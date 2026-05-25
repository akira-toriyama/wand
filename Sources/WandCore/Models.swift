import CoreGraphics
import Foundation

/// `L U R D` is single-letter on purpose: grep-friendly in logs and
/// easy to type in TOML. Scroll-axis directions are not recognised yet.
public enum Direction: Character, Sendable, Hashable, CaseIterable {
    case left  = "L"
    case up    = "U"
    case right = "R"
    case down  = "D"
}

extension Array where Element == Direction {
    public var patternString: String {
        String(map { $0.rawValue })
    }
}

extension Direction {
    public var arrow: String {
        switch self {
        case .left:  return "←"
        case .up:    return "↑"
        case .right: return "→"
        case .down:  return "↓"
        }
    }
}

extension Array where Element == Sample {
    /// Largest absolute displacement from the first sample on each
    /// axis. Diagnostic for "why was nothing recognised" — a tiny
    /// span means the user barely moved.
    public var span: (dx: CGFloat, dy: CGFloat) {
        guard let first = first else { return (0, 0) }
        var dx: CGFloat = 0, dy: CGFloat = 0
        for s in self {
            dx = Swift.max(dx, abs(s.p.x - first.p.x))
            dy = Swift.max(dy, abs(s.p.y - first.p.y))
        }
        return (dx, dy)
    }
}

public struct Trigger: Sendable, Equatable {
    public enum Button: String, Sendable, CaseIterable {
        case right, middle, side1, side2
    }
    public let button: Button
    public let modifiers: Set<Modifier>
    public init(button: Button, modifiers: Set<Modifier> = []) {
        self.button = button
        self.modifiers = modifiers
    }
}

public enum Modifier: String, Sendable, Hashable, CaseIterable {
    case cmd, opt, ctrl, shift, fn
}

/// One row in `[[rules]]`. `apps` matches the **cursor-anchored
/// target** window's bundle id, not the focused app — the whole point
/// of the project. Wildcards `*` / `?`; entries starting with `!`
/// exclude (e.g. `!com.apple.dt.Xcode`).
public struct Rule: Sendable, Equatable {
    public let name: String
    public let pattern: String
    public let apps: [String]
    public let action: Action

    public init(name: String, pattern: String, apps: [String], action: Action) {
        self.name = name
        self.pattern = pattern
        self.apps = apps
        self.action = action
    }
}

public enum Action: Sendable, Equatable {
    case key(String)        // e.g. `cmd+w`; the target is raised first
    case ax(String)         // `verb` ∈ axVerbs (no focus switch)
    case shell(String)      // env: STROKE_TARGET_BUNDLE_ID / PID / TITLE / FRAME
    case url(String)        // open via NSWorkspace — handles https / file / custom schemes

    /// Source of truth shared by config validation (a typo drops the
    /// rule at load) and the dispatcher's switch — drift between the
    /// two would silently load no-op rules.
    public static let axVerbs: Set<String> = ["close", "minimize", "zoom", "raise"]
}

/// `t` is seconds since stroke start (NOT wall-clock) so recognition
/// is reproducible from a fixture.
public struct Sample: Sendable, Equatable {
    public let p: CGPoint
    public let t: TimeInterval
    public init(p: CGPoint, t: TimeInterval) {
        self.p = p
        self.t = t
    }
}

/// Exit-animation kind for the assist cards in the gesture overlay.
/// Raw values match the `[effect]` strings in `config.toml` so the
/// parser is a one-liner. `.random` is a selector — the adapter
/// resolves it to one of the renderable cases per card at queue time.
public enum Effect: String, Sendable, Hashable, CaseIterable {
    case none
    case drop
    case rise
    case slideLeft = "slide-left"
    case slideRight = "slide-right"
    case explode
    case vibrate
    case fade
    case fireworks
    case confetti
    case random

    /// How long the animation runs before the card is pruned. `.none`
    /// and `.random` are nonsensical here (the adapter resolves the
    /// latter first); 0 is just a placeholder so the switch stays
    /// exhaustive.
    public var duration: TimeInterval {
        switch self {
        case .none, .random:         return 0
        case .vibrate:               return 0.45
        case .fireworks, .confetti:  return 0.9
        default:                     return 0.35
        }
    }

    /// Pool that `.random` chooses from — every concrete renderable
    /// effect, excluding `.none` and the selector itself.
    public static let randomPool: [Effect] =
        Effect.allCases.filter { $0 != .none && $0 != .random }
}

/// Overall size of the chosen `Effect`s. Multiplier is read by the
/// adapter to scale translation distance, scale delta, vibration
/// amplitude, and particle birth-rate / velocity. Lives in Core so the
/// parsing layer can store a typed value instead of a raw string.
public enum Intensity: String, Sendable, Hashable, CaseIterable {
    case subtle
    case normal
    case bold
    case wild

    public var multiplier: CGFloat {
        switch self {
        case .subtle: return 0.6
        case .normal: return 1.0
        case .bold:   return 1.6
        case .wild:   return 2.5
        }
    }
}

/// The window the stroke acts on. Resolved at *button-down* time —
/// actions dispatch to **this** window, never to whichever has focus
/// at button-up. Plain data so Core stays free of AX types.
public struct Target: Sendable, Equatable {
    public let pid: Int32
    public let bundleID: String
    public let title: String
    public let frame: CGRect
    /// CGWindowID of the resolved window (0 when the window couldn't
    /// be resolved). Used as the side-table key in the adapter to map
    /// this value-type back to a live `AXUIElement` at action-dispatch
    /// time. Stored as `UInt32` so Core can carry it around without
    /// depending on CoreGraphics's `CGWindowID` typedef.
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
