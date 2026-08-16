import SimpleVMCore
import SwiftUI

@main
struct SimpleVMApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1_180, height: 760)

        Settings {
            SettingsView(storageURL: model.storageURL)
                .frame(width: 520)
        }
    }
}

