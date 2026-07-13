# Smoke Checklist — 2026-07-06/07 changes

Everything landed for the Jacques meeting items + smoke findings. Prep first:
reseed (`sql/scratch/smoke_seed_phase4.sql`), **restart the gateway** (DB was
reset), and reload any file-edited views open in Designer (Routes, RouteStepRow,
ItemMaster, ItemRow, DieCastBody, RejectPanel, TrimBody, MovementScan,
LotDetail, TerminalSelector, ConfirmCreateLot).

## Terminal Selector
- [ ] Table defaults to **100 rows**; pager offers 25/50/100/200.
- [ ] **Search bar** filters live on code / name / zone.
- [ ] Scan-a-terminal-barcode path still selects + navigates.

## Die Cast Entry
- [ ] **Refresh button** (header) re-fetches the mounted tool + shift tally without a page reload (swap the mounted die in Config, hit Refresh, watch the subtitle/tool field update).
- [ ] **Prefill**: picking an Item fills Piece Count from its **DefaultSubLotQty** (5G0-C=48, PNA=100) and Weight = UnitWeight x that count. Only fills EMPTY fields — type a value first and confirm it is not overwritten. *(Weight semantics = computed basket weight — confirm with Jacques.)*
- [ ] **No-template gate**: pick an item whose route has no DieCast-role step → red warning under the Item dropdown + Create blocked with a toast. Then configure a route with a DieCast-role template for one item and confirm Create passes. *(After the DB reset most items will be blocked — that is the gate working, not a bug.)*
- [ ] **Right rail is ONE card** (cavity picker, Shots this shift, Pieces + Scrap for selected cavity, reject entry, peer tally) — **no scrollbar on the card**.
- [ ] **Shots this shift shows a number** (never null/blank). Create a LOT → it climbs. Record a reject → shots stay (as-cast incl. scrap) and the **Scrap line increases**.
- [ ] **Cavity-scoped reject**: select a cavity in the rail → panel reads "Rejecting against <LOT> (Cavity N)" naming the NEWEST open LOT on that cavity; with no cavity selected the button is disabled with a hint; reject a LOT to zero → target rolls to the next-latest LOT on that cavity.
- [ ] **Cavity stamped at creation**: create a LOT with cavity 2 selected → LOT Detail shows Cavity 2 (`Lot.ToolCavityId` correct).
- [ ] **Create LOT confirm popup**: three buttons on one row, no wrap, no scrollbar.
- [ ] 👀 **Open observation — cavity-this-shift dropdown**: it lists every ACTIVE cavity configured on the die (by design). If it still looks like "too many", check that die's Tools → Cavities config; Jacques to call whether it should list only cavities that ran.
- [ ] 👀 **Open observation — cavity dropdown resize glitch**: try to reproduce while selecting a cavity in the New LOT form; note exactly what resizes.

## Trim Station
- [ ] **IN panel: "Currently in Trim" table** lists the open LOTs at the trim zone; scan a LOT in → it moves and the table refreshes.
- [ ] 👀 **Open observation — "null" under Eligible**: after scanning, the review panel should read cleanly — Capacity line now says `... of N` or `(no cap)`. Confirm the reported "null" is gone.
- [ ] **OUT panel: selectable inventory** — tapping a row sets the active LOT (label updates); scanning the LTT still works as the alternative.
- [ ] **Destination dropdown lists production LINES** (e.g. MA1-COMPBR), not Machining-In terminals or printers.
- [ ] **Submit stays on the Trim screen** — form clears, inventory refreshes, no jump to LOT Detail.
- [ ] **LOT lands at the LINE** (check LOT Detail current location) and shows in Machining IN's queue.
- [ ] **Double checkout blocked**: re-scan the same LTT on OUT → reject toast ("not at this Trim station... may already be checked out").
- [ ] **Count caps**: shot count > LOT pieces → rejected; scrap count > LOT pieces → rejected.

## LOT Detail
- [ ] **Total Scrap KPI** in the top strip (red when > 0) = rejects + checkpoint scrap counter.
- [ ] History timeline shows **Production** (teal, template + terminal + shots/scrap) and **Reject** (red, qty + defect) rows; Movement rows read `Name (CODE) -> Name (CODE) [via terminal]`.
- [ ] Paused tab dates show **MM/dd HH:mm** (no long timestamps).

## Item Master (Config Tool)
- [ ] **Item list**: single scrollable list, 45px rows, zero per-row scrollbars.
- [ ] **Routes tab (rebuilt, BOMs-style)** — the big one:
  - [ ] Version dropdown labels `v2 - Name (Published)`; status badge next to it; Include-deprecated checkbox.
  - [ ] **+ New Version lands you IN the draft editor** with steps cloned and the dropdown on the new draft.
  - [ ] Draft rows: **Category dropdown** (3 categories, wide enough to read) → **template list filters to that category**; picking a template fills the **Data Collection** column immediately.
  - [ ] Req checkbox, up/down arrows, row remove, + Add Step all mutate the draft; **Save Draft** enables only when dirty.
  - [ ] Dirty draft + switching item/tab raises the unsaved-changes guard (sectionDirty).
  - [ ] **Publish** shows the "will deprecate vN" confirm when a published version exists; publishes; badge flips.
  - [ ] **Discard Draft** confirms + returns to the published version; **Deprecate** works on a published version.
  - [ ] Item with no routes shows the "+ New Version creates the first draft" hint and it works.
  - [ ] Published (read-only) view: rows show Category / template / Req / Data Collection, no editors, no arrows.
- [ ] **Eligibility tab**: location dropdown offers **Areas + Lines only** — no cells, terminals, or printers.
- [ ] Spot-check: no FDS-numbered text anywhere operator-visible (Hold Management header, Trim scan panel, etc.).

## After the smoke
Report failures per item — everything above except the three 👀 observations is
new/changed code from the last two days.
