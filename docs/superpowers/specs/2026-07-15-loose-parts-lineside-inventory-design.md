# Loose-Parts (Non-LOT) Lineside Inventory — Design Spec

**Date:** 2026-07-15
**Status:** Draft — awaiting Hunter review
**Author:** Blue Ridge (with Claude)
**Arc / Phase:** Arc 2 (Plant Floor) — extends the Spec 2 machining/assembly flow. Adds a second, non-LOT inventory representation for purchased/loose components and folds a "receive by part# + qty" path into the lineside inventory check-in popup.
**Related:** `docs/superpowers/specs/2026-07-02-machining-assembly-plant-floor-flow-design.md` (I1/I2 — the `InventoryManager` popup + `Lot_GetLineInventoryByPart`), `docs/superpowers/specs/2026-07-07-terminal-mint-model-and-rename-bom-removal-design.md` (assembly consume-mint). Reference impl reused: `Views/ShopFloor/ReceivingDock` (part#-scan → `Received` LOT mint).

---

## 1. Motivation

The lineside inventory check-in popup (`Components/PlantFloor/InventoryManager`) today has a single input — **scan an LTT** — which resolves an *existing* LOT by name and moves it onto the line (`Lots.Lot_MoveToValidated`). It cannot handle the common plant-floor reality that MPP raised: **operators frequently receive a box of loose parts that has no LTT** — they have a part number and a piece count, nothing more.

Today the only way such parts enter the system is as a `Received`-origin LOT (the Receiving Dock flow), which then feeds Assembly BOM consumption with full LOT genealogy. For the components in question — generic purchased hardware (pins, studs, dowels, fasteners) — MPP does **not** want per-part LOT genealogy; they want a simple **on-hand count per part per line** that Assembly draws down automatically as finished goods are built.

This spec adds that second, deliberately-lighter inventory representation and threads it through the check-in popup and `Assembly_CompleteTray`, **without disturbing** the LOT/genealogy path that castings, sub-assemblies, and traceable components continue to use.

---

## 2. Decisions locked (from brainstorming)

Resolved in dialogue; these are the foundation of the design:

1. **Non-LOT count bucket.** A box of loose parts scanned in by part# + qty is stored as a plain **on-hand count** keyed by `(ItemId, LocationId)` — **not** a LOT. It carries no `LotGenealogy`, no LTT, no genealogy edge into the finished good.
2. **Auto-decrement at Assembly.** When a tray/FG is completed, each **count-tracked** BOM component's on-hand count is reduced by `QtyPer × PieceCount` at the cell. `Workorder.Assembly_CompleteTray` is modified.
3. **Two explicit sections in the popup.** The `InventoryManager` popup gets a **Check in LTT** section (today's scan → move) and a distinct **Receive loose parts** section (part# scan/pick + qty + Add). No auto-detection of LTT-vs-part#.
4. **Per-item tracking mode (blast-radius containment).** A part is *either* LOT-tracked *or* Count-tracked, decided by a new per-`Item` flag. All existing items default to LOT-tracked, so nothing about castings / sub-assemblies / traceable components changes. Only parts an engineer explicitly marks Count-tracked lose genealogy.

### Decisions A–E (confirmed 2026-07-15)

| # | Decision | Resolution |
|---|---|---|
| A | Insufficient count stock at tray completion | **Reject** the completion with a business-rule `Status=0` (mirrors the existing LOT "insufficient component stock" pre-check). No negative balances, no backflush. |
| B | Vendor-lot capture on loose-parts receive | **Optional**, nullable. Hidden/collapsed by default in the popup; stored on the `Receive` ledger row when supplied. |
| C | Soft `ProducedLotId` / `ContainerTrayId` reference on `Consume` ledger rows | **Included.** Not a `LotGenealogy` edge, but records *which FG tray drew down the count* for recall traceability. |
| D | Item Master tracking-mode field | **Included now** — a small addition to the Identity section of Item Master. |
| E | Manual Adjust UI in the popup | **Included** as a minimal per-row adjust affordance (proc + popup) for corrections / box-empty. |

### 2.1 Accepted tradeoff — genealogy

Count-tracked components **do not appear in finished-good `LotGenealogy`**. This is a deliberate, MPP-directed departure from the "Honda requires full genealogy for every part" default, scoped to parts an engineer explicitly marks Count-tracked (generic purchased hardware). The soft reference on `Consume` ledger rows (decision C) preserves a *coarse* audit trail ("40 pins consumed by FG LOT `6NA-000123` on tray 2") without a formal genealogy edge. If a component ever needs true genealogy, it stays LOT-tracked and this feature does not touch it.

---

## 3. Data model (migration `0038_loose_parts_line_inventory.sql`)

`0038` is the next free versioned migration (highest today is `0037`).

### 3.1 Per-item tracking mode

```sql
-- Parts.InventoryTrackingMode — fixed-seed code table (FK-backed enum; no magic ints)
CREATE TABLE Parts.InventoryTrackingMode (
    Id           BIGINT        NOT NULL IDENTITY(1,1) PRIMARY KEY,
    Code         NVARCHAR(20)  NOT NULL,
    Name         NVARCHAR(50)  NOT NULL,
    Description  NVARCHAR(200) NULL,
    CreatedAt    DATETIME2(3)  NOT NULL DEFAULT SYSUTCDATETIME(),
    DeprecatedAt DATETIME2(3)  NULL,
    CONSTRAINT UQ_InventoryTrackingMode_Code UNIQUE (Code)
);
-- seed: (1,'Lot','LOT-tracked'), (2,'Count','Count-tracked (loose parts)')

-- Parts.Item gains the FK; every existing row defaults to Lot (behavior preserved)
ALTER TABLE Parts.Item
    ADD InventoryTrackingModeId BIGINT NOT NULL
        CONSTRAINT DF_Item_InventoryTrackingModeId DEFAULT 1
        CONSTRAINT FK_Item_InventoryTrackingMode
            REFERENCES Parts.InventoryTrackingMode(Id);
CREATE INDEX IX_Item_InventoryTrackingModeId ON Parts.Item (InventoryTrackingModeId);
```

The `NOT NULL DEFAULT 1` backfills existing rows to `Lot` in the same ALTER; no separate backfill statement needed.

### 3.2 Count bucket — materialized balance + append-only ledger (`lots` schema)

Placed in the `lots` schema: it is material-state at a location, sibling to `Lot`/`LotMovement`/`Container`. It follows the project's B5 "materialized qty + append-only events" pattern — a fast, lockable balance for the tray-completion decrement, plus a full ledger for audit.

```sql
-- Lots.LineInventory — materialized on-hand balance, one row per (ItemId, LocationId)
CREATE TABLE Lots.LineInventory (
    Id              BIGINT       NOT NULL IDENTITY(1,1) PRIMARY KEY,
    ItemId          BIGINT       NOT NULL REFERENCES Parts.Item(Id),
    LocationId      BIGINT       NOT NULL REFERENCES Location.Location(Id),
    OnHandQty       INT          NOT NULL DEFAULT 0,
    RowVersion      BIGINT       NOT NULL DEFAULT 0,   -- optimistic lock for manual Adjust
    CreatedAt       DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    UpdatedAt       DATETIME2(3) NULL,
    CreatedByUserId BIGINT       NOT NULL REFERENCES Location.AppUser(Id),
    UpdatedByUserId BIGINT       NULL     REFERENCES Location.AppUser(Id),
    CONSTRAINT CK_LineInventory_OnHand_NonNeg CHECK (OnHandQty >= 0)
);
CREATE UNIQUE INDEX UQ_LineInventory_Item_Location ON Lots.LineInventory (ItemId, LocationId);

-- Lots.LineInventoryTxnType — fixed-seed code table (same shape as the code
--   tables above: Id/Code/Name/Description/CreatedAt/DeprecatedAt + UQ on Code)
--   seed: (1,'Receive'), (2,'Consume'), (3,'Adjust')
CREATE TABLE Lots.LineInventoryTxnType ( /* Id, Code, Name, Description, CreatedAt, DeprecatedAt */ );

-- Lots.LineInventoryTxn — append-only ledger; every balance change writes one row
CREATE TABLE Lots.LineInventoryTxn (
    Id                 BIGINT       NOT NULL IDENTITY(1,1) PRIMARY KEY,
    LineInventoryId    BIGINT       NOT NULL REFERENCES Lots.LineInventory(Id),
    TxnTypeId          BIGINT       NOT NULL REFERENCES Lots.LineInventoryTxnType(Id),
    QtyDelta           INT          NOT NULL,           -- signed: + receive, - consume, ± adjust
    BalanceAfter       INT          NOT NULL,
    Reason             NVARCHAR(200) NULL,
    VendorLotNumber    NVARCHAR(50) NULL,               -- Receive only (decision B)
    ProducedLotId      BIGINT       NULL REFERENCES Lots.Lot(Id),          -- Consume soft ref (C)
    ProducedContainerTrayId BIGINT  NULL REFERENCES Lots.ContainerTray(Id),-- Consume soft ref (C)
    AppUserId          BIGINT       NOT NULL REFERENCES Location.AppUser(Id),
    TerminalLocationId BIGINT       NULL REFERENCES Location.Location(Id),
    CreatedAt          DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME()
);
CREATE INDEX IX_LineInventoryTxn_LineInventoryId ON Lots.LineInventoryTxn (LineInventoryId);
```

`CK_LineInventory_OnHand_NonNeg` is the structural backstop for decision A — a decrement that would go negative is rejected in-proc *before* it hits the constraint, but the constraint guarantees no path can leave a negative balance.

### 3.3 Audit code tables

Add `Audit.LogEntityType` row for `LineInventory` and `Audit.LogEventType` rows for `LineInventoryReceived`, `LineInventoryConsumed`, `LineInventoryAdjusted` (next free ids — confirm high-water at build). Receive/Adjust write `Audit.Audit_LogOperation`; the tray-completion Consume path is audited by the *existing* `Assembly_CompleteTray` `TrayClosed` operation row (the ledger row carries the per-component detail), so no separate Consume audit row per component.

---

## 4. `Workorder.Assembly_CompleteTray` → v2.0

The proc's BOM-consume loop (block B4) currently FIFO-consumes **every** BOM line from LOTs at the cell and writes genealogy edges. v2.0 branches per BOM line on the child item's tracking mode.

### 4.1 Per-line branch (block B4)

For each `Parts.BomLine` of the active BOM, resolve `child.InventoryTrackingModeId`:

- **`Lot` (unchanged):** existing FIFO LOT consumption — `ConsumptionEvent`, `Lot` decrement/close, `LotGenealogy` edge (`RelationshipTypeId=3`), closure ancestors → FG LOT. Verbatim today's logic.
- **`Count` (new, inlined):** decrement `Lots.LineInventory.OnHandQty` for `(ChildItemId, @CellLocationId)` by `CAST(QtyPer * @PieceCount AS INT)` under `UPDLOCK`, bump `RowVersion`/`UpdatedAt`, and insert one `Lots.LineInventoryTxn` `Consume` row (`QtyDelta` negative, `BalanceAfter` = new balance, `ProducedLotId=@FinishedGoodLotId`, `ProducedContainerTrayId=@ContainerTrayId`). **No** `ConsumptionEvent`, **no** `LotGenealogy`, **no** closure rows. There is **no standalone `LineInventory_Consume` proc** — the decrement lives only inline here, because `Assembly_CompleteTray` is captured via INSERT-EXEC and cannot EXEC a status-row sub-proc (same rule that forces the FG-mint / container-open blocks to be inlined). The inline block carries a comment describing the receive/consume ledger invariant it upholds.

### 4.2 Pre-transaction sufficiency check (block 7)

The existing advisory pre-check (LOT `SUM(InventoryAvailable)` per BOM line) gains a parallel branch: for **Count** lines, compare `Lots.LineInventory.OnHandQty` at the cell against `CAST(QtyPer * @PieceCount AS INT)`. If any line — LOT or Count — is short, reject before `BEGIN TRANSACTION` with `Status=0` and message `Insufficient component stock at the line for one or more BOM lines.` (decision A). The in-transaction re-check for Count lines is the `UPDLOCK`'d read + a `RAISERROR` if the balance would go negative (mirrors the LOT "drained mid-consume" `RAISERROR` → CATCH → clean `Status=0`).

### 4.3 Invariants preserved

- Still a single status-row SELECT (`Status, Message, FinishedGoodLotId, ContainerId, ContainerTrayId, ContainerFull`) — FDS-11-011.
- All rejecting validations before `BEGIN TRANSACTION`; the only in-proc `ROLLBACK` site is the CATCH (INSERT-EXEC / Msg 3915 rule).
- `SET XACT_ABORT ON`, `RAISERROR` (not `THROW`) in CATCH.

---

## 5. Procs + read layer (all `Lots` schema, repeatable)

Per FDS-11-011: no OUTPUT params; mutation procs end every exit path with `SELECT @Status AS Status, @Message AS Message[, @NewId AS NewId]`. Audit Description follows the `<SUBJECT> · <CATEGORY> · <ACTION>` convention via `Audit.ufn_MidDot()` / `Audit.ufn_TruncateActivity()`, with resolved-name FK sub-objects in Old/New JSON.

| Proc | Kind | Contract |
|---|---|---|
| `Lots.LineInventory_Receive` | mutation | `@ItemId, @LocationId, @Qty, @VendorLotNumber=NULL, @AppUserId, @TerminalLocationId=NULL`. **Rejects** if the item is not `Count`-tracked (`Status=0`, "This part is LOT-tracked — check in its LTT instead."), if `@Qty <= 0`, or if the item is not eligible at the location. Optional OI-12 `Item.MaxParts` cap check (reject if `OnHand + @Qty > MaxParts`). Upserts the `LineInventory` balance under `UPDLOCK` (insert row if none), inserts a `Receive` ledger row, writes `LineInventoryReceived` audit. Returns `Status, Message, NewId` (`NewId` = `LineInventory.Id`). |
| `Lots.LineInventory_Adjust` | mutation | `@LineInventoryId, @NewOnHandQty, @Reason, @RowVersion, @AppUserId, @TerminalLocationId=NULL`. Optimistic-locked (RowVersion mismatch → the standard "modified by another user" `Status=0`). Sets the absolute balance, writes an `Adjust` ledger row (`QtyDelta` = new − old), `LineInventoryAdjusted` audit. Returns `Status, Message`. |
| `Lots.Inventory_GetOnHandByLocation` | read | `@LocationId`. **Unified** on-hand read — UNIONs LOT rows and Count rows with a `Source` discriminator column. **Supersedes `Lots.Lot_GetLineInventoryByPart`** (only the popup calls it). Columns: `Source` (`'LOT'`\|`'Count'`), `ItemId`, `PartNumber`, `Description`, `LotName` (NULL for Count), `LineInventoryId` (NULL for LOT), `OnHand` (LOT `InventoryAvailable` / Count `OnHandQty`), `RowVersion` (NULL for LOT), `ArrivedAt` (ET-converted: LOT last-arrival / Count `UpdatedAt`). Ordered `PartNumber ASC, Source, ArrivedAt ASC`. ET conversion at the read boundary via `CAST(... AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time' AS DATETIME2(3))` (OI-36). |

`Lots.Lot_GetLineInventoryByPart` is retired in the same migration (its NQ + entity method removed) once the popup repoints to the unified read. (Grep confirmed the popup is its only caller.)

---

## 6. Ignition layer (Core project — file-authored + `scan.ps1`)

### 6.1 Entity script — `BlueRidge.Lots.LineInventory` (new module)

```
script-python/BlueRidge/Lots/LineInventory/code.py
```
Standard entity shape, all access via `BlueRidge.Common.Db.*`, `_currentAppUserId()` for attribution:
- `receive(itemId, locationId, qty, vendorLot=None, appUserId=None, terminalLocationId=None)` → `execMutation("lots/LineInventory_Receive", ...)`
- `adjust(data, appUserId=None, terminalLocationId=None)` → `execMutation("lots/LineInventory_Adjust", ...)`
- `getOnHandByLocation(locationId, _refreshToken=None)` → `execList("lots/Inventory_GetOnHandByLocation", ...)` (ignored refresh-token arg so the popup's `runScript` binding re-reads after a receive/adjust — the refreshToken-as-arg rule).

### 6.2 `BlueRidge.Parts.Item` additions

- `getCountTrackedForDropdown(locationId=None)` → `[{label: PartNumber, value: Id}]` scoped to `Count`-tracked active items (optionally further scoped to items eligible at the line). Backs the "Receive loose parts" picker so a LOT-tracked part cannot be received as a count. Reuses the existing `getByPartNumber` for typed/scanned resolution of a free-text entry.
- Item Identity read/update already round-trips the full row; add `InventoryTrackingModeId` to the Identity save contract (§7) and an options helper `getTrackingModeOptions()`.

### 6.3 Named queries (new, `lots/` + `parts/`)

`lots/LineInventory_Receive` (UpdateQuery), `lots/LineInventory_Adjust` (UpdateQuery), `lots/Inventory_GetOnHandByLocation` (Query), `parts/Item_ListCountTrackedForLocation` (Query), `parts/InventoryTrackingMode_List` (Query). `sqlType` per Designer's enum (Id params = `3`, NVARCHAR = `7`); v2 resource.json shape.

---

## 7. `InventoryManager` popup (rewrite — new-file authorable)

The popup is restructured enough (new sections + a `state`/refresh model + a unified table) that it is authored as a fresh `view.json` and picked up via `scan.ps1` — it is not a surgical Designer-only edit. Root stays `pf-*` plant-floor styling (`canvas`/`pf-panel`/`pf-field`/`pf-btn`, 44px touch targets), `meta.name: "root"`.

**Custom state:** `scanCode` (LTT field), `receiveDraft: {partItemId, qty, vendorLotNumber}` (fully-shaped default per the pre-declared-bound-props / editDraft-shape rules), `refreshToken`, `countOptions` (bound to `Item.getCountTrackedForDropdown`).

**Sections (top→bottom):**
1. **Header** — "Line Inventory" + cell name.
2. **Check in LTT** (`pf-panel`) — the existing scan field; `onBlur` → `checkIn()` → `Lot.moveToValidated` (verbatim today). Single-line rows get explicit `overflow:hidden`.
3. **Receive loose parts** (`pf-panel`) — part# dropdown (`allowCustomOptions`, bound to `countOptions`) + qty text-field (`inputType:"tel"`) + optional collapsed Vendor LOT field (decision B) + **Add** button → `receiveLoose()` → `LineInventory.receive`; on success clears the draft + bumps `refreshToken`.
4. **On hand** (`ia.display.table`, full column schema per the table-column rule) — bound via `runScript("BlueRidge.Lots.LineInventory.getOnHandByLocation", 0, {locationId}, {refreshToken})`. Columns: **Type** (LOT/Count), **Part**, **LOT** (blank for counts), **On hand**, **Updated (ET)**. Count rows expose a minimal **Adjust** action (decision E) — opens a small qty popup → `LineInventory.adjust` (RowVersion-guarded), bumps `refreshToken`.

Both check-in paths bump the shared `refreshToken` and send the existing `replyMessage` (`inventoryChanged`) page message so the embedding assembly/machining view refreshes.

**Embedding unchanged** — `AssemblyIn/NonSerialized/Serialized` + `MachiningIn/MachiningOutSplit` already open `mpp-inventory` with `params={locationId: session.custom.cell.locationId}`; the tooltip ("Check component / pass-through inventory in to this line") already fits.

---

## 8. Config Tool — Item Master Identity tab (decision D)

Add an **Inventory Tracking** dropdown (`Lot` / `Count`) to the Identity section, bound into `editDraft.identity.inventoryTrackingModeId`, options from `Item.getTrackingModeOptions()`. Follows the per-section-ownership + atomic-state-write conventions (single `view.custom.state = {...}` write on load; `sectionDirtyChanged` broadcast). The Item Identity update proc (`Parts.Item_Update`) takes a new `@InventoryTrackingModeId` param; audit Old/New JSON resolves it to `{Id, Code, Name}`.

**Guard:** changing a part from `Count` → `Lot` (or vice-versa) while it has a non-zero `LineInventory` balance or open `Received` LOTs is a state hazard. v1 rule: the Item_Update proc **rejects** a tracking-mode change while the part has a non-zero on-hand count at any location (`Status=0`, clear message). Broadened reconciliation (migrating existing on-hand between representations) is out of scope.

---

## 9. Seed / demo

`sql/scratch/seed_demo.sql` currently receives pins/studs/dowels as `Received` LOTs consumed by assembly. Update the demo so **one** purchased component (the 21001 pin) is marked `Count`-tracked and seeded with a `Lots.LineInventory` balance at its assembly line, so the demo exercises a **mixed BOM** (LOT sub-assembly + Count pin) through `Assembly_CompleteTray`. The other purchased parts stay `Received` LOTs to keep both paths demonstrated. Internal code-table seeds (`InventoryTrackingMode`, `LineInventoryTxnType`) bake into migration `0038`, not the seeding registry.

---

## 10. Testing (TDD)

**New suite `sql/tests/0038_PlantFloor_LineInventory/`:**
- `LineInventory_Receive`: happy path (new balance row + Receive ledger + audit); reject LOT-tracked part; reject qty ≤ 0; reject not-eligible-at-location; MaxParts cap; second receive accumulates.
- `LineInventory_Adjust`: absolute set + ledger row; RowVersion mismatch rejects; non-negative constraint.
- `Inventory_GetOnHandByLocation`: unified UNION shape (LOT + Count rows, `Source` column, ET `ArrivedAt`); empty rowset when nothing on hand.

**Extend `sql/tests/0028_PlantFloor_Assembly/` (`092_Assembly_CompleteTray`):**
- Mixed BOM (one `Lot` child, one `Count` child): FG mint consumes the LOT via FIFO+genealogy **and** decrements the count + writes a `Consume` ledger row with `ProducedLotId`/`ProducedContainerTrayId`; **no** `LotGenealogy` edge for the count child.
- Insufficient count stock → `Status=0`, no partial mutation (transaction rolled back).
- Count child with exactly-enough stock (boundary).

Re-run the **full suite** after the proc-shape + precondition changes (INSERT-EXEC fixed-shape captures + the Assembly test fixtures) per the "re-run suite after proc shape / precondition change" rule; grep both `ERROR running` and `FAIL:`.

---

## 11. Change inventory

**SQL — migration `0038` (versioned):**
- `Parts.InventoryTrackingMode` table + seed; `Parts.Item.InventoryTrackingModeId` FK + index + default backfill.
- `Lots.LineInventory`, `Lots.LineInventoryTxnType` (+seed), `Lots.LineInventoryTxn`.
- `Audit.LogEntityType` (+1) / `LogEventType` (+3) seeds.

**SQL — repeatable procs:**
- New: `Lots.LineInventory_Receive`, `Lots.LineInventory_Adjust`, `Lots.Inventory_GetOnHandByLocation`, `Parts.Item_ListCountTrackedForLocation`, `Parts.InventoryTrackingMode_List`.
- Modified: `Workorder.Assembly_CompleteTray` → **v2.0** (per-line LOT/Count branch + count sufficiency pre-check); `Parts.Item_Update` (+`@InventoryTrackingModeId`, tracking-mode change guard); `Parts.Item_Get`/`_List` (+`InventoryTrackingModeId`/Code in SELECT — widen any INSERT-EXEC capture temp tables).
- Retired: `Lots.Lot_GetLineInventoryByPart`.

**Ignition (Core + MPP + MPP_Config, file-authored + scanned):**
- New entity module `BlueRidge.Lots.LineInventory`; `Parts.Item` additions.
- 5 new NQs (§6.3); retire `lots/Lot_GetLineInventoryByPart` NQ + `Lot.getLineInventoryByPart`.
- `Components/PlantFloor/InventoryManager` view rewrite (§7).
- Item Master Identity tab + Item entity tracking-mode field (§8).

**Docs:** Data Model (new tables + `Item.InventoryTrackingModeId`, changelog row); FDS (a short subsection under the Assembly/Inventory section describing the two inventory representations + the count-decrement rule + the genealogy tradeoff of §2.1); OIR (close/track any related open item). Regenerate `.docx` per the doc-generation convention.

---

## 12. Open items / risks

1. **Genealogy tradeoff (§2.1)** — accepted by MPP for explicitly Count-tracked parts. Surface in the FDS so it is a documented decision, not a silent gap.
2. **Mode-change reconciliation (§8)** — v1 rejects a tracking-mode flip while on-hand is non-zero. A migration path (convert existing `Received` LOTs ↔ `LineInventory` counts) is deferred; call it out to MPP if they need to re-classify parts that already have stock.
3. **Cross-location counts** — `LineInventory` is keyed by exact `(ItemId, LocationId)` (the cell). `Assembly_CompleteTray` decrements at `@CellLocationId`. Confirm loose parts are always received at the *same* location granularity the tray completes at (the cell), not a parent zone. If receipts land at a zone and consumption at a child cell, a small ancestor-resolution is needed (out of scope until confirmed).
4. **`MaxParts` cap on receive** — included as an optional check; confirm MPP wants the OI-12 lineside cap enforced on loose-parts receipts as it is on LOT moves.
5. **Audit id high-water** — confirm the next free `LogEntityType`/`LogEventType` ids at build (the terminal-mint + quality-capture work consumed several).

---

## 13. Build order (feeds writing-plans)

1. Migration `0038` (tables + seeds + Item ALTER) — TDD scaffolding first.
2. `Lots.LineInventory_Receive` / `_Adjust` / `Inventory_GetOnHandByLocation` + suite `0038`.
3. `Assembly_CompleteTray` v2.0 + `0028` mixed-BOM tests; full-suite re-run.
4. `Parts.Item_Update`/`_Get`/`_List` tracking-mode plumbing.
5. Core NQs + entity modules; retire the superseded read.
6. `InventoryManager` popup rewrite; scan + Designer smoke.
7. Item Master Identity tracking-mode field; scan + Designer smoke.
8. `seed_demo` mixed-BOM update; docs (Data Model / FDS / OIR) + `.docx`.
