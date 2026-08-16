import Foundation

public struct LibrarySnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var machines: [Machine]
    public var images: [MachineImage]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        machines: [Machine] = [],
        images: [MachineImage] = []
    ) {
        self.schemaVersion = schemaVersion
        self.machines = machines
        self.images = images
    }
}

public enum LibraryStoreError: LocalizedError, Equatable {
    case unsupportedSchema(found: Int, supported: Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let found, let supported):
            "Library schema \(found) is not supported; this app supports schema \(supported)."
        }
    }
}

public actor LibraryStore {
    private let layout: StorageLayout
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        layout: StorageLayout,
        fileManager: FileManager = .default
    ) {
        self.layout = layout
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func load() throws -> LibrarySnapshot {
        try layout.initialize(fileManager: fileManager)
        guard fileManager.fileExists(atPath: layout.metadataURL.path) else {
            return LibrarySnapshot()
        }

        let data = try Data(contentsOf: layout.metadataURL)
        let snapshot = try decoder.decode(LibrarySnapshot.self, from: data)
        guard snapshot.schemaVersion == LibrarySnapshot.currentSchemaVersion else {
            throw LibraryStoreError.unsupportedSchema(
                found: snapshot.schemaVersion,
                supported: LibrarySnapshot.currentSchemaVersion
            )
        }
        return snapshot
    }

    public func save(_ snapshot: LibrarySnapshot) throws {
        guard snapshot.schemaVersion == LibrarySnapshot.currentSchemaVersion else {
            throw LibraryStoreError.unsupportedSchema(
                found: snapshot.schemaVersion,
                supported: LibrarySnapshot.currentSchemaVersion
            )
        }

        try layout.initialize(fileManager: fileManager)
        let data = try encoder.encode(snapshot)
        try data.write(to: layout.metadataURL, options: .atomic)
    }
}

