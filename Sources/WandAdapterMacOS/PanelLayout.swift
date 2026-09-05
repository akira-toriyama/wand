// Content-view construction + screen-aware frame placement for one
// tome panel level: rows, icons, dynamic-item expansion, labels, and
// the state resolver. Builds views; owns no state between calls.

import AppKit
import WandCore

/// Content-view construction + screen-aware frame placement. Pulled
/// out of `PanelController` so the init becomes a thin wire-up step
/// instead of a multi-stage builder.
@MainActor
enum PanelLayout {

    /// Panel internal width target. Wide enough for typical
    /// breadcrumbed labels without wrapping; narrow enough not to feel
    /// like a dialog.
    static let contentWidth: CGFloat = 240
    static let cornerRadius: CGFloat = 8

    static func makeHeaderSpec(for target: Target) -> HeaderSpec? {
        let (name, icon) = AppIconCache.shared.lookup(
            bundleID: target.bundleID, iconSize: ItemRow.iconRenderPt)
        if name.isEmpty && icon == nil { return nil }
        return HeaderSpec(name: name, icon: icon)
    }

    /// Returns the row list alongside the view: the caller owns row
    /// callback wiring, so the rows have to survive the build.
    static func buildContent(nodes: [PanelNode],
                              header: HeaderSpec?,
                              layout: TomeLayout,
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

        // Section headers only fire in list mode — toolbar variants
        // are short horizontal strips where a header band would
        // dominate the panel — and only on `.item` nodes (folders /
        // placeholders pass through without disturbing the section).
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
                            parentLayout: TomeLayout,
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

    private static func makeItemRow(_ item: TomeItem,
                                     nodeID: String?,
                                     layout: TomeLayout,
                                     shortcutBadge: Bool,
                                     iconChip: Bool,
                                     fontSize: Int,
                                     sink rows: inout [ItemRow]) -> NSView {
        if !item.dynamic.isEmpty {
            // Dynamic item — render as a folder-style row that
            // hover-expands into a child panel populated by running
            // `item.dynamic` (see `PanelController.handleRowHover`).
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
        item: TomeItem, layout: TomeLayout, iconChip: Bool,
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
                                       layout: TomeLayout,
                                       fontSize: Int,
                                       sink rows: inout [ItemRow]) -> NSView {
        let r = ItemRow(kind: .folder(name: name, children: children),
                        label: name, icon: nil, layout: layout,
                        fontSize: fontSize, nodeID: nodeID)
        rows.append(r)
        return r
    }

    private static func makePlaceholderRow(label: String,
                                            layout: TomeLayout,
                                            fontSize: Int,
                                            sink rows: inout [ItemRow]) -> NSView {
        let r = ItemRow(kind: .placeholder, label: label, icon: nil,
                         layout: layout, fontSize: fontSize)
        rows.append(r)
        return r
    }

    /// Inline section-header band drawn above a run of items sharing a
    /// `TomeItem.header` value. Non-interactive (no hover / click)
    /// — pure visual separation between groups of related items in
    /// the same panel. Only emitted in `.list` layout.
    private static func makeSectionHeaderRow(name: String,
                                              layout: TomeLayout,
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
    /// `TomeItem` via `item.template`. Errors (timeout, spawn
    /// fail, non-zero exit, empty stdout) become a single
    /// `.placeholder` node so the user always sees something. Called
    /// at hover time, not present time, so the cost is paid only when
    /// the user actually opens the dynamic submenu.
    static func expandDynamic(_ item: TomeItem) -> [PanelNode] {
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

    /// Build one synthetic leaf `TomeItem` from a template + a
    /// stdout line. `{line}` placeholders in the template's name,
    /// icon and payload are substituted. Inherits `apps` from the
    /// parent dynamic item so app-filter behaviour matches.
    /// `{line}` content is untrusted — same caveat as
    /// `WAND_TARGET_TITLE`; template authors must quote it when it
    /// reaches a shell command.
    private static func synthesizeChild(template: TomeTemplate,
                                         line: String,
                                         parent: TomeItem) -> TomeItem {
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
        return TomeItem(
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
    private static func renderItemLabel(_ item: TomeItem,
                                         layout: TomeLayout) -> String {
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

    /// The toolbar branch is unreachable today — `separator-before` is
    /// skipped in toolbar layouts — and is kept only for a future
    /// toolbar section divider.
    private static func makeSeparator(layout: TomeLayout) -> NSView {
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
