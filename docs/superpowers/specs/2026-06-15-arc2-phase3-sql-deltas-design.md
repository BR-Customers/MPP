# Arc 2 Phase 3 — SQL Deltas (Die-Cast Front-End Dependencies) — Design

**Date:** 2026-06-15
**Status:** Draft for review
**Author:** Blue Ridge Automation
**Scope:** Three small, already-decided follow-on SQL changes that the **Phase 3 die-cast front-end** depends on. The Phase 3 SQL foundation (migration `0022` + the `ProductionEvent_Record` / `RejectEvent_Record` / `ToolCavity_ListActiveByTool` procs + the `0022_PlantFloor_DieCast` test suite) is **already built and committed** on `jacques/working`; this spec extends it. The Perspective layer (FieldInputRow, checkpoint-history panel, manual-cavity entry UI) is a **separate front-end spec**.

This document is a design specification only — the human reviews and commits. No SQL is built here.

---

## 1. Source of truth

- Predecessor: `docs/superpowers/specs/2026-06-12-arc2-phase3-die-cast-sql-design.md` (the foundation this extends — its D1/D2/D3 decisions remain in force).
- Phased plan: `MPP_MES_PHASED_PLAN_PLANT_FLOOR.md` § "Phase 3 — Die Cast Operator Station".
- Data model: `MPP_MES_DATA_MODEL.md` — `Parts.DataCollectionField`, `Parts.OperationTemplateField`, `Workorder.ProductionEvent`, `Lots.Lot`.
- Conventions: `CLAUDE.md` (SQL design; FDS-11-011; audit-readability; code-table-backed enums; migration/versioning), `sql_best_practices_mes.md`, `sql_version_control_guide.md`.
- Open items: D2 (manual cavity, no active `ToolCavity`) and D4 (pre-printed-LTT identity) per Phase-3 plant-floor register.

---

## 2. Reconciliation to shipped SQL (what is actually on disk)

Verified against the working tree before writing this spec. Several prompt assumptions are corrected here against the **as-built** state.

| Asset | As-built fact (verified) | Consequence for this spec |
|---|---|---|
| `Parts.DataCollectionField` (migration `0004`, lines 314–333) | Plain table — `Id, Code, Name, Description, CreatedAt, DeprecatedAt`. **No `DataType` column.** Seven seeded rows. | Change 1 adds the column. |
| Seeded `DataCollectionField` codes | `1 MaterialVerification, 2 SerialNumber, 3 DieInfo, 4 CavityInfo, 5 Weight, 6 GoodCount, 7 BadCount`. **There is NO `ShotCount`, `Good`, or `Bad` field.** | The prompt's "DieInfo/CavityInfo=String, Weight=Decimal, Good/Bad/ShotCount=Integer" maps to the real codes as: `DieInfo`/`CavityInfo` → String, `Weight` → Decimal, `GoodCount`/`BadCount` → Integer. `MaterialVerification` → Boolean, `SerialNumber` → String. ShotCount/ScrapCount are **promoted typed columns on `ProductionEvent`**, not `DataCollectionField` rows, so they need no DataType seed. |
| DieCastShot `OperationTemplateField` set (seed `022_seed_die_cast_operation_template.sql`) | Binds `DieInfo, CavityInfo, Weight, GoodCount, BadCount`. | These five are the FE FieldInputRow set — all must carry a DataType after Change 1. |
| Existing datatype "code table" | `Tools.ToolAttributeDefinition.DataType NVARCHAR(20)` with `CHECK (DataType IN ('String','Integer','Decimal','Boolean','Date'))` (migration `0010`, lines 160–166). **This is a CHECK-constrained string column, NOT an FK code table.** | See Decision **DT-1** — do NOT reuse the CHECK column; create a real FK code table. |
| `Workorder.ProductionEvent` (migration `0020`) | `Id, LotId, OperationTemplateId, WorkOrderOperationId NULL, EventAt, ShotCount NULL, ScrapCount NULL, ScrapSourceId NULL, WeightValue NULL, WeightUomId NULL, AppUserId, TerminalLocationId NULL, Remarks NULL`. PK NONCLUSTERED `(Id)`; clustered `(LotId, EventAt)` partition-aligned. | Change 2 reads it; no schema change. |
| `Workorder.ProductionEventValue` | `Id, ProductionEventId →CASCADE, DataCollectionFieldId, Value NVARCHAR(255), NumericValue NULL, UomId NULL, CreatedAt`; `UNIQUE(ProductionEventId, DataCollectionFieldId)`. | Change 2 may shred these into the result. |
| `Lots.Lot` (migration `0020`, lines 529–559) | Has `ToolCavityId BIGINT NULL → Tools.ToolCavity(Id)` **and** a legacy `CavityNumber NVARCHAR(50) NULL` free-text column (and `DieNumber NVARCHAR(50) NULL`). `CONSTRAINT UQ_Lot_LotName UNIQUE (LotName)`. | See Decision **D2** — reuse the existing `CavityNumber` legacy column for manual cavity; reuse `UQ_Lot_LotName` for the `@LotName` collision check. |
| `Lots.Lot_Create` (`R__Lots_Lot_Create.sql`) | Mints `LotName` inline (mirror of `IdentifierSequence_Next 'Lot'`) **inside** the transaction; all validations before `BEGIN TRANSACTION`; single result row `Status, Message, NewId, MintedLotName`. | Change 3 extends it additively. |
| Next migration number | Disk has versioned through `0022`. | This spec's migration is **`0023`**. |

No tables are added by this spec. One column is added (`DataCollectionField.DataType...`), one code table is created, one read proc is added, and one existing proc gains two optional params.

---

## 3. Change 1 — `DataType` on `Parts.DataCollectionField` (FE type-aware rendering)

**Requirement (FDS-04-NNN, code-table-backed enum rule):** the die-cast FieldInputRow SHALL render the correct widget (text / integer spinner / decimal / checkbox / date picker) per field. The FE needs a server-supplied data type per `DataCollectionField`. This SHALL be code-table-backed with an FK — no magic strings (`CLAUDE.md` § SQL design: "All enum/status columns code-table backed with FK — no magic integers, no free-text").

### 3.1 New code table `Parts.DataCollectionFieldDataType`

Created in migration `0023`, idempotent guard, ASCII-only seeds.

```sql
CREATE TABLE Parts.DataCollectionFieldDataType (
    Id           BIGINT        NOT NULL IDENTITY(1,1) PRIMARY KEY,
    Code         NVARCHAR(20)  NOT NULL,
    Name         NVARCHAR(50)  NOT NULL,
    Description  NVARCHAR(200) NULL,
    SortOrder    INT           NOT NULL DEFAULT 0,
    CreatedAt    DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_DataCollectionFieldDataType_Code UNIQUE (Code)
);
```

Seed rows (manual `Id`, `SET IDENTITY_INSERT`, idempotent on `Code` / `Id`):

| Id | Code | Name | SortOrder |
|----|------|------|-----------|
| 1 | `String` | Text | 1 |
| 2 | `Integer` | Whole Number | 2 |
| 3 | `Decimal` | Decimal Number | 3 |
| 4 | `Boolean` | Yes / No | 4 |
| 5 | `Date` | Date | 5 |

(The five codes mirror the legacy `Tools.ToolAttributeDefinition.DataType` CHECK domain exactly, so a future migration can repoint that CHECK column at this FK without a value remap — see DT-1.)

### 3.2 Add the FK column to `Parts.DataCollectionField`

**Decision DT-2 — nullable-then-backfill-then-NOT-NULL, in one migration.** Add the column NULL, backfill every existing row, then `ALTER ... ALTER COLUMN ... NOT NULL` + add the FK. Justification: a `NOT NULL DEFAULT` would silently stamp every existing and future row `String`, masking a missing classification; explicit backfill forces every shipped row to be deliberately typed and makes the migration self-documenting. The column ends NOT NULL so the FE never receives an untyped field.

```sql
ALTER TABLE Parts.DataCollectionField
    ADD DataTypeId BIGINT NULL;     -- temporarily nullable for backfill
GO
-- backfill (see 3.3)
GO
ALTER TABLE Parts.DataCollectionField
    ALTER COLUMN DataTypeId BIGINT NOT NULL;
GO
ALTER TABLE Parts.DataCollectionField
    ADD CONSTRAINT FK_DataCollectionField_DataType
        FOREIGN KEY (DataTypeId) REFERENCES Parts.DataCollectionFieldDataType(Id);
GO
```

Idempotency: each step guarded (`IF COL_LENGTH(...) IS NULL`, `IF NOT EXISTS (... sys.foreign_keys ...)`), so a re-apply is a no-op.

### 3.3 Backfill the seven shipped rows (by `Code`, resolved to FK Id)

| `DataCollectionField.Code` | DataType |
|---|---|
| `MaterialVerification` | `Boolean` |
| `SerialNumber` | `String` |
| `DieInfo` | `String` |
| `CavityInfo` | `String` |
| `Weight` | `Decimal` |
| `GoodCount` | `Integer` |
| `BadCount` | `Integer` |

Backfill resolves each `DataType` by `Code` against `Parts.DataCollectionFieldDataType` (no hard-coded Ids in the UPDATE) and updates by `DataCollectionField.Code` (stable natural key). A defensive `IF EXISTS (... DataTypeId IS NULL)` guard after backfill RAISERRORs if any row stayed null — the `ALTER ... NOT NULL` would otherwise fail with an opaque message.

> **DT-3 — new-field default.** This is schema only; `DataCollectionField_Create` (and the FE add-field form) gains a required `@DataTypeId` in a *future* config-tool change. That proc is **out of scope** here — Change 1 only adds the column + backfills existing rows so the read proc can surface a type. Flag for the config-tool backlog: `DataCollectionField_Create`/`_Update` need a `@DataTypeId` param before engineering can add a new field through the UI. (Until then, new fields can only be added by SQL, which is the status quo.)

### 3.4 Extend `Parts.DataCollectionField_List` (repeatable proc)

`R__Parts_DataCollectionField_List.sql` — bump to version 3.0. Join the new code table and return `DataTypeId`, `DataTypeCode`, `DataTypeName` so the FieldInputRow picks its widget. Read proc — single result set, no status row, no OUTPUT params (FDS-11-011). Ordering unchanged (`ORDER BY Code`).

```sql
CREATE OR ALTER PROCEDURE Parts.DataCollectionField_List
    @IncludeDeprecated BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        dcf.Id, dcf.Code, dcf.Name, dcf.Description,
        dcf.DataTypeId,
        dt.Code AS DataTypeCode,
        dt.Name AS DataTypeName,
        dcf.CreatedAt, dcf.DeprecatedAt
    FROM Parts.DataCollectionField dcf
    INNER JOIN Parts.DataCollectionFieldDataType dt ON dt.Id = dcf.DataTypeId
    WHERE (@IncludeDeprecated = 1 OR dcf.DeprecatedAt IS NULL)
    ORDER BY dcf.Code;
END;
GO
```

`INNER JOIN` is safe because `DataTypeId` is NOT NULL with an FK after Change 1 — every row resolves. The result-set shape is additive (existing columns retained in the same positions, three appended), so the existing `DataCollectionField_Get` and any current binding stay compatible; only the new columns are net-new.

> **Note on `DataCollectionField_Get` / `_Create` / `_Update`:** `_Get` MAY optionally be extended the same way for symmetry but is **not required** by the FE (the list feeds FieldInputRow). `_Create`/`_Update` extension is deferred (DT-3). This spec changes only `_List`.

---

## 4. Change 2 — `Workorder.ProductionEvent_ListByLot @LotId` (read proc)

**Requirement (FDS-11-011; FE "last checkpoint shots" hint + checkpoint history):** a thin READ proc returning a LOT's production checkpoints ordered chronologically. Feeds two FE surfaces: (a) the "last checkpoint shots/scrap" hint pre-filling the next entry, (b) the checkpoint-history panel.

New repeatable proc `R__Workorder_ProductionEvent_ListByLot.sql`. **No status row, single result set, no OUTPUT params.** Empty result set = LOT has no checkpoints (no invented 404 — FDS-11-011 read-proc rule). No mutation, no transaction, no audit.

### 4.1 Signature + body

```sql
CREATE OR ALTER PROCEDURE Workorder.ProductionEvent_ListByLot
    @LotId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        pe.Id,
        pe.LotId,
        pe.OperationTemplateId,
        ot.Code            AS OperationTemplateCode,
        ot.Name            AS OperationTemplateName,
        pe.WorkOrderOperationId,
        pe.EventAt,
        pe.ShotCount,
        pe.ScrapCount,
        pe.ScrapSourceId,
        pe.WeightValue,
        pe.WeightUomId,
        u.Code             AS WeightUomCode,           -- resolved UoM symbol for display
        pe.AppUserId,
        au.DisplayName     AS ByUser,                  -- resolved actor for the history row
        pe.TerminalLocationId,
        pe.Remarks
    FROM Workorder.ProductionEvent pe
    INNER JOIN Parts.OperationTemplate ot ON ot.Id = pe.OperationTemplateId
    LEFT  JOIN Parts.Uom u                ON u.Id  = pe.WeightUomId
    LEFT  JOIN Location.AppUser au        ON au.Id = pe.AppUserId
    WHERE pe.LotId = @LotId
    ORDER BY pe.EventAt ASC, pe.Id ASC;     -- chronological; Id tiebreak for same-instant rows
END;
GO
```

- **Ordering:** `EventAt ASC, Id ASC`. Chronological matches the history-panel reading order; `Id` tiebreaks rows recorded in the same millisecond (the clustered key `(LotId, EventAt)` makes this range scan efficient). The FE derives "last checkpoint" as the last row (or issues a `TOP 1 ... ORDER BY EventAt DESC` — see 4.2).
- **Resolved-name joins** (`OperationTemplateCode/Name`, `WeightUomCode`, `ByUser`) so the FE renders without secondary lookups, consistent with the resolved-FK convention used elsewhere. `LEFT JOIN` on UoM + AppUser tolerates NULL `WeightUomId` (no weight captured); `AppUserId` is NOT NULL on the table but `LEFT JOIN` is defensive.
- **Display-name column:** uses whatever the canonical actor display column is on `Location.AppUser` (the proc author SHALL match the column the audit-display procs already use — `DisplayName` if present, else the established initials/name expression; do **not** invent a new one).
- **Timezone:** `EventAt` is returned as stored UTC (raw), matching the other plant-floor read procs; the FE formats. (The audit *browser* procs convert UTC→ET, but the plant-floor checkpoint history mirrors `ProductionEvent_Record`'s UTC storage; no conversion here. Flag if MPP wants ET — trivial `AT TIME ZONE` add, same pattern as the audit procs.)

### 4.2 Shredded `ProductionEventValue` rows — Decision PE-1

**Recommendation: do NOT bundle the shredded `ProductionEventValue` child rows into this proc's result.** FDS-11-011 mandates one result set per proc; returning header rows + value rows in one SELECT would require a denormalized cross-join (value columns pivoted, fragile) or a second result set (forbidden). Two clean options:

- **PE-1a (recommended):** this proc returns the **header** rows only (the columns above). If/when the FE needs the per-checkpoint extra `DataCollectionField` values, add a **sibling** read proc `Workorder.ProductionEventValue_ListByEvent @ProductionEventId` (one result set, value rows with resolved `DataCollectionField` Code/Name + DataType). The promoted columns (`ShotCount`, `ScrapCount`, `WeightValue`) already cover the "last checkpoint shots" hint and the history grid — the shredded values are detail-drill, not list-grid data.
- **PE-1b:** embed the values as a JSON column per header row (`FOR JSON PATH` correlated subquery → `ValuesJson NVARCHAR(MAX)`). Single result set, FDS-11-011-clean, FE parses JSON. Acceptable if the FE wants values inline without a second round-trip.

**This spec specifies PE-1a** (header-only `ProductionEvent_ListByLot`); the sibling value proc is listed as a thin optional follow-on, built only if the FE history panel needs to show extra fields. The "last checkpoint shots" hint needs only the promoted columns, which PE-1a returns.

---

## 5. Change 3 — `Lot_Create` gains `@LotName` (D4) + the no-cavity path (D2)

Two **additive, backward-compatible** parameter additions to the shipped `Lots.Lot_Create` (`R__Lots_Lot_Create.sql`). Existing callers and the entire `0021`/`0022` test suite pass these as NULL (the default) and behave **byte-for-byte identically** to today. The proc keeps its INSERT-EXEC discipline (all rejecting validations before `BEGIN TRANSACTION`; `CATCH` is the only ROLLBACK site), its inline mint, and its single result row `Status, Message, NewId, MintedLotName`.

### 5.1 New signature (additions in **bold**)

```text
Lots.Lot_Create
    @ItemId             BIGINT,
    @LotOriginTypeId    BIGINT,
    @CurrentLocationId  BIGINT,
    @PieceCount         INT,
    @Weight             DECIMAL(12,4) = NULL,
    @WeightUomId        BIGINT        = NULL,
    @ToolId             BIGINT        = NULL,
    @ToolCavityId       BIGINT        = NULL,
    @VendorLotNumber    NVARCHAR(100) = NULL,
    @MinSerialNumber    INT           = NULL,
    @MaxSerialNumber    INT           = NULL,
    @AppUserId          BIGINT,
    @TerminalLocationId BIGINT        = NULL,
    **@LotName            NVARCHAR(50)  = NULL,   -- D4: caller-supplied identity; NULL = mint server-side (today's behavior)**
    **@CavityNote         NVARCHAR(50)  = NULL    -- D2: free-text cavity when no active ToolCavity exists; stored in legacy Lot.CavityNumber**
  → Status, Message, NewId, MintedLotName
```

New params are appended **after** all existing params and both default NULL, so every existing positional and named call is unaffected (SQL Server binds omitted trailing optional params to their defaults).

### 5.2 D4 — `@LotName` behavior (pre-printed-LTT forward-compat)

**Decision D4 — caller-supplied LotName, validated, with mint as the default.**

- **`@LotName IS NULL` (every existing caller/test):** mint server-side **exactly as today** via the existing inline `IdentifierSequence 'Lot'` block inside the transaction. `MintedLotName` is returned as today. Zero behavioral change.
- **`@LotName` supplied (non-NULL, non-blank):** use the supplied value as the LOT identity; **do NOT** advance the `IdentifierSequence` counter (the pre-printed LTT carries its own identity — burning a counter would desync). Validate per below. `MintedLotName` returns the **supplied** value (the column already means "the name the LOT ended up with").

**Validation (before `BEGIN TRANSACTION`, per the INSERT-EXEC/Msg-3915 rule — early SELECT-return + `Audit_LogFailure`):**

1. Trim; reject blank-after-trim with `'LotName cannot be blank.'` (a supplied-but-empty string is a caller error, distinct from NULL=mint).
2. **Uniqueness pre-check** against `UQ_Lot_LotName`: `IF EXISTS (SELECT 1 FROM Lots.Lot WHERE LotName = @LotName)` → Status=0, `'LOT name ''<name>'' already exists.'` (clear collision message, no exception). This is the friendly path; the unique constraint itself remains the concurrency backstop — a race that slips past the pre-check surfaces as a 2627/2601 in the `CATCH`, which already produces a Status=0 row. The pre-check makes the *common* collision a clean message rather than a raw constraint error.

**Mutation branch:** the inline mint block runs only on the NULL path. Refactor so `@MintedLotName` is set either (a) to `@LotName` (supplied path — skip the sequence read/update entirely) or (b) by the existing inline mint (NULL path). The `INSERT INTO Lots.Lot (... LotName ...)` is unchanged — it already inserts `@MintedLotName`. Keep the comment block explaining why the supplied path does not touch `IdentifierSequence`.

**Audit:** the existing `Description` already embeds `@MintedLotName`; on the supplied path it naturally reads the caller-supplied name. Add a parenthetical only if it adds clarity (`MAY`); the resolved-FK New JSON is unchanged.

### 5.3 D2 — manual cavity when no active `ToolCavity` (recommended approach)

**Context:** the shipped die-cast branch (lines 183–253 of `R__Lots_Lot_Create.sql`) requires a valid, Active `ToolCavityId` belonging to the mounted Tool **whenever the Cell has an active ToolAssignment**. The die-cast FE needs to handle the real-world case where the operator must enter a cavity manually because **no active `ToolCavity` row exists** for the mounted tool (cavity config not yet loaded, or a one-off), **or no tool is mounted** at all.

**Decision D2 — recommended: keep the validated path intact; add a documented free-text fallback via the existing legacy `Lot.CavityNumber` column, gated on `@ToolCavityId IS NULL`.**

Rationale for choosing the free-text column over relaxing the FK check:
- `Lots.Lot` already carries `CavityNumber NVARCHAR(50) NULL` (and `DieNumber`), explicitly retained as "legacy, superseded by ToolCavityId" — it is the natural home for a cavity value that has no `ToolCavity` row. No schema change needed.
- It keeps the **strict, FK-validated path the default**: when a real `ToolCavityId` is supplied it is still validated against the mounted tool + Active status, exactly as today. Genealogy/traceability integrity for the normal case is unchanged.
- It makes the manual entry **auditable and distinguishable**: `ToolCavityId IS NULL` + `CavityNumber = '<free text>'` is unambiguously the override case; a populated `ToolCavityId` is the validated case. No relaxation of the existing constraint semantics.

**Behavior:**

| Inputs | Branch | Stored |
|---|---|---|
| Cell has active tool, `@ToolCavityId` supplied | Existing validated path (unchanged) | `ToolId`, `ToolCavityId`; `CavityNumber` NULL |
| Cell has active tool, `@ToolCavityId` NULL, `@CavityNote` supplied | **New D2 fallback** | `ToolId`, `ToolCavityId` NULL, `CavityNumber = @CavityNote` |
| Cell has active tool, `@ToolCavityId` NULL, `@CavityNote` NULL | **Reject** (unchanged spirit) | — |
| No active tool on Cell (non-die-cast origin) | Existing path (Tool/Cavity NULL allowed) | as today |

**Validation changes (all before `BEGIN TRANSACTION`):** in the `@CellHasActiveTool = 1` branch, replace the unconditional "Tool and Cavity required" rejection with:
- Require `@ToolId` (a die-cast LOT still records *which tool* — `@ToolId` stays mandatory in the die-cast branch).
- If `@ToolCavityId IS NULL`: require `@CavityNote` non-blank, else reject `'Die-cast-origin LOT requires a Cavity (select a configured cavity or enter one manually) (FDS-05-034).'` On the `@CavityNote` path, **skip** the three cavity-FK validations (belongs-to-tool / Active-status) — there is no row to validate; the free-text note is the recorded value.
- If `@ToolCavityId` supplied: run the existing belongs-to-tool + Active-status checks unchanged.

**Insert change:** add `CavityNumber` to the column/value list — set to `@CavityNote` on the fallback path, NULL otherwise (i.e. `CAST(CASE WHEN @ToolCavityId IS NULL THEN @CavityNote ELSE NULL END AS NVARCHAR(50))` precomputed into a local, since `EXEC`/insert values stay literal-or-`@var` per the SP template).

**Audit:** the existing `@ToolSuffix` prose resolves `Cavity` from `ToolCavity.CavityNumber` when `ToolCavityId` is set; extend it to fall back to the free-text `@CavityNote` (e.g. `Cavity <CavityNote> (manual)`) when `ToolCavityId IS NULL`, so the audit line still names the cavity.

> **Alternative considered (NOT recommended): relax the "cavity belongs to active tool" check under a documented condition** (allow `@ToolCavityId` to be NULL silently). Rejected because it loses the explicit manual-vs-validated distinction and leaves no recorded cavity value at all — worse traceability for a Honda genealogy system. The free-text column captures *something* auditable; a silent NULL captures nothing.

> **Flag for review:** D2 introduces `@CavityNote`. Confirm the FE will pass the manual string here (not into `@VendorLotNumber` or a misused field), and that recording the cavity in the legacy `CavityNumber` column (rather than a new typed column) is acceptable for the genealogy/reporting consumers. If MPP wants the manual cavity surfaced identically to validated cavities in reports, a future report view can `COALESCE(tc.CavityNumber, l.CavityNumber)`.

---

## 6. Migration `0023_arc2_phase3_sql_deltas.sql`

Versioned migration; `SchemaVersion` row; idempotent guards on every DDL/seed step; ASCII-only seed strings (byte-scan before applying — `feedback_ascii_only_seed_data`). Contents:

1. `CREATE TABLE Parts.DataCollectionFieldDataType` (guarded `IF OBJECT_ID(...) IS NULL`).
2. Seed the 5 datatype rows (`SET IDENTITY_INSERT`; guard each on `Id`/`Code`).
3. `ALTER TABLE Parts.DataCollectionField ADD DataTypeId BIGINT NULL` (guard `IF COL_LENGTH(...) IS NULL`).
4. Backfill the 7 rows by `Code` (resolve FK by `Code`).
5. Defensive null check → RAISERROR if any row unclassified.
6. `ALTER COLUMN DataTypeId ... NOT NULL` + add FK constraint (guarded).
7. `INSERT INTO dbo.SchemaVersion` (`IF NOT EXISTS` on `MigrationId`).

`0023` is **schema + seed only**. The three procs (`DataCollectionField_List` v3.0, `ProductionEvent_ListByLot` new, `Lot_Create` extended) are **repeatable** migrations (`R__*.sql`), re-run on every deploy after the versioned migrations — consistent with the existing proc-as-repeatable topology and `sql_version_control_guide.md`.

**Apply order constraint:** `R__Workorder_ProductionEvent_ListByLot.sql` and the `DataCollectionField_List` rewrite must apply **after** `0023` (they reference the new column/joins). The standard pipeline (all versioned, then all repeatable) satisfies this. The `Lot_Create` repeatable has no dependency on `0023` (its changes are param-only + the existing `CavityNumber` column) but lands in the same delivery.

---

## 7. Conventions applied

- **FDS-11-011:** read procs (`DataCollectionField_List`, `ProductionEvent_ListByLot`) — single result set, no OUTPUT, empty = not-found. `Lot_Create` keeps `Status/Message/NewId/MintedLotName` single-row contract.
- **Code-table-backed enums:** `DataType` is an FK to a real code table, not a CHECK string (DT-1).
- **Audit-readable Description** (`SUBJECT · CATEGORY · ACTION`, resolved-FK JSON) — only `Lot_Create` mutates; its existing audit block is preserved and lightly extended for the manual-cavity prose.
- **INSERT-EXEC / Msg-3915 discipline:** all new `Lot_Create` validations (`@LotName` blank/collision, `@CavityNote` required) are added **before** `BEGIN TRANSACTION`; `CATCH` stays the only ROLLBACK site.
- **SP template:** `EXEC`/insert values are literals or `@variables` (manual-cavity value precomputed into a local; no inline `CASE` in the `VALUES`/`EXEC`).
- **ASCII-only seeds**; idempotent guards; `SchemaVersion` row.
- **NVARCHAR / DATETIME2(3) / DECIMAL / BIGINT IDENTITY** throughout.

---

## 8. Test plan

New/extended files under `sql/tests/`. Full suite (currently **1520**) SHALL stay green; INSERT-EXEC into temp tables matching each SELECT shape; FK-safe teardown (`feedback_arc2_lot_test_teardown_fk_order`: closure → genealogy → ProductionEventValue → ProductionEvent → LotEventLog/Movement/StatusHistory → Lot; audit route 'Lot'→LotEventLog, Workorder→OperationLog).

### 8.1 Change 1 — DataType (`sql/tests/0023_*` or extend `0004`/parts field tests)

| Assertion |
|---|
| `Parts.DataCollectionFieldDataType` has the 5 expected codes (String/Integer/Decimal/Boolean/Date). |
| Every shipped `DataCollectionField` row has a non-NULL `DataTypeId` after backfill (no orphans). |
| Backfill correctness: `Weight`→Decimal, `GoodCount`/`BadCount`→Integer, `DieInfo`/`CavityInfo`/`SerialNumber`→String, `MaterialVerification`→Boolean. |
| FK rejects an invalid `DataTypeId` (negative test on a manual insert). |
| `DataCollectionField_List` returns `DataTypeCode`/`DataTypeName` columns, populated, for the DieCastShot field set. |
| `DataCollectionField_List` row count / ordering unchanged vs pre-change (active rows by Code). |
| `@IncludeDeprecated=1` still includes deprecated rows (regression). |

### 8.2 Change 2 — `ProductionEvent_ListByLot`

| Assertion |
|---|
| Empty: a LOT with no checkpoints → 0 rows (no error, no status row). |
| Ordering: three checkpoints at increasing `EventAt` return in chronological `EventAt ASC` order. |
| Same-instant tiebreak: two rows with equal `EventAt` order by `Id ASC`. |
| Resolved columns: `OperationTemplateCode/Name`, `ByUser`, `WeightUomCode` populated (and NULL-safe when `WeightUomId` NULL). |
| Promoted columns (`ShotCount`/`ScrapCount`/`WeightValue`/`EventAt`) match what `ProductionEvent_Record` wrote. |
| Scoping: a checkpoint on LOT A is not returned for LOT B. |

### 8.3 Change 3 — `Lot_Create` (extend `0021`/Lot tests; do not regress existing)

| Assertion |
|---|
| `@LotName NULL` (default): mints exactly as before — `MintedLotName` non-null, `IdentifierSequence 'Lot'` advanced by 1 (byte-for-byte legacy behavior; this is the critical regression guard). |
| `@LotName` supplied: LOT stored with the supplied name; `MintedLotName` = supplied value; `IdentifierSequence 'Lot'` **NOT** advanced. |
| `@LotName` duplicate: Status=0, clear collision message; no row inserted; no sequence burn. |
| `@LotName` blank string: Status=0, blank message. |
| **D2 no-cavity, manual:** Cell has active tool, `@ToolCavityId` NULL + `@CavityNote='C3'` → Status=1; `Lot.ToolCavityId` NULL, `Lot.CavityNumber='C3'`, `Lot.ToolId` set. |
| **D2 reject:** active tool, `@ToolCavityId` NULL + `@CavityNote` NULL → Status=0 (cavity required message). |
| **D2 validated path unchanged:** active tool + valid `@ToolCavityId` → Status=1, `CavityNumber` NULL (regression: existing die-cast path intact). |
| Non-die-cast origin (no active tool): Tool/Cavity NULL still allowed (regression). |
| Audit: manual-cavity LOT's `OperationLog`/`LotEventLog` Description names the manual cavity. |

Existing `0021`/`0022` LOT tests SHALL pass **unmodified** (proof the additions are backward-compatible). Target ~30–40 net-new assertions; combined suite ≥ 1520 and green.

---

## 9. Design decisions (confirm at review)

- **DT-1 — create a real FK code table, do NOT reuse the `ToolAttributeDefinition.DataType` CHECK column.** The only existing "datatype" is a CHECK-constrained `NVARCHAR(20)` on `Tools.ToolAttributeDefinition`, which violates the project's "code-table-backed FK, no magic strings" rule and lives in a different schema (`Tools`, tool-attribute semantics) from `Parts.DataCollectionField`. New table `Parts.DataCollectionFieldDataType` with the **same five codes**, so a later migration can repoint the legacy CHECK column at the FK without a value remap. **Recommendation: create.**
- **DT-2 — nullable→backfill→NOT-NULL in one migration** (not `NOT NULL DEFAULT`), so every shipped row is deliberately typed and a missed classification fails loudly. **Recommendation: as specified.**
- **DT-3 — `DataCollectionField_Create`/`_Update` need a `@DataTypeId` param** before engineering can add a field via UI; deferred to a config-tool change (out of scope here). **Flag for backlog.**
- **PE-1 — `ProductionEvent_ListByLot` returns header rows only** (PE-1a); shredded `ProductionEventValue` rows, if needed, come from a separate sibling proc (FDS-11-011 one-result-set rule). The promoted columns cover the "last checkpoint shots" hint + history grid. **Recommendation: header-only.**
- **D4 — `@LotName` optional, validated, mint-by-default.** NULL = today's server mint (no behavioral change, no sequence change); supplied = use it, validate against `UQ_Lot_LotName`, do **not** burn the counter. **Recommendation: as specified.**
- **D2 — manual cavity stored in the existing legacy `Lot.CavityNumber` column, gated on `@ToolCavityId IS NULL` via a new `@CavityNote` param; validated path kept strict and default.** Chosen over silently relaxing the FK check because it preserves the validated-vs-manual distinction and records an auditable cavity value for genealogy. **Recommendation: free-text fallback (as specified).** Alternative (relax FK silently) documented and rejected.

Open ambiguities for Jacques:
- D2 storage column: confirm legacy `Lot.CavityNumber` is acceptable for the manual cavity (vs. a new typed column) for downstream genealogy/report consumers.
- PE-1: confirm header-only is sufficient for the FE history panel, or whether the FE wants extra `DataCollectionField` values inline (→ build the sibling value proc or PE-1b JSON).
- `ProductionEvent_ListByLot.EventAt` returned as raw UTC (matching `ProductionEvent_Record` storage); confirm the FE formats, or request ET conversion (trivial add).
- The `Location.AppUser` display column for `ByUser` — match whatever the audit-display procs use.

---

## 10. Out of scope

- The Perspective layer: FieldInputRow widget selection, checkpoint-history panel, the manual-cavity entry UI, Named Queries wrapping these procs (built with the front-end spec; the extended `DataCollectionField_List` + new `ProductionEvent_ListByLot` are reads — their NQs are `type:"Query"`-agnostic reads, but `Lot_Create` remains a status-row proc whose NQ needs `attributes.type:"Query"`).
- `DataCollectionField_Create`/`_Update` `@DataTypeId` extension (config-tool backlog, DT-3).
- The sibling `ProductionEventValue_ListByEvent` proc (build only if PE-1a proves insufficient).
- PLC/TOPServer cycle reading; ZPL/printing.
- Any change to `ProductionEvent_Record` / `RejectEvent_Record` / `ToolCavity_ListActiveByTool` (shipped, unchanged).

---

## 11. Done when

- Migration `0023` applied: `Parts.DataCollectionFieldDataType` table + 5 seeds; `DataCollectionField.DataTypeId` column NOT NULL + FK; all 7 rows backfilled; `SchemaVersion` row present; re-apply is a no-op.
- `Parts.DataCollectionField_List` (v3.0) returns `DataTypeId`/`DataTypeCode`/`DataTypeName`.
- `Workorder.ProductionEvent_ListByLot` delivered (header-only, chronological, resolved-name joins, empty-safe).
- `Lots.Lot_Create` accepts `@LotName` (mint-by-default, validated) + `@CavityNote` (D2 manual cavity) — every existing caller/test unchanged.
- New tests for all three changes pass; the existing `0021`/`0022` LOT tests pass unmodified; full suite ≥ 1520 and green.
- All seeds ASCII-verified (byte scan).
