# Arc 2 Phase 2 — LOT Detail View (Ignition) — Design

**Date:** 2026-06-12
**Status:** Draft for review
**Scope:** One Perspective view — the polymorphic **LOT Detail** screen — plus its NQ/entity-script plumbing and one small new SQL read proc. First of the four deferred Phase 2 views (LOT Detail, LOT Search, Genealogy Viewer, Paused-LOT Indicator).

## 1. Source of truth

The design is the existing canonical mockup: `mockup/plantFloor.html` → section `data-route="lot/detail"` ("LOT DETAIL (polymorphic — Phase 2)"). This spec does **not** redesign it — it scopes the mockup to what the shipped Phase 2 SQL (migration `0021`) can back, and pins the data contract.

**Polymorphism is the core concept:** one view serves every LOT regardless of phase or origin. Tool/Cavity header rows render only when `Lot.ToolId` is populated (Die-Cast origin); they are hidden for Received / Machining-origin LOTs.

## 2. Layout (faithful to mockup)

- **Header:** `LOT Detail · <LotName>`, meta line `<Item> · <origin> · single view across all phases`, status pill (LOT status / MESL grade).
- **KPI strip:** LOT Name · Item · Piece Count (sub: "Inventory Available · N in process") · Current Location · **Tool · Cavity (polymorphic, conditional on `ToolId`)**.
- **Tabs:** History · Genealogy · Paused-at · Linked Container.
- **Actions:** Back to Home; Place Hold + Scrap (rendered but disabled/stubbed — see §4).

## 3. Data contract — Phase 2 procs → NQs → entity methods

All reads. NQs live in **Core** (`named-query/lots/...`), `type:"Query"`, `database:"MPP"`; entity methods on `BlueRidge.Lots.Lot` via `Common.Db.execList`/`execOne`. No view calls `system.db.*`.

| UI section | Proc (shipped 0021 unless noted) | New NQ | Entity method |
|---|---|---|---|
| Header + KPIs + polymorphic Tool/Cavity | `Lots.Lot_Get` (returns `ToolId`, `ToolCavityId`, `TotalInProcess`, `InventoryAvailable`, `CurrentLocationName`, `LotStatusCode`) | `lots/Lot_Get` | `Lot.get(lotId)` |
| History tab | `Lots.Lot_GetAttributeHistory` (UNION: attribute + status + movement) | `lots/Lot_GetAttributeHistory` | `Lot.getHistory(lotId)` |
| Genealogy tab | `Lots.Lot_GetParents`, `Lots.Lot_GetChildren` (one-hop edges; tree proc reserved for the standalone Genealogy Viewer) | `lots/Lot_GetParents`, `lots/Lot_GetChildren` | `Lot.getParents(lotId)`, `Lot.getChildren(lotId)` |
| Paused-at tab | **NEW** `Lots.LotPause_GetByLot @LotId` — open pauses for one LOT across all Locations (mirror of `LotPause_GetByLocation`, keyed by LotId) | `lots/LotPause_GetByLot` | `Lot.getPauses(lotId)` |

**`Tool`/`Cavity` name resolution:** `Lot_Get` returns FK ids, not codes. Resolve the Tool code/Cavity number either by extending `Lot_Get`'s SELECT (preferred — one join) or a sibling read. Decide at build; lean toward extending `Lot_Get` since the header always needs it.

## 4. Stubs (later-phase, drawn as empty-states like the mockup)

- **Linked Container tab** — Phase 6 schema; static "Not yet containerized / Container links land at Assembly" empty-state.
- **History production rows** (Die Cast Event, ShotCount, RejectEvent) — Phase 3 evidence writers; History shows only the movement/status/attribute streams until then.
- **Place Hold** (Phase 7) / **Scrap** (Phase 3) actions — render disabled with a "future phase" tooltip, or hide behind a build flag. No wiring.

## 5. New SQL — `LotPause_GetByLot`

`CREATE OR ALTER PROC Lots.LotPause_GetByLot @LotId BIGINT` → single result set `(LocationId, LocationName, PausedByUserId, PausedByInitials, PausedAt, PausedReason)` for rows where `ResumedAt IS NULL`, ordered by `PausedAt`. Mirror `LotPause_GetByLocation`'s shape/joins, swap the predicate to `LotId`. FDS-11-011 single-result-set. New test in `sql/tests/0021_PlantFloor_Lot_Lifecycle/` asserting count + shape; suite stays green.

## 6. Conventions

- MPP project (operator-facing), `parent=Core`. View under `BlueRidge/Views/...`; route added to `page-config`.
- Pre-declare every bound `view.custom.*` prop with a shaped default; binding sources return shaped-empty (`_EMPTY_*`), never `None`/`{}`.
- Tabs via the established tab pattern (typed style-class slots). Conditional rows via `position.display`, not `meta.visible` (tabular KPI exception aside).
- Read-only screen → no `editDraft`, no status-row procs, no mutations this push.
- `ia.display.table` columns (if used for History/Genealogy lists) carry the full ~25-key schema.
- File-author the new view + NQs + proc; `scan.ps1`; **no gateway restart** needed.

## 7. Done when

- `/lot/detail?lotId=<id>` (or scan-routed) renders a LOT: header + polymorphic Tool/Cavity, History (3 streams), Genealogy (parents/children), Paused-at (live), Container stub.
- `LotPause_GetByLot` shipped + tested; SQL suite green.
- Designer smoke: a Die-Cast LOT shows Tool/Cavity; a Received LOT hides them; a LOT paused at a Cell shows in Paused-at.

## 8. Out of scope (other Phase 2 views, separate specs)

LOT Search, Genealogy Viewer (tree), Paused-LOT Indicator. LOT Detail links out to them but they are designed/built separately.
