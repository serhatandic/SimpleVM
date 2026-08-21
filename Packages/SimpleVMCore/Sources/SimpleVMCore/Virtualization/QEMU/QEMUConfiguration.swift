import Foundation

public struct QEMUSoftwareTPMConfiguration: Equatable, Sendable {
    public let executableURL: URL
    public let stateURL: URL
    public let socketURL: URL
    public let logURL: URL

    public init(
        executableURL: URL,
        stateURL: URL,
        socketURL: URL,
        logURL: URL
    ) {
        self.executableURL = executableURL
        self.stateURL = stateURL
        self.socketURL = socketURL
        self.logURL = logURL
    }
}

public struct QEMUConfiguration: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let vncPort: UInt16
    public let qmpSocketURL: URL
    public let logURL: URL
    public let spiceSocketURL: URL?
    public let agentSocketURL: URL?
    public let qemuGuestAgentSocketURL: URL?
    public let softwareTPM: QEMUSoftwareTPMConfiguration?

    public init(
        executableURL: URL,
        arguments: [String],
        vncPort: UInt16,
        qmpSocketURL: URL,
        logURL: URL,
        spiceSocketURL: URL? = nil,
        agentSocketURL: URL? = nil,
        qemuGuestAgentSocketURL: URL? = nil,
        softwareTPM: QEMUSoftwareTPMConfiguration? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.vncPort = vncPort
        self.qmpSocketURL = qmpSocketURL
        self.logURL = logURL
        self.spiceSocketURL = spiceSocketURL
        self.agentSocketURL = agentSocketURL
        self.qemuGuestAgentSocketURL = qemuGuestAgentSocketURL
        self.softwareTPM = softwareTPM
    }
}

public struct QEMUDisplaySize: Equatable, Sendable {
    public static let fallback = QEMUDisplaySize(width: 1_280, height: 800)

    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = max(640, width)
        self.height = max(480, height)
    }
}

public enum QEMUConfigurationBuilder {
    public static func make(
        machine: Machine,
        diskURL: URL,
        installerURL: URL?,
        supportToolsURL: URL? = nil,
        backendStateURL: URL,
        runtime: QEMURuntime,
        vncPort: UInt16,
        displaySize: QEMUDisplaySize = .fallback
    ) throws -> QEMUConfiguration {
        guard vncPort >= 5_900 else {
            throw QEMUConfigurationError.invalidVNCPort
        }
        switch (machine.spec.operatingSystem, machine.spec.architecture) {
        case (.linux, .x86_64):
            return try makeLinuxX86(
                machine: machine,
                diskURL: diskURL,
                installerURL: installerURL,
                backendStateURL: backendStateURL,
                runtime: runtime,
                vncPort: vncPort,
                displaySize: displaySize
            )
        case (.windows, .arm64):
            return try makeWindowsARM64(
                machine: machine,
                diskURL: diskURL,
                installerURL: installerURL,
                supportToolsURL: supportToolsURL,
                backendStateURL: backendStateURL,
                runtime: runtime,
                vncPort: vncPort
            )
        case (.linux, .arm64), (.windows, .x86_64):
            throw QEMUConfigurationError.unsupportedGuest
        }
    }

    private static func makeLinuxX86(
        machine: Machine,
        diskURL: URL,
        installerURL: URL?,
        backendStateURL: URL,
        runtime: QEMURuntime,
        vncPort: UInt16,
        displaySize: QEMUDisplaySize
    ) throws -> QEMUConfiguration {
        guard runtime.architecture == .x86_64 else {
            throw QEMUConfigurationError.runtimeArchitectureMismatch
        }
        let paths = try preparePaths(
            machine: machine,
            backendStateURL: backendStateURL,
            runtime: runtime
        )
        let fileManager = FileManager.default
        let memoryMiB = max(512, machine.spec.memorySizeBytes / 1_024 / 1_024)
        let displayNumber = Int(vncPort) - 5_900
        let displayDeviceSize =
            "xres=\(displaySize.width),yres=\(displaySize.height)"
        let forwarding = machine.spec.portForwards.map {
            "hostfwd=tcp:127.0.0.1:\($0.hostPort)-:\($0.guestPort)"
        }
        let networkDefinition = (["user", "id=net0"] + forwarding)
            .joined(separator: ",")
        let audioBackend: String
        let cpuCount: Int
        let accelerator: String
        switch runtime.displayBackend {
        case .vnc:
            audioBackend = "coreaudio,id=audio0"
            cpuCount = min(machine.spec.cpuCount, 2)
            accelerator = "tcg,tb-size=1024"
        case .spiceGL:
            audioBackend = "spice,id=audio0"
            cpuCount = machine.spec.cpuCount
            accelerator = "tcg,thread=multi,tb-size=2048"
        }
        var arguments = [
            "-name", escapedName(machine.name),
            "-machine", "q35,hpet=off",
            "-accel", accelerator,
            "-cpu", "max",
            "-smp", String(cpuCount),
            "-m", String(memoryMiB),
            "-nodefaults",
            "-qmp", "unix:\(paths.qmpURL.path),server=on,wait=off",
            "-serial", "file:\(paths.serialURL.path)",
            "-device", "virtio-serial-pci",
            "-chardev",
            "socket,id=agent,path=\(paths.agentURL.path),server=on,wait=off",
            "-device",
            "virtserialport,chardev=agent,name=com.simplevm.agent.0",
            "-drive",
            "if=pflash,format=\(paths.codeFormat.rawValue),unit=0,readonly=on,file=\(paths.codeURL.path)",
            "-drive",
            "if=pflash,format=\(paths.variablesFormat.rawValue),unit=1,file=\(paths.variablesURL.path)",
            "-drive",
            "if=none,id=system-disk,file=\(diskURL.path),format=raw,cache=writeback,aio=threads,discard=unmap,detect-zeroes=unmap",
            "-device",
            "virtio-blk-pci,drive=system-disk,bootindex=0",
            "-device", "virtio-rng-pci",
            "-netdev", networkDefinition,
            "-device", "virtio-net-pci,netdev=net0",
            "-audiodev", audioBackend,
            "-device", "ich9-intel-hda,id=hda",
            "-device", "hda-output,bus=hda.0,audiodev=audio0"
        ]
        if let sharedDirectoryPath = machine.spec.sharedDirectoryPath {
            try validateSharedDirectory(
                sharedDirectoryPath,
                fileManager: fileManager
            )
            let escapedPath = sharedDirectoryPath.replacingOccurrences(
                of: ",",
                with: ",,"
            )
            arguments.append(contentsOf: [
                "-fsdev",
                "local,id=shared,path=\(escapedPath),security_model=mapped-xattr,multidevs=remap",
                "-device",
                "virtio-9p-pci,fsdev=shared,mount_tag=share"
            ])
        }
        switch runtime.displayBackend {
        case .vnc:
            arguments.append(contentsOf: [
                "-display", "none",
                "-vnc", "127.0.0.1:\(displayNumber)",
                "-device", "virtio-vga,\(displayDeviceSize)",
                "-device", "qemu-xhci",
                "-device", "usb-kbd",
                "-device", "usb-tablet"
            ])
        case .spiceGL(let resourceDirectoryURL):
            arguments.append(contentsOf: [
                "-L", resourceDirectoryURL.path,
                "-display", "none",
                "-spice",
                "unix=on,addr=\(paths.spiceURL.path),disable-ticketing=on,gl=on,image-compression=off,playback-compression=off,streaming-video=off",
                "-device", "virtio-vga-gl,\(displayDeviceSize)",
                "-chardev", "spicevmc,id=vdagent,name=vdagent",
                "-device",
                "virtserialport,chardev=vdagent,name=com.redhat.spice.0",
                "-device", "virtio-keyboard-pci",
                "-device", "virtio-tablet-pci"
            ])
        }
        if let installerURL {
            arguments.append(contentsOf: [
                "-drive",
                "if=none,id=installer,file=\(installerURL.path),media=cdrom,readonly=on",
                "-device",
                "ide-cd,drive=installer,bootindex=1"
            ])
        }
        return QEMUConfiguration(
            executableURL: runtime.systemExecutableURL,
            arguments: arguments,
            vncPort: vncPort,
            qmpSocketURL: paths.qmpURL,
            logURL: paths.logURL,
            spiceSocketURL: runtime.displayBackend == .vnc
                ? nil
                : paths.spiceURL,
            agentSocketURL: paths.agentURL
        )
    }

    private static func makeWindowsARM64(
        machine: Machine,
        diskURL: URL,
        installerURL: URL?,
        supportToolsURL: URL?,
        backendStateURL: URL,
        runtime: QEMURuntime,
        vncPort: UInt16
    ) throws -> QEMUConfiguration {
        guard runtime.architecture == .arm64,
              runtime.acceleration == .hvf else {
            throw QEMUConfigurationError.runtimeArchitectureMismatch
        }
        guard !machine.spec.rosettaEnabled else {
            throw QEMUConfigurationError.rosettaUnavailable
        }
        guard let profile = machine.spec.qemuHardwareProfile else {
            throw QEMUConfigurationError.missingHardwareProfile
        }
        guard profile.machineType.hasPrefix("virt-"),
              isValidMACAddress(profile.macAddress) else {
            throw QEMUConfigurationError.invalidHardwareProfile
        }
        guard let swtpmExecutableURL = runtime.softwareTPMExecutableURL else {
            throw QEMUConfigurationError.softwareTPMUnavailable
        }
        let paths = try preparePaths(
            machine: machine,
            backendStateURL: backendStateURL,
            runtime: runtime
        )
        if let sharedDirectoryPath = machine.spec.sharedDirectoryPath {
            try validateSharedDirectory(
                sharedDirectoryPath,
                fileManager: .default
            )
        }
        let memoryMiB = max(4_096, machine.spec.memorySizeBytes / 1_024 / 1_024)
        let machineType = machine.spec.cpuCount > 8
            ? "\(profile.machineType),gic-version=3"
            : profile.machineType
        let forwarding = machine.spec.portForwards.map {
            "hostfwd=tcp:127.0.0.1:\($0.hostPort)-:\($0.guestPort)"
        }
        let networkDefinition = (["user", "id=net0"] + forwarding)
            .joined(separator: ",")
        let nvmeSerial = profile.hardwareUUID.uuidString.replacingOccurrences(
            of: "-",
            with: ""
        )
        let tpm = QEMUSoftwareTPMConfiguration(
            executableURL: swtpmExecutableURL,
            stateURL: backendStateURL.appending(path: "tpm-state"),
            socketURL: paths.tpmURL,
            logURL: backendStateURL.appending(path: "swtpm.log")
        )
        var arguments = [
            "-name", escapedName(machine.name),
            "-machine", machineType,
            "-accel", "hvf",
            "-cpu", "host",
            "-smp", String(machine.spec.cpuCount),
            "-m", String(memoryMiB),
            "-nodefaults",
            "-uuid", profile.hardwareUUID.uuidString,
            "-rtc", "base=localtime",
            "-qmp", "unix:\(paths.qmpURL.path),server=on,wait=off",
            "-serial", "file:\(paths.serialURL.path)",
            "-drive",
            "if=pflash,format=\(paths.codeFormat.rawValue),unit=0,readonly=on,file=\(paths.codeURL.path)",
            "-drive",
            "if=pflash,format=\(paths.variablesFormat.rawValue),unit=1,file=\(paths.variablesURL.path)",
            "-chardev",
            "socket,id=chrtpm0,path=\(tpm.socketURL.path)",
            "-tpmdev",
            "emulator,id=tpm0,chardev=chrtpm0",
            "-device",
            "tpm-crb-device,tpmdev=tpm0",
            "-drive",
            "if=none,id=system-disk,file=\(diskURL.path),format=raw,cache=writeback,aio=threads,discard=unmap,detect-zeroes=unmap",
            "-device",
            "nvme,drive=system-disk,serial=\(nvmeSerial),bootindex=0",
            "-device", "virtio-rng-pci",
            "-netdev", networkDefinition,
            "-device",
            "virtio-net-pci,netdev=net0,mac=\(profile.macAddress)",
            "-audiodev", "spice,id=audio0",
            "-device", "intel-hda,id=hda",
            "-device", "hda-duplex,bus=hda.0,audiodev=audio0",
            "-device", "nec-usb-xhci,id=usb-bus",
            "-device", "usb-kbd,bus=usb-bus.0",
            "-device", "usb-tablet,bus=usb-bus.0",
            "-device", "virtio-serial-pci",
            "-chardev",
            "socket,id=qga,path=\(paths.qgaURL.path),server=on,wait=off",
            "-device",
            "virtserialport,chardev=qga,name=org.qemu.guest_agent.0",
            "-L", paths.resourceDirectoryURL.path,
            "-display", "none",
            "-spice",
            "unix=on,addr=\(paths.spiceURL.path),disable-ticketing=on,gl=off,image-compression=off,playback-compression=off,streaming-video=off",
            "-device",
            machine.spec.displayMode == .compatibility
                ? "ramfb"
                : "virtio-ramfb",
            "-chardev", "spicevmc,id=vdagent,name=vdagent",
            "-device",
            "virtserialport,chardev=vdagent,name=com.redhat.spice.0"
        ]
        if machine.spec.sharedDirectoryPath != nil {
            arguments.append(contentsOf: [
                "-chardev",
                "spiceport,name=org.spice-space.webdav.0,id=webdav",
                "-device",
                "virtserialport,chardev=webdav,name=org.spice-space.webdav.0"
            ])
        }
        if let installerURL {
            arguments.append(contentsOf: usbCDArguments(
                id: "installer",
                url: installerURL,
                bootIndex: 1
            ))
        }
        if machine.spec.windowsSupportToolsAttached,
           let supportToolsURL {
            arguments.append(contentsOf: usbCDArguments(
                id: "support-tools",
                url: supportToolsURL,
                bootIndex: nil
            ))
        }
        return QEMUConfiguration(
            executableURL: runtime.systemExecutableURL,
            arguments: arguments,
            vncPort: vncPort,
            qmpSocketURL: paths.qmpURL,
            logURL: paths.logURL,
            spiceSocketURL: paths.spiceURL,
            qemuGuestAgentSocketURL: paths.qgaURL,
            softwareTPM: tpm
        )
    }

    private static func preparePaths(
        machine: Machine,
        backendStateURL: URL,
        runtime: QEMURuntime
    ) throws -> RuntimePaths {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: backendStateURL,
            withIntermediateDirectories: true
        )
        let variablesURL = backendStateURL.appending(path: "efi-vars.fd")
        let codeURL = backendStateURL.appending(path: "efi-code.fd")
        if !fileManager.fileExists(atPath: codeURL.path) {
            try fileManager.copyItem(
                at: runtime.firmwareCodeURL,
                to: codeURL
            )
        }
        if !fileManager.fileExists(atPath: variablesURL.path) {
            try fileManager.copyItem(
                at: runtime.firmwareVariablesTemplateURL,
                to: variablesURL
            )
        }
        let prefix = "svm-\(machine.id.uuidString.prefix(8))"
        let socketDirectory = URL(
            filePath: NSTemporaryDirectory(),
            directoryHint: .isDirectory
        )
        let resourceDirectoryURL: URL
        switch runtime.displayBackend {
        case .vnc:
            resourceDirectoryURL = runtime.firmwareCodeURL.deletingLastPathComponent()
        case .spiceGL(let url):
            resourceDirectoryURL = url
        }
        let socketURLs = [
            socketDirectory.appending(path: "\(prefix)-qmp.sock"),
            socketDirectory.appending(path: "\(prefix)-agent.sock"),
            socketDirectory.appending(path: "\(prefix)-qga.sock"),
            socketDirectory.appending(path: "\(prefix)-spice.sock"),
            socketDirectory.appending(path: "\(prefix)-tpm.sock")
        ]
        for url in socketURLs
        where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        return RuntimePaths(
            codeURL: codeURL,
            codeFormat: try QEMURuntimeDiscovery.imageFormat(at: codeURL),
            variablesURL: variablesURL,
            variablesFormat: try QEMURuntimeDiscovery.imageFormat(
                at: variablesURL
            ),
            qmpURL: socketURLs[0],
            agentURL: socketURLs[1],
            qgaURL: socketURLs[2],
            spiceURL: socketURLs[3],
            tpmURL: socketURLs[4],
            logURL: backendStateURL.appending(path: "qemu.log"),
            serialURL: backendStateURL.appending(path: "serial.log"),
            resourceDirectoryURL: resourceDirectoryURL
        )
    }

    private static func usbCDArguments(
        id: String,
        url: URL,
        bootIndex: Int?
    ) -> [String] {
        var device = "usb-storage,drive=\(id),removable=on,bus=usb-bus.0"
        if let bootIndex {
            device += ",bootindex=\(bootIndex)"
        }
        return [
            "-drive",
            "if=none,id=\(id),file=\(url.path),media=cdrom,readonly=on",
            "-device",
            device
        ]
    }

    private static func escapedName(_ name: String) -> String {
        name.replacingOccurrences(of: ",", with: ",,")
    }

    private static func validateSharedDirectory(
        _ path: String,
        fileManager: FileManager
    ) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw QEMUConfigurationError.sharedDirectoryUnavailable(path)
        }
    }

    private static func isValidMACAddress(_ value: String) -> Bool {
        let parts = value.split(separator: ":")
        return parts.count == 6 && parts.allSatisfy {
            $0.count == 2 && UInt8($0, radix: 16) != nil
        }
    }
}

private struct RuntimePaths {
    let codeURL: URL
    let codeFormat: QEMUImageFormat
    let variablesURL: URL
    let variablesFormat: QEMUImageFormat
    let qmpURL: URL
    let agentURL: URL
    let qgaURL: URL
    let spiceURL: URL
    let tpmURL: URL
    let logURL: URL
    let serialURL: URL
    let resourceDirectoryURL: URL
}

public enum QEMUConfigurationError: LocalizedError, Equatable {
    case unsupportedGuest
    case runtimeArchitectureMismatch
    case invalidVNCPort
    case sharedDirectoryUnavailable(String)
    case rosettaUnavailable
    case missingHardwareProfile
    case invalidHardwareProfile
    case softwareTPMUnavailable

    public var errorDescription: String? {
        switch self {
        case .unsupportedGuest:
            "QEMU does not support this guest OS and architecture combination."
        case .runtimeArchitectureMismatch:
            "The discovered QEMU runtime does not match the guest architecture."
        case .invalidVNCPort:
            "The selected VNC port is invalid."
        case .sharedDirectoryUnavailable(let path):
            "The configured shared directory is unavailable: \(path)"
        case .rosettaUnavailable:
            "Apple Rosetta cannot be attached to a Windows guest."
        case .missingHardwareProfile:
            "The Windows machine is missing its virtual hardware identity."
        case .invalidHardwareProfile:
            "The Windows machine has an invalid virtual hardware profile."
        case .softwareTPMUnavailable:
            "The Windows machine requires a TPM 2.0 runtime."
        }
    }
}
