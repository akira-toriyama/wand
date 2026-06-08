// Chomp — the single special-theme family that spans both surfaces
// (cast HUD + tome panel). Picking it as `[cast].theme = "chomp"`
// locks the trail's render shape to the arcade Chomp wedge +
// corridor (handled by `ChompRenderer` in WandAdapterMacOS); picking
// it as `[tome].theme = "chomp"` swaps in the matching arcade
// palette on the menu side. The pellets/ghost/font/wall colours all
// come from one place — this file — so the two surfaces stay
// visually locked.

import CoreGraphics
import Foundation

/// Scale tier for the `chomp` cast theme. Replaces
/// `[cast.overlay.trail].width` when `[cast].theme = "chomp"` is
/// picked — the arcade aesthetic is always a single line of pellets,
/// so a free-form integer width fights the visual; three named tiers
/// give the user real choices without misconfiguration.
///
/// `.m` is the calibrated baseline. `.s` reads as compact arcade-
/// pixel-art; `.l` goes chunky / over-the-top. Carried into
/// `ChompRenderer` as a scale multiplier on every chomp dimension
/// (pellet diameter, spacing, face radius, wall offset, trail lag) so
/// the three sizes stay self-consistent.
public enum ChompSize: String, Sendable, Hashable, CaseIterable {
    case s
    case m
    case l

    /// Scale multiplier applied to every chomp dimension. Tuned so
    /// each step is visibly different at a glance without the large
    /// tier crowding the corridor walls.
    public var scale: CGFloat {
        switch self {
        case .s: return 2.0
        case .m: return 3.0
        case .l: return 4.5
        }
    }
}

/// `[cast.chomp]` — the chomp theme's scale knob. Only read when
/// `[cast].theme = "chomp"`; the parser warns and ignores when the
/// user sets this block under a different theme. Kept as a struct (not
/// folded into `GestureOverlayTrailSpec`) so the "applies under one
/// specific theme" scope is visible from the type alone.
public struct ChompSpec: Sendable, Equatable {
    public let size: ChompSize

    public init(size: ChompSize = .m) {
        self.size = size
    }

    public static let `default` = ChompSpec()
}

/// Shared palette + helpers for the chomp theme on both the cast HUD
/// and the tome panel. Keeping the constants in one namespace prevents
/// the two surfaces from drifting visually.
public enum Chomp {
    /// Arcade Chomp yellow.
    public static let pellet: String = "#ffea00"
    /// Red Blinky ghost.
    public static let ghost: String = "#ff0000"
    /// Arcade maze wall — neon blue. Drives the cast trail's corridor
    /// flanks AND the directional cards' border (both surfaces share
    /// this signature blue).
    public static let wall: String = "#2121ff"
    /// Arcade backdrop — pure black, used as both the cast cards' body
    /// and the tome panel's solid backdrop.
    public static let backdrop: String = "#000000"

    /// `CastThemePalette` for `[cast].theme = "chomp"`. Card scheme
    /// is "uniform body, border tells the state":
    ///   - directional cards: black body + yellow text + neon-blue
    ///     border (matches the corridor walls)
    ///   - firing card: SAME black body + yellow text, but a rainbow
    ///     animated border so "fires on release" reads as the special-
    ///     bonus glow against the solid-blue approach cards.
    public static var castPalette: CastThemePalette {
        CastThemePalette(
            trailColor: pellet,
            trailColorNoMatch: ghost,
            trailColorOutline: wall,
            cardsBorderColor: wall,
            cardsBodyColor: backdrop,
            cardsTextColor: pellet,
            // Empty `cardsFiresColor` / `cardsFiresTextColor` make the
            // firing card share the directional card's body / text —
            // only the border (rainbow) distinguishes the two states.
            cardsFiresColor: "",
            cardsFiresTextColor: "",
            cardsFiresBorderColor: "rainbow",
            badgeBackgroundColor: backdrop)
    }

    /// `TomeThemePalette` for `[tome].theme = "chomp"`. Yellow accent
    /// with black hover text on the canonical arcade black backdrop.
    public static var tomePalette: TomeThemePalette {
        TomeThemePalette(
            accentColor: pellet,
            accentTextColor: backdrop,
            textColor: pellet,
            backgroundColor: backdrop)
    }
}
