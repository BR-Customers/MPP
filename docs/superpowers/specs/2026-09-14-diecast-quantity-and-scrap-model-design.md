# Die Cast Quantity and Scrap Model — Design Spec

**Date:** 2026-09-14
**Status:** Design, awaiting Jacques's review
**Migration:** `0084_reject_event_cavity_attribution`
**Mockup:** `mockup/diecast_reconcile_mock.html` (published artifact, rev 4)
**Supersedes nothing.** Extends the shot-reading chain (`2026-09-09-diecast-shot-reading-chain-design.md`)
and the counter anchor (`2026-09-10-diecast-counter-anchor-design.md`).

---

## 1. Motivation

Three complaints from the die cast floor, which turn out to be one problem.

1. **Operators want to enter the basket quantity, not a press counter reading.** At the oil pan
   lines the basket holds something a person can actually count, and the counted number beats a
   derived one.
2. **Nothing on the shift-output screen shows scrap that has already been submitted.** At end of
   shift the operator is reconciling against a paper form and cannot see what the system already
   holds.
3. **Scrap has to be recordable against a cavity with no basket checked in.** Die cast logs scrap
   for the *shift*, not for the LOT — which is the opposite of every other operation in the plant.

Underneath all three: **the numbers are never required to add up.** `good` is *computed*
(`reading − cavity watermark`), `scrap` is recorded *additively and separately*, and no code path
anywhere compares them. A shift can submit 2,000 shots, 2,000 good and 300 scrap and the system
answers *"Shift output recorded."*

So "Record Shift Output" is a **credit** screen — *how many parts do I add to each basket?* What
the floor is asking for is a **reconciliation** screen — *the press ran N shots, you have this much
good, you scrapped this much, here is the gap.* Once that framing is right, all three complaints
are the same feature.

---

## 2. Decisions locked (from brainstorming)

| # | Decision |
|---|---|
| D1 | Die-cast scrap is attributed to **(Shift, Press, Tool, Cavity, Part)**. `Workorder.RejectEvent.LotId` becomes **nullable**; a LOT is stamped when one happens to be open. |
| D2 | **Identity never routes through the LOT.** `RejectEvent.ItemId` is stamped at write time and is what every reject report reads. |
| D3 | The press counter reading **proposes** good; the per-cavity good figure is **editable**. Reading and counted-good are two independent facts and are allowed to disagree. |
| D4 | The disagreement is shown as **variance**. A non-zero variance requires a **disposition** before submit, and `Unknown` is always one of the choices — mandatory, but it can never wall an operator (§3.7). |
| D5 | Scrap is recordable at **two moments**: the Reconcile tab, and basket release. |
| D6 | Shot loss stops being an immediate separate proc call and **folds into the one Submit**. |
| D7 | The die-wide block carries **explicit named rows** for Warm-up (`DC-999`) and Quality test (`107`), plus free add-rows. Entry is in **shots**; the resulting part count is shown. |
| D8 | Die-wide scrap fans out across **active cavities**, not open LOTs. |
| D9 | Warm-up is classified `IsNonRejectScrap = 1`, charged to **Die Cast**. |
| D10 | Three tabs collapse to two cavity-keyed tabs: **Lot Management** and **Reconcile Shift**. |
| D11 | The right-hand KPI rail is removed. |
| D12 | The plant-floor type scale drops **15%** (a separate, global change — see §8). |
| D13 | `Tools.ToolCavity_SaveAll` **requires a part** on any cavity row it creates or changes, so no *new* unmapped cavity can be authored. Untouched legacy rows are not blocked. |
| D14 | A cavity with no basket **must not** advance its shot watermark — its shots credit to the next basket, because that is where the castings physically are (§3.6). `DieCastContribution.LotId` stays `NOT NULL`. The table gains a stamped `ToolCavityId` and the variance-disposition columns only. |
| D15 | New code table `Workorder.DieCastVarianceReason`, shaped like `DieCastCounterAnchorReason` (`0074`): reason + conditionally-mandatory note, with a `Warning`-severity audit row as the control. |
| D16 | The **die** is a reportable dimension. `RejectEvent` carries `ToolId` alongside `ToolCavityId` so scrap resolves to a die without traversing a cavity. Remodelling the reject reports to *use* it is explicitly **deferred** (§13). |
| D17 | The variance disposition is picked **inline in the variance cell**, using the same in-place expander the cavity-scrap cell uses — not a pre-submit dialog. |

---

## 3. The model

### 3.1 Why die cast is not subtractive, and where the model already knows that

Everywhere downstream — trim, machining, assembly — the LOT is the unit of account and scrap comes
*out of* it: you had 100 parts, 5 were bad, you have 95. At the press, the cavity fires and the bad
casting **never enters the basket**. Scrap is produced-and-discarded, parallel to the basket.

Migration `0042` already conceded exactly this. `Workorder.RejectEvent_Record` takes
`@OperationTypeCode` and derives:

```sql
DECLARE @Additive BIT = ISNULL(
    (SELECT ScrapIsAdditive FROM Parts.OperationType WHERE Code = @OperationTypeCode), 0);
```

Additive scrap records without decrementing `PieceCount` and without closing the LOT. **One proc,
two behaviours, the rule in SQL.** That is genuinely "both systems" and it is already correct.

What was never followed through is the second consequence. If the scrap never entered the basket,
then it does not *need* a basket — but `RejectEvent.LotId` is `BIGINT NOT NULL`, so every additive
row is still pinned to a container it was never in. **That single constraint is what makes
complaint 3 impossible today.**

### 3.2 The identity

Per cavity **that has a basket**, per entry:

```
netShots  =  good  +  scrap  +  unaccounted

  netShots = (counterReading − cavityWatermark) − dieWideShots
  scrap    = this cavity's own scrap lines
```

A cavity with **no** basket is outside this identity. Its shots are **pending**, not unaccounted —
they credit to whatever basket opens next, because that is where the castings are (§3.6).

Nothing new needs storing to compute it. `Workorder.DieCastContribution` already carries
**`ShotCounterReading`** and **`PieceDelta`** on the same row, and scrap will be keyed to the same
cavity and shift. **The reconciliation is a read proc the screen never had, not a new subsystem.**

### 3.3 Die-wide scrap must reduce the proposal, not sit beside it

Today shot loss is purely additive. A 2,000-shot shift with 20 warm-up shots proposes 2,000 good
per cavity *and* books 20 scrap per cavity — 2,020 parts out of 2,000 shots. Nothing complains,
because nothing checks.

Under the identity that surfaces as a −20 variance on **every cavity, every shift**, which would
train operators to ignore the variance inside a week. So:

```
proposedGood = netShots − thisCavityScrap
```

with `netShots` already net of die-wide. The default balances to zero; a non-zero variance then
means something actually happened. The operator still never subtracts anything — D3's whole point.

### 3.4 What "two independent facts" means in practice

The good figure **auto-follows** `netShots − cavityScrap` while untouched. The moment an operator
types a number it locks to theirs and is visibly marked as operator-entered. So a line that reads
the counter types nothing, and a line that counts baskets types one number per cavity. There is no
mode, no toggle, and no per-part configuration — the behaviour differs because the operator's
behaviour differs.

### 3.5 A cavity with no basket cannot be credited *on this entry*

Its good figure is **fixed at 0 and the input disabled** — there is no LOT to carry pieces. But that
is a deferral, not a loss: those shots stay behind the cavity's watermark and are credited to the
next basket (§3.6). The screen therefore reports them as **pending**, never as variance.

### 3.6 A basketless cavity must NOT advance its watermark — and the `NOT NULL` is why it doesn't

**This section previously argued the opposite, and was wrong.** It is kept, inverted, because the
constraint it concerns looks like an oversight and an earlier draft of this spec proposed removing
it.

When a basket is released and the next one is opened late, the press keeps firing — and those
castings go into **the next physical container**, the one the operator opens late. The MES record
lags the metal; it does not lose it. So when that basket is opened and later credited
`reading − cavityWatermark`, it picks up the gap shots **because the parts are in it**. The credit
is the record catching up, not phantom production.

`Workorder.DieCastContribution.LotId` is `NOT NULL`, and `Workorder.ufn_CavityShotWatermark` reaches
the cavity through it:

```sql
SELECT @Watermark = MAX(c.ShotCounterReading)
FROM Workorder.DieCastContribution c
INNER JOIN Lots.Lot l ON l.Id = c.LotId
WHERE l.ToolCavityId = @ToolCavityId
```

A basketless cavity therefore cannot write a watermark-advancing row — **which is the correct
result.** Advancing it would strand those shots behind the new watermark and under-credit the basket
that physically holds the castings. **A timing gap on the operator's part must not cost them
production** (Jacques, 2026-09-14).

The default is that gap castings are **good**. An operator who knows otherwise reports it — scrap
against the cavity with **no LOT** (§4.1), which is exactly what that change exists for. Default
good, reportable otherwise.

### 3.7 Mandatory disposition, not a hard block

A hard block on non-zero variance does not produce reconciliation. It produces **fiction**: an
operator at 03:00 who genuinely cannot account for twelve pieces, facing a screen that will not
submit, picks a defect code at random — and the Part Matrix Honda reads now carries twelve
fabricated `111 Flash` rejects instead of twelve honest unaccounted pieces. A known gap has been
traded for an invisible corruption, in the one dataset that must not be corrupt.

The counter anchor (`0074`) faced this exact choice in this exact subsystem and resolved it:

> *Any signed-in operator, with a mandatory reason. Deliberately no AD elevation — the operator is
> the only person who can see the press counter, and gating on a supervisor strands a night shift at
> a wall. The reason code and a `Warning`-severity audit row are the control.*

D4 adopts the same shape. Submit is gated until every non-zero variance carries a disposition, and
**`Unknown` is always available.** The difference from a hard block is the escape hatch: under a
block the only way out is to lie; here the way out is to say you do not know. Both let the operator
finish the shift. Only one of them tells the truth afterwards.

So *"scrap with no reason code"* stops being a category. Every piece is either **good**, **scrap with
a defect code**, or **variance with a disposition** — and the third is explicitly allowed to mean
*we do not know*, which is a fact worth recording rather than one worth hiding.

---

## 4. Schema

### 4.1 `Workorder.RejectEvent` — cavity attribution

| Column | Change | Why |
|---|---|---|
| `LotId` | `NOT NULL` → **`NULL`** | D1. A cavity with no basket can be scrapped. |
| `ItemId` | **new**, `BIGINT NULL`, FK → `Parts.Item` | D2. Identity without traversing the LOT. |
| `ToolCavityId` | **new**, `BIGINT NULL`, FK → `Tools.ToolCavity` | Which cavity produced it. |
| `ToolId` | **new**, `BIGINT NULL`, FK → `Tools.Tool` | D16 — **which die**. Denormalised deliberately (see below). |
| `ShiftId` | **new**, `BIGINT NULL`, FK → `Oee.Shift` | Shift-scoped reads and reporting. |
| `CellLocationId` | **new**, `BIGINT NULL`, FK → `Location.Location` | The press. Mirrors `DieCastContribution.CellLocationId` (v1.4) so `Oee.ShiftOverride_Restamp` can key on a plain equality. |

All five nullable and additive. Backfill `ItemId` once from the LOT
(`UPDATE … SET ItemId = l.ItemId FROM Lots.Lot l WHERE re.LotId = l.Id`); the rest stay NULL on
historical rows, which is honest — we do not know the cavity for a 2026-08 reject and should not
invent one.

**`ToolId` is stamped, not derived through the cavity.** It is reachable as
`ToolCavity.ToolId`, so denormalising looks redundant — but several dies make the same part and are
distinguishable **only by their code** (prod carries `11200-5J6-A000` on two dies, `11200-6MAA-J010`
on two more). Once "which die produced this scrap" is a question the reports must answer, it should
be one column on the fact row, not a join that a lot-free or cavity-less row could fail. Same
argument as `ItemId` (§4.2), one level up. It also makes the per-die reject rate computable against
`Tools.Tool.ShotCount` and `ShotLimit` without touching the cavity table at all.

**`ItemId` is nullable because the column it resolves from is nullable — not because unmapped
cavities are an accepted state.** D13 (§4.6) stops new ones being authored, and MPP is mapping the
existing backlog as part of deployment, so NULL is a **shrinking legacy state**. But
`Tools.ToolCavity.ItemId` stays `NULL`-able at the column level and `Tools.Tool_Duplicate`
deliberately writes NULL when a source cavity's part has since been deprecated (§4.6), so a NOT NULL
`RejectEvent.ItemId` would have no guaranteed resolution path and would make scrap *unrecordable* on
such a cavity — blocking the floor on a configuration gap, which contradicts D4.

**A downstream constraint must never be stronger than the upstream one it depends on.** D13 is a
proc validation, not a column constraint; direct SQL, a migration, or `Tool_Duplicate` can still
produce a NULL. Tightening `RejectEvent.ItemId` to NOT NULL is available later, once the backlog is
mapped, `Tool_Duplicate` has an answer, and `Tools.ToolCavity.ItemId` is itself NOT NULL — in that
order. Until then reports bucket NULL as *(unassigned part)*, the precedent `ChargeToPartyId`
already sets for `DC-999`.

### 4.2 Why `ItemId` is stamped rather than derived — the finding that makes this non-optional

Two reject reports resolve the part number like this:

```sql
FROM Workorder.RejectEvent re
INNER JOIN Lots.Lot   l ON l.Id = re.LotId      -- <<<
INNER JOIN Parts.Item i ON i.Id = l.ItemId
```

`Quality.Reject_GetPartMatrix` (line 49) and `Quality.Reject_SearchDetail` (line 63).
`Reject_GetPlantSummary` joins the same way through `ProductionEvent`.

**An `INNER JOIN` on a NULL key drops the row.** Make `LotId` nullable without addressing this and
every lot-free die-cast scrap row silently disappears from the Part Matrix and the Transaction
Detail — no error, no warning, a smaller number that looks plausible. That is precisely the failure
mode the `Shipping History` report shipped with for months (empty because the gate could never
open, not because nothing shipped).

Changing those joins to `LEFT` would not fix it either: the row would survive with a NULL part and
fall out of the `GROUP BY i.Id`. **The part has to be on the reject row.** Every reject reader then
reads `re.ItemId` directly and `LotId` reverts to what it should always have been — a traceability
link, not an identity path.

### 4.3 Migration mechanics — and why now is the cheap moment

`LotId` is the **leading key of a clustered index on a partitioned table**:

```
CIX_RejectEvent_LotRecordedAt  CLUSTERED  (LotId, RecordedAt)  ON ps_MonthlyUtc
PK_RejectEvent                 NONCLUSTERED (Id, RecordedAt)   ON ps_MonthlyUtc
IX_RejectEvent_ProductionEventId / _DefectCodeId / _TerminalLocationId  — all ON ps_MonthlyUtc
```

SQL Server will not `ALTER COLUMN` the nullability of an indexed column in place. Order:

1. `ALTER TABLE … DROP CONSTRAINT FK_RejectEvent_Lot`
2. `DROP INDEX CIX_RejectEvent_LotRecordedAt`
3. `ALTER TABLE … ALTER COLUMN LotId BIGINT NULL`
4. Add the four new columns + FKs
5. Backfill `ItemId`
6. Recreate `CIX_RejectEvent_LotRecordedAt` **`ON ps_MonthlyUtc(RecordedAt)`**
7. Re-add `FK_RejectEvent_Lot`
8. New filtered index for the cavity-keyed read path (§4.4)

**Step 6's storage clause is load-bearing.** Every index on this table is partition-aligned, and
sliding-window `TRUNCATE` retention (B2) requires that. Recreating the clustered index on
`PRIMARY` instead would silently break partition maintenance — the same class of defect recorded
in `project_mpp_partition_aligned_pk`.

**Cost:** measured, not estimated — `MPP_MES_Dev` **27** rows, `MPP_MES_Prod` **67** rows
(2026-09-14, largely FAT practice). A clustered-index rebuild on a partitioned table costs in proportion to rows. At today's order of
magnitude this is a sub-second operation inside the normal `Deploy-ProdRelease` transaction; at a
year of production it is a maintenance window. This is the cheapest this change will ever be, and it
gets monotonically worse.

### 4.4 Indexing

Keep `CIX_RejectEvent_LotRecordedAt` clustered on `(LotId, RecordedAt)` — "rejects for this LOT" is
the Honda traceability path and remains the most important read. NULLs simply cluster at one end.

Add, per the B8 filtered-index convention:

```sql
CREATE INDEX IX_RejectEvent_ShiftCavity
    ON Workorder.RejectEvent (ShiftId, ToolCavityId, RecordedAt)
    WHERE ShiftId IS NOT NULL
    ON ps_MonthlyUtc(RecordedAt);
```

That is the new dominant access path (shift-scoped prior scrap per cavity) and the filter keeps it
off every non-die-cast row.

### 4.5 `DC-999 Warmup` — repo drift, and three fixes not one

Prod carries this defect code. **The repo has never had it.** No `999` and no "Warm" anywhere in
`sql/seeds/030_seed_defect_codes.sql` or any migration; the only "Warm Up" strings in the tree are
two Machine-Shop *downtime* reason codes. A fresh `Reset-DevDatabase` therefore builds a database
where the warm-up row on the new screen has nothing to write.

Prod's row reads: `DC-999 | Warmup | OperationCategory NULL | IsExcused 0 | IsNonRejectScrap 0 |
ChargeToParty NULL`. Three things wrong with it:

| | Now | Should be | Why |
|---|---|---|---|
| `OperationCategoryId` | NULL | **DieCast** | With NULL it reads as plant-wide and does not filter onto the die-cast screens that need it. |
| `IsNonRejectScrap` | 0 | **1** | D9. Warm-up metal was never going to be a part; counting it against a die's reject percentage makes every changeover look like a quality event. Matches `107`/`229`, already flagged by `0067`. |
| `ChargeToPartyId` | NULL | **DieCast** | Keeps it visible as a departmental cost rather than in a bucket everyone learns to ignore. |

Delivered in **both** `sql/seeds/030` and migration `0084`, per the `0048`/`0067`/`0075`
precedent: a reset runs migrations before seeds (so the migration's backfill sees an empty table),
and an in-place upgrade never re-runs seeds. Both copies or the fix lands in exactly one
environment.

**The code string stays `DC-999`** despite every other code being bare numeric (`100`–`260`).
It exists in a live system that has been recording production since 2026-09-09; renaming a code
is worse than the inconsistency. Noted so the next person does not "fix" it.

**Quality test shots write `107 Test Part`** — already seeded, already `IsNonRejectScrap = 1`,
already `@DieCast`. No change. (`229 Trial Part` is its sibling and stays available as an
add-row.)

### 4.6 `Tools.ToolCavity_SaveAll` — a part is required on rows this save touches (D13)

The gap §4.1 works around should also be closed at its source: a cavity with no part is a
configuration mistake, not a state worth supporting. `ToolCavity_SaveAll` v1.2 rejects any row it
is **creating or changing** whose `ItemId` is NULL, naming the cavity letters in the message.

**The validation is row-scoped, and that is the whole design.** `ToolCavity_SaveAll` is a bundled
reconcile — `@RowsJson` carries *every* cavity on the die, not just the edited one. A blanket
"ItemId required" check would therefore reject the entire save whenever any pre-existing row is
unmapped, so changing one cavity's status on `5G0-F-A` would fail because two untouched siblings
have no part. That is the same failure that stranded the Cavities editor in the `Tool_Duplicate`
bug (2026-09-10): a proc refusing to re-save state it had itself produced.

| Case | Result |
|---|---|
| New cavity (`Id` NULL) | Rejected without a part |
| Existing row whose incoming values differ | Rejected without a part |
| Existing **mapped** row, unmapped sibling untouched | Saves |
| Untouched legacy unmapped row | Survives; must be mapped the first time it is edited |

So the guarantee is **"no new unmapped cavities"**, and the legacy set drains as dies are touched
rather than in one blocking migration. That is why `RejectEvent.ItemId` stays nullable (§4.1).

**`Tools.Tool_Duplicate` keeps its NULL path** (line 377): when a source cavity's part has since
been deprecated, the copy gets `ItemId = NULL` and the count is named in the success message. That
was the *fix* for the 2026-09-10 defect — carrying a deprecated `ItemId` forward produced a cavity
`ToolCavity_SaveAll` then refused to re-save. Making NULL invalid too would strand the duplicate
from the other direction. Row-scoped validation resolves both: the duplicate lands, the cavity is
flagged, and it must be mapped the first time anyone edits it.

**Uniqueness is unchanged.** The active-cavity key is `(ToolId, ItemId, CavityCode)` with NULL
handled via an `ISNULL(ItemId, -1)` sentinel. That sentinel stays until `ToolCavity.ItemId` is
genuinely NOT NULL — simplifying it now would break on exactly the legacy rows this design leaves
in place.

**Screen.** The Cavities editor shows an unmapped existing row with a *"no part configured"* flag
rather than an empty cell, so the gap is visible before a save is attempted rather than as a
rejection after.

### 4.7 `Workorder.DieCastContribution` — stamped cavity and disposition (D14, D15)

| Column | Change | Why |
|---|---|---|
| `LotId` | **unchanged — stays `NOT NULL`** | §3.6. A basketless cavity must not advance its watermark, and this constraint is what prevents it. |
| `ToolCavityId` | **new**, `BIGINT NULL`, FK → `Tools.ToolCavity` | Lets §5.3b drop the `INNER JOIN Lots.Lot`. A simplification, not a necessity. |
| `VarianceReasonId` | **new**, `BIGINT NULL`, FK → `Workorder.DieCastVarianceReason` | D15. |
| `VarianceNote` | **new**, `NVARCHAR(500) NULL` | Required when the reason says so. |

**This table is unpartitioned** — `PRIMARY`, five indexes, **77 rows** on Dev — so this is a plain
`ALTER`: no index rebuild, no partition-alignment hazard, nothing like §4.3. Backfill
`ToolCavityId` once from the LOT. Add `IX_DieCastContribution_Cavity (ToolCavityId, ShiftId)`.

**A contribution row is still written only when there is a basket.** An earlier draft proposed one
row per active cavity per entry, unconditionally, so a basketless cavity could carry a reading — see
§3.6 for why that is wrong. Dispositions attach only to cavities that have a basket, so a `NOT NULL`
`LotId` is no obstacle to D15.

`Workorder.DieCastVarianceReason` is a fixed-seed code table shaped like `DieCastCounterAnchorReason`
(`0074`), including its `RequiresNote` flag:

| Code | Name | RequiresNote |
|---|---|---|
| `MiscountedBasket` | Basket count corrected | 0 |
| `CounterSuspect` | Press counter reading suspect | 0 |
| `ScrapNotRecorded` | Scrap produced but not recorded | 0 |
| `PartsRemovedFromLine` | Parts removed from the line | 1 |
| `Unknown` | Unknown | 1 |

`Unknown` requires a note deliberately — not to obstruct, but because *"found the cavity empty at
02:40"* is worth more six months later than a bare code, and it costs one line.

---

## 5. Stored procedures

### 5.1 `Workorder.RejectEvent_Record` — lot-optional

New optional params `@ItemId`, `@ToolCavityId`, `@ShiftId`, `@CellLocationId`. `@LotId` becomes
optional but **exactly one of `@LotId` / `@ToolCavityId` must be supplied** — a reject that
identifies neither a basket nor a cavity is not a fact about anything and is rejected
pre-transaction.

Resolution, in SQL:

- `@ItemId` supplied → use it.
- else `@LotId` supplied → `Lots.Lot.ItemId`.
- else `@ToolCavityId` supplied → `Tools.ToolCavity.ItemId` (may be NULL — allowed, §4.1).

The `@Additive` branch (`0042`) is untouched. Subtractive scrap still requires `@LotId` — there is
nothing to decrement without one — and that is a validation, not an accident.

### 5.2 `Workorder.DieCast_GetShiftOutputBreakdown` → v3.0

Two new trailing columns (appended last; consumers capture this proc positionally via
`INSERT-EXEC`):

| Column | Meaning |
|---|---|
| `PriorScrapThisShift` | `SUM(RejectEvent.Quantity)` for this **cavity** in this **shift**. The number that exists nowhere today. |
| `DieWideShots` | Shots already booked die-wide this entry, so the row can show `raw − dieWide`. |

`ProposedGood` changes to net of die-wide (§3.3). The v2.1 cavity-driven row source stays exactly
as it is — it is the change this whole design generalises.

### 5.3 `Workorder.DieCastShiftOutput_Record` → v3.0

- Each line may carry **`toolCavityId` with a null `lotId`**. Scrap on such a line writes a
  `RejectEvent` with `LotId NULL`, `ToolCavityId`, `ShiftId`, `CellLocationId` and the cavity's
  `ItemId`. Pieces on such a line are still rejected — there is no basket to credit.
- **Die-wide fan-out re-keyed.** Today:

  ```sql
  CROSS JOIN Lots.Lot l INNER JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId
  WHERE l.ToolId = @ToolId AND sc.Code = N'Open'
  ```

  — which reaches only cavities that happen to have an open basket, and **silently skips the rest**.
  It becomes a fan-out over `Tools.ToolCavity` where `StatusCode = 'Active'` and `DeprecatedAt IS
  NULL`, stamping each row's cavity and part, and attaching the LOT only where one is open. D8.
  This is strictly more correct and is the same button to the operator.
- `@ShotLossJson` keeps its name and shape. The **screen** stops calling it separately (D6); the
  proc already accepted both in one call.
- Scrap writes stay **inlined** rather than `EXEC`-ing `RejectEvent_Record` — this proc returns a
  status row and is itself captured via `INSERT-EXEC`, so the nesting rule applies unchanged.

### 5.3b `Workorder.ufn_CavityShotWatermark` → v3.0

Drops the `INNER JOIN Lots.Lot` and reads `DieCastContribution.ToolCavityId` directly. This is a
**simplification, not a behaviour change** — every contribution row still has a LOT (§3.6), so the
join and the column resolve the same cavity. The `DieCastCounterAnchor` floor (v2.0) is unchanged.
The result must be **byte-identical** to v2.0 across the existing fixtures; assert that as test 1,
or every existing die-cast test passes for a new reason.

### 5.4 `Lots.DieCastLot_Release` — unchanged signature, finally used

No SQL change. The proc **already** accepts `@FinalPieceDelta` as an explicit override of the
derived delta, and `@ScrapLinesJson` for a closing scrap batch. **The release dialog has never
offered either** — its only input is `ReadingInput`. D3 and D5 are satisfied at basket closure by
adding the two controls to `Popups/DieCastRelease`, against a proc that has been ready since v1.1.

### 5.5 Reject readers

`Reject_GetPartMatrix`, `Reject_GetPartMatrixByParty`, `Reject_GetPartMatrixDefects`,
`Reject_SearchDetail`, `Reject_GetPlantSummary`, `Reject_GetNonRejectScrap` all repoint their part
resolution from `re.LotId → Lots.Lot.ItemId` to **`re.ItemId`**, with `LEFT JOIN Parts.Item` and a
NULL bucket labelled *(unassigned part)*.

`Lots.Lot_GetScrapSummary` / `_GetScrapEvents` / `Lot_GetAttributeHistory` are LOT-scoped by
definition and keep `WHERE re.LotId = @LotId` — lot-free rows correctly do not appear on a LOT's
own history.

### 5.6 `Lots.Lot_GetShiftCavityTally` — deleted

The right-hand rail (D11) was its only consumer, and the proc is **wrong anyway**: `RejectSum` is
`SUM(RejectEvent.Quantity)` over the LOT's entire life with no shift predicate, while every label
around it says "this shift" — on a cross-shift basket it over-reports, in the direction that hides
the error (deferred minor #3, 2026-07-29). Reconcile Shift supersedes it with a shift-scoped figure.
Delete the proc, its named query and its entity wrapper, grep-verifying zero references first — the
cleanup `RejectPanel` never got (§7.5).

---

## 6. The screens

Reference rendering: `mockup/diecast_reconcile_mock.html`.

### 6.1 Three tabs become two

`Open Baskets` and `Currently Open` are two views of the same twelve cavities, split by whether a
basket exists — which is why they are named almost identically and why neither explains itself.
The v2.1 breakdown change (row source `Lots.Lot` → `Tools.ToolCavity`) already established the
right shape; this applies it to the rest of the screen.

| Tab | Question it answers |
|---|---|
| **Lot Management** | What is the die doing right now? Open / Release / Void, inline per cavity. |
| **Reconcile Shift** | Settle the shift. |

Every cavity has a row on both tabs whether or not a basket exists. That is what makes "scrap a
cavity with no basket" stop being a special case.

### 6.2 Lot Management

Columns: Cavity · Part · Basket (LOT + opened-at) · Pieces · actions. A cavity with no basket shows
an `Open basket` button with its configured part pre-filled; a `Scrapped` cavity is muted with
actions disabled. Footer: running count, pieces on the die, cavities with no basket, and
**Open all empty cavities** (the bulk-open changeover flow, kept as an action rather than a tab).

### 6.3 Reconcile Shift

**Entry bar and die-wide share one row.** "This entry" (shift picker, press counter reading, and
the existing `DieCast_GetCounterContext` line with its `Fix counter` escape hatch) sits left; the
die-wide block sits right. They are the two things an operator sets *before* reading the grid, and
pairing them buys back the vertical space the grid needs. Both carry a section heading so the pair
reads as two labelled cards rather than a block and an orphan.

**Die-wide block** — permanent named rows for Warm-up (`DC-999`) and Quality test (`107`), plus
`+ Add die-wide scrap`. Entry is in **shots**, with `× N cavities = M pc` stated beside it so
nobody multiplies by twelve in their head, and a summary line stating the total once. D7.

**Per-cavity grid** — one row per cavity:

```
Cavity | Part · basket | Shots | Good | Cavity scrap | Variance | Shift good | Shift scrap
                          842    [830]      12 (1)         0        1,980          48
                       866 − 24
```

- **Shots** carries the die-wide subtraction — `842` with `866 − 24` beneath. Printed on every row
  as *"· die-wide"* it was noise; stated once per row as the figure to account for, it is the
  arithmetic the operator never has to do.
- **Good** is pre-filled, editable, and visibly marked once overwritten. Disabled where there is no
  basket (§3.5).
- **Cavity scrap** is a tappable figure with a line-count chip that expands **in place** to
  reason/qty/remove rows — the existing `ScrapStack` / `ScrapLineRow` structure, collapsed by
  default. On a normal shift eleven of twelve rows are a dim `0`.
- **Shift good / shift scrap** are the shift-to-date context columns. `Shift scrap` is
  `PriorScrapThisShift` (§5.2) — the number the floor asked for.
- **A cavity with no basket is `Pending`, not a variance.** Its row reads
  *"116 shots since 02:10 — credits to the next basket"*, sits **outside** the identity, needs no
  reason, and never holds the submit. It carries an **Open basket** action inline so the operator can
  close the gap where they noticed it rather than switching tabs. Totals gain a separate **Pending**
  figure so the `Shots − Good − Scrap = Unaccounted` equation still balances over the cavities that
  have baskets. Scrap is still recordable against it — that is the *"unless reported otherwise"* path
  (§3.6).
- **Variance** is a figure until it is non-zero, then it is a control (D17). A non-zero variance
  with no disposition reads amber; tapping it expands **the same in-place row the scrap cell uses**,
  carrying a `DieCastVarianceReason` picker and, where the reason demands it, a note. A set
  disposition shows a check chip, an unset one an alert chip. Same interaction, same place, two
  different things to explain — and on a clean shift neither is on screen at all.

  A pre-submit dialog listing every unexplained cavity was considered and rejected: it separates the
  question from the number that provoked it, and on a twelve-cavity die it becomes a second screen
  to reconcile against the first.

**Totals** are written as the equation, not four unrelated tiles:
`Shots 8,776 − Good 8,404 − Scrap 276 = Unaccounted 96`. One Submit writes lines, cavity scrap and
die-wide together (D6).

**Submit is gated on dispositions, never on the numbers.** While any non-zero variance lacks a
reason the button is disabled and says what is missing — *"2 cavities need a reason"* — not
*"variance must be zero"*. The operator is never asked to make the numbers agree, only to say what
happened; and `Unknown` always discharges that (§3.7). A clean shift never sees the gate.

### 6.4 What the right rail's numbers become

| Old rail KPI | Now |
|---|---|
| Shots this shift | Reconcile totals |
| Good parts this shift | Reconcile totals |
| Scrap this shift | Reconcile totals (and now shift-correct — §5.6) |
| Die total shots + `ShotLimit` warning | **Header pill**, amber near the limit |

Die life is the one figure not derivable from anything else on screen, which is why it survives as
a pill rather than being dropped with the rail.

---

## 7. Bugs fixed on the way

Each of these is live today and independently verifiable.

1. **Scrap on a basket released earlier in the shift is silently discarded.**
   `DieCastBody.submitShiftOutput` does `if not r.get("IsOpen"): continue`, then toasts *"Shift
   output recorded."* `DieCastShiftOutput_Record` **v2.1 was explicitly widened to accept exactly
   that case** — its header says so in as many words. The view throws it away before the proc sees
   it. (Known since 2026-09-10, still open.)
2. **Basketless cavity rows collide.** `entries.get("%s" % lotId)` keys on the string `"None"` for
   every cavity without a LOT, so all of them share one draft entry.
3. **Die-wide scrap misses cavities with no basket** (§5.3).
4. **`Lot_GetShiftCavityTally.RejectSum` is not shift-scoped** (§5.6).
5. **`Components/PlantFloor/DieCastEntry/RejectPanel` is dead code** — zero references since the
   2026-07-29 rebuild retired it. Delete.

---

## 8. Type scale — a separate, global change

Agreed at **−15%**. This is an edit to `--mpp-fs-*` in the **Core** stylesheet and it moves every
MPP plant-floor screen, not just die cast. It ships as its own commit.

| Token | Now | ×0.85 | Proposed |
|---|---|---|---|
| `--mpp-fs-xs` | 16px | 13.6 | **14px** |
| `--mpp-fs-sm` | 17px | 14.5 | **15px** |
| `--mpp-fs-base` | 20px | 17.0 | **17px** |
| `--mpp-fs-md` | 22px | 18.7 | **19px** |
| `--mpp-fs-lg` | 26px | 22.1 | **22px** |
| `--mpp-fs-xl` | 32px | 27.2 | **27px** |
| `--mpp-fs-2xl` | 40px | 34.0 | **34px** |
| `--mpp-fs-3xl` | 50px | 42.5 | **42px** |

`sm` is nudged off the arithmetic deliberately: `xs` and `sm` are only 1px apart today, so a
straight ×0.85 rounds **both to 14px** and collapses two steps of the scale into one.

**`--pf-touch-min` rides the scale down, 40px → 34px.** Raised and decided: some terminals are
touch, and Jacques has elected to proceed. Recorded here so the next person reads a decision rather
than an oversight.

**The stylesheet's own comment must be narrowed in the same commit.** It currently reads *"the MPP
plant floor runs on 1920x1200 tablets … Tune from the tablet, not the Designer preview"* — that is
the entire stated justification for the 1.4× scale, and it overstates the estate. Leave it and the
next person tunes it back up citing gloves.

**Out of scope but worth a look after:** anything hard-coded in px inside a view rather than taken
from a token will not move and will read large next to everything that did. The fixed widths
(`--pf-kpi-w`, `--pf-modal-w`, `--pf-tree-w`) become *roomier*, which is the safe direction.

---

## 9. Deliberately out of scope

- **A tolerance on variance.** D4 is show-never-block, on purpose: nobody currently knows how big
  the gaps are, and picking a threshold before seeing real numbers is guessing. Revisit once a few
  weeks of `unaccounted` exist.
- **Auto-booking the residual to a catch-all code.** Balances the books by laundering a measurement
  problem into a quality number.
- **Per-part configuration of the quantity source.** D3's auto-follow makes it unnecessary — a line
  that counts baskets types a number, a line that reads the counter does not.
- **`Tools.Tool.ShotCount` inflation from a typo'd reading.** Open since 2026-09-10 and unrelated
  to this work.
- **The plant-floor die mount/release popup** — its own spec,
  `2026-09-14-plant-floor-die-mount-popup-design.md`.

---

## 10. Verification

**SQL.** New suite `sql/tests/0022_PlantFloor_DieCast/110_CavityScrap.sql`:
lot-free scrap writes and reads back with the cavity's part · `@LotId` and `@ToolCavityId` both
NULL rejects pre-transaction · unmapped cavity writes with `ItemId` NULL and does not throw ·
die-wide fan-out reaches a cavity with no basket · subtractive scrap still requires a LOT ·
`PriorScrapThisShift` is shift-scoped (a cross-shift basket must not over-report) · `ItemId`
backfill leaves every pre-migration row matching its LOT.

**Regression gate.** Full suite green on `MPP_MES_Test` **before** the change, so any failure after
is unambiguously this work — the method that caught the `0081` eligibility case that hand-picked
destinations missed.

**Migration.** Applied to a throwaway DB built at the target's migration state; verify after the
rebuild that **all five indexes are still `ON ps_MonthlyUtc`** (§4.3) — the failure this migration
is most likely to cause is silent and only shows up when partition maintenance next runs.

**Watermark (D14) — the behaviour that must NOT change.** In
`sql/tests/0022_PlantFloor_DieCast/`: with no basketless rows present, `ufn_CavityShotWatermark` v3.0
`ufn_CavityShotWatermark` v3.0 returns **byte-identical** results to v2.0 across every existing
fixture (test 1 — otherwise the whole die-cast suite passes for a new reason) · a cavity whose basket
is released, then runs shots with no basket, then opens a new basket, credits that basket **through**
the gap, because the castings are in it (§3.6) — this is the assertion that pins the rule Jacques
corrected · a basketless cavity writes **no** contribution row · the `DieCastCounterAnchor` floor
still overrides.

**Disposition (D15).** Submit with a non-zero variance and no reason rejects, naming the cavities ·
`Unknown` without a note rejects (`RequiresNote`) · with a note succeeds · the `Warning`-severity
audit row carries cavity, variance and reason · a zero-variance submit needs no disposition.

**`ToolCavity_SaveAll` (D13).** Extend `sql/tests/0014_Tools/020_ToolCavity_SaveAll.sql`: a new row
with no part rejects · an existing row edited to no part rejects · an existing **mapped** row saves
while an unmapped sibling is present and untouched (the regression this design exists to avoid) ·
an untouched unmapped row survives the save with its NULL intact · `Tool_Duplicate` of a die with a
deprecated cavity part still succeeds and still reports the count.

**Reports.** Render `Rejects - Part Matrix`, `Rejects - Transaction Detail` and `Rejects - Plant
Summary` to PDF with at least one lot-free die-cast scrap row present, and confirm the row
**appears** and lands under the right part. This is the check that the `INNER JOIN` finding (§4.2)
is actually closed; a report that renders proves nothing.

**Screens.** Live smoke on the gateway: open a basket, release one with a counted good figure and a
scrap line, reconcile a shift with a cavity that has no basket, confirm prior scrap shows and the
totals balance.

---

## 11. Decisions taken, and what is still open

**Settled 2026-09-14 (Jacques):**

1. **Counter recompute — on blur, with the button retained** as an explicit refresh. Guard the
   commit race per `feedback_ignition_input_deferupdates_commit_race` (`deferUpdates: false` on the
   reading field, or the gateway read fires against an empty value).
2. **Basket release does not show die-wide context.** Release is one cavity's closing number;
   die-wide belongs to the shift entry.
3. **`Lots.Lot_GetShiftCavityTally` is deleted** with the rail (§5.6).
4. **D13 ships in this spec, as its own commit** — so the Config Tool change can be reverted
   without touching the plant floor.

**Still open:**

5. **When does `Tools.ToolCavity.ItemId` become NOT NULL at the column level?** Available once the
   legacy set is drained (§12) and `Tool_Duplicate` has an answer. `RejectEvent.ItemId` may follow
   it, in that order, never before — a downstream constraint must not outrun its upstream one.

---

## 12. Adjacent, not in this spec — the cavity-to-part mapping reconciliation

**Measured 2026-09-14: `MPP_MES_Prod` has ZERO unmapped cavities** across all 11 loaded dies
(`sql/scratch/2026-09-14_cavity_part_mapping_evidence.sql`, set B returned no rows). The unmapped
set on Dev is entirely test fixtures. **So there is no backlog to drain, and D13 is purely
preventive rather than remedial.**

What remains is a *standing* check rather than a one-off reconciliation: MPP is still loading dies —
the eleven in prod are a partial migration against a die-shots report carrying 343 rows — so the
evidence script should be re-run after each batch. Kept below because the ranking is the reusable
part, and because a future batch may arrive incomplete.

**Rank the evidence; do not lead with names.** Name matching is the weakest signal available and the
one most likely to produce confident wrong answers — a confirm/deny list where a third of the rows
are plausible guesses gets rubber-stamped by row 40.

| Rank | Basis | Strength |
|---|---|---|
| 1 | **LOT history** — `Lots.Lot` carries `ToolId` + `ToolCavityId` + `ItemId`, so what a cavity has actually cast is *recorded* | near-certain |
| 2 | **Sole eligible part** — the die is mounted at press P and exactly one part is eligible there with a DieCast route | strong |
| 3 | **Sibling consensus** on a **single-part** die | strong; **unsafe on a family die** |
| 4 | Tool name ↔ part description tokens | a guess, and must be labelled one |

**The family-die caveat is the important one.** `6MA-A` runs 6 distinct parts across 12 cavities and
`6MA-B` runs 4; there cavity-to-part *is* the configuration, and a wrong map books castings under
the wrong part number — a traceability defect, not a cosmetic one. On a family die, offer rank-1
evidence only and leave the rest blank.

**Shape:** a script emitting `die · cavity · current part · suggested part · basis · confidence`
with blanks where nothing credible exists; Jacques marks confirm/deny; it generates an idempotent
script applying confirmed rows **through `Tools.ToolCavity_SaveAll`** — not raw `UPDATE`s — so the
change carries validation and audit rows, the discipline
`sql/scratch/2026-09-03_import_prod_tools_to_dev.sql` used for the prod tool import. Lives in
`sql/scratch/` until confirmed, as `seed_vision_app_ip.sql` did.

---

## 13. Deferred — remodel the reject reports for the part/die dimension

**Not in this build.** D16 puts `ToolId` on the fact row so the data is there; nothing in this spec
*reads* it.

Every reject report is keyed on **part**: `Reject_GetPartMatrix`, `_GetPartMatrixByParty`,
`_GetPartMatrixDefects`, `Reject_SearchDetail`, `Reject_GetPlantSummary`. That was right when a part
implied a die. It no longer is — prod runs several dies producing the same part number, identified
only by their code, and per-die `ShotCount` / `ShotLimit` make "which die is producing the scrap" a
question with an operational answer (pull the die, not the part).

So the remodel is: die as a first-class reporting dimension alongside part — a per-die reject rate,
a die column on the transaction detail, and a defect profile per die so a failing die separates from
a difficult part. Its own spec, its own report renders, after this ships.

Recorded here because the **column has to land now**: adding `ToolId` to a partitioned table later
is the same drop-and-rebuild cost as §4.3, and doing it twice is the avoidable version.
