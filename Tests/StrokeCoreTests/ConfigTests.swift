// StrokeConfig.parse — clamps, defaults, rule shape, overlay parsing.
// TOML parser primitives live in TOMLTests; this file targets the
// `parse(_:)` orchestrator and its per-key clamp/drop semantics.

import XCTest
@testable import StrokeCore

final class ConfigTests: XCTestCase {

    // MARK: - Trigger + modifier fallbacks

    func testTriggerButtonAndModifierFallback() {
        // Unknown button → .right (safe default). Mixed-validity
        // modifier list → only the known ones (compactMap typo
        // tolerance).
        let cfg = StrokeConfig.parse("""
        [trigger]
        button = "wat"
        modifiers = ["xyz", "cmd"]
        """)
        XCTAssertEqual(cfg.trigger.button, .right)
        XCTAssertEqual(cfg.trigger.modifiers, [.cmd])
    }

    // MARK: - [recognition] clamps

    func testMinStrokePxClampLowHighDefault() {
        XCTAssertEqual(StrokeConfig.parse("").minStrokePx, 16)
        XCTAssertEqual(StrokeConfig.parse(
            "[recognition]\nmin-stroke-px = 2").minStrokePx, 4)   // low clamp
        XCTAssertEqual(StrokeConfig.parse(
            "[recognition]\nmin-stroke-px = 999").minStrokePx, 200) // high clamp
    }

    func testMaxSegmentMs() {
        XCTAssertEqual(StrokeConfig.parse("").maxSegmentMs, 0)
        XCTAssertEqual(StrokeConfig.parse(
            "[recognition]\nmax-segment-ms = 1500").maxSegmentMs, 1500)
        XCTAssertEqual(StrokeConfig.parse(
            "[recognition]\nmax-segment-ms = 50").maxSegmentMs, 100)
        XCTAssertEqual(StrokeConfig.parse(
            "[recognition]\nmax-segment-ms = 999999").maxSegmentMs, 60000)
    }

    func testMaxStrokeMsLegacyAlias() {
        // `max-stroke-ms` is the deprecated alias — still parsed for
        // backwards compatibility, with a `config: deprecated` log line.
        XCTAssertEqual(StrokeConfig.parse(
            "[recognition]\nmax-stroke-ms = 1500").maxSegmentMs, 1500)
        // New key wins when both are present.
        let both = StrokeConfig.parse("""
        [recognition]
        max-stroke-ms = 800
        max-segment-ms = 1500
        """)
        XCTAssertEqual(both.maxSegmentMs, 1500)
    }

    func testCancelReversals() {
        XCTAssertEqual(StrokeConfig.parse("").cancelReversals, 2)
        XCTAssertEqual(StrokeConfig.parse(
            "[recognition]\ncancel-reversals = 3").cancelReversals, 3)
        XCTAssertEqual(StrokeConfig.parse(
            "[recognition]\ncancel-reversals = 0").cancelReversals, 0)
        XCTAssertEqual(StrokeConfig.parse(
            "[recognition]\ncancel-reversals = 999").cancelReversals, 20)
    }

    func testCancelWindowMs() {
        XCTAssertEqual(StrokeConfig.parse("").cancelWindowMs, 500)
        XCTAssertEqual(StrokeConfig.parse(
            "[recognition]\ncancel-window-ms = 800").cancelWindowMs, 800)
        XCTAssertEqual(StrokeConfig.parse(
            "[recognition]\ncancel-window-ms = 0").cancelWindowMs, 0)
        XCTAssertEqual(StrokeConfig.parse(
            "[recognition]\ncancel-window-ms = 50").cancelWindowMs, 100)
        XCTAssertEqual(StrokeConfig.parse(
            "[recognition]\ncancel-window-ms = 99999").cancelWindowMs, 5000)
    }

    func testExcludeAppsParsed() {
        let cfg = StrokeConfig.parse("""
        [recognition]
        exclude-apps = ["com.apple.dt.Xcode", "com.example.foo"]
        """)
        XCTAssertEqual(cfg.excludeApps,
                       ["com.apple.dt.Xcode", "com.example.foo"])
    }

    // MARK: - [overlay]

    func testOverlayConfigParsed() {
        let cfg = StrokeConfig.parse("""
        [overlay]
        enabled = false
        color = "#ff0000"
        color-no-match = "orange"
        width = 8
        """)
        XCTAssertFalse(cfg.overlayEnabled)
        XCTAssertEqual(cfg.overlayColor, "#ff0000")
        XCTAssertEqual(cfg.overlayColorNoMatch, "orange")
        XCTAssertEqual(cfg.overlayWidth, 8)
    }

    func testOverlayDefaultsWhenAbsent() {
        let cfg = StrokeConfig.parse("[trigger]\nbutton = \"right\"")
        XCTAssertTrue(cfg.overlayEnabled)
        XCTAssertEqual(cfg.overlayColor, "#3b82f6")
        XCTAssertEqual(cfg.overlayColorNoMatch, "#ef4444")
        XCTAssertEqual(cfg.overlayWidth, 3)
    }

    func testOverlayWidthClamped() {
        XCTAssertEqual(StrokeConfig.parse(
            "[overlay]\nwidth = 999").overlayWidth, 40)
        XCTAssertEqual(StrokeConfig.parse(
            "[overlay]\nwidth = 0").overlayWidth, 1)
    }

    func testOverlayBadgeKnobs() {
        // Defaults — every overlay knob is opt-out so a config that
        // doesn't mention them keeps the rich HUD.
        let def = StrokeConfig.parse("")
        XCTAssertTrue(def.overlayBadgeEnabled)
        XCTAssertTrue(def.overlayBlurEnabled)
        XCTAssertTrue(def.overlayAnimEnabled)
        XCTAssertEqual(def.overlayBadgeSize, 56)

        // Explicit off + custom size — and the size clamps so a typo
        // can't pin the badge to nothing.
        let custom = StrokeConfig.parse("""
        [overlay]
        badge-enabled = false
        blur-enabled = false
        anim-enabled = false
        badge-size = 999
        """)
        XCTAssertFalse(custom.overlayBadgeEnabled)
        XCTAssertFalse(custom.overlayBlurEnabled)
        XCTAssertFalse(custom.overlayAnimEnabled)
        XCTAssertEqual(custom.overlayBadgeSize, 96)

        XCTAssertEqual(StrokeConfig.parse(
            "[overlay]\nbadge-size = 4").overlayBadgeSize, 32)
    }

    // MARK: - [[rules]]

    func testConfigParsesArrayOfTables() {
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
        // Typo'd verb drops at parse time (visible to --validate)
        // rather than loading and silently no-op'ing at dispatch.
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
        if case .ax(let v) = cfg.rules[0].action {
            XCTAssertEqual(v, "zoom")   // normalised to lowercase
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

    func testRuleWithConsecutiveDuplicatesDrops() {
        // The recogniser coalesces same-direction segments, so a rule
        // pattern like `DRR` can never fire. Parser drops it loudly
        // rather than letting it load and silently no-op.
        let toml = """
        [[rules]]
        pattern = "DRR"
        action-type = "key"
        action-keys = "cmd+w"

        [[rules]]
        pattern = "DR"
        action-type = "key"
        action-keys = "cmd+w"
        """
        let cfg = StrokeConfig.parse(toml)
        XCTAssertEqual(cfg.rules.count, 1)
        XCTAssertEqual(cfg.rules[0].pattern, "DR")
    }

    func testRuleMissingPatternOrActionDrops() {
        // All three should drop: empty pattern, missing action-keys
        // for type=key, unknown action-type.
        let toml = """
        [[rules]]
        pattern = ""
        action-type = "key"
        action-keys = "cmd+w"

        [[rules]]
        pattern = "L"
        action-type = "key"
        action-keys = ""

        [[rules]]
        pattern = "R"
        action-type = "thing"
        action-keys = "cmd+w"

        [[rules]]
        pattern = "U"
        action-type = "key"
        action-keys = "cmd+r"
        """
        let cfg = StrokeConfig.parse(toml)
        XCTAssertEqual(cfg.rules.count, 1)
        XCTAssertEqual(cfg.rules[0].pattern, "U")
    }

    func testRuleShellAction() {
        let toml = """
        [[rules]]
        pattern = "L"
        action-type = "shell"
        action-cmd = "open -a Terminal"
        """
        let cfg = StrokeConfig.parse(toml)
        XCTAssertEqual(cfg.rules.count, 1)
        if case .shell(let c) = cfg.rules[0].action {
            XCTAssertEqual(c, "open -a Terminal")
        } else { XCTFail("expected .shell") }
    }
}
