// wand is config.toml-driven, read-only from the daemon's
// perspective: the file is the source of truth, the CLI never writes
// it. Unknown / out-of-range values clamp to defaults — a typo can
// never break recognition.

import Foundation

public struct WandConfig: Sendable {
    /// `[cast]` — the gesture trigger (button + modifiers). Other
    /// gesture-family knobs live in dedicated sub-blocks
    /// (`recognition` / `overlay` / `fire`).
    public var trigger: Trigger
    /// `[cast].intensity` — gesture-wide effect multiplier. Scope
    /// spans `[cast.overlay.cards]` (HUD card particle effects)
    /// AND `[cast.fire.burst]` (cursor-anchored explosion). Decal
    /// has its own size / duration knobs and is not scaled. Kept
    /// inline at the gesture level (next to button / modifiers)
    /// because moving it into either sub-block would mislead about
    /// the scope.
    public var intensity: Intensity
    /// `[cast].theme` — coordinated colour palette for trail +
    /// cards. Individual colour keys still win when explicitly set
    /// in the TOML (non-empty string).
    public var theme: CastTheme
    /// `[cast.pac-man]` — only populated when `theme ==
    /// .pacMan` (the pac-man "special theme"). `nil` under every
    /// other theme. The adapter reads this single field to decide
    /// whether to route the trail through `PacManRenderer` and
    /// what scale to use; the rest of the codebase doesn't need to
    /// know `CastTheme` has a special case.
    public var pacMan: PacManSpec?
    /// `[cast.recognition]` — sample → direction tuning.
    public var recognition: GestureRecognitionSpec
    /// `[exclude].apps` — global bundle-id exclusion list. Applies
    /// to both gesture rules and launcher items.
    public var excludeApps: [String]
    /// `[[cast.rule]]` — gesture pattern → action mappings.
    public var rules: [Rule]
    /// `[cast.overlay]` and sub-blocks — trail + badge + cards.
    public var overlay: GestureOverlaySpec
    /// `[cast.fire]` and sub-blocks — burst + decal.
    public var fire: GestureFireSpec
    /// `[tome]` and sub-blocks — trigger + items + row /
    /// animation / decoration cosmetics.
    public var launcher: LauncherSpec
    /// `[failsafe]` — mandatory safety-net block. See CLAUDE.md
    /// "Safety invariants" for the WHY of the missing-block policy.
    public var failsafe: FailsafeConfig
    /// `false` when the `[failsafe]` block was absent in the parsed
    /// TOML. The App layer refuses to start in that case.
    public var failsafeBlockPresent: Bool

    public static let `default` = WandConfig(
        trigger: Trigger(button: .right, modifiers: []),
        intensity: .normal,
        theme: .default,
        pacMan: nil,
        recognition: .default,
        excludeApps: [],
        rules: [],
        overlay: .default,
        fire: .default,
        launcher: .default,
        failsafe: .default,
        failsafeBlockPresent: true
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

    /// Parse a TOML document containing `[[tome.item]]` entries
    /// (and optionally `[tome].layout`) — the schema `wand
    /// --show-menu --items <PATH>` expects. Same row-level
    /// validation as `[tome]` items in the main config (drop on
    /// missing name / invalid action, with a loud log line), so a
    /// client that screws up the file gets a diagnostic.
    ///
    /// The items file's `[tome].layout` declaration is what
    /// controls the visual orientation for this particular show-menu
    /// call — independent of `~/.config/wand/config.toml`'s
    /// `[tome].layout` (which only applies to the native middle-
    /// click trigger). Default `.list` when missing or unknown.
    public static func parseItems(_ text: String) -> LauncherItemsFile {
        let doc = parseTOMLSubset(text)
        let lr = doc.tables["tome"] ?? [:]
        let layout: LauncherLayout = parseEnum(
            lr, key: "layout", section: "tome", default: .list)
        let items: [LauncherItem] = (doc.arrays["tome.item"] ?? []).enumerated()
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
        // Right-button-drag trigger family. Top-level [cast]
        // holds the trigger (button / modifiers) AND the recognition
        // timing knobs (min-stroke-px, max-segment-ms, cancel-*) —
        // collapsing the old [trigger] + [recognition] split now
        // that they're explicitly gesture-scoped.
        let g = doc.tables["cast"] ?? [:]
        let button = Trigger.Button(rawValue: g.string("button").lowercased())
            ?? .right
        let mods = Set(g.strings("modifiers")
            .compactMap { Modifier(rawValue: $0.lowercased()) })

        // `[cast].intensity` — gesture-wide effect multiplier.
        // Stays inline at the gesture level (next to button /
        // modifiers) because its scope spans both [cast.overlay]
        // cards and [cast.fire] burst — moving it inside either
        // sub-block would mislead about what it scales.
        let intensity: Intensity = parseEnum(
            g, key: "intensity", section: "cast", default: .normal)

        // [cast].theme — coordinated colour palette supplying
        // defaults for trail + cards colour fields. Individual
        // keys still win when explicitly non-empty in the TOML.
        let theme: CastTheme = parseEnum(
            g, key: "theme", section: "cast", default: .default)
        let palette = theme.palette

        // [cast.recognition] — sample → direction tuning. v6 split
        // these out of the bare [cast] block (which now holds only
        // trigger identity + the family-wide intensity knob) so
        // recognition behaviour and trigger identity don't share a
        // section.
        let rec = doc.tables["cast.recognition"] ?? [:]
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

        // [cast.overlay] — shared overlay toggles (enabled + blur);
        // trail / badge / cards each live in their own nested sub-block
        // so each field's scope is visible from the section path.
        let ov = doc.tables["cast.overlay"] ?? [:]
        let overlayEnabled = ov.bool("enabled", true)
        let overlayBlurEnabled = ov.bool("blur-enabled", true)
        let overlayColorCycleMs = clampInt(
            ov, key: "color-cycle-ms",
            default: 2000, lo: 100, hi: 10000)

        // [cast.overlay.trail]
        let tr = doc.tables["cast.overlay.trail"] ?? [:]
        // Theme inheritance: explicit non-empty user value wins,
        // else the active theme's palette value supplies the default.
        // `theme = "default"` reproduces the historical hard-coded
        // values, so existing configs that never set `theme` behave
        // unchanged.
        let trailColor = { let c = tr.string("color")
            return c.isEmpty ? palette.trailColor : c }()
        let trailColorNoMatch = { let c = tr.string("color-no-match")
            return c.isEmpty ? palette.trailColorNoMatch : c }()
        let parsedTrailWidth = clampInt(tr, key: "width",
                                         default: 3, lo: 1, hi: 40)
        let parsedTrailStyle: TrailStyle = parseEnum(
            tr, key: "style", section: "cast.overlay.trail",
            default: .normal)
        // `arrowhead` knob was retired in #115 (replaced by
        // `style = "arrow"` for direction-along-the-whole-path).
        // Any stale `arrowhead = true / false` line in a user config
        // silently drops, per wand's clamp-to-default policy.
        let trailFinalHoldMs = clampInt(tr, key: "final-hold-ms",
                                        default: 400, lo: 0, hi: 2000)
        let parsedTrailStraightenOnTurn = tr.bool("straighten-on-turn", false)
        let trailColorOutline = { let c = tr.string("color-outline")
            return c.isEmpty ? palette.trailColorOutline : c }()

        // ── [cast.pac-man] ──────────────────────────────
        // Special-theme override block. Only active when
        // `[cast].theme = "pac-man"`; under every other theme it's
        // nil so the rest of the codebase can branch on a single
        // optional. The "size" knob replaces the trail's free-form
        // `width`, and the parser also forces `straighten-on-turn =
        // true` for the pac-man render (the arcade-maze metaphor
        // only reads cleanly with axis-snapped corridors). Standard
        // trail knobs (`style` / `width` / `straighten-on-turn`)
        // are silently overridden when present — the warning loop
        // below tells the user exactly which lines are dead.
        let pacManTable = doc.tables["cast.pac-man"] ?? [:]
        let pacMan: PacManSpec?
        if theme == .pacMan {
            let size: PacManSize = parseEnum(
                pacManTable, key: "size",
                section: "cast.pac-man", default: .m)
            pacMan = PacManSpec(size: size)
            var overridden: [String] = []
            if tr["style"] != nil { overridden.append("style") }
            if tr["width"] != nil { overridden.append("width") }
            if tr["straighten-on-turn"] != nil {
                overridden.append("straighten-on-turn")
            }
            if !overridden.isEmpty {
                Log.line("config: [cast.overlay.trail]."
                    + "\(overridden.joined(separator: " / "))"
                    + " is ignored under [cast].theme = \"pac-man\""
                    + " — pac-man is a special theme that locks the"
                    + " trail's style, width, and straighten-on-turn."
                    + " Use [cast.pac-man].size = \"s\" |"
                    + " \"m\" | \"l\" to adjust scale.")
            }
        } else {
            pacMan = nil
            // Only complain when the dead block carries a NON-
            // default value — the bundled config.toml ships the
            // block with `size = "m"` for documentation, and that
            // shouldn't read as a misconfiguration just because the
            // user hasn't picked the pac-man theme yet. Mirrors the
            // launcher's `nonDefault` check below: dead config
            // worth warning about is dead config that's NOT just
            // the default.
            let sizeForCheck: PacManSize = parseEnum(
                pacManTable, key: "size",
                section: "cast.pac-man", default: .m)
            if sizeForCheck != PacManSpec.default.size {
                Log.line("config: [cast.pac-man].size = "
                    + "\"\(sizeForCheck.rawValue)\" is set but"
                    + " [cast].theme = \"\(theme.rawValue)\" — this"
                    + " knob only applies when [cast].theme ="
                    + " \"pac-man\". Either switch themes or remove"
                    + " the line to silence this warning.")
            }
        }

        // When pac-man is active, force the trail render shape to
        // the arcade pellet line:
        //   - `straightenOnTurn = true` (arcade corridors are
        //     orthogonal — the metaphor only reads cleanly with
        //     axis-snapped segments).
        //   - `style = .normal` (the pac-man dispatch in the
        //     adapter is gated on `cfg.pacMan != nil`, not on a
        //     TrailStyle case — `.normal` here is just an inert
        //     placeholder since the renderer never reads it under
        //     pac-man).
        // `width` is left at whatever the user wrote (or default 3)
        // — under pac-man the adapter ignores `trail.width` and
        // uses `cfg.pacMan!.size.scale` directly, so the precise
        // sub-integer values for `.s` / `.m` / `.l` survive without
        // losing the `.l` step to an `Int` cast.
        let trailStyle: TrailStyle =
            pacMan != nil ? .normal : parsedTrailStyle
        let trailStraightenOnTurn =
            pacMan != nil ? true : parsedTrailStraightenOnTurn
        let trail = GestureOverlayTrailSpec(
            color: trailColor,
            colorNoMatch: trailColorNoMatch,
            colorOutline: trailColorOutline,
            width: parsedTrailWidth,
            style: trailStyle,
            finalHoldMs: trailFinalHoldMs,
            straightenOnTurn: trailStraightenOnTurn)

        // [cast.overlay.badge]
        let bd = doc.tables["cast.overlay.badge"] ?? [:]
        let badgeEnabled = bd.bool("enabled", true)
        let badgeSize = clampInt(bd, key: "size",
                                 default: 56, lo: 32, hi: 96)
        let badgeAnimEnabled = bd.bool("anim-enabled", true)
        let badge = GestureOverlayBadgeSpec(
            enabled: badgeEnabled,
            size: badgeSize,
            animEnabled: badgeAnimEnabled)

        // [cast.overlay.cards]
        let cd = doc.tables["cast.overlay.cards"] ?? [:]
        let cardsMatch: Effect = parseEnum(
            cd, key: "match", section: "cast.overlay.cards", default: .none)
        let cardsUnmatch: Effect = parseEnum(
            cd, key: "unmatch", section: "cast.overlay.cards", default: .none)
        let cardsArmed: ArmedEffect = parseEnum(
            cd, key: "armed", section: "cast.overlay.cards", default: .none)
        // `chomp = true` retired in favour of the more general
        // `line-pet = [...]` array (mirrors `[tome.decoration]`).
        // Honour the old key for one release with a loud warning.
        if cd.bool("chomp", false) {
            Log.line("config: [cast.overlay.cards].chomp = true was"
                     + " retired — use line-pet = [\"pac-man\"]"
                     + " instead (value silently ignored)")
        }
        let cardsLinePets: [LinePet] =
            cd.strings("line-pet").compactMap { raw in
                let v = raw.lowercased()
                if let pet = LinePet(rawValue: v) { return pet }
                let valid = LinePet.allCases.map(\.rawValue)
                    .sorted().joined(separator: ", ")
                Log.line("config: [cast.overlay.cards].line-pet contains"
                         + " unrecognised entry \"\(raw)\" — dropped"
                         + " (valid: \(valid))")
                return nil
            }
        let cardsFontSize = clampInt(
            cd, key: "font-size", default: 13, lo: 8, hi: 32)
        // Card colours retired from `[cast.overlay.cards]` (#116) —
        // sole source is now `[cast].theme`. Any stale `border-color`
        // / `body-color` / `text-color` / `fires-color` /
        // `fires-text-color` lines are silently dropped per wand's
        // clamp-to-default policy. Resolution happens in
        // `GestureOverlay.applyConfig` directly from `cfg.theme.palette`.
        let cards = GestureOverlayCardsSpec(
            match: cardsMatch, unmatch: cardsUnmatch,
            armed: cardsArmed,
            linePets: cardsLinePets,
            fontSize: cardsFontSize)

        let overlay = GestureOverlaySpec(
            enabled: overlayEnabled,
            blurEnabled: overlayBlurEnabled,
            colorCycleMs: overlayColorCycleMs,
            trail: trail, badge: badge, cards: cards)

        // [cast.fire.burst]
        let bu = doc.tables["cast.fire.burst"] ?? [:]
        let burstKind: TrailEndKind = parseEnum(
            bu, key: "kind", section: "cast.fire.burst", default: .off)
        let burstColor = { let c = bu.string("color")
            return c.isEmpty ? palette.burstColor : c }()
        let burst = GestureFireBurstSpec(kind: burstKind,
                                          color: burstColor)

        // [cast.fire.decal]
        let de = doc.tables["cast.fire.decal"] ?? [:]
        let decalKind: DecalKind = parseEnum(
            de, key: "kind", section: "cast.fire.decal", default: .off)
        let decalDurationMs = clampInt(
            de, key: "duration-ms",
            default: 3000, lo: 0, hi: 10000)
        let decalSize = clampInt(
            de, key: "size", default: 60, lo: 10, hi: 500)
        // `[cast.fire.decal].color` was retired — decal always uses
        // the Splatoon multi-team palette when enabled (#115). Any
        // stale `color = "..."` line in a user config is silently
        // dropped by the parser, per wand's clamp-to-default policy.
        let decal = GestureFireDecalSpec(
            kind: decalKind,
            durationMs: decalDurationMs,
            size: decalSize)

        let fire = GestureFireSpec(burst: burst, decal: decal)

        // ── [launcher.*] ──────────────────────────────────────
        // Middle-click (or other configured button) contextual
        // menu. Tap not installed when `enabled = false` (default),
        // so a stale `[[tome.item]]` list can't surprise anyone
        // who hasn't opted in.
        let lr = doc.tables["tome"] ?? [:]
        let launcherEnabled = lr.bool("enabled", false)
        let launcherButton = Trigger.Button(rawValue: lr.string("button").lowercased())
            ?? .middle
        let launcherMods = Set(lr.strings("modifiers")
            .compactMap { Modifier(rawValue: $0.lowercased()) })
        // `[tome].layout` — orientation of the native-trigger
        // launcher panel. `--show-menu` items files override this
        // per-call via their own `[tome].layout`. Default `.list`.
        let launcherLayout: LauncherLayout = parseEnum(
            lr, key: "layout", section: "tome", default: .list)
        // `[tome].theme` — coordinated colour palette for the
        // launcher panel. Independent of `[cast].theme`: the two
        // surfaces have different visual constraints (HUD overlay
        // vs system-styled menu blur), so a user can pair them
        // freely or run different looks per family.
        let launcherTheme: TomeTheme = parseEnum(
            lr, key: "theme", section: "tome", default: .default)

        // [tome.row] — per-row visual cosmetics (split from the
        // bare [tome] block so trigger identity stays clean).
        let lrow = doc.tables["tome.row"] ?? [:]
        let launcherRow = LauncherRowSpec(
            shortcutBadge: lrow.bool("shortcut-badge", true),
            iconChip: lrow.bool("icon-chip", true),
            fontSize: clampInt(lrow, key: "font-size",
                                default: 13, lo: 11, hi: 32))

        // [tome.animation]
        let la = doc.tables["tome.animation"] ?? [:]
        let launcherAnimOpen: LauncherOpenAnim = parseEnum(
            la, key: "open", section: "tome.animation", default: .off)
        let launcherAnimClose: LauncherCloseAnim = parseEnum(
            la, key: "close", section: "tome.animation", default: .off)
        let launcherAnimation = LauncherAnimationSpec(
            open: launcherAnimOpen, close: launcherAnimClose)

        // [tome.decoration]
        let ld = doc.tables["tome.decoration"] ?? [:]
        let launcherDecorBorder: LauncherBorder = parseEnum(
            ld, key: "border", section: "tome.decoration", default: .off)
        let launcherDecorCycleMs = clampInt(
            ld, key: "cycle-ms", default: 4000, lo: 500, hi: 10000)
        let launcherDecorBorderWidth = clampInt(
            ld, key: "border-width", default: 2, lo: 1, hi: 10)
        let launcherDecorShadow = ld.bool("shadow", false)
        // `chomp = true` (PR #112 and earlier) was retired in favour
        // of `line-pet = ["pac-man", …]`. `line-pet` itself was then
        // retired (PR #113) in favour of bundling the pets into
        // `border = "pac-man-tail"`. Both old keys still parse but
        // log a warning and are silently ignored.
        if ld.bool("chomp", false) {
            Log.line("config: [tome.decoration].chomp = true was retired"
                     + " — use border = \"pac-man-tail\" for the"
                     + " full maze (the value has been silently ignored)")
        }
        if !ld.strings("line-pet").isEmpty {
            Log.line("config: [tome.decoration].line-pet was retired"
                     + " — the pac-man / ghost pets are now bundled"
                     + " into border = \"pac-man-tail\". Drop this"
                     + " key; set border = \"pac-man-tail\" to keep"
                     + " the look (the value has been silently"
                     + " ignored).")
        }
        let launcherDecoration = LauncherDecorationSpec(
            border: launcherDecorBorder,
            cycleMs: launcherDecorCycleMs,
            borderWidth: launcherDecorBorderWidth,
            shadow: launcherDecorShadow)

        // Warn when the user opted out of the launcher but still
        // configured non-default panel cosmetics — those only fire
        // when a panel actually opens, so they're dead config until
        // `[tome].enabled = true`. Default values stay silent;
        // the log lists exactly what's dead. Skipped when launcher
        // is enabled — the collision check below handles demotion.
        if !launcherEnabled {
            var nonDefault: [String] = []
            if launcherAnimOpen != .off {
                nonDefault.append("[tome.animation].open = \"\(launcherAnimOpen.rawValue)\"")
            }
            if launcherAnimClose != .off {
                nonDefault.append("[tome.animation].close = \"\(launcherAnimClose.rawValue)\"")
            }
            if launcherDecorBorder != .off {
                nonDefault.append("[tome.decoration].border = \"\(launcherDecorBorder.rawValue)\"")
            }
            if !nonDefault.isEmpty {
                Log.line("config: \(nonDefault.joined(separator: ", "))"
                    + " is set but [tome].enabled = false — these"
                    + " knobs only fire when a launcher panel actually"
                    + " opens. Either set [tome].enabled = true,"
                    + " or remove the offending lines.")
            }
        }

        // [[tome.item]] — launcher rows. Same drop-on-typo
        // policy as [[cast.rule]]: bad rows surface in the log
        // with their position.
        let items: [LauncherItem] = (doc.arrays["tome.item"] ?? []).enumerated()
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
            Log.line("config: [tome].button = \"\(launcherButton.rawValue)\""
                + " + modifiers=\(modifierList(launcherMods)) collides"
                + " with [cast] — [tome] disabled for this"
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
            decoration: launcherDecoration,
            theme: launcherTheme)

        // [[cast.rule]] — gesture pattern → action mappings.
        // Log every dropped rule with its position + reason so
        // `--validate` and the daemon log both surface them.
        let rules: [Rule] = (doc.arrays["cast.rule"] ?? []).enumerated()
            .compactMap { idx, row in
                let label = "[[cast.rule]][\(idx)]"
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

        // [failsafe] — mandatory; absence signalled via
        // `failsafeBlockPresent`. See CLAUDE.md "Safety invariants".
        let fs = doc.tables["failsafe"] ?? [:]
        let mouseHoldTimeoutSec = clampInt(
            fs, key: "mouse-hold-timeout-sec",
            default: 30, lo: 5, hi: 300)
        let emergencyReleaseKey: String = {
            let raw = fs.string("emergency-release-key").lowercased()
            return raw.isEmpty ? "esc" : raw
        }()
        let failsafe = FailsafeConfig(
            mouseHoldTimeoutSec: mouseHoldTimeoutSec,
            emergencyReleaseKey: emergencyReleaseKey)
        let failsafeBlockPresent = doc.tables["failsafe"] != nil

        return WandConfig(
            trigger: gestureTrigger,
            intensity: intensity,
            theme: theme,
            pacMan: pacMan,
            recognition: recognition,
            excludeApps: excludes,
            rules: rules,
            overlay: overlay,
            fire: fire,
            launcher: launcher,
            failsafe: failsafe,
            failsafeBlockPresent: failsafeBlockPresent
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
    /// v7 retires the `[gesture]` / `[launcher]` block names (and
    /// every sub-block underneath) in favour of `[cast]` / `[tome]`
    /// — the magical-vocabulary rename that aligns the trigger
    /// families with the rest of wand (bolt / aura / scry).
    /// `[[gesture.rule]]` and `[[launcher.item]]` follow the same
    /// shift to `[[cast.rule]]` / `[[tome.item]]`. Older retirements
    /// (v3-v6) are dropped — wand has no third-party users beyond
    /// curl-template downloaders, and chained migration warnings
    /// just noise the log; users still on a v6 layout get the
    /// targeted v7 hint and can re-run with the bundled template.
    private static func logMigrationWarnings(_ doc: TOMLDocument) {
        let tableRenames: [(old: String, new: String)] = [
            ("gesture",                  "[cast]"),
            ("gesture.recognition",      "[cast.recognition]"),
            ("gesture.overlay",          "[cast.overlay]"),
            ("gesture.overlay.trail",    "[cast.overlay.trail]"),
            ("gesture.overlay.badge",    "[cast.overlay.badge]"),
            ("gesture.overlay.cards",    "[cast.overlay.cards]"),
            ("gesture.fire",             "[cast.fire]"),
            ("gesture.fire.burst",       "[cast.fire.burst]"),
            ("gesture.fire.decal",       "[cast.fire.decal]"),
            ("launcher",                 "[tome]"),
            ("launcher.row",             "[tome.row]"),
            ("launcher.animation",       "[tome.animation]"),
            ("launcher.decoration",      "[tome.decoration]"),
        ]
        for r in tableRenames where doc.tables[r.old] != nil {
            Log.line("config: [\(r.old)] section was renamed in v7 — "
                     + "rename to \(r.new). Until renamed, the "
                     + "values from this section are ignored.")
        }

        let arrayRenames: [(old: String, new: String)] = [
            ("gesture.rule", "[[cast.rule]]"),
            ("launcher.item", "[[tome.item]]"),
        ]
        for r in arrayRenames where doc.arrays[r.old] != nil {
            Log.line("config: [[\(r.old)]] array was renamed in v7 — "
                     + "rename each block to \(r.new). Until renamed, "
                     + "the rows in this array are ignored.")
        }

        // v8: `pacman` → `pac-man` across CastTheme / TomeTheme /
        // TrailStyle (the canonical spelling, and the rename that
        // promotes pac-man from "yet another TrailStyle" to a
        // special CastTheme that locks the trail render shape).
        // The string values silently clamp to defaults today; these
        // warnings turn the silent drop into a loud pointer at the
        // exact line to update.
        let castVal = (doc.tables["cast"] ?? [:]).string("theme")
            .lowercased()
        if castVal == "pacman" {
            Log.line("config: [cast].theme = \"pacman\" was renamed "
                + "in v8 to \"pac-man\" — until renamed the value "
                + "clamps to \"default\". Picking \"pac-man\" now "
                + "also unlocks [cast.pac-man].size = "
                + "\"s\" | \"m\" | \"l\" (replaces width / style / "
                + "straighten-on-turn under this theme).")
        }
        let tomeVal = (doc.tables["tome"] ?? [:]).string("theme")
            .lowercased()
        if tomeVal == "pacman" {
            Log.line("config: [tome].theme = \"pacman\" was renamed "
                + "in v8 to \"pac-man\" — until renamed the value "
                + "clamps to \"default\".")
        }
        let trailVal = (doc.tables["cast.overlay.trail"] ?? [:])
            .string("style").lowercased()
        if trailVal == "pacman" {
            Log.line("config: [cast.overlay.trail].style = \"pacman\" "
                + "was retired in v8 — pac-man is now a special "
                + "theme. Set [cast].theme = \"pac-man\" instead, "
                + "and use [cast.pac-man].size for scale "
                + "(width / style / straighten-on-turn are ignored "
                + "under that theme). Until updated the style "
                + "clamps to \"normal\".")
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
    /// in `[tome].layout = "list"`. Toolbar variants are short
    /// horizontal strips with no room for a section header, a 2nd-line
    /// subtitle, or a row separator — those fields parse cleanly but
    /// never appear, leaving dead config in the file.
    ///
    /// `shortcut-badge` at `[tome]` level is intentionally not
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
                + " `[tome].layout = \"list\"`. Current layout is"
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
    /// `[tome]` items inside the main config and by
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
            // `[[cast.rule]]` drops + logs on bad action; the
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
