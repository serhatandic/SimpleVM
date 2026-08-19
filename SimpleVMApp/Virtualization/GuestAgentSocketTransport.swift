import Darwin
import Foundation
import SimpleVMCore

enum GuestAgentSocketTransport {
    static let defaultTimeout: TimeInterval = 3

    static func request(
        _ request: GuestAgentRequest,
        timeout: TimeInterval = defaultTimeout,
        connect: @escaping @Sendable () throws -> Int32
    ) async throws -> GuestAgentResponse {
        let envelope = GuestAgentRequestEnvelope(request: request)
        let operation = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let descriptor = try connect()
            defer { Darwin.close(descriptor) }
            try configure(descriptor)
            let deadline = Date().addingTimeInterval(timeout)
            try write(
                GuestAgentFrameCodec.encode(envelope),
                to: descriptor,
                deadline: deadline
            )
            let header = try readExactly(
                4,
                from: descriptor,
                deadline: deadline
            )
            let payloadLength = header.reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            guard payloadLength <= GuestAgentFrameCodec.maximumPayloadSize else {
                throw GuestAgentProtocolError.payloadTooLarge
            }
            let payload = try readExactly(
                Int(payloadLength),
                from: descriptor,
                deadline: deadline
            )
            var frame = header
            frame.append(payload)
            let response = try GuestAgentFrameCodec.decode(
                GuestAgentResponseEnvelope.self,
                from: frame
            )
            guard (1...GuestAgentProtocol.currentVersion).contains(
                response.protocolVersion
            ) else {
                throw GuestAgentProtocolError.incompatibleVersion(
                    response.protocolVersion
                )
            }
            if response.protocolVersion >= 2,
               response.requestID != envelope.requestID {
                throw GuestAgentProtocolError.mismatchedRequestID
            }
            if response.protocolVersion == 1,
               let responseID = response.requestID,
               responseID != envelope.requestID {
                throw GuestAgentProtocolError.mismatchedRequestID
            }
            return response.response
        }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    static func connectUnixSocket(at socketURL: URL) throws -> Int32 {
        let path = socketURL.path
        guard !path.isEmpty else {
            throw GuestAgentTransportError.invalidSocketPath
        }
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count + 1 <= capacity else {
            throw GuestAgentTransportError.invalidSocketPath
        }
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                destination in
                path.withCString { source in
                    memcpy(destination, source, path.utf8.count + 1)
                }
            }
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw GuestAgentTransportError.posix(
                operation: "create the Unix socket",
                code: errno
            )
        }
        do {
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(
                        descriptor,
                        $0,
                        socklen_t(
                            MemoryLayout<sa_family_t>.size
                                + path.utf8.count + 1
                        )
                    )
                }
            }
            guard result == 0 else {
                throw GuestAgentTransportError.posix(
                    operation: "connect to \(path)",
                    code: errno
                )
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func configure(_ descriptor: Int32) throws {
        var enabled: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout.size(ofValue: enabled))
        ) == 0 else {
            throw GuestAgentTransportError.posix(
                operation: "configure the guest-agent socket",
                code: errno
            )
        }
    }

    private static func write(
        _ data: Data,
        to descriptor: Int32,
        deadline: Date
    ) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                try wait(
                    descriptor: descriptor,
                    events: Int16(POLLOUT),
                    deadline: deadline
                )
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR || errno == EAGAIN {
                    continue
                } else {
                    throw GuestAgentTransportError.posix(
                        operation: "write to the guest agent",
                        code: count == 0 ? EPIPE : errno
                    )
                }
            }
        }
    }

    private static func readExactly(
        _ count: Int,
        from descriptor: Int32,
        deadline: Date
    ) throws -> Data {
        var result = Data(count: count)
        var offset = 0
        while offset < count {
            try wait(
                descriptor: descriptor,
                events: Int16(POLLIN),
                deadline: deadline
            )
            let readCount = result.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    count - offset
                )
            }
            if readCount > 0 {
                offset += readCount
            } else if readCount == 0 {
                throw GuestAgentTransportError.disconnected
            } else if errno == EINTR || errno == EAGAIN {
                continue
            } else {
                throw GuestAgentTransportError.posix(
                    operation: "read from the guest agent",
                    code: errno
                )
            }
        }
        return result
    }

    private static func wait(
        descriptor: Int32,
        events: Int16,
        deadline: Date
    ) throws {
        while true {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw GuestAgentTransportError.timedOut
            }
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let milliseconds = Int32(
                min(max(remaining * 1_000, 1), 200).rounded(.up)
            )
            let result = Darwin.poll(&item, 1, milliseconds)
            if result == 0 {
                continue
            }
            if result < 0 {
                if errno == EINTR {
                    continue
                }
                throw GuestAgentTransportError.posix(
                    operation: "wait for the guest agent",
                    code: errno
                )
            }
            if item.revents & Int16(POLLNVAL | POLLERR) != 0 {
                throw GuestAgentTransportError.disconnected
            }
            if item.revents & events != 0 {
                return
            }
            if item.revents & Int16(POLLHUP) != 0 {
                throw GuestAgentTransportError.disconnected
            }
        }
    }
}

enum QEMUGuestAgentTransport {
    static func request(
        _ request: GuestAgentRequest,
        socketURL: URL,
        timeout: TimeInterval = GuestAgentSocketTransport.defaultTimeout
    ) async throws -> GuestAgentResponse {
        try await GuestAgentSocketTransport.request(
            request,
            timeout: timeout
        ) {
            try GuestAgentSocketTransport.connectUnixSocket(at: socketURL)
        }
    }
}

enum GuestAgentTransportError: LocalizedError, Equatable {
    case unavailable
    case disconnected
    case timedOut
    case invalidSocketPath
    case connectionFailed(String)
    case posix(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "The Guest Tools transport is unavailable."
        case .disconnected:
            "Guest Tools disconnected before replying."
        case .timedOut:
            "Guest Tools did not reply before the request timed out."
        case .invalidSocketPath:
            "The Guest Tools Unix socket path is invalid."
        case .connectionFailed(let message):
            "The Guest Tools connection failed: \(message)"
        case .posix(let operation, let code):
            "Could not \(operation): \(String(cString: strerror(code)))."
        }
    }
}
