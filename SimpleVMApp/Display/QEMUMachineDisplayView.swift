import AppKit
import SwiftUI

struct QEMUMachineDisplayView: NSViewRepresentable {
    let image: CGImage
    let runtime: QEMUMachineRuntime

    func makeNSView(context: Context) -> QEMUFramebufferNSView {
        let view = QEMUFramebufferNSView()
        view.runtime = runtime
        view.image = image
        return view
    }

    func updateNSView(_ view: QEMUFramebufferNSView, context: Context) {
        view.runtime = runtime
        view.image = image
    }
}

final class QEMUFramebufferNSView: NSView {
    weak var runtime: QEMUMachineRuntime?
    var image: CGImage? {
        didSet {
            layer?.contents = image
            needsDisplay = true
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .linear
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func mouseDown(with event: NSEvent) {
        sendPointer(event: event, mask: 1)
    }

    override func mouseUp(with event: NSEvent) {
        sendPointer(event: event, mask: 0)
    }

    override func mouseMoved(with event: NSEvent) {
        sendPointer(event: event, mask: 0)
    }

    override func mouseDragged(with event: NSEvent) {
        sendPointer(event: event, mask: 1)
    }

    override func keyDown(with event: NSEvent) {
        if let keysym = keysym(for: event) {
            runtime?.sendKey(keysym, isDown: true)
        }
    }

    override func keyUp(with event: NSEvent) {
        if let keysym = keysym(for: event) {
            runtime?.sendKey(keysym, isDown: false)
        }
    }

    private func sendPointer(event: NSEvent, mask: UInt8) {
        guard let image else { return }
        let point = convert(event.locationInWindow, from: nil)
        let scaleX = CGFloat(image.width) / max(bounds.width, 1)
        let scaleY = CGFloat(image.height) / max(bounds.height, 1)
        let x = UInt16(clamping: Int(point.x * scaleX))
        let y = UInt16(
            clamping: Int((bounds.height - point.y) * scaleY)
        )
        runtime?.sendPointer(mask: mask, x: x, y: y)
    }

    private func keysym(for event: NSEvent) -> UInt32? {
        switch event.keyCode {
        case 36: return 0xff0d
        case 51: return 0xff08
        case 53: return 0xff1b
        case 123: return 0xff51
        case 124: return 0xff53
        case 125: return 0xff54
        case 126: return 0xff52
        default:
            return event.characters?.unicodeScalars.first?.value
        }
    }
}
