// Per-model invariants — direction glyphs, sample-stream diagnostic
// span, and the canonical AX verb set the dispatcher accepts.

import XCTest
import CoreGraphics
@testable import StrokeCore

final class ModelsTests: XCTestCase {

    func testDirectionArrows() {
        XCTAssertEqual(Direction.left.arrow, "←")
        XCTAssertEqual(Direction.up.arrow, "↑")
        XCTAssertEqual(Direction.right.arrow, "→")
        XCTAssertEqual(Direction.down.arrow, "↓")
    }

    func testSampleSpan() {
        // span = largest |dx|, |dy| from the first sample. Drives the
        // `samples=N, max|dx|=…, max|dy|=…` diagnostic in --record and
        // the no-stroke-recognised log line.
        let samples = [
            Sample(p: CGPoint(x: 0, y: 0), t: 0),
            Sample(p: CGPoint(x: 12, y: -4), t: 0.01),
            Sample(p: CGPoint(x: -3, y: 10), t: 0.02),
        ]
        let (dx, dy) = samples.span
        XCTAssertEqual(dx, 12)
        XCTAssertEqual(dy, 10)
    }

    func testSampleSpanEmptyAndSingle() {
        let empty: [Sample] = []
        XCTAssertEqual(empty.span.dx, 0)
        XCTAssertEqual(empty.span.dy, 0)

        let single = [Sample(p: CGPoint(x: 5, y: 5), t: 0)]
        XCTAssertEqual(single.span.dx, 0)
        XCTAssertEqual(single.span.dy, 0)
    }

    func testActionAxVerbs() {
        // The single source of truth the config parser drops typos
        // against and the dispatcher's switch uses. Drift between the
        // two would silently load no-op rules.
        XCTAssertEqual(Action.axVerbs, ["close", "minimize", "zoom", "raise"])
    }
}
