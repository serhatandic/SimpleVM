import CocoaSpiceNoUsb
import MetalKit
import SwiftUI

struct SPICEMachineDisplayView: NSViewRepresentable {
    let runtime: QEMUMachineRuntime
    let isImmersive: Bool

    func makeNSView(context: Context) -> SPICEFramebufferNSView {
        let view = SPICEFramebufferNSView()
        view.runtime = runtime
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
        view.runtime?.spiceDisplayView = nil
    }
}

final class SPICEFramebufferNSView: MTKView {
    weak var runtime: QEMUMachineRuntime?
    var display: CSDisplay? {
        didSet {
            if oldValue !== display, let oldValue {
                oldValue.removeRenderer(renderer)
            }
            if oldValue !== display, let display {
                display.addRenderer(renderer)
            }
        }
    }

    private var spiceRenderer: CSMetalRenderer!
    private var trackingAreaReference: NSTrackingArea?
    private var buttonMask: UInt8 = 0

    private var renderer: CSRenderer {
        spiceRenderer
    }

    override var acceptsFirstResponder: Bool { true }

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
                .mouseMoved
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
        guard let display, display.displaySize.width > 0,
              display.displaySize.height > 0 else {
            return
        }
        let scale = min(
            drawableSize.width / display.displaySize.width,
            drawableSize.height / display.displaySize.height
        )
        spiceRenderer.viewportScale = scale
        spiceRenderer.viewportOrigin = .zero
    }

    override func mouseDown(with event: NSEvent) {
        buttonMask |= 1
        sendPointer(event)
    }

    override func mouseUp(with event: NSEvent) {
        buttonMask &= ~1
        sendPointer(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        buttonMask |= 4
        sendPointer(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        buttonMask &= ~4
        sendPointer(event)
    }

    override func otherMouseDown(with event: NSEvent) {
        buttonMask |= 2
        sendPointer(event)
    }

    override func otherMouseUp(with event: NSEvent) {
        buttonMask &= ~2
        sendPointer(event)
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
        runtime?.sendKeyEvent(event)
    }

    override func keyUp(with event: NSEvent) {
        runtime?.sendKeyEvent(event)
    }

    override func flagsChanged(with event: NSEvent) {
        runtime?.sendKeyEvent(event)
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
}
