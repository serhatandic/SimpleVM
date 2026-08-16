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

