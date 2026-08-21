import SimpleVMCore
import AppKit
import SwiftUI
import Virtualization

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var mappingReference = MachineInputProfile.macOSGNOME
    @State private var keyboardProfiles = KeyboardProfileStore.shared

    var body: some View {
        Form {
            Section("Storage") {
                LabeledContent("Machine data") {
                    Text(
                        model.storageURL?.path(percentEncoded: false)
                            ?? "Initializing…"
                    )
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Section("Virtualization") {
                LabeledContent(
                    "ARM64 Linux",
                    value: "Apple Virtualization"
                )
                LabeledContent("Windows 11 ARM64") {
                    Text(windowsRuntimeStatus)
                        .foregroundStyle(
                            windowsRuntimeAvailable
                                ? Color.secondary
                                : Color.red
                        )
                }
                LabeledContent("x86_64 Linux") {
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
                LabeledContent("Linux Rosetta") {
                    Text(rosettaStatus)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Windows support media") {
                    HStack {
                        Text(windowsToolsStatus)
                            .foregroundStyle(.secondary)
                        if case .ready = model.windowsSupportToolsState {
                            Button("Remove") {
                                Task {
                                    await model.removeWindowsSupportToolsCache()
                                }
                            }
                        } else {
                            Button("Prepare") {
                                Task {
                                    do {
                                        _ = try await model
                                            .prepareWindowsSupportTools()
                                    } catch {
                                        model.present(error: error)
                                    }
                                }
                            }
                        }
                    }
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
                Section("Custom Keyboard Profiles") {
                    KeyboardProfileEditor(
                        model: model,
                        store: keyboardProfiles
                    )
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
        (try? QEMURuntimeDiscovery.discover(
            for: .linux,
            architecture: .x86_64
        )) != nil
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

    private var windowsRuntimeAvailable: Bool {
        (try? QEMURuntimeDiscovery.discover(
            for: .windows,
            architecture: .arm64
        )) != nil
    }

    private var windowsRuntimeStatus: String {
        windowsRuntimeAvailable
            ? "QEMU / HVF / TPM ready"
            : "Install UTM and rebuild SimpleVM"
    }

    private var windowsToolsStatus: String {
        switch model.windowsSupportToolsState {
        case .notDownloaded:
            "Not prepared"
        case .downloading(let progress):
            "Downloading \(Int(progress * 100))%"
        case .verifying:
            "Verifying"
        case .building:
            "Building safe ISO"
        case .ready(let version):
            "Ready (\(version))"
        case .failed(let message):
            "Error: \(message)"
        }
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
