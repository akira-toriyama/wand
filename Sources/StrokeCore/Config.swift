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
        let reco = doc.tables["recognition"] ?? [:]
        let minPx = max(4, min(200, reco.int("min-stroke-px", 16)))
        // 0 = no limit; otherwise clamp to a sane 100ms..60s window.
        let maxMs = { let m = reco.int("max-stroke-ms", 0); return m <= 0 ? 0 : max(100, min(60000, m)) }()
        // 0 = off; otherwise at least 1 reversal, capped so a typo can't
        // demand an unreachable scribble.
        let cancelRev = { let n = reco.int("cancel-reversals", 2); return n <= 0 ? 0 : max(1, min(20, n)) }()
        // 0 = any speed; otherwise clamp to a sane 100ms..5s window.
        let cancelWin = { let m = reco.int("cancel-window-ms", 500); return m <= 0 ? 0 : max(100, min(5000, m)) }()
        let hz = max(30, min(240, reco.int("sample-hz", 120)))
        let excludes = reco.strings("exclude-apps")

        // [overlay]
        let ov = doc.tables["overlay"] ?? [:]
        let overlayEnabled = ov.bool("enabled", true)
        let overlayColor = { let c = ov.string("color"); return c.isEmpty ? "#3b82f6" : c }()
        let overlayColorNoMatch = { let c = ov.string("color-no-match"); return c.isEmpty ? "#ef4444" : c }()
        let overlayWidth = max(1, min(40, ov.int("width", 3)))

        // [[rules]]
        let rules: [Rule] = (doc.arrays["rules"] ?? []).compactMap { row in
            let pattern = row.string("pattern")
            guard !pattern.isEmpty else { return nil }
            guard let action = parseAction(row) else { return nil }
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
