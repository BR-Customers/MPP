# Working Notes — 2026-07-20

**Session:** Part configuration + testing walkthrough (Config Tool / Item Master). Jacques driving; Claude as fact-finder + note-taker.

---

## Item Master tooltips added

Added `meta.tooltip.text` + `meta.tooltip.enabled` to every field label across three Item Master sub-views (MPP_Config). Placed on the **field-label** (not the input) so the hover target always renders and disabled inputs don't swallow hover. Descriptions written against the `Parts.Item` / `Parts.ContainerConfig` / `Parts.ItemLocation` data-model definitions.

- **Eligibility** (`ItemMaster/Eligibility/view.json`) — 5 column headers: Location, Consumption, Min, Max, Default.
- **Identity** (`ItemMaster/Identity/view.json`) — 12 fields: Part Number, Item Type, UOM, Description, Macola Part #, PLC / Vision Recipe ID, Unit Weight, Weight UOM, Default Sub-Lot Qty, Parts Per Basket, Country of Origin, Max Parts.
- **Container Config** (`ItemMaster/ContainerConfig/view.json`) — 7 fields: Trays Per Container, Parts Per Tray, Serialized, Closure Method, Target Weight, Dunnage Code, Customer Code.

All scanned to gateway clean.

## Field semantics captured (reference)

### Eligibility (`Parts.ItemLocation`)
- **Consumption (`IsConsumptionPoint`)** — `1` = location consumes the part as an **input** (enables Min/Max/Default + runtime Allocations scan-in). `0` = location **produces** the part or is merely eligible.
- **Min / Max / Default (`MinQuantity` / `MaxQuantity` / `DefaultQuantity`)** — per-scan-in quantity band; only meaningful when Consumption on. Default pre-fills the scan form; Min/Max reject under/over-scan.
- **Eligibility cascades UP the hierarchy** — `LocationId` can be Area / WorkCenter / Cell; a row at a higher tier applies to all Cells beneath. `Parts.ItemLocation_IsEligible(@ItemId, @CellLocationId)` walks Cell→Site, first match wins.

### Identity (`Parts.Item`) — non-obvious ones
- **Parts Per Basket** = `MaxLotSize`, repurposed v1.9 (one LOT = one basket = one LTT label at Die Cast/Trim/Machining). Also the max LOT size.
- **Max Parts** = `MaxParts` — hard cap on pieces of the part at **any single location** (Cell), NOT per shipping container. Scan-in rejects existing+incoming > cap.
- **Default Sub-Lot Qty** = `DefaultSubLotQty` — default pieces per sub-LOT at Machining OUT sublotting (FDS-05-009).
- **PLC / Vision Recipe ID** = `PlcId` — integer recipe number PLC/vision loads for the part; blank if none.

## Bugs found + fixed

1. **Mojibake em-dash in part header** — `Identity/view.json` `SummaryText` expression had the em-dash stored as the 3-byte mojibake sequence (`â€"`, i.e. `â€”`), so the header read `12231-59B-0000 â€" 59B Cam Holder...`. Classic ASCII-only violation. **Fixed** → plain hyphen ` - `.
2. **"Max Parts (per container)" label mislabeled** — field is a per-*location* cap, not per-container. **Renamed** label → `Max Parts (per location)`; tooltip already describes the real behavior.

## Parts under test

- `12231-59B-0000` — 59B Cam Holder IN #1 Casting (Component). No container config yet at time of review (all fields blank, Closure Method = Select...).

## LTT-as-LOT-identity work (Die Cast + Machining OUT)

Spec: `docs/superpowers/specs/2026-07-20-ltt-lot-identity-diecast-machining-design.md`. Plan: `docs/superpowers/plans/2026-07-20-ltt-lot-identity-diecast-machining.md`.

Model landed: `LotName` IS the LTT (single identity column). Die Cast adopts the operator-scanned external LTT (external scheduler owns the numbers, bulk pre-printed); Machining OUT derives `<sourceLTT>-NN` + auto-prints its label; Assembly OUT (FG lot + AIM shipper) is a **separate follow-on**.

### OPEN: external LTT checksum rule — Jacques to confirm

Die Cast LTT validation currently = **9 numeric digits + uniqueness only**. Jacques flagged there is also a **checksum/check-digit** on the 9-digit external LTT that still needs to be confirmed.

- **Where it drops in:** `Lots.ufn_IsValidExternalLtt(@Ltt)` (new function, plan Task 1). It ships with the 9-digit check and a clearly-marked **checksum STUB** (currently a no-op returning valid). Adding the real algorithm is a **one-function edit** — no caller/proc churn, no re-plan.
- **Action owner:** Jacques — get the exact check-digit algorithm from the external scheduler / LTT spec, then update the stub in `ufn_IsValidExternalLtt` and add a rejecting test case to `sql/tests/0023_PlantFloor_DieCast_Deltas/031_ufn_IsValidExternalLtt.sql`.

### Implementation status (2026-07-20 SDD run)

Tasks 1-4 + 6 built + reviewed on `jacques/working` (commits ca3f482e, 0a647a55, 2fa6762c, c0e9e0bf, c85de722, 3f568288, 95aab1b2; DB guardrail cfffa805). Full suite at baseline (zero new failures) on `MPP_MES_Test`.

**Task 5 (DieCastBody) is NOT done — it's a Designer edit for Jacques.** Steps in plan §Task 5 / `docs/superpowers/plans/2026-07-20-ltt-lot-identity-diecast-machining.md`: in `submitCreate`, pass `editDraft.scannedLtt` into `Lot.create(...)` instead of `None` (arg 4), and delete the dead "minted vs scanned mismatch" toast.

**⚠️ DEPLOY COORDINATION (do NOT skip):** the new `Lot_Create` makes die-cast `@LotName` **required**. Until Task 5 lands, the DieCastBody UI still passes `None`, so deploying the new proc to the live gateway DB **breaks die-cast LOT creation from the UI**. Deploy the new SQL procs to `MPP_MES_Dev` **only together with** the Task 5 view edit. (Dev currently runs the OLD procs — rebuilt pre-Task-2 by the reset incident — so the app works today; the break happens on the next proc redeploy.)

### Open follow-ups (from reviews)
- **MachiningOut_Mint concurrency:** the `UPDLOCK` source re-read guards the `-NN` ordinal but doesn't re-validate source availability/status under the lock like `Lot_Split` does. Rare same-casting two-session race could over-consume. Net improvement over old (no lock). Candidate follow-up task.
- **`smoke_seed_shipping.sql` is broken independently** of this work: hardcodes `USE MPP_MES_Dev` (a footgun like the old `clear_demo`) and references stale `6MA`/`6MA-M` parts no longer in the catalog. Needs a refresh or retirement.
- **Minor:** `LIKE @SrcName + N'-[0-9][0-9]'` in the ordinal probe is unescaped (safe on the 9-digit die-cast path; defensive `ESCAPE` if a non-die-cast casting name could carry `%_[`). Synchronous print now on the Machining-OUT hot path (~up to 8s stall on printer-offline, after the mint commits).

### DB-safety guardrail added
`Run-Tests.ps1` now defaults `-DatabaseName` to `MPP_MES_Test`; `Reset-DevDatabase.ps1` refuses to drop any `*_Dev` DB without `-Force` (commit cfffa805). See [[project_mpp_dev_db_testing_env]].

## Stuck session state → stale terminal zone (root of several Trim/eligibility symptoms)

Several confusing plant-floor symptoms this session all traced back to a **stale session terminal**: the session was bound to the **Fallback Terminal**, whose `session.custom.terminal.zoneLocationId` = the whole **Madison Facility** (id 2) rather than a specific Trim area. Consequences observed:

- **Trim inventory swept plant-wide** — `getWipQueueByLocation(zone, includeDescendants=true, ...)` with the facility as the zone returned LOTs from TRIM1 + Warehouse + everywhere, so the IN list showed castings that were physically in the **Warehouse** (pending TrimIn) as "CURRENTLY IN TRIM."
- **"Not eligible at destination" on Trim check-in** — the validated move checks eligibility by **exact match against `zoneLocationId`** (no hierarchy walk; see [[project_mpp_move_eligibility_location_resolution]]). With the zone = facility, a part eligible at `TRIM1` (not at the facility) fails → false "not eligible."

**Confirmed fix by Jacques:** closing and reopening the sessions cleared the stale terminal and the "not eligible" error went away. So the data/config was correct all along — the session id/terminal was stuck.

### TODO (Jacques, 2026-07-20): nav tree should refresh the session terminal property

The **navigation tree** used to jump to a configured view (the DevNav / plant-hierarchy `NavigationTree` picker) **should also send a message to update the session property** when it navigates — i.e. selecting a terminal/view in the tree must re-sync `session.custom.terminal` (and clear/refresh the zone) rather than leaving whatever stale terminal the session already holds. This keeps the terminal zone fresh on navigation and prevents the stuck-session symptoms above without needing a full session close/reopen.

### Still pending: Trim inventory should scope to the trim shop, not the terminal zone

Jacques's directive (not yet implemented): **both Trim IN and Trim OUT should list the LOTs that currently reside in that trim shop** (by physical current-location), replacing the route-role proxy (`TrimIn`/`TrimOut`). The view already carries `params.areaId` (= `37`/TRIM1), which is the correct anchor for "this trim shop" and is robust even on the fallback terminal. Plan: bind both `trimInInventory` + `trimOutInventory` to a current-location read scoped to `params.areaId` (LOTs at/under the trim area), keep the `TrimOut` role only as the "ready to route" filter on the OUT action if still wanted. `MovementScan.destinationLocationId` (TrimBody) currently also binds to `zoneLocationId` — revisit so check-in targets the trim area too.
