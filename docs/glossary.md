# Glossary — wand's ubiquitous language

A short, normative list of names for the moving parts of wand. **Code,
docs, commit messages, PR titles, and Claude Code prompts all use these
names** — and only these names. Synonyms drift; pick one and stick.

If a term is missing, add it here in the same PR that introduces it. If
a term changes name, rename it across code + docs + this file in one PR.

> Format per entry: **canonical name**, one-line definition, where it
> lives in the config or code, and a `Don't call it:` line listing the
> wrong names this entry replaces.

---

## Gesture surface

### assist card
The small card laid out around the cursor showing **what's reachable
from here** — one per direction the in-progress shape could still
extend into. The card whose rule fires right now is tinted in the match
color.
- Config: `[gesture.overlay]`
- Code: `WandAdapterMacOS` overlay
- **Don't call it:** tooltip, popup, hint, chip, balloon, label.

### badge
The small marker pinned at the gesture's **start point** that shows the
target app's icon, so the user can see which window wand will act on
even when keyboard focus sits elsewhere.
- Config: `[gesture.overlay]` (`badge` toggle)
- **Don't call it:** icon, indicator, marker, anchor.

### trail
The translucent line that follows the cursor while a gesture is being
drawn. Match color while the shape so far fires a rule, no-match color
once it doesn't.
- Config: `[gesture.overlay]`
- **Don't call it:** path, stroke, line, ink.

### gesture rule
One `[[gesture.rule]]` entry: a `pattern` (e.g. `DR`) plus an action,
optionally narrowed by `apps` / `filter-title` / `filter-shell`.
- Config: `[[gesture.rule]]`
- **Don't call it:** gesture, binding, mapping, shortcut.

### wand pattern
The cardinal-direction string a `gesture rule` matches against —
alphabet `L U R D`, no consecutive duplicates (the recogniser coalesces
same-direction motion).
- Examples: `DR`, `URD`, `L`
- **Don't call it:** shape, sequence, path, motion.

---

## Launcher surface

### non-activating panel
The launcher's main menu — a floating panel that appears at button-down
**without stealing keyboard focus** (PopClip parity). Anchored to the
window under the cursor at the moment the trigger fires.
- Config: `[launcher]`
- Code: `PanelController`
- **Don't call it:** modal, popup, window, menu, dialog.

### child panel
A submenu that opens **adjacent** to the non-activating panel on hover
over a row with `group = [...]`. Same non-activating semantics as its
parent.
- Code: `PanelController.openChild`
- **Don't call it:** submenu, dropdown, flyout, nested menu.

### launcher item
One `[[launcher.item]]` entry — a row in the non-activating panel or a
child panel. May be static, or expand into a child panel via `group`,
or generate its rows at open-time via `dynamic`.
- Config: `[[launcher.item]]`
- **Don't call it:** entry, row, button, command, action.

### dynamic submenu
A `launcher item` whose child rows are produced at menu-open time by
running its `dynamic = "<shell>"` command and applying its
`template-*` fields to each stdout line. 500 ms hard timeout.
- Config: `[[launcher.item]]` with `dynamic` set
- **Don't call it:** generated submenu, shell submenu, computed menu.

---

## Targeting

### AX target
The window the cursor was over at button-down — the window every action
runs against, regardless of keyboard focus. Resolved by AX walk first,
with a `CGWindowListCopyWindowInfo` fallback for renderer processes
(Chrome content area, etc.).
- Log line: `AX: resolved … via ax-walk` / `via cg-window`
- Env vars exposed to shell actions: `WAND_TARGET_BUNDLE_ID`,
  `WAND_TARGET_PID`, `WAND_TARGET_TITLE`, `WAND_TARGET_FRAME`
- **Don't call it:** focused window, active window, frontmost window,
  target app. (The frontmost / focused window may be different.)

### `$SELECTION`
The text selected in the focused element at the moment the launcher
trigger fired, exposed to `shell` launcher items as an env var. Empty
if nothing is selected or the focused app doesn't expose AX selection.
**Untrusted** — quote it in shell commands.
- **Don't call it:** clipboard, highlighted text, current selection
  (which collides with code-side AX terminology).

---

## Conventions for adding entries

- One canonical name per concept. If two names are circulating, this
  file picks the winner and the loser goes in `Don't call it:`.
- Lowercase the name unless it's a literal config key or type
  (`[[gesture.rule]]`, `PanelController`).
- Keep definitions to **one or two sentences**. Link to the config
  section or source file rather than re-explaining behavior.
- When a term gets a screenshot, drop it in `docs/images/` and embed
  with `![](images/<name>.png)`.
