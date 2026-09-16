# Release Handoff — Defect Codes Scoped by Area

**Date:** 2026-09-15
**Branch:** `jacques/working`
**Commits:** `7cf94802` (999 + view) and `8936a5cd` (area scoping + procs)
**Status:** Implemented, applied to `MPP_MES_Dev`, verified. **Not deployed to Prod.**
**Reference artifact:** the three sheet tables — https://claude.ai/code/artifact/6b006301-d688-41c4-8e16-cb65e37a2500

---

## 1. What this changes, in one paragraph

Madison prints reject codes on three shop-floor sheets, and those numbers exist in systems
outside the MES, so they are honoured exactly as printed — **nothing is renumbered, ever**.
`Quality.DefectCode` now holds one row per printed line: 36 die cast (DCFM-0485 v18), 36
trim shop (TSFM-0085 v7), 33 machining & assembly (line production sheet) = **105 rows**.
The grouping is the FK that always existed, `OperationCategoryId`. The one thing blocking
this was `UQ_DefectCode_Code` being plant-wide: those 105 rows carry only **86 distinct
numbers**, because 17 codes are printed on more than one sheet, and `133` / `134` appear
**twice on the M&A sheet alone** — once under `D/C Rejects`, once under `M/S Rejects`. The
key is therefore now `(OperationCategoryId, ChargeToPartyId, Code)`.

---

## 2. Deployment inventory

### 2.1 SQL — three versioned migrations

| File | What it does |
|---|---|
| `0085_defectcode_warmup_999.sql` | `DC-999` → `999`. Pure rename; `Id` unchanged, so the booked Warmup rejects follow the row. It was the only code in the table that was not three digits. |
| `0086_defectcode_dc_attribution_prefix.sql` | **Wrong, and deliberately still in the chain.** Prefixes `DC - ` onto all 59 die-cast-*charged* descriptions when the M&A sheet lists 17. `0087` strips it again. |
| `0087_defectcode_area_scoped_codes.sql` | Strips 0086's prefix, swaps the unique key, then inserts/re-words the 105 printed lines. |

> **Expect `0086` in the Preview's pending list and do not panic.** Forward-only means it
> applies before `0087` undoes it, inside the same release transaction. Net effect on
> `Description` is zero. Do not try to remove it from the chain — it is committed and the
> high-water-mark gate will BLOCK on a gap.

### 2.2 SQL — three repeatables

| File | Version | Change |
|---|---|---|
| `R__Quality_DefectCode_Create.sql` | 3.0 → **4.0** | `@ChargeToPartyId` added with an FK check; the duplicate check moves from plant-wide to `(area, charge-to, code)`. |
| `R__Quality_DefectCode_Get.sql` | → **2.0** | Returns `ChargeToPartyId` + `ChargeToPartyName`. |
| `R__Quality_DefectCode_List.sql` | → **3.0** | Same two columns. Filtering logic untouched. |

**Why the procs had to change, not just the table.** `DefectCode_Create` had no
`@ChargeToPartyId` parameter at all, so every code the Config Tool created would have landed
`NULL` — and the new unique index treats NULLs as equal, so the second such code with the
same number and area would collide. Worse, its duplicate check was
`WHERE Code = @Code` with no scope, so it would have refused a legitimate `100` under Trim
because `100` already exists under M&A. Deploying the migration without these three is a
broken Config Tool.

`DefectCode_Update` and `_Deprecate` are **unchanged and correct** — neither touches `Code`
or `ChargeToPartyId`.

### 2.3 Ignition — three resources

| Project | Resource | Change |
|---|---|---|
| Core | `named-query/quality/DefectCode_Create` | `chargeToPartyId` parameter (`sqlType: 3`) + the `EXEC` line. |
| MPP | `views/.../ShopFloor/DieCastBody` | `dieWideLines` default cleared to `[]`; `_byCode("999")` / `_byCode("008")`. |
| MPP | `views/.../Popups/DieCastShiftOutputHowTo` | Regenerated. **The source is `tools/gen_howto_views.py:338`** — never edit the view directly, it is overwritten on the next run. |

Core imports before MPP.

---

## 3. What it does to Prod — computed, not guessed

| | |
|---|---|
| Rows inserted (new Ids) | **78** |
| Rows re-worded | **8** |
| Rows deleted | **0** |
| Existing Ids changed | **0** |
| `Quality.DefectCode` | 155 → **233** |

`0087` is **set-based and id-free** — no row id from any snapshot is baked into it, so it
behaves identically on Dev, ProdSim and Prod. It only ever `INSERT`s a missing
`(area, charge-to, code)` or `UPDATE`s a `Description` to match the paper.

**The three rows carrying reject history are never moved:**

| Id | Code | Area | Rejects |
|---|---|---|---|
| 21 | `008` Test Part | Die Cast | 318 |
| 154 | `DC-999` → `999` Warmup | Die Cast | 456 |
| 16 | `003` Bent Pin | Die Cast | 2 |

`0085` renames `154`'s code in place. `Workorder.RejectEvent.DefectCodeId` keys on `Id`, and
it is the **only** FK into the table (verified against prod, not the repo), so all 776 booked
events keep pointing exactly where they did.

The 8 re-wordings are cosmetic, bringing the label in line with the printed sheet:

```
010 Stuck Part/Stuck Piece  -> Stuck Part / Stuck Piece
142 N/G Blast N/G Tumble    -> NG Blast/ NG Tumble
144 White-Rust              -> White Rust
145 Drill Damage            -> Drill damage (Broken Drill Bit)
149 Flatness                -> Flatness No Good
150 Holesize                -> Hole Size No Good
151 Thickness               -> Thickness No good
152 Thread Damage           -> Threads No Good
```

---

## 4. Pre-flight gates to write — this is the main job

Section `[5]` of `sql/scripts/Deploy-ProdRelease.ps1` is hand-written per release, keyed off
`$pendingIds`. Add these. The first is the one that can actually fail the deploy.

**G1 — BLOCK. `0087` cannot create its unique index over duplicate triples.**

```sql
SELECT COUNT(*) FROM (
    SELECT OperationCategoryId, ChargeToPartyId, Code
      FROM Quality.DefectCode
     GROUP BY OperationCategoryId, ChargeToPartyId, Code
    HAVING COUNT(*) > 1) x;
```

Must be `0`. It is `0` on prod today only because `Code` is currently globally unique — if
anyone adds a row between the preview and the window, this catches it. `CREATE UNIQUE INDEX`
failing mid-transaction is the one way this release can roll back hard.

**G2 — BLOCK. All six lookup codes must resolve**, or `0087` raises and the whole batch dies.

```sql
SELECT (SELECT COUNT(*) FROM Parts.OperationCategory
         WHERE Code IN (N'DieCast', N'Trim', N'MachiningAssembly'))
     + (SELECT COUNT(*) FROM Quality.ChargeToParty
         WHERE Code IN (N'DieCast', N'TrimShop', N'MachineShop'));
```

Must be `6`.

**G3 — BLOCK. `0085`'s rename target must be free.**

```sql
SELECT COUNT(*) FROM Quality.DefectCode WHERE Code = N'999';
```

Must be `0` while `DC-999` still exists. `0085` raises rather than clobbering, but catch it
read-only first.

**G4 — WARN. Rows with a NULL `ChargeToPartyId`.** The unique index treats NULLs as equal,
so two NULL-charge rows sharing an area and a number would collide.

```sql
SELECT COUNT(*) FROM Quality.DefectCode WHERE ChargeToPartyId IS NULL;
```

Expected `0` on prod (migration `0067` backfilled, `0084` finished `DC-999`). Non-zero is
worth reading before you commit.

**G5 — INFO. Record the reject count so the window can prove nothing moved.**

```sql
SELECT COUNT(*) FROM Workorder.RejectEvent;      -- 103 as of 2026-09-15
```

---

## 5. Verification after Execute

```sql
-- 1. all 105 printed lines present, grouped correctly
SELECT oc.Name AS Area, cp.Name AS ChargedTo, COUNT(*) AS Codes
  FROM Quality.DefectCode dc
  JOIN Parts.OperationCategory oc ON oc.Id = dc.OperationCategoryId
  JOIN Quality.ChargeToParty  cp ON cp.Id = dc.ChargeToPartyId
 GROUP BY oc.Name, cp.Name ORDER BY oc.Name, cp.Name;

-- 2. nothing lost, nothing prefixed
SELECT COUNT(*) AS Total,                                   -- expect 233
       SUM(CASE WHEN Description LIKE 'DC - %' THEN 1 ELSE 0 END) AS StillPrefixed,  -- 0
       SUM(CASE WHEN Code NOT LIKE '[0-9][0-9][0-9]' THEN 1 ELSE 0 END) AS NotThreeDigit  -- 0
  FROM Quality.DefectCode;

-- 3. every booked reject still resolves, and the count is unchanged
SELECT COUNT(*) AS Events,                                  -- expect 103
       SUM(CASE WHEN dc.Id IS NULL THEN 1 ELSE 0 END) AS Orphaned   -- expect 0
  FROM Workorder.RejectEvent re
  LEFT JOIN Quality.DefectCode dc ON dc.Id = re.DefectCodeId;

-- 4. the two codes DieCastBody resolves by name
SELECT dc.Code, dc.Description FROM Quality.DefectCode dc
  JOIN Parts.OperationCategory oc ON oc.Id = dc.OperationCategoryId
 WHERE oc.Code = N'DieCast' AND dc.Code IN (N'008', N'999');
```

Then on a terminal: open a Trim OUT reject panel and confirm the picker offers the trim
sheet's codes. **That is the outcome this whole release exists for** — before it, a trim
operator could reach 5 of the 36 codes on their own laminated sheet.

---

## 6. Rollback

The `COPY_ONLY` backup Execute takes first is the rollback. There is no down-migration.

If only the Ignition side misbehaves, re-import the previous scoped export — the SQL stands
on its own and the old views keep working, because `0087` only adds rows.

---

## 7. Known open — NOT in this release

**The Config Tool's `DefectCodeEditor` has no charge-to-party control.** `_Get` and `_List`
now return `ChargeToPartyId` + `ChargeToPartyName`, and `_Create` accepts the parameter, but
the view does not bind either. Until it does, a code created through the Config Tool gets
`ChargeToPartyId = NULL` — see G4. The editor needs a dropdown fed by a
`ChargeToParty_List` named query, which **does not exist yet**. Existing-view work, so
Designer, per the file-edit boundary.

**The trim sheet's attribution was inferred, not read.** DCFM-0485 and the M&A line sheet
state their attribution explicitly; TSFM-0085 is a single list with no `D/C` / `M/S`
headings, so all 36 trim rows were set to `ChargeToParty = TrimShop`. If trim charges some
back to die cast the way the M&A sheet does, it is a one-line change in the generator at
`scratchpad/gen_0087.py` and a re-run.

**Codes no sheet claims are untouched.** Prod holds ~50 codes that appear on none of the
three sheets — `135`–`139`, `191`, `206`, `210`, `214`–`222`, `226`, `229`–`231`, `255`,
`256`, and most of the Machine Shop block. Nothing was deleted or deprecated. Deciding their
fate needs the sheets that claim them, or a call from MPP.

---

## 8. Provenance

The 105 rows were transcribed from photographs of the three sheets and cross-checked
row-by-row against a read-only prod extract (`sql/scratch/defectcode_renumber_risk.sql`,
six sections). The transcription is rendered in the artifact linked at the top — **check it
against the paper before the window**, because it is the input the migration was generated
from, and a misread digit becomes a wrong code in production.
