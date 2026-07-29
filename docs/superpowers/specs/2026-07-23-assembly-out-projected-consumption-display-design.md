# Assembly OUT — Projected Per-Container Component Consumption + Low-Stock Indicator (display-only)

**Date:** 2026-07-23
**Status:** Design note + implementation plan (server-side ready to build; view wiring is a *coordination note* — see §5)
**Author:** Blue Ridge Automation
**Scope tag:** MVP polish on the built Assembly OUT flow (Arc 2 Phase 6). Display-only. **NOT a gate / precheck.**

---

## 1. Intent (locked with the customer)

On the **Assembly OUT** view (`AssemblyNonSerialized`), the right-hand panel already lists the **line inventory** — the components physically at the cell (`ComponentsPanel` / `InventorySidebar`, fed by `Lots.Lot_GetComponentsAtCell`). This feature *annotates* that list so each component also shows:

1. **Projected remaining consumption** — how many of that component will be consumed to **complete the current container**.
2. **A LOW indication** — flagged when on-hand line inventory for the component **cannot cover** that projected remaining need.

Customer was explicit: *"not that complicated."* This is a read-only annotation. It **does not block** Complete Tray or Complete Container — the authoritative sufficiency check already lives inside `Workorder.Assembly_CompleteTray` (the pre-transaction short-list, and the in-transaction drained-mid-consume re-check). This feature just gives the operator advance warning so they can stage stock before they run short.

---

## 2. The calculation (grounded in `R__Workorder_Assembly_CompleteTray.sql`)

The completion proc is the source of truth for consumption math. Two facts drive it:

- **Per-tray consumption of a BOM child** = `CAST(bl.QtyPer * @PieceCount AS INT)`, where `@PieceCount` = the tray's part count = **`ContainerConfig.PartsPerTray`** (the proc rejects a tray whose count ≠ `PartsPerTray`, line 154). So per-tray need is effectively `CAST(QtyPer * PartsPerTray AS INT)`.
- **Container target** = `TraysPerContainer * PartsPerTray` (`TargetParts`, computed identically in `Container_GetOpenByCell` line 28 and the proc's `@FullTarget`/`@Target`).

**Open-container state** (already surfaced by `Lots.Container_GetOpenByCell`, bound to `view.custom.container`):
- `AccumulatedParts` = `SUM(ContainerTray.PartsClosedCount WHERE ClosedAt IS NOT NULL)`
- `ClosedTrays` = count of closed trays
- `TargetParts`, `TraysPerContainer`, `PartsPerTray`

**Remaining work to finish the container** (whole trays, because a tray is atomic — one `CompleteTray` call = one full `PartsPerTray` tray):

```
RemainingTrays = MAX(TraysPerContainer - ClosedTrays, 0)
PerTrayNeed    = CAST(QtyPer * PartsPerTray AS INT)          -- mirrors the proc's per-tray CAST exactly
ProjectedRemainingConsumption = PerTrayNeed * RemainingTrays
```

`PerTrayNeed * RemainingTrays` is used (rather than the prompt's `QtyPer * (TargetParts − AccumulatedParts)`) because it **reproduces the proc's tray-by-tray integer CAST exactly** — no fractional-rounding drift between the projection and what the container will actually consume. For whole-tray configs the two are identical; this one is provably consistent with the gate.

**On-hand** must be computed with the **exact same pool the proc drains**, so the number reconciles with the completion gate (see §6 note):

```
OnHand = ISNULL(SUM(l.InventoryAvailable), 0)
         FROM Lots.Lot l JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
         WHERE l.ItemId = <component>
           AND l.CurrentLocationId = @CellLocationId     -- EXACT cell (matches CompleteTray), NOT descendants
           AND sc.Code <> N'Closed'
```

**Low:**

```
IsLow = (OnHand < ProjectedRemainingConsumption) ? 1 : 0
Shortfall = MAX(ProjectedRemainingConsumption - OnHand, 0)   -- for tooltip / severity
```

---

## 3. SQL / NQ surface (the piece to build now)

### 3.1 New read proc — `Workorder.Assembly_GetComponentProjection`

Co-located in the **`Workorder`** schema next to `Assembly_CompleteTray` so the BOM×tray consumption math has one home. Read proc, JDBC-compatible (FDS-11-011): **no OUTPUT params, single result set, empty set = nothing to show.**

```sql
CREATE OR ALTER PROCEDURE Workorder.Assembly_GetComponentProjection
    @CellLocationId     BIGINT,
    @FinishedGoodItemId BIGINT,
    @ClosureMethod      NVARCHAR(20) = NULL
AS
```

**Why the proc resolves geometry itself (no business logic in Python):**
1. Resolve the **open container** at the cell for `@FinishedGoodItemId` (same query as `Container_GetOpenByCell` / the proc's `@OpenCid`). If found → take `TraysPerContainer`, `PartsPerTray` from its `ContainerConfig`, and `ClosedTrays` from its closed trays.
2. If **no open container** → resolve the active `ContainerConfig` by `(@FinishedGoodItemId, @ClosureMethod)` (the exact resolution `Assembly_CompleteTray` step 4b uses) with `ClosedTrays = 0` → a *fresh full-container* projection.
3. Resolve the active BOM (`TOP 1 … ORDER BY VersionNumber DESC`, mirroring the proc).
4. Emit one row per BOM line.

If any of {FG id null, no active BOM, no resolvable ContainerConfig} → **return the empty set** (the view renders nothing / a dash). No invented error.

### 3.2 Return shape (one row per active-BOM component, `ORDER BY PartNumber`)

| Column | Type | Meaning |
|---|---|---|
| `ChildItemId` | BIGINT | component part id |
| `ItemPartNumber` | NVARCHAR | for display (matches existing column naming) |
| `ItemDescription` | NVARCHAR | |
| `QtyPer` | DECIMAL(18,4) | BOM qty per finished part |
| `PerTrayNeed` | INT | `CAST(QtyPer * PartsPerTray AS INT)` |
| `RemainingTrays` | INT | `MAX(TraysPerContainer - ClosedTrays, 0)` |
| `ProjectedRemainingConsumption` | INT | `PerTrayNeed * RemainingTrays` |
| `OnHand` | INT | exact-cell available (see §2) |
| `Shortfall` | INT | `MAX(Projected - OnHand, 0)` |
| `IsLow` | BIT | `OnHand < Projected` |

Column names deliberately echo `Lot_GetComponentsAtCell` (`ItemPartNumber` / `ItemDescription`) so the view transform stays familiar.

### 3.3 New Named Query — `workorder/Assembly_GetComponentProjection` (Core)

Per the *NQs in Core only* topology. `type: "Query"` is fine (this is a plain `SELECT`-returning read, not a status-row mutation).

```sql
EXEC Workorder.Assembly_GetComponentProjection
    @CellLocationId     = :locationId,
    @FinishedGoodItemId = :finishedGoodItemId,
    @ClosureMethod      = :closureMethod
```

### 3.4 Core entity method — `BlueRidge.Workorder.Assembly.getComponentProjection`

```python
def getComponentProjection(cellLocationId, finishedGoodItemId, closureMethod, _refreshToken=None):
    """Per-component projected remaining consumption + low-stock flag for the
       Assembly OUT display. Thin: passes args, returns list[dict]. Empty = nothing
       to show. All math lives in Workorder.Assembly_GetComponentProjection."""
    cellLocationId = _u(cellLocationId); finishedGoodItemId = _u(finishedGoodItemId)
    if cellLocationId is None or finishedGoodItemId is None:
        return []
    return BlueRidge.Common.Db.execList("workorder/Assembly_GetComponentProjection",
        {"locationId": cellLocationId, "finishedGoodItemId": finishedGoodItemId,
         "closureMethod": closureMethod})
```

Zero domain decisions in Python (honors *No business logic in Python*). `_refreshToken` is the ignored runScript re-read arg, consistent with `getComponentsAtCell` / `getOpenByCell`.

---

## 4. Display / binding — **COORDINATION NOTE, do not assume current structure**

> ⚠️ **`AssemblyNonSerialized/view.json` is being actively rewritten by another session.** Do **not** author view edits against the structure captured here — it may not survive. The section below is the *contract* the rewrite should wire to, plus a drop-in fallback if the rewrite keeps today's label-based inventory panel.

**Contract for whoever owns the view:**

- Add custom prop **`view.custom.componentProjection`** with a **fully-shaped default `[]`** (pre-declare rule — anything iterated/`len()`'d needs a `[]` default or it renders as a Component Error before first eval).
- Bind it via `runScript`, reusing the **same FG-id coalesce the existing `fgConfig` binding already uses** (`coalesce(container.ItemId, selectedFinishedGoodItemId)`) plus the session closure method and the existing `refreshToken`:

  ```
  if({view.custom.refreshToken} >= 0 && !isNull({session.custom.cell.locationId}),
     runScript("BlueRidge.Workorder.Assembly.getComponentProjection", 0,
               {session.custom.cell.locationId},
               coalesce({view.custom.container.ItemId}, {view.custom.selectedFinishedGoodItemId}),
               {session.custom.closureMethod},
               {view.custom.refreshToken}),
     [])
  ```

- The binding source **always returns a shaped list** (empty list, never `None`) so no null-traversal error.
- Rendering (preferred): a **flex-repeater** over `componentProjection`, one card per component — `ItemPartNumber` · `OnHand` on-hand · `ProjectedRemainingConsumption` needed, with a LOW pill (`meta.visible`/style gated on `IsLow`, e.g. a `psc-pf` warning chip). This is the clean replacement for the current mono-text `queueByPartVertical` label.
- Rendering (fallback if the rewrite keeps the label panel): a Python `script` transform that folds the rows into the existing `pre-line` text, appending `— LOW (need N, have M)` when `IsLow`. Mirrors the existing `queueByPartVertical` transform so it slots in with minimal churn.

**Refresh:** it already rides the existing `refreshToken` (bumped on tray complete, container complete, and the `inventoryChanged` page message). No new refresh plumbing.

**Which panels:** the projection is meaningful for **ByCount / ByWeight** flavors (operator-facing component list). ByVision shows a camera pane, not a component list — leave it as-is (out of scope), consistent with today's `ComponentsPanel` visibility gating.

---

## 5. Coordination with the active `AssemblyNonSerialized` rewrite

- **Build & land the server-side piece independently** — the proc, NQ, and entity method touch **no view files** and are safe to commit while the rewrite is in flight.
- Hand the rewrite owner the **§3.4 method signature + §4 binding contract + §3.2 columns**. They wire `view.custom.componentProjection` when convenient; the two streams don't collide.
- Do **not** file-edit the existing `AssemblyNonSerialized/view.json` (Ignition file-edit boundary — existing views are Designer-owned; and this one has a concurrent editor). If this session must demonstrate the view end, do it *after* the rewrite lands, in Designer.
- The Core entity file `…/BlueRidge/Workorder/Assembly/code.py` may also be touched by the rewrite — append the new method; coordinate the merge (small, additive).

---

## 6. Edge cases

| Case | Behavior |
|---|---|
| **No open container yet** (first tray of the shift) | Proc resolves `ContainerConfig` by `(FG, ClosureMethod)`, `ClosedTrays = 0` → projection = full fresh container (`PerTrayNeed * TraysPerContainer`). Requires an FG selected in the dropdown (the coalesce yields `selectedFinishedGoodItemId`). Before any FG is chosen → FG id null → **empty set** (nothing shown). |
| **Over-target container** (the container-24 incident: 5 trays closed vs 4-tray config) | `RemainingTrays = MAX(4 - 5, 0) = 0` → `Projected = 0`, `IsLow = 0` for every line. Never negative. |
| **Component fully drained** (`OnHand = 0`) while work remains | `IsLow = 1`, `Shortfall = Projected`. Exactly the advance warning the feature is for. |
| **No active BOM / FG not eligible at cell** | Empty set. (The proc does not re-run the eligibility reject — it's display-only; but no BOM ⇒ no rows anyway.) |
| **Fractional `QtyPer`** | `CAST(QtyPer * PartsPerTray AS INT)` per tray, matching the proc's own CAST — display equals reality. |
| **`OnHand` vs the completion gate** | Both use `CurrentLocationId = @CellLocationId` (exact cell) + `sc.Code <> 'Closed'` + `SUM(InventoryAvailable)`. Note the *display list* (`Lot_GetComponentsAtCell`) uses `@IncludeDescendants` + ancestor logic — a **different, wider** pool. The projection deliberately uses the **narrower exact-cell** pool so `OnHand` and `IsLow` reconcile with what `CompleteTray` will actually consume. Flag on the view if the two panels ever show different totals for the same part — that's the descendants-vs-exact-cell difference, by design. |

---

## 7. Phased TDD plan (server-side only)

New suite file: `sql/tests/0028_PlantFloor_Assembly/094_Assembly_ComponentProjection.sql` (sits beside `092_Assembly_CompleteTray.sql` / `093_…_by_method.sql`). Build proc test-first; each phase red → green.

- **Phase 1 — mid-fill open container (core happy path).**
  Config 4 trays × 10 parts (Target 40); 2 trays closed (Accumulated 20, ClosedTrays 2 ⇒ RemainingTrays 2).
  BOM: component A `QtyPer 1` → PerTrayNeed 10, Projected 20; stage OnHand 25 → `IsLow 0`, `Shortfall 0`.
  Component B `QtyPer 2` → PerTrayNeed 20, Projected 40; stage OnHand 30 → `IsLow 1`, `Shortfall 10`.
  Assert full row shape + ordering by PartNumber.

- **Phase 2 — fresh, no open container.** Same config, no container. Pass `@ClosureMethod`. Expect `RemainingTrays = 4`, `Projected = PerTrayNeed × 4`, resolved via `(Item, ClosureMethod)` ContainerConfig.

- **Phase 3 — over-target guard.** 5 trays closed against a 4-tray config → `RemainingTrays 0`, `Projected 0`, `IsLow 0` for all lines. No negatives.

- **Phase 4 — empty sets.** (a) `@FinishedGoodItemId = NULL` → 0 rows. (b) FG with no active BOM → 0 rows. (c) FG with no resolvable ContainerConfig for the method → 0 rows.

- **Phase 5 — OnHand pool fidelity.** Seed the component across: a LOT at the exact cell (counts), a LOT at a **descendant** location (must **not** count — exact-cell rule), a **Closed** LOT at the cell (must not count), a LOT with `InventoryAvailable = 0`. Assert `OnHand` = only the exact-cell non-closed available sum, matching `Assembly_CompleteTray`'s pre-check pool.

- **Phase 6 — reconciliation with the gate.** For a given fixture, assert the proc's per-line `OnHand`/`Projected` agree with what `Assembly_CompleteTray`'s short-list would compute for the *next* tray (`PerTrayNeed`), i.e. the projection's first-tray slice equals the gate's per-tray need. Guards against the two drifting apart in future edits.

Verify per `sql_version_control_guide.md`: run the new suite against a throwaway `MPP_MES_Test` (never a destructive reset of `MPP_MES_Dev`). Do **not** run migrations/tests as part of this design task — that's the build session's job.

---

## 8. Open questions (flagged for the customer / build session)

1. **Projected = whole remaining container, or just the next tray?** This note assumes **whole remaining container** (`PerTrayNeed × RemainingTrays`), matching the prompt's "consumed to COMPLETE the container." If the customer actually wants the *next tray only*, `RemainingTrays` collapses to 1 — trivial to switch. **(Recommend: whole container.)**
2. **`IsLow` — boolean or severity?** This note returns a `BIT` + a `Shortfall` int. If the customer wants a gradient (e.g. amber "tight" when OnHand covers ≥1 but not all remaining trays vs red "short now"), derive it from `OnHand` vs `PerTrayNeed` (can't cover even the next tray = red) vs `Projected` (can't cover the full container = amber). **(Recommend: start with the boolean; `Shortfall` is already there if they want to upgrade.)**
3. **Fresh-container projection before an FG is chosen** — currently shows nothing until the operator picks the finished good. Acceptable? (Alternative: pre-select via the existing `getRecommendedFinishedGoodId` on startup, which the view already calls — so in practice a recommendation is usually pre-filled.)
4. **Schema home** — proposed `Workorder.Assembly_GetComponentProjection` (next to the consumption proc). If the team prefers reads under `Lots`, rename; no logic changes. **(Recommend: Workorder, to keep consumption math co-located.)**
5. **Weight/vision flavors** — projection is defined for count-based tray geometry. ByWeight closes on a target weight at the PLC; the tray still carries `PartsPerTray`, so the math holds, but confirm the ByWeight panel should show it. ByVision is out of scope (camera pane, no list).
```
