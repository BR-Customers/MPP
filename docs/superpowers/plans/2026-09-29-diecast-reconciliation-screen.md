# Die Cast Shift Reconciliation — the Perspective screen (Plan 2) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Perspective surface a team lead uses to reconcile one past shift × press × die against its paper press sheet — one save, one transaction, one audited reconciliation.

**Architecture:** Every proc, function and worker already exists and is green (Plan 1). This plan adds **only** Core named queries, one thin Core entity script, six new MPP views, one route, and one tile on an existing view. No SQL. No domain arithmetic in Python — the confirmation panel renders `PlanJson` returned by the Save's own preview mode, so the screen and the Save can never disagree.

**Tech Stack:** Ignition 8.3 Perspective (file-based project), Jython 2.7 project scripts, SQL Server 2022 stored procedures reached through Core named queries.

---

## Global Constraints

Every task's requirements implicitly include this section.

1. **All named queries live in the Core project.** MPP and MPP_Config have none of their own; sibling projects cannot see each other's. (`project_mpp_nq_core_topology`)
2. **Every NQ here is `type: "Query"`**, including the Save. `UpdateQuery`/`execNonQuery` is for silent procs and would swallow the Save's status row. (`feedback_ignition_nq_type_for_status_row_procs`)
3. **NQ `resource.json` is `version: 2`.** Designer 8.3.5 NPEs on `version: 1`. Clone the shape from an existing Designer-saved NQ.
4. **`sqlType` is Designer's own enum, not `java.sql.Types`:** `2` = Int4 (`INT`), `3` = Int8 (`BIGINT`), `6` = Boolean (`BIT`), `7` = String (`NVARCHAR`), `8` = DateTime.
5. **The caller supplies `appUserId`.** No entity function resolves or defaults it. Views pass `BlueRidge.Common.Session.currentAppUserId(self.session)`. Entity functions call `BlueRidge.Common.Util.requireAppUserId(appUserId)`.
6. **No business logic in Python.** Domain rules live in SQL. The blocking checks in Task 8 are a *pre-flight UX mirror* of the Save's own refusals, never the authority — the Save re-runs every one of them.
7. **Every displayed timestamp is Eastern.** The read procs already convert at the boundary; `Oee.Shift.ActualStart`/`ActualEnd` are already Eastern (OI-38) and are returned raw. Never re-convert.
8. **Vocabulary is fixed.** An **LTT** is the ticket number; a **LOT** is the record. "Tag" and "basket" appear nowhere. The typed column is **Actual**, never "Sheet". A die shows **name first, then `Asset # <code>`**; the word "code" never reaches the operator.
9. **Pre-declare every `view.custom.*` a binding reads**, with a fully shaped default — `[]` for anything iterated or measured with `len()`, a dict carrying every accessed key for anything traversed by nested path. The binding *source* must also always return the full shape, including on the empty path. (`feedback_ignition_predeclare_bound_custom_props`)
10. **`load()` seeds `selected` and `editDraft` in ONE property write.** Two sequential writes make the dirty binding fire a spurious `isDirty: true`. (`project_mpp_item_master_pattern`)
11. **Numeric and text inputs the Save reads set `deferUpdates: false`.** Inputs commit on blur, so a gateway button otherwise reads an empty field. (`feedback_ignition_input_deferupdates_commit_race`)
12. **`position.display` for binding-driven visibility on flex children**, not `meta.visible`. The exception is tabular rows where column alignment demands a preserved slot.
13. **No drag-and-drop.** Up/down arrow buttons for any sortable list.
14. **Root container keeps `meta.name: "root"`.** Style classes are referenced by suffix only (no `psc-` prefix).
15. **`events.system.onStartup`, never `events.component.onStartup`** — the latter silently never fires.
16. **Event-script bodies start with a tab.** Designer wraps them in `def runAction(self, event):`; a column-0 body is an `IndentationError`.
17. **Stage explicit git paths.** Never `git add -u`, `-A` or `.` — the tree is shared with other sessions and carries hundreds of unrelated modified files.
18. **After writing any Ignition resource, run `.\scan.ps1`** from the repo root. Never `pull.ps1`.
19. **Working branch is `jacques/working`.**

### Editing existing views

The standing rule is that **existing** views are edited in Designer, because file edits race the Designer's in-memory model. **Jacques confirmed on 2026-09-29 that his Designer is attached to a different gateway**, so for this plan's duration existing-view file edits are cleared. Two files are affected (Task 12's `SupervisorDashboard`, and nothing else). Re-confirm before assuming this still holds in a later session.

---

## What already exists — do not rebuild

| Thing | Where |
|---|---|
| Every read proc, the Save, the six workers, three functions | `sql/migrations/repeatable/`, applied and green (suite 4186/4186) |
| The design | `docs/superpowers/specs/2026-09-21-diecast-shift-reconciliation-design.md` — **§14 amendments A1–A16 win over §1–13** |
| The behaviour + wording specification | `mockup/diecast_shift_reconciliation_mock.html` — authoritative for *behaviour and wording*, never for data shape |
| Elevation that survives a long sheet | `Common.Session.touchElevation` + `ElevationMaxSeconds` (migration `0100`, 2026-09-29) |
| Toasts, ConfirmUnsaved, ElevationModal, Numpad, Keyboard | Core / MPP components, reused as-is |

**Decisions settled 2026-09-29 (these closed the scope draft's open questions):**

- **Approver picker sources from all active `Location.AppUser` rows.** Every person gets a row at first PIN sign-in, so a QAS signer always exists. No AD-account filter.
- **Terminal is whatever the team lead chooses, including a personal laptop on the network.** Mouse and keyboard are the baseline — **no `Numpad` / `Keyboard` embeds anywhere in this plan.**
- **The dashboard tile lives on the landing view** and flips the press selector; idle rows render inline as their own chip and never enter the tile's count. No separate list, no plant-wide landing mode.
- **No draft persistence.** One sitting. The elevation ceiling work removes the common way to lose it.
- **A die changed mid-shift is two landing rows**, presented as two collapsible events.

---

## The SQL contracts this plan binds to

Captured from `sys.dm_exec_describe_first_result_set` on 2026-09-29. **These are the authority — do not retype a column name from prose.**

### Reads

```
Workorder.DieCastShiftReconciliation_ListShifts(@CellLocationId BIGINT, @Days INT, @AtMoment DATETIME2 = NULL)
  ShiftId bigint | ShiftLabel nvarchar(106) | StartEt datetime2(3) | EndEt datetime2(3)
  ToolId bigint | AssetNumber nvarchar(50) | DieName nvarchar(100)
  ContributionRows int | GoodRecorded int | RecordedTotalShots int
  StatusCode nvarchar(18) | LastReconciledBy nvarchar(10) | LastReconciledAtEt datetime2(3)
    StatusCode ∈ Open | Reconciled | ReleasedNoShiftEnd | EntryRecorded | NoEntry

Workorder.DieCastShift_ListUnreconciled(@Days INT, @AtMoment DATETIME2 = NULL)
  ShiftId | ShiftLabel | StartEt | CellLocationId | PressCode | PressName
  ToolId | AssetNumber | DieName | ContributionRows | GoodRecorded
  StatusCode nvarchar(18) | IsAlerting bit

Workorder.DieCastShiftReconciliation_GetHeader(@ShiftId, @CellLocationId, @ToolId)
  ShiftId | ShiftLabel | StartEt | EndEt | IsOpen bit
  CellLocationId | PressCode | PressName | ToolId | AssetNumber | DieName
  ActiveCavities int | DieShotCount int
  RecordedTotalShots int | RecordedWarmUpShots int | RecordedNoGood int | RecordedGood int
  HasShiftEndNumber bit | Stamp nvarchar(100)
  LastReconciledAtEt datetime2(3) | LastReconciledBy nvarchar(10)

Workorder.DieCastShiftReconciliation_ListEntries(@ShiftId, @CellLocationId, @ToolId)
  EntryKey nvarchar(62) | EnteredAtEt | EnteredBy nvarchar(10) | ReconciliationId bigint
  EnteredDuringShiftId bigint | EnteredDuringShift nvarchar(106)
  Reading int | Pieces int | Lots int | WarmUpPieces int | OtherScrapPieces int
  RowCount int | ContributionIds nvarchar(max) | RejectIds nvarchar(max)
    ContributionIds / RejectIds are COMMA-SEPARATED id lists. They are what a move acts on.

Workorder.DieCastShiftReconciliation_ListLots(@ShiftId, @CellLocationId, @ToolId)
  LotId | Ltt nvarchar(50) | ItemId | PartNumber | PartDescription
  ToolCavityId | CavityCode nvarchar(4) | Recorded int | PieceCount int | InventoryAvailable int
  StatusCode | StatusName | NowAt nvarchar(200) | ReleasedAtEt
  IsLocked bit | LockReason nvarchar(200)

Workorder.DieCastShiftReconciliation_ListRejects(@ShiftId, @CellLocationId, @ToolId)
  DefectCodeId | DefectCode nvarchar(20) | Defect nvarchar(500) | IsNonRejectScrap bit
  ItemId bigint | PartNumber | Quantity int | Cavities int
  ApprovedByUserId bigint | ApprovedBy nvarchar(10)
    GRAIN IS (DefectCode, Part, Approver). A per-defect total is SUMMED ON SCREEN,
    never read off one row. An unapproved line is its own NULL-approver row.

Workorder.DieCastShiftReconciliation_ListMoveTargets(@ShiftId, @CellLocationId, @ToolId)
  ShiftId | ShiftLabel | StartEt | EndEt | Offset int | GoodRecorded int
    MAY RETURN FEWER THAN FOUR ROWS at the ends of history. Never assume four,
    never pad, never pre-select.

Workorder.DieCastShiftReconciliation_ListCavities(@ShiftId, @ToolId)   -- TWO params, not three
  ToolCavityId | CavityCode nvarchar(4) | ItemId | PartNumber | PartDescription
  CanMintLot bit | DeprecatedAtEt datetime2(3) | IsOffDieNow bit

Workorder.DieCastReconciliationReason_List()      -- no params
  Id bigint | Code nvarchar(50) | Name nvarchar(100) | RequiresNote bit

Lots.DieCastLot_ResolveLtt(@Ltt NVARCHAR, @ToolId BIGINT)
  Ltt | Result nvarchar(9) | LotId | ToolCavityId | CavityCode nvarchar(10)
  ItemId | PartNumber | PieceCount int | Message nvarchar(432)
```

### The Save

```
Workorder.DieCastShiftReconciliation_Save(
    @ShiftId BIGINT, @CellLocationId BIGINT, @ToolId BIGINT,
    @ReasonId BIGINT, @Note NVARCHAR(500),
    @ActualJson  NVARCHAR(MAX),   -- {"totalShots":N,"goodShots":N,"warmUpShots":N}
    @MovesJson   NVARCHAR(MAX),   -- [{"entityType":"Contribution"|"Reject","entityId":N,"toShiftId":N}]
    @LotsJson    NVARCHAR(MAX),   -- [{"lotId":N|null,"ltt":"...","toolCavityId":N,"quantity":N}]
                                  --   quantity is the ACTUAL for that LOT in this shift, never a delta
    @RejectsJson NVARCHAR(MAX),   -- [{"defectCodeId":N,"itemId":N|null,"quantity":N,"approvedByUserId":N}]
                                  --   itemId null means "All"
    @LoadedStamp NVARCHAR(100),   -- GetHeader.Stamp exactly as the screen read it
    @AppUserId BIGINT, @TerminalLocationId BIGINT,
    @PreviewOnly BIT = 0)

RESULT: exactly one row, FOUR columns, on every exit path:
  Status BIT | Message NVARCHAR(500) | NewId BIGINT | PlanJson NVARCHAR(MAX)
  PlanJson is NULL on a refusal, the plan that WOULD apply on a preview,
  the plan that WAS applied on a save.
```

### `PlanJson` — the confirmation panel's entire data source

```jsonc
{
  "shiftLabel": "09-17 1st Shift", "pressCode": "DC1-M11",
  "dieName": "6MA IN 2,3,4 EX 2,3,4 D", "assetNumber": "DMO125",
  "activeCavities": 12,
  "hasReduction": false,            // THE amber tick-box fact. Decided in SQL, never guessed.
  "dieLife":  { "before": 15699, "delta": 1121, "after": 16820 },
  "totals":   { "piecesAdded": 12960, "piecesRemoved": 0, "newLots": 2,
                "countsCorrected": 6, "countsStanding": 1, "rowsMoved": 24 },
  "moves":  [ { "entityType": "Contribution", "entityId": 9912, "toShiftId": 53,
                "toShiftLabel": "09-16 3rd Shift" } ],
  "lots":   [ { "ltt": "10628131", "partNumber": "...", "cavityCode": "a",
                "isNew": false, "gap": 1080, "isLocked": false, "countChanges": 1,
                "pieceCountBefore": 1788, "pieceCountAfter": 2868, "lockReason": null } ],
  "scrap":  [ { "cavityCode": "a", "partNumber": "...", "defectCode": "008",
                "defect": "...", "delta": -12, "approvedBy": "CW", "isWarmUp": false } ]
}
```

`moves`, `lots` and `scrap` are **always arrays, never a missing key** — the proc `ISNULL`s them to `[]` inside the `JSON_QUERY` precisely so a Perspective binding reading `$.moves` gets something on the ordinary path.

---

## The Dev verification fixture — use this, do not report "code reading only"

Found 2026-09-29, after Tasks 5 and 6 both reported they could not exercise a populated
sheet. **They could.** `MPP_MES_Dev` carries real die cast production on **`DC1-M11` /
`DMO125`** — the acceptance sheet's own press and die — dated 09-21 and 09-22. It reads as
"No Entry" everywhere only because the landing's window is the last **7 days** and the data
is 7-8 days old. Nothing is broken; the window is correct product behaviour.

The **sheet view takes its ids as params**, so it renders a populated shift regardless of
that window. Use:

```
shiftId = 20126   cellLocationId = 14   toolId = 1     (09-21 First Shift, DC1-M11 / DMO125)
shiftId = 20129   cellLocationId = 14   toolId = 1     (09-22 First Shift, same press and die)
```

Verified row counts for **20126**, straight from the procs — these are what a correct screen
must show:

| Read | Rows |
|---|---|
| `_GetHeader` | 1 |
| `_ListEntries` | 2 entries |
| `_ListLots` | 10 LOTs |
| `_ListRejects` | **0** |
| `_ListMoveTargets` | 4 |
| `_ListCavities` | 12 cavities |

**Shift 20126 is a genuinely UNDER-RECORDED shift, which makes it the right end-to-end
fixture.** The die has **12 active cavities**, but only **10 LOTs** exist, one per cavity, at
894 pieces each. So 894 x 12 = 10,728 pieces were made and only 8,940 are on baskets -- the
missing 1,788 is exactly two cavities' worth. That is precisely the failure this feature
exists to repair (SS 6.3: LTTs on paper, nowhere in the MES).

Consequence for testing: **the blocking checks cannot all pass on this shift from the totals
fields alone**, and that is correct behaviour, not a defect. Matching the LOT sum needs
`goodShots = 745`, while the per-LOT ceiling needs `goodShots >= 894`; the two are
irreconcilable until the two missing baskets are entered. **After Task 9 ships the LTT entry
bar, adding the two missing LTTs at `goodShots = 894` should make the sheet fully saveable**
-- which is the real end-to-end test for Task 10, on real production rows.

Two consequences worth stating:

- `_ListMoveTargets` returning **4** here does not license assuming four. It legitimately
  returns fewer at the ends of history, and the popup must render whatever arrives.
- `_ListRejects` returns **0**, so the reject block's *recorded* side has no live data on
  Dev. The typed side can still be exercised. Do not manufacture reject rows to fix this —
  say it is unverified, the way Plan 1 refused to reconstruct a fixture.

---

## File Structure

| File | Responsibility |
|---|---|
| `ignition/projects/Core/ignition/named-query/workorder/DieCastShiftReconciliation_*/` | 8 NQs — one per read + the Save |
| `.../named-query/workorder/DieCastShift_ListUnreconciled/` | the dashboard read |
| `.../named-query/workorder/DieCastReconciliationReason_List/` | reason dropdown |
| `.../named-query/lots/DieCastLot_ResolveLtt/` | per-LTT resolver |
| `.../script-python/BlueRidge/Workorder/DieCastReconciliation/code.py` | thin glue, one function per NQ |
| `.../script-python/BlueRidge/Common/Session/code.py` | +1 replay-map entry (existing file) |
| `MPP/.../views/BlueRidge/Views/ShopFloor/DieCastReconcile/` | shell: route, AD gate, phase |
| `MPP/.../views/BlueRidge/Components/PlantFloor/DieCastReconcileLanding/` | press + shift picker, tile |
| `MPP/.../views/BlueRidge/Components/PlantFloor/DieCastReconcileSheet/` | the reconciliation |
| `MPP/.../views/BlueRidge/Components/Popups/DieCastReconcileMove/` | re-file an entry |
| `MPP/.../views/BlueRidge/Components/Popups/DieCastReconcileConfirm/` | PlanJson confirmation |
| `MPP/.../views/BlueRidge/Components/Popups/DieCastReconcileHowTo/` | operator guide |
| `MPP/.../page-config/config.json` | the route (existing file) |
| `MPP/.../views/BlueRidge/Views/ShopFloor/SupervisorDashboard/` | +1 tile (existing view) |

The sheet is the only large view. It uses **per-section ownership** for its four blocks, but with a **single shared derived-state owner on the parent** — the totals block's arithmetic reads the reject block's sum and the LOT list's sum, so the sections are not independent. There is **one Save, not one per section**; sections do not carry their own Save/Discard buttons, which is where this departs from Item Master.

---

## Task 1: The eleven named queries

**Files:**
- Create: `ignition/projects/Core/ignition/named-query/workorder/DieCastShiftReconciliation_ListShifts/{query.sql,resource.json}`
- Create: the same pair under `.../DieCastShiftReconciliation_GetHeader/`, `.../DieCastShiftReconciliation_ListEntries/`, `.../DieCastShiftReconciliation_ListLots/`, `.../DieCastShiftReconciliation_ListRejects/`, `.../DieCastShiftReconciliation_ListMoveTargets/`, `.../DieCastShiftReconciliation_ListCavities/`, `.../DieCastShiftReconciliation_Save/`, `.../DieCastShift_ListUnreconciled/`
- Create: `ignition/projects/Core/ignition/named-query/lots/DieCastLot_ResolveLtt/{query.sql,resource.json}`

**Interfaces:**
- Consumes: the procs listed under "The SQL contracts" above.
- Produces: NQ paths `workorder/DieCastShiftReconciliation_*`, `workorder/DieCastShift_ListUnreconciled`, `workorder/DieCastReconciliationReason_List`, `lots/DieCastLot_ResolveLtt` — consumed by Task 2 only.

Named queries share one folder tree and one gateway scan, so **author all ten, then scan once**. Do not parallelise this task.

- [ ] **Step 1: Write the eight three-parameter read NQs**

Five of them (`GetHeader`, `ListEntries`, `ListLots`, `ListRejects`, `ListMoveTargets`) take exactly the same three parameters. **`ListCavities` does NOT** — it takes `(@ShiftId, @ToolId)` only; see Step 2. `query.sql`, substituting `<NAME>`:

```sql
EXEC Workorder.DieCastShiftReconciliation_<NAME>
    @ShiftId        = :shiftId,
    @CellLocationId = :cellLocationId,
    @ToolId         = :toolId
```

`resource.json` for each of those six — identical but for nothing:

```json
{
  "scope": "DG",
  "version": 2,
  "restricted": false,
  "overridable": true,
  "files": [
    "query.sql"
  ],
  "attributes": {
    "useMaxReturnSize": false,
    "autoBatchEnabled": false,
    "fallbackValue": "",
    "maxReturnSize": 100,
    "cacheUnit": "SEC",
    "type": "Query",
    "enabled": true,
    "cacheAmount": 1,
    "cacheEnabled": false,
    "database": "MPP",
    "fallbackEnabled": false,
    "lastModificationSignature": "",
    "permissions": [
      {
        "zone": "",
        "role": ""
      }
    ],
    "lastModification": {
      "actor": "claude",
      "timestamp": "2026-09-29T00:00:00Z"
    },
    "parameters": [
      { "type": "Parameter", "identifier": "shiftId",        "sqlType": 3 },
      { "type": "Parameter", "identifier": "cellLocationId", "sqlType": 3 },
      { "type": "Parameter", "identifier": "toolId",         "sqlType": 3 }
    ]
  }
}
```

- [ ] **Step 2: Write the two list NQs with their own parameters**

`workorder/DieCastShiftReconciliation_ListShifts/query.sql`:

```sql
EXEC Workorder.DieCastShiftReconciliation_ListShifts
    @CellLocationId = :cellLocationId,
    @Days           = :days
```

parameters: `cellLocationId` `sqlType: 3`, `days` `sqlType: 2`.

`workorder/DieCastShift_ListUnreconciled/query.sql`:

```sql
EXEC Workorder.DieCastShift_ListUnreconciled
    @Days = :days
```

parameters: `days` `sqlType: 2`.

`@AtMoment` is a test-only UTC "now" override and is deliberately **not** exposed — it defaults, and a screen that could pass it could silently read a different week.

- [ ] **Step 3: Write the reason list and the LTT resolver**

`workorder/DieCastReconciliationReason_List/query.sql`:

```sql
EXEC Workorder.DieCastReconciliationReason_List
```

`"parameters": []`. Leave `cacheEnabled: false` — the table is tiny and a stale reason list during a release is a worse trade than one round trip.

`lots/DieCastLot_ResolveLtt/query.sql`:

```sql
EXEC Lots.DieCastLot_ResolveLtt
    @Ltt    = :ltt,
    @ToolId = :toolId
```

parameters: `ltt` `sqlType: 7`, `toolId` `sqlType: 3`.

**`ltt` is a STRING (`sqlType: 7`) and must stay one.** An LTT is 8–9 digits and is compared as text; typing it as an integer is the same class of defect as `int()`-ing a PIN.

- [ ] **Step 4: Write the Save NQ**

`workorder/DieCastShiftReconciliation_Save/query.sql`:

```sql
EXEC Workorder.DieCastShiftReconciliation_Save
    @ShiftId            = :shiftId,
    @CellLocationId     = :cellLocationId,
    @ToolId             = :toolId,
    @ReasonId           = :reasonId,
    @Note               = :note,
    @ActualJson         = :actualJson,
    @MovesJson          = :movesJson,
    @LotsJson           = :lotsJson,
    @RejectsJson        = :rejectsJson,
    @LoadedStamp        = :loadedStamp,
    @AppUserId          = :appUserId,
    @TerminalLocationId = :terminalLocationId,
    @PreviewOnly        = :previewOnly
```

parameters, in order: `shiftId` 3, `cellLocationId` 3, `toolId` 3, `reasonId` 3, `note` 7, `actualJson` 7, `movesJson` 7, `lotsJson` 7, `rejectsJson` 7, `loadedStamp` 7, `appUserId` 3, `terminalLocationId` 3, `previewOnly` 6.

`type` stays `"Query"` — **the Save returns a four-column status row and an `UpdateQuery` would discard it.**

**ONE NQ serves both preview and save**, with `previewOnly` as a parameter. Two NQs hard-coding `1` and `0` would be two places to keep in step for no gain.

- [ ] **Step 5: Scan and verify every NQ resolves**

```bash
cd /c/Users/JacquesPotgieter/Documents/Dev/MPP && ./scan.ps1
```

Then, from the Designer's Script Console (or a gateway-scope test), confirm each path resolves. A missing NQ file shows up as *"Named query not found"* in the gateway log and, on screen, as a panel that saves fine and never refreshes — so check the log, not the screen. (`feedback_check_nq_files_first`)

Expected: `scan.ps1` returns 200 and the gateway log carries no `Named query not found` for any of the ten paths.

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/Core/ignition/named-query/workorder/DieCastShiftReconciliation_ListShifts ignition/projects/Core/ignition/named-query/workorder/DieCastShiftReconciliation_GetHeader ignition/projects/Core/ignition/named-query/workorder/DieCastShiftReconciliation_ListEntries ignition/projects/Core/ignition/named-query/workorder/DieCastShiftReconciliation_ListLots ignition/projects/Core/ignition/named-query/workorder/DieCastShiftReconciliation_ListRejects ignition/projects/Core/ignition/named-query/workorder/DieCastShiftReconciliation_ListMoveTargets ignition/projects/Core/ignition/named-query/workorder/DieCastShiftReconciliation_ListCavities ignition/projects/Core/ignition/named-query/workorder/DieCastShiftReconciliation_Save ignition/projects/Core/ignition/named-query/workorder/DieCastShift_ListUnreconciled ignition/projects/Core/ignition/named-query/workorder/DieCastReconciliationReason_List ignition/projects/Core/ignition/named-query/lots/DieCastLot_ResolveLtt
git commit -m "feat(ignition): named queries for the die cast shift reconciliation"
```

---

## Task 2: The entity script

**Files:**
- Create: `ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/DieCastReconciliation/{code.py,resource.json}`

**Interfaces:**
- Consumes: the ten NQ paths from Task 1.
- Produces, all on `BlueRidge.Workorder.DieCastReconciliation`:
  - `listShifts(cellLocationId, days=7)` → `list[dict]`
  - `listUnreconciled(days=7)` → `list[dict]` (both claims)
  - `listFlagged(days=7)` → `list[dict]` (the alerting claim only — the tile's source)
  - `getHeader(shiftId, cellLocationId, toolId)` → `dict` or `None`
  - `getHeaderOrEmpty(shiftId, cellLocationId, toolId)` → `dict`, always fully shaped
  - `listEntries / listLots / listRejects / listMoveTargets(shiftId, cellLocationId, toolId)` → `list[dict]`
  - `listCavities(shiftId, toolId)` → `list[dict]` — **two params; the proc has no `@CellLocationId`**
  - `listReasons()` → `list[dict]`; `reasonOptions()` → `[{label, value}]`
  - `resolveLtt(ltt, toolId)` → `dict`, always fully shaped
  - `save(payload, appUserId, terminalLocationId, previewOnly=False)` → `{Status, Message, NewId, PlanJson}`
  - `preview(payload, appUserId, terminalLocationId)` → same, `previewOnly=True`

- [ ] **Step 1: Write `resource.json`**

```json
{
  "scope": "A",
  "version": 1,
  "restricted": false,
  "overridable": true,
  "files": [
    "code.py"
  ],
  "attributes": {
    "hintScope": 2,
    "lastModification": {
      "actor": "claude",
      "timestamp": "2026-09-29T00:00:00Z"
    }
  }
}
```

The folder must contain **only** `code.py` and `resource.json`. A child folder (a stray `__pycache__`) makes the gateway render the resource as a *folder, not a module*, and `BlueRidge.Workorder.DieCastReconciliation` then silently resolves to a same-named Java package.

- [ ] **Step 2: Write `code.py`**

```python
# =============================================================================
# Project Library:  BlueRidge.Workorder.DieCastReconciliation
#
# Thin glue for the die cast shift reconciliation screen: one function per
# named query, nothing else.
#
# THERE IS NO DOMAIN LOGIC IN THIS MODULE AND NONE MAY BE ADDED. The blocking
# checks, the totals arithmetic and the confirmation's change groups are all
# decided in SQL -- the Save computes them, and its @PreviewOnly = 1 mode hands
# them back as PlanJson. A helper here that "just totals the rejects" is the
# start of a second implementation of the Save, and the first time the two
# disagree a correctly entered press sheet becomes unsaveable.
#
# Layer: View -> this module -> BlueRidge.Common.Db.* -> system.db.*
# =============================================================================

# Fully-shaped empties. A binding-bound custom property is REPLACED by its
# binding's result the instant it evaluates, so a shaped default on the view is
# not enough -- the source has to return the full shape on the empty path too,
# or a nested read errors the component. (feedback_ignition_predeclare_bound_custom_props)
_EMPTY_HEADER = {
    "ShiftId": None, "ShiftLabel": "", "StartEt": None, "EndEt": None, "IsOpen": False,
    "CellLocationId": None, "PressCode": "", "PressName": "",
    "ToolId": None, "AssetNumber": "", "DieName": "",
    "ActiveCavities": 0, "DieShotCount": 0,
    "RecordedTotalShots": 0, "RecordedWarmUpShots": 0,
    "RecordedNoGood": 0, "RecordedGood": 0,
    "HasShiftEndNumber": False, "Stamp": "",
    "LastReconciledAtEt": None, "LastReconciledBy": "",
}

_EMPTY_LTT = {
    "Ltt": "", "Result": "Error", "LotId": None, "ToolCavityId": None, "CavityCode": "",
    "ItemId": None, "PartNumber": "", "PieceCount": 0,
    "Message": "The LTT could not be checked. Try again.",
}


def listShifts(cellLocationId, days=7):
    """The landing list for one press: one row per shift x die."""
    BlueRidge.Common.Util.log("cellLocationId=%s days=%s" % (cellLocationId, days))
    return BlueRidge.Common.Db.execList(
        "workorder/DieCastShiftReconciliation_ListShifts",
        {"cellLocationId": cellLocationId, "days": days})


def listUnreconciled(days=7):
    """Plant-wide. Carries BOTH claims: IsAlerting = 1 is a real finding
    (production recorded, no shift-end number); IsAlerting = 0 is an idle die,
    which fires over every weekend and prep window. The TILE COUNTS ONLY THE
    ALERTING ROWS -- merging the two is explicitly forbidden (spec sec 6.4)."""
    BlueRidge.Common.Util.log("days=%s" % days)
    return BlueRidge.Common.Db.execList(
        "workorder/DieCastShift_ListUnreconciled", {"days": days})


def listFlagged(days=7):
    """listUnreconciled filtered to the ALERTING claim, which is the only thing
    the dashboard tile and its drill-through ever count.

    It lives here rather than in a per-view script transform because BOTH the
    landing tile and the supervisor dashboard tile need exactly this list, and
    two copies of the filter is two places for the two tiles to drift apart and
    disagree about the same number. Projection, not domain logic -- IsAlerting
    is decided in SQL and this only selects on it."""
    return [r for r in listUnreconciled(days) if r.get("IsAlerting")]


def getHeader(shiftId, cellLocationId, toolId):
    """The banner, the Recorded column, die life, the active-cavity count and
    the stale-guard Stamp. None when the shift/press/die does not exist."""
    BlueRidge.Common.Util.log("shiftId=%s cell=%s tool=%s" % (shiftId, cellLocationId, toolId))
    return BlueRidge.Common.Db.execOne(
        "workorder/DieCastShiftReconciliation_GetHeader",
        {"shiftId": shiftId, "cellLocationId": cellLocationId, "toolId": toolId})


def getHeaderOrEmpty(shiftId, cellLocationId, toolId):
    """Binding-only sibling of getHeader: ALWAYS the full shape, so a view that
    traverses view.custom.header.ShiftLabel never reads through a None."""
    row = getHeader(shiftId, cellLocationId, toolId)
    if not row:
        return dict(_EMPTY_HEADER)
    out = dict(_EMPTY_HEADER)
    out.update(row)
    return out


def _listThree(nq, shiftId, cellLocationId, toolId):
    return BlueRidge.Common.Db.execList(
        nq, {"shiftId": shiftId, "cellLocationId": cellLocationId, "toolId": toolId})


def listEntries(shiftId, cellLocationId, toolId):
    """What is on record, grouped into entries. ContributionIds / RejectIds are
    comma-separated id lists and are what a move acts on -- the grouping itself
    is presentation only, so a wrong grouping can never produce a wrong write."""
    return _listThree("workorder/DieCastShiftReconciliation_ListEntries",
                      shiftId, cellLocationId, toolId)


def listLots(shiftId, cellLocationId, toolId):
    return _listThree("workorder/DieCastShiftReconciliation_ListLots",
                      shiftId, cellLocationId, toolId)


def listRejects(shiftId, cellLocationId, toolId):
    """GRAIN IS (DefectCode, Part, Approver). One defect code on one part
    approved by two people is TWO rows, each carrying only that person's
    quantity; an unapproved line is its own NULL-approver row. A per-defect
    total is summed on the screen and never read off one row. Do not flatten
    this -- the earlier grain named the wrong person."""
    return _listThree("workorder/DieCastShiftReconciliation_ListRejects",
                      shiftId, cellLocationId, toolId)


def listMoveTargets(shiftId, cellLocationId, toolId):
    """The closed shifts within two of this one. LEGITIMATELY RETURNS FEWER
    THAN FOUR ROWS at the ends of history -- render whatever arrives, never pad
    and never pre-select."""
    return _listThree("workorder/DieCastShiftReconciliation_ListMoveTargets",
                      shiftId, cellLocationId, toolId)


def listCavities(shiftId, toolId):
    """TWO parameters -- this proc has no @CellLocationId, unlike its siblings.
    The die alone identifies the cavity set; the press adds nothing.

    The die's cavities and parts AS OF THE SHIFT -- the same set the Save
    resolves. Feeds the reject block's Part dropdown and the LTT bar's cavity
    picker. Do not substitute a resolved-as-of-now list from anywhere else:
    the Save would then refuse a cavity the screen offered."""
    return BlueRidge.Common.Db.execList(
        "workorder/DieCastShiftReconciliation_ListCavities",
        {"shiftId": shiftId, "toolId": toolId})


def listReasons():
    return BlueRidge.Common.Db.execList("workorder/DieCastReconciliationReason_List")


def reasonOptions():
    """[{label, value}] for ia.input.dropdown."""
    return [{"label": r.get("Name"), "value": r.get("Id")} for r in listReasons()]


def resolveLtt(ltt, toolId):
    """Called AS EACH LTT IS TYPED OR SCANNED, never at save.

    Result is one of: NewLot | SameDie | Foreign | Invalid | Error.
    Message is operator-ready prose; render it verbatim rather than composing
    a second sentence from the parts."""
    BlueRidge.Common.Util.log("ltt=%s toolId=%s" % (ltt, toolId))
    row = BlueRidge.Common.Db.execOne(
        "lots/DieCastLot_ResolveLtt", {"ltt": ltt, "toolId": toolId})
    if not row:
        out = dict(_EMPTY_LTT)
        out["Ltt"] = ltt
        return out
    out = dict(_EMPTY_LTT)
    out.update(row)
    return out


def _saveParams(payload, appUserId, terminalLocationId, previewOnly):
    d = BlueRidge.Common.Util.extractQualifiedValues(payload) or {}
    return {
        "shiftId":            d.get("shiftId"),
        "cellLocationId":     d.get("cellLocationId"),
        "toolId":             d.get("toolId"),
        "reasonId":           d.get("reasonId"),
        "note":               d.get("note"),
        "actualJson":         system.util.jsonEncode(d.get("actual") or {}),
        "movesJson":          system.util.jsonEncode(d.get("moves") or []),
        "lotsJson":           system.util.jsonEncode(d.get("lots") or []),
        "rejectsJson":        system.util.jsonEncode(d.get("rejects") or []),
        "loadedStamp":        d.get("loadedStamp"),
        "appUserId":          BlueRidge.Common.Util.requireAppUserId(appUserId),
        "terminalLocationId": terminalLocationId,
        "previewOnly":        previewOnly,
    }


def preview(payload, appUserId, terminalLocationId):
    """Run every check and build the plan WITHOUT writing. Returns the same
    four columns as save; PlanJson is the plan that WOULD be applied.

    A preview binds because the stale guard makes it bind: between a preview
    and its save either nothing moved and the plan is identical, or the save
    refuses outright. There is no third outcome. So the confirmation panel may
    render this plan as fact."""
    return BlueRidge.Common.Db.execMutation(
        "workorder/DieCastShiftReconciliation_Save",
        _saveParams(payload, appUserId, terminalLocationId, True))


def save(payload, appUserId, terminalLocationId, previewOnly=False):
    """The one write in this feature."""
    # Log from the EXTRACTED params, never from the raw payload: a payload from
    # a view can be a QualifiedValue or a Perspective ImmutableMap, and .get()
    # raises on both. _saveParams does the extraction; borrowing its result
    # keeps this trace safe without extracting twice.
    params = _saveParams(payload, appUserId, terminalLocationId, bool(previewOnly))
    BlueRidge.Common.Util.log("shiftId=%s previewOnly=%s"
                              % (params.get("shiftId"), previewOnly))
    return BlueRidge.Common.Db.execMutation(
        "workorder/DieCastShiftReconciliation_Save", params)


def planFrom(result):
    """Decode PlanJson off a save/preview result into a dict. Returns a fully
    shaped empty plan when the proc refused (PlanJson is NULL on a refusal),
    so a confirmation view binding to $.totals never reads through a None."""
    empty = {"shiftLabel": "", "pressCode": "", "dieName": "", "assetNumber": "",
             "activeCavities": 0, "hasReduction": False,
             "dieLife": {"before": 0, "delta": 0, "after": 0},
             "totals": {"piecesAdded": 0, "piecesRemoved": 0, "newLots": 0,
                        "countsCorrected": 0, "countsStanding": 0, "rowsMoved": 0},
             "moves": [], "lots": [], "scrap": []}
    raw = (result or {}).get("PlanJson")
    if not raw:
        return empty
    try:
        out = dict(empty)
        out.update(system.util.jsonDecode(raw))
        return out
    except (Exception, java.lang.Exception):
        BlueRidge.Common.Util.log("PlanJson did not decode", level="error")
        return empty


import java.lang
```

- [ ] **Step 3: Scan and smoke-test from the Script Console**

```bash
cd /c/Users/JacquesPotgieter/Documents/Dev/MPP && ./scan.ps1
```

In the Designer Script Console against `MPP_MES_Dev`:

```python
print BlueRidge.Workorder.DieCastReconciliation.listReasons()
print BlueRidge.Workorder.DieCastReconciliation.getHeaderOrEmpty(-1, -1, -1)
```

Expected: the reason list returns rows; `getHeaderOrEmpty` returns the full `_EMPTY_HEADER` dict (every key present, no `None` for the whole object) rather than raising.

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/DieCastReconciliation
git commit -m "feat(ignition): thin entity script for the die cast shift reconciliation"
```

---

## Task 3: Route + elevation replay entry

**Files:**
- Modify: `ignition/projects/MPP/com.inductiveautomation.perspective/page-config/config.json`
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Common/Session/code.py:301-308`

**Interfaces:**
- Produces: route `/shop-floor/die-cast/reconcile` → `BlueRidge/Views/ShopFloor/DieCastReconcile`; elevation code `DieCastReconcile` → page message `dieCastReconcileRequested`.

Both are shared files other sessions may be touching. Stage them explicitly and make the smallest possible edit.

- [ ] **Step 1: Add the route**

In `pages`, beside the other `/shop-floor/die-cast/*` entries:

```json
"/shop-floor/die-cast/reconcile": {
  "title": "Die Cast Shift Reconciliation",
  "viewPath": "BlueRidge/Views/ShopFloor/DieCastReconcile"
}
```

Edit the file as **text**, not a JSON round-trip — `json.dumps` reformats unrelated compact blocks and produces tens of lines of churn on a file other sessions are editing.

- [ ] **Step 2: Add the replay-map entry**

```python
_ELEVATED_REPLAY_MESSAGES = {
    "DowntimeReason":     "dtReasonSelected",           # Downtime Manager - change/clear a reason
    "DowntimeEdit":       "dtEditRequested",            # Downtime Manager - open the time/remarks editor
    "DowntimeVoid":       "dtVoidRequested",            # Downtime Manager - void an event
    "SortCageMigrate":    "sortCageMigrateAuthorized",  # Sort Cage - re-containerize a serial
    "CrtToggle":          "crtToggleRequested",         # LOT Detail - apply/release a Controlled Run Tag
    "DieMount":           "dieMountRequested",          # Die Cast - open the Die Mount popup, then mount / release
    "DieCastReconcile":   "dieCastReconcileRequested",  # Die Cast - enter the shift reconciliation screen
}
```

- [ ] **Step 3: Scan and verify the route resolves**

```bash
cd /c/Users/JacquesPotgieter/Documents/Dev/MPP && ./scan.ps1
```

Expected: navigating to `/shop-floor/die-cast/reconcile` renders *"View Not Found"* — the route exists, the view does not yet. That is the correct intermediate state and proves the route registered.

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/page-config/config.json ignition/projects/Core/ignition/script-python/BlueRidge/Common/Session/code.py
git commit -m "feat(ignition): route and elevation replay entry for the reconciliation screen"
```

---

## Task 4: The shell view

**Files:**
- Create: `ignition/projects/MPP/.../views/BlueRidge/Views/ShopFloor/DieCastReconcile/{view.json,resource.json}`

**Interfaces:**
- Consumes: `BlueRidge.Common.Session.isElevated / requireElevation`.
- Produces: `view.custom.phase` (`"landing" | "sheet" | "result"`), `view.custom.selection` (`{shiftId, cellLocationId, toolId, shiftLabel}`), and the page messages `reconcileShiftChosen`, `reconcileBackToShifts`, `reconcileSaved`.

**`shiftLabel` travels with the selection** because the result panel (Step 5) and the crumb both name the shift, and the shell reads nothing from the database. The landing already has it on every row (`ListShifts.ShiftLabel`), so passing it costs nothing and keeps the shell free of a lookup it would otherwise need purely to render a heading.

**A view folder needs BOTH `view.json` and `resource.json`** (scope `G`) or the page renders *"View Not Found"*.

- [ ] **Step 1: Write `resource.json`**

```json
{
  "scope": "G",
  "version": 1,
  "restricted": false,
  "overridable": true,
  "files": [
    "view.json"
  ],
  "attributes": {
    "lastModificationSignature": "",
    "lastModification": {
      "actor": "claude",
      "timestamp": "2026-09-29T00:00:00Z"
    }
  }
}
```

- [ ] **Step 2: Write `view.json`**

`custom` block — every one of these is read by a binding, so all are pre-declared with a full shape:

```json
"custom": {
  "phase": "landing",
  "selection": { "shiftId": null, "cellLocationId": null, "toolId": null, "shiftLabel": "" },
  "savedResult": { "NewId": null, "Message": "" }
}
```

Root is `ia.container.flex`, `direction: "column"`, `meta.name: "root"`, with three children whose `position.display` is bound:

| Child | type | `position.display` expression | props.path |
|---|---|---|---|
| `LandingEmbed` | `ia.display.view` | `{view.custom.phase} = "landing"` | `BlueRidge/Components/PlantFloor/DieCastReconcileLanding` |
| `SheetEmbed` | `ia.display.view` | `{view.custom.phase} = "sheet"` | `BlueRidge/Components/PlantFloor/DieCastReconcileSheet` |
| `ResultPanel` | `ia.container.flex` | `{view.custom.phase} = "result"` | — |

`SheetEmbed.props.params` passes `shiftId`, `cellLocationId`, `toolId` from `view.custom.selection`. These are **input-only** params — the sheet reports back by page-scoped message, never by writing through its params.

- [ ] **Step 3: Add the AD gate on startup**

`events.system.onStartup` (NOT `events.component.onStartup`, which never fires):

```python
	# A PIN is presence, never privilege. This screen writes production records,
	# LOT counts and die life into Honda traceability for a shift that is
	# already closed, so it takes an AD credential at the door -- the same
	# per-action elevation path every other protected action uses.
	# On success Session.dispatchElevatedAction re-sends dieCastReconcileRequested,
	# whose handler below simply lets the screen stand.
	if not BlueRidge.Common.Session.isElevated(self.session):
		BlueRidge.Common.Session.requireElevation(
			self.session, "DieCastReconcile", "Reconcile a die cast shift", {})
```

- [ ] **Step 4: Add the three page-scoped message handlers**

`dieCastReconcileRequested` — the elevation replay lands here; nothing to do but stay:

```python
	# Replay hook (Session._ELEVATED_REPLAY_MESSAGES). Fired only after a
	# successful authorization, so the screen is now open to a named person.
	pass
```

`reconcileShiftChosen`, payload `{shiftId, cellLocationId, toolId}`:

```python
	p = BlueRidge.Common.Util.extractQualifiedValues(payload) or {}
	# ONE property write: phase and selection move together, so no binding ever
	# observes a sheet phase against a stale selection.
	self.view.custom.selection = {"shiftId": p.get("shiftId"),
		"cellLocationId": p.get("cellLocationId"), "toolId": p.get("toolId"),
		"shiftLabel": p.get("shiftLabel") or ""}
	self.view.custom.phase = "sheet"
```

`reconcileBackToShifts`:

```python
	self.view.custom.selection = {"shiftId": None, "cellLocationId": None, "toolId": None,
		"shiftLabel": ""}
	self.view.custom.phase = "landing"
```

`reconcileSaved`, payload `{NewId, Message}`:

```python
	p = BlueRidge.Common.Util.extractQualifiedValues(payload) or {}
	self.view.custom.savedResult = {"NewId": p.get("NewId"), "Message": p.get("Message") or ""}
	self.view.custom.phase = "result"
```

All three handlers set `pageScope: true`. View scope does not propagate from an embedded view up to its parent.

- [ ] **Step 5: Build the result panel (spec §7.6)**

`ResultPanel` is the `phase = "result"` child. It carries three things and nothing else:

- a success heading naming the shift — `{view.custom.selection.shiftLabel}`;
- **the reconciliation number**, `{view.custom.savedResult.NewId}`, and the proc's own `Message`;
- a **Back to shifts** button.

Back to shifts sends the message the shell already handles, so the landing reloads and the row now reads *Reconciled · <initials>*:

```python
	system.perspective.sendMessage("reconcileBackToShifts", scope="page")
```

`savedResult` is pre-declared with both keys in Step 2, so this panel never traverses a `None`.

- [ ] **Step 6: Scan and verify**

```bash
cd /c/Users/JacquesPotgieter/Documents/Dev/MPP && ./scan.ps1
```

Expected: `/shop-floor/die-cast/reconcile` opens, the ElevationModal appears immediately, and after a valid AD credential the page shows an empty area (the landing view does not exist yet) rather than a Component Error.

- [ ] **Step 7: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/DieCastReconcile
git commit -m "feat(ignition): reconciliation shell -- route, AD gate, phase"
```

---

## Task 5: The landing view

**Files:**
- Create: `ignition/projects/MPP/.../views/BlueRidge/Components/PlantFloor/DieCastReconcileLanding/{view.json,resource.json}`

**Interfaces:**
- Consumes: `listShifts`, `listUnreconciled`, `Location.Location` press list.
- Produces: page message `reconcileShiftChosen` `{shiftId, cellLocationId, toolId, shiftLabel}`.

**Nothing is pre-selected.** The wrong-shift defect this feature repairs came from a screen that preselected the current shift; this is the single most important behaviour on this view.

- [ ] **Step 1: Declare the custom block**

```json
"custom": {
  "presses": [],
  "selectedPressId": null,
  "rows": [],
  "flagged": [],
  "flaggedCount": 0,
  "days": 7
}
```

`rows` and `flagged` are iterated, so they default to `[]` — never `null`.

- [ ] **Step 2: Build the tile**

A single `ia.input.button` styled as a tile at the top: the count in large type, then *"Shifts not reconciled · last 7 days"*.

`view.custom.flagged` binds to `runScript('BlueRidge.Workorder.DieCastReconciliation.listFlagged', 0, 7)`.
No script transform: the filter lives in the entity module so this tile and the supervisor
dashboard's tile (Task 12) cannot drift apart about the same number. `listFlagged` returns only
the **alerting** claim — production on record with no shift-end number. The idle claim
(`IsAlerting = 0`) is a die left assigned between runs; it fires over every weekend and prep
window, and counting it would train people to ignore amber. Merging the two is forbidden by the
spec, and the read keeps them distinguishable precisely so the screen can filter rather than
re-derive.

The landing's inline idle rows come from the per-press `listShifts` read, not from this one:

```python
	# The tile counts ONLY the alerting claim -- production on record with no
	# shift-end number. The idle claim (IsAlerting = 0) is a die left assigned
	# between runs and fires over every weekend and prep window; counting it
	# would train people to ignore amber. Merging the two is forbidden by the
	# spec, and the read keeps them distinguishable precisely so the screen can
	# filter rather than re-derive.
	return [r for r in (value or []) if r.get("IsAlerting")]
```

`flaggedCount` is `len({view.custom.flagged})`. The tile's colour binds amber on `> 0`.

Clicking the tile does **not** open a separate list — it sets `view.custom.selectedPressId` to the first flagged row's `CellLocationId`, which re-runs the shift list for that press. One view, one read, no second list to keep in sync.

- [ ] **Step 3: Build the press selector and the shift table**

An `ia.input.dropdown` over `view.custom.presses` (`{label, value}` only), with **no default
selection**. The label is the press's **Name alone** — *Machine 11*. **Not** *Machine 11 · Asset #
DC1-M01*: an asset number is a **die's** identifier (`Tools.Tool.Code`, e.g. `DMO125`), while
`DC1-M01` is the machine's Location code, and presenting it as an asset number invents a concept
the plant does not use. Constraint 8's name-then-asset-number order governs **dies**; the die's
asset number appears in the shift table's own *Die asset #* column.

`view.custom.rows` is loaded whenever `selectedPressId` changes, by
`BlueRidge.Workorder.DieCastReconciliation.listShifts(self.view.custom.selectedPressId, 7)`;
an `ia.display.table` binds to it. Columns, each authored with the **full ~25-key column schema** (an abbreviated column, and especially a bare-string `header`, produces a table-wide Component Error):

| field | header.title | notes |
|---|---|---|
| `ShiftLabel` | Shift | bold |
| `AssetNumber` | Die asset # | |
| `ContributionRows` | Entries | numeric |
| `GoodRecorded` | Good recorded | numeric |
| `RecordedTotalShots` | Shift-end reading | numeric; blank reads "none" |
| `StatusCode` | Status | rendered as a chip — see Step 4 |
| `ShiftId` | — | `"visible": false` |
| `ToolId` | — | `"visible": false` |
| `CellLocationId` | — | `"visible": false` |

The three hidden columns **must exist as columns**. `selection.data` is built from the table's `columns`, not from the raw row, so a field with no column entry is absent from the selection payload and `selection.data[0]["ShiftId"]` raises `KeyError`.

- [ ] **Step 4: Map `StatusCode` to its chip**

Status is **neutral where the MES cannot know better** and **amber only for a positive finding**:

| StatusCode | Chip | Tone |
|---|---|---|
| `Open` | Open — live screen owns it | info, **no Reconcile button** |
| `ReleasedNoShiftEnd` | Released, no shift-end number | **amber** |
| `Reconciled` | Reconciled · `LastReconciledBy` `LastReconciledAtEt` | good |
| `EntryRecorded` | Entry recorded | neutral |
| `NoEntry` | No entry | **grey, never amber** — the press may simply not have run |

- [ ] **Step 5: Wire row selection**

Use `onSelectionChange`, not `onRowClick`. Guard on `None`, not falsiness — `if not sel` is true for row 0.

```python
	sel = self.props.selection.data
	if sel is None or len(sel) == 0:
		return
	row = sel[0]
	if row.get("StatusCode") == "Open":
		BlueRidge.Common.Notify.toast("Shift is open",
			"This shift is still running. The live die cast screen owns it.", "info")
		return
	system.perspective.sendMessage("reconcileShiftChosen", payload={
		"shiftId": row.get("ShiftId"), "cellLocationId": row.get("CellLocationId"),
		"toolId": row.get("ToolId"), "shiftLabel": row.get("ShiftLabel")}, scope="page")
```

- [ ] **Step 6: Group a mid-shift die change as two collapsible events**

When two rows share a `ShiftId` but differ in `ToolId`, render them under one collapsible shift header showing both dies. Each remains **its own row and its own reconciliation** — the grouping is presentation only.

- [ ] **Step 7: Scan and verify against Dev**

```bash
cd /c/Users/JacquesPotgieter/Documents/Dev/MPP && ./scan.ps1
```

Expected: the press dropdown lists the die cast machines with **nothing selected**; picking one lists that press's last 7 days with a chip per row; no row is preselected; the tile shows a number that equals the count of `IsAlerting` rows only.

- [ ] **Step 8: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/DieCastReconcileLanding
git commit -m "feat(ignition): reconciliation landing -- press, shifts, and the unreconciled tile"
```

---

## Task 6: The sheet — shell, banner, reason, and load

**Files:**
- Create: `ignition/projects/MPP/.../views/BlueRidge/Components/PlantFloor/DieCastReconcileSheet/{view.json,resource.json}`

**Interfaces:**
- Consumes: `params.shiftId`, `params.cellLocationId`, `params.toolId` (all `paramDirection: "input"`); `getHeaderOrEmpty`, `listEntries`, `listLots`, `listRejects`, `listCavities`, `reasonOptions`.
- Produces: `view.custom.state` (the single shared derived-state owner), and the page messages consumed by Tasks 7–10.

- [ ] **Step 1: Declare the whole custom block up front**

Every key a binding reads, fully shaped. This is the view most likely to produce Component Errors, and every one of them comes from a property that did not exist when a binding first evaluated.

```json
"custom": {
  "header": {
    "ShiftId": null, "ShiftLabel": "", "StartEt": null, "EndEt": null, "IsOpen": false,
    "CellLocationId": null, "PressCode": "", "PressName": "",
    "ToolId": null, "AssetNumber": "", "DieName": "",
    "ActiveCavities": 0, "DieShotCount": 0,
    "RecordedTotalShots": 0, "RecordedWarmUpShots": 0,
    "RecordedNoGood": 0, "RecordedGood": 0,
    "HasShiftEndNumber": false, "Stamp": "",
    "LastReconciledAtEt": null, "LastReconciledBy": ""
  },
  "entries": [],
  "lots": [],
  "rejects": [],
  "cavities": [],
  "reasonOptions": [],
  "state": {
    "actual": { "totalShots": null, "goodShots": null, "warmUpShots": null },
    "reasonId": null,
    "note": "",
    "moves": [],
    "lotLines": [],
    "rejectLines": [],
    "loadedStamp": ""
  },
  "lttInput": "",
  "lttCavityId": null,
  "blockers": [],
  "isEmptyShift": false
}
```

`blockers`, `entries`, `lots`, `rejects`, `cavities`, `moves`, `lotLines`, `rejectLines` are all iterated or measured — `[]`, never `null`.

- [ ] **Step 2: Write `load()` as a root customMethod**

customMethods go on the **root** container. A sibling calls `self.X()`; a view-level event calls `self.rootContainer.X()`; a nested component calls `self.view.rootContainer.X()`.

```python
	shiftId = self.view.params.shiftId
	cellId  = self.view.params.cellLocationId
	toolId  = self.view.params.toolId
	if shiftId is None or cellId is None or toolId is None:
		return

	R = BlueRidge.Workorder.DieCastReconciliation
	header   = R.getHeaderOrEmpty(shiftId, cellId, toolId)
	entries  = R.listEntries(shiftId, cellId, toolId)
	lots     = R.listLots(shiftId, cellId, toolId)
	rejects  = R.listRejects(shiftId, cellId, toolId)
	cavities = R.listCavities(shiftId, toolId)

	self.view.custom.header        = header
	self.view.custom.entries       = entries
	self.view.custom.lots          = lots
	self.view.custom.rejects       = rejects
	self.view.custom.cavities      = cavities
	self.view.custom.reasonOptions = R.reasonOptions()

	# A shift with NOTHING on record is the Machine 202 case this screen exists
	# for. Say so explicitly -- an empty screen must never be mistaken for a
	# failed load.
	self.view.custom.isEmptyShift = (len(entries) == 0 and len(lots) == 0
	                                 and len(rejects) == 0)

	# ONE property write. Seeding state in two steps lets a dirty binding
	# observe a half-loaded sheet and latch. The LOT lines start at their
	# RECORDED value so an untouched LOT contributes its existing number and
	# the totals reconcile before anything is typed.
	self.view.custom.state = {
		"actual": {"totalShots": None, "goodShots": None, "warmUpShots": None},
		"reasonId": None,
		"note": "",
		"moves": [],
		"lotLines": [{"lotId": r.get("LotId"), "ltt": r.get("Ltt"),
		              "toolCavityId": r.get("ToolCavityId"),
		              "quantity": r.get("Recorded"), "isNew": False}
		             for r in lots],
		"rejectLines": [{"defectCodeId": r.get("DefectCodeId"), "itemId": r.get("ItemId"),
		                 "quantity": r.get("Quantity"),
		                 "approvedByUserId": r.get("ApprovedByUserId")}
		                for r in rejects],
		"loadedStamp": header.get("Stamp") or "",
	}
```

**`loadedStamp` is captured here and never recomputed.** It is the stale guard: the Save refuses a stamp that has changed, which is exactly what makes a preview binding.

- [ ] **Step 3: Call `load()` from startup and on any param change**

`events.system.onStartup`:

```python
	self.rootContainer.load()
```

and an `onChange` on each of `params.shiftId` / `params.cellLocationId` / `params.toolId` that calls `self.view.rootContainer.load()`.

- [ ] **Step 4: Build the shift banner**

Large, warning-coloured, the same form as `DieCastShiftConfirm`, always visible:

- `{view.custom.header.ShiftLabel}` in large type, with `StartEt`–`EndEt`;
- press name, then **die name first, `Asset # <AssetNumber>` second**;
- die life `DieShotCount` → the projected after-value **taken from the preview, not computed here** (until a preview has run, show the before value alone);
- *"Reconciling as <name> (<initials>). Everything saved here is recorded under your name."*

- [ ] **Step 5: Build the reason dropdown and its note**

`ia.input.dropdown` over `view.custom.reasonOptions`, bidirectionally bound to `view.custom.state.reasonId`. `options` carry `{label, value}` only; a placeholder is an object, not a string.

A text field bound to `state.note`, its `position.display` bound to whether the selected reason's `RequiresNote` is true.

- [ ] **Step 6: Add the empty-shift banner**

`position.display` bound to `{view.custom.isEmptyShift}`:

> *"Nothing is recorded for this shift on {PressName} — no entries, no LOTs, no rejects. Everything below comes from the press sheet."*

- [ ] **Step 7: Add the HowTo button**

Every shop-floor screen in this project carries one; this is not an exception. An `ia.display.icon` (`material/help_outline`) in the header opening `BlueRidge/Components/Popups/DieCastReconcileHowTo`. `system.perspective.openPopup` from a dom event needs `"scope": "G"` — at `"C"` it silently no-ops.

- [ ] **Step 8: Scan and verify**

Expected: opening a shift from the landing renders the banner with the right shift, press and die; the reason dropdown populates; a shift with nothing recorded shows the empty-shift banner.

- [ ] **Step 9: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/DieCastReconcileSheet
git commit -m "feat(ignition): reconciliation sheet -- banner, reason, and the single load"
```

---

## Task 7: Entries on record, and staging a move

**Files:**
- Modify: `.../DieCastReconcileSheet/view.json`
- Create: `.../views/BlueRidge/Components/Popups/DieCastReconcileMove/{view.json,resource.json}`

**Interfaces:**
- Consumes: `view.custom.entries`, `listMoveTargets`.
- Produces: appends to `view.custom.state.moves` as `[{entityType, entityId, toShiftId}]` — **one element per row id**, expanded from the entry's comma-separated id lists.

- [ ] **Step 1: Render one card per entry**

Each card shows `EnteredAtEt`, `EnteredBy`, `Reading`, `Pieces`, `Lots`, `WarmUpPieces`, `OtherScrapPieces`, `RowCount`.

It states **entered during** (`EnteredDuringShift`) vs **filed under** (the banner's shift). Where they differ, an **amber chip**. That catches Machine 202's night filed as 1st; it does *not* catch Machine 11's 09:35 entry, which is why the card also shows its reading and totals for the team lead to match against the paper.

A card already staged for a move reads *"Moving to 09-16 3rd"* and offers **Undo**.

- [ ] **Step 2: Open the move popup**

```python
	e = BlueRidge.Common.Util.extractQualifiedValues(self.view.params.entry) or {}
	system.perspective.openPopup("mpp-dc-recon-move",
		"BlueRidge/Components/Popups/DieCastReconcileMove",
		params={"popupId": "mpp-dc-recon-move", "replyMessage": "reconcileMoveChosen",
			"entry": e,
			"shiftId": self.view.params.shiftId,
			"cellLocationId": self.view.params.cellLocationId,
			"toolId": self.view.params.toolId,
			"fromShiftLabel": self.view.custom.header.ShiftLabel},
		modal=True, showCloseIcon=True)
```

- [ ] **Step 3: Build the move popup**

`view.custom.targets` (default `[]`) is loaded on startup by
`BlueRidge.Workorder.DieCastReconciliation.listMoveTargets(self.view.params.shiftId, self.view.params.cellLocationId, self.view.params.toolId)`.

It shows the entry's facts; **From** and **To** as large shift names with each shift's `GoodRecorded`; the explicit sentence *"Shots, pieces, LOTs and die life do not change — only which shift is credited."*; and the row count that moves.

**Render whatever arrives.** The target list is the closed shifts within two of this one and legitimately returns fewer than four rows at the ends of history — never assume four, never pad, never pre-select. With zero targets, say so and disable the confirm.

The confirm button's text **names the target**: `MOVE TO 09-16 3RD SHIFT`.

- [ ] **Step 4: Reply, and expand the id lists**

The popup sends `reconcileMoveChosen` `{entryKey, toShiftId, toShiftLabel}` page-scoped. The sheet's handler expands the entry's comma-separated ids into one move element per row:

```python
	p = BlueRidge.Common.Util.extractQualifiedValues(payload) or {}
	entryKey  = p.get("entryKey")
	toShiftId = p.get("toShiftId")
	entry = None
	for e in (self.view.custom.entries or []):
		if e.get("EntryKey") == entryKey:
			entry = e
			break
	if entry is None or toShiftId is None:
		return

	def ids(csv):
		return [int(x) for x in (csv or "").split(",") if x.strip()]

	# The Save takes one element PER ROW, not per entry. The grouping into
	# entries is presentation; ContributionIds / RejectIds are the real targets,
	# which is what stops a wrong grouping ever producing a wrong write.
	staged = [m for m in (self.view.custom.state.moves or [])
	          if m.get("entryKey") != entryKey]
	for cid in ids(entry.get("ContributionIds")):
		staged.append({"entryKey": entryKey, "entityType": "Contribution",
		               "entityId": cid, "toShiftId": toShiftId})
	for rid in ids(entry.get("RejectIds")):
		staged.append({"entryKey": entryKey, "entityType": "Reject",
		               "entityId": rid, "toShiftId": toShiftId})

	st = BlueRidge.Common.Util.convertWrapperObjectToJson(self.view.custom.state)
	st = system.util.jsonDecode(st)
	st["moves"] = staged
	self.view.custom.state = st
```

`entryKey` is carried for the screen's own undo and is **stripped before the Save** (Task 10) — the proc's payload is `{entityType, entityId, toShiftId}` only.

Reading `self.view.custom.state` returns a **live view into the property tree**, not a dict, so the read-modify-write above detaches through a JSON round trip first. Mutating the wrapper and then assigning it back silently loses the nested write.

- [ ] **Step 5: Verify**

Expected: staging a move on a 24-row entry appends 24 elements; Undo removes exactly those; the card's chip updates; nothing is written.

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/DieCastReconcileSheet ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/DieCastReconcileMove
git commit -m "feat(ignition): entries on record, and staging a re-file to the right shift"
```

---

## Task 8: Totals, rejects, and the blocking checks

**Files:**
- Modify: `.../DieCastReconcileSheet/view.json`

**Interfaces:**
- Consumes: `view.custom.header`, `view.custom.state`, `view.custom.cavities`.
- Produces: `view.custom.blockers` — `list[str]`, empty when Save may be attempted.

- [ ] **Step 1: Build the totals block**

Recorded | Actual | Gap across five rows: Total shots, Good shots, Warm-up shots, No-good pieces, Total good pieces.

Recorded comes from `header.RecordedTotalShots` / `RecordedWarmUpShots` / `RecordedNoGood` / `RecordedGood`. Actual for the first three are `ia.input.numeric-entry-field` bound bidirectionally to `state.actual.*`, **each with `deferUpdates: false`**. No-good and Total good are derived.

The component type is `ia.input.numeric-entry-field`. `ia.input.numeric-entry` does not exist and renders "component not found".

- [ ] **Step 2: Build the reject block**

One row per typed line: **QAS (Approved by)**, Reason (defect code), Part (All or one), Amt.

- Approved-by is a dropdown over **all active `Location.AppUser`** rows (every person has one from first PIN sign-in), and may be left empty — an unapproved line is legitimate and becomes its own NULL-approver row.
- Part is a dropdown over `view.custom.cavities` distinct parts, plus **All**. `itemId: null` means All.
- Recorded rows render beside the typed ones from `view.custom.rejects`.

**Sum per defect code on screen.** The read's grain is (DefectCode, Part, Approver), so one defect code on one part approved by two people is two rows. Never read a per-defect total off a single row.

- [ ] **Step 3: Compute the blockers**

This is a **pre-flight mirror of the Save's own refusals, for UX only**. The Save re-runs every one of them and is the authority; if the two ever disagree, the Save wins and this list is the bug.

Bind `view.custom.blockers` to a script transform:

```python
	# UX PRE-FLIGHT ONLY -- see Global Constraint 6. Every check below is
	# re-run by Workorder.DieCastShiftReconciliation_Save, which refuses
	# authoritatively. This list exists so Save can say WHY it is disabled
	# rather than failing on click.
	U  = BlueRidge.Common.Util
	st = U.extractQualifiedValues(self.view.custom.state) or {}
	hd = U.extractQualifiedValues(self.view.custom.header) or {}
	act = st.get("actual") or {}
	lots = st.get("lotLines") or []
	rejs = st.get("rejectLines") or []
	out = []

	if st.get("reasonId") is None:
		out.append("Choose a reason for this reconciliation.")
	elif BlueRidge.Workorder.DieCastReconciliation.reasonRequiresNote(
			st.get("reasonId")) and not (st.get("note") or "").strip():
		# Save line 498 refuses this too.
		out.append("This reason needs a note saying what happened.")

	hasLines = len(lots) > 0 or len(rejs) > 0
	total = act.get("totalShots")
	good  = act.get("goodShots")
	warm  = act.get("warmUpShots")

	# A11: LOT or reject lines require the three actual totals; a save with
	# only moves does not -- the checks below cannot run without them.
	if hasLines and (total is None or good is None or warm is None):
		out.append("Enter the actual total shots, good shots and warm-up shots.")
		return out

	if total is not None and good is not None and warm is not None:
		# EQUALITY, not ">". Save line 782 is `IF @Total <> @Good + @Warm` and
		# refuses either way. A ">"-only mirror leaves total=900 good=750 warm=12
		# with an empty blocker strip and an enabled Save that then fails on click.
		if good + warm != total:
			out.append("Total shots %s should equal good shots %s + warm-up %s = %s. One of them has a typo."
			           % ("{:,}".format(total), "{:,}".format(good),
			              "{:,}".format(warm), "{:,}".format(good + warm)))
		cav    = hd.get("ActiveCavities") or 0
		if cav == 0:
			# Save line 701. Without this the zero makes expected negative and
			# surfaces as a baffling LOT-sum message instead.
			out.append("This die had no active cavities during this shift, so there is nothing to reconcile against.")
			return out
		noGood = sum([(r.get("quantity") or 0) for r in rejs])
		expected = good * cav - noGood
		lotSum   = sum([(l.get("quantity") or 0) for l in lots])
		if lots and lotSum != expected:
			out.append("LOT list totals %s; actual total good is %s. One of them has a typo."
			           % ("{:,}".format(lotSum), "{:,}".format(expected)))
		for l in lots:
			if (l.get("quantity") or 0) > good:
				out.append("%s is %s pieces, more than the shift's %s good shots."
				           % (l.get("ltt"), "{:,}".format(l.get("quantity") or 0),
				              "{:,}".format(good)))
	return out
```

- [ ] **Step 4: Wire Save's enabled state and the reason strip**

`Review & Save`'s `props.enabled` binds to `len({view.custom.blockers}) = 0`. A strip beneath the footer renders each blocker verbatim, so the screen always says *why*.

- [ ] **Step 5: Verify**

Expected: with a deliberate typo (LOT list 11,880 against actual total good 12,960) the strip reads *"LOT list totals 11,880; actual total good is 12,960. One of them has a typo."* and Save is disabled. Clearing the typo enables it.

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/DieCastReconcileSheet
git commit -m "feat(ignition): totals, rejects, and the pre-flight blocking checks"
```

---

## Task 9: The LOT list and the LTT entry bar

**Files:**
- Modify: `.../DieCastReconcileSheet/view.json`

**Interfaces:**
- Consumes: `view.custom.lots`, `view.custom.cavities`, `resolveLtt`.
- Produces: appends to `view.custom.state.lotLines`.

- [ ] **Step 1: Render the LOT list grouped by part**

Grouped by part in the sheet's order (part name, Macola #, sub-total). Per row: LTT, Cav, **Actual qty** (editable, `deferUpdates: false`), Recorded, LOT state, Count before → after.

A row whose `IsLocked` is true shows `LockReason`, and its **Actual stays EDITABLE** — its
production is still recorded in full; only its *count* is left alone.

> **Do not disable that field.** An earlier draft of this plan said the count was "not editable",
> and that was wrong. Spec §3.3 reads *"Counted downstream — Left alone. … The production record
> is still written in full"*, and the Save's step (c) loops `@Plan WHERE Gap <> 0` over **every**
> row, passing `@ApplyToLot = 0` for a locked one — writing the production and skipping the count.
> `@PlanStand = COUNT(*) WHERE IsLocked = 1 AND Gap <> 0` exists *only* to report locked LOTs
> that carry a gap.
>
> Disabling it breaks two things. The confirmation's "Counts left standing" group becomes dead
> code, because `countsStanding` can never be non-zero. And an **under-recorded locked LOT walls
> the sheet**: `lotSum` is pinned to that LOT's `Recorded` while `expected` reflects the real
> production, so the mismatch blocker fires and the team lead cannot clear it — the only way to
> save a correctly-read press sheet becomes putting the missing pieces on a different LOT, which
> is a falsified genealogy row as the escape from a hard block. Dev has zero locked LOTs, so
> nothing catches this before prod, where a shift a few days old has LOTs through Trim already.
>
> The row must still say plainly that this LOT's count will not change even though its production
> is recorded.

- [ ] **Step 2: Build the entry bar**

One LTT at a time, typed or scanned — never a range. LTTs come off a shared stack across the die building, so consecutive numbers say nothing about which press or shift used them, and a range would invent LOTs for tickets that are on no LOT.

A text field bound to `view.custom.lttInput` (`deferUpdates: false`), a cavity dropdown over `view.custom.cavities` shown only when the die has more than one cavity, and an **Add** button. The cursor stays in the LTT field after each add.

- [ ] **Step 3: Resolve each LTT as it is added**

```python
	U = BlueRidge.Common.Util
	ltt = (U.extractQualifiedValues(self.view.custom.lttInput) or "").strip()
	if not ltt:
		return
	toolId = self.view.params.toolId

	st = system.util.jsonDecode(U.convertWrapperObjectToJson(self.view.custom.state))
	lines = st.get("lotLines") or []

	if any([(l.get("ltt") or "") == ltt for l in lines]):
		BlueRidge.Common.Notify.toast("Already on the list",
			"%s is already on this sheet." % ltt, "info")
		self.view.custom.lttInput = ""
		return

	# Resolved AT THE FIELD, never at save -- the team lead finds out now, with
	# the LOT in their hand, not twenty minutes later on a refused save.
	res = BlueRidge.Workorder.DieCastReconciliation.resolveLtt(ltt, toolId)
	result = res.get("Result")

	# Result vocabulary is New | OnThisDie | Elsewhere | Invalid, per
	# Lots.DieCastLot_ResolveLtt. "Error" is the Python wrapper's _EMPTY_LTT
	# default for the not-found path, so it belongs in the refusal set too.
	# NOT "Foreign"/"NewLot" -- those literals exist nowhere, and testing for
	# them lets a foreign LTT through UNREFUSED.
	if result in ("Elsewhere", "Invalid", "Error"):
		# Message is operator-ready prose naming where the LTT belongs.
		BlueRidge.Common.Notify.toast("LTT not added", res.get("Message"), "error")
		return

	cavityId = res.get("ToolCavityId") or U.extractQualifiedValues(self.view.custom.lttCavityId)
	if cavityId is None:
		cavs = U.extractQualifiedValues(self.view.custom.cavities) or []
		if len(cavs) == 1:
			cavityId = cavs[0].get("ToolCavityId")
	if cavityId is None:
		BlueRidge.Common.Notify.toast("Choose a cavity",
			"This die has more than one cavity -- pick the one that cast %s." % ltt, "warning")
		return

	lines.append({"lotId": res.get("LotId"), "ltt": ltt, "toolCavityId": cavityId,
	              "quantity": 0, "isNew": (result == "New")})
	st["lotLines"] = lines
	self.view.custom.state = st
	self.view.custom.lttInput = ""
```

- [ ] **Step 4: Allow removing a staged new LOT**

A new LOT's row carries a remove control. Nothing is written until the confirmation, so removal is purely local.

- [ ] **Step 5: Verify against Dev**

Expected: an unknown valid LTT adds as **New LOT**; an LTT already on this die adds and shows its state; an LTT on another press or die is **refused with the proc's own message naming where it belongs**; a duplicate is ignored with a toast.

**The in-app browser cannot commit input bindings**, so verify what was actually staged by reading it back rather than by looking at the screen.

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/DieCastReconcileSheet
git commit -m "feat(ignition): the LOT list and the per-LTT entry bar"
```

---

## Task 10: The confirmation, and the one write

**Files:**
- Create: `.../views/BlueRidge/Components/Popups/DieCastReconcileConfirm/{view.json,resource.json}`
- Modify: `.../DieCastReconcileSheet/view.json`

**Interfaces:**
- Consumes: `preview`, `save`, `planFrom`.
- Produces: page message `reconcileSaved` `{NewId, Message}`.

**The confirmation renders `PlanJson` and recomputes nothing.** That is the whole point of `@PreviewOnly`: the panel shows the plan the Save itself built, so it cannot promise something the Save will not do.

- [ ] **Step 1: Build the payload, and run the preview**

`Review & Save`:

```python
	U = BlueRidge.Common.Util
	st = system.util.jsonDecode(U.convertWrapperObjectToJson(self.view.custom.state))

	# entryKey is the screen's own undo handle; the proc takes {entityType,
	# entityId, toShiftId} and nothing else.
	moves = [{"entityType": m.get("entityType"), "entityId": m.get("entityId"),
	          "toShiftId": m.get("toShiftId")} for m in (st.get("moves") or [])]
	lots  = [{"lotId": l.get("lotId"), "ltt": l.get("ltt"),
	          "toolCavityId": l.get("toolCavityId"), "quantity": l.get("quantity")}
	         for l in (st.get("lotLines") or [])]

	payload = {
		"shiftId": self.view.params.shiftId,
		"cellLocationId": self.view.params.cellLocationId,
		"toolId": self.view.params.toolId,
		"reasonId": st.get("reasonId"), "note": st.get("note"),
		"actual": st.get("actual") or {},
		"moves": moves, "lots": lots, "rejects": st.get("rejectLines") or [],
		"loadedStamp": st.get("loadedStamp"),
	}

	termId = None
	try:
		termId = self.session.custom.terminal.terminalLocationId
	except:
		termId = None

	res = BlueRidge.Workorder.DieCastReconciliation.preview(
		payload, BlueRidge.Common.Session.currentAppUserId(self.session), termId)

	if not res.get("Status"):
		# A preview that refuses is the Save's own refusal, word for word, and
		# it logs nothing -- a half-typed sheet is typing, not failing.
		BlueRidge.Common.Ui.notifyResult(res, "")
		return

	system.perspective.openPopup("mpp-dc-recon-confirm",
		"BlueRidge/Components/Popups/DieCastReconcileConfirm",
		params={"popupId": "mpp-dc-recon-confirm", "replyMessage": "reconcileConfirmed",
			"plan": BlueRidge.Workorder.DieCastReconciliation.planFrom(res),
			"payload": payload},
		modal=True, showCloseIcon=True)
```

- [ ] **Step 2: Build the confirmation popup**

Full width. The shift in **large type** at the top, then **only the groups that have content**, each a plain sentence with numbers. Drive every group's `position.display` off the plan:

| Group | Shown when | Sentence |
|---|---|---|
| Entries moved | `totals.rowsMoved > 0` | *1 entry (24 rows) moves from … to ….* |
| Production added | `totals.piecesAdded > 0` | *12,960 good pieces credited to 12 LOTs.* |
| Production reduced | `totals.piecesRemoved > 0` | **amber** *72 pieces removed from 10628131 (a correction).* |
| New LOTs | `totals.newLots > 0` | *2 LOTs created and released to Warehouse: ….* (from `lots[].isNew`) |
| LOT counts changed | `totals.countsCorrected > 0` | *6 released LOTs: 10628131 1,788 → 2,868, …* |
| Counts left standing | `totals.countsStanding > 0` | **grey** *10628125 was counted at Trim OUT … — its count stands; its production is still recorded.* (from `lots[].lockReason`) |
| Die life | always | *Asset # DMO125 (…): 15,699 → 16,820 (+1,121 shots).* |

The confirm button **names the shift**: `SAVE 09-17 1ST SHIFT`.

- [ ] **Step 3: Gate reductions behind the tick box**

`plan.hasReduction` is **decided in SQL** and covers a reduction in production, die life or a count — and deliberately not a negative scrap delta, which is scrap being backed out and raises good production.

When it is true, show a checkbox *"I have checked this reduction against the actual count"* and bind the confirm button's `enabled` to it. When false, the button is enabled immediately — additions are the normal case and friction on the normal case trains people to click through.

- [ ] **Step 4: Perform the save on confirm**

The popup replies `reconcileConfirmed` page-scoped with the payload it was given. The sheet's handler:

```python
	p = BlueRidge.Common.Util.extractQualifiedValues(payload) or {}
	termId = None
	try:
		termId = self.session.custom.terminal.terminalLocationId
	except:
		termId = None
	res = BlueRidge.Workorder.DieCastReconciliation.save(
		p.get("payload"), BlueRidge.Common.Session.currentAppUserId(self.session), termId)
	BlueRidge.Common.Ui.notifyResult(res, "Shift reconciled")
	if res.get("Status"):
		system.perspective.sendMessage("reconcileSaved",
			payload={"NewId": res.get("NewId"), "Message": res.get("Message")}, scope="page")
```

A stale-guard refusal arrives here as a plain `Status = 0` with *"This shift changed since you opened it"*. Re-run `load()` on that message so the team lead sees current data rather than a sheet that can no longer save.

- [ ] **Step 5: Wire Discard through `ConfirmUnsaved`**

Dirty check first; a clean sheet closes immediately. Route the choice back via the page-scoped `confirmUnsavedResult` message. Wire **both** the footer Discard and any header X.

- [ ] **Step 6: Verify**

Expected: a preview on a sheet with a reduction opens the panel with the amber group and a disabled confirm until the box is ticked; confirming writes one reconciliation and the result panel shows its number; a second confirm of the same payload is refused by the stale guard.

- [ ] **Step 7: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/DieCastReconcileConfirm ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/DieCastReconcileSheet
git commit -m "feat(ignition): the confirmation panel, previewed through the Save itself"
```

---

## Task 11: The HowTo popup

**Files:**
- Create: `.../views/BlueRidge/Components/Popups/DieCastReconcileHowTo/{view.json,resource.json}`

- [ ] **Step 1: Author the guide**

An `ia.display.markdown`. Two traps, both silent:

- the text goes in **`props.source`**; `props.markdown` is an options object and a string there renders nothing;
- **`markdown.escapeHtml` defaults to `true`** — leave it and the operator reads `<div style="...">` on screen.

HTML inside renders through a plain HTML pipeline, not the Perspective layout engine: nested tables, every style inline, web-safe fonts, **literal hex colours** (not `var(--mpp-*)`), on a dark surface with light text.

Cover: what Recorded and Actual mean; that nothing is written until the confirmation; what a move does and does not change; why an LTT is refused; what "count stands" means.

- [ ] **Step 2: Generate rather than hand-edit, and verify**

A guide body is one multi-kilobyte string inside a `view.json`; hand-editing is how an unclosed tag swallows the rest of the page invisibly. Extend `tools/gen_howto_views.py`, which carries a verifier for every failure mode above.

- [ ] **Step 3: Commit**

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/DieCastReconcileHowTo tools/gen_howto_views.py
git commit -m "feat(ignition): how-to popup for the reconciliation screen"
```

---

## Task 12: The supervisor dashboard tile

**Files:**
- Modify: `.../views/BlueRidge/Views/ShopFloor/SupervisorDashboard/view.json`

This is an **existing** view. See "Editing existing views" above — file editing is cleared only while Jacques's Designer is on another gateway. **Re-confirm before starting.** Do this task last regardless: it is the most likely place for a conflict.

- [ ] **Step 1: Add the tile**

**Shifts not reconciled** — a count, amber when non-zero, matching the existing tiles' shape. It binds to `runScript('BlueRidge.Workorder.DieCastReconciliation.listFlagged', 0, 7)` — the **same function** Task 5's tile uses, so the two tiles cannot disagree. The count is the alerting claim **only**.

- [ ] **Step 2: Navigate on tap**

```python
	system.perspective.navigate(page="/shop-floor/die-cast/reconcile")
```

The shell's own AD gate handles authorization; the tile does not gate.

- [ ] **Step 3: Verify and commit**

Expected: the tile's number equals the count of `IsAlerting` rows and never includes idle shifts. Confirm by comparing against `SELECT COUNT(*) ... WHERE IsAlerting = 1` on Dev.

```bash
git add ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/SupervisorDashboard
git commit -m "feat(ignition): shifts-not-reconciled tile on the supervisor dashboard"
```

---

## Task 13: Live smoke on the Dev gateway

**Files:** none — this is verification.

Nothing before this has driven the procs from Perspective. Plan 1's Dev smoke ran them inside a rolled-back transaction.

- [ ] **Step 1: Confirm Dev carries the current procs**

```bash
sqlcmd -S localhost -d MPP_MES_Dev -E -C -h -1 -W -Q "SET NOCOUNT ON; SELECT CASE WHEN OBJECT_ID('Workorder.DieCastShiftReconciliation_ListCavities') IS NULL THEN 'MISSING ListCavities' ELSE 'ok' END; SELECT CASE WHEN OBJECT_DEFINITION(OBJECT_ID('Workorder.DieCastShiftReconciliation_Save')) LIKE '%PreviewOnly%' THEN 'ok' ELSE 'Save is STALE -- reapply' END;"
```

Expected: `ok` twice. Tasks 17/18 of Plan 1 were committed but **not** applied to Dev until 2026-09-29; do not assume.

- [ ] **Step 2: Walk the whole flow with elevation BYPASSED**

**Decided 2026-09-29 (Jacques): the Dev gateway has no AD identity provider configured, so an
elevation can never complete on it. Smoke the screen with the gate bypassed and accept the AD
gate itself as untested until prod.** This is pre-existing
(`notes/2026-08-19_backlog_crt_and_shop_floor.md` item 4.3), not caused by this feature.

How to bypass without weakening anything: **dismiss the ElevationModal** (the screen renders
beneath it — verified in Tasks 4 and 5) and **sign in with a PIN** at the terminal. The PIN sets
`session.custom.appUserId`, which is what `Common.Session.currentAppUserId` returns and what the
Save stamps, so attribution works and the write path is exercised end to end. Do **not** edit the
gate out of the view to make this easier — the shipped code must carry the gate.

Then walk it: every popup in spec §7; a blocked save for **each** blocking check; a reduction that
needs its tick box; a move; a new LTT; a locked LOT whose count stands.

**What this leaves untested, and must therefore be verified in the prod window:** that
`requireElevation` → credential → `dispatchElevatedAction` actually replays
`dieCastReconcileRequested` and lands the team lead on a working screen, and that the Save is then
attributed to the **supervisor** rather than to whoever was PIN-signed-in. Both are in the runbook.

- [ ] **Step 3: Confirm what was written**

For the reconciliation id the result panel names, check `Workorder.DieCastShiftReconciliation`, `DieCastReconciliationMove`, the `DieCastContribution` rows' `ShiftAttributionSourceId` = `Reconciled`, the anchor with reason `ShiftReconciliation`, and **`Audit.OperationLog`** — *not*
`Audit.ConfigLog`. The Save calls `Audit_LogOperation`: this is a production event, and
`ConfigLog` sits on a sliding-retention `TRUNCATE` window for configuration changes.

- [ ] **Step 4: Record the outcome in `PROJECT_STATUS.md`**

Append; never rewrite another session's entry.

---

## Not in this plan

- **The 2026-09-17 Machine 11 acceptance replay.** It needs production rows this machine cannot reach. The read-only extract that collects them is `sql/scratch/Run-ReconcileReplayExtract.ps1` (2026-09-29); Jacques runs it and returns the CSVs, and the fixture is built from those rows — never reconstructed.
- Trim's equivalent screen (spec §10).
- The supervisor dashboard's own redesign — one tile only.
- AD **role** gating. Any active AD-mapped user may reconcile until roles land.
- Reject reports adopting the new approver column.
- Changes to the live die cast entry / release screens.

## Release

Plan 1's SQL and Plan 2's resources ship in **one window** — the screen is useless without the procs and the procs are inert without the screen. Full contract applies (`prod-release-context-pack/`): preview, rehearsal against live data, fingerprint-guarded execute, scoped exports built from git and verified against HEAD (**Core first, then MPP**), and a published runbook.

Two deployment facts the runbook must carry, both from Plan 1: `0098`'s constraint validation is **not partition-aware** and scans every partition of `Workorder.RejectEvent` under a whole-table `Sch-M` lock; `0099`'s `ADD ... NOT NULL ... DEFAULT` on `DieCastContribution` is **not metadata-only on Standard Edition** and rewrites the table. **Both need the presses idle.** Migration `0100` (elevation ceiling) is a one-row table and carries no such concern.

---

## Revision history

| Date | Change |
|---|---|
| 2026-09-29 | Initial plan, written against the frozen Plan 1 contracts (captured from `sys.dm_exec_describe_first_result_set`) and the five scope questions answered by Jacques on 2026-09-29. |
