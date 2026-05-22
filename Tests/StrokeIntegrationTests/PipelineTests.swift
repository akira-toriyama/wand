// End-to-end pipeline test: SyntheticMouseSource (StrokeAdapterTest)
// → Recognition → Matcher, the same path the Controller runs minus
// the macOS-only Dispatch. Exercises the test adapter against Core
// exactly as docs/architecture.md advertises it, without a real
// CGEventTap or AX permission.
//
// XCTest needs Xcode (CommandLineTools can't run it); this compiles
// in `swift build --build-tests` and runs in CI on the macOS runner.

import XCTest
import CoreGraphics
@testable import StrokeCore
import StrokeAdapterTest

// File-scope helpers (not methods) so the @Sendable stroke handler
// can call them without capturing the non-Sendable XCTestCase `self`.

/// A "down then right" stroke in the Y-up convention Recognition
/// expects (the adapter's flipY produces this for real input).
private func downThenRight() -> [Sample] {
    let down: [Sample] = (0...20).map { i in
        Sample(p: CGPoint(x: 0, y: -CGFloat(i) * 5),
               t: TimeInterval(i) * 0.01)
    }
    let right: [Sample] = (1...20).map { i in
        Sample(p: CGPoint(x: CGFloat(i) * 5, y: -100),
               t: TimeInterval(20 + i) * 0.01)
    }
    return down + right
}

/// Mirror of Controller.handle minus the macOS Dispatch: recognise
/// the stroke, then match against the rules for the event's
/// cursor-anchored target.
private func matchStroke(_ event: StrokeEvent, _ rules: [Rule]) -> Rule? {
    let dirs = Recognition.recognize(samples: event.samples, minStrokePx: 16)
    guard !dirs.isEmpty else { return nil }
    return Matcher.match(pattern: dirs.patternString,
                         bundleID: event.target.bundleID, rules: rules)
}

/// Sendable sink for the @Sendable handler to record into — the
/// synthetic source delivers synchronously on `flush()`, so the
/// unchecked annotation is safe (no real concurrency).
private final class Recorder: @unchecked Sendable {
    var matched: Rule?
    var deliveries = 0
}

final class PipelineTests: XCTestCase {

    func testSyntheticSourceDrivesRecognitionAndMatch() {
        let rules = [
            Rule(name: "close tab", pattern: "DR",
                 apps: ["*chrome*"], action: .key("cmd+w")),
            Rule(name: "minimize", pattern: "L",
                 apps: ["*"], action: .ax("minimize")),
        ]
        let rec = Recorder()
        let source = SyntheticMouseSource()
        source.start { event in
            rec.deliveries += 1
            rec.matched = matchStroke(event, rules)
        }

        source.enqueue(
            target: Target(pid: 123, bundleID: "com.google.Chrome",
                           title: "Tab", frame: .zero, windowID: 1),
            samples: downThenRight())
        source.flush()

        XCTAssertEqual(rec.deliveries, 1)
        XCTAssertEqual(rec.matched?.name, "close tab")
    }

    func testAppFilterRejectsNonMatchingTarget() {
        let rules = [
            Rule(name: "close tab", pattern: "DR",
                 apps: ["*chrome*"], action: .key("cmd+w")),
        ]
        let rec = Recorder()
        let source = SyntheticMouseSource()
        source.start { event in rec.matched = matchStroke(event, rules) }

        // Same DR stroke, but the cursor-anchored target is Finder —
        // the chrome-only rule must not fire.
        source.enqueue(
            target: Target(pid: 9, bundleID: "com.apple.finder",
                           title: "", frame: .zero, windowID: 2),
            samples: downThenRight())
        source.flush()

        XCTAssertNil(rec.matched)
    }

    func testTooShortStrokeProducesNoMatch() {
        let rules = [
            Rule(name: "close tab", pattern: "DR",
                 apps: ["*"], action: .key("cmd+w")),
        ]
        let rec = Recorder()
        let source = SyntheticMouseSource()
        source.start { event in rec.matched = matchStroke(event, rules) }

        source.enqueue(
            target: Target(pid: 1, bundleID: "com.google.Chrome",
                           title: "", frame: .zero, windowID: 3),
            samples: [Sample(p: .zero, t: 0),
                      Sample(p: CGPoint(x: 4, y: 0), t: 0.01)])  // < minStrokePx
        source.flush()

        XCTAssertNil(rec.matched)
    }
}
