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

## CLI

```sh
stroke                    # run as agent (CGEventTap loop)
stroke --debug            # verbose log to /tmp/stroke.log + stderr

stroke --validate         # parse config.toml, exit 0/2
stroke --record           # interactive recorder — draw, see the
                          # pattern + sample count + span on stdout

stroke --reload           # tell the running daemon to re-read config.toml
stroke --quit             # terminate the running daemon
stroke --help
```

`--reload` and `--quit` are client commands — they exit 3 with a
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
