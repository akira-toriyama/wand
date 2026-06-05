// "cmd+shift+t" → (CGEventFlags, CGKeyCode) parser. Keycodes are
// US-QWERTY because macOS has no global "logical-name → keycode"
// map — the rule writer is implicitly typing on that layout.

import CoreGraphics
import WandCore

enum KeyCombo {

    struct Parsed: Equatable {
        let flags: CGEventFlags
        let keyCode: CGKeyCode
    }

    static func parse(_ combo: String) -> Parsed? {
        let parts = combo
            .lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }

        var flags: CGEventFlags = []
        var keyName: String?
        for p in parts {
            switch p {
            case "cmd", "command":   flags.formUnion(.maskCommand)
            case "opt", "option", "alt": flags.formUnion(.maskAlternate)
            case "ctrl", "control":  flags.formUnion(.maskControl)
            case "shift":            flags.formUnion(.maskShift)
            case "fn":               flags.formUnion(.maskSecondaryFn)
            default:
                if keyName != nil { return nil }   // two non-mod tokens
                keyName = p
            }
        }
        guard let name = keyName, let code = keyCodes[name] else { return nil }
        return Parsed(flags: flags, keyCode: code)
    }

    /// US-QWERTY virtual key codes. Source: Apple's HIToolbox/Events.h
    /// (`kVK_ANSI_*` constants).
    private static let keyCodes: [String: CGKeyCode] = [
        // letters
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "o": 0x1F,
        "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28,
        "n": 0x2D, "m": 0x2E,

        // digits (note 5/6 and 8/9 are not strictly ascending)
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17, "6": 0x16,
        "7": 0x1A, "8": 0x1C, "9": 0x19, "0": 0x1D,

        // common symbols
        "-": 0x1B, "=": 0x18, "[": 0x21, "]": 0x1E, "\\": 0x2A,
        ";": 0x29, "'": 0x27, ",": 0x2B, ".": 0x2F, "/": 0x2C, "`": 0x32,

        // editing / navigation
        "return": 0x24, "enter": 0x4C,
        "tab": 0x30, "space": 0x31,
        "delete": 0x33, "backspace": 0x33, "forwarddelete": 0x75,
        "escape": 0x35, "esc": 0x35,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,

        // function keys
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76,
        "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
        "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
    ]

    /// Render a key-combo string into Apple's glyph display form so the
    /// launcher panel can show `"cmd+shift+t"` as `"⌘⇧T"` next to a
    /// row. Returns nil when the input has no recognisable key token
    /// (modifier-only / typo) — caller skips the badge in that case.
    /// Modifier order follows Apple HIG: ctrl → opt → shift → cmd; `fn`
    /// has no glyph and is rendered as the text `"fn"` ahead of the
    /// others. Parsing rules match `parse(_:)` so anything wand will
    /// actually dispatch is also displayable.
    static func format(_ combo: String) -> String? {
        let parts = combo
            .lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }

        var hasCmd = false, hasOpt = false, hasCtrl = false
        var hasShift = false, hasFn = false
        var keyName: String?
        for p in parts {
            switch p {
            case "cmd", "command":       hasCmd = true
            case "opt", "option", "alt": hasOpt = true
            case "ctrl", "control":      hasCtrl = true
            case "shift":                hasShift = true
            case "fn":                   hasFn = true
            default:
                if keyName != nil { return nil }   // two non-mod tokens
                keyName = p
            }
        }
        guard let name = keyName, let glyph = keyGlyph(for: name)
        else { return nil }

        var out = ""
        if hasFn   { out += "fn" }
        if hasCtrl { out += "⌃" }
        if hasOpt  { out += "⌥" }
        if hasShift { out += "⇧" }
        if hasCmd  { out += "⌘" }
        out += glyph
        return out
    }

    /// Glyph display string for one key token. Special keys map to the
    /// Apple HIG glyphs; F-keys keep their `F1`-style text; single
    /// characters render as their uppercase. Anything else returns nil.
    private static func keyGlyph(for name: String) -> String? {
        if let g = specialGlyphs[name] { return g }
        // F-keys: `f1`..`f12`
        if name.hasPrefix("f"), name.count >= 2, name.count <= 3,
           name.dropFirst().allSatisfy({ $0.isNumber }) {
            return name.uppercased()
        }
        if name.count == 1 { return name.uppercased() }
        return nil
    }

    private static let specialGlyphs: [String: String] = [
        "return": "↩", "enter": "⌅",
        "tab": "⇥", "space": "␣",
        "delete": "⌫", "backspace": "⌫", "forwarddelete": "⌦",
        "escape": "⎋", "esc": "⎋",
        "left": "←", "right": "→", "down": "↓", "up": "↑",
        "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟",
    ]
}
