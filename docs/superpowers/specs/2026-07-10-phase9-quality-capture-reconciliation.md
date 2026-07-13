# Phase 9 (Quality Capture + CRT + Global Trace) — Reconciliation to current state

**Date:** 2026-07-10 · **Branch:** `hunter/explore` · **Source plan:** `MPP_MES_PHASED_PLAN_PLANT_FLOOR.md` § Phase 9 (ratified in-scope 2026-06-08)

The Phase 9 plan (written 2026-04/06) is executed against the 2026-07-10 tree with the
following deltas. Everything not listed here builds as the plan wrote it.

## Numbering
| Plan said | Now |
|---|---|
| Migration `0028_arc2_phase9_quality_capture.sql` | **`0037_arc2_phase9_quality_capture.sql`** (0028–0036 consumed) |
| Suite `0028_PlantFloor_Quality_Capture/` | **`0037_PlantFloor_Quality_Capture/`** |
| Audit ids (unstated) | `LogEventType` **63 InspectionRecorded, 64 CrtActivated, 65 CrtCleared, 66 MissedCrtInspect**; `LogEntityType` **57 QualitySample** |

## Already exists (don't create)
- `Quality.InspectionResultCode` (Pass/Fail/Conditional) and `Quality.SampleTriggerCode`
  (FirstPiece/LastPiece/Hourly/Random) shipped in `0004`. Migration only **adds** the
  FDS-08-014 triggers as new rows: `ShiftStart`, `DieChange`, `ToolChange`, `TimeInterval`,
  `Manual` (ids 5–9, additive; existing rows untouched).
- `Quality.QualitySpecVersion` / `QualitySpecAttribute` (0008): the FK targets are real.
  Attribute shape: `AttributeName, DataType, Uom NVARCHAR, TargetValue/LowerLimit/UpperLimit
  DECIMAL(18,6), IsRequired, SortOrder`. Active-version resolution reuses the existing
  `QualitySpec_GetActiveForSpec` machinery (view-side); `QualitySample_Record` takes the
  **version id** directly.
- `Lots.Lot.CrtActive` (Phase 1, v1.9q). CRT is procs + audit + UI, no schema.

## Architecture deltas
1. **No `Trace` schema.** The 8-schema architecture stands; trace procs home in `Lots`:
   `Lots.GlobalTrace_Resolve`.
2. **`GlobalTrace_GetFullTrace` dropped** — a header+tree+streams multi-set proc violates
   FDS-11-011 (one result set per proc). The Global Trace **view composes the existing
   per-stream reads** (`Lot_Get`, `Lot_GetAttributeHistory`, `Lot_GetGenealogyTree`,
   `Workorder.ProductionEvent_ListByLot`, `Lot_GetScrapSummary`) after `GlobalTrace_Resolve`
   maps the scanned input to LOT(s).
   - `GlobalTrace_Resolve(@SearchText)` returns candidate rows (one result set):
     `MatchType (Lot|Serial|Container|Shipper), MatchedEntityId, LotId, LotName,
     ItemPartNumber, Detail` — a serial resolves to its `ProducingLotId`; a container to its
     source LOTs (ContainerTray FG LOTs ∪ ContainerSerial producing LOTs); a shipper id via
     `ShippingLabel/AimShipperId` to its container's LOTs. Multiple rows = the FDS-12-013
     disambiguation list.
3. **CRT enforcement is surfaced, not proc-gated (v1).** Plan line "missed-inspect detection
   is consumed by the production procs" would touch TrimOut/RecordPick/Mint — that hard-gate
   is a follow-on decision with Jacques (blast radius). Phase 9 v1 ships:
   `Lots.Lot_SetCrt` / `Lot_ClearCrt` (audit CrtActivated/CrtCleared; clearance elevation is
   the UI's FDS-04-007 concern — proc takes `@AppUserId`), `Quality.Crt_GetRequiredInspections`
   (@LocationId → CRT-active LOTs at/under it + their sample counts/latest result) and
   `Quality.Crt_FlagMissedInspection` (@LotId, writes the MissedCrtInspect audit row).
   Views surface the 200% prompt off the read.
4. **Attachments**: `QualityAttachment` table + `QualityAttachment_Add`/`_ListBySample`
   procs + entity ship now; the **file-upload UI is a Designer follow-up** (gateway file-path
   decision owed) — the API surface is complete.
5. **Print/Export**: MVP = print-friendly Global Trace layout (browser print). The Reporting-
   module report stays in the deferred reporting workstream per the 2026-06-08 split.

## Pass/fail semantics (FDS-08-011.2/3)
Per attribute: `Numeric` attrs with any limit → `IsPass = MeasuredValue within
[LowerLimit,UpperLimit]` (open bounds respected; `NumericValue DECIMAL(18,4)` shadow stored).
Non-numeric attrs → `IsPass = 1` when a value is present, `0` when `IsRequired=1` and empty,
`NULL` (informational) when optional and empty. Overall = `Fail` if any `IsRequired=1`
attribute has `IsPass = 0`, else `Pass`. **No auto-hold on Fail** (FDS-08-012) — the proc
returns the result; alerting is the view's toast.

## Views (all NEW file-authored except two careful edits)
- `ShopFloor/InspectionEntry` (`/shop-floor/inspection`): LOT scan/pick → item's active spec
  version → dynamic attribute rows (numeric entry vs text by DataType, limits shown) →
  Record; Fail = warning toast, no hold. History panel (samples for the LOT, expandable
  per-attribute results). Die-Cast-family styling.
- `ShopFloor/GlobalTrace` (`/shop-floor/trace`): one search input → Resolve → candidate list
  (disambiguation) → full read-only trace composed from existing reads; print-friendly.
- **Careful existing-view edits:** HomeRouter gains the `Track` tile (→ /shop-floor/trace);
  LotDetail gains the CRT badge + Set/Clear CRT actions (elevation-gated) and an
  Inspections cross-link.

## Test suite `0037_PlantFloor_Quality_Capture/`
Per plan: record + rollup + no-auto-hold; numeric limits (in/at/out of bounds, open-ended);
required-empty fail; CRT set/clear + audit + required-inspections read + missed-flag;
resolver: LOT name, serial, container id, AIM shipper id, ambiguous prefix → multiple rows,
no match → 0 rows. Target ≥70 assertions. All INSERT-EXEC / Msg-3915 / one-result-set rules
per `sql/scripts/_TEMPLate_stored_procedure.sql` conventions.
