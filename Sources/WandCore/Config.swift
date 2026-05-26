// wand is config.toml-driven, read-only from the daemon's
// perspective: the file is the source of truth, the CLI never writes
// it. Unknown / out-of-range values clamp to defaults — a typo can
// never break recognition.

import Foundation

public struct WandConfig: Sendable {
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
    /// Exit animation when an assist card becomes unreachable mid-
    /// gesture (the user picked a different direction). Unknown
    /// config values clamp to `.none`.
    public var effectUnmatch: Effect
    /// Exit animation when the firing card actually fires at button-
    /// up. Particle effects (`fireworks`, `confetti`) read more
    /// naturally here.
    public var effectMatch: Effect
    /// Overall size of the chosen effects. Applied uniformly to both
    /// `unmatch` and `match`. Unknown config values clamp to `.normal`.
    public var effectIntensity: Intensity
    /// Launcher trigger family — middle-click (or other configured
    /// button) pops a contextual menu near the cursor. Trigger lives
    /// inside the spec so each family owns its own button; the
    /// top-level `trigger` is the gesture family.
    public var launcher: LauncherSpec

    public static let `default` = WandConfig(
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
        overlayAnimEnabled: true,
        effectUnmatch: .none,
        effectMatch: .none,
        effectIntensity: .normal,
        launcher: .default
    )

    /// The single source-of-truth path. Shared by `load()` and the
    /// app's file watcher so both point at the same file.
    public static let path = NSString(string: "~/.config/wand/config.toml")
        .expandingTildeInPath

    /// Read ~/.config/wand/config.toml. Missing file → defaults,
    /// no error (same agent-friendly behaviour as facet).
    public static func load() -> WandConfig {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8)
        else {
            Log.line("config: no file at \(path) — using built-in defaults")
            return .default
        }
        return parse(text)
    }

    /// Parse a TOML document containing only `[[item]]` entries — the
    /// schema `wand --show-menu --items <PATH>` expects. Same
    /// row-level validation as `[launcher]` items in the main config
    /// (drop on missing name / invalid action, with a loud log line),
    /// so a client that screws up the file gets a diagnostic.
    public static func parseItems(_ text: String) -> [LauncherItem] {
        let doc = parseTOMLSubset(text)
        return (doc.arrays["item"] ?? []).enumerated()
            .compactMap { idx, row in parseItem(row, idx: idx) }
    }

    static func parse(_ text: String) -> WandConfig {
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
        let maxMs = clampMs(reco, key: "max-segment-ms",
                            default: 0, lo: 100, hi: 60000)
        // v1.5 accepted `max-stroke-ms` as a deprecated alias; v2.0
        // drops it. Warn loudly so a stale config doesn't silently
        // run with `0` (= no timeout).
        if reco["max-stroke-ms"] != nil {
            Log.line("config: `max-stroke-ms` was removed in v2.0 — "
                     + "rename to `max-segment-ms` (same semantic). "
                     + "Until you do, the timeout is unset (0 = no limit).")
        }
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

        // Same typo-tolerant policy as `[recognition]`: unknown names
        // log + clamp to default, never throw.
        let ef = doc.tables["effect"] ?? [:]
        let effectUnmatch: Effect = parseEnum(
            ef, key: "unmatch", section: "effect", default: .none)
        let effectMatch: Effect = parseEnum(
            ef, key: "match", section: "effect", default: .none)
        let effectIntensity: Intensity = parseEnum(
            ef, key: "intensity", section: "effect", default: .normal)

        // [launcher] — sibling trigger family. Tap not installed when
        // `enabled = false` (default), so a stale `[[item]]` list
        // can't surprise anyone who hasn't opted in.
        let lr = doc.tables["launcher"] ?? [:]
        let launcherEnabled = lr.bool("enabled", false)
        let launcherButton = Trigger.Button(rawValue: lr.string("button").lowercased())
            ?? .middle
        let launcherMods = Set(lr.strings("modifiers")
            .compactMap { Modifier(rawValue: $0.lowercased()) })

        // [[item]] — launcher menu rows. Same drop-on-typo policy as
        // [[rules]]: bad rows surface in the log with their position.
        let items: [LauncherItem] = (doc.arrays["item"] ?? []).enumerated()
            .compactMap { idx, row in parseItem(row, idx: idx) }
        let launcher = LauncherSpec(
            enabled: launcherEnabled,
            trigger: Trigger(button: launcherButton, modifiers: launcherMods),
            items: items)

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

        return WandConfig(
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
            overlayAnimEnabled: overlayAnimEnabled,
            effectUnmatch: effectUnmatch,
            effectMatch: effectMatch,
            effectIntensity: effectIntensity,
            launcher: launcher
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

    /// Parse a string-keyed enum from a TOML table. Empty / missing
    /// → silent default; unknown name → loud log + default with the
    /// full vocabulary listed (so a typo is fixable from the log
    /// alone). `CaseIterable` powers the valid-set; `RawRepresentable
    /// where RawValue == String` powers the lookup.
    private static func parseEnum<E>(
        _ table: [String: TOMLValue], key: String, section: String,
        default def: E
    ) -> E where E: RawRepresentable & CaseIterable, E.RawValue == String {
        let raw = table.string(key).lowercased()
        if raw.isEmpty { return def }
        if let v = E(rawValue: raw) { return v }
        let valid = E.allCases.map(\.rawValue).sorted().joined(separator: ", ")
        Log.line("config: [\(section)].\(key) = \"\(raw)\" not recognised "
                 + "— falling back to \"\(def.rawValue)\" (valid: \(valid))")
        return def
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

    /// Row-level parse for a single `[[item]]`. Shared by the
    /// `[launcher]` items inside the main config and by
    /// `parseItems(_:)` for the `--show-menu --items <PATH>` path.
    private static func parseItem(_ row: [String: TOMLValue], idx: Int)
        -> LauncherItem? {
        let label = "[[item]][\(idx)]"
            + (row.string("name").isEmpty ? "" : " \(row.string("name"))")
        let name = row.string("name")
        guard !name.isEmpty else {
            Log.line("config: dropped \(label) — `name` is required "
                     + "(it's the menu label)")
            return nil
        }
        let dynamic = row.string("dynamic")
        let action: Action
        let template: LauncherTemplate?
        if dynamic.isEmpty {
            // Static item — need a regular action.
            template = nil
            guard let parsed = parseAction(row) else {
                Log.line("config: dropped \(label) — invalid or missing "
                         + "action (need action-type + matching "
                         + "action-keys / action-verb / action-cmd / "
                         + "action-url)")
                return nil
            }
            action = parsed
        } else {
            // Dynamic producer — needs a template for children. The
            // parent's own `action` is unused (a sentinel keeps the
            // type total — `.shell("")` doubles as a no-op marker;
            // expansion paths never call it).
            guard let t = parseTemplate(row) else {
                Log.line("config: dropped \(label) — `dynamic` is set "
                         + "but no valid template-* fields found "
                         + "(need template-action-type + matching "
                         + "template-action-keys / template-action-verb / "
                         + "template-action-cmd / template-action-url)")
                return nil
            }
            template = t
            action = .shell("")  // unused for dynamic items
        }
        let apps = row.strings("apps")
        let group = row.strings("group")
        let sep = row.bool("separator-before", false)
        let icon = row.string("icon")
        let state = row.string("state")
        return LauncherItem(
            name: name, group: group, separatorBefore: sep,
            apps: apps.isEmpty ? ["*"] : apps,
            icon: icon, state: state,
            dynamic: dynamic, template: template,
            action: action)
    }

    /// Parse the `template-*` block — sibling of `parseAction` but
    /// reads from `template-action-type` etc., and keeps the body as
    /// a raw string (it may contain `{line}` placeholders that the
    /// adapter substitutes at expansion time).
    private static func parseTemplate(_ row: [String: TOMLValue])
        -> LauncherTemplate? {
        let kindRaw = row.string("template-action-type").lowercased()
        guard let kind = LauncherTemplate.Kind(rawValue: kindRaw)
        else { return nil }
        let payload: String
        switch kind {
        case .key:   payload = row.string("template-action-keys")
        case .ax:
            let verb = row.string("template-action-verb").lowercased()
            guard Action.axVerbs.contains(verb) || verb.contains("{line}")
            else { return nil }
            payload = verb
        case .shell: payload = row.string("template-action-cmd")
        case .url:   payload = row.string("template-action-url")
        }
        guard !payload.isEmpty else { return nil }
        let name = row.string("template-name")
        return LauncherTemplate(
            kind: kind,
            payload: payload,
            name: name.isEmpty ? "{line}" : name,
            icon: row.string("template-icon"))
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
        case "url":
            if case .string(let u) = row["action-url"] ?? .string(""),
               !u.isEmpty { return .url(u) }
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
