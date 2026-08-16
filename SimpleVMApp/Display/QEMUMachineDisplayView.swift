import AppKit
import SwiftUI

struct QEMUMachineDisplayView: NSViewRepresentable {
    let image: CGImage
    let runtime: QEMUMachineRuntime
    let isImmersive: Bool
    let pointerInteractionHandler:
        (Bool, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> QEMUFramebufferNSView {
        let view = QEMUFramebufferNSView()
        view.runtime = runtime
        view.image = image
        view.isImmersive = isImmersive
        view.pointerInteractionHandler = pointerInteractionHandler
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ view: QEMUFramebufferNSView, context: Context) {
        view.runtime = runtime
        view.image = image
        view.isImmersive = isImmersive
        view.pointerInteractionHandler = pointerInteractionHandler
        if isImmersive {
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
            }
        }
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
    private var trackingAreaReference: NSTrackingArea?
    private var cursorHidden = false
    private var buttonMask: UInt8 = 0
    private var resizeTask: Task<Void, Never>?
    private var accumulatedScrollX: CGFloat = 0
    private var accumulatedScrollY: CGFloat = 0
    var isImmersive = false
    var pointerInteractionHandler:
        ((Bool, NSEvent.ModifierFlags) -> Void)?

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

    deinit {
        MainActor.assumeIsolated {
            restoreCursor()
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
        resizeTask?.cancel()
        let targetSize = fittedIntegerSize()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.runtime?.requestDisplaySize(
                    width: Int(targetSize.width),
                    height: Int(targetSize.height)
                )
            }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if !cursorHidden {
            NSCursor.hide()
            cursorHidden = true
        }
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

    override func mouseDown(with event: NSEvent) {
        if buttonMask == 0 {
            pointerInteractionHandler?(true, event.modifierFlags)
        }
        buttonMask |= 1
        sendPointer(event: event)
    }

    override func mouseUp(with event: NSEvent) {
        buttonMask &= ~1
        sendPointer(event: event)
        if buttonMask == 0 {
            pointerInteractionHandler?(false, event.modifierFlags)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if buttonMask == 0 {
            pointerInteractionHandler?(true, event.modifierFlags)
        }
        buttonMask |= 4
        sendPointer(event: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        buttonMask &= ~4
        sendPointer(event: event)
        if buttonMask == 0 {
            pointerInteractionHandler?(false, event.modifierFlags)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        if buttonMask == 0 {
            pointerInteractionHandler?(true, event.modifierFlags)
        }
        buttonMask |= 2
        sendPointer(event: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        buttonMask &= ~2
        sendPointer(event: event)
        if buttonMask == 0 {
            pointerInteractionHandler?(false, event.modifierFlags)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        sendPointer(event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendPointer(event: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendPointer(event: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendPointer(event: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 else {
            return
        }

        var deltaX = event.scrollingDeltaX
        var deltaY = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            accumulatedScrollX += deltaX
            accumulatedScrollY += deltaY
            let threshold: CGFloat = 10
            deltaX = abs(accumulatedScrollX) >= threshold
                ? accumulatedScrollX
                : 0
            deltaY = abs(accumulatedScrollY) >= threshold
                ? accumulatedScrollY
                : 0
            if deltaX == 0 && deltaY == 0 {
                return
            }
            if deltaX != 0 {
                accumulatedScrollX -= threshold
                    * (deltaX > 0 ? 1 : -1)
            }
            if deltaY != 0 {
                accumulatedScrollY -= threshold
                    * (deltaY > 0 ? 1 : -1)
            }
        }
        let wheelMask: UInt8
        if abs(deltaY) >= abs(deltaX) {
            wheelMask = deltaY > 0 ? 8 : 16
        } else {
            wheelMask = deltaX > 0 ? 32 : 64
        }
        sendPointer(event: event, overrideMask: buttonMask | wheelMask)
        sendPointer(event: event)
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

    private func sendPointer(
        event: NSEvent,
        overrideMask: UInt8? = nil
    ) {
        guard let image else { return }
        let eventPoint = convert(event.locationInWindow, from: nil)
        let contentRect = fittedContentRect()
        let point = CGPoint(
            x: min(max(eventPoint.x, contentRect.minX), contentRect.maxX),
            y: min(max(eventPoint.y, contentRect.minY), contentRect.maxY)
        )
        let scaleX = CGFloat(image.width) / max(contentRect.width, 1)
        let scaleY = CGFloat(image.height) / max(contentRect.height, 1)
        let x = UInt16(clamping: min(
            max(Int((point.x - contentRect.minX) * scaleX), 0),
            image.width - 1
        ))
        let y = UInt16(clamping: min(
            max(Int((contentRect.maxY - point.y) * scaleY), 0),
            image.height - 1
        ))
        runtime?.sendPointer(
            mask: overrideMask ?? buttonMask,
            x: x,
            y: y
        )
    }

    private func fittedContentRect() -> CGRect {
        guard let image, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let aspect = CGFloat(image.width) / CGFloat(image.height)
        if bounds.width / bounds.height > aspect {
            let width = bounds.height * aspect
            return CGRect(
                x: (bounds.width - width) / 2,
                y: 0,
                width: width,
                height: bounds.height
            )
        }
        let height = bounds.width / aspect
        return CGRect(
            x: 0,
            y: (bounds.height - height) / 2,
            width: bounds.width,
            height: height
        )
    }

    private func fittedIntegerSize() -> CGSize {
        let backingSize = convertToBacking(bounds).size
        return CGSize(
            width: max(640, backingSize.width.rounded()),
            height: max(480, backingSize.height.rounded())
        )
    }

    private func restoreCursor() {
        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
    }

}

enum QEMUKeyMapper {
    static func keysym(for event: NSEvent) -> UInt32? {
        guard event.type == .keyDown || event.type == .keyUp else {
            return modifierKeysym(for: event.keyCode)
        }
        return keysym(forKeyCode: event.keyCode)
            ?? event.charactersIgnoringModifiers?.unicodeScalars.first?.value
    }

    static func keysym(forKeyCode keyCode: UInt16) -> UInt32? {
        switch keyCode {
        case 0: return 0x61
        case 1: return 0x73
        case 2: return 0x64
        case 3: return 0x66
        case 4: return 0x68
        case 5: return 0x67
        case 6: return 0x7a
        case 7: return 0x78
        case 8: return 0x63
        case 9: return 0x76
        case 11: return 0x62
        case 12: return 0x71
        case 13: return 0x77
        case 14: return 0x65
        case 15: return 0x72
        case 16: return 0x79
        case 17: return 0x74
        case 18: return 0x31
        case 19: return 0x32
        case 20: return 0x33
        case 21: return 0x34
        case 22: return 0x36
        case 23: return 0x35
        case 24: return 0x3d
        case 25: return 0x39
        case 26: return 0x37
        case 27: return 0x2d
        case 28: return 0x38
        case 29: return 0x30
        case 30: return 0x5d
        case 31: return 0x6f
        case 32: return 0x75
        case 33: return 0x5b
        case 34: return 0x69
        case 35: return 0x70
        case 36, 76: return 0xff0d
        case 37: return 0x6c
        case 38: return 0x6a
        case 39: return 0x27
        case 40: return 0x6b
        case 41: return 0x3b
        case 42: return 0x5c
        case 43: return 0x2c
        case 44: return 0x2f
        case 45: return 0x6e
        case 46: return 0x6d
        case 47: return 0x2e
        case 48: return 0xff09
        case 49: return 0x20
        case 50: return 0x60
        case 51: return 0xff08
        case 53: return 0xff1b
        case 54: return 0xffec
        case 55: return 0xffeb
        case 56: return 0xffe1
        case 57: return 0xffe5
        case 58: return 0xffe9
        case 59: return 0xffe3
        case 60: return 0xffe2
        case 61: return 0xffea
        case 62: return 0xffe4
        case 115: return 0xff50
        case 116: return 0xff55
        case 117: return 0xffff
        case 119: return 0xff57
        case 121: return 0xff56
        case 122: return 0xffbe
        case 120: return 0xffbf
        case 99: return 0xffc0
        case 118: return 0xffc1
        case 96: return 0xffc2
        case 97: return 0xffc3
        case 98: return 0xffc4
        case 100: return 0xffc5
        case 101: return 0xffc6
        case 109: return 0xffc7
        case 103: return 0xffc8
        case 111: return 0xffc9
        case 105: return 0xffca
        case 107: return 0xffcb
        case 123: return 0xff51
        case 124: return 0xff53
        case 125: return 0xff54
        case 126: return 0xff52
        default: return nil
        }
    }

    static func modifierKeysym(for keyCode: UInt16) -> UInt32? {
        switch keyCode {
        case 54: 0xffec
        case 55: 0xffeb
        case 56: 0xffe1
        case 57: 0xffe5
        case 58: 0xffe9
        case 59: 0xffe3
        case 60: 0xffe2
        case 61: 0xffea
        case 62: 0xffe4
        default: nil
        }
    }

    static func isModifierDown(_ event: NSEvent) -> Bool {
        guard let flag = modifierFlag(for: event.keyCode) else {
            return false
        }
        return event.modifierFlags.contains(flag)
    }

    static func modifierKeysyms(
        for modifiers: NSEvent.ModifierFlags
    ) -> [UInt32] {
        var result: [UInt32] = []
        if modifiers.contains(.control) { result.append(0xffe3) }
        if modifiers.contains(.option) { result.append(0xffe9) }
        if modifiers.contains(.shift) { result.append(0xffe1) }
        if modifiers.contains(.command) { result.append(0xffeb) }
        return result
    }

    static func modifierFlag(
        for keyCode: UInt16
    ) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55: .command
        case 56, 60: .shift
        case 58, 61: .option
        case 59, 62: .control
        default: nil
        }
    }
}
