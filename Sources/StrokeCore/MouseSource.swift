// The seam that lets the Controller see strokes without knowing
// about CGEventTap. Real impl: MacOSMouseSource. Test impl:
// SyntheticMouseSource (fixture-driven). Target is captured at
// button-down — that's the cursor-anchored guarantee.

import Foundation

public struct StrokeEvent: Sendable {
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
    func start(_ handler: @escaping @Sendable (StrokeEvent) -> Void)
    func stop()
    /// Hot-apply `[recognition]` timing knobs without reinstalling the
    /// event tap. Implementations that can swap fields in place do so;
    /// the synthetic test source uses the default no-op since fixtures
    /// supply their own samples and don't read the live config.
    func updateConfig(_ cfg: StrokeConfig)
}

public extension MouseSource {
    func updateConfig(_ cfg: StrokeConfig) {}   // default: no-op
}
