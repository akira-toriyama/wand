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

    /// Splatoon-style ink palette — 10 saturated, vivid hues sourced
    /// from a Turf War colour-pair compilation
    /// (https://uto-room.com/color/character/splatoon/). All at near-
    /// 100% saturation so each reads as a distinct team colour against
    /// whatever surface the cursor-anchored fire point lands on. The
    /// set was de-duped from 17 published pairs down to 10 maximally-
    /// distinct hues so consecutive `splatoon` rolls actually look
    /// different.
    public static let splatoonInks: [NSColor] = [
        NSColor(srgbRed: 0xFA/255.0, green: 0x5B/255.0, blue: 0x00/255.0, alpha: 1),   // orange       #FA5B00
        NSColor(srgbRed: 0xF6/255.0, green: 0xFC/255.0, blue: 0x0B/255.0, alpha: 1),   // yellow       #F6FC0B
        NSColor(srgbRed: 0xA9/255.0, green: 0xDE/255.0, blue: 0x00/255.0, alpha: 1),   // lime         #A9DE00
        NSColor(srgbRed: 0x40/255.0, green: 0xF7/255.0, blue: 0x3E/255.0, alpha: 1),   // neon green   #40F73E
        NSColor(srgbRed: 0x1A/255.0, green: 0xC8/255.0, blue: 0xB4/255.0, alpha: 1),   // peppermint   #1AC8B4
        NSColor(srgbRed: 0x00/255.0, green: 0x32/255.0, blue: 0xFE/255.0, alpha: 1),   // sapphire     #0032FE
        NSColor(srgbRed: 0x60/255.0, green: 0x3B/255.0, blue: 0xFD/255.0, alpha: 1),   // purple       #603BFD
        NSColor(srgbRed: 0xDA/255.0, green: 0x18/255.0, blue: 0xAD/255.0, alpha: 1),   // magenta      #DA18AD
        NSColor(srgbRed: 0xFD/255.0, green: 0x2A/255.0, blue: 0x96/255.0, alpha: 1),   // pink         #FD2A96
        NSColor(srgbRed: 0xE6/255.0, green: 0x40/255.0, blue: 0x72/255.0, alpha: 1),   // coral        #E64072
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
