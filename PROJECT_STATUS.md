# MPP MES — Project Status

**Last updated:** 2026-05-28 (Phase 8 Eligibility editor end-to-end green — all 14 spec §9 smoke steps pass. Phase 3 + Phase 6 BOMs also fully green from earlier in the same session. SQL tests **1048/1048**.)

---

## 🔖 Next Session Pickup — finish Audit Log "Changes" column (Designer-side) → then Phase 7 QualitySpec cross-nav

**State of play.** Item Master is fully wired across all 5 tabs now that Phase 8 Eligibility landed today. Phase 7 (QualitySpecs cross-navigation — the "Go to spec" button per row) is the only remaining Item-Master roadmap item, and it's a small enhancement. The **active** in-flight work is the AuditLog "Changes" column workstream from 2026-05-27 evening that has uncommitted script changes sitting in the working tree plus a documented next-step Designer column add.

**First three steps on resume:**

1. **Sync up + verify clean tree.**
   ```
   git fetch origin && git pull --ff-only origin main
   git status   # should show 5 modified files (the audit-log "Changes" column WIP) + untracked HANDOFF_AUDIT_LOG_2026-05-28.md + plant-layout PDF + tools/plant-layout-mapper/
   ```

2. **Finish the AuditLog "Changes" column** per `HANDOFF_AUDIT_LOG_2026-05-28.md` at the repo root. Three remaining steps (Designer-only, ~10 min):
   - Add the new `ChangesSummary` column to the AuditTable's `props.columns` (between Event and Severity)
   - Drop the meaningless `EntityId` column from the table
   - Re-test row click → ConfigChangeDetail popup still opens with side-by-side Old/New JSON
   - Commit + push the 4 already-modified files plus the Designer-side view edit
   - Delete `HANDOFF_AUDIT_LOG_2026-05-28.md` after the commit lands

3. **Phase 7 QualitySpecs cross-nav** (after audit log column closes). The QualitySpecs tab view currently has a literal placeholder line "Phase 7 will add a 'Go to spec' navigation button per row." Wire a row-level "Go to spec" button (or click-on-row) that navigates to the existing QualitySpec editor surface (or opens it as a popup if no top-level page yet). Small spec + plan should run ~1 session.

**Other open Ignition items not blocking the above:**
- Audit Log UI revisit (Jacques flagged 2026-05-27). The Changes-column work addresses the most acute pain; broader UX rework still wanted at some point but no concrete spec yet. Lower priority than #1/#2 above.
- DieCastMachine Cell read-only mounted-Tool status panel (Plant Hierarchy editor) — deferred until Tools master Config Tool surface exists. See "Deferred follow-ups" section below.
- Orphan Draft BOM rows in dev DB from pre-fix `+ New Version` clicks may still need a manual cleanup pass before further BOM testing (see `feedback_ignition_nq_type_for_status_row_procs` memory).
- OI-35 Architecture Decision Gate still gating Arc 2 Phase 1 SQL build (independent of any Item Master / audit work).

---

---

## 🆕 Item Master design convention update (2026-05-20)

The Item Master design has been **reworked from bundled-editDraft + bidi-Object-param to per-section ownership** before any Phase 3+ implementation lands. Each of 6 sections (Identity + 5 tabs) now owns its own selected/editDraft locally, has its own Save/Discard, and broadcasts dirty state via `sectionDirtyChanged` page-scoped messages. Parent aggregates flags + gates tab/item switches via the existing ConfirmUnsaved popup.

**Why:** R1 (bidi Object-param round-trip) was never proven and Phase 2's wiring drifted from the original design. Per-section ownership uses primitives the project has shipped reliably (page-scoped messages) and aligns with how the customer's roles actually work (different engineers own different concerns).

**Canonical reference:** `project_mpp_item_master_pattern` memory (2026-05-20 rev).

**Docs realigned:**
- `docs/superpowers/specs/2026-05-20-item-master-phase4-design.md` + plan — **rewritten** for per-section.
- `docs/superpowers/specs/2026-05-20-item-master-boms-design.md` + plan — **medium retrofit** flagged via §0 convention-reconciliation preamble (most of spec stands).
- `docs/superpowers/specs/2026-05-20-item-master-routes-design.md` + plan — **light retrofit** (Routes already designed for per-section; convention ratifies it).

**Phase 1 + 2 code:** parent's old bundled `editDraft` and `selected` blocks are inert (never properly populated for ContainerConfig); they get demolished as part of Phase 4 Task 5.

---

## ✅ Recently closed

### Item Master Phase 8 Eligibility editor — end-to-end smoke green (2026-05-28)

Closed out Phase 8 — the last big tab in the Item Master refactor. Full vertical stack landed in 16 commits (`31f66cb`..`0a83224`), all 14 spec §9 smoke steps pass:

- **SQL** — `Parts.ItemLocation_SaveAllForItem` (bundled reconcile: add / update / deprecate / reactivate-deprecated all atomically), `Location.Location_ListForEligibilityPicker` (tier-grouped picker read with `NCHAR(8212)` em-dash to avoid `sqlcmd` codepage trap), `Parts.ItemLocation_ListByItem` bumped to v3.0 (added `TierOrdinal`, re-sorted `(tierOrdinal, code)`). 11 SaveAll tests + 3 picker tests pass. Existing 64 ItemLocation CRUD tests still pass after widening `#IlByItem1`/`#IlByItem2` scratch tables for the new column. **1048/1048 SQL tests passing.**
- **Ignition** — 3 NQ wrappers (SaveAll + picker + **previously-missing** `ItemLocation_ListByItem` read NQ — `6527d24` was the root cause of all the post-save dirty-stuck symptoms, see below), `BlueRidge.Parts.Eligibility` entity script, new `EligibilityRow` sub-view (page-scoped message propagation per `feedback_ignition_embed_params_input_only`), and full rewrite of `Eligibility/view.json` per per-section ownership pattern matching BOMs.
- **Pattern adherence** — `isDirty` binding uses the canonical BOMs-equivalent `runScript("BlueRidge.Common.Util.convertWrapperObjectToJson", 0, {view.custom.state.editDraft.rows}) != ...{state.selected.rows}` expression. No divergence from the per-section ownership convention.

**Process lesson (captured as memory `feedback_check_nq_files_first`)**: I spent four rounds patching the `isDirty` binding (property+transform variants, type comparison tweaks, deep-path watching theories) chasing a "save success toast but dirty stays true" symptom. The actual root cause was a missing NQ file (`parts/ItemLocation_ListByItem`) which the plan had assumed already existed. `load()` was failing silently with `java.lang.Exception: Named query not found` every call, so `state.selected` never reset post-save. **Lesson:** when a new editor following an established pattern misbehaves in surprising ways, FIRST check the gateway log for `Named query not found` traces — don't immediately blame the binding or comparison logic. 30-second diagnostic vs hours of binding archaeology.

**Plan deviations (all documented in commits):**
- Tier filter in tests uses `lt.Code = N'Area'` / `N'Cell'`, not `ltd.Name = N'Area'` — dev seeds carry definition names like `'Production Area'` / `'CNC Machine'`.
- Test Item insert uses `CreatedByUserId` (Parts.Item has no `IsActive` column).
- Picker proc uses `NCHAR(8212)` (em-dash codepoint) instead of literal em-dash in source — sqlcmd was loading the UTF-8 source file with the Win-1252 codepage and storing the wrong 3-byte sequence in the proc body. Same fix applied to the test's LIKE pattern via `@Sep NVARCHAR(5) = NCHAR(8212)`.
- Row qty fields (`Min`/`Max`/`Default`) use `meta.visible` not `position.display` so the 240px slot stays reserved when `IsConsumptionPoint` is off (uniform row geometry per user feedback).
- Save (`props.enabled`) + Discard (`meta.visible`) wrap `view.custom.isDirty` in `if(isNull(...), false, ...)` defensive guard so a transient Quality-Bad doesn't cascade to Component Error.

Audit-log "Changes" column work from 2026-05-27 evening is still uncommitted in working tree alongside the Phase 8 commits — see "Next Session Pickup" above. The two workstreams touched disjoint files; no interference.

### Item Master Phase 3 dirty-drift blocker resolved + Phase 6 BOMs smoke green (2026-05-27 → 2026-05-28)

Closed out the per-section dirty-drift blocker that had been gating Phase 3 closeout for a week. Two compounding bugs in `BlueRidge.Common.Util.convertWrapperObjectToJson` + `load()` racing:

1. **Shallow unwrap.** `convertWrapperObjectToJson` was `return dict(obj)` — handed back a Python dict containing raw `BasicQualifiedValue` leaves. The dirty-binding expression then either compared two dicts whose Java-wrapper identities drifted between reads (false-positive dirty), or — once `system.util.jsonEncode(dict(obj))` was tried — choked because jsonEncode can't serialize raw QV objects (binding evaluated to null, "Error_Configuration"). Fix: `return system.util.jsonEncode(extractQualifiedValues(obj))`. The existing `extractQualifiedValues` already handles `JavaMap` + `QualifiedValue` recursively — which is exactly the shape that arrives at runScript (`HashMap` of `BasicQualifiedValue`). Confirmed via diagnostic logging that captured both sides' types + reprs.

2. **Load-race architecture.** Even with deep unwrap, the dirty-binding still fired spuriously on cross-item nav because `load()` was writing `self.view.custom.selected = X; self.view.custom.editDraft = X` as two SEQUENTIAL property assignments. Between the writes the binding evaluated with `selected = new item, editDraft = old item` → dirty=true → `sectionDirtyChanged{isDirty:true}` propagated → parent latched `sectionDirty.<section> = true`. The subsequent dirty=false transition either coalesced or arrived after the parent already gated navigation. **Fix:** wrap both in a single `view.custom.state` parent property and write atomically: `self.view.custom.state = {"selected": dict(loaded), "editDraft": dict(loaded)}`. Applied to Identity, ContainerConfig, BOMs (per-section ownership), and Routes (the only one that uses explicit `broadcastDirty()` instead of binding-driven dirty).

**Phase 3 smoke (steps 1–16, including the previously-blocked cross-item nav steps 10–16) all PASS.**

**Phase 6 BOMs end-to-end smoke (B1–B13) also all PASS** in the same multi-day session. Numerous fixes layered on top of the per-section state refactor:

- **Six BOM mutation NQs** (`Bom_Create`, `Bom_CreateNewVersion`, `Bom_Publish`, `Bom_SaveDraft`, `Bom_Deprecate`, `Bom_DiscardDraft`) were mistyped as `UpdateQuery`. JDBC's executeUpdate path throws on the status-row SELECT every project mutation proc returns — "A result set was generated for update." The procs succeeded server-side, but client got an exception, no toast fired, no UI updated. Flipped all six to `type: "Query"`. New memory: `feedback_ignition_nq_type_for_status_row_procs`.
- **`forEach` in Ignition expressions doesn't exist.** Four BOMs/BomLineRow bindings (`VersionDropdown.options`, `LinesRepeater.instances`, `ItemPicker.options`, `UomEdit.options`) had been authored as `forEach({list}, {label: ..., value: ...})` expressions and silently failed with "Nested paths not allowed" / "TagPathFormatException". Converted all four to property binding + script transform, mirroring Routes' working pattern. New memory: `feedback_ignition_no_foreach_in_expressions`.
- **`BomLineRow` was nested under `Boms/`.** Same "Ignition can't load views nested under other views" trap that hit `DraftStepRow` yesterday. Moved to `ItemMaster/BomLineRow/` as a sibling of the other section embeds.
- **Embed sub-view params are input-only.** `BomLineRow.QtyEdit` + `UomEdit` were bidi-bound to `view.params.line.X` — writes silently dropped, never reaching the parent. Save Draft stayed disabled after qty edits; UOM "reverted to EA" on every pick. Added page-scoped `bomLineQtyChanged` + `bomLineUomChanged` messages with `_applyQtyChange` + `_applyUomChange` customMethods on the parent. New memory: `feedback_ignition_embed_params_input_only`.
- **`handleNewVersion` didn't load state inline.** Was relying on `activeVersionId.onChange` → `loadActiveVersion()` chain to populate the new draft's content. The chain didn't reliably fire. Now `handleNewVersion` explicitly fetches the bundle and writes `view.custom.state = {selected, editDraft}` synchronously, same pattern Routes' `BtnNewVersion` uses.
- **Single-Published invariant + pre-publish confirmation UX.** Catching that v1 + v2 could both have `DeprecatedAt IS NULL` for the same `ParentItemId`: `Bom_Publish` now auto-deprecates any prior Published version in the same transaction, with an `OUTPUT inserted.VersionNumber INTO @DeprecatedVersions` so the success message reads "Published v2. Deprecated v1." Publish button now routes through a new `requestPublish` customMethod that inspects `view.custom.versions` for a prior Published row — if found, opens the existing `ConfirmDestructive` popup ("Publish v2? This will deprecate v1 currently active in production."); first publish goes direct. Commit `f6df905`.
- **Layout polish.** ColMove/ColRm header placeholders converted from empty `ia.display.label` to empty `ia.container.flex` so they reserve slot width when invisible (labels collapse on `meta.visible: false`). Draft/Published alternate columns switched from `meta.visible` to `position.display` (alternates that share a column should collapse, not both reserve space). All BomLineRow controls get uniform `height: 30px` so bottom edges align. ColArrows widened 52px → 72px so arrows fit side-by-side.
- **Component filter.** `Parts.ItemLocation_ListAvailableForBom` excludes `ItemType.Name = N'Finished Good'` per business rule (BOM components are never Finished Goods).

Commit chain on main (this session): `bd00c5e` (per-section atomic state writes + extractQualifiedValues chain) → `5b13cc1` (yesterday's DraftStepRow polish) → `44ec8b7` (script-console demo) → `1049ea3` (BOMs end-to-end smoke fixes bundle) → `c27c36d` (Routes elementStyle parity) → `f6df905` (BOMs Publish invariant + UX).

**Memory updates (durable lessons captured):**
- `project_mpp_item_master_pattern` — added "Atomic state writes" addendum documenting the `view.custom.state = {selected, editDraft}` single-write rule + the `convertWrapperObjectToJson` co-fix.
- `feedback_ignition_nq_type_for_status_row_procs` — NEW. Mutation procs returning status-row SELECT must have NQ `type: "Query"`, not `UpdateQuery`.
- `feedback_ignition_no_foreach_in_expressions` — NEW. Ignition expression language has no iteration primitive; use property + script transform.
- `feedback_ignition_embed_params_input_only` — NEW. Sub-view params are input-only; bidi writes to nested paths under `view.params.X` get silently dropped; use page-scoped messages.
- `feedback_no_business_logic_in_python` — NEW. Jacques rule: business rules (compatibility matrices, validation thresholds, etc.) live in SQL, never in Python entity scripts.
- `CLAUDE.md` § Compound editors with per-section ownership — strengthened with the atomic-state-write paragraph + embed-to-parent propagation paragraph.

### Item Master Phase 8 Eligibility — spec + implementation plan committed (2026-05-27)

Brainstormed + designed + planned. Code not yet landed.

- Spec: `docs/superpowers/specs/2026-05-27-item-master-eligibility-design.md` (commits `03c50e0` + `8fc736d` self-review).
- Plan: `docs/superpowers/plans/2026-05-27-item-master-eligibility.md` (commit `84a2a0b`). 10 tasks, SQL-first, every task has exact file paths + complete code blocks + expected sqlcmd output.
- Pattern: per-section ownership with atomic state writes (same pattern locked in Phase 3 fix).
- Editor model: tiered list (one row per `Parts.ItemLocation` row), single typeahead Location dropdown grouped by tier, bundled SaveAll proc with reactivate-deprecated semantics, no client-side business-rule enforcement.
- Schema already supports the design — `Parts.ItemLocation` already has the consumption-metadata columns from migration 0010. No new migration needed.

### Item Master Phase 6 — BOMs versioning workflow landed via rebase + ff-merge (2026-05-26)

Second versioned per-section embed to ship (after Phase 5 Routes). The BOMs tab on `/items` now supports the full Draft → Published → Deprecated lifecycle: create new version (clone last Published into Draft), add/edit/remove component-item lines (Item dropdown + UoM auto-populate + Qty + IsScrapTracked), Save Draft (bundled JSON-line reconciliation via `Bom_SaveDraft` — physical DELETE/UPDATE/INSERT since `BomLine` has no `DeprecatedAt`), Publish (atomic save-then-publish with optional `EffectiveFrom` + min-1-line guard moved BEFORE `BEGIN TRANSACTION` to avoid Msg 3915 in INSERT-EXEC tests), Discard Draft (hard delete + cascade), Deprecate Published (idempotent). Filtered UNIQUE index `UX_Bom_ActiveDraft` enforces one Draft per ParentItemId. New migration: `0016_parts_bom_unique_draft.sql`.

Built in worktree `.claude/worktrees/Agent-B-item-master-boms`, then **rebased onto main** after main absorbed Phase 5 Routes + Phase 3 Item CRUD which collided on three surfaces:

- **Migration slot collision** — `0015_parts_bom_unique_draft.sql` renamed to `0016_*` (0015 taken by main's `audit_add_event_type_deleted`).
- **`Uom_List` NQ add/add** — kept main's `EXEC Parts.Uom_List @IncludeDeprecated = :includeDeprecated` signature; deleted BOMs' duplicate; updated `BlueRidge.Parts.Bom.listUoms()` to pass `{"includeDeprecated": False}`.
- **Generic 2-button confirm popup duplication** — swapped BOMs' new `ConfirmAction` for main's `ConfirmDestructive`; updated 2 callers in `Boms/view.json` (`openDeprecateConfirm`, `openDiscardDraftConfirm`); deleted `ConfirmAction` view dir. Orphan `f30be77 feat(popups): reusable ConfirmAction popup` commit still in history → `682905b` deletes its files (net effect correct; squash if cleaner log desired).

**Pattern backports from main's Routes versioning work (post-fork commits):**

- **`85986c3` isDirty deep-compare** — backported as `43c20bd`. BOMs' `view.custom.isDirty` was comparing `editDraft.lines != selected.lines` (list reference equality); now routes both sides through `Common.Util.convertWrapperObjectToJson` for primitive-level equality. **This is the candidate fix-pattern for the open dirty-drift blocker on Identity/ContainerConfig.**
- **`e7f2f3e` / `404b51b` ImmutableMap unwrap in versions.onChange** — NOT APPLICABLE; BOMs has no versions.onChange handler (uses runScript-bound dropdown + Python entity returning plain `list[dict]`); uses `flex-repeater` not `ia.display.table`.
- **`e29c670` selectedItem default shape restore** — NOT APPLICABLE; BOMs `view.custom.selected` + `editDraft` already declare full nested empty shape.
- **`a391f07` Routes onChange bracket-access on ImmutableMap (not broken json.loads roundtrip)** — landed AFTER the rebase agent did its main pass; BOMs absorbed via a second silent rebase before ff-merge. BOMs has no analogous onChange callsite.

**Pre-existing test bug recovered:** `010_Bom_crud.sql` had a `#BomListScratch` temp-table that wasn't widened when `R__Parts_Bom_ListByParentItem.sql` went to v3 (added `LineCount` + `Status` columns). INSERT-EXEC was throwing Msg 213 silently aborting the whole file via `sqlcmd -b`, skipping ~13 trailing assertions including `[BomCreateHappy]`. Fixed in `705986e` as part of the rebase pass.

**Final 11-commit set on main:** `971c2f4` SQL backend → `c61db35` 10 NQs → `ae481b5` entity script → `f30be77` ConfirmAction (orphaned later) → `d357a95` BomLineRow → `38639a1` BOMs embed wire → `217c540` migration renumber → `c2962c1` Uom_List signature → `682905b` ConfirmAction→ConfirmDestructive swap → `43c20bd` isDirty deep-compare → `705986e` `#BomListScratch` widen. Merged ff-only.

**SQL tests:** 1034/1034 passing (was 972 on BOMs branch pre-rebase; +62 from main's Phase 5 Routes additions + recovered `010_Bom_crud.sql` assertions).

**Pickup tomorrow:**

1. **Smoke-test BOMs end-to-end in Designer** — open `/items`, pick 5G0, click BOMs tab. Verify: versions list with line-count + status badges; `+ New Version` → clones last Published into Draft + EffectiveFrom prefill + success toast; edit qty → `●` dirty + tab disable; `+ Add Component` Item dropdown auto-populates UoM; reorder arrows; row `×` remove; `Save Draft` → reload persists; `Publish` (zero-line + missing EffectiveFrom blocked; valid → status flip); `Deprecate` → `ConfirmDestructive` → status flip; `Discard Draft` → `ConfirmDestructive` → version vanishes; tab-switch with dirty Draft triggers ConfirmDestructive gate (parent's Phase 4 infrastructure carries this); `Audit.ConfigLog` rows for every mutation.
2. **Reset dev DB** — `.\Reset-DevDatabase.ps1` to land migration 0016 cleanly (if `0015_parts_bom_unique_draft` row exists in `SchemaVersion` from pre-rebase, the reset rebuilds from scratch).
3. **`.\scan.ps1`** before Designer testing to pick up new NQs + 2 new views + restructured `Boms/view.json`.
4. **Try `43c20bd` deep-compare pattern on Identity + ContainerConfig isDirty** — first diagnostic step for the open editDraft-drift blocker (both currently do reference-equality on dict-typed editDraft vs selected, the exact bug the BOMs backport addressed).
5. **Working tree on main has uncommitted edits** to `ItemMaster/{resource.json, view.json}` from prior Identity bug investigation — survived the merge intact; decide whether to commit / discard / continue iterating before re-opening Designer.
6. Optional cleanup: interactive-rebase squash `f30be77` (orphan ConfirmAction add) into `682905b` (its delete) for tidier log.
7. Optional: remove worktree `git worktree remove .claude/worktrees/Agent-B-item-master-boms` (Agent-A + Agent-C worktrees still in use for parallel work).

### Item Master Phase 4 — ContainerConfig save + parent gate infrastructure (2026-05-26)

First section to ship under the per-section ownership convention. ContainerConfig embed now owns its own `view.custom.selected` + `view.custom.editDraft` locally, receives a plain BIGINT `params.value: itemId` (input-only, no bidi Object-param), fetches its own data via `BlueRidge.Parts.ContainerConfig.getByItem` on `params.value` onChange, has its own Save / Discard buttons in a HeaderRow, broadcasts `sectionDirtyChanged` page-scoped on every dirty transition, and listens for `sectionSaveRequested` / `sectionDiscardRequested` from the parent. New `TargetWeight` field with `position.display` gated on `ClosureMethod == 'ByWeight'`. `handleSave` coerces string text-field input → numeric (text-field bidi writes strings into editDraft, so the plan's `trays <= 0` would silently misvalidate in Jython 2).

Parent ItemMaster view demolished the old bundled `editDraft` / `selected` / `mode` props (never properly populated anyway) and added the per-section gate infrastructure:

- `view.custom.selectedItemId` (BIGINT, set on item-row click); all 5 tab embeds receive `params.value: selectedItemId` input-only.
- `view.custom.activeTabIndex` (int, bidi-bound to TabContainer.currentTabIndex). View-level onChange interceptor stages `pendingSwitch` and opens ConfirmUnsaved when leaving a dirty section, then auto-reverts.
- `view.custom.sectionDirty` flag map populated by listening to `sectionDirtyChanged` from sections.
- `view.custom.pendingSwitch` staging area for the intercepted nav event.
- `root.scripts.customMethods`: `openConfirmUnsaved(sectionKey)`, `completeSwitch()`, `cancelSwitch()`.
- `root.scripts.messageHandlers`: rewritten `itemRowClicked` (gated by any-section-dirty), new `sectionDirtyChanged`, new `confirmUnsavedResult` (save → page-msg `sectionSaveRequested`; discard → page-msg `sectionDiscardRequested`; cancel → drop pendingSwitch).
- TabContainer `props.tabs` bound via `runScript(BlueRidge.Parts.Item.itemMasterTabLabels, 0, {view.custom.sectionDirty})` — returns a plain Python list[str] with `●` prefix on dirty sections. Initial `[if(...), ...]` expression-array-literal binding caused a red error at the top of the tab strip; runScript binding is cleaner.

Identity panel (DetailsHeader) restored as **read-only display** binding to a new `view.custom.selectedItem` prop populated via `runScript(BlueRidge.Parts.Item.getOneOrEmpty, 0, {view.custom.selectedItemId})`. `getOneOrEmpty` returns the full Item key-shape with null values when itemId is null/missing, so cold-open bindings render clean rather than Quality-Bad. All Identity inputs are `enabled: false`; Save / Deprecate buttons toast Phase-3 placeholders. Phase 3 will carve Identity into its own embed and wire bidi editing.

Plan deviations (all called out in commit messages):

- **sqlType corrections**: plan said `INT → 4`, `DECIMAL → 8`; correct values from the empirical Designer-canonical enum (per `ignition-context-pack/04_named_queries.md`) are `INT → 2` (Int4) and DECIMAL has no native code so `→ 5` (Float8 — JDBC coerces).
- **`self.X()` not `self.rootContainer.X()`** inside `root.scripts.messageHandlers` and `root.scripts.customMethods`: per the verified `ignition-view-customMethods-scope` memory, `self` IS the root component at that scope. The plan-text had the wrong addressing.
- **`{X} != null` not `isnull(X, 0) != 0`** for nullable-BIGINT visibility gates: `isnull(value, default)` is SQL; Ignition expressions use `isNull(value)` or direct null comparison. The wrong syntax silently fail-evaluated to Quality-Bad and propagated to the view-level ERROR banner.

Commit range: `4e2f47d` (NQ Create) → `8c72bea` (NQ Update) → `bcb4575` (entity script) → `981b816` (ContainerConfig embed) → `7731120` (parent gate) → `61a9eaa` (DetailsHeader excise + tab init fix) → `08256e0` (expr/runScript fixes) → `be207a5` (Identity read-only restore).

**Status**: full smoke (spec §7 steps 1–11) passed 2026-05-26.

**Late-stage smoke fix (`2817cdd`)**: spec §7 step 4 originally wanted a ConfirmUnsaved popup on tab clicks with revert-to-current-tab semantics. `ia.container.tab` in Ignition 8.3 doesn't expose `instantiation` / `keepAlive` / pre-change events, so the popup-intercept-with-state-preservation pattern is infeasible against that component. Pivoted to the **tab-objects pattern** — `props.tabs` accepts a list of dicts per tab with `text` / `runWhileHidden` / `disabled` fields. New `BlueRidge.Parts.Item.itemMasterTabObjects(sectionDirty, activeTab)` returns objects with `runWhileHidden: true` (keeps inactive embeds mounted, preserves their local editDraft across tab visibility changes) and `disabled: true` on every non-active tab when any section is dirty (locks navigation visually instead of via script intercept). The active tab still shows the `●` dirty-dot prefix as the cue. Item-row click popup intercept stays as-is (separate code path). Spec §7 step 4 should be retro-edited to describe this UX. Reference: [Ignition tab container docs](https://www.docs.inductiveautomation.com/docs/8.3/appendix/components/perspective-components/perspective-container-palette/perspective-tab-container#adding-components-to-tabs).

### Defect Codes — Task 8 complete (2026-05-20)

The flex-repeater never re-rendered because the screen chained two bindings: a query+transform on `view.custom.allRows` (Python list[dict] with `java.sql.Timestamp` values from unread CreatedAt/DeprecatedAt) feeding a second expression binding `runScript("...filterAndMapRows", 0, {view.custom.allRows}, {view.custom.filter.searchText})`. Substituting a freshly transformed list-of-dicts back into another binding's args chokes Perspective's marshaling. Script Console didn't reproduce because it sends literal Python objects.

**Fix (`15eeee2`):** consolidated to the DowntimeCodes peer pattern — new `BlueRidge.Quality.DefectCode.search(filter)` does DB + client-side text filter + row mapping in one shot; `view.custom.rows` binds via single expr `runScript("...search", 0, {view.custom.filter})`; the flex-repeater downgrades to a plain property binding on `view.custom.rows`.

**Bundled follow-ups:**
- `15eeee2` — "Area (optional)" → "Area" label + handleSave null-area warning toast guard
- `75b4420` — Editor `editDraft.meta` initialized to the proper empty shape upfront (was `null`, causing red borders and "null" text on first render); explicit `props.text:""` on Excused checkbox (suppresses component default placeholder); list-view IncludeDeprecated wrapped in `IncludeDeprecatedField` matching DowntimeCodes filter sidebar
- `16291b6` — DefectCodeRow gains `params.deprecated` + root opacity binding (55% fade) + EditButton conditional hide for deprecated rows
- `4922ec4` — Both DefectCodeRow and DowntimeCodeRow switched EditButton hide from `position.display` to `meta.visible` so the 80px slot stays reserved and Area/Excused columns hold their x-position across deprecated rows ([[ignition-meta-visible-in-tables]])

Smoke-confirmed by Jacques: add, deprecate, filter all working.

### Defect Codes — open follow-ups (not blocking)

- **`getAllAreas` vs `listByTier`** — Task 5 added `listByTier` as a generic primitive but neither Task 6 (popup) nor Task 7 (list view) ended up using it. Ships with zero consumers. Cleanup option: migrate both area-dropdown sites to `listByTier('Area')` + transform when next touched.
- **Parity opportunity in DowntimeCodeEditor** — same `editDraft: {meta: null}` initial state and unset `props.text` on Excused checkbox. Symptoms haven't been reported there (its `params.editId` onChange populates meta earlier in lifecycle) but the same two-line fix would close the latent risk.

---

This file holds the **volatile** state of the project — current doc versions, active blockers, recent change narrative, and the next-session briefing. Durable identity, document map, architecture, and conventions live in `CLAUDE.md`.

---

## Current Document Versions

| Doc | Version | Rev Date | Status / Notes |
|---|---|---|---|
| Data Model | **v1.9m** | 2026-04-29 | Current. `Parts.OperationTemplate.RequiresSubLotSplit` added (FDS-05-009). |
| FDS | **v1.0** | 2026-05-04 | **First customer-review release.** Feedback-Welcomed callout added near front matter. In-document Revision History reset to start at v1.0; pre-release granular history (v0.1 through v0.11p) archived in `MPP_MES_FDS_CHANGELOG.docx`. From v1.0 forward, revisions are tracked in the FDS body itself. |
| Open Issues Register | **v2.17** | 2026-05-01 | Current. **9 items closed** from Jacques's 2026-05-01 markup: OI-07, -24, -25, -27, -28, -29, -30, -31, UJ-03 → all ✅ Resolved. 6 items remain Open. |
| Outstanding Items extract | **v2.0** | 2026-05-01 | Current. Reduced to 6 Open items per OIR v2.17. |
| User Journeys | **v0.9** | 2026-04-29 | Current. FDS v0.11m reconciliation pass. |
| Phased Plan — Plant Floor (Arc 2) | **v1.0** | 2026-04-29 | Current. Full rebuild from v0.3. |
| Phased Plan — Config Tool (Arc 1) | v1.7 | earlier | All 8 phases built and tested. |
| Seeding Registry | v1.0 | earlier | Current. |
| ERD | (current through v1.9i) | — | **Pending refresh** — see ERD Refresh Queue below. |

---

## 🚨 Active Blockers

### OI-35 — Architecture Decision Gate (HIGH)

**Long-horizon scaling, retention, archiving strategy must resolve before Arc 2 Phase 1 SQL build (`0014_arc2_phase1_shop_floor_foundation.sql`) commences.** Last-responsible-moment posture confirmed by Jacques 2026-04-29.

Eight architectural decisions:

1. Per-table retention class (push back on 20-yr for `Audit.OperationLog` / `InterfaceLog` / `FailureLog`).
2. Monthly partitioning + sliding-window automation across ~14 high-volume event tables. **Must be in CREATE migration.**
3. Columnstore on aged partitions (>90 days).
4. Materialized closure table for `Lots.LotGenealogy` — Honda audit O(1) vs recursive CTE at year 15. **Must be in CREATE migration.**
5. Materialize `TotalInProcess` / `InventoryAvailable` columns onto `Lots.Lot` (supersedes OI-23 view choice at scale). **Must be in CREATE migration.**
6. `Lots.IdentifierSequence_Next` locking model — row-locked vs SQL Server `SEQUENCE`.
7. Split `Audit.OperationLog` into 7-yr general + 20-yr `Lots.LotEventLog`. **Must be in CREATE migration.**
8. Filtered indexes on hot subsets.

Items 2/4/5/7 must be in the CREATE migration — retrofitting partition schemes, closure tables, or materialization columns to populated 100M+ row tables is operationally expensive.

**Resolution path:** internal Blue Ridge architecture review + MPP IT retention-policy negotiation (single meeting). Output: data model § "Scaling Decisions" + FDS-11 retention paragraph + Phase 1 migration content.

**Background:** `Meeting_Notes/2026-04-28_DataModel_Indexing_Scaling_Review.md`.

### Phase 0 Customer Validation Workshop with MPP — Track A (8 items)

Track A is the customer-validation gate. Track B is the architecture workshop above (OI-35). OI-31 closed 2026-05-01 (cutover seed at +10K above Flexware counter — captured in FDS-16-003) — only the rollout-shape sub-question remains as a Ben item, no longer Phase-0-gating.

1. **FDS-06-030** — WorkOrder BIT-flag enumeration.
2. **Historical data migration** — entity list + pre-flight validation + discrepancy review.
3. **ShotCount semantics** — cumulative counter (current default) vs derived from aggregated LOT quantity.
4. **Workstation `DefaultScreen` + `ConfirmationMethod` seeding** — per-Cell Perspective-view list + per-Cell `ConfirmationMethod` value (Vision / Barcode / Both).
5. **Honda AIM Hold/Update contract detail** — `PlaceOnHold` / `ReleaseFromHold` / `UpdateAim` signatures + error recovery (UJ-04 GetNextNumber pool flow already locked).
6. **Label template scope** — Flexware has 3 templates (CONTAINER / LOT / CONTAINER_HOLD); confirm matches + any new (Sort Cage / Hold / Void). Couples to S-09 in Seeding Registry.
7. **OI-32 Material Allocation operator screen** — premise challenged 2026-04-24; revised "close as not-reproduced" framing awaits Ben's explicit confirmation.
8. **OI-33 AIM pool empty-pool hard-fail customer validation** — confirm hard-fail is the desired posture (production stops on affected lines until pool refills; no soft-fallback).

---

## Outstanding for Next Session

### Open Part B UJs

- **UJ-05** Sort Cage serial migration — default direction committed (update-in-place + `Lots.ContainerSerialHistory`); awaits MPP Quality + Honda compliance affirmation.
- **UJ-19** Productivity DB replacement — Ben + MPP Production Control name the four PD reports; **MVP scope confirmed** per OI-30 closure (the four reports are deliverables; reports beyond the four = post-deployment change order).

### Open Part A items (4)

- **OI-32** Material Allocation operator screen — Ben's confirmation of "close as not-reproduced" framing.
- **OI-33** AIM pool empty-pool hard-fail — MPP Operations / IT customer validation.
- **OI-34** Production schedule leverage — MPP Production Control discovery walk-through.
- **OI-35** Long-horizon scaling, retention, archiving — Blue Ridge architecture review + MPP IT retention negotiation. **HARD GATE** before Arc 2 Phase 1 SQL build.

### SQL queue — Blue Ridge owns (gated on Phase 0)

1. ✅ **OI-07 + OI-12 correction migrations** — landed 2026-04-28 as `0013_oi07_oi12_corrections.sql`. 858/858 tests passing.
2. ✅ **LocationTypeDefinition CRUD support** — landed 2026-05-13 as `0014_locationattributedefinition_unique_active_name.sql` (filtered UNIQUE index) plus `R__Location_LocationTypeDefinition_SaveAll.sql` (bundled meta + child reconciliation in one transaction) and `R__Location_LocationTypeDefinition_Deprecate.sql` (cascade + FK guard against active Locations). 907/907 tests passing.
3. **Arc 2 Phase 1 SQL implementation** — needs renumber to **`0015_arc2_phase1_shop_floor_foundation.sql`** (0014 was taken by item 2). **GATED on Phase 0 — both tracks (Customer Validation + Architecture Decision)** before commencement. Phase 1 plan body bakes OI-35 architectural decisions into the migration on day one (partition functions, closure table if elected, materialization columns if elected, OperationLog split if elected, filtered indexes per B8). Includes the Phase 4 Data Model column add `Parts.OperationTemplate.RequiresSubLotSplit` if not landed earlier as its own migration.
4. **Phases 2–8 SQL** — sequential per the rebuilt plan (migrations `0016`–`0022`, shifted by one from the original reservation). Phase 4 migration `0018` includes the `RequiresSubLotSplit` ALTER if not already shipped.

### ERD refresh queue

ERD pending refresh for v1.9j–m additions:

- `ContainerConfig.ClosureMethod` values (`ByCount` / `ByWeight` / `ByVision`)
- `Lots.ShippingLabel.BannerAcknowledgedAt`
- `CoupledDownstreamCellLocationId` LocationAttribute under `CNCMachine`
- `Parts.OperationTemplate.RequiresSubLotSplit`

Per-schema tabs are the source of truth and remain canonical until next regen.

### Internal Docs Portal — ✅ landed 2026-05-12

Initial v1 build at `docs_portal/`. See "Recent Change Narrative" entry below for details.

### LocationTypeEditor modal — ✅ closed 2026-05-15

Full vertical stack landed 2026-05-13, convention-rectification pass 2026-05-14, all 8 smoke flows pass 2026-05-15 (commits `f469061` + `7ab9cd3`). Audit verified via `Audit.ConfigLog` rows. Marker removed from this section; historical detail in the "Recent Change Narrative" entries below.

### Non-blocking polish

- Memory file revision-history-format trim: applied to FDS only; not yet to Data Model + OIR.
- FDS-06-028 wording sharpen — WO Auto-Finish (§6.10) prose still mentions "camera-count mode" pre-tray-reframe. Low priority.
- ~~**Latent NQ v1 schema bug:** at least `location/Get/resource.json` is `version: 1`~~ — resolved 2026-05-14 (bumped to v2 with corrected sqlType enum). See `feedback_ignition_nq_resource_schema.md` memory for the empirically-verified Designer sqlType table.
- **Audit Log UI revisit** (Jacques, 2026-05-27) — current FailureLog + AuditLog browser pages work for Phase 3 verification but the UI itself wants another design pass at some point. Not blocking anything; revisit when there's a natural opening between feature work.

### Deferred follow-ups tied to future Config Tool surfaces

- **DieCastMachine Cell — read-only mounted-Tool status panel** (Plant Hierarchy editor). When the Tools master Config Tool surface is built, add a read-only section under (or alongside) Attributes on DieCastMachine Cell details showing the currently mounted Tool, mount timestamp, and mounting supervisor, sourced from `Tools.ToolAssignment_ListActiveByCell(@CellLocationId)`. Mutation (mount/release) stays on the plant-floor scan-in screen per FDS-05-034 + the `tool-assignment-modal` mockup design — the Plant Hierarchy panel is visibility-only so engineering can see what's mounted without going to the floor or asking. Deferred until the Tool master Config Tool screen exists (it would have no cross-link target today). Discussion: 2026-05-18 session.

### 🟠 Open at session end (2026-05-19)

### Item Master Phase 1 view shell landed (2026-05-19)

The Item Master Configuration Tool page (`/items`) is built as a Phase 1 visual shell — 7 new view files plus a page-config registration. Layout fully mirrors the mockup at `mockup/index.html` §"SCREEN: Item Master" (lines 308–860) and `+Add Item` modal (lines 2629–2715). All `view.custom.editDraft.*` form bindings active; dirty indicator works; tab switching works; toast placeholders for Save/Deprecate/Create/New Version all fire correctly.

**What's wired:** Page route, sidebar nav (already in place), ItemMaster shell, ItemRow flex-repeater + page-scoped click messaging, DetailsHeader form (9 inputs bidi-bound to editDraft.meta), TabStrip with 5-tab switching, 5 embedded tab views (ContainerConfig editable; Routes/BOMs/QualitySpecs/Eligibility read-only with placeholder New Version buttons), AddItem modal opened from +Add Item button.

**What's NOT wired (deliberately Phase 2+ per `docs/superpowers/specs/2026-05-19-item-master-view-shell-design.md`):**
- Item list / item details DB read paths (Phase 2)
- Item Save / Deprecate / Add Item Create flows (Phase 3)
- Container Config save (Phase 4)
- Routes versioning workflow — own design + plan (Phase 5)
- BOMs versioning workflow — own design + plan (Phase 6)
- Quality Specs cross-navigation (Phase 7)
- Eligibility editor (Phase 8)

**Pickup notes for next session:** Designer-side smoke test of the page (5G0 dummy data renders, item rows click, fields edit + dirty indicator flips through embedded boundary, all 5 tabs visible). The bidi-on-Object-param mechanism for Embedded View `props.params.value` is the architectural risk — if it doesn't round-trip when smoke tested, fall back per R1 in the design doc.

### 🟠 Audit-pages customMethods addressing bug (2026-05-19 — fixed same day, note retained)

The `view.custom.editDraft` / `view.custom.selected` dirty-check binding in the audit views surfaced a `customMethods` scope issue: `root.scripts.customMethods` attaches methods to the ROOT COMPONENT, not to the view. Addressing inside a view-level onChange script must use `self.rootContainer.X()` (not `self.X()` or `self.view.X()`). Fixed in the same session; see `feedback_ignition_view_customMethods_scope.md` memory for the full pattern. Relevant for any future view that calls `customMethods` from within embedded-view or event-handler context.

---

## OIR Status (v2.17, 2026-05-01)

54 items total: **47 resolved, 0 in review, 6 open, 1 superseded.**

- **Open Part A:** OI-32 (Material Allocation framing — Ben), OI-33 (AIM pool hard-fail — MPP Ops / IT), OI-34 (production schedule leverage — Production Control), OI-35 (scaling / retention — Blue Ridge architecture + MPP IT) **HARD GATE**
- **Open Part B:** UJ-05 (Sort Cage serial migration — MPP Quality + Honda), UJ-19 (PD replacement — Ben + Production Control name the four reports)

---

## Decision Owners

Items genuinely gating downstream work, by owner:

1. **OI-35 Architecture Decision Workshop** — Blue Ridge architecture lead + MPP IT (retention-policy negotiation). Gates Arc 2 Phase 1 SQL build.
2. **Phase 0 Customer Validation Workshop with MPP** — 9 gating items above. Gates Arc 2 Phase 1 SQL build.
3. **Ben** — OI-32 close-as-not-reproduced confirmation; OI-31 rollout-shape decision is no longer gating (OI-31 closed 2026-05-01 with the +10K seed-offset rule; rollout shape is operationally informational only). Memo at `Meeting_Notes/2026-04-24_OI-31_Single-Line_Deployment_Impact.md`.
4. **Tom (security SME)** — final elevated-action list validation (FDS-04-007).

---

## Build Status

- **Configuration Tool (Arc 1):** Phases 1–8 + G.1–G.5 + 0013 corrections + 0014 LocationTypeDefinition CRUD support complete. Audit page procs (FailureLog_List, ConfigLog_List, FailureLog_DistinctProcedures) landed 2026-05-19. Phase 5 Routes versioning + Phase 6 BOMs versioning landed 2026-05-26. **1034/1034 tests passing** across 24+ test suites.
- **SQL artifacts:** `/sql/` folder, **16 versioned migrations** (latest: `0015_audit_add_event_type_deleted` + `0016_parts_bom_unique_draft`) **+ 230+ repeatable procs.** PowerShell reset script `Reset-DevDatabase.ps1` auto-discovers and runs all scripts via `sqlcmd.exe`. Tested on SQL Server 2025.
- **Plant Floor (Arc 2):** Mockup landed at `mockup/plantFloor.html` (12 terminal/lot routes + Home Page). SQL not yet started — gated on Phase 0.
- **Ignition project (live build, Arc 1):** Phase 1 Location pipeline + toasts + scan helper landed 2026-05-12. LocationTypeEditor full stack 2026-05-13. **Convention rectification 2026-05-14** — `Common.Db`/`Common.Util`/`Common.Ui` layer built, `Common.Action` deleted, 5 entity scripts retrofitted through Common helpers, LocationTypeEditor view restructured to `editDraft`/`selected` pattern + dirty indicator + Cancel, all NQs normalized (camelCase identifiers, Designer-canonical sqlType enum, v2 schema). Designer smoke-test pending. Audit pages (FailureLog + AuditLog) landed 2026-05-19 with the customMethods addressing bug fixed same day. **Downtime Codes Ops view wired 2026-05-19** — first Config Tool admin surface to combine live-data List + popup editor + page-scoped refresh pulse (separate pattern from the audit-browser read-only pattern).
- **Seed data loading:** CSVs ready in `reference/seed_data/` (876 rows total). `machines.csv` not yet loaded; MPP parts list not yet provided; `defect_codes.csv` not yet loaded; `downtime_reason_codes.csv` has bulk-load proc but not yet invoked.

---

## Source-of-Truth Doc Locations

| Doc | Markdown source | Word output |
|---|---|---|
| Data Model | `MPP_MES_DATA_MODEL.md` | `MPP_MES_DATA_MODEL.docx` |
| FDS | `MPP_MES_FDS.md` | `MPP_MES_FDS.docx` |
| FDS Changelog | `MPP_MES_FDS_CHANGELOG.md` | `MPP_MES_FDS_CHANGELOG.docx` |
| OIR | `MPP_MES_Open_Issues_Register.md` | `MPP_MES_Open_Issues_Register.docx` |
| User Journeys | `MPP_MES_USER_JOURNEYS.md` | `MPP_MES_USER_JOURNEYS.docx` |
| Phased Plan Plant Floor | `MPP_MES_PHASED_PLAN_PLANT_FLOOR.md` | `MPP_MES_PHASED_PLAN_PLANT_FLOOR.docx` |
| Seeding Registry | `MPP_MES_SEEDING_REGISTRY.md` | `MPP_MES_SEEDING_REGISTRY.docx` |
| ERD | `MPP_MES_ERD.html` | — |

Arc 2 revisions spec: `docs/superpowers/specs/2026-04-23-arc2-model-revisions.md` (still untracked in working tree).

Indexing review (carries OI-35 Decision Gate callout): `Meeting_Notes/2026-04-28_DataModel_Indexing_Scaling_Review.md`.

Phase G capability snapshot: `Meeting_Notes/2026-04-22_Phase_G_Capabilities_Summary.md`.

---

## Recent Change Narrative

A timeline of session-by-session changes. Most recent first.

### 2026-05-20 — Item Master Phase 2: read paths + R1 smoke test bed

Phase 2 of the 8-phase Item Master Configuration Tool. Three new Named Queries (`parts/Item_List`, `parts/Item_Get`, `parts/ContainerConfig_GetByItem`) wrap existing stored procs. Two new entity scripts (`BlueRidge.Parts.Item`, `BlueRidge.Parts.ContainerConfig`) route through `Common.Db`. The parent `ItemMaster/view.json` now binds `view.custom.items` to a `runScript(BlueRidge.Parts.Item.getAllForList, ...)` expression and its `itemRowClicked` handler calls the live entity scripts to populate `view.custom.editDraft.meta` + `view.custom.editDraft.containerConfig` from the DB. The other four tab slices (routes/boms/qualitySpecs/eligibility) are left empty until their own phases land.

**No SQL changes.** Tests stay at 937/937 (existing `Parts.Item_List`, `Parts.Item_Get`, `Parts.ContainerConfig_GetByItem` reused as-is).

**Spec:** `docs/superpowers/specs/2026-05-20-item-master-phase2-design.md`
**Plan:** `docs/superpowers/plans/2026-05-20-item-master-phase2.md`

**Files touched (8 created + 2 modified):**
- 3 new NQ folders under `ignition/projects/MPP_Config/ignition/named-query/parts/`
- 2 new entity script modules under `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Parts/`
- 1 view edit + resource.json metadata bump on `BlueRidge/Views/Parts/ItemMaster/`

**R1 smoke verification — PENDING.** Designer smoke checklist in spec §9. R1 holding is the precondition for Phase 3-8 building on the bidi-embed pattern. If smoke fails, the page-scoped message fallback documented in spec §2 governs the rebuild.

**Worktree:** built in `.claude/worktrees/Agent-B-item-master-phase2` on branch `worktree-Agent-B-item-master-phase2`. Ready to merge to main once R1 smoke verifies green.

**Next pickup:** Jacques walks the R1 smoke checklist in Designer. On pass → Phase 3 (Item Save / Deprecate / Add Item Create) brainstorming, including cleanup of the `PartsPerBasket` Identity field that doesn't map to a real `Parts.Item` column. On fail → fallback design cycle (page-scoped messages instead of bidi-embed).

### 2026-05-19 — Item Master Phase 1 view shell

Phase 1 of an 8-phase Item Master Configuration Tool build (per `docs/superpowers/specs/2026-05-19-item-master-view-shell-design.md` + `docs/superpowers/plans/2026-05-19-item-master-view-shell.md`).

**Files landed (8 new view files + 1 config edit):**
- `page-config/config.json` — added `/items` route entry
- `views/BlueRidge/Views/Parts/ItemMaster/{resource.json, view.json}` — page shell
- `views/BlueRidge/Components/Parts/ItemMaster/ItemRow/{resource.json, view.json}` — flex-repeater row sub-view
- `views/BlueRidge/Components/Parts/ItemMaster/ContainerConfig/{resource.json, view.json}` — tab 1 (editable form)
- `views/BlueRidge/Components/Parts/ItemMaster/Routes/{resource.json, view.json}` — tab 2 (published-only table)
- `views/BlueRidge/Components/Parts/ItemMaster/Boms/{resource.json, view.json}` — tab 3 (published-only table)
- `views/BlueRidge/Components/Parts/ItemMaster/QualitySpecs/{resource.json, view.json}` — tab 4 (read-only linked list)
- `views/BlueRidge/Components/Parts/ItemMaster/Eligibility/{resource.json, view.json}` — tab 5 (Area dropdown + machine table)
- `views/BlueRidge/Components/Popups/AddItem/{resource.json, view.json}` — +Add Item modal shell

**Architecture:**
- Parent ItemMaster holds all state on `view.custom` (items, selected, editDraft, itemTypes, uoms, activeTab, mode, search, typeFilter)
- 5 always-mounted Embedded Views in TabPanels, gated by `position.display = "{view.custom.activeTab} = '<key>'"`
- Each embedded tab's `props.params.value` bidirectionally bound to `view.custom.editDraft.<slice>` — child form-field writes propagate back up through the embed boundary (R1 in the design doc — first use of this pattern in the project, needs Designer smoke validation)
- ItemRow flex-repeater fires page-scoped `itemRowClicked` message handled by `root.scripts.messageHandlers[0]` on the parent
- Save / Deprecate / Create Item / New Version buttons all fire `BlueRidge.Common.Notify.toast(...)` placeholders for Phases 3/5/6

**Roadmap forward:** Phase 2 wires read paths; Phase 3 wires Item mutations + Add Item Create; Phase 4 Container Config save; Phases 5/6 are substantial Routes/BOMs versioned-entity workflows that warrant their own design docs. Phases 7/8 are Quality Specs cross-link and Eligibility editor.

### 2026-05-19 — Downtime Codes Ops view wired end-to-end (first Config Tool admin surface)

Plan + spec committed first (`docs/superpowers/specs/2026-05-19-downtime-codes-wiring-design.md` + `docs/superpowers/plans/2026-05-19-downtime-codes-wiring.md`), then executed via subagent-driven development across 9 tasks. Scaffolded `Views/Oee/DowntimeCodes` was sample-data only; this session turned it into a fully interactive admin surface.

**Backend layer** — 6 new NQs under `named-query/oee/` (`DowntimeReasonCode_List` / `_Get` / `_Create` / `_Update` / `_Deprecate` plus `DowntimeReasonType_List` with 30-min cache). Two new entity-script modules: `BlueRidge.Oee.DowntimeReasonType` (`getAll`, `getForDropdown(includeUnassigned, includeAll)`) and `BlueRidge.Oee.DowntimeReasonCode` (full CRUD: `search/getOne/add/update/deprecate/emptyMeta`, with client-side `searchText` filter since the proc has no `@SearchText`). Added `BlueRidge.Location.Location.getAllAreas(includeAll)` as a peer read helper that filters the existing `location/GetTree` flat result for `HierarchyLevel == 2`.

**Spec-review catch** — Initial plan asserted Areas were `HierarchyLevel == 3` (ISA-95 ordinal counting). The project's seed (migration 0002 line 110) places Areas at `HierarchyLevel == 2` (zero-indexed: Enterprise=0, Site=1, **Area=2**, WorkCenter=3, Cell=4). Spec reviewer caught the defect before code shipped to a view; plan + spec corrected, code patched. Seeded Areas are DC/MS/QC/TS (4, not 3 -- QC included but downtime typically only uses the first 3).

**New popup view** — `BlueRidge/Components/Popups/DowntimeCodeEditor`: single popup for both Add and Edit via `view.params.mode = "create"|"update"` discriminator, with `editDraft/selected` state, dirty indicator, and `ConfirmUnsaved` wiring on both header X and footer Cancel. Code field is readonly in update mode (immutable post-create per the proc). Deprecate button visible only in update mode. Refresh pulse on Save/Deprecate via page-scoped `downtimeCodesRefresh` message.

**Wired existing views** — `BlueRidge/Components/DowntimeCodeRow` got an `id` input param and Edit button onClick → openPopup. `BlueRidge/Views/Oee/DowntimeCodes` got: filter keys renamed (`area` → `areaLocationId`, `reasonType` → `downtimeReasonTypeId`) to match proc params, hardcoded sample arrays replaced with `runScript` bindings, `+ Add Code` button wired to openPopup, repeater binding restructured with script transform mapping proc PascalCase → row-component lowercase keys, and `downtimeCodesRefresh` message handler at root that shallow-copies `view.custom.filter` to force re-eval of the rows binding.

**Bugs caught during smoke testing** —
- `scope: "C"` on `component.onActionPerformed` doesn't fire reliably; project standard is `scope: "G"` (matches PlantHierarchy + AuditLog precedent). Fixed both AddCodeButton and DowntimeCodeRow EditButton.
- `IncludeDeprecated` checkbox originally wrapped in a flex+label workaround; Jacques reverted to single-component `ia.input.checkbox.props.text` — works fine in normal-width containers. New memory entry `feedback_ignition_checkbox_text_prop_ok.md` corrects my earlier overcaution.
- Edit button on deprecated rows hidden via `meta.visible` (not `position.display`) to preserve column alignment across the tabular layout. New memory entry `feedback_ignition_meta_visible_in_tables.md` notes table rows are the legitimate exception to the "use position.display" convention.

**Visual polish** — Deprecated rows in the list rendered at 55% opacity (root `style.opacity` binding), Edit button hidden via `meta.visible: false`. Greyed visual + no Edit affordance for deprecated rows; toggle "Include deprecated" to surface them.

**Bulk-load explicitly deferred** — `Oee.DowntimeReasonCode_BulkLoadFromSeed` proc exists and is tested. One-shot cutover operation; will run from Designer Script Console with the 353-row seed JSON when MPP confirms the DC/MS/TS → AreaLocationId mapping. No UI button needed.

**SQL untouched** — no migrations or repeatable procs added. Test suite remains at 937/937.

**Generalizes** — this is the reference pattern for any future Config Tool admin surface where a single entity has full CRUD (no compound children — that pattern stays the `SaveAll` bundled-proc reference impl): List-Detail view with live runScript-bound rows, popup editor with mode discriminator + ConfirmUnsaved, page-scoped refresh pulse. Distinct from the audit-browser pattern (read-only with TOP cap + COUNT(*) OVER total).

**Parallel work landed same day** — audit-pages addressing bug (customMethods scope) fixed; `BlueRidge.Location.Location.listByTier(tierCode)` + `location/Location_ListByTier` NQ added as prep for the upcoming Defect Codes Config Tool screen.

### 2026-05-19 — Audit pages landed (FailureLog + AuditLog Config Tool browsers)

Design and plan committed first (`docs/superpowers/specs/2026-05-19-audit-pages-design.md` + `docs/superpowers/plans/2026-05-19-audit-pages.md`), then executed via 13 commits using the subagent-driven development pattern. Full SQL reset + test run closes the session at **937/937 tests passing**.

**SQL** — `Audit.FailureLog_List` and `Audit.ConfigLog_List` both received `TOP 1000` caps and `COUNT(*) OVER() AS TotalCount` window-aggregate columns, which drive the "Showing N of M — narrow your filter" banner on both pages. FailureLog_List gained `@FailureReasonLike` substring filter and `@LogEntityTypeId` filter; ConfigLog_List gained `@DescriptionLike` and `@SeverityId`. New `Audit.FailureLog_DistinctProcedures` proc powers the Procedure dropdown on the FailureLog page — returns every distinct `ProcedureName` that has ever logged a failure. Test extensions landed alongside each proc. Note on canonical column names: `Audit.ConfigLog` uses `LoggedAt`/`UserId` (not `ChangedAt`/`AppUserId`); the proc passes those through unchanged and downstream Ignition consumers use `loggedAt` / `userDisplayName` accordingly. 220 repeatable procs total.

**Ignition NQs** — 9 new named queries under `named-query/audit/`: `FailureLog_List`, `FailureLog_GetByEntity`, `FailureLog_GetTopReasons`, `FailureLog_GetTopProcs`, `FailureLog_DistinctProcedures`, `ConfigLog_List`, `ConfigLog_GetByEntity`, `LogEntityType_List`, `LogSeverity_List`.

**Entity scripts** — 4 new modules: `BlueRidge.Audit.LogEntityType` (`getAll`), `BlueRidge.Audit.LogSeverity` (`getAll`), `BlueRidge.Audit.FailureLog` (3-NQ-bundled `search()` returning `{rows, totalCount, topReasons, topProcs}`), `BlueRidge.Audit.ConfigLog` (1-NQ `search()` returning `{rows, totalCount}`). Both `search()` functions deep-unwrap their filter dict via `Common.Util._u()` at entry to defend against tile-click / bidirectional-binding QualifiedValue wrappers. `Common.Util.prettyJson` helper added — formats AttemptedParameters / Old / New JSON for the detail popups (try/except wrapper; falls back to raw text on parse failure).

**New views** — three new components written as files (new-view path; no Designer cache conflict): `BlueRidge/Components/Popups/FailureDetail` (single AttemptedParameters JSON block), `BlueRidge/Components/Popups/ConfigChangeDetail` (side-by-side Old + New diff blocks), `BlueRidge/Components/Audit/TopRow` (reusable tile-row sub-view shared between Top Reasons + Top Procs panels; fires page-scoped `applyFilterFromTile` message on tile click). FailureLog and AuditLog views fully wired: default date range = last 7 days, no auto-apply on load, explicit Apply + Reset buttons, TOP 1000 cap with banner. Tile-row click sets the appropriate filter field and triggers apply. FailureLog filter set: Date / EntityType / Procedure / AppUser / Search text. AuditLog filter set: Date / EntityType / Severity / Search text.

**Deviation noted** — AuditLog lost its AppUser dropdown during the wire pass; the original mockup's `UserDropdown` slot was repurposed to `SeverityDropdown`. The design called for AppUser filter on both pages. Tracked as a follow-up polish item; not blocking any other work.

**Proc return shapes documented** — TopReasons / TopProcs procs return `FailureCount` (not `Count`). The view's flex-repeater transform accounts for this.

**Session also included** (earlier commits, not audit-pages scope): FDS v1.2 (`ParentLocationId` immutability rule, `5bd3d80`) and plant hierarchy view work (`d0d5355`).

### 2026-05-15 — LocationTypeEditor smoke test + close-confirmation dialog

Two commits landed:
- `f469061` fix(loc-type-editor): dirty indicator + attribute-table alignment
- `7ab9cd3` feat(loc-type-editor): close-confirmation dialog for unsaved work

**Smoke test — all 8 flows pass.** Tier select, definition pick, edit + dirty indicator, Cancel revert, Save commit (audit verified — `Audit.ConfigLog` rows 251/252 with full pre/post payloads), Add Definition, Add/Remove Attribute, Deprecate (FK guard rejects active-Location references with graceful toast).

**Fixes landed:**

- Attribute row text-field events moved from `events.component.onActionPerformed` (no-op — text-fields don't have Component Events at all) to `events.dom.onBlur` for AttributeName / DefaultValue / Uom / Description. Dirty indicator now fires when user tabs out of any attribute field.
- AttrTableHeader column basis / grow aligned with AttributeDefinitionRow. ColArrows + ColRemove converted from `ia.display.label` to `ia.container.flex` (empty labels were collapsing despite `basis`).
- Pulled `min-width: 180px` from `.psc-search-input` — class was overloaded as a generic input look across 24 sites, and the 180px floor was overriding flex sizing in every attribute-row cell.

**New view:**

- `BlueRidge/Components/Popups/ConfirmUnsaved` — parameterised 3-button popup (Save & Close / Discard & Close / Cancel). LocationTypeEditor's CloseIcon + footer CloseButton now dirty-check before closing; if dirty, open this popup; user's choice routes back via page-scoped `confirmUnsavedResult` message handler. Reusable across future editors — see `project_mpp_confirm_unsaved_pattern.md` memory.

**Workflow learning — file-edit boundary established.** view.json edits to existing views are unreliable due to (a) Designer's GSON serialization of `=` / `'` / `<` / `>` as 6-char unicode escapes (`=` etc.) that fight tool JSON-parsing, and (b) Designer's in-memory cache conflicts. The Designer "Files vs Gateway" conflict dialog also has confusing semantics — picking "Gateway" pushed Designer's cached state to disk and overwrote our file edits.

Established split going forward (also added to CLAUDE.md):

| File type | Edit path |
|---|---|
| view.json (existing views) | Designer — Claude writes Designer-step instructions |
| view.json (new views) | File + scan — no Designer cache to conflict with |
| stylesheet.css | File |
| Python script modules | File |
| NQ `query.sql` / `resource.json` | File |
| SQL migrations / procs | File |

**Cosmetic items still open** (next session):

- TypeBadge `nameForTier` runScript returns NULL — needs gateway-log traceback to diagnose
- Description input renders literal "null" when DB value is NULL — coalesce missing on read path
- `â€` garble on em-dash placeholders — UTF-8 / Latin-1 mismatch somewhere in render pipeline

**Memory added/updated:**

- NEW `feedback_ignition_designer_unicode_escapes.md` — Designer 8.3 GSON escape style for `=` / `'` / `<` / `>` and how to match it when file-editing view.json scripts.
- NEW `project_mpp_confirm_unsaved_pattern.md` — reusable ConfirmUnsaved popup pattern for editors with `editDraft` / `selected` state.
- UPDATED `feedback_ignition_view_edit_boundary.md` — conflict-resolution dialog learning ("Gateway" overwrites disk with Designer's cache, not the inverse).

**Context pack additions:**

- `02_perspective_views.md` — note on Designer's GSON unicode-escape serialization
- `07_conventions_and_antipatterns.md` — close-confirmation popup pattern + text-field-events caveat (no Component Events; use `dom.onBlur`)

### 2026-05-14 — Convention rectification per Hunter's pack updates

Hunter merged in pack updates (`hunter/explore` → `main` fast-forward, commits `784a981` / `591da53` / `cf0fb42` / `fc534bf`) that source the `ignition-context-pack/` from `MPP_MES_CONFIG_TOOL_FRONTEND_CONVENTIONS.md` v1.2 and document the `SaveAll` bundled pattern. Our 2026-05-12/13 Ignition work was built against the older pack and deviated in several places. Today's session rectified the deviations as a coordinated four-phase pass.

Decision sheet: `Meeting_Notes/2026-05-14_Convention_Rectification_Review.md` (line-by-line response document with Jacques's per-item decisions).

**Phase 1 — Foundation built (Common helpers):**

- **`BlueRidge.Common.Db`** — `execList` / `execOne` / `execMutation`. Only layer that calls `system.db.runNamedQuery`. Handles BIT Status convention.
- **`BlueRidge.Common.Util`** — `log` (inspect-frame auto-fill of calling module + function), `_currentAppUserId` (reads `session.custom.appUserId` with dev fallback to AppUser.Id 2), `extractQualifiedValues`, `convertWrapperObjectToJson`.
- **`BlueRidge.Common.Ui.notifyResult(result, successTitle, successMsg, errorTitle)`** — routes mutation result to toast.
- **`BlueRidge.Common.Notify.toast`** — `DEFAULT_TTL_SEC` 8 → 5 per C1 decision.
- **`BlueRidge.Common.Action`** deleted (was the parallel-universe `execMutation` that mixed DB + toast).
- **`BlueRidge.Common.Session.getCurrentUserId`** now a thin shim over `Common.Util._currentAppUserId`.

**Phase 2 — Entity scripts retrofitted + NQ casings normalized:**

- 5 entity scripts (`Location.Location`, `Location.Tree`, `Location.LocationType`, `Location.LocationTypeDefinition`, `Location.LocationAttributeDefinition`) rewritten to route every DB call through `Common.Db.*`. All `system.db.*` direct calls eliminated outside `Common.Db`. Per-module logger declarations removed; replaced with direct `Common.Util.log(...)` calls. 5 copies of local `_rowsToDicts` helper deleted.
- Module surface standardized per pack convention: `listByType` → `getAll`, `listByDefinition` → `getAll`, `listAll` → `getAll`, `get` → `getOne`. Custom domain handlers (`handleMoveUp`/`handleMoveDown`/`handleSaveAll`/`handleDeprecate`/factories) kept per Jacques's A4 decision ("standard is starting point, not complete list").
- 9 NQ files normalized: parameter identifiers → camelCase (`LocationID`/`UserID`/`Id`/`AppUserId` → `locationId`/`userId`/`id`/`appUserId`); query.sql `:placeholder` references updated to match.
- `Get/resource.json` bumped v1 → v2 schema (was the latent Designer-NPE bug flagged 2026-05-13).
- `print ds` stripped from `Location.code.py:124` (B1); `Tree.code.py` header rewritten to standard module shape (B2).

**Phase 3 — LocationTypeEditor view restructured to editDraft/selected pattern:**

- `view.custom.meta` + `view.custom.attributesDraft` → `view.custom.selected` (baseline) + `view.custom.editDraft` (in-flight), each carrying `{meta, attributes}`.
- All form bindings repointed to `editDraft.meta.*`; attributes repeater binding to `editDraft.attributes`.
- 4 message handlers (`definitionClick`, `attrDraftUpdate`, `attrDraftRemove`, `attrDraftMove`) rewritten to mutate `editDraft.attributes` and maintain the `selected` baseline on selection changes.
- 5 inline scripts rewritten (Save, Deprecate, +Add Definition, +Add Attribute, TierDropdown onChange) for the new state shape.
- **New:** dirty indicator label bound to `if({view.custom.editDraft} != {view.custom.selected}, "● Unsaved changes", "")` per pack universal rule.
- **New:** Cancel button in DetailsHeader — reverts `editDraft = dict(selected)` in update mode; resets to view mode in create mode; hidden when no pending changes.
- Save handler does proper deep-copy commit on success (`selected = {meta: dict(...), attributes: [dict(a) for a in ...]}`) so the dirty indicator clears.

**Phase 4 — Pack contributions + memory updates (two-way street):**

- **`ignition-context-pack/03_script_python.md`**: `execMutation` updated for BIT Status convention; full SP shape (`DECLARE @Status BIT = 0`) baked in verbatim. `notifyResult` signature updated. **New `Common.Notify` section** documenting popup-per-toast surface (top-right FIFO max 5, errors persist, non-errors auto-dismiss 5s — supersedes the single-banner pattern; toast is now THE standard, no variant). `runNamedQuery` vs `execQuery` clarified.
- **`ignition-context-pack/04_named_queries.md`**: Status-row pattern rewritten with verbatim SP shape. **sqlType section rewritten** with the empirically-verified Designer-canonical enum table (Int1/Int2/Int4/Int8/Float4/Float8/Boolean/String/DateTime/ByteArray = 0/1/2/3/4/5/6/7/8/20) — explicit warning that `java.sql.Types` codes are irrelevant. NQ v2 schema section added.
- **`ignition-context-pack/07_conventions_and_antipatterns.md`**: mutation feedback section updated for toast; **new "Mode discriminator on shared add/edit popups" section** (C4); all `Status='OK'`/`'ERROR'` references updated to BIT 1/0.
- **`ignition-context-pack/02_perspective_views.md`**: **new "Tree mutations — return `{items, selectedPath, selected}`" section** (C2) documenting our re-anchor pattern and the `Tree.props.selection` writeback misfire workaround.
- **`ignition-context-pack/00_README.md`**: file-13 / file-14 descriptions updated.

**sqlType correction (A9 → empirical resolution):**

Initial reading of A9 had me writing `sqlType: 2` for BIGINT (based on observing existing Designer-saved NQs with that code). Jacques provided an empirical reference (Designer-saved NQ with one parameter of every type) that revealed **Designer uses its own internal type enum, NOT `java.sql.Types`**:

| sqlType | Designer name | DB type |
|---|---|---|
| 0 / 1 / 2 / 3 | Int1 / Int2 / Int4 / Int8 | TINYINT / SMALLINT / INTEGER / **BIGINT** |
| 4 / 5 | Float4 / Float8 | REAL / FLOAT |
| 6 | Boolean | BIT |
| 7 | String | **NVARCHAR / VARCHAR** |
| 8 | DateTime | DATETIME |
| 20 | ByteArray | VARBINARY |

Existing Designer-saved NQs in the project had BIGINT params with `sqlType: 2` (Int4) — that was a UI selection mistake by whoever created them; SQL Server's INT → BIGINT silent coercion meant the procs worked anyway. All NQ resource.json files corrected: BIGINT params `2` → `3`, NVARCHAR params `-9` → `7`. Memory entry `feedback_ignition_nq_resource_schema.md` updated with the full Designer enum.

**Memory entries added/updated:**

- UPDATED `feedback_ignition_nq_resource_schema.md` — full Designer sqlType enum table; corrects earlier "sqlType 2 for BIGINT" claim.

**Files touched (42 total):**

- 3 new Common modules (Db, Ui, Util) — 6 files
- 1 deleted module (Action) — 2 files
- 9 NQ folders modified (resource.json + query.sql each)
- 5 entity scripts rewritten
- 1 view (LocationTypeEditor) restructured
- 5 pack files updated
- 1 PROJECT_STATUS.md updated
- 1 memory file updated
- 1 review markdown added to Meeting_Notes/

**Next pickup:** smoke-test the LocationTypeEditor modal in Designer end-to-end (tier select, definition pick, edit fields with dirty indicator, Cancel revert, Save commit, Add Definition flow, Add Attribute flow, Deprecate FK guard).

### 2026-05-13 — LocationTypeEditor modal: full vertical stack scaffolded (WIP)

Big day. Built the complete top-to-bottom stack for the Plant Hierarchy view's cog-button "Location Type Editor" modal: SQL migration + procs + tests, named queries, entity scripts, embedded views, popup view, and the cog-button onClick wiring. **907/907 SQL tests pass.** End-of-day smoke-test in Designer still surfaces issues; modal is NOT FULLY WORKING yet but the full surface area is in place to iterate from.

**SQL (all green, all tests passing):**

- **Migration 0014** — `0014_locationattributedefinition_unique_active_name.sql`. Filtered UNIQUE index on `Location.LocationAttributeDefinition(LocationTypeDefinitionId, AttributeName) WHERE DeprecatedAt IS NULL`. Defends the bundled save proc against active-name collisions; allows reuse of deprecated names. **Note:** this slot was originally reserved for Arc 2 Phase 1's `0014_arc2_phase1_shop_floor_foundation.sql`. That work shifts to `0015` when it lands (SQL queue updated accordingly).
- **`R__Location_LocationTypeDefinition_SaveAll.sql`** — bundled save proc. Meta as params (`@Id`, `@LocationTypeId`, `@Code`, `@Name`, `@Icon`, `@Description`, `@AppUserId`) + `@AttributesJson NVARCHAR(MAX)`. Server-side reconciliation: OPENJSON parse → validate within-batch uniqueness + immutable Code/LocationTypeId on update → DEPRECATE missing children → UPDATE Id-matched (SortOrder = array index) → INSERT NULL-Id rows → one Audit row with full pre/post snapshot → status-row SELECT. See `project_mpp_bundled_save_pattern.md` memory.
- **`R__Location_LocationTypeDefinition_Deprecate.sql`** — soft-delete with cascade to active children. FK guard rejects when active `Location.Location` rows reference. Idempotent re-deprecate returns `Status=1, Message='Already deprecated.'`.
- **Tests:** `030_LocationTypeDefinition_SaveAll.sql` (12 scenarios), `040_LocationTypeDefinition_Deprecate.sql` (6 scenarios). All assertions pass.

**Ignition (scaffolded, end-of-day modal still buggy in Designer):**

- **5 named queries:** `location/LocationType_List`, `LocationTypeDefinition_List`, `LocationAttributeDefinition_ListByDefinition`, `LocationTypeDefinition_SaveAll`, `LocationTypeDefinition_Deprecate`. Resource.json forced to v2 schema after Designer 8.3.5 NPE'd on v1 inheritance from the `Get` NQ template.
- **3 entity script modules:** `BlueRidge.Location.LocationType` (`listAll`, `nameForTier`), `BlueRidge.Location.LocationTypeDefinition` (`listByType`, `handleSaveAll`, `handleDeprecate`, `emptyMeta`, `emptyAttributeRow`, `metaFromDefinition`), `BlueRidge.Location.LocationAttributeDefinition` (`listByDefinition`). All read functions wrap their `system.db.execQuery` calls in try/except with error-toast on failure.
- **`Common.Action.runMutation` upgraded** — now returns the status-row dict (or None) instead of bool. Backwards-compatible (truthy/falsy preserved); `handleSaveAll` reads `result["NewId"]` from the return.
- **3 new views:** `BlueRidge/Components/AttributeDefinitionRow` (editable row sibling of read-only AttributeRow), `BlueRidge/Components/DefinitionItem` (chip/button for tier-scoped definition selection, root = flex with label inside), `BlueRidge/Components/Popups/LocationTypeEditor` (the modal — tier dropdown + definitions repeater + Definition Details panel + Attribute Definitions table + footer Close).
- **PlantHierarchy/view.json** cog icon (`LocationTypeEditorButton`) wired to `dom.onClick` opening the modal via `system.perspective.openPopup(id='mpp-loc-type-editor', view='BlueRidge/Components/Popups/LocationTypeEditor', modal=True, ...)`.

**Bugs hit + fixed during the day** (each = a memory entry now):

1. **Toast popup auto-dismiss never fired** — `view.custom.dismissAt` had no binding, so the polled `now(500) > dismissAt` expression stayed false forever. Fix: add an expression binding on `dismissAt` that computes `dateArithmetic(now(0), {view.params.ttl}, 'second')`. Updated `project_mpp_toast_system.md`.
2. **Tree-selection re-anchor pattern** — when items change programmatically the selection path goes stale. Fixed by having `handleMoveUp`/`handleMoveDown` return `{tree, selectedPath, selected}` so the view writes all three atomically. Same pattern can be reused for any future tree-mutating action.
3. **NQ resource.json schema v1 vs v2** — Designer 8.3.5 NPEs on v1 shape. Bumped all 5 new NQs to v2 with the Designer-saved field order. Pre-existing `location/Get` is still v1 — flagged for cleanup. New memory: `feedback_ignition_nq_resource_schema.md`.
4. **`def list()` shadowed Python builtin** in `BlueRidge.Location.LocationType` — broke `_rowsToDicts`'s `list(...)` call. Renamed to `listAll()`. Genuine junior miss; flagged it as such in the conversation. Update Plant Hierarchy view + binding to call `listAll`.
5. **Message scope: view vs page** — `scope='view'` doesn't propagate from an embedded view to its parent. Chip click from inside `DefinitionItem` with `scope='view'` never reached the popup's `definitionClick` handler. Fix: change to `scope='page'` and flip handler config to `pageScope: true`. Same fix applied to `attrDraftUpdate`/`attrDraftRemove`/`attrDraftMove` from `AttributeDefinitionRow`. New memory: `feedback_ignition_message_scope.md`.
6. **`lookup()` expression function** requires a Dataset, doesn't work against `list[dict]` from `runScript`. TypeBadge expression failed because tiers is a list[dict]. Fix: added `nameForTier(tiers, tierId)` helper in `LocationType` module, called via `runScript`. New memory: `feedback_ignition_lookup_dataset_only.md`.
7. **`DefinitionChip` view was rooted at `ia.input.button`** — non-idiomatic, didn't render text. Rebuilt as `ia.container.flex` root with `ia.display.label` child. Folder renamed `DefinitionChip` → `DefinitionItem`; "chip" terminology replaced with "definition" everywhere (function `chipsFromDefinitions` → `definitionItemsFor`, prop `view.custom.chips` → projection removed entirely, meta names `Chips*` → `Definitions*`, message `defChipClick` → `definitionClick`).
8. **Read-side silent failures upgraded to toasts** — all three list functions (`listAll`, `listByType`, `listByDefinition`) now catch exceptions and fire an error toast before returning `[]`. The `definitionClick` message handler also fires warning toasts on null payload + stale-id-not-in-list paths.

**Memory entries added/updated:**

- NEW: `feedback_ignition_nq_resource_schema.md` — v2 schema required, clone shape from Designer-saved file
- NEW: `feedback_ignition_message_scope.md` — view vs page, use page for embedded→parent
- NEW: `feedback_ignition_lookup_dataset_only.md` — Dataset-aware expr fns don't work on list[dict]
- NEW: `project_mpp_bundled_save_pattern.md` — the SaveAll-with-JSON-deltas pattern as project standard
- UPDATED: `project_mpp_toast_system.md` — dismissAt wiring formula
- UPDATED: `feedback_readonly_type_tables.md` — LocationTypeDefinition now CRUDable (LocationType stays read-only)

**Next session pickup:**

1. Open Designer fresh, pull project, double-click each new NQ to confirm none Designer-NPE
2. Open LocationTypeEditor modal via the cog button on Plant Hierarchy
3. Verify tier dropdown populates, definitions repeater renders DefinitionItems, click flow propagates selection to Definition Details + Attribute Definitions panels, Save round-trips through the bundled proc, Deprecate FK-guards on tiers with active Locations
4. Whatever isn't working at that point — fix and iterate

### 2026-05-12 — Internal Docs Portal landed

Built and shipped the v1 internal docs portal — a self-contained static HTML site at `docs_portal/` that consolidates **FDS + Data Model + OIR + ERD** into one browsable, searchable surface for the Blue Ridge team. Internal-only; does NOT replace the `.docx` deliverables to MPP.

**What's in v1:**

- Four pages: `fds.html`, `data-model.html`, `oir.html`, `erd.html` (the ERD is iframed — no rewrite), plus an `index.html` meta-refresh to FDS.
- Shared shell: sticky header nav, sticky TOC sidebar with `IntersectionObserver`-driven active-section highlight, dark theme matching the ERD palette (`#0f1117` bg / `#6c8aff` accent).
- Cross-doc full-text search via **MiniSearch** — section-level granularity (every h2 + h3), ~277 entries, ~470 KB serialized index, lazy-loaded into a modal triggered by `🔍` button or `/` key.
- Six custom markdown-it plugins:
  1. `heading_permalinks` — adds clickable `#` chips on h2/h3/h4, canonicalizes FDS-XX-NNN and OI-XX/UJ-XX heading ids
  2. `anchor_fds_req` — wraps bold-inline `**FDS-XX-NNN**` references in section anchors
  3. `scope_pill` — backticked scope tags (`MVP`, `CONDITIONAL`, etc.) render as colored badges
  4. `cross_doc_link` — bare `FDS-XX-NNN`, `OI-XX`, `UJ-XX`, `Schema.Table`, `(FRS X.Y.Z)` refs in body text auto-link across docs (only for known schema tables, validated against a pre-parsed allowlist)
  5. `oi_badge` — inline 🔓 OI-XX chip on FDS h4 requirements that an open OI references (8 live badges from the 6 open OIs)
  6. `schema_table_anchor` — Data Model only, gives table h3s schema-prefixed slugs (`parts-operationtemplate`) so cross_doc_link's expected anchors actually resolve

**How to rebuild:** `npm run build:portal` (alias for `node tools/build_docs_portal.js`). Idempotent — wipes and rebuilds `docs_portal/`. Test suite: `npm run test:portal` (38 tests across the generator + plugins + smoke tests).

**Spec + plan:** `docs/superpowers/specs/2026-05-12-docs-portal-design.md` (approved 2026-05-12) and `docs/superpowers/plans/2026-05-12-docs-portal.md` (17 tasks, executed via subagent-driven development).

**Three plan deviations corrected during build:**

1. `buildToc` regex strip left scope-pill text in TOC labels — added a span-strip pre-pass. Same issue with permalink `#` chips — added an anchor-strip pre-pass.
2. The FDS source uses `#### FDS-XX-NNN — Title` h4 headings, not `**FDS-XX-NNN**` bold inline (plan got this inverted). Both `heading_permalinks` and `oi_badge` were extended to recognize the h4 form. 8 live OI badges now appear on FDS.
3. The OIR's `### OI-XX — long description` headings were producing slugified ids that didn't match the bare `oir.html#oi-35` hrefs the cross-doc plugins generate. Added OIR-pattern canonicalization to `heading_permalinks` (mirrors the FDS pattern handling).

Each plan correction landed as a small `fix(portal):` commit so the chain is auditable.

### 2026-05-07 — MPP custom Perspective icon library landed

Built and deployed the `mpp` custom Perspective icon library against the lock spec in `mockup/icons.csv`. 34 unique icon sprites (35 logical icons; `cancel` covers both `close` and `reject` from `icons.csv`) at the locked Material Symbols Outlined / wght 300 / grade -25 / fill 0 / opsz 48 axes. Sprite at `ignition/icons/mpp/mpp.svg` (30 KB), companion `config.json` + `resource.json`, and a README at `ignition/icons/README.md` capturing the deploy + recolor recipe.

Three discoveries forced strategy changes from the original design spec, all captured in the README:

- **Ignition 8.3 moved custom icon libraries** from `data/modules/com.inductiveautomation.perspective/icons/<lib>.svg` (8.1) to `data/config/resources/core/com.inductiveautomation.perspective/icons/<lib>/` (8.3), with mandatory `config.json` + `resource.json` siblings. Folder name must equal library name. Gateway service restart needed — Scan File System is unreliable for modified-sprite reloads.
- **Material Symbols' native viewBox `0 -960 960 960` does not render** in 8.3 Perspective. Path data is remapped to viewBox `0 0 24 24` via `transform="translate(0 24) scale(0.025)"` on each path.
- **`fill="currentColor"` on the path doesn't propagate Perspective's color hook.** Perspective wraps each rendered icon in an outer SVG with `style="fill: currentcolor"`; SVG attribute fill on a child path overrides that cascade. Removing the fill attribute entirely lets the Icon component's top-level `color` prop or a Style Class `Text → Color` drive recolor.

Source for the SVGs: `github.com/google/material-design-icons` (the GitHub repo is the only place Google publishes Material Symbols at every variable-font axis combination including `gradN25`; `fonts.gstatic.com` exposes only `wght` and `fill`).

Spec + plan: `docs/superpowers/specs/2026-05-05-ignition-icon-library-design.md` and `docs/superpowers/plans/2026-05-05-ignition-icon-library.md`. Final-state commit: `8303f72`. Durable mechanics also captured in `CLAUDE.md` § Ignition custom Perspective icon library.

### 2026-05-04 — FDS v1.0 customer-review release

Cut FDS v0.11p → **v1.0**, the first customer-review release. Pre-release working-session history (v0.1 through v0.11p) archived in `MPP_MES_FDS_CHANGELOG.docx`; future revisions tracked in the FDS body itself.

- **Feedback-Welcomed callout** added prominently near the front matter, framing v1.0 as the critical-feedback window. Specific areas highlighted: plant-floor workflows (§5–§9), event-data capture, Honda traceability, integration touch points, scope boundary, the 6 remaining open items.
- **In-document Revision History** reset to start at v1.0 with one consolidated entry summarising the 16 sections covered + the 6 remaining open items. Pointer block to the standalone changelog removed.
- **`MPP_MES_FDS_CHANGELOG.md/.docx`** marked archival as of v1.0; standalone artifact retained as the historical record of design evolution but no longer appended to.

### 2026-05-01 — Outstanding Items extract + 9-item closure pass + companion FDS amendments

Built a focused 15-item working extract of the OIR (`MPP_MES_Outstanding_Items.md` / `.docx`) for customer review. Jacques marked it up by adding "Final decision" annotations to 9 items; clarified two follow-ups (per-Operation split flag confirmed as the implemented mechanism; UJ-19 four PD reports remain MVP scope while reports beyond the four = post-deployment change order); approved a four-doc landing pass.

- **OIR v2.17** (companion to this session) — closed OI-07, -24, -25, -27, -28, -29, -30, -31, UJ-03 → all ✅ Resolved with explicit Decision (2026-05-01) blocks. Counts shift: Part A Resolved 22 → 30, In Review 1 → 0, Open 11 → 4 (only OI-32, -33, -34, -35 remain). Part B Resolved 16 → 17, In Review 1 → 0, Open 2 → 2 (UJ-05, UJ-19). Grand total: 54 items, 47 resolved, 0 in review, 6 open, 1 superseded.
- **FDS v0.11p** — **FDS-16-003** amended: cutover-day seeding rule changed from "at or above the Flexware value" to a concrete `<Flexware-current> + 10,000` offset (or MPP-agreed delta). Sample post-offset cutover seeds: `Lot=1,720,932`, `SerializedItem=12,492`. The "Open items (OI-31)" paragraph absorbed into design fact (format carry-forward, no reset policy, ~30+ year rollover horizon). **FDS-12-015 NEW** — `§12.6 Notifications Posture — MVP` establishes banners-only via terminal-context broadcast (FDS-07-006a/b, elevation banners, hold tiles, AIM-pool alarm tiles); text and email notifications are out-of-MVP, future change order. **Embedded Open Items Register reduced** from 14 unresolved items to 6 (OI-33, OI-35, UJ-19 HIGH; OI-34, OI-32, UJ-05 MEDIUM); previously-omitted OI-35 row added.
- **`MPP_MES_Outstanding_Items.md/.docx` v2.0** — refreshed to the 6 remaining Open items only (OI-32, OI-33, OI-34, OI-35, UJ-05, UJ-19). Customer-facing working draft for Phase 0 / architecture-review walk-throughs.
- **No data model / SQL / UJ doc changes this session** — register entries + FDS prose only.
- **Phase 0 Track A items reduced** from 9 to 8 (OI-31 closed; sub-question Ben rollout-shape no longer Phase-0-gating). Active blockers stay: OI-35 architecture gate (HARD) + Phase 0 Customer Validation Workshop.

### 2026-04-30 — Arc 2 Plant Floor mockup + FDS amendments

Substantial day building the operator-facing UI mockup and correcting two FDS sections.

- **`mockup/plantFloor.html` + `mockup/plantFloor.css` + extracted `mockup/styles.css`** — 12 terminal/lot routes covering every operator surface in the Phased Plan v1.0: `home`, `terminal/initials`, `terminal/cell-context`, `terminal/diecast`, `terminal/trim-in`, `terminal/trim-out`, `terminal/machining-in`, `terminal/assembly`, `terminal/assembly-ns`, `terminal/sort-cage` (Serialized + Non-Serialized variants), `terminal/receiving`, `terminal/shipping`, `terminal/end-of-shift`, `lot/detail`. Home Page has plant-hierarchy tree dock + tabbed details panel (Location Details + LOT Search + Genealogy Lookup + Hold Management + Supervisor Dashboard with AIM Pool Wallboard tile). Cross-cutting modals: Elevation, BOM Rename, Idle Re-Confirm, Material Substitute Override, Change Cell Context. Print Failure Banner. Header has elevation toggle (mockup demo affordance), app-title-as-home-link, breadcrumb (terminal routes only), Config Tool nav-out (elevated only). Polymorphism via Flex Repeater + Embedded View. Per-action AD elevation pattern with secondary-color treatment for elevated buttons. 1080p scroll-free with inner-repeater scroll modifiers for high-N entity lists. Touch-friendly (44 px minimum touch targets, 56 px header).
- **FDS v0.11m → v0.11n** (commit `361f6a4`): **FDS-09-013** End-of-Shift Time Entry — selection mechanism corrected to button-toggle on both terminal modes. 3 toggleable buttons (Lunch · 30 min, Break 1 · 15 min, Break 2 · 15 min) tap-to-select / tap-to-deselect. No numeric duration entry. Differences between Dedicated and Shared scoped to identity capture only (Shared adds inline initials field + 3-button single-select Time Category — Regular / Overtime / Double-Time). Zero-button submission valid (operator skipped breaks → no DowntimeEvent rows).
- **FDS v0.11n → v0.11o** (commit `d7f889f`): **FDS-06-014** ByVision row corrected — camera scans the FULL TRAY as a single image, ONE validation event per tray (not per piece). Four-tray container = four passing tray-scan events. Per-tray `ConsumptionEvent` semantics clarified. New OPC tag names: `TrayPresent`, `TrayValidationResult`, `TrayFullFlag`. Same mechanic applies in Sort Cage non-serialized re-pack (uses the same camera).
- **Phased Plan v1.0 implication flagged** — Phase 1's "Terminal Selector" placeholder is structurally a Home Page (plant browser) for elevated desktop users, not a generic Terminal Selector. Mockup proves the model; Phased Plan + FDS will be updated at next pass to match. Companion FDS-02 paragraph also pending.

### 2026-04-29 — Multi-doc reconciliation + scaling-gate tracking + Phased Plan rebuild + DM column add

Five commits over the day landed substantial work.

- **OIR sync + DM column adds** (commit `c7ca780`) — DM v1.9j → v1.9k. `Lots.ShippingLabel.BannerAcknowledgedAt DATETIME2(3) NULL` added (FDS-07-006b broadcast-script Acknowledge action). `CoupledDownstreamCellLocationId` LocationAttributeDefinition seeded under `CNCMachine` (FDS-06-008 auto-move target). OIR v2.14 → v2.15 — OI-33 (AIM pool empty-pool hard-fail customer validation, HIGH) + OI-34 (production schedules leverage, MEDIUM) folded from embedded FDS register into canonical OIR. OIR v2.15 → v2.16 — **OI-35 NEW (HIGH) "MUST DECIDE BEFORE ARC 2 PHASE 1 SQL BUILD"** — long-horizon scaling, retention, archiving strategy.
- **DM v1.9l + UJ v0.9 reconciliation** (commit `3851802`) — comprehensive sweep aligning DM and UJ to FDS v0.11m. DM v1.9k → v1.9l: ContainerConfig `ByVision` reframed as tray-level trigger; "Casting → Trim" subsection retitled "Trim → Machining" with full BOM example rewrite (5G0-TRIM Component + 5G0-MACHINED Sub-Assembly); `Parts.v_EffectiveItemLocation` view documented (Direct ∪ BomDerived per FDS-02-012); deferred event tables (WorkOrderOperation, ConsumptionEvent, RejectEvent, DowntimeEvent) renamed `OperatorId` → `AppUserId`; UJ-14 + UJ-16 PENDING callouts converted to resolved-prose; 5 Arc 2 admonitions stripped; WorkOrderType SQL correction marked landed; Tools cross-references rewritten. UJ v0.8 → v0.9: 4 high-impact scene rewrites — Trim Shop ("Trim is yield loss, not a rename" + "Trim OUT split + route to Machining FIFO"); Machining scene (FIFO pick + BOM rename at IN, PLC-driven auto-move at OUT); 11:30am Assembly tray-level closure with three peer methods + configured-value references; End of Shift FDS-09-013 single-submission rewrite. Assumption status flips: UJ-12, UJ-14, UJ-16, UJ-18 → ✅ Resolved.
- **Phased Plan Plant Floor v0.3 → v1.0 full rebuild + DM v1.9m** (commit `cf11542`) — complete document rebuild. 1825 lines (down from v0.3's 2077). Phase shape preserved (9 phases, 0–8). Cross-Cutting Concerns B1–B17 lifted verbatim with B12 reframed for **Flex Repeater + Embedded View** as the polymorphic primitive. NEW Seeding Registry — Phase Coupling section maps S-01..S-11 to phases. Phase 0 expanded with parallel **Architecture Decision Workshop** track (OI-35). Phase 1 bakes OI-35 architectural decisions into the migration on day one. Phase 3 Die Cast walkthrough corrected for **Shared terminal model**. Phase 4 Trim OUT branches on `Parts.OperationTemplate.RequiresSubLotSplit`. Phase 5 Machining whole rewrite (FIFO pick + BOM rename at IN; PLC-driven auto-complete + auto-move via CoupledDownstreamCellLocationId at OUT; no operator OUT view). Phase 6 Assembly tray-level closure with three peer methods. Phase 7 AIM pool topup loop + tier alarms. Phase 8 FDS-09-013 end-of-shift entry. Migration numbering rebased — Phase 1 lands at `0014`. **DM v1.9l → v1.9m** companion: `Parts.OperationTemplate.RequiresSubLotSplit BIT NOT NULL DEFAULT 0` added.

### 2026-04-28 — FDS continuity + clarity pass + indexing review

FDS lifted from v0.11j → v0.11m across multiple amend-in-place sessions. Major edits:

- §1.4 layer diagram → table; §1.7 FDS-01-007 historian-DB-separation guidance added.
- §2.5 Cell Context Selection (scan **or** dropdown — was scan-only); FDS-02-010 mode-derivation table refreshed (Cell→Dedicated, WC→Shared, Area→Shared); FDS-02-012 expanded with BOM-derived eligibility.
- §3.6 + §6.6 closure granularity corrected to **tray-level** (FDS-03-017 / FDS-06-013 / FDS-06-014 rewritten — `ClosureMethod` extended with `ByVision`).
- §5.10 + FDS-05-033 part-identity rename moved one step downstream from Casting→Trim to **Trim→Machining**; §5.4/§6.3/§6.4 Trim→Machining workflow reframe (sub-LOT split at Trim OUT not Machining IN; Machining OUT auto-completes via PLC and auto-moves to coupled Assembly Cell via new `CoupledDownstreamCellLocationId` LocationAttribute).
- §9.4 end-of-shift time entry (lunch + breaks only, ~15-min header window).
- FDS-07-006b reframed from per-session bound-query to **Gateway-broadcast-with-session-filter** (one DB query per 5s regardless of terminal count).
- Document-wide strip of project-execution decoration (Arc 2 / Phase N / version trailers / "Implementation deferred" admonitions / requirement-deletion tombstones).

**Standalone FDS Change Log doc** — `MPP_MES_FDS_CHANGELOG.md` + `.docx` created. Pre-release pattern: change log lives in companion doc while FDS is in active development; reintegrates into FDS at customer-review release.

**Data model v1.9j** — `Parts.ContainerConfig.ClosureMethod` extended with `ByVision`; UpperCamelCase casing applied; OI-02 caveat retired.

**Indexing & query-perf review** — full report at `Meeting_Notes/2026-04-28_DataModel_Indexing_Scaling_Review.md`. Phase 1–8 already-built schemas have good index coverage; the gap is the **deferred Arc 2 tables** (Lots event tables, Workorder.ConsumptionEvent / RejectEvent, Oee.DowntimeEvent, Quality.HoldEvent) — 14 tables × multiple indexes each need to be pinned in the data model spec before Arc 2 Phase 1 CREATE migrations are written. Three architectural concerns also flagged: 20-year audit retention strategy, `v_LotDerivedQuantities` materialization criteria, recursive-CTE depth limit on `LotGenealogy`. All pre-Arc-2-Phase-1 decisions.

### 2026-04-27 — Integration queue + UJ enrichment + closure batch

- **Integration queue from OIR v2.10 — 7 of 8 landed:** (1) OI-12 MaxParts ✅ `47a4e25`, (2) OI-18 ItemLocation cascade ✅ `0f7f40f`, (3) OI-08 Terminal mode ✅ `7a9d87e`, (4) OI-23 Lot derivations view ✅ `e393b7d`, (5) OI-16 PLC confirm + RequiresCompletionConfirm ✅ `55427f5`, (6) OI-21 Pausable LOT — design locked + landed ✅ `15edd5e`, (7) UJ-04 AIM pool — design locked + landed ✅ `82df891`. (8) OI-13 BOM export moved to seeding registry as S-06.
- **UJ enrichment + closure batch** — 13 UJ entries enriched to OI-style depth in v2.13 (commit `483948e`); Jacques reviewed the docx and closed 10 in v2.14 (commit `a2b58f5`): UJ-07/-08/-11/-13/-14/-16 (Option A defaults), UJ-09 (Option C — strict + supervisor override), UJ-10 (Option D — shift-end summary), UJ-17 (Option A — ConfirmationMethod LocationAttribute), UJ-18 (Gateway-script-async architectural — FDS-01-014 + print-dispatch async pattern + ShippingLabel +5 print-state cols).

### 2026-04-23 / -24 — Arc 2 Model Revisions + corrections

- **Arc 2 Model Revisions (2026-04-23 session)** — 6 commits on 2026-04-23 lifted doc set to Data Model v1.9 / FDS v0.11 / UJ v0.8 / OIR v2.7 / Arc 2 Plan v0.2. Tool/Cavity promoted to `Lots.Lot`; ProductionEvent reshaped to checkpoint form; new `Lots.IdentifierSequence` table; `MaxLotSize` repurposed as `PartsPerBasket`; OI-09 closed (cavity-parallel LOTs as peers); OI-26 deleted; OI-31 opened.
- **2026-04-24 corrections + integrations:**
  - ERD full rebuild — every tab fully current to v1.9; Master tab rebuilt from v1.5 baseline; Audit `bigbigint` typos + OEE column mismatches fixed; Tools cross-schema FKs drawn (commits `2a91da0`, `70d0f37`).
  - Phase 0 + Phase 1 of Arc 2 Plan rewritten in-place (clock# + PIN removed from body, not just overlay) — commit `9121502`.
  - **OI-07 correction** — `WorkOrderType` corrected to single `Production` row; Demand + Maintenance moved to FUTURE hooks; Recipe deleted (commit `ce3e080`).
  - **Storyboards + IPAddresses review** (commit `7550bb8`) — 2012 Flexware docs reviewed against v1.9 design. 83% coverage. Report at `reference/NewInput/REVIEW_2026-04-24.md`. OI-32 Material Allocation + OI-32b Material Classes opened.
  - **OI-31 single-line deployment memo for Ben** — `Meeting_Notes/2026-04-24_OI-31_Single-Line_Deployment_Impact.md`.
  - **Jacques's OIR review batch applied** (commit `6865d8d`, OIR v2.10) — 17 Part A OIs moved Resolved + 2 UJ closures (UJ-02, UJ-04).

### Earlier landmarks

- **Phase G SQL** — All five sub-phases (G.1–G.5) landed by 2026-04-23 (terminal commit `534f55c`). 853/853 tests passing across 20+ test suites at that point.
- **2026-04-20 OI review refactor** — All phases (A/B/C/D/E/F/G) landed.
- **Phase B Tool Management design spec** — Approved 2026-04-21 (commit `47ce9c7`). Full schema spec at `docs/superpowers/specs/2026-04-21-tool-management-design.md` v0.2.
- **Legacy PDF references** — `reference/Manufacturing Director Technical Manual.pdf` (2009 Flexware doc) converted to searchable Markdown at `reference/Manufacturing_Director_Technical_Manual.md` on 2026-04-21. Converter `reference/scripts/convert_mdtm_to_md.js` reusable for future Flexware docs.
- **Seed data extraction** — 876 rows extracted from FRS Appendices B/C/D/E into CSVs in `reference/seed_data/`, plus auto-generated `reference/seed_data.xlsx`. Per-appendix Node.js parsers in `reference/seed_data/parsers/`. Source PDF: `reference/MPP_FRS_Draft.pdf`.
