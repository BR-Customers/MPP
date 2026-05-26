# Item Master — Phase 5 Routes Versioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Convention reconciliation (added 2026-05-20):** This plan was drafted ahead of the **per-section ownership** convention codified in `project_mpp_item_master_pattern` memory (2026-05-20 rev). The plan's architecture already aligns with the convention — Routes was the first spec to consciously reject the bidi-Object-param mechanism. Two small adjustments during execution: (1) the deferred cross-tab dirty gate (spec §6.8) is now provided by the convention — emit `sectionDirtyChanged {section: "routes", isDirty: <bool>}` page-scoped on every dirty-state transition, and listen for `sectionSaveRequested` / `sectionDiscardRequested` page-scoped from parent. (2) Rename "tab-level dirty" → "section dirty" in toast messages and code comments for consistency with Identity (which is a section but not a tab). The rest of the plan stands as written.

**Goal:** Wire the Routes tab on `/items` end-to-end against `Parts.RouteTemplate` + `Parts.RouteStep` + `Parts.OperationTemplate`, implementing the full Draft → Published → Deprecated workflow per `docs/superpowers/specs/2026-05-20-item-master-routes-design.md`.

**Tech stack:** SQL Server 2022 (new + extended stored procs); Ignition 8.3 Perspective NQs + entity scripts (`BlueRidge.Common.Db` / `_Util` / `_Ui` / `_Notify`); per-view edits in Designer for existing views, file writes for new views.

**Spec:** `docs/superpowers/specs/2026-05-20-item-master-routes-design.md`

**Reference patterns:**
- Bundled SaveAll reference impl: `sql/migrations/repeatable/R__Location_LocationTypeDefinition_SaveAll.sql`
- Versioned-entity proc shapes: `sql/migrations/repeatable/R__Parts_RouteTemplate_*.sql`
- Existing entity-script + NQ + popup-editor flow: `BlueRidge.Location.LocationTypeDefinition` + LocationTypeEditor view
- File-edit boundary: `feedback_ignition_view_edit_boundary.md`
- Designer GSON escapes: `feedback_ignition_designer_unicode_escapes.md`
- Toast / popup conventions: `BlueRidge.Common.Notify`, `Components/Popups/ConfirmUnsaved`
- Memory: `mpp-bundled-save-pattern`, `mpp-confirm-unsaved-popup-pattern`, `project-mpp-item-master-pattern`

---

## File Structure

**SQL (NEW + EXTENSIONS):**
- NEW: `sql/migrations/repeatable/R__Parts_RouteTemplate_SaveAll.sql`
- NEW: `sql/migrations/repeatable/R__Parts_RouteTemplate_DiscardDraft.sql`
- EXTEND: `sql/migrations/repeatable/R__Parts_RouteTemplate_Publish.sql` (add `@EffectiveFrom`, `@Name` overrides + zero-steps guard)
- EXTEND: `sql/migrations/repeatable/R__Parts_RouteTemplate_CreateNewVersion.sql` (add single-Draft-per-Item guard)
- EXTEND: `sql/migrations/repeatable/R__Parts_RouteStep_ListByRoute.sql` (add `OperationAreaName`, `DataCollectionSummary` columns)
- NEW: `sql/tests/0009_Parts_Process/030_RouteTemplate_SaveAll.sql`
- NEW: `sql/tests/0009_Parts_Process/031_RouteTemplate_DiscardDraft.sql`
- EXTEND: `sql/tests/0009_Parts_Process/020_RouteTemplate_crud.sql` (cover new Publish overrides + zero-steps guard + single-Draft guard)

**Ignition Named Queries (NEW):**
- NEW: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/named-query/parts/RouteTemplate_ListByItem/{resource.json, query.sql}`
- NEW: `…/parts/RouteTemplate_Get/{resource.json, query.sql}`
- NEW: `…/parts/RouteStep_ListByRoute/{resource.json, query.sql}`
- NEW: `…/parts/RouteTemplate_CreateNewVersion/{resource.json, query.sql}`
- NEW: `…/parts/RouteTemplate_Publish/{resource.json, query.sql}`
- NEW: `…/parts/RouteTemplate_DiscardDraft/{resource.json, query.sql}`
- NEW: `…/parts/RouteTemplate_SaveAll/{resource.json, query.sql}`
- NEW: `…/parts/RouteTemplate_Deprecate/{resource.json, query.sql}` (optional — only if Deprecate button is added per spec R5)
- NEW: `…/parts/OperationTemplate_ListByArea/{resource.json, query.sql}`

**Entity script (NEW):**
- NEW: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/script-python/BlueRidge/Parts/Route/code.py`
  - Module exports: `listVersions`, `getHeader`, `getSteps`, `getOperationTemplatesByArea`, `createNewVersion`, `saveAll`, `publish`, `discardDraft`, `deprecate`

**Views:**
- EDIT (Designer): `views/BlueRidge/Components/Parts/ItemMaster/Routes/view.json`
- EDIT (Designer): `views/BlueRidge/Views/Parts/ItemMaster/view.json` (Embedded Routes view — change `props.params` from bidi `editDraft.routes` to input-only `itemId`)
- NEW (file): `views/BlueRidge/Components/Popups/ConfirmDestructive/{resource.json, view.json}`

**Stylesheet:** no change anticipated. Spot-check at smoke time; add classes only if missing.

---

## Conventions This Plan Follows

- **Designer-vs-file edit boundary** (per `feedback_ignition_view_edit_boundary.md`): NEW view files are written directly; EDITS to existing view.json go through Designer. Steps below mark each edit explicitly with **[DESIGNER]** or **[FILE]**.
- **scan.ps1** must be run at project root after writing any new Ignition file (NQ, entity script, new view).
- **SQL test suite** is the gate before each commit involving SQL changes — run `.\Reset-DevDatabase.ps1` (or equivalent) and verify `937 → N` pass count climbs by the new test count, with zero failures.
- **Commit messages**: `feat(routes): <one-liner>` / `fix(routes): …` / `test(routes): …`. Omit `Co-Authored-By: Claude` trailer per `feedback_no_claude_coauthor.md`.
- **Audit on every mutation**: every new/extended proc calls `Audit.Audit_LogConfigChange` on success (inside the transaction) and `Audit.Audit_LogFailure` on every validation/exception path.
- **NQ shape**: BIT Status convention — every mutation NQ binds to a proc emitting `SELECT @Status, @Message[, @NewId]` (one result set; no OUTPUT params); the entity-script wrapper reads via `Common.Db.execMutation`.
- **NQ sqlType enum** (Designer-canonical) per `feedback_ignition_nq_resource_schema.md`: BIGINT=3, NVARCHAR=7, DATETIME=8, BIT=6.

---

## Task 1: SQL — Extend `RouteStep_ListByRoute` with OperationAreaName + DataCollectionSummary

**Files:**
- Modify: `sql/migrations/repeatable/R__Parts_RouteStep_ListByRoute.sql`
- Verify: `sql/tests/0009_Parts_Process/020_RouteTemplate_crud.sql` — adjust if the existing test asserts an exact column list

**Why first:** every downstream NQ + UI relies on the new columns. Small additive change.

- [ ] **Step 1: Read the current proc + its test** to find any assertions on exact column shape.

- [ ] **Step 2: Add the two columns to the SELECT**:
  ```sql
  -- existing JOIN to OperationTemplate aliased as ot
  -- ADD: JOIN Location.Location areaLoc ON areaLoc.Id = ot.AreaLocationId
  -- ADD column: areaLoc.Name AS OperationAreaName
  -- ADD column: dataCollectionSummary (a correlated STRING_AGG subquery over OperationTemplateField joined to DataCollectionField,
  --             filtered to DeprecatedAt IS NULL, ordered by DataCollectionField.Code)
  ```
  Example shape:
  ```sql
  SELECT
      rs.Id, rs.RouteTemplateId, rs.SequenceNumber, rs.OperationTemplateId,
      ot.Code AS OperationCode, ot.Name AS OperationName, ot.VersionNumber AS OperationVersionNumber,
      areaLoc.Id AS OperationAreaLocationId,
      areaLoc.Name AS OperationAreaName,
      ISNULL((
          SELECT STRING_AGG(dcf.Code, N', ') WITHIN GROUP (ORDER BY dcf.Code)
          FROM Parts.OperationTemplateField otf
          INNER JOIN Parts.DataCollectionField dcf ON dcf.Id = otf.DataCollectionFieldId
          WHERE otf.OperationTemplateId = rs.OperationTemplateId
            AND otf.DeprecatedAt IS NULL
      ), N'') AS DataCollectionSummary,
      rs.IsRequired, rs.Description
  FROM Parts.RouteStep rs
  INNER JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
  INNER JOIN Location.Location areaLoc ON areaLoc.Id = ot.AreaLocationId
  WHERE rs.RouteTemplateId = @RouteTemplateId
  ORDER BY rs.SequenceNumber;
  ```

- [ ] **Step 3: Bump the proc's Change Log** to 3.0 with date 2026-05-20 + description.

- [ ] **Step 4: Run SQL test suite** (`.\Reset-DevDatabase.ps1` or equivalent). Verify 937/937 still passes (existing tests should continue to assert on the columns they pre-existed for; the new columns are additive and shouldn't break anything unless a test does `SELECT * INTO #t` then asserts column count — fix if so).

- [ ] **Step 5: Commit**:
  ```
  git add sql/migrations/repeatable/R__Parts_RouteStep_ListByRoute.sql sql/tests/0009_Parts_Process/020_RouteTemplate_crud.sql
  git commit -m "feat(routes): RouteStep_ListByRoute projects OperationAreaName + DataCollectionSummary"
  ```

---

## Task 2: SQL — Extend `RouteTemplate_CreateNewVersion` with single-Draft-per-Item guard

**Files:**
- Modify: `sql/migrations/repeatable/R__Parts_RouteTemplate_CreateNewVersion.sql`
- Modify: `sql/tests/0009_Parts_Process/020_RouteTemplate_crud.sql` (add a test for the guard)

- [ ] **Step 1: Read the current proc** to locate the parameter validation block.

- [ ] **Step 2: After parent-existence validation, add the single-Draft guard**:
  ```sql
  -- Reject if an active Draft already exists for the same Item
  DECLARE @ParentItemId BIGINT;
  SELECT @ParentItemId = ItemId FROM Parts.RouteTemplate WHERE Id = @ParentRouteTemplateId;

  IF EXISTS (
      SELECT 1 FROM Parts.RouteTemplate
      WHERE ItemId = @ParentItemId
        AND PublishedAt IS NULL
        AND DeprecatedAt IS NULL
  )
  BEGIN
      SET @Message = N'A Draft for this Item already exists. Publish or discard it before creating another.';
      EXEC Audit.Audit_LogFailure ...;
      SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
      RETURN;
  END
  ```

- [ ] **Step 3: Bump Change Log** to 3.0.

- [ ] **Step 4: Inspect existing test cases** for `_CreateNewVersion` — they likely don't trip the new guard (each typically creates one Draft per Item). If any does, refactor.

- [ ] **Step 5: Add a new test case** to `020_RouteTemplate_crud.sql`:
  - Create an Item + an initial Route + Publish v1.
  - `_CreateNewVersion` v2 → Draft.
  - `_CreateNewVersion` again on v1 → expect `Status = 0` and message contains "Draft for this Item already exists".

- [ ] **Step 6: Run SQL test suite.** Verify pass count climbs by 1, zero failures.

- [ ] **Step 7: Commit**:
  ```
  git commit -m "feat(routes): RouteTemplate_CreateNewVersion rejects when an active Draft exists"
  ```

---

## Task 3: SQL — Extend `RouteTemplate_Publish` with overrides + zero-steps guard

**Files:**
- Modify: `sql/migrations/repeatable/R__Parts_RouteTemplate_Publish.sql`
- Modify: `sql/tests/0009_Parts_Process/020_RouteTemplate_crud.sql`

- [ ] **Step 1: Update proc signature**:
  ```sql
  CREATE OR ALTER PROCEDURE Parts.RouteTemplate_Publish
      @Id            BIGINT,
      @AppUserId     BIGINT,
      @EffectiveFrom DATETIME2(3) = NULL,    -- NEW
      @Name          NVARCHAR(200) = NULL    -- NEW
  AS
  ```

- [ ] **Step 2: Add zero-steps guard** after the existing not-found / deprecated / already-published validations:
  ```sql
  IF NOT EXISTS (SELECT 1 FROM Parts.RouteStep WHERE RouteTemplateId = @Id)
  BEGIN
      SET @Message = N'Cannot publish: route has no steps.';
      EXEC Audit.Audit_LogFailure ...;
      SELECT @Status AS Status, @Message AS Message;
      RETURN;
  END
  ```

- [ ] **Step 3: Apply the optional overrides inside the existing transaction**:
  ```sql
  BEGIN TRANSACTION;

  UPDATE Parts.RouteTemplate
  SET PublishedAt   = SYSUTCDATETIME(),
      EffectiveFrom = ISNULL(@EffectiveFrom, EffectiveFrom),
      Name          = ISNULL(@Name, Name)
  WHERE Id = @Id;
  ```

- [ ] **Step 4: Update `@Params` JSON capture** to include the new params for the audit row.

- [ ] **Step 5: Bump Change Log** to 3.0.

- [ ] **Step 6: Add test cases**:
  - Publish a Draft with zero steps → expect Status=0 with "no steps" message.
  - Publish a Draft with steps and no overrides → expect Status=1, EffectiveFrom + Name unchanged from Draft.
  - Publish a Draft with `@EffectiveFrom = '2027-01-01'` → expect Status=1, EffectiveFrom = 2027-01-01.
  - Publish a Draft with `@Name = N'Renamed at publish'` → expect Status=1, Name = 'Renamed at publish'.

- [ ] **Step 7: Run SQL test suite.** Pass count climbs by 4.

- [ ] **Step 8: Commit**:
  ```
  git commit -m "feat(routes): RouteTemplate_Publish takes optional EffectiveFrom/Name + rejects zero-step Drafts"
  ```

---

## Task 4: SQL — Create `RouteTemplate_DiscardDraft`

**Files:**
- New: `sql/migrations/repeatable/R__Parts_RouteTemplate_DiscardDraft.sql`
- New: `sql/tests/0009_Parts_Process/031_RouteTemplate_DiscardDraft.sql`

- [ ] **Step 1: Author the proc.** Use `R__Parts_RouteTemplate_Deprecate.sql` as the scaffold (same shape, BIT Status convention, audit + RAISERROR pattern). Differences:
  - Reject if `PublishedAt IS NOT NULL` (cannot discard a Published route).
  - Reject if `DeprecatedAt IS NOT NULL` (already gone).
  - Capture OldValue = full header + steps JSON pre-mutation (for the audit row).
  - DELETE from `Parts.RouteStep WHERE RouteTemplateId = @Id` first.
  - DELETE from `Parts.RouteTemplate WHERE Id = @Id` second.
  - `Audit.Audit_LogConfigChange` with `EventCode = N'Deleted'`, `OldValue = snapshot`, `NewValue = NULL`.
  - Emit `SELECT @Status, @Message;` (no NewId — entity is gone).

- [ ] **Step 2: Author the test file** (`031_RouteTemplate_DiscardDraft.sql`):
  - Discard a Draft (zero steps) → Status=1, row gone from both tables, ConfigLog row written.
  - Discard a Draft with steps → Status=1, header gone, all step rows gone, ConfigLog row written.
  - Discard a Published row → Status=0 with "Cannot discard a Published route" or similar.
  - Discard a Deprecated row → Status=0 with "RouteTemplate is deprecated" or similar.
  - Discard a non-existent Id → Status=0 with "RouteTemplate not found".

- [ ] **Step 3: Run SQL test suite.** Pass count climbs by 5.

- [ ] **Step 4: Commit**:
  ```
  git commit -m "feat(routes): add RouteTemplate_DiscardDraft (hard delete for unpublished routes)"
  ```

---

## Task 5: SQL — Create `RouteTemplate_SaveAll` (bundled Draft save)

**Files:**
- New: `sql/migrations/repeatable/R__Parts_RouteTemplate_SaveAll.sql`
- New: `sql/tests/0009_Parts_Process/030_RouteTemplate_SaveAll.sql`

- [ ] **Step 1: Author the proc.** Use `R__Location_LocationTypeDefinition_SaveAll.sql` as the scaffold; adapt for RouteTemplate + RouteStep specifics.

  Signature:
  ```sql
  CREATE OR ALTER PROCEDURE Parts.RouteTemplate_SaveAll
      @Id            BIGINT,             -- required; must be an active Draft
      @Name          NVARCHAR(200),
      @EffectiveFrom DATETIME2(3),
      @AppUserId     BIGINT,
      @StepsJson     NVARCHAR(MAX) = N'[]'   -- JSON array
  AS
  ```

  Validation block:
  - Required-param check (Id, Name, EffectiveFrom, AppUserId all non-NULL).
  - Resolve `@Id` → row must exist, `PublishedAt IS NULL`, `DeprecatedAt IS NULL`. Friendly messages for "not found", "already Published" ("Cannot edit a Published route. Create a new version first."), "deprecated".
  - Parse `@StepsJson` into `@Incoming` temp table with `RowIndex` (1-based from `[key] + 1`).
  - Every incoming row's `OperationTemplateId` must be non-NULL.
  - Every `OperationTemplateId` must resolve to an active `Parts.OperationTemplate` (`DeprecatedAt IS NULL`). Reject otherwise.
  - For incoming rows with non-NULL `Id`, validate the row belongs to this `RouteTemplateId` (catches stale Ids).
  - **No** uniqueness constraint on `OperationTemplateId` across the batch — repetition is allowed.

  Mutation block (single transaction):
  - Capture `OldValue` = header JSON + ordered steps JSON snapshot.
  - UPDATE header: `Name`, `EffectiveFrom`.
  - DELETE FROM `Parts.RouteStep WHERE RouteTemplateId = @Id AND Id NOT IN (SELECT Id FROM @Incoming WHERE Id IS NOT NULL)`. (Hard-delete; per design § 5.2.)
  - UPDATE matched rows: `OperationTemplateId`, `IsRequired`, `Description`, `SequenceNumber = RowIndex`.
  - INSERT new rows (incoming with NULL `Id`): `SequenceNumber = RowIndex`, IsRequired, Description.
  - Capture `NewValue` snapshot.
  - `Audit.Audit_LogConfigChange` with `EventCode = N'Updated'`, `Description = N'RouteTemplate saved with step reconciliation.'`, OldValue + NewValue.
  - COMMIT.
  - Emit `SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;` (NewId echoes @Id).

  CATCH block: rollback + capture ERROR_MESSAGE → @Message + nested-try-catch Audit_LogFailure + RAISERROR.

- [ ] **Step 2: Author the test file** (`030_RouteTemplate_SaveAll.sql`):
  - **SaveAll on a fresh Draft (empty → 3 steps)** → Status=1, 3 RouteStep rows with SequenceNumber 1/2/3.
  - **SaveAll updates existing steps in-place** — pass back known Ids with reordered RowIndex, expect SequenceNumber updated.
  - **SaveAll inserts new steps + deletes orphans** — submit a list where one existing step Id is missing and one new row has NULL Id; expect the orphan DELETED and the new row INSERTED.
  - **SaveAll rejects on Published route** → Status=0 with "Cannot edit a Published route" message.
  - **SaveAll rejects on Deprecated route** → Status=0.
  - **SaveAll rejects with NULL OperationTemplateId in a step** → Status=0 with "row N missing OperationTemplateId" or similar.
  - **SaveAll rejects with stale step Id (Id not belonging to this route)** → Status=0.
  - **SaveAll rejects with NULL Name or EffectiveFrom** → Status=0 ("Required parameter missing").
  - **Audit row written on success** — verify `Audit.ConfigLog` has the new row with OldValue + NewValue.

- [ ] **Step 3: Run SQL test suite.** Pass count climbs by 9.

- [ ] **Step 4: Commit**:
  ```
  git commit -m "feat(routes): add RouteTemplate_SaveAll (bundled Draft meta + step reconciliation)"
  ```

---

## Task 6: Ignition Named Queries — read paths

**Files (each = a folder with `resource.json` + `query.sql`):**
- New: `…/named-query/parts/RouteTemplate_ListByItem`
- New: `…/named-query/parts/RouteTemplate_Get`
- New: `…/named-query/parts/RouteStep_ListByRoute`
- New: `…/named-query/parts/OperationTemplate_ListByArea`

Note: there may already be NQs for these procs from other phases. Check the `named-query/parts/` directory and only add what's missing.

Each `resource.json`:
```json
{
  "scope": "G",
  "version": 2,
  "restricted": false,
  "overridable": true,
  "files": ["query.sql"],
  "attributes": {
    "lastModification": {
      "actor": "Jacques Potgieter",
      "timestamp": "2026-05-20T12:00:00Z"
    }
  }
}
```

NQ params use Designer-canonical sqlType:
- BIGINT → 3
- NVARCHAR → 7
- DATETIME → 8
- BIT → 6

NQ shape examples:

**`RouteTemplate_ListByItem`** params: `itemId` (sqlType 3), `activeOnly` (sqlType 6, default 1).
```sql
EXEC Parts.RouteTemplate_ListByItem @ItemId = :itemId, @ActiveOnly = :activeOnly;
```

**`RouteTemplate_Get`** params: `id` (sqlType 3).
```sql
EXEC Parts.RouteTemplate_Get @Id = :id;
```

**`RouteStep_ListByRoute`** params: `routeTemplateId` (sqlType 3).
```sql
EXEC Parts.RouteStep_ListByRoute @RouteTemplateId = :routeTemplateId;
```

**`OperationTemplate_ListByArea`** params: `areaLocationId` (sqlType 3), `activeOnly` (sqlType 6, default 1).
```sql
EXEC Parts.OperationTemplate_List @AreaLocationId = :areaLocationId, @ActiveOnly = :activeOnly;
```
(Note: the existing proc is named `_List`, not `_ListByArea`. The NQ may be named for the call-site semantic.)

- [ ] **Step 1: Read existing `named-query/parts/` directory** to identify pre-existing NQs (likely some Item NQs from Phase 2 of the Item Master build).

- [ ] **Step 2: Write each missing NQ folder** (resource.json + query.sql per the shapes above).

- [ ] **Step 3: Run `.\scan.ps1`** at project root. Expect HTTP 200.

- [ ] **Step 4: Sanity-check from Designer Script Console** (one round-trip per NQ):
  ```python
  ds = system.db.runNamedQuery("parts/RouteTemplate_ListByItem", {"itemId": <a known itemId>, "activeOnly": True})
  system.perspective.print(ds)
  ```
  Verify columns and row counts look sensible.

- [ ] **Step 5: Commit**:
  ```
  git commit -m "feat(routes): named queries for Route read paths (ListByItem/Get/Steps/OpsByArea)"
  ```

---

## Task 7: Ignition Named Queries — mutation paths

**Files (each = a folder with `resource.json` + `query.sql`):**
- New: `…/named-query/parts/RouteTemplate_CreateNewVersion`
- New: `…/named-query/parts/RouteTemplate_Publish`
- New: `…/named-query/parts/RouteTemplate_SaveAll`
- New: `…/named-query/parts/RouteTemplate_DiscardDraft`
- New: `…/named-query/parts/RouteTemplate_Deprecate` (only if Deprecate button is added per spec R5)

**`RouteTemplate_CreateNewVersion`** params: `parentRouteTemplateId` (sqlType 3), `effectiveFrom` (sqlType 8, nullable), `appUserId` (sqlType 3).
```sql
EXEC Parts.RouteTemplate_CreateNewVersion
    @ParentRouteTemplateId = :parentRouteTemplateId,
    @EffectiveFrom         = :effectiveFrom,
    @AppUserId             = :appUserId;
```

**`RouteTemplate_Publish`** params: `id` (3), `appUserId` (3), `effectiveFrom` (8, nullable), `name` (7, nullable).
```sql
EXEC Parts.RouteTemplate_Publish
    @Id            = :id,
    @AppUserId     = :appUserId,
    @EffectiveFrom = :effectiveFrom,
    @Name          = :name;
```

**`RouteTemplate_SaveAll`** params: `id` (3), `name` (7), `effectiveFrom` (8), `appUserId` (3), `stepsJson` (7).
```sql
EXEC Parts.RouteTemplate_SaveAll
    @Id            = :id,
    @Name          = :name,
    @EffectiveFrom = :effectiveFrom,
    @AppUserId     = :appUserId,
    @StepsJson     = :stepsJson;
```

**`RouteTemplate_DiscardDraft`** params: `id` (3), `appUserId` (3).
```sql
EXEC Parts.RouteTemplate_DiscardDraft @Id = :id, @AppUserId = :appUserId;
```

**`RouteTemplate_Deprecate`** params: `id` (3), `appUserId` (3).
```sql
EXEC Parts.RouteTemplate_Deprecate @Id = :id, @AppUserId = :appUserId;
```

- [ ] **Step 1: Write each NQ folder.**

- [ ] **Step 2: Run `.\scan.ps1`.**

- [ ] **Step 3: Smoke-test each mutation from Script Console** with one happy-path call + one error-path call. Confirm the result row (`{Status, Message, NewId?}`) shape comes through.

- [ ] **Step 4: Commit**:
  ```
  git commit -m "feat(routes): named queries for Route mutations (CreateNewVersion/Publish/SaveAll/DiscardDraft/Deprecate)"
  ```

---

## Task 8: Ignition entity script — `BlueRidge.Parts.Route`

**Files:**
- New: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/script-python/BlueRidge/Parts/Route/code.py`
- Verify: `script-python/BlueRidge/Parts/Route/resource.json` (or check the package's `__init__.py` / config.json wiring per project convention — sample at `script-python/BlueRidge/Common/Db/`)

- [ ] **Step 1: Read a reference entity-script** (`script-python/BlueRidge/Oee/DowntimeReasonCode/code.py` from the Downtime Codes work) to lock in the module style — `Common.Db` for I/O, `Common.Util._u` deep-unwrap at every public-method entry, `Common.Util.log` for logging, no per-module logger boilerplate.

- [ ] **Step 2: Author the module**. Public functions:

  ```python
  import json
  from BlueRidge.Common import Db, Util

  _LOG = Util.log  # convenience alias

  def listVersions(itemId, includeDeprecated=False):
      itemId = Util._u(itemId)
      rows = Db.execList("parts/RouteTemplate_ListByItem", {
          "itemId":     itemId,
          "activeOnly": not includeDeprecated
      })
      return rows  # list[dict] ordered newest first

  def getHeader(id):
      id = Util._u(id)
      rows = Db.execList("parts/RouteTemplate_Get", {"id": id})
      return rows[0] if rows else None

  def getSteps(routeTemplateId):
      routeTemplateId = Util._u(routeTemplateId)
      return Db.execList("parts/RouteStep_ListByRoute", {"routeTemplateId": routeTemplateId})

  def getOperationTemplatesByArea(areaLocationId, includeDeprecated=False):
      areaLocationId = Util._u(areaLocationId)
      return Db.execList("parts/OperationTemplate_ListByArea", {
          "areaLocationId": areaLocationId,
          "activeOnly":     not includeDeprecated
      })

  def createNewVersion(parentRouteTemplateId, effectiveFrom=None, appUserId=None):
      parentRouteTemplateId = Util._u(parentRouteTemplateId)
      effectiveFrom         = Util._u(effectiveFrom)
      appUserId             = appUserId or Util._currentAppUserId()
      return Db.execMutation("parts/RouteTemplate_CreateNewVersion", {
          "parentRouteTemplateId": parentRouteTemplateId,
          "effectiveFrom":         effectiveFrom,
          "appUserId":             appUserId
      })

  def saveAll(id, name, effectiveFrom, stepsList, appUserId=None):
      id            = Util._u(id)
      name          = Util._u(name)
      effectiveFrom = Util._u(effectiveFrom)
      stepsList     = Util._u(stepsList)
      appUserId     = appUserId or Util._currentAppUserId()

      # Project the JSON shape the proc expects — strip display caches
      payload = [
          {
              "Id":                  s.get("Id"),
              "OperationTemplateId": s.get("OperationTemplateId"),
              "IsRequired":          1 if s.get("IsRequired") else 0,
              "Description":         s.get("Description")
          }
          for s in (stepsList or [])
      ]

      return Db.execMutation("parts/RouteTemplate_SaveAll", {
          "id":            id,
          "name":          name,
          "effectiveFrom": effectiveFrom,
          "appUserId":     appUserId,
          "stepsJson":     json.dumps(payload)
      })

  def publish(id, effectiveFrom=None, name=None, appUserId=None):
      id            = Util._u(id)
      effectiveFrom = Util._u(effectiveFrom)
      name          = Util._u(name)
      appUserId     = appUserId or Util._currentAppUserId()
      return Db.execMutation("parts/RouteTemplate_Publish", {
          "id":            id,
          "appUserId":     appUserId,
          "effectiveFrom": effectiveFrom,
          "name":          name
      })

  def discardDraft(id, appUserId=None):
      id        = Util._u(id)
      appUserId = appUserId or Util._currentAppUserId()
      return Db.execMutation("parts/RouteTemplate_DiscardDraft", {"id": id, "appUserId": appUserId})

  def deprecate(id, appUserId=None):
      id        = Util._u(id)
      appUserId = appUserId or Util._currentAppUserId()
      return Db.execMutation("parts/RouteTemplate_Deprecate", {"id": id, "appUserId": appUserId})

  def publishWithSave(id, name, effectiveFrom, stepsList, appUserId=None):
      """Chained save-then-publish behind a single button press. Per design § 6.9."""
      saveRes = saveAll(id=id, name=name, effectiveFrom=effectiveFrom,
                        stepsList=stepsList, appUserId=appUserId)
      if not saveRes or not saveRes.get("Status"):
          return saveRes  # bail; surface save failure
      return publish(id=id, effectiveFrom=effectiveFrom, name=name, appUserId=appUserId)
  ```

- [ ] **Step 3: Run `.\scan.ps1`.**

- [ ] **Step 4: Smoke-test each function from Designer Script Console**:
  ```python
  versions = BlueRidge.Parts.Route.listVersions(<a known itemId>, includeDeprecated=False)
  system.perspective.print(versions)
  steps = BlueRidge.Parts.Route.getSteps(versions[0]["Id"])
  system.perspective.print(steps)
  ```

- [ ] **Step 5: Commit**:
  ```
  git commit -m "feat(routes): BlueRidge.Parts.Route entity script"
  ```

---

## Task 9: Build `ConfirmDestructive` popup (NEW view, file write)

**Files:**
- New: `views/BlueRidge/Components/Popups/ConfirmDestructive/{resource.json, view.json}`

This is a new view; safe to file-write per `feedback_ignition_view_edit_boundary.md`. Mirror `Components/Popups/ConfirmUnsaved/view.json` structure but with two buttons instead of three.

- [ ] **Step 1: Read `Components/Popups/ConfirmUnsaved/view.json`** for the layout template + parameter list.

- [ ] **Step 2: Author `ConfirmDestructive/view.json`**. Parameters:
  ```yaml
  params:
    title:         "Confirm"                # header label
    message:       "Are you sure?"          # body label
    confirmLabel:  "Confirm"                # primary button text
    cancelLabel:   "Cancel"                 # neutral button text
    confirmClass:  "btn btn-danger btn-sm"  # button class (default destructive red)
    replyMessage:  "confirmDestructiveResult"  # page-scoped message type
    popupId:       "mpp-confirm-destructive"
  ```

  Two buttons: Cancel (left) and Confirm (right). Each fires a page-scoped message with payload `{"action": "confirm"}` or `{"action": "cancel"}`, then closes the popup. Direct adaptation of ConfirmUnsaved's button scripts.

- [ ] **Step 3: Author `resource.json`** (sibling to ConfirmUnsaved's resource.json shape).

- [ ] **Step 4: Run `.\scan.ps1`.**

- [ ] **Step 5: Smoke-test** by opening it from Designer Script Console:
  ```python
  system.perspective.openPopup(
      id="mpp-confirm-destructive",
      view="BlueRidge/Components/Popups/ConfirmDestructive",
      modal=True, showCloseIcon=False,
      params={"title": "Test", "message": "Confirm test?"}
  )
  ```
  Verify both buttons render + fire their messages (catch via a temporary handler on any view).

- [ ] **Step 6: Commit**:
  ```
  git commit -m "feat(popups): add ConfirmDestructive popup (two-button confirm/cancel)"
  ```

---

## Task 10: Refactor `Components/Parts/ItemMaster/Routes/view.json` — Phase 5 surface

**Files:**
- Edit (Designer): `views/BlueRidge/Components/Parts/ItemMaster/Routes/view.json`

This is the largest single step in the plan; the existing view is the Phase 1 published-only static shell, and Phase 5 replaces it with the full versioning surface. **Designer edit, not file edit** (per `feedback_ignition_view_edit_boundary.md`).

### 10a. Replace `view.params` with `itemId`

Currently:
```json
"params": { "value": {} },
"propConfig": { "params.value": {"paramDirection": "input"} }
```

Replace with:
```json
"params": { "itemId": null },
"propConfig": { "params.itemId": {"paramDirection": "input"} }
```

### 10b. Populate `view.custom`

```yaml
itemId:             (input mirror — read-only computed binding to view.params.itemId)
versions:           []
showDeprecated:     false
selectedVersionId:  null
selectedHeader:     null
selectedSteps:      []
mode:               "view"     # "view" | "draft"
opTemplatesByArea:  {}
areas:              []
draftId:            null
draftEditDraft:     null
draftSelected:      null
```

Bind data loads via property-change scripts on `view.params.itemId`:

```python
# events.propertyChange on view.params.itemId
itemId = currentValue.value
if itemId is None:
    self.view.custom.versions = []
    self.view.custom.selectedVersionId = None
    self.view.custom.selectedHeader = None
    self.view.custom.selectedSteps = []
    return

versions = BlueRidge.Parts.Route.listVersions(itemId, self.view.custom.showDeprecated)
self.view.custom.versions = versions
# Default selectedVersionId to the active Published version (highest VersionNumber where PublishedAt IS NOT NULL AND DeprecatedAt IS NULL)
active = next((v for v in versions if v["PublishedAt"] and not v["DeprecatedAt"]), None)
self.view.custom.selectedVersionId = active["Id"] if active else (versions[0]["Id"] if versions else None)
```

Cascade `selectedVersionId` → header + steps via its own propertyChange:

```python
sid = currentValue.value
if sid is None:
    self.view.custom.selectedHeader = None
    self.view.custom.selectedSteps = []
    return
self.view.custom.selectedHeader = BlueRidge.Parts.Route.getHeader(sid)
self.view.custom.selectedSteps  = BlueRidge.Parts.Route.getSteps(sid)
```

Load Areas once on view startup:

```python
# events.onStartup on the view (or onMount if using mount events)
self.view.custom.areas = BlueRidge.Location.Location.getAllAreas(includeAll=False)
```

### 10c. Two-mode root layout

Replace the existing two-element flex column (HeaderRow + PublishedPanel) with a structure that conditionally renders one of two header strips and one of two table panels, gated by `view.custom.mode`:

```
root (ia.container.flex, direction: column, gap: 10px)
  ├── PublishedHeaderRow  position.display = "{view.custom.mode} = 'view'"
  │     ├── VersionDropdown    bidi → view.custom.selectedVersionId
  │     │     options expression: pretty-formatted list from view.custom.versions
  │     ├── ShowDeprecatedCheckbox  bidi → view.custom.showDeprecated
  │     │     (onChange: reload versions)
  │     ├── BadgePublished / BadgeDeprecated / BadgeDraft
  │     │     visibility per selectedHeader state
  │     ├── HeaderSpacer (grow:1)
  │     └── BtnNewVersion       onClick → handleNewVersion (see 10e)
  │
  ├── DraftHeaderRow      position.display = "{view.custom.mode} = 'draft'"
  │     ├── VersionDropdown (same source; if user picks non-draft, ConfirmUnsaved fires)
  │     ├── BadgeDraft
  │     ├── EffectiveDatePicker  bidi → draftEditDraft.EffectiveFrom
  │     ├── HeaderSpacer (grow:1)
  │     ├── BtnDiscardDraft      onClick → handleDiscardDraft
  │     └── BtnPublish           onClick → handlePublish (chained save+publish)
  │
  ├── PublishedPanel      position.display = "{view.custom.mode} = 'view'"
  │     └── RouteStepsTable (read-only, columns: #, Up/Down (disabled), Area, Operation Template, Required, Data Collection)
  │           data binding: view.custom.selectedSteps
  │           Note: "Operation Template" cell renders the synthesized "Code v<n> — Name" label
  │           in a styled label, not as raw column data
  │
  └── DraftPanel          position.display = "{view.custom.mode} = 'draft'"
        ├── DraftStepsTable (editable; columns: #, Up/Down, Area dropdown, OpTemplate dropdown, Required checkbox, Data Collection (read-only), ✕ remove)
        │     data binding: view.custom.draftEditDraft.steps
        │     Each row is a flex-repeater sub-view (see 10d) OR a custom ia.display.table with cell renderers — pick the simpler shape; flex-repeater is the project precedent
        └── AddStepButton onClick → handleAddStep
```

### 10d. DraftStepRow sub-view (NEW)

If using flex-repeater (recommended for editability + per-row dropdown behavior), introduce:

- New view: `views/BlueRidge/Components/Parts/ItemMaster/Routes/DraftStepRow/{resource.json, view.json}` — **file-write, new view**.
- Params: `instance` (Object — the step dict + index), `opTemplatesByArea` (Object — pass-through reference to parent cache), `areas` (Array — pass-through), `isFirst` (Boolean), `isLast` (Boolean).
- Renders one row matching the mockup's draft table row shape (lines 605–613 of `mockup/index.html`).
- Each Area dropdown change → `propertyChange` script that:
  - Caches new opTemplates list (via `BlueRidge.Parts.Route.getOperationTemplatesByArea(newAreaId)` if not cached)
  - Resets `instance.OperationTemplateId` to first option
  - Sends page-scoped message `routeStepChanged` with payload `{rowIndex, instance}` back to the parent Routes view
- Up/Down/Remove buttons send page-scoped messages: `routeStepMoveUp`/`routeStepMoveDown`/`routeStepRemove` with `{rowIndex}` payload.
- Parent Routes view has `messageHandlers` for these (pageScope: true, viewScope: false) that mutate `draftEditDraft.steps`.

Alternative: build the editable table as an `ia.display.table` with cell renderers. The project's existing pattern leans on flex-repeaters for editable tabular shapes (Defect Codes, Downtime Codes), so flex-repeater is the consistent choice.

### 10e. Inline handler scripts (sketch)

```python
# handleNewVersion — onClick of BtnNewVersion (in PublishedHeaderRow)
parentId = self.view.custom.selectedVersionId
if parentId is None:
    BlueRidge.Common.Notify.toast("Cannot create version",
                                   "No source version selected.", "warn", 5)
    return
# Default EffectiveFrom = SYSUTCDATETIME(); pass None to let the proc default it
result = BlueRidge.Parts.Route.createNewVersion(parentRouteTemplateId=parentId, effectiveFrom=None)
BlueRidge.Common.Ui.notifyResult(result, "New version", "Draft created.", "Create failed")
if result and result.get("Status"):
    newDraftId = result["NewId"]
    self.view.custom.draftId = newDraftId
    self.view.custom.versions = BlueRidge.Parts.Route.listVersions(
        self.view.params.itemId, self.view.custom.showDeprecated
    )
    header = BlueRidge.Parts.Route.getHeader(newDraftId)
    steps  = BlueRidge.Parts.Route.getSteps(newDraftId)
    draft  = {
        "Id":            newDraftId,
        "Name":          header["Name"],
        "EffectiveFrom": header["EffectiveFrom"],
        "steps":         steps
    }
    self.view.custom.draftEditDraft = dict(draft)
    self.view.custom.draftSelected  = dict(draft)
    self.view.custom.selectedVersionId = newDraftId
    self.view.custom.mode = "draft"

# handleAddStep
draft = self.view.custom.draftEditDraft
steps = list(draft["steps"])
steps.append({
    "Id": None, "SequenceNumber": len(steps) + 1,
    "OperationAreaLocationId": None, "OperationAreaName": "",
    "OperationTemplateId": None, "OperationCode": "", "OperationName": "",
    "OperationVersionNumber": None,
    "DataCollectionSummary": "", "IsRequired": True, "Description": None
})
draft["steps"] = steps
self.view.custom.draftEditDraft = dict(draft)

# handlePublish (chained save+publish per design § 6.9)
draft = self.view.custom.draftEditDraft
result = BlueRidge.Parts.Route.publishWithSave(
    id=self.view.custom.draftId,
    name=draft["Name"],
    effectiveFrom=draft["EffectiveFrom"],
    stepsList=draft["steps"]
)
BlueRidge.Common.Ui.notifyResult(result, "Publish", "Route published.", "Publish failed")
if result and result.get("Status"):
    publishedId = self.view.custom.draftId
    self.view.custom.draftId = None
    self.view.custom.draftEditDraft = None
    self.view.custom.draftSelected  = None
    self.view.custom.mode = "view"
    self.view.custom.versions = BlueRidge.Parts.Route.listVersions(
        self.view.params.itemId, self.view.custom.showDeprecated
    )
    self.view.custom.selectedVersionId = publishedId

# handleDiscardDraft
# Open ConfirmDestructive first; on confirm, call discardDraft
system.perspective.openPopup(
    id="mpp-confirm-destructive",
    view="BlueRidge/Components/Popups/ConfirmDestructive",
    modal=True, showCloseIcon=False,
    params={
        "title":        "Discard Draft?",
        "message":      "This deletes the unpublished draft entirely. It cannot be undone.",
        "confirmLabel": "Discard Draft",
        "replyMessage": "routeConfirmDiscard"
    }
)

# pageScope message handler: routeConfirmDiscard
action = payload.get("action") if payload else None
if action != "confirm":
    return
result = BlueRidge.Parts.Route.discardDraft(id=self.view.custom.draftId)
BlueRidge.Common.Ui.notifyResult(result, "Discard", "Draft discarded.", "Discard failed")
if result and result.get("Status"):
    self.view.custom.draftId = None
    self.view.custom.draftEditDraft = None
    self.view.custom.draftSelected  = None
    self.view.custom.mode = "view"
    self.view.custom.versions = BlueRidge.Parts.Route.listVersions(
        self.view.params.itemId, self.view.custom.showDeprecated
    )
    # Default selectedVersionId back to the active Published version
    active = next((v for v in self.view.custom.versions
                   if v["PublishedAt"] and not v["DeprecatedAt"]), None)
    self.view.custom.selectedVersionId = active["Id"] if active else None
```

### 10f. ConfirmUnsaved wiring on version-dropdown change while dirty

Add a propertyChange script on `view.custom.selectedVersionId` that:
- If `view.custom.mode == "draft"` AND `draftEditDraft != draftSelected`, open `ConfirmUnsaved` popup; carry the intended target version Id in the params or in a `view.custom.pendingVersionId`. Cancel reverts the dropdown.
- Otherwise, no-op (the existing header+steps reload cascade does its job).

Handler for `confirmUnsavedResult` (pageScope):
- "save" → call SaveAll, then if Status=1, proceed with the version switch (clear draft state if leaving), refresh header+steps.
- "discard" → discard in-memory edits (`draftEditDraft = dict(draftSelected)`), proceed with switch. If switching to a non-Draft version, additionally call `discardDraft` to clean up the never-saved Draft row? — open question; recommend NO, the user explicitly chose "discard the in-memory changes," not "delete the persisted Draft." Persisted Draft survives; user can return later.
- "cancel" → revert dropdown to pre-change value.

### 10g. Steps to execute in Designer

- [ ] **Step 1: Open the project in Designer**. Open `Components/Parts/ItemMaster/Routes`.
- [ ] **Step 2: Edit `view.params`** — remove the old `value` Object param; add `itemId` (Long, paramDirection: Input).
- [ ] **Step 3: Populate `view.custom`** per § 10b. Use the Designer property tree.
- [ ] **Step 4: Replace the root children** per § 10c. Keep the existing PublishedHeaderRow + PublishedPanel as the starting scaffold for view-mode; add the DraftHeaderRow + DraftPanel siblings; set `position.display` expressions on all four.
- [ ] **Step 5: Wire the propertyChange scripts** for `view.params.itemId`, `view.custom.selectedVersionId`, and `view.custom.showDeprecated` per § 10b/10f.
- [ ] **Step 6: Wire the inline scripts** for BtnNewVersion / BtnPublish / BtnDiscardDraft per § 10e.
- [ ] **Step 7: Wire the page-scoped message handlers** at the root view (`routeConfirmDiscard`, `confirmUnsavedResult`, `routeStepChanged`, `routeStepMoveUp`, `routeStepMoveDown`, `routeStepRemove`).
- [ ] **Step 8: Wire the DraftStepRow flex-repeater** inside DraftPanel (write the new view files first per 10h).
- [ ] **Step 9: Save** in Designer. **Do not run scan.ps1** for an existing-view edit — Designer's save is the authoritative writer.
- [ ] **Step 10: Smoke-test** the published-mode rendering against a known Item (5G0 Front Cover). Verify version dropdown, badge, table render correctly. The draft flows aren't testable yet until DraftStepRow lands.

### 10h. New view: `Routes/DraftStepRow` (file-write, new view)

- [ ] **Step 1: Write `Routes/DraftStepRow/resource.json`** (standard shape).
- [ ] **Step 2: Write `Routes/DraftStepRow/view.json`**. Match mockup row at lines 605–613 of `mockup/index.html`. Params: `instance` (Object), `opTemplatesByArea` (Object), `areas` (Array), `isFirst` (Boolean), `isLast` (Boolean).
- [ ] **Step 3: Wire** Area dropdown's `onChange` (when bidi value writes back into `instance.AreaLocationId`, fire page-scoped `routeStepChanged` message with the row's index). Similarly OpTemplate dropdown.
- [ ] **Step 4: Wire** Up/Down/Remove buttons to fire `routeStepMoveUp/Down/Remove` page-scoped messages.
- [ ] **Step 5: scan.ps1** → 200.

### 10i. Commit (single commit covering Routes/view.json refactor + DraftStepRow)

```
git commit -m "feat(routes): wire Routes tab to live RouteTemplate data + Draft editing surface"
```

---

## Task 11: Refactor parent ItemMaster — change Routes Embedded View's params

**Files:**
- Edit (Designer): `views/BlueRidge/Views/Parts/ItemMaster/view.json`

- [ ] **Step 1: In Designer, open ItemMaster.** Locate the Routes Embedded View component (the `ia.display.view` whose `props.path = "BlueRidge/Components/Parts/ItemMaster/Routes"`).

- [ ] **Step 2: Change `props.params`** — remove the bidi binding on `params.value → view.custom.editDraft.routes`. Add `params.itemId` as a property binding (one-way input) to `view.custom.editDraft.meta.Id` (or whatever the selected Item's Id field is named in the parent's state — verify against the actual `view.custom` shape).

- [ ] **Step 3: Save in Designer.** Verify the tab still renders (it should now load its own data via the propertyChange in the Routes tab).

- [ ] **Step 4: Smoke-test** in browser — click an Item in the left panel; verify the Routes tab populates with that Item's versions.

- [ ] **Step 5: Commit**:
  ```
  git commit -m "feat(item-master): pass itemId (not editDraft.routes) into Routes tab"
  ```

---

## Task 12: End-to-end smoke test

Per design § 10 — walk the 12-step "What done looks like" checklist. Run each on a browser session against the live gateway.

- [ ] **Pre-check:** `.\Reset-DevDatabase.ps1` + verify SQL test count climbs by ~20 from Phase 5 (1 from Task 1's optional test count adjustment + 1 from Task 2 + 4 from Task 3 + 5 from Task 4 + 9 from Task 5). **Final target: ~957/957.**
- [ ] **Pre-check:** seed at least one Item with a Published v2 + Deprecated v1 RouteTemplate (use Script Console fixtures or run a small seed proc).
- [ ] **Step 1:** Navigate to `/items`. Click 5G0 Front Cover. Open Routes tab.
- [ ] **Step 2:** Verify version dropdown shows `v2 (Published)` selected; "Show all" toggle reveals `v1 (Deprecated)`.
- [ ] **Step 3:** Click **New Version**. Toast "Draft created." Mode switches to draft. Draft v3 steps populated from v2.
- [ ] **Step 4:** Edit a step's Area dropdown. OpTemplate dropdown repopulates. Pick new OpTemplate. Data Collection column updates. Save button shows dirty indicator.
- [ ] **Step 5:** Click **+ Add Step** → blank row appears at the bottom. Click ✕ on a row → row removed.
- [ ] **Step 6:** Click ↑ on the bottom row → moves up by one position.
- [ ] **Step 7:** Click **Save**. Toast "Route saved." Dirty indicator clears. Audit log row written.
- [ ] **Step 8:** Edit again. Click **Publish**. Chained save+publish runs. Toast "Route published." Mode returns to view. Version dropdown updates to show v3 as Published, badge changes.
- [ ] **Step 9:** Click **New Version** again → v4 Draft. Switch version dropdown to v3 → ConfirmUnsaved opens. Click "Discard & Switch" → mode returns to view on v3.
- [ ] **Step 10:** Click **New Version** → v5 Draft. Click **Discard Draft** → ConfirmDestructive opens → confirm → toast "Draft discarded." v5 disappears from version list.
- [ ] **Step 11:** Switch to a different Item in left panel. Verify Routes tab loads that Item's data without leakage.
- [ ] **Step 12:** Inspect `Audit.ConfigLog` from the AuditLog page (existing surface from prior phase). Verify all Phase 5 mutation entries: Created (×2 — `_CreateNewVersion`), Updated (×1 — SaveAll), Updated (×1 — Publish), Deleted (×1 — DiscardDraft).

If any step fails:
- Capture Designer logs + browser console output.
- File as a bug under "Phase 5 follow-ups" in PROJECT_STATUS.md and create a separate task. Don't conflate fixes with the main commit chain.

- [ ] **Final commit (status):**
  ```
  git commit --allow-empty -m "docs(status): Phase 5 Routes versioning landed; smoke green"
  ```
  (Or update `PROJECT_STATUS.md` with the new state per project convention.)

---

## Conventions Recap (per project memory)

- **SP layer:** BIT Status convention; one result set; no OUTPUT params; audit on every mutation path.
- **NQ layer:** v2 schema; Designer-canonical sqlType enum (`3` BIGINT, `7` NVARCHAR, `8` DATETIME, `6` BIT); camelCase param identifiers; `:placeholder` references in query.sql.
- **Entity script layer:** `BlueRidge.Common.Db` is the only caller of `system.db.runNamedQuery`; `Common.Util._u` deep-unwrap at every public-method entry; `Common.Util._currentAppUserId()` for attribution.
- **View layer:** `view.custom` for component-local state; `propertyChange` for cascade loads; flex-repeater for editable tabular rows; ↑/↓ arrow buttons (no drag-and-drop); page-scoped messages for child→parent communication.
- **scan.ps1** after every new-file write.
- **Designer for edits** to existing view.json files.
- **No `Co-Authored-By: Claude` trailer** on commits.

---

## Deferred / Out of Scope (revisit in later phases)

- Cross-tab dirty coordination on the parent ItemMaster (deferred to Phase 6 per design § 6.8).
- "Active now" pill on the version dropdown indicating which Published version is live per `_GetActiveForItem(now)` (design R6 — cosmetic enhancement).
- Operation Template Library + Editor (separate Phased Plan deliverable; not Phase 5 of Item Master).
- Per-step Deprecate of an Operation Template referenced by a Published RouteStep (design R7 — defer).
- Audit retention / cleanup of discarded-draft ConfigLog rows (OI-35 territory).

---
