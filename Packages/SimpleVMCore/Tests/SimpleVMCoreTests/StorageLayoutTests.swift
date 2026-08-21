import Foundation
import Testing
@testable import SimpleVMCore

@Test
func initializesExpectedStorageDirectories() throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString,
        directoryHint: .isDirectory
    )
    defer {
        try? FileManager.default.removeItem(at: rootURL)
    }

    let layout = StorageLayout(rootURL: rootURL)
    try layout.initialize()

    for directory in [
        layout.rootURL,
        layout.imagesURL,
        layout.machinesURL,
        layout.downloadsURL,
        layout.logsURL
    ] {
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        ))
        #expect(isDirectory.boolValue)
    }
}

@Test
func roundTripsLibrarySnapshot() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString,
        directoryHint: .isDirectory
    )
    defer {
        try? FileManager.default.removeItem(at: rootURL)
    }

    let store = LibraryStore(layout: StorageLayout(rootURL: rootURL))
    let image = MachineImage(
        name: "Test Installer",
        architecture: .arm64,
        artifactKind: .installerISO,
        origin: .localImport(originalFileName: "test.iso")
    )
    let snapshot = LibrarySnapshot(images: [image])

    try await store.save(snapshot)
    let loaded = try await store.load()

    #expect(loaded == snapshot)
}

@Test
func decodesExistingLibraryJSONWithAutomaticInputProfile() throws {
    let machineID = UUID()
    let imageID = UUID()
    let machine = Machine(
        id: machineID,
        name: "Existing Linux",
        spec: MachineSpec(
            cpuCount: 2,
            memorySizeBytes: 4 * 1_024 * 1_024 * 1_024,
            diskSizeBytes: 64 * 1_024 * 1_024 * 1_024,
            architecture: .arm64
        ),
        sourceImageID: imageID,
        disk: MachineDisk(
            relativePath: "Machines/\(machineID)/disk.raw",
            capacityBytes: 64 * 1_024 * 1_024 * 1_024
        ),
        provisioningState: .ready,
        bootMedia: .systemDisk,
        backend: .appleVirtualization,
        backendState: BackendStateReference(
            relativeDirectory: "Machines/\(machineID)/Apple"
        )
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let currentData = try encoder.encode(
        LibrarySnapshot(machines: [machine])
    )
    var json = try #require(
        JSONSerialization.jsonObject(with: currentData)
            as? [String: Any]
    )
    var machines = try #require(json["machines"] as? [[String: Any]])
    var spec = try #require(machines[0]["spec"] as? [String: Any])
    spec.removeValue(forKey: "inputProfile")
    spec.removeValue(forKey: "customInputProfileID")
    spec.removeValue(forKey: "operatingSystem")
    spec.removeValue(forKey: "qemuHardwareProfile")
    spec.removeValue(forKey: "displayMode")
    spec.removeValue(forKey: "windowsSupportToolsAttached")
    machines[0]["spec"] = spec
    json["machines"] = machines
    let existingData = try JSONSerialization.data(withJSONObject: json)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(
        LibrarySnapshot.self,
        from: existingData
    )

    #expect(decoded.machines[0].spec.inputProfile == .automatic)
    #expect(decoded.machines[0].spec.customInputProfileID == nil)
    #expect(decoded.machines[0].spec.operatingSystem == .linux)
    #expect(decoded.machines[0].spec.qemuHardwareProfile == nil)
    #expect(decoded.machines[0].spec.displayMode == .automatic)
    #expect(!decoded.machines[0].spec.windowsSupportToolsAttached)
    #expect(
        decoded.machines[0].spec.inputProfile.resolved(
            forMachineNamed: decoded.machines[0].name
        ) == .macOSGNOME
    )
}

@Test
func resolvesSupportedGuestPlatforms() throws {
    #expect(
        try VirtualizationBackendKind.resolve(
            operatingSystem: .linux,
            architecture: .arm64
        ) == .appleVirtualization
    )
    #expect(
        try VirtualizationBackendKind.resolve(
            operatingSystem: .linux,
            architecture: .x86_64
        ) == .qemu
    )
    #expect(
        try VirtualizationBackendKind.resolve(
            operatingSystem: .windows,
            architecture: .arm64
        ) == .qemu
    )
    #expect(throws: GuestPlatformError.self) {
        try VirtualizationBackendKind.resolve(
            operatingSystem: .windows,
            architecture: .x86_64
        )
    }
}

@Test
func createsStableDistinctQEMUHardwareProfiles() {
    let hardwareUUID = UUID(
        uuidString: "12345678-1234-5678-9ABC-DEF012345678"
    )!
    let first = QEMUHardwareProfile.windowsARM64(
        hardwareUUID: hardwareUUID
    )
    let same = QEMUHardwareProfile.windowsARM64(
        hardwareUUID: hardwareUUID
    )
    let other = QEMUHardwareProfile.windowsARM64()

    #expect(first == same)
    #expect(first.machineType == "virt-10.0")
    #expect(first.macAddress == "12:34:56:78:12:34")
    #expect(other.hardwareUUID != first.hardwareUUID)
    #expect(other.macAddress != first.macAddress)
}

@Test
func automaticProfileDetectsOmarchyAndHyprlandNames() {
    #expect(
        MachineInputProfile.automatic.resolved(
            forMachineNamed: "Omarchy 4.0"
        ) == .macOSHyprland
    )
    #expect(
        MachineInputProfile.automatic.resolved(
            forMachineNamed: "Arch Hyprland"
        ) == .macOSHyprland
    )
}

@Test
func explicitHyprlandProfileOverridesGenericMachineName() {
    #expect(
        MachineInputProfile.macOSHyprland.resolved(
            forMachineNamed: "Generic Arch Linux"
        ) == .macOSHyprland
    )
}

@Test
func rejectsUnknownSchema() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString,
        directoryHint: .isDirectory
    )
    defer {
        try? FileManager.default.removeItem(at: rootURL)
    }

    let layout = StorageLayout(rootURL: rootURL)
    let store = LibraryStore(layout: layout)

    await #expect(throws: LibraryStoreError.unsupportedSchema(found: 2, supported: 1)) {
        try await store.save(LibrarySnapshot(schemaVersion: 2))
    }
}

@Test
func resolvesOnlyManagedRelativePaths() throws {
    let rootURL = URL(filePath: "/tmp/SimpleVM")
    let layout = StorageLayout(rootURL: rootURL)
    let managedURL = rootURL.appending(path: "Images/test/artifact.iso")

    let relativePath = try layout.relativePath(for: managedURL)
    #expect(relativePath == "Images/test/artifact.iso")
    #expect(try layout.resolve(relativePath: relativePath) == managedURL)
    #expect(throws: StorageLayoutError.outsideManagedStorage) {
        try layout.relativePath(for: URL(filePath: "/tmp/outside.iso"))
    }
    #expect(throws: StorageLayoutError.invalidRelativePath) {
        try layout.resolve(relativePath: "../outside.iso")
    }
}

@Test
func removesOnlyUnreferencedManagedDirectories() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString,
        directoryHint: .isDirectory
    )
    defer {
        try? FileManager.default.removeItem(at: rootURL)
    }

    let layout = StorageLayout(rootURL: rootURL)
    try layout.initialize()

    let referencedImageID = UUID()
    let orphanedImageID = UUID()
    let referencedMachineID = UUID()
    let orphanedMachineID = UUID()
    for directory in [
        layout.imagesURL.appending(path: referencedImageID.uuidString),
        layout.imagesURL.appending(path: orphanedImageID.uuidString),
        layout.machinesURL.appending(path: referencedMachineID.uuidString),
        layout.machinesURL.appending(path: orphanedMachineID.uuidString)
    ] {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    try await ManagedImageStore(layout: layout).removeOrphanedImages(
        referencedIDs: [referencedImageID]
    )
    try await ManagedMachineStore(layout: layout).removeOrphanedMachines(
        referencedIDs: [referencedMachineID]
    )

    #expect(FileManager.default.fileExists(
        atPath: layout.imagesURL.appending(path: referencedImageID.uuidString).path
    ))
    #expect(!FileManager.default.fileExists(
        atPath: layout.imagesURL.appending(path: orphanedImageID.uuidString).path
    ))
    #expect(FileManager.default.fileExists(
        atPath: layout.machinesURL.appending(path: referencedMachineID.uuidString).path
    ))
    #expect(!FileManager.default.fileExists(
        atPath: layout.machinesURL.appending(path: orphanedMachineID.uuidString).path
    ))
}

@Test
func exportsManagedFilesAtomicallyWithoutMutatingSource() throws {
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
    let managedURL = directory.appending(
        path: "Managed",
        directoryHint: .isDirectory
    )
    let exportsURL = directory.appending(
        path: "Exports",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: managedURL,
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: exportsURL,
        withIntermediateDirectories: true
    )
    let sourceURL = managedURL.appending(path: "source.raw")
    let destinationURL = exportsURL.appending(path: "export.raw")
    let sourceData = Data("managed-image".utf8)
    try sourceData.write(to: sourceURL)
    try Data("old-export".utf8).write(to: destinationURL)

    try ManagedFileExporter.export(
        from: sourceURL,
        to: destinationURL,
        protectedRootURL: managedURL
    )

    #expect(try Data(contentsOf: sourceURL) == sourceData)
    #expect(try Data(contentsOf: destinationURL) == sourceData)
    #expect(throws: ManagedFileExportError.destinationMatchesSource) {
        try ManagedFileExporter.export(
            from: sourceURL,
            to: sourceURL
        )
    }
    #expect(throws: ManagedFileExportError.destinationInsideManagedStorage) {
        try ManagedFileExporter.export(
            from: sourceURL,
            to: managedURL.appending(path: "another.raw"),
            protectedRootURL: managedURL
        )
    }

    let managedAliasURL = directory.appending(path: "ManagedAlias")
    try FileManager.default.createSymbolicLink(
        at: managedAliasURL,
        withDestinationURL: managedURL
    )
    #expect(throws: ManagedFileExportError.destinationInsideManagedStorage) {
        try ManagedFileExporter.export(
            from: sourceURL,
            to: managedAliasURL.appending(path: "through-alias.raw"),
            protectedRootURL: managedURL
        )
    }
}
