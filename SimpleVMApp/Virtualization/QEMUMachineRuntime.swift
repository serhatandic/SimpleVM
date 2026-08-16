import CoreGraphics
import Foundation
import Network
import Observation
import SimpleVMCore

@MainActor
@Observable
final class QEMUMachineRuntime {
    private(set) var state: MachineRuntimeState
    private(set) var framebuffer: CGImage?

    var hasDisplay: Bool {
        framebuffer != nil
    }

    @ObservationIgnored
    var stateHandler: ((MachineRuntimeState) -> Void)?

    @ObservationIgnored
    var errorHandler: ((any Error) -> Void)?

    @ObservationIgnored
    private var processController: QEMUProcessController?

    @ObservationIgnored
    private var vncClient: SimpleVNCClient?

    init(state: MachineRuntimeState = .stopped) {
        switch state {
        case .running, .starting, .stopping:
            self.state = .stopped
        default:
            self.state = state
        }
    }

    func start(
        machine: Machine,
        diskURL: URL,
        installerURL: URL?,
        backendStateURL: URL
    ) async {
        guard state.canStart else {
            return
        }
        transition(to: .starting)
        do {
            let runtime = try QEMURuntimeDiscovery.discover()
            let port = try await LoopbackPortAllocator.allocate()
            var releasesPortReservation = true
            defer {
                if releasesPortReservation {
                    LoopbackPortAllocator.release(port)
                }
            }
            let configuration = try QEMUConfigurationBuilder.make(
                machine: machine,
                diskURL: diskURL,
                installerURL: installerURL,
                backendStateURL: backendStateURL,
                runtime: runtime,
                vncPort: port
            )
            let controller = QEMUProcessController { [weak self] processState in
                Task { @MainActor in
                    self?.handle(processState: processState)
                }
            }
            processController = controller
            try await controller.start(configuration: configuration)
            try await waitForPort(port)
            LoopbackPortAllocator.release(port)
            releasesPortReservation = false

            let client = SimpleVNCClient(port: port)
            client.imageHandler = { [weak self] image in
                let image = CGImageBox(image)
                Task { @MainActor in
                    self?.framebuffer = image.value
                }
            }
            client.errorHandler = { [weak self] error in
                Task { @MainActor in
                    self?.errorHandler?(error)
                }
            }
            vncClient = client
            try await client.connect()
            transition(to: .running)
        } catch {
            await processController?.forceStop()
            clearRuntime()
            transition(to: .failed(message: error.localizedDescription))
        }
    }

    func stop() async {
        guard state == .running || state == .stopping else {
            return
        }
        transition(to: .stopping)
        vncClient?.errorHandler = nil
        vncClient?.disconnect()
        await processController?.stop()
        clearRuntime()
        transition(to: .stopped)
    }

    func forceStop() async {
        guard state == .starting || state == .running || state == .stopping else {
            return
        }
        transition(to: .stopping)
        vncClient?.errorHandler = nil
        vncClient?.disconnect()
        await processController?.forceStop()
        clearRuntime()
        transition(to: .stopped)
    }

    func sendKey(_ keysym: UInt32, isDown: Bool) {
        vncClient?.sendKey(keysym, isDown: isDown)
    }

    func sendPointer(mask: UInt8, x: UInt16, y: UInt16) {
        vncClient?.sendPointer(mask: mask, x: x, y: y)
    }

    private func waitForPort(_ port: UInt16) async throws {
        for _ in 0..<100 {
            do {
                try await probePort(port)
                return
            } catch {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        throw QEMURuntimeDisplayError.unavailable
    }

    private func probePort(_ port: UInt16) async throws {
        let connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            let gate = ContinuationGate()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    connection.cancel()
                    continuation.resume()
                case .failed(let error):
                    guard gate.claim() else { return }
                    connection.cancel()
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private func handle(processState: QEMUProcessController.State) {
        switch processState {
        case .stopped:
            clearRuntime()
            transition(to: .stopped)
        case .failed(let message):
            clearRuntime()
            transition(to: .failed(message: message))
        case .starting, .running, .stopping:
            break
        }
    }

    private func transition(to state: MachineRuntimeState) {
        self.state = state
        stateHandler?(state)
    }

    private func clearRuntime() {
        vncClient?.errorHandler = nil
        vncClient?.disconnect()
        vncClient = nil
        framebuffer = nil
        processController = nil
    }
}

private final class CGImageBox: @unchecked Sendable {
    let value: CGImage
    init(_ value: CGImage) {
        self.value = value
    }
}

private enum QEMURuntimeDisplayError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "QEMU started but its display did not become available."
    }
}

private extension MachineRuntimeState {
    var canStart: Bool {
        switch self {
        case .stopped, .failed:
            true
        case .starting, .running, .stopping:
            false
        }
    }
}
