import SimpleVMCore
import SwiftUI

struct MachineDetailView: View {
    @Bindable var model: AppModel
    let machine: Machine

    @State private var confirmsDeletion = false

    private var runtime: MachineRuntime {
        model.runtime(for: machine)
    }

    var body: some View {
        VStack(spacing: 0) {
            display
            Divider()
            statusBar
        }
        .navigationTitle(machine.name)
        .toolbar {
            ToolbarItemGroup {
                lifecycleControls
                Menu {
                    if runtime.state == .running || runtime.state == .stopping {
                        Button("Force Stop", role: .destructive) {
                            Task {
                                await model.forceStop(machine)
                            }
                        }
                        Divider()
                    }
                    if machine.hasInstallerAttached {
                        Button("Eject Installer") {
                            Task {
                                await model.ejectInstaller(machine)
                            }
                        }
                        .disabled(runtime.state != .stopped)
                    }
                    Divider()
                    Button("Delete Machine", role: .destructive) {
                        confirmsDeletion = true
                    }
                    .disabled(runtime.state != .stopped)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Machine actions")
            }
        }
        .confirmationDialog(
            "Delete \(machine.name)?",
            isPresented: $confirmsDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Machine", role: .destructive) {
                Task {
                    await model.deleteMachine(machine)
                }
            }
        } message: {
            Text("Its virtual disk and machine state will be permanently removed.")
        }
    }

    @ViewBuilder
    private var display: some View {
        ZStack {
            Color.black
            if let virtualMachine = runtime.virtualMachine {
                MachineDisplayView(virtualMachine: virtualMachine)
            } else {
                stoppedContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var stoppedContent: some View {
        VStack(spacing: 14) {
            Image(systemName: machine.provisioningState.symbolName)
                .font(.system(size: 44, weight: .light))
            Text(machine.provisioningState.title)
                .font(.headline)
            if let detail = machine.provisioningState.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            if let progress = machine.provisioningState.progress {
                ProgressView(value: progress)
                    .frame(width: 260)
                    .accessibilityValue("\(Int(progress * 100)) percent")
            }
        }
        .foregroundStyle(.white.opacity(0.82))
    }

    private var statusBar: some View {
        HStack(spacing: 28) {
            StatusValue(title: "Status", value: runtime.state.title)
            StatusValue(
                title: "CPU",
                value: "\(machine.spec.cpuCount) cores"
            )
            StatusValue(
                title: "Memory",
                value: ByteCountFormatter.string(
                    fromByteCount: Int64(machine.spec.memorySizeBytes),
                    countStyle: .memory
                )
            )
            StatusValue(
                title: "Disk",
                value: ByteCountFormatter.string(
                    fromByteCount: Int64(machine.spec.diskSizeBytes),
                    countStyle: .file
                )
            )
            StatusValue(title: "Network", value: "Shared NAT")
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    @ViewBuilder
    private var lifecycleControls: some View {
        switch runtime.state {
        case .stopped, .failed:
            Button {
                Task {
                    await model.start(machine)
                }
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            .disabled(!machine.provisioningState.canStart)
        case .running:
            Button {
                model.requestStop(machine)
            } label: {
                Label("Shut Down", systemImage: "stop.fill")
            }
        case .stopping:
            Button {
                Task {
                    await model.forceStop(machine)
                }
            } label: {
                Label("Force Stop", systemImage: "stop.fill")
            }
        case .starting:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Starting machine")
        }
    }
}

private struct StatusValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.callout)
        }
    }
}

private extension Machine {
    var hasInstallerAttached: Bool {
        if case .installer = bootMedia {
            return true
        }
        return false
    }
}

private extension MachineRuntimeState {
    var title: String {
        switch self {
        case .stopped:
            "Stopped"
        case .starting:
            "Starting"
        case .running:
            "Running"
        case .stopping:
            "Stopping"
        case .failed:
            "Error"
        }
    }
}

private extension MachineProvisioningState {
    var title: String {
        switch self {
        case .downloading:
            "Downloading installer"
        case .verifying:
            "Verifying installer"
        case .preparingDisk:
            "Preparing disk"
        case .readyToInstall:
            "Ready to install"
        case .installing:
            "Installing"
        case .ready:
            "Ready"
        case .failed:
            "Provisioning failed"
        }
    }

    var detail: String? {
        switch self {
        case .readyToInstall:
            "Start the machine to boot its installer."
        case .installing:
            "Complete installation in the guest, shut it down, then eject the installer."
        case .ready:
            "The installed system is ready to start."
        case .failed(let message):
            message
        default:
            nil
        }
    }

    var progress: Double? {
        if case .downloading(let progress) = self {
            return progress
        }
        return nil
    }

    var symbolName: String {
        switch self {
        case .downloading:
            "arrow.down.circle"
        case .verifying:
            "checkmark.shield"
        case .preparingDisk:
            "externaldrive"
        case .readyToInstall, .installing:
            "opticaldiscdrive"
        case .ready:
            "display"
        case .failed:
            "exclamationmark.triangle"
        }
    }

    var canStart: Bool {
        switch self {
        case .readyToInstall, .installing, .ready:
            true
        case .downloading, .verifying, .preparingDisk, .failed:
            false
        }
    }
}
