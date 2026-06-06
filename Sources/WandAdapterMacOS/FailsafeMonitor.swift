// Failsafe — the safety nets that catch a stuck click / drag and
// keep wand's positioning ("mouse enhancement") honest. wand grabs
// low-level mouse via CGEventTap; a bug, crash, or swallowed event
// maps directly to "the user's PC is now unusable". This monitor
// provides two of the five defense layers documented in CLAUDE.md's
// "Safety invariants" section:
//
//   • Button-hold timeout — polled watchdog. If any mouse button
//     stays `down` longer than `mouse-hold-timeout-sec`, force-post
//     a synthetic mouseUp at the current cursor. Catches both
//     wand-origin stuck states and external HID layers that drop
//     the real up event.
//
//   • Emergency release key — bare Esc, observed via
//     `NSEvent.addGlobalMonitorForEvents` (passive — Esc still
//     flows to the underlying app, so normal cancel / dismiss
//     behaviour is preserved). The release sequence is
//     **idempotent**: releasing an un-held button is a no-op,
//     cancelling an inactive state is a no-op, so the firehose of
//     normal Esc presses is harmless. Only logs when wand actually
//     released something.
//
// The other three layers (CLI escape hatch `wand --release-all`,
// tap-internal `buttonState` invariants on synthetic posts, and a
// CGEventTap watchdog reinstaller) are tracked as follow-ups; this
// file ships the two most user-facing nets that cover the common
// failure modes.

import AppKit
import CoreGraphics
import Foundation
import WandCore

public final class FailsafeMonitor: @unchecked Sendable {

    private let config: FailsafeConfig
    /// Idempotent state-clearing callback. Fires once per
    /// emergency-release event so the App layer can drop any
    /// in-progress cast stroke / tome panel before the synthetic
    /// mouseUp arrives at the tap. Safe to call when nothing is in
    /// flight; the callback itself is the source of the
    /// "no-op when idle" property.
    private let onRelease: @MainActor () -> Void
    private var escMonitor: Any?
    private var holdTimer: Timer?
    /// Per-button "first observed `down`" timestamp. Reset whenever
    /// the button transitions back to `up`. Used by `checkButtonHold`
    /// to detect when a button has stayed `down` past the configured
    /// timeout. Keyed by `CGMouseButton.rawValue` (`UInt32`).
    private var buttonDownSince: [UInt32: Date] = [:]

    public init(config: FailsafeConfig,
                onRelease: @escaping @MainActor () -> Void) {
        self.config = config
        self.onRelease = onRelease
    }

    @MainActor
    public func start() {
        installEscMonitor()
        installHoldWatchdog()
        Log.line("[failsafe] monitor started "
            + "(mouse-hold-timeout=\(config.mouseHoldTimeoutSec)s, "
            + "emergency-release-key=\(config.emergencyReleaseKey))")
    }

    @MainActor
    public func stop() {
        if let m = escMonitor {
            NSEvent.removeMonitor(m)
            escMonitor = nil
        }
        holdTimer?.invalidate()
        holdTimer = nil
    }

    // MARK: - Layer 2: emergency release key

    @MainActor
    private func installEscMonitor() {
        guard let keyCode = keyCode(for: config.emergencyReleaseKey)
        else {
            Log.line("[failsafe] unknown emergency-release-key "
                + "\"\(config.emergencyReleaseKey)\" — emergency"
                + " release disabled this session (only \"esc\" is"
                + " currently supported)")
            return
        }
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard event.keyCode == keyCode else { return }
            MainActor.assumeIsolated { self?.fireEmergencyRelease() }
        }
    }

    @MainActor
    private func fireEmergencyRelease() {
        var released: [String] = []
        for entry in mouseButtons {
            if CGEventSource.buttonState(
                .combinedSessionState, button: entry.button) {
                postMouseUp(button: entry.button)
                released.append(entry.name)
            }
        }
        // Tell the App layer to drop any in-flight trigger state so
        // the synthetic mouseUp's tap callback can't fire a spurious
        // cast / tome action behind us. Always called, even with an
        // empty `released` — the callback is idempotent.
        onRelease()
        // Only log when something actually changed — an empty log line
        // for every Esc press would drown out useful events. Quiet log
        // = wand healthy; an entry = wand had to step in.
        guard !released.isEmpty else { return }
        Log.line("[failsafe] emergency release fired "
            + "(released: \(released.joined(separator: ", ")))")
        // Clear tracking for buttons we just released so the
        // hold-watchdog doesn't trip again immediately.
        for entry in mouseButtons where released.contains(entry.name) {
            buttonDownSince[entry.button.rawValue] = nil
        }
    }

    // MARK: - Layer 1: button-hold timeout

    @MainActor
    private func installHoldWatchdog() {
        // Tick more often than the timeout so the worst-case latency
        // between "button stuck" and "wand force-releases" is ≈ one
        // tick (`timeout / 6`, clamped 1..5 s). Higher fidelity isn't
        // worth the polling cost; lower would let the user wait a
        // visibly long time for the rescue.
        let interval = max(
            1.0, min(5.0, Double(config.mouseHoldTimeoutSec) / 6.0))
        holdTimer = Timer.scheduledTimer(
            withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkButtonHold() }
        }
    }

    @MainActor
    private func checkButtonHold() {
        let now = Date()
        for entry in mouseButtons {
            let key = entry.button.rawValue
            let down = CGEventSource.buttonState(
                .combinedSessionState, button: entry.button)
            if down {
                if let since = buttonDownSince[key] {
                    let elapsed = now.timeIntervalSince(since)
                    if elapsed >= Double(config.mouseHoldTimeoutSec) {
                        let msg = "[failsafe] \(entry.name) button held "
                            + "\(Int(elapsed))s"
                            + " (> \(config.mouseHoldTimeoutSec)s)"
                            + " — force-releasing"
                        Log.line(msg)
                        postMouseUp(button: entry.button)
                        // Also drop wand's in-flight trigger state —
                        // same reasoning as the Esc path: the
                        // synthetic up will land at the tap, we want
                        // no spurious dispatch.
                        onRelease()
                        buttonDownSince[key] = nil
                    }
                } else {
                    buttonDownSince[key] = now
                }
            } else {
                buttonDownSince[key] = nil
            }
        }
    }

    // MARK: - mouseUp synthesis

    @MainActor
    private func postMouseUp(button: CGMouseButton) {
        let type: CGEventType
        switch button {
        case .left:   type = .leftMouseUp
        case .right:  type = .rightMouseUp
        case .center: type = .otherMouseUp
        @unknown default: return
        }
        // Use the current cursor location in CG coords. AppKit's
        // `NSEvent.mouseLocation` reports Cocoa coords (Y-up); flip
        // about the primary-screen height to land in CG (Y-down) —
        // the convention every other adapter file follows. The exact
        // location matters less for a release event than for a click
        // (the OS routes mouseUp to whichever target tracked the
        // matching mouseDown), but a coherent location is still
        // friendlier than `(0, 0)`.
        let cocoa = NSEvent.mouseLocation
        let primaryH = NSScreen.screens
            .first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? cocoa.y
        let cg = CGPoint(x: cocoa.x, y: primaryH - cocoa.y)
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: cg,
            mouseButton: button) else { return }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Button table

    private struct ButtonEntry {
        let button: CGMouseButton
        let name: String
    }
    /// Mouse buttons covered by the watchdog. side1 / side2 (mouse
    /// buttons 4 / 5) are not on this list yet — they can be added
    /// without a schema change once we have a test mouse to verify
    /// the synthetic up behaves as expected.
    private let mouseButtons: [ButtonEntry] = [
        ButtonEntry(button: .left,   name: "left"),
        ButtonEntry(button: .right,  name: "right"),
        ButtonEntry(button: .center, name: "middle"),
    ]

    private func keyCode(for name: String) -> UInt16? {
        switch name.lowercased() {
        case "esc", "escape": return 53
        default: return nil
        }
    }
}
