# QWERTY Keyboard Refactor — Design

**Date:** 2026-06-11
**Status:** Approved by Jacques (2026-06-11)
**Scope:** `BlueRidge/Views/ShopFloor/InitialsEntry` keyboard refactor + new reusable Keyboard component (MPP project)

## Problem

`InitialsEntry/view.json` hand-places 28 `ia.input.button` components (A-Z + Clear + Enter) in a single wrap container — ~870 lines of duplicated JSON, alphabetical layout instead of QWERTY, no reuse path for other plant-floor text-entry surfaces.

## Decisions (with Jacques, 2026-06-11)

1. **Reusable component** — new `BlueRidge/Components/PlantFloor/Keyboard` view, embedded by InitialsEntry. Future consumers: defect notes, hold reasons, any operator text entry.
2. **Clear/Enter flank the bottom row** — Row 3 = `Clear | Z X C V B N M | Enter`, like Shift/Backspace on a physical keyboard.
3. **Approach A** — three flex-repeaters (one per QWERTY row) sharing one `Key` sub-view. Rejected: nested repeater-of-rows (param-threading complexity for zero benefit on a static layout).

## Architecture

### New: `BlueRidge/Components/PlantFloor/Keyboard`

- **Param:** `messageName` (input, default `"keyboardKeyPressed"`) — page-scoped message type fired on every key press. Lets hosts scope their handlers and allows two keyboards to coexist.
- **Root:** flex column, `alignItems: center`, 8px gap. Three named `ia.display.flex-repeater` children (`Row1`/`Row2`/`Row3`), each `direction: row`, `position.basis: auto` (content-sized; the column's `alignItems: center` produces the QWERTY stagger), `elementPosition: {basis: "62px", grow: 0, shrink: 0}`, `useDefaultViewWidth/Height: false`, `props.style.gap: "8px"`.
- **Instances** built by a property binding on `view.params.messageName` + script transform per repeater (established Eligibility pattern). The transform is the only channel that can inject `messageName` into instance params. Rows:
  - Row1: `Q W E R T Y U I O P` (10 keys, ~692px)
  - Row2: `A S D F G H J K L` (9 keys)
  - Row3: `Clear` (`variant: secondary`, `instancePosition.basis: 130px`) + `Z X C V B N M` + `Enter` (`variant: primary`, `instancePosition.basis: 130px`) (~698px)
- `props.defaultSize`: 700 × 210.

### New: `BlueRidge/Components/PlantFloor/_Keyboard/Key`

Underscore folder per component-internals convention. Params (all input, persistent, shaped defaults): `label`, `key`, `action` (`"key"|"clear"|"enter"`), `variant` (`"default"|"secondary"|"primary"`), `messageName`.

- One button filling the instance box (height 62px). `props.text` ← `label`.
- `props.style.classes` ← expression: base `pf-btn pf-btn-large` + ` pf-btn-primary` / ` pf-btn-secondary` by variant.
- `props.style.fontSize` ← expression: `22px` for letters, `18px` for action keys.
- `onActionPerformed` (scope `G`, tab-indented body):
  `system.perspective.sendMessage(self.view.params.messageName, {"action": self.view.params.action, "key": self.view.params.key}, scope="page")`
  Page scope because view scope does not cross the embed boundary.

### Changed: `BlueRidge/Views/ShopFloor/InitialsEntry`

- Keypad container (28 buttons) → one `ia.display.view` embed of Keyboard with `params: {messageName: "initialsKeyPressed"}`, explicit size (basis 210px, width 700px, `useDefaultViewWidth/Height: false` — embedded-view flex sizing is finicky per pack §06).
- Root gains one message handler (`messageType: "initialsKeyPressed"`, `pageScope: true`) routing `payload.action` → existing `appendKey` / `clearKeys` / `submitInitials` customMethods (handler lives on root, same component as the methods, so `self.appendKey(...)` addressing works).
- Heading, TerminalName, InitialsEcho, ScannerInput (onBlur submit), ErrorLabel, customMethods: unchanged.

## Conventions honored

- New views file-authored + `scan.ps1`; InitialsEntry is existing but file-authored (no Designer unicode escapes) and replaced via full-file Write — view must be closed in Designer during scan.
- Literal `=` in script strings, matching the repo's file-authored style.
- Event/handler/transform script bodies start with `\t`.
- `scope: "G"` on any event script calling `system.perspective.*`.
- All binding-read `view.params.*` declared with shaped defaults.
- resource.json per new view (scope G, actor claude).

## Error handling

None new — key presses are pure UI events; submit/validation paths untouched.

## Testing

Manual: scan → terminal session → verify QWERTY layout, letter append, Clear, Enter (valid + unrecognised initials), scanner-input blur path still works.
