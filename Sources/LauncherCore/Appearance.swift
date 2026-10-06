import Foundation

/// Light, dark, or following the Mac.
public enum AppearanceMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .system: return String(localized: "Automatic")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }
}

/// The single colour the interface takes from the user. Everything else follows macOS.
public enum AppTint: String, CaseIterable, Codable, Sendable, Identifiable {
    case green, pine, blue, purple, pink, brick, graphite, system
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .green: return String(localized: "Appothèque Green")
        case .pine: return String(localized: "Pine")
        case .blue: return String(localized: "Blue")
        case .purple: return String(localized: "Purple")
        case .pink: return String(localized: "Pink")
        case .brick: return String(localized: "Brick")
        case .graphite: return String(localized: "Graphite")
        case .system: return String(localized: "System Accent")
        }
    }
    /// sRGB values for the light and dark appearances; `nil` follows the accent chosen in System Settings.
    /// Light values keep 4.5:1 on white, dark values 4.5:1 on a dark window and 3:1 under white button labels.
    public var hex: (light: UInt32, dark: UInt32)? {
        switch self {
        case .green: return (0x2F7A4E, 0x3F9E68)
        case .pine: return (0x1F6F6B, 0x2E9A93)
        case .blue: return (0x0A6CD6, 0x3D8EF0)
        case .purple: return (0x7D4FC4, 0x9C7AE0)
        case .pink: return (0xC2306A, 0xE0558C)
        case .brick: return (0xB5481A, 0xD9703A)
        case .graphite: return (0x5B6470, 0x8A94A0)
        case .system: return nil
        }
    }
    /// Text on a light wash of the tint (the main button): darker in light mode, lighter in dark mode, for 4.5:1.
    public var labelHex: (light: UInt32, dark: UInt32)? {
        hex.map { (ThemeColor.mix($0.light, 0x000000, amount: 0.3), ThemeColor.mix($0.dark, 0xFFFFFF, amount: 0.45)) }
    }
}

public struct AppearancePreferences: Codable, Equatable, Sendable {
    public static let storageKey = "appearance.v2"
    public var mode: AppearanceMode = .system
    public var tint: AppTint = .green
    public init(mode: AppearanceMode = .system, tint: AppTint = .green) { self.mode = mode; self.tint = tint }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? container.decode(AppearanceMode.self, forKey: .mode)) ?? .system
        tint = (try? container.decode(AppTint.self, forKey: .tint)) ?? .green
    }

    public static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: storageKey) else { return Self() }
        return (try? JSONDecoder().decode(Self.self, from: data)) ?? Self()
    }
    public func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.storageKey) }
    }
}

public enum ThemeColor {
    public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ value: UInt32) -> Double {
            let rgb = [16, 8, 0].map { shift -> Double in
                let channel = Double((value >> shift) & 255) / 255
                return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722
        }
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    public static func mix(_ a: UInt32, _ b: UInt32, amount: Double) -> UInt32 {
        [16, 8, 0].reduce(0) { result, shift in
            let from = Double((a >> shift) & 255), to = Double((b >> shift) & 255)
            return result | (UInt32((from + (to - from) * amount).rounded()) << shift)
        }
    }
}
