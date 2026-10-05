# Die cast shift reconciliation — three scenarios on Dev

**Date:** 2026-10-04, corrected 2026-10-05
**Seed:** `sql/scratch/2026-10-04_recon_scenarios_seed.sql` — **applied to `MPP_MES_Dev`**
**Teardown:** `sql/scratch/2026-10-04_recon_scenarios_teardown.sql` — run once for real on 10-05, then re-seeded
**Screen:** `/shop-floor/die-cast/reconcile` (also reachable from the Supervisor Dashboard tile)
**Spec:** `docs/superpowers/specs/2026-09-21-diecast-shift-reconciliation-design.md`

Three scenarios are seeded and waiting. Every number below was verified through the
real read procs and through `DieCastShiftReconciliation_Save @PreviewOnly = 1`, so
each scenario is known to pass every blocking gate before you touch it — if the
screen refuses one, the refusal is the screen's, not the arithmetic's.

This closes runbook precondition 2 (`notes/2026-10-01_prod-release-runbook-diecast-zebra-bundle.md`
§3.0) only once a human has actually clicked through it. That part is yours.

---

## Before you start

- **The reconciliation needs an AD sign-in.** The screen gates on
  `Common.Session.isElevated` and dispatches the elevation popup. Sign in as
  **`admin`**, which resolves to `AppUser 22 / JGP`. The banner should then read
  *"Reconciling as JACQUES (JGP)"*.
- **The operator on every seeded entry is `JD` (John Doe)**, deliberately not you —
  the "entered by" on each card has to be somebody else for the screen to be
  telling you anything.
- **Perspective trial.** The 2026-09-30 smoke died when the trial expired. Reset it
  before starting; I could not check this from outside the gateway.
- **Nothing else on Dev was touched.** Every LOT created is `777000xx`; the only
  pre-existing row the seed modified is `DMO125.ShotCount` (13,894 → 23,804, because
  a recorded reading advances die life exactly as the live path does).

### Verified state as seeded

| | Press | Die | Shift | Landing status | Recorded | Reading |
|---|---|---|---|---|---|---|
| 1 | Machine 11 | DMO125 | 10-04 Weekend First | `EntryRecorded` | 12 rows, 19,960 pcs | 9910 |
| 2 | Machine 202 | DM0144 | 10-04 Weekend First | `ReleasedNoShiftEnd` ⚠ | 3 rows, 1,450 pcs | — |
| 3a | Machine 305 | DMO126 | 10-01 First Shift | `NoEntry` | nothing | — |
| 3b | Machine 304 | DMO145 | 09-24 Third | **not on the list** | 2 rows, 600 pcs | — |

The dashboard tile counts **exactly one** alerting row: scenario 2. Everything else
in the seven-day window is `NoEntry` with `IsAlerting = 0`.

---

## Scenario 1 — an operator got it wrong and a supervisor has to fix it

**Machine 11 · DMO125 · 10-04 Weekend First (07:00–15:00)**

The shift ran 991 shots on a 12-cavity die and made 12 baskets of 953. One operator
entry at 14:55 recorded all of it, with **three errors in that one entry**:

1. the counter reading typed **9910** instead of 991 — so die life ran away by 8,919;
2. basket **77700012** typed **9530** instead of 953;
3. the 36 test parts recorded with **no QAS approver** — the sheet has a signature,
   nobody keyed it.

And basket **77700002** holds 900, not 953, but it has **already been counted at
Trim Out** — so its count must stand while its production still gets corrected.

### What to type

Reason **Recorded numbers did not match actual**. Then:

| Field | Actual |
|---|---|
| Total shots | **991** |
| Good shots | **956** |
| Warm-up shots | **35** |
| Reject line | code **008 Test Part**, part **All**, qty **36**, approved by **JGP** |
| Every one of the 12 baskets | **953** |

The arithmetic the screen checks: 991 = 956 + 35, and 956 × 12 − 36 = **11,436** =
12 × 953. Leave the warm-up line alone; warm-up comes from the Warm-up shots field,
not from a reject row.

### What the confirmation should say

- **Die life** `DMO125: 23,804 → 14,885 (−8,919 shots)` — **amber**, and the tick box
  *"I have checked this reduction against the actual count"* must appear and must
  gate the confirm button.
- **Production reduced** 8,577 pieces off `77700012`, whose count goes `9,530 → 953`.
- **Production added** 53 pieces.
- **Counts left standing** `77700002` — *"Counted at Trim Out 2026-10-04 18:00"*,
  count stays 900, production still recorded.
- **1 count corrected, 1 count standing.** Not 11 of each: the nine clean baskets
  have a zero gap and are correctly filtered out of the list.
- 24 scrap rows behind the scenes — see below.

### The thing to look at hardest

Re-approving the test parts writes **−3 unapproved and +3 approved on each of the 12
cavities**: 24 rows to move an approver onto 36 pieces that were already recorded
correctly. That is `Save` §10 working as designed — the scrap grain is per cavity
*and per approver*, so a typed line that differs only by approver cannot meet the
recorded row, and the only honest way to change an approver without editing history
is to cancel and re-add. The net on every reject report is zero change to quantity
and a correct approver.

It is right, and it will look like churn in the Transaction Detail. **Worth deciding
whether the confirmation should say so in words** — something like *"36 test parts
re-recorded against JGP (no quantity change)"* — rather than listing 24 deltas.

### After saving

Re-open the same shift. It should read *Reconciled — JGP*, and a second save with
the same numbers must refuse with **"Nothing to save: the record already matches
actual."** `DMO125` should sit at **14,885**, which is the original 13,894 plus the
991 shots the shift really ran.

---

## Scenario 2 — the shift-end number was never entered, caught mid-next-shift

**Machine 202 · DM0144 · 10-04 Weekend First**, reconciled while **Weekend Second is
still open**. Not a simulation of "mid-way through the following shift" — it
literally is one.

This is Machine 202's real failure shape from the week the feature was designed
against, and **no SQL test covers it.** Three baskets were released during the shift
*with counts and no counter reading*, so:

- the pieces are on record (1,450) and correct;
- both watermarks stayed at 0 and die life never moved;
- the landing row is amber, **`Released, no shift-end number`** — a positive finding,
  not an absence.

Seeded:

| LTT | State | Pieces | Note |
|---|---|---|---|
| `77700021` | Good, Warehouse | 500 | released 09:30, no reading |
| `77700022` | Good, Warehouse | 500 | released 12:00, no reading |
| `77700023` | Good, Warehouse | 450 | released 14:30, no reading |
| `77700024` | **Open**, at the press | 0 | opened 14:40, never credited |

### What to type

Reason **Shift not entered**.

| Field | Actual |
|---|---|
| Total shots | **1620** |
| Good shots | **1600** |
| Warm-up shots | **20** |
| Reject line | **008 Test Part**, **All**, qty **10**, approved by **JGP** |
| `77700021` / `77700022` / `77700023` | **500 / 500 / 450** |
| `77700024` | **140** |

1,600 × 1 − 10 = **1,590** = 500 + 500 + 450 + 140.

### What the confirmation should say

- **Die life** `DM0144: 2,068 → 3,688 (+1,620)` — an addition, so **no tick box**.
- **Production added** 140 pieces, to `77700024` only. The three released baskets
  have a zero gap: their counts were right all along; only the shift's *reading* was
  missing. That asymmetry is the whole point of this scenario.
- Warm-up +20 and test parts +10, both new.
- No reduction, no count corrections, no new LOTs.

`77700024` stays **Open** and keeps accumulating into Weekend Second — the
reconciliation credits it 140 for the shift that is being settled and does not touch
the one that is running. Worth confirming on the live die cast screen afterwards
that its Weekend Second proposal is unaffected.

### The spanning basket — corrected 2026-10-05, and where it actually bites

An earlier draft of this note seeded a probe basket (`77700020`) opened in the
previous shift and released in the next, spanning Weekend First with no event
inside it, and reported that it was absent from the LOT list. **That seed was
physically invalid and has been removed.**

DM0144 has **one** cavity, and `Lots.DieCastLot_Open:106-109` enforces one open
basket per `(Tool, ToolCavity)`. A basket that spans the whole shift on a
single-cavity die therefore *is* the only basket on that cavity — it cannot coexist
with the three releases above. The guard lives in the proc, not in a unique index,
so the raw INSERT walked straight past it and produced a state the plant cannot
reach. Dev has been torn down and re-seeded without it.

**The underlying mechanism, confirmed (Jacques, 2026-10-04).** A basket can span an
entire shift or even two — but the shift-end entry credits the open basket on
*every* cavity: `DieCast_GetShiftOutputBreakdown` proposes `reading − cavity
watermark` per cavity (lines 211-231) and `DieCastShiftOutput_Record` writes it. So
a spanning basket normally **does** carry a contribution in each shift it spans, and
`_ListLots` finds it through its `rec` branch. No hole.

**The hole only opens where the two conditions meet: a MULTI-CAVITY die whose
shift-end entry was missed.** Then one cavity's basket can span the shift while
other cavities cycle and release, and nothing ever credits the spanner — the entry
that would have done it is the entry that was missed. Its `CreatedAt` is in an
earlier shift, so neither branch of `_ListLots` offers it, and the arithmetic gate
forces the issue regardless of how the sheet records partials: the shift's total
good is `good shots × cavities − no-good`, which includes that cavity's production,
and no LOT row can absorb it. Measured refusal shape, from the invalid seed before
it was removed:

> *"LOT list totals 1590; actual total good is 1770 (1780 good shots x 1 - 10
> no-good). One of them has a typo."*

A typo message for a basket the list never offered. The team lead's only way through
is to already know to type the LTT into the entry bar.

**This is not seeded yet** — it needs its own scenario on its own press (a
multi-cavity die with a missed shift-end, e.g. Machine 11 on a shift other than the
one scenario 1 uses). Worth building only if you agree the combination is real;
see the question at the end.

## Scenario 3 — nobody noticed for days

### 3a · Machine 305 · DMO126 · 10-01 First Shift (4 days back) — reachable

Nothing was recorded at all. The landing row reads **`No entry`** in neutral grey,
not amber, because the MES cannot know whether the press ran — and the screen opens
with the explicit empty state rather than looking like a failed load.

Reason **Shift not entered**. Every basket is created from paper:

| Field | Actual |
|---|---|
| Total shots | **1200** |
| Good shots | **1185** |
| Warm-up shots | **15** |
| Reject line | **008 Test Part**, **All**, qty **5**, approved by **JGP** |
| New LTT | **`77700031`** qty **600** |
| New LTT | **`77700032`** qty **580** |

> **Use those two LTT numbers.** The teardown finds minted LOTs by the `777000`
> prefix; a LOT created under any other number has to be deleted by hand.

Expect: **2 LOTs created and released to Warehouse**, die life `1,408 → 2,608
(+1,200)`, 1,180 pieces added, no reduction.

> 3a sits four days back on purpose. The window is seven days, so a shift picked at
> five or six silently drops off the screen after a day of slippage and then looks
> like the 3b ceiling instead of the case it is meant to show. 10-01 stays reachable
> until 10-08; past that, re-point `@S3a` in the seed.

**The open question here is the two new baskets.** They are minted and released to
Warehouse **today**, four days after the castings were made — and in a real plant
those baskets went through trim days ago. D4 says a retroactively created LOT is
released to default storage exactly as the live path does, and that is precisely
what happens, but five days later it puts two baskets of stock into the warehouse
that are not physically there. Same mechanism as same-day, different consequence.
Worth a decision: leave it (someone moves them later), release them somewhere
else, or accept the inventory drift as the cost of having the production record.

### 3b · Machine 304 · DMO145 · 09-24 Third Shift (10 days back) — **not reachable**

Seeded in the same `ReleasedNoShiftEnd` shape as scenario 2: two baskets released
with counts and no reading, 600 pieces, a genuine finding.

**It does not appear anywhere on the screen.** Not the landing list, not the
dashboard tile, no indication the shift exists. Measured:

```
ListShifts(cell 25, @Days = 7)   -> 21 rows, oldest 09-27 Weekend Third, 20137 absent
ListShifts(cell 25, @Days = 14)  -> 42 rows, 20137 present: ReleasedNoShiftEnd, 600 pcs
```

The SQL is fine. The ceiling is in the view:
[`DieCastReconcileLanding/view.json:47`](../ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/DieCastReconcileLanding/view.json#L47)
calls `listShifts(value, 7)` with a **literal 7**, ignoring the `view.custom.days`
property declared immediately above it, and there is no date-range control on the
screen. The tile is the same seven days.

I don't know whether seven days is a ruling or a default that got typed. It matters
because the feature's founding evidence — Building 2, 2026-09-16 — was reconciled on
**2026-09-21, five days later**, and a weekend plus a Monday of nobody looking puts
you past seven. If seven is deliberate, 3b is correct behaviour and the only gap is
that a finding disappears silently rather than saying *"older than 7 days — ask
engineering"*. If it isn't, the fix is one literal and a control.

---

## Cleaning up

```bash
sqlcmd -S localhost -d MPP_MES_Dev -E -C -i sql\scratch\2026-10-04_recon_scenarios_teardown.sql
```

Runs every delete inside a transaction and rolls back, printing the counts. Read
them, then set `@Commit = 1` at the top of the script and re-run. Previewed against
the seeded state it reports **18 LOTs, 17 contributions, 24 reject rows, 1 production
event**, restores all four dies' `ShotCount`, and leaves zero `777000xx` LOTs. It has
been run armed once already, on 10-05, to clear the invalid spanning-basket seed —
so the round trip is proven, not just previewed.

It also removes whatever the reconciliations wrote — headers, moves, counter anchors,
compensating rows, count corrections, minted LOTs. Audit rows are deliberately left:
they record things that really happened on this gateway, and deleting audit history
to tidy a test is the wrong habit.

---

## Summary of what came out of this

**Nothing arithmetically wrong was found.** All three scenarios pass every blocking
gate and produce exactly the plan the spec describes, including the three-error save,
the firm count lock, the compensating negative, and the per-approver scrap grain.

Four things to rule on, none of them a bug in the arithmetic:

1. **The spanning basket on a multi-cavity die with a missed shift-end.** The
   sharpest of the four, and the one that needs your yes before it is worth seeding.
   Spanning is real and the shift-end entry normally credits the spanner — so the
   hole needs both conditions at once, and when they meet, `_ListLots` offers
   neither branch and the arithmetic gate reports a typo. Is a multi-cavity press
   missing its shift-end while one cavity's basket runs long a combination you
   expect to see? If yes, this wants a scenario 2b and probably a fix to the read.
2. **The seven-day landing ceiling** (3b). A real finding is unreachable from the
   screen and says nothing when it is. One literal, plus whether a control is wanted.
3. **Retroactive LOTs released to Warehouse days later** (3a). Specified behaviour
   whose consequence changes with elapsed time.
4. **24 scrap rows to add one approver** (1). Correct, and unreadable in the
   confirmation as currently worded.

### Correction log

- **2026-10-05.** The spanning-basket probe `77700020` was seeded on a single-cavity
  die alongside three same-cavity releases — two open baskets on one cavity, which
  `Lots.DieCastLot_Open` forbids and only a raw INSERT could produce. Removed; Dev
  torn down and re-seeded. The finding survives in a narrower and better-founded
  form (item 1 above), thanks to Jacques's correction that the shift-end entry
  credits the open basket on every cavity.
- **2026-10-05.** Scenario 3a moved from 09-29 to 10-01 so it does not drift out of
  the seven-day landing window mid-exercise and masquerade as the 3b ceiling.
