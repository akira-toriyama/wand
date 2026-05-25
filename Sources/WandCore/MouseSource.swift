// The seam that lets the Controller see strokes without knowing
// about CGEventTap. Real impl: MacOSMouseSource. Test impl:
// SyntheticMouseSource (fixture-driven). Target is captured at
// button-down — that's the cursor-anchored guarantee.

import Foundation

public struct WandEvent: Sendable {
    public let target: Target
    public let samples: [Sample]
    public init(target: Target, samples: [Sample]) {
        self.target = target
        self.samples = samples
    }
}

public protocol MouseSource: AnyObject, Sendable {
    /// `handler` runs on the implementation's chosen queue —
    /// MacOSMouseSource fires on the event-tap main-thread callback.
    func start(_ handler: @escaping @Sendable (WandEvent) -> Void)
    func stop()
    /// Hot-apply `[recognition]` timing knobs without reinstalling the
    /// event tap. Implementations that can swap fields in place do so;
    /// the synthetic test source uses the default no-op since fixtures
    /// supply their own samples and don't read the live config.
    func updateConfig(_ cfg: WandConfig)
}

public extension MouseSource {
    func updateConfig(_ cfg: WandConfig) {}   // default: no-op
}

/// One launcher trigger fire: the button-down screen point plus the
/// resolved cursor-anchored target. Same `Target` value-type the
/// gesture path uses, so dispatch is trigger-agnostic.
public struct LauncherEvent: Sendable {
    public let point: CGPoint              // CG global coords, Y-down
    public let target: Target
    public init(point: CGPoint, target: Target) {
        self.point = point
        self.target = target
    }
}

/// Sibling of `MouseSource` for the launcher trigger. Real impl
/// installs its own CGEventTap masking the configured button only.
/// `handler` fires once per qualifying button-down with the target
/// resolved at that moment — same cursor-anchored guarantee.
public protocol LauncherSource: AnyObject, Sendable {
    func start(_ handler: @escaping @Sendable (LauncherEvent) -> Void)
    func stop()
    /// Hot-apply launcher-side knobs without reinstalling the tap.
    /// The tap's event mask is baked at install time, so a `[launcher].
    /// trigger` change still needs a restart — caller surfaces that.
    func updateConfig(_ cfg: WandConfig)
}

public extension LauncherSource {
    func updateConfig(_ cfg: WandConfig) {}
}
