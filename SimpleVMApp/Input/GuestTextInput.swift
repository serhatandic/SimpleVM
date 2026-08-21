import AppKit

enum GuestTextEncoder {
    static func chords(for text: String) throws -> [GuestChord] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return try normalized.map(chord(for:))
    }

    static func chord(for character: Character) throws -> GuestChord {
        if character == "\n" {
            return GuestChord(keyCode: 36, modifiers: [])
        }
        if character == "\t" {
            return GuestChord(keyCode: 48, modifiers: [])
        }
        guard let mapping = characterMappings[character] else {
            throw GuestTextEncodingError.unsupportedCharacter(character)
        }
        return GuestChord(
            keyCode: mapping.keyCode,
            modifiers: mapping.shifted ? [.shift] : []
        )
    }

    static func chord(forKeyName name: String) throws -> GuestChord {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized.count == 1, let character = normalized.first {
            return try chord(for: character)
        }
        if let character = namedCharacters[normalized] {
            return try chord(for: character)
        }
        if let keyCode = namedKeyCodes[normalized] {
            return GuestChord(keyCode: keyCode, modifiers: [])
        }
        throw GuestTextEncodingError.unknownKey(name)
    }

    private struct CharacterMapping {
        let keyCode: UInt16
        let shifted: Bool
    }

    private static let characterMappings: [Character: CharacterMapping] = {
        var result: [Character: CharacterMapping] = [:]
        let letters: [(Character, UInt16)] = [
            ("a", 0), ("b", 11), ("c", 8), ("d", 2), ("e", 14),
            ("f", 3), ("g", 5), ("h", 4), ("i", 34), ("j", 38),
            ("k", 40), ("l", 37), ("m", 46), ("n", 45), ("o", 31),
            ("p", 35), ("q", 12), ("r", 15), ("s", 1), ("t", 17),
            ("u", 32), ("v", 9), ("w", 13), ("x", 7), ("y", 16),
            ("z", 6)
        ]
        for (character, keyCode) in letters {
            result[character] = CharacterMapping(
                keyCode: keyCode,
                shifted: false
            )
            result[Character(character.uppercased())] = CharacterMapping(
                keyCode: keyCode,
                shifted: true
            )
        }
        let unshifted: [(Character, UInt16)] = [
            ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23),
            ("6", 22), ("7", 26), ("8", 28), ("9", 25), ("0", 29),
            ("-", 27), ("=", 24), ("[", 33), ("]", 30), ("\\", 42),
            (";", 41), ("'", 39), (",", 43), (".", 47), ("/", 44),
            ("`", 50), (" ", 49)
        ]
        for (character, keyCode) in unshifted {
            result[character] = CharacterMapping(
                keyCode: keyCode,
                shifted: false
            )
        }
        let shifted: [(Character, UInt16)] = [
            ("!", 18), ("@", 19), ("#", 20), ("$", 21), ("%", 23),
            ("^", 22), ("&", 26), ("*", 28), ("(", 25), (")", 29),
            ("_", 27), ("+", 24), ("{", 33), ("}", 30), ("|", 42),
            (":", 41), ("\"", 39), ("<", 43), (">", 47), ("?", 44),
            ("~", 50)
        ]
        for (character, keyCode) in shifted {
            result[character] = CharacterMapping(
                keyCode: keyCode,
                shifted: true
            )
        }
        return result
    }()

    private static let namedCharacters: [String: Character] = [
        "colon": ":",
        "semicolon": ";",
        "plus": "+",
        "minus": "-",
        "equal": "=",
        "slash": "/",
        "backslash": "\\",
        "comma": ",",
        "period": ".",
        "quote": "'",
        "space": " "
    ]

    private static let namedKeyCodes: [String: UInt16] = [
        "return": 36,
        "enter": 36,
        "tab": 48,
        "escape": 53,
        "esc": 53,
        "backspace": 51,
        "delete": 117,
        "forwarddelete": 117,
        "home": 115,
        "end": 119,
        "pageup": 116,
        "pagedown": 121,
        "left": 123,
        "right": 124,
        "down": 125,
        "up": 126,
        "f1": 122,
        "f2": 120,
        "f3": 99,
        "f4": 118,
        "f5": 96,
        "f6": 97,
        "f7": 98,
        "f8": 100,
        "f9": 101,
        "f10": 109,
        "f11": 103,
        "f12": 111
    ]
}

enum GuestTextEncodingError: LocalizedError, Equatable {
    case unsupportedCharacter(Character)
    case unknownKey(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedCharacter(let character):
            "The character “\(character)” cannot be typed with the virtual US keyboard."
        case .unknownKey(let key):
            "Unknown key “\(key)”."
        }
    }
}
