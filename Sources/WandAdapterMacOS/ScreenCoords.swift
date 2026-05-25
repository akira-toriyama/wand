// CG ↔ Cocoa coordinate conversion. CGEvent reports Y-down with the
// origin at the top-left of the primary display; AppKit's
// NSScreen / NSWindow use Y-up with the origin at the bottom-left
// of the primary display. Flipping about the **primary screen's
// height** is correct for ALL displays — both coordinate systems
// are anchored to the primary, so a point above it (CG y < 0)
// maps to Cocoa y > primaryH and a point below maps to y < 0,
// exactly where a secondary display sits.

import AppKit
import CoreGraphics

enum ScreenCoords {

    /// CG global (Y-down) → Cocoa global (Y-up). Used by every adapter
    /// that takes a `CGEvent.location` and needs to talk to AppKit
    /// (overlay window, NSMenu popup). Lives in one place so the
    /// CLAUDE.md-flagged Y-axis trap has a single definition.
    static func cocoaPoint(fromCG cg: CGPoint) -> CGPoint {
        let primaryH = NSScreen.screens
            .first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? cg.y
        return CGPoint(x: cg.x, y: primaryH - cg.y)
    }
}
