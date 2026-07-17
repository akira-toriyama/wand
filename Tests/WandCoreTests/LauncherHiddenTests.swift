import XCTest
@testable import WandCore

/// Session-only context-menu delete (t-k4hf / wand#128):
/// `LauncherHidden.apply` is the pure per-level filter. Elements
/// whose id is in the hidden set drop; nil-id elements (headers /
/// placeholders) always survive; unknown hidden ids are no-ops.
final class LauncherHiddenTests: XCTestCase {

    private func apply(_ ids: [String], _ hidden: Set<String>) -> [String] {
        LauncherHidden.apply(ids, id: { $0 }, hidden: hidden)
    }

    func testEmptyHiddenKeepsAll() {
        XCTAssertEqual(apply(["a", "b"], []), ["a", "b"])
    }

    func testHidesMatchingIds() {
        XCTAssertEqual(apply(["a", "b", "c"], ["b"]), ["a", "c"])
    }

    func testUnknownIdIsNoOp() {
        XCTAssertEqual(apply(["a", "b"], ["x"]), ["a", "b"])
    }

    func testNilIdElementsAlwaysSurvive() {
        // Header-style elements expose no id; a hidden set can never
        // touch them (even one that happens to contain their label).
        let out = LauncherHidden.apply(
            [("a", true), ("sep", false), ("b", true)],
            id: { $0.1 ? $0.0 : nil },
            hidden: ["a", "sep"])
        XCTAssertEqual(out.map(\.0), ["sep", "b"])
    }

    func testAllHiddenYieldsEmpty() {
        XCTAssertEqual(apply(["a"], ["a"]), [])
    }
}
