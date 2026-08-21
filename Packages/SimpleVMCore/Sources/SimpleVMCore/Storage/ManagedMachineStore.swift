import Foundation

public struct MachineFileLocations: Sendable {
    public let directoryURL: URL
    public let diskURL: URL
    public let backendStateURL: URL

    public init(
        directoryURL: URL,
        diskURL: URL,
        backendStateURL: URL
    ) {
        self.directoryURL = directoryURL
        self.diskURL = diskURL
        self.backendStateURL = backendStateURL
    }
}

public actor ManagedMachineStore {
    private let layout: StorageLayout
    private let fileManager: FileManager

    public init(
        layout: StorageLayout,
        fileManager: FileManager = .default
    ) {
        self.layout = layout
        self.fileManager = fileManager
    }

    public func createFiles(
        machineID: UUID,
        diskCapacityBytes: UInt64,
        backend: VirtualizationBackendKind,
        operatingSystem: GuestOperatingSystem = .linux,
        baseDiskURL: URL? = nil
    ) throws -> (MachineDisk, BackendStateReference) {
        try layout.initialize(fileManager: fileManager)
        let directoryURL = layout.machineURL(id: machineID)
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false
        )

        do {
            let stateDirectoryURL: URL
            if operatingSystem == .windows {
                stateDirectoryURL = directoryURL.appending(
                    path: "State/current",
                    directoryHint: .isDirectory
                )
                try fileManager.createDirectory(
                    at: stateDirectoryURL,
                    withIntermediateDirectories: true
                )
            } else {
                stateDirectoryURL = directoryURL
            }
            let diskURL = stateDirectoryURL.appending(path: "disk.raw")
            let capacity: UInt64
            if let baseDiskURL {
                try APFSCloneStorage.clone(from: baseDiskURL, to: diskURL)
                let attributes = try fileManager.attributesOfItem(
                    atPath: diskURL.path
                )
                let sourceSize = (attributes[.size] as? NSNumber)?.uint64Value
                    ?? 0
                capacity = max(
                    sourceSize,
                    SparseDiskCreator.alignedCapacity(diskCapacityBytes)
                )
                if capacity > sourceSize {
                    let handle = try FileHandle(forWritingTo: diskURL)
                    defer { try? handle.close() }
                    try handle.truncate(atOffset: capacity)
                }
            } else {
                capacity = try SparseDiskCreator.create(
                    at: diskURL,
                    capacityBytes: diskCapacityBytes,
                    fileManager: fileManager
                )
            }
            let backendDirectoryName = switch backend {
            case .appleVirtualization:
                "Apple"
            case .qemu:
                "QEMU"
            }
            let backendStateURL = stateDirectoryURL.appending(
                path: backendDirectoryName,
                directoryHint: .isDirectory
            )
            try fileManager.createDirectory(
                at: backendStateURL,
                withIntermediateDirectories: false
            )

            return (
                MachineDisk(
                    relativePath: try layout.relativePath(for: diskURL),
                    capacityBytes: capacity
                ),
                BackendStateReference(
                    relativeDirectory: try layout.relativePath(
                        for: backendStateURL
                    )
                )
            )
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }
    }

    public func resolveFiles(for machine: Machine) throws -> MachineFileLocations {
        let directoryURL = layout.machineURL(id: machine.id)
        let diskURL = try layout.resolve(relativePath: machine.disk.relativePath)
        let backendStateURL = try layout.resolve(
            relativePath: machine.backendState.relativeDirectory
        )
        guard fileManager.fileExists(atPath: diskURL.path) else {
            throw ManagedMachineStoreError.missingDisk
        }
        return MachineFileLocations(
            directoryURL: directoryURL,
            diskURL: diskURL,
            backendStateURL: backendStateURL
        )
    }

    public func removeMachine(id: UUID) throws {
        let directoryURL = layout.machineURL(id: id)
        if fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.removeItem(at: directoryURL)
        }
    }

    public func cloneFiles(
        source: Machine,
        destinationID: UUID
    ) throws -> (MachineDisk, BackendStateReference) {
        let sourceLocations = try resolveFiles(for: source)
        let result = try createFiles(
            machineID: destinationID,
            diskCapacityBytes: source.disk.capacityBytes,
            backend: source.backend,
            operatingSystem: source.spec.operatingSystem,
            baseDiskURL: sourceLocations.diskURL
        )
        copyFirmwareState(
            sourceDirectory: sourceLocations.backendStateURL,
            destinationDirectory: try layout.resolve(
                relativePath: result.1.relativeDirectory
            )
        )
        return result
    }

    private func copyFirmwareState(
        sourceDirectory: URL,
        destinationDirectory: URL
    ) {
        for fileName in [
            "efi-variable-store",
            "efi-code.fd",
            "efi-vars.fd",
            "tpm-state",
            AppleLinuxBootAssets.kernelFileName,
            AppleLinuxBootAssets.initialRamdiskFileName,
            AppleLinuxBootAssets.commandLineFileName
        ] {
            let sourceURL = sourceDirectory.appending(path: fileName)
            let destinationURL = destinationDirectory.appending(path: fileName)
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                continue
            }
            if (try? APFSCloneStorage.clone(
                from: sourceURL,
                to: destinationURL
            )) == nil {
                try? fileManager.copyItem(
                    at: sourceURL,
                    to: destinationURL
                )
            }
        }
    }

    public func removeOrphanedMachines(referencedIDs: Set<UUID>) throws {
        try layout.initialize(fileManager: fileManager)
        let directories = try fileManager.contentsOfDirectory(
            at: layout.machinesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for directory in directories {
            guard let id = UUID(uuidString: directory.lastPathComponent),
                  !referencedIDs.contains(id) else {
                continue
            }
            try fileManager.removeItem(at: directory)
        }
    }
}

public enum ManagedMachineStoreError: LocalizedError, Equatable {
    case missingDisk

    public var errorDescription: String? {
        switch self {
        case .missingDisk:
            "The machine’s virtual disk is missing."
        }
    }
}
