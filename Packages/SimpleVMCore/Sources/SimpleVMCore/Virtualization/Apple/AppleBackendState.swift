import Foundation
import Virtualization

public struct AppleBackendStateURLs: Sendable {
    public let directoryURL: URL
    public let machineIdentifierURL: URL
    public let variableStoreURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
        self.machineIdentifierURL = directoryURL.appending(path: "machine-identifier")
        self.variableStoreURL = directoryURL.appending(path: "efi-variable-store")
    }
}

public enum AppleBackendState {
    @MainActor
    public static func platformConfiguration(
        at directoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> VZGenericPlatformConfiguration {
        let urls = AppleBackendStateURLs(directoryURL: directoryURL)
        try fileManager.createDirectory(
            at: urls.directoryURL,
            withIntermediateDirectories: true
        )

        let machineIdentifier: VZGenericMachineIdentifier
        if fileManager.fileExists(atPath: urls.machineIdentifierURL.path) {
            let data = try Data(contentsOf: urls.machineIdentifierURL)
            guard let restoredIdentifier = VZGenericMachineIdentifier(
                dataRepresentation: data
            ) else {
                throw AppleBackendStateError.invalidMachineIdentifier
            }
            machineIdentifier = restoredIdentifier
        } else {
            machineIdentifier = VZGenericMachineIdentifier()
            try machineIdentifier.dataRepresentation.write(
                to: urls.machineIdentifierURL,
                options: .atomic
            )
        }

        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = machineIdentifier
        return platform
    }

    @MainActor
    public static func bootLoader(
        at directoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> VZEFIBootLoader {
        let urls = AppleBackendStateURLs(directoryURL: directoryURL)
        let variableStore: VZEFIVariableStore
        if fileManager.fileExists(atPath: urls.variableStoreURL.path) {
            variableStore = VZEFIVariableStore(url: urls.variableStoreURL)
        } else {
            try fileManager.createDirectory(
                at: urls.directoryURL,
                withIntermediateDirectories: true
            )
            variableStore = try VZEFIVariableStore(
                creatingVariableStoreAt: urls.variableStoreURL
            )
        }

        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = variableStore
        return bootLoader
    }
}

public enum AppleBackendStateError: LocalizedError, Equatable {
    case invalidMachineIdentifier

    public var errorDescription: String? {
        switch self {
        case .invalidMachineIdentifier:
            "The machine’s persisted Apple platform identifier is invalid."
        }
    }
}
