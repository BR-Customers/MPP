# Prod release handoff -- Assembly OUT low-inventory lock (+ Jacques's Designer saves)

**Written:** 2026-10-06 (late evening), for the agent that packages the next prod release.
**Status:** built and checked on Dev. **Nothing here is on prod.** This is a handoff, not a runbook:
it lists what exists, what it depends on, and what is still unknown. The release itself follows the
five-part shape in CLAUDE.md § Production deployments and `prod-release-context-pack/`.

Spec (rev 2 = as built): `docs/superpowers/specs/2026-10-06-assembly-out-low-inventory-lock-design.md`.
Status entry: `PROJECT_STATUS.md`, "2026-10-06 (evening) -- Assembly OUT low-inventory lock".

---

## 1. What the feature does

On the **non-serialized** Assembly OUT screen, when the selected finished good is **3 trays or fewer**
from running out of a purchased (PassThrough) part, a full-screen banner locks the terminal, names
the part and embeds the add-inventory form. A supervisor AD elevation releases it until stock next
changes at the line. A `System` / `MA-LOWINV` downtime event runs from the banner opening until the
shortage clears.

## 2. Commits (branch `jacques/working`)

| Commit | What |
|---|---|
| `8126fdaa` | Spec (rev 1). |
| `9a856510` | SQL: `Workorder.Assembly_GetTraysRemaining`, the reason-code migration (then numbered 0106), test `0028/101`. |
| `d9ef878e` | Ignition: banner, dock watcher, script functions, NQ, styles, page-config, session prop. |
| `ba13e462` | Proc always emits a result set; migration renumbered **0106 -> 0108**; spec rev 2; status entry. |
| `9ec63834` | Unrelated: read-only line-consumption check script (`sql/scripts/Invoke-LineConsumptionCheck.ps1`, `sql/scratch/2026-10-05_...sql`). Not a prod artefact. |
| `2a446216` | Jacques's Designer saves of 2026-10-06 (section 6). **Separate content, not reviewed for behaviour.** |

Other sessions committed between these on the same branch (`41c5a3d5` lot search, `666d30fc` LOT
notes incl. migration `0107_lot_note`, `4f3870b7` scrap popup). They are not described here; scope
them from their own commits.

## 3. SQL to release

| Item | Kind | Notes |
|---|---|---|
| `sql/migrations/versioned/0108_downtime_reason_low_inventory.sql` | Versioned | Inserts one `Oee.DowntimeReasonCode` row: `MA-LOWINV`, 'Low Inventory', category `MachiningAssembly`, source `System`, not excused, type NULL. Idempotent on `Code`. Created by AppUser 1. |
| `sql/migrations/repeatable/R__Workorder_Assembly_GetTraysRemaining.sql` | Repeatable (new) | Read-only. No dependency on 0108. |

- **Numbering.** Prod's last known migration is `0106_container_label_code128_and_data_identifiers`
  (released 2026-10-06 16:17). `0107_lot_note` belongs to another session's work. `0108` does not
  depend on `0107`; whether they ship together is a scoping decision.
- **Dev bookkeeping.** On `MPP_MES_Dev` the migration was applied under its old name and the
  `SchemaVersion` row was then renamed by hand to `0108_...`. A database built from the repo is
  unaffected.
- **Dev has no `SchemaVersion` row for the container-label `0106`** (as of this session). Not caused
  by this work; worth knowing before using Dev as a rehearsal baseline.
- **Tests.** Full suite on a clean DB: 4355/4355 (with the other sessions' in-progress tests present).
  The new file is `sql/tests/0028_PlantFloor_Assembly/101_Assembly_GetTraysRemaining.sql`, 8 assertions.

### Pre-flight questions against prod data (candidates for gates)

1. `SELECT 1 FROM Oee.DowntimeReasonCode WHERE Code = N'MA-LOWINV'` -- expect none before, one after.
2. `Parts.OperationCategory` has `MachiningAssembly` and `Oee.DowntimeSourceCode` has `System` -- if
   either is missing the migration inserts nothing and its own THROW fails the deploy.
3. **Is each Assembly OUT line's downtime unit OEE-enabled?** `Oee.DowntimeEvent_Start` refuses a
   location with `IsOeeEnabled = 0`. Where `Oee.ufn_ResolveDowntimeScope(<line>)` lands on a
   non-enabled location, the banner still works but **no downtime event is recorded**, silently
   (the refusal is logged as an audit failure, not shown to the operator).
4. **Will the lock fire the moment the page loads?** For every (finished good, line, closure method)
   that runs on a non-serialized Assembly OUT terminal, run
   `EXEC Workorder.Assembly_GetTraysRemaining @CellLocationId, @FinishedGoodItemId, @ClosureMethod`
   and look at `IsShort`. Any row already short locks that terminal as soon as the release lands.
   On Dev, part `1223A-6MA -J000` at `MA2-6MACH` sat at 5 trays for one dowel pin -- close to the line.
   **This is the main operational risk of the release; Jacques should see this list before Execute.**

## 4. Ignition resources to export (scoped, from git, Core first)

**Core**

- `ignition/named-query/workorder/Assembly_GetTraysRemaining` (new)
- `ignition/script-python/BlueRidge/Workorder/Assembly` -- adds `getTraysRemaining`,
  `getLowInventoryLock`, `syncLowInventoryDowntime`
- `ignition/script-python/BlueRidge/Common/Session` -- one new entry in `_ELEVATED_REPLAY_MESSAGES`
  (`LowInventoryRelease`)
- `com.inductiveautomation.perspective/stylesheet` -- `psc-pf-lock-*` classes appended. The stylesheet
  is one resource: exporting it carries every other stylesheet change since prod's copy.

**MPP**

- `views/BlueRidge/Components/Popups/LowInventoryLock` (new)
- `views/BlueRidge/Components/PlantFloor/AddLotBox` -- new `embedded` param
- `views/BlueRidge/Components/PlantFloor/LineInventory` -- the watcher
- `views/BlueRidge/Views/ShopFloor/AssemblyNonSerialized` -- mirrors the selected part to the
  session; sends `inventoryChanged` on an operator tray close. **This view also carries Jacques's
  Designer edits from `2a446216`** (layout changes to the KPI block, a font size). Exporting it ships
  both.
- `page-config` -- `lockEnabled: true` on the `/shop-floor/assembly-nonserialized` dock. One resource
  for all pages: check nothing else in it differs from prod.
- `session-props` -- new `custom.selectedFinishedGoodItemId`; **also** `timeZoneId`
  `America/Indianapolis` -> `America/New_York` from Jacques's save. One resource.

**Dependencies already on prod (per PROJECT_STATUS):** the Line Inventory dock (released
2026-09-18), `AddLotBox` with supplier-lot capture (2026-10-06), pass-through repack in
`Assembly_CompleteTray` v1.5 (2026-10-06). The shared resources above were changed by other work
too, so verify each export against HEAD with `tools/Build-ChangeExport.ps1` rather than trusting
this list.

**The feature is inert without all of it.** With the SQL but not the views, nothing changes. With
the views but not the SQL, the lock reader catches the missing proc and returns "not short" (logged
at warn every 30 s per open Assembly OUT page) -- so SQL first, then Core, then MPP.

## 5. What was verified, and what was not

Checked on the Dev gateway, terminal METTs Assembly Out A, part `1223A-6MA -J000`:

- banner opens by itself when a purchased part drops to 3 trays or fewer;
- a `System` / `MA-LOWINV` event opens at the line's downtime unit;
- adding stock through the embedded form closes the banner and ends the event (remarks name the part);
- the supervisor AD prompt opens over the banner;
- the sidebar's own `+ LOT` popup still opens and cancels.

**Not verified:**

- **The supervisor release end to end.** It needs an AD credential. The replay message
  (`lowInventoryReleaseRequested`) and the `released` flag have never run. Someone with an AD login
  should press it on Dev before this ships.
- A completed add from the sidebar's own popup after the `AddLotBox` change.
- ByWeight / ByVision terminals. Only ByCount was exercised.
- A no-BOM pass-through repack part on the gateway (covered by SQL tests only). In that case the
  banner's add form checks in the **finished-good part itself** as a Received LOT; whether
  `Lots.Lot_Create` accepts that from this form for every such part was not tried.
- Two stations on one line both short at once (see spec 3.4 for the known limit).

## 6. Jacques's Designer saves (`2a446216`) -- separate from the feature

Saved in Designer on the evening of 2026-10-06 and committed as saved, except where Designer had
baked live Dev data into defaults:

| Resource | Note |
|---|---|
| `Views/ShopFloor/DowntimeEntry`, `Popups/DowntimeManager`, `Popups/DowntimeEditor` | Layout / input tweaks. `DowntimeEditor` now defaults `custom.durationOnly = true` and `editDraft.durationMinutes = ""` -- **kept as saved; possibly runtime state, ask Jacques.** `DowntimeManager` lost its `"No downtime events..."` empty text and the `scopeOptions: []` default. |
| `Popups/DieMount` | Placeholder text; the shaped defaults for `custom.context` and `custom.picker` are gone from the file (Designer dropped them). CLAUDE.md § "Pre-declare every binding-referenced custom property" says these guard first paint -- open it on Dev and watch for a Component Error flash before shipping. |
| `Popups/InitialsEntry` | Size / ordering only. |
| `Popups/ScrapEntry` | `resource.json` only (the view itself went in with `4f3870b7`). |
| `PlantFloor/Cutover/CavityToggle`, `Cutover/SessionRow`, `Views/ShopFloor/_CutoverScan/Phone` | Cutover scan screens. **Stripped:** `Phone`'s `setupDraft` had Dev ids (item 52, locations 149 / 14) baked in; they are null again. |
| `session-props` | **Stripped:** the `cutover` block held a live session's state; back to empty defaults. `timeZoneId` change kept. |
| `Views/ShopFloor/AssemblyNonSerialized` | KPI-block layout and a font size, plus the feature's hunks. |

- **`thumbnail.png` in manifests.** Several of these `resource.json` files now list `thumbnail.png`
  under `files`, and thumbnails are gitignored. An export built from git will name a file it does not
  carry. See the `feedback_ignition_manifest_designer_npe` note ("resource.json names a missing file")
  and handle it in the export step.
- None of these saves was reviewed or tested by the agent that committed them.

## 7. Left uncommitted in the working tree (not part of this handoff)

- Eleven `view.json` files with a 3-line `spinner: {enabled: false}` addition and no `resource.json`
  change (DieCastEntry rows, DieCastReconcileSheet + rows, TrimBody, `_CutoverScan/Desktop` and
  `/Tablet`, two MPP_Config attribute rows). They look like an in-progress sweep from another
  session and were left for that session to finish.
- `reference/um.csv` (untracked, origin unknown).

## 8. Rollback sketch

- **Fastest switch-off, no SQL:** remove `"lockEnabled": true` from the non-serialized dock in
  `page-config` and re-import. The watcher then never evaluates; no banner, no downtime events.
- Ignition: re-import the previous exports of the resources in section 4.
- SQL: the proc is read-only and can stay. The reason code can stay (unused) or be deprecated through
  `Oee.DowntimeReasonCode_Deprecate`; do not delete it once any event references it.
- Any open `MA-LOWINV` event left behind is ended in the Downtime Manager.

## 9. Known limits to state in the runbook

- The banner locks the **screen**, not the line: scale- and camera-closed trays keep closing behind
  it. The PLC hold flag is a later feature.
- Serialized Assembly OUT is not covered.
- The 3-tray threshold is a constant in the proc.
- If a terminal's browser dies mid-lock, its downtime event stays open until that terminal next sees
  the shortage clear, or someone ends it by hand.
