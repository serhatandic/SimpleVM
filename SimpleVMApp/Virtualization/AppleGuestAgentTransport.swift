import Darwin
import Foundation
import SimpleVMCore
import Virtualization

enum AppleGuestAgentTransport {
    static func request(
        _ request: GuestAgentRequest,
        virtualMachine: VZVirtualMachine,
        port: UInt32 = 1_021
    ) async throws -> GuestAgentResponse {
        guard let socketDevice =
            virtualMachine.socketDevices.first as? VZVirtioSocketDevice
        else {
            throw GuestAgentTransportError.unavailable
        }
        let connectionBox = try await withCheckedThrowingContinuation {
            (
                continuation:
                    CheckedContinuation<SocketConnectionBox, any Error>
            ) in
            socketDevice.connect(toPort: port) { result in
                switch result {
                case .success(let connection):
                    continuation.resume(
                        returning: SocketConnectionBox(connection)
                    )
                case .failure(let error):
                    continuation.resume(
                        throwing: GuestAgentTransportError.connectionFailed(
                            error.localizedDescription
                        )
                    )
                }
            }
        }
        let connection = connectionBox.value
        let descriptor = dup(connection.fileDescriptor)
        connection.close()
        guard descriptor >= 0 else {
            throw POSIXError(.EBADF)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: GuestAgentFrameCodec.encode(request))
        let header = try await readExactly(4, from: handle)
        let payloadLength = header.reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        guard payloadLength <= GuestAgentFrameCodec.maximumPayloadSize else {
            throw GuestAgentProtocolError.payloadTooLarge
        }
        let payload = try await readExactly(Int(payloadLength), from: handle)
        var frame = header
        frame.append(payload)
        return try GuestAgentFrameCodec.decode(
            GuestAgentResponse.self,
            from: frame
        )
    }

    private static func readExactly(
        _ count: Int,
        from handle: FileHandle
    ) async throws -> Data {
        var result = Data()
        while result.count < count {
            guard let chunk = try handle.read(
                upToCount: count - result.count
            ), !chunk.isEmpty else {
                throw GuestAgentTransportError.disconnected
            }
            result.append(chunk)
        }
        return result
    }
}

enum GuestAgentTransportError: LocalizedError {
    case unavailable
    case disconnected
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "The guest-agent transport is unavailable."
        case .disconnected:
            "The guest agent disconnected."
        case .connectionFailed(let message):
            "The guest agent connection failed: \(message)"
        }
    }
}

private final class SocketConnectionBox: @unchecked Sendable {
    let value: VZVirtioSocketConnection

    init(_ value: VZVirtioSocketConnection) {
        self.value = value
    }
}
