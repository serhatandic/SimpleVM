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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        nil
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
