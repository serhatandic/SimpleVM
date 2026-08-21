import Foundation

public enum ImageArtifactKind: String, Codable, CaseIterable, Sendable {
    case installerISO
    case preinstalledDisk
    case rootfsArchive
    case ociReference

    public var displayName: String {
        switch self {
        case .installerISO:
            "Installer ISO"
        case .preinstalledDisk:
            "Preinstalled Disk"
        case .rootfsArchive:
            "Root Filesystem"
        case .ociReference:
            "OCI Image"
        }
    }
}

public enum ImageOrigin: Codable, Hashable, Sendable {
    case catalog(URL)
    case localImport(originalFileName: String)
    case remoteURL(URL)
    case oci(String)
}

public enum ImageAvailability: Codable, Hashable, Sendable {
    case remote
    case downloading(progress: Double)
    case verifying
    case available(relativePath: String)
    case failed(message: String)
}

public struct MachineImage: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var version: String?
    public var operatingSystem: GuestOperatingSystem
    public var architecture: GuestArchitecture
    public var artifactKind: ImageArtifactKind
    public var origin: ImageOrigin
    public var sha256: String?
    public var sizeBytes: Int64?
    public var availability: ImageAvailability

    public init(
        id: UUID = UUID(),
        name: String,
        version: String? = nil,
        operatingSystem: GuestOperatingSystem = .linux,
        architecture: GuestArchitecture,
        artifactKind: ImageArtifactKind,
        origin: ImageOrigin,
        sha256: String? = nil,
        sizeBytes: Int64? = nil,
        availability: ImageAvailability = .remote
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.artifactKind = artifactKind
        self.origin = origin
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.availability = availability
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case version
        case operatingSystem
        case architecture
        case artifactKind
        case origin
        case sha256
        case sizeBytes
        case availability
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
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
        origin = try container.decode(ImageOrigin.self, forKey: .origin)
        sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
        sizeBytes = try container.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        availability = try container.decode(
            ImageAvailability.self,
            forKey: .availability
        )
    }
}

public extension MachineImage {
    var suggestedExportFileName: String? {
        guard artifactKind != .ociReference else {
            return nil
        }
        let originalName: String?
        switch origin {
        case .localImport(let fileName):
            originalName = fileName
        case .catalog(let url), .remoteURL(let url):
            originalName = url.lastPathComponent
        case .oci:
            originalName = nil
        }
        if let originalName, !originalName.isEmpty {
            return originalName
        }

        let sanitizedName = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let baseName = sanitizedName.isEmpty ? "SimpleVM Image" : sanitizedName
        let fileExtension: String
        switch artifactKind {
        case .installerISO:
            fileExtension = "iso"
        case .preinstalledDisk:
            fileExtension = "raw"
        case .rootfsArchive:
            fileExtension = "tar"
        case .ociReference:
            return nil
        }
        return "\(baseName).\(fileExtension)"
    }
}
