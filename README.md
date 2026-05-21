# stroke

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)
![swift](https://img.shields.io/badge/Swift-6.0-orange)
![license](https://img.shields.io/badge/license-MIT-blue)
![status](https://img.shields.io/badge/status-M4%20ipc%20%2B%20recorder-orange)

**English** · [日本語](README.ja.md)

A global mouse-gesture daemon for macOS. Draw a shape with the
mouse, run an action against **the window you were pointing at** —
not whatever app happens to have focus.

stroke is the spiritual successor to
[MacGesture](https://github.com/MacGesture/MacGesture) and
[xGestures](https://www.briankendall.net/xGestures/), built around
the one thing they don't do: **cursor-anchored target resolution**.
See [Why stroke exists](#why-stroke-exists) below.

## Status

**M4 — live reload, interactive recorder, IPC.** Edit
`~/.config/stroke/config.toml`, run `stroke --reload`, and the
running daemon swaps in the new rules without losing its event tap
or AX grant. `stroke --record` opens an interactive recorder
(`pattern=DR  samples=421  max|dx|=180 max|dy|=92  target=...`) so
you can dial in a new gesture before committing it to the file.
`stroke --quit` shuts the daemon down cleanly. Client commands
refuse with exit 3 if no daemon is running; `--record` refuses
with exit 3 if one is.

| Milestone | Status |
|---|---|
| M1 — repo scaffolded, `swift build` green, config parses, recognition algorithm | ✅ |
| M2 — CGEventTap captures real strokes; `key` / `shell` actions fire | ✅ |
| M3 — AX cursor-anchored target resolution (the issue #115 fix); `ax` actions | ✅ |
| M4 — `--reload`, `--record`, `--quit` | ✅ |
| M5 — Homebrew tap, signed bundle | ⏳ |

## Why stroke exists

[MacGesture issue #115](https://github.com/MacGesture/MacGesture/issues/115)
captures the gap. Multi-display setups break MacGesture: you draw a
gesture while pointing at Chrome on display 2, but the keystroke
fires into whatever app happens to be focused on display 1. The same
problem haunts the older xGestures.

stroke's fix is to **resolve the target window at button-down time**
via `AXUIElementCopyElementAtPosition`, then dispatch every action
to that exact window — `ax` actions hit it directly without focus
churn, `key` actions raise it first, `shell` actions get the target
identity passed through as environment variables. The cursor is
ground truth.

## Configuration

stroke is **config.toml-driven** — there is no settings GUI by
design. Drop a copy of [`config.toml`](config.toml) at
`~/.config/stroke/config.toml`:

```sh
curl --create-dirs -o ~/.config/stroke/config.toml \
  https://raw.githubusercontent.com/akira-toriyama/stroke/main/config.toml
```

Out-of-range / unknown values clamp silently to defaults — a typo
can never break the daemon. Validate explicitly with
`stroke --validate`.

A rule looks like this:

```toml
[[rules]]
name = "close tab"
pattern = "DR"                        # down → right
apps = ["*chrome*", "*safari*"]       # cursor-anchored — see above
action-type = "key"
action-keys = "cmd+w"
```

Pattern alphabet is MacGesture-compatible: `L U R D`
(left / up / right / down). Scroll-axis directions are deferred to
post-M2. App filters support `*` / `?` globs and `!` exclusions.

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

## License

[MIT](LICENSE) © akira-toriyama
