import CocoaSpiceNoUsb
import MetalKit
import SwiftUI

struct SPICEMachineDisplayView: NSViewRepresentable {
    let runtime: QEMUMachineRuntime
    let isImmersive: Bool
    let pointerInteractionHandler:
        (Bool, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> SPICEFramebufferNSView {
        let view = SPICEFramebufferNSView()
        view.runtime = runtime
        view.pointerInteractionHandler = pointerInteractionHandler
        runtime.spiceDisplayView = view
        view.display = runtime.spiceController?.display
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(
        _ view: SPICEFramebufferNSView,
        context: Context
    ) {
        view.runtime = runtime
        view.pointerInteractionHandler = pointerInteractionHandler
        runtime.spiceDisplayView = view
        view.display = runtime.spiceController?.display
        if isImmersive {
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
            }
        }
    }

    static func dismantleNSView(
        _ view: SPICEFramebufferNSView,
        coordinator: Void
    ) {
        view.display = nil
        view.prepareForRemoval()
        view.runtime?.spiceDisplayView = nil
    }
}

final class SPICEFramebufferNSView: MTKView {
    weak var runtime: QEMUMachineRuntime?
    var pointerInteractionHandler:
        ((Bool, NSEvent.ModifierFlags) -> Void)?
    var display: CSDisplay? {
        didSet {
            if oldValue !== display, let oldValue {
                oldValue.removeRenderer(renderer)
            }
            if oldValue !== display, let display {
                display.addRenderer(renderer)
            }
            needsLayout = true
        }
    }

    private var spiceRenderer: CSMetalRenderer!
    private var trackingAreaReference: NSTrackingArea?
    private var buttonMask: UInt8 = 0
    private var cursorHidden = false
    private var appObservers: [NSObjectProtocol] = []
    private var resizeTask: Task<Void, Never>?

    private var renderer: CSRenderer {
        spiceRenderer
    }

    override var acceptsFirstResponder: Bool { true }

    var preferredGuestPixelSize: CGSize? {
        guard drawableSize.width > 0, drawableSize.height > 0 else {
            return nil
        }
        return CGSize(
            width: max(640, drawableSize.width.rounded()),
            height: max(480, drawableSize.height.rounded())
        )
    }

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is unavailable.")
        }
        super.init(frame: .zero, device: device)
        spiceRenderer = CSMetalRenderer(metalKitView: self)
        delegate = spiceRenderer
        framebufferOnly = false
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = 60
        appObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.restoreCursor()
                }
            }
        )
        appObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let window = self.window else {
                        return
                    }
                    let point = self.convert(
                        window.mouseLocationOutsideOfEventStream,
                        from: nil
                    )
                    if self.bounds.contains(point) {
                        self.hideCursor()
                    }
                }
            }
        )
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        MainActor.assumeIsolated {
            if let display, let spiceRenderer {
                display.removeRenderer(spiceRenderer)
            }
        }
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .activeInKeyWindow,
                .inVisibleRect,
                .mouseMoved,
                .mouseEnteredAndExited
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    override func layout() {
        super.layout()
        if let display, display.displaySize.width > 0,
           display.displaySize.height > 0 {
            let scale = min(
                drawableSize.width / display.displaySize.width,
                drawableSize.height / display.displaySize.height
            )
            spiceRenderer.viewportScale = scale
            spiceRenderer.viewportOrigin = .zero
        }
        scheduleResolutionRequest()
    }

    override func mouseDown(with event: NSEvent) {
        if buttonMask == 0 {
            pointerInteractionHandler?(true, event.modifierFlags)
        }
        buttonMask |= 1
        sendPointer(event)
    }

    override func mouseUp(with event: NSEvent) {
        buttonMask &= ~1
        sendPointer(event)
        if buttonMask == 0 {
            pointerInteractionHandler?(false, event.modifierFlags)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if buttonMask == 0 {
            pointerInteractionHandler?(true, event.modifierFlags)
        }
        buttonMask |= 4
        sendPointer(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        buttonMask &= ~4
        sendPointer(event)
        if buttonMask == 0 {
            pointerInteractionHandler?(false, event.modifierFlags)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        if buttonMask == 0 {
            pointerInteractionHandler?(true, event.modifierFlags)
        }
        buttonMask |= 2
        sendPointer(event)
    }

    override func otherMouseUp(with event: NSEvent) {
        buttonMask &= ~2
        sendPointer(event)
        if buttonMask == 0 {
            pointerInteractionHandler?(false, event.modifierFlags)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        hideCursor()
    }

    override func mouseExited(with event: NSEvent) {
        restoreCursor()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            restoreCursor()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func mouseMoved(with event: NSEvent) {
        sendPointer(event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendPointer(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendPointer(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendPointer(event)
    }

    override func scrollWheel(with event: NSEvent) {
        runtime?.spiceController?.sendScroll(
            deltaY: event.scrollingDeltaY,
            mask: buttonMask
        )
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            guard !event.isARepeat else { return }
            runtime?.sendKeyEvent(event)
            runtime?.sendGuestKeyEvent(
                GuestKeyEvent(
                    keyCode: event.keyCode,
                    isDown: false,
                    isRepeat: false,
                    modifiers: event.modifierFlags,
                    isModifier: false
                )
            )
            return
        }
        runtime?.sendKeyEvent(event)
    }

    override func keyUp(with event: NSEvent) {
        runtime?.sendKeyEvent(event)
    }

    override func flagsChanged(with event: NSEvent) {
        runtime?.sendKeyEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    private func sendPointer(_ event: NSEvent) {
        guard let display, bounds.width > 0, bounds.height > 0 else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let scale = min(
            bounds.width / max(display.displaySize.width, 1),
            bounds.height / max(display.displaySize.height, 1)
        )
        let origin = CGPoint(
            x: (bounds.width - display.displaySize.width * scale) / 2,
            y: (bounds.height - display.displaySize.height * scale) / 2
        )
        let x = UInt16(clamping: Int(
            (point.x - origin.x) / max(scale, 0.001)
        ))
        let y = UInt16(clamping: Int(
            (bounds.height - point.y - origin.y) / max(scale, 0.001)
        ))
        runtime?.sendPointer(mask: buttonMask, x: x, y: y)
    }

    func prepareForRemoval() {
        resizeTask?.cancel()
        resizeTask = nil
        restoreCursor()
        for observer in appObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        appObservers.removeAll()
    }

    private func hideCursor() {
        guard !cursorHidden else { return }
        NSCursor.hide()
        cursorHidden = true
    }

    private func restoreCursor() {
        guard cursorHidden else { return }
        NSCursor.unhide()
        cursorHidden = false
    }

    private func scheduleResolutionRequest() {
        guard let targetSize = preferredGuestPixelSize else { return }
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.runtime?.requestDisplaySize(
                width: Int(targetSize.width),
                height: Int(targetSize.height)
            )
        }
    }
}
