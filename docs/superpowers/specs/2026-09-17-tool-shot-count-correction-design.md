# Tool shot-count correction + comma-friendly shot inputs -- design

**Date:** 2026-09-17
**Status:** Approved (design), not yet built
**Screen:** Config Tool -> Tools (`MPP_Config` view `BlueRidge/Views/Parts/Tools`), die header

## 1. Problem

Doug, who manages the dies, needs to enter each die's actual lifetime shot count at
cutover and to fix a wrong count afterwards. Today:

- **Total Shots is read-only.** `Tools.Tool.ShotCount` has no setter proc -- the Data
  Model says so deliberately. The only writer is `Workorder.DieCastShiftOutput_Record`,
  which adds `ShotDelta = counterReading - dieWatermark` when positive.
- **Shot Limit silently clears on a comma.** It is a text field, but `Tool.update()`
  parses it with `Common.Util.toIntOrNone`, which does `int(float(v))`. `"1,000,000"`
  fails, returns `None`, and the save writes `ShotLimit = NULL`.

## 2. Decisions

| # | Decision |
|---|---|
| D1 | A note is required **only when the shot count changes**. Other header edits (name, description, shot limit, status) are unchanged. |
| D2 | The correction mimics the shift-reconcile increment: `ShotCount = ShotCount + (typed - current)` under `UPDLOCK, HOLDLOCK`. Unlike the shift path the delta may be negative. |
| D3 | The correction touches **only** `Tools.Tool.ShotCount`. It writes no `Workorder.DieCastContribution` row and moves no watermark: those rows are the per-shift press-counter chain, need a LOT, and drive basket crediting. A lifetime die count is not a press reading. |
| D4 | **Stale guard.** The screen passes the count it loaded (`@ExpectedShotCount`). If a shift output landed since, the proc refuses rather than overwriting shots recorded while Doug was typing. |
| D5 | The record of the correction lives in **`Audit.ConfigLog` only** -- no ledger table. |
| D6 | Shot inputs accept thousands separators; values are still stored as `INT`. Non-numeric input is **rejected with a message**, never coerced to NULL. |

## 3. SQL -- `Tools.Tool_CorrectShotCount` (new repeatable)

File: `sql/migrations/repeatable/R__Tools_Tool_CorrectShotCount.sql`, built from
`sql/scripts/_TEMPLATE_stored_procedure.sql`.

```
@Id                BIGINT
@ShotCount         INT            -- the actual count typed
@ExpectedShotCount INT            -- the count the screen loaded
@Note              NVARCHAR(500)
@AppUserId         BIGINT
```

Result: one row `Status, Message` (no `NewId`, no OUTPUT params -- FDS-11-011).

**Pre-transaction rejections** (each logs `Audit.Audit_LogFailure`, entity `Tool`,
event `Updated`, then SELECTs the status row and RETURNs):

1. `@Id`, `@ShotCount`, `@ExpectedShotCount`, `@AppUserId` required.
2. `LTRIM(RTRIM(@Note))` non-blank -- "A note is required when changing the shot count."
3. `@ShotCount >= 0`.
4. Tool exists, `DeprecatedAt IS NULL`, ToolType `Die`.
5. `@ShotCount <> @ExpectedShotCount` -- "Shot count is unchanged."
6. **Stale check (plain read):** current `ShotCount <> @ExpectedShotCount` -> stale
   message.

**Transaction** (no ROLLBACK outside CATCH -- Msg-3915 rule):

1. `@Delta = @ShotCount - @ExpectedShotCount`.
2. `UPDATE Tools.Tool WITH (UPDLOCK, HOLDLOCK) SET ShotCount = ShotCount + @Delta,
   UpdatedAt, UpdatedByUserId WHERE Id = @Id AND ShotCount = @ExpectedShotCount`.
3. `@@ROWCOUNT = 0` -> a shift output landed between step 6 and the UPDATE: `COMMIT`
   (nothing written), return the stale message.
4. `Audit.Audit_LogConfigChange`, entity `Tool`, event `Updated`, severity `Info`:
   - Description: `Audit.ufn_TruncateActivity(<Code> · Shot Count · <old> -> <new> · <note>)`
     using `Audit.ufn_MidDot()`.
   - OldValue: `{"ShotCount": <old>}`
   - NewValue: `{"ShotCount": <new>, "Delta": <delta>, "Note": "<note>"}` -- the full
     note is always kept here even if the description truncates.

Stale message: *"Shot count changed since this die was opened (now N). Reload and
re-enter."*

**Docs:** `MPP_MES_DATA_MODEL.md` `Tools.Tool.ShotCount` row -- replace "no proc exposes
a setter" with the correction proc and D3. Revision history entry. Extended property in
`R__Descriptions_ExtendedProperties.sql` if it carries the same wording.

**Tests:** `sql/tests/0050_ToolShotCount/050_Tool_CorrectShotCount.sql` (INSERT-EXEC
pattern): correct up; correct down; to zero; blank note; unchanged; negative; stale
expected; non-Die tool; deprecated tool; audit row written with Delta + Note; no
`DieCastContribution` row created.

## 4. Named query + Python (Core)

- `named-query/parts/Tool_CorrectShotCount` -- `type: Query` (status-row proc); params
  `id`, `shotCount`, `expectedShotCount` (sqlType Int), `note` (String), `appUserId`.
- `BlueRidge.Common.Util.parseWholeNumber(v)` -> `(value, error)`. Unwraps QV, strips
  `,` and whitespace; blank -> `(None, None)`; non-digits -> `(None, "<msg>")`. New
  helper; `toIntOrNone` is left alone (plant-floor callers rely on its None fallback).
- `BlueRidge.Parts.Tool.get()`:
  - `ShotLimit` -> `"1,000,000"` or `""`.
  - `ShotCount` -> `"812,400"`; `ShotCountLoaded` -> raw int.
  - `ShotCountNote` -> `""`.
- `BlueRidge.Parts.Tool.update()`:
  1. Parse `ShotLimit` and `ShotCount`; any error -> return `{Status: 0, Message}`.
  2. Shot count changed (`parsed != ShotCountLoaded`) and note blank -> reject before
     any write.
  3. `Tool_Update` (unchanged call, parsed ShotLimit).
  4. If shot count changed: `Tool_CorrectShotCount` with `expectedShotCount =
     ShotCountLoaded`; failure message bubbles up.
  5. Existing `Tool_UpdateStatus` leg unchanged.
  Two transactions, as the status leg already is; on a later-leg failure the screen
  reloads to the true state.
- `getOrEmpty` / empty shapes gain `ShotCountLoaded` and `ShotCountNote`.

## 5. View -- `Parts/Tools` header (existing view)

- `FieldShotCount`: label "Total Shots" -> **"Current Shots"**; `ValueShotCount` label
  -> `ia.input.text-field` bidi to `view.custom.editDraft.meta.ShotCount`, enabled when
  not deprecated, `deferUpdates: false`.
- `InputShotLimit`: unchanged binding, now shows commas (from `get()`); label stays.
- New row `FieldRowShotCountNote` under `FieldRowShotLimit`: label "Shot Count Change
  Note (required)" + text-field bidi to `editDraft.meta.ShotCountNote`; `meta.visible`
  bound to `{view.custom.editDraft.meta.ShotCount} != {view.custom.selected.meta.ShotCount}`.
- `custom.editDraft.meta` and `custom.selected.meta` defaults gain `ShotCountLoaded: 0`
  and `ShotCountNote: ""`; strip the pickled live row from the defaults while there.
- Save/Discard/ConfirmUnsaved unchanged; after a successful save the view reloads the
  tool, so the note clears and `ShotCountLoaded` refreshes.

Existing view -> edit with the view closed in Designer, then `scan.ps1`, per the
file-edit boundary.

## 6. Out of scope

- No ledger table / correction-history grid (D5).
- No change to the shift-reconcile path, watermarks, or counter anchors.
- No change to plant-floor numeric parsing.
- `DuplicateDie` popup still resets ShotCount to 0.

## 7. Deploy

One new repeatable proc, no versioned migration. Prod shape per
`prod-release-context-pack/`: preview / rehearsal / execute, scoped export (Core: NQ +
`Parts/Tool` + `Common/Util` scripts; MPP_Config: `Parts/Tools` view), runbook artifact.
