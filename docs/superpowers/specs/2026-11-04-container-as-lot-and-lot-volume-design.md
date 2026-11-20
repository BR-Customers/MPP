# Container-as-LOT and LOT volume -- design

> **Status: APPROVED 2026-11-04 (Jacques) and BUILT on `claude/container-as-lot-3afdfd`. 2026-11-16: brought onto `main` as branch `sp/container-as-lot` (migration renumbered `0119_container_as_lot`; prod's `0118` is the 2026-11-10 incident fix). The volume items were split out (Jacques, 2026-11-16): the `Lots.Lot` clustered index (8.1), LOT search v2 (8.2) and the perf-only rewrites of `Lot_List`, components-at-cell, line inventory by part and the OEE refresh tick each land as their own `sp/` PR. The WIP queue and trim storage queue keep main's v3.3 / v2.1, and `IX_Lot_LocationStatus` / `IX_Lot_ItemStatus` are dropped in favour of `0118`'s `IX_Lot_NotClosed_*`. NOT deployed, no Ignition view edited.**
> Branch `claude/container-as-lot-3afdfd` (from `jacques/working` @ `b168a6e6`).
> Evidence and first blast-radius: `notes/2026-11-04_lot-volume-and-container-as-lot.md`.
> Full reader inventory (2026-11-04 code sweep): section 11.

---

## 1. Why

Seeding a month of OEE history showed what one finished-good (FG) LOT per **tray** costs at real line rates:
- **About 3 million FG LOTs a year.** The schema was sized for about 150K a year (OI-35).
- **Every tray LOT is a full LOT.** It gets an MESL number, a status-history row, a movement, a closure self-row, and about 12 consumption rows, genealogy edges and closure rows each.
- **The numbering runs out.** The MESL range (3,000,000 - 9,999,999) would be exhausted in 2-3 years, and the identifier proc refuses past the end.

The legacy MES has no tray entity. Its produced unit is the `Container`, at about 127K a year, and FRS 3.10.11 already reads that way: "Produced LOT or Container ID", plus "Produced Tray ID (when appropriate)".

**Decision (Jacques, 2026-11-04): one FG LOT per container.** The tray stays as a record of what passed the camera. Prod's existing 6MA-CH tray LOTs stay as history, so **every reader handles both shapes**.

Prod records only one M&A line (MA2-6MACH) today, so this is the cheapest moment to change the schema.

## 2. Goals, non-goals, anti-goals

**Goals**
- **About 30x fewer FG rows per container.** A container has one LOT, so one MESL number, one status history, one closure self-row, and genealogy edges per (source LOT, container LOT) pair.
- **No lost trace.** Every piece still traces to its source LOTs. Tray-level detail ("which tray drew from which source LOT") stays in `Workorder.ConsumptionEvent`.
- **OEE good is unchanged in meaning.** Each shift is credited with the trays that passed the camera in that shift, including when a container spans a shift change.
- **Safety gates behave the same:**
  - a held or CRT container cannot ship;
  - a CRT container is not posted to AIM;
  - super-lot release, deviation and repack all work.
- **Smaller volume items:**
  - give `Lots.Lot` a clustered index;
  - make `Lot_Search` / `Lot_SearchAdvanced` scale.
- **Year-scale benchmark** on `MPP_MES_Bench`, before and after.

**Non-goals**
- **Old data stays as it is.** Existing tray-LOT containers are not migrated or rewritten.
- **The operator flow does not change**, nor does the screen layout beyond what a reader needs.
- **No serialized-line (5G0 MIP) changes.** `SerializedMipWatcher` mints serials against the front LOT of the assembly queue, not through the tray mint, so it is out of scope.
- **No change to Die Cast, Trim or Machining LOT grain.**

**Anti-goals: these would be failures even if the code "works"**
- **A safety gate that passes silently because a reader still looks only at tray LOTs.** This is the biggest risk, because the failure gives a wrong answer, not an error. See the hot list in section 11.
- **OEE good double-counting or dropping pieces** across the old/new boundary, or across a shift change.
- **Anything touching the main checkout or `MPP_MES_Dev`** while the 2026-11-05 prod release is pending.

## 3. Shop-floor facts this design rests on (Jacques, 2026-11-04)

- **The 6MA-CH Assembly Out area.**
  - Two operators work there, each fed by a conveyor.
  - They load parts into trays and stack the trays.
  - Whenever they choose, they feed the trays one at a time into the shared camera station two feet away.
  - The camera pushes an accepted tray left, onto the skid (the container), and a denied tray right.
- **A denied tray is reworked and fed back in.** It must consume nothing. *Verified:* `TrayInspectionWatcher` books nothing on a camera FAIL; only a PASS reaches `Assembly_CompleteTray`.
- **A container opens on its own.** If no box is open when a tray scans, `Assembly_CompleteTray` opens one (it already does).
- **The final tray completes the skid.** When it passes the camera, the skid is full: labels print and the AIM shipper ID is consumed.

## 4. Decisions

| # | Decision | Who |
|---|---|---|
| D1 | **Mint on the first accepted tray.** The first tray into an empty container mints the container's LOT in the same transaction that opens the container. Each later tray adds its pieces to that LOT. `Container_Complete` closes the LOT along with the container. | Jacques |
| D2 | **`Lots.ContainerTray` stays, one row per accepted tray.** New trays carry no LOT of their own (`FinishedGoodLotId` NULL). It remains the FRS "Produced Tray ID". | Jacques (playback) |
| D3 | **`ConsumptionEvent` stays per tray per source-LOT draw.** `ProducedLotId` is the container LOT; `TrayId` and `ProducedContainerId` are carried as today. | Jacques (playback) |
| D4 | **One genealogy edge per (source LOT, container LOT) pair.** The first draw inserts the edge; later draws from the same source add to its `PieceCount`. Closure ancestors are inserted only when new, as today. This is a deliberate exception to append-only, for `Lots.LotGenealogy` only; the per-draw history lives in `ConsumptionEvent`. | Jacques |
| D5 | **OEE good is credited per tray.** Each tray is stamped with the shift (and terminal) it passed the camera in. M&A good per shift = the pieces in that shift's trays. | Jacques (playback) |
| D6 | **Rework moves pieces LOT to LOT.** Moving pieces between containers (`ContainerRework_MovePieces`) takes them off the giving container's LOT, adds them to the receiving container's LOT, and links the two with one edge (D4 rule). No new LOT is minted. | Jacques |
| D7 | **Holds and CRT apply to the whole container.** They sit on the container's LOT. Tagging one tray, or holding four trays out of 24, is no longer possible. Shipping behaviour is unchanged: one tagged or held tray already stops the whole container. | Jacques |
| D8 | **Readers handle both shapes** through two helper functions (section 6). Old tray-LOT containers stay exactly as they are. | Jacques |
| D9 | **Super-lot time rules read the trays, not the LOT's birth.** A container belongs to a time-bounded super-lot (auto-join "keep adding new production", and selection by time) when **any of its trays passed the camera inside the window**. A container LOT is created at its first tray, so `Lot.CreatedAt` would miss a window that opens or closes mid-skid. This over-includes rather than misses, and matches the per-tray CRT re-resolve (7.1 step 4). | Jacques (builder check) |
| D10 | **A held skid keeps filling.** If Quality puts a hard hold on a still-filling container's LOT, the next accepted tray still adds its pieces to that held LOT, and they are released or dispositioned together with it. In practice Quality would use CRT, or pause the line and CRT, for a filling skid, rather than a hard hold. | Jacques (builder check) |
| D11 | **Each tray stamps a fixed minted count.** `ContainerTray.MintedPieceCount` is written once, at tray close, and OEE good reads it, never `PartsClosedCount`, which repack scrap and moves lower afterwards. This mirrors `Lot.MintedPieceCount` (OEE D21), so later rework never moves a closed shift's good. | My call (builder check) |
| D12 | **A rework move's trace is container-grained.** A piece moved by repack traces to the donor *container's* LOT, and so to all of that container's source LOTs, not just the donor tray's. This follows from D7: it over-includes recall scope and never under-includes it. The move's `ConsumptionEvent` records the receiving tray (`TrayId`); the donor tray is not recorded. | My call (builder check) |

## 5. Data model -- migration `0118_container_as_lot`

(The number assumes nothing else lands `0118` first. Renumber at merge if it does.)

```
Lots.Container
  + LotId  BIGINT NULL  FK -> Lots.Lot(Id)
    UNIQUE filtered index UX_Container_LotId (LotId) WHERE LotId IS NOT NULL
    NULL = an old (tray-LOT) container, or a container opened before its first tray.

Lots.ContainerTray
  + ShiftId             BIGINT NULL  FK -> Oee.Shift(Id)          (D5; stamped by Assembly_CompleteTray only)
  + ClosedAtTerminalId  BIGINT NULL  FK -> Location.Location(Id)  (the station; feeds Oee.ufn_AreaFamily)
  + MintedPieceCount    INT    NULL  (D11; = PartsClosedCount at tray close, never updated; NULL on rework-move trays)
    filtered index IX_ContainerTray_ShiftId (ShiftId) INCLUDE (MintedPieceCount, ClosedAtTerminalId, ContainerId)
      WHERE ShiftId IS NOT NULL
    index IX_ContainerTray_ClosedAt (ClosedAt) INCLUDE (ContainerId, ClosedAtTerminalId)   -- D9 window reads
  FinishedGoodLotId stays (old rows); NULL on every new tray. The 0034 filtered UNIQUE index stays.

Lots.Lot  -- volume item, section 8
  clustered index CIX_Lot_CreatedAt (CreatedAt, Id)  -- converts the heap
```

**On the container LOT's own columns:**
- **`ShiftId` / `MintedPieceCount` stay NULL.** OEE reads the trays (D5), and NULL keeps the old-shape branch of `Oee.ufn_ShiftGood` from counting the container LOT.
- **`MaxPieceCount` = `Item.MaxLotSize`**, as today. For 6MA-CH that value is already the container size (96 = 24 trays x 4).
- **`CreatedAtTerminalId`** is the station of the first tray.

**Doc fix in the same branch:** the Data Model's `Container` / `ContainerTray` sections are stale against the live schema. They list `ContainerName`, `LotId` "Source LOT", `TrayNumber` and `PieceCount`, but the database has `OpenedAt`, `TrayPosition`, `PartsClosedCount` and so on. Rewrite both from the live schema, plus the two new columns.

## 6. The two helpers (both shapes)

```
Lots.ufn_ContainerLots(@ContainerId)  -> (LotId, SortKey, Shape)
    old: ContainerTray.FinishedGoodLotId, SortKey = TrayPosition, Shape = 'Tray'
    new: Container.LotId,                  SortKey = 2147483647,   Shape = 'Container'
    (UNION ALL; a mixed container -- see section 9 -- returns both)

Lots.ufn_LotContainers(@LotId)        -> (ContainerId, ContainerTrayId NULL)
    old: tray whose FinishedGoodLotId = @LotId
    new: container whose LotId = @LotId (ContainerTrayId NULL)
```

- **Both are inline TVFs**, so the optimizer can see through them.
- **Readers that took "TOP 1 tray LOT"** (AIM `LotNumber`, label `MfgLotNumber`, recent boxes) now take `TOP 1 ... ORDER BY SortKey`. A new container gives its own LOT; an old one gives its first tray's LOT, which is unchanged behaviour.
- **Pieces in a container are always `SUM(ContainerTray.PartsClosedCount)`**, never a sum over LOTs. That is right in both shapes and after rework.

## 7. Behaviour, proc by proc

### 7.1 `Workorder.Assembly_CompleteTray` (v2.0)

**Unchanged:**
- the pre-transaction checks: eligibility, config, piece count, BOM or repack stock, the full-box guard;
- container resolution (own box / claim unowned / open new, 0078).

**Inside the transaction:**
1. **Resolve the container first (today's B2), then the LOT.**
   - If `Container.LotId` is NULL, mint the LOT exactly as today's B1 (inline `IdentifierSequence`, status history, closure self-row, movement, `LotCreated` audit). Leave `ShiftId` / `MintedPieceCount` NULL and set `Container.LotId`.
   - Otherwise lock the container's LOT (`UPDLOCK`) and add `@PieceCount` to `PieceCount` and `InventoryAvailable` (B5). **This happens whatever the LOT's status:**
     - **Good** is the normal case.
     - **Hold:** D10, the held skid keeps filling.
     - **Closed:** a reworked container being topped up (7.4).

     The container's own status (Open) is what gates the tray. A container-level hold already takes the container out of Open, so the box lookup never finds it.
2. **Insert the tray** with:
   - `FinishedGoodLotId` NULL;
   - `ShiftId` = `Oee.ufn_ShiftIdForInstant(@CellLocationId, now)`, resolved before the transaction, as v1.6 does;
   - `ClosedAtTerminalId` = `@TerminalLocationId`;
   - `MintedPieceCount` = `@PieceCount` (D11).
3. **Consume first-in-first-out**, as today:
   - `ConsumptionEvent` per draw (`ProducedLotId` = container LOT, `TrayId` = this tray);
   - the genealogy edge per D4 (`UPDATE ... SET PieceCount += @Take` if the pair exists, else `INSERT`);
   - closure ancestors only when new (today's `NOT EXISTS` guard is unchanged).
4. **Re-resolve CRT on every tray, raise only (0 -> 1).**
   - Call `Lots.ufn_CrtForMint` with the part, the terminal, and the LOTs this tray consumed.
   - The open-super-lot arm is evaluated per tray, so a window opened mid-container still tags the container from the next tray on, as it tagged the next tray LOT before.
   - Membership recording is unchanged (`ControlledRun_SyncInternal` picks up a newly tagged LOT).
5. **Result set:** `FinishedGoodLotId` keeps its name, and now returns the container's LOT. The callers only display it or log it (see 7.6).

**Audit:**
- `LotCreated` on mint;
- the per-tray `TrayClosed` audit stays, naming the container LOT;
- no per-tray LOT audit.

### 7.2 `Lots.Container_Complete`

- **The close loop runs over `ufn_ContainerLots`**, so it closes the container LOT, or the old tray LOTs.
- **A held container LOT is not closed here** (the existing Good-only rule; D10). `Hold_Release` closes it later, once its container is Complete or Shipped, as today.
- **The AIM `LotNumber` is `TOP 1 LotName ORDER BY SortKey`.**
- Nothing else changes.

### 7.3 Gates and trace (mechanical swap to the helpers)

- **Gates:** `Container_Ship` (held-LOT + CRT), `AimShipperIdPool_ListUnposted`, `Container_ListPendingValidation`, `Container_ValidateCrt`.
- **Label and trace:** `Container_GetLabelData`, `GetTraceDetail`, `ListShipped`, `GlobalTrace_Resolve` (container + shipper branches).
- **Holds:** `Hold_ListAssociatedContainers`, `Hold_Release`.
- **Other readers:** `Lot_GetShippedContainers` (Quantity = the tray sum), `ScaleStation_GetRecentBoxes`, `ContainerRework_Void` (CRT clear), and the Lot Detail report query (`tools/reports/lot_detail/queries.py`; check the report `data.bin` too).
- **Every `ControlledRun*` proc and function** (resolve/fold, member state, memberships, apply, release, sync, log, preview):
  - container pieces = the tray sum;
  - "any CRT" = over `ufn_ContainerLots`.
- **D9 time rule.** This is a real change, not a helper swap.
  - **For a container LOT, "produced in the window" = `EXISTS` a tray of that container with `ClosedAt` in `[OpenedAt, EndedAt)`.**
    - The location filter applies to that tray's `ClosedAtTerminalId`.
    - It is used by `ControlledRun_SyncInternal` (auto-join), the time arm of `ufn_ControlledRunResolveMembers` / `PreviewSelection` (today `COALESCE(c.OpenedAt, l.CreatedAt)`), and the window-conflict check.
  - **Old tray LOTs keep `l.CreatedAt`**, which is the same instant for them.

**`Tools.ufn_ContainerOriginDieRankCode`:**
- **Old container:** first tray's LOT, unchanged.
- **New container:** take the container's first tray (MIN `TrayPosition`), its `ConsumptionEvent` source LOTs, and the deepest closure ancestor with a `ToolId`. That keeps today's "representative = first tray" rule. Walking the whole container LOT's closure would pick an arbitrary die among 24 trays' worth of castings. *(My call.)*

### 7.4 Repack (super-lot piece 4)

- **`ContainerRework_Scrap`** decrements the container LOT and the tray's `PartsClosedCount`. `RejectEvent.LotId` = the container LOT (old shape: the tray LOT, as today).
- **`ContainerRework_MovePieces`** (D6):
  - It decrements the donor's LOT and the donor tray, increments the receiving container's LOT, and inserts a tray row in the receiver (`ShiftId` NULL, so it is not new production).
  - It writes `ConsumptionEvent` (`TrayId` = the new tray) and the D4 edge from donor LOT to receiving LOT.
  - If the receiving container has no LOT yet (an emptied container being refilled is the only case), mint one.
  - An **old-shape donor** still decrements its tray LOT. An **old-shape receiver** gets a container LOT on its first move, which makes it a mixed container (section 9).
- **`ContainerRework_ListTrays`:**
  - the per-tray LOT column shows the container LOT for new trays;
  - "moved from" comes from `ConsumptionEvent` by `TrayId` (it already does).
- **Top-up at a line (repack D8, my call):** the normal tray completion appends to the reworked container's existing LOT. That LOT stays **Closed** throughout the rework, the same way repack D5 already takes pieces off Closed tray LOTs; `Assembly_CompleteTray` appends regardless of the LOT's status when the container is Open. `Container_Complete` then claims a new serial, as today.

### 7.5 OEE

- **`Oee.ufn_ShiftGood`:** the M&A branch becomes a UNION of two parts:
  - **old:** FG LOTs with `ShiftId` = the shift (they all have tray-LOT shape);
  - **new:** `ContainerTray` rows with `ShiftId` = the shift, `MintedPieceCount` as good (D11), `ItemId` from the container, and area via `ClosedAtTerminalId`.

  No row is in both (container LOTs carry no `ShiftId`, and old trays carry no `ShiftId`).
- **`Oee.ufn_ShiftInputFingerprint`** adds the same tray set.
- **`Lots.Lot_BackfillMintStamp`** skips container LOTs (`Container.LotId` = the LOT).
- **`Workorder.FinishedGoods_GetProducedSummary`:**
  - pieces come from the trays, by `ContainerTray.ClosedAt` in the window;
  - "LOTs" becomes "containers" for new data, and old data counts trays as today.

### 7.6 LOT-to-tray readers

- **`Lot_GetLinkedContainer`, plus the LotDetail view's custom `ContainerTrayId`:**
  - a container LOT returns its container with tray count and NULL tray fields;
  - the view shows "Container #n (k trays)" instead of a tray position.
- **`ScaleStation_GetPressLog` + `ScaleEPrintWatcher`:**
  - the watcher logs `lotId` = the container LOT and puts `ContainerTrayId` in the interface log payload;
  - the press log resolves the tray from that payload, falling back to the old `FinishedGoodLotId` join.
- **Ignition callers** of the tray result (`Workorder/Assembly/code.py`, the AssemblyNonSerialized view, the PLC watchers) only display or log the id. Check each one; no contract change beyond the meaning of the id.
- **Edits to existing views go through Designer** (CLAUDE.md file-edit boundary).

## 8. Volume items

### 8.1 `Lots.Lot` clustered index

- **Add clustered `(CreatedAt, Id)` on PRIMARY. Do not partition it.**
  - `Lots.Lot` is mutable (piece counts, status) and is never aged out, because of the 20-year trace.
  - Partitioning would force every FK target (`Lot.Id`) into a non-aligned unique index. That blocks partition `TRUNCATE` and gains nothing for a table we never truncate (memory: partition-aligned PK).
- **`PK_Lot` stays NONCLUSTERED on `Id`.** *(My call.)*
- **On prod** (one line, small table) the rebuild is seconds. Measure it on Bench at year scale anyway.

### 8.2 `Lot_Search` / `Lot_SearchAdvanced`

**Today:** both do `LIKE '%q%'` over `LotName`, `VendorLotNumber` and `PartNumber` (Advanced adds `Description`) on every LOT, plus a `COUNT(*) OVER()`, plus a `TOP 1 ProductionEvent` per row.

**Proposed:**
- **Route the query by shape:**
  - an exact `LotName` match first (unique index seek);
  - a prefix match (`LotName LIKE q + '%'`, which is a seek);
  - part numbers resolved through `Parts.Item` first (`PartNumber LIKE '%q%'` on a small table), then `Lot.ItemId IN (...)` over the window;
  - the vendor LOT number searched only inside the window.
- **Default window: the last 90 days by `CreatedAt`** (uses 8.1). `@IncludeOlder BIT = 0` is the last parameter, so existing named queries keep their behaviour shape. An exact LOT-name hit is returned **regardless** of the window.
- **Replace `COUNT(*) OVER()`** with `TotalCount` = `LimitRows + 1` probing: fetch `TOP (@LimitRows + 1)` and return `HasMore`. Keep the column name `TotalCount` as "rows returned" plus a `HasMore` bit, so the pager can say "100+".
- **`OUTER APPLY` last operation stays.** It runs only for the returned rows once the filter is a seek.

**Screens:** the LOT search screens gain a "Search older" toggle. The 90-day default is *my call*; Jacques may prefer another.

## 9. Transition (prod has live tray-LOT data)

- **No data migration.** Old containers keep `LotId` NULL and their tray LOTs.
- **A container that is open when the release lands becomes mixed.** It has old trays with their own LOTs, and new trays appended to a container LOT minted on the first post-release tray.
  - Every reader handles this through `ufn_ContainerLots` (it returns both).
  - OEE does not double count (section 7.5).
  - The AIM LOT number stays the first tray's LOT.

  *(My call: simpler and safer than forcing a different mint path for in-flight boxes.)*
- **Pre-flight gate (release):** WARN listing the open FG containers with tray LOTs, so the window can be timed between containers if Jacques prefers.

## 10. Benchmark -- `MPP_MES_Bench`

**Setup:**
- **Restored 2026-11-04** from a COPY_ONLY backup of `MPP_MES_Dev`: 119,192 LOTs, `Lot` sequence at 3,000,180.
- **Never** run against Dev. The seed is a redirected copy of `sql/scratch/seed_oee_history.sql`, with its `USE` changed to `MPP_MES_Bench` and kept out of the repo.

**Year-scale seed, two runs:**

| Run | Rates (Jacques) |
|---|---|
| A, realistic | Cam holders: one 96-pc container (24 trays x 4) every 30-40 min per line (prod audit: about 41 trays an hour). Oil pans: 6-8 x 60-pc containers per shift. Every other M&A line: one tray every 3 min. |
| B, stress | One tray every 3 min on every M&A line. |

Each run is seeded twice:
- **before:** today's shape, one tray LOT per tray, through a direct-insert generator that mirrors `Assembly_CompleteTray`'s rows;
- **after:** the container shape.

**Measured:**
- row counts and reserved MB per table (`Lot`, `LotStatusHistory`, `LotMovement`, `LotGenealogy`, `LotGenealogyClosure`, `ConsumptionEvent`, `ContainerTray`, `LotEventLog`);
- MESL numbers consumed per year, and years left in the range;
- timings via `sql/scratch/Measure-OeeDevVolume.ps1 -Database MPP_MES_Bench` (OEE reads, ShiftSummary refresh), plus `Lot_Search` / `_SearchAdvanced` (exact, prefix, part, vendor, empty) old vs new, `GlobalTrace_Resolve` for a container, `Hold_ListAssociatedContainers`, and the latency of one `Assembly_CompleteTray` call at year-end volume (in a rolled-back transaction).

The results go into this spec, section 12, and the status page.

## 11. Reader inventory (code sweep 2026-11-04)

The full list with classifications is in the shared session note `2026-11-04_container-as-lot-reader-inventory.md`, summarised in section 7. **77 test files** reference the changed objects. Each changed reader gets a test for **each shape** (old tray-LOT container, new container LOT) and, for the gates, a mixed container.

**Silent-breakage hot list.** These must have tests that fail first:
1. `Container_Ship` held / CRT gates
2. `AimShipperIdPool_ListUnposted` CRT exclusion
3. `Container_ListPendingValidation`
4. label die rank and `MfgLotNumber`
5. the `Container_Complete` close loop and `Hold_Release` close
6. super-lot container pieces / CRT
7. `GlobalTrace` container and shipper
8. OEE good and the fingerprint

## 12. Benchmark results (2026-11-04, year-scale on restored Dev copies)

**Method.**
- **Databases:** `MPP_MES_Bench` / `_After` (Run A, Jacques's rates) and `MPP_MES_BenchB` / `_After` (Run B, one tray every 3 min on every line), all restored from one COPY_ONLY backup of Dev.
- **Seed:** a year of M&A by direct insert in each shape (`sql/scratch/bench_lot_volume_seed.sql`), with 500-piece source LOTs and a die-cast parent per source, so closure depth is real.
- **Calendar:** schedules 1-3, Mon-Fri.
- **Statistics:** refreshed after the seed (`sp_updatestats`). The first measurement without that inflated several timings.
- **Timings:** warm medians from `Measure-LotVolume.ps1` / `Measure-OeeDevVolume.ps1`, through SqlClient.
- **Code:** "Before" = `b168a6e6` code; "after" = this branch.
- **Reliability:** reads are the more reliable signal, because runs overlapped other work at times.

**Volume (Run A / Run B):**

| | A before | A after | B before | B after |
|---|---|---|---|---|
| Trays a year | 3.67M | 3.67M | 3.53M | 3.53M |
| Finished-good LOTs a year (MESL numbers) | 3.67M | 0.80M | 3.53M | 1.11M |
| Years left in 3,000,000-9,999,999 at that rate | 0.9 | 7.8 | 1.0 | 5.3 |
| Lots.Lot rows / MB | 5.52M / 2,324 | 2.65M / 1,620 | 5.88M / 2,475 | 3.46M / 2,158 |
| LotStatusHistory rows | 7.45M | 1.71M | 7.18M | 2.35M |
| LotGenealogy rows | 20.2M | 4.34M | 16.3M | 6.70M |
| LotGenealogyClosure rows / MB | 45.1M / 3,130 | 10.5M / 757 | 37.3M / 2,604 | 15.7M / 1,148 |
| LotEventLog rows | 3.67M | 0.80M | 3.53M | 1.11M |
| ConsumptionEvent rows (per tray draw, both shapes) | 19.4M | 19.4M | 15.2M | 15.2M |

The seed's "other" lines take their container size from their own `ContainerConfig`. Several are one tray per container, so Run B's container LOTs stay above the legacy ~127K a year. Cam holders and oil pans are the real gain.

**Reads (warm ms, Run A; Run B is the same shape):**

| Read | before | after |
|---|---|---|
| `Lot_Search` exact / prefix / part / empty | 8,184 / 7,863 / 8,048 / 26,352 | 1 / 1 / 28 / 9 |
| `Lot_Search` no match (vendor-style) | 7,042 | 1,416 |
| `Lot_SearchAdvanced` part / by shift | 11,748 / 10,930 | 27 / 16 |
| `Assembly_CompleteTray` 1st / 2nd tray (rolled back) | 109 / 95 | 18 / 14 |
| WIP queue Assembly OUT / Die Cast | 608 / 659 | 1 / 1 |
| `Lot_List` at a line | 1,306 | ~95 |
| `Oee.ufn_ShiftGood` busy shift | 32 | 70 |
| `Lots.Lot_GetComponentsAtCell` (line) | 6,716 (13.6M reads) | 18 (2.5K reads) |
| `Lots.Lot_GetTrimStorageQueueForLine` | 5,699 (8.2M reads) | 6 (4.7K reads) |
| `Lots.Container_ListShipped` 30 days (68K rows) | 14,797 (24M reads) | ~4,600 |
| GlobalTrace / Hold associations / linked container / trace detail | 1 / 0 / 0 / 0 | 1 / 1 / 1 / 0 |

`ufn_ShiftGood` rose from 32 to 70 ms: it now reads trays, not one LOT per tray, and both are fine.

**What changed, beyond the container-as-LOT design (all in `0118` or repeatables):**
- **The clustered `(CreatedAt, Id)` on `Lots.Lot` needs seekable companions.** Without them, an ordered `TOP 1` (the FIFO stock pick) walked the clustered index from the oldest LOT. That cost 105K reads per tray, a regression this branch introduced and then fixed.
  - `IX_Lot_LocationItemCreated` (filtered `InventoryAvailable > 0`) serves the stock pick.
  - `IX_Lot_LocationStatus` and `IX_Lot_ItemStatus` replace the location-only and item-only indexes for "open LOTs at a location / of a part".
- **Other indexes:**
  - `IX_Container_CompletedAt`;
  - `IX_ShippingLabel_Container` widened to (ContainerId, IsVoid, CreatedAt, Id);
  - `IX_ContainerTray_Container` covering the per-container tray sum.
- **Rewritten reads** (same rows):
  - the WIP queue, components at cell and trim storage queue: eligible set first, then the last movement per LOT;
  - `Lot_List`: page ids first, count separately;
  - `Container_ListShipped`: set-based aggregates;
  - LOT search v2.

**Found, not fixed (still slow at year scale):**
- `Lot_Search` with no exact hit scans the 90-day window: about 1.4-2.2 s for a miss.
- `Container_ListShipped` over 30 days of 68K containers: about 4.6 s, dominated by the per-container tray reads. At legacy volume a month is about 10K containers.
- See `PROJECT_STATUS.md` for the slow-query sweep (`sql/scratch/Probe-ReadSweep.ps1`).

## 13. Left to the builder

- Exact test file layout, and whether the helpers are TVFs or views.
- Audit wording for the append (`TrayClosed` naming the container LOT) and for the D4 edge update.
- Gate wording for the release pre-flight.
- Seed-generator internals for the benchmark.

## Revision History

| Date | Change |
|---|---|
| 2026-11-04 | Draft from the design conversation with Jacques (D1-D8). |
| 2026-11-04 | Built (plan `docs/superpowers/plans/2026-11-04-container-as-lot-and-lot-volume.md`); section 12 benchmark results; whole-branch review fixes (I1 genealogy loop refusal + closure-based shipped trace, I2 filtered stock index). |
| 2026-11-04 | Builder check: D9 (super-lot window by tray time) and D10 (held skid keeps filling), both Jacques. D11 (`ContainerTray.MintedPieceCount`) and D12 (container-grained rework trace) are my calls. Evidence note copied into `notes/`. |
| 2026-11-16 | Rebased onto `main` as `sp/container-as-lot`: migration `0119_container_as_lot`; clustered `Lots.Lot` (8.1), LOT search v2 (8.2) and the separable perf rewrites split into their own PRs; main's not-closed indexes (`0118`) and queue procs win over this branch's `(location, status)` / `(item, status)` indexes. Sections 8 and 12 describe the original combined build. |
| 2026-11-16 | **Section 8.1 (clustered `Lots.Lot`) dropped (Jacques).** Re-bench on main's indexes: the queues, FIFO stock pick (`IX_Lot_LocationItemCreated`) and LOT search v2 are fast on the heap; the only remaining gain was FG produced summary over the pre-0119 tray LOTs, a set that stops growing. Split-out PRs: OEE refresh tick #17, LOT search v2 #18; line inventory and components-at-cell were already SP-review PRs #11 / #7; `Lot_List` has no caller. |
