import Virtualization

public enum AppleRosettaSupport {
    @MainActor
    public static func ensureInstalled() async throws {
        switch VZLinuxRosettaDirectoryShare.availability {
        case .installed:
            return
        case .notInstalled:
            try await VZLinuxRosettaDirectoryShare.installRosetta()
        case .notSupported:
            throw AppleRosettaError.notSupported
        @unknown default:
            throw AppleRosettaError.notSupported
        }
    }

    @MainActor
    public static func makeDevice()
        throws -> VZVirtioFileSystemDeviceConfiguration
    {
        try VZVirtioFileSystemDeviceConfiguration.validateTag("rosetta")
        let device = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
        device.share = try VZLinuxRosettaDirectoryShare()
        return device
    }
}

public enum AppleRosettaError: LocalizedError, Equatable {
    case notSupported
    case invalidTag

    public var errorDescription: String? {
        switch self {
        case .notSupported:
            "Rosetta is not supported on this Mac."
        case .invalidTag:
            "The Rosetta shared-directory tag is invalid."
        }
    }
}
