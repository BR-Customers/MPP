# Consolidated Smoke Test — 2026-07-23/24 Meeting-Driven Workstreams

**Date:** 2026-07-24
**Scope:** The location-model reconciliation + six workstreams built from the 2026-07-22 meeting notes. (Die cast is intentionally **excluded** — held pending customer feedback on the lifecycle spec.)
**Environment:** `MPP_MES_Dev` (all backend deployed live); full SQL suite **green** on `MPP_MES_Test`.

Legend per feature: **✅ done** · **🖥 Designer/view wiring left** · **🧪 smoke steps**.

> **Update 2026-07-24:** the Ignition **view layer is now built too** (file-authored with Designer closed, scanned into the gateway) — MachiningIn flex + queue rebind, `loginAs` audit call, TrimBody dropdown removal + "Lot count", AssemblyNonSerialized `componentProjection` binding, and the new `ThirdPartyInspection` tabs view + route. The `🖥` sections below are therefore **implemented**; treat them as "what to verify" rather than "still to do". **One exception:** the inspection **Inspect** tab shows the received-LOT queue but the full quality-capture *attribute form* (dynamic inputs from the QualitySpec → `QualitySample_Record`) is **scaffolded, not finished** — the first consumer of the Phase-9 capture API and a meaty form on its own. Check-in and check-out are fully functional via the embedded proven views.

---

## 0. Location model reconciled to the Site DB ✅

The plant location model was reconciled to `MPP_MES_Site` (the authoritative onsite map) and applied to Dev **in place** (renames preserve `Location.Id`, so the 50 live LOTs + the PLC registration stayed attached). Codes corrected to match authoritative names; printers pruned to OUT-only; DefaultScreen/closure/scanner/confirm seeded; `66B-TC` moved under the new `INSP` area; trim storage (`TRIM1-STORE`/`TRIM2-STORE`) and the inspection area added.

**🧪 Smoke**
1. Open a terminal at each of a few renamed cells (e.g. `MA1-FP6NA-AOUT`, `MA2-5PA-MOUT`, `MA2-RPYCAM1-MIO-RS5`). Confirm the **correct default screen** loads (Assembly OUT / Machining OUT / combined tabs).
2. Confirm **only** MOUT/AOUT/combined/serialized-assembly terminals have a printer; die-cast, trim, MIN, AIN terminals have none.
3. Vision-through-scale terminals (`MA1-FP6NA-AOUT`, `MA1-FPRPY-AOUT`, `MA2-5PA-AOUT`) read closure = **ByVision** — and need the **scale UDT wired on the Ignition side** (config task, not code).
4. Spot-check a couple of names verbatim (`METTs Assembly Out`, `RPY Comp bracket`) — names are authoritative, unchanged.

> Re-applying: `sql/scripts/reconcile_location_dev.sql` is the one-time in-place transform (generated; wrap in a transaction). Fresh DBs get the reconciled model straight from the regenerated seed `011`.

---

## 4. Terminal operator-change audit ✅  🖥 one line

**Backend done** (migration 0044 event type 75; `Audit.OperatorChange_Log`; NQ `audit/OperatorChange_Log`; wrapper `AppUser.logOperatorChange`; tests 18/18).

**🖥 Designer:** in `Components/Popups/InitialsEntry`, custom method **`loginAs`** — capture the old operator before overwriting, then call the wrapper:
```python
old = self.session.custom.user or {}
# ... existing writes to session.custom.user / appUserId ...
BlueRidge.Location.AppUser.logOperatorChange(
    old.get("appUserId"), appUserId,
    (self.session.custom.terminal or {}).get("terminalLocationId"))
```

**🧪 Smoke**
1. Sign in operator A (first bind) → Audit Browser shows `<Terminal> · Operator · Signed in A` (ET timestamp).
2. Change Operator → B → one `<Terminal> · Operator · Changed A → B` row (resolved names in Old/New JSON).
3. Re-scan the **same** operator → **no** new row.
4. On the fallback terminal (unregistered IP) → description uses the literal `Terminal`.

---

## 5. Machining 50/50 flex 🖥 one property

**🖥 Designer** (existing view — do it in Designer, not a file edit): `Views/ShopFloor/MachiningIn`, component **`ActiveLotPanel`**, change `position` from `{ shrink: 0 }` to **`{ basis: "0", grow: 1, shrink: 1 }`** (matching `QueuePanel`).

**🧪 Smoke:** open Machining IN → the "Active machined LOT (after pick)" panel and the FIFO queue split the height **50/50**.

---

## 6. Assembly-OUT projected consumption + low flag ✅  🖥 view binding

**Backend done** (`Workorder.Assembly_GetComponentProjection`; NQ + `Assembly.getComponentProjection`; tests 10/10). Display-only — **not** a gate.

**🖥 Designer (coordinate with the active AssemblyNonSerialized rewrite):** add custom prop `view.custom.componentProjection` (default `[]`), bind via `runScript` to `BlueRidge.Workorder.Assembly.getComponentProjection({cell.locationId}, coalesce(container.ItemId, selectedFinishedGoodItemId), {session.custom.closureMethod}, {refreshToken})`; render each component row with `OnHand` / `ProjectedRemainingConsumption` and a LOW pill gated on `IsLow`.

**🧪 Smoke**
1. Open a container mid-fill (say 2 of 4 trays) → each component shows projected remaining consumption = per-tray need × remaining trays.
2. Stage a component below that projection → it shows a **LOW** pill (and `Shortfall`); staging more clears it.
3. Numbers reconcile with what Complete Tray actually consumes (same integer math + exact-cell pool).

---

## 7. Combined Machining IN/OUT terminal (tabs) ✅

**Done** — new view `Views/ShopFloor/MachiningStation` (tab container embedding `MachiningIn` + `MachiningOutSplit`), route `/shop-floor/machining` (matches the DefaultScreen on the `In - out` terminals: `MA2-RPYCAM1-MIO-RS5`, `MA2-RPYCAM2-MIO-RS5`).

**🧪 Smoke**
1. Open a combined terminal (`…-MIO-RS5`) → two tabs, **Machining IN** and **Machining OUT**, both bound to the one session terminal.
2. **Verify the one risk:** that terminal's zone resolves the machining line for **both** roles — the IN queue and the OUT queue both show line-scoped LOTs (not the whole facility; watch the "Madison Facility" fallback tell).

---

## 2. Trim storage → Machining IN line assignment ✅  🖥 two views

**Backend done.** Trim OUT deposits every trimmed LOT into the local shop's **Trim Storage** (`TRIM{N}-STORE`), resolved internally (no line picker); `Lot_GetTrimStorageQueueForLine` shows each line only the Trim-Storage LOTs eligible there; `MachiningIn_RecordPick` v2 **claims** the LOT (move Trim Storage → line, race-safe) then records the checkpoint. Full suite **2144/0** (also fixed the pre-existing `0027` route tests).

**🖥 Designer:**
- `Views/ShopFloor/TrimBody` — remove the destination dropdown (`DestField`/`destValue`/`destCells` + binding); `submitTrimOut()` drops `destinationCellLocationId`; relabel **"Shot count" → "Lot count"**.
- `Views/ShopFloor/MachiningIn` — rebind `custom.queue` from `getWipQueueByLocation(...)` to **`BlueRidge.Lots.Lot.getTrimStorageQueueForLine({cell.locationId}, refreshToken)`** (same columns, no transform change).

**🧪 Smoke**
1. Trim OUT a LOT (no line picker; counter reads "Lot count") → the LOT lands in `TRIM{N}-STORE`.
2. That LOT appears at Machining IN on **every line it's eligible for** (the two-line part shows on both lines).
3. Pick it on line A → it moves onto line A and **disappears from line B's** queue (claim-move).
4. Re-scan the same LOT for OUT → rejected ("not at this Trim station"); pick an ineligible part at a line → rejected ("not eligible at this line").

---

## 3. Third-party inspection station ✅ backend  🖥 new view

**Model (customer-confirmed):** an inspected part is a **bought-in component consumed by a newly-minted pass-through FG** — check-out **is assembly-out** (`Assembly_CompleteTray` mints the FG consuming the received component; `Container_Complete` claims the AIM id + label). The FG's container config is a normal FG config, **1 lot → 1 tray → 1 container**. So the only new backend is the station queue read `Lots.Lot_GetInspectionQueueByLocation` (Received-origin LOTs at the station + latest inspection result). Tests 7/7.

**🖥 New view `Views/ShopFloor/ThirdPartyInspection`** (file-authored + scan; route `/shop-floor/third-party-inspection`), three panels sharing the station's session cell:
- **Check in** — reuse `ReceivingDock`'s create flow: `Lots.Lot.create` (Received origin, `VendorLotNumber`, mint MPP LotName + print LTT). Mints the bought-in **component** LOT at the station.
- **Inspect** — pick list from `Lots.Lot.getInspectionQueue`; load the part's active `QualitySpecVersion` attributes into a form; submit `Quality.QualitySample.record`; Pass/Fail toast. (First shop-floor consumer of the Phase-9 quality-capture API.)
- **Check out** — embed / reuse **Assembly OUT** (`AssemblyNonSerialized`): the pass-through FG consumes the inspected component and ships (container + AIM label). **Gate:** enable check-out only when the component's latest inspection = **Pass** and no open hold (the queue read supplies the result; server integrity is the assembly-out proc). On **Fail**, offer one-tap `Quality.Hold.place`.

**Config prerequisite (seeding):** for each third-party part, seed (a) the pass-through **FG Item + BOM** (FG ← received part), (b) an FG **ContainerConfig** (1 tray × N), (c) the FG's **AIM shipper-id pool** entries, and (d) the received part eligible at the inspection station.

**🧪 Smoke**
1. Check in a vendor LOT (vendor lot # captured, MPP LTT printed) → appears in the inspect queue with **no result**.
2. Inspect → **Pass** → check-out enables; **Fail** → check-out blocked + Place Hold offered.
3. On Pass, check out → assembly-out completes: pass-through FG minted consuming the received component, container completed with an AIM shipping label.
4. Re-inspect a held LOT → Pass → release hold → check out.

---

## Suite status
`MPP_MES_Test` full suite: **PASS 2151 / FAIL 0** (2144 after trim + 7 inspection-queue). No regressions; the previously-pre-existing `0027` MachiningIn failures are now fixed.

## Not in this scope
- **Die cast** open/accumulate/release lifecycle — **held** pending customer feedback on the spec's assumptions.
- Downstream **pass-through parts tracking** — FUTURE per the Scope Matrix (inspection builds the station only).
