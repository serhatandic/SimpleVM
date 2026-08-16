import Foundation
import Testing
@testable import SimpleVMCore

@Test
func roundTripsVersionedGuestAgentFrames() throws {
    let request = GuestAgentRequest.hello(protocolVersion: 1)
    let frame = try GuestAgentFrameCodec.encode(request)

    #expect(
        try GuestAgentFrameCodec.decode(
            GuestAgentRequest.self,
            from: frame
        ) == request
    )
    #expect(throws: GuestAgentProtocolError.incompleteFrame) {
        try GuestAgentFrameCodec.decode(
            GuestAgentRequest.self,
            from: frame.dropLast()
        )
    }
}

@Test
func createsCopyOnWriteDiskCloneOnAPFS() throws {
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
    let sourceURL = directory.appending(path: "source.raw")
    let cloneURL = directory.appending(path: "clone.raw")
    try Data("machine disk".utf8).write(to: sourceURL)

    try APFSCloneStorage.clone(from: sourceURL, to: cloneURL)

    #expect(try Data(contentsOf: cloneURL) == Data("machine disk".utf8))
    try Data("changed".utf8).write(to: cloneURL)
    #expect(try Data(contentsOf: sourceURL) == Data("machine disk".utf8))
}

@Test
func validatesPortForwardRules() throws {
    #expect(throws: Never.self) {
        try PortForwardValidator.validate(
            PortForward(hostPort: 8_080, guestPort: 80)
        )
    }
    #expect(throws: PortForwardError.invalidPort) {
        try PortForwardValidator.validate(
            PortForward(hostPort: 0, guestPort: 80)
        )
    }
}

