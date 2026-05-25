// Launcher trigger — a separate CGEventTap masking only the
// configured button's down/up. Sibling to MacOSMouseSource (which
// owns the gesture tap); two taps coexist on the same daemon so the
// gesture's right-button-drag and the launcher's middle-click never
// fight over a single mask.
//
// We consume BOTH down and up of the trigger button: if we ate the
// down but let the up through, the foreground app would see a
// phantom mouse-up without a paired down and confuse its own click
// tracking.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import WandCore

public final class MacOSLauncherSource: LauncherSource, @unchecked Sendable {

    private var trigger: Trigger
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var handler: (@Sendable (LauncherEvent) -> Void)?

    public init(trigger: Trigger) {
        self.trigger = trigger
    }

    /// Cheap probe — install a listen-only tap and tear it down. Used
    /// by `wand --doctor` to confirm the launcher tap path works
    /// without touching the real handler.
    public static func canInstallTap(trigger: Trigger) -> Bool {
        let mask = Self.eventMask(for: trigger.button)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, e, _ in Unmanaged.passRetained(e) },
            userInfo: nil
        ) else { return false }
        CGEvent.tapEnable(tap: tap, enable: false)
        return true
    }

    public func start(_ handler: @escaping @Sendable (LauncherEvent) -> Void) {
        self.handler = handler

        let mask = Self.eventMask(for: trigger.button)
        let info = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let me = Unmanaged<MacOSLauncherSource>
                    .fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: info
        ) else {
            Log.line("launcher-tap: tapCreate failed — is Accessibility "
                     + "granted? (System Settings → Privacy & Security)")
            return
        }
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = src
        Log.line("launcher-tap: installed (button=\(trigger.button.rawValue), "
                 + "mods=\(trigger.modifiers.map(\.rawValue).sorted()))")
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        handler = nil
    }

    public func updateConfig(_ cfg: WandConfig) {
        // Trigger change requires a fresh tapCreate (event mask is
        // baked at install). Surfaced in --status as pending-restart;
        // Controller logs the mismatch on reload.
    }

    // MARK: - tap callback

    private func handle(type: CGEventType,
                        event: CGEvent) -> Unmanaged<CGEvent>? {
        // The tap is auto-disabled on timeout or user-input throttling;
        // re-arm so the next click still fires the menu.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)
        }

        let downType = Self.mouseEventType(for: trigger.button, isDown: true)
        let upType = Self.mouseEventType(for: trigger.button, isDown: false)

        if type == downType {
            // `.otherMouseDown` covers middle / side1 / side2 — filter
            // by button number so a side-button click doesn't fire a
            // middle-configured menu (and vice versa).
            guard handleSideButtonFilter(event)
            else { return Unmanaged.passRetained(event) }
            // Modifier gate — only fire when the configured modifiers
            // match exactly. An empty `modifiers` requires NO modifier
            // is held (a plain middle-click), so accidentally Cmd-
            // clicking still passes through to the app.
            guard Self.modifiersMatch(event: event, want: trigger.modifiers)
            else { return Unmanaged.passRetained(event) }

            let point = event.location  // CG global, Y-down
            // Resolve the target AT THE MOMENT of the click — same
            // cursor-anchored invariant as the gesture path. The menu
            // closes before the user can move to another window, so
            // by the time an action dispatches focus may have moved;
            // we still act on the original target.
            guard let target = AXTarget.resolveAt(point: point) else {
                Log.line("launcher-tap: down at \(point) → target=nil "
                         + "(cursor on Dock / menu bar / desktop) — "
                         + "menu suppressed")
                return nil  // still consume so app doesn't see middle-click
            }
            Log.line("launcher-tap: down at \(point) → \(target.bundleID)")
            handler?(LauncherEvent(point: point, target: target))
            return nil  // consume — don't let the foreground app see it
        }

        if type == upType, handleSideButtonFilter(event) {
            // Pair the consumed down by consuming the up too, so the
            // foreground app's click tracking doesn't see a phantom up.
            return nil
        }

        return Unmanaged.passRetained(event)
    }

    // MARK: - helpers

    private static func eventMask(for button: Trigger.Button) -> CGEventMask {
        switch button {
        case .right:
            return (1 << CGEventType.rightMouseDown.rawValue)
                 | (1 << CGEventType.rightMouseUp.rawValue)
        case .middle, .side1, .side2:
            return (1 << CGEventType.otherMouseDown.rawValue)
                 | (1 << CGEventType.otherMouseUp.rawValue)
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

    /// `side1` / `side2` distinguish via `mouseEventButtonNumber`:
    /// middle = 2, side1 = 3, side2 = 4. Down/up types collapse `.middle
    /// | .side1 | .side2` to the same `.otherMouse*` so we filter by
    /// button number to keep the configured side button isolated from
    /// the others on multi-button mice.
    private func handleSideButtonFilter(_ event: CGEvent) -> Bool {
        let want = Self.buttonNumber(for: trigger.button)
        let got = event.getIntegerValueField(.mouseEventButtonNumber)
        return got == want
    }

    private static func buttonNumber(for button: Trigger.Button) -> Int64 {
        switch button {
        case .right:  return 1
        case .middle: return 2
        case .side1:  return 3
        case .side2:  return 4
        }
    }

    private static let allModifierFlags: CGEventFlags = [
        .maskCommand, .maskAlternate, .maskControl,
        .maskShift, .maskSecondaryFn
    ]
    private static let flagMap: [Modifier: CGEventFlags] = [
        .cmd: .maskCommand, .opt: .maskAlternate,
        .ctrl: .maskControl, .shift: .maskShift,
        .fn: .maskSecondaryFn,
    ]
    private static func modifiersMatch(event: CGEvent,
                                        want: Set<Modifier>) -> Bool {
        let actual = event.flags.intersection(allModifierFlags)
        let expected: CGEventFlags = want.reduce([]) { acc, m in
            acc.union(flagMap[m] ?? [])
        }
        return actual == expected
    }
}
