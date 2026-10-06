import Foundation
import XCTest
@testable import LauncherCore

final class AppPresenceTests: XCTestCase {
    func testAtLeastOneAccessStaysEnabled() {
        let start = AppPresence()
        XCTAssertEqual(start, AppPresence(dock: false, menuBar: true))
        XCTAssertEqual(start.with(menuBar: false), AppPresence(dock: true, menuBar: false))
        XCTAssertEqual(start.with(dock: true).with(menuBar: false).with(dock: false), AppPresence(dock: false, menuBar: true))
        XCTAssertEqual(AppPresence(dock: false, menuBar: false), AppPresence(dock: false, menuBar: true))
    }

    func testPersistsAndDefaultsToMenuBarOnly() throws {
        let domain = "dev.arsis.appotheque.presence-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        XCTAssertEqual(AppPresence.load(from: defaults), AppPresence(dock: false, menuBar: true))
        AppPresence(dock: true, menuBar: false).save(to: defaults)
        XCTAssertEqual(AppPresence.load(from: defaults), AppPresence(dock: true, menuBar: false))
    }
}
