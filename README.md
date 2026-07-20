# wand

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)
![swift](https://img.shields.io/badge/Swift-6.0-orange)
![license](https://img.shields.io/badge/license-MIT-blue)

**English** · [日本語](README.ja.md)

A global mouse-gesture daemon for macOS. Hold a mouse button, draw a
short shape with the cursor — down, then right — and wand fires an
action: close a tab, reopen one, minimize a window, run a shell
command. The action runs against the window the cursor was over when
you started drawing.

## Cast — drawn-pattern trigger

Draw with the trigger button held down (right mouse by default). A
cast is a sequence of cardinal directions:

```
L = left    U = up    R = right    D = down
```

So `DR` is down-then-right, `URD` is up → right → down. When you
release the button, wand matches the shape against your rules and
runs the first match. A shape that matches nothing — or barely
moving at all — does nothing, and a plain click still behaves like a
normal click.

Out of the box (the bundled [`config.toml`](config.toml)):

| Draw | Action | Where |
|---|---|---|
| `DR` down → right | close the current tab (`cmd+w`) | Chrome / Safari |
| `UR` up → right | reopen last closed tab (`cmd+shift+t`) | Chrome / Safari |
| `DRU` down → right → up | close the window | any app |
| `L` left | minimize the window | any app |

A translucent trail follows the cursor as you draw — match color
while the shape so far fires a rule, no-match color once it doesn't.
Around the cursor, small cards lay out **what's reachable from here**
in the direction of each card's next arrow, and the one that fires
right now is tinted in the match color. At the gesture's start point
a small badge shows the **target app's icon** so the window wand
will act on is unambiguous even when keyboard focus sits elsewhere.

Visual knobs live in scoped sub-blocks of `[cast.overlay]`:
the trail line itself in `[cast.overlay.trail]`, the origin
badge in `[cast.overlay.badge]`, and the assist-card exit
animations in `[cast.overlay.cards]`.

The assist cards can animate out — drop, slide, explode, vibrate,
or burst with fireworks / confetti particles. Pick one effect for
the moment a card becomes unreachable mid-gesture (`unmatch`) and
another for the moment a rule actually fires (`match`), both in
`[cast.overlay.cards]`. Default is silent. Fire-moment effects
that work even when the trail overlay is off — the trail-end burst
in `[cast.fire.burst]` and the post-fire ink decal in
`[cast.fire.decal]` — live separately.

Actions target the window **under the cursor**, not whichever window
holds keyboard focus: `ax` actions operate on it directly, `key`
actions raise it first and send the keystroke, and `shell` actions
receive its identity (bundle id, pid, title, frame) as environment
variables.

## Tome — middle-click menu (opt-in)

wand also ships a **middle-click contextual menu** as a second
trigger. Off by default — set `[tome].enabled = true` in your
config and the daemon installs a second event tap alongside the
cast one. The tome renders as a **non-activating panel** that
keeps the source app focused: it floats above the underlying app
*without* stealing keyboard focus, so you can keep typing in your
editor while picking a row with the mouse. Submenus open on hover
as an adjacent child panel (`group = ["..."]`). Click outside or
press Esc to dismiss. The panel is anchored to the **window
under the cursor at button-down** — same invariant as the cast
path. Each `[[tome.cursor.item]]` is one row:

```toml
[tome]
enabled = true
button = "middle"                 # or "side1" / "side2" / "right"

[[tome.cursor.item]]
name = "New Tab"
icon = "🌐"                        # emoji / SF:<name> / file path
apps = ["*chrome*", "*safari*"]
action-type = "key"
action-keys = "cmd+t"

[[tome.cursor.item]]
name = "By Name"
icon = "SF:textformat.abc"         # macOS SF Symbol
group = ["Sort"]                   # nests this row inside a "Sort" submenu
separator-before = true            # divider line above the row
action-type = "shell"
action-cmd = "echo name"
```

Item `icon` syntax: `"🌐"` (emoji / 1-2 char text glyph), `"SF:globe"`
(SF Symbol — macOS 11+), `"app:com.apple.Safari"` (the running app's
icon for that bundle id), `"~/icons/foo.png"` / `"icons/foo.png"`
(path; relative paths resolve against `~/.config/wand/`), or
`"/abs/path.png"`. Unrecognised values fall back to no icon and log
once to `/tmp/wand.log`.

Tome entries can be **reordered by drag & drop**: drag an entry and
drop it above or below another to rearrange the panel (list layout
only).
The new order is **session-only** — a config reload or daemon
restart discards it and the `config.toml` document order applies
again. To make an order permanent, reorder the
`[[tome.cursor.item]]` tables in `config.toml`.

Each row also accepts `subtitle`, a `header` separator, and
`tint` / `tint-colors` / `icon-anim` for SF-Symbol icons — see
[`config.toml`](config.toml) for the full per-row vocabulary. Panel-
wide visual settings live in `[tome.row]`, `[tome.animation]`
(`open` / `close` ∈ `off | fade | pop`), and `[tome.decoration]`
(`border ∈ off | rainbow`). `[tome].layout` switches the panel
between `list`, `toolbar`, and `labeled-toolbar`.

Items can also produce **dynamic submenus**. Set `dynamic` to a
shell command and provide `template-*` fields; each stdout line
becomes one child item with `{line}` substituted in the template:

```toml
[[tome.cursor.item]]
name = "Switch Branch"
icon = "SF:point.3.connected.trianglepath.dotted"
dynamic = 'cd ~/repo && git branch --format="%(refname:short)"'
template-name = "{line}"
template-icon = "SF:arrow.triangle.branch"
template-action-type = "shell"
template-action-cmd  = 'cd ~/repo && git switch "{line}"'
```

The shell is killed after 500 ms if it hangs; empty stdout / non-
zero exit / timeout show a disabled placeholder (`(no items)` /
`(error: exit N)` / `(timeout)`). Quote `{line}` substitutions in
shell commands — the line content is untrusted.

Items can also carry a **checkmark state** via `state`:

```toml
[[tome.cursor.item]]
name = "Dark Mode"
state = "shell:defaults read -g AppleInterfaceStyle 2>/dev/null | grep -q Dark"
action-type = "shell"
action-cmd  = "..."
```

`state` accepts `"on"` / `"off"` / `"mixed"` for static markers,
or `"shell:<cmd>"` to evaluate live at menu-open (exit 0 → ✓,
100 ms timeout).

Items with `apps = ["*"]` (or `apps` omitted) **also fire on the
Dock, menu bar, and Desktop** — places where no AX target resolves
under the cursor. App-specific items there are filtered out
automatically. Good fit for Spotlight, lock screen, "open
Terminal", etc.

### Selection-aware shell items (`$WAND_SELECTION`)

Shell actions launched from the menu also see a `$WAND_SELECTION`
env var carrying the text selected in the focused element at the
moment you middle-clicked. Use it for translate / search /
send-to-app workflows:

```toml
[[tome.cursor.item]]
name = "Translate"
icon = "SF:globe"
action-type = "shell"
action-cmd = 'open "https://translate.google.com/?sl=auto&tl=en&text=$(printf %s "$WAND_SELECTION" | sed "s/ /%20/g")"'
```

Every wand env var is `WAND_`-prefixed, and a context that doesn't
exist is left **unset** — never set to an empty string — so a
command can branch on presence:
`[ -n "${WAND_SELECTION:-}" ] && …`. `$WAND_SELECTION` is unset
when nothing is selected or the focused app doesn't expose AX
selection.

Quote `$WAND_SELECTION` in shell commands — the content is
whatever the user happened to highlight (URLs, code, shell
metacharacters), and is **untrusted** in the same sense
`WAND_TARGET_TITLE` is.

### Conditional filters (`filter-title` / `filter-shell`)

`apps` decides which apps a rule / item belongs to.
**`filter-title`** narrows that with a window-title glob, and
**`filter-shell`** is an escape hatch — a `/bin/sh -c` predicate
that decides at match time whether the row applies. Both work on
`[[cast.cursor.rule]]` and `[[tome.cursor.item]]`:

```toml
[[tome.cursor.item]]
name = "Open as PR"
icon = "SF:arrow.triangle.pull"
apps = ["*chrome*"]
filter-title = "*github.com*/issues/*"      # only on a GitHub issue
action-type = "url"
action-url = "..."

[[tome.cursor.item]]
name = "Late-night ping"
filter-shell = "test $(date +%H) -ge 22"    # only after 22:00
action-type = "shell"
action-cmd  = "afplay /System/Library/Sounds/Glass.aiff"
```

`filter-title` is sub-microsecond (in-process glob against the
title captured at button-down / click). `filter-shell` is ~5-20 ms
per row (process spawn), 100 ms hard timeout — use sparingly.

## Install

```sh
brew install akira-toriyama/tap/wand
curl --create-dirs -o ~/.config/wand/config.toml \
  https://raw.githubusercontent.com/akira-toriyama/wand/main/config.toml
open "$(brew --prefix)/opt/wand/Wand.app"   # triggers AX prompt
```

Then grant **Accessibility** to *wand* (System Settings → Privacy
& Security → Accessibility) and launch the daemon with `wand`.

To start it automatically at login:

```sh
brew services start wand
```

The formula bundles a `Wand.app` (LSUIElement — no Dock icon) plus
a stable self-signed code-signing identity created in your login
keychain on first install, so the Accessibility grant persists across
`brew upgrade wand`. If the keychain isn't reachable during install,
the formula falls back to ad-hoc signing and prints a loud warning
with a one-line recovery path. Details:
[packaging/homebrew/](packaging/homebrew/).

## Configuration

wand is **config.toml-driven** — there is no settings GUI by
design. The `curl` line above drops the template at
`~/.config/wand/config.toml`. Out-of-range / unknown values clamp
silently to defaults — a typo can never break the daemon. Validate
explicitly with `wand config --validate`.

> **`[failsafe]` is mandatory.** It defines the safety nets that
> catch a stuck click / drag (button-hold timeout, Esc emergency
> release). The bundled template ships it; **don't delete the
> block** — `wand config --validate` and daemon startup both refuse to
> run without it. See the `[failsafe]` block in
> [`config.toml`](config.toml) for the knobs.

A rule looks like this:

```toml
[[cast.cursor.rule]]
name = "close tab"
icon = "SF:xmark.square"              # optional — drawn next to `name` in the assist card
pattern = "DR"                        # down → right
apps = ["*chrome*", "*safari*"]       # matches the window under the cursor
action-type = "key"
action-keys = "cmd+w"
```

`icon` mirrors `[[tome.cursor.item]].icon` syntax — SF Symbols
(`"SF:globe"`), emoji / text glyphs (`"🌐"`), installed app icons
(`"app:com.apple.Safari"`), or a file path. Empty / omitted = no
icon (the assist card just shows arrow + name).

Pattern alphabet is `L U R D` (left / up / right / down) —
**no consecutive duplicates**, because the recogniser coalesces
same-direction motion into one segment (`LLLL…` is `L`, not `LL`).
A rule whose pattern repeats a direction (`DRR`, `LL`, …) is
unreachable; `wand config --validate` drops it loudly. Scroll-axis
directions are not recognised yet. Action types are `key` (a
keystroke), `ax` (`close` / `minimize` / `zoom` / `raise`), and
`shell` (any command), `url` (`https://`, `slack://`, `file://`,
any custom scheme an installed app advertises — via
`NSWorkspace.shared.open`).

`apps` is a glob list with positive entries (`*chrome*`,
`com.apple.Safari`, `*` for any) and `!`-prefixed exclusions. The
rule applies when **at least one positive entry matches** (or none
exists) **and no `!` entry matches**. Case-insensitive. Examples:

| `apps =` | Applies to |
|---|---|
| `["*chrome*"]` | only Chrome (or anything whose bundle id contains "chrome") |
| `[]` *or* `["*"]` | every app |
| `["!com.apple.dt.Xcode"]` | every app **except** Xcode |
| `["*", "!*.chrome.beta*"]` | every app except Chrome's beta channel |
| `["*chrome*", "*safari*"]` | Chrome OR Safari |

Globally suppress cast and tome in specific apps via
`[exclude].apps` (e.g. block wand inside a remote-desktop client).
The list short-circuits both trigger families before rule / item
matching runs.

Trail style, origin-badge size, blur on the overlay, final-hold
fade time, and many more visual knobs live in
`[cast.overlay.trail]`, `[cast.overlay.badge]`, and
`[cast.overlay]` — see [`config.toml`](config.toml) for the
complete annotated list.

`[cast.recognition].max-segment-ms` caps how long any one segment
may take — the clock resets on every turn, so a multi-segment gesture
gets the full budget per leg and only a stalled single direction (an
ordinary deliberate right-drag) runs past it and is abandoned. `0`
(default) = no limit; the trail turns the no-match color once a
segment runs past the budget.

`[cast.recognition].cancel-reversals` is the escape hatch: scribble
the cursor back and forth and the in-progress gesture is abandoned on
the spot — no waiting for a timeout, and releasing fires nothing. It
counts 180° direction reversals; the default `2` catches a deliberate
back-and-forth without tripping on real gestures. `0` = off.
`cancel-window-ms` (default `500`) gates it on *speed* — the reversals
must land within that window, so a fast scribble cancels but a slow
deliberate back-and-forth doesn't; `0` = any speed.

`[cast.overlay.cards]` adds optional exit animations to the
assist cards. Each card normally pops out the moment it's no
longer reachable from the shape you've drawn; with an effect set
it eases out instead. Two hooks:

```toml
[cast.overlay.cards]
cancel = "drop"         # cards that became unreachable mid-gesture
fire   = "fireworks"    # the firing card, on button-up
```

Available kinds: `off` (default), `drop`, `rise`, `slide-left`,
`slide-right`, `explode`, `vibrate`, `fade`, `fireworks`, `confetti`,
and `random` (picks a different one each time a card disappears).
Particle effects (`fireworks` / `confetti`) read most naturally on
`fire`.

Fire-moment effects that work independently of the overlay live in
their own click-through windows:

```toml
[cast.fire.burst]
kind = "burst"          # off | burst

[cast.fire.decal]
kind = "ink-splatter"   # off | ink-splatter | paint-blob | scorch | star
duration-ms = 3000
size = 60
```

Both fire even when `[cast.overlay].enabled = false`.

A single `intensity` knob at the top level of `[cast]` scales
every visual effect produced by a cast firing — overlay card
animations AND the trail-end burst (decal has its own size /
duration knobs and is not affected):

```toml
[cast]
button = "right"
intensity = "wild"      # subtle | normal | bold | wild
```

## CLI

yabai-style `wand <domain> --<verb> [VALUE …]`. Four domains —
**daemon** (lifecycle), **cast** (gesture engine), **tome** (launcher
menu), **config** (settings). Bare `wand` runs the agent.

```sh
wand                    # run as agent (CGEventTap loop)
WAND_DEBUG=1 wand       # verbose log to /tmp/wand.log + stderr

# daemon — lifecycle (need a running daemon; exit 3 if none)
wand daemon --reload    # re-read config.toml (also automatic on save)
wand daemon --show      # rule count, trigger, last gesture, counters
wand daemon --quit      # terminate the running daemon
wand daemon --resign    # re-sign the installed Wand.app + restart
                        #   (run once after `brew install` / upgrade)

# cast — gesture engine
wand cast --test DR [app]   # dry-run: which rule fires for a pattern
wand cast --record          # interactive recorder → paste-ready [[cast.cursor.rule]]

# tome — launcher menu (external trigger)
wand tome --open --items <PATH> --at <X> <Y> [--selection <TEXT>] [--title <TEXT>]
                        #   pop the tome at <X> <Y> (Cocoa coords, Y-up;
                        #   --at accepts negative coords). --selection →
                        #   $WAND_SELECTION for shell items; --title
                        #   overrides $WAND_TARGET_TITLE.
wand tome --validate --items <PATH>   # validate a standalone items file

# config — settings
wand config --validate  # schema-validate config.toml; exit 0 (valid) / 1 (schema violation) / 2 (unparseable)
wand config --doctor    # health check: Accessibility, config, daemon, tap
wand config --emit-schema   # print the config.toml JSON Schema (Draft-07)

wand --help, -h
```

Each domain takes exactly **one** verb. Combining verbs (e.g.
`wand daemon --reload --quit`) or using a flag outside its domain
(e.g. `--items` without `tome`) exits `2` — no silent fallback; an
unknown flag prints a `did you mean …?` hint.

The daemon **auto-reloads `config.toml` on save** — `daemon --reload` is
the manual trigger. `daemon --reload` / `daemon --show` / `daemon --quit`
/ `tome --open` need a running daemon (exit 3 with a helpful message if
none). `cast --record` is the reverse — it refuses if the daemon *is*
running, because both would fight over the same CGEventTap.

### Migration (flat flags → yabai-style domains)

There is **no deprecation shim** — the old flat flags exit 2. Map:

| old | new |
|---|---|
| `wand --reload` / `--status` / `--quit` / `--resign` | `wand daemon --reload` / `--show` / `--quit` / `--resign` |
| `wand --test P [app]` / `--record` | `wand cast --test P [app]` / `--record` |
| `wand --show-menu --items … --at …` | `wand tome --open --items … --at …` |
| `wand --validate --items P` | `wand tome --validate --items P` |
| `wand --validate` / `--doctor` / `--emit-schema` | `wand config --validate` / `--doctor` / `--emit-schema` |

**Two transitions need a daemon restart** — everything else hot-reloads:
- `[cast]` (button / modifiers) — baked into the running tap's
  event mask at `tapCreate` time
- `[cast.overlay].enabled = false → true` — when the daemon started with
  overlay disabled, the window was never created; flipping it on
  later has nothing to attach to

Both surface in `wand daemon --show` as a `pending-restart:` line, and
in `/tmp/wand.log` at reload time.

## Contributing

Commit messages are **gitmoji-driven**; CI lints
each PR against [CONTRIBUTING.md](https://github.com/akira-toriyama/.github/blob/main/CONTRIBUTING.md).
Install the local hook once per clone with `glyph hook install`.

## Build from source

```sh
swift build                       # compile (CommandLineTools is enough)
swift test                        # needs Xcode for XCTest
.build/debug/wand --help        # smoke test
```

For a local `Wand.app` with persistent Accessibility grant:

```sh
./setup-signing-cert.sh           # once — creates stable self-signed cert
./run.sh                          # ./package.sh + open Wand.app
./run.sh --dev                    # → Wand-dev.app (com.wand.wand.dev)
                                  #   for parallel testing alongside a
                                  #   Homebrew install without TCC collision
./stop.sh                         # kill everything wand
```

## Troubleshooting

**`event-tap: tapCreate failed — is Accessibility granted?`** in
`/tmp/wand.log`. macOS dropped (or never had) the Accessibility
grant for this binary. Two ways out:
- **Quick**: re-grant in System Settings → Privacy & Security →
  Accessibility (toggle the `wand` entry off and on, or
  `+` the binary if missing). Re-launch.
- **Sticky**: run `./setup-signing-cert.sh` once. It creates a stable
  self-signed cert in the login keychain; `package.sh` / `run.sh`
  pick it up and sign every rebuild with the same identity, so the
  TCC grant survives. Each subsequent `swift build` would otherwise
  ad-hoc-sign with a new identity and look like a "new app" to TCC.

**`security find-identity -v -p codesigning` returns 0** but
`./run.sh` still signs the bundle. That's expected — `find-identity
-v` filters for codesigning-trusted identities, and a self-signed
cert isn't trusted as a CA. The cert is still in the keychain and
`codesign --sign "<name>"` finds it by Common Name. Confirm with
`security find-certificate -c "wand Local Signing"`.

**Cast doesn't fire on a Chrome page's content area.** The AX
walk-to-window fails through Chrome's renderer process; wand falls
back to `CGWindowListCopyWindowInfo`. The log line reads
`AX: resolved … via cg-window → com.google.Chrome …` — if you see
`via ax-walk` for the same area you're fine. If you see neither,
the cursor was likely on the menu bar / Dock / desktop.

**A rule with `pattern = "DRR"` or similar repeats never fires.** By
design — the recogniser coalesces same-direction motion, so `DRR`
is unreachable. `wand config --validate` drops the rule loudly. Use
distinct directions per segment (`DR` plus a follow-on like `DRU`).

## License

[MIT](LICENSE) © akira-toriyama
