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

    private let trigger: Trigger
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var handler: (@Sendable (LauncherEvent) -> Void)?
    // Precomputed at init so the hot-path callback doesn't rebuild
    // them per event. Trigger is immutable post-init (a config
    // change needs a daemon restart, surfaced as pending-restart),
    // so caching is safe.
    private let expectedFlags: CGEventFlags
    private let wantButton: Int64
    private let downType: CGEventType
    private let upType: CGEventType

    public init(trigger: Trigger) {
        self.trigger = trigger
        self.expectedFlags = CGModifier.flags(trigger.modifiers)
        self.wantButton = trigger.button.cgButtonNumber
        let (d, u) = trigger.button.downUpTypes
        self.downType = d
        self.upType = u
    }

    /// Cheap probe — install a listen-only tap and tear it down. Used
    /// by `wand --doctor` to confirm the launcher tap path works
    /// without touching the real handler.
    public static func canInstallTap(trigger: Trigger) -> Bool {
        let mask = trigger.button.downUpMask
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

        let mask = trigger.button.downUpMask
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
        // No-op: trigger is immutable post-init (changing it needs a
        // fresh tapCreate, which is a daemon restart). The Controller
        // logs the mismatch on reload and surfaces it as
        // `pending-restart` in `--status`.
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

        if type == downType {
            // `.otherMouseDown` covers middle / side1 / side2 — filter
            // by button number so a side-button click doesn't fire a
            // middle-configured menu (and vice versa).
            guard matchesConfiguredButton(event) else {
                return Unmanaged.passRetained(event)
            }
            // Modifier gate — only fire when the configured modifiers
            // match exactly. An empty `modifiers` requires NO modifier
            // is held (a plain middle-click), so accidentally Cmd-
            // clicking still passes through to the app.
            guard event.matches(expectedFlags: expectedFlags) else {
                return Unmanaged.passRetained(event)
            }

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

        if type == upType, matchesConfiguredButton(event) {
            // Pair the consumed down by consuming the up too, so the
            // foreground app's click tracking doesn't see a phantom up.
            return nil
        }

        return Unmanaged.passRetained(event)
    }

    /// `.otherMouseDown` carries middle / side1 / side2; the trigger
    /// button's number filters to the one we care about.
    private func matchesConfiguredButton(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.mouseEventButtonNumber) == wantButton
    }
}
