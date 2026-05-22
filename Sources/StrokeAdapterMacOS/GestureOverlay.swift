// Translucent gesture-trail HUD. While the user draws, the path is
// stroked on a transparent, click-through window that floats above
// every app; on button-up the trail clears.
//
// Layer note: this is the project's one piece of on-screen UI. stroke
// is otherwise headless (LSUIElement). It lives in StrokeAdapterMacOS
// — same layer as EventTap — because it's pure AppKit/CG rendering
// fed by the event-tap sample stream; spinning up a separate View
// module (facet-style) isn't worth it for a single overlay. Core
// stays UI-free: the trail points arrive as plain `CGPoint`s.
//
// Threading: `addPoint` / `clear` are called from the event-tap
// callback (main thread). AppKit windows/views must be touched on
// main, so this is correct by construction — no dispatching needed.

import AppKit
import CoreGraphics

@MainActor
public final class GestureOverlay {

    private let window: NSWindow
    private let view: TrailView

    /// Colors are config strings: `#RGB` / `#RRGGBB` / `#RRGGBBAA`
    /// or a small set of names (see `nsColor`). `match` is used while
    /// the in-progress stroke matches a rule (and before it's moved
    /// enough to recognise anything); `noMatch` while the shape so far
    /// matches nothing. `width` is the stroke width in points.
    public init(match: String, noMatch: String, width: Int) {
        let frame = Self.unionFrame()
        let v = TrailView(frame: CGRect(origin: .zero, size: frame.size))
        v.matchColor = Self.nsColor(match) ?? .systemBlue
        v.noMatchColor = Self.nsColor(noMatch) ?? .systemRed
        v.strokeWidth = CGFloat(max(1, min(40, width)))
        v.originOffset = frame.origin   // global Cocoa origin of the union
        self.view = v

        let w = NSWindow(contentRect: frame, styleMask: .borderless,
                         backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true                 // click-through
        w.level = .screenSaver                       // above normal windows
        w.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                .fullScreenAuxiliary, .ignoresCycle]
        w.contentView = v
        self.window = w
    }

    /// Order the (empty, transparent) window on screen. Safe to call
    /// once at startup; it stays up for the daemon's lifetime and is
    /// invisible until points arrive.
    public func show() {
        window.orderFrontRegardless()
    }

    /// Append one trail point (CG global coords, Y-down). `valid`
    /// recolors the whole trail: the match color when the stroke so
    /// far matches a rule, the no-match color otherwise. `label` (the
    /// matched rule's name, or nil) is drawn near the cursor so the
    /// user sees what the gesture will do. Coalesced redraws keep this
    /// cheap even at the per-mouse-move rate.
    public func addPoint(_ cg: CGPoint, valid: Bool, label: String?) {
        view.append(cg, valid: valid, label: label)
    }

    /// Clear the trail (stroke ended).
    public func clear() {
        view.reset()
    }

    // MARK: - Geometry

    /// Cocoa-coordinate union of every screen — the window covers the
    /// whole virtual desktop so a gesture on any display is drawn.
    private static func unionFrame() -> CGRect {
        let screens = NSScreen.screens
        guard var u = screens.first?.frame else {
            return NSScreen.main?.frame ?? .zero
        }
        for s in screens.dropFirst() { u = u.union(s.frame) }
        return u
    }

    // MARK: - Color parsing

    private static func nsColor(_ s: String) -> NSColor? {
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
        func byte(_ r: Range<String.Index>) -> CGFloat {
            CGFloat(Int(hex[r], radix: 16) ?? 0) / 255.0
        }
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

// MARK: - Trail view

private final class TrailView: NSView {
    var matchColor: NSColor = .systemBlue
    var noMatchColor: NSColor = .systemRed
    var strokeWidth: CGFloat = 3
    /// Cocoa-global origin of the window; subtracted to get view-local
    /// coords from a global point.
    var originOffset: CGPoint = .zero

    private var points: [CGPoint] = []   // already in view-local coords
    private var valid = true             // current match state of the trail
    private var label: String?           // matched rule's label, if any

    override var isFlipped: Bool { false }   // Cocoa default (Y-up)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // click-through

    /// Convert a CG global point (Y-down) to view-local (Y-up) coords.
    func append(_ cg: CGPoint, valid: Bool, label: String?) {
        self.valid = valid
        self.label = label
        // CG global (origin top-left, Y-down) → Cocoa global (origin
        // bottom-left of the primary display, Y-up). Flip about the
        // primary screen's height; the primary is the screen whose
        // Cocoa origin is (0,0).
        let primaryH = NSScreen.screens
            .first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? cg.y
        let cocoa = CGPoint(x: cg.x, y: primaryH - cg.y)
        points.append(CGPoint(x: cocoa.x - originOffset.x,
                              y: cocoa.y - originOffset.y))
        needsDisplay = true
    }

    func reset() {
        guard !points.isEmpty || label != nil else { return }
        points.removeAll(keepingCapacity: true)
        label = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard points.count >= 2 else { return }
        let path = NSBezierPath()
        path.lineWidth = strokeWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: points[0])
        for p in points.dropFirst() { path.line(to: p) }
        (valid ? matchColor : noMatchColor).withAlphaComponent(0.85).setStroke()
        path.stroke()

        if let label, !label.isEmpty, let cursor = points.last {
            drawLabel(label, near: cursor)
        }
    }

    /// Draw the matched rule's label as a rounded "pill" just above-
    /// right of the cursor: dark translucent background, light text.
    private func drawLabel(_ text: String, near cursor: CGPoint) {
        let font = NSFont.systemFont(ofSize: 14, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let textSize = str.size()
        let padX: CGFloat = 10, padY: CGFloat = 6, gap: CGFloat = 16
        var pill = CGRect(x: cursor.x + gap, y: cursor.y + gap,
                          width: textSize.width + padX * 2,
                          height: textSize.height + padY * 2)
        // Keep the pill inside the view so it isn't clipped at edges.
        pill.origin.x = min(pill.origin.x, bounds.maxX - pill.width - 4)
        pill.origin.x = max(pill.origin.x, 4)
        pill.origin.y = min(pill.origin.y, bounds.maxY - pill.height - 4)
        pill.origin.y = max(pill.origin.y, 4)

        let bg = NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.7).setFill()
        bg.fill()
        str.draw(at: CGPoint(x: pill.minX + padX, y: pill.minY + padY))
    }
}
