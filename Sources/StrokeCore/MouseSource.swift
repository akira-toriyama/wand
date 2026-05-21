// Protocol seam between Core and the Adapter layer.
//
// `MouseSource` lets the Controller subscribe to mouse strokes
// without depending on CGEventTap (the real adapter) or knowing
// anything about Quartz event types. The Test adapter provides a
// canned implementation for unit-level end-to-end recognition tests.
//
// One stroke = (target captured at button-down) + (sample stream
// while button is held) + (button-up triggers delivery). The
// adapter is responsible for resolving the target via AX before
// streaming samples — that's the heart of the cursor-anchored
// design.

import Foundation

/// One complete stroke, ready for recognition + dispatch.
public struct StrokeEvent: Sendable {
    public let target: Target
    public let samples: [Sample]
    public init(target: Target, samples: [Sample]) {
        self.target = target
        self.samples = samples
    }
}

/// Source of completed strokes. Implementations:
///
///   - `StrokeAdapterMacOS.MacOSMouseSource` — real CGEventTap.
///   - `StrokeAdapterTest.SyntheticMouseSource` — fixture-driven
///     for tests / `stroke --record` replay.
public protocol MouseSource: AnyObject, Sendable {
    /// Begin observing. `handler` runs on the dispatcher's chosen
    /// queue; implementations document their threading.
    func start(_ handler: @escaping @Sendable (StrokeEvent) -> Void)
    /// Stop observing and release resources.
    func stop()
}
