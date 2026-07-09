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

---

## Machining IN — lot moved to the line does not appear in the Machining-IN queue 🐞
After Trim OUT moves a LOT to its **production line** (WorkCenter), the LOT **does not show up on the Machining IN terminal** for that line. The **Machining IN FIFO queue must look at the LOTs on the LINE**, not just the Machining-IN cell.
- Root cause candidate: the Machining-IN queue read is cell-scoped (`Lot_GetWipQueueByLocation(cellId, includeDescendants=false)`), but the LOT now lives at the parent **line** (`CurrentLocationId` = WorkCenter). The queue needs to read at the **line** (the terminal's parent WorkCenter) — either pass the line id, or `includeDescendants`/ancestor-aware so a line-resident LOT surfaces.
- *(Follow-on from the Trim OUT → deposit-at-line change. Files: `MachiningIn/view.json` queue binding, `Core/.../BlueRidge/Lots/Lot/code.py` `getWipQueueByLocation`, `R__Lots_Lot_GetWipQueueByLocation.sql`. Checklist § Trim Station — "LOT lands at the LINE and shows in Machining IN's queue".)*

> ✅ **Fixed (2026-07-08, post-merge).** The screen's anchor was already the line on a real MIN terminal (onStartup binds `session.custom.cell` to the terminal's parent line), but the reads were `includeDescendants=false` — exact-match only. That misses (a) the dev/fallback terminal whose zone is not the line, and (b) LOTs deposited at cells *under* the line (the 6MA demo threads deposit at MA1-FPRPY-MIN). All queue reads flipped to `includeDescendants=true` — anchor + full subtree — across **MachiningIn (both role queues), MachiningOutSplit, AssemblyIn, AssemblyNonSerialized, AssemblySerialized** (same latent wall on each; descendants of a line are only its own cells, so no cross-line bleed on real terminals). Note the merged terminal-mint model also **role-filters** these queues by route: the LOT's item must have a published route whose next pending step matches the screen (e.g. MachiningIn) — a part with no/partial route will still not list, by design. Re-check: trim OUT to a line → LOT appears on that line's Machining IN; on the dev/fallback terminal the queue is plant-wide (role-filtered), which is intended for dev.

---

## Assembly — container fields stop prepopulating after a container is started 🐞
After a **container is started**, the fields **no longer prepopulate** (a prefill that worked before the container opens stops working once it's open). *(⚠️ Confirm WHICH field(s) — piece/tray count? finished-good dropdown? — and the trigger. Likely the prefill logic only runs on the no-open-container path / doesn't re-run once `Container_GetOpenByCell` returns an open container. Files: `AssemblyNonSerialized/view.json`, `Lots/Container`, `Assembly.completeTray`/finished-good dropdown. Checklist § — Assembly / container.)*

> ✅ **Fixed (2026-07-09).** Exact mechanism: the parts-in-tray prefill fires from `fgConfig`'s onChange, which only runs when the CONFIG value changes — after tray 1 the config is unchanged (same container/item) and the tray-complete handler blanked the field, so tray 2 stayed empty. The tray-complete success path now **re-primes** `partsCount` from the part's configured `PartsPerTray` after every tray.

## Assembly — tray position should be auto-assigned, not manually input
Question raised: **why input a tray position at all** — it should be **auto-assigned**. Remove/hide the manual **tray position** input and have the system assign it automatically. *(Aligns with the earlier note that `AssemblyNonSerialized`'s `trayPosition` draft field is vestigial — `completeTray` already auto-assigns the position. So: drop the manual input entirely. Files: `AssemblyNonSerialized/view.json` tray form; `Assembly_CompleteTray`.)*

> ✅ **Fixed (2026-07-09).** The Tray position input is removed from the form — `Assembly_CompleteTray` auto-assigns the position (the input was never read).

## Trim OUT & Machining OUT — destination must be eligibility-filtered
On both **Trim OUT** and **Machining OUT**, the operator should **only be able to select a destination area/line that the item is eligible at**. Filter the destination dropdown to areas/lines where the LOT's item is eligible (via the eligibility cascade). *(Trim OUT lists machining lines; Machining OUT lists its downstream destinations — both should intersect with `Item` eligibility. Files: `Location_ListMachiningDestinations` / the Machining-OUT destination read, `Item_ListEligibleForLocation` + `ufn_AncestorLocationIds` cascade; `TrimBody/view.json`, `MachiningOutSplit/view.json`.)*

> ✅ **Fixed (2026-07-09).** **Trim OUT:** `Location_ListMachiningDestinations` v2.0 adds optional `@ItemId` — when the screen has an active LOT, the dropdown lists only lines where that LOT's item resolves via the FDS-03-014 cascade (the exact predicate `TrimOut_Record` enforces, so the dropdown can never offer a rejectable destination); no LOT selected = full line list. New NQ `Location_ListMachiningDestinationsForItem`; property-based tests in `0024/060`. **Machining OUT:** under the merged terminal-mint model the mint is line-resident and its action never read the destination — the vestigial Destination dropdown was Jacques's flagged cleanup and is now **deleted** (nothing to filter).

## Container complete — behavior confirmed against FDS-07-005
Checked FDS. **FDS-07-005 (Container Closure)** — on full, in ONE synchronous local-DB txn: (1) status → COMPLETE, (2) claim next FIFO AIM Shipper ID from `AimShipperIdPool`, (3) store `AimShipperId` on the container, (4) INSERT `ShippingLabel` (`PrintedAt=NULL`, ZPL generated — queued not sent), (5) `Audit.OperationLog`, (6) return `ShippingLabel.Id`. Atomic (never COMPLETE without an AIM id). **Print is async** (`sendRequestAsync('mes','print-shipping-label',{ShippingLabelId})`). FG **LOT auto-closes** in the same txn. `RequiresCompletionConfirm` gates a confirm button per Dedicated terminal. **Empty pool = hard-fail rollback, stays OPEN** (FDS-07-010a / OI-33). Built flow: `Assembly_CompleteTray` **delegates to `Container_Complete`** → matches the FDS.

## Need a way to test Shipping Dock & Receiving
Need a **test path / seed** to exercise the **Shipping Dock** and **Receiving** screens end-to-end (a way to drive complete containers to shipping + inbound receipts). *(Likely a smoke-seed that stages a COMPLETE container with an AIM id + a receiving scenario. Views: `ShippingDock`, `ReceivingDock`. Owed with the Designer smoke.)*

> ✅ **Built (2026-07-09): `sql/scratch/smoke_seed_shipping.sql`** — re-runnable; drives everything through the production procs: stages 6MA-M + PIN-A at the MA2-6MACH line, completes two trays (`Assembly_CompleteTray` auto-opens + fills the container), then `Container_Complete` claims the next FIFO AIM id and mints the ShippingLabel (`PrintedAt` NULL) — **COMPLETE + UNSHIPPED**, ready for the Shipping Dock's Ship action; also puts a fresh RD-BRKT received LOT on the dock (SHIPIN) for the Receiving screen. Guards on a drained AIM pool (the FDS-07-010a hard-fail). Each run consumes one pool id. Verified green (first staged run: container 23, AIM DEVAIM-6MA-003, label 10, dock LOT MESL3000137). *(FDS-07-005 confirmation note above: acknowledged — the built `Assembly_CompleteTray` → `Container_Complete` delegation matches the FDS; no action.)*
