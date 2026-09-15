# Release Handoff — Machining IN Route-Driven Claim

**Date:** 2026-09-15
**Branch:** `jacques/working`
**Commit range:** `035222d9..72f9b547` (three implementation commits)
**Spec:** `docs/superpowers/specs/2026-09-15-machining-in-route-driven-claim-design.md`
**Plan:** `docs/superpowers/plans/2026-09-15-machining-in-route-driven-claim.md`
**Status:** Implemented, full suite green (3621/3621). **Not deployed anywhere.**

---

## 1. What this changes, in one paragraph

Some oil pans skip the trim shop; their routes are authored `DieCast → MachiningIn →
AssemblyOut`. A released die-cast basket lands in `WHSE`, but both the Machining IN queue
read and the claim proc required the LOT to be sitting in a Trim Storage location
(`LocationTypeDefinitionId = 14` under a `TRIM*` area), so those castings were invisible
and unclaimable at every machining line. **The location gate is replaced by the LOT's own
route:** a LOT is claimable when its next *pending* route step carries the `MachiningIn`
role and its item is eligible at the line. No schema change.

---

## 2. Deployment inventory

### 2.1 SQL — two repeatable procs, NO migration

| File | Version | Change |
|---|---|---|
| `sql/migrations/repeatable/R__Lots_Lot_GetTrimStorageQueueForLine.sql` | 1.0 → **2.0** | Drops the `TrimStores` CTE and its location predicate; status filter tightens from `<> 'Closed'` to `NOT IN ('Closed','Open')`. |
| `sql/migrations/repeatable/R__Workorder_MachiningIn_RecordPick.sql` | 1.1 → **3.0** | Steps 3 + 4 collapse into one `Lots.ufn_NextPendingRouteStep` lookup supplying both the gate and the `OperationTemplateId`. |

> **There is no versioned migration in this release.** Both procs are `CREATE OR ALTER`.
> `SchemaVersion` is untouched and the highest applied migration stays `0084`. Do not
> author an `0085`; if your release tooling expects one, this release legitimately has none.

Neither proc's **signature** changes. `@StorageLocationId` is retained on both as an
accepted-and-ignored parameter (house pattern: cf. `@DestinationCellLocationId` on
`Workorder.TrimOut_Record`) precisely so no caller has to change.

### 2.2 Ignition — one comment-only Python resource

| File | Change |
|---|---|
| `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Lot/code.py` | `getTrimStorageQueueForLine` **docstring only** (14 insertions, 7 deletions, all comment). |

The old docstring asserted the LOTs are *"sitting in Trim Storage"*, which this change
makes false. Zero executable change — the function name, parameters and `execList` call
are byte-identical.

**No named query, no `view.json`, no Perspective view is touched.** Verified:
`git diff --name-only 035222d9 72f9b547 | grep -E "named-query|view\.json"` returns nothing.

Scoped export scope is therefore a single Core script-python resource. Build it **from git,
verified against HEAD**, via `tools/Build-ChangeExport.ps1`; Core imports first. Because the
change is comment-only, a reviewer may reasonably decide to defer the export to the next
release that touches Core — the SQL works without it. Do not skip it silently: an
un-exported docstring leaves repo and gateway divergent, which is how the next reader gets
misled.

### 2.3 Not deployed (test-only)

`sql/tests/0027_PlantFloor_Machining/030_MachiningIn_NoTrimRoute.sql` (new, 11 assertions),
`sql/tests/0027_PlantFloor_Machining/020_MachiningIn_RecordPick_guards.sql`,
`sql/tests/0024_PlantFloor_Movement_Trim/065_Lot_GetTrimStorageQueueForLine.sql`.

The `030` fixture creates a part `TSKIP-C`. That is a **test-database fixture only** — it is
created inside the test file, not in any seed, and must never reach production.

---

## 3. Pre-flight gates — run these against live data in Preview

All four are read-only. SQL validated against the real schema (syntax-checked on
`MPP_MES_Test`). Gate 1 is the one that can stop the release.

### GATE 1 (blocking) — LOTs claimable today that this change would BLOCK

```sql
SELECT l.Id, l.LotName, i.PartNumber, loc.Name AS AtLocation,
       ISNULL(ns.OperationTypeCode, N'(no pending step)') AS NextStep
FROM Lots.Lot l
JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId AND sc.Code <> N'Closed'
JOIN Parts.Item i ON i.Id = l.ItemId
JOIN Location.Location loc ON loc.Id = l.CurrentLocationId
OUTER APPLY Lots.ufn_NextPendingRouteStep(l.Id) ns
WHERE loc.LocationTypeDefinitionId = 14
  AND EXISTS (SELECT 1 FROM Location.Location a
              WHERE a.Id = loc.ParentLocationId AND a.Code LIKE N'TRIM%')
  AND ISNULL(ns.OperationTypeCode, N'') <> N'MachiningIn';
```

**Pass = 0 rows.**

**Why this is the dangerous one.** The old claim proc checked only *"is the LOT in Trim
Storage"* plus *"does this part's route contain a `MachiningIn` template anywhere"*. It did
**not** check that `MachiningIn` was the step actually due. So today a LOT sitting in Trim
Storage with its `TrimIn` or `TrimOut` checkpoint missing — an operator skipped a scan, or
the LOT was moved in by `Lot_MoveToValidated` rather than by `TrimOut_Record` — **can still
be claimed onto a machining line.** After this change it is refused with *"…is not ready
for Machining IN; its next operation is TrimIn."*

That is the intended correction (a casting was being machined before it was recorded as
trimmed), but in a live plant it can strand real baskets mid-shift. Every row this gate
returns is a basket an operator will find blocked the morning after the release.

**If it returns rows:** do not treat it as a reason to abandon the change. Either record the
missing checkpoints for those LOTs first (through the procs, with audit — see
`prod-release-context-pack/09_one_off_remediation.md`), or schedule the release for a window
when trim storage is empty. Whichever, the count belongs in the instruction guide so the
operators affected are known in advance.

### GATE 2 (informational) — what NEWLY appears in Machining IN queues

```sql
SELECT loc.Name AS AtLocation, i.PartNumber, COUNT(*) AS Lots
FROM Lots.Lot l
JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId AND sc.Code NOT IN (N'Closed', N'Open')
JOIN Parts.Item i ON i.Id = l.ItemId
JOIN Location.Location loc ON loc.Id = l.CurrentLocationId
CROSS APPLY Lots.ufn_NextPendingRouteStep(l.Id) ns
WHERE ns.OperationTypeCode = N'MachiningIn'
  AND NOT (loc.LocationTypeDefinitionId = 14
           AND EXISTS (SELECT 1 FROM Location.Location a
                       WHERE a.Id = loc.ParentLocationId AND a.Code LIKE N'TRIM%'))
GROUP BY loc.Name, i.PartNumber ORDER BY COUNT(*) DESC;
```

This is the size of the behaviour change, and the number the instruction guide should quote
so nobody is surprised by a queue that grew overnight. Rows at **Warehouse** are the point
of the release. Rows at a **sort cage, an offsite facility, or a shipping location** are the
spec's §7 residual risk showing up in real data — review them before proceeding, because a
machining line will now be able to claim them.

### GATE 3 (blocking) — Open LOTs that would disappear from a queue

```sql
SELECT COUNT(*) AS OpenInTrimStore FROM Lots.Lot l
JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId AND sc.Code = N'Open'
JOIN Location.Location loc ON loc.Id = l.CurrentLocationId
WHERE loc.LocationTypeDefinitionId = 14
  AND EXISTS (SELECT 1 FROM Location.Location a
              WHERE a.Id = loc.ParentLocationId AND a.Code LIKE N'TRIM%');
```

**Pass = 0.** The read now excludes `Open`. An `Open` basket parked in trim storage is
already anomalous; if any exist they vanish from the queue on release and someone must know.

### GATE 4 (blocking) — items with a MachiningIn step but no PUBLISHED route

```sql
SELECT i.PartNumber, COUNT(*) AS OpenLots
FROM Lots.Lot l
JOIN Lots.LotStatusCode sc ON sc.Id = l.LotStatusId AND sc.Code <> N'Closed'
JOIN Parts.Item i ON i.Id = l.ItemId
WHERE NOT EXISTS (SELECT 1 FROM Parts.RouteTemplate rt
                  WHERE rt.ItemId = l.ItemId AND rt.PublishedAt IS NOT NULL
                    AND rt.DeprecatedAt IS NULL)
  AND EXISTS (SELECT 1 FROM Parts.RouteTemplate rt
              JOIN Parts.RouteStep rs ON rs.RouteTemplateId = rt.Id
              JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
              JOIN Parts.OperationType oty ON oty.Id = ot.OperationTypeId
              WHERE rt.ItemId = l.ItemId AND oty.Code = N'MachiningIn')
GROUP BY i.PartNumber;
```

**Pass = 0 rows.** The old inline lookup accepted a **Draft** route (`DeprecatedAt IS NULL`
only); `ufn_NextPendingRouteStep` requires `PublishedAt IS NOT NULL`. Any part running on an
unpublished route is claimable today and will not be after. Fix by publishing the route.

---

## 4. Rehearsal

Standard shape (`prod-release-context-pack/05_local_rehearsal.md`): build a local DB at the
target's exact migration state, apply the two repeatable scripts, run the four gates, then
the full suite.

Because there is no migration and no data mutation, the rehearsal's job is narrower than
usual — it is confirming the two `CREATE OR ALTER` statements compile against the target's
actual schema and that the gates return what the preview said. `Lots.ufn_NextPendingRouteStep`
must already exist at the target (it does from migration-era `R__Lots_ufn_NextPendingRouteStep.sql`,
extracted 2026-09-12); confirm it, because both changed procs now depend on it and the read
proc did not call it before.

---

## 5. Post-execute verification

1. Both procs report their new versions:
   ```sql
   SELECT OBJECT_NAME(object_id) AS Proc, LEFT(definition, 400) AS Head
   FROM sys.sql_modules
   WHERE object_id IN (OBJECT_ID(N'Lots.Lot_GetTrimStorageQueueForLine'),
                       OBJECT_ID(N'Workorder.MachiningIn_RecordPick'));
   ```
   Expect `Version: 2.0` and `Version: 3.0` in the headers.
2. Neither proc contains the old gate — expect **0 rows**:
   ```sql
   SELECT OBJECT_NAME(object_id) FROM sys.sql_modules
   WHERE definition LIKE N'%LocationTypeDefinitionId = 14%'
     AND object_id IN (OBJECT_ID(N'Lots.Lot_GetTrimStorageQueueForLine'),
                       OBJECT_ID(N'Workorder.MachiningIn_RecordPick'));
   ```
3. Re-run GATE 2 and confirm the newly-visible count matches what Preview predicted.
4. Smoke on the floor: open a Machining IN terminal and confirm its queue renders, the
   On-Hold indicator still shows held LOTs, and one claim succeeds end to end.

The On-Hold check matters: held LOTs are **deliberately** still visible-but-not-claimable
(spec D5), and a regression there would silently blank that indicator rather than error.

---

## 6. Rollback

Clean, because nothing is migrated and nothing is mutated. Re-deploy the previous bodies:

```bash
git show 035222d9:sql/migrations/repeatable/R__Lots_Lot_GetTrimStorageQueueForLine.sql
git show 035222d9:sql/migrations/repeatable/R__Workorder_MachiningIn_RecordPick.sql
```

Apply both; the old behaviour returns immediately. No `SchemaVersion` row to unwind, no data
to repair, no export to reverse (the Ignition change is a comment).

**One-way residue, and it is benign.** A LOT claimed from `WHSE` during the window keeps its
`MachiningIn` `ProductionEvent` and sits on its line. Rolling back does not undo that and
does not need to: that LOT's next pending step is now `MachiningOut`/`AssemblyOut`, so it has
left the Machining IN path entirely and neither proc version will offer it again. It is a
correctly in-process LOT either way.

---

## 7. Out of scope for this release

- **Renaming** `Lot_GetTrimStorageQueueForLine` → `Lot_GetMachiningInQueueForLine`. The name
  is now historic and says so in the proc header, the Python docstring and the test
  description. Renaming means editing the MachiningIn view's binding expression, which is a
  Designer change; bundle it with the next Designer session that touches that view.
- **Seeding the real trim-skipping oil pan routes.** None exist in any environment yet —
  every seeded route in `029_seed_item_routes.sql` runs through trim. Until those routes are
  authored, this release fixes a path nothing currently travels. It is a prerequisite, not a
  regression.
- The `Parts.ufn_OperationTemplateForLotRole` convergence (open TODO, `PROJECT_STATUS.md`).
- Die-cast release destination — `WHSE` is correct and untouched.

---

## 8. Test evidence

Full suite **3621 / 3621, exit 0**, run after every change in this release.

- `0027/030_MachiningIn_NoTrimRoute.sql` — **new**, 11 assertions: WHSE visibility, the next
  step reported as `MachiningIn`, `Open` basket excluded, held LOT visible, ineligible line
  excluded, claim from WHSE succeeds, the `WHSE → line` movement row, the checkpoint on the
  same LOT, the LOT leaving the queue after the claim, and a held LOT refused at claim
  *citing the hold*.
- `0027/010` happy path — **passed unmodified**; it stages in `TRIM1-STORE` and pre-advances
  past trim, so the staging simply stopped being load-bearing.
- `0024/065` — all five assertions **passed unmodified** (only two labels corrected). This is
  the strongest evidence the change is behaviour-preserving for the normal trim path.
- `0027/090` (rework) and `0064/060` (CRT) — **passed untouched**; both already pre-advance
  their fixtures to `MachiningIn`-pending.

**A defect found during implementation, worth repeating in the guide:** when `020` Guard 1
was rewritten it went red on its *first* assertion, revealing that the **old** proc would
**accept** a LOT sitting in Trim Storage whose pending step was still `TrimIn` — i.e. a
casting could be claimed onto a machining line before it was recorded as trimmed. This
release closes that. It is also exactly what GATE 1 measures, which is why GATE 1 can return
rows in a plant that has been running fine.
