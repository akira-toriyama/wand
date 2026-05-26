// The launcher UI surface. A non-activating NSPanel that does NOT
// take keyboard focus from the underlying app — the user keeps typing
// in their editor while picking an item with the mouse (PopClip
// parity). Used for both the native middle-click trigger and the
// `wand --show-menu` external trigger.
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

import AppKit
import Foundation
import WandCore

@MainActor
public enum LauncherPanel {

    /// Strong reference holder for the currently-visible root panel.
    /// Replaced when a new panel opens; cleared in `dismiss()`.
    private static var current: PanelController?

    public static func present(filteredItems items: [LauncherItem],
                                target: Target,
                                cocoaPoint: NSPoint,
                                onSelect: @escaping (LauncherItem, Target) -> Void) {
        current?.dismiss()
        guard !items.isEmpty else {
            Log.line("launcher-panel: no items for \(target.bundleID) — "
                     + "panel suppressed")
            return
        }
        let nodes = PanelTree.build(from: items)
        let header = makeHeader(for: target)
        let controller = PanelController(
            nodes: nodes,
            header: header,
            anchor: cocoaPoint,
            target: target,
            onSelect: onSelect,
            isRoot: true,
            onDismissRoot: { current = nil })
        current = controller
        controller.show()
    }

    private static func makeHeader(for target: Target) -> HeaderSpec? {
        let (name, icon) = AppIconCache.shared.lookup(
            bundleID: target.bundleID, iconSize: 16)
        if name.isEmpty && icon == nil { return nil }
        return HeaderSpec(name: name, icon: icon)
    }
}

/// One non-leaf or leaf node in the panel tree. Built from the flat
/// `[LauncherItem]` list by `PanelTree.build`. `separatorBefore` is
/// carried on `.item` only — folder nodes don't need it because each
/// item that opens a new section keeps its own flag.
indirect enum PanelNode {
    case item(LauncherItem)
    case folder(name: String, children: [PanelNode])
}

/// App-header data flowed into the root panel.
private struct HeaderSpec {
    let name: String
    let icon: NSImage?
}

/// Convert `[LauncherItem]` → `[PanelNode]`. Walks each item's `group`
/// path, creating folders on first reference and appending into them
/// on subsequent ones — same shape as `LauncherMenu.resolveParent`,
/// but produces an immutable tree instead of mutating NSMenus.
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
    private let nodes: [PanelNode]
    private let target: Target
    private let onSelect: (LauncherItem, Target) -> Void
    private let isRoot: Bool
    /// Root-only: cleared in `dismiss()`, called once when the entire
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

    init(nodes: [PanelNode],
         header: HeaderSpec? = nil,
         anchor: NSPoint,
         anchorIsRow: Bool = false,
         target: Target,
         onSelect: @escaping (LauncherItem, Target) -> Void,
         isRoot: Bool,
         onDismissRoot: (() -> Void)? = nil) {
        self.nodes = nodes
        self.target = target
        self.onSelect = onSelect
        self.isRoot = isRoot
        self.onDismissRoot = isRoot ? onDismissRoot : nil

        let content = NSView()
        let rows = PanelController.buildRows(nodes: nodes, header: header,
                                              into: content)
        let size = content.fittingSize
        let raw = anchorIsRow
            // For child panels: `anchor` is the top-left where the
            // child should appear (Cocoa screen coords). Panel's
            // bottom-left = anchor.x, anchor.y - height.
            ? NSRect(origin: NSPoint(x: anchor.x, y: anchor.y - size.height),
                     size: size)
            // For the root panel: `anchor` is the cursor. Same as
            // NSMenu.popUp's anchor: top-left of panel = cursor.
            : NSRect(origin: NSPoint(x: anchor.x, y: anchor.y - size.height),
                     size: size)
        let placed = PanelController.clampToScreen(raw, anchor: anchor)

        self.panel = NonActivatingPanel(
            contentRect: placed,
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
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = content

        // Wire row callbacks now that `self` exists. Each row reports
        // its hover and click events back to this controller; the
        // controller decides what they mean (open child / dismiss /
        // fire action).
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
    }

    func show() {
        panel.orderFront(nil)
        if isRoot { installDismissMonitors() }
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
        // Depth-first: close grandchild → child → self.
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
        panel.orderOut(nil)
        onDismissRoot?()
    }

    // MARK: - Row callbacks

    private func handleRowClick(_ row: ItemRow) {
        switch row.kind {
        case .leaf(let item):
            onSelect(item, target)
            dismiss()
        case .folder, .header, .placeholder:
            break  // folders open on hover, not click
        }
    }

    private func handleRowHover(_ row: ItemRow) {
        switch row.kind {
        case .folder(_, let children):
            if childAnchor === row { return }  // already open for this row
            closeChild()
            openChild(for: row, children: children)
        case .leaf, .header, .placeholder:
            // Moved to a non-folder row in this panel — close any open
            // child. The user's cursor is now committed to the current
            // panel's level.
            closeChild()
        }
    }

    // MARK: - Child management

    private func openChild(for row: ItemRow, children: [PanelNode]) {
        guard let win = row.window else { return }
        // Compute top-right of row in screen coords. The child's
        // top-left will sit there (no gap → cursor moves smoothly into
        // the child without crossing dead space).
        let rowInWin = row.convert(row.bounds, to: nil)
        let rowOnScreen = win.convertToScreen(rowInWin)
        let topRight = NSPoint(x: rowOnScreen.maxX, y: rowOnScreen.maxY)
        let c = PanelController(
            nodes: children,
            anchor: topRight,
            anchorIsRow: true,
            target: target,
            onSelect: onSelect,
            isRoot: false)
        c.parent = self
        // Flip horizontally if the child would fall off the right
        // edge of the screen — try opening to the left of the parent.
        c.maybeFlipLeftOfParent(parentRow: row)
        child = c
        childAnchor = row
        c.show()
    }

    private func closeChild() {
        child?.tearDown()
        child = nil
        childAnchor = nil
    }

    /// Called by the parent after init when the placed child runs off
    /// the right edge. We use the parent's panel frame to flip across.
    private func maybeFlipLeftOfParent(parentRow: ItemRow) {
        guard let parent else { return }
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSPoint(x: panel.frame.midX, y: panel.frame.midY))
        }) ?? NSScreen.main else { return }
        if panel.frame.maxX > screen.visibleFrame.maxX {
            // Flip: child's right edge at parent's left edge.
            let parentLeft = parent.panel.frame.minX
            var f = panel.frame
            f.origin.x = parentLeft - f.width
            if f.origin.x < screen.visibleFrame.minX {
                f.origin.x = screen.visibleFrame.minX
            }
            panel.setFrame(f, display: false)
        }
        _ = parentRow  // reserved for fine vertical alignment later
    }

    // MARK: - Dismiss monitors (root only)

    private func installDismissMonitors() {
        // Global monitor (other-app events). Because wand is
        // LSUIElement + the panel is non-activating, "another app" is
        // effectively every app — including our own underlying
        // target. So a click anywhere outside our panels routes here.
        // We deliberately DON'T install a local monitor for clicks
        // inside any panel — rows handle those via their own action.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown]
        ) { [weak self] ev in
            // 53 = kVK_Escape. The underlying editor still receives
            // the Esc (global monitor doesn't consume), so the user's
            // Esc-as-vim-mode-exit still works. Acceptable trade.
            if ev.keyCode == 53 {
                Task { @MainActor in self?.dismiss() }
            }
        }
    }

    // MARK: - Content building

    /// Panel internal width target. Wide enough for typical
    /// breadcrumbed labels without wrapping; narrow enough not to feel
    /// like a dialog. Each row constrains to this so right edges align
    /// and the hover highlight is rectangular.
    static let contentWidth: CGFloat = 240

    /// Build the row views into `content` (NSVisualEffectView wrapper)
    /// and return the row list so the caller can wire callbacks.
    private static func buildRows(nodes: [PanelNode],
                                   header: HeaderSpec?,
                                   into content: NSView) -> [ItemRow] {
        let bg = NSVisualEffectView()
        bg.material = .menu
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 8
        bg.layer?.masksToBounds = true
        bg.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)
        stack.translatesAutoresizingMaskIntoConstraints = false

        var rows: [ItemRow] = []
        var views: [NSView] = []

        if let h = header {
            let hr = ItemRow(kind: .header, label: h.name, icon: h.icon)
            rows.append(hr)
            views.append(hr)
            views.append(makeSeparator())
        }

        for node in nodes {
            switch node {
            case .item(let item):
                if item.separatorBefore && !views.isEmpty {
                    views.append(makeSeparator())
                }
                views.append(makeItemRow(item, into: &rows))
            case .folder(let name, let children):
                views.append(makeFolderRow(name: name, children: children,
                                            into: &rows))
            }
        }

        for v in views {
            stack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        }

        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: bg.topAnchor),
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])

        content.addSubview(bg)
        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: content.topAnchor),
            bg.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bg.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        content.frame = NSRect(origin: .zero, size: stack.fittingSize)
        return rows
    }

    private static func makeItemRow(_ item: LauncherItem,
                                     into rows: inout [ItemRow]) -> NSView {
        if !item.dynamic.isEmpty {
            // Dynamic items aren't supported in panel mode yet —
            // expanding them would mean rendering a child panel
            // populated by shell output, which is out of MVP scope.
            // Show a disabled placeholder so the user notices instead
            // of wondering why their dynamic item silently vanished.
            let r = ItemRow(
                kind: .placeholder,
                label: "\(item.name) (dynamic — N/A in panel)",
                icon: nil)
            rows.append(r)
            return r
        }
        let label = renderItemLabel(item)
        let icon = item.icon.isEmpty
            ? nil
            : resolveItemIcon(item.icon)
        let r = ItemRow(kind: .leaf(item), label: label, icon: icon)
        rows.append(r)
        return r
    }

    /// Item-icon resolution. See `LauncherItem.icon` for the
    /// recognised forms. Returns nil (which collapses to no image on
    /// the row) on miss; logs once so a typo is visible in
    /// `/tmp/wand.log` without spamming every popup.
    static func resolveItemIcon(_ spec: String) -> NSImage? {
        let pt: CGFloat = 16

        // SF Symbol prefix.
        if spec.hasPrefix("SF:") {
            let name = String(spec.dropFirst(3))
            let cfg = NSImage.SymbolConfiguration(pointSize: pt,
                                                   weight: .regular)
            guard let img = NSImage(systemSymbolName: name,
                                     accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) else {
                Log.line("launcher-panel: unknown SF Symbol \"\(name)\" "
                         + "in item icon — falling back to no icon")
                return nil
            }
            return img
        }

        // File path — absolute, tilde, or relative to the config dir.
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
            let path = resolveIconPath(spec)
            guard let img = NSImage(contentsOfFile: path) else {
                Log.line("launcher-panel: could not load item icon "
                         + "from \(path) — falling back to no icon")
                return nil
            }
            img.size = NSSize(width: pt, height: pt)
            return img
        }

        // Text / emoji — draw the glyph into an NSImage.
        return textIcon(spec, pointSize: pt)
    }

    private static func resolveIconPath(_ spec: String) -> String {
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
                                  pointSize pt: CGFloat) -> NSImage? {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: pt * 0.85),
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let measured = attributed.size()
        guard measured.width > 0 && measured.height > 0 else { return nil }
        let size = NSSize(width: pt, height: pt)
        let img = NSImage(size: size)
        img.lockFocus()
        let origin = NSPoint(
            x: (size.width - measured.width) / 2,
            y: (size.height - measured.height) / 2)
        attributed.draw(at: origin)
        img.unlockFocus()
        return img
    }

    private static func makeFolderRow(name: String,
                                       children: [PanelNode],
                                       into rows: inout [ItemRow]) -> NSView {
        let r = ItemRow(kind: .folder(name: name, children: children),
                        label: name, icon: nil)
        rows.append(r)
        return r
    }

    /// Build the row title from the item, folding in state marker.
    /// The group path is consumed by tree-building so it doesn't
    /// appear in the label anymore.
    private static func renderItemLabel(_ item: LauncherItem) -> String {
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

    private static func makeSeparator() -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            wrap.heightAnchor.constraint(equalToConstant: 7),
            line.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor,
                                          constant: 8),
            line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor,
                                           constant: -8),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
        return wrap
    }

    /// Nudge `rect` so it stays on the screen containing `anchor`.
    /// PopClip-style: prefer down-right; if it falls off the bottom or
    /// right, flip / clamp.
    static func clampToScreen(_ rect: NSRect, anchor: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return rect }
        var r = rect
        if r.maxX > visible.maxX { r.origin.x = visible.maxX - r.width }
        if r.minX < visible.minX { r.origin.x = visible.minX }
        if r.minY < visible.minY {
            // Falls off bottom — flip above the cursor instead.
            r.origin.y = anchor.y
            if r.maxY > visible.maxY { r.origin.y = visible.maxY - r.height }
        }
        if r.maxY > visible.maxY { r.origin.y = visible.maxY - r.height }
        return r
    }
}

/// One row's visual + behavioural kind. `header` is the app-icon
/// banner at top of the root panel; `placeholder` is a disabled row
/// (e.g. dynamic-not-supported); `leaf` fires onSelect; `folder` opens
/// a child panel on hover.
private enum RowKind {
    case header
    case placeholder
    case leaf(LauncherItem)
    case folder(name: String, children: [PanelNode])
}

/// One clickable launcher row. Custom NSView containing a fixed-size
/// NSImageView + an NSTextField + an optional chevron, laid out
/// manually so every row has the same height regardless of icon kind
/// (SF Symbol vs emoji glyph vs app .icns). Hover highlight fills the
/// row corner-to-corner.
@MainActor
private final class ItemRow: NSView {

    let kind: RowKind
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private var chevronView: NSImageView?
    private static let iconSize: CGFloat = 16
    private static let rowHeight: CGFloat = 22

    init(kind: RowKind, label: String, icon: NSImage?) {
        self.kind = kind
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 4

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = icon
        addSubview(iconView)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.stringValue = label
        titleField.font = .menuFont(ofSize: 0)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.cell?.usesSingleLineMode = true
        addSubview(titleField)

        var trailingAnchorTarget = trailingAnchor
        var trailingConst: CGFloat = -10

        if case .folder = kind {
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
            trailingAnchorTarget = cv.leadingAnchor
            trailingConst = -6
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.rowHeight),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor,
                                                constant: 8),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchorTarget,
                                                  constant: trailingConst),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        applyIdleStyle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var isInteractive: Bool {
        switch kind {
        case .leaf, .folder: return true
        case .header, .placeholder: return false
        }
    }

    private func applyIdleStyle() {
        layer?.backgroundColor = NSColor.clear.cgColor
        switch kind {
        case .header:
            titleField.textColor = .secondaryLabelColor
        case .placeholder:
            titleField.textColor = .tertiaryLabelColor
        case .leaf, .folder:
            titleField.textColor = .labelColor
        }
        chevronView?.contentTintColor = .secondaryLabelColor
    }

    private func applyHoverStyle() {
        layer?.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(0.85).cgColor
        titleField.textColor = .white
        chevronView?.contentTintColor = .white
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas { removeTrackingArea(ta) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp,
                      .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        guard isInteractive else { return }
        applyHoverStyle()
        onHover?()
    }

    override func mouseExited(with event: NSEvent) {
        applyIdleStyle()
    }

    override func mouseUp(with event: NSEvent) {
        guard isInteractive else { return }
        onClick?()
    }
}
