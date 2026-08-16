import Foundation
import Observation
import SimpleVMCore
import Virtualization

enum MachineCreationSource: Hashable {
    case managedImage(UUID)
    case catalogEntry(String)
}

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
    private var machineStore: ManagedMachineStore?

    @ObservationIgnored
    private var layout: StorageLayout?

    @ObservationIgnored
    private let downloader = ImageDownloadClient()

    @ObservationIgnored
    private var downloads: [UUID: Task<Void, Never>] = [:]

    @ObservationIgnored
    private var runtimes: [UUID: MachineRuntime] = [:]

    @ObservationIgnored
    private let storageRootURL: URL?

    init(
        storageRootURL: URL? = ProcessInfo.processInfo.environment[
            "SIMPLEVM_STORAGE_ROOT"
        ].map { URL(filePath: $0) }
    ) {
        self.storageRootURL = storageRootURL
    }

    func initialize() async {
        guard store == nil else {
            return
        }

        do {
            let layout: StorageLayout
            if let storageRootURL {
                layout = StorageLayout(rootURL: storageRootURL)
            } else {
                layout = try StorageLayout.live()
            }
            let store = LibraryStore(layout: layout)
            let snapshot = try await store.load()
            let imageStore = ManagedImageStore(layout: layout)
            let machineStore = ManagedMachineStore(layout: layout)
            try await imageStore.removeOrphanedImages(
                referencedIDs: Set(snapshot.images.map(\.id))
            )
            try await machineStore.removeOrphanedMachines(
                referencedIDs: Set(snapshot.machines.map(\.id))
            )
            self.store = store
            self.imageStore = imageStore
            self.machineStore = machineStore
            self.layout = layout
            storageURL = layout.rootURL
            machines = snapshot.machines.map { machine in
                var machine = machine
                switch machine.runtimeState {
                case .starting, .running, .stopping:
                    machine.runtimeState = .stopped
                case .stopped, .failed:
                    break
                }
                return machine
            }
            images = snapshot.images.map { image in
                var image = image
                if image.availability.isInterruptedTransfer {
                    image.availability = .failed(
                        message: "The transfer was interrupted. Retry the download."
                    )
                }
                return image
            }
            for index in machines.indices
            where machines[index].provisioningState.isInterrupted {
                let sourceImage = images.first {
                    $0.id == machines[index].sourceImageID
                }
                machines[index].provisioningState =
                    sourceImage?.availability.provisioningState
                    ?? .failed(message: "The machine’s source image is missing.")
            }
            catalog = try ImageCatalog.bundled()
            if images != snapshot.images || machines != snapshot.machines {
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
            return imageID
        } catch {
            try? await imageStore.removeImage(id: imageID)
            throw error
        }
    }

    @discardableResult
    func download(_ entry: ImageCatalogEntry) -> UUID? {
        guard imageStore != nil, layout != nil else {
            present(error: AppModelError.notInitialized)
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
            present(error: AppModelError.catalogEntryUnavailable)
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
            present(error: AppModelError.notInitialized)
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
                    present(error: error)
                }
            }
            downloads[imageID] = nil
        }
        downloads[imageID] = task
    }

    func createMachine(
        name: String,
        cpuCount: Int,
        memorySizeBytes: UInt64,
        diskSizeBytes: UInt64,
        source: MachineCreationSource,
        sharedDirectoryPath: String?
    ) async throws -> UUID {
        guard let machineStore else {
            throw AppModelError.notInitialized
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw AppModelError.missingMachineName
        }
        let allowedCPUCounts = (
            VZVirtualMachineConfiguration.minimumAllowedCPUCount
                ... VZVirtualMachineConfiguration.maximumAllowedCPUCount
        )
        guard allowedCPUCounts.contains(cpuCount) else {
            throw AppleConfigurationError.invalidCPUCount
        }
        let allowedMemorySizes = (
            VZVirtualMachineConfiguration.minimumAllowedMemorySize
                ... VZVirtualMachineConfiguration.maximumAllowedMemorySize
        )
        guard allowedMemorySizes.contains(memorySizeBytes) else {
            throw AppleConfigurationError.invalidMemorySize
        }

        let imageID: UUID
        switch source {
        case .managedImage(let id):
            imageID = id
        case .catalogEntry(let id):
            guard let entry = catalog.first(where: { $0.id == id }),
                  let downloadedImageID = download(entry) else {
                throw AppModelError.catalogEntryUnavailable
            }
            imageID = downloadedImageID
        }

        guard let image = images.first(where: { $0.id == imageID }) else {
            throw AppModelError.imageUnavailable
        }
        guard image.architecture == .arm64 else {
            throw AppModelError.compatibilityBackendUnavailable
        }

        let machineID = UUID()
        let (disk, backendState) = try await machineStore.createFiles(
            machineID: machineID,
            diskCapacityBytes: diskSizeBytes
        )
        let machine = Machine(
            id: machineID,
            name: trimmedName,
            spec: MachineSpec(
                cpuCount: cpuCount,
                memorySizeBytes: memorySizeBytes,
                diskSizeBytes: disk.capacityBytes,
                architecture: image.architecture,
                sharedDirectoryPath: sharedDirectoryPath
            ),
            sourceImageID: imageID,
            disk: disk,
            provisioningState: image.availability.provisioningState,
            bootMedia: .installer(imageID: imageID),
            backend: .appleVirtualization,
            backendState: backendState
        )
        machines.append(machine)

        do {
            try await persist()
        } catch {
            machines.removeAll { $0.id == machineID }
            try? await machineStore.removeMachine(id: machineID)
            throw error
        }
        return machineID
    }

    func runtime(for machine: Machine) -> MachineRuntime {
        if let runtime = runtimes[machine.id] {
            return runtime
        }

        let runtime = MachineRuntime(state: machine.runtimeState)
        runtime.stateHandler = { [weak self] state in
            self?.record(runtimeState: state, machineID: machine.id)
        }
        runtime.errorHandler = { [weak self] error in
            self?.present(error: error)
        }
        runtimes[machine.id] = runtime
        return runtime
    }

    func start(_ machine: Machine) async {
        guard let machineStore, let layout else {
            present(error: AppModelError.notInitialized)
            return
        }

        do {
            let files = try await machineStore.resolveFiles(for: machine)
            let installerURL: URL?
            switch machine.bootMedia {
            case .installer(let imageID):
                guard let image = images.first(where: { $0.id == imageID }) else {
                    throw AppModelError.imageUnavailable
                }
                installerURL = try image.availableURL(layout: layout)
            case .systemDisk:
                installerURL = nil
            }

            let configuration = try AppleVirtualMachineConfigurationFactory.make(
                machine: machine,
                diskURL: files.diskURL,
                installerURL: installerURL,
                backendStateURL: files.backendStateURL
            )
            if machine.provisioningState == .readyToInstall {
                updateMachine(id: machine.id) {
                    $0.provisioningState = .installing
                }
            }
            await runtime(for: machine).start(configuration: configuration)
        } catch {
            present(error: error)
        }
    }

    func requestStop(_ machine: Machine) {
        runtime(for: machine).requestStop()
    }

    func forceStop(_ machine: Machine) async {
        await runtime(for: machine).forceStop()
    }

    func ejectInstaller(_ machine: Machine) async {
        let runtime = runtime(for: machine)
        guard runtime.state == .stopped else {
            present(error: AppModelError.machineMustBeStopped)
            return
        }
        updateMachine(id: machine.id) {
            $0.bootMedia = .systemDisk
            $0.provisioningState = .ready
        }
        try? await persist()
    }

    func deleteMachine(_ machine: Machine) async {
        guard let machineStore else {
            present(error: AppModelError.notInitialized)
            return
        }
        guard runtime(for: machine).state == .stopped else {
            present(error: AppModelError.machineMustBeStopped)
            return
        }

        do {
            try await machineStore.removeMachine(id: machine.id)
            machines.removeAll { $0.id == machine.id }
            runtimes[machine.id] = nil
            try await persist()
        } catch {
            present(error: error)
        }
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

    func present(error: any Error) {
        self.errorMessage = error.localizedDescription
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

    private func updateMachine(
        id: UUID,
        mutation: (inout Machine) -> Void
    ) {
        guard let index = machines.firstIndex(where: { $0.id == id }) else {
            return
        }
        mutation(&machines[index])
    }

    private func updateMachinesForImage(
        id: UUID,
        mutation: (inout Machine) -> Void
    ) {
        for index in machines.indices where machines[index].sourceImageID == id {
            mutation(&machines[index])
        }
    }

    private func record(runtimeState: MachineRuntimeState, machineID: UUID) {
        updateMachine(id: machineID) {
            $0.runtimeState = runtimeState
        }
        Task {
            try? await persist()
        }
    }

    private func persist() async throws {
        guard let store else {
            throw AppModelError.notInitialized
        }
        try await store.save(
            LibrarySnapshot(machines: machines, images: images)
        )
    }

}

private enum AppModelError: LocalizedError {
    case notInitialized
    case imageInUse
    case catalogEntryUnavailable
    case imageUnavailable
    case compatibilityBackendUnavailable
    case missingMachineName
    case machineMustBeStopped

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            "SimpleVM is still initializing."
        case .imageInUse:
            "This image is used by one or more machines."
        case .catalogEntryUnavailable:
            "The catalog entry for this image is no longer available."
        case .imageUnavailable:
            "The selected image is not available."
        case .compatibilityBackendUnavailable:
            "x86_64 images require the compatibility backend, which is not available yet."
        case .missingMachineName:
            "Enter a machine name."
        case .machineMustBeStopped:
            "Stop the machine before performing this action."
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

private extension MachineImage {
    func availableURL(layout: StorageLayout) throws -> URL {
        guard case .available(let relativePath) = availability else {
            throw AppModelError.imageUnavailable
        }
        return try layout.resolve(relativePath: relativePath)
    }
}

private extension MachineProvisioningState {
    var isInterrupted: Bool {
        switch self {
        case .downloading, .verifying, .preparingDisk:
            true
        default:
            false
        }
    }
}
