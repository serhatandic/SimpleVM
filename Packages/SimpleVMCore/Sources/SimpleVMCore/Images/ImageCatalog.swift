import Foundation

public struct ImageCatalogEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let version: String?
    public let architecture: GuestArchitecture
    public let artifactKind: ImageArtifactKind
    public let remoteURL: URL
    public let sha256: String
    public let sizeBytes: Int64

    public init(
        id: String,
        name: String,
        version: String? = nil,
        architecture: GuestArchitecture,
        artifactKind: ImageArtifactKind,
        remoteURL: URL,
        sha256: String,
        sizeBytes: Int64
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.architecture = architecture
        self.artifactKind = artifactKind
        self.remoteURL = remoteURL
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
    }
}

public enum ImageCatalog {
    public static func bundled() throws -> [ImageCatalogEntry] {
        guard let url = Bundle.module.url(
            forResource: "ImageCatalog",
            withExtension: "json"
        ) else {
            throw ImageCatalogError.missingBundledCatalog
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([ImageCatalogEntry].self, from: data)
    }
}

public enum ImageCatalogError: LocalizedError {
    case missingBundledCatalog

    public var errorDescription: String? {
        switch self {
        case .missingBundledCatalog:
            "The bundled image catalog is missing."
        }
    }
}

