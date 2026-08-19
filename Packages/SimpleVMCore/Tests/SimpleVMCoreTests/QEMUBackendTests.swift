import Foundation
import Testing
@testable import SimpleVMCore

@Test
func discoversInstalledQEMURuntimeWhenAvailable() throws {
    let runtime: QEMURuntime
    do {
        runtime = try QEMURuntimeDiscovery.discover()
    } catch QEMURuntimeError.notFound {
        return
    }

    #expect(runtime.systemExecutableURL.lastPathComponent == "qemu-system-x86_64")
    #expect(runtime.imageExecutableURL.lastPathComponent == "qemu-img")
    #expect(runtime.firmwareCodeURL.lastPathComponent == "edk2-x86_64-code.fd")
}

@Test
func buildsExplicitQEMUArgumentsAndPersistentFirmware() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString,
        directoryHint: .isDirectory
    )
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let executableURL = directory.appending(path: "qemu-system-x86_64")
    let imageExecutableURL = directory.appending(path: "qemu-img")
    let codeURL = directory.appending(path: "edk2-code.fd")
    let variablesTemplateURL = directory.appending(path: "edk2-vars.fd")
    let diskURL = directory.appending(path: "disk.raw")
    let installerURL = directory.appending(path: "installer.iso")
    for url in [
        executableURL,
        imageExecutableURL,
        codeURL,
        variablesTemplateURL,
        diskURL,
        installerURL
    ] {
        FileManager.default.createFile(
            atPath: url.path,
            contents: Data(repeating: 0, count: 512)
        )
    }

    let imageID = UUID()
    let machine = Machine(
        name: "Compatibility, Test",
        spec: MachineSpec(
            cpuCount: 2,
            memorySizeBytes: 2 * 1_024 * 1_024 * 1_024,
            diskSizeBytes: 8 * 1_024 * 1_024 * 1_024,
            architecture: .x86_64
        ),
        sourceImageID: imageID,
        disk: MachineDisk(
            relativePath: "disk.raw",
            capacityBytes: 8 * 1_024 * 1_024 * 1_024
        ),
        provisioningState: .readyToInstall,
        bootMedia: .installer(imageID: imageID),
        backend: .qemu,
        backendState: BackendStateReference(relativeDirectory: "QEMU")
    )
    let backendURL = directory.appending(path: "QEMU")
    let configuration = try QEMUConfigurationBuilder.make(
        machine: machine,
        diskURL: diskURL,
        installerURL: installerURL,
        backendStateURL: backendURL,
        runtime: QEMURuntime(
            systemExecutableURL: executableURL,
            imageExecutableURL: imageExecutableURL,
            firmwareCodeURL: codeURL,
            firmwareVariablesTemplateURL: variablesTemplateURL
        ),
        vncPort: 5_901
    )

    #expect(configuration.arguments.contains("q35,hpet=off"))
    #expect(configuration.arguments.contains("tcg,tb-size=1024"))
    #expect(configuration.arguments.contains("max"))
    #expect(configuration.arguments.contains("Compatibility,, Test"))
    #expect(configuration.arguments.contains("127.0.0.1:1"))
    #expect(configuration.arguments.contains("virtio-vga,xres=1280,yres=800"))
    #expect(
        configuration.arguments.contains(
            "virtio-blk-pci,drive=system-disk,bootindex=0"
        )
    )
    #expect(
        configuration.arguments.contains(
            "ide-cd,drive=installer,bootindex=1"
        )
    )
    #expect(
        configuration.arguments.contains(where: {
            $0.hasPrefix("file:")
                && $0.hasSuffix("/serial.log")
        })
    )
    #expect(configuration.arguments.contains {
        $0.contains("media=cdrom")
    })
    #expect(FileManager.default.fileExists(
        atPath: backendURL.appending(path: "efi-vars.fd").path
    ))
    #expect(configuration.qmpSocketURL.path.utf8.count < 104)
    #expect(configuration.agentSocketURL?.lastPathComponent.hasSuffix(
        "-agent.sock"
    ) == true)
    #expect(configuration.arguments.contains {
        $0.contains(configuration.agentSocketURL!.path)
            && $0.contains("server=on,wait=off")
    })

    let accelerated = try QEMUConfigurationBuilder.make(
        machine: machine,
        diskURL: diskURL,
        installerURL: nil,
        backendStateURL: backendURL,
        runtime: QEMURuntime(
            systemExecutableURL: executableURL,
            imageExecutableURL: imageExecutableURL,
            firmwareCodeURL: codeURL,
            firmwareVariablesTemplateURL: variablesTemplateURL,
            displayBackend: .spiceGL(
                resourceDirectoryURL: directory
            )
        ),
        vncPort: 5_902,
        displaySize: QEMUDisplaySize(width: 3_024, height: 1_964)
    )
    #expect(accelerated.spiceSocketURL != nil)
    #expect(accelerated.arguments.contains("virtio-vga-gl,xres=3024,yres=1964"))
    #expect(accelerated.arguments.contains("spicevmc,id=vdagent,name=vdagent"))
    #expect(accelerated.arguments.contains(
        "virtserialport,chardev=vdagent,name=com.redhat.spice.0"
    ))
    #expect(accelerated.arguments.contains("virtio-keyboard-pci"))
    #expect(accelerated.arguments.contains("virtio-tablet-pci"))
    #expect(accelerated.arguments.contains("tcg,thread=multi,tb-size=2048"))
    #expect(accelerated.arguments.contains(where: {
        $0.contains("disable-ticketing=on,gl=on")
    }))
    #expect(!accelerated.arguments.contains("-vnc"))
}

@Test
func supervisesRealQEMUProcessWhenAvailable() async throws {
    let runtime: QEMURuntime
    do {
        runtime = try QEMURuntimeDiscovery.discover()
    } catch QEMURuntimeError.notFound {
        return
    }

    let directory = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString,
        directoryHint: .isDirectory
    )
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let controller = QEMUProcessController()
    try await controller.start(
        configuration: QEMUConfiguration(
            executableURL: runtime.systemExecutableURL,
            arguments: ["--version"],
            vncPort: 5_900,
            qmpSocketURL: directory.appending(path: "qmp.sock"),
            logURL: directory.appending(path: "qemu.log")
        )
    )

    for _ in 0..<100 where await controller.state == .running {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await controller.state == .stopped)
}

@Test
func intentionalProcessTerminationRemainsStopped() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString,
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    for _ in 0..<25 {
        let controller = QEMUProcessController()
        try await controller.start(
            configuration: QEMUConfiguration(
                executableURL: URL(filePath: "/bin/sleep"),
                arguments: ["30"],
                vncPort: 5_900,
                qmpSocketURL: directory.appending(path: "qmp.sock"),
                logURL: directory.appending(path: UUID().uuidString)
            )
        )
        await controller.stop()
        try await Task.sleep(for: .milliseconds(10))
        #expect(await controller.state == .stopped)
    }
}

@Test
func rendersRealX86InstallerFramebufferWhenFixtureIsConfigured() async throws {
    let repositoryURL = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let pathFile = repositoryURL
        .appending(path: ".build/TestFixtures/x86_64-iso-path")
    guard let fixturePath = try? String(
        contentsOf: pathFile,
        encoding: .utf8
    ).trimmingCharacters(in: .whitespacesAndNewlines) else {
        return
    }
    let runtime = try QEMURuntimeDiscovery.discover()
    let directory = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString,
        directoryHint: .isDirectory
    )
    defer {
        try? FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let diskURL = directory.appending(path: "disk.raw")
    try SparseDiskCreator.create(
        at: diskURL,
        capacityBytes: 1 * 1_024 * 1_024 * 1_024
    )
    let imageID = UUID()
    let machine = Machine(
        name: "QEMU Framebuffer Test",
        spec: MachineSpec(
            cpuCount: 2,
            memorySizeBytes: 2 * 1_024 * 1_024 * 1_024,
            diskSizeBytes: 1 * 1_024 * 1_024 * 1_024,
            architecture: .x86_64
        ),
        sourceImageID: imageID,
        disk: MachineDisk(
            relativePath: "disk.raw",
            capacityBytes: 1 * 1_024 * 1_024 * 1_024
        ),
        provisioningState: .readyToInstall,
        bootMedia: .installer(imageID: imageID),
        backend: .qemu,
        backendState: BackendStateReference(relativeDirectory: "QEMU")
    )
    let configuration = try QEMUConfigurationBuilder.make(
        machine: machine,
        diskURL: diskURL,
        installerURL: URL(filePath: fixturePath),
        backendStateURL: directory.appending(path: "QEMU"),
        runtime: runtime,
        vncPort: 5_997
    )
    let controller = QEMUProcessController()
    try await controller.start(configuration: configuration)
    defer {
        Task { await controller.forceStop() }
    }
    try await Task.sleep(for: .seconds(1))

    let client = SimpleVNCClient(port: 5_997)
    let imageReceived = Confirmation()
    client.imageHandler = { image in
        if image.width > 640 && image.height > 480 {
            imageReceived.confirm()
        }
    }
    try await client.connect()
    await imageReceived.wait(timeout: .seconds(90))
    client.disconnect()
    await controller.forceStop()
}

private final class Confirmation: @unchecked Sendable {
    private let lock = NSLock()
    private var confirmed = false

    func confirm() {
        lock.withLock {
            confirmed = true
        }
    }

    func wait(timeout: Duration) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if lock.withLock({ confirmed }) {
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Timed out waiting for QEMU framebuffer.")
    }
}
