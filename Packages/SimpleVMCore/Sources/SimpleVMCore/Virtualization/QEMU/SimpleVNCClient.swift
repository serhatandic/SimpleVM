import CoreGraphics
import Darwin
import Foundation

public final class SimpleVNCClient: @unchecked Sendable {
    public var imageHandler: (@Sendable (CGImage) -> Void)?
    public var errorHandler: (@Sendable (any Error) -> Void)?

    private let port: UInt16
    private let descriptorLock = NSLock()
    private let writeLock = NSLock()
    private var descriptor: Int32 = -1
    private var expectsDisconnect = false
    private var framebuffer = Data()
    private(set) var width = 0
    private(set) var height = 0

    public init(port: UInt16) {
        self.port = port
    }

    public func connect() async throws {
        try await Task.detached { [self] in
            try openSocket()
            try handshake()
        }.value
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                try readUpdates()
            } catch {
                if !descriptorLock.withLock({ expectsDisconnect }) {
                    errorHandler?(error)
                }
            }
        }
    }

    public func disconnect() {
        let descriptor = descriptorLock.withLock {
            expectsDisconnect = true
            let descriptor = self.descriptor
            self.descriptor = -1
            return descriptor
        }
        if descriptor >= 0 {
            shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
        }
    }

    public func sendKey(_ keysym: UInt32, isDown: Bool) {
        var message = Data([4, isDown ? 1 : 0, 0, 0])
        message.appendBigEndian(keysym)
        try? send(message)
    }

    public func requestDesktopSize(width: UInt16, height: UInt16) {
        var message = Data([251, 0])
        message.appendBigEndian(width)
        message.appendBigEndian(height)
        message.append(contentsOf: [1, 0])
        message.appendBigEndian(UInt32(0))
        message.appendBigEndian(UInt16(0))
        message.appendBigEndian(UInt16(0))
        message.appendBigEndian(width)
        message.appendBigEndian(height)
        message.appendBigEndian(UInt32(0))
        try? send(message)
    }

    public func sendPointer(mask: UInt8, x: UInt16, y: UInt16) {
        var message = Data([5, mask])
        message.appendBigEndian(x)
        message.appendBigEndian(y)
        try? send(message)
    }

    private func openSocket() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var noSignal: Int32 = 1
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var noDelay: Int32 = 1
        setsockopt(
            descriptor,
            IPPROTO_TCP,
            TCP_NODELAY,
            &noDelay,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard result == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(descriptor)
            throw error
        }
        descriptorLock.withLock {
            self.descriptor = descriptor
            expectsDisconnect = false
        }
    }

    private func handshake() throws {
        let version = try receiveExactly(12)
        guard String(data: version, encoding: .ascii)?.hasPrefix("RFB 003.") == true
        else {
            throw SimpleVNCError.unsupportedVersion
        }
        try send(Data("RFB 003.008\n".utf8))

        let securityCount = Int(try receiveExactly(1)[0])
        guard securityCount > 0 else {
            let length = Int(
                try receiveExactly(4).readUInt32BigEndian(at: 0)
            )
            _ = try receiveExactly(length)
            throw SimpleVNCError.noSecurityType
        }
        let securityTypes = try receiveExactly(securityCount)
        guard securityTypes.contains(1) else {
            throw SimpleVNCError.noSecurityType
        }
        try send(Data([1]))
        guard try receiveExactly(4).readUInt32BigEndian(at: 0) == 0 else {
            throw SimpleVNCError.authenticationFailed
        }

        try send(Data([1]))
        let serverHeader = try receiveExactly(24)
        width = Int(serverHeader.readUInt16BigEndian(at: 0))
        height = Int(serverHeader.readUInt16BigEndian(at: 2))
        _ = try receiveExactly(
            Int(serverHeader.readUInt32BigEndian(at: 20))
        )
        framebuffer = Data(repeating: 0, count: width * height * 4)

        var pixelFormat = Data([0, 0, 0, 0, 32, 24, 0, 1])
        pixelFormat.appendBigEndian(UInt16(255))
        pixelFormat.appendBigEndian(UInt16(255))
        pixelFormat.appendBigEndian(UInt16(255))
        pixelFormat.append(contentsOf: [16, 8, 0, 0, 0, 0])
        try send(pixelFormat)

        var encodings = Data([2, 0])
        encodings.appendBigEndian(UInt16(3))
        encodings.appendBigEndian(UInt32(0))
        encodings.appendBigEndian(UInt32(bitPattern: -223))
        encodings.appendBigEndian(UInt32(bitPattern: -308))
        try send(encodings)
        try requestUpdate(incremental: false)
    }

    private func readUpdates() throws {
        while true {
            switch try receiveExactly(1)[0] {
            case 0:
                try readFramebufferUpdate()
            case 1:
                let header = try receiveExactly(5)
                _ = try receiveExactly(
                    Int(header.readUInt16BigEndian(at: 3)) * 6
                )
            case 2:
                continue
            case 3:
                let header = try receiveExactly(7)
                _ = try receiveExactly(
                    Int(header.readUInt32BigEndian(at: 3))
                )
            case let type:
                throw SimpleVNCError.unsupportedMessage(type)
            }
        }
    }

    private func readFramebufferUpdate() throws {
        let header = try receiveExactly(3)
        let rectangleCount = Int(header.readUInt16BigEndian(at: 1))
        for _ in 0..<rectangleCount {
            let rectangle = try receiveExactly(12)
            let x = Int(rectangle.readUInt16BigEndian(at: 0))
            let y = Int(rectangle.readUInt16BigEndian(at: 2))
            let rectangleWidth = Int(rectangle.readUInt16BigEndian(at: 4))
            let rectangleHeight = Int(rectangle.readUInt16BigEndian(at: 6))
            let encoding = Int32(
                bitPattern: rectangle.readUInt32BigEndian(at: 8)
            )
            if encoding == -223 {
                if width != rectangleWidth || height != rectangleHeight {
                    width = rectangleWidth
                    height = rectangleHeight
                    framebuffer = Data(
                        repeating: 0,
                        count: width * height * 4
                    )
                    try requestUpdate(incremental: false)
                }
                continue
            }
            if encoding == -308 {
                let header = try receiveExactly(4)
                let screenCount = Int(header[0])
                _ = try receiveExactly(screenCount * 16)
                if width != rectangleWidth || height != rectangleHeight {
                    width = rectangleWidth
                    height = rectangleHeight
                    framebuffer = Data(
                        repeating: 0,
                        count: width * height * 4
                    )
                    try requestUpdate(incremental: false)
                }
                continue
            }
            guard encoding == 0 else {
                throw SimpleVNCError.unsupportedEncoding(encoding)
            }
            let pixels = try receiveExactly(
                rectangleWidth * rectangleHeight * 4
            )
            copy(
                pixels: pixels,
                x: x,
                y: y,
                width: rectangleWidth,
                height: rectangleHeight
            )
        }
        publishImage()
        try requestUpdate(incremental: true)
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
                with: pixels[sourceStart..<sourceEnd]
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
                      rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
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

    private func requestUpdate(incremental: Bool) throws {
        var message = Data([3, incremental ? 1 : 0])
        message.appendBigEndian(UInt16(0))
        message.appendBigEndian(UInt16(0))
        message.appendBigEndian(UInt16(width))
        message.appendBigEndian(UInt16(height))
        try send(message)
    }

    private func receiveExactly(_ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let descriptor = descriptorLock.withLock { self.descriptor }
                guard descriptor >= 0 else {
                    throw SimpleVNCError.disconnected
                }
                let received = Darwin.recv(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    count - offset,
                    0
                )
                guard received > 0 else {
                    throw SimpleVNCError.disconnected
                }
                offset += received
            }
        }
        return result
    }

    private func send(_ data: Data) throws {
        try writeLock.withLock {
            let descriptor = descriptorLock.withLock { self.descriptor }
            guard descriptor >= 0 else {
                throw SimpleVNCError.disconnected
            }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.send(
                        descriptor,
                        bytes.baseAddress!.advanced(by: offset),
                        bytes.count - offset,
                        0
                    )
                    guard written > 0 else {
                        throw SimpleVNCError.disconnected
                    }
                    offset += written
                }
            }
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
