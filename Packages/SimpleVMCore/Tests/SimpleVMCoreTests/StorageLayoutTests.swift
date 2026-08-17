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
