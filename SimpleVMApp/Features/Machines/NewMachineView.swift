import AppKit
import SimpleVMCore
import SwiftUI
import UniformTypeIdentifiers
import Virtualization

struct NewMachineView: View {
    @Bindable var model: AppModel
    let onCreated: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var operatingSystem = GuestOperatingSystem.linux
    @State private var name = "Linux"
    @State private var cpuCount = min(4, ProcessInfo.processInfo.processorCount)
    @State private var memoryGiB = 4
    @State private var diskGiB = 64
    @State private var inputProfile = MachineInputProfile.automatic
    @State private var source: MachineCreationSource?
    @State private var sharedDirectoryPath: String?
    @State private var rosettaEnabled = false
    @State private var bootProfileID: String?
    @State private var enablesPortForward = false
    @State private var hostPort = 8_080
    @State private var guestPort = 80
    @State private var windowsSupportToolsAttached = true
    @State private var pendingISO: PendingLocalISO?
    @State private var isImporting = false
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Machine")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(20)

            Divider()

            Form {
                Section("Operating System") {
                    Picker("Operating system", selection: $operatingSystem) {
                        ForEach(GuestOperatingSystem.allCases) { system in
                            Text(system.displayName).tag(system)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("newMachine.operatingSystem")
                }
                sourceSection
                configurationSection
                sharedDirectorySection
                platformSections
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if isCreating {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Preparing machine")
                    if operatingSystem == .windows {
                        Text(windowsPreparationStatus)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Create") {
                    createMachine()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(source == nil || isImporting || isCreating)
            }
            .padding(20)
        }
        .frame(width: 640, height: 720)
        .onAppear {
            selectInitialSource()
        }
        .onChange(of: operatingSystem) { _, system in
            applyDefaults(for: system)
        }
    }

    private var sourceSection: some View {
        Section {
            Picker("Installer", selection: $source) {
                Text("Select an installer")
                    .tag(MachineCreationSource?.none)
                if !availableImages.isEmpty {
                    Section("Library") {
                        ForEach(availableImages) { image in
                            Text(image.displayName)
                                .tag(MachineCreationSource?.some(
                                    .managedImage(image.id)
                                ))
                        }
                    }
                }
                if !availableCatalogEntries.isEmpty {
                    Section("Catalog") {
                        ForEach(availableCatalogEntries) { entry in
                            Text(entry.displayName)
                                .tag(MachineCreationSource?.some(
                                    .catalogEntry(entry.id)
                                ))
                        }
                    }
                }
            }

            if operatingSystem == .windows {
                Link(
                    "Download Windows 11 ARM64 from Microsoft",
                    destination: URL(
                        string:
                            "https://www.microsoft.com/software-download/windows11arm64"
                    )!
                )
                Text(
                    "A valid Microsoft license is required. SimpleVM does not download, modify, or supply Windows."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Button("Import Local ISO…") {
                if let url = FilePicker.chooseFile(
                    allowedContentTypes: [
                        UTType(filenameExtension: "iso") ?? .data
                    ]
                ) {
                    inspectLocalISO(url)
                }
            }

            if let pendingISO {
                LabeledContent("Selected ISO", value: pendingISO.url.lastPathComponent)
                if operatingSystem == .windows {
                    LabeledContent("Architecture", value: "ARM64")
                    if !pendingISOIsCompatible {
                        Label(
                            "Windows 11 requires an ARM64 ISO.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                    }
                } else {
                    Picker(
                        "ISO architecture",
                        selection: pendingArchitectureBinding
                    ) {
                        ForEach(GuestArchitecture.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                }
                Button("Use \(pendingISO.url.lastPathComponent)") {
                    importPendingISO()
                }
                .disabled(isImporting || !pendingISOIsCompatible)
            }
        } header: {
            Text("Source")
        } footer: {
            Text(sourceFooter)
        }
    }

    private var configurationSection: some View {
        Section("Configuration") {
            TextField("Name", text: $name)
            Stepper(
                "\(cpuCount) CPU cores",
                value: $cpuCount,
                in: (
                    VZVirtualMachineConfiguration.minimumAllowedCPUCount
                        ... VZVirtualMachineConfiguration.maximumAllowedCPUCount
                )
            )
            Picker("Memory", selection: $memoryGiB) {
                ForEach(memoryChoices, id: \.self) {
                    Text("\($0) GB").tag($0)
                }
            }
            Stepper(
                "\(diskGiB) GB disk",
                value: $diskGiB,
                in: minimumDiskGiB...2_048,
                step: 8
            )
            if operatingSystem == .linux {
                Picker("Desktop and input profile", selection: $inputProfile) {
                    ForEach(linuxInputProfiles) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }
                Text(
                    "Automatic uses Hyprland mappings for known Omarchy or Hyprland machines and GNOME/Linux mappings otherwise."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                LabeledContent(
                    "Keyboard mapping",
                    value: MachineInputProfile.macOSWindows.displayName
                )
                Text(
                    "Windows 11 ARM64 runs x86 and x64 user-mode apps through Microsoft Prism. Apple Rosetta is not used."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var sharedDirectorySection: some View {
        Section {
            LabeledContent("Host folder") {
                Text(
                    sharedDirectoryPath.map {
                        URL(filePath: $0).lastPathComponent
                    } ?? "None"
                )
                .foregroundStyle(.secondary)
                Button("Choose…") {
                    sharedDirectoryPath = FilePicker.chooseDirectory()?
                        .path(percentEncoded: false)
                }
            }
        } header: {
            Text("Shared Directory")
        } footer: {
            if operatingSystem == .windows {
                Text(
                    "The folder appears in Windows after the optional SPICE integration tools are installed."
                )
            }
        }
    }

    @ViewBuilder
    private var platformSections: some View {
        if operatingSystem == .linux {
            if selectedArchitecture == .arm64 {
                Section("Compatibility") {
                    Toggle(
                        "Enable Rosetta for Intel Linux binaries",
                        isOn: $rosettaEnabled
                    )
                }
                if needsBootProfile {
                    Section("Linux Boot Profile") {
                        Picker("Kernel profile", selection: $bootProfileID) {
                            ForEach(compatibleBootProfiles) { profile in
                                Text(profile.name)
                                    .tag(String?.some(profile.id))
                            }
                        }
                    }
                }
            }
        } else {
            Section {
                Toggle(
                    "Attach verified ARM64 drivers and integration tools",
                    isOn: $windowsSupportToolsAttached
                )
                LabeledContent("Support media", value: windowsToolsStatus)
            } header: {
                Text("Windows Integration")
            } footer: {
                Text(
                    "SimpleVM verifies the pinned UTM image, removes its unattended policy, and attaches driver-only media. Windows Setup remains interactive."
                )
            }
        }

        if selectedBackend == .qemu {
            Section("Networking") {
                Toggle("Forward a TCP port", isOn: $enablesPortForward)
                if enablesPortForward {
                    TextField(
                        "Host port",
                        value: $hostPort,
                        format: .number
                    )
                    TextField(
                        "Guest port",
                        value: $guestPort,
                        format: .number
                    )
                }
            }
        }
    }

    private var availableImages: [MachineImage] {
        model.library.images.filter {
            $0.operatingSystem == operatingSystem
                && ($0.availability.isAvailable
                    || $0.artifactKind == .ociReference)
                && (operatingSystem == .linux
                    || $0.artifactKind == .installerISO)
        }
    }

    private var availableCatalogEntries: [ImageCatalogEntry] {
        model.library.catalog.filter {
            $0.operatingSystem == operatingSystem
        }
    }

    private var selectedImage: MachineImage? {
        guard case .managedImage(let id) = source else { return nil }
        return model.library.images.first { $0.id == id }
    }

    private var needsBootProfile: Bool {
        operatingSystem == .linux
            && (
                selectedImage?.artifactKind == .rootfsArchive
                    || selectedImage?.artifactKind == .ociReference
            )
    }

    private var compatibleBootProfiles: [LinuxBootProfile] {
        model.library.bootProfiles.filter {
            $0.architecture == selectedArchitecture
        }
    }

    private var selectedArchitecture: GuestArchitecture? {
        switch source {
        case .managedImage(let id):
            model.library.images.first(where: { $0.id == id })?.architecture
        case .catalogEntry(let id):
            model.library.catalog.first(where: { $0.id == id })?.architecture
        case nil:
            nil
        }
    }

    private var selectedBackend: VirtualizationBackendKind? {
        guard let selectedArchitecture else { return nil }
        return try? VirtualizationBackendKind.resolve(
            operatingSystem: operatingSystem,
            architecture: selectedArchitecture
        )
    }

    private var pendingISOIsCompatible: Bool {
        guard let pendingISO else { return false }
        return operatingSystem == .linux || pendingISO.architecture == .arm64
    }

    private var pendingArchitectureBinding: Binding<GuestArchitecture> {
        Binding(
            get: { pendingISO?.architecture ?? .arm64 },
            set: { pendingISO?.architecture = $0 }
        )
    }

    private var linuxInputProfiles: [MachineInputProfile] {
        MachineInputProfile.allCases.filter { $0 != .macOSWindows }
    }

    private var memoryChoices: [Int] {
        operatingSystem == .windows
            ? [4, 8, 16, 32, 64]
            : [2, 4, 8, 16, 32, 64]
    }

    private var minimumDiskGiB: Int {
        operatingSystem == .windows ? 64 : 16
    }

    private var sourceFooter: String {
        switch operatingSystem {
        case .linux:
            "ARM64 EFI installer media uses native Apple Virtualization."
        case .windows:
            "Windows 11 ARM64 uses QEMU with Apple hardware virtualization, TPM 2.0, and ARM UEFI."
        }
    }

    private var windowsToolsStatus: String {
        switch model.windowsSupportToolsState {
        case .notDownloaded:
            "Downloads during creation"
        case .downloading(let progress):
            "Downloading \(Int(progress * 100))%"
        case .verifying:
            "Verifying"
        case .building:
            "Preparing safe media"
        case .ready(let version):
            "Ready (\(version))"
        case .failed:
            "Retry during creation"
        }
    }

    private var windowsPreparationStatus: String {
        switch model.windowsSupportToolsState {
        case .downloading(let progress):
            "Downloading verified drivers (\(Int(progress * 100))%)"
        case .verifying:
            "Verifying Windows support media"
        case .building:
            "Building safe driver media"
        default:
            "Preparing Windows 11"
        }
    }

    private func applyDefaults(for system: GuestOperatingSystem) {
        source = nil
        pendingISO = nil
        errorMessage = nil
        rosettaEnabled = false
        inputProfile = .automatic
        switch system {
        case .linux:
            name = "Linux"
            memoryGiB = 4
            diskGiB = 64
        case .windows:
            name = "Windows 11"
            memoryGiB = 8
            diskGiB = 128
        }
        selectInitialSource()
    }

    private func selectInitialSource() {
        if let image = availableImages.first {
            source = .managedImage(image.id)
            name = image.name
        } else if let entry = availableCatalogEntries.first {
            source = .catalogEntry(entry.id)
            name = entry.name
        }
        selectInitialBootProfile()
    }

    private func selectInitialBootProfile() {
        if bootProfileID == nil {
            bootProfileID = compatibleBootProfiles.first?.id
        }
    }

    private func inspectLocalISO(_ url: URL) {
        Task {
            do {
                let detection = try await model.library.detectArchitecture(at: url)
                let architecture: GuestArchitecture
                switch detection {
                case .architecture(let detected):
                    architecture = detected
                case .ambiguous, .unknown:
                    architecture = .arm64
                }
                pendingISO = PendingLocalISO(
                    url: url,
                    architecture: architecture
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importPendingISO() {
        guard let pendingISO, pendingISOIsCompatible else { return }
        isImporting = true
        errorMessage = nil

        Task {
            do {
                let imageID = try await model.library.importISO(
                    from: pendingISO.url,
                    operatingSystem: operatingSystem,
                    architecture: pendingISO.architecture
                )
                source = .managedImage(imageID)
                name = pendingISO.url.deletingPathExtension().lastPathComponent
                self.pendingISO = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            isImporting = false
        }
    }

    private func createMachine() {
        guard let source else { return }
        isCreating = true
        errorMessage = nil

        Task {
            do {
                let machineID = try await model.createMachine(
                    name: name,
                    cpuCount: cpuCount,
                    memorySizeBytes:
                        UInt64(memoryGiB) * 1_024 * 1_024 * 1_024,
                    diskSizeBytes:
                        UInt64(diskGiB) * 1_024 * 1_024 * 1_024,
                    source: source,
                    sharedDirectoryPath: sharedDirectoryPath,
                    rosettaEnabled:
                        operatingSystem == .linux && rosettaEnabled,
                    bootProfileID: bootProfileID,
                    portForwards: enablesPortForward
                        ? [
                            PortForward(
                                hostPort: UInt16(clamping: hostPort),
                                guestPort: UInt16(clamping: guestPort)
                            )
                        ]
                        : [],
                    inputProfile: operatingSystem == .windows
                        ? .automatic
                        : inputProfile,
                    windowsSupportToolsAttached:
                        operatingSystem == .windows
                            && windowsSupportToolsAttached
                )
                onCreated(machineID)
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}

private struct PendingLocalISO {
    let url: URL
    var architecture: GuestArchitecture
}

private extension MachineImage {
    var displayName: String {
        [name, version].compactMap { $0 }.joined(separator: " ")
    }
}

private extension ImageCatalogEntry {
    var displayName: String {
        [name, version].compactMap { $0 }.joined(separator: " ")
    }
}
