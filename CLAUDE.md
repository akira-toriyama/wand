# CLAUDE.md

Guidance for working in this repository — only the constraints and
workflows that hold **today**. The design narrative lives in
[docs/architecture.md](docs/architecture.md), the planned failsafe
layers in [docs/safety-roadmap.md](docs/safety-roadmap.md), the
vocabulary in [docs/glossary.md](docs/glossary.md); don't paste
their content back here.

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
  draw a shape; the recogniser turns it into a `LURD` string; rules
  fire actions.
- **tome** (middle-click, opt-in via `[tome].enabled`): a
  **non-activating NSPanel** of `[[tome.cursor.item]]` rows near the
  cursor, sharing cast's action vocabulary; never takes keyboard
  focus.
- **`wand tome --open`** (external trigger CLI): an upstream trigger
  posts items + point + selection over DNC and the daemon pops the
  same panel against the frontmost app. **Spine exception** — no
  button-down moment.

Both native triggers share the **single invariant**: actions dispatch
to the window the cursor was over **at button-down time**, never to
whichever has focus by the time the action runs. The why and the
per-action mechanics are in
[docs/architecture.md](docs/architecture.md#the-cursor-anchored-spine).

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
macOS 26+, three-layer hexagonal split.

## Build / run

```sh
swift build                  # compile (CommandLineTools works)
swift test                   # tests — needs Xcode (XCTest); fails on CLT
.build/debug/wand --help   # smoke test
.build/debug/wand config --validate
./setup-signing-cert.sh      # once — persistent self-signed cert so the TCC grant survives rebuilds
./run.sh                     # ./package.sh + open Wand.app (sets WAND_DEBUG)
./run.sh --dev               # → Wand-dev.app / com.wand.wand.dev, co-exists with a brew install
./stop.sh                    # kill everything wand
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
  It's a separate `CGEventTap` from `MacOSMouseSource` — keep the two
  taps separate so the right-button-drag mask never has to also
  carry middle-click. On a non-AX surface the tap substitutes the
  `Target(bundleID: "", pid: 0, …)` sentinel rather than suppressing
  the menu — don't turn that into a `nil` / early return; the
  Desktop path depends on it
  ([architecture.md → Tome panel](docs/architecture.md#tome-panel)).
- **`LauncherPanel` lives in `WandAdapterMacOS` too**
  ([Sources/WandAdapterMacOS/LauncherPanel.swift](Sources/WandAdapterMacOS/LauncherPanel.swift)).
  Don't promote it to a separate module — same reasoning as
  `GestureOverlay`. The root panel must stay a `NonActivatingPanel`
  (`canBecomeKey = false` + `.nonactivatingPanel`); native NSMenu's
  diagonal-cursor tolerance is deliberately NOT reproduced. How the
  tree, icons, dynamic items, and checkmark state are built is in
  [architecture.md → Tome panel](docs/architecture.md#tome-panel).
- **`NSTrackingArea` MUST use `.activeAlways`** in `ItemRow`. wand
  is `LSUIElement` and the panel is non-activating, so
  `.activeInActiveApp` resolves to "never" and `mouseEntered` never
  fires — silently breaks hover highlight AND hover-to-expand. Cost
  us a debugging cycle once; the regression test is: open a folder
  row by hovering it (don't click — there's no click handler on
  folder rows).
- **Dynamic items expand at hover time, never at panel-open, and
  never cache** — the shell runs only when the user actually opens
  the submenu and re-runs on each re-open. `{line}` is untrusted —
  same caveat as `WAND_TARGET_TITLE`. Every error shape collapses
  to a placeholder row so the user always sees something.
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

The design narrative — why button-down, how each action type
reaches the target — is written once, in
[docs/architecture.md → The cursor-anchored spine](docs/architecture.md#the-cursor-anchored-spine).
Don't re-explain it here or in README; this section only lists the
constraints that keep it true:

- The target is captured at **button-down time**, NOT at button-up
  and NOT at dispatch. `AXTarget.resolveAt(point:)` is the single
  resolution point — don't add a second one.
- **`Target` is a value type** in
  [Sources/WandCore/Models.swift](Sources/WandCore/Models.swift).
  Don't put `AXUIElement` inside it — Core must stay free of
  Application Services types. The adapter keeps the live AX handle
  in a side-table keyed by `(pid, windowID)` and looks it up at
  dispatch time; the serialised `Target` is what flows through Core.
- `.key(...)` must raise the **specific window**
  (`Dispatch.raiseSpecificWindow`) before posting the keystroke.
  Raising only the app, or posting first, lands the key on
  whichever window last had focus — the failure mode the spine
  exists to avoid, recreated inside dispatch.
- `.ax(...)` skips raising entirely. Prefer it for close / minimize /
  zoom.
- **Env-var contract (wand#137)**: the contract is defined in
  [docs/glossary.md → env-var contract](docs/glossary.md#env-var-contract)
  and the variable list users read is the comment above the rule
  tables in [config.toml](config.toml). `Dispatch.execute(extraEnv:)`
  enforces the `WAND_` prefix (drops non-conforming keys loudly).
  New trigger families add one var each (`$WAND_SHELF_FILES` /
  `$WAND_SHELF_COUNT` for bolt, `$WAND_CLIPBOARD` / `$WAND_URL`
  reserved).
- **`wand tome --open` is the documented spine exception** — no
  button-down moment exists, so `Controller.handleShowMenu`
  ([Sources/WandApp/Controller.swift](Sources/WandApp/Controller.swift))
  resolves the target via `NSWorkspace.frontmostApplication`. Keep
  the carve-out there: the native trigger families (cast, middle-
  click tome) never take that path. `$WAND_SELECTION` is the only
  extra env var it adds; `WAND_TARGET_*` is still populated, from
  the frontmost app.

### Safety invariants — DO NOT regress this

wand grabs low-level mouse via CGEventTap. A bug, a crash, or a
swallowed event maps directly to **"the user's PC is now
unusable"** — the worst possible outcome for a tool whose own
positioning is "mouse enhancement". Three failure modes contradict
wand's reason for existing:

- left click cannot be released (stuck mid-drag)
- right click cannot be released (stuck mid-stroke)
- DnD cannot be released (synthetic mouseUp lost, or tap holds the
  drag stream)

**`[failsafe]` is a mandatory config block.** Missing block → wand
refuses to start, and `wand config --validate` flags it as fatal.
This is the one deliberate inversion of the clamp-to-default rule.
The rationale is written once, in the `[failsafe]` block comment of
[config.toml](config.toml) — keep it there; README and this file
only point at it.

**What ships today** is `FailsafeMonitor`
([Sources/WandAdapterMacOS/FailsafeMonitor.swift](Sources/WandAdapterMacOS/FailsafeMonitor.swift)):
the button-hold timeout (`mouse-hold-timeout-seconds`) and the
emergency release key (`emergency-release-key`, a passive
`NSEvent` global monitor whose release sequence is idempotent and
logs only when it actually released something — an empty log is
healthy). Each knob's behaviour is documented on the key in
config.toml.

**Rules that hold now, regardless of roadmap:**

- Nothing in wand posts a synthetic mouseDown, ever. Synthetic
  mouseUp is allowed only behind a `CGEventSource.buttonState`
  precondition, in one place — today that place doesn't exist.
- The cast tap must never swallow mouseUp on any error path; a
  crashed daemon is recoverable (the OS uninstalls the tap), a
  held mouseUp is not.
- Adding a trigger family (bolt, scry, anything future) goes
  through the checklist in
  [docs/safety-roadmap.md](docs/safety-roadmap.md), which also
  records the three PLANNED layers (`--release-all`, tap-internal
  invariants, tap watchdog). Never cite a PLANNED item as
  available.

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
- **Value-convention discipline.** The three value shapes (`"off"`
  for a disabled enum, `""` for an inherit-from-theme string, `[]`
  for an empty array) are defined once, under "Value conventions"
  in the header of [config.toml](config.toml). Pick the matching
  shape when adding a field; don't introduce a parallel `"none"` or
  let a fourth convention drift in.
- **Prefer the nested-sub-block style** when a config feature has
  multiple knobs that share a domain — keys live inside the
  sub-block that owns them (`[foo].color` + `[bar].color`), even if
  some keys repeat across sub-blocks, rather than one top-level key
  bleeding into both. This is a *want / better*, not a *must*. The
  exception is a setting that genuinely spans both sub-blocks and
  would invite drift if duplicated — `[cast].intensity` (scales
  both `[cast.overlay.cards]` and `[cast.fire.burst]`) and
  `[exclude].apps` (applies to both cast rules and tome entries)
  live at the higher scope on purpose; the comment at the call site
  explains why. Default to the nested form, and justify in a
  comment when promoting a key upward.
- **The same discipline applies to the CLI** — breaking changes to
  the verb surface are OK, and the loud-reject policy is the CLI's
  counterpart of clamp-to-default. Both are spelled out under
  `### CLI surface` below.

### TOML parser and action vocabulary

- **TOML parsing is delegated to swift-toml-edit's `Toml` module**
  (the family's one TOML implementation); wand reads its config via
  `Toml.parseFlat` in [Sources/WandCore/Config.swift](Sources/WandCore/Config.swift),
  which natively supports the arrays-of-tables
  (`[[cast.cursor.rule]]` / `[[cast.focused.rule]]` /
  `[[tome.cursor.item]]`). Don't hand-roll a parser again. The
  dotted-key action style (`action-type` + `action-keys` /
  `action-verb` / `action-cmd` / `action-url`) is a convention, not
  a parser limitation.
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

The algorithm itself (dominant-axis quantisation, the `L U R D`
alphabet, coalescing) is described once in
[docs/architecture.md → Recognition](docs/architecture.md#recognition);
the code is [Sources/WandCore/Recognition.swift](Sources/WandCore/Recognition.swift).
Constraints:

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
   event-tap: down at (x, y) → com.google.Chrome (pid …, wid …)
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
   warning count; 1 on a schema violation; 2 if unparseable). Parser
   warnings (clamps / collisions / typos) mirror to stderr in addition to
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
  [Info.plist](Info.plist)). Why the Accessibility grant is keyed
  to the signing identity, and how the persistent self-signed cert
  keeps it across rebuilds and `brew upgrade`, is explained once in
  the header of [setup-signing-cert.sh](setup-signing-cert.sh)
  (including why the cert never shows in
  `find-identity -v -p codesigning`). [package.sh](package.sh)'s
  header explains the `--dev` flavour (`Wand-dev.app` /
  `com.wand.wand.dev`, a separate TCC entry beside a Homebrew
  install). Point at those headers instead of restating them.
- **`LSUIElement = true`** — no Dock icon, no menubar item. The
  daemon is intentionally invisible.

### CLI surface

- **Domain-verb surface (yabai-style).** wand is invoked
  `wand <domain> --<verb> [VALUE …]`; bare `wand` is server mode.
  The verb list, per-verb semantics, and exit codes are written once,
  in `printHelp()` ([Sources/WandApp/Main.swift](Sources/WandApp/Main.swift)).
  README's CLI section and docs/architecture.md point at
  `wand --help` rather than copying it — keep it that way. Breaking
  changes to the verb surface are OK (rename + update `--help` /
  README in the same PR — no third-party tooling depends on it).
  Verbose logging is the `WAND_DEBUG` env var, not a flag — there is
  no `--debug` (passing it exits `2`).
- **Loud-reject policy (PR #98 set the baseline)**: an unknown
  domain, an unknown flag, a bad arity, zero verbs for a domain, or
  two incompatible verbs all exit `2` — no silent fallback, no
  silent drop. `CLIKit` (sill) owns tokenization: each domain
  declares a `CLIKit.Spec(arity:)` (so `--at -100 50` negatives are
  consumed as values) and `parseOrDie` maps any parse error to exit
  `2`; `requireOneVerb` enforces exactly one verb per domain, and an
  unknown domain exits via `CLIKit.die`. To add a verb, register it
  in two places in [Main.swift](Sources/WandApp/Main.swift): the
  domain's `CLIKit.Spec(arity:)` (pick `.flag` / `.value` /
  `.values(n)` / `.requiredThenOptional(n)`) and the domain's
  `requireOneVerb` list.
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
  so old history still passes). The repo's [glyph.toml](glyph.toml) is the
  machine source of truth; the prose rules are the fleet
  [CONTRIBUTING.md](https://github.com/akira-toriyama/.github/blob/main/CONTRIBUTING.md).
  Install the local hook once per clone: `glyph hook install`.
- **Docs are English-only and code-first** — follow the fleet
  [doc-consistency policy](https://github.com/akira-toriyama/.github/blob/main/docs/doc-consistency-policy.md)
  (no stored translations — a JA reader translates the EN docs on
  demand; truth lives in the code/CLI, docs point to it).
- After source edits, **`swift build` must pass** before
  finishing a turn.

## References

The external material behind the architecture (AX / CGEventTap /
CGWindowList APIs, the TOML spec, the MGLAHK prior art) is listed
with review dates in
[docs/architecture.md → References](docs/architecture.md#references),
next to the decisions it informed. Commit-convention references are
the fleet [CONTRIBUTING.md](https://github.com/akira-toriyama/.github/blob/main/CONTRIBUTING.md).

## Shared libraries (atelier)

This app sits on the swift app family's shared libraries (plan:
[atelier](https://github.com/akira-toriyama/atelier)). A responsibility a
shared lib owns is **extended on the library side, never reimplemented here**
(the north star: never again say "imitate facet's theme"). The exact
module → target wiring is canonical in [Package.swift](Package.swift).

- **[sill](https://github.com/akira-toriyama/sill)** — shared theming / CLI
  foundation. Design → [`docs/DESIGN.md`](https://github.com/akira-toriyama/sill/blob/main/docs/DESIGN.md).
  wand uses: `Palette` / `Effects` (line-pets, border) / `CLIKit` (CLI
  tokenizer) / `ConfigSchema` (taplo schema).
- **[swift-toml-edit](https://github.com/akira-toriyama/swift-toml-edit)** —
  the family's only TOML implementation (`Toml` module, a Swift port of
  toml_edit). wand uses it to parse config.toml.

**Don't be self-contained — a sharing candidate goes to sill as a PR**: before
implementing app-side, ask "would this become redundant across 2+ apps?" — if
so, consider a sill PR (no over-generalization either; zero-debt ≠ share
everything).

## Roadmap board (GitHub Projects)

Issue handling (the aggregate Project "roadmap" #5, Inbox as the default
lane, the Status flow, `Closes #N`) is family-wide policy. Canonical doc →
https://github.com/akira-toriyama/atelier/blob/main/docs/roadmap-board.md
