import XCTest
@testable import LauncherCore

final class MonogramTests: XCTestCase {
    func testInitialsFollowWordsAndCapitals() {
        XCTAssertEqual(Monogram.letters(for: "NamerKit"), "NK")
        XCTAssertEqual(Monogram.letters(for: "DailyPencilPlanner"), "DP", "two initials at most")
        XCTAssertEqual(Monogram.letters(for: "LLMarium"), "L", "a run of capitals is one word")
        XCTAssertEqual(Monogram.letters(for: "tralala"), "T")
        XCTAssertEqual(Monogram.letters(for: "loop-huntr"), "LH")
        XCTAssertEqual(Monogram.letters(for: "Appothèque"), "A")
        XCTAssertEqual(Monogram.letters(for: "  "), "?")
    }

    func testColourDependsOnlyOnTheName() {
        XCTAssertEqual(Monogram.color(for: "NamerKit"), Monogram.color(for: "namerkit"), "case does not matter")
        XCTAssertTrue(Monogram.palette.contains(Monogram.color(for: "NamerKit")))
        // Fixed value: the hash must not change between launches (Swift's `hashValue` does).
        XCTAssertEqual(Monogram.fnv1a("namerkit"), Monogram.fnv1a("namerkit"))
        XCTAssertEqual(Monogram.fnv1a(""), 14_695_981_039_346_656_037)
        XCTAssertEqual(Monogram.fnv1a("a"), 0xAF63DC4C8601EC8C)
    }

    func testNamesSpreadOverThePalette() {
        let names = ["NamerKit", "LLMarium", "tralala", "Letheca", "Rhizomes", "Spicilege", "LoopHuntr", "DailyPencilPlanner", "Watslog", "Daymon"]
        XCTAssertGreaterThanOrEqual(Set(names.map(Monogram.color(for:))).count, 5)
    }
}
