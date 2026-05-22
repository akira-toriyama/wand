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
