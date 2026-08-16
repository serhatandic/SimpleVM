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
    private(set) var bootProfiles: [LinuxBootProfile] = []
    private(set) var snapshots: [UUID: [MachineSnapshot]] = [:]
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
    private var snapshotStore: SnapshotStore?

    @ObservationIgnored
    private var layout: StorageLayout?

    @ObservationIgnored
    private let downloader = ImageDownloadClient()

    @ObservationIgnored
    private var downloads: [UUID: Task<Void, Never>] = [:]

    @ObservationIgnored
    private var appleRuntimes: [UUID: MachineRuntime] = [:]

    @ObservationIgnored
    private var qemuRuntimes: [UUID: QEMUMachineRuntime] = [:]

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
            let snapshotStore = SnapshotStore(layout: layout)
            try await imageStore.removeOrphanedImages(
                referencedIDs: Set(snapshot.images.map(\.id))
            )
            try await machineStore.removeOrphanedMachines(
                referencedIDs: Set(snapshot.machines.map(\.id))
            )
            self.store = store
            self.imageStore = imageStore
            self.machineStore = machineStore
            self.snapshotStore = snapshotStore
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
            bootProfiles = try LinuxBootProfileCatalog.bundled()
            for machine in machines {
                snapshots[machine.id] = try await snapshotStore.list(
                    machineID: machine.id
                )
            }
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
        sharedDirectoryPath: String?,
        rosettaEnabled: Bool = false,
        bootProfileID: String? = nil,
        portForwards: [PortForward] = []
    ) async throws -> UUID {
        guard let machineStore, let layout else {
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
        for forward in portForwards {
            try PortForwardValidator.validate(forward)
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
        let machineID = UUID()
        let backend: VirtualizationBackendKind = image.architecture == .arm64
            ? .appleVirtualization
            : .qemu
        let baseDiskURL: URL?
        if image.artifactKind == .preinstalledDisk {
            baseDiskURL = try image.availableURL(layout: layout)
        } else {
            baseDiskURL = nil
        }
        var (disk, backendState) = try await machineStore.createFiles(
            machineID: machineID,
            diskCapacityBytes: diskSizeBytes,
            backend: backend,
            baseDiskURL: baseDiskURL
        )
        do {
            let diskURL = try layout.resolve(relativePath: disk.relativePath)
            let backendStateURL = try layout.resolve(
                relativePath: backendState.relativeDirectory
            )
            if image.artifactKind == .rootfsArchive
                || image.artifactKind == .ociReference {
            guard let bootProfile = bootProfiles.first(where: {
                $0.id == bootProfileID
            }), bootProfile.architecture == image.architecture else {
                throw LinuxBootProfileError.incompatibleArchitecture
            }
            let helper = try ProvisioningHelperClient.discover()
            try FileManager.default.removeItem(at: diskURL)
            switch image.artifactKind {
            case .rootfsArchive:
                let archiveURL = try image.availableURL(layout: layout)
                try await helper.provisionRootFS(
                    archiveURL: archiveURL,
                    diskURL: diskURL,
                    capacityBytes: diskSizeBytes,
                    compression: archiveURL.pathExtension == "gz"
                        ? "gzip"
                        : "none"
                )
            case .ociReference:
                guard case .oci(let reference) = image.origin else {
                    throw AppModelError.invalidOCIReference
                }
                try await helper.provision(
                    reference: reference,
                    contentStoreURL: layout.downloadsURL.appending(
                        path: "OCI",
                        directoryHint: .isDirectory
                    ),
                    diskURL: diskURL,
                    capacityBytes: diskSizeBytes,
                    architecture: image.architecture
                )
            default:
                break
            }
                try await prepare(
                    bootProfile: bootProfile,
                    helper: helper,
                    backendStateURL: backendStateURL
                )
                let attributes = try FileManager.default.attributesOfItem(
                    atPath: diskURL.path
                )
                disk.capacityBytes =
                    (attributes[.size] as? NSNumber)?.uint64Value
                    ?? disk.capacityBytes
            }
            let machine = Machine(
            id: machineID,
            name: trimmedName,
            spec: MachineSpec(
                cpuCount: cpuCount,
                memorySizeBytes: memorySizeBytes,
                diskSizeBytes: disk.capacityBytes,
                architecture: image.architecture,
                sharedDirectoryPath: sharedDirectoryPath,
                rosettaEnabled: rosettaEnabled,
                portForwards: portForwards
            ),
            sourceImageID: imageID,
            disk: disk,
            provisioningState: image.artifactKind == .preinstalledDisk
                || image.artifactKind == .rootfsArchive
                || image.artifactKind == .ociReference
                ? .ready
                : image.availability.provisioningState,
            bootMedia: image.artifactKind == .preinstalledDisk
                || image.artifactKind == .rootfsArchive
                || image.artifactKind == .ociReference
                ? .systemDisk
                : .installer(imageID: imageID),
            backend: backend,
            backendState: backendState
            )
            machines.append(machine)
            try await persist()
            return machineID
        } catch {
            machines.removeAll { $0.id == machineID }
            try? await machineStore.removeMachine(id: machineID)
            throw error
        }
    }

    private func prepare(
        bootProfile: LinuxBootProfile,
        helper: ProvisioningHelperClient,
        backendStateURL: URL
    ) async throws {
        let temporaryDirectory = backendStateURL.appending(
            path: "BootDownload",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let wrappedKernelURL = temporaryDirectory.appending(path: "kernel")
        _ = try await downloader.download(
            from: bootProfile.kernelURL,
            to: wrappedKernelURL,
            expectedSHA256: bootProfile.kernelSHA256
        ) { _ in }
        let kernelURL = temporaryDirectory.appending(path: "Image")
        try helper.extractKernel(from: wrappedKernelURL, to: kernelURL)

        var initialRamdiskURL: URL?
        if let remoteURL = bootProfile.initialRamdiskURL,
           let checksum = bootProfile.initialRamdiskSHA256 {
            let localURL = temporaryDirectory.appending(path: "initrd")
            _ = try await downloader.download(
                from: remoteURL,
                to: localURL,
                expectedSHA256: checksum
            ) { _ in }
            initialRamdiskURL = localURL
        }
        try AppleLinuxBootAssets.install(
            kernelURL: kernelURL,
            initialRamdiskURL: initialRamdiskURL,
            commandLine: bootProfile.commandLine,
            backendStateURL: backendStateURL
        )
    }

    func appleRuntime(for machine: Machine) -> MachineRuntime {
        if let runtime = appleRuntimes[machine.id] {
            return runtime
        }

        let runtime = MachineRuntime(state: machine.runtimeState)
        runtime.stateHandler = { [weak self] state in
            self?.record(runtimeState: state, machineID: machine.id)
        }
        runtime.errorHandler = { [weak self] error in
            self?.present(error: error)
        }
        appleRuntimes[machine.id] = runtime
        return runtime
    }

    func qemuRuntime(for machine: Machine) -> QEMUMachineRuntime {
        if let runtime = qemuRuntimes[machine.id] {
            return runtime
        }
        let runtime = QEMUMachineRuntime(state: machine.runtimeState)
        runtime.stateHandler = { [weak self] state in
            self?.record(runtimeState: state, machineID: machine.id)
        }
        runtime.errorHandler = { [weak self] error in
            self?.present(error: error)
        }
        qemuRuntimes[machine.id] = runtime
        return runtime
    }

    func runtimeState(for machine: Machine) -> MachineRuntimeState {
        switch machine.backend {
        case .appleVirtualization:
            appleRuntime(for: machine).state
        case .qemu:
            qemuRuntime(for: machine).state
        }
    }

    var hasActiveMachines: Bool {
        let states = appleRuntimes.values.map(\.state)
            + qemuRuntimes.values.map(\.state)
        return states.contains {
            switch $0 {
            case .starting, .running, .stopping:
                true
            case .stopped, .failed:
                false
            }
        }
    }

    func stopAllMachines() async {
        for runtime in appleRuntimes.values {
            if runtime.state == .starting {
                for _ in 0..<100 where runtime.state == .starting {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            switch runtime.state {
            case .running, .stopping:
                await runtime.forceStop()
            case .stopped, .starting, .failed:
                break
            }
        }
        for runtime in qemuRuntimes.values {
            if runtime.state == .starting {
                for _ in 0..<100 where runtime.state == .starting {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            switch runtime.state {
            case .starting, .running, .stopping:
                await runtime.forceStop()
            case .stopped, .failed:
                break
            }
        }
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

            if machine.provisioningState == .readyToInstall {
                updateMachine(id: machine.id) {
                    $0.provisioningState = .installing
                }
            }
            switch machine.backend {
            case .appleVirtualization:
                if machine.spec.rosettaEnabled {
                    try await AppleRosettaSupport.ensureInstalled()
                }
                let configuration =
                    try AppleVirtualMachineConfigurationFactory.make(
                        machine: machine,
                        diskURL: files.diskURL,
                        installerURL: installerURL,
                        backendStateURL: files.backendStateURL
                    )
                await appleRuntime(for: machine).start(
                    configuration: configuration
                )
            case .qemu:
                await qemuRuntime(for: machine).start(
                    machine: machine,
                    diskURL: files.diskURL,
                    installerURL: installerURL,
                    backendStateURL: files.backendStateURL
                )
            }
        } catch {
            present(error: error)
        }
    }

    func requestStop(_ machine: Machine) async {
        switch machine.backend {
        case .appleVirtualization:
            appleRuntime(for: machine).requestStop()
        case .qemu:
            await qemuRuntime(for: machine).stop()
        }
    }

    func forceStop(_ machine: Machine) async {
        switch machine.backend {
        case .appleVirtualization:
            await appleRuntime(for: machine).forceStop()
        case .qemu:
            await qemuRuntime(for: machine).forceStop()
        }
    }

    func ejectInstaller(_ machine: Machine) async {
        guard runtimeState(for: machine) == .stopped else {
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
        guard runtimeState(for: machine) == .stopped else {
            present(error: AppModelError.machineMustBeStopped)
            return
        }

        do {
            try await machineStore.removeMachine(id: machine.id)
            machines.removeAll { $0.id == machine.id }
            appleRuntimes[machine.id] = nil
            qemuRuntimes[machine.id] = nil
            try await persist()
        } catch {
            present(error: error)
        }
    }

    func createSnapshot(_ machine: Machine) async {
        guard let snapshotStore else {
            present(error: AppModelError.notInitialized)
            return
        }
        guard runtimeState(for: machine) == .stopped else {
            present(error: AppModelError.machineMustBeStopped)
            return
        }
        do {
            let snapshot = try await snapshotStore.create(
                machine: machine,
                name: Date.now.formatted(
                    date: .abbreviated,
                    time: .shortened
                )
            )
            snapshots[machine.id, default: []].append(snapshot)
        } catch {
            present(error: error)
        }
    }

    func restoreSnapshot(
        _ snapshot: MachineSnapshot,
        machine: Machine
    ) async {
        guard let snapshotStore else {
            present(error: AppModelError.notInitialized)
            return
        }
        guard runtimeState(for: machine) == .stopped else {
            present(error: AppModelError.machineMustBeStopped)
            return
        }
        do {
            try await snapshotStore.restore(snapshot, machine: machine)
        } catch {
            present(error: error)
        }
    }

    func deleteSnapshot(
        _ snapshot: MachineSnapshot,
        machine: Machine
    ) async {
        guard let snapshotStore else {
            present(error: AppModelError.notInitialized)
            return
        }
        do {
            try await snapshotStore.delete(snapshot, machineID: machine.id)
            snapshots[machine.id]?.removeAll { $0.id == snapshot.id }
        } catch {
            present(error: error)
        }
    }

    func cloneMachine(_ machine: Machine) async {
        guard let machineStore else {
            present(error: AppModelError.notInitialized)
            return
        }
        guard runtimeState(for: machine) == .stopped else {
            present(error: AppModelError.machineMustBeStopped)
            return
        }
        let cloneID = UUID()
        do {
            let (disk, backendState) = try await machineStore.cloneFiles(
                source: machine,
                destinationID: cloneID
            )
            machines.append(
                Machine(
                    id: cloneID,
                    name: "\(machine.name) Copy",
                    spec: machine.spec,
                    sourceImageID: machine.sourceImageID,
                    disk: disk,
                    provisioningState: machine.provisioningState,
                    runtimeState: .stopped,
                    bootMedia: machine.bootMedia,
                    backend: machine.backend,
                    backendState: backendState
                )
            )
            try await persist()
        } catch {
            try? await machineStore.removeMachine(id: cloneID)
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
    case missingMachineName
    case machineMustBeStopped
    case invalidOCIReference

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
        case .missingMachineName:
            "Enter a machine name."
        case .machineMustBeStopped:
            "Stop the machine before performing this action."
        case .invalidOCIReference:
            "Enter a valid OCI image reference."
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
