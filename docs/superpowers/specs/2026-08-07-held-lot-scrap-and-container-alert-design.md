# Held-LOT scrap + container-hold advisory — design (FAT-QH-150, FAT-QH-170)

**Brief:** F (`docs/handoffs/2026-08-07-fat-remediation-handoffs.md`)
**Date:** 2026-08-07
**Author:** Blue Ridge Automation
**FAT rows closed:** FAT-QH-150 (partial disposition of a held LOT), FAT-QH-170 (container hold integration alert)
**Branch:** `jacques/working` · repeatable procs only (no new versioned migration)

---

## 1. Problem & direction

### FAT-QH-150 — dispose against a held LOT
The FAT step expects an operator to dispose part of a held LOT. Today the only disposition
path for a held LOT is `Lots.Lot_Split`, which **rejects** any split of a `BlocksProduction=1`
LOT (`R__Lots_Lot_Split.sql` held-guard) — so there is no way to scrap from a held LOT at all.

**Jacques's direction (overrides FRS/FDS on this row):** do **not** split the held LOT. Register
scrap **directly against the held LOT** using the exact same `RejectEvent` + quantity-decrement
mechanism scrap uses everywhere else. No split, no hold release. The hold stays in place.

### FAT-QH-170 — container advisory on hold
Holding a LOT SHOULD alert the operator about containers associated with that LOT (FDS-08-007,
SHOULD-level). Today `Quality.Hold_Place` does no association lookup and the Hold Management view
shows no such notice.

---

## 2. Current state (evidence)

- **Canonical scrap proc** `Workorder.RejectEvent_Record` (`R__Workorder_RejectEvent_Record.sql`)
  writes one `Workorder.RejectEvent` row and decrements the LOT's materialised B5 quantities
  (`PieceCount` / `InventoryAvailable`); closes-at-zero when the LOT was `Good`. Its held-LOT guard
  (the INLINED mirror of `Lots.Lot_AssertNotBlocked`) **rejects** any LOT whose status
  `BlocksProduction=1` or is `Closed`:

  ```sql
  IF @Blocks = 1 OR @StatusCode = N'Closed'   -- rejects Hold(2), Scrap(3), Closed(4)
  ```

  It is a standalone status-row proc (`SELECT @Status,@Message,@NewId`) invoked via the NQ
  `workorder/RejectEvent_Record` and entity `BlueRidge.Workorder.RejectEvent.record`. It is
  **not** captured inside any open caller transaction on the held-LOT path (the UI calls it
  directly) — so reusing it here is legal under the INSERT-EXEC / Msg-3915 rule (unlike the
  Trim/Machining fan-out, which inlines).

- **LOT status codes** (`0004_phase3_reference_lookups.sql`): `Good`=1 (Blocks 0), `Hold`=2
  (Blocks 1), `Scrap`=3 (Blocks 1), `Closed`=4 (Blocks 0).

- **Container ↔ LOT associations** (no direct `Container.LotId` column):
  1. **FG-lot-is-a-tray:** `Lots.ContainerTray.FinishedGoodLotId` → `Lots.Lot` (migration 0034,
     1:1). A held finished-good LOT is one tray inside a container.
  2. **Producing LOT of serialized parts:** `Lots.SerializedPart.ProducingLotId` → the LOT, joined
     to a container via `Lots.ContainerSerial.SerializedPartId → ContainerId`. A held casting /
     sub-assembly LOT whose parts were etched into containers.

- **Hold Management view** (`BlueRidge/Views/ShopFloor/HoldManagement/view.json`): panels for
  Place Hold, Bulk Hold, Release Hold; open-holds repeaters bound to `Quality.Hold_ListOpen`
  (via `BlueRidge.Quality.Hold.listOpen`). Place Hold resolves a LOT name → id via
  `BlueRidge.Lots.Lot.getByName`, calls `BlueRidge.Quality.Hold.place`, toasts the result.

- **Defect-code dropdown:** `BlueRidge.Quality.DefectCode.getForDropdown(operationTypeCode=None)`
  returns plant-wide active codes as `[{label, value}]` when no operation type is given.

---

## 3. Approved design

### 3.1 QH-150 — scrap against a held LOT (reuse `RejectEvent_Record`)

**Decision: reuse the canonical `Workorder.RejectEvent_Record`, gated by a new flag.** The brief
explicitly permits reuse here (standalone scrap against one LOT, not nested in a split), and it is
"the same way scrap is recorded elsewhere" that Jacques asked for.

1. **Add param** `@AllowHeldLot BIT = 0` (trailing, default 0 — backward compatible with every
   existing caller: die-cast, Trim, ProductionEvent, tests).

2. **Relax the held-guard, tightly scoped to `Hold` only:**

   ```sql
   -- Held(2)/Scrap(3) block, Closed(4) blocks. When @AllowHeldLot=1 the scrap
   -- path may proceed against a Hold LOT specifically; Scrap and Closed remain blocked.
   IF (@Blocks = 1 AND NOT (@AllowHeldLot = 1 AND @StatusCode = N'Hold'))
      OR @StatusCode = N'Closed'
   ```

   A `Scrap`-status LOT (already fully scrapped) and a `Closed` LOT are still rejected — the
   exception is scoped to the Hold state only.

3. **Close-at-zero is deliberately NOT extended to held LOTs.** The existing close-at-zero block is
   gated on `@CurrentStatusId = @GoodStatusId`; a held LOT's current status is `Hold`, so scrapping
   its last piece leaves it **Held at 0 pieces**. This is correct: the hold lifecycle owns the
   LOT's terminal transition — the operator resolves the LOT through hold release / disposition, not
   an implicit auto-close. (Documented in the proc header.)

4. **Subtractive decrement:** the held-LOT scrap passes `@OperationTypeCode = NULL`, so
   `@Additive = 0` (default) → the LOT is decremented, exactly like downstream scrap. Quantity is
   still bounded by remaining pieces (existing validation + TOCTOU re-check under `UPDLOCK`).

5. **Wiring:**
   - NQ `workorder/RejectEvent_Record/query.sql`: add `@AllowHeldLot = :allowHeldLot`.
   - Entity `BlueRidge.Workorder.RejectEvent.record(data, appUserId, terminalLocationId,
     allowHeldLot=False)`: pass the flag through (default preserves all current callers).
   - **UI:** a new **"Scrap Held LOT"** panel in the Hold Management view (mirrors the Place Hold
     panel): LOT name (scan/type), Defect code (dropdown ← `getForDropdown()` plant-wide), Quantity,
     optional Remarks, and a **Record Scrap** button. The button resolves the LOT via
     `Lot.getByName`, guards that the LOT is actually held (`Hold.getOpenByLotOne(...).IsHeld`),
     then calls `RejectEvent.record({...}, allowHeldLot=True)`, toasts the result, and bumps
     `refreshToken`. This keeps the change to the single `HoldManagement/view.json` (no shared
     `HoldRow` edit → smaller blast radius, one scan lane).

**Audit:** unchanged — `RejectEvent_Record` already emits the `RejectEvent · … · Reject` op and (on
close-at-zero, not reached here) a status-change op. No new audit surface.

### 3.2 QH-170 — associated-container advisory on hold-place

**Decision: a dedicated read proc + NQ, surfaced by the view after a successful hold-place.**
`Quality.Hold_Place` is a single-result-set mutation proc (FDS-11-011) and **cannot** return a
second result set for the advisory — the JDBC-correct realisation of "return an advisory the view
renders" is a separate read the view calls on success.

1. **New read proc** `Quality.Hold_ListAssociatedContainers @LotId BIGINT` — returns the DISTINCT
   containers associated with the LOT via **both** association paths, with display columns:

   ```
   ContainerId, ItemPartNumber, ItemDescription, CurrentLocationName,
   ContainerStatusCode, AssociationKind ('FinishedGoodTray' | 'SerializedPart')
   ```

   - Path A: `Lots.ContainerTray.FinishedGoodLotId = @LotId → ContainerId`.
   - Path B: `Lots.SerializedPart.ProducingLotId = @LotId`
     → `Lots.ContainerSerial.SerializedPartId → ContainerId`.
   - `UNION` (distinct) the two, join `Container`/`Item`/`Location`/`ContainerStatusCode` for the
     display columns. Read-only; no audit; empty result = no associated containers. Timestamps n/a.

2. **NQ** `quality/Hold_ListAssociatedContainers` (read; `execList`), entity method
   `BlueRidge.Quality.Hold.listAssociatedContainers(lotId)` → `list[dict]`.

3. **View:** after a successful **single** Place Hold on a LOT, the PlaceButton script calls
   `listAssociatedContainers(lotId)`; when non-empty it (a) sets a shaped custom prop
   `view.custom.containerAdvisory = {"lotName": ..., "containers": [...]}` rendered by an advisory
   banner panel (visible only when `len(containers) > 0`, listing container id / part / location /
   status), and (b) toasts `"N associated container(s) — review whether they need holding too."`
   The banner has a dismiss (clears the prop). Advisory-only: no auto-hold, no mutation. Bulk Hold
   is out of scope for the banner (would be noisy across many LOTs).

---

## 4. Guardrails honoured

- **Hold invariant relaxed for scrap ONLY.** `@AllowHeldLot` defaults 0; the relaxation is scoped
  to `@StatusCode = 'Hold'`. `Lot_AssertNotBlocked` (production moves / checkouts / advances) is
  **unchanged** — holds still block everything except this one scrap path. FRS/FDS override for
  QH-150 documented here and in the proc header.
- **No business logic in Python.** The guard relaxation and the association query live in SQL; the
  entity methods are thin pass-throughs; the view scripts only marshal params + render.
- **FDS-11-011 / INSERT-EXEC / Msg-3915.** `RejectEvent_Record` keeps its single status-row shape
  and its "all rejecting validations before `BEGIN TRANSACTION`" structure. The held-LOT scrap
  calls it directly from the UI (not via INSERT-EXEC), so the reuse is legal. The new read proc has
  no OUTPUT params and one result set.
- **ASCII-only** for any new seed/string literals (none of ZPL scope here).
- **Ignition file-edit boundary / single-lane scan.** One view edited (`HoldManagement/view.json`);
  `.\scan.ps1` after the Ignition changes.

## 5. Files

| Layer | File | Change |
|---|---|---|
| Proc | `sql/migrations/repeatable/R__Workorder_RejectEvent_Record.sql` | add `@AllowHeldLot`; relax guard; header note |
| Proc | `sql/migrations/repeatable/R__Quality_Hold_ListAssociatedContainers.sql` | **new** read proc |
| NQ | `ignition/projects/Core/ignition/named-query/workorder/RejectEvent_Record/query.sql` | add `:allowHeldLot` |
| NQ | `ignition/projects/Core/ignition/named-query/quality/Hold_ListAssociatedContainers/` | **new** (query.sql + resource.json) |
| Entity | `BlueRidge/Workorder/RejectEvent/code.py` | `allowHeldLot=False` passthrough |
| Entity | `BlueRidge/Quality/Hold/code.py` | `listAssociatedContainers(lotId)` |
| View | `BlueRidge/Views/ShopFloor/HoldManagement/view.json` | Scrap-Held-LOT panel + advisory banner + `containerAdvisory` custom prop |
| Test | `sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/020_HeldLot_Scrap.sql` | **new** (QH-150) |
| Test | `sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/025_Hold_AssociatedContainers.sql` | **new** (QH-170) |

## 6. Test plan (TDD)

**QH-150 (`020_HeldLot_Scrap.sql`)** — seed an item + a `Good` LOT with N pieces; place a hold.
- deprecated/legacy control: reject with `@AllowHeldLot=0` against the held LOT → **Status 0**, LOT unchanged.
- `@AllowHeldLot=1`, valid defect + qty < N → **Status 1**; one `RejectEvent` row; `PieceCount` decremented by qty; LOT **still `Hold`** (status 2), hold still open.
- `@AllowHeldLot=1`, qty = N (scrap all) → **Status 1**; `PieceCount = 0`; LOT **still `Hold`** (NOT auto-closed).
- `@AllowHeldLot=1` against a `Scrap`(3) LOT → **Status 0** (exception is Hold-only).
- `@AllowHeldLot=1` against a `Closed`(4) LOT → **Status 0**.
- qty ≤ 0 / deprecated defect → **Status 0** (existing validations still fire).

**QH-170 (`025_Hold_AssociatedContainers.sql`)** — seed a container with a tray whose
`FinishedGoodLotId` = the held LOT (Path A) and a serialized part `ProducingLotId` = another LOT in
a second container (Path B).
- `Hold_ListAssociatedContainers` for the FG LOT → returns the tray's container (AssociationKind `FinishedGoodTray`).
- for the producing LOT → returns the serial's container (`SerializedPart`).
- for a LOT with no containers → empty result.
- distinctness: a LOT linked through both paths to the same container returns that container once.

Both files follow the `test.BeginTestFile` / `Assert_IsEqual` / `EndTestFile` harness with
explicit setup + teardown (FK-safe delete order: HoldEvent → RejectEvent → ContainerSerial →
SerializedPart → ContainerTray → Container → LotStatusHistory/closure → Lot), keyed off a unique
test PartNumber.

## 7. Out of scope

- LOT-detail-page scrap affordance (the Hold Management panel satisfies the FAT row; a LOT-detail
  button is a later nice-to-have to avoid a second view edit / scan lane this round).
- Bulk-hold container advisory.
- Any change to `Lot_Split`, `Lot_AssertNotBlocked`, or the hold release flow.
