// Pure-logic tests for the recognition pipeline + the reversal
// counter that drives the adapter's scribble-to-cancel detector.
// XCTest needs Xcode; CommandLineTools alone can't run these — CI
// covers them on an Xcode-bearing macOS image.

import XCTest
import CoreGraphics
@testable import StrokeCore

final class RecognitionTests: XCTestCase {

    // MARK: - recognize(samples:minStrokePx:)

    func testStraightDownThenRight() {
        // Explicit `[Sample]` annotation needed — without it Swift 6's
        // type checker bails on the two chained closures + `+`
        // ("compiler is unable to type-check this expression in
        // reasonable time"). Annotating breaks the inference into two
        // independent sub-problems.
        let down: [Sample] = (0...20).map { i in
            Sample(p: CGPoint(x: 0, y: -CGFloat(i) * 5),
                   t: TimeInterval(i) * 0.01)
        }
        let right: [Sample] = (1...20).map { i in
            Sample(p: CGPoint(x: CGFloat(i) * 5, y: -100),
                   t: TimeInterval(20 + i) * 0.01)
        }
        let dirs = Recognition.recognize(samples: down + right,
                                          minStrokePx: 16)
        XCTAssertEqual(dirs.patternString, "DR")
    }

    func testShortStrokeBelowThreshold() {
        let samples = [
            Sample(p: CGPoint(x: 0, y: 0), t: 0),
            Sample(p: CGPoint(x: 5, y: 0), t: 0.01),
        ]
        XCTAssertTrue(Recognition.recognize(samples: samples, minStrokePx: 16).isEmpty)
    }

    func testRecognitionCoalescesConsecutiveDuplicates() {
        // Three +20px right jumps each cross the threshold individually
        // but the recognizer collapses them into one `.right` — every
        // multi-segment pattern match depends on this.
        let samples: [Sample] = (0...3).map { i in
            Sample(p: CGPoint(x: CGFloat(i) * 20, y: 0),
                   t: TimeInterval(i) * 0.01)
        }
        XCTAssertEqual(Recognition.recognize(samples: samples,
                                              minStrokePx: 16),
                       [.right])
    }

    func testRecognitionExactThresholdEmits() {
        // The threshold guard is `max(absX, absY) >= threshold`, so
        // hitting it on the nose must emit. An off-by-one to `>` would
        // silently lose the at-threshold case.
        let samples = [
            Sample(p: .zero, t: 0),
            Sample(p: CGPoint(x: 16, y: 0), t: 0.01),
        ]
        XCTAssertEqual(Recognition.recognize(samples: samples,
                                              minStrokePx: 16),
                       [.right])
    }

    func testRecognitionMinStrokePxZeroReturnsEmpty() {
        // `minStrokePx <= 0` short-circuits to []. A regression would
        // emit a direction on every sample (threshold of 0 always met).
        let samples = [
            Sample(p: .zero, t: 0),
            Sample(p: CGPoint(x: 100, y: 0), t: 0.01),
        ]
        XCTAssertTrue(Recognition.recognize(samples: samples,
                                             minStrokePx: 0).isEmpty)
    }

    func testRecognitionDominantAxisTieGoesHorizontal() {
        // `absX >= absY` puts ties on the horizontal axis. The
        // tie-breaker is load-bearing for 45° drags — flipping it
        // would reclassify diagonals as vertical.
        let samples = [
            Sample(p: .zero, t: 0),
            Sample(p: CGPoint(x: 20, y: 20), t: 0.01),
        ]
        XCTAssertEqual(Recognition.recognize(samples: samples,
                                              minStrokePx: 16),
                       [.right])
    }

    func testRecognitionAnchorResetsAfterEmit() {
        // After a 20px right jump, a further 10px right (only 10px
        // since the anchor was reset, even though 30px from origin)
        // must NOT emit a second direction. Without anchor-reset the
        // recognizer would re-fire on every sample past threshold.
        let samples = [
            Sample(p: .zero, t: 0),
            Sample(p: CGPoint(x: 20, y: 0), t: 0.01),
            Sample(p: CGPoint(x: 30, y: 0), t: 0.02),
        ]
        XCTAssertEqual(Recognition.recognize(samples: samples,
                                              minStrokePx: 16),
                       [.right])
    }

    func testRecognitionYAxisGrowsUp() {
        // Adapter feeds `p.y` Y-up (CGEvent.location Y-down sign-flipped
        // in EventTap.flipY). `dy > 0 ⇒ .up`. Pins the convention
        // CLAUDE.md flags as load-bearing.
        let samples = [
            Sample(p: .zero, t: 0),
            Sample(p: CGPoint(x: 0, y: 20), t: 0.01),
        ]
        XCTAssertEqual(Recognition.recognize(samples: samples,
                                              minStrokePx: 16),
                       [.up])
    }

    // MARK: - reversals (drives scribble-to-cancel)

    func testReversalsCountsOppositePairs() {
        XCTAssertEqual(Recognition.reversals("LR"), 1)
        XCTAssertEqual(Recognition.reversals("LRL"), 2)
        XCTAssertEqual(Recognition.reversals("LRLR"), 3)
    }

    func testReversalsIgnoresOrthogonal() {
        // 90° turns are not reversals — `DU` is one reversal but
        // `DR` (90°) is zero. The user's `DRU` rule must not
        // accidentally trip scribble-cancel.
        XCTAssertEqual(Recognition.reversals("DR"), 0)
        XCTAssertEqual(Recognition.reversals("DRU"), 0)
        XCTAssertEqual(Recognition.reversals("LU"), 0)
    }

    func testReversalsEmptyAndSingle() {
        XCTAssertEqual(Recognition.reversals(""), 0)
        XCTAssertEqual(Recognition.reversals("L"), 0)
    }

    func testReversalsRespectsAllFourAxes() {
        // Both axes pin their own reversal pairs.
        XCTAssertEqual(Recognition.reversals("UD"), 1)
        XCTAssertEqual(Recognition.reversals("DU"), 1)
        XCTAssertEqual(Recognition.reversals("LR"), 1)
        XCTAssertEqual(Recognition.reversals("RL"), 1)
        // Mixed-axis sequences should still count only the same-axis
        // adjacent reversals.
        XCTAssertEqual(Recognition.reversals("LRDU"), 2)
    }
}
