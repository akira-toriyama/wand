# Design: tome context-menu delete (session-only) — t-k4hf / wand#128

Status: approved 2026-07-17.
Task: [t-k4hf](https://github.com/akira-toriyama/projects/blob/main/.furrow/bodies/t-k4hf.md)
(parent epic t-p9c8 "tome 仕上げ"). Source issue: wand#128.

Right-click a tome panel row → a context menu with one item, **Delete** →
the row disappears for the rest of the session. Discarded on config
reload and daemon restart. Persistence to config.toml is a tracked
follow-up (swift-toml-edit v2.1.0 surgical writer, t-12az done —
export wiring is a separate task), NOT this feature.

## Decision record: why sill `ThemedMenu`, not `NSMenu`, not a wand-local panel

Issue #128 sketched `NSMenu`. During design we evaluated three options
against the software-architecture skill's essential-floor rules and the
house policy (shared-lib responsibilities are never reimplemented
app-side):

- **NSMenu (rejected)** — unthemed (clashes with tome themes), and its
  focus behaviour on a non-activating `LSUIElement` panel is exactly
  the risk #128's acceptance criteria flag. We'd be verifying a
  mechanism we don't control instead of using one the family already
  verified.
- **wand-local mini panel (rejected)** — reusing `PanelController` for
  a one-row menu would deepen the exact reinvention sill names:
  `ThemedMenu`'s header lists "wand's launcher cascade" as a
  present-day duplicate of what it provides. A new hand-rolled menu
  surface would be caught twice by any future migration.
- **sill `ThemedMenu` (chosen)** — ThemeKitUI's themed pop-up action
  menu. Non-activating discipline is built in (`PopupPanel` refuses
  key/main — same contract as wand's `NonActivatingPanel`), it has
  `present(at:in:)` for cursor-point presentation, and
  `MenuItem(isDestructive:)` is documented with "a Delete row" as the
  motivating example. Submenus/checkmarks cover #128's "future items"
  note. wand is the first family adopter — a spike + GUI verification
  precedes full wiring (see Verification).

The essential-floor verdict: wand's non-activating panel shell IS a
named AppKit floor (focus-preserving non-activating panel), so AppKit
here is sanctioned — but the *chrome* on that floor should come from
sill when sill already owns it. It does; we adopt it. Migrating the
whole launcher cascade onto `ThemedMenu` is out of scope and tracked
as its own furrow task.

### Spike outcome (2026-07-17, on hardware) — the gate caught a blocker

**"Non-activating discipline is built in" above is only half true, and
the missing half blocks shipping.** `PopupPanel` does refuse key/main,
but it is not *accessory*-safe: sill's shared `themedPopupPanel`
factory sets `hidesOnDeactivate = true`, and wand is `LSUIElement` — an
`.accessory` app never becomes active, so the menu's panel is ordered
out the instant it is shown. The failure is **silent**: no error, no
warning, and wand's own `context menu on "…"` log line still fires. You
only see it by looking at the screen.

Same family as the `.activeAlways` NSTrackingArea regression CLAUDE.md
records: AppKit defaults keyed on "is the app active" all resolve to the
wrong thing under an accessory host.

wand has no local workaround — `ThemedMenu`'s panel is private, so
nothing wand owns can reach `hidesOnDeactivate`. The fix belongs in sill
(house rule: extend the shared lib, don't reimplement its
responsibility). Verified on hardware against a patched checkout,
tracked as furrow **t-cp90**, which **t-k4hf now depends on**:

```swift
p.hidesOnDeactivate = NSApp.activationPolicy() != .accessory
```

A flat `false` would regress facet / perch, where a popup SHOULD vanish
when the user switches away — hence the policy gate. The fix lands in
the shared factory, so the tooltip and combo box (same `PopupPanel`)
stop being accessory-broken with it.

With that patch applied, the feature verified end-to-end — see Testing &
verification. **The fallback (a wand-local mini panel) was NOT taken:**
the spike proved the widget itself is right for the job once sill is
accessory-aware.

## State & pure logic (WandCore / WandApp)

- `Controller.tomeHidden: [String: Set<String>]` — panel path (`""` =
  root; nested levels join folder names with U+001F, identical to
  `tomeOrder`'s keying) → hidden node-id set. Lives next to
  `tomeOrder`, is cleared in `reload()` with a log line, and dies with
  the daemon. **Deliberate deviation from #128's flat `Set<String>`
  sketch**: per-level keying means deleting `item:Foo` inside folder A
  does not hide a same-named item at the root, and the identity scheme
  stays symmetric with DnD sort.
- Identity = `PanelNode.orderID` (name-keyed: `item:<name>` /
  `folder:<name>`), reused as-is. Same caveat as DnD: two same-named
  entries at one level share an id and hide together — noted at
  `orderID`'s doc comment.
- New pure helper `LauncherHidden.apply(nodes:id:hidden:)` in
  `WandCore` — generic over the element type via an `id` closure,
  same shape as `LauncherOrder.apply`, unit-tested in
  `WandCoreTests`.
- Adapter-side `PanelTree.applyHidden(nodes:path:hidden:)` applies it
  recursively per level and **prunes folders whose children all end up
  hidden** (an empty child panel must never appear). Order of
  application at panel build: hidden filter first, then
  `applyOrder`. If the ROOT level ends up empty, the panel is not
  shown at all (log line) — but `counterLauncherShown` has ALREADY
  incremented by then: the Controller bumps it before calling
  `present`, since it can only see the pre-hidden-filter item count,
  not the built tree. This rare "every visible item was
  session-deleted" case skews the counter by one — an accepted
  trade-off (Core can't see the tree PanelTree builds), documented at
  `LauncherPanel.present`'s guard.

## UI surface (WandAdapterMacOS + sill ThemedMenu)

- `ItemRow` gains right-click handling. Eligible rows = rows carrying
  a `nodeID` (leaf, folder, dynamic) in `.list` panels of the native
  middle-click tome — the same opt-in shape as DnD sort: a new
  `onDelete` callback threaded alongside `onReorder`; `nil` disables
  (toolbar layouts, dynamic expansions, `tome --open`).
- Right-click → `ThemedMenu.present(at:in:)` with a single
  `MenuItem("Delete", icon: SF trash, isDestructive: true)`. Its
  action: live-remove the row from the stack view, reframe the panel,
  close the row's open child panel first if it's a folder row, and
  report `(panelPath, nodeID)` up to the Controller.
- Palette bridge: `LauncherPanel.present` gains a `themeName: String`
  parameter; the adapter resolves it via
  `PaletteKit.resolve(paletteFor(themeName))` at menu-present time.
  (The theme NAME crosses the seam, not a resolved palette — WandApp
  stays free of PaletteKit.) wand-local hex tweaks (neon / splatoon)
  map approximately via `ThemeSpec`; `ThemedMenu.surfaceColor` is the
  escape hatch if the approximation reads wrong.
- Dependencies: `WandAdapterMacOS` adds `PaletteKit`, `ThemeKit`,
  `ThemeKitUI` (sill floor bump as needed). The Package.swift comment
  that documents "no PaletteKit" flips — update it in the same change.
- **No new config keys** — always-on, like DnD sort.

## Event-path facts (verified in source, 2026-07-17)

- The cast trigger is right-button: `EventTap.handleDown` swallows the
  real right-down; with no movement, `handleUp` calls `replayClick`,
  which posts a sentinel-tagged (`replaySentinel` in
  `eventSourceUserData`) synthetic right down+up pair at the original
  point. Net effect: the panel receives the right-click **on button
  release**, as a replayed pair. The context menu therefore opens on
  release, not on press — accepted; spike confirms the replayed pair
  drives `rightMouseDown` → menu without the immediately-following
  `rightMouseUp` dismissing it.
- The tree-dismiss global monitors observe other-app events only, so
  a right-click on our own panel does not dismiss the tree, and a
  click anywhere outside tears down both the tree and the menu
  (ThemedMenu has its own outside-click monitor; `PopupGlue` follows
  host close).
- Keyboard nav inside the menu is inert by design: wand is
  `LSUIElement` and never activates, so `ThemedMenu`'s local keyDown
  monitor receives nothing. The menu is mouse-only — same as every
  other tome surface.

## Non-goals

`tome --open` items (caller-owned), dynamic-expansion children
(synthesized per hover), toolbar / labeledToolbar layouts, undo/redo,
persistence to config.toml (separate task), menu keyboard navigation,
and the wholesale launcher-cascade migration to `ThemedMenu` (tracked
separately in furrow).

## Testing & verification

1. **Spike first**: wire the deps, present a ThemedMenu from a row
   right-click, and verify focus non-theft on hardware before building
   the rest. Fallback if the spike fails: wand-local mini panel
   (decision record above gets amended).
2. **Unit** (`WandCoreTests/LauncherHiddenTests`, 6 tests): covers the
   PURE per-level filter `LauncherHidden.apply` only — no-op when
   nothing is hidden, hides matching ids, unknown id is a no-op,
   nil-id elements always survive, all-hidden yields empty, duplicate
   ids hide together. The RECURSIVE tree walk (`PanelTree.applyHidden`
   — subtree hiding, folder pruning, per-level independence) is NOT
   unit-tested: it lives in `LauncherPanel.swift`, a `WandAdapterMacOS`
   (AppKit) type with no test target. Moving `PanelNode` / `PanelTree`
   into `WandCore` would make it testable — tracked as furrow t-hf3r.
3. **Build bar**: `swift build` clean (tests run in CI — XCTest needs
   Xcode).
4. **GUI verification** (peekaboo, macos-gui-verify skill; macOS
   notification + user OK before any synthetic input, per the
   live-input memory): menu appears on row right-click; frontmost app
   unchanged while the menu is up; Delete removes the row live and on
   next open; folder delete hides the subtree; child-panel hover and
   filters still work; touching config.toml (reload) restores deleted
   rows.
5. **Log lines**: delete records
   `launcher-panel: deleted "<title>" at <path> (session-only)` +
   a controller-side record line; `reload()` logs the discard like
   the DnD override discard.

## Acceptance (from #128, restated against ThemedMenu)

Verified on hardware 2026-07-17 (peekaboo + a CGEvent click helper —
peekaboo has `--right` but no middle-click, and tome's trigger IS
middle-click). **Every box below was checked against a build carrying
the t-cp90 patch**; on stock sill 3.6 the first one fails silently and
takes the rest with it.

- [x] Right-click on an eligible row shows the context menu — 🗑 Delete,
      with the `isDestructive` red accent, at the click point. Also
      confirms the design's event-path claim: the cast tap swallows the
      real right-down and the *replayed* pair drives `rightMouseDown`,
      and the trailing `rightMouseUp` does not dismiss the menu.
- [x] "Delete" removes the row from the panel (live + next open) — the
      panel shrank with its TOP edge fixed; the row stayed gone across
      a dismiss + re-open.
- [x] Menu on the non-activating panel never steals focus — frontmost
      stayed `Code` throughout.
- [x] Child-panel expansion and filtering still work after deletes —
      `apps` globs filtered 12/14 rows; hovering `Sort` opened its
      child; **deleting a child then re-hovering the folder logged
      `opened submenu "Sort" (1 items)`**, i.e. the delete survived the
      rebuild (this is the resurrect bug commit 6316940 fixed).
- [x] Config reload discards all deletions — `controller: reload — tome
      session deletes discarded (session-only)`, every row back.

Also confirmed: two same-named rows at one level hide TOGETHER (the
name-keyed identity caveat, matching
`LauncherHiddenTests.testDuplicateIdsHideTogether`).

Not yet exercised, left for whoever finishes t-cp90's follow-up run:
folder-pruned-on-reopen after deleting *every* child, the all-root-
deleted dismiss, `theme = "neon"` menu colours, `line-pets` after a
live reframe, and the `tome --open` carve-out staying inert.
