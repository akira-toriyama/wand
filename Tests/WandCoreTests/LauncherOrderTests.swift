import XCTest
@testable import WandCore

/// Session-only DnD sort (wand#127): `LauncherOrder.apply` is the
/// pure slot-merge that reorders one panel level's elements per a
/// saved override. Only elements whose id appears in the override
/// move — and they move only within the slots they already occupy —
/// so a panel filtered down to a subset (per-app `apps` globs) never
/// scrambles rows the user didn't drag.
final class LauncherOrderTests: XCTestCase {

    private func apply(_ ids: [String], _ override: [String]) -> [String] {
        LauncherOrder.apply(ids, id: { $0 }, override: override)
    }

    func testFullOverrideReordersCompletely() {
        XCTAssertEqual(apply(["a", "b", "c"], ["c", "a", "b"]),
                       ["c", "a", "b"])
    }

    func testEmptyOverrideKeepsOrder() {
        XCTAssertEqual(apply(["a", "b", "c"], []), ["a", "b", "c"])
    }

    func testSubsetOverrideOnlyPermutesItsOwnSlots() {
        // Override knows a and c only (e.g. saved while other rows
        // were filtered out). b and d keep their positions; a and c
        // swap within slots 0 and 2.
        XCTAssertEqual(apply(["a", "b", "c", "d"], ["c", "a"]),
                       ["c", "b", "a", "d"])
    }

    func testOverrideWithUnknownIdsIgnoresThem() {
        // "x" was visible when the override was saved but is filtered
        // out now — it must not consume a slot.
        XCTAssertEqual(apply(["a", "b"], ["x", "b", "a"]), ["b", "a"])
    }

    func testPartialOverrideLeavesUntouchedRowsInPlace() {
        XCTAssertEqual(apply(["a", "b", "c"], ["c", "b"]),
                       ["a", "c", "b"])
    }

    func testNilIdElementsNeverMove() {
        // Placeholder-style elements expose no id; they keep their
        // positions and don't participate in the permutation.
        let out = LauncherOrder.apply(
            [("a", true), ("sep", false), ("b", true)],
            id: { $0.1 ? $0.0 : nil },
            override: ["b", "a"])
        XCTAssertEqual(out.map(\.0), ["b", "sep", "a"])
    }

    func testDuplicateIdsStayStable() {
        // Two rows share an id (same item name twice) — they keep
        // their relative order among themselves.
        XCTAssertEqual(apply(["a", "dup", "dup", "b"], ["b", "dup", "a"]),
                       ["b", "dup", "dup", "a"])
    }
}
