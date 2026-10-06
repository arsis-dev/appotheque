import Foundation
import XCTest
@testable import LauncherCore

final class AppIconChoiceTests: XCTestCase {
    func testLoadsSavedChoicesAndFallsBackToDefaults() throws {
        let domain = "dev.arsis.appotheque.icon-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }

        XCTAssertEqual(AppIconChoice.load(from: defaults), .standard)
        XCTAssertEqual(MenuBarSymbol.load(from: defaults), .system)

        defaults.set("22", forKey: AppIconChoice.defaultsKey)
        defaults.set("matching", forKey: MenuBarSymbol.defaultsKey)
        XCTAssertEqual(AppIconChoice.load(from: defaults), .liftedStack)
        XCTAssertEqual(MenuBarSymbol.load(from: defaults), .matching)

        defaults.set("supprimée", forKey: AppIconChoice.defaultsKey)
        XCTAssertEqual(AppIconChoice.load(from: defaults), .standard)
    }

    func testEveryChoiceShipsItsResources() {
        let icons = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/Icons").standardizedFileURL
        for choice in AppIconChoice.allCases {
            XCTAssertTrue(FileManager.default.fileExists(atPath: icons.appendingPathComponent(choice.iconResource + ".png").path), choice.rawValue)
            XCTAssertTrue(FileManager.default.fileExists(atPath: icons.appendingPathComponent(choice.glyphResource + ".png").path), choice.rawValue)
        }
    }
}
