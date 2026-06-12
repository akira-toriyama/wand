// The sill theme bridge (atelier block-6). wand's two surfaces — the
// cast HUD (gesture trail + assist cards) and the tome launcher panel —
// each carry a String-token palette (`CastThemePalette` /
// `TomeThemePalette`) whose values flow on to the per-key config
// defaults and are resolved to `NSColor` at draw time by the adapter's
// `NSColorParse`. This file is the seam that DERIVES those String tokens
// from sill's authoritative `ThemeSpec` instead of hand-keeping a wand
// palette per theme, so "stop saying copy facet's theme" holds in code:
// one sill catalog change reaches both wand surfaces.
//
// Mirrors perch's `perchThemeSpec` bridge. The projection is maximally
// sill-driven (atelier Q5): every surface that has a sensible sill role
// derives from it. Three exceptions stay wand-local because sill has no
// equivalent or the surface is an ENGINE, not a static palette:
//   * `neon` / `splatoon` — dynamic engine themes (per-frame neon cycle,
//     per-stroke Splatoon ink). No sill *theme* exists for them; the
//     dynamic tokens (`"neon"` / `"splatoon"`) are resolved by the
//     adapter's `TrailColorMode`. Their surrounding chrome stays the
//     hand-tuned wand palette.
//   * `chomp` — IS a sill catalog theme; its arcade constants derive
//     from `paletteFor("chomp")` (see `Chomp`), but the wall-blue
//     outline/border arrangement + the rainbow firing border are wand
//     motion, so the special `Chomp.castPalette` / `.tomePalette` shape
//     is kept (over sill values).
//   * `system` — the native look (OS control-accent trail + frosted
//     vibrancy surfaces); sill's `system` spec is a vibrancy sentinel,
//     not a concrete palette, so wand expresses it with empty-string
//     (= system default) tokens + the `"accent"` token.

import Foundation
import Palette

/// wand's default theme when `[cast].theme` / `[tome].theme` is unset or
/// fails to resolve — the native look (OS accent + frosted vibrancy).
public let wandDefaultThemeName = "system"

/// Theme names wand supports on TOP of sill's catalog: dynamic engine
/// themes with no static sill palette. Validated alongside
/// `canonicalThemeNames` so a typo is still rejected.
public let wandLocalThemeNames = ["neon", "splatoon"]

/// Validate a raw `[cast].theme` / `[tome].theme` / `--theme=` value —
/// sill's shared `canonical(_:)` mechanism wrapped with wand's local
/// engine themes (neon / splatoon, which sill doesn't know), returning
/// the canonical name or `nil` for an unknown name so the caller can
/// clamp + log (wand's loud-typo discipline — sill's `paletteFor` is
/// silent and would mask a typo as `terminal`). `random` resolves HERE
/// to a concrete name (excluding `system`) so the chosen theme is
/// stable for the session.
public func wandCanonicalThemeName(_ raw: String) -> String? {
    let t = raw.trimmingCharacters(in: .whitespaces).lowercased()
    if t.isEmpty { return nil }
    if t == "random" {
        let pool = canonicalThemeNames.filter { $0 != "random" && $0 != "system" }
            + wandLocalThemeNames
        return pool.randomElement() ?? "terminal"
    }
    if wandLocalThemeNames.contains(t) { return t }
    // Membership + normalization delegate to sill (`random` was
    // intercepted above, so canonical's passthrough is unreachable).
    return canonical(t)
}

/// "Did you mean" hint for an unknown theme name — sill's `suggest(_:)`
/// plus wand's local engine themes (a near-miss like "splatoo" should
/// hint "splatoon", which sill can't know). `nil` when nothing is close.
public func wandThemeNameSuggestion(_ raw: String) -> String? {
    let t = raw.trimmingCharacters(in: .whitespaces).lowercased()
    // Cheap local pass first: prefix/edit-adjacency against the two
    // engine names, mirroring suggest's intent without duplicating its
    // distance machinery.
    if let local = wandLocalThemeNames.first(where: {
        $0.hasPrefix(t) || t.hasPrefix($0) || levenshteinClose(t, $0)
    }) { return local }
    return suggest(raw)
}

/// True when `a` and `b` are within edit distance 2 for short names —
/// just enough for the two local engine themes; sill's `suggest` covers
/// the full catalog.
private func levenshteinClose(_ a: String, _ b: String) -> Bool {
    if abs(a.count - b.count) > 2 { return false }
    // For names this short a simple common-prefix + tail check suffices:
    let common = zip(a, b).prefix(while: { $0 == $1 }).count
    return max(a.count, b.count) - common <= 2
}

// MARK: - Cast HUD palette

/// Project a (canonical) theme name onto the cast HUD's String-token
/// palette. Standard themes derive every surface from sill roles;
/// `neon` / `splatoon` / `chomp` / `system` are the documented
/// exceptions (see file header).
public func wandCastPalette(_ name: String) -> CastThemePalette {
    switch name.lowercased() {
    case "neon":     return .wandNeon
    case "splatoon": return .wandSplatoon
    case "chomp":    return Chomp.castPalette       // sill-derived constants
    case "system":   return .wandSystem
    default:
        let spec = paletteFor(name)                 // sill canonical palette
        let bg = themeHex(spec.background ?? HexColor(0x000000))
        return CastThemePalette(
            trailColor:           themeHex(spec.primary),
            trailColorNoMatch:    themeHex(spec.error),
            trailColorOutline:    bg,
            cardsBorderColor:     themeHex(spec.primary),
            cardsBodyColor:       bg,
            cardsTextColor:       themeHex(spec.foreground),
            // firing card inherits trail accent / directional text /
            // directional border (the historical "" semantics); a solid
            // themed badge backdrop so the icon doesn't float on frost.
            badgeBackgroundColor: bg)
    }
}

extension CastThemePalette {
    /// `neon` — dynamic electric trail (the `"neon"` token cycles the
    /// shared `EffectSpec.neon` flash) on deep violet chrome.
    static let wandNeon = CastThemePalette(
        trailColor: "neon",
        trailColorNoMatch: "#ec4899",
        trailColorOutline: "#000000",
        cardsBorderColor: "neon",
        cardsBodyColor: "#0f0a1f",
        cardsTextColor: "#ffffff",
        badgeBackgroundColor: "#0f0a1f")

    /// `splatoon` — per-stroke random Turf-War ink (the `"splatoon"`
    /// token rolls one ink from `NSColorParse.splatoonInks` per stroke).
    static let wandSplatoon = CastThemePalette(
        trailColor: "splatoon",
        trailColorNoMatch: "#000000",
        trailColorOutline: "#ffffff",
        cardsBorderColor: "splatoon",
        cardsBodyColor: "#1a1a1a",
        cardsTextColor: "#ffffff",
        burstColor: "",
        badgeBackgroundColor: "#1a1a1a")

    /// `system` — native look: OS control-accent trail + cards on the
    /// system frosted blur (empty tokens fall through to system colors).
    static let wandSystem = CastThemePalette(
        trailColor: "accent",
        trailColorNoMatch: "#ef4444",
        trailColorOutline: "",
        cardsBorderColor: "accent",
        cardsBodyColor: "",
        cardsTextColor: "",
        badgeBackgroundColor: "")
}

// MARK: - Tome launcher palette

/// Project a (canonical) theme name onto the tome panel's String-token
/// palette. Same exception set as `wandCastPalette`.
public func wandTomePalette(_ name: String) -> TomeThemePalette {
    switch name.lowercased() {
    case "neon":     return .wandNeon
    case "splatoon": return .wandSplatoon
    case "chomp":    return Chomp.tomePalette       // sill-derived constants
    case "system":   return TomeThemePalette()      // all empty → native vibrancy
    default:
        let spec = paletteFor(name)
        return TomeThemePalette(
            accentColor:     themeHex(spec.primary),
            accentTextColor: themeHex(spec.primary.bestForeground),
            textColor:       themeHex(spec.foreground),
            backgroundColor: themeHex(spec.background ?? HexColor(0x000000)))
    }
}

extension TomeThemePalette {
    static let wandNeon = TomeThemePalette(
        accentColor: "#22d3ee",
        accentTextColor: "#0f0a1f",
        textColor: "#ffffff",
        backgroundColor: "#0f0a1f")

    static let wandSplatoon = TomeThemePalette(
        accentColor: "splatoon",
        accentTextColor: "",      // adapter picks black/white per ink luminance
        textColor: "#ffffff",
        backgroundColor: "#1a1a1a")
}

// MARK: - Hex formatting

/// Format a sill `HexColor` as a wand color token: `#RRGGBB`, or
/// `#RRGGBBAA` when the color carries a non-opaque alpha. The adapter's
/// `NSColorParse` accepts both forms.
func themeHex(_ c: HexColor) -> String {
    if c.alpha >= 1.0 { return String(format: "#%06X", c.rgb) }
    let a = Int((c.alpha * 255).rounded())
    return String(format: "#%06X%02X", c.rgb, a)
}
