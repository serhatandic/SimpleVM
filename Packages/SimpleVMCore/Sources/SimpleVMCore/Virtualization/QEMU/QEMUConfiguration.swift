import Foundation

public struct QEMUConfiguration: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let vncPort: UInt16
    public let qmpSocketURL: URL
    public let logURL: URL

    public init(
        executableURL: URL,
        arguments: [String],
        vncPort: UInt16,
        qmpSocketURL: URL,
        logURL: URL
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.vncPort = vncPort
        self.qmpSocketURL = qmpSocketURL
        self.logURL = logURL
    }
}

public enum QEMUConfigurationBuilder {
    public static func make(
        machine: Machine,
        diskURL: URL,
        installerURL: URL?,
        backendStateURL: URL,
        runtime: QEMURuntime,
        vncPort: UInt16
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
        let logURL = backendStateURL.appending(path: "qemu.log")
        let memoryMiB = max(512, machine.spec.memorySizeBytes / 1_024 / 1_024)
        let displayNumber = Int(vncPort) - 5_900

        let forwarding = machine.spec.portForwards.map {
            "hostfwd=tcp:127.0.0.1:\($0.hostPort)-:\($0.guestPort)"
        }
        let networkDefinition = (["user", "id=net0"] + forwarding)
            .joined(separator: ",")
        var arguments = [
            "-name", machine.name.replacingOccurrences(of: ",", with: ",,"),
            "-machine", "q35,accel=tcg",
            "-cpu", "max",
            "-smp", String(machine.spec.cpuCount),
            "-m", String(memoryMiB),
            "-nodefaults",
            "-display", "none",
            "-vnc", "127.0.0.1:\(displayNumber)",
            "-qmp", "unix:\(qmpURL.path),server=on,wait=off",
            "-device", "virtio-serial-pci",
            "-chardev",
            "socket,id=agent,path=\(agentURL.path),server=on,wait=off",
            "-device",
            "virtserialport,chardev=agent,name=com.simplevm.agent.0",
            "-drive",
            "if=pflash,format=raw,unit=0,readonly=on,file=\(runtime.firmwareCodeURL.path)",
            "-drive",
            "if=pflash,format=raw,unit=1,file=\(variablesURL.path)",
            "-drive", "file=\(diskURL.path),if=virtio,format=raw",
            "-device", "virtio-vga,xres=1280,yres=800",
            "-device", "qemu-xhci",
            "-device", "usb-kbd",
            "-device", "usb-tablet",
            "-netdev", networkDefinition,
            "-device", "virtio-net-pci,netdev=net0"
        ]
        if let installerURL {
            arguments.append(contentsOf: [
                "-drive",
                "file=\(installerURL.path),media=cdrom,readonly=on"
            ])
        }

        return QEMUConfiguration(
            executableURL: runtime.systemExecutableURL,
            arguments: arguments,
            vncPort: vncPort,
            qmpSocketURL: qmpURL,
            logURL: logURL
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
