# LOT volume and the container-as-LOT decision (2026-11-04)

Starting point for the DB-volume branch that follows the OEE prod release.
Decision (Jacques, 2026-11-04): **move to container-as-LOT**. Not built.

## What we found

- The schema was sized for ~150K LOTs/year (OI-35, from the legacy
  `IdentifierFormat` reading). The legacy row counts agree with that grain:
  `reference/legacy_mes_extract/mes_tables.csv` (snapshot 2026-07-08) has
  `dbo.Lot` 554K + `Lot_Historical` 1.46M = ~2.0M LOTs since 2011, and
  `dbo.Container` 1.78M (~127K/yr). **Legacy has no tray entity** --
  only `WorkOrder.TrayQuantity`. The produced unit is the `Container`;
  `ContainerLot` links consumed component LOTs to it.
- Our `Workorder.Assembly_CompleteTray` mints a full FG LOT (MESL number,
  status history, movement, closure, ~12 consumption + genealogy rows) per
  **tray**. Prod 6MA-CH (`notes/2026-09-15_line-run-audit-MA2-6MACH_2043.txt`):
  113 trays in ~3 h, peak 44/h, 4 pcs/tray, 24 trays = one 96-pc container.
- At Jacques's rates (cam holders: a 96-pc container every 30-40 min; oil pans
  6-8 x 60-pc containers/shift; others ~a tray every 3 min) that is **~3M FG
  LOTs/year** (~20x design). The MESL range (3,000,000-9,999,999, the proc
  refuses past the end) would run out in ~2-3 years. Container-as-LOT brings
  FG LOTs back near the legacy ~130K/yr.
- The FRS (3.10.11) already reads this way: consumption records carry
  "Produced LOT or Container ID" and "Produced Tray ID (when appropriate)".
- Legacy die-cast LOT numbers are ~10.6M (`reference/Lot Numbers by daterange.pdf`)
  -- a separate pre-printed LTT counter, not the 1.7M figure.

## Container-as-LOT blast radius (code sweep, 2026-11-04)

Counts of files touching `FinishedGoodLotId` / `ContainerTray` /
`Assembly_CompleteTray` / `Container_Complete`: ~46 repeatable procs, ~66 test
files, ~21 Ignition resources.

| Area | What changes |
|---|---|
| Mint | `Assembly_CompleteTray`: mint (or find) the container's LOT on the first tray, add pieces per tray; `Container_Complete` closes it. B5 materialized qty grows per tray. |
| Tray record | `Lots.ContainerTray` stays as the tray ID (FRS "Produced Tray ID"); `FinishedGoodLotId` goes, the LOT hangs off `Container`. |
| Genealogy | One edge per (container LOT, source LOT) instead of per tray; closure rows per container, not per tray -- the biggest row saving. Decide whether `ConsumptionEvent` stays per tray (tray-level trace) or per container. |
| OEE | `Oee.ufn_ShiftGood` reads FG `Lot.ShiftId` + `MintedPieceCount` at mint. A container can straddle a shift change, so good must come from a per-tray record (ShiftId on the tray / its consumption) instead. |
| Holds / Controlled Run | Tray-LOT holds, `Quality.ControlledRun*` membership, `Hold_ListAssociatedContainers`, `Hold_Release`; see `notes/2026-10-29_followon-tray-lot-hold-blocks-container.md`. |
| Rework / Sort cage | `ContainerRework_*` (MovePieces, Scrap, ListTrays...), `SortCage_MigrateSerial` move pieces between tray LOTs. |
| Ship / label / AIM | `Container_GetLabelData`, `ufn_ShippingLabelZpl`, `Tools.ufn_ContainerOriginDieRankCode`, `GlobalTrace_Resolve`, `Lot_GetLinkedContainer`, `AimPost`, `ShippingDispatcher`. |
| CRT | `Lots.ufn_CrtForMint`, `Container_ValidateCrt`, `Container_ListPendingValidation`. |
| Watchers | `NonSerializedMipWatcher`, `TrayInspectionWatcher`, `ScaleWatcher`, `ScaleEPrintWatcher` call the tray mint. |
| Views | `AssemblyNonSerialized`, `LotDetail`; scale-station reads (`ScaleStation_*`, `FinishedGoods_GetProducedSummary`). |
| Prod data | Existing 6MA-CH tray LOTs in prod stay as history: **readers handle both shapes** (Jacques, 2026-11-04) -- tray-LOT containers from before the change, container LOTs after. Every reader in this table needs a test for each shape. |

## Same branch, smaller items

- `Lots.Lot` is a heap with no `CreatedAt` index; add clustered `(CreatedAt, Id)`,
  likely on `ps_MonthlyUtc`. Cheap now (prod has one line), a rebuild later.
- `Lot_Search` / `Lot_SearchAdvanced`: drop or cap `COUNT(*) OVER()`; route LOT
  numbers to exact/prefix seeks and part numbers via `Parts.Item` first; default
  recent window with "search older".
- Year-scale benchmark on a throwaway restore of Dev (`MPP_MES_Bench`) using
  `sql/scratch/seed_oee_history.sql` + `Measure-OeeDevVolume.ps1`, before and after.
- Real rates to replace estimates: read-only LOT/tray counts per day from prod,
  and Lot / Container creation per month from legacy (EXCSRV05 is not reachable
  from the build machine -- Jacques runs it).
