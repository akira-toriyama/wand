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
import Foundation
import WandCore

// MARK: - Public entry

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
        let header = PanelLayout.makeHeaderSpec(for: target)
        let (content, rows) = PanelLayout.buildContent(
            nodes: nodes, header: header)
        let frame = PanelLayout.placeRoot(
            atCursor: cocoaPoint, contentSize: content.fittingSize)
        let controller = PanelController(
            content: content, rows: rows, frame: frame,
            target: target, onSelect: onSelect,
            isRoot: true,
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

    /// Build the content view (NSVisualEffectView wrapping a vertical
    /// NSStackView of rows) and return both the view and the row list
    /// so the caller can wire callbacks.
    static func buildContent(nodes: [PanelNode],
                              header: HeaderSpec?)
        -> (view: NSView, rows: [ItemRow]) {
        let bg = NSVisualEffectView()
        bg.material = .menu
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = cornerRadius
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
                views.append(makeItemRow(item, sink: &rows))
            case .folder(let name, let children):
                views.append(makeFolderRow(name: name, children: children,
                                            sink: &rows))
            case .placeholder(let label):
                views.append(makePlaceholderRow(label: label, sink: &rows))
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

        // Wrap bg so the caller has a single NSView to set as the
        // panel's contentView. content is sized from the stack.
        let content = NSView()
        content.addSubview(bg)
        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: content.topAnchor),
            bg.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bg.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        content.frame = NSRect(origin: .zero, size: stack.fittingSize)
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

    /// Frame for a CHILD panel anchored to a folder row in the parent
    /// panel. Prefers "to the right of parent, top aligned with the
    /// hovered row". Flips left of the parent panel if the right side
    /// would clip the screen; clamps vertically if the panel is taller
    /// than the row's distance to the bottom of the screen.
    static func placeChild(rowFrameOnScreen rowFrame: NSRect,
                            parentPanelFrame parent: NSRect,
                            contentSize size: NSSize) -> NSRect {
        let visible = visibleFrame(for: NSPoint(x: rowFrame.maxX,
                                                  y: rowFrame.midY))
        // Default: right of parent, child top = row top.
        var originX = rowFrame.maxX
        if originX + size.width > visible.maxX {
            // Flip to the left of the parent panel (NOT just left of
            // the row — we want the cursor-traversal gap to stay zero
            // on the side we end up on).
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

    private static func visibleFrame(for point: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        return screen?.visibleFrame ?? .zero
    }

    private static func makeItemRow(_ item: LauncherItem,
                                     sink rows: inout [ItemRow]) -> NSView {
        if !item.dynamic.isEmpty {
            // Dynamic item — render as a folder-style row that
            // hover-expands into a child panel populated by running
            // `item.dynamic` (see `PanelController.openDynamicChild`).
            let icon = item.icon.isEmpty
                ? nil
                : resolveItemIcon(item.icon)
            let r = ItemRow(kind: .dynamic(item),
                            label: item.name, icon: icon)
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

    private static func makeFolderRow(name: String,
                                       children: [PanelNode],
                                       sink rows: inout [ItemRow]) -> NSView {
        let r = ItemRow(kind: .folder(name: name, children: children),
                        label: name, icon: nil)
        rows.append(r)
        return r
    }

    private static func makePlaceholderRow(label: String,
                                            sink rows: inout [ItemRow]) -> NSView {
        let r = ItemRow(kind: .placeholder, label: label, icon: nil)
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

    /// Item-icon resolution. See `LauncherItem.icon` for the
    /// recognised forms. Returns nil (which collapses to no image on
    /// the row) on miss; logs once so a typo is visible in
    /// `/tmp/wand.log` without spamming every popup.
    static func resolveItemIcon(_ spec: String) -> NSImage? {
        let pt: CGFloat = ItemRow.iconRenderPt

        // SF Symbol prefix.
        if spec.hasPrefix("SF:") {
            let name = String(spec.dropFirst(3))
            // `.medium` weight + `.large` scale together: each symbol
            // fills more of its bounding box optically, so glyphs with
            // a lot of internal whitespace (gear, camera, folder) no
            // longer read as smaller than tight ones (lock, magnifying
            // glass). Without this, child panels filled with whitespace-
            // heavy symbols look "shrunk" next to a parent of tight ones.
            let cfg = NSImage.SymbolConfiguration(
                pointSize: pt, weight: .medium, scale: .large)
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
    private let target: Target
    private let onSelect: (LauncherItem, Target) -> Void
    private let isRoot: Bool
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

    init(content: NSView, rows: [ItemRow], frame: NSRect,
         target: Target,
         onSelect: @escaping (LauncherItem, Target) -> Void,
         isRoot: Bool,
         onDismissRoot: (() -> Void)? = nil) {
        self.target = target
        self.onSelect = onSelect
        self.isRoot = isRoot
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
        panel.hasShadow = true
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

    // MARK: Row callbacks

    private func handleRowClick(_ row: ItemRow) {
        switch row.kind {
        case .leaf(let item):
            onSelect(item, target)
            dismiss()
        case .folder, .dynamic, .header, .placeholder:
            break  // folders / dynamic open on hover, not click
        }
    }

    private func handleRowHover(_ row: ItemRow) {
        switch row.kind {
        case .folder(_, let children):
            if childAnchor === row { return }  // already open
            closeChild()
            openChild(for: row, children: children, label: row.titleForLog)
        case .dynamic(let item):
            if childAnchor === row { return }
            closeChild()
            let expanded = PanelLayout.expandDynamic(item)
            openChild(for: row, children: expanded,
                       label: "\(row.titleForLog) (dynamic)")
        case .leaf, .placeholder:
            // Moved to a non-folder row → close any open child. The
            // user's cursor is now committed to this level.
            closeChild()
        case .header:
            // Header is non-interactive, but if somehow hovered we
            // don't want to mess with the child state.
            break
        }
    }

    // MARK: Child management

    private func openChild(for row: ItemRow, children: [PanelNode],
                            label: String) {
        guard let win = row.window else {
            Log.line("launcher-panel: openChild: row has no window — skip")
            return
        }
        let rowInWin = row.convert(row.bounds, to: nil)
        let rowOnScreen = win.convertToScreen(rowInWin)
        let (content, rows) = PanelLayout.buildContent(
            nodes: children, header: nil)
        let frame = PanelLayout.placeChild(
            rowFrameOnScreen: rowOnScreen,
            parentPanelFrame: panel.frame,
            contentSize: content.fittingSize)
        let c = PanelController(
            content: content, rows: rows, frame: frame,
            target: target, onSelect: onSelect,
            isRoot: false)
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
    case placeholder
    case leaf(LauncherItem)
    case folder(name: String, children: [PanelNode])
    case dynamic(LauncherItem)
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
    /// Bounding box in points for the icon view. The actual rendered
    /// SF Symbol is sized to `iconRenderPt` and scaled `.large`, so it
    /// fills the box optically.
    private static let iconSize: CGFloat = 17
    /// `pointSize` passed to `NSImage.SymbolConfiguration` — see the
    /// comment in `PanelLayout.resolveItemIcon` for why this is paired
    /// with `.medium` weight + `.large` scale.
    static let iconRenderPt: CGFloat = 17
    private static let rowHeight: CGFloat = 26
    private static let idleCornerRadius: CGFloat = 4
    private static let hoverCornerRadius: CGFloat = 5

    var titleForLog: String { titleField.stringValue }

    init(kind: RowKind, label: String, icon: NSImage?) {
        self.kind = kind
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Self.idleCornerRadius

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

        var titleTrailingAnchor = trailingAnchor
        var titleTrailingConst: CGFloat = -10

        let needsChevron: Bool = {
            switch kind {
            case .folder, .dynamic: return true
            case .header, .placeholder, .leaf: return false
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
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.rowHeight),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor,
                                                constant: 8),
            titleField.trailingAnchor.constraint(equalTo: titleTrailingAnchor,
                                                  constant: titleTrailingConst),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        applyIdleStyle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var isInteractive: Bool {
        switch kind {
        case .leaf, .folder, .dynamic: return true
        case .header, .placeholder: return false
        }
    }

    private func applyIdleStyle() {
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = Self.idleCornerRadius
        switch kind {
        case .header:
            titleField.textColor = .secondaryLabelColor
        case .placeholder:
            titleField.textColor = .tertiaryLabelColor
        case .leaf, .folder, .dynamic:
            titleField.textColor = .labelColor
        }
        chevronView?.contentTintColor = .secondaryLabelColor
    }

    private func applyHoverStyle() {
        // Fully-opaque accent so the hovered row reads as THE
        // selection target, with no risk of being washed out by the
        // vibrancy underneath.
        layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        layer?.cornerRadius = Self.hoverCornerRadius
        titleField.textColor = .white
        chevronView?.contentTintColor = .white
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
