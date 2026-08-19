import Foundation
import Virtualization

public enum AppleVirtualMachineConfigurationFactory {
    public static let defaultDisplayWidth = 1_280
    public static let defaultDisplayHeight = 800

    @MainActor
    public static func make(
        machine: Machine,
        diskURL: URL,
        installerURL: URL?,
        backendStateURL: URL,
        serialOutput: FileHandle? = nil
    ) throws -> VZVirtualMachineConfiguration {
        guard machine.spec.architecture == .arm64 else {
            throw AppleConfigurationError.unsupportedArchitecture
        }
        let allowedCPUCounts = (
            VZVirtualMachineConfiguration.minimumAllowedCPUCount
                ... VZVirtualMachineConfiguration.maximumAllowedCPUCount
        )
        guard allowedCPUCounts.contains(machine.spec.cpuCount) else {
            throw AppleConfigurationError.invalidCPUCount
        }
        let allowedMemorySizes = (
            VZVirtualMachineConfiguration.minimumAllowedMemorySize
                ... VZVirtualMachineConfiguration.maximumAllowedMemorySize
        )
        guard allowedMemorySizes.contains(machine.spec.memorySizeBytes) else {
            throw AppleConfigurationError.invalidMemorySize
        }

        let configuration = VZVirtualMachineConfiguration()
        if let linuxBoot = try AppleLinuxBootAssets.load(
            backendStateURL: backendStateURL
        ) {
            let bootLoader = VZLinuxBootLoader(
                kernelURL: linuxBoot.kernelURL
            )
            bootLoader.initialRamdiskURL = linuxBoot.initialRamdiskURL
            bootLoader.commandLine = linuxBoot.commandLine
            configuration.bootLoader = bootLoader
        } else {
            configuration.bootLoader = try AppleBackendState.bootLoader(
                at: backendStateURL
            )
        }
        configuration.platform = try AppleBackendState.platformConfiguration(
            at: backendStateURL
        )
        configuration.cpuCount = machine.spec.cpuCount
        configuration.memorySize = machine.spec.memorySizeBytes

        var storageDevices: [VZStorageDeviceConfiguration] = []
        if let installerURL {
            storageDevices.append(
                VZVirtioBlockDeviceConfiguration(
                    attachment: try VZDiskImageStorageDeviceAttachment(
                        url: installerURL,
                        readOnly: true,
                        cachingMode: .cached,
                        synchronizationMode: .none
                    )
                )
            )
        }
        storageDevices.append(
            VZVirtioBlockDeviceConfiguration(
                attachment: try VZDiskImageStorageDeviceAttachment(
                    url: diskURL,
                    readOnly: false,
                    cachingMode: .automatic,
                    synchronizationMode: .full
                )
            )
        )
        configuration.storageDevices = storageDevices
        configuration.networkDevices = [makeNetworkDevice()]
        configuration.graphicsDevices = [makeGraphicsDevice()]
        configuration.audioDevices = [makeAudioDevice()]
        configuration.keyboards = [VZUSBKeyboardConfiguration()]
        configuration.pointingDevices = [
            VZUSBScreenCoordinatePointingDeviceConfiguration()
        ]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [
            VZVirtioTraditionalMemoryBalloonDeviceConfiguration()
        ]

        var directoryShares: [VZDirectorySharingDeviceConfiguration] = []
        if let sharedDirectoryPath = machine.spec.sharedDirectoryPath {
            directoryShares.append(
                makeDirectoryShare(path: sharedDirectoryPath)
            )
        }
        if machine.spec.rosettaEnabled {
            directoryShares.append(try AppleRosettaSupport.makeDevice())
        }
        configuration.directorySharingDevices = directoryShares
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        if let serialOutput {
            let serialPort = VZVirtioConsoleDeviceSerialPortConfiguration()
            serialPort.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: nil,
                fileHandleForWriting: serialOutput
            )
            configuration.serialPorts = [serialPort]
        }

        try configuration.validate()
        return configuration
    }

    @MainActor
    private static func makeNetworkDevice() -> VZVirtioNetworkDeviceConfiguration {
        let device = VZVirtioNetworkDeviceConfiguration()
        device.attachment = VZNATNetworkDeviceAttachment()
        return device
    }

    @MainActor
    private static func makeGraphicsDevice() -> VZVirtioGraphicsDeviceConfiguration {
        let device = VZVirtioGraphicsDeviceConfiguration()
        device.scanouts = [
            VZVirtioGraphicsScanoutConfiguration(
                widthInPixels: defaultDisplayWidth,
                heightInPixels: defaultDisplayHeight
            )
        ]
        return device
    }

    @MainActor
    private static func makeAudioDevice() -> VZVirtioSoundDeviceConfiguration {
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()

        let device = VZVirtioSoundDeviceConfiguration()
        device.streams = [output]
        return device
    }

    @MainActor
    private static func makeDirectoryShare(
        path: String
    ) -> VZVirtioFileSystemDeviceConfiguration {
        let device = VZVirtioFileSystemDeviceConfiguration(tag: "share")
        let directory = VZSharedDirectory(
            url: URL(filePath: path),
            readOnly: false
        )
        device.share = VZSingleDirectoryShare(directory: directory)
        return device
    }
}

public enum AppleConfigurationError: LocalizedError, Equatable {
    case unsupportedArchitecture
    case invalidCPUCount
    case invalidMemorySize

    public var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture:
            "Apple Virtualization supports ARM64 guests on this host."
        case .invalidCPUCount:
            "The selected CPU count is outside the host-supported range."
        case .invalidMemorySize:
            "The selected memory size is outside the host-supported range."
        }
    }
}
