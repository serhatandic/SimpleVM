import SimpleVMCore
import SwiftUI
import UniformTypeIdentifiers
import Virtualization

struct NewMachineView: View {
    @Bindable var model: AppModel
    let onCreated: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
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
                sourceSection
                configurationSection
                sharedDirectorySection
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
                                    Text(profile.name).tag(String?.some(profile.id))
                                }
                            }
                        }
                    }
                }
                if selectedArchitecture == .x86_64 {
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
            .formStyle(.grouped)

            Divider()

            HStack {
                if let errorMessage {
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
        .frame(width: 600, height: 650)
        .onAppear {
            selectInitialSource()
        }
    }

    private var sourceSection: some View {
        Section {
            Picker("Installer", selection: $source) {
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
                Section("Catalog") {
                    ForEach(model.library.catalog) { entry in
                        Text(entry.displayName)
                            .tag(MachineCreationSource?.some(
                                .catalogEntry(entry.id)
                            ))
                    }
                }
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
                Picker("ISO architecture", selection: pendingArchitectureBinding) {
                    ForEach(GuestArchitecture.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                Button("Use \(pendingISO.url.lastPathComponent)") {
                    importPendingISO()
                }
                .disabled(isImporting)
            }
        } header: {
            Text("Source")
        } footer: {
            Text("ARM64 EFI installer media uses native Apple Virtualization.")
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
                ForEach([2, 4, 8, 16, 32, 64], id: \.self) {
                    Text("\($0) GB").tag($0)
                }
            }
            Stepper(
                "\(diskGiB) GB disk",
                value: $diskGiB,
                in: 16...2_048,
                step: 8
            )
            Picker("Desktop and input profile", selection: $inputProfile) {
                ForEach(MachineInputProfile.allCases) { profile in
                    Text(profile.displayName).tag(profile)
                }
            }
            Text(
                "Automatic uses Hyprland mappings for known Omarchy or Hyprland machines and GNOME/Linux mappings otherwise."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var sharedDirectorySection: some View {
        Section("Shared Directory") {
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
        }
    }

    private var availableImages: [MachineImage] {
        model.library.images.filter {
            $0.availability.isAvailable
                || $0.artifactKind == .ociReference
        }
    }

    private var selectedImage: MachineImage? {
        guard case .managedImage(let id) = source else { return nil }
        return model.library.images.first { $0.id == id }
    }

    private var needsBootProfile: Bool {
        selectedImage?.artifactKind == .rootfsArchive
            || selectedImage?.artifactKind == .ociReference
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

    private var pendingArchitectureBinding: Binding<GuestArchitecture> {
        Binding(
            get: { pendingISO?.architecture ?? .arm64 },
            set: { pendingISO?.architecture = $0 }
        )
    }

    private func selectInitialSource() {
        guard source == nil else {
            return
        }
        if let image = availableImages.first {
            source = .managedImage(image.id)
            name = image.name
        } else if let entry = model.library.catalog.first {
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
                switch detection {
                case .architecture(let architecture):
                    pendingISO = PendingLocalISO(
                        url: url,
                        architecture: architecture
                    )
                    importPendingISO()
                case .ambiguous, .unknown:
                    pendingISO = PendingLocalISO(url: url, architecture: .arm64)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importPendingISO() {
        guard let pendingISO else {
            return
        }
        isImporting = true
        errorMessage = nil

        Task {
            do {
                let imageID = try await model.library.importISO(
                    from: pendingISO.url,
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
        guard let source else {
            return
        }
        isCreating = true
        errorMessage = nil

        Task {
            do {
                let machineID = try await model.createMachine(
                    name: name,
                    cpuCount: cpuCount,
                    memorySizeBytes: UInt64(memoryGiB) * 1_024 * 1_024 * 1_024,
                    diskSizeBytes: UInt64(diskGiB) * 1_024 * 1_024 * 1_024,
                    source: source,
                    sharedDirectoryPath: sharedDirectoryPath,
                    rosettaEnabled: rosettaEnabled,
                    bootProfileID: bootProfileID,
                    portForwards: enablesPortForward
                        ? [
                            PortForward(
                                hostPort: UInt16(clamping: hostPort),
                                guestPort: UInt16(clamping: guestPort)
                            )
                        ]
                        : [],
                    inputProfile: inputProfile
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
