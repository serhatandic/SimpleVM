import SimpleVMCore
import SwiftUI

@main
struct SimpleVMApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self)
    private var lifecycleDelegate

    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 960, minHeight: 640)
                .task {
                    lifecycleDelegate.hasActiveMachines = {
                        model.hasActiveMachines
                    }
                    lifecycleDelegate.stopActiveMachines = {
                        await model.stopAllMachinesGracefully()
                    }
                    lifecycleDelegate.forceStopActiveMachines = {
                        await model.forceStopAllMachines()
                    }
                }
        }
        .defaultSize(width: 1_180, height: 760)

        Settings {
            SettingsView(model: model)
                .frame(width: 520)
        }
    }
}
