# Inspection-station quality-capture form + Assembly consume hold-guard — Design

**Date:** 2026-07-24
**Author:** Blue Ridge Automation
**Status:** Approved (direction confirmed by Jacques 2026-07-24) — ready for TDD implementation.
**Type:** Plant-floor (Arc 2). Amends `2026-07-23-inspection-station-third-party-receiving-design.md` (§7 Ignition surface, §8 pass/fail gate) with the ground truth that the capture form already exists.

---

## 1. Summary

Two coupled pieces of work close out the third-party **Inspect** tab (the last scaffold from the 2026-07-22 meeting workstreams):

1. **Consume hold-guard fix (SQL).** `Workorder.Assembly_CompleteTray` is the **only** consume path that does not exclude blocked (`BlocksProduction=1` — Hold/Scrap) source LOTs from its FIFO consume. Every sibling proc does. Restore consistency so a held LOT physically cannot be consumed by assembly/check-out. This *is* the check-out PASS gate — no bespoke rule.
2. **Inspect-tab form (Ignition).** The dynamic quality-capture form already exists as the standalone `InspectionEntry` view. The `ThirdPartyInspection` Inspect tab currently shows only a monospace queue label. Replace it by **embedding `InspectionEntry` as-is**, and add a one-tap **Place Hold** affordance to the form for the Fail path.

No new SQL procs, no new tables, no from-scratch form.

---

## 2. Ground truth found during investigation

The plant's universal block is **status-based, not location-based**: `Hold_Place` flips `Lot.LotStatusId → Hold (2)` **in place** (it does not relocate the LOT to the Sort Cage). `Hold` carries `BlocksProduction = 1`. The shared guard `Lots.Lot_AssertNotBlocked` rejects any LOT whose status has `BlocksProduction=1` or is `Closed`. "Only actionable at the Sort Cage" is enforced *behaviorally* — every advance/move/consume proc refuses a blocked LOT, and only the `SortCage_*` procs act on one.

Enforcement audit across lot-event procs:

| Lot event | Excludes blocked source? |
|---|---|
| Move (`Lot_MoveTo`, `Lot_MoveToValidated`) | ✅ calls `Lot_AssertNotBlocked` |
| Advance (`TrimOut_Record`, `MachiningIn_RecordPick`, `ProductionEvent_Record`, `RejectEvent_Record`, `LotPause_Place`, `Lot_Split`) | ✅ subject-LOT guard |
| Consume (`LotGenealogy_RecordConsumption`) | ✅ inline block-guard on source |
| Consume-mint (`MachiningOut_Mint`) | ✅ FIFO candidate set requires **Good** status |
| **Consume (`Assembly_CompleteTray`)** | ❌ FIFO filters `<> Closed` only |

`Assembly_CompleteTray` is the lone exception — the `BlocksProduction` check was dropped when the consume was inlined (per the INSERT-EXEC rule). Its sibling `MachiningOut_Mint` does it correctly. **This is a latent bug affecting all assembly consumption, not just third-party inspection.**

---

## 3. Part 1 — Assembly consume hold-guard (SQL, TDD)

**Change `Workorder.Assembly_CompleteTray`** (`R__Workorder_Assembly_CompleteTray.sql`) in the two places it reads component stock. Today both filter `sc.Code <> N'Closed'`; both must also exclude blocked status. Use `sc.BlocksProduction = 0 AND sc.Code <> N'Closed'` (covers Hold **and** Scrap; keeps the existing Closed exclusion explicit) — matching the intent of `Lot_AssertNotBlocked`.

- **§7 pre-check short-list** (the `OUTER APPLY … SUM(l.InventoryAvailable)` availability sum, ~line 190–193): add the guard so held inventory is not counted as available. Otherwise the pre-check would report "enough stock", then the consume walk would skip the held LOT and hit the `Component stock drained mid-consume` RAISERROR — a confusing failure. Guarding both keeps the advisory pre-check and the authoritative walk consistent.
- **§B4 FIFO consume walk** (`SELECT TOP 1 … ORDER BY l.CreatedAt`, ~line 334–339): add the same guard so a blocked LOT is never selected as a consume source.

Version bump + header note in the proc (mirror-of-`MachiningOut_Mint` rationale). No signature change; no caller/NQ/test-shape change beyond the new assertion.

**Test (TDD first):** new `sql/tests/0028_PlantFloor_Assembly/097_Assembly_CompleteTray_skips_held_source.sql`.
- Arrange: FG item with a 1-line BOM; one component LOT at the cell with exactly enough pieces; place it on Hold (`Quality.Hold_Place`).
- Assert: `Assembly_CompleteTray` returns `Status=0` with the insufficient-stock short-list message (the held LOT is not counted), and the held LOT's `InventoryAvailable`/`PieceCount` are unchanged (not consumed).
- Second case: a second **Good** component LOT present alongside the held one → consume takes only the Good one (FIFO skips the held), FG mints correctly.
- Follow the existing `092`/`093` fixtures + INSERT-EXEC temp-table pattern; teardown FK order (closure/audit before LOTs).

**Blast radius:** low. Existing `092`/`093` assume Good source LOTs, so they stay green. The only behavior change is that Hold/Scrap sources are now excluded — the intended fix.

---

## 4. Part 2 — Inspect tab embeds the existing form (Ignition)

### 4.1 What already exists (reused verbatim)
- `Views/ShopFloor/InspectionEntry` (route `/shop-floor/inspection`) — LOT scan/resolve → active-spec load (`QualitySpec.getActiveVersionForItemOrEmpty`) → `AttributeRow` repeater → trigger dropdown → **RECORD** → `QualitySample.recordFromEntries` → `Quality.QualitySample_Record` → Pass/Fail toast → inspection-history panel (`SampleRow`).
- Components `AttributeRow`, `SampleRow`; entity glue `recordFromEntries`; all scanned and functional.

### 4.2 Inspect-tab embed
In `Views/ShopFloor/ThirdPartyInspection/view.json`, replace the `InspectTab` container's current children (the `InspectHeader` label + `InspectQueue` monospace label) with a single `ia.display.view` embedding `BlueRidge/Views/ShopFloor/InspectionEntry` (`grow:1`), matching how `CheckInTab` embeds `ReceivingDock` and `CheckOutTab` embeds `AssemblyNonSerialized`. File-authored edit via `json.load`/`json.dump` (GSON unicode escapes) + `scan.ps1`.

The station operator flow becomes: **Check In** (ReceivingDock mints the received LOT + prints LTT) → **Inspect** (scan that LTT into the embedded form, enter measurements, RECORD) → **Check Out** (AssemblyNonSerialized).

**Known wrinkle (accepted, embed-as-is):** `InspectionEntry` carries its own header/operator/Refresh/Close chrome, and its **Close** button navigates to `/`, which would leave the whole `ThirdPartyInspection` screen. Acceptable for MVP; noted for a future polish pass (could hide the close button when embedded).

### 4.3 Fail → one-tap Place Hold (the gate's operator path)
Add a **Place Hold** affordance to `InspectionEntry` that appears after a **Fail** result on the resolved LOT. This belongs in the form (it benefits every inspection consumer, not just third-party) and is what makes a failed LOT un-checkoutable via the Part-1 guard.

- New `view.custom.lastResult` (default `""`) set from the `record()` customMethod's result Message (`"Fail"`/`"Pass"`).
- A **Place Hold** button, visible only when `lastResult = "Fail"` and the LOT has no open hold, via a thin `placeHold` customMethod calling the existing wrapper `BlueRidge.Quality.Hold.place(holdTypeCodeId=1, lotId=<lot.Id>, reason="Failed incoming inspection", appUserId=<session.appUserId>, terminalLocationId=<terminal>)` → `notifyResult` toast → refresh (bump `refreshToken`). `HoldTypeCode` id 1 = `Quality` is the default for a failed-inspection hold. "No open hold" is read via `BlueRidge.Quality.Hold.getOpenByLot(lot.Id)` (empty = none). Both wrappers already exist — no new Python.
- No check-out button change is required: with Part 1 in place, a held LOT simply cannot be consumed by `AssemblyNonSerialized`/`Assembly_CompleteTray`. The Check Out tab needs no bespoke gate.

### 4.4 Not doing
- No `InspectionCheckOut` proc (check-out stays `AssemblyNonSerialized` → `Assembly_CompleteTray` → `Container_Complete`).
- No queue-driven pick-list in the Inspect tab (embed-as-is; the form resolves LOTs by scan/type, and ReceivingDock prints the LTT to scan).
- No downstream pass-through tracking (FUTURE per Scope Matrix row 20).

---

## 5. Implementation order (in-session TDD, serial)

1. Write failing test `0028/097`; run to confirm it fails (current proc consumes the held LOT).
2. Fix `Assembly_CompleteTray` (both stock reads); rerun `0028` suite green on throwaway `MPP_MES_Test`; run the full suite to confirm no regressions.
3. Deploy the repeatable proc to `MPP_MES_Dev` (data-safe, no reset).
4. Edit `InspectionEntry/view.json`: `lastResult` custom prop + Place Hold affordance + `placeHold` customMethod (reusing the existing `Hold.place`/`Hold.getOpenByLot` wrappers); `scan.ps1`.
5. Edit `ThirdPartyInspection/view.json`: Inspect tab embeds `InspectionEntry`; `scan.ps1`.
6. Update `PROJECT_STATUS.md` (correct the "form NOT built" note → embedded existing form + guard fix) and this session's smoke doc.

**Verification:** full `MPP_MES_Test` suite green; both edited views valid JSON + `scan.ps1` clean; commit to `jacques/working` with explicit paths (leave the concurrent-session `Core/…/Location/Location/code.py` untouched).

---

## 6. Revision history
| Version | Date | Author | Change |
|---|---|---|---|
| 1.0 | 2026-07-24 | Blue Ridge Automation | Initial. Investigation of consume hold-guard consistency; design to fix `Assembly_CompleteTray` + embed the existing `InspectionEntry` form in the third-party Inspect tab. |
