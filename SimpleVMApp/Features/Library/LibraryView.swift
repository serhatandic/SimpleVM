import SimpleVMCore
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Bindable var model: AppModel
    @State private var presentsOCI = false
    @State private var pendingImport: PendingISOImport?
    @State private var confirmsRemoval: MachineImage?

    var body: some View {
        Group {
            if model.images.isEmpty {
                ContentUnavailableView {
                    Label("No Images", systemImage: "opticaldiscdrive")
                } description: {
                    Text("Import an installer ISO or download catalog media.")
                } actions: {
                    Button("Import ISO…") {
                        chooseISO()
                    }
                }
            } else {
                imageTable
            }
        }
        .navigationTitle("Images")
        .toolbar {
            ToolbarItemGroup {
                catalogMenu
                Button {
                    chooseISO()
                } label: {
                    Label("Import ISO", systemImage: "plus")
                }
                Button {
                    chooseDisk()
                } label: {
                    Label("Import Disk", systemImage: "externaldrive")
                }
                Button {
                    chooseRootFS()
                } label: {
                    Label("Import RootFS", systemImage: "archivebox")
                }
                Button {
                    presentsOCI = true
                } label: {
                    Label("Add OCI Reference", systemImage: "shippingbox")
                }
            }
        }
        .sheet(isPresented: $presentsOCI) {
            OCIImportView(model: model) {
                presentsOCI = false
            }
        }
        .sheet(item: $pendingImport) { pendingImport in
            ISOImportView(
                pendingImport: pendingImport,
                onImport: { architecture in
                    Task {
                        do {
                            _ = try await model.importImage(
                                from: pendingImport.url,
                                architecture: architecture,
                                artifactKind: pendingImport.artifactKind
                            )
                        } catch {
                            model.present(error: error)
                        }

                    }
                    self.pendingImport = nil
                },
                onCancel: {
                    self.pendingImport = nil
                }
            )
        }
        .confirmationDialog(
            "Delete image?",
            isPresented: removalBinding,
            titleVisibility: .visible
        ) {
            if let image = confirmsRemoval {
                Button("Delete Image", role: .destructive) {
                    Task {
                        await model.removeImage(image)
                    }
                    confirmsRemoval = nil
                }
            }
        } message: {
            Text("The managed image file will be permanently removed.")
        }
    }

    private var imageTable: some View {
        Table(model.images) {
            TableColumn("Name") { image in
                VStack(alignment: .leading) {
                    Text(image.name)
                    if let version = image.version {
                        Text(version)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            TableColumn("Architecture") { image in
                Text(image.architecture.displayName)
            }
            TableColumn("Kind") { image in
                Text(image.artifactKind.displayName)
            }
            TableColumn("Size") { image in
                Text(image.formattedSize)
            }
            TableColumn("Status") { image in
                ImageStatusView(image: image)
            }
            TableColumn("") { image in
                Menu {
                    if case .downloading = image.availability {
                        Button("Cancel Download") {
                            model.cancelDownload(imageID: image.id)
                        }
                    }
                    if case .failed = image.availability {
                        Button("Retry Download") {
                            Task {
                                await model.retryDownload(image)
                            }
                        }
                    }
                    Button("Delete", role: .destructive) {
                        confirmsRemoval = image
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Image actions")
            }
            .width(42)
        }
    }

    private var catalogMenu: some View {
        Menu {
            ForEach(model.catalog) { entry in
                Button {
                    model.download(entry)
                } label: {
                    Text("\(entry.name) \(entry.version ?? "")")
                }
            }
        } label: {
            Label("Download", systemImage: "arrow.down.circle")
        }
        .disabled(model.catalog.isEmpty)
    }

    private var removalBinding: Binding<Bool> {
        Binding(
            get: { confirmsRemoval != nil },
            set: { isPresented in
                if !isPresented {
                    confirmsRemoval = nil
                }
            }
        )
    }

    private func handleISO(_ url: URL) {
        Task {
            let detection = try? await model.detectArchitecture(at: url)
            pendingImport = PendingISOImport(
                url: url,
                detection: detection ?? .unknown,
                artifactKind: .installerISO
            )
        }
    }

    private func chooseISO() {
        if let url = FilePicker.chooseFile(
            allowedContentTypes: [
                UTType(filenameExtension: "iso") ?? .data
            ]
        ) {
            handleISO(url)
        }
    }

    private func chooseDisk() {
        if let url = FilePicker.chooseFile(
            allowedContentTypes: [
                UTType(filenameExtension: "raw") ?? .data,
                UTType(filenameExtension: "img") ?? .data
            ]
        ) {
            pendingImport = PendingISOImport(
                url: url,
                detection: .unknown,
                artifactKind: .preinstalledDisk
            )
        }
    }

    private func chooseRootFS() {
        if let url = FilePicker.chooseFile(
            allowedContentTypes: [
                UTType(filenameExtension: "tar") ?? .archive,
                UTType(filenameExtension: "gz") ?? .gzip
            ]
        ) {
            pendingImport = PendingISOImport(
                url: url,
                detection: .unknown,
                artifactKind: .rootfsArchive
            )
        }
    }
}

private struct PendingISOImport: Identifiable {
    let id = UUID()
    let url: URL
    let detection: ISOArchitectureDetection
    var artifactKind: ImageArtifactKind = .installerISO
}

private struct ISOImportView: View {
    let pendingImport: PendingISOImport
    let onImport: (GuestArchitecture) -> Void
    let onCancel: () -> Void

    @State private var architecture = GuestArchitecture.arm64

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(
                pendingImport.artifactKind == .installerISO
                    ? "Import Installer ISO"
                    : "Import Preinstalled Disk"
            )
                .font(.title2.weight(.semibold))
            LabeledContent("File", value: pendingImport.url.lastPathComponent)
            Picker("Architecture", selection: $architecture) {
                ForEach(GuestArchitecture.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            if pendingImport.detection == .unknown {
                Label(
                    "SimpleVM could not detect this ISO’s architecture.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    onImport(architecture)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460, height: 240)
        .onAppear {
            if case .architecture(let detected) = pendingImport.detection {
                architecture = detected
            }
        }
    }
}

private struct ImageStatusView: View {
    let image: MachineImage

    var body: some View {
        switch image.availability {
        case .remote:
            Text("Remote")
        case .downloading(let progress):
            ProgressView(value: progress)
                .accessibilityLabel("Downloading")
                .accessibilityValue("\(Int(progress * 100)) percent")
        case .verifying:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Verifying")
        case .available:
            Label("Available", systemImage: "checkmark.circle.fill")
        case .failed(let message):
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .help(message)
        }
    }
}

private extension MachineImage {
    var formattedSize: String {
        guard let sizeBytes else {
            return "—"
        }
        return ByteCountFormatter.string(
            fromByteCount: sizeBytes,
            countStyle: .file
        )
    }
}

private struct OCIImportView: View {
    @Bindable var model: AppModel
    let onDismiss: () -> Void

    @State private var reference = "docker.io/library/alpine:latest"
    @State private var architecture = GuestArchitecture.arm64
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add OCI Image")
                .font(.title2.weight(.semibold))
            TextField("Image reference", text: $reference)
            Picker("Architecture", selection: $architecture) {
                ForEach(GuestArchitecture.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onDismiss)
                Button("Add") {
                    Task {
                        do {
                            _ = try await model.addOCIReference(
                                reference,
                                architecture: architecture
                            )
                            onDismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 500, height: 240)
    }
}
