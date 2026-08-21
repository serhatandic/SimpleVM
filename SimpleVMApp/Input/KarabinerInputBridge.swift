import AppKit
import Foundation

@MainActor
enum KarabinerInputBridge {
    static let ruleDescription = "SimpleVM Immersion Mappings"
    static let variableName = "simplevm_vz_immersion"

    private static let cliURL = URL(
        filePath:
            "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
    )

    private static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/karabiner/karabiner.json")
    }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: cliURL.path)
    }

    static func prepare() throws {
        guard isInstalled else {
            throw KarabinerBridgeError.notInstalled
        }
        let devices = try runCLI(["--list-connected-devices"])
        guard devices.contains("Karabiner DriverKit VirtualHIDKeyboard") else {
            throw KarabinerBridgeError.virtualKeyboardUnavailable
        }
        try installRules(
            entries: KeyboardMappingSettings.shared.activeMappingEntries
        )
        let profile = try runCLI(["--show-current-profile-name"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.isEmpty else {
            throw KarabinerBridgeError.invalidConfiguration
        }
        _ = try runCLI(["--select-profile", profile])
    }

    @discardableResult
    static func setImmersionActive(_ active: Bool) -> Bool {
        guard isInstalled else { return false }
        do {
            _ = try runCLI([
                "--set-variables",
                variablePayload(active: active)
            ])
            return true
        } catch {
            return false
        }
    }

    static func variablePayload(active: Bool) -> String {
        "{\"\(variableName)\":\(active ? 1 : 0)}"
    }

    private static func installRules(
        entries: [KeyboardMappingEntry]
    ) throws {
        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch {
            throw KarabinerBridgeError.configurationUnavailable
        }
        guard var root = try JSONSerialization.jsonObject(
            with: data
        ) as? [String: Any],
        var profiles = root["profiles"] as? [[String: Any]],
        !profiles.isEmpty else {
            throw KarabinerBridgeError.invalidConfiguration
        }
        let profileIndex = profiles.firstIndex {
            $0["selected"] as? Bool == true
        } ?? 0
        var profile = profiles[profileIndex]
        var modifications =
            profile["complex_modifications"] as? [String: Any] ?? [:]
        var rules = modifications["rules"] as? [[String: Any]] ?? []
        rules.removeAll {
            $0["description"] as? String == ruleDescription
        }
        rules.append(try generatedRule(entries: entries))
        modifications["rules"] = rules
        profile["complex_modifications"] = modifications
        profiles[profileIndex] = profile
        root["profiles"] = profiles

        let backupURL = configURL.appendingPathExtension("simplevm-backup")
        try? FileManager.default.removeItem(at: backupURL)
        try FileManager.default.copyItem(at: configURL, to: backupURL)
        let output = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try output.write(to: configURL, options: .atomic)
    }

    static var generatedRule: [String: Any] {
        generatedRule(for: .gnome)
    }

    static func generatedRule(
        for preset: KeyboardPreset
    ) -> [String: Any] {
        (try? generatedRule(
            entries: KeyboardMappingSettings.mappingEntries(for: preset)
        )) ?? [
            "description": ruleDescription,
            "manipulators": []
        ]
    }

    static func generatedRule(
        entries: [KeyboardMappingEntry]
    ) throws -> [String: Any] {
        let manipulators = entries.compactMap(mapping)
        guard manipulators.count == entries.count else {
            throw KarabinerBridgeError.unsupportedMapping
        }
        return [
            "description": ruleDescription,
            "manipulators": manipulators
        ]
    }

    private static func mapping(
        _ entry: KeyboardMappingEntry
    ) -> [String: Any]? {
        guard let fromKey = keyName(for: entry.host.keyCode),
              let toKey = keyName(for: entry.guest.keyCode) else {
            return nil
        }
        let fromModifiers = modifierNames(
            for: entry.host.modifiers,
            sideSpecific: false
        )
        let toModifiers = modifierNames(
            for: entry.guest.modifiers,
            sideSpecific: true
        )
        var to: [String: Any] = ["key_code": toKey]
        if !toModifiers.isEmpty {
            to["modifiers"] = toModifiers
        }
        return [
            "type": "basic",
            "from": [
                "key_code": fromKey,
                "modifiers": [
                    "mandatory": fromModifiers,
                    "optional": ["caps_lock", "fn"]
                ]
            ],
            "to": [to],
            "conditions": [
                [
                    "type": "frontmost_application_if",
                    "bundle_identifiers": ["^com\\.simplevm\\.app$"]
                ],
                [
                    "type": "variable_if",
                    "name": variableName,
                    "value": 1
                ]
            ]
        ]
    }

    private static func keyName(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 0: "a"
        case 1: "s"
        case 2: "d"
        case 3: "f"
        case 4: "h"
        case 5: "g"
        case 6: "z"
        case 7: "x"
        case 8: "c"
        case 9: "v"
        case 11: "b"
        case 12: "q"
        case 13: "w"
        case 14: "e"
        case 15: "r"
        case 16: "y"
        case 17: "t"
        case 18: "1"
        case 19: "2"
        case 20: "3"
        case 21: "4"
        case 22: "6"
        case 23: "5"
        case 24: "equal_sign"
        case 25: "9"
        case 26: "7"
        case 27: "hyphen"
        case 28: "8"
        case 29: "0"
        case 30: "close_bracket"
        case 33: "open_bracket"
        case 31: "o"
        case 32: "u"
        case 34: "i"
        case 35: "p"
        case 36: "return_or_enter"
        case 37: "l"
        case 38: "j"
        case 40: "k"
        case 39: "quote"
        case 41: "semicolon"
        case 42: "backslash"
        case 43: "comma"
        case 44: "slash"
        case 45: "n"
        case 46: "m"
        case 47: "period"
        case 48: "tab"
        case 49: "spacebar"
        case 50: "grave_accent_and_tilde"
        case 51: "delete_or_backspace"
        case 53: "escape"
        case 96: "f5"
        case 97: "f6"
        case 98: "f7"
        case 99: "f3"
        case 100: "f8"
        case 101: "f9"
        case 103: "f11"
        case 109: "f10"
        case 111: "f12"
        case 115: "home"
        case 116: "page_up"
        case 118: "f4"
        case 120: "f2"
        case 121: "page_down"
        case 122: "f1"
        case 117: "delete_forward"
        case 119: "end"
        case 123: "left_arrow"
        case 124: "right_arrow"
        case 125: "down_arrow"
        case 126: "up_arrow"
        default: nil
        }
    }

    private static func modifierNames(
        for modifiers: NSEvent.ModifierFlags,
        sideSpecific: Bool
    ) -> [String] {
        var result: [String] = []
        if modifiers.contains(.command) {
            result.append(sideSpecific ? "left_command" : "command")
        }
        if modifiers.contains(.control) {
            result.append(sideSpecific ? "left_control" : "control")
        }
        if modifiers.contains(.option) {
            result.append(sideSpecific ? "left_option" : "option")
        }
        if modifiers.contains(.shift) {
            result.append(sideSpecific ? "left_shift" : "shift")
        }
        if modifiers.contains(.function) {
            result.append("fn")
        }
        return result
    }

    private static func runCLI(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL = cliURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errorOutput
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorOutput.fileHandleForReading.readDataToEndOfFile()
            throw KarabinerBridgeError.commandFailed(
                String(decoding: data, as: UTF8.self)
            )
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}

enum KarabinerBridgeError: LocalizedError {
    case notInstalled
    case virtualKeyboardUnavailable
    case configurationUnavailable
    case invalidConfiguration
    case unsupportedMapping
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "Karabiner-Elements is not installed."
        case .virtualKeyboardUnavailable:
            "Karabiner's virtual keyboard is not active."
        case .configurationUnavailable:
            "Open Karabiner-Elements once to create its configuration."
        case .invalidConfiguration:
            "Karabiner-Elements configuration is invalid."
        case .unsupportedMapping:
            "A custom keyboard mapping cannot be represented by Karabiner-Elements."
        case .commandFailed(let message):
            "Karabiner command failed: \(message)"
        }
    }
}
