// String → NSColor parser shared by every adapter surface that takes
// a colour from config. Originally lived as a `private static` on
// `GestureOverlay`; promoted out so the launcher panel (#59 tint)
// and the upcoming theme system (#62) can reuse the same name +
// hex grammar without copy-paste.
//
// Grammar:
//   - Named: blue / red / green / orange / purple / pink / yellow /
//     teal / indigo / brown / gray / white / black, or the matching
//     macOS-API form ("systemRed" / "systemBlue" / ... — accepted
//     case-insensitively so docs and habit agree with the parser).
//     "accent" / "system" → the user's system accent colour.
//   - Hex: "#rgb" / "#rrggbb" / "#rrggbbaa".
// Unknown strings return nil so callers can apply their own
// fallback (`nsColor(...) ?? .systemBlue` etc).

import AppKit

public enum NSColorParse {

    public static func nsColor(_ s: String) -> NSColor? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        // Short and `systemX` aliases both map to the same NSColor.
        switch t {
        case "blue",   "systemblue":     return .systemBlue
        case "red",    "systemred":      return .systemRed
        case "green",  "systemgreen":    return .systemGreen
        case "orange", "systemorange":   return .systemOrange
        case "purple", "systempurple":   return .systemPurple
        case "pink",   "systempink":     return .systemPink
        case "yellow", "systemyellow":   return .systemYellow
        case "teal",   "systemteal":     return .systemTeal
        case "indigo", "systemindigo":   return .systemIndigo
        case "brown",  "systembrown":    return .systemBrown
        case "gray",   "grey",
             "systemgray", "systemgrey": return .systemGray
        case "white":                    return .white
        case "black":                    return .black
        case "accent", "system":         return .controlAccentColor
        default: break
        }
        // Hex: #RGB / #RRGGBB / #RRGGBBAA
        guard t.hasPrefix("#") else { return nil }
        let hex = String(t.dropFirst())
        let chars = Array(hex)
        func expand(_ c: Character) -> String { "\(c)\(c)" }
        let rgba: String
        switch chars.count {
        case 3: rgba = expand(chars[0]) + expand(chars[1]) + expand(chars[2]) + "ff"
        case 6: rgba = hex + "ff"
        case 8: rgba = hex
        default: return nil
        }
        let b = Array(rgba)
        func pair(_ i: Int) -> CGFloat {
            CGFloat(Int(String([b[i], b[i + 1]]), radix: 16) ?? 0) / 255.0
        }
        return NSColor(srgbRed: pair(0), green: pair(2),
                       blue: pair(4), alpha: pair(6))
    }

    /// Splatoon-style ink palette — 10 saturated, vivid hues mirroring
    /// the Turf War colour pairings (sapphire vs orange, pink vs
    /// green, purple vs orange, pansy vs mustard, orange vs peppermint
    /// — Splatoon 3 set). All at saturation ≈ 100% so each reads as a
    /// distinct team colour against the cursor-anchored fire point's
    /// surroundings. Sourced from observation of in-game splats — exact
    /// hex codes aren't published, so these are visual approximations
    /// that lean on hue diversity rather than pixel-perfect matches.
    public static let splatoonInks: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.18, blue: 0.50, alpha: 1),   // pink
        NSColor(srgbRed: 0.40, green: 0.86, blue: 0.30, alpha: 1),   // green
        NSColor(srgbRed: 0.22, green: 0.38, blue: 1.00, alpha: 1),   // sapphire blue
        NSColor(srgbRed: 1.00, green: 0.42, blue: 0.10, alpha: 1),   // orange
        NSColor(srgbRed: 0.65, green: 0.27, blue: 1.00, alpha: 1),   // purple
        NSColor(srgbRed: 0.50, green: 0.27, blue: 0.80, alpha: 1),   // pansy
        NSColor(srgbRed: 0.96, green: 0.78, blue: 0.10, alpha: 1),   // mustard
        NSColor(srgbRed: 0.20, green: 0.92, blue: 0.78, alpha: 1),   // peppermint
        NSColor(srgbRed: 1.00, green: 0.85, blue: 0.00, alpha: 1),   // yellow
        NSColor(srgbRed: 0.95, green: 0.18, blue: 0.85, alpha: 1),   // magenta
    ]

    /// Pick a random ink colour from `splatoonInks`. Re-rolls on each
    /// call so two fires in a row land different hues (the deliberate
    /// "Turf War" feel). Uses `SystemRandomNumberGenerator` for the
    /// pick — the decal's per-fire seed governs the shape, not the
    /// colour.
    public static func randomSplatoonInk() -> NSColor {
        splatoonInks.randomElement() ?? .systemBlue
    }
}
