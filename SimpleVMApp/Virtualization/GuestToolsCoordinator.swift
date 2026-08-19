import AppKit
import Foundation
import Observation
import SimpleVMCore

enum GuestToolsConnectionState: Equatable {
    case stopped
    case checking
    case notConnected(String?)
    case connected(GuestAgentStatus)
    case incompatible(String)
    case failed(String)

    var status: GuestAgentStatus? {
        if case .connected(let status) = self {
            return status
        }
        return nil
    }
}

enum GuestToolsOperationError: LocalizedError, Equatable {
    case notConnected
    case unsupported(GuestAgentCapability)
    case unexpectedResponse
    case guest(GuestAgentFailure)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "SimpleVM Guest Tools are not connected."
        case .unsupported(let capability):
            "Guest Tools do not advertise \(capability.displayName)."
        case .unexpectedResponse:
            "Guest Tools returned an unexpected response."
        case .guest(let failure):
            "Guest Tools reported \(failure.code): \(failure.message)"
        }
    }
}

@MainActor
@Observable
final class GuestToolsCoordinator {
    typealias RequestHandler = (
        GuestAgentRequest
    ) async throws -> GuestAgentResponse

    private(set) var state: GuestToolsConnectionState = .stopped
    private(set) var notice: String?

    @ObservationIgnored
    var statusHandler: ((GuestAgentStatus?) -> Void)?

    @ObservationIgnored
    private var requestHandler: RequestHandler?

    @ObservationIgnored
    private var sharedDirectoryConfigured = false

    @ObservationIgnored
    private var connectionTask: Task<Void, Never>?

    @ObservationIgnored
    private let clipboardSynchronizer = GuestClipboardSynchronizer()

    func start(
        sharedDirectoryConfigured: Bool,
        requestHandler: @escaping RequestHandler
    ) {
        stop()
        self.requestHandler = requestHandler
        self.sharedDirectoryConfigured = sharedDirectoryConfigured
        retry()
    }

    func retry() {
        guard requestHandler != nil else {
            state = .stopped
            return
        }
        connectionTask?.cancel()
        clipboardSynchronizer.stop()
        notice = nil
        state = .checking
        statusHandler?(nil)
        connectionTask = Task { [weak self] in
            await self?.probe()
        }
    }

    func stop() {
        connectionTask?.cancel()
        connectionTask = nil
        clipboardSynchronizer.stop()
        requestHandler = nil
        state = .stopped
        notice = nil
        statusHandler?(nil)
    }

    func supports(_ capability: GuestAgentCapability) -> Bool {
        state.status?.capabilities.contains(capability) == true
    }

    func reportNotice(_ message: String) {
        notice = message
    }

    func resolvedInputProfile(
        configuredProfile: MachineInputProfile,
        machineName: String
    ) -> MachineInputProfile {
        guard configuredProfile == .automatic,
              let desktop = state.status?.desktopEnvironment else {
            return configuredProfile.resolved(forMachineNamed: machineName)
        }
        switch desktop {
        case .hyprland:
            return .macOSHyprland
        case .gnome:
            return .macOSGNOME
        case .other:
            return configuredProfile.resolved(forMachineNamed: machineName)
        }
    }

    func requestShutdown() async throws {
        try await expectAccepted(
            .shutdown,
            capability: .gracefulShutdown
        )
    }

    func requestReboot() async throws {
        try await expectAccepted(.reboot, capability: .gracefulReboot)
    }

    func requestDisplayResize(width: Int, height: Int) async throws {
        guard GuestDisplaySize.isValid(width: width, height: height) else {
            throw GuestAgentProtocolError.invalidDisplaySize
        }
        try await expectAccepted(
            .resizeDisplay(width: width, height: height),
            capability: .displayResize
        )
    }

    private func probe() async {
        guard let requestHandler else { return }
        do {
            var status = try await fetchStatus(using: requestHandler)
            try Task.checkCancellation()
            guard status.protocolVersion <= GuestAgentProtocol.currentVersion else {
                state = .incompatible(
                    "Guest protocol \(status.protocolVersion) is newer than the host protocol \(GuestAgentProtocol.currentVersion)."
                )
                statusHandler?(nil)
                return
            }
            if sharedDirectoryConfigured,
               status.capabilities.contains(.mountSharedDirectory),
               status.sharedMountStatus.state != .mounted {
                do {
                    let response = try await requestHandler(
                        .mountSharedDirectory
                    )
                    try Task.checkCancellation()
                    switch response {
                    case .accepted:
                        status = try await fetchStatus(using: requestHandler)
                        try Task.checkCancellation()
                    case .failure(let failure):
                        notice =
                            "Guest Tools connected, but the shared folder could not be mounted: \(failure.message)"
                    case .hello, .status, .clipboard:
                        notice =
                            "Guest Tools connected, but returned an unexpected shared-folder response."
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    notice =
                        "Guest Tools connected, but the shared folder could not be mounted: \(error.localizedDescription)"
                }
            }
            try Task.checkCancellation()
            state = .connected(status)
            statusHandler?(status)
            if status.sessionType == .wayland,
               status.capabilities.contains(.clipboardRead),
               status.capabilities.contains(.clipboardWrite) {
                clipboardSynchronizer.start(
                    requestHandler: requestHandler
                ) { [weak self] message in
                    self?.notice = message
                }
            }
        } catch is CancellationError {
            return
        } catch GuestAgentProtocolError.incompatibleVersion(let version) {
            state = .incompatible(
                "Guest protocol \(version) is not supported."
            )
            statusHandler?(nil)
        } catch {
            state = .notConnected(error.localizedDescription)
            statusHandler?(nil)
        }
    }

    private func fetchStatus(
        using requestHandler: RequestHandler
    ) async throws -> GuestAgentStatus {
        let response = try await requestHandler(.status)
        switch response {
        case .status(let status):
            return status
        case .failure(let failure):
            throw GuestToolsOperationError.guest(failure)
        case .hello, .accepted, .clipboard:
            throw GuestToolsOperationError.unexpectedResponse
        }
    }

    private func expectAccepted(
        _ request: GuestAgentRequest,
        capability: GuestAgentCapability
    ) async throws {
        guard supports(capability) else {
            throw GuestToolsOperationError.unsupported(capability)
        }
        guard let requestHandler else {
            throw GuestToolsOperationError.notConnected
        }
        try validateAccepted(try await requestHandler(request))
    }

    private func validateAccepted(_ response: GuestAgentResponse) throws {
        switch response {
        case .accepted:
            return
        case .failure(let failure):
            throw GuestToolsOperationError.guest(failure)
        case .hello, .status, .clipboard:
            throw GuestToolsOperationError.unexpectedResponse
        }
    }
}

struct ClipboardLoopGuard: Equatable {
    private(set) var lastSentToGuest: UInt64?
    private(set) var lastAppliedFromGuest: UInt64?

    mutating func shouldSendToGuest(_ text: String) -> Bool {
        let value = Self.fingerprint(text)
        guard value != lastAppliedFromGuest,
              value != lastSentToGuest else {
            return false
        }
        lastAppliedFromGuest = nil
        markSentToGuest(text)
        return true
    }

    func canSendToGuest(_ text: String) -> Bool {
        let value = Self.fingerprint(text)
        return value != lastAppliedFromGuest && value != lastSentToGuest
    }

    mutating func markSentToGuest(_ text: String) {
        let value = Self.fingerprint(text)
        if value != lastAppliedFromGuest {
            lastAppliedFromGuest = nil
        }
        lastSentToGuest = value
    }

    mutating func shouldAnnounceHostChange(_ text: String) -> Bool {
        let value = Self.fingerprint(text)
        guard value != lastAppliedFromGuest else {
            return false
        }
        lastAppliedFromGuest = nil
        return value != lastSentToGuest
    }

    mutating func shouldApplyFromGuest(_ text: String) -> Bool {
        let value = Self.fingerprint(text)
        guard value != lastSentToGuest, value != lastAppliedFromGuest else {
            return false
        }
        lastAppliedFromGuest = value
        return true
    }

    static func fingerprint(_ text: String) -> UInt64 {
        text.utf8.reduce(14_695_981_039_346_656_037) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
    }
}

@MainActor
final class GuestClipboardSynchronizer {
    private var task: Task<Void, Never>?
    private var lastPasteboardChangeCount = NSPasteboard.general.changeCount
    private var loopGuard = ClipboardLoopGuard()
    private var pendingHostText: String?
    private var pendingHostWriteAttempts = 0

    func start(
        requestHandler: @escaping GuestToolsCoordinator.RequestHandler,
        noticeHandler: @escaping (String) -> Void
    ) {
        stop()
        lastPasteboardChangeCount = NSPasteboard.general.changeCount
        loopGuard = ClipboardLoopGuard()
        pendingHostText = nil
        pendingHostWriteAttempts = 0
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if NSApp.isActive {
                    await synchronize(
                        using: requestHandler,
                        noticeHandler: noticeHandler
                    )
                }
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        pendingHostText = nil
        pendingHostWriteAttempts = 0
    }

    private func synchronize(
        using requestHandler: GuestToolsCoordinator.RequestHandler,
        noticeHandler: (String) -> Void
    ) async {
        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount != lastPasteboardChangeCount {
            lastPasteboardChangeCount = pasteboard.changeCount
            pendingHostText = nil
            pendingHostWriteAttempts = 0
            if let text = pasteboard.string(forType: .string) {
                guard text.utf8.count
                        <= GuestAgentProtocol.maximumClipboardSize else {
                    pendingHostText = nil
                    noticeHandler(
                        "Clipboard sync skipped because the text exceeds 1 MiB."
                    )
                    return
                }
                if loopGuard.canSendToGuest(text) {
                    pendingHostText = text
                }
            }
        }

        if let pendingHostText {
            do {
                let response = try await requestHandler(
                    .writeClipboard(text: pendingHostText)
                )
                if case .accepted = response {
                    loopGuard.markSentToGuest(pendingHostText)
                    self.pendingHostText = nil
                    pendingHostWriteAttempts = 0
                } else {
                    pendingHostWriteAttempts += 1
                    noticeHandler(
                        "Guest Tools rejected the host clipboard text."
                    )
                    if pendingHostWriteAttempts < 3 {
                        return
                    }
                    self.pendingHostText = nil
                    pendingHostWriteAttempts = 0
                }
            } catch {
                pendingHostWriteAttempts += 1
                noticeHandler(
                    "Clipboard text could not be sent to the guest."
                )
                if pendingHostWriteAttempts < 3 {
                    return
                }
                self.pendingHostText = nil
                pendingHostWriteAttempts = 0
            }
        }

        let response: GuestAgentResponse
        do {
            response = try await requestHandler(.readClipboard)
        } catch {
            noticeHandler("Guest clipboard text could not be read.")
            return
        }
        guard case .clipboard(let text) = response,
              text.utf8.count <= GuestAgentProtocol.maximumClipboardSize,
              loopGuard.shouldApplyFromGuest(text),
              pasteboard.string(forType: .string) != text else {
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastPasteboardChangeCount = pasteboard.changeCount
    }
}

extension GuestAgentCapability {
    var displayName: String {
        switch self {
        case .gracefulShutdown:
            "graceful shutdown"
        case .gracefulReboot:
            "graceful reboot"
        case .mountSharedDirectory:
            "shared-directory mounting"
        case .clipboardRead:
            "clipboard reading"
        case .clipboardWrite:
            "clipboard writing"
        case .displayResize:
            "display resizing"
        }
    }
}

extension GuestAgentStatus {
    var supportsAgentClipboardTransport: Bool {
        sessionType == .wayland
            && capabilities.contains(.clipboardRead)
            && capabilities.contains(.clipboardWrite)
    }
}
