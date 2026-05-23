// Cursor-anchored window targeting — the spine of the project.
//
// At stroke *start* (button-down) we resolve which window sits under
// the cursor and freeze that as the stroke's target. Actions later
// dispatch to *that* window regardless of which app gains focus
// while the user is drawing.
//
// Pipeline:
//
//   1. systemWide = AXUIElementCreateSystemWide()
//   2. AXUIElementCopyElementAtPosition(systemWide, x, y, &elt)
//   3. Walk `elt`'s parent chain via kAXParentAttribute until role
//      is kAXWindowRole — that's the window.
//   4. Read kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute.
//   5. Resolve pid via AXUIElementGetPid; bundle id via
//      NSRunningApplication(processIdentifier:).
//   6. Look up CGWindowID via the private `_AXUIElementGetWindow`
//      (same dlsym trick facet's AX module uses).
//   7. Stash the live `AXUIElement` in `liveElements` keyed by
//      (pid, windowID) so `Dispatch.runAX` can find it later. Return
//      the pure-data `Target`.
//
// Threading: every call happens on the main thread — the CGEventTap
// callback in EventTap.swift runs on `CFRunLoopGetMain()` and the
// Controller's handler invokes resolveAt synchronously from there.
// No locking needed on `liveElements`.

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import StrokeCore

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

    // MARK: - Resolution

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
        if err == .success, let element = hit,
           let window = walkToWindow(from: element) {
            return finalize(window: window, point: point, via: "ax-walk")
        }

        // Fallback: Chrome (and any multi-process renderer) sometimes
        // returns an element whose parent chain doesn't reach a window —
        // the cursor was on page content drawn by a helper process, so
        // the AX hierarchy is orphaned from the browser-process window.
        // Look the on-screen window up by frame via CGWindowList and
        // re-acquire its AX peer from the owning app.
        if let (window, _) = windowAtPointViaCG(point: point) {
            return finalize(window: window, point: point, via: "cg-window")
        }

        Log.debug("AX: no kAXWindowRole in parent chain at \(point) "
                  + "and no on-screen window found there — "
                  + "likely menu bar / desktop / Dock")
        return nil
    }

    /// Read the metadata off `window`, register it for `.ax` dispatch,
    /// and log how we found it. Shared by the direct AX-walk path and
    /// the CGWindowList fallback so they record identical Targets.
    private static func finalize(window: AXUIElement,
                                  point: CGPoint, via: String) -> Target {
        AXUIElementSetMessagingTimeout(window, axTimeout)
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
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
        return liveElements.first(where: { $0.0 == key })?.1
    }

    // MARK: - AX permission prompt

    /// Current trust state, without prompting — for `stroke --doctor`.
    public static func isTrusted() -> Bool { AXIsProcessTrusted() }

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
                "stroke: grant Accessibility, then relaunch.\n".utf8))
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

    // MARK: - Side-table (live AXUIElements keyed by pid+windowID)

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

    // MARK: - AX helpers

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
        if let v = posVal {
            AXValueGetValue(v as! AXValue, .cgPoint, &pos)
        }
        if let v = sizeVal {
            AXValueGetValue(v as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: pos, size: size)
    }
}
