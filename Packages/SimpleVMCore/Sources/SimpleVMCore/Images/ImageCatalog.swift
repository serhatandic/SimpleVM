import Foundation

public struct ImageCatalogEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let version: String?
    public let operatingSystem: GuestOperatingSystem
    public let architecture: GuestArchitecture
    public let artifactKind: ImageArtifactKind
    public let remoteURL: URL
    public let sha256: String
    public let sizeBytes: Int64

    public init(
        id: String,
        name: String,
        version: String? = nil,
        operatingSystem: GuestOperatingSystem = .linux,
        architecture: GuestArchitecture,
        artifactKind: ImageArtifactKind,
        remoteURL: URL,
        sha256: String,
        sizeBytes: Int64
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.artifactKind = artifactKind
        self.remoteURL = remoteURL
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case version
        case operatingSystem
        case architecture
        case artifactKind
        case remoteURL
        case sha256
        case sizeBytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        operatingSystem = try container.decodeIfPresent(
            GuestOperatingSystem.self,
            forKey: .operatingSystem
        ) ?? .linux
        architecture = try container.decode(
            GuestArchitecture.self,
            forKey: .architecture
        )
        artifactKind = try container.decode(
            ImageArtifactKind.self,
            forKey: .artifactKind
        )
        remoteURL = try container.decode(URL.self, forKey: .remoteURL)
        sha256 = try container.decode(String.self, forKey: .sha256)
        sizeBytes = try container.decode(Int64.self, forKey: .sizeBytes)
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
