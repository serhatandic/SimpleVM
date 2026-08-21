import AppKit
import SimpleVMCore
import SwiftUI
import UniformTypeIdentifiers

struct MachineDetailView: View {
    @Bindable var model: AppModel
    let machine: Machine
    let immersion: ImmersionController

    @State private var confirmsDeletion = false
    @State private var confirmsForceStop = false
    @State private var showsGuestTools = false
    @State private var deliveredToolsMessage: String?
    @State private var pendingWindowsOperation: WindowsProtectedOperation?
    @State private var keyboardProfiles = KeyboardProfileStore.shared
    @State private var showsKeystrokePanel = false

    private var runtimeState: MachineRuntimeState {
        model.runtimeState(for: machine)
    }

    private var diskOperationsDisabled: Bool {
        runtimeState != .stopped
            || model.exportingMachineIDs.contains(machine.id)
            || model.startingMachineIDs.contains(machine.id)
    }

    var body: some View {
        Group {
            if immersion.isActive(machineID: machine.id) {
                display
                    .ignoresSafeArea()
                    .overlay(alignment: .top) {
                        if immersion.requiresAccessibilityPermission
                            || immersion.karabinerErrorMessage != nil
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
                                } else if let message =
                                    immersion.karabinerErrorMessage {
                                    HStack {
                                        Text(message)
                                            .foregroundStyle(.orange)
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
                    if showsKeystrokePanel {
                        Divider()
                        VMKeystrokePanel(
                            isRunning: runtimeState == .running,
                            sendChord: sendInjectedChord
                        )
                    }
                    Divider()
                    statusBar
                }
            }
        }
        .navigationTitle(machine.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showsKeystrokePanel.toggle()
                } label: {
                    Label(
                        "Send Keystrokes",
                        systemImage: "keyboard.badge.ellipsis"
                    )
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .accessibilityIdentifier("vmInput.toggle")
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
                        Button("Force Power Off…", role: .destructive) {
                            confirmsForceStop = true
                        }
                        Divider()
                    }
                    Menu("Desktop and Input Profile") {
                        ForEach(availableInputProfiles) { profile in
                            Button {
                                Task {
                                    await model.setInputProfile(
                                        profile,
                                        for: machine
                                    )
                                }
                            } label: {
                                if machine.spec.customInputProfileID == nil,
                                   machine.spec.inputProfile == profile {
                                    Label(
                                        profile.displayName,
                                        systemImage: "checkmark"
                                    )
                                } else {
                                    Text(profile.displayName)
                                }
                            }
                        }
                        if machine.spec.inputProfile == .automatic {
                            Divider()
                            Text(
                                "Active: \(resolvedInputProfile.displayName)"
                            )
                        }
                        if !keyboardProfiles.profiles.isEmpty {
                            Divider()
                            ForEach(keyboardProfiles.profiles) { profile in
                                Button {
                                    Task {
                                        await model.setCustomInputProfile(
                                            profile,
                                            for: machine
                                        )
                                    }
                                } label: {
                                    if machine.spec.customInputProfileID
                                        == profile.id {
                                        Label(
                                            profile.name,
                                            systemImage: "checkmark"
                                        )
                                    } else {
                                        Text(profile.name)
                                    }
                                }
                            }
                        }
                    }
                    Button(
                        machine.spec.operatingSystem == .windows
                            ? "Windows Integration..."
                            : "Guest Tools Setup..."
                    ) {
                        showsGuestTools = true
                    }
                    if machine.hasInstallerAttached {
                        Button("Eject Installer") {
                            Task {
                                await model.ejectInstaller(machine)
                            }
                        }
                        .disabled(diskOperationsDisabled)
                    }
                    if sourceInstallerImage != nil {
                        Button("Export Source ISO…") {
                            exportSourceISO()
                        }
                    }
                    Button("Create Snapshot") {
                        performProtected(.snapshot)
                    }
                    .disabled(diskOperationsDisabled)
                    Button("Clone Machine") {
                        performProtected(.clone)
                    }
                    .disabled(diskOperationsDisabled)
                    Button {
                        performProtected(.exportDisk)
                    } label: {
                        Label(
                            model.exportingMachineIDs.contains(machine.id)
                                ? "Exporting Disk..."
                                : "Export Disk...",
                            systemImage:
                                model.exportingMachineIDs.contains(machine.id)
                                    ? "progress.indicator"
                                    : "square.and.arrow.up"
                        )
                    }
                    .disabled(diskOperationsDisabled)
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
                                    .disabled(diskOperationsDisabled)
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
                    .disabled(diskOperationsDisabled)
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
        .confirmationDialog(
            "Force power off \(machine.name)?",
            isPresented: $confirmsForceStop,
            titleVisibility: .visible
        ) {
            Button("Force Power Off", role: .destructive) {
                Task {
                    await model.forceStop(machine)
                }
            }
        } message: {
            Text(
                "This cuts power immediately and can corrupt the guest disk, Windows updates, EFI variables, or TPM state."
            )
        }
        .confirmationDialog(
            "Save the Windows recovery key first",
            isPresented: windowsProtectionBinding,
            titleVisibility: .visible
        ) {
            Button("I Saved the Recovery Key") {
                UserDefaults.standard.set(
                    true,
                    forKey: windowsRecoveryAcknowledgmentKey
                )
                if let operation = pendingWindowsOperation {
                    execute(operation)
                }
                pendingWindowsOperation = nil
            }
            Button("Cancel", role: .cancel) {
                pendingWindowsOperation = nil
            }
        } message: {
            Text(
                "Windows can enable Device Encryption automatically. Snapshots, clones, and disk-only exports may require the BitLocker recovery key after virtual hardware or TPM state changes. SimpleVM never collects the key."
            )
        }
        .popover(isPresented: $showsGuestTools) {
            if machine.spec.operatingSystem == .windows {
                WindowsIntegrationPanel(
                    model: model,
                    machine: machine,
                    runtimeState: runtimeState,
                    runtime: model.qemuRuntime(for: machine),
                    notice: deliveredToolsMessage,
                    chooseShare: chooseSharedFolder,
                    removeShare: removeSharedFolder,
                    restart: {
                        Task {
                            await model.requestReboot(machine)
                        }
                    }
                )
            } else {
                GuestToolsPanel(
                    machine: machine,
                    runtimeState: runtimeState,
                    state: guestTools.state,
                    notice: guestTools.notice,
                    deliveredMessage: deliveredToolsMessage,
                    retry: {
                        guestTools.retry()
                    },
                    exportBundle: exportGuestTools,
                    copyToShare: copyGuestToolsToShare,
                    chooseShare: chooseSharedFolder,
                    removeShare: removeSharedFolder,
                    reboot: {
                        Task {
                            await model.requestReboot(machine)
                        }
                    }
                )
            }
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
                if runtime.hasDisplay {
                    if runtime.usesAcceleratedDisplay {
                        SPICEMachineDisplayView(
                            runtime: runtime,
                            isImmersive: immersion.isActive(
                                machineID: machine.id
                            ),
                            pointerInteractionHandler: {
                                active,
                                modifiers in
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
                        QEMUMachineDisplayView(
                            runtime: runtime,
                            isImmersive: immersion.isActive(
                                machineID: machine.id
                            ),
                            pointerInteractionHandler: {
                                active,
                                modifiers in
                                if active {
                                    immersion.beginPointerInteraction(
                                        modifiers: modifiers
                                    )
                                } else {
                                    immersion.endPointerInteraction()
                                }
                            }
                        )
                    }
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
            if machine.spec.operatingSystem == .windows,
               machine.hasInstallerAttached,
               runtimeState == .running {
                Text(
                    "Click inside the display and press any key now to start Windows Setup."
                )
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThickMaterial, in: Capsule())
                .padding(.top, 18)
                .frame(maxHeight: .infinity, alignment: .top)
                .accessibilityIdentifier("windows.firstBootPrompt")
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
            if machine.spec.operatingSystem == .windows,
               machine.hasInstallerAttached,
               machine.provisioningState == .installing {
                Button("Windows Is Installed — Eject Installer") {
                    Task {
                        await model.ejectInstaller(machine)
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("windows.ejectInstaller")
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
            StatusValue(title: "Profile", value: inputProfileStatus)
            Button {
                showsGuestTools.toggle()
            } label: {
                StatusValue(
                    title: machine.spec.operatingSystem == .windows
                        ? "Integration"
                        : "Guest Tools",
                    value: machine.spec.operatingSystem == .windows
                        ? windowsIntegrationStatus
                        : guestToolsStatus
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                machine.spec.operatingSystem == .windows
                    ? "Windows integration status: \(windowsIntegrationStatus)"
                    : "Guest Tools status: \(guestToolsStatus)"
            )
            .accessibilityIdentifier(
                machine.spec.operatingSystem == .windows
                    ? "windowsIntegration.status"
                    : "guestTools.status"
            )
            StatusValue(title: "Network", value: "Shared NAT")
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func enterImmersion() {
        showsKeystrokePanel = false
        KeyboardMappingSettings.shared.activate(
            profile: resolvedInputProfile,
            forMachineNamed: machine.name,
            customProfile: selectedCustomInputProfile
        )
        switch machine.backend {
        case .appleVirtualization:
            let runtime = model.appleRuntime(for: machine)
            immersion.enter(
                machineID: machine.id,
                keyEventHandler: { event in
                    runtime.sendGuestKeyEvent(event)
                },
                releaseKeysHandler: {
                    runtime.releaseAllKeys()
                },
                workspaceSwipeHandler: { direction in
                    runtime.sendWorkspaceSwipe(direction)
                },
                usesKarabinerInput: true
            )
        case .qemu:
            let runtime = model.qemuRuntime(for: machine)
            immersion.enter(
                machineID: machine.id,
                keyEventHandler: { event in
                    runtime.sendGuestKeyEvent(event)
                },
                releaseKeysHandler: {
                    runtime.releaseAllKeys()
                },
                workspaceSwipeHandler: { direction in
                    runtime.sendWorkspaceSwipe(direction)
                },
                usesKarabinerInput: false
            )
        }
    }

    private func sendInjectedChord(_ chord: GuestChord) {
        let router: GuestInputRouter
        switch machine.backend {
        case .appleVirtualization:
            let runtime = model.appleRuntime(for: machine)
            router = GuestInputRouter { event in
                runtime.sendInjectedKeyEvent(event)
            }
        case .qemu:
            let runtime = model.qemuRuntime(for: machine)
            router = GuestInputRouter { event in
                runtime.sendGuestKeyEvent(event)
            }
        }
        router.sendChord(chord)
    }

    private var resolvedInputProfile: MachineInputProfile {
        switch machine.backend {
        case .appleVirtualization:
            model.appleRuntime(for: machine).guestTools.resolvedInputProfile(
                configuredProfile: machine.spec.inputProfile,
                machineName: machine.name,
                operatingSystem: machine.spec.operatingSystem
            )
        case .qemu:
            model.qemuRuntime(for: machine).guestTools.resolvedInputProfile(
                configuredProfile: machine.spec.inputProfile,
                machineName: machine.name,
                operatingSystem: machine.spec.operatingSystem
            )
        }
    }

    private var inputProfileStatus: String {
        if let selectedCustomInputProfile {
            return selectedCustomInputProfile.name
        }
        if machine.spec.inputProfile == .automatic {
            return "Automatic (\(resolvedInputProfile.displayName))"
        }
        return resolvedInputProfile.displayName
    }

    private var selectedCustomInputProfile: CustomKeyboardProfile? {
        keyboardProfiles.profile(id: machine.spec.customInputProfileID)
    }

    private var availableInputProfiles: [MachineInputProfile] {
        if machine.spec.operatingSystem == .windows {
            return [.automatic, .macOSWindows]
        }
        return MachineInputProfile.allCases.filter { $0 != .macOSWindows }
    }

    private var guestTools: GuestToolsCoordinator {
        switch machine.backend {
        case .appleVirtualization:
            model.appleRuntime(for: machine).guestTools
        case .qemu:
            model.qemuRuntime(for: machine).guestTools
        }
    }

    private var guestToolsStatus: String {
        switch guestTools.state {
        case .stopped:
            "Stopped"
        case .checking:
            "Checking..."
        case .notConnected:
            "Not connected"
        case .connected:
            "Connected"
        case .incompatible:
            "Incompatible"
        case .failed:
            "Error"
        }
    }

    private var windowsIntegrationStatus: String {
        let runtime = model.qemuRuntime(for: machine)
        if runtime.windowsAgentConnected {
            return "Connected"
        }
        return machine.spec.windowsSupportToolsAttached
            ? "Tools attached"
            : "Not attached"
    }

    private func exportGuestTools() {
        guard let destinationURL = FilePicker.chooseSaveFile(
            suggestedName: GuestToolsBundleExporter.archiveName,
            allowedContentType:
                UTType(filenameExtension: "gz") ?? .archive
        ) else {
            return
        }
        Task {
            do {
                try await model.exportGuestTools(to: destinationURL)
                deliveredToolsMessage =
                    "Exported to \(destinationURL.lastPathComponent). Move the archive into the guest, then run the shown command from its folder."
            } catch {
                model.present(error: error)
            }
        }
    }

    private func copyGuestToolsToShare() {
        Task {
            do {
                let destinationURL =
                    try await model.copyGuestToolsToSharedDirectory(
                        for: machine
                    )
                deliveredToolsMessage =
                    "Copied \(destinationURL.lastPathComponent) to the configured shared folder. Restart the VM if this folder was just configured, then run the shown guest command."
            } catch {
                model.present(error: error)
            }
        }
    }

    private func chooseSharedFolder() {
        guard let url = FilePicker.chooseDirectory() else { return }
        let path = url.path(percentEncoded: false)
        Task {
            await model.setSharedDirectory(path, for: machine)
            if model.machines.first(where: { $0.id == machine.id })?
                .spec.sharedDirectoryPath == path {
                if machine.spec.operatingSystem == .windows {
                    let live = runtimeState == .running
                        && model.qemuRuntime(for: machine)
                            .windowsWebDAVAvailable
                    deliveredToolsMessage = live
                        ? "Sharing \(url.lastPathComponent) through SPICE WebDAV."
                        : "Configured \(url.lastPathComponent). Restart Windows to attach the WebDAV channel."
                } else {
                    deliveredToolsMessage =
                        "Configured \(url.lastPathComponent) as the shared folder. Restart the VM to attach it, then copy the tools bundle."
                }
            }
        }
    }

    private func removeSharedFolder() {
        Task {
            await model.setSharedDirectory(nil, for: machine)
            if model.machines.first(where: { $0.id == machine.id })?
                .spec.sharedDirectoryPath == nil {
                let revokedLive = machine.spec.operatingSystem == .windows
                    && runtimeState == .running
                    && model.qemuRuntime(for: machine)
                        .windowsWebDAVAvailable
                deliveredToolsMessage = revokedLive
                    ? "Shared-folder access was removed from the running Windows session."
                    : "The shared folder will be detached the next time this VM starts."
            }
        }
    }


    private func exportDisk() {
        let sanitizedName = machine.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let baseName = sanitizedName.isEmpty ? "SimpleVM Disk" : sanitizedName
        guard let destinationURL = FilePicker.chooseSaveFile(
            suggestedName: "\(baseName).raw",
            allowedContentType:
                UTType(filenameExtension: "raw") ?? .data
        ) else {
            return
        }
        Task {
            do {
                try await model.exportMachineDisk(
                    machine,
                    to: destinationURL
                )
                NSWorkspace.shared.activateFileViewerSelecting(
                    [destinationURL]
                )
            } catch {
                model.present(error: error)
            }
        }
    }

    private var sourceInstallerImage: MachineImage? {
        model.library.images.first {
            $0.id == machine.sourceImageID
                && $0.artifactKind == .installerISO
                && $0.availability.isAvailable
        }
    }

    private func exportSourceISO() {
        guard let image = sourceInstallerImage,
              let suggestedName = image.suggestedExportFileName,
              let destinationURL = FilePicker.chooseSaveFile(
                  suggestedName: suggestedName,
                  allowedContentType:
                      UTType(filenameExtension: "iso") ?? .data
              ) else {
            return
        }
        Task {
            do {
                try await model.library.exportImage(
                    image,
                    to: destinationURL
                )
                NSWorkspace.shared.activateFileViewerSelecting(
                    [destinationURL]
                )
            } catch {
                model.present(error: error)
            }
        }
    }

    private var windowsProtectionBinding: Binding<Bool> {
        Binding(
            get: { pendingWindowsOperation != nil },
            set: { presented in
                if !presented {
                    pendingWindowsOperation = nil
                }
            }
        )
    }

    private var windowsRecoveryAcknowledgmentKey: String {
        "windowsRecoveryKeySaved.\(machine.id.uuidString)"
    }

    private func performProtected(_ operation: WindowsProtectedOperation) {
        guard machine.spec.operatingSystem == .windows,
              !UserDefaults.standard.bool(
                forKey: windowsRecoveryAcknowledgmentKey
              ) else {
            execute(operation)
            return
        }
        pendingWindowsOperation = operation
    }

    private func execute(_ operation: WindowsProtectedOperation) {
        switch operation {
        case .snapshot:
            Task {
                await model.createSnapshot(machine)
            }
        case .clone:
            Task {
                await model.cloneMachine(machine)
            }
        case .exportDisk:
            exportDisk()
        }
    }

    @ViewBuilder
    private var lifecycleControls: some View {
        if model.startingMachineIDs.contains(machine.id) {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Preparing machine")
        } else {
            switch runtimeState {
            case .stopped, .failed:
                Button {
                    Task {
                        await model.start(machine)
                    }
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .disabled(
                    !machine.provisioningState.canStart
                        || model.exportingMachineIDs.contains(machine.id)
                )
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
                    confirmsForceStop = true
                } label: {
                    Label("Force Power Off…", systemImage: "stop.fill")
                }
            case .starting:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Starting machine")
            }
        }
    }
}

private enum WindowsProtectedOperation {
    case snapshot
    case clone
    case exportDisk
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
