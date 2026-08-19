import Darwin
import Foundation
import SimpleVMCore
import Virtualization

enum AppleGuestAgentTransport {
    @MainActor
    static func request(
        _ request: GuestAgentRequest,
        virtualMachine: VZVirtualMachine,
        port: UInt32 = GuestAgentProtocol.agentPort,
        timeout: TimeInterval = GuestAgentSocketTransport.defaultTimeout
    ) async throws -> GuestAgentResponse {
        guard let socketDevice =
            virtualMachine.socketDevices.first as? VZVirtioSocketDevice
        else {
            throw GuestAgentTransportError.unavailable
        }
        let completion = SocketConnectionCompletion()
        let connectionBox = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                Task {
                    try? await Task.sleep(for: .seconds(timeout))
                    completion.complete(
                        .failure(GuestAgentTransportError.timedOut)
                    )
                }
                socketDevice.connect(toPort: port) { result in
                    switch result {
                    case .success(let connection):
                        completion.complete(
                            .success(SocketConnectionBox(connection))
                        )
                    case .failure(let error):
                        completion.complete(
                            .failure(
                                GuestAgentTransportError.connectionFailed(
                                    error.localizedDescription
                                )
                            )
                        )
                    }
                }
            }
        } onCancel: {
            completion.complete(.failure(CancellationError()))
        }
        defer { connectionBox.value.close() }
        return try await GuestAgentSocketTransport.request(
            request,
            timeout: timeout
        ) {
            let descriptor = dup(connectionBox.value.fileDescriptor)
            guard descriptor >= 0 else {
                throw POSIXError(.EBADF)
            }
            return descriptor
        }
    }
}

private final class SocketConnectionBox: @unchecked Sendable {
    let value: VZVirtioSocketConnection

    init(_ value: VZVirtioSocketConnection) {
        self.value = value
    }
}

private final class SocketConnectionCompletion: @unchecked Sendable {
    private typealias ConnectionResult = Result<SocketConnectionBox, Error>
    private typealias ConnectionContinuation =
        CheckedContinuation<SocketConnectionBox, Error>

    private let lock = NSLock()
    private var continuation: ConnectionContinuation?
    private var pendingResult: ConnectionResult?
    private var isCompleted = false

    func install(
        _ continuation: CheckedContinuation<SocketConnectionBox, Error>
    ) {
        lock.lock()
        let result = pendingResult
        if result == nil {
            self.continuation = continuation
        } else {
            pendingResult = nil
        }
        lock.unlock()

        if let result {
            continuation.resume(with: result)
        }
    }

    func complete(_ result: Result<SocketConnectionBox, Error>) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            if case .success(let box) = result {
                box.value.close()
            }
            return
        }
        isCompleted = true
        let continuation = self.continuation
        if continuation == nil {
            pendingResult = result
        } else {
            self.continuation = nil
        }
        lock.unlock()

        if let continuation {
            continuation.resume(with: result)
        }
    }
}
