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
    #expect(runtime.imageExecutableURL?.lastPathComponent == "qemu-img")
    #expect(runtime.firmwareCodeURL.lastPathComponent == "edk2-x86_64-code.fd")
}

@Test
func discoversUTMOnlyWindowsARMRuntime() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString,
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let helpersURL = directory.appending(
        path: "Helpers",
        directoryHint: .isDirectory
    )
    let utmURL = directory.appending(
        path: "UTM.app",
        directoryHint: .isDirectory
    )
    let resourcesURL = utmURL.appending(
        path: "Contents/Resources/qemu",
        directoryHint: .isDirectory
    )
    let frameworkURL = utmURL.appending(
        path:
            "Contents/Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu"
    )
    try FileManager.default.createDirectory(
        at: helpersURL,
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: resourcesURL,
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: frameworkURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    for url in [
        helpersURL.appending(path: "UTMQEMUARM64Launcher"),
        helpersURL.appending(path: "UTMSWTPMLauncher")
    ] {
        FileManager.default.createFile(atPath: url.path, contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }
    FileManager.default.createFile(
        atPath: frameworkURL.path,
        contents: Data()
    )
    FileManager.default.createFile(
        atPath: resourcesURL.appending(
            path: "edk2-aarch64-secure-code.fd"
        ).path,
        contents: Data(repeating: 0, count: 8)
    )
    var qcow2Header = Data(repeating: 0, count: 32)
    qcow2Header.replaceSubrange(
        0..<4,
        with: [0x51, 0x46, 0x49, 0xfb]
    )
    qcow2Header.replaceSubrange(
        24..<32,
        with: [0, 0, 0, 0, 4, 0, 0, 0]
    )
    FileManager.default.createFile(
        atPath: resourcesURL.appending(
            path: "edk2-arm-secure-vars.fd"
        ).path,
        contents: qcow2Header
    )

    let runtime = try QEMURuntimeDiscovery.discover(
        for: .windows,
        architecture: .arm64,
        environment: [:],
        bundleURL: nil,
        helperDirectoryURL: helpersURL,
        utmURL: utmURL
    )
    #expect(runtime.architecture == .arm64)
    #expect(runtime.acceleration == .hvf)
    #expect(runtime.firmwareVariablesFormat == .qcow2)
    #expect(
        try QEMURuntimeDiscovery.qcow2VirtualSize(
            at: runtime.firmwareVariablesTemplateURL
        ) == 64 * 1_024 * 1_024
    )
    #expect(runtime.imageExecutableURL == nil)
    #expect(
        runtime.softwareTPMExecutableURL?.lastPathComponent
            == "UTMSWTPMLauncher"
    )
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
    let sharedDirectoryURL = directory.appending(
        path: "shared,folder",
        directoryHint: .isDirectory
    )
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
    try FileManager.default.createDirectory(
        at: sharedDirectoryURL,
        withIntermediateDirectories: true
    )

    let imageID = UUID()
    let machine = Machine(
        name: "Compatibility, Test",
        spec: MachineSpec(
            cpuCount: 2,
            memorySizeBytes: 2 * 1_024 * 1_024 * 1_024,
            diskSizeBytes: 8 * 1_024 * 1_024 * 1_024,
            architecture: .x86_64,
            sharedDirectoryPath: sharedDirectoryURL.path
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
            "local,id=shared,path=\(sharedDirectoryURL.path.replacingOccurrences(of: ",", with: ",,")),security_model=mapped-xattr,multidevs=remap"
        )
    )
    #expect(
        configuration.arguments.contains(
            "virtio-9p-pci,fsdev=shared,mount_tag=share"
        )
    )
    #expect(configuration.arguments.contains("coreaudio,id=audio0"))
    #expect(configuration.arguments.contains("ich9-intel-hda,id=hda"))
    #expect(
        configuration.arguments.contains(
            "hda-output,bus=hda.0,audiodev=audio0"
        )
    )
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
    var machineWithoutShare = machine
    machineWithoutShare.spec.sharedDirectoryPath = nil
    let configurationWithoutShare = try QEMUConfigurationBuilder.make(
        machine: machineWithoutShare,
        diskURL: diskURL,
        installerURL: nil,
        backendStateURL: backendURL,
        runtime: QEMURuntime(
            systemExecutableURL: executableURL,
            imageExecutableURL: imageExecutableURL,
            firmwareCodeURL: codeURL,
            firmwareVariablesTemplateURL: variablesTemplateURL
        ),
        vncPort: 5_903
    )
    #expect(!configurationWithoutShare.arguments.contains("-fsdev"))
    #expect(!configurationWithoutShare.arguments.contains {
        $0.contains("virtio-9p")
    })

    var machineWithMissingShare = machine
    machineWithMissingShare.spec.sharedDirectoryPath =
        directory.appending(path: "missing-share").path
    #expect(
        throws: QEMUConfigurationError.sharedDirectoryUnavailable(
            machineWithMissingShare.spec.sharedDirectoryPath!
        )
    ) {
        try QEMUConfigurationBuilder.make(
            machine: machineWithMissingShare,
            diskURL: diskURL,
            installerURL: nil,
            backendStateURL: backendURL,
            runtime: QEMURuntime(
                systemExecutableURL: executableURL,
                imageExecutableURL: imageExecutableURL,
                firmwareCodeURL: codeURL,
                firmwareVariablesTemplateURL: variablesTemplateURL
            ),
            vncPort: 5_904
        )
    }
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

    let persistedBackendURL = directory.appending(path: "PersistedQEMU")
    try FileManager.default.createDirectory(
        at: persistedBackendURL,
        withIntermediateDirectories: true
    )
    try Data(repeating: 0, count: 512).write(
        to: persistedBackendURL.appending(path: "efi-code.fd")
    )
    try Data(repeating: 0, count: 512).write(
        to: persistedBackendURL.appending(path: "efi-vars.fd")
    )
    let persistedConfiguration = try QEMUConfigurationBuilder.make(
        machine: machineWithoutShare,
        diskURL: diskURL,
        installerURL: nil,
        backendStateURL: persistedBackendURL,
        runtime: QEMURuntime(
            systemExecutableURL: executableURL,
            imageExecutableURL: imageExecutableURL,
            firmwareCodeURL: codeURL,
            firmwareVariablesTemplateURL: variablesTemplateURL,
            firmwareVariablesFormat: .qcow2
        ),
        vncPort: 5_906
    )
    #expect(persistedConfiguration.arguments.contains {
        $0.contains("format=raw")
            && $0.contains("PersistedQEMU/efi-vars.fd")
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
    #expect(accelerated.arguments.contains("spice,id=audio0"))
    #expect(accelerated.arguments.contains("ich9-intel-hda,id=hda"))
    #expect(
        accelerated.arguments.contains(
            "hda-output,bus=hda.0,audiodev=audio0"
        )
    )
    #expect(!accelerated.arguments.contains { $0.hasPrefix("hda-duplex") })
    #expect(!accelerated.arguments.contains { $0.hasPrefix("hda-micro") })
    #expect(accelerated.arguments.contains("tcg,thread=multi,tb-size=2048"))
    #expect(accelerated.arguments.contains(where: {
        $0.contains("disable-ticketing=on,gl=on")
    }))
    #expect(!accelerated.arguments.contains("-vnc"))
}

@Test
func buildsWindowsARMHVFConfiguration() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString,
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let executableURL = directory.appending(path: "UTMQEMUARM64Launcher")
    let swtpmURL = directory.appending(path: "UTMSWTPMLauncher")
    let codeURL = directory.appending(path: "edk2-aarch64-secure-code.fd")
    let variablesURL = directory.appending(path: "edk2-arm-secure-vars.fd")
    let diskURL = directory.appending(path: "disk.raw")
    let installerURL = directory.appending(path: "windows.iso")
    let supportURL = directory.appending(path: "support.iso")
    let sharedURL = directory.appending(
        path: "Shared",
        directoryHint: .isDirectory
    )
    for url in [
        executableURL,
        swtpmURL,
        codeURL,
        diskURL,
        installerURL,
        supportURL
    ] {
        FileManager.default.createFile(
            atPath: url.path,
            contents: Data(repeating: 0, count: 8)
        )
    }
    try Data([0x51, 0x46, 0x49, 0xfb]).write(to: variablesURL)
    try FileManager.default.createDirectory(
        at: sharedURL,
        withIntermediateDirectories: true
    )
    let hardwareUUID = UUID(
        uuidString: "12345678-1234-5678-9ABC-DEF012345678"
    )!
    let imageID = UUID()
    let machine = Machine(
        name: "Windows 11",
        spec: MachineSpec(
            cpuCount: 4,
            memorySizeBytes: 8 * 1_024 * 1_024 * 1_024,
            diskSizeBytes: 128 * 1_024 * 1_024 * 1_024,
            architecture: .arm64,
            operatingSystem: .windows,
            sharedDirectoryPath: sharedURL.path,
            qemuHardwareProfile: .windowsARM64(
                hardwareUUID: hardwareUUID
            ),
            windowsSupportToolsAttached: true
        ),
        sourceImageID: imageID,
        disk: MachineDisk(
            relativePath: "disk.raw",
            capacityBytes: 128 * 1_024 * 1_024 * 1_024
        ),
        provisioningState: .readyToInstall,
        bootMedia: .installer(imageID: imageID),
        backend: .qemu,
        backendState: BackendStateReference(relativeDirectory: "QEMU")
    )
    let configuration = try QEMUConfigurationBuilder.make(
        machine: machine,
        diskURL: diskURL,
        installerURL: installerURL,
        supportToolsURL: supportURL,
        backendStateURL: directory.appending(path: "QEMU"),
        runtime: QEMURuntime(
            architecture: .arm64,
            systemExecutableURL: executableURL,
            imageExecutableURL: nil,
            firmwareCodeURL: codeURL,
            firmwareCodeFormat: .raw,
            firmwareVariablesTemplateURL: variablesURL,
            firmwareVariablesFormat: .qcow2,
            displayBackend: .spiceGL(resourceDirectoryURL: directory),
            acceleration: .hvf,
            softwareTPMExecutableURL: swtpmURL
        ),
        vncPort: 5_905
    )

    #expect(configuration.arguments.contains("virt-10.0"))
    #expect(configuration.arguments.contains("hvf"))
    #expect(configuration.arguments.contains("host"))
    #expect(configuration.arguments.contains(hardwareUUID.uuidString))
    #expect(configuration.arguments.contains {
        $0.contains("format=qcow2") && $0.contains("efi-vars.fd")
    })
    #expect(configuration.arguments.contains("tpm-crb-device,tpmdev=tpm0"))
    #expect(!configuration.arguments.contains("tpm-crb,tpmdev=tpm0"))
    #expect(configuration.arguments.contains {
        $0.hasPrefix("nvme,drive=system-disk,serial=")
            && $0.contains("bootindex=0")
    })
    #expect(configuration.arguments.contains(
        "virtio-net-pci,netdev=net0,mac=12:34:56:78:12:34"
    ))
    #expect(configuration.arguments.contains("virtio-ramfb"))
    #expect(configuration.arguments.contains {
        $0.contains("disable-ticketing=on,gl=off")
    })
    #expect(configuration.arguments.contains {
        $0.contains("id=installer") && $0.contains(installerURL.path)
    })
    #expect(configuration.arguments.contains {
        $0.contains("id=support-tools") && $0.contains(supportURL.path)
    })
    #expect(configuration.arguments.contains(
        "virtserialport,chardev=webdav,name=org.spice-space.webdav.0"
    ))
    #expect(configuration.arguments.contains(
        "virtserialport,chardev=qga,name=org.qemu.guest_agent.0"
    ))
    #expect(!configuration.arguments.contains {
        $0.contains("virtio-9p") || $0.contains("com.simplevm.agent")
    })
    #expect(configuration.softwareTPM?.executableURL == swtpmURL)
    #expect(configuration.qemuGuestAgentSocketURL != nil)
    let copiedVariablesURL = directory.appending(path: "QEMU/efi-vars.fd")
    #expect(
        try QEMURuntimeDiscovery.imageFormat(at: copiedVariablesURL) == .qcow2
    )
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
func startsRealWindowsARMFirmwareWhenHelpersAreConfigured() async throws {
    guard let helperPath = ProcessInfo.processInfo.environment[
        "SIMPLEVM_ARM_QEMU_HELPER_DIR"
    ] else {
        return
    }
    let runtime = try QEMURuntimeDiscovery.discover(
        for: .windows,
        architecture: .arm64,
        helperDirectoryURL: URL(
            filePath: helperPath,
            directoryHint: .isDirectory
        )
    )
    let supportToolsURL = ProcessInfo.processInfo.environment[
        "SIMPLEVM_WINDOWS_SUPPORT_ISO_FIXTURE"
    ].map { URL(filePath: $0) }
    let directory = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString,
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let diskURL = directory.appending(path: "disk.raw")
    try SparseDiskCreator.create(
        at: diskURL,
        capacityBytes: 64 * 1_024 * 1_024
    )
    let machine = Machine(
        name: "Windows ARM Firmware Test",
        spec: MachineSpec(
            cpuCount: 2,
            memorySizeBytes: 4 * 1_024 * 1_024 * 1_024,
            diskSizeBytes: 64 * 1_024 * 1_024,
            architecture: .arm64,
            operatingSystem: .windows,
            qemuHardwareProfile: .windowsARM64(),
            windowsSupportToolsAttached: supportToolsURL != nil
        ),
        sourceImageID: UUID(),
        disk: MachineDisk(
            relativePath: "disk.raw",
            capacityBytes: 64 * 1_024 * 1_024
        ),
        provisioningState: .ready,
        bootMedia: .systemDisk,
        backend: .qemu,
        backendState: BackendStateReference(relativeDirectory: "QEMU")
    )
    let configuration = try QEMUConfigurationBuilder.make(
        machine: machine,
        diskURL: diskURL,
        installerURL: nil,
        supportToolsURL: supportToolsURL,
        backendStateURL: directory.appending(path: "QEMU"),
        runtime: runtime,
        vncPort: 5_998
    )
    let tpm = SoftwareTPMProcessController()
    try await tpm.start(configuration: #require(configuration.softwareTPM))
    let qemu = QEMUProcessController()
    try await qemu.start(configuration: configuration)
    try await Task.sleep(for: .seconds(2))

    #expect(await qemu.state == .running)

    await qemu.forceStop()
    await tpm.stop()
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
        let result = await controller.stop(gracePeriod: .zero)
        guard case .requestFailed = result else {
            Issue.record("Expected a missing QMP control failure.")
            await controller.forceStop()
            return
        }
        await controller.forceStop()
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
