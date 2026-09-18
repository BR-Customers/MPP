# Prod release handoff -- Die cast: Submit confirms the reporting shift, and the shift starts blank

**Written:** 2026-09-18, for the agent who builds and runs the prod release.
**Branch:** `jacques/working`.
**Feature commit:** `8e501753` (Ignition only). This note is committed separately.
**Proposed range if it ships alone:** `-Since e02fa812 -Until 8e501753`. Those are the parent of `8e501753` and the commit itself. The trial build in § 2 used this range.
**Previous release:** `192c77c1` (0089, `notes/2026-09-16_prod-release-runbook-item-type-reclassify.md`). That runbook's Outcome is still unfilled, so confirm prod's state first.
**Builds on:** nothing unreleased. `DieCastBody` has no commit between `192c77c1` and `8e501753` other than this one. `Oee/Shift/code.py` at `8e501753` is the `192c77c1` file plus one added function.

This note is scoping input for `prod-release-context-pack/07_writing_the_runbook.md`. It is **not** the runbook. The five deliverables in `01_the_release_contract.md` are still owed.

---

## 0. Check these first

1. **Do NOT export `Oee/Shift` from HEAD unless `df99b8d5` ships whole.**
   - `df99b8d5` ("fix(attribution): every mutation's AppUserId comes from its caller") was committed straight after this feature.
   - It is 100 files. It includes a new repeatable `R__Location_AppUser_GetActiveByAdAccount` and a new `BlueRidge.Common.Util.requireAppUserId`.
   - It also rewrites `Oee/Shift/code.py`, so that `start` / `end` / `acknowledgeHandover` call `requireAppUserId`.
   - Shipping HEAD's `Shift/code.py` without the rest of `df99b8d5` would put a call to a function prod doesn't have on those three paths. That is why the range above stops at `-Until 8e501753`.
   - If this is bundled with `df99b8d5`, the problem goes away. Jacques decides the bundling.
2. **A range that starts at `192c77c1` also carries about 98 other commits.** They include Line Inventory, Trim OUT layout, cutover location-first, tool shot count, and migrations `0090`-`0093` (see the 2026-09-17 handoffs). To ship this feature alone, use the narrow range above.
3. **The two `resource.json` diffs in the working tree are not part of this change.**
   - They sit beside `DieCastBody` and `Oee/Shift`.
   - They are Gateway bookkeeping only: signature and timestamp. The content files match their committed versions.
   - The builder ships the committed manifests, which is correct.
   - The same applies to about 390 other `resource.json` files in the tree.
4. **Not clicked through end-to-end.**
   - The blank shift default was seen live on Dev at `/shop-floor/die-cast`: the dropdown shows "Select a shift".
   - The confirmation popup has never been opened. Testing it needs a PIN sign-in, a mounted die, a counter reading and a Compute.
   - Do that on Dev before release, or make it the first post-deploy check (§ 5).

---

## 1. What it does, in plant terms

Operators kept submitting die cast shift reconciliations against the wrong shift. The screen pre-selected the current shift, and they submitted against it when they meant the shift that had just ended.

**The reporting shift now starts blank.** It is blank:
- when the page loads;
- after switching press;
- after a successful submit.

Every operator must pick their shift. Compute already refused to run with no shift and asked the operator to pick one.

**SUBMIT SHIFT ENTRY opens a confirmation popup** (`DieCastShiftConfirm`):
- "You are submitting shift output for:" followed by the shift name in 52px bold capitals on a warning-coloured banner, for example **DAY - 09/18 (CURRENT)**.
- A dropdown, pre-set to that shift, with the prompt "Wrong shift? Pick the right one".
- **CONFIRM & SUBMIT** submits exactly as before.
- Choosing a different shift swaps the button to **CHANGE SHIFT & RECOMPUTE**.
  - This reruns the shift maths for the new shift and **submits nothing**.
  - An info toast says the totals were recomputed and asks the operator to review and press Submit again. That re-opens the popup with the new shift.
- The recompute keeps the scrap and Good figures already typed. Only per-cavity shots and proposals are re-read.
- If the recompute fails, the old shift's rows are cleared and the operator is told to press Compute. Rows from the wrong shift are never left on screen.
- The popup has no close X and ignores clicks outside it. Cancel is the only way out without acting.

**Stale-rows guard.** Before this change, changing the dropdown after Compute left the previous shift's rows on screen, and Submit sent them under the new shift id. The screen now records which shift its rows were computed for (`breakdownShiftId`). If that differs from the selected shift, Submit recomputes instead of opening the popup.

**Basket Release is unchanged in effect.** Release on the Lot Management tab reads the same shift field.
- With no shift picked, it falls back to `custom.defaultShiftId`, the press's current shift. That is the value the old pre-selection gave it.
- Release therefore never sends a NULL shift. `Lots.DieCastLot_Release` writes whatever shift it receives into `DieCastContribution` and `RejectEvent`, and resolves its watermarks from it.

---

## 2. Scope

### Versioned migrations
**None.**

### Repeatables
**None.** No SQL changes at all.

### Ignition resources (trial build 2026-09-18: `-Since e02fa812 -Until 8e501753`)

| Project | Resource | State | Change |
|---|---|---|---|
| Core | `ignition/script-python/BlueRidge/Oee/Shift` | MOD | Adds `labelFor(shiftId, _arg=None)`. It returns the `getRecentOptions` label for one shift id: `''` for None, and `'Shift #<id>'` when the id is outside the three-shift window. It is used by the popup headline and the toasts. Nothing else in the file changed. |
| MPP | `views/BlueRidge/Components/Popups/DieCastShiftConfirm` | NEW | The popup. Params `shiftId`, `popupId`, `replyMessage`. It replies page-scoped with `{action: confirm/change/cancel, shiftId}`. |
| MPP | `views/BlueRidge/Views/ShopFloor/DieCastBody` | MOD | See the view change list below. |

**`DieCastBody` view changes:**
- New customMethods:
  - `requestSubmitShiftOutput`: the button's new target. It gates on shift chosen, rows present, rows matching the shift, and `canSubmit`, then opens the popup.
  - `changeReportingShift`.
- New message handler `dieCastShiftConfirmResult`. **Confirm** submits only if the shift id in the reply still equals the selected shift.
- `computeBreakdown` now returns True/False and records `breakdownShiftId`.
- The shift seeding was removed from `startup`, from `applyCell`, and from the `custom.defaultShiftId` onChange (that onChange is deleted; the binding itself stays).
- `_afterSubmit` blanks the shift.
- `requestRelease` / `releaseBasket` use the release fallback described in § 1.
- The pickled default `selectedShiftId: 20107` (a Dev id) is now `null`. Shipping the old value would have pre-selected a Dev shift id in prod.
- The `CounterLabel` and `BackdatedNotice` expressions gained an `isNull(selectedShiftId)` guard, so a blank shift doesn't read as back-dated.

**Expected builder output:**
```
Core           1 resource(s),   3 entries
MPP            2 resource(s),   5 entries
MPP_Config   no changed resources -- skipped
1 manifest(s) rewritten to drop an excluded file (thumbnail.png).
```

**Verified in the trial archive:** the shipped `Shift/code.py` contains `def labelFor` (1) and `requireAppUserId` (0). **No deletions.** Rebuild at the actual release commit.

### Ships nothing
- this note

---

## 3. Risk -- the four tests

**Test 1: does anything now refuse what it used to allow?** Yes, in the UI, by design. There is no SQL rejection.
- Submit now needs a shift picked by hand. Before, one was always pre-picked.
- Submit now takes one extra confirm click.
- Submit after changing the shift post-Compute now recomputes instead of submitting.

Operators will notice all three on the first shift. That is the point of the change. Tell the floor lead before the window.

- Basket Release is **not** newly refused, because of the fallback in § 1.
- The counter-anchor popup (`openCounterAnchor`) already refused to open with no shift ("Mount a die and select a shift first"). With a blank default, an operator now sees that prompt until they pick a shift.

**Test 2: is any of it shared code?**
- `Oee.Shift` is Core, but the change only adds a function. No existing function changed in the shipped file.
- `DieCastBody` is embedded by `DieCastShared` (`/shop-floor/die-cast`, `/area/:areaId`) and `DieCastDedicated` (`/shop-floor/die-cast/dedicated`). Both get the change.
- The popup is used only by `DieCastBody`.

Blast radius: the die cast screen's Reconcile tab, plus the shift passed to Release on its Lot tab.

**Test 3: is the schema change metadata-only?** There is no schema change.

**Test 4: does old Ignition work against new SQL, and new against old?** There is no SQL.
- **Import Core before MPP.** If MPP lands first, the popup's `runScript("BlueRidge.Oee.Shift.labelFor", ...)` has nothing to call, and the headline comes up empty or as a binding error until Core is imported.
- The two imports are otherwise independent.

**Rollback:**
- Re-import `DieCastBody` and `Oee/Shift` as they were at `e02fa812`. Build with `-Since <some ancestor> -Until e02fa812`, or restore them from the pre-import Gateway backup.
- `DieCastShiftConfirm` can stay on the Gateway; nothing references it once `DieCastBody` is rolled back. Delete it in the Designer if you want it gone.
- There's no data to unwind.

---

## 4. Rehearsal expectations

- No SQL, so `Deploy-ProdRelease` has nothing of this feature's to show. If this ships alone, the SQL steps are skipped entirely and the release is exports-only.
- **Dev state:** `8e501753` is on the shared Dev Gateway, loaded by `scan.ps1` on 2026-09-18. `/shop-floor/die-cast` rendered with Reporting shift blank ("Select a shift"), behind the PIN popup.
- All `DieCastBody` event and handler scripts plus the popup's scripts were syntax-checked with a Python parser. Every event carries a `scope` (a missing one blanks the view).
- `view.json` was edited as structured JSON with Designer's serializer settings, and its round-trip was checked byte-identical before editing. The diff is 44 lines.
- **Owed:** one click-through on Dev.
  1. PIN in, with a die mounted.
  2. Enter a counter reading, then Compute.
  3. Press Submit. Check that the popup shows the shift in large text.
  4. Choose another shift, then CHANGE SHIFT & RECOMPUTE. Check for the toast and changed shots.
  5. Press Submit again. The popup should now show the new shift.
  6. Press Cancel. Nothing should be written.

---

## 5. Post-deploy verification (prod)

1. **F5 each die cast workstation.** The Reconcile tab's **Reporting shift is blank**, and the "not the one in progress" warning is **not** shown.
2. Pick a shift, enter the counter, Compute, then press **SUBMIT SHIFT ENTRY**.
   - The popup shows that shift's name large and bold.
   - **Cancel** writes nothing, and the grid is unchanged.
3. Press Submit again and choose a different shift in the popup. The button reads **CHANGE SHIFT & RECOMPUTE**.
   - Press it. The popup closes, an info toast names the new shift, the SHOTS column is re-read, and entered scrap is still there.
   - Press Submit again. The popup shows the new shift.
4. **If Jacques wants a live write,** press **CONFIRM & SUBMIT** on a real reconciliation.
   - Expect "Shift reconciled".
   - The Reporting shift goes back to blank.
5. **The one surface that is not the feature:** on the Lot Management tab, with the Reconcile shift still blank, release a basket.
   - It succeeds.
   - The new `Workorder.DieCastContribution` row carries the press's current `ShiftId`, not NULL:
   ```sql
   SELECT TOP 3 Id, LotId, ShiftId, EventAt FROM Workorder.DieCastContribution ORDER BY Id DESC;
   ```
6. The die cast screen's console shows no Component Error.
