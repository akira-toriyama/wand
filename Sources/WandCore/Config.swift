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
    /// Named preset that determines how the trail line is rendered —
    /// width, glow, dash pattern, per-segment color. `.normal` is the
    /// existing single-color stroke; other cases swap in dashed,
    /// rainbow hue rotation, comet tapering, etc. Sourced from
    /// `[gesture.overlay].trail-style`; unknown values log + clamp to
    /// `.normal`. Hot-reloadable.
    public var overlayTrailStyle: TrailStyle
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
    /// How long (ms) the trail stays on screen after a gesture fires —
    /// the in-progress segment is first snapped onto the lastDir axis
    /// so the whole path reads as a clean orthogonal polyline, then
    /// held at full alpha and faded out across this window. Clamped
    /// 0..2000; `0` disables hold (immediate clear, like the
    /// no-match path). Hot-reloadable.
    public var overlayFinalHoldMs: Int
    /// Exit animation when an assist card becomes unreachable mid-
    /// gesture (the user picked a different direction). Lives under
    /// `[gesture.overlay].card-unmatch` — these effects animate the
    /// overlay's HUD cards, so they're intrinsically tied to the
    /// overlay being visible. Unknown values clamp to `.none`.
    public var overlayCardUnmatch: Effect
    /// Exit animation when the firing card actually fires at button-
    /// up. Particle effects (`fireworks`, `confetti`) read more
    /// naturally here. Lives under `[gesture.overlay].card-match`
    /// (see `overlayCardUnmatch`).
    public var overlayCardMatch: Effect
    /// Particle burst emitted at the cursor position when a gesture
    /// rule fires. Lives in its own click-through window (independent
    /// of `[gesture.overlay].enabled`), so the burst still fires when
    /// the trail overlay is disabled. Default `.off`.
    public var fireTrailEnd: TrailEndKind
    /// Post-fire "ink decal" left at the cursor position when a
    /// gesture fires — a Splatoon-style splatter / blob / scorch /
    /// star that lingers and fades. Independent of overlay enabled.
    /// Default `.off`.
    public var fireDecal: DecalKind
    /// How long (ms) a decal stays visible before being released.
    /// Clamped 0..10000; `0` collapses to `.off` regardless of the
    /// `fireDecal` value.
    public var fireDecalDurationMs: Int
    /// Decal footprint in points (width = height). Clamped 10..200,
    /// default 60.
    public var fireDecalSize: Int
    /// Overall multiplier applied to fire-moment effects (trail-end
    /// burst, the launcher / overlay particle animations). Lives
    /// under `[gesture.fire]`. Unknown values clamp to `.normal`.
    /// Also scales overlay card animations so a single "intensity"
    /// knob covers every gesture-related effect.
    public var fireIntensity: Intensity
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
        overlayTrailStyle: .normal,
        overlayBadgeEnabled: true,
        overlayBlurEnabled: true,
        overlayBadgeSize: 56,
        overlayAnimEnabled: true,
        overlayFinalHoldMs: 400,
        overlayCardUnmatch: .none,
        overlayCardMatch: .none,
        fireTrailEnd: .off,
        fireDecal: .off,
        fireDecalDurationMs: 3000,
        fireDecalSize: 60,
        fireIntensity: .normal,
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

    /// Parse a TOML document containing `[[launcher.item]]` entries
    /// (and optionally `[launcher].layout`) — the schema `wand
    /// --show-menu --items <PATH>` expects. Same row-level
    /// validation as `[launcher]` items in the main config (drop on
    /// missing name / invalid action, with a loud log line), so a
    /// client that screws up the file gets a diagnostic.
    ///
    /// The items file's `[launcher].layout` declaration is what
    /// controls the visual orientation for this particular show-menu
    /// call — independent of `~/.config/wand/config.toml`'s
    /// `[launcher].layout` (which only applies to the native middle-
    /// click trigger). Default `.list` when missing or unknown.
    public static func parseItems(_ text: String) -> LauncherItemsFile {
        let doc = parseTOMLSubset(text)
        let lr = doc.tables["launcher"] ?? [:]
        let layout: LauncherLayout = parseEnum(
            lr, key: "layout", section: "launcher", default: .list)
        let items: [LauncherItem] = (doc.arrays["launcher.item"] ?? []).enumerated()
            .compactMap { idx, row in parseItem(row, idx: idx) }
        return LauncherItemsFile(layout: layout, items: items)
    }

    static func parse(_ text: String) -> WandConfig {
        let doc = parseTOMLSubset(text)
        logMigrationWarnings(doc)

        // ── Global ────────────────────────────────────────────
        // [exclude] — bundle ids where wand is fully disabled.
        // Applies to BOTH gesture rules and launcher items; the old
        // location was `[recognition].exclude-apps`, which was
        // misleading (gesture-flavoured) and inconsistent with the
        // actual scope.
        let excl = doc.tables["exclude"] ?? [:]
        let excludes = excl.strings("apps")

        // ── [gesture.*] ───────────────────────────────────────
        // Right-button-drag trigger family. Top-level [gesture]
        // holds the trigger (button / modifiers) AND the recognition
        // timing knobs (min-stroke-px, max-segment-ms, cancel-*) —
        // collapsing the old [trigger] + [recognition] split now
        // that they're explicitly gesture-scoped.
        let g = doc.tables["gesture"] ?? [:]
        let button = Trigger.Button(rawValue: g.string("button").lowercased())
            ?? .right
        let mods = Set(g.strings("modifiers")
            .compactMap { Modifier(rawValue: $0.lowercased()) })

        // Each clamp helper logs when the parsed value differs from
        // user input, so a typo like `min-stroke-px = 9999` is visible
        // in /tmp/wand.log instead of silently capping.
        let minPx = clampInt(g, key: "min-stroke-px",
                             default: 16, lo: 4, hi: 200)
        let maxMs = clampMs(g, key: "max-segment-ms",
                            default: 0, lo: 100, hi: 60000)
        let cancelRev = clampMs(g, key: "cancel-reversals",
                                default: 2, lo: 1, hi: 20)
        let cancelWin = clampMs(g, key: "cancel-window-ms",
                                default: 500, lo: 100, hi: 5000)

        // [gesture.overlay] — gesture-trail HUD (badge / cards /
        // trail color / blur). Renamed from bare [overlay] to make
        // the scope obvious next to a future [launcher.overlay]
        // (when ring/panel mode lands).
        //
        // Card-match / card-unmatch animate the assist cards inside
        // the overlay, so they live under [gesture.overlay] (not
        // [gesture.fire]) — the dependency is now visible in the
        // section name.
        let ov = doc.tables["gesture.overlay"] ?? [:]
        let overlayEnabled = ov.bool("enabled", true)
        let overlayColor = { let c = ov.string("color"); return c.isEmpty ? "#3b82f6" : c }()
        let overlayColorNoMatch = { let c = ov.string("color-no-match"); return c.isEmpty ? "#ef4444" : c }()
        let overlayWidth = clampInt(ov, key: "width",
                                    default: 3, lo: 1, hi: 40)
        let overlayTrailStyle: TrailStyle = parseEnum(
            ov, key: "trail-style", section: "gesture.overlay",
            default: .normal)
        let overlayBadgeEnabled = ov.bool("badge-enabled", true)
        let overlayBlurEnabled = ov.bool("blur-enabled", true)
        let overlayBadgeSize = clampInt(ov, key: "badge-size",
                                        default: 56, lo: 32, hi: 96)
        let overlayAnimEnabled = ov.bool("anim-enabled", true)
        let overlayFinalHoldMs = clampInt(ov, key: "final-hold-ms",
                                          default: 400, lo: 0, hi: 2000)
        let overlayCardUnmatch: Effect = parseEnum(
            ov, key: "card-unmatch", section: "gesture.overlay",
            default: .none)
        let overlayCardMatch: Effect = parseEnum(
            ov, key: "card-match", section: "gesture.overlay",
            default: .none)

        // [gesture.fire] — effects emitted at the moment a gesture
        // rule fires. Both the trail-end burst and the decal live in
        // their own click-through windows, so they fire even when
        // [gesture.overlay].enabled = false. `intensity` is a global
        // multiplier — also scales overlay card animations, so a
        // single knob covers every gesture-effect amplitude.
        let fi = doc.tables["gesture.fire"] ?? [:]
        let fireTrailEnd: TrailEndKind = parseEnum(
            fi, key: "trail-end", section: "gesture.fire", default: .off)
        let fireDecal: DecalKind = parseEnum(
            fi, key: "decal", section: "gesture.fire", default: .off)
        let fireDecalDurationMs = clampInt(
            fi, key: "decal-duration-ms",
            default: 3000, lo: 0, hi: 10000)
        let fireDecalSize = clampInt(
            fi, key: "decal-size", default: 60, lo: 10, hi: 200)
        let fireIntensity: Intensity = parseEnum(
            fi, key: "intensity", section: "gesture.fire", default: .normal)

        // ── [launcher.*] ──────────────────────────────────────
        // Middle-click (or other configured button) contextual
        // menu. Tap not installed when `enabled = false` (default),
        // so a stale `[[launcher.item]]` list can't surprise anyone
        // who hasn't opted in.
        let lr = doc.tables["launcher"] ?? [:]
        let launcherEnabled = lr.bool("enabled", false)
        let launcherButton = Trigger.Button(rawValue: lr.string("button").lowercased())
            ?? .middle
        let launcherMods = Set(lr.strings("modifiers")
            .compactMap { Modifier(rawValue: $0.lowercased()) })
        // `[launcher].layout` — orientation of the native-trigger
        // launcher panel. `--show-menu` items files override this
        // per-call via their own `[launcher].layout`. Default `.list`.
        let launcherLayout: LauncherLayout = parseEnum(
            lr, key: "layout", section: "launcher", default: .list)
        let launcherShortcutBadge = lr.bool("shortcut-badge", true)
        let launcherIconChip = lr.bool("icon-chip", true)

        // [launcher.effect] — launcher panel open/close animations
        // + decorative border. Lives under launcher (not the gesture
        // tree) so the trigger-family scoping stays clean.
        let le = doc.tables["launcher.effect"] ?? [:]
        let launcherEffectOpen: LauncherOpenAnim = parseEnum(
            le, key: "open", section: "launcher.effect", default: .off)
        let launcherEffectClose: LauncherCloseAnim = parseEnum(
            le, key: "close", section: "launcher.effect", default: .off)
        let launcherEffectBorder: LauncherBorder = parseEnum(
            le, key: "border", section: "launcher.effect", default: .off)
        let launcherEffect = LauncherEffectSpec(
            open: launcherEffectOpen,
            close: launcherEffectClose,
            border: launcherEffectBorder)

        // Warn when the user opted out of the launcher but still
        // configured non-default panel effects — those knobs only
        // fire when a panel actually opens, so they're dead config
        // until `[launcher].enabled = true`. Default values stay
        // silent (no one needs a warning for `open = "off"`); the
        // log only mentions the fields they actually set, so the
        // fix is obvious. Skipped when the launcher was enabled by
        // the user — the collision check below handles the demotion
        // case separately.
        if !launcherEnabled {
            var nonDefault: [String] = []
            if launcherEffectOpen != .off {
                nonDefault.append("open = \"\(launcherEffectOpen.rawValue)\"")
            }
            if launcherEffectClose != .off {
                nonDefault.append("close = \"\(launcherEffectClose.rawValue)\"")
            }
            if launcherEffectBorder != .off {
                nonDefault.append("border = \"\(launcherEffectBorder.rawValue)\"")
            }
            if !nonDefault.isEmpty {
                Log.line("config: [launcher.effect] has "
                    + "\(nonDefault.joined(separator: ", ")) but "
                    + "[launcher].enabled = false — these knobs"
                    + " only fire when a launcher panel actually"
                    + " opens. Either set [launcher].enabled = true,"
                    + " or remove the [launcher.effect] block.")
            }
        }

        // [[launcher.item]] — launcher rows. Same drop-on-typo
        // policy as [[gesture.rule]]: bad rows surface in the log
        // with their position.
        let items: [LauncherItem] = (doc.arrays["launcher.item"] ?? []).enumerated()
            .compactMap { idx, row in parseItem(row, idx: idx) }

        // ── Trigger collision detection ───────────────────────
        // Two trigger families sharing the same (button, modifiers)
        // would have their CGEventTaps fight over the same down
        // event — the daemon would install both, only one would see
        // each click, and *which* one is determined by the CG
        // registration order. From the outside it looks like "one
        // of them silently stopped working".
        //
        // Policy: declaration-order wins (gesture > launcher >
        // future families in source order). The loser is forced to
        // `enabled = false` so its tap is never installed, and the
        // demotion is logged with a hint on how to fix it. A
        // different button OR a non-empty modifier difference
        // resolves the conflict (modifier sets are compared
        // strictly — `[]` and `["ctrl"]` are different triggers).
        let gestureTrigger = Trigger(button: button, modifiers: mods)
        let launcherTrigger = Trigger(button: launcherButton,
                                       modifiers: launcherMods)
        var effectiveLauncherEnabled = launcherEnabled
        if launcherEnabled && launcherTrigger == gestureTrigger {
            Log.line("config: [launcher].button = \"\(launcherButton.rawValue)\""
                + " + modifiers=\(modifierList(launcherMods)) collides"
                + " with [gesture] — [launcher] disabled for this"
                + " session. Pick a distinct button, or add a"
                + " modifier (e.g. `modifiers = [\"ctrl\"]`) to one"
                + " side. (Declaration-order policy: gesture wins,"
                + " later families lose.)")
            effectiveLauncherEnabled = false
        }

        let launcher = LauncherSpec(
            enabled: effectiveLauncherEnabled,
            trigger: launcherTrigger,
            layout: launcherLayout,
            items: items,
            shortcutBadge: launcherShortcutBadge,
            iconChip: launcherIconChip,
            effect: launcherEffect)

        // [[gesture.rule]] — gesture pattern → action mappings.
        // Log every dropped rule with its position + reason so
        // `--validate` and the daemon log both surface them.
        let rules: [Rule] = (doc.arrays["gesture.rule"] ?? []).enumerated()
            .compactMap { idx, row in
                let label = "[[gesture.rule]][\(idx)]"
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
                             + "action-keys / action-verb / action-cmd / "
                             + "action-url)")
                    return nil
                }
                let name = row.string("name")
                let apps = row.strings("apps")
                return Rule(name: name.isEmpty ? pattern : name,
                            pattern: pattern,
                            apps: apps.isEmpty ? ["*"] : apps,
                            filterTitle: row.string("filter-title"),
                            filterShell: row.string("filter-shell"),
                            action: action)
            }

        return WandConfig(
            trigger: gestureTrigger,
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
            overlayTrailStyle: overlayTrailStyle,
            overlayBadgeEnabled: overlayBadgeEnabled,
            overlayBlurEnabled: overlayBlurEnabled,
            overlayBadgeSize: overlayBadgeSize,
            overlayAnimEnabled: overlayAnimEnabled,
            overlayFinalHoldMs: overlayFinalHoldMs,
            overlayCardUnmatch: overlayCardUnmatch,
            overlayCardMatch: overlayCardMatch,
            fireTrailEnd: fireTrailEnd,
            fireDecal: fireDecal,
            fireDecalDurationMs: fireDecalDurationMs,
            fireDecalSize: fireDecalSize,
            fireIntensity: fireIntensity,
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
    /// Scan a parsed TOML doc for retired section / array names and
    /// log one line per occurrence with the new location. The parser
    /// already ignored unknown sections; this just turns the silent
    /// ignore into a loud "your config still has the old shape"
    /// pointer.
    ///
    /// v4 retired (still warned about): bare `[trigger]` / `[recognition]`
    /// / `[overlay]` / `[effect]` and `[[rules]]` / `[[item]]`.
    ///
    /// v5 retired: `[gesture.effect]` was split — card animations
    /// (match/unmatch) moved into `[gesture.overlay]` to make the
    /// overlay dependency explicit; trail-end burst / decal / intensity
    /// moved into the new `[gesture.fire]`; launcher-open / launcher-close
    /// moved into `[launcher.effect]`. `[launcher].border` moved into
    /// the same new `[launcher.effect]` block. We also surface key-level
    /// renames (`match`/`unmatch`/`launcher-open`/`launcher-close`) for
    /// users who only edit individual lines.
    private static func logMigrationWarnings(_ doc: TOMLDocument) {
        let renames: [(old: String, new: String)] = [
            // v3 → v4
            ("trigger",     "[gesture] (button / modifiers folded in)"),
            ("recognition", "[gesture] (timing knobs folded in) + [exclude].apps"),
            ("overlay",     "[gesture.overlay]"),
            ("effect",      "[gesture.effect] (then split again in v5)"),
            // v4 → v5
            ("gesture.effect",
             "[gesture.overlay] (card-match / card-unmatch), "
                + "[gesture.fire] (trail-end / decal* / intensity), and "
                + "[launcher.effect] (open / close)"),
        ]
        for r in renames where doc.tables[r.old] != nil {
            Log.line("config: [\(r.old)] section was retired — "
                     + "move keys to \(r.new). Until renamed, the "
                     + "values from this section are ignored.")
        }
        // v5 individual-key renames inside the old [gesture.effect]
        // — surfaced even if the user already split the section, in
        // case they only renamed *some* keys.
        if let ef = doc.tables["gesture.effect"] {
            let keyRenames: [(old: String, new: String)] = [
                ("match",          "[gesture.overlay].card-match"),
                ("unmatch",        "[gesture.overlay].card-unmatch"),
                ("trail-end",      "[gesture.fire].trail-end"),
                ("decal",          "[gesture.fire].decal"),
                ("decal-duration-ms", "[gesture.fire].decal-duration-ms"),
                ("decal-size",     "[gesture.fire].decal-size"),
                ("intensity",      "[gesture.fire].intensity"),
                ("launcher-open",  "[launcher.effect].open"),
                ("launcher-close", "[launcher.effect].close"),
            ]
            for r in keyRenames where ef[r.old] != nil {
                Log.line("config: [gesture.effect].\(r.old) was renamed "
                         + "in v5 — move it to \(r.new).")
            }
        }
        // v4 → v5: [launcher].border moved to [launcher.effect].border.
        if let lr = doc.tables["launcher"], lr["border"] != nil {
            Log.line("config: [launcher].border was moved in v5 — "
                     + "place it under [launcher.effect].border instead.")
        }
        let arrayRenames: [(old: String, new: String)] = [
            ("rules", "[[gesture.rule]]"),
            ("item",  "[[launcher.item]]"),
        ]
        for r in arrayRenames where doc.arrays[r.old] != nil {
            Log.line("config: [[\(r.old)]] array was retired — "
                     + "rename each block to \(r.new). Until renamed, "
                     + "the rows in this array are ignored.")
        }
    }

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

    /// Render a Modifier set as a stable, sorted, bracketed string
    /// for log lines — `[]` for empty, `["cmd", "shift"]` for two.
    /// Sort by rawValue so the same set always renders the same way
    /// (Swift's Set has no inherent order, and log diffability beats
    /// the natural-language order).
    private static func modifierList(_ mods: Set<Modifier>) -> String {
        if mods.isEmpty { return "[]" }
        let names = mods.map(\.rawValue).sorted()
            .map { "\"\($0)\"" }
            .joined(separator: ", ")
        return "[\(names)]"
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
        let header = row.string("header")
        let subtitle = row.string("subtitle")
        let icon = row.string("icon")
        let tint = row.string("tint")
        let tintColors = row.strings("tint-colors")
        let iconAnim = row.string("icon-anim")
        let filterTitle = row.string("filter-title")
        let filterShell = row.string("filter-shell")
        let state = row.string("state")
        return LauncherItem(
            name: name, group: group, separatorBefore: sep,
            apps: apps.isEmpty ? ["*"] : apps,
            header: header,
            subtitle: subtitle,
            icon: icon,
            tint: tint,
            tintColors: tintColors,
            iconAnim: iconAnim,
            filterTitle: filterTitle, filterShell: filterShell,
            state: state,
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
