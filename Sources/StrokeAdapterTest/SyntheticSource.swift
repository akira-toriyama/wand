// Synthetic MouseSource for end-to-end pipeline tests.
//
// Lets a unit test feed a hand-built `[Sample]` (plus a fake Target)
// into the same recognition + matching path the real adapter uses,
// without needing a CGEventTap or AX permission. Also useful as the
// driver behind `stroke --record`'s "play back the saved fixture and
// show what would be recognised" mode.

import CoreGraphics
import Foundation
import StrokeCore

public final class SyntheticMouseSource: MouseSource, @unchecked Sendable {

    private var queued: [StrokeEvent] = []
    private var handler: (@Sendable (StrokeEvent) -> Void)?

    public init() {}

    /// Enqueue one stroke to be delivered on the next `flush()`.
    public func enqueue(target: Target, samples: [Sample]) {
        queued.append(StrokeEvent(target: target, samples: samples))
    }

    public func start(_ handler: @escaping @Sendable (StrokeEvent) -> Void) {
        self.handler = handler
    }

    public func stop() { handler = nil }

    /// Deliver every queued stroke synchronously. Returns the count
    /// delivered.
    @discardableResult
    public func flush() -> Int {
        guard let h = handler else { return 0 }
        let batch = queued; queued.removeAll(keepingCapacity: true)
        for e in batch { h(e) }
        return batch.count
    }
}
