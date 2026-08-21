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
    let library = ImageLibraryModel()
    private(set) var snapshots: [UUID: [MachineSnapshot]] = [:]
    private(set) var exportingMachineIDs: Set<UUID> = []
    private(set) var startingMachineIDs: Set<UUID> = []
    private(set) var storageURL: URL?
    private(set) var isLoading = true
    private(set) var errorMessage: String?

    @ObservationIgnored
    private var store: LibraryStore?

    @ObservationIgnored
    private var machineStore: ManagedMachineStore?

    @ObservationIgnored
    private var snapshotStore: SnapshotStore?

    @ObservationIgnored
    private var layout: StorageLayout?

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
        library.app = self
    }

    func initialize() async {
        guard store == nil else {
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

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
            try await machineStore.removeOrphanedMachines(
                referencedIDs: Set(snapshot.machines.map(\.id))
            )
            var machines = snapshot.machines.map { machine in
                var machine = machine
                switch machine.runtimeState {
                case .starting, .running, .stopping:
                    machine.runtimeState = .stopped
                case .stopped, .failed:
                    break
                }
                return machine
            }
            var restoredSnapshots: [UUID: [MachineSnapshot]] = [:]
            if ProcessInfo.processInfo.environment[
                "SIMPLEVM_UI_TEST_GUEST_TOOLS"
            ] == "1", machines.isEmpty {
                let machineID = UUID()
                let files = try await machineStore.createFiles(
                    machineID: machineID,
                    diskCapacityBytes: 1 * 1_024 * 1_024,
                    backend: .appleVirtualization
                )
                let shareURL = layout.rootURL.appending(
                    path: "GuestToolsTestShare",
                    directoryHint: .isDirectory
                )
                try FileManager.default.createDirectory(
                    at: shareURL,
                    withIntermediateDirectories: true
                )
                machines = [
                    Machine(
                        id: machineID,
                        name: "Guest Tools Fixture",
                        spec: MachineSpec(
                            cpuCount: 2,
                            memorySizeBytes: 2 * 1_024 * 1_024 * 1_024,
                            diskSizeBytes: files.0.capacityBytes,
                            architecture: .arm64,
                            sharedDirectoryPath: shareURL.path
                        ),
                        sourceImageID: UUID(),
                        disk: files.0,
                        provisioningState: .ready,
                        bootMedia: .systemDisk,
                        backend: .appleVirtualization,
                        backendState: files.1
                    )
                ]
            }
            for machine in machines {
                restoredSnapshots[machine.id] = try await snapshotStore.list(
                    machineID: machine.id
                )
            }
            try await library.restore(
                layout: layout,
                imageStore: imageStore,
                snapshotImages: snapshot.images
            )
            for index in machines.indices
            where machines[index].provisioningState.isInterrupted {
                let sourceImage = library.images.first {
                    $0.id == machines[index].sourceImageID
                }
                machines[index].provisioningState =
                    sourceImage?.availability.provisioningState
                    ?? .failed(message: "The machine’s source image is missing.")
            }
            self.store = store
            self.machineStore = machineStore
            self.snapshotStore = snapshotStore
            self.layout = layout
            storageURL = layout.rootURL
            self.machines = machines
            snapshots = restoredSnapshots
            if library.images != snapshot.images || machines != snapshot.machines {
                try await persist()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
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
        portForwards: [PortForward] = [],
        inputProfile: MachineInputProfile = .automatic
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
            guard let entry = library.catalog.first(where: { $0.id == id }),
                  let downloadedImageID = library.download(entry) else {
                throw AppModelError.catalogEntryUnavailable
            }
            imageID = downloadedImageID
        }

        guard let image = library.images.first(where: { $0.id == imageID }) else {
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
                disk.capacityBytes = try await provisionLinuxDisk(
                    image: image,
                    bootProfileID: bootProfileID,
                    layout: layout,
                    diskURL: diskURL,
                    backendStateURL: backendStateURL,
                    diskSizeBytes: diskSizeBytes
                )
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
                    portForwards: portForwards,
                    inputProfile: inputProfile
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

    private func provisionLinuxDisk(
        image: MachineImage,
        bootProfileID: String?,
        layout: StorageLayout,
        diskURL: URL,
        backendStateURL: URL,
        diskSizeBytes: UInt64
    ) async throws -> UInt64 {
        guard let bootProfile = library.bootProfiles.first(where: {
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
        return (attributes[.size] as? NSNumber)?.uint64Value ?? diskSizeBytes
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
        try await library.downloadBootAsset(
            from: bootProfile.kernelURL,
            to: wrappedKernelURL,
            expectedSHA256: bootProfile.kernelSHA256
        )
        let kernelURL = temporaryDirectory.appending(path: "Image")
        try helper.extractKernel(from: wrappedKernelURL, to: kernelURL)

        var initialRamdiskURL: URL?
        if let remoteURL = bootProfile.initialRamdiskURL,
           let checksum = bootProfile.initialRamdiskSHA256 {
            let localURL = temporaryDirectory.appending(path: "initrd")
            try await library.downloadBootAsset(
                from: remoteURL,
                to: localURL,
                expectedSHA256: checksum
            )
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
        wireHandlers(for: runtime, machineID: machine.id)
        appleRuntimes[machine.id] = runtime
        return runtime
    }

    func qemuRuntime(for machine: Machine) -> QEMUMachineRuntime {
        if let runtime = qemuRuntimes[machine.id] {
            return runtime
        }
        let runtime = QEMUMachineRuntime(state: machine.runtimeState)
        wireHandlers(for: runtime, machineID: machine.id)
        qemuRuntimes[machine.id] = runtime
        return runtime
    }

    private func wireHandlers(
        for runtime: MachineRuntimeBase,
        machineID: UUID
    ) {
        runtime.stateHandler = { [weak self] state in
            self?.record(runtimeState: state, machineID: machineID)
        }
        runtime.errorHandler = { [weak self] error in
            self?.present(error: error)
        }
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
        if !startingMachineIDs.isEmpty {
            return true
        }
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
            await settleIfStarting(runtime)
            switch runtime.state {
            case .running, .stopping:
                await runtime.forceStop()
            case .stopped, .starting, .failed:
                break
            }
        }
        for runtime in qemuRuntimes.values {
            await settleIfStarting(runtime)
            switch runtime.state {
            case .starting, .running, .stopping:
                await runtime.forceStop()
            case .stopped, .failed:
                break
            }
        }
    }

    private func settleIfStarting(_ runtime: MachineRuntimeBase) async {
        guard runtime.state == .starting else { return }
        for _ in 0..<100 where runtime.state == .starting {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func ensureMachineIdle(_ machine: Machine) -> Bool {
        if exportingMachineIDs.contains(machine.id) {
            present(error: AppModelError.exportInProgress)
            return false
        }
        if startingMachineIDs.contains(machine.id) {
            present(error: AppModelError.machineStartInProgress)
            return false
        }
        if runtimeState(for: machine) != .stopped {
            present(error: AppModelError.machineMustBeStopped)
            return false
        }
        return true
    }

    func start(_ machine: Machine) async {
        guard let machineStore, let layout else {
            present(error: AppModelError.notInitialized)
            return
        }
        guard !exportingMachineIDs.contains(machine.id) else {
            present(error: AppModelError.exportInProgress)
            return
        }
        guard startingMachineIDs.insert(machine.id).inserted else {
            present(error: AppModelError.machineStartInProgress)
            return
        }
        defer {
            startingMachineIDs.remove(machine.id)
        }

        do {
            let files = try await machineStore.resolveFiles(for: machine)
            let installerURL: URL?
            switch machine.bootMedia {
            case .installer(let imageID):
                guard let image = library.images.first(where: { $0.id == imageID }) else {
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
                    configuration: configuration,
                    sharedDirectoryConfigured:
                        machine.spec.sharedDirectoryPath != nil
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
            await appleRuntime(for: machine).requestStop()
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

    func requestReboot(_ machine: Machine) async {
        switch machine.backend {
        case .appleVirtualization:
            await appleRuntime(for: machine).requestReboot()
        case .qemu:
            await qemuRuntime(for: machine).requestReboot()
        }
    }

    func ejectInstaller(_ machine: Machine) async {
        guard !startingMachineIDs.contains(machine.id) else {
            present(error: AppModelError.machineStartInProgress)
            return
        }
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
        guard ensureMachineIdle(machine) else { return }

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
        guard ensureMachineIdle(machine) else { return }
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
        guard ensureMachineIdle(machine) else { return }
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
        guard ensureMachineIdle(machine) else { return }
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

    func setInputProfile(
        _ profile: MachineInputProfile,
        for machine: Machine
    ) async {
        guard let index = machines.firstIndex(where: {
            $0.id == machine.id
        }) else {
            present(error: AppModelError.machineUnavailable)
            return
        }
        let previousProfile = machines[index].spec.inputProfile
        machines[index].spec.inputProfile = profile
        do {
            try await persist()
        } catch {
            updateMachine(id: machine.id) {
                $0.spec.inputProfile = previousProfile
            }
            present(error: error)
        }
    }

    func setSharedDirectory(
        _ path: String?,
        for machine: Machine
    ) async {
        guard let index = machines.firstIndex(where: {
            $0.id == machine.id
        }) else {
            present(error: AppModelError.machineUnavailable)
            return
        }
        if let path {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                present(error: AppModelError.sharedDirectoryUnavailable)
                return
            }
        }
        let previousPath = machines[index].spec.sharedDirectoryPath
        machines[index].spec.sharedDirectoryPath = path
        do {
            try await persist()
        } catch {
            updateMachine(id: machine.id) {
                $0.spec.sharedDirectoryPath = previousPath
            }
            present(error: error)
        }
    }

    func exportMachineDisk(
        _ machine: Machine,
        to destinationURL: URL
    ) async throws {
        guard let layout else {
            throw AppModelError.notInitialized
        }

        guard exportingMachineIDs.insert(machine.id).inserted else {
            throw AppModelError.exportInProgress
        }
        defer {
            exportingMachineIDs.remove(machine.id)
        }
        guard let currentMachine = machines.first(where: {
            $0.id == machine.id
        }) else {
            throw AppModelError.machineUnavailable
        }
        guard !startingMachineIDs.contains(machine.id) else {
            throw AppModelError.machineStartInProgress
        }
        guard machine.runtimeState == .stopped,
              currentMachine.runtimeState == .stopped else {
            throw AppModelError.machineMustBeStopped
        }
        let sourceURL = try layout.resolve(
            relativePath: currentMachine.disk.relativePath
        )
        try await exportManagedFile(
            from: sourceURL,
            to: destinationURL
        )
    }

    func exportGuestTools(to destinationURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try GuestToolsBundleExporter().export(to: destinationURL)
        }.value
    }

    func copyGuestToolsToSharedDirectory(
        for machine: Machine
    ) async throws -> URL {
        guard let path = machine.spec.sharedDirectoryPath else {
            throw GuestToolsBundleError.destinationUnavailable
        }
        return try await Task.detached(priority: .userInitiated) {
            try GuestToolsBundleExporter().copyToSharedDirectory(
                URL(filePath: path, directoryHint: .isDirectory)
            )
        }.value
    }

    func dismissError() {
        errorMessage = nil
    }

    func present(error: any Error) {
        self.errorMessage = error.localizedDescription
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

    func updateMachinesForImage(
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

    func persist() async throws {
        guard let store else {
            throw AppModelError.notInitialized
        }
        try await store.save(
            LibrarySnapshot(machines: machines, images: library.images)
        )
    }

    func exportManagedFile(
        from sourceURL: URL,
        to destinationURL: URL
    ) async throws {
        guard let layout else {
            throw AppModelError.notInitialized
        }
        try await Task.detached(priority: .userInitiated) {
            try ManagedFileExporter.export(
                from: sourceURL,
                to: destinationURL,
                protectedRootURL: layout.rootURL
            )
        }.value
    }

}

enum AppModelError: LocalizedError {
    case notInitialized
    case imageInUse
    case catalogEntryUnavailable
    case imageUnavailable
    case machineUnavailable
    case exportInProgress
    case machineStartInProgress
    case missingMachineName
    case machineMustBeStopped
    case invalidOCIReference
    case sharedDirectoryUnavailable

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
        case .machineUnavailable:
            "The selected machine is unavailable."
        case .exportInProgress:
            "Wait for the current export to finish."
        case .machineStartInProgress:
            "Wait for the machine to finish starting."
        case .missingMachineName:
            "Enter a machine name."
        case .machineMustBeStopped:
            "Stop the machine before performing this action."
        case .invalidOCIReference:
            "Enter a valid OCI image reference."
        case .sharedDirectoryUnavailable:
            "The selected shared directory is unavailable."
        }
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
