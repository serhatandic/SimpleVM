import Foundation

public actor SnapshotStore {
    private let layout: StorageLayout
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        layout: StorageLayout,
        fileManager: FileManager = .default
    ) {
        self.layout = layout
        self.fileManager = fileManager
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
    }

    public func list(machineID: UUID) throws -> [MachineSnapshot] {
        let metadataURL = snapshotsDirectory(machineID: machineID).appending(
            path: "snapshots.json"
        )
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return []
        }
        return try decoder.decode(
            [MachineSnapshot].self,
            from: Data(contentsOf: metadataURL)
        )
    }

    public func create(
        machine: Machine,
        name: String
    ) throws -> MachineSnapshot {
        let sourceURL = try layout.resolve(
            relativePath: machine.disk.relativePath
        )
        let directory = snapshotsDirectory(machineID: machine.id)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let snapshotID = UUID()
        let diskURL = directory.appending(path: "\(snapshotID.uuidString).raw")
        try APFSCloneStorage.clone(from: sourceURL, to: diskURL)
        var snapshots = try list(machineID: machine.id)
        let snapshot = MachineSnapshot(
            id: snapshotID,
            name: name,
            diskRelativePath: try layout.relativePath(for: diskURL)
        )
        snapshots.append(snapshot)
        try save(snapshots, machineID: machine.id)
        return snapshot
    }

    public func restore(
        _ snapshot: MachineSnapshot,
        machine: Machine
    ) throws {
        let sourceURL = try layout.resolve(
            relativePath: snapshot.diskRelativePath
        )
        let diskURL = try layout.resolve(relativePath: machine.disk.relativePath)
        let replacementURL = diskURL.appendingPathExtension("restore")
        if fileManager.fileExists(atPath: replacementURL.path) {
            try fileManager.removeItem(at: replacementURL)
        }
        try APFSCloneStorage.clone(from: sourceURL, to: replacementURL)
        _ = try fileManager.replaceItemAt(
            diskURL,
            withItemAt: replacementURL
        )
    }

    public func delete(
        _ snapshot: MachineSnapshot,
        machineID: UUID
    ) throws {
        let diskURL = try layout.resolve(relativePath: snapshot.diskRelativePath)
        if fileManager.fileExists(atPath: diskURL.path) {
            try fileManager.removeItem(at: diskURL)
        }
        let snapshots = try list(machineID: machineID).filter {
            $0.id != snapshot.id
        }
        try save(snapshots, machineID: machineID)
    }

    private func save(
        _ snapshots: [MachineSnapshot],
        machineID: UUID
    ) throws {
        let directory = snapshotsDirectory(machineID: machineID)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(snapshots)
        try data.write(
            to: directory.appending(path: "snapshots.json"),
            options: .atomic
        )
    }

    private func snapshotsDirectory(machineID: UUID) -> URL {
        layout.machineURL(id: machineID).appending(
            path: "Snapshots",
            directoryHint: .isDirectory
        )
    }
}

