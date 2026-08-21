import Foundation
import Testing
@testable import SimpleVMCore

@Test
func roundTripsVersionedGuestAgentFrames() throws {
    let request = GuestAgentRequestEnvelope(
        requestID: "request-1",
        request: .resizeDisplay(width: 1_920, height: 1_080)
    )
    let frame = try GuestAgentFrameCodec.encode(request)

    #expect(
        try GuestAgentFrameCodec.decode(
            GuestAgentRequestEnvelope.self,
            from: frame
        ) == request
    )
    #expect(throws: GuestAgentProtocolError.incompleteFrame) {
        _ = try GuestAgentFrameCodec.decode(
            GuestAgentRequestEnvelope.self,
            from: frame.dropLast()
        )
    }
}

@Test
func decodesLegacyGuestAgentFramesAndStatus() throws {
    let request = try GuestAgentFrameCodec.decode(
        GuestAgentRequestEnvelope.self,
        from: framedJSON(#"{"status":{}}"#)
    )
    #expect(request.protocolVersion == 1)
    #expect(request.requestID == nil)
    #expect(request.request == .status)

    let response = try GuestAgentFrameCodec.decode(
        GuestAgentResponseEnvelope.self,
        from: framedJSON(
            """
            {"status":{"protocolVersion":1,"hostname":"guest","ipAddresses":["192.0.2.2"],"operatingSystem":"Linux","sharedDirectories":["/mnt/share"]}}
            """
        )
    )
    guard case .status(let status) = response.response else {
        Issue.record("Expected a legacy status response.")
        return
    }
    #expect(status.agentVersion == "unknown")
    #expect(status.desktopEnvironment == .other)
    #expect(status.sharedMountStatus.state == .mounted)
}

@Test
func decodesGuestToolsStatusWireShape() throws {
    let frame = try framedJSON(
        """
        {"protocolVersion":2,"requestID":"status-1","response":{"type":"status","protocolVersion":2,"agentVersion":"2.0.0","hostname":"omarchy","ipAddresses":[],"operatingSystem":"Linux","distroID":"arch","distroVersion":"rolling","desktopEnvironment":"hyprland","sessionType":"wayland","capabilities":["clipboardRead","clipboardWrite","displayResize"],"sharedMountStatus":{"mounted":false,"state":"notMounted","mountPoint":"/mnt/simplevm-share","tag":"share","filesystem":"virtiofs"}}}
        """
    )
    let response = try GuestAgentFrameCodec.decode(
        GuestAgentResponseEnvelope.self,
        from: frame
    )
    guard case .status(let status) = response.response else {
        Issue.record("Expected a status response.")
        return
    }
    #expect(response.requestID == "status-1")
    #expect(status.desktopEnvironment == .hyprland)
    #expect(status.sessionType == .wayland)
    #expect(status.capabilities.contains(.displayResize))
    #expect(status.sharedMountStatus.state == .unmounted)
}

@Test
func rejectsUnsafeGuestAgentPayloads() throws {
    #expect(throws: GuestAgentProtocolError.clipboardTooLarge) {
        try GuestAgentFrameCodec.encode(
            GuestAgentRequestEnvelope(
                request: .writeClipboard(
                    text: String(
                        repeating: "x",
                        count: GuestAgentProtocol.maximumClipboardSize + 1
                    )
                )
            )
        )
    }
    #expect(throws: GuestAgentProtocolError.invalidDisplaySize) {
        try GuestAgentFrameCodec.encode(
            GuestAgentRequestEnvelope(
                request: .resizeDisplay(width: 100, height: 100)
            )
        )
    }
    do {
        _ = try GuestAgentFrameCodec.decode(
            GuestAgentRequestEnvelope.self,
            from: try framedJSON(
                #"{"protocolVersion":2,"requestID":"x","request":{"type":"runCommand","command":"id"}}"#
            )
        )
        Issue.record("Expected an unknown operation to be rejected.")
    } catch GuestAgentProtocolError.invalidMessage {
        // Expected.
    }
}

private func framedJSON(_ json: String) throws -> Data {
    let payload = Data(json.utf8)
    var length = UInt32(payload.count).bigEndian
    var frame = withUnsafeBytes(of: &length) { Data($0) }
    frame.append(payload)
    return frame
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
