// Action execution against a cursor-anchored Target.
//
// Three variants, each dispatching to the captured Target (NOT the
// currently-focused window — that's the whole point of issue #115):
//
//   .key("cmd+w")     raise(target), then post the key combo
//   .ax("close")      AXUIElementPerformAction on the target's
//                     close button / minimize attribute / zoom
//                     button. No focus switch needed.
//   .shell("cmd …")   spawn /bin/sh -c with STROKE_TARGET_*
//                     environment variables populated from `target`.
//
// M1: skeletons only. Logging proves the right rule fired against
// the right target without yet causing side effects.

import AppKit
import ApplicationServices
import Foundation
import StrokeCore

public enum Dispatch {

    public static func execute(_ action: Action, on target: Target) {
        switch action {
        case .key(let combo):       runKey(combo, target: target)
        case .ax(let verb):         runAX(verb, target: target)
        case .shell(let cmd):       runShell(cmd, target: target)
        }
    }

    // MARK: - .key

    /// Delay between activating the target app and posting the
    /// keystroke. Activation is asynchronous — the new app takes a
    /// tick to become key, and a keystroke posted too early lands
    /// on the previous keyWindow (the very bug this project exists
    /// to fix). 30 ms matches MacGesture's choice and is well under
    /// human-perceptible latency.
    private static let activationDelayMs = 30

    private static func runKey(_ combo: String, target: Target) {
        guard let parsed = KeyCombo.parse(combo) else {
            Log.line("dispatch.key: could not parse \"\(combo)\"")
            return
        }
        Log.line("dispatch.key: \(combo) → \(target.bundleID) "
                 + "(pid \(target.pid), wid \(target.windowID))")

        raiseSpecificWindow(target: target)

        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(activationDelayMs)
        ) {
            postKey(flags: parsed.flags, code: parsed.keyCode)
        }
    }

    /// Bring the *specific* cursor-anchored window forward — not just
    /// the app. Activating only the app picks the app's last-focused
    /// window, which for a multi-window app is exactly the wrong one
    /// (e.g. two Chrome windows: cursor on B, focus on A → activate
    /// Chrome → A stays frontmost → cmd+w closes A's tab. That's the
    /// issue #115 bug recreated inside dispatch).
    ///
    /// Order mirrors facet's `AX.focus`: AX-level app frontmost,
    /// make this window main + focused, then raise it last so it
    /// lands on top. If we never resolved an AX window (M1/M2
    /// fallback, or cursor was over a non-AX surface), fall back to
    /// app-level activate — at least the app comes forward.
    private static func raiseSpecificWindow(target: Target) {
        guard let window = AXTarget.liveElement(for: target) else {
            Log.line("dispatch.key: no live AX window for "
                     + "pid=\(target.pid) wid=\(target.windowID) — "
                     + "falling back to app activate (keystroke may "
                     + "land on the app's last-focused window)")
            NSRunningApplication(processIdentifier: target.pid)?
                .activate(options: [.activateIgnoringOtherApps])
            return
        }
        let appElement = AXUIElementCreateApplication(target.pid)
        AXUIElementSetAttributeValue(
            appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(
            window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(
            window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    private static func postKey(flags: CGEventFlags, code: CGKeyCode) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src,
                           virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: src,
                         virtualKey: code, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - .ax

    /// Operate on the cursor-anchored window directly via AX — no
    /// app activation, no focus theft, no keystroke. The window
    /// handle was stashed in `AXTarget.liveElements` at stroke start;
    /// we just look it up by `(pid, windowID)`.
    ///
    /// Verbs:
    ///   close     — press kAXCloseButtonAttribute
    ///   minimize  — set kAXMinimizedAttribute = true
    ///   zoom      — press kAXZoomButtonAttribute (green button)
    ///   raise     — kAXRaiseAction on the window itself
    private static func runAX(_ verb: String, target: Target) {
        Log.line("dispatch.ax: \(verb) → \(target.bundleID) "
                 + "(pid \(target.pid), wid \(target.windowID))")
        guard let window = AXTarget.liveElement(for: target) else {
            Log.line("dispatch.ax: no live AXUIElement for "
                     + "pid=\(target.pid) wid=\(target.windowID) — "
                     + "was the target resolved at stroke start?")
            return
        }
        switch verb.lowercased() {
        case "close":
            pressChild(of: window, attribute: kAXCloseButtonAttribute)
        case "zoom":
            pressChild(of: window, attribute: kAXZoomButtonAttribute)
        case "minimize":
            setBool(window, kAXMinimizedAttribute, true)
        case "raise":
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        default:
            Log.line("dispatch.ax: unknown verb \"\(verb)\" — "
                     + "expected close | minimize | zoom | raise")
        }
    }

    /// Read a button child of `window` (e.g. close / zoom button)
    /// and fire its press action. No-op (with log) if the window
    /// doesn't expose that button — e.g. a borderless panel.
    private static func pressChild(of window: AXUIElement, attribute: String) {
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window, attribute as CFString, &val) == .success,
              let btn = val else {
            Log.line("dispatch.ax: window has no \(attribute)")
            return
        }
        AXUIElementPerformAction(btn as! AXUIElement,
                                  kAXPressAction as CFString)
    }

    private static func setBool(_ e: AXUIElement,
                                 _ attribute: String, _ value: Bool) {
        AXUIElementSetAttributeValue(
            e, attribute as CFString,
            (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef
        )
    }

    // MARK: - .shell

    private static func runShell(_ cmd: String, target: Target) {
        Log.line("dispatch.shell: \(cmd) (target \(target.bundleID))")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        var env = ProcessInfo.processInfo.environment
        env["STROKE_TARGET_BUNDLE_ID"] = target.bundleID
        env["STROKE_TARGET_PID"] = String(target.pid)
        env["STROKE_TARGET_TITLE"] = target.title
        env["STROKE_TARGET_FRAME"] =
            "\(Int(target.frame.minX)),\(Int(target.frame.minY))," +
            "\(Int(target.frame.width)),\(Int(target.frame.height))"
        p.environment = env
        do { try p.run() } catch {
            Log.line("dispatch.shell: spawn failed — \(error)")
        }
    }
}
