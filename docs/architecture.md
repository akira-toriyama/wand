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

## References

- [CLAUDE.md](../CLAUDE.md) — non-obvious constraints to read before
  editing (Y-axis convention, side-table policy, TCC grant
  preservation, …)
- [commit-convention.md](commit-convention.md) — pointer to the
  fleet commit convention
- [packaging/homebrew/README.md](../packaging/homebrew/README.md) —
  release flow + TCC grant persistence across `brew upgrade`
- [facet's architecture.md](https://github.com/akira-toriyama/facet/blob/main/docs/architecture.md)
  — same hexagonal pattern, different domain
