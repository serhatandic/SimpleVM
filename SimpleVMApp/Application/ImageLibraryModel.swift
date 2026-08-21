import Foundation
import Observation
import SimpleVMCore
import UniformTypeIdentifiers

@MainActor
@Observable
final class ImageLibraryModel {
    private(set) var images: [MachineImage] = []
    private(set) var catalog: [ImageCatalogEntry] = []
    private(set) var bootProfiles: [LinuxBootProfile] = []
    private(set) var exportingImageIDs: Set<UUID> = []

    @ObservationIgnored
    weak var app: AppModel?

    @ObservationIgnored
    private var imageStore: ManagedImageStore?

    @ObservationIgnored
    private var layout: StorageLayout?

    @ObservationIgnored
    private let downloader = ImageDownloadClient()

    @ObservationIgnored
    private var downloads: [UUID: Task<Void, Never>] = [:]

    func restore(
        layout: StorageLayout,
        imageStore: ManagedImageStore,
        snapshotImages: [MachineImage]
    ) async throws {
        try await imageStore.removeOrphanedImages(
            referencedIDs: Set(snapshotImages.map(\.id))
        )
        let images = snapshotImages.map { image in
            var image = image
            if image.availability.isInterruptedTransfer {
                image.availability = .failed(
                    message: "The transfer was interrupted. Retry the download."
                )
            }
            return image
        }
        let catalog = try ImageCatalog.bundled()
        let bootProfiles = try LinuxBootProfileCatalog.bundled()

        self.layout = layout
        self.imageStore = imageStore
        self.images = images
        self.catalog = catalog
        self.bootProfiles = bootProfiles
    }

    func downloadBootAsset(
        from remoteURL: URL,
        to destinationURL: URL,
        expectedSHA256: String
    ) async throws {
        _ = try await downloader.download(
            from: remoteURL,
            to: destinationURL,
            expectedSHA256: expectedSHA256
        ) { _ in }
    }

    func detectArchitecture(at url: URL) async throws -> ISOArchitectureDetection {
        try await Task.detached {
            try ISOArchitectureDetector.detect(at: url)
        }.value
    }

    func importISO(
        from sourceURL: URL,
        architecture: GuestArchitecture
    ) async throws -> UUID {
        try await importImage(
            from: sourceURL,
            architecture: architecture,
            artifactKind: .installerISO
        )
    }

    func importImage(
        from sourceURL: URL,
        architecture: GuestArchitecture,
        artifactKind: ImageArtifactKind
    ) async throws -> UUID {
        guard let imageStore, let layout else {
            throw AppModelError.notInitialized
        }

        let imageID = UUID()
        do {
            let destinationURL = try await imageStore.importFile(
                from: sourceURL,
                imageID: imageID
            )
            let attributes = try FileManager.default.attributesOfItem(
                atPath: destinationURL.path
            )
            let sizeBytes = (attributes[.size] as? NSNumber)?.int64Value
            let sha256 = try await Task.detached {
                try FileSHA256.digest(of: destinationURL)
            }.value
            let image = MachineImage(
                id: imageID,
                name: sourceURL.deletingPathExtension().lastPathComponent,
                architecture: architecture,
                artifactKind: artifactKind,
                origin: .localImport(originalFileName: sourceURL.lastPathComponent),
                sha256: sha256,
                sizeBytes: sizeBytes,
                availability: .available(
                    relativePath: try layout.relativePath(for: destinationURL)
                )
            )
            images.append(image)
            try await persist()
            return imageID
        } catch {
            try? await imageStore.removeImage(id: imageID)
            throw error
        }
    }

    func addOCIReference(
        _ reference: String,
        architecture: GuestArchitecture
    ) async throws -> UUID {
        let trimmed = reference.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else {
            throw AppModelError.invalidOCIReference
        }
        let image = MachineImage(
            name: trimmed,
            architecture: architecture,
            artifactKind: .ociReference,
            origin: .oci(trimmed),
            availability: .remote
        )
        images.append(image)
        try await persist()
        return image.id
    }

    @discardableResult
    func download(_ entry: ImageCatalogEntry) -> UUID? {
        guard imageStore != nil, layout != nil else {
            app?.present(error: AppModelError.notInitialized)
            return nil
        }
        if let existing = images.first(where: {
            $0.sha256 == entry.sha256 && !$0.availability.isFailed
        }) {
            return existing.id
        }

        let imageID = UUID()
        let image = MachineImage(
            id: imageID,
            name: entry.name,
            version: entry.version,
            architecture: entry.architecture,
            artifactKind: entry.artifactKind,
            origin: .catalog(entry.remoteURL),
            sha256: entry.sha256,
            sizeBytes: entry.sizeBytes,
            availability: .downloading(progress: 0)
        )
        images.append(image)
        beginDownload(entry, imageID: imageID)
        return imageID
    }

    func cancelDownload(imageID: UUID) {
        downloads[imageID]?.cancel()
    }

    func retryDownload(_ image: MachineImage) async {
        guard let entry = catalog.first(where: { $0.sha256 == image.sha256 }) else {
            app?.present(error: AppModelError.catalogEntryUnavailable)
            return
        }

        try? await imageStore?.removeImage(id: image.id)
        updateImage(id: image.id) {
            $0.availability = .downloading(progress: 0)
        }
        updateMachinesForImage(id: image.id) {
            $0.provisioningState = .downloading(progress: 0)
        }
        try? await persist()
        beginDownload(entry, imageID: image.id)
    }

    private func beginDownload(
        _ entry: ImageCatalogEntry,
        imageID: UUID
    ) {
        guard let imageStore, let layout else {
            app?.present(error: AppModelError.notInitialized)
            return
        }

        let task = Task {
            do {
                try await persist()
                let destinationURL = try await imageStore.destinationURL(
                    imageID: imageID,
                    fileExtension: "iso"
                )
                let downloadedURL = try await downloader.download(
                    from: entry.remoteURL,
                    to: destinationURL,
                    expectedSHA256: entry.sha256
                ) { [weak self] phase in
                    Task { @MainActor in
                        self?.record(phase: phase, imageID: imageID)
                    }
                }
                try updateImage(id: imageID) {
                    $0.availability = .available(
                        relativePath: try layout.relativePath(for: downloadedURL)
                    )
                }
                updateMachinesForImage(id: imageID) {
                    $0.provisioningState = .readyToInstall
                }
                try await persist()
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    try? await imageStore.removeImage(id: imageID)
                    updateImage(id: imageID) {
                        $0.availability = .failed(message: "Download canceled.")
                    }
                    updateMachinesForImage(id: imageID) {
                        $0.provisioningState = .failed(
                            message: "Image download canceled."
                        )
                    }
                    try? await persist()
                } else {
                    updateImage(id: imageID) {
                        $0.availability = .failed(message: error.localizedDescription)
                    }
                    updateMachinesForImage(id: imageID) {
                        $0.provisioningState = .failed(
                            message: error.localizedDescription
                        )
                    }
                    try? await persist()
                    app?.present(error: error)
                }
            }
            downloads[imageID] = nil
        }
        downloads[imageID] = task
    }

    func removeImage(_ image: MachineImage) async {
        guard let imageStore else {
            app?.present(error: AppModelError.notInitialized)
            return
        }
        guard !exportingImageIDs.contains(image.id) else {
            app?.present(error: AppModelError.exportInProgress)
            return
        }
        guard !(app?.machines.contains(where: { $0.sourceImageID == image.id })
                ?? false) else {
            app?.present(error: AppModelError.imageInUse)
            return
        }

        do {
            downloads[image.id]?.cancel()
            try await imageStore.removeImage(id: image.id)
            images.removeAll { $0.id == image.id }
            try await persist()
        } catch {
            app?.present(error: error)
        }
    }

    func exportImage(
        _ image: MachineImage,
        to destinationURL: URL
    ) async throws {
        guard let layout else {
            throw AppModelError.notInitialized
        }
        guard exportingImageIDs.insert(image.id).inserted else {
            throw AppModelError.exportInProgress
        }
        defer {
            exportingImageIDs.remove(image.id)
        }
        let sourceURL = try image.availableURL(layout: layout)
        try await app?.exportManagedFile(
            from: sourceURL,
            to: destinationURL
        )
    }

    private func record(phase: ImageDownloadPhase, imageID: UUID) {
        updateImage(id: imageID) { image in
            switch phase {
            case .downloading(let progress):
                image.availability = .downloading(progress: progress)
                updateMachinesForImage(id: imageID) {
                    $0.provisioningState = .downloading(progress: progress)
                }
            case .verifying:
                image.availability = .verifying
                updateMachinesForImage(id: imageID) {
                    $0.provisioningState = .verifying
                }
            }
        }
    }

    private func updateImage(
        id: UUID,
        mutation: (inout MachineImage) throws -> Void
    ) rethrows {
        guard let index = images.firstIndex(where: { $0.id == id }) else {
            return
        }
        try mutation(&images[index])
    }

    private func updateMachinesForImage(
        id: UUID,
        mutation: (inout Machine) -> Void
    ) {
        app?.updateMachinesForImage(id: id, mutation: mutation)
    }

    private func persist() async throws {
        try await app?.persist()
    }
}

extension ImageAvailability {
    var isAvailable: Bool {
        if case .available = self {
            return true
        }
        return false
    }

    var isFailed: Bool {
        if case .failed = self {
            return true
        }
        return false
    }

    var isInterruptedTransfer: Bool {
        switch self {
        case .downloading, .verifying:
            true
        default:
            false
        }
    }

    var provisioningState: MachineProvisioningState {
        switch self {
        case .remote:
            .failed(message: "The selected image is not downloaded.")
        case .downloading(let progress):
            .downloading(progress: progress)
        case .verifying:
            .verifying
        case .available:
            .readyToInstall
        case .failed(let message):
            .failed(message: message)
        }
    }
}

extension MachineImage {
    func availableURL(layout: StorageLayout) throws -> URL {
        guard case .available(let relativePath) = availability else {
            throw AppModelError.imageUnavailable
        }
        return try layout.resolve(relativePath: relativePath)
    }
}
