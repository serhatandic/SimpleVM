import Foundation

public struct QEMUConfiguration: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let vncPort: UInt16
    public let qmpSocketURL: URL
    public let logURL: URL
    public let spiceSocketURL: URL?

    public init(
        executableURL: URL,
        arguments: [String],
        vncPort: UInt16,
        qmpSocketURL: URL,
        logURL: URL,
        spiceSocketURL: URL? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.vncPort = vncPort
        self.qmpSocketURL = qmpSocketURL
        self.logURL = logURL
        self.spiceSocketURL = spiceSocketURL
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
        backendStateURL: URL,
        runtime: QEMURuntime,
        vncPort: UInt16,
        displaySize: QEMUDisplaySize = .fallback
    ) throws -> QEMUConfiguration {
        guard machine.spec.architecture == .x86_64 else {
            throw QEMUConfigurationError.unsupportedArchitecture
        }
        guard vncPort >= 5_900 else {
            throw QEMUConfigurationError.invalidVNCPort
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: backendStateURL,
            withIntermediateDirectories: true
        )
        let variablesURL = backendStateURL.appending(path: "efi-vars.fd")
        if !fileManager.fileExists(atPath: variablesURL.path) {
            try fileManager.copyItem(
                at: runtime.firmwareVariablesTemplateURL,
                to: variablesURL
            )
        }
        let socketPrefix = "svm-\(machine.id.uuidString.prefix(8))"
        let socketDirectory = URL(
            filePath: NSTemporaryDirectory(),
            directoryHint: .isDirectory
        )
        let qmpURL = socketDirectory.appending(path: "\(socketPrefix)-qmp.sock")
        let agentURL = socketDirectory.appending(
            path: "\(socketPrefix)-agent.sock"
        )
        let spiceURL = socketDirectory.appending(
            path: "\(socketPrefix)-spice.sock"
        )
        let logURL = backendStateURL.appending(path: "qemu.log")
        let serialURL = backendStateURL.appending(path: "serial.log")
        let memoryMiB = max(512, machine.spec.memorySizeBytes / 1_024 / 1_024)
        let displayNumber = Int(vncPort) - 5_900
        let displayDeviceSize =
            "xres=\(displaySize.width),yres=\(displaySize.height)"

        let forwarding = machine.spec.portForwards.map {
            "hostfwd=tcp:127.0.0.1:\($0.hostPort)-:\($0.guestPort)"
        }
        let networkDefinition = (["user", "id=net0"] + forwarding)
            .joined(separator: ",")
        let cpuCount: Int
        let accelerator: String
        switch runtime.displayBackend {
        case .vnc:
            cpuCount = min(machine.spec.cpuCount, 2)
            accelerator = "tcg,tb-size=1024"
        case .spiceGL:
            cpuCount = machine.spec.cpuCount
            accelerator = "tcg,thread=multi,tb-size=2048"
        }
        var arguments = [
            "-name", machine.name.replacingOccurrences(of: ",", with: ",,"),
            "-machine", "q35,hpet=off",
            "-accel", accelerator,
            "-cpu", "max",
            "-smp", String(cpuCount),
            "-m", String(memoryMiB),
            "-nodefaults",
            "-qmp", "unix:\(qmpURL.path),server=on,wait=off",
            "-serial", "file:\(serialURL.path)",
            "-device", "virtio-serial-pci",
            "-chardev",
            "socket,id=agent,path=\(agentURL.path),server=on,wait=off",
            "-device",
            "virtserialport,chardev=agent,name=com.simplevm.agent.0",
            "-drive",
            "if=pflash,format=raw,unit=0,readonly=on,file=\(runtime.firmwareCodeURL.path)",
            "-drive",
            "if=pflash,format=raw,unit=1,file=\(variablesURL.path)",
            "-drive",
            "if=none,id=system-disk,file=\(diskURL.path),format=raw,cache=writeback,aio=threads,discard=unmap,detect-zeroes=unmap",
            "-device",
            "virtio-blk-pci,drive=system-disk,bootindex=0",
            "-device", "virtio-rng-pci",
            "-netdev", networkDefinition,
            "-device", "virtio-net-pci,netdev=net0"
        ]
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
                "unix=on,addr=\(spiceURL.path),disable-ticketing=on,gl=on,image-compression=off,playback-compression=off,streaming-video=off",
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
            qmpSocketURL: qmpURL,
            logURL: logURL,
            spiceSocketURL: runtime.displayBackend == .vnc
                ? nil
                : spiceURL
        )
    }
}

public enum QEMUConfigurationError: LocalizedError, Equatable {
    case unsupportedArchitecture
    case invalidVNCPort

    public var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture:
            "QEMU compatibility mode expects an x86_64 guest."
        case .invalidVNCPort:
            "The selected VNC port is invalid."
        }
    }
}
