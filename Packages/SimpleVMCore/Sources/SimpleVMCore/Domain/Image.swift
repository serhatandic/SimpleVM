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
        self.architecture = architecture
        self.artifactKind = artifactKind
        self.origin = origin
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.availability = availability
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
