# Item Master — BOMs Versioning Workflow (Phase 6) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Spec doc is the contract — read it BEFORE touching any task.

> **Convention reconciliation (added 2026-05-20):** This plan was drafted before the **per-section ownership** convention was codified in `project_mpp_item_master_pattern` memory (2026-05-20 rev). The spec's §0 lists the deltas. When executing this plan, apply these adjustments:
>
> 1. **Tasks 18-19 (view structure):** Drop `editDraft.boms` from the PARENT view custom block. BOMs embed owns its own `view.custom.selected` + `view.custom.editDraft` LOCALLY. Parent passes only `params.value: bomId` (BIGINT, input-only — no `bidirectional: true`).
> 2. **Repeater binding:** flex-repeater `instances` binds to `view.custom.editDraft.activeVersion.lines` (the embed's local state), NOT to `view.params.value.activeVersion.lines`.
> 3. **Six message handlers** that Task 19 was going to add on the parent (`bomActiveVersionChanged`, `bomVersionListRefresh`, `bomLineMoveUp`, etc.) move INTO the BOMs embed — they're now intra-tab handlers that mutate local state.
> 4. **Parent message handlers** the BOMs embed must wire: emit `sectionDirtyChanged {section: "boms", isDirty: <bool>}` on every dirty transition; listen for `sectionSaveRequested {section: "boms"}` (run SaveAll) and `sectionDiscardRequested {section: "boms"}` (revert editDraft to selected).
> 5. **Dirty-vs-publish distinction:** `sectionDirty.boms` tracks unsaved DRAFT LINE EDITS only. `Publish`, `Deprecate`, `Discard Draft` are state-machine actions that do NOT fire `sectionDirtyChanged` — they refresh local `selected` directly (success toast + reload). Conflating them would block tab/item switching after a Publish, which is wrong.
> 6. **No page-level Save button for BOMs.** The embed renders its own `[Save Draft]` / `[Publish]` / `[Discard Draft]` buttons per the mockup. The parent's title-bar Save button (Phase 3) only saves Identity.
>
> Proc surface, NQ shapes, entity script, mockup references, and task ordering remain as written. The retrofit is to **where state lives** and **how dirty propagates** — proc semantics and intra-tab UX are unchanged.

**Goal:** Wire the Item Master `BOMs` tab from Phase 1's static published-only display into a full Draft → Published → Deprecated versioned-entity editor. Backend (SQL migration + 10 procs + tests) → NQs → entity script → view restructure.

**Architecture summary** (full detail in spec §3–§7):

- **Three-state lifecycle** Bom: Draft (`PublishedAt NULL, DeprecatedAt NULL`) → Published (`PublishedAt SET`) → Deprecated (`DeprecatedAt SET`). One draft per ParentItemId enforced via filtered UNIQUE index.
- **Bundled save pattern** for line reconciliation (per `project_mpp_bundled_save_pattern.md` instance-editor variant — BomLine has no DeprecatedAt, so reconciliation is physical DELETE / UPDATE / INSERT, SortOrder derived from array index).
- **Lifecycle procs are discrete:** `_CreateNewVersion`, `_SaveDraft`, `_Publish`, `_Deprecate`, `_DiscardDraft`. Reads: `_ListByParentItem`, `_Get`, `_GetActiveForItem`, `BomLine_ListByBom`, `Item_ListAvailableForBom`, `Uom_List`.
- **In-tab lifecycle actions** (`Save Draft` / `Publish` / `Discard Draft` / `Deprecate` per-version) — isolated from page-level Item Save.
- **BomLineRow sub-view** depth-2 embed; page-scoped messages from row up to parent ItemMaster handle line mutations, NOT relying on bidi through two embed boundaries.

**Tech stack:** SQL Server 2022; Ignition Perspective 8.3 file-based; NQs at v2 resource schema with Designer-canonical sqlType enum; entity scripts route through `Common.Db.*` + `Common.Util._currentAppUserId` + `Common.Ui.notifyResult` + `Common.Notify.toast`; bidirectional Property bindings on Embedded View `props.params.value` (R1 mechanism); page-scoped Perspective messaging for deep embed → parent flows; `ia.container.flex`, `ia.input.dropdown`, `ia.input.text-field` (numeric mode), `ia.input.button`, `ia.input.checkbox`, `ia.display.label`, `ia.display.flex-repeater`.

**Hard prerequisites (verify before Task 1):**

- Phase 2 has landed (Agent B): `BlueRidge.Parts.Item` entity script with `search` and `getOne`; parent ItemMaster reads from DB on row-click; R1 verdict known (HOLDS or FAILS).
  - If R1 FAILS: **DO NOT proceed**. The BOMs tab design assumes `view.params.value` bidi on a complex Object. Re-design the editDraft.boms slice as page-scoped messages from the BOMs tab up to the parent. Pause and consult Jacques.
  - If R1 HOLDS: proceed.
- 937+ SQL tests passing baseline before Task 1.
- Reset script `Reset-DevDatabase.ps1` works against the dev DB.

**Spec:** `docs/superpowers/specs/2026-05-20-item-master-boms-design.md`

---

## File Inventory

**SQL — created:**

```
sql/migrations/versioned/
  0016_parts_bom_unique_draft.sql                                  [NEW]

sql/migrations/repeatable/
  R__Parts_Bom_ListByParentItem.sql                                [NEW]
  R__Parts_Bom_Get.sql                                             [NEW]
  R__Parts_BomLine_ListByBom.sql                                   [NEW]
  R__Parts_Bom_GetActiveForItem.sql                                [NEW]
  R__Parts_Bom_CreateNewVersion.sql                                [NEW]
  R__Parts_Bom_SaveDraft.sql                                       [NEW]
  R__Parts_Bom_Publish.sql                                         [NEW]
  R__Parts_Bom_Deprecate.sql                                       [NEW]
  R__Parts_Bom_DiscardDraft.sql                                    [NEW]
  R__Parts_Item_ListAvailableForBom.sql                            [NEW]
  R__Parts_Uom_List.sql                                            [NEW — verify if exists from Phase 2]

sql/tests/00YY_Bom/                                                [NEW folder; YY = next free]
  010_Bom_CreateNewVersion.sql                                     [NEW]
  020_Bom_SaveDraft.sql                                            [NEW]
  030_Bom_Publish.sql                                              [NEW]
  040_Bom_Deprecate.sql                                            [NEW]
  050_Bom_DiscardDraft.sql                                         [NEW]
  060_Bom_Reads.sql                                                [NEW]
  070_Bom_GetActiveForItem.sql                                     [NEW]
```

**Ignition — created:**

```
ignition/projects/MPP_Config/com.inductiveautomation.perspective/named-query/parts/
  Bom_ListByParentItem/{resource.json, query.sql}                  [NEW]
  Bom_Get/{resource.json, query.sql}                               [NEW]
  BomLine_ListByBom/{resource.json, query.sql}                     [NEW]
  Bom_GetActiveForItem/{resource.json, query.sql}                  [NEW]
  Bom_CreateNewVersion/{resource.json, query.sql}                  [NEW]
  Bom_SaveDraft/{resource.json, query.sql}                         [NEW]
  Bom_Publish/{resource.json, query.sql}                           [NEW]
  Bom_Deprecate/{resource.json, query.sql}                         [NEW]
  Bom_DiscardDraft/{resource.json, query.sql}                      [NEW]
  Item_ListAvailableForBom/{resource.json, query.sql}              [NEW]
  Uom_List/{resource.json, query.sql}                              [NEW — if not present]

ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/Bom/
  code.py                                                          [NEW]
  resource.json                                                    [NEW]

ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/
  Components/Parts/ItemMaster/Boms/BomLineRow/
    resource.json                                                  [NEW]
    view.json                                                      [NEW]

  Components/Popups/ConfirmDeprecate/
    resource.json                                                  [NEW]
    view.json                                                      [NEW]

  Components/Popups/ConfirmDiscardDraft/
    resource.json                                                  [NEW]
    view.json                                                      [NEW]
```

**Ignition — modified (existing-view edits — see "File-edit boundary" callouts in each task):**

```
ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/
  Components/Parts/ItemMaster/Boms/view.json                       [MODIFY — substantial restructure]
  Views/Parts/ItemMaster/view.json                                 [MODIFY — add 6 message handlers]
```

---

## Conventions This Plan Follows

- **resource.json** for every new Ignition resource:
  ```json
  {
    "scope": "G",
    "version": 1,
    "restricted": false,
    "overridable": true,
    "files": ["view.json"],
    "attributes": {
      "lastModification": {
        "actor": "Jacques Potgieter",
        "timestamp": "2026-05-20T12:00:00Z"
      }
    }
  }
  ```
  For NQs: `"files": ["query.sql"]` and the resource.json `version: 2` per `feedback_ignition_nq_resource_schema.md`.

- **NQ Designer sqlType enum:**
  | sqlType | Designer name | DB type |
  |---|---|---|
  | 3 | Int8 | BIGINT |
  | 6 | Boolean | BIT |
  | 7 | String | NVARCHAR |
  | 8 | DateTime | DATETIME2 |

- **SP conventions** per `sql/scripts/_TEMPLATE_stored_procedure.sql`:
  - Three-tier error hierarchy.
  - `RAISERROR` (not `THROW`) in CATCH with nested TRY/CATCH for failure logging.
  - Schema-qualify all DB references.
  - No OUTPUT params (Ignition JDBC restriction per CLAUDE.md). Status / Message / NewId as `DECLARE @… BIT/NVARCHAR/BIGINT` locals, single `SELECT @Status, @Message, @NewId` at exit.
  - Audit writers (`Audit.Audit_LogConfigChange`, `Audit.Audit_LogFailure`) emit no result set.

- **Entity script conventions** per `ignition-context-pack/03_script_python.md`:
  - Route every DB call through `BlueRidge.Common.Db.execList` / `execOne` / `execMutation`.
  - Log via `BlueRidge.Common.Util.log(...)` (auto-fills calling module + function).
  - Auto-fill `appUserId` from `BlueRidge.Common.Util._currentAppUserId()`.
  - Mutation handler functions named `handle*`; read functions named `get*` / `listBy*` etc.
  - Wrap reads in try/except and fire an error toast via `BlueRidge.Common.Notify.toast` on failure.

- **scan.ps1** must be run at project root after writing any new Ignition resource. POST with both `X-Ignition-API-Token` and `Content-Type: application/json` headers — see `feedback_ignition_gateway_scan.md`.

- **Commit messages** follow `feat(item-master-boms): <one-liner>`. Omit `Co-Authored-By: Claude` trailer per `feedback_no_claude_coauthor.md`.

- **File-edit boundary** per `feedback_ignition_view_edit_boundary.md`:
  - New view files (`BomLineRow`, `ConfirmDeprecate`, `ConfirmDiscardDraft`) → safe to file-edit on disk.
  - **Existing view files (`Boms/view.json` and parent `ItemMaster/view.json`) → prefer Designer-step instructions for Jacques to apply.** When substantial restructure is needed (the Boms view is substantially rewritten), the plan's task may issue file-edit instructions but flags the risk and asks Jacques to confirm pull / Designer-cache state before scan.

---

## Phase Sequencing

```
Phase 6.A  SQL backend (migration + 10 procs + 7 test files)
   │       Test suite green at the end of each proc batch.
   │
   ├──────────────────────────────────────────┐
   │                                          │
   ▼                                          ▼
Phase 6.B  Ignition NQs                  (Phase 6.A must be GREEN before B starts)
   │       11 new NQs.
   │
   ▼
Phase 6.C  Entity script (BlueRidge.Parts.Bom)
   │       9 functions (4 reads + 5 mutations).
   │
   ▼
Phase 6.D  New popup views (ConfirmDeprecate, ConfirmDiscardDraft)
   │       (Optional — only if not already extracted from prior work.)
   │
   ▼
Phase 6.E  BomLineRow sub-view (NEW file — safe file-edit)
   │
   ▼
Phase 6.F  Boms tab view restructure (existing-view edit; Designer or careful file-edit)
   │
   ▼
Phase 6.G  Parent ItemMaster message handlers (existing-view edit)
   │
   ▼
Phase 6.H  Designer smoke test (driven by Jacques; agent provides checklist)
```

**Each phase's tasks must complete in order. Tasks within a phase that don't share files may run in parallel during execution (e.g., 10 repeatable procs are independent of each other once the migration is in place).**

---

## Phase 6.A — SQL Backend

### Task 1: Migration `00XX_parts_bom_unique_draft.sql`

**Files:**
- Create: `sql/migrations/versioned/0016_parts_bom_unique_draft.sql`

- [ ] **Step 1:** Landed as `0016` (0015 taken by Routes Phase 5 `0015_audit_add_event_type_deleted.sql`).
- [ ] **Step 2:** Write migration file:

```sql
-- =============================================
-- Migration: 0016_parts_bom_unique_draft.sql
-- Author:    Blue Ridge Automation
-- Created:   2026-05-20
-- Purpose:   Enforce one active Draft Bom per ParentItemId.
-- =============================================

CREATE UNIQUE INDEX UX_Bom_ActiveDraft
    ON Parts.Bom (ParentItemId)
    WHERE PublishedAt IS NULL AND DeprecatedAt IS NULL;
GO

INSERT INTO Audit.SchemaVersion (VersionNumber, AppliedAt, Description)
VALUES ('00XX', SYSUTCDATETIME(), 'Filtered UNIQUE index on Parts.Bom(ParentItemId) for one active Draft per Item');
GO
```

- [ ] **Step 3:** Run `Reset-DevDatabase.ps1` — confirm migration applies clean.
- [ ] **Step 4:** Verify index exists:
  ```sql
  SELECT name FROM sys.indexes WHERE name = 'UX_Bom_ActiveDraft';
  ```

### Task 2: `R__Parts_Bom_ListByParentItem.sql`

**Files:**
- Create: `sql/migrations/repeatable/R__Parts_Bom_ListByParentItem.sql`

- [ ] **Step 1:** Author proc per `_TEMPLATE_stored_procedure.sql`. Shape:
  ```sql
  CREATE OR ALTER PROCEDURE Parts.Bom_ListByParentItem
      @ParentItemId       BIGINT,
      @IncludeDeprecated  BIT = 0
  AS
  BEGIN
      SET NOCOUNT ON;
      SELECT
          b.Id,
          b.VersionNumber,
          b.EffectiveFrom,
          b.PublishedAt,
          b.DeprecatedAt,
          u.UserName + ' (' + u.DisplayName + ')' AS CreatedByName,
          b.CreatedAt,
          (SELECT COUNT(*) FROM Parts.BomLine bl WHERE bl.BomId = b.Id) AS LineCount,
          CASE
              WHEN b.PublishedAt IS NULL AND b.DeprecatedAt IS NULL THEN 'Draft'
              WHEN b.PublishedAt IS NOT NULL AND b.DeprecatedAt IS NULL THEN 'Published'
              ELSE 'Deprecated'
          END AS [Status]
      FROM Parts.Bom b
      LEFT JOIN dbo.AppUser u ON u.Id = b.CreatedByUserId
      WHERE b.ParentItemId = @ParentItemId
        AND (@IncludeDeprecated = 1 OR b.DeprecatedAt IS NULL)
      ORDER BY
          CASE WHEN b.PublishedAt IS NULL AND b.DeprecatedAt IS NULL THEN 0 ELSE 1 END,
          b.EffectiveFrom DESC,
          b.VersionNumber DESC;
  END;
  GO
  ```
- [ ] **Step 2:** Apply via `Reset-DevDatabase.ps1` or `sqlcmd -i R__Parts_Bom_ListByParentItem.sql`.
- [ ] **Step 3:** Smoke from Script Console / SSMS:
  ```sql
  EXEC Parts.Bom_ListByParentItem @ParentItemId = 1, @IncludeDeprecated = 0;
  ```
  Expected: 0 rows (no BOMs seeded yet) — proc runs without error.

### Task 3: `R__Parts_Bom_Get.sql`

- [ ] Author per template. Single SELECT returning the Bom header row joined to `AppUser` for `CreatedByName`. Returns 0 rows for a non-existent Id (per Ignition JDBC convention: empty = not found, no fabricated 404).
- [ ] Apply + smoke.

### Task 4: `R__Parts_BomLine_ListByBom.sql`

- [ ] Author per template. SELECT BomLine rows joined to `Parts.Item` for PartNumber + Description, joined to `Parts.Uom` for UomCode. ORDER BY SortOrder ASC.
- [ ] Apply + smoke.

### Task 5: `R__Parts_Bom_GetActiveForItem.sql`

- [ ] Author per spec §4 SQL block:
  ```sql
  SELECT TOP 1 Id, VersionNumber, EffectiveFrom, PublishedAt, DeprecatedAt
  FROM Parts.Bom
  WHERE ParentItemId = @ParentItemId
    AND PublishedAt IS NOT NULL
    AND DeprecatedAt IS NULL
    AND EffectiveFrom <= ISNULL(@AsOfDate, SYSUTCDATETIME())
  ORDER BY EffectiveFrom DESC;
  ```
- [ ] Apply + smoke.

### Task 6: `R__Parts_Bom_CreateNewVersion.sql`

This is the first mutation proc. Shape closely mirrors `R__Location_LocationTypeDefinition_SaveAll.sql`'s structure but is simpler (no JSON delta parsing; just clone-or-new).

- [ ] **Step 1:** Author proc. Params:
  - `@ParentItemId BIGINT`
  - `@SourceBomId BIGINT = NULL` (NULL = blank draft; non-NULL = clone lines from this Bom)
  - `@EffectiveFrom DATETIME2 = NULL` (NULL = SYSUTCDATETIME() + 30 days)
  - `@AppUserId BIGINT`

  Logic:
  1. Validate `@ParentItemId` exists in `Parts.Item` and is not deprecated. Fail with friendly Message if not.
  2. If `@SourceBomId` non-NULL: validate it's a `Parts.Bom` row belonging to `@ParentItemId` (cross-link check).
  3. Default `@EffectiveFrom = DATEADD(DAY, 30, SYSUTCDATETIME())` if NULL.
  4. BEGIN TRANSACTION.
  5. `INSERT INTO Parts.Bom (ParentItemId, VersionNumber, EffectiveFrom, PublishedAt, DeprecatedAt, CreatedByUserId, CreatedAt) VALUES (@ParentItemId, ISNULL((SELECT MAX(VersionNumber) FROM Parts.Bom WHERE ParentItemId = @ParentItemId), 0) + 1, @EffectiveFrom, NULL, NULL, @AppUserId, SYSUTCDATETIME());`
  6. `SET @NewId = SCOPE_IDENTITY();`
  7. If `@SourceBomId` non-NULL: `INSERT INTO Parts.BomLine (BomId, ChildItemId, QtyPer, UomId, SortOrder) SELECT @NewId, ChildItemId, QtyPer, UomId, SortOrder FROM Parts.BomLine WHERE BomId = @SourceBomId ORDER BY SortOrder;`
  8. `EXEC Audit.Audit_LogConfigChange ... @LogEventTypeCode = N'Created', ...`
  9. COMMIT.
  10. `SELECT @Status, @Message, @NewId;`

  CATCH: rollback, log failure, RAISERROR, return Status=0.

  **Filtered-UNIQUE-violation handling**: a parallel CreateNewVersion call for the same ParentItemId triggers a unique-constraint violation on `UX_Bom_ActiveDraft`. Catch this specific case (`ERROR_NUMBER() = 2601 OR 2627`) and return Status=0 with friendly Message: "A draft BOM already exists for this Item. Open it or discard it before creating a new version."

- [ ] **Step 2:** Apply + smoke from Script Console:
  ```sql
  EXEC Parts.Bom_CreateNewVersion
       @ParentItemId = 1,
       @SourceBomId = NULL,
       @EffectiveFrom = NULL,
       @AppUserId = 2;
  -- Expected: Status=1, NewId = <some new BIGINT>
  ```

### Task 7: `R__Parts_Bom_SaveDraft.sql`

This is the bundled save. Closely mirrors `R__Location_LocationTypeDefinition_SaveAll.sql`'s shape; key difference is line reconciliation is **physical** (DELETE/UPDATE/INSERT) per the instance-editor variant.

- [ ] **Step 1:** Author proc. Params:
  - `@Id BIGINT` (the draft Bom's Id)
  - `@EffectiveFrom DATETIME2`
  - `@LinesJson NVARCHAR(MAX) = N'[]'`
  - `@AppUserId BIGINT`

  Logic flow per `project_mpp_bundled_save_pattern.md`:
  1. Tier-1 validation: `@Id`, `@EffectiveFrom`, `@AppUserId` not NULL.
  2. Verify target Bom exists, is Draft (`PublishedAt IS NULL AND DeprecatedAt IS NULL`). Fail "Cannot edit a published or deprecated BOM" otherwise.
  3. Parse `@LinesJson` into `@Incoming` table via OPENJSON. Columns: `RowIndex INT, Id BIGINT NULL, ChildItemId BIGINT NULL, QtyPer DECIMAL(10,4) NULL, UomId BIGINT NULL`.
  4. Validate every incoming row has `ChildItemId`, `QtyPer`, `UomId` non-NULL.
  5. Validate `ChildItemId != @ParentItemId` for every row (look up `@ParentItemId` from `Parts.Bom WHERE Id = @Id`).
  6. Within-batch duplicate ChildItemId check — flagged as Open Q A2 in spec. **Default: allow duplicates.** Skip the check unless A2 resolves to "reject."
  7. Validate every incoming `ChildItemId` exists in `Parts.Item` (FK check, but explicit for friendly message).
  8. Validate every incoming `UomId` exists in `Parts.Uom`.
  9. Validate every incoming row with non-NULL Id is an active BomLine on this Bom (cross-link).
  10. Capture pre-mutation state for audit (header + lines as JSON).
  11. BEGIN TRANSACTION.
  12. UPDATE Bom header: `SET EffectiveFrom = @EffectiveFrom`.
  13. DELETE BomLine rows for `BomId = @Id` whose Id is NOT in `@Incoming`.
  14. UPDATE BomLine rows where Id matches `@Incoming`: set `ChildItemId, QtyPer, UomId, SortOrder = RowIndex`.
  15. INSERT BomLine rows for `@Incoming` rows with NULL Id: `ChildItemId, QtyPer, UomId, SortOrder = RowIndex`.
  16. Capture post-mutation state for audit.
  17. `EXEC Audit.Audit_LogConfigChange @LogEventTypeCode = N'Updated', @OldValue = pre, @NewValue = post, ...`
  18. COMMIT.
  19. `SELECT @Status=1, @Message="Saved draft with N line(s).", @NewId = @Id;`

- [ ] **Step 2:** Apply + smoke. Test the three reconciliation paths:
  ```sql
  -- (A) Create a draft via Task 6, get NewId = <bomId>
  -- (B) Save 2 lines (both new — Id NULL):
  EXEC Parts.Bom_SaveDraft
       @Id = <bomId>,
       @EffectiveFrom = '2026-08-01',
       @LinesJson = N'[{"Id":null,"ChildItemId":2,"QtyPer":1,"UomId":1},{"Id":null,"ChildItemId":3,"QtyPer":2,"UomId":1}]',
       @AppUserId = 2;
  -- (C) Re-save with 2 lines reordered + qty change on first (Id of first/second from a SELECT):
  -- (D) Re-save with line 2 removed (only first row in JSON) — expect physical delete
  ```

### Task 8: `R__Parts_Bom_Publish.sql`

- [ ] **Step 1:** Author proc. Params:
  - `@Id BIGINT`
  - `@EffectiveFrom DATETIME2 = NULL` (optional override if save-and-publish in one shot)
  - `@LinesJson NVARCHAR(MAX) = NULL` (optional — if non-NULL, invokes save logic first)
  - `@AppUserId BIGINT`

  Logic:
  1. Validate target Bom exists, is Draft.
  2. If `@LinesJson` non-NULL: internally execute the same reconciliation logic as `_SaveDraft` (extract into a private helper or inline; the simpler path is to inline since SQL Server SPs don't compose neatly).
  3. Validate at least one BomLine exists post-save.
  4. Validate `EffectiveFrom` non-NULL (use override if passed, else existing).
  5. BEGIN TRANSACTION.
  6. UPDATE Bom: `SET PublishedAt = SYSUTCDATETIME(), EffectiveFrom = ISNULL(@EffectiveFrom, EffectiveFrom)`.
  7. Audit log: `@LogEventTypeCode = N'Updated', @Description = N'Published.', @NewValue = full bundle JSON`.
  8. COMMIT.
  9. `SELECT Status=1, Message="Published v<N>.", NewId = @Id;`

- [ ] **Step 2:** Apply + smoke. Test scenarios:
  - Publish zero-line BOM → Status=0, friendly message.
  - Publish with missing EffectiveFrom → Status=0.
  - Publish happy path → Status=1, verify `PublishedAt IS NOT NULL` afterwards.
  - Republish already-published → Status=0, "Already published."

### Task 9: `R__Parts_Bom_Deprecate.sql`

- [ ] **Step 1:** Author proc. Params: `@Id BIGINT`, `@AppUserId BIGINT`.

  Logic:
  1. Validate target Bom exists, is Published (`PublishedAt IS NOT NULL AND DeprecatedAt IS NULL`).
  2. **Active-WO guard (TODO Arc 2):** wrap in `-- TODO Arc 2:` comment. Stub: `-- IF EXISTS (SELECT 1 FROM Workorder.WorkOrder WHERE BomId = @Id AND Status IN ('Open','InProgress')) RAISERROR(...)`.
  3. UPDATE Bom SET DeprecatedAt = SYSUTCDATETIME().
  4. Audit log Deprecated event.
  5. `SELECT Status=1, Message="Deprecated v<N>.";`

  Idempotent re-deprecate: return Status=1 Message="Already deprecated." if already in deprecated state.

- [ ] **Step 2:** Apply + smoke.

### Task 10: `R__Parts_Bom_DiscardDraft.sql`

- [ ] **Step 1:** Author proc. Params: `@Id BIGINT`, `@AppUserId BIGINT`.

  Logic:
  1. Validate target Bom exists and is Draft.
  2. Capture pre-delete state for audit (`@OldValue = full bundle JSON`).
  3. BEGIN TRANSACTION.
  4. DELETE Parts.BomLine WHERE BomId = @Id.
  5. DELETE Parts.Bom WHERE Id = @Id.
  6. Audit log: `@LogEventTypeCode = N'Deleted', @OldValue = pre, @NewValue = NULL, @Description = N'Draft discarded.'`.
  7. COMMIT.
  8. `SELECT Status=1, Message="Draft discarded.";`

- [ ] **Step 2:** Apply + smoke.

### Task 11: `R__Parts_Item_ListAvailableForBom.sql`

- [ ] **Step 1:** Author proc. Params: `@ParentItemId BIGINT`, `@SearchText NVARCHAR(50) = NULL`.

  SELECT `Item` rows + joined `Uom` for default UOM, filtering: `DeprecatedAt IS NULL`, `Id != @ParentItemId`. If `@SearchText` provided, apply `WHERE PartNumber LIKE @SearchText + '%' OR Description LIKE '%' + @SearchText + '%'`. ORDER BY PartNumber ASC.

- [ ] **Step 2:** Apply + smoke.

### Task 12: `R__Parts_Uom_List.sql`

- [ ] **Step 1:** Check whether the proc already exists from Phase 2 (Agent B) or earlier work. If so, skip.
- [ ] **Step 2:** If absent: simple `SELECT Id, Code, Name FROM Parts.Uom WHERE DeprecatedAt IS NULL ORDER BY Code`.

### Task 13: Test files (7 files)

Per spec §6.3. Each file uses the project's test harness (assert/raise pattern; mirror existing tests in `sql/tests/`).

- [ ] **Step 1:** Create `sql/tests/00YY_Bom/` directory. Pick `YY` as the next free TestSet number (check existing `sql/tests/` listings).
- [ ] **Step 2:** Author `010_Bom_CreateNewVersion.sql`. Scenarios:
  - 1.1 Happy path: new Item, no source Bom → creates v1 draft.
  - 1.2 Clone-create: existing Published v1 → CreateNewVersion(@SourceBomId=v1) → v2 draft has same lines as v1.
  - 1.3 Default EffectiveFrom: today + 30 days when @EffectiveFrom NULL.
  - 1.4 Dup-draft rejection: try to CreateNewVersion when draft already exists → Status=0.
  - 1.5 Invalid ParentItem: deprecated Item → Status=0.
  - 1.6 Audit row written.

- [ ] **Step 3:** Author `020_Bom_SaveDraft.sql`. Scenarios:
  - 2.1 Add 2 lines on empty draft.
  - 2.2 Edit qty on existing line.
  - 2.3 Remove a line (physical delete confirmed by row count).
  - 2.4 Reorder lines (SortOrder reconciliation).
  - 2.5 Rejection: SaveDraft on Published Bom → Status=0.
  - 2.6 Rejection: SaveDraft on Deprecated Bom → Status=0.
  - 2.7 Rejection: self-reference (ChildItemId = ParentItemId).
  - 2.8 Rejection: missing UomId / ChildItemId in JSON.
  - 2.9 Rejection: invalid UomId.

- [ ] **Step 4:** Author `030_Bom_Publish.sql`. Scenarios:
  - 3.1 Happy path with prior _SaveDraft.
  - 3.2 Save-and-publish in one shot (LinesJson passed).
  - 3.3 Rejection: zero lines.
  - 3.4 Rejection: missing EffectiveFrom.
  - 3.5 Rejection: republish already-published.
  - 3.6 Prior published version NOT auto-deprecated (assert prior version still has DeprecatedAt = NULL).

- [ ] **Step 5:** Author `040_Bom_Deprecate.sql`. Scenarios:
  - 4.1 Happy path: Published → Deprecated.
  - 4.2 Idempotent: Deprecate already-deprecated → Status=1 Message="Already deprecated."
  - 4.3 Rejection: Deprecate a draft → Status=0.

- [ ] **Step 6:** Author `050_Bom_DiscardDraft.sql`. Scenarios:
  - 5.1 Happy path: Draft physically deleted + BomLines cascade.
  - 5.2 Rejection: DiscardDraft on Published.

- [ ] **Step 7:** Author `060_Bom_Reads.sql`. Scenarios:
  - 6.1 `_ListByParentItem` ordering: Drafts first, then Published DESC by EffectiveFrom.
  - 6.2 `_ListByParentItem` IncludeDeprecated=1 shows deprecated rows.
  - 6.3 `_Get` non-existent Id → empty rowset.
  - 6.4 `BomLine_ListByBom` ordering by SortOrder.

- [ ] **Step 8:** Author `070_Bom_GetActiveForItem.sql`. Scenarios:
  - 7.1 Future-dated v2 not picked (EffectiveFrom > now).
  - 7.2 Past-dated v2 picked when v1 also exists.
  - 7.3 Deprecated excluded.
  - 7.4 No versions returns empty rowset.

- [ ] **Step 9:** Run full test suite via `Reset-DevDatabase.ps1`. Confirm 937 → 970+ passing.

- [ ] **Step 10:** Commit Phase 6.A in batches (one commit per proc or per logical group).
  ```bash
  git add sql/migrations/versioned/00XX_parts_bom_unique_draft.sql
  git commit -m "feat(item-master-boms): migration — UNIQUE active-draft index on Parts.Bom"

  git add sql/migrations/repeatable/R__Parts_Bom_*.sql sql/migrations/repeatable/R__Parts_BomLine_ListByBom.sql sql/migrations/repeatable/R__Parts_Item_ListAvailableForBom.sql sql/migrations/repeatable/R__Parts_Uom_List.sql
  git commit -m "feat(item-master-boms): SP layer — 11 procs for Bom CRUD + versioning"

  git add sql/tests/00YY_Bom/
  git commit -m "test(item-master-boms): 7 test files covering Bom procs (33+ scenarios)"
  ```

---

## Phase 6.B — Ignition Named Queries

11 new NQs at `ignition/projects/MPP_Config/com.inductiveautomation.perspective/named-query/parts/`. All v2 resource.json schema. Designer-canonical sqlType enum (3 = Int8 / BIGINT; 6 = Boolean / BIT; 7 = String / NVARCHAR; 8 = DateTime / DATETIME2).

Each NQ is one folder with `resource.json` + `query.sql`. The `query.sql` contains `EXEC Parts.Bom_<Name> @param1 = :param1, ...` lines per the project's NQ-binding pattern.

### Task 14: NQ scaffolding

For each NQ, create the folder and the two files. **All new files — safe to file-edit.**

- [ ] `Bom_ListByParentItem` — params: `parentItemId` (sqlType 3), `includeDeprecated` (sqlType 6, default `false`)
- [ ] `Bom_Get` — `id` (3)
- [ ] `BomLine_ListByBom` — `bomId` (3)
- [ ] `Bom_GetActiveForItem` — `parentItemId` (3), `asOfDate` (8, nullable=true)
- [ ] `Bom_CreateNewVersion` — `parentItemId` (3), `sourceBomId` (3, nullable=true), `effectiveFrom` (8, nullable=true), `appUserId` (3)
- [ ] `Bom_SaveDraft` — `id` (3), `effectiveFrom` (8), `linesJson` (7), `appUserId` (3)
- [ ] `Bom_Publish` — `id` (3), `effectiveFrom` (8, nullable=true), `linesJson` (7, nullable=true), `appUserId` (3)
- [ ] `Bom_Deprecate` — `id` (3), `appUserId` (3)
- [ ] `Bom_DiscardDraft` — `id` (3), `appUserId` (3)
- [ ] `Item_ListAvailableForBom` — `parentItemId` (3), `searchText` (7, nullable=true)
- [ ] `Uom_List` — (no params; skip if exists from Phase 2)

**Reference for resource.json sqlType structure:** `feedback_ignition_nq_resource_schema.md`. Existing NQ to clone shape from: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/named-query/location/LocationTypeDefinition_SaveAll/resource.json` (NVARCHAR-with-JSON pattern matches Bom_SaveDraft / Bom_Publish).

- [ ] **Step 1:** Author all 11 (or 10 if Uom_List exists) folders + files.
- [ ] **Step 2:** Run `.\scan.ps1` at project root. Expected HTTP 200.
- [ ] **Step 3:** Designer pull. Open each new NQ. Run the read NQs with manual params (Designer Test interface). For mutation NQs, smoke at least one (e.g., `Bom_CreateNewVersion` with `@parentItemId = 1, @appUserId = 2`).
- [ ] **Step 4:** Commit:
  ```bash
  git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/named-query/parts/Bom_* ignition/projects/MPP_Config/com.inductiveautomation.perspective/named-query/parts/BomLine_ListByBom/ ignition/projects/MPP_Config/com.inductiveautomation.perspective/named-query/parts/Item_ListAvailableForBom/
  git commit -m "feat(item-master-boms): 10 named queries for Bom CRUD + reads"
  ```

---

## Phase 6.C — Entity Script

### Task 15: `BlueRidge.Parts.Bom` module

**Files:**
- Create: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/Bom/resource.json`
- Create: `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/Bom/code.py`

- [ ] **Step 1:** Write `resource.json` (script-python convention; copy shape from a sibling module like `BlueRidge/Oee/DowntimeReasonCode/resource.json`).

- [ ] **Step 2:** Write `code.py`. Skeleton:

  ```python
  """
  BlueRidge.Parts.Bom — versioned BOM entity for the Item Master BOMs tab.

  All DB calls route through BlueRidge.Common.Db.*.
  AppUserId auto-filled from BlueRidge.Common.Util._currentAppUserId().
  Read functions wrap exceptions in toasts via BlueRidge.Common.Notify.toast.
  """

  import BlueRidge.Common.Db as _Db
  import BlueRidge.Common.Util as _Util
  import BlueRidge.Common.Notify as _Notify

  _NQ = 'parts/'

  # ---------- Reads ----------

  def listByParentItem(parentItemId, includeDeprecated=False):
      try:
          rows = _Db.execList(_NQ + 'Bom_ListByParentItem',
                              {'parentItemId': parentItemId,
                               'includeDeprecated': bool(includeDeprecated)})
          return rows
      except Exception as e:
          _Util.log('listByParentItem failed', e)
          _Notify.toast('BOM read failed', str(e), 'error', 8)
          return []

  def getOne(bomId):
      """Returns {header: {...}, lines: [...]} bundle."""
      try:
          header = _Db.execOne(_NQ + 'Bom_Get', {'id': bomId})
          if not header:
              return None
          lines = _Db.execList(_NQ + 'BomLine_ListByBom', {'bomId': bomId})
          return {'header': header, 'lines': lines}
      except Exception as e:
          _Util.log('getOne failed', e)
          _Notify.toast('BOM read failed', str(e), 'error', 8)
          return None

  def listAvailableItemsForBom(parentItemId, searchText=None):
      try:
          return _Db.execList(_NQ + 'Item_ListAvailableForBom',
                              {'parentItemId': parentItemId,
                               'searchText': searchText})
      except Exception as e:
          _Util.log('listAvailableItemsForBom failed', e)
          _Notify.toast('Item list failed', str(e), 'error', 8)
          return []

  def listUoms():
      try:
          return _Db.execList(_NQ + 'Uom_List', {})
      except Exception as e:
          _Util.log('listUoms failed', e)
          return []

  # ---------- Mutations ----------

  def handleCreateNewVersion(parentItemId, sourceBomId=None, effectiveFrom=None):
      result = _Db.execMutation(_NQ + 'Bom_CreateNewVersion', {
          'parentItemId': parentItemId,
          'sourceBomId':  sourceBomId,
          'effectiveFrom': effectiveFrom,
          'appUserId':    _Util._currentAppUserId(),
      })
      return result

  def handleSaveDraft(bomId, effectiveFrom, lines):
      import system
      linesJson = system.util.jsonEncode(lines or [])
      result = _Db.execMutation(_NQ + 'Bom_SaveDraft', {
          'id':            bomId,
          'effectiveFrom': effectiveFrom,
          'linesJson':     linesJson,
          'appUserId':     _Util._currentAppUserId(),
      })
      return result

  def handlePublish(bomId, effectiveFrom=None, lines=None):
      import system
      linesJson = system.util.jsonEncode(lines) if lines is not None else None
      result = _Db.execMutation(_NQ + 'Bom_Publish', {
          'id':            bomId,
          'effectiveFrom': effectiveFrom,
          'linesJson':     linesJson,
          'appUserId':     _Util._currentAppUserId(),
      })
      return result

  def handleDeprecate(bomId):
      result = _Db.execMutation(_NQ + 'Bom_Deprecate', {
          'id':         bomId,
          'appUserId':  _Util._currentAppUserId(),
      })
      return result

  def handleDiscardDraft(bomId):
      result = _Db.execMutation(_NQ + 'Bom_DiscardDraft', {
          'id':         bomId,
          'appUserId':  _Util._currentAppUserId(),
      })
      return result

  # ---------- Helpers ----------

  def emptyLine():
      return {
          'id':            None,
          'childItemId':   None,
          'partNumber':    '',
          'componentName': '',
          'qtyPer':        1,
          'uomId':         None,
          'uomCode':       '',
      }
  ```

  Note: `_Util.log` and `_Util._currentAppUserId` are the established Common helpers per the 2026-05-14 convention rectification pass.

- [ ] **Step 3:** Run `.\scan.ps1`.

- [ ] **Step 4:** Smoke from Designer Script Console:
  ```python
  import BlueRidge.Parts.Bom as B
  print(B.listByParentItem(1, False))
  result = B.handleCreateNewVersion(1, None, None)
  print(result)
  ```

- [ ] **Step 5:** Commit:
  ```bash
  git add ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/Bom/
  git commit -m "feat(item-master-boms): BlueRidge.Parts.Bom entity script (reads + 5 mutations)"
  ```

---

## Phase 6.D — Confirm Popups

### Task 16: `ConfirmDeprecate` and `ConfirmDiscardDraft`

These extend the `ConfirmUnsaved` popup pattern per `project_mpp_confirm_unsaved_pattern.md`.

- [ ] **Step 1:** Check whether either popup already exists. If yes, skip.
- [ ] **Step 2:** Author `ConfirmDeprecate/{resource.json, view.json}`. Params: `title`, `message`, `entityLabel`, `replyMessage` (default `confirmDeprecateResult`), `popupId` (default `mpp-confirm-deprecate`). Three buttons: Cancel / (right) Deprecate. Style classes `btn btn-sm` for Cancel, `btn btn-danger btn-sm` for Deprecate.
- [ ] **Step 3:** Author `ConfirmDiscardDraft/{resource.json, view.json}`. Similar shape; primary button label "Discard" (red-danger style).
- [ ] **Step 4:** Run `.\scan.ps1`.
- [ ] **Step 5:** Commit:
  ```bash
  git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/ConfirmDeprecate/ ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/ConfirmDiscardDraft/
  git commit -m "feat(popups): ConfirmDeprecate + ConfirmDiscardDraft (reusable)"
  ```

---

## Phase 6.E — BomLineRow Sub-view

### Task 17: New file — safe to file-edit.

**Files:**
- Create: `views/BlueRidge/Components/Parts/ItemMaster/Boms/BomLineRow/{resource.json, view.json}`

- [ ] **Step 1:** Write `resource.json` (standard scope G v1).
- [ ] **Step 2:** Write `view.json` per spec §7.2. Layout:
  - root `ia.container.flex` direction row, alignItems center, gap 8px, padding 6px 10px, borderBottom 1px solid var(--mpp-border-subtle).
  - 6 columns as described in spec §7.2: ColIndex, ColArrows, ColItemPicker, ColComponent, ColQty, ColUom, ColRemove.
  - **Conditional rendering**: use `meta.visible` (not `position.display`) on the ColArrows and ColRemove columns based on `{view.params.mode} = 'draft'`. This is the legitimate table-row exception per `feedback_ignition_meta_visible_in_tables.md`.
  - **Conditional widgets**: in ColItemPicker, ColQty, ColUom — two children, one for "edit mode" (dropdown / numeric input) gated `meta.visible = if({view.params.mode} = 'draft', true, false)` and one for "display mode" (label) gated inverse.
  - **All click events** use `scope: "G"` per `feedback_ignition_popup_open_scope.md`.
  - **Page-scoped messages** from this depth-2 view: every line action (`bomLineMoveUp/Down/Remove/ItemChanged`) is `system.perspective.sendMessage(..., scope='page')`.

- [ ] **Step 3:** Run `.\scan.ps1`.

- [ ] **Step 4:** Commit:
  ```bash
  git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Parts/ItemMaster/Boms/BomLineRow/
  git commit -m "feat(item-master-boms): BomLineRow sub-view (display + edit modes)"
  ```

---

## Phase 6.F — Boms Tab View Restructure

### Task 18: Restructure `Boms/view.json` — EXISTING-VIEW EDIT

**Files:**
- Modify: `views/BlueRidge/Components/Parts/ItemMaster/Boms/view.json`

This is the trickiest task. The Phase 1 shell wrote this file; restructuring substantial sections of an existing view.json risks Designer cache conflicts. Two options:

**Option A — Designer-driven (preferred):**

Issue Jacques a detailed Designer-step instruction set. The agent writes the structure as a step-by-step recipe ("In Designer, open `BlueRidge/Components/Parts/ItemMaster/Boms`; right-click `HeaderRow`; rename to `HeaderBar`; ...") and Jacques applies it interactively. Slow but safe.

**Option B — File-edit + reconciliation:**

Agent writes the new `view.json` directly. Before scanning, Jacques is instructed to close Designer (or at least close the Boms view) to clear any in-memory cache. After scan, Jacques pulls in Designer and accepts "Files" if the conflict dialog appears.

- [ ] **Step 1:** Pick option. **Recommended: Option A** unless Jacques explicitly authorizes Option B given the substantial restructure.

- [ ] **Step 2 (if Option B):**
  - Read current `Boms/view.json`.
  - Compose the new structure per spec §7.1 — HeaderBar (with VersionDropdown + ModeBadge + IncludeDeprecatedCheckbox + HeaderSpacer + mode-gated button clusters), LinesPanel (containing flex-repeater of BomLineRow + DraftFooter).
  - **Critical:** The flex-repeater's `props.instances` binding must use `forEach` per the conventions pack — example for BOMs:
    ```
    "instances": {
      "binding": {
        "type": "expr",
        "config": {
          "expression": "forEach({view.params.value.activeVersion.lines}, {'line': it, 'rowIndex': index, 'mode': {view.params.value.mode}, 'lineCount': len({view.params.value.activeVersion.lines}), 'availableItems': {view.params.value.availableItems}, 'uoms': {view.params.value.uoms}})"
        }
      }
    }
    ```
  - Each button's `events.dom.onClick` (or `events.component.onActionPerformed`) script calls `BlueRidge.Parts.Bom.handle*(...)` directly. Wrap the result through `BlueRidge.Common.Ui.notifyResult(result, "Saved", "BOM draft saved.", "BOM save failed")`. On `result.Status == 1`, write back the updated state to `view.custom` via the parent (or via `view.params.value` updates that propagate via bidi).

- [ ] **Step 2 (if Option A):** Write a Designer recipe document at `docs/superpowers/recipes/2026-05-20-item-master-boms-tab-restructure.md` with numbered Designer steps. Hand to Jacques.

- [ ] **Step 3:** Run `.\scan.ps1`.

- [ ] **Step 4:** Designer smoke: load `/items`, switch to BOMs tab, confirm visual layout matches the mockup.

- [ ] **Step 5:** Commit (only if Option B; Option A's commit is whatever Jacques does in Designer + scan).

### Task 19: Add page-scoped message handlers to parent

**Files:**
- Modify: `views/BlueRidge/Views/Parts/ItemMaster/view.json` — EXISTING-VIEW EDIT

Per spec §7.3, 6 new page-scoped handlers attach to `root.scripts.messageHandlers[]` on the parent ItemMaster view.

- [ ] **Step 1:** Use Option A (Designer) given this is the parent ItemMaster view — high-traffic, cache-sensitive.
- [ ] **Step 2:** Write the 6 handler bodies (Python scripts) as a recipe doc for Jacques. Each handler mutates `self.view.custom.editDraft.boms.activeVersion.lines` per spec §7.3.

  Example handler body for `bomLineMoveUp`:
  ```python
  if not payload:
      return
  idx = int(payload.get('rowIndex', -1))
  draft = self.view.custom.editDraft.boms
  if not draft or 'activeVersion' not in draft:
      return
  lines = list(draft.get('activeVersion', {}).get('lines', []))
  if idx <= 0 or idx >= len(lines):
      return
  lines[idx], lines[idx-1] = lines[idx-1], lines[idx]
  # write back through nested dict copy
  av = dict(draft.get('activeVersion', {}))
  av['lines'] = lines
  d = dict(draft); d['activeVersion'] = av
  self.view.custom.editDraft.boms = d
  ```

- [ ] **Step 3:** Jacques applies in Designer. Save. `.\scan.ps1` runs.

---

## Phase 6.H — Designer Smoke Checklist

### Task 20: Hand off to Jacques for smoke testing

- [ ] **Step 1:** Compose smoke checklist (mirrors spec §10 Acceptance Criteria):
  1. `/items` loads; pick 5G0 (or another Item with seeded BOM data).
  2. Switch to BOMs tab. Confirm versions dropdown populates from DB.
  3. Click `[+ New Version]`. Confirm switch to Draft mode; lines cloned (or empty if no prior); EffectiveFrom defaults to today + 30 days; toast "Created v<N> draft."
  4. Edit a Qty value in a draft row. Confirm `● Unsaved changes` lights on page title bar.
  5. Click `[+ Add Component]`. Confirm new empty row appears at the bottom.
  6. Use the ChildItem dropdown to pick an item. Confirm partNumber + componentName + default UOM populate.
  7. Click `[↑]` / `[↓]` on a draft row. Confirm order changes; first row up disabled; last row down disabled.
  8. Click `[× Remove]` on a row. Confirm row removed.
  9. Click `[Save Draft]`. Confirm success toast; reload page (or switch Items + back) — confirm persisted state.
  10. Edit a line then click `[Publish]`. Confirm validation (try zero lines → blocked; try valid → success; version mode flips to Published).
  11. Click `[+ New Version]` again to make v3 draft. Click `[Discard Draft]`. Confirm confirmation popup; confirm physical delete (v3 gone from dropdown after discard).
  12. On a Published version, click `[Deprecate]`. Confirm popup; confirm DeprecatedAt set; mode flips to Deprecated.
  13. Toggle `[Include Deprecated]`. Confirm deprecated versions appear in the dropdown.
  14. Open Audit Log Browser (`/audit-log`), filter to LogEntityType = `Bom`. Confirm rows captured for every action.
  15. Switch to another Item. Confirm BOMs tab resets to that Item's versions.

- [ ] **Step 2:** Pass checklist to Jacques. Jacques drives smoke in Designer; reports findings.

- [ ] **Step 3:** Address any bugs found. Common likely fixes:
  - Bidi state-write didn't round-trip → fall back to page-scoped messages for the specific affected field.
  - Page-scoped message handler missing on parent → add it.
  - Mode-gated `meta.visible` not refreshing on activeVersion swap → re-fetch on `bomActiveVersionChanged`.

---

## Rollback Plan

If a critical issue is found mid-execution and a revert is needed:

- **SQL:** Drop the `0016_...` migration's index, drop all `R__Parts_Bom_*.sql` repeatable procs (they'll re-apply from disk if re-pulled). Tests in `sql/tests/00YY_Bom/` can be deleted.
- **NQs / scripts:** `git rm -r` the new folders and `.\scan.ps1`. Designer's project tree refreshes.
- **View edits:** `git revert` the commits touching `Boms/view.json` and parent `ItemMaster/view.json`. Re-pull in Designer.

Phase 1 shell is restored to its pre-Phase-6 state with no DB or code residue.

---

## References

- **Spec:** `docs/superpowers/specs/2026-05-20-item-master-boms-design.md` (READ THIS BEFORE TASK 1)
- **Reference impls:**
  - `sql/migrations/repeatable/R__Location_LocationTypeDefinition_SaveAll.sql` (bundled SaveAll — schema-editor variant; closest analog for `Bom_SaveDraft` shape)
  - `sql/migrations/repeatable/R__Location_Location_SaveAll.sql` (bundled SaveAll — instance-editor variant; closer for the physical child reconciliation)
- **Memory:**
  - `project_mpp_item_master_pattern.md`
  - `project_mpp_bundled_save_pattern.md`
  - `project_mpp_confirm_unsaved_pattern.md`
  - `feedback_ignition_view_edit_boundary.md` (CRITICAL for Tasks 18, 19)
  - `feedback_ignition_nq_resource_schema.md`
  - `feedback_ignition_meta_visible_in_tables.md`
  - `feedback_ignition_message_scope.md`
  - `feedback_ignition_popup_open_scope.md`
  - `feedback_ignition_gateway_scan.md`
- **Conventions pack:** `ignition-context-pack/{02_perspective_views,03_script_python,04_named_queries,07_conventions_and_antipatterns}.md`
- **CLAUDE.md** — Ignition JDBC compatibility section (no OUTPUT params, one result set per proc), SQL design conventions, git commit conventions.
