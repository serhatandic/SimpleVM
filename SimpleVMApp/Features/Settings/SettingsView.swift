import SwiftUI

struct SettingsView: View {
    let storageURL: URL?

    var body: some View {
        Form {
            Section("Storage") {
                LabeledContent("Machine data") {
                    Text(storageURL?.path(percentEncoded: false) ?? "Initializing…")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

