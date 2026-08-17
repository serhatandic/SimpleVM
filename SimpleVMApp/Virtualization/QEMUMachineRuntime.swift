import CoreGraphics
import Foundation
import AppKit
import Observation
import SimpleVMCore

@MainActor
@Observable
final class QEMUMachineRuntime {
    private(set) var state: MachineRuntimeState
    private(set) var hasDisplay = false
    private(set) var requiresDiskPassword = false
    private(set) var usesAcceleratedDisplay = false

    @ObservationIgnored
    private(set) var framebuffer: CGImage?

    @ObservationIgnored
    weak var displayView: QEMUFramebufferNSView?

    @ObservationIgnored
    weak var spiceDisplayView: SPICEFramebufferNSView?

    @ObservationIgnored
    private(set) var spiceController: SPICEConnectionController?

    @ObservationIgnored
    var stateHandler: ((MachineRuntimeState) -> Void)?

    @ObservationIgnored
    var errorHandler: ((any Error) -> Void)?

    @ObservationIgnored
    private var processController: QEMUProcessController?

    @ObservationIgnored
    private var vncClient: SimpleVNCClient?

    @ObservationIgnored
    var keySink: ((UInt32, Bool) -> Void)?

    @ObservationIgnored
    private var diagnosticURL: URL?

    @ObservationIgnored
    private var serialMonitorTask: Task<Void, Never>?

    @ObservationIgnored
    private var serialReadOffset: UInt64 = 0

    @ObservationIgnored
    private var lastRequestedDisplaySize: (UInt16, UInt16)?

    @ObservationIgnored
    private var lastWorkspaceSwipeTime = 0.0

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
            let runtime = try discoverRuntime()
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

            switch runtime.displayBackend {
            case .vnc:
                let client = try await connectVNC(port: port)
                vncClient = client
                log("VNC connected")
            case .spiceGL:
                guard let socketURL = configuration.spiceSocketURL else {
                    throw QEMUVNCError.unavailable
                }
                let spice = SPICEConnectionController()
                spice.displayHandler = { [weak self] display in
                    guard let self else { return }
                    self.spiceDisplayView?.display = display
                    self.hasDisplay = true
                }
                spice.errorHandler = { [weak self] error in
                    self?.errorHandler?(error)
                }
                spiceController = spice
                usesAcceleratedDisplay = true
                try await spice.connect(to: socketURL)
                log("SPICE GL connected")
            }
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
        if let keySink {
            keySink(keysym, isDown)
        } else {
            vncClient?.sendKey(keysym, isDown: isDown)
        }
    }

    func sendPointer(mask: UInt8, x: UInt16, y: UInt16) {
        if let spiceController {
            spiceController.sendPointer(mask: mask, x: x, y: y)
        } else {
            vncClient?.sendPointer(mask: mask, x: x, y: y)
        }
    }

    func requestDisplaySize(width: Int, height: Int) {
        if let display = spiceController?.display {
            display.requestResolution(
                CGRect(x: 0, y: 0, width: width, height: height)
            )
            return
        }
        let scale = min(
            1,
            min(1_280 / Double(max(width, 1)), 800 / Double(max(height, 1)))
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
        if spiceController != nil {
            if event.keyCode == 57 {
                let press = GuestKeyEvent(
                    keyCode: event.keyCode,
                    isDown: true,
                    isRepeat: false,
                    modifiers: event.modifierFlags,
                    isModifier: true
                )
                sendGuestKeyEvent(press)
                sendGuestKeyEvent(
                    GuestKeyEvent(
                        keyCode: event.keyCode,
                        isDown: false,
                        isRepeat: false,
                        modifiers: event.modifierFlags,
                        isModifier: true
                    )
                )
                return
            }
            let isDown: Bool
            switch event.type {
            case .keyDown:
                isDown = true
            case .keyUp:
                isDown = false
            case .flagsChanged:
                isDown = QEMUKeyMapper.isModifierDown(event)
            default:
                return
            }
            sendGuestKeyEvent(
                GuestKeyEvent(
                    keyCode: event.keyCode,
                    isDown: isDown,
                    isRepeat: event.isARepeat,
                    modifiers: event.modifierFlags,
                    isModifier: event.type == .flagsChanged
                )
            )
            if !isDown, event.keyCode == 36 || event.keyCode == 76 {
                requiresDiskPassword = false
            }
            return
        }
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

    func sendGuestKeyEvent(_ event: GuestKeyEvent) {
        if !event.isDown,
           event.keyCode == 36 || event.keyCode == 76 {
            requiresDiskPassword = false
        }
        if let spiceController {
            spiceController.sendKey(event)
            return
        }
        guard let keysym = QEMUKeyMapper.keysym(for: event) else { return }
        if event.isDown {
            pressedKeysyms.insert(keysym)
            if event.isModifier {
                pressedModifierKeyCodes.insert(event.keyCode)
            }
        } else {
            pressedKeysyms.remove(keysym)
            pressedModifierKeyCodes.remove(event.keyCode)
        }
        sendKey(keysym, isDown: event.isDown)
    }

    func releaseAllKeys() {
        spiceController?.releaseKeys()
        for keysym in pressedKeysyms {
            sendKey(keysym, isDown: false)
        }

        pressedKeysyms.removeAll()
        pressedModifierKeyCodes.removeAll()
    }

    func sendWorkspaceSwipe(_ direction: WorkspaceSwipeDirection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastWorkspaceSwipeTime > 0.25 else { return }
        lastWorkspaceSwipeTime = now
        let router = GuestInputRouter { [weak self] event in
            self?.sendGuestKeyEvent(event)
        }
        router.sendChord(
            KeyboardMappingSettings.shared.workspaceChord(
                direction: direction,
                workspaceCount:
                    KeyboardMappingSettings.hyprlandWorkspaceCount
            )
        )
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
                    guard let self else { return }
                    self.framebuffer = image.value
                    self.displayView?.image = image.value
                    if !self.hasDisplay {
                        self.hasDisplay = true
                    }
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
        lastWorkspaceSwipeTime = 0
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
        spiceController?.disconnect()
        spiceController = nil
        framebuffer = nil
        displayView?.image = nil
        displayView = nil
        spiceDisplayView?.display = nil
        spiceDisplayView = nil
        hasDisplay = false
        usesAcceleratedDisplay = false
        processController = nil
        pressedKeysyms.removeAll()
        pressedModifierKeyCodes.removeAll()
    }

    private func discoverRuntime() throws -> QEMURuntime {
        let fallback = try QEMURuntimeDiscovery.discover()
        let fileManager = FileManager.default
        let helperURL = Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/UTMQEMULauncher")
        let resourcesURL = URL(
            filePath: "/Applications/UTM.app/Contents/Resources/qemu",
            directoryHint: .isDirectory
        )
        let frameworkURL = URL(
            filePath:
                "/Applications/UTM.app/Contents/Frameworks/qemu-x86_64-softmmu.framework/qemu-x86_64-softmmu"
        )
        guard fileManager.isExecutableFile(atPath: helperURL.path),
              fileManager.fileExists(atPath: frameworkURL.path) else {
            return fallback
        }
        return QEMURuntime(
            systemExecutableURL: helperURL,
            imageExecutableURL: fallback.imageExecutableURL,
            firmwareCodeURL: resourcesURL.appending(
                path: "edk2-x86_64-code.fd"
            ),
            firmwareVariablesTemplateURL: resourcesURL.appending(
                path: "edk2-i386-vars.fd"
            ),
            displayBackend: .spiceGL(
                resourceDirectoryURL: resourcesURL
            )
        )
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
