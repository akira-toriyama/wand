# Security policy

`wand` runs as a global keyboard / window-action daemon with
**Accessibility** privileges, so a vulnerability could let an attacker
synthesize keystrokes, close arbitrary windows, or exfiltrate window
titles via `.shell` actions.

## Reporting

**Please do not open public GitHub issues for security bugs.**

- **Private report (preferred):** open a draft advisory via GitHub's
  [security advisories](https://github.com/akira-toriyama/wand/security/advisories/new).
- **Email:** akira.toriyama.dev@gmail.com — please include "wand"
  in the subject so it's easy to triage.

Include:

- the version you're running (`wand --doctor` prints it)
- a minimal reproduction (config snippet + gesture sequence, or a
  step-by-step description)
- the impact you observed and any mitigations you've considered

I aim to acknowledge within 7 days and to coordinate disclosure on a
timeline that matches the severity. There is no bug bounty.

## Supported versions

The latest release on `main` is supported. Older releases get fixes only by
upgrading.

## Trust boundary in `.shell` actions

The `.shell` action runs a `/bin/sh -c "$cmd"` with the user's
`config.toml` command. The command text itself is trusted (the user
wrote it). The four `WAND_TARGET_*` environment variables, however,
carry **untrusted** data — `WAND_TARGET_TITLE` is a window title,
which can be a web page title containing `$( … )` or backticks.

If you write a `.shell` action that expands these, **quote the
expansions**: `echo "$WAND_TARGET_TITLE"` (safe) rather than
`echo $WAND_TARGET_TITLE` (a malicious page title would be evaluated
as a sub-shell).
