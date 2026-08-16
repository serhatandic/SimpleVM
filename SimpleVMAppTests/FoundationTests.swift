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
}
