import SimpleVMCore
import SwiftUI

struct WindowsIntegrationPanel: View {
    @Bindable var model: AppModel
    let machine: Machine
    let runtimeState: MachineRuntimeState
    @Bindable var runtime: QEMUMachineRuntime
    let notice: String?
    let chooseShare: () -> Void
    let removeShare: () -> Void
    let restart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(
                    systemName: runtime.windowsAgentConnected
                        ? "checkmark.circle.fill"
                        : "wrench.and.screwdriver"
                )
                .foregroundStyle(
                    runtime.windowsAgentConnected ? .green : .secondary
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Windows Integration")
                        .font(.headline)
                        .accessibilityIdentifier("windowsIntegration.panel")
                    Text(integrationStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                statusRow("Support media", supportMediaStatus)
                statusRow(
                    "Clipboard",
                    runtime.windowsClipboardAvailable ? "Connected" : "Unavailable"
                )
                statusRow(
                    "Display resize",
                    runtime.windowsDisplayResizeAvailable
                        ? "Connected"
                        : "Unavailable"
                )
                statusRow(
                    "Shared folder",
                    machine.spec.sharedDirectoryPath.map {
                        URL(filePath: $0).lastPathComponent
                    } ?? "None"
                )
                statusRow(
                    "Display mode",
                    machine.spec.displayMode.displayName
                )
            }
            if let notice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            Text("Setup and recovery")
                .font(.subheadline.weight(.semibold))
            Text(
                "After Windows Setup finishes, open the “SimpleVM Drivers” CD and run utm-guest-tools.exe yourself. It is a third-party UTM installer; SimpleVM never runs it automatically."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button(
                    machine.spec.windowsSupportToolsAttached
                        ? "Detach Tools on Next Start"
                        : "Attach Verified Tools"
                ) {
                    Task {
                        await model.setWindowsSupportToolsAttached(
                            !machine.spec.windowsSupportToolsAttached,
                            for: machine
                        )
                    }
                }
                .disabled(runtimeState != .stopped)
                if case .failed = model.windowsSupportToolsState {
                    Button("Retry Download") {
                        Task {
                            do {
                                _ = try await model.prepareWindowsSupportTools()
                            } catch {
                                model.present(error: error)
                            }
                        }
                    }
                }
            }

            HStack {
                Button(
                    machine.spec.sharedDirectoryPath == nil
                        ? "Choose Shared Folder…"
                        : "Change Shared Folder…",
                    action: chooseShare
                )
                if machine.spec.sharedDirectoryPath != nil {
                    Button(
                        "Remove Shared Folder",
                        role: .destructive,
                        action: removeShare
                    )
                }
            }
            if runtimeState == .running {
                Button("Restart Windows", action: restart)
            }

            Picker(
                "Display recovery",
                selection: Binding(
                    get: { machine.spec.displayMode },
                    set: { mode in
                        Task {
                            await model.setDisplayMode(mode, for: machine)
                        }
                    }
                )
            ) {
                Text("Automatic").tag(MachineDisplayMode.automatic)
                Text("Compatibility").tag(MachineDisplayMode.compatibility)
            }
            .disabled(runtimeState != .stopped)
            Text(
                "Use Compatibility after stopping the VM if Windows remains black after a graphics-driver change."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 470)
    }

    private var integrationStatus: String {
        if runtime.windowsAgentConnected {
            return "SPICE tools connected"
        }
        return runtimeState == .running
            ? "Install or repair the tools from the attached CD"
            : "Start Windows to check installed tools"
    }

    private var supportMediaStatus: String {
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
            machine.spec.windowsSupportToolsAttached
                ? "Attached (\(version))"
                : "Ready (\(version))"
        case .failed:
            "Error"
        }
    }

    @ViewBuilder
    private func statusRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
        .font(.caption)
    }
}
