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
