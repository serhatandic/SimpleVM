import Foundation

public enum ManagedFileExporter {
    public static func export(
        from sourceURL: URL,
        to destinationURL: URL,
        protectedRootURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw ManagedFileExportError.sourceUnavailable
        }
        if let protectedRootURL,
           contains(
            destinationURL,
            in: protectedRootURL,
            fileManager: fileManager
           ) {
            throw ManagedFileExportError.destinationInsideManagedStorage
        }
        guard sourceURL.resolvingSymlinksInPath().standardizedFileURL
                != destinationURL.resolvingSymlinksInPath()
                    .standardizedFileURL else {
            throw ManagedFileExportError.destinationMatchesSource
        }

        let accessedSecurityScope =
            destinationURL.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                destinationURL.stopAccessingSecurityScopedResource()
            }
        }

        let temporaryURL = destinationURL
            .deletingLastPathComponent()
            .appending(
                path:
                    ".\(destinationURL.lastPathComponent).simplevm-\(UUID().uuidString)"
            )
        defer {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: temporaryURL
            )
        } else {
            try fileManager.moveItem(
                at: temporaryURL,
                to: destinationURL
            )
        }
    }

    private static func contains(
        _ candidateURL: URL,
        in rootURL: URL,
        fileManager: FileManager
    ) -> Bool {
        let rootComponents = canonicalURL(
            rootURL,
            fileManager: fileManager
        ).pathComponents
        let candidateComponents = canonicalURL(
            candidateURL,
            fileManager: fileManager
        ).pathComponents
        return candidateComponents.starts(with: rootComponents)
    }

    private static func canonicalURL(
        _ url: URL,
        fileManager: FileManager
    ) -> URL {
        if fileManager.fileExists(atPath: url.path) {
            return url.resolvingSymlinksInPath().standardizedFileURL
        }
        return url
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appending(path: url.lastPathComponent)
            .standardizedFileURL
    }
}

public enum ManagedFileExportError: LocalizedError, Equatable {
    case sourceUnavailable
    case destinationMatchesSource
    case destinationInsideManagedStorage

    public var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            "The managed source file is unavailable."
        case .destinationMatchesSource:
            "Choose a destination different from the managed source file."
        case .destinationInsideManagedStorage:
            "Choose a destination outside SimpleVM's managed storage."
        }
    }
}
