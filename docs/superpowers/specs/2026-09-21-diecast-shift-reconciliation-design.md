# Die Cast Shift Reconciliation -- Design Spec

**Date:** 2026-09-21
**Status:** Design -- review items settled with Jacques 2026-09-22 (§13)
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

**Language (Jacques, 2026-09-21).** On this screen and in this spec: an **LTT** is the LOT Tracking
Ticket number (the press sheet's *Tag #* column); a **LOT** is the record. "Tag" and "basket" are
not used. The typed column is **Actual**, compared against **Recorded**.

---

## 1. Why

Building 2 die cast could not enter LOTs on the night of 2026-09-16. The paperwork was complete;
the MES had no way to take a past shift. That was the trigger. A week of prod records held against
the paper shows it is not a one-off, and that "missing" is only one of three failures.

**Machine 11, die asset # `DMO125`, sheet dated 2026-09-17:**

| Sheet column | Sheet | MES |
|---|---|---|
| 3rd (Tamara) | 991 shots, 953/LOT = 11,436 good, 35 warm-up shots, 36 no-good (code 8, All) | All of it, exactly -- entered 09-17 09:35 by BH. **Filed under 1st shift.** |
| 1st (Brittany) | 1,121 shots, 1,080/LOT = 12,960 good, 38 warm-up, 36 no-good | **Nothing.** No credit, no scrap, no reading. Not keyed through cutover either. |
| 2nd (KC/Tamara) | 732 shots, 711/LOT = 8,532 good, 25 warm-up, 0 no-good | Quantity exact, right shift. Reading recorded 726 (sheet 732); warm-up 15 shots (sheet 25). |

The mis-filed entry is the pre-2026-09-18 shift-picker defect (the screen preselected the current
shift). The 09-18 release stops new ones; it did not correct the rows already written.

**Machine 202, die asset # `DM0144` (6FB Oil Pan D):** the legible press sheet lists LTTs
10628573-580; **four of them (10628574-577) do not exist in the MES** -- LOTs on paper and on
physical baskets, nowhere in the system. *(Two claims from earlier drafts are withdrawn: "12 of 14
LTTs missing" mixed numbers read from a second, illegible photo; and the absence of LTTs
10628556-572 says nothing, because LTTs come off a shared stack across the die building, not in
sequence per press -- see §6.3.)*
All 33 credits in the week came through LOT release with a count and **no counter reading**; no
shift-end number was entered on Machine 202 all week. Releases from 22:31 on 09-17 to 06:54 on 09-18
are filed under 09-17 **1st** shift -- a whole night. Everything after the 09-18 release is filed
correctly.

So there are three failures, and the screen must fix all three, end to end:

1. **A shift, or part of one, is missing.**
2. **Recorded production is filed against the wrong shift.**
3. **Recorded numbers differ from the sheet** while the entry itself exists.

**The 99 cutover-keyed LOTs are unrelated.** Their cast dates run May through early September,
59 are on `DMO124` (not mounted), and they were keyed in three sittings on 09-15. That is genuine
cutover stock-taking, not a workaround for missed shifts.

---

## 2. Decisions locked

| # | Decision |
|---|---|
| D1 | The unit of work is **one shift x one press x one die** -- one column of the sheet. |
| D2 | **Approach A.** Reuse the existing writers rather than write a parallel backfill path. Shared writes are extracted into internal worker procs (the `Oee.ShiftOverride_Restamp` pattern) that the live procs and the reconciliation both call (§5.1). |
| D3 | **The production record is always written and must be right.** The LOT count follows a three-state rule (§3.3). Once a LOT is counted downstream, **trim's number goes forward** and the count is locked. **Firm lock -- no override on this screen.** The LOT Detail count panel remains the one place to change such a count. |
| D4 | A LOT created retroactively is **released to default storage**, exactly as the live release path does. |
| D5 | Die life: backfilled production **advances** it; re-filing and count corrections **do not**. |
| D6 | LOT release with a count and no reading is **unchanged**. A shift left without its shift-end number is operator failure; it is **surfaced on the supervisor dashboard**, not built around. |
| D7 | Every reconciliation writes a **header row**; every row it produces references it. The header is the late-entry marker, the audit anchor, and what clears the dashboard signal. |
| D8 | **Shop floor, one AD sign-in per session** (`Common.Session.beginElevatedWindow`). Any active AD-mapped user until AD roles land -- the shipping-label-reprint stance. |
| D9 | **Layout A: sheet-shaped.** Totals block, reject block, then the LOT list grouped by part, in the paper's order. |
| D10 | Reject rows gain **Approved by** -- the sheet's QAS column -- as `RejectEvent.ApprovedByUserId`, a FK to `Location.AppUser`, picked by initials or name. |
| D11 | **One Save, one transaction, fixed order:** moves, then new LOTs, then credits and scrap, then count corrections (§3.5). |
| D12 | Backfilled rows are stamped **at the end of their shift**; the header keeps the real time of entry. |
| D13 | **Save closes every gap, in whichever direction** -- compensating rows for decreases (§3.6). Confirmed by Jacques 2026-09-22. |
| D14 | **Every critical decision is named on screen and confirmed before it is written** (§7). Team leads succeed by default; a mistake needs two deliberate acts. |
| D15 | A shift that changes after the team lead opens it refuses to save (stale guard) and reloads. |
| D16 | **A shift with nothing recorded is a first-class case.** The team lead scans or types the LTT off each physical LOT, with its cavity and quantity, and every LTT is resolved as it is entered (§6.3). |

---

## 3. The model

### 3.1 What the screen compares

For the chosen shift x press x die the screen loads **everything on record** and lays it beside
**what the team lead types from the sheet**, field for field:

| Level | Recorded (from) | Actual (typed from the press sheet) |
|---|---|---|
| Shift | Total shots = max counter reading in the shift (`DieCastContribution.ShotCounterReading`, anchor-aware via `ufn_DieShotWatermark`); warm-up shots = `999` rows / active cavities; test/no-good = reject rows | Total shots, Good shots, Warm-up shots |
| Reject block | `RejectEvent` rows for the shift x press x die, by code and part | QAS (approved by), Reason, Part (or All), Amt |
| LOT list | Per LOT: `SUM(PieceDelta)` credited **in this shift** | LTT, Cav, Qty |

No-good pieces and Total good pieces are **computed** from the reject block and the LOT list -- the
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

### 3.3 The LOT count -- three states

| LOT state | Count |
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

`Lots.Lot_RectifyPieceCount` refuses `Open` LOTs; the three states line up with that -- open LOTs
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
2. **New LOTs** -- mint, then (at the end of the transaction) release to default storage.
3. **Credits and scrap** -- written against the shift, computed from the post-move watermark.
4. **Count corrections** -- on released, not-counted-downstream LOTs the team lead accepted.

On Machine 11 this is the difference between 1st shift gaining 1,121 shots (move first) and 130
(move last).

### 3.6 Decreases -- compensating rows (D13)

The evidence so far needed only increases. But a reconciliation must be correctable -- a typo of
10800 for 1080 cannot become permanent -- and "end to end" means the gap closes whichever way it
points. Rows are never edited or deleted; a decrease is a **compensating row carrying the
reconciliation id**:

| Quantity | Decrease written as |
|---|---|
| Pieces credited to a LOT | `DieCastContribution` with negative `PieceDelta`. `CK_DieCastContribution_DeltaNonNeg` becomes `PieceDelta >= 0 OR ReconciliationId IS NOT NULL` -- live paths still cannot write a negative. |
| Scrap / warm-up | `RejectEvent` with negative `Quantity` and the reconciliation id. Every reject report SUMs, so it nets; the Transaction Detail shows the correction as its own row, which is honest. |
| Counter reading | `DieCastCounterAnchor` at the sheet figure. The anchor already discards earlier readings in the shift (`ufn_DieShotWatermark`: MAX over the anchor and readings *after* it), so it is the existing way to lower a watermark. |
| LOT count | The count-correction worker, subject to §3.3's lock. |

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

**Six workers** (confirmed by Jacques 2026-09-22): five lifted out of four live procs, one new.

| Worker | Extracted from | Guards that stay in the live wrapper only |
|---|---|---|
| `Workorder.DieCastCredit_Write` | `DieCastShiftOutput_Record` (contribution + PieceCount + ShotCount) | reading behind the die watermark; pieces onto a closed LOT |
| `Workorder.DieCastScrap_Write` | `DieCastShiftOutput_Record` (cavity + die-wide fan-out) | -- |
| `Lots.DieCastLot_Mint` | `DieCastLot_Open` | die mounted *now*; one open LOT per cavity |
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
@LotsJson         -- [{lotId|null, ltt, toolCavityId, quantity}]   (actual qty per LOT)
@RejectsJson      -- [{defectCodeId, itemId|null (null = All), quantity, approvedByUserId}]
@CountsJson       -- [{lotId}]  released LOTs whose count the team lead accepted
@LoadedStamp      -- stale guard: MAX row id / EventAt the screen loaded (§8)
@AppUserId, @TerminalLocationId
```

Pre-transaction validation (every rejection is a status row, no open transaction -- Msg 3915 rule):
AppUser exists; shift is **closed** (a reconciliation never targets the open shift -- the live
screen owns it); the die was mounted on the press during the shift (`Tools.ToolAssignment`
overlap); reason exists, note when required; every move targets a closed shift within +/-2 of the
source and moves a row belonging to this shift x press x die; every LTT either resolves to a LOT of
**this die and cavity** or is a valid unused LTT (`Lots.ufn_IsValidExternalLtt`) -- an LTT that
belongs elsewhere is refused *naming where it belongs*; every count correction is on a
released, not-counted-downstream LOT; the stale stamp matches.

Then one transaction: header row -> moves -> mint -> credits/scrap (increases and compensating
decreases) -> anchor if the reading drops -> release new LOTs -> count corrections -> audit. The
proc **computes the deltas itself** from recorded vs sheet; the JSON carries what the sheet says,
never a delta. That keeps the arithmetic in SQL (no business logic in Python) and makes a re-run
after any partial success a no-op for what already landed.

### 5.3 Reads -- new

| Proc | Returns |
|---|---|
| `Workorder.DieCastShiftReconciliation_ListShifts(@CellLocationId, @Days)` | Landing list: per shift x die mounted, entries, good recorded, max reading, status (`NoEntry` / `EntryRecorded` / `ReleasedNoShiftEnd` / `Reconciled`) |
| `Workorder.DieCastShiftReconciliation_Load(@ShiftId, @CellLocationId, @ToolId)` | One row per recorded fact for the shift x press x die: entries (grouped, with row ids), LOTs with credited-in-shift, LOT state + lock reason, reject rows, shift totals, die life, stale stamp. One result set, discriminated by a `RowKind` column. |
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
- **Totals block** -- Recorded | Actual | Gap for Total shots, Good shots, Warm-up shots, No-good
  pieces, Total good pieces.
- **Reject block** -- QAS (Approved by), Reason, Part (All or one), Amt, with recorded rows beside.
- **LOT list** -- grouped by part in the sheet's order (part name, Macola #, sub-total): LTT, Cav,
  Actual qty, Recorded, LOT state, Count before -> after. The entry bar adds LTTs (§6.3).

**The typed column is labelled Actual, never Sheet** (Jacques, 2026-09-21). The paper is where the
figures come from; what the screen compares is recorded against actual. Every operator-facing
string follows: *"no actual figure"*, *"actual total good"*, *"checked against the actual count"*.
- **Footer** -- Discard, Review & Save.

### 6.3 Adding LTTs -- including a shift with nothing recorded (D16)

The Machine 202 evidence (§1) is the case this exists for: a whole shift of LOTs that are on paper
and nowhere in the MES. The LOT list carries an entry bar, not a single `+` row:

- **One LTT at a time, scanned or typed off the LOT itself.** The team lead reconciling a missing
  shift has the LOTs in front of them -- the paper LTT is on each one -- so every LTT entered is one
  that physically exists. A keyboard-wedge scanner works: the cursor stays in the LTT field after
  each add.
- **No run entry and no sequence hint.** LTTs are pulled from a shared stack across the die
  building (Jacques, 2026-09-22), so consecutive numbers say nothing about which press, die or shift
  used them. Entering a range would invent LOTs for tickets that are on no LOT.
- On a multi-cavity die the entry carries the cavity (part + letter); on a single-cavity die it is
  implied.
- **Every LTT is resolved the moment it is added**, never at save:

  | LTT | Result |
  |---|---|
  | Not in the MES, valid (`Lots.ufn_IsValidExternalLtt`, 8-9 digits) | **New LOT** -- minted against this press, die and cavity, credited, stamped to the shift, and released to Warehouse at save (D4). |
  | Already a LOT on **this die** | Adds to that LOT; §3.3's three states apply to its count. |
  | A LOT on **another press or die** | **Refused**, naming where it belongs (*"10628131 is Machine 11 · 6MA IN 2,3,4 EX 2,3,4 D (Asset # DMO125), cavity A"*). |
  | Already in the list | Ignored, and said so. |

- A new LOT's row can be removed before save; nothing is written until the confirmation.
- The rest of the screen is unchanged: the Actual totals must add up, the LOT list must equal
  Actual total good, and die life advances by the shift's Actual total shots (there is no recorded
  reading to subtract).
- The confirmation lists new LOTs by LTT with their quantities (§7.5).

A shift with nothing recorded opens with an explicit empty state -- *"Nothing is recorded for this
shift on Machine 202 -- no entries, no LOTs, no rejects. Everything below comes from the press
sheet."* -- so an empty screen is never mistaken for a failed load.

### 6.4 Supervisor dashboard tile

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
before and after; the explicit statement *Shots, pieces, LOTs and die life do not change -- only
which shift is credited*; the row count that moves. Target limited to +/-2 closed shifts. Confirm
button: **MOVE TO 09-16 3RD SHIFT**. Moves are staged on screen (the card shows *Moving to 09-16
3rd*, undoable) and written only at Save.

### 7.4 Before Save -- blocking checks, in plain words

Save stays disabled, and says why, until:

- the reason is set (and its note, if required);
- **the LOT list adds up to Total good pieces**, and Good shots x cavities - no-good = Total good --
  *"LOT list totals 11,880; actual total good is 12,960. One of them has a typo."*;
- every LTT resolves (no unknown or foreign LTTs);
- no LOT quantity exceeds that cavity's shots for the shift -- a typo guard (10800 for 1080).

These are the sheet's own arithmetic. They block because a failure is always a typing error, never
a plant condition -- unlike variance on the live screen, which is allowed to mean "we do not know".

### 7.5 The Save confirmation -- what will change

A full-width popup, the shift in large type at the top, then **only the groups that have content**,
each in plain sentences with numbers:

| Group | Example |
|---|---|
| Entries moved | *1 entry (24 rows) moves from 09-17 1st to 09-16 3rd.* |
| Production added | *12,960 good pieces credited to 12 LOTs. 456 warm-up and 36 test pieces recorded.* |
| Production reduced | *(amber)* *72 pieces removed from 10628131 (a correction).* |
| New LOTs | *2 LOTs created and released to Warehouse: 10628574, 10628575.* |
| LOT counts changed | *6 released LOTs: 10628131 1,788 -> 2,868, ...* |
| Counts left standing | *(grey)* *10628125 was counted at Trim OUT on 09-18 -- its count stands; its production is still recorded.* |
| Die life | *Asset # DMO125 (6MA IN 2,3,4 EX 2,3,4 D): 15,699 -> 16,820 (+1,121 shots).* |

Anything that **reduces** production, die life, or a count is amber and needs its own tick box
(*I have checked this reduction against the actual count*) before the confirm button enables. Additions do
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
- **LTT belongs elsewhere.** Refused with where it belongs (*"10628578 is 6FB / DM0144 cavity a"*).
- **Cutover-keyed LTT.** An existing LOT like any other; §3.3 applies.
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
  failing to enter it is operator failure, not something to build around* -- hence §6.4.
- **Consequence to know about:** when that shift-end number is entered, the breakdown's proposal
  for the open LOT is `reading - cavity watermark`
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
- the three LOT states, including a locked LOT whose production is still written;
- **no override**: a count correction on a counted-downstream LOT is refused;
- re-file leaves `ShotCount` and every `PieceCount` untouched;
- decreases: negative contribution only with a reconciliation id (live path still refused by the
  CHECK); negative scrap nets on `Reject_GetPartMatrix`; an anchor lowers the reading;
- LTT collision named; unused LTT minted and released to default storage;
- stale stamp refuses; open shift refused; move outside +/-2 refused;
- re-running an identical save writes nothing but a header;
- `DieCastShift_ListUnreconciled` flags Machine-202-shaped data and clears on a header.

**Acceptance -- Jacques's sheet.** Restore prod to a local ProdSim DB. Reconcile Machine 11 09-16
3rd, 09-17 1st and 09-17 2nd from the DCFM-2076 sheet. Re-run
`sql/scratch/Run-DieCastOnRecord.ps1` against it. It must show: 09-16 3rd 11,436; 09-17 1st
12,960; 09-17 2nd 8,532 with reading 732 and 300 warm-up pieces; `DMO125` die life +1,121 (+6 for
the 2nd-shift reading); LOTs 10628131-134 at 2,868; and every Machine 202 shift flagged until
reconciled.

**Screens.** Live smoke on the Dev gateway with a real AD sign-in: each popup in §7, a blocked save
for each §7.4 check, a reduction needing its tick box.

## 12. Release

Touches prod data and the live die cast write path, so the full release contract applies
(`prod-release-context-pack/`): preview, rehearsal against live data, fingerprint-guarded execute,
scoped Core + MPP exports built from git, and a published runbook. The worker extraction is the
risky half; it ships with its regression evidence in the runbook.

## 13. Review items -- settled 2026-09-22

1. **D13 -- decreases as compensating rows.** Kept. The original entry stays exactly as the operator
   made it, the correction sits beside it with who and why, and every existing total nets without a
   read changing. `CK_DieCastContribution_DeltaNonNeg` is relaxed for reconciliation rows only; the
   live screens still cannot write a negative. Voiding was rejected (every reader would have to skip
   void rows); editing in place was rejected (the original disappears).
2. **§5.1 -- six workers.** Confirmed: five extracted from `DieCastShiftOutput_Record` (two),
   `DieCastLot_Open`, `DieCastLot_Release` and `Lot_RectifyPieceCount`, plus the new
   `DieCastEntry_Restamp`. The live procs keep their checks and call the workers; the Save has its
   own checks and calls the same workers, in one transaction.
3. **§7.4 -- the four blocking checks.** Agreed as written.
4. **LTT sequence.** No. LTTs come off a shared stack across the die building, so there is no
   sequence hint and no run entry; the team lead scans or types the LTT on each physical LOT (§6.3).

---

## 14. Amendments from the implementation plan (2026-09-22)

Found while writing `docs/superpowers/plans/2026-09-22-diecast-shift-reconciliation-sql.md`
against the code. Where these disagree with earlier sections, these win.

| # | Amendment | Why |
|---|---|---|
| A1 | Backfilled rows are stamped **one second before** the shift's `ActualEnd` (UTC), not at it. | Shift windows are `[start, end)`: a row stamped exactly at the end resolves to the *next* shift. |
| A2 | `Oee.ShiftOverride_Restamp` **skips** contribution rows that carry a `ReconciliationId` or appear in `Workorder.DieCastReconciliationMove`. | The restamp re-derives the shift from `EventAt`. A moved entry keeps its real `EventAt` (09-17 09:35), so the next override on that press would silently move it back. The team lead's decision wins over the time-based resolver. |
| A3 | The shift's counter reading is set by **an anchor written at save** (`DieCastCounterAnchor`, new reason `ShiftReconciliation`, `EventAt` = the save time), up or down. Reconciliation credit rows carry **no** reading. | The latest anchor floors both watermarks and discards earlier readings -- one mechanism for increases and decreases. The new reason is hidden from the operators' *Fix counter* list. |
| A4 | Moves cover **contribution and reject rows** only. | Anchors are counter resets; filed against the wrong shift is not a case the evidence showed. |
| A5 | **No `@CountsJson`.** Every released, not-locked LOT with a gap has its count corrected; the confirmation lists them. | The state decides, not the team lead -- one fewer decision on the critical path. |
| A6 | The single `_Load` proc is replaced by `_GetHeader`, `_ListEntries`, `_ListLots`, `_ListRejects`, `_ListMoveTargets`, plus `Lots.DieCastLot_ResolveLtt`. | One result set per proc (FDS-11-011). |
| A7 | Reject and warm-up gaps are computed **per active cavity**. A reject line's amount must divide evenly across the cavities it covers ("All" = every active cavity; a part = that part's cavities), else it is refused with a plain message. | The recorded rows are per cavity; so is the comparison. |
| A8 | Header columns are `ActualTotalShots`, `ActualGoodShots`, `ActualWarmUpShots` (were `Sheet*`). | "Actual, never Sheet" (2026-09-21). |
| A9 | A new LOT's part is **not** required to have a published Die Cast route. | A configuration gap must not stop production that happened from being recorded -- the `0084` D4 principle. |
| A10 | The count lock also covers LOTs whose status blocks production (Hold, Scrap). | `Lot_RectifyPieceCount` refuses them too. |
| A11 | LOT or reject lines require the three actual totals; a save with only moves does not. | The blocking checks (§7.4) cannot run without them. |
| A12 | The six workers are named `Workorder.DieCastCredit_Write`, `Workorder.DieCastScrap_Write`, `Lots.DieCastLot_Mint`, `Lots.DieCastLot_ReleaseMove`, `Lots.Lot_ApplyPieceCountCorrection`, `Workorder.DieCastEntry_Restamp`. | Final names. |
