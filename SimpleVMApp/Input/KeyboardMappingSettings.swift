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

struct HostChord: Hashable {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers.rawValue)
    }
}

struct KeyboardMappingEntry: Equatable {
    let host: HostChord
    let guest: GuestChord
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
        let resolved = mappings[
            HostChord(keyCode: keyCode, modifiers: normalized)
        ] ?? GuestChord(keyCode: keyCode, modifiers: normalized)
        synchronizeHyprlandWorkspace(with: resolved)
        return resolved
    }

    func observeHostChord(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) {
        guard effectivePreset == .hyprland,
              modifiers.intersection([
                .command,
                .option,
                .control,
                .shift
              ]) == .command,
              let index = Self.hyprlandWorkspaceKeyCodes.firstIndex(
                of: keyCode
              ) else {
            return
        }
        UserDefaults.standard.set(
            index + 1,
            forKey: "hyprlandWorkspaceIndex"
        )
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

    func workspaceChord(
        direction: WorkspaceSwipeDirection,
        workspaceCount: Int
    ) -> GuestChord {
        guard effectivePreset == .hyprland else {
            return workspaceChord(direction: direction)
        }
        let count = min(
            max(workspaceCount, 2),
            Self.hyprlandWorkspaceCount
        )
        let defaults = UserDefaults.standard
        let key = "hyprlandWorkspaceIndex"
        var index = defaults.integer(forKey: key)
        index = min(max(index, 1), count)
        switch direction {
        case .next:
            index = index == count ? 1 : index + 1
        case .previous:
            index = index == 1 ? count : index - 1
        }
        defaults.set(index, forKey: key)
        return GuestChord(
            keyCode: Self.hyprlandWorkspaceKeyCodes[
                min(index, Self.hyprlandWorkspaceKeyCodes.count) - 1
            ],
            modifiers: [.command]
        )
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
                ("⌘W / ⌘Q", "Super+W"),
                ("⌘Space", "Super+Space"),
                ("⌘Tab", "Alt+Tab"),
                ("⇧⌘Tab", "Alt+Shift+Tab"),
                ("⌃⌘F", "Super+F"),
                ("⌘1…0", "Super+1…0"),
                ("Workspace swipe", "Super+Tab / Super+Shift+Tab")
            ]
        }
    }

    private var mappings: [HostChord: GuestChord] {
        Dictionary(
            uniqueKeysWithValues: Self.mappingEntries(
                for: effectivePreset
            ).map { ($0.host, $0.guest) }
        )
    }

    static func mappingEntries(
        for preset: KeyboardPreset
    ) -> [KeyboardMappingEntry] {
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

        let letterKeyCodes: [UInt16] = [
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13,
            14, 15, 16, 17, 31, 32, 34, 35, 37, 38, 40,
            45, 46
        ]
        let digitKeyCodes: [UInt16] = [
            18, 19, 20, 21, 22, 23, 25, 26, 28, 29
        ]
        for keyCode in letterKeyCodes {
            add(UInt16(keyCode), [.command], [.control])
            add(
                UInt16(keyCode),
                [.command, .shift],
                [.control, .shift]
            )
        }
        for keyCode in digitKeyCodes {
            add(keyCode, [.command], [.control])
        }
        add(24, [.command], [.control])
        add(27, [.command], [.control])
        add(123, [.command], [], guestKeyCode: 115)
        add(124, [.command], [], guestKeyCode: 119)
        add(126, [.command], [.control], guestKeyCode: 115)
        add(125, [.command], [.control], guestKeyCode: 119)
        add(123, [.command, .shift], [.shift], guestKeyCode: 115)
        add(124, [.command, .shift], [.shift], guestKeyCode: 119)
        add(
            126,
            [.command, .shift],
            [.control, .shift],
            guestKeyCode: 115
        )
        add(
            125,
            [.command, .shift],
            [.control, .shift],
            guestKeyCode: 119
        )
        add(123, [.option], [.control], guestKeyCode: 123)
        add(124, [.option], [.control], guestKeyCode: 124)
        add(
            123,
            [.option, .shift],
            [.control, .shift],
            guestKeyCode: 123
        )
        add(
            124,
            [.option, .shift],
            [.control, .shift],
            guestKeyCode: 124
        )
        add(51, [.option], [.control])
        add(117, [.option], [.control])

        switch preset {
        case .macOS:
            add(12, [.command], [.option], guestKeyCode: 118)
            add(48, [.command], [.option])
            add(48, [.command, .shift], [.option, .shift])
            add(3, [.command, .control], [], guestKeyCode: 103)
        case .hyprland:
            add(13, [.command], [.command])
            add(12, [.command], [.command], guestKeyCode: 13)
            add(49, [.command], [.command])
            add(48, [.command], [.option])
            add(48, [.command, .shift], [.option, .shift])
            add(3, [.command, .control], [.command])
            for keyCode in digitKeyCodes {
                add(keyCode, [.command], [.command])
                add(
                    keyCode,
                    [.command, .shift],
                    [.command, .shift]
                )
            }
        case .passthrough:
            return []
        }
        return result
            .map { KeyboardMappingEntry(host: $0.key, guest: $0.value) }
            .sorted {
                if $0.host.keyCode != $1.host.keyCode {
                    return $0.host.keyCode < $1.host.keyCode
                }
                return $0.host.modifiers.rawValue
                    < $1.host.modifiers.rawValue
            }
    }

    func activatePreset(forMachineNamed name: String) {
        let normalized = name.lowercased()
        activeMachinePreset =
            normalized.contains("omarchy")
            || normalized.contains("hyprland")
            ? .hyprland
            : preset
        if activeMachinePreset == .hyprland {
            UserDefaults.standard.set(
                1,
                forKey: "hyprlandWorkspaceIndex"
            )
        }
    }

    func deactivateMachinePreset() {
        activeMachinePreset = nil
    }

    private var effectivePreset: KeyboardPreset {
        activeMachinePreset ?? preset
    }

    var activePreset: KeyboardPreset {
        effectivePreset
    }

    private func synchronizeHyprlandWorkspace(
        with chord: GuestChord
    ) {
        guard effectivePreset == .hyprland,
              chord.modifiers == .command,
              let index = Self.hyprlandWorkspaceKeyCodes.firstIndex(
                of: chord.keyCode
              ) else {
            return
        }
        UserDefaults.standard.set(
            index + 1,
            forKey: "hyprlandWorkspaceIndex"
        )
    }

    private static let hyprlandWorkspaceKeyCodes: [UInt16] = [
        18, 19, 20, 21, 23, 22, 26, 28, 25, 29
    ]

    static let hyprlandWorkspaceCount = hyprlandWorkspaceKeyCodes.count

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

enum WorkspaceSwipeDirection: Equatable {
    case previous
    case next
}
