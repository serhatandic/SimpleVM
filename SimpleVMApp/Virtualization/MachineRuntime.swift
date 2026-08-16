import Observation
import AppKit
import SimpleVMCore
import Virtualization

@MainActor
@Observable
final class MachineRuntime {
    private(set) var state: MachineRuntimeState
    private(set) var virtualMachine: VZVirtualMachine?

    @ObservationIgnored
    var stateHandler: ((MachineRuntimeState) -> Void)?

    @ObservationIgnored
    var errorHandler: ((any Error) -> Void)?

    @ObservationIgnored
    private var virtualMachineDelegate: VirtualMachineDelegate?

    @ObservationIgnored
    weak var displayView: VZVirtualMachineView?

    @ObservationIgnored
    private var pressedModifierKeyCodes: Set<UInt16> = []

    @ObservationIgnored
    private var pressedKeyEvents: [UInt16: NSEvent] = [:]

    init(state: MachineRuntimeState = .stopped) {
        switch state {
        case .running, .starting, .stopping:
            self.state = .stopped
        default:
            self.state = state
        }
    }

    func start(configuration: VZVirtualMachineConfiguration) async {
        guard state.canStart else {
            return
        }

        transition(to: .starting)
        let virtualMachine = VZVirtualMachine(configuration: configuration)
        let delegate = VirtualMachineDelegate { [weak self] state in
            self?.handleDelegateState(state)
        }
        virtualMachine.delegate = delegate
        self.virtualMachine = virtualMachine
        virtualMachineDelegate = delegate

        do {
            try await virtualMachine.start()
            transition(to: .running)
        } catch {
            clearVirtualMachine()
            transition(to: .failed(message: error.localizedDescription))
        }
    }

    func requestStop() {
        guard let virtualMachine, state == .running else {
            return
        }

        do {
            try virtualMachine.requestStop()
            transition(to: .stopping)
        } catch {
            transition(to: .running)
            errorHandler?(error)
        }
    }

    func forceStop() async {
        guard let virtualMachine,
              state == .running || state == .stopping else {
            return
        }

        transition(to: .stopping)
        do {
            try await virtualMachine.stop()
            clearVirtualMachine()
            transition(to: .stopped)
        } catch {
            transition(to: .running)
            errorHandler?(error)
        }
    }

    func sendKeyEvent(_ event: NSEvent) {
        guard let displayView else { return }
        switch event.type {
        case .keyDown:
            if !event.isARepeat {
                pressedKeyEvents[event.keyCode] = event
            }
            displayView.keyDown(with: event)
        case .keyUp:
            pressedKeyEvents.removeValue(forKey: event.keyCode)
            displayView.keyUp(with: event)
        case .flagsChanged:
            if event.keyCode != 57,
               QEMUKeyMapper.modifierKeysym(for: event.keyCode) != nil {
                if QEMUKeyMapper.isModifierDown(event) {
                    pressedModifierKeyCodes.insert(event.keyCode)
                } else {
                    pressedModifierKeyCodes.remove(event.keyCode)
                }
            }
            displayView.flagsChanged(with: event)
        default:
            break
        }
    }

    func releaseAllKeys() {
        if let displayView {
            for event in pressedKeyEvents.values {
                guard let release = NSEvent.keyEvent(
                    with: .keyUp,
                    location: event.locationInWindow,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: displayView.window?.windowNumber ?? 0,
                    context: nil,
                    characters: event.characters ?? "",
                    charactersIgnoringModifiers:
                        event.charactersIgnoringModifiers ?? "",
                    isARepeat: false,
                    keyCode: event.keyCode
                ) else { continue }
                displayView.keyUp(with: release)
            }
        }
        pressedKeyEvents.removeAll()
        guard let displayView else {
            pressedModifierKeyCodes.removeAll()
            return
        }
        for keyCode in pressedModifierKeyCodes {
            guard let release = NSEvent.keyEvent(
                with: .flagsChanged,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: displayView.window?.windowNumber ?? 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: keyCode
            ) else { continue }
            displayView.flagsChanged(with: release)
        }
        pressedModifierKeyCodes.removeAll()
    }

    private func handleDelegateState(_ state: MachineRuntimeState) {
        clearVirtualMachine()
        transition(to: state)
    }

    private func transition(to state: MachineRuntimeState) {
        self.state = state
        stateHandler?(state)
    }

    private func clearVirtualMachine() {
        pressedModifierKeyCodes.removeAll()
        pressedKeyEvents.removeAll()
        virtualMachine = nil
        virtualMachineDelegate = nil
    }
}

private final class VirtualMachineDelegate: NSObject, VZVirtualMachineDelegate {
    private let handler: @MainActor @Sendable (MachineRuntimeState) -> Void

    init(handler: @escaping @MainActor @Sendable (MachineRuntimeState) -> Void) {
        self.handler = handler
    }

    func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        didStopWithError error: any Error
    ) {
        let handler = handler
        let message = error.localizedDescription
        Task { @MainActor in
            handler(.failed(message: message))
        }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        let handler = handler
        Task { @MainActor in
            handler(.stopped)
        }
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
