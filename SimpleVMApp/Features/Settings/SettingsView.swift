import SimpleVMCore
import SwiftUI
import Virtualization

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
