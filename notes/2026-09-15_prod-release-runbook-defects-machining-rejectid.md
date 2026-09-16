# Prod release runbook — area-scoped defect codes, route-driven Machining IN, reject identity

**Release commit:** `aec53015` on `jacques/working` — the commit the archives were built and verified from.
**Previous release:** `7ddb1ae0` (2026-09-15 08:53, die cast quantity + scrap model, migration `0084`).
**Published guide:** https://claude.ai/code/artifact/7ecbb380-6553-402c-8629-21b3bb2346d0
**Rehearsed against:** `MPP_MES_ProdSim`, a database built at `7ddb1ae0` — prod's exact
migration state (84 migrations, highest `0084`).

> **Nothing may be committed between the preview you read and the Execute.** The plan
> fingerprint covers HEAD; Execute refuses if anything moved.
>
> HEAD will be this runbook, or a later docs-only commit — that is fine and expected. What
> matters is not which commit HEAD is, but that **no deployable moved after the archives
> were built**:
> ```bash
> git diff --stat aec53015..HEAD -- ignition/ sql/
> ```
> Expect **no output**. If anything is listed, the archives are stale — rebuild and re-preview.

---

## 1. What this ships

Three bodies of work that accumulated after this morning's release.

**A trim operator can finally reach their own reject codes.** Before this, `Quality.DefectCode`
held one row per *number* and the number was unique plant-wide, so a code could belong to only
one department. The trim shop's laminated sheet lists 36 codes; a Trim OUT terminal could offer
**five** of them. A code now belongs to an *area*, so the same number can exist under Die Cast
and under Trim as two different rows, and all 105 printed lines exist. Nothing is renumbered —
those numbers live in systems outside the MES and are honoured exactly as printed.

**Castings that skip the trim shop can be machined.** Some oil pans are routed
`DieCast → MachiningIn → AssemblyOut`. A released basket lands in the warehouse, but both the
Machining IN queue and the claim proc demanded the LOT be sitting in a Trim Storage location —
so those castings were invisible and unclaimable at every machining line. The location gate is
replaced by the LOT's own route.

**Die-cast, trim and machining scrap gets its part back.** Migration `0084` (this morning)
repointed every reject reader to resolve the part from `RejectEvent.ItemId` instead of joining
through the LOT. Five procs write reject rows; two were updated, **three were not**. Since
08:53 this morning those three have written rows with no part, no shift and no cavity — which
makes them invisible to Reconcile Shift's SHIFT SCRAP column and buckets them under
`(unassigned part)` on the scrap matrix. This release fixes all three writers and backfills the
die-cast release rows.

### SQL

| Migration | What it does |
|---|---|
| `0085_defectcode_warmup_999` | `DC-999` → `999`. Pure rename; `Id` unchanged, so booked Warmup rejects follow the row. It was the only code that was not three digits. |
| `0086_defectcode_dc_attribution_prefix` | **Superseded, and deliberately still in the chain.** Prefixes `DC - ` onto 59 descriptions. `0087` strips it again. |
| `0087_defectcode_area_scoped_codes` | Strips `0086`'s prefix, swaps `UQ_DefectCode_Code` for `UQ_DefectCode_Area_Charge_Code`, then inserts/re-words the 105 printed lines. |
| `0088_diecast_release_scrap_identity_backfill` | Relabels the die-cast release-scrap rows `0084` left unlabelled. Idempotent; every `UPDATE` is guarded on the column still being NULL. |

> **Expect `0086` in the Preview's pending list and do not panic.** Forward-only means it
> applies before `0087` undoes it, inside the same release transaction. Net effect on
> `Description` is zero. Do not try to remove it from the chain — it is committed, and the
> high-water-mark gate BLOCKs on a gap.

| Repeatable | Version | Change |
|---|---|---|
| `R__Quality_DefectCode_Create` | 3.0 → 4.0 | `@ChargeToPartyId` added; duplicate check moves from plant-wide to `(area, charge-to, code)`. |
| `R__Quality_DefectCode_Get` | → 2.0 | Returns `ChargeToPartyId` + `ChargeToPartyName`. |
| `R__Quality_DefectCode_List` | → 3.0 | Same two columns. |
| `R__Lots_Lot_GetTrimStorageQueueForLine` | 1.0 → 2.0 | Drops the Trim Storage location predicate; status filter tightens to `NOT IN ('Closed','Open')`. |
| `R__Workorder_MachiningIn_RecordPick` | 1.1 → 3.0 | Route gate + template both from `Lots.ufn_NextPendingRouteStep`. |
| `R__Lots_DieCastLot_Release` | 2.1 → 2.2 | Closing scrap rows stamp their own identity. |
| `R__Workorder_TrimOut_Record` | 1.3 → 1.4 | Trim OUT scrap stamps `ItemId` + `CellLocationId` + `TerminalLocationId`. |
| `R__Workorder_MachiningOut_Mint` | 2.5 → 2.6 | Machining OUT scrap stamps the same. |

**Neither changed Machining IN proc's signature moves.** `@StorageLocationId` is retained on
both as accepted-and-ignored, so no caller changes.

### Ignition — Core imports FIRST

| Project | Resource | Change |
|---|---|---|
| Core | `named-query/quality/DefectCode_Create` | `chargeToPartyId` parameter (`sqlType: 3`) + the `EXEC` line. |
| Core | `script-python/BlueRidge/Lots/Lot` | **Docstring only.** Zero executable change. |
| MPP | `views/.../ShopFloor/DieCastBody` | `dieWideLines` default cleared to `[]`; resolves `_byCode("999")` / `_byCode("008")`. |
| MPP | `views/.../Popups/DieCastShiftOutputHowTo` | Regenerated. **Source is `tools/gen_howto_views.py:338`** — never edit the view directly. |

### In the range but shipping nothing

`sql/scratch/2026-09-15_line_run_audit.sql` and `sql/scripts/Invoke-LineRunAudit.ps1` (the MA2
line run forensics), `sql/seeds/030_seed_defect_codes.sql`, every `sql/tests/` file, and all of
`docs/` and `notes/`. **The deploy script runs no seeds.** `999` reaches prod through migration
`0085`, which is the `0048`/`0067`/`0075` dual-delivery pattern.

---

## 2. Risk

| | |
|---|---|
| Migrations | 4 — `0085` `0086` `0087` `0088` |
| Repeatables | 8 changed, 0 new (on ProdSim; prod may differ — see below) |
| Post-commit | `R__Descriptions_ExtendedProperties.sql` (documentation only) |
| Rehearsal lock window | **0.6s** |

### The one that generates phone calls — Machining IN now refuses what it allowed

This is the only behaviour regression in the release, and it is deliberate.

The old claim proc checked two things: *is the LOT sitting in trim storage*, and *does this
part's route mention `MachiningIn` anywhere*. It never checked that `MachiningIn` was the step
actually **due**. So today a casting whose `TrimIn` or `TrimOut` checkpoint is missing — an
operator skipped a scan, or the LOT was moved in by `Lot_MoveToValidated` rather than by
`TrimOut_Record` — **can be claimed onto a machining line before it is recorded as trimmed.**
After this release it is refused with *"…is not ready for Machining IN; its next operation is
TrimIn."*

That is the correction the release exists to make. In a live plant it can also strand real
baskets mid-shift. **Preview's `machining-in` GATE 1 counts them and prints the list** — it
BLOCKs, and every row it returns is a basket an operator will find blocked the morning after.

If it returns rows, do not abandon the change. Either record the missing checkpoints first
(through the procs, with audit — `prod-release-context-pack/09_one_off_remediation.md`), or run
the window when trim storage is empty. Whichever you choose, **the count belongs in the shift
handover** so the operators affected are known in advance.

Two smaller refusals in the same body of work, both BLOCK gates:
- **`Open` LOTs parked in trim storage vanish from the queue** (the read now excludes `Open`).
- **A part running on an unpublished (Draft) route stops being claimable.** The old inline
  lookup accepted a Draft; `ufn_NextPendingRouteStep` requires `PublishedAt`. Fix by publishing.

### The one way this rolls back hard

`0087` creates `UQ_DefectCode_Area_Charge_Code`. **`CREATE UNIQUE INDEX` failing mid-transaction
is the only way this release rolls back on its own.** It cannot fail today, because `Code` is
still globally unique — so Preview's `0087` duplicate-triple gate is really catching a row
somebody adds between the preview and the window. Treat a non-zero there as a stop.

### Low risk, stated honestly

The defect-code work **deletes nothing and renumbers nothing**. `0087` only `INSERT`s a missing
`(area, charge-to, code)` or `UPDATE`s a `Description`; it is set-based and id-free, so no row id
from any snapshot is baked into it. `Workorder.RejectEvent.DefectCodeId` keys on `Id` and is the
only FK into the table (verified against prod), so every booked reject keeps pointing where it
did. `0085` renames in place.

`0088` is a guarded, idempotent backfill — every `UPDATE` is conditioned on the target column
still being `NULL`, so a partial repair can simply be re-run. It **never infers a shift**: a
release taken with no counter reading and no final delta has no contribution row to pair
against, and those rows stay `NULL` and are reported rather than guessed, because a wrong shift
moves one crew's scrap onto another's numbers.

The three reject-writer procs stamp columns that already exist and change no signature.

> **Shared-code check.** Nothing in this release touches `BlueRidge.Common.*`. The only Core
> Python change is a docstring.

---

## 3. Deploy

> **Prod's numbers will differ from the rehearsal's, and for one section they differ a lot.**
> Read § 3.4 before you compare anything.

### Step 1 — Preview (read-only)

```bash
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition
```

Let it prompt for the password (masked). Never put it on the command line.

Expect `[3]` to report **84 applied, highest 0084**, and exactly these four pending:

```
  Pending (4):
    + 0085_defectcode_warmup_999.sql
    + 0086_defectcode_dc_attribution_prefix.sql
    + 0087_defectcode_area_scoped_codes.sql
    + 0088_diecast_release_scrap_identity_backfill.sql
```

**If `[3]` does not say 84/0084, stop.** Something was deployed outside this process.

`[4]` listed **8 changed, 0 new** on ProdSim. Prod may list more — the script compares proc text
on the target, not commit history, so a proc prod carries in a hand-patched form shows as
`CHANGED`. That is information, not an error: **read the per-object diffs in the report's
`diffs\` folder before continuing.**

Then read `[5]` in full. The gates that can stop you are labelled `BLOCK`.

### Step 2 — Rehearse (applies to the live data, then rolls back)

```bash
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -Mode Rehearse -ExpectedPlan <fingerprint-from-YOUR-preview>
```

**Take the fingerprint from your own Preview.** ProdSim's was `3664ba967697` and prod's will
differ, because the fingerprint covers the target's state as well as HEAD.

Expect the twelve step markers, then:

```
    == verifying inside the transaction
    == checks passed
    == ROLLED BACK (rehearsal / preview script) -- nothing was kept

  REHEARSAL PASSED and was rolled back. Lock window: 0.6s.
```

The lock window matters: the script takes `TABLOCKX` on `Lots.Lot`, `Tools.ToolCavity` and
`Workorder.DieCastContribution` for its duration, so plant writes wait. 0.6s locally; prod has
more data in `RejectEvent`, so allow for a few seconds, not minutes. **If it runs long enough to
notice, something is blocking** — check `[6]` for an open transaction.

### Step 3 — Execute

```bash
.\sql\scripts\Deploy-ProdRelease.ps1 -ServerInstance 172.17.10.148 -Username Ignition -Mode Execute -ExpectedPlan <same-fingerprint>
```

It takes a verified `COPY_ONLY` backup first and prints where. Expect `== COMMITTED`, then:

```
  Every repo migration is recorded.
  All N applied repeatable(s) now match the repo byte-for-byte.
DONE
  MPP_MES_Prod is at this checkout (aec53015). Import the Ignition exports NOW -- Core first.
```

### Step 4 — Import the Ignition exports, Core FIRST

From `dist\ignition-exports\`:

1. `Core_defects-machining-rejectid_2026-09-15_2352.zip`
2. `MPP_defects-machining-rejectid_2026-09-15_2352.zip`

Four resources total. **Core must go first** — MPP declares `"parent": "Core"` and will not
resolve inherited resources without it. Nothing is deleted in this range, so there is no
by-hand deletion step.

### 3.4 — What the rehearsal could NOT prove, and why

**ProdSim reproduces prod's schema, not prod's defect-code rows.** It is built at `7ddb1ae0`,
and `sql/seeds/030_seed_defect_codes.sql` was realigned to prod *after* that commit (`7cf94802`).
Both databases hold 155 codes, but **they are not the same 155** — ProdSim carries the Dev-era
low range (`107` present, `001` and `008` absent); prod carries `001`–`015` and `008`.

So the rehearsal printed:

```
0086: 60 die-cast-charged description(s) prefixed.
0087: 7 description(s) matched to the sheet.
0087: 89 code(s) added.
```

and prod is expected to print **59 / 8 / 78**, ending at **233** rather than ProdSim's 244.

**Trust the prod-computed numbers in the handoff (78 / 8 / 233), not the rehearsal's.** What the
rehearsal *does* prove, and what it was for: all four migrations apply in order against prod's
real schema, the unique-index swap succeeds, all eight repeatables compile, the whole thing fits
in one transaction with a 0.6s lock window, and the rollback is genuinely clean (`SchemaVersion`
back to 84/0084, 155 codes, new index absent).

Post-Execute check 2 in § 4 is the one that settles it. If it returns anything other than
`233 / 0 / 0`, read before you continue — the release is committed by then, and the backup from
Step 3 is the way back.

---

## 4. Verification after Execute

```sql
-- 1. all 105 printed lines present, grouped correctly
SELECT oc.Name AS Area, cp.Name AS ChargedTo, COUNT(*) AS Codes
  FROM Quality.DefectCode dc
  JOIN Parts.OperationCategory oc ON oc.Id = dc.OperationCategoryId
  JOIN Quality.ChargeToParty  cp ON cp.Id = dc.ChargeToPartyId
 GROUP BY oc.Name, cp.Name ORDER BY oc.Name, cp.Name;

-- 2. nothing lost, nothing prefixed          expect 233 / 0 / 0
SELECT COUNT(*) AS Total,
       SUM(CASE WHEN Description LIKE 'DC - %' THEN 1 ELSE 0 END) AS StillPrefixed,
       SUM(CASE WHEN Code NOT LIKE '[0-9][0-9][0-9]' THEN 1 ELSE 0 END) AS NotThreeDigit
  FROM Quality.DefectCode;

-- 3. every booked reject still resolves, and the count is unchanged
SELECT COUNT(*) AS Events,
       SUM(CASE WHEN dc.Id IS NULL THEN 1 ELSE 0 END) AS Orphaned   -- expect 0
  FROM Workorder.RejectEvent re
  LEFT JOIN Quality.DefectCode dc ON dc.Id = re.DefectCodeId;

-- 4. the excused set is untouched (it feeds the OEE quality calculation)
SELECT COUNT(*) AS Excused FROM Quality.DefectCode
 WHERE IsExcused = 1 AND Code NOT LIKE 'TEST%';   -- must equal the Preview's number

-- 5. both Machining IN procs report their new versions
SELECT OBJECT_NAME(object_id) AS Proc, LEFT(definition, 400) AS Head
  FROM sys.sql_modules
 WHERE object_id IN (OBJECT_ID(N'Lots.Lot_GetTrimStorageQueueForLine'),
                     OBJECT_ID(N'Workorder.MachiningIn_RecordPick'));
-- expect Version: 2.0 and Version: 3.0

-- 6. neither retains the old location gate    expect 0 rows
SELECT OBJECT_NAME(object_id) FROM sys.sql_modules
 WHERE definition LIKE N'%LocationTypeDefinitionId = 14%'
   AND object_id IN (OBJECT_ID(N'Lots.Lot_GetTrimStorageQueueForLine'),
                     OBJECT_ID(N'Workorder.MachiningIn_RecordPick'));

-- 7. the backfill actually labelled the release scrap   expect 0
SELECT COUNT(*) FROM Workorder.RejectEvent
 WHERE Remarks = N'Die-cast final release scrap'
   AND (ItemId IS NULL OR ToolId IS NULL OR ToolCavityId IS NULL);
```

**Then on a terminal:**

1. Open a **Trim OUT** reject panel and confirm the picker offers the trim sheet's codes.
   *That is the outcome this whole release exists for.*
2. Open a **Machining IN** terminal: the queue renders, the On-Hold indicator still shows held
   LOTs, and one claim succeeds end to end. The On-Hold check matters — held LOTs are
   deliberately visible-but-not-claimable, and a regression there blanks the indicator silently
   rather than erroring.
3. Release a die-cast basket with one scrap line, then open **Reconcile Shift** and confirm the
   SHIFT SCRAP column shows it. Before this release it read 0 permanently.

---

## 5. Rollback

The `COPY_ONLY` backup Execute takes first is the rollback. There is no down-migration.

The Machining IN half rolls back cleanly on its own — nothing is migrated and nothing mutated:

```bash
git show 035222d9:sql/migrations/repeatable/R__Lots_Lot_GetTrimStorageQueueForLine.sql
git show 035222d9:sql/migrations/repeatable/R__Workorder_MachiningIn_RecordPick.sql
```

Apply both and the old behaviour returns. **One-way residue, benign:** a LOT claimed from the
warehouse during the window keeps its `MachiningIn` checkpoint and sits on its line. Its next
pending step is now `MachiningOut`/`AssemblyOut`, so neither proc version will offer it again.

If only the Ignition side misbehaves, re-import the previous scoped export — the SQL stands on
its own and the old views keep working, because `0087` only adds rows.

---

## 6. Known open — NOT in this release

- **`0088` backfills die-cast release scrap only.** The `v1.4` / `v2.6` proc fixes stop new
  unlabelled trim and machining rows, but the ones already written since 08:53 this morning
  stay unlabelled. The Preview's `0088` gate counts them. A second backfill is owed, and it is
  a different shape — `ToolId` / `ToolCavityId` must stay NULL for a die-free operation.
- **The Config Tool's `DefectCodeEditor` has no charge-to-party control.** `_Get` and `_List`
  now return it and `_Create` accepts it, but the view binds neither, so a code created through
  the Config Tool gets `ChargeToPartyId = NULL`. The editor needs a dropdown fed by a
  `ChargeToParty_List` named query, which does not exist yet.
- **The trim sheet's attribution was inferred, not read.** TSFM-0085 has no `D/C` / `M/S`
  headings, so all 36 trim rows were set to `ChargeToParty = TrimShop`.
- **Codes no sheet claims are untouched.** ~50 codes appear on none of the three sheets.
  Nothing was deleted or deprecated.
- **No trim-skipping oil pan routes are seeded in any environment yet.** Until those routes are
  authored, the Machining IN change fixes a path nothing currently travels. Prerequisite, not
  regression.
- **`DieCastBody` carries a pickled `selectedShiftId: 20107`** — a Dev shift id — in its view
  defaults, and all three code paths that set it are guarded `if ... is None`, so it is not
  overwritten. Pre-existing: it shipped this morning and this release does not change it.
  Worth a look, separately.
- **Renaming `Lot_GetTrimStorageQueueForLine` → `Lot_GetMachiningInQueueForLine`.** The name is
  now historic and says so in the proc header. Renaming means editing the MachiningIn view's
  binding expression — a Designer change; bundle it with the next Designer session.

---

## 7. Outcome -- executed 2026-09-16 04:46 ET

**Clean. `== COMMITTED`, sqlcmd exit 0 after 1.7s, 0 warnings, no BLOCK gate fired.**

| | |
|---|---|
| Executed at | 2026-09-16 04:46 ET |
| Plan fingerprint used | `e343dce4d97d` (prod's own -- ProdSim's was `3664ba967697`) |
| Backup path | `C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\Backup\MPP_MES_Prod_pre-release_0084_20260916_044646.bak` (COPY_ONLY, CHECKSUM, verified) |
| Report folder | `dist/deploy-reports/MPP_MES_Prod_Execute_20260916_044646` |
| Migrations applied | 4 -- `0085` `0086` `0087` `0088` |
| Repeatables applied | 8 (matching ProdSim exactly -- prod carried no hand-patched proc) |
| Lock window | 1.7s (ProdSim: 0.6s) |
| Prod HEAD | `10346bbe` |

### The prod-computed numbers were right; the rehearsal's were not

This is the section § 3.4 existed for, and it resolved in favour of the handoff:

```
0087: 8 description(s) matched to the sheet.
0087: 78 code(s) added.
```

**8 re-worded and 78 added, exactly as computed against prod** -- 155 + 78 = **233**.
ProdSim had printed 7 and 89 (ending at 244) because it carries the Dev-era code set. Anyone
reading a future ProdSim rehearsal of a defect-code migration should expect the same divergence
and trust the prod-computed figure.

One small miss: `0086` prefixed **60** descriptions where the handoff said 59. Harmless and not
worth chasing -- `0087` strips every row matching `Description LIKE 'DC - %'`, so the net effect
on `Description` is zero regardless of the count.

### Gates: no blocks, one number that matters

**`machining-in` GATE 1 returned nothing.** Not one LOT in trim storage was in a state the new
route gate would refuse, so no basket was stranded and there was nothing to put in the shift
handover. GATE 3 (Open LOTs in trim storage) and GATE 4 (unpublished routes) were also clean.
The refusal risk that dominated § 2 did not materialise.

**63 LOTs newly appear in Machining IN queues** -- the size of the behaviour change, and the
number to quote if anyone asks why a queue grew overnight:

| At location | Part | LOTs |
|---|---|---|
| 6MA Cam Holder Line 1 | `12231-6MA -0000` | 14 |
| 64A Oil Pan | `1120A-64AA` | 8 |
| Warehouse | `12231-6MA -0000` | 7 |
| Warehouse | `12235-6MA -0000` | 7 |
| Warehouse | `12241-6MA -0000` | 5 |
| 6MA Cam Holder Line 1 | `12242-6MA -0000` | 4 |
| 6MA Cam Holder Line 1 | `12244-6MA -0000` | 4 |
| Warehouse | `12245-6MA -0000` | 4 |
| (10 more rows, 1-3 each) | | 10 |

Every location is a Warehouse or a machining line -- **no sort cage, offsite facility or shipping
location appeared**, so the spec's § 7 residual risk did not show up in real data either.

### `0088` repaired nothing, and that is the honest result

```
0088: labelled part/die/cavity on 0 release-scrap row(s).
0088: every release-scrap row is now fully labelled.
```

**Zero rows needed relabelling, and the out-of-scope gate for trim/machining scrap did not fire
either** -- so all 103 booked rejects in prod already carry an `ItemId`. The three unstamped
writers were a real defect in code and would have bitten the first time anyone recorded closing
scrap, but between `0084` going out on 2026-09-15 08:53 and this release, **nobody did** -- prod
is running at cutover volumes (4 open baskets, last die-cast entry 09/15 14:48).

So the urgency stated in § 1 was overstated in effect, though not in kind. The fix is correct
and belongs in prod; the data damage it was written to stop had not yet happened. Worth
remembering the next time a writer/reader split like this is found: **check how many bad rows
exist before describing it as bleeding.**

The trim/machining backfill owed in § 6 is therefore **no longer owed** -- there is nothing to
backfill. If that changes, the query is the `0088` gate in `Deploy-ProdRelease.ps1`.

### Still to verify

The Ignition exports (Core first) and the three terminal checks in § 4 -- the Trim OUT picker,
a Machining IN claim end to end with the On-Hold indicator, and a die-cast release with one
scrap line landing in Reconcile Shift's SHIFT SCRAP column.
