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

As you draw, a translucent trail follows the cursor so you can see
the shape forming; it clears the moment you release. The trail is
**colored by whether the shape so far matches a rule** — one color
while it's a valid gesture for the window under the cursor, another
once it forms a shape no rule wants. Next to the cursor it shows the
shape so far as **arrows** (`↓→`) and a live **gesture-assist** list
— every rule still reachable from here, showing only what's *left* to
draw, with the one that fires right now tinted in the match color:

```
↓
  ←   close tab
  →↑  close window
```

So after a `↓` you can see you're on the way to either, and what to
add. The trail is the match color while the current shape fires a
rule, the no-match color otherwise. Colors, width, and on/off live in
the `[overlay]` section of `config.toml`.

Actions target the window **under the cursor**, not whichever window
holds keyboard focus: `ax` actions operate on it directly, `key`
actions raise it first and send the keystroke, and `shell` actions
receive its identity (bundle id, pid, title, frame) as environment
variables.

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

Pattern alphabet is `L U R D` (left / up / right / down). Scroll-
axis directions are not recognised yet. App filters support
`*` / `?` globs and `!` exclusions. Action types are `key` (a
keystroke), `ax` (`close` / `minimize` / `zoom` / `raise`), and
`shell` (any command).

`[recognition] max-stroke-ms` caps how long any one segment may take
— the clock resets on every turn, so a multi-segment gesture gets the
full budget per leg and only a stalled single direction (an ordinary
deliberate right-drag) runs past it and is abandoned. `0` (default) =
no limit; the trail turns the no-match color once a segment runs past
the budget.

`[recognition] cancel-reversals` is the escape hatch: scribble the
cursor back and forth and the in-progress gesture is abandoned on the
spot — no waiting for a timeout, and releasing fires nothing. It
counts 180° direction reversals; the default `2` catches a deliberate
back-and-forth without tripping on real gestures. `0` = off.
`cancel-window-ms` (default `500`) gates it on *speed* — the reversals
must land within that window, so a fast scribble cancels but a slow
deliberate back-and-forth doesn't; `0` = any speed.

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

## Architecture

Hexagonal (Ports & Adapters), three layers:

```
StrokeApp           @main / CLI / Controller (wires the pipeline)
    │
StrokeCore          pure logic: recognition, matching, config.
    │               No AppKit, no AX, no CGEvent. Fully testable.
    │
    ├── StrokeAdapterMacOS    CGEventTap + AX + dispatch
    └── StrokeAdapterTest     synthetic source for tests
```

Full write-up: [docs/architecture.md](docs/architecture.md).

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

## License

[MIT](LICENSE) © akira-toriyama
