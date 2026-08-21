@preconcurrency import CocoaSpiceNoUsb
import AppKit
import Foundation
import SimpleVMCore

@MainActor
final class SPICEConnectionController: NSObject {
    private(set) var display: CSDisplay?
    private(set) var input: CSInput?
    private(set) var supportsDisplayResize = false
    private(set) var supportsClipboard = false

    var displayHandler: ((CSDisplay) -> Void)?
    var displayResizeSupportHandler: ((Bool) -> Void)?
    var clipboardNoticeHandler: ((String) -> Void)?
    var agentStateHandler: ((Bool, Bool, Bool) -> Void)?
    var errorHandler: ((any Error) -> Void)?
    var sharedDirectoryPath: String?

    private var connection: CSConnection?
    private var connectionContinuation:
        CheckedContinuation<Void, any Error>?
    private let pasteboardBridge = SPICEPasteboardBridge()
    private var clipboardPollingTask: Task<Void, Never>?
    private var clipboardSharingAllowed = true

    func connect(to socketURL: URL) async throws {
        guard Self.startClient() else {
            throw SPICEConnectionError.startFailed
        }
        var lastError: (any Error)?
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: socketURL.path) {
                prepareConnection(to: socketURL)
                guard let connection else {
                    throw SPICEConnectionError.connectionFailed
                }
                do {
                    try await withCheckedThrowingContinuation {
                        continuation in
                        self.connectionContinuation = continuation
                        if !connection.connect() {
                            self.connectionContinuation = nil
                            continuation.resume(
                                throwing:
                                    SPICEConnectionError.connectionFailed
                            )
                        }
                    }
                    return
                } catch {
                    lastError = error
                    connection.disconnect()
                    self.connection = nil
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw lastError ?? SPICEConnectionError.unavailable
    }

    @discardableResult
    func prepareConnection(to socketURL: URL) -> AnyObject {
        let connection = CSConnection(unixSocketFile: socketURL)
        connection.audioEnabled = true
        pasteboardBridge.noticeHandler = { [weak self] message in
            self?.clipboardNoticeHandler?(message)
        }
        connection.session.pasteboardDelegate = pasteboardBridge
        connection.session.shareClipboard = false
        if let sharedDirectoryPath {
            connection.session.setSharedDirectory(
                sharedDirectoryPath,
                readOnly: false
            )
        }
        connection.delegate = self
        self.connection = connection
        return connection
    }

    var preparedConnectionAudioEnabled: Bool {
        connection?.audioEnabled == true
    }

    var preparedConnectionHasPasteboardDelegate: Bool {
        connection?.session.pasteboardDelegate != nil
    }

    static func startClient() -> Bool {
        CSMain.shared.spiceStart() || CSMain.shared.running
    }

    static func stopClient() {
        CSMain.shared.spiceStop()
    }

    func disconnect() {
        clipboardPollingTask?.cancel()
        clipboardPollingTask = nil
        connection?.session.shareClipboard = false
        connection?.session.pasteboardDelegate = nil
        connection?.disconnect()
        connection = nil
        display = nil
        input = nil
        supportsDisplayResize = false
        supportsClipboard = false
        agentStateHandler?(false, false, false)
    }

    func setClipboardSharingAllowed(_ allowed: Bool) {
        clipboardSharingAllowed = allowed
        updateClipboardSharing()
    }

    func setSharedDirectory(_ path: String?) {
        sharedDirectoryPath = path
        if let path {
            connection?.session.setSharedDirectory(path, readOnly: false)
        } else {
            let disabledURL = FileManager.default.temporaryDirectory.appending(
                path: "SimpleVM-Disabled-Share",
                directoryHint: .isDirectory
            )
            try? FileManager.default.createDirectory(
                at: disabledURL,
                withIntermediateDirectories: true
            )
            connection?.session.setSharedDirectory(
                disabledURL.path,
                readOnly: true
            )
        }
    }

    func sendKey(_ event: GuestKeyEvent) {
        guard let scancode = PCXTKeyMapper.scancode(
            for: event.keyCode
        ) else {
            return
        }
        input?.send(
            event.isDown ? .press : .release,
            code: Int32(scancode)
        )
    }

    func sendPointer(mask: UInt8, x: UInt16, y: UInt16) {
        input?.sendMousePosition(
            CSInputButton(rawValue: UInt(mask)),
            absolutePoint: CGPoint(x: Int(x), y: Int(y))
        )
    }

    func sendScroll(deltaY: CGFloat, mask: UInt8) {
        input?.sendMouseScroll(
            .smooth,
            buttonMask: CSInputButton(rawValue: UInt(mask)),
            dy: deltaY
        )
    }

    func releaseKeys() {
        input?.releaseKeys()
    }

    private func updateClipboardSharing() {
        let enabled = supportsClipboard && clipboardSharingAllowed
        connection?.session.shareClipboard = enabled
        clipboardPollingTask?.cancel()
        clipboardPollingTask = nil
        guard enabled else { return }
        pasteboardBridge.pollForHostChange()
        clipboardPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.pasteboardBridge.pollForHostChange()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
}

extension SPICEConnectionController: CSConnectionDelegate {
    nonisolated func spiceConnected(_ connection: CSConnection) {
        let connectionID = ObjectIdentifier(connection)
        Task { @MainActor [weak self] in
            guard self?.connection.map(ObjectIdentifier.init)
                    == connectionID else {
                return
            }
            self?.connectionContinuation?.resume()
            self?.connectionContinuation = nil
        }
    }

    nonisolated func spiceDisconnected(_ connection: CSConnection) {
        let connectionID = ObjectIdentifier(connection)
        Task { @MainActor [weak self] in
            if self?.connection.map(ObjectIdentifier.init) == connectionID,
               let continuation = self?.connectionContinuation {
                continuation.resume(
                    throwing: SPICEConnectionError.connectionFailed
                )
                self?.connectionContinuation = nil
            }
            self?.display = nil
            self?.input = nil
        }
    }

    nonisolated func spiceInputAvailable(
        _ connection: CSConnection,
        input: CSInput
    ) {
        let retainedInput = Unmanaged.passRetained(input)
        Task { @MainActor [weak self] in
            let input = retainedInput.takeRetainedValue()
            self?.input = input
            input.requestMouseMode(false)
        }
    }

    nonisolated func spiceInputUnavailable(
        _ connection: CSConnection,
        input: CSInput
    ) {
        let inputID = ObjectIdentifier(input)
        Task { @MainActor [weak self] in
            if self?.input.map(ObjectIdentifier.init) == inputID {
                self?.input = nil
            }
        }
    }

    nonisolated func spiceError(
        _ connection: CSConnection,
        code: CSConnectionError,
        message: String?
    ) {
        let connectionID = ObjectIdentifier(connection)
        let errorMessage = message ?? "Unknown SPICE error."
        Task { @MainActor [weak self] in
            let error = SPICEConnectionError.remote(
                errorMessage
            )
            if self?.connection.map(ObjectIdentifier.init) == connectionID,
               let continuation = self?.connectionContinuation {
                continuation.resume(throwing: error)
                self?.connectionContinuation = nil
            } else {
                self?.errorHandler?(error)
            }
        }
    }

    nonisolated func spiceDisplayCreated(
        _ connection: CSConnection,
        display: CSDisplay
    ) {
        let retainedDisplay = Unmanaged.passRetained(display)
        Task { @MainActor [weak self] in
            let display = retainedDisplay.takeRetainedValue()
            guard display.isPrimaryDisplay else { return }
            self?.display = display
            self?.displayHandler?(display)
        }
    }

    nonisolated func spiceDisplayUpdated(
        _ connection: CSConnection,
        display: CSDisplay
    ) {
        let retainedDisplay = Unmanaged.passRetained(display)
        Task { @MainActor [weak self] in
            let display = retainedDisplay.takeRetainedValue()
            guard display.isPrimaryDisplay else { return }
            self?.display = display
            self?.displayHandler?(display)
        }
    }

    nonisolated func spiceDisplayDestroyed(
        _ connection: CSConnection,
        display: CSDisplay
    ) {
        let displayID = ObjectIdentifier(display)
        Task { @MainActor [weak self] in
            if self?.display.map(ObjectIdentifier.init) == displayID {
                self?.display = nil
            }
        }
    }

    nonisolated func spiceAgentConnected(
        _ connection: CSConnection,
        supportingFeatures features: CSConnectionAgentFeature
    ) {
        let supportsDisplayResize = features.rawValue != 0
        Task { @MainActor [weak self] in
            self?.supportsDisplayResize = supportsDisplayResize
            self?.supportsClipboard = true
            self?.agentStateHandler?(true, true, supportsDisplayResize)
            self?.displayResizeSupportHandler?(supportsDisplayResize)
            self?.updateClipboardSharing()
        }
    }

    nonisolated func spiceAgentDisconnected(
        _ connection: CSConnection
    ) {
        Task { @MainActor [weak self] in
            self?.supportsDisplayResize = false
            self?.supportsClipboard = false
            self?.agentStateHandler?(false, false, false)
            self?.displayResizeSupportHandler?(false)
            self?.updateClipboardSharing()
        }
    }

    nonisolated func spiceForwardedPortOpened(
        _ connection: CSConnection,
        port: CSPort
    ) {}

    nonisolated func spiceForwardedPortClosed(
        _ connection: CSConnection,
        port: CSPort
    ) {}
}

private final class SPICEPasteboardBridge: NSObject,
    CSPasteboardDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var lastChangeCount = -1
    private var cachedHostText: String?
    private var loopGuard = ClipboardLoopGuard()
    private var lastOversizeChangeCount: Int?
    private var storedNoticeHandler: (@MainActor @Sendable (String) -> Void)?

    var noticeHandler: (@MainActor @Sendable (String) -> Void)? {
        get { withLock { storedNoticeHandler } }
        set { withLock { storedNoticeHandler = newValue } }
    }

    func canReadItem(for type: CSPasteboardType) -> Bool {
        guard type == .string else { return false }
        return withLock {
            guard let cachedHostText else { return false }
            return loopGuard.canSendToGuest(cachedHostText)
        }
    }

    func data(for type: CSPasteboardType) -> Data? {
        guard type == .string else { return nil }
        return withLock {
            guard let cachedHostText,
                  loopGuard.canSendToGuest(cachedHostText) else {
                return nil
            }
            return Data(cachedHostText.utf8)
        }
    }

    func setData(_ data: Data, for type: CSPasteboardType) {
        guard type == .string,
              data.count <= GuestAgentProtocol.maximumClipboardSize,
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else {
            if data.count > GuestAgentProtocol.maximumClipboardSize {
                emitNotice(
                    "Guest clipboard sync skipped because the text exceeds 1 MiB."
                )
            }
            return
        }
        setString(text)
    }

    func string() -> String? {
        withLock {
            guard let cachedHostText,
                  loopGuard.canSendToGuest(cachedHostText) else {
                return nil
            }
            return cachedHostText
        }
    }

    func setString(_ string: String) {
        guard !string.isEmpty,
              string.utf8.count
                <= GuestAgentProtocol.maximumClipboardSize else {
            if string.utf8.count
                > GuestAgentProtocol.maximumClipboardSize {
                emitNotice(
                    "Guest clipboard sync skipped because the text exceeds 1 MiB."
                )
            }
            return
        }
        let shouldApply = withLock {
            loopGuard.shouldApplyFromGuest(string)
        }
        guard shouldApply else { return }
        Task { @MainActor [weak self] in
            self?.applyGuestString(string)
        }
    }

    func clearContents() {
        // A guest clipboard release must not erase unrelated host clipboard data.
    }

    @MainActor
    func pollForHostChange() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        let text = pasteboard.string(forType: .string)
        var shouldAnnounce = false
        var shouldReportOversize = false
        withLock {
            guard changeCount != lastChangeCount else { return }
            lastChangeCount = changeCount
            cachedHostText = nil
            guard let text else { return }
            guard text.utf8.count
                    <= GuestAgentProtocol.maximumClipboardSize else {
                if lastOversizeChangeCount != changeCount {
                    lastOversizeChangeCount = changeCount
                    shouldReportOversize = true
                }
                return
            }
            cachedHostText = text
            shouldAnnounce = loopGuard.shouldAnnounceHostChange(text)
        }
        if shouldReportOversize {
            emitNotice(
                "Clipboard sync skipped because the text exceeds 1 MiB."
            )
        }
        if shouldAnnounce {
            NotificationCenter.default.post(
                name: .csPasteboardChanged,
                object: nil
            )
        }
    }

    @MainActor
    private func applyGuestString(_ string: String) {
        let pasteboard = NSPasteboard.general
        if pasteboard.string(forType: .string) != string {
            pasteboard.clearContents()
            pasteboard.setString(string, forType: .string)
        }
        let changeCount = pasteboard.changeCount
        withLock {
            cachedHostText = string
            lastChangeCount = changeCount
        }
    }

    private func emitNotice(_ message: String) {
        let handler = noticeHandler
        Task { @MainActor in
            handler?(message)
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private enum SPICEConnectionError: LocalizedError {
    case startFailed
    case connectionFailed
    case unavailable
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .startFailed:
            "The SPICE client could not start."
        case .connectionFailed:
            "The SPICE connection could not be created."
        case .unavailable:
            "The accelerated display did not become available."
        case .remote(let message):
            message
        }
    }
}

enum PCXTKeyMapper {
    static func scancode(for keyCode: UInt16) -> Int? {
        switch keyCode {
        case 0: 0x1E
        case 1: 0x1F
        case 2: 0x20
        case 3: 0x21
        case 4: 0x23
        case 5: 0x22
        case 6: 0x2C
        case 7: 0x2D
        case 8: 0x2E
        case 9: 0x2F
        case 11: 0x30
        case 12: 0x10
        case 13: 0x11
        case 14: 0x12
        case 15: 0x13
        case 16: 0x15
        case 17: 0x14
        case 18: 0x02
        case 19: 0x03
        case 20: 0x04
        case 21: 0x05
        case 22: 0x07
        case 23: 0x06
        case 24: 0x0D
        case 25: 0x0A
        case 26: 0x08
        case 27: 0x0C
        case 28: 0x09
        case 29: 0x0B
        case 30: 0x1B
        case 31: 0x18
        case 32: 0x16
        case 33: 0x1A
        case 34: 0x17
        case 35: 0x19
        case 36: 0x1C
        case 37: 0x26
        case 38: 0x24
        case 39: 0x28
        case 40: 0x25
        case 41: 0x27
        case 42: 0x2B
        case 43: 0x33
        case 44: 0x35
        case 45: 0x31
        case 46: 0x32
        case 47: 0x34
        case 48: 0x0F
        case 49: 0x39
        case 50: 0x29
        case 51: 0x0E
        case 53: 0x01
        case 54: 0x15C
        case 55: 0x15B
        case 56: 0x2A
        case 57: 0x3A
        case 58: 0x38
        case 59: 0x1D
        case 60: 0x36
        case 61: 0x138
        case 62: 0x11D
        case 65: 0x53
        case 67: 0x37
        case 69: 0x4E
        case 75: 0x135
        case 76: 0x11C
        case 78: 0x4A
        case 81: 0x59
        case 82: 0x52
        case 83: 0x4F
        case 84: 0x50
        case 85: 0x51
        case 86: 0x4B
        case 87: 0x4C
        case 88: 0x4D
        case 89: 0x47
        case 91: 0x48
        case 92: 0x49
        case 96: 0x3F
        case 97: 0x40
        case 98: 0x41
        case 99: 0x3D
        case 100: 0x42
        case 101: 0x43
        case 103: 0x57
        case 105: 0x64
        case 107: 0x65
        case 109: 0x44
        case 111: 0x58
        case 115: 0x147
        case 116: 0x149
        case 117: 0x153
        case 118: 0x3E
        case 119: 0x14F
        case 120: 0x3C
        case 121: 0x151
        case 122: 0x3B
        case 123: 0x14B
        case 124: 0x14D
        case 125: 0x150
        case 126: 0x148
        default: nil
        }
    }
}
