import AppKit
import Security
import SimpleVMCore
import Virtualization
import XCTest
@testable import SimpleVM

final class FoundationTests: XCTestCase {
    func testAppBundleIdentity() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.simplevm.app")
    }

    func testAppHasVirtualizationEntitlement() throws {
        let task = try XCTUnwrap(SecTaskCreateFromSelf(nil))
        let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.security.virtualization" as CFString,
            nil
        )
        XCTAssertEqual(value as? Bool, true)
    }

    @MainActor
    func testImmersionExitShortcutIsHostOnly() throws {
        let matching = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.control, .option, .command],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            )
        )
        let ordinaryEscape = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            )
        )

        XCTAssertTrue(ImmersionController.isExitShortcut(matching))
        XCTAssertFalse(ImmersionController.isExitShortcut(ordinaryEscape))
    }

    @MainActor
    func testQEMUKeyMapperIgnoresUnknownFlagsChangedEvents() throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .flagsChanged,
                location: .zero,
                modifierFlags: [.shift],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: 0
            )
        )

        XCTAssertNil(QEMUKeyMapper.keysym(for: event))
    }

    @MainActor
    func testMacOSProfileMapsCommandCopyToGuestControlCopy() {
        let settings = KeyboardMappingSettings.shared
        let previousPreset = settings.preset
        defer { settings.preset = previousPreset }
        settings.preset = .macOS
        let chord = settings.chord(
            keyCode: 8,
            modifiers: [.command]
        )

        XCTAssertEqual(chord.keyCode, 8)
        XCTAssertTrue(chord.modifiers.contains(.control))
        XCTAssertFalse(chord.modifiers.contains(.command))
    }

    @MainActor
    func testUnmappedCommandChordUsesGuestSuper() {
        let settings = KeyboardMappingSettings.shared
        let previousPreset = settings.preset
        defer { settings.preset = previousPreset }
        settings.preset = .macOS
        let chord = settings.chord(
            keyCode: 16,
            modifiers: [.command]
        )

        XCTAssertEqual(chord.keyCode, 16)
        XCTAssertTrue(chord.modifiers.contains(.command))
    }

    @MainActor
    func testWorkspaceSwipeChordsFollowSelectedProfile() {
        let settings = KeyboardMappingSettings.shared
        let previousPreset = settings.preset
        defer { settings.preset = previousPreset }

        settings.preset = .macOS
        XCTAssertEqual(
            settings.workspaceChord(direction: .previous),
            GuestChord(keyCode: 116, modifiers: [.command])
        )
        settings.preset = .hyprland
        XCTAssertEqual(
            settings.workspaceChord(direction: .previous),
            GuestChord(keyCode: 48, modifiers: [.command, .shift])
        )
    }

    @MainActor
    func testQEMUKeyMapperUsesSuperAndMapsANSIKeys() {
        XCTAssertEqual(QEMUKeyMapper.keysym(forKeyCode: 8), 0x63)
        XCTAssertEqual(QEMUKeyMapper.modifierKeysym(for: 55), 0xffeb)
        XCTAssertEqual(
            QEMUKeyMapper.modifierKeysyms(for: [.command]),
            [0xffeb]
        )
    }

    @MainActor
    func testNavigationMappingsIgnoreSystemFunctionFlag() {
        let settings = KeyboardMappingSettings.shared
        let previousPreset = settings.preset
        defer { settings.preset = previousPreset }
        settings.preset = .macOS
        let chord = settings.chord(
            keyCode: 123,
            modifiers: [.command, .function]
        )

        XCTAssertEqual(chord.keyCode, 115)
        XCTAssertEqual(
            chord.modifiers.intersection(
                .deviceIndependentFlagsMask
            ),
            []
        )
    }

    @MainActor
    func testGuestInputRouterEmitsBalancedMappedChord() {
        var events: [NSEvent] = []
        let router = GuestInputRouter { events.append($0) }
        router.press(
            hostKeyCode: 8,
            chord: GuestChord(keyCode: 8, modifiers: [.control]),
            repeats: false
        )
        router.release(hostKeyCode: 8)

        XCTAssertEqual(
            events.map(\.type),
            [.flagsChanged, .keyDown, .keyUp, .flagsChanged]
        )
        XCTAssertEqual(events.map(\.keyCode), [59, 8, 8, 59])
        XCTAssertTrue(events[0].modifierFlags.contains(.control))
        XCTAssertFalse(events[3].modifierFlags.contains(.control))
        XCTAssertFalse(events.contains(where: { $0.keyCode == 55 }))
    }

    @MainActor
    func testPointerInteractionEmitsBalancedGuestSuper() {
        var events: [NSEvent] = []
        let router = GuestInputRouter { events.append($0) }

        router.beginPointerInteraction(modifiers: [.command])
        router.endPointerInteraction()

        XCTAssertEqual(events.map(\.type), [.flagsChanged, .flagsChanged])
        XCTAssertEqual(events.map(\.keyCode), [55, 55])
        XCTAssertTrue(events[0].modifierFlags.contains(.command))
        XCTAssertFalse(events[1].modifierFlags.contains(.command))
    }

    @MainActor
    func testSyntheticModifierEventsHaveCorrectDirection() {
        var events: [NSEvent] = []
        let router = GuestInputRouter { events.append($0) }
        router.beginPointerInteraction(modifiers: [.control])
        router.endPointerInteraction()

        XCTAssertTrue(QEMUKeyMapper.isModifierDown(events[0]))
        XCTAssertFalse(QEMUKeyMapper.isModifierDown(events[1]))
    }

    @MainActor
    func testHeldHostModifierKeepsGuestSwitcherOpen() {
        var events: [NSEvent] = []
        let router = GuestInputRouter { events.append($0) }
        router.updateHostModifiers([.command])
        router.press(
            hostKeyCode: 48,
            chord: GuestChord(keyCode: 48, modifiers: [.option]),
            repeats: false
        )
        router.release(hostKeyCode: 48)

        XCTAssertEqual(
            events.map(\.type),
            [.flagsChanged, .keyDown, .keyUp]
        )
        router.updateHostModifiers([])
        XCTAssertEqual(events.last?.type, .flagsChanged)
        XCTAssertEqual(events.last?.keyCode, 58)
        XCTAssertFalse(events.last?.modifierFlags.contains(.option) ?? true)
    }

    @MainActor
    func testMacOSPointerCommandMapsToGuestControl() {
        let settings = KeyboardMappingSettings.shared
        let previousPreset = settings.preset
        defer { settings.preset = previousPreset }
        settings.preset = .macOS

        let modifiers = settings.pointerModifiers(from: [.command])

        XCTAssertTrue(modifiers.contains(.control))
        XCTAssertFalse(modifiers.contains(.command))
    }

    @MainActor
    func testAppleInstallerConfigurationPersistsPlatformState() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let diskURL = directory.appending(path: "disk.raw")
        let installerURL = directory.appending(path: "installer.iso")
        let backendURL = directory.appending(
            path: "Apple",
            directoryHint: .isDirectory
        )
        try SparseDiskCreator.create(
            at: diskURL,
            capacityBytes: 8 * 1_024 * 1_024
        )
        try SparseDiskCreator.create(
            at: installerURL,
            capacityBytes: 1_024 * 1_024
        )

        let imageID = UUID()
        let machine = Machine(
            name: "Installer Test",
            spec: MachineSpec(
                cpuCount: VZVirtualMachineConfiguration.minimumAllowedCPUCount,
                memorySizeBytes:
                    VZVirtualMachineConfiguration.minimumAllowedMemorySize,
                diskSizeBytes: 8 * 1_024 * 1_024,
                architecture: .arm64
            ),
            sourceImageID: imageID,
            disk: MachineDisk(
                relativePath: "Machines/test/disk.raw",
                capacityBytes: 8 * 1_024 * 1_024
            ),
            provisioningState: .readyToInstall,
            bootMedia: .installer(imageID: imageID),
            backend: .appleVirtualization,
            backendState: BackendStateReference(
                relativeDirectory: "Machines/test/Apple"
            )
        )

        let first = try AppleVirtualMachineConfigurationFactory.make(
            machine: machine,
            diskURL: diskURL,
            installerURL: installerURL,
            backendStateURL: backendURL
        )
        let identifierURL = AppleBackendStateURLs(
            directoryURL: backendURL
        ).machineIdentifierURL
        let firstIdentifier = try Data(contentsOf: identifierURL)
        let second = try AppleVirtualMachineConfigurationFactory.make(
            machine: machine,
            diskURL: diskURL,
            installerURL: installerURL,
            backendStateURL: backendURL
        )

        XCTAssertNoThrow(try first.validate())
        XCTAssertNoThrow(try second.validate())
        let graphics = try XCTUnwrap(
            first.graphicsDevices.first
                as? VZVirtioGraphicsDeviceConfiguration
        )
        let scanout = try XCTUnwrap(graphics.scanouts.first)
        XCTAssertEqual(
            scanout.widthInPixels,
            AppleVirtualMachineConfigurationFactory.defaultDisplayWidth
        )
        XCTAssertEqual(
            scanout.heightInPixels,
            AppleVirtualMachineConfigurationFactory.defaultDisplayHeight
        )
        XCTAssertEqual(try Data(contentsOf: identifierURL), firstIdentifier)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: AppleBackendStateURLs(
                    directoryURL: backendURL
                ).variableStoreURL.path
            )
        )
    }

    @MainActor
    func testCreatesPersistentMachineFromManagedISO() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let sourceURL = rootURL.appending(path: "source.iso")
        try Data("EFI/BOOT/BOOTAA64.EFI".utf8).write(to: sourceURL)

        let model = AppModel(
            storageRootURL: rootURL.appending(
                path: "Library",
                directoryHint: .isDirectory
            )
        )
        await model.initialize()
        let imageID = try await model.importISO(
            from: sourceURL,
            architecture: .arm64
        )
        let machineID = try await model.createMachine(
            name: "Generic Linux",
            cpuCount: VZVirtualMachineConfiguration.minimumAllowedCPUCount,
            memorySizeBytes:
                VZVirtualMachineConfiguration.minimumAllowedMemorySize,
            diskSizeBytes: 1_024 * 1_024,
            source: .managedImage(imageID),
            sharedDirectoryPath: nil
        )

        let machine = try XCTUnwrap(
            model.machines.first(where: { $0.id == machineID })
        )
        XCTAssertEqual(machine.provisioningState, .readyToInstall)
        XCTAssertEqual(machine.bootMedia, .installer(imageID: imageID))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: try XCTUnwrap(model.storageURL)
                    .appending(path: machine.disk.relativePath).path
            )
        )
    }

    @MainActor
    func testReconcilesInterruptedImageAndMachineProvisioning() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let image = MachineImage(
            name: "Interrupted",
            architecture: .arm64,
            artifactKind: .installerISO,
            origin: .remoteURL(URL(string: "https://example.test/image.iso")!),
            availability: .downloading(progress: 0.5)
        )
        let machine = Machine(
            name: "Interrupted",
            spec: MachineSpec(
                cpuCount: 2,
                memorySizeBytes: 2 * 1_024 * 1_024 * 1_024,
                diskSizeBytes: 16 * 1_024 * 1_024 * 1_024,
                architecture: .arm64
            ),
            sourceImageID: image.id,
            disk: MachineDisk(
                relativePath: "Machines/test/disk.raw",
                capacityBytes: 16 * 1_024 * 1_024 * 1_024
            ),
            provisioningState: .verifying,
            bootMedia: .installer(imageID: image.id),
            backend: .appleVirtualization,
            backendState: BackendStateReference(
                relativeDirectory: "Machines/test/Apple"
            )
        )
        let store = LibraryStore(layout: StorageLayout(rootURL: rootURL))
        try await store.save(
            LibrarySnapshot(machines: [machine], images: [image])
        )

        let model = AppModel(storageRootURL: rootURL)
        await model.initialize()

        guard case .failed = try XCTUnwrap(model.images.first).availability else {
            XCTFail("Interrupted image was not marked failed.")
            return
        }
        guard case .failed = try XCTUnwrap(model.machines.first)
            .provisioningState else {
            XCTFail("Interrupted machine was not reconciled.")
            return
        }
    }

    @MainActor
    func testCreatesMachineFromPreinstalledDiskWithoutInstaller() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let sourceURL = rootURL.appending(path: "base.raw")
        try SparseDiskCreator.create(
            at: sourceURL,
            capacityBytes: 1 * 1_024 * 1_024
        )
        let model = AppModel(
            storageRootURL: rootURL.appending(path: "Library")
        )
        await model.initialize()
        let imageID = try await model.importImage(
            from: sourceURL,
            architecture: .arm64,
            artifactKind: .preinstalledDisk
        )
        let machineID = try await model.createMachine(
            name: "Curated",
            cpuCount: 2,
            memorySizeBytes: 2 * 1_024 * 1_024 * 1_024,
            diskSizeBytes: 2 * 1_024 * 1_024,
            source: .managedImage(imageID),
            sharedDirectoryPath: nil
        )
        let machine = try XCTUnwrap(
            model.machines.first(where: { $0.id == machineID })
        )

        XCTAssertEqual(machine.bootMedia, .systemDisk)
        XCTAssertEqual(machine.provisioningState, .ready)
        XCTAssertEqual(machine.disk.capacityBytes, 2 * 1_024 * 1_024)
    }

    @MainActor
    func testRealARM64EFIISOStaysRunningWithDisplayAttached() async throws {
        guard let fixturePath = fixturePath(
            environmentKey: "SIMPLEVM_ARM64_ISO_FIXTURE",
            fileName: "arm64-iso-path"
        ) else {
            throw XCTSkip("Set SIMPLEVM_ARM64_ISO_FIXTURE for the hardware smoke test.")
        }

        let fixtureURL = URL(filePath: fixturePath)
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            XCTFail("The ARM64 ISO fixture does not exist.")
            return
        }

        let directory = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let diskURL = directory.appending(path: "disk.raw")
        let backendURL = directory.appending(path: "Apple")
        try SparseDiskCreator.create(
            at: diskURL,
            capacityBytes: 1 * 1_024 * 1_024 * 1_024
        )

        let imageID = UUID()
        let machine = Machine(
            name: "EFI Smoke Test",
            spec: MachineSpec(
                cpuCount: max(
                    2,
                    VZVirtualMachineConfiguration.minimumAllowedCPUCount
                ),
                memorySizeBytes: max(
                    2 * 1_024 * 1_024 * 1_024,
                    VZVirtualMachineConfiguration.minimumAllowedMemorySize
                ),
                diskSizeBytes: 1 * 1_024 * 1_024 * 1_024,
                architecture: .arm64
            ),
            sourceImageID: imageID,
            disk: MachineDisk(
                relativePath: "disk.raw",
                capacityBytes: 1 * 1_024 * 1_024 * 1_024
            ),
            provisioningState: .readyToInstall,
            bootMedia: .installer(imageID: imageID),
            backend: .appleVirtualization,
            backendState: BackendStateReference(relativeDirectory: "Apple")
        )
        let configuration = try AppleVirtualMachineConfigurationFactory.make(
            machine: machine,
            diskURL: diskURL,
            installerURL: fixtureURL,
            backendStateURL: backendURL
        )
        let virtualMachine = VZVirtualMachine(configuration: configuration)
        let display = VZVirtualMachineView(
            frame: NSRect(x: 0, y: 0, width: 1_024, height: 640)
        )
        display.virtualMachine = virtualMachine
        let window = NSWindow(
            contentRect: display.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentView = display
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }

        try await virtualMachine.start()
        defer {
            Task { @MainActor in
                if virtualMachine.state == .running {
                    try? await virtualMachine.stop()
                }
            }
        }
        try await Task.sleep(for: .seconds(45))

        XCTAssertEqual(virtualMachine.state, .running)
        XCTAssertTrue(display.virtualMachine === virtualMachine)

        try await virtualMachine.stop()
    }

    @MainActor
    func testRealRootFSBootsThroughDirectKernel() async throws {
        guard let diskPath = fixturePath(
            environmentKey: "SIMPLEVM_ROOTFS_DISK_FIXTURE",
            fileName: "rootfs-disk-path"
        ), let kernelPath = fixturePath(
            environmentKey: "SIMPLEVM_ROOTFS_KERNEL_FIXTURE",
            fileName: "rootfs-kernel-path"
        ), let initrdPath = fixturePath(
            environmentKey: "SIMPLEVM_ROOTFS_INITRD_FIXTURE",
            fileName: "rootfs-initrd-path"
        ) else {
            throw XCTSkip("Configure rootfs, kernel, and initrd fixtures.")
        }

        let directory = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let diskURL = directory.appending(path: "rootfs.ext4")
        try APFSCloneStorage.clone(
            from: URL(filePath: diskPath),
            to: diskURL
        )
        let backendURL = directory.appending(path: "Apple")
        try AppleLinuxBootAssets.install(
            kernelURL: URL(filePath: kernelPath),
            initialRamdiskURL: URL(filePath: initrdPath),
            commandLine: "console=hvc0 root=/dev/vda rw init=/bin/sh",
            backendStateURL: backendURL
        )
        let logURL = directory.appending(path: "console.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        defer { try? logHandle.close() }

        let machine = Machine(
            name: "RootFS Test",
            spec: MachineSpec(
                cpuCount: 2,
                memorySizeBytes: 2 * 1_024 * 1_024 * 1_024,
                diskSizeBytes: 384 * 1_024 * 1_024,
                architecture: .arm64
            ),
            sourceImageID: UUID(),
            disk: MachineDisk(
                relativePath: "rootfs.ext4",
                capacityBytes: 384 * 1_024 * 1_024
            ),
            provisioningState: .ready,
            bootMedia: .systemDisk,
            backend: .appleVirtualization,
            backendState: BackendStateReference(relativeDirectory: "Apple")
        )
        let configuration = try AppleVirtualMachineConfigurationFactory.make(
            machine: machine,
            diskURL: diskURL,
            installerURL: nil,
            backendStateURL: backendURL,
            serialOutput: logHandle
        )
        let virtualMachine = VZVirtualMachine(configuration: configuration)
        try await virtualMachine.start()
        try await Task.sleep(for: .seconds(20))
        XCTAssertEqual(virtualMachine.state, .running)
        try await virtualMachine.stop()
        try logHandle.synchronize()

        let console = String(
            data: try Data(contentsOf: logURL),
            encoding: .utf8
        ) ?? ""
        XCTAssertTrue(
            console.contains("Linux version") || console.contains("Alpine"),
            "Expected Linux boot output, received: \(console.suffix(500))"
        )
    }

    private func fixturePath(
        environmentKey: String,
        fileName: String
    ) -> String? {
        if let path = ProcessInfo.processInfo.environment[environmentKey] {
            return path
        }
        let repositoryURL = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let pathURL = repositoryURL
            .appending(path: ".build/TestFixtures")
            .appending(path: fileName)
        return try? String(contentsOf: pathURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
