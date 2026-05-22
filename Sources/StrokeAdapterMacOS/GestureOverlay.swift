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

    /// Draw the hint as a rounded card just above-right of the cursor:
    /// the shape on top (bold), then each reachable rule's remaining
    /// arrows + name. The firing row is tinted with the accent color.
    private func drawHint(_ hint: GestureHint, near cursor: CGPoint,
                          accent: NSColor) {
        func mono(_ sz: CGFloat, _ w: NSFont.Weight) -> NSFont {
            .monospacedSystemFont(ofSize: sz, weight: w)
        }
        let dim = NSColor.white.withAlphaComponent(0.55)
        let markerFont = mono(13, .bold), suffixFont = mono(13, .medium)

        // Names align in a column: a left tab stop just past the widest
        // "marker+suffix" prefix. Arrow glyphs aren't monospaced, so a
        // tab stop (not space padding) is what reliably lines them up.
        var prefixMax: CGFloat = 0
        for row in hint.rows {
            let marker = (row.fires ? "▸ " : "   ") as NSString
            let w = marker.size(withAttributes: [.font: markerFont]).width
                + (row.suffix as NSString).size(withAttributes: [.font: suffixFont]).width
            prefixMax = max(prefixMax, w)
        }
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 4
        para.tabStops = [NSTextTab(textAlignment: .left, location: prefixMax + 14)]

        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: hint.shape, attributes: [
            .font: mono(17, .semibold), .foregroundColor: NSColor.white]))
        for row in hint.rows {
            s.append(NSAttributedString(string: "\n", attributes: [.font: mono(13, .regular)]))
            s.append(NSAttributedString(string: row.fires ? "▸ " : "   ", attributes: [
                .font: markerFont,
                .foregroundColor: row.fires ? accent : dim]))
            if !row.suffix.isEmpty {
                s.append(NSAttributedString(string: row.suffix, attributes: [
                    .font: suffixFont,
                    .foregroundColor: NSColor.white.withAlphaComponent(0.9)]))
            }
            s.append(NSAttributedString(string: "\t" + row.name, attributes: [
                .font: mono(13, .regular),
                .foregroundColor: row.fires ? accent : NSColor.white.withAlphaComponent(0.8)]))
        }
        s.addAttribute(.paragraphStyle, value: para,
                       range: NSRange(location: 0, length: s.length))

        let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin]
        let textSize = s.boundingRect(
            with: CGSize(width: 600, height: 800), options: opts).size
        let padX: CGFloat = 13, padY: CGFloat = 10, gap: CGFloat = 18
        var card = CGRect(x: cursor.x + gap, y: cursor.y + gap,
                          width: ceil(textSize.width) + padX * 2,
                          height: ceil(textSize.height) + padY * 2)
        card.origin.x = min(max(card.origin.x, 6), bounds.maxX - card.width - 6)
        card.origin.y = min(max(card.origin.y, 6), bounds.maxY - card.height - 6)

        let bg = NSBezierPath(roundedRect: card, xRadius: 11, yRadius: 11)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        NSColor.black.withAlphaComponent(0.8).setFill()
        bg.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        bg.lineWidth = 1
        bg.stroke()

        s.draw(with: card.insetBy(dx: padX, dy: padY), options: opts)
    }
}
