import SimpleVMCore
import SwiftUI

struct MachineDetailView: View {
    @Bindable var model: AppModel
    let machine: Machine
    let immersion: ImmersionController

    @State private var confirmsDeletion = false

    private var runtimeState: MachineRuntimeState {
        model.runtimeState(for: machine)
    }

    var body: some View {
        Group {
            if immersion.isActive(machineID: machine.id) {
                display
                    .ignoresSafeArea()
                    .overlay(alignment: .top) {
                        if immersion.requiresAccessibilityPermission
                            || immersion.showsExitHint {
                            VStack(spacing: 8) {
                                if immersion.requiresAccessibilityPermission {
                                    HStack {
                                        Text(
                                            "Accessibility permission is required for system shortcuts and workspace swipes."
                                        )
                                        .foregroundStyle(.orange)
                                        Button("Open Settings") {
                                            immersion.openAccessibilitySettings()
                                        }
                                        Button("Exit Immersion") {
                                            immersion.exit()
                                        }
                                    }
                                } else {
                                    Text(
                                        "\(ImmersionController.exitShortcutDescription) to exit immersion"
                                    )
                                }
                            }
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.ultraThickMaterial, in: Capsule())
                            .padding(.top, 16)
                        }
                    }
            } else {
                VStack(spacing: 0) {
                    display
                    Divider()
                    statusBar
                }
            }
        }
        .navigationTitle(machine.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                lifecycleControls
                Button {
                    enterImmersion()
                } label: {
                        Label(
                            "Enter Immersion",
                            systemImage: "arrow.up.left.and.arrow.down.right"
                        )
                    }

                .disabled(runtimeState != .running)
                Menu {
                    if runtimeState == .running || runtimeState == .stopping {
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
                        .disabled(runtimeState != .stopped)
                    }
                    Button("Create Snapshot") {
                        Task {
                            await model.createSnapshot(machine)
                        }
                    }
                    .disabled(runtimeState != .stopped)
                    Button("Clone Machine") {
                        Task {
                            await model.cloneMachine(machine)
                        }
                    }
                    .disabled(runtimeState != .stopped)
                    if let machineSnapshots = model.snapshots[machine.id],
                       !machineSnapshots.isEmpty {
                        Menu("Snapshots") {
                            ForEach(machineSnapshots) { snapshot in
                                Menu(snapshot.name) {
                                    Button("Restore") {
                                        Task {
                                            await model.restoreSnapshot(
                                                snapshot,
                                                machine: machine
                                            )
                                        }
                                    }
                                    Button("Delete", role: .destructive) {
                                        Task {
                                            await model.deleteSnapshot(
                                                snapshot,
                                                machine: machine
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Delete Machine", role: .destructive) {
                        confirmsDeletion = true
                    }
                    .disabled(runtimeState != .stopped)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Machine actions")
            }
        }
        .onChange(of: runtimeState) { _, state in
            if immersion.isActive(machineID: machine.id),
               state != .running {
                immersion.exit()
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
            switch machine.backend {
            case .appleVirtualization:
                if let virtualMachine = model.appleRuntime(
                    for: machine
                ).virtualMachine {
                    MachineDisplayView(
                        virtualMachine: virtualMachine,
                        runtime: model.appleRuntime(for: machine),
                        isImmersive: immersion.isActive(
                            machineID: machine.id
                        ),
                        pointerInteractionHandler: { active, modifiers in
                            if active {
                                immersion.beginPointerInteraction(
                                    modifiers: modifiers
                                )
                            } else {
                                immersion.endPointerInteraction()
                            }
                        }
                    )
                } else {
                    stoppedContent
                }
            case .qemu:
                let runtime = model.qemuRuntime(for: machine)
                if let framebuffer = runtime.framebuffer {
                    QEMUMachineDisplayView(
                        image: framebuffer,
                        runtime: runtime,
                        isImmersive: immersion.isActive(
                            machineID: machine.id
                        ),
                        pointerInteractionHandler: { active, modifiers in
                            if active {
                                immersion.beginPointerInteraction(
                                    modifiers: modifiers
                                )
                            } else {
                                immersion.endPointerInteraction()
                            }
                        }
                    )
                    if runtime.requiresDiskPassword {
                        Text(
                            "Encrypted disk is waiting for its passphrase. Type it and press Return."
                        )
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThickMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .frame(
                            maxHeight: .infinity,
                            alignment: .bottom
                        )
                    }
                } else {
                    stoppedContent
                }
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
            StatusValue(title: "Status", value: runtimeState.title)
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

    private func enterImmersion() {
        switch machine.backend {
        case .appleVirtualization:
            let runtime = model.appleRuntime(for: machine)
            immersion.enter(
                machineID: machine.id,
                keyEventHandler: { event in
                    runtime.sendKeyEvent(event)
                },
                releaseKeysHandler: {
                    runtime.releaseAllKeys()
                }
            )
        case .qemu:
            let runtime = model.qemuRuntime(for: machine)
            immersion.enter(
                machineID: machine.id,
                keyEventHandler: { event in
                    runtime.sendKeyEvent(event)
                },
                releaseKeysHandler: {
                    runtime.releaseAllKeys()
                }
            )
        }
    }

    @ViewBuilder
    private var lifecycleControls: some View {
        switch runtimeState {
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
                Task {
                    await model.requestStop(machine)
                }
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
