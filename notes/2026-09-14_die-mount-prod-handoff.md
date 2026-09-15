# Die Mount — prod deployment handoff

**Date:** 2026-09-14
**For:** the agent producing the prod release content (preview / rehearsal / execute / scoped exports / instruction guide)
**From:** the session that built it
**Branch:** `jacques/working`
**Spec:** `docs/superpowers/specs/2026-09-14-plant-floor-die-mount-popup-design.md` (v0.3, status "built")

This is everything you need to include this work correctly. It is **not** the runbook —
producing that is your job, per CLAUDE.md § Production deployments (preview with plan
fingerprint, rehearsal in a rolled-back transaction, fingerprint-guarded execute after a
verified `COPY_ONLY` backup, scoped exports built from git, and a published instruction
guide mirrored to `notes/`).

---

## 1. The commits

| Commit | Subject | Layer |
|---|---|---|
| `3616026e` | feat(diecast): mount and release a die at the press | 4 procs, 4 test suites, Core NQ + 2 entity scripts, DieMount popup |
| `bf377911` | feat(diecast): route the press button to the Die Mount popup | `DieCastBody` view |
| `860d4d83` | fix(elevation): the replay payload was a view into a property we had just cleared | `Common.Session` + both replay handlers |
| `8e298c24` | docs(diecast): die mount spec v0.3 | docs only — not deployable |

Other sessions committed interleaved with these; the four above are the complete set for
this feature. Nothing here has been deployed anywhere but Dev.

---

## 2. What ships

| Layer | Object | Change |
|---|---|---|
| SQL | `Tools.Tool_ListEligibleForCell` | **NEW** read proc |
| SQL | `Tools.ToolAssignment_Release` | v1.0 → **v1.1** — open-basket rejection |
| SQL | `Tools.ToolAssignment_GetCellContext` | **v1.1** — `OpenBasketCount` appended last |
| SQL | `Tools.ToolCavity_Deprecate` | v1.0 → **v1.1** — open-basket rejection |
| Core | `ignition/named-query/parts/Tool_ListEligibleForCell` | **NEW** (`type: Query`, one param `cellLocationId` `sqlType: 3`) |
| Core | `script-python/BlueRidge/Parts/Tool` | `getEligibleToolPicker`; `OpenBasketCount` + `_refreshToken` on `getCellMountContextOrEmpty`; `import java.lang` |
| Core | `script-python/BlueRidge/Common/Session` | `DieMount` replay entry **and the shared replay-payload fix** |
| MPP | `views/BlueRidge/Components/Popups/DieMount` | **NEW** view (`view.json` + `resource.json`, scope `G`) |
| MPP | `views/BlueRidge/Views/ShopFloor/DieCastBody` | Button repointed; `openDieMount()`; two page-scoped handlers |

**All four procs are repeatable (`CREATE OR ALTER`). There is NO versioned migration** —
nothing about the schema changes. Expect `Preview` to report **0 pending migrations,
4 changed procs**. If it reports a pending migration, something else has ridden along and
you should stop and reconcile.

Test suites in `3616026e` are repo-only (they never run against prod) but they are the
evidence: 246/246 pass, 39 new.

---

## 3. Risk — read this before writing "low risk"

Most of this is additive. **Two parts are not**, and both land on an existing surface that
is in daily use:

1. **`ToolAssignment_Release` now refuses while the die holds an open basket.** The Config
   Tool's `CellMountCard` calls the same proc and inherits the refusal — deliberately
   (spec §5.4), but it means a supervisor at a desk who could previously release a mount
   at any time now cannot while baskets are open. **In a live plant, open baskets are the
   normal state**, so this is not a rare edge case; it is the common one. Pre-flight
   query 3B below tells you exactly how many presses are in that state right now.

2. **`ToolCavity_Deprecate` now refuses while the cavity holds an open basket.** Same
   class of change, same surface (Config Tool).

Neither is a regression — both are the point of the change, and the operator can always
clear the block (Release a basket with pieces, Void an empty one, both on the Die Cast
screen, neither needing elevation). But they *will* generate a "why can't I…" call on day
one if nobody is told. The instruction guide should say so in plain language.

3. **`Common.Session` is shared code.** The replay fix touches every elevated action
   (`DowntimeReason`, `DowntimeEdit`, `DowntimeVoid`, `SortCageMigrate`, `CrtToggle`), not
   just Die Mount. It is a strict repair — it also fixes a latent `DowntimeEdit` bug where
   the first downtime edit after an elevation prompt opened the editor with no event id —
   but the blast radius is wider than the feature, and post-deploy verification must prove
   one **non-Die-Mount** elevated action still works. See §7.

---

## 4. Deploy order — SQL first, then Core, then MPP

This order is required, and the reverse is not safe.

- **SQL before Ignition is safe.** The Ignition currently on prod keeps working against the
  new procs: `GetCellContext` gains a *trailing* column, and `Common.Db.execList` builds
  `dict(zip(headers, row))`, so an extra key simply appears unused. No existing caller
  passes a new parameter.
- **Ignition before SQL is NOT safe.** `getEligibleToolPicker` calls a proc that would not
  exist yet. It is guarded (`except (Exception, java.lang.Exception)` → shaped empty dict,
  so the popup degrades to an empty dropdown rather than erroring) but the feature would be
  visibly broken in the window.
- **Core before MPP.** `DieCastBody` calls `BlueRidge.Common.Session.requireElevation` with
  the `DieMount` code, and the popup calls `BlueRidge.Parts.Tool.getEligibleToolPicker`.
  Both live in Core.

Rollback is the exact reverse: **MPP → Core → SQL.** Rolling back SQL first would leave
Core's NQ pointing at a missing proc.

Rollback mechanics: every proc is `CREATE OR ALTER`, so rolling back is redeploying the
prior version from the parent commit (`3616026e~1`). There is no data migration to undo and
nothing is dropped.

---

## 5. Scoped exports

```powershell
.\tools\Build-ChangeExport.ps1 -Since <last-ref-prod-has> -Until 860d4d83 -Label die-mount
```

`-Since` must be whatever Ignition ref prod is actually on — determine it, do not assume.
The tool builds **from git**, not the working tree, which matters more than usual right
now: this shared tree has ~442 uncommitted files from other sessions and `scan.ps1`
rewrites resource manifests on every scan. Do not stage anything.

Verify the zips contain exactly these and nothing else:

**Core** (imports first)
```
ignition/named-query/parts/Tool_ListEligibleForCell/{query.sql,resource.json}
ignition/script-python/BlueRidge/Parts/Tool/code.py
ignition/script-python/BlueRidge/Common/Session/code.py
```

**MPP**
```
views/BlueRidge/Components/Popups/DieMount/{view.json,resource.json}
views/BlueRidge/Views/ShopFloor/DieCastBody/view.json
```

If the range you pick sweeps in other sessions' Ignition work, narrow it or split the
release — do not ship someone else's uncommitted-yesterday work inside this one.

---

## 6. Pre-flight gates — prod-specific, read-only

These are the checks only this change needs. Run them against prod **before** the window
and put the numbers in the guide; two of them change what you tell Jacques.

### 6A. Orphan baskets (the spec §10 check)

```sql
SET NOCOUNT ON;
DECLARE @Open BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open');

SELECT 'A_open_on_unmounted_die' AS Chk, COUNT(*) AS N
FROM Lots.Lot l
WHERE l.LotStatusId = @Open AND l.ToolId IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM Tools.ToolAssignment ta
                  WHERE ta.ToolId = l.ToolId AND ta.ReleasedAt IS NULL)
UNION ALL
SELECT 'B_cell_mismatch', COUNT(*)
FROM Lots.Lot l
INNER JOIN Tools.ToolAssignment ta ON ta.ToolId = l.ToolId AND ta.ReleasedAt IS NULL
WHERE l.LotStatusId = @Open AND ta.CellLocationId <> l.CurrentLocationId
UNION ALL
SELECT 'C_invisible_basket', COUNT(*)
FROM Lots.Lot l
LEFT JOIN Tools.ToolCavity tc ON tc.Id = l.ToolCavityId
WHERE l.LotStatusId = @Open
  AND (l.ToolCavityId IS NULL OR tc.DeprecatedAt IS NOT NULL)
UNION ALL
SELECT 'D_total_open', COUNT(*) FROM Lots.Lot WHERE LotStatusId = @Open;
```

Dev on 2026-09-14: A=0, B=0, C=0, D=21.

**A and B must be resolved before the guard ships** — they are genuine orphans and
`sql/scratch/2026-09-14_orphaned_basket_check.sql` (another session's, already committed)
plus `sql/scratch/2026-09-14_close_stranded_basket.sql` are the tools for it.
**C is not release-blocking** — the guard is cavity-scoped and steps around exactly this
population — but report the count anyway: it is invisible production and it under-counts
a die's life, and a non-zero number is the measure of how late the `ToolCavity_Deprecate`
guard is arriving.

### 6B. How many presses the guard would block *right now*

This is the one that shapes the message to Jacques.

```sql
SET NOCOUNT ON;
DECLARE @Open BIGINT = (SELECT Id FROM Lots.LotStatusCode WHERE Code = N'Open');

SELECT loc.Code AS Press, t.Code AS Die, COUNT(l.Id) AS OpenBaskets
FROM Tools.ToolAssignment ta
INNER JOIN Tools.Tool     t   ON t.Id   = ta.ToolId
INNER JOIN Location.Location loc ON loc.Id = ta.CellLocationId
INNER JOIN Lots.Lot       l   ON l.ToolId = ta.ToolId AND l.LotStatusId = @Open
INNER JOIN Tools.ToolCavity tc ON tc.Id = l.ToolCavityId
                              AND tc.ToolId = ta.ToolId AND tc.DeprecatedAt IS NULL
WHERE ta.ReleasedAt IS NULL
GROUP BY loc.Code, t.Code
ORDER BY loc.Code;
```

Every row is a press whose die **cannot be unmounted** until those baskets are released or
voided. That is correct behaviour, and in a running plant the list may be long. The guide
needs to state the expected day-one experience honestly rather than implying nothing
changes.

### 6C. Will the eligibility shortlist actually do anything?

```sql
SET NOCOUNT ON;
SELECT m.Code AS Press,
       (SELECT COUNT(DISTINCT t.Id)
        FROM Tools.Tool t
        WHERE t.DeprecatedAt IS NULL
          AND EXISTS (SELECT 1 FROM Tools.ToolCavity tc
                      INNER JOIN Parts.ItemLocation il ON il.ItemId = tc.ItemId
                      WHERE tc.ToolId = t.Id AND tc.DeprecatedAt IS NULL
                        AND il.LocationId = m.Id AND il.DeprecatedAt IS NULL)) AS MappedDies
FROM Location.Location m
INNER JOIN Location.LocationTypeDefinition d ON d.Id = m.LocationTypeDefinitionId
WHERE d.Code = N'DieCastMachine' AND m.DeprecatedAt IS NULL
ORDER BY m.Code;
```

A press with `MappedDies = 0` will show **every** compatible unmounted die, flagged
`IsEligible = 0`, with the muted line *"No die is mapped to this press — showing all
available dies."* That is the designed fallback (eligibility shortens a list, it never
refuses one), not a fault — but if most presses come back 0, say so in the guide, because
the feature will look like it is not filtering.

Note the shortlist also collapses to the fallback when the mapped die is **already
mounted**, since an unmounted-die predicate applies in both branches. That is the normal
state of a running press and resolves itself at the changeover, which is the only moment
the list matters. In Dev this is exactly what happens: `6MA-A` / `6MA-B` are the only
mapped dies and both are mounted.

---

## 7. Post-deploy verification

**SQL smoke** (read-only, safe on prod):

```sql
EXEC Tools.Tool_ListEligibleForCell @CellLocationId = <a real press id>;
EXEC Tools.ToolAssignment_GetCellContext @CellLocationId = <same>;   -- OpenBasketCount present
```

**Ignition:** `scan.ps1` equivalent for prod, then check `wrapper.log` for GSON
deserialize errors. A missing read NQ shows up as *"Named query not found"* and as a
silently inert screen, so confirm `parts/Tool_ListEligibleForCell` resolves.

**Runtime click-through at a die cast terminal** — the spec's §10 list. Priority order:

1. Press **Die Mount** with no elevation window: the AD prompt appears and, on success,
   **the popup opens by itself**. A second tap being required is the exact bug `860d4d83`
   fixed; if you see it, the Core script did not land.
2. A die with open baskets → **Release disabled**, reason line visible, and the count
   matches the baskets listed on the Die Cast screen behind the popup.
3. Release/void those baskets on the Die Cast screen → Release enables.
4. A changeover (Release then Mount) raises the modal **once**, not twice.
5. Cancelling the elevation opens nothing and writes nothing; a later unrelated elevation
   does not resurrect the dismissed popup.
6. **One non-Die-Mount elevated action from cold** — a downtime *edit* with no elevation
   window open. This is what proves the shared `Common.Session` change is good, and it is
   the step most likely to be skipped.

**Confirmed at a Dev terminal, 2026-09-14 (Jacques):** the popup works end to end — one
tap on **Die Mount**, the AD prompt, and the popup opens by itself on success. That is
item 1 above, and it is also the direct confirmation that `860d4d83` fixed the replay:
the same flow required a second tap before it.

Also confirmed by Jacques the same day:

- Item 2/3 — the **open-basket block**. Release is disabled with the reason line while the
  die holds an open basket, and enables once the basket is cleared. This is the half of
  the feature that changes Config Tool behaviour in prod, so it mattered that it was
  exercised rather than assumed.
- Item 6 — **a non-Die-Mount elevated action from cold**. This is the proof that the
  shared `Common.Session` replay fix is good for the other four elevated actions
  (`DowntimeReason`, `DowntimeEdit`, `DowntimeVoid`, `SortCageMigrate`, `CrtToggle`), and
  it is a path this feature's own testing never touches.

**So the Dev-side verification is complete.** Items 4 and 5 (a single modal across a
Release-then-Mount changeover; cancelling the elevation leaves no phantom state) are
lower risk and are left for the prod click-through.

What remains genuinely unverified is prod's **data**, not the code — the three pre-flight
queries in §6 are still the gate, and §6B in particular is expected to return rows on a
running plant where Dev returned few.

---

## 8. Things not to "fix" on the way through

- **The release guard is cavity-scoped on purpose.** `Lots.Lot_GetOpenByTool` is
  cavity-driven and filters `tc.DeprecatedAt IS NULL`, and `Lots.Lot.ToolCavityId` is
  nullable, so a die-wide `EXISTS` would count baskets the operator cannot see — the screen
  says three, lists two, and the die never comes off. The governing rule is recorded in
  both proc headers: **whatever the guard counts, the screen must show.**
- **The tests that look backwards are correct.** An open LOT on a deprecated cavity, or
  with a `NULL` `ToolCavityId`, must **not** block a release.
- **`Tool_ListMountableForCell` is deliberately untouched** and still serves the Config
  Tool's `CellMountCard`. Two purpose-named read procs, one caller each.
- **The Config Tool link on the Die Cast screen was removed, not relocated** (decision 3).

---

## 9. Known operational gotchas

- Hand-run `sqlcmd` needs **`-I`** (quoted identifiers) or the diagnostic queries fail.
- **Do not commit between preview and execute** — the plan fingerprint includes HEAD, so a
  commit makes Execute refuse. Harmless, but it costs a re-preview. On this branch another
  session commits frequently, so keep the window tight.
- Exports must be built **from git**, never the working tree (§5).
- Core imports before MPP.
- MPP declares `"parent": "Core"`, so a view path absent from MPP may still resolve from
  Core — do not treat that as a broken reference.

---

## 10. Out of scope for this release

- The press-filter follow-up on `Lots.Lot_GetOpenByTool` (spec §5.5). **If anyone picks it
  up, it must change the guard predicate too** or it re-opens the count/screen mismatch
  from the other side.
- An optional "hand off without closing" mode for `ElevationModal` — under discussion, to
  remove the modal-closes-then-modal-opens transition. Not built.
- Any supervisor-elevated override of the open-basket block. Considered and rejected
  (spec §5.3.1); if it ever gets built it needs its own reason code, audit row and
  recovery surface.
