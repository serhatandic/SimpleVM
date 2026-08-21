import Foundation

public enum MachineInputProfile: String, Codable, CaseIterable, Hashable,
    Identifiable, Sendable
{
    case automatic
    case macOSGNOME
    case macOSHyprland
    case macOSWindows
    case linuxPassthrough

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .automatic:
            "Automatic"
        case .macOSGNOME:
            "macOS-style GNOME/Linux"
        case .macOSHyprland:
            "macOS-style Hyprland"
        case .macOSWindows:
            "macOS-style Windows"
        case .linuxPassthrough:
            "Linux passthrough"
        }
    }

    public func resolved(forMachineNamed name: String) -> Self {
        resolved(for: .linux, machineNamed: name)
    }

    public func resolved(
        for operatingSystem: GuestOperatingSystem,
        machineNamed name: String
    ) -> Self {
        guard self == .automatic else {
            return self
        }
        if operatingSystem == .windows {
            return .macOSWindows
        }
        let normalizedName = name.lowercased()
        return normalizedName.contains("omarchy")
            || normalizedName.contains("hyprland")
            ? .macOSHyprland
            : .macOSGNOME
    }
}

public enum MachineDisplayMode: String, Codable, CaseIterable, Hashable,
    Identifiable, Sendable
{
    case automatic
    case compatibility

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .automatic:
            "Automatic"
        case .compatibility:
            "Compatibility"
        }
    }
}

public struct QEMUHardwareProfile: Codable, Hashable, Sendable {
    public let machineType: String
    public let hardwareUUID: UUID
    public let macAddress: String

    public init(
        machineType: String,
        hardwareUUID: UUID,
        macAddress: String
    ) {
        self.machineType = machineType
        self.hardwareUUID = hardwareUUID
        self.macAddress = macAddress
    }

    public static func windowsARM64(
        machineType: String = "virt-10.0",
        hardwareUUID: UUID = UUID()
    ) -> Self {
        Self(
            machineType: machineType,
            hardwareUUID: hardwareUUID,
            macAddress: macAddress(for: hardwareUUID)
        )
    }

    public static func macAddress(for hardwareUUID: UUID) -> String {
        var value = hardwareUUID.uuid
        var bytes = withUnsafeBytes(of: &value) {
            Array($0.prefix(6))
        }
        bytes[0] = (bytes[0] & 0xfc) | 0x02
        return bytes.map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }
}

public struct MachineSpec: Codable, Hashable, Sendable {
    public var cpuCount: Int
    public var memorySizeBytes: UInt64
    public var diskSizeBytes: UInt64
    public var architecture: GuestArchitecture
    public var operatingSystem: GuestOperatingSystem
    public var sharedDirectoryPath: String?
    public var rosettaEnabled: Bool
    public var portForwards: [PortForward]
    public var inputProfile: MachineInputProfile
    public var customInputProfileID: UUID?
    public var qemuHardwareProfile: QEMUHardwareProfile?
    public var displayMode: MachineDisplayMode
    public var windowsSupportToolsAttached: Bool

    public init(
        cpuCount: Int,
        memorySizeBytes: UInt64,
        diskSizeBytes: UInt64,
        architecture: GuestArchitecture,
        operatingSystem: GuestOperatingSystem = .linux,
        sharedDirectoryPath: String? = nil,
        rosettaEnabled: Bool = false,
        portForwards: [PortForward] = [],
        inputProfile: MachineInputProfile = .automatic,
        customInputProfileID: UUID? = nil,
        qemuHardwareProfile: QEMUHardwareProfile? = nil,
        displayMode: MachineDisplayMode = .automatic,
        windowsSupportToolsAttached: Bool = false
    ) {
        self.cpuCount = cpuCount
        self.memorySizeBytes = memorySizeBytes
        self.diskSizeBytes = diskSizeBytes
        self.architecture = architecture
        self.operatingSystem = operatingSystem
        self.sharedDirectoryPath = sharedDirectoryPath
        self.rosettaEnabled = rosettaEnabled
        self.portForwards = portForwards
        self.inputProfile = inputProfile
        self.customInputProfileID = customInputProfileID
        self.qemuHardwareProfile = qemuHardwareProfile
        self.displayMode = displayMode
        self.windowsSupportToolsAttached = windowsSupportToolsAttached
    }

    private enum CodingKeys: String, CodingKey {
        case cpuCount
        case memorySizeBytes
        case diskSizeBytes
        case architecture
        case operatingSystem
        case sharedDirectoryPath
        case rosettaEnabled
        case portForwards
        case inputProfile
        case customInputProfileID
        case qemuHardwareProfile
        case displayMode
        case windowsSupportToolsAttached
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
        operatingSystem = try container.decodeIfPresent(
            GuestOperatingSystem.self,
            forKey: .operatingSystem
        ) ?? .linux
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
        inputProfile = try container.decodeIfPresent(
            MachineInputProfile.self,
            forKey: .inputProfile
        ) ?? .automatic
        customInputProfileID = try container.decodeIfPresent(
            UUID.self,
            forKey: .customInputProfileID
        )
        qemuHardwareProfile = try container.decodeIfPresent(
            QEMUHardwareProfile.self,
            forKey: .qemuHardwareProfile
        )
        displayMode = try container.decodeIfPresent(
            MachineDisplayMode.self,
            forKey: .displayMode
        ) ?? .automatic
        windowsSupportToolsAttached = try container.decodeIfPresent(
            Bool.self,
            forKey: .windowsSupportToolsAttached
        ) ?? false
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

    public var canStart: Bool {
        switch self {
        case .stopped, .failed:
            true
        case .starting, .running, .stopping:
            false
        }
    }
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
