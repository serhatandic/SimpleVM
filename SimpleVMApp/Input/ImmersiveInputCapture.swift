import AppKit
@preconcurrency import ApplicationServices
@preconcurrency import CoreGraphics

@MainActor
final class ImmersiveInputCapture {
    private static let gestureEventType = CGEventType(rawValue: 29)!
    private static let dockControlEventType = CGEventType(rawValue: 30)!
    private static let eventTypeField = CGEventField(rawValue: 55)!
    private static let gestureHIDTypeField = CGEventField(rawValue: 110)!
    private static let gestureMotionField = CGEventField(rawValue: 123)!
    private static let gestureProgressField = CGEventField(rawValue: 124)!
    private static let gesturePhaseField = CGEventField(rawValue: 132)!
    private static let dockSwipeHIDType: Int64 = 23
    private static let horizontalMotion: Int64 = 1
    private static let gestureBegan: Int64 = 1
    private static let gestureEnded: Int64 = 4
    private static let gestureCancelled: Int64 = 8

    private let workspaceSwipeHandler: (WorkspaceSwipeDirection) -> Void
    private let router: GuestInputRouter
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var callbackContext: UnsafeMutableRawPointer?
    private var tracksDockSwipe = false
    private var dockSwipeProgress = 0.0

    init(
        keyEventHandler: @escaping (GuestKeyEvent) -> Void,
        workspaceSwipeHandler: @escaping (WorkspaceSwipeDirection) -> Void
    ) {
        self.workspaceSwipeHandler = workspaceSwipeHandler
        router = GuestInputRouter(keyEventHandler: keyEventHandler)
    }

    static var hasAccessibilityAccess: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibilityAccess() -> Bool {
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func start() -> Bool {
        guard tap == nil else { return true }
        guard Self.requestAccessibilityAccess() else { return false }

        let keyboardMask =
            CGEventMask(1) << CGEventType.keyDown.rawValue
            | CGEventMask(1) << CGEventType.keyUp.rawValue
            | CGEventMask(1) << CGEventType.flagsChanged.rawValue
        let gestureMask =
            CGEventMask(1) << Self.gestureEventType.rawValue
            | CGEventMask(1) << Self.dockControlEventType.rawValue
        let pointer = Unmanaged.passRetained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: keyboardMask | gestureMask,
            callback: Self.tapCallback,
            userInfo: pointer
        ) else {
            Unmanaged<ImmersiveInputCapture>
                .fromOpaque(pointer)
                .release()
            return false
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        callbackContext = pointer
        return true
    }

    func stop() {
        router.releaseAll()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                runLoopSource,
                .commonModes
            )
        }
        tap = nil
        runLoopSource = nil
        if let callbackContext {
            Unmanaged<ImmersiveInputCapture>
                .fromOpaque(callbackContext)
                .release()
            self.callbackContext = nil
        }
        tracksDockSwipe = false
        dockSwipeProgress = 0
    }

    func beginPointerInteraction(modifiers: NSEvent.ModifierFlags) {
        router.beginPointerInteraction(
            modifiers: KeyboardMappingSettings.shared.pointerModifiers(
                from: modifiers
            )
        )
    }

    func endPointerInteraction() {
        router.endPointerInteraction()
    }

    func sendWorkspaceSwipe(_ direction: WorkspaceSwipeDirection) {
        router.sendChord(
            KeyboardMappingSettings.shared.workspaceChord(direction: direction)
        )
    }

    func setEnabled(_ enabled: Bool) {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: enabled)
        }
        if !enabled {
            router.releaseAll()
        }
    }

    private static let tapCallback: CGEventTapCallBack = {
        _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let capture = Unmanaged<ImmersiveInputCapture>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        return MainActor.assumeIsolated {
            capture.handle(type: type, event: event)
        }
    }

    private func handle(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData)
            == GuestInputEventMarker.value {
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        if handleDockGesture(event) {
            return nil
        }
        switch type {
        case .flagsChanged:
            router.updateHostModifiers(
                modifierFlags(from: event.flags)
            )
            return nil
        case .keyDown:
            let keyCode = UInt16(clamping: event.getIntegerValueField(
                .keyboardEventKeycode
            ))
            let modifiers = modifierFlags(from: event.flags)
            if keyCode == 53,
               modifiers.contains([.control, .option, .command]) {
                NotificationCenter.default.post(
                    name: .simpleVMExitImmersion,
                    object: self
                )
                return nil
            }
            let repeats = event.getIntegerValueField(
                .keyboardEventAutorepeat
            ) != 0
            let chord = KeyboardMappingSettings.shared.chord(
                    keyCode: keyCode,
                    modifiers: modifiers
                )
            router.press(
                hostKeyCode: keyCode,
                chord: chord,
                repeats: repeats
            )
            return nil
        case .keyUp:
            let keyCode = UInt16(clamping: event.getIntegerValueField(
                .keyboardEventKeycode
            ))
            router.release(hostKeyCode: keyCode)
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleDockGesture(_ event: CGEvent) -> Bool {
        let eventType = event.getIntegerValueField(Self.eventTypeField)
        if eventType == Int64(Self.dockControlEventType.rawValue),
           event.getIntegerValueField(Self.gestureHIDTypeField)
                == Self.dockSwipeHIDType,
           event.getIntegerValueField(Self.gestureMotionField)
                == Self.horizontalMotion {
            let phase = event.getIntegerValueField(Self.gesturePhaseField)
            if phase == Self.gestureBegan {
                tracksDockSwipe = true
                dockSwipeProgress = 0
            }
            if tracksDockSwipe {
                dockSwipeProgress = event.getDoubleValueField(
                    Self.gestureProgressField
                )
            }
            if phase == Self.gestureEnded, tracksDockSwipe {
                if abs(dockSwipeProgress) > 0.1 {
                    let direction: WorkspaceSwipeDirection =
                        dockSwipeProgress < 0 ? .next : .previous
                    workspaceSwipeHandler(direction)
                }
                tracksDockSwipe = false
                dockSwipeProgress = 0
            } else if phase == Self.gestureCancelled {
                tracksDockSwipe = false
                dockSwipeProgress = 0
            }
            return true
        }
        if eventType == Int64(Self.gestureEventType.rawValue),
           tracksDockSwipe {
            return true
        }
        return false
    }

    private func modifierFlags(
        from flags: CGEventFlags
    ) -> NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        return result
    }

}

@MainActor
final class GuestInputRouter {
    private let keyEventHandler: (GuestKeyEvent) -> Void
    private var activeChords: [UInt16: GuestChord] = [:]
    private var guestModifierFlags: NSEvent.ModifierFlags = []
    private var pointerModifierFlags: NSEvent.ModifierFlags = []
    private var hostModifierFlags: NSEvent.ModifierFlags = []
    private var latchedModifierFlags: NSEvent.ModifierFlags = []

    init(keyEventHandler: @escaping (GuestKeyEvent) -> Void) {
        self.keyEventHandler = keyEventHandler
    }

    func press(
        hostKeyCode: UInt16,
        chord: GuestChord,
        repeats: Bool
    ) {
        let resolved = activeChords[hostKeyCode] ?? chord
        if !repeats {
            latchedModifierFlags = resolved.modifiers
            activeChords[hostKeyCode] = resolved
            synchronizeGuestModifiers(including: resolved.modifiers)
        }
        emitKey(
            keyCode: resolved.keyCode,
            isDown: true,
            modifiers: resolved.modifiers,
            repeats: repeats
        )
    }

    func release(hostKeyCode: UInt16) {
        guard let chord = activeChords.removeValue(
            forKey: hostKeyCode
        ) else {
            return
        }
        emitKey(
            keyCode: chord.keyCode,
            isDown: false,
            modifiers: chord.modifiers,
            repeats: false
        )
        synchronizeGuestModifiers()
    }

    func beginPointerInteraction(modifiers: NSEvent.ModifierFlags) {
        pointerModifierFlags = normalized(modifiers)
        synchronizeGuestModifiers()
    }

    func updateHostModifiers(_ modifiers: NSEvent.ModifierFlags) {
        let updated = normalized(modifiers)
        if hostModifierFlags.contains(.command)
            && !updated.contains(.command) {
            latchedModifierFlags = []
        }
        if hostModifierFlags.contains(.shift)
            && !updated.contains(.shift) {
            latchedModifierFlags.remove(.shift)
        }
        if hostModifierFlags.contains(.control)
            && !updated.contains(.control) {
            latchedModifierFlags.remove(.control)
        }
        if hostModifierFlags.contains(.option)
            && !updated.contains(.option) {
            latchedModifierFlags.remove(.option)
        }
        hostModifierFlags = updated
        if updated.isEmpty {
            latchedModifierFlags = []
        }
        synchronizeGuestModifiers()
    }

    func endPointerInteraction() {
        pointerModifierFlags = []
        synchronizeGuestModifiers()
    }

    func sendChord(_ chord: GuestChord) {
        synchronizeGuestModifiers(including: chord.modifiers)
        emitKey(
            keyCode: chord.keyCode,
            isDown: true,
            modifiers: chord.modifiers,
            repeats: false
        )
        emitKey(
            keyCode: chord.keyCode,
            isDown: false,
            modifiers: chord.modifiers,
            repeats: false
        )
        synchronizeGuestModifiers()
    }

    func releaseAll() {
        for chord in activeChords.values {
            emitKey(
                keyCode: chord.keyCode,
                isDown: false,
                modifiers: guestModifierFlags,
                repeats: false
            )
        }
        activeChords.removeAll()
        pointerModifierFlags = []
        hostModifierFlags = []
        latchedModifierFlags = []
        synchronizeGuestModifiers()
    }

    private func synchronizeGuestModifiers(
        including additional: NSEvent.ModifierFlags = []
    ) {
        let chordModifiers = activeChords.values.reduce(
            into: NSEvent.ModifierFlags()
        ) { result, chord in
            result.formUnion(chord.modifiers)
        }
        let target = normalized(
            chordModifiers
                .union(pointerModifierFlags)
                .union(hostModifierFlags.isEmpty ? [] : latchedModifierFlags)
                .union(additional)
        )
        let modifiers: [(NSEvent.ModifierFlags, UInt16)] = [
            (.control, 59),
            (.option, 58),
            (.shift, 56),
            (.command, 55)
        ]
        var current = guestModifierFlags
        for (flag, keyCode) in modifiers where
            current.contains(flag) && !target.contains(flag) {
            current.remove(flag)
            emitModifier(keyCode: keyCode, flags: current)
        }
        for (flag, keyCode) in modifiers where
            !current.contains(flag) && target.contains(flag) {
            current.insert(flag)
            emitModifier(keyCode: keyCode, flags: current)
        }
        guestModifierFlags = target
    }

    private func emitModifier(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags
    ) {
        keyEventHandler(
            GuestKeyEvent(
                keyCode: keyCode,
                isDown: flags.contains(
                    QEMUKeyMapper.modifierFlag(for: keyCode) ?? []
                ),
                isRepeat: false,
                modifiers: flags,
                isModifier: true
            )
        )
    }

    private func emitKey(
        keyCode: UInt16,
        isDown: Bool,
        modifiers: NSEvent.ModifierFlags,
        repeats: Bool
    ) {
        keyEventHandler(
            GuestKeyEvent(
                keyCode: keyCode,
                isDown: isDown,
                isRepeat: repeats,
                modifiers: normalized(modifiers),
                isModifier: false
            )
        )
    }

    private func normalized(
        _ flags: NSEvent.ModifierFlags
    ) -> NSEvent.ModifierFlags {
        flags.intersection([.control, .option, .shift, .command])
    }

}

extension Notification.Name {
    static let simpleVMExitImmersion = Notification.Name(
        "SimpleVMExitImmersion"
    )
}
