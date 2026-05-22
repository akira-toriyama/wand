// Pure-logic tests for the recognition + matcher pipeline.
// XCTest runs in CI (Xcode-bearing macOS image); CommandLineTools
// alone can't run these — same constraint facet works under.

import XCTest
import CoreGraphics
@testable import StrokeCore

final class RecognitionTests: XCTestCase {

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

    func testMatcherFirstWins() {
        let rules = [
            Rule(name: "A", pattern: "D", apps: ["*"], action: .key("cmd+1")),
            Rule(name: "B", pattern: "D", apps: ["*"], action: .key("cmd+2")),
        ]
        XCTAssertEqual(Matcher.match(pattern: "D",
                                     bundleID: "com.apple.Finder",
                                     rules: rules)?.name, "A")
    }

    func testMatcherAppExclusion() {
        let rules = [
            Rule(name: "X", pattern: "D",
                 apps: ["*", "!com.apple.dt.Xcode"],
                 action: .key("cmd+w"))
        ]
        XCTAssertNil(Matcher.match(pattern: "D",
                                   bundleID: "com.apple.dt.Xcode",
                                   rules: rules))
        XCTAssertNotNil(Matcher.match(pattern: "D",
                                      bundleID: "com.apple.Finder",
                                      rules: rules))
    }

    func testCandidatesByPrefixAndApp() {
        let rules = [
            Rule(name: "close tab", pattern: "DL", apps: ["*chrome*"], action: .key("cmd+w")),
            Rule(name: "close window", pattern: "DRU", apps: ["*"], action: .ax("close")),
            Rule(name: "minimize", pattern: "L", apps: ["*"], action: .ax("minimize")),
        ]
        // "D" reaches both DL (chrome-only) and DRU on Chrome…
        XCTAssertEqual(
            Set(Matcher.candidates(prefix: "D", bundleID: "com.google.Chrome",
                                   rules: rules).map(\.name)),
            ["close tab", "close window"])
        // …but only DRU on a non-chrome app (app filter applies).
        XCTAssertEqual(
            Matcher.candidates(prefix: "D", bundleID: "com.apple.finder",
                               rules: rules).map(\.name),
            ["close window"])
        // Exact pattern is a prefix of itself.
        XCTAssertEqual(
            Matcher.candidates(prefix: "DL", bundleID: "com.google.Chrome",
                               rules: rules).map(\.name),
            ["close tab"])
        // Dead end → nothing.
        XCTAssertTrue(
            Matcher.candidates(prefix: "X", bundleID: "com.google.Chrome",
                               rules: rules).isEmpty)
    }

    func testDirectionArrows() {
        XCTAssertEqual(Direction.left.arrow, "←")
        XCTAssertEqual(Direction.up.arrow, "↑")
        XCTAssertEqual(Direction.right.arrow, "→")
        XCTAssertEqual(Direction.down.arrow, "↓")
    }

    func testGlobWildcards() {
        XCTAssertTrue(Matcher.glob("*chrome*", "com.google.chrome"))
        XCTAssertTrue(Matcher.glob("com.apple.?afari", "com.apple.safari"))
        XCTAssertFalse(Matcher.glob("com.apple.safari", "com.google.chrome"))
    }

    func testTOMLArrayOfTables() {
        let toml = """
        [trigger]
        button = "right"
        modifiers = ["cmd"]

        [recognition]
        min-stroke-px = 20

        [[rules]]
        name = "close tab"
        pattern = "DR"
        apps = ["*chrome*", "*safari*"]
        action-type = "key"
        action-keys = "cmd+w"

        [[rules]]
        name = "minimize"
        pattern = "L"
        apps = ["*"]
        action-type = "ax"
        action-verb = "minimize"
        """
        let cfg = StrokeConfig.parse(toml)
        XCTAssertEqual(cfg.trigger.button, .right)
        XCTAssertEqual(cfg.trigger.modifiers, [.cmd])
        XCTAssertEqual(cfg.minStrokePx, 20)
        XCTAssertEqual(cfg.rules.count, 2)
        XCTAssertEqual(cfg.rules[0].pattern, "DR")
        if case .key(let k) = cfg.rules[0].action {
            XCTAssertEqual(k, "cmd+w")
        } else { XCTFail("expected .key") }
        if case .ax(let v) = cfg.rules[1].action {
            XCTAssertEqual(v, "minimize")
        } else { XCTFail("expected .ax") }
    }

    func testUnknownAXVerbDropsRule() {
        // A typo'd verb must drop the rule at parse time (visible to
        // --validate) rather than load and silently no-op at dispatch.
        let toml = """
        [[rules]]
        pattern = "L"
        action-type = "ax"
        action-verb = "clsoe"

        [[rules]]
        pattern = "R"
        action-type = "ax"
        action-verb = "ZOOM"
        """
        let cfg = StrokeConfig.parse(toml)
        XCTAssertEqual(cfg.rules.count, 1, "typo'd verb rule should drop")
        XCTAssertEqual(cfg.rules[0].pattern, "R")
        // Verb is normalised to lowercase so dispatch matching is stable.
        if case .ax(let v) = cfg.rules[0].action {
            XCTAssertEqual(v, "zoom")
        } else { XCTFail("expected .ax") }
    }

    func testOverlayConfigParsed() {
        let toml = """
        [overlay]
        enabled = false
        color = "#ff0000"
        color-no-match = "orange"
        width = 8
        """
        let cfg = StrokeConfig.parse(toml)
        XCTAssertFalse(cfg.overlayEnabled)
        XCTAssertEqual(cfg.overlayColor, "#ff0000")
        XCTAssertEqual(cfg.overlayColorNoMatch, "orange")
        XCTAssertEqual(cfg.overlayWidth, 8)
    }

    func testOverlayDefaultsWhenAbsent() {
        let cfg = StrokeConfig.parse("[trigger]\nbutton = \"right\"")
        XCTAssertTrue(cfg.overlayEnabled)          // default on
        XCTAssertEqual(cfg.overlayColor, "#3b82f6")
        XCTAssertEqual(cfg.overlayColorNoMatch, "#ef4444")
        XCTAssertEqual(cfg.overlayWidth, 3)
    }

    func testOverlayWidthClamped() {
        let cfg = StrokeConfig.parse("[overlay]\nwidth = 999")
        XCTAssertEqual(cfg.overlayWidth, 40)       // clamped 1..40
    }

    func testMaxStrokeMs() {
        XCTAssertEqual(StrokeConfig.parse("").maxStrokeMs, 0)               // default off
        XCTAssertEqual(StrokeConfig.parse(
            "[recognition]\nmax-stroke-ms = 1500").maxStrokeMs, 1500)
        XCTAssertEqual(StrokeConfig.parse(
            "[recognition]\nmax-stroke-ms = 50").maxStrokeMs, 100)          // clamp low
        XCTAssertEqual(StrokeConfig.parse(
            "[recognition]\nmax-stroke-ms = 999999").maxStrokeMs, 60000)    // clamp high
    }

    func testCancelReversals() {
        XCTAssertEqual(StrokeConfig.parse("").cancelReversals, 2)            // default on
        XCTAssertEqual(StrokeConfig.parse(
            "[recognition]\ncancel-reversals = 3").cancelReversals, 3)
        XCTAssertEqual(StrokeConfig.parse(
            "[recognition]\ncancel-reversals = 0").cancelReversals, 0)       // off
        XCTAssertEqual(StrokeConfig.parse(
            "[recognition]\ncancel-reversals = 999").cancelReversals, 20)    // clamp high
    }

    func testCancelWindowMs() {
        XCTAssertEqual(StrokeConfig.parse("").cancelWindowMs, 500)           // default
        XCTAssertEqual(StrokeConfig.parse(
            "[recognition]\ncancel-window-ms = 800").cancelWindowMs, 800)
        XCTAssertEqual(StrokeConfig.parse(
            "[recognition]\ncancel-window-ms = 0").cancelWindowMs, 0)        // any speed
        XCTAssertEqual(StrokeConfig.parse(
            "[recognition]\ncancel-window-ms = 50").cancelWindowMs, 100)     // clamp low
        XCTAssertEqual(StrokeConfig.parse(
            "[recognition]\ncancel-window-ms = 99999").cancelWindowMs, 5000) // clamp high
    }

    func testRuleNameDefaultsToPattern() {
        let toml = """
        [[rules]]
        pattern = "DR"
        action-type = "key"
        action-keys = "cmd+w"
        """
        let cfg = StrokeConfig.parse(toml)
        XCTAssertEqual(cfg.rules.count, 1)
        XCTAssertEqual(cfg.rules[0].name, "DR")
        XCTAssertEqual(cfg.rules[0].apps, ["*"])
    }
}
