import Foundation

/// Icons offered in Settings. The first one is the bundle's own (`AppIcon.icns`).
public enum AppIconChoice: String, CaseIterable, Identifiable, Sendable {
    case fingerprint = "16a"
    case fingerprintBlueprint = "16b"
    case fingerprintStack = "21"
    case liftedStack = "22"

    public static let defaultsKey = "appIcon"
    public static let standard = AppIconChoice.fingerprint

    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .fingerprint: String(localized: "Fingerprint")
        case .fingerprintBlueprint: String(localized: "Fingerprint on Grid")
        case .fingerprintStack: String(localized: "Fingerprint Stack")
        case .liftedStack: String(localized: "Lifted Stack")
        }
    }
    /// Resources copied into `Contents/Resources/Icons` by `build.sh`.
    public var iconResource: String { "AppIcon-\(rawValue)" }
    public var glyphResource: String { "MenuBar-\(rawValue)@2x" }

    public static func load(from defaults: UserDefaults) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? standard
    }
}

/// Menu bar image: the original system symbol, or the glyph matching the chosen icon.
public enum MenuBarSymbol: String, CaseIterable, Sendable {
    case system, matching

    public static let defaultsKey = "menuBarSymbol"

    public static func load(from defaults: UserDefaults) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .system
    }
}
