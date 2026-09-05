# Safety roadmap — the five layers of defense

Design record for wand's failsafe architecture. The constraints that
hold **today** are in [CLAUDE.md → Safety invariants](../CLAUDE.md);
this file keeps the WHY of every planned layer on record so the PR
that eventually lands it doesn't re-derive the design. Each layer is
marked SHIPPED or PLANNED; a PLANNED item must not be referenced
anywhere else as if it were available.

wand grabs low-level mouse via CGEventTap. A bug, a crash, or a
swallowed event maps directly to **"the user's PC is now unusable"**
— the worst possible outcome for a tool whose own positioning is
"mouse enhancement". The rules below apply to every current trigger
family (cast, tome) and every future one (bolt, aura, scry, …). The
three PC-inoperable failure modes they guard against are listed in
CLAUDE.md.

## Five layers of defense

The full target architecture. Layers 1 and 2 ship today
(`FailsafeMonitor`); layers 3–5 are tracked follow-ups. Don't lean on
any single layer; combine them so one failure mode can't cascade.

1. **Button-hold timeout** — `[failsafe].mouse-hold-timeout-seconds`.
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

## Tap-internal invariants (code level — PLANNED, lands with bolt)

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
  [`Sources/WandAdapterMacOS/EventTap.swift`](../Sources/WandAdapterMacOS/EventTap.swift)
  to confirm mouseUp always reaches AppKit.
- **No "synthetic-down-in-flight" state** in the daemon. wand may
  post mouseUp synthetically; it must never post mouseDown
  synthetically. The asymmetry is the whole point: if wand
  crashes between a synthetic-down and the matching synthetic-up,
  the OS has no way to recover. Crashing with no synthetic-down
  in flight is safe because the OS uninstalls the tap and every
  real event flows through.

## Adding a new trigger family

Every new trigger (planned bolt's left-drag-shake, planned scry's
AX observation, anything future) goes through this checklist:

1. If the daemon crashes mid-trigger, can the user still use the
   mouse normally?
2. Does the trigger post synthetic mouse events? If yes, only
   mouseUp, and only after a `buttonState` precondition check.
3. Is the trigger's progress state cleared by the emergency
   release sequence? Wire it into the release path.
4. Does `wand config --doctor` report the trigger's health? Add a probe.

## Re-checking the PLANNED markings

Before promoting any item above to SHIPPED, or before citing one as
available, measure:

```sh
rg -n -i 'release-all|tap-watchdog|\bbolt\b|\bscry\b' Sources Tests
```

Zero hits means the PLANNED markings are still current (last
measured 2026-09-04; `FailsafeMonitor`'s own `installHoldWatchdog`
is layer 1, not layer 5).
