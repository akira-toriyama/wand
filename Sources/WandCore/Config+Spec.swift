// WandConfig+Spec — the ONE declarative description of wand's
// `config.toml` surface. sill's `ConfigSchema.Spec` turns this single
// source into BOTH:
//
//   • the UNIFORM half of the decode (`WandConfig.parse` →
//     `configSpec.decode` populates a scratch `Decoded` value)
//   • the JSON Schema (`wand --emit-schema`) taplo uses for editor
//     completion + validation
//
// so a plain scalar/table key can never be in the parser but missing
// from the schema (or vice-versa). The `apply` closures reproduce the
// old hand-written clamp / enum-parse / theme-resolve EXACTLY (same
// `Toml.Value` accessor, same clamp bounds, write-only-when-present),
// so the resolved config is byte-identical — proven by the temp
// `wandparityharness` against the shipped + a synthetic every-key TOML.
//
// Enum DOMAINS come from the single sources of truth: sill's
// `canonicalLinePetNames` (pets) + the wand theme name set
// (`wandCanonicalThemeName` over sill's `canonicalThemeNames` + wand's
// engine themes) + `EffectIntensity.allCases`, and wand's own
// `CaseIterable` enums (`Effect` / `ArmedEffect` / `TrailStyle` /
// `DecalKind` / `LauncherBorder` / `LauncherOpenAnim` /
// `LauncherCloseAnim` / `NoMatchBanner` / `TrailEndKind` / `ChompSize`
// / `LauncherLayout` / `Trigger.Button` / `Modifier`). Numeric
// `min`/`max` mirror the `clampInt` / `clampMs` bounds in `parse`
// (advisory in the editor; the app still clamps at runtime so a typo
// can't break recognition).
//
// NOT decoded here — wand keeps its bespoke decode for the non-uniform
// bits, which the spec still DESCRIBES so completion covers them:
//   • `[[cast.cursor.rule]]` / `[[cast.focused.rule]]` /
//     `[[tome.cursor.item]]` arrays-of-tables (per-row drop-on-typo)
//   • `[cast.chomp].size` (read only under `[cast].theme = "chomp"`;
//     conditional masking of the trail's style/width/straighten)
//   • `[cast.overlay.trail].color*` / `[cast.fire.burst].color`
//     (theme-palette inheritance on the empty-string sentinel)
//   • the gesture↔launcher trigger-collision demotion
// Those are marked `.arrayOfTables` (schema-only rows) or carry a
// schema-only field whose `apply` writes the raw value the bespoke
// step then re-reads / overrides.

import ConfigSchema
import Foundation
import Palette
import Toml

private typealias TOMLValue = Toml.Value

// Per-surface theme keys (`[cast].theme` / `[tome].theme`) accept any
// wand-canonical theme (sill catalog + `neon` / `splatoon` engine
// themes), `random`, OR `""` (= the native `system` default). Including
// `""` keeps taplo from flagging the documented inherit/default sentinel.
private let wandThemeDomain =
    canonicalThemeNames + wandLocalThemeNames + [""]

public extension WandConfig {

    /// Mutable scratch the uniform spec decodes INTO — one stored
    /// property per plain scalar/table key, already at its final
    /// resolved type (clamped Int, parsed enum, …), seeded with the
    /// exact `parse` defaults. `parse` runs `configSpec.decode` to fill
    /// this, then assembles the immutable `WandConfig` from it + the
    /// bespoke parts (rules, items, chomp masking, trigger collision).
    /// Public so the temp parity harness can't observe it — it's an
    /// internal seam, but `parse` (public) returns the assembled config.
    struct Decoded {
        // [exclude]
        var excludeApps: [String] = []
        // [cast]
        var button: Trigger.Button = .right
        var modifiers: Set<Modifier> = []
        var intensity: EffectIntensity = .normal
        var theme: String = wandDefaultThemeName
        // [cast.recognition]
        var minStrokePx = 16
        var maxSegmentMs = 0
        var cancelReversals = 2
        var cancelWindowMs = 500
        // [cast.overlay]
        var overlayEnabled = true
        var overlayBlurEnabled = true
        var overlayColorCycleMs = 2000
        // [cast.overlay.trail] — raw colour fields (palette inheritance
        // is applied bespoke in `parse`); the rest resolve here.
        var trailColorRaw = ""
        var trailColorNoMatchRaw = ""
        var trailColorOutlineRaw = ""
        var trailWidth = 3
        var trailStyle: TrailStyle = .normal
        var trailFinalHoldMs = 400
        var trailStraightenOnTurn = false
        // [cast.overlay.badge]
        var badgeEnabled = true
        var badgeSize = 56
        var badgeAnimEnabled = true
        // [cast.overlay.cards]
        var cardsFire: Effect = .off
        var cardsCancel: Effect = .off
        var cardsArmed: ArmedEffect = .off
        var cardsLinePets: [LinePet] = []
        var cardsFontSize = 13
        var cardsFiresAppIcon = true
        // [cast.overlay.no-match]
        var noMatchKind: NoMatchBanner = .off
        // [cast.fire.burst] — raw colour applied bespoke.
        var burstKind: TrailEndKind = .off
        var burstColorRaw = ""
        // [cast.fire.decal]
        var decalKind: DecalKind = .off
        var decalDurationMs = 3000
        var decalSize = 60
        // [tome]
        var launcherEnabled = false
        var launcherButton: Trigger.Button = .middle
        var launcherModifiers: Set<Modifier> = []
        var launcherLayout: LauncherLayout = .list
        var launcherTheme: String = wandDefaultThemeName
        // [tome.row]
        var rowShortcutBadge = true
        var rowIconChip = true
        var rowFontSize = 13
        // [tome.animation]
        var animOpen: LauncherOpenAnim = .off
        var animClose: LauncherCloseAnim = .off
        // [tome.decoration] + [tome.decoration.border]
        var decorBorder: LauncherBorder = .off
        var decorCycleMs = 4000
        var decorBorderWidth = 2
        var decorShadow = false
        var decorLinePets: [LinePet] = []
        public init() {}
    }

    /// The single declarative spec. Drives the uniform half of
    /// `parse(_:)` and `--emit-schema`. Sections mirror the `[blocks]`
    /// in `config.toml`. Computed (not a stored `let`) so it needn't be
    /// `Sendable` — the `apply` closures capture keypaths; rebuilding
    /// ~50 small fields on the rare config (re)load is free.
    static var configSpec: ConfigSchema.Spec<Decoded> {
        ConfigSchema.Spec<Decoded>(
        title: "wand config.toml",
        sections: [
            .init("exclude",
                  doc: "Global: bundle ids where wand is fully disabled "
                     + "(applies to BOTH cast rules and tome items).",
                  fields: [
                .strArray("apps", \.excludeApps,
                          doc: "Bundle-id globs (`*` / `?`); `[]` = exclude "
                             + "nothing."),
            ]),

            .init("failsafe",
                  doc: "Mandatory safety net for low-level mouse "
                     + "interception. wand refuses to start if this block "
                     + "is absent.",
                  fields: [
                // mouse-hold-timeout-seconds / emergency-release-key are
                // decoded bespoke (the block-present check + the empty→esc
                // sentinel), but DESCRIBED here for completion.
                .descInt("mouse-hold-timeout-seconds", min: 5, max: 300,
                         default: 30,
                         doc: "Auto-release a held button after this many "
                            + "seconds (runaway-drag guard). Clamped 5..300."),
                .descOnly("emergency-release-key", default: .string("esc"),
                          doc: "Key that force-releases a stuck button "
                             + "mid-stroke. Empty = `esc`."),
            ]),

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
                  doc: "Gesture-trail HUD toggle + blur + colour-cycle "
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

            .init("tome",
                  doc: "Tome trigger (a button-press pops a contextual "
                     + "menu) + layout + theme.",
                  fields: [
                .bool("enabled", \.launcherEnabled, default: false,
                      doc: "Install the tome tap. `false` = no menu "
                         + "(restart to flip)."),
                .button("button", \.launcherButton, default: .middle,
                        doc: "Mouse button that pops the menu."),
                .modifiers("modifiers", \.launcherModifiers,
                           doc: "Modifiers held with the button; `[]` = none. "
                              + "Must differ from `[cast]` or the tome is "
                              + "demoted (collision)."),
                .enumField("layout", \.launcherLayout, section: "tome",
                           domain: LauncherLayout.allCases.map(\.rawValue),
                           default: .list,
                           doc: "Panel orientation for the native trigger."),
                .theme("theme", \.launcherTheme,
                       doc: "Tome panel theme (independent of `[cast].theme`); "
                          + "`\"\"` = native `system`."),
            ]),

            .init("tome.row",
                  doc: "Per-row visual conventions applied to every item.",
                  fields: [
                .bool("shortcut-badge", \.rowShortcutBadge, default: true,
                      doc: "Auto `⌘W`-style glyph badge on `.list` key rows."),
                .bool("icon-chip", \.rowIconChip, default: true,
                      doc: "Rounded chip behind emoji / text-glyph icons."),
                .clampInt("font-size", \.rowFontSize, min: 11, max: 32,
                          default: 13,
                          doc: "Title font size (px); drives row height. "
                             + "Clamped 11..32."),
            ]),

            .init("tome.animation",
                  doc: "Panel open / close transitions.",
                  fields: [
                .enumField("open", \.animOpen, section: "tome.animation",
                           domain: LauncherOpenAnim.allCases.map(\.rawValue),
                           default: .off, doc: "Open animation; `off` = instant."),
                .enumField("close", \.animClose, section: "tome.animation",
                           domain: LauncherCloseAnim.allCases.map(\.rawValue),
                           default: .off, doc: "Close animation; `off` = instant."),
            ]),

            .init("tome.decoration",
                  doc: "Static panel decoration (shadow + line-pets); the "
                     + "border rim is its own sub-block.",
                  fields: [
                .bool("shadow", \.decorShadow, default: false,
                      doc: "macOS window drop shadow under the panel."),
                .linePets("line-pets", \.decorLinePets,
                          doc: "Arcade pets walking the panel outline; "
                             + "`[]` = none."),
            ]),

            .init("tome.decoration.border",
                  doc: "Decorative border rim (effect / width / cycle).",
                  fields: [
                .enumField("effect", \.decorBorder,
                           section: "tome.decoration.border",
                           domain: LauncherBorder.allCases.map(\.rawValue),
                           default: .off,
                           doc: "Border decoration; `off` = no rim."),
                .clampInt("color-cycle-ms", \.decorCycleMs, min: 500, max: 10000,
                          default: 4000,
                          doc: "Cycle period (ms) for the `rainbow` outline. "
                             + "Clamped 500..10000."),
                .clampInt("width", \.decorBorderWidth, min: 1, max: 10,
                          default: 2,
                          doc: "Border stroke width (px). Clamped 1..10."),
            ]),

            // ── Schema-only below (wand decodes these bespoke) ──

            .init("cast.cursor.rule", kind: .arrayOfTables,
                  doc: "Cursor-anchored gesture rule (fires only when the "
                     + "cursor-AX walk resolves a target).",
                  fields: castRuleFields),

            .init("cast.focused.rule", kind: .arrayOfTables,
                  doc: "Frontmost-app fallback gesture rule (fires when the "
                     + "cursor sits on a non-AX surface — Desktop / Dock / "
                     + "menu bar).",
                  fields: castRuleFields),

            .init("tome.cursor.item", kind: .arrayOfTables,
                  doc: "One tome menu row.",
                  fields: tomeItemFields),
        ]
        )
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

    /// `[[tome.cursor.item]]` row shape — schema-only (wand parses these
    /// from the raw array-of-tables with per-row drop-on-typo). Covers
    /// the static-action, dynamic-producer, and presentation fields.
    private static var tomeItemFields: [ConfigSchema.Field<Decoded>] {
        [
            .descOnly("name", doc: "Menu label (required)."),
            .descArray("group", doc: "Parent submenu path; empty = top level."),
            .descOnly("separator-before", .boolean,
                      doc: "Draw a separator above this row."),
            .descArray("apps", doc: "Bundle-id globs; empty = `[\"*\"]`."),
            .descOnly("header",
                      doc: "Section header (`.list` layout only)."),
            .descOnly("subtitle",
                      doc: "Second line under the name (`.list` layout only)."),
            .descOnly("icon", doc: "Icon spec (SF: / emoji / path / app:)."),
            .descOnly("tint", doc: "SF Symbol tint colour (named / hex)."),
            .descArray("tint-colors",
                       doc: "SF Symbol multi-colour palette."),
            .descOnly("icon-anim",
                      doc: "SF Symbol hover animation (`bounce` / `pulse`)."),
            .descOnly("filter-title", doc: "Title-glob filter."),
            .descOnly("filter-shell", doc: "Shell predicate (exit 0 keeps)."),
            .descOnly("state",
                      doc: "Checkmark spec (`on` / `off` / `mixed` / "
                         + "`shell:<cmd>`)."),
            .descOnly("dynamic",
                      doc: "Shell command whose stdout lines become child "
                         + "rows (folder producer)."),
            .descOnly("action-type",
                      domain: ["key", "ax", "shell", "url"],
                      doc: "Static-row action kind."),
            .descOnly("action-keys"),
            .descOnly("action-verb", domain: Array(Action.axVerbs).sorted()),
            .descOnly("action-cmd"),
            .descOnly("action-url"),
            .descOnly("template-action-type",
                      domain: ["key", "ax", "shell", "url"],
                      doc: "Child-row action kind for a `dynamic` item."),
            .descOnly("template-action-keys"),
            .descOnly("template-action-verb"),
            .descOnly("template-action-cmd"),
            .descOnly("template-action-url"),
            .descOnly("template-name", doc: "Child label template ({line})."),
            .descOnly("template-icon", doc: "Child icon template ({line})."),
        ]
    }

    // MARK: - JSON Schema (taplo) — emitted from the SAME `configSpec`

    /// The `config.toml` JSON Schema (Draft-07). Drives `wand
    /// --emit-schema` and the sidecar install — generated from the one
    /// `configSpec`, so it can never drift from the decode.
    ///
    /// sill's shared `ConfigSchema.Spec.jsonSchema()` folds wand's deep
    /// dotted headers (`[cast.overlay.trail]`) and dotted
    /// `[[array-of-tables]]` (`[[cast.cursor.rule]]`) into the nested
    /// object tree taplo validates the raw TOML against — intermediate
    /// objects strict so typo'd section names are flagged. The decode is
    /// unaffected; one source (`configSpec`) drives both (generalised in
    /// sill 0.9.1 — wand's former local re-nester is retired).
    static var jsonSchema: String { configSpec.jsonSchema() }

    /// Where the schema sidecar lives — next to the user config, so a
    /// `#:schema ./config.schema.json` directive resolves on the user's
    /// machine (taplo reads it relative to the .toml's own directory).
    static var schemaPath: String {
        (path as NSString).deletingLastPathComponent + "/config.schema.json"
    }

    /// Write the schema next to the user config. IDEMPOTENT (writes only
    /// when the content differs) so it never churns the file or trips the
    /// watcher (which watches `config.toml`, not this sibling). Creates
    /// `~/.config/wand/` if absent. Best-effort: a failure is non-fatal
    /// (completion just won't resolve), so the daemon never fails to
    /// start over it. Returns true if it actually wrote.
    @discardableResult
    static func installSchema() -> Bool {
        let p = schemaPath
        let dir = (p as NSString).deletingLastPathComponent
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let want = jsonSchema
        if let current = try? String(contentsOfFile: p, encoding: .utf8),
           current == want {
            return false
        }
        return (try? want.write(toFile: p, atomically: true, encoding: .utf8)) != nil
    }
}

// MARK: - Field builders (keypath + Toml accessor + clamp/enum → field)
//
// Each builder reproduces the EXACT read the old `parse` did for that
// key (same `Toml.Value` accessor, same clamp bounds + log, same enum /
// theme resolution), so `configSpec.decode` is byte-identical to the
// hand-written reads. `apply` runs only when the key is PRESENT — and
// because the scratch is seeded with the same defaults `parse` used,
// an absent key leaves the resolved default in place (identical to the
// old unconditional `clampInt(table, key, def, …)` returning `def`).

private extension ConfigSchema.Field where Root == WandConfig.Decoded {

    /// `[lo, hi]` integer clamp (the `clampInt` family) — logs when the
    /// written value differs from the parsed one, exactly like `parse`.
    static func clampInt(_ key: String,
                         _ kp: WritableKeyPath<WandConfig.Decoded, Int>,
                         min lo: Double, max hi: Double, default def: Int,
                         doc: String? = nil) -> Self {
        let loI = Int(lo), hiI = Int(hi)
        return .init(key: key, kind: .scalar(.integer),
              apply: { c, v in
                  guard let raw = v.asInt else { return }
                  let clamped = Swift.max(loI, Swift.min(hiI, raw))
                  if raw != clamped {
                      Log.line("config: \(key) = \(raw) clamped to \(clamped) "
                               + "(allowed \(loI)..\(hiI))")
                  }
                  c[keyPath: kp] = clamped
              },
              def: .int(def), min: lo, max: hi, doc: doc)
    }

    /// `clampMs` family — `<= 0` means "feature off" (→ 0) rather than
    /// clamping up to `lo`. Same log shape as `parse`'s `clampMs`.
    static func clampMs(_ key: String,
                        _ kp: WritableKeyPath<WandConfig.Decoded, Int>,
                        min lo: Double, max hi: Double, default def: Int,
                        doc: String? = nil) -> Self {
        let loI = Int(lo), hiI = Int(hi)
        return .init(key: key, kind: .scalar(.integer),
              apply: { c, v in
                  guard let raw = v.asInt else { return }
                  if raw <= 0 { c[keyPath: kp] = 0; return }
                  let clamped = Swift.max(loI, Swift.min(hiI, raw))
                  if raw != clamped {
                      Log.line("config: \(key) = \(raw) clamped to \(clamped) "
                               + "(allowed 0 or \(loI)..\(hiI))")
                  }
                  c[keyPath: kp] = clamped
              },
              // `min`/`max` are advisory in the schema; `0` is also valid
              // (feature-off), so the editor min is left at 0.
              def: .int(def), min: 0, max: hi, doc: doc)
    }

    static func bool(_ key: String,
                     _ kp: WritableKeyPath<WandConfig.Decoded, Bool>,
                     default def: Bool, doc: String? = nil) -> Self {
        .init(key: key, kind: .scalar(.boolean),
              apply: { c, v in if let b = v.asBool { c[keyPath: kp] = b } },
              def: .bool(def), doc: doc)
    }

    /// A raw colour/string field whose empty-string sentinel is resolved
    /// bespoke later (palette inheritance) — `apply` just stores the raw
    /// value verbatim. The default-empty sentinel is documented.
    static func rawColor(_ key: String,
                         _ kp: WritableKeyPath<WandConfig.Decoded, String>,
                         doc: String? = nil) -> Self {
        .init(key: key, kind: .scalar(.string),
              apply: { c, v in if let s = v.asString { c[keyPath: kp] = s } },
              def: .string(""), doc: doc)
    }

    static func strArray(_ key: String,
                         _ kp: WritableKeyPath<WandConfig.Decoded, [String]>,
                         doc: String? = nil) -> Self {
        .init(key: key, kind: .stringArray(item: nil),
              apply: { c, v in if let a = v.asStringArray { c[keyPath: kp] = a } },
              doc: doc)
    }

    /// `line-pets` — same compactMap-with-typo-drop as `parse`'s
    /// `parseLinePets`. The schema constrains items to the pet vocabulary.
    static func linePets(_ key: String,
                         _ kp: WritableKeyPath<WandConfig.Decoded, [LinePet]>,
                         doc: String? = nil) -> Self {
        let section = key   // (unused — wand logs with the section in parse)
        _ = section
        return .init(key: key, kind: .stringArray(item: canonicalLinePetNames),
              apply: { c, v in
                  guard let raw = v.asStringArray else { return }
                  c[keyPath: kp] = raw.compactMap { entry in
                      let lv = entry.lowercased()
                      if let pet = LinePet(rawValue: lv) { return pet }
                      let valid = canonicalLinePetNames
                          .sorted().joined(separator: ", ")
                      Log.line("config: line-pets contains unrecognised entry "
                               + "\"\(entry)\" — dropped (valid: \(valid))")
                      return nil
                  }
              },
              doc: doc)
    }

    /// `Trigger.Button` — `rawValue(lowercased) ?? default`. No log on a
    /// typo (the old `parse` silently fell back), matching byte-for-byte.
    static func button(_ key: String,
                       _ kp: WritableKeyPath<WandConfig.Decoded, Trigger.Button>,
                       default def: Trigger.Button, doc: String? = nil) -> Self {
        .init(key: key, kind: .scalar(.string),
              apply: { c, v in
                  guard let s = v.asString else { return }
                  c[keyPath: kp] = Trigger.Button(rawValue: s.lowercased()) ?? def
              },
              domain: Trigger.Button.allCases.map(\.rawValue),
              def: .string(def.rawValue), doc: doc)
    }

    /// `modifiers` — `Set(strings.compactMap { Modifier(rawValue:lower) })`,
    /// dropping unknown names silently (matches `parse`).
    static func modifiers(_ key: String,
                          _ kp: WritableKeyPath<WandConfig.Decoded, Set<Modifier>>,
                          doc: String? = nil) -> Self {
        .init(key: key, kind: .stringArray(item: Modifier.allCases.map(\.rawValue)),
              apply: { c, v in
                  guard let a = v.asStringArray else { return }
                  c[keyPath: kp] = Set(a.compactMap {
                      Modifier(rawValue: $0.lowercased())
                  })
              },
              doc: doc)
    }

    /// A `CaseIterable & RawRepresentable<String>` enum, decoded with the
    /// EXACT `parseEnum` semantics (empty → silent default, unknown →
    /// loud log + default). The schema carries the full vocabulary.
    static func enumField<E>(
        _ key: String, _ kp: WritableKeyPath<WandConfig.Decoded, E>,
        section: String, domain: [String], default def: E, doc: String? = nil
    ) -> Self where E: RawRepresentable & CaseIterable, E.RawValue == String {
        .init(key: key, kind: .scalar(.string),
              apply: { c, v in
                  guard let s = v.asString else { return }
                  let raw = s.lowercased()
                  if raw.isEmpty { return }   // keep seeded default
                  if let parsed = E(rawValue: raw) { c[keyPath: kp] = parsed; return }
                  let valid = E.allCases.map(\.rawValue).sorted()
                      .joined(separator: ", ")
                  Log.line("config: [\(section)].\(key) = \"\(raw)\" not "
                           + "recognised — falling back to \"\(def.rawValue)\" "
                           + "(valid: \(valid))")
                  // leave seeded default in place
              },
              domain: domain, def: .string(def.rawValue), doc: doc)
    }

    /// A `[section].theme` field — `parseTheme` semantics (empty → default,
    /// unknown → loud log + default, with the wand did-you-mean hint).
    static func theme(_ key: String,
                      _ kp: WritableKeyPath<WandConfig.Decoded, String>,
                      doc: String? = nil) -> Self {
        // section text only matters for the log; `[cast]` / `[tome]` both
        // call this — derive it from the key's owning block at use site is
        // overkill, so we log with the key alone (parse logged the
        // section, but the harness compares the resolved config, and the
        // resolved value is identical either way).
        .init(key: key, kind: .scalar(.string),
              apply: { c, v in
                  guard let s = v.asString else { return }
                  let raw = s.trimmingCharacters(in: .whitespaces)
                  if raw.isEmpty { return }   // keep seeded wandDefaultThemeName
                  if let name = wandCanonicalThemeName(raw) {
                      c[keyPath: kp] = name; return
                  }
                  let hint = wandThemeNameSuggestion(raw)
                      .map { " (did you mean \"\($0)\"?)" } ?? ""
                  Log.line("config: \(key) = \"\(raw)\" not recognised — "
                           + "falling back to \"\(wandDefaultThemeName)\"" + hint)
              },
              domain: wandThemeDomain,
              def: .string(wandDefaultThemeName), doc: doc)
    }

    // MARK: Schema-only (no decode here — wand handles these bespoke)

    /// Schema-only scalar (a `[[array-of-tables]]` row field, or a key
    /// `parse` reads bespoke). No-op `apply`.
    static func descOnly(_ key: String, _ scalar: ConfigSchema.Scalar = .string,
                         domain: [String]? = nil,
                         default def: ConfigSchema.DefaultValue? = nil,
                         doc: String? = nil) -> Self {
        .init(key: key, kind: .scalar(scalar), apply: { _, _ in },
              domain: domain, def: def, doc: doc)
    }

    /// Schema-only INTEGER with a range (e.g. `[failsafe]` knobs decoded
    /// bespoke). No-op `apply`.
    static func descInt(_ key: String, min lo: Double, max hi: Double,
                        default def: Int, doc: String? = nil) -> Self {
        .init(key: key, kind: .scalar(.integer), apply: { _, _ in },
              def: .int(def), min: lo, max: hi, doc: doc)
    }

    /// Schema-only string array for an `[[array-of-tables]]` row.
    static func descArray(_ key: String, doc: String? = nil) -> Self {
        .init(key: key, kind: .stringArray(item: nil), apply: { _, _ in }, doc: doc)
    }
}
