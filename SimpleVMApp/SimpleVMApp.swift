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
                        await model.stopAllMachines()
                    }
                }
        }
        .defaultSize(width: 1_180, height: 760)

        Settings {
            SettingsView(storageURL: model.storageURL)
                .frame(width: 520)
        }
    }
}
