# Die Cast Shot-Reading Chain — Design Spec

**Date:** 2026-09-09
**Status:** Draft — awaiting Jacques review
**Author:** Blue Ridge (with Claude)
**Arc / Phase:** Arc 2 (Plant Floor) — Die Cast per-cavity lifecycle correction. Replaces the die-wide additive shot count with a per-cavity reading watermark.
**Origin:** Day-one deployment feedback, 2026-09-09 (Die Cast). Item 2 of four.
**Supersedes / corrects:** `Workorder.DieCast_GetShiftOutputBreakdown` v1.3's additive `@GrossShots` premise; the `EditableBlock` visibility rule in `CavityLotRow` that blanks closed baskets.
**Builds on:** migration `0072` (`Tools.ToolCavity.ItemId` — the configured cavity-to-part map), committed `18758272`.

> ⚠️ **Prod went live 2026-09-09.** This changes how a number the operator types is interpreted. Section 9 (Cutover) is not optional.

---

## 1. Motivation

### 1.1 What the operator reports

> *"When operators record shift output they enter this output at the end of a shift, BUT they may have opened and closed multiple lots from the same cavity during that time… right now, it looks and reads like shot counts apply uniformly across all open lots, when in reality, 4 of the 12 cavities may only have 3/4 of the shots the others have due to lot change."*

### 1.2 What the system does today

`Workorder.DieCast_GetShiftOutputBreakdown` v1.3 gives **every open cavity lot the entered number verbatim**:

```sql
CASE WHEN lo.IsOpen = 0 THEN ISNULL(p.PriorGood, 0)
     WHEN ISNULL(@GrossShots, 0) < 0 THEN 0
     ELSE ISNULL(@GrossShots, 0)
END AS ProposedGood
```

Its header justifies this: *"the operator counts shots SINCE THEIR LAST ENTRY … so the number handed to this proc is already the increment for this recording."*

### 1.3 Why that is not wrong, but is incomplete

Both halves of what MPP told us are true:

- there **is** an incrementing press counter, **reset at end of shift**; and
- operators **do** record output once, at end of shift.

Given one entry per shift, *"shots since my last entry"* and *"the counter reading"* are **the same number** — which is why v1.3 works, and works for almost every cavity almost every shift. It is correct for any cavity that ran one basket all shift.

It has **no term at all** for a cavity that rolled its basket mid-shift. That case is not mis-computed; it is unrepresentable. v1.3 was the right fix for the wrong model: it cured a symptom by deleting the only place the system knew cavities could diverge.

### 1.4 We are improving on the paper process, not restoring parity with it

Production sheet **DCFM-2077** and the basket tags show the die-wide number written onto **every** cavity's tag: one column group is `865` across the board, the next `490` across the board. Nobody counts loose castings per basket per shift — those numbers are computed, not observed.

So **the paper process is itself uniform fan-out**, and it has the identical blind spot. This design does not reproduce what the paper does; it corrects it.

**Consequence, and it must be said to MPP before go-live:** after this change, MES basket totals will **stop matching** what the old sheet would have produced for any shift in which a cavity rolled over. That divergence is the feature. If nobody warns them, it reads as a bug.

### 1.5 Evidence base

| Source | What it establishes |
|---|---|
| Basket tag `10627547` (`6MA EX 5`, cav `Db`, cast 9/4) | A basket is an **additive ledger across shifts**: five entries `294 + 865 + 796 + 490 + 1063 = 3508`, exactly the container quantity. Each line is signed by the D/C operator. Machine # is recorded once per tag. |
| Sheet `DCFM-2077 Ver. 5` | One press, one shift, **four part numbers** off one family die; grouped by part with a **Sub-Total per part** and a **Grand Total**. Quantities repeat across cavities within a group. |
| Jacques, 2026-09-09 | Press counter exists and **resets at end of shift**. Cavities and parts share naming (`6MA EX 1 Db`). A cavity may be out of service (`6MA EX 1` cavity `a`). Scrap is recorded on a separate paper form, extensively, at end of shift. |

---

## 2. Decisions locked (from brainstorming)

1. **Approach A — shot-reading chain.** The operator types the **press counter reading**; the system derives every credit. Per-cavity good-parts entry (approach B) was considered and rejected: with loose castings there is no observed per-cavity count, so B moves the same arithmetic onto the operator while losing the die-wide shot number that die life depends on.
2. **The watermark belongs to the CAVITY, not the basket.** If it lived on the basket, a gap between releasing one and opening the next would lose shots. On the cavity, the successor inherits the watermark whenever it is opened — even an hour later — so shots cannot leak.
3. **Release captures a reading; it does not capture scrap.** Scrap is entered at end of shift on the shot-entry tab, matching the paper scrap form.
4. **Because of (3), closed-this-shift baskets must remain scrap-editable at shift end.** They are already returned by the breakdown proc; today they render blank.
5. **A reading may never go backwards.** Validate against the highest reading already recorded for that die in that shift.
6. **`Tools.Tool.ShotCount` increments by the DELTA, not the reading.** Today `ShotCount += @GrossShots` is correct precisely because `@GrossShots` is an increment. Changing the input to a reading without changing this line would inflate die life on every second entry in a shift.
7. **`Lots.DieCastLot_Release` does NOT touch `ShotCount`.** Release deals in *pieces*; shift-output deals in *shots*. A release partitions a shift's shots between two baskets on one cavity — it does not create shots. Making release bump the counter would double-count.
8. **Rows are driven by CAVITY, not by LOT.** A Closed or Scrapped cavity has no LOT and today produces no row at all, which is why its state is invisible on the die cast screens.

---

## 3. The model

### 3.1 The chain

Let `C(t)` be the press counter: `0` at shift start, monotonically increasing, reset at shift end.

Every cavity carries a **credited-through watermark** `W` — the reading at which it was last settled. It starts each shift at `0`.

```
credit(basket) = R − W(cavity)      where R is the reading being entered
```

After crediting, `W(cavity) := R`.

When a basket is released, the reading typed does **double duty**: it closes the outgoing basket and becomes the starting watermark of the next basket on that cavity.

A cavity that never rolled has exactly one segment, `0 → R`, so it is credited `R` — **precisely today's behaviour**. Uniform fan-out is not replaced; it becomes the special case where nothing rolled.

### 3.2 Worked example — the 4-of-12 case

12-cavity die, shift-end reading `2000`. Cavity `Db` rolled at reading `1450`.

| Cavity | Segments | Credit |
|---|---|---|
| `6MA EX 1 Db` | `0→1450`, `1450→2000` | basket 1 = **1450**, basket 2 = **550** |
| `6MA EX 1 Dc` | `0→2000` | **2000** |
| `6MA EX 1 Da` (scrapping) | `0→2000`, no basket | **2000 scrap** |
| `6MA IN 5 Db` | `0→2000` | **2000** |

Die shot count increases by **2000 exactly once**, from the shift-end reading — independent of how the parts split across baskets.

### 3.3 Two watermarks, one column

Both derive from the same recorded reading:

| Watermark | Derivation | Consumer |
|---|---|---|
| **Cavity** | `MAX(ShotCounterReading)` over contributions this shift for lots on that `ToolCavityId`, else `0` | per-basket credit |
| **Die** | `MAX(ShotCounterReading)` over **all** contributions this shift for that `ToolId`, else `0` | `Tools.Tool.ShotCount` increment |

In the worked example: at release the die watermark goes `0 → 1450` (+1450 shots); at shift end `1450 → 2000` (+550). Die total `2000`. Meanwhile the untouched cavities still have watermark `0` and are credited the full `2000` each. Both are right, from one column.

---

## 4. Data model

### 4.1 New column

```sql
ALTER TABLE Workorder.DieCastContribution ADD ShotCounterReading INT NULL;
```

`Workorder.DieCastContribution` is already the ledger — one row per handwritten tag line (`Id, LotId, ShiftId, PieceDelta, AppUserId, TerminalLocationId, EventAt, CellLocationId`). The reading is a property of the entry, so it belongs on the entry.

**NULL means "recorded before this change"** (see §9). New rows written by the shift-output and release paths SHALL populate it.

**No new table.** Both watermarks are derivable, so a materialised watermark table would be a second source of truth for something already recorded.

### 4.2 Release must always write a contribution row

Today `DieCastLot_Release` writes a `DieCastContribution` row only when `@FinalPieceDelta > 0`. Under this model the release **anchors the cavity watermark**, so it SHALL write a row unconditionally — `PieceDelta` may be `0` (the table's `CK_DieCastContribution_DeltaNonNeg` (`PieceDelta >= 0`) permits it). A zero-piece row is honest: *"at reading 1450 this basket closed, contributing 0 further pieces."*

Without this, a cavity released with no new production leaves its watermark at the previous value and the next basket is over-credited.

### 4.3 Helper function

```sql
Workorder.ufn_CavityShotWatermark(@ToolCavityId BIGINT, @ShiftId BIGINT) RETURNS INT
Workorder.ufn_DieShotWatermark   (@ToolId BIGINT,       @ShiftId BIGINT) RETURNS INT
```

Both `ISNULL(MAX(ShotCounterReading), 0)`. Inline TVF or scalar — scalar is fine at this cardinality (12 cavities). Single definition of the rule, per the "no business logic in Python" convention.

---

## 5. Procedure changes

### 5.1 `Workorder.DieCast_GetShiftOutputBreakdown` (read)

**Signature:** `@GrossShots INT` → `@CounterReading INT`. Renamed, not overloaded — the meaning changed and a silently-reinterpreted parameter is exactly how §1.3 happened.

**Row source changes from LOT-driven to CAVITY-driven.** Today:

```sql
FROM Lots.Lot l WHERE l.ToolId = @ToolId AND (Open OR contributed this shift)
```

Becomes: `FROM Tools.ToolCavity` (all non-deprecated cavities of the tool) `LEFT JOIN` the open lot, `LEFT JOIN` lots closed this shift. One row per physical cavity, always.

**New / changed result columns** (appended last; positional `INSERT-EXEC` consumers exist):

| Column | Meaning |
|---|---|
| `CreditedThrough` | the cavity's watermark — what the operator sees as context |
| `NewShots` | `@CounterReading − CreditedThrough`, floored at 0 |
| `CavityStatusCode` | `Active` / `Closed` / `Scrapped` |
| `ConfiguredItemId`, `ConfiguredPartNumber` | from `ToolCavity.ItemId` (0072) — lets a cavity with no LOT still name its part |

`ProposedGood` becomes `NewShots` for an open basket; a basket closed earlier this shift keeps `PriorGoodThisShift` and is **not** re-credited.

### 5.2 `Workorder.DieCastShiftOutput_Record` (write)

- `@GrossShots` → `@CounterReading`.
- Reject `@CounterReading < ufn_DieShotWatermark(@ToolId, @ShiftId)` **pre-transaction**, with a message naming both numbers.
- Persist `ShotCounterReading = @CounterReading` on every contribution row written.
- `ShotCount += (@CounterReading − ufn_DieShotWatermark(...))` — the delta, per decision 6. Replaces `ShotCount = ShotCount + @GrossShots` at `R__Workorder_DieCastShiftOutput_Record.sql:196`.
- Accept scrap lines for baskets **closed this shift** as well as open ones (decision 4). The additive-`RejectEvent` block already handles a closed lot; the guard that every submitted lot is *"an open basket on this tool"* must widen to *"open, or closed this shift with a contribution"*.

### 5.3 `Lots.DieCastLot_Release` (write)

- New `@CounterReading INT` param.
- `@FinalPieceDelta` becomes **derived, not supplied**: `@CounterReading − ufn_CavityShotWatermark(cavity, @ShiftId)`. Keep the parameter for an explicit operator override (§8, E2) but default to the derived value.
- Same backwards-reading rejection as §5.2.
- Always write the contribution row (§4.2), carrying the reading.
- Still does **not** touch `ShotCount` (decision 7).
- `@ScrapLinesJson` is retained but unused by the new UI (decision 3); not removed, so the exception path survives.

---

## 6. UI changes

### 6.1 Record Shift Output

- Field relabelled **"Press counter reading now"** (was *"Shots this entry (die-wide)"*). This is the single most important change — the label is what makes the number unambiguous.
- Each cavity row shows **`credited through N`** and **`new shots N`** alongside Good. The operator never subtracts; they can see that the system already did.
- **Closed-this-shift baskets render their numbers and accept scrap.** Today `CavityLotRow`'s `EditableBlock` binds `position.display` to `view.params.isOpen`, so a closed row shows the cavity name and *nothing else* — present enough to look like an omission, empty enough to teach operators not to trust the screen.
- **Closed / Scrapped cavities appear**, labelled with their configured part (0072), with a scrap quantity field and no basket.
- **Per-part sub-totals and a grand total**, matching DCFM-2077's shape.

### 6.2 Lot Release

Operator picks the cavity's basket, types the **current counter reading**, and the screen states the consequence before they commit:

> reading 2000 · credited through 1450 · **this basket gets 550** · basket total 3508

Confirm → LTT prints → offer to open the successor basket on that cavity. No scrap on this tab.

### 6.3 Not in this spec

The `deferUpdates` / gateway-scope commit race on `GrossShotsInput` and `ShotLossQtyInput` was already fixed in `ab8e3aa6`. The scrap-row layout was fixed in the same commit.

---

## 7. What falls out for free

These need no special-casing; they are just "how many segments does this cavity have":

- A basket carried in from the previous shift — the counter reset, so its watermark is `0`.
- Multiple rollovers on one cavity in a shift — N segments.
- Cavities rolling at different times — independent chains.
- A basket released with none reopened before shift end — the cavity's last segment simply stays closed.
- Overflow-forced rollovers — the same event as any other release.
- Multiple shift-output entries in one shift — each advances the watermark.

---

## 8. Edge cases requiring a decision

| # | Case | Recommendation |
|---|---|---|
| **E1** | **Gap:** cavity runs Active with no basket for a span. | Those shots land on the next basket opened, over-crediting it. Recommend: warn at open when `W(cavity) < die watermark`, showing the gap, and let the operator accept or adjust. Do **not** silently absorb. |
| **E2** | **Late release:** the basket was physically swapped at 1450 but released in the MES at 1900. | The operator types the remembered reading, not "now". Keep `@FinalPieceDelta` as an override for when they cannot. This is the model's main exposure — a late release mis-splits between two baskets **on that one cavity**, and nothing on screen reveals it. |
| **E3** | **Reading goes backwards** (typo, or an entry made after the end-of-shift reset). | Hard reject with both numbers in the message. A supervisor-elevated override is possible but should be deferred until MPP shows it is needed. |
| **E4** | **Counter reset mid-shift** (power loss, maintenance). | Presents as E3. Needs an explicit "counter was reset" action that re-anchors the die watermark to 0 without discarding recorded contributions. **Open — see §11.** |
| **E5** | **Die moved to another press mid-shift.** | The counter belongs to the press, not the die; baskets follow the die. The chain breaks. Recommend: treat a `ToolAssignment` change as a mandatory reading capture that closes the chain on the old press. **Frequency unknown — see §11.** |
| **E6** | **Two dies on one press in a shift** (changeover). | The counter keeps climbing across the changeover, so the incoming die's first basket would inherit the outgoing die's shots. Same fix as E5: capture a reading at changeover. |
| **E7** | **Two terminals entering for the same press concurrently.** | Readings are monotonic per (die, shift), so the second entry's delta is naturally correct. The existing peer-tally refresh already surfaces the other terminal's writes. No extra guard needed beyond E3's rejection. |
| **E8** | **Die-wide shot loss vs. baskets closed earlier in the shift.** | Today `@ShotLossJson` fans an additive `RejectEvent` across every currently-**Open** lot. Strictly, a loss should charge whichever cavities were open *when it happened*, which may include a basket since closed. Recommend keeping current behaviour for now and flagging it, rather than inventing time-ranged loss attribution. |
| **E9** | **Nobody records at shift end.** | The counter resets and that shift's production is lost — true today as well. Out of scope here; belongs with the existing shift-boundary reconcile work. |

---

## 9. Cutover (prod is live)

`ShotCounterReading` is `NULL` on every pre-existing row, so `ISNULL(MAX(...), 0)` reads every cavity's watermark as `0`. **The first entry after deploy would credit each open basket the full counter reading, double-counting anything already recorded in that shift.**

Recommended: **deploy at a shift boundary**, so every cavity legitimately starts at `0` and no in-flight shift spans the change.

If a boundary deploy is not possible, the migration must backfill `ShotCounterReading` for contributions in any **currently open** shift. There is no way to recover the true reading retrospectively, so the honest backfill is a running sum of `PieceDelta` per cavity within the open shift — correct for the common case (one basket, one entry) and wrong exactly where the old model was already wrong.

A third option — refuse entries until the shift rolls — is cleaner but blocks the floor. **Jacques's call.**

---

## 10. Testing

New suite `sql/tests/0022_PlantFloor_DieCast/080_ShotReadingChain.sql`:

1. Single basket, one entry — credited the full reading (proves the v1.3 case still holds).
2. Mid-shift release then shift-end entry — `1450` / `550` split, per §3.2.
3. Two rollovers on one cavity — three segments.
4. Twelve cavities, one rolled — 11 credited `R`, 1 split.
5. Basket carried across a shift boundary — watermark resets to `0`.
6. `ShotCount` increments by the **delta**: two entries in one shift total the final reading, not the sum of readings.
7. Backwards reading rejected, with nothing written.
8. Release with no production — `PieceDelta 0` row written, watermark still advances.
9. Closed-this-shift basket accepts scrap at shift end.
10. Closed / Scrapped cavity appears in the breakdown with its configured part and no basket.

Fixtures must be **self-contained** — see the pre-existing `Msg 515` failure in three DieCast suites (`task_a2b8d904`), where fixtures hunt for seed data that a `-SkipDemoSeed` build does not contain.

---

## 11. Open questions

1. **E4 / counter reset mid-shift** — does it happen, and is there a recognised procedure today?
2. **E5 / E6 — die moved or changed over mid-shift.** How often? If routine, reading capture at changeover is mandatory work, not a guard.
3. **§9 cutover** — boundary deploy, backfill, or block-until-roll?
4. **E2 late release** — is "remember the reading at the swap" realistic, or should the UI default to *now* and accept the error?
5. Should a shot-loss entry also carry a reading, so losses can later be time-attributed (E8)?

---

## 12. Out of scope

- Automated shot capture from the press. No die cast OPC shot counter exists (`reference/seed_data/opc_tags.csv` covers assembly MIP and scales only); this remains manual entry.
- Time-ranged shot-loss attribution (E8).
- Reworking shift-boundary reconcile (E9).
- The Trim / Machining / Assembly terminals. This is die cast only.

---

## 13. Documents to update on implementation

- `MPP_MES_DATA_MODEL.md` — `Workorder.DieCastContribution.ShotCounterReading`.
- `MPP_MES_FDS.md` — the die cast shift-output requirements, plus a note that basket totals intentionally diverge from the legacy sheet (§1.4).
- `MPP_MES_Open_Issues_Register.md` — §11 open questions.
- `PROJECT_STATUS.md` — the change narrative.
- The `DieCastShiftOutputHowTo` and `DieCastLotReleaseHowTo` popups — the operator-facing wording changes with the field label.
