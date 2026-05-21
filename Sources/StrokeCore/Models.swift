// StrokeCore — backend-neutral domain types.
//
// The Adapter layer translates real mouse events into these; views
// (if any are ever added) and matching only see these. No AppKit, no
// CGEvent, no AXUIElement — see docs/architecture.md.

import CoreGraphics
import Foundation

// MARK: - Direction

/// Cardinal direction of a single stroke segment. Mirrors MacGesture's
/// `L U R D` alphabet so existing users can port their rule files
/// trivially. Scroll-axis directions (lowercase `u` / `d`) are not
/// recognised yet — see [README.md](README.md) M2+ roadmap.
public enum Direction: Character, Sendable, Hashable, CaseIterable {
    case left  = "L"
    case up    = "U"
    case right = "R"
    case down  = "D"
}

extension Array where Element == Direction {
    /// Canonical pattern string (e.g. `[.down, .right] → "DR"`).
    public var patternString: String {
        String(map { $0.rawValue })
    }
}

// MARK: - Trigger

/// Which mouse button (and optional modifier set) starts capturing a
/// stroke. Matches the `[trigger]` section of config.toml.
public struct Trigger: Sendable, Equatable {
    public enum Button: String, Sendable, CaseIterable {
        case right, middle, side1, side2
    }
    public let button: Button
    /// Required modifier keys at the moment the button goes down.
    /// Empty set = no modifier required.
    public let modifiers: Set<Modifier>
    public init(button: Button, modifiers: Set<Modifier> = []) {
        self.button = button
        self.modifiers = modifiers
    }
}

public enum Modifier: String, Sendable, Hashable, CaseIterable {
    case cmd, opt, ctrl, shift, fn
}

// MARK: - Rule + Action

/// One row in `[[rules]]`. Matches if `pattern` equals the recognised
/// direction string AND `apps` matches the **cursor-anchored target**
/// window's bundle id (NOT the focused app — see issue #115 in
/// README).
public struct Rule: Sendable, Equatable {
    public let name: String
    public let pattern: String
    /// Bundle-id glob list. Wildcards `*` and `?` supported.
    /// `["*"]` (or empty) matches every app. Entries starting with
    /// `!` exclude (e.g. `!com.apple.dt.Xcode`).
    public let apps: [String]
    public let action: Action

    public init(name: String, pattern: String, apps: [String], action: Action) {
        self.name = name
        self.pattern = pattern
        self.apps = apps
        self.action = action
    }
}

/// What to do when a rule matches. The dispatcher (in
/// StrokeAdapterMacOS) executes each variant against the
/// cursor-anchored target window captured at stroke start.
public enum Action: Sendable, Equatable {
    /// Synthesize a keyboard shortcut. The target is raised first
    /// so the keystroke lands on the right window.
    /// Example: `cmd+w`, `cmd+shift+t`.
    case key(String)
    /// Invoke an AX action on the target window directly (no focus
    /// switch needed). `verb` ∈ close | minimize | zoom | raise.
    case ax(String)
    /// Run a shell command. The dispatcher injects environment
    /// variables identifying the target window:
    ///   STROKE_TARGET_BUNDLE_ID, STROKE_TARGET_PID,
    ///   STROKE_TARGET_TITLE, STROKE_TARGET_FRAME.
    case shell(String)
}

// MARK: - Stroke sample

/// One mouse position sample captured during gesture recording.
/// `t` is seconds since the stroke started (NOT wall-clock) so
/// recognition is reproducible from a fixture.
public struct Sample: Sendable, Equatable {
    public let p: CGPoint
    public let t: TimeInterval
    public init(p: CGPoint, t: TimeInterval) {
        self.p = p
        self.t = t
    }
}

// MARK: - Target

/// The window the stroke is acting on, resolved by the adapter at
/// stroke *start* (button-down) via AXUIElementCopyElementAtPosition.
/// Stored as plain data so Core can reason about app filtering
/// without depending on AX types.
///
/// This is the spine of the issue #115 fix: actions always dispatch
/// to this target, never to the currently-focused window at
/// stroke-end time.
public struct Target: Sendable, Equatable {
    public let pid: Int32
    public let bundleID: String
    public let title: String
    public let frame: CGRect
    /// CGWindowID of the resolved window (0 when unknown — e.g. the
    /// M1/M2 stub returned a pid-only target). Used as the side-table
    /// key in the adapter to map this value-type back to a live
    /// `AXUIElement` at action-dispatch time. Stored as `UInt32` so
    /// Core can carry it around without depending on CoreGraphics's
    /// `CGWindowID` typedef.
    public let windowID: UInt32
    public init(pid: Int32, bundleID: String, title: String,
                frame: CGRect, windowID: UInt32 = 0) {
        self.pid = pid
        self.bundleID = bundleID
        self.title = title
        self.frame = frame
        self.windowID = windowID
    }
}
