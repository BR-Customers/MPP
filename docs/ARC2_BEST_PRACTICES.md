# Arc 2 (Plant Floor) — Ignition Best-Practices / View-Hygiene Audit

**Reviewer:** Claude (Opus 4.8) · **Date:** 2026-06-26 · **Branch:** `hunter/explore`
**Method:** Every plant-floor view (incl. popups, nav, keyboard, and Core components the correctness reviews never opened) audited against this project's Ignition gotcha checklist + Core stylesheet class/token coverage. Hygiene only — correctness/FDS live in `ARC2_REVIEW_FINDINGS.md` / `ARC2_FDS_CONFORMANCE.md`. Already-filed `P#-#`/`F#` items are confirmed, not re-filed.

**Verdict:** The views are **structurally sound on the systemic rules** — `bidirectional` inside `config`, input-only embed params + page-scoped child→parent messages, atomic state writes, whole-prop writes, `position.display` for conditional flex, and `ia.input.button onActionPerformed` (no dead container clicks) are all consistently correct across the app. The new hygiene rot is concentrated in **undefined CSS classes/tokens** (will misrender), a few **first-paint undeclared props**, and **two genuine structural defects**.

Severity: 🟠 will misrender / break interaction · 🟡 fragility / convention · 🟢 nit.

---

## ✅ Group 1 fixes applied (2026-06-29) — pending Designer smoke

Highest-leverage quick wins, applied to the working tree (uncommitted). **All undefined-class/token fixes were made in the stylesheet** (file-safe) so no view.json was touched for the sweep; only the two unavoidable structural/root fixes edited views (both never-smoked, file-authored — ASCII-only edits).

- **BP-BRR-1 ✅** — `BulkResultRow/view.json` wrapped under a proper `"root"` + added `props.defaultSize` (64×680). Verified valid JSON, `root.meta.name="root"`, 2 children. Bulk-hold results will now render.
- **Undefined-class/token sweep ✅** — added a clearly-marked compatibility-alias block to `Core/.../stylesheet.css` (braces balanced 382/382): tokens `--bg-panel`→`--mpp-surface-raised` (fixes the **invisible PausedLotIndicator count, BP-B-1**), `--mpp-surface-alt`→`--mpp-surface-card` (**BP-B-4** transparent row badges), `--radius-lg`→`--mpp-radius-lg`; classes `pf-title`/`pf-subtitle`/`pf-section-title`/`pf-empty-hint` (**BP-AS-1..4**), `pf-field-mono` (**BP-DC-6**), `pf-field-col`/`pf-review-panel` (**BP-TR-3/4**), `pf-tool-row` (**BP-B-6**); `pf-primary-button` (**BP-TR-5**) comma-grouped onto `.psc-pf-btn` + `.psc-pf-btn-primary`.
- **BP-1 ✅** — `RegisterOperator/view.json` root class `modal`→`canvas` (un-caps the 480px width so the 800px keyboard fits, matching the InitialsEntry pattern).

**Owed before merge:** (1) `scan.ps1` / gateway resource scan so the stylesheet + views register; (2) Designer reload-from-disk + a **visual smoke** — especially RegisterOperator (canvas root vs the modal-header/footer chrome) and that the alias classes render as intended; (3) long-term, normalize the view references to the canonical class names in Designer and delete the compatibility-alias block. Not addressed (out of confirmed Arc-2 scope): `pf-tile` / `badge-warn` (no confirmed plant-floor reference; `badge-warn` is an Arc-1 quality-spec pill). `pf-primary-button` alias does not carry the `:hover` state (cosmetic).

---

## Must-fix (🟠) — these visibly break

| ID | View | Issue |
|----|------|-------|
| **BP-BRR-1** | `Quality/BulkResultRow/view.json` | **Malformed view — no `root` key.** The root component is hoisted to the view's top level instead of nested under `"root": {…}` (top-level keys are `[custom, params, props, meta, type, children]` vs the correct `[…, root]`). Perspective finds no root component → HoldManagement's **bulk-hold results repeater renders blank rows** (bulk-hold result list non-functional). Hand-author error, never opened in Designer. **Fix:** wrap the component under `"root": {…}` + add `props.defaultSize` (~64px). |
| **BP-B-1** | `PlantFloor/PausedLotIndicator/view.json:148` | Count-chip text uses `color: var(--bg-panel)` — an **undefined** token with no fallback; `color` inherits to the same value as the chip background → **the paused-LOT count number is invisible.** **Fix:** apply the defined `pf-paused-indicator-count` class (uses `--mpp-surface-raised`). |
| **BP-AS-1 / BP-AS-2** | `Views/ShopFloor/AssemblyIn/view.json:96,107` | Header `pf-title` and subtitle `pf-subtitle` are **undefined** in Core stylesheet → the Assembly IN title/subtitle render at default label size. Sibling Assembly views use the defined `pf-terminal-title` / `pf-terminal-title-meta`. **Fix:** swap to the defined classes. |
| **BP-1** | `Popups/RegisterOperator/view.json:40` | Root applies `.psc-modal` (hardcodes `width:480px` + `overflow:hidden`) but embeds an **800px on-screen Keyboard (defaultSize 880)** → the keyboard is **clipped to 480px.** InitialsEntry correctly uses a `canvas` root sized to 880. **Fix:** use a `canvas`/wide root (not the 480 `modal`) for keyboard-bearing popups. |

---

## Undefined classes / tokens sweep (Rule K)

These are referenced by views but have **no definition** in `Core/.../stylesheet.css` → unstyled/invisible render. A single token/class pass fixes them all (extends the earlier A2 note: `pf-tile`, `badge-warn`):

| Referenced | Where | Suggested fix |
|---|---|---|
| `--bg-panel` | PausedLotIndicator:148 (🟠 invisible count) | `--mpp-surface-raised` (or class `pf-paused-indicator-count`) |
| `--mpp-surface-alt` | ParentRow:117, ChildRow:117, HistoryRow:104, NodeRow:153 (4 badges transparent) | `--mpp-surface-card` / `--mpp-neutral-40` |
| `--radius-lg` | PausedLotIndicator:37 | `--mpp-radius-lg` |
| `pf-title`, `pf-subtitle` | AssemblyIn:96,107 (🟠) | `pf-terminal-title`, `pf-terminal-title-meta` |
| `pf-section-title`, `pf-empty-hint` | AssemblyIn:335,404 | existing title class / `pf-kpi-sub` |
| `pf-field-mono` | PeerTallyRow:64 | `pf-field-input-mono` / `pf-kpi-value-mono` |
| `pf-field-col`, `pf-review-panel`, `pf-primary-button` | MovementScan:46,149,314 | `pf-panel`; `pf-btn pf-btn-primary` |
| `pf-tool-row` | LotDetail:528,602 (harmless — display gated) | remove or define |
| `pf-tile`, `badge-warn` | (earlier A2) | define or remove |

---

## Per-cluster findings (new items; confirmations noted inline)

### Cluster A — Die Cast / Trim / Machining / Assembly / Receiving + sub-views
- **BP-DC-5 🟡 (structural / correction)** — `DieCastEntry/CheckpointPanel` is **orphaned: no view embeds it** project-wide (TrimBody has only a `TODO(phase4)` comment, not an embed). **This corrects `P3-4`/`P3-1`** — the `dcValues` JSON-shape bug and the missing-checkpoint claim are *not reachable via TrimBody*; CheckpointPanel's plumbing runs nowhere. Either wire it in or remove it.
- **BP-DC-2 / BP-DC-4 🟡 (L)** — DieCastBody `PeerRepeater:1021` and CheckpointPanel `FieldsRepeater:223` use the flagged `useDefaultViewHeight:false`+`basis:"auto"` combo → rows stretch instead of sizing. Set `true` + pixel basis.
- **BP-DC-6 / BP-TR-3/4/5 / BP-AS-3/4 🟡 (K)** — undefined classes (see sweep).
- **BP-DC-1 / BP-TR-1 🟡 (P)** — DieCastShared/TrimShared cell dropdowns say "Scan or pick" but are pick-only (no `allowCustomOptions` + id-only `findCellById`) → scanned codes silently no-op (root of P4-4).
- **BP-TR-2 🟡 (A)** — TrimBody `custom.destCells` is binding-only, not seeded `[]` in the `custom` block (siblings seed it).
- Confirmed systemic (not re-filed): P3-6/P5-5/P6-4 under-shaped bound props.
- **Clean:** DieCastDedicated, TrimDedicated, RejectPanel, FieldInputRow, MachiningOutSplit, QueueRow, ReceivingDock, AssemblySerialized/NonSerialized, ScanQueueRow. Rules B/C/D/E/F/G/H/I/O pass cluster-wide.

### Cluster B — LotSearch / LotDetail / GenealogyViewer + sub-views
- **BP-B-1 🟠 (K)** — PausedLotIndicator count invisible (above).
- **BP-B-4 🟡 (K)** — 4 relationship/event/direction badges use undefined `--mpp-surface-alt` → transparent (ParentRow/ChildRow/HistoryRow/NodeRow).
- **BP-B-3 🟡 (O)** — PausedLotIndicator:14 `params.locationId` onChange calls `self.view.rootContainer.load()` (wrong scope — `self` IS the view in a view-param onChange; convention is `self.rootContainer.load()`) → throws; masked by onStartup + `pausedLotResumed` covering the real refresh paths.
- **BP-B-2 / BP-B-5 / BP-B-6 🟢** — undefined `--radius-lg`; hardcoded hex instead of tokens; dead `pf-tool-row` ref.
- Confirmed: P2-1 (dead genealogy clicks — no new instances found), P2-2 (StatusPill value mismatch), P2-3, P2-9 (extends to GenealogyViewer `AncestorsRepeater:496`/`DescendantsRepeater:669`).
- **Clean:** LotSearch (fully); structure/resource.json/root-name/no-DnD all pass.

### Cluster C — HoldManagement / ShippingDock / SortCageWorkflow / AimPoolConfig + components
- **BP-BRR-1 🟠 (J)** — BulkResultRow malformed, no `root` (above).
- **BP-HR-2 🟡 (J)** — HoldRow carries 7 orphan copy-paste `paramDirection:"input"` decls (5 unused; same template debris behind P7-6).
- **BP-HM-1 🟡 (L)** — HoldManagement OpenLots/OpenContainers/Bulk repeaters set basis (76/64px) without `useDefaultViewHeight:true` while HoldRow is 92px → content clips.
- **BP-HM-2/3/4 🟢** — `openHolds` not pre-declared (top-level read, low risk); stale subtitle; lone em-dash.
- Confirmed: P7-6 (HoldRow Use disabled), P7-9 (AimPoolConfig.cfg), P7-10 (AimPoolTile run-once), P7-11 (banner not terminal-filtered).
- **Clean (hygiene):** ShippingDock, SortCage, AimPoolTile structure, PrintFailureBanner structure. Rule K **passes** this cluster (all classes defined); rule M N/A.

### Cluster D — Downtime / EndOfShift / ShiftEndSummary / SupervisorDashboard / HomeRouter / TerminalSelector
- **BP-D-6 🟡 (E)** — SupervisorDashboard `openSummary:7` runScript is **run-once (no poll/token)** → the two real tiles (Open Downtime, Classified) freeze; supervisor sees a stale snapshot. Add a `now(30000)` arg.
- **BP-D-4 🟡 (A)** — EndOfShiftEntry `custom.shift` read via nested path but undeclared **and** source `Shift.getOpen()` returns **None** on empty → first-paint bad-quality / `"null"` flash (the StateBadge incident class). Use a `getOpenOrEmpty` shaped return + pre-declare.
- **BP-D-8 🟡 (G)** — DowntimeEntry `EventRow` AssignButton toggles `meta.visible` with `basis:120px shrink:0` → reserves a 120px gap when hidden. Use `position.display`.
- **BP-D-1/D-5 🟡 (A)** — DowntimeEntry `rows` / ShiftEndSummary `summary` undeclared (confirms P8-10); **BP-D-2 🟠** confirms P8-1 (downtime list never refreshes); **BP-D-3/D-7/D-9 🟢** nits.
- **Clean:** HomeRouter (route() attribute-access safe), TerminalSelector (onSelectionChange + onBlur-scan = house convention), BreakToggle, SummaryRow. Rule K **passes** (zero undefined classes/vars). P8-11 stub tiles are correct display-only.

### Cluster E — Popups + cross-cutting + Core
- **BP-1 🟠 (K)** — RegisterOperator keyboard clipped (above).
- **BP-2 🟡 (K)** — PausedLotList root `.psc-modal` (480) vs defaultSize 720 / 680px rows → dead band + compressed rows. Use a `modal-lg` (720) variant.
- **BP-5 🟡 (logic)** — PresenceIdleWatcher `modalOpen` latches `True` on the IdleReconfirm **"change operator"** path (reset only fires on "continue") → the 30-min idle re-prompt never fires again for that session. Reset on the change path too.
- **BP-6 🟡 (guard)** — InitialsField onStartup reads `session.custom.presence.policy` unguarded (folds into systemic F5).
- **BP-3/BP-4/BP-7 🟢** — PausedLotList hardcodes a close id (no `popupId` param); PausedLotRow nested under the PausedLotList view folder (only convention-violating nesting in the project); Toast `dismissAt`/`shouldClose` not pre-declared (benign).
- **Rule M (popup overflow) — cluster PASS:** the modal-family popups use `modal-header`/`modal-footer` with `basis:"auto"` (not the flagged fixed 50px) and `.psc-modal` sets `overflow:hidden`. The repeatedly-flagged scrollbar-over-buttons bug does **not** recur.
- **Clean:** InitialsEntry (uncommitted diff = reserialization, logic-neutral — F8), UnknownInitials, ConfirmCreateLot, BomRenameConfirm, MaterialOverrideConfirm, ElevationModal, CellContextSelector (hygiene-clean; dead per F6), Keyboard/_Keyboard/Key, NotifyHost, Toast.

---

## Corrections to prior findings
- **P3-4 / P3-1 reachability** — `CheckpointPanel` is **orphaned** (BP-DC-5): no view embeds it, so the `dcValues` JSON-shape bug (P3-4) and the "missing die-cast checkpoint" (P3-1) are *latent in dead code*, not live via TrimBody as Area 3 stated. Still fix before wiring CheckpointPanel in, but they are not currently reachable.

## Highest-leverage fixes
1. **`BulkResultRow` `root` wrapper** (BP-BRR-1) — makes bulk-hold results render.
2. **Undefined class/token sweep** (the table above) — one pass clears ~12 misrenders incl. the invisible paused count (BP-B-1) and unstyled Assembly header (BP-AS-1/2).
3. **RegisterOperator width** (BP-1) — un-clip the keyboard.
4. **Run-once/refresh-token + first-paint shaped props** (BP-D-6, BP-D-4, P8-1) — live tiles + clean first paint.
5. **PresenceIdleWatcher latch** (BP-5) — restores idle re-prompt after an operator change.
