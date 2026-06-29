# Die Rank Compatibility — bundled SaveAll backend

**Date:** 2026-06-22
**Author:** Blue Ridge Automation
**Status:** Design — pending review
**Scope tag:** MVP (supports OI-05 / FDS-05-025..030 die-rank merge compatibility)

## Problem

The Die Ranks admin popup (`BlueRidge/Components/Popups/DieRanks`) presents the
cross-rank merge-compatibility matrix as a symmetric grid and edits the whole
matrix locally (`view.custom.bodyRows`, toggled via `handleToggle`). It has a
single **Save** button — which is currently a stub (`toast('Saved (stub)')`); no
DB write occurs.

The only persistence proc today is `Tools.DieRankCompatibility_Upsert`, which
writes **one pair at a time**. There is no atomic "save the whole matrix"
backend, so a single Save click cannot persist a multi-cell edit in one
transaction with one audit entry.

This is the same shape the codebase already solves for other whole-collection
editors via a `*_SaveAll` proc taking a JSON array (`Tools.ToolAttribute_SaveAll`,
`Parts.RouteTemplate_SaveAll`, `Location.Location_SaveAll`, etc.).

## What already exists (not rebuilt)

- `Tools.DieRankCompatibility` table — canonical pair storage `(RankAId <= RankBId)`,
  `CanMix BIT`, unique pair, indexes (migration `0010`).
- Procs: `_Upsert`, `_List`, `_GetPair`, `_Remove` (all audit-wired).
- Named queries: `parts/DieRankCompatibility_Upsert`, `parts/DieRankCompatibility_List`.
- Merge enforcement: `Lots.Lot_Merge` consults the matrix per distinct rank pair
  and rejects uncovered / `CanMix=0` pairs (supervisor-override path).
- Python surface: `BlueRidge.Parts.DieRank` (`getCompatibilityMatrix`,
  `setCompatibility`, matrix instance builders).

## Out of scope (deferred per instruction)

- No Python `saveAll()` helper in `BlueRidge.Parts.DieRank`.
- No popup wiring (the stub Save stays a stub for now).

The **named query is the delivered boundary** — callable later via
`BlueRidge.Common.Db.execMutation("parts/DieRankCompatibility_SaveAll", {...})`.

## Deliverables

### 1. Stored procedure `Tools.DieRankCompatibility_SaveAll`

Modeled on `Tools.ToolAttribute_SaveAll`. FDS-11-011 compliant (no OUTPUT params;
single `SELECT @Status, @Message, @NewId` on every exit path).

**Signature**

```sql
CREATE OR ALTER PROCEDURE Tools.DieRankCompatibility_SaveAll
    @RowsJson  NVARCHAR(MAX),   -- [{ "RankAId": <bigint>, "RankBId": <bigint>, "CanMix": <0|1> }, ...]
    @AppUserId BIGINT
```

**JSON shape** — Ids, not Codes. Code→Id resolution stays in the (future) Python
layer, exactly as the existing per-cell `setCompatibility` does. This keeps the
proc consistent with the rest of the Tools proc layer.

**Reconciliation model: upsert-only, never delete.**
For each payload row, canonicalize to `(Lo, Hi)` = `(min(RankAId,RankBId), max(...))`,
then:
- canonical pair exists → `UPDATE CanMix, UpdatedAt` (only when `CanMix` differs).
- canonical pair absent → `INSERT (RankAId=Lo, RankBId=Hi, CanMix, CreatedAt)`.
- existing rows **not** in the payload → **left untouched** (no delete).

`CanMix` is stored exactly as sent (including `0`). Omitting a pair from the
payload does NOT clear it — a pair is only changed by being present in the
payload.

**Validations (all run BEFORE `BEGIN TRANSACTION`** — proc returns a status row
and may be captured via `INSERT-EXEC`, so a `ROLLBACK` outside `CATCH` would
throw Msg 3915):
1. `@AppUserId` not null. (`@RowsJson` null/empty is treated as `[]` → no-op success.)
2. Every row has non-null `RankAId`, `RankBId`, `CanMix`.
3. Every referenced rank exists in `Tools.DieRank` and is active (`DeprecatedAt IS NULL`).
4. No duplicate canonical pair within the payload (would make the upsert ambiguous).

Self-pairs (`RankAId = RankBId`) are permitted (consistent with `_Upsert`); the
matrix UI never emits them but the proc does not reject them.

Each rejecting validation: set `@Message`, `EXEC Audit.Audit_LogFailure`
(`@LogEntityTypeCode = N'DieRankCompatibility'`, `@LogEventTypeCode = N'Updated'`),
`SELECT @Status, @Message, @NewId`, `RETURN` — with no open transaction.

**Audit (success path):** one `Audit.Audit_LogConfigChange`
(`DieRankCompatibility` / `Updated` / `Info`), built from pre-mutation state:
- Action narrative using `+` (inserted pair) and `~` (CanMix changed) symbols
  (no `-` kind — this model never deletes), capped with
  `Audit.ufn_TruncateActivity`. Pair labels use rank `Code`s joined by a `×`
  glyph emitted as `NCHAR(215)` (never a literal non-ASCII char — mirrors the
  precedent's `NCHAR(8212)`/`NCHAR(8594)` usage so it survives sqlcmd codepage
  decoding); the `0→1` arrow uses `NCHAR(8594)`. Middle-dot framing via
  `Audit.ufn_MidDot()`, matching the `<SUBJECT> · <CATEGORY> · <ACTION>`
  convention.
- `@OldValue` / `@NewValue`: resolved-name JSON arrays of the affected pairs
  (`{RankA:{Id,Code}, RankB:{Id,Code}, CanMix}`) per the audit convention.
- A genuine no-op (payload changes nothing) still logs once with an action of
  `No-op save` (mirrors `ToolAttribute_SaveAll`).

**Return contract:** `@Status BIT`, `@Message NVARCHAR(500)`, `@NewId BIGINT`.
There is no single parent entity, so `@NewId` echoes the **count of rows in the
payload** (kept for `*_SaveAll` family consistency; callers ignore it).

### 2. Named query `parts/DieRankCompatibility_SaveAll`

Thin `EXEC` wrapper + `resource.json`, mirroring `parts/ToolAttribute_SaveAll`:

```sql
-- @rowsJson  NVARCHAR(MAX)
-- @appUserId BIGINT
EXEC Tools.DieRankCompatibility_SaveAll
    @RowsJson  = :rowsJson,
    @AppUserId = :appUserId
```

`resource.json`: `scope DG`, `database MPP`, parameters `rowsJson` (`sqlType 7`),
`appUserId` (`sqlType 3`) — same metadata block as the sibling SaveAll NQs.

### 3. Tests

Extend `sql/tests/0018_Tools_DieRank/010_DieRank_crud.sql` (or a sibling file)
with SaveAll cases, captured via `INSERT … EXEC` into a temp table matching the
`Status/Message/NewId` shape:
- **Insert path:** SaveAll with two new pairs → both rows present, canonical order.
- **Update path:** SaveAll a pair with flipped `CanMix` → row updated, still one row.
- **Canonicalization:** SaveAll `(B,A)` resolves to the same canonical row as `(A,B)`.
- **No-delete:** a pre-existing pair omitted from a later payload survives.
- **Reject:** payload referencing a deprecated/nonexistent rank → `Status = 0`,
  no rows written.
- **Duplicate pair in payload:** → `Status = 0`.

## Files

| Action | Path |
|---|---|
| Create | `sql/migrations/repeatable/R__Tools_DieRankCompatibility_SaveAll.sql` |
| Create | `ignition/projects/Core/ignition/named-query/parts/DieRankCompatibility_SaveAll/query.sql` |
| Create | `ignition/projects/Core/ignition/named-query/parts/DieRankCompatibility_SaveAll/resource.json` |
| Modify | `sql/tests/0018_Tools_DieRank/010_DieRank_crud.sql` (add SaveAll cases) |

## Risks / notes

- Repeatable migration (`R__`) — re-runnable `CREATE OR ALTER`, no SchemaVersion bump.
- Upsert-only means the matrix admin can never "clear" a pair to default by
  un-checking and saving when the popup omits unchanged cells; the popup must send
  every cell it wants to set (including explicit `CanMix=0`). Documented here so
  the future wiring step sends the full grid, not just toggled deltas.
- ASCII-only string **literals** in the proc per project convention; any
  non-ASCII glyph in audit prose is emitted via `NCHAR()` (e.g. `NCHAR(215)` for
  `×`, `NCHAR(8594)` for the arrow), never as a literal char in the `.sql` file —
  so a byte scan of the migration stays clean.
