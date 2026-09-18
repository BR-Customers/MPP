# Prod release handoff -- Assembly OUT shipping-label reprint + print-reason ASCII fix

**Written:** 2026-09-17, for the agent who builds and runs the prod release.
**Branch:** `jacques/working`. **Feature commits:** `675e000e` (reprint: SQL, tests, Ignition, spec, handoff note), `f6dbd872` (migration `0093` + spec correction), plus this note.
**Prod is at:** release `192c77c1` / migration `0089` -- `daa32e16` records it committed clean. Confirm in `[3]`.
**Spec:** `docs/superpowers/specs/2026-09-17-assembly-out-shipping-label-reprint-design.md`.

This note is the scoping input for `prod-release-context-pack/07_writing_the_runbook.md`. It is **not** the runbook. The five deliverables in `01_the_release_contract.md` are still owed: preview, rehearsal, execute, scoped exports, and a published instruction guide mirrored to `notes/<date>_prod-release-runbook-<slug>.md`.

---

## 0. Decide these before building anything -- both are Jacques's call

### 0.1 HEAD carries two migrations that have no release handoff

`Deploy-ProdRelease.ps1` applies **every** pending migration and **every** changed repeatable in the checkout. It cannot pick. Between prod (`daa32e16`) and HEAD, besides this work, `jacques/working` now holds:

| Migration | Commit | Work | Release handoff? |
|---|---|---|---|
| `0090_location_is_oee_enabled` | `055fc905` + the `feat(oee)` / `merge(oee)` series | OEE-enabled locations + availability roll-up. **Includes a new refusal:** `dc180daf` "downtime writers reject a location that is not OEE-enabled" -- a Test 1 item for whoever ships it. | **None found** in `notes/` |
| `0091_line_inventory_sidebar` | `cf001c27` + the line-inventory series | Line inventory sidebar | **None found** in `notes/` |

A release built from HEAD ships both, unreviewed for release. The four other queued handoffs from today (`cutover-location-first`, `tool-shot-count`, `trim-out-layout`, `diecast-released-good`) were written before `0090`/`0091` landed and are in the same position.

**Options for Jacques:**
- **(a) Release branch.** Branch from `daa32e16` and bring over only the commits being released. **This feature separates cleanly:** every deployable file below was touched by `675e000e` / `f6dbd872` and by **no other commit** since `daa32e16` (verified 2026-09-17). Take them by path rather than cherry-picking whole commits, because `675e000e` also edits `PROJECT_STATUS.md`:
  ```bash
  git checkout 675e000e -- sql/migrations/repeatable/R__Lots_ShippingLabel_ListRecentByCell.sql \
    "ignition/projects/Core/ignition/named-query/lots/ShippingLabel_ListRecentByCell" \
    ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Shipping/code.py \
    ignition/projects/Core/ignition/script-python/BlueRidge/Lots/Container/code.py \
    ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/ShippingLabelReprint \
    ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Components/PlantFloor/ShippingLabelReprintRow \
    ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/AssemblySerialized/view.json \
    ignition/projects/MPP/com.inductiveautomation.perspective/views/BlueRidge/Views/ShopFloor/AssemblyNonSerialized/view.json
  git checkout f6dbd872 -- sql/migrations/versioned/0093_printreasoncode_ascii_name.sql
  ```
  Then `0093` would be pending while `0090`-`0092` are not in the checkout. That is fine for the preview (none of them is *below* the high-water mark yet) -- but see 0.2.
- **(b) Ship from HEAD**, after `0090` and `0091` get their own handoffs and Jacques signs off on them.

### 0.2 Migration numbering: `0093` will block `0092` later

`0092` is **claimed but not written**: the line-inventory plan (`docs/superpowers/plans/2026-09-17-line-inventory-sidebar.md`) reserves `0092_retire_component_projection`. If `0093` reaches prod first, the day `0092` is authored it is pending **below** prod's high-water mark, and `[3]` BLOCKs it ("out of order"). Two ways out, before this ships:
- the line-inventory work takes `0094` (or later) instead of `0092` -- **recommended**: that migration does not exist yet, so it's one line in a plan file. `0093` stays as it is, and it's already recorded in `MPP_MES_Dev`'s `SchemaVersion` under that name; or
- hold `0093` back until `0092` exists. The reprint feature does **not** need `0093` -- it is an independent cosmetic fix -- so it can ship without it.

Don't renumber `0093` itself: Dev already recorded it by name, and renaming it would leave an orphan row.

---

## 1. What it does, in plant terms

**Reprint Shipping Label** is a new button in a new footer bar at the bottom of both Assembly OUT screens (Serialized and Non-Serialized). It opens a popup listing the **last 10 shipping labels for containers on this line** (one row per container), each with the serial as printed, the part, the quantity, the time, whether it printed, and a "reprint" marker if the newest label was already a reprint.

The operator picks the label and a reason (`printer jam`, `network error`, `damaged label`, `print failed`, `smudged`). **A supervisor types their AD account and password** in the popup and presses Reprint. The label is re-rendered and **sent to the printer immediately**. **The operator stays signed in** -- the approval covers this one reprint only, and the reprint is recorded against the supervisor. Any active AD-mapped user can approve (no role gate yet; Jacques will add AD roles in a week or two).

The print-failure alert now tells operators to "Reprint it from Assembly OUT" instead of "the Shipping Dock".

Separately, `0093` renames the print reason `ReprintDamaged` from `Reprint <em-dash> Damaged` -- which sqlcmd stored as the mojibake `Reprint â€" Damaged` -- to `Reprint - Damaged`.

---

## 2. Scope

### Versioned migrations
| # | Effect |
|---|---|
| `0093_printreasoncode_ascii_name` | `UPDATE Lots.PrintReasonCode SET Name = N'Reprint - Damaged' WHERE Code = N'ReprintDamaged'`, only if the Name differs (binary compare). One row of a 5-row code table. Idempotent. Id unchanged, so `Lots.LotLabel.PrintReasonCodeId` FKs are untouched. No `BEGIN TRAN` / `ALTER DATABASE`; safe inside the release transaction. |

### Repeatables
| Object | State on prod (expected) | Effect |
|---|---|---|
| `Lots.ShippingLabel_ListRecentByCell` (`R__Lots_ShippingLabel_ListRecentByCell.sql`) | **NEW** | The popup's list. Read proc, one result set, no OUTPUT params. |

`[4]` should show exactly this one for this feature. **No existing proc changed** -- the reprint reuses `Lots.ShippingLabel_Reprint` and `Location.AppUser_AuthenticateAd` as they are in prod (both unchanged since `daa32e16`). No extended-property change.

### Ignition resources (scope-checked 2026-09-17: `-Since 8a3d1699 -Until 675e000e`)
| Project | Resource | State |
|---|---|---|
| Core | `named-query/lots/ShippingLabel_ListRecentByCell` | NEW |
| Core | `script-python/BlueRidge/Lots/Shipping` | MOD (+`listRecentByCell`, `reprintAndDispatch`, `reprintFromPopup`, `REPRINT_ACTION_CODE`; existing functions unchanged) |
| Core | `script-python/BlueRidge/Lots/Container` | MOD (one toast string) |
| MPP | `views/BlueRidge/Components/PlantFloor/ShippingLabelReprint` | NEW (popup) |
| MPP | `views/BlueRidge/Components/PlantFloor/ShippingLabelReprintRow` | NEW (list row) |
| MPP | `views/BlueRidge/Views/ShopFloor/AssemblySerialized` | MOD (+ root `Footer`) |
| MPP | `views/BlueRidge/Views/ShopFloor/AssemblyNonSerialized` | MOD (+ root `Footer`) |

Scope-check result: `Core 3 resource(s), 7 entries`, `MPP 4 resource(s), 9 entries`, MPP_Config skipped, 1 manifest rewritten to drop `thumbnail.png` (expected). **No deletions.** Rebuild at the real release commit, bundled with whatever else ships. Import **Core first**, then MPP.

The two Assembly views were edited by `tools/add_assembly_out_reprint_footer.py`: a text splice checked by re-parsing (the original document plus exactly one `Footer` node). So their text diff is small (+47 lines each) and contains only the footer.

### Ships nothing
`sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/082_ShippingLabel_ListRecentByCell.sql`, `tools/add_assembly_out_reprint_footer.py`, the spec, `PROJECT_STATUS.md`, `notes/` (including `2026-09-17_handoff-aim-failure-log-and-shipping-reprint.md`, whose section 1 is an open TODO and section 3 is benched -- **neither ships**).

---

## 3. Risk -- the four tests

**Test 1: does anything now refuse what it used to allow?** No. No proc gained a rejection. Reprinting was already possible at the Shipping Dock (unelevated, unchanged); this adds a second, elevated path. The Shipping Dock screen is **untouched** and still the only UI that ships a container or voids a label.

**Test 2: is any of it shared code?** Yes, three pieces:
- `BlueRidge.Lots.Shipping` ships whole. Its existing callers -- Shipping Dock (`ship`, `voidLabel`, `reprintLabel`) and `PrintFailureBanner` (`ackBanner`) -- are unchanged functions.
- `BlueRidge.Lots.Container` ships whole. It is the container-complete path for **every** Assembly OUT completion, including the PLC path. Only the "Label not printed" alert string changed.
- Both Assembly OUT views ship whole. Only the footer was added; completion, CRT validation, scrap and inventory are as before.

Post-deploy must prove a normal container completion still prints (section 5, step 5).

**Test 3: is the schema change metadata-only?** There's no schema change. `0093` is a one-row data update on a code table.

**Test 4: does old Ignition work against new SQL?** **Yes.** The new proc has no old callers, and nothing matches on the renamed print-reason Name (checked across `sql/` and `ignition/`). **New Ignition against old SQL:** the popup's list errors (missing proc). **Deploy SQL first**; after that, the two steps can happen at different times.

**Rollback:** re-import the previous `Lots/Shipping`, `Lots/Container`, `AssemblySerialized` and `AssemblyNonSerialized` from `daa32e16`, and delete the two new MPP views and the new NQ in the Designer (optional -- nothing opens them once the footer is gone). The new proc can be dropped or left in place. **Don't reverse `0093`**: that would put the mojibake back. Reprint rows written in the meantime are real history -- leave them.

---

## 4. Rehearsal expectations

Rehearse at prod's exact state (`05_local_rehearsal.md`) on a **uniquely named** throwaway DB, not `MPP_MES_Test` -- other sessions reset it.

For this feature alone (option 0.1 (a)):
- `[3]`: 1 pending, `0093`.
- `[4]`: 1 NEW -- `Lots.ShippingLabel_ListRecentByCell`.
- `[5]`: no gate needed. Add this **informational** pre-flight to the runbook and show Jacques the result:
  ```sql
  -- (a) prod's current print-reason name. Expect the mojibake form (bytes E2 00 AC 20 1D 20 in the dash
  --     position) -- that's what 0093 fixes. Already 'Reprint - Damaged' = 0093 is a no-op; still fine.
  SELECT Id, Code, Name, CONVERT(VARBINARY(60), Name) AS Bytes
  FROM Lots.PrintReasonCode WHERE Code = N'ReprintDamaged';
  -- (b) what the popup will offer at each Assembly OUT line: labels per line in the last 7 days.
  SELECT l.Code, COUNT(*) AS Labels7d
  FROM Lots.ShippingLabel sl
  JOIN Lots.Container c   ON c.Id = sl.ContainerId
  JOIN Location.Location l ON l.Id = c.CurrentLocationId
  WHERE sl.IsVoid = 0 AND sl.CreatedAt >= DATEADD(DAY, -7, SYSUTCDATETIME())
  GROUP BY l.Code ORDER BY l.Code;
  ```

**Local evidence (2026-09-17):**
- `082_ShippingLabel_ListRecentByCell` 22/22, and the whole `0029_PlantFloor_Hold_Sort_Shipping_Aim` folder 111/111, on a throwaway DB (since dropped).
- `0093`: a full throwaway build from `0001` ran it in order; a second run no-oped; the Name read `Reprint - Damaged` (bytes checked). Applied to `MPP_MES_Dev`, which held the mojibake form and now reads correctly.
- The proc on Dev returns MA2-59B's five containers.
- Gateway scan clean (no errors for any of the resources); the footer renders on AssemblyNonSerialized.
- **Not exercised by the building agent:** the popup end-to-end (PIN sign-in + AD approval). Jacques has elevation working in Dev; the live reprint is a post-deploy step (section 5) or a Dev check for Jacques before release.
- Every function the new code calls exists with the same signature at `daa32e16`: `ShippingDispatcher.dispatch`, `AppUser.elevate`, `Notify.toast`, `Db.execList`, `Util.extractQualifiedValues`, `Shipping.reprintLabel`.

---

## 5. Post-deploy verification (prod)

1. **SQL:** `SELECT OBJECT_ID(N'Lots.ShippingLabel_ListRecentByCell')` is non-NULL; `SELECT Name FROM Lots.PrintReasonCode WHERE Code = N'ReprintDamaged'` returns `Reprint - Damaged`.
2. **Screens:** open an Assembly OUT terminal of each kind (Serialized and Non-Serialized) and reload with F5. The page loads, and the footer shows **Reprint Shipping Label**.
3. **Popup:** it lists this line's recent labels, newest first. The serials match the printed labels. Cancel closes it.
4. **Live reprint (only with Jacques's go -- it prints a real label):**
   - Pick a label and a reason; a supervisor enters AD credentials and presses Reprint.
   - Expect the toast "Label reprinted", and a label from the terminal's printer with the **same serial** as the original.
   - Check the newest row: `SELECT TOP 1 Id, ContainerId, Initial, PrintReasonCode, PrintedByUserId, TerminalLocationId, PrintedAt, PrintFailedAt FROM Lots.ShippingLabel ORDER BY Id DESC`. Expect `Initial = 0`, the reason, the **supervisor's** AppUser id, and `PrintedAt` set.
   - Check the audit: the newest `ElevationGranted` row's Description ends `Granted for ShippingLabelReprint`.
   - The operator bar still shows the **operator**, not the supervisor.
   - Discard the physical label that was replaced -- two live labels with one serial is an operational problem, not a system one.
5. **Shared-code check (Test 2):** let one container complete normally on any Assembly OUT line (or wait for the next one). Its label prints as before. The Shipping Dock page still loads.

---

## 6. Caveats to tell Jacques

- **Multi-printer stations: the reprint goes to the terminal's default printer, not necessarily the card the original came from.** `completeBoxToPrinter` sends the original to the printer card's own printer, but `Lots.ShippingLabel` records no printer, so the reprint dispatch resolves the session or terminal printer. On a single-printer station, that's the same printer. On a printer-card station, it may be a different spot on the line. Fixing that would mean storing the printer on the label row -- a follow-up, if it matters.
- **Anyone with an active AD mapping can approve**, same as every other protected action today. The action code `ShippingLabelReprint` is recorded on every approval, so a role rule later is SQL-only.
- The Shipping Dock's own Reprint button still doesn't dispatch; its reprint prints only when the stranded-label sweep next runs (~5 min). The screen was deliberately left alone (section 3 of the handoff is benched).
