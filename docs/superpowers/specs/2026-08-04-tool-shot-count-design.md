# Tool (Die) Shot Count — Design Spec

**Date:** 2026-08-04
**Author:** Blue Ridge Automation
**FAT items:** #26 (shot-limit property + total-shots display), #27 (update mechanism)
**Status:** Approved for planning
**Branch:** `claude/tool-shot-count` (off `jacques/working`)

---

## 1. Problem

A die-cast **die** (a `Tools.Tool` of `ToolType = Die`) wears with every shot (cycle). MPP
wants to (a) see how many shots a die has taken over its life, and (b) set an optional
**shot limit** so operators/engineers are warned when a mounted die nears or exceeds it.

Today the die's shot count is **not persisted anywhere**:

- Migration `0010` created `Tools.Tool` with the explicit comment *"No shot counter — derived
  from `Workorder.ProductionEvent` group-by."*
- The per-cavity lifecycle redesign (migration `0045`, 2026-07-29) removed die-cast's use of
  `ProductionEvent` entirely. Die-cast now writes `Workorder.DieCastContribution` (net **good
  pieces** per cavity) + additive `Workorder.RejectEvent` rows.
- The operator enters a **gross shot count** per die per shift on the shift-output screen, but it
  is passed only to the read-only `Workorder.DieCast_GetShiftOutputBreakdown` to *propose* a
  per-cavity split. `Workorder.DieCastShiftOutput_Record` (the write proc) does **not** take it,
  so **the gross shot count is discarded.**

Critically, **shots ≠ pieces**: one shot on an N-cavity die makes N castings, and gross also
includes scrap and shot-loss cycles. So the existing `DieCastContribution` (net good pieces)
**cannot** reconstruct a die's shot count. The one authoritative number is the operator-entered
gross shot count — which must be captured to build this feature.

## 2. Approach (decided)

A **materialized running counter on the die**, incremented live in the same transaction that
records shift output. No event ledger; no reconciliation job.

| Decision | Choice | Rationale |
|---|---|---|
| Where the total lives | New `Tools.Tool.ShotCount` (materialized, lifetime) | B5 materialized-quantity pattern (mirrors `Lot.PieceCount`). Read is O(1); no group-by. |
| How it updates | **Live in-transaction increment** on the die-cast shift-output Submit | The count is always current — this *obsoletes* FAT #27's "daily trigger" rather than building it. |
| What a "shot" is | The operator-entered **gross shot count** on the shift-output Submit | The only authoritative cycle count. Shots ≠ pieces. |
| Shot-loss path | Does **not** increment | Gross already counts those cycles; a separate bump would double-count. |
| Limit basis | `Tools.Tool.ShotLimit` (nullable), **lifetime** | Chosen over since-maintenance. No maintenance-reset this pass (deferred). |
| Event ledger / reconcile | **None** | Shots can't be reconstructed from pieces, so a ledger's only value is future OEE shot-rate rollups — not a current workstream. Additive to introduce later (`Tools.ToolShotEvent`) if that lands; history would start then, same position as now. |
| Scope | **Die-type tools only** | Non-die tools keep `ShotCount = 0` / `ShotLimit = NULL`; no badge. |
| "Near limit" threshold | 90% (hardcoded in reads, documented) | No config knob (YAGNI). |

### Why not the alternatives (recorded, not to re-litigate)

- **Reconcile from `DieCastContribution`** — impossible: pieces ≠ shots (multi-cavity + scrap +
  shot-loss).
- **Retrofit `ProductionEvent` for die shots** — reverses part of the `0045` redesign and
  overloads a LOT-scoped table with a die-scoped concept.
- **Event ledger + nightly reconcile** — no independent source exists to reconcile *against*
  (the counter would be recomputed from itself), so it adds a table with no drift-correction
  value today.

## 3. Schema — migration `0050_tool_shot_count.sql`

Additive `ALTER`s to `Tools.Tool` (idempotent guards; `WITH VALUES` so existing rows backfill 0):

```sql
ALTER TABLE Tools.Tool ADD ShotCount INT NOT NULL DEFAULT 0 WITH VALUES;  -- materialized lifetime total
ALTER TABLE Tools.Tool ADD ShotLimit INT NULL;                            -- optional lifetime limit; NULL = untracked
```

- `INT` matches the existing `@GrossShots INT` and all die-cast piece columns. A die's lifetime
  shots (≤ low millions) are far below `INT` max (2.1B) — no overflow risk.
- No new `Audit.LogEntityType` / `LogEventType` rows: `Tool` is already entity Id 31; `ShotLimit`
  edits log through the existing `Tool_Update` → `Audit_LogConfigChange` path, and the increment
  is part of the already-audited shift-output operation.
- No backfill of `ShotCount` from history — no historical shot data exists to backfill from.
  Counting starts from the first shift-output Submit after deploy.

## 4. Stored procedures (repeatable, file-safe, TDD)

### 4.1 `Workorder.DieCastShiftOutput_Record` → v1.2 (increment)

- Add parameter `@GrossShots INT = NULL` (last, defaulted — backward compatible).
- **Pre-transaction validation** (with the other rejecting checks, per the Msg-3915 rule): if
  `@GrossShots IS NOT NULL AND @GrossShots < 0` → `GOTO Fail` with a clean `Status = 0`.
- **Inside the existing transaction**, when `@GrossShots > 0`:
  ```sql
  UPDATE Tools.Tool WITH (UPDLOCK, HOLDLOCK)
  SET ShotCount = ShotCount + @GrossShots,
      UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @AppUserId
  WHERE Id = @ToolId;
  ```
  (row-locked increment, mirroring the per-LOT `PieceCount` increment already in this proc).
- `@GrossShots` NULL or 0 ⇒ no increment. The standalone shot-loss path (`registerShotLoss`
  → `recordShiftOutput` with no gross) therefore never bumps the counter.
- Bump the header comment version to v1.2 with a changelog line.

### 4.2 `Tools.Tool_Update` → add `@ShotLimit`

- Add parameter `@ShotLimit INT = NULL`.
- **Die-only guard** (mirrors the existing `@DieRankId` rule): if `@ShotLimit IS NOT NULL AND
  @ToolTypeCode <> 'Die'` → reject `'ShotLimit is only valid for Die-type Tools.'`.
- `SET ShotLimit = @ShotLimit` in the `UPDATE`. Include the old `ShotLimit` in the audit
  `@OldValue` JSON and the new value flows through `@Params` (audit `@NewValue`).
- **Caller contract:** the tool editor loads current `ShotLimit` into `editDraft` and passes it
  back on every save (standard editDraft pattern) — otherwise a save would null it out. Documented
  for the Designer punch-list.

### 4.3 `Tools.Tool_Get` + `Tools.Tool_List` → surface shot fields

Add to both result sets:

| Column | Definition |
|---|---|
| `ShotCount` | `t.ShotCount` |
| `ShotLimit` | `t.ShotLimit` |
| `ShotsRemaining` | `ShotLimit IS NULL → NULL`, else `ShotLimit - ShotCount` (negative = over by N) |
| `PercentOfLimit` | `ShotLimit IS NULL OR 0 → NULL`, else `CAST(ShotCount AS DECIMAL(9,2)) * 100 / ShotLimit` |
| `IsNearLimit` | `1` when `ShotLimit > 0 AND ShotCount >= 0.9*ShotLimit AND ShotCount < ShotLimit`, else `0` |
| `IsOverLimit` | `1` when `ShotLimit IS NOT NULL AND ShotCount >= ShotLimit`, else `0` |

`IsNearLimit` and `IsOverLimit` are mutually exclusive (near = approaching but not yet over).

### 4.4 `Tools.Tool_GetShotStatusForCell` — NEW (station badge read)

```
@CellLocationId BIGINT
```

Returns the shot status of the die **currently mounted** on the cell (via the active
`Tools.ToolAssignment` — `ReleasedAt IS NULL`), joined to `Tools.Tool`:
`ToolId, ToolCode, ToolName, ShotCount, ShotLimit, ShotsRemaining, PercentOfLimit, IsNearLimit,
IsOverLimit` (same computed columns as §4.3). **Empty result set** when nothing is mounted
(FDS-11-011: empty = not found, no invented row). One result set, no OUTPUT params.

## 5. Ignition layer (file-safe: entity Python + named queries)

- **NQ** `workorder/DieCastShiftOutput_Record` — add the `grossShots` parameter.
- **NQ** `tools/Tool_Get`, `tools/Tool_List` — no param change; result sets widen automatically.
- **NQ** `tools/Tool_GetShotStatusForCell` — new (`type: "Query"`).
- **Entity** `BlueRidge.Workorder.DieCast.recordShiftOutput` — read `grossShots` from the `data`
  dict and add it to the proc params (default `None`).
- **Entity** `BlueRidge.Tools.Tool` — `update(...)` passes `shotLimit`; add a
  `getShotStatusForCell(cellLocationId)` reader. (Confirm exact module path during planning.)
- Run `.\scan.ps1` after NQ changes.

## 6. Perspective display — Designer punch-list (flagged; NOT in automated-test scope)

These edit **existing** `view.json` files → Designer work per the file-edit boundary. None are on
the do-not-touch list.

1. **`DieCastBody` submit payload** — include `grossShots` (already in view scope; it drove the
   breakdown) in the dict passed to `recordShiftOutput`. *Required* for the counter to move.
2. **Die-cast station badge** — for the mounted die, show total / limit / % via
   `Tool_GetShotStatusForCell`, colored on `IsNearLimit` (warn) / `IsOverLimit` (danger).
3. **Config-Tool tool detail/editor** — display `ShotCount` + `ShotLimit` + remaining/%, and add a
   `ShotLimit` numeric input bound into the tool `editDraft`.

## 7. Testing (sqlcmd harness, `MPP_MES_ToolShots` throwaway DB)

New tests under `sql/tests/0050_ToolShotCount/`:

1. **Increment happy path** — Submit with `@GrossShots = 500` bumps `Tool.ShotCount` by 500; a
   second Submit of 300 accumulates to 800.
2. **No-op paths** — `@GrossShots` NULL and `@GrossShots = 0` leave `ShotCount` unchanged; the
   shot-loss-only path (`registerShotLoss`) does not bump it.
3. **Negative gross rejected** — `@GrossShots = -1` returns `Status = 0` with a clean message and
   **no** increment (rejected pre-transaction).
4. **Rollback safety** — a Submit that fails inside the transaction (e.g. an invalid line) leaves
   `ShotCount` unchanged.
5. **`Tool_Update` ShotLimit** — set a limit on a Die; read it back via `Tool_Get`; non-Die
   rejection; clearing to NULL.
6. **Computed fields** — `Tool_Get`/`Tool_List`: no-limit → `ShotsRemaining`/`PercentOfLimit` NULL
   and both flags 0; below 90% → flags 0; at/above 90% but below limit → `IsNearLimit = 1`; at/above
   limit → `IsOverLimit = 1`, `ShotsRemaining` negative when over.
7. **`Tool_GetShotStatusForCell`** — mounted die returns one row with correct fields; cell with no
   active assignment returns an empty set.

Follow the sqlcmd test conventions: `INSERT ... EXEC` into a temp table matching each proc's SELECT
shape; teardown respects FK order (audit/child rows before `AppUser`/`Tool`).

## 8. Out of scope / deferred

- OEE Performance / shot-rate rollups and any `Tools.ToolShotEvent` ledger (additive later).
- Shots-since-maintenance and any maintenance-reset action (deferred with the lifetime-only
  decision).
- FAT #27's "daily trigger" as a distinct gateway job — obsoleted by the live increment.

## 9. Shared-environment guardrails

- Branch `claude/tool-shot-count` only; explicit-path staging (a pre-existing `M package.json`
  from another session must never be swept in). No `Co-Authored-By: Claude` trailer.
- DB validation on the throwaway `MPP_MES_ToolShots` only — never reset/migrate `MPP_MES_Dev`,
  never use `MPP_MES_Test`.
- Migration number `0050` (verified free: `0049_session_policy` is the current highest; re-confirm
  no collision immediately before writing the file).
- Do-not-touch (parallel sessions): `Quality.DefectCode*` / DefectCode views / RejectPanel;
  AppHeader, NavigationTree, CellContextSelector, MoveOverride, `Location`/`Terminal`/`code.py`,
  `Common/Session/code.py`, session-props, MPP_Config Users view.
```

## 10. Revision history

| Date | Change |
|---|---|
| 2026-08-04 | Initial design — approved for planning. |
