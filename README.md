# stroke

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)
![swift](https://img.shields.io/badge/Swift-6.0-orange)
![license](https://img.shields.io/badge/license-MIT-blue)
![status](https://img.shields.io/badge/status-M5%20packaged-brightgreen)

**English** · [日本語](README.ja.md)

A global mouse-gesture daemon for macOS. Draw a shape with the
mouse, run an action against **the window you were pointing at** —
not whatever app happens to have focus.

The one design principle: **the cursor is ground truth.** See
[Why cursor-anchored](#why-cursor-anchored) below.

## Status

**M5 — packaged.** `Stroke.app` bundle, persistent self-signed cert
for stable Accessibility grants across rebuilds / `brew upgrade`,
Homebrew formula at `akira-toriyama/homebrew-tap`, release pipeline
that builds + zips on every push to main and attaches the artifact
to a rolling DRAFT release.

| Milestone | Status |
|---|---|
| M1 — repo scaffolded, `swift build` green, config parses, recognition algorithm | ✅ |
| M2 — CGEventTap captures real strokes; `key` / `shell` actions fire | ✅ |
| M3 — AX cursor-anchored target resolution + `ax` actions | ✅ |
| M4 — `--reload`, `--record`, `--quit` | ✅ |
| M5 — Homebrew tap, `.app` bundle, persistent codesign | ✅ |

## Why cursor-anchored

On a multi-display Mac the focused window is often on a different
display from where you're pointing. A gesture drawn over a Chrome
tab on display 2 should close *that* tab — not whatever happened to
have focus on display 1.

stroke does this by **resolving the target window at button-down
time** via `AXUIElementCopyElementAtPosition`, then dispatching every
action to that exact window — `ax` actions hit it directly without
focus churn, `key` actions raise it first, `shell` actions get the
target identity passed through as environment variables. The cursor
is ground truth.

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
apps = ["*chrome*", "*safari*"]       # cursor-anchored — see above
action-type = "key"
action-keys = "cmd+w"
```

Pattern alphabet is `L U R D` (left / up / right / down). Scroll-
axis directions are not recognised yet. App filters support
`*` / `?` globs and `!` exclusions.

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

Hexagonal (Ports & Adapters), three layers — mirrors
[facet](https://github.com/akira-toriyama/facet):

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
