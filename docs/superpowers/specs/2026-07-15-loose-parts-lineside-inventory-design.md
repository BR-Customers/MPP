# Loose-Parts Lineside Inventory — Receive-as-LOT — Design Spec

**Date:** 2026-07-15
**Status:** Draft — awaiting Hunter review
**Author:** Blue Ridge (with Claude)
**Arc / Phase:** Arc 2 (Plant Floor) — extends the Spec 2 machining/assembly flow. Adds a "receive by part# + qty" path to the lineside inventory check-in popup by **minting a `Received`-origin LOT** at the line.
**Related:** `docs/superpowers/specs/2026-07-02-machining-assembly-plant-floor-flow-design.md` (I1/I2 — the `InventoryManager` popup + `Lot_GetLineInventoryByPart`). Reference impl reused nearly verbatim: `Views/ShopFloor/ReceivingDock` (part#-scan → `Received` LOT mint).

> **History:** an earlier draft of this spec modeled loose parts as a **non-LOT count bucket** (new `Parts.InventoryTrackingMode` flag, `Lots.LineInventory` balance + ledger, `Assembly_CompleteTray` auto-decrement). That was reversed in dialogue (2026-07-15): loose parts are now **minted as normal LOTs** so they behave exactly like every other parts lot. All of that data-model / proc work is dropped. This spec reflects the minted-LOT design only.

---

## 1. Motivation

The lineside inventory check-in popup (`Components/PlantFloor/InventoryManager`) today has a single input — **scan an LTT** — which resolves an *existing* LOT by name and moves it onto the line (`Lots.Lot_MoveToValidated`). It cannot handle the common case MPP raised: an operator receives **a box of loose parts with no LTT** — they have only a part number and a piece count.

The fix is to let the operator scan/pick the **part number**, enter the **piece count**, and have the system **mint a `Received`-origin LOT** for that part+qty at the line — the same thing the Receiving Dock already does. Because it is a normal LOT, it immediately behaves like every other parts lot: it appears in the on-hand table, and Assembly consumes it via the existing BOM-FIFO path (`Workorder.Assembly_CompleteTray`) into finished-good genealogy. Nothing downstream needs to change.

---

## 2. Decisions locked (from brainstorming)

1. **Mint a LOT, don't track loose.** A box of loose parts scanned by part# + qty is **minted as a `Received`-origin LOT** at the line (`Lots.Lot_Create`), identical to the Receiving Dock flow. It is a first-class LOT with full genealogy participation — no separate non-LOT representation.
2. **Two explicit sections in the popup.** `InventoryManager` gets a **Check in LTT** section (today's scan → move, unchanged) and a distinct **Receive loose parts** section (part# scan/pick + qty + Add).
3. **No LTT print (silent mint).** The receive mints the LOT and it appears in the on-hand table; **no label is printed** and there is no navigation away (it's a popup). The box stays physically unlabeled. *(Consequence to accept: a later manual move/hold of that box has no printed barcode to scan; Assembly BOM-FIFO consumption needs none. If MPP later wants labels, add the Receiving Dock's print + reprint-on-failure path — a self-contained follow-up.)*
4. **Vendor LOT optional.** A nullable, collapsed **Vendor LOT** field is available on the receive form (carried on `Lot.VendorLotNumber`), but the minimal flow is just part# + qty.
5. **Eligibility gate — already enforced by `Lot_Create`.** A loose-parts receive must reject a part that is not eligible at the line. **No new proc is needed** — `Lots.Lot_Create` step 4 already rejects a mint whose Item is not eligible at `@CurrentLocationId` (`Parts.v_EffectiveItemLocation`, `Direct ∪ BomDerived`, ancestor-cascaded via `Location.ufn_AncestorLocationIds`), returning `Item is not eligible at the specified location.`. Because the receive calls `Lot.create` → `Lot_Create`, the gate is automatic; the popup surfaces the rejection via `notifyResult`. (`Lot_Create` also caps `PieceCount ≤ Item.MaxLotSize` — an over-count receipt is rejected too.)
6. **No dedicated part picker.** The receive section keeps the compact scan-or-pick **dropdown listing all active parts** (`Item.getForDropdown`) — *not* a separate/scoped picker view. An ineligible pick is caught by the decision-5 gate on Add. (Declined: scoping the dropdown to line-eligible parts, and a dedicated picker popup.)

---

## 3. Scope of change

**This is an Ignition front-end change with no new SQL.** Every server-side building block already exists and is used by the Receiving Dock:

| Building block | Status |
|---|---|
| `Lots.Lot_Create` (mint, server-generated LTT name when `@LotName` NULL) — **already enforces the eligibility gate** (step 4) + `PieceCount ≤ MaxLotSize` | exists |
| `BlueRidge.Lots.Lot.create(data, appUserId, terminalLocationId)` | exists |
| `BlueRidge.Lots.Lot.getOriginTypeIdByCode("Received")` | exists |
| `BlueRidge.Parts.Item.getForDropdown()` / `getByPartNumber(partNumber)` | exists |
| `Lots.Lot_GetLineInventoryByPart` + `Lot.getLineInventoryByPart` (on-hand table) | exists — **unchanged**, already lists these LOTs |
| `Lots.Lot_MoveToValidated` (the existing LTT check-in) | exists — **unchanged** |

No migration. No new/changed stored procs. No named-query changes (all needed NQs — `lots/Lot_Create`, `lots/LotOriginType_List`, `parts/Item_List`, `lots/Lot_GetLineInventoryByPart` — already exist).

---

## 4. `InventoryManager` popup (edit — new section added)

Root stays `pf-*` plant-floor styling and `meta.name: "root"`. The current popup is a single flex column (Header, scan label, scan field, on-hand label, on-hand table). The change restructures the top into two labeled sections and adds the receive form; the on-hand table is untouched.

### 4.1 New view state (`view.custom`)

Added alongside the existing `scanCode` / `refreshToken`:
- `receiveDraft: { "partItemId": null, "qty": "", "vendorLotNumber": "" }` — **fully-shaped default** (pre-declared-bound-props + editDraft-shape rules: every bound key seeded so the form doesn't render `"null"`/error borders before first load).
- `partOptions` — bound to `runScript("BlueRidge.Parts.Item.getForDropdown", 0)` (all active parts, matching the Receiving Dock). *Scope note: this can later be narrowed to line-eligible parts via a scoped read; kept broad + zero-SQL for v1.*
- `receivedOriginId` — bound to `runScript("BlueRidge.Lots.Lot.getOriginTypeIdByCode", 0, "Received")`.

### 4.2 New custom method `receiveLoose()`

A view `customMethod` mirroring `ReceivingDock.createLot` **minus the print + navigate tail** (matching the existing `InventoryManager.checkIn` house style of multi-line orchestration customMethods). Logic:

1. Unwrap `receiveDraft` + `partItemId` (`extractQualifiedValues`).
2. Resolve the part: a numeric option value is a real `Item.Id`; a free-text (custom-option) value is a part-number string → `Parts.Item.getByPartNumber` → `Id`. Unknown part → warning toast, return.
3. Coerce `qty` to a positive int (blank/invalid → warning toast, return).
4. Resolve `appUserId` (`session.custom.appUserId`) and `terminalLocationId` (`session.custom.terminal.terminalLocationId`, best-effort).
5. `BlueRidge.Lots.Lot.create({ itemId, lotOriginTypeId: receivedOriginId, currentLocationId: params.locationId, pieceCount: qty, vendorLotNumber: (draft.vendorLotNumber or None) }, appUserId, terminalLocationId)`.
6. `Common.Ui.notifyResult(res, "Parts received")`. On success: reset `receiveDraft` to its empty shape, bump `refreshToken` (re-reads the on-hand table), and `system.perspective.sendMessage(params.replyMessage, {"lotId": res.NewId}, scope="page")` so the embedding view refreshes (same contract the LTT check-in already uses).

If `params.locationId` is null, toast "No line selected" and return (same guard as `checkIn`).

The **eligibility gate is server-side** (decision 5): `Lot_Create` returns `Status=0, Message='Item is not eligible at the specified location.'` for an ineligible part (and a MaxLotSize message for an over-count), which `notifyResult` surfaces as an error toast — no client-side eligibility check, no minted LOT. The client does only the cheap input coercion above (part resolution, positive-int qty).

### 4.3 New children (between the LTT scan and the on-hand table)

A **Receive loose parts** section (`pf-panel`, `overflow:hidden` on single-line rows):
- Part# **dropdown** (`ia.input.dropdown`, `allowCustomOptions: true`, `search.enabled: true`) bound to `partOptions`, value bidirectional to `receiveDraft.partItemId`, 44px min height.
- **Piece Count** text-field (`inputType: "tel"`), value bidirectional to `receiveDraft.qty`.
- Optional collapsed **Vendor LOT** text-field, value bidirectional to `receiveDraft.vendorLotNumber` (decision 4).
- **Add** button → `self.view.rootContainer.receiveLoose()`.

The existing **Check in LTT** scan field is relabeled into its own section header for symmetry; its behavior (`onBlur → checkIn()`) is unchanged. `defaultSize.height` grows (~560 → ~720) to fit the new section.

### 4.4 On-hand table — unchanged

`InventoryTable` keeps its current binding to `Lot.getLineInventoryByPart` (grouped by part, FIFO by arrival). A freshly-minted Received LOT lands with `CurrentLocationId = the line`, so it appears in the table on the next `refreshToken` bump with its server-minted LTT name, available qty, and arrival time — no read change needed.

### 4.5 Embedding — unchanged

`AssemblyIn` / `AssemblyNonSerialized` / `AssemblySerialized` / `MachiningIn` / `MachiningOutSplit` already open `mpp-inventory` with `params={locationId: session.custom.cell.locationId, replyMessage: "inventoryChanged"}`. The button tooltip ("Check component / pass-through inventory in to this line") already fits.

---

## 5. Testing / verification

No SQL tests (no SQL change). Verification is a **Designer smoke** of the popup (the CLI-impossible step), against a demo-seeded, gateway-restarted dev DB:

1. Open the popup from an assembly line (`session.custom.cell.locationId` set, operator resolved).
2. **Receive loose parts:** pick/scan a part number, enter a qty, Add → success toast; the on-hand table shows a new Received LOT row for that part+qty; the form clears; the embedding view's inventory refreshes.
3. Free-text part number (type a part# not in the list) resolves via `getByPartNumber`; unknown part# → warning toast, no LOT minted.
4. Blank/zero/negative qty → warning toast, no LOT minted.
5. **Eligibility gate (decision 5):** pick/scan a part that is **not** eligible at this line → Add → error toast `Item is not eligible at the specified location.`, **no** LOT minted. Then pick an eligible (Direct or BOM-derived) part → succeeds.
6. **Over-count:** enter a qty greater than the part's `MaxLotSize` → Add → error toast (MaxLotSize message), no LOT minted.
7. **Check in LTT** still works unchanged (scan an existing LTT → LOT moves onto the line).
8. Optional Vendor LOT flows onto the minted `Lot.VendorLotNumber` (verify via LOT Detail).
9. Received LOT is consumable: complete an assembly tray whose BOM includes that part → it draws down via the existing FIFO path (proves "behaves like any other lot").

File-author the view edit + `scan.ps1`; keep Designer closed on `InventoryManager` until the scan is picked up (open-view reconciliation caution). Because the popup is substantially restructured (new sections + state), authoring the whole `view.json` fresh is acceptable — but confirm no stale Designer cache exists first (it's an existing view).

---

## 6. Change inventory

**SQL:** none.

**Ignition (MPP project, file-authored + scanned):**
- `Components/PlantFloor/InventoryManager/view.json` — add `receiveDraft` / `partOptions` / `receivedOriginId` state, the `receiveLoose()` custom method, and the **Receive loose parts** section; relabel the LTT scan into its own section; grow `defaultSize.height`. On-hand table + `checkIn` unchanged.

**Ignition entity scripts:** none required — `Lot.create`, `Lot.getOriginTypeIdByCode`, `Item.getForDropdown`, `Item.getByPartNumber` all exist. *(Optional, only if we later scope the picker to line-eligible parts: a `Parts.Item.get…ForLocation` helper + read — deferred.)*

**Docs:** a short FDS note under the Assembly/Inventory section — the lineside inventory popup can receive loose parts by part# + qty, minted as a `Received` LOT (no label). Data Model unchanged. OIR: close/track any related open item. Regenerate `.docx` if FDS text changes.

---

## 7. Open items / risks

1. **Unlabeled boxes (decision 3).** Minted LOTs get no printed LTT, so a later *manual* move/hold of that physical box has no barcode. Accepted; Assembly consumption doesn't need one. Revisit if MPP wants labels (drop-in Receiving Dock print path).
2. **Duplicate/rapid Add.** The Add button should debounce or the operator could mint two LOTs on a double-tap; a minor UX guard (disable-while-inflight) is worth including in the build.
3. **All-parts dropdown + gate (decisions 5–6).** The picker lists all active parts and the server gate rejects an ineligible pick on Add. If operators find scrolling all parts noisy, scoping the dropdown to line-eligible parts is a later follow-up (one scoped read + entity method) — deliberately *not* done in v1.

*(Resolved during design: the eligibility gate needs no new proc — `Lot_Create` enforces it. See §2 decision 5.)*

---

## 8. Build order (feeds writing-plans, or direct build — small scope)

1. Edit `InventoryManager/view.json`: state + `receiveLoose()` + Receive-loose-parts section; grow height. `scan.ps1`.
2. Designer smoke per §5.
3. FDS note + `.docx` if changed.

Given the scope (one view, no SQL), this may not warrant a full multi-phase implementation plan — a direct build against §4 + the §5 smoke checklist is likely sufficient.
