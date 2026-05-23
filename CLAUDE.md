# CLAUDE.md

Guidance for working in this repository.

## What this is

`stroke` — global mouse-gesture daemon for macOS. Built around a
single invariant: **gestures act on the window under the cursor,
not the focused one.** On multi-display Macs the focused window is
often on a different display from where you're pointing, so a
gesture aimed at e.g. a Chrome tab on display 2 should fire against
*that* tab — not whatever happened to have focus on display 1.

Architecturally a sibling of
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
- **The gesture-trail overlay lives in `StrokeAdapterMacOS`**, not a
  separate View module ([Sources/StrokeAdapterMacOS/GestureOverlay.swift](Sources/StrokeAdapterMacOS/GestureOverlay.swift)).
  It's the project's only on-screen UI; it's pure AppKit/CG rendering
  fed by the event-tap sample stream, so it belongs in the macOS
  adapter rather than justifying a facet-style View layer. Core stays
  UI-free — trail points cross the seam as plain `CGPoint`. **Don't
  promote it to its own module** unless a second UI surface appears.
  `MacOSMouseSource.onSample` / `onStrokeEnd` are the (non-`@Sendable`,
  main-thread-only) hooks that feed it; they're deliberately separate
  from the protocol's `@Sendable` stroke `handler` so they can capture
  the non-Sendable overlay.

### The cursor-anchored spine — DO NOT regress this

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
  — exactly the failure mode the cursor-anchored design exists
  to avoid.
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

### Debugging — how Claude Code observes a running daemon

stroke is **headless** (`LSUIElement`, no Dock icon, no window).
The agent cannot "look at the screen" to see what it's doing — so
the daemon is built to be debuggable entirely from the terminal.
The workflow:

1. **Run in the foreground with `--debug`** so events stream live:
   `.build/debug/stroke --debug`. This sets `debugMode = true`
   (enables `Log.debug`) and mirrors every log line to stderr in
   addition to `/tmp/stroke.log`.
2. **Tail the log** from a second shell: `tail -f /tmp/stroke.log`.
   This is the single source of observability — there is nothing
   else to inspect.
3. **Read the trace.** A gesture that fires end-to-end logs, in
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
     non-AX surface (Dock, menu bar, desktop); the gesture is
     dropped on purpose.
5. **Isolate recognition** with `stroke --record` — it streams
   `pattern=… samples=… max|dx|=… target=…` to stdout for every
   stroke and fires **no actions**, so you can confirm the
   capture+recognition half without side effects. (Refuses if the
   daemon is already running — they'd fight over the tap.)
6. **Check config** with `stroke --validate` (exit 0 + rule count,
   or exit 2).

**Known external interference to suspect first:** virtual-HID
remappers (Karabiner-Elements, Logitech Options, some KVMs) can
deliver button-held motion as `.mouseMoved` instead of
`.rightMouseDragged`, or swallow the drag entirely. The classic
symptom is `samples=1` on every stroke. stroke masks `.mouseMoved`
to survive this; if a new "no samples" report appears, check
what's intercepting the HID stream before touching the tap code.

**AX grant after rebuild:** `swift build` ad-hoc re-signs the
binary, which can drop the Accessibility grant — the symptom is
`event-tap: tapCreate failed` in the log and no events at all.
Re-grant in System Settings, or use the persistent cert
(`setup-signing-cert.sh`) so the grant survives. Use
`pgrep -lf stroke` to see what's running and `./stop.sh` to clear
stray instances before relaunching.

### Bundle / signing

- **Bundle id is `com.stroke.stroke`** (set in
  [Info.plist](Info.plist)). TCC keys the Accessibility grant
  to the code-signing identity, so ad-hoc signing loses the
  grant on every rebuild. [setup-signing-cert.sh](setup-signing-cert.sh)
  creates a persistent self-signed cert so the grant survives
  rebuilds; [package.sh](package.sh) assembles `Stroke.app` and
  signs it with that identity (`--dev` →
  `Stroke-dev.app` / `com.stroke.stroke.dev` to co-exist with a
  Homebrew install without TCC collision). Same pattern as facet.
- **`LSUIElement = true`** — no Dock icon, no menubar item. The
  daemon is intentionally invisible.

### CLI surface

- **Flags**: `--debug` (server, verbose), `--validate` /
  `--doctor` / `--test` / `--record` / `--help` (standalone),
  `--reload` / `--quit` / `--status` (client). Any unrecognised
  flag exits `2` with a stderr message (no silent fallback —
  facet's *Rule of Repair* discipline). **`--test` takes an operand**
  (the pattern), so it's handled *before* the unknown-flag scan would
  reject that operand — keep that ordering if adding more
  value-taking flags.
- **`--doctor`** reports Accessibility (`AXTarget.isTrusted()`),
  config, daemon liveness, and a live tap probe
  (`MacOSMouseSource.canInstallTap()` — a listen-only tap created and
  torn down). Exit 1 if AX/tap fail. **`--test PATTERN [bundle-id]`**
  dry-runs `Matcher` against config (no event tap touched).
- **`--reload` / `--quit` talk to the running daemon over
  Distributed Notification Center** (`com.stroke.app.control`,
  see [Sources/StrokeApp/Control.swift](Sources/StrokeApp/Control.swift)
  + `Controller.installCLIControl`) — same pattern as facet.
  Don't invent a different IPC. They exit `3` if no daemon is
  running; `--record` exits `3` if one *is* (tap conflict).
- **`--status` is one-way the other direction**: DNC can't reply, so
  the daemon rewrites a small status file (`statusPath` =
  `/tmp/stroke.status`) on start / reload / each recognised gesture,
  and `--status` just reads it. Don't reach for a request/response
  IPC — the file is enough.
- **Config auto-reload**: `ConfigWatcher`
  ([Sources/StrokeApp/ConfigWatcher.swift](Sources/StrokeApp/ConfigWatcher.swift))
  watches `StrokeConfig.path` with a `DispatchSource` vnode source
  and calls `controller.reload()` on edit (debounced; re-arms on the
  atomic-save rename/delete). `--reload` is now just the manual
  trigger for the same path.
- **Login auto-start**: the Homebrew formula's `service do` block
  (`brew services start stroke`) runs the bundle's executable via
  launchd; `keep_alive` is safe because an un-granted start doesn't
  crash (the app loop stays up).

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
