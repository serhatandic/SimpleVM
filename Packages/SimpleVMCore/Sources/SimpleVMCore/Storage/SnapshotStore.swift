import Darwin
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
        let snapshot: MachineSnapshot
        if machine.spec.operatingSystem == .windows {
            let snapshotRootURL = directory.appending(
                path: snapshotID.uuidString,
                directoryHint: .isDirectory
            )
            let stateURL = snapshotRootURL.appending(
                path: "State",
                directoryHint: .isDirectory
            )
            do {
                try cloneWindowsState(
                    from: sourceURL.deletingLastPathComponent(),
                    to: stateURL
                )
            } catch {
                try? fileManager.removeItem(at: snapshotRootURL)
                throw error
            }
            snapshot = MachineSnapshot(
                id: snapshotID,
                name: name,
                diskRelativePath: try layout.relativePath(
                    for: stateURL.appending(path: "disk.raw")
                ),
                stateDirectoryRelativePath: try layout.relativePath(
                    for: stateURL
                )
            )
        } else {
            let diskURL = directory.appending(path: "\(snapshotID.uuidString).raw")
            try APFSCloneStorage.clone(from: sourceURL, to: diskURL)
            snapshot = MachineSnapshot(
                id: snapshotID,
                name: name,
                diskRelativePath: try layout.relativePath(for: diskURL)
            )
        }
        var snapshots = try list(machineID: machine.id)
        snapshots.append(snapshot)
        try save(snapshots, machineID: machine.id)
        return snapshot
    }

    public func restore(
        _ snapshot: MachineSnapshot,
        machine: Machine
    ) throws {
        if machine.spec.operatingSystem == .windows,
           let relativeStatePath = snapshot.stateDirectoryRelativePath {
            try restoreWindowsState(
                from: try layout.resolve(relativePath: relativeStatePath),
                machine: machine
            )
            return
        }
        try restoreLegacyDisk(snapshot, machine: machine)
    }

    public func delete(
        _ snapshot: MachineSnapshot,
        machineID: UUID
    ) throws {
        if let relativeStatePath = snapshot.stateDirectoryRelativePath {
            let stateURL = try layout.resolve(relativePath: relativeStatePath)
            let snapshotRootURL = stateURL.deletingLastPathComponent()
            if fileManager.fileExists(atPath: snapshotRootURL.path) {
                try fileManager.removeItem(at: snapshotRootURL)
            }
        } else {
            let diskURL = try layout.resolve(
                relativePath: snapshot.diskRelativePath
            )
            if fileManager.fileExists(atPath: diskURL.path) {
                try fileManager.removeItem(at: diskURL)
            }
        }
        let snapshots = try list(machineID: machineID).filter {
            $0.id != snapshot.id
        }
        try save(snapshots, machineID: machineID)
    }

    private func restoreLegacyDisk(
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

    private func restoreWindowsState(
        from snapshotStateURL: URL,
        machine: Machine
    ) throws {
        let diskURL = try layout.resolve(relativePath: machine.disk.relativePath)
        let currentStateURL = diskURL.deletingLastPathComponent()
        guard currentStateURL.lastPathComponent == "current",
              currentStateURL.deletingLastPathComponent().lastPathComponent
                == "State" else {
            throw SnapshotStoreError.invalidWindowsState
        }
        let stagedURL = currentStateURL.deletingLastPathComponent().appending(
            path: ".restore-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        if fileManager.fileExists(atPath: stagedURL.path) {
            try fileManager.removeItem(at: stagedURL)
        }
        do {
            try cloneWindowsState(from: snapshotStateURL, to: stagedURL)
            try swap(currentStateURL, stagedURL)
            try fileManager.removeItem(at: stagedURL)
        } catch {
            if fileManager.fileExists(atPath: stagedURL.path) {
                try? fileManager.removeItem(at: stagedURL)
            }
            throw error
        }
    }

    private func cloneWindowsState(
        from sourceStateURL: URL,
        to destinationStateURL: URL
    ) throws {
        try fileManager.createDirectory(
            at: destinationStateURL,
            withIntermediateDirectories: true
        )
        try APFSCloneStorage.clone(
            from: sourceStateURL.appending(path: "disk.raw"),
            to: destinationStateURL.appending(path: "disk.raw")
        )
        let sourceQEMUURL = sourceStateURL.appending(
            path: "QEMU",
            directoryHint: .isDirectory
        )
        let destinationQEMUURL = destinationStateURL.appending(
            path: "QEMU",
            directoryHint: .isDirectory
        )
        for fileName in ["efi-code.fd", "efi-vars.fd", "tpm-state"] {
            let sourceURL = sourceQEMUURL.appending(path: fileName)
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                continue
            }
            try fileManager.createDirectory(
                at: destinationQEMUURL,
                withIntermediateDirectories: true
            )
            try APFSCloneStorage.clone(
                from: sourceURL,
                to: destinationQEMUURL.appending(path: fileName)
            )
        }
    }

    private func swap(_ firstURL: URL, _ secondURL: URL) throws {
        let result = firstURL.path.withCString { firstPath in
            secondURL.path.withCString { secondPath in
                renamex_np(firstPath, secondPath, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
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

public enum SnapshotStoreError: LocalizedError, Equatable {
    case invalidWindowsState

    public var errorDescription: String? {
        "The Windows machine state is not stored as an atomic generation."
    }
}
