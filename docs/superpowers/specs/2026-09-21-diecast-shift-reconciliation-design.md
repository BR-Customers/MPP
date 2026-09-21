# Die Cast Shift Reconciliation -- Design Spec

**Date:** 2026-09-21
**Status:** Design, awaiting Jacques's review
**Migration:** next free number at build time (`0096` when written -- re-check; the part-type
recategorization release may claim it first)
**Mockup:** `mockup/diecast_shift_reconciliation_mock.html`
**Evidence:** `sql/scratch/2026-09-21_diecast_on_record_window.sql` + `sql/scratch/Run-DieCastOnRecord.ps1`
(read-only), run against `MPP_MES_Prod` 2026-09-21 12:57, held against the DCFM-2076 press sheets.
**Builds on:** `2026-09-14-diecast-quantity-and-scrap-model-design.md` (cavity scrap, reconciliation
identity), `2026-09-09-diecast-shot-reading-chain-design.md` (watermarks),
`2026-08-19-shift-override-attribution-design.md` (the restamp precedent).
**Earlier decision:** `notes/2026-09-17_shift-reconciliation-backfill-trim-followup.md` (approach A,
supervisor-attributed, reusable for Trim).

---

## 1. Why

Building 2 die cast could not enter LOTs on the night of 2026-09-16. The paperwork was complete;
the MES had no way to take a past shift. That was the trigger. A week of prod records held against
the paper shows it is not a one-off, and that "missing" is only one of three failures.

**Machine 11, die asset # `DMO125`, sheet dated 2026-09-17:**

| Sheet column | Sheet | MES |
|---|---|---|
| 3rd (Tamara) | 991 shots, 953/tag = 11,436 good, 35 warm-up shots, 36 no-good (code 8, All) | All of it, exactly -- entered 09-17 09:35 by BH. **Filed under 1st shift.** |
| 1st (Brittany) | 1,121 shots, 1,080/tag = 12,960 good, 38 warm-up, 36 no-good | **Nothing.** No credit, no scrap, no reading. Not keyed through cutover either. |
| 2nd (KC/Tamara) | 732 shots, 711/tag = 8,532 good, 25 warm-up, 0 no-good | Quantity exact, right shift. Reading recorded 726 (sheet 732); warm-up 15 shots (sheet 25). |

The mis-filed entry is the pre-2026-09-18 shift-picker defect (the screen preselected the current
shift). The 09-18 release stops new ones; it did not correct the rows already written.

**Machine 202, die asset # `DM0144` (6FB Oil Pan D):** of the 14 tags on the sheet, **2 exist in the MES**.
All 33 credits in the week came through basket release with a count and **no counter reading**; no
shift-end number was entered on Machine 202 all week. Releases from 22:31 on 09-17 to 06:54 on 09-18
are filed under 09-17 **1st** shift -- a whole night. Everything after the 09-18 release is filed
correctly.

So there are three failures, and the screen must fix all three, end to end:

1. **A shift, or part of one, is missing.**
2. **Recorded production is filed against the wrong shift.**
3. **Recorded numbers differ from the sheet** while the entry itself exists.

**The 99 cutover-keyed baskets are unrelated.** Their cast dates run May through early September,
59 are on `DMO124` (not mounted), and they were keyed in three sittings on 09-15. That is genuine
cutover stock-taking, not a workaround for missed shifts.

---

## 2. Decisions locked

| # | Decision |
|---|---|
| D1 | The unit of work is **one shift x one press x one die** -- one column of the sheet. |
| D2 | **Approach A.** Reuse the existing writers rather than write a parallel backfill path. Shared writes are extracted into internal worker procs (the `Oee.ShiftOverride_Restamp` pattern) that the live procs and the reconciliation both call (§5.1). |
| D3 | **The production record is always written and must be right.** The basket count follows a three-state rule (§3.3). Once a basket is counted downstream, **trim's number goes forward** and the count is locked. **Firm lock -- no override on this screen.** The LOT Detail count panel remains the one place to change such a count. |
| D4 | A basket created retroactively is **released to default storage**, exactly as the live release path does. |
| D5 | Die life: backfilled production **advances** it; re-filing and count corrections **do not**. |
| D6 | Basket release with a count and no reading is **unchanged**. A shift left without its shift-end number is operator failure; it is **surfaced on the supervisor dashboard**, not built around. |
| D7 | Every reconciliation writes a **header row**; every row it produces references it. The header is the late-entry marker, the audit anchor, and what clears the dashboard signal. |
| D8 | **Shop floor, one AD sign-in per session** (`Common.Session.beginElevatedWindow`). Any active AD-mapped user until AD roles land -- the shipping-label-reprint stance. |
| D9 | **Layout A: sheet-shaped.** Totals block, reject block, then the tag list grouped by part, in the paper's order. |
| D10 | Reject rows gain **Approved by** -- the sheet's QAS column -- as `RejectEvent.ApprovedByUserId`, a FK to `Location.AppUser`, picked by initials or name. |
| D11 | **One Save, one transaction, fixed order:** moves, then new baskets, then credits and scrap, then count corrections (§3.5). |
| D12 | Backfilled rows are stamped **at the end of their shift**; the header keeps the real time of entry. |
| D13 | **Save closes every gap, in whichever direction** -- compensating rows for decreases (§3.6). *Decided while writing this spec; flagged for review.* |
| D14 | **Every critical decision is named on screen and confirmed before it is written** (§7). Team leads succeed by default; a mistake needs two deliberate acts. |
| D15 | A shift that changes after the team lead opens it refuses to save (stale guard) and reloads. |

---

## 3. The model

### 3.1 What the screen compares

For the chosen shift x press x die the screen loads **everything on record** and lays it beside
**what the team lead types from the sheet**, field for field:

| Level | Recorded (from) | Sheet (typed) |
|---|---|---|
| Shift | Total shots = max counter reading in the shift (`DieCastContribution.ShotCounterReading`, anchor-aware via `ufn_DieShotWatermark`); warm-up shots = `999` rows / active cavities; test/no-good = reject rows | Total shots, Good shots, Warm-up shots |
| Reject block | `RejectEvent` rows for the shift x press x die, by code and part | QAS (approved by), Reason, Part (or All), Amt |
| Tag list | Per tag: `SUM(PieceDelta)` credited **in this shift** | Tag #, Cav, Qty |

No-good pieces and Total good pieces are **computed** from the reject block and the tag list -- the
same arithmetic the sheet does by hand -- so a mismatch between them and the typed totals is a typo
and is shown as one before save (§7.4).

### 3.2 Watermarks are shift-scoped -- which is what makes backfill safe

`Workorder.ufn_CavityShotWatermark` and `ufn_DieShotWatermark` are scoped to **shift and press**:
each shift starts at 0 and the reading entered is that shift's total shots (hence the sheet's
"Total Shots" box equals the recorded reading). **Backfilling one shift cannot disturb any other
shift's arithmetic.**

Re-filing changes which shift a reading belongs to, so it changes both shifts' watermarks. Recorded
credits are facts and are **not recomputed**. A later backfill into either shift computes from the
new watermark, and that is visible on screen as the proposed figure, never silent.

### 3.3 The basket count -- three states

| Basket state | Count |
|---|---|
| **Open** at the press | Credited normally, as the live path would have. |
| **Released**, nothing downstream | Corrected, with the header's reason, through the count-correction worker (§5.1). |
| **Counted downstream** | **Left alone.** The row says why: *"Counted at Trim OUT 09-18 14:02 -- count stands."* The production record is still written in full. |

"Counted downstream" is derived from what is stored, never asked:

- a `Workorder.ProductionEvent` on the LOT whose template's `OperationType` is not `DieCast`;
- a `Lots.LotAttributeChange` on `PieceCount` after the LOT's release;
- status `Closed`, or the LOT consumed (genealogy child exists).

This is the rule Jacques set: *at trim a total count is put in, adjusting the LOT count, and that
number is what goes forward. Reconciling the count here is putting in the record of its creation.
If trim has already done their accounting, our entry needs to be accurate for shot count more than
for the parts in that LOT.*

`Lots.Lot_RectifyPieceCount` refuses `Open` LOTs; the three states line up with that -- open baskets
are credited, released ones corrected.

### 3.4 Die life

| Action | `Tools.Tool.ShotCount` |
|---|---|
| Backfilled production | `+ (sheet total shots - die watermark for the shift)`, the live arithmetic |
| Decrease (§3.6) | `- (die watermark - sheet total shots)`, under the same row lock |
| Re-file | unchanged -- the shots were counted when first entered |
| Count correction | unchanged -- pieces are not shots |

The header shows die life before and after. A die whose lifetime total is wrong for unrelated
reasons is `Tools.Tool_CorrectShotCount`'s job (Config Tool), not this screen's.

### 3.5 Save order

One transaction, in this order, because the watermark is per shift:

1. **Moves** -- restamp the selected rows to their new shift.
2. **New baskets** -- mint, then (at the end of the transaction) release to default storage.
3. **Credits and scrap** -- written against the shift, computed from the post-move watermark.
4. **Count corrections** -- on released, not-counted-downstream baskets the team lead accepted.

On Machine 11 this is the difference between 1st shift gaining 1,121 shots (move first) and 130
(move last).

### 3.6 Decreases -- compensating rows (D13, for review)

The evidence so far needed only increases. But a reconciliation must be correctable -- a typo of
10800 for 1080 cannot become permanent -- and "end to end" means the gap closes whichever way it
points. Rows are never edited or deleted; a decrease is a **compensating row carrying the
reconciliation id**:

| Quantity | Decrease written as |
|---|---|
| Pieces credited to a tag | `DieCastContribution` with negative `PieceDelta`. `CK_DieCastContribution_DeltaNonNeg` becomes `PieceDelta >= 0 OR ReconciliationId IS NOT NULL` -- live paths still cannot write a negative. |
| Scrap / warm-up | `RejectEvent` with negative `Quantity` and the reconciliation id. Every reject report SUMs, so it nets; the Transaction Detail shows the correction as its own row, which is honest. |
| Counter reading | `DieCastCounterAnchor` at the sheet figure. The anchor already discards earlier readings in the shift (`ufn_DieShotWatermark`: MAX over the anchor and readings *after* it), so it is the existing way to lower a watermark. |
| Basket count | The count-correction worker, subject to §3.3's lock. |

Voiding rows instead was considered and rejected: every reader (watermarks, breakdown, six reject
reports, LOT history) would have to learn to skip them.

### 3.7 What an "entry" is

Nothing stored identifies one submission: `DieCastShiftOutput_Record` calls `SYSUTCDATETIME()` per
statement, so one entry's rows differ by milliseconds. The screen **groups for display** -- same
shift, press, user, terminal, within 10 seconds -- and every move carries **explicit row ids**. The
confirmation lists exactly what moves (§7.3). The grouping can be wrong without the write being
wrong.

---

## 4. Schema

All additive, nullable, no defaults -- metadata-only on the partitioned `RejectEvent` (no rebuild,
none of `0084`'s §4.3 cost).

### 4.1 `Workorder.DieCastShiftReconciliation` -- new

| Column | Type | |
|---|---|---|
| `Id` | `BIGINT IDENTITY` PK | |
| `ShiftId` | `BIGINT NOT NULL` FK `Oee.Shift` | the shift reconciled |
| `CellLocationId` | `BIGINT NOT NULL` FK `Location.Location` | the press |
| `ToolId` | `BIGINT NOT NULL` FK `Tools.Tool` | the die |
| `ReasonId` | `BIGINT NOT NULL` FK `Workorder.DieCastReconciliationReason` | |
| `Note` | `NVARCHAR(500) NULL` | required when the reason says so |
| `SheetTotalShots` / `SheetGoodShots` / `SheetWarmUpShots` | `INT NULL` | what the team lead typed, kept as typed |
| `DieShotCountBefore` / `DieShotCountAfter` | `INT NOT NULL` | die life either side |
| `AppUserId` | `BIGINT NOT NULL` FK `Location.AppUser` | the signed-in team lead |
| `TerminalLocationId` | `BIGINT NULL` | |
| `CreatedAt` | `DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME()` | the real time of entry (D12) |

Index `(ShiftId, CellLocationId)`. Unpartitioned: a handful of rows a day.

### 4.2 `Workorder.DieCastReconciliationReason` -- new code table

Shaped like `DieCastVarianceReason` (`RequiresNote`):

| Code | Name | RequiresNote |
|---|---|---|
| `MissedEntry` | Shift not entered | 0 |
| `WrongShift` | Entered against the wrong shift | 0 |
| `WrongNumbers` | Entered numbers did not match the sheet | 0 |
| `Other` | Other | 1 |

A reconciliation that does several things picks the one that prompted it; the rows show the rest.

### 4.3 `Workorder.DieCastReconciliationMove` -- new

One row per moved row: `Id`, `ReconciliationId` FK, `EntityType` (`Contribution` / `Reject` /
`Anchor`, code-table backed via `Audit.LogEntityType`), `EntityId`, `FromShiftId`, `ToShiftId`.
The restamp itself writes the new `ShiftId` in place -- the `ShiftOverride_Restamp` precedent --
and this table is the durable record of where it was.

### 4.4 Columns on existing tables

| Table | Column | |
|---|---|---|
| `Workorder.DieCastContribution` | `ReconciliationId BIGINT NULL` FK | rows a reconciliation wrote |
| `Workorder.DieCastContribution` | CHECK relaxed | `PieceDelta >= 0 OR ReconciliationId IS NOT NULL` (§3.6) |
| `Workorder.RejectEvent` | `ReconciliationId BIGINT NULL` FK | |
| `Workorder.RejectEvent` | `ApprovedByUserId BIGINT NULL` FK `Location.AppUser` | D10 -- the sheet's QAS. The live Reconcile Shift screen can adopt it later. |
| `Workorder.DieCastCounterAnchor` | `ReconciliationId BIGINT NULL` FK | |

Count corrections land in `Lots.LotAttributeChange` exactly as `Lot_RectifyPieceCount` writes them,
with `Reason = 'Shift reconciliation #<id>: <reason name>'` and the id in the `LotUpdated` audit
`NewValue` JSON. `LotAttributeChange` is generic and does not get a die-cast column.

---

## 5. Stored procedures

### 5.1 Workers extracted from the live procs (D2)

The reconciliation must be one transaction (D11), and a status-row proc cannot `EXEC` another
(CLAUDE.md, INSERT-EXEC rule). The resolution is the one `Oee.ShiftOverride_Restamp` already uses:
**internal workers that emit no result set and own no transaction**. Each live proc becomes a thin
wrapper -- validation, then the worker -- and the reconciliation calls the same workers.

| Worker | Extracted from | Guards that stay in the live wrapper only |
|---|---|---|
| `Workorder.DieCastCredit_Write` | `DieCastShiftOutput_Record` (contribution + PieceCount + ShotCount) | reading behind the die watermark; pieces onto a closed basket |
| `Workorder.DieCastScrap_Write` | `DieCastShiftOutput_Record` (cavity + die-wide fan-out) | -- |
| `Lots.DieCastLot_Mint` | `DieCastLot_Open` | die mounted *now*; one open basket per cavity |
| `Lots.DieCastLot_ReleaseMove` | `DieCastLot_Release` (Open -> Good, move to storage) | -- |
| `Lots.Lot_ApplyPieceCountCorrection` | `Lot_RectifyPieceCount` | -- (the `Open` refusal stays in both) |
| `Workorder.DieCastEntry_Restamp` | new; modelled on `Oee.ShiftOverride_Restamp` | -- |

**The live procs must behave byte-identically after extraction.** The existing
`0022_PlantFloor_DieCast` suite, `0070` rectify tests and `090_ReleasePreview` are the regression
gate, run green before and after (§11).

The guards that "stay in the live wrapper only" are the whole point: they encode *now* (mounted die,
monotonic readings as they are typed) and are wrong for a past shift. The reconciliation proc
replaces them with its own guards (§5.2), not with nothing.

### 5.2 `Workorder.DieCastShiftReconciliation_Save` -- new, status row

```
@ShiftId, @CellLocationId, @ToolId, @ReasonId, @Note,
@SheetJson        -- {totalShots, goodShots, warmUpShots}
@MovesJson        -- [{entityType, entityId, toShiftId}]
@TagsJson         -- [{lotId|null, lotName, toolCavityId, quantity}]   (sheet qty per tag)
@RejectsJson      -- [{defectCodeId, itemId|null (null = All), quantity, approvedByUserId}]
@CountsJson       -- [{lotId}]  released baskets whose count the team lead accepted
@LoadedStamp      -- stale guard: MAX row id / EventAt the screen loaded (§8)
@AppUserId, @TerminalLocationId
```

Pre-transaction validation (every rejection is a status row, no open transaction -- Msg 3915 rule):
AppUser exists; shift is **closed** (a reconciliation never targets the open shift -- the live
screen owns it); the die was mounted on the press during the shift (`Tools.ToolAssignment`
overlap); reason exists, note when required; every move targets a closed shift within +/-2 of the
source and moves a row belonging to this shift x press x die; every tag either resolves to a LOT of
**this die and cavity** or is a valid unused LTT (`Lots.ufn_IsValidExternalLtt`) -- a tag that
belongs elsewhere is refused *naming where it belongs*; every count correction is on a
released, not-counted-downstream LOT; the stale stamp matches.

Then one transaction: header row -> moves -> mint -> credits/scrap (increases and compensating
decreases) -> anchor if the reading drops -> release new baskets -> count corrections -> audit. The
proc **computes the deltas itself** from recorded vs sheet; the JSON carries what the sheet says,
never a delta. That keeps the arithmetic in SQL (no business logic in Python) and makes a re-run
after any partial success a no-op for what already landed.

### 5.3 Reads -- new

| Proc | Returns |
|---|---|
| `Workorder.DieCastShiftReconciliation_ListShifts(@CellLocationId, @Days)` | Landing list: per shift x die mounted, entries, good recorded, max reading, status (`NoEntry` / `EntryRecorded` / `ReleasedNoShiftEnd` / `Reconciled`) |
| `Workorder.DieCastShiftReconciliation_Load(@ShiftId, @CellLocationId, @ToolId)` | One row per recorded fact for the shift x press x die: entries (grouped, with row ids), tags with credited-in-shift, basket state + lock reason, reject rows, shift totals, die life, stale stamp. One result set, discriminated by a `RowKind` column. |
| `Workorder.DieCastShift_ListUnreconciled(@Days)` | Dashboard: shift x press with production recorded but **no counter reading and no reconciliation header** |
| `Workorder.DieCastReconciliationReason_List` | Code table |

All ET at the boundary except `Oee.Shift` times, which are already Eastern (OI-38).

---

## 6. Screens

Route `/shop-floor/die-cast/reconcile`, view `BlueRidge/Views/ShopFloor/DieCastReconcile` (MPP).
Reached from the supervisor dashboard tile and the die cast supervisor page. Opening it requires the
AD sign-in (§7.1).

**A die is identified by its Asset Number** -- `Tools.Tool.Code`, which MPP calls the asset number
and which the Tools screen has labelled *Asset Number* since the 2026-09-10 punch list (no second
field exists). Everywhere this screen names a die it shows the die's **name first and its asset
number second** (*6MA IN 2,3,4 EX 2,3,4 D · Asset # DMO125*), the same order the Tools list uses.
The word "code" never reaches the operator.

### 6.1 Landing

Press dropdown, then the last 7 days of shifts for that press -- one row per shift x die mounted.
Columns: Shift, Die asset #, Entries, Good recorded, Reading, Status. **Status is neutral where the MES
cannot know better** ("No entry" -- the press may not have run) and **amber only for a positive
finding** ("Released, no shift-end number"). Reconciled shifts read *Reconciled -- JGP 09-21* and
reopen normally.

### 6.2 The reconciliation (layout A)

- **Shift banner** -- the shift in the same large, warning-coloured form as `DieCastShiftConfirm`
  (*09-17 1ST SHIFT -- 07:00-15:00*), with press, die name and asset number, and die life before ->
  after. Always visible.
- **Reason** dropdown (+ note when required).
- **Entries on record** -- one card per grouped entry: time, who, reading, credits, scrap. Each
  card states **entered during** vs **filed under**; where they differ it carries an amber chip.
  That catches Machine 202's night filed as 1st; it does *not* catch Machine 11's 09:35 entry
  (entered during 1st, belonging to 3rd), which is why the card also shows its reading and totals
  for the team lead to match against the paper.
- **Totals block** -- Recorded | Sheet | Gap for Total shots, Good shots, Warm-up shots, No-good
  pieces, Total good pieces.
- **Reject block** -- QAS (Approved by), Reason, Part (All or one), Amt, with recorded rows beside.
- **Tag list** -- grouped by part in the sheet's order (part name, Macola #, sub-total): Tag #, Cav,
  Sheet qty, Recorded, Basket state, Count before -> after. A `+ tag` row adds a basket.
- **Footer** -- Discard, Review & Save.

### 6.3 Supervisor dashboard tile

**Shifts not reconciled** -- count, amber when non-zero, tap -> the landing list filtered to
flagged shifts. The dashboard's own redesign stays the separate open TODO (PROJECT_STATUS).

---

## 7. Critical decisions and confirmations (D14)

The team lead is not a daily user of this screen, is reconciling someone else's shift from paper,
and every write lands in Honda traceability and die life. The screen therefore **names each
consequential decision where it is made, and confirms it before anything is written.**

### 7.1 Sign-in -- who is responsible

AD credential popup. On success the banner reads *Reconciling as Jacques Potgieter (JGP). Everything
saved here is recorded under your name.* The elevation window is renewed on activity so a long
reconciliation does not expire mid-sheet.

### 7.2 Choosing the shift -- the historic failure

The wrong-shift defect is the reason half this screen exists, so the shift is never implicit:

- the landing list has no preselected row;
- the banner shows the shift in large type on every screen after;
- the Save confirmation repeats it at the top, in the same large type, and the confirm button
  itself names it: **SAVE 09-17 1ST SHIFT**.

### 7.3 Moving an entry

Popup: the entry's facts; **From** and **To** as large shift names with each shift's good total
before and after; the explicit statement *Shots, pieces, baskets and die life do not change -- only
which shift is credited*; the row count that moves. Target limited to +/-2 closed shifts. Confirm
button: **MOVE TO 09-16 3RD SHIFT**. Moves are staged on screen (the card shows *Moving to 09-16
3rd*, undoable) and written only at Save.

### 7.4 Before Save -- blocking checks, in plain words

Save stays disabled, and says why, until:

- the reason is set (and its note, if required);
- **the tag list adds up to Total good pieces**, and Good shots x cavities - no-good = Total good --
  *"Tag list totals 11,880; Total good says 12,960. One of them has a typo."*;
- every tag resolves (no unknown / foreign tags);
- no per-tag quantity exceeds that cavity's shots for the shift -- a typo guard (10800 for 1080).

These are the sheet's own arithmetic. They block because a failure is always a typing error, never
a plant condition -- unlike variance on the live screen, which is allowed to mean "we do not know".

### 7.5 The Save confirmation -- what will change

A full-width popup, the shift in large type at the top, then **only the groups that have content**,
each in plain sentences with numbers:

| Group | Example |
|---|---|
| Entries moved | *1 entry (24 rows) moves from 09-17 1st to 09-16 3rd.* |
| Production added | *12,960 good pieces credited to 12 tags. 456 warm-up and 36 test pieces recorded.* |
| Production reduced | *(amber)* *72 pieces removed from 10628131 (a correction).* |
| New baskets | *2 baskets created and released to Warehouse: 10628574, 10628575.* |
| Basket counts changed | *6 released baskets: 10628131 1,788 -> 2,868, ...* |
| Counts left standing | *(grey)* *10628125 was counted at Trim OUT on 09-18 -- its count stands; its production is still recorded.* |
| Die life | *Asset # DMO125 (6MA IN 2,3,4 EX 2,3,4 D): 15,699 -> 16,820 (+1,121 shots).* |

Anything that **reduces** production, die life, or a count is amber and needs its own tick box
(*I have checked this reduction against the sheet*) before the confirm button enables. Additions do
not -- they are the normal case, and friction on the normal case trains people to click through.

### 7.6 After Save

A result panel: what was written, the reconciliation number, and **Back to shifts**, where the row
now reads *Reconciled -- JGP*. Discard with unsaved changes uses the existing `ConfirmUnsaved` popup.

---

## 8. Edge cases

- **Stale data.** `@LoadedStamp` is the highest contribution / reject / anchor id for the shift x
  press x die when loaded. Anything newer refuses the save: *"This shift changed since you opened
  it -- reloading."* (`Tool_CorrectShotCount`'s guard.)
- **Die changed mid-shift.** Each die is its own landing row and its own reconciliation.
- **Tag belongs elsewhere.** Refused with where it belongs (*"10628578 is 6FB / DM0144 cavity a"*).
- **Cutover-keyed tag.** An existing basket like any other; §3.3 applies.
- **Unmapped cavity.** Part NULL, allowed (0084 §4.1); reports bucket it *(unassigned part)*.
- **Open shift.** Not offered. The live screen owns the current shift.
- **Reconciling twice.** Allowed. The second compares against everything including the first, so
  it writes only the remaining gap.
- **Anchor in the shift.** Backfilled rows are stamped at shift end (D12), so they sort after any
  anchor in the shift and count toward its watermark.

---

## 9. Recorded, not changed

- **Release with a count and no reading** does not move either watermark and does not advance die
  life (`DieCastLot_Release` lines 225-240: `MAX` ignores NULL; `ISNULL(@CounterReading,0) -
  watermark` is not positive). Jacques, 2026-09-21: *the shift is waiting on its shift-end number;
  failing to enter it is operator failure, not something to build around* -- hence §6.3.
- **Consequence to know about:** when that shift-end number is entered, the breakdown's proposal
  for the open basket is `reading - cavity watermark`
  (`DieCast_GetShiftOutputBreakdown` line 211), which ignores the reading-less releases, so it
  proposes the whole shift again. The good figure is editable and the variance shows the gap.
  Noted so it is known behaviour, not a surprise.

---

## 10. Out of scope

- **Trim.** Same shape later (`notes/2026-09-17_shift-reconciliation-backfill-trim-followup.md`).
  The header / reason / move / confirmation structure is written to be copied, not generalised now.
- **A submission id on live entries** (§3.7). Would make "an entry" exact going forward; not needed
  for this screen.
- **AD role gating.** Arrives with the AD roles; until then any AD-mapped user (D8).
- **Supervisor dashboard redesign.** Only the tile is added here.
- **Reject reports reading `ApprovedByUserId`.** The column lands; reports adopt it separately.

---

## 11. Verification

**Regression gate first.** Full SQL suite green on a throwaway DB *before* the worker extraction,
and again after -- the live procs must not change behaviour (§5.1).

**SQL tests** (`sql/tests/0022_PlantFloor_DieCast/` new files):

- each worker, called by its live wrapper, is behaviour-identical (existing fixtures, unchanged);
- save order: a move and a backfill in one save credit the full shift, not the remainder;
- the three basket states, including a locked basket whose production is still written;
- **no override**: a count correction on a counted-downstream LOT is refused;
- re-file leaves `ShotCount` and every `PieceCount` untouched;
- decreases: negative contribution only with a reconciliation id (live path still refused by the
  CHECK); negative scrap nets on `Reject_GetPartMatrix`; an anchor lowers the reading;
- tag collision named; unused LTT minted and released to default storage;
- stale stamp refuses; open shift refused; move outside +/-2 refused;
- re-running an identical save writes nothing but a header;
- `DieCastShift_ListUnreconciled` flags Machine-202-shaped data and clears on a header.

**Acceptance -- Jacques's sheet.** Restore prod to a local ProdSim DB. Reconcile Machine 11 09-16
3rd, 09-17 1st and 09-17 2nd from the DCFM-2076 sheet. Re-run
`sql/scratch/Run-DieCastOnRecord.ps1` against it. It must show: 09-16 3rd 11,436; 09-17 1st
12,960; 09-17 2nd 8,532 with reading 732 and 300 warm-up pieces; `DMO125` die life +1,121 (+6 for
the 2nd-shift reading); tags 10628131-134 at 2,868; and every Machine 202 shift flagged until
reconciled.

**Screens.** Live smoke on the Dev gateway with a real AD sign-in: each popup in §7, a blocked save
for each §7.4 check, a reduction needing its tick box.

## 12. Release

Touches prod data and the live die cast write path, so the full release contract applies
(`prod-release-context-pack/`): preview, rehearsal against live data, fingerprint-guarded execute,
scoped Core + MPP exports built from git, and a published runbook. The worker extraction is the
risky half; it ships with its regression evidence in the runbook.

## 13. For review

1. **D13 -- decreases as compensating rows**, including relaxing
   `CK_DieCastContribution_DeltaNonNeg` for reconciliation rows only. Decided while writing; not
   discussed.
2. **§5.1 -- worker extraction** touches the live die cast procs. It follows from D2 + D11 + the
   INSERT-EXEC rule, but it is a larger change to live code than "extend the existing writers" may
   have sounded.
3. **§7.4 -- the four blocking checks**, especially the per-tag shot ceiling.
