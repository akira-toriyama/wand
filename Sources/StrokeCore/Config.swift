// stroke configuration. Single source of truth lives at
// ~/.config/stroke/config.toml — never written, never auto-generated,
// never persisted from the CLI (same policy as facet). To make a
// change stick, the user edits the file and restarts (or
// `stroke --reload`).
//
// Unknown / out-of-range values clamp to defaults — a typo can
// never break the daemon.

import Foundation

public struct StrokeConfig: Sendable {
    public var trigger: Trigger
    public var minStrokePx: Int
    /// Maximum time (ms) from button-down to button-up for a stroke to
    /// still count as a gesture. A slower drag is abandoned (no
    /// action). `0` = no limit. Lets you right-drag normally without
    /// it being read as a gesture, as long as you take your time.
    public var maxStrokeMs: Int
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
    public var sampleHz: Int
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

    public static let `default` = StrokeConfig(
        trigger: Trigger(button: .right, modifiers: []),
        minStrokePx: 16,
        maxStrokeMs: 0,
        cancelReversals: 2,
        cancelWindowMs: 500,
        sampleHz: 120,
        excludeApps: [],
        rules: [],
        overlayEnabled: true,
        overlayColor: "#3b82f6",
        overlayColorNoMatch: "#ef4444",
        overlayWidth: 3
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

        // [trigger]
        let trig = doc.tables["trigger"] ?? [:]
        let button = Trigger.Button(rawValue: trig.string("button").lowercased())
            ?? .right
        let mods = Set(trig.strings("modifiers")
            .compactMap { Modifier(rawValue: $0.lowercased()) })

        // [recognition] — clamp out-of-range to keep a typo from
        // breaking recognition (the rule still loads, just bounded).
        // Each clamp logs when the parsed value differs from the user
        // input so a typo like `min-stroke-px = 9999` is visible in
        // `/tmp/stroke.log` instead of silently capped.
        let reco = doc.tables["recognition"] ?? [:]
        let minPx = clampInt(reco, key: "min-stroke-px",
                             default: 16, lo: 4, hi: 200)
        let maxMs = clampMs(reco, key: "max-stroke-ms",
                            default: 0, lo: 100, hi: 60000)
        let cancelRev = clampMs(reco, key: "cancel-reversals",
                                default: 2, lo: 1, hi: 20)
        let cancelWin = clampMs(reco, key: "cancel-window-ms",
                                default: 500, lo: 100, hi: 5000)
        let hz = clampInt(reco, key: "sample-hz",
                          default: 120, lo: 30, hi: 240)
        let excludes = reco.strings("exclude-apps")

        // [overlay]
        let ov = doc.tables["overlay"] ?? [:]
        let overlayEnabled = ov.bool("enabled", true)
        let overlayColor = { let c = ov.string("color"); return c.isEmpty ? "#3b82f6" : c }()
        let overlayColorNoMatch = { let c = ov.string("color-no-match"); return c.isEmpty ? "#ef4444" : c }()
        let overlayWidth = clampInt(ov, key: "width",
                                    default: 3, lo: 1, hi: 40)

        // [[rules]] — silently dropping rules (empty pattern, missing
        // action, unknown action-type) used to make typos invisible.
        // Log each drop with the reason so `stroke --validate` and the
        // daemon's log both surface them.
        let rules: [Rule] = (doc.arrays["rules"] ?? []).enumerated()
            .compactMap { idx, row in
                let label = "[[rules]][\(idx)]"
                    + (row.string("name").isEmpty
                       ? "" : " \(row.string("name"))")
                let pattern = row.string("pattern")
                guard !pattern.isEmpty else {
                    Log.line("config: dropped \(label) — missing or empty "
                             + "`pattern`")
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
            maxStrokeMs: maxMs,
            cancelReversals: cancelRev,
            cancelWindowMs: cancelWin,
            sampleHz: hz,
            excludeApps: excludes,
            rules: rules,
            overlayEnabled: overlayEnabled,
            overlayColor: overlayColor,
            overlayColorNoMatch: overlayColorNoMatch,
            overlayWidth: overlayWidth
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
    /// opt-out (max-stroke-ms, cancel-reversals, cancel-window-ms).
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
