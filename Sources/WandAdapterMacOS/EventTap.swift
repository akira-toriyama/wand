// CGEventTap-based MouseSource. Down/drag are swallowed; on button-up
// either the stroke recognised → handler fires and the up is swallowed
// too, or it was effectively a click → we synthesise a fresh down+up
// (tagged with `replaySentinel` so we ignore it when it loops back).
//
// Threading: tap callback is on the main thread (`CFRunLoopGetMain()`
// in `.commonModes`); all state mutation lives there. `@unchecked
// Sendable` is justified by that single-threaded invariant.

import AppKit
import CoreGraphics
import Foundation
import WandCore

public struct TrailSample {
    public let point: CGPoint      // CG global coords, Y-down
    public let pattern: String
    public let bundleID: String
    /// Title of the cursor-anchored target captured at button-down.
    /// Lets the overlay's `valid` indicator + assist tooltips
    /// honour `filter-title` rules without re-querying AX per
    /// sample.
    public let title: String
    public let expired: Bool       // exceeded maxSegmentMs
    public let cancelled: Bool     // scribble-cancelled (latched)
    /// `true` when the bundleID above was synthesised from the
    /// frontmost-app fallback (cursor over Desktop / Dock / menu
    /// bar). The overlay uses this to filter the assist tooltips
    /// down to `[[cast.focused.rule]]` rows so the HUD only hints
    /// at strokes that can actually fire from here.
    public let isFocusedFallback: Bool

    public init(point: CGPoint, pattern: String, bundleID: String,
                title: String, expired: Bool, cancelled: Bool,
                isFocusedFallback: Bool = false) {
        self.point = point
        self.pattern = pattern
        self.bundleID = bundleID
        self.title = title
        self.expired = expired
        self.cancelled = cancelled
        self.isFocusedFallback = isFocusedFallback
    }
}

public final class MacOSMouseSource: MouseSource, @unchecked Sendable {

    // Configuration -----------------------------------------------------
    // `trigger` is baked into the running tap (event mask) and only
    // changes at restart. The four timing knobs below are mutable so
    // `updateConfig` can swap them live on the next sample.
    private let trigger: Trigger
    private var minStrokePx: Int
    /// Max time (ms) a single segment may take; `0` = no limit. The
    /// clock resets on each turn, so a stalled single direction is
    /// abandoned at button-up.
    private var maxSegmentMs: Int
    /// 180° reversals that scribble-cancel the stroke; `0` = off.
    private var cancelReversals: Int
    /// Window (ms) those reversals must fall within; `0` = any speed.
    private var cancelWindowMs: Int
    /// `--record` mode: never fire actions, deliver *every* stroke
    /// (including too-short ones) to the handler so the recorder can
    /// log them, and still replay short clicks so the user keeps a
    /// working right-button while the recorder is open.
    private let isRecording: Bool

    // Tap state ---------------------------------------------------------
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var handler: (@Sendable (WandEvent) -> Void)?

    /// Overlay hooks; both run on the main-thread tap callback. Not
    /// `@Sendable` (unlike the protocol's `handler`) so the closures
    /// can capture the non-Sendable `GestureOverlay` — safe because
    /// everything here is main-bound.
    public var onSample: ((TrailSample) -> Void)?
    public var onStrokeEnd: (() -> Void)?

    // Per-stroke capture state -----------------------------------------
    private var capturing = false
    private var samples: [Sample] = []
    private var currentTarget: Target?
    private var strokeStart: TimeInterval = 0
    /// Timestamp of the last "turn" — button-down, or the moment a new
    /// direction was added to the live pattern. `maxSegmentMs` is measured
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
    /// the definitive Accessibility check for `wand --doctor`. Creates
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
                maxSegmentMs: Int = 0, cancelReversals: Int = 0,
                cancelWindowMs: Int = 0, isRecording: Bool = false) {
        self.trigger = trigger
        self.minStrokePx = minStrokePx
        self.maxSegmentMs = maxSegmentMs
        self.cancelReversals = cancelReversals
        self.cancelWindowMs = cancelWindowMs
        self.isRecording = isRecording
    }

    /// Has the current segment (time since the last turn) exceeded
    /// `maxSegmentMs`? Each direction change resets the clock, so the
    /// budget is per-segment rather than for the whole stroke.
    private var strokeExpired: Bool {
        maxSegmentMs > 0
            && (CACurrentMediaTime() - lastTurn) * 1000 > Double(maxSegmentMs)
    }

    /// Reset the segment clock when a new direction appears.
    private func noteTurn(dirCount: Int) {
        if dirCount > lastDirCount {
            lastDirCount = dirCount
            lastTurn = CACurrentMediaTime()
        }
    }

    // Reversal counting moved to `Recognition.reversals` (Core) so the
    // pure logic is unit-testable without an AX/CG stack.


    public func start(_ handler: @escaping @Sendable (WandEvent) -> Void) {
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
                     + "granted? (wand needs the AX entitlement to "
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

    /// Hot-apply the four `[recognition]` timing knobs without
    /// reinstalling the event tap. The recogniser reads these values
    /// per-sample, so the swap takes effect on the very next gesture.
    /// `trigger` is intentionally not swappable here — the event mask
    /// is fixed at `tapCreate` time, and a button change needs a full
    /// restart (Controller.reload logs the warning).
    ///
    /// If a stroke is in progress when the swap arrives, the captured
    /// `samples` were threshold-checked against the OLD `minStrokePx`
    /// while subsequent samples would use the new one — a real
    /// recognition-state inconsistency. We cancel the in-progress
    /// gesture cleanly: drop samples, clear the overlay, no replay
    /// (the user moved on purpose). The chance of saving config.toml
    /// mid-drag is small; correctness wins here.
    public func updateConfig(_ cfg: WandConfig) {
        if capturing {
            Log.line("event-tap: [recognition] config swapped mid-stroke "
                     + "— cancelling the in-progress gesture to keep "
                     + "recognition state consistent")
            forceStrokeEnd()
        }
        minStrokePx = cfg.recognition.minStrokePx
        maxSegmentMs = cfg.recognition.maxSegmentMs
        cancelReversals = cfg.recognition.cancelReversals
        cancelWindowMs = cfg.recognition.cancelWindowMs
    }

    /// Drop all in-progress stroke state without firing recognition
    /// or dispatch — used by paths that need to abandon mid-gesture
    /// (mid-stroke config reload, tap-disable recovery). `onStrokeEnd`
    /// clears the overlay trail so the user sees the gesture cancel
    /// visually. Precondition: caller has logged the reason.
    private func forceStrokeEnd() {
        capturing = false
        samples.removeAll(keepingCapacity: true)
        currentTarget = nil
        cancelled = false
        reversalTimes.removeAll(keepingCapacity: true)
        lastDirCount = 0
        onStrokeEnd?()
    }


    private func handle(type: CGEventType,
                        event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables our tap on timeout / heavy load; the
        // documented recovery is to simply flip it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // Promoted to Log.line: a flapping tap is a real symptom
            // (system load, handler too slow) the user should be able
            // to see without WAND_DEBUG. Repeated firings are still
            // single lines — readable, not a flood.
            Log.line("event-tap: re-enabled after disable "
                     + "(\(type.rawValue))")
            // Defensive cleanup: any in-progress stroke was orphaned
            // while the tap was off — we won't have seen the real
            // `.rightMouseUp` that would have cleared `capturing`. If
            // we leave `capturing = true`, the `.mouseMoved` short-
            // circuit above will consume every subsequent move event
            // forever, breaking unrelated mouse activity (notably
            // left-button drag-and-drop in Chrome / Electron apps,
            // where the drag visualization depends on `.mouseMoved`
            // landing in the app's event queue). See `forceStrokeEnd`.
            if capturing {
                Log.line("event-tap: in-progress stroke aborted by "
                         + "tap-disable — clearing capturing state")
                forceStrokeEnd()
            }
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
            if bn != trigger.button.cgButtonNumber {
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
        guard event.matches(expectedFlags: CGModifier.flags(trigger.modifiers))
        else { return Unmanaged.passUnretained(event) }

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
        // Focused-fallback synthesis — when the cursor-anchored AX
        // walk + CG fallback both failed (Desktop / Dock / menu bar),
        // synthesise a `Target` from `NSWorkspace.frontmostApplication`
        // and mark it `isFocusedFallback = true`. The Matcher uses
        // that flag to fire only `[[cast.focused.rule]]` rows here;
        // `[[cast.cursor.rule]]` rows still treat a missing spine as
        // a hard "drop the gesture" signal.
        if currentTarget == nil,
           let frontmost = NSWorkspace.shared.frontmostApplication,
           let bid = frontmost.bundleIdentifier, !bid.isEmpty {
            currentTarget = Target(
                pid: frontmost.processIdentifier,
                bundleID: bid,
                title: frontmost.localizedName ?? "",
                frame: .zero, windowID: 0,
                isFocusedFallback: true)
        }
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
            if t.isFocusedFallback {
                Log.line("event-tap: down at \(cg) → focused-fallback "
                         + "→ \(t.bundleID) (pid \(t.pid)) — "
                         + "cursor was on a non-AX surface; only "
                         + "[[cast.focused.rule]] rows are eligible "
                         + "to fire")
            } else {
                Log.line("event-tap: down at \(cg) → \(t.bundleID) "
                         + "(pid \(t.pid), wid \(t.windowID))")
            }
        } else {
            Log.line("event-tap: down at \(cg) → target=nil "
                     + "(cursor on Dock / menu bar / desktop / "
                     + "renderer area where AX walk + CG fallback "
                     + "both failed, AND no frontmost app available "
                     + "for the focused-fallback path)")
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
    /// `maxSegmentMs`, or `cancelReversals` needs it — skipped otherwise.
    private func emitTrailSample(_ cg: CGPoint) {
        guard onSample != nil || maxSegmentMs > 0 || cancelReversals > 0
        else { return }
        let pattern = Recognition.recognize(samples: samples,
                                             minStrokePx: minStrokePx).patternString
        noteTurn(dirCount: pattern.count)
        if cancelReversals > 0 && !cancelled {
            let rev = Recognition.reversals(pattern)   // monotonic as samples grow
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
        onSample?(TrailSample(
            point: cg, pattern: pattern,
            bundleID: currentTarget?.bundleID ?? "",
            title: currentTarget?.title ?? "",
            expired: strokeExpired, cancelled: cancelled,
            isFocusedFallback: currentTarget?.isFocusedFallback
                ?? false))
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
            // threshold=…") is visible without WAND_DEBUG. This is the
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
        // `maxSegmentMs` (the clock resets on each turn) — abandon it. No
        // replay (they moved, so it wasn't a click) and no dispatch; the
        // whole sequence is already swallowed, so nothing happens.
        if expired {
            Log.line("event-tap: \(recognised.patternString) recognised but "
                     + "a segment stalled past \(maxSegmentMs)ms — abandoned")
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
        handler(WandEvent(target: target, samples: samples))
        return true
    }


    /// Synthesize a fresh trigger-button down+up pair at `point` (CG
    /// screen coords) so a no-motion gesture is indistinguishable from
    /// a real click — right-click menus, middle-click paste etc keep
    /// working. The events carry `replaySentinel` so our own tap
    /// passes them through.
    private func replayClick(at point: CGPoint) {
        let src = CGEventSource(stateID: .hidSystemState)
        let (down, up) = trigger.button.downUpTypes
        let btn = Self.cgMouseButton(for: trigger.button)
        let btnNum = trigger.button.cgButtonNumber

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


    /// Down + up + drag + mouseMoved mask for the configured button.
    /// We layer the drag and move bits on top of `Trigger.Button.
    /// downUpMask` because some virtual-HID layers (Karabiner-Elements,
    /// Logitech Options, some KVMs) deliver button-held motion as
    /// `.mouseMoved` instead of the per-button `.*Dragged` type —
    /// `handleDrag` no-ops outside a stroke, so the firehose of
    /// background `.mouseMoved` is just a cheap bool check.
    private static func eventMask(for button: Trigger.Button) -> CGEventMask {
        let moveMask: CGEventMask = 1 << CGEventType.mouseMoved.rawValue
        let dragMask: CGEventMask
        switch button {
        case .right:
            dragMask = 1 << CGEventType.rightMouseDragged.rawValue
        case .middle, .side1, .side2:
            dragMask = 1 << CGEventType.otherMouseDragged.rawValue
        }
        return button.downUpMask | dragMask | moveMask
    }

    /// `CGMouseButton` enum used by `CGEvent(mouseEventSource:…)` —
    /// distinct from `mouseEventButtonNumber` (an Int64 field). Kept
    /// here because synthesis is gesture-specific; the launcher tap
    /// never posts events.
    private static func cgMouseButton(for button: Trigger.Button) -> CGMouseButton {
        switch button {
        case .right:  return .right
        case .middle: return .center
        case .side1:  return CGMouseButton(rawValue: 3) ?? .center
        case .side2:  return CGMouseButton(rawValue: 4) ?? .center
        }
    }
}
