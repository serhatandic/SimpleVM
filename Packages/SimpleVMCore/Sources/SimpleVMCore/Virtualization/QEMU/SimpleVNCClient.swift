import CoreGraphics
import Foundation
import Network

public final class SimpleVNCClient: @unchecked Sendable {
    public var imageHandler: (@Sendable (CGImage) -> Void)?
    public var errorHandler: (@Sendable (any Error) -> Void)?

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.simplevm.vnc")
    private var framebuffer = Data()
    private(set) var width = 0
    private(set) var height = 0

    public init(port: UInt16) {
        connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
    }

    public func connect() async throws {
        connection.start(queue: queue)
        try await waitUntilReady()
        try await handshake()
        Task {
            do {
                try await readUpdates()
            } catch {
                errorHandler?(error)
            }
        }
    }

    public func disconnect() {
        connection.cancel()
    }

    public func sendKey(_ keysym: UInt32, isDown: Bool) {
        var message = Data([4, isDown ? 1 : 0, 0, 0])
        message.appendBigEndian(keysym)
        sendWithoutWaiting(message)
    }

    public func sendPointer(mask: UInt8, x: UInt16, y: UInt16) {
        var message = Data([5, mask])
        message.appendBigEndian(x)
        message.appendBigEndian(y)
        sendWithoutWaiting(message)
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            let gate = VNCContinuationGate()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    continuation.resume()
                case .failed(let error):
                    guard gate.claim() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
        }
    }

    private func handshake() async throws {
        let version = try await receiveExactly(12)
        guard String(data: version, encoding: .ascii)?.hasPrefix("RFB 003.") == true
        else {
            throw SimpleVNCError.unsupportedVersion
        }
        try await send(Data("RFB 003.008\n".utf8))

        let securityCount = Int(try await receiveExactly(1)[0])
        guard securityCount > 0 else {
            let reasonLength = Int(
                try await receiveExactly(4).readUInt32BigEndian(at: 0)
            )
            _ = try await receiveExactly(reasonLength)
            throw SimpleVNCError.noSecurityType
        }
        let securityTypes = try await receiveExactly(securityCount)
        guard securityTypes.contains(1) else {
            throw SimpleVNCError.noSecurityType
        }
        try await send(Data([1]))
        let securityResult = try await receiveExactly(4).readUInt32BigEndian(
            at: 0
        )
        guard securityResult == 0 else {
            throw SimpleVNCError.authenticationFailed
        }

        try await send(Data([1]))
        let serverHeader = try await receiveExactly(24)
        width = Int(serverHeader.readUInt16BigEndian(at: 0))
        height = Int(serverHeader.readUInt16BigEndian(at: 2))
        let nameLength = Int(serverHeader.readUInt32BigEndian(at: 20))
        _ = try await receiveExactly(nameLength)
        framebuffer = Data(repeating: 0, count: width * height * 4)

        var pixelFormat = Data([0, 0, 0, 0, 32, 24, 0, 1])
        pixelFormat.appendBigEndian(UInt16(255))
        pixelFormat.appendBigEndian(UInt16(255))
        pixelFormat.appendBigEndian(UInt16(255))
        pixelFormat.append(contentsOf: [16, 8, 0, 0, 0, 0])
        try await send(pixelFormat)

        var encodings = Data([2, 0])
        encodings.appendBigEndian(UInt16(2))
        encodings.appendBigEndian(UInt32(0))
        encodings.appendBigEndian(UInt32(bitPattern: -223))
        try await send(encodings)
        try await requestUpdate(incremental: false)
    }

    private func readUpdates() async throws {
        while true {
            let messageType = try await receiveExactly(1)[0]
            switch messageType {
            case 0:
                try await readFramebufferUpdate()
            case 1:
                let header = try await receiveExactly(5)
                let colorCount = Int(header.readUInt16BigEndian(at: 3))
                _ = try await receiveExactly(colorCount * 6)
            case 2:
                continue
            case 3:
                let header = try await receiveExactly(7)
                let length = Int(header.readUInt32BigEndian(at: 3))
                _ = try await receiveExactly(length)
            default:
                throw SimpleVNCError.unsupportedMessage(messageType)
            }
        }
    }

    private func readFramebufferUpdate() async throws {
        let header = try await receiveExactly(3)
        let rectangleCount = Int(header.readUInt16BigEndian(at: 1))
        for _ in 0..<rectangleCount {
            let rectangle = try await receiveExactly(12)
            let x = Int(rectangle.readUInt16BigEndian(at: 0))
            let y = Int(rectangle.readUInt16BigEndian(at: 2))
            let rectangleWidth = Int(rectangle.readUInt16BigEndian(at: 4))
            let rectangleHeight = Int(rectangle.readUInt16BigEndian(at: 6))
            let encoding = Int32(
                bitPattern: rectangle.readUInt32BigEndian(at: 8)
            )
            if encoding == -223 {
                width = rectangleWidth
                height = rectangleHeight
                framebuffer = Data(
                    repeating: 0,
                    count: width * height * 4
                )
                try await requestUpdate(incremental: false)
                continue
            }
            guard encoding == 0 else {
                throw SimpleVNCError.unsupportedEncoding(encoding)
            }
            var pixels = try await receiveExactly(
                rectangleWidth * rectangleHeight * 4
            )
            for alphaIndex in stride(from: 3, to: pixels.count, by: 4) {
                pixels[alphaIndex] = 255
            }
            copy(
                pixels: pixels,
                x: x,
                y: y,
                width: rectangleWidth,
                height: rectangleHeight
            )
        }
        publishImage()
        try await requestUpdate(incremental: true)
    }

    private func copy(
        pixels: Data,
        x: Int,
        y: Int,
        width rectangleWidth: Int,
        height rectangleHeight: Int
    ) {
        let sourceRowBytes = rectangleWidth * 4
        for row in 0..<rectangleHeight {
            let sourceStart = row * sourceRowBytes
            let destinationStart = ((y + row) * width + x) * 4
            let destinationEnd = destinationStart + sourceRowBytes
            let sourceEnd = sourceStart + sourceRowBytes
            guard destinationStart >= 0,
                  destinationEnd <= framebuffer.count,
                  sourceEnd <= pixels.count else {
                continue
            }
            framebuffer.replaceSubrange(
                destinationStart..<destinationEnd,
                with: pixels[sourceStart..<(sourceStart + sourceRowBytes)]
            )
        }
    }

    private func publishImage() {
        guard let provider = CGDataProvider(data: framebuffer as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(
                      rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                          | CGBitmapInfo.byteOrder32Little.rawValue
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            return
        }
        imageHandler?(image)
    }

    private func requestUpdate(incremental: Bool) async throws {
        var message = Data([3, incremental ? 1 : 0])
        message.appendBigEndian(UInt16(0))
        message.appendBigEndian(UInt16(0))
        message.appendBigEndian(UInt16(width))
        message.appendBigEndian(UInt16(height))
        try await send(message)
    }

    private func receiveExactly(_ count: Int) async throws -> Data {
        guard count > 0 else {
            return Data()
        }
        var result = Data()
        while result.count < count {
            let remaining = count - result.count
            let chunk = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, any Error>) in
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: remaining
                ) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(throwing: SimpleVNCError.disconnected)
                    } else {
                        continuation.resume(throwing: SimpleVNCError.disconnected)
                    }
                }
            }
            result.append(chunk)
        }
        return result
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    private func sendWithoutWaiting(_ data: Data) {
        connection.send(content: data, completion: .idempotent)
    }
}

private final class VNCContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

private enum SimpleVNCError: LocalizedError {
    case unsupportedVersion
    case noSecurityType
    case authenticationFailed
    case unsupportedMessage(UInt8)
    case unsupportedEncoding(Int32)
    case disconnected

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            "QEMU uses an unsupported VNC protocol version."
        case .noSecurityType:
            "QEMU did not offer a supported local VNC security type."
        case .authenticationFailed:
            "QEMU rejected the local VNC connection."
        case .unsupportedMessage(let type):
            "QEMU sent unsupported VNC message \(type)."
        case .unsupportedEncoding(let encoding):
            "QEMU sent unsupported VNC encoding \(encoding)."
        case .disconnected:
            "The QEMU display disconnected."
        }
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.bigEndian
        append(Data(bytes: &value, count: MemoryLayout<T>.size))
    }

    func readUInt16BigEndian(at offset: Int) -> UInt16 {
        self[offset..<(offset + 2)].reduce(UInt16(0)) {
            ($0 << 8) | UInt16($1)
        }
    }

    func readUInt32BigEndian(at offset: Int) -> UInt32 {
        self[offset..<(offset + 4)].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
    }
}
