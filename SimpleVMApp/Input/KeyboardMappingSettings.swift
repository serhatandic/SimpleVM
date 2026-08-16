import AppKit
import Observation

enum KeyboardPreset: String, CaseIterable, Identifiable {
    case macOS = "macOS-style Linux"
    case hyprland = "macOS-style Hyprland"
    case passthrough = "Linux passthrough"

    var id: Self { self }
}

struct GuestChord: Equatable {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
}

struct GuestKeyEvent: Equatable {
    let keyCode: UInt16
    let isDown: Bool
    let isRepeat: Bool
    let modifiers: NSEvent.ModifierFlags
    let isModifier: Bool
}

enum GuestInputEventMarker {
    static let value: Int64 = 0x53494D504C45564D
}

private struct HostChord: Hashable {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers.rawValue)
    }
}

@MainActor
@Observable
final class KeyboardMappingSettings {
    static let shared = KeyboardMappingSettings()

    var preset: KeyboardPreset {
        didSet {
            UserDefaults.standard.set(preset.rawValue, forKey: "keyboardPreset")
        }
    }

    @ObservationIgnored
    private var activeMachinePreset: KeyboardPreset?

    init() {
        preset = KeyboardPreset(
            rawValue: UserDefaults.standard.string(
                forKey: "keyboardPreset"
            ) ?? ""
        ) ?? .macOS
    }

    func chord(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> GuestChord {
        let normalized = modifiers.intersection([
            .command,
            .option,
            .control,
            .shift
        ])
        guard effectivePreset != .passthrough else {
            return GuestChord(keyCode: keyCode, modifiers: normalized)
        }
        return mappings[
            HostChord(keyCode: keyCode, modifiers: normalized)
        ] ?? GuestChord(keyCode: keyCode, modifiers: normalized)
    }

    func workspaceChord(direction: WorkspaceSwipeDirection) -> GuestChord {
        switch effectivePreset {
        case .hyprland:
            return GuestChord(
                keyCode: direction == .next ? 48 : 48,
                modifiers: direction == .next
                    ? [.command]
                    : [.command, .shift]
            )
        case .macOS, .passthrough:
            return GuestChord(
                keyCode: direction == .next ? 121 : 116,
                modifiers: [.command]
            )
        }

    }

    func pointerModifiers(
        from modifiers: NSEvent.ModifierFlags
    ) -> NSEvent.ModifierFlags {
        var result = modifiers.intersection([
            .command,
            .option,
            .control,
            .shift
        ])
        if effectivePreset == .macOS, result.contains(.command) {
            result.remove(.command)
            result.insert(.control)
        }
        return result
    }

    var mappingDescriptions: [(host: String, guest: String)] {
        switch effectivePreset {
        case .passthrough:
            [("Command", "Super"), ("Option", "Alt"), ("Control", "Control")]
        case .macOS:
            Self.sharedDescriptions + [
                ("⌘W", "Ctrl+W"),
                ("⌘Q", "Alt+F4"),
                ("⌘Tab", "Alt+Tab"),
                ("⌃⌘F", "F11")
            ]
        case .hyprland:
            Self.sharedDescriptions + [
                ("⌘W / ⌘Q", "Super+Q"),
                ("⌘Space", "Super+Space"),
                ("⌘Tab", "Super+Tab"),
                ("⇧⌘Tab", "Super+Shift+Tab"),
                ("⌃⌘F", "Super+F"),
                ("⌘1…9", "Super+1…9")
            ]
        }
    }

    private var mappings: [HostChord: GuestChord] {
        var result: [HostChord: GuestChord] = [:]
        func add(
            _ keyCode: UInt16,
            _ host: NSEvent.ModifierFlags,
            _ guest: NSEvent.ModifierFlags,
            guestKeyCode: UInt16? = nil
        ) {
            result[HostChord(keyCode: keyCode, modifiers: host)] = GuestChord(
                keyCode: guestKeyCode ?? keyCode,
                modifiers: guest
            )
        }

        for keyCode in [8, 7, 9, 0, 6, 1, 35, 31, 3, 5, 45, 17, 11, 34, 32,
                        15, 37, 40, 2] {
            add(UInt16(keyCode), [.command], [.control])
        }
        add(6, [.command, .shift], [.control, .shift])
        add(3, [.command, .shift], [.control, .shift])
        add(15, [.command, .shift], [.control, .shift])
        add(24, [.command], [.control])
        add(27, [.command], [.control])
        add(29, [.command], [.control])
        add(123, [.command], [], guestKeyCode: 115)
        add(124, [.command], [], guestKeyCode: 119)
        add(126, [.command], [.control], guestKeyCode: 115)
        add(125, [.command], [.control], guestKeyCode: 119)
        add(123, [.command, .shift], [.shift], guestKeyCode: 115)
        add(124, [.command, .shift], [.shift], guestKeyCode: 119)
        add(123, [.option], [.control], guestKeyCode: 123)
        add(124, [.option], [.control], guestKeyCode: 124)
        add(51, [.option], [.control])
        add(117, [.option], [.control])

        switch effectivePreset {
        case .macOS:
            add(13, [.command], [.control])
            add(12, [.command], [.option], guestKeyCode: 118)
            add(48, [.command], [.option])
            add(3, [.command, .control], [], guestKeyCode: 103)
        case .hyprland:
            add(13, [.command], [.command], guestKeyCode: 12)
            add(12, [.command], [.command])
            add(49, [.command], [.command])
            add(48, [.command], [.command])
            add(48, [.command, .shift], [.command, .shift])
            add(3, [.command, .control], [.command])
            for keyCode in (18...29) where ![24, 27, 29].contains(keyCode) {
                add(UInt16(keyCode), [.command], [.command])
                add(UInt16(keyCode), [.command, .shift], [.command, .shift])
            }
        case .passthrough:
            break
        }
        return result
    }

    func activatePreset(forMachineNamed name: String) {
        let normalized = name.lowercased()
        activeMachinePreset =
            normalized.contains("omarchy")
            || normalized.contains("hyprland")
            ? .hyprland
            : preset
    }

    func deactivateMachinePreset() {
        activeMachinePreset = nil
    }

    private var effectivePreset: KeyboardPreset {
        activeMachinePreset ?? preset
    }

    private static let sharedDescriptions = [
        ("⌘C / X / V", "Ctrl+C / X / V"),
        ("⌘Z / ⇧⌘Z", "Ctrl+Z / Ctrl+Shift+Z"),
        ("⌘A / S / P / O", "Ctrl+A / S / P / O"),
        ("⌘F / G / R / L", "Ctrl+F / G / R / L"),
        ("⌘N / T", "Ctrl+N / T"),
        ("⌘+ / − / 0", "Ctrl++ / − / 0"),
        ("⌘← / →", "Home / End"),
        ("⌘↑ / ↓", "Ctrl+Home / End"),
        ("⌥← / →", "Ctrl+← / →"),
        ("⌥⌫ / ⌥⌦", "Ctrl+Backspace / Delete")
    ]
}

enum WorkspaceSwipeDirection {
    case previous
    case next
}
