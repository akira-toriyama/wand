// Cursor-anchored window targeting — the spine of the project.
// `resolveAt(point:)` at button-down freezes which window sits under
// the cursor; actions later dispatch to *that* window regardless of
// focus. Two resolution paths: the AX-walk (normal apps), and the
// CGWindowList fallback (Chrome's multi-process renderer area
// returns AX elements whose parent chain never reaches a window).
//
// Threading: every call is main-thread (tap callback → Controller
// → resolveAt), so `liveElements` needs no lock.

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import WandCore

// Private API: `_AXUIElementGetWindow` translates an `AXUIElement`
// to its `CGWindowID`. Resolved via `dlsym` so we don't link the
// symbol at build time. `nil` means it moved / went away — windowID
// stays 0 and the side-table lookup falls back to pid-only matching.
private typealias AXGetWindowFn =
    @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError

private let axGetWindow: AXGetWindowFn? = {
    guard let s = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                        "_AXUIElementGetWindow") else { return nil }
    return unsafeBitCast(s, to: AXGetWindowFn.self)
}()

public enum AXTarget {


    /// Resolve the window under `point` (CG global screen coords —
    /// origin top-left, Y grows down — exactly what
    /// `CGEvent.location` gives the event-tap callback). Returns
    /// `nil` if AX is not granted, no window sits there, or the
    /// system was too slow to answer within `axTimeout`.
    public static func resolveAt(point: CGPoint) -> Target? {
        var hit: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(
            systemWide, Float(point.x), Float(point.y), &hit
        )
        // Distinguish the three failure modes — a future remote-diagnosis
        // session needs to know *why* a gesture was dropped, not just
        // "AX returned nil." Three real causes, three lines:
        //   - copyElementAtPosition itself failed (rare; permission)
        //   - parent chain didn't reach a window (Chrome renderer area)
        //   - cg-window also empty (real Dock / menu / desktop)
        if err != .success {
            Log.debug("AX: copyElementAtPosition failed at \(point) "
                      + "err=\(err.rawValue)")
        } else if let element = hit,
                  let window = walkToWindow(from: element) {
            return finalize(window: window, point: point, via: "ax-walk")
        }

        if let (window, _) = windowAtPointViaCG(point: point) {
            // Worth logging at debug that we needed the fallback — when
            // the user reports flaky behaviour on a specific app, a tail
            // of `via cg-window` lines is the signal that ax-walk is
            // structurally failing there (multi-process renderer etc.).
            return finalize(window: window, point: point, via: "cg-window")
        }

        Log.line("AX: no window resolvable at \(point) — "
                 + "ax-walk failed and CGWindowList found no on-screen "
                 + "window there. Cursor was likely on Dock / menu bar / "
                 + "desktop. Gesture dropped.")
        return nil
    }

    /// Read the metadata off `window`, register it for `.ax` dispatch,
    /// and log how we found it. Shared by the direct AX-walk path and
    /// the CGWindowList fallback so they record identical Targets.
    private static func finalize(window: AXUIElement,
                                  point: CGPoint, via: String) -> Target {
        AXUIElementSetMessagingTimeout(window, axTimeout)
        var pid: pid_t = 0
        // Surface a pid-lookup failure rather than registering a target
        // with pid=0 (which `NSRunningApplication(processIdentifier:)`
        // can't resolve, so the bundleID would silently come back as ""
        // and the rule's `apps` filter would never match).
        let pidErr = AXUIElementGetPid(window, &pid)
        if pidErr != .success || pid == 0 {
            Log.line("AX: getPid failed (err=\(pidErr.rawValue)) at "
                     + "\(point) — bundleID will be empty; rules with an "
                     + "`apps` filter won't match this gesture")
        }
        let title = string(window, kAXTitleAttribute) ?? ""
        let frame = readFrame(window)
        let bundleID = NSRunningApplication(processIdentifier: pid)?
            .bundleIdentifier ?? ""
        var wid: UInt32 = 0
        _ = axGetWindow?(window, &wid)
        let target = Target(pid: pid, bundleID: bundleID,
                            title: title, frame: frame, windowID: wid)
        register(window, for: target)
        Log.debug("AX: resolved point=\(point) via \(via) → "
                  + "\(bundleID) wid=\(wid) title=\"\(title)\"")
        return target
    }

    /// Topmost normal-level on-screen window whose frame contains
    /// `point`, paired with its AX peer (re-acquired through the
    /// owning app so the renderer-process orphaning doesn't bite).
    /// Returns `nil` for menu bar / desktop / Dock hits.
    private static func windowAtPointViaCG(point: CGPoint)
        -> (AXUIElement, pid_t)?
    {
        let opts: CGWindowListOption =
            [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        // CGWindowListCopyWindowInfo returns windows in front-to-back
        // z-order; first hit is what the cursor visually sits on.
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let bounds = info[kCGWindowBounds as String]
                    as? [String: CGFloat],
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let wid = info[kCGWindowNumber as String] as? UInt32
            else { continue }
            let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                              width: bounds["Width"] ?? 0,
                              height: bounds["Height"] ?? 0)
            guard rect.contains(point) else { continue }
            if let ax = findAXWindow(pid: pid, windowID: wid) {
                return (ax, pid)
            }
        }
        return nil
    }

    /// AX window element belonging to `pid` whose CGWindowID matches.
    /// Iterates the app's kAXWindows; `_AXUIElementGetWindow` gives the
    /// id of each, exactly the same private API the success path uses.
    private static func findAXWindow(pid: pid_t,
                                      windowID: UInt32) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                app, kAXWindowsAttribute as CFString, &val) == .success,
              let windows = val as? [AXUIElement]
        else { return nil }
        for w in windows {
            var wid: UInt32 = 0
            if axGetWindow?(w, &wid) == .success, wid == windowID {
                return w
            }
        }
        return nil
    }

    /// Live `AXUIElement` previously registered for `target` (by
    /// pid + windowID). Used by `Dispatch.runAX`. Nil if the entry
    /// has been evicted from the LRU or the window couldn't be
    /// resolved (windowID == 0). Pid-only matching is intentionally
    /// not provided — a stale match against the wrong window of the
    /// same multi-window app is worse than silently no-op'ing.
    public static func liveElement(for target: Target) -> AXUIElement? {
        let key = SideKey(pid: target.pid, windowID: target.windowID)
        guard let element = liveElements.first(where: { $0.0 == key })?.1
        else { return nil }
        // Liveness probe: the LRU has no upper bound on age, so a pid
        // may have died and been recycled. If we returned a stale
        // element a pid-recycled process inherits, `Dispatch.runAX`
        // would press the close button on whatever inherited the pid.
        // A cheap kAXRole round-trip distinguishes "valid window" from
        // "AX element backing object is gone" via .invalidUIElement /
        // .cannotComplete.
        var val: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &val)
        if err != .success {
            Log.line("AX: live element for pid=\(target.pid) "
                     + "wid=\(target.windowID) is stale (err=\(err.rawValue)) — "
                     + "evicting; the target was probably closed or its "
                     + "process exited")
            liveElements.removeAll { $0.0 == key }
            return nil
        }
        return element
    }


    /// Current trust state, without prompting — for `wand --doctor`.
    public static func isTrusted() -> Bool { AXIsProcessTrusted() }

    /// Focused-window title of the app owning `pid`. Empty string
    /// when the app exposes no focused window, no title attribute,
    /// or AX denies the read. Used by `--show-menu` to fill in
    /// `Target.title` (= `$WAND_TARGET_TITLE`) on external triggers
    /// where the calling shell can't know the window title itself.
    public static func focusedWindowTitle(pid: pid_t) -> String {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app,
                kAXFocusedWindowAttribute as CFString, &value) == .success,
              let v = value else { return "" }
        return string(v as! AXUIElement, kAXTitleAttribute) ?? ""
    }

    /// Text selected in the system-focused element, or nil if none
    /// (or AX not granted, or focused element doesn't expose
    /// selected-text). Cheap synchronous AX lookup — safe to call
    /// from the launcher hot path (button-down callback).
    ///
    /// The selection lives on the *focused* element, which is often
    /// in a window different from the cursor-anchored target — e.g.
    /// the user selects in window A then middle-clicks over window B
    /// to act on that selection. Returning the focused element's
    /// selection matches that mental model. (Cursor-anchored
    /// targeting still applies to the *action's* destination — only
    /// the `$SELECTION` payload comes from the focused element.)
    public static func selectedText() -> String? {
        let sys = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(
                sys, kAXFocusedUIElementAttribute as CFString, &focused)
                == .success,
              let elem = focused
        else { return nil }
        let axElem = elem as! AXUIElement
        var text: AnyObject?
        guard AXUIElementCopyAttributeValue(
                axElem, kAXSelectedTextAttribute as CFString, &text)
                == .success,
              let s = text as? String,
              !s.isEmpty
        else { return nil }
        return s
    }

    /// Ensure Accessibility is granted; prompt the user if not.
    /// Called once from `Main` at server startup. Mirrors facet's
    /// `AX.ensureTrusted()`.
    public static func ensureTrusted() {
        // String-literal key sidesteps Swift 6's strict-concurrency
        // diagnostic on the C global `kAXTrustedCheckOptionPrompt`
        // (same workaround facet uses in AXFocus.swift).
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            FileHandle.standardError.write(Data(
                "wand: grant Accessibility, then relaunch.\n".utf8))
            Log.line("AX: not yet trusted — opening System Settings → "
                     + "Privacy & Security → Accessibility")
            // Jump the user straight to the right pane instead of
            // making them navigate. macOS 13+ deep link; no-op (just
            // the prompt above) if the URL scheme ever changes.
            if let url = URL(string: "x-apple.systempreferences:"
                + "com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }


    private struct SideKey: Hashable {
        let pid: Int32
        let windowID: UInt32
    }

    /// (key, element) pairs ordered least-recently-touched first.
    /// `register` removes any existing entry for the key and appends,
    /// so re-touching a key moves it to the tail; eviction drops from
    /// the front — i.e. LRU, capped at `maxLive`. Strokes happen at
    /// most a few times per second, so 64 covers many seconds of
    /// history and the O(n) scan over a 64-element array is free.
    private nonisolated(unsafe) static var liveElements: [(SideKey, AXUIElement)] = []
    private static let maxLive = 64

    private static func register(_ element: AXUIElement, for target: Target) {
        let key = SideKey(pid: target.pid, windowID: target.windowID)
        liveElements.removeAll { $0.0 == key }
        liveElements.append((key, element))
        if liveElements.count > maxLive {
            liveElements.removeFirst(liveElements.count - maxLive)
        }
    }


    /// AX round-trip budget — generous (a busy Chrome can take 50+ ms)
    /// but bounded so a hung app can't stall the event-tap thread.
    /// 0.25 s matches facet's setting.
    private static let axTimeout: Float = 0.25
    private static let maxWalkDepth = 16

    /// The system-wide AX element is a stable singleton — build it
    /// (and set the messaging timeout) once rather than per stroke.
    /// `nonisolated(unsafe)`: only touched from `resolveAt`, which
    /// runs on the main thread (event-tap callback), same invariant
    /// as `liveElements`.
    private nonisolated(unsafe) static let systemWide: AXUIElement = {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, axTimeout)
        return sys
    }()

    private static func walkToWindow(from start: AXUIElement) -> AXUIElement? {
        var current = start
        for _ in 0..<maxWalkDepth {
            if (string(current, kAXRoleAttribute)) == kAXWindowRole {
                return current
            }
            var parentVal: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(
                current, kAXParentAttribute as CFString, &parentVal)
            guard err == .success, let parent = parentVal else { return nil }
            // Defensive conditional cast: a malformed AX hierarchy
            // could return something that isn't an AXUIElement (rare
            // — sandboxed apps with broken AX bridging), and crashing
            // the daemon on it is worse than dropping the gesture.
            guard CFGetTypeID(parent) == AXUIElementGetTypeID() else {
                return nil
            }
            current = parent as! AXUIElement
        }
        return nil
    }

    private static func string(_ e: AXUIElement, _ attr: String) -> String? {
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            e, attr as CFString, &val) == .success else { return nil }
        return val as? String
    }

    private static func readFrame(_ window: AXUIElement) -> CGRect {
        var posVal: CFTypeRef?
        var sizeVal: CFTypeRef?
        AXUIElementCopyAttributeValue(
            window, kAXPositionAttribute as CFString, &posVal)
        AXUIElementCopyAttributeValue(
            window, kAXSizeAttribute as CFString, &sizeVal)
        var pos = CGPoint.zero
        var size = CGSize.zero
        // Type-guarded so a stub AX implementation that returns a
        // non-AXValue here (some sandboxed apps do) can't crash the
        // daemon — we just return a zero frame and continue.
        if let v = posVal, CFGetTypeID(v) == AXValueGetTypeID() {
            AXValueGetValue(v as! AXValue, .cgPoint, &pos)
        }
        if let v = sizeVal, CFGetTypeID(v) == AXValueGetTypeID() {
            AXValueGetValue(v as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: pos, size: size)
    }
}
