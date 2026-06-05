// wand is config.toml-driven, read-only from the daemon's
// perspective: the file is the source of truth, the CLI never writes
// it. Unknown / out-of-range values clamp to defaults — a typo can
// never break recognition.

import Foundation

public struct WandConfig: Sendable {
    /// `[gesture]` — the gesture trigger (button + modifiers). Other
    /// gesture-family knobs live in dedicated sub-blocks
    /// (`recognition` / `overlay` / `fire`).
    public var trigger: Trigger
    /// `[gesture].intensity` — gesture-wide effect multiplier. Scope
    /// spans `[gesture.overlay.cards]` (HUD card particle effects)
    /// AND `[gesture.fire.burst]` (cursor-anchored explosion). Decal
    /// has its own size / duration knobs and is not scaled. Kept
    /// inline at the gesture level (next to button / modifiers)
    /// because moving it into either sub-block would mislead about
    /// the scope.
    public var intensity: Intensity
    /// `[gesture.recognition]` — sample → direction tuning.
    public var recognition: GestureRecognitionSpec
    /// `[exclude].apps` — global bundle-id exclusion list. Applies
    /// to both gesture rules and launcher items.
    public var excludeApps: [String]
    /// `[[gesture.rule]]` — gesture pattern → action mappings.
    public var rules: [Rule]
    /// `[gesture.overlay]` and sub-blocks — trail + badge + cards.
    public var overlay: GestureOverlaySpec
    /// `[gesture.fire]` and sub-blocks — burst + decal.
    public var fire: GestureFireSpec
    /// `[launcher]` and sub-blocks — trigger + items + row /
    /// animation / decoration cosmetics.
    public var launcher: LauncherSpec

    public static let `default` = WandConfig(
        trigger: Trigger(button: .right, modifiers: []),
        intensity: .normal,
        recognition: .default,
        excludeApps: [],
        rules: [],
        overlay: .default,
        fire: .default,
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
        warnToolbarOnlyFields(items: items, layout: layout)
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

        // `[gesture].intensity` — gesture-wide effect multiplier.
        // Stays inline at the gesture level (next to button /
        // modifiers) because its scope spans both [gesture.overlay]
        // cards and [gesture.fire] burst — moving it inside either
        // sub-block would mislead about what it scales.
        let intensity: Intensity = parseEnum(
            g, key: "intensity", section: "gesture", default: .normal)

        // [gesture.recognition] — sample → direction tuning. v6 split
        // these out of the bare [gesture] block (which now holds only
        // trigger identity + the family-wide intensity knob) so
        // recognition behaviour and trigger identity don't share a
        // section.
        let rec = doc.tables["gesture.recognition"] ?? [:]
        let minPx = clampInt(rec, key: "min-stroke-px",
                             default: 16, lo: 4, hi: 200)
        let maxMs = clampMs(rec, key: "max-segment-ms",
                            default: 0, lo: 100, hi: 60000)
        let cancelRev = clampMs(rec, key: "cancel-reversals",
                                default: 2, lo: 1, hi: 20)
        let cancelWin = clampMs(rec, key: "cancel-window-ms",
                                default: 500, lo: 100, hi: 5000)
        let recognition = GestureRecognitionSpec(
            minStrokePx: minPx,
            maxSegmentMs: maxMs,
            cancelReversals: cancelRev,
            cancelWindowMs: cancelWin)

        // [gesture.overlay] — shared overlay toggles (enabled + blur);
        // trail / badge / cards each live in their own nested sub-block
        // so each field's scope is visible from the section path.
        let ov = doc.tables["gesture.overlay"] ?? [:]
        let overlayEnabled = ov.bool("enabled", true)
        let overlayBlurEnabled = ov.bool("blur-enabled", true)

        // [gesture.overlay.trail]
        let tr = doc.tables["gesture.overlay.trail"] ?? [:]
        let trailColor = { let c = tr.string("color"); return c.isEmpty ? "#3b82f6" : c }()
        let trailColorNoMatch = { let c = tr.string("color-no-match"); return c.isEmpty ? "#ef4444" : c }()
        let trailWidth = clampInt(tr, key: "width",
                                  default: 3, lo: 1, hi: 40)
        let trailStyle: TrailStyle = parseEnum(
            tr, key: "style", section: "gesture.overlay.trail",
            default: .normal)
        let trailFinalHoldMs = clampInt(tr, key: "final-hold-ms",
                                        default: 400, lo: 0, hi: 2000)
        let trail = GestureOverlayTrailSpec(
            color: trailColor,
            colorNoMatch: trailColorNoMatch,
            width: trailWidth,
            style: trailStyle,
            finalHoldMs: trailFinalHoldMs)

        // [gesture.overlay.badge]
        let bd = doc.tables["gesture.overlay.badge"] ?? [:]
        let badgeEnabled = bd.bool("enabled", true)
        let badgeSize = clampInt(bd, key: "size",
                                 default: 56, lo: 32, hi: 96)
        let badgeAnimEnabled = bd.bool("anim-enabled", true)
        let badge = GestureOverlayBadgeSpec(
            enabled: badgeEnabled,
            size: badgeSize,
            animEnabled: badgeAnimEnabled)

        // [gesture.overlay.cards]
        let cd = doc.tables["gesture.overlay.cards"] ?? [:]
        let cardsMatch: Effect = parseEnum(
            cd, key: "match", section: "gesture.overlay.cards", default: .none)
        let cardsUnmatch: Effect = parseEnum(
            cd, key: "unmatch", section: "gesture.overlay.cards", default: .none)
        let cards = GestureOverlayCardsSpec(
            match: cardsMatch, unmatch: cardsUnmatch)

        let overlay = GestureOverlaySpec(
            enabled: overlayEnabled,
            blurEnabled: overlayBlurEnabled,
            trail: trail, badge: badge, cards: cards)

        // [gesture.fire.burst]
        let bu = doc.tables["gesture.fire.burst"] ?? [:]
        let burstKind: TrailEndKind = parseEnum(
            bu, key: "kind", section: "gesture.fire.burst", default: .off)
        let burst = GestureFireBurstSpec(kind: burstKind)

        // [gesture.fire.decal]
        let de = doc.tables["gesture.fire.decal"] ?? [:]
        let decalKind: DecalKind = parseEnum(
            de, key: "kind", section: "gesture.fire.decal", default: .off)
        let decalDurationMs = clampInt(
            de, key: "duration-ms",
            default: 3000, lo: 0, hi: 10000)
        let decalSize = clampInt(
            de, key: "size", default: 60, lo: 10, hi: 200)
        let decal = GestureFireDecalSpec(
            kind: decalKind,
            durationMs: decalDurationMs,
            size: decalSize)

        let fire = GestureFireSpec(burst: burst, decal: decal)

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

        // [launcher.row] — per-row visual cosmetics (split from the
        // bare [launcher] block so trigger identity stays clean).
        let lrow = doc.tables["launcher.row"] ?? [:]
        let launcherRow = LauncherRowSpec(
            shortcutBadge: lrow.bool("shortcut-badge", true),
            iconChip: lrow.bool("icon-chip", true))

        // [launcher.animation]
        let la = doc.tables["launcher.animation"] ?? [:]
        let launcherAnimOpen: LauncherOpenAnim = parseEnum(
            la, key: "open", section: "launcher.animation", default: .off)
        let launcherAnimClose: LauncherCloseAnim = parseEnum(
            la, key: "close", section: "launcher.animation", default: .off)
        let launcherAnimation = LauncherAnimationSpec(
            open: launcherAnimOpen, close: launcherAnimClose)

        // [launcher.decoration]
        let ld = doc.tables["launcher.decoration"] ?? [:]
        let launcherDecorBorder: LauncherBorder = parseEnum(
            ld, key: "border", section: "launcher.decoration", default: .off)
        let launcherDecoration = LauncherDecorationSpec(
            border: launcherDecorBorder)

        // Warn when the user opted out of the launcher but still
        // configured non-default panel cosmetics — those only fire
        // when a panel actually opens, so they're dead config until
        // `[launcher].enabled = true`. Default values stay silent;
        // the log lists exactly what's dead. Skipped when launcher
        // is enabled — the collision check below handles demotion.
        if !launcherEnabled {
            var nonDefault: [String] = []
            if launcherAnimOpen != .off {
                nonDefault.append("[launcher.animation].open = \"\(launcherAnimOpen.rawValue)\"")
            }
            if launcherAnimClose != .off {
                nonDefault.append("[launcher.animation].close = \"\(launcherAnimClose.rawValue)\"")
            }
            if launcherDecorBorder != .off {
                nonDefault.append("[launcher.decoration].border = \"\(launcherDecorBorder.rawValue)\"")
            }
            if !nonDefault.isEmpty {
                Log.line("config: \(nonDefault.joined(separator: ", "))"
                    + " is set but [launcher].enabled = false — these"
                    + " knobs only fire when a launcher panel actually"
                    + " opens. Either set [launcher].enabled = true,"
                    + " or remove the offending lines.")
            }
        }

        // [[launcher.item]] — launcher rows. Same drop-on-typo
        // policy as [[gesture.rule]]: bad rows surface in the log
        // with their position.
        let items: [LauncherItem] = (doc.arrays["launcher.item"] ?? []).enumerated()
            .compactMap { idx, row in parseItem(row, idx: idx) }
        warnToolbarOnlyFields(items: items, layout: launcherLayout)

        // ── Trigger collision detection ───────────────────────
        // Two trigger families sharing the same (button, modifiers)
        // would have their CGEventTaps fight over the same down
        // event. Declaration-order wins (gesture > launcher > future
        // families); the loser is forced enabled = false. A different
        // button OR a non-empty modifier difference resolves it.
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
            row: launcherRow,
            animation: launcherAnimation,
            decoration: launcherDecoration)

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
            intensity: intensity,
            recognition: recognition,
            excludeApps: excludes,
            rules: rules,
            overlay: overlay,
            fire: fire,
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
                + "[gesture.fire] (trail-end / decal*), "
                + "[gesture].intensity (top-level), and "
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
                ("intensity",      "[gesture].intensity (top-level — scope spans both [gesture.overlay] cards and [gesture.fire] burst)"),
                ("launcher-open",  "[launcher.effect].open"),
                ("launcher-close", "[launcher.effect].close"),
            ]
            for r in keyRenames where ef[r.old] != nil {
                Log.line("config: [gesture.effect].\(r.old) was renamed "
                         + "in v5 — move it to \(r.new).")
            }
        }
        // v5.0 → v5.1: [gesture.fire].intensity moved up to
        // [gesture].intensity (top-level). v6 also retires the rest
        // of [gesture.fire]'s flat shape — see the [gesture.fire]
        // key-level renames below for the full migration.
        if let fi = doc.tables["gesture.fire"], fi["intensity"] != nil {
            Log.line("config: [gesture.fire].intensity was moved to "
                     + "[gesture].intensity (top-level) — its scope "
                     + "spans both [gesture.overlay] card animations "
                     + "and [gesture.fire] burst, so the sub-block "
                     + "location was misleading. Move the line up.")
        }
        // v4 → v5: [launcher].border moved to [launcher.effect].border.
        // v6 further moves it to [launcher.decoration].border (handled
        // by the [launcher.effect] key-rename block below).
        if let lr = doc.tables["launcher"], lr["border"] != nil {
            Log.line("config: [launcher].border was moved — "
                     + "place it under [launcher.decoration].border.")
        }

        // ── v5 → v6 sub-block split ─────────────────────────────
        // v6 splits previously-flat [gesture.overlay] and [gesture.fire]
        // into nested sub-blocks (trail / badge / cards under overlay;
        // burst / decal under fire). Row cosmetics moved out of
        // [launcher] into [launcher.row]. [launcher.effect] retired
        // in favour of [launcher.animation] + [launcher.decoration].
        if let ov = doc.tables["gesture.overlay"] {
            let overlayKeyRenames: [(old: String, new: String)] = [
                ("color",          "[gesture.overlay.trail].color"),
                ("color-no-match", "[gesture.overlay.trail].color-no-match"),
                ("width",          "[gesture.overlay.trail].width"),
                ("trail-style",    "[gesture.overlay.trail].style"),
                ("final-hold-ms",  "[gesture.overlay.trail].final-hold-ms"),
                ("badge-enabled",  "[gesture.overlay.badge].enabled"),
                ("badge-size",     "[gesture.overlay.badge].size"),
                ("anim-enabled",   "[gesture.overlay.badge].anim-enabled"),
                ("card-match",     "[gesture.overlay.cards].match"),
                ("card-unmatch",   "[gesture.overlay.cards].unmatch"),
            ]
            for r in overlayKeyRenames where ov[r.old] != nil {
                Log.line("config: [gesture.overlay].\(r.old) moved in"
                         + " v6 — place it under \(r.new).")
            }
        }
        if let fi = doc.tables["gesture.fire"] {
            let fireKeyRenames: [(old: String, new: String)] = [
                ("trail-end",         "[gesture.fire.burst].kind"),
                ("decal",             "[gesture.fire.decal].kind"),
                ("decal-duration-ms", "[gesture.fire.decal].duration-ms"),
                ("decal-size",        "[gesture.fire.decal].size"),
            ]
            for r in fireKeyRenames where fi[r.old] != nil {
                Log.line("config: [gesture.fire].\(r.old) moved in"
                         + " v6 — place it under \(r.new).")
            }
        }
        // v5 [gesture] held the recognition tuning knobs flat. v6
        // moves them to [gesture.recognition] so trigger identity and
        // recognition behaviour don't share a section.
        if let g = doc.tables["gesture"] {
            let recKeys = ["min-stroke-px", "max-segment-ms",
                            "cancel-reversals", "cancel-window-ms"]
            for key in recKeys where g[key] != nil {
                Log.line("config: [gesture].\(key) moved in v6 — place"
                         + " it under [gesture.recognition].\(key).")
            }
        }
        // v5 [launcher] held shortcut-badge / icon-chip flat. v6
        // moves them to [launcher.row].
        if let lr = doc.tables["launcher"] {
            let rowKeys = ["shortcut-badge", "icon-chip"]
            for key in rowKeys where lr[key] != nil {
                Log.line("config: [launcher].\(key) moved in v6 —"
                         + " place it under [launcher.row].\(key).")
            }
        }
        // v5 [launcher.effect] retired in v6 — split into
        // [launcher.animation] (open/close) + [launcher.decoration]
        // (border). Section-level warning + per-key hints.
        if let le = doc.tables["launcher.effect"] {
            Log.line("config: [launcher.effect] was retired in v6 —"
                + " split into [launcher.animation] (open / close) +"
                + " [launcher.decoration] (border). Until renamed,"
                + " the values from this section are ignored.")
            let effectKeyRenames: [(old: String, new: String)] = [
                ("open",   "[launcher.animation].open"),
                ("close",  "[launcher.animation].close"),
                ("border", "[launcher.decoration].border"),
            ]
            for r in effectKeyRenames where le[r.old] != nil {
                Log.line("config: [launcher.effect].\(r.old) moved in"
                         + " v6 — place it under \(r.new).")
            }
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

    /// Warn once per row when an item carries fields that only render
    /// in `[launcher].layout = "list"`. Toolbar variants are short
    /// horizontal strips with no room for a section header, a 2nd-line
    /// subtitle, or a row separator — those fields parse cleanly but
    /// never appear, leaving dead config in the file.
    ///
    /// `shortcut-badge` at `[launcher]` level is intentionally not
    /// surfaced here: it's a global default with a true/false value
    /// that doesn't change toolbar's behaviour either way, so warning
    /// about it would just add noise.
    private static func warnToolbarOnlyFields(items: [LauncherItem],
                                               layout: LauncherLayout) {
        guard layout != .list else { return }
        for (idx, item) in items.enumerated() {
            var ignored: [String] = []
            if !item.header.isEmpty {
                ignored.append("`header = \"\(item.header)\"`")
            }
            if !item.subtitle.isEmpty {
                ignored.append("`subtitle = \"\(item.subtitle)\"`")
            }
            if item.separatorBefore {
                ignored.append("`separator-before = true`")
            }
            guard !ignored.isEmpty else { continue }
            let label = "[[item]][\(idx)]"
                + (item.name.isEmpty ? "" : " \(item.name)")
            Log.line("config: \(label) — "
                + "\(ignored.joined(separator: ", ")) only apply to"
                + " `[launcher].layout = \"list\"`. Current layout is"
                + " \"\(layout.rawValue)\", so these fields are"
                + " ignored.")
        }
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
            //
            // Warn if the user also set action-* / state fields on
            // the parent: those rows parse cleanly but are silently
            // dropped because the dynamic branch renders the parent
            // as a folder (no action, no selectability), and the
            // dynamic-folder render path bypasses `renderItemLabel`
            // entirely (so `state = "on"` / `state = "shell:..."`
            // never produces a checkmark or runs the shell).
            //
            // `[[gesture.rule]]` drops + logs on bad action; the
            // dynamic-launcher parent keeps working but tells the
            // user exactly which lines are dead.
            var strayDynamicFields: [String] = [
                "action-type", "action-keys", "action-verb",
                "action-cmd", "action-url",
            ].filter { !row.string($0).isEmpty }
            if !row.string("state").isEmpty {
                strayDynamicFields.append("state")
            }
            if !strayDynamicFields.isEmpty {
                Log.line("config: \(label) — `dynamic` is set, so the"
                    + " parent's own "
                    + "\(strayDynamicFields.joined(separator: " / "))"
                    + " is ignored (the row renders as a folder for"
                    + " the dynamic children, not as a selectable"
                    + " leaf). Remove these lines from this row to"
                    + " silence this warning.")
            }
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

        // `icon-anim` / `tint` / `tint-colors` only apply to SF
        // Symbol icons — the adapter's symbol-effect and palette
        // paths gate on the `SF:` prefix, so an emoji / file path /
        // `app:` icon (or no icon at all) silently ignores them.
        // Warn once per offending row so the dead config is visible
        // in the log. Default-empty fields stay silent.
        if !icon.hasPrefix("SF:") {
            var ignored: [String] = []
            if !iconAnim.isEmpty {
                ignored.append("icon-anim = \"\(iconAnim)\"")
            }
            if !tint.isEmpty {
                ignored.append("tint = \"\(tint)\"")
            }
            if !tintColors.isEmpty {
                ignored.append("tint-colors = "
                    + "[\(tintColors.map { "\"\($0)\"" }.joined(separator: ", "))]")
            }
            if !ignored.isEmpty {
                let iconDescription = icon.isEmpty
                    ? "no icon set"
                    : "a non-SF-Symbol icon (\"\(icon)\")"
                Log.line("config: \(label) — "
                    + "\(ignored.joined(separator: ", ")) only apply"
                    + " to SF Symbol icons (icon = \"SF:...\")."
                    + " Current item has \(iconDescription), so"
                    + " these fields are ignored.")
            }
        }
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
