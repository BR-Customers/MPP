# Prod release runbook: 2026-09-12 (Config Tool — unsaved-changes latch + die mount badge)

**Ignition only. There is no SQL in this release.** Nothing to preview, rehearse or
execute; no migration, no backup of `MPP_MES_Prod` required. That also means the
rollback is just re-importing the previous resources, and those archives are already
built (§5).

**Prod baseline:** `d4c29e75` — the state both prod SQL and prod Ignition have been at
since 2026-09-11. **This release:** `b7bc870e`.

The only `ignition/projects/` files that changed in `d4c29e75..HEAD` are the four below;
the other commits in the range are docs and a SQL scratch script. Both archives were
built from git and verified byte-for-byte against `HEAD`, the rollback pair against
`d4c29e75`.

---

## What ships

| Archive | Resources |
|---|---|
| `Core_config-unsaved-latch-die-badge_2026-09-12_1617.zip` | `script-python/BlueRidge/Location/Location` |
| `MPP_Config_config-unsaved-latch-die-badge_2026-09-12_1617.zip` | `views/BlueRidge/Views/Location/PlantHierarchy`<br>`views/BlueRidge/Views/Parts/Tools`<br>`views/BlueRidge/Components/Parts/Tools/Assignments` |

Three changes:

**1. Plant Hierarchy "Unsaved changes" latched on and could not be cleared.**
`Location.SortOrder` is `INT`, but the Sort Order editor is a text field whose
`props.text` — a String prop — is bound bidirectionally to the draft. Perspective
coerced the int and wrote `"3"` back, so the dirty check compared `{"sortOrder": "3"}`
against `{"sortOrder": 3}` and never matched. The banner came on with nothing edited,
every tree click raised a phantom "unsaved changes" prompt, and Save could not clear it —
the post-save re-baseline pulled the int from the DB and the text field re-wrote the
string straight after. Both halves of the comparison now hold the value in the field's
own type.

**2. Mounting or releasing a die did not update the Tools header badge.**
The "Mounted · \<Cell\>" badge depends only on the selected tool id, so a mount or
release inside the embedded Assignments section never reached it; the badge stayed wrong
until you clicked to another die and back. The intended page-scoped `toolDataChanged`
message existed as a handler but nothing ever sent it. Now it is sent, and the parent
re-reads the mount on receipt.

**3. `PlantHierarchy/view.json` shrank 180 KB → 81 KB.** It carried 188 real Location
rows and a pickled selection that Designer had been re-serialising into the resource on
every save. All of it is populated at runtime by bindings.

### Two behaviour changes worth knowing before someone reports them

- The Sort Order box on an **unselected** Location form is now blank. It used to show the
  literal text `null`.
- A **non-numeric** Sort Order is now rejected with a "Sort Order must be a whole number"
  toast instead of failing inside the JDBC layer, where it never reached the proc and so
  never reached `Audit.FailureLog`.

---

## 0. Before the window

Nothing to back up. The rollback archives in §5 are the restore path, and no database
object is touched.

Pick a moment when nobody is mid-edit in the Config Tool. Shop-floor terminals are
unaffected — the `MPP` project is not in this release.

---

## 1. Ignition: import (Core first)

Designer **File → Import**, one zip at a time, accepting overwrite for the listed
resources:

1. `Core_config-unsaved-latch-die-badge_2026-09-12_1617.zip`
2. `MPP_Config_config-unsaved-latch-die-badge_2026-09-12_1617.zip`

Core **must** go first: `MPP_Config` declares `"parent": "Core"` and will not resolve
`BlueRidge.Location.Location` without it.

**Do not** use the Gateway web page's project import — these are partial exports, not
whole projects.

Then reload any open Config Tool session (F5). A session left open across a project
update can come back with stale bindings.

---

## 2. Register the files

If the import was done through Designer this is already done. If the files were dropped
onto the project store directly instead, trigger a scan — same call `scan.ps1` makes
locally:

```
POST http://<prod-gateway>:8088/data/api/v1/scan/projects
     X-Ignition-API-Token: <token>
     Content-Type: application/json          <-- omitting this returns 403
     {}
```

No Gateway restart. A scan is enough for views and scripts.

---

## 3. Verify the tree

```
python tools/verify_project_tree.py "\\<prod-host>\c$\Program Files\Inductive Automation\Ignition\data\projects\Core"
```

…and the same for `MPP` and `MPP_Config`. All three must print `ok`.

Then confirm the prod Gateway log shows **zero** `ResourceCollectionFileTree` /
`NoSuchFileException` lines after the scan.

---

## 4. Verify the fixes (four clicks)

Each of these failed before the release and must now pass.

**a. The latch is gone.** Config Tool → **Plant Hierarchy** → click any Location and
touch nothing. No "● Unsaved changes" in the header. Click a second Location: it must
switch straight over, with no "unsaved changes" prompt.

**b. Save clears it and it stays cleared.** Go to the terminal this was reported on —
**Machining & Assembly 2 → 6MA Cam Holder Line 1 → METTs Assembly Out B**
(`MA2-6MACH-AOUT2`). Change something real (or nothing at all) and press **Save**. You
should get a *Saved Location* toast, and the indicator must stay **off** afterwards.

> Dismiss the toast before you judge this. The success toast renders directly over the
> indicator, so "I can't see it" proves nothing while the toast is up.

**c. The indicator still works.** On any Terminal, tick an attribute checkbox.
"● Unsaved changes" and a **Cancel** button must appear. This is the check that the
indicator was fixed rather than switched off. Press Cancel.

**d. The die badge tracks the mount.** Config Tool → **Tools** → pick a mounted die and
press **Release** in the green banner. The badge at the top of the detail header must
flip from green *MOUNTED · \<cell\>* to grey **NOT MOUNTED** immediately, without
navigating away. Re-mount it and the badge must go green again on the spot.

Do (d) on a die that is genuinely idle. Releasing a die that is mounted on a running
press is a real production change, not a test.

---

## 5. Rollback

One import each, back to exactly what prod is running now. Already built and verified
against `d4c29e75`:

1. `Core_ROLLBACK-to-d4c29e75_2026-09-12_1618.zip`
2. `MPP_Config_ROLLBACK-to-d4c29e75_2026-09-12_1618.zip`

Same order, same Designer import, same session reload. Nothing else to undo — no schema
change, no data migration, no configuration switch. Rolling back restores the latch and
the stale badge, so forward-fixing is better unless the import itself misbehaved.

---

## Verification performed before the release

- `ignition/tests/test_location_sort_order.py` — 10 passed. The key case fails against
  the pre-fix module with the bug itself (`"sortOrder": 3` vs `"3"`).
- Dev gateway, Plant Hierarchy: load-clean, save-clean, dirty-on-edit, clean-after-save.
- Dev gateway, Tools: `ASN-DIE-A` NOT MOUNTED → mount → *MOUNTED · MACHINE 02* →
  release → NOT MOUNTED, each updating live.
- Dev gateway, Plant Hierarchy after de-pickling: tree renders from its binding,
  selection loads, no Component Errors.
- Both archives verified entry-by-entry against `git show HEAD:` — the single permitted
  difference is the builder dropping `thumbnail.png` from one `files[]`.

## Outcome

_(fill in after the window)_
