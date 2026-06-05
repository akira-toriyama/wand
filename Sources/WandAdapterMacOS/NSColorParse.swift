// String → NSColor parser shared by every adapter surface that takes
// a colour from config. Originally lived as a `private static` on
// `GestureOverlay`; promoted out so the launcher panel (#59 tint)
// and the upcoming theme system (#62) can reuse the same name +
// hex grammar without copy-paste.
//
// Grammar:
//   - Named: blue / red / green / orange / purple / pink / yellow /
//     white / black / "accent" or "system" (system accent).
//   - Hex: "#rgb" / "#rrggbb" / "#rrggbbaa".
// Unknown strings return nil so callers can apply their own
// fallback (`nsColor(...) ?? .systemBlue` etc).

import AppKit

public enum NSColorParse {

    public static func nsColor(_ s: String) -> NSColor? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        switch t {
        case "blue":   return .systemBlue
        case "red":    return .systemRed
        case "green":  return .systemGreen
        case "orange": return .systemOrange
        case "purple": return .systemPurple
        case "pink":   return .systemPink
        case "yellow": return .systemYellow
        case "white":  return .white
        case "black":  return .black
        case "accent", "system": return .controlAccentColor
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
}
