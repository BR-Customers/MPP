# Working notes — 2026-07-15

## Bugs / observations

- **Die Cast Lot Entry: duplicate LTT barcode accepted.** Able to submit the
  same LTT barcode twice in Die Cast Lot Entry — no uniqueness/duplicate guard
  is rejecting the second submission. Expected: a repeated LTT barcode should be
  rejected (an LTT identifies a single physical LOT container). Needs
  investigation — likely enforce uniqueness at the SQL layer (LOT create /
  LTT assignment proc) rather than the UI.

- **Die Cast Lot Entry: part's default piece count not applied.** ~~When a part is
  selected, the entry does not pre-fill the piece count from the part's default~~
  **RESOLVED 2026-07-15 — configuration error, not a code bug.** Confirmed via DB:
  every part had `MaxLotSize = NULL` / `DefaultSubLotQty = NULL`, so the existing
  `applyItemDefaults` seed (`perBasket = MaxLotSize or DefaultSubLotQty`) had
  nothing to apply. The seeding logic + onChange wiring are correct; the parts
  just needed their default piece count ("Parts Per Basket" = `MaxLotSize`)
  configured. User set the config.

- **Die Cast cavity shift details: "Shots this shift (incl. scrap)" miscounts.**
  The cavity shift-detail panel does not properly account for scrap + pieces in
  the "Shots this shift (incl. scrap)" figure. Observed (Cavity 1): Shots this
  shift (incl. scrap) = 192, Pieces this shift = 192, Scrap this shift = 22.
  The numbers are inconsistent — if the shots total is meant to include scrap,
  it should be pieces + scrap (192 + 22 = 214), or pieces should net out scrap
  (192 − 22 = 170). Currently "shots (incl. scrap)" equals pieces and ignores
  the 22 scrap. Reconcile the aggregation (shots vs pieces vs scrap) in the
  cavity shift-detail query/rollup.

- **Die Cast "Logged this run" list drops rows / possibly session-scoped.**
  Logged 6 LOTs but only 4 appear in the bottom "Logged this run" section. A
  screen refresh occurred at some point. Need to confirm whether that list is
  session/client-state based (in-memory, lost/desynced on refresh) or read from
  the DB (source of truth). If it's session-based it should either survive
  refresh or be re-hydrated from the DB on load; if it's DB-backed then the
  query/filter is dropping rows. Determine the data source first, then fix
  accordingly.
  - **Update:** LOT Search (DB source of truth) shows all 6 LOTs
    (MESL3000001–006), so the DB persisted every LOT. The "Logged this run"
    panel is the one dropping rows (2 missing) — points at the panel being
    session/client-state based and desyncing on refresh rather than a DB write
    failure.

- **Die Cast scrap accounting: scrap subtracted from LOT instead of added on
  top.** Scrap appears to be deducted from the LOT piece count rather than being
  additive. Intended flow: produce parts until the basket is full, report a full
  LOT (e.g. 96), and separately report the scrap (e.g. 4) — so total produced =
  100 (96 good in the LOT + 4 scrap), and the LOT stays at its reported full
  count (96). Currently the reported scrap looks like it reduces the LOT's pcs
  (LOT Search shows pcs of 93 / 79 / 74 on some LOTs vs the full 96), which is
  wrong — good pieces in the LOT should not be decremented by scrap. Related to
  the "shots this shift (incl. scrap)" miscount above; both are scrap-vs-pieces
  aggregation bugs — fix the model so scrap is additive/independent of LOT good
  count.

- **Move to Trim: "not eligible at destination" + dead MOVE button.** Tried to
  move part 5G0-c to the Trim station. Eligibility was confirmed, yet the UI
  shows red text "not eligible at destination". The MOVE button renders blue
  (active/enabled) but does nothing on press — no toast, no navigation, no
  error, silent no-op. Two problems: (1) eligibility check is returning
  not-eligible when it should pass (destination/location resolution mismatch?
  cf. move-eligibility resolves against the terminal's immediate parent /
  zoneLocationId), and (2) the button is enabled despite the failed eligibility
  and swallows the click with no feedback — it should either be disabled when
  ineligible or surface a rejection toast. Check the move-eligibility resolution
  and the MOVE handler's guard/feedback path.
  - **Stack trace (15Jul2026 14:10:18, WARN ViewModel — likely ROOT CAUSE):**
    The view's `load()` custom method (fired from a `view.params.value`
    `valueChanged` property-change script) calls
    `BlueRidge.Parts.Item.getPlcId` (Core `Parts/Item` code.py line 453) →
    `Common.Db.execOne`/`execList` → named query → SQL, which fails with:
    `Could not find stored procedure 'Parts.Item_GetPlcId'`.
    So `load()` throws before finishing — that almost certainly leaves the Trim
    view half-initialized, which explains BOTH symptoms: the spurious "not
    eligible at destination" red text and the MOVE button that's enabled but
    does nothing (its wiring/guards never completed).
    Two distinct problems:
      1. **Screen shouldn't call `getPlcId` here** — user confirms PLC
         validation is not needed on this move/Trim screen, yet `load()` invokes
         it unconditionally. Gate the getPlcId call to only the screens/parts
         that need PLC validation, or make `load()` tolerate its absence instead
         of aborting the whole load.
      2. **`Parts.Item_GetPlcId` proc missing from this DB** — a deployment gap,
         NOT a missing-code gap. CONFIRMED: the proc exists in the repo as a
         repeatable migration `sql/migrations/repeatable/R__Parts_Item_GetPlcId.sql`
         (+ its NQ `parts/Item_GetPlcId`); it simply was never applied to this
         dev DB. The R__ file is a pure `CREATE OR ALTER PROCEDURE` read proc
         (`SELECT PlcId FROM Parts.Item …`) — no INSERT/UPDATE/DELETE/DROP/
         TRUNCATE — so applying it is DATA-SAFE (defines the proc, touches no
         rows). Same class as today's `Location.TerminalPlcDevice_GetByInstancePath`
         gateway error — a batch of PLC-integration repeatable procs (recent
         Plan 3 PLC work) isn't deployed to this dev DB. Fix: manually apply the
         missing repeatable proc(s); no reset needed. (All R__ files are
         idempotent CREATE OR ALTER — safe to re-run.)
      - **RESOLVED 2026-07-15 (proc-not-found portion).** Root cause turned out
        deeper: dev DB was 3 versioned migrations behind (applied through 0036;
        missing 0037 quality-capture, 0038 PLC foundation, 0039 PLC handshake
        audit). `Parts.Item.PlcId` column comes from 0038, so the proc couldn't
        even compile. Applied 0037→0038→0039 (all additive/guarded/data-safe, no
        reset) + re-ran all 349 repeatables (347 first pass, +2 PlcId after the
        column existed). Verified: PlcId column present, 3 migrations recorded,
        Item_GetPlcId/Item_SetPlcId procs exist. The `getPlcId` crash on the
        Trim load() should be gone — re-test the move-to-Trim.
      - **getPlcId was a RED HERRING for this bug.** `getPlcId` is called by ZERO
        MPP-project views (grep) — the crash came from the Item Master config
        screen (MPP_Config), not the Trim/move flow. The move eligibility issue
        is independent.
  - **REAL ROOT CAUSE (2026-07-15): move destination is bound to the selected
    PRESS cell, not the Trim AREA.** DB confirms 5G0-c IS Direct-eligible at
    TRIM1 (id 37, a ProductionArea). The trim presses (TRIM1-P01/02/03 =
    40/41/42) are CHILDREN of 37. In TrimBody the MovementScan embed binds
    `props.params.destinationLocationId` → `session.custom.cell.locationId` (the
    press picked in a dropdown). The eligibility proc walks UP from the
    destination (`ufn_AncestorLocationIds`), so:
      - No press selected → destination null → "not eligible at destination".
      - Press selected → ancestor walk reaches area 37 → eligibility goes green.
    That is why eligibility only turns green after picking a press — it's the
    ancestor walk indirectly satisfying the AREA rule. Per design intent
    (project_mpp_move_eligibility_location_resolution: validate against the
    terminal's zone/immediate parent), Trim content is tracked at the AREA, not
    the press.
  - **PROPOSED FIX (needs scope confirm):** (1) remove the press-selection
    dropdown; (2) re-point the move destination from `session.custom.cell.locationId`
    to `session.custom.terminal.zoneLocationId` (= area 37) so eligibility
    validates the area directly and is green immediately. BLAST RADIUS: other
    TrimBody bindings also key off `session.custom.cell.locationId` — the
    `trimInventory` WIP-queue binding (getWipQueueByLocation) and `submitTrimOut`.
    Open question: does Trim OUT need the press for machine/OEE, or is area-level
    correct for both IN and OUT?
  - **IMPLEMENTED 2026-07-15 (pending live re-test).** Confirmed Trim OUT is
    already zone-based (`submitTrimOut` uses `terminal.zoneLocationId` as source +
    the Machining `destValue`; never touched the press) — so OUT is unaffected.
    Switched Trim to the dedicated-flavor pattern (FDS-02-010, same as Machining/
    Assembly/DieCastDedicated): (1) `TrimShared` embed `cellPickerEnabled: true→false`
    (hides the press ContextBar); (2) `TrimBody.startup()` now sets
    `session.custom.cell = {locationId: zoneLocationId, ...}` from the terminal.
    Net: WIP queue + MovementScan destination now key off the AREA (37);
    eligibility is a direct match, green on arrival, no press pick. Dead code left
    for later cleanup: `applyCell` method + `cells` custom prop. Scanned; needs
    Designer reopen + live re-test of the move-to-Trim.
  - **v1 FAILED live (destination still None) — diagnosed via gateway log +
    a temporary `startup()` diag.** Two findings: (a) the test was on `TRIM2-T1`
    (Trim Shop 2, zone 43), where 5G0-c is NOT eligibility-configured — 5G0-c is
    configured at Trim Shop 1 (37) / Die Cast (3) / MA1-5GOF (81) only, so it is
    *correctly* ineligible on Shop 2; (b) the real fix bug was a RACE:
    `session.custom.terminal` is set by the tree BEFORE navigation (populated at
    mount), but `startup()` writes `session.custom.cell` AFTER mount, and
    `MovementScan`'s embed-param binding reads `cell.locationId` at mount → gets
    the null default.
  - **v2 FIX (implemented 2026-07-15).** Bind the IN-side directly to the
    pre-populated terminal zone (race-free, no imperative write): re-pointed the
    MovementScan destination, the Trim WIP-queue, and the context label from
    `session.custom.cell.locationId`/`.name` → `session.custom.terminal.zoneLocationId`/
    `.zoneName` (4 locationId + 3 name refs). Reverted `TrimBody.startup()` back to
    operator-gate only (dropped the cell-set + diag). `session.custom.cell` no
    longer read on the Trim IN path. Scanned. **Re-test on the TRIM1 terminal
    (Trim Shop 1)** — 5G0-c should show eligible (destination = 37) and move.
    (If 5G0-c should also be movable to Trim Shop 2, that's a config add — an
    eligibility row at location 43 — not a code change.)

- **Move eligibility badge overpromises (cosmetic, not a data bug).** The green
  "Eligible at destination" badge on the Movement Scan calls
  `ItemLocation.checkEligibility(itemId, destLocationId)` — item-at-location only.
  It does NOT know the LOT's current location, so a LOT already at the
  destination still shows green. The authoritative `Lots.Lot_MoveToValidated`
  proc DOES guard this (same-location reject, lines 116–126: "LOT is already at
  the destination location (no-op)"), plus MaxParts + blocked-status — so
  clicking Move fails safely; no double-move / bad data. Optional polish: pass
  the LOT (or its CurrentLocationId) into the eligibility check so the badge can
  pre-empt "already here" (and maybe MaxParts) instead of only failing on submit.
  NOTE: the alarming screenshot (a LOT "in trim" that was really at Die Cast 1)
  was the pre-v2 cell-leak, now fixed — Trim reads `terminal.zoneLocationId`.

- **Trim IN stale "press" wording (cleanup after picker removal).** With the press
  dropdown gone, the empty-state text still says "No LOTs checked in at this
  press. Pick a press above, then scan LOTs in." and the panel says "at this
  press" — should read area-level ("…in this area" / drop "pick a press").
  Low-priority copy fix in TrimBody.

- **Die-cast LOTs never move to the warehouse after creation (process gap).**
  MESL3000001–006 (5G0-c, minted at Machine 01 / DC1-M01) all still sit at
  Machine 01 — LOT Search Location = Machine 01, and LOT history shows only
  `(none) → Machine 01 [via Terminal]` at creation, no onward move. Per design
  intent (R__Lots_Lot_GetShiftCavityTally.sql header: die-cast LOTs are "Created
  at the terminal and moved straight to storage"), after minting they should
  move to the Warehouse (`WHSE`, id 181, SupportArea). CONFIRMED never
  implemented: `Lot_Create` is generic (places the LOT at the passed
  `@CurrentLocationId` = the machine), the die-cast `submitCreate` does no
  post-create move, and there is zero warehouse/storage handling in code.
  Symptom: these machine-resident LOTs show up in a Trim "CURRENTLY IN TRIM"
  WIP queue when viewed on a Die Cast terminal context (queue walks Die Cast
  descendants incl. the machine). Fix = add the mint→warehouse move.
  Implement in SQL (no-business-logic-in-Python); resolve WHSE by well-known
  code/kind, not a hardcoded id; non-eligibility-gated system move (warehouse is
  storage, not a production location → Lot_MoveTo, not Lot_MoveToValidated).
  Scope: die-cast origin only (Machining/Assembly are line-resident by design).

- **Trim OUT / Machining OUT "template missing" — wrong template lookup (FIXED
  2026-07-16).** Trim OUT submit and the Machining-OUT-split `opTemplateId`
  binding resolved the operation template with `getActiveTemplateIdByCode(<role>)`
  — which matches a template's OWN code. But templates are coded `T-Out-A` /
  `M-Out-A`, not the role codes `TrimOut` / `MachiningOut`, so it always returned
  None → "No active '<role>' operation template is published", even though the
  part's route was configured correctly. Die Cast was already on the route-aware
  `getActiveTemplateIdForRoute(itemId, role)`; these two were never migrated. Fix:
  added Core helper `OperationTemplate.getActiveTemplateIdForLot(lotId, role)`
  (lot → ItemId via Lot.get → getActiveTemplateIdForRoute); TrimBody.submitTrimOut
  now calls it with `lotId`; MachiningOutSplit `opTemplateId` binding now
  `runScript(...getActiveTemplateIdForLot, 0, {parentLot.Id}, "MachiningOut")`.
  Verified the route-role lookup returns T-Out-A (tmpl 10) for 5G0-c. Scanned;
  needs live re-test of Trim OUT + Machining OUT.
  - **STILL OPEN (separate):** `DieCastEntry/CheckpointPanel` calls
    `getActiveTemplateIdByCode("DieCastShot")` — but no template is coded
    `DieCastShot` and it is not an OperationType, so the route-aware swap does NOT
    apply. This is an unseeded/deferred die-cast-shot checkpoint template (the
    shot data-collection panel). Flag for later; not fixed.
  - **Machining IN — SAME bug in SQL (FIXED 2026-07-16).** `MachiningIn_RecordPick`
    resolved the template with `OperationTemplate.Code = N'MachiningIn'` (no such
    code → NULL → "MachiningIn OperationTemplate is not configured"). Fixed the
    repeatable proc to resolve route-aware off the LOT's item route
    (`oty.Code = N'MachiningIn'` via RouteTemplate/RouteStep), moved after the LOT
    load so @ItemId is known. Applied to dev DB (CREATE OR ALTER, data-safe);
    verified live definition is route-aware + returns M-In-A (tmpl 11) for 5G0-c.
    Repeatable file edited (uncommitted).

- **Die-cast warehouse auto-deposit — IMPLEMENTED 2026-07-16.** After a die-cast
  LOT is minted at the machine it now auto-moves to the Warehouse (WHSE), per the
  approved design (automatic on creation; history = born-at-machine → moved-to-
  warehouse, two movement rows; soft-skip + message note if no WHSE configured).
  Implementation: `Lot_Create` gains `@DepositToStorage BIT = 0` (OFF by default →
  receiving/other origins unaffected); when 1, after the birth placement it
  resolves WHSE by code, INLINE-moves the LOT there (2nd LotMovement + LotMoved
  audit), floored by a soft-skip when WHSE is absent. Threaded through
  `lots/Lot_Create` NQ (+ `depositToStorage` param, INTEGER/0-1→BIT), Python
  `Lot.create` (`d.get("depositToStorage")`), and DieCastBody `submitCreate`
  (passes `True`). Proc applied to dev + rollback-transaction tested: LOT lands in
  Warehouse with movements `(none)→Machine 01` then `Machine 01→Warehouse`,
  nothing persisted. Scanned. Needs live UI test (create a die-cast LOT → verify
  it lands in the Warehouse). Existing MESL LOTs unaffected (forward-only);
  MESL3000001–003 were manually backfilled earlier, 004–006 remain at the machine.

- **Assembly: "insufficient component stock" toast doesn't say WHICH component is
  short.** When a line lacks component stock to complete a tray, the toast reads
  `Insufficient component stock at the line for one or more BOM lines.` — generic,
  no part named. ROOT CAUSE FOUND: `Workorder.Assembly_CompleteTray`
  (R__Workorder_Assembly_CompleteTray.sql lines 174–190) — the FIFO stock
  pre-check uses `IF EXISTS(SELECT 1 FROM Parts.BomLine ... WHERE s.Avail <
  bl.QtyPer * @PieceCount)`, so it *detects* a shortfall but discards which
  line(s). All the data to name them is right there: `BomLine.ChildItemId →
  Parts.Item.PartNumber`, required = `QtyPer * @PieceCount`, available = `s.Avail`.
  FIX: replace the EXISTS with an aggregation that lists the short components in
  `@Message`, e.g. `"Short: 5G0-SA need 96 have 40; XYZ need 12 have 0"` (cap
  length via Audit.ufn_TruncateActivity). SQL-only change to the one proc; the
  toast already surfaces `@Message` verbatim.
  - **FIXED 2026-07-16.** Replaced the `IF EXISTS` with a `STRING_AGG` that lists
    each short component as `PartNumber (need X, have Y)`, truncated. Applied to
    dev (CREATE OR ALTER, data-safe) + verified against 5G0-FG's BOM: message =
    `Insufficient component stock at the line -- short: 21001 pin (need 60, have
    0); 5G0-SA (need 10, have 0)`. Repeatable file edited (uncommitted).

## Constraints (this testing session)

- **DO NOT reset the dev DB.** Live test data in play (LOTs MESL3000001–006,
  cavity/scrap testing). Any SQL fix must be applied MANUALLY and
  non-destructively (e.g. run a single repeatable `CREATE OR ALTER` proc file),
  never via the reset/seed scripts. Ref [[project_mpp_dev_db_testing_env]].
