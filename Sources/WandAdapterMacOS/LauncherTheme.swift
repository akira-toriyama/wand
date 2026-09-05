// Adapter-side colour resolution for the tome panel: the static
// stroke colour per `LauncherBorder` kind and `TomeColors`, the
// NSColor mirror of Core's `TomeThemePalette` (Core stays AppKit-free).

import AppKit
import WandCore

/// Per-kind stroke colour for non-animated `LauncherBorder` cases.
/// Lives in the adapter (Core stays AppKit-free). `.off` and
/// `.rainbow` are handled by their own code paths and never query
/// this — they trap with a clear message if the switch is ever
/// reached out-of-context.
extension LauncherBorder {
    @MainActor
    var staticColor: NSColor {
        switch self {
        case .terminal:  return NSColor(srgbRed: 0x22 / 255.0,
                                         green: 0xc5 / 255.0,
                                         blue:  0x5e / 255.0, alpha: 1)
        case .neon:      return NSColor(srgbRed: 0x22 / 255.0,
                                         green: 0xd3 / 255.0,
                                         blue:  0xee / 255.0, alpha: 1)
        case .splatoon:  return NSColor(srgbRed: 0xbf / 255.0,
                                         green: 0xff / 255.0,
                                         blue:  0x00 / 255.0, alpha: 1)
        case .mono:      return .white
        case .vapor:     return NSColor(srgbRed: 0xff / 255.0,
                                         green: 0x79 / 255.0,
                                         blue:  0xc6 / 255.0, alpha: 1)
        case .chomp:    return NSColor(srgbRed: 0xff / 255.0,
                                         green: 0xea / 255.0,
                                         blue:  0x00 / 255.0, alpha: 1)
        case .off, .rainbow:
            // Animated kinds (`.rainbow`) + the off case carry their
            // colour another way. Reaching here means the caller
            // used the wrong accessor — fall back loudly rather than
            // render a silent mystery colour.
            assertionFailure(
                "LauncherBorder.staticColor accessed for \(self)")
            return .controlAccentColor
        }
    }
}

/// Resolved theme colours for the panel. Each field is `nil` when the
/// corresponding `TomeThemePalette` slot was empty (or its colour
/// string didn't parse), in which case the row/panel falls back to
/// the system semantic colour. Adapter-layer mirror of
/// `TomeThemePalette` — Core stays free of AppKit.
@MainActor
struct TomeColors {
    let accent: NSColor?        // hover background fill
    let accentText: NSColor?    // text colour while hovered
    let text: NSColor?          // idle row text colour
    /// Solid panel backdrop. When non-nil the system frosted blur is
    /// **replaced** with a solid colour view — required for themes
    /// that need a saturated backdrop the blur can't deliver
    /// (chomp / terminal black, mono OLED, etc).
    let background: NSColor?
    /// When `true`, each `ItemRow` rolls its own random ink from
    /// `NSColorParse.splatoonInks` at init time and keeps it
    /// across every hover. Set when the palette's `accentColor` is
    /// the `"splatoon"` token. Panel-open creates fresh `ItemRow`
    /// instances → fresh per-row inks; the colour only changes
    /// when the menu is dismissed and re-opened. Matches the spec:
    /// "each row random, fixed until the tome closes."
    let accentRandomSplatoon: Bool

    static func resolve(_ palette: TomeThemePalette) -> TomeColors {
        let pick: (String) -> NSColor? = { s in
            s.isEmpty ? nil : NSColorParse.nsColor(s)
        }
        let isSplatoonAccent = palette.accentColor
            .trimmingCharacters(in: .whitespaces)
            .lowercased() == "splatoon"
        return TomeColors(
            accent: isSplatoonAccent ? nil : pick(palette.accentColor),
            accentText: pick(palette.accentTextColor),
            text: pick(palette.textColor),
            background: pick(palette.backgroundColor),
            accentRandomSplatoon: isSplatoonAccent)
    }

    static let none = TomeColors(accent: nil, accentText: nil,
                                  text: nil, background: nil,
                                  accentRandomSplatoon: false)

    /// Pick black or white text against an arbitrary fill so the
    /// label stays legible. BT.601 luma gate at 0.55 — the Splatoon
    /// ink palette has two brights (yellow / lime) where white-on-
    /// white fails and a 0.5 threshold isn't enough headroom; 0.55
    /// pushes those two onto black text and leaves the rest on
    /// white.
    static func legibleText(on fill: NSColor) -> NSColor {
        let c = fill.usingColorSpace(.sRGB) ?? fill
        let luma = 0.299 * c.redComponent
                 + 0.587 * c.greenComponent
                 + 0.114 * c.blueComponent
        return luma > 0.55 ? .black : .white
    }
}
