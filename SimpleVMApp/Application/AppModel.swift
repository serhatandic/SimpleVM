import Foundation
import Observation
import SimpleVMCore

@MainActor
@Observable
final class AppModel {
    private(set) var machines: [Machine] = []
    private(set) var images: [MachineImage] = []
    private(set) var catalog: [ImageCatalogEntry] = []
    private(set) var storageURL: URL?
    private(set) var isLoading = true
    private(set) var errorMessage: String?

    @ObservationIgnored
    private var store: LibraryStore?

    @ObservationIgnored
    private var imageStore: ManagedImageStore?

    @ObservationIgnored
    private var layout: StorageLayout?

    @ObservationIgnored
    private let downloader = ImageDownloadClient()

    @ObservationIgnored
    private var downloads: [UUID: Task<Void, Never>] = [:]

    func initialize() async {
        guard store == nil else {
            return
        }

        do {
            let layout = try StorageLayout.live()
            let store = LibraryStore(layout: layout)
            let snapshot = try await store.load()
            self.store = store
            self.imageStore = ManagedImageStore(layout: layout)
            self.layout = layout
            storageURL = layout.rootURL
            machines = snapshot.machines
            images = snapshot.images.map { image in
                var image = image
                if image.availability.isInterruptedTransfer {
                    image.availability = .failed(
                        message: "The transfer was interrupted. Retry the download."
                    )
                }
                return image
            }
            catalog = try ImageCatalog.bundled()
            if images != snapshot.images {
                try await persist()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func detectArchitecture(at url: URL) async throws -> ISOArchitectureDetection {
        try await Task.detached {
            try ISOArchitectureDetector.detect(at: url)
        }.value
    }

    func importISO(
        from sourceURL: URL,
        architecture: GuestArchitecture
    ) async {
        guard let imageStore, let layout else {
            present(error: AppModelError.notInitialized)
            return
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
                artifactKind: .installerISO,
                origin: .localImport(originalFileName: sourceURL.lastPathComponent),
                sha256: sha256,
                sizeBytes: sizeBytes,
                availability: .available(
                    relativePath: try layout.relativePath(for: destinationURL)
                )
            )
            images.append(image)
            try await persist()
        } catch {
            try? await imageStore.removeImage(id: imageID)
            present(error: error)
        }
    }

    func download(_ entry: ImageCatalogEntry) {
        guard let imageStore, let layout else {
            present(error: AppModelError.notInitialized)
            return
        }
        guard !images.contains(where: {
            $0.sha256 == entry.sha256 && !$0.availability.isFailed
        }) else {
            return
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
                try await persist()
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    images.removeAll { $0.id == imageID }
                    try? await imageStore.removeImage(id: imageID)
                    try? await persist()
                } else {
                    updateImage(id: imageID) {
                        $0.availability = .failed(message: error.localizedDescription)
                    }
                    try? await persist()
                    present(error: error)
                }
            }
            downloads[imageID] = nil
        }
        downloads[imageID] = task
    }

    func cancelDownload(imageID: UUID) {
        downloads[imageID]?.cancel()
    }

    func retryDownload(_ image: MachineImage) async {
        guard let entry = catalog.first(where: { $0.sha256 == image.sha256 }) else {
            present(error: AppModelError.catalogEntryUnavailable)
            return
        }

        if let imageStore {
            try? await imageStore.removeImage(id: image.id)
        }
        images.removeAll { $0.id == image.id }
        try? await persist()
        download(entry)
    }

    func removeImage(_ image: MachineImage) async {
        guard let imageStore else {
            present(error: AppModelError.notInitialized)
            return
        }
        guard !machines.contains(where: { $0.sourceImageID == image.id }) else {
            present(error: AppModelError.imageInUse)
            return
        }

        do {
            downloads[image.id]?.cancel()
            try await imageStore.removeImage(id: image.id)
            images.removeAll { $0.id == image.id }
            try await persist()
        } catch {
            present(error: error)
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    private func record(phase: ImageDownloadPhase, imageID: UUID) {
        updateImage(id: imageID) { image in
            switch phase {
            case .downloading(let progress):
                image.availability = .downloading(progress: progress)
            case .verifying:
                image.availability = .verifying
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

    private func persist() async throws {
        guard let store else {
            throw AppModelError.notInitialized
        }
        try await store.save(
            LibrarySnapshot(machines: machines, images: images)
        )
    }

    private func present(error: any Error) {
        errorMessage = error.localizedDescription
    }
}

private enum AppModelError: LocalizedError {
    case notInitialized
    case imageInUse
    case catalogEntryUnavailable

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            "SimpleVM is still initializing."
        case .imageInUse:
            "This image is used by one or more machines."
        case .catalogEntryUnavailable:
            "The catalog entry for this image is no longer available."
        }
    }
}

private extension ImageAvailability {
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
}
