import Foundation
import XCTest
@testable import LauncherCore

final class AppearanceTests: XCTestCase {
    func testTintsStayReadableInBothAppearances() {
        for tint in AppTint.allCases {
            guard let hex = tint.hex else { continue }
            XCTAssertGreaterThanOrEqual(ThemeColor.contrast(hex.light, 0xFFFFFF), 4.5, tint.label)
            XCTAssertGreaterThanOrEqual(ThemeColor.contrast(hex.dark, 0x1E1E1E), 4.5, tint.label)
            XCTAssertGreaterThanOrEqual(ThemeColor.contrast(hex.dark, 0xFFFFFF), 3, tint.label)
        }
        XCTAssertNil(AppTint.system.hex)
        XCTAssertNil(AppTint.system.labelHex)
        XCTAssertEqual(AppearancePreferences().tint, .green)
        XCTAssertEqual(AppearancePreferences().mode, .system)
    }

    func testMainButtonLabelsStayReadableOnTheirWash() {
        for tint in AppTint.allCases {
            guard let hex = tint.hex, let label = tint.labelHex else { continue }
            // The button is the tint at 15 % over a light card or a dark one.
            for card in [UInt32(0xF2F2F2), 0xFFFFFF] {
                XCTAssertGreaterThanOrEqual(ThemeColor.contrast(label.light, ThemeColor.mix(card, hex.light, amount: 0.15)), 4.5, tint.label)
            }
            for card in [UInt32(0x2C2C2E), 0x1E1E1E] {
                XCTAssertGreaterThanOrEqual(ThemeColor.contrast(label.dark, ThemeColor.mix(card, hex.dark, amount: 0.15)), 4.5, tint.label)
            }
        }
    }

    func testPreferencesReloadWithoutChangingProjectPreferences() throws {
        let (defaults, domain) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(["hidden-app"], forKey: "hiddenProjectIDs")
        defaults.set(["favorite-app"], forKey: "favoriteProjectIDs")
        defaults.set("space", forKey: "launcherShortcut")
        let settings = AppearancePreferences(mode: .dark, tint: .purple)
        settings.save(to: defaults)
        XCTAssertEqual(AppearancePreferences.load(from: try XCTUnwrap(UserDefaults(suiteName: domain))), settings)
        XCTAssertEqual(defaults.stringArray(forKey: "hiddenProjectIDs"), ["hidden-app"])
        XCTAssertEqual(defaults.stringArray(forKey: "favoriteProjectIDs"), ["favorite-app"])
        XCTAssertEqual(defaults.string(forKey: "launcherShortcut"), "space")
    }

    func testInvalidOrUnknownValuesFallBack() throws {
        let (defaults, domain) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(Data("invalid json".utf8), forKey: AppearancePreferences.storageKey)
        XCTAssertEqual(AppearancePreferences.load(from: defaults), AppearancePreferences())
        defaults.set(Data(#"{"mode":"sepia","tint":"blue"}"#.utf8), forKey: AppearancePreferences.storageKey)
        XCTAssertEqual(AppearancePreferences.load(from: defaults), AppearancePreferences(mode: .system, tint: .blue))
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let domain = "dev.arsis.appotheque.appearance-test.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: domain)), domain)
    }
}
