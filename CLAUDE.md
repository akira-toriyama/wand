# CLAUDE.md

Guidance for working in this repository.

## What this is

`stroke` — global mouse-gesture daemon for macOS. Inspired by
[MacGesture](https://github.com/MacGesture/MacGesture) and
[xGestures](https://www.briankendall.net/xGestures/), built to
solve the one thing they don't:
[MacGesture#115](https://github.com/MacGesture/MacGesture/issues/115)
— gestures must act on the window under the cursor, not the
focused one. Architecturally a sibling of
[facet](https://github.com/akira-toriyama/facet): Swift 6,
macOS 13+, three-layer hexagonal split.

## Build / run

```sh
swift build                  # compile (CommandLineTools works)
swift test                   # tests — needs Xcode (XCTest); fails on CLT
.build/debug/stroke --help   # smoke test
.build/debug/stroke --validate
```

Same XCTest constraint as facet — CommandLineTools alone can't
run tests; let CI cover them. `swift build` is the bar locally.

`@main enum StrokeApp` lives in
[Sources/StrokeApp/Main.swift](Sources/StrokeApp/Main.swift)
(NOT top-level code in a `main.swift`) so XCTest's executable-target
`@testable import` keeps working once test coverage of the CLI lands.
**Don't reintroduce a `main.swift` file** — same trap as facet /
ws-tabs.

## Non-obvious constraints — read before editing

### Layer rules (the spine of the project)

- **3 layers are non-negotiable**: `StrokeCore` is pure logic
  (CoreGraphics OK, NO AppKit / NO CGEvent / NO AX).
  `StrokeAdapterMacOS` wraps the OS (CGEventTap, AX,
  CGEvent post, NSRunningApplication) and is the *only* place
  those types appear. `StrokeAdapterTest` is the synthetic
  counterpart for end-to-end recognition tests.
  Crossing layers always means there's a missing protocol.
- **`MouseSource` is the seam**:
  [Sources/StrokeCore/MouseSource.swift](Sources/StrokeCore/MouseSource.swift)
  declares the protocol; the Controller only ever sees
  `MouseSource`. Real vs synthetic is picked at app startup.
  Adding a new mouse-input strategy means a new `MouseSource`
  conformer in an Adapter module — never a `#if` in Core.

### The issue #115 spine — DO NOT regress this

The whole point of stroke is that **actions dispatch to the
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
  [Sources/StrokeCore/Models.swift](Sources/StrokeCore/Models.swift).
  Don't put `AXUIElement` inside it — Core must stay free of
  Application Services types. If the dispatcher needs the live
  AX handle (for `.ax(...)` actions), the adapter keeps a
  side-table keyed by pid + serverID and looks it up at dispatch
  time. The serialised `Target` is what flows through Core.
- `.key(...)` actions raise the target first (via
  `NSRunningApplication.activate`), THEN post the keystroke.
  Posting before raising would land the key on whoever has focus
  — that's the MacGesture bug.
- `.ax(...)` actions skip raising and call
  `AXUIElementPerformAction` directly. Less disruption, no
  focus stolen. Prefer `ax` for close/minimize/zoom.
- `.shell(...)` actions get the target identity via env vars
  (`STROKE_TARGET_BUNDLE_ID`, `STROKE_TARGET_PID`,
  `STROKE_TARGET_TITLE`, `STROKE_TARGET_FRAME`) — the user's
  command can decide what to do with that information.

### Configuration

- **`config.toml` at the repo root is the source-of-truth
  template**. Users `curl` it into `~/.config/stroke/config.toml`
  (see [README.md](README.md) Configuration section).
  **The app only reads it** — never writes, never auto-generates
  an example, never persists runtime overrides. Same policy as
  facet: the file is the only thing the user has to look at to
  know what stroke will do.
- **There is no settings GUI** — by design. Don't propose
  adding NSPanel-based preferences. The user can already see
  every option in one TOML file. Memory: facet's
  `config-default-behavior` pattern.
- **All TOML keys clamp out-of-range / unknown values to defaults**
  rather than rejecting. A typo can never break gesture
  recognition — the rule with the typo silently drops, the rest
  still load. `stroke --validate` is the explicit verification
  path.

### TOML parser

- **`parseTOMLSubset` is hand-rolled** in
  [Sources/StrokeCore/TOML.swift](Sources/StrokeCore/TOML.swift)
  — extended from facet's port with `[[array-of-tables]]`
  support because `[[rules]]` needs it. Inline tables (`{a=1,
  b=2}`) are **not** supported and rules use dotted-key style
  (`action-type` + `action-keys` / `action-verb` /
  `action-cmd`) instead. Don't add an inline-table parser
  without a real need; the dotted-key form keeps the parser
  ~100 lines.

### Recognition algorithm

- **Dominant-axis quantisation**:
  [Sources/StrokeCore/Recognition.swift](Sources/StrokeCore/Recognition.swift)
  walks samples, emits a Direction when the larger of |dx|, |dy|
  exceeds `minStrokePx`, then resets the anchor. Consecutive
  duplicate directions are coalesced — continuing left is one
  `L`, not many.
- **Y axis grows UP**. `dy > 0` ⇒ `.up`. Don't flip this; the
  test fixture (`testStraightDownThenRight`) pins the convention.
  Adapter samples come from `CGEvent.location` (CG global coords,
  Y-down) with a sign flip applied in
  [Sources/StrokeAdapterMacOS/EventTap.swift](Sources/StrokeAdapterMacOS/EventTap.swift)'s
  `flipY`. **Do not "simplify" by switching to
  `NSEvent.mouseLocation`** — when the tap swallows drag events
  AppKit never processes them, so the cursor cache that backs
  `NSEvent.mouseLocation` freezes at the button-down position and
  every sample reports the same coords. We learned this in M2's
  first-run (samples=600, max|dx|=0).
- **Tunable via `[recognition].min-stroke-px`** in config.toml,
  clamped 4..200 by `StrokeConfig.parse`.

### Logging

- **`Log` lives in `StrokeCore`** so both the Adapter and App
  modules can call it without crossing layer rules. Two
  functions: `Log.line` (always on) and `Log.debug` (gated by
  `debugMode`, set from `stroke --debug` at startup).
- **Both write to `/tmp/stroke.log`**; `--debug` also mirrors to
  stderr so foreground users see events live.
- **Use `Log.debug` liberally** in EventTap / dispatch hot paths.
  It costs one bool check when disabled. Skip per-sample logging
  (mouse-moved fires too often even with the gate).

### Bundle / signing

- **Bundle id is `com.stroke.stroke`** (set in
  [Info.plist](Info.plist)). TCC keys the Accessibility grant
  to the code-signing identity, so ad-hoc signing loses the
  grant on every rebuild. A `setup-signing-cert.sh` script
  (lands in M5) will create a persistent self-signed cert so
  the grant survives rebuilds — same pattern as facet.
- **`LSUIElement = true`** — no Dock icon, no menubar item. The
  daemon is intentionally invisible.

### CLI surface

- **`--validate`, `--debug`, `--help` are the only M1 flags**.
  Anything else exits `2` with a stderr message (no silent
  fallback — facet's *Rule of Repair* discipline).
- **`--record`, `--reload`, `--quit` land in M2/M4**. They will
  use Distributed Notification Center IPC to talk to the
  running daemon — same pattern as facet's
  `controller.installCLIControl`. Don't invent a different IPC.

## Conventions

- **Commit messages**: gitmoji + Conventional Commits (matches
  facet). `<:gitmoji:> <type>(<scope>)<!>: <subject>`. Enable
  the local hook when one is added: `git config core.hooksPath
  scripts/hooks`.
- **README is bilingual** ([README.md](README.md) English +
  [README.ja.md](README.ja.md) Japanese). Keep them in sync
  when user-visible behaviour changes — same rule as facet.
- After source edits, **`swift build` must pass** before
  finishing a turn.

## References

External material that informed stroke's API / architecture
decisions. Subsections ordered broad → narrow.

### Prior art (the apps stroke supersedes)

- [MacGesture](https://github.com/MacGesture/MacGesture)
  *(reviewed 2026-05-22)* — direction-alphabet, app-filtered
  rules. stroke's pattern syntax (`L U R D`) is intentionally
  identical so rule files port without retraining. The unsolved
  issue this app has is [#115](https://github.com/MacGesture/MacGesture/issues/115).
- [xGestures (Brian Kendall)](https://www.briankendall.net/xGestures/)
  *(reviewed 2026-05-22)* — older macOS gesture tool with
  configurable mouse buttons and modifier+drag triggers.
  Influenced stroke's `[trigger]` schema (button + modifier
  set rather than a single hard-coded right-click).

### Architecture

- See [facet's CLAUDE.md → References → Architecture](https://github.com/akira-toriyama/facet/blob/main/CLAUDE.md)
  *(reviewed 2026-05-22)* — same hexagonal / Clean Architecture /
  DDD literature applies here. Don't re-list it.

### macOS / Apple

- [AXUIElementCopyElementAtPosition](https://developer.apple.com/documentation/applicationservices/1462091-axuielementcopyelementatposition)
  *(reviewed 2026-05-22)* — the single API stroke's #115 fix
  hinges on. Returns the deepest AX element at a screen point;
  walk `kAXParentAttribute` up to `kAXWindowRole` to get the
  window.
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
