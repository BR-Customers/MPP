# Smoke Test Meeting — Notes

**Date:** 2026-06-29
**Attendees:** Jacques Potgieter, Noah, Hunter

---

## Config App — Eligibility

**Issue:** The eligibility editor's consumption field (when "consumption" = true) exposes Min / Max / Default inputs, but the UI never labels *what* these are the min/max/default **of** — consumption quantity? inventory? It's ambiguous to the user.

**Context (from data model + SQL):**
- The columns are `MinQuantity` / `MaxQuantity` / `DefaultQuantity` / `IsConsumptionPoint` on `Parts.ItemLocation` (added migration `0010`, v1.8, **OI-18** — mirrors the legacy Flexware "Compatible work cells" consumption fields).
- Per `MPP_MES_DATA_MODEL.md` (ItemLocation), they are all **pieces per scan-in at this Cell for this Item** — i.e. consumption quantity per scan event, **not** inventory:
  - `MinQuantity` — minimum pieces per scan-in.
  - `MaxQuantity` — maximum pieces per scan-in (rejects over-scan).
  - `DefaultQuantity` — value pre-populated on the Allocations scan form.
  - `IsConsumptionPoint` — `1` = Cell consumes this Item (input); `0` = produces it (output) / merely eligible.
- Backed by proc `Parts.ItemLocation_SetConsumptionMetadata`; enforced non-negative + `Min ≤ Max`.
- **Fix candidate:** relabel the three inputs in the eligibility editor to "Min / Max / Default **pieces per scan-in**" (or a section header "Consumption quantity (pieces per scan-in)"). UI-only change.

---

## Config App — Routes Configuration

View: `BlueRidge/Components/Parts/ItemMaster/Routes` (in `MPP_Config`). Multiple issues observed when adding/editing route steps:

1. **Operation Template dropdown contains characters Ignition can't parse.** Likely the dropdown `options` carry extra/un-stripped keys or the label has problem characters. Project convention (`feedback_ignition_dropdown_conventions`): `ia.input.dropdown` options must be `{label, value}` **only** — extra keys (code/name) break the control; strip via a transform and keep full data in a separate custom prop for lookups. **Check the OperationTemplate options source for unstripped keys / non-ASCII chars.**
2. **Operation Template field too short / unclear** — column/input width too narrow to read the template name; not obvious what it is.
3. **All dropdowns on the form are too narrow** — general width pass needed on the route-step row dropdowns.
4. **Move route step up/down does nothing.**
5. **All route-step saves fail: "Step at row 1 is missing OperationTemplateID."**

**Likely ROOT CAUSE for #4 and #5 (and possibly the dropdown not committing):**
In `Routes/view.json`, the root component's page-scoped message handlers are **declared but have empty bodies** — `"script": null` on:
- `routeStepMoveUp`
- `routeStepMoveDown`
- `routeStepChanged`
- `routeStepRemove`
- `sectionSaveRequested`
- `sectionDiscardRequested`

So:
- **#4** — Move Up/Down send `routeStepMoveUp`/`routeStepMoveDown` from the row, but the handlers do nothing → no reorder.
- **#5** — when a row's OperationTemplate dropdown changes, the row broadcasts `routeStepChanged`, but the null handler never writes the selected `OperationTemplateId` back into `view.custom.state.editDraft.steps[]`. Save then serializes steps with `OperationTemplateId: None` → proc rejects "missing OperationTemplateID." (`+ Add Step` correctly seeds a step with `OperationTemplateId: None` at `BtnAddStep`, confirming the per-row selection is what's supposed to populate it.)

This matches the established project gotcha: an embed/row → parent change must be handled by a real handler that mutates `state.editDraft` and writes the whole state back atomically (`feedback_ignition_embed_params_input_only`, item-master per-section pattern). The handlers look stubbed-out (declared, never implemented).

**Fix candidates:**
- Implement the 6 stubbed message handlers (esp. `routeStepChanged`, `routeStepMoveUp`, `routeStepMoveDown`) to mutate `editDraft.steps` and re-broadcast dirty / write state atomically.
- Strip OperationTemplate dropdown options to `{label, value}` only; verify label chars are ASCII / Designer-safe.
- Widen the route-step row dropdowns (OperationTemplate especially).

**Confirmed (added in meeting):** Discard does not work, Save does not work, Move up/down does not work, Delete route step does not work — i.e. **none** of the route-step actions function.

This is consistent with the root cause above — **every** action maps to one of the empty (`script: null`) handlers:

| Action | Handler | Status |
|---|---|---|
| Save | `sectionSaveRequested` | empty |
| Discard | `sectionDiscardRequested` | empty |
| Move up | `routeStepMoveUp` | empty |
| Move down | `routeStepMoveDown` | empty |
| Delete step | `routeStepRemove` | empty |
| Edit step (pick template, etc.) | `routeStepChanged` | empty |

So the Routes tab is **non-functional end-to-end**, not a set of separate bugs — the handler bodies were never implemented (or were wiped). All six need to be written. (Only `+ Add Step` / `BtnAddStep` works, because it has an inline `onActionPerformed` script rather than relying on a message handler.)

**Severity (added in meeting): cannot leave Routes in current state** — must be fixed before this ships / before merge.

### Git history check — root cause confirmed: handlers were wiped by the last commit

The handlers **used to work** and were stripped by the most recent change to the view:

- `"script": null` count on `Routes/view.json` by commit:
  - `0151dbc`, `c27c36d`, `bd00c5e`, `7e79563` → **0 null** (handlers intact + working)
  - `0dbaa9d` *"fix(ignition): land intern's non-colliding Config Tool UI fixes (cleaned)"* (HEAD) → **7 null** ← the wipe happened here.
- This is a repeat of a known failure mode — there is literally a prior commit `c10a13a "fix(routes): restore page-scoped message handlers stripped by Designer save"`. Designer's save round-trip drops page-scoped message-handler bodies.

**Good news for the fix:** the last-good version (`7e79563`) already uses the **current** `view.custom.state.editDraft` model (16 references, same as HEAD's working `BtnAddStep`) — so the handler bodies are **directly restorable** from `7e79563`, no state-model translation needed. The earlier `draftEditDraft` model was already migrated before the wipe.

**Recommended fix:** restore the 6 message-handler `script` bodies from commit `7e79563` (`routeStepChanged`, `routeStepMoveUp`, `routeStepMoveDown`, `routeStepRemove`, `sectionSaveRequested`, `sectionDiscardRequested`). Then re-test all step actions. The dropdown `{label,value}`-strip + width fixes are still separate follow-ups on top.

> ⚠️ These are edits to an **existing** view → do in Designer per the file-edit boundary. Restoring stripped handler bodies is one of the cases where a careful file-level splice + `scan.ps1` may actually be safer than re-typing in Designer (and avoids re-triggering the same strip) — decide at fix time.
