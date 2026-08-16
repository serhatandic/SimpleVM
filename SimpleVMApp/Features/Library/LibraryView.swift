import SimpleVMCore
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Bindable var model: AppModel
    @State private var importsISO = false
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
                        importsISO = true
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
                    importsISO = true
                } label: {
                    Label("Import ISO", systemImage: "plus")
                }
            }
        }
        .fileImporter(
            isPresented: $importsISO,
            allowedContentTypes: [UTType(filenameExtension: "iso") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .sheet(item: $pendingImport) { pendingImport in
            ISOImportView(
                pendingImport: pendingImport,
                onImport: { architecture in
                    Task {
                        await model.importISO(
                            from: pendingImport.url,
                            architecture: architecture
                        )
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

    private func handleImport(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            return
        }

        Task {
            let detection = try? await model.detectArchitecture(at: url)
            pendingImport = PendingISOImport(
                url: url,
                detection: detection ?? .unknown
            )
        }
    }
}

private struct PendingISOImport: Identifiable {
    let id = UUID()
    let url: URL
    let detection: ISOArchitectureDetection
}

private struct ISOImportView: View {
    let pendingImport: PendingISOImport
    let onImport: (GuestArchitecture) -> Void
    let onCancel: () -> Void

    @State private var architecture = GuestArchitecture.arm64

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Import Installer ISO")
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
