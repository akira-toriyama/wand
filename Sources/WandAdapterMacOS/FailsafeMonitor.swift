// Two of the five `[failsafe]` defense layers documented in
// CLAUDE.md's "Safety invariants" section:
//   • button-hold timeout (Layer 1)
//   • Esc emergency-release key (Layer 2)
// See CLAUDE.md and the `[failsafe]` block in the bundled
// `config.toml` for the WHY of each layer; this file just wires them.

import AppKit
import CoreGraphics
import Foundation
import WandCore

public final class FailsafeMonitor: @unchecked Sendable {

    private let config: FailsafeConfig
    private var escMonitor: Any?
    private var holdTimer: Timer?
    private var buttonDownSince: [UInt32: Date] = [:]

    public init(config: FailsafeConfig) {
        self.config = config
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
                buttonDownSince[entry.button.rawValue] = nil
            }
        }
        // Quiet log on idle Esc presses is the signal: an entry means
        // wand had to step in.
        guard !released.isEmpty else { return }
        Log.line("[failsafe] emergency release fired "
            + "(released: \(released.joined(separator: ", ")))")
    }

    // MARK: - Layer 1: button-hold timeout

    @MainActor
    private func installHoldWatchdog() {
        // Worst-case rescue latency ≈ one tick; clamp 1..5 s so a long
        // user-set timeout doesn't push the rescue past a visibly long
        // wait, and a short one doesn't burn CPU polling.
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
        let cg = ScreenCoords.cgPoint(fromCocoa: NSEvent.mouseLocation)
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
