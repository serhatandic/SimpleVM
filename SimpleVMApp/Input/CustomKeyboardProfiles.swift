import AppKit
import Observation
import SimpleVMCore

struct CustomKeyboardProfile: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var baseProfile: MachineInputProfile
    var rules: String

    init(
        id: UUID = UUID(),
        name: String,
        baseProfile: MachineInputProfile,
        rules: String = ""
    ) {
        self.id = id
        self.name = name
        self.baseProfile = baseProfile
        self.rules = rules
    }
}

enum KeyboardProfileRuleParser {
    static func parse(_ rules: String) throws -> [KeyboardMappingEntry] {
        var entries: [HostChord: GuestChord] = [:]
        for (offset, rawLine) in rules.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ).enumerated() {
            let line = rawLine.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let sides = line.components(separatedBy: "->")
            guard sides.count == 2 else {
                throw KeyboardProfileError.invalidRule(
                    line: offset + 1,
                    message: "Use “host shortcut -> guest shortcut”."
                )
            }
            let hostChord = try parseShortcut(
                sides[0],
                line: offset + 1
            )
            let guestChord = try parseShortcut(
                sides[1],
                line: offset + 1
            )
            let host = HostChord(
                keyCode: hostChord.keyCode,
                modifiers: hostChord.modifiers
            )
            guard entries[host] == nil else {
                throw KeyboardProfileError.invalidRule(
                    line: offset + 1,
                    message: "The host shortcut is already mapped."
                )
            }
            entries[host] = guestChord
        }
        return entries.map {
            KeyboardMappingEntry(host: $0.key, guest: $0.value)
        }
        .sorted {
            if $0.host.keyCode != $1.host.keyCode {
                return $0.host.keyCode < $1.host.keyCode
            }
            return $0.host.modifiers.rawValue
                < $1.host.modifiers.rawValue
        }
    }

    private static func parseShortcut(
        _ source: String,
        line: Int
    ) throws -> GuestChord {
        let parts = source.split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let keyName = parts.last, !keyName.isEmpty else {
            throw KeyboardProfileError.invalidRule(
                line: line,
                message: "A key is required."
            )
        }
        var modifiers = NSEvent.ModifierFlags()
        for modifier in parts.dropLast() {
            switch modifier.lowercased() {
            case "cmd", "command", "super", "win", "windows":
                modifiers.insert(.command)
            case "ctrl", "control":
                modifiers.insert(.control)
            case "alt", "option":
                modifiers.insert(.option)
            case "shift":
                modifiers.insert(.shift)
            default:
                throw KeyboardProfileError.invalidRule(
                    line: line,
                    message: "Unknown modifier “\(modifier)”."
                )
            }
        }
        do {
            let key = try GuestTextEncoder.chord(forKeyName: keyName)
            modifiers.formUnion(key.modifiers)
            return GuestChord(
                keyCode: key.keyCode,
                modifiers: modifiers
            )
        } catch {
            throw KeyboardProfileError.invalidRule(
                line: line,
                message: error.localizedDescription
            )
        }
    }
}

@MainActor
@Observable
final class KeyboardProfileStore {
    static let shared = KeyboardProfileStore()
    static let allowedBaseProfiles: [MachineInputProfile] = [
        .macOSGNOME,
        .macOSHyprland,
        .macOSWindows,
        .linuxPassthrough
    ]

    private(set) var profiles: [CustomKeyboardProfile]
    private let defaults: UserDefaults
    private let storageKey: String
    @ObservationIgnored
    private var preservedEntries: [Any] = []
    @ObservationIgnored
    private var storageIsUnreadable = false

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "customKeyboardProfiles"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        guard let data = defaults.data(forKey: storageKey) else {
            profiles = []
            return
        }
        do {
            guard let objects = try JSONSerialization.jsonObject(
                with: data
            ) as? [Any] else {
                throw KeyboardProfileError.unreadableStorage
            }
            var decoded: [CustomKeyboardProfile] = []
            for object in objects {
                let entryData = try JSONSerialization.data(
                    withJSONObject: object
                )
                if let profile = try? JSONDecoder().decode(
                    CustomKeyboardProfile.self,
                    from: entryData
                ) {
                    decoded.append(profile)
                } else {
                    preservedEntries.append(object)
                }
            }
            profiles = decoded
        } catch {
            profiles = []
            storageIsUnreadable = true
        }
    }

    @discardableResult
    func create(
        baseProfile: MachineInputProfile = .macOSWindows
    ) throws -> CustomKeyboardProfile {
        let profile = CustomKeyboardProfile(
            name: uniqueName("Custom Profile"),
            baseProfile: Self.allowedBaseProfiles.contains(baseProfile)
                ? baseProfile
                : .macOSWindows
        )
        try persist(profiles + [profile])
        return profile
    }

    @discardableResult
    func duplicate(
        _ source: CustomKeyboardProfile
    ) throws -> CustomKeyboardProfile {
        let profile = CustomKeyboardProfile(
            name: uniqueName("\(source.name) Copy"),
            baseProfile: source.baseProfile,
            rules: source.rules
        )
        try persist(profiles + [profile])
        return profile
    }

    func save(
        id: UUID,
        name: String,
        baseProfile: MachineInputProfile,
        rules: String
    ) throws {
        let trimmedName = name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedName.isEmpty else {
            throw KeyboardProfileError.missingName
        }
        guard Self.allowedBaseProfiles.contains(baseProfile) else {
            throw KeyboardProfileError.invalidBaseProfile
        }
        _ = try KeyboardProfileRuleParser.parse(rules)
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw KeyboardProfileError.notFound
        }
        var updated = profiles
        updated[index].name = trimmedName
        updated[index].baseProfile = baseProfile
        updated[index].rules = rules
        try persist(updated)
    }

    func delete(id: UUID) throws {
        try persist(profiles.filter { $0.id != id })
    }

    func profile(id: UUID?) -> CustomKeyboardProfile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    private func uniqueName(_ proposed: String) -> String {
        guard profiles.contains(where: { $0.name == proposed }) else {
            return proposed
        }
        var suffix = 2
        while profiles.contains(where: {
            $0.name == "\(proposed) \(suffix)"
        }) {
            suffix += 1
        }
        return "\(proposed) \(suffix)"
    }

    private func persist(_ updated: [CustomKeyboardProfile]) throws {
        guard !storageIsUnreadable else {
            throw KeyboardProfileError.unreadableStorage
        }
        let encoded = try updated.map { profile -> Any in
            let data = try JSONEncoder().encode(profile)
            return try JSONSerialization.jsonObject(with: data)
        }
        let data = try JSONSerialization.data(
            withJSONObject: encoded + preservedEntries,
            options: [.sortedKeys]
        )
        defaults.set(data, forKey: storageKey)
        profiles = updated
    }
}

enum KeyboardProfileError: LocalizedError, Equatable {
    case missingName
    case invalidBaseProfile
    case notFound
    case unreadableStorage
    case invalidRule(line: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingName:
            "Enter a profile name."
        case .invalidBaseProfile:
            "Choose a built-in base profile."
        case .notFound:
            "The custom profile no longer exists."
        case .unreadableStorage:
            "Saved keyboard profiles could not be read. The original data was preserved."
        case .invalidRule(let line, let message):
            "Line \(line): \(message)"
        }
    }
}
