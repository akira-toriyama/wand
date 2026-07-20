# CLAUDE.md

Guidance for working in this repository.

## Terminology

All UI / config terminology follows [`docs/glossary.md`](docs/glossary.md) —
use the canonical names (**cast**, **tome**, assist card, badge,
trail, fire burst, fire decal, chomp, line-pet, non-activating panel,
child panel, tome entry, tome layout, dynamic submenu, AX target,
external trigger, excludes, …), **not** the `Don't call it:` synonyms.
Adding or renaming a term lands in the same PR as the code change.

The same lockstep covers the CLI verb surface and the TOML table
names: prose and help text use the live forms (`wand <domain> --<verb>`;
`[[cast.cursor.rule]]` / `[[cast.focused.rule]]` / `[[tome.cursor.item]]`).
The retired flag CLI and the dropped `[[cast.rule]]` / `[[tome.item]]`
headers may appear only in the parser's migration-warning paths, never
as canonical examples.

Swift type names (`LauncherSpec`, `LauncherPanel`, `LauncherSource`,
`GestureOverlay`, `cfg.launcher`, …) intentionally retain the pre-
rename names — the TOML / user-facing rename to `cast` / `tome`
covered config keys and strings only; an internal-type rename is a
tracked follow-up.

## What this is

`wand` — macOS daemon for **cursor-anchored mouse automation**. Two
trigger families coexist on one daemon, with an external entry point
for event-driven daemons to share the same tome UI:

- **cast** (right-button + drag, the original "stroke" feature):
  draw a shape with the cursor; the recogniser turns it into a
  `LURD` string; rules fire actions.
- **tome** (middle-click, opt-in via `[tome].enabled`):
  pops a **non-activating NSPanel** near the cursor that does NOT
  take keyboard focus, so the source app stays focused; each
  `[[tome.cursor.item]]` is one row with the same action-type
  vocabulary. Submenus (`group = ["..."]`) open as adjacent child
  panels on hover.
- **`wand tome --open`** (external trigger CLI): an upstream trigger
  (a chord hotkey, or a text-selection observer) posts a
  Distributed Notification carrying items + cursor + selection;
  the daemon pops the same `LauncherPanel` against the frontmost
  app. **Spine exception** — no button-down moment, see the
  cursor-anchored section.

Both native triggers share the **single invariant**: actions dispatch
to the window the cursor was over **at button-down time**, never to
whichever has focus by the time the action runs. On multi-display
Macs the focused window is often on a different display from where
you're pointing, so a cast / tome click aimed at e.g. a
Chrome tab on display 2 fires against *that* tab — not whatever
happened to have focus on display 1.

Names:
- repo + binary + bundle + brand: `wand`, `com.wand.wand`,
  `Wand.app`
- config: `~/.config/wand/config.toml`
- log / status: `/tmp/wand.{log,status}`
- DNC channel: `com.wand.app.control`
- shell-action env vars: `WAND_*` (`WAND_TARGET_*`, `WAND_SELECTION`, …)
- Swift modules: `WandCore` / `WandAdapterMacOS` / `WandAdapterTest`
  / `WandApp`

The domain term "stroke" (a drawn gesture) survives in identifiers
like `minStrokePx`, `onStrokeEnd`, "stroke recognition" — that's
the concept, not the project name. Don't rename those.

Architecturally a sibling of
[facet](https://github.com/akira-toriyama/facet) and
[focusfx](https://github.com/akira-toriyama/focusfx): Swift 6,
macOS 13+, three-layer hexagonal split.

## Build / run

```sh
swift build                  # compile (CommandLineTools works)
swift test                   # tests — needs Xcode (XCTest); fails on CLT
.build/debug/wand --help   # smoke test
.build/debug/wand config --validate
```

Same XCTest constraint as facet — CommandLineTools alone can't
run tests; let CI cover them. `swift build` is the bar locally.

`@main enum WandApp` lives in
[Sources/WandApp/Main.swift](Sources/WandApp/Main.swift)
(NOT top-level code in a `main.swift`) so XCTest's executable-target
`@testable import` keeps working once test coverage of the CLI lands.
**Don't reintroduce a `main.swift` file** — same trap as facet /
ws-tabs.

## Non-obvious constraints — read before editing

### Layer rules (the spine of the project)

- **3 layers are non-negotiable**: `WandCore` is pure logic
  (CoreGraphics OK, NO AppKit / NO CGEvent / NO AX).
  `WandAdapterMacOS` wraps the OS (CGEventTap, AX,
  CGEvent post, NSRunningApplication) and is the *only* place
  those types appear. `WandAdapterTest` is the synthetic
  counterpart for end-to-end recognition tests.
  Crossing layers always means there's a missing protocol.
- **`MouseSource` is the seam**:
  [Sources/WandCore/MouseSource.swift](Sources/WandCore/MouseSource.swift)
  declares the protocol; the Controller only ever sees
  `MouseSource`. Real vs synthetic is picked at app startup.
  Adding a new mouse-input strategy means a new `MouseSource`
  conformer in an Adapter module — never a `#if` in Core.
- **The tome trigger has its own seam**: `LauncherSource`
  protocol in `WandCore`, `MacOSLauncherSource` in `WandAdapterMacOS`
  ([Sources/WandAdapterMacOS/LauncherTap.swift](Sources/WandAdapterMacOS/LauncherTap.swift)).
  It's a separate `CGEventTap` from `MacOSMouseSource` — two taps
  coexist so the right-button-drag mask never has to also carry
  middle-click. `Controller` holds it optionally (`nil` unless
  `cfg.launcher.enabled` at startup), so the second tap isn't even
  allocated when the user hasn't opted in.
  When AX target resolution fails (Dock / menu bar / Desktop —
  cursor is over a non-AX surface) the tap falls back to a
  `Target(bundleID: "", pid: 0, …)` sentinel instead of suppressing
  the menu. `Matcher.appsAllow` then keeps `apps = ["*"]` items
  (truly global ones — Spotlight, lock screen, open Terminal,
  etc.) and prunes app-specific items. The app-icon header
  collapses because no `NSRunningApplication` resolves under the
  empty bundle id. This carves out a "menu still works on
  Desktop" path without breaking the cursor-anchored spine for
  app-specific items.
- **`LauncherPanel` lives in `WandAdapterMacOS` too**
  ([Sources/WandAdapterMacOS/LauncherPanel.swift](Sources/WandAdapterMacOS/LauncherPanel.swift)) —
  it builds a tree of `NSPanel`s from `[LauncherItem]` filtered by
  the cursor-anchored target. The root panel is a
  `NonActivatingPanel` (subclass of `NSPanel`, `canBecomeKey = false`
  + `.nonactivatingPanel` style mask) so it never steals keyboard
  focus from the underlying app — the user keeps typing in their
  editor while picking a row. `group = [...]` paths drive nesting:
  `PanelTree.build` walks each item's group, creating folders on
  first reference and appending into them on subsequent ones. A
  folder row shows a `chevron.right` SF Symbol; hovering it spawns
  an adjacent child panel via `PanelController.openChild`. The
  hand-off gap between panels is zero so cursor traversal works
  straight-right; native NSMenu's diagonal-cursor tolerance is NOT
  reproduced — hovering a non-folder row in the parent closes the
  child. Don't promote this to a separate module — same reasoning
  as `GestureOverlay`. `PanelLayout.resolveItemIcon` is the per-item
  icon resolver — recognises `SF:<name>` (NSImage.systemSymbolName,
  rendered with `.medium` weight + `.large` scale so whitespace-
  heavy glyphs read the same optical size as tight ones), file
  paths (absolute / tilde / config-dir-relative), or falls back to
  drawing the string as a glyph (emoji / 1-2 char text).
  Unresolvable specs log once and collapse to no-icon; never throws.
- **`NSTrackingArea` MUST use `.activeAlways`** in `ItemRow`. wand
  is `LSUIElement` and the panel is non-activating, so
  `.activeInActiveApp` resolves to "never" and `mouseEntered` never
  fires — silently breaks hover highlight AND hover-to-expand. Cost
  us a debugging cycle once; the regression test is: open a folder
  row by hovering it (don't click — there's no click handler on
  folder rows).
- **Dynamic items** (`dynamic = "..."` + `LauncherTemplate`) render
  as folder-style rows with a chevron. Hovering one runs the shell
  via `BoundedShell.run` (500 ms timeout) and pops a child panel
  populated by `PanelLayout.expandDynamic`: each non-empty stdout
  line becomes a synthetic leaf `LauncherItem` with `{line}`
  substituted in the template's name / icon / payload. Errors
  (timeout, spawn fail, non-zero exit, empty stdout) collapse to a
  single `(timeout)` / `(spawn failed)` / `(error: exit N)` /
  `(no items)` placeholder row so the user always sees something.
  Expansion happens at hover time, not at panel-open time — the
  shell runs only when the user actually opens the submenu, and
  re-runs on each re-open (no caching). `{line}` is untrusted —
  same caveat as `WAND_TARGET_TITLE`.
- **Checkmark / radio state** is decoded inline in
  `PanelLayout.renderItemLabel`: `"on"` / `"off"` / `"mixed"` for
  static markers, `"shell:<cmd>"` for live eval at panel-open via
  `BoundedShell.run` with a tight 100 ms budget. The resolved glyph
  (`✓` / `–`) is prefixed to the row title; no native
  `NSMenuItem.state` to lean on once we left NSMenu behind. Unknown
  spec logs and falls through to no-marker.
- **`BoundedShell` is the shared synchronous-with-timeout shell
  runner** ([Sources/WandAdapterMacOS/BoundedShell.swift](Sources/WandAdapterMacOS/BoundedShell.swift)).
  Used by the state resolver in `PanelLayout` and the
  `filter-shell` evaluator the Controller wires into `Matcher`.
  Returns `.exited(stdout, exitCode)` / `.timeout` / `.spawnFailed`.
  All main-thread callers pass a budget short enough that the
  caller doesn't feel laggy.
- **Filter chain in `Matcher.passesFilter`** — three predicates,
  ordered cheapest first: `apps` glob → `filter-title` glob →
  `filter-shell` predicate. The shell predicate is injected from
  the App layer (`Controller.shellEvaluator(for:)`) so `Matcher`
  stays in Core (no AppKit / Foundation Process dependency).
  `Matcher.candidates()` is the one place that skips title /
  shell entirely — it runs per-sample for the overlay's assist
  hint, and any extra work blows the frame budget. Net: the
  cast trail can paint a rule as "reachable" that ends up
  rejected at button-up; deliberate trade-off, documented at the
  call site.
- **The cast-trail overlay lives in `WandAdapterMacOS`**, not a
  separate View module ([Sources/WandAdapterMacOS/GestureOverlay.swift](Sources/WandAdapterMacOS/GestureOverlay.swift)).
  It's the project's only on-screen UI; it's pure AppKit/CG rendering
  fed by the event-tap sample stream, so it belongs in the macOS
  adapter rather than justifying a facet-style View layer. Core stays
  UI-free — trail points cross the seam as plain `CGPoint`. **Don't
  promote it to its own module** unless a second UI surface appears.
  `MacOSMouseSource.onSample` / `onStrokeEnd` are the (non-`@Sendable`,
  main-thread-only) hooks that feed it; they're deliberately separate
  from the protocol's `@Sendable` wand `handler` so they can capture
  the non-Sendable overlay.
- **Shared adapter helpers** live in three single-purpose files; the
  invariants behind each are easy to regress if duplicated, so reach
  for these instead of re-implementing:
  - [Sources/WandAdapterMacOS/CGTrigger.swift](Sources/WandAdapterMacOS/CGTrigger.swift) —
    `Trigger.Button` → CGEvent mask / type / button number, and
    `CGModifier.flags` for the strict-equality modifier check both
    taps use.
  - [Sources/WandAdapterMacOS/ScreenCoords.swift](Sources/WandAdapterMacOS/ScreenCoords.swift) —
    CG (Y-down) ↔ Cocoa (Y-up) conversion. Flipping about the
    primary screen height is correct for ALL displays; **don't
    derive the flip per-call from `NSScreen.main.frame.height`** —
    that breaks on multi-display setups where the cursor sits
    outside the primary.
  - [Sources/WandAdapterMacOS/AppIconCache.swift](Sources/WandAdapterMacOS/AppIconCache.swift) —
    `(bundleID) → (localizedName, resized NSImage)` keyed cache.
    `NSRunningApplication.runningApplications(withBundleIdentifier:)`
    is 5–20 ms per call on a busy machine; cache invalidates via
    `NSWorkspace.didTerminateApplicationNotification`.

### The cursor-anchored spine — DO NOT regress this

The whole point of wand is that **actions dispatch to the
cursor-anchored target window**, not to the focused window.
Everything below depends on this contract:

- The target is captured at **button-down time**, NOT at
  button-up time and NOT at action-dispatch time. By the time
  the user finishes drawing, the focused window may be entirely
  different — that's a feature, not a bug.
- `AXTarget.resolveAt(point:)` is the single resolution point.
  Walking up `kAXParentAttribute` until `kAXWindowRole` gives
  the window; `AXUIElementGetPid` then `NSRunningApplication`
  gives the bundle id.
- **`Target` is a value type** in
  [Sources/WandCore/Models.swift](Sources/WandCore/Models.swift).
  Don't put `AXUIElement` inside it — Core must stay free of
  Application Services types. If the dispatcher needs the live
  AX handle (for `.ax(...)` actions), the adapter keeps a
  side-table keyed by pid + serverID and looks it up at dispatch
  time. The serialised `Target` is what flows through Core.
- `.key(...)` actions raise the target first (via
  `NSRunningApplication.activate`), THEN post the keystroke.
  Posting before raising would land the key on whoever has focus
  — exactly the failure mode the cursor-anchored design exists
  to avoid.
- `.ax(...)` actions skip raising and call
  `AXUIElementPerformAction` directly. Less disruption, no
  focus stolen. Prefer `ax` for close/minimize/zoom.
- `.shell(...)` actions get the target identity via env vars
  (`WAND_TARGET_BUNDLE_ID`, `WAND_TARGET_PID`,
  `WAND_TARGET_TITLE`, `WAND_TARGET_FRAME`) — the user's
  command can decide what to do with that information.
- **Env-var contract (wand#137)**: every context env var is
  `WAND_`-prefixed (`Dispatch.execute(extraEnv:)` drops
  non-conforming keys loudly), and an absent context leaves the
  var **unset** — never an empty string — so recipes can branch
  on `[ -n "${WAND_SELECTION:-}" ]`. New trigger families add
  one var each (`$WAND_SHELF_FILES` / `$WAND_SHELF_COUNT` for
  bolt, `$WAND_CLIPBOARD` / `$WAND_URL` reserved); values are
  untrusted — same quoting caveat as `WAND_TARGET_TITLE`.
- **`wand tome --open` is the documented spine exception.**
  An upstream trigger (a chord hotkey, or a text-selection
  observer — there is no button-down moment to anchor against)
  posts `show-menu` over the existing DNC channel with
  `userInfo = [items, x, y, selection]`.
  The Controller resolves the target via
  `NSWorkspace.frontmostApplication` instead of `AXTarget.
  resolveAt(point:)` — text-selection-anchored, not cursor-
  anchored. Spine guarantees above apply to cast and middle-
  click tome (the native trigger families); `tome --open` is
  documented as the carve-out. `$WAND_SELECTION` is the only extra
  env var added (via `Dispatch.execute(extraEnv:)`); the
  `WAND_TARGET_*` set is still populated, just from the
  frontmost app instead of a cursor-anchored window. See
  [Sources/WandApp/Controller.swift](Sources/WandApp/Controller.swift)'s
  `handleShowMenu`.

### Safety invariants — DO NOT regress this

wand grabs low-level mouse via CGEventTap. A bug, a crash, or a
swallowed event maps directly to **"the user's PC is now
unusable"** — the worst possible outcome for a tool whose own
positioning is "mouse enhancement". The rules below apply to every
current trigger family (cast, tome) and every future one
(bolt, aura, scry, …).

**The three PC-inoperable failure modes**

These all contradict wand's reason for existing:

- left click cannot be released (stuck mid-drag)
- right click cannot be released (stuck mid-stroke)
- DnD cannot be released (synthetic mouseUp lost, or tap holds the
  drag stream)

**`[failsafe]` is a mandatory config block**

Same top-level scope as `[exclude]`, but with the opposite
TOML-handling policy: while every other key clamps to a default
when missing / invalid, **`[failsafe]` block missing → wand
refuses to start**. Deliberate deviation from the
clamp-to-default convention. The bundled `config.toml` always
ships `[failsafe]`; `wand config --validate` flags the missing block as
fatal. Rationale: safety must not silently degrade — if a user
removes the block, they get a loud error, not a quietly unsafe
daemon.

**Five layers of defense**

The full target architecture. Layers 1 and 2 ship today
(`FailsafeMonitor`); layers 3–5 are tracked follow-ups documented
as PLANNED below so the WHY of each one is on record for the next
PR that touches this surface. Don't lean on any single layer;
combine them so one failure mode can't cascade.

1. **Button-hold timeout** — `[failsafe].mouse-hold-timeout-sec`.
   If any mouse button stays `down` longer than the timeout, the
   daemon force-posts a mouseUp at the current cursor position.
   Catches both wand-origin stuck states and external HID layers
   (Karabiner-Elements / Logitech Options / KVMs) that drop the
   real up event. SHIPPED.
2. **Emergency release key** — `[failsafe].emergency-release-key`,
   default `"esc"`. Implemented via
   `NSEvent.addGlobalMonitorForEvents` (passive observer — Esc
   still flows to the underlying app, so modals / cancels keep
   working). The release sequence is **idempotent**: releasing an
   un-held button is a no-op, so the firehose of normal Esc
   presses is harmless. Only logs `Log.line` when it *actually*
   released something, so an empty log = healthy. SHIPPED.
3. **CLI escape hatch** — `wand --release-all` over the existing
   DNC channel. Works from a second shell / ssh / a keyboard
   shortcut app when the mouse itself is unusable. PLANNED — not
   yet wired; do not reference as if available.
4. **Tap-internal invariants** (see below). The relevant tap
   doesn't yet exist (only bolt posts synthetic mouseUp, and bolt
   itself is PLANNED). The invariants below are the contract that
   tap will be held to.
5. **Tap watchdog** — `[failsafe].tap-watchdog-interval-sec`.
   `CGEventTap` can be disabled by the OS under load; the daemon
   periodically checks and reinstalls. `wand config --doctor` flags any
   button held longer than the timeout and suggests
   `--release-all`. PLANNED — neither the config key nor the
   watchdog exists yet.

**Tap-internal invariants (code level — PLANNED, lands with bolt)**

These apply to any code path that posts synthetic mouse events.
Today no such path exists; bolt (the planned shake-to-shelf
trigger) will be the first. Codifying them here so the bolt PR
honours them by construction.

- **A synthetic `.leftMouseUp` post is the single most dangerous
  code path.** Before posting, check `CGEventSource.buttonState`:
  if it's already `false` (user released naturally), skip the
  post. After posting, re-check; if still `true`, retry once.
  Keep this the *only* place wand posts a synthetic mouseUp.
- **The cast tap must never swallow mouseUp on any error path.**
  A crashed daemon is recoverable (the OS auto-uninstalls the
  tap); a tap that holds the mouseUp is not. Audit every CGReturn
  / error branch in
  [Sources/WandAdapterMacOS/EventTap.swift](Sources/WandAdapterMacOS/EventTap.swift)
  to confirm mouseUp always reaches AppKit.
- **No "synthetic-down-in-flight" state** in the daemon. wand may
  post mouseUp synthetically; it must never post mouseDown
  synthetically. The asymmetry is the whole point: if wand
  crashes between a synthetic-down and the matching synthetic-up,
  the OS has no way to recover. Crashing with no synthetic-down
  in flight is safe because the OS uninstalls the tap and every
  real event flows through.

**Adding a new trigger family**

Every new trigger (planned bolt's left-drag-shake, planned scry's
AX observation, anything future) goes through this checklist:

1. If the daemon crashes mid-trigger, can the user still use the
   mouse normally?
2. Does the trigger post synthetic mouse events? If yes, only
   mouseUp, and only after a `buttonState` precondition check.
3. Is the trigger's progress state cleared by the emergency
   release sequence? Wire it into the release path.
4. Does `wand config --doctor` report the trigger's health? Add a probe.

### Configuration

- **`config.toml` at the repo root is the source-of-truth
  template**. Users `curl` it into `~/.config/wand/config.toml`
  (see [README.md](README.md) Configuration section).
  **The app only reads it** — never writes, never auto-generates
  an example, never persists runtime overrides. Same policy as
  facet: the file is the only thing the user has to look at to
  know what wand will do.
- **There is no settings GUI** — by design. Don't propose
  adding NSPanel-based preferences. The user can already see
  every option in one TOML file. Memory: facet's
  `config-default-behavior` pattern.
- **All TOML keys clamp out-of-range / unknown values to defaults**
  rather than rejecting. A typo can never break cast
  recognition — the rule with the typo silently drops, the rest
  still load. `wand config --validate` is the explicit verification
  path.
- **Breaking schema changes are OK when adding / reshaping
  features.** wand is config.toml-driven with no users beyond
  whoever ran the `curl` template line. Don't preserve retired
  key shapes with shims or migration warnings — rename in place,
  drop the old form, and update the bundled `config.toml` in the
  same PR.
- **Value-convention discipline.** Three shapes carry distinct
  meaning and shouldn't mix:
  - Enum fields whose "disabled / no animation" state is one option
    use `"off"` (`kind`, `border`, `open`, `close`, `fire`,
    `cancel`, `armed`). Don't introduce a parallel `"none"`.
  - String fields whose empty value means "inherit theme / default"
    use `""` (the colour fields under `[cast.overlay.trail]` /
    `[cast.fire.burst]`).
  - Arrays use `[]` for the empty case.
  Pick the right shape when adding a new field rather than letting
  a fourth convention drift in.
- **Prefer the nested-sub-block style** when a config feature has
  multiple knobs that share a domain — keys live inside the
  sub-block that owns them, even if some keys repeat across
  sub-blocks:

  ```toml
  # Preferred
  [foo]
  color = "red"
  length = "short"

  [bar]
  color = "red"
  size = "xl"
  ```

  not

  ```toml
  # Avoid — `color` at the top bleeds down into both sub-blocks
  color = "red"
  [foo]
  length = "short"
  [bar]
  size = "xl"
  ```

  This is a *want / better*, not a *must*. The exception is a
  setting that genuinely spans both sub-blocks and would invite
  drift if duplicated — `[cast].intensity` (scales both
  `[cast.overlay.cards]` and `[cast.fire.burst]`) and
  `[exclude].apps` (applies to both cast rules and tome
  entries) live at the higher scope on purpose; the comment at the
  call site explains why. Default to the nested form, and justify
  in a comment when promoting a key upward.
- **The same discipline applies to the CLI.** wand is a domain-verb
  CLI (`wand <domain> --<verb> [VALUE …]`; bare `wand` = server).
  Breaking changes to the verb surface are OK (rename + update
  `--help` / README in the same PR — there is no third-party tooling
  depending on it). The loud-reject policy holds end-to-end: an
  unknown domain, an unknown flag, a bad arity, zero verbs for a
  domain, or two incompatible verbs all exit `2`. **No silent
  fallback, no silent drop** (PR #98 set this baseline). Tokenizing
  is delegated to `CLIKit` (sill): each domain declares a
  `CLIKit.Spec(arity:)` and `parseOrDie` maps any parse error to a
  loud exit `2`; wand keeps the policy on top via `requireOneVerb`
  (exactly one verb per domain). To add a verb, register it in two
  places in [Main.swift](Sources/WandApp/Main.swift): the domain's
  `CLIKit.Spec(arity:)` (pick `.flag` / `.value` / `.values(n)` /
  `.requiredThenOptional(n)`) and the domain's `requireOneVerb` list.

### TOML parser

- **TOML parsing is delegated to swift-toml-edit's `Toml` module**
  (Sill-1 — the family's one TOML implementation). wand reads its
  config via `Toml.parseFlat` (Config.swift), which natively supports
  arrays-of-tables (`[[cast.cursor.rule]]` / `[[cast.focused.rule]]` /
  `[[tome.cursor.item]]`). The former hand-rolled
  `Sources/WandCore/TOML.swift` (`parseTOMLSubset`, extended from
  facet's port) was removed when wand moved onto the shared lib. Rules
  still use the dotted-key style (`action-type` + `action-keys` /
  `action-verb` / `action-cmd` / `action-url`); the underlying lib is
  full TOML 1.0, so there is no local "~100-line parser budget" to defend.
- **Action vocabulary**: `key` (keystroke after `raise`), `ax`
  (verb in `Action.axVerbs` — no focus switch), `shell` (env vars
  carry the target), `url` (`NSWorkspace.shared.open` — handles
  `https://`, `file://`, and any custom scheme an installed app
  advertises). Adding a new variant means: a case on `Action` in
  [Sources/WandCore/Models.swift](Sources/WandCore/Models.swift),
  a parse branch in
  [Sources/WandCore/Config.swift](Sources/WandCore/Config.swift)
  `parseAction`, a dispatch branch in
  [Sources/WandAdapterMacOS/Dispatch.swift](Sources/WandAdapterMacOS/Dispatch.swift),
  and a string in `Main.swift` `actionDescription` (status/log
  formatter). The compiler's exhaustive-switch error flags any
  forgotten site.

### Recognition algorithm

- **Dominant-axis quantisation**:
  [Sources/WandCore/Recognition.swift](Sources/WandCore/Recognition.swift)
  walks samples, emits a Direction when the larger of |dx|, |dy|
  exceeds `minStrokePx`, then resets the anchor. Consecutive
  duplicate directions are coalesced — continuing left is one
  `L`, not many.
- **Y axis grows UP**. `dy > 0` ⇒ `.up`. Don't flip this; the
  test fixture (`testStraightDownThenRight`) pins the convention.
  Adapter samples come from `CGEvent.location` (CG global coords,
  Y-down) with a sign flip applied in
  [Sources/WandAdapterMacOS/EventTap.swift](Sources/WandAdapterMacOS/EventTap.swift)'s
  `flipY`. **Do not "simplify" by switching to
  `NSEvent.mouseLocation`** — when the tap swallows drag events
  AppKit never processes them, so the cursor cache that backs
  `NSEvent.mouseLocation` freezes at the button-down position and
  every sample reports the same coords. We learned this in M2's
  first-run (samples=600, max|dx|=0).
- **Tunable via `[cast].min-stroke-px`** in config.toml,
  clamped 4..200 by `WandConfig.parse`.

### Logging

- **`Log` lives in `WandCore`** so both the Adapter and App
  modules can call it without crossing layer rules. Two
  functions: `Log.line` (always on) and `Log.debug` (gated by
  `debugMode`, set from the `WAND_DEBUG` env var at startup —
  run.sh sets it; a brew/raw launch leaves it unset and stays
  quiet. There is no `--debug` flag).
- **Both write to `/tmp/wand.log`**; `WAND_DEBUG` also mirrors to
  stderr so foreground users see events live.
- **`mirrorLineToStderr`** is the `config --validate`-only escape hatch
  for surfacing `Log.line` (and only `Log.line`, never `Log.debug`)
  to stderr without flipping `debugMode`. `Log.lineCount` /
  `Log.resetLineCount()` let the caller turn the warning stream
  into a tally for the validation summary. Don't reach for these
  outside `config --validate`; for normal daemon foregrounding, set
  `WAND_DEBUG=1` instead.
- **Use `Log.debug` liberally** in EventTap / dispatch hot paths.
  It costs one bool check when disabled. Skip per-sample logging
  (mouse-moved fires too often even with the gate).

### Debugging — how Claude Code observes a running daemon

wand is **headless** (`LSUIElement`, no Dock icon, no window).
The agent cannot "look at the screen" to see what it's doing — so
the daemon is built to be debuggable entirely from the terminal.
The workflow:

1. **Run in the foreground with `WAND_DEBUG=1`** so events stream live:
   `WAND_DEBUG=1 .build/debug/wand`. This sets `debugMode = true`
   (enables `Log.debug`) and mirrors every log line to stderr in
   addition to `/tmp/wand.log`. (run.sh sets `WAND_DEBUG` for the
   `.app` launch automatically.)
2. **Tail the log** from a second shell: `tail -f /tmp/wand.log`.
   This is the single source of observability — there is nothing
   else to inspect.
3. **Read the trace.** A cast that fires end-to-end logs, in
   order:
   ```
   event-tap: down at (x,y) → target=com.google.Chrome
   event-tap: up — samples=512, pattern=DR
   controller: recognised DR on com.google.Chrome
   controller: → rule "close tab"
   dispatch.key: cmd+w → com.google.Chrome (pid …, wid …)
   ```
   Each missing line localises the failure to one stage
   (capture → recognition → match → dispatch).
4. **Interpret the diagnostics** in the "no stroke recognised" line
   (`samples=N, max|dx|=…, max|dy|=…, threshold=…`):
   - `samples=1` → the drag never streamed; the user clicked
     without moving, **or** a virtual-HID layer is eating
     `.rightMouseDragged` (see below).
   - `max|dx|`/`max|dy|` both `< threshold` → real motion but too
     small; raise sensitivity or draw bigger.
   - `target=nil` (with a recognised pattern) → cursor was over a
     non-AX surface (Dock, menu bar, desktop); the cast is
     dropped on purpose.
5. **Isolate recognition** with `wand cast --record` — it streams
   `pattern=… samples=… max|dx|=… target=…` to stdout for every
   stroke and fires **no actions**, so you can confirm the
   capture+recognition half without side effects. (Refuses if the
   daemon is already running — they'd fight over the tap.)
6. **Check config** with `wand config --validate` (exit 0 + rule count +
   warning count, or exit 2). Parser warnings (clamps / collisions
   / typos) mirror to stderr in addition to
   `/tmp/wand.log` so the user sees them without tailing the log.

**Known external interference to suspect first:** virtual-HID
remappers (Karabiner-Elements, Logitech Options, some KVMs) can
deliver button-held motion as `.mouseMoved` instead of
`.rightMouseDragged`, or swallow the drag entirely. The classic
symptom is `samples=1` on every stroke. wand masks `.mouseMoved`
to survive this; if a new "no samples" report appears, check
what's intercepting the HID stream before touching the tap code.

**AX grant after rebuild:** `swift build` ad-hoc re-signs the
binary, which can drop the Accessibility grant — the symptom is
`event-tap: tapCreate failed` in the log and no events at all.
Re-grant in System Settings, or use the persistent cert
(`setup-signing-cert.sh`) so the grant survives. Use
`pgrep -lf wand` to see what's running and `./stop.sh` to clear
stray instances before relaunching.

### Bundle / signing

- **Bundle id is `com.wand.wand`** (set in
  [Info.plist](Info.plist)). TCC keys the Accessibility grant
  to the code-signing identity, so ad-hoc signing loses the
  grant on every rebuild. [setup-signing-cert.sh](setup-signing-cert.sh)
  creates a persistent self-signed cert so the grant survives
  rebuilds; [package.sh](package.sh) assembles `Wand.app` and
  signs it with that identity (`--dev` →
  `Wand-dev.app` / `com.wand.wand.dev` to co-exist with a
  Homebrew install without TCC collision). Same pattern as facet.
- **`LSUIElement = true`** — no Dock icon, no menubar item. The
  daemon is intentionally invisible.

### CLI surface

- **Domain-verb surface (yabai-style).** wand is invoked
  `wand <domain> --<verb> [VALUE …]`; bare `wand` is server mode.
  Domains and verbs: `daemon --reload | --quit | --show | --resign`;
  `cast --test PATTERN [APP] | --record`; `tome --open | --validate`
  (modifiers `--items <PATH>` / `--at <X> <Y>` / `--selection <TEXT>`
  / `--title <TEXT>`); `config --validate | --doctor | --emit-schema`.
  Verbose logging is the `WAND_DEBUG` env var, not a flag — there is
  no `--debug` (passing it exits `2`). `CLIKit` (sill) owns
  tokenization: it parses each domain's argv against a per-domain
  `CLIKit.Spec(arity:)` (so `--at -100 50` negatives are consumed as
  values), and any unknown flag / arity error maps to a loud exit `2`
  via `parseOrDie`. wand layers the policy on top: `requireOneVerb`
  enforces exactly one verb per domain (zero verbs or two
  incompatible verbs both exit `2`), and an unknown domain exits via
  `CLIKit.die`. No three-pass processor / `valueArities` /
  `modifierFlags` allow-list exists any more.
- **`wand config --doctor`** reports Accessibility (`AXTarget.isTrusted()`),
  config, daemon liveness, and a live tap probe
  (`MacOSMouseSource.canInstallTap()` — a listen-only tap created and
  torn down). Exit 1 if AX/tap fail. **`wand cast --test PATTERN [bundle-id]`**
  dry-runs `Matcher` against config (no event tap touched).
- **`daemon --reload` / `daemon --quit` / `tome --open` talk to the
  running daemon over Distributed Notification Center**
  (`com.wand.app.control`,
  see [Sources/WandApp/Control.swift](Sources/WandApp/Control.swift)
  + `Controller.installCLIControl`) — same pattern as facet.
  Don't invent a different IPC. `tome --open` posts the `show-menu`
  DNC object (a wire constant, not a CLI flag) carrying
  `items`/`x`/`y`/`selection`/`title`. They exit `3` if no daemon is
  running; `cast --record` exits `3` if one *is* (tap conflict).
  `daemon --resign` re-signs the installed bundle with the persistent
  identity and restarts the daemon — a one-shot recovery after
  `brew install` / upgrade drops the TCC grant.
- **`daemon --show` is one-way the other direction**: DNC can't reply,
  so the daemon rewrites a small status file (`statusPath` =
  `/tmp/wand.status`) on start / reload / each recognised cast,
  and `daemon --show` just reads it (rule count, trigger, last
  gestures, counters, last reload). Don't reach for a request/response
  IPC — the file is enough.
- **Config auto-reload**: `ConfigWatcher`
  ([Sources/WandApp/ConfigWatcher.swift](Sources/WandApp/ConfigWatcher.swift))
  watches `WandConfig.path` with a `DispatchSource` vnode source
  and calls `controller.reload()` on edit (debounced; re-arms on the
  atomic-save rename/delete). `daemon --reload` is now just the
  manual trigger for the same path.
- **Login auto-start**: the Homebrew formula's `service do` block
  (`brew services start wand`) runs the bundle's executable via
  launchd; `keep_alive` is safe because an un-granted start doesn't
  crash (the app loop stays up).

## Conventions

- **Commit messages**: gitmoji-driven — `<:gitmoji:>[(<scope>)][!] <subject>`,
  where the leading `:code:` IS the type (the Conventional `<type>` word is
  retired; legacy `<type>(scope):` tokens are accepted and ignored by the lint,
  so old history still passes). `glyph rules` is the machine source of truth.
  Install the local hook once per clone: `glyph hook install`.
- **README is bilingual** ([README.md](README.md) English +
  [README.ja.md](README.ja.md) Japanese). Keep them in sync
  when user-visible behaviour changes — same rule as facet.
- After source edits, **`swift build` must pass** before
  finishing a turn.

## References

External material that informed wand's API / architecture
decisions. Subsections ordered broad → narrow.

### Architecture

- See [facet's CLAUDE.md → References → Architecture](https://github.com/akira-toriyama/facet/blob/main/CLAUDE.md)
  *(reviewed 2026-05-22)* — same hexagonal / Clean Architecture /
  DDD literature applies here. Don't re-list it.

### macOS / Apple

- [AXUIElementCopyElementAtPosition](https://developer.apple.com/documentation/applicationservices/1462091-axuielementcopyelementatposition)
  *(reviewed 2026-05-22)* — the single API the cursor-anchored
  spine hinges on. Returns the deepest AX element at a screen
  point; walk `kAXParentAttribute` up to `kAXWindowRole` to get
  the window.
- [Quartz Event Services (CGEventTap)](https://developer.apple.com/documentation/coregraphics/quartz_event_services)
  *(reviewed 2026-05-22)* — the global mouse-event capture
  mechanism. `.cgSessionEventTap` location + `tapOption.defaultTap`
  + `eventMask` for the configured trigger button.
- [Hardened Runtime / Code Signing](https://developer.apple.com/documentation/security/hardened_runtime)
  *(reviewed 2026-05-22)* — same TCC-Accessibility grant
  concern facet documents. Self-signed persistent identity
  keeps the grant stable across rebuilds.
- [NUIKit/CGSInternal (community)](https://github.com/NUIKit/CGSInternal)
  *(reviewed 2026-05-22)* — `_AXUIElementGetWindow` symbol used
  to resolve serverID from an AXUIElement. Same usage as facet's
  `AXFocus.swift`.
- [CGWindowListCopyWindowInfo](https://developer.apple.com/documentation/coregraphics/1455214-cgwindowlistcopywindowinfo)
  *(reviewed 2026-05-23)* — `AXTarget.windowAtPointViaCG`'s fallback
  source-of-truth. When `AXUIElementCopyElementAtPosition` returns an
  orphan renderer element (Chrome page content), this gives the
  on-screen window list in z-order with frame + owner pid; we then
  re-acquire the AX peer via `kAXWindows` on the owning app.

### Formats / conventions

- [TOML 1.0.0 spec](https://toml.io/en/v1.0.0)
  *(reviewed 2026-05-23)* — wand now consumes full TOML 1.0 via
  swift-toml-edit's `Toml` module (Sill-1), so the whole spec is
  available. The config still uses the dotted-key action style on
  `[[cast.cursor.rule]]` / `[[cast.focused.rule]]` / `[[tome.cursor.item]]`
  rows by convention, not by parser limitation (the retired
  hand-rolled `parseTOMLSubset` and its ≈100-line budget no longer
  apply — see `### TOML parser`).
- [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/)
  *(reviewed 2026-07-20)* — **retired ancestor**, kept for
  provenance only. Its `<type>(<scope>)<!>: <subject>` grammar is no
  longer what we write: the leading `:code:` is the type now (see
  Conventions). glyph's lint accepts a legacy `<type>(scope):` token
  and ignores it, so old history keeps passing — that is tolerance
  for the past, not a second legal form.
- [Gitmoji](https://gitmoji.dev/)
  *(reviewed 2026-07-20)* — the vocabulary the leading `:code:` is
  drawn from. Which code means what, and which bump it carries, is
  `glyph rules` (`--md` for the table) — the machine source of truth.
  Don't re-list it here and don't map codes back to the retired
  `feat` / `fix` words. The prose rules are the account-wide
  [CONTRIBUTING.md](https://github.com/akira-toriyama/.github/blob/main/CONTRIBUTING.md);
  CI enforces them via `commit-lint.yml`.

### GitHub

- [GitHub Docs (日本語)](https://docs.github.com/ja)
  *(reviewed 2026-05-23)* — primary reference for the bits this
  repo actually touches: `gh` CLI, Actions workflow syntax,
  release drafts, branch protection, fine-grained PAT scoping
  (the recurring foot-gun behind `HOMEBREW_TAP_TOKEN`).

### Inspiration

- [MGLAHK (pyonkichi)](https://ss1.xrea.com/pyonkichi.g1.xrea.com/mglahk.html)
  *(reviewed 2026-05-23)* — Japanese-language mouse-gesture
  utility; useful as prior art for direction-string rule shape,
  trigger button + modifier conventions, and the user-facing
  vocabulary native users expect ("ジェスチャー" / "アクション" /
  方向の表記). Reference for design feel, not for code.

## Shared libraries (atelier)

このアプリは swift app family の共有ライブラリに乗る（plan [atelier](https://github.com/akira-toriyama/atelier)）。
共有 lib が持つ責務は**再実装せずライブラリ側を拡張**する（北極星＝「facet の theme を真似て」を二度と言わない）。
モジュール → target の正確な配線は [Package.swift](Package.swift) を正とする。

- **[sill](https://github.com/akira-toriyama/sill)** — 共有 theming / CLI 基盤。設計 → [`docs/DESIGN.md`](https://github.com/akira-toriyama/sill/blob/main/docs/DESIGN.md)。wand が使う: `Palette` / `Effects`（line-pets・border）/ `CLIKit`（CLI tokenizer）/ `ConfigSchema`（taplo schema）。
- **[swift-toml-edit](https://github.com/akira-toriyama/swift-toml-edit)** — family 唯一の TOML 実装（`Toml` module・Swift 版 toml_edit）。wand は config.toml パースに使用。

**自己完結しない — 共有候補は sill に PR を模索**: app 単独で実装する前に「2 つ以上の app で冗長になりそうか」を問い、そうなら sill への PR を検討する（過剰共通化はしない・zero-debt ≠ 全部共有）。

## Roadmap board (GitHub Projects)

issue 運用（集約 Project「roadmap」#5・Inbox 既定 / Status フロー / `Closes #N`）は
family 共通ポリシー。正典 → https://github.com/akira-toriyama/atelier/blob/main/docs/roadmap-board.md
