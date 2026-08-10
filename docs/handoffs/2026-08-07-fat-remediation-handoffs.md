# FAT remediation handoffs — 2026-08-07

Paste-ready kickoff briefs for the **GO** specs from `notes/2026-08-07_fat-failure-remediation-brief.md`.
Each brief is self-contained: an agent reads it + the referenced files and runs the **full
brainstorm → spec → plan → build → verify** cycle itself. Source triage + evidence:
`notes/2026-08-07_fat-failure-remediation-brief.md`; live FAT record:
`docs/fat/MPP_MES_FAT_practice.xlsx`.

GO set: **A** operation-template lifecycle · **C** machining reject capture · **D** label/print
subsystem · **E** deprecated-initials · **F** held-LOT scrap + container alert.
(HELD/closed: B validation-only, G, H — do not spec.)

---

## Shared-environment rules — apply to EVERY brief (read first)

There is **one** working tree, **one** symlinked Ignition gateway, and **one** dev DB. Multiple
agents share them. A prior round **lost work** by ignoring these — do not repeat it:

- **Work on `jacques/working`. Do NOT `git checkout` any other branch** — a checkout rewrites
  every file in the shared tree and reverts other agents' in-flight work. Commit directly to
  `jacques/working`. No feature branches, no worktrees for these tasks.
- **Stage explicit paths only** (`git add <path>`), NEVER `git add -A`/`-u` — the tree holds other
  agents' uncommitted files. Run `git status` before committing and never sweep up files you did
  not create. No `Co-Authored-By` trailer.
- **Edit disjoint files.** Each brief lists its files. If two briefs touch the same proc/view, run
  them **sequentially**, not in parallel.
- **Ignition view + `scan.ps1` is single-lane.** Only ONE agent edits `view.json` + runs
  `.\scan.ps1` at a time. New SQL/NQ/Python are always safe to write in parallel; existing
  `view.json` file-edits are safe ONLY while Designer is closed (else its cache races the disk).
  Run `.\scan.ps1` after any Ignition resource change (memory `feedback_ignition_gateway_scan`).
- **DB validation:** use a uniquely-named throwaway DB (e.g. `MPP_MES_<Feature>`) via the reset
  flow in `sql_version_control_guide.md`. NEVER reset `MPP_MES_Dev`. Coordinate `MPP_MES_Test`.
- **Migration numbers are PRE-ASSIGNED** to avoid collision: **A → `0053`**, **D → `0054`**.
  C/E/F need no new versioned migration (repeatable procs only). Confirm your number isn't taken
  (`ls sql/migrations/versioned/`) before applying; if taken, take the next free and note it.
- **Follow `CLAUDE.md`** — especially: FDS-11-011 (no OUTPUT params; mutation procs end with the
  `SELECT @Status,@Message,@NewId`; status-row NQ `type:"Query"`); INSERT-EXEC / Msg-3915 rule
  (validations before `BEGIN TRANSACTION`; don't nest INSERT-EXEC); audit Description convention
  (`<SUBJECT> · <CATEGORY> · <ACTION>`, resolved-name FK JSON); **no business logic in Python**
  (domain rules in SQL); ASCII-only seeds/ZPL; the Ignition file-edit boundary.
- **Process skills:** run `superpowers:brainstorming` first (write the spec to
  `docs/superpowers/specs/2026-08-07-<topic>-design.md`, get it reviewed), then
  `superpowers:writing-plans`, then `superpowers:test-driven-development` for the build, then
  `superpowers:requesting-code-review` before declaring done. Read on-demand from
  `ignition-context-pack/*` per the task.

**Parallelism:** the SQL/NQ/Python backends of A, C, E, F can proceed in parallel; **D is the
heaviest** and its own lane. The **view.json edits of A, C, D, F must be serialized** (single-lane
scan). E has no view work. Recommended order if serializing end-to-end: **E → A → C → F → D**.

---

## Brief A — Operation Template Draft/Published lifecycle (FAT-OQ-030)

> **STATUS: ✅ DONE** (2026-08-07, session 31dc0442). Migration 0053 + Publish/DiscardDraft
> procs + resolver gate + editor Publish button/badges; 91/91 tests green; deployed to
> MPP_MES_Dev; FAT-OQ-030 marked Pass. Commits 088e5064 (spec), f9849a8f (backend),
> 2be9cc18 (view), + code-review fixes.

**Mission:** give `Parts.OperationTemplate` the same three-state Draft/Published/Deprecated
lifecycle `RouteTemplate` and `Bom` already have, so "New Version" produces an editable Draft that
only goes live on Publish. Closes FAT-OQ-030.

**Acceptance (FAT wording):** creating a new template version follows the
Draft/Published/Deprecated lifecycle; the prior version is retained.

**Current state (evidence):** `Parts.OperationTemplate` has only `VersionNumber` + `DeprecatedAt`
— it never got the `0007_bom_and_route_publish.sql:48-61` publish retrofit.
`R__Parts_OperationTemplate_CreateNewVersion.sql:93-106` clones to `Version+1` **immediately live**.
No `_Publish` proc/NQ; the editor `MPP_Config/.../BlueRidge/Views/Parts/OperationTemplates/view.json`
has no Publish button/badge. Entity `Core/.../BlueRidge/Parts/OperationTemplate/code.py`
`getVersionsForCode` computes "active" as highest non-deprecated version — no Published gate.

**Approved design (mirror the RouteTemplate pattern exactly):**
1. Migration `0053`: `ALTER TABLE Parts.OperationTemplate ADD PublishedAt DATETIME2(3) NULL;`
   **backfill existing non-deprecated rows `PublishedAt = CreatedAt`** (so current routes keep
   resolving). Mirror `0007:48-49`.
2. New `Parts.OperationTemplate_Publish` proc — clone `R__Parts_RouteTemplate_Publish.sql`; audited
   per ConfigLog convention. Optional `_DiscardDraft` (clone `R__Parts_RouteTemplate_DiscardDraft.sql`).
3. `OperationTemplate_CreateNewVersion` leaves the clone a Draft (`PublishedAt` NULL); prior
   published version stays active until publish.
4. `Get`/`List` surface `PublishedAt`; the resolver NQ
   `parts/OperationTemplate_GetForRouteRole` **and** the entity `getVersionsForCode` gate "active"
   on `PublishedAt IS NOT NULL` — a Draft must never resolve into execution.
5. Editor: Publish button + Draft/Published state badge (mirror the RouteTemplate editor);
   `OperationTemplate.publish(id)` entity method + `parts/OperationTemplate_Publish` NQ
   (`type:"Query"`, status-row shape).
6. Extend `sql/tests/0009_Parts_Process/010_OperationTemplate_crud.sql`: Draft→Publish→new-Draft-
   version→prior-retained-and-still-active; resolver ignores a Draft.

**OUT OF SCOPE (do not touch):** the `Parts.ufn_OperationTemplateForLotRole` resolver convergence
and the two Assembly latent bugs (AssemblyIn no checkpoint / AssemblyOut no template) — separate
PROJECT_STATUS TODO. Keep this Config-side only.

**Files:** migration `0053`; repeatables `R__Parts_OperationTemplate_{Publish,CreateNewVersion,
Get,List}.sql` (+ optional `_DiscardDraft`); NQ `parts/OperationTemplate_{Publish,GetForRouteRole,
Get,List}`; entity `Parts/OperationTemplate/code.py`; view `Parts/OperationTemplates/view.json`;
test `010_OperationTemplate_crud.sql`.

> **Launch prompt:** "Implement FAT-OQ-030 (Operation Template Draft/Published lifecycle) per
> `docs/handoffs/2026-08-07-fat-remediation-handoffs.md` § Brief A and the design in
> `notes/2026-08-07_fat-failure-remediation-brief.md` § Spec A. Read CLAUDE.md, the Shared-
> environment rules at the top of the handoff doc, `ignition-context-pack/07` + `04`, and the
> RouteTemplate publish reference impls. Run brainstorming → write the spec to
> `docs/superpowers/specs/2026-08-07-operation-template-publish-lifecycle-design.md` → writing-plans
> → TDD build → requesting-code-review → `.\scan.ps1`. Stay on `jacques/working`, explicit staging,
> migration `0053`."

---

## Brief C — Machining defect/reject capture (FAT-MACH-140)

> **STATUS: ✅ DONE** (2026-08-07, session 4c520a18). Backend + NQ + entity + view shipped;
> tests `080_MachiningOut_Mint_scrap.sql` green (41 asserts incl. 3 code-review edge cases);
> full SQL suite 2427/0; `.\scan.ps1` run; code-review passed. Fixture note: uses
> `12270-6NA`/`MA1-FP6NA-MOUT` — the `5G0-c`/`MA1-5GOF-MOUT` fixture is orphaned (that line
> was dropped from the location seed), which independently leaves `070_MachiningOut_Mint.sql`
> and `100_Lot_GetLineInventoryByPart.sql` red — **pre-existing, not this change**. FAT row
> ready for operator re-test (workbook not edited — it has concurrent uncommitted changes).

**Mission:** port the shipped Trim OUT multi-reason scrap feature onto Machining OUT so entering
defect codes + reject quantities writes one `Workorder.RejectEvent` per code. Closes FAT-MACH-140.

**Acceptance:** operator enters ≥1 defect code with reject qty and submits → a `RejectEvent` row per
defect code used.

**Current state:** Machining captures **zero** defect data. `R__Workorder_MachiningOut_Mint.sql`
and `R__Workorder_MachiningIn_RecordPick.sql` write no rejects; no Machining ShopFloor view has a
scrap surface.

**Reference impl to mirror (Trim OUT, shipped last week):**
- Proc: `R__Workorder_TrimOut_Record.sql:106-157` (pre-txn ISJSON + OPENJSON shred + qty>0 +
  active-DefectCode validations) and `:351-355` (inline `INSERT … Workorder.RejectEvent … SELECT …
  FROM @Scrap`, `ProductionEventId` NULL, LOT decremented **once** by the scrap total).
- NQ `workorder/TrimOut_Record/query.sql` (`@ScrapLinesJson`); entity `Workorder/TrimOut/code.py:29`
  (`convertWrapperObjectToJson(scrapLines)`); UI `Components/PlantFloor/TrimEntry/ScrapLineRow`
  + `Views/ShopFloor/TrimBody/view.json:900-1210` (repeater + `addScrapLine`/`recomputeGood`/
  handlers) with dropdown bound `getForDropdown("TrimOut")`.

**Approved design:**
1. Add `@ScrapLinesJson NVARCHAR(MAX)=NULL` to `MachiningOut_Mint` + the pre-txn validations +
   inline RejectEvent fan-out. **Do NOT call the shared `RejectEvent_Record`** (double-decrement +
   nested INSERT-EXEC / Msg-3915) — inline it like Trim.
2. Add `:scrapLinesJson` to `workorder/MachiningOut_Mint/query.sql`.
3. `BlueRidge.Workorder.Machining.mint` JSON-encodes `scrapLines` (mirror `TrimOut/code.py:29`).
4. `Views/ShopFloor/MachiningOutSplit/view.json`: `scrapLines`/`defectOptions` custom props,
   dropdown bound `getForDropdown("MachiningOut")` (resolves `MachiningAssembly` category +
   plant-wide), flex-repeater + the 4 handler methods — direct port of TrimBody. Reuse or clone
   `ScrapLineRow` (only the page-message type strings differ).
5. Tests under `sql/tests/0027_PlantFloor_Machining/` mirroring
   `sql/tests/0024_*/050_TrimOut_Record_validation.sql` (N lines→N RejectEvents; invalid/deprecated
   defect → Status 0; non-positive qty → Status 0; empty JSON → zero rejects).

**Decisions (made — implement, don't re-litigate):** scrap charges to the **source casting LOT**
(the LOT being decremented); `ProductionEventId = NULL`. Matches Trim + die-cast.

**Files:** `R__Workorder_MachiningOut_Mint.sql`; NQ `workorder/MachiningOut_Mint`; entity
`Workorder/Machining/code.py`; view `MachiningOutSplit/view.json` (+ maybe a
`MachiningEntry/ScrapLineRow`); tests in `0027_PlantFloor_Machining/`.

> **Launch prompt:** "Implement FAT-MACH-140 (machining reject capture) per
> `docs/handoffs/2026-08-07-fat-remediation-handoffs.md` § Brief C and
> `notes/2026-08-07_fat-failure-remediation-brief.md` § Spec C — a mechanical port of the Trim OUT
> scrap feature onto Machining OUT. Read CLAUDE.md + the Shared-environment rules + the Trim
> reference files. brainstorming → spec `docs/superpowers/specs/2026-08-07-machining-reject-capture-design.md`
> → writing-plans → TDD → code-review → `.\scan.ps1`. `jacques/working`, explicit staging, inline
> the RejectEvent write (never call `RejectEvent_Record`)."

---

## Brief D — Label/print reliability & Honda shipping-label content (ENV-170, LBL-050/060/150)

> **STATUS: 🟡 IN PROGRESS** (claimed 2026-08-07, session b11af470). Do not double-assign.

**Mission (one subsystem, one spec):** make the shipping label template-driven + Honda-complete,
persist rendered ZPL, and move print dispatch to Gateway-async with a real failure lifecycle.
Closes ENV-170, LBL-050, LBL-060, LBL-150. **Heaviest brief — its own lane.**

**Current state:** LTT labels are already DB-template-driven (`Lots.LabelTemplate.ZplBody` with
`{Placeholder}` tokens, resolved by `R__Lots_LotLabel_Print.sql:132`, table
`0021_arc2_phase2_lot_lifecycle.sql:183-195`). The **shipping label is hardcoded** —
`Core/.../BlueRidge/Lots/ShippingDispatcher/code.py:30-34` `_renderZpl` emits a minimal label
(AIM Shipper barcode only). Dispatch is **synchronous raw-TCP** single-retry
(`LotLabel/code.py:148-171`); `PrintFailureGateway.sweepTick/broadcastTick` are **skeleton no-ops**
(`PrintFailureGateway/code.py:18-29`). `Lots.ShippingLabel` (`0028_arc2_phase6_assembly.sql:109-131`)
has no `ZplContent` column.

**Approved design:**
1. **Migration `0054`:** `ALTER TABLE Lots.ShippingLabel ADD ZplContent NVARCHAR(MAX) NULL;` + seed
   a shipping `LabelTemplate` row (a shipping `LabelTypeCode`) with `{Placeholder}` tokens.
2. **Bring the shipping label onto the `LabelTemplate` pattern** — render via placeholders resolved
   in a proc (mirror `LotLabel_Print`), not hardcoded Python. Persist the rendered payload into
   `ShippingLabel.ZplContent` at dispatch.
3. **Honda field mapping (from Jacques), as `{Placeholder}` tokens:** part number ←
   `Item.PartNumber` (config; matches AIM part) · description ← `Item.Description` · DC part level ←
   **die rank** · MFG lot number ← **AIM minted serial** · bottom serial field ← **first 8 digits
   UNKNOWN + last 8 = AIM serial**.
4. **Async dispatch:** move `ShippingDispatcher.dispatch` + `LotLabel.printLabel` to the Gateway-
   async pattern already used for AIM, 3 attempts w/ ~2s backoff, mark `PrintFailedAt`, implement
   `PrintFailureGateway` sweep + terminal banner. Reuse the AIM `Audit.InterfaceLog` +
   async-dispatch idiom (FDS-01-014).
5. Tests for the render (token resolution, ASCII-only ZPL) + the retry/failure path.

**INVESTIGATIONS the agent MUST resolve in the spec (do not guess into the build):**
- The **bottom-serial composition** — what are the first 8 digits? (Inspect the AIM interface
  contract `reference/…AIM…` + any label templates in `reference/`; if undeterminable, **escalate to
  Jacques** before finalizing the ZPL — do not ship a wrong Honda label.)
- Confirm the **die-rank → "DC part level"** mapping.

**Guardrails:** ASCII-only ZPL (memory `feedback_ascii_only_seed_data`). Async from gateway scope
needs explicit session/page targeting (memory `feedback_ignition_gateway_sendmessage_needs_session_page`).

**Files:** migration `0054`; `Lots/ShippingDispatcher/code.py`, `Lots/LotLabel/code.py`,
`Lots/PrintFailureGateway/code.py`; a shipping-label render proc + NQ; the LabelTemplate seed;
shipping/print views (`ShippingDock` etc.) for the banner; tests.

> **Launch prompt:** "Implement the label/print subsystem (ENV-170, LBL-050/060/150) per
> `docs/handoffs/2026-08-07-fat-remediation-handoffs.md` § Brief D and
> `notes/2026-08-07_fat-failure-remediation-brief.md` § Spec D. Read CLAUDE.md + Shared-environment
> rules + the LotLabel/LabelTemplate reference + the AIM async-dispatch code. FIRST resolve the two
> investigations (bottom-serial composition; die-rank→DC-level) — escalate to Jacques if the serial
> format is undeterminable. brainstorming → spec
> `docs/superpowers/specs/2026-08-07-label-print-subsystem-design.md` → writing-plans → TDD →
> code-review → `.\scan.ps1`. `jacques/working`, explicit staging, migration `0054`, ASCII-only ZPL."

---

## Brief E — Deprecated initials blocked at presence sign-in (FAT-USR-090)

> **STATUS: ✅ DONE** (2026-08-07, session 0170f14a). Impl commit `6c04952`; spec
> `docs/superpowers/specs/2026-08-07-deprecated-initials-presence-design.md`; tests green (045);
> code-review clean. FAT-USR-090 marked Pass in the practice workbook (uncommitted — shared binary,
> left for Jacques to commit alongside other agents' FAT updates).

**Mission:** reject **deprecated** operator initials at presence sign-in (unknown ones already are).
Closes FAT-USR-090. Small but genealogy-critical (Honda attribution).

**Current state:** `R__Location_AppUser_GetByInitials.sql:36-45` returns deprecated rows unfiltered
(documented); `Core/.../BlueRidge/Location/AppUser/code.py:169-179` `resolveForPresence` marks any
found row `valid=True` with no `DeprecatedAt` check.

**Approved design:** filter `DeprecatedAt IS NULL` in the **presence-resolution path**, in SQL
(business rules in SQL, not Python). **Verify first** whether `AppUser_GetByInitials` has other
callers that legitimately need deprecated rows (e.g. attribution-history reads) — if so, do NOT
change the shared proc's behavior globally; instead add a presence-eligibility gate (a param, or a
dedicated presence resolver) so historical attribution reads still resolve deprecated users while
**new** presence sign-in rejects them. Add a test asserting a deprecated initial → not valid, an
active initial → valid, and (if applicable) history reads still resolve deprecated users.

**Files:** `R__Location_AppUser_GetByInitials.sql` (or a new presence resolver); possibly
`AppUser/code.py` (thin glue only); a test under the AppUser/presence test folder. **No view work.**

> **Launch prompt:** "Implement FAT-USR-090 (block deprecated initials at presence sign-in) per
> `docs/handoffs/2026-08-07-fat-remediation-handoffs.md` § Brief E. Read CLAUDE.md + Shared-
> environment rules. First check all callers of `AppUser_GetByInitials` so you don't break
> attribution-history reads — gate presence eligibility in SQL, keep history reads intact.
> brainstorming → spec `docs/superpowers/specs/2026-08-07-deprecated-initials-presence-design.md` →
> writing-plans → TDD → code-review. `jacques/working`, explicit staging, no view edits."

---

## Brief F — Scrap against a held LOT + container-hold alert (FAT-QH-150, FAT-QH-170)

> **STATUS: ✅ DONE** (impl session ab13b4e8; verification session 31dc0442, 2026-08-07). Backend +
> view + tests landed on `jacques/working` (commits `32f6a826` spec, `8adfb4a0` backend, `1a04b580`
> view, `0f0a5f10` review-fixes); SQL suite green (Brief-F suite 83/83, incl. QH-150 scrap-in-place
> + QH-170 associated-containers); code-review passed. **Verified 2026-08-07 after the Perspective
> trial was reset:** HoldManagement renders both new panels (Scrap Held LOT + Associated-containers
> advisory) with no view errors; procs deployed to `MPP_MES_Dev`. FAT-QH-150 + FAT-QH-170 marked
> Pass in the practice workbook (uncommitted shared binary). Caveat: the operator-*typed* UI submit
> is backed by the automated proc-path tests, not a live keystroke witness — the browser tool can't
> commit Perspective form inputs; a ~60s human spot-check is recommended.

**Mission:** let an operator register a **scrap event directly against a held LOT** (no split, no
hold release), and surface an **associated-container advisory** when a LOT is held. Closes
FAT-QH-150 and FAT-QH-170.

**Acceptance / direction (per Jacques — overrides FRS/FDS on QH-150):** do NOT split the held LOT.
Register scrap against it the **same way scrap is recorded elsewhere** (a `RejectEvent` + qty
decrement). QH-170: holding a LOT alerts about associated containers (FDS-08-007 SHOULD).

**Current state:** `R__Lots_Lot_Split.sql:238-250` rejects splitting a held (`BlocksProduction=1`)
LOT; `Lot_UpdateStatus` allows only Good→Closed. The blocked-state guard is `Lot_AssertNotBlocked`.
`R__Quality_Hold_Place.sql` does no container-association lookup; the HoldManagement view shows no
container notice.

**Approved design:**
- **QH-150:** permit the scrap path through the hold guard so a `RejectEvent`-style scrap can be
  recorded against a `BlocksProduction=1` LOT, decrementing the LOT qty as recorded scrap does
  elsewhere. Decide in the spec whether this reuses the shared `RejectEvent_Record`
  (`R__Workorder_RejectEvent_Record.sql`) — legitimate here since it's a **standalone** scrap
  against one LOT, not nested inside a split/INSERT-EXEC — or an inlined write; follow the
  INSERT-EXEC / Msg-3915 rule either way. Surface the scrap action on the hold/LOT-detail surface.
- **QH-170:** on `Hold_Place`, look up associated containers and return an advisory the
  HoldManagement view renders (advisory only; SHOULD-level).

**Guardrail:** this deliberately relaxes the hold invariant for scrap only — scope the exception
tightly (scrap/RejectEvent path only; holds still block production moves/checkouts). Document the
FRS/FDS override in the spec.

**Files:** the scrap-against-held path (`Lot_AssertNotBlocked` usage / a scrap proc / possibly
`RejectEvent_Record`); `R__Quality_Hold_Place.sql`; the HoldManagement view + LOT-detail scrap
affordance; tests.

> **Launch prompt:** "Implement FAT-QH-150 + FAT-QH-170 per
> `docs/handoffs/2026-08-07-fat-remediation-handoffs.md` § Brief F and
> `notes/2026-08-07_fat-failure-remediation-brief.md` § Spec F. Direction (Jacques, overrides
> FRS/FDS): register scrap directly against a held LOT (RejectEvent + decrement, no split, no hold
> release) + a container advisory on hold-place. Read CLAUDE.md + Shared-environment rules.
> brainstorming → spec `docs/superpowers/specs/2026-08-07-held-lot-scrap-and-container-alert-design.md`
> → writing-plans → TDD → code-review → `.\scan.ps1`. `jacques/working`, explicit staging; scope the
> hold-guard exception to the scrap path only."

---

## Definition of done (every brief)

Spec committed under `docs/superpowers/specs/`; plan followed; implementation on `jacques/working`
with explicit-path commits (no `-A`); tests green (TDD, run via the project test harness);
`.\scan.ps1` run for any Ignition change; `superpowers:requesting-code-review` passed; the FAT
row(s) re-testable — update the FAT workbook Result to Pass with evidence once verified, or report
what blocks it. Report back what landed + any escalations (esp. Brief D's serial-format question).
