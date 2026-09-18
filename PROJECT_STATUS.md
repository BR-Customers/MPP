# MPP MES — Project Status

> ## 🚧 OPEN TODO (deferred 2026-07-16) — Converge operation-template execution to ONE SQL methodology
>
> **Problem:** the same concept — *"for this LOT at this step, which OperationTemplate applies, then record its event"* — is implemented **five different ways** across the shop floor (view expression bindings, view Python, a Core-Python recorder, and inside a SQL proc), and two steps skip it entirely. This drift is the root of the string of *"template missing"* bugs (Trim OUT / Machining OUT / Machining IN, all fixed piecemeal 2026-07-16) and is hard to trust/maintain.
>
> **Target:** one SQL resolver `Parts.ufn_OperationTemplateForLotRole(@LotId, @RoleCode)` used by **every** execution proc (each proc knows its own role and resolves internally); Perspective/Python becomes **thin inert glue** (passes `lotId`, renders result — zero domain decisions); keep pre-flight **SQL-read gates** for UX. Matches the existing "no business logic in Python" rule — this is *enforcing* it, not a new direction.
>
> **Design decisions to make first (3 sharp edges):** (1) `ProductionEvent_Record` is generic (serves die-cast shots + Trim-IN) → give it a `@RoleCode` param, or split into per-role procs; (2) `DieCastShot` is a *named template code*, not an OperationType role → keep a legit by-code lookup, or model it as a role; (3) the two Assembly gaps — should `AssemblyIn` record an Advance checkpoint (like MachiningIn)? should `AssemblyOut` validate a ConsumeMint template (like MachiningOut)? (≥1 looks like a latent bug).
>
> **Blast radius:** 3 execution procs rewritten (`TrimOut_Record`, `MachiningOut_Mint`, `ProductionEvent_Record`) + `MachiningIn_RecordPick` aligns + 1 new function + 3 NQs + ~7 views/thin-Python stripped + **~15 SQL test fixtures** (biggest chunk — must build routes, not pass template ids). **Config side untouched.** Behavior risk low (relocating proven logic); mechanical risk moderate (tests).
>
> **How to run it:** SERIALIZE — do it on a quiet `jacques/working` as a clean sweep; it's a *poor* parallel candidate (it rewrites the exact operation procs/views the active session churns → heavy merge conflicts; gateway + `MPP_MES_Dev` are shared singletons). Full inventory + blast-radius detail: **`notes/2026-07-16_operation-template-methodology-inventory.md`**.

> ## 🚧 OPEN TODO (raised 2026-09-17) — AIM integration writes nothing to the Failure Log
>
> MPP asked (2026-09-16) for Failure Log auditing on the AIM stack: every failure row carrying the **Location**, the **LOT** and the metadata. Today nothing in Ignition can write `Audit.FailureLog` at all -- there is no NQ and no Python writer; `Audit.Audit_LogFailure` is the silent proc mutation procs call internally. AIM failures land only in `Audit.InterfaceLog` (and not even there when AIM is disabled / not configured) or the gateway log.
>
> **Decided with Jacques:** log **every failed attempt** (post, timer retry, pool top-up, bad or mismatched reply, AIM disabled / not configured, exceptions), knowing the retry timer writes a row per owed container per tick while AIM is down. `FailureLog` gets real nullable `LocationId` + `LotId` FK columns; everything else (container, AIM serial, endpoint **without the path token**, HTTP status, attempt count, terminal, InterfaceLog id) goes in `AttemptedParameters` JSON. Gateway-timer failures attribute to AppUser 1.
>
> **Shape of the build:** migration (check FailureLog's partition alignment first -- `project_mpp_partition_aligned_pk`); optional `@LocationId`/`@LotId` on `Audit_LogFailure`; a status-row wrapper `Audit.FailureLog_Record` + Core NQ (type `Query`); a never-raising `BlueRidge.Audit.FailureLog.record(...)`; calls from `AimHttp`, `AimPost.postOne`/`retryTick`, `AimPoolGateway.topupTick`, `Container.complete`/`validateCrt`; Location + LOT columns in the Audit Browser. Migration number: `0090`-`0092` are claimed by the OEE and line-inventory specs -- take the next free one and re-check. Full findings, file/line references and the side notes (the `aim-pool-alarm` nobody listens to, the unused hold/release stubs, the synchronous post) are in **`notes/2026-09-17_handoff-aim-failure-log-and-shipping-reprint.md` section 1**. Brainstorm with Jacques before building.

**Last updated:** 2026-09-17 (evening) -- **Assembly OUT: elevated shipping-label reprint (handoff section 2). One new read proc, two new views, a footer bar on both Assembly OUT screens; no migration. Proc tested and on Dev; views scanned; NOT live-verified -- needs a PIN sign-in + a real AD elevation, which the dev gateway cannot do. Not deployed.**

> ### Shipping-label reprint at Assembly OUT (2026-09-17)
>
> Spec: `docs/superpowers/specs/2026-09-17-assembly-out-shipping-label-reprint-design.md`. A **Reprint Shipping Label** button in a new `Footer` bar on `AssemblySerialized` + `AssemblyNonSerialized` opens `Components/PlantFloor/ShippingLabelReprint`: the last 10 labels for containers at or under the cell (one row per container, newest non-void label, via the new `Lots.ShippingLabel_ListRecentByCell`), a free-text reason (printer jam / network error / damaged label / print failed / smudged, stored in the existing `ShippingLabel.PrintReasonCode NVARCHAR(50)`), and a supervisor AD account + password.
>
> - **Elevation is the stateless one-shot form** (`Popups/CrtValidation`), NOT `requireElevation`: the reprint is attributed to the approver and the operator stays signed in. `requireElevation` runs `beginElevatedWindow`, which makes the supervisor the session user for 300 s. Action code `ShippingLabelReprint` reaches `AppUser_AuthenticateAd` and its audit row. **No role gate** -- any active AD-mapped user approves, as for every protected action; Jacques will add AD roles in a week or two.
> - **The reprint now actually prints.** `Shipping.reprintLabel` only inserts the `Initial=0` row; nothing dispatched it, so it waited up to ~5 min for `PrintFailureGateway.sweepTick`. The popup goes through the new `Shipping.reprintAndDispatch`, which dispatches immediately. **The Shipping Dock's own Reprint button still has the delay** -- left alone because section 3 is parked.
> - The Assembly views were edited by `tools/add_assembly_out_reprint_footer.py`: a text splice verified by re-parse (original + exactly one node), not a re-dump -- both files mix escaped and unescaped strings. **Close both views in Designer before re-running it**, and reload them in Designer after pulling.
> - Print-failure toast (`Lots/Container`) now says "Reprint it from Assembly OUT."
> - **Verified:** `082_ShippingLabel_ListRecentByCell` 22/22; the `0029_PlantFloor_Hold_Sort_Shipping_Aim` folder 111/111 (throwaway `MPP_MES_Test_Reprint`); proc applied to Dev and returns the five MA2-59B containers; scan clean, footer renders.
> - **Owed:** live check on a terminal -- open the popup, pick a label, reprint with a real AD account, confirm the new `ShippingLabel` row (`Initial=0`, reason, approver as `PrintedByUserId`), the `ElevationGranted` row naming `ShippingLabelReprint`, and the print. Also confirm the header/footer fit on the real terminal resolution.
> - **Section 3 (remove the Shipping Dock) stays benched** -- it is still the only UI that ships a container or voids a label.
> - **Also `0093_printreasoncode_ascii_name`** (`f6dbd872`): print reason `ReprintDamaged` renamed to ASCII `Reprint - Damaged` -- sqlcmd had stored its em-dash as mojibake. Applied to Dev.
> - **Release handoff: `notes/2026-09-17_prod-release-handoff-assembly-out-reprint.md`.** Two calls for Jacques before any release: (1) HEAD also carries `0090` (OEE, incl. a new downtime refusal) and `0091` (line inventory) with **no release handoff**, and `Deploy-ProdRelease` ships everything at HEAD -- this feature separates cleanly onto a release branch; (2) **`0093` blocks the line-inventory plan's unwritten `0092` if it reaches prod first** (pending below the high-water mark) -- the line-inventory work should take `0094`.

**Last updated:** 2026-09-17 -- **Trim OUT compact layout: scrap tiles wrap, the scrap lists scroll inside their boxes, and the buttons stay visible. Four MPP views, no SQL. Browser-verified and signed off by Jacques; not deployed -- release handoff in `notes/2026-09-17_prod-release-handoff-trim-out-layout.md`.**

> ### Trim OUT layout (2026-09-17)
>
> Commits `272dafc7` (layout), `1d678f36` (container renames), `1fd6ffe8` (manifest signature). Views: `TrimBody`, `TrimEntry/ScrapCodeTile`, `TrimEntry/ScrapLineRow`, `Trim/InventoryRow`.
>
> **Open:**
> - `InventoryRow` is shared with the Inventory Manager and the Receiving Dock screen. It lost its "Position N - oldest" label and shrank to 64 px while those screens keep 92 px slots. Jacques's call before release.
> - With no LOT selected, the Trim OUT helper reads "LOT # selected" (`activeLotId` defaults to `""`). Existing bug.

**Previously (same day):** 2026-09-17 -- **Cutover scan: location-first setup (Warehouse / Blast / Tumble Trim Storage / lines), trim-store default destination, cast-date picker, LTT keeps its prefix, compact layout. Two new repeatables + one changed; no migration. On Dev and browser-verified; not deployed -- release handoff in `notes/2026-09-17_prod-release-handoff-cutover-location-first.md`, to ship bundled with the shot-count release.**

> ### Cutover scan -- location first (2026-09-17)
>
> Commits `a0d32be7` (SQL: `Location_ListCutoverSources`, `Item_ListForCutoverLocation`, `Location_ListCutoverDestinationsForLine` v2.0; tests `0070/080`, `0070/090`, folder 97/97) and `1da26dfb` (Ignition). The Location dropdown opens on Warehouse. A store is its own destination and hides Entry Step + Destination. At a line, the destination defaults to the part's trim store. Warehouse lists every active part (a cutover destination with no eligibility). Setup draft logic lives in `BlueRidge.Cutover.Scan` (`initSetup` / `applySetupChange` / `draftFromSession`).
>
> **Open:**
> - Trim-store labels are a CASE on Code in both procs (Tumble = `TRIM1-STORE`, Blast = `TRIM2-STORE`). Jacques renamed the stores in prod on 2026-09-17; after the Friday 2026-09-18 prod-backup config sync, drop the CASE so Names drive the label.
> - A keyboard-wedge scan would append to the kept LTT prefix; camera scan replaces it. Confirm how operators scan.
> - Add basket not exercised live (harness only).

**Previously (same day):** 2026-09-17 -- **Tools screen: die shot-count correction. New repeatable `Tools.Tool_CorrectShotCount`; no migration. On Dev and screen-verified; not deployed -- release handoff in `notes/2026-09-17_prod-release-handoff-tool-shot-count.md`.**

> ### Die shot-count correction (2026-09-17)
>
> The Config Tool Tools header's read-only **Total Shots** is now an editable **Current Shots** text field so the die manager can enter a die's real lifetime count at cutover and fix a wrong one later. Changing it reveals a mandatory **Shot Count Change Note**. Save runs `Tool_Update`, then `Tools.Tool_CorrectShotCount`, then status. Spec/plan `docs/superpowers/{specs,plans}/2026-09-17-tool-shot-count-correction*`. Commits `0a629690` `ea5756fe` `ffeb7c18`.
>
> **The correction is the shift-reconcile increment, isolated.** It applies `ShotCount + (typed - loaded)` under a row lock (the delta may be negative) and touches nothing else: no `DieCastContribution` row, no watermark, no counter anchor. It refuses the save if a shift output moved the count after the screen loaded. The record is one `Audit.ConfigLog` row -- `<Code> -- <Name> · Shot Count · old -> new · note`, with the full note in `NewValue.Note`.
>
> **Shot Limit was silently clearing on a comma.** It was already a text field, but `int(float("1,000,000"))` failed and `toIntOrNone` returned None, so the save wrote `ShotLimit = NULL`. Both shot fields now load with thousands separators, parse commas and spaces, and **reject** anything else with a message. Helpers `_parseShots` / `_formatShots` / `_metaForEditor` / `_shotEdits` in `BlueRidge.Parts.Tool`, pinned by `ignition/tests/test_tool_shot_inputs.py`.
>
> **Verified:** `0050_ToolShotCount` 63/63 (22 new) on a throwaway DB; the die-cast shot-reading, anchor, release-preview and cavity-scrap files green; pytest 31/31; proc + descriptions applied to Dev; view scanned. The view was edited by `tools/edit_tools_view_shot_count.py` (JSON round-trip that keeps Designer's `=` escapes), not by hand.
>
> **Owed:**
> - **Screen verified 2026-09-17** on `CAV-TEST-DIE`: bad limit rejected, comma'd limit saved, note enforced, correction audited, stale edit refused, unsaved-changes prompt fires. Die restored via the procs afterwards.
> - **Four die-cast test files error in fixture setup** on a fresh test DB (`030`, `040`, `050`, `070` in `0022_PlantFloor_DieCast`): `Tools.ToolAssignment.CellLocationId` resolves NULL. It happens before any code under test runs; not caused by this change, not yet investigated.
> - `MPP_MES_Test` was being reset by another session during this work; tests ran on a throwaway `MPP_MES_Test_ShotFix`, since dropped.
> - **Prod: packaged for a release agent** -- `notes/2026-09-17_prod-release-handoff-tool-shot-count.md` (scope, four risk tests, rehearsal expectations, post-deploy checks). Note the 0089 runbook's Outcome is still unfilled; confirm prod's high-water mark first.

> ## 🚧 OPEN TODO (raised 2026-09-17) — Supervisor Dashboard was never set up properly
>
> `/shop-floor/supervisor` (`Views/ShopFloor/SupervisorDashboard`) is six **KPI tiles with no navigation**: Open Downtime + Classified are wired; Paused LOTs / Shift Availability say "pending"; AIM Pool / Print Failures still say "wired when Phase 7 lands". The die cast supervisor page (`/shop-floor/die-cast/supervisor`) is not reachable from it. The dashboard needs its own design pass as a supervisor **launcher** (tiles that navigate) with the placeholders resolved. Raised while designing the die cast **shift reconciliation** screen (supervisor-only, 2026-09-17), which needs a tile there — that spec adds only the one tile; the rework is separate. Trim shop needs the same reconciliation capability later: `notes/2026-09-17_shift-reconciliation-backfill-trim-followup.md`.

> ## ✅ Line Inventory panel — built on Dev 2026-09-18, not deployed
>
> A 320px right **page dock** (`Components/PlantFloor/LineInventory`) on the six M&A pages (machining-in / -out / machining / assembly-in / -serialized / -nonserialized), each dock passing its own `terminalRole`; the panel takes its location from `session.custom.cell.locationId`. Lists the parts the line **consumes** (`Parts.ItemLocation.IsConsumptionPoint`) plus anything on hand; colours by % of the line's `MaxQuantity` (orange ≤ 30%, red ≤ 10%); held LOTs are not available; bought (PassThrough) parts get a one-tap box check-in (`Item.BoxQuantity`) or a numpad count. **Tolerances** popup sets Max (anyone signed in — see the TODO below). Replaced: the Assembly OUT tray projection + the low-inventory toast (migration `0095`). Spec `docs/superpowers/specs/2026-09-17-line-inventory-sidebar-design.md` (rev 2); plans `docs/superpowers/plans/2026-09-17-line-inventory-sidebar.md` + `-rev2.md`; handoff `notes/2026-09-17_line-inventory-designer-handoff.md`. Migrations `0091` / `0094` / `0095` (**`0092` abandoned** — never write it). Full SQL suite 3836/3836.
>
> **Owed:** (1) a live floor check on a terminal (scope + Line-wide, a Tolerances save recolouring a second terminal, a check-in over Max refused); (2) **MPP data** — a Max per consumption part per line and a Box Quantity per bought part; nothing colours until Max is set, and Max must leave room for a whole box (≈ Box / 0.7); (3) Dev lacks `0088`/`0089`, so bought parts are still typed Component there and no button shows until they are applied (needs `-AllowOutOfOrder`); (4) no prod release handoff yet.

> ## 🚧 OPEN TODO (raised 2026-09-18) — Line Inventory Tolerances popup: add a high-level role when able
>
> `Components/PlantFloor/LineTolerances` (and its editor `LineToleranceEdit`) lets **anyone signed in** set a part's consumption-point `Parts.ItemLocation.MaxQuantity` from a shop-floor terminal (Jacques, 2026-09-17, spec `docs/superpowers/specs/2026-09-17-line-inventory-sidebar-design.md` §3.6). Max is not only the colour scale — it is also `Lots.Lot_Create`'s check-in cap, so a wrong value blocks check-ins. **Add a high-level role when able:** once the AD roles land, gate Save / Clear Max behind a per-action elevation above team lead, using the same role-per-action mechanism planned for the shipping-label reprint (`notes/2026-09-17_handoff-aim-failure-log-and-shipping-reprint.md` §2). Until then it is open by design.

**Last updated:** 2026-09-15 (evening) -- **Defect codes: `999` rename, seed realigned to prod, and die-cast attribution carried in the label. Migrations `0085` + `0086`, neither deployed.**

> ### Defect codes -- what the shop-floor sheets proved (2026-09-15)
>
> Three source documents were read against `MPP_MES_Prod`: the die cast press sheet (**DCFM-0485 v18**), the trim shop sheet (**TSFM-0085 v7**), and an **M&A line production sheet**. A read-only risk query -- `sql/scratch/defectcode_renumber_risk.sql`, six sections, run against prod -- established the blast radius before anything was changed.
>
> **The decisive number: 152 of 155 defect codes have ZERO reject history in prod.** Only `008` Test Part (78 rejects), `DC-999` Warmup (24) and `003` Bent Pin (1) carry any, all Die Cast, and none needed its code changed. `Workorder.RejectEvent.DefectCodeId` is the single FK (verified on prod, not from the repo) and it keys on `Id`, not `Code` -- so a rename moves no event rows. `RejectEvent.ChargeToArea` is NULL on all 103 events.
>
> **Codes are never renumbered.** They exist in systems outside the MES and are honoured as-is. The M&A line sheet's `D/C Rejects` / `M/S Rejects` headings are **attribution, not location** -- the line records all of its own scrap and splits it so a missed upstream audit can be identified. Migration `0086` carries that into the label: every Die-Cast-charged description is prefixed `DC - ` (59 rows). `OperationCategoryId` and `Code` untouched.
>
> **`0085`** renames `DC-999` to `999`, the only code in the table that was not three digits. Pure rename, `Id 154` unchanged.
>
> **Seed `030` now reproduces prod exactly** -- 155 codes each side, verified by set comparison. Its low range moved `100`-`112` to prod's `001`-`015` (with `005 Bent Part (Air Gap)` under Trim, and `015` not `013` -- MPP retires numbers permanently, the gaps are real). Four `0069_Aggregate_Reports` test files and `0022/110_CavityScrap` carried the Dev-era `107` for Test Part and now use `008`. Applied migrations `0067` / `0084` deliberately still say `DC-999` / `107` -- they are the historical record.
>
> **`DieCastBody` shipped to prod with Dev row-Ids pickled into `view.custom.dieWideLines`** (`defectCodeId: 165` / `21`). Prod has no `Id 165`. The prod export confirmed the deployed view is **identical to git HEAD** -- no drift -- so the pickled default is live, and `seedDieWide`'s `if dieWideLines: return` guard means the resolver never fires to correct it. Something at runtime is overwriting it (Warm-up has 24 clean rejects against `Id 154`); the likeliest path is the row's own dropdown via `setDieWideLine`. **Not proven.** The default is now `[]` so resolution is deterministic, and the two lookups are `_byCode("999")` / `_byCode("008")`.
>
> **The How-To text is generated** -- `tools/gen_howto_views.py:338` is the source; editing `DieCastShiftOutputHowTo/view.json` directly would be erased on the next run.
>
> **OPEN -- not fixed, and it was the session's starting question.** The trim shop's laminated sheet lists 36 codes. A Trim OUT terminal can reach **five** of them (`140` `142` `143` `144` `145`), because `Quality.DefectCode_List` filters on `OperationCategoryId` and prod tags only 8 codes Trim. Eleven of the sheet's codes (`100`-`112`) are not in the database in any form; twenty more sit under Die Cast or Machining & Assembly. **Blocked on a schema decision:** `UQ_DefectCode_Code UNIQUE (Code)` is global, but the same code serves more than one department (`133` and `134` appear under both `D/C Rejects` and `M/S Rejects` on one line sheet), so the key has to become `(OperationCategoryId, Code)` before the missing rows can exist. Machine Shop sheet still outstanding.
>
> **Deployment:** `0085` + the `DieCastBody` view edit are **atomic** -- view first and `_byCode("999")` finds nothing; `0085` first and the old view stands on pickled `165`. `0086` is independent. Nothing applied to Dev or Prod; both migrations verified on `MPP_MES_Test` including idempotent re-run.

**Last updated:** 2026-09-15 (early hours) — **Die cast quantity + scrap model: the whole SQL chain and the Ignition backend are built, green and on Dev. `DieCastBody` (Task 8) and the How-To regeneration (Task 10) were in flight at the time of writing.** Design: `docs/superpowers/specs/2026-09-14-diecast-quantity-and-scrap-model-design.md`. Plan: `docs/superpowers/plans/2026-09-14-diecast-quantity-and-scrap-model.md`. See the section immediately below.

> ### Die cast quantity + scrap model — built 2026-09-14/15 (migration `0084`)
>
> **Shipped and green: full suite 3610/3610, exit 0.** Everything below is applied to `MPP_MES_Dev` the way it will go to Prod (apply, verify, re-run for idempotency). Commits: `841aa142` `9e0b5518` `2a0c86ac` `de198846` `cfd1ce0f` `46df9323` `f87fb2a0` `2e8c74c3` `fca9bdda` `8e9c6949` `a3b42c57` `b6dfeba9` `a71ae3cb`.
>
> Die-cast scrap is now a fact about **(Shift, Press, Tool, Cavity, Part)** with the LOT optional: `Workorder.RejectEvent.LotId` is nullable and the row carries its own `ItemId` / `ToolId` / `ToolCavityId` / `ShiftId` / `CellLocationId`. `DieCast_GetShiftOutputBreakdown` v3.0 adds `PriorScrapThisShift` / `DieWideShots` / `IsPending` and nets `ProposedGood` of die-wide; `DieCastShiftOutput_Record` v3.0 takes cavity-keyed lines, fans die-wide scrap across **active cavities** instead of open LOTs, and enforces variance dispositions. `DC-999 Warmup` is added, categorised DieCast, charged to DieCast and flagged non-reject scrap.
>
> **Four defects were found during the build that the plan as written would have shipped. Each was silent.**
>
> 1. **Nothing stamped `DieCastContribution.ToolCavityId`.** `ufn_CavityShotWatermark` v3.0 was specified to read that column, and migration `0084` backfilled history — but neither writer populated it going forward, and the plan never said to. The watermark would have read **0**, crediting a basket **the entire counter reading** as new production. Both writers now stamp it (`DieCastLot_Release` v2.1, `DieCastShiftOutput_Record` v2.2). This is a deliberate deviation from spec § 5.4, which says `DieCastLot_Release` needs no SQL change; it does.
> 2. **The ordinary with-basket scrap write stamped no identity at all** — while the new basketless branch and the die-wide fan-out both did. Since the reject readers now resolve the part from `RejectEvent.ItemId`, **every normal die-cast scrap entry would have shown as `(unassigned part)`** on the Part Matrix Honda reads. *Generalisable lesson: when a column is added and readers are repointed to it, audit **every** writer branch — twice here the new branches were correct and the pre-existing one was the one that mattered.*
> 3. **The release dialog's counted Good and closing scrap reached nothing.** `Popups/DieCastRelease` sent `finalPieceDelta` and `scrapLines`; `DieCastBody`'s `releaseConfirmResult` handler forwarded only `counterReading` and `releaseBasket`'s signature accepted only that — with a cheerful "Basket released" toast either way. The proc has accepted both since v1.1.
> 4. **`Tools.ToolCavity_SaveAll`'s own new fixture poisoned an unrelated suite.** It created an Item described `Cavity SaveAll seed part`; `Parts.Item_Create` writes that into `Audit.ConfigLog`, and `050_ConfigLog_List` asserts a `@DescriptionLike = 'SaveAll'` filter returns exactly one row. `0015_Tools_Cavity` sorts *before* `02_audit_readers`, so the failure surfaced in the audit suite pointing away from its cause.
>
> **Spec § 4.2 is closed, verified by render not by reasoning.** A baseline was captured first (Part Matrix = one part, one page), then two lot-free rejects were written **through the real proc**: one on a mapped cavity (part resolved from `ToolCavity.ItemId`, qty 13) and one on an **unmapped** cavity (`ItemId` NULL, qty 4). The Part Matrix then rendered three pages — `(unassigned part)` 4 rejects, and `12232-6MA -0000` Die Cast 100 good / 13 reject / **11.50%** — and the Transaction Detail showed both with LOT `<N/A>` beside a pre-existing lot-bearing row. Both test rows were deleted from Dev afterwards. So a lot-free row is no longer dropped by an `INNER JOIN` on a NULL key, and a NULL part buckets visibly instead of falling out of the `GROUP BY`.
>
> **Scope note:** only **4 of the 6** reject readers named in the plan actually needed repointing. `Reject_GetPlantSummary`'s `Charged` CTE and `Reject_GetNonRejectScrap` never joined `Lots.Lot` on the reject side and were deliberately left alone rather than edited to satisfy a file list.
>
> **Owed / open:**
> - **`Lots.Lot_GetShiftCavityTally` retirement is deliberately NOT done yet.** It is blocked on Task 8 removing `DieCastBody`'s right rail, which still binds `BlueRidge.Lots.Lot.shiftShotsForTool` / `.shiftGoodForTool`. When retiring it, **do not simply delete Test 2 of `0045_DieCast_Lifecycle/060`** — its two assertions pin real behaviour (*additive scrap not double-counted*); re-point them at `DieCast_GetShiftOutputBreakdown` + `PriorScrapThisShift` if that property is not covered elsewhere.
> - **Live smoke owed** on the release dialog (counted good + one scrap line → check `Lot.PieceCount`, the `DieCastContribution` row and the `RejectEvent`) and on the reconciliation screen. Deliberately not run against shared Dev data.
> - `ScrapLineRow` broadcasts page-scoped keyed on **`lotId` alone**, so a scrap row entered in the release dialog can be picked up by a same-lot `CavityLotRow` on the always-mounted shift-output tab.
> - `BlueRidge/Workorder/DieCast/code.py` carries **seven pre-existing bare `except Exception` guards** (~167, 254, 337, 354, 633, 638, 882) that miss Java exceptions in Jython — beside a comment at line 19 that already warns about exactly this. Worth a dedicated sweep.
> - The **−15% type scale** (`a71ae3cb`) only reaches screens through the ~62 CSS classes that consume `var(--mpp-fs-*)`. It does **not** reach **466 hard-coded `fontSize` props across 117 MPP view files**; 102 of those sit at 18/20/22px, now above the new `base` (17) and `md` (19). Concentrated in `GlobalTrace` (54), `LotDetail` (39), `Reports` (25).
>
> **`die_cast_supervisor_source()` was deliberately left alone, and it is not an oversight.** It documents `Views/ShopFloor/DieCastSupervisor`, a separate read-only dashboard this redesign does not touch. More to the point, it belongs to a **different initiative from earlier the same week: a How-To guide per area, aimed at the area supervisor so they can better equip their team** — not at the operator at the terminal. That initiative is **not a priority right now** (Jacques, 2026-09-15). The plan's Task 10 lists it among "the four die-cast How-To sources" to rewrite; rewriting it would have been wrong on both counts.
>
> **Test-runner trap worth knowing:** running `-Filter "0022_PlantFloor_DieCast"` alone makes four files (030/040/050/070) error with *"Cannot insert the value NULL into column 'CellLocationId', table 'Tools.ToolAssignment'"*. Those fixtures need a Cell with a Direct item eligibility and no live `ToolAssignment`, which **earlier suites create** — the full suite runs them clean. It is a filter artifact; do not chase it. Related: a test file that errors never runs its teardown, so its fixtures survive and break whatever suite runs next, looking unrelated. The tell-tale is the total assertion count failing to rise when assertions were added.

**Last updated:** 2026-09-13 (evening) — **Inventory cutover scan: the dropped-write bug is FIXED and verified live. Cavity tiles, both cast-date arrows, the tab strip, Change, and all three mobile-header buttons work. Mobile CAMERA barcode scanning is wired and routed (Phone + Tablet), and `resetTerminal`'s dead-route landing is fixed.** Design: `docs/superpowers/specs/2026-09-12-inventory-cutover-scan-design.md`. Plan: `docs/superpowers/plans/2026-09-12-inventory-cutover-scan.md`.

> ### The bug that made every control inert — ROOT CAUSE, and the wrong theory it replaces
>
> **`BlueRidge.Cutover.Scan.getState()` handed back LIVE property-tree views, not detached Python.**
> `session.custom.cutover` reads back as a `com.inductiveautomation.perspective.gateway.script.PropertyTreeScriptWrapper$ObjectWrapper` — a live view into the session's property document. It quacks enough like a dict (`.get` / `.keys` / `.items` / `[k]`) that `getState`'s `for k, v in st.items(): out[k] = v` looked correct and was not: every nested value copied out was still a live view. So
> ```
> st = getState(session)          # st["entry"] is a LIVE wrapper
> st["entry"]["castDate"] = nxt   # mutates the live tree (queued)
> session.custom.cutover = st     # replaces the tree with a snapshot rebuilt
>                                 # from those same wrappers -> clobbers it
> ```
> **`extractQualifiedValues` does NOT cover this** — it only recurses into a Python `dict` / `list` / `tuple`, and `isinstance(wrapper, dict)` is `False` (verified live).
>
> **Fix:** `_plain()` in `BlueRidge/Cutover/Scan/code.py` — a duck-typed deep detach (`.items()` ⇒ mapping, iterable ⇒ sequence, anything else ⇒ leaf), applied in `getState`. Read its docstring; it carries the whole mechanism.
>
> **Why not the JSON round-trip** that `BlueRidge.Lots.LotTrail._plain` uses for the same hazard: `entry.castDate` is a `java.util.Date`, and a JSON round-trip returns it as a string, which then fails `Lot_Create`'s `:castDate` (`sqlType` 8, DateTime).
>
> **The `java.util.Date` theory recorded here previously was WRONG.** A `Date` round-trips through a session custom prop correctly — `WROTE Sat Sep 12 … ; READBACK Sat Sep 12 … ; match=True`, verified live. It looked like the culprit only because `loadSession` was the one write that worked, and it is also the one write that never mutates nested state (it *replaces* whole keys with fresh literals: `st["session"] = {...}`, `st["rows"] = []`). That asymmetry had nothing to do with dates.
>
> **How it was found (the technique, not the guess):** instrument at the boundary and read `logs/wrapper.log` directly — `type(raw)`, `isinstance(raw, dict)`, `u.items()`, and a direct `session.custom.cutover.entry.castDate` readback. One tap printed the wrapper class name and settled it. Driving the session from the in-app browser + tailing `wrapper.log` is a ~20-second feedback loop; use it instead of reasoning about Perspective internals.
>
> **Verified live on the real screen, 2026-09-13:** cavity tile taps latch (`toolCavityId: 38, cavityCode: 'a'` read back); the back arrow steps Sep 12 → Sep 11 → Sep 10 with `match=True` on every write and the label re-rendering each time; the Cast/Purchased tab strip switches; **Change** re-opens setup pre-populated from the latched session; **Downtime** opens `popup-mpp-downtime-manager`; **Supervisor** opens `popup-mpp-elevation-modal`; **Reset** clears the operator, navigates, and re-prompts for a PIN. All instrumentation has been removed.

> ### Cutover scan — what is still NOT exercised
>
> - ~~No basket has been written end to end.~~ **DONE, on a real phone (2026-09-13 23:17 ET).** LOT `10627577` in Dev: part `12231-6MA -0000`, 2016 pcs, `CastDate 2026-09-10`, `EntryRouteSequence 4`, die `6MA-B` cavity `b`, and its **next pending step is `MachiningIn`** — i.e. it surfaces in the Machining IN queue instead of falling into Trim, which is the entire point of `EntryRouteSequence`. Every part of the chain (`_plain`, the cavity write, the date stepper, `Lot_Create`) is confirmed on real hardware. **Still unexercised: `addBox` (purchased) and `voidEntry`.**
> - **Camera scanning works on a real phone** (Perspective App, 2026-09-13). The scan action now sits on its own button beside each field so a damaged barcode can still be hand-typed. **Still unexercised: a basket written end to end** -- the first real attempt hit the two defects above; both are fixed and `Lot_Create` is proven from SQL, but nobody has yet tapped Add basket successfully.
> - **The phone header now collapses** (default collapsed; the always-visible label shows the PART NUMBER, and the Part/Die/Machine row is forced open when the die is ambiguous because the die dropdown lives in it). The tablet and desktop were left alone.
> - **The PIN keypad is clipped on a phone** — `1/4/7/Clear` and `3/6/9/Back` fall off 375px. An operator cannot sign in on a phone. Still blocking for handheld use.
> - Spec section 11 open questions: where warehouse-held stock lands, and whether already-machined SubAssembly stock needs its own handling.

> ### Camera barcode scanning (2026-09-13, Jacques + Claude)
>
> **Mobile camera scanning works, and the mechanism is not what the component list suggests.**
>
> **`ia.input.barcodescannerinput` is NOT a camera** — it is a keyboard-wedge listener, and it was removed from this screen. Read out of the 8.3.5 client bundle: `captureMode` (default `"keypress"`) is passed straight to `document.addEventListener(captureMode, …)`, and its handler factory returns **null** unless `prefix`+`suffix` or `regex` is set — so with the default props it silently captures nothing, forever. Its `props.data` is also **append-only** (`props.write("data", data.concat(scanned))`), so a `props.data[0]` binding sees only the *first* scan ever. Use it only with a hardware/Bluetooth wedge scanner, and only with a prefix+suffix pair or a regex.
>
> **The camera is a native ACTION, App-only.** A component carries an event action of type **`native/barcode`** (config: `cameraPreference`, `type`, `backgroundColor`, `uuid`). Firing it calls `window.__mobileInterface.launchAction(...)`, a bridge that exists **only inside the Ignition Perspective App**. In a plain mobile browser the client logs *"Native mobile action requested in non-mobile client. Action request ignored!"* and nothing happens. Operators therefore need the **Perspective App**, not Safari/Chrome. (Sibling native actions, same bridge: `native/picture`, `native/geolocation`, `native/deviceId`, `native/ndef`, `native/bluetooth`, `native/accelerometer`.)
>
> **A scan does not return to the component that asked for it.** Perspective fires ONE project-wide session event, `MPP/com.inductiveautomation.perspective/barcode/onBarcodeDataReceived.py`, for every scan in the app:
> ```
> data    = {"barcodeType": "qrcode", "text": "<payload>", "timestamp": 1789351139952}
> context = the action's own "context" object, echoed back verbatim
> ```
> **`context` is the only routing key there is.** So every `native/barcode` action SHALL carry `{"screen": "<screen>", "field": "<field>"}`. The session event is a one-liner into **`BlueRidge.Common.Barcode.onScan`**, which dispatches per screen; `BlueRidge.Cutover.Scan.applyScan` writes the value into the right slot of `session.custom.cutover`. An action with **no context is logged and dropped on purpose** — writing a stray scan into whatever field was last touched is worse than ignoring it.
>
> Wired: **Phone + Tablet** — LTT field → `entry.lotName`, purchased part-number field → `purchased.partNumber`. **Desktop deliberately has neither** component nor action; because the three size views are separate files, "hide the scanner on desktop" needs no binding at all.
>
> **This is also why the `_plain` fix was load-bearing.** `applyScan` is a read-modify-write of nested session state — the exact shape that silently lost every write before `getState()` started detaching the property tree.
>
> **Test a scan without a phone.** The client exposes the simulate path; run this in the browser console of a live session and watch `wrapper.log`:
> ```js
> window.__webInterface.submitData({type: 'native/barcode',
>   data: {barcodeType: 'code128', text: 'LTT-TEST-0001', timestamp: Date.now()},
>   context: {screen: 'cutover', field: 'lotName'}});
> ```
> Verified 2026-09-13 — `lotName`, `purchasedPartNumber`, and the no-context drop path all behaved correctly.
>
> **Open UX question:** the `native/barcode` action currently sits on the text field's own `dom.onClick`, so tapping the field opens the camera — which means an operator **cannot type a damaged barcode by hand**. Either move the action to a dedicated scan button beside the field, or keep tap-to-scan and add a separate manual-entry affordance. Not decided.

> ### Found in passing (pre-existing, outside the cutover screen)
>
> **FIXED — `Common.Session.resetTerminal` navigated to a dead route.** Its fallback was `navigate("/shop-floor")`, which is not a route in MPP's `page-config`, so an unregistered / fallback terminal landed on *"View Not Found"* after **Reset** (reproduced live). A fallback terminal's `defaultScreen` is `""` (`Terminal.applyToSession` sets it so when `terminalLocationId` is None), so that dead route was exactly what it hit. Destination now resolves through `Common.Session._resetDestination()`, which mirrors **HomeRouter's** existing landing rule — no terminal or `isFallback` → `/shop-floor/terminal-selector`; a registered terminal → its own `DefaultScreen`. One rule, two callers.
>
> **The live-wrapper hazard was audited across the rest of the codebase and is clean.** `BlueRidge.Lots.LotTrail._plain` already solves it (JSON round-trip, and its docstring names the hazard); `Common.Notify._readInstances` only filters elements out of the list and never mutates one, so it is safe; every other `session.custom.*` write in `Core` assigns a fresh literal. Cutover was the only module that read-modify-wrote nested session state without detaching first.
>
> **FIXED — flex shrink/collide defects in all three `_CutoverScan` views.** `CastEntryPanel` / `PurchasedEntryPanel` are flex columns whose children all carried `position.shrink: 0` **except** the trailing note + Add button; a flex child defaults to `shrink: 1`, so those two were the only ones squeezed when content exceeded the panel — down to near-zero height with their text overflowing onto the field above (the "Vendor lot overlaps the paragraph" symptom). And in `LatchedTop`, the line name and the step pill both defaulted to `shrink: 1` **and** `min-width: auto`, which refuses to shrink below content — so they collided instead of truncating. Line name now gets `min-width: 0` + ellipsis; pill and Change button get `shrink: 0`. Same class as the SetupPanel and header-column fixes banked 2026-09-12.
>
> **Editing these view files programmatically:** Phone is authored in Designer's escaped form (`=` / `'`), Tablet and Desktop in the plain form, and Phone alone has no trailing newline. A scripted edit MUST detect and preserve each file's own shape, or a four-line fix reformats two thousand. `scratchpad/viewio.py` in that session did this by rendering both ways and keeping whichever reproduced the file byte-for-byte, asserting that on all three before writing anything.

> ### Add basket failed silently -- TWO defects, both fixed (2026-09-13, real phone)
>
> **1. The Dev database was behind on migrations.** `Lots.Lot_Create` raised `Invalid object name 'Lots.ufn_CrtForMint'`. `MPP_MES_Dev` had **77 of 80** versioned migrations applied: **0064_crt_part_scoped, 0065_crt_label_mark_token and 0066_crt_banner_label were never applied**, even though 0067-0080 were. So `Parts.Item.CrtEnabled` and `Location.LocationTypeDefinition.IsProductionDestination` did not exist, the three repeatables that read them could not compile (`Lots.ufn_CrtForMint`, `Lots.ufn_CrtBlocksAdvance` / `ufn_CrtBlocksMoveTo`, `Lots.ContainerSerial_Get` were all absent), and any mint path blew up at runtime.
>
> Applied 0064-0066 then the three repeatables; all four objects now resolve and `Lot_Create` was proven with the real cutover parameters inside a transaction (`Status=1`, LOT count 67 -> 68 -> 67 on rollback, nothing left behind).
>
> **`sqlcmd` needs `-I`.** The first attempt failed with `Msg 1934 ... QUOTED_IDENTIFIER`, because sqlcmd defaults that OFF and the schema has filtered indexes. Every script in `sql/scripts/` already passes `-b -I -C`; a hand-run `sqlcmd` must too. Nothing partial was recorded -- the migrations guard their `SchemaVersion` insert.
>
> **Worth a standing check.** A dev DB can sit mid-sequence indefinitely and nothing says so until a proc fails at runtime. The diff that found it is two lines: `SELECT MigrationId FROM dbo.SchemaVersion` against `ls sql/migrations/versioned/*.sql`. Anything CRT-related has therefore never actually run on this Dev database.
>
> **2. The exception reached the operator as nothing at all.** The view does `res = ...addBasket(...)` then `notifyResult(res, ...)`. When `addBasket` RAISES, the gateway event script dies on the spot and `notifyResult` never runs -- no toast, no error, the button simply does nothing, and the only evidence is a stack trace in `wrapper.log`. `loadSession` / `addBasket` / `addBox` / `voidEntry` now carry a `@_guard` decorator that converts an unexpected exception into the `{Status: 0, Message}` row every caller already renders. Business-rule failures were already Status-0 and are unaffected.

> ### Stock locations -- `Lot_Create` no longer demands eligibility at storage (0081)
>
> Counting stock in at the **warehouse** or a **trim store** was impossible: `Lot_Create` gates `@CurrentLocationId` on `Parts.v_EffectiveItemLocation`, eligibility answers *"may this part be WORKED here"*, and storage locations carry no eligibility rows at all -- nor does the Site tier -- so **every** part read as *"Item is not eligible at the specified location"* at `WHSE`. Die cast had already hit this and dodged it locally: its `@DepositToStorage` move is explicitly non-eligibility-gated, commented *"warehouse is storage, not a production location"*.
>
> **Migration `0081`** adds `Location.LocationTypeDefinition.IsStockLocation` (BIT, default 0), set 1 for `InventoryLocation`, `SupportArea`, `InspectionStation`, `InspectionLine` (inspection included deliberately -- quarantined material rests there). `Lots.Lot_Create` **v1.5** skips the eligibility gate when the destination is a stock location. Production destinations are untouched and still reject.
>
> **A dead end worth not repeating: `IsProductionDestination` (0064) is NOT the right flag**, even though `Lots.Lot_MoveTo` gates on it and reusing it looks like good consistency. 0064 added that column `DEFAULT 0` and set 1 for only seven definitions, so "non-production" ALSO covers `Organization`, `Facility`, `Printer`, `Scale` and `Terminal` -- gating `Lot_Create` on it permits a LOT at the **enterprise root**. That is not theoretical: it was caught by `0020_PlantFloor_Foundation/040_Lot_Create.sql [LcIneligible]`, which picks the lowest-Id ineligible location (`MPP-ENT`, Id 1). `Lot_MoveTo` can use the flag because its question is *"may a CRT LOT move to quarantine"*, where permissive toward inspection/inventory/support IS the intent. Same flag, different question.
>
> **Verified.** Full suite **3489/3489** both before the change (clean baseline, so any failure is unambiguously the change) and after, with `0081` applied in sequence. Behaviour on Dev, all rolled back:
>
> | Destination | Expected | Actual |
> |---|---|---|
> | Warehouse (`SupportArea`) | create | create |
> | Trim store (`InventoryLocation`) | create | create |
> | Trim shop area (production, part eligible) | create | create |
> | M&A line, part not eligible | REJECT | REJECT |
> | Enterprise root | REJECT | REJECT |
> | Printer | REJECT | REJECT |
>
> **Method note.** The first attempt was validated by hand-picking three destinations on Dev -- all three passed, and it looked like confirmation. It only tested the locations already in mind; the suite tested the one that was not. Hand-checks confirm what you thought of; the suite catches what you did not.

> ### Gateway logging: traces are OFF by default (2026-09-13)
>
> `BlueRidge.Common.Util.log()`'s default level is now **`debug`**, not `info`. There were ~430 call sites across ~75 modules, nearly all function-entry traces, and at INFO they buried the gateway log so deeply that a real fault was hard to find.
>
> **To see a module's traces again:** Gateway -> **Status -> Diagnostics -> Logs**, set that module's logger (e.g. `BlueRidge.Lots.Lot`) to DEBUG. Per-module, no redeploy, no code change.
>
> **A bare `log()` is now invisible in normal operation, so anything that must be seen says so explicitly.** Classification was done by AST, not by grepping the message text (which is unreliable both ways -- "failed" appears in harmless traces, and real faults often never say it); the structural question is *is this call inside an `except` handler?*
>
> | bucket | count | level |
> |---|---|---|
> | already passed `level=` | 69 | unchanged |
> | inside `except`, no level | 90 | promoted to `warn` |
> | misconfiguration diagnostics outside `except` | 5 | promoted to `warn` |
> | plain function traces | 264 | `debug` (silent) |
>
> Post-sweep the audit reports **zero** `except`-block calls left at default level. Verified live: a successful routed barcode scan now emits **nothing**, while a mis-configured one still raises a `W` line.
>
> **Deliberately left at `debug`:** `Oee.DowntimePlc.tickWatcher`'s "PLC DowntimeSourceCode not found" — `DowntimePlcWatcher` runs every 5 s, so promoting it would trade one kind of log spam for another.
>
> Also removed: the three leftover `system.perspective.print` debug calls in **MPP_Config** (`DieRanks`, `LocationTypeEditor`, `ItemMaster`). The other 94 hits live in `Refrence project/Spinner`, a reference project that is not deployed — left alone.
>
> Re-run the audit any time with the AST classifier pattern in `ignition-context-pack/03_script_python.md` § "Log entry and exit of every public function".

> ### Dead ends already burned — do not re-walk these
>
> (1) `Could not find the web session` on route `/hello/:project_name/:tab_id` is Perspective's own tab-attach handshake, not a component failing; it was stale background tabs. (2) `Unable to find registered component for id="ia.display.inline-frame"` at startup is pre-existing, belongs to `AssemblySerialized` / `AssemblyNonSerialized`, fires about 10 s into boot before the component registry finishes, and those vision frames render fine. (3) The event JSON is byte-identical to the working `MachiningIn` Refresh button — scope `G`, `component.onActionPerformed`, tab-indented script. (4) DOM probes run without a session started report `{0,0,0,0}` for everything, because a `display:none` subtree reports zero boxes at the origin — that is not a collapse. (5) **Screenshots of the in-app browser go stale while its pane is hidden** — a frozen frame showed SetupPanel and MainPanel rendering simultaneously, which is not real (`getComputedStyle` confirmed SetupPanel was `display: none`). Confirm layout from the DOM, not from a screenshot taken after the pane was backgrounded.

> ### What IS built and verified
>
> **SQL — all green, full suite on `MPP_MES_Test` 3451/3451.**
> - **Phase A (behaviour-neutral):** `Lots.ufn_NextPendingRouteStep` extracted from **seven** copy-pasted pending-step CTEs across five procs (`Lot_GetWipQueueByLocation`, `Lot_GetComponentsAtCell`, `Lot_GetTrimStorageQueueForLine`, `Lot_MoveToValidated`, and three inside `MachiningOut_Mint`, where drift between the copies produces wrong QUANTITIES rather than an error). Proven neutral by diffing the full suite before and after, line by line — identical.
> - **Migration `0080`:** `Lots.Lot.EntryRouteSequence`, `Lots.Lot.CastDate`, `Location.Location.DefaultStockLocationId`. All nullable, no backfill, metadata-only ALTERs.
> - `CastDate` lives on `Lots.Lot`, **not** a backdated `LotMovement.MovedAt`: that table is partitioned on `MovedAt` under sliding-window `TRUNCATE` retention, so a backdated row lands in a partition maintenance is designed to sweep, and the LOT's FIFO position would change silently.
> - **`Item.MaxLotSize` is now INFORMATIONAL** (Jacques's call): an over-size basket creates successfully with a note appended to `Message`. `Item.MaxParts` and the consumption-point `ItemLocation.MaxQuantity` still reject — they cap what may accumulate at a location, which is a real physical constraint.
> - Readiness check `sql/scratch/2026-09-12_cutover_readiness_check.sql`, verified read-only against Dev.
>
> **Ignition — renders and functions (see the root-cause block above).** Breakpoint host plus Phone/Tablet/Desktop views, the `BlueRidge.Cutover.Scan` module, named queries and wrappers, reachable from the Terminal Selector, and `AppHeaderSmall` completing the breakpoint header shell Jacques scaffolded.

> ### Corrections banked this session (each was a real defect)
>
> - **`session.custom.cutover` was declared in CORE.** MPP defines its own `session-props` resource, which overrides the parent rather than merging — so the prop was undeclared for every MPP session while all three views bound nested paths into it. Moved to MPP.
> - **`getState()` could never read state.** It called `system.perspective.getSessionInfo()["custom"]`, but that returns a LIST of every session on the gateway; it threw `list indices must be integers` on every call and the never-throw guard swallowed it. Now reads through the session object. **`CavityToggle` still called the no-arg form**, so tapping a cavity read the empty shape and wrote it straight back, wiping the whole session.
> - **The top dock had `content: "auto"`** (not a documented value — push / cover are). The page body started 24px above the dock's bottom edge, so the first 24px of EVERY shop-floor screen rendered underneath the header; on desktop each view's own title bar hid it. Set to `push`.
> - **The PART dropdown passed `@OperationTypeCode`**, hiding four eligible parts at `6ma-CH-L2` including both dowel pins — the entire purchased-part flow was unreachable from the picker. Eligibility alone now (`v_EffectiveItemLocation` plus the ancestor cascade). `loadSession` no longer hard-fails when a part has no step for the entry role: `EntryRouteSequence` is castings-only (spec 3.4).
> - **"Casting" is a ROLE, not an `ItemType`** — there is no such item type (`RawMaterial` / `Component` / `SubAssembly` / `FinishedGood` / `PassThrough`); a casting is a `Component`. Filtering by it matched nothing and made two readiness-check sections silently vacuous. Now identified by an `OriginMint` DieCast route step, which immediately found 6 castings at `MA1-5GOF` with no cavities configured.
> - **Measurement correction:** the earlier "13 of 14 parts map to one die, 1 part on 6 dies" was wrong — the 6-die bucket was `ItemId IS NULL` (unmapped cavities). All 13 mapped parts resolve to exactly one die.
> - Flex fixes: `SetupPanel` shrinking below its content and clipping its own heading; header columns overlapping instead of truncating (`min-width: 0`); cavity and session-row scrollbars (the `overflow: auto` default); toasts 500px wide on a 390px phone (now device-aware, with chars-per-line scaled — otherwise the height estimate under-reads and the message is clipped).

> ### Known gaps, not started
> Superseded by “Cutover scan — what is still NOT exercised” above; that list is the current one.

**Previously:** 2026-09-11 (late afternoon) — **6MA CH camera: the SlcTray handshake was built on the wrong PLC program. New `SlcPassPulse` protocol, a `DisableWriteback` UDT switch, and a per-terminal `SuppressAimAndLabel` (migration `0079`) for the parallel run beside legacy.** Detail: `notes/2026-09-11_6ma-ch-real-ladder-slcpasspulse.md`.
> **What happened.** `6MA_CH` ran all night with live tags and the MES booked nothing. MPP supplied the real program (`reference/6MA_PLC Logic`, processor "6MA", PLC `172.17.21.213`). It is **not** MPPMACH (PLC `172.17.20.30`, whose vision IP is RPY Line 2's), which `SlcTray` had been built from on a data-file-layout match. Confirmed live: device IP `.213`, `C5:10.PRE` = 48. On the 6MA ladder, N7:0 is 1 constantly (no per-tray edge), N7:1 does not gate the camera (the PLC runs the cell by itself), N7:30 is set and cleared in the same scan (unobservable), N7:11..27 are never written. The only per-tray host signal is **N7:10** "PASSED TO HOST COMPUTER": 1 for 2-3 s on each good tray. The per-part N17 words are filled from the discrete pass input, so this cell is tray-level only.
> **Fix (Core `TrayInspectionWatcher`; `SlcTray` left as MPPMACH's, probably `RPY_CH`).** Protocol **`SlcPassPulse`**: `TrayLocked` → I:0.0/0 (tray present) syncs N7:2 to `Item.PlcId` if it differs. `InspectionComplete` → **N7:10** books the ByVision tray **only if** `VisionPartNumber` → **N16:2** (the program vision is actually running) equals `PlcId`. Otherwise it is a master tray / rabbit test / override: not booked, warning toast. **`DisableWriteback`** (new Boolean memory member on `TrayInspectionStation`) makes any tray protocol observe-only: it reads and books, writes nothing to the PLC, and logs each suppressed write. **Migration `0079`** + **`Lots.Container_Complete` v1.2**: terminal attribute `SuppressAimAndLabel` (BIT); when it is set, the box completes and its FG LOTs close, but with no AIM claim, no pool check and no `ShippingLabel`. `Assembly.completeBoxToPrinter` returns cleanly on the NULL label. New tool `reference/scripts/decode_rslogix500_rss.py` decodes any RSLogix 500 `.RSS` without RSLogix. Get and decode the `.RSS` before wiring the next cam-holder cell.
> **Verification.** SQL `0028/055` (13 assertions: suppressed + empty pool completes; suppressed leaves a pool row unconsumed; attribute 0 = the normal claim + label) red → green; full suite on `MPP_MES_Test` **3444/3444**. Applied to Dev (`0079` + proc) and scanned. Offline Python harnesses: every SlcPassPulse branch, DisableWriteback across all three protocols, and Container.complete / completeBoxToPrinter with suppressed vs normal results. **Not yet run against the PLC.**
> **Prod SQL live 2026-09-12 14:49 ET** — `MPP_MES_Prod` at `0079` (`0078` + `0079`, 3 procs; backup `MPP_MES_Prod_pre-release_0077_20260912_144959.bak`, committed in 2.9 s, all 3 procs byte-identical). Runbook + outcome: `notes/2026-09-11_prod-release-runbook-6ma-parallel-run.md`. **Still owed: the two Ignition imports and the arming steps (3)-(4) below.**
> **Prod, in order.** (1) `Deploy-ProdRelease`: migration `0079` + `R__Lots_Container_Complete` v1.2. (2) Core export: `Workorder/TrayInspectionWatcher`, `Workorder/PlcWatcher`, `Workorder/Assembly`. (3) Gateway, `TrayInspectionStation` UDT: add `DisableWriteback` (Boolean memory). On `6MA_CH`: `Protocol=SlcPassPulse`, `DisableWriteback=true`, `TrayLocked`→I:0.0/0, `InspectionComplete`→N7:10, `VisionPartNumber`→N16:2. (4) Config Tool: tick `SuppressAimAndLabel` on `MA2-6MACH-AOUT3`. Untick both at cutover.
> **Open.** Failed trays are invisible to the MES on this ladder. A rabbit test run on the production program would book. Possible pre-existing **double label dispatch** on the operator "Complete (box)" path (`Container.complete` dispatches, then `completeBoxToPrinter` dispatches the same label again): spun off as a separate task, unverified.

**Previously:** 2026-09-11 (afternoon) — **Open boxes belong to a station (migration `0078`): METTs A and B can run the same part numbers at once, and each can switch between part boxes.**
> **The problem.** Line `MA2-6MACH` has three assembly-out terminals, each with its own printer: METTs A (`AOUT1`) and METTs B (`AOUT2`), both ByCount, and the vision cell (`AOUT3`). METTs and vision never run together, but **both METTs stations run the same part numbers at the same time into separate boxes**. Boxes were keyed (line, part): both stations' trays of one part landed in one container, under one AIM serial and one label. And with one printer per terminal the printer cards never switch on, so the ByCount screen showed and filled **the oldest open box on the line** and ignored the part dropdown: no switching parts until that box was full and shipped, and METTs B's parts could be booked into METTs A's box under the wrong part number.
> **The fix.** `Lots.Container.StationLocationId` (nullable FK, the owning terminal) + filtered index. `Workorder.Assembly_CompleteTray` v1.4: a tray goes to this station's open box for (line, part), else **claims** an unowned one (every pre-`0078` box, so nothing is stranded at deploy), else opens one owned by the station. The full-box guard uses the same resolution. A NULL/non-Terminal `@TerminalLocationId` keeps the old line-wide rule. `Lots.Container_GetOpenByCell` v1.1: optional `@StationLocationId` (own + unowned) and `@ClosureMethod` filters, plus `StationLocationId`/`StationCode`; the unfiltered call is unchanged. New Core NQ `lots/Container_ListOpenForStation`. **Screen (`AssemblyNonSerialized`, 4 one-line text edits + 1 new label):** the part dropdown drives the box (`Assembly.getStationContainerRows`); an "Open boxes:" line lists this station's boxes with their fill (`getStationOpenBoxesText`); on load it pre-selects the part of this station's oldest open box, else the recommended part (`getDefaultFinishedGoodId`); **Complete Tray and Complete now pass the terminal, not the line.** That also fixes, for this screen, the stamping found this morning (ShippingLabel/CRT/audit carried the line). **Camera line:** `resolvePlcCloseContext` reads only this terminal's ByVision boxes, and with none takes the top-ranked finished good that *has* a ByVision pack-out (a one-line METTs BOM could otherwise outrank the set). **Printer cards:** fill display and the box they complete use the same station-aware read.
> **Verification.** New `0028/098` (23 assertions: two stations/same part = two boxes, switching parts, per-station full guard, claim of an unowned box, non-terminal caller stays line-wide, read filters) red → green; full suite on `MPP_MES_Test` **3431/3431**. Jython harness 26/26 for the Python (box selection, part switching, terminal pass-through, camera part pick). Everything compiles under Ignition's Jython. Applied to Dev (`0078` + 2 procs) and scanned clean. **Not rendered:** the local gateway's Perspective trial has expired, so the screen could not be opened here.
> **Data MPP still owes for METTs** (none of it exists in Dev): the METTs finished goods `12231…12235-6MAA-J000` / `12241…12245-6MAA-J000` from the Macola workbook (6MA sheet; codes `652…661-MET`), each a FinishedGood eligible at `MA2-6MACH` with a published one-line BOM (its `-6MA -0000` casting × 1) and a ByCount pack-out. The workbook lists 10; Jacques says 12, so two are unidentified.
> **Prod:** the branch also carries Jacques's `0077` downtime repair (`5159c5af`), so `Deploy-ProdRelease` will show `0077` + `0078` + four procs. Ignition export for this change only: Core (NQ + `Workorder/Assembly`, `Lots/Container`, `Location/PrinterFgAssignment`) + MPP (`AssemblyNonSerialized`). **SQL first, then Core, then MPP**: the new NQ calls the v1.1 proc parameters.

**Previously:** 2026-09-11 (morning) — **Downtime popup fixed and released to prod: `MPP_MES_Prod` at `0077` (09:53 ET), popups imported.** So a `Deploy-ProdRelease` for `0078` now shows `0078` + its procs only — `0077` is already live.
> **Symptom:** die cast downtime "not showing". Diagnosed on prod with `sql/scratch/2026-09-11_downtime_popup_diag.sql` (read-only). Shift rows roll on time, and machine selection works. Three real defects:
> (1) **The selected shift was ignored.** The Downtime Manager never passed its shift dropdown to the editor, and the editor's duration-only save hard-coded `shiftId None`, so every approximate entry landed on the *current* shift and the chosen shift's list stayed empty. `RecordApproximate` already honoured an explicit shift, so the fix is two view edits (Manager passes `view.custom.shiftId`; Editor declares `params.shiftId` and uses it).
> (2) **Approximate entries were stored 4 h early.** `RecordApproximate` v1.0 copied `Oee.Shift.ActualStart` (Eastern wall-clock) into the UTC `StartedAt`, so every entry showed 03:00 for a 07:00 shift. v1.1 converts. Migration `0077` repaired the rows the bug produced (matched exactly: `IsApproximate = 1 AND StartedAt = shift ActualStart`; a no-op on re-run). **10 moved on prod**, including one from 08/19 nobody had spotted.
> (3) `GetByScope` v1.1: the current-shift view also lists events still **open** from an earlier shift.
> Commits `5159c5af` (fix + 5 test assertions, red → green; suite 3408/3408) and `52705ece` (`Deploy-ProdRelease` previews the rows 0077 moves, and echoes migration counts). Prod: backup `MPP_MES_Prod_pre-release_0076_20260911_095257.bak`, committed in 0.2 s, and MPP export `MPP_downtime-shift-fix_2026-09-11_0939.zip` (the two popups only). Jacques voided the four test entries filed under the wrong shift and re-entered them against Third Shift 09/10. They landed correctly, confirming the fix live.
> **Operational lessons:**
> - **After ANY Ignition import, reload every open terminal (F5).** The open session came back with the machine dropdown empty ("no scope"), even though the view had changed by one line. A reload fixed it (see debt item 1).
> - **Elevation is not sign-in.** Supervisor elevation opens a permission window but supplies no operator; with the header on "Operator: --", a void failed with "Required parameter missing (DowntimeEventId, AppUserId)". Signing in with a PIN first fixed it (see debt item 2).
> **Technical debt logged (not yet fixed):**
> 1. **MPP `session-props/props.json` holds Dev-pickled defaults.** `custom.terminal` = `DC1-T1` / `terminalLocationId 15` and `custom.cell` = Die Cast 1 / `locationId 3` are Dev Ids, saved in by the Designer. Startup overwrites them from the client IP, but a session left open through a project update appears to fall back to them, and on prod those Ids may point at other locations. Reset them to empty shaped defaults (`terminalLocationId: null`, …).
> 2. **Protected actions with no operator signed in.** The mutation is sent with no operator, and the operator sees only "Required parameter missing (DowntimeEventId, AppUserId)". Either the elevation prompt should require a PIN sign-in first, or elevation should attribute to the supervisor's `AppUserId` (`beginElevatedWindow` sets `session.custom.appUserId`, yet the call still arrived NULL — cause not confirmed). Check `Common.Util._currentAppUserId` reading `getSessionInfo()` after elevation.
> 3. **`Oee.DowntimeEvent_Void` does not failure-log its missing-parameter rejection.** It's the only path in the proc that returns without `Audit_LogFailure`, so the failure log showed nothing. Other `DowntimeEvent_*` procs likely share the shape; sweep them.
> 4. **Changing times never re-derives the shift.** `DowntimeEvent_UpdateTimes` leaves `ShiftId` alone, so moving an event to another shift means void + re-enter.
> 5. **The Current-shift reader and the writers resolve "shift" differently.** The reader uses the plant-wide latest open `Oee.Shift`; writers use `ufn_ShiftIdForInstant(press, now)`. They agree today, but diverge for a press under a shift override. Resolve the reader per press the same way.
> 6. **Undeclared custom property:** `DowntimeManager` binds `custom.shiftOptions` without declaring it (pre-existing).
> 7. **Also open from the 09-10 review:** `DieCastBody.submitShiftOutput` drops scrap on baskets released earlier in the shift; `DieCast_GetReleasePreview` returns no result set for a no-longer-open basket; plus the unverified Release-dialog items listed in the 2026-09-10 (late) entry below.

**Previously:** 2026-09-11 (early) — **AIM made safe to switch on against production company `99`; prod carries `AimShipperIdPool_ListUnposted` v1.4.**
> **The hazard.** `ListUnposted` is the single query behind the AIM retry sweep (`AimPostTimer` → `AimPost.retryTick`), the owed-to-AIM screen and the backlog-age alarm. It listed every consumed-but-unposted serial, including the seven the 2026-09-09 FAT purge orphaned (`999000001`–`007`: consumed, `PostedAt` NULL, container FK NULLed, frozen lot/qty intact). Enabling the sweep on company 99 would have POSTed never-issued serials with FAT data to live AIM. **v1.4 adds `AND c.Id IS NOT NULL`**; the rows stay consumed and unposted. Test `0049/050` (red → green); full suite **3403/3403** on `MPP_MES_Test`. **Deployed to prod 06:53 ET** via `Deploy-ProdRelease` (preview: 1 changed proc, 0 migrations, 0 drift; rehearse 0.4 s; execute 0.2 s; backup `MPP_MES_Prod_pre-release_0076_20260911_065348.bak`). No Ignition change.
> **Test vs production AIM is ONLY the company code.** A captured production request (`notes/2026-07-28_aim-interface-contract.md` ll. 484-491) is `…/floor/99/636652666553236784/postserial.csv` to `Host: 172.17.10.86:8080`: same server, same port, same path token as the company-01 testing. Company 99's counter was ~13.84M, so real serials look like `0138xxxxx`.
> **New tooling.** `sql/scripts/Invoke-LabelReadiness.ps1` (runs the read-only `sql/scratch/2026-09-10_6ma_ch_label_readiness.sql`: printer Endpoint, AIM settings, pool, template, pack-out, open container, components, PLC map; masked password). `sql/scratch/2026-09-11_aim_config_company99.sql`: company 99 / target 5 / threshold 3 / alarms 2-1, report-only by default, with two pre-flight lists (unconsumed pool rows; unposted rows + whether the live proc has the orphan guard). Also shipped to prod: the "Container not completed" terminal alarm when a PLC tray fills a container whose completion is refused (`937b0be1`, one Core resource).
> **Found, not fixed:** `AimPoolGateway.topupTick` never passes `FetchedInterfaceLogId` and `AimHttp`'s success log omits the serial, so **nothing in the DB proves a pooled serial came from AIM** — the 2026-09-09 purge's "decided by provenance" test could only ever show NULL. `PostedAt` remains valid evidence.
> **Owed before AIM goes live:** (1) run the config script report-only and clear **hazard 1** — any unconsumed non-company-99 serial is claimed by the next container and posted synchronously by `Container.complete` (not via the sweep, so v1.4 does not cover it); (2) apply with `@Apply = 1`, enable `AimPoolTopupTimer`, confirm 5 `0138xxxxx` serials; (3) printer `Endpoint` on `MA2-6MACH-AOUT3`'s printer — legacy share `\\FLXWAPSRV1\6MA Final Assembly`, which must be installed machine-wide on the **gateway** host (javax.print sees only the service account's queues), or `IP:9100`; (4) `AimPostTimer` may now be enabled safely once hazard 1 is clear.

**Previously:** 2026-09-10 (night) — **6MA Cam Holder Assembly Out (`MA2-6MACH-AOUT3`) readied for its first PLC-driven run on 2026-09-11. Its camera PLC is wired straight to Ignition's Allen-Bradley driver, and the tray watcher could not have driven it: new `SlcTray` handshake protocol.** Detail + address map: `notes/2026-09-10_6ma-ch-camera-plc-host-interface.md`.
> **Why the old watcher failed on this PLC.** Without TOPServer the friendly members are gone; Jacques re-pointed the `6MA_CH` instance (now a `TrayInspectionStation`) at SLC words. The map came from the **`MPPMACH`** ladder export, whose data-file list matches the device's; its "LAD 4 - HOST" file is the MES interface. That PLC re-asserts `TrayLocked` (`N7:0`) every scan, **will not fire the camera until the host writes `OkToContinue` (`N7:1`)**, and has no `VisionPartNumber`. The watcher reset `TrayLocked` (an edge storm, since every bounce is a new rising edge), wrote `OkToContinue` only after a vision match (a deadlock), and would have line-stopped every tray on the missing vision value.
> **Fix (two Core script modules, nothing else).** `TrayInspectionWatcher` reads a new per-instance `Protocol` memory member. Blank or `SkuVerify` keeps the original behaviour. `SlcTray`: on tray lock, write the recipe then `OkToContinue`; on inspection complete, read the tray verdict. The MES writes **neither** trigger, as legacy never did. **The verdict words `N7:10..27` are labelled "PART# n BAD TO HOST" but the ladder writes 1 on PASS and 0 on FAIL into all of them** (rungs 9 and 6), so all 1 = book the tray, all 0 = PLC already rejected it (nothing booked), anything else = alarm. Fails closed: no `PlcId` / no ByVision pack-out / failed PLC write → no `OkToContinue`, tray held, toast. For **both** protocols, the expected recipe is now the **finished good's** `Item.PlcId` via `Assembly.resolvePlcCloseContext`, not the Item of the oldest open LOT on the line (on a ten-casting assembly that was random). `PlcWatcher.dispatch` no longer treats `previousValue=None` (tag-change subscription on restart or scan) as a rising edge, except for `TrayLocked`, which is replay-safe (`_REPLAY_SAFE`). A replayed `InspectionComplete` would book the tray twice.
> **Verification.** Offline harness (stubbed Ignition surface, the real module source) passed 29 checks: both protocols, every failure branch, the edge guard. Both modules compile under Ignition's own `jython-ia-2.7.3.5.jar`. Local `scan.ps1` clean. **Not yet run against the PLC**; the first-tray checks are in the note, including what an inverted verdict looks like.
> **Prod.** `Item.PlcId = 2` set on `1223A-6MA -J000` by Jacques (the value legacy last left in `N7:2`). **Owed tonight:** add `Protocol` (String memory) to the `TrayInspectionStation` UDT and set `SlcTray` on `6MA_CH`, since generator `defaultValue` is not applied on import; import the scoped Core export of the two modules. **Stale, left alone to keep the prod change to two resources:** the Sim panel's scenario text still says "front-of-queue Item.PlcId" (`BlueRidge.Sim`, line 64).

**Previously:** 2026-09-10 (late) — **`MPP_MES_Prod` released to `0076` at 22:14 ET, and the matching Ignition resources imported. Everything the evening's three sessions built is now live: counter anchor (`0074`), Tools punch list + scrap code 260 (`0075`), per-part cavity alpha code (`0076`).** Runbook + outcome: `notes/2026-09-10_prod-release-runbook.md`.
> **How it shipped — new `sql/scripts/Deploy-ProdRelease.ps1`, which supersedes `Deploy-0074`/`Deploy-0076` and replaces `Update-Prod` for a live database.** Three modes. **Preview** is read-only: it reads `SchemaVersion` (prod's has no `AppliedBy` column — built by `Deploy-Prod.ps1`; read only `MigrationId`/`AppliedAt`), compares **every proc's live definition to the repo text** rather than trusting commit history (reading `.sql` as cp1252 the way sqlcmd does, and normalising SQL Server's `CREATE OR ALTER` → `CREATE   `), and runs gates against live data. It writes a report with per-proc diffs, the exact cavity letters `0076` will assign, and a plan fingerprint. **Rehearse** applies the release to live data in a transaction and rolls back. **Execute** takes a COPY_ONLY backup + VERIFYONLY, then commits the pending migrations and changed procs in **one transaction**: any error rolls the whole release back. It holds TABLOCKX on `Lots.Lot` / `ToolCavity` / `DieCastContribution` so plant writes wait instead of landing between steps, and runs with DEADLOCK_PRIORITY LOW and LOCK_TIMEOUT. `-ExpectedPlan` refuses if anything changed since the preview; it fired for real when `7221d519` landed between rehearsal and execute. The password comes via `SQLCMDPASSWORD` and is never on a command line.
> **Gates stricter than `0076`'s own.** Two SQL-review findings, both verified in code: the migration's family-die gate misses (a) a single-part die with some cavities mapped and some not, which gives one part two `a` cavities, and (b) a family die with **no** map at all, which gets die-wide letters `a..l` permanently. The preview now BLOCKs on both, detecting (b) from `Lots.Lot` history (2+ parts made). It also BLOCKs when a surviving object still names a dropped column, and when `0072` and `0076` would run together. Prod tripped none of these.
> **Prod result.** Preview: `0073` with **zero proc drift** from the morning deploy, 20 changed + 3 new procs, no BLOCK or WARN. Rehearsal passed (10.2 s lock window). Execute committed in 9.2 s; all 23 procs byte-identical to `7221d519`; **all 31 active cavities got exactly the previewed letters** (DMO124 4 parts × `a,b,c`; DMO125 6 parts × `a,b`; cavity 7 `Ex 1 Da` → `a`). Backup: `MESDBSRV:...\MSSQL16.MSSQLSERVER\MSSQL\Backup\MPP_MES_Prod_pre-release_0073_20260910_221451.bak`.
> **Tested first on `MPP_MES_ProdSim`** (local, built from `ea85f0c6` = prod's morning state), loaded with dies covering every gate case and a prod-only proc naming `CavityNumber`. Preview blocked on exactly the four bad cases; after fixing them, rehearse, execute and re-preview ("nothing to do") all passed.
> **Ignition** — `tools/Build-ChangeExport.ps1 -Since add7dae6` (prod's last full import). 45 resources: **Core 14 / MPP 21 / MPP_Config 10**, imported Core first via Designer File → Import. This also delivers the **whole** `DieCastBody` resource, which settles the `shotLossDefectOptions` partial-drop defect. The builder now reads from **git, not the working tree**: the tree had 388 uncommitted gateway-rewritten manifests. It uses `autocrlf=false` (a Windows `git archive` otherwise emits CRLF), skips the 78 resources whose only change was a `thumbnail.png` manifest entry, and writes a `CONTENTS.txt` import checklist. Zips verified byte-identical to HEAD, apart from 8 manifests rewritten only to drop `thumbnail.png`. `11_project_exports.md` updated.
> **Cutover gap, observed as predicted:** from SQL commit until the Core import, prod's old `lots/Lot_Create` (passes `@CavityNote`) and `parts/ToolCavity_Create` (`@CavityNumber`) NQs fail against the new procs. The window was a few minutes with the plant idle (0 open baskets, last die-cast entry 14:54).
> **Open — confirmed bugs, both already on prod since this morning's file drop (this release did not introduce them):**
> (1) `DieCastBody.submitShiftOutput` skips every row with `IsOpen` false, **scrap lines included**, then toasts "Shift output recorded". Scrap entered on a basket released earlier in the shift is silently lost. Basketless cavity rows also share `breakdownEntries["None"]`.
> (2) `Workorder.DieCast_GetReleasePreview` does a bare `RETURN` (no result set) when the basket is no longer Open. The Query-type NQ then throws a Java exception that `except Exception` in `BlueRidge.Workorder.DieCast` does not catch. It happens when a peer releases the basket while the dialog is open.
> **Open — reviewer findings not yet verified:** the release write ignores the `cellLocationId` the dialog previewed against (NQ `lots/DieCastLot_Release` has no such param); the `DieCastRelease` context line is not keyed on `refreshToken`, so it can stay stale after an anchor; that dialog passes the cavity name as `dieName` to the anchor popup; `Tool_Duplicate` can hit `UQ_ToolCavity_ActiveToolItemCode` inside its transaction when deprecated-part `ItemId`s null out. Migration hygiene: `0076`'s letters are shared between deprecated and active rows, so active letters can skip (design call); `0073`'s backfill batch has no SchemaVersion guard if ever re-run.
> **Owed:** rotate the `Ignition` SQL password (exposed again this session); prod is in FULL recovery with **no log backups** in `msdb`, so the log will grow unbounded; floor smoke of the cavity letters / counter context / receiving LOT create; drop the local `MPP_MES_ProdSim` and its test `.bak`.

**Previously:** 2026-09-10 — **Seven-item punch list from the first plant testing session on live prod, all shipped on `jacques/working` (`8da3b9af`..`f3ef3b6e`); full suite 3373/0.** Design spec `docs/superpowers/specs/2026-09-10-tools-screen-punch-list-design.md`. One commit per item so the die-rank removal in particular can be reverted alone.
> **The real defect was `Tools.Tool_Duplicate` losing every cavity's part number** (`8da3b9af`). The proc was authored 2026-08-18; `Tools.ToolCavity.ItemId` — the family-die cavity-to-part map — arrived three weeks later in migration `0072` (2026-09-09), and the cavity `INSERT` was never taught the new column. On a 12-cavity die casting four part numbers, that map *is* the configuration, so a duplicate came back with nothing. Now copied, guarded the way the proc already guards `DieRankId`: a part deprecated since the source was configured drops to NULL and is named in the success message — carrying it forward would produce a cavity `ToolCavity_SaveAll` then refuses to re-save, stranding the Cavities editor. Cavity part joins the Old/New audit JSON, resolved to a part number. Test 4b covers active-copies / deprecated-NULLs / unmapped-stays / **source-left-intact**.
> **A scrapped cavity can be un-scrapped** (`258a0ab2`). Scrapped was modelled as terminal; the floor treats it as a working state (cavity scrapped → die repaired → back in production), and there was no route back — `ToolCavity_SaveAll` rejected the transition and `UQ_ToolCavity_ActiveToolCavity` blocks re-adding the same number, so recovery meant an SSMS hand-edit. Two layers removed: the SQL validation block (v1.2) and three `CavityRow` `props.enabled` bindings keyed on `isScrappedSaved`. **Nothing replaces the gate** — no elevation, no confirmation, as asked; the audit trail already records who changed a status and when. Test 3 in `020_ToolCavity_SaveAll` is inverted accordingly.
> **`Code` is now labelled `Asset Number`** (`7f083698`) across the Tools screen, Add Die and Duplicate Die, plus the two operator-facing proc messages that would otherwise name a field that no longer exists on screen. Column, `UQ_Tool_Code` and every `@Code` parameter keep their names. **The tool list leads with the name** (`7d83ef9d`), asset number demoted to the muted second line.
> **Die rank is out of the UI, data model untouched** (`9acc2c17`). Six components removed plus two orphaned `custom.rankOptions` bindings that were still querying the database on every load of the Tools screen and the Add Die popup. `Tools.DieRank`, `DieRankCompatibility`, their procs, `BlueRidge.Parts.DieRank` and the `DieRanks` / `EditRank` / `_DieRanks` / `DieRanksHowTo` views all stay, unreachable. **This closes the 2026-09-03 thread** that found ranks *do* exist in prod (A/B/C/D, two dies on B), contradicting FAT #2b — MPP does not want them on screen, so they stop being maintained rather than being deleted. **Two deliberate non-removals, both load-bearing:** `editDraft.meta.DieRankCode/Id/Name` stay in the Tools view defaults, because `Tools.Tool_Update` writes `DieRankId` unconditionally and an editor that stopped supplying it would silently NULL the rank on every die — invisibly, with the rank UI gone; and `AddDie`'s `DieRankCode` default stays `"B"` so a new die is stamped exactly as before. Consequence for `Lots.Lot_Merge`'s cross-die gate: unchanged today, but every *new* die now gets `B` with no way to differ, so the gate stays inert for them — the 2026-08-18 "re-key on `ToolId` or delete the dead code" decision is still owed.
> **New Trim Shop scrap reason `260` Scale Adjustment** (`c8b3bacb`). **Not 146** — that is already `Chatter` under MachiningAssembly; the Trim block just stops at 145 because Appendix E is not contiguous. The free gaps inside the FRS range (155, 193, 196, 251) sit mid-band where Flexware could still fill them, so **MPP additions open their own band at 260**, above the FRS maximum of 256. Ordinary scrap reason: Trim, not excused, not non-reject, charged to TrimShop, counts against reject percentage. Delivered in **both** seed `030` and migration `0075` per the `0048`/`0067` precedent (a reset runs migrations before seeds; seeds are not re-run in place).
> **The `shotLossDefectOptions` error on prod is a partial file drop, not a code defect** (`f3ef3b6e`). `DieCastBody` has declared `custom.shotLossDefectOptions` with a `[]` default in all twelve commits that touched it, and the local Gateway's copy is byte-identical to the repo. Prod has a copy where the transform arrived but the declaration did not. **Owed: redeploy the whole `DieCastBody` view resource to prod** — the fragment drop is what broke it. Separately, the `props.instances` transform no longer reaches across to a sibling property at all (it fetches its own defect codes), so no single missing property can take the section down again; cost is one extra identical query per load, which is what the NQ cache is for.
> **Owed to prod.** None of this has reached `MPP_MES_Prod` or the prod Gateway. SQL: three repeatables (`Tool_Duplicate`, `ToolCavity_SaveAll`, `Tool_Create`) + migration **`0075`**. Perspective: six MPP_Config views, three regenerated How-To views, and `MPP`'s `DieCastBody`. Prod is **live and carrying real production** — back up and check the shift before touching it.
> **Verification.** Full suite **3373/3373, exit 0** (fresh `MPP_MES_Test` reset, so the seed path for `260` is covered by the `0067` assertion that no seeded defect code lacks a charge-to party). All three changed procs and migration `0075` applied to `MPP_MES_Dev`; `0075` re-run to confirm its guard. Rendered against the running gateway: Tools screen (no rank button/badge/field, `ASSET NUMBER`, name-led list rows), Add Die, Duplicate Die, and the Cavities tab — where a cavity was driven Scrapped → Active → **restored to its original Closed** end-to-end. That last check is what caught the one thing `scan.ps1` cannot do: **the procs live in the database, so a view-only scan left Dev running the old `ToolCavity_SaveAll` and the save failed with the very message the commit removes.**
> **View edits were file-authored, against the standing Designer preference** — each is surgical (a label string, one term of an expression, a component subtree) and only the Designer *Launcher* was running, no project window. Removals were done by span-accurate text surgery rather than parse-and-redump, which would have unescaped Designer's `=` / `'` sequences across whole files. Verified after: every touched view still parses, all four component removals are **pure deletions** (0 insertions), and each file's escape counts differ from baseline by exactly what the intended edit accounts for.
**Previously:** 2026-09-09 — **`hunter/explore` merged to `main` (41 commits — in-app How-To guides on nearly every screen) and `MPP_MES_Prod` deployed to `0071`, then the FAT dummy LOT data purged from prod — which is now carrying REAL production.** The merge itself was textually clean (Hunter was 0 behind `main`, so a fast-forward; only `MPP_MES_DATA_MODEL.md` was touched by both sides, in non-overlapping sections), but the pre-merge review found **two migrations numbered `0067`**: Hunter's `0067_rfid_label_placeholder.sql` had been renumbered *onto* the number `0067_reject_chargeto_and_location.sql` already held. With prod at `0069` that is exactly the case `Update-Prod.ps1`'s out-of-order guard **aborts** on — the next prod update would have thrown. Renumbered to `0070`. Second find: the `INSP-SORT-T1` DefaultScreen change (`/shop-floor/third-party-inspection` → `/shop-floor/sort-cage`) was a **silent no-op on every already-seeded database** — the seed's `IF NOT EXISTS` tests for the row's PRESENCE, not its value — so Dev and prod both kept the old screen. Confirmed on Dev, fixed forward by `0071`.
> **Prod deploy to `0071`.** Backed up first (`…\MSSQL\Backup\MPP_MES_Prod_pre0070_20260909.bak`, 5,170 pages). Preview reported exactly the predicted **2 pending**, both above the 0069 watermark, no out-of-order block. Applied: **2 migrations + 449 repeatables, seeds off**. Final state **71 migrations | 431 procs | 103 tables** — 431 matches the repeatable tier's `CREATE OR ALTER PROCEDURE` count exactly, so nothing failed silently. Verified against real data: both `RfidTag` columns present; `INSP-SORT-T1` now reads `/shop-floor/sort-cage`.
> **🔴 PROD IS LIVE AS OF 2026-09-09** — discovered by the pre-purge inventory, not announced: 13 real LOTs created that afternoon by **JH (JOHN HORN, PIN `08464`)** and **TCD (Tom Davis, `08356`)** — real operator PINs, not the `000xx` placeholders — several still **Open at DC1-M11**. Treat `MPP_MES_Prod` as a production system from here on: no destructive work without a backup and a shift check.
> **FAT dummy LOT data purged from prod.** 47 LOTs (Ids 1–47, 2026-08-18 → 2026-08-20) and their entire transitive FK closure deleted; the 13 real LOTs kept. Cutoff **2026-09-09 00:00 ET = 04:00 UTC** (converted via `AT TIME ZONE`; a naive `00:00 UTC` would have spared four hours), with a **19-day gap** either side so nothing sat near the boundary. Backed up first (`…\MSSQL\Backup\MPP_MES_Prod_pre_fatpurge_20260909.bak`, 5,474 pages). 26 statements, deepest-first: `LotEventLog` 192, `LotMovement` 166, `LotStatusHistory` 94, `LotGenealogyClosure` 93, `ProductionEvent` 88, `ConsumptionEvent` 46, `LotGenealogy` 46, `DieCastContribution` 45, `RejectEvent` 27, `QualitySample`/`QualityResult` 9 each, `ShippingLabel` 7, `ContainerTray` 7, `Container` 7, `HoldEvent` 3, `SerializedPart` 2, `LotAttributeChange` 1, **`Lots.Lot` 47**. Verified after: `Lots=13`, `LotGenealogyClosure=13` (**exactly one self-row per surviving LOT** — the strongest signal the closure table is structurally intact), `Container=0`, oldest remaining LOT `2026-09-09T12:56 ET`. Script `sql/scratch/2026-09-09_purge_fat_lot_data.sql`, left at `@Commit = 0`; inventory `sql/scratch/2026-09-09_fat_lot_data_inventory.sql`.
> **⚠ The project export zips were broken and had to be fixed twice — the import smoke test we never ran would have caught both.** Two defects, both the same root cause: `build-project-exports.ps1` walks the **filesystem**, so what ships is “whatever is on disk”, and `.gitignore` has no say in it. (1) **Manifest lied about payload** — a view's `resource.json` `files[]` array is a manifest the Gateway builds the resource from; the builder excluded `thumbnail.png` but shipped the `resource.json` still naming it, so **142 resources** (1 Core / 76 MPP / 65 MPP_Config) arrived describing a file that was not in the archive. Project fails to load → Designer dies on startup with `NullPointerException … because "project" is null`. (2) **`__pycache__` shipped inside script-module folders** — a script-python resource is a LEAF folder of `code.py` + `resource.json`; give it a child folder and the Gateway renders it as a **folder, not a module**, so `BlueRidge.Common.Util` stops resolving and Jython falls through to a same-named Java package: `AttributeError: 'com.inductiveautomation…' object has no attribute 'Util'`. **18 of them** — 17 script modules (`Common/Util`, all `Location/*`, `Lots/*`, `Oee/Shift`, `Parts/{Item,Tool}`, `Reports`, all `Workorder/*` watchers) plus MPP's Perspective startup script — all CPython 3.14 bytecode that Ignition (Jython 2.7) never reads. **Invisible to review** because `.gitignore` covers `__pycache__/`, so nothing ever showed in `git status`.
> **Why it shipped:** the format was validated against `Downloads\MPP_2026-08-20_0713.zip`, described as “a genuine Ignition-produced export” — it is **3,487 bytes, three entries, one view**. It proved `project.json` placement and forward-slash separators and nothing else. Notably its one `resource.json` declares only `["view.json"]`: a real Ignition export writes the manifest to match what it emits. We did not.
> **Fixed** (`c1adf8a4` + follow-up): manifests are now rewritten to match the payload (emitted via a placeholder because PS 5.1 collapses a one-element array to a scalar, which would have broken the schema a second way); `__pycache__` / `*.pyc` excluded and the 18 folders deleted from the working tree; `ItemMaster/DraftStepRow` finally has the `resource.json` it never had. **Plus a safety net for the whole class:** any file still being included that **git ignores** is now reported loudly before it can ship. **Current good set: `dist/ignition-exports/{Core,MPP,MPP_Config}_2026-09-09_1106.zip`** — every earlier set is broken and has been deleted. Verified: every file is either `project.json`, a `resource.json`, or declared by the `resource.json` in its own directory; zero promised-but-missing, zero `.pyc`, zero backslash entries.
> **Still not import-tested.** That is now the single highest-value thing outstanding — import `Core_…_1106.zip` into a Gateway under a throwaway name and confirm `BlueRidge.Common.Util` shows as a **script**, not a folder.
> **Merge review — checked and clean:** all 277 changed files parse; 69 new How-To view folders each carry a correct `resource.json`; all **67** referenced How-To view paths resolve **within their own project** (a cross-project reference is a silent “View Not Found”); the Plant Hierarchy `editDraft.meta` → flat `state.editDraft` refactor is consistent with zero leftover binding paths; new script dependencies (`Hold.getOpenByContainerOne`, `Util.toIntOrNone`, the `ContainerSerial_Get` NQ↔proc pair) all exist; no Designer-pickled data. Hunter's `appUserId` session-prop declaration actually **fixes** a latent bug — `DieRanks` and `OperatorEditor` on `main` were already reading an undeclared property.
> **Ignition project exports rebuilt** — `dist/ignition-exports/{Core,MPP,MPP_Config}_2026-09-09_0637.zip` (862 / 356 / 246 files). **The Sep 3 and Sep 4 sets are pre-merge and must not be shipped** — they contain none of the How-To views. Verified 32 + 35 = **67** How-To views present, `project.json` at zip root, zero backslash entries. **Import Core FIRST.** Delete the stale sets so nobody grabs the wrong zip at the gateway.
> **`docs_portal` was two revisions stale** and is now rebuilt: Hunter's portal build predated FDS v1.8, so the published portal was still describing **initials-based sign-in** and carrying the struck “no clock-number/PIN convenience login” prohibition. `test:portal` 42/42.
> **Owed before go-live:** (1) **rotate the `Ignition` SQL password** — it was echoed in clear text during this deploy (`Read-Host` without `-AsSecureString`). (2) That login is still **sysadmin** on `MESDBSRV` — tighten to `db_owner` on `MPP_MES_Prod`. (3) Prod's Ignition server still has **no projects** — import the 09-09 zips. (4) **Real PINs** — prod's 7 users still carry zero-padded Id placeholders. (5) No import smoke test yet.
> **Trap worth fixing:** `Update-Prod.ps1` **hangs with no visible prompt** when `-Password` is omitted — it captures sqlcmd's output (`$output = & sqlcmd … 2>&1`), which swallows sqlcmd's own `Password:` prompt. Pass `-Password`, or fix the script to `Read-Host -AsSecureString` when it is missing.
> **Also carried in from Hunter:** a `.gitattributes` `*.pdf binary` rule, 7 new `sql/scratch/_*.sql` files, and `tools/gen_howto_views.py` (the How-To view generator). **Pre-existing, not Hunter's:** `ItemMaster/DraftStepRow` has a `view.json` but **no `resource.json`** — a “View Not Found” waiting to happen.

**Previously:** 2026-09-03 — **`MPP_MES_Prod` deployed to `0069` and the three Ignition project exports built; customer go-live is next week.** Prod (`MESDBSRV` / `172.17.10.148`) was at `0065` with **zero drift** — nothing applied that wasn't in the repo, and the four pending migrations (`0066`..`0069`) all sat above the high-water mark, so it was a clean forward-only catch-up. Backed up + `RESTORE VERIFYONLY`-checked first (`…\MSSQL\Backup\MPP_MES_Prod_pre0066_20260903.bak`, 5,058 pages), then `Update-Prod.ps1`: **4 migrations + 447 repeatables, seeds off**. Final state **69 migrations | 103 tables**; 20 procs prod never had now exist (rejects reporting, container/serial trace, `Lot_SearchAdvanced`, both PIN lookups, CRT helpers). Every migration's effect verified against real data: CrtBanner template 1 / stale `{CrtMark}` **0**; ChargeToParty 6 rows, **153 of 154** defect codes charged (the one holdout is `DC-999` "Warmup" — by design it reports under Unassigned); 5 non-reject-scrap codes; **27 of 27** reject events backfilled with a terminal; `ToleranceWeight` present; 7 users, 7 distinct PINs. **Nothing destructive** — no DROP/TRUNCATE/DELETE anywhere in the four; the only in-place edit is `0066` stripping `{CrtMark}` from 3 label templates, which I simulated read-only against prod's live ZPL before running (removes exactly one field, remaining ~200 chars byte-identical).
> **Seed `032` run by hand on BOTH prod and Dev.** Prod's Primary LOT ticket was still migration `0021`'s 260-char **placeholder** — MPP's real Honda layout had never reached it. Checking before pushing caught that **Dev was in the same state**: seeds only run on a full `Reset-DevDatabase`, and Dev has been migrated forward incrementally since seed 032 was written (2026-08-20), so it never ran there either. Both are now the real 402-byte layout, byte-identical to the seed. **Still divergent:** Dev's `Container` template is 1284 bytes vs prod's 1317 — pre-existing, untouched by 032 (Container is owned by migration `0054`), worth resolving before go-live.
> **Three Ignition project exports built** — `dist/ignition-exports/{Core,MPP,MPP_Config}_2026-09-03_1154.zip` (860 / 288 / 176 files). New rerunnable builder **`build-project-exports.ps1`** at the repo root; `dist/` gitignored as a rebuildable artifact. **Import Core FIRST** — both children declare `"parent": "Core"` and won't resolve inherited resources without it. Format was **not guessed**: matched against a genuine Ignition-produced export (`Downloads\MPP_2026-08-20_0713.zip`, 8.3.5-rc1) — `project.json` at the zip ROOT, resource paths relative to it, **forward-slash** separators, files only, no directory entries. The forward slashes are the trap: `Compress-Archive` on PS 5.1 writes backslash separators that Java-side consumers read as one long filename, so the builder writes entries by hand via `System.IO.Compression`. Verified **1,324 entries, zero byte differences** vs source, zero backslash entries, zero excluded-file leaks. Exclusions checked rather than assumed: 159 `thumbnail.png` dropped (Core legitimately has none), 4 `.gitkeep`, and **all 12 report `data.bin` KEPT** — the gitignore rule is scoped `views/**/data.bin`, so report binaries under `com.inductiveautomation.reporting/` are real authored resources; dropping them would have shipped MPP with no PDF reports.
> **Owed before go-live:** (1) **no import smoke test** — the 8.3 gateway exposes no reachable import endpoint (`openapi.json` 404s), so the zips are verified structurally and byte-wise but never actually imported; import `Core` into the local dev gateway once to close that link. (2) Prod's Ignition server has **no projects yet** and needs either the git-sync loop (`pull.ps1` + junction, per `ignition-context-pack/09_repo_gateway_sync.md`) or repeat imports. (3) **Real PINs** — prod's 7 users carry zero-padded Id placeholders (`00001`, `00002`, `00006`–`00010`); initials sign-in still works until the new project ships, so this is not urgent, but the new views are PIN-only. (4) The `Ignition` SQL login is **sysadmin** on `MESDBSRV` — more than an app service account should hold; tighten to `db_owner` on `MPP_MES_Prod` before go-live.
> **Also this session:** the customer's **tool configuration imported from prod into Dev** — `6MA-A` (12 cavities), `6MA-B` (12 cavities) and `5G0-F-A` (2), proc-driven via `Tool_Create` + `ToolCavity_SaveAll` so it carries full validation + audit rows; script `sql/scratch/2026-09-03_import_prod_tools_to_dev.sql` (scratch, never a seed). Verified all 26 tool+cavity rows byte-identical to source. **`6MA` is two dies, not one.** **Die ranks DO exist in prod** (A/Premium, B/Good, C/Okay, D/Poor; two of the three dies reference B) — which **contradicts the FAT #2b note in `CLAUDE.md`** that MPP confirmed they don't; worth reopening. `DieRankCompatibility` is empty in prod as it is here, so `Lot_Merge`'s cross-die gate is inert there too. `MPP_MES_DATA_MODEL.md` → **v2.2**: §7 still claimed "No shot counter column", false since migration `0050` (2026-08-04) — now documented along with `ShotLimit`, `Tool_Duplicate`'s config-vs-per-asset split, and a new normative rule that cross-database tool copies resolve FKs **by natural key, never by Id**.
> **Uncommitted on `jacques/working`:** `MPP_MES_DATA_MODEL.md` (v2.2), `.gitignore` (`dist/`), `build-project-exports.ps1`, `sql/scratch/2026-09-03_import_prod_tools_to_dev.sql`. Flagged for a separate pass: the older `Tools` procs (`Tool_Create`, `Tool_Update`, `DieRank_Create`) still emit generic `'Tool created.'` audit descriptions instead of the `<SUBJECT> · <CATEGORY> · <ACTION>` convention that `ToolCavity_SaveAll` / `ToolAttribute_SaveAll` already follow.

**Previously:** 2026-09-02 — **Operator sign-in switched from initials to a 5-digit PIN.** Nine commits on `jacques/working` (`83f9c244`..`b589aa60`). Migration `0069_appuser_pin.sql` adds `Location.AppUser.Pin NVARCHAR(5) NOT NULL UNIQUE` + `CK_AppUser_Pin_Format`; new procs `AppUser_GetActiveByPin` (presence gate) / `AppUser_GetByPin` (history), both mirroring the initials pair; `Pin` carried through Create/Update/Get/List/Deprecate. New `Components/PlantFloor/Numpad` view; `Popups/InitialsEntry` now takes a PIN and auto-submits on the 5th digit (path + popup id unchanged, so none of the ~16 call sites moved). Config-Tool Users screen gained a PIN column and field.
> **Leading zeros are load-bearing** — a full-time employee's code is `04218`, a temp's `40218`. Column is NVARCHAR, NQ params are `sqlType: 7`. Three tests guard it (`046_AppUser_Pin_lookups.sql` round trip, plus 4-digit and duplicate rejection in `010_AppUser_Create.sql`). Full suite **3221 assertions, 2 failures — both pre-existing** and unrelated (`0069_Aggregate_Reports/010_schema.sql` defect-code charge-to counts; verified identical at baseline with the PIN work stashed, 3136/2).
> **No seed dependency.** Operators self-provision at the terminal on first unrecognised PIN; the unknown-PIN dialog makes **Re-type PIN** primary and *Register New User* secondary so a mistyped digit cannot become a duplicate person. **Elevation deliberately untouched** — a PIN grants presence only, AD per-action elevation is unchanged, and a supervisor covering a break just signs in with their own PIN.
> **Owed:** live smoke of the four edited/new views — the gateway trial had expired when the work landed, so they are validated by JSON parse + clean `scan.ps1` only. `MPP_MES_Dev` has migration `0069` applied and all 16 users backfilled with zero-padded placeholder PINs (`JGP` = `00022`, `TOM` = `00023`); real PINs need entering before use. Dev also still shows migrations `0064`/`0065`/`0066` pending out-of-order — pre-existing, untouched.

**Prior header (2026-08-18):** **FAT Day 1 punch list worked; `main` == `jacques/working` == `0b000bdf`; full suite 2728/0.** Eight items triaged against the actual code, three shipped, one closed with no build, two decided, one deferred, one written up for the customer. Working notes: **`notes/2026-08-18_fat-day1-punch-list.md`** (all eight, with file references, decisions and what is still owed) and **`notes/2026-08-18_serialized-line-validation-number-brief.md`** (item 7 for Tom).
> **Shipped.** **#6 session timeout** (`c62ea5e2`) — migration `0058` sets operator presence to **30 min** (1800 s) on the live row and on the shipped DEFAULT; the Config-Tool **Users** page editor now speaks **whole minutes with the unit shown** and converts at the boundary, refusing a blank/non-numeric field instead of writing a silent fallback. Storage deliberately stays in **seconds** (the unit `Common.Session` computes with and both CHECKs are written against). **#3 terminal IP auto-nav** (`126d267c`) — root-caused: **nothing was broken.** `Terminal_GetByIpAddress` v1.2 + `ufn_NormalizeIpAddress` are correct (26 dedicated assertions green); localhost failed at the prod test because **no terminal carries `127.0.0.1`**, so the fallback row was the right answer — it was just *silent*. TerminalSelector now shows an `UnregisteredBanner` naming `{session.props.address}` when `isFallback`, and `sql/scratch/register_loopback_terminal.sql` binds one chosen terminal to loopback for gateway-host demos (scratch, never a seed — shipping `127.0.0.1` to a plant terminal would make every gateway-host session claim to be it). **#8 vision station by IP** (`05764eaa`) — migration `0059` renames LTD-7 `VisionAppUrl` → **`VisionAppIp`**; new **`Location.ufn_VisionAppUrl`** composes `http://<ip>/` (`:port` and `/path` carried through, an existing full URL passed through unchanged — which is what makes the rename non-breaking, blank → NULL so the iframe never loads `http:///`); `Terminal_GetClosureContext` v1.1 reads it but **keeps the result column named `VisionAppUrl`**, so `applyToSession`, the session property and both assembly views are untouched. +15 tests.
> **Closed / decided.** **#5 weekend shifts** — no build: Jacques authors the weekend `ShiftSchedule` in the existing editor. (One residual worth doing: `DowntimeEvent_Start` writes `ShiftId = NULL` silently when no shift instance is open and `GetByScope` then filters the event out of every shift-scoped read — any future schedule gap reproduces the disappearance.) **#4 production/inventory report** — **building = Area** (no new location tier; `DC1`–`DC4`, `TRIM1/2`, `MA1/2`, `WHSE`, `SHIPIN/OUT` already hang off the facility) and **daily = shift-anchored, 3rd → 1st → 2nd**, so the report must group on the `Oee.Shift` instance, not a `CAST(… AS DATE)` cut that would split 3rd shift across two rows. Spec pending.
> **Two corrections to earlier assumptions, both the same mistake:** a `SessionPolicy` editor **did** already exist (Config-Tool Users page), and there is **no missing attribute editor** for terminals — the Plant Hierarchy attribute panel renders generically from `LocationAttributeDefinition` via `buildAttributesForType`, so any LTD-7 attribute appears automatically.
> **Open, needing MPP or Jacques.** **#2 die list** — `reference/Die Shots Report.pdf` parsed to `reference/seed_data/die_shots_report.csv` (343 rows, all parsing). `(6-digit code, Die)` is unique and a reliable natural key, but the **cavity roll-up does not resolve from the report alone**: `(model, die letter)` over-groups (59B die N collects the Base Comp Fuel Pump with the In Cam parts), and grouping by identical die-letter sets — convincing on strong cases like `dies H,J,K,L,M,N` → the ten 59B In Cam cavities — collapses unrelated single-die parts and leaves 13 `(model, die)` collisions. Recommendation: load one `Tools.Tool` per `(code, die)` row, ask MPP for the die master. Also owed: how the 6-digit code maps to `Parts.Item.PartNumber`, which statuses to load, Total vs Good shots for `ShotCount`. **#2b die rank dropped** — MPP confirms die ranks do not exist. **S-08 was the only true blocker in the Seeding Registry and dissolves**, but `Lots.Lot_Merge`'s cross-die gate only fires on 2+ distinct non-NULL `DieRankId`s, so with every rank NULL it goes **inert — all cross-die merges pass with no supervisor override**. Decide: re-key on `ToolId`, or delete rather than leave dead code. **#8 mapping** — the seven vision IPs were supplied as station names; mapping derived via the one `ByVision` terminal per line and loaded to Dev, kept in `sql/scratch/seed_vision_app_ip.sql` until confirmed (open: MPP's "RPY, 6B2, 66V Fuel Pump" vs our "Fuel Pump (RPY 66v)"; and five ByVision terminals given no IP). **#7** — brief ready to send to Tom. **#1 BOM version on the FG label** — **deferred**, but note the coupling: `D/C PART LEVEL (2P)` is fed by die rank, so it now renders **blank on every label**, and `00`/`01`/`02` is exactly Honda's native format for that field.
> **Verification gaps:** the local gateway's **Perspective client trial has expired**, so neither the minute-based timeout editor nor the unregistered-terminal banner has been eyeballed in a browser, and the live `session.props.address` → `applyToSession` → `HomeRouter.route()` leg of #3 is unverified. All SQL is verified against `MPP_MES_Dev` and the full suite is green.
> **Note for whoever runs tests next:** `Run-Tests.ps1 -Filter 0020_PlantFloor_Foundation` reports `Test run FAILED` on `040_Lot_Create.sql` (`ToolAssignment.CellLocationId` NULL). That is a **filtered-run artefact, not a bug** — that file's fixtures are built by earlier test directories the filter skips. The unfiltered suite is **2728/0, exit 0**.
> **Also uncommitted in the shared tree, deliberately left alone:** `link-projects.ps1` (someone replaced a hardcoded `C:\Users\NoahNesbitt\…` path with `$PSScriptRoot`) and the untracked `ignition/projects/MPP/…/stylesheet/` (Core's stylesheet is canonical; the MPP override was dropped in `4466f32b` and must not be re-added).
> **Latent issue worth a sweep:** a top-of-file `IF EXISTS … RETURN` migration guard only exits its **own batch**, so the trailing `dbo.SchemaVersion` insert still runs and raises Msg 2627 on re-run. Fixed in `0058`; **`0049_session_policy.sql` has the same shape**, and others may.

**Prior header (2026-08-10):** **Ignition Reporting Module report suite built end-to-end + FAT-practice remediation pass, all on `jacques/working`.** **Reporting (commits `dd1d8cf7` → `732a31db`):** the `ignition-reporting` skill (reverse-engineered `data.bin` codec) installed **globally** (`~/.claude/skills/`) + MPP overlay `ignition-context-pack/10_reporting_module.md`; a plant-floor **Reports landing page** (`/shop-floor/reports`, in the ≡ AppMenu) — tile rail → per-report pickers (gated) → inline **Report Viewer** → **Print PDF**, driven by the `BlueRidge.Reports` registry — with **six PDF reports** authored *from files* off the donor `sample for claude` and render-verified against the live 8.3.5 gateway: **Downtime by Shift** (shift picker; shift date+bounds; machine-grouped detail), **Downtime by Date Range**, **Current Inventory** (plantwide WIP), **Die Cast Shot Count** (materialized `Tool.ShotCount`), **Lot Detail** (2-page traceability: header + genealogy + production events, LOT picker), **Production Line Performance** (weekly output/scrap/downtime by OperationCategory line). Picker NQs `reports/Shift_ListForPicker` + `reports/Lot_ListForPicker`; guarded Perspective glue (safe fallbacks + toasts). **Hard-won report gotchas codified in the overlay:** a report resolves by its internal `setTitle` (folder name MUST match); `L.esc` every layout literal + validate the XML (a raw `&` → `RMException` at render, shown as "invalid report"); never pass the Report Viewer an empty params dict; `scan.ps1` DOES reload changed report `data.bin` (no restart). **FAT remediation:** `docs/fat/MPP_MES_FAT_practice.xlsx` cleaned (30 `N/A` rows + orphaned headers removed, Cover roll-up totals corrected) then the 194 un-evaluated items validated by code-inspection (**102 Pass / 19 Fail** marked `[insp]` with file:line evidence; 73 left blank as live/HW/data-gated) + 4 stale "design-evolved-past-the-FAT" rows dropped. Full failure triage → candidate specs in `notes/2026-08-07_fat-failure-remediation-brief.md`; paste-ready fleet kickoff briefs in `docs/handoffs/2026-08-07-fat-remediation-handoffs.md` — Briefs **A** (FAT-OQ-030 operation-template Draft/Published lifecycle) and **C** (FAT-MACH-140 machining reject capture) shipped **DONE by fleet agents**; D (label/print) / E (deprecated initials) / F (held-LOT scrap) queued. Draft email to MPP requesting the Honda trace-export format at `notes/2026-08-07_mpp-email-honda-trace-export.md` (unblocks the HELD Spec H). Per-thread detail in the `## 🔖 2026-08-10` section below.

**Prior header (2026-08-04):** **Hunter plant-floor feedback pass (9 items + extras) on `jacques/working` (commits `17cd2bc5` → `0ba74666`).** Downtime popup rebuilt (pinned row height, header/action spacing, reason readability, **inline per-row reason dropdown**, editor date-field align + `dismissOnSelect` picker fix) + **duration-only/approximate downtime capture** (migration `0046`: `IsApproximate` + materialized `DurationMinutes` + temporal-safe backfill; `RecordApproximate` proc/NQ/wrapper; editor "Duration only" toggle; `~NNm` row marker). Assembly **completion gate → single "Complete" button** (Non-Serialized + Serialized) + **ChangeoverElevation** popup height. **LOT Detail:** linked-container tab wired (`Lots.Lot_GetLinkedContainer`), **as-built BOM version** (migration `0047`: `Lots.Lot.BomId` stamped by `Assembly_CompleteTray` + `MachiningOut_Mint`, surfaced by `Lot_Get`, one-time temporal backfill), new **Inspections tab**. **Hold release** made reachable (HoldManagement row-button un-gated + LOT-detail "ON HOLD" pill & one-click Release via `Hold.getOpenByLotOne`/`release`). **Serialization checkbox** exposed on Container Config (per closure method). **MaxParts** now enforced on loose receiving (`Lot_Create`, **Received-origin only** — production mints unaffected; +test `041`). Inspection terminal **auto-populates the LOT** when opened from a LOT. All views file-authored + scanned; all SQL applied to `MPP_MES_Dev`; `MPP_MES_Test` green (full suite 2268/0 + new `092` 32/32 and `041`). Per-item detail in the `## 🔖 2026-08-04` section below.

**Prior header (2026-07-29):** **Die Cast entry redesigned to a per-cavity Open → accumulate → release lifecycle** (see the `## 🔖 2026-07-29` section directly below). Built subagent-driven across 14 tasks (SDD) per `docs/superpowers/specs/2026-07-28-diecast-per-cavity-lifecycle-design.md` and `docs/superpowers/plans/2026-07-28-diecast-per-cavity-lifecycle.md`, with a per-task review after each task plus one final whole-branch review. Migration `0045` (new `Open` `LotStatusCode`, new `Workorder.DieCastContribution` ledger, 4 audit `LogEventType`s) + 5 new/reworked procs + 6 Core NQs + entity glue + a rebuilt `DieCastBody` view. Full `MPP_MES_Test` suite **2225/0**; deployed to `MPP_MES_Dev`; final whole-branch review **APPROVED, no blockers**. **The view is a first cut pending Jacques's live smoke** — no automated UI test exists for it. Deferred Minors consolidated in `.superpowers/sdd/progress.md` (none block merge; see the section below for the list). Full task-by-task ledger in that same progress file.

**Prior header (2026-07-24, session 2):** **Third-party Inspect-tab quality-capture form wired + Assembly consume hold-guard fixed** (see the `## 🔖 2026-07-24 (session 2)` section directly below). The "meaty quality-capture form" the prior note flagged as unbuilt **already existed** as the standalone `InspectionEntry` view (Phase-9, file-authored) — so the Inspect tab now **embeds** it (no from-scratch form), plus a Fail→one-tap **Place Hold** affordance. Investigation en route found `Workorder.Assembly_CompleteTray` was the **only** consume path missing the `BlocksProduction` guard (it consumed Hold/Scrap source LOTs); fixed to match every sibling proc — this *is* the check-out gate. Full `MPP_MES_Test` **2163/0**; proc deployed to Dev; both views scanned. Earlier today —

**Prior header (2026-07-24, session 1):** **Meeting-driven workstreams (2026-07-22 notes) built + the plant location model reconciled to the authoritative Site DB; `jacques/working` == `main` == `a7829b6a`. Full `MPP_MES_Test` suite 2151/0.** Six of seven meeting items shipped (**die cast HELD** pending Jacques's feedback on its spec's assumptions):
> **(1) Location reconcile** — `MPP_MES_Site` is now the authoritative location map. Regenerated the seed (`gen_locations_mpp.js` now reads `sql/seeds/_site_*.tsv` dumps) with authoritative **Names** (never renamed — codes fixed to match: RPYCAM re-key, AFIN→AOUT, 5PA MIN→MOUT/AIN, 6F9TC/COS MOUT→AOUT…), **printers only on MOUT/AOUT/COMBINED/ASER** terminals, DefaultScreen/closure(→enum, vision-through-scale→ByVision)/scanner/confirm seeded, `TRIM{1,2}-STORE` + `INSP` inspection area (66B-TC re-parented) added. Applied to **Dev in place** via `sql/scripts/reconcile_location_dev.sql` (two-phase rename preserves `Location.Id` → the 50 live LOTs + PLC reg stayed attached; old printers retired to `__OLD__`/deprecated for the downtime FK). Memory: [[project-mpp-location-authority]].
> **(2) Operator-change audit** — migration `0044` (LogEventType 75 `OperatorChanged`) + `Audit.OperatorChange_Log` + NQ + `AppUser.logOperatorChange`, wired into `InitialsEntry.loginAs` (capture old op → audit handoff, fire-and-forget). Tests 18/18.
> **(3) Assembly-OUT projected consumption (display-only, NOT a gate)** — `Workorder.Assembly_GetComponentProjection` (mirrors CompleteTray math + exact-cell pool) + NQ + `Assembly.getComponentProjection` + `view.custom.componentProjection` binding + **rendered**: `ComponentProjectionRow` instance view + flex-repeater under the components sidebar with red LOW pills. Tests 10/10.
> **(4) Combined Machining IN/OUT tabs** — new `MachiningStation` view (embeds `MachiningIn`+`MachiningOutSplit`), route `/shop-floor/machining` = the `-MIO-` terminals' DefaultScreen.
> **(5) Trim storage → Machining IN** — Trim OUT (`TrimOut_Record` v2) deposits every trimmed LOT into the local `TRIM{N}-STORE` (destination picker gone, "Shot count"→"Lot count"); `Lot_GetTrimStorageQueueForLine` shows each line the eligible Trim-Storage LOTs (two-line part on both); `MachiningIn_RecordPick` v2 **claims** (in-txn move Storage→line, race-safe no-op-COMMIT). TrimBody + MachiningIn views rewired. **Also fixed the pre-existing `0027` MachiningIn route-test failures.** Full suite 2144/0.
> **(6) Third-party inspection station** — customer-confirmed: check-out **IS assembly-out** (bought-in part = component consumed by a newly-minted pass-through FG, FG-style container config 1 lot→1 tray→1 container). Only new backend = `Lots.Lot_GetInspectionQueueByLocation` (Received-origin LOTs at station + latest result; 7/7). New `ThirdPartyInspection` tabs view: **Check In**=ReceivingDock / **Inspect**=queue / **Check Out**=AssemblyNonSerialized; route + `INSP-SORT-T1`/`66B-Ins` DefaultScreen. **⚠ Scaffold remaining:** the Inspect tab shows the queue but the dynamic **quality-capture attribute form** (render a QualitySpec's attrs → build `ResultsJson` → `QualitySample_Record`) is NOT built — first consumer of the Phase-9 capture API, a meaty form of its own.
> Design docs: `docs/superpowers/specs/2026-07-23-*` (7). Consolidated smoke test: `docs/superpowers/specs/2026-07-24-consolidated-smoke-test.md`. All Ignition views were file-authored (Designer closed) + scanned; concurrent-session file `Core/…/Location/Location/code.py` left untouched/uncommitted.

**Prior header (2026-07-20):** **Shop-floor UX polish + terminal-context refactor; all pushed to `origin/jacques/working` (through `60852585`).** Session shipped, each committed: Cell Mount Card embedded on Plant Hierarchy (Tool Config section, right of the details card, gated on `IsMountTarget`); Item Master cavity `#` ordinal removed + die-cast cavity dropdown shows number **+ description**; ContainerConfig **view-deserialize fix** (a `customMethods` param was an object — must be a plain string, or the whole view fails to load); Trim IN/OUT inventory rescoped to **LOTs residing in the terminal's zone** (role-filter band-aid removed — the earlier IN/OUT split is undone); MovementScan **"already at this location"** pre-check (disables Move when the LOT's current location == destination); plant-floor **disabled-button styling** (`:disabled` grey/not-allowed on `psc-pf-*` buttons, Core stylesheet); `Trim/InventoryRow` switched to a **flex `pf-inventory-row`** card so the Select-on-left button lays out without disturbing the shared `pf-queue-row` grid; Trim OUT **shot-count prefill** from the selected LOT's pieces. **Terminal refactor:** one `BlueRidge.Location.Terminal.applyToSession` resolver — onStartup/NavigationTree/TerminalSelector all delegate; fixes stale printer/PLC/closure/vision after a navigate and clears the cell. **Root-caused a recurring plant-floor trap:** a stale/**fallback** terminal (unregistered laptop IP) has `zoneLocationId` = the whole Madison Facility → plant-wide queue reads + false "Not eligible at destination"; the station subtitle "Madison Facility" is the tell. **DB incident:** a concurrent agent reset `MPP_MES_Dev` mid-session (Run-Tests pointed at Dev); `sql/scratch/seed_jp_validation.sql` refreshed to Jacques's rebuilt config (3 dies mounted DC1-M01..03 + routes-through-Trim/BOMs/eligibility/container-configs) as the LOT-free restore fixture; DB-safety guardrails already landed earlier today (Run-Tests → `MPP_MES_Test` default; Reset refuses `*_Dev` without `-Force`). New memories: [[mpp-terminal-session-context-and-fallback]], [[mpp-core-stylesheet-canonical]], [[ignition-view-deserialize-schema-valid-json]]. Full per-item detail: `notes/2026-07-20_working-notes.md`.**

**Prior header (2026-07-16):** — **Shop-floor bug-fix pass: route-aware operation-template lookups (Trim OUT / Machining OUT / Machining IN "template missing" fixed), die-cast→Warehouse auto-deposit, assembly insufficient-stock toast now names the short component(s), NavigationTree reusable component, Trim IN validates/deposits at the AREA. Branch reconciled with 13 concurrent-stream commits + promoted — `main` == `jacques/working` == `db4800d5`. Surfaced a bigger architectural TODO: converge operation-template execution to ONE SQL methodology (see the 🚧 TODO at the very top). Full detail in the 2026-07-16 section below + `notes/2026-07-15_working-notes.md`.**

**Prior header (2026-07-14):** **PLC integration built end-to-end (Plans 1–3) on `jacques/working`; `hunter/explore` merged in (Phase 9 quality capture).** SQL: migration `0038` (`PlcDeviceType` / `TerminalPlcDevice` / `Item.PlcId`, audit entity Id 58) + `0039` (handshake audit LogEventTypes 67/68). Ignition: 4 UDT defs + `MPP_Sim` Programmable-Device-Simulator + 22 instances (generated from one member catalog); Sim Panel `/dev/sim/plc`; Core NQs; gateway watchers (Scale / SerializedMip / NonSerializedMip / TrayInspection) + rising-edge `PlcWatcher.dispatch`; `/plc-devices` mapping editor; `onStartup` → `session.custom.plcDevices`; Item Master `PlcId` field. Full SQL reset green (39 migrations + 349 repeatables; `0039` test 2/2); `scan.ps1` clean; pushed to `origin/jacques/working` (`d5d8a332`). **Owed (only):** one folder-watch gateway Tag Change script in Designer + the simulator smoke pass — see `notes/2026-07-14_plc-commissioning-runbook.md`. Migration-collision note: the Hunter merge renumbered the PLC migration `0037→0038` (Phase 9 keeps `0037`) and bumped the `TerminalPlcDevice` audit entity Id `57→58`. Detail in the 2026-07-14 section below.

**Prior header note (2026-07-08):** **Streams converged on `hunter/explore`: main's terminal-mint model redesign (Jacques, ~24 commits — route-driven queues, `MachiningOut_Mint` consume-mint, OperatorBar, Category cascades, `seed_demo` auto-run in Reset-DevDatabase) MERGED with the 2026-07-07 smoke-findings fix pass + follow-ups (Hunter — see that stream's header note below). Merge resolutions: shared-terminal cell picker kept as a picker-only ContextBar hidden on dedicated flavors (reconciles main's ContextBar removal with the picker requirement); die-cast tally readers unified on main's `_tallyRows`; `seed_demo.sql` taken from main (mint model). Full suite + gateway scan re-run post-merge.**

> **See the `## 🔖 2026-07-14 — PLC Integration` section directly below for the full PLC writeup.**

**Prior header note (hunter/explore, 2026-07-07):** **Smoke-findings fix pass on `hunter/explore`: all 14 items from `notes/2026-07-07_smoke_findings.md` addressed (full suite 1945/1945, only the pre-existing `010_Parts_codes_crud` thrower). Per-item ✅/⚠️ annotations live in the findings file. Re-smoke owed — see the section directly below.** Prior header note (2026-07-06 second session): **Jacques 2026-07-06 meeting task list worked on `hunter/explore`: 21 of 24 items fixed, tested, committed (full suite 1934/1934, only the pre-existing `010_Parts_codes_crud` thrower). 3 items open pending live repro / Jacques's call.** Prior header note (earlier 2026-07-06):

---

## 🔖 2026-09-10 (session 2) — Die cast counter anchor: see the shift total, declare the real one

Day-two feedback from the die cast floor. An operator on basket `10627564` typed a counter reading, got

> *That reading is behind the last reading recorded for this die, 2,124 for this shift.*

and had **no way past it**. Two defects behind one screen.

### The rolling total was invisible until it blocked you

`Workorder.DieCast_GetReleasePreview` has returned `DieCreditedThrough` since it was written, but the only component reading it was the red `Advisory` label — whose `position.display` is `readingState != "Ok" || belowStandardAfter`. So the number governing every reading on the die appeared **only inside the sentence rejecting one**. Nobody could check against it beforehand.

Both die-cast entry points now state it as plain context above the field it explains — *"This die is at 2,124 for the shift (recorded 14:12 by JP)"* — from the new read proc `Workorder.DieCast_GetCounterContext`, which also says whether the number came from a recorded entry or from a hand-set anchor.

### And there was no way past the wall

Three places refuse a reading below the die watermark, and all three are right for a typo. None had an exit for the two cases the floor actually hits: **the press counter was reset mid-shift**, or **a wrong number was entered earlier** and has blocked the die for the rest of the shift. Spec 2026-09-09 named both (E3, E4) and deferred them pending evidence MPP needed them. MPP has now provided it.

The blocker was structural, not an oversight: both watermarks were `MAX(ShotCounterReading)`, and **a MAX cannot be lowered by appending**. Correcting downward meant editing an append-only ledger.

### The fix — a floor, not an override

`Workorder.DieCastCounterAnchor` (migration `0074`) records one new fact: *"as of now, this press counter reads N."* Both `ufn_*ShotWatermark` functions (v2.0) take it as a floor:

```
watermark = MAX( anchor.DeclaredReading,
                 MAX(reading) over contributions recorded AFTER it,
                 0 )
```

**With no anchor, every number is byte-for-byte what it was** — asserted as test 1 of the new suite, because otherwise every existing die-cast test would be passing for a new reason.

Three properties worth keeping in mind:

- **The floor reaches every cavity on the die, including ones with no basket.** That is why it is its own table: `DieCastContribution.LotId` is `NOT NULL` (`0045`), so a contribution can only speak for a cavity that has an open basket — while the next basket opened on *any* cavity inherits that cavity's watermark. It floors in **both directions**: down for a poisoned watermark, up for a cavity that never produced (else the next basket invents production) or a die changed over onto a running press.
- **A counter reset is `DeclaredReading = 0`.** E4 needed no code of its own.
- **A later contribution supersedes the anchor.** The chain resumes normally; it is not sticky.

**Authorization: any signed-in operator, with a mandatory reason** (`CounterReset` / `WrongReadingEntered` / `DieChangeover` / `Other`+note). Deliberately no AD elevation — the operator is the only person who can see the press counter, and gating on a supervisor strands a night shift at a wall. The reason code and a `Warning`-severity audit row carrying old → new watermark are the control.

**Forward-only, and the UI says so out loud.** An anchor sets where crediting *resumes*. Pieces already credited to baskets stay, and so does `Tools.Tool.ShotCount`. The popup and the proc's own success `Message` both state it — if either stops saying it, operators will assume the baskets were fixed too.

### Shipped

| | |
|---|---|
| Migration | `0074_diecast_counter_anchor` — `DieCastCounterAnchor` + `DieCastCounterAnchorReason` (4 seeded) + `DieCastCounterAnchored` audit event |
| Procs | `ufn_DieShotWatermark` **2.0**, `ufn_CavityShotWatermark` **2.0**, `DieCast_GetReleasePreview` **1.1** (+`ToolId`); new `DieCastCounterAnchor_Record`, `DieCast_GetCounterContext`, `DieCastCounterAnchorReason_List` |
| Named queries | `workorder/DieCastCounterAnchor_Record`, `workorder/DieCast_GetCounterContext`, `workorder/DieCastCounterAnchorReason_List` |
| Python | `BlueRidge.Workorder.DieCast` — `getCounterContext`, `describeCounterContext`, `listAnchorReasons`, `anchorReasonRequiresNote`, `recordCounterAnchor` |
| Views | new `Popups/DieCastCounterAnchor`; `Popups/DieCastRelease` + `Views/ShopFloor/DieCastBody` gain the context line and the escape hatch |
| Tests | `0022_PlantFloor_DieCast/100_CounterAnchor.sql` — **40/40** |

Spec: `docs/superpowers/specs/2026-09-10-diecast-counter-anchor-design.md`. Data model updated (which also documented `DieCastContribution.ShotCounterReading` from `0073`, missed at the time).

### Two things left open

1. **`Tools.Tool.ShotCount` keeps the inflation.** A typo'd `2124` added 2,124 of phantom die life against `ShotLimit`, and a forward-only anchor does not claw it back. A die could run past its limit on shots it never fired. Not addressed — raise it if the die-life numbers start to drift.
2. **`MPP_MES_Dev` has migration drift, unrelated to this work.** `Update-Prod -Preview` reports `0064_crt_part_scoped`, `0065_crt_label_mark_token`, `0066_crt_banner_label` as pending *and out of order* (the DB is at `0073`). `0074` and its repeatables were therefore applied by hand rather than letting the updater touch those three. Someone should decide whether they were superseded (backfill `SchemaVersion`) or genuinely missed.

### Not verified in the browser

Perspective's **client trial has expired** on the local gateway, so the three views were deployed via `scan.ps1` and are structurally valid, but **no screen was rendered**. The SQL is covered by the 40 passing assertions; the view wiring is not. Reset the trial in the gateway and smoke the Release dialog + Record Shift Output tab before this goes to the floor.

---

## 🔖 2026-09-10 — `MPP_MES_ERD.html` replaced by the SchemaGen build (generated, not hand-authored)

The repo ERD had been a **hand-authored** HTML file last refreshed **2026-06-08** (`c388863f`) — three months stale, and maintained by transcribing `MPP_MES_DATA_MODEL.md` by hand. It is now the **SchemaGen** output read straight from the live `MPP_MES_Dev` schema, so it can never drift from the built database again.

**Generated:** `python generate_erd.py --config mpp.json` in `../SchemaGen`, then copied over `MPP_MES_ERD.html`. Read-only introspection (`sys.*` catalog views, no user data, no locks).

| | |
|---|---|
| Tables | 103 |
| Columns | 822 |
| Relationships | 234 (0 heuristic — every edge is a real FK) + 2 self-referencing |
| Stored procedures | 432 with table references |
| Dependent objects | 35 views/functions/triggers across 23 tables |
| Tabs | 17 — 8 schema tabs + cross-schema overview + 8 `X:` focus tabs |
| Comments | **323** (136 table, 618 non-empty column) |

### What this closes

**Step 4 of `docs/superpowers/plans/2026-09-03-extended-property-descriptions.md`** — "Run SchemaGen against `MPP_MES_Dev`. Expected: the header's comment count goes from 0 to several hundred." It went **0 → 323**, and every schema tab's Documentation section is populated from `MS_Description` extended properties. That plan step is done.

### Capability delta

**Gained:** per-tab stored-procedure dependency graphs (color-coded SELECT/INSERT/UPDATE/DELETE), a procedure call graph, table-dependency graphs (which views/functions/triggers touch each table), cross-schema overview + per-schema focus tabs, table/column documentation straight from the DB, SVG + ZIP export per tab, light/print themes alongside dark.

**Lost: the MVP / CONDITIONAL / FUTURE scope badges.** The hand-authored ERD tagged tables by scope; SchemaGen reads database metadata only and has no notion of project scope. `reference/MPP_Scope_Matrix.xlsx` remains the scope authority. If the badges are wanted back, the path is to encode scope in an extended property so SchemaGen surfaces it as documentation — not to resume hand-authoring.

Also note the **919 columns with no `MS_Description`**. Improving the ERD's documentation now means adding extended properties in SQL, not editing HTML — the drift report at `notes/2026-09-03_data-model-doc-drift.md` is the backlog.

### Pointers updated

`README.md` (doc table + folder tree + a new **Regenerating the ERD** section carrying the command, the `--embed-assets` offline variant, and the scope-badge caveat), `CLAUDE.md` doc-map row 5, `MPP_MES_SUMMARY.md` (2 places — the "8 tabs + master" description was wrong), `MPP_MES_FDS.md` and `MPP_MES_USER_JOURNEYS.md` (both claimed "scope badges"), `MPP_MES_PHASED_PLAN_PLANT_FLOOR.md` (carried a stale "v1.9i, regen pending" version), and the Source-of-Truth table below. `docs_portal/erd.html` iframes `../MPP_MES_ERD.html` by filename, so the portal picks up the new content with no rebuild.

No doc version bumps: these are cross-reference description corrections, not design changes.

---

## 🔖 2026-09-09 (session 2) — Trim-press seed drift closed: the seed now matches the plant

**Commit `aacf12f7` on `jacques/working`.** `sql/seeds/011_seed_locations_mpp_plant.sql` still created `TRIM1-P01..P03` and `TRIM2-P01..P03` (`LocationTypeDefinitionId 10` = `TrimPress`) plus the dedicated press terminal `TRIM1-P01-T1` as **active** Cell-tier equipment. Both live databases deprecated all seven on **2026-07-30** — MPP tracks trim at the **shop** level, not per press. The Site dump the generator reads is dated 2026-07-23, so it predates the decision and a freshly seeded database did not match the plant it exists to model.

### Why it stopped being cosmetic

`Oee.DowntimeScope_ListForTerminal` (added earlier the same day, `105c097b`) offers a per-machine downtime dropdown whenever an Area has **active** equipment cells beneath it, and the trim shop scope depends on `TRIM1` having none. On any DB built from the seed, trim got a **three-press machine dropdown instead of shop scope**. The drift had quietly become load-bearing.

### The decision — seed them deprecated, not delete them

Three options were on the table: drop the rows, seed them already-deprecated, or document and leave. **Seeded already-deprecated.** Prod and Dev both *carry* these rows, so deleting them would make a fresh DB diverge from the live tree in the other direction; a deprecated row also records that the presses existed and were retired, where a deleted one invites someone to re-add it. The proc filters `DeprecatedAt` at every level of its descendant walk, so trim collapses to shop scope with **no code change** — and if MPP ever runs trim per press again, clearing `DeprecatedAt` brings the dropdown back by itself.

`011` is **generated**, so the fix lives in `sql/seeds/gen_locations_mpp.js` as a `RETIRED` set consulted by `loc()`. That is a deliberately **different axis** from the TSV's `Deprecated` column, which `skip()` reads as *"omit entirely"* — these rows must exist. `sql/scripts/reconcile_location_dev.sql` picks the change up from the same emitter (it only adds rows that are missing, so prod is a no-op). Regenerating produced exactly the 7 rows + header, which also confirms the committed seed was still in sync with its generator.

### The test fallout was real, not incidental

`Lots.Lot_Create` refuses a deprecated `@CurrentLocationId` (`R__Lots_Lot_Create.sql:128`), and `0024_PlantFloor_Movement_Trim` staged its fixtures at `TRIM1-P01` across **14 call sites in two files** — 29 assertions failed. Worth recording: **this churn was unavoidable either way.** Deleting the rows would have broken the same 14 sites, because both options end with `TRIM1-P01` unusable as a LOT location. The fixtures were modelling a configuration that can no longer exist; live trim LOTs sit at `TRIM1` itself (Dev: 4 LOTs at `TRIM1`, 1 at `TRIM1-STORE`, **none at any press**). Restaged on the shop.

One case needed thought rather than a rename. Test 4 exercises guard **3b** (*"not at this Trim station"*), which needs a source that is **not** an ancestor of the LOT's location — exactly what a press used to provide. It now records the second OUT from the **sibling shop `TRIM2`**. Guard 3b fires before the already-trimmed guard (5), so the reason it asserts is unchanged, and Test 6 still covers the same-shop re-entry that falls through to guard 5.

### Test 120 keeps its synthetic area — on purpose

`0026_PlantFloor_Downtime_Shift/120_DowntimeScope_ListForTerminal.sql` built a synthetic area rather than using `TRIM1`, and its header called the seed stale. The synthetic fixture **stays**: it is the only way to assert both halves of the rule (no active cells → the area; flip back to a machine list the moment one appears) without mutating the plant seed. Its comments no longer describe the seed as drifted, and a new **Test 10** asserts the real seeded `TRIM1` resolves to shop scope — the part that actually drifted. It deliberately names `TRIM1` where every other test in that file is structural, because the thing under test *is* the seed.

### Verification

| Run | Result |
|---|---|
| Baseline, original seed, `-Filter Trim` | 87 / 87 pass |
| Seed fixed, tests not yet updated | 3246 / 3275 — **29 failures**, all trim |
| Tests restaged, `-Filter Trim` | 87 / 87 pass |
| **Full suite, final** | **3275 / 3275 pass** |

Run against a throwaway `MPP_MES_Test_TrimSeed` (since dropped) after the shared `MPP_MES_Test` hit a concurrent-session reset failure — worth remembering that DB is shared across worktrees. **`MPP_MES_Dev` was never reset**; read-only queries only, its 7 press rows unchanged.

**Untouched deliberately:** the `TrimPress` LocationTypeDefinition, the `TrimDedicated` view and the `/shop-floor/trim/dedicated` page all remain — the *capability* is still valid, only the terminal that used it is retired.

---

## 🔖 2026-09-09 — `hunter/explore` merged + prod deploy to `0071`

**Target:** `MPP_MES_Prod` on `MESDBSRV` / `172.17.10.148`, SQL login `Ignition`. Prod still not in use; customer go-live imminent.

### The merge

`origin/hunter/explore` was **0 behind / 41 ahead** of `origin/main` — a straight fast-forward, no merge commit. 277 files: 139 `view.json` (69 new How-To popups, 70 edits to existing views), 79 other Ignition resources, 35 docs, 13 SQL, 11 root. Both trial merges (`git merge-tree`) returned zero conflicts, including against the 5 unpushed commits on `jacques/working`; the only file touched by both sides was `MPP_MES_DATA_MODEL.md`, in different sections.

Not docs-only, despite the branch's own “this branch is now docs-only” revert commits — it also carries Core Python changes (`Notify` toast stacking now height-aware, `SortCage.getSourceHold`, `Hold.listOpenLots`, `Nav` shift-overrides category, the `Location` editDraft reshape), both stylesheets, `MPP_Config` session props, a new named query + repeatable proc, and the SQL below.

### Two real findings

1. **Duplicate migration `0067`.** Hunter's commit `a1845bdc` “renumber RFID label placeholder 0064 -> 0067” moved it *onto* an occupied number. `Update-Prod.ps1`'s out-of-order guard (`sql/scripts/Update-Prod.ps1:184`) throws on any pending migration numbered at or below the applied high-water mark, and prod was at `0069`. **The next prod update would have aborted.** Renumbered to `0070` (`e4bf356f`), updating the `MigrationId` recorded in `dbo.SchemaVersion`, the trailing `PRINT`, and the two `MPP_MES_DATA_MODEL.md` rows citing it. Verified the renamed file differs from Hunter's original by exactly those 4 lines.
2. **`INSP-SORT-T1` DefaultScreen was a silent no-op.** The generator and both generated outputs were changed in lockstep — that part was well done — but the seed's `IF NOT EXISTS` is a *presence* guard, so re-running seeds does nothing on a database that already has the row. Read Dev's live value to confirm before writing the fix. New migration `0071` (`c6be73cf`) retargets it, guarded on the **old value** so it is idempotent and will not clobber a terminal deliberately pointed elsewhere.

Both migrations were applied and verified on `MPP_MES_Dev` first, including a clean second run.

### Runbook as executed

```
BACKUP DATABASE MPP_MES_Prod TO DISK='…\MSSQL\Backup\MPP_MES_Prod_pre0070_20260909.bak'
  WITH INIT, COMPRESSION, STATS=25;      -- 5,170 pages
$pw = Read-Host "Ignition password"      -- NOTE: echoes in CLEAR TEXT; use -AsSecureString
& …\sql\scripts\Update-Prod.ps1 -ServerInstance 172.17.10.148 -DatabaseName MPP_MES_Prod `
                                 -Username Ignition -Password $pw -Preview
& …\sql\scripts\Update-Prod.ps1 … (same line, minus -Preview)  -- confirms by typing the db name
```

`Update-Prod.ps1` must be invoked by absolute path or from the repo root; it derives `$SqlRoot` from its own location, so the working directory is otherwise irrelevant.

### FAT dummy LOT data purged from prod

**The inventory changed the job.** It was run first purely to identify the FAT rows, and instead revealed that `MPP_MES_Prod` had gone into **real use that afternoon** — 13 LOTs from JH (`08464`) and TCD (`08356`), several Open at DC1-M11 with realistic counts (1059, 1353, 1355) and real names (`10627547`…`10627569`). The FAT rows are unmistakable next to them: `000000001`–`000000033` and `MESL30000xx`, created by `JGP`/`DEV`/`SYS` in bulk bursts — twelve LOTs inside one second at 00:31:22.

That turned a routine cleanup into a delete against live traceability data, so the script got hard guards before it got run.

**Guards (all abort BEFORE any transaction opens):**

| Check | Prod result |
|---|---|
| A kept LOT has a FAT parent | 0 |
| `LotGenealogy` straddles the cutoff | 0 |
| `LotGenealogyClosure` straddles the cutoff | 0 |
| `ConsumptionEvent` straddles the cutoff | 0 |
| A FAT container holds a kept LOT's tray | 0 |
| A FAT container holds a kept serial | 0 |
| A shipping label carries a **really fetched or posted** AIM id | 0 |

Each straddle test projects both sides to 1/0 first — T-SQL cannot compare two predicates with `<>`.

**AIM shipper ids — decided by provenance, not by the id string.** Prod's seven are `999000001`–`999000007`, a synthetic block, but a format is not evidence. `Lots.AimShipperIdPool` records the truth directly: `FetchedInterfaceLogId` is non-NULL only if the id really came back from a logged Honda AIM call, `PostedAt` only if it was really transmitted. All seven were NULL/NULL, so nothing entered or left the plant and deleting the labels is local housekeeping. Note `PostAttempts = 1` on all seven — the gateway *tried* once and failed, which is exactly why the test is `PostedAt`, not the prefix. **The pool rows themselves were NOT deleted and NOT recycled** — only the container FK was NULLed; they stay marked consumed, because reissuing a shipper id Honda may have seen is not ours to do.

**Scope beyond `Lots.Lot`.** Containers do not foreign-key to `Lots.Lot`, so a LOT-only delete would have stranded a container holding no trays with a shipping label still pointing at it. Containers *opened* before the cutoff went too, with their trays, serials, serial history and shipping labels. Delete order came from `sys.foreign_keys` — 21 tables, `ContainerSerialHistory` four levels down — not from memory.

**Dry-run design.** `@Commit = 0` does not skip the deletes; it runs them inside a transaction and rolls back. A preview that skipped the statements would prove nothing, whereas this exercises every FK in real order and reports true counts. Plus a residue check that rolls back and raises if any targeted LOT survives.

**Trap worth remembering:** the first prod preview died at the first `DELETE` with **Msg 1934 `QUOTED_IDENTIFIER`**. `sqlcmd` defaults it OFF, and SQL Server refuses DML against a **filtered index** unless it is ON — `Lots.Lot` carries one (the B8 active-lots index). `Update-Prod.ps1` passes `-I`; the ad-hoc command did not. Both FAT scripts now `SET QUOTED_IDENTIFIER ON` themselves so they no longer depend on how they are invoked (verified by running on Dev deliberately without `-I`). `XACT_ABORT` had already rolled the failed preview back, so nothing changed.

**Not touched:** `Audit.ConfigLog` / `Audit.OperationLog` and anything else without an FK to `Lots.Lot` — that is the audit trail and it SHOULD outlive the rows it describes. Parts, tools, locations, users and label templates are configuration, not LOT content.

### Export/import incident — two builder defects, same root cause

`build-project-exports.ps1` enumerates the **filesystem**, so a file being git-ignored does not stop it shipping, and a file being excluded does not stop the manifest promising it. Both directions bit us:

| # | Defect | Blast radius | Symptom |
|---|---|---|---|
| 1 | `resource.json` `files[]` promised `thumbnail.png` that was excluded from the zip | 142 resources (1 / 76 / 65) | project will not load; Designer `NullPointerException … "project" is null` |
| 2 | `__pycache__` shipped **inside** script-python resource folders | 17 script modules + MPP startup | resource renders as a folder, not a module; `AttributeError: '…' object has no attribute 'Util'` |

Defect 2's bytecode is CPython 3.14; Ignition runs Jython 2.7 and never reads it. Both were invisible to code review — `.gitignore` covers `thumbnail.png` and `__pycache__/`, so neither ever appeared in `git status`.

**The validation that gave false confidence:** the donor export used to confirm the format is 3,487 bytes with **three entries and one view**. It could only ever prove `project.json` placement and path separators. Its lone `resource.json` declares `["view.json"]` — real Ignition exports keep the manifest consistent with what they emit, which is precisely the invariant the builder broke.

**Fixes:** manifests rewritten to match payload; `__pycache__`/`*.pyc` excluded and purged from the tree; missing `DraftStepRow/resource.json` added; and a git-ignore safety net that reports any ignored file still being shipped. Verification is now structural rather than spot-check: every file in every zip must be `project.json`, a `resource.json`, or declared by the `resource.json` in its own directory.

**Lesson for next time:** “verified structurally and byte-wise but never actually imported” was already written down as owed work on 2026-09-03. It was the exact gap that let this reach a customer Gateway. Import once, into anything, before shipping.

### Post-deploy verification (all green)

`71 migrations | 431 procs | 103 tables`; `RfidTag` present on both `Lots.LotLabel` and `Lots.ShippingLabel`; `INSP-SORT-T1` = `/shop-floor/sort-cage`. Table count unchanged is correct — `0070` adds columns, not tables.

---

## 🔖 2026-09-03 — Prod deploy to `0069` + Ignition project exports

**Target:** `MPP_MES_Prod` on `MESDBSRV` / `172.17.10.148`, SQL login `Ignition`. Customer go-live next week; prod was **not yet in use**, which is what made this routine.

### Pre-flight (what made it safe to proceed)

| Check | Finding |
|---|---|
| Applied vs repo | 65 applied, 69 in repo — missing `0066`, `0067`, `0068`, `0069` |
| Drift | **None.** Nothing applied on prod that is absent from the repo |
| Ordering | All four above the `0065` high-water mark — clean forward-only, no `-AllowOutOfOrder` |
| Tools schema prod vs Dev | **Byte-identical** despite the 4-migration gap |
| `0067` preconditions | `RejectEvent` partitioned on `ps_MonthlyUtc` ✓, all 3 `OperationCategory` codes ✓, 6 HSP + 7 Prod/QC defect codes present ✓ |
| `0069` backfill safety | max `AppUser.Id` = 10 across 7 rows → PINs `00001`..`00010`, all 5-digit, all unique |
| Permissions | `Ignition` login is **sysadmin** + `db_owner` (also `BACKUP DATABASE`) |
| Live volume | 7 AppUsers, 47 LOTs, 169 Items, 218 Locations, 88 ProductionEvents, 27 RejectEvents, 40 ContainerConfigs |

### Destructiveness review — nothing destructive

No `DROP`, `TRUNCATE`, `DELETE`, or column narrowed/retyped in any of the four. Three mutate existing rows:

1. **`0066`** rewrites 3 live label templates to strip the `{CrtMark}` token `0065` had spliced in. **Simulated read-only against prod's actual ZPL before running** — removes exactly the one `^FO300,45…{CrtMark}^FS` field, remaining ~200 chars byte-identical on all three.
2. **`0067`** backfills, all `WHERE … IS NULL` so it can never overwrite an engineer's edit.
3. **`0069`** backfills `Pin` then applies NOT NULL + UNIQUE + format CHECK.

**Re-run safety note:** `0066` and `0067` carry the known guard bug — a top-of-file `IF EXISTS … RETURN` before a `GO` only exits its own batch. Both survive it because every statement is individually guarded and the `SchemaVersion` insert is `IF NOT EXISTS`-wrapped. `0069` has no `GO`, so its `RETURN` works properly. (Same family as the `0049_session_policy.sql` issue flagged 2026-08-18.)

### Runbook as executed

```
BACKUP DATABASE MPP_MES_Prod TO DISK='…\MSSQL\Backup\MPP_MES_Prod_pre0066_20260903.bak'
  WITH INIT, COMPRESSION, STATS=25;      -- 5,058 pages
RESTORE VERIFYONLY FROM DISK='…';        -- "backup set is valid"
.\Update-Prod.ps1 -ServerInstance 172.17.10.148 -DatabaseName MPP_MES_Prod `
                  -Username Ignition -Password <pw> -Preview
.\Update-Prod.ps1 … -Force                -- 4 migrations + 447 repeatables, seeds OFF
sqlcmd … -i sql\seeds\032_seed_label_templates_mpp.sql   -- by hand, prod AND Dev
```

> `Update-Prod.ps1`'s confirmation uses `Read-Host`, so an agent/non-interactive shell must pass `-Force`. Run it from a real terminal to get the "type the database name" prompt.

### Post-deploy verification (all green)

`69 migrations | 103 tables`; CrtBanner template 1, stale `{CrtMark}` 0; ChargeToParty 6; defect codes charged 153/154 (`DC-999` "Warmup" unassigned **by design**); non-reject-scrap 5; RejectEvent terminal backfill **27/27** (better than predicted — every reject had a prior `LotMovement`); `ToleranceWeight` present; 7 PINs / 7 distinct.

### Label templates — a gap that was nearly missed

Prod's **Primary** LOT ticket was still migration `0021`'s 260-char placeholder; MPP's real Honda layout lives only in seed `032`. Checking before pushing revealed **Dev was identical** — seeds run only on a full `Reset-DevDatabase`, and Dev has been migrated forward incrementally since 032 was authored (2026-08-20), so **seed 032 had never run anywhere.** It is a scoped idempotent `UPDATE` (Primary only, `AND ZplBody <> @Zpl`), not insert-if-missing, so it does replace the placeholder. Run on both. Prod now: Container 1317, Primary 401, Master 226, Void 226, CrtBanner 53. **Dev's Container is 1284 vs prod's 1317 — unresolved.**

### Ignition project exports

`build-project-exports.ps1` (repo root, rerunnable) → `dist/ignition-exports/` (gitignored).

| Zip | Title | Parent | Files | Size |
|---|---|---|---|---|
| `Core_2026-09-03_1154.zip` | Core | — (inheritable) | 860 | 680 KB |
| `MPP_2026-09-03_1154.zip` | MPP MES | Core | 288 | 374 KB |
| `MPP_Config_2026-09-03_1154.zip` | MPP Configuration Tool | Core | 176 | 269 KB |

**Import Core first.** Format reverse-checked against a real Ignition export (`Downloads\MPP_2026-08-20_0713.zip`): `project.json` at zip ROOT, relative resource paths, **forward-slash** separators, files only. `Compress-Archive` on PS 5.1 writes backslashes that Java reads as one filename — hence hand-built entries via `System.IO.Compression`. Verified 1,324 entries / 0 byte diffs / 0 backslash entries / 0 leaks. **Report `data.bin` kept** (gitignore is scoped `views/**/data.bin`); 159 thumbnails + 4 `.gitkeep` dropped. `MPP_MES` and `Refrence project` are empty stubs with no `project.json` — the builder refuses them.

**Not verified:** no actual import was performed (no reachable 8.3 import endpoint; `openapi.json` 404s). Smoke-import `Core` into the dev gateway before the customer deploy.

---

## 🔖 2026-08-26 — LOT Detail report: ancestor process history + reachable picker

All 8 tasks of `docs/superpowers/plans/2026-08-25-lot-detail-report-genealogy-nesting.md`
complete on `jacques/working`. Full narrative in
`notes/2026-08-25_lot-detail-report-handoff.md`.

**The report was never broken.** It was a working five-page traceability document whose data
sources all returned correctly. It *looked* empty because the picker was
`TOP 100 ORDER BY CreatedAt DESC` and Dev's newest LOTs are terminal SubAssemblies with no
descendants, containers or events.

**The picker was the real defect** and is fixed (`214d1674`): a traceability report you can
only run on the newest 100 LOTs is backwards, since its purpose is investigating something
that shipped months ago. Any LOT of any age is now reachable by scanning or typing its LTT
name. The resolver branches on TYPE, not parseability — LOT names are zero-padded numerics, so
`int('000000001')` succeeds and returns `1` while that LOT's Id is `254`. Resolving numerically
first would have rendered a fully populated Honda traceability document **for the wrong LOT**.
The plan's own code did exactly that; it had never been run.

**Nested report tables work, but the markup is exacting and fails SILENTLY** — the most reusable
finding here. The whole nest must sit inside a **`<table-group>`**, and the child table must carry
the **same width and height as its parent with no `x`/`y` of its own**. Break either and the child
renders nothing at all — no exception, no log line, no partial output. The reverted `80f87484`, my
first attempt, and the pre-existing **`Rejects Part Matrix`** (whose nests have never rendered) all
break the same two rules. Working skeleton now in `ignition-context-pack/10_reporting_module.md`,
taken from the production Boar's Head `CryovacEnterpriseWeeklyReport`. The "Ancestor Process
History" page is built as designed on that shape.

I initially concluded from two failing examples that the engine did not support nesting at all, and
wrote that into the pack, memory and this file. Jacques corrected it by pointing at the Boar's Head
reports. **Two failures sharing an author-error are not evidence about the engine**, and "no working
example in this repo" is not "unsupported".

**Section counts now appear in every page subtitle** (`ce89ce56`). An empty ReportMill table is
a bare header over a void with no "no rows" message, so an empty section read as broken — the
thing that started this investigation.

**The report now has a generator in version control** — the biggest structural win. It
previously had none: six `data.bin` files were built ad-hoc in a scratchpad and only the
binaries committed. `tools/reports/` now holds the layout as editable XML, the SQL as Python, a
generator, and a reproduction test proving byte-level fidelity. Never hand-edit `data.bin`.

**Process note:** the broken layout commit `80f87484` was reverted (`9c64ff9e`) before any new
work. Its layout XML had been authored into the plan as verbatim code from ~10 minutes of
reading samples, never rendered, and faithfully transcribed by the implementer. Report layout
is interactive work — render, look, adjust — not a delegable transcription task. A clean render
with no exception proves nothing; bad layout renders blank and logs nothing.

**A reported "defect" that turned out not to be one:** the footer rendering literal `@Page@` /
`@PageMax@` is a **PNG artifact, not a bug**. PNG is not a paginated format, so the page-number
keys cannot resolve; the same report rendered to PDF shows `Page 1 of 6` correctly on every page.
The markup is byte-identical to the production Boar's Head reports. Recorded in the pack, because
the PNG-based verify harness makes this look like a project-wide bug.

**`Rejects Part Matrix` was shipping broken and is now fixed** (`11d6f268`). It rendered, so it read
as working, but its `ByParty` and `Defects` nested tables produced nothing — operators got part rows
with the department split and defect breakdown silently absent, on an `available: True` report. Fixed
at the generator (`nested_table()` in `tools/build_aggregate_reports.py`), which emitted the same
malformed nest — no `<table-group>`, children given their own offsets and boxes — so the next nested
report would have inherited it. Verified by render in PDF and PNG.

**Open, chipped, not fixed:** `InventoryManager.receiveLoose` has the same int-first resolution
bug the picker had, safe today only because part numbers contain letters.

**All five aggregate reports are now content-verified by PDF render** (2026-08-26), not merely
"it rendered" — every value checked against the proc output that feeds it:

| Report | Verdict |
|---|---|
| Rejects - Transaction Detail | ✅ full detail rows (part, LOT, operator, defect, charge-to, qty) |
| Rejects - Plant Summary | ✅ all 6 departments matching SQL exactly (Die Cast `25,241 / 192 / 25,433 / 0.75`), non-reject scrap section, customer-scrap explainer |
| Rejects - Part Matrix | ✅ fixed this session (`11d6f268`) — both nested sections now render |
| Hold Status | ✅ the one open hold, complete (`000000005 / 1,220 pcs / Trim Shop 1 / Precautionary / 533 h`) |
| Shipping History | ⚠️ headers only — **correct, not broken** (see below) |

**Shipping History was gated on a flag that will never be set — fixed** (`10bf8b81`). It returned
zero rows and would have done so forever: `Lots.Container_ListShipped` scoped on
`ContainerStatusCodeId = 3` (Shipped), and per Jacques there will never be a Shipped flag in
practice — MPP ships through their own infrastructure and MES is never told. Not empty because
nothing shipped; empty because the gate can never open.

The proc header already reasoned correctly about the **timestamp** ("closure time is not a degraded
proxy, it is the ceiling of what this system can ever know") and then failed to apply the same
reasoning to the **scope**. Scope is now closed containers (Complete or Shipped) ranged on
`CompletedAt`, with the AIM shipper ID left-joined so a container that closed *without* one still
appears blank — a closed container missing its ID is a reconciliation gap worth surfacing. Report
note and subtitle now say "closed", not "shipped". The test asserting the old contract was inverted
deliberately; 56/56 green. Render-verified: all 5 containers listed.

**Consequence still open — the Shipped status is a dead path.** Nothing sets status 3 except the
Shipping Dock's Ship button (operator action, not integration). If that step will not be used, the
button / `Lots.Container_Ship` / its NQ and entity wrapper are dead weight that will read as working
features at FAT. Scoped but deliberately NOT actioned in
`notes/2026-08-26_shipped-status-dead-path-scope.md` — it needs one question answered by MPP, then
an FDS revision + Open Item, not a silent code deletion. The system is correct meanwhile: the
report no longer depends on the flag.

---

## 🔖 2026-08-10 — Reporting Module suite + FAT-practice remediation

Two threads, both on `jacques/working`.

### A. Ignition Reporting Module — report suite (commits `dd1d8cf7`, `7de366b4`, `3e881e11`, `732a31db`)

- **Skill + overlay.** Installed the `ignition-reporting` Claude skill **globally** at `~/.claude/skills/ignition-reporting/` (Jacques is an integrator — reuse across clients). It authors Ignition Reporting reports as file-based binary `data.bin` resources via a reverse-engineered `BinaryWriter` v2 codec (there is no scripting API to *author* reports; `system.report.*` only executes them). Round-trip-validated byte-for-byte against our gateway (`framework.version 8.3.5.2026040611-rc1`). MPP-specific deploy + gotchas in `ignition-context-pack/10_reporting_module.md` (+ CLAUDE.md pack pointer, memory `project_mpp_reporting_module`).
- **Donor.** Jacques saved `…/reporting/reports/sample for claude/` in the Report Designer (a report **must** carry ≥1 parameter AND a parameterized query so the codec can clone every setter signature — a param-less donor lacks `setExpressions`; the codec borrows arg-type-identical signatures where needed). Every report is cloned from this donor.
- **Landing page** `BlueRidge/Views/Reports` (route `/shop-floor/reports`, added to `Popups/AppMenu` OPERATIONS group). Plant-floor dark/touch: left **tile rail** (6 reports) → detail pane with **per-report parameter inputs** (shift dropdown / date pickers / LOT dropdown, `meta.visible`-gated by selected report) → embedded **`ia.reporting.report-viewer`** (inline preview) → **Print PDF** (`system.report.executeReport` → `system.perspective.download`). Driven by the `BlueRidge.Reports` registry (Core script): `registry()` / `reportOptions` / `shiftOptions` / `lotOptions` / `composeParams` / `generatePdf`, all guarded (`except (Exception, java.lang.Throwable)` → safe fallbacks; view `printPdf`/`selectReport` wrap + toast).
- **Six reports, all render-verified** (light letter-size PDF, MPP tokens — cyan accent, blue-black, single-scale Pareto where used, machine-grouped nested detail on the shift downtime one): **Downtime by Shift**, **Downtime by Date Range**, **Current Inventory**, **Die Cast Shot Count**, **Lot Detail** (2 pages: header + genealogy + production events), **Production Line Performance** (weekly). Picker NQs `reports/Shift_ListForPicker`, `reports/Lot_ListForPicker`. HTML design mocks kept in `mockup/reports/` (`downtime_report_mock.html` is the locked family template).
- **The gotchas that cost hours (now codified so they never bite again):** ① a report resolves by its internal **`setTitle`**, not the folder name — folder == `setTitle` == the view's `source` or you get *"Enter a valid report in the source property"*. ② **`L.esc` every layout literal** (`&`/`<`/`>`); a raw `&` yields `RMException: entity name must immediately follow the '&'` at *render* time, surfaced as a generic invalid-report — **validate the layout XML parses** (`minidom`) before deploy. ③ Never hand the Report Viewer an **empty `params` dict** — it rejects the source (`composeParams` always returns a non-empty dict; a param-less report gets a defaulted param, e.g. `{"MinPieces": 0}`). ④ `scan.ps1` **does** reload changed report `data.bin` — no gateway restart needed.
- **Verify-in-browser note:** the in-app browser renders + reads Perspective views but **cannot fire a container's `onClick` or commit a dropdown/date** — so report render was verified by temporarily defaulting the landing view to each report + reading `"/ N"` (page count) with no error, then reverting. Tile-click / picker interactions are for a human/Designer to confirm.

### B. FAT-practice remediation + fleet handoffs

- **Workbook** `docs/fat/MPP_MES_FAT_practice.xlsx` (uncommitted — Jacques's to stage): removed **30 `N/A`** data rows + orphaned section headers, decremented the Cover roll-up `Total`s (live `COUNTIF` Pass/Fail/Open recompute on open), then validated the **194 un-evaluated** items by code-inspection via a fan-out of subagents — **+102 Pass / +19 Fail** written to Result with `insp` witness + file:line evidence in Notes; **73** left blank (genuinely live/hardware/data/manual-gated) annotated with the reason. Then dropped **4 stale rows** where the build deliberately evolved past the FAT wording (USR-130 sticky elevation, SHIFT-070 editable StartedAt, TRC-140 materialized quantities, AUD-110 log-anyway). Net FAT tally after: **224 Pass / 40 Fail / 73 blank**.
- **Triage → specs.** `notes/2026-08-07_fat-failure-remediation-brief.md` — every remaining Fail with context + evidence + a pattern-aware proposed fix, clustered into candidate specs, with Jacques's inline feedback folded in (CC-060 LinesideLimit **cancelled** — it's the existing part-side `MaxParts`; Spec E collapses to USR-090; QH-150 = scrap-against-held-LOT not split; Specs **G** and **H** HELD).
- **Fleet kickoff briefs** `docs/handoffs/2026-08-07-fat-remediation-handoffs.md` (shared-tree rules + paste-ready launch prompts). Fleet agents shipped **Brief A** (FAT-OQ-030 — `Parts.OperationTemplate` Draft/Published lifecycle, migration `0053`) and **Brief C** (FAT-MACH-140 — Machining OUT defect/reject capture) as **DONE, tests green**. Briefs **D** (label/print reliability + Honda shipping-label content, migration `0054`), **E** (deprecated-initials at presence sign-in), **F** (held-LOT scrap + container alert) remain queued.
- **Owed from MPP:** an example Honda-format trace export (draft email `notes/2026-08-07_mpp-email-honda-trace-export.md`, not yet sent) — unblocks the HELD **Spec H** (genealogy/shipping-history exports), now that the Reporting Module is understood.

---

## 🔖 2026-08-04 — Hunter plant-floor feedback pass (9 items + extras)

Worked Hunter's shop-floor feedback list end-to-end on `jacques/working`, item by item with a commit per cluster (`17cd2bc5` → `0ba74666`). All Ignition views were **file-authored with Designer closed** then `scan.ps1`'d (large existing views edited via verified Python string-splices + `json.loads` + JSON-walk checks, not the Edit tool, because of the `=`/`\"` escaping and deep nesting); all SQL applied to `MPP_MES_Dev` (idempotent migrations + `CREATE OR ALTER`, **no reset** — Dev holds hand-built data). Two dead async subagents early on (silent death — no file changes, verified before trusting) reinforced: **verify subagent output; don't assume**.

- **Downtime popup** (`Popups/DowntimeManager`, `PlantFloor/DowntimeManager/EventRow`, `Popups/DowntimeEditor`). Rows were growing to fill — pinned to a fixed height; widened + rebalanced columns so the reason no longer truncates; header/End-Edit-Void spacing. **Inline reason dropdown** on each row (`Downtime.updateReason` on select → refresh; kills the "Start → must hit Edit to set reason" round-trip; options cached once). Editor: START/END fields aligned (the "blank = still open" label wrap was shoving End down → moved to a tooltip), **`dismissOnSelect: false`** on the `date-time-input`s so you pick date *then* time, larger popup + roomier Cancel/Save.
- **Approximate (duration-only) downtime.** End-of-shift reconstruction ("down ~45 min, don't recall when") is the real manual-entry case. Migration `0046_downtime_duration_approximate`: `Oee.DowntimeEvent += IsApproximate BIT + DurationMinutes INT` (materialized), backfill of existing closed events. New `Oee.DowntimeEvent_RecordApproximate` (nominal **shift-anchored** window so the one-open index + shift OEE bucketing both hold; `IsApproximate=1` flags the window as not-precise — only duration + shift are authoritative) + NQ + `Downtime.recordApproximate`; `RecordHistorical`/`End`/`UpdateTimes` now stamp `DurationMinutes`; `GetByScope` returns both. Editor gains a **"Duration only" toggle** (minutes field, hides Start/End); manager rows show **`~NNm`** for approximate events. Tests `0026/110` (7 asserts) + full downtime suite green (43/0).
- **Assembly completion gate → just a "Complete" button** in **both** `AssemblyNonSerialized` and `AssemblySerialized` (stripped the bulleted `GateText` + the dev `Hsub` subtitle, relabeled the button). **Msg 1 (parts-in-tray reset on closure switch) was already implemented** in the working tree (`closureMethodTracker.onChange`) — verified, not duplicated.
- **`ChangeoverElevation`** ("Change Closure Mode") popup was too short for its content — `defaultSize.height` 400 → 540.
- **LOT Detail** (`Views/ShopFloor/LotDetail`). The **Linked Container** tab was a "later phase" stub — wired to the real container via `Lots.Lot_GetLinkedContainer` (`ContainerTray.FinishedGoodLotId → Container`, + AIM shipper id / status / location / tray) with an empty-state when unlinked. **As-built BOM version:** migration `0047_lot_bom_asbuilt` adds `Lots.Lot.BomId` (FK `Parts.Bom`) stamped by the two mint procs (which already resolve it) + a **temporal backfill** of existing LOTs (BOM Published & active at each LOT's `CreatedAt`); `Lot_Get` surfaces `BomVersionNumber` → header shows "· BOM vN". New **Inspections tab** listing all `Quality.QualitySample`s for the LOT (reuses the existing `listByLotInstances` → `SampleRow`). Backend tests: `092_Assembly_CompleteTray` +4 asserts (stamp, version resolve, linked-container read) → 32/0.
- **Hold release** was *unreachable*, not missing. The `HoldManagement` console exists (AppMenu → Hold Management) but each hold-row's action button was enable-gated on `lotStatusCode='Good'` (never passed, and a held LOT is never Good) → permanently disabled; ungated + renamed "Select". Replaced the misleading "open-holds list read pending" hints. Added the discoverable per-LOT home: **LOT Detail shows an "ON HOLD · #N · type" pill and a one-click "Release Hold"** (mirrors Clear-CRT) when the LOT has an open hold — via new `Quality.Hold.getOpenByLotOne` + existing `Hold.release`.
- **Serialization checkbox on part config.** `Parts.ContainerConfig.IsSerialized` already flowed through load→editDraft→save but had **no widget** (stuck at false) — added a "Serialized" checkbox to each closure-method block (ByCount/ByWeight/ByVision) in the MPP_Config Item Master `ContainerConfig` section, bound to the existing draft key. View-only.
- **MaxParts on loose receiving.** The per-location cap was enforced on the move path (`Lot_MoveToValidated`) but not on "Receive loose parts" (`Lot_Create`). Added the guard to `Lot_Create` **gated to the `Received` origin** (mirrors the move check; inert when `MaxParts` NULL) so operator placement is capped both ways while **production births — die-cast/machining/assembly mints — are never halted on a full location**. Test `041_Lot_Create_maxparts` (accept-under, reject-over, minted-nothing, Manufactured-over-not-gated).
- **Inspection auto-populate.** `LotDetail` → Inspection navigate now passes `params={lotName}`; `InspectionEntry` gains a `lotName` input param + an `onStartup` `self.resolveLot(...)` so the LOT is pre-loaded (spec/history cascade) instead of re-scanned.

**Commits:** `17cd2bc5` (downtime + approximate + assembly gates + changeover) · `d979aefb` (as-built BOM + linked-container backend) · `b8298b0b` (LotDetail linked-container view + BOM + Inspections tab) · `9b7c4137` (hold release) · `1f15c8bd` (serialization checkbox) · `b36fe536` (MaxParts) · `0ba74666` (inspection auto-populate).

---

## 🔖 2026-07-31 — Shift Boundary Reconcile-to-Now

Replaced the shift-boundary gateway ticker's naive tick-time stamping with `Oee.Shift_Reconcile`: snaps open/closing shifts to their scheduled boundary instant instead of the wall-clock tick moment, and runs a bounded (max 7-day) full-timeline backfill so gateway-downtime gaps no longer leave whole shifts missing — idempotent, safe to re-run. `ShiftBoundaryTicker` rewired to call the new proc; never throws. The die-cast shift-output entry picker (`Oee.Shift.getRecentOptions`) now lists the last 3 shifts so an operator can attribute output to a just-closed shift. Design spec `docs/superpowers/specs/2026-07-31-shift-boundary-reconcile-design.md`; dev seed `sql/scratch/seed_shifts.sql`. New **OI-38** logged: the shift subsystem intentionally stores/compares LOCAL time, diverging from the store-UTC convention (couples to OI-36). Full `MPP_MES_Test` suite green including the new `0046_Shift_Reconcile` tests and the untouched `030_Shift_lifecycle` procs.

---

## 🔖 2026-07-29 — Die Cast per-cavity lifecycle

Redesigned die-cast entry from a **one-basket-per-create origin mint** into a **per-cavity Open → accumulate → release lifecycle**: each cavity of a mounted die owns an independent accumulating basket that fills across operators and shifts, and is released to storage (its first route movement) only when the operator says it's full. Design spec: `docs/superpowers/specs/2026-07-28-diecast-per-cavity-lifecycle-design.md`. Executed as a 14-task SDD plan (`docs/superpowers/plans/2026-07-28-diecast-per-cavity-lifecycle.md`) subagent-driven, one review per task plus a final whole-branch review. Full task ledger: `.superpowers/sdd/progress.md`.

- **Migration `0045_diecast_per_cavity_lifecycle`.** New `Lots.LotStatusCode` **`Open`** (`BlocksProduction = 0`, appended Id — the pre-route accumulating state). New table **`Workorder.DieCastContribution`** (`Id, LotId FK→Lots.Lot, ShiftId FK→Oee.Shift NULL, PieceDelta INT CHECK >= 0, AppUserId FK, TerminalLocationId FK NULL, EventAt DATETIME2(3)`; indexes on `LotId` and `(ShiftId, LotId)`) — the per-shift net-good ledger. 4 new audit `LogEventType`s (`DieCastLotOpened` / `DieCastPieceContributed` / `DieCastLotReleased` / `DieCastLotVoided`, entity `Lot`).
- **Granularity: one Open LOT per (Tool, Cavity).** A 16-cavity die has 16 open baskets/LTTs. Cavity remains a LOT-level attribute via the existing `Lot.ToolCavityId` FK — cavity peers are not sublots.
- **New/changed procs.** `Lots.DieCastLot_Open` (mint a per-cavity Open basket at `PieceCount = 0`; LTT-validated; enforces one-open-per-(tool,cavity); gated on a published DieCast route). `Workorder.DieCast_GetShiftOutputBreakdown` (read — splits a die-wide gross shot count across a cavity's LOTs: a closed LOT keeps its already-credited good, the open LOT gets the remainder, floored at 0). `Workorder.DieCastShiftOutput_Record` (write — per-cavity net-good contributions, ADDITIVE scrap that is recorded but never decrements `PieceCount` and never closes the basket, plus whole-shot-loss fan-out across every open cavity LOT on the tool). `Lots.DieCastLot_Release` (Open → Good + move to WHSE storage — the LOT's first route movement, so it now appears in the Trim IN queue; optional final good/scrap entry; hard-rejects an empty basket or a missing warehouse location). `Lots.DieCastLot_Void` (empty-basket Open → Scrap). `Lots.Lot_GetOpenByTool` (running per-cavity open-basket list).
- **Reworked existing procs.** `Lot_GetShiftCavityTally` is now additive-correct (`PieceSum = SUM(PieceCount)` good-only with no scrap add-back; `RejectSum` reported separately — die-cast scrap has been additive since migration `0042`, so the old v1.1 add-back was double-counting). `Lot_GetWipQueueByLocation` excludes `Open` LOTs (`NOT IN ('Closed','Open')`) so an accumulating basket never surfaces to Trim prematurely. `Lot_GetAttributeHistory` gains a `Contribution` history stream sourced from `DieCastContribution`.
- **Ignition.** 6 new Core NQs + inert entity glue: `Lots.Lot.openDieCast/releaseDieCast/voidDieCast/getOpenByTool(+Instances)`, `Workorder.DieCast.getShiftOutputBreakdown/recordShiftOutput/registerShotLoss/mapBreakdownInstances`, `Oee.Shift.getRecentOptions/defaultEntryShiftId`. **`DieCastBody` view rebuilt**: an Open panel, a Shape-1 die-wide shift-output entry screen (per-cavity good + scrap repeater, shot-loss button, soft basket-ceiling warning — never a hard block), and a Currently-Open list with Release + Void actions. New components `CavityLotRow`, `OpenBasketRow`, `Popups/ConfirmAction`. The old `CheckpointPanel` and standalone `RejectPanel` are retired from the die-cast flow (grep-verified zero remaining references).
- **Locked decisions carried through the build:** the basket holds GOOD pieces only (scrap is additive and tracked as a separate metric, never subtracted from `PieceCount`); the operator enters the GROSS shot count and the system computes good = gross − scrap − shot-losses; accumulation is shift-scoped via `Oee.Shift`; `Item.MaxLotSize` is a soft basket ceiling (warns, never blocks); `Lots.v_LotDerivedQuantities.TotalInProcess = 0` for the whole accumulation phase (the basket isn't on its route yet).
- **Verification.** Full `MPP_MES_Test` suite **2225/0** (task-by-task, re-verified clean after each task — a few apparent failures during the build were concurrent-session `Run-Tests` collisions on the shared `MPP_MES_Test`, not real regressions). Migration + all touched repeatables deployed to `MPP_MES_Dev` (idempotent migration guard + `CREATE OR ALTER`, data-safe, no reset). Final whole-branch review (`59bd6d9c..31b60fcb`) traced every action chain view→glue→NQ→proc and **APPROVED for merge, no Critical/Important findings**.
- **⚠️ Owed — Jacques's live smoke.** The rebuilt `DieCastBody` view has no automated test; a 10-item smoke checklist lives in `.superpowers/sdd/task-11-13-report.md`. Known first-cut simplifications (all reasonable, none blocking): a smart shift-default ("first hour of a shift defaults to the *previous* shift") was **not** built — falls back to open/most-recent, operator-overridable; **close-and-open-next is not auto-chained** — Release and Open are two separate manual actions (the largest functional gap, by design for this pass); shot-loss registration is its own immediate proc call rather than being batched into the shift-output Submit.
- **Deferred Minors (consolidated in `.superpowers/sdd/progress.md`, none block merge):** (1) `DieCastShiftOutput_Record` / `DieCastLot_Release` don't pre-validate `defectCodeId` before the transaction — a nonexistent code throws an ungraceful in-txn error instead of a clean status row, and a deprecated code is silently accepted (UI-gated today via `includeDeprecated=False`, so low risk; recommended cheap fix is a pre-`BEGIN TRAN` existence + `DeprecatedAt IS NULL` guard); (2) the shift breakdown doesn't account for the open LOT's own prior same-shift contributions (correct for "gross entered once," but a double-submit on the reset panel could double-add the remainder); (3) `Lot_GetShiftCavityTally`'s `RejectSum` / `ShiftScrapTotal` and its `UpdatedAt >= @ShiftStart` window aren't shift-scoped, so a cross-shift open basket can over-count on the display-only right rail; (4) shot-loss fan-out filters on lot `Open` status rather than cavity-active status (behaviorally equivalent today); (5) a `Lots` CTE alias shadows the schema name in `DieCast_GetShiftOutputBreakdown` (readability only); (6) stale "as-cast pieces" wording survives in a couple of docstrings; (7) `WIP_GetQueueByLocation` header prose still says `<> Closed` though the code is the correct `NOT IN (Closed, Open)`.

---

## 🔖 2026-07-24 (session 2) — Inspect-tab form wired + Assembly consume hold-guard

Closed the last scaffold from the 2026-07-22 meeting workstreams (the third-party **Inspect** tab). Design doc: `docs/superpowers/specs/2026-07-24-inspection-form-and-consume-hold-guard-design.md`. Two coupled pieces:

- **The quality-capture form was NOT unbuilt — it already existed** as `Views/ShopFloor/InspectionEntry` (route `/shop-floor/inspection`; Phase-9, file-authored): LOT scan/resolve → active-spec load (`QualitySpec.getActiveVersionForItemOrEmpty`) → `AttributeRow` repeater → trigger dropdown → `QualitySample.recordFromEntries` → `Quality.QualitySample_Record` → Pass/Fail toast → history panel. The consolidated-smoke author simply didn't know this standalone screen existed. **Decision (Jacques): embed it as-is.** `ThirdPartyInspection` Inspect tab now embeds `InspectionEntry` (like the other two tabs embed ReceivingDock / AssemblyNonSerialized), replacing the monospace queue label.
- **Fail → one-tap Place Hold** added to `InspectionEntry`: new `view.custom.lastResult`; a `PLACE HOLD` button (`pf-btn-danger`, visible only when `lastResult = "Fail"`) → `placeHold` customMethod → existing `Quality.Hold.place(1, lotId=…)` wrapper (HoldTypeCode 1 = `Quality`). `record` sets `lastResult`; `resolveLot` resets it.
- **The check-out gate is the hold, not a bespoke rule.** Investigation of every lot-event proc found `Workorder.Assembly_CompleteTray` was the **lone consume path** filtering `<> Closed` only — it counted AND consumed **blocked** (Hold/Scrap, `BlocksProduction=1`) source LOTs, unlike every sibling (`MachiningOut_Mint` Good-only FIFO, `LotGenealogy_RecordConsumption` inline guard, all move/advance procs via `Lot_AssertNotBlocked`). **Fixed** (v1.1): both the §7 availability pre-check and the §B4 FIFO consume now require `sc.BlocksProduction = 0`. So a Fail→Hold LOT can no longer be consumed by assembly-out / third-party check-out — same universal block as everywhere else. Note: `Hold_Place` blocks by **status in place**, it does not relocate to the Sort Cage.
- **Verification:** new TDD test `sql/tests/0028_PlantFloor_Assembly/097_Assembly_CompleteTray_skips_held_source.sql` (held LOT not counted/consumed; FIFO skips held, takes Good). Full `MPP_MES_Test` suite **2163/0** (prior 2151 + 12). Fixed proc deployed to `MPP_MES_Dev` (data-safe `CREATE OR ALTER`, no reset). Both views file-authored (Designer closed) + `scan.ps1` clean. Concurrent-session `Core/…/Location/Location/code.py` left untouched.
- **⚠️ Owed — Designer/live smoke:** open a third-party inspection terminal → Check In a vendor LOT → Inspect tab shows the embedded form → record a Fail → PLACE HOLD appears → place hold → Check Out (AssemblyNonSerialized) now refuses to consume the held LOT; record a Pass on a fresh LOT → check out succeeds. Known wrinkle (accepted, embed-as-is): `InspectionEntry`'s own Close button navigates to `/` (leaves the whole tab screen) — future polish.

---

## 🔖 2026-07-20 — Cell Mount Card embedded on Plant Hierarchy (Tool Configuration section)

Completed the final outstanding item of the approved `docs/superpowers/specs/2026-06-16-cell-mount-card-design.md` — the PlantHierarchy embed. The data layer, NQs, `BlueRidge.Parts.Tool` methods, and the `CellMountCard` component were all already built + tested; only the view wiring remained.

- **What:** on the Config Tool Plant Hierarchy (`/plant`, MPP_Config), selecting a mount-compatible cell (a Die Cast Machine) now shows a **Tool Configuration** card (`CellMountCard`) **to the right of** the Location Details card — mount an unmounted compatible tool (dropdown + notes + Mount) or Release the currently-mounted one.
- **How:** `LocationDetailsPanel` + an `ia.display.view` embed of `BlueRidge/Components/Location/CellMountCard` wrapped in a new `DetailTopRow` (flex row, wrap); details `grow:1 basis:0`, embed `basis:460px shrink:0`. New `view.custom.cellContext` bound to `runScript(getCellMountContextOrEmpty, {selected.id})`; embed visibility gated on `{cellContext.IsMountTarget} && {mode} != "view"` (Jacques's "mount-compatible cells only" rule); `params.cellLocationId` ← `{selected.id}`. **No backend changes** — single-file view edit + `scan.ps1`.
- **Verified live** in the Perspective client: card renders for a `DieCastMachine` cell, positioned right of the details card (bounding-box check: x=824 vs 589, same row), "No tool mounted" empty state with TOOL dropdown + Mount button. JSON valid; `scan.ps1` clean ("Project Up to Date … by external").
- **⚠️ Working-tree note (pickled-data hazard):** `PlantHierarchy/view.json` re-pickled its `sortedTree`/`tree`/`editDraft` runtime data mid-session (a concurrent Designer/gateway save). I restored HEAD and re-applied only the logical edits, so the working-tree diff is a **clean 82-line insert**. Commit it before opening this view in Designer again, or Designer will re-pickle and bloat the next diff. Not yet committed (explicit-staging convention).

---

## 🔖 2026-07-16 — Shop-floor bug-fix pass + die-cast→Warehouse deposit + branch reconcile (`main` = `db4800d5`)

Worked a live shop-floor smoke list end-to-end on `jacques/working`; reconciled with a concurrent stream and promoted to `main` (`db4800d5`). Per-item root causes in `notes/2026-07-15_working-notes.md`.

- **Operation-template "template missing" (Trim OUT / Machining OUT / Machining IN) — route-aware fix.** All three resolved the template by the *role code* (`getActiveTemplateIdByCode("TrimOut"/"MachiningOut")` in views; `WHERE Code = N'MachiningIn'` in SQL) — but template codes are `T-Out-A`/`M-Out-A`/`M-In-A`, so the lookups always returned None. Fixed: new Core helper `OperationTemplate.getActiveTemplateIdForLot(lotId, role)` (TrimBody + MachiningOutSplit); `MachiningIn_RecordPick` resolves route-aware in-proc. Die Cast already used the route-aware path. **Convention now in CLAUDE.md.** This exposed 5 divergent methodologies → **prominent OPEN TODO at the top of this doc** + inventory in `notes/2026-07-16_operation-template-methodology-inventory.md`.
- **Die-cast → Warehouse auto-deposit.** Die-cast LOTs were minted at the machine and never moved to storage (the shift-tally proc already *assumed* they had). `Lot_Create` gains opt-in `@DepositToStorage BIT`: after birth at the machine, INLINE system-move to the Warehouse (`WHSE` by code), two movement rows (born-at-machine → moved-to-storage), soft-skip if no WHSE configured. Wired through the NQ + `Lot.create` + DieCastBody opt-in. Rollback-transaction tested.
- **Assembly insufficient-stock toast now names the short component(s).** `Assembly_CompleteTray` swapped `IF EXISTS` for a `STRING_AGG` short-list (`PartNumber (need X, have Y)`).
- **NavigationTree reusable component.** Extracted the DevLauncher plant-tree into `Components/PlantFloor/NavigationTree`; the Terminal Selector (unrecognized-IP gate) now embeds the tree instead of a flat table.
- **Trim IN validates/deposits at the AREA, not a press.** Removed the press picker (dedicated-flavor pattern per FDS-02-010); Movement-Scan destination + WIP queue + subtitle bind to `session.custom.terminal.zoneLocationId`/`zoneName`; fixed a mount-order race (embed read `session.custom.cell` before `startup()` set it).
- **Merge/reconcile.** `jacques/working` was 13 behind `origin/main`; merged main **cleanly** (auto-merged the concurrent MachiningOut-queue feature + warehouse wiring + the other stream's components-at-cell / InventoryManager / ReceivingDock / LotLabel / Zebra work), verified coherent, promoted to `main` by fast-forward.

**Dev DB (`MPP_MES_Dev`) applied this session — all data-safe, NO reset (live test data preserved):** versioned `0037`/`0038`/`0039` (were unapplied — quality-capture + PLC foundation incl. `Item.PlcId`) + all 349 repeatables re-run, then the route-aware `MachiningIn_RecordPick`, `Lot_Create` warehouse deposit, and `Assembly_CompleteTray` message.

---

## 🔖 2026-07-14 — PLC Integration built end-to-end (Plans 1–3) + `hunter/explore` merged

Executed the three PLC-integration plans on `jacques/working` (spec
`docs/superpowers/specs/2026-07-10-plc-udt-terminal-mapping-design.md`; plans
`…-plc-integration-plan1/2/3-*`). Ignition file-authoring; validated against the
`MPP_Sim` simulator, not live PLCs. **Everything committed + pushed to
`origin/jacques/working` (`d5d8a332`).**

### Merge reconciliation (`hunter/explore` → `jacques/working`, `3b58ad40`)
Clean auto-merge that brought in Hunter's **Phase 9 quality capture / CRT / global
trace** (migration `0037`). Two collisions resolved:
- **Migration number:** our PLC migration `0037` → **`0038`** (file + `MigrationId`
  + test dir `0037_PlcIntegration` → `0038_PlcIntegration`). Phase 9 keeps `0037`.
- **Audit Id:** both inserted `Audit.LogEntityType` Id 57 (Hunter=`QualitySample`,
  ours=`TerminalPlcDevice`). PLC bumped to **Id 58** + Id-or-Code guard added.
- Verified: full suite on a throwaway `MPP_MES_Test` = **2087/2087**, both
  migrations apply in sequence.

### Plan 1 — SQL foundation (pre-existing + reconciled)
Migration `0038` (`Location.PlcDeviceType` fixed-seed of 4 types, `Location.
TerminalPlcDevice` thin pointer terminal→UDT-instance, `Parts.Item.PlcId`) + 8
procs (`TerminalPlcDevice_Save/_GetByTerminal/_Deprecate/_GetByInstancePath`,
`Item_SetPlcId/_GetPlcId`, `SerializedPart_Mint @SerialNumber/_GetBySerial`) +
migration `0039` (audit LogEventType 67 `PlcHandshake`, 68 `PlcLineStop`).
`GetByInstancePath` (reverse lookup) + `0039` were added in Plan 3.

### Plan 2 — UDTs / simulator / Sim Panel / NQs
**`ignition/tags/`** (import-managed, NOT scan-synced): `generate_tags.py` (one
member catalog + the device manifest → all 3 artifacts, so real UDTs and the sim
can't drift) → **4 UDT defs**, **22 instances** (`PlcDevices.json`, all → `MPP_Sim`),
**`MPP_Sim_program.csv`** (325 writeable rows). Addressing scheme locked: member
appended directly to `{BasePath}`; separator lives in `{BasePath}` (dev `<device>/`),
so one def serves sim + every real device by swapping only params. **6 Core NQs**
(all `type:"Query"`). **Sim Panel** `/dev/sim/plc` (`BlueRidge.Sim` + `ScenarioRow`)
— device dropdown, per-type control panel (incl. 18-checkbox disposition grid),
scenario tracker. Jacques imported the tags/UDTs/CSV into the gateway.

### Plan 3 — watchers + dispatch + config editor + wiring
- **Entity layer:** `Common.Util.systemAppUserId()`, `Location.TerminalPlcDevice`
  wrapper, `Parts.Item.getPlcId/setPlcId`, `Lots.SerializedPart.getBySerial` +
  `@serialNumber` mint.
- **`Workorder.PlcWatcher`:** instance-member tag I/O, rising-edge guard,
  `WriteDisplayEnabled` gating (spec §5.1), `logInterface` (FDS-01-014), and
  `dispatch(tagPath, prev, cur)` → resolve terminal → route to the per-type watcher.
- **4 watchers** (`ScaleWatcher`, `SerializedMipWatcher`, `NonSerializedMipWatcher`,
  `TrayInspectionWatcher`), pure choreography over the procs (no business logic in
  Python). SerializedMip (mint against the FIFO front LOT) and TrayInspection
  (vision `VisionPartNumber` vs `Item.PlcId`; mismatch → line-stop) are the concrete
  ones; Scale weight-persistence/coupling + NonSerialized FG/count resolution are
  **flagged commissioning hooks, not faked**.
- **Config-Tool `/plc-devices`** editor (MPP_Config) + `PlcDeviceType_List`.
- **Wiring (Designer closed, edits done in files, `06117aaa`):** `onStartup` →
  `session.custom.plcDevices`; session prop declared; **Item Master → Identity**
  gains the `PlcId` field (loads via `getPlcId`, saves via `setPlcId` — separate
  procs, so no `Item_Get/_Update` change / no INSERT-EXEC test impact).

**Verification:** full SQL reset green (39 migrations + 349 repeatables deploy
clean; `0039` test 2/2); `scan.ps1` clean.

### ⚠️ Owed — the ONLY remaining steps (see `notes/2026-07-14_plc-commissioning-runbook.md`)
1. **A4 — one gateway Tag Change script** (Designer): watch the `[MPP]PlcDevices`
   folder, body `BlueRidge.Workorder.PlcWatcher.dispatch(str(event.tagPath),
   event.previousValue, event.currentValue)`. Safe as a folder-watch because
   `dispatch` + each `handleEdge` ignore non-trigger members. (Explicit path list:
   `ignition/tags/plc_trigger_tag_paths.txt`.) NOT hand-authored — the 8.3
   tag-change resource schema + the real tag paths are import-specific.
2. **Seed ≥1 mapping** via `/plc-devices` (so `dispatch` resolves).
3. **Simulator acceptance pass** — run the `/dev/sim/plc` scenarios against the live
   watchers on `MPP_Sim` (the no-hardware acceptance gate).
4. **Hardware commissioning** (gated on plant network + driver decisions): per-device
   OPC connections, flip instance params sim→real, tick `integration_manifest.csv`.

**Flagged open decisions** (spec §5.2/§11, watcher hooks): NonSerialized FG/PieceCount
source; scale raw-weight persistence + 5G0 scale↔MIP completion coupling; the
`len(PartSN)≥6`/interlock serial rule (proc-level); tray-close bookkeeping;
line-stop-vs-formal-Hold policy; Mitsubishi series / Pro-face / OmniServer-scale
driver specifics.

---

## 🔖 2026-07-07 — Smoke-findings fix pass (all 14 items) on `hunter/explore`

Worked `notes/2026-07-07_smoke_findings.md` end to end (per-item ✅/⚠️ annotations in that file). Full suite **1945/1945**; all Ignition edits file-authored + `scan.ps1`'d.

**SQL (TDD, new/updated tests):**
- `TrimOut_Record` **v1.2** — the cap is now the **COMBINED** shot+scrap sum vs `Lot.PieceCount`, and **scrap decrements the LOT** on the move (arrives at machining with its real remaining qty). Tests `0024/040+050` updated (happy path 18+2=20; boundary sum==pieces passes; combined-over rejects).
- `Item_ListEligibleForLocation` **v2.1** — optional `@OperationTypeCode` route-role filter (same predicate as the no-template gate) + new NQ `parts/Item_ListEligibleForLocationByRole`; the **Die Cast Item dropdown is now eligibility ∩ has-DieCast-route** (and re-pulls on the header Refresh). Property-based tests in `0023/050`. Existing callers unchanged (param defaults NULL).

**Terminal Selector:** search-bar table error fixed — `filterForSelector` received `{view.custom.terminals}` as Perspective ImmutableMaps in the runScript expression (`.get()` AttributeErrors; `extractQualifiedValues` doesn't unwrap those) → JSON round-trip to plain dicts. Scan field + search bar centered (icon offset balanced with a trailing spacer; both input boxes 360px).

**Die Cast:** prefill repointed to the real **parts-per-basket** column — `Item.MaxLotSize` (repurposed as PartsPerBasket per Data Model v1.9; `DefaultSubLotQty` kept only as a dev-data fallback). Reject verified **already cavity-scoped** mechanically (rail cavity → `Lot_GetLatestForToolCavity` → newest open LOT on that cavity, tested 0022/070); RejectPanel label reworded cavity-first ("Rejecting Cavity N - charges newest open LOT ..."); **real bug fixed**: `submitCreate` classified a *typed* cavity by `int()` parse, so a typed cavity NUMBER was treated as a ToolCavityId — now classified by membership in the dropdown option ids; typed values become the manual CavityNote (D2). Scrollbar overflow pass (ContextBar, CumulativeCard, ActiveCavityCard, ToolCavityRow); both cavity dropdowns pinned `width:100%` (resize-glitch theory: transient scrollbar shrank the field; the options popup tracks field width). **Cell picker moved into the Active Cell ContextBar**, gated by a new `cellPickerEnabled` body param — DieCastShared passes true (its separate PickerBar deleted), DieCastDedicated stays pickerless.

**Trim:** new reusable `Components/PlantFloor/Trim/InventoryRow` card (Machining QueueRow styling: position / LOT / part · pcs · arrived / Good-Hold pill). IN panel's table → card repeater; OUT panel restructured to **two columns** — tappable pick list left (Select button + selected highlight, `trimLotSelected` page message), form right (scan, selected-LOT-by-name label, machining-line dropdown, shot/scrap counts, combined-cap help, Trim OUT). `activeLotName` plumbed through scan-resolve / select / submit-clear.

**LOT Detail:** history-row time fixed by moving date math to Python — new `Lot.mapHistoryInstances` precomputes `EventAtDisplay` (MM/dd HH:mm) + `EventAgo` ("3h ago"); HistoryRow's MetaLabel just concatenates (the Date serialized to a string on the repeater param hop, so `dateFormat`/`dateDiff` passed the raw value through). If the Paused tab shows the same symptom, PauseRow gets the identical treatment.

**⚠️ Open for Jacques:** (1) if cavity rejects must record with **no open LOT** on the cavity (pure machine scrap), `RejectEvent.LotId` needs a schema change — current design charges the newest open LOT for traceability; (2) weight-prefill semantics (UnitWeight × count) still assumed; (3) dev items need `PartsPerBasket` (`MaxLotSize`) populated via the Item screen for the prefill to show real values.

**⚠️ Owed — re-smoke.** Dev DB was reset by test runs — reseed (`sql/scratch/smoke_seed_phase4.sql` etc.) + **restart the gateway** before smoking. File-edited existing views this pass: TerminalSelector, DieCastBody, DieCastShared, RejectPanel, TrimBody, LotDetail, HistoryRow (+ new `Trim/InventoryRow`); Core script modules Terminal / Item / Lot also changed. Keep Designer closed on the edited views until the scan is picked up (scan already run 2026-07-07).

---

**Prior header note (main, 2026-07-07):** **Terminal-mint model redesign EXECUTED end-to-end on `jacques/working` — the rename-BOM thread is unwound; the ROUTE is now the single source of truth for terminal FIFO + part identity.** SQL fully built + validated (full suite **1887/1887**, only the pre-existing `010_Parts_codes_crud` thrower); migrations `0035` (`Parts.OperationRoleKind` Advance/OriginMint/ConsumeMint) + `0036` (drop cell-coupling); Machining OUT is a consume-**mint** (`MachiningOut_Mint`, Consumption genealogy) not a split; route-legality validation at publish; ranked eligible-FG read; `Lot_Split` demoted to exception-only; `seed_demo` + demo routes (`029`) re-authored to the mint model. Ignition NQs/scripts/**views** file-authored + scanned. Docs: Data Model updated (`OperationRoleKind` + v2.0 changelog). Spec: `docs/superpowers/specs/2026-07-07-terminal-mint-model-and-rename-bom-removal-design.md`; plans `...-plan1/2/3-*`. **Owed:** Designer smoke of the mint / route-driven-queue / ranked-FG views; FDS-06-007/05-033/06-008 prose rewrite; JP backup (`sql/scratch/seed_jp_validation.sql`) still old-model; vestigial dest-dropdown on MachiningOutSplit. See the 2026-07-07 section directly below. Prior header note (2026-07-06 second session): **Jacques 2026-07-06 meeting task list worked on `hunter/explore`: 21 of 24 items fixed, tested, committed (full suite 1934/1934). 3 items open. Designer smoke owed.** Prior header note (earlier 2026-07-06): **Spec 2 (machining/assembly plant-floor flow reconciliation) EXECUTED end-to-end on `jacques/working`. All SQL built + verified (full suite 1910/1910 green); Ignition backend + views file-authored + scanned. A4 (serialized FG-LOT) deferred by decision; M3 view-repoint deferred. Awaiting Jacques's Designer smoke of the views. See the Spec 2 section below.** Prior header note (2026-07-02):

---

## 🔖 2026-07-07 (second session) — Worked the 2026-07-06 working-notes list end-to-end

Merged `origin/main` (Hunter's `97310ac` Route-Category cascade + `7c7dffe` notes) into
`jacques/working` — clean auto-merge, no conflicts. Then worked every item in
`notes/2026-07-06_working-notes.md` (per-item resolution log at the top of that file).

- **Operation Template management (Config):** filter dropdown repointed **type → CATEGORY**
  with a one-click "All Categories" reset; **creation popup** now a **Category → Operation
  cascade** (auto-selects when a category has one type, e.g. Die Cast); selection list ordered
  **Die Cast → Trim → Machining & Assembly** (by `OperationCategory.Id`). New entity helper
  `OperationTemplate.getOperationTypesByCategory`; `search()` filters+orders by category.
- **Route steps:** dead `OperationAreaName` read removed from `RouteTemplate._mapSteps`
  (repointed onto the v4.1 proc's Category/Type). The Category→Operation route-step cascade
  itself came in with `main`'s `97310ac`.
- **`Parts.Item_Deprecate` → v3.0 CASCADE-deprecate** (the big one): deprecating a part now
  **cascade-deprecates its owned config** (RouteTemplate / Bom-as-parent / ItemLocation /
  ContainerConfig) and **blocks ONLY on a live (non-terminal, i.e. not Closed/Scrap) LOT**;
  a part used as a BomLine child in another part's BOM is neither blocked nor cascaded. Per-
  dependent audit rows + cascade counts in the Item audit NewValue. New suite
  `sql/tests/0008_Parts_Item/020_Item_Deprecate_cascade.sql` (**15/15 green**). Item Master
  deprecate now routes through a `ConfirmDestructive` cascade-warning popup (was immediate).
- **Terminal-FIFO / `CoupledDownstreamCellLocationId` note:** closed as **OBE** — already
  answered by the 2026-07-07 terminal-mint redesign (route-driven queue; coupling column
  dropped in `0036`).

**Verification:** full suite on a throwaway `MPP_MES_Test` = **1886/1887**; the single
failure (`0024/060 [WipQueue] fresh LOT in MachiningIn`) is **pre-existing + environmental**
— it resolves demo-seed rows (`6MA-M` / `MA1-FPRPY-MOUT` / `DEV`) that `Run-Tests -SkipDemoSeed`
omits, unrelated to this session. Ignition changes file-authored + `scan.ps1`'d.

**Owed:** Designer smoke of the Op-Template Category filter + cascade creation popup + the
Item Master deprecate confirm (existing-view edits, authored with Designer closed).

---

## 🔖 2026-07-07 — Terminal-mint model: rename-BOM thread unwound, route = single source of truth

**What & why.** The Machining & Assembly flow had accreted a "rename-BOM" mechanism (FDS-05-033) that minted a machined LOT at Machining IN by "consuming" a 1-line BOM. Commits `348762e`/`1e46c60` half-unwound it, leaving `HasRenameBom` as a fragile queue discriminator. This redesign removes it entirely and re-bases terminal FIFO + part identity on the **route**. Brainstormed → spec → 3 plans → executed on `jacques/working`.

**The model (spec `docs/superpowers/specs/2026-07-07-terminal-mint-model-and-rename-bom-removal-design.md`):**
- **Route is the single source of truth.** A terminal of `OperationType` role R shows LOTs whose lowest-`SequenceNumber` *pending* route step has role R. "Pending" depends on **`OperationRoleKind`** (new): `Advance` (satisfied by a `ProductionEvent`), `OriginMint` (DieCast — always satisfied), `ConsumeMint` (Machining/Assembly OUT — terminal step, stays queued until the LOT closes).
- **Model Y (mint-step placement):** the consume-mint is the **final route step of the *consumed* part**. A casting's route carries `…→MachiningIn→MachiningOut` (MachiningOut mints the SubAssembly, consuming the casting). The SubAssembly's route picks up *after* birth (`AssemblyIn→AssemblyOut`). Finished goods are the **output** of Assembly OUT and are **unrouted**.
- **Decision C:** a SubAssembly identity exists only when the line has a Machining OUT terminal (expressed purely as route authoring).
- **Consume-mint** = mint a new part-number LOT by consuming input(s) per the *produced* part's BOM (`Consumption` genealogy), derived via BOM + line-eligibility, operator-overridable. Flexible operator qty (prefill `DefaultSubLotQty`). `Lot_Split`/`Split` demoted to exception-only.

**Landed (all committed, ~24 commits):**
- **SQL** — `0035_operation_role_kind` (table + `OperationType.OperationRoleKindId`); `0036_drop_coupled_downstream_cell` (dropped `CoupledDownstreamCellLocationId` + `Workorder.MachiningOut_AutoComplete`); `Lots.Lot_GetWipQueueByLocation` v3.0 (route-driven, `@OperationTypeCode`, dropped `HasRenameBom`/`HasLineEvent`); `Workorder.MachiningOut_Mint` (replaces `RecordSplit`); route-legality validation in `Parts.RouteTemplate_Publish`; `Parts.Item_ListEligibleFinishedGoodsRanked`; `Lot_Split` header scoped exception-only; `seed_demo.sql` machining threads rebuilt on the mint (authentic cast→machined `Consumption`); **`029_seed_item_routes.sql` demo routes re-authored** to the mint model. Full suite **1887/1887** (only pre-existing `010_Parts_codes` thrower).
- **Ignition** (Core NQs + scripts + shop-floor views, file-authored + scanned) — `MachiningOut_Mint` NQ + `Machining.mint()`; `Item_ListEligibleFinishedGoodsRanked` NQ; `Lot_GetWipQueueByLocation` NQ/script `@operationTypeCode` (last arg — existing bindings unaffected); MachiningIn/MachiningOutSplit/AssemblyNonSerialized views repointed (queue roles, mint action, ranked-FG default); retired coupling PLC/NQs.
- **Docs** — Data Model: `OperationRoleKind` table + v2.0 changelog row (flags stale coupling/split prose).
- **Data preservation** — Jacques's live 4-part 5G0 config was captured to `sql/scratch/seed_jp_validation.sql` before any schema change (his Dev DB was never destructively reset; verified intact, 0 LOTs lost).

**Verified live.** A `6MA-C` casting walks the route-driven queue: fresh → `TrimIn` queue; after Trim + Machining-In events → `MachiningOut` queue (ready to mint). `MachiningOut_Mint` mints the SubAssembly with `Consumption` genealogy (12 assertions green).

**Next-session pickup / owed:**
1. **Designer smoke** of MachiningOutSplit (mint), the route-driven queues, and the Assembly ranked-FG default against a demo-seeded gateway (`Reset-DevDatabase` default seeds `seed_demo`, but note it `USE MPP_MES_Dev` — see gotcha).
2. **FDS prose** — FDS-06-007 / 05-033 / 06-008 still narrate rename-at-IN / split / coupling; Data Model `CoupledDownstreamCellLocationId` / `DefaultSubLotQty` / `RequiresSubLotSplit` prose flagged in the changelog.
3. **JP backup** (`sql/scratch/seed_jp_validation.sql`) still holds Jacques's *old-model* `5G0-c` route (ends at MachiningIn); re-author to Option A (`…→MachiningOut`; `5G0-SA`→AssemblyOut; `5G0-FG` unrouted) when he wants his Dev fixture to match.
4. Cosmetic: delete the vestigial destination dropdown on MachiningOutSplit (Designer); per-screen queue-role tuning for AssemblyIn/Serialized/Trim (left showing-all on purpose).
5. Pre-existing (unrelated) `Parts.DataCollectionField_Create` Msg 3915 thrower (`010_Parts_codes_crud`) — the suite's non-zero exit; worth a separate fix.

**Testing gotchas learned this session:** (a) `seed_demo.sql` pins `USE MPP_MES_Dev` — running it via `-d <other>` still hits Dev; validate the demo against a demo-seeded DB by copying with the `USE` swapped. (b) A throwaway `MPP_MES_Test` (`Reset-DevDatabase.ps1 -DatabaseName MPP_MES_Test -SkipDemoSeed`) is the clean way to validate migrations/procs without touching Jacques's hand-built Dev. (c) `sqlcmd.exe` can't open Git-Bash `/tmp` paths — write temp SQL under the repo. (d) Jacques's Dev has only his 4 hand-built parts, NOT the `020` demo dataset — so `029`/`seed_demo` (demo items) can't run there; his Dev is migrations + manual config.

---

## 🔖 2026-07-06 (second session) — Jacques meeting fixes: 21 of 24 items landed on `hunter/explore`

Worked `notes/2026-07-06_jacques-meeting-tasks.md` end to end (per-item annotations live in that file). Full suite **1934/1934** after all proc changes. All Ignition edits file-authored + `scan.ps1`'d.

**Data integrity (SQL, all with new/updated tests):**
- `TrimOut_Record` v1.1 — required `@SourceLocationId` (the terminal's Trim zone) **blocks double checkout** (LOT must sit at/under the zone; after checkout it sits at the destination, so a re-scan rejects); `ShotCount`/`ScrapCount` capped at `Lot.PieceCount`. NQ + entity + TrimBody pass `session.custom.terminal.zoneLocationId`.
- `Lot_GetShiftCavityTally` v1.1 — **scrap-inclusive** (RejectEvent_Record decrements PieceCount, so rejected qty is added back per lot) + new `RejectSum` column. New tests 0022/050.
- `Lot_GetAttributeHistory` v1.2 — Movement details carry location codes + recording terminal; new **Production** and **Reject** timeline streams. New `Lots.Lot_GetScrapSummary` (+ Core NQ) feeds the LOT Detail **Total Scrap** KPI. New tests 0022/060.
- `Location_ListMachiningDestinations` v1.1 (**line-resident**) — Trim OUT destinations are the machining **production lines** (WorkCenter tier with a Machining-In cell child); checkout parks the LOT at the line. Also fixes a latent mismatch (deposit-at-MIN-cell vs Machining-In queue read at the LINE via zoneLocationId). Test 0024/060 rewritten; `smoke_seed_phase4` repointed to MA1-COMPBR.
- `Location_ListForEligibilityPicker` v1.1 — eligibility authoring at **Area + WorkCenter tiers only**; terminals/printers structurally excluded. Test 0009/050 extended.

**Die Cast entry rework (DieCastBody + RejectPanel):** the SQL-computed `ShiftShots` is now actually displayed (it was never bound — the "null"/missing shots complaint) plus a per-cavity scrap line; **no-template gate** on Create via route-role resolution (`getActiveTemplateIdForRoute(itemId, 'DieCast')`) with a red warning under the Item dropdown (parts whose routes lack a DieCast-role step are blocked — intended, but route data must carry roles); header **Refresh** button + `refreshToken` arg on the mounted-tool/shift-tally bindings (also bumped on create/reject — replaces the old direct write into a bound prop); right rail consolidated to **one card** (cavity, KPIs, reject entry, peer tally); RejectPanel shows **"Rejecting against <LOT>"** (attribution rides the active LOT's stamped cavity — flagged to Jacques that the right-rail cavity selection does NOT retarget it); item pick prefills Piece Count = `Item.MaxParts` and Weight = `UnitWeight x MaxParts` (**weight semantics assumed — confirm**).

**Trim:** IN panel shows a **Currently-in-Trim** table; OUT panel has the same inventory as a **selectable pick list** (tap sets the active LOT; scan retained); OUT submit **stays on-screen** (form clears; no LOT Detail nav); MovementScan capacity label rendered a raw backslash-u221e escape under the Eligible label — now ASCII `(no cap)` (likely the reported "null").

**Config Tool:** Routes draft-step editor **migrated off Area to OperationType roles** — its Area dropdown fed a deprecated shim returning ALL templates (Jacques's un-scoped dropdown); now Operation Type → templates-of-that-role cascade, and the **Data Collection column resolves at pick time** via new `OperationTemplate.getFieldSummary` (was blank on drafts until save+publish). No save-contract change. Terminal selector: 100-row default + live search. Create LOT popup: button spacing (no-wrap, 640px, 44px buttons). **FDS commentary stripped from all operator-visible view text** across MPP + MPP_Config (script comments kept; residual sweep zero).

**Still open (3):** (1) **cavity-this-shift over-listing** — query verified correct (every Active cavity of the mounted die, by design); either the die's cavity config has extras or Jacques expects only-ran-this-shift — needs his call; (2) **cavity dropdown resize glitch** — not reproducible statically, smoke-list item; (3) **Trim IN "null" under Eligible** — all operands isNull-guarded; the capacity-label fix is the likely culprit, confirm on smoke.

**⚠️ Owed — Designer smoke.** Dev DB was reset by test runs — reseed smoke data (`sql/scratch/smoke_seed_phase4.sql` etc.) and **restart the gateway** (stale-connection memory) before smoking: DieCastBody (KPIs incl. scrap, refresh button, gate warning, prefill, one-card rail, reject target label), TrimBody (inventory tables, line destinations, double-checkout toast, stay-on-screen), TerminalSelector (100 rows + search), ConfirmCreateLot spacing, LotDetail (Total Scrap KPI, Production/Reject rows, pause date format), MPP_Config Routes tab (role cascade + pick-time Data Collection). DieCastBody / TrimBody / Routes / DraftStepRow / RejectPanel / MovementScan / LotDetail / HistoryRow / PauseRow / TerminalSelector / ConfirmCreateLot were **file-edited existing views** — keep Designer closed on them until the scan is picked up, and expect Files-vs-Gateway prompts if a stale Designer cache exists.

---

## 🔖 2026-07-06 — Spec 2 (machining & assembly flow) executed

Executed `docs/superpowers/plans/2026-07-02-machining-assembly-plant-floor-flow.md` (in-session TDD + two parallel subagents on a second DB `MPP_MES_Ttest` for the independent read procs / MachiningOutSplit view). Branch `jacques/working`.

**SQL — done + verified (full suite 1910/1910, 0 fail; only pre-existing `010_Parts_codes_crud` throws):**
- **M1** `MachiningOut_RecordSplit` → **extract-one / partial-remainder**: `SUM(children) <= parent`, parent decremented + stays OPEN, Closes only at 0. Tests 070/075/080 rewritten (`b8a95f1`).
- **A1** migration **`0034`** `Lots.ContainerTray.FinishedGoodLotId` (BIGINT NULL FK → Lot + filtered-unique, 1:1 tray↔LOT) (`74b4687`). *(Spec 1 had taken 0032/0033, so this is 0034 not the plan's 0032.)*
- **A2** `Workorder.Assembly_CompleteTray` — mints FG LOT (tray = LOT), consumes `BOM × PieceCount` FIFO into it, attaches/auto-opens the Container, returns `ContainerFull`. **Delegates container completion (AIM + ShippingLabel) to the existing `Container_Complete`** (decision 2026-07-06 — the built `Container_Complete` hard-requires an AIM pool id for the NOT-NULL ShippingLabel, so "stub AIM + insert label" wasn't clean). Inlines all sub-mutations per the INSERT-EXEC rule. Test `092` (`a698dc9`).
- **A3** retired BOM consumption from `ContainerTray_Close` (now a thin tray-insert helper); 070 deleted, 075 → no-consume guard, 077 backward-trace rewired through the FG LOT (`115860d`).
- **I1** `Lots.Lot_GetLineInventoryByPart` (on-hand grouped part→lot FIFO, ET) (`dfe2143`, Ttest subagent).
- **K1** `Workorder.FinishedGoods_GetProducedSummary` (derived LotCount/PartCount over tray-linked FG LOTs) (`6da83b5`, Ttest subagent).

**Ignition — file-authored + scanned (⚠️ NOT Designer-smoked):**
- **A5/M3/I2 backend** — Core NQs `workorder/Assembly_CompleteTray`, `parts/OperationTemplate_GetForRouteRole`, `lots/Lot_GetLineInventoryByPart` + entity methods `Assembly.completeTray`/`getEligibleFinishedGoodsForDropdown`/`handleTrayComplete`, `OperationTemplate.getActiveTemplateIdForRoute`, `Lot.getLineInventoryByPart` (`beca0fb`, `b71225d`).
- **A6** `AssemblyNonSerialized` — Complete-Tray button now calls `completeTray` (mints FG LOT); existing Complete-Container button handles the delegated completion; persistent finished-good dropdown (shown when no container open → `completeTray` auto-opens one); container custom prop now carries `ItemId`; **Inventory** button opens the new popup (`e07a477`, `b71225d`).
- **I2** new `Components/PlantFloor/InventoryManager` popup (on-hand table + scan-to-check-in via `moveToValidated`) (`b71225d`).
- **M2** `MachiningOutSplit` reworked to a single extract-one form (parent stays open) (`0ecf900`).
- **D1** docs — FDS 1.6, Data Model 1.9u, OIR 2.20 (OI-32 closed), docx regenerated (`7c28449`).

**Deferred (documented):**
- **A4 serialized FG-LOT** — chicken-and-egg (`SerializedPart.ProducingLotId` NOT NULL at etch time vs FG LOT minted at completion); needs customer input on etch-vs-completion ordering. Note: `notes/2026-07-06_A4-serialized-fg-lot-deferred.md`.
- **M3 view repoint** — resolver + NQ are live, but the MachiningOutSplit view still uses `getActiveTemplateIdByCode` (repointing to route-role resolution would break parts whose route lacks a `MachiningOut` step until route data carries OperationTypes).

**⚠️ Owed — Designer smoke (the CLI-impossible step; run `.\scan.ps1` first, no gateway restart):** exercise AssemblyNonSerialized (complete a tray → FG LOT mints + consumes BOM; full container → Complete → ShippingLabel; FG dropdown auto-opens a container; Inventory button opens the popup), the InventoryManager popup (on-hand list + scan check-in), and MachiningOutSplit (extract a sub-LOT < parent → parent stays open; extract to zero → closes). Seed dev data via the smoke scripts; the operator session needs `session.custom.cell.locationId` + `appUserId`. A5 caveat: `getEligibleFinishedGoodsForDropdown` reuses `Item_ListEligibleForLocation` (all eligible items at the cell, not strictly ItemType=FinishedGood) — tighten to FG-only if MPP wants. AssemblyNonSerialized's `trayPosition` draft field is now vestigial (completeTray auto-assigns position).

---

**Prior header note (2026-07-02):** — **PROJECT_STATUS had drifted badly out of sync. Corrected: all Arc 2 plant-floor phases (5 Machining, 6 Assembly, 7 Hold/Sort, 8 Downtime, 9 Shipping) are in fact BUILT (SQL + Ignition views), migrations `0027`–`0029` with test suites, landed via the `hunter/explore` merge (PR #2). The one unbuilt external is AIM integration. Two design specs committed today for the operation-type restructure + machining/assembly reconciliation to the customer discovery. See the 2026-07-02 section directly below.** Prior header note (2026-06-15): (**Phase 4 fully specced — two design specs committed (SQL foundation + gateway/front-end); Phase 3 die-cast SQL reviewed, stale-base/Id-collision caught, cleaned up by the original agent + committed; Phase 3 front-end spec committed. See the 2026-06-15 section directly below.** Earlier context follows.) Prior note 2026-06-08: (**Eligibility-style config editors — backend COMPLETE + verified (SQL suite 1196/1196), Perspective UI drafted pending Designer smoke.** 3 bundled SaveAll procs (`Tools.ToolAttribute_SaveAll` hard-delete + per-DataType validation; `Tools.ToolCavity_SaveAll` insert/update-only + number-immutable + Scrapped-lock; `Parts.OperationTemplateField_SaveAll` reconcile + reactivate) + 3 NQs + entity `saveAttributesAll`/`saveCavitiesAll`/`saveFieldsAll`/typed options; Perspective UI file-authored for Attributes (type-aware) / Cavities / Assignments (inline mount, non-draft) / Operation-Template Fields + Tools & OperationTemplates parent dirty-gating; MountToCell/AddAttribute/AddCavity popups retired. Subagent-driven w/ per-task spec+quality review, commits `81f7a82`..`33b94e5` on `jacques/working`. **⚠️ Visual Designer smoke (Phase H3) NOT yet done — that is the next step; no Perspective session has exercised these views.** See Recently closed + Next Session Pickup. Also 2026-06-08: **Plant Floor (Arc 2) phased plan validated + corrected to v1.3 (MVP gaps ratified in-scope as Phase 9; migrations re-baselined to 0020-0027); task list (CSV + xlsx) generated — see Recently closed.) Earlier 2026-06-05 (**Tools Config Tool — Mount-to-Cell tool-type filter + three bug-fixes (Retire→status, NULL rank pills, "null" description) applied to `MPP_MES_Dev` but ⚠️ UNCOMMITTED in working tree; eligibility-style config-editor redesign brainstormed + spec'd + committed `7f41a2d`, implementation NOT started; Data Model → v1.9o. See today's Next Session Pickup + Recently closed.**) **Also 2026-06-05 (parallel session):** re-enabled the 13 legacy-seed-coupled SQL tests via dynamic location lookups (suite **1165/1165**); ran an Ignition entity-script code-review pass and applied buckets 1–3; fully configured demo item **5G0** across every Item Master tab; fixed the Routes-tab StateBadge undeclared-custom-prop error and codified a new "pre-declare bound custom props" convention. Earlier — 2026-05-29 (**Quality Spec Config Tool — built (Phases A–H) AND smoke-tested + polished; functional end-to-end.** Backend: migration 0017, 3 net-new procs, readable-audit on all quality procs, **SQL tests 1161/1161**; 14 NQs; entity script; `/quality-specs` master-detail screen + `QualitySpecAttributeRow` + `NewSpecModal` + route/nav + Item Master cross-nav. Smoke fixes landed today: spec library + Version History converted table→flex-repeater (legible, no squish/mojibake); `numeric-entry-field` component fix; `Lower≤Target≤Upper` save validation (proc-enforced); left-list refresh after publish/etc.; hide UOM/Target/Lower/Upper on non-Numeric attrs (meta.visible); `+ New Version` clones the *selected* version; date-resolved per-version state **Active/Scheduled/Superseded** (SQL `ListBySpec.State` + `GetActiveForSpec` tiebreaker) surfaced in dropdown + history pills. Also earlier today: audit-readability refactor COMPLETE (Slices 1–8 + 2.5). Two visual smokes still pending: the ConfigChangeDetail color-diff (Slice 2.5) and the new Quality state badges.)

---

## 🔖 2026-07-02 — Status doc reconciled to reality + customer-discovery design (operation-type restructure + machining/assembly reconciliation)

**Two things happened: (1) discovered PROJECT_STATUS was badly stale, (2) brainstormed + specced the customer's machining/assembly discovery into two committed specs.**

### The stale-status correction (ground truth is the code, not this doc)
Grounding for the design work (5 read-only subagent passes over SQL + Ignition + FDS + Data Model) revealed that **all Arc 2 plant-floor phases are already built**, not just through Phase 8 as this doc implied:
- **Migrations `0027` (Machining), `0028` (Assembly + Container/Tray/Serial/ShippingLabel/AIM pool), `0029` (Hold/Sort/Shipping/AIM)** — each with a full `sql/tests/00{27,28,29}_*` suite.
- **Procs:** `MachiningIn_PickAndConsume`, `MachiningOut_RecordSplit`, `MachiningOut_AutoComplete`, `Assembly_ScanIn`, `ConsumptionEvent_RecordWithBomCheck`, `ContainerTray_Close`, `Container_Open/_Complete/_Ship`, `ContainerSerial_Add`, `Location_ListMachiningDestinations`, `Item_ListEligibleForLocation`, plus Hold/Sort/Shipping procs.
- **Ignition views:** `MachiningIn`, `MachiningOutSplit`, `AssemblyIn`, `AssemblyNonSerialized`, `AssemblySerialized`, `HoldManagement`, `ShippingDock`, `SortCageWorkflow`, `ReceivingDock` (+ Dedicated/Shared/Body triads for DieCast/Trim).
- Landed via the **`hunter/explore` merge (PR #2)**. **AIM integration is the one unbuilt external.** Designer-smoke status of the newest views was **not** independently verified this session.
- ⚠️ **Older sections of this doc below are pre-`hunter/explore` and describe phases as unbuilt/pending that are now built. Trust the code + test suites over the older narrative until a full rewrite is done.**

### Customer discovery + two design specs (committed on `jacques/working`)
Customer walkthrough (2026-07-01/02) of the machining/assembly lines drove a design session (brainstorming → grounding → specs). Key model decisions: **route vs BOM separation**; operation templates become **area-agnostic, classified by a new `OperationType` role** (terminals resolve the right template by role, not by Area); **machining-out = extract-one sublot** (parent stays open — executes pending UJ-03); **assembly-out mints a finished-good LOT (tray = LOT)** consuming `BOM × PieceCount` FIFO while **retaining the Container** as wrapper (future RFID + pending AIM); **tray ↔ LOT is 1:1**, container holds 1→n trays; reusable **line inventory check-in popup**.

- **Spec 1** `docs/superpowers/specs/2026-07-02-operation-type-model-restructure-design.md` (commit `2fa35e8`) — drop `OperationTemplate.AreaLocationId`, add `OperationTypeId` FK → new `Parts.OperationType` (8 roles) + `Parts.OperationCategory` (3 groups). Full change inventory (migration + backfill, 6 procs, 4 NQs, entity script, 2 Config-Tool views, tests, FDS/Data-Model edits). Config-vs-dev tagged. **Decisions D1–D3 resolved by Jacques: OperationCategory = table; both tables fixed-seed; the 3 part-specific template→role mappings confirmed.** **Implementation plan next (writing-plans).**
- **Spec 2** `docs/superpowers/specs/2026-07-02-machining-assembly-plant-floor-flow-design.md` (commit `bfea396`) — **reconciliation deltas** onto the built Phase 5/6 (keep/change/add): machining-out extract-one, `Assembly_CompleteTray` orchestrator (mint FG LOT + consume BOM FIFO + manage container), `ContainerTray.FinishedGoodLotId`, persistent finished-good dropdown, inventory popup, finished-goods KPI. 5 open decisions (D1–D5) in §11. **⏳ Jacques still reviewing Spec 2.**

**Next session pickup:** Spec 1 implementation plan (in progress); Spec 2 pending Jacques's review of the §11 decisions; a full PROJECT_STATUS rewrite to reflect the post-`hunter/explore` built state is owed.

---

## 🔖 2026-06-17 — Arc 2 Phase 8 (Downtime + Shift Boundary) built end-to-end (SQL + 4 views), pending Designer smoke

**Built on `hunter/explore`** (fast-forwarded from current `main`/`f14b305`). Spec + plan committed today (`docs/superpowers/specs/2026-06-16-arc2-phase8-downtime-shift-design.md`, `docs/superpowers/plans/2026-06-16-arc2-phase8-downtime-shift.md`).

- **SQL — migration `0026`:** `Oee.DowntimeEvent` table + `DowntimeReasonCode.StandardDurationMinutes` delta + `Break` reason type/codes seed + audit seeds. Procs: `DowntimeEvent_Start`/`_End`, `DowntimeReasonCode_Assign` (B7 late-binding), `EndOfShiftEntry_Submit` (FDS-09-013), `DowntimeEvent_GetOpenByLocation`, `Lot_GetInProcessByLocation`, `ShiftHandover_Acknowledge`, `DowntimeEvent_GetOpenSummary`. **SQL suite 1629/1629.**
- **Ignition:** `BlueRidge.Oee.DowntimeEvent`/`Shift`/`DowntimePlc` scripts + oee NQs (all Core); **4 plant-floor views in MPP** — Downtime Entry (smoked working end-to-end), End-of-Shift Time Entry, Shift-End Summary, Supervisor Dashboard — + routes (`/shop-floor/{downtime,end-of-shift,shift-summary,supervisor}`); `DowntimePlcWatcher` gateway timer (sim-ready, no-op until `_WATCH` configured at commissioning); **toast listener** wired into the MPP session (`Core/Components/NotifyHost` + `Toast` view copied to Core + hidden overlay dock).
- **Decisions/divergences:** breaks as fixed reason codes w/ uniform durations (**OI-37** raised); manual downtime defaults to `Operator` source; ET reads `CAST … AS DATETIME2(3)`.
- **Debugging lessons (memories added):** Perspective `bidirectional` must be **inside** binding `config`; a raw `datetimeoffset` return breaks the Ignition JDBC read (cast to `DATETIME2(3)`); plant-floor `pf-*` design system ≠ Config-Tool `screen-active`/`btn`.

**Pending:** Designer smoke of End-of-Shift / Shift-End Summary / Supervisor Dashboard (Downtime Entry already verified working); dashboard Paused-LOTs + Shift-Availability tiles are stubs (need aggregate reads / OEE calc — AIM + Print-Failure tiles are legitimately Phase 7); End-of-Shift ±15-min window-gating not wired (always visible); confirm MPP break durations (OI-37). Not yet pushed to remote; OIR `.docx` regen pending.

---

## 🔖 2026-06-16 — Phase 4 (Movement + Trim + Receiving) BUILT end-to-end (SQL green; Ignition file-authored, Designer-smoke owed)

Plan: `docs/superpowers/plans/2026-06-16-arc2-phase4-movement-trim.md` (writing-plans from the two 2026-06-15 specs). Executed hybrid: SQL inline TDD; the 3 views via parallel subagents; convergence (routes/scan/commit) in-session. All on `jacques/working`.

**SQL — complete + green (full suite passes; both Phase 4 suites green):**
- Migration `0024` (audit LogEventType 34 `TrimCheckpointRecorded` reserved / 35 `TrimOutRecorded`) + seed `024` (Trim IN/OUT OperationTemplates, no fields, bound to Area `TRIM1`).
- **6 net-new procs:** `Parts.ItemLocation_CheckEligibility`, `Parts.Item_GetMaxParts`, `Lots.Lot_GetCellLineQuantity`, `Lots.Lot_GetWipQueueByLocation` (Phase 5 FIFO consumer), `Lots.Lot_MoveToValidated` (eligibility FDS-02-012 + MaxParts OI-12 + B2, inline move), `Workorder.TrimOut_Record` (closing checkpoint + whole-LOT move, no split). `Lot_MoveTo`/`Lot_Create` reused untouched. Suite `0024` = 39 assertions.
- Migration `0025` (label dispatch): `LotLabel.DispatchedAt` + LogEventType 36 `LabelDispatched`; `@PrinterName` added to `LotLabel_Print`/`_Reprint`; new `LotLabel_RecordDispatch`; new `Location.Terminal_GetPrinter` read. Suite `0025`.
- **Migration numbers consumed: `0024` + `0025`.** Phase 5 (Machining) renumbers to **`0026`+**.

**Ignition — file-authored + scanned (NOT Designer-smoked):**
- **13 Core NQs** (the 6 movement/trim + `LotLabel_Print`/`_Reprint`/`_RecordDispatch` + `Terminal_GetPrinter` + `Audit_LogInterfaceCall` + `LabelTypeCode_List`/`PrintReasonCode_List`).
- **Entity scripts:** new `Parts.ItemLocation`, `Workorder.TrimOut`, `Lots.LotLabel` (synchronous raw-TCP 9100 ZPL dispatcher + InterfaceLog-every-attempt + fail-fast + default Primary/Initial id resolution); extended `Parts.Item` (getMaxParts/getForDropdown/getByPartNumber), `Lots.Lot` (moveToValidated/getCellLineQuantity/getWipQueueByLocation/getByName), `Location.Terminal` (getPrinter).
- **`onStartup`** resolves the terminal's child Printer into a declared `session.custom.printer`.
- **3 views:** `Components/PlantFloor/MovementScan`, `Views/ShopFloor/TrimStation` (tabbed IN/OUT), `Views/ShopFloor/ReceivingDock` (parallel-subagent authored). Routes `/shop-floor/trim` + `/shop-floor/receiving` added.

**⚠️ Owed / carry-over:**
1. **Designer smoke** (the one CLI-impossible step) — exercise all 3 views in a Perspective session. Run `.\scan.ps1` first — **no gateway restart** (new Core NQs register for inherited visibility on scan; the old "restart required" note was false, corrected 2026-07-02).
2. **HomeRouter tiles** for Trim/Receiving — deferred (editing the existing HomeRouter `view.json` is the file-edit boundary → do in Designer). Routes are directly navigable now.
3. **Hardware-gated:** real Zebra LTT print is a deployment gate (raw TCP to networked printers only). Dispatch verifiable via a local socket listener / Labelary.
4. **TrimStation IN-tab checkpoint** (`ProductionEvent.record` for `TrimIn`) is TODO'd (no counter inputs wired yet); "Record scrap"/"Correct piece count" buttons present but disabled. The IN-tab MOVE works.
5. **TrimStation OUT destination dropdown** uses the generic all-cells list (`getCellsForDropdown`) — includes terminal/printer-kind cells; a Machining-line-scoped read would be tighter.
6. **Smoke seed** `sql/scratch/smoke_seed_phase4.sql` not yet written (owed with the Designer smoke).

**🚩 Pre-existing branch blocker (NOT Phase 4 — for the Phase 3-deltas owner):** `Parts.DataCollectionField_Create` (still v2.0) doesn't supply `DataTypeId`, but deltas migration `0023` made `DataCollectionField.DataTypeId` NOT NULL → every DataCollectionField create throws (surfaces as Msg 3915 under INSERT-EXEC in `0007_Parts_codes/010`). Needs a `@DataTypeId` path on Create (+ likely Update) + a required-vs-default decision. I fixed the companion stale-temp-table (Msg 213) in that test, but did not touch the Create proc. Until resolved, the full suite shows one throwing file (all 1602 assertions still pass).

---

## 🔖 2026-06-15 — Phase 3 SQL cleaned up; Phase 4 fully specced (next: writing-plans on Spec 1)

**Phase 3 (die cast) — SQL cleaned up, front-end spec in.** Reviewed the Phase 3 die-cast SQL (built by a parallel agent in a worktree): caught that it was authored on a **stale base** (branched before Phase 2's `0021`), giving a hard **audit-Id collision** (`0022` reused LogEventType 29/30 + LogEntityType 42/43 already taken by `0021`). The original agent rebased + re-reconciled; the cleaned build is committed (`f619326`) — post-cleanup `0022` uses LogEventType **32/33**, LogEntityType **45/46**. The Phase 3 front-end design spec is committed (`2276bbf`). Secondary review findings still worth folding into the Phase 3 front-end build: the dropped `@EventAt` param vs the NQ that passes it; the TOCTOU race on the reject quantity check; `ProductionEvent_ListByLot` / `DataCollectionField.DataType` gaps. Phase 3 front-end is the *other* agent's to wrap.

**Phase 4 (Movement + Trim + Receiving) — two design specs written + committed on `jacques/working`:**
- **Spec 1 — SQL foundation** (`docs/superpowers/specs/2026-06-15-arc2-phase4-movement-trim-sql-design.md`, `29310e1`): migration `0023` (audit seeds, LogEventType 34/35) + seed `023` (Trim OperationTemplates, no fields) + **6 net-new procs** (`ItemLocation_CheckEligibility`, `Item_GetMaxParts`, `Lot_GetCellLineQuantity`, `Lot_GetWipQueueByLocation`, `Lot_MoveToValidated`, `TrimOut_Record`) + the `0023` test suite. Receiving reuses `Lot_Create` (vendor lot + serial range already shipped). **Decision:** server-authoritative `Lot_MoveToValidated` (eligibility + MaxParts enforced in the proc) + advisory reads. Confirms: drop `ReceivingScan`, no MaxParts at TrimOut, no data-collection fields on Trim templates.
- **Spec 2 — gateway + front-end** (`docs/superpowers/specs/2026-06-15-arc2-phase4-gateway-frontend-design.md`, `4770efc` + `2434491`): **synchronous** LTT ZPL dispatch (raw TCP 9100 → networked Zebra; GX420d Ethernet variant validated), resolved from `session.custom.printer` (an `onStartup` extension), every attempt logged to `Audit.InterfaceLog` via the existing `Audit_LogInterfaceCall`; **print failure never rolls back the LOT** (retry via the existing `LotLabel_Reprint`). Small label SQL delta in migration `0024` (`@PrinterName` on Print/Reprint + `LotLabel.DispatchedAt` + `LotLabel_RecordDispatch`). Reusable **Movement Scan** component, one **tabbed Trim Station** view (IN/OUT), **Receiving Dock**; Core NQs + entity scripts + routes. **New convention:** FDS-02-009 "scan or dropdown" inputs = one `ia.input.dropdown` with `allowCustomOptions:true` (memory `feedback_ignition_scan_or_dropdown_allowcustomoptions`).

**Next session:** `writing-plans` on **Spec 1** (buildable first; Spec 2 depends on its procs), then build. Both specs are awaiting Jacques's read.

### ⚠️ Phase 3 spec-agent addendum (2026-06-15, parallel session) — read before building Phase 3/4

A second agent produced the **Phase 3 SQL-deltas spec** + baked the Phase 3 FE decisions (D1–D5) in, codified the ET convention, and landed the Phase 2 LOT-view smoke fixes. Fold these into writing-plans/build:

- **✅ Migration collision RESOLVED 2026-06-16.** Numbers claimed across all three specs: **Phase 3 SQL-deltas = `0023`** (`docs/.../2026-06-15-arc2-phase3-sql-deltas-design.md`), **Phase 4 movement/trim = `0024`** (renumbered from `0023`; seed `024`, tests `0024_PlantFloor_Movement_Trim`), **Phase 4 label dispatch = `0025`** (renumbered from `0024`). Both Phase 4 specs were edited in place — the Phase 4 agent reads the corrected numbers. Audit-Id high-water unaffected: Phase 3 deltas `0023` adds NO LogEventType/LogEntityType; Phase 4 `0024` adds LogEventType 34/35; Phase 4 `0025` adds LogEventType 36. Phase 5 (Machining) renumbers off its old `0024` earmark to `0026+`.
- **Phase 3 SQL-deltas spec RESOLVES the "gaps" listed above as open:** adds `Parts.DataCollectionField.DataType` (new `Parts.DataCollectionFieldDataType` FK code table + backfill + `DataCollectionField_List` returns it), the `Workorder.ProductionEvent_ListByLot` read proc, optional `Lot_Create @LotName` (D4 forward-compat — mint stays default), and the `@CavityNote` no-active-cavity path (D2 — stored in the legacy `Lot.CavityNumber`). The secondary-review `@EventAt`-param + reject-TOCTOU findings are NOT in this spec — still fold them into the build.
- **Phase 3 FE spec decisions baked in (D1–D5)** + reconciled with the SQL-deltas spec (commits `aadbc0b`, `5ae57d9`): mockup two-column layout (NO tabs), cavity dropdown w/ `allowCustomOptions:true` free-entry, rapid cavity-peer logging, scanned-LTT mint-default + one-line flip, DataType-driven field typing. Field codes corrected to **`GoodCount`/`BadCount`** (there is no `ShotCount`/`Good`/`Bad` DataCollectionField — `ShotCount`/`ScrapCount` are typed `ProductionEvent` columns); reject proc uses **`@Quantity`** + `@ChargeToArea NVARCHAR(100)`.
- **⏳ Pending MPP (expected this morning, 2026-06-16):** is the pre-printed LTT # the canonical LOT id? **Yes** → flip `Lot.create` to pass `lotName=scannedLtt` (one line; the `Lot_Create @LotName` seam is already specced). **No** → server mint stays. Either way no rebuild.
- **ET timestamp convention codified** (CLAUDE.md § SQL design, commit `58655dc`): all displayed timestamps are ET (store UTC, convert at the read boundary via `AT TIME ZONE`). **OI-36** (OIR v2.19) tracks the refactor sweep — apply the ET conversion to every NEW Phase 3/4 read proc (`ProductionEvent_ListByLot.EventAt`, Movement/WIP reads, etc.).
- **Phase 2 LOT-view smoke fixes landed + pushed** (commits in the `f619326`..`2276bbf` batch): flex-repeater row sub-views relocated to `Components/PlantFloor/...` (Ignition can't register a view nested under another view), `ia.container.tab` for LOT Detail tabs, path-param route `/shop-floor/lot-detail/:lotId`, LOT Search default-Top-200 + Reset + Vendor column + `StatusPill` cell-view, history-timeline enrichment (pause/genealogy/label/reason streams, ET). Seed dev data via `sql/scratch/smoke_seed_phase2.sql`. The throwaway `PausedDemo` page was deleted (the `PausedLotIndicator` component stays for real embedding).

---

## ✅ Closed 2026-06-11 — Eligibility-style config editors signed off (was: Designer-smoke pickup, 2026-06-08)

**Jacques closed this out 2026-06-11** — the eligibility-style editors are accepted and the Phase H3 Designer-smoke obligation is retired. Original pickup detail retained below for reference.

**The eligibility-style config editors are built: backend COMPLETE + verified, Perspective UI drafted.** Plan at `docs/superpowers/plans/2026-06-08-eligibility-style-config-editors.md` executed via subagent-driven-development on `jacques/working` (commits `81f7a82`..`33b94e5`). SQL suite **1196/1196**; every Ignition resource scanned clean. **Nothing has been visually smoked yet — that is the entire remaining task.**

**Next step: Designer smoke (plan Phase H3).** Open a Perspective session and exercise each surface:
- **Tools → Attributes** (`/tools`): edit a value → `●` dirty + Save/Discard appear; Save persists + clears dirty + toasts; Discard reverts; `+ Add` picks a Definition and the value input matches its DataType (String text / Integer+Decimal numeric / Boolean checkbox / Date picker); `×` hard-deletes on Save; switching tools/tabs while dirty raises ConfirmUnsaved. Confirm `+ New definition` still opens `AddAttributeDefinition`.
- **Tools → Cavities**: add cavity (Active), set status via dropdown, Save; saved-Scrapped row is locked/dimmed; number read-only on existing rows; empty save does NOT delete cavities.
- **Tools → Assignments**: inline cell dropdown (compatible cells only); Mount mounts immediately + toasts + history/banner update; Release works; NO dirty-gating from this tab; MountToCell popup is gone. **Eyeball the active-mount banner** (the `coalesce`→`if(isNull,…,toStr)` defensive fix landed, but confirm AssignedAt renders cleanly — date formatting on the banner wasn't specced).
- **Operation Templates → Fields**: add field via dropdown, toggle Required, remove, Save; switching template/version while Fields dirty raises ConfirmUnsaved.
- **`/audit`**: confirm `Audit.ConfigLog` rows for each save carry the `<SUBJECT> · <Attributes|Cavities|Fields> · <action>` narrative + resolved-FK Old/New JSON.

**Known caveats for the smoke (all file-authored without a Perspective session, so expect to iterate in Designer):**
- The Tools + OperationTemplates **parent views were file-edited** (the view-edit-boundary risk was explicitly accepted). Watch for Designer "Files vs Gateway" reconciliation prompts; the diffs were clean structural deltas (~100–220 lines, no pickle).
- Entry-field inputs (numeric/date) commit on `dom.onBlur`; dropdowns/checkboxes on `onActionPerformed` — verify commits fire.
- Tab gating uses the ItemMaster tab-objects `disabled`-when-dirty model (`toolTabObjects`), not a click-intercept.
- Two unverified-design assumptions worth confirming: the `toolTypeId` lazy lookup on the Attributes `+ New definition` click, and the `_applyFieldChange` `"CODE - Name"` label split populating new-row Code/Name.

**After smoke passes:** merge `jacques/working` → `main` when ready. If smoke surfaces fixes, they're Designer edits to the drafted views.

**Migration-number heads-up:** `0018` is now taken by the Arc-1 tooltype-compat migration above. The Data Model header / Arc-2 plan had *planned* a Phase-5 `0018` for the OperationTemplate sub-LOT-split ALTER — that future Arc-2 migration must renumber to `0019+` when it actually builds (Arc 2 is OI-35-gated, unbuilt).

**Carry-forward (still owed from 2026-05-29, non-blocking):** the two Quality visual smokes below (state badges + ConfigChangeDetail color-diff).

**Carry-forward from the 2026-06-05 hardening session (non-blocking):**
- **Visual eyeball owed:** demo item **5G0** is now fully configured — open `/items` → 5G0 and confirm every tab renders (Identity, Container Config, Routes w/ OT data-collection fields, BOMs, Quality Specs w/ attributes, Eligibility). Also confirm the Routes-tab StateBadge no longer errors with no version selected (the custom-prop fix).
- **Offered, not done — sibling custom-prop audit:** apply the Routes `getXOrEmpty` + pre-declared-custom-props pass to the other versioned editors (**BOMs**, **QualitySpecs**) — they bind header/version props the same way and likely carry the same latent "binding returns None into a nested read" error. See `feedback_ignition_predeclare_bound_custom_props`.
- **Code-review items deferred by design** (pushed back with reasoning, left as-is): #3 DowntimeReasonType "(Unassigned)" vs "All Types" dropdown (both `value:None` — needs a proc + Designer view change to fix properly); #9 `Location.eligibleTypes` Python tier filter (5 static rows, backstopped by the SaveAll proc); #11 RouteTemplate `"Route v1"` default name. Revisit only if desired.

---

## 🔖 Next Session Pickup — Quality Spec Config Tool is functional; small polish + two visual smokes

**State of play.** The Quality Spec Config Tool is **built and smoke-tested end-to-end** (Phases A–H + a day of polish fixes — see Last-updated + Recently-closed). All committed locally; push at session start if not already pushed. Nothing blocking.

**Two visual smokes still owed** (need a Perspective session — quick eyeball):
1. **Quality state badges** — `/quality-specs`: with two published versions (one effective-now, one future-effective), confirm the dropdown + Version History show **Active / Scheduled / Superseded** with the right colors.
2. **ConfigChangeDetail color-diff** (Slice 2.5) — `/audit` → click a row → confirm the Changes block renders with color (green/red/yellow).

**Small known follow-ups (non-blocking, all in `BlueRidge/Views/Quality/QualitySpecs` + components):**
- `badge-warn` class doesn't exist in the stylesheet; `SpecListRow` and the main `StateBadge` still use it for the Draft pill (renders unstyled). Standardize on `badge-draft`. (VersionHistoryRow already fixed.)
- `QualitySpec_Get` doesn't SELECT `DeprecatedAt`, so the header can't show a deprecated badge (library already hides deprecated specs). One-line SQL add + widen any `INSERT-EXEC` scratch table that calls it.
- Both `/quality-specs` and `QualitySpecAttributeRow` view.json are Designer-expanded; expect format churn on Designer saves (not a bug).

**After that — next major work** (pick per priority): the OI-35 architecture gate still blocks Arc 2 Phase 1 SQL; other Config Tool surfaces (Tools master) remain; or whatever the customer prioritizes.

---

### (superseded) Build the Quality Spec Config Tool (audit refactor is DONE)

**State of play.** The project-wide audit-readability refactor is **complete across all 8 slices + 2.5**. Every audit-writing proc now emits the `SUBJECT · CATEGORY · ACTION` narrative `Description` + resolved-FK `OldValue`/`NewValue` JSON. **SQL tests 1136/1136.** Slices landed:

| # | Slice | Procs | Status |
|---|---|---|---|
| 1 | Convention + UI + popup fix | — | ✅ 2026-05-28 |
| 2 | Eligibility (reference impl) | `ItemLocation_SaveAllForItem` | ✅ 2026-05-29 |
| 2.5 | ConfigChangeDetail diff highlighting | `Common.Util.prettyJsonDiff` + popup | ✅ 2026-05-29 |
| 3 | BOMs | `Bom_*` (6) | ✅ 2026-05-29 |
| 4 | Routes | `RouteTemplate_*` (6) | ✅ 2026-05-29 |
| 5 | Item core (Identity + ContainerConfig) | `Item_*`, `ContainerConfig_*` (5) | ✅ 2026-05-29 |
| 6 | Plant Hierarchy | `Location_*`, `LocationAttribute_Set` (6) | ✅ 2026-05-29 |
| 7 | LocationTypeEditor | `LocationTypeDefinition_*` (2) | ✅ 2026-05-29 |
| 8 | Downtime + Defect codes | `DowntimeReasonCode_*`, `DefectCode_*` (6) | ✅ 2026-05-29 |

**⚠️ One visual smoke still pending (Slice 2.5).** The ConfigChangeDetail popup's new **Changes** block uses `ia.display.markdown` (`props.markdown.escapeHtml=false`) bound to `Common.Util.prettyJsonDiff`, which emits HTML `<div>` lines colored green/red/yellow. Open `/audit` → click any row → confirm the diff renders **with color**. If 8.3's markdown sanitizes inline `style` attributes, the +/−/~ symbols still convey the diff (graceful degradation) and it's a one-line revert to the dual-block-only render. Helper + popup are scanned/live; the dual Old/New JSON blocks were kept below the diff for the full unabridged snapshot.

**Convention reference for new procs.** Use `Audit.ufn_MidDot()` for the separator and `Audit.ufn_TruncateActivity()` for the 500-char cap. Resolve every FK to a `{Id, Code, Name}`-style sub-object via `JSON_QUERY((... FOR JSON PATH, WITHOUT_ARRAY_WRAPPER))` — a **bare** aliased `FOR JSON` subquery double-encodes as an escaped string. Strip trailing separators with `LEFT(x, DATALENGTH(x)/2 - 2)`, never `LEN()`-based. Render `BIT` diffs as `true`/`false` words. Keep test fixtures' free-text names off tokens other tests grep for (e.g. avoid `'SaveAll'` in a Description — it cross-contaminates `02_audit_readers/050_ConfigLog_List.sql`'s `@DescriptionLike` filter).

**On resume — build the Quality Spec Config Tool.** Spec `docs/superpowers/specs/2026-05-28-quality-spec-config-tool-design.md`, plan `docs/superpowers/plans/2026-05-28-quality-spec-config-tool.md` (9 phases / ~18 tasks, SQL-first). The Quality SQL layer is already built (migration `0008` + ~20 procs); this is mostly Ignition front-end + a contained SQL delta (migration `0017` adds `QualitySpecAttribute.UomId` FK). Audit rows are designed to the readability convention from day one. Front-end mirrors the BOMs versioned-editor impl in a standalone `/quality-specs` master-detail shell.

> **Build heads-up for the quality-spec plan:** the plan (written before Slice 1 landed) inlines `NCHAR(183)` in its audit-prose blocks — use the deployed `Audit.ufn_MidDot` + `Audit.ufn_TruncateActivity` helpers instead for consistency with the refactored procs.

**Other open Ignition items not blocking the above:**
- Phase 7 QualitySpecs cross-nav — **now folded into the Quality Spec Config Tool plan** (Phase H: "Go to spec →" navigates to the new standalone `/quality-specs` screen). No longer a standalone task; the cross-nav needs the standalone screen as its target.
- DieCastMachine Cell read-only mounted-Tool status panel — deferred until Tools master Config Tool surface exists.
- Orphan Draft BOM rows in dev DB from pre-fix `+ New Version` clicks may still need a manual cleanup pass.
- OI-35 Architecture Decision Gate still gating Arc 2 Phase 1 SQL build (independent of any Ignition work).

---

---

## 🆕 Item Master design convention update (2026-05-20)

The Item Master design has been **reworked from bundled-editDraft + bidi-Object-param to per-section ownership** before any Phase 3+ implementation lands. Each of 6 sections (Identity + 5 tabs) now owns its own selected/editDraft locally, has its own Save/Discard, and broadcasts dirty state via `sectionDirtyChanged` page-scoped messages. Parent aggregates flags + gates tab/item switches via the existing ConfirmUnsaved popup.

**Why:** R1 (bidi Object-param round-trip) was never proven and Phase 2's wiring drifted from the original design. Per-section ownership uses primitives the project has shipped reliably (page-scoped messages) and aligns with how the customer's roles actually work (different engineers own different concerns).

**Canonical reference:** `project_mpp_item_master_pattern` memory (2026-05-20 rev).

**Docs realigned:**
- `docs/superpowers/specs/2026-05-20-item-master-phase4-design.md` + plan — **rewritten** for per-section.
- `docs/superpowers/specs/2026-05-20-item-master-boms-design.md` + plan — **medium retrofit** flagged via §0 convention-reconciliation preamble (most of spec stands).
- `docs/superpowers/specs/2026-05-20-item-master-routes-design.md` + plan — **light retrofit** (Routes already designed for per-section; convention ratifies it).

**Phase 1 + 2 code:** parent's old bundled `editDraft` and `selected` blocks are inert (never properly populated for ContainerConfig); they get demolished as part of Phase 4 Task 5.

---

## ✅ Recently closed

### Arc 2 Phase 3 — SQL deltas (migration 0023) built + tested (2026-06-16)

Built the three die-cast front-end SQL dependencies + a concurrency fix, in-session TDD against a fresh `Reset-DevDatabase` baseline (DB had been at `0021` — Phase 3 `0022` was committed but never applied; reset brought it to `0022` then `0023` applied). **Full SQL suite 1535/1535 green** (30 net-new `0023_PlantFloor_DieCast_Deltas/` assertions). On `jacques/working`, commits `7f3da5a` (Phase 4 renumber) → `6f5b7b1`.

- **Migration `0023`** — new `Parts.DataCollectionFieldDataType` FK code table (5 rows String/Integer/Decimal/Boolean/Date) + `Parts.DataCollectionField.DataTypeId` NOT NULL FK (nullable→backfill-by-Code→NOT NULL, DT-2). No audit-lookup rows. Idempotent (verified re-apply = no-op).
- **`DataCollectionField_List` v3.0** — joins the new code table, returns `DataTypeId/Code/Name` (the FE typed-widget driver, D5).
- **`Workorder.ProductionEvent_ListByLot`** (new, PE-1a) — header-only chronological checkpoint list, resolved-name joins, empty-safe; `EventAt` raw UTC (FE formats; OI-36 if ET wanted). Feeds the FE cumulative-cavity card + last-shot hint.
- **`Lot_Create` `@LotName` (D4) + `@CavityNote` (D2)** — additive, backward-compatible (every existing caller/test passes NULL and behaves byte-for-byte as today; the `0021`/`0022` LOT tests pass unmodified). `@LotName` supplied = use verbatim, no `IdentifierSequence` burn; duplicate/blank rejected. `@CavityNote` = manual cavity stored in the legacy `Lot.CavityNumber` when `@ToolCavityId IS NULL` on a die-cast cell; validated cavity path unchanged.
- **`RejectEvent_Record` TOCTOU fix (v1.1)** — the `@Quantity > @PieceCount` gate read `PieceCount` unlocked pre-transaction; added an in-transaction `IF @NewPieceCount < 0 RAISERROR` re-check under the existing UPDLOCK (routes to CATCH = clean Status 0) so concurrent over-rejects can't drive `PieceCount` negative. (Beyond the deltas-spec scope but a correctness bug; the project-status addendum flagged it.)
- **Reconciliation folded in (verified vs as-built):** the FE-spec NQ for `ProductionEvent_Record` named `@EventAt` (proc has none — stamps `SYSUTCDATETIME()`) and `@DataCollectionValuesJson` (real param is **`@FieldValuesJson`**) — Part B authors the NQ/entity-script against the real signature (recorded in the plan's reconciliation section).
- **Part B front-end — BUILT (file-authored + scanned), commits `c29d5db`+`5a8a566`.** 5 Core NQs (`workorder/ProductionEvent_Record`+`_ListByLot`, `workorder/RejectEvent_Record`, `parts/ToolCavity_ListActiveByTool`, `parts/ToolAssignment_ListActiveByCell`; `lots/Lot_Create` gained `:lotName`/`:cavityNote`); entity scripts (`BlueRidge.Workorder.ProductionEvent`+`RejectEvent` new modules; `Parts.Tool` +cavity-dropdown/cell→tool helpers; `Parts.OperationTemplate.getDieCastShotFields` DataType-merge; `Lots.Lot.create` lotName/cavityNote forward + `getOriginTypeIdByCode`; `Quality.DefectCode.getForDropdown`); the no-tabs two-column **DieCastEntry** page + **CheckpointPanel**/**RejectPanel**/**FieldInputRow**/**PeerTallyRow** sub-views; 3 `/shop-floor/die-cast*` routes + HomeRouter tile; smoke seed `sql/scratch/smoke_seed_phase3_diecast.sql`.
  - **Topology reconciliation (FE spec assumed namespaces that don't exist):** tool NQs live under `parts/` (no `tools/` group) and tool helpers extend `BlueRidge.Parts.Tool` (no `BlueRidge.Tools.*`); event procs got a new `workorder/` NQ group + `BlueRidge.Workorder.*`. NQ params reconciled to the **as-built** `ProductionEvent_Record` (no `@EventAt`; `@FieldValuesJson` not `@DataCollectionValuesJson`).
  - **⚠️ REMAINING (manual): Designer visual smoke** — the views were file-authored without a Perspective session, so expect iteration. The `scan.ps1` already ran — **the new Core NQs are registered, no gateway restart needed.** Walkthrough in the plan §B5 / FE spec §10: minimal-tap create, cavity-peer (flat genealogy), free-entry cavity (D2), data-driven checkpoint widgets (D5) + unchanged inventory, reject + close-at-zero. Seed via the smoke script; the operator session needs `session.custom.cell.locationId` + `appUserId` set.
  - **Known FE follow-up:** the Item field is a numeric-entry (flagged TODO) — needs an `Item_ListEligibleForLocation` read to become an eligibility-constrained dropdown (deferred: would be untested new SQL; the proc validates eligibility server-side regardless). Tool-reassign Edit + Hold buttons are surfaced per the mockup but not fully wired (reuse existing `Parts.Tool` assign/release + hold procs at smoke).
  - **Open dispositions (non-blocking):** D4 canonical-LOT-id MPP confirmation (server-mint default until then; one-line flip to `lotName=scannedLtt`); `ProductionEvent_ListByLot.EventAt` UTC-vs-ET (OI-36); Tool-reassign-from-plant-floor auth policy.

### Arc 2 Phase 2 — LOT Lifecycle SQL foundation built end-to-end (2026-06-11)

Migration `0021` + **13 net-new procs** + test suite `0021_PlantFloor_Lot_Lifecycle/` (9 files), **SQL suite 1449/1449**. Brainstormed → spec'd (`docs/superpowers/specs/2026-06-11-arc2-phase2-lot-lifecycle-design.md`) → planned (`docs/superpowers/plans/2026-06-11-arc2-phase2-lot-lifecycle.md`) → built. Tasks 0–5 ran subagent-driven (fresh implementer + spec-review + code-review + fix per task); Tasks 6–7 + integration sign-off ran in normal in-session flow (faster/cheaper for well-specified pattern SQL where context is already held — see the 2026-06-11 process note). All on `jacques/working`, commits `56aefa1`..`6bae073`.

- **Schema (migration 0021):** 5 new tables — `LotGenealogy` (born-partitioned on `EventAt`, 20-yr Honda class, PartitionRetention 240mo), `LotAttributeChange`, `LotLabel`, `PauseEvent` (filtered-unique open-pause invariant + CK_ResumePaired), `LabelTemplate` (1:1 active ASCII ZPL body per LabelTypeCode). Seeds: 3 new LogEventType + 3 LogEntityType + one ZPL template per label type. B4 closure + B5 materialized cols already existed in 0020 — Phase 2 *maintains* them.
- **Mutations:** `Lot_Update` (partial-update NULL semantics, lenient optimistic lock, per-field LotAttributeChange audit, resolved WeightUom FK), `Lot_UpdateAttribute`.
- **Genealogy:** `Lot_Split` (parent-derived `-NN` sublot suffix, UPDLOCK/HOLDLOCK serialization, closure depth+1, Option-A multi-row return, inline child-create to dodge INSERT-EXEC/result-set pollution), `Lot_Merge` (die-rank-compat rules keyed off `Tool.DieRankId` + supervisor override, fresh-MESL blended output, closure ancestor-dedup, BIGINT sum guard), `LotGenealogy_RecordConsumption` (consumption edge + closure; `@ProducedLotId` required since `ChildLotId` is NOT NULL).
- **Reads:** `Lot_GetGenealogyTree` (closure-backed ancestors/descendants/both), `Lot_GetParents`/`Lot_GetChildren` (one-hop edges + EventUser), `Lot_GetAttributeHistory` (UNION of attribute/status/movement streams).
- **Labels:** `LotLabel_Print` + `LotLabel_Reprint` — SQL-side ZPL render from `LabelTemplate` (5-token REPLACE), sublot `ParentLotId` rule, reprint resolves prior label type (else Primary) + forces non-Initial reason. `LotLabel` entity audits route to `Audit.OperationLog`.
- **Pause (OI-21):** `LotPause_Place`/`_Resume`/`_GetByLocation`/`_GetCountsByLocation` — B3 open-event pre-check + filtered-unique backstop, multi-Cell concurrent pause, resumer-may-differ.
- **Key engineering note:** every mutation proc that orchestrates sub-mutations INLINES them (child create, parent reduce, source close) rather than `EXEC`-ing the status-row procs — an `EXEC`'d status-row SELECT pollutes the caller's result set and nesting INSERT-EXEC is illegal. Validations run *before* `BEGIN TRANSACTION` (ROLLBACK inside an INSERT-EXEC'd proc throws Msg 3915).
- **Deferred (by design):** the 4 Perspective views (LOT Detail, LOT Search, Genealogy Viewer, Paused-LOT Indicator) are a follow-on Ignition push (SQL-first decision); `@PrinterName` on labels lands with the B17 gateway dispatcher; precise B5 OEE-grade recompute lands with the Phase 3 event writers. Migration `0021` is now taken — Phase 3 die-cast is `0022`.

### Terminal-mode view-policy model — smoke-discovered redesign landed end-to-end (2026-06-10/11)

Designer-smoking Phase 1 exposed that FDS-02-010's parent-tier TerminalMode derivation misclassified every machining/assembly-line + trim terminal (cell-less parents -> Shared with an EMPTY context picker; attribution broken). MPP ruling: lines are tracked at line resolution; stations are operation points. Redesign (spec `docs/superpowers/specs/2026-06-10-terminal-mode-view-policy-design.md`, plan + 8-task subagent-driven execution): **there is no TerminalMode anywhere** — behavior is a property of the operator view assigned via `DefaultScreen` (shared-flavor views open with a select-location step; dedicated-flavor views bind context to the terminal's parent Location at ANY tier).

- **SQL:** `Terminal_GetByIpAddress`/`Terminal_List` v1.1 (mode column dropped; `HasPrinter` registry flag added — every terminal must carry >= 1 child Printer; seed has 62/63, FALLBACK-TERMINAL flagged); NEW `Location.Terminal_ListContextCells` (recursive equipment-cell picker excluding Terminal/Printer kinds, MAXRECURSION 8); test file `015_Terminal_ContextCells_List.sql`. Suite **1308/1308**.
- **Ignition:** Core NQ + `Terminal.listContextCells`/`getContextCellsForDropdown`; MPP session shape drops `terminalMode`, adds `presence.policy` (default `strict`; dedicated views set `confirm`); HomeRouter initials-gate removed (view flavor owns it); CellContextSelector re-pointed to the terminal-scoped picker (also fixes its old all-Cells list offering terminals/printers); PresenceIdleWatcher gates on `policy != "confirm"` (strict-flavor idle handling TODO'd for first work views); InitialsField auto-fill re-anchored to `policy == "confirm"`; TerminalSelector session-write purged.
- **FDS v1.4** (+docx): §2.5, 02-008/009/010/011, 04-003 amended; 04-006 explicitly unchanged (both flavors keep the 30-min re-confirm); §1 diagram + FDS-05-008 move step re-anchored; stale header version fixed (was reading 1.3).
- **⚠️ Owed:** a 60-second session smoke (after a `scan.ps1` — no gateway restart needed): select DC1-T1 -> CellContextSelector lists exactly the 11 DC1 presses; line terminal -> empty picker. (Earlier note here claimed a gateway restart was required for MPP to resolve the inherited `location/Terminal_ListContextCells` NQ; that was a mis-attribution — scan re-reads NQs fine. The real prior fix was *moving* NQs into Core for sibling visibility. Corrected 2026-06-12.)

### Arc 2 Phase 1 Ignition layer — NQs + gateway scripts + 7 Perspective views built (2026-06-09)

The follow-on Ignition push to the Phase 1 SQL foundation (tasks T030–T041, ~54h) is **built + file-authored + statically reviewed**, committed on `jacques/working` (`07f2e10`..`848426b`). Executed subagent-driven (fresh implementer + spec/quality review per task + a final holistic cross-cutting review). **NOT yet Designer-smoked — that is the remaining manual step.**

- **New project topology (Jacques's decision):** introduced **`Core`** (inheritable parent; holds the moved `BlueRidge.*` scripting library) and **`MPP`** (`parent=Core`; the plant-floor operator project) — pulled from the gateway projects folder into the repo (`ee70f4a`). The legacy `MPP_Config` (config tool) stays as-is. Entity scripts + NQs → Core; views + session-startup + timers → MPP.
- **DB-access layer (T030, Core):** 17 thin Named Queries wrapping the Phase-1 procs (all `type:"Query"` — even mutations, status-row pattern) + 6 entity-script modules (`Location.Terminal`, `Location.AppUser`, `Oee.Shift`, `Lots.Lot`, `Lots.IdentifierSequence`, `Audit.Partition`). Later migrated `location/Location_ListByTier` into Core too (for the Cell selector).
- **Session bootstrap + gateway timers (T031/T033/T034, MPP):** rewrote `onStartup` to resolve the terminal from client IP (`Terminal_GetByIpAddress`) into `session.custom.terminal.*`; declared the plant-floor `session.custom` shape (`terminal`/`user`/`appUserId`/`cell`); `ShiftBoundaryTicker` (60s) → `Shift.tickShiftBoundary`; `PartitionMaintenance` (24h) → `Audit.Partition.maintain`.
- **7 Perspective views (T035–T041, MPP):** Per-Mutation Initials Field, Elevation Modal, Initials Entry (+ A-Z keypad), 30-Min Idle Re-Confirm Modal, PresenceIdleWatcher (`now(30000)` idle binding), Terminal Selector (`ia.display.table` full-schema + `onSelectionChange`), Cell Context Selector, Home Router (gates terminal→Dedicated-presence→defaultScreen, repointed `/`). Routes added: `/shop-floor/initials`, `/shop-floor/terminal-selector`, `/` → HomeRouter.

**Known follow-ups / flagged decisions (none blocking the build):**
1. **Gateway sync + Designer smoke** is the only remaining step a CLI can't do — the new files are in the repo but NOT yet in the live gateway's `Core`/`MPP` copies. Sync repo→gateway (carefully, to avoid clobbering in-Designer work) then smoke each surface in a Perspective session.
2. **AD elevation is default-deny:** `AppUser.elevate`'s `_validateAdCredentials` denies all until the gateway AD Identity Provider is wired (FDS-04-007). No invented permissive rule — wire the IdP at deployment and decide the validation mechanism.
3. `ia.input.password-field` (Elevation Modal) is unconfirmed in Designer — verify it renders.
4. Timers attribute shift/partition audit to the dev-fallback AppUser `2`; seed a dedicated **system** AppUser before cutover.
5. `now(30000)` idle re-fire + the PresenceIdleWatcher embedding into work screens are runtime-verify / later-phase items.
6. Cell Context Selector is Phase-1-scoped (pick+persist+broadcast); zone cascade + `v_EffectiveItemLocation` enrichment are later-phase.

### Arc 2 Phase 1 SQL — Phase 0 gate signed off + design/plan committed + dispatch begun (2026-06-09)

**OI-35 architecture gate CLEARED.** Phase 0 Track B was decided 2026-06-08 (`Meeting_Notes/2026-06-08_Phase0_Decision_Log.md`); the staged T009 sign-off Blocks 1–5 were applied to the canonical docs this session:
- **Data Model** → new § "Scaling Decisions (OI-35)" (rev **1.9s**).
- **FDS** → FDS-11-009 differentiated retention table (20-yr Honda / 7-yr general) (rev **1.3a**).
- **OIR** → OI-35 **RESOLVED**; UJ-03 changed (no auto even-split, Phase 0 T008); UJ-05 build-default locked; counts/version (**v2.18**).
- **Plant Floor plan** → B10 serial-migration convention refined.
- **Validation doc** → Section 5 resolution banner (C-4/C-5 CREATE-ownership pinned).
- **CLAUDE.md** → Active Blockers cleared. Decision-log T009 marked Done.

**Phase 1 scoped + designed + planned (SQL-first push).** Brainstormed the build approach: SQL foundation first (migration `0020` + ~16 procs + `0020_PlantFloor_Foundation/` test suite green, target 80–105), Ignition layer (3 Gateway scripts + 7 Perspective views) deferred to a follow-on push; subagent-driven execution. **Key design decision — partitioning:** monthly `RANGE RIGHT` + **`TRUNCATE`-based sliding-window** (not `SWITCH`) so the singleton `BIGINT IDENTITY Id` PK convention is preserved (clustered index = partition-aligned hot path; `Id` stays NONCLUSTERED PK); single `PRIMARY` filegroup; sliding-window logic in a testable proc so the future Gateway timer is a thin caller. Grounding catch: `Audit_LogOperation` (B7 target) has near-zero Arc-1 blast radius (Arc 1 audits to `ConfigLog`); no partitioning exists in the repo yet (genuinely new ground).

- **Design spec:** `docs/superpowers/specs/2026-06-09-arc2-phase1-sql-foundation-design.md` (commit `2785590`).
- **Implementation plan:** `docs/superpowers/plans/2026-06-09-arc2-phase1-sql-foundation.md` (commit `e1ef121`) — Tasks A–G (A partitioning in-session; B Lot core; C Terminal; D AppUser/elevation; E WorkOrder+eligibility view; F audit split+Shift; G integration/sign-off).
- **Status:** dispatch (subagent-driven) has **begun** on the SQL build (separate session). All on `jacques/working`.

### Eligibility-style config editors — backend built + verified, UI drafted (2026-06-08)

Executed the plan `docs/superpowers/plans/2026-06-08-eligibility-style-config-editors.md` (turned from spec `7f41a2d` via `writing-plans`) using **subagent-driven-development** — fresh implementer per task + two-stage (spec then code-quality) review per task + a final holistic cross-cutting review. All on `jacques/working`, commits `81f7a82`..`33b94e5`.

- **SQL (Phases A–B), fully tested — suite 1196/1196:** three bundled SaveAll procs following the audit-readable convention (`SUBJECT · CATEGORY · ACTION`, resolved-FK JSON, status row, no OUTPUT params):
  - `Tools.ToolAttribute_SaveAll` — insert/update/**hard-DELETE on absent** (`ToolAttribute` has no `DeprecatedAt`) + per-`DataType` value validation (String/Integer/Decimal/Boolean/Date). Reuses LogEntityType `ToolAttribute`.
  - `Tools.ToolCavity_SaveAll` — **insert + update only** (no deprecate-on-absent; cavities persist, end-of-life via Scrapped); CavityNumber immutable on existing rows; rejects transition out of Scrapped. LogEntityType `ToolCavity`.
  - `Parts.OperationTemplateField_SaveAll` — insert / update `IsRequired` / deprecate-on-absent / reactivate. LogEntityType `OpTemplateField`.
  - 3 thin NQs under `named-query/parts/` (`type:"Query"`, sqlType 3/7/3). No schema change (D4 = no SortOrder). No new LogEntityType seed (all three codes pre-existed).
- **Review catches (per-task):** ToolAttribute Boolean-NULL slipped the `NOT IN` validation → NOT-NULL constraint crash (fixed `i.Value IS NULL OR …` + test); OperationTemplateField reactivation could clear `DeprecatedAt` on >1 deprecated row for the same pairing → unique-index violation (fixed `MAX(Id)` guard + reject-active-re-add + regression test). Test fixtures named off "SaveAll" to avoid the `02_audit_readers/050_ConfigLog_List.sql` `%SaveAll%` count cross-contamination.
- **Entity scripts (Phase C):** `BlueRidge.Parts.Tool.saveAttributesAll`/`saveCavitiesAll`/`getAttributeDefinitionOptions`(carries DataType); `BlueRidge.Parts.OperationTemplate.saveFieldsAll` + `getFieldsForTemplate` now surfaces `DataCollectionFieldId`. Per-row legacy mutations kept as the non-UI surface. Resolved both plan-flagged prereqs (`Tool_Get` returns `ToolTypeId`; `OperationTemplateField_ListByTemplate` already returns `DataCollectionFieldId`).
- **Perspective UI (Phases D–H), file-authored + scanned — NOT visually smoked yet:** Attributes section + type-aware AttributeRow (four `position.display`-gated value inputs); Cavities section + CavityRow (status dropdown, Scrapped-lock, immutable number, remove only on unsaved rows); Assignments rewritten as a **non-draft** inline mount/release surface (+ binding-safe `getActiveAssignmentForToolOrEmpty`); Operation-Template Fields draft panel + FieldRow. Tools parent gains `sectionDirty` map + ConfirmUnsaved tab/tool-switch gating + `toolTabObjects` (ItemMaster tab-objects pattern); OperationTemplates parent folds `fieldsDirty` into its existing version-switch gate. All mirror the `ItemMaster/Eligibility` reference (atomic single-write `view.custom.state`, page-scoped row→section messages, pre-declared shaped bound props).
- **Cleanup (Phase I):** `MountToCell` / `AddAttribute` / `AddCavity` popups deleted (no dangling refs; `AddAttributeDefinition` kept + still referenced); defensive banner expr + dead-state removal.
- **⚠️ Remaining: Phase H3 visual Designer smoke** (see Next Session Pickup) — the only step a subagent/CLI cannot do. Parent views were file-edited (accepted view-edit-boundary risk); expect possible Designer iteration.

### Plant Floor (Arc 2) phased plan validated + corrected; task list generated (2026-06-08)

Diligence pass over the Arc 2 plan against the current FDS (v1.3), Data Model (v1.9o), and the **actual shipped migrations on disk** (three parallel inventory agents + ground-truth disk verification). Found 2 blocking defects, 3 MVP coverage gaps, and consistency drift; all corrections applied to `MPP_MES_PHASED_PLAN_PLANT_FLOOR.md` (→ **v1.2**).

- **Blocking fixes:** (1) Arc 1 actually shipped migrations through `0018`, so all Arc 2 migrations renumbered **`0014`–`0021` → `0019`–`0026`** and test suites → **`0020`–`0027`** (Arc 1 test suites end at `0019`). (2) **Phase 1 now CREATEs `Lots.Lot` (+ `LotStatusHistory` + `LotMovement`) and Phase 2 CREATEs `LotGenealogy` + `LotAttributeChange` + `LotLabel`** — these core tables were never built by Arc 1 (only the Lots *code* tables exist); the plan had wrongly ALTERed `Lot`.
- **Consistency:** `HoldEvent`/`DowntimeEvent`/`ShippingLabel` CREATE-ownership pinned (Phases 7/8/6); Phase 4 dep corrected to {1,3}; Phase 6↔7 schema cross-dep noted; gateway-script count five→six; stale v1.0a placeholder note removed; versions restamped (FDS v1.3 / DM v1.9o).
- **Three MVP gaps flagged for a scope decision** (not yet sized in-scope): G-1 inspection recording (FDS-08-011..013); G-2 Controlled Run Tag (FDS-10-012 — also missing from the **schema**, needs a DM bump); G-3 reporting + Global Trace Tool (FDS-12 — plan defers to an unscoped workstream).
- **New artifacts:** `MPP_MES_PLANT_FLOOR_PLAN_VALIDATION.md` (findings report), `MPP_MES_TASK_LIST_PLANT_FLOOR.csv` + `.xlsx` (**184 tasks, ~739 h / ~92 dev-days**; xlsx adds Workstream + SuggestedRole grouping + a swimlane ReadMe). Phase 9 holds the gap-fill tasks (T182/T183 CRT + T184 reporting marked **Blocked** pending decisions).
- **OI-35 still gates the actual SQL build** — the task list assumes the Phase 0 default decisions (closure table, monthly partitioning, materialized columns, OperationLog split); these must be ratified in Phase 0 before Phase 1 (`0020`) is written.
- **MVP scope ratified (2026-06-08):** quality-capture (G-1 inspection, FDS-08-011..013), the Controlled Run Tag workflow (G-2 — `Lot.CrtActive` added to the Phase 1 `Lot` CREATE, **Data Model v1.9q**), and the Global Trace Tool + LOT Genealogy Report (G-3a) are all **in-scope** as a new **Phase 9** (plan → **v1.3**). The legacy PD operational reports stay **deferred** to near/post-deployment (UJ-19). **Arc 2 migrations re-baselined +1 to `0020`–`0027`** (Phase 9 `0028`) because `0019_location_coupled_downstream_cell` landed on disk 2026-06-08 — the per-phase numbers are now next-free-at-build-time.

### Tools Config Tool — eligibility-style editor redesign spec'd (2026-06-05)

Brainstormed (with the visual-companion mockup tool) → design spec committed `7f41a2d`: `docs/superpowers/specs/2026-06-05-eligibility-style-config-editors-design.md`. **No implementation yet** — next step is `writing-plans`. Ports the Item Master eligibility editing model onto Tools Attributes/Cavities/Assignments + Operation-Template fields. Decisions: (1) full eligibility model (inline draft + Save/Discard + atomic SaveAll); (2) cavity status as inline dropdown, `ToolCavity_SaveAll` insert+update only (no delete-on-absent — end-of-life via Scrapped); (3) assignments adopt the look + inline mount (kills MountToCell popup) but stay immediate/audited with no draft; (4) no field ordering (no SortOrder); (5) type-aware attribute value inputs (text/numeric/checkbox/date by DataType, proc-validated). New procs planned: `ToolAttribute_SaveAll` (delete-on-absent — no DeprecatedAt column), `ToolCavity_SaveAll`, `OperationTemplateField_SaveAll`. Parent Tools + OperationTemplates views gain dirty-gating like Item Master.

### Tools Config Tool — Mount-to-Cell tool-type filter (2026-06-05) ⚠️ UNCOMMITTED

Mount-to-Cell dropdown now filters Cell-tier Locations to the kinds a tool type can mount on (Die → Die Cast Machine), instead of listing all 146 cells (presses + printers + terminals). Migration `0018_tooltype_compatible_celldef.sql` adds `Tools.ToolType.CompatibleLocationTypeDefinitionId` (FK → `Location.LocationTypeDefinition`, NULL = no restriction) and seeds Die→DieCastMachine by Code. New `Tools.Tool_ListCompatibleCells @ToolId` proc (rule in SQL per `feedback_no_business_logic_in_python`) + NQ; `getCellsForDropdown(toolId)` + the MountToCell binding pass the tool id; `ToolType_List`/`_Get` surface the column. Verified on dev: Die tool → 22 DieCastMachine cells only. **Data Model → v1.9o.** Applied non-destructively to `MPP_MES_Dev`; scanned. **Not committed — see Next Session Pickup.**

### Tools Config Tool — Retire/status + display bug-fixes (2026-06-05) ⚠️ UNCOMMITTED

Three issues from Jacques's review (root-caused via DB evidence, no guessing): (1) **Retire left status "Active"** — `Tool_Deprecate` set `DeprecatedAt` only, never `StatusCode`, and the chip reads `StatusCode`. Per decision, the proc now sets **StatusCode=Retired + DeprecatedAt** together (ISNULL-guarded, audit old→new status); verified via rollback-test; the already-retired `CAV-TEST-DIE` data-corrected to Retired. (2) **Rank pills/chips rendered literal "NULL"** — no tool has a DieRank; pills bound text directly to a null rank. Now hidden via `position.display = !isNull(...)` on `ToolRow.BadgeRank` + header `SummaryBadgeRank`. (3) **Description showed "null"** — `getOne` now coerces null→"" for display; `add`/`update` coerce ""→NULL so the DB keeps NULL. Also: the reported "assignment history vanished" was a **non-bug** — `CAV-TEST-DIE` was never mounted (audit + raw table confirm zero assignment rows; the two real assignments belong to ASN-DIE-A/B). Applied to `MPP_MES_Dev`; scanned. **Not committed — see Next Session Pickup.**

### Quality Spec Config Tool — built end-to-end + smoke-polished (2026-05-29)

Brainstormed/designed/planned previously; **built and smoke-tested in one session**. Executed the plan `docs/superpowers/plans/2026-05-28-quality-spec-config-tool.md` Phases A–H, then iterated on live-session smoke feedback. Parallel-subagent-draft → serialize throughout.

- **SQL (Phase A):** migration `0017` (`QualitySpecAttribute.UomId` FK + `QualitySpec.DeprecatedAt`/`DeprecatedByUserId` → `Location.AppUser`); 3 net-new procs `QualitySpecVersion_SaveDraft` / `QualitySpec_Deprecate` / `QualitySpecVersion_DiscardDraft`; readable-audit convention on every quality mutation proc; date-resolved Publish (no auto-deprecate). **SQL tests 1161/1161.**
- **Ignition (B–H):** 14 named queries; extended `BlueRidge.Quality.QualitySpec` entity script; `/quality-specs` master-detail screen; `QualitySpecAttributeRow`, `SpecListRow`, `VersionHistoryRow` flex-repeaters; `NewSpecModal`; route + sidebar nav (pre-existing); Item Master "Go to spec →" cross-nav.
- **Smoke fixes:** spec library + Version History converted table→flex-repeater (table column-width squish + em-dash mojibake + blank CreatedBy fixed); `ia.input.numeric-entry-field` (was nonexistent `numeric-entry`); `Lower≤Target≤Upper` validation enforced in `QualitySpecVersion_SaveDraft`; left-rail list refresh after publish/new-version/discard/deprecate; hide UOM/Target/Lower/Upper on non-Numeric attrs via `meta.visible`; `+ New Version` clones the *selected* version.
- **Date-resolved versioning surfaced:** per-version **Active / Scheduled / Superseded** state computed in SQL (`QualitySpecVersion_ListBySpec.State` via `@ActiveId` = max `EffectiveFrom ≤ now` among published-non-deprecated) + `GetActiveForSpec` `VersionNumber DESC` tiebreaker; shown in the version dropdown + Version History pills.
- **Key plan corrections caught at build:** plan's `Audit.AppUser` → real table is `Location.AppUser`; plan's A3 code had the `JSON_QUERY` double-encode bug; `QualitySpec_Update` SETs ItemId/OpTemplateId unconditionally (NULL-defaulting params would wipe links → NQ + entity pass them through); new tests written in the `test.Assert_*` framework (plan used raw RAISERROR).
- **Memory added:** `feedback_ignition_numeric_entry_field_type`. Context-pack `06_component_quirks` corrected (had the wrong numeric component id).

### Audit-readability refactor Slices 2.5 + 3–8 landed — refactor COMPLETE (2026-05-29)

Closed out the entire project-wide audit-readability refactor in one session. Slices 3–8 (the six backport slices, ~31 procs) were **drafted in parallel by six subagents** — one per slice, each given the Slice-2 reference impl + the three inherited fixes (`JSON_QUERY` wrap, `DATALENGTH` strip, boolean-words) — then serialized through a single deploy + full-test pass, triaged, and committed slice-by-slice. **SQL tests 1136/1136** (was 1060 after Slice 2; +76 convention-shape assertions).

- **Slice 2.5** — `Common.Util.prettyJsonDiff` (unified colorized diff: green add / red remove / yellow change; resolved-FK sub-objects collapse to `Code — Name`; degrades to +/−/~ symbols if HTML isn't rendered). ConfigChangeDetail popup gains an `ia.display.markdown` Changes block (`props.markdown.escapeHtml=false`, schema confirmed from a user-supplied markdown example) above the kept Old/New JSON blocks. **Visual smoke pending** (see Next Session Pickup). Commit `feat(audit): Slice 2.5 …`.
- **Slice 3 BOMs** — 6 `Bom_*` procs; lines resolve `ChildItem` + `Uom`, header resolves `ParentItem`.
- **Slice 4 Routes** — 6 `RouteTemplate_*` procs; steps resolve `OperationTemplate`, header resolves `Item`. Publish says "supersedes v<N-1>" (Routes don't auto-deprecate). 
- **Slice 5 Item core** — `Item_*` + `ContainerConfig_*` (5); Update procs capture pre-state for field-diffs.
- **Slice 6 Plant Hierarchy** — `Location_*` + `LocationAttribute_Set` (6); resolves Parent + LocationTypeDefinition.
- **Slice 7 LocationTypeEditor** — `LocationTypeDefinition_SaveAll`/`Deprecate` (2); attribute +/-/~ reconciliation + cascade count.
- **Slice 8 Downtime + Defect codes** — 6 atomic Create/Update/Deprecate procs; resolve Area + DowntimeReasonType.

**Triage fixes during serialization (3 failure clusters → all resolved):**
1. **Routes `Header` double-encoding** — subagents wrapped the inner `Item`/`OperationTemplate` in `JSON_QUERY` but left the outer `Header` subquery bare, so it double-encoded to an escaped string. Wrapped `Header` in `JSON_QUERY()` across all 5 route procs (7 spots).
2. **`ConfigLog_List` cross-contamination** — `030_RouteTemplate_SaveAll.sql` fixtures named `'SaveAll test item N'` surfaced in the new `Item_Create` narratives and matched the `@DescriptionLike='SaveAll'` filter (8 rows vs 1). Renamed to `'Route bundle item N'`.
3. **BOM Deprecate audit test** — v1 was auto-deprecated by the v2 publish (no standalone audit row) and the explicit v1 deprecate is an idempotent no-op; retargeted the assertion to deprecate the active v2.

### Quality Spec Config Tool — design + implementation plan committed (2026-05-28)

Brainstormed → designed → planned. No code yet; queued behind the audit refactor.

- **Spec:** `docs/superpowers/specs/2026-05-28-quality-spec-config-tool-design.md` (`4d4b07b`).
- **Plan:** `docs/superpowers/plans/2026-05-28-quality-spec-config-tool.md` (`35859a1`). 9 phases / ~18 tasks, SQL-first, complete code for net-new SQL + entity script, mirror-with-deltas for the large views.
- **Key finding:** the Quality SQL layer was **already built** (migration `0008` + ~20 procs + `sql/tests/0011_Quality_Spec/`). This build is mostly Ignition front-end plus a contained SQL delta.
- **Design decisions captured this session:**
  - Standalone `/quality-specs` master-detail screen (NOT an Item Master tab — the mockup designs it standalone; Item Master tab stays link-only) + Phase 7 "Go to spec →" cross-nav folded in.
  - Lifecycle: Draft/Published/Deprecated (BOMs vocabulary on the built procs), but **date-resolved active versions — Publish does NOT auto-deprecate the prior Published version** (`_GetActiveForSpec @AsOfDate` resolves the active one; future-effective Published = "Scheduled" badge). This reconciles the mockup's Active/Pending model with the built Draft/Published procs.
  - `QualitySpecAttribute.UomId` FK dropdown (not free text) → SQL delta: migration `0017` adds the FK.
  - Add `QualitySpec_Deprecate` header soft-delete proc (+ `QualitySpec.DeprecatedAt`); add bundled `QualitySpecVersion_SaveDraft` (per the editDraft/explicit-Save convention; the per-action `_Add/_Update/_MoveUp/...` procs stay but aren't called per-click).
  - **Audit-readability convention applied to every quality-spec mutation proc from day one** (per the audit refactor spec §3/§4 + a richer quality catalog in the design §7) — so quality specs never need a backport slice.
- **Front-end reference:** mirrors the BOMs versioned-editor impl (`BlueRidge.Parts.Bom` + `Components/Parts/ItemMaster/Boms` + `BomLineRow`) — atomic state writes, binding-based dirty, input-only embeds via page-scoped messages — but in a standalone `LocationTypeEditor`-style shell.

### Audit-readability refactor Slice 2 landed (2026-05-29)

`Parts.ItemLocation_SaveAllForItem` is now the **reference implementation** of the `SUBJECT · CATEGORY · ACTION` convention; Slices 3-8 mirror this proc.

- **Subject resolution**: `PartNumber — Description` resolved once at proc start via `Audit.ufn_MidDot()` separator.
- **Change-set classification**: a `@Changes` table variable buckets the reconciliation into `+` (add, incl. reactivation-as-add), `~` (update with field-level diff), `-` (remove), each joined to `Location.Location` + `Location.LocationTypeDefinition` for resolved names — all computed from **pre-mutation** state before `BEGIN TRANSACTION`.
- **Activity narrative**: `STRING_AGG ... WITHIN GROUP` composes per-op specifics with a 3-per-op cap + `+N more` overflow counters; capped at 500 via `Audit.ufn_TruncateActivity()`. Live example produced in tests: `TEST-ELIG-ITEM-001 — Eligibility map test item · Eligibility · +DIECAST (Production Area); 1 rows`.
- **Resolved-FK JSON**: `OldValue`/`NewValue` expand `LocationId` to `Location: {Id, Code, Name}` sub-objects (one JOIN per row at write time, zero at read time).
- **Two defects caught in the plan's SQL** (both fixed in the reference impl, both flagged for Slices 3-8 in Next Session Pickup):
  1. Resolved sub-object emitted via a bare aliased `FOR JSON` subquery — SQL Server double-encodes that as an escaped *string*, not a nested object. Fixed by wrapping in `JSON_QUERY((...))`.
  2. Trailing-`"; "` strip used `LEFT(x, LEN(x) - 2)`; `LEN()` ignores trailing spaces so it ate one real char off the last specific (`5→nul`, `Area`). Fixed to `LEFT(x, DATALENGTH(x)/2 - 2)`.
- **Boolean rendering**: field-diffs on `BIT` columns render as words (`IsConsumptionPoint true→false`), not `1→0` — readability convention for all slices.
- **Tests**: 6 new convention-shape assertions (Tests 9-13: SUBJECT·Eligibility· prefix, `+<Code>` presence, resolved `Location` Id/Code/Name in NewValue, length ≤ 500, plus Test 13's `~`-update path asserting `true→false` words + the last specific surviving intact). The Eligibility test item was renamed off "SaveAll" to stop its audit narrative cross-matching `ConfigLog_List`'s `@DescriptionLike='SaveAll'` filter. **1060/1060 SQL tests.** Proc at v1.3.
- **Designer smoke (Task 2.8) DONE 2026-05-29** — `/items → Eligibility → Save → /audit` verified narrative + resolved-name popup; ConfigChangeDetail EntityLine `\u` binding error fixed (literal middle-dot).

Proc bumped to v1.1. Files: `sql/migrations/repeatable/R__Parts_ItemLocation_SaveAllForItem.sql`, `sql/tests/0009_Parts_Process/040_ItemLocation_SaveAllForItem.sql`.

### Audit-readability refactor Slice 1 landed (2026-05-28)

First slice of the project-wide audit-log readability refactor spec'd at `docs/superpowers/specs/2026-05-28-audit-readability-refactor-design.md`. Five tasks landed across 6 commits:

- **Helpers**: `Audit.ufn_MidDot()` returns `NCHAR(183)` middle-dot separator; `Audit.ufn_TruncateActivity(@text)` applies the 500-char cap with `NCHAR(8230)` ellipsis suffix on overflow + NULL passthrough. 6 truncate tests pass. **1054/1054 SQL tests total.**
- **Convention codified**: `sql_best_practices_mes.md` gained a full "Audit Log Description Convention" section covering the `SUBJECT · CATEGORY · ACTION` shape, verb/symbol vocabulary, field-diff notation, truncation rules, and FK-resolution rule. CLAUDE.md gained a brief pointer subsection. New procs inherit the convention; existing procs migrate as touched in Slices 2-8.
- **AuditLog UI**: dropped meaningless numeric `EntityId` column; added `ChangesSummary` column between Event and Severity (powered by yesterday's `BlueRidge.Common.Util.summarizeJsonDiff` helper); renamed `Description` column header to `Activity`. Scoped monospace+ellipsis CSS for the Changes column under `.psc-audit-log-table`. Absorbed yesterday's `HANDOFF_AUDIT_LOG_2026-05-28.md` (handoff deleted).
- **Popup fixed**: `BlueRidge/Components/Popups/ConfigChangeDetail` opens correctly on row click. Three bugs found via a one-shot diagnostic log of `event.keys()` + `str(event)`:
  1. Event name was `onRowClick` which `ia.display.table` doesn't dispatch in 8.3 — silent no-op, nothing in logs. Standard event is `onSelectionChange`. Switched.
  2. Event payload is a PyDictionary not an object. `hasattr(event, "selection")` returned False because `selection` would be a KEY not attr. Plus event uses `selectedRow` (int index) not `selection` (array). Plus `if not sel:` would silently return on `selectedRow=0`. Switched to dict `.get()` + explicit `if sel is None` check.
  3. EntityLine binding used `coalesce(BIGINT entityId, '(new)')` which fails Quality due to type mismatch. Rendered as 'null' + red error indicator. Switched to `if(isNull(...), '(new)', toStr(...))` to force string type.

Commit chain on main: `159bc73` (ufn_MidDot) → `66a7ab5` (ufn_TruncateActivity + tests) → `2d0b16b` (convention codified) → `129aaa9` (AuditLog UI + handoff absorption) → `91fa14d` (popup fixes + Slice 2.5 plan add).

Slice 2.5 added to the implementation plan: diff highlighting on the popup via `ia.display.markdown` + new `Common.Util.prettyJsonDiff` helper. Deferred until after Slice 2 lands resolved-name JSON, because highlighting bare-ID diffs `LocationId 4 → 5` is useless whereas `Location DC-401 → DC-402` is actionable.

**Lessons captured (no new memories this slice, but noted for future):**
- `ia.display.table` standard event for row clicks in 8.3 is `onSelectionChange`, NOT `onRowClick`. Silent no-op if event name is wrong — no error logged anywhere. Diagnostic was to add `log("event attrs=" + str(dir(event)))` at script entry; if log doesn't appear, event isn't dispatched.
- `event` payload for `onSelectionChange` is a PyDictionary with keys `selectedRow` (int), `selectedColumn` (str), `data` (the visible-column subset of the row, NOT the full row data). For full row use `self.props.data[idx]`.
- `event.get("selectedRow")` returns 0 for the first row — using truthy `if not sel: return` silently breaks on that row. Use explicit `if sel is None: return`.

### Item Master Phase 8 Eligibility editor — end-to-end smoke green (2026-05-28)

Closed out Phase 8 — the last big tab in the Item Master refactor. Full vertical stack landed in 16 commits (`31f66cb`..`0a83224`), all 14 spec §9 smoke steps pass:

- **SQL** — `Parts.ItemLocation_SaveAllForItem` (bundled reconcile: add / update / deprecate / reactivate-deprecated all atomically), `Location.Location_ListForEligibilityPicker` (tier-grouped picker read with `NCHAR(8212)` em-dash to avoid `sqlcmd` codepage trap), `Parts.ItemLocation_ListByItem` bumped to v3.0 (added `TierOrdinal`, re-sorted `(tierOrdinal, code)`). 11 SaveAll tests + 3 picker tests pass. Existing 64 ItemLocation CRUD tests still pass after widening `#IlByItem1`/`#IlByItem2` scratch tables for the new column. **1048/1048 SQL tests passing.**
- **Ignition** — 3 NQ wrappers (SaveAll + picker + **previously-missing** `ItemLocation_ListByItem` read NQ — `6527d24` was the root cause of all the post-save dirty-stuck symptoms, see below), `BlueRidge.Parts.Eligibility` entity script, new `EligibilityRow` sub-view (page-scoped message propagation per `feedback_ignition_embed_params_input_only`), and full rewrite of `Eligibility/view.json` per per-section ownership pattern matching BOMs.
- **Pattern adherence** — `isDirty` binding uses the canonical BOMs-equivalent `runScript("BlueRidge.Common.Util.convertWrapperObjectToJson", 0, {view.custom.state.editDraft.rows}) != ...{state.selected.rows}` expression. No divergence from the per-section ownership convention.

**Process lesson (captured as memory `feedback_check_nq_files_first`)**: I spent four rounds patching the `isDirty` binding (property+transform variants, type comparison tweaks, deep-path watching theories) chasing a "save success toast but dirty stays true" symptom. The actual root cause was a missing NQ file (`parts/ItemLocation_ListByItem`) which the plan had assumed already existed. `load()` was failing silently with `java.lang.Exception: Named query not found` every call, so `state.selected` never reset post-save. **Lesson:** when a new editor following an established pattern misbehaves in surprising ways, FIRST check the gateway log for `Named query not found` traces — don't immediately blame the binding or comparison logic. 30-second diagnostic vs hours of binding archaeology.

**Plan deviations (all documented in commits):**
- Tier filter in tests uses `lt.Code = N'Area'` / `N'Cell'`, not `ltd.Name = N'Area'` — dev seeds carry definition names like `'Production Area'` / `'CNC Machine'`.
- Test Item insert uses `CreatedByUserId` (Parts.Item has no `IsActive` column).
- Picker proc uses `NCHAR(8212)` (em-dash codepoint) instead of literal em-dash in source — sqlcmd was loading the UTF-8 source file with the Win-1252 codepage and storing the wrong 3-byte sequence in the proc body. Same fix applied to the test's LIKE pattern via `@Sep NVARCHAR(5) = NCHAR(8212)`.
- Row qty fields (`Min`/`Max`/`Default`) use `meta.visible` not `position.display` so the 240px slot stays reserved when `IsConsumptionPoint` is off (uniform row geometry per user feedback).
- Save (`props.enabled`) + Discard (`meta.visible`) wrap `view.custom.isDirty` in `if(isNull(...), false, ...)` defensive guard so a transient Quality-Bad doesn't cascade to Component Error.

Audit-log "Changes" column work from 2026-05-27 evening is still uncommitted in working tree alongside the Phase 8 commits — see "Next Session Pickup" above. The two workstreams touched disjoint files; no interference.

### Item Master Phase 3 dirty-drift blocker resolved + Phase 6 BOMs smoke green (2026-05-27 → 2026-05-28)

Closed out the per-section dirty-drift blocker that had been gating Phase 3 closeout for a week. Two compounding bugs in `BlueRidge.Common.Util.convertWrapperObjectToJson` + `load()` racing:

1. **Shallow unwrap.** `convertWrapperObjectToJson` was `return dict(obj)` — handed back a Python dict containing raw `BasicQualifiedValue` leaves. The dirty-binding expression then either compared two dicts whose Java-wrapper identities drifted between reads (false-positive dirty), or — once `system.util.jsonEncode(dict(obj))` was tried — choked because jsonEncode can't serialize raw QV objects (binding evaluated to null, "Error_Configuration"). Fix: `return system.util.jsonEncode(extractQualifiedValues(obj))`. The existing `extractQualifiedValues` already handles `JavaMap` + `QualifiedValue` recursively — which is exactly the shape that arrives at runScript (`HashMap` of `BasicQualifiedValue`). Confirmed via diagnostic logging that captured both sides' types + reprs.

2. **Load-race architecture.** Even with deep unwrap, the dirty-binding still fired spuriously on cross-item nav because `load()` was writing `self.view.custom.selected = X; self.view.custom.editDraft = X` as two SEQUENTIAL property assignments. Between the writes the binding evaluated with `selected = new item, editDraft = old item` → dirty=true → `sectionDirtyChanged{isDirty:true}` propagated → parent latched `sectionDirty.<section> = true`. The subsequent dirty=false transition either coalesced or arrived after the parent already gated navigation. **Fix:** wrap both in a single `view.custom.state` parent property and write atomically: `self.view.custom.state = {"selected": dict(loaded), "editDraft": dict(loaded)}`. Applied to Identity, ContainerConfig, BOMs (per-section ownership), and Routes (the only one that uses explicit `broadcastDirty()` instead of binding-driven dirty).

**Phase 3 smoke (steps 1–16, including the previously-blocked cross-item nav steps 10–16) all PASS.**

**Phase 6 BOMs end-to-end smoke (B1–B13) also all PASS** in the same multi-day session. Numerous fixes layered on top of the per-section state refactor:

- **Six BOM mutation NQs** (`Bom_Create`, `Bom_CreateNewVersion`, `Bom_Publish`, `Bom_SaveDraft`, `Bom_Deprecate`, `Bom_DiscardDraft`) were mistyped as `UpdateQuery`. JDBC's executeUpdate path throws on the status-row SELECT every project mutation proc returns — "A result set was generated for update." The procs succeeded server-side, but client got an exception, no toast fired, no UI updated. Flipped all six to `type: "Query"`. New memory: `feedback_ignition_nq_type_for_status_row_procs`.
- **`forEach` in Ignition expressions doesn't exist.** Four BOMs/BomLineRow bindings (`VersionDropdown.options`, `LinesRepeater.instances`, `ItemPicker.options`, `UomEdit.options`) had been authored as `forEach({list}, {label: ..., value: ...})` expressions and silently failed with "Nested paths not allowed" / "TagPathFormatException". Converted all four to property binding + script transform, mirroring Routes' working pattern. New memory: `feedback_ignition_no_foreach_in_expressions`.
- **`BomLineRow` was nested under `Boms/`.** Same "Ignition can't load views nested under other views" trap that hit `DraftStepRow` yesterday. Moved to `ItemMaster/BomLineRow/` as a sibling of the other section embeds.
- **Embed sub-view params are input-only.** `BomLineRow.QtyEdit` + `UomEdit` were bidi-bound to `view.params.line.X` — writes silently dropped, never reaching the parent. Save Draft stayed disabled after qty edits; UOM "reverted to EA" on every pick. Added page-scoped `bomLineQtyChanged` + `bomLineUomChanged` messages with `_applyQtyChange` + `_applyUomChange` customMethods on the parent. New memory: `feedback_ignition_embed_params_input_only`.
- **`handleNewVersion` didn't load state inline.** Was relying on `activeVersionId.onChange` → `loadActiveVersion()` chain to populate the new draft's content. The chain didn't reliably fire. Now `handleNewVersion` explicitly fetches the bundle and writes `view.custom.state = {selected, editDraft}` synchronously, same pattern Routes' `BtnNewVersion` uses.
- **Single-Published invariant + pre-publish confirmation UX.** Catching that v1 + v2 could both have `DeprecatedAt IS NULL` for the same `ParentItemId`: `Bom_Publish` now auto-deprecates any prior Published version in the same transaction, with an `OUTPUT inserted.VersionNumber INTO @DeprecatedVersions` so the success message reads "Published v2. Deprecated v1." Publish button now routes through a new `requestPublish` customMethod that inspects `view.custom.versions` for a prior Published row — if found, opens the existing `ConfirmDestructive` popup ("Publish v2? This will deprecate v1 currently active in production."); first publish goes direct. Commit `f6df905`.
- **Layout polish.** ColMove/ColRm header placeholders converted from empty `ia.display.label` to empty `ia.container.flex` so they reserve slot width when invisible (labels collapse on `meta.visible: false`). Draft/Published alternate columns switched from `meta.visible` to `position.display` (alternates that share a column should collapse, not both reserve space). All BomLineRow controls get uniform `height: 30px` so bottom edges align. ColArrows widened 52px → 72px so arrows fit side-by-side.
- **Component filter.** `Parts.ItemLocation_ListAvailableForBom` excludes `ItemType.Name = N'Finished Good'` per business rule (BOM components are never Finished Goods).

Commit chain on main (this session): `bd00c5e` (per-section atomic state writes + extractQualifiedValues chain) → `5b13cc1` (yesterday's DraftStepRow polish) → `44ec8b7` (script-console demo) → `1049ea3` (BOMs end-to-end smoke fixes bundle) → `c27c36d` (Routes elementStyle parity) → `f6df905` (BOMs Publish invariant + UX).

**Memory updates (durable lessons captured):**
- `project_mpp_item_master_pattern` — added "Atomic state writes" addendum documenting the `view.custom.state = {selected, editDraft}` single-write rule + the `convertWrapperObjectToJson` co-fix.
- `feedback_ignition_nq_type_for_status_row_procs` — NEW. Mutation procs returning status-row SELECT must have NQ `type: "Query"`, not `UpdateQuery`.
- `feedback_ignition_no_foreach_in_expressions` — NEW. Ignition expression language has no iteration primitive; use property + script transform.
- `feedback_ignition_embed_params_input_only` — NEW. Sub-view params are input-only; bidi writes to nested paths under `view.params.X` get silently dropped; use page-scoped messages.
- `feedback_no_business_logic_in_python` — NEW. Jacques rule: business rules (compatibility matrices, validation thresholds, etc.) live in SQL, never in Python entity scripts.
- `CLAUDE.md` § Compound editors with per-section ownership — strengthened with the atomic-state-write paragraph + embed-to-parent propagation paragraph.

### Item Master Phase 8 Eligibility — spec + implementation plan committed (2026-05-27)

Brainstormed + designed + planned. Code not yet landed.

- Spec: `docs/superpowers/specs/2026-05-27-item-master-eligibility-design.md` (commits `03c50e0` + `8fc736d` self-review).
- Plan: `docs/superpowers/plans/2026-05-27-item-master-eligibility.md` (commit `84a2a0b`). 10 tasks, SQL-first, every task has exact file paths + complete code blocks + expected sqlcmd output.
- Pattern: per-section ownership with atomic state writes (same pattern locked in Phase 3 fix).
- Editor model: tiered list (one row per `Parts.ItemLocation` row), single typeahead Location dropdown grouped by tier, bundled SaveAll proc with reactivate-deprecated semantics, no client-side business-rule enforcement.
- Schema already supports the design — `Parts.ItemLocation` already has the consumption-metadata columns from migration 0010. No new migration needed.

### Item Master Phase 6 — BOMs versioning workflow landed via rebase + ff-merge (2026-05-26)

Second versioned per-section embed to ship (after Phase 5 Routes). The BOMs tab on `/items` now supports the full Draft → Published → Deprecated lifecycle: create new version (clone last Published into Draft), add/edit/remove component-item lines (Item dropdown + UoM auto-populate + Qty + IsScrapTracked), Save Draft (bundled JSON-line reconciliation via `Bom_SaveDraft` — physical DELETE/UPDATE/INSERT since `BomLine` has no `DeprecatedAt`), Publish (atomic save-then-publish with optional `EffectiveFrom` + min-1-line guard moved BEFORE `BEGIN TRANSACTION` to avoid Msg 3915 in INSERT-EXEC tests), Discard Draft (hard delete + cascade), Deprecate Published (idempotent). Filtered UNIQUE index `UX_Bom_ActiveDraft` enforces one Draft per ParentItemId. New migration: `0016_parts_bom_unique_draft.sql`.

Built in worktree `.claude/worktrees/Agent-B-item-master-boms`, then **rebased onto main** after main absorbed Phase 5 Routes + Phase 3 Item CRUD which collided on three surfaces:

- **Migration slot collision** — `0015_parts_bom_unique_draft.sql` renamed to `0016_*` (0015 taken by main's `audit_add_event_type_deleted`).
- **`Uom_List` NQ add/add** — kept main's `EXEC Parts.Uom_List @IncludeDeprecated = :includeDeprecated` signature; deleted BOMs' duplicate; updated `BlueRidge.Parts.Bom.listUoms()` to pass `{"includeDeprecated": False}`.
- **Generic 2-button confirm popup duplication** — swapped BOMs' new `ConfirmAction` for main's `ConfirmDestructive`; updated 2 callers in `Boms/view.json` (`openDeprecateConfirm`, `openDiscardDraftConfirm`); deleted `ConfirmAction` view dir. Orphan `f30be77 feat(popups): reusable ConfirmAction popup` commit still in history → `682905b` deletes its files (net effect correct; squash if cleaner log desired).

**Pattern backports from main's Routes versioning work (post-fork commits):**

- **`85986c3` isDirty deep-compare** — backported as `43c20bd`. BOMs' `view.custom.isDirty` was comparing `editDraft.lines != selected.lines` (list reference equality); now routes both sides through `Common.Util.convertWrapperObjectToJson` for primitive-level equality. **This is the candidate fix-pattern for the open dirty-drift blocker on Identity/ContainerConfig.**
- **`e7f2f3e` / `404b51b` ImmutableMap unwrap in versions.onChange** — NOT APPLICABLE; BOMs has no versions.onChange handler (uses runScript-bound dropdown + Python entity returning plain `list[dict]`); uses `flex-repeater` not `ia.display.table`.
- **`e29c670` selectedItem default shape restore** — NOT APPLICABLE; BOMs `view.custom.selected` + `editDraft` already declare full nested empty shape.
- **`a391f07` Routes onChange bracket-access on ImmutableMap (not broken json.loads roundtrip)** — landed AFTER the rebase agent did its main pass; BOMs absorbed via a second silent rebase before ff-merge. BOMs has no analogous onChange callsite.

**Pre-existing test bug recovered:** `010_Bom_crud.sql` had a `#BomListScratch` temp-table that wasn't widened when `R__Parts_Bom_ListByParentItem.sql` went to v3 (added `LineCount` + `Status` columns). INSERT-EXEC was throwing Msg 213 silently aborting the whole file via `sqlcmd -b`, skipping ~13 trailing assertions including `[BomCreateHappy]`. Fixed in `705986e` as part of the rebase pass.

**Final 11-commit set on main:** `971c2f4` SQL backend → `c61db35` 10 NQs → `ae481b5` entity script → `f30be77` ConfirmAction (orphaned later) → `d357a95` BomLineRow → `38639a1` BOMs embed wire → `217c540` migration renumber → `c2962c1` Uom_List signature → `682905b` ConfirmAction→ConfirmDestructive swap → `43c20bd` isDirty deep-compare → `705986e` `#BomListScratch` widen. Merged ff-only.

**SQL tests:** 1034/1034 passing (was 972 on BOMs branch pre-rebase; +62 from main's Phase 5 Routes additions + recovered `010_Bom_crud.sql` assertions).

**Pickup tomorrow:**

1. **Smoke-test BOMs end-to-end in Designer** — open `/items`, pick 5G0, click BOMs tab. Verify: versions list with line-count + status badges; `+ New Version` → clones last Published into Draft + EffectiveFrom prefill + success toast; edit qty → `●` dirty + tab disable; `+ Add Component` Item dropdown auto-populates UoM; reorder arrows; row `×` remove; `Save Draft` → reload persists; `Publish` (zero-line + missing EffectiveFrom blocked; valid → status flip); `Deprecate` → `ConfirmDestructive` → status flip; `Discard Draft` → `ConfirmDestructive` → version vanishes; tab-switch with dirty Draft triggers ConfirmDestructive gate (parent's Phase 4 infrastructure carries this); `Audit.ConfigLog` rows for every mutation.
2. **Reset dev DB** — `.\Reset-DevDatabase.ps1` to land migration 0016 cleanly (if `0015_parts_bom_unique_draft` row exists in `SchemaVersion` from pre-rebase, the reset rebuilds from scratch).
3. **`.\scan.ps1`** before Designer testing to pick up new NQs + 2 new views + restructured `Boms/view.json`.
4. **Try `43c20bd` deep-compare pattern on Identity + ContainerConfig isDirty** — first diagnostic step for the open editDraft-drift blocker (both currently do reference-equality on dict-typed editDraft vs selected, the exact bug the BOMs backport addressed).
5. **Working tree on main has uncommitted edits** to `ItemMaster/{resource.json, view.json}` from prior Identity bug investigation — survived the merge intact; decide whether to commit / discard / continue iterating before re-opening Designer.
6. Optional cleanup: interactive-rebase squash `f30be77` (orphan ConfirmAction add) into `682905b` (its delete) for tidier log.
7. Optional: remove worktree `git worktree remove .claude/worktrees/Agent-B-item-master-boms` (Agent-A + Agent-C worktrees still in use for parallel work).

### Item Master Phase 4 — ContainerConfig save + parent gate infrastructure (2026-05-26)

First section to ship under the per-section ownership convention. ContainerConfig embed now owns its own `view.custom.selected` + `view.custom.editDraft` locally, receives a plain BIGINT `params.value: itemId` (input-only, no bidi Object-param), fetches its own data via `BlueRidge.Parts.ContainerConfig.getByItem` on `params.value` onChange, has its own Save / Discard buttons in a HeaderRow, broadcasts `sectionDirtyChanged` page-scoped on every dirty transition, and listens for `sectionSaveRequested` / `sectionDiscardRequested` from the parent. New `TargetWeight` field with `position.display` gated on `ClosureMethod == 'ByWeight'`. `handleSave` coerces string text-field input → numeric (text-field bidi writes strings into editDraft, so the plan's `trays <= 0` would silently misvalidate in Jython 2).

Parent ItemMaster view demolished the old bundled `editDraft` / `selected` / `mode` props (never properly populated anyway) and added the per-section gate infrastructure:

- `view.custom.selectedItemId` (BIGINT, set on item-row click); all 5 tab embeds receive `params.value: selectedItemId` input-only.
- `view.custom.activeTabIndex` (int, bidi-bound to TabContainer.currentTabIndex). View-level onChange interceptor stages `pendingSwitch` and opens ConfirmUnsaved when leaving a dirty section, then auto-reverts.
- `view.custom.sectionDirty` flag map populated by listening to `sectionDirtyChanged` from sections.
- `view.custom.pendingSwitch` staging area for the intercepted nav event.
- `root.scripts.customMethods`: `openConfirmUnsaved(sectionKey)`, `completeSwitch()`, `cancelSwitch()`.
- `root.scripts.messageHandlers`: rewritten `itemRowClicked` (gated by any-section-dirty), new `sectionDirtyChanged`, new `confirmUnsavedResult` (save → page-msg `sectionSaveRequested`; discard → page-msg `sectionDiscardRequested`; cancel → drop pendingSwitch).
- TabContainer `props.tabs` bound via `runScript(BlueRidge.Parts.Item.itemMasterTabLabels, 0, {view.custom.sectionDirty})` — returns a plain Python list[str] with `●` prefix on dirty sections. Initial `[if(...), ...]` expression-array-literal binding caused a red error at the top of the tab strip; runScript binding is cleaner.

Identity panel (DetailsHeader) restored as **read-only display** binding to a new `view.custom.selectedItem` prop populated via `runScript(BlueRidge.Parts.Item.getOneOrEmpty, 0, {view.custom.selectedItemId})`. `getOneOrEmpty` returns the full Item key-shape with null values when itemId is null/missing, so cold-open bindings render clean rather than Quality-Bad. All Identity inputs are `enabled: false`; Save / Deprecate buttons toast Phase-3 placeholders. Phase 3 will carve Identity into its own embed and wire bidi editing.

Plan deviations (all called out in commit messages):

- **sqlType corrections**: plan said `INT → 4`, `DECIMAL → 8`; correct values from the empirical Designer-canonical enum (per `ignition-context-pack/04_named_queries.md`) are `INT → 2` (Int4) and DECIMAL has no native code so `→ 5` (Float8 — JDBC coerces).
- **`self.X()` not `self.rootContainer.X()`** inside `root.scripts.messageHandlers` and `root.scripts.customMethods`: per the verified `ignition-view-customMethods-scope` memory, `self` IS the root component at that scope. The plan-text had the wrong addressing.
- **`{X} != null` not `isnull(X, 0) != 0`** for nullable-BIGINT visibility gates: `isnull(value, default)` is SQL; Ignition expressions use `isNull(value)` or direct null comparison. The wrong syntax silently fail-evaluated to Quality-Bad and propagated to the view-level ERROR banner.

Commit range: `4e2f47d` (NQ Create) → `8c72bea` (NQ Update) → `bcb4575` (entity script) → `981b816` (ContainerConfig embed) → `7731120` (parent gate) → `61a9eaa` (DetailsHeader excise + tab init fix) → `08256e0` (expr/runScript fixes) → `be207a5` (Identity read-only restore).

**Status**: full smoke (spec §7 steps 1–11) passed 2026-05-26.

**Late-stage smoke fix (`2817cdd`)**: spec §7 step 4 originally wanted a ConfirmUnsaved popup on tab clicks with revert-to-current-tab semantics. `ia.container.tab` in Ignition 8.3 doesn't expose `instantiation` / `keepAlive` / pre-change events, so the popup-intercept-with-state-preservation pattern is infeasible against that component. Pivoted to the **tab-objects pattern** — `props.tabs` accepts a list of dicts per tab with `text` / `runWhileHidden` / `disabled` fields. New `BlueRidge.Parts.Item.itemMasterTabObjects(sectionDirty, activeTab)` returns objects with `runWhileHidden: true` (keeps inactive embeds mounted, preserves their local editDraft across tab visibility changes) and `disabled: true` on every non-active tab when any section is dirty (locks navigation visually instead of via script intercept). The active tab still shows the `●` dirty-dot prefix as the cue. Item-row click popup intercept stays as-is (separate code path). Spec §7 step 4 should be retro-edited to describe this UX. Reference: [Ignition tab container docs](https://www.docs.inductiveautomation.com/docs/8.3/appendix/components/perspective-components/perspective-container-palette/perspective-tab-container#adding-components-to-tabs).

### Defect Codes — Task 8 complete (2026-05-20)

The flex-repeater never re-rendered because the screen chained two bindings: a query+transform on `view.custom.allRows` (Python list[dict] with `java.sql.Timestamp` values from unread CreatedAt/DeprecatedAt) feeding a second expression binding `runScript("...filterAndMapRows", 0, {view.custom.allRows}, {view.custom.filter.searchText})`. Substituting a freshly transformed list-of-dicts back into another binding's args chokes Perspective's marshaling. Script Console didn't reproduce because it sends literal Python objects.

**Fix (`15eeee2`):** consolidated to the DowntimeCodes peer pattern — new `BlueRidge.Quality.DefectCode.search(filter)` does DB + client-side text filter + row mapping in one shot; `view.custom.rows` binds via single expr `runScript("...search", 0, {view.custom.filter})`; the flex-repeater downgrades to a plain property binding on `view.custom.rows`.

**Bundled follow-ups:**
- `15eeee2` — "Area (optional)" → "Area" label + handleSave null-area warning toast guard
- `75b4420` — Editor `editDraft.meta` initialized to the proper empty shape upfront (was `null`, causing red borders and "null" text on first render); explicit `props.text:""` on Excused checkbox (suppresses component default placeholder); list-view IncludeDeprecated wrapped in `IncludeDeprecatedField` matching DowntimeCodes filter sidebar
- `16291b6` — DefectCodeRow gains `params.deprecated` + root opacity binding (55% fade) + EditButton conditional hide for deprecated rows
- `4922ec4` — Both DefectCodeRow and DowntimeCodeRow switched EditButton hide from `position.display` to `meta.visible` so the 80px slot stays reserved and Area/Excused columns hold their x-position across deprecated rows ([[ignition-meta-visible-in-tables]])

Smoke-confirmed by Jacques: add, deprecate, filter all working.

### Defect Codes — open follow-ups (not blocking)

- **`getAllAreas` vs `listByTier`** — Task 5 added `listByTier` as a generic primitive but neither Task 6 (popup) nor Task 7 (list view) ended up using it. Ships with zero consumers. Cleanup option: migrate both area-dropdown sites to `listByTier('Area')` + transform when next touched.
- **Parity opportunity in DowntimeCodeEditor** — same `editDraft: {meta: null}` initial state and unset `props.text` on Excused checkbox. Symptoms haven't been reported there (its `params.editId` onChange populates meta earlier in lifecycle) but the same two-line fix would close the latent risk.

---

This file holds the **volatile** state of the project — current doc versions, active blockers, recent change narrative, and the next-session briefing. Durable identity, document map, architecture, and conventions live in `CLAUDE.md`.

---

## Current Document Versions

| Doc | Version | Rev Date | Status / Notes |
|---|---|---|---|
| Data Model | **v1.9q** | 2026-06-08 | Current. v1.9q (2026-06-08): `Lots.Lot.CrtActive BIT` added (FDS-10-012 Controlled Run Tag hook). v1.9p (2026-06-08): Location `CoupledDownstreamCellLocationId` typed-FK promotion (migration `0019_location_coupled_downstream_cell`) + `Quality.QualityResult.NumericValue` + OI-35 scaling fold-in. v1.9o: `Tools.ToolType.CompatibleLocationTypeDefinitionId` (migration `0018`) for the Mount-to-Cell tool-type filter (Die→DieCastMachine). v1.9n (2026-06-04): sub-LOT split relocated Trim OUT → Machining OUT. v1.9m: `Parts.OperationTemplate.RequiresSubLotSplit`. |
| FDS | **v1.4** | 2026-06-10 | Current. v1.4 (2026-06-10): terminal-mode view-policy model — FDS-02-010 rewritten (behavior by assigned view; parent-tier derivation retired), 02-008/009/011 + 04-003 amended, 04-006 unchanged; header-version stale note resolved. v1.3 (2026-06-03): sub-LOT split relocated Trim OUT → Machining OUT. v1.2 (2026-05-18): `ParentLocationId` immutability (FDS-02-002a). v1.1 (2026-05-12): Customer Acceptance signature page. v1.0 (2026-05-04): first customer-review release. |
| Open Issues Register | **v2.17** | 2026-05-01 | Current. **9 items closed** from Jacques's 2026-05-01 markup: OI-07, -24, -25, -27, -28, -29, -30, -31, UJ-03 → all ✅ Resolved. 6 items remain Open. |
| Outstanding Items extract | **v2.0** | 2026-05-01 | Current. Reduced to 6 Open items per OIR v2.17. |
| User Journeys | **v0.9** | 2026-04-29 | Current. FDS v0.11m reconciliation pass. |
| Phased Plan — Plant Floor (Arc 2) | **v1.3** | 2026-06-08 | Current. v1.3 (2026-06-08): MVP gaps (inspection / CRT / Global Trace) ratified in-scope as Phase 9; `Lot.CrtActive` added (DM v1.9q); Arc 2 migrations re-baselined +1 to `0020`-`0027` (Phase 9 `0028`). v1.2 (2026-06-08): validation-correction pass — migrations renumbered `0019`–`0026` / test suites `0020`–`0027`; Phase 1 CREATEs `Lot` + history (was wrongly ALTERed); Phase 2 CREATEs genealogy/attr/label; CREATE-ownership + dep-table + version fixes. v1.1 (2026-06-03): sub-LOT split → Machining OUT. Companion: validation report + task list (CSV/xlsx). |
| Phased Plan — Config Tool (Arc 1) | v1.7 | earlier | All 8 phases built and tested. |
| Seeding Registry | v1.0 | earlier | Current. |
| ERD | (current through v1.9i) | — | **Pending refresh** — see ERD Refresh Queue below. |

---

## 🚨 Active Blockers

### OI-35 — Architecture Decision Gate (HIGH)

**Long-horizon scaling, retention, archiving strategy must resolve before Arc 2 Phase 1 SQL build (`0014_arc2_phase1_shop_floor_foundation.sql`) commences.** Last-responsible-moment posture confirmed by Jacques 2026-04-29.

Eight architectural decisions:

1. Per-table retention class (push back on 20-yr for `Audit.OperationLog` / `InterfaceLog` / `FailureLog`).
2. Monthly partitioning + sliding-window automation across ~14 high-volume event tables **plus the two runtime-EAV children** `Workorder.ProductionEventValue` + `Quality.QualityResult` (partition-aligned with their parents; folded in 2026-06-08 EAV-at-scale review). **Must be in CREATE migration.**
3. Columnstore on aged partitions (>90 days).
4. Materialized closure table for `Lots.LotGenealogy` — Honda audit O(1) vs recursive CTE at year 15. **Must be in CREATE migration.**
5. Materialize `TotalInProcess` / `InventoryAvailable` columns onto `Lots.Lot` (supersedes OI-23 view choice at scale). **Must be in CREATE migration.**
6. `Lots.IdentifierSequence_Next` locking model — row-locked vs SQL Server `SEQUENCE`.
7. Split `Audit.OperationLog` into 7-yr general + 20-yr `Lots.LotEventLog`. **Must be in CREATE migration.**
8. Filtered indexes on hot subsets.

Items 2/4/5/7 must be in the CREATE migration — retrofitting partition schemes, closure tables, or materialization columns to populated 100M+ row tables is operationally expensive.

**Resolution path:** internal Blue Ridge architecture review + MPP IT retention-policy negotiation (single meeting). Output: data model § "Scaling Decisions" + FDS-11 retention paragraph + Phase 1 migration content.

**Background:** `Meeting_Notes/2026-04-28_DataModel_Indexing_Scaling_Review.md`.

### Phase 0 Customer Validation Workshop with MPP — Track A (8 items)

Track A is the customer-validation gate. Track B is the architecture workshop above (OI-35). OI-31 closed 2026-05-01 (cutover seed at +10K above Flexware counter — captured in FDS-16-003) — only the rollout-shape sub-question remains as a Ben item, no longer Phase-0-gating.

1. **FDS-06-030** — WorkOrder BIT-flag enumeration.
2. **Historical data migration** — entity list + pre-flight validation + discrepancy review.
3. **ShotCount semantics** — cumulative counter (current default) vs derived from aggregated LOT quantity.
4. **Workstation `DefaultScreen` + `ConfirmationMethod` seeding** — per-Cell Perspective-view list + per-Cell `ConfirmationMethod` value (Vision / Barcode / Both).
5. **Honda AIM Hold/Update contract detail** — `PlaceOnHold` / `ReleaseFromHold` / `UpdateAim` signatures + error recovery (UJ-04 GetNextNumber pool flow already locked).
6. **Label template scope** — Flexware has 3 templates (CONTAINER / LOT / CONTAINER_HOLD); confirm matches + any new (Sort Cage / Hold / Void). Couples to S-09 in Seeding Registry.
7. **OI-32 Material Allocation operator screen** — premise challenged 2026-04-24; revised "close as not-reproduced" framing awaits Ben's explicit confirmation.
8. **OI-33 AIM pool empty-pool hard-fail customer validation** — confirm hard-fail is the desired posture (production stops on affected lines until pool refills; no soft-fallback).

---

## Outstanding for Next Session

### Open Part B UJs

- **UJ-05** Sort Cage serial migration — default direction committed (update-in-place + `Lots.ContainerSerialHistory`); awaits MPP Quality + Honda compliance affirmation.
- **UJ-19** Productivity DB replacement — Ben + MPP Production Control name the four PD reports; **MVP scope confirmed** per OI-30 closure (the four reports are deliverables; reports beyond the four = post-deployment change order).

### Open Part A items (4)

- **OI-32** Material Allocation operator screen — Ben's confirmation of "close as not-reproduced" framing.
- **OI-33** AIM pool empty-pool hard-fail — MPP Operations / IT customer validation.
- **OI-34** Production schedule leverage — MPP Production Control discovery walk-through.
- **OI-35** Long-horizon scaling, retention, archiving — Blue Ridge architecture review + MPP IT retention negotiation. **HARD GATE** before Arc 2 Phase 1 SQL build.

### SQL queue — Blue Ridge owns (gated on Phase 0)

1. ✅ **OI-07 + OI-12 correction migrations** — landed 2026-04-28 as `0013_oi07_oi12_corrections.sql`. 858/858 tests passing.
2. ✅ **LocationTypeDefinition CRUD support** — landed 2026-05-13 as `0014_locationattributedefinition_unique_active_name.sql` (filtered UNIQUE index) plus `R__Location_LocationTypeDefinition_SaveAll.sql` (bundled meta + child reconciliation in one transaction) and `R__Location_LocationTypeDefinition_Deprecate.sql` (cascade + FK guard against active Locations). 907/907 tests passing.
3. **Arc 2 Phase 1 SQL implementation** — needs renumber to **`0015_arc2_phase1_shop_floor_foundation.sql`** (0014 was taken by item 2). **GATED on Phase 0 — both tracks (Customer Validation + Architecture Decision)** before commencement. Phase 1 plan body bakes OI-35 architectural decisions into the migration on day one (partition functions, closure table if elected, materialization columns if elected, OperationLog split if elected, filtered indexes per B8). Includes the Phase 4 Data Model column add `Parts.OperationTemplate.RequiresSubLotSplit` if not landed earlier as its own migration.
4. **Phases 2–8 SQL** — sequential per the rebuilt plan (migrations `0016`–`0022`, shifted by one from the original reservation). Phase 4 migration `0018` includes the `RequiresSubLotSplit` ALTER if not already shipped.

### ERD refresh queue

ERD pending refresh for v1.9j–m additions:

- `ContainerConfig.ClosureMethod` values (`ByCount` / `ByWeight` / `ByVision`)
- `Lots.ShippingLabel.BannerAcknowledgedAt`
- `CoupledDownstreamCellLocationId` LocationAttribute under `CNCMachine`
- `Parts.OperationTemplate.RequiresSubLotSplit`

Per-schema tabs are the source of truth and remain canonical until next regen.

### Internal Docs Portal — ✅ landed 2026-05-12

Initial v1 build at `docs_portal/`. See "Recent Change Narrative" entry below for details.

### LocationTypeEditor modal — ✅ closed 2026-05-15

Full vertical stack landed 2026-05-13, convention-rectification pass 2026-05-14, all 8 smoke flows pass 2026-05-15 (commits `f469061` + `7ab9cd3`). Audit verified via `Audit.ConfigLog` rows. Marker removed from this section; historical detail in the "Recent Change Narrative" entries below.

### Non-blocking polish

- Memory file revision-history-format trim: applied to FDS only; not yet to Data Model + OIR.
- FDS-06-028 wording sharpen — WO Auto-Finish (§6.10) prose still mentions "camera-count mode" pre-tray-reframe. Low priority.
- ~~**Latent NQ v1 schema bug:** at least `location/Get/resource.json` is `version: 1`~~ — resolved 2026-05-14 (bumped to v2 with corrected sqlType enum). See `feedback_ignition_nq_resource_schema.md` memory for the empirically-verified Designer sqlType table.
- **Audit Log UI revisit** (Jacques, 2026-05-27) — current FailureLog + AuditLog browser pages work for Phase 3 verification but the UI itself wants another design pass at some point. Not blocking anything; revisit when there's a natural opening between feature work.

### Deferred follow-ups tied to future Config Tool surfaces

- **DieCastMachine Cell — read-only mounted-Tool status panel** (Plant Hierarchy editor). When the Tools master Config Tool surface is built, add a read-only section under (or alongside) Attributes on DieCastMachine Cell details showing the currently mounted Tool, mount timestamp, and mounting supervisor, sourced from `Tools.ToolAssignment_ListActiveByCell(@CellLocationId)`. Mutation (mount/release) stays on the plant-floor scan-in screen per FDS-05-034 + the `tool-assignment-modal` mockup design — the Plant Hierarchy panel is visibility-only so engineering can see what's mounted without going to the floor or asking. Deferred until the Tool master Config Tool screen exists (it would have no cross-link target today). Discussion: 2026-05-18 session.

- **Downtime / OEE dashboard (not started, 2026-07-21)** — supervisor dashboard: open downtime by cell/line, downtime Pareto by reason code + reason type over a shift/day/date-range, and Availability % once a shift-availability rollup exists (downtime minutes vs shift minutes per `Oee.Shift` — no proc computes A/P/Q today). The downtime subsystem already captures all inputs; only the rollup/dashboard surface is missing. See `notes/2026-07-21_downtime-dashboard-need.md`. Raised while shipping the Shift Schedules config screen (`/shifts`), which is now built (NQ + view + route over the pre-existing `Oee.ShiftSchedule_*` procs; the sidebar nav item was a dead link before).

### 🟠 Open at session end (2026-05-19)

### Item Master Phase 1 view shell landed (2026-05-19)

The Item Master Configuration Tool page (`/items`) is built as a Phase 1 visual shell — 7 new view files plus a page-config registration. Layout fully mirrors the mockup at `mockup/index.html` §"SCREEN: Item Master" (lines 308–860) and `+Add Item` modal (lines 2629–2715). All `view.custom.editDraft.*` form bindings active; dirty indicator works; tab switching works; toast placeholders for Save/Deprecate/Create/New Version all fire correctly.

**What's wired:** Page route, sidebar nav (already in place), ItemMaster shell, ItemRow flex-repeater + page-scoped click messaging, DetailsHeader form (9 inputs bidi-bound to editDraft.meta), TabStrip with 5-tab switching, 5 embedded tab views (ContainerConfig editable; Routes/BOMs/QualitySpecs/Eligibility read-only with placeholder New Version buttons), AddItem modal opened from +Add Item button.

**What's NOT wired (deliberately Phase 2+ per `docs/superpowers/specs/2026-05-19-item-master-view-shell-design.md`):**
- Item list / item details DB read paths (Phase 2)
- Item Save / Deprecate / Add Item Create flows (Phase 3)
- Container Config save (Phase 4)
- Routes versioning workflow — own design + plan (Phase 5)
- BOMs versioning workflow — own design + plan (Phase 6)
- Quality Specs cross-navigation (Phase 7)
- Eligibility editor (Phase 8)

**Pickup notes for next session:** Designer-side smoke test of the page (5G0 dummy data renders, item rows click, fields edit + dirty indicator flips through embedded boundary, all 5 tabs visible). The bidi-on-Object-param mechanism for Embedded View `props.params.value` is the architectural risk — if it doesn't round-trip when smoke tested, fall back per R1 in the design doc.

### 🟠 Audit-pages customMethods addressing bug (2026-05-19 — fixed same day, note retained)

The `view.custom.editDraft` / `view.custom.selected` dirty-check binding in the audit views surfaced a `customMethods` scope issue: `root.scripts.customMethods` attaches methods to the ROOT COMPONENT, not to the view. Addressing inside a view-level onChange script must use `self.rootContainer.X()` (not `self.X()` or `self.view.X()`). Fixed in the same session; see `feedback_ignition_view_customMethods_scope.md` memory for the full pattern. Relevant for any future view that calls `customMethods` from within embedded-view or event-handler context.

---

## OIR Status (v2.17, 2026-05-01)

54 items total: **47 resolved, 0 in review, 6 open, 1 superseded.**

- **Open Part A:** OI-32 (Material Allocation framing — Ben), OI-33 (AIM pool hard-fail — MPP Ops / IT), OI-34 (production schedule leverage — Production Control), OI-35 (scaling / retention — Blue Ridge architecture + MPP IT) **HARD GATE**
- **Open Part B:** UJ-05 (Sort Cage serial migration — MPP Quality + Honda), UJ-19 (PD replacement — Ben + Production Control name the four reports)

---

## Decision Owners

Items genuinely gating downstream work, by owner:

1. **OI-35 Architecture Decision Workshop** — Blue Ridge architecture lead + MPP IT (retention-policy negotiation). Gates Arc 2 Phase 1 SQL build.
2. **Phase 0 Customer Validation Workshop with MPP** — 9 gating items above. Gates Arc 2 Phase 1 SQL build.
3. **Ben** — OI-32 close-as-not-reproduced confirmation; OI-31 rollout-shape decision is no longer gating (OI-31 closed 2026-05-01 with the +10K seed-offset rule; rollout shape is operationally informational only). Memo at `Meeting_Notes/2026-04-24_OI-31_Single-Line_Deployment_Impact.md`.
4. **Tom (security SME)** — final elevated-action list validation (FDS-04-007).

---

## Build Status

- **Configuration Tool (Arc 1):** Phases 1–8 + G.1–G.5 + 0013 corrections + 0014 LocationTypeDefinition CRUD support complete. Audit page procs (FailureLog_List, ConfigLog_List, FailureLog_DistinctProcedures) landed 2026-05-19. Phase 5 Routes versioning + Phase 6 BOMs versioning landed 2026-05-26. **1034/1034 tests passing** across 24+ test suites.
- **SQL artifacts:** `/sql/` folder, **16 versioned migrations** (latest: `0015_audit_add_event_type_deleted` + `0016_parts_bom_unique_draft`) **+ 230+ repeatable procs.** PowerShell reset script `Reset-DevDatabase.ps1` auto-discovers and runs all scripts via `sqlcmd.exe`. Tested on SQL Server 2025.
- **Plant Floor (Arc 2):** Mockup landed at `mockup/plantFloor.html` (12 terminal/lot routes + Home Page). SQL not yet started — gated on Phase 0.
- **Ignition project (live build, Arc 1):** Phase 1 Location pipeline + toasts + scan helper landed 2026-05-12. LocationTypeEditor full stack 2026-05-13. **Convention rectification 2026-05-14** — `Common.Db`/`Common.Util`/`Common.Ui` layer built, `Common.Action` deleted, 5 entity scripts retrofitted through Common helpers, LocationTypeEditor view restructured to `editDraft`/`selected` pattern + dirty indicator + Cancel, all NQs normalized (camelCase identifiers, Designer-canonical sqlType enum, v2 schema). Designer smoke-test pending. Audit pages (FailureLog + AuditLog) landed 2026-05-19 with the customMethods addressing bug fixed same day. **Downtime Codes Ops view wired 2026-05-19** — first Config Tool admin surface to combine live-data List + popup editor + page-scoped refresh pulse (separate pattern from the audit-browser read-only pattern).
- **Seed data loading:** CSVs ready in `reference/seed_data/` (876 rows total). `machines.csv` not yet loaded; MPP parts list not yet provided; `defect_codes.csv` not yet loaded; `downtime_reason_codes.csv` has bulk-load proc but not yet invoked.

---

## Source-of-Truth Doc Locations

| Doc | Markdown source | Word output |
|---|---|---|
| Data Model | `MPP_MES_DATA_MODEL.md` | `MPP_MES_DATA_MODEL.docx` |
| FDS | `MPP_MES_FDS.md` | `MPP_MES_FDS.docx` |
| FDS Changelog | `MPP_MES_FDS_CHANGELOG.md` | `MPP_MES_FDS_CHANGELOG.docx` |
| OIR | `MPP_MES_Open_Issues_Register.md` | `MPP_MES_Open_Issues_Register.docx` |
| User Journeys | `MPP_MES_USER_JOURNEYS.md` | `MPP_MES_USER_JOURNEYS.docx` |
| Phased Plan Plant Floor | `MPP_MES_PHASED_PLAN_PLANT_FLOOR.md` | `MPP_MES_PHASED_PLAN_PLANT_FLOOR.docx` |
| Seeding Registry | `MPP_MES_SEEDING_REGISTRY.md` | `MPP_MES_SEEDING_REGISTRY.docx` |
| ERD | `MPP_MES_ERD.html` — **generated by SchemaGen from `MPP_MES_Dev`, not a markdown source.** Regenerate: `python generate_erd.py --config mpp.json` in `../SchemaGen`, then copy `mpp-data-model.html` over it. | — |

Arc 2 revisions spec: `docs/superpowers/specs/2026-04-23-arc2-model-revisions.md` (still untracked in working tree).

Indexing review (carries OI-35 Decision Gate callout): `Meeting_Notes/2026-04-28_DataModel_Indexing_Scaling_Review.md`.

Phase G capability snapshot: `Meeting_Notes/2026-04-22_Phase_G_Capabilities_Summary.md`.

---

## Recent Change Narrative

A timeline of session-by-session changes. Most recent first.

### 2026-06-05 — SQL/Ignition hardening session (parallel to the Tools work)

A separate workstream from the Tools Config Tool session above. Five things landed, all committed on `jacques/working`, SQL suite green **1165/1165** throughout.

- **Re-enabled the 13 legacy-seed-coupled SQL tests** (`2f27b04`). They had been deactivated when the legacy `010` location sample was dropped for the real MPP plant seed (`011`). Refactored with the **hybrid** strategy: mutation/CRUD tests resolve area/cell anchors dynamically per `GO`-batch (`SELECT TOP 1 ... WHERE LocationTypeDefinitionId = N` / `OFFSET` for distinct ones) instead of hardcoded Ids/Codes; pure seed-read tests derive expected counts via direct `COUNT`. `MPP-MAD` reused for the Tools non-Cell rejection case. `_disabled/` folders removed. Memory `project_mpp_location_seed_and_disabled_tests` updated to RESOLVED.
- **Ignition entity-script code review** across all 29 `BlueRidge.*` modules, fixes applied in three buckets (`2c909ac`): correctness (RouteTemplate `json.dumps`→`convertWrapperObjectToJson`, Eligibility itemId unwrap, QualitySpec `listVersions` filter, Tree default icon, Notify TTL, Db `is not None` guard, dead import, DieRank dict-index + null guards); a wrapper-safe JSON-encode sweep (6 sites → `convertWrapperObjectToJson`); convention enforcement (RouteTemplate `appUserId`-from-session, Tool DataType allowlist → proc, QualitySpec draft-check dedup + label consolidation). Deferred by design: #3 DowntimeReasonType dropdown, #9 `eligibleTypes`, #11 `"Route v1"` default.
- **Demo item 5G0 fully configured** (`829698e`) — extended `020_seed_items.sql` so item 1 (5G0) populates every Item Master tab: 14 `OperationTemplateField` rows, 7 `QualitySpecAttribute` rows (Dimensional Numeric + Visual Text/Boolean), 4 `ItemLocation` eligibility rows (DieCastMachine cells, one consumption point). Idempotent, ASCII-only, locations by Code.
- **Committed the `0018` tooltype-compat SQL** (`9d10ae3`) and fixed an unrelated INSERT-EXEC drift it caused in `0013_Tools_Types/010_Types_read` (temp tables widened for the new `CompatibleLocationTypeDefinitionId` column).
- **Routes-tab StateBadge custom-prop fix** (`7e79563`) — `view.custom.selectedHeader` (and `versions`, etc.) were referenced by bindings but existed only in `propConfig` with no default, and the `getHeader` binding returned `None` for an unselected version, so nested reads errored. Declared all bound props in the `custom` block with shaped defaults and added `RouteTemplate.getHeaderOrEmpty` → `_EMPTY_HEADER` so the binding source is never `None`. Codified the rule in CLAUDE.md, `ignition-context-pack/02_perspective_views.md`, and memory `feedback_ignition_predeclare_bound_custom_props`.

### 2026-05-20 — Item Master Phase 2: read paths + R1 smoke test bed

Phase 2 of the 8-phase Item Master Configuration Tool. Three new Named Queries (`parts/Item_List`, `parts/Item_Get`, `parts/ContainerConfig_GetByItem`) wrap existing stored procs. Two new entity scripts (`BlueRidge.Parts.Item`, `BlueRidge.Parts.ContainerConfig`) route through `Common.Db`. The parent `ItemMaster/view.json` now binds `view.custom.items` to a `runScript(BlueRidge.Parts.Item.getAllForList, ...)` expression and its `itemRowClicked` handler calls the live entity scripts to populate `view.custom.editDraft.meta` + `view.custom.editDraft.containerConfig` from the DB. The other four tab slices (routes/boms/qualitySpecs/eligibility) are left empty until their own phases land.

**No SQL changes.** Tests stay at 937/937 (existing `Parts.Item_List`, `Parts.Item_Get`, `Parts.ContainerConfig_GetByItem` reused as-is).

**Spec:** `docs/superpowers/specs/2026-05-20-item-master-phase2-design.md`
**Plan:** `docs/superpowers/plans/2026-05-20-item-master-phase2.md`

**Files touched (8 created + 2 modified):**
- 3 new NQ folders under `ignition/projects/MPP_Config/ignition/named-query/parts/`
- 2 new entity script modules under `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/`
- 1 view edit + resource.json metadata bump on `BlueRidge/Views/Parts/ItemMaster/`

**R1 smoke verification — PENDING.** Designer smoke checklist in spec §9. R1 holding is the precondition for Phase 3-8 building on the bidi-embed pattern. If smoke fails, the page-scoped message fallback documented in spec §2 governs the rebuild.

**Worktree:** built in `.claude/worktrees/Agent-B-item-master-phase2` on branch `worktree-Agent-B-item-master-phase2`. Ready to merge to main once R1 smoke verifies green.

**Next pickup:** Jacques walks the R1 smoke checklist in Designer. On pass → Phase 3 (Item Save / Deprecate / Add Item Create) brainstorming, including cleanup of the `PartsPerBasket` Identity field that doesn't map to a real `Parts.Item` column. On fail → fallback design cycle (page-scoped messages instead of bidi-embed).

### 2026-05-19 — Item Master Phase 1 view shell

Phase 1 of an 8-phase Item Master Configuration Tool build (per `docs/superpowers/specs/2026-05-19-item-master-view-shell-design.md` + `docs/superpowers/plans/2026-05-19-item-master-view-shell.md`).

**Files landed (8 new view files + 1 config edit):**
- `page-config/config.json` — added `/items` route entry
- `views/BlueRidge/Views/Parts/ItemMaster/{resource.json, view.json}` — page shell
- `views/BlueRidge/Components/Parts/ItemMaster/ItemRow/{resource.json, view.json}` — flex-repeater row sub-view
- `views/BlueRidge/Components/Parts/ItemMaster/ContainerConfig/{resource.json, view.json}` — tab 1 (editable form)
- `views/BlueRidge/Components/Parts/ItemMaster/Routes/{resource.json, view.json}` — tab 2 (published-only table)
- `views/BlueRidge/Components/Parts/ItemMaster/Boms/{resource.json, view.json}` — tab 3 (published-only table)
- `views/BlueRidge/Components/Parts/ItemMaster/QualitySpecs/{resource.json, view.json}` — tab 4 (read-only linked list)
- `views/BlueRidge/Components/Parts/ItemMaster/Eligibility/{resource.json, view.json}` — tab 5 (Area dropdown + machine table)
- `views/BlueRidge/Components/Popups/AddItem/{resource.json, view.json}` — +Add Item modal shell

**Architecture:**
- Parent ItemMaster holds all state on `view.custom` (items, selected, editDraft, itemTypes, uoms, activeTab, mode, search, typeFilter)
- 5 always-mounted Embedded Views in TabPanels, gated by `position.display = "{view.custom.activeTab} = '<key>'"`
- Each embedded tab's `props.params.value` bidirectionally bound to `view.custom.editDraft.<slice>` — child form-field writes propagate back up through the embed boundary (R1 in the design doc — first use of this pattern in the project, needs Designer smoke validation)
- ItemRow flex-repeater fires page-scoped `itemRowClicked` message handled by `root.scripts.messageHandlers[0]` on the parent
- Save / Deprecate / Create Item / New Version buttons all fire `BlueRidge.Common.Notify.toast(...)` placeholders for Phases 3/5/6

**Roadmap forward:** Phase 2 wires read paths; Phase 3 wires Item mutations + Add Item Create; Phase 4 Container Config save; Phases 5/6 are substantial Routes/BOMs versioned-entity workflows that warrant their own design docs. Phases 7/8 are Quality Specs cross-link and Eligibility editor.

### 2026-05-19 — Downtime Codes Ops view wired end-to-end (first Config Tool admin surface)

Plan + spec committed first (`docs/superpowers/specs/2026-05-19-downtime-codes-wiring-design.md` + `docs/superpowers/plans/2026-05-19-downtime-codes-wiring.md`), then executed via subagent-driven development across 9 tasks. Scaffolded `Views/Oee/DowntimeCodes` was sample-data only; this session turned it into a fully interactive admin surface.

**Backend layer** — 6 new NQs under `named-query/oee/` (`DowntimeReasonCode_List` / `_Get` / `_Create` / `_Update` / `_Deprecate` plus `DowntimeReasonType_List` with 30-min cache). Two new entity-script modules: `BlueRidge.Oee.DowntimeReasonType` (`getAll`, `getForDropdown(includeUnassigned, includeAll)`) and `BlueRidge.Oee.DowntimeReasonCode` (full CRUD: `search/getOne/add/update/deprecate/emptyMeta`, with client-side `searchText` filter since the proc has no `@SearchText`). Added `BlueRidge.Location.Location.getAllAreas(includeAll)` as a peer read helper that filters the existing `location/GetTree` flat result for `HierarchyLevel == 2`.

**Spec-review catch** — Initial plan asserted Areas were `HierarchyLevel == 3` (ISA-95 ordinal counting). The project's seed (migration 0002 line 110) places Areas at `HierarchyLevel == 2` (zero-indexed: Enterprise=0, Site=1, **Area=2**, WorkCenter=3, Cell=4). Spec reviewer caught the defect before code shipped to a view; plan + spec corrected, code patched. Seeded Areas are DC/MS/QC/TS (4, not 3 -- QC included but downtime typically only uses the first 3).

**New popup view** — `BlueRidge/Components/Popups/DowntimeCodeEditor`: single popup for both Add and Edit via `view.params.mode = "create"|"update"` discriminator, with `editDraft/selected` state, dirty indicator, and `ConfirmUnsaved` wiring on both header X and footer Cancel. Code field is readonly in update mode (immutable post-create per the proc). Deprecate button visible only in update mode. Refresh pulse on Save/Deprecate via page-scoped `downtimeCodesRefresh` message.

**Wired existing views** — `BlueRidge/Components/DowntimeCodeRow` got an `id` input param and Edit button onClick → openPopup. `BlueRidge/Views/Oee/DowntimeCodes` got: filter keys renamed (`area` → `areaLocationId`, `reasonType` → `downtimeReasonTypeId`) to match proc params, hardcoded sample arrays replaced with `runScript` bindings, `+ Add Code` button wired to openPopup, repeater binding restructured with script transform mapping proc PascalCase → row-component lowercase keys, and `downtimeCodesRefresh` message handler at root that shallow-copies `view.custom.filter` to force re-eval of the rows binding.

**Bugs caught during smoke testing** —
- `scope: "C"` on `component.onActionPerformed` doesn't fire reliably; project standard is `scope: "G"` (matches PlantHierarchy + AuditLog precedent). Fixed both AddCodeButton and DowntimeCodeRow EditButton.
- `IncludeDeprecated` checkbox originally wrapped in a flex+label workaround; Jacques reverted to single-component `ia.input.checkbox.props.text` — works fine in normal-width containers. New memory entry `feedback_ignition_checkbox_text_prop_ok.md` corrects my earlier overcaution.
- Edit button on deprecated rows hidden via `meta.visible` (not `position.display`) to preserve column alignment across the tabular layout. New memory entry `feedback_ignition_meta_visible_in_tables.md` notes table rows are the legitimate exception to the "use position.display" convention.

**Visual polish** — Deprecated rows in the list rendered at 55% opacity (root `style.opacity` binding), Edit button hidden via `meta.visible: false`. Greyed visual + no Edit affordance for deprecated rows; toggle "Include deprecated" to surface them.

**Bulk-load explicitly deferred** — `Oee.DowntimeReasonCode_BulkLoadFromSeed` proc exists and is tested. One-shot cutover operation; will run from Designer Script Console with the 353-row seed JSON when MPP confirms the DC/MS/TS → AreaLocationId mapping. No UI button needed.

**SQL untouched** — no migrations or repeatable procs added. Test suite remains at 937/937.

**Generalizes** — this is the reference pattern for any future Config Tool admin surface where a single entity has full CRUD (no compound children — that pattern stays the `SaveAll` bundled-proc reference impl): List-Detail view with live runScript-bound rows, popup editor with mode discriminator + ConfirmUnsaved, page-scoped refresh pulse. Distinct from the audit-browser pattern (read-only with TOP cap + COUNT(*) OVER total).

**Parallel work landed same day** — audit-pages addressing bug (customMethods scope) fixed; `BlueRidge.Location.Location.listByTier(tierCode)` + `location/Location_ListByTier` NQ added as prep for the upcoming Defect Codes Config Tool screen.

### 2026-05-19 — Audit pages landed (FailureLog + AuditLog Config Tool browsers)

Design and plan committed first (`docs/superpowers/specs/2026-05-19-audit-pages-design.md` + `docs/superpowers/plans/2026-05-19-audit-pages.md`), then executed via 13 commits using the subagent-driven development pattern. Full SQL reset + test run closes the session at **937/937 tests passing**.

**SQL** — `Audit.FailureLog_List` and `Audit.ConfigLog_List` both received `TOP 1000` caps and `COUNT(*) OVER() AS TotalCount` window-aggregate columns, which drive the "Showing N of M — narrow your filter" banner on both pages. FailureLog_List gained `@FailureReasonLike` substring filter and `@LogEntityTypeId` filter; ConfigLog_List gained `@DescriptionLike` and `@SeverityId`. New `Audit.FailureLog_DistinctProcedures` proc powers the Procedure dropdown on the FailureLog page — returns every distinct `ProcedureName` that has ever logged a failure. Test extensions landed alongside each proc. Note on canonical column names: `Audit.ConfigLog` uses `LoggedAt`/`UserId` (not `ChangedAt`/`AppUserId`); the proc passes those through unchanged and downstream Ignition consumers use `loggedAt` / `userDisplayName` accordingly. 220 repeatable procs total.

**Ignition NQs** — 9 new named queries under `named-query/audit/`: `FailureLog_List`, `FailureLog_GetByEntity`, `FailureLog_GetTopReasons`, `FailureLog_GetTopProcs`, `FailureLog_DistinctProcedures`, `ConfigLog_List`, `ConfigLog_GetByEntity`, `LogEntityType_List`, `LogSeverity_List`.

**Entity scripts** — 4 new modules: `BlueRidge.Audit.LogEntityType` (`getAll`), `BlueRidge.Audit.LogSeverity` (`getAll`), `BlueRidge.Audit.FailureLog` (3-NQ-bundled `search()` returning `{rows, totalCount, topReasons, topProcs}`), `BlueRidge.Audit.ConfigLog` (1-NQ `search()` returning `{rows, totalCount}`). Both `search()` functions deep-unwrap their filter dict via `Common.Util._u()` at entry to defend against tile-click / bidirectional-binding QualifiedValue wrappers. `Common.Util.prettyJson` helper added — formats AttemptedParameters / Old / New JSON for the detail popups (try/except wrapper; falls back to raw text on parse failure).

**New views** — three new components written as files (new-view path; no Designer cache conflict): `BlueRidge/Components/Popups/FailureDetail` (single AttemptedParameters JSON block), `BlueRidge/Components/Popups/ConfigChangeDetail` (side-by-side Old + New diff blocks), `BlueRidge/Components/Audit/TopRow` (reusable tile-row sub-view shared between Top Reasons + Top Procs panels; fires page-scoped `applyFilterFromTile` message on tile click). FailureLog and AuditLog views fully wired: default date range = last 7 days, no auto-apply on load, explicit Apply + Reset buttons, TOP 1000 cap with banner. Tile-row click sets the appropriate filter field and triggers apply. FailureLog filter set: Date / EntityType / Procedure / AppUser / Search text. AuditLog filter set: Date / EntityType / Severity / Search text.

**Deviation noted** — AuditLog lost its AppUser dropdown during the wire pass; the original mockup's `UserDropdown` slot was repurposed to `SeverityDropdown`. The design called for AppUser filter on both pages. Tracked as a follow-up polish item; not blocking any other work.

**Proc return shapes documented** — TopReasons / TopProcs procs return `FailureCount` (not `Count`). The view's flex-repeater transform accounts for this.

**Session also included** (earlier commits, not audit-pages scope): FDS v1.2 (`ParentLocationId` immutability rule, `5bd3d80`) and plant hierarchy view work (`d0d5355`).

### 2026-05-15 — LocationTypeEditor smoke test + close-confirmation dialog

Two commits landed:
- `f469061` fix(loc-type-editor): dirty indicator + attribute-table alignment
- `7ab9cd3` feat(loc-type-editor): close-confirmation dialog for unsaved work

**Smoke test — all 8 flows pass.** Tier select, definition pick, edit + dirty indicator, Cancel revert, Save commit (audit verified — `Audit.ConfigLog` rows 251/252 with full pre/post payloads), Add Definition, Add/Remove Attribute, Deprecate (FK guard rejects active-Location references with graceful toast).

**Fixes landed:**

- Attribute row text-field events moved from `events.component.onActionPerformed` (no-op — text-fields don't have Component Events at all) to `events.dom.onBlur` for AttributeName / DefaultValue / Uom / Description. Dirty indicator now fires when user tabs out of any attribute field.
- AttrTableHeader column basis / grow aligned with AttributeDefinitionRow. ColArrows + ColRemove converted from `ia.display.label` to `ia.container.flex` (empty labels were collapsing despite `basis`).
- Pulled `min-width: 180px` from `.psc-search-input` — class was overloaded as a generic input look across 24 sites, and the 180px floor was overriding flex sizing in every attribute-row cell.

**New view:**

- `BlueRidge/Components/Popups/ConfirmUnsaved` — parameterised 3-button popup (Save & Close / Discard & Close / Cancel). LocationTypeEditor's CloseIcon + footer CloseButton now dirty-check before closing; if dirty, open this popup; user's choice routes back via page-scoped `confirmUnsavedResult` message handler. Reusable across future editors — see `project_mpp_confirm_unsaved_pattern.md` memory.

**Workflow learning — file-edit boundary established.** view.json edits to existing views are unreliable due to (a) Designer's GSON serialization of `=` / `'` / `<` / `>` as 6-char unicode escapes (`=` etc.) that fight tool JSON-parsing, and (b) Designer's in-memory cache conflicts. The Designer "Files vs Gateway" conflict dialog also has confusing semantics — picking "Gateway" pushed Designer's cached state to disk and overwrote our file edits.

Established split going forward (also added to CLAUDE.md):

| File type | Edit path |
|---|---|
| view.json (existing views) | Designer — Claude writes Designer-step instructions |
| view.json (new views) | File + scan — no Designer cache to conflict with |
| stylesheet.css | File |
| Python script modules | File |
| NQ `query.sql` / `resource.json` | File |
| SQL migrations / procs | File |

**Cosmetic items still open** (next session):

- TypeBadge `nameForTier` runScript returns NULL — needs gateway-log traceback to diagnose
- Description input renders literal "null" when DB value is NULL — coalesce missing on read path
- `â€` garble on em-dash placeholders — UTF-8 / Latin-1 mismatch somewhere in render pipeline

**Memory added/updated:**

- NEW `feedback_ignition_designer_unicode_escapes.md` — Designer 8.3 GSON escape style for `=` / `'` / `<` / `>` and how to match it when file-editing view.json scripts.
- NEW `project_mpp_confirm_unsaved_pattern.md` — reusable ConfirmUnsaved popup pattern for editors with `editDraft` / `selected` state.
- UPDATED `feedback_ignition_view_edit_boundary.md` — conflict-resolution dialog learning ("Gateway" overwrites disk with Designer's cache, not the inverse).

**Context pack additions:**

- `02_perspective_views.md` — note on Designer's GSON unicode-escape serialization
- `07_conventions_and_antipatterns.md` — close-confirmation popup pattern + text-field-events caveat (no Component Events; use `dom.onBlur`)

### 2026-05-14 — Convention rectification per Hunter's pack updates

Hunter merged in pack updates (`hunter/explore` → `main` fast-forward, commits `784a981` / `591da53` / `cf0fb42` / `fc534bf`) that source the `ignition-context-pack/` from `MPP_MES_CONFIG_TOOL_FRONTEND_CONVENTIONS.md` v1.2 and document the `SaveAll` bundled pattern. Our 2026-05-12/13 Ignition work was built against the older pack and deviated in several places. Today's session rectified the deviations as a coordinated four-phase pass.

Decision sheet: `Meeting_Notes/2026-05-14_Convention_Rectification_Review.md` (line-by-line response document with Jacques's per-item decisions).

**Phase 1 — Foundation built (Common helpers):**

- **`BlueRidge.Common.Db`** — `execList` / `execOne` / `execMutation`. Only layer that calls `system.db.runNamedQuery`. Handles BIT Status convention.
- **`BlueRidge.Common.Util`** — `log` (inspect-frame auto-fill of calling module + function), `_currentAppUserId` (reads `session.custom.appUserId` with dev fallback to AppUser.Id 2), `extractQualifiedValues`, `convertWrapperObjectToJson`.
- **`BlueRidge.Common.Ui.notifyResult(result, successTitle, successMsg, errorTitle)`** — routes mutation result to toast.
- **`BlueRidge.Common.Notify.toast`** — `DEFAULT_TTL_SEC` 8 → 5 per C1 decision.
- **`BlueRidge.Common.Action`** deleted (was the parallel-universe `execMutation` that mixed DB + toast).
- **`BlueRidge.Common.Session.getCurrentUserId`** now a thin shim over `Common.Util._currentAppUserId`.

**Phase 2 — Entity scripts retrofitted + NQ casings normalized:**

- 5 entity scripts (`Location.Location`, `Location.Tree`, `Location.LocationType`, `Location.LocationTypeDefinition`, `Location.LocationAttributeDefinition`) rewritten to route every DB call through `Common.Db.*`. All `system.db.*` direct calls eliminated outside `Common.Db`. Per-module logger declarations removed; replaced with direct `Common.Util.log(...)` calls. 5 copies of local `_rowsToDicts` helper deleted.
- Module surface standardized per pack convention: `listByType` → `getAll`, `listByDefinition` → `getAll`, `listAll` → `getAll`, `get` → `getOne`. Custom domain handlers (`handleMoveUp`/`handleMoveDown`/`handleSaveAll`/`handleDeprecate`/factories) kept per Jacques's A4 decision ("standard is starting point, not complete list").
- 9 NQ files normalized: parameter identifiers → camelCase (`LocationID`/`UserID`/`Id`/`AppUserId` → `locationId`/`userId`/`id`/`appUserId`); query.sql `:placeholder` references updated to match.
- `Get/resource.json` bumped v1 → v2 schema (was the latent Designer-NPE bug flagged 2026-05-13).
- `print ds` stripped from `Location.code.py:124` (B1); `Tree.code.py` header rewritten to standard module shape (B2).

**Phase 3 — LocationTypeEditor view restructured to editDraft/selected pattern:**

- `view.custom.meta` + `view.custom.attributesDraft` → `view.custom.selected` (baseline) + `view.custom.editDraft` (in-flight), each carrying `{meta, attributes}`.
- All form bindings repointed to `editDraft.meta.*`; attributes repeater binding to `editDraft.attributes`.
- 4 message handlers (`definitionClick`, `attrDraftUpdate`, `attrDraftRemove`, `attrDraftMove`) rewritten to mutate `editDraft.attributes` and maintain the `selected` baseline on selection changes.
- 5 inline scripts rewritten (Save, Deprecate, +Add Definition, +Add Attribute, TierDropdown onChange) for the new state shape.
- **New:** dirty indicator label bound to `if({view.custom.editDraft} != {view.custom.selected}, "● Unsaved changes", "")` per pack universal rule.
- **New:** Cancel button in DetailsHeader — reverts `editDraft = dict(selected)` in update mode; resets to view mode in create mode; hidden when no pending changes.
- Save handler does proper deep-copy commit on success (`selected = {meta: dict(...), attributes: [dict(a) for a in ...]}`) so the dirty indicator clears.

**Phase 4 — Pack contributions + memory updates (two-way street):**

- **`ignition-context-pack/03_script_python.md`**: `execMutation` updated for BIT Status convention; full SP shape (`DECLARE @Status BIT = 0`) baked in verbatim. `notifyResult` signature updated. **New `Common.Notify` section** documenting popup-per-toast surface (top-right FIFO max 5, errors persist, non-errors auto-dismiss 5s — supersedes the single-banner pattern; toast is now THE standard, no variant). `runNamedQuery` vs `execQuery` clarified.
- **`ignition-context-pack/04_named_queries.md`**: Status-row pattern rewritten with verbatim SP shape. **sqlType section rewritten** with the empirically-verified Designer-canonical enum table (Int1/Int2/Int4/Int8/Float4/Float8/Boolean/String/DateTime/ByteArray = 0/1/2/3/4/5/6/7/8/20) — explicit warning that `java.sql.Types` codes are irrelevant. NQ v2 schema section added.
- **`ignition-context-pack/07_conventions_and_antipatterns.md`**: mutation feedback section updated for toast; **new "Mode discriminator on shared add/edit popups" section** (C4); all `Status='OK'`/`'ERROR'` references updated to BIT 1/0.
- **`ignition-context-pack/02_perspective_views.md`**: **new "Tree mutations — return `{items, selectedPath, selected}`" section** (C2) documenting our re-anchor pattern and the `Tree.props.selection` writeback misfire workaround.
- **`ignition-context-pack/00_README.md`**: file-13 / file-14 descriptions updated.

**sqlType correction (A9 → empirical resolution):**

Initial reading of A9 had me writing `sqlType: 2` for BIGINT (based on observing existing Designer-saved NQs with that code). Jacques provided an empirical reference (Designer-saved NQ with one parameter of every type) that revealed **Designer uses its own internal type enum, NOT `java.sql.Types`**:

| sqlType | Designer name | DB type |
|---|---|---|
| 0 / 1 / 2 / 3 | Int1 / Int2 / Int4 / Int8 | TINYINT / SMALLINT / INTEGER / **BIGINT** |
| 4 / 5 | Float4 / Float8 | REAL / FLOAT |
| 6 | Boolean | BIT |
| 7 | String | **NVARCHAR / VARCHAR** |
| 8 | DateTime | DATETIME |
| 20 | ByteArray | VARBINARY |

Existing Designer-saved NQs in the project had BIGINT params with `sqlType: 2` (Int4) — that was a UI selection mistake by whoever created them; SQL Server's INT → BIGINT silent coercion meant the procs worked anyway. All NQ resource.json files corrected: BIGINT params `2` → `3`, NVARCHAR params `-9` → `7`. Memory entry `feedback_ignition_nq_resource_schema.md` updated with the full Designer enum.

**Memory entries added/updated:**

- UPDATED `feedback_ignition_nq_resource_schema.md` — full Designer sqlType enum table; corrects earlier "sqlType 2 for BIGINT" claim.

**Files touched (42 total):**

- 3 new Common modules (Db, Ui, Util) — 6 files
- 1 deleted module (Action) — 2 files
- 9 NQ folders modified (resource.json + query.sql each)
- 5 entity scripts rewritten
- 1 view (LocationTypeEditor) restructured
- 5 pack files updated
- 1 PROJECT_STATUS.md updated
- 1 memory file updated
- 1 review markdown added to Meeting_Notes/

**Next pickup:** smoke-test the LocationTypeEditor modal in Designer end-to-end (tier select, definition pick, edit fields with dirty indicator, Cancel revert, Save commit, Add Definition flow, Add Attribute flow, Deprecate FK guard).

### 2026-05-13 — LocationTypeEditor modal: full vertical stack scaffolded (WIP)

Big day. Built the complete top-to-bottom stack for the Plant Hierarchy view's cog-button "Location Type Editor" modal: SQL migration + procs + tests, named queries, entity scripts, embedded views, popup view, and the cog-button onClick wiring. **907/907 SQL tests pass.** End-of-day smoke-test in Designer still surfaces issues; modal is NOT FULLY WORKING yet but the full surface area is in place to iterate from.

**SQL (all green, all tests passing):**

- **Migration 0014** — `0014_locationattributedefinition_unique_active_name.sql`. Filtered UNIQUE index on `Location.LocationAttributeDefinition(LocationTypeDefinitionId, AttributeName) WHERE DeprecatedAt IS NULL`. Defends the bundled save proc against active-name collisions; allows reuse of deprecated names. **Note:** this slot was originally reserved for Arc 2 Phase 1's `0014_arc2_phase1_shop_floor_foundation.sql`. That work shifts to `0015` when it lands (SQL queue updated accordingly).
- **`R__Location_LocationTypeDefinition_SaveAll.sql`** — bundled save proc. Meta as params (`@Id`, `@LocationTypeId`, `@Code`, `@Name`, `@Icon`, `@Description`, `@AppUserId`) + `@AttributesJson NVARCHAR(MAX)`. Server-side reconciliation: OPENJSON parse → validate within-batch uniqueness + immutable Code/LocationTypeId on update → DEPRECATE missing children → UPDATE Id-matched (SortOrder = array index) → INSERT NULL-Id rows → one Audit row with full pre/post snapshot → status-row SELECT. See `project_mpp_bundled_save_pattern.md` memory.
- **`R__Location_LocationTypeDefinition_Deprecate.sql`** — soft-delete with cascade to active children. FK guard rejects when active `Location.Location` rows reference. Idempotent re-deprecate returns `Status=1, Message='Already deprecated.'`.
- **Tests:** `030_LocationTypeDefinition_SaveAll.sql` (12 scenarios), `040_LocationTypeDefinition_Deprecate.sql` (6 scenarios). All assertions pass.

**Ignition (scaffolded, end-of-day modal still buggy in Designer):**

- **5 named queries:** `location/LocationType_List`, `LocationTypeDefinition_List`, `LocationAttributeDefinition_ListByDefinition`, `LocationTypeDefinition_SaveAll`, `LocationTypeDefinition_Deprecate`. Resource.json forced to v2 schema after Designer 8.3.5 NPE'd on v1 inheritance from the `Get` NQ template.
- **3 entity script modules:** `BlueRidge.Location.LocationType` (`listAll`, `nameForTier`), `BlueRidge.Location.LocationTypeDefinition` (`listByType`, `handleSaveAll`, `handleDeprecate`, `emptyMeta`, `emptyAttributeRow`, `metaFromDefinition`), `BlueRidge.Location.LocationAttributeDefinition` (`listByDefinition`). All read functions wrap their `system.db.execQuery` calls in try/except with error-toast on failure.
- **`Common.Action.runMutation` upgraded** — now returns the status-row dict (or None) instead of bool. Backwards-compatible (truthy/falsy preserved); `handleSaveAll` reads `result["NewId"]` from the return.
- **3 new views:** `BlueRidge/Components/AttributeDefinitionRow` (editable row sibling of read-only AttributeRow), `BlueRidge/Components/DefinitionItem` (chip/button for tier-scoped definition selection, root = flex with label inside), `BlueRidge/Components/Popups/LocationTypeEditor` (the modal — tier dropdown + definitions repeater + Definition Details panel + Attribute Definitions table + footer Close).
- **PlantHierarchy/view.json** cog icon (`LocationTypeEditorButton`) wired to `dom.onClick` opening the modal via `system.perspective.openPopup(id='mpp-loc-type-editor', view='BlueRidge/Components/Popups/LocationTypeEditor', modal=True, ...)`.

**Bugs hit + fixed during the day** (each = a memory entry now):

1. **Toast popup auto-dismiss never fired** — `view.custom.dismissAt` had no binding, so the polled `now(500) > dismissAt` expression stayed false forever. Fix: add an expression binding on `dismissAt` that computes `dateArithmetic(now(0), {view.params.ttl}, 'second')`. Updated `project_mpp_toast_system.md`.
2. **Tree-selection re-anchor pattern** — when items change programmatically the selection path goes stale. Fixed by having `handleMoveUp`/`handleMoveDown` return `{tree, selectedPath, selected}` so the view writes all three atomically. Same pattern can be reused for any future tree-mutating action.
3. **NQ resource.json schema v1 vs v2** — Designer 8.3.5 NPEs on v1 shape. Bumped all 5 new NQs to v2 with the Designer-saved field order. Pre-existing `location/Get` is still v1 — flagged for cleanup. New memory: `feedback_ignition_nq_resource_schema.md`.
4. **`def list()` shadowed Python builtin** in `BlueRidge.Location.LocationType` — broke `_rowsToDicts`'s `list(...)` call. Renamed to `listAll()`. Genuine junior miss; flagged it as such in the conversation. Update Plant Hierarchy view + binding to call `listAll`.
5. **Message scope: view vs page** — `scope='view'` doesn't propagate from an embedded view to its parent. Chip click from inside `DefinitionItem` with `scope='view'` never reached the popup's `definitionClick` handler. Fix: change to `scope='page'` and flip handler config to `pageScope: true`. Same fix applied to `attrDraftUpdate`/`attrDraftRemove`/`attrDraftMove` from `AttributeDefinitionRow`. New memory: `feedback_ignition_message_scope.md`.
6. **`lookup()` expression function** requires a Dataset, doesn't work against `list[dict]` from `runScript`. TypeBadge expression failed because tiers is a list[dict]. Fix: added `nameForTier(tiers, tierId)` helper in `LocationType` module, called via `runScript`. New memory: `feedback_ignition_lookup_dataset_only.md`.
7. **`DefinitionChip` view was rooted at `ia.input.button`** — non-idiomatic, didn't render text. Rebuilt as `ia.container.flex` root with `ia.display.label` child. Folder renamed `DefinitionChip` → `DefinitionItem`; "chip" terminology replaced with "definition" everywhere (function `chipsFromDefinitions` → `definitionItemsFor`, prop `view.custom.chips` → projection removed entirely, meta names `Chips*` → `Definitions*`, message `defChipClick` → `definitionClick`).
8. **Read-side silent failures upgraded to toasts** — all three list functions (`listAll`, `listByType`, `listByDefinition`) now catch exceptions and fire an error toast before returning `[]`. The `definitionClick` message handler also fires warning toasts on null payload + stale-id-not-in-list paths.

**Memory entries added/updated:**

- NEW: `feedback_ignition_nq_resource_schema.md` — v2 schema required, clone shape from Designer-saved file
- NEW: `feedback_ignition_message_scope.md` — view vs page, use page for embedded→parent
- NEW: `feedback_ignition_lookup_dataset_only.md` — Dataset-aware expr fns don't work on list[dict]
- NEW: `project_mpp_bundled_save_pattern.md` — the SaveAll-with-JSON-deltas pattern as project standard
- UPDATED: `project_mpp_toast_system.md` — dismissAt wiring formula
- UPDATED: `feedback_readonly_type_tables.md` — LocationTypeDefinition now CRUDable (LocationType stays read-only)

**Next session pickup:**

1. Open Designer fresh, pull project, double-click each new NQ to confirm none Designer-NPE
2. Open LocationTypeEditor modal via the cog button on Plant Hierarchy
3. Verify tier dropdown populates, definitions repeater renders DefinitionItems, click flow propagates selection to Definition Details + Attribute Definitions panels, Save round-trips through the bundled proc, Deprecate FK-guards on tiers with active Locations
4. Whatever isn't working at that point — fix and iterate

### 2026-05-12 — Internal Docs Portal landed

Built and shipped the v1 internal docs portal — a self-contained static HTML site at `docs_portal/` that consolidates **FDS + Data Model + OIR + ERD** into one browsable, searchable surface for the Blue Ridge team. Internal-only; does NOT replace the `.docx` deliverables to MPP.

**What's in v1:**

- Four pages: `fds.html`, `data-model.html`, `oir.html`, `erd.html` (the ERD is iframed — no rewrite), plus an `index.html` meta-refresh to FDS.
- Shared shell: sticky header nav, sticky TOC sidebar with `IntersectionObserver`-driven active-section highlight, dark theme matching the ERD palette (`#0f1117` bg / `#6c8aff` accent).
- Cross-doc full-text search via **MiniSearch** — section-level granularity (every h2 + h3), ~277 entries, ~470 KB serialized index, lazy-loaded into a modal triggered by `🔍` button or `/` key.
- Six custom markdown-it plugins:
  1. `heading_permalinks` — adds clickable `#` chips on h2/h3/h4, canonicalizes FDS-XX-NNN and OI-XX/UJ-XX heading ids
  2. `anchor_fds_req` — wraps bold-inline `**FDS-XX-NNN**` references in section anchors
  3. `scope_pill` — backticked scope tags (`MVP`, `CONDITIONAL`, etc.) render as colored badges
  4. `cross_doc_link` — bare `FDS-XX-NNN`, `OI-XX`, `UJ-XX`, `Schema.Table`, `(FRS X.Y.Z)` refs in body text auto-link across docs (only for known schema tables, validated against a pre-parsed allowlist)
  5. `oi_badge` — inline 🔓 OI-XX chip on FDS h4 requirements that an open OI references (8 live badges from the 6 open OIs)
  6. `schema_table_anchor` — Data Model only, gives table h3s schema-prefixed slugs (`parts-operationtemplate`) so cross_doc_link's expected anchors actually resolve

**How to rebuild:** `npm run build:portal` (alias for `node tools/build_docs_portal.js`). Idempotent — wipes and rebuilds `docs_portal/`. Test suite: `npm run test:portal` (38 tests across the generator + plugins + smoke tests).

**Spec + plan:** `docs/superpowers/specs/2026-05-12-docs-portal-design.md` (approved 2026-05-12) and `docs/superpowers/plans/2026-05-12-docs-portal.md` (17 tasks, executed via subagent-driven development).

**Three plan deviations corrected during build:**

1. `buildToc` regex strip left scope-pill text in TOC labels — added a span-strip pre-pass. Same issue with permalink `#` chips — added an anchor-strip pre-pass.
2. The FDS source uses `#### FDS-XX-NNN — Title` h4 headings, not `**FDS-XX-NNN**` bold inline (plan got this inverted). Both `heading_permalinks` and `oi_badge` were extended to recognize the h4 form. 8 live OI badges now appear on FDS.
3. The OIR's `### OI-XX — long description` headings were producing slugified ids that didn't match the bare `oir.html#oi-35` hrefs the cross-doc plugins generate. Added OIR-pattern canonicalization to `heading_permalinks` (mirrors the FDS pattern handling).

Each plan correction landed as a small `fix(portal):` commit so the chain is auditable.

### 2026-05-07 — MPP custom Perspective icon library landed

Built and deployed the `mpp` custom Perspective icon library against the lock spec in `mockup/icons.csv`. 34 unique icon sprites (35 logical icons; `cancel` covers both `close` and `reject` from `icons.csv`) at the locked Material Symbols Outlined / wght 300 / grade -25 / fill 0 / opsz 48 axes. Sprite at `ignition/icons/mpp/mpp.svg` (30 KB), companion `config.json` + `resource.json`, and a README at `ignition/icons/README.md` capturing the deploy + recolor recipe.

Three discoveries forced strategy changes from the original design spec, all captured in the README:

- **Ignition 8.3 moved custom icon libraries** from `data/modules/com.inductiveautomation.perspective/icons/<lib>.svg` (8.1) to `data/config/resources/core/com.inductiveautomation.perspective/icons/<lib>/` (8.3), with mandatory `config.json` + `resource.json` siblings. Folder name must equal library name. Gateway service restart needed — Scan File System is unreliable for modified-sprite reloads.
- **Material Symbols' native viewBox `0 -960 960 960` does not render** in 8.3 Perspective. Path data is remapped to viewBox `0 0 24 24` via `transform="translate(0 24) scale(0.025)"` on each path.
- **`fill="currentColor"` on the path doesn't propagate Perspective's color hook.** Perspective wraps each rendered icon in an outer SVG with `style="fill: currentcolor"`; SVG attribute fill on a child path overrides that cascade. Removing the fill attribute entirely lets the Icon component's top-level `color` prop or a Style Class `Text → Color` drive recolor.

Source for the SVGs: `github.com/google/material-design-icons` (the GitHub repo is the only place Google publishes Material Symbols at every variable-font axis combination including `gradN25`; `fonts.gstatic.com` exposes only `wght` and `fill`).

Spec + plan: `docs/superpowers/specs/2026-05-05-ignition-icon-library-design.md` and `docs/superpowers/plans/2026-05-05-ignition-icon-library.md`. Final-state commit: `8303f72`. Durable mechanics also captured in `CLAUDE.md` § Ignition custom Perspective icon library.

### 2026-05-04 — FDS v1.0 customer-review release

Cut FDS v0.11p → **v1.0**, the first customer-review release. Pre-release working-session history (v0.1 through v0.11p) archived in `MPP_MES_FDS_CHANGELOG.docx`; future revisions tracked in the FDS body itself.

- **Feedback-Welcomed callout** added prominently near the front matter, framing v1.0 as the critical-feedback window. Specific areas highlighted: plant-floor workflows (§5–§9), event-data capture, Honda traceability, integration touch points, scope boundary, the 6 remaining open items.
- **In-document Revision History** reset to start at v1.0 with one consolidated entry summarising the 16 sections covered + the 6 remaining open items. Pointer block to the standalone changelog removed.
- **`MPP_MES_FDS_CHANGELOG.md/.docx`** marked archival as of v1.0; standalone artifact retained as the historical record of design evolution but no longer appended to.

### 2026-05-01 — Outstanding Items extract + 9-item closure pass + companion FDS amendments

Built a focused 15-item working extract of the OIR (`MPP_MES_Outstanding_Items.md` / `.docx`) for customer review. Jacques marked it up by adding "Final decision" annotations to 9 items; clarified two follow-ups (per-Operation split flag confirmed as the implemented mechanism; UJ-19 four PD reports remain MVP scope while reports beyond the four = post-deployment change order); approved a four-doc landing pass.

- **OIR v2.17** (companion to this session) — closed OI-07, -24, -25, -27, -28, -29, -30, -31, UJ-03 → all ✅ Resolved with explicit Decision (2026-05-01) blocks. Counts shift: Part A Resolved 22 → 30, In Review 1 → 0, Open 11 → 4 (only OI-32, -33, -34, -35 remain). Part B Resolved 16 → 17, In Review 1 → 0, Open 2 → 2 (UJ-05, UJ-19). Grand total: 54 items, 47 resolved, 0 in review, 6 open, 1 superseded.
- **FDS v0.11p** — **FDS-16-003** amended: cutover-day seeding rule changed from "at or above the Flexware value" to a concrete `<Flexware-current> + 10,000` offset (or MPP-agreed delta). Sample post-offset cutover seeds: `Lot=1,720,932`, `SerializedItem=12,492`. The "Open items (OI-31)" paragraph absorbed into design fact (format carry-forward, no reset policy, ~30+ year rollover horizon). **FDS-12-015 NEW** — `§12.6 Notifications Posture — MVP` establishes banners-only via terminal-context broadcast (FDS-07-006a/b, elevation banners, hold tiles, AIM-pool alarm tiles); text and email notifications are out-of-MVP, future change order. **Embedded Open Items Register reduced** from 14 unresolved items to 6 (OI-33, OI-35, UJ-19 HIGH; OI-34, OI-32, UJ-05 MEDIUM); previously-omitted OI-35 row added.
- **`MPP_MES_Outstanding_Items.md/.docx` v2.0** — refreshed to the 6 remaining Open items only (OI-32, OI-33, OI-34, OI-35, UJ-05, UJ-19). Customer-facing working draft for Phase 0 / architecture-review walk-throughs.
- **No data model / SQL / UJ doc changes this session** — register entries + FDS prose only.
- **Phase 0 Track A items reduced** from 9 to 8 (OI-31 closed; sub-question Ben rollout-shape no longer Phase-0-gating). Active blockers stay: OI-35 architecture gate (HARD) + Phase 0 Customer Validation Workshop.

### 2026-04-30 — Arc 2 Plant Floor mockup + FDS amendments

Substantial day building the operator-facing UI mockup and correcting two FDS sections.

- **`mockup/plantFloor.html` + `mockup/plantFloor.css` + extracted `mockup/styles.css`** — 12 terminal/lot routes covering every operator surface in the Phased Plan v1.0: `home`, `terminal/initials`, `terminal/cell-context`, `terminal/diecast`, `terminal/trim-in`, `terminal/trim-out`, `terminal/machining-in`, `terminal/assembly`, `terminal/assembly-ns`, `terminal/sort-cage` (Serialized + Non-Serialized variants), `terminal/receiving`, `terminal/shipping`, `terminal/end-of-shift`, `lot/detail`. Home Page has plant-hierarchy tree dock + tabbed details panel (Location Details + LOT Search + Genealogy Lookup + Hold Management + Supervisor Dashboard with AIM Pool Wallboard tile). Cross-cutting modals: Elevation, BOM Rename, Idle Re-Confirm, Material Substitute Override, Change Cell Context. Print Failure Banner. Header has elevation toggle (mockup demo affordance), app-title-as-home-link, breadcrumb (terminal routes only), Config Tool nav-out (elevated only). Polymorphism via Flex Repeater + Embedded View. Per-action AD elevation pattern with secondary-color treatment for elevated buttons. 1080p scroll-free with inner-repeater scroll modifiers for high-N entity lists. Touch-friendly (44 px minimum touch targets, 56 px header).
- **FDS v0.11m → v0.11n** (commit `361f6a4`): **FDS-09-013** End-of-Shift Time Entry — selection mechanism corrected to button-toggle on both terminal modes. 3 toggleable buttons (Lunch · 30 min, Break 1 · 15 min, Break 2 · 15 min) tap-to-select / tap-to-deselect. No numeric duration entry. Differences between Dedicated and Shared scoped to identity capture only (Shared adds inline initials field + 3-button single-select Time Category — Regular / Overtime / Double-Time). Zero-button submission valid (operator skipped breaks → no DowntimeEvent rows).
- **FDS v0.11n → v0.11o** (commit `d7f889f`): **FDS-06-014** ByVision row corrected — camera scans the FULL TRAY as a single image, ONE validation event per tray (not per piece). Four-tray container = four passing tray-scan events. Per-tray `ConsumptionEvent` semantics clarified. New OPC tag names: `TrayPresent`, `TrayValidationResult`, `TrayFullFlag`. Same mechanic applies in Sort Cage non-serialized re-pack (uses the same camera).
- **Phased Plan v1.0 implication flagged** — Phase 1's "Terminal Selector" placeholder is structurally a Home Page (plant browser) for elevated desktop users, not a generic Terminal Selector. Mockup proves the model; Phased Plan + FDS will be updated at next pass to match. Companion FDS-02 paragraph also pending.

### 2026-04-29 — Multi-doc reconciliation + scaling-gate tracking + Phased Plan rebuild + DM column add

Five commits over the day landed substantial work.

- **OIR sync + DM column adds** (commit `c7ca780`) — DM v1.9j → v1.9k. `Lots.ShippingLabel.BannerAcknowledgedAt DATETIME2(3) NULL` added (FDS-07-006b broadcast-script Acknowledge action). `CoupledDownstreamCellLocationId` LocationAttributeDefinition seeded under `CNCMachine` (FDS-06-008 auto-move target). OIR v2.14 → v2.15 — OI-33 (AIM pool empty-pool hard-fail customer validation, HIGH) + OI-34 (production schedules leverage, MEDIUM) folded from embedded FDS register into canonical OIR. OIR v2.15 → v2.16 — **OI-35 NEW (HIGH) "MUST DECIDE BEFORE ARC 2 PHASE 1 SQL BUILD"** — long-horizon scaling, retention, archiving strategy.
- **DM v1.9l + UJ v0.9 reconciliation** (commit `3851802`) — comprehensive sweep aligning DM and UJ to FDS v0.11m. DM v1.9k → v1.9l: ContainerConfig `ByVision` reframed as tray-level trigger; "Casting → Trim" subsection retitled "Trim → Machining" with full BOM example rewrite (5G0-TRIM Component + 5G0-MACHINED Sub-Assembly); `Parts.v_EffectiveItemLocation` view documented (Direct ∪ BomDerived per FDS-02-012); deferred event tables (WorkOrderOperation, ConsumptionEvent, RejectEvent, DowntimeEvent) renamed `OperatorId` → `AppUserId`; UJ-14 + UJ-16 PENDING callouts converted to resolved-prose; 5 Arc 2 admonitions stripped; WorkOrderType SQL correction marked landed; Tools cross-references rewritten. UJ v0.8 → v0.9: 4 high-impact scene rewrites — Trim Shop ("Trim is yield loss, not a rename" + "Trim OUT split + route to Machining FIFO"); Machining scene (FIFO pick + BOM rename at IN, PLC-driven auto-move at OUT); 11:30am Assembly tray-level closure with three peer methods + configured-value references; End of Shift FDS-09-013 single-submission rewrite. Assumption status flips: UJ-12, UJ-14, UJ-16, UJ-18 → ✅ Resolved.
- **Phased Plan Plant Floor v0.3 → v1.0 full rebuild + DM v1.9m** (commit `cf11542`) — complete document rebuild. 1825 lines (down from v0.3's 2077). Phase shape preserved (9 phases, 0–8). Cross-Cutting Concerns B1–B17 lifted verbatim with B12 reframed for **Flex Repeater + Embedded View** as the polymorphic primitive. NEW Seeding Registry — Phase Coupling section maps S-01..S-11 to phases. Phase 0 expanded with parallel **Architecture Decision Workshop** track (OI-35). Phase 1 bakes OI-35 architectural decisions into the migration on day one. Phase 3 Die Cast walkthrough corrected for **Shared terminal model**. Phase 4 Trim OUT branches on `Parts.OperationTemplate.RequiresSubLotSplit`. Phase 5 Machining whole rewrite (FIFO pick + BOM rename at IN; PLC-driven auto-complete + auto-move via CoupledDownstreamCellLocationId at OUT; no operator OUT view). Phase 6 Assembly tray-level closure with three peer methods. Phase 7 AIM pool topup loop + tier alarms. Phase 8 FDS-09-013 end-of-shift entry. Migration numbering rebased — Phase 1 lands at `0014`. **DM v1.9l → v1.9m** companion: `Parts.OperationTemplate.RequiresSubLotSplit BIT NOT NULL DEFAULT 0` added.

### 2026-04-28 — FDS continuity + clarity pass + indexing review

FDS lifted from v0.11j → v0.11m across multiple amend-in-place sessions. Major edits:

- §1.4 layer diagram → table; §1.7 FDS-01-007 historian-DB-separation guidance added.
- §2.5 Cell Context Selection (scan **or** dropdown — was scan-only); FDS-02-010 mode-derivation table refreshed (Cell→Dedicated, WC→Shared, Area→Shared); FDS-02-012 expanded with BOM-derived eligibility.
- §3.6 + §6.6 closure granularity corrected to **tray-level** (FDS-03-017 / FDS-06-013 / FDS-06-014 rewritten — `ClosureMethod` extended with `ByVision`).
- §5.10 + FDS-05-033 part-identity rename moved one step downstream from Casting→Trim to **Trim→Machining**; §5.4/§6.3/§6.4 Trim→Machining workflow reframe (sub-LOT split at Trim OUT not Machining IN; Machining OUT auto-completes via PLC and auto-moves to coupled Assembly Cell via new `CoupledDownstreamCellLocationId` LocationAttribute).
- §9.4 end-of-shift time entry (lunch + breaks only, ~15-min header window).
- FDS-07-006b reframed from per-session bound-query to **Gateway-broadcast-with-session-filter** (one DB query per 5s regardless of terminal count).
- Document-wide strip of project-execution decoration (Arc 2 / Phase N / version trailers / "Implementation deferred" admonitions / requirement-deletion tombstones).

**Standalone FDS Change Log doc** — `MPP_MES_FDS_CHANGELOG.md` + `.docx` created. Pre-release pattern: change log lives in companion doc while FDS is in active development; reintegrates into FDS at customer-review release.

**Data model v1.9j** — `Parts.ContainerConfig.ClosureMethod` extended with `ByVision`; UpperCamelCase casing applied; OI-02 caveat retired.

**Indexing & query-perf review** — full report at `Meeting_Notes/2026-04-28_DataModel_Indexing_Scaling_Review.md`. Phase 1–8 already-built schemas have good index coverage; the gap is the **deferred Arc 2 tables** (Lots event tables, Workorder.ConsumptionEvent / RejectEvent, Oee.DowntimeEvent, Quality.HoldEvent) — 14 tables × multiple indexes each need to be pinned in the data model spec before Arc 2 Phase 1 CREATE migrations are written. Three architectural concerns also flagged: 20-year audit retention strategy, `v_LotDerivedQuantities` materialization criteria, recursive-CTE depth limit on `LotGenealogy`. All pre-Arc-2-Phase-1 decisions.

### 2026-04-27 — Integration queue + UJ enrichment + closure batch

- **Integration queue from OIR v2.10 — 7 of 8 landed:** (1) OI-12 MaxParts ✅ `47a4e25`, (2) OI-18 ItemLocation cascade ✅ `0f7f40f`, (3) OI-08 Terminal mode ✅ `7a9d87e`, (4) OI-23 Lot derivations view ✅ `e393b7d`, (5) OI-16 PLC confirm + RequiresCompletionConfirm ✅ `55427f5`, (6) OI-21 Pausable LOT — design locked + landed ✅ `15edd5e`, (7) UJ-04 AIM pool — design locked + landed ✅ `82df891`. (8) OI-13 BOM export moved to seeding registry as S-06.
- **UJ enrichment + closure batch** — 13 UJ entries enriched to OI-style depth in v2.13 (commit `483948e`); Jacques reviewed the docx and closed 10 in v2.14 (commit `a2b58f5`): UJ-07/-08/-11/-13/-14/-16 (Option A defaults), UJ-09 (Option C — strict + supervisor override), UJ-10 (Option D — shift-end summary), UJ-17 (Option A — ConfirmationMethod LocationAttribute), UJ-18 (Gateway-script-async architectural — FDS-01-014 + print-dispatch async pattern + ShippingLabel +5 print-state cols).

### 2026-04-23 / -24 — Arc 2 Model Revisions + corrections

- **Arc 2 Model Revisions (2026-04-23 session)** — 6 commits on 2026-04-23 lifted doc set to Data Model v1.9 / FDS v0.11 / UJ v0.8 / OIR v2.7 / Arc 2 Plan v0.2. Tool/Cavity promoted to `Lots.Lot`; ProductionEvent reshaped to checkpoint form; new `Lots.IdentifierSequence` table; `MaxLotSize` repurposed as `PartsPerBasket`; OI-09 closed (cavity-parallel LOTs as peers); OI-26 deleted; OI-31 opened.
- **2026-04-24 corrections + integrations:**
  - ERD full rebuild — every tab fully current to v1.9; Master tab rebuilt from v1.5 baseline; Audit `bigbigint` typos + OEE column mismatches fixed; Tools cross-schema FKs drawn (commits `2a91da0`, `70d0f37`).
  - Phase 0 + Phase 1 of Arc 2 Plan rewritten in-place (clock# + PIN removed from body, not just overlay) — commit `9121502`.
  - **OI-07 correction** — `WorkOrderType` corrected to single `Production` row; Demand + Maintenance moved to FUTURE hooks; Recipe deleted (commit `ce3e080`).
  - **Storyboards + IPAddresses review** (commit `7550bb8`) — 2012 Flexware docs reviewed against v1.9 design. 83% coverage. Report at `reference/NewInput/REVIEW_2026-04-24.md`. OI-32 Material Allocation + OI-32b Material Classes opened.
  - **OI-31 single-line deployment memo for Ben** — `Meeting_Notes/2026-04-24_OI-31_Single-Line_Deployment_Impact.md`.
  - **Jacques's OIR review batch applied** (commit `6865d8d`, OIR v2.10) — 17 Part A OIs moved Resolved + 2 UJ closures (UJ-02, UJ-04).

### Earlier landmarks

- **Phase G SQL** — All five sub-phases (G.1–G.5) landed by 2026-04-23 (terminal commit `534f55c`). 853/853 tests passing across 20+ test suites at that point.
- **2026-04-20 OI review refactor** — All phases (A/B/C/D/E/F/G) landed.
- **Phase B Tool Management design spec** — Approved 2026-04-21 (commit `47ce9c7`). Full schema spec at `docs/superpowers/specs/2026-04-21-tool-management-design.md` v0.2.
- **Legacy PDF references** — `reference/Manufacturing Director Technical Manual.pdf` (2009 Flexware doc) converted to searchable Markdown at `reference/Manufacturing_Director_Technical_Manual.md` on 2026-04-21. Converter `reference/scripts/convert_mdtm_to_md.js` reusable for future Flexware docs.
- **Seed data extraction** — 876 rows extracted from FRS Appendices B/C/D/E into CSVs in `reference/seed_data/`, plus auto-generated `reference/seed_data.xlsx`. Per-appendix Node.js parsers in `reference/seed_data/parsers/`. Source PDF: `reference/MPP_FRS_Draft.pdf`.
