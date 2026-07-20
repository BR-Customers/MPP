# LTT as LOT Identity — Die Cast & Machining OUT

**Date:** 2026-07-20
**Status:** Draft (design approved; pending spec review → implementation plan)
**Scope tag:** MVP (Plant Floor / Arc 2)
**Author:** Blue Ridge Automation

---

## 1. Problem

The physical **LTT (LOT Tracking Ticket)** barcode is what operators scan to move a LOT into a location, consume it, and trace it — it is the LOT's identity across the entire plant floor. In the MES, that identity **is** `Lots.Lot.LotName` (there is no separate barcode column; `UQ_Lot_LotName` is the single uniqueness guard, and every scan-resolution, label token, audit line, and genealogy read keys on it).

Today **every LOT-birth path fabricates its own identity** by minting `MESL{0:D7}` from `Lots.IdentifierSequence` code `'Lot'`. This is wrong for the real MPP process:

- At **Die Cast**, LTT labels are **bulk pre-printed by an external scheduler** — the physical ticket exists *before* the LOT. `DieCastBody` already scans that ticket into `editDraft.scannedLtt`, but the create call passes `lotName=None`, mints an unrelated `MESL…`, compares, toasts "LTT mismatch", and **throws the scan away** (`DieCastBody/view.json:1281`). The result: the ticket on the physical basket does not match the LOT's identity, so downstream scans cannot find it.
- At **Machining OUT**, the legacy convention treats a new machined LOT as a **sublot of its source**: `<sourceLTT>-01`, `-02`, … `MachiningOut_Mint` ignores this and sequence-mints a fresh `MESL…` instead.

This spec fixes the two birth points where the scanned/derived LTT is actively discarded. **Assembly OUT is a separate follow-on** (its FG-lot + AIM-shipper binding leans on the AIM interface and container closure).

## 2. Scope

**In scope**
- Die Cast birth: adopt the operator-scanned external LTT as `LotName`.
- Machining OUT: derive `LotName` as `<sourceLTT>-NN` and auto-print its label.

**Out of scope (explicitly)**
- **Assembly OUT** — FG lot number + AIM shipper ID binding → separate spec.
- **`Lot_Merge`** — keeps its `MESL` sequence mint (merge is exception-only: holds / quality / logistics).
- Received LOTs and any non-die-cast, non-machining origin of `Lot_Create` — behavior unchanged.
- Changing the `IdentifierSequence 'Lot'` counter mechanics (it still serves Assembly FG + Merge).

## 3. Identity model

One identity column remains — `LotName` = the LTT. After this change, three name shapes coexist under the same `UQ_Lot_LotName`:

| Birth point | `LotName` shape | Source | Counter advanced? |
|---|---|---|---|
| Die Cast | `123456789` (9 digits) | Operator scans external pre-printed LTT | No |
| Machining OUT | `123456789-01` | Derived: consumed casting `LotName` + suffix | No |
| Assembly OUT *(out of scope)* | `MESL0003001` | `IdentifierSequence 'Lot'` mint | Yes (unchanged) |

`LotName` is `NVARCHAR(50)`, so all three shapes fit and remain mutually unique. No schema change to `Lots.Lot`.

## 4. Die Cast design

### 4.1 Validation helper (new)
`Lots.ufn_IsValidExternalLtt(@Ltt NVARCHAR(50)) RETURNS BIT` — a scalar SQL function encoding the external-LTT format rule (domain logic belongs in SQL, not Python):
- **Confirmed rule:** exactly 9 characters, all numeric (`0`–`9`).
- **Checksum:** a check-digit/checksum validation is expected but the exact algorithm is **not yet confirmed** (see §8). The function ships with the 9-digit check and a clearly-marked checksum stub returning valid, so the real rule drops in as a one-function change with no caller churn.

### 4.2 `Lots.Lot_Create` — origin-aware external LTT
The `@LotName` ("D4") parameter and its verbatim-use / counter-suppression path already exist (`R__Lots_Lot_Create.sql:50`, `:318-329`) plus a friendly uniqueness pre-check (`:163`). Changes:
- For **die-cast-origin** creates, `@LotName` becomes **required** and must pass `Lots.ufn_IsValidExternalLtt`. Reject (status-row, no mint) on: missing LTT, failed format/checksum, or duplicate.
- For all **other origins**, behavior is unchanged (optional `@LotName`; NULL → server-mints from the counter).
- The origin discriminator is the `LotOriginType` the caller passes; the exact code for die-cast birth is verified at implementation (see §7).

### 4.3 `DieCastBody` view (Designer edit)
- Pass `editDraft.scannedLtt` into `BlueRidge.Lots.Lot.create(...)` in place of the literal `None` at `DieCastBody/view.json:1281`.
- Remove the now-dead "minted vs scanned mismatch" comparison + toast (there is no separate minted name anymore).
- Keep the client thin — no format logic in Python; the proc validates and returns a status row that the existing toast surface reports.
- Cavity-parallel births already call `Lot_Create` once per cavity, so each cavity LOT carries its own scanned LTT with no additional machinery.

## 5. Machining OUT design

### 5.1 `Workorder.MachiningOut_Mint` — derive sublot name
Replace the inline `IdentifierSequence 'Lot'` mint block (`R__Workorder_MachiningOut_Mint.sql:100-108`) with suffix derivation:
- `@MintedName = @SrcName + N'-' + <NN>`, where `<NN>` is the next 2-digit, zero-padded suffix across existing children of the source casting (`LotName LIKE @SrcName + N'-%'`, take max existing suffix + 1, starting at `01`).
- Mirror the proven `-NN` derivation + concurrency locking already in `Lots.Lot_Split` (`R__Lots_Lot_Split.sql:271-337`) so concurrent mints from the same source don't collide.
- The counter is **not** advanced. All other logic in the proc — Consumption genealogy edge (`RelationshipTypeId=3`), closure ancestors, `ConsumptionEvent`, `MachiningOut` `ProductionEvent`, source decrement/close, audit — is unchanged.

### 5.2 Auto-print the sublot LTT
After `MachiningOut_Mint` returns a successful `@NewId`, the Machining-OUT terminal's **Core Python** (the caller of the mint) invokes the existing label path — `BlueRidge.Lots.LotLabel.printLabel(newLotId, …)` → `Lots.LotLabel_Print` → Zebra ZPL dispatch. This is Python orchestration only (the dispatch is already Python raw-TCP), so it is a file-editable Core-script change, not a Designer view edit. The label renders `{LotName}` = `<sourceLTT>-NN`, giving the new basket a scannable ticket.

## 6. Testing

**Die Cast (`Lot_Create`, die-cast origin)**
- Rejects: missing `@LotName`, non-9-digit / non-numeric, duplicate `LotName`.
- Accepts a valid 9-digit LTT; stores it verbatim as `LotName`; **does not advance** `IdentifierSequence 'Lot'`.
- Non-die-cast origins still mint server-side when `@LotName` is NULL (no regression).
- `Lots.ufn_IsValidExternalLtt` unit assertions: valid 9-digit passes; 8/10-digit and alpha fail.

**Machining OUT (`MachiningOut_Mint`)**
- First mint from a source → `<src>-01`; second → `-02`; suffix uniqueness holds; counter untouched.
- Consumption/genealogy/close behavior unchanged from current passing tests.

**Regressions to update**
- Machining fixtures asserting `MESL…` minted machined names (`sql/tests/0027_*`) move to `<src>-NN`.
- Die-cast counter test `sql/tests/0023_PlantFloor_DieCast_Deltas/030_Lot_Create_LotName_and_Cavity.sql` stays valid (supplied-name-does-not-advance-counter already asserted); extend it with the new format-rejection cases.

## 7. Implementation verification points
Confirm these against the code during implementation (not assumptions to bake in blind):
- The exact `LotOriginType` code used for die-cast birth in `Lot_Create` (drives the origin-aware branch).
- The precise Core-Python caller of `MachiningOut_Mint` (where the auto-print call is added) and the correct `printLabel` signature / label-type + reason arguments.
- That `Lot_Split`'s suffix + locking pattern is transplantable as-is into `MachiningOut_Mint` (same `ROWLOCK/UPDLOCK` discipline; INSERT-EXEC safety preserved — all rejections before `BEGIN TRANSACTION`).

## 8. Open items
- **LTT checksum rule** — Jacques to confirm the exact check-digit/checksum algorithm for the 9-digit external LTT. Until then `ufn_IsValidExternalLtt` enforces the 9-digit-numeric rule with a checksum stub; the real rule is a one-function edit.

## 9. Blast-radius reference (unchanged consumers)
These all key on `LotName` and continue to work because the LTT *is* `LotName` — no changes required, listed to document why the single-column model is safe:
- Scan-resolution: `Lots.Lot_Get`/`getByName`, `MovementScan`, `Workorder.Assembly_ScanIn`, `Lots.GlobalTrace_Resolve`, `Lots.Lot_Search`.
- Label token `{LotName}` and `{ParentLotNumber}` in `Lots.LotLabel_Print`/`_Reprint`.
- Audit "Activity" prose and genealogy/queue/detail reads that project `LotName`.

## Revision History

| Date | Change | Author |
|---|---|---|
| 2026-07-20 | Initial design — Die Cast external-LTT adoption + Machining OUT sublot derivation; Assembly OUT deferred. | Blue Ridge Automation |
