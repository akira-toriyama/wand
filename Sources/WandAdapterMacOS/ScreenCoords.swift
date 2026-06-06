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

public enum ScreenCoords {

    /// CG global (Y-down) → Cocoa global (Y-up). Used by every adapter
    /// that takes a `CGEvent.location` and needs to talk to AppKit
    /// (overlay window, launcher panel). Also re-used by the App
    /// layer when threading native-trigger CG coords into
    /// `LauncherPanel` (now Cocoa-only). Lives in one place so the
    /// CLAUDE.md-flagged Y-axis trap has a single definition.
    public static func cocoaPoint(fromCG cg: CGPoint) -> CGPoint {
        CGPoint(x: cg.x, y: primaryHeight(fallback: cg.y) - cg.y)
    }

    /// Cocoa global (Y-up) → CG global (Y-down). Symmetric companion
    /// to `cocoaPoint(fromCG:)`, used when feeding `NSEvent.mouseLocation`
    /// or any other AppKit-sourced point back into `CGEvent` /
    /// `CGWarpMouseCursorPosition`.
    public static func cgPoint(fromCocoa cocoa: CGPoint) -> CGPoint {
        CGPoint(x: cocoa.x, y: primaryHeight(fallback: cocoa.y) - cocoa.y)
    }

    private static func primaryHeight(fallback: CGFloat) -> CGFloat {
        NSScreen.screens
            .first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? fallback
    }
}
