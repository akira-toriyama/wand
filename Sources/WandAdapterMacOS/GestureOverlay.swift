// Translucent gesture-trail HUD — the project's only on-screen UI
// (stroke is otherwise headless / LSUIElement). Lives in the adapter
// layer next to EventTap because it's pure AppKit/CG rendering fed by
// the sample stream; Core stays UI-free (points cross the seam as
// plain `CGPoint`). Threading: `addPoint` / `clear` fire on the
// event-tap main-thread callback, which is where AppKit wants them.

import AppKit
import CoreGraphics
import WandCore

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

    /// Spin up the window + view, then funnel every `[overlay]` field
    /// through `applyConfig` so the init and hot-reload paths share
    /// one setter — no chance of a knob landing in only one of them.
    public init(_ cfg: WandConfig) {
        let frame = Self.unionFrame()
        let v = TrailView(frame: CGRect(origin: .zero, size: frame.size),
                          blurEnabled: cfg.overlayBlurEnabled)
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

        // Single source of truth: the same setter the hot-reload path
        // calls. Drops the four-fold knob threading the audit flagged.
        applyConfig(cfg)
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
    /// only restart-required overlay transition is `enabled = false → true`
    /// when the daemon was started with `enabled = false` (the window
    /// was never created, so there's nothing for `applyConfig` to
    /// attach to). The converse — visible at startup, hidden later —
    /// is handled here by ordering the window out, and re-shown on
    /// the next flip back.
    public func applyConfig(_ cfg: WandConfig) {
        view.matchColor = Self.nsColor(cfg.overlayColor) ?? .systemBlue
        view.noMatchColor = Self.nsColor(cfg.overlayColorNoMatch) ?? .systemRed
        view.strokeWidth = CGFloat(cfg.overlayWidth)
        view.badgeEnabled = cfg.overlayBadgeEnabled
        view.badgeSize = CGFloat(cfg.overlayBadgeSize)
        view.animEnabled = cfg.overlayAnimEnabled
        view.setBlurEnabled(cfg.overlayBlurEnabled)
        view.effectUnmatch = cfg.effectUnmatch
        view.effectMatch = cfg.effectMatch
        view.effectIntensity = cfg.effectIntensity.multiplier
        view.minStrokePx = CGFloat(cfg.minStrokePx)
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
    /// Exit-animation kinds from `[effect]`. Typed values come straight
    /// from `WandConfig` — `GestureOverlay.applyConfig` assigns them
    /// on init + hot-reload.
    var effectUnmatch: Effect = .none
    var effectMatch: Effect = .none
    /// Pre-resolved multiplier from `Intensity.multiplier` — scales
    /// translation distance, scale deltas, vibration amplitude, and
    /// particle birth-rate / velocity.
    var effectIntensity: CGFloat = 1.0
    /// Per-segment displacement threshold used to commit a direction
    /// — the same value `Recognition.recognize` uses, so the visual
    /// polyline elbows match where rules actually break a segment.
    var minStrokePx: CGFloat = 16

    /// Polyline state. `origin` = button-down point (badge anchor);
    /// `cursor` = latest sample (line head + HUD anchor); `corners` =
    /// every committed turn point in between. The trail draws as
    /// `origin → corners → cursor` — straight segments, Figma-style,
    /// rather than freehand through every sample.
    fileprivate var origin: CGPoint?
    fileprivate var cursor: CGPoint?
    fileprivate var corners: [CGPoint] = []
    /// Live recognition state — mirrors `Recognition.recognize`:
    /// `anchor` is the point from which the next segment is being
    /// measured; `lastDir` is the most recently committed direction.
    /// When the next sample exceeds `minStrokePx` from `anchor` AND
    /// the dominant axis differs from `lastDir`, the current `anchor`
    /// is promoted to a corner.
    private var anchor: CGPoint?
    private var lastDir: Direction?
    fileprivate var valid = true            // current match state of the trail
    fileprivate var hint: GestureHint?      // shape + reachable rules
    /// Icon of the target app the gesture is acting on, drawn as a
    /// small badge at `origin`. Tells the user "you're operating
    /// on Chrome (the cursor-anchored window), even though VSCode has
    /// keyboard focus" — the whole reason cursor-anchored exists.
    var originIcon: NSImage?
    /// Time the badge first appeared (the first sample with hint set).
    /// Drives the scale-in animation. Reset to nil on stroke end.
    private var badgeAppearedAt: TimeInterval?

    /// Card identity for diffing across layout passes. `direction(c)`
    /// keys directional cards by their first arrow; `fires` keys the
    /// firing card. When a kind present in the previous layout is
    /// absent from the new one, that card "became unmatched" mid-
    /// gesture and triggers `effectUnmatch`.
    fileprivate enum CardKind: Hashable {
        case direction(Character)
        case fires
    }

    /// Swap `.random` for a concrete pick at queue time — per-card,
    /// so successive unmatch cards in one stroke each get their own
    /// dice roll. Other kinds pass through unchanged.
    fileprivate func resolveRandom(_ effect: Effect) -> Effect {
        guard effect == .random else { return effect }
        return Effect.randomPool.randomElement() ?? .none
    }

    /// Pre-computed positions of the currently-visible HUD elements.
    /// Single source of truth shared by the blur-mask updater (only
    /// these regions get vibrant blur) and `HUDContentView` (which
    /// draws the tint / border / text / icon on top of the blur).
    /// Rebuilt every `append` / `reset`.
    fileprivate struct CardLayout {
        let kind: CardKind
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
    /// One card that's animating out — kept around past `layoutHUD`
    /// so its exit effect plays to completion regardless of subsequent
    /// state changes. Pruned by `tickExitAnimations` when the elapsed
    /// time exceeds the effect's duration.
    fileprivate struct ExitingCard {
        let layout: CardLayout
        let effect: Effect
        let startedAt: TimeInterval
    }
    fileprivate var cardLayouts: [CardLayout] = []
    fileprivate var badgeLayout: BadgeLayout?
    /// Last layoutHUD's cards, keyed by `CardKind`. Used to detect
    /// disappearing cards across passes and emit unmatch effects.
    private var prevCardsByKind: [CardKind: CardLayout] = [:]
    /// In-flight exit animations. Drained by `tickExitAnimations`.
    fileprivate var exitingCards: [ExitingCard] = []
    /// True while a `tickExitAnimations` is queued on the main loop —
    /// `kickExitAnimationTick` checks it before scheduling, so the
    /// concurrent `layoutHUD` + `reset` callers can't stack timers
    /// that then each reschedule themselves into an avalanche.
    private var tickScheduled = false

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
        let cocoa = ScreenCoords.cocoaPoint(fromCG: cg)
        let p = CGPoint(x: cocoa.x - originOffset.x,
                        y: cocoa.y - originOffset.y)
        if origin == nil { origin = p; anchor = p }
        cursor = p
        // Live direction tracking — same algorithm as
        // `Recognition.recognize` so the polyline elbows land
        // exactly where the recogniser would split a segment.
        if let a = anchor {
            let dx = p.x - a.x, dy = p.y - a.y
            let absX = abs(dx), absY = abs(dy)
            if max(absX, absY) >= minStrokePx {
                let dir: Direction =
                    absX >= absY ? (dx >= 0 ? .right : .left)
                                 : (dy >= 0 ? .up    : .down)
                if let last = lastDir, last != dir {
                    // Project the corner onto the previous segment's
                    // axis so the polyline is strictly orthogonal —
                    // raw `anchor` carries hand-jitter perpendicular
                    // to the intended direction.
                    let segStart = corners.last ?? origin ?? a
                    corners.append(Self.snap(a, to: last, from: segStart))
                }
                lastDir = dir
                anchor = p
            }
        }
        layoutHUD()
        needsDisplay = true
        hudContent.needsDisplay = true
    }

    func reset() {
        guard origin != nil || hint != nil || originIcon != nil
        else { return }
        // If a `fires` card was on-screen the moment the user released,
        // a rule actually triggered — animate that card out with the
        // match effect. Clearing `prevCardsByKind` first prevents the
        // layoutHUD diff below from double-queueing it (and from
        // queueing unmatch effects for the directional cards that are
        // simply going away with the rest of the HUD).
        if effectMatch != .none, let fires = prevCardsByKind[.fires] {
            let now = CACurrentMediaTime()
            let e = resolveRandom(effectMatch)
            exitingCards.append(ExitingCard(
                layout: fires, effect: e, startedAt: now))
            scheduleParticleEffect(fires, effect: e)
        }
        prevCardsByKind.removeAll()
        origin = nil
        cursor = nil
        corners.removeAll(keepingCapacity: true)
        anchor = nil
        lastDir = nil
        hint = nil
        originIcon = nil
        badgeAppearedAt = nil
        cardLayouts.removeAll()
        badgeLayout = nil
        layoutHUD()
        needsDisplay = true
        hudContent.needsDisplay = true
        kickExitAnimationTick()
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
        guard let origin, let cursor,
              origin != cursor || !corners.isEmpty
        else { return }
        let color = valid ? matchColor : noMatchColor

        // Live segment end: snap the raw cursor onto `lastDir`'s axis
        // relative to the previous corner (or origin). Keeps the
        // polyline orthogonal even while the user's hand drifts off
        // the cardinal axis mid-segment.
        let segStart = corners.last ?? origin
        let head: CGPoint
        if let dir = lastDir {
            head = Self.snap(cursor, to: dir, from: segStart)
        } else {
            head = cursor
        }

        // Polyline: origin → committed corners → live (snapped) head,
        // with each interior corner softened by a quadratic-style
        // bezier of radius `cornerRadius`. The radius is capped to
        // half of each adjacent segment so back-to-back tight corners
        // never overshoot. Sits beneath the blurView + HUD overlay.
        let path = NSBezierPath()
        path.lineWidth = strokeWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let polyline = [origin] + corners + [head]
        path.move(to: polyline[0])
        if polyline.count == 2 {
            path.line(to: polyline[1])
        } else {
            let desiredR = strokeWidth * 4
            for i in 1..<polyline.count - 1 {
                let A = polyline[i - 1]
                let B = polyline[i]
                let C = polyline[i + 1]
                let inLen = hypot(B.x - A.x, B.y - A.y)
                let outLen = hypot(C.x - B.x, C.y - B.y)
                let r = min(desiredR, inLen / 2, outLen / 2)
                let inU = CGPoint(x: (B.x - A.x) / max(inLen, 1),
                                  y: (B.y - A.y) / max(inLen, 1))
                let outU = CGPoint(x: (C.x - B.x) / max(outLen, 1),
                                   y: (C.y - B.y) / max(outLen, 1))
                let P = CGPoint(x: B.x - inU.x * r, y: B.y - inU.y * r)
                let Q = CGPoint(x: B.x + outU.x * r, y: B.y + outU.y * r)
                path.line(to: P)
                // Cubic with both control points at B = quadratic
                // approximation through the corner.
                path.curve(to: Q, controlPoint1: B, controlPoint2: B)
            }
            path.line(to: polyline.last!)
        }
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = color.withAlphaComponent(0.5)
        glow.shadowBlurRadius = 7
        glow.set()
        color.withAlphaComponent(0.9).setStroke()
        path.stroke()
        // Arrowhead at the live cursor end. Skipped until a direction
        // has been committed (no axis to point along yet).
        if let dir = lastDir {
            drawArrowhead(at: head, direction: dir, color: color)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Snap `p` onto the axis defined by `dir` and the point `from` —
    /// horizontal directions preserve `from.y`, vertical preserve
    /// `from.x`. Used in two places: committing a corner that sits on
    /// the previous segment's axis, and projecting the live cursor
    /// onto the current segment's axis.
    private static func snap(_ p: CGPoint, to dir: Direction,
                              from: CGPoint) -> CGPoint {
        switch dir {
        case .left, .right: return CGPoint(x: p.x, y: from.y)
        case .up, .down:    return CGPoint(x: from.x, y: p.y)
        }
    }

    /// Filled triangle pointing along `direction`, with its tip at
    /// `tip`. Sized off `strokeWidth` so it scales with the trail.
    private func drawArrowhead(at tip: CGPoint, direction: Direction,
                                color: NSColor) {
        let len = strokeWidth * 4
        let half = strokeWidth * 2.5
        let path = NSBezierPath()
        let p1: CGPoint, p2: CGPoint
        switch direction {
        case .right:
            p1 = CGPoint(x: tip.x - len, y: tip.y - half)
            p2 = CGPoint(x: tip.x - len, y: tip.y + half)
        case .left:
            p1 = CGPoint(x: tip.x + len, y: tip.y - half)
            p2 = CGPoint(x: tip.x + len, y: tip.y + half)
        case .up:
            p1 = CGPoint(x: tip.x - half, y: tip.y - len)
            p2 = CGPoint(x: tip.x + half, y: tip.y - len)
        case .down:
            p1 = CGPoint(x: tip.x - half, y: tip.y + len)
            p2 = CGPoint(x: tip.x + half, y: tip.y + len)
        }
        path.move(to: tip)
        path.line(to: p1)
        path.line(to: p2)
        path.close()
        color.withAlphaComponent(0.95).setFill()
        path.fill()
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

        if let hint, let cursor = cursor {
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
                    kind: .direction(arrow),
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
                    kind: .fires,
                    rect: firesRect, text: s,
                    fill: accent.withAlphaComponent(firesAlpha)))
            }
            // With blur disabled, regular cards still need a fill —
            // the frost would have been their backdrop. Re-run and
            // tag each non-fires layout with the solid dark fill.
            if !blurEnabled {
                for i in cardLayouts.indices where cardLayouts[i].fill == nil {
                    cardLayouts[i] = CardLayout(
                        kind: cardLayouts[i].kind,
                        rect: cardLayouts[i].rect,
                        text: cardLayouts[i].text,
                        fill: NSColor.black.withAlphaComponent(0.8))
                }
            }
        }

        if badgeEnabled,
           hint != nil, let icon = originIcon, let origin = origin {
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

        // Diff drives the unmatch effect and feeds reset()'s match
        // effect — skip both bookkeeping and dict construction when
        // neither hook is active (this runs on every mouse-move).
        if effectUnmatch != .none || effectMatch != .none {
            let newByKind = Dictionary(uniqueKeysWithValues:
                cardLayouts.map { ($0.kind, $0) })
            if effectUnmatch != .none {
                let now = CACurrentMediaTime()
                for (kind, oldLayout) in prevCardsByKind
                    where newByKind[kind] == nil {
                    let e = resolveRandom(effectUnmatch)
                    exitingCards.append(ExitingCard(
                        layout: oldLayout, effect: e, startedAt: now))
                    scheduleParticleEffect(oldLayout, effect: e)
                }
            }
            prevCardsByKind = newByKind
            kickExitAnimationTick()
        }
    }

    /// Emit a CAEmitterLayer for particle effects. No-op for the non-
    /// particle effects — those are drawn each frame in
    /// `HUDContentView`. The emitter auto-cleans after the effect's
    /// duration via a `DispatchQueue.main.asyncAfter`.
    private func scheduleParticleEffect(_ layout: CardLayout,
                                         effect: Effect) {
        guard effect == .fireworks || effect == .confetti else { return }
        let layer = makeEmitter(for: effect, at: layout.rect)
        hudContent.wantsLayer = true
        hudContent.layer?.addSublayer(layer)
        DispatchQueue.main.asyncAfter(deadline: .now() + effect.duration) {
            [weak layer] in layer?.removeFromSuperlayer()
        }
    }

    /// Drive redraws while exit animations are running. Idempotent —
    /// the `tickScheduled` flag absorbs repeat calls within a frame.
    private func kickExitAnimationTick() {
        guard !exitingCards.isEmpty, !tickScheduled else { return }
        tickScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) {
            [weak self] in self?.tickExitAnimations()
        }
    }

    private func tickExitAnimations() {
        tickScheduled = false
        let now = CACurrentMediaTime()
        exitingCards.removeAll { (now - $0.startedAt) >= $0.effect.duration }
        hudContent.needsDisplay = true
        kickExitAnimationTick()
    }

    /// Build a CAEmitterLayer configured for either `.fireworks`
    /// (burst upward from the card's bottom) or `.confetti` (raining
    /// down from the card's top). Both auto-fade via cell lifetime.
    private func makeEmitter(for effect: Effect, at rect: CGRect) -> CAEmitterLayer {
        let emitter = CAEmitterLayer()
        emitter.emitterSize = CGSize(width: rect.width, height: 1)
        emitter.emitterShape = .line
        // Particles wear small alpha-modulated dots; colour comes from
        // each cell's `color` channel multiplying the white texel.
        let dot = Self.particleDot
        let palette: [NSColor] = [
            .systemBlue, .systemGreen, .systemYellow,
            .systemOrange, .systemPink, .systemPurple,
        ]
        // Intensity scales count and reach but not lifetime — keeps
        // the burst timing consistent so particles always disappear
        // around the same moment the card has fully faded.
        let k = Float(effectIntensity)
        let cells: [CAEmitterCell] = palette.map { c in
            let cell = CAEmitterCell()
            cell.contents = dot
            cell.color = c.cgColor
            cell.birthRate = (effect == .fireworks ? 80 : 30) * k
            cell.lifetime = effect == .fireworks ? 0.7 : 1.0
            cell.lifetimeRange = 0.2
            cell.velocity = CGFloat((effect == .fireworks ? 180 : 90)) * effectIntensity
            cell.velocityRange = 60 * effectIntensity
            cell.emissionRange = effect == .fireworks ? .pi * 0.5 : 0.4
            cell.scale = 1.0
            cell.scaleRange = 0.4
            cell.scaleSpeed = -0.4
            cell.alphaSpeed = -1.2
            cell.spin = 1.0
            cell.spinRange = 4.0
            // Gravity: fireworks fall back down, confetti rains down.
            cell.yAcceleration = CGFloat(effect == .fireworks ? -160 : 90) * effectIntensity
            return cell
        }
        emitter.emitterCells = cells
        // Cocoa is Y-up: fireworks emit at the card's bottom edge
        // with longitude +π/2 (towards larger Y), confetti at the top
        // edge with -π/2.
        if effect == .fireworks {
            emitter.emitterPosition = CGPoint(
                x: rect.midX, y: rect.minY + 4)
            for cell in emitter.emitterCells ?? [] {
                cell.emissionLongitude = .pi / 2
            }
        } else {
            emitter.emitterPosition = CGPoint(
                x: rect.midX, y: rect.maxY - 4)
            for cell in emitter.emitterCells ?? [] {
                cell.emissionLongitude = -.pi / 2
            }
        }
        // Brief burst: birthRate goes to 0 after a short window so
        // particles stop spawning before the layer is removed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            [weak emitter] in emitter?.birthRate = 0
        }
        return emitter
    }

    /// Cached white-disc texel shared by every emitter cell — no point
    /// re-rasterising the same 6×6 image on each fireworks burst.
    private static let particleDot: CGImage = makeParticleDot(diameter: 6)

    private static func makeParticleDot(diameter d: CGFloat) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: Int(d), height: Int(d),
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: d, height: d))
        return ctx.makeImage()!
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
            drawCard(c, in: o, alpha: 1, dx: 0, dy: 0, scale: 1)
        }

        // Exiting cards drawn on top so their final fade frame can't be
        // covered by a live card the next layout pass happens to put in
        // the same spot.
        let now = CACurrentMediaTime()
        for ex in o.exitingCards {
            let p = CGFloat(min(1.0, max(0.0,
                (now - ex.startedAt) / ex.effect.duration)))
            let s = exitTransform(for: ex.effect, progress: p,
                                   intensity: o.effectIntensity)
            drawCard(ex.layout, in: o,
                     alpha: s.alpha, dx: s.dx, dy: s.dy, scale: s.scale)
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

    /// Draw one card (fill + border + text). `alpha` multiplies into
    /// the CGContext so the entire card fades uniformly; `dx`/`dy`/
    /// `scale` place the rect through the exit animation.
    private func drawCard(_ c: TrailView.CardLayout,
                          in o: TrailView,
                          alpha: CGFloat,
                          dx: CGFloat, dy: CGFloat, scale: CGFloat) {
        let bg = NSBezierPath(roundedRect: c.rect,
                              xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        if alpha < 1 {
            NSGraphicsContext.current?.cgContext.setAlpha(alpha)
        }
        if dx != 0 || dy != 0 || scale != 1 {
            let cx = c.rect.midX, cy = c.rect.midY
            let tx = NSAffineTransform()
            tx.translateX(by: cx + dx, yBy: cy + dy)
            tx.scaleX(by: scale, yBy: scale)
            tx.translateX(by: -cx, yBy: -cy)
            tx.concat()
        }
        if let fill = c.fill {
            fill.setFill()
            bg.fill()
        }
        NSColor.white.withAlphaComponent(0.18).setStroke()
        bg.lineWidth = 1
        bg.stroke()
        c.text.draw(with: c.rect.insetBy(dx: o.cardPadX, dy: o.cardPadY),
                    options: TrailView.textOpts)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Per-effect transform + alpha for an exiting card at `progress`
    /// (0..1 across the effect's duration). Cards rest with dx/dy=0,
    /// scale=1, alpha=1; the function eases them away on the chosen
    /// axis. Particle effects (`fireworks`, `confetti`) fade the card
    /// fast so the CAEmitterLayer carries the show.
    private func exitTransform(for effect: Effect,
                                progress p: CGFloat,
                                intensity k: CGFloat)
        -> (dx: CGFloat, dy: CGFloat, scale: CGFloat, alpha: CGFloat) {
        switch effect {
        case .none, .random:
            // .random is resolved at queue time; reaching it here
            // would mean a card slipped through unresolved — render
            // as an identity transform rather than crash.
            return (0, 0, 1, 1)
        case .drop:
            // Accelerating fall: y goes UP in Cocoa, so subtract.
            return (0, -240 * k * p * p, 1, 1 - p)
        case .rise:
            return (0, 120 * k * p, 1, 1 - p)
        case .slideLeft:
            return (-260 * k * p, 0, 1, 1 - p)
        case .slideRight:
            return (260 * k * p, 0, 1, 1 - p)
        case .explode:
            return (0, 0, 1 + 0.6 * k * p, 1 - p)
        case .vibrate:
            // Damped sine: 4 cycles, amplitude decays linearly.
            let dx = 10 * k * sin(p * .pi * 8) * (1 - p)
            return (dx, 0, 1, 1 - p)
        case .fade:
            return (0, 0, 1, 1 - p)
        case .fireworks, .confetti:
            // Fade card faster than the particles' duration so the
            // emitter visibly takes over.
            return (0, 0, 1, max(0, 1 - 2 * p))
        }
    }
}
