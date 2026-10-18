import Foundation

/// Stand-in icon for a project without one: its initials on a colour drawn from its name. The same name always
/// gets the same colour, on every launch and every Mac, so an app can be told apart before it has a real icon.
public enum Monogram {
    /// The theme's tints, softened towards grey so a stand-in never looks like a finished icon, plus three
    /// neighbours of the same weight to spread names across more colours.
    public static let palette: [UInt32] = [
        0x2F7A4E, 0x1F6F6B, 0x0A6CD6, 0x7D4FC4, 0xC2306A, 0xB5481A, 0x5B6470, 0x9A7B2F, 0x4A6A8A
    ].map { ThemeColor.mix($0, 0x8A8F96, amount: 0.25) }

    /// Two initials when the name splits into words or at a capital (« NamerKit » → « NK »), otherwise one:
    /// « LLMarium » gives « L », not a hard-to-read « LL ».
    public static func letters(for name: String) -> String {
        let words = self.words(in: name)
        let initials = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return initials.isEmpty ? "?" : initials.joined()
    }

    /// Words of a name: split on anything that is not a letter or a digit, then where a lowercase letter is
    /// followed by a capital. A run of capitals stays one word.
    static func words(in name: String) -> [String] {
        var words: [String] = []
        for token in name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            var current = ""
            var previous: Character?
            for character in token {
                if let previous, previous.isLowercase, character.isUppercase, !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                current.append(character)
                previous = character
            }
            if !current.isEmpty { words.append(current) }
        }
        return words
    }

    public static func color(for name: String) -> UInt32 {
        palette[Int(fnv1a(name.lowercased()) % UInt64(palette.count))]
    }

    /// FNV-1a over the UTF-8 bytes: unlike `hashValue`, it does not change from one launch to the next.
    static func fnv1a(_ text: String) -> UInt64 {
        text.utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}
