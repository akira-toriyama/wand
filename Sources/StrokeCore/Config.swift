// stroke is config.toml-driven, read-only from the daemon's
// perspective: the file is the source of truth, the CLI never writes
// it. Unknown / out-of-range values clamp to defaults — a typo can
// never break recognition.

import Foundation

public struct StrokeConfig: Sendable {
    public var trigger: Trigger
    public var minStrokePx: Int
    /// Maximum time (ms) from button-down to button-up for a stroke to
    /// still count as a gesture. A slower drag is abandoned (no
    /// action). `0` = no limit. Lets you right-drag normally without
    /// it being read as a gesture, as long as you take your time.
    public var maxSegmentMs: Int
    /// Number of 180° direction reversals (a back-and-forth scribble)
    /// that cancels the in-progress stroke — once reached, the gesture
    /// is latched dead and releasing fires nothing, no waiting for a
    /// timeout. `0` = off. A real gesture rarely reverses, so the
    /// default catches deliberate scribbles without false positives.
    public var cancelReversals: Int
    /// Time window (ms) the `cancelReversals` reversals must fall within
    /// for a scribble to cancel — so only a *fast* back-and-forth counts,
    /// not a slow deliberate one. `0` = any speed (count alone cancels).
    public var cancelWindowMs: Int
    public var excludeApps: [String]
    public var rules: [Rule]
    /// Gesture-trail overlay. Colors stay strings here so Core needn't
    /// depend on AppKit's NSColor — the adapter parses them (`#rgb` /
    /// `#rrggbb` / `#rrggbbaa` / a few names). `overlayColor` is drawn
    /// while the in-progress stroke matches a rule (and before it's
    /// recognisable); `overlayColorNoMatch` while the shape so far
    /// matches nothing.
    public var overlayEnabled: Bool
    public var overlayColor: String
    public var overlayColorNoMatch: String
    public var overlayWidth: Int
    /// Show the target-app icon badge at the gesture origin?
    /// Independent of `overlayEnabled` so a user can keep the trail
    /// + assist tooltips but hide the badge alone.
    public var overlayBadgeEnabled: Bool
    /// Use the macOS frosted blur (`NSVisualEffectView`) under the
    /// HUD cards + badge. `false` falls back to the older solid dark
    /// fill — useful when blur feels heavy on the eyes or perf.
    public var overlayBlurEnabled: Bool
    /// Origin badge size in points. Clamped 32..96.
    public var overlayBadgeSize: Int
    /// Scale-in pop on the origin badge.
    public var overlayAnimEnabled: Bool

    public static let `default` = StrokeConfig(
        trigger: Trigger(button: .right, modifiers: []),
        minStrokePx: 16,
        maxSegmentMs: 0,
        cancelReversals: 2,
        cancelWindowMs: 500,
        excludeApps: [],
        rules: [],
        overlayEnabled: true,
        overlayColor: "#3b82f6",
        overlayColorNoMatch: "#ef4444",
        overlayWidth: 3,
        overlayBadgeEnabled: true,
        overlayBlurEnabled: true,
        overlayBadgeSize: 56,
        overlayAnimEnabled: true
    )

    /// The single source-of-truth path. Shared by `load()` and the
    /// app's file watcher so both point at the same file.
    public static let path = NSString(string: "~/.config/stroke/config.toml")
        .expandingTildeInPath

    /// Read ~/.config/stroke/config.toml. Missing file → defaults,
    /// no error (same agent-friendly behaviour as facet).
    public static func load() -> StrokeConfig {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8)
        else {
            Log.line("config: no file at \(path) — using built-in defaults")
            return .default
        }
        return parse(text)
    }

    static func parse(_ text: String) -> StrokeConfig {
        let doc = parseTOMLSubset(text)

        let trig = doc.tables["trigger"] ?? [:]
        let button = Trigger.Button(rawValue: trig.string("button").lowercased())
            ?? .right
        let mods = Set(trig.strings("modifiers")
            .compactMap { Modifier(rawValue: $0.lowercased()) })

        // Each clamp helper logs when the parsed value differs from
        // user input, so a typo like `min-stroke-px = 9999` is visible
        // in /tmp/stroke.log instead of silently capping.
        let reco = doc.tables["recognition"] ?? [:]
        let minPx = clampInt(reco, key: "min-stroke-px",
                             default: 16, lo: 4, hi: 200)
        // `max-segment-ms` is the canonical key. `max-stroke-ms` is
        // the legacy alias — kept for one release as a courtesy after
        // PR #6 rewrote the semantic from total-stroke to per-segment;
        // the old name now mis-describes what it does.
        let maxMs: Int = {
            if reco["max-segment-ms"] != nil {
                return clampMs(reco, key: "max-segment-ms",
                               default: 0, lo: 100, hi: 60000)
            }
            if reco["max-stroke-ms"] != nil {
                Log.line("config: `max-stroke-ms` is deprecated; rename "
                         + "to `max-segment-ms` (same semantic — the "
                         + "value is the per-segment timeout, with the "
                         + "clock resetting on each direction change)")
                return clampMs(reco, key: "max-stroke-ms",
                               default: 0, lo: 100, hi: 60000)
            }
            return 0
        }()
        let cancelRev = clampMs(reco, key: "cancel-reversals",
                                default: 2, lo: 1, hi: 20)
        let cancelWin = clampMs(reco, key: "cancel-window-ms",
                                default: 500, lo: 100, hi: 5000)
        let excludes = reco.strings("exclude-apps")

        let ov = doc.tables["overlay"] ?? [:]
        let overlayEnabled = ov.bool("enabled", true)
        let overlayColor = { let c = ov.string("color"); return c.isEmpty ? "#3b82f6" : c }()
        let overlayColorNoMatch = { let c = ov.string("color-no-match"); return c.isEmpty ? "#ef4444" : c }()
        let overlayWidth = clampInt(ov, key: "width",
                                    default: 3, lo: 1, hi: 40)
        let overlayBadgeEnabled = ov.bool("badge-enabled", true)
        let overlayBlurEnabled = ov.bool("blur-enabled", true)
        let overlayBadgeSize = clampInt(ov, key: "badge-size",
                                        default: 56, lo: 32, hi: 96)
        let overlayAnimEnabled = ov.bool("anim-enabled", true)

        // Log every dropped rule with its position + reason so
        // `--validate` and the daemon log both surface them — silent
        // `compactMap`-of-nil was the worst typo footgun.
        let rules: [Rule] = (doc.arrays["rules"] ?? []).enumerated()
            .compactMap { idx, row in
                let label = "[[rules]][\(idx)]"
                    + (row.string("name").isEmpty
                       ? "" : " \(row.string("name"))")
                let pattern = row.string("pattern")
                if let issue = Recognition.patternIssue(pattern) {
                    Log.line("config: dropped \(label) — \(issue)")
                    return nil
                }
                guard let action = parseAction(row) else {
                    Log.line("config: dropped \(label) — invalid or missing "
                             + "action (need action-type + matching "
                             + "action-keys / action-verb / action-cmd)")
                    return nil
                }
                let name = row.string("name")
                let apps = row.strings("apps")
                return Rule(name: name.isEmpty ? pattern : name,
                            pattern: pattern,
                            apps: apps.isEmpty ? ["*"] : apps,
                            action: action)
            }

        return StrokeConfig(
            trigger: Trigger(button: button, modifiers: mods),
            minStrokePx: minPx,
            maxSegmentMs: maxMs,
            cancelReversals: cancelRev,
            cancelWindowMs: cancelWin,
            excludeApps: excludes,
            rules: rules,
            overlayEnabled: overlayEnabled,
            overlayColor: overlayColor,
            overlayColorNoMatch: overlayColorNoMatch,
            overlayWidth: overlayWidth,
            overlayBadgeEnabled: overlayBadgeEnabled,
            overlayBlurEnabled: overlayBlurEnabled,
            overlayBadgeSize: overlayBadgeSize,
            overlayAnimEnabled: overlayAnimEnabled
        )
    }

    /// Per-row action shape, decomposed across dotted-style keys so
    /// the minimal TOML parser can read it without inline-table
    /// support:
    ///
    ///     action-type = "key"           # key | ax | shell
    ///     action-keys = "cmd+w"         # for type=key
    ///     action-verb = "close"         # for type=ax
    ///     action-cmd  = "open ..."      # for type=shell
    /// Clamp a `[lo, hi]` integer, logging when the parsed value
    /// differs from what the user wrote. Used for every fixed-range
    /// knob — covers the "user typed 9999 and it silently capped to
    /// 200" foot-gun.
    private static func clampInt(_ table: [String: TOMLValue],
                                  key: String, default def: Int,
                                  lo: Int, hi: Int) -> Int {
        let raw = table.int(key, def)
        let clamped = max(lo, min(hi, raw))
        if raw != clamped {
            Log.line("config: \(key) = \(raw) clamped to \(clamped) "
                     + "(allowed \(lo)..\(hi))")
        }
        return clamped
    }

    /// Same as `clampInt`, but treats `<= 0` as "feature off" rather
    /// than clamping up to `lo`. For knobs where 0 is a documented
    /// opt-out (max-segment-ms, cancel-reversals, cancel-window-ms).
    private static func clampMs(_ table: [String: TOMLValue],
                                 key: String, default def: Int,
                                 lo: Int, hi: Int) -> Int {
        let raw = table.int(key, def)
        if raw <= 0 { return 0 }
        let clamped = max(lo, min(hi, raw))
        if raw != clamped {
            Log.line("config: \(key) = \(raw) clamped to \(clamped) "
                     + "(allowed 0 or \(lo)..\(hi))")
        }
        return clamped
    }

    private static func parseAction(_ row: [String: TOMLValue]) -> Action? {
        guard case .string(let type) = row["action-type"] ?? .string("")
        else { return nil }
        switch type.lowercased() {
        case "key":
            if case .string(let k) = row["action-keys"] ?? .string(""),
               !k.isEmpty { return .key(k) }
        case "ax":
            if case .string(let v) = row["action-verb"] ?? .string("") {
                let verb = v.lowercased()
                if Action.axVerbs.contains(verb) { return .ax(verb) }
            }
        case "shell":
            if case .string(let c) = row["action-cmd"] ?? .string(""),
               !c.isEmpty { return .shell(c) }
        default: break
        }
        return nil
    }
}

// Typed accessors over a parsed TOML table — collapse the repeated
// `if case .string(let s) = x ?? .string("")` extraction to one call.
// A wrong-typed or missing key yields the fallback (config policy:
// never throw on a typo).
private extension [String: TOMLValue] {
    func string(_ key: String, _ fallback: String = "") -> String {
        if case .string(let s) = self[key] { return s }
        return fallback
    }
    func int(_ key: String, _ fallback: Int) -> Int {
        if case .int(let i) = self[key] { return i }
        return fallback
    }
    func bool(_ key: String, _ fallback: Bool) -> Bool {
        if case .bool(let b) = self[key] { return b }
        return fallback
    }
    func strings(_ key: String, _ fallback: [String] = []) -> [String] {
        if case .stringArray(let a) = self[key] { return a }
        return fallback
    }
}
