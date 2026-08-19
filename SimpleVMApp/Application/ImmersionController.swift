import AppKit
import Observation

@MainActor
@Observable
final class ImmersionController {
    static let exitShortcutDescription = "⌃⌥⌘ Esc"

    private(set) var activeMachineID: UUID?
    private(set) var showsExitHint = false
    private(set) var requiresAccessibilityPermission = false
    private(set) var karabinerErrorMessage: String?

    @ObservationIgnored
    private weak var window: NSWindow?

    @ObservationIgnored
    private var enteredFullScreen = false

    @ObservationIgnored
    private var releaseKeysHandler: (() -> Void)?

    @ObservationIgnored
    private var inputCapture: ImmersiveInputCapture?

    @ObservationIgnored
    private var fullScreenObserver: Any?

    @ObservationIgnored
    private var resignActiveObserver: Any?

    @ObservationIgnored
    private var becomeActiveObserver: Any?

    @ObservationIgnored
    private var exitObserver: Any?

    @ObservationIgnored
    private var fallbackEventMonitor: Any?

    init() {
        KarabinerInputBridge.setImmersionActive(false)
    }

    func enter(
        machineID: UUID,
        keyEventHandler: @escaping (GuestKeyEvent) -> Void,
        releaseKeysHandler: @escaping () -> Void,
        workspaceSwipeHandler: @escaping (
            WorkspaceSwipeDirection
        ) -> Void,
        usesKarabinerInput: Bool
    ) {
        guard activeMachineID == nil, let window = NSApp.keyWindow else {
            return
        }
        activeMachineID = machineID
        self.releaseKeysHandler = releaseKeysHandler
        self.window = window
        showsExitHint = true
        window.toolbar?.isVisible = false
        if usesKarabinerInput {
            do {
                try KarabinerInputBridge.prepare()
                guard KarabinerInputBridge.setImmersionActive(true) else {
                    throw KarabinerBridgeError.commandFailed(
                        "Unable to activate SimpleVM mappings."
                    )
                }
                karabinerErrorMessage = nil
            } catch {
                karabinerErrorMessage = error.localizedDescription
            }
        }

        let capture = ImmersiveInputCapture(
            keyEventHandler: keyEventHandler,
            workspaceSwipeHandler: workspaceSwipeHandler,
            usesNativeKeyboardMapping: usesKarabinerInput
        )
        inputCapture = capture
        requiresAccessibilityPermission = !capture.start()
        if requiresAccessibilityPermission {
            fallbackEventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown]
            ) { [weak self] event in
                if Self.isExitShortcut(event) {
                    Task { @MainActor in self?.exit() }
                    return nil
                }
                return event
            }
        }

        if !window.styleMask.contains(.fullScreen) {
            enteredFullScreen = true
            window.toggleFullScreen(nil)
        }
        fullScreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard self?.activeMachineID != nil else { return }
                self?.exit()
            }
        }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.inputCapture?.setEnabled(false)
                self?.releaseKeysHandler?()
            }
        }
        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      let inputCapture = self.inputCapture else {
                    return
                }
                if self.requiresAccessibilityPermission {
                    if inputCapture.start() {
                        self.requiresAccessibilityPermission = false
                        self.removeFallbackEventMonitor()
                    }
                } else {
                    inputCapture.setEnabled(true)
                }
                if usesKarabinerInput {
                    if KarabinerInputBridge.setImmersionActive(true) {
                        self.karabinerErrorMessage = nil
                    } else {
                        do {
                            try KarabinerInputBridge.prepare()
                            guard KarabinerInputBridge.setImmersionActive(
                                true
                            ) else {
                                throw KarabinerBridgeError.commandFailed(
                                    "Unable to activate SimpleVM mappings."
                                )
                            }
                            self.karabinerErrorMessage = nil
                        } catch {
                            self.karabinerErrorMessage =
                                error.localizedDescription
                        }
                    }
                }
            }
        }
        exitObserver = NotificationCenter.default.addObserver(
            forName: .simpleVMExitImmersion,
            object: capture,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.exit()
            }
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.showsExitHint = false
        }
    }

    func exit() {
        guard activeMachineID != nil else { return }
        inputCapture?.stop()
        inputCapture = nil
        KarabinerInputBridge.setImmersionActive(false)
        removeFallbackEventMonitor()
        releaseKeysHandler?()
        releaseKeysHandler = nil
        removeObservers()

        let window = window
        self.window = nil
        activeMachineID = nil
        showsExitHint = false
        requiresAccessibilityPermission = false
        karabinerErrorMessage = nil
        KeyboardMappingSettings.shared.deactivate()
        window?.toolbar?.isVisible = true

        if enteredFullScreen, window?.styleMask.contains(.fullScreen) == true {
            window?.toggleFullScreen(nil)
        }
        enteredFullScreen = false
    }

    func isActive(machineID: UUID) -> Bool {
        activeMachineID == machineID
    }

    func beginPointerInteraction(
        modifiers: NSEvent.ModifierFlags
    ) {
        inputCapture?.beginPointerInteraction(modifiers: modifiers)
    }

    func endPointerInteraction() {
        inputCapture?.endPointerInteraction()
    }

    func openAccessibilitySettings() {
        ImmersiveInputCapture.requestAccessibilityAccess()
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    static func isExitShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(
            .deviceIndependentFlagsMask
        )
        return event.keyCode == 53
            && modifiers.contains([.control, .option, .command])
    }

    private func removeObservers() {
        for observer in [
            fullScreenObserver,
            resignActiveObserver,
            becomeActiveObserver,
            exitObserver
        ] {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        fullScreenObserver = nil
        resignActiveObserver = nil
        becomeActiveObserver = nil
        exitObserver = nil
    }

    private func removeFallbackEventMonitor() {
        if let fallbackEventMonitor {
            NSEvent.removeMonitor(fallbackEventMonitor)
            self.fallbackEventMonitor = nil
        }
    }
}
