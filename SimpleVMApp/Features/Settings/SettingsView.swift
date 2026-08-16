import SimpleVMCore
import AppKit
import SwiftUI
import Virtualization

struct SettingsView: View {
    let storageURL: URL?
    @State private var keyboard = KeyboardMappingSettings.shared

    var body: some View {
        Form {
            Section("Storage") {
                LabeledContent("Machine data") {
                    Text(storageURL?.path(percentEncoded: false) ?? "Initializing…")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Section("Virtualization") {
                LabeledContent(
                    "Native ARM64",
                    value: "Apple Virtualization"
                )
                LabeledContent("x86_64 Compatibility") {
                    Text(qemuStatus)
                        .foregroundStyle(
                            qemuAvailable ? Color.secondary : Color.red
                        )
                }
                LabeledContent("RootFS / OCI Provisioning") {
                    Text(helperStatus)
                        .foregroundStyle(
                            helperAvailable ? Color.secondary : Color.red
                        )
                }
                LabeledContent("Rosetta") {
                    Text(rosettaStatus)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("Keyboard profile", selection: $keyboard.preset) {
                    ForEach(KeyboardPreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                LabeledContent(
                    "System input capture",
                    value: ImmersiveInputCapture.hasAccessibilityAccess
                        ? "Ready"
                        : "Accessibility permission required"
                )
                if !ImmersiveInputCapture.hasAccessibilityAccess {
                    Button("Open Accessibility Settings") {
                        ImmersiveInputCapture.requestAccessibilityAccess()
                        if let url = URL(
                            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                        ) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            } header: {
                Text("Immersion Input")
            } footer: {
                Text(
                    "Immersion captures system shortcuts and suppresses macOS workspace swipes. Control–Option–Command–Escape always exits."
                )
            }

            Section("Active Key Mappings") {
                ForEach(
                    Array(keyboard.mappingDescriptions.enumerated()),
                    id: \.offset
                ) { _, mapping in
                    LabeledContent(mapping.host, value: mapping.guest)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var qemuAvailable: Bool {
        (try? QEMURuntimeDiscovery.discover()) != nil
    }

    private var qemuStatus: String {
        qemuAvailable ? "Available" : "Install QEMU"
    }

    private var helperAvailable: Bool {
        (try? ProvisioningHelperClient.discover()) != nil
    }

    private var helperStatus: String {
        helperAvailable ? "Available" : "Run make build"
    }

    private var rosettaStatus: String {
        switch VZLinuxRosettaDirectoryShare.availability {
        case .installed:
            "Installed"
        case .notInstalled:
            "Available on demand"
        case .notSupported:
            "Not supported"
        @unknown default:
            "Unknown"
        }
    }
}
