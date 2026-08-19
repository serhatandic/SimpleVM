import SwiftUI
import Virtualization

struct MachineDisplayView: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine
    let runtime: MachineRuntime
    let isImmersive: Bool
    let pointerInteractionHandler:
        (Bool, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> ImmersiveVZMachineView {
        let view = ImmersiveVZMachineView()
        view.virtualMachine = virtualMachine
        runtime.displayView = view
        view.runtime = runtime
        view.pointerInteractionHandler = pointerInteractionHandler
        view.capturesSystemKeys = isImmersive
        view.automaticallyReconfiguresDisplay = true
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ view: ImmersiveVZMachineView, context: Context) {
        view.virtualMachine = virtualMachine
        runtime.displayView = view
        view.runtime = runtime
        view.pointerInteractionHandler = pointerInteractionHandler
        view.capturesSystemKeys = isImmersive
        if isImmersive {
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
            }
        }
    }
}

final class ImmersiveVZMachineView: VZVirtualMachineView {
    weak var runtime: MachineRuntime?
    var pointerInteractionHandler:
        ((Bool, NSEvent.ModifierFlags) -> Void)?
    private var buttonMask: UInt8 = 0
    private var resizeTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        guard let window else { return }
        let width = Int((bounds.width * window.backingScaleFactor).rounded())
        let height = Int((bounds.height * window.backingScaleFactor).rounded())
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.runtime?.requestDisplaySize(width: width, height: height)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            resizeTask?.cancel()
            resizeTask = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func mouseDown(with event: NSEvent) {
        if buttonMask == 0 {
            pointerInteractionHandler?(true, event.modifierFlags)
        }
        buttonMask |= 1
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        buttonMask &= ~1
        if buttonMask == 0 {
            pointerInteractionHandler?(false, event.modifierFlags)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if buttonMask == 0 {
            pointerInteractionHandler?(true, event.modifierFlags)
        }
        buttonMask |= 4
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        super.rightMouseUp(with: event)
        buttonMask &= ~4
        if buttonMask == 0 {
            pointerInteractionHandler?(false, event.modifierFlags)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        if buttonMask == 0 {
            pointerInteractionHandler?(true, event.modifierFlags)
        }
        buttonMask |= 2
        super.otherMouseDown(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        super.otherMouseUp(with: event)
        buttonMask &= ~2
        if buttonMask == 0 {
            pointerInteractionHandler?(false, event.modifierFlags)
        }
    }
}
