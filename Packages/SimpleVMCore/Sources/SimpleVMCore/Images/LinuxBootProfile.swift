import Foundation

public struct LinuxBootProfile: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let architecture: GuestArchitecture
    public let kernelURL: URL
    public let kernelSHA256: String
    public let initialRamdiskURL: URL?
    public let initialRamdiskSHA256: String?
    public let commandLine: String

    public init(
        id: String,
        name: String,
        architecture: GuestArchitecture,
        kernelURL: URL,
        kernelSHA256: String,
        initialRamdiskURL: URL? = nil,
        initialRamdiskSHA256: String? = nil,
        commandLine: String
    ) {
        self.id = id
        self.name = name
        self.architecture = architecture
        self.kernelURL = kernelURL
        self.kernelSHA256 = kernelSHA256
        self.initialRamdiskURL = initialRamdiskURL
        self.initialRamdiskSHA256 = initialRamdiskSHA256
        self.commandLine = commandLine
    }
}

public enum LinuxBootProfileCatalog {
    public static func bundled() throws -> [LinuxBootProfile] {
        guard let url = Bundle.module.url(
            forResource: "LinuxBootProfiles",
            withExtension: "json"
        ) else {
            throw LinuxBootProfileError.missingCatalog
        }
        return try JSONDecoder().decode(
            [LinuxBootProfile].self,
            from: Data(contentsOf: url)
        )
    }
}

public enum LinuxBootProfileError: LocalizedError {
    case missingCatalog
    case incompatibleArchitecture

    public var errorDescription: String? {
        switch self {
        case .missingCatalog:
            "The Linux boot-profile catalog is missing."
        case .incompatibleArchitecture:
            "The selected boot profile is incompatible with this image."
        }
    }
}

