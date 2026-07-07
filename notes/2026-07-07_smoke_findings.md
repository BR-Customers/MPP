# Smoke Findings — 2026-07-07

Findings while going through `notes/2026-07-07_smoke_checklist.md`. Each item maps back to a checklist section.

> **Fix-pass annotations (2026-07-07, second session):** every item below carries a ✅/⚠️ note describing what was changed. All view edits file-authored (scan owed); SQL verified by suite runs.

---

## Terminal Selector — scan-barcode field + search bar not centered
On the **Terminal selection** screen, the **"scan terminal barcode"** field and the **search bar** are **not centered** (alignment fix). *(Checklist § Terminal Selector.)*

> ✅ **Fixed.** The scan row centered as a group (icon + input), which pushed the input box 36px right of the search bar's center. Added a trailing 26px spacer to balance the icon and matched both input boxes at 360px — the two bars now share the exact center axis.

## Terminal Selector — typing in the search bar throws a table error 🐞
Typing anything in the **terminal search bar** makes the **table throw an error**:
- **Subcode:** `Error_ExpressionEval`
- **Property:** `root/TerminalsTable.data`
- **Description:** `Error executing script for runScript() expression: BlueRidge.Location.Terminal.filterForSelector`

The `filterForSelector` runScript bound to `TerminalsTable.data` errors on search input. *(Files: `Core/.../BlueRidge/Location/Terminal/code.py` → `filterForSelector`; `MPP/.../ShopFloor/TerminalSelector/view.json`. Checklist § Terminal Selector — search bar.)*

> ✅ **Fixed.** Root cause: `{view.custom.terminals}` arrives in a runScript expression as Perspective `ImmutableMap` rows — `.get()` AttributeErrors, and `extractQualifiedValues` does not unwrap those types (empty search returned rows untouched, which is why the table rendered until you typed). `filterForSelector` now JSON-round-trips the rows to plain dicts first.

## Die Cast — piece-count prefill should use the part's "parts per basket" field
On Die Cast, the **piece count** prefill should source from the part's **parts-per-basket** field — **not** the field currently used. *(Checklist prefill item uses `DefaultSubLotQty`; tasks-file note used `Item.MaxParts` — this corrects the source to parts-per-basket. ⚠️ Confirm the exact `Parts.Item` column that represents "parts per basket" — MaxParts vs DefaultSubLotQty vs another — and repoint the prefill to it. Checklist § Die Cast Entry — Prefill.)*

> ✅ **Fixed.** Column confirmed from Data Model v1.9: **`Item.MaxLotSize` is repurposed as `PartsPerBasket`** (the Config Tool Item screen labels it "Parts Per Basket"); `DefaultSubLotQty` is the Machining-OUT sub-lot split qty. Prefill now reads `MaxLotSize` first, `DefaultSubLotQty` only as a dev-data fallback (dev items may not have PartsPerBasket populated — set it on 5G0-C/PNA via the Item screen to see the true value). Weight is still `UnitWeight x count` — the ⚠️ weight-semantics confirm with Jacques stands.

## Die Cast — Item dropdown filtering wrong 🐞
The **Item dropdown** on Die Cast is not filtering correctly. It should list **only items that (a) have a Die Cast route** (a DieCast-role route step) **AND (b) are eligible at that cell**. Currently showing items that don't meet both. *(Combine the route-role check `getActiveTemplateIdForRoute(item,'DieCast')` with cell eligibility `Item_ListEligibleForLocation` — the dropdown source should be the intersection. Note: eligibility now resolves at Area/Line tiers via the cascade. Checklist § Die Cast Entry — No-template gate / dropdown.)*

> ✅ **Fixed SQL-side.** `Parts.Item_ListEligibleForLocation` v2.1 adds optional `@OperationTypeCode`: when supplied, only items whose non-deprecated route carries a step of that role are returned — the **same predicate as the no-template gate**, so dropdown membership == gate pass. New NQ `parts/Item_ListEligibleForLocationByRole`; `Item.getEligibleForLocationDropdown` grew the role arg; DieCastBody passes `"DieCast"` (+ refreshToken so the header Refresh re-pulls the list). Tests added to `0023/050` (property-based: filtered = exactly the qualifying subset); suite green. Existing callers (assembly FG dropdown) unchanged.

## Die Cast — reject must record against the CAVITY, not a LOT (still wrong)
Confirmed in smoke: **reject entry is still recording against a LOT** — it should record **against the cavity**. *(Reinforces the Jacques decision in `2026-07-06_jacques-meeting.md`; current behavior charges the reject to the active LOT via its `ToolCavityId`. Change the target to the selected cavity. Checklist § Die Cast Entry — Cavity-scoped reject.)*

> ⚠️ **Investigated — the mechanics were already cavity-scoped; presentation + one real create-path bug fixed.** Verified end-to-end in the code that landed 97310ac: the right-rail cavity selection (`tallyCavityId`, value = ToolCavityId) drives `Lot_GetLatestForToolCavity` (tested, `0022/070`) → reject charges the **newest open LOT on the selected cavity** and rolls to the next when one closes. Two changes made anyway: (1) the panel label was LOT-first ("Rejecting against MESL-x (Cavity N)") — now cavity-first: *"Rejecting Cavity N - charges newest open LOT MESL-x"*; (2) **real bug**: `submitCreate` classified a *typed* cavity by `int()` parse, so typing cavity number "2" was treated as ToolCavityId 2 instead of a manual CavityNote (D2) — now classified by membership in the dropdown's option ids. **If the intent is that rejects need NO open LOT at all (pure machine/cavity scrap), that's a schema change (`RejectEvent.LotId` nullable or a cavity FK) — needs Jacques's call.** Re-smoke: select cavity 2 in the rail with LOTs open on cavities 1+2 and confirm the reject decrements the cavity-2 LOT.

## Die Cast — "Active Cell" card has an unwanted scroll bar
The card that displays the **Active Cell** has a **scroll bar** when it shouldn't (size to fit / `overflow:hidden`). *(Separate from the shift-counts-card scrollbar noted 07-06. Checklist § Die Cast Entry.)*

> ✅ **Fixed.** `overflow: hidden` on the ContextBar (the Active Cell card).

## Die Cast — "Shots" section has an unwanted scroll bar
The section that displays **shots** has a **scroll bar** when it shouldn't (size to fit / `overflow:hidden`). *(Third scrollbar issue — Active Cell card, shift-counts card, and now the Shots section. Likely a common `overflow` pass across the Die Cast rail/cards. Checklist § Die Cast Entry.)*

> ✅ **Fixed.** Overflow pass across the rail cards: `overflow: hidden` added to the CumulativeCard (Shots/Pieces/Scrap KPI section), ActiveCavityCard, and ToolCavityRow (the RightRail itself already had it).

## Die Cast — Cavity dropdown resizes the whole bar on open 🐞 (repro'd, screenshots)
**Reproduced** the cavity dropdown resize glitch (checklist 👀 observation). Opening the **CAVITY** dropdown **resizes the whole bar weirdly** — the open options list doesn't match the closed field's width/alignment (options box appears narrower / left-offset vs. the full-width field), so the control visibly jumps when opened/closed.
- Screenshots (2026-07-07): closed = full-width `Cavity 1 ▾` with helper text "Active cavities on the mounted tool. No active cavities? Type one (manual, D2)"; open = options popup `Cavity 1` misaligned/narrower.
- Likely CSS on the `ia.input.dropdown` — this one has **`allowCustomOptions:true`** (manual cavity entry, D2), which is the variant that tends to size oddly. Check the dropdown's width/menu style in `DieCastBody/view.json` (cavity picker). *(Checklist § Die Cast Entry — cavity dropdown resize observation.)*

> ⚠️ **Static fix applied — needs smoke confirmation.** Both cavity dropdowns (New LOT form + right rail) now carry `width: 100%`, and their containers `overflow: hidden`. Theory: opening the dropdown transiently changed its intrinsic size → a scrollbar appeared in the un-hidden container → content width shrank → the open options popup (which tracks the field width) rendered narrower/offset. Pinning the width + killing the scroll channel removes both inputs to that loop. If it still jumps on smoke, next step is DevTools on the open options modal.

## Die Cast — "scan or pick a cell" dropdown should live in the Active Cell card
The **scan-or-pick-a-cell** dropdown should be moved **into the same card as the Active Cell label** (co-locate the cell selector with the Active Cell display). *(Layout/grouping change — DieCastShared/DieCastBody. Checklist § Die Cast Entry.)*

> ✅ **Fixed.** DieCastShared's separate PickerBar is gone; the picker dropdown now sits inside DieCastBody's Active Cell ContextBar, right after the cell value. Gated by a new `cellPickerEnabled` view param — Shared passes `true`, Dedicated passes nothing (picker hidden, cell still comes from the terminal zone). The dropdown's value tracks `session.custom.cell.locationId`, so it always shows the active cell.

---

## Trim — LOT inventory should use the machining card style
The **LOT inventory at Trim** ("Currently in Trim" table) should be styled as **cards, matching the machining screen's inventory** (consistency with the machining inventory card style, not a plain table). *(Files: `TrimBody/view.json`; reference the machining inventory card layout / `InventoryManager`. Checklist § Trim Station — Currently in Trim.)*

> ✅ **Fixed.** New reusable `Components/PlantFloor/Trim/InventoryRow` card modeled on `Machining/QueueRow` (position / LOT name / part · pcs · arrived / Good-Hold pill, 92px rows). The IN panel's table is now a card repeater; the OUT panel uses the same cards with a **Select** action (page message `trimLotSelected`) and a highlight on the active pick. Arrival time is preformatted in Python (`Lot.mapTrimInventoryInstances`).

## Trim — OUT tab has bad spacing/layout
The **Trim OUT tab** has **terrible spacing and layout** — needs a general spacing/layout pass. *(Files: `TrimBody/view.json` OUT panel. Checklist § Trim Station — OUT panel.)*

> ✅ **Fixed.** OUT panel restructured from a full-width stack into **two columns**: the tappable inventory pick list on the left (grow), the form on the right (420px — scan, selected-LOT label by *name* not raw id, destination line, shot/scrap counts, combined-cap help text, Trim OUT button). Overflow hidden on all the single-line rows.

---

## LOT Detail — history row time still not rounding
On the **LOT Detail history rows**, the **time does not round properly** (still showing over-precise/long timestamps). *(Reinforces the 07-06 "round the date" note; the rounding fix isn't taking on the history rows. Files: `Components/PlantFloor/LotDetail/HistoryRow/view.json` — check the date/`dateFormat` binding. Checklist § LOT Detail.)*

> ✅ **Fixed.** Date math moved out of the expression layer entirely: new `Lot.mapHistoryInstances` precomputes `EventAtDisplay` ('MM/dd HH:mm') and `EventAgo` ('3h ago') in Python (the Date serializes to a string on the repeater param hop, and `dateFormat`/`dateDiff` then pass the raw value through). The HistoryRow MetaLabel just concatenates the precomputed strings. If the Paused tab shows the same symptom on re-smoke, PauseRow gets the identical treatment.

---

## Trim OUT — validate shot + scrap COMBINED against the lot's current parts
On **Trim OUT**, add a check that **shot count + scrap count (added together) cannot exceed the LOT's current number of parts**. *(Refines the earlier per-field caps — it's the SUM that must not exceed current pieces, not each field independently. Files: `R__Workorder_TrimOut_Record.sql` + the TrimBody OUT form. Checklist § Trim Station — Count caps.)*

> ✅ **Fixed.** `TrimOut_Record` v1.2: the two per-field caps replaced by one combined guard — `ISNULL(shot,0) + ISNULL(scrap,0) <= Lot.PieceCount`. Tests: combined-over rejects, boundary (sum == pieces) passes, per-field cases still covered (`0024/050`). The OUT form carries a help line stating the rule; the proc's toast message names the numbers on rejection.

## Trim OUT — scrap count should subtract from the LOT
When a **scrap count** is entered on a LOT at **Trim OUT**, that number of parts should be **subtracted from the LOT's piece count** (scrap decrements the lot). *(Files: `R__Workorder_TrimOut_Record.sql` — decrement `Lot.PieceCount` by the scrap qty on the move. Checklist § Trim Station.)*

> ✅ **Fixed.** `TrimOut_Record` v1.2: the whole-LOT move now subtracts `@ScrapCount` from `Lot.PieceCount` (never negative — guaranteed by the combined cap), so the LOT arrives at the machining line with its real remaining quantity. Test: 20 pieces − 2 scrap = 18 asserted in `0024/040`. Happy-path fixture updated to shot 18 + scrap 2 (the old 20+2 violates the combined cap by design).
