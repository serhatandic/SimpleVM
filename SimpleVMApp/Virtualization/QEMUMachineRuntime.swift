import CoreGraphics
import Foundation
import AppKit
import Observation
import SimpleVMCore

@MainActor
@Observable
final class QEMUMachineRuntime {
    private(set) var state: MachineRuntimeState
    private(set) var framebuffer: CGImage?
    private(set) var requiresDiskPassword = false

    var hasDisplay: Bool {
        framebuffer != nil
    }

    @ObservationIgnored
    var stateHandler: ((MachineRuntimeState) -> Void)?

    @ObservationIgnored
    var errorHandler: ((any Error) -> Void)?

    @ObservationIgnored
    private var processController: QEMUProcessController?

    @ObservationIgnored
    private var vncClient: SimpleVNCClient?

    @ObservationIgnored
    private var diagnosticURL: URL?

    @ObservationIgnored
    private var serialMonitorTask: Task<Void, Never>?

    @ObservationIgnored
    private var serialReadOffset: UInt64 = 0

    @ObservationIgnored
    private var lastRequestedDisplaySize: (UInt16, UInt16)?

    @ObservationIgnored
    private var pressedKeysyms: Set<UInt32> = []

    @ObservationIgnored
    private var pressedModifierKeyCodes: Set<UInt16> = []

    init(state: MachineRuntimeState = .stopped) {
        switch state {
        case .running, .starting, .stopping:
            self.state = .stopped
        default:
            self.state = state
        }
    }

    func start(
        machine: Machine,
        diskURL: URL,
        installerURL: URL?,
        backendStateURL: URL
    ) async {
        guard state.canStart else {
            return
        }
        transition(to: .starting)
        diagnosticURL = backendStateURL.appending(path: "runtime.log")
        startSerialMonitor(
            at: backendStateURL.appending(path: "serial.log")
        )
        log("starting")
        do {
            let runtime = try QEMURuntimeDiscovery.discover()
            log("QEMU discovered at \(runtime.systemExecutableURL.path)")
            let port = try await LoopbackPortAllocator.allocate()
            log("reserved VNC port \(port)")
            var releasesPortReservation = true
            defer {
                if releasesPortReservation {
                    LoopbackPortAllocator.release(port)
                }
            }
            let configuration = try QEMUConfigurationBuilder.make(
                machine: machine,
                diskURL: diskURL,
                installerURL: installerURL,
                backendStateURL: backendStateURL,
                runtime: runtime,
                vncPort: port
            )
            log("configuration built")
            let controller = QEMUProcessController { [weak self] processState in
                Task { @MainActor in
                    self?.handle(processState: processState)
                }
            }
            processController = controller
            try await controller.start(configuration: configuration)
            log("QEMU process started")
            LoopbackPortAllocator.release(port)
            releasesPortReservation = false

            let client = try await connectVNC(port: port)
            vncClient = client
            log("VNC connected")
            transition(to: .running)
        } catch {
            log("start failed: \(error.localizedDescription)")
            await processController?.forceStop()
            clearRuntime()
            transition(to: .failed(message: error.localizedDescription))
        }
    }

    func stop() async {
        guard state == .running || state == .stopping else {
            return
        }
        transition(to: .stopping)
        vncClient?.errorHandler = nil
        vncClient?.disconnect()
        await processController?.stop()
        clearRuntime()
        transition(to: .stopped)
    }

    func forceStop() async {
        guard state == .starting || state == .running || state == .stopping else {
            return
        }
        transition(to: .stopping)
        vncClient?.errorHandler = nil
        vncClient?.disconnect()
        await processController?.forceStop()
        clearRuntime()
        transition(to: .stopped)
    }

    func sendKey(_ keysym: UInt32, isDown: Bool) {
        vncClient?.sendKey(keysym, isDown: isDown)
    }

    func sendPointer(mask: UInt8, x: UInt16, y: UInt16) {
        vncClient?.sendPointer(mask: mask, x: x, y: y)
    }

    func requestDisplaySize(width: Int, height: Int) {
        let scale = min(
            1,
            min(1_920 / Double(max(width, 1)), 1_200 / Double(max(height, 1)))
        )
        let width = UInt16(clamping: max(Int(Double(width) * scale), 640))
        let height = UInt16(clamping: max(Int(Double(height) * scale), 480))
        let requested = (
            width - (width % 8),
            height - (height % 8)
        )
        guard lastRequestedDisplaySize?.0 != requested.0
                || lastRequestedDisplaySize?.1 != requested.1 else {
            return
        }
        lastRequestedDisplaySize = requested
        vncClient?.requestDesktopSize(
            width: requested.0,
            height: requested.1
        )
    }

    func sendKeyEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            guard let keysym = QEMUKeyMapper.keysym(for: event) else { return }
            pressedKeysyms.insert(keysym)
            sendKey(keysym, isDown: true)
        case .keyUp:
            guard let keysym = QEMUKeyMapper.keysym(for: event) else { return }
            pressedKeysyms.remove(keysym)
            sendKey(keysym, isDown: false)
            if event.keyCode == 36 || event.keyCode == 76 {
                requiresDiskPassword = false
            }
        case .flagsChanged:
            guard let keysym = QEMUKeyMapper.modifierKeysym(
                for: event.keyCode
            ) else { return }
            if event.keyCode == 57 {
                sendKey(keysym, isDown: true)
                sendKey(keysym, isDown: false)
            } else if !QEMUKeyMapper.isModifierDown(event) {
                pressedModifierKeyCodes.remove(event.keyCode)
                pressedKeysyms.remove(keysym)
                sendKey(keysym, isDown: false)
            } else {
                pressedModifierKeyCodes.insert(event.keyCode)
                pressedKeysyms.insert(keysym)
                sendKey(keysym, isDown: true)
            }

        default:
            break
        }
    }

    func releaseAllKeys() {
        for keysym in pressedKeysyms {
            sendKey(keysym, isDown: false)
        }
        pressedKeysyms.removeAll()
        pressedModifierKeyCodes.removeAll()
    }

    private func handle(processState: QEMUProcessController.State) {
        switch processState {
        case .stopped:
            clearRuntime()
            transition(to: .stopped)
        case .failed(let message):
            clearRuntime()
            transition(to: .failed(message: message))
        case .starting, .running, .stopping:
            break
        }
    }

    private func connectVNC(port: UInt16) async throws -> SimpleVNCClient {
        var lastError: (any Error)?
        for attempt in 1...100 {
            let client = SimpleVNCClient(port: port)
            client.imageHandler = { [weak self] image in
                let image = CGImageBox(image)
                Task { @MainActor in
                    self?.framebuffer = image.value
                }
            }
            client.errorHandler = { [weak self] error in
                Task { @MainActor in
                    self?.errorHandler?(error)
                }
            }
            do {
                log("connecting VNC (attempt \(attempt))")
                try await client.connect()
                return client
            } catch {
                lastError = error
                client.disconnect()
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        throw lastError ?? QEMUVNCError.unavailable
    }

    private func transition(to state: MachineRuntimeState) {
        self.state = state
        stateHandler?(state)
    }

    private func log(_ message: String) {
        guard let diagnosticURL else { return }
        let line = "\(Date().ISO8601Format()) \(message)\n"
        if !FileManager.default.fileExists(atPath: diagnosticURL.path) {
            _ = FileManager.default.createFile(
                atPath: diagnosticURL.path,
                contents: Data(line.utf8)
            )
            return
        }

        guard let handle = try? FileHandle(forWritingTo: diagnosticURL) else {
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    private func startSerialMonitor(at url: URL) {
        serialMonitorTask?.cancel()
        serialReadOffset = 0
        lastRequestedDisplaySize = nil
        requiresDiskPassword = false
        serialMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let attributes = try? FileManager.default.attributesOfItem(
                    atPath: url.path
                ), let fileSize = attributes[.size] as? NSNumber {
                    let endOffset = fileSize.uint64Value
                    if endOffset < serialReadOffset {
                        serialReadOffset = 0
                    }
                    if endOffset > serialReadOffset,
                       let handle = try? FileHandle(forReadingFrom: url) {
                        defer { try? handle.close() }
                        try? handle.seek(toOffset: serialReadOffset)
                        let data = try? handle.readToEnd()
                        serialReadOffset = endOffset
                        if let data,
                           String(decoding: data, as: UTF8.self).contains(
                            "A password is required to access the root volume"
                           ) {
                            requiresDiskPassword = true
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func clearRuntime() {
        serialMonitorTask?.cancel()
        serialMonitorTask = nil
        serialReadOffset = 0
        requiresDiskPassword = false
        vncClient?.errorHandler = nil
        vncClient?.disconnect()
        vncClient = nil
        framebuffer = nil
        processController = nil
        pressedKeysyms.removeAll()
        pressedModifierKeyCodes.removeAll()
    }
}

private final class CGImageBox: @unchecked Sendable {
    let value: CGImage
    init(_ value: CGImage) {
        self.value = value
    }
}

private enum QEMUVNCError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "QEMU started but its display did not become available."
    }
}

private extension MachineRuntimeState {
    var canStart: Bool {
        switch self {
        case .stopped, .failed:
            true
        case .starting, .running, .stopping:
            false
        }
    }
}
