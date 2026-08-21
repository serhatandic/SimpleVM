import Observation
import SimpleVMCore

@MainActor
@Observable
class MachineRuntimeBase {
    private(set) var state: MachineRuntimeState
    let guestTools = GuestToolsCoordinator()

    @ObservationIgnored
    var stateHandler: ((MachineRuntimeState) -> Void)?

    @ObservationIgnored
    var errorHandler: ((any Error) -> Void)?

    init(state: MachineRuntimeState = .stopped) {
        switch state {
        case .running, .starting, .stopping:
            self.state = .stopped
        default:
            self.state = state
        }
    }

    func requestReboot() async {
        guard state == .running else { return }
        do {
            try await guestTools.requestReboot()
        } catch {
            errorHandler?(error)
        }
    }

    func transition(to state: MachineRuntimeState) {
        self.state = state
        stateHandler?(state)
    }
}
