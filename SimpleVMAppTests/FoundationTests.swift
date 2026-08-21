import AppKit
import Darwin
import Security
import SimpleVMCore
import Virtualization
import XCTest
@testable import SimpleVM

final class FoundationTests: XCTestCase {
    func testAppBundleIdentity() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.simplevm.app")
    }

    func testAppHasVirtualizationEntitlement() throws {
        let task = try XCTUnwrap(SecTaskCreateFromSelf(nil))
        let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.security.virtualization" as CFString,
            nil
        )
        XCTAssertEqual(value as? Bool, true)
    }

    @MainActor
    func testSPICEControllerRetainsConnectionUntilDisconnect() {
        XCTAssertTrue(SPICEConnectionController.startClient())
        defer { SPICEConnectionController.stopClient() }

        let controller = SPICEConnectionController()
        weak var retainedConnection: AnyObject?
        autoreleasepool {
            let connection = controller.prepareConnection(
                to: URL(filePath: "/tmp/simplevm-audio-test.sock")
            )
            XCTAssertTrue(controller.preparedConnectionAudioEnabled)
            XCTAssertTrue(
                controller.preparedConnectionHasPasteboardDelegate
            )
            retainedConnection = connection
        }
        XCTAssertNotNil(retainedConnection)

        controller.disconnect()
        XCTAssertNil(retainedConnection)
    }

    @MainActor
    func testImmersionExitShortcutIsHostOnly() throws {
        let matching = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.control, .option, .command],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            )
        )
        let ordinaryEscape = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            )
        )

        XCTAssertTrue(ImmersionController.isExitShortcut(matching))
        XCTAssertFalse(ImmersionController.isExitShortcut(ordinaryEscape))
    }

    @MainActor
    func testQEMUKeyMapperIgnoresUnknownFlagsChangedEvents() throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .flagsChanged,
                location: .zero,
                modifierFlags: [.shift],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: 0
            )
        )

        XCTAssertNil(QEMUKeyMapper.keysym(for: event))
    }

    @MainActor
    func testMacOSProfileMapsCommandCopyToGuestControlCopy() {
        let settings = KeyboardMappingSettings.shared
        defer { settings.deactivate() }
        settings.activate(
            profile: .macOSGNOME,
            forMachineNamed: "Generic Linux"
        )
        let chord = settings.chord(
            keyCode: 8,
            modifiers: [.command]
        )

        XCTAssertEqual(chord.keyCode, 8)
        XCTAssertTrue(chord.modifiers.contains(.control))
        XCTAssertFalse(chord.modifiers.contains(.command))
    }

    @MainActor
    func testUnmappedCommandChordUsesGuestSuper() {
        let settings = KeyboardMappingSettings.shared
        defer { settings.deactivate() }
        settings.activate(
            profile: .macOSGNOME,
            forMachineNamed: "Generic Linux"
        )
        let chord = settings.chord(
            keyCode: 47,
            modifiers: [.command]
        )

        XCTAssertEqual(chord.keyCode, 47)
        XCTAssertTrue(chord.modifiers.contains(.command))
    }

    @MainActor
    func testWorkspaceSwipeChordsFollowSelectedProfile() {
        let settings = KeyboardMappingSettings.shared
        defer { settings.deactivate() }

        settings.activate(
            profile: .macOSGNOME,
            forMachineNamed: "Generic Linux"
        )
        XCTAssertEqual(
            settings.workspaceChord(direction: .previous),
            GuestChord(keyCode: 116, modifiers: [.command])
        )
        settings.activate(
            profile: .macOSHyprland,
            forMachineNamed: "Generic Linux"
        )
        XCTAssertEqual(
            settings.workspaceChord(direction: .previous),
            GuestChord(keyCode: 48, modifiers: [.command, .shift])
        )
    }

    @MainActor
    func testHyprlandWorkspaceSwipeCyclesExplicitWorkspaces() {
        let settings = KeyboardMappingSettings.shared
        let defaults = UserDefaults.standard
        let previousIndex = defaults.integer(
            forKey: "hyprlandWorkspaceIndex"
        )
        defer {
            settings.deactivate()
            defaults.set(
                previousIndex,
                forKey: "hyprlandWorkspaceIndex"
            )
        }
        settings.activate(
            profile: .automatic,
            forMachineNamed: "omarchy"
        )
        defaults.set(1, forKey: "hyprlandWorkspaceIndex")

        XCTAssertEqual(
            settings.workspaceChord(
                direction: .next,
                workspaceCount: 5
            ),
            GuestChord(keyCode: 19, modifiers: [.command])
        )
        XCTAssertEqual(
            settings.workspaceChord(
                direction: .previous,
                workspaceCount: 5
            ),
            GuestChord(keyCode: 18, modifiers: [.command])
        )
        defaults.set(5, forKey: "hyprlandWorkspaceIndex")
        XCTAssertEqual(
            settings.workspaceChord(
                direction: .next,
                workspaceCount: 5
            ),
            GuestChord(keyCode: 18, modifiers: [.command])
        )
        _ = settings.chord(keyCode: 20, modifiers: [.command])
        XCTAssertEqual(
            settings.workspaceChord(
                direction: .next,
                workspaceCount: 5
            ),
            GuestChord(keyCode: 21, modifiers: [.command])
        )
        defaults.set(1, forKey: "hyprlandWorkspaceIndex")
        settings.observeHostChord(
            keyCode: 26,
            modifiers: [.command]
        )
        XCTAssertEqual(
            settings.workspaceChord(
                direction: .next,
                workspaceCount:
                    KeyboardMappingSettings.hyprlandWorkspaceCount
            ),
            GuestChord(keyCode: 28, modifiers: [.command])
        )
    }

    @MainActor
    func testDockSwipeFiresOnSmallProgressAndVelocityFallback() throws {
        var directions: [WorkspaceSwipeDirection] = []
        let capture = ImmersiveInputCapture(
            keyEventHandler: { _ in },
            workspaceSwipeHandler: { directions.append($0) },
            usesNativeKeyboardMapping: false
        )
        let began = try XCTUnwrap(CGEvent(source: nil))
        began.setIntegerValueField(CGEventField(rawValue: 55)!, value: 30)
        began.setIntegerValueField(CGEventField(rawValue: 110)!, value: 23)
        began.setIntegerValueField(CGEventField(rawValue: 123)!, value: 1)
        began.setIntegerValueField(CGEventField(rawValue: 132)!, value: 1)
        XCTAssertEqual(capture.handleDockGesture(began), .suppress)

        let changed = try XCTUnwrap(CGEvent(source: nil))
        changed.setIntegerValueField(CGEventField(rawValue: 55)!, value: 30)
        changed.setIntegerValueField(CGEventField(rawValue: 110)!, value: 23)
        changed.setIntegerValueField(CGEventField(rawValue: 123)!, value: 1)
        changed.setIntegerValueField(CGEventField(rawValue: 132)!, value: 2)
        changed.setDoubleValueField(
            CGEventField(rawValue: 124)!,
            value: -0.001
        )
        XCTAssertEqual(capture.handleDockGesture(changed), .suppress)
        XCTAssertEqual(directions, [.previous])

        directions.removeAll()
        let secondCapture = ImmersiveInputCapture(
            keyEventHandler: { _ in },
            workspaceSwipeHandler: { directions.append($0) },
            usesNativeKeyboardMapping: false
        )
        XCTAssertEqual(secondCapture.handleDockGesture(began), .suppress)
        let ended = try XCTUnwrap(CGEvent(source: nil))
        ended.setIntegerValueField(CGEventField(rawValue: 55)!, value: 30)
        ended.setIntegerValueField(CGEventField(rawValue: 110)!, value: 23)
        ended.setIntegerValueField(CGEventField(rawValue: 123)!, value: 1)
        ended.setIntegerValueField(CGEventField(rawValue: 132)!, value: 4)
        ended.setDoubleValueField(
            CGEventField(rawValue: 129)!,
            value: 1
        )
        XCTAssertEqual(secondCapture.handleDockGesture(ended), .suppress)
        XCTAssertEqual(directions, [.next])
    }

    @MainActor
    func testNativeDockSwipeUsesHardwareBackedModifierEvents() throws {
        let capture = ImmersiveInputCapture(
            keyEventHandler: { _ in },
            workspaceSwipeHandler: { _ in },
            usesNativeKeyboardMapping: true
        )
        let began = try XCTUnwrap(CGEvent(source: nil))
        began.setIntegerValueField(CGEventField(rawValue: 55)!, value: 30)
        began.setIntegerValueField(CGEventField(rawValue: 110)!, value: 23)
        began.setIntegerValueField(CGEventField(rawValue: 123)!, value: 1)
        began.setIntegerValueField(CGEventField(rawValue: 132)!, value: 1)

        XCTAssertEqual(capture.handleDockGesture(began), .forward)
        XCTAssertEqual(began.type, .flagsChanged)
        XCTAssertEqual(
            began.getIntegerValueField(.keyboardEventKeycode),
            55
        )
        XCTAssertTrue(began.flags.contains(.maskCommand))

        let ended = try XCTUnwrap(CGEvent(source: nil))
        ended.setIntegerValueField(CGEventField(rawValue: 55)!, value: 30)
        ended.setIntegerValueField(CGEventField(rawValue: 110)!, value: 23)
        ended.setIntegerValueField(CGEventField(rawValue: 123)!, value: 1)
        ended.setIntegerValueField(CGEventField(rawValue: 132)!, value: 4)
        XCTAssertEqual(capture.handleDockGesture(ended), .forward)
        XCTAssertEqual(ended.type, .flagsChanged)
        XCTAssertFalse(ended.flags.contains(.maskCommand))
    }

    @MainActor
    func testQEMUKeyMapperUsesSuperAndMapsANSIKeys() {
        XCTAssertEqual(QEMUKeyMapper.keysym(forKeyCode: 8), 0x63)
        XCTAssertEqual(QEMUKeyMapper.modifierKeysym(for: 55), 0xffeb)
        XCTAssertEqual(
            QEMUKeyMapper.modifierKeysyms(for: [.command]),
            [0xffeb]
        )
    }

    @MainActor
    func testNavigationMappingsIgnoreSystemFunctionFlag() {
        let settings = KeyboardMappingSettings.shared
        defer { settings.deactivate() }
        settings.activate(
            profile: .macOSGNOME,
            forMachineNamed: "Generic Linux"
        )
        let chord = settings.chord(
            keyCode: 123,
            modifiers: [.command, .function]
        )

        XCTAssertEqual(chord.keyCode, 115)
        XCTAssertEqual(
            chord.modifiers.intersection(
                .deviceIndependentFlagsMask
            ),
            []
        )
    }

    @MainActor
    func testGuestInputRouterEmitsBalancedMappedChord() {
        var events: [GuestKeyEvent] = []
        let router = GuestInputRouter { events.append($0) }
        router.press(
            hostKeyCode: 8,
            chord: GuestChord(keyCode: 8, modifiers: [.control]),
            repeats: false
        )
        router.release(hostKeyCode: 8)

        XCTAssertEqual(
            events.map(\.isDown),
            [true, true, false, false]
        )
        XCTAssertEqual(events.map(\.keyCode), [59, 8, 8, 59])
        XCTAssertTrue(events[0].modifiers.contains(.control))
        XCTAssertFalse(events[3].modifiers.contains(.control))
        XCTAssertFalse(events.contains(where: { $0.keyCode == 55 }))
    }

    @MainActor
    func testPointerInteractionEmitsBalancedGuestSuper() {
        var events: [GuestKeyEvent] = []
        let router = GuestInputRouter { events.append($0) }

        router.beginPointerInteraction(modifiers: [.command])
        router.endPointerInteraction()

        XCTAssertEqual(events.map(\.isDown), [true, false])
        XCTAssertEqual(events.map(\.keyCode), [55, 55])
        XCTAssertTrue(events[0].modifiers.contains(.command))
        XCTAssertFalse(events[1].modifiers.contains(.command))
    }

    @MainActor
    func testSyntheticModifierEventsHaveCorrectDirection() {
        var events: [GuestKeyEvent] = []
        let router = GuestInputRouter { events.append($0) }
        router.beginPointerInteraction(modifiers: [.control])
        router.endPointerInteraction()

        XCTAssertTrue(events[0].isDown)
        XCTAssertFalse(events[1].isDown)
    }

    @MainActor
    func testHeldHostModifierKeepsGuestSwitcherOpen() {
        var events: [GuestKeyEvent] = []
        let router = GuestInputRouter { events.append($0) }
        router.updateHostModifiers([.command])
        router.press(
            hostKeyCode: 48,
            chord: GuestChord(keyCode: 48, modifiers: [.option]),
            repeats: false
        )
        router.release(hostKeyCode: 48)

        XCTAssertEqual(
            events.map(\.isDown),
            [true, true, false]
        )
        router.updateHostModifiers([])
        XCTAssertTrue(events.last?.isModifier ?? false)
        XCTAssertEqual(events.last?.keyCode, 58)
        XCTAssertFalse(events.last?.modifiers.contains(.option) ?? true)
    }

    @MainActor
    func testMappedDigitsCannotRemainStuckOrRepeatFromHost() {
        var events: [GuestKeyEvent] = []
        let router = GuestInputRouter { events.append($0) }
        router.updateHostModifiers([.command])
        let chord = GuestChord(keyCode: 18, modifiers: [.command])
        router.press(
            hostKeyCode: 18,
            chord: chord,
            repeats: false,
            hostModifiers: [.command]
        )
        router.press(
            hostKeyCode: 18,
            chord: chord,
            repeats: true,
            hostModifiers: [.command]
        )
        router.updateHostModifiers([])
        router.release(hostKeyCode: 18)

        XCTAssertEqual(events.map(\.keyCode), [55, 18, 18, 55])
        XCTAssertEqual(events.map(\.isDown), [true, true, false, false])
    }

    @MainActor
    func testMappedShortcutsEmitModifiersBeforeGuestKeys() {
        let settings = KeyboardMappingSettings.shared
        defer { settings.deactivate() }
        settings.activate(
            profile: .macOSGNOME,
            forMachineNamed: "Generic Linux"
        )

        for (hostKey, expectedKey, expectedModifier, modifierKey) in [
            (UInt16(12), UInt16(118), NSEvent.ModifierFlags.option, UInt16(58)),
            (UInt16(48), UInt16(48), NSEvent.ModifierFlags.option, UInt16(58))
        ] {
            var events: [GuestKeyEvent] = []
            let router = GuestInputRouter { events.append($0) }
            router.press(
                hostKeyCode: hostKey,
                chord: settings.chord(
                    keyCode: hostKey,
                    modifiers: [.command]
                ),
                repeats: false
            )
            router.release(hostKeyCode: hostKey)
            router.updateHostModifiers([])

            XCTAssertEqual(events.first?.keyCode, modifierKey)
            XCTAssertEqual(events.first?.isDown, true)
            XCTAssertEqual(events[1].keyCode, expectedKey)
            XCTAssertTrue(events[1].modifiers.contains(expectedModifier))
        }

        var swipeEvents: [GuestKeyEvent] = []
        let swipeRouter = GuestInputRouter { swipeEvents.append($0) }
        swipeRouter.sendChord(
            settings.workspaceChord(direction: .next)
        )
        XCTAssertEqual(swipeEvents.first?.keyCode, 55)
        XCTAssertEqual(swipeEvents.first?.isDown, true)
        XCTAssertEqual(swipeEvents[1].keyCode, 121)
        XCTAssertTrue(swipeEvents[1].modifiers.contains(.command))
    }

    @MainActor
    func testMappedShortcutsResolveToQEMUModifierKeysyms() {
        let settings = KeyboardMappingSettings.shared
        defer { settings.deactivate() }
        settings.activate(
            profile: .macOSGNOME,
            forMachineNamed: "Generic Linux"
        )
        var events: [GuestKeyEvent] = []
        let router = GuestInputRouter { events.append($0) }

        router.press(
            hostKeyCode: 12,
            chord: settings.chord(
                keyCode: 12,
                modifiers: [.command]
            ),
            repeats: false
        )
        router.release(hostKeyCode: 12)

        XCTAssertEqual(
            events.compactMap(QEMUKeyMapper.keysym(for:)),
            [0xffe9, 0xffc1, 0xffc1, 0xffe9]
        )
        XCTAssertEqual(QEMUKeyMapper.keysym(for: events.last!), 0xffe9)
        XCTAssertFalse(events.last!.isDown)
    }

    @MainActor
    func testOmarchyAutomaticallyUsesHyprlandMappings() {
        let settings = KeyboardMappingSettings.shared
        defer { settings.deactivate() }
        settings.activate(
            profile: .automatic,
            forMachineNamed: "omarchy-4.0.0"
        )

        XCTAssertEqual(
            settings.chord(keyCode: 12, modifiers: [.command]),
            GuestChord(keyCode: 13, modifiers: [.command])
        )
        XCTAssertEqual(
            settings.chord(keyCode: 48, modifiers: [.command]),
            GuestChord(keyCode: 48, modifiers: [.option])
        )
        XCTAssertEqual(
            settings.workspaceChord(direction: .next),
            GuestChord(keyCode: 48, modifiers: [.command])
        )
    }

    @MainActor
    func testExplicitGNOMEProfileOverridesOmarchyDetection() {
        let settings = KeyboardMappingSettings.shared
        defer { settings.deactivate() }
        settings.activate(
            profile: .macOSGNOME,
            forMachineNamed: "omarchy-4.0.0"
        )

        XCTAssertEqual(
            settings.chord(keyCode: 12, modifiers: [.command]),
            GuestChord(
                keyCode: 118,
                modifiers: [.option, .function]
            )
        )
    }

    @MainActor
    func testOmarchySystemBindingsReachHyprlandUnchanged() {
        let settings = KeyboardMappingSettings.shared
        defer { settings.deactivate() }
        settings.activate(
            profile: .macOSHyprland,
            forMachineNamed: "Generic Linux"
        )

        for (keyCode, hostModifiers, expectedModifiers) in [
            (
                UInt16(123),
                NSEvent.ModifierFlags([.command, .shift]),
                NSEvent.ModifierFlags([.command, .shift])
            ),
            (
                UInt16(3),
                NSEvent.ModifierFlags([.command, .shift]),
                NSEvent.ModifierFlags([.command, .shift])
            ),
            (
                UInt16(36),
                NSEvent.ModifierFlags([.command, .shift]),
                NSEvent.ModifierFlags([.command, .shift])
            ),
            (
                UInt16(11),
                NSEvent.ModifierFlags([.command, .shift]),
                NSEvent.ModifierFlags([.command, .shift])
            ),
            (
                UInt16(45),
                NSEvent.ModifierFlags([.command, .shift]),
                NSEvent.ModifierFlags([.command, .shift])
            ),
            (
                UInt16(18),
                NSEvent.ModifierFlags([.command, .shift, .option]),
                NSEvent.ModifierFlags([.command, .shift, .option])
            ),
            (
                UInt16(38),
                NSEvent.ModifierFlags([.command]),
                NSEvent.ModifierFlags([.command])
            )
        ] {
            XCTAssertEqual(
                settings.chord(
                    keyCode: keyCode,
                    modifiers: hostModifiers
                ),
                GuestChord(
                    keyCode: keyCode,
                    modifiers: expectedModifiers
                )
            )
        }
    }

    @MainActor
    func testQEMUKeyMapperCoversNumericKeypad() {
        let keypad: [UInt16: UInt32] = [
            65: 0xffae,
            67: 0xffaa,
            69: 0xffab,
            75: 0xffaf,
            76: 0xff8d,
            78: 0xffad,
            81: 0xffbd,
            82: 0xffb0,
            92: 0xffb9
        ]
        for (keyCode, keysym) in keypad {
            XCTAssertEqual(
                QEMUKeyMapper.keysym(forKeyCode: keyCode),
                keysym
            )
        }
    }

    @MainActor
    func testQEMURuntimePreservesMappedModifierSequence() {
        let runtime = QEMUMachineRuntime()
        var transmitted: [(UInt32, Bool)] = []
        runtime.keySink = { transmitted.append(($0, $1)) }
        let events = [
            GuestKeyEvent(
                keyCode: 58,
                isDown: true,
                isRepeat: false,
                modifiers: [.option],
                isModifier: true
            ),
            GuestKeyEvent(
                keyCode: 118,
                isDown: true,
                isRepeat: false,
                modifiers: [.option],
                isModifier: false
            ),
            GuestKeyEvent(
                keyCode: 118,
                isDown: false,
                isRepeat: false,
                modifiers: [.option],
                isModifier: false
            ),
            GuestKeyEvent(
                keyCode: 58,
                isDown: false,
                isRepeat: false,
                modifiers: [],
                isModifier: true
            )
        ]
        events.forEach(runtime.sendGuestKeyEvent)

        XCTAssertEqual(transmitted.map(\.0), [0xffe9, 0xffc1, 0xffc1, 0xffe9])
        XCTAssertEqual(transmitted.map(\.1), [true, true, false, false])
    }

    @MainActor
    func testKarabinerRuleContainsCriticalVZMappings() throws {
        let manipulators = try XCTUnwrap(
            KarabinerInputBridge.generatedRule["manipulators"]
                as? [[String: Any]]
        )
        func output(
            for key: String,
            modifiers: [String]
        ) -> [String: Any]? {
            guard let manipulator = manipulators.first(where: { manipulator in
                guard let from = manipulator["from"] as? [String: Any],
                      from["key_code"] as? String == key,
                      let fromModifiers =
                        from["modifiers"] as? [String: Any],
                      fromModifiers["mandatory"] as? [String]
                        == modifiers else {
                    return false
                }
                return true
            }), let output = manipulator["to"] as? [[String: Any]] else {
                return nil
            }
            return output.first
        }

        let quit = try XCTUnwrap(output(for: "q", modifiers: ["command"]))
        XCTAssertEqual(quit["key_code"] as? String, "f4")
        XCTAssertEqual(
            quit["modifiers"] as? [String],
            ["left_option", "fn"]
        )

        let switcher = try XCTUnwrap(
            output(for: "tab", modifiers: ["command"])
        )
        XCTAssertEqual(switcher["key_code"] as? String, "tab")
        XCTAssertEqual(
            switcher["modifiers"] as? [String],
            ["left_option"]
        )

        let bold = try XCTUnwrap(output(for: "b", modifiers: ["command"]))
        XCTAssertEqual(bold["key_code"] as? String, "b")
        XCTAssertEqual(
            bold["modifiers"] as? [String],
            ["left_control"]
        )
        XCTAssertEqual(
            manipulators.count,
            KeyboardMappingSettings.mappingEntries(for: .gnome).count
        )
        let hyprlandManipulators = try XCTUnwrap(
            KarabinerInputBridge.generatedRule(for: .hyprland)[
                "manipulators"
            ] as? [[String: Any]]
        )
        XCTAssertEqual(
            hyprlandManipulators.count,
            KeyboardMappingSettings.mappingEntries(for: .hyprland).count
        )

        let payload = KarabinerInputBridge.variablePayload(active: true)
        let payloadObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(payload.utf8)
            ) as? [String: Int]
        )
        XCTAssertEqual(
            payloadObject[KarabinerInputBridge.variableName],
            1
        )
        let inactivePayload = KarabinerInputBridge.variablePayload(
            active: false
        )
        XCTAssertEqual(
            try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(inactivePayload.utf8)
                ) as? [String: Int]
            )[KarabinerInputBridge.variableName],
            0
        )
    }

    func testSPICEKeyMapperCoversMappedChords() {
        XCTAssertEqual(PCXTKeyMapper.scancode(for: 58), 0x38)
        XCTAssertEqual(PCXTKeyMapper.scancode(for: 118), 0x3E)
        XCTAssertEqual(PCXTKeyMapper.scancode(for: 48), 0x0F)
        XCTAssertEqual(PCXTKeyMapper.scancode(for: 55), 0x15B)
        XCTAssertEqual(PCXTKeyMapper.scancode(for: 121), 0x151)
        XCTAssertEqual(PCXTKeyMapper.scancode(for: 103), 0x57)
        XCTAssertEqual(PCXTKeyMapper.scancode(for: 105), 0x64)
        XCTAssertEqual(PCXTKeyMapper.scancode(for: 107), 0x65)
        XCTAssertEqual(PCXTKeyMapper.scancode(for: 109), 0x44)
        XCTAssertEqual(PCXTKeyMapper.scancode(for: 111), 0x58)
    }

    @MainActor
    func testMacOSPointerCommandMapsToGuestControl() {
        let settings = KeyboardMappingSettings.shared
        defer { settings.deactivate() }
        settings.activate(
            profile: .macOSGNOME,
            forMachineNamed: "Generic Linux"
        )

        let modifiers = settings.pointerModifiers(from: [.command])

        XCTAssertTrue(modifiers.contains(.control))
        XCTAssertFalse(modifiers.contains(.command))
    }

    @MainActor
    func testGNOMEProfileMapsCommandQuitToAltF4() {
        let settings = KeyboardMappingSettings.shared
        defer { settings.deactivate() }
        settings.activate(
            profile: .macOSGNOME,
            forMachineNamed: "Generic Linux"
        )

        XCTAssertEqual(
            settings.chord(keyCode: 12, modifiers: [.command]),
            GuestChord(
                keyCode: 118,
                modifiers: [.option, .function]
            )
        )
    }

    @MainActor
    func testLinuxPassthroughLeavesCommandChordUnchanged() {
        let settings = KeyboardMappingSettings.shared
        defer { settings.deactivate() }
        settings.activate(
            profile: .linuxPassthrough,
            forMachineNamed: "Generic Linux"
        )

        XCTAssertEqual(
            settings.chord(
                keyCode: 12,
                modifiers: [.command, .shift]
            ),
            GuestChord(
                keyCode: 12,
                modifiers: [.command, .shift]
            )
        )
    }

    @MainActor
    func testAppleInstallerConfigurationPersistsPlatformState() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let diskURL = directory.appending(path: "disk.raw")
        let installerURL = directory.appending(path: "installer.iso")
        let backendURL = directory.appending(
            path: "Apple",
            directoryHint: .isDirectory
        )
        try SparseDiskCreator.create(
            at: diskURL,
            capacityBytes: 8 * 1_024 * 1_024
        )
        try SparseDiskCreator.create(
            at: installerURL,
            capacityBytes: 1_024 * 1_024
        )

        let imageID = UUID()
        let machine = Machine(
            name: "Installer Test",
            spec: MachineSpec(
                cpuCount: VZVirtualMachineConfiguration.minimumAllowedCPUCount,
                memorySizeBytes:
                    VZVirtualMachineConfiguration.minimumAllowedMemorySize,
                diskSizeBytes: 8 * 1_024 * 1_024,
                architecture: .arm64
            ),
            sourceImageID: imageID,
            disk: MachineDisk(
                relativePath: "Machines/test/disk.raw",
                capacityBytes: 8 * 1_024 * 1_024
            ),
            provisioningState: .readyToInstall,
            bootMedia: .installer(imageID: imageID),
            backend: .appleVirtualization,
            backendState: BackendStateReference(
                relativeDirectory: "Machines/test/Apple"
            )
        )

        let first = try AppleVirtualMachineConfigurationFactory.make(
            machine: machine,
            diskURL: diskURL,
            installerURL: installerURL,
            backendStateURL: backendURL
        )
        let identifierURL = AppleBackendStateURLs(
            directoryURL: backendURL
        ).machineIdentifierURL
        let firstIdentifier = try Data(contentsOf: identifierURL)
        let second = try AppleVirtualMachineConfigurationFactory.make(
            machine: machine,
            diskURL: diskURL,
            installerURL: installerURL,
            backendStateURL: backendURL
        )

        XCTAssertNoThrow(try first.validate())
        XCTAssertNoThrow(try second.validate())
        let graphics = try XCTUnwrap(
            first.graphicsDevices.first
                as? VZVirtioGraphicsDeviceConfiguration
        )
        let scanout = try XCTUnwrap(graphics.scanouts.first)
        XCTAssertEqual(
            scanout.widthInPixels,
            AppleVirtualMachineConfigurationFactory.defaultDisplayWidth
        )
        XCTAssertEqual(
            scanout.heightInPixels,
            AppleVirtualMachineConfigurationFactory.defaultDisplayHeight
        )
        let audioDevice = try XCTUnwrap(
            first.audioDevices.first as? VZVirtioSoundDeviceConfiguration
        )
        XCTAssertEqual(first.audioDevices.count, 1)
        XCTAssertEqual(audioDevice.streams.count, 1)
        let output = try XCTUnwrap(
            audioDevice.streams.first
                as? VZVirtioSoundDeviceOutputStreamConfiguration
        )
        XCTAssertTrue(output.sink is VZHostAudioOutputStreamSink)
        XCTAssertFalse(
            audioDevice.streams.contains {
                $0 is VZVirtioSoundDeviceInputStreamConfiguration
            }
        )
        XCTAssertEqual(try Data(contentsOf: identifierURL), firstIdentifier)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: AppleBackendStateURLs(
                    directoryURL: backendURL
                ).variableStoreURL.path
            )
        )
    }

    @MainActor
    func testCreatesPersistentMachineFromManagedISO() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let sourceURL = rootURL.appending(path: "source.iso")
        try Data("EFI/BOOT/BOOTAA64.EFI".utf8).write(to: sourceURL)

        let model = AppModel(
            storageRootURL: rootURL.appending(
                path: "Library",
                directoryHint: .isDirectory
            )
        )
        await model.initialize()
        let imageID = try await model.library.importISO(
            from: sourceURL,
            architecture: .arm64
        )
        let machineID = try await model.createMachine(
            name: "Generic Linux",
            cpuCount: VZVirtualMachineConfiguration.minimumAllowedCPUCount,
            memorySizeBytes:
                VZVirtualMachineConfiguration.minimumAllowedMemorySize,
            diskSizeBytes: 1_024 * 1_024,
            source: .managedImage(imageID),
            sharedDirectoryPath: nil
        )

        let machine = try XCTUnwrap(
            model.machines.first(where: { $0.id == machineID })
        )
        XCTAssertEqual(machine.provisioningState, .readyToInstall)
        XCTAssertEqual(machine.bootMedia, .installer(imageID: imageID))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: try XCTUnwrap(model.storageURL)
                    .appending(path: machine.disk.relativePath).path
            )
        )
    }

    @MainActor
    func testReconcilesInterruptedImageAndMachineProvisioning() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let image = MachineImage(
            name: "Interrupted",
            architecture: .arm64,
            artifactKind: .installerISO,
            origin: .remoteURL(URL(string: "https://example.test/image.iso")!),
            availability: .downloading(progress: 0.5)
        )
        let machine = Machine(
            name: "Interrupted",
            spec: MachineSpec(
                cpuCount: 2,
                memorySizeBytes: 2 * 1_024 * 1_024 * 1_024,
                diskSizeBytes: 16 * 1_024 * 1_024 * 1_024,
                architecture: .arm64
            ),
            sourceImageID: image.id,
            disk: MachineDisk(
                relativePath: "Machines/test/disk.raw",
                capacityBytes: 16 * 1_024 * 1_024 * 1_024
            ),
            provisioningState: .verifying,
            bootMedia: .installer(imageID: image.id),
            backend: .appleVirtualization,
            backendState: BackendStateReference(
                relativeDirectory: "Machines/test/Apple"
            )
        )
        let store = LibraryStore(layout: StorageLayout(rootURL: rootURL))
        try await store.save(
            LibrarySnapshot(machines: [machine], images: [image])
        )

        let model = AppModel(storageRootURL: rootURL)
        await model.initialize()

        guard case .failed = try XCTUnwrap(model.library.images.first).availability else {
            XCTFail("Interrupted image was not marked failed.")
            return
        }
        guard case .failed = try XCTUnwrap(model.machines.first)
            .provisioningState else {
            XCTFail("Interrupted machine was not reconciled.")
            return
        }
    }

    @MainActor
    func testFailedInitializationDoesNotPublishOrOverwriteStores() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        let layout = StorageLayout(rootURL: rootURL)
        try layout.initialize()
        defer {
            chmod(layout.imagesURL.path, 0o700)
            try? FileManager.default.removeItem(at: rootURL)
        }

        let image = MachineImage(
            name: "Preserved",
            architecture: .arm64,
            artifactKind: .installerISO,
            origin: .localImport(originalFileName: "preserved.iso"),
            availability: .available(
                relativePath: "Images/preserved/artifact.iso"
            )
        )
        let machine = Machine(
            name: "Preserved",
            spec: MachineSpec(
                cpuCount: 2,
                memorySizeBytes: 2 * 1_024 * 1_024 * 1_024,
                diskSizeBytes: 8 * 1_024 * 1_024 * 1_024,
                architecture: .arm64
            ),
            sourceImageID: image.id,
            disk: MachineDisk(
                relativePath: "Machines/preserved/disk.raw",
                capacityBytes: 8 * 1_024 * 1_024 * 1_024
            ),
            provisioningState: .ready,
            bootMedia: .systemDisk,
            backend: .appleVirtualization,
            backendState: BackendStateReference(
                relativeDirectory: "Machines/preserved/Apple"
            )
        )
        let snapshot = LibrarySnapshot(
            machines: [machine],
            images: [image]
        )
        let store = LibraryStore(layout: layout)
        try await store.save(snapshot)
        let persistedSnapshot = try await store.load()
        XCTAssertEqual(chmod(layout.imagesURL.path, 0), 0)

        let model = AppModel(storageRootURL: rootURL)
        await model.initialize()

        XCTAssertNil(model.storageURL)
        XCTAssertTrue(model.machines.isEmpty)
        XCTAssertTrue(model.library.images.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        let unchangedSnapshot = try await store.load()
        XCTAssertEqual(unchangedSnapshot, persistedSnapshot)

        XCTAssertEqual(chmod(layout.imagesURL.path, 0o700), 0)
        await model.initialize()

        XCTAssertEqual(model.machines.map(\.id), [machine.id])
        XCTAssertEqual(model.library.images.map(\.id), [image.id])
        let restoredSnapshot = try await store.load()
        XCTAssertEqual(restoredSnapshot, persistedSnapshot)
    }

    @MainActor
    func testPersistsInputProfileAcrossCreationEditingAndCloning() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let sourceURL = rootURL.appending(path: "base.raw")
        try SparseDiskCreator.create(
            at: sourceURL,
            capacityBytes: 1 * 1_024 * 1_024
        )
        let libraryURL = rootURL.appending(path: "Library")
        let model = AppModel(storageRootURL: libraryURL)
        await model.initialize()
        let imageID = try await model.library.importImage(
            from: sourceURL,
            architecture: .arm64,
            artifactKind: .preinstalledDisk
        )
        let machineID = try await model.createMachine(
            name: "Curated",
            cpuCount: 2,
            memorySizeBytes: 2 * 1_024 * 1_024 * 1_024,
            diskSizeBytes: 2 * 1_024 * 1_024,
            source: .managedImage(imageID),
            sharedDirectoryPath: nil,
            inputProfile: .macOSHyprland
        )
        let machine = try XCTUnwrap(
            model.machines.first(where: { $0.id == machineID })
        )

        XCTAssertEqual(machine.bootMedia, .systemDisk)
        XCTAssertEqual(machine.provisioningState, .ready)
        XCTAssertEqual(machine.disk.capacityBytes, 2 * 1_024 * 1_024)
        XCTAssertEqual(machine.spec.inputProfile, .macOSHyprland)

        await model.setInputProfile(.linuxPassthrough, for: machine)
        let updatedMachine = try XCTUnwrap(
            model.machines.first(where: { $0.id == machineID })
        )
        await model.cloneMachine(updatedMachine)

        XCTAssertEqual(model.machines.count, 2)
        XCTAssertTrue(
            model.machines.allSatisfy {
                $0.spec.inputProfile == .linuxPassthrough
            }
        )

        let reloadedModel = AppModel(storageRootURL: libraryURL)
        await reloadedModel.initialize()
        XCTAssertEqual(reloadedModel.machines.count, 2)
        XCTAssertTrue(
            reloadedModel.machines.allSatisfy {
                $0.spec.inputProfile == .linuxPassthrough
            }
        )
    }

    @MainActor
    func testExportsManagedImageAndStoppedMachineDisk() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let sourceURL = rootURL.appending(path: "portable.raw")
        try SparseDiskCreator.create(
            at: sourceURL,
            capacityBytes: 1 * 1_024 * 1_024
        )
        let model = AppModel(
            storageRootURL: rootURL.appending(path: "Library")
        )
        await model.initialize()
        let imageID = try await model.library.importImage(
            from: sourceURL,
            architecture: .arm64,
            artifactKind: .preinstalledDisk
        )
        let image = try XCTUnwrap(
            model.library.images.first(where: { $0.id == imageID })
        )
        let imageExportURL = rootURL.appending(path: "image-export.raw")
        try await model.library.exportImage(image, to: imageExportURL)
        XCTAssertEqual(
            try FileSHA256.digest(of: imageExportURL),
            image.sha256
        )

        let machineID = try await model.createMachine(
            name: "Portable",
            cpuCount: 2,
            memorySizeBytes: 2 * 1_024 * 1_024 * 1_024,
            diskSizeBytes: 2 * 1_024 * 1_024,
            source: .managedImage(imageID),
            sharedDirectoryPath: nil
        )
        let machine = try XCTUnwrap(
            model.machines.first(where: { $0.id == machineID })
        )
        let diskExportURL = rootURL.appending(path: "machine-export.raw")
        try await model.exportMachineDisk(
            machine,
            to: diskExportURL
        )
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(
                atPath: diskExportURL.path
            )[.size] as? NSNumber,
            NSNumber(value: machine.disk.capacityBytes)
        )

        var runningMachine = machine
        runningMachine.runtimeState = .running
        do {
            try await model.exportMachineDisk(
                runningMachine,
                to: rootURL.appending(path: "running.raw")
            )
            XCTFail("Expected a running machine export to fail.")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Stop the machine before performing this action."
            )
        }
    }

    @MainActor
    func testGuestToolsDetectionResolvesOnlyAutomaticProfile() async throws {
        let coordinator = GuestToolsCoordinator()
        let unmounted = guestToolsStatus(
            mountState: .unmounted,
            capabilities: [.mountSharedDirectory, .displayResize]
        )
        let mounted = guestToolsStatus(
            mountState: .mounted,
            capabilities: [.mountSharedDirectory, .displayResize]
        )
        var statusRequests = 0
        var mountRequests = 0
        coordinator.start(sharedDirectoryConfigured: true) { request in
            switch request {
            case .status:
                statusRequests += 1
                return .status(statusRequests == 1 ? unmounted : mounted)
            case .mountSharedDirectory:
                mountRequests += 1
                return .accepted
            default:
                return .failure(
                    GuestAgentFailure(
                        code: "unexpected",
                        message: "Unexpected test request."
                    )
                )
            }
        }
        for _ in 0..<100 where coordinator.state.status == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(mountRequests, 1)
        XCTAssertEqual(coordinator.state.status?.sharedMountStatus.state, .mounted)
        XCTAssertEqual(
            coordinator.resolvedInputProfile(
                configuredProfile: .automatic,
                machineName: "Generic Linux"
            ),
            .macOSHyprland
        )
        XCTAssertEqual(
            coordinator.resolvedInputProfile(
                configuredProfile: .macOSGNOME,
                machineName: "Omarchy"
            ),
            .macOSGNOME
        )
        coordinator.stop()
    }

    @MainActor
    func testGuestToolsMountFailurePreservesConnection() async throws {
        let coordinator = GuestToolsCoordinator()
        let status = guestToolsStatus(
            mountState: .unmounted,
            capabilities: [.mountSharedDirectory, .gracefulShutdown]
        )
        coordinator.start(sharedDirectoryConfigured: true) { request in
            switch request {
            case .status:
                return .status(status)
            case .mountSharedDirectory:
                return .failure(
                    GuestAgentFailure(
                        code: "mountFailed",
                        message: "fixed mount point is occupied"
                    )
                )
            default:
                return .failure(
                    GuestAgentFailure(
                        code: "unexpected",
                        message: "Unexpected test request."
                    )
                )
            }
        }
        for _ in 0..<100 where coordinator.state.status == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(coordinator.state.status, status)
        XCTAssertTrue(coordinator.supports(.gracefulShutdown))
        XCTAssertTrue(
            coordinator.notice?.contains("could not be mounted") == true
        )
        coordinator.stop()
    }

    @MainActor
    func testGuestToolsMountTimeoutPreservesConnection() async throws {
        let coordinator = GuestToolsCoordinator()
        let status = guestToolsStatus(
            mountState: .unmounted,
            capabilities: [.mountSharedDirectory, .gracefulReboot]
        )
        coordinator.start(sharedDirectoryConfigured: true) { request in
            switch request {
            case .status:
                return .status(status)
            case .mountSharedDirectory:
                throw GuestAgentTransportError.timedOut
            default:
                return .failure(
                    GuestAgentFailure(
                        code: "unexpected",
                        message: "Unexpected test request."
                    )
                )
            }
        }
        for _ in 0..<100 where coordinator.state.status == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(coordinator.state.status, status)
        XCTAssertTrue(coordinator.supports(.gracefulReboot))
        XCTAssertTrue(
            coordinator.notice?.contains("could not be mounted") == true
        )
        coordinator.stop()
    }

    func testClipboardLoopGuardSuppressesEchoes() {
        var guardState = ClipboardLoopGuard()
        XCTAssertTrue(guardState.canSendToGuest("host"))
        guardState.markSentToGuest("host")
        XCTAssertFalse(guardState.shouldApplyFromGuest("host"))
        XCTAssertTrue(guardState.shouldApplyFromGuest("guest"))
        XCTAssertFalse(guardState.shouldAnnounceHostChange("guest"))
        XCTAssertTrue(guardState.shouldAnnounceHostChange("new host"))
        guardState.markSentToGuest("guest")
        XCTAssertFalse(guardState.canSendToGuest("guest"))
        XCTAssertFalse(guardState.shouldApplyFromGuest("guest"))
    }

    func testClipboardLoopGuardAllowsGuestTextAfterDistinctHostWrite() {
        var guardState = ClipboardLoopGuard()
        XCTAssertTrue(guardState.shouldApplyFromGuest("guest"))
        XCTAssertTrue(guardState.canSendToGuest("host"))
        guardState.markSentToGuest("host")
        XCTAssertTrue(guardState.shouldApplyFromGuest("guest"))
    }

    func testAgentClipboardRoutingRequiresBothWaylandCapabilities() {
        let partial = guestToolsStatus(
            capabilities: [.clipboardRead],
            sessionType: .wayland
        )
        let complete = guestToolsStatus(
            capabilities: [.clipboardRead, .clipboardWrite],
            sessionType: .wayland
        )
        let x11 = guestToolsStatus(
            capabilities: [.clipboardRead, .clipboardWrite],
            sessionType: .x11
        )

        XCTAssertFalse(partial.supportsAgentClipboardTransport)
        XCTAssertTrue(complete.supportsAgentClipboardTransport)
        XCTAssertFalse(x11.supportsAgentClipboardTransport)
    }

    func testGuestToolsBundleExportsAndAtomicallyReplacesArchive() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appending(
            path: "GuestTools",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: sourceURL,
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(
            to: sourceURL.appending(path: "install.sh")
        )
        let shareURL = directory.appending(
            path: "share",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: shareURL,
            withIntermediateDirectories: true
        )
        let exporter = GuestToolsBundleExporter(sourceURL: sourceURL)

        let archiveURL = try exporter.copyToSharedDirectory(shareURL)
        let firstArchive = try Data(contentsOf: archiveURL)
        XCTAssertFalse(firstArchive.isEmpty)
        try Data("#!/bin/sh\necho updated\n".utf8).write(
            to: sourceURL.appending(path: "install.sh")
        )
        XCTAssertEqual(
            try exporter.copyToSharedDirectory(shareURL),
            archiveURL
        )
        let updatedArchive = try Data(contentsOf: archiveURL)
        XCTAssertNotEqual(updatedArchive, firstArchive)
        XCTAssertEqual(
            try exporter.copyToSharedDirectory(shareURL),
            archiveURL
        )
        XCTAssertEqual(try Data(contentsOf: archiveURL), updatedArchive)

        let list = Process()
        list.executableURL = URL(filePath: "/usr/bin/tar")
        list.arguments = ["-tzf", archiveURL.path]
        let output = Pipe()
        list.standardOutput = output
        try list.run()
        list.waitUntilExit()
        XCTAssertEqual(list.terminationStatus, 0)
        let contents = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )
        XCTAssertTrue(contents?.contains("GuestTools/install.sh") == true)
        XCTAssertTrue(
            GuestToolsBundleExporter.sharedInstallCommand(
                backend: .appleVirtualization
            ).contains("mount -t virtiofs")
        )
        XCTAssertTrue(
            GuestToolsBundleExporter.sharedInstallCommand(
                backend: .qemu
            ).contains("mount -t 9p")
        )
        for backend in [
            VirtualizationBackendKind.appleVirtualization,
            .qemu
        ] {
            let command =
                GuestToolsBundleExporter.sharedInstallCommand(
                    backend: backend
                )
            XCTAssertTrue(
                command.contains(
                    "-C \"$HOME/simplevm-guest-tools\""
                )
            )
            XCTAssertFalse(
                command.contains(
                    "cd /mnt/simplevm-share && tar"
                )
            )
        }
    }

    @MainActor
    func testQEMUMachineCanConfigureAndReceiveGuestToolsShare() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let sourceURL = rootURL.appending(path: "base.raw")
        try SparseDiskCreator.create(
            at: sourceURL,
            capacityBytes: 1 * 1_024 * 1_024
        )
        let shareURL = rootURL.appending(
            path: "QEMU Share",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: shareURL,
            withIntermediateDirectories: true
        )
        let model = AppModel(
            storageRootURL: rootURL.appending(path: "Library")
        )
        await model.initialize()
        let imageID = try await model.library.importImage(
            from: sourceURL,
            architecture: .x86_64,
            artifactKind: .preinstalledDisk
        )
        let machineID = try await model.createMachine(
            name: "QEMU Share",
            cpuCount: 2,
            memorySizeBytes: 2 * 1_024 * 1_024 * 1_024,
            diskSizeBytes: 2 * 1_024 * 1_024,
            source: .managedImage(imageID),
            sharedDirectoryPath: nil
        )
        let machine = try XCTUnwrap(
            model.machines.first(where: { $0.id == machineID })
        )

        await model.setSharedDirectory(shareURL.path, for: machine)
        let updatedMachine = try XCTUnwrap(
            model.machines.first(where: { $0.id == machineID })
        )
        XCTAssertEqual(
            updatedMachine.spec.sharedDirectoryPath,
            shareURL.path
        )
        let archiveURL = try await model.copyGuestToolsToSharedDirectory(
            for: updatedMachine
        )
        XCTAssertEqual(
            archiveURL,
            shareURL.appending(
                path: GuestToolsBundleExporter.archiveName
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: archiveURL.path)
        )

        await model.setSharedDirectory(nil, for: updatedMachine)
        XCTAssertNil(
            model.machines.first(where: { $0.id == machineID })?
                .spec.sharedDirectoryPath
        )
    }

    func testGuestAgentSocketTransportRoundTripAndTimeout() async throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(
            socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors),
            0
        )
        let client = descriptors[0]
        let server = descriptors[1]
        let status = guestToolsStatus(
            mountState: .mounted,
            capabilities: [.gracefulShutdown]
        )
        let serverTask = Task.detached {
            defer { Darwin.close(server) }
            let handle = FileHandle(
                fileDescriptor: server,
                closeOnDealloc: false
            )
            let header = try handle.read(upToCount: 4) ?? Data()
            let length = header.reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            let payload = try handle.read(upToCount: Int(length)) ?? Data()
            var requestFrame = header
            requestFrame.append(payload)
            let request = try GuestAgentFrameCodec.decode(
                GuestAgentRequestEnvelope.self,
                from: requestFrame
            )
            let response = try GuestAgentFrameCodec.encode(
                GuestAgentResponseEnvelope(
                    requestID: request.requestID,
                    response: .status(status)
                )
            )
            try handle.write(contentsOf: response.prefix(2))
            try handle.write(contentsOf: response.dropFirst(2))
        }
        let response = try await GuestAgentSocketTransport.request(
            .status,
            timeout: 1
        ) {
            client
        }
        guard case .status(let received) = response else {
            XCTFail("Expected status response.")
            return
        }
        XCTAssertEqual(received.hostname, "guest")
        _ = try await serverTask.value

        var timeoutDescriptors: [Int32] = [0, 0]
        XCTAssertEqual(
            socketpair(AF_UNIX, SOCK_STREAM, 0, &timeoutDescriptors),
            0
        )
        let timeoutClient = timeoutDescriptors[0]
        let timeoutServer = timeoutDescriptors[1]
        defer { Darwin.close(timeoutServer) }
        do {
            _ = try await GuestAgentSocketTransport.request(
                .status,
                timeout: 0.05
            ) {
                timeoutClient
            }
            XCTFail("Expected a timeout.")
        } catch GuestAgentTransportError.timedOut {
            // Expected.
        }
    }

    func testGuestAgentSocketTransportRejectsMismatchedIDs() async throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        let client = descriptors[0]
        let server = descriptors[1]
        let serverTask = Task.detached {
            defer { Darwin.close(server) }
            let handle = FileHandle(
                fileDescriptor: server,
                closeOnDealloc: false
            )
            let header = try handle.read(upToCount: 4) ?? Data()
            let length = header.reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            _ = try handle.read(upToCount: Int(length))
            let response = try GuestAgentFrameCodec.encode(
                GuestAgentResponseEnvelope(
                    requestID: "not-the-request-id",
                    response: .accepted
                )
            )
            try handle.write(contentsOf: response)
        }

        do {
            _ = try await GuestAgentSocketTransport.request(
                .status,
                timeout: 1
            ) {
                client
            }
            XCTFail("Expected a mismatched request ID.")
        } catch GuestAgentProtocolError.mismatchedRequestID {
            // Expected.
        }
        _ = try await serverTask.value
    }

    func testGuestAgentSocketTransportCancelsPendingRead() async throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        let client = descriptors[0]
        let server = descriptors[1]
        defer { Darwin.close(server) }
        let requestTask = Task {
            try await GuestAgentSocketTransport.request(
                .status,
                timeout: 10
            ) {
                client
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        requestTask.cancel()
        do {
            _ = try await requestTask.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected.
        }
    }

    @MainActor
    func testRealARM64EFIISOStaysRunningWithDisplayAttached() async throws {
        guard let fixturePath = fixturePath(
            environmentKey: "SIMPLEVM_ARM64_ISO_FIXTURE"
        ) else {
            throw XCTSkip("Set SIMPLEVM_ARM64_ISO_FIXTURE for the hardware smoke test.")
        }

        let fixtureURL = URL(filePath: fixturePath)
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            XCTFail("The ARM64 ISO fixture does not exist.")
            return
        }

        let directory = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let diskURL = directory.appending(path: "disk.raw")
        let backendURL = directory.appending(path: "Apple")
        try SparseDiskCreator.create(
            at: diskURL,
            capacityBytes: 1 * 1_024 * 1_024 * 1_024
        )

        let imageID = UUID()
        let machine = Machine(
            name: "EFI Smoke Test",
            spec: MachineSpec(
                cpuCount: max(
                    2,
                    VZVirtualMachineConfiguration.minimumAllowedCPUCount
                ),
                memorySizeBytes: max(
                    2 * 1_024 * 1_024 * 1_024,
                    VZVirtualMachineConfiguration.minimumAllowedMemorySize
                ),
                diskSizeBytes: 1 * 1_024 * 1_024 * 1_024,
                architecture: .arm64
            ),
            sourceImageID: imageID,
            disk: MachineDisk(
                relativePath: "disk.raw",
                capacityBytes: 1 * 1_024 * 1_024 * 1_024
            ),
            provisioningState: .readyToInstall,
            bootMedia: .installer(imageID: imageID),
            backend: .appleVirtualization,
            backendState: BackendStateReference(relativeDirectory: "Apple")
        )
        let configuration = try AppleVirtualMachineConfigurationFactory.make(
            machine: machine,
            diskURL: diskURL,
            installerURL: fixtureURL,
            backendStateURL: backendURL
        )
        let virtualMachine = VZVirtualMachine(configuration: configuration)
        let display = VZVirtualMachineView(
            frame: NSRect(x: 0, y: 0, width: 1_024, height: 640)
        )
        display.virtualMachine = virtualMachine
        let window = NSWindow(
            contentRect: display.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentView = display
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }

        try await virtualMachine.start()
        defer {
            Task { @MainActor in
                if virtualMachine.state == .running {
                    try? await virtualMachine.stop()
                }
            }
        }
        try await Task.sleep(for: .seconds(45))

        XCTAssertEqual(virtualMachine.state, .running)
        XCTAssertTrue(display.virtualMachine === virtualMachine)

        try await virtualMachine.stop()
    }

    @MainActor
    func testRealRootFSBootsThroughDirectKernel() async throws {
        guard let diskPath = fixturePath(
            environmentKey: "SIMPLEVM_ROOTFS_DISK_FIXTURE"
        ), let kernelPath = fixturePath(
            environmentKey: "SIMPLEVM_ROOTFS_KERNEL_FIXTURE"
        ), let initrdPath = fixturePath(
            environmentKey: "SIMPLEVM_ROOTFS_INITRD_FIXTURE"
        ) else {
            throw XCTSkip("Configure rootfs, kernel, and initrd fixtures.")
        }

        let directory = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let diskURL = directory.appending(path: "rootfs.ext4")
        try APFSCloneStorage.clone(
            from: URL(filePath: diskPath),
            to: diskURL
        )
        let backendURL = directory.appending(path: "Apple")
        try AppleLinuxBootAssets.install(
            kernelURL: URL(filePath: kernelPath),
            initialRamdiskURL: URL(filePath: initrdPath),
            commandLine: "console=hvc0 root=/dev/vda rw init=/bin/sh",
            backendStateURL: backendURL
        )
        let logURL = directory.appending(path: "console.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        defer { try? logHandle.close() }

        let machine = Machine(
            name: "RootFS Test",
            spec: MachineSpec(
                cpuCount: 2,
                memorySizeBytes: 2 * 1_024 * 1_024 * 1_024,
                diskSizeBytes: 384 * 1_024 * 1_024,
                architecture: .arm64
            ),
            sourceImageID: UUID(),
            disk: MachineDisk(
                relativePath: "rootfs.ext4",
                capacityBytes: 384 * 1_024 * 1_024
            ),
            provisioningState: .ready,
            bootMedia: .systemDisk,
            backend: .appleVirtualization,
            backendState: BackendStateReference(relativeDirectory: "Apple")
        )
        let configuration = try AppleVirtualMachineConfigurationFactory.make(
            machine: machine,
            diskURL: diskURL,
            installerURL: nil,
            backendStateURL: backendURL,
            serialOutput: logHandle
        )
        let virtualMachine = VZVirtualMachine(configuration: configuration)
        try await virtualMachine.start()
        try await Task.sleep(for: .seconds(20))
        XCTAssertEqual(virtualMachine.state, .running)
        try await virtualMachine.stop()
        try logHandle.synchronize()

        let console = String(
            data: try Data(contentsOf: logURL),
            encoding: .utf8
        ) ?? ""
        XCTAssertTrue(
            console.contains("Linux version") || console.contains("Alpine"),
            "Expected Linux boot output, received: \(console.suffix(500))"
        )
    }

    private func fixturePath(environmentKey: String) -> String? {
        guard let path = ProcessInfo.processInfo.environment[environmentKey],
              !path.isEmpty else {
            return nil
        }
        return path
    }

    private func guestToolsStatus(
        mountState: GuestSharedMountState = .unmounted,
        capabilities: Set<GuestAgentCapability>,
        sessionType: GuestSessionType = .wayland
    ) -> GuestAgentStatus {
        GuestAgentStatus(
            protocolVersion: GuestAgentProtocol.currentVersion,
            agentVersion: "2.0.0",
            hostname: "guest",
            ipAddresses: [],
            operatingSystem: "Linux",
            distroID: "arch",
            distroVersion: "rolling",
            desktopEnvironment: .hyprland,
            sessionType: sessionType,
            capabilities: capabilities,
            sharedMountStatus: GuestSharedMountStatus(state: mountState)
        )
    }

}
