// wand is config.toml-driven, read-only from the daemon's
// perspective: the file is the source of truth, the CLI never writes
// it. Unknown / out-of-range values clamp to defaults — a typo can
// never break recognition.

import ConfigSchema
import Foundation
import Palette
import Toml

// wand's four-case TOML model + flat document folded into sill's shared
// `Toml` module in atelier Phase 1.6. `Toml.Document` has the exact
// `{tables, arrays}` shape wand's old `TOMLDocument` had, and `Toml.Value`
// is a superset of the old `TOMLValue` (adds .double/.array/.table/AoT),
// so these aliases keep every signature and `if case .string(...)` read
// site unchanged. Values are read through the accessor extension below.
private typealias TOMLValue = Toml.Value
private typealias TOMLDocument = Toml.Document

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
    public var intensity: EffectIntensity
    /// `[cast].theme` — the canonical theme name (sill's catalog +
    /// wand's `neon` / `splatoon` engine themes). The cast HUD palette
    /// is derived from it via `wandCastPalette`; individual colour keys
    /// still win when explicitly set in the TOML (non-empty string).
    public var theme: String
    /// `[cast.chomp]` — only populated when `theme == "chomp"` (the
    /// chomp "special theme"). `nil` under every other theme. The
    /// adapter reads this single field to decide whether to route the
    /// trail through `ChompRenderer` and what scale to use; the rest of
    /// the codebase doesn't need to know `chomp` is a special case.
    public var chomp: ChompSpec?
    /// `[cast.recognition]` — sample → direction tuning.
    public var recognition: GestureRecognitionSpec
    /// `[exclude].apps` — global bundle-id exclusion list. Applies
    /// to both gesture rules and launcher items.
    public var excludeApps: [String]
    /// `[[cast.cursor.rule]]` + `[[cast.focused.rule]]` — gesture
    /// pattern → action mappings, tagged with their activation
    /// context (`RuleContext.cursor` / `.focused`).
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
        theme: wandDefaultThemeName,
        chomp: nil,
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

    /// Parse a TOML document containing `[[tome.cursor.item]]` entries
    /// (and optionally `[tome].layout`) — the schema `wand
    /// tome --open --items <PATH>` expects. Same row-level
    /// validation as `[tome]` items in the main config (drop on
    /// missing name / invalid action, with a loud log line), so a
    /// client that screws up the file gets a diagnostic.
    ///
    /// The items file's `[tome].layout` declaration is what
    /// controls the visual orientation for this particular show-menu
    /// call — independent of `~/.config/wand/config.toml`'s
    /// `[tome].layout` (which only applies to the native middle-
    /// click trigger). Default `.list` when missing or unknown.
    ///
    /// The legacy `[[tome.item]]` header logs + drops; the user must
    /// rename to `[[tome.cursor.item]]` (the namespace explicit form
    /// that pairs symmetrically with `[[cast.cursor.rule]]`).
    public static func parseItems(_ text: String) -> LauncherItemsFile {
        let doc = Toml.parseFlat(text)
        let lr = doc.tables["tome"] ?? [:]
        let layout: LauncherLayout = parseEnum(
            lr, key: "layout", section: "tome", default: .list)
        warnLegacyTomeItem(doc, scope: "--items file")
        let items: [LauncherItem] = (doc.arrays["tome.cursor.item"] ?? []).enumerated()
            .compactMap { idx, row in parseItem(row, idx: idx) }
        warnToolbarOnlyFields(items: items, layout: layout)
        return LauncherItemsFile(layout: layout, items: items)
    }

    /// Structural validation against the SAME `configSpec` that drives decode
    /// + `--emit-schema` (sill 1.29.0's `Spec.validate` bridge, t-0029). The
    /// STRICT counterpart to the lenient `load()` / `parse()` (which clamp
    /// out-of-range values and drop typo'd keys): it surfaces the type / enum /
    /// range / unknown-key mismatches the loader silently accepts — the
    /// "editor-green-but-load-accepts" gap. Returns every violation (empty =
    /// structurally valid). Throws only if `text` is not parseable TOML at all
    /// (a genuine syntax error, distinct from a schema violation). One source
    /// for decode + emit + validate ⇒ they can't drift.
    public static func validate(_ text: String) throws -> [ValidationError] {
        let root = try Toml.parse(text)
        return configSpec.validate(root)
    }

    public static func parse(_ text: String) -> WandConfig {
        let doc = Toml.parseFlat(text)

        // ── Uniform half: the plain scalar/table keys are driven by the
        // single declarative `configSpec` (which ALSO emits the JSON
        // Schema — see `Config+Spec.swift`). `decode` runs the SAME
        // clamp / enum-parse / theme-resolve the hand-written reads did,
        // writing into a scratch `Decoded` seeded with the parse
        // defaults — so the resolved values below are byte-identical to
        // the old inline reads (proven by `wandparityharness`). The
        // NON-uniform bits (palette inheritance on the `""` colour
        // sentinel, the chomp theme-conditional masking, `[failsafe]`
        // block-present + empty→esc, the arrays-of-tables, the trigger
        // collision) stay bespoke below; the spec still DESCRIBES them.
        var d = Decoded()
        configSpec.decode(doc.tables, into: &d)

        // ── [exclude] ─────────────────────────────────────────
        let excludes = d.excludeApps

        // ── [cast] ────────────────────────────────────────────
        // Trigger identity + family-wide knobs (intensity, theme).
        let button = d.button
        let mods = d.modifiers
        let intensity = d.intensity

        // `[cast].theme` — derived to a cast palette that supplies
        // defaults for trail + cards colour fields. Individual keys
        // still win when explicitly non-empty in the TOML.
        let theme = d.theme
        let palette = wandCastPalette(theme)

        // [cast.recognition] — sample → direction tuning.
        let recognition = GestureRecognitionSpec(
            minStrokePx: d.minStrokePx,
            maxSegmentMs: d.maxSegmentMs,
            cancelReversals: d.cancelReversals,
            cancelWindowMs: d.cancelWindowMs)

        // [cast.overlay] — shared overlay toggles (enabled + blur);
        // trail / badge / cards live in their own nested sub-blocks.
        let overlayEnabled = d.overlayEnabled
        let overlayBlurEnabled = d.overlayBlurEnabled
        let overlayColorCycleMs = d.overlayColorCycleMs

        // [cast.overlay.trail] — colour fields resolve their `""`
        // sentinel against the theme palette (bespoke; the spec stored
        // the raw value). Explicit non-empty user value wins; `""` /
        // unset inherits the active theme's palette (derived from sill).
        // An unset `[cast].theme` resolves to the native `system` theme.
        let tr = doc.tables["cast.overlay.trail"] ?? [:]
        let trailColor = d.trailColorRaw.isEmpty
            ? palette.trailColor : d.trailColorRaw
        let trailColorNoMatch = d.trailColorNoMatchRaw.isEmpty
            ? palette.trailColorNoMatch : d.trailColorNoMatchRaw
        let parsedTrailWidth = d.trailWidth
        let parsedTrailStyle = d.trailStyle
        let trailFinalHoldMs = d.trailFinalHoldMs
        let parsedTrailStraightenOnTurn = d.trailStraightenOnTurn
        let trailColorOutline = d.trailColorOutlineRaw.isEmpty
            ? palette.trailColorOutline : d.trailColorOutlineRaw

        // [cast.chomp] — only read when `[cast].theme = "chomp"`.
        // Under every other theme it's nil so the rest of the codebase
        // branches on a single optional. The `size` knob replaces
        // the trail's free-form `width`, and the parser forces
        // `straighten-on-turn = true` for the chomp render (the
        // arcade-maze metaphor only reads with axis-snapped corridors).
        // Standard trail knobs (`style` / `width` / `straighten-on-turn`)
        // are silently overridden when present — the warning below
        // tells the user exactly which lines are dead.
        let chompTable = doc.tables["cast.chomp"] ?? [:]
        let chomp: ChompSpec?
        if theme == "chomp" {
            let size: ChompSize = parseEnum(
                chompTable, key: "size",
                section: "cast.chomp", default: .m)
            chomp = ChompSpec(size: size)
            var overridden: [String] = []
            if tr["style"] != nil { overridden.append("style") }
            if tr["width"] != nil { overridden.append("width") }
            if tr["straighten-on-turn"] != nil {
                overridden.append("straighten-on-turn")
            }
            if !overridden.isEmpty {
                Log.line("config: [cast.overlay.trail]."
                    + "\(overridden.joined(separator: " / "))"
                    + " is ignored under [cast].theme = \"chomp\""
                    + " — chomp is a special theme that locks the"
                    + " trail's style, width, and straighten-on-turn."
                    + " Use [cast.chomp].size = \"s\" |"
                    + " \"m\" | \"l\" to adjust scale.")
            }
        } else {
            chomp = nil
            // Only complain when the block carries a non-default value
            // — the bundled config.toml ships `size = "m"` for
            // documentation, and that shouldn't read as a
            // misconfiguration just because the user hasn't picked
            // the chomp theme yet.
            let sizeForCheck: ChompSize = parseEnum(
                chompTable, key: "size",
                section: "cast.chomp", default: .m)
            if sizeForCheck != ChompSpec.default.size {
                Log.line("config: [cast.chomp].size = "
                    + "\"\(sizeForCheck.rawValue)\" is set but"
                    + " [cast].theme = \"\(theme)\" — this"
                    + " knob only applies when [cast].theme ="
                    + " \"chomp\". Either switch themes or remove"
                    + " the line to silence this warning.")
            }
        }

        // Chomp locks the trail's render shape to the arcade pellet
        // line. `style = .normal` is just an inert placeholder since
        // the renderer is gated on `cfg.chomp != nil`, not on
        // `TrailStyle`. `width` is left as written — the adapter
        // reads `cfg.chomp!.size.scale` directly, so the precise
        // sub-integer values for `.s` / `.m` / `.l` survive.
        let trailStyle: TrailStyle =
            chomp != nil ? .normal : parsedTrailStyle
        let trailStraightenOnTurn =
            chomp != nil ? true : parsedTrailStraightenOnTurn
        let trail = GestureOverlayTrailSpec(
            color: trailColor,
            colorNoMatch: trailColorNoMatch,
            colorOutline: trailColorOutline,
            width: parsedTrailWidth,
            style: trailStyle,
            finalHoldMs: trailFinalHoldMs,
            straightenOnTurn: trailStraightenOnTurn)

        // [cast.overlay.badge]
        let badge = GestureOverlayBadgeSpec(
            enabled: d.badgeEnabled,
            size: d.badgeSize,
            animEnabled: d.badgeAnimEnabled)

        // [cast.overlay.cards]
        let cards = GestureOverlayCardsSpec(
            fire: d.cardsFire, cancel: d.cardsCancel,
            armed: d.cardsArmed,
            linePets: d.cardsLinePets,
            fontSize: d.cardsFontSize,
            firesAppIcon: d.cardsFiresAppIcon)

        // [cast.overlay.no-match]
        let noMatch = GestureOverlayNoMatchSpec(kind: d.noMatchKind)

        let overlay = GestureOverlaySpec(
            enabled: overlayEnabled,
            blurEnabled: overlayBlurEnabled,
            colorCycleMs: overlayColorCycleMs,
            trail: trail, badge: badge, cards: cards,
            noMatch: noMatch)

        // [cast.fire.burst] — `kind` resolved by the spec; the `color`
        // `""` sentinel is resolved against the theme palette bespoke
        // (the spec stored the raw value).
        let burstColor = d.burstColorRaw.isEmpty
            ? palette.burstColor : d.burstColorRaw
        let burst = GestureFireBurstSpec(kind: d.burstKind,
                                          color: burstColor)

        // [cast.fire.decal]
        let decal = GestureFireDecalSpec(
            kind: d.decalKind,
            durationMs: d.decalDurationMs,
            size: d.decalSize)

        let fire = GestureFireSpec(burst: burst, decal: decal)

        // ── [tome.*] ──────────────────────────────────────────
        // Middle-click (or other configured button) contextual menu.
        // Tap not installed when `enabled = false` (default). The plain
        // scalar/table keys come from the spec decode; the items
        // array-of-tables + trigger collision stay bespoke below.
        let launcherEnabled = d.launcherEnabled
        let launcherButton = d.launcherButton
        let launcherMods = d.launcherModifiers
        let launcherLayout = d.launcherLayout
        let launcherTheme = d.launcherTheme

        // [tome.row] — per-row visual cosmetics.
        let launcherRow = LauncherRowSpec(
            shortcutBadge: d.rowShortcutBadge,
            iconChip: d.rowIconChip,
            fontSize: d.rowFontSize)

        // [tome.animation]
        let launcherAnimOpen = d.animOpen
        let launcherAnimClose = d.animClose
        let launcherAnimation = LauncherAnimationSpec(
            open: launcherAnimOpen, close: launcherAnimClose)

        // [tome.decoration] + [tome.decoration.border] — panel statics +
        // the border rim (the family block shape shared with facet/halo
        // [border] and perch [overlay.border]).
        let launcherDecorBorder = d.decorBorder
        let launcherDecoration = LauncherDecorationSpec(
            border: launcherDecorBorder,
            cycleMs: d.decorCycleMs,
            borderWidth: d.decorBorderWidth,
            shadow: d.decorShadow,
            linePets: d.decorLinePets)

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
                nonDefault.append("[tome.decoration.border].effect = \"\(launcherDecorBorder.rawValue)\"")
            }
            if !nonDefault.isEmpty {
                Log.line("config: \(nonDefault.joined(separator: ", "))"
                    + " is set but [tome].enabled = false — these"
                    + " knobs only fire when a launcher panel actually"
                    + " opens. Either set [tome].enabled = true,"
                    + " or remove the offending lines.")
            }
        }

        // [[tome.cursor.item]] — launcher rows. Same drop-on-typo
        // policy as [[cast.cursor.rule]]: bad rows surface in the log
        // with their position. Legacy `[[tome.item]]` header is
        // detected and warned out via `warnLegacyTomeItem` so users
        // notice the breaking rename instead of silently losing every
        // menu row.
        warnLegacyTomeItem(doc, scope: "config")
        let items: [LauncherItem] = (doc.arrays["tome.cursor.item"] ?? []).enumerated()
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

        // [[cast.cursor.rule]] / [[cast.focused.rule]] — cast pattern
        // → action mappings, split by activation context (target-
        // resolution regime). Legacy `[[cast.rule]]` and the
        // `focused-fallback = true` flag both log + drop so the
        // user notices the breaking rename instead of silently losing
        // their rules at recognition time.
        warnLegacyCastRule(doc)
        let cursorRules = parseCastRules(
            doc.arrays["cast.cursor.rule"] ?? [],
            context: .cursor)
        let focusedRules = parseCastRules(
            doc.arrays["cast.focused.rule"] ?? [],
            context: .focused)
        let rules = cursorRules + focusedRules

        // [failsafe] — mandatory; absence signalled via
        // `failsafeBlockPresent`. See CLAUDE.md "Safety invariants".
        let fs = doc.tables["failsafe"] ?? [:]
        let mouseHoldTimeoutSec = clampInt(
            fs, key: "mouse-hold-timeout-seconds",
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
            chomp: chomp,
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
    ///     action-type = "key"           # key | ax | shell | url
    ///     action-keys = "cmd+w"         # for type=key
    ///     action-verb = "close"         # for type=ax
    ///     action-cmd  = "open ..."      # for type=shell
    ///     action-url  = "https://..."   # for type=url

    /// Parse a homogeneous batch of cast rule rows from the given
    /// array-of-tables, tagging each with the supplied `context`.
    /// Same drop-on-typo / loud-log policy applied per row.
    ///
    /// The legacy `focused-fallback` field is detected here and the
    /// row is dropped with a warning telling the user to move it to
    /// `[[cast.focused.rule]]` — the boolean no longer exists on the
    /// `Rule` model; activation context is exclusively a namespace
    /// concern.
    private static func parseCastRules(
        _ rows: [[String: TOMLValue]], context: RuleContext
    ) -> [Rule] {
        let header: String
        switch context {
        case .cursor:  header = "cast.cursor.rule"
        case .focused: header = "cast.focused.rule"
        }
        return rows.enumerated().compactMap { idx, row in
            let label = "[[\(header)]][\(idx)]"
                + (row.string("name").isEmpty
                   ? "" : " \(row.string("name"))")
            if row["focused-fallback"] != nil {
                Log.line("config: dropped \(label) — the "
                         + "`focused-fallback` flag has been removed."
                         + " Move this row to `[[cast.focused.rule]]`"
                         + " (the dedicated namespace for"
                         + " frontmost-app fallback rules) and delete"
                         + " the `focused-fallback` line.")
                return nil
            }
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
            let resolvedApps = apps.isEmpty ? ["*"] : apps
            // Opt-in safety warning: a `[[cast.focused.rule]]` row
            // with `apps = ["*"]` (or empty → ["*"]) dispatches to
            // whichever app happens to be frontmost when the stroke
            // lands on a non-AX surface — surprising by design, but
            // the user opted in by placing the row in this namespace.
            // Don't reject / clamp; surface in `--validate` + the
            // daemon log so the trade-off is visible.
            if context == .focused, resolvedApps.contains("*") {
                let nameForLog = name.isEmpty ? pattern : name
                Log.line("config: cast.focused.rule \"\(nameForLog)\" "
                         + "has `apps = [\"*\"]` — this rule will "
                         + "dispatch to whichever app happens to be "
                         + "frontmost on a non-AX surface. Tighten "
                         + "`apps` to specific bundle ids for "
                         + "predictable targeting.")
            }
            return Rule(name: name.isEmpty ? pattern : name,
                        pattern: pattern,
                        apps: resolvedApps,
                        icon: row.string("icon"),
                        filterTitle: row.string("filter-title"),
                        filterShell: row.string("filter-shell"),
                        context: context,
                        action: action)
        }
    }

    /// Detect the legacy `[[cast.rule]]` header (and the obsolete
    /// `focused-fallback` flag if it shows up there) and emit a loud
    /// warning per row — every row is dropped (we never load the
    /// legacy array). Users must rename to `[[cast.cursor.rule]]`
    /// (default) or `[[cast.focused.rule]]` (non-AX fallback).
    private static func warnLegacyCastRule(_ doc: TOMLDocument) {
        guard let rows = doc.arrays["cast.rule"], !rows.isEmpty
        else { return }
        Log.line("config: [[cast.rule]] is no longer supported "
                 + "(\(rows.count) row(s) dropped). Rename each row "
                 + "to either `[[cast.cursor.rule]]` (default cursor-"
                 + "anchored target) or `[[cast.focused.rule]]` "
                 + "(frontmost-app fallback on Desktop / Dock / menu "
                 + "bar — the former `focused-fallback = true` "
                 + "opt-in). The `focused-fallback` field itself is "
                 + "removed; activation context is the section "
                 + "header now.")
    }

    /// Detect the legacy `[[tome.item]]` header and emit a loud
    /// warning per row — every row is dropped. Users must rename to
    /// `[[tome.cursor.item]]`. `scope` is "config" for the main
    /// daemon config and "--items file" for `tome --open --items`.
    private static func warnLegacyTomeItem(_ doc: TOMLDocument,
                                            scope: String) {
        guard let rows = doc.arrays["tome.item"], !rows.isEmpty
        else { return }
        Log.line("config: [[tome.item]] is no longer supported "
                 + "in the \(scope) (\(rows.count) row(s) dropped). "
                 + "Rename each row to `[[tome.cursor.item]]` — the "
                 + "namespace-explicit form that pairs symmetrically "
                 + "with `[[cast.cursor.rule]]` and leaves room for "
                 + "future `[[tome.<modifier>.item]]` namespaces.")
    }

    /// Clamp a `[lo, hi]` integer, logging when the parsed value
    /// differs from what the user wrote. The uniform `[block]` clamps
    /// run through `configSpec` now (`Config+Spec.swift`); this stays
    /// for the bespoke `[failsafe]` knob (decoded outside the spec
    /// because of the block-present semantics).
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
    /// where RawValue == String` powers the lookup. The uniform
    /// `[block]` enums run through `configSpec` now; this stays for the
    /// bespoke `[cast.chomp].size` (read conditionally on the theme) and
    /// the `[tome].layout` of a standalone `--items` file (`parseItems`).
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

    /// Row-level parse for a single `[[item]]`. Shared by the
    /// `[tome]` items inside the main config and by
    /// `parseItems(_:)` for the `tome --open --items <PATH>` path.
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
            // `[[cast.cursor.rule]]` drops + logs on bad action; the
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
        self[key]?.asString ?? fallback
    }
    func int(_ key: String, _ fallback: Int) -> Int {
        // sill stores ints as Int64; `asInt` narrows to wand's field
        // width and (deliberately) does NOT coerce a `.double`, so a
        // fractional value falls back exactly like the old skip-on-typo.
        self[key]?.asInt ?? fallback
    }
    func bool(_ key: String, _ fallback: Bool) -> Bool {
        self[key]?.asBool ?? fallback
    }
    func strings(_ key: String, _ fallback: [String] = []) -> [String] {
        // Old wand had a dedicated `.stringArray` case; sill stores a
        // generic `.array` and projects to strings on read (non-strings
        // dropped — same net result as the old string-only array parse).
        self[key]?.asStringArray ?? fallback
    }
}
