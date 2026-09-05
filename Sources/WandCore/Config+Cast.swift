// The `[cast]` half of the config surface: the bespoke parse
// (`parseCast` — palette inheritance, chomp masking, fire) and the
// rule arrays (`parseRules`), plus the `configSpec` sections that
// describe them. `parseAction` / `parseEnum` stay in Config.swift
// (shared with tome).

import ConfigSchema
import Foundation
import Palette
import Toml

extension WandConfig {
    /// Everything `parse` resolves from `[cast]` and its sub-blocks
    /// (recognition / overlay + chomp masking / fire), plus the cast
    /// trigger identity `parseTome` needs for the collision check.
    struct CastParse {
        let trigger: Trigger
        let intensity: EffectIntensity
        let theme: String
        let recognition: CastRecognitionSpec
        let overlay: CastOverlaySpec
        let chomp: ChompSpec?
        let fire: CastFireSpec
    }

    static func parseCast(_ doc: TOMLDocument, _ d: Decoded) -> CastParse {
        // [cast] — trigger identity + family-wide knobs (intensity,
        // theme).
        let button = d.button
        let mods = d.modifiers
        let intensity = d.intensity

        // `[cast].theme` — derived to a cast palette that supplies
        // defaults for trail + cards colour fields. Individual keys
        // still win when explicitly non-empty in the TOML.
        let theme = d.theme
        let palette = wandCastPalette(theme)

        // [cast.recognition] — sample → direction tuning.
        let recognition = CastRecognitionSpec(
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
        let trail = CastOverlayTrailSpec(
            color: trailColor,
            colorNoMatch: trailColorNoMatch,
            colorOutline: trailColorOutline,
            width: parsedTrailWidth,
            style: trailStyle,
            finalHoldMs: trailFinalHoldMs,
            straightenOnTurn: trailStraightenOnTurn)

        // [cast.overlay.badge]
        let badge = CastOverlayBadgeSpec(
            enabled: d.badgeEnabled,
            size: d.badgeSize,
            animEnabled: d.badgeAnimEnabled)

        // [cast.overlay.cards]
        let cards = CastOverlayCardsSpec(
            fire: d.cardsFire, cancel: d.cardsCancel,
            armed: d.cardsArmed,
            linePets: d.cardsLinePets,
            fontSize: d.cardsFontSize,
            firesAppIcon: d.cardsFiresAppIcon)

        // [cast.overlay.no-match]
        let noMatch = CastOverlayNoMatchSpec(kind: d.noMatchKind)

        let overlay = CastOverlaySpec(
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
        let burst = CastFireBurstSpec(kind: d.burstKind,
                                          color: burstColor)

        // [cast.fire.decal]
        let decal = CastFireDecalSpec(
            kind: d.decalKind,
            durationMs: d.decalDurationMs,
            size: d.decalSize)

        let fire = CastFireSpec(burst: burst, decal: decal)

        return CastParse(
            trigger: Trigger(button: button, modifiers: mods),
            intensity: intensity,
            theme: theme,
            recognition: recognition,
            overlay: overlay,
            chomp: chomp,
            fire: fire)
    }

    /// `[[cast.cursor.rule]]` + `[[cast.focused.rule]]`, in that order.
    static func parseRules(_ doc: TOMLDocument) -> [Rule] {
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
        return rules
    }

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

    /// `[cast]` … `[cast.fire.decal]` — the order `configSpec` emits them.
    static var castSpecSections: [ConfigSchema.Section<Decoded>] {
        [
            .init("cast",
                  doc: "Cast trigger (button + drag draws a shape) + "
                     + "cast-wide effect intensity + theme.",
                  fields: [
                .button("button", \.button, default: .right,
                        doc: "Mouse button that arms a cast stroke."),
                .modifiers("modifiers", \.modifiers,
                           doc: "Keyboard modifiers held with the button; "
                              + "`[]` = none. Unknown names dropped."),
                .enumField("intensity", \.intensity, section: "cast",
                           domain: EffectIntensity.allCases.map(\.rawValue),
                           default: .normal,
                           doc: "Effect-magnitude multiplier spanning "
                              + "`[cast.overlay.cards]` + `[cast.fire.burst]`."),
                .theme("theme", \.theme,
                       doc: "Cast HUD theme (sill catalog + `neon` / "
                          + "`splatoon` engine themes); `random` picks one "
                          + "per launch; `\"\"` = native `system`."),
            ]),

            .init("cast.recognition",
                  doc: "Sample → direction tuning (recognition quality "
                     + "only; no visual output).",
                  fields: [
                .clampInt("min-stroke-px", \.minStrokePx, min: 4, max: 200,
                          default: 16,
                          doc: "Min displacement (px) before a new "
                             + "direction is emitted. Clamped 4..200."),
                .clampMs("max-segment-ms", \.maxSegmentMs, min: 100, max: 60000,
                         default: 0,
                         doc: "Max time (ms) one segment may take; `0` = no "
                            + "limit. Clamped 100..60000 when set."),
                .clampMs("cancel-reversals", \.cancelReversals, min: 1, max: 20,
                         default: 2,
                         doc: "180° reversals that abandon the stroke; `0` = "
                            + "off. Clamped 1..20 when set."),
                .clampMs("cancel-window-ms", \.cancelWindowMs, min: 100, max: 5000,
                         default: 500,
                         doc: "Speed gate (ms) for the scribble cancel; `0` "
                            + "= any speed. Clamped 100..5000 when set."),
            ]),

            .init("cast.overlay",
                  doc: "Cast-trail HUD toggle + blur + colour-cycle "
                     + "period (trail / badge / cards live in sub-blocks).",
                  fields: [
                .bool("enabled", \.overlayEnabled, default: true,
                      doc: "Draw the trail HUD. `false` skips the overlay "
                         + "window entirely (restart to re-enable)."),
                .bool("blur-enabled", \.overlayBlurEnabled, default: true,
                      doc: "Frosted blur under the HUD cards + badge."),
                .clampInt("color-cycle-ms", \.overlayColorCycleMs,
                          min: 100, max: 10000, default: 2000,
                          doc: "Cycle period (ms) for `rainbow` / `neon` "
                             + "colour modes. Clamped 100..10000."),
            ]),

            .init("cast.overlay.trail",
                  doc: "The trail line itself.",
                  fields: [
                .rawColor("color", \.trailColorRaw,
                          doc: "Match-colour. `\"\"` inherits the theme "
                             + "palette; named / hex / `rainbow` / `neon` / "
                             + "`splatoon`."),
                .rawColor("color-no-match", \.trailColorNoMatchRaw,
                          doc: "Colour while the shape can't reach any rule. "
                             + "`\"\"` inherits the theme palette."),
                .rawColor("color-outline", \.trailColorOutlineRaw,
                          doc: "Underlay / outline colour. `\"\"` inherits "
                             + "the theme palette (or = no outline)."),
                .clampInt("width", \.trailWidth, min: 1, max: 40, default: 3,
                          doc: "Stroke width (px). Clamped 1..40. Ignored "
                             + "under `[cast].theme = \"chomp\"`."),
                .enumField("style", \.trailStyle, section: "cast.overlay.trail",
                           domain: TrailStyle.allCases.map(\.rawValue),
                           default: .normal,
                           doc: "Line-shape preset (shape only — colour stays "
                              + "from `color`). Ignored under chomp."),
                .clampInt("final-hold-ms", \.trailFinalHoldMs,
                          min: 0, max: 2000, default: 400,
                          doc: "How long (ms) the trail lingers after a fire. "
                             + "Clamped 0..2000."),
                .bool("straighten-on-turn", \.trailStraightenOnTurn,
                      default: false,
                      doc: "Snap each completed segment onto its axis "
                         + "(diagram look). Forced `true` under chomp."),
            ]),

            .init("cast.overlay.badge",
                  doc: "Origin badge showing the target app's icon at the "
                     + "stroke start point.",
                  fields: [
                .bool("enabled", \.badgeEnabled, default: true),
                .clampInt("size", \.badgeSize, min: 32, max: 96, default: 56,
                          doc: "Badge size (px). Clamped 32..96."),
                .bool("anim-enabled", \.badgeAnimEnabled, default: true,
                      doc: "Scale-in pop when the badge first appears."),
            ]),

            .init("cast.overlay.cards",
                  doc: "Assist-card cosmetics + exit effects.",
                  fields: [
                .enumField("fire", \.cardsFire, section: "cast.overlay.cards",
                           domain: Effect.allCases.map(\.rawValue), default: .off,
                           doc: "Animation when the firing card fires."),
                .enumField("cancel", \.cardsCancel, section: "cast.overlay.cards",
                           domain: Effect.allCases.map(\.rawValue), default: .off,
                           doc: "Animation when a card becomes unreachable."),
                .enumField("armed", \.cardsArmed, section: "cast.overlay.cards",
                           domain: ArmedEffect.allCases.map(\.rawValue),
                           default: .off,
                           doc: "Continuous cue on the currently-armed card."),
                .linePets("line-pets", \.cardsLinePets,
                          doc: "Arcade pets walking the firing card's "
                             + "outline; `[]` = none."),
                .clampInt("font-size", \.cardsFontSize, min: 8, max: 32,
                          default: 13,
                          doc: "Card-text base font size (px). Clamped 8..32."),
                .bool("fires-app-icon", \.cardsFiresAppIcon, default: true,
                      doc: "Prepend the target-app icon to the firing card."),
            ]),

            .init("cast.overlay.no-match",
                  doc: "Banner shown while the in-progress gesture is off "
                     + "every reachable rule.",
                  fields: [
                .enumField("kind", \.noMatchKind, section: "cast.overlay.no-match",
                           domain: NoMatchBanner.allCases.map(\.rawValue),
                           default: .off,
                           doc: "Banner kind; `off` = no banner."),
            ]),

            // Schema-only: `[cast.chomp].size` is read ONLY under
            // `[cast].theme = "chomp"` (conditional masking), so it's
            // decoded bespoke in `parse`. Described here for completion.
            .init("cast.chomp",
                  doc: "Chomp special-theme scale knob — read ONLY when "
                     + "`[cast].theme = \"chomp\"`; under any other theme it "
                     + "is ignored (with a log line).",
                  fields: [
                .descOnly("size",
                          domain: ChompSize.allCases.map(\.rawValue),
                          default: .string(ChompSpec.default.size.rawValue),
                          doc: "Arcade pellet-line scale tier; replaces the "
                             + "trail's `width` under chomp."),
            ]),

            .init("cast.fire.burst",
                  doc: "Fire-moment particle burst at the cursor.",
                  fields: [
                .enumField("kind", \.burstKind, section: "cast.fire.burst",
                           domain: TrailEndKind.allCases.map(\.rawValue),
                           default: .off,
                           doc: "Burst kind; `off` = no burst."),
                .rawColor("color", \.burstColorRaw,
                          doc: "Particle colour. `\"\"` / `\"trail\"` inherits "
                             + "the trail accent; `\"splatoon\"` = random ink; "
                             + "else named / hex."),
            ]),

            .init("cast.fire.decal",
                  doc: "Post-fire ink decal at the cursor.",
                  fields: [
                .enumField("kind", \.decalKind, section: "cast.fire.decal",
                           domain: DecalKind.allCases.map(\.rawValue),
                           default: .off,
                           doc: "Decal kind; `off` = no decal."),
                .clampInt("duration-ms", \.decalDurationMs, min: 0, max: 10000,
                          default: 3000,
                          doc: "How long the decal stays (ms); `0` = off. "
                             + "Clamped 0..10000."),
                .clampInt("size", \.decalSize, min: 10, max: 500, default: 60,
                          doc: "Decal footprint (px). Clamped 10..500."),
            ]),
        ]
    }

    /// `[[cast.cursor.rule]]` / `[[cast.focused.rule]]` (schema-only rows).
    static var castRuleSpecSections: [ConfigSchema.Section<Decoded>] {
        [
            .init("cast.cursor.rule", kind: .arrayOfTables,
                  doc: "Cursor-anchored gesture rule (fires only when the "
                     + "cursor-AX walk resolves a target).",
                  fields: castRuleFields),

            .init("cast.focused.rule", kind: .arrayOfTables,
                  doc: "Frontmost-app fallback gesture rule (fires when the "
                     + "cursor sits on a non-AX surface — Desktop / Dock / "
                     + "menu bar).",
                  fields: castRuleFields),
        ]
    }

    /// `[[cast.cursor.rule]]` / `[[cast.focused.rule]]` row shape —
    /// schema-only (wand parses these from the raw arrays-of-tables with
    /// per-row drop-on-typo). Shared by both contexts.
    private static var castRuleFields: [ConfigSchema.Field<Decoded>] {
        [
            .descOnly("name", doc: "Assist-card label (defaults to the pattern)."),
            .descOnly("pattern",
                      doc: "Direction string from `L` / `U` / `R` / `D` "
                         + "(e.g. `\"DR\"`). Required."),
            .descArray("apps",
                       doc: "Bundle-id globs; empty = `[\"*\"]` (any app)."),
            .descOnly("icon", doc: "Optional card icon (SF: / emoji / path / app:)."),
            .descOnly("filter-title", doc: "Optional title-glob filter."),
            .descOnly("filter-shell", doc: "Optional shell predicate (exit 0 fires)."),
            .descOnly("action-type",
                      domain: ["key", "ax", "shell", "url"],
                      doc: "Action kind; pairs with the matching `action-*`."),
            .descOnly("action-keys", doc: "For `type=key` — e.g. `\"cmd+w\"`."),
            .descOnly("action-verb",
                      domain: Array(Action.axVerbs).sorted(),
                      doc: "For `type=ax` — AX verb."),
            .descOnly("action-cmd", doc: "For `type=shell` — shell command."),
            .descOnly("action-url", doc: "For `type=url` — URL to open."),
        ]
    }
}
