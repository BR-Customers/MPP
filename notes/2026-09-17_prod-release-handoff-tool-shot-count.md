# Prod release handoff -- Tools screen die shot-count correction

**Written:** 2026-09-17, for the agent who builds and runs the prod release.
**Branch:** `jacques/working`. **Feature commits:** `0a629690` `ea5756fe` `ffeb7c18` (+ docs `9344a02a` `716f4593` `b09cb991`, and this note).
**Proposed `-Since`:** `8ba40203` (the 0089 runbook commit). Everything from there to this feature is docs-only.
**Spec / plan:** `docs/superpowers/specs/2026-09-17-tool-shot-count-correction-design.md`, `docs/superpowers/plans/2026-09-17-tool-shot-count-correction.md`.

This note is the scoping input for `prod-release-context-pack/07_writing_the_runbook.md`. It is **not** the runbook. You still owe the five deliverables in `01_the_release_contract.md`: preview, rehearsal, execute, scoped exports, and a published instruction guide mirrored to `notes/<date>_prod-release-runbook-tool-shot-count.md`.

---

## 0. Check this first -- has 0089 gone out?

The newest runbook, `notes/2026-09-16_prod-release-runbook-item-type-reclassify.md` (release commit `192c77c1`, migration `0089`), has an **unfilled Outcome section**. Before scoping, confirm in the preview's `[3]` whether prod's high-water mark is `0089`. If it is `0088`:

- this release carries `0089` with it, and that runbook's gates, risk and verification apply too, **or**
- Jacques runs the 0089 release first.

Ask Jacques which one. Don't fold 0089 in silently.

---

## 1. What it does, in plant terms

Doug (die manager) can now type a die's **actual lifetime shot count** on Config Tool -> Parts -> Tools (the **Current Shots** field). He does this at cutover, and again whenever he has to fix a wrong count. Changing the count makes a **Shot Count Change Note (required)** field appear. Save refuses a blank note. Shot Limit and Current Shots show and accept thousands separators (`1,200,000`) and still store an `INT`.

Every correction writes one `Audit.ConfigLog` row, visible in the Audit Browser:
`<Code> — <Name> · Shot Count · 812,400 → 850,000 · <note>`. The full note is in `NewValue.Note` and the signed delta is in `NewValue.Delta`.

The correction changes **only** `Tools.Tool.ShotCount`. It writes no `Workorder.DieCastContribution` row and moves no shot watermark or counter anchor. Basket crediting and shift reconciliation are unaffected.

---

## 2. Scope

### Versioned migrations
**None.**

### Repeatables
| Object | State on prod (expected) | Effect |
|---|---|---|
| `Tools.Tool_CorrectShotCount` (`R__Tools_Tool_CorrectShotCount.sql`) | **NEW** | The correction proc. Status-row, no OUTPUT params. |
| `R__Descriptions_ExtendedProperties.sql` | changed text for **one** property: `Tools.Tool.ShotCount` MS_Description | Wording only: names the new setter. |

The extended-properties script isn't a proc, so check how `Deploy-ProdRelease.ps1` classifies it (its `[4]` compares module definitions). If it isn't picked up, the description update can simply be skipped: it's documentation that ERD/SchemaGen reads, with no runtime effect. **If `[4]` lists any other `CHANGED` object, read its diff. This release doesn't explain it** (see § 0).

### Ignition resources (built and verified 2026-09-17 with `-Since 8ba40203`)
| Project | Resource | State |
|---|---|---|
| Core | `ignition/named-query/parts/Tool_CorrectShotCount` | NEW |
| Core | `ignition/script-python/BlueRidge/Parts/Tool` | MOD |
| MPP_Config | `com.inductiveautomation.perspective/views/BlueRidge/Views/Parts/Tools` | MOD |

MPP: nothing. **No deletions.**

```powershell
.\tools\Build-ChangeExport.ps1 -Since 8ba40203 -Label tool-shot-count
```

Expected: `Core 2 resource(s), 5 entries` and `MPP_Config 1 resource(s), 3 entries`; MPP skipped. Rebuild the archives at the actual release commit; the 2026-09-17 `dist/` build was only a scope check. Import **Core first**, then MPP_Config.

### Ships nothing
`sql/tests/0050_ToolShotCount/060_Tool_CorrectShotCount.sql`, `ignition/tests/test_tool_shot_inputs.py`, `tools/edit_tools_view_shot_count.py` (the one-off script that authored the view edit), `MPP_MES_DATA_MODEL.md`, `PROJECT_STATUS.md`, `docs/`, `notes/`.

---

## 3. Risk -- the four tests (`02_scoping_a_release.md` § 4)

**Test 1: does anything now refuse what it used to allow?** Yes, in Python only, on the Tools screen header Save:
- A non-numeric **Shot Limit** is now **rejected** with "Shot Limit must be a whole number of shots (got '…')." It used to be **silently saved as NULL**, which was the bug. Commas were the common case, and they now work.
- **Current Shots** can't be blank ("Current Shots cannot be blank.").
- Changing Current Shots without a note is refused.

No existing SQL proc gained a rejection, so there's no live-data row that is "newly refused". **No pre-flight gate is needed.** Optional informational query for the runbook, a baseline before Doug starts entering counts:
```sql
SELECT COUNT(*) AS ActiveDies,
       SUM(CASE WHEN t.ShotCount > 0 THEN 1 ELSE 0 END) AS DiesWithCount,
       SUM(CASE WHEN t.ShotLimit IS NOT NULL THEN 1 ELSE 0 END) AS DiesWithLimit
FROM Tools.Tool t JOIN Tools.ToolType tt ON tt.Id = t.ToolTypeId
WHERE tt.Code = N'Die' AND t.DeprecatedAt IS NULL;
```

**Test 2: is any of it shared code?** Yes. `BlueRidge.Parts.Tool` ships as a whole module. Only `getOne`, `update` and four new private helpers changed, but the **shop floor imports this module**: `Views/ShopFloor/DieCastBody` (shot-status header via `getShotStatusForCell*`) and `Components/Popups/DieMount`. Also the Config Tool's `CellMountCard` and the Tools Attributes/Cavities/Assignments embeds. Post-deploy verification must include one of these (see § 5). `Common.*` is untouched.

**Test 3: is the schema change metadata-only?** There's no schema change. One new proc and one extended-property text update.

**Test 4: does old Ignition work against new SQL?** Yes. Nothing old calls the new proc. **New Ignition against old SQL** fails only when someone saves a changed shot count ("Could not find stored procedure"). Everything else on the new screen works, because `Tool_Update` is unchanged. **Deploy SQL first**; after that, the two steps don't have to happen together.

**Rollback:** re-import the previous `Parts/Tool` script and `Parts/Tools` view (from the prior release commit), then `DROP PROCEDURE Tools.Tool_CorrectShotCount`. No data to unwind. Any corrections already made are real, audited values, so leave them.

---

## 4. Rehearsal expectations

Rehearse locally at prod's exact state (`05_local_rehearsal.md`): a temp worktree at `8ba40203` (or at `192c77c1` if prod lacks 0089 and it isn't riding along) plus `Reset-DevDatabase.ps1` under a throwaway name, then preview from HEAD. Expected:
- `[3]` 0 pending (or `0089` pending, see § 0).
- `[4]` `Tools.Tool_CorrectShotCount` **NEW**; nothing else CHANGED apart from the extended-properties note above.
- `[5]` no BLOCK or WARN introduced by this release.

**Don't rehearse on `MPP_MES_Test`.** Another session was resetting it on 2026-09-17 and killed a run mid-migration. Use a unique throwaway name.

---

## 5. Post-deploy verification (prod)

Use a die Doug names, or skip steps 3–4 if he'd rather enter the first real count himself.

1. **SQL present:** `SELECT OBJECT_ID(N'Tools.Tool_CorrectShotCount')` returns non-NULL.
2. **Tools screen loads:** pick a die. Current Shots is a text field and both shot fields show commas. The header shows **no** "Unsaved changes".
3. **Validation:** type `1,2x` in Shot Limit and Save. The error toast appears and `ShotLimit` is unchanged in SQL. Click another die and choose **Discard & Close**.
4. **A real correction (Doug's):** change Current Shots, and the note row appears. Save without a note: refused. Add the note and Save: "Tool saved", and the field reloads with commas. Then:
   ```sql
   SELECT TOP 1 c.LoggedAt, c.UserId, c.Description, c.OldValue, c.NewValue
   FROM Audit.ConfigLog c JOIN Audit.LogEntityType e ON e.Id = c.LogEntityTypeId
   WHERE e.Code = N'Tool' AND c.EntityId = <die id> ORDER BY c.Id DESC;
   ```
   Expect `NewValue` = `{"ShotCount":<new>,"Delta":<new-old>,"Note":"<note>"}`.
5. **Shared-module check (Test 2):** open a die-cast terminal (`DieCastBody`) with a mounted die. The shot-status header (count / limit / remaining) renders, with no Component Error.

---

## 6. Known behaviour worth one line in the guide

- **Stale refusal.** If a shift output is recorded for that die while Doug has the Tools screen open, his save is refused: "Shot count changed since this die was opened (now N). Reload and re-enter." The typed value and note stay on screen. To reload, he clicks another die, chooses **Discard & Close**, and comes back.
- **Two audit rows per header save.** A header save that changes only the count still runs `Tool_Update` first, and that proc always writes a "Tool updated." `ConfigLog` row even when nothing in it changed. That's pre-existing behaviour, and the second row is the correction. The legs aren't one transaction: on a stale refusal the `Tool_Update` leg has already committed. That's harmless, since it re-saves the same values.
- The stale message shows the current count without commas (`now 850100`). Cosmetic.

---

## 7. Evidence this was proven on Dev (2026-09-17)

- **SQL:** `0050_ToolShotCount` all files green on a throwaway DB (22 new assertions: up, down, zero, blank/NULL note, negative, unchanged, stale, non-Die, deprecated, missing param, audit content, no side effects, no `DieCastContribution` rows). Die-cast files `010 020 060 080 090 100 110` green.
- **Unrelated fixture failures:** die-cast `030 040 050 070` fail in fixture setup (`ToolAssignment.CellLocationId` NULL) before reaching any code under test. They predate this change, and a separate task is filed.
- **pytest:** `ignition/tests` 31/31.
- **Screen**, on `CAV-TEST-DIE` in the in-app browser:
  - bad limit rejected
  - `1,200,000` saved (SQL `1200000`)
  - count change without a note refused
  - with a note: saved, SQL `850000`, audit row correct (middle dot stored as U+00B7)
  - stale edit refused with "(now 850100)"
  - unsaved-changes prompt fires on switching dies

  The die was restored afterwards through the procs (`ShotCount 0`, `ShotLimit NULL`).
