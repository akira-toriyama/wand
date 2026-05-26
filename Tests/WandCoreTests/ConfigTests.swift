// WandConfig.parse — clamps, defaults, rule shape, overlay parsing.
// TOML parser primitives live in TOMLTests; this file targets the
// `parse(_:)` orchestrator and its per-key clamp/drop semantics.

import XCTest
@testable import WandCore

final class ConfigTests: XCTestCase {

    // MARK: - Trigger + modifier fallbacks

    func testTriggerButtonAndModifierFallback() {
        // Unknown button → .right (safe default). Mixed-validity
        // modifier list → only the known ones (compactMap typo
        // tolerance).
        let cfg = WandConfig.parse("""
        [gesture]
        button = "wat"
        modifiers = ["xyz", "cmd"]
        """)
        XCTAssertEqual(cfg.trigger.button, .right)
        XCTAssertEqual(cfg.trigger.modifiers, [.cmd])
    }

    // MARK: - [gesture] clamps

    func testMinStrokePxClampLowHighDefault() {
        XCTAssertEqual(WandConfig.parse("").minStrokePx, 16)
        XCTAssertEqual(WandConfig.parse(
            "[gesture]\nmin-stroke-px = 2").minStrokePx, 4)   // low clamp
        XCTAssertEqual(WandConfig.parse(
            "[gesture]\nmin-stroke-px = 999").minStrokePx, 200) // high clamp
    }

    func testMaxSegmentMs() {
        XCTAssertEqual(WandConfig.parse("").maxSegmentMs, 0)
        XCTAssertEqual(WandConfig.parse(
            "[gesture]\nmax-segment-ms = 1500").maxSegmentMs, 1500)
        XCTAssertEqual(WandConfig.parse(
            "[gesture]\nmax-segment-ms = 50").maxSegmentMs, 100)
        XCTAssertEqual(WandConfig.parse(
            "[gesture]\nmax-segment-ms = 999999").maxSegmentMs, 60000)
    }

    func testMaxStrokeMsRemovedInV2() {
        // `max-stroke-ms` was removed in v2.0. A stale config that
        // still uses it gets the default (0 = no timeout) and a
        // log line — it must NOT silently map to maxSegmentMs.
        XCTAssertEqual(WandConfig.parse(
            "[gesture]\nmax-stroke-ms = 1500").maxSegmentMs, 0)
    }

    func testCancelReversals() {
        XCTAssertEqual(WandConfig.parse("").cancelReversals, 2)
        XCTAssertEqual(WandConfig.parse(
            "[gesture]\ncancel-reversals = 3").cancelReversals, 3)
        XCTAssertEqual(WandConfig.parse(
            "[gesture]\ncancel-reversals = 0").cancelReversals, 0)
        XCTAssertEqual(WandConfig.parse(
            "[gesture]\ncancel-reversals = 999").cancelReversals, 20)
    }

    func testCancelWindowMs() {
        XCTAssertEqual(WandConfig.parse("").cancelWindowMs, 500)
        XCTAssertEqual(WandConfig.parse(
            "[gesture]\ncancel-window-ms = 800").cancelWindowMs, 800)
        XCTAssertEqual(WandConfig.parse(
            "[gesture]\ncancel-window-ms = 0").cancelWindowMs, 0)
        XCTAssertEqual(WandConfig.parse(
            "[gesture]\ncancel-window-ms = 50").cancelWindowMs, 100)
        XCTAssertEqual(WandConfig.parse(
            "[gesture]\ncancel-window-ms = 99999").cancelWindowMs, 5000)
    }

    func testExcludeAppsParsed() {
        let cfg = WandConfig.parse("""
        [exclude]
        apps = ["com.apple.dt.Xcode", "com.example.foo"]
        """)
        XCTAssertEqual(cfg.excludeApps,
                       ["com.apple.dt.Xcode", "com.example.foo"])
    }

    // MARK: - [gesture.overlay]

    func testOverlayConfigParsed() {
        let cfg = WandConfig.parse("""
        [gesture.overlay]
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
        let cfg = WandConfig.parse("[gesture]\nbutton = \"right\"")
        XCTAssertTrue(cfg.overlayEnabled)
        XCTAssertEqual(cfg.overlayColor, "#3b82f6")
        XCTAssertEqual(cfg.overlayColorNoMatch, "#ef4444")
        XCTAssertEqual(cfg.overlayWidth, 3)
    }

    func testOverlayWidthClamped() {
        XCTAssertEqual(WandConfig.parse(
            "[gesture.overlay]\nwidth = 999").overlayWidth, 40)
        XCTAssertEqual(WandConfig.parse(
            "[gesture.overlay]\nwidth = 0").overlayWidth, 1)
    }

    func testOverlayBadgeKnobs() {
        // Defaults — every overlay knob is opt-out so a config that
        // doesn't mention them keeps the rich HUD.
        let def = WandConfig.parse("")
        XCTAssertTrue(def.overlayBadgeEnabled)
        XCTAssertTrue(def.overlayBlurEnabled)
        XCTAssertTrue(def.overlayAnimEnabled)
        XCTAssertEqual(def.overlayBadgeSize, 56)

        // Explicit off + custom size — and the size clamps so a typo
        // can't pin the badge to nothing.
        let custom = WandConfig.parse("""
        [gesture.overlay]
        badge-enabled = false
        blur-enabled = false
        anim-enabled = false
        badge-size = 999
        """)
        XCTAssertFalse(custom.overlayBadgeEnabled)
        XCTAssertFalse(custom.overlayBlurEnabled)
        XCTAssertFalse(custom.overlayAnimEnabled)
        XCTAssertEqual(custom.overlayBadgeSize, 96)

        XCTAssertEqual(WandConfig.parse(
            "[gesture.overlay]\nbadge-size = 4").overlayBadgeSize, 32)
    }

    // MARK: - [[gesture.rule]]

    func testConfigParsesArrayOfTables() {
        let toml = """
        [gesture]
        button = "right"
        modifiers = ["cmd"]

        [gesture]
        min-stroke-px = 20

        [[gesture.rule]]
        name = "close tab"
        pattern = "DR"
        apps = ["*chrome*", "*safari*"]
        action-type = "key"
        action-keys = "cmd+w"

        [[gesture.rule]]
        name = "minimize"
        pattern = "L"
        apps = ["*"]
        action-type = "ax"
        action-verb = "minimize"
        """
        let cfg = WandConfig.parse(toml)
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
        [[gesture.rule]]
        pattern = "L"
        action-type = "ax"
        action-verb = "clsoe"

        [[gesture.rule]]
        pattern = "R"
        action-type = "ax"
        action-verb = "ZOOM"
        """
        let cfg = WandConfig.parse(toml)
        XCTAssertEqual(cfg.rules.count, 1, "typo'd verb rule should drop")
        XCTAssertEqual(cfg.rules[0].pattern, "R")
        if case .ax(let v) = cfg.rules[0].action {
            XCTAssertEqual(v, "zoom")   // normalised to lowercase
        } else { XCTFail("expected .ax") }
    }

    func testRuleNameDefaultsToPattern() {
        let toml = """
        [[gesture.rule]]
        pattern = "DR"
        action-type = "key"
        action-keys = "cmd+w"
        """
        let cfg = WandConfig.parse(toml)
        XCTAssertEqual(cfg.rules.count, 1)
        XCTAssertEqual(cfg.rules[0].name, "DR")
        XCTAssertEqual(cfg.rules[0].apps, ["*"])
    }

    func testRuleWithConsecutiveDuplicatesDrops() {
        // The recogniser coalesces same-direction segments, so a rule
        // pattern like `DRR` can never fire. Parser drops it loudly
        // rather than letting it load and silently no-op.
        let toml = """
        [[gesture.rule]]
        pattern = "DRR"
        action-type = "key"
        action-keys = "cmd+w"

        [[gesture.rule]]
        pattern = "DR"
        action-type = "key"
        action-keys = "cmd+w"
        """
        let cfg = WandConfig.parse(toml)
        XCTAssertEqual(cfg.rules.count, 1)
        XCTAssertEqual(cfg.rules[0].pattern, "DR")
    }

    func testRuleMissingPatternOrActionDrops() {
        // All three should drop: empty pattern, missing action-keys
        // for type=key, unknown action-type.
        let toml = """
        [[gesture.rule]]
        pattern = ""
        action-type = "key"
        action-keys = "cmd+w"

        [[gesture.rule]]
        pattern = "L"
        action-type = "key"
        action-keys = ""

        [[gesture.rule]]
        pattern = "R"
        action-type = "thing"
        action-keys = "cmd+w"

        [[gesture.rule]]
        pattern = "U"
        action-type = "key"
        action-keys = "cmd+r"
        """
        let cfg = WandConfig.parse(toml)
        XCTAssertEqual(cfg.rules.count, 1)
        XCTAssertEqual(cfg.rules[0].pattern, "U")
    }

    func testRuleShellAction() {
        let toml = """
        [[gesture.rule]]
        pattern = "L"
        action-type = "shell"
        action-cmd = "open -a Terminal"
        """
        let cfg = WandConfig.parse(toml)
        XCTAssertEqual(cfg.rules.count, 1)
        if case .shell(let c) = cfg.rules[0].action {
            XCTAssertEqual(c, "open -a Terminal")
        } else { XCTFail("expected .shell") }
    }
}
