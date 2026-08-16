import Foundation

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
        try installRules()
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
            "{\"\\(variableName)\":\\(active ? 1 : 0)}"
            ])
            return true
        } catch {
            return false
        }
    }

    private static func installRules() throws {
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
        rules.append(generatedRule)
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
        let shared: [[String: Any]] = [
            mapping("c", ["command"], "c", ["left_control"]),
            mapping("x", ["command"], "x", ["left_control"]),
            mapping("v", ["command"], "v", ["left_control"]),
            mapping("z", ["command"], "z", ["left_control"]),
            mapping("z", ["command", "shift"], "z", [
                "left_control", "left_shift"
            ]),
            mapping("a", ["command"], "a", ["left_control"]),
            mapping("s", ["command"], "s", ["left_control"]),
            mapping("p", ["command"], "p", ["left_control"]),
            mapping("o", ["command"], "o", ["left_control"]),
            mapping("f", ["command"], "f", ["left_control"]),
            mapping("g", ["command"], "g", ["left_control"]),
            mapping("r", ["command"], "r", ["left_control"]),
            mapping("l", ["command"], "l", ["left_control"]),
            mapping("n", ["command"], "n", ["left_control"]),
            mapping("t", ["command"], "t", ["left_control"]),
            mapping("w", ["command"], "w", ["left_control"]),
            mapping("equal_sign", ["command"], "equal_sign", [
                "left_control"
            ]),
            mapping("hyphen", ["command"], "hyphen", ["left_control"]),
            mapping("0", ["command"], "0", ["left_control"]),
            mapping("left_arrow", ["command"], "home", []),
            mapping("right_arrow", ["command"], "end", []),
            mapping("up_arrow", ["command"], "home", ["left_control"]),
            mapping("down_arrow", ["command"], "end", ["left_control"]),
            mapping("left_arrow", ["option"], "left_arrow", [
                "left_control"
            ]),
            mapping("right_arrow", ["option"], "right_arrow", [
                "left_control"
            ]),
            mapping(
                "delete_or_backspace",
                ["option"],
                "delete_or_backspace",
                ["left_control"]
            ),
            mapping("delete_forward", ["option"], "delete_forward", [
                "left_control"
            ]),
            mapping("q", ["command"], "f4", ["left_option"]),
            mapping("tab", ["command"], "tab", ["left_option"]),
            mapping("tab", ["command", "shift"], "tab", [
                "left_option", "left_shift"
            ]),
            mapping("f", ["command", "control"], "f11", [])
        ]
        return [
            "description": ruleDescription,
            "manipulators": shared
        ]
    }

    private static func mapping(
        _ fromKey: String,
        _ fromModifiers: [String],
        _ toKey: String,
        _ toModifiers: [String]
    ) -> [String: Any] {
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
                    "optional": ["caps_lock"]
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
        case .commandFailed(let message):
            "Karabiner command failed: \(message)"
        }
    }
}
