# Backlog — CRT + shop-floor items (captured 2026-08-19)

Raw backlog handed over by Hunter on 2026-08-19, recorded verbatim in intent so
work can be picked up later without re-deriving it. Branch at capture time:
`hunter/explore` @ `3f9f9fa0`.

Status legend: **OPEN** (not started) · **WIP** · **DONE** · **BLOCKED** (needs a
decision from MPP or Hunter).

---

## 1. CRT — needs a design conversation before any code

**BLOCKED — do not implement from this note alone.** The existing CRT work on this
branch (`Container_ValidateCrt`, the assembly-out validation button, the
changeover-popup CRT switch) is *container*-scoped. The requirement below is
*part*-scoped and materially larger.

Requirement as stated:

- CRT is normally **part based**. A "CRT enabled" flag on the part; **any LOT of
  that part created while the bit is on is stamped `CRTActive`**.
- On LOT creation → **popup** telling the operator the LOT is marked CRT.
- On any later attempt to use that LOT **at a different terminal** → **popup that
  blocks use** until cleared.
- **Only a Quality person can clear it** (elevated / role-gated action).
- A **machined** part marked CRT: when a LOT is created from it, the **new label
  must carry the CRT mark**.
- **CRT at assembly out** behaves the same, and its **label must also include CRT**.

Open questions to resolve with Hunter/MPP first:
- Where does the part-level flag live — `Parts.Item`, `ContainerConfig`, or a new
  `Parts.ItemCrt` with effective dating? Needs history: "which LOTs were minted
  while the bit was on" must stay answerable after the bit is turned off.
- Does `CRTActive` propagate through genealogy (casting → SubAssembly → FG), or is
  it re-evaluated from the part flag at each mint?
- "Different terminal" — does the *originating* terminal stay unblocked
  deliberately, or is that incidental?
- Clearing: per-LOT, per-container, or bulk-by-part? Audit shape?
- Label change: ZPL template variant vs. a conditional field on the existing
  template. Affects `Lots.LotLabel` + the Zebra templates.
- Interaction with the existing container-scoped CRT already built — replace,
  or coexist?

## 2. Die Cast — Record Shift Output screen

| # | Item | Status |
|---|---|---|
| 2.1 | Pre-populate the reporting shift with the **current** shift | DONE |
| 2.2 | Cavity name must show the **actual cavity name**, not "Cavity 1" | DONE |
| 2.3 | Remove the **limit on scrap reasons** per cavity | DONE |
| 2.4 | Operators should **not see released lots** on record shift output | DONE |
| 2.5 | Good-pc entry field → **display only** (no longer operator-editable) | DONE |
| 2.6 | Better use of space for cavities (layout explore) | DONE |
| 2.7 | Remove the extra comments/instruction text on the die cast screen | DONE |

## 3. Die Cast — behaviour / back end

| # | Item | Status |
|---|---|---|
| 3.1 | Defect codes offered at die cast must be **die-cast codes only** | DONE (not a code bug - see below) |
| 3.2 | **Die total shots does not increment** when Register Shot Loss is used | DONE (CONFLICTS WITH AN APPROVED DECISION - needs Hunter) |
| 3.3 | Multiple terminals on the **same die cast machine** must see each other's entries | DONE |
| 3.4 | **Bulk open of baskets**: a row per cavity on the mounted tool, operator selects the part and scans the LTT per row | WIP - auto-assign DROPPED 2026-08-19 |
| 3.5 | Die cast **supervisor dashboard** — registered production total, current + previous shift (explore) | DONE (explore) |

## 4. Auth / permissions

| # | Item | Status |
|---|---|---|
| 4.1 | Only a **supervisor** may edit or void a downtime event | DONE |
| 4.2 | **Sort cage** needs an elevated-access requirement | DONE |
| 4.3 | Elevated access must authenticate against the **Active Directory** user source, not the MPP internal source | BLOCKED - no AD user source exists on the gateway |

> 4.3 relates to `AppUser.elevate` / `_validateAdCredentials`. Note the interim
> `system.security.validateUser(..., _DEV_USER_SOURCE)` path added in `ebc70495`
> — that is the thing being replaced.

## 5. LOT / Lot Detail

| # | Item | Status |
|---|---|---|
| 5.1 | **8-digit LTT** at machining and die cast — the current 9-digit check is wrong there | DONE |
| 5.2 | **Scrap tab on Lot Detail** — attribute scrap to a LOT against its *current location* (die cast → die cast, warehouse → warehouse, …). All defect reasons available, not a filtered subset | DONE |
| 5.3 | **Rectify LOT counts** in Lot Detail when entered wrong, with a mandatory reason | DONE |

## 6. OEE / shifts

| # | Item | Status |
|---|---|---|
| 6.1 | **Shift override screen** — let an operator extend a shift on a given day for a *specific piece of equipment*. Affects OEE. Resolution order: for a given day, if the equipment has an override use it, else fall back to the global shift | OPEN |
| 6.2 | **Validate the shift hours** used by the downtime report | DONE - found 6 bugs, 2 corrupting stored data |

## 7. Styling

| # | Item | Status |
|---|---|---|
| 7.1 | Checkbox component **label text is dark grey**; should match the rest of the app | DONE |
| 7.2 | **Trim IN** — left-side flex container to 50% width, to make room for the scrap reason rows | DONE (Trim OUT, not Trim IN - see below) |

---

## Context worth carrying forward

- **Audit merges from Designer-edited branches.** Four defects on 2026-08-19 traced
  to one merge (`56af3f84`), all from Designer saves silently dropping structure:
  a `script-python` module in MPP shadowing Core, four dropped `custom.*` bindings
  on AssemblyNonSerialized, a missing `paramDirection` on `CavityLotRow`, and six
  missing `ScrapQty` blur handlers. Diff *structure* (propConfig key sets, param
  directions, `events` blocks) against `main` — and check sub-views, not just the
  screen being reported.
- **AD elevation wants a re-test.** The AppUser shadow's `elevate` ran stale code
  and failed silently. Fixed in `54fffbcd`, not re-verified.
- **Known-open, pre-existing:** `sql/tests/0022_PlantFloor_DieCast/070_Lot_GetLatestForToolCavity.sql`
  errors out (stale fixture, 2026-07-06 eligibility-tier decision);
  `ia.display.inline-frame` not registered on the gateway; `var(--mpp-accent)`
  referenced by 11 MPP_Config views but never defined; `sql_best_practices_mes.md`
  omits `JSON_QUERY` in its resolved-FK example that 82 procs use;
  `MachiningEntry/ScrapLineRow` still the pre-refactor twin of the Trim row.


---

## Session addendum — 2026-08-19 (work done, and what it surfaced)

**Corrections to the "known-open" list above:** the stale-fixture failure is NOT
only `070_Lot_GetLatestForToolCavity`. `sql/tests/0022_PlantFloor_DieCast/030`,
`040` and `050` fail identically (`ToolAssignment.CellLocationId` NULL, because
`Parts.v_EffectiveItemLocation` returns no `Source='Direct'` Cell row after the
2026-07-06 eligibility-tier decision), as does `0020/040_Lot_Create`. All are
pre-existing and make the runner exit 1 while assertion counts stay green.

**Decisions now waiting on Hunter:**
1. **3.2 shot count** — the fix contradicts `docs/superpowers/specs/2026-08-04-tool-shot-count-design.md`
   line 44 ("Shot-loss path | Does **not** increment | ... would double-count").
   That holds only if the operator's typed gross already includes shot-loss
   cycles. If gross is read off the machine counter, the fix double-counts and
   should be reverted rather than patched.
2. **3.1 defect codes** — filtering works (72 = 59 Die Cast + 13 plant-wide). The
   13 "plant-wide" codes are misclassified: dowel pin / baffle plate / NG bolt /
   supply-part codes are Assembly; 201-205 and 225 are logistics. Fix belongs in
   `sql/seeds/030_seed_defect_codes.sql`, not in the query.
3. **4.3 AD** — verified: the gateway has three user sources (`MPP`, `default`,
   `opcua-module`), ALL `type: INTERNAL`, and no AD identity provider. Repointing
   at an AD source name today would deny every elevation. MPP IT must create the
   source first; then `_ELEVATION_USER_SOURCE` is a one-line change.
   Related: "supervisor" currently means "any active AppUser whose password
   validates" - there is no role check anywhere, and `admin1` (the only AD-linked
   dev user) has `IgnitionRole` NULL, so a role gate would lock dev out.
4. **5.1 LTT** — set to accept **8 OR 9** digits rather than 8-only, because the
   9-digit rule traces to a verbal note (FRS 2.2.1 states no digit count) and
   narrowing would orphan every existing 9-digit LotName. Tightening later is a
   one-line edit. AIM shipper serials stay 9 — that is a separate, verified
   contract.
5. **5.3 count rectification** — deliberately NOT elevation-gated; peer to 4.1 and
   arguably deserves the same treatment. Hunter's call.
6. **7.2** — Trim IN has no scrap block; the scrap grid is on Trim **OUT**, which is
   what was widened (500px -> 50%, 3 -> 5 tiles/row). Confirm this was the intent.

**Deliberate non-changes worth preserving:**
- `Workorder.RejectEvent` gets NO `LocationId` FK — five other procs write that
  table and would leave it NULL. Scrap-by-area reporting needs one migration that
  backfills all five writers together.
- Released lots are filtered out of Record Shift Output in the read layer, not in
  `DieCast_GetShiftOutputBreakdown` — the proc's contract is "one row per LOT open
  at any point in the shift" and the 0045 suite asserts released rows are present.

**Small pre-existing bugs found in passing:** `LotDetail.reprintLabel` read a
non-existent `view.custom.lotId` (AttributeError on every press) - fixed;
`BlueRidge/Lots/Lot/code.py:331` has a Windows-style backslash inside a named-query
path (`"lots\Lot_GetLinkedContainer"`) which Python treats as a literal backslash
and which works only by accident - NOT fixed.

**OI-38 is now the project's highest-value open issue.** The shift subsystem stores
`Oee.Shift.ActualStart/ActualEnd` in LOCAL Eastern while everything around it is
UTC. That single mismatch produced SIX defects, found 2026-08-19:

| where | effect |
|---|---|
| `Oee.EndOfShiftEntry_Submit` | wrote local shift start into the UTC `DowntimeEvent.StartedAt` - every break/lunch event stamped 4-5 h early. **Corrupted stored data.** |
| `Oee.DowntimeEvent_RecordHistorical` | compared a UTC instant against local shift bounds - routinely stamped the FOLLOWING shift's id. **Corrupted stored data.** |
| Downtime Report `data.bin` | double-converted an already-local value: printed "2:00 AM - 2:00 AM" instead of "6:00 AM - 2:30 PM" |
| same | `COALESCE(ActualEnd, ActualStart)` made an open shift print a zero-length window |
| `reports/Shift_ListForPicker` | same double-conversion; any shift starting 00:00-04:00 labelled with the previous day |
| `Downtime by Date Range` | filtered UTC `StartedAt` with local date-picker params - whole window off by the offset |

All six fixed. **The CLASS stays open until the shift subsystem moves to UTC.**
Two more suspects found but NOT touched (outside that agent's lane):
`Workorder.DieCast_GetShiftOutputBreakdown` and `Lots.Lot_GetShiftCavityTally`
both mix the two bases.

Also note `Oee.Shift_GetAvailability` was specified in the Phase 8 plan and had
**never been built** - there was no planned-time or availability figure anywhere in
the system. It now exists and is override-aware.

**DST is explicitly NOT solved.** Override windows are wall-clock, so a window
spanning a transition is off by 60 min - MPP's real exposure is the Sat 23:00 ->
Sun 07:00 third shift on two Sundays a year (~12.5% availability skew for that
shift). Fixing it properly means the OI-38 UTC migration.

**3.4 scope decision (Hunter, 2026-08-19): no cavity-name -> part auto-assignment.**
The operator selects the part on every row. The rule was unknowable from the data
anyway - only DC-03 carries cavity descriptions in Dev and they are `test` / `yest`,
so there was no convention to infer. Each row's dropdown reuses the existing
die-cast-route-items-eligible-at-the-active-cell binding rather than a second
resolution path. If MPP later states a real naming convention, the pre-fill can be
added on top without reshaping the screen.

That leaves **partial submission** (open 3 of 5, leave the rest untouched, per-row
results) and **duplicate-LTT rejection before any write** as the two behaviours that
decide whether this feature is worth shipping.

---

## Shift attribution built 2026-08-19 — two findings that outlive it

**1. `Oee.Shift.ActualStart` is written in TWO DIFFERENT TIME BASES.** OI-38 is
recorded as "Oee.Shift is local Eastern". It is local *sometimes*:

| proc | writes |
|---|---|
| `Oee.Shift_Reconcile` (the boundary engine, the normal path) | `ISNULL(@NowLocal, SYSDATETIME())` — **local**, commented "LOCAL, deliberately" |
| `Oee.Shift_Start` | `ISNULL(@ActualStart, SYSUTCDATETIME())` — **UTC**, header says "defaults to now (UTC)" |

Everything downstream reads it as local: `Shift_GetAvailability` takes
`BusinessDate = CAST(s.ActualStart AS DATE)` with no conversion, the Downtime Report
prints it, and the new `Oee.ufn_ShiftIdForInstant` resolves against it. **A shift
started manually through `Shift_Start` therefore maps its business date 4-5 hours
wrong**, and every consumer inherits that. Pre-existing debt, not introduced by the
attribution work, but the resolver now depends on the local reading being true.
This widens OI-38 from "one table is local" to "one COLUMN is inconsistently based".

**2. OI-4 as originally written was unimplementable.** "Reject an override that would
leave a gap or overlap", evaluated on post-change state, deadlocks: the first
override of a pair is always non-contiguous with its neighbour, so both halves
reject and no override can ever be created. What was built instead, and is better:

- **Override-vs-global overlap is ACCEPTED**, resolved by override PRECEDENCE in the
  resolver. D1's "Second effectively starts at 16:00 for that press" falls out of a
  single override row as a derived consequence, instead of requiring the operator to
  author a second row.
- **Override-vs-override overlap is REJECTED** — the one ambiguity precedence cannot
  break.
- **Gaps reject as a DELTA**, not an absolute: only newly-opened uncovered minutes
  reject, so a plant whose schedules already fail to tile the day is not blocked from
  every override by a pre-existing hole.
- **Deprecate is not validated** — reverting to the plant baseline cannot open a hole
  the plant does not already have.

Strict literal OI-4 would need a batch editor authoring both halves in one
transaction. That is a UI change, not a proc change.

**Restamp scope is wider than the design's "two shifts either side"** — it is
`[BusinessDate-1 00:00, BusinessDate+2 00:00)` local for the one press, because an
edit can move either boundary in either direction and a midnight-crossing shift
extended past midnight reaches into the next calendar day. Safe at any width because
the resolver is total and a row already correct is not rewritten. Documented in the
proc header.

---

## Gross shots made additive 2026-08-19 — knock-on items

Operators count shots **since their last entry**, not off a climbing machine
counter (Hunter, 2026-08-19). `DieCast_GetShiftOutputBreakdown` no longer subtracts
prior claims. Consequences that are NOT yet actioned:

**1. The peer-terminal guard is now a false positive.** `DieCastBody.submitShiftOutput`
(backlog 3.3) re-reads the breakdown and refuses to submit if any lot's
`PriorGoodThisShift` moved since Compute, because under the cumulative model a peer's
recording changed this terminal's proposed split. Under the additive model it does
not — this terminal's count is its own. The guard now blocks a legitimate independent
entry and forces a recompute returning identical numbers. Not data-destructive, but
it should be narrowed or dropped.

**2. The shot-loss decision needs closing.** `2026-08-04-tool-shot-count-design.md`
line 44 says the shot-loss path must not increment ShotCount "because gross already
counts those cycles". That rationale is void — it only holds for a machine counter
that ticks on every cycle including spoiled ones. So the `registerShotLoss` fix in
`e9b1c61c` is consistent with the additive model. **Residual field-convention
question for MPP:** if an operator counts total cycles for the entry and THEN
registers some as shot loss, `e9b1c61c` double-counts those. Confirm the typed count
excludes cycles already registered as loss, and update the design-doc row either way
— its stated rationale no longer supports its conclusion.

**3. Docs now stale on this point** (not edited):
- `2026-07-28-diecast-per-cavity-lifecycle-design.md` §3.2 — "entered **once**"
- `docs/fat/areas/die-cast.csv` FAT-DC-050 — "gross shot count ... **for the shift**"
  will mislead a tester
- `2026-08-04-tool-shot-count-design.md` — the "What a shot is" and "Shot-loss path" rows

**Verified unaffected:** `Lots.Lot_GetShiftCavityTally` (derives shots from PieceCount,
never gross) and `Workorder.DieCastSupervisor_GetShiftTotals` (sums PieceDelta).

**Correction to an earlier entry in this note:** the four `0022_PlantFloor_DieCast`
fixtures (030/040/050/070) are STILL broken. An agent reported mid-session that they
had been fixed; that was wrong — a controlled A/B (stash the work, re-run at HEAD)
produced a byte-identical error list. Root cause unchanged: `Msg 515`, NULL
`ToolAssignment.CellLocationId`, because the fixture's cell lookup resolves to
nothing on a clean reset.
