import Foundation

public struct StorageLayout: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public static func live(
        fileManager: FileManager = .default
    ) throws -> StorageLayout {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return StorageLayout(
            rootURL: applicationSupport.appending(
                path: "SimpleVM",
                directoryHint: .isDirectory
            )
        )
    }

    public var metadataURL: URL {
        rootURL.appending(path: "library.json")
    }

    public var imagesURL: URL {
        rootURL.appending(path: "Images", directoryHint: .isDirectory)
    }

    public var machinesURL: URL {
        rootURL.appending(path: "Machines", directoryHint: .isDirectory)
    }

    public var downloadsURL: URL {
        rootURL.appending(path: "Downloads", directoryHint: .isDirectory)
    }

    public var logsURL: URL {
        rootURL.appending(path: "Logs", directoryHint: .isDirectory)
    }

    public func machineURL(id: UUID) -> URL {
        machinesURL.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    public func relativePath(for url: URL) throws -> String {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        guard urlComponents.starts(with: rootComponents) else {
            throw StorageLayoutError.outsideManagedStorage
        }
        return urlComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    public func resolve(relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..") else {
            throw StorageLayoutError.invalidRelativePath
        }
        return rootURL.appending(path: relativePath)
    }

    public func initialize(fileManager: FileManager = .default) throws {
        for directory in [rootURL, imagesURL, machinesURL, downloadsURL, logsURL] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }
}

public enum StorageLayoutError: LocalizedError, Equatable {
    case outsideManagedStorage
    case invalidRelativePath

    public var errorDescription: String? {
        switch self {
        case .outsideManagedStorage:
            "The file is outside SimpleVM managed storage."
        case .invalidRelativePath:
            "The managed storage path is invalid."
        }
    }
}
