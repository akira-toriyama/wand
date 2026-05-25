// Shared CG-event helpers for both `MacOSMouseSource` (gesture tap)
// and `MacOSLauncherSource` (launcher tap). Each tap installs its
// own `CGEventTap`, but the mapping between wand's `Trigger.Button`
// / `Modifier` model and CoreGraphics constants — event masks,
// button numbers, mouse-event types, modifier flag bits — was
// copy-pasted across both adapters. One source of truth here
// guarantees they can't drift (e.g. a future side-button 5 added
// in one place but forgotten in the other).

import CoreGraphics
import WandCore

extension Trigger.Button {

    /// Numeric button index reported in `mouseEventButtonNumber`.
    /// Lets `.otherMouseDown` callbacks distinguish middle / side1
    /// / side2 (which all share that CGEventType).
    var cgButtonNumber: Int64 {
        switch self {
        case .right:  return 1
        case .middle: return 2
        case .side1:  return 3
        case .side2:  return 4
        }
    }

    /// `(down, up)` CGEventType pair for this button. `.right`
    /// branches to `.rightMouse{Down,Up}`; everything else collapses
    /// to `.otherMouse{Down,Up}` (filter further by `cgButtonNumber`
    /// when you care about middle vs side).
    var downUpTypes: (down: CGEventType, up: CGEventType) {
        switch self {
        case .right:  return (.rightMouseDown, .rightMouseUp)
        default:      return (.otherMouseDown, .otherMouseUp)
        }
    }

    /// Down + up bitmask without movement events. Use for taps that
    /// only care about button transitions (the launcher); add the
    /// `.mouseMoved`/`.rightMouseDragged`/`.otherMouseDragged` bits
    /// at the call site if you need them (the gesture tap does).
    var downUpMask: CGEventMask {
        let (down, up) = downUpTypes
        return (1 << down.rawValue) | (1 << up.rawValue)
    }
}

/// Modifier flag mapping — kept alongside the button helpers since
/// every tap that filters events by modifier reaches for this.
public enum CGModifier {

    public static let allFlags: CGEventFlags = [
        .maskCommand, .maskAlternate, .maskControl,
        .maskShift, .maskSecondaryFn,
    ]

    private static let flagMap: [Modifier: CGEventFlags] = [
        .cmd:   .maskCommand,
        .opt:   .maskAlternate,
        .ctrl:  .maskControl,
        .shift: .maskShift,
        .fn:    .maskSecondaryFn,
    ]

    /// Bitwise OR of every flag in `set`. Suitable for precomputing
    /// `expectedFlags` once at install rather than rebuilding on
    /// every callback.
    public static func flags(_ set: Set<Modifier>) -> CGEventFlags {
        set.reduce([]) { acc, m in acc.union(flagMap[m] ?? []) }
    }
}

extension CGEvent {

    /// True when this event's modifier state (restricted to the
    /// wand-relevant flags — Caps Lock is intentionally ignored) is
    /// exactly `expected`. Pass `CGModifier.flags(trigger.modifiers)`
    /// as `expected`, precomputed at install time.
    func matches(expectedFlags expected: CGEventFlags) -> Bool {
        flags.intersection(CGModifier.allFlags) == expected
    }
}
