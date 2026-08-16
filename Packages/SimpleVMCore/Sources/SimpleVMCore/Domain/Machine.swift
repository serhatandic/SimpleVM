import Foundation

public struct MachineSpec: Codable, Hashable, Sendable {
    public var cpuCount: Int
    public var memorySizeBytes: UInt64
    public var diskSizeBytes: UInt64
    public var architecture: GuestArchitecture
    public var sharedDirectoryPath: String?
    public var rosettaEnabled: Bool
    public var portForwards: [PortForward]

    public init(
        cpuCount: Int,
        memorySizeBytes: UInt64,
        diskSizeBytes: UInt64,
        architecture: GuestArchitecture,
        sharedDirectoryPath: String? = nil,
        rosettaEnabled: Bool = false,
        portForwards: [PortForward] = []
    ) {
        self.cpuCount = cpuCount
        self.memorySizeBytes = memorySizeBytes
        self.diskSizeBytes = diskSizeBytes
        self.architecture = architecture
        self.sharedDirectoryPath = sharedDirectoryPath
        self.rosettaEnabled = rosettaEnabled
        self.portForwards = portForwards
    }

    private enum CodingKeys: String, CodingKey {
        case cpuCount
        case memorySizeBytes
        case diskSizeBytes
        case architecture
        case sharedDirectoryPath
        case rosettaEnabled
        case portForwards
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cpuCount = try container.decode(Int.self, forKey: .cpuCount)
        memorySizeBytes = try container.decode(
            UInt64.self,
            forKey: .memorySizeBytes
        )
        diskSizeBytes = try container.decode(
            UInt64.self,
            forKey: .diskSizeBytes
        )
        architecture = try container.decode(
            GuestArchitecture.self,
            forKey: .architecture
        )
        sharedDirectoryPath = try container.decodeIfPresent(
            String.self,
            forKey: .sharedDirectoryPath
        )
        rosettaEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .rosettaEnabled
        ) ?? false
        portForwards = try container.decodeIfPresent(
            [PortForward].self,
            forKey: .portForwards
        ) ?? []
    }
}

public enum MachineProvisioningState: Codable, Hashable, Sendable {
    case downloading(progress: Double)
    case verifying
    case preparingDisk
    case readyToInstall
    case installing
    case ready
    case failed(message: String)
}

public enum MachineRuntimeState: Codable, Hashable, Sendable {
    case stopped
    case starting
    case running
    case stopping
    case failed(message: String)
}

public enum BootMedia: Codable, Hashable, Sendable {
    case installer(imageID: UUID)
    case systemDisk
}

public struct BackendStateReference: Codable, Hashable, Sendable {
    public let relativeDirectory: String

    public init(relativeDirectory: String) {
        self.relativeDirectory = relativeDirectory
    }
}

public struct MachineDisk: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var relativePath: String
    public var capacityBytes: UInt64

    public init(
        id: UUID = UUID(),
        relativePath: String,
        capacityBytes: UInt64
    ) {
        self.id = id
        self.relativePath = relativePath
        self.capacityBytes = capacityBytes
    }
}

public struct Machine: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var spec: MachineSpec
    public var sourceImageID: UUID
    public var disk: MachineDisk
    public var provisioningState: MachineProvisioningState
    public var runtimeState: MachineRuntimeState
    public var bootMedia: BootMedia
    public var backend: VirtualizationBackendKind
    public var backendState: BackendStateReference
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        spec: MachineSpec,
        sourceImageID: UUID,
        disk: MachineDisk,
        provisioningState: MachineProvisioningState,
        runtimeState: MachineRuntimeState = .stopped,
        bootMedia: BootMedia,
        backend: VirtualizationBackendKind,
        backendState: BackendStateReference,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.spec = spec
        self.sourceImageID = sourceImageID
        self.disk = disk
        self.provisioningState = provisioningState
        self.runtimeState = runtimeState
        self.bootMedia = bootMedia
        self.backend = backend
        self.backendState = backendState
        self.createdAt = createdAt
    }
}
