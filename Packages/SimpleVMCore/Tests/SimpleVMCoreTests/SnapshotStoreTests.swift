import Foundation
import Testing
@testable import SimpleVMCore

@Test
func createsRestoresAndDeletesDiskSnapshots() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString,
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let layout = StorageLayout(rootURL: rootURL)
    try layout.initialize()
    let machineID = UUID()
    let machineDirectory = layout.machineURL(id: machineID)
    try FileManager.default.createDirectory(
        at: machineDirectory,
        withIntermediateDirectories: true
    )
    let diskURL = machineDirectory.appending(path: "disk.raw")
    try Data("before".utf8).write(to: diskURL)
    let machine = Machine(
        id: machineID,
        name: "Snapshot",
        spec: MachineSpec(
            cpuCount: 2,
            memorySizeBytes: 2 * 1_024 * 1_024 * 1_024,
            diskSizeBytes: 6,
            architecture: .arm64
        ),
        sourceImageID: UUID(),
        disk: MachineDisk(
            relativePath: try layout.relativePath(for: diskURL),
            capacityBytes: 6
        ),
        provisioningState: .ready,
        bootMedia: .systemDisk,
        backend: .appleVirtualization,
        backendState: BackendStateReference(relativeDirectory: "Apple")
    )
    let store = SnapshotStore(layout: layout)
    let snapshot = try await store.create(machine: machine, name: "Before")
    try Data("after!".utf8).write(to: diskURL)

    try await store.restore(snapshot, machine: machine)
    #expect(try Data(contentsOf: diskURL) == Data("before".utf8))
    let loaded = try await store.list(machineID: machineID)
    #expect(loaded.map(\.id) == [snapshot.id])
    #expect(loaded.map(\.name) == [snapshot.name])

    try await store.delete(snapshot, machineID: machineID)
    #expect(try await store.list(machineID: machineID).isEmpty)
}

@Test
func atomicallyRestoresWindowsDiskEFIAndTPMState() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString,
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let layout = StorageLayout(rootURL: rootURL)
    try layout.initialize()
    let machineID = UUID()
    let stateURL = layout.machineURL(id: machineID).appending(
        path: "State/current",
        directoryHint: .isDirectory
    )
    let qemuURL = stateURL.appending(
        path: "QEMU",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: qemuURL,
        withIntermediateDirectories: true
    )
    let diskURL = stateURL.appending(path: "disk.raw")
    let efiURL = qemuURL.appending(path: "efi-vars.fd")
    let tpmURL = qemuURL.appending(path: "tpm-state")
    try Data("disk-before".utf8).write(to: diskURL)
    try Data("efi-before".utf8).write(to: efiURL)
    try Data("tpm-before".utf8).write(to: tpmURL)
    let machine = Machine(
        id: machineID,
        name: "Windows Snapshot",
        spec: MachineSpec(
            cpuCount: 4,
            memorySizeBytes: 8 * 1_024 * 1_024 * 1_024,
            diskSizeBytes: 11,
            architecture: .arm64,
            operatingSystem: .windows,
            qemuHardwareProfile: .windowsARM64()
        ),
        sourceImageID: UUID(),
        disk: MachineDisk(
            relativePath: try layout.relativePath(for: diskURL),
            capacityBytes: 11
        ),
        provisioningState: .ready,
        bootMedia: .systemDisk,
        backend: .qemu,
        backendState: BackendStateReference(
            relativeDirectory: try layout.relativePath(for: qemuURL)
        )
    )
    let store = SnapshotStore(layout: layout)
    let snapshot = try await store.create(machine: machine, name: "Before")
    #expect(snapshot.stateDirectoryRelativePath != nil)

    try Data("disk-after!".utf8).write(to: diskURL)
    try Data("efi-after".utf8).write(to: efiURL)
    try Data("tpm-after".utf8).write(to: tpmURL)
    try Data("runtime log".utf8).write(
        to: qemuURL.appending(path: "qemu.log")
    )

    try await store.restore(snapshot, machine: machine)

    #expect(try Data(contentsOf: diskURL) == Data("disk-before".utf8))
    #expect(try Data(contentsOf: efiURL) == Data("efi-before".utf8))
    #expect(try Data(contentsOf: tpmURL) == Data("tpm-before".utf8))
    #expect(!FileManager.default.fileExists(
        atPath: qemuURL.appending(path: "qemu.log").path
    ))

    try await store.delete(snapshot, machineID: machineID)
    #expect(try await store.list(machineID: machineID).isEmpty)
}
