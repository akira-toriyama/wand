// One live tome panel level: the non-activating NSPanel, show /
// dismiss, hover-to-expand child panels, reorder drop, decorations,
// and the Esc monitor. The root controller owns the whole tree.

import AppKit
import Effects      // LinePet / drawLinePets (shared line-pet drawing; re-exports Palette)
import Palette      // paletteFor — ThemeSpec source for the context menu
import PaletteKit   // resolve(ThemeSpec) → ResolvedPalette (ThemedMenu input)
import ThemeKitUI   // ThemedMenu — the row context menu (wand#128)
import WandCore

/// NSPanel subclass that refuses key/main status. With
/// `canBecomeKey = false` the panel can receive mouse events but
/// macOS won't deliver key events to it — the underlying app keeps
/// its first responder.
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController {
    let panel: NonActivatingPanel
    /// The layout of THIS panel. Root may be `.list` or `.toolbar`;
    /// non-root (children) are always `.list`. Used by `openChild`
    /// to pick the spawn direction.
    let layout: TomeLayout
    private let target: Target
    private let onSelect: (TomeItem, Target) -> Void
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
    /// Row context menu (wand#128). Created on first right-click,
    /// reused for the panel's lifetime, dismissed in tearDown.
    private var contextMenu: ThemedMenu?
    /// Open-time animation applied in `show()`. Inherited by child
    /// panels when they're spawned (so the whole cascade feels
    /// consistent). `.off` keeps the historical instant pop.
    private let openAnim: TomeOpenAnim
    /// Symmetric close-time animation applied in `tearDown()`. Same
    /// inheritance rule as `openAnim` — child panels pick up the
    /// root's value so the cascade unwinds visually together.
    private let closeAnim: TomeCloseAnim
    /// Decorative panel border (rainbow / future palette variants).
    /// Drawn in `show()` as a CAShapeLayer above `contentView`'s
    /// blur, with a hue-rotating CAKeyframeAnimation. Child panels
    /// inherit the root's value.
    private let border: TomeBorder
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
    /// Live session hidden-state for THIS panel tree (wand#128). Seeded
    /// from the Controller's durable `tomeHidden` at panel-open and
    /// updated in place by `handleDelete`, so a re-hover rebuilds a
    /// child from the CURRENT truth rather than the frozen `children`
    /// captured in `ItemRow.kind` at build time. Only the ROOT's copy
    /// is authoritative — children reach it via `root`.
    private var hidden: [String: Set<String>]
    /// The tree's root controller — the one whose `hidden` is
    /// authoritative. A child walks up; the root returns itself.
    private var root: PanelController { parent?.root ?? self }

    private var globalMouseMonitor: Any?
    private var globalKeyMonitor: Any?

    /// Resolved theme colours. Carried so child panels (submenus,
    /// dynamic expansions) inherit the same look — `openChild`
    /// threads this into the child's `buildContent`.
    let colors: TomeColors

    init(content: NSView, rows: [ItemRow], frame: NSRect,
         layout: TomeLayout = .list,
         target: Target,
         onSelect: @escaping (TomeItem, Target) -> Void,
         isRoot: Bool,
         panelPath: String = "",
         onReorder: ((String, [String]) -> Void)? = nil,
         themeName: String = "system",
         onDelete: ((String, String) -> Void)? = nil,
         hidden: [String: Set<String>] = [:],
         openAnim: TomeOpenAnim = .off,
         closeAnim: TomeCloseAnim = .off,
         border: TomeBorder = .off,
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
        self.hidden = hidden
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
        // Row context menu (wand#128) — same opt-in shape as reorder:
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
    /// outside the rim, the "black rim" issue. CALayer's native border
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

    /// Dismiss the entire tree from any level — a child row's click
    /// must not leave its ancestors on screen.
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
        Log.line("tome-panel: DnD sort \"\(source.titleForLog)\" "
                 + "at \"\(PanelTree.displayPath(panelPath))\" — "
                 + "\(order.count) row(s) reordered (session-only)")
        onReorder?(panelPath, order)
    }

    /// The context menu's palette: start from sill's catalog lookup
    /// (`paletteFor(themeName)` resolved via `PaletteKit`), then let
    /// wand's own resolved `colors` — the SAME `TomeColors` the panel's
    /// rows are painted with — override the roles it has an opinion on.
    /// `paletteFor` only knows sill's catalog; `neon` and `splatoon` are
    /// wand-local engine themes (see `Theme.swift`'s file header) that
    /// are NOT in it, so `paletteFor` returns nil for them and we start
    /// from `terminal` — which alone would paint a `neon` panel's
    /// context menu phosphor-green on black instead of matching the
    /// panel's violet-black/cyan chrome. The `colors` override below is
    /// what fixes that. For a catalog theme (terminal, mono, vapor,
    /// chomp, system, …) `colors` derives from that identical sill
    /// spec, so the override is a same-value no-op there — safe to
    /// apply unconditionally.
    private func contextMenuPalette() -> PaletteKit.ResolvedPalette {
        let base = PaletteKit.resolve(paletteFor(themeName) ?? Theme.terminal.spec)
        let background = colors.background ?? base.background
        let foreground = colors.text ?? base.foreground
        // `splatoon` rolls a random ink per ROW (`accentRandomSplatoon`,
        // `colors.accent == nil` by design) — there's no single "the"
        // accent to theme one static menu with, so don't invent a
        // random ink here: leave `primary` and everything derived from
        // it (below) on sill's resolved value.
        guard let accent = colors.accent else {
            return PaletteKit.ResolvedPalette(
                background: background, foreground: foreground,
                muted: base.muted, tertiary: base.tertiary,
                primary: base.primary, secondary: base.secondary,
                border: base.border, hover: base.hover,
                selection: base.selection, error: base.error,
                font: base.font, backgroundAlpha: base.backgroundAlpha,
                vibrancyMaterial: base.vibrancyMaterial,
                forceDarkAqua: base.forceDarkAqua)
        }
        // Mirror sill's own non-system derive recipe (PaletteKit.swift
        // `resolve`'s `.fixed` branch) instead of inventing new alpha
        // constants: hover = the best-contrast ink against the
        // background @ 0.05, selection = primary @ 0.18.
        let neutral = base.bestContrast(on: background ?? .black)
        return PaletteKit.ResolvedPalette(
            background: background, foreground: foreground,
            muted: base.muted, tertiary: base.tertiary,
            primary: accent, secondary: base.secondary,
            border: base.border,
            hover: neutral.withAlphaComponent(0.05),
            selection: accent.withAlphaComponent(0.18),
            error: base.error, font: base.font,
            backgroundAlpha: base.backgroundAlpha,
            vibrancyMaterial: base.vibrancyMaterial,
            forceDarkAqua: base.forceDarkAqua)
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
            menu = ThemedMenu(palette: contextMenuPalette())
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
        Log.line("tome-panel: context menu on \"\(row.titleForLog)\" "
                 + "at \"\(PanelTree.displayPath(panelPath))\"")
        menu.present(at: event.locationInWindow, in: win)
    }

    /// Delete chosen from the context menu: remove the row from the
    /// live panel (folder rows close their open child first), shrink
    /// the panel keeping its TOP edge fixed, and report upward so the
    /// next panel-open filters it out. Separators / section headers
    /// don't travel with the row (same as DnD sort) — the next open
    /// rebuilds them against the filtered tree. If the delete empties
    /// this level entirely, the level tears itself down too — the
    /// panel-open path already forbids an empty root / an empty child
    /// panel, so the live tree can't be left showing one.
    private func handleDelete(row: ItemRow, nodeID: String) {
        if childAnchor === row { closeChild() }
        // Record into the root's live state BEFORE anything else can
        // rebuild from it — a re-hover on a sibling folder reads
        // `root.hidden` via `openChild`, and it must see this delete
        // even though the next real panel-open hasn't happened yet.
        root.hidden[panelPath, default: []].insert(nodeID)
        // Non-zero sentinel: if `row` turns out not to be inside an
        // NSStackView (shouldn't happen — every row lives in the
        // panel's arranged-subviews stack), skip the empty-level
        // teardown below rather than misreading "didn't remove
        // anything" as "removed the last row".
        var remaining = 1
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
            // A level emptied by deletes must not linger — the
            // panel-open path suppresses an empty root and prunes an
            // emptied folder, so the live tree honours the same
            // invariant. Rows carrying a node id are the interactive
            // ones; the app-icon header / section headers /
            // separators don't count as content.
            remaining = stack.arrangedSubviews
                .compactMap { $0 as? ItemRow }
                .filter { $0.nodeID != nil }
                .count
        }
        Log.line("tome-panel: deleted \"\(row.titleForLog)\" at "
                 + "\"\(PanelTree.displayPath(panelPath))\" (session-only)")
        onDelete?(panelPath, nodeID)
        guard remaining == 0 else { return }
        // `row` / `panel` must not be touched past this point —
        // `dismiss()` / `closeChild()` tear down views.
        if isRoot {
            dismiss()
        } else {
            parent?.closeChild()
        }
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

    private func openChild(for row: ItemRow, children: [PanelNode],
                            label: String, childPath: String? = nil) {
        guard let win = row.window else {
            Log.line("tome-panel: openChild: row has no window — skip")
            return
        }
        // Re-apply the session's deletes (wand#128) — `children` was
        // frozen into `ItemRow.kind` at panel-build time, so a row deleted
        // since then would otherwise reappear on the next hover. Dynamic
        // expansions (childPath == nil) are synthesized per hover and are
        // not deletable, so they skip the filter.
        let live: [PanelNode]
        if let childPath {
            live = PanelTree.applyHidden(children, path: childPath,
                                          hidden: root.hidden)
        } else {
            live = children
        }
        // Every child session-deleted → the folder row itself is left
        // stranded at this level (chevron intact, no-ops on hover)
        // rather than being pruned too. Same trade-off as the
        // separator/header note above: the live panel mutates rows
        // only, so self-heals on the next panel-open; pruning the
        // sibling folder row here would mean cascading the delete up
        // through however many parent levels sit above it.
        guard !live.isEmpty else {
            Log.line("tome-panel: openChild \"\(label)\" — every row "
                     + "session-deleted; child suppressed")
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
            nodes: live, header: nil, layout: .list,
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
        Log.line("tome-panel: opened submenu \"\(label)\" "
                 + "(\(live.count) items)")
    }

    private func closeChild() {
        child?.tearDown()
        child = nil
        childAnchor = nil
    }

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
