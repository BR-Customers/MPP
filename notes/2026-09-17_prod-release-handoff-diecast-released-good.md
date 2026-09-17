# Prod release handoff -- Die cast: a released basket proposes 0 good, and Good shows "-"

**Written:** 2026-09-17, for the agent who builds and runs the prod release.
**Branch:** `jacques/working`.
**Feature commits:**
- `fb61f627`: SQL proc and its tests.
- `b47d0a34`: the Ignition view.
- This note.

**Proposed `-Since`:** `02079cbf`, the parent of `fb61f627`. It is almost certainly bundled with the other pending 2026-09-17 handoffs (tool shot count, cutover location-first, Trim OUT layout). For a bundle, use the earliest `-Since`, which is `8ba40203` for those.
**Previous release:** `192c77c1` (0089, `notes/2026-09-16_prod-release-runbook-item-type-reclassify.md`).
**Builds on:** nothing unreleased. Prod already has the files these commits replace:
- proc v3.0, shipped in the 2026-09-15 die-cast scrap-model release;
- `CavityLotRow` as of `bc1476eb`, which is an ancestor of `192c77c1`.

This note is scoping input for `prod-release-context-pack/07_writing_the_runbook.md`. It is **not** the runbook, and the five deliverables in `01_the_release_contract.md` are still owed.

---

## 0. Check these first

1. **The `02079cbf..HEAD` range contains commits from other features.** They include:
   - `1fd6ffe8`: ScrapLineRow manifest signature (Trim).
   - `d4a312f5` and `41a921d4`: docs.
   - anything committed later.

   If this ships alone, build the export with `-Until b47d0a34`. Even then, `1fd6ffe8` falls inside the range and would ship. If this ships bundled, which is the likely case, it's moot.
2. **The Trim OUT handoff (`notes/2026-09-17_prod-release-handoff-trim-out-layout.md` § 0.1) asks whether `fb61f627` ships with Trim.** This note is the answer to "what is `fb61f627`". Jacques decides the bundling.
3. **The `CavityLotRow/resource.json` manifest was deliberately not committed.** The working tree has a Gateway bookkeeping diff (signature and timestamp from 2026-09-11) that is not part of this change. The builder ships the committed manifest, which names only `view.json`. That is correct.

---

## 1. What it does, in plant terms

Die Cast shift output (`DieCastBody` → Record / Reconcile Shift grid, one `CavityLotRow` per cavity/basket).

When a cavity rolled its basket mid-shift, it shows two rows: the released basket and the open one. Before this change, the released basket's row showed a **greyed 0** under GOOD next to its non-zero SHIFT GOOD (for example 66). Operators read that as "this basket made nothing".

- **GOOD now shows "-"**:
  - on a basket released earlier this shift, which takes scrap only;
  - on a cavity with no basket.

  This is the same rule and style as the VARIANCE column's dash. The tooltip says why there's nothing to credit.
- **SHIFT GOOD is unchanged.** It still shows what that basket was credited this shift.
- **Open baskets are unchanged:**
  - GOOD is pre-filled and editable;
  - scrap entry works on every row, including released ones.

**Underneath:** `Workorder.DieCast_GetShiftOutputBreakdown` v3.1 now returns `ProposedGood = 0` for a released basket, where it used to return its shift credit. That old value was left over from the v1.0 cumulative-split model:
- every screen consumer already overrode it;
- `DieCastShiftOutput_Record` rejects `pieceDelta > 0` on a non-Open basket, so 0 is the only value it would accept.

The shift credit is still returned as `PriorGoodThisShift`, and the result-set columns are unchanged.

---

## 2. Scope

### Versioned migrations
**None.**

### Repeatables
| Object | State | Effect |
|---|---|---|
| `R__Workorder_DieCast_GetShiftOutputBreakdown` | CHANGED (v3.0 → v3.1) | The released-basket branch of `ProposedGood`: `ISNULL(p.PriorGood,0)` → `0`, plus header comments. |

`[4]` will also list repeatables from the other bundled features. Only the one above belongs to this feature.

### Ignition resources (trial build 2026-09-17: `-Since 41a921d4 -Until b47d0a34`)
| Project | Resource | State |
|---|---|---|
| MPP | `views/BlueRidge/Components/PlantFloor/DieCastEntry/CavityLotRow` | MOD |

Expected builder output for this feature alone:
```
Core         no changed resources -- skipped
MPP            1 resource(s),   3 entries
MPP_Config   no changed resources -- skipped
```

**View change:**
- a new `GoodNA` label (text `-`, class `pf-kpi-sub`) as the first child of `CavityContent/MainLine/GoodCell`, displayed when `{view.params.isPending} || !{view.params.isOpen}`;
- `GoodInput` gains a `position.display` binding with the exact inverse.

No scripts changed. `recompute()` still forces `goodValue = 0` on those rows as a guard. **No deletions. No Core resources.** Rebuild at the actual release commit.

### Ships nothing
- `sql/tests/0045_DieCast_Lifecycle/030_ShiftOutput_Record.sql`
- this note

---

## 3. Risk -- the four tests

**Test 1: does anything now refuse what it used to allow?** No. The only rejection involved already existed: the write proc has refused pieces on a released basket since v2.1. The GOOD input on released and basketless rows was already disabled; it's now hidden and replaced by a dash. **No gate needed.**

**Test 2: is any of it shared code?**
- `CavityLotRow` is embedded only by `Views/ShopFloor/DieCastBody`.
- The proc's only runtime caller is `BlueRidge.Workorder.DieCast.getShiftOutputBreakdown` (NQ `workorder/DieCast_GetShiftOutputBreakdown`), which is used only by `DieCastBody`. Other SQL files mention it only in comments.
- `DieCastBody` reads `ProposedGood` only for **open** rows: in `recomputeTotals` and `submitShiftOutput` it skips released rows or sends `pieceDelta: 0` for them.

Blast radius: the die-cast shift-output grid.

**Test 3: is the schema change metadata-only?** There is no schema change; this is a `CREATE OR ALTER` of one read proc.

**Test 4: does old Ignition work against new SQL, and new against old?**
- **Old view with the new proc:** fine. The old view forced GOOD to 0 on these rows regardless of the proc.
- **New view with the old proc:** fine. The dash depends only on `isOpen` / `isPending`, and `recompute()` still zeroes the value.

There's no ordering constraint of its own, but follow the normal order (SQL first).

**Rollback:**
- re-apply `R__Workorder_DieCast_GetShiftOutputBreakdown.sql` as it was at `02079cbf` (v3.0);
- re-import `CavityLotRow` as it was at `41a921d4`.

There's no data to unwind; the proc is read-only.

---

## 4. Rehearsal expectations

For this feature alone, rehearsed at prod's state (`05_local_rehearsal.md`):
- `[3]`: 0 pending.
- `[4]`: `R__Workorder_DieCast_GetShiftOutputBreakdown` CHANGED. The per-object diff should show only the header comment block and the one `WHEN lo.IsOpen = 0 THEN 0` line.
- `[5]`: nothing new.

**Local evidence (2026-09-17):**
- **Tests:** `Run-Tests.ps1 -Filter "DieCast"` on `MPP_MES_Test` gave **347 passed, 0 failed**. That includes the updated `[MultiLot]` assertions:
  - released lot A proposes 0;
  - its `PriorGoodThisShift` is still 40;
  - the open lot's proposals are unchanged.
- **Runner exit code:** 1, because four unrelated files in `0022_PlantFloor_DieCast` (030, 040, 050, 070) error during their setup data: a `Tools.ToolAssignment.CellLocationId` NULL insert. None of them call this proc. A separate session is fixing them.
- **Dev:** the proc is applied to `MPP_MES_Dev`, the view was loaded by gateway scan, and `wrapper.log` shows no deserialize error.
- **Not checked visually.** Nobody has yet looked at the grid with a released basket after the change. Do that on Dev before release, or make it the first post-deploy check.

---

## 5. Post-deploy verification (prod)

1. Open Die Cast shift output on a press where a cavity rolled its basket this shift. Enter the counter reading and Compute.
   - The **released basket's** row shows **"-" under GOOD**, the "released earlier this shift - scrap only" note, its SHIFT GOOD value, and "-" under VARIANCE.
   - The **open basket's** row shows GOOD pre-filled and editable, with variance behaving as before.
   - A **cavity with no basket**, if there is one, shows "-" under GOOD, and its pending strip is unchanged.
2. **If Jacques wants a live write:** enter scrap on the released basket's row and submit.
   - Expect success, with no "cannot take more pieces" message.
   - The released basket's SHIFT GOOD is unchanged afterwards.
3. The die-cast screen console shows no Component Error on any row.
