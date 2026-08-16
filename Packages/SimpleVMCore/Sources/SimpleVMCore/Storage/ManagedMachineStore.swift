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
        diskCapacityBytes: UInt64
    ) throws -> (MachineDisk, BackendStateReference) {
        try layout.initialize(fileManager: fileManager)
        let directoryURL = layout.machineURL(id: machineID)
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false
        )

        do {
            let diskURL = directoryURL.appending(path: "disk.raw")
            let capacity = try SparseDiskCreator.create(
                at: diskURL,
                capacityBytes: diskCapacityBytes,
                fileManager: fileManager
            )
            let backendStateURL = directoryURL.appending(
                path: "Apple",
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
