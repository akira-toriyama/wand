// Shared icon-spec → NSImage resolver. Used by:
//   - The tome panel (`[[tome.item]].icon` on every row)
//   - The cast HUD assist cards (`[[cast.rule]].icon` on each row)
// Keeping the parser in one place means the same syntax works on both
// surfaces (SF:<name> / emoji / file paths / app:<bundle-id>).

import AppKit
import WandCore

/// Stateless icon resolver. Every call is independent — no per-row
/// caching beyond what `AppIconCache` already provides for the
/// `app:<bundle-id>` form.
@MainActor
enum IconResolver {

    /// Baseline (font-size 13) icon render size in points. SF Symbols
    /// use this as their `pointSize` with `.medium` weight + `.large`
    /// scale so glyphs fill their bounding box optically — without
    /// `.large` scale, whitespace-heavy symbols (gear, camera, folder)
    /// read as smaller than tight ones (lock, magnifying glass).
    static let baselinePt: CGFloat = 17

    /// Per-call scaled equivalent of `baselinePt`. Callers that have
    /// a live row's font size pass it in so the icon column scales
    /// with the rest of the row.
    static func pt(forFontSize fontSize: Int) -> CGFloat {
        round(baselinePt * CGFloat(fontSize) / 13.0)
    }

    /// Resolve `spec` to a rendered `NSImage`. Returns `nil` on miss
    /// (which collapses to no image in the caller's row); logs once so
    /// a typo is visible in `/tmp/wand.log` without spamming every
    /// repaint. Recognised forms:
    ///   - `""` (empty) — no icon (callers usually skip this branch)
    ///   - `"app:<bundle-id>"` — installed app icon via `AppIconCache`
    ///   - `"SF:<name>"` — SF Symbol (macOS 11+) with optional `tint`
    ///                     (`hierarchicalColor`) or `tintColors`
    ///                     (multi-colour palette)
    ///   - absolute / `~` / config-relative file path
    ///   - anything else — drawn as a text/emoji glyph (1-2 chars
    ///                     typical), optionally backed by a soft chip
    static func resolve(_ spec: String,
                        fontSize: Int,
                        tint: String = "",
                        tintColor: NSColor? = nil,
                        tintColors: [String] = [],
                        iconChip: Bool = false) -> NSImage? {
        let pt = pt(forFontSize: fontSize)
        return resolve(spec, pointSize: pt,
                       tint: tint, tintColor: tintColor,
                       tintColors: tintColors,
                       iconChip: iconChip)
    }

    /// Lower-level entry point for callers that already have a target
    /// point size (the cast HUD measures its icon column off the
    /// card's font size, not the tome row's). `tintColor` overrides
    /// `tint` / `tintColors` when set — used by callers that have a
    /// live NSColor (e.g. the cast HUD's per-frame card text colour)
    /// rather than a config-string spec.
    static func resolve(_ spec: String,
                        pointSize pt: CGFloat,
                        tint: String = "",
                        tintColor: NSColor? = nil,
                        tintColors: [String] = [],
                        iconChip: Bool = false) -> NSImage? {
        if spec.hasPrefix("app:") {
            let bid = String(spec.dropFirst(4))
            let (_, img) = AppIconCache.shared.lookup(
                bundleID: bid, iconSize: pt)
            if img == nil {
                Log.line("icon-resolver: no installed app for "
                         + "\"\(bid)\" — falling back to no icon")
            }
            return img
        }

        if IconSetCache.matches(spec) {
            // External icon-set hit (lucide / phosphor / tabler /
            // heroicons). Cached hits render immediately; misses
            // fall through to a generic SF Symbol placeholder and
            // the calling row kicks the async download. Sized via
            // `image.size` so the SVG-decoded NSImage matches the
            // surrounding column's footprint.
            //
            // `tintColor` path: the cached SVG carries `isTemplate =
            // true` so AppKit can auto-tint it inside an NSImageView
            // (tome panel). NSTextAttachment doesn't apply that auto-
            // tint, so for callers that hand us a live colour (cast
            // HUD card text) we bake the tint into a raster copy.
            // Without this the icon would render fully transparent
            // inside the card — phantom whitespace where a glyph
            // should be.
            if let img = IconSetCache.shared.cached(spec: spec) {
                img.size = NSSize(width: pt, height: pt)
                if let tintColor = tintColor {
                    return tintedRaster(img, pointSize: pt,
                                          color: tintColor)
                }
                return img
            }
            var cfg = NSImage.SymbolConfiguration(
                pointSize: pt, weight: .medium, scale: .large)
            if let tintColor = tintColor {
                cfg = cfg.applying(
                    NSImage.SymbolConfiguration(paletteColors: [tintColor]))
            }
            return NSImage(systemSymbolName: "square.dashed",
                            accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg)
        }

        if spec.hasPrefix("favicon:") {
            // Cache hit returns the site icon immediately; misses fall
            // through to the `SF:globe` placeholder below and the
            // calling row kicks the async fetch. Sizing matches the
            // surrounding column so the rendered NSImage lands at the
            // same footprint as an `app:` or SF Symbol icon.
            //
            // Real favicons are full-colour PNGs (no `isTemplate`),
            // so they render fine through NSTextAttachment without
            // any tint baking. Only the SF Symbol placeholder needs
            // the same `paletteColors` trick the `SF:` branch uses
            // to stay visible in a card.
            if let host = FaviconCache.host(from: spec),
               let img = FaviconCache.shared.cached(host: host) {
                img.size = NSSize(width: pt, height: pt)
                return img
            }
            // Placeholder — same SF:globe the row will keep showing
            // when the fetch fails. Built here (rather than via the
            // SF: branch) so the favicon-specific resize is applied
            // consistently with the eventual real favicon.
            var cfg = NSImage.SymbolConfiguration(
                pointSize: pt, weight: .medium, scale: .large)
            if let tintColor = tintColor {
                cfg = cfg.applying(
                    NSImage.SymbolConfiguration(paletteColors: [tintColor]))
            }
            return NSImage(systemSymbolName: "globe",
                            accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg)
        }

        if spec.hasPrefix("SF:") {
            let name = String(spec.dropFirst(3))
            var cfg = NSImage.SymbolConfiguration(
                pointSize: pt, weight: .medium, scale: .large)
            // Live `NSColor` wins outright — callers using it know the
            // exact frame colour (e.g. dynamic-mode trail / card text)
            // and the resolved hex would only round-trip lossily.
            // Applied via `paletteColors` so the resulting image
            // carries its tint as raster pixels rather than as a
            // template that needs a foreground at draw time — this is
            // what makes the icon visible inside `NSTextAttachment`,
            // which doesn't apply text-foreground to template images.
            if let tintColor = tintColor {
                cfg = cfg.applying(
                    NSImage.SymbolConfiguration(paletteColors: [tintColor]))
            } else if !tintColors.isEmpty {
                let resolved: [NSColor] = tintColors.compactMap { spec in
                    if let c = NSColorParse.nsColor(spec) { return c }
                    Log.line("icon-resolver: unknown tint-colors entry "
                             + "\"\(spec)\" on SF Symbol — skipped")
                    return nil
                }
                if !resolved.isEmpty {
                    cfg = cfg.applying(
                        NSImage.SymbolConfiguration(paletteColors: resolved))
                }
            } else if !tint.isEmpty {
                if let c = NSColorParse.nsColor(tint) {
                    cfg = cfg.applying(
                        NSImage.SymbolConfiguration(hierarchicalColor: c))
                } else {
                    Log.line("icon-resolver: unknown tint \"\(tint)\" "
                             + "on SF Symbol — falling back to no tint")
                }
            }
            guard let img = NSImage(systemSymbolName: name,
                                     accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) else {
                Log.line("icon-resolver: unknown SF Symbol \"\(name)\" "
                         + "in item icon — falling back to no icon")
                return nil
            }
            return img
        }

        let looksLikePath = spec.hasPrefix("/")
            || spec.hasPrefix("~")
            || spec.contains("/")
            || spec.hasSuffix(".png")
            || spec.hasSuffix(".jpg")
            || spec.hasSuffix(".jpeg")
            || spec.hasSuffix(".gif")
            || spec.hasSuffix(".tiff")
            || spec.hasSuffix(".icns")
        if looksLikePath {
            let path = resolvePath(spec)
            guard let img = NSImage(contentsOfFile: path) else {
                Log.line("icon-resolver: could not load item icon "
                         + "from \(path) — falling back to no icon")
                return nil
            }
            img.size = NSSize(width: pt, height: pt)
            return img
        }

        return textIcon(spec, pointSize: pt, chip: iconChip)
    }

    /// Bake `color` into a template raster image (lucide / phosphor /
    /// tabler / heroicons — anything `IconSetCache` returns flagged
    /// `isTemplate = true`). Returns a fresh, non-template NSImage
    /// sized to the requested pt box.
    ///
    /// Needed for callers that place the icon inside an
    /// `NSTextAttachment` (cast HUD card text): AppKit's auto-tint
    /// path only applies to template images drawn through an
    /// NSImageView / NSButton / NSMenuItem, not through an attachment,
    /// so without this step the icon renders fully transparent and
    /// the column collapses to a phantom whitespace.
    ///
    /// Tome panel callers don't hit this path — they pass
    /// `tintColor == nil` and let the row's NSImageView auto-tint the
    /// template image based on hover state, which is the correct
    /// behaviour there (the icon needs to flip colour on hover).
    private static func tintedRaster(_ template: NSImage,
                                      pointSize pt: CGFloat,
                                      color: NSColor) -> NSImage {
        let size = NSSize(width: pt, height: pt)
        // Resolve dynamic colours (e.g. `NSColor.labelColor`) against
        // the user's effective appearance BEFORE we step into
        // `lockFocus`. Inside a fresh NSImage's drawing context
        // `NSAppearance.current` is unset and the daemon — being
        // `LSUIElement` without a key window — defaults to the system
        // (usually light) appearance for colour resolution. The
        // result is an almost-black tint baked into the raster, which
        // then disappears against the cast card's dark backdrop. The
        // cast HUD overlay window already runs in `darkAqua` so its
        // glyphs and labels look the same regardless of system
        // appearance; matching that here keeps the icon visible
        // alongside them.
        let appearance = NSAppearance(named: .darkAqua)
            ?? NSApp.effectiveAppearance
        var resolved: NSColor = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.deviceRGB) ?? color
        }
        let baked = NSImage(size: size)
        baked.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        template.size = size
        template.draw(in: rect,
                      from: .zero,
                      operation: .sourceOver,
                      fraction: 1.0)
        resolved.set()
        rect.fill(using: .sourceAtop)
        baked.unlockFocus()
        return baked
    }

    private static func resolvePath(_ spec: String) -> String {
        if spec.hasPrefix("/") { return spec }
        if spec.hasPrefix("~") {
            return (spec as NSString).expandingTildeInPath
        }
        // Relative — resolve against the config file's directory.
        let configDir = (WandConfig.path as NSString)
            .deletingLastPathComponent
        return "\(configDir)/\(spec)"
    }

    private static func textIcon(_ text: String,
                                  pointSize pt: CGFloat,
                                  chip: Bool) -> NSImage? {
        // Shrink the glyph slightly when sitting on a chip so the
        // padding reads as deliberate rather than cramped.
        let fontSize: CGFloat = chip ? pt * 0.72 : pt * 0.85
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let measured = attributed.size()
        guard measured.width > 0 && measured.height > 0 else { return nil }
        let size = NSSize(width: pt, height: pt)
        let img = NSImage(size: size)
        img.lockFocus()
        if chip {
            // `quaternaryLabelColor` is the muted-grey baseline macOS
            // uses for filled chips — visible against vibrant blur but
            // soft enough not to compete with the row's title.
            let chipRect = NSRect(origin: .zero, size: size)
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: chipRect,
                          xRadius: pt * 0.28, yRadius: pt * 0.28).fill()
        }
        let origin = NSPoint(
            x: (size.width - measured.width) / 2,
            y: (size.height - measured.height) / 2)
        attributed.draw(at: origin)
        img.unlockFocus()
        return img
    }
}
