# Task List — Jacques Meeting (2026-07-06)

Derived from `notes/2026-07-06_jacques-meeting.md`. Tags: 🐞 data-integrity bug · ⚙️ validation/gating · 🎨 UI/layout · ✨ enhancement.

> **Recurring theme — "line-resident":** several items point the machining hand-off at the **production line** (WorkCenter), not terminals — Trim OUT destination, Trim checkout move-target, and eligibility tier. Worth doing as one coherent change. This aligns with what's now landing on `main` (OperationType/route-role model).

---

## Die Cast entry
- [x] 🎨 **Add a "refresh mounted tool" button** on the Die Cast terminal page — re-fetch the currently mounted tool without reloading the screen. *(2026-07-06: header Refresh button bumps `view.custom.refreshToken`, which is now an arg on the mounted-tool + shift-tally runScript bindings, so both re-fetch in place. Create/reject also bump it.)*
- [ ] 🎨 **Fix cavity dropdown resize glitch** — the cavity dropdown scales/resizes weirdly when a cavity is selected. *(Needs live repro in Designer — nothing in the view config explains a resize; suspect CSS on `allowCustomOptions` selected-chip. On the smoke list.)*
- [x] ✨ **Prepopulate defaults from the part** — part count defaults to the part's **parts-per-basket**; weight defaults from the part **if it exists**. *(2026-07-06: picking an Item prefills Piece Count from `Item.MaxParts` and Weight as `UnitWeight x MaxParts` + the part's weight UOM — only into EMPTY fields. ⚠️ Weight semantics assumed = computed basket weight; confirm with Jacques.)*
- [ ] 🐞 **"Cavity this shift" dropdown shows too many** — check the query; it's listing more than expected. *(2026-07-06 checked: the query lists every ACTIVE-status cavity configured on the mounted die — by design, so zero-shot cavities are selectable. If Jacques saw extras, either the tool has more Active cavities configured than the die physically has (config/data issue — check Tools → Cavities for that die), or the expectation is "only cavities that ran this shift" — needs his call.)*
- [x] 🐞 **"Shots this shift" is null** — should show a count. *(2026-07-06: the SQL-computed `ShiftShots` value was never bound anywhere — the card only showed per-cavity pieces. Now displayed via `Lot.shiftShotsFromTally`; `shiftTally` is also pre-declared `[]` so first-paint can't error.)*
- [x] ✨ **"Shots this shift" should also reflect scrap** — include/account for scrap. *(2026-07-06: root cause — `RejectEvent_Record` decrements `Lot.PieceCount`, so the tally lost scrapped parts. `Lot_GetShiftCavityTally` v1.1 adds rejected qty back per lot + exposes per-cavity `RejectSum`; card shows a "Scrap this shift (selected cavity)" line. Tested (0022/050, 9/9).)*
- [x] ⚙️ **Verify reject entry is cavity-scoped** — confirm reject entry records in the context of the selected cavity. *(2026-07-06 verified: a reject records against the ACTIVE (last-created) LOT via `activeLotId`; the LOT's immutable `ToolCavityId` provides the cavity attribution. The right-rail "Cavity (this shift)" selection does NOT affect it. The panel now shows "Rejecting against <LOT>" so the target is explicit. ⚠️ If a bad part from cavity 1 is found after a cavity-2 LOT was created, the reject would charge cavity 2's LOT — raise with Jacques whether the reject should target the latest LOT of the SELECTED cavity instead.)*
- [x] 🎨 **Consolidate the three right-side cards into one card.** *(2026-07-06: right rail is now ONE `pf-panel` card with divided sections — cavity selector, shift KPIs (shots incl. scrap / pieces / scrap for selected cavity), reject entry, peer tally.)*
- [x] ⚙️ **Gate: no run without an operation template** — was able to run a part in Die Cast with no operation template; block it. *(2026-07-06: `submitCreate` hard-rejects when `getActiveTemplateIdForRoute(itemId, 'DieCast')` resolves nothing, + a red warning label under the Item dropdown as soon as such a part is picked. ⚠️ Resolution is route-role based (Spec 1 model) — parts whose routes don't yet carry a DieCast-role step will be blocked until their route data is configured. No proc-side gate (Lot_Create is generic across receiving/machining); flag if server-side enforcement is wanted.)*

## Operation templates & Routes
- [x] ⚙️ **Scope the operation-template selection dropdown** — currently not scoped by area. *(2026-07-06: root cause — the Routes draft-step editor was the un-migrated half of the OperationType restructure: its Area dropdown fed a deprecated shim that ignored the area and returned ALL templates. The row now cascades **Operation Type (role) → templates of that role** via `getOperationTemplatesByType`; Area column/labels replaced with Operation Type on both draft and published views. No save-contract change (SaveAll persists only OperationTemplateId per step).)*
- [x] 🐞 **Routes: Data Collection column empty on create screen** — it populates on the published view but not the draft/create view; fix the create-screen binding. *(2026-07-06: draft rows only got the summary from SQL on load — picking a template never resolved it. `broadcastStep` now fills it at pick time via the new `OperationTemplate.getFieldSummary`.)*

## Eligibility & config
- [x] ⚙️ **Eligibility should target Area + Production Line tiers**, and **exclude terminals & printers** from the location list. *(2026-07-06: `Location_ListForEligibilityPicker` v1.1 offers HierarchyLevel 2+3 (Area + WorkCenter) only. Existing Cell-tier eligibility rows still resolve via the cascade but can no longer be authored; migrate dev-data cell rows up to their line. Test 0009/050 gains two tier assertions, suite 242/242.)*
- [x] 🎨 **Printers must not appear in the eligibility location dropdown** (subset of the above — filter Printer-kind). *(2026-07-06: structurally excluded — the whole Cell tier is out.)*
- [x] 🎨 **Terminal selection table: default to 100 rows + add a search bar.** *(2026-07-06: pager `initialOption` 100 (options 25/50/100/200) + a live search field filtering code/name/zone via `Terminal.filterForSelector`.)*

## Trim IN
- [x] ⚙️ **Confirm Trim IN's available cells are terminals, not printers** — verify the location list excludes Printer-kind. *(2026-07-06: verified in code — `Terminal_ListContextCells` excludes `Terminal` + `Printer` kinds, and TrimShared further filters to `Kind = 'Trim Press'`.)*
- [ ] 🐞 **"null" under the Eligible label** on Trim IN — show a value or hide it. *(2026-07-06: every operand under the Eligible label is isNull-guarded, so the literal "null" needs a live repro. One real defect found+fixed in that exact spot: the Capacity line's infinity fallback rendered a raw backslash-u221e escape as literal text instead of an infinity glyph; now ASCII `(no cap)`. Confirm on Designer smoke.)*
- [x] ✨ **Show a Trim inventory** — display what's currently in Trim (on-hand LOTs at the trim area/line). *(2026-07-06: "Currently in Trim" table on the IN panel — open LOTs at the terminal's Trim zone via `Lot_GetWipQueueByLocation`, refreshed on check-in/check-out.)*

## Trim OUT / checkout
- [x] ✨ **Show the Trim inventory + selectable LOT list** on Trim OUT — pick from the queue, while **keeping scan** as an option. *(2026-07-06: the OUT panel now shows the same Trim inventory as a selectable table — tapping a row sets the active LOT; the LTT scan field stays as the alternative.)*
- [x] ⚙️ **Destination = production line, not Machining-IN terminals** — the destination dropdown should list the WorkCenter line. *(2026-07-06: `Location_ListMachiningDestinations` v1.1 returns WorkCenter-tier lines that have a Machining-In cell child (e.g. MA1-COMPBR); the MIN cells/printers are structurally excluded. Test 0024/060 rewritten, 5/5.)*
- [x] ⚙️ **Trim checkout moves the LOT to the production line, not the terminal** (`CurrentLocationId` = line). *(2026-07-06: falls out of the destination change — `TrimOut_Record` moves to whatever id the dropdown supplies, now the line. Bonus: this FIXES a latent mismatch — the dedicated Machining-In terminal reads its FIFO queue at its parent LINE (zone), while Trim OUT used to deposit at the MIN cell, so the queue screen would never have shown the lot. Smoke seed repointed to MA1-COMPBR.)*
- [x] 🎨 **Don't navigate to the LOT summary page on Trim OUT submit** — stay on the screen / return to the queue. *(2026-07-06: success path now clears the OUT form in place; no navigation.)*
- [x] 🐞 **Block double checkout** — was able to check out the same LOT twice from the Trim shop. *(2026-07-06: `TrimOut_Record` now requires `@SourceLocationId` — the terminal's Trim zone — and rejects when the LOT is not at/under it; TrimBody passes `session.custom.terminal.zoneLocationId`.)*
- [x] ⚙️ **Validate shot count against the LOT** — was able to enter a shot count far exceeding the LOT's piece count. *(2026-07-06: proc rejects `ShotCount > Lot.PieceCount`.)*
- [x] ⚙️ **Validate/cap scrap count against the LOT** — same overflow issue for scrap. *(2026-07-06: proc rejects `ScrapCount > Lot.PieceCount`.)*

## LOT Detail
- [x] ✨ **More context per event** — need more than just the terminal/machine name (richer location/context detail). *(2026-07-06: `Lot_GetAttributeHistory` v1.2 — Movement rows now read `Name (CODE) -> Name (CODE) [via <terminal>]`, and two new streams joined the timeline: `Production` (template + terminal + shots/scrap counters) and `Reject` (qty + defect + charge-to). HistoryRow got icons/colors for both.)*
- [x] ✨ **Scrap in LOT Detail** — show scrap recorded in each movement where applicable, and add a **Total Scrap card** at the top. *(2026-07-06: Reject/Production timeline rows carry the scrap per event; new `Lots.Lot_GetScrapSummary` proc + Total Scrap KPI tile in the top strip (red when > 0). TotalScrap = SUM(RejectEvent.Quantity) + MAX(ProductionEvent.ScrapCount) — the two disjoint scrap channels. Tested (0022/060, 7/7).)*
- [x] 🎨 **Round the date** in the LOT Detail history (over-precise timestamp). *(2026-07-06: the offender was the Pauses tab — `PauseRow` rendered raw `toStr(PausedAt)`; now `MM/dd HH:mm`. The main timeline already rounded.)*

## Create LOT popup
- [x] 🎨 **Create LOT popup button spacing** *(2026-07-06: ButtonRow no longer wraps (was wrap+520px so "Confirm & Submit Another" dropped to a second row); popup widened to 640, all three buttons 44px min-height, shrink-proof, 12px gap.)*

## Smoke findings (added during the 2026-07-06 Designer smoke)
- [x] ⚙️ **Routes tab: restructure "Area" to Operation Type** — *(already landed earlier this session as part of the op-template dropdown scoping: role dropdown cascade, headers, and published column all read Operation Type now.)*
- [x] 🐞 **Routes: New Version doesn't switch to the route editor** — *(2026-07-06: the handler selected the new draft id BEFORE reloading the version list; the dropdown (bidi-bound) nulled the unknown value and the onChange reset mode back to view, wiping the primed editor state. Fixed: reload-then-select, plus the onChange now restores a live primed draft selection instead of resetting on a spurious null. Re-smoke to confirm.)*
- [x] 🎨 **Item Master list: per-row scrollbars** — *(2026-07-06: repeater was useDefaultViewHeight:false + basis:auto; now true + pixel basis (45px after Hunter's row-height bump) + overflow:hidden on wrappers/row root; whole-list scroll on the repeater.)*

## Cross-cutting
- [x] 🎨 **Remove all FDS commentary from Perspective views** — no spec/FDS text should be visible on any operator-facing screen. *(2026-07-06: swept every view.json in MPP + MPP_Config — stripped FDS-XX-NNN refs from HoldManagement (incl. the standalone FDS badge label), MachiningOutSplit x2, AssemblyNonSerialized, MovementScan, DieCastBody; also rewrote TrimBody's `v_EffectiveItemLocation` internal-name help text. Script comments (never rendered) intentionally kept. Residual grep over visible text/expression strings: zero hits.)*

---

### Suggested priority
1. **Data-integrity / gating (🐞⚙️):** double checkout, shot/scrap overflow validation, run-without-op-template gate, cavity-this-shift over-listing, shots-this-shift null.
2. **Line-resident cluster (⚙️):** Trim OUT destination = line, Trim checkout move-target = line, eligibility at Area/Line + exclude terminals/printers.
3. **Enhancements (✨):** Trim inventory (IN/OUT), part-count/weight defaults, LOT Detail scrap + context.
4. **UI polish (🎨):** card consolidation, cavity dropdown glitch, refresh button, table rows+search, date rounding, button spacing, FDS-comment removal.
