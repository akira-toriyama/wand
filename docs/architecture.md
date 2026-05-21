# stroke — architecture

stroke is a global mouse-gesture daemon for macOS, built around a
single invariant: gestures act on the **window under the cursor**,
not the focused one. On multi-display Macs the focused window is
often on a different display from where you're pointing, so a
gesture aimed at e.g. a Chrome tab on display 2 should fire against
that tab — not whatever happened to have focus on display 1.

The split into **Core / Adapter / App** is the central design idea
(same shape as [facet](https://github.com/akira-toriyama/facet)): the
pure-logic core knows nothing about CGEventTap, AX, or AppKit, so it
can be driven equally by a real CGEventTap (`StrokeAdapterMacOS`) or
by a fixture (`StrokeAdapterTest`) in unit tests.

## Layers

```
┌─────────────────────────────────────────────────────────┐
│  StrokeApp     @main, CLI argv, Controller wiring,      │
│                IPC observer for --reload / --quit       │  app
└──────────────────────┬──────────────────────────────────┘
                       │
              ┌────────┴────────┐
              │   StrokeCore    │  pure logic:
              │                 │   - Direction / Sample / Target
              │                 │   - Recognition (dominant-axis)
              │                 │   - Matcher (rule globs + excludes)
              │                 │   - TOML parser, StrokeConfig
              │                 │   - MouseSource protocol (the seam)
              │                 │  AppKit / AX / CGEvent 非依存
              └────────┬────────┘
                       │
       ┌───────────────┴────────────────────────┐
       │                                        │
┌──────┴───────────────┐         ┌──────────────┴──────┐
│  StrokeAdapterMacOS  │         │  StrokeAdapterTest  │  adapter
│   CGEventTap +       │         │   SyntheticMouseSource │
│   AX target resolve  │         │   (no real mouse;   │
│   + Dispatch         │         │    feeds canned     │
│   (the only place    │         │    samples)         │
│   AX/CG/AppKit lives)│         │                     │
└──────────────────────┘         └─────────────────────┘
```

`StrokeCore` defines `MouseSource` — the protocol that emits one
`StrokeEvent` (target + samples) per completed stroke. The Controller
only ever sees `MouseSource`. Real vs synthetic is picked at app
startup. Adding a new mouse-input strategy means a new `MouseSource`
conformer in an Adapter module — never a `#if` in Core.

## The cursor-anchored spine

The whole point of stroke is **cursor-anchored** action dispatch.
Every decision below flows from that contract:

- **Target captured at button-down**, not button-up. By the time the
  user finishes drawing, focus may have moved entirely; that's a
  feature, not a bug. (`AXTarget.resolveAt(point:)` is the single
  resolution point — `AXUIElementCopyElementAtPosition` then walk
  parents to `kAXWindowRole`.)
- **`Target` is a value type** in
  [`Sources/StrokeCore/Models.swift`](../Sources/StrokeCore/Models.swift)
  — `pid`, `bundleID`, `title`, `frame`, `windowID`. The live
  `AXUIElement` stays in an adapter-side table keyed by
  `(pid, windowID)`; `Dispatch` looks it up at action time. Core
  never imports ApplicationServices.
- **`.key(...)` raises the specific window** (AX
  `kAXFrontmost` + `kAXMain` + `kAXRaiseAction`) before posting the
  keystroke. Raising only the app would pick the app's last-focused
  window — exactly the failure mode the cursor-anchored design
  exists to avoid, recreated inside dispatch.
- **`.ax(...)` acts directly on the window** via
  `AXUIElementPerformAction` — no focus switch, no keystroke. Less
  disruptive; prefer for close / minimize / zoom.
- **`.shell(...)` exports the target identity** as `STROKE_TARGET_*`
  env vars so the user's command can decide.

## Recognition

[`Recognition.swift`](../Sources/StrokeCore/Recognition.swift)
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

## CLI surface (M1–M4)

| Flag | Mode | Purpose |
|---|---|---|
| *(none)* | server | run the agent (CGEventTap loop) |
| `--debug` | server | mirror logs to stderr too |
| `--validate` | standalone | parse `~/.config/stroke/config.toml`, exit 0/2 |
| `--record` | standalone | interactive recorder; refuses if daemon running |
| `--reload` | client | tell running daemon to re-read config |
| `--quit` | client | terminate running daemon |
| `--help` | standalone | show help |

Client commands (`--reload`, `--quit`) talk to the running daemon via
`DistributedNotificationCenter` (notification name
`com.stroke.app.control` — deliberately distinct from the bundle id
so the bundle id can change without breaking clients). Refuse with
exit 3 if no daemon is running. `--record` is the inverse — it
refuses with exit 3 if one *is* running, because both would fight
over the same CGEventTap.

## References

- [CLAUDE.md](../CLAUDE.md) — non-obvious constraints to read before
  editing (Y-axis convention, side-table policy, TCC grant
  preservation, …)
- [commit-convention.md](commit-convention.md) — message format +
  release flow
- [facet's architecture.md](https://github.com/akira-toriyama/facet/blob/main/docs/architecture.md)
  — same hexagonal pattern, different domain
