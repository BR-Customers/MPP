# Audit Log Readability Refactor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Roll out the `Audit.ConfigLog` readability convention defined in `docs/superpowers/specs/2026-05-28-audit-readability-refactor-design.md` — every audit row emits a human-readable `SUBJECT · CATEGORY · ACTION` narrative `Description` and stores resolved-name `OldValue` / `NewValue` JSON. Lands across 8 slices: UI + popup + convention codification first; Eligibility as reference proc impl; then 6 backport slices through the rest of the audit-writing procs in the project.

**Architecture:** Per-proc convention adoption with two small `Audit`-schema helpers (`Audit.ufn_TruncateActivity` and `Audit.NCHAR_MIDDOT`). Each proc resolves its subject's names at proc start, builds a category-specific narrative from the change-set, and emits FK-resolved JSON for the diff snapshots. No new infrastructure; no schema changes; no migration. UI side rename `Description` column → `Activity` and fold in the broken-popup fix.

**Tech Stack:** SQL Server 2022 stored procs (`CREATE OR ALTER`), Ignition 8.3 Perspective views + named queries + script-python, Jython 2.7.

**Spec:** `docs/superpowers/specs/2026-05-28-audit-readability-refactor-design.md` (commit `cea8533` initial + `04938d6` popup-fix-in-scope addendum)

**Slice ordering — why this sequence:**

1. Slice 1 lands the convention doc, the UI changes, and fixes the load-bearing popup. Without the popup the truncation-and-recover story isn't actually recoverable; everything downstream depends on this.
2. Slice 2 (Eligibility) is the reference proc impl. Slices 3–8 all apply the same pattern — having one working example to mirror catches convention drift early.
3. Slices 3–8 are independent of each other; can be sequential or parallel via subagents. Sequencing here is rough effort order (BOMs/Routes share shape and can pair; Item core + LocationTypeEditor pair; Plant Hierarchy + Downtime/Defect codes pair).

---

## File Structure (Slice 1 + Slice 2)

| Path | Action | Slice | Responsibility |
|---|---|---|---|
| `sql/migrations/repeatable/R__Audit_ufn_TruncateActivity.sql` | Create | 1 | Scalar fn applying 500-char cap with `…` suffix |
| `sql/migrations/repeatable/R__Audit_ufn_MidDot.sql` | Create | 1 | Scalar fn returning `NCHAR(183)` middle-dot — keeps separator inline-callable |
| `sql/tests/0001_Audit/060_ufn_TruncateActivity.sql` | Create | 1 | Unit tests on the truncate fn |
| `sql_best_practices_mes.md` | Modify | 1 | Add "Audit Description Convention" section pointing at the spec |
| `CLAUDE.md` | Modify | 1 | Add brief Audit Description Convention subsection |
| `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Audit/AuditLog/view.json` | Modify | 1 | Rename `Description` column → `Activity` with `grow: 1`, `whiteSpace: pre-wrap`; drop `EntityId` column; add `ChangesSummary` column from in-flight handoff |
| `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/ConfigChangeDetail/view.json` | Modify | 1 | Diagnose + fix the broken popup per spec §6.2 |
| `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Common/Util/code.py` | Already-modified | 1 | The `summarizeJsonDiff` + `_formatDiffValue` already added 2026-05-27; commit alongside view changes |
| `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Audit/ConfigLog/code.py` | Already-modified | 1 | `search()` already stamps `ChangesSummary` per row; commit alongside view changes |
| `HANDOFF_AUDIT_LOG_2026-05-28.md` | Delete | 1 | Handoff doc; absorbed into this plan + spec |
| `sql/migrations/repeatable/R__Parts_ItemLocation_SaveAllForItem.sql` | Modify | 2 | Refactor per convention — resolve PartNumber/ItemDesc, build narrative Description, emit resolved-FK JSON |
| `sql/tests/0009_Parts_Process/040_ItemLocation_SaveAllForItem.sql` | Modify | 2 | Update assertions that examine Description text + add new assertions on resolved-JSON shape |

---

## Slice 1 — Convention + UI + Popup Fix

### Task 1.1: `Audit.NCHAR_MIDDOT` scalar function

**Files:**
- Create: `sql/migrations/repeatable/R__Audit_ufn_MidDot.sql`

- [ ] **Step 1: Write the function**

A tiny scalar function so procs can write `Audit.ufn_MidDot()` instead of remembering `NCHAR(183)`. Keeps every Description rendering the same separator.

```sql
-- =============================================
-- Function:    Audit.ufn_MidDot
-- Author:      Blue Ridge Automation
-- Created:     2026-05-28
-- Version:     1.0
--
-- Description:
--   Returns the middle-dot character (U+00B7) used as the standard
--   separator in Audit.ConfigLog.Description prose. Defined as a
--   function so callers don't need to remember NCHAR(183) or worry
--   about file-encoding round-trips through sqlcmd.
--
-- Returns:
--   NCHAR(1) — the middle-dot character.
-- =============================================
CREATE OR ALTER FUNCTION Audit.ufn_MidDot()
RETURNS NCHAR(1)
WITH SCHEMABINDING
AS
BEGIN
    RETURN NCHAR(183);
END;
GO
```

- [ ] **Step 2: Deploy + smoke**

```bash
sqlcmd -S localhost -d MPP_MES_Dev -E -C -b -I -i sql/migrations/repeatable/R__Audit_ufn_MidDot.sql
sqlcmd -S localhost -d MPP_MES_Dev -E -C -b -I -Q "SELECT N'A' + Audit.ufn_MidDot() + N'B' AS Sep;"
```

Expected: `A·B` (with the middle dot in the middle).

- [ ] **Step 3: Commit**

```bash
git add sql/migrations/repeatable/R__Audit_ufn_MidDot.sql
git commit -m "feat(audit): Audit.ufn_MidDot() — middle-dot separator helper for Description prose"
```

---

### Task 1.2: `Audit.ufn_TruncateActivity` scalar function

**Files:**
- Create: `sql/migrations/repeatable/R__Audit_ufn_TruncateActivity.sql`
- Create: `sql/tests/0001_Audit/060_ufn_TruncateActivity.sql`

- [ ] **Step 1: Write the function**

```sql
-- =============================================
-- Function:    Audit.ufn_TruncateActivity
-- Author:      Blue Ridge Automation
-- Created:     2026-05-28
-- Version:     1.0
--
-- Description:
--   Applies the standard Audit.ConfigLog.Description cap: 500 chars
--   with N'…' (U+2026 horizontal ellipsis) suffix when the input
--   exceeds the cap. Below the cap the input is returned verbatim.
--
--   Cap reflects the at-a-glance read budget on the AuditLog table
--   row; the full diff is always recoverable from OldValue / NewValue
--   JSON via the ConfigChangeDetail popup (spec §6.3 auditor flow).
--
--   NULL input returns NULL (no implicit '' coercion -- callers should
--   never pass NULL but if they do the bug surfaces as NULL Description
--   in the audit row, not silent loss).
--
-- Parameters:
--   @Text NVARCHAR(MAX) - the proposed Description prose.
--
-- Returns:
--   NVARCHAR(500) - truncated as needed; NULL if input is NULL.
-- =============================================
CREATE OR ALTER FUNCTION Audit.ufn_TruncateActivity(@Text NVARCHAR(MAX))
RETURNS NVARCHAR(500)
WITH SCHEMABINDING
AS
BEGIN
    IF @Text IS NULL RETURN NULL;
    IF LEN(@Text) <= 500 RETURN CAST(@Text AS NVARCHAR(500));
    -- Reserve 1 char for the ellipsis -- LEFT 499 chars + N'…'
    RETURN LEFT(@Text, 499) + NCHAR(8230);
END;
GO
```

- [ ] **Step 2: Write tests**

```sql
-- =============================================
-- File:         0001_Audit/060_ufn_TruncateActivity.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-05-28
-- Description:  Tests for Audit.ufn_TruncateActivity.
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0001_Audit/060_ufn_TruncateActivity.sql';
GO

-- =============================================
-- Test 1: NULL input -> NULL
-- =============================================
DECLARE @Actual NVARCHAR(500) = Audit.ufn_TruncateActivity(NULL);
DECLARE @ActualStr NVARCHAR(10) = CASE WHEN @Actual IS NULL THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[TruncNull] NULL passes through',
    @Expected = N'1',
    @Actual   = @ActualStr;
GO

-- =============================================
-- Test 2: Short input passes through verbatim
-- =============================================
DECLARE @Input NVARCHAR(MAX) = N'5G0 · Eligibility · +DIECAST';
DECLARE @Actual NVARCHAR(500) = Audit.ufn_TruncateActivity(@Input);
EXEC test.Assert_IsEqual
    @TestName = N'[TruncShort] Short input verbatim',
    @Expected = @Input,
    @Actual   = @Actual;
GO

-- =============================================
-- Test 3: Exactly-500 input passes through verbatim
-- =============================================
DECLARE @Input NVARCHAR(MAX) = REPLICATE(N'a', 500);
DECLARE @Actual NVARCHAR(500) = Audit.ufn_TruncateActivity(@Input);
DECLARE @LenStr NVARCHAR(10) = CAST(LEN(@Actual) AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[TruncBoundary] 500-char input verbatim, length 500',
    @Expected = N'500',
    @Actual   = @LenStr;
GO

-- =============================================
-- Test 4: 501-char input gets truncated, suffix is the ellipsis
-- =============================================
DECLARE @Input NVARCHAR(MAX) = REPLICATE(N'a', 501);
DECLARE @Actual NVARCHAR(500) = Audit.ufn_TruncateActivity(@Input);
DECLARE @LenStr NVARCHAR(10) = CAST(LEN(@Actual) AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[TruncOverflow] 501-char input truncated to 500',
    @Expected = N'500',
    @Actual   = @LenStr;

DECLARE @LastChar NVARCHAR(1) = RIGHT(@Actual, 1);
DECLARE @IsEllipsis NVARCHAR(1) = CASE WHEN @LastChar = NCHAR(8230) THEN N'1' ELSE N'0' END;
EXEC test.Assert_IsEqual
    @TestName = N'[TruncOverflow] Last char is the ellipsis NCHAR(8230)',
    @Expected = N'1',
    @Actual   = @IsEllipsis;
GO

-- =============================================
-- Test 5: Very long input (5000 chars) — capped at 500 with ellipsis
-- =============================================
DECLARE @Input NVARCHAR(MAX) = REPLICATE(N'b', 5000);
DECLARE @Actual NVARCHAR(500) = Audit.ufn_TruncateActivity(@Input);
DECLARE @LenStr NVARCHAR(10) = CAST(LEN(@Actual) AS NVARCHAR(10));
EXEC test.Assert_IsEqual
    @TestName = N'[TruncFar] 5000-char input capped at 500',
    @Expected = N'500',
    @Actual   = @LenStr;
GO

EXEC test.EndTestFile;
GO
```

- [ ] **Step 3: Deploy + run tests**

```bash
sqlcmd -S localhost -d MPP_MES_Dev -E -C -b -I -i sql/migrations/repeatable/R__Audit_ufn_TruncateActivity.sql
sqlcmd -S localhost -d MPP_MES_Dev -E -C -b -I -i sql/tests/0001_Audit/060_ufn_TruncateActivity.sql
```

Expected: all 5 asserts pass.

- [ ] **Step 4: Commit**

```bash
git add sql/migrations/repeatable/R__Audit_ufn_TruncateActivity.sql sql/tests/0001_Audit/060_ufn_TruncateActivity.sql
git commit -m "feat(audit): Audit.ufn_TruncateActivity — 500-char cap with ellipsis suffix"
```

---

### Task 1.3: Codify the convention in `sql_best_practices_mes.md` + CLAUDE.md

**Files:**
- Modify: `sql_best_practices_mes.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add a new section to `sql_best_practices_mes.md`**

Append a top-level section titled `## Audit Description Convention` with:
- The `SUBJECT · CATEGORY · ACTION` shape
- The middle-dot separator (use `Audit.ufn_MidDot()`)
- The verb/symbol vocabulary (`+ - ~` inline; `Created` / `Deprecated` / `Published` / `Reordered` / `Moved` verb-form)
- The field-diff notation (`Field old→new`, scalars unquoted, strings quoted, NULLs literal)
- The truncation rule (call `Audit.ufn_TruncateActivity` when composing)
- The FK-resolution rule for `OldValue` / `NewValue` JSON (every FK → `{Id, Code, Name}`)
- Pointer at the spec for the per-category catalog and worked examples

Body should be ~80-120 lines. Use the spec §3, §4, §5.x as the canonical source.

- [ ] **Step 2: Add a brief subsection to CLAUDE.md**

Under `## Conventions`, add a subsection titled `### Audit log Description convention` (~10 lines). Points readers at `sql_best_practices_mes.md` for the full convention and `docs/superpowers/specs/2026-05-28-audit-readability-refactor-design.md` for the catalog.

- [ ] **Step 3: Commit**

```bash
git add sql_best_practices_mes.md CLAUDE.md
git commit -m "docs(convention): codify Audit Description convention in best-practices + CLAUDE.md"
```

---

### Task 1.4: AuditLog view — rename Description→Activity, drop EntityId, add Changes column

**Files:**
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Audit/AuditLog/view.json`

This is a Designer-side edit (per file-edit boundary memory — `view.json` edits to existing views go through Designer). Steps below describe the Designer interactions, NOT file edits.

- [ ] **Step 1: Pull latest + open Designer**

```bash
git pull --ff-only origin main
```

Open Designer → navigate to `BlueRidge/Views/Audit/AuditLog` → click `root.MainSplit.ContentArea.AuditPanelWrapper.AuditPanel.AuditTable`.

- [ ] **Step 2: Drop EntityId column**

In the property editor, find `props.columns` → expand the array → find the entry with `field: "EntityId"` → delete it. The numeric Entity ID alone is meaningless; the ID is still passed to ConfigChangeDetail popup via the row click handler.

- [ ] **Step 3: Add ChangesSummary column**

Add a new column between the existing Event column and Severity column. Suggested values (use the full 25-key column schema per `feedback_ignition_table_column_full_schema.md`):

```
field:    ChangesSummary
header.title: Changes
sortable: false
visible:  true
style.fontFamily: ui-monospace, Menlo, Consolas, monospace
style.fontSize:   11px
style.color:      var(--mpp-text-secondary)
style.whiteSpace: nowrap
style.overflow:   hidden
style.textOverflow: ellipsis
```

If Designer post-scan complains with Component Error, copy the full column schema shape from a sibling column (e.g. Description) and override only `field` / `header` / `style`.

- [ ] **Step 4: Rename Description column to Activity, allow wrap**

Find the column entry with `field: "Description"`:
- Change `header.title` from "Description" to "Activity"
- DO NOT change `field` — the underlying ConfigLog column is still `Description`; only the user-facing column header renames
- Set `width` to a larger value (or remove width entirely; let `grow: 1` absorb space)
- Set `style.whiteSpace` to `pre-wrap`
- Set `style.maxHeight` or row-height to allow up to 2 visible lines with overflow tooltip

- [ ] **Step 5: Save in Designer + sync to disk**

File → Save in Designer. Confirm changes flushed to `view.json` on disk via `git diff`.

- [ ] **Step 6: Commit the AuditLog view + the already-modified script files**

The in-flight handoff has 3 already-modified files in working tree that pair with this view change:
- `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Common/Util/code.py` — `summarizeJsonDiff` + `_formatDiffValue` helpers (2026-05-27)
- `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Audit/ConfigLog/code.py` — `search()` stamps `ChangesSummary` per row (2026-05-27)
- `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Audit/AuditLog/view.json` — the Designer changes from this task

```bash
git add ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Common/Util/code.py \
        ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Audit/ConfigLog/code.py \
        ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Audit/AuditLog/view.json
git commit -m "feat(audit): inline Activity column + ChangesSummary diff column

- Drop the meaningless numeric EntityId column from the AuditLog table.
- Rename the Description column header to Activity (column field stays
  as Description -- only the user-facing header renames). Allow wrap +
  multi-line so the SUBJECT · CATEGORY · ACTION prose reads cleanly.
- Add ChangesSummary column showing a compact one-line JSON diff
  computed in BlueRidge.Audit.ConfigLog.search via the new
  BlueRidge.Common.Util.summarizeJsonDiff helper (2026-05-27 work).

Folds in the audit-log Changes column work from 2026-05-27 evening
that had script changes loaded into the gateway but Designer-side
column add still pending."
```

- [ ] **Step 7: Delete the handoff doc**

```bash
git rm HANDOFF_AUDIT_LOG_2026-05-28.md
git commit -m "docs(audit): absorb handoff doc into audit-readability spec/plan

The HANDOFF_AUDIT_LOG_2026-05-28.md content is now covered by:
- docs/superpowers/specs/2026-05-28-audit-readability-refactor-design.md
- docs/superpowers/plans/2026-05-28-audit-readability-refactor.md (this plan)
- The just-landed AuditLog view changes."
```

- [ ] **Step 8: Push**

```bash
git push
```

---

### Task 1.5: Diagnose + fix ConfigChangeDetail popup

**Files:**
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/ConfigChangeDetail/view.json`

- [ ] **Step 1: Smoke-reproduce the failure**

Open `/audit` in a Perspective Session (Designer Preview, or directly against the gateway). Click any existing ConfigLog row.

Categorize what happens:
- **Silent no-op (nothing happens)** — likely the `system.perspective.openPopup` event handler has `scope: "C"` instead of `scope: "G"`. See `feedback_ignition_popup_open_scope.md`. Grep the AuditTable row-click event in `BlueRidge/Views/Audit/AuditLog/view.json` and look for the scope tag.
- **Opens but empty / loading spinner forever** — `viewParams` payload mismatch. The popup expects `params` like `{logRow: {...}}` or specific fields like `oldValue` / `newValue`; the click handler is passing something different.
- **Opens with Component Error** — the popup's bindings reference shapes that don't match what `BlueRidge.Audit.ConfigLog.search` returns. May have drifted since the popup was built.

- [ ] **Step 2: Read the popup's view.json + the click handler side-by-side**

Compare:
- `views/BlueRidge/Components/Popups/ConfigChangeDetail/view.json` — what `params.*` does it declare? What does it bind to?
- `views/BlueRidge/Views/Audit/AuditLog/view.json` AuditTable `onRowClick` (or equivalent) — what `viewParams` does it pass to `openPopup`?

Identify the gap.

- [ ] **Step 3: Fix per the gap found in Step 1**

The most likely fixes:

**A) Scope C → G:**
```json
"onRowClick": {
  "type": "script",
  "scope": "G",          // ← was "C"; "C" silently no-ops openPopup
  "config": { "script": "..." }
}
```

**B) viewParams alignment:**

Match the popup's `params` shape to what the click handler passes. Reference shape (adjust based on what the popup expects):

```json
"viewParams": {
  "logRow": {
    "Id": ...,
    "OldValue": ...,
    "NewValue": ...,
    "Description": ...,
    "LoggedAt": ...
  }
}
```

**C) Binding drift:**

Popup's `propConfig` bindings on `params.logRow.OldValue` etc. may reference paths that no longer exist if `ConfigLog.search`'s return shape changed. Verify against `BlueRidge.Audit.ConfigLog.search()` output structure.

- [ ] **Step 4: Verify acceptance criteria**

Per spec §6.2:
- Clicking any ConfigLog row opens the popup
- Both `OldValue` and `NewValue` JSON render pretty-printed (via `Common.Util.prettyJson`) side-by-side
- Close button works
- Subsequent row clicks open with the new row's data (no stale state)

- [ ] **Step 5: Commit**

```bash
git add <files-touched>
git commit -m "fix(audit): ConfigChangeDetail popup — <one-line description of root cause>

Diagnostic from spec §6.2: <silent no-op | opens-empty | opens-error>.

Root cause: <e.g. row-click handler had scope=C, silently dropping
system.perspective.openPopup. Per feedback_ignition_popup_open_scope
this is twice-empirically-observed in this project.>

Fix: <e.g. flip scope C → G; viewParams shape now matches popup's
params declaration>.

Acceptance per spec §6.2: any ConfigLog row click opens popup with
OldValue + NewValue pretty-printed side-by-side; close + reopen work."
```

- [ ] **Step 6: Push**

```bash
git push
```

---

### Task 1.6: Slice 1 closeout

- [ ] Update `PROJECT_STATUS.md` "Recently closed" with a Slice 1 entry: convention helpers landed, UI changes landed, popup fixed, handoff absorbed.
- [ ] Update `PROJECT_STATUS.md` "Next Session Pickup" to point at Slice 2 (Eligibility reference impl).
- [ ] Commit + push the status update.

---

## Slice 2 — Eligibility proc as reference impl

Refactors `Parts.ItemLocation_SaveAllForItem` to emit the convention-compliant Description + resolved-FK JSON. This is the reference impl that Slices 3–8 mirror.

### Task 2.1: Plan the proc refactor

Before touching the proc, walk through what changes:

**Current proc emission** (current code):
```sql
EXEC Audit.Audit_LogConfigChange
    @AppUserId         = @AppUserId,
    @LogEntityTypeCode = N'ItemLocation',
    @EntityId          = @ItemId,
    @LogEventTypeCode  = N'Updated',
    @LogSeverityCode   = N'Info',
    @Description       = N'Eligibility map updated.',
    @OldValue          = @OldValue,
    @NewValue          = @RowsJson;
```

**Target emission** (convention):
```sql
EXEC Audit.Audit_LogConfigChange
    @AppUserId         = @AppUserId,
    @LogEntityTypeCode = N'ItemLocation',
    @EntityId          = @ItemId,
    @LogEventTypeCode  = N'Updated',
    @LogSeverityCode   = N'Info',
    @Description       = @Activity,  -- built locally per convention
    @OldValue          = @OldValueResolved,
    @NewValue          = @NewValueResolved;
```

With three new local-variable builds inside the proc:

1. **`@PartNumber` + `@ItemDesc`** — resolved once at proc start
2. **`@Activity`** — composed from `@Incoming` joined to `Parts.ItemLocation` (existing rows) and `Location.Location` (for resolved names), respecting the `+ - ~` symbol order and the 3-specifics-per-op cap
3. **`@OldValueResolved` / `@NewValueResolved`** — `FOR JSON PATH` with Location subqueries

### Task 2.2: Add subject resolution + change-set classification temp tables

**File:** `sql/migrations/repeatable/R__Parts_ItemLocation_SaveAllForItem.sql`

Inside the proc body, after `@Incoming` is populated and validation passes, add:

```sql
-- Subject resolution (convention §3.1 - SUBJECT)
DECLARE @PartNumber NVARCHAR(50);
DECLARE @ItemDesc   NVARCHAR(500);

SELECT @PartNumber = PartNumber, @ItemDesc = Description
FROM Parts.Item
WHERE Id = @ItemId;

DECLARE @Subject NVARCHAR(600) =
    @PartNumber + CASE WHEN @ItemDesc IS NOT NULL THEN N' — ' + @ItemDesc ELSE N'' END;

-- Change-set classification (drives Activity prose + resolved JSON)
DECLARE @Changes TABLE (
    ChangeKind          NCHAR(1) NOT NULL,  -- '+' / '-' / '~'
    SortKey             INT NOT NULL,       -- canonical order within kind
    ExistingId          BIGINT NULL,        -- present for - and ~
    LocationId          BIGINT NOT NULL,
    LocationCode        NVARCHAR(50) NOT NULL,
    LocationName        NVARCHAR(200) NOT NULL,
    TierDefName         NVARCHAR(100) NOT NULL,
    OldIsConsumption    BIT NULL,
    NewIsConsumption    BIT NULL,
    OldMin              INT NULL, NewMin INT NULL,
    OldMax              INT NULL, NewMax INT NULL,
    OldDefault          INT NULL, NewDefault INT NULL
);

-- ADDS: incoming Id IS NULL, no active or deprecated pairing
INSERT INTO @Changes
    (ChangeKind, SortKey, LocationId, LocationCode, LocationName, TierDefName,
     NewIsConsumption, NewMin, NewMax, NewDefault)
SELECT N'+',
       ROW_NUMBER() OVER (ORDER BY l.Code),
       l.Id, l.Code, l.Name, ltd.Name,
       i.IsConsumptionPoint, i.MinQuantity, i.MaxQuantity, i.DefaultQuantity
FROM @Incoming i
INNER JOIN Location.Location l ON l.Id = i.LocationId
INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
WHERE i.Id IS NULL
  AND NOT EXISTS (SELECT 1 FROM Parts.ItemLocation il
                  WHERE il.ItemId = @ItemId AND il.LocationId = i.LocationId);

-- ADDS via REACTIVATION (incoming Id IS NULL, deprecated pairing exists)
-- These render as ADD in the audit narrative; the reactivation is a DB detail
INSERT INTO @Changes
    (ChangeKind, SortKey, ExistingId, LocationId, LocationCode, LocationName,
     TierDefName, NewIsConsumption, NewMin, NewMax, NewDefault)
SELECT N'+',
       100 + ROW_NUMBER() OVER (ORDER BY l.Code),
       il.Id, l.Id, l.Code, l.Name, ltd.Name,
       i.IsConsumptionPoint, i.MinQuantity, i.MaxQuantity, i.DefaultQuantity
FROM @Incoming i
INNER JOIN Parts.ItemLocation il
    ON il.ItemId = @ItemId AND il.LocationId = i.LocationId AND il.DeprecatedAt IS NOT NULL
INNER JOIN Location.Location l ON l.Id = i.LocationId
INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
WHERE i.Id IS NULL;

-- UPDATES: Id matched + at least one field differs
INSERT INTO @Changes
    (ChangeKind, SortKey, ExistingId, LocationId, LocationCode, LocationName,
     TierDefName,
     OldIsConsumption, NewIsConsumption,
     OldMin, NewMin, OldMax, NewMax, OldDefault, NewDefault)
SELECT N'~',
       ROW_NUMBER() OVER (ORDER BY l.Code),
       il.Id, l.Id, l.Code, l.Name, ltd.Name,
       il.IsConsumptionPoint, i.IsConsumptionPoint,
       il.MinQuantity, i.MinQuantity,
       il.MaxQuantity, i.MaxQuantity,
       il.DefaultQuantity, i.DefaultQuantity
FROM @Incoming i
INNER JOIN Parts.ItemLocation il ON il.Id = i.Id
INNER JOIN Location.Location l ON l.Id = il.LocationId
INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
WHERE il.DeprecatedAt IS NULL
  AND (il.IsConsumptionPoint <> i.IsConsumptionPoint
       OR ISNULL(il.MinQuantity, -1) <> ISNULL(i.MinQuantity, -1)
       OR ISNULL(il.MaxQuantity, -1) <> ISNULL(i.MaxQuantity, -1)
       OR ISNULL(il.DefaultQuantity, -1) <> ISNULL(i.DefaultQuantity, -1));

-- REMOVES: active row whose Id is not in incoming
INSERT INTO @Changes
    (ChangeKind, SortKey, ExistingId, LocationId, LocationCode, LocationName,
     TierDefName, OldIsConsumption, OldMin, OldMax, OldDefault)
SELECT N'-',
       ROW_NUMBER() OVER (ORDER BY l.Code),
       il.Id, l.Id, l.Code, l.Name, ltd.Name,
       il.IsConsumptionPoint, il.MinQuantity, il.MaxQuantity, il.DefaultQuantity
FROM Parts.ItemLocation il
INNER JOIN Location.Location l ON l.Id = il.LocationId
INNER JOIN Location.LocationTypeDefinition ltd ON ltd.Id = l.LocationTypeDefinitionId
WHERE il.ItemId = @ItemId AND il.DeprecatedAt IS NULL
  AND NOT EXISTS (SELECT 1 FROM @Incoming i WHERE i.Id = il.Id);
```

### Task 2.3: Build the Activity narrative

Continuing inside the proc, after `@Changes` is populated:

```sql
-- Per-operation specific lists (cap at 3 each per convention §3.4)
DECLARE @AddSpecifics    NVARCHAR(MAX) = N'';
DECLARE @AddOverflow     INT = 0;
DECLARE @UpdateSpecifics NVARCHAR(MAX) = N'';
DECLARE @UpdateOverflow  INT = 0;
DECLARE @RemoveSpecifics NVARCHAR(MAX) = N'';
DECLARE @RemoveOverflow  INT = 0;
DECLARE @TotalRows       INT = (SELECT COUNT(*) FROM @Incoming);

-- Adds: render as "+CODE (TierDefName)" -- TierDef gives spatial context
;WITH ranked AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY SortKey) AS rn
    FROM @Changes WHERE ChangeKind = N'+'
)
SELECT @AddSpecifics = STRING_AGG(
    N'+' + LocationCode + N' (' + TierDefName + N')',
    N', '
) WITHIN GROUP (ORDER BY rn)
FROM ranked WHERE rn <= 3;
SELECT @AddOverflow = COUNT(*) - 3 FROM @Changes WHERE ChangeKind = N'+';
IF @AddOverflow < 0 SET @AddOverflow = 0;

-- Updates: render the changed fields as Field old→new tuples
;WITH ranked AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY SortKey) AS rn
    FROM @Changes WHERE ChangeKind = N'~'
)
SELECT @UpdateSpecifics = STRING_AGG(
    N'~' + LocationCode + N' ' +
    STUFF(
        CONCAT(
            CASE WHEN OldIsConsumption <> NewIsConsumption
                 THEN N', IsConsumptionPoint ' + CAST(OldIsConsumption AS NVARCHAR) + N'→' + CAST(NewIsConsumption AS NVARCHAR)
                 ELSE N'' END,
            CASE WHEN ISNULL(OldMin, -1) <> ISNULL(NewMin, -1)
                 THEN N', MinQuantity ' + ISNULL(CAST(OldMin AS NVARCHAR), N'null') + N'→' + ISNULL(CAST(NewMin AS NVARCHAR), N'null')
                 ELSE N'' END,
            CASE WHEN ISNULL(OldMax, -1) <> ISNULL(NewMax, -1)
                 THEN N', MaxQuantity ' + ISNULL(CAST(OldMax AS NVARCHAR), N'null') + N'→' + ISNULL(CAST(NewMax AS NVARCHAR), N'null')
                 ELSE N'' END,
            CASE WHEN ISNULL(OldDefault, -1) <> ISNULL(NewDefault, -1)
                 THEN N', DefaultQuantity ' + ISNULL(CAST(OldDefault AS NVARCHAR), N'null') + N'→' + ISNULL(CAST(NewDefault AS NVARCHAR), N'null')
                 ELSE N'' END
        ),
        1, 2, N''  -- strip the leading ", "
    ),
    N'; '
) WITHIN GROUP (ORDER BY rn)
FROM ranked WHERE rn <= 3;
SELECT @UpdateOverflow = COUNT(*) - 3 FROM @Changes WHERE ChangeKind = N'~';
IF @UpdateOverflow < 0 SET @UpdateOverflow = 0;

-- Removes: render as "-CODE"
;WITH ranked AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY SortKey) AS rn
    FROM @Changes WHERE ChangeKind = N'-'
)
SELECT @RemoveSpecifics = STRING_AGG(N'-' + LocationCode, N', ')
                          WITHIN GROUP (ORDER BY rn)
FROM ranked WHERE rn <= 3;
SELECT @RemoveOverflow = COUNT(*) - 3 FROM @Changes WHERE ChangeKind = N'-';
IF @RemoveOverflow < 0 SET @RemoveOverflow = 0;

-- Compose the Activity prose: SUBJECT · CATEGORY · ACTION; N rows
DECLARE @ActionParts NVARCHAR(MAX) = N'';

IF NULLIF(@AddSpecifics, N'') IS NOT NULL
    SET @ActionParts = @ActionParts + @AddSpecifics +
                       CASE WHEN @AddOverflow > 0 THEN N', +' + CAST(@AddOverflow AS NVARCHAR) + N' more' ELSE N'' END +
                       N'; ';

IF NULLIF(@UpdateSpecifics, N'') IS NOT NULL
    SET @ActionParts = @ActionParts + @UpdateSpecifics +
                       CASE WHEN @UpdateOverflow > 0 THEN N'; ~' + CAST(@UpdateOverflow AS NVARCHAR) + N' more' ELSE N'' END +
                       N'; ';

IF NULLIF(@RemoveSpecifics, N'') IS NOT NULL
    SET @ActionParts = @ActionParts + @RemoveSpecifics +
                       CASE WHEN @RemoveOverflow > 0 THEN N', -' + CAST(@RemoveOverflow AS NVARCHAR) + N' more' ELSE N'' END +
                       N'; ';

-- Strip trailing "; "
IF LEN(@ActionParts) >= 2
    SET @ActionParts = LEFT(@ActionParts, LEN(@ActionParts) - 2);

IF @ActionParts = N''
    SET @ActionParts = N'No-op save';

DECLARE @ActivityRaw NVARCHAR(MAX) =
    @Subject + N' ' + Audit.ufn_MidDot() + N' Eligibility ' + Audit.ufn_MidDot() +
    N' ' + @ActionParts +
    N'; ' + CAST(@TotalRows AS NVARCHAR) + N' rows';

DECLARE @Activity NVARCHAR(500) = Audit.ufn_TruncateActivity(@ActivityRaw);
```

### Task 2.4: Build the resolved-FK OldValue / NewValue JSON

```sql
-- OldValue: pre-state active rows with resolved Location names
DECLARE @OldValueResolved NVARCHAR(MAX) = (
    SELECT
        il.Id,
        (SELECT l.Id, l.Code, l.Name
         FROM Location.Location l WHERE l.Id = il.LocationId
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)             AS Location,
        il.IsConsumptionPoint,
        il.MinQuantity, il.MaxQuantity, il.DefaultQuantity
    FROM Parts.ItemLocation il
    WHERE il.ItemId = @ItemId AND il.DeprecatedAt IS NULL
    ORDER BY il.LocationId
    FOR JSON PATH
);

-- NewValue: post-state intent from @Incoming, with resolved Location names
DECLARE @NewValueResolved NVARCHAR(MAX) = (
    SELECT
        i.Id,
        (SELECT l.Id, l.Code, l.Name
         FROM Location.Location l WHERE l.Id = i.LocationId
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)             AS Location,
        i.IsConsumptionPoint,
        i.MinQuantity, i.MaxQuantity, i.DefaultQuantity
    FROM @Incoming i
    ORDER BY i.LocationId
    FOR JSON PATH
);
```

### Task 2.5: Wire to the Audit_LogConfigChange call + remove old emission

Replace the existing `EXEC Audit.Audit_LogConfigChange` block inside the proc with:

```sql
EXEC Audit.Audit_LogConfigChange
    @AppUserId         = @AppUserId,
    @LogEntityTypeCode = N'ItemLocation',
    @EntityId          = @ItemId,
    @LogEventTypeCode  = N'Updated',
    @LogSeverityCode   = N'Info',
    @Description       = @Activity,
    @OldValue          = @OldValueResolved,
    @NewValue          = @NewValueResolved;
```

The previous `@OldValue` declaration + assignment + `@RowsJson` direct-pass are replaced by the resolved versions.

### Task 2.6: Update existing tests + add convention-shape assertions

**File:** `sql/tests/0009_Parts_Process/040_ItemLocation_SaveAllForItem.sql`

The existing 11 tests assert on Status truthy/falsy. They should continue to pass because the proc's behavior contract (status row, ROLLBACK on validation failure, etc.) is unchanged.

Add 4 new tests verifying the convention:

```sql
-- =============================================
-- Test 9: Activity Description has SUBJECT · Eligibility · prefix
-- =============================================
-- Add a row, then SELECT TOP 1 Description FROM Audit.ConfigLog ORDER BY Id DESC,
-- assert Description LIKE N'TEST-ELIG-ITEM-001%' + Audit.ufn_MidDot() + N' Eligibility ' + Audit.ufn_MidDot() + N'%'.
-- ...

-- =============================================
-- Test 10: Activity Description includes the location Code
-- =============================================
-- Assert Description LIKE N'%+%' (where the location code appears with + prefix).

-- =============================================
-- Test 11: NewValue JSON contains resolved Location with Code + Name
-- =============================================
-- Parse NewValue JSON and assert it contains "Location": {"Id": N, "Code": "...", "Name": "..."}.

-- =============================================
-- Test 12: Activity prose stays under 500 chars on a normal save
-- =============================================
-- Assert LEN(Description) <= 500 from a multi-change save.
```

### Task 2.7: Deploy + run tests

```bash
sqlcmd -S localhost -d MPP_MES_Dev -E -C -b -I -i sql/migrations/repeatable/R__Parts_ItemLocation_SaveAllForItem.sql
sqlcmd -S localhost -d MPP_MES_Dev -E -C -b -I -i sql/tests/0009_Parts_Process/040_ItemLocation_SaveAllForItem.sql
```

Expected: original 11 tests still pass, 4 new tests pass.

### Task 2.8: Designer smoke

1. Open `/items` → pick an item → Eligibility tab.
2. Add a Location → Save.
3. Open `/audit` → click the freshly-created ConfigLog row.
4. Verify in the table row: Activity reads as `<PartNumber> — <Description> · Eligibility · +<Code> (<TierDefName>); 1 rows`.
5. Verify in the popup: NewValue JSON shows `Location: {Id, Code, Name}` not bare `LocationId: N`.
6. Repeat with a multi-change save (add + edit + remove) to see the narrative compose.

### Task 2.9: Commit + push

```bash
git add sql/migrations/repeatable/R__Parts_ItemLocation_SaveAllForItem.sql \
        sql/tests/0009_Parts_Process/040_ItemLocation_SaveAllForItem.sql
git commit -m "feat(audit): Eligibility proc — convention-compliant Activity prose + resolved JSON

Reference impl of the Audit Description convention from spec
2026-05-28-audit-readability-refactor-design.md. Parts.ItemLocation_
SaveAllForItem now:

- Resolves Item PartNumber + Description at proc start.
- Classifies the change-set into @Changes with +/-/~ kinds, joined to
  Location.Location + Location.LocationTypeDefinition for names.
- Composes Activity prose with 3-specifics-per-op cap + overflow
  counters: '5G0 — Front Cover Assembly · Eligibility · +DIECAST
  (Production Area); -DC-401; ~DC-501 IsConsumptionPoint false→true;
  3 rows'.
- Emits OldValue / NewValue JSON with LocationId expanded to
  {Id, Code, Name} sub-objects (one JOIN per row at write time, zero
  JOINs at read time).
- Uses Audit.ufn_MidDot() for the separator and
  Audit.ufn_TruncateActivity() for the 500-char cap.

Tests: original 11 still pass; 4 new tests verify the convention
shape (prefix, location-code presence, resolved JSON, length cap).

Slice 2 of audit-readability refactor. Slices 3-8 mirror this pattern
across BOMs, Routes, Identity/ContainerConfig, Plant Hierarchy,
LocationTypeEditor, Downtime + Defect codes."
git push
```

### Task 2.10: Slice 2 closeout

- [ ] Update `PROJECT_STATUS.md` Recently Closed with Slice 2 entry referencing the convention being reference-implemented in Eligibility.
- [ ] Update Next Session Pickup to point at Slice 2.5 (popup diff highlighting).

---

## Slice 2.5 — ConfigChangeDetail popup diff highlighting

Polish slice that depends on Slice 2's resolved-name JSON to be useful. Trying to highlight differences across bare-ID JSON gives `LocationId: 4 → 5` (red strikethrough + green) which tells the reader nothing about which Location. After Slice 2 it reads `Location DC-401 → DC-402` (red strikethrough + green) which is genuinely actionable.

### Files

| Path | Action | Responsibility |
|---|---|---|
| `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Common/Util/code.py` | Modify | Add `prettyJsonDiff(oldJson, newJson)` helper alongside existing `prettyJson` + `summarizeJsonDiff`. Returns markdown text with embedded HTML spans coloring added (green) / removed (red) / changed (yellow) keys. |
| `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/ConfigChangeDetail/view.json` | Modify | Replace the two `ia.display.label` Old/New body blocks with `ia.display.markdown` components. Set `escapeHtml: false` so embedded HTML spans render. Bind `props.markdown` to the helper output via runScript. |

### Tasks

- [ ] **Task 2.5.1: Write `Common.Util.prettyJsonDiff`** (~60 lines Python). Walk-the-tree key-level comparison. For each top-level array element / dict key, emit one markdown line. Color rules:
  - **Added** (in new, not in old): `<span style="color:#5db38a">+ Key: value</span>` (green)
  - **Removed** (in old, not in new): `<span style="color:#d97064">- Key: value</span>` (red)
  - **Changed** (in both, value differs): `<span style="color:#e6c14e">~ Key: oldValue → newValue</span>` (yellow)
  - **Unchanged**: plain text `Key: value` (or skip entirely if Description carries the narrative)
- [ ] **Task 2.5.2: Two output modes.** Per-side rendering (left block shows old with removed lines highlighted; right block shows new with added lines highlighted) OR unified diff (single block with both adds and removes interleaved). Recommendation: unified single-block, drops the side-by-side layout. Less wasted space; the diff reads as one narrative.
- [ ] **Task 2.5.3: Popup view.json swap.** Replace the two label blocks (lines 96-117 of `ConfigChangeDetail/view.json`) with one `ia.display.markdown` block. Bind via `runScript("BlueRidge.Common.Util.prettyJsonDiff", 0, {view.params.oldValue}, {view.params.newValue})`. Set `escapeHtml: false`.
- [ ] **Task 2.5.4: Diagnostic + smoke.** Click any audit row → diff renders with colored spans. Click a Create event (oldValue is null) → all lines render green. Click a Deprecate event (newValue same as old + DeprecatedAt added) → most lines plain, just `+ DeprecatedAt` green.
- [ ] **Task 2.5.5: Commit + push.**
- [ ] **Task 2.5.6: Slice 2.5 closeout.** PROJECT_STATUS update pointing at Slice 3.

### Color palette source

Pull from existing project CSS vars if available (`--mpp-success` / `--mpp-error` / `--mpp-warning`). Otherwise hardcode the hex values listed above which match the project's dark theme.

### Skip if diff helper proves too noisy

The dual-block layout with resolved-name JSON post-Slice-2 may be readable enough on its own without diff highlighting. If the helper output adds visual noise rather than clarity, revert to the dual-block label render and call Slice 2.5 not-worth-it. The summarizeJsonDiff one-line Changes column on the table row already provides at-a-glance per-row scanning; the popup's job is comprehensive detail.

---

## Slice 3 — BOMs

Apply Slice 2 pattern across:

| Proc | Description prose shape |
|---|---|
| `Bom_Create` | `<PartNumber> · BOM v1 (Draft) · Created` (verb-form on initial create) |
| `Bom_CreateNewVersion` | `<PartNumber> · BOM v<N> (Draft) · Created from v<N-1>; <K> lines` |
| `Bom_SaveDraft` | `<PartNumber> · BOM v<N> (Draft) · <ActionParts>; <K> lines` |
| `Bom_Publish` | `<PartNumber> · BOM v<N> · Published (deprecated v<N-1>); <K> lines; effective <date>` |
| `Bom_Deprecate` | `<PartNumber> · BOM v<N> · Deprecated` |
| `Bom_DiscardDraft` | `<PartNumber> · BOM v<N> (Draft) · Discarded; <K> lines discarded` |

OldValue/NewValue JSON resolves `ItemId` → `{Id, PartNumber, Description}` for each BOM line's child reference, and resolves `UomId` if applicable. Tests in `010_Bom_crud.sql` and siblings get the same 4 new assertion-shape tests as Slice 2.

Effort: 1 session. ~6 procs × ~80 lines of change each.

## Slice 4 — Routes

Same as Slice 3 but for `RouteTemplate_Create`, `_CreateNewVersion`, `_SaveAll`, `_Publish`, `_Deprecate`, `_DiscardDraft`. Activity prose verbs include `+Step` / `-Step` / `~Step` / `Reordered`. Resolves `OperationTemplateId` references in steps.

Effort: 1 session.

## Slice 5 — Item core (Identity + Container Config)

| Proc | Description prose shape |
|---|---|
| `Item_Create` | `<PartNumber> — <Description> (<ItemTypeName>) · Created` |
| `Item_Update` | `<PartNumber> · Identity · <field-diff list>` |
| `Item_Deprecate` | `<PartNumber> — <Description> · Deprecated` |
| `ContainerConfig_Create` | `<PartNumber> · Container Config · Created; <key params>` |
| `ContainerConfig_Update` | `<PartNumber> · Container Config · <field-diff list>` |

Effort: 1 session.

## Slice 6 — Plant Hierarchy

| Proc | Description prose shape |
|---|---|
| `Location_Create` | `Location <Code> — <Name> (<TierDef>) · Created under <ParentCode> — <ParentName>` |
| `Location_Update` | `Location <Code> · <field-diff list>` |
| `Location_Deprecate` | `Location <Code> — <Name> · Deprecated` |
| `Location_MoveSortOrderUp/Down` | `Location <Code> · Reordered from #<old> to #<new>` |
| `LocationAttributeValue_Set` | `Location <Code> · Set attribute <Name> = "<value>" (was "<old>")` |

Effort: 1 session.

## Slice 7 — LocationTypeEditor

| Proc | Description prose shape |
|---|---|
| `LocationTypeDefinition_SaveAll` | `Location Type Definition "<Name>" (<Tier> tier) · <ActionParts>` (attribute add/remove/update) |
| `LocationTypeDefinition_Deprecate` | `Location Type Definition "<Name>" · Deprecated (cascade: <N> attributes deprecated)` |

Effort: 1 session.

## Slice 8 — Downtime + Defect Codes

| Proc | Description prose shape |
|---|---|
| `DowntimeReasonCode_Create` | `Downtime Code <Code> — <Name> (<AreaName>) · Created` |
| `DowntimeReasonCode_Update` | `Downtime Code <Code> · <field-diff list>` |
| `DowntimeReasonCode_Deprecate` | `Downtime Code <Code> · Deprecated` |
| `DefectCode_Create` | `Defect Code <Code> — <Name> (<AreaName>) · Created` |
| `DefectCode_Update` | `Defect Code <Code> · <field-diff list>` |
| `DefectCode_Deprecate` | `Defect Code <Code> · Deprecated` |

Effort: 1 session.

---

## Spec Self-Review Coverage

| Spec section | Plan task(s) |
|---|---|
| §3 Description format (subject, category, action) | Tasks 2.2, 2.3 (Eligibility reference) |
| §3.2 Verb/symbol vocabulary | Tasks 2.3 (Eligibility), Slices 3-8 catalog |
| §3.3 Field-diff notation | Task 2.3 |
| §3.4 Truncation + overflow rules | Task 1.2 (`ufn_TruncateActivity`), Task 2.3 |
| §4 Resolved-FK JSON convention | Task 2.4 |
| §5 Per-category Description catalog | Slices 3-8 task tables |
| §6.1 AuditLog table column changes | Task 1.4 |
| §6.2 ConfigChangeDetail popup fix | Task 1.5 |
| §6.3 Auditor user flow | Verified at Task 2.8 smoke |
| §7 Refactor approach (per-proc) | All slices |
| §8 Backport plan | Slice ordering |
| §9 Open questions | Decided via inline conventions in this plan |

---

## Per-slice acceptance criteria

Each slice (1-8) must meet:

1. **All existing SQL tests pass** for the touched procs.
2. **At least one new test per proc** asserts on the SUBJECT · CATEGORY · ACTION shape (LIKE pattern against Description).
3. **At least one new test per proc** asserts that `NewValue` JSON contains the resolved-FK sub-objects (not bare IDs).
4. **Manual smoke**: trigger a mutation in the UI, open `/audit`, verify the row's Activity column reads as designed and the popup's JSON shows resolved names.
5. **`PROJECT_STATUS.md` updated** Recently-closed entry per slice.
