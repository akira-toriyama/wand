// Translucent gesture-trail HUD — the project's only on-screen UI
// (stroke is otherwise headless / LSUIElement). Lives in the adapter
// layer next to EventTap because it's pure AppKit/CG rendering fed by
// the sample stream; Core stays UI-free (points cross the seam as
// plain `CGPoint`). Threading: `addPoint` / `clear` fire on the
// event-tap main-thread callback, which is where AppKit wants them.

import AppKit
import CoreGraphics
import StrokeCore

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
    /// matches nothing. The boolean toggles + `badgeSize` come from
    /// `[overlay]` — each independently lets the user dial back a
    /// piece of the HUD without disabling the whole overlay.
    public init(match: String, noMatch: String, width: Int,
                badgeEnabled: Bool = true,
                blurEnabled: Bool = true,
                badgeSize: Int = 56,
                animEnabled: Bool = true) {
        let frame = Self.unionFrame()
        let v = TrailView(frame: CGRect(origin: .zero, size: frame.size),
                          blurEnabled: blurEnabled)
        v.matchColor = Self.nsColor(match) ?? .systemBlue
        v.noMatchColor = Self.nsColor(noMatch) ?? .systemRed
        v.strokeWidth = CGFloat(width)   // already clamped by StrokeConfig
        v.originOffset = frame.origin    // global Cocoa origin of the union
        v.badgeEnabled = badgeEnabled
        v.badgeSize = CGFloat(badgeSize)
        v.animEnabled = animEnabled
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

    /// Set the target-app icon shown at the gesture's start point.
    /// Drawn only once a direction has emerged (so a plain click never
    /// flashes a badge). Caller resolves the icon (it's an AppKit type
    /// — Core can't see it), passing it in once per stroke.
    public func setOriginIcon(_ icon: NSImage?) {
        view.originIcon = icon
    }

    /// Apply a config change live — drives `[overlay]` hot-reload from
    /// `ConfigWatcher`. Every overlay field is reflected without a
    /// daemon restart, including `blur-enabled` (the blur subview is
    /// added or removed in place via `TrailView.setBlurEnabled`). The
    /// only restart-required overlay field is `enabled = true → false`
    /// when the daemon was started with `enabled = false` (the window
    /// was never created); the converse (visible → hidden) is handled
    /// here by ordering the window out.
    public func applyConfig(_ cfg: StrokeConfig) {
        view.matchColor = Self.nsColor(cfg.overlayColor) ?? .systemBlue
        view.noMatchColor = Self.nsColor(cfg.overlayColorNoMatch) ?? .systemRed
        view.strokeWidth = CGFloat(cfg.overlayWidth)
        view.badgeEnabled = cfg.overlayBadgeEnabled
        view.badgeSize = CGFloat(cfg.overlayBadgeSize)
        view.animEnabled = cfg.overlayAnimEnabled
        view.setBlurEnabled(cfg.overlayBlurEnabled)
        if cfg.overlayEnabled {
            if !window.isVisible { window.orderFrontRegardless() }
        } else if window.isVisible {
            window.orderOut(nil)
        }
    }

    /// Clear the trail (stroke ended).
    public func clear() {
        view.reset()
    }


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


private final class TrailView: NSView {
    var matchColor: NSColor = .systemBlue
    var noMatchColor: NSColor = .systemRed
    var strokeWidth: CGFloat = 3
    /// Cocoa-global origin of the window; subtracted to get view-local
    /// coords from a global point.
    var originOffset: CGPoint = .zero
    /// User-visible knobs from `[overlay]`. All hot-reloadable via
    /// `GestureOverlay.applyConfig(_:)` — colours and toggles update
    /// without restart; `setBlurEnabled` even adds/removes the
    /// `NSVisualEffectView` subview in place.
    fileprivate var blurEnabled: Bool
    var badgeEnabled: Bool = true
    var badgeSize: CGFloat = 56
    var animEnabled: Bool = true

    fileprivate var points: [CGPoint] = []  // already in view-local coords
    fileprivate var valid = true            // current match state of the trail
    fileprivate var hint: GestureHint?      // shape + reachable rules
    /// Icon of the target app the gesture is acting on, drawn as a
    /// small badge at `points.first`. Tells the user "you're operating
    /// on Chrome (the cursor-anchored window), even though VSCode has
    /// keyboard focus" — the whole reason cursor-anchored exists.
    var originIcon: NSImage?
    /// Time the badge first appeared (the first sample with hint set).
    /// Drives the scale-in animation. Reset to nil on stroke end.
    private var badgeAppearedAt: TimeInterval?

    /// Pre-computed positions of the currently-visible HUD elements.
    /// Single source of truth shared by the blur-mask updater (only
    /// these regions get vibrant blur) and `HUDContentView` (which
    /// draws the tint / border / text / icon on top of the blur).
    /// Rebuilt every `append` / `reset`.
    fileprivate struct CardLayout {
        let rect: CGRect
        let text: NSAttributedString
        let fill: NSColor?   // nil → frosted only; set → tint over frost
    }
    fileprivate struct BadgeLayout {
        let rect: CGRect
        let icon: NSImage
        let border: NSColor
        let scale: CGFloat
    }
    fileprivate var cardLayouts: [CardLayout] = []
    fileprivate var badgeLayout: BadgeLayout?

    /// Behind-window vibrant blur, masked to the union of all current
    /// card + badge rounded rects so blur only appears where the HUD
    /// actually is — the rest of the overlay window stays fully
    /// transparent.
    private let blurView: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.autoresizingMask = [.width, .height]
        return v
    }()

    /// HUD overlay drawn ON TOP of `blurView`: optional tint, hair
    /// border, text, icon. Subview ordering (blurView at index 0,
    /// hudContent at index 1) gives us the right z-stack without
    /// fighting AppKit's "subviews always above parent's draw" rule.
    fileprivate let hudContent: HUDContentView = {
        let v = HUDContentView()
        v.autoresizingMask = [.width, .height]
        return v
    }()

    init(frame frameRect: NSRect, blurEnabled: Bool = true) {
        self.blurEnabled = blurEnabled
        super.init(frame: frameRect)
        wantsLayer = true
        hudContent.frame = bounds
        if blurEnabled {
            blurView.frame = bounds
            // Empty mask initially — no HUD until a sample arrives.
            let mask = CAShapeLayer()
            mask.fillColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
            blurView.layer?.mask = mask
            addSubview(blurView)
        }
        addSubview(hudContent)
        hudContent.owner = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }   // Cocoa default (Y-up)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // click-through

    /// Convert a CG global point (Y-down) to view-local (Y-up) coords.
    func append(_ cg: CGPoint, valid: Bool, hint: GestureHint?) {
        if self.hint == nil && hint != nil {
            badgeAppearedAt = CACurrentMediaTime()
        }
        self.valid = valid
        self.hint = hint
        // CG global (origin top-left, Y-down) → Cocoa global (origin
        // bottom-left of the primary display, Y-up). Flipping about the
        // primary screen's height is correct for ALL displays: both
        // coord systems are anchored to the primary, so a point above
        // it (CG y < 0) maps to Cocoa y > primaryH and a point below
        // maps to y < 0 — exactly where a secondary display sits.
        let primaryH = NSScreen.screens
            .first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? cg.y
        let cocoa = CGPoint(x: cg.x, y: primaryH - cg.y)
        points.append(CGPoint(x: cocoa.x - originOffset.x,
                              y: cocoa.y - originOffset.y))
        layoutHUD()
        needsDisplay = true
        hudContent.needsDisplay = true
    }

    func reset() {
        guard !points.isEmpty || hint != nil || originIcon != nil
        else { return }
        points.removeAll(keepingCapacity: true)
        hint = nil
        originIcon = nil
        badgeAppearedAt = nil
        cardLayouts.removeAll()
        badgeLayout = nil
        layoutHUD()
        needsDisplay = true
        hudContent.needsDisplay = true
    }

    /// Add or remove the blur subview in place when `[overlay]
    /// blur-enabled` flips during a hot-reload. No-op if already at
    /// the requested state.
    func setBlurEnabled(_ enabled: Bool) {
        guard enabled != blurEnabled else { return }
        blurEnabled = enabled
        if enabled {
            if blurView.superview == nil {
                blurView.frame = bounds
                if blurView.layer?.mask == nil {
                    let mask = CAShapeLayer()
                    mask.fillColor = CGColor(srgbRed: 0, green: 0,
                                              blue: 0, alpha: 1)
                    blurView.layer?.mask = mask
                }
                // Keep hudContent on top of the blur, where it was at
                // first-launch wiring.
                addSubview(blurView,
                           positioned: .below, relativeTo: hudContent)
            }
        } else {
            blurView.removeFromSuperview()
        }
        layoutHUD()
        needsDisplay = true
        hudContent.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard points.count >= 2 else { return }
        let color = valid ? matchColor : noMatchColor
        // Trail with a soft same-color glow — drawn here (parent view)
        // so it sits beneath the blurView + HUD overlay subviews. A
        // small portion overlapping HUD regions is hidden by blur,
        // which is fine: the visual focus is the badge → cards arc.
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
    }

    // MARK: - HUD layout

    private let badgeAnimDuration: TimeInterval = 0.15

    /// Compute every HUD region's rect (cards + optional badge),
    /// update the blur mask path to match, and store the layouts so
    /// `HUDContentView` can draw text / borders / icon on top. Called
    /// from `append` (state change) and during the badge scale-in.
    private func layoutHUD() {
        cardLayouts.removeAll()
        badgeLayout = nil

        let accent = valid ? matchColor : noMatchColor

        if let hint, let cursor = points.last {
            var byDir: [Character: [GestureHint.Row]] = [:]
            var fires: [GestureHint.Row] = []
            for row in hint.rows {
                if let first = row.suffix.first {
                    byDir[first, default: []].append(row)
                } else {
                    fires.append(row)
                }
            }
            let gap: CGFloat = 24
            for (arrow, rows) in byDir {
                let s = cardText(rows)
                let size = cardSize(s)
                let o: CGPoint
                switch arrow {
                case "←": o = CGPoint(x: cursor.x - gap - size.width, y: cursor.y - size.height / 2)
                case "→": o = CGPoint(x: cursor.x + gap,               y: cursor.y - size.height / 2)
                case "↑": o = CGPoint(x: cursor.x - size.width / 2,    y: cursor.y + gap)
                case "↓": o = CGPoint(x: cursor.x - size.width / 2,    y: cursor.y - gap - size.height)
                default:  o = CGPoint(x: cursor.x + gap, y: cursor.y + gap)
                }
                cardLayouts.append(CardLayout(
                    rect: clampedCardRect(at: o, size: size),
                    text: s, fill: nil))
            }
            if !fires.isEmpty {
                let s = cardText(fires)
                let size = cardSize(s)
                // Fires card fill: accent on its own over blur (alpha
                // 0.5 lets the frost show through). Without blur the
                // dark backdrop is missing too, so the tint goes more
                // opaque to keep the card a distinct surface.
                let firesAlpha: CGFloat = blurEnabled ? 0.5 : 0.78
                // Collision avoidance: when the user has rules that
                // share a prefix (e.g. `DL` + `DLU` + `DLU`), the
                // fires card's natural upper-right anchor overlaps
                // the ↑ directional card's rectangle. Try each
                // diagonal anchor in turn and pick the first one
                // that doesn't intersect any directional card. Order
                // — ↗ ↘ ↙ ↖ — keeps the natural diagonal first so
                // the simple case (no collision) is unchanged.
                let anchors: [CGPoint] = [
                    CGPoint(x: cursor.x + gap,
                            y: cursor.y + gap),
                    CGPoint(x: cursor.x + gap,
                            y: cursor.y - gap - size.height),
                    CGPoint(x: cursor.x - gap - size.width,
                            y: cursor.y - gap - size.height),
                    CGPoint(x: cursor.x - gap - size.width,
                            y: cursor.y + gap),
                ]
                var firesRect = clampedCardRect(at: anchors[0], size: size)
                for a in anchors {
                    let r = clampedCardRect(at: a, size: size)
                    if !cardLayouts.contains(where: { $0.rect.intersects(r) }) {
                        firesRect = r
                        break
                    }
                }
                cardLayouts.append(CardLayout(
                    rect: firesRect, text: s,
                    fill: accent.withAlphaComponent(firesAlpha)))
            }
            // With blur disabled, regular cards still need a fill —
            // the frost would have been their backdrop. Re-run and
            // tag each non-fires layout with the solid dark fill.
            if !blurEnabled {
                for i in cardLayouts.indices where cardLayouts[i].fill == nil {
                    cardLayouts[i] = CardLayout(
                        rect: cardLayouts[i].rect,
                        text: cardLayouts[i].text,
                        fill: NSColor.black.withAlphaComponent(0.8))
                }
            }
        }

        if badgeEnabled,
           hint != nil, let icon = originIcon, let origin = points.first {
            let s = badgeSize
            var rect = CGRect(x: origin.x - s / 2, y: origin.y - s / 2,
                              width: s, height: s)
            rect.origin.x = min(max(rect.origin.x, 8), bounds.maxX - s - 8)
            rect.origin.y = min(max(rect.origin.y, 8), bounds.maxY - s - 8)

            // 0.85 → 1.0 ease-out cubic over 150 ms. Re-layout each
            // frame until done so the mask scales with the visible
            // badge — otherwise blur briefly extends past the border.
            var scale: CGFloat = 1.0
            if animEnabled, let t0 = badgeAppearedAt {
                let elapsed = CACurrentMediaTime() - t0
                if elapsed < badgeAnimDuration {
                    let p = elapsed / badgeAnimDuration
                    let eased = 1 - pow(1 - p, 3)
                    scale = 0.85 + 0.15 * CGFloat(eased)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) {
                        [weak self] in
                        self?.layoutHUD()
                        self?.hudContent.needsDisplay = true
                    }
                }
            }
            badgeLayout = BadgeLayout(rect: rect, icon: icon,
                                      border: accent, scale: scale)
        }

        let maskPath = CGMutablePath()
        for c in cardLayouts {
            maskPath.addRoundedRect(in: c.rect,
                                    cornerWidth: 10, cornerHeight: 10)
        }
        if let b = badgeLayout {
            // Scale the badge cutout from its centre so the blur
            // region pulses with the visible badge.
            let cx = b.rect.midX, cy = b.rect.midY
            let t = CGAffineTransform(translationX: cx, y: cy)
                .scaledBy(x: b.scale, y: b.scale)
                .translatedBy(x: -cx, y: -cy)
            maskPath.addRoundedRect(in: b.rect,
                                    cornerWidth: 10, cornerHeight: 10,
                                    transform: t)
        }
        // Skip mask update when blur is disabled — blurView isn't
        // even in the hierarchy then; the mask layer is moot.
        if blurEnabled, let mask = blurView.layer?.mask as? CAShapeLayer {
            mask.path = maskPath
        }
    }

    private func clampedCardRect(at origin: CGPoint, size: CGSize) -> CGRect {
        var rect = CGRect(origin: origin, size: size)
        rect.origin.x = min(max(rect.origin.x, 6), bounds.maxX - size.width - 6)
        rect.origin.y = min(max(rect.origin.y, 6), bounds.maxY - size.height - 6)
        return rect
    }

    fileprivate static func mono(_ sz: CGFloat, _ w: NSFont.Weight) -> NSFont {
        .monospacedSystemFont(ofSize: sz, weight: w)
    }
    fileprivate static let textOpts: NSString.DrawingOptions = [.usesLineFragmentOrigin]
    fileprivate let cardPadX: CGFloat = 12, cardPadY: CGFloat = 9

    /// One card's text. Directional cards (`fires == false` rows)
    /// stay tab-aligned past the widest arrows. The firing card has
    /// no arrows left, so it drops the tab — its accent-tinted fill
    /// (set in `layoutHUD`) does the "firing" signal; text stays white.
    fileprivate func cardText(_ rows: [GestureHint.Row]) -> NSAttributedString {
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
                .foregroundColor: NSColor.white]))
        }
        s.addAttribute(.paragraphStyle, value: para,
                       range: NSRange(location: 0, length: s.length))
        return s
    }

    fileprivate func cardSize(_ s: NSAttributedString) -> CGSize {
        let t = s.boundingRect(with: CGSize(width: 600, height: 800),
                               options: Self.textOpts).size
        return CGSize(width: ceil(t.width) + cardPadX * 2,
                      height: ceil(t.height) + cardPadY * 2)
    }
}

/// HUD overlay drawn on top of `TrailView.blurView`: optional tint
/// fill (for the firing card), the hair border, the text — and for
/// the badge, the scale-in transform, the 2pt accent border, and the
/// icon. Reads state from its `owner` (TrailView) instead of holding
/// its own copy; layout was already computed there in `layoutHUD`.
private final class HUDContentView: NSView {
    weak var owner: TrailView?
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let o = owner else { return }

        for c in o.cardLayouts {
            let bg = NSBezierPath(roundedRect: c.rect,
                                  xRadius: 10, yRadius: 10)
            if let fill = c.fill {
                fill.setFill()
                bg.fill()
            }
            NSColor.white.withAlphaComponent(0.18).setStroke()
            bg.lineWidth = 1
            bg.stroke()
            c.text.draw(with: c.rect.insetBy(dx: o.cardPadX, dy: o.cardPadY),
                        options: TrailView.textOpts)
        }

        if let b = o.badgeLayout {
            let cx = b.rect.midX, cy = b.rect.midY
            NSGraphicsContext.saveGraphicsState()
            let tx = NSAffineTransform()
            tx.translateX(by: cx, yBy: cy)
            tx.scaleX(by: b.scale, yBy: b.scale)
            tx.translateX(by: -cx, yBy: -cy)
            tx.concat()
            let bgPath = NSBezierPath(roundedRect: b.rect,
                                      xRadius: 10, yRadius: 10)
            // Without blur the badge needs its own dark backdrop
            // for icon contrast (otherwise the icon sits on whatever
            // page content is behind the transparent overlay).
            if !o.blurEnabled {
                NSColor.black.withAlphaComponent(0.8).setFill()
                bgPath.fill()
            }
            b.border.withAlphaComponent(0.95).setStroke()
            bgPath.lineWidth = 2
            bgPath.stroke()
            // Padding so the app's own squircle isn't flush with the
            // badge's rounded edge.
            let pad: CGFloat = 6
            b.icon.draw(in: b.rect.insetBy(dx: pad, dy: pad),
                        from: .zero, operation: .sourceOver,
                        fraction: 1.0,
                        respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
