import AppKit

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    var hasActiveMachines: (() -> Bool)?
    var stopActiveMachines: (() async -> Bool)?
    var forceStopActiveMachines: (() async -> Void)?

    private var isTerminating = false

    func applicationWillTerminate(_ notification: Notification) {
        KarabinerInputBridge.setImmersionActive(false)
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard !isTerminating,
              hasActiveMachines?() == true,
              let stopActiveMachines else {
            return .terminateNow
        }

        isTerminating = true
        Task { @MainActor in
            if await stopActiveMachines() {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            let alert = NSAlert()
            alert.messageText = "Virtual machines are still running"
            alert.informativeText =
                "Windows may still be shutting down or installing updates. Force Power Off can corrupt guest disks and TPM state."
            alert.addButton(withTitle: "Cancel Quit")
            alert.addButton(withTitle: "Force Power Off and Quit")
            if alert.runModal() == .alertSecondButtonReturn {
                await self.forceStopActiveMachines?()
                sender.reply(toApplicationShouldTerminate: true)
            } else {
                self.isTerminating = false
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}
