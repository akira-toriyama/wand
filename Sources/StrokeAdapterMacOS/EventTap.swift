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

public final class MacOSMouseSource: MouseSource, @unchecked Sendable {

    // Configuration -----------------------------------------------------
    private let trigger: Trigger
    private let minStrokePx: Int
    /// `--record` mode: never fire actions, deliver *every* stroke
    /// (including too-short ones) to the handler so the recorder can
    /// log them, and still replay short clicks so the user keeps a
    /// working right-button while the recorder is open.
    private let isRecording: Bool

    // Tap state ---------------------------------------------------------
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var handler: (@Sendable (StrokeEvent) -> Void)?

    // Per-stroke capture state -----------------------------------------
    private var capturing = false
    private var samples: [Sample] = []
    private var currentTarget: Target?
    private var strokeStart: TimeInterval = 0
    /// Mouse location at button-down in CG screen coords (origin
    /// top-left). Used to replay a click on no-motion strokes.
    private var downPoint: CGPoint = .zero

    /// Stamped on any CGEvent we synthesize (replayed clicks) so the
    /// callback can pass them through instead of feeding them back
    /// into capture. Arbitrary 64-bit sentinel — collisions are
    /// vanishingly unlikely with any real producer.
    private static let replaySentinel: Int64 = 0x5354_524B_E115

    public init(trigger: Trigger, minStrokePx: Int,
                isRecording: Bool = false) {
        self.trigger = trigger
        self.minStrokePx = minStrokePx
        self.isRecording = isRecording
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
            Log.debug("event-tap: re-enabled after disable (\(type.rawValue))")
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
        samples.removeAll(keepingCapacity: true)
        samples.append(Sample(p: Self.flipY(cg), t: 0))

        Log.debug("event-tap: down at \(cg) → "
                  + "target=\(currentTarget?.bundleID ?? "nil")")
        return nil
    }

    private func handleDrag(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard capturing else { return Unmanaged.passUnretained(event) }
        let cg = event.location
        let t = CACurrentMediaTime() - strokeStart
        samples.append(Sample(p: Self.flipY(cg), t: t))
        return nil
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
        capturing = false

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
            Log.debug("event-tap: no stroke recognised (samples="
                      + "\(captured.count), max|dx|=\(Int(dx)), "
                      + "max|dy|=\(Int(dy)), threshold=\(minStrokePx)) "
                      + "— replayed click")
            // Recorder wants to see misses too — that's how the user
            // learns "I moved 12px but the threshold is 16."
            if isRecording, let target, let h = handler {
                h(StrokeEvent(target: target, samples: captured))
            }
            return nil
        }

        Log.debug("event-tap: up — samples=\(captured.count), "
                  + "pattern=\(recognised.patternString)")
        if let target, let h = handler {
            h(StrokeEvent(target: target, samples: captured))
        } else {
            Log.line("event-tap: pattern \(recognised.patternString) "
                     + "recognised but no AX target was resolved at "
                     + "stroke start — gesture dropped (cursor on Dock, "
                     + "menu bar, or another non-AX surface?)")
        }
        return nil
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
