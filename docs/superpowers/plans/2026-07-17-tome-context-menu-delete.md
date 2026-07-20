# tome Context-Menu Delete (session-only) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Right-click a tome panel row → themed context menu → "Delete" hides that row for the rest of the session (discarded on config reload / daemon restart).

**Architecture:** Session hidden-state lives in `Controller.tomeHidden: [String: Set<String>]` (panel path → hidden node ids), mirroring the DnD sort override `tomeOrder`. A pure `LauncherHidden.apply` filter in WandCore (unit-tested) is applied recursively by adapter-side `PanelTree.applyHidden` (with empty-folder pruning) at panel build. The menu UI is sill ThemeKitUI's `ThemedMenu` presented from `ItemRow.rightMouseDown` — wand is the first family adopter, so a spike task verifies focus non-theft before the state layer lands.

**Tech Stack:** Swift 6 / SwiftPM, sill 3.6 (`ThemedMenu`, `PaletteKit.resolve`, `paletteFor`), XCTest, peekaboo (GUI verify).

**Spec:** `docs/superpowers/specs/2026-07-17-tome-context-menu-delete-design.md` — read it first; the Decision record explains why ThemedMenu (not NSMenu, not a wand-local panel).

## Global Constraints

- `swift build` must pass before finishing any task (project CLAUDE.md). Pipe long output: `swift build 2>&1 | pare`, tests: `swift test ... 2>&1 | pare --profile test`.
- Layer rules: `WandCore` = pure logic, NO AppKit. All AppKit/sill-UI code stays in `WandAdapterMacOS`.
- Commit messages must pass the LOCAL hook's legacy form: `<:gitmoji:> <type>(<scope>): <subject>` (English subject; the pure-glyph form is rejected by this repo's hook — verified 2026-07-17). Bodies get a trailing `---（和訳）` section. End with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- No new config keys. No persistence. Session-only.
- Branch: `feat/t-k4hf-tome-context-menu-delete` (already exists, spec committed on it).
- Any live synthetic mouse/keyboard input (peekaboo clicks) requires a macOS notification to the user + their OK first (user memory: live-input confirmation).
- macOS floor becomes 26 in Task 1 (sill 3.6 requires it; house policy targets latest macOS only).

---

### Task 1: Bump sill to 3.6, add ThemeKitUI deps, raise macOS floor

**Files:**
- Modify: `Package.swift:36` (platforms), `Package.swift:72-73` (sill floor), `Package.swift:96-101` (WandAdapterMacOS deps), comment block `Package.swift:42-71`
- Modify: `CLAUDE.md` (the "Swift 6, macOS 13+" line)

**Interfaces:**
- Consumes: sill v3.6.0 (`ThemedMenu` with `present(at:in:)` already exists in 1.29.0's `ThemeKit` — v3.0.0's `:boom:` #17b M5 only MOVED it to `ThemeKitUI`, retiring the AppKit `ThemedList`; the bump is therefore elective, matching house policy rather than forced by the API. The only OTHER `:boom:` in 1.29→3.6 is the macOS-26 floor — verified in sill git history 2026-07-17).
- Produces: `import PaletteKit` / `import ThemeKitUI` / `import Palette` compile inside `WandAdapterMacOS`. Later tasks rely on `ThemedMenu`, `ThemedMenu.MenuItem`, `PaletteKit.resolve(_:)`, `Palette.paletteFor(_:)`.

- [ ] **Step 1: Edit Package.swift**

Platforms (line 36):

```swift
    platforms: [.macOS("26.0")],
```

sill dependency (replace the `.upToNextMinor(from: "1.29.0")` line):

```swift
        .package(url: "https://github.com/akira-toriyama/sill.git",
                 .upToNextMinor(from: "3.6.0")),
```

In the sill comment block above it, replace the sentence claiming WandAdapterMacOS never takes PaletteKit (lines ~45-48, "WandAdapterMacOS additionally takes `Effects` … PaletteKit (it has its own NSColorParse and never uses `pal` / `resolve`)") with:

```swift
        // WandAdapterMacOS additionally takes `Effects` for the shared
        // decorations, and (since t-k4hf) `PaletteKit` + `ThemeKit` +
        // `ThemeKitUI` for the row context menu (`ThemedMenu` — the
        // family's themed pop-up action menu; wand is its first
        // adopter). sill 3.x raised the macOS floor to 26, which wand
        // adopts too (latest-macOS-only policy).
```

WandAdapterMacOS target dependencies:

```swift
        .target(
            name: "WandAdapterMacOS",
            dependencies: [
                "WandCore",
                .product(name: "Palette", package: "sill"),
                .product(name: "Effects", package: "sill"),
                .product(name: "PaletteKit", package: "sill"),
                .product(name: "ThemeKit", package: "sill"),
                .product(name: "ThemeKitUI", package: "sill"),
            ]),
```

- [ ] **Step 2: Update CLAUDE.md floor note**

In `CLAUDE.md`, change `Swift 6, macOS 13+, three-layer hexagonal split.` to `Swift 6, macOS 26+, three-layer hexagonal split.`

- [ ] **Step 3: Resolve + build**

Run: `cd /Volumes/workspace/github.com/akira-toriyama/wand && swift package update sill 2>&1 | pare && swift build 2>&1 | pare`
Expected: resolves sill 3.6.x, build succeeds. If APIs wand consumes (Palette / Effects / CLIKit / ConfigSchema) broke silently, fix call sites minimally — sill history shows no `:boom:` touching them, so expect zero or trivial fallout.

- [ ] **Step 4: Run existing tests (Xcode is installed)**

Run: `swift test 2>&1 | pare --profile test`
Expected: all existing tests PASS (this is the regression gate for the version bump).

- [ ] **Step 5: Commit**

```bash
git add Package.swift Package.resolved CLAUDE.md
git commit -m ':arrow_up: build(deps): bump sill floor to 3.6 — ThemedMenu + macOS 26 platform

wand adopts sill 3.x (only :boom: in 1.29→3.6 is the macOS-26 floor,
which matches the latest-macOS-only policy). WandAdapterMacOS gains
PaletteKit + ThemeKit + ThemeKitUI for the tome row context menu
(t-k4hf); the Package.swift comment that documented "no PaletteKit"
flips deliberately.

---（和訳）
subject: sill floor を 3.6 へ — ThemedMenu と macOS 26 platform
body: sill 3.x を採用（1.29→3.6 の :boom: は macOS 26 floor のみで、
最新 macOS のみターゲットの方針と一致）。tome 行コンテキストメニュー
(t-k4hf) のため WandAdapterMacOS に PaletteKit + ThemeKit + ThemeKitUI
を追加。「PaletteKit は取らない」注記は意図的に反転。

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>'
```

---

### Task 2: Spike — right-click opens ThemedMenu (log-only action), verify focus non-theft

The design mandates spike-first: prove the sill widget works on wand's non-activating panel BEFORE building the state layer. The plumbing built here is final; only the delete action is upgraded later.

**Files:**
- Modify: `Sources/WandAdapterMacOS/LauncherPanel.swift` (imports ~line 36; `present` signature ~line 149; `PanelController` init ~line 986; `openChild` ~line 1319; `ItemRow` ~line 1521)
- Modify: `Sources/WandApp/Controller.swift` (`handleLauncher`'s `LauncherPanel.present` call ~line 217)

**Interfaces:**
- Consumes: `ThemedMenu(palette: ResolvedPalette)`, `ThemedMenu.MenuItem("Delete", icon:isDestructive:action:)`, `menu.present(at: CGPoint, in: NSWindow)`, `menu.dismiss(animated:)`, `PaletteKit.resolve(_ spec: ThemeSpec) -> ResolvedPalette` (`@MainActor`), `Palette.paletteFor(_ raw: String) -> ThemeSpec`.
- Produces (later tasks rely on these exact names):
  - `LauncherPanel.present(..., themeName: String = "system", ..., onDelete: ((String, String) -> Void)? = nil, ...)` — onDelete args are `(panelPath, nodeID)`.
  - `PanelController.handleDelete(row: ItemRow, nodeID: String)` — Task 4 inserts live removal here.
  - `ItemRow.enableContextMenu(_ handler: @escaping (ItemRow, NSEvent) -> Void)`.

- [ ] **Step 1: Add imports to LauncherPanel.swift**

After the existing imports (line 36-39):

```swift
import AppKit
import Effects   // drawLinePets (shared line-pet drawing; re-exports Palette)
import Foundation
import Palette      // paletteFor — ThemeSpec source for the context menu
import PaletteKit   // resolve(ThemeSpec) → ResolvedPalette (ThemedMenu input)
import ThemeKitUI   // ThemedMenu — the row context menu (t-k4hf)
import WandCore
```

- [ ] **Step 2: Thread `themeName` and `onDelete` through `present`**

In `LauncherPanel.present` (line ~149) add two parameters after `palette:`:

```swift
                                palette: TomeThemePalette = TomeThemePalette(),
                                themeName: String = "system",
                                orderOverride: [String: [String]] = [:],
                                onReorder: ((String, [String]) -> Void)? = nil,
                                hiddenOverride: [String: Set<String>] = [:],
                                onDelete: ((String, String) -> Void)? = nil,
                                onSelect: @escaping (LauncherItem, Target) -> Void) {
```

(`hiddenOverride` is declared now so the signature is final; it is unused until Task 4.)

Pass both into the root `PanelController` init (alongside `onReorder:`):

```swift
            onReorder: onReorder,
            themeName: themeName,
            onDelete: onDelete,
```

- [ ] **Step 3: PanelController properties + init parameters**

Next to `onReorder` (line ~924) add:

```swift
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
```

Init signature: add `themeName: String = "system", onDelete: ((String, String) -> Void)? = nil` right after `onReorder`, and assign both (`self.themeName = themeName`, `self.onDelete = onDelete`) with the other assignments.

At the end of init, after the reorder wiring block (line ~1052-1059), add:

```swift
        // Row context menu (t-k4hf) — same opt-in shape as reorder:
        // native tome `.list` panels only, rows that carry a node id.
        if layout == .list && onDelete != nil {
            for row in rows where row.nodeID != nil {
                row.enableContextMenu { [weak self] row, event in
                    self?.showDeleteMenu(for: row, event: event)
                }
            }
        }
```

- [ ] **Step 4: Menu presentation + spike-level delete handler**

Add below `handleReorderDrop` (line ~1289):

```swift
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

    /// Delete chosen from the context menu. Task 4 adds the live row
    /// removal; the (panelPath, nodeID) report is final already.
    private func handleDelete(row: ItemRow, nodeID: String) {
        Log.line("launcher-panel: deleted \"\(row.titleForLog)\" at "
                 + "\"\(PanelTree.displayPath(panelPath))\" (session-only)")
        onDelete?(panelPath, nodeID)
    }
```

In `tearDown()` (find `isClosing = true` inside it), add near the top:

```swift
        contextMenu?.dismiss(animated: false)
        contextMenu = nil
```

In `openChild` (line ~1344), thread both new values into the child init, next to `onReorder`:

```swift
            onReorder: childPath == nil ? nil : onReorder,
            themeName: themeName,
            onDelete: childPath == nil ? nil : onDelete,
```

- [ ] **Step 5: ItemRow right-click hook**

Next to `enableReorder` (line ~2020) add the stored handler + enabler, and the override:

```swift
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
```

Note (from the spec's event-path facts): the real right-down is swallowed by the cast tap; this override receives the sentinel-tagged replayed click on button release. That is expected — do not "fix" it.

- [ ] **Step 6: Controller passes themeName + a log-only onDelete**

In `Controller.handleLauncher`'s `LauncherPanel.present` call (line ~217), after `palette:` add:

```swift
            palette: wandTomePalette(cfg.launcher.theme),
            themeName: cfg.launcher.theme,
```

and after the `onReorder:` closure add (spike version — Task 4 replaces the body):

```swift
            onDelete: { path, id in
                Log.line("controller: tome delete requested — \(id) at "
                         + "\"\(path.isEmpty ? "(root)" : path)\" (spike)")
            },
```

(`handleShowMenu`'s present call at line ~333 stays untouched — its `onDelete` defaults to `nil`, which disables the menu for `tome --open`. That is the spec's scope.)

- [ ] **Step 7: Build**

Run: `swift build 2>&1 | pare`
Expected: success.

- [ ] **Step 8: Spike GUI verification (the go/no-go gate for ThemedMenu)**

Use the macos-gui-verify skill (peekaboo). **Before any synthetic click: send a macOS notification and wait for the user's OK (live-input memory).**

1. `./stop.sh; pgrep -lf wand` — clear stray daemons.
2. Ensure `~/.config/wand/config.toml` has `[tome] enabled = true` and at least two `[[tome.cursor.item]]` rows (the repo-root `config.toml` template qualifies). Foreground run: `WAND_DEBUG=1 .build/debug/wand` (second shell: `tail -f /tmp/wand.log`). If the log shows `tapCreate failed`, re-sign per CLAUDE.md (setup-signing-cert.sh) and re-grant AX.
3. Middle-click over a normal app window → tome panel appears.
4. Right-click a row → **expected**: themed menu with a destructive "Delete" row appears at the click point; log shows `launcher-panel: context menu on ...`.
5. **Focus check**: the frontmost app must be unchanged while the menu is open (peekaboo: query frontmost before/after; also the source app's window keeps its focused appearance).
6. Click "Delete" → log shows both the panel line and `controller: tome delete requested ... (spike)`; the row does NOT disappear yet (that's Task 4).
7. Click outside → panel tree AND menu dismiss together.

Record the outcome in the task log. **If focus IS stolen or the menu misbehaves**: stop, amend the spec's decision record, and fall back to the wand-local mini panel per the spec. Do not proceed to Task 3 on a failed spike.

- [ ] **Step 9: Commit**

```bash
git add Sources/WandAdapterMacOS/LauncherPanel.swift Sources/WandApp/Controller.swift
git commit -m ':sparkles: feat(tome): row context menu via sill ThemedMenu — spike wiring (t-k4hf)

Right-click on a nodeID row in a native-tome .list panel presents
ThemedMenu (PopupPanel refuses key — focus non-theft verified on
hardware). Delete action logs only; the session hidden-state lands
next. tome --open and dynamic expansions stay excluded (onDelete nil).

---（和訳）
subject: sill ThemedMenu で行コンテキストメニュー — spike 配線 (t-k4hf)
body: native tome の .list パネルで nodeID 行を右クリックすると
ThemedMenu を表示（PopupPanel は key を拒否 — フォーカス非奪取を実機
検証済み）。Delete はログのみで、session 状態は次タスク。tome --open
と dynamic 展開は対象外のまま（onDelete nil）。

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>'
```

---

### Task 3: Pure hidden-filter in WandCore (TDD)

**Files:**
- Create: `Sources/WandCore/LauncherHidden.swift`
- Test: `Tests/WandCoreTests/LauncherHiddenTests.swift`

**Interfaces:**
- Produces: `LauncherHidden.apply<T>(_ elements: [T], id: (T) -> String?, hidden: Set<String>) -> [T]` — Task 4's `PanelTree.applyHidden` calls this per level.

- [ ] **Step 1: Write the failing tests**

`Tests/WandCoreTests/LauncherHiddenTests.swift`:

```swift
import XCTest
@testable import WandCore

/// Session-only context-menu delete (t-k4hf / wand#128):
/// `LauncherHidden.apply` is the pure per-level filter. Elements
/// whose id is in the hidden set drop; nil-id elements (headers /
/// placeholders) always survive; unknown hidden ids are no-ops.
final class LauncherHiddenTests: XCTestCase {

    private func apply(_ ids: [String], _ hidden: Set<String>) -> [String] {
        LauncherHidden.apply(ids, id: { $0 }, hidden: hidden)
    }

    func testEmptyHiddenKeepsAll() {
        XCTAssertEqual(apply(["a", "b"], []), ["a", "b"])
    }

    func testHidesMatchingIds() {
        XCTAssertEqual(apply(["a", "b", "c"], ["b"]), ["a", "c"])
    }

    func testUnknownIdIsNoOp() {
        XCTAssertEqual(apply(["a", "b"], ["x"]), ["a", "b"])
    }

    func testNilIdElementsAlwaysSurvive() {
        // Header-style elements expose no id; a hidden set can never
        // touch them (even one that happens to contain their label).
        let out = LauncherHidden.apply(
            [("a", true), ("sep", false), ("b", true)],
            id: { $0.1 ? $0.0 : nil },
            hidden: ["a", "sep"])
        XCTAssertEqual(out.map(\.0), ["sep", "b"])
    }

    func testAllHiddenYieldsEmpty() {
        XCTAssertEqual(apply(["a"], ["a"]), [])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter LauncherHiddenTests 2>&1 | pare --profile test`
Expected: FAIL to compile — `cannot find 'LauncherHidden' in scope`.

- [ ] **Step 3: Implement**

`Sources/WandCore/LauncherHidden.swift`:

```swift
// Session-only context-menu delete (t-k4hf / wand#128) — the pure
// half of the feature. The adapter's panel records "the user deleted
// this row" as a node-id set per panel level; this filter drops those
// rows the next time the same level is built. The recursive walk and
// the empty-folder pruning live adapter-side (`PanelTree.applyHidden`)
// because the tree type does; this level filter is the testable core.

public enum LauncherHidden {

    /// Filter one panel level's `elements` per the level's `hidden`
    /// id set. Elements whose `id` is `nil` (headers / placeholders)
    /// always survive; hidden ids not present in `elements` are
    /// ignored.
    public static func apply<T>(_ elements: [T],
                                 id: (T) -> String?,
                                 hidden: Set<String>) -> [T] {
        guard !hidden.isEmpty else { return elements }
        return elements.filter { el in
            guard let eid = id(el) else { return true }
            return !hidden.contains(eid)
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter LauncherHiddenTests 2>&1 | pare --profile test`
Expected: 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/WandCore/LauncherHidden.swift Tests/WandCoreTests/LauncherHiddenTests.swift
git commit -m ':sparkles: feat(core): LauncherHidden.apply — pure per-level hidden filter (t-k4hf)

Same generic shape as LauncherOrder.apply: id-closure over the
element type, nil-id rows always survive, unknown ids are no-ops.
Unit-tested; the recursive tree walk stays adapter-side.

---（和訳）
subject: LauncherHidden.apply — 階層別 hidden 純フィルタ (t-k4hf)
body: LauncherOrder.apply と同型のジェネリック。nil-id 行は常に残り、
未知 id は no-op。unit test 済み。再帰ツリー適用は adapter 側。

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>'
```

---

### Task 4: Session state + tree filter + live row removal

**Files:**
- Modify: `Sources/WandAdapterMacOS/LauncherPanel.swift` (`PanelTree` ~line 261; `present` ~line 167; `handleDelete` from Task 2)
- Modify: `Sources/WandApp/Controller.swift` (state ~line 61; `handleLauncher` present call; `reload()` ~line 420)

**Interfaces:**
- Consumes: `LauncherHidden.apply` (Task 3), `present(..., hiddenOverride:onDelete:)` + `handleDelete` (Task 2).
- Produces: `PanelTree.applyHidden(_ nodes: [PanelNode], path: String, hidden: [String: Set<String>]) -> [PanelNode]`; `Controller.tomeHidden: [String: Set<String>]`.

- [ ] **Step 1: PanelTree.applyHidden**

Add below `applyOrder` (line ~324) in `LauncherPanel.swift`:

```swift
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
```

- [ ] **Step 2: Wire the filter into `present`**

Replace the node-build line (line ~173-174):

```swift
        let nodes = PanelTree.applyOrder(PanelTree.build(from: items),
                                          path: "", override: orderOverride)
```

with:

```swift
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
```

- [ ] **Step 3: Live row removal in handleDelete**

Replace Task 2's `handleDelete` body:

```swift
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
```

- [ ] **Step 4: Controller state + real onDelete + reload discard**

In `Controller.swift`, below `tomeOrder` (line ~61):

```swift
    /// Session-only context-menu deletes for the tome panel (t-k4hf):
    /// panel path (same U+001F keying as `tomeOrder`) → node ids the
    /// user deleted at that level. Deliberately NOT persisted —
    /// discarded on config reload and daemon restart (persistence to
    /// config.toml is a tracked follow-up on swift-toml-edit's
    /// surgical writer). Only the native middle-click path reads it.
    private var tomeHidden: [String: Set<String>] = [:]
```

In `handleLauncher`'s present call, add after `onReorder:`'s closure:

```swift
            hiddenOverride: tomeHidden,
```

and replace the spike `onDelete` closure with:

```swift
            onDelete: { [weak self] path, id in
                self?.tomeHidden[path, default: []].insert(id)
                let shown = path.isEmpty
                    ? "(root)"
                    : path.split(separator: Character("\u{1F}"),
                                 omittingEmptySubsequences: false)
                          .dropFirst()
                          .joined(separator: "/")
                Log.line("controller: tome delete saved for "
                         + "\"\(shown)\" — \(id) (session-only)")
            },
```

In `reload()`, right after the `tomeOrder` discard block (line ~420-425):

```swift
        // Session context-menu deletes die with the config too
        // (wand#128 acceptance: reload restores deleted rows).
        if !tomeHidden.isEmpty {
            tomeHidden.removeAll()
            Log.line("controller: reload — tome session deletes "
                     + "discarded (session-only)")
        }
```

- [ ] **Step 5: Build + full test run**

Run: `swift build 2>&1 | pare && swift test 2>&1 | pare --profile test`
Expected: build success, all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/WandAdapterMacOS/LauncherPanel.swift Sources/WandApp/Controller.swift
git commit -m ':sparkles: feat(tome): session hidden-state + live row removal for context-menu delete (t-k4hf)

Controller.tomeHidden ([panelPath: Set<nodeID>], same keying as the
DnD override) feeds PanelTree.applyHidden — hidden filter before
order, emptied folders prune, an all-deleted root suppresses the
panel. Delete now removes the row live (top edge fixed) and reload
discards the state.

---（和訳）
subject: コンテキストメニュー削除の session 状態 + live 行除去 (t-k4hf)
body: Controller.tomeHidden（DnD override と同じ階層キー）を
PanelTree.applyHidden に接続 — hidden → order の順で適用、空 folder は
prune、root 全削除はパネル抑止。Delete は行を live 除去（上端固定）、
reload で状態破棄。

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>'
```

---

### Task 5: GUI acceptance run (all #128 criteria)

**Files:** none (verification; fixes loop back into the touched files above)

**Interfaces:**
- Consumes: the running daemon + `/tmp/wand.log` trace vocabulary from Tasks 2/4.

- [ ] **Step 1: Full acceptance pass with peekaboo**

macos-gui-verify skill; **notification + user OK before synthetic input**. Foreground daemon (`WAND_DEBUG=1 .build/debug/wand`), config with ≥2 root items, ≥1 folder (`group = ["..."]`) with ≥2 children, and 1 dynamic item if the template has one.

| # | Action | Expected |
|---|--------|----------|
| 1 | Right-click leaf row → Delete | Row disappears live, panel shrinks (top edge fixed); log `deleted "…" (session-only)` + `controller: tome delete saved` |
| 2 | Reopen panel (middle-click) | Deleted row still absent |
| 3 | Delete BOTH children inside the folder's child panel, reopen | Folder row itself is gone (prune) |
| 4 | Delete a folder row directly | Its open child panel closes first, subtree hidden on reopen |
| 5 | Hover another folder / filtered app after deletes | Child panels + `apps` filtering still work |
| 6 | Focus check during menu | Frontmost app unchanged the whole time |
| 7 | `touch ~/.config/wand/config.toml` (ConfigWatcher reload), reopen | All deleted rows restored; log `reload — tome session deletes discarded` |
| 8 | Same-named two rows at one level (add temp config rows) | Both hide together — expected name-key caveat, log it as confirmed |
| 9 | `wand tome --open` path (if a chord/test trigger is handy) | Right-click does nothing (menu disabled) |

- [ ] **Step 2: Fix anything that failed, re-run, commit fixes**

Each fix is its own commit (`:bug: fix(tome): …` with 和訳). Re-run the failed row until the table is green.

---

### Task 6: Docs, glossary, furrow, PR

**Files:**
- Modify: `README.md`, `README.ja.md` (tome section), `docs/glossary.md`
- Modify: `Sources/WandAdapterMacOS/LauncherPanel.swift` (doc comment, line ~7-17)

**Interfaces:** none new.

- [ ] **Step 1: Update the LauncherPanel header doc**

In the behaviour notes block (line ~7-17), add one bullet:

```swift
//   - Right-click on a row opens a themed context menu (sill
//     ThemedMenu) with Delete — session-only, discarded on config
//     reload / restart. Native middle-click tome only.
```

- [ ] **Step 2: README (EN + JA, same PR)**

In `README.md`'s tome section add (adapt to surrounding prose):

```markdown
Right-click a row to open its context menu — **Delete** hides the
row for the rest of the session (a config reload or daemon restart
restores it; deleting every child of a folder hides the folder too).
```

Mirror in `README.ja.md`:

```markdown
行を右クリックするとコンテキストメニューが開き、**Delete** でその行を
セッション中だけ非表示にできます（config reload / daemon 再起動で復活。
folder の子を全部消すと folder ごと消えます）。
```

- [ ] **Step 3: glossary.md**

Add a term (same PR as the code — house rule):

```markdown
### row context menu

Right-click menu on a tome row (sill `ThemedMenu` on a non-activating
`PopupPanel`). Today it has one entry, **Delete** — a session-only
hide recorded per panel level (`Controller.tomeHidden`), discarded on
config reload / daemon restart. Native middle-click tome only; not
`tome --open`, not dynamic-expansion children.

Don't call it: 右クリックメニュー (in code/docs), NSMenu.
```

- [ ] **Step 4: Build + commit**

```bash
swift build 2>&1 | pare
git add README.md README.ja.md docs/glossary.md Sources/WandAdapterMacOS/LauncherPanel.swift
git commit -m ':memo: docs(tome): document row context menu delete (session-only)

READMEs (EN/JA), glossary "row context menu" term, LauncherPanel
header note — same PR as the feature per the glossary lockstep rule.

---（和訳）
subject: 行コンテキストメニュー削除のドキュメント (session-only)
body: README 英日・glossary の "row context menu"・LauncherPanel
ヘッダ注記。glossary は同一 PR ルールに従う。

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>'
```

- [ ] **Step 5: furrow body + PR**

1. Update the task body checklist: `furrow show t-k4hf` → edit `projects/.furrow/bodies/t-k4hf.md` via `furrow edit t-k4hf` (non-TTY prints the path; check off what shipped, note the sill-3.6 bump + first ThemedMenu adoption), then `furrow sync`.
2. Push branch, open the PR:

```bash
git push -u origin feat/t-k4hf-tome-context-menu-delete
gh pr create --title ':sparkles: feat(tome): right-click context menu — delete a row (session-only)' --body '$BODY'
```

PR body must cover: What (ThemedMenu adoption + session hidden-state), Scope per #128 (non-goals: persistence, tome --open, dynamic children, toolbar, undo), Verification (unit tests + the Task 5 acceptance table results + spike focus check), `Closes #128`, and end with:

```
SetStatus-task: https://github.com/akira-toriyama/projects/blob/main/.furrow/bodies/t-k4hf.md done

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

3. After CI: `cifail` if anything fails.

---

## Self-Review (done at write time)

- **Spec coverage:** decision record → Task 2 spike gate; state/pure logic → Tasks 3-4; UI → Tasks 2+4; event-path facts → Task 2 note; non-goals → onDelete-nil defaults (Task 2 Step 6, openChild threading); testing section → Tasks 3 (unit), 1/4 (build+test), 5 (GUI table); acceptance checklist → Task 5 table rows 1-7. sill floor/platform bump (discovered during planning, 1.29→3.6 + macOS 26) → Task 1.
- **Placeholders:** none — every code step carries the code.
- **Type consistency:** `onDelete: ((String, String) -> Void)?` and `handleDelete(row:nodeID:)` identical in Tasks 2/4; `LauncherHidden.apply(_:id:hidden:)` matches between Tasks 3/4; `hiddenOverride: [String: Set<String>]` declared Task 2, consumed Task 4.
