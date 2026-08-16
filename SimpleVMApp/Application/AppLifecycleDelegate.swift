import AppKit

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    var hasActiveMachines: (() -> Bool)?
    var stopActiveMachines: (() async -> Void)?

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
            await stopActiveMachines()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
