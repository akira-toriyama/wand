// Action execution against a cursor-anchored Target.
//
// Three variants, each dispatching to the captured Target (NOT the
// currently-focused window — that's the whole point of the
// cursor-anchored design):
//
//   .key("cmd+w")     raise(target), then post the key combo
//   .ax("close")      AXUIElementPerformAction on the target's
//                     close button / minimize attribute / zoom
//                     button. No focus switch needed.
//   .shell("cmd …")   spawn /bin/sh -c with STROKE_TARGET_*
//                     environment variables populated from `target`.

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
    /// on the previous keyWindow (the very failure mode the cursor-
    /// anchored design exists to avoid). 30 ms is well under human-
    /// perceptible latency.
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
    /// cursor-anchored failure mode recreated inside dispatch).
    ///
    /// Order mirrors facet's `AX.focus`: AX-level app frontmost,
    /// make this window main + focused, then raise it last so it
    /// lands on top. If we never resolved an AX window (cursor was
    /// over a non-AX surface like the Dock), fall back to app-level
    /// activate — at least the app comes forward.
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
        guard let down = CGEvent(keyboardEventSource: src,
                                  virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: src,
                                virtualKey: code, keyDown: false)
        else {
            // Both CGEvent ctors return optional even though they're
            // typed otherwise in older SDKs — when they fail the
            // keystroke is silently dropped. The trace would end with
            // `dispatch.key: cmd+w → …` and the user would think it
            // worked, so this needs to surface.
            Log.line("dispatch.key: CGEvent allocation failed "
                     + "(code=\(code), flags=\(flags.rawValue)) — "
                     + "keystroke dropped")
            return
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
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
            setBool(window, kAXMinimizedAttribute, true, verb: verb)
        case "raise":
            let err = AXUIElementPerformAction(
                window, kAXRaiseAction as CFString)
            if err != .success {
                Log.line("dispatch.ax: raise failed err=\(err.rawValue)")
            }
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
        // Type-guard the cast so a non-AXUIElement here can't crash
        // the daemon — log and bail instead.
        guard CFGetTypeID(btn) == AXUIElementGetTypeID() else {
            Log.line("dispatch.ax: \(attribute) is not an AXUIElement "
                     + "(typeID=\(CFGetTypeID(btn))) — ignored")
            return
        }
        let err = AXUIElementPerformAction(
            btn as! AXUIElement, kAXPressAction as CFString)
        if err != .success {
            Log.line("dispatch.ax: press \(attribute) failed "
                     + "err=\(err.rawValue)")
        }
    }

    private static func setBool(_ e: AXUIElement,
                                 _ attribute: String, _ value: Bool,
                                 verb: String) {
        let err = AXUIElementSetAttributeValue(
            e, attribute as CFString,
            (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef
        )
        if err != .success {
            Log.line("dispatch.ax: \(verb) (\(attribute)) failed "
                     + "err=\(err.rawValue)")
        }
    }

    // MARK: - .shell

    /// Run a shell command for a `.shell` action.
    ///
    /// SECURITY: the command string itself comes from the user's own
    /// `config.toml` and is treated as trusted (the user wrote it).
    /// The four `STROKE_TARGET_*` env vars however carry **untrusted**
    /// data — `STROKE_TARGET_TITLE` is a web page title, window title,
    /// or document name and can contain arbitrary characters including
    /// `$( )` and backticks. Authors writing `.shell` actions MUST
    /// quote any env-var expansion that reaches a shell command line.
    /// Example: `echo "$STROKE_TARGET_TITLE"`, not `echo $STROKE_TARGET_TITLE`.
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
        // Surface non-zero exits — a silent failing shell command was
        // the most under-diagnosed `.shell` failure mode previously
        // (the spawn-success line above made it look successful even
        // when the command itself errored).
        p.terminationHandler = { proc in
            if proc.terminationStatus != 0 {
                Log.line("dispatch.shell: exited "
                         + "rc=\(proc.terminationStatus): \(cmd)")
            }
        }
        do { try p.run() } catch {
            Log.line("dispatch.shell: spawn failed — \(error)")
        }
    }
}
