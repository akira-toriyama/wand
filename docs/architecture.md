# wand — architecture

wand is a global mouse-gesture daemon for macOS, built around a
single invariant: gestures act on the **window under the cursor**,
not the focused one. On multi-display Macs the focused window is
often on a different display from where you're pointing, so a
gesture aimed at e.g. a Chrome tab on display 2 should fire against
that tab — not whatever happened to have focus on display 1.

The split into **Core / Adapter / App** is the central design idea
(same shape as [facet](https://github.com/akira-toriyama/facet)): the
pure-logic core knows nothing about CGEventTap, AX, or AppKit, so it
can be driven equally by a real CGEventTap (`WandAdapterMacOS`) or
by a fixture (`WandAdapterTest`) in unit tests.

## Layers

```
┌─────────────────────────────────────────────────────────┐
│  WandApp       @main, CLI argv, Controller wiring,      │
│                IPC observer for daemon --reload / --quit│  app
└──────────────────────┬──────────────────────────────────┘
                       │
              ┌────────┴────────┐
              │   WandCore      │  pure logic:
              │                 │   - Direction / Sample / Target
              │                 │   - Recognition (dominant-axis)
              │                 │   - Matcher (rule globs + excludes)
              │                 │   - WandConfig (TOML via swift-toml-edit)
              │                 │   - MouseSource protocol (the seam)
              │                 │  no AppKit / AX / CGEvent
              └────────┬────────┘
                       │
       ┌───────────────┴────────────────────────┐
       │                                        │
┌──────┴───────────────┐         ┌──────────────┴──────┐
│  WandAdapterMacOS    │         │  WandAdapterTest    │  adapter
│   CGEventTap +       │         │   SyntheticMouseSource │
│   AX target resolve  │         │   (no real mouse;   │
│   + Dispatch         │         │    feeds canned     │
│   (the only place    │         │    samples)         │
│   AX/CG/AppKit lives)│         │                     │
└──────────────────────┘         └─────────────────────┘
```

`WandCore` defines `MouseSource` — the protocol that emits one
`WandEvent` (target + samples) per completed stroke. The Controller
only ever sees `MouseSource`. Real vs synthetic is picked at app
startup. Adding a new mouse-input strategy means a new `MouseSource`
conformer in an Adapter module — never a `#if` in Core.

## The cursor-anchored spine

The whole point of wand is **cursor-anchored** action dispatch: an
action runs against the window the cursor was over when the trigger
button went down, never against whichever window has keyboard focus
by the time the action runs. This is the single home of that
narrative — CLAUDE.md lists only the constraints, README only the
user-visible consequence. Every decision below flows from the
contract:

- **Target captured at button-down**, not button-up and not at
  dispatch. By the time the user finishes drawing, focus may have
  moved entirely; that's a feature, not a bug.
  `AXTarget.resolveAt(point:)` is the single resolution point:
  `AXUIElementCopyElementAtPosition`, then walk `kAXParentAttribute`
  up to `kAXWindowRole`; `AXUIElementGetPid` + `NSRunningApplication`
  give the bundle id. When the walk dead-ends in an orphan renderer
  element (Chrome page content) it falls back to
  `CGWindowListCopyWindowInfo` and re-acquires the AX peer via
  `kAXWindows` — the log says `via ax-walk` or `via cg-window`.
- **`Target` is a value type** in
  [`Sources/WandCore/Models.swift`](../Sources/WandCore/Models.swift)
  — `pid`, `bundleID`, `title`, `frame`, `windowID`. The live
  `AXUIElement` stays in an adapter-side table keyed by
  `(pid, windowID)`; `Dispatch` looks it up at action time. Core
  never imports ApplicationServices.
- **`.key(...)` raises the specific window** before posting the
  keystroke (`Dispatch.raiseSpecificWindow`: AX `kAXFrontmost` on
  the app, `kAXMain` + `kAXFocused` + `kAXRaiseAction` on the
  window). Raising only the app would pick the app's last-focused
  window — exactly the failure mode the cursor-anchored design
  exists to avoid, recreated inside dispatch. Only when no live AX
  window exists (cursor was over the Dock or another non-AX surface)
  does it degrade to `NSRunningApplication.activate`, and it logs
  that it did.
- **`.ax(...)` acts directly on the window** via
  `AXUIElementPerformAction` — no focus switch, no keystroke. Less
  disruptive; prefer for close / minimize / zoom.
- **`.shell(...)` exports the target identity** as `WAND_TARGET_*`
  env vars so the user's command can decide. The shape of those
  variables is the [env-var contract](glossary.md#env-var-contract);
  the list users read is the comment above the rule tables in
  [`config.toml`](../config.toml).
- **Non-AX surfaces don't break the spine.** A cast landing on the
  Desktop / Dock / menu bar is dropped unless a `[[cast.focused.rule]]`
  opts into the frontmost-app fallback; a tome click there keeps only
  `apps = ["*"]` items. The [external trigger](glossary.md#external-trigger)
  (`wand tome --open`) is the one documented exception — it has no
  button-down moment, so it targets the frontmost app.

## Recognition

[`Recognition.swift`](../Sources/WandCore/Recognition.swift)
implements *dominant-axis quantisation*: walk samples accumulating
displacement from the last anchor; when `max(|dx|, |dy|)` exceeds
`minStrokePx`, emit a `Direction` whose axis is the dominant one and
reset the anchor. Consecutive duplicates are coalesced (continuing
left is one `L`, not many).

The alphabet is `L U R D` — single-letter cardinals are easy to
type in TOML and grep-friendly in logs. Y grows up — `dy > 0` ⇒
`.up`, pinned by `testStraightDownThenRight`. The adapter samples
from `CGEvent.location` (Y-down) and sign-flips Y at sample creation
to honour the convention.

## CLI surface

Four domains, each taking exactly one verb (`wand <domain> --<verb>`);
bare `wand` runs the agent. The verb list, arguments, and exit codes
are written once, in `printHelp()`
([`Sources/WandApp/Main.swift`](../Sources/WandApp/Main.swift)) —
run `wand --help`; this file only records the design behind it.

Verbs come in three modes. **Server** (bare `wand`) owns the
CGEventTap. **Client** verbs (`daemon --reload` / `--show` / `--quit`
/ `--resign`, `tome --open`) talk to the running daemon via
`DistributedNotificationCenter` (notification name
`com.wand.app.control` — deliberately distinct from the bundle id
so the bundle id can change without breaking clients) and exit 3 if
none is running; `daemon --show` reads the status file the daemon
rewrites (`/tmp/wand.status`) because DNC cannot reply.
**Standalone** verbs (`config --*`, `cast --test`, `tome --validate`)
touch neither; `cast --record` is standalone but refuses with exit 3
if a daemon *is* running, because both would fight over the same
CGEventTap. Tokenizing is delegated to `CLIKit` (sill);
`requireOneVerb` enforces the one-verb-per-domain mutex, and every
parse error exits 2 — no silent fallback.

## Tome panel

`MacOSLauncherSource`
([`Sources/WandAdapterMacOS/LauncherTap.swift`](../Sources/WandAdapterMacOS/LauncherTap.swift))
is a second `CGEventTap` beside `MacOSMouseSource`, so the
right-button-drag mask never has to also carry middle-click. The
Controller holds it optionally (`nil` unless `cfg.launcher.enabled`
at startup), so the tap isn't even allocated when the user hasn't
opted in. When AX target resolution fails (Dock / menu bar / Desktop
— cursor is over a non-AX surface) the tap substitutes a
`Target(bundleID: "", pid: 0, …)` sentinel instead of suppressing the
menu. `Matcher.appsAllow` then keeps `apps = ["*"]` items (truly
global ones — Spotlight, lock screen, open Terminal, …) and prunes
app-specific items; the app-icon header collapses because no
`NSRunningApplication` resolves under the empty bundle id. This
carves out a "menu still works on Desktop" path without breaking the
cursor-anchored spine for app-specific items.

`LauncherPanel`
([`Sources/WandAdapterMacOS/LauncherPanel.swift`](../Sources/WandAdapterMacOS/LauncherPanel.swift))
builds a tree of `NSPanel`s from `[LauncherItem]` filtered by the
cursor-anchored target. The root panel is a `NonActivatingPanel`
(subclass of `NSPanel`, `canBecomeKey = false` + `.nonactivatingPanel`
style mask) so it never steals keyboard focus from the underlying app
— the user keeps typing in their editor while picking a row.
`group = [...]` paths drive nesting: `PanelTree.build` walks each
item's group, creating folders on first reference and appending into
them on subsequent ones. A folder row shows a `chevron.right` SF
Symbol; hovering it spawns an adjacent child panel via
`PanelController.openChild`. The hand-off gap between panels is zero
so cursor traversal works straight-right; native NSMenu's
diagonal-cursor tolerance is not reproduced — hovering a non-folder
row in the parent closes the child.

`PanelLayout.resolveItemIcon` is the per-item icon resolver: it
recognises `SF:<name>` (`NSImage.systemSymbolName`, rendered with
`.medium` weight + `.large` scale so whitespace-heavy glyphs read the
same optical size as tight ones), `app:<bundle-id>`, file paths
(absolute / tilde / config-dir-relative), or falls back to drawing
the string as a glyph (emoji / 1-2 char text). Unresolvable specs log
once and collapse to no-icon; never throws.

**Dynamic items** (`dynamic = "..."` + `LauncherTemplate`) render as
folder-style rows with a chevron. Hovering one runs the shell via
`BoundedShell.run` (500 ms timeout) and pops a child panel populated
by `PanelLayout.expandDynamic`: each non-empty stdout line becomes a
synthetic leaf `LauncherItem` with `{line}` substituted in the
template's name / icon / payload. Errors (timeout, spawn fail,
non-zero exit, empty stdout) collapse to a single `(timeout)` /
`(spawn failed)` / `(error: exit N)` / `(no items)` placeholder row so
the user always sees something. Expansion happens at hover time, not
at panel-open time — the shell runs only when the user actually opens
the submenu, and re-runs on each re-open (no caching).

**Checkmark / radio state** is decoded inline in
`PanelLayout.renderItemLabel`: `"on"` / `"off"` / `"mixed"` for
static markers, `"shell:<cmd>"` for live eval at panel-open via
`BoundedShell.run` with a tight 100 ms budget. The resolved glyph
(`✓` / `–`) is prefixed to the row title; there is no native
`NSMenuItem.state` to lean on once we left NSMenu behind. An unknown
spec logs and falls through to no-marker.

## References

External material that informed the decisions above, each with the
date it was last checked against the code.

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
  *(reviewed 2026-05-22)* — the TCC-Accessibility grant is keyed to
  the signing identity; the persistent self-signed identity
  (`setup-signing-cert.sh`) keeps the grant stable across rebuilds.
- [NUIKit/CGSInternal (community)](https://github.com/NUIKit/CGSInternal)
  *(reviewed 2026-05-22)* — `_AXUIElementGetWindow` symbol used
  to resolve the window id from an AXUIElement
  (`AXTarget.swift`). Same usage as facet's `AXFocus.swift`.
- [CGWindowListCopyWindowInfo](https://developer.apple.com/documentation/coregraphics/1455214-cgwindowlistcopywindowinfo)
  *(reviewed 2026-05-23)* — `AXTarget.windowAtPointViaCG`'s fallback
  source-of-truth. When `AXUIElementCopyElementAtPosition` returns an
  orphan renderer element (Chrome page content), this gives the
  on-screen window list in z-order with frame + owner pid; we then
  re-acquire the AX peer via `kAXWindows` on the owning app.

### Formats

- [TOML 1.0.0 spec](https://toml.io/en/v1.0.0)
  *(reviewed 2026-05-23)* — wand consumes full TOML 1.0 via
  swift-toml-edit's `Toml` module, so the whole spec is available.
  The dotted-key action style on the rule / item rows is a
  convention, not a parser limitation.

### Inspiration

- [MGLAHK (pyonkichi)](https://ss1.xrea.com/pyonkichi.g1.xrea.com/mglahk.html)
  *(reviewed 2026-05-23)* — Japanese-language mouse-gesture
  utility; prior art for direction-string rule shape, trigger
  button + modifier conventions, and the user-facing vocabulary
  native Japanese users expect (the katakana loanwords for
  gesture / action, and the direction notation). Reference for
  design feel, not for code.

### Same family

- [CLAUDE.md](../CLAUDE.md) — the constraints to read before
  editing (Y-axis convention, side-table policy, TCC grant
  preservation, …)
- [safety-roadmap.md](safety-roadmap.md) — the five failsafe
  layers, which ship and which are planned
- [commit-convention.md](commit-convention.md) — pointer to the
  fleet commit convention
- [packaging/homebrew/README.md](../packaging/homebrew/README.md) —
  release flow + TCC grant persistence across `brew upgrade`
- [facet's architecture.md](https://github.com/akira-toriyama/facet/blob/main/docs/architecture.md)
  — same hexagonal pattern, different domain; its CLAUDE.md
  References list the hexagonal / Clean Architecture / DDD
  literature that applies here too
