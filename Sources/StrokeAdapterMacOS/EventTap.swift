// CGEventTap-based MouseSource. Captures stroke samples from the
// configured trigger button (right-mouse by default) and emits one
// `StrokeEvent` per completed stroke.
//
// Lifecycle:
//   1. `start(_:)` installs a `.defaultTap` CGEventTap on the
//      `.cgSessionEventTap` location, hooked into the main run loop.
//   2. On trigger button-down (with required modifiers): resolve the
//      cursor-anchored window via `AXTarget.resolveAt(point:)`, begin
//      sampling. Down event is swallowed.
//   3. Each dragged event: append a `Sample`. Drag is swallowed so
//      stray drag-selection doesn't fire.
//   4. On button-up:
//        a. If `Recognition.recognize(...)` returned ≥1 direction the
//           stroke is "real" — deliver to handler, swallow up.
//        b. Otherwise the user effectively just clicked. Synthesize a
//           fresh down+up at the original location so the OS still
//           sees a normal click (right-click menu, middle-click paste,
//           …). Original up is still swallowed; the synthesized pair
//           is tagged with `replaySentinel` so we can ignore it when
//           it loops back through our own tap.
//
// Threading: the tap is added to `CFRunLoopGetMain()` in `.commonModes`,
// so the C callback runs on the main thread. All MacOSMouseSource state
// mutation lives on main — `@unchecked Sendable` is justified by that
// single-threaded invariant.

import AppKit
import CoreGraphics
import Foundation
import StrokeCore

/// One live trail update for the gesture overlay. Named fields beat a
/// 4-tuple here: `point` and the two strings (pattern / bundleID) plus
/// `expired` are easy to transpose positionally.
public struct TrailSample {
    /// Cursor location in CG global coords (Y-down).
    public let point: CGPoint
    /// Gesture-so-far recognised from all samples to date.
    public let pattern: String
    /// Cursor-anchored target's bundle id.
    public let bundleID: String
    /// Stroke has already exceeded `maxStrokeMs` (won't fire).
    public let expired: Bool
    /// Stroke has been scribble-cancelled (latched; won't fire).
    public let cancelled: Bool
}

public final class MacOSMouseSource: MouseSource, @unchecked Sendable {

    // Configuration -----------------------------------------------------
    private let trigger: Trigger
    private let minStrokePx: Int
    /// Max time (ms) a single segment may take; `0` = no limit. The
    /// clock resets on each turn, so a stalled single direction is
    /// abandoned at button-up.
    private let maxStrokeMs: Int
    /// 180° reversals that scribble-cancel the stroke; `0` = off.
    private let cancelReversals: Int
    /// Window (ms) those reversals must fall within; `0` = any speed.
    private let cancelWindowMs: Int
    /// `--record` mode: never fire actions, deliver *every* stroke
    /// (including too-short ones) to the handler so the recorder can
    /// log them, and still replay short clicks so the user keeps a
    /// working right-button while the recorder is open.
    private let isRecording: Bool

    // Tap state ---------------------------------------------------------
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var handler: (@Sendable (StrokeEvent) -> Void)?

    /// Live trail hooks for the gesture overlay (set at startup, both
    /// optional). `onSample` fires for the button-down point and each
    /// drag point in **CG global coords** (Y-down — what the overlay
    /// converts from). `onStrokeEnd` fires once when the button comes
    /// up, so the overlay can clear. Both run on the main thread (the
    /// tap callback). Recognition / dispatch are unaffected — the
    /// overlay is a passive observer of the same stream.
    ///
    /// `onSample` delivers a `TrailSample` (point + gesture-so-far +
    /// target bundle id + expired flag) — enough for the App layer to
    /// decide whether the in-progress stroke currently matches a rule
    /// (and colour the trail), without EventTap needing to know about
    /// rules. `onStrokeEnd` fires once on button-up so the overlay
    /// clears.
    ///
    /// Not `@Sendable` (unlike `handler`, which the protocol requires)
    /// so the closures can capture the non-Sendable `GestureOverlay`.
    /// Safe because everything here runs on the main thread; the
    /// enclosing class is already `@unchecked Sendable` on that basis.
    public var onSample: ((TrailSample) -> Void)?
    public var onStrokeEnd: (() -> Void)?

    // Per-stroke capture state -----------------------------------------
    private var capturing = false
    private var samples: [Sample] = []
    private var currentTarget: Target?
    private var strokeStart: TimeInterval = 0
    /// Timestamp of the last "turn" — button-down, or the moment a new
    /// direction was added to the live pattern. `maxStrokeMs` is measured
    /// from here, not from `strokeStart`, so a multi-segment gesture gets
    /// a fresh budget per segment and only a stalled single direction
    /// (the slow deliberate drag we want to ignore) expires.
    private var lastTurn: TimeInterval = 0
    /// Direction count of the live pattern at the last turn — a turn is
    /// detected when the recomputed pattern grows past this.
    private var lastDirCount = 0
    /// Latched once the live pattern accumulates `cancelReversals`
    /// back-and-forth reversals fast enough — a deliberate scribble.
    /// Stays set until the next button-down, so releasing fires nothing.
    private var cancelled = false
    /// Timestamp of each 180° reversal seen this stroke, in order. The
    /// span of the last `cancelReversals` of these is the scribble speed.
    private var reversalTimes: [TimeInterval] = []
    /// Mouse location at button-down in CG screen coords (origin
    /// top-left). Used to replay a click on no-motion strokes.
    private var downPoint: CGPoint = .zero

    /// Stamped on any CGEvent we synthesize (replayed clicks) so the
    /// callback can pass them through instead of feeding them back
    /// into capture. Arbitrary 64-bit sentinel — collisions are
    /// vanishingly unlikely with any real producer.
    private static let replaySentinel: Int64 = 0x5354_524B_E115

    /// Probe whether a session event tap can be installed right now —
    /// the definitive Accessibility check for `stroke --doctor`. Creates
    /// a listen-only tap, never adds it to a run loop, and tears it down
    /// immediately (safe alongside a running daemon — taps coexist).
    public static func canInstallTap() -> Bool {
        let mask: CGEventMask = 1 << CGEventType.mouseMoved.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: mask,
            callback: { _, _, e, _ in Unmanaged.passUnretained(e) },
            userInfo: nil
        ) else { return false }
        CGEvent.tapEnable(tap: tap, enable: false)
        return true
    }

    public init(trigger: Trigger, minStrokePx: Int,
                maxStrokeMs: Int = 0, cancelReversals: Int = 0,
                cancelWindowMs: Int = 0, isRecording: Bool = false) {
        self.trigger = trigger
        self.minStrokePx = minStrokePx
        self.maxStrokeMs = maxStrokeMs
        self.cancelReversals = cancelReversals
        self.cancelWindowMs = cancelWindowMs
        self.isRecording = isRecording
    }

    /// Has the current segment (time since the last turn) exceeded
    /// `maxStrokeMs`? Each direction change resets the clock, so the
    /// budget is per-segment rather than for the whole stroke.
    private var strokeExpired: Bool {
        maxStrokeMs > 0
            && (CACurrentMediaTime() - lastTurn) * 1000 > Double(maxStrokeMs)
    }

    /// Reset the segment clock when a new direction appears.
    private func noteTurn(dirCount: Int) {
        if dirCount > lastDirCount {
            lastDirCount = dirCount
            lastTurn = CACurrentMediaTime()
        }
    }

    /// Count of 180° reversals in a coalesced pattern (`L↔R`, `U↔D`).
    private static func reversals(_ pattern: String) -> Int {
        let c = Array(pattern)
        guard c.count > 1 else { return 0 }
        var n = 0
        for i in 1..<c.count where isOpposite(c[i - 1], c[i]) { n += 1 }
        return n
    }

    private static func isOpposite(_ a: Character, _ b: Character) -> Bool {
        (a == "L" && b == "R") || (a == "R" && b == "L")
            || (a == "U" && b == "D") || (a == "D" && b == "U")
    }

    // MARK: - MouseSource

    public func start(_ handler: @escaping @Sendable (StrokeEvent) -> Void) {
        self.handler = handler

        let mask = Self.eventMask(for: trigger.button)
        let cb: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<MacOSMouseSource>
                .fromOpaque(userInfo).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: cb,
            userInfo: userInfo
        ) else {
            Log.line("event-tap: tapCreate failed — is Accessibility "
                     + "granted? (stroke needs the AX entitlement to "
                     + "tap the session event stream)")
            return
        }
        self.tap = tap

        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        self.runLoopSource = src
        CGEvent.tapEnable(tap: tap, enable: true)

        Log.line("event-tap: installed (button=\(trigger.button.rawValue)"
                 + ", mods=\(trigger.modifiers.map(\.rawValue).sorted())"
                 + ", minStrokePx=\(minStrokePx))")
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        handler = nil
        Log.line("event-tap: stop")
    }

    // MARK: - Callback dispatch

    private func handle(type: CGEventType,
                        event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables our tap on timeout / heavy load; the
        // documented recovery is to simply flip it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // Promoted to Log.line: a flapping tap is a real symptom
            // (system load, handler too slow) the user should be able
            // to see without `--debug`. Repeated firings are still
            // single lines — readable, not a flood.
            Log.line("event-tap: re-enabled after disable "
                     + "(\(type.rawValue))")
            return Unmanaged.passUnretained(event)
        }

        // Hot path: .mouseMoved fires hundreds/sec. It's only a drag
        // sample while a stroke is in progress; when idle it's a
        // guaranteed pass-through. Short-circuit here, before the
        // field reads below, so the idle firehose costs one enum
        // compare + a bool. (We never synthesize .mouseMoved, so the
        // replaySentinel check doesn't apply to it.)
        if type == .mouseMoved {
            return capturing ? handleDrag(event: event)
                             : Unmanaged.passUnretained(event)
        }

        // Pass through events we ourselves synthesized.
        if event.getIntegerValueField(.eventSourceUserData)
            == Self.replaySentinel {
            return Unmanaged.passUnretained(event)
        }

        // For .otherMouse* event types we have to filter by button
        // number — there's one event type for "any other mouse button"
        // and the per-button distinction is in a field.
        if trigger.button != .right {
            let bn = event.getIntegerValueField(.mouseEventButtonNumber)
            if bn != Self.buttonNumber(for: trigger.button) {
                return Unmanaged.passUnretained(event)
            }
        }

        switch type {
        case .rightMouseDown, .otherMouseDown:
            return handleDown(event: event)
        case .rightMouseDragged, .otherMouseDragged:
            return handleDrag(event: event)
        case .rightMouseUp, .otherMouseUp:
            return handleUp(event: event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleDown(event: CGEvent) -> Unmanaged<CGEvent>? {
        // Strict equality on the five tracked modifier flags. Extra
        // modifiers held → not our gesture; pass through unchanged so
        // the user keeps normal mouse semantics (e.g. cmd+right-click
        // still raises the regular context menu).
        let observed = event.flags.intersection(Self.allModifierFlags)
        let required = trigger.modifiers.reduce(into: CGEventFlags()) { acc, m in
            if let f = Self.flagMap[m] { acc.formUnion(f) }
        }
        guard observed == required else {
            return Unmanaged.passUnretained(event)
        }

        // `event.location` is CG global coords (origin top-left,
        // Y grows DOWN). AX target resolution and click replay both
        // want this raw form. Recognition wants the Y-up convention
        // pinned by Models/Recognition tests, so each sample's Y is
        // flipped at creation time (`flipY`).
        //
        // Why not NSEvent.mouseLocation: when our tap swallows drag
        // events, AppKit never processes them, so the AppKit-side
        // cache that backs NSEvent.mouseLocation never updates. Every
        // subsequent drag callback would then see the at-button-down
        // position — the `max|dx|=0` symptom (every sample identical).
        let cg = event.location
        downPoint = cg
        currentTarget = AXTarget.resolveAt(point: cg)
        capturing = true
        strokeStart = CACurrentMediaTime()
        lastTurn = strokeStart
        lastDirCount = 0
        cancelled = false
        reversalTimes.removeAll(keepingCapacity: true)
        samples.removeAll(keepingCapacity: true)
        samples.append(Sample(p: Self.flipY(cg), t: 0))
        emitTrailSample(cg)

        // `Log.line` (not debug) so the gold-standard trace survives in
        // production logs — without this the user-visible failure modes
        // ("clicked but no gesture fired") have no log entry at all.
        if let t = currentTarget {
            Log.line("event-tap: down at \(cg) → \(t.bundleID) "
                     + "(pid \(t.pid), wid \(t.windowID))")
        } else {
            Log.line("event-tap: down at \(cg) → target=nil "
                     + "(cursor on Dock / menu bar / desktop / "
                     + "renderer area where AX walk + CG fallback both failed)")
        }
        return nil
    }

    private func handleDrag(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard capturing else { return Unmanaged.passUnretained(event) }
        let cg = event.location
        let t = CACurrentMediaTime() - strokeStart
        samples.append(Sample(p: Self.flipY(cg), t: t))
        emitTrailSample(cg)
        return nil
    }

    /// Feed the overlay one trail point plus the gesture-so-far, advance
    /// the per-segment expiry clock on each turn, and latch a cancel
    /// once the shape scribbles back and forth. The live pattern drives
    /// all three, so the recognise pass runs whenever any of the overlay,
    /// `maxStrokeMs`, or `cancelReversals` needs it — skipped otherwise.
    private func emitTrailSample(_ cg: CGPoint) {
        guard onSample != nil || maxStrokeMs > 0 || cancelReversals > 0
        else { return }
        let pattern = Recognition.recognize(samples: samples,
                                             minStrokePx: minStrokePx).patternString
        noteTurn(dirCount: pattern.count)
        if cancelReversals > 0 && !cancelled {
            let rev = Self.reversals(pattern)   // monotonic as samples grow
            if rev > reversalTimes.count {
                let now = CACurrentMediaTime()
                while reversalTimes.count < rev { reversalTimes.append(now) }
                if reversalTimes.count >= cancelReversals {
                    let span = now - reversalTimes[reversalTimes.count - cancelReversals]
                    if cancelWindowMs == 0 || span * 1000 <= Double(cancelWindowMs) {
                        cancelled = true
                        Log.debug("event-tap: scribble-cancelled at \(pattern) "
                                  + "(\(cancelReversals) reversals in "
                                  + "\(Int(span * 1000))ms)")
                    }
                }
            }
        }
        onSample?(TrailSample(point: cg, pattern: pattern,
                              bundleID: currentTarget?.bundleID ?? "",
                              expired: strokeExpired, cancelled: cancelled))
    }

    /// Convert CG global coords (Y grows down) to the Y-up convention
    /// Recognition was written against. Recognition only ever looks
    /// at relative motion, so a simple sign flip suffices — we don't
    /// need to know the primary display's height.
    private static func flipY(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: -p.y)
    }

    private func handleUp(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard capturing else { return Unmanaged.passUnretained(event) }
        let expired = strokeExpired         // capture before resetting state
        let wasCancelled = cancelled
        capturing = false
        onStrokeEnd?()   // clear the overlay trail, whatever the outcome

        let target = currentTarget
        let captured = samples
        currentTarget = nil
        samples.removeAll(keepingCapacity: true)

        // Recognise once here — both to decide gesture-vs-click and
        // because the handler will call Recognition again via the
        // Controller. The cost is negligible (≤O(captured.count)) and
        // it keeps the click/gesture branch authoritative.
        let recognised = Recognition.recognize(samples: captured,
                                                minStrokePx: minStrokePx)
        if recognised.isEmpty {
            replayClick(at: downPoint)
            let (dx, dy) = captured.span
            // `Log.line` so the diagnostic ("samples=N, max|dx|=…,
            // threshold=…") is visible without `--debug`. This is the
            // single most useful line for "I drew but nothing fired" —
            // the CLAUDE.md runbook reads it as the interpretation map.
            Log.line("event-tap: no stroke recognised on "
                     + "\(target?.bundleID ?? "<no-target>") (samples="
                     + "\(captured.count), max|dx|=\(Int(dx)), "
                     + "max|dy|=\(Int(dy)), threshold=\(minStrokePx)) "
                     + "— replayed click")
            // Recorder wants to see misses too — that's how the user
            // learns "I moved 12px but the threshold is 16."
            if isRecording { deliver(target, captured) }
            return nil
        }

        // Scribble-cancelled mid-stroke — abandon it. They moved (so no
        // click replay) and the shape is dead by design, no dispatch.
        if wasCancelled {
            Log.line("event-tap: \(recognised.patternString) recognised but "
                     + "scribble-cancelled — abandoned")
            if isRecording { deliver(target, captured) }
            return nil
        }

        // Recognisable shape but a single segment stalled longer than
        // `maxStrokeMs` (the clock resets on each turn) — abandon it. No
        // replay (they moved, so it wasn't a click) and no dispatch; the
        // whole sequence is already swallowed, so nothing happens.
        if expired {
            Log.line("event-tap: \(recognised.patternString) recognised but "
                     + "a segment stalled past \(maxStrokeMs)ms — abandoned")
            if isRecording { deliver(target, captured) }
            return nil
        }

        Log.line("event-tap: up — samples=\(captured.count), "
                 + "pattern=\(recognised.patternString)")
        if !deliver(target, captured) {
            Log.line("event-tap: pattern \(recognised.patternString) "
                     + "recognised but no AX target was resolved at "
                     + "stroke start — gesture dropped (cursor on Dock, "
                     + "menu bar, or another non-AX surface?)")
        }
        return nil
    }

    /// Hand a completed stroke to the controller / recorder. Returns
    /// `false` (and delivers nothing) when there's no target or no
    /// handler — the caller logs that case.
    @discardableResult
    private func deliver(_ target: Target?, _ samples: [Sample]) -> Bool {
        guard let target, let handler else { return false }
        handler(StrokeEvent(target: target, samples: samples))
        return true
    }

    // MARK: - Replay

    /// Synthesize a fresh trigger-button down+up pair at `point` (CG
    /// screen coords) so a no-motion gesture is indistinguishable from
    /// a real click — right-click menus, middle-click paste etc keep
    /// working. The events carry `replaySentinel` so our own tap
    /// passes them through.
    private func replayClick(at point: CGPoint) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = Self.mouseEventType(for: trigger.button, isDown: true)
        let up = Self.mouseEventType(for: trigger.button, isDown: false)
        let btn = Self.cgMouseButton(for: trigger.button)
        let btnNum = Self.buttonNumber(for: trigger.button)

        for type in [down, up] {
            guard let e = CGEvent(mouseEventSource: src,
                                  mouseType: type,
                                  mouseCursorPosition: point,
                                  mouseButton: btn) else { continue }
            e.setIntegerValueField(.mouseEventButtonNumber, value: btnNum)
            e.setIntegerValueField(.eventSourceUserData,
                                    value: Self.replaySentinel)
            e.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Trigger ↔ CGEvent helpers

    private static func eventMask(for button: Trigger.Button) -> CGEventMask {
        // Some virtual-HID layers (Karabiner-Elements, Logitech Options,
        // some KVMs) deliver mouse-button-held motion as `.mouseMoved`
        // instead of the per-button `.*Dragged` type. Capture both —
        // the `handleDrag` path no-ops when we're not in a stroke, so
        // the firehose of background mouseMoved events is just a cheap
        // bool check.
        let moveMask: CGEventMask = 1 << CGEventType.mouseMoved.rawValue
        switch button {
        case .right:
            return moveMask
                 | (1 << CGEventType.rightMouseDown.rawValue)
                 | (1 << CGEventType.rightMouseUp.rawValue)
                 | (1 << CGEventType.rightMouseDragged.rawValue)
        case .middle, .side1, .side2:
            return moveMask
                 | (1 << CGEventType.otherMouseDown.rawValue)
                 | (1 << CGEventType.otherMouseUp.rawValue)
                 | (1 << CGEventType.otherMouseDragged.rawValue)
        }
    }

    private static func buttonNumber(for button: Trigger.Button) -> Int64 {
        switch button {
        case .right:  return 1
        case .middle: return 2
        case .side1:  return 3
        case .side2:  return 4
        }
    }

    private static func cgMouseButton(for button: Trigger.Button) -> CGMouseButton {
        switch button {
        case .right:  return .right
        case .middle: return .center
        case .side1:  return CGMouseButton(rawValue: 3) ?? .center
        case .side2:  return CGMouseButton(rawValue: 4) ?? .center
        }
    }

    private static func mouseEventType(for button: Trigger.Button,
                                        isDown: Bool) -> CGEventType {
        switch (button, isDown) {
        case (.right, true):  return .rightMouseDown
        case (.right, false): return .rightMouseUp
        case (_,      true):  return .otherMouseDown
        case (_,      false): return .otherMouseUp
        }
    }

    // MARK: - Modifier ↔ CGEvent flags

    private static let allModifierFlags: CGEventFlags = [
        .maskCommand, .maskAlternate, .maskControl,
        .maskShift, .maskSecondaryFn
    ]

    private static let flagMap: [Modifier: CGEventFlags] = [
        .cmd:   .maskCommand,
        .opt:   .maskAlternate,
        .ctrl:  .maskControl,
        .shift: .maskShift,
        .fn:    .maskSecondaryFn,
    ]
}
