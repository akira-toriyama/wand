#!/usr/bin/swift
//
// Generate Stroke.icns from scratch using CoreGraphics — no external
// art tools required. Renders the icon at the 10 sizes macOS expects in
// an .iconset directory, then `iconutil -c icns` rolls it up. Run from
// the repo root via `scripts/make-icon.sh` (or directly: `swift run`).
//
// Design: a flowing "down → right" stroke (the canonical DR gesture
// shape, mirroring what the daemon recognises) painted in white on a
// blue squircle. The blue matches the overlay's match color so the
// app icon and the live trail share an identity.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Output sizes
// Standard macOS .iconset members. Listing both the 1x and the @2x
// physical size lets iconutil pick the right entry on every display.
let sizes: [(label: String, dim: Int)] = [
    ("16x16",      16),
    ("16x16@2x",   32),
    ("32x32",      32),
    ("32x32@2x",   64),
    ("128x128",   128),
    ("128x128@2x", 256),
    ("256x256",   256),
    ("256x256@2x", 512),
    ("512x512",   512),
    ("512x512@2x", 1024),
]

// MARK: - Colors
// Top → bottom blue gradient. The top is the overlay's match color
// (#3b82f6 from [overlay].color); the bottom is a darker shade of the
// same hue (#1d4ed8) so the gradient reads as depth, not a second color.
private let bgTop    = CGColor(srgbRed: 0x3b/255, green: 0x82/255, blue: 0xf6/255, alpha: 1)
private let bgBottom = CGColor(srgbRed: 0x1d/255, green: 0x4e/255, blue: 0xd8/255, alpha: 1)
private let strokeFG = CGColor(srgbRed: 1,        green: 1,        blue: 1,        alpha: 1)

// MARK: - Rendering

/// Render the icon at `side` × `side` px and return a CGImage.
func render(side dim: CGFloat) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: Int(dim), height: Int(dim),
        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("CGContext alloc failed at \(dim)") }

    // Squircle background. The corner-radius ratio matches Apple's
    // own app-icon template (≈22.37% of the side). A "true" squircle
    // would be a superellipse; the rounded rect is visually close and
    // a single API call.
    let rect = CGRect(x: 0, y: 0, width: dim, height: dim)
    let r = dim * 0.2237
    let bgPath = CGPath(roundedRect: rect, cornerWidth: r,
                        cornerHeight: r, transform: nil)
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: cs,
        colors: [bgTop, bgBottom] as CFArray,
        locations: [0, 1]
    )!
    // CGContext bitmaps are Y-up: start the gradient at the *top*
    // (y == dim) and walk down to y == 0.
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: dim),
        end:   CGPoint(x: 0, y: 0),
        options: [])
    ctx.restoreGState()

    // Foreground stroke: a chunky white "down then right" path. All
    // coordinates are fractions of `dim` so the icon scales cleanly
    // across the 10 sizes without per-size hand-tuning.
    let lineWidth = dim * 0.085
    ctx.setStrokeColor(strokeFG)
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // Y-up: bigger Y = visually higher. "down → right" therefore goes
    // from a high Y to a low Y, with the right turn at the bottom.
    let startX   = dim * 0.30
    let startY   = dim * 0.78
    let cornerY  = dim * 0.36
    let endX     = dim * 0.78
    let endY     = dim * 0.36

    let path = CGMutablePath()
    path.move(to: CGPoint(x: startX, y: startY))
    // Vertical segment of the D-stroke. Stop short of the actual
    // corner so the curve below can ease into the turn.
    path.addLine(to: CGPoint(x: startX, y: cornerY + dim * 0.10))
    // Smooth 90° turn from "down" to "right" via a quad-bezier with
    // its control at the geometric corner — gives a perfectly round
    // L-shape without visible kinks.
    path.addQuadCurve(
        to: CGPoint(x: startX + dim * 0.10, y: cornerY),
        control: CGPoint(x: startX, y: cornerY))
    // Right segment, stopping short of the arrowhead so the head's
    // line caps don't overlap a continuing stem.
    path.addLine(to: CGPoint(x: endX - dim * 0.04, y: endY))
    ctx.addPath(path)
    ctx.strokePath()

    // Arrowhead at the right end. Two short strokes form the ">":
    // tip at (endX, endY), wings sweep back-left into the stem.
    let head = CGMutablePath()
    let wing  = dim * 0.13
    let wingY = dim * 0.085
    head.move(to: CGPoint(x: endX - wing, y: endY + wingY))
    head.addLine(to: CGPoint(x: endX,       y: endY))
    head.addLine(to: CGPoint(x: endX - wing, y: endY - wingY))
    ctx.addPath(head)
    ctx.strokePath()

    guard let image = ctx.makeImage() else {
        fatalError("makeImage failed at \(dim)")
    }
    return image
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
    }
    try data.write(to: url)
}

// MARK: - main

let fm = FileManager.default
let iconset = "Stroke.iconset"
try? fm.removeItem(atPath: iconset)
try fm.createDirectory(atPath: iconset,
                       withIntermediateDirectories: true)

for (label, dim) in sizes {
    let image = render(side: CGFloat(dim))
    let path = "\(iconset)/icon_\(label).png"
    try writePNG(image, to: URL(fileURLWithPath: path))
    print("  ✓ \(label.padding(toLength: 12, withPad: " ", startingAt: 0)) → \(path) (\(dim)px)")
}

print("\nwrote \(iconset) — run `iconutil -c icns \(iconset) -o Stroke.icns` to package")
