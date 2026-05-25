# stroke

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)
![swift](https://img.shields.io/badge/Swift-6.0-orange)
![license](https://img.shields.io/badge/license-MIT-blue)

**English** · [日本語](README.ja.md)

A global mouse-gesture daemon for macOS. Hold a mouse button, draw a
short shape with the cursor — down, then right — and stroke fires an
action: close a tab, reopen one, minimize a window, run a shell
command. The action runs against the window the cursor was over when
you started drawing.

## Gestures

Draw with the trigger button held down (right mouse by default). A
stroke is a sequence of cardinal directions:

```
L = left    U = up    R = right    D = down
```

So `DR` is down-then-right, `URD` is up → right → down. When you
release the button, stroke matches the shape against your rules and
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
a small badge shows the **target app's icon** so the window stroke
will act on is unambiguous even when keyboard focus sits elsewhere.

Colors, width, on/off, and per-piece toggles (badge / blur / size /
animation) live in the `[overlay]` section of `config.toml`.

The assist cards can also animate out — drop, slide, explode, vibrate,
or burst with fireworks / confetti particles. Pick one effect for the
moment a card becomes unreachable mid-gesture (`unmatch`) and another
for the moment a rule actually fires (`match`), in `[effect]`. Default
is silent.

Actions target the window **under the cursor**, not whichever window
holds keyboard focus: `ax` actions operate on it directly, `key`
actions raise it first and send the keystroke, and `shell` actions
receive its identity (bundle id, pid, title, frame) as environment
variables.

## Launcher (opt-in)

stroke also ships a **middle-click contextual menu** as a second
trigger. Off by default — set `[launcher].enabled = true` in your
config and the daemon installs a second event tap alongside the
gesture one. The menu is a native macOS `NSMenu` (submenus,
keyboard navigation, click-outside dismiss all for free), anchored
to the **window under the cursor at button-down** — same invariant
as the gesture path. Each `[[item]]` is one row:

```toml
[launcher]
enabled = true
button = "middle"                 # or "side1" / "side2" / "right"

[[item]]
name = "新規タブ"
apps = ["*chrome*", "*safari*"]
action-type = "key"
action-keys = "cmd+t"

[[item]]
name = "並び替え > 名前順"
group = ["並び替え"]               # nests this row inside a "並び替え" submenu
separator-before = true            # divider line above the row
action-type = "shell"
action-cmd = "echo name"
```

## Install

```sh
brew install akira-toriyama/tap/stroke
curl --create-dirs -o ~/.config/stroke/config.toml \
  https://raw.githubusercontent.com/akira-toriyama/stroke/main/config.toml
open "$(brew --prefix)/opt/stroke/Stroke.app"   # triggers AX prompt
```

Then grant **Accessibility** to *stroke* (System Settings → Privacy
& Security → Accessibility) and launch the daemon with `stroke`.

To start it automatically at login:

```sh
brew services start stroke
```

The formula bundles a `Stroke.app` (LSUIElement — no Dock icon) plus
a stable self-signed code-signing identity created in your login
keychain on first install, so the Accessibility grant persists across
`brew upgrade stroke`. If the keychain isn't reachable during install,
the formula falls back to ad-hoc signing and prints a loud warning
with a one-line recovery path. Details:
[packaging/homebrew/](packaging/homebrew/).

## Configuration

stroke is **config.toml-driven** — there is no settings GUI by
design. The `curl` line above drops the template at
`~/.config/stroke/config.toml`. Out-of-range / unknown values clamp
silently to defaults — a typo can never break the daemon. Validate
explicitly with `stroke --validate`.

A rule looks like this:

```toml
[[rules]]
name = "close tab"
pattern = "DR"                        # down → right
apps = ["*chrome*", "*safari*"]       # matches the window under the cursor
action-type = "key"
action-keys = "cmd+w"
```

Pattern alphabet is `L U R D` (left / up / right / down) —
**no consecutive duplicates**, because the recogniser coalesces
same-direction motion into one segment (`LLLL…` is `L`, not `LL`).
A rule whose pattern repeats a direction (`DRR`, `LL`, …) is
unreachable; `stroke --validate` drops it loudly. Scroll-axis
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

`[recognition] max-segment-ms` caps how long any one segment may
take — the clock resets on every turn, so a multi-segment gesture
gets the full budget per leg and only a stalled single direction (an
ordinary deliberate right-drag) runs past it and is abandoned. `0`
(default) = no limit; the trail turns the no-match color once a
segment runs past the budget.

`[recognition] cancel-reversals` is the escape hatch: scribble the
cursor back and forth and the in-progress gesture is abandoned on the
spot — no waiting for a timeout, and releasing fires nothing. It
counts 180° direction reversals; the default `2` catches a deliberate
back-and-forth without tripping on real gestures. `0` = off.
`cancel-window-ms` (default `500`) gates it on *speed* — the reversals
must land within that window, so a fast scribble cancels but a slow
deliberate back-and-forth doesn't; `0` = any speed.

`[effect]` adds optional exit animations to the assist cards. Each
card normally pops out the moment it's no longer reachable from the
shape you've drawn; with an effect set it eases out instead. Two
hooks:

```toml
[effect]
unmatch = "drop"        # cards that became unreachable mid-gesture
match   = "fireworks"   # the firing card, on button-up
```

Available kinds: `none` (default), `drop`, `rise`, `slide-left`,
`slide-right`, `explode`, `vibrate`, `fade`, `fireworks`, `confetti`,
and `random` (picks a different one each time a card disappears).
Particle effects (`fireworks` / `confetti`) read most naturally on
`match`.

Set `intensity = "subtle" | "normal" | "bold" | "wild"` in the same
block to dial the overall size — bigger throws, denser particles. The
default is `normal`.

## CLI

```sh
stroke                    # run as agent (CGEventTap loop)
stroke --debug            # verbose log to /tmp/stroke.log + stderr

stroke --validate         # parse config.toml, exit 0/2
stroke --doctor           # health check: Accessibility, config, daemon, tap
stroke --test DR [app]    # dry-run: which rule fires for a pattern
stroke --record           # interactive recorder — draw a gesture, get a
                          # paste-ready [[rules]] snippet on stdout

stroke --status           # rule count, trigger, last gesture
stroke --reload           # re-read config.toml (also automatic on save)
stroke --quit             # terminate the running daemon
stroke --help
```

The daemon **auto-reloads `config.toml` on save** — `--reload` is the
manual trigger if you need it. `--reload` / `--status` / `--quit` are
client commands — they exit 3 with a
helpful message if the daemon isn't running. `--record` is the
reverse — it refuses if the daemon *is* running, because both
would fight over the same CGEventTap.

**Two transitions need a daemon restart** — everything else hot-reloads:
- `[trigger]` (button / modifiers) — baked into the running tap's
  event mask at `tapCreate` time
- `[overlay].enabled = false → true` — when the daemon started with
  overlay disabled, the window was never created; flipping it on
  later has nothing to attach to

Both surface in `stroke --status` as a `pending-restart:` line, and
in `/tmp/stroke.log` at reload time.

## Contributing

Commit messages use **gitmoji + Conventional Commits**; CI lints
each PR against [docs/commit-convention.md](docs/commit-convention.md).
Enable the local hook with `git config core.hooksPath scripts/hooks`.

## Build from source

```sh
swift build                       # compile (CommandLineTools is enough)
swift test                        # needs Xcode for XCTest
.build/debug/stroke --help        # smoke test
```

For a local `Stroke.app` with persistent Accessibility grant:

```sh
./setup-signing-cert.sh           # once — creates stable self-signed cert
./run.sh                          # ./package.sh + open Stroke.app
./run.sh --dev                    # → Stroke-dev.app (com.stroke.stroke.dev)
                                  #   for parallel testing alongside a
                                  #   Homebrew install without TCC collision
./stop.sh                         # kill everything stroke
```

## Troubleshooting

**`event-tap: tapCreate failed — is Accessibility granted?`** in
`/tmp/stroke.log`. macOS dropped (or never had) the Accessibility
grant for this binary. Two ways out:
- **Quick**: re-grant in System Settings → Privacy & Security →
  Accessibility (toggle the `stroke` / `Stroke` entry off and on, or
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
`security find-certificate -c "stroke Local Signing"`.

**Gesture doesn't fire on a Chrome page's content area.** The AX
walk-to-window fails through Chrome's renderer process; stroke falls
back to `CGWindowListCopyWindowInfo`. The log line reads
`AX: resolved … via cg-window → com.google.Chrome …` — if you see
`via ax-walk` for the same area you're fine. If you see neither,
the cursor was likely on the menu bar / Dock / desktop.

**A rule with `pattern = "DRR"` or similar repeats never fires.** By
design — the recogniser coalesces same-direction motion, so `DRR`
is unreachable. `stroke --validate` drops the rule loudly. Use
distinct directions per segment (`DR` plus a follow-on like `DRU`).

## License

[MIT](LICENSE) © akira-toriyama
