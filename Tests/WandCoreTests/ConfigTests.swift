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

    // MARK: - [gesture.recognition] clamps

    func testMinStrokePxClampLowHighDefault() {
        XCTAssertEqual(WandConfig.parse("").recognition.minStrokePx, 16)
        XCTAssertEqual(WandConfig.parse(
            "[gesture.recognition]\nmin-stroke-px = 2").recognition.minStrokePx, 4)
        XCTAssertEqual(WandConfig.parse(
            "[gesture.recognition]\nmin-stroke-px = 999").recognition.minStrokePx, 200)
    }

    func testMaxSegmentMs() {
        XCTAssertEqual(WandConfig.parse("").recognition.maxSegmentMs, 0)
        XCTAssertEqual(WandConfig.parse(
            "[gesture.recognition]\nmax-segment-ms = 1500").recognition.maxSegmentMs, 1500)
        XCTAssertEqual(WandConfig.parse(
            "[gesture.recognition]\nmax-segment-ms = 50").recognition.maxSegmentMs, 100)
        XCTAssertEqual(WandConfig.parse(
            "[gesture.recognition]\nmax-segment-ms = 999999").recognition.maxSegmentMs, 60000)
    }

    func testMaxStrokeMsRemovedInV2() {
        // `max-stroke-ms` was removed in v2.0. A stale config that
        // still uses it gets the default (0 = no timeout) and a
        // log line — it must NOT silently map to maxSegmentMs.
        XCTAssertEqual(WandConfig.parse(
            "[gesture.recognition]\nmax-stroke-ms = 1500").recognition.maxSegmentMs, 0)
    }

    func testCancelReversals() {
        XCTAssertEqual(WandConfig.parse("").recognition.cancelReversals, 2)
        XCTAssertEqual(WandConfig.parse(
            "[gesture.recognition]\ncancel-reversals = 3").recognition.cancelReversals, 3)
        XCTAssertEqual(WandConfig.parse(
            "[gesture.recognition]\ncancel-reversals = 0").recognition.cancelReversals, 0)
        XCTAssertEqual(WandConfig.parse(
            "[gesture.recognition]\ncancel-reversals = 999").recognition.cancelReversals, 20)
    }

    func testCancelWindowMs() {
        XCTAssertEqual(WandConfig.parse("").recognition.cancelWindowMs, 500)
        XCTAssertEqual(WandConfig.parse(
            "[gesture.recognition]\ncancel-window-ms = 800").recognition.cancelWindowMs, 800)
        XCTAssertEqual(WandConfig.parse(
            "[gesture.recognition]\ncancel-window-ms = 0").recognition.cancelWindowMs, 0)
        XCTAssertEqual(WandConfig.parse(
            "[gesture.recognition]\ncancel-window-ms = 50").recognition.cancelWindowMs, 100)
        XCTAssertEqual(WandConfig.parse(
            "[gesture.recognition]\ncancel-window-ms = 99999").recognition.cancelWindowMs, 5000)
    }

    func testExcludeAppsParsed() {
        let cfg = WandConfig.parse("""
        [exclude]
        apps = ["com.apple.dt.Xcode", "com.example.foo"]
        """)
        XCTAssertEqual(cfg.excludeApps,
                       ["com.apple.dt.Xcode", "com.example.foo"])
    }

    // MARK: - [gesture.overlay] + sub-blocks

    func testOverlayConfigParsed() {
        let cfg = WandConfig.parse("""
        [gesture.overlay]
        enabled = false

        [gesture.overlay.trail]
        color = "#ff0000"
        color-no-match = "orange"
        width = 8
        """)
        XCTAssertFalse(cfg.overlay.enabled)
        XCTAssertEqual(cfg.overlay.trail.color, "#ff0000")
        XCTAssertEqual(cfg.overlay.trail.colorNoMatch, "orange")
        XCTAssertEqual(cfg.overlay.trail.width, 8)
    }

    func testOverlayDefaultsWhenAbsent() {
        let cfg = WandConfig.parse("[gesture]\nbutton = \"right\"")
        XCTAssertTrue(cfg.overlay.enabled)
        XCTAssertEqual(cfg.overlay.trail.color, "#3b82f6")
        XCTAssertEqual(cfg.overlay.trail.colorNoMatch, "#ef4444")
        XCTAssertEqual(cfg.overlay.trail.width, 3)
    }

    func testOverlayWidthClamped() {
        XCTAssertEqual(WandConfig.parse(
            "[gesture.overlay.trail]\nwidth = 999").overlay.trail.width, 40)
        XCTAssertEqual(WandConfig.parse(
            "[gesture.overlay.trail]\nwidth = 0").overlay.trail.width, 1)
    }

    func testOverlayBadgeKnobs() {
        // Defaults — every overlay knob is opt-out so a config that
        // doesn't mention them keeps the rich HUD.
        let def = WandConfig.parse("")
        XCTAssertTrue(def.overlay.badge.enabled)
        XCTAssertTrue(def.overlay.blurEnabled)
        XCTAssertTrue(def.overlay.badge.animEnabled)
        XCTAssertEqual(def.overlay.badge.size, 56)

        // Explicit off + custom size — and the size clamps so a typo
        // can't pin the badge to nothing.
        let custom = WandConfig.parse("""
        [gesture.overlay]
        blur-enabled = false

        [gesture.overlay.badge]
        enabled = false
        anim-enabled = false
        size = 999
        """)
        XCTAssertFalse(custom.overlay.badge.enabled)
        XCTAssertFalse(custom.overlay.blurEnabled)
        XCTAssertFalse(custom.overlay.badge.animEnabled)
        XCTAssertEqual(custom.overlay.badge.size, 96)

        XCTAssertEqual(WandConfig.parse(
            "[gesture.overlay.badge]\nsize = 4").overlay.badge.size, 32)
    }

    // MARK: - [[gesture.rule]]

    func testConfigParsesArrayOfTables() {
        let toml = """
        [gesture]
        button = "right"
        modifiers = ["cmd"]

        [gesture.recognition]
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
        XCTAssertEqual(cfg.recognition.minStrokePx, 20)
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
