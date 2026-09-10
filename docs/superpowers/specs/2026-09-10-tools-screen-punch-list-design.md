# Tools screen + die-cast punch list — design

**Date:** 2026-09-10
**Branch:** `jacques/working`
**Origin:** a plant-floor testing session the day after prod went live (2026-09-09). Seven
items plus one error screenshot, all against the Tools configuration screen and the Die Cast
LOT Entry screen.

Nothing here needs a new table, a new stored procedure, or a new named query. Six of the
seven items are corrections to surfaces that already exist; the seventh adds one row of
reference data.

---

## 1 · Part number is lost when a die is duplicated

**Cause.** `Tools.Tool_Duplicate` was authored 2026-08-18. `Tools.ToolCavity.ItemId` — the
configured cavity-to-part map for family dies — arrived three weeks later in migration
`0072_toolcavity_itemid.sql` (2026-09-09). The proc's cavity `INSERT … SELECT` copies
`CavityNumber`, `StatusCodeId` and `Description`, and was never taught the new column. A
duplicated family die therefore comes back with every cavity's part number blank, which on a
12-cavity die casting four different part numbers is the whole point of the die.

**Fix.** Add `ItemId` to the cavity insert, guarded exactly the way the proc already guards
`DieRankId`:

- Source Item active → carry it.
- Source Item deprecated → carry `NULL`, count it, and report the count in the success
  `@Message`, alongside the existing `@RankDropped` and `@AttributeSkipped` reporting.

A deprecated part is not an error. The rest of the die's configuration is still worth
cloning, and `Tools.ToolCavity_SaveAll` v1.1 already rejects a deprecated `ItemId` on user
input — so carrying one forward silently would create a row the editor could not re-save.

**Also touched.**

- `@OldValueResolved` / `@NewValueResolved`: the `Cavities` JSON gains the resolved part
  number, per the audit resolved-name-FK convention. Both halves, so the ConfigChangeDetail
  popup still diffs cleanly.
- Proc header → v1.1; `ItemId` added to the COPIED list; Change Log entry.
- `sql/tests/0014_Tools_Tool/020_Tool_duplicate.sql`: two new assertions — ItemId copies for
  an active part; ItemId lands NULL for a deprecated one.
- `Popups/DuplicateDie` → `ResetPanel/ResetBody`: the sentence about cavities carrying over
  "exactly, including Closed and Scrapped ones" is extended to name the part numbers.

---

## 2 · A scrapped cavity can be returned to Active

Two independent locks, both removed. **No gate replaces them** — no elevation prompt, no
confirmation dialog. A cavity's status is now freely editable in either direction.

**SQL.** `R__Tools_ToolCavity_SaveAll.sql` carries a validation block commented
`-- No transition OUT of Scrapped`, rejecting with *"A scrapped cavity cannot change
status."* Deleted. Header Description and Change Log updated to v1.2 — the header currently
states the rule as fact, so leaving it would be a lie in the source of truth.

**UI.** `Components/Parts/Tools/_Tools/CavityRow/view.json` disables the description, status
and part inputs on a saved-Scrapped row through three identical `props.enabled` bindings:

```
!{view.params.row.isScrappedSaved} && !{view.params.row.isDeprecated}
```

The first term comes out of all three. `!isDeprecated` stays — a deprecated tool's rows
remain read-only.

`isScrappedSaved` then has no reader. Its declaration in `CavityRow.params` and its two
producers in `Cavities/view.json` are left in place: three files of churn to delete a
computed boolean is not worth it, and the flag is a plausible future styling hook.

---

## 3 · "Code" is relabelled "Asset Number"

`Tools.Tool.Code` *is* what MPP calls the asset number — there is no second concept anywhere
in the schema, and no `ToolAttributeDefinition` named Asset Number. This is a pure label
change; the column, the unique constraint and every proc parameter keep the name `Code`.

| Surface | Now | After |
|---|---|---|
| `Views/Parts/Tools` → `FieldCode/LabelCode` | `Code` | `Asset Number` |
| `Popups/AddDie` → `CodeField/Label` | `Code` | `Asset Number` |
| `Popups/DuplicateDie` → `CodeField/Label` | `New Code` | `New Asset Number` |
| `Tools.Tool_Create` `@Message` | *A Tool with this Code already exists.* | *…this Asset Number…* |
| `Tools.Tool_Duplicate` `@Message` | *A Tool with this Code already exists.* | *…this Asset Number…* |
| `tools/gen_howto_views.py` → ToolsHowTo prose | Code | Asset Number |

The two `@Message` strings are operator-facing text surfaced by `notifyResult`, so they
follow the label or the toast contradicts the form the operator is looking at.

---

## 4 · The tool search list leads with the name

`Components/Parts/Tools/ToolRow` renders two stacked labels: `LabelCode` bound to
`tool.code` at 12px/600, and `LabelName` bound to `tool.name` at 11px muted with ellipsis.

Swapped: the **name** becomes the bold 12px primary line, the **asset number** the muted
11px secondary. The `meta.name` values swap with their bindings so the file stays honest.

The row feed (`BlueRidge.Parts.Tool._toListRow` → `{id, code, name, rank, deprecated}`) is
unchanged — both fields are already there. The Tool's `Description` column is deliberately
not introduced into the list; the operator-facing text they wanted bold is the Name.

---

## 5 · Die rank disappears from the UI; the data model is untouched

Six components removed, along with their `propConfig` entries:

- `Views/Parts/Tools` → `TitleBar/BtnDieRanks`
- `Views/Parts/Tools` → `DetailsHeader/SummaryRow/SummaryBadgeRank`
- `Views/Parts/Tools` → `DetailsHeader/FieldRowIdentity/FieldDieRank`
- `Components/Parts/Tools/ToolRow` → `BadgeRank`
- `Popups/AddDie` → `DieRankField`
- `Popups/DuplicateDie` → `CopyPanel/RowRank`

Plus: `tools/gen_howto_views.py` loses the Die Rank paragraph from the ToolsHowTo body.
`DieRanksHowTo` keeps generating — it is simply unreachable once its opener is gone.

**Explicitly retained, unreachable:** `Tools.DieRank` and `Tools.DieRankCompatibility` and
every proc over them; `BlueRidge.Parts.DieRank`; the `DieRanks`, `EditRank`, `_DieRanks/*`
and `DieRanksHowTo` views. `Tool_Duplicate`'s deprecated-rank carry-forward logic also
stays. Restoring the feature is a matter of re-adding the components.

**The trap this design avoids.** `Tools.Tool_Update` writes `DieRankId` unconditionally, so
an editor that stopped supplying it would silently NULL the rank on every die that has one —
a quiet data loss with the rank UI gone to notice it. It does not happen here, because the
Tools editor's `load()` seeds the whole `editDraft.meta` dict from the DB row and Save posts
the dict back: `DieRankCode` keeps round-tripping unread. The rule for implementation is
therefore **delete the dropdown, never the `editDraft.meta.DieRankCode` key.**

---

## 6 · Scale Adjustment — a new Trim scrap reason

A seventh Trim-scoped defect code, behaving like the existing six (140–145).

**Code number: `260`.** `146` — the obvious next number — is already `Chatter` under
MachiningAssembly. The only free numbers inside the FRS Appendix E range (100–256) are 155,
193, 196 and 251, each sitting mid-band where Flexware could later fill it. `260` opens a
clean MPP-additions band above the FRS maximum.

**Classification:** `OperationCategoryId = Trim`, `IsExcused = 0`, `IsNonRejectScrap = 0`,
`ChargeToPartyId = TrimShop` — an ordinary scrap reason that counts against reject
percentage. (If a scale reconciliation should be excluded from reject %, the one-field
change is `IsNonRejectScrap = 1`.)

**Delivered twice, following the `0067` / `0048` precedent**, because a reset runs migrations
before seeds and an in-place upgrade runs only migrations:

- `sql/seeds/030_seed_defect_codes.sql` — appended to the `@Defects` table variable, which
  already inserts `WHERE NOT EXISTS` on `Code`. Fixes a fresh reset.
- `sql/migrations/versioned/0075_defectcode_scale_adjustment.sql` — idempotent insert plus
  the `ChargeToPartyId` set, guarded on `SchemaVersion`. Fixes Dev and Prod in place.

ASCII-only, per the seed-data rule.

---

## 7 · The `shotLossDefectOptions` error on Die Cast LOT Entry

**Symptom.** `AttributeError: … object has no attribute 'shotLossDefectOptions'` at line 4 of
the `BreakdownRepeater.props.instances` transform, rendering the breakdown area as a red
binding-error bar.

**Not a code defect in this repo.** The committed `DieCastBody/view.json` declares
`custom.shotLossDefectOptions` with a `[]` default, and has done so in all twelve commits
that touched the file. The local Gateway's copy is byte-identical to the repo (junction
verified) and its `wrapper.log` shows only an idle session. The screenshot is from the live
prod Gateway, which went live 2026-09-09 and is maintained by surgical file drops — it holds
a DieCastBody where the transform arrived but the custom-property declaration did not.

**Two-part fix.**

1. **Deploy.** Redeploy the whole `DieCastBody` view resource to prod and run the manifest
   check, rather than patching a fragment.
2. **Make it structurally immune.** The transform reaches across into `self.view.custom`
   from inside a `props.instances` binding — the pattern already recorded in this repo as a
   silent repeater-killer. Replace the cross-property read with a direct call:

   ```python
   rows = BlueRidge.Workorder.DieCast.mapBreakdownInstances(value)
   opts = BlueRidge.Quality.DefectCode.getForDropdown("DieCast") or []
   for r in rows:
       r["defectOptions"] = opts
   return rows
   ```

   This preserves the comment's entire rationale — one defect-code fetch for the whole list
   rather than one per cavity — while removing the dependency that can go missing. The
   `custom.shotLossDefectOptions` property itself stays: the shot-loss dropdown above the
   repeater binds to it directly and is unaffected.

---

## Execution

**View edits are file-authored**, against the standing CLAUDE.md preference for Designer,
because each one is surgical (a label string, one term of an expression, a component
deletion) and Designer has no project window open — only the Launcher. Match patterns anchor
on escape-free text per the Designer `=` rule. `.\scan.ps1` after the writes;
`git diff --stat` before each commit to catch pickled-live-data bloat.

**Seven commits, one per item**, so the die-rank removal in particular can be reverted alone.

## Known pre-existing issue, not fixed here

`Views/Parts/Tools` has live data pickled into its `custom.editDraft` default — a retired
tool named `hbjnjhbhj` with real timestamps and user ids. That is the Designer-pickles-live-
data trap. Out of scope for this punch list; flagged rather than silently rewritten.
