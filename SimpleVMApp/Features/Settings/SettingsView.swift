import SimpleVMCore
import AppKit
import SwiftUI
import Virtualization

struct SettingsView: View {
    let storageURL: URL?
    @State private var mappingReference = MachineInputProfile.macOSGNOME

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
                LabeledContent(
                    "VZ Keyboard Mapping",
                    value: KarabinerInputBridge.isInstalled
                        ? "Virtual HID ready"
                        : "Install Karabiner-Elements"
                )
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
                Text(
                    "Desktop and input profiles are configured per machine from the machine actions menu."
                )
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

            Section("Keyboard Mapping Reference") {
                Picker("Profile to preview", selection: $mappingReference) {
                    ForEach(
                        MachineInputProfile.allCases.filter {
                            $0 != .automatic
                        }
                    ) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }
                ForEach(
                    Array(
                        KeyboardMappingSettings.shared.mappingDescriptions(
                            for: mappingReference
                        ).enumerated()
                    ),
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
        if FileManager.default.fileExists(
            atPath:
                "/Applications/UTM.app/Contents/Frameworks/qemu-x86_64-softmmu.framework/qemu-x86_64-softmmu"
        ) {
            "Accelerated SPICE / Metal"
        } else {
            qemuAvailable ? "Software display" : "Install QEMU"
        }
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
