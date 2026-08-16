import Foundation

public actor ManagedImageStore {
    private let layout: StorageLayout
    private let fileManager: FileManager

    public init(
        layout: StorageLayout,
        fileManager: FileManager = .default
    ) {
        self.layout = layout
        self.fileManager = fileManager
    }

    public func destinationURL(
        imageID: UUID,
        fileExtension: String
    ) throws -> URL {
        try layout.initialize(fileManager: fileManager)
        let directory = layout.imagesURL.appending(
            path: imageID.uuidString,
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appending(path: "artifact.\(fileExtension)")
    }

    public func importFile(
        from sourceURL: URL,
        imageID: UUID
    ) throws -> URL {
        let accessedSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileExtension = sourceURL.pathExtension.isEmpty
            ? "bin"
            : sourceURL.pathExtension.lowercased()
        let destinationURL = try destinationURL(
            imageID: imageID,
            fileExtension: fileExtension
        )

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    public func removeImage(id: UUID) throws {
        let directory = layout.imagesURL.appending(
            path: id.uuidString,
            directoryHint: .isDirectory
        )
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }
}
