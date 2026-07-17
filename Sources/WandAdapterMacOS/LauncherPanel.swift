// The launcher UI surface. A non-activating NSPanel that does NOT
// take keyboard focus from the underlying app — the user keeps typing
// in their editor while picking an item with the mouse. Used for
// both the native middle-click trigger and the
// `wand tome --open` external trigger.
//
// Behaviour notes:
//   - No keyboard navigation (panel cannot become key by design);
//     Esc dismisses the whole tree.
//   - Submenus open as adjacent child panels on hover. The gap
//     between panels is zero so moving the cursor straight right
//     from the folder row into the child works reliably; the native
//     NSMenu diagonal-cursor tolerance is NOT reproduced — hovering
//     a non-folder row inside the parent closes the child.
//   - Dynamic items (`dynamic = "..."`) are rendered as a disabled
//     placeholder; expanding them as a child panel is future work.
//   - State markers (✓ / –) prefix the row title.
//
// Spec contract:
//   - `present(...)` returns **immediately** (unlike `NSMenu.popUp`,
//     which blocks). Callers must not assume synchronous selection.
//   - `onSelect` fires asynchronously on click and is followed by
//     the whole panel tree closing.
//   - Only one panel tree is visible at a time. A second
//     `present(...)` dismisses the first.
//
// File structure:
//   - `LauncherPanel`         — public entry (just `present(...)`)
//   - `PanelNode`             — tree node enum (item / folder)
//   - `PanelTree`             — flat `[LauncherItem]` → `[PanelNode]`
//   - `PanelLayout`           — builds content NSView, computes frames
//   - `PanelController`       — one panel level's lifecycle
//   - `NonActivatingPanel`    — NSPanel subclass that refuses key
//   - `RowKind` / `ItemRow`   — row view + its state machine

import AppKit
import Effects   // drawLinePets (shared line-pet drawing; re-exports Palette)
import Foundation
import Palette      // paletteFor — ThemeSpec source for the context menu
import PaletteKit   // resolve(ThemeSpec) → ResolvedPalette (ThemedMenu input)
import ThemeKitUI   // ThemedMenu — the row context menu (t-k4hf)
import WandCore

// MARK: - Static border colour

/// Per-kind stroke colour for non-animated `LauncherBorder` cases.
/// Lives in the adapter (Core stays AppKit-free). `.off` and
/// `.rainbow` are handled by their own code paths and never query
/// this — they trap with a clear message if the switch is ever
/// reached out-of-context.
extension LauncherBorder {
    @MainActor
    var staticColor: NSColor {
        switch self {
        case .terminal:  return NSColor(srgbRed: 0x22 / 255.0,
                                         green: 0xc5 / 255.0,
                                         blue:  0x5e / 255.0, alpha: 1)
        case .neon:      return NSColor(srgbRed: 0x22 / 255.0,
                                         green: 0xd3 / 255.0,
                                         blue:  0xee / 255.0, alpha: 1)
        case .splatoon:  return NSColor(srgbRed: 0xbf / 255.0,
                                         green: 0xff / 255.0,
                                         blue:  0x00 / 255.0, alpha: 1)
        case .mono:      return .white
        case .vapor:     return NSColor(srgbRed: 0xff / 255.0,
                                         green: 0x79 / 255.0,
                                         blue:  0xc6 / 255.0, alpha: 1)
        case .chomp:    return NSColor(srgbRed: 0xff / 255.0,
                                         green: 0xea / 255.0,
                                         blue:  0x00 / 255.0, alpha: 1)
        case .off, .rainbow:
            // Animated kinds (`.rainbow`) + the off case carry their
            // colour another way. Reaching here means the caller
            // used the wrong accessor — fall back loudly rather than
            // render a silent mystery colour.
            assertionFailure(
                "LauncherBorder.staticColor accessed for \(self)")
            return .controlAccentColor
        }
    }
}

// MARK: - Theme

/// Resolved theme colours for the panel. Each field is `nil` when the
/// corresponding `TomeThemePalette` slot was empty (or its colour
/// string didn't parse), in which case the row/panel falls back to
/// the system semantic colour. Adapter-layer mirror of
/// `TomeThemePalette` — Core stays free of AppKit.
@MainActor
struct TomeColors {
    let accent: NSColor?        // hover background fill
    let accentText: NSColor?    // text colour while hovered
    let text: NSColor?          // idle row text colour
    /// Solid panel backdrop. When non-nil the system frosted blur is
    /// **replaced** with a solid colour view — required for themes
    /// that need a saturated backdrop the blur can't deliver
    /// (chomp / terminal black, mono OLED, etc).
    let background: NSColor?
    /// When `true`, each `ItemRow` rolls its own random ink from
    /// `NSColorParse.splatoonInks` at init time and keeps it
    /// across every hover. Set when the palette's `accentColor` is
    /// the `"splatoon"` token. Panel-open creates fresh `ItemRow`
    /// instances → fresh per-row inks; the colour only changes
    /// when the menu is dismissed and re-opened. Matches "各行は
    /// ランダム、tome を閉じるまでは固定."
    let accentRandomSplatoon: Bool

    static func resolve(_ palette: TomeThemePalette) -> TomeColors {
        let pick: (String) -> NSColor? = { s in
            s.isEmpty ? nil : NSColorParse.nsColor(s)
        }
        let isSplatoonAccent = palette.accentColor
            .trimmingCharacters(in: .whitespaces)
            .lowercased() == "splatoon"
        return TomeColors(
            accent: isSplatoonAccent ? nil : pick(palette.accentColor),
            accentText: pick(palette.accentTextColor),
            text: pick(palette.textColor),
            background: pick(palette.backgroundColor),
            accentRandomSplatoon: isSplatoonAccent)
    }

    static let none = TomeColors(accent: nil, accentText: nil,
                                  text: nil, background: nil,
                                  accentRandomSplatoon: false)

    /// Pick black or white text against an arbitrary fill so the
    /// label stays legible. BT.601 luma gate at 0.55 — the Splatoon
    /// ink palette has two brights (yellow / lime) where white-on-
    /// white fails and a 0.5 threshold isn't enough headroom; 0.55
    /// pushes those two onto black text and leaves the rest on
    /// white.
    static func legibleText(on fill: NSColor) -> NSColor {
        let c = fill.usingColorSpace(.sRGB) ?? fill
        let luma = 0.299 * c.redComponent
                 + 0.587 * c.greenComponent
                 + 0.114 * c.blueComponent
        return luma > 0.55 ? .black : .white
    }
}

// MARK: - Public entry

@MainActor
public enum LauncherPanel {

    /// Strong reference holder for the currently-visible root panel.
    /// Replaced when a new panel opens; cleared in `dismiss()`.
    private static var current: PanelController?

    public static func present(filteredItems items: [LauncherItem],
                                target: Target,
                                cocoaPoint: NSPoint,
                                layout: LauncherLayout = .list,
                                shortcutBadge: Bool = true,
                                iconChip: Bool = true,
                                fontSize: Int = 13,
                                openAnim: LauncherOpenAnim = .off,
                                closeAnim: LauncherCloseAnim = .off,
                                border: LauncherBorder = .off,
                                borderCycleMs: Int = 4000,
                                borderWidth: Int = 2,
                                shadow: Bool = false,
                                linePets: [LinePet] = [],
                                palette: TomeThemePalette = TomeThemePalette(),
                                themeName: String = "system",
                                orderOverride: [String: [String]] = [:],
                                onReorder: ((String, [String]) -> Void)? = nil,
                                hiddenOverride: [String: Set<String>] = [:],
                                onDelete: ((String, String) -> Void)? = nil,
                                onSelect: @escaping (LauncherItem, Target) -> Void) {
        current?.dismiss()
        guard !items.isEmpty else {
            Log.line("launcher-panel: no items for \(target.bundleID) — "
                     + "panel suppressed")
            return
        }
        // Hidden filter first (deleted rows drop, emptied folders
        // prune), then the DnD order re-applies to what's left.
        // `counterLauncherShown` was already bumped by the caller;
        // the rare "every visible item was session-deleted" case
        // below skews it by one — accepted, the counter reads as
        // "panel requested with visible items".
        let built = PanelTree.applyHidden(PanelTree.build(from: items),
                                           path: "", hidden: hiddenOverride)
        guard !built.isEmpty else {
            Log.line("launcher-panel: all items session-deleted for "
                     + "\(target.bundleID) — panel suppressed")
            return
        }
        let nodes = PanelTree.applyOrder(built, path: "",
                                          override: orderOverride)
        let colors = TomeColors.resolve(palette)
        // Header (app icon + name) only makes sense on the vertical
        // list — in toolbar mode the panel is a single horizontal row
        // and a header banner doesn't fit visually.
        let header = layout == .list
            ? PanelLayout.makeHeaderSpec(for: target)
            : nil
        // Outer margin around bg — needed by any decoration that sits
        // OUTSIDE the panel content rather than inside it. Two sources
        // contribute. `line-pets` ride the rim and need ~14 pt
        // (scaled by `fontSize`) so the panel window doesn't clip
        // their outer half.
        let petScale = max(1.0, CGFloat(fontSize) / 13.0)
        let outerMargin: CGFloat = linePets.isEmpty
            ? 0 : round(14 * petScale)
        let (content, rows) = PanelLayout.buildContent(
            nodes: nodes, header: header, layout: layout,
            shortcutBadge: shortcutBadge, iconChip: iconChip,
            fontSize: fontSize,
            colors: colors, outerMargin: outerMargin)
        let frame = PanelLayout.placeRoot(
            atCursor: cocoaPoint, contentSize: content.fittingSize)
        let controller = PanelController(
            content: content, rows: rows, frame: frame,
            layout: layout,
            target: target, onSelect: onSelect,
            isRoot: true,
            panelPath: "",
            onReorder: onReorder,
            themeName: themeName,
            onDelete: onDelete,
            openAnim: openAnim,
            closeAnim: closeAnim,
            border: border,
            borderCycleMs: borderCycleMs,
            borderWidth: borderWidth,
            shadow: shadow,
            linePets: linePets,
            fontSize: fontSize,
            colors: colors,
            onDismissRoot: { current = nil })
        current = controller
        controller.show()
    }
}

// MARK: - Tree types

/// One node in the panel tree. Built from the flat `[LauncherItem]`
/// list by `PanelTree.build`. `separatorBefore` is carried on
/// `.item` only — folder nodes don't need it because each item that
/// opens a new section keeps its own flag.
///
/// `.placeholder` is used for synthesized disabled rows (e.g. "(no
/// items)" when a dynamic-item expansion's shell command returned
/// nothing). It's NOT in the tree at build time; only injected into
/// expansion results at hover time.
indirect enum PanelNode {
    case item(LauncherItem)
    case folder(name: String, children: [PanelNode])
    case placeholder(label: String)

    /// Stable-within-a-session identity for the DnD sort override
    /// (wand#127). Keyed on the display name — two same-named items
    /// at one level share an id and keep their relative order (see
    /// `LauncherOrder.apply`). `nil` = the node never participates
    /// in reordering. The id is threaded into each `ItemRow` at
    /// build time so rows and nodes can't drift apart.
    var orderID: String? {
        switch self {
        case .item(let i):             return "item:\(i.name)"
        case .folder(let name, _):     return "folder:\(name)"
        case .placeholder:             return nil
        }
    }
}

/// App-header data flowed into the root panel.
private struct HeaderSpec {
    let name: String
    let icon: NSImage?
}

/// Convert `[LauncherItem]` → `[PanelNode]`. Walks each item's `group`
/// path, creating folders on first reference and appending into them
/// on subsequent ones — same shape as the prior `LauncherMenu`
/// folder-building, but produces an immutable tree instead of
/// mutating NSMenus.
private enum PanelTree {
    static func build(from items: [LauncherItem]) -> [PanelNode] {
        let root = FolderBuilder(name: "")
        for item in items {
            var current = root
            for segment in item.group {
                if let existing = current.subs[segment] {
                    current = existing
                } else {
                    let f = FolderBuilder(name: segment)
                    current.subs[segment] = f
                    current.children.append(.folder(f))
                    current = f
                }
            }
            current.children.append(.leaf(item))
        }
        return root.toNodes()
    }

    /// Separator for panel-path override keys. U+001F (unit
    /// separator) instead of "/" because folder names are free-form
    /// user strings — `group = ["a/b"]` and `group = ["a", "b"]`
    /// must not collapse to the same key.
    static let pathSep = "\u{1F}"

    /// Override key for the child panel of folder `name` inside
    /// `parent`. Always prefixes the separator so even an empty
    /// folder name can't collide with the root key `""`.
    static func childPath(_ parent: String, _ name: String) -> String {
        parent + pathSep + name
    }

    /// Human-readable form of a panel path for log lines.
    static func displayPath(_ path: String) -> String {
        path.isEmpty
            ? "(root)"
            : path.split(separator: Character(pathSep), omittingEmptySubsequences: false)
                  .dropFirst()  // leading separator from the always-prefix shape
                  .joined(separator: "/")
    }

    /// Re-apply the session's DnD sort override (wand#127) to every
    /// level of the tree. `override` maps a panel path ("" = root,
    /// folder names joined via `pathSep` when nested) to the row
    /// order the user last dragged that level into;
    /// `LauncherOrder.apply` does the slot-merge so rows the
    /// override doesn't know about keep their config positions.
    static func applyOrder(_ nodes: [PanelNode], path: String,
                           override: [String: [String]]) -> [PanelNode] {
        let level = override[path].map { order in
            LauncherOrder.apply(nodes, id: { $0.orderID }, override: order)
        } ?? nodes
        guard !override.isEmpty else { return level }
        return level.map { node in
            guard case .folder(let name, let children) = node else {
                return node
            }
            return .folder(name: name,
                           children: applyOrder(children,
                                                 path: childPath(path, name),
                                                 override: override))
        }
    }

    /// Apply the session's context-menu deletes (t-k4hf) to every
    /// level of the tree, BEFORE `applyOrder`. `hidden` maps a panel
    /// path to the node ids the user deleted at that level. Folders
    /// whose children all end up hidden are pruned — an empty child
    /// panel must never appear.
    static func applyHidden(_ nodes: [PanelNode], path: String,
                             hidden: [String: Set<String>]) -> [PanelNode] {
        guard !hidden.isEmpty else { return nodes }
        let level = LauncherHidden.apply(nodes, id: { $0.orderID },
                                          hidden: hidden[path] ?? [])
        return level.compactMap { node in
            guard case .folder(let name, let children) = node else {
                return node
            }
            let kids = applyHidden(children,
                                    path: childPath(path, name),
                                    hidden: hidden)
            return kids.isEmpty ? nil : .folder(name: name, children: kids)
        }
    }

    /// Mutable intermediate. Class so siblings share folder references.
    private final class FolderBuilder {
        let name: String
        var children: [Child] = []
        var subs: [String: FolderBuilder] = [:]
        init(name: String) { self.name = name }
        enum Child {
            case folder(FolderBuilder)
            case leaf(LauncherItem)
        }
        func toNodes() -> [PanelNode] {
            children.map { c in
                switch c {
                case .folder(let f):
                    return .folder(name: f.name, children: f.toNodes())
                case .leaf(let item):
                    return .item(item)
                }
            }
        }
    }
}

// MARK: - Layout

/// Content-view construction + screen-aware frame placement. Pulled
/// out of `PanelController` so the init becomes a thin wire-up step
/// instead of a multi-stage builder.
@MainActor
private enum PanelLayout {

    /// Panel internal width target. Wide enough for typical
    /// breadcrumbed labels without wrapping; narrow enough not to feel
    /// like a dialog.
    static let contentWidth: CGFloat = 240
    /// Visual gap between content edge and accent-highlighted hover
    /// fill on each side. Matches the row's own internal padding.
    static let cornerRadius: CGFloat = 8

    static func makeHeaderSpec(for target: Target) -> HeaderSpec? {
        let (name, icon) = AppIconCache.shared.lookup(
            bundleID: target.bundleID, iconSize: ItemRow.iconRenderPt)
        if name.isEmpty && icon == nil { return nil }
        return HeaderSpec(name: name, icon: icon)
    }

    /// Build the content view (NSVisualEffectView wrapping a
    /// stack of rows) and return both the view and the row list so
    /// the caller can wire callbacks. `layout` picks the orientation:
    /// `.list` builds a vertical stack of full-width rows; `.toolbar`
    /// builds a horizontal stack of icon-only buttons.
    static func buildContent(nodes: [PanelNode],
                              header: HeaderSpec?,
                              layout: LauncherLayout,
                              shortcutBadge: Bool = true,
                              iconChip: Bool = true,
                              fontSize: Int = 13,
                              colors: TomeColors = .none,
                              outerMargin: CGFloat = 0)
        -> (view: NSView, rows: [ItemRow]) {
        // Backdrop: themed solid colour replaces the system frosted
        // blur when `colors.background` is set. The blur can't be
        // tinted (NSVisualEffectView's `.menu` material has no colour
        // knob), so saturated themes like chomp / terminal need a
        // full surface swap — at the cost of losing vibrancy. The
        // default (`background == nil`) keeps the historical
        // frosted-glass `.menu` look.
        let bg: NSView
        if let bgColor = colors.background {
            let solid = NSView()
            solid.wantsLayer = true
            solid.layer?.backgroundColor = bgColor.cgColor
            bg = solid
        } else {
            let blur = NSVisualEffectView()
            blur.material = .menu
            blur.blendingMode = .behindWindow
            blur.state = .active
            bg = blur
        }
        bg.wantsLayer = true
        bg.layer?.cornerRadius = cornerRadius
        bg.layer?.masksToBounds = true
        bg.translatesAutoresizingMaskIntoConstraints = false
        // Panel rim is solely a `[tome.decoration.border]` concern —
        // a theme-supplied static frame here would overlap (and
        // visually swallow) the animated rim drawn by
        // `PanelController.installBorderDecoration`.

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        switch layout {
        case .list:
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 0
            stack.edgeInsets = NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)
        case .toolbar:
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 2
            stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        case .labeledToolbar:
            // Same horizontal orientation as toolbar; slightly more
            // spacing between pills since each button is wider.
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 3
            stack.edgeInsets = NSEdgeInsets(top: 4, left: 5, bottom: 4, right: 5)
        }

        var rows: [ItemRow] = []
        var views: [NSView] = []

        if let h = header, layout == .list {
            let hr = ItemRow(kind: .header, label: h.name, icon: h.icon,
                              layout: layout,
                              fontSize: fontSize)
            rows.append(hr)
            views.append(hr)
            views.append(makeSeparator(layout: layout))
        }

        // Track the current section as we walk nodes. Section headers
        // only fire in list mode — toolbar variants are short horizontal
        // strips where a header band would dominate the panel — and
        // only on `.item` nodes (folders / placeholders pass through
        // without disturbing the section).
        //
        // An empty `header` on an item inherits whatever the previous
        // run used, so a config can carry one `header = "Editing"` on
        // the first row of a run and leave it off the rest. After
        // filtering (apps / title / shell), if every item in a section
        // is excluded then that header's `.item` nodes never enter
        // `nodes` and the band is silently omitted — no orphan labels.
        var currentSection: String? = nil
        for node in nodes {
            switch node {
            case .item(let item):
                if layout == .list && !item.header.isEmpty
                    && item.header != currentSection {
                    views.append(makeSectionHeaderRow(name: item.header,
                                                       layout: layout,
                                                       fontSize: fontSize,
                                                       sink: &rows))
                    currentSection = item.header
                }
                // separator-before only applies in list mode; in
                // toolbar mode it would be a vertical bar between
                // buttons, which adds visual noise without enough
                // grouping payoff for a single row of 6-8 items.
                if layout == .list && item.separatorBefore && !views.isEmpty {
                    views.append(makeSeparator(layout: layout))
                }
                views.append(makeItemRow(item, nodeID: node.orderID,
                                          layout: layout,
                                          shortcutBadge: shortcutBadge,
                                          iconChip: iconChip,
                                          fontSize: fontSize,
                                          sink: &rows))
            case .folder(let name, let children):
                views.append(makeFolderRow(name: name, children: children,
                                            nodeID: node.orderID,
                                            layout: layout,
                                            fontSize: fontSize,
                                            sink: &rows))
            case .placeholder(let label):
                views.append(makePlaceholderRow(label: label,
                                                 layout: layout,
                                                 fontSize: fontSize,
                                                 sink: &rows))
            }
        }

        // In list mode every row is constrained to a uniform width so
        // hover highlights are rectangular; in toolbar mode each
        // button is its own intrinsic square and the stack hugs them.
        if layout == .list {
            for v in views {
                stack.addArrangedSubview(v)
                v.widthAnchor.constraint(
                    equalToConstant: contentWidth).isActive = true
            }
        } else {
            for v in views {
                stack.addArrangedSubview(v)
            }
        }

        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: bg.topAnchor),
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])

        let content = NSView()
        content.addSubview(bg)
        // `outerMargin > 0` insets bg from content on all four sides
        // so a decoration view layered above bg (chomp pellet, …) has
        // room to draw OUTSIDE bg's rounded edge without being
        // clipped by the panel window. The panel's frame is then
        // sized to `stack.fittingSize + 2 * outerMargin` so the
        // rendered bg footprint matches the no-margin case visually.
        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: content.topAnchor,
                                     constant: outerMargin),
            bg.leadingAnchor.constraint(equalTo: content.leadingAnchor,
                                         constant: outerMargin),
            bg.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                          constant: -outerMargin),
            bg.bottomAnchor.constraint(equalTo: content.bottomAnchor,
                                        constant: -outerMargin),
        ])
        content.frame = NSRect(origin: .zero,
                                size: CGSize(
                                    width: stack.fittingSize.width
                                        + 2 * outerMargin,
                                    height: stack.fittingSize.height
                                        + 2 * outerMargin))
        // Apply the resolved theme to every row built above. Cheap —
        // each call re-runs `applyIdleStyle`, no view rebuild — and
        // keeping it post-build means the factory functions stay
        // theme-unaware.
        for r in rows { r.applyTheme(colors) }
        return (content, rows)
    }

    /// Frame for the ROOT panel: cursor at top-left, clamped to the
    /// screen containing the cursor.
    static func placeRoot(atCursor cursor: NSPoint,
                           contentSize size: NSSize) -> NSRect {
        let visible = visibleFrame(for: cursor)
        // Top-left at cursor → bottom-left = (cursor.x, cursor.y - h)
        var origin = NSPoint(x: cursor.x, y: cursor.y - size.height)
        if origin.x + size.width > visible.maxX {
            origin.x = visible.maxX - size.width
        }
        if origin.x < visible.minX { origin.x = visible.minX }
        if origin.y < visible.minY {
            // Falls off bottom — open above the cursor instead.
            origin.y = cursor.y
        }
        if origin.y + size.height > visible.maxY {
            origin.y = visible.maxY - size.height
        }
        return NSRect(origin: origin, size: size)
    }

    /// Frame for a CHILD panel anchored to a row in the parent panel.
    /// Placement direction depends on the parent panel's orientation:
    /// list parent opens the child to the RIGHT (top-aligned with the
    /// hovered row); any horizontal-toolbar variant opens it BELOW
    /// (left-aligned with the hovered button). In both cases we flip
    /// to the opposite side if the preferred side would clip.
    static func placeChild(rowFrameOnScreen rowFrame: NSRect,
                            parentPanelFrame parent: NSRect,
                            parentLayout: LauncherLayout,
                            contentSize size: NSSize) -> NSRect {
        let visible = visibleFrame(for: NSPoint(x: rowFrame.midX,
                                                  y: rowFrame.midY))
        if !parentLayout.isHorizontal {
            // List parent: right of parent panel, child top = row top.
            var originX = rowFrame.maxX
            if originX + size.width > visible.maxX {
                // Flip to the left of the parent panel (NOT just
                // left of the row — we want the cursor-traversal
                // gap to stay zero on the side we end up on).
                originX = parent.minX - size.width
            }
            if originX < visible.minX { originX = visible.minX }
            var originY = rowFrame.maxY - size.height
            if originY < visible.minY { originY = visible.minY }
            if originY + size.height > visible.maxY {
                originY = visible.maxY - size.height
            }
            return NSRect(origin: NSPoint(x: originX, y: originY), size: size)
        }
        // Horizontal parent (toolbar or labeled-toolbar) → child
        // opens below the hovered button. Child top edge at button's
        // bottom (no gap, so cursor moves smoothly down into the
        // child); left-aligned with the button, clamped horizontally
        // if it would clip.
        var originX = rowFrame.minX
        if originX + size.width > visible.maxX {
            originX = visible.maxX - size.width
        }
        if originX < visible.minX { originX = visible.minX }
        var originY = rowFrame.minY - size.height
        if originY < visible.minY {
            // No room below the toolbar — flip above the panel
            // (child bottom = panel top).
            originY = parent.maxY
            if originY + size.height > visible.maxY {
                originY = visible.maxY - size.height
            }
        }
        return NSRect(origin: NSPoint(x: originX, y: originY), size: size)
    }

    private static func visibleFrame(for point: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        return screen?.visibleFrame ?? .zero
    }

    private static func makeItemRow(_ item: LauncherItem,
                                     nodeID: String?,
                                     layout: LauncherLayout,
                                     shortcutBadge: Bool,
                                     iconChip: Bool,
                                     fontSize: Int,
                                     sink rows: inout [ItemRow]) -> NSView {
        if !item.dynamic.isEmpty {
            // Dynamic item — render as a folder-style row that
            // hover-expands into a child panel populated by running
            // `item.dynamic` (see `PanelController.openDynamicChild`).
            let icon = resolveItemIconWithFallback(item: item, layout: layout,
                                                    iconChip: iconChip,
                                                    fontSize: fontSize)
            let r = ItemRow(kind: .dynamic(item),
                            label: item.name, icon: icon, layout: layout,
                            fontSize: fontSize, nodeID: nodeID)
            rows.append(r)
            return r
        }
        let label = renderItemLabel(item, layout: layout)
        let icon = resolveItemIconWithFallback(item: item, layout: layout,
                                                iconChip: iconChip,
                                                fontSize: fontSize)
        // Auto-derive a shortcut glyph for `.key(...)` actions so list
        // rows can show the underlying ⌘W next to the label — pure
        // documentation, never intercepts the actual key. Other action
        // types (ax / shell / url) have no shortcut to display, and
        // toolbar variants have no room for it.
        let shortcut: String = {
            guard shortcutBadge, layout == .list else { return "" }
            guard case .key(let keys) = item.action else { return "" }
            return KeyCombo.format(keys) ?? ""
        }()
        // Subtitle only in list layout — toolbar variants are too short.
        let subtitle = layout == .list ? item.subtitle : ""
        let r = ItemRow(kind: .leaf(item), label: label, icon: icon,
                         layout: layout, shortcut: shortcut,
                         subtitle: subtitle, iconAnim: item.iconAnim,
                         iconSpec: item.icon,
                         fontSize: fontSize, nodeID: nodeID)
        rows.append(r)
        return r
    }

    /// Icon for an item, with a layout-specific fallback when the
    /// item didn't declare one. In list mode an empty icon is fine
    /// (the row's label carries the meaning), so we return nil and
    /// let the icon column collapse. In toolbar mode the button
    /// would otherwise be a blank square, indistinguishable from
    /// other unlabelled buttons — so we draw the first 1-2 chars of
    /// the item's `name` as a text glyph. Same trick the existing
    /// `resolveItemIcon` uses for emoji / short-text icon specs.
    private static func resolveItemIconWithFallback(
        item: LauncherItem, layout: LauncherLayout, iconChip: Bool,
        fontSize: Int
    ) -> NSImage? {
        if !item.icon.isEmpty {
            return resolveItemIcon(item.icon,
                                    tint: item.tint,
                                    tintColors: item.tintColors,
                                    iconChip: iconChip,
                                    fontSize: fontSize)
        }
        switch layout {
        case .list:
            return nil
        case .toolbar, .labeledToolbar:
            // Synthesised text-glyph fallback for unlabelled toolbar
            // buttons — these are always rendered as text, so they
            // benefit from the chip the same way an emoji icon would.
            let glyph = String(item.name.prefix(2))
            return IconResolver.resolve(glyph,
                                         fontSize: fontSize,
                                         iconChip: iconChip)
        }
    }

    private static func makeFolderRow(name: String,
                                       children: [PanelNode],
                                       nodeID: String?,
                                       layout: LauncherLayout,
                                       fontSize: Int,
                                       sink rows: inout [ItemRow]) -> NSView {
        let r = ItemRow(kind: .folder(name: name, children: children),
                        label: name, icon: nil, layout: layout,
                        fontSize: fontSize, nodeID: nodeID)
        rows.append(r)
        return r
    }

    private static func makePlaceholderRow(label: String,
                                            layout: LauncherLayout,
                                            fontSize: Int,
                                            sink rows: inout [ItemRow]) -> NSView {
        let r = ItemRow(kind: .placeholder, label: label, icon: nil,
                         layout: layout, fontSize: fontSize)
        rows.append(r)
        return r
    }

    /// Inline section-header band drawn above a run of items sharing a
    /// `LauncherItem.header` value. Non-interactive (no hover / click)
    /// — pure visual separation between groups of related items in
    /// the same panel. Only emitted in `.list` layout.
    private static func makeSectionHeaderRow(name: String,
                                              layout: LauncherLayout,
                                              fontSize: Int,
                                              sink rows: inout [ItemRow]) -> NSView {
        // Section headers keep their compact small-caps style at the
        // same fixed point size regardless of `fontSize` — the band
        // is a visual rest between item runs, not a title that
        // should scale with body content. Passing fontSize through
        // anyway so future tweaks have it available without another
        // signature change.
        let r = ItemRow(kind: .sectionHeader(name), label: name,
                         icon: nil, layout: layout,
                         fontSize: fontSize)
        rows.append(r)
        return r
    }

    /// Run `item.dynamic` under `/bin/sh -c`, kill it after 500 ms,
    /// and convert each non-empty stdout line into a synthetic leaf
    /// `LauncherItem` via `item.template`. Errors (timeout, spawn
    /// fail, non-zero exit, empty stdout) become a single
    /// `.placeholder` node so the user always sees something. Called
    /// at hover time, not present time, so the cost is paid only when
    /// the user actually opens the dynamic submenu.
    static func expandDynamic(_ item: LauncherItem) -> [PanelNode] {
        guard !item.dynamic.isEmpty, let template = item.template else {
            return [.placeholder(label: "(invalid dynamic)")]
        }
        switch BoundedShell.run(item.dynamic, timeoutMs: 500) {
        case .timeout:
            return [.placeholder(label: "(timeout)")]
        case .spawnFailed:
            return [.placeholder(label: "(spawn failed)")]
        case .exited(_, let exit) where exit != 0:
            return [.placeholder(label: "(error: exit \(exit))")]
        case .exited(let stdout, _):
            let lines = stdout
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if lines.isEmpty { return [.placeholder(label: "(no items)")] }
            return lines.map { line in
                .item(synthesizeChild(template: template, line: line,
                                       parent: item))
            }
        }
    }

    /// Build one synthetic leaf `LauncherItem` from a template + a
    /// stdout line. `{line}` placeholders in the template's name,
    /// icon and payload are substituted. Inherits `apps` from the
    /// parent dynamic item so app-filter behaviour matches.
    /// `{line}` content is untrusted — same caveat as
    /// `WAND_TARGET_TITLE`; template authors must quote it when it
    /// reaches a shell command.
    private static func synthesizeChild(template: LauncherTemplate,
                                         line: String,
                                         parent: LauncherItem) -> LauncherItem {
        let name = template.name.replacingOccurrences(of: "{line}", with: line)
        let icon = template.icon.replacingOccurrences(of: "{line}", with: line)
        let payload = template.payload.replacingOccurrences(of: "{line}",
                                                              with: line)
        let action: Action
        switch template.kind {
        case .key:   action = .key(payload)
        case .ax:    action = .ax(payload)
        case .shell: action = .shell(payload)
        case .url:   action = .url(payload)
        }
        return LauncherItem(
            name: name,
            group: [],
            separatorBefore: false,
            apps: parent.apps,
            icon: icon,
            filterTitle: "",
            filterShell: "",
            state: "",
            dynamic: "",
            template: nil,
            action: action)
    }

    /// Build the row title from the item, folding in state marker.
    /// Applied in every layout: list (visible prefix), labeled-toolbar
    /// (visible prefix), toolbar (tooltip content). The state glyph
    /// is useful even in the tooltip path — "✓ Dark Mode" tells the
    /// user the option is currently active without taking up
    /// on-screen space.
    private static func renderItemLabel(_ item: LauncherItem,
                                         layout: LauncherLayout) -> String {
        var parts: [String] = []
        switch item.state {
        case "on":    parts.append("✓")
        case "mixed": parts.append("–")
        default:
            if item.state.hasPrefix("shell:") {
                let cmd = String(item.state.dropFirst("shell:".count))
                switch BoundedShell.run(cmd, timeoutMs: 100) {
                case .exited(_, let exit) where exit == 0:
                    parts.append("✓")
                default: break
                }
            }
        }
        parts.append(item.name)
        return parts.joined(separator: " ")
    }

    /// Separator wrapper. List mode: a horizontal 1pt rule with 7pt
    /// vertical padding. Toolbar mode: a vertical rule between
    /// buttons (used in practice only for `separator-before` we
    /// already skip in toolbar — kept for completeness if a future
    /// toolbar feature wants section dividers).
    private static func makeSeparator(layout: LauncherLayout) -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(line)
        if layout == .list {
            NSLayoutConstraint.activate([
                wrap.heightAnchor.constraint(equalToConstant: 7),
                line.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
                line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor,
                                              constant: 8),
                line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor,
                                               constant: -8),
                line.heightAnchor.constraint(equalToConstant: 1),
            ])
        } else {
            NSLayoutConstraint.activate([
                wrap.widthAnchor.constraint(equalToConstant: 7),
                line.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
                line.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 4),
                line.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -4),
                line.widthAnchor.constraint(equalToConstant: 1),
            ])
        }
        return wrap
    }

    /// Item-icon resolution. Thin wrapper around `IconResolver.resolve`
    /// — the shared resolver also serves the cast HUD assist cards.
    static func resolveItemIcon(_ spec: String,
                                 tint: String = "",
                                 tintColors: [String] = [],
                                 iconChip: Bool = false,
                                 fontSize: Int = 13) -> NSImage? {
        IconResolver.resolve(spec, fontSize: fontSize,
                             tint: tint, tintColors: tintColors,
                             iconChip: iconChip)
    }
}

// MARK: - Panel

/// NSPanel subclass that refuses key/main status. With
/// `canBecomeKey = false` the panel can receive mouse events but
/// macOS won't deliver key events to it — the underlying app keeps
/// its first responder.
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class PanelController {
    let panel: NonActivatingPanel
    /// The layout of THIS panel. Root may be `.list` or `.toolbar`;
    /// non-root (children) are always `.list`. Used by `openChild`
    /// to pick the spawn direction.
    let layout: LauncherLayout
    private let target: Target
    private let onSelect: (LauncherItem, Target) -> Void
    private let isRoot: Bool
    /// Tree position for the session DnD sort override (wand#127):
    /// "" = root, folder names joined via `PanelTree.pathSep` when
    /// nested. Keys the order the panel's rows are reported under
    /// when the user drags one.
    private let panelPath: String
    /// Fires after a DnD row drop with (panelPath, new node-id order
    /// for that level). `nil` = reordering disabled for this panel
    /// (toolbar layouts, dynamic expansions, external `tome --open`).
    private let onReorder: ((String, [String]) -> Void)?
    /// Fires when the user picks Delete in a row's context menu, with
    /// (panelPath, nodeID). `nil` = deletion disabled for this panel
    /// (toolbar layouts, dynamic expansions, external `tome --open`).
    private let onDelete: ((String, String) -> Void)?
    /// Theme name from config ([tome].theme) — resolved lazily via
    /// PaletteKit for the context menu's palette. The tome rows keep
    /// their own TomeColors pipeline; only ThemedMenu consumes this.
    private let themeName: String
    /// Row context menu (t-k4hf). Created on first right-click,
    /// reused for the panel's lifetime, dismissed in tearDown.
    private var contextMenu: ThemedMenu?
    /// Open-time animation applied in `show()`. Inherited by child
    /// panels when they're spawned (so the whole cascade feels
    /// consistent). `.off` keeps the historical instant pop.
    private let openAnim: LauncherOpenAnim
    /// Symmetric close-time animation applied in `tearDown()`. Same
    /// inheritance rule as `openAnim` — child panels pick up the
    /// root's value so the cascade unwinds visually together.
    private let closeAnim: LauncherCloseAnim
    /// Decorative panel border (rainbow / future palette variants).
    /// Drawn in `show()` as a CAShapeLayer above `contentView`'s
    /// blur, with a hue-rotating CAKeyframeAnimation. Child panels
    /// inherit the root's value.
    private let border: LauncherBorder
    /// Cycle period (ms) for any animated `border` kind — feeds the
    /// CAKeyframeAnimation `duration` in `installBorderDecoration`.
    /// Static border kinds ignore this value. Child panels inherit
    /// from the root for visual consistency.
    private let borderCycleMs: Int
    /// Border stroke width (points). Feeds `CAShapeLayer.lineWidth`
    /// in `installBorderDecoration`. Ignored when `border = .off`.
    /// Child panels inherit from the root.
    private let borderWidth: Int
    /// Whether to draw the macOS window drop shadow under the panel.
    /// Default `false`: a thin halo just outside the rim reads as a
    /// fringe on the border decoration, so the project default is
    /// no shadow. Child panels inherit from the root.
    private let shadow: Bool
    /// Chomp "pets" walking the panel's outer edge. Empty array
    /// = no decoration. Theme-agnostic; child panels inherit from
    /// the root.
    private let linePets: [LinePet]
    /// Title font size (points) — forwarded to every row built for
    /// child panels (`openChild`) so submenus stay at the same text
    /// scale as the root.
    private let fontSize: Int
    /// Re-entry guard: a fade-out can dispatch async, and a global
    /// click or follow-up `dismiss()` could land mid-fade. Once `true`
    /// the panel is committed to its current teardown path and any
    /// further `tearDown()` call is a no-op.
    private var isClosing = false
    /// Root-only: cleared in `tearDown()`, called once when the entire
    /// tree is gone. Non-root controllers leave this nil.
    private let onDismissRoot: (() -> Void)?
    /// Set when this panel is a child of another. Used to walk back
    /// up the tree for tree-wide dismissal.
    private weak var parent: PanelController?
    /// Currently-open child (one at a time per level). Cleared in
    /// `closeChild()`.
    private var child: PanelController?
    /// The folder row that spawned `child` (so we can detect "still
    /// hovering the same folder" vs "moved to a different row").
    private weak var childAnchor: ItemRow?

    private var globalMouseMonitor: Any?
    private var globalKeyMonitor: Any?

    /// Resolved theme colours. Carried so child panels (submenus,
    /// dynamic expansions) inherit the same look — `openChild`
    /// threads this into the child's `buildContent`.
    let colors: TomeColors

    init(content: NSView, rows: [ItemRow], frame: NSRect,
         layout: LauncherLayout = .list,
         target: Target,
         onSelect: @escaping (LauncherItem, Target) -> Void,
         isRoot: Bool,
         panelPath: String = "",
         onReorder: ((String, [String]) -> Void)? = nil,
         themeName: String = "system",
         onDelete: ((String, String) -> Void)? = nil,
         openAnim: LauncherOpenAnim = .off,
         closeAnim: LauncherCloseAnim = .off,
         border: LauncherBorder = .off,
         borderCycleMs: Int = 4000,
         borderWidth: Int = 2,
         shadow: Bool = false,
         linePets: [LinePet] = [],
         fontSize: Int = 13,
         colors: TomeColors = .none,
         onDismissRoot: (() -> Void)? = nil) {
        self.layout = layout
        self.target = target
        self.onSelect = onSelect
        self.isRoot = isRoot
        self.panelPath = panelPath
        self.onReorder = onReorder
        self.themeName = themeName
        self.onDelete = onDelete
        self.openAnim = openAnim
        self.closeAnim = closeAnim
        self.border = border
        self.borderCycleMs = borderCycleMs
        self.borderWidth = borderWidth
        self.shadow = shadow
        self.linePets = linePets
        self.fontSize = fontSize
        self.colors = colors
        self.onDismissRoot = isRoot ? onDismissRoot : nil

        self.panel = NonActivatingPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless,
                        .fullSizeContentView],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces,
                                    .fullScreenAuxiliary, .transient]
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = shadow
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = content

        for row in rows {
            row.onHover = { [weak self, weak row] in
                guard let self, let row else { return }
                self.handleRowHover(row)
            }
            row.onClick = { [weak self, weak row] in
                guard let self, let row else { return }
                self.handleRowClick(row)
            }
        }
        // Session DnD sort (wand#127) — only vertical list panels
        // whose caller opted in (native tome; not `tome --open`,
        // not dynamic expansions) and only rows that carry a node id
        // (headers / placeholders sit out).
        if layout == .list && onReorder != nil {
            for row in rows where row.nodeID != nil {
                row.enableReorder { [weak self] source, target, after in
                    self?.handleReorderDrop(source: source, target: target,
                                             after: after)
                }
            }
        }
        // Row context menu (t-k4hf) — same opt-in shape as reorder:
        // native tome `.list` panels only, rows that carry a node id.
        if layout == .list && onDelete != nil {
            for row in rows where row.nodeID != nil {
                row.enableContextMenu { [weak self] row, event in
                    self?.showDeleteMenu(for: row, event: event)
                }
            }
        }
    }

    func show() {
        // Decorative panel border (rainbow / …) — installed before
        // the open animation so the border participates in the alpha
        // ramp without flicker. Auto-released when the panel orders
        // out (the layer's parent view goes away with the window).
        installBorderDecoration()
        installChompDecoration()
        switch openAnim {
        case .off:
            panel.orderFront(nil)
        case .fade:
            // Alpha 0 → 1 ease-out over ~140ms. Cheap and reliable —
            // no layer transform involved, so it composites the same
            // on any backend.
            panel.alphaValue = 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.allowsImplicitAnimation = true
                panel.animator().alphaValue = 1
            }
        case .pop:
            // Alpha 0 → 1 + scale 0.92 → 1.0 on the contentView's
            // CALayer. Scaling the NSWindow's frame instead would
            // shift its on-screen origin, so we animate the layer
            // inside a stable window. ~180ms ease-out cubic for a
            // gentle pop that doesn't feel jittery.
            panel.alphaValue = 0
            if let layer = panel.contentView?.layer {
                let size = panel.contentView?.bounds.size
                    ?? .zero
                layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                layer.position = CGPoint(x: size.width / 2,
                                          y: size.height / 2)
                layer.transform = CATransform3DMakeScale(0.92, 0.92, 1)
            }
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(
                    name: .easeOut)
                ctx.allowsImplicitAnimation = true
                panel.animator().alphaValue = 1
                if let layer = panel.contentView?.layer {
                    layer.transform = CATransform3DIdentity
                }
            }
        }
        if isRoot { installDismissMonitors() }
    }

    /// Paint the configured `border` decoration as bg's CALayer-native
    /// border (`borderColor` + `borderWidth`). No-op for `.off`.
    ///
    /// Hosting note: earlier iterations tried a separate CAShapeLayer
    /// (on contentView, on bg.layer, then on a dedicated overlay
    /// view) and every one of them suffered from anti-aliasing
    /// mismatch at bg's rounded mask edge — a faint dark fringe
    /// outside the rim, the "黒い枠" issue. CALayer's native border
    /// is drawn by the compositor as a single operation with the
    /// layer's `cornerRadius`, so the rounded curve and the rim are
    /// anti-aliased together with no seam between them.
    private func installBorderDecoration() {
        guard border != .off,
              let bg = panel.contentView?.subviews.first,
              let layer = bg.layer else { return }
        layer.borderWidth = CGFloat(borderWidth)
        switch border {
        case .off:
            return  // unreachable; guarded above
        case .rainbow:
            // Hue rotation around the wheel over `borderCycleMs`.
            // CAKeyframeAnimation on the layer's own `borderColor`
            // composes with `cornerRadius` natively — no separate
            // stroke layer, no clipping fringe.
            let stops = (0..<9).map { i in
                NSColor(hue: CGFloat(i) / 8.0,
                        saturation: 0.85, brightness: 1.0,
                        alpha: 0.95).cgColor
            }
            // Seed the model-layer colour so a paused window doesn't
            // flash transparent before the animation kicks in.
            layer.borderColor = stops.first
            let anim = CAKeyframeAnimation(keyPath: "borderColor")
            anim.values = stops
            anim.duration = Double(borderCycleMs) / 1000.0
            anim.repeatCount = .infinity
            anim.calculationMode = .linear
            layer.add(anim, forKey: "rainbow")
        case .terminal, .neon, .splatoon, .mono, .vapor, .chomp:
            // Static signature-colour rim — ports the per-theme
            // `borderColor` that lived on `TomeThemePalette` through
            // PR #111. Pair freely with any `[tome].theme`.
            layer.borderColor = border.staticColor.cgColor
        }
    }

    /// Install the line-pet overlay above `bg` when at least one pet
    /// is configured. The view spans `content` (which is bg + the
    /// outer margin set in `buildContent`) so the pets have room to
    /// ride along bg's rounded edge without being clipped. Its own
    /// 60 fps timer drives the orbit + per-pet animations; the timer
    /// dies with the view (cleaned up in `viewWillMove(toWindow:)`),
    /// so no explicit cleanup is needed here.
    private func installChompDecoration() {
        guard !linePets.isEmpty,
              let content = panel.contentView,
              let bg = content.subviews.first else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        let view = TomePetsView(
            frame: content.bounds,
            bgFrameInView: bg.frame,    // bg.frame is in content coords
            cornerRadius: PanelLayout.cornerRadius,
            pets: linePets,
            petScale: max(1.0, CGFloat(fontSize) / 13.0))
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
    }

    /// Dismiss the entire tree from any level. Walks up to root, then
    /// tears down monitors and orders out every panel from the deepest
    /// child back to the root.
    func dismiss() {
        var top: PanelController = self
        while let p = top.parent { top = p }
        top.tearDown()
    }

    private func tearDown() {
        // A teardown that's already in-flight (mid-fade) shouldn't
        // restart its own animation if a follow-up `dismiss()` lands.
        if isClosing { return }
        isClosing = true

        contextMenu?.dismiss(animated: false)
        contextMenu = nil

        // Recursively tear down children first so the whole cascade
        // fades together — each child schedules its own close-anim,
        // running in parallel with this panel's.
        child?.tearDown()
        child = nil
        childAnchor = nil
        if let g = globalMouseMonitor {
            NSEvent.removeMonitor(g)
            globalMouseMonitor = nil
        }
        if let k = globalKeyMonitor {
            NSEvent.removeMonitor(k)
            globalKeyMonitor = nil
        }
        // Clear the root tracking ASAP so a new middle-click during
        // the fade starts a fresh panel cleanly. The animation
        // closures below capture `self` strongly so the controller
        // survives until `orderOut` runs.
        onDismissRoot?()

        switch closeAnim {
        case .off:
            panel.orderOut(nil)
        case .fade:
            NSAnimationContext.runAnimationGroup({ [self] ctx in
                ctx.duration = 0.12
                ctx.allowsImplicitAnimation = true
                self.panel.animator().alphaValue = 0
            }, completionHandler: { [self] in
                self.panel.orderOut(nil)
            })
        case .pop:
            NSAnimationContext.runAnimationGroup({ [self] ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                ctx.allowsImplicitAnimation = true
                self.panel.animator().alphaValue = 0
                if let layer = self.panel.contentView?.layer {
                    let size = self.panel.contentView?.bounds.size
                        ?? .zero
                    layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                    layer.position = CGPoint(x: size.width / 2,
                                              y: size.height / 2)
                    layer.transform = CATransform3DMakeScale(0.92, 0.92, 1)
                }
            }, completionHandler: { [self] in
                self.panel.orderOut(nil)
            })
        }
    }

    // MARK: Row callbacks

    private func handleRowClick(_ row: ItemRow) {
        switch row.kind {
        case .leaf(let item):
            onSelect(item, target)
            dismiss()
        case .folder, .dynamic, .header, .sectionHeader, .placeholder:
            break  // folders / dynamic open on hover, not click;
                   // headers / placeholders are non-interactive
        }
    }

    /// One row was dropped onto another (same panel level). Move the
    /// dragged row's view in the stack for immediate visual feedback,
    /// then report the level's new node-id order upward so the next
    /// panel-open rebuilds in that order. `after` = insert below the
    /// target row (drop landed in its lower half).
    private func handleReorderDrop(source: ItemRow, target: ItemRow,
                                    after: Bool) {
        guard source !== target,
              let stack = target.superview as? NSStackView,
              source.superview === stack,
              let targetIdx = stack.arrangedSubviews.firstIndex(of: target),
              let sourceIdx = stack.arrangedSubviews.firstIndex(of: source)
        else { return }
        var idx = after ? targetIdx + 1 : targetIdx
        if sourceIdx < idx { idx -= 1 }
        guard idx != sourceIdx else { return }
        stack.removeArrangedSubview(source)
        source.removeFromSuperview()
        stack.insertArrangedSubview(source, at: idx)
        // Separators / section headers don't travel with the row in
        // the live panel (they carry no node id); the next panel-open
        // rebuilds them against the new item order.
        let order = stack.arrangedSubviews.compactMap {
            ($0 as? ItemRow)?.nodeID
        }
        Log.line("launcher-panel: DnD sort \"\(source.titleForLog)\" "
                 + "at \"\(PanelTree.displayPath(panelPath))\" — "
                 + "\(order.count) row(s) reordered (session-only)")
        onReorder?(panelPath, order)
    }

    /// Right-click on an eligible row → ThemedMenu with one Delete
    /// item. sill's PopupPanel refuses key/main (same discipline as
    /// NonActivatingPanel), so presenting it can never steal focus
    /// from the app under the tome panel.
    private func showDeleteMenu(for row: ItemRow, event: NSEvent) {
        guard let nodeID = row.nodeID, let win = row.window else { return }
        let menu: ThemedMenu
        if let existing = contextMenu {
            menu = existing
        } else {
            menu = ThemedMenu(palette: PaletteKit.resolve(paletteFor(themeName)))
            contextMenu = menu
        }
        menu.items = [ThemedMenu.MenuItem(
            "Delete",
            icon: NSImage(systemSymbolName: "trash",
                          accessibilityDescription: "Delete"),
            isDestructive: true) { [weak self, weak row] in
                guard let self, let row else { return }
                self.handleDelete(row: row, nodeID: nodeID)
            }]
        Log.line("launcher-panel: context menu on \"\(row.titleForLog)\" "
                 + "at \"\(PanelTree.displayPath(panelPath))\"")
        menu.present(at: event.locationInWindow, in: win)
    }

    /// Delete chosen from the context menu: remove the row from the
    /// live panel (folder rows close their open child first), shrink
    /// the panel keeping its TOP edge fixed, and report upward so the
    /// next panel-open filters it out. Separators / section headers
    /// don't travel with the row (same as DnD sort) — the next open
    /// rebuilds them against the filtered tree.
    private func handleDelete(row: ItemRow, nodeID: String) {
        if childAnchor === row { closeChild() }
        if let stack = row.superview as? NSStackView {
            stack.removeArrangedSubview(row)
            row.removeFromSuperview()
            if let content = panel.contentView {
                let newHeight = content.fittingSize.height
                let old = panel.frame
                panel.setFrame(NSRect(x: old.minX,
                                      y: old.maxY - newHeight,
                                      width: old.width,
                                      height: newHeight),
                               display: true)
            }
        }
        Log.line("launcher-panel: deleted \"\(row.titleForLog)\" at "
                 + "\"\(PanelTree.displayPath(panelPath))\" (session-only)")
        onDelete?(panelPath, nodeID)
    }

    private func handleRowHover(_ row: ItemRow) {
        switch row.kind {
        case .folder(let name, let children):
            if childAnchor === row { return }  // already open
            closeChild()
            openChild(for: row, children: children, label: row.titleForLog,
                       childPath: PanelTree.childPath(panelPath, name))
        case .dynamic(let item):
            if childAnchor === row { return }
            closeChild()
            let expanded = PanelLayout.expandDynamic(item)
            // childPath nil — dynamic children are synthesized per
            // hover, so there's no stable order to override.
            openChild(for: row, children: expanded,
                       label: "\(row.titleForLog) (dynamic)")
        case .leaf, .placeholder:
            // Moved to a non-folder row → close any open child. The
            // user's cursor is now committed to this level.
            closeChild()
        case .header, .sectionHeader:
            // Headers are non-interactive, but if somehow hovered we
            // don't want to mess with the child state.
            break
        }
    }

    // MARK: Child management

    private func openChild(for row: ItemRow, children: [PanelNode],
                            label: String, childPath: String? = nil) {
        guard let win = row.window else {
            Log.line("launcher-panel: openChild: row has no window — skip")
            return
        }
        let rowInWin = row.convert(row.bounds, to: nil)
        let rowOnScreen = win.convertToScreen(rowInWin)
        // Children are always vertical lists regardless of the
        // parent's layout — a horizontal grandchild from a toolbar's
        // submenu would feel chaotic, and submenus typically benefit
        // from rows-with-labels anyway.
        let petScale = max(1.0, CGFloat(fontSize) / 13.0)
        let outerMargin: CGFloat = linePets.isEmpty
            ? 0 : round(14 * petScale)
        let (content, rows) = PanelLayout.buildContent(
            nodes: children, header: nil, layout: .list,
            fontSize: fontSize,
            colors: colors,
            outerMargin: outerMargin)
        let frame = PanelLayout.placeChild(
            rowFrameOnScreen: rowOnScreen,
            parentPanelFrame: panel.frame,
            parentLayout: layout,
            contentSize: content.fittingSize)
        let c = PanelController(
            content: content, rows: rows, frame: frame,
            layout: .list,
            target: target, onSelect: onSelect,
            isRoot: false,
            panelPath: childPath ?? "",
            onReorder: childPath == nil ? nil : onReorder,
            themeName: themeName,
            onDelete: childPath == nil ? nil : onDelete,
            openAnim: openAnim,
            closeAnim: closeAnim,
            border: border,
            borderCycleMs: borderCycleMs,
            borderWidth: borderWidth,
            shadow: shadow,
            linePets: linePets,
            fontSize: fontSize,
            colors: colors)
        c.parent = self
        child = c
        childAnchor = row
        c.show()
        Log.line("launcher-panel: opened submenu \"\(label)\" "
                 + "(\(children.count) items)")
    }

    private func closeChild() {
        child?.tearDown()
        child = nil
        childAnchor = nil
    }

    // MARK: Dismiss monitors (root only)

    private func installDismissMonitors() {
        // Global monitor (other-app events). Because wand is
        // LSUIElement + the panel is non-activating, "another app" is
        // effectively every app — so a click anywhere outside our
        // panels routes here. We deliberately DON'T install a local
        // monitor for clicks inside any panel — rows handle those via
        // their own mouseUp.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown]
        ) { [weak self] ev in
            // 53 = kVK_Escape. The underlying editor still receives
            // the Esc (global monitor doesn't consume), so Esc-as-
            // vim-mode-exit etc. still work. Acceptable trade.
            if ev.keyCode == 53 {
                Task { @MainActor in self?.dismiss() }
            }
        }
    }
}


// MARK: - Chomp line-pet overlay

/// Click-through view that paints one or more chomp "pets"
/// (`chomp`, `ghost`) walking the panel's rounded outline. Pets
/// share a single 60 fps timer so the rim doesn't accumulate
/// independent animation loops. Each pet's centre traces `bgFrame`
/// directly; the configured outer margin gives them room to spill
/// past the border. The leader is at the live time `t`; subsequent
/// pets trail by a fixed gap (28 pt) so they read as a chase rather
/// than evenly spaced.
@MainActor
private final class TomePetsView: NSView {
    private let startedAt: CFTimeInterval = CACurrentMediaTime()
    private let bgFrameInView: CGRect
    private let cornerRadius: CGFloat
    private let pets: [LinePet]
    /// Scale factor multiplied into every pet's geometry (pellet
    /// radius / ghost dimensions) and the chase gap. Derived from
    /// `[tome.row].font-size` so a larger panel gets proportionally
    /// larger pets — without this, the ghost shrinks visually as the
    /// panel grows.
    private let petScale: CGFloat
    private var timer: Timer?

    /// Travel speed of the chase along the rim. A typical panel
    /// (~250 × 200 pt → perimeter ~900 pt) completes a lap in 5-6 s
    /// at 160 pt/s. Speed stays constant across `petScale` — a
    /// larger pet at the same pt/s reads as "the same pet, just
    /// bigger", not as a slower one.
    private static let petSpeedPtPerSec: CGFloat = 160

    init(frame: NSRect, bgFrameInView: CGRect,
         cornerRadius: CGFloat, pets: [LinePet],
         petScale: CGFloat) {
        self.bgFrameInView = bgFrameInView
        self.cornerRadius = cornerRadius
        self.pets = pets
        self.petScale = petScale
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        translatesAutoresizingMaskIntoConstraints = true
        // 60 fps. Timer holds the block, block captures self weakly
        // — no retain cycle.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60,
                                      repeats: true) { [weak self] _ in
            Task { @MainActor in self?.needsDisplay = true }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Stop the redraw timer when the view leaves its window — covers
    /// panel dismissal cleanly. (`deinit` would have crossed the
    /// main-actor isolation boundary.)
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            timer?.invalidate()
            timer = nil
        }
    }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let now = CACurrentMediaTime() - startedAt
        // Shared sill drawing. The tome rim runs a brisker 160 pt/s and a
        // looser 28*petScale chase than the cast card's defaults; both are
        // passed explicitly so the dedup preserves the prior look exactly.
        drawLinePets(pets, on: bgFrameInView, now: now, scale: petScale,
                     speed: Self.petSpeedPtPerSec, chaseGap: 28 * petScale)
    }

}

// MARK: - Row view

/// One row's visual + behavioural kind. `header` is the app-icon
/// banner at top of the root panel; `placeholder` is a disabled row
/// (e.g. "(no items)" inside a dynamic expansion's error path);
/// `leaf` fires onSelect; `folder` opens a child panel on hover with
/// the precomputed children; `dynamic` opens a child panel on hover
/// with children produced by `PanelLayout.expandDynamic` at hover
/// time (i.e. the shell runs only when the user actually opens the
/// submenu).
private enum RowKind {
    case header
    /// Inline section header — a labelled band drawn above a run of
    /// items whose `LauncherItem.header` shares a value. Distinct from
    /// `.header` (which is the app-icon banner pinned at the top of
    /// the root panel). Non-interactive, smaller height, only used in
    /// `.list` layout.
    case sectionHeader(String)
    case placeholder
    case leaf(LauncherItem)
    case folder(name: String, children: [PanelNode])
    case dynamic(LauncherItem)
}

/// One clickable launcher row. Custom NSView whose layout depends on
/// `layout`:
///
/// - `.list` — fixed-height horizontal strip: icon left, label
///   filling the rest, optional chevron right (for folder/dynamic).
///   Width is set by the panel (constraint to `contentWidth`); hover
///   highlight fills the row corner-to-corner.
/// - `.toolbar` — square icon-only button. Label rendered as a
///   `toolTip` (system shows on hover after a short delay). No
///   chevron in `.toolbar` even for folder/dynamic — the hover
///   behaviour itself signals expandability, and a chevron in a
///   tiny button reads as noise.
///
/// Either way, hover state machine + click handler are identical:
/// `onHover` fires on mouseEntered, `onClick` on mouseUp. The
/// controller decides what the events mean based on `kind`.
@MainActor
private final class ItemRow: NSView {

    let kind: RowKind
    let layout: LauncherLayout
    /// Session DnD sort identity (`PanelNode.orderID`, threaded in at
    /// build time so rows and nodes can't drift apart). `nil` for
    /// header / section-header / placeholder rows — they never drag.
    let nodeID: String?
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    /// Theme-resolved colours. Defaults to `.none` (every field nil →
    /// system colours). The panel re-applies these after building the
    /// row tree via `applyTheme(_:)`, which kicks `applyIdleStyle` so
    /// theme-tinted idle text takes effect before first paint.
    private var themeColors: TomeColors = .none

    /// Per-row random splatoon ink rolled once when the theme is
    /// applied. Non-nil only under `[tome].theme = "splatoon"` —
    /// every row picks its own colour, and that colour stays put
    /// across every hover until the panel is dismissed (new rows
    /// = new rolls on the next panel-open). When `nil`, the
    /// hover style falls back to `themeColors.accent`.
    private var rowAccent: NSColor?

    func applyTheme(_ colors: TomeColors) {
        themeColors = colors
        rowAccent = colors.accentRandomSplatoon
            ? NSColorParse.randomSplatoonInk()
            : nil
        applyIdleStyle()
    }

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private var chevronView: NSImageView?
    /// Right-edge "⌘W"-style display string, derived from the item's
    /// `action-keys` by `KeyCombo.format` when this row was built.
    /// Empty for non-`.key` actions, toolbar layouts, or when the
    /// global `[launcher].shortcut-badge = false`. Rendered as a
    /// muted-grey label inside `installListLayout` only.
    private let shortcutText: String
    private var shortcutField: NSTextField?
    /// Optional second line under the title. Empty = single-line row
    /// (the existing `listRowHeight`); non-empty bumps the row to
    /// `listRowHeightWithSubtitle` and shows a muted-grey caption.
    /// Toolbar variants ignore this — the `makeItemRow` factory only
    /// passes a non-empty value when `layout == .list`.
    private let subtitleText: String
    private var subtitleField: NSTextField?
    /// SF Symbol animation kind ("bounce" / "pulse" / empty), fired on
    /// `mouseEntered`. macOS 14+ only; older OS silently ignores.
    /// Empty (default) means static icon.
    private let iconAnim: String
    /// Title font size (points). Scales the row's icon size and
    /// height proportionally — the row reads at the user's preferred
    /// text scale rather than truncating. Default 13 matches macOS'
    /// menu baseline; `[tome.row].font-size` overrides it.
    private let fontSize: CGFloat
    /// Per-instance scale factor against the baseline (13 pt). Used
    /// to derive icon box, row height, and `iconRenderPt` so the
    /// whole row grows or shrinks coherently.
    private var fontScale: CGFloat { fontSize / 13.0 }
    /// Bounding box in points for the icon view. The actual rendered
    /// SF Symbol is sized to `iconRenderPt` and scaled `.large`, so it
    /// fills the box optically.
    private var iconSize: CGFloat { round(17 * fontScale) }
    /// Baseline icon render size in points (font-size 13). Non-row
    /// icon callers like the panel header use this directly.
    static let iconRenderPt: CGFloat = IconResolver.baselinePt
    /// Per-row scaled equivalent. Callers with a live row's
    /// `fontSize` in hand pass it here so the icon column scales
    /// with the rest of the row.
    static func iconRenderPt(forFontSize pt: Int) -> CGFloat {
        IconResolver.pt(forFontSize: pt)
    }
    private var listRowHeight: CGFloat { round(26 * fontScale) }
    /// Taller row variant for items that supply a non-empty subtitle.
    /// Scales with `fontSize` like the single-line variant so a tall
    /// `font-size` panel keeps captioned rows proportional to plain
    /// rows.
    private var listRowHeightWithSubtitle: CGFloat {
        round(38 * fontScale)
    }
    /// Section-header band height. Just enough to breathe a small-caps
    /// 10pt label without the band dominating the panel.
    private static let sectionHeaderHeight: CGFloat = 22
    private static let toolbarButtonSide: CGFloat = 34
    /// Height of the labeled-toolbar "pill" button. Tall enough to
    /// breathe with the 17pt icon + menu font, short enough to read
    /// as a chip rather than a row.
    private static let labeledPillHeight: CGFloat = 28
    private static let idleCornerRadius: CGFloat = 4
    private static let hoverCornerRadius: CGFloat = 5

    private let rawLabel: String

    /// Friendly name for `/tmp/wand.log`. In toolbar mode the label
    /// isn't rendered, so we keep the raw string around for logs.
    var titleForLog: String { rawLabel }

    init(kind: RowKind, label: String, icon: NSImage?,
         layout: LauncherLayout, shortcut: String = "",
         subtitle: String = "", iconAnim: String = "",
         iconSpec: String = "",
         fontSize: Int = 13,
         nodeID: String? = nil) {
        self.kind = kind
        self.layout = layout
        self.nodeID = nodeID
        self.rawLabel = label
        self.shortcutText = shortcut
        self.subtitleText = subtitle
        self.iconAnim = iconAnim
        self.fontSize = CGFloat(fontSize)
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Self.idleCornerRadius

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = icon
        addSubview(iconView)

        // Remote-icon async swap — when the row was constructed with
        // a spec that resolved to a placeholder pending a network
        // fetch (`favicon:<host>` → SF:globe, or `lucide:<name>` /
        // `phosphor:` / `tabler:` / `heroicons:` → SF:square.dashed),
        // kick off the download and update `iconView.image` in
        // place once it lands. Cache hits are already handled
        // synchronously by `IconResolver`, so this path only fires
        // on the very first sight (or after a 24 h disk-cache
        // expiry). Resize on swap matches the resize the
        // synchronous path applies.
        let pt = IconResolver.pt(forFontSize: Int(self.fontSize))
        if iconSpec.hasPrefix("favicon:"),
           let host = FaviconCache.host(from: iconSpec) {
            FaviconCache.shared.loadOrFetch(host: host) { [weak self] img in
                guard let self = self, let img = img else { return }
                img.size = NSSize(width: pt, height: pt)
                self.iconView.image = img
            }
        } else if IconSetCache.matches(iconSpec) {
            IconSetCache.shared.loadOrFetch(spec: iconSpec) { [weak self] img in
                guard let self = self, let img = img else { return }
                img.size = NSSize(width: pt, height: pt)
                self.iconView.image = img
            }
        }

        // Section headers get their own compact layout (no icon, smaller
        // font, shorter row). Everything else goes through the
        // layout-specific installer.
        if case .sectionHeader = kind {
            iconView.isHidden = true
            installSectionHeaderLayout(label: label)
        } else {
            switch layout {
            case .list:           installListLayout(label: label)
            case .toolbar:        installToolbarLayout(label: label)
            case .labeledToolbar: installLabeledToolbarLayout(label: label)
            }
        }

        applyIdleStyle()
    }

    /// Compact band: smaller height, no icon column, 10pt semibold
    /// uppercased label hugging the left edge. Used by `.sectionHeader`
    /// rows to split a long `.list` panel into labelled groups without
    /// stealing space from the items themselves.
    private func installSectionHeaderLayout(label: String) {
        titleField.translatesAutoresizingMaskIntoConstraints = false
        // Uppercase + small-cap weight reads as a band rather than a
        // row title. Falls back gracefully on locales where uppercase
        // is a no-op (Japanese / CJK section names still render as
        // their original glyphs).
        titleField.stringValue = label.uppercased()
        titleField.font = .systemFont(ofSize: 10, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.cell?.usesSingleLineMode = true
        addSubview(titleField)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.sectionHeaderHeight),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor,
                                                  constant: 10),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor,
                                                  constant: -10),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func installListLayout(label: String) {
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.stringValue = label
        titleField.font = .menuFont(ofSize: fontSize)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.cell?.usesSingleLineMode = true
        addSubview(titleField)

        var titleTrailingAnchor = trailingAnchor
        var titleTrailingConst: CGFloat = -10

        let needsChevron: Bool = {
            switch kind {
            case .folder, .dynamic: return true
            case .header, .sectionHeader, .placeholder, .leaf: return false
            }
        }()

        if needsChevron {
            let cv = NSImageView()
            cv.translatesAutoresizingMaskIntoConstraints = false
            cv.image = NSImage(systemSymbolName: "chevron.right",
                                accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    .init(pointSize: 9, weight: .semibold))
            cv.contentTintColor = .secondaryLabelColor
            cv.imageScaling = .scaleProportionallyDown
            addSubview(cv)
            NSLayoutConstraint.activate([
                cv.trailingAnchor.constraint(equalTo: trailingAnchor,
                                              constant: -8),
                cv.centerYAnchor.constraint(equalTo: centerYAnchor),
                cv.widthAnchor.constraint(equalToConstant: 10),
                cv.heightAnchor.constraint(equalToConstant: 10),
            ])
            chevronView = cv
            titleTrailingAnchor = cv.leadingAnchor
            titleTrailingConst = -6
        } else if !shortcutText.isEmpty {
            // Shortcut glyph badge — purely cosmetic, mirrors native
            // NSMenu's right-aligned ⌘W next to a row. Sits where the
            // chevron would, with a muted colour so the row title
            // still reads as the primary content.
            let sf = NSTextField(labelWithString: shortcutText)
            sf.translatesAutoresizingMaskIntoConstraints = false
            sf.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            sf.textColor = .tertiaryLabelColor
            sf.alignment = .right
            sf.lineBreakMode = .byTruncatingTail
            sf.maximumNumberOfLines = 1
            sf.cell?.usesSingleLineMode = true
            addSubview(sf)
            NSLayoutConstraint.activate([
                sf.trailingAnchor.constraint(equalTo: trailingAnchor,
                                              constant: -10),
                sf.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            shortcutField = sf
            titleTrailingAnchor = sf.leadingAnchor
            titleTrailingConst = -8
        }

        // Subtitle-aware vertical layout. Without a subtitle the row
        // stays single-line at `listRowHeight` and the title sits on
        // the centre Y. With a subtitle the row grows to
        // `listRowHeightWithSubtitle`; the title hangs from the top
        // and the muted-grey subtitle hangs below it, while the icon
        // stays centred so the visual baseline doesn't drift.
        let hasSubtitle = !subtitleText.isEmpty
        let rowHeight: CGFloat = hasSubtitle
            ? listRowHeightWithSubtitle : listRowHeight

        var verticalConstraints: [NSLayoutConstraint] = []
        if hasSubtitle {
            let sub = NSTextField(labelWithString: subtitleText)
            sub.translatesAutoresizingMaskIntoConstraints = false
            sub.font = .systemFont(ofSize: 11)
            sub.textColor = .secondaryLabelColor
            sub.lineBreakMode = .byTruncatingTail
            sub.maximumNumberOfLines = 1
            sub.cell?.usesSingleLineMode = true
            addSubview(sub)
            subtitleField = sub
            verticalConstraints = [
                titleField.topAnchor.constraint(equalTo: topAnchor,
                                                  constant: 4),
                sub.topAnchor.constraint(equalTo: titleField.bottomAnchor,
                                          constant: 1),
                sub.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
                sub.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            ]
        } else {
            verticalConstraints = [
                titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: rowHeight),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: iconSize),
            iconView.heightAnchor.constraint(equalToConstant: iconSize),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor,
                                                constant: 8),
            titleField.trailingAnchor.constraint(equalTo: titleTrailingAnchor,
                                                  constant: titleTrailingConst),
        ] + verticalConstraints)
    }

    private func installToolbarLayout(label: String) {
        // Tooltip: system shows on hover after a built-in delay. No
        // on-screen label, no chevron — the button is purely the
        // icon's bounding box.
        toolTip = label
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.toolbarButtonSide),
            heightAnchor.constraint(equalToConstant: Self.toolbarButtonSide),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: iconSize + 2),
            iconView.heightAnchor.constraint(equalToConstant: iconSize + 2),
        ])
    }

    private func installLabeledToolbarLayout(label: String) {
        // Horizontal "pill" button: icon left, label right. Same
        // tooltip as icon-only toolbar so a user hovering still gets
        // the full name on accessibility readers. Width is intrinsic
        // — the stack lets each pill size to its label.
        toolTip = label

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.stringValue = label
        titleField.font = .menuFont(ofSize: fontSize)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.cell?.usesSingleLineMode = true
        addSubview(titleField)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.labeledPillHeight),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: iconSize),
            iconView.heightAnchor.constraint(equalToConstant: iconSize),

            titleField.leadingAnchor.constraint(
                equalTo: iconView.trailingAnchor, constant: 6),
            titleField.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -10),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var isInteractive: Bool {
        switch kind {
        case .leaf, .folder, .dynamic: return true
        case .header, .sectionHeader, .placeholder: return false
        }
    }

    private func applyIdleStyle() {
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = Self.idleCornerRadius
        // Theme idle text overrides only the regular interactive row
        // text — headers / section bands / placeholders keep their
        // quieter system semantics so the visual hierarchy survives.
        let themedText = themeColors.text
        switch kind {
        case .header:
            titleField.textColor = .secondaryLabelColor
        case .sectionHeader:
            titleField.textColor = .tertiaryLabelColor
        case .placeholder:
            titleField.textColor = .tertiaryLabelColor
        case .leaf, .folder, .dynamic:
            titleField.textColor = themedText ?? .labelColor
        }
        subtitleField?.textColor = .secondaryLabelColor
        shortcutField?.textColor = .tertiaryLabelColor
        chevronView?.contentTintColor = .secondaryLabelColor
        // Toolbar variants: tint SF Symbol icons in `.labelColor`
        // so they read as text-level contrast rather than the
        // default grey. No effect on .icns / emoji rendered icons.
        if layout != .list {
            iconView.contentTintColor = isInteractive
                ? (themedText ?? .labelColor) : .tertiaryLabelColor
        }
    }

    private func applyHoverStyle() {
        // Fully-opaque accent so the hovered row reads as THE
        // selection target, with no risk of being washed out by the
        // vibrancy underneath. Under the splatoon theme each row
        // carries its own ink (`rowAccent`) rolled in `applyTheme`,
        // and that ink stays stable until the panel closes — only
        // the next panel-open rerolls. Text colour adapts to the
        // row's ink luma when the palette didn't pin a value.
        let accent = rowAccent ?? themeColors.accent ?? .controlAccentColor
        let accentText: NSColor
        if let ink = rowAccent {
            accentText = themeColors.accentText ?? TomeColors.legibleText(on: ink)
        } else {
            accentText = themeColors.accentText ?? .white
        }
        layer?.backgroundColor = accent.cgColor
        layer?.cornerRadius = Self.hoverCornerRadius
        titleField.textColor = accentText
        chevronView?.contentTintColor = accentText
        // Subtitle / shortcut badges share the row with the title, so
        // they flip alongside it — otherwise muted greys read as
        // smudged on the accent fill. Use 85% alpha for the same
        // visual hierarchy idle had with `secondary` / `tertiary`.
        subtitleField?.textColor = accentText.withAlphaComponent(0.85)
        shortcutField?.textColor = accentText.withAlphaComponent(0.85)
        if layout != .list {
            iconView.contentTintColor = accentText
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas { removeTrackingArea(ta) }
        // `.activeAlways` is mandatory here — wand is LSUIElement +
        // the panel is non-activating, so `.activeInActiveApp` would
        // resolve to "never" and mouseEntered would never fire (which
        // is why hover-to-expand silently failed in the first cut).
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways,
                      .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        guard isInteractive else { return }
        applyHoverStyle()
        playIconAnim()
        onHover?()
    }

    /// Fire the configured SF Symbol effect on the icon. macOS 14+ only —
    /// older OS silently no-ops via the @available guard, so a config
    /// that opts in on a 13.x host still loads and the icon just stays
    /// static. Unknown effect strings log + skip.
    private func playIconAnim() {
        guard !iconAnim.isEmpty, iconView.image != nil else { return }
        if #available(macOS 14, *) {
            switch iconAnim.lowercased() {
            case "bounce":
                iconView.addSymbolEffect(.bounce, options: .nonRepeating,
                                          animated: true)
            case "pulse":
                iconView.addSymbolEffect(.pulse, options: .nonRepeating,
                                          animated: true)
            default:
                Log.line("launcher-panel: unknown icon-anim \"\(iconAnim)\" "
                         + "(supported: bounce, pulse) — skipped")
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        applyIdleStyle()
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        guard isInteractive else { return }
        onClick?()
    }

    // MARK: Session DnD sort (wand#127)

    /// Private in-app pasteboard type marking a tome-row drag. The
    /// payload (the row's `nodeID`) is informational — drop handling
    /// resolves the source row via `draggingSource` identity so
    /// duplicate-named rows can't cross wires.
    static let reorderType =
        NSPasteboard.PasteboardType("com.wand.wand.tome-row")

    /// Set by `PanelController` on reorderable rows only (`.list`
    /// layout + a live `onReorder` sink + non-nil `nodeID`). Fires
    /// with (source row, target row = self, insert-after) when a
    /// drop lands on this row.
    private var reorderDrop: ((ItemRow, ItemRow, Bool) -> Void)?
    /// Button-down point (window coords) armed in `mouseDown`; a
    /// drag past a small hysteresis starts the dragging session.
    /// Cleared on mouseUp so a plain click stays a click.
    private var dragOrigin: NSPoint?
    /// 2 pt accent insertion line shown while a compatible drag
    /// hovers this row — top edge = "insert above", bottom edge =
    /// "insert below". Lazily created, hidden between drags.
    private var dropIndicator: CALayer?

    func enableReorder(
        _ onDrop: @escaping (ItemRow, ItemRow, Bool) -> Void) {
        reorderDrop = onDrop
        registerForDraggedTypes([Self.reorderType])
    }

    /// Set by `PanelController` on deletable rows only (t-k4hf —
    /// `.list` layout, native tome, nodeID rows). `nil` keeps
    /// NSView's default rightMouseDown behaviour.
    private var contextMenuHandler: ((ItemRow, NSEvent) -> Void)?

    func enableContextMenu(_ handler: @escaping (ItemRow, NSEvent) -> Void) {
        contextMenuHandler = handler
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let contextMenuHandler, nodeID != nil else {
            super.rightMouseDown(with: event)
            return
        }
        contextMenuHandler(self, event)
    }

    override func mouseDown(with event: NSEvent) {
        guard reorderDrop != nil else {
            // Non-reorderable rows keep NSView's default next-
            // responder propagation — only drag-source rows hold the
            // event back to arm the hysteresis check.
            super.mouseDown(with: event)
            return
        }
        dragOrigin = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, let nodeID else { return }
        let dx = event.locationInWindow.x - origin.x
        let dy = event.locationInWindow.y - origin.y
        guard dx * dx + dy * dy > 16 else { return }  // 4 pt hysteresis
        dragOrigin = nil
        let pb = NSPasteboardItem()
        pb.setString(nodeID, forType: Self.reorderType)
        let item = NSDraggingItem(pasteboardWriter: pb)
        item.setDraggingFrame(bounds, contents: snapshotImage())
        beginDraggingSession(with: [item], event: event, source: self)
    }

    /// Row snapshot used as the drag image, so the user drags a
    /// faithful copy of the row instead of a generic ghost.
    private func snapshotImage() -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        cacheDisplay(in: bounds, to: rep)
        let img = NSImage(size: bounds.size)
        img.addRepresentation(rep)
        return img
    }

    // Destination side — every reorderable row is also a drop target.

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropIndicator(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropIndicator(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideDropIndicator()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        hideDropIndicator()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hideDropIndicator()
        guard let drop = reorderDrop,
              let source = sender.draggingSource as? ItemRow,
              source !== self else { return false }
        drop(source, self, isLowerHalf(sender))
        return true
    }

    private func updateDropIndicator(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard reorderDrop != nil,
              let source = sender.draggingSource as? ItemRow,
              source !== self else {
            hideDropIndicator()
            return []
        }
        showDropIndicator(below: isLowerHalf(sender))
        return .move
    }

    private func hideDropIndicator() {
        dropIndicator?.isHidden = true
    }

    /// Non-flipped view: smaller y = visually lower. Lower half →
    /// insert AFTER (below) this row.
    private func isLowerHalf(_ sender: NSDraggingInfo) -> Bool {
        convert(sender.draggingLocation, from: nil).y < bounds.midY
    }

    private func showDropIndicator(below: Bool) {
        let line: CALayer
        if let existing = dropIndicator {
            line = existing
        } else {
            line = CALayer()
            line.cornerRadius = 1
            line.zPosition = 10
            // Standalone CALayer: kill the implicit ~0.25 s
            // animations, or the line eases behind every drag-move
            // event instead of tracking the cursor.
            line.actions = ["frame": NSNull(), "position": NSNull(),
                            "bounds": NSNull(), "hidden": NSNull(),
                            "backgroundColor": NSNull()]
            layer?.addSublayer(line)
            dropIndicator = line
        }
        // Same accent resolution as the hover highlight so the two
        // drag affordances agree under a `[tome].theme`.
        let accent = rowAccent ?? themeColors.accent ?? .controlAccentColor
        line.backgroundColor = accent.cgColor
        line.frame = CGRect(x: 4, y: below ? 0 : bounds.height - 2,
                            width: bounds.width - 8, height: 2)
        line.isHidden = false
    }
}

// NSDraggingSource — nonisolated to satisfy the protocol regardless
// of the SDK's isolation annotations; AppKit calls these on the main
// thread, so `assumeIsolated` is safe where row state is touched.
extension ItemRow: NSDraggingSource {
    nonisolated func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     willBeginAt screenPoint: NSPoint) {
        MainActor.assumeIsolated { alphaValue = 0.5 }
    }

    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     endedAt screenPoint: NSPoint,
                                     operation: NSDragOperation) {
        // Restore idle style too: the drag session swallows mouse
        // events, so the tracking area's mouseExited never fires and
        // the source row would otherwise keep its hover accent.
        MainActor.assumeIsolated {
            alphaValue = 1
            applyIdleStyle()
        }
    }
}
