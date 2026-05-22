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

/// What the overlay shows next to the cursor: the shape drawn so far
/// (as arrows) plus the rules still reachable from it. Each row's
/// `suffix` is only the *remaining* arrows (the drawn prefix is
/// stripped — you already see it), and `fires` marks the rule the
/// current shape triggers right now (its suffix is empty).
public struct GestureHint: Sendable {
    public struct Row: Sendable {
        public let suffix: String
        public let name: String
        public let fires: Bool
        public init(suffix: String, name: String, fires: Bool) {
            self.suffix = suffix; self.name = name; self.fires = fires
        }
    }
    public let shape: String
    public let rows: [Row]
    public init(shape: String, rows: [Row]) {
        self.shape = shape; self.rows = rows
    }
}

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
        v.strokeWidth = CGFloat(width)   // already clamped by StrokeConfig
        v.originOffset = frame.origin    // global Cocoa origin of the union
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
    /// recolors the whole trail: the match color when the current
    /// shape fires a rule, the no-match color otherwise. `hint` (the
    /// shape-so-far + reachable rules) is drawn near the cursor.
    /// Coalesced redraws keep this cheap at the per-mouse-move rate.
    public func addPoint(_ cg: CGPoint, valid: Bool, hint: GestureHint?) {
        view.append(cg, valid: valid, hint: hint)
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
    private var hint: GestureHint?       // shape + reachable rules

    override var isFlipped: Bool { false }   // Cocoa default (Y-up)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // click-through

    /// Convert a CG global point (Y-down) to view-local (Y-up) coords.
    func append(_ cg: CGPoint, valid: Bool, hint: GestureHint?) {
        self.valid = valid
        self.hint = hint
        // CG global (origin top-left, Y-down) → Cocoa global (origin
        // bottom-left of the primary display, Y-up). Flipping about the
        // primary screen's height is correct for ALL displays, not
        // just the primary: both coordinate systems are anchored to
        // the primary, so a point above it (CG y < 0) maps to Cocoa
        // y > primaryH and a point below to y < 0, exactly as a
        // secondary display sits. The primary is the screen whose
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
        guard !points.isEmpty || hint != nil else { return }
        points.removeAll(keepingCapacity: true)
        hint = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard points.count >= 2 else { return }
        let color = valid ? matchColor : noMatchColor

        // Trail with a soft same-color glow for a bit of depth.
        let path = NSBezierPath()
        path.lineWidth = strokeWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: points[0])
        for p in points.dropFirst() { path.line(to: p) }
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = color.withAlphaComponent(0.5)
        glow.shadowBlurRadius = 7
        glow.set()
        color.withAlphaComponent(0.9).setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()

        if let hint, let cursor = points.last {
            drawHint(hint, near: cursor, accent: color)
        }
    }

    private static func mono(_ sz: CGFloat, _ w: NSFont.Weight) -> NSFont {
        .monospacedSystemFont(ofSize: sz, weight: w)
    }
    private static let textOpts: NSString.DrawingOptions = [.usesLineFragmentOrigin]

    /// Spatial tooltips: each reachable rule is shown in the direction
    /// of its next arrow — left for `←…`, right for `→…`, up for `↑…`,
    /// down for `↓…` — so the layout itself points the way. Rules that
    /// share a next direction stack into one card; the rule the current
    /// shape fires now (empty remainder) sits at the cursor.
    private func drawHint(_ hint: GestureHint, near cursor: CGPoint,
                          accent: NSColor) {
        var byDir: [Character: [GestureHint.Row]] = [:]
        var fires: [GestureHint.Row] = []
        for row in hint.rows {
            if let first = row.suffix.first { byDir[first, default: []].append(row) }
            else { fires.append(row) }
        }
        let gap: CGFloat = 24
        for (arrow, rows) in byDir {
            let s = cardText(rows, accent: accent)
            let size = cardSize(s)
            var o: CGPoint
            switch arrow {
            case "←": o = CGPoint(x: cursor.x - gap - size.width, y: cursor.y - size.height / 2)
            case "→": o = CGPoint(x: cursor.x + gap,               y: cursor.y - size.height / 2)
            case "↑": o = CGPoint(x: cursor.x - size.width / 2,     y: cursor.y + gap)
            case "↓": o = CGPoint(x: cursor.x - size.width / 2,     y: cursor.y - gap - size.height)
            default:  o = CGPoint(x: cursor.x + gap, y: cursor.y + gap)
            }
            drawCard(s, at: o, size: size)
        }
        if !fires.isEmpty {
            let s = cardText(fires, accent: accent)
            let size = cardSize(s)
            drawCard(s, at: CGPoint(x: cursor.x + gap, y: cursor.y + gap), size: size)
        }
    }

    /// One card's text: each row is `<remaining arrows>\t<name>`, names
    /// tab-aligned past the widest arrows. The firing rows have no
    /// arrows left, so their card drops the tab and tints the name with
    /// the accent color instead.
    private func cardText(_ rows: [GestureHint.Row], accent: NSColor) -> NSAttributedString {
        let arrowFont = Self.mono(14, .semibold)
        var arrowMax: CGFloat = 0
        for r in rows {
            let w = (r.suffix as NSString).size(withAttributes: [.font: arrowFont]).width
            arrowMax = max(arrowMax, w)
        }
        let useTab = arrowMax > 0
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 4
        if useTab {
            para.tabStops = [NSTextTab(textAlignment: .left, location: arrowMax + 12)]
        }

        let s = NSMutableAttributedString()
        for (i, r) in rows.enumerated() {
            if i > 0 { s.append(NSAttributedString(string: "\n")) }
            if !r.suffix.isEmpty {
                s.append(NSAttributedString(string: r.suffix, attributes: [
                    .font: arrowFont, .foregroundColor: NSColor.white]))
            }
            s.append(NSAttributedString(string: (useTab ? "\t" : "") + r.name, attributes: [
                .font: Self.mono(13, .regular),
                .foregroundColor: r.fires ? accent : NSColor.white.withAlphaComponent(0.85)]))
        }
        s.addAttribute(.paragraphStyle, value: para,
                       range: NSRange(location: 0, length: s.length))
        return s
    }

    private let cardPadX: CGFloat = 12, cardPadY: CGFloat = 9

    private func cardSize(_ s: NSAttributedString) -> CGSize {
        let t = s.boundingRect(with: CGSize(width: 600, height: 800),
                               options: Self.textOpts).size
        return CGSize(width: ceil(t.width) + cardPadX * 2,
                      height: ceil(t.height) + cardPadY * 2)
    }

    /// Draw a rounded card (shadow + hair border) at `origin`, clamped
    /// to stay on-screen, then its text.
    private func drawCard(_ s: NSAttributedString, at origin: CGPoint, size: CGSize) {
        var rect = CGRect(origin: origin, size: size)
        rect.origin.x = min(max(rect.origin.x, 6), bounds.maxX - size.width - 6)
        rect.origin.y = min(max(rect.origin.y, 6), bounds.maxY - size.height - 6)
        let bg = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 13
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        NSColor.black.withAlphaComponent(0.8).setFill()
        bg.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        bg.lineWidth = 1
        bg.stroke()
        s.draw(with: rect.insetBy(dx: cardPadX, dy: cardPadY), options: Self.textOpts)
    }
}
