# Arc 2 (Plant Floor) — Review Findings

**Reviewer:** Claude (Opus 4.8) · **Started:** 2026-06-26 · **Branch:** `hunter/explore`
**Scope:** Full stack (Perspective views → entity scripts → Named Queries → procs/migrations/seeds).
**Method:** Review against **FDS v1.4** + the actual code (the Plant-Floor Plan v1.3 and User Journeys v0.9 lag the code on the terminal-mode model — code/FDS are authoritative).

Severity legend: 🔴 High (breaks runtime / data integrity) · 🟠 Medium (functional gap / FDS divergence) · 🟡 Low (fragility / maintainability) · 🟢 Info / verify.

---

## Executive Summary

**Overall posture.** Arc 2 is broadly built across Phases 1–8, and the **SQL/proc layer is a genuine strength** — atomicity, FIFO locking, INSERT-EXEC inlining discipline, single-result-set/no-OUTPUT contract, and NQ `type:"Query"` correctness are consistently right across every phase reviewed. Risk concentrates in two places: (1) the **Perspective views were file-authored without a live Designer session ("never smoked")**, so they carry a recurring class of first-paint/wiring bugs; and (2) **two areas are not actually built** despite being in MVP scope.

**Build-completeness gaps (verify scope intent):**
- **Phase 9 — essentially unbuilt** (Area 9): inspection capture, CRT lifecycle, and the Global Trace tool / Honda genealogy export are all missing. These are ratified MVP (plan v1.3). 🔴
- **Serialized-assembly MIP per-part path — unbuilt** (P6-5): `AssemblyPlc._handlePiece` is a commissioning no-op; serial mint / per-piece consumption / material-override / NoRead-bypass aren't wired end-to-end. The non-serialized tray path *is* fully wired.
- **AD elevation — wired into zero views** (systemic #3): the primitive exists but is never invoked; blocked on the AD IdP deployment seam.
- **Sort Cage re-containerize — partial** (P7-8) and several **gateway side-effects are sim stubs** (AIM hold/update, print-failure sweep/broadcast) pending commissioning.

**Must-fix runtime/correctness bugs (before any smoke/cutover):**
| ID | Area | Bug |
|----|------|-----|
| P4-1 🔴 | Trim | Trim OUT sends `shotCount:0` raw → monotonic guard rejects the happy path (Trim OUT blocked) |
| P3-4 🟠 | Die Cast | `dcValues` JSON object-vs-array → `ProductionEventValue` children silently dropped |
| P3-2 🟠 | Die Cast | Free-entry cavity routes a typed number into a surrogate PK → wrong/rejected cavity |
| P2-1 🟠 | LOT | Genealogy drill-down clicks are dead (event on a container) |
| P5-4 🟠 | Machining | PLC watcher grabs `queue[0]` unfiltered → can auto-complete an un-machined source LOT |
| P7-4 🟠 | Shipping | `Container_Ship` writes no `LotMovement`/`CurrentLocationId` (Honda-trace gap) |
| P7-7 🟠 | Hold | Held→released **shipped** container restores to Complete → silently re-shippable (double-ship) |
| P7-6 🟠 | Hold | HoldRow "Use" button permanently disabled → release-select path dead |
| P8-5 🟠 | Shift | `ShiftBoundaryTicker` writes gateway-local time into UTC columns → mixed-TZ data |
| P8-1 🟠 | Downtime | Open-downtime list never refreshes after a mutation (runScript cache) |

**Systemic patterns** (one fix each, applied app-wide) are summarized at the bottom; per-area detail follows. **~95 itemized findings** across 10 areas (~10 must-fix; the rest FDS gaps, fragilities, and info/verify); reviewed-clean surfaces are listed per area.

### Applied-fixes log (working tree, uncommitted — SQL **suite not yet re-run**)
- **F1 ✅** (06-26) — session-schema clobber reverted (`props.json`).
- **Group 1 ✅** (06-29) — `BulkResultRow` root wrapper; undefined-class/token stylesheet shim; `RegisterOperator` width. Detail + verification in `ARC2_BEST_PRACTICES.md`.
- **Group 2** (06-29) — data/trace defects:
  - **P4-1 ✅** — `TrimBody` now seeds `shot/scrapCount = null` and wraps both in `toIntOrNone`, so the blank default no longer trips `TrimOut_Record`'s monotonic guard. Trim OUT happy path unblocked. (view; verified valid JSON)
  - **P7-7 ✅** — migration `0031` adds `Quality.HoldEvent.PriorContainerStatusCodeId`; `Hold_Place` captures the container's pre-hold status, `Hold_Release` restores it (`COALESCE → Complete` fallback for pre-0031 rows) — a shipped→hold→release container returns to **Shipped**, not a re-shippable Complete.
  - **P7-4 ✅ (schema-corrected)** — the finding's "source LOT" premise was wrong: **`Lots.Container` has no `LotId`** (parts trace via `ContainerSerial`/`ConsumptionEvent` genealogy). Fixed the real gap — `Container_Ship` now updates `CurrentLocationId → SHIPOUT` (matches the ShippingDock view's stated behavior) alongside the status flip + existing `ContainerShipped` audit row. A per-LOT `LotMovement` is **not applicable** to the container-centric model → flagged for FDS-07-014 reconciliation.
  - **FDS-08-016 ✅** — `sql/seeds/030_seed_defect_codes.sql` loads all **153** FRS Appendix-E codes (idempotent `NOT EXISTS`, ASCII, apostrophe-escaped) with the agreed representative dept→Area mapping: Die Cast→DC1 (59) / Machine Shop→MA1 (75) / Trim Shop→TRIM1 (6) / HSP·Prod.Control·Quality Control→MPP-MAD (13). Unblocks the previously-empty reject dropdown (which is currently unfiltered). **Caveat (in the seed header):** die-cast codes attach to DC1 only, so once area-filtering is wired, DC2–4 won't see them — refine with MPP. **P-08-017 still open** (RejectPanel passes hardcoded `getForDropdown(0)`; the area filter isn't wired — that's why the dropdown shows all codes regardless of mapping for now).
- **Corrections surfaced by the fix work:** (1) FDS-08-001 hold-type taxonomy is **already fixed by migration `0030`** (Quality/CustomerComplaint/Precautionary) — the conformance note read the pre-0030 `0004` seed. (2) P3-4's "reachable via TrimBody" was wrong — `CheckpointPanel` is orphaned (BP-DC-5).
- **SQL suite ✅ run 2026-06-29 — 1849 / 1849 assertions pass, 0 failures** (all 159 test files recorded full results; the new nullable `HoldEvent` column + 153 defect rows broke no fixed-shape capture or row-count assert). Updated the `0029` Hold test to the correct **restore-prior** behavior and added a **P7-7 Shipped-container regression** (held→released stays Shipped) — both pass. The runner exits 1 **only** because of the **pre-existing** `Parts.DataCollectionField_Create` throwing file (no `@DataTypeId` vs migration `0023`'s NOT NULL column — documented in `PROJECT_STATUS.md`, unrelated to these changes; worth fixing separately). P4-1 needed no SQL test — the proc already correctly skips its guard on a NULL count; the bug was the view sending `0`.
- **Still owed before merge:** Designer reload-from-disk + smoke of the view edits + `scan.ps1`; **re-seed** (`Seed-SmokeData.ps1`) + **gateway restart** (the suite reset `MPP_MES_Dev`).
- **Group 3 (2026-06-29) — systemic sweeps:**
  - **OI-36 ET conversion ✅ (committed `bbbc5ae`, suite 1849/1849)** — 7 read procs convert displayed timestamps UTC→ET at the boundary (`LotPause_GetByLocation`/`_GetByLot`, `Lot_Search`/`_Get`/`_List`, `Lot_GetWipQueueByLocation`, `ProductionEvent_ListByLot`). Resolves P2-4, P2-5/P9-5, P4-5/P5-6, P3-11, P8-7.
  - **Pre-declared shaped bound props ✅** — shaped `custom`-block defaults added to 9 views (DieCastBody `activeTool`/`cavityOptions`/`itemOptions`/`shiftTally`; MachiningIn `queue`/`holdCount`/`activeMachined`; MachiningOutSplit `parentLot`/`destOptions`; Assembly Ser+NonSer `container`/`queueByPartText`; DowntimeEntry `rows`; ShiftEndSummary `summary`; SupervisorDashboard `openSummary`; TrimBody `destCells`). Resolves P3-6, P5-5, P6-4, P8-10, BP-D-1/D-5, BP-TR-2. All 10 views verified valid JSON. Two cases also needed a binding-safe SOURCE (CLAUDE.md "the default is only the first-paint guard"): **EndOfShiftEntry** → new `Shift.getOpenOrEmpty` + guards re-keyed to `.Id` (BP-D-4); **SupervisorDashboard** → `DowntimeEvent.getOpenSummary` now returns a shaped zero-dict (BP-D-7).
  - **Deferred (pre-existing WIP, not entangled):** `AimPoolConfig.cfg` (P7-9) and `HoldManagement.openHolds` (BP-HM-2) — same one-line shaped default; apply when that WIP is reconciled.
  - **Noticed, out of scope:** `DowntimeEntry.cellOptions`/`reasonOptions` and `ShiftEndSummary.cellOptions` are top-level reads of undeclared (binding-backed) props — low-risk first-paint; add `[]` defaults if desired.

---

## Area 1 — Terminal-Flavor Refactor (shared/dedicated, FDS-02-010)

Governing design: `docs/superpowers/specs/2026-06-25-terminal-flavor-shared-dedicated-design.md`.
Structure: `*Body` (shared form embed) + `*Shared` (picker + `presence=strict`) + `*Dedicated` (parent-bound + `presence=confirm`) for Die Cast & Trim; Machining/Assembly normalized to dedicated-flavor (per-view onStartup, no picker).

### F1 🔴 ✅ RESOLVED — Uncommitted `session-props/props.json` wiped the entire declared session schema
**Fixed 2026-06-26:** reverted `props.json` to `HEAD` (`git checkout`), restoring the 7 `custom` keys + 6 `props` keys (incl. ET `timeZoneId`). The sibling `resource.json` shows only an EOL flag (no content diff) — left as-is.
**File:** `ignition/projects/MPP/com.inductiveautomation.perspective/session-props/props.json` (working-tree, uncommitted)
The working-tree change replaces `"custom": { appUserId, cell{}, presence{policy}, printer{}, terminal{}, user{}, toastInstances }` with `"custom": {}`, and `"props": { address, timeZoneId:"America/Indianapolis", locale, … }` with `"props": {}`.

**Why it breaks:**
- `session.custom.terminal` / `printer` are re-created at runtime by `startup/onStartup.py` (whole-dict assign), so those survive. But `cell`, `user`, `appUserId`, `presence`, `toastInstances` were **only** provided by the now-deleted declared defaults.
- Unguarded reads of the missing props throw / go Quality-Bad on first paint:
  - Every work view's `OperatorLabel` expr reads `{session.custom.user.displayName}` / `.initials` (DieCastBody:145, TrimBody:94, MachiningIn:131, MachiningOutSplit:120, AssemblyIn/NonSer/Ser, ReceivingDock:165).
  - Work-view onStartup operator-gates read `self.session.custom.appUserId` (MachiningIn:630, Assembly*, DieCastBody:1113, TrimBody:772, ReceivingDock:73) → AttributeError before the InitialsEntry popup can open → **operator login gate dead**.
  - `PresenceIdleWatcher` reads `session.custom.presence.policy` and `session.custom.user.appUserId` every 30 s → throws when absent.
  - `DieCastShared.seedSelectedCell` reads `session.custom.cell` unguarded.
  - `NotifyHost`/Toast read `session.custom.toastInstances`.
- Losing `props.timeZoneId:"America/Indianapolis"` drops the ET-display timezone override (CLAUDE.md: all displayed timestamps are ET).

This is the "Designer clobber" hazard the design spec §8 explicitly warned about. The diff contains **no** intended edits — only the two wipes.

**Recommended fix:** restore the file to `HEAD` (`git checkout -- …/session-props/props.json`); also check the companion `session-props/resource.json` working-tree change. **Pending Hunter's OK** (discards uncommitted working-tree state).

### F2 🟠 Strict-policy (shared-flavor) presence re-prompts are not implemented
Per **FDS-04-003**, a strict (shared) terminal must (a) re-request initials after idle > timeout, and (b) re-prompt on location-context change. Neither exists now that the shared flavor ships:
- **Idle:** `…/Components/PlantFloor/PresenceIdleWatcher/view.json:17` early-returns when `presence.policy != "confirm"` (explicit TODO: "wired when the first shared-flavor work views are built"). `DieCastShared`/`TrimShared` set `policy="strict"`, so they get no idle re-prompt.
- **Context change:** the shared views' `applyCell` (e.g. `DieCastShared/view.json:132`) updates `session.custom.cell` but does **not** clear/re-request initials. FDS-04-003 requires a re-prompt on context change for strict terminals.

Functional MVP gap introduced by shipping the shared flavor.

### F3 🟡 Two sources of truth for the operator id
`session.custom.appUserId` (top-level) and `session.custom.user.appUserId` (nested) are both maintained (written in sync at `InitialsEntry/view.json:224` and `IdleReconfirmModal/view.json:176`), but read inconsistently: work-view gates/mutations read the top-level one; `PresenceIdleWatcher` reads the nested one. Works today; fragile to future edits. Consolidate on one, or document the invariant.

### F4 🟢 Verify dedicated-flavor parent parenting in seed (not a code bug)
`Terminal_GetByIpAddress` returns `ZoneLocationId = ParentLocationId` (immediate parent) — so dedicated context = terminal's parent at any tier is correct per FDS-02-009. **But** the dedicated Machining/Assembly views bind `cell = zoneLocationId`, so they bind to the line **only if** the MA terminals are parented at the ProductionLine in `sql/seeds/011_seed_locations_mpp_plant.sql`; and a dedicated Die Cast terminal binds to a machine only if parented at the machine. Verify seed parenting matches intent (spec §5 notes today's DC terminals are area-parented and a machine-parented demo terminal must be seeded).

### F5 🟡 onStartup guard inconsistency (defense-in-depth)
Even with the schema restored, presence/cell reads are inconsistently guarded — some via `try/except` (presence), some unguarded (`seedSelectedCell` cell read; `MachiningIn` messageHandler `self.session.custom.cell.locationId`). A watcher firing before a work-view onStartup sets `presence` could still throw. Recommend a uniform guard/seed pattern.

### F6 🟡 `CellContextSelector` component is orphaned
Zero references anywhere in the MPP project (`grep CellContextSelector` → none). The shared flavor views (`DieCastShared`/`TrimShared`) inline their own `CellDropdown` + `applyCell`/`seedSelectedCell` instead of using the component the design (§6) named. The component is now dead/stale code (it also predates the `kindFilter` mechanism). Cleanup candidate, or repoint the shared views at it to avoid duplicated picker logic across Die Cast/Trim.

### F7 🟡 Shared-picker `kindFilter` is keyed on the display Name (currently matches)
`Terminal_ListContextCells` returns `Kind = LocationTypeDefinition.Name`; the shared views filter `Kind == "Die Cast Machine"` / `"Trim Press"`. Seed confirms Name = `Die Cast Machine` (Code `DieCastMachine`, DefId 8) and `Trim Press` (Code `TrimPress`, DefId 10) — **so it works today.** But the filter is coupled to the human-editable Name while the proc's own Terminal/Printer exclusion uses the stable `Code`. An admin renaming a definition Name would silently empty the picker. Recommend filtering by `Code` (or DefId) for robustness.

### F8 🟢 Uncommitted view diffs — classify reserialization vs. real WIP before committing
- `InitialsEntry/view.json` and (likely) `PrintFailureBanner/view.json` working-tree diffs are **Designer GSON reserialization** (key reordering; all scripts/handlers intact) — logic-neutral, but noisy. Verify and commit as reformat, or discard.
- `HoldManagement` (~1264-line diff), `ShippingDock` (~1154), `SortCageWorkflow` (~799), `AimPoolConfig` (~420), and the Assembly/Machining view diffs are large and **likely real in-flight work** — reviewed in their phase areas (Phase 6/7), not assumed reformat.

### ✅ Reviewed clean (terminal-flavor area)
`HomeRouter.route()` (fallback→terminal-selector, else `DefaultScreen`, else graceful "no default screen" card); `Terminal_GetByIpAddress` (`ZoneLocationId` = immediate parent, deterministic IP tie-break, fallback + seed-missing empty-set guard); `Terminal_ListContextCells` (recursive descendants, `MAXRECURSION 8`, Terminal/Printer excluded by Code); `TrimShared`/`TrimDedicated` (mirror Die Cast correctly); `onStartup.py` (whole-dict terminal/printer assign, fallback-safe). The dual-write of `appUserId` (top-level + nested) is synced at both write sites (`InitialsEntry:loginAs`, `IdleReconfirmModal`).

---

## Area 2 — Phase 2: LOT Lifecycle (LotSearch, LotDetail, GenealogyViewer, Pause)

*(Parallel review agent; verified against FDS-05 + lots procs/NQs. Spot-check status below.)*

- **P2-1 🟠 Correctness** — Genealogy drill-down clicks are dead. `ParentRow:42`, `ChildRow:42`, `GenealogyViewer/NodeRow:67` wire navigate to `events.component.onActionPerformed` on a **root flex container**, which emits no such event (working rows use it only on `ia.input.button`; `PausedLotIndicator` correctly uses `events.dom.onClick`). Clicking a parent/child/node does nothing — core Honda-trace UX is dead. **Fix:** move scripts to `events.dom.onClick`.
- **P2-2 🟠 Data-contract** — `StatusPill:54` color expr tests `"Good"/"Held"/"Scrapped"/"Rejected"` but seeded `LotStatusCode.Code` are `Good/Hold/Scrap/Closed` — `Hold`/`Scrap` fall through to a neutral grey pill in search results (safety-critical statuses render unstyled). **Fix:** match `Hold`/`Scrap`.
- **P2-3 🟠 Correctness** — `LotDetail:194` header pill hardcodes `pf-pill-good` for every status → a Hold/Scrap LOT shows a green pill in the detail header. **Fix:** drive class off `LotStatusCode`.
- **P2-4 🟠 FDS (OI-36)** — `LotPause_GetByLocation:27` / `LotPause_GetByLot:11` return `PausedAt` raw UTC (no `AT TIME ZONE`); PausedLotRow/PauseRow display it ~4–5h off plant ET. **Fix:** ET-convert at proc boundary.
- **P2-5 🟠 FDS (OI-36)** — `Lot_Search:21` (`CreatedAt`), `Lot_Get:42`, `Lot_List` return raw UTC; LotSearch "Created" column shows UTC. **Fix:** ET-convert.
- **P2-6 🟡** — `PauseRow:121` uses `toStr(PausedAt)` instead of `dateFormat()` → raw timestamp blob.
- **P2-7 🟡 Data-contract** — `LotPause_Resume` proc accepts `@TerminalLocationId` but NQ/entity never thread it → NULL terminal in OperationLog. **Fix:** pass it through `resume()`→NQ→proc.
- **P2-8 🟢** — `GenealogyViewer:557` reads `rootLot.ItemCode` but `Lot_Get` returns `ItemPartNumber` → blank root part code. **Fix:** use `ItemPartNumber`.
- **P2-9 🟡** — LotDetail/PausedLotList repeaters use the flagged `useDefaultViewHeight:false` + `basis:"auto"` combo (row-sizing risk); verify on smoke.
- **P2-10 🟢** — `/lot-detail/:lotId` route param is a string into a numeric `Lot_Get` param; verify coercion on real navigation.

**Reviewed clean:** all lots NQ `type:"Query"` incl. `LotPause_Resume` mutation; `bidirectional` correctly inside `config`; `Lot_GetAttributeHistory` ET-converts + casts UNION branches uniformly; `LotPause_Resume` runs rejections before `BEGIN TRANSACTION` (no INSERT-EXEC/rollback trap); param shapes match proc contracts; LotDetail `custom.lot` pre-declares nested keys; all `resource.json` manifests present.

---

## Area 3 — Phase 3: Die Cast Operator Station

*(Parallel review agent; verified against FDS-05/06 + workorder/lots procs.)*

- **P3-1 🟠 FDS** — Die-cast LOT create (`DieCastBody:1103 submitCreate`) calls only `Lot.create` and never writes the `ProductionEvent` checkpoint FDS-05-004 step 8 mandates (`CheckpointPanel` is embedded by TrimBody, not DieCast). The shot KPI is reconstructed from summed LOT counts instead. Likely an intentional evolution — **reconcile the FDS or wire the checkpoint write.**
- **P3-2 🟠 Correctness** — Free-entry cavity discriminates by `int(cav)`-parseability; an operator typing the cavity *number* ("3") parses to `int 3` and is passed as `ToolCavityId=3` (a surrogate PK) → wrong cavity or reject. **Fix:** discriminate by membership in the known `cavityOptions` value set, not int-parseability.
- **P3-3 🟠 Correctness** — `Lot_GetShiftCavityTally` sums `Lot.PieceCount`, but `RejectEvent_Record:214` decrements it → "shots this shift" KPI drops on reject, contradicting the proc's documented "immutable as-cast" intent (no immutable as-cast column exists). **Fix:** store/sum an immutable as-cast count.
- **P3-4 🟠 Data-contract** — `ProductionEvent.code.py:37` encodes `dcValues` as a JSON **object** keyed by field id, but `ProductionEvent_Record:243` `OPENJSON … WITH (DataCollectionFieldId …)` expects an **array of objects** → all `ProductionEventValue` children silently dropped. **Correction (best-practices pass, BP-DC-5):** `CheckpointPanel` is **orphaned — no view embeds it**, so this is latent in dead code, not live via TrimBody. **Fix:** reshape to `[{DataCollectionFieldId, Value}, …]` before wiring CheckpointPanel in.
- **P3-5 🟠 FDS** — No inline elevated Tool-mismatch Edit (FDS-05-004 step 4 / FDS-04-007); `DieCastBody:486` only navigates to the Config app (no AD elevation, no inline release/assign).
- **P3-6 🟡** — `DieCastBody` reads `activeTool`/`cavityOptions`/`itemOptions`/`shiftTally` via bindings but doesn't pre-declare them with shaped defaults (first-paint Quality-Bad risk; sources do return shaped, so transient).
- **P3-7 🟡** — `DieCastBody:98` hardcodes "SHARED TERMINAL" subtitle but is embedded by both flavors → wrong label on dedicated.
- **P3-8 🟡** — Peer tally (`PeerTallyRow:50`) shows surrogate `ToolCavityId` ("Cavity 4012") not the cavity number.
- **P3-9 🟡** — `rejectRecorded` page message has no handler in DieCastBody → right-rail KPI stale after a reject.
- **P3-10 🟢** — `DieCastBody:162` PausedLotIndicator embed is `position.display:false` (hard-hidden); verify intentional.
- **P3-11 🟢 / P3-12 🟢** — `ProductionEvent_ListByLot.EventAt` raw UTC (OI-36, not yet surfaced); manual-cavity (D2) LOTs invisible to the cavity tally.

**Reviewed clean:** NQ `type:"Query"` on all 3 mutations; single result set + validations-before-BEGIN-TRAN + inlined guards (Msg-3915 safe); `bidirectional` inside `config` on every input; embed→parent via page-scoped messages; `Lot_Create` enforces `PieceCount ≤ MaxLotSize`; `RejectEvent_Record` TOCTOU re-check under UPDLOCK; `FieldInputRow` uses `position.display` for type-driven widgets.

---

## Area 4 — Phase 4: Movement + Trim + Receiving

- **P4-1 🔴 Correctness** — `TrimBody:7,765` seeds `shotCount:0`/`scrapCount:0` and `submitTrimOut` passes them raw (no `toIntOrNone`). `TrimOut_Record:166` runs a cumulative-monotonic guard (`@ShotCount < @PrevShot → reject`); a cast LOT already carries a die-cast `ProductionEvent.ShotCount`, so an unchanged Trim OUT submits `0 < prevShot` and is **rejected** — blocks the primary Trim OUT path. **Fix:** default both to `null` + `toIntOrNone` (blank→NULL skips guard); ideally drop the shot field for Trim (it's yield-loss only).
- **P4-2 🟠 Correctness** — The Trim IN `MovementScan` embed (`TrimBody:322`) doesn't set `props.params.replyMessage`, so it emits the default `"movementScanCommitted"`, but TrimBody handles `"trimInMoved"` (no handler for the default anywhere) → the IN→OUT auto-handoff never fires (server move still happens). **Fix:** set `replyMessage:"trimInMoved"`.
- **P4-3 🟠 FDS** — `LinesideLimit` (FDS-03-020, MVP per-Cell total cap) is **entirely unimplemented** — no LocationAttribute, no enforcement anywhere; `Lot_MoveToValidated` enforces only `Item.MaxParts`. **Fix:** add the cap check or formally defer FDS-03-020.
- **P4-4 🟡** — Trim OUT destination dropdown (`TrimBody:501`) lacks `allowCustomOptions` though the toast says "Scan or pick" — pick-only, no scan path.
- **P4-5 🟡 OI-36** — `Lot_GetWipQueueByLocation:31` returns `LastMovementAt` raw UTC.
- **P4-6 🟡 Correctness** — `Lot_GetWipQueueByLocation:55` `ORDER BY LastMovementAt ASC` — in-place LOTs (NULL move) sort first and jump the FIFO queue. **Fix:** `ISNULL(LastMovementAt, l.CreatedAt)`.
- **P4-7 🟡 Data** — `0004_phase3_reference_lookups.sql:114` `PrintReasonCode` "Reprint — Damaged" contains a non-ASCII em-dash → mojibake (this is `reprint`'s default reason). **Fix:** hyphen.
- **P4-8 🟢** — ReceivingDock `createLot`/`reprintLast` TODO comments are stale (the label/reason resolvers exist; print actually succeeds).

**Reviewed clean:** `Lot_MoveToValidated` (eligibility via `v_EffectiveItemLocation` + MaxParts + not-blocked/Closed gates, Msg-3915 safe); `TrimOut_Record` whole-LOT 1:1 move no split; LotLabel print path (server-resolves None ids, InterfaceLog every attempt, failure never rolls back the LOT, raw-TCP 9100 w/ timeout); all 11 NQs `type:"Query"`; ReceivingDock part field is correct scan-or-dropdown; MovementScan shaped defaults + page-scoped message-out.

## Area 5 — Phase 5: Machining IN/OUT

- **P5-1 🟠 FDS** — `MachiningOutSplit` hardcodes exactly 2 sub-LOTs (`qty1/qty2/dest1/dest2`, 2 static repeater entities, fixed 2-element `children`), but FDS-05-009 specifies N-way (default 2, adjustable) and the proc is fully general (OPENJSON + WHILE). UI-only gap. **Confirm** whether any sublotting line routes to >2 destinations; if so it's a functional defect. **Fix:** dynamic add/remove rows bound to a `draft.children` array.
- **P5-2 🟠 FDS** — `MachiningIn:654` rename confirm shows only the **source** part ("Pick LOT X (src) and rename…"); FDS-05-033 mandates *"This LOT is {src}. Receive as {dst}?"* The operator confirms without seeing the destination. **Fix:** resolve + render the destination machined part.
- **P5-3 🟠 FDS** — FIFO-override "Pick" (`MachiningIn:661`) always calls `pickAndConsume(..., None)` though `queueOverrideReason` is plumbed end-to-end and the UI promises a reason prompt → out-of-order picks silently unattributed. **Fix:** prompt for reason when `position>1`.
- **P5-4 🟠 Correctness** — `MachiningPlc.tickWatcher:48` resolves the LOT as `getWipQueueByLocation(cellId)[0]` (oldest open LOT, **unfiltered**). If an un-picked source LOT sits at the cell when the PLC fires, `MachiningOut_AutoComplete` writes a MachiningOut event + auto-moves a LOT that was never machined. **Fix:** filter to machined LOTs (`not HasRenameBom`), match the views' selection.
- **P5-5 🟡** — `MachiningIn`/`MachiningOutSplit` read `queue`/`holdCount`/`activeMachined`/`parentLot`/`destOptions` via nested-path bindings with no shaped `custom` defaults (first-paint Component-Error risk).
- **P5-6 🟡 OI-36** — WIP-queue `LastMovementAt` displayed raw UTC (same root as P4-5).
- **P5-7 🟡** — split submit doesn't validate `qty1+qty2 == parent.PieceCount` client-side (proc rejects → UX round-trip).
- **P5-8 🟡 B1** — `pickAndConsume`/`recordSplit` calls omit `terminalLocationId` → NULL terminal attribution on all Phase 5 events.
- **P5-9 🟡** — active LOT = `machined[-1]` heuristic; two coexisting machined LOTs hide the older (un-splittable).
- **P5-10 🟢** — `MachiningOutSplit:134` hardcoded "Paused 0" badge.
- **P5-11 🟢 FDS** — `pickAndConsume` system-mints the machined LTT (FDS-05-033 says "scan a fresh LTT") — likely an intentional minting decision; reconcile the FDS.
- **P5-12 🟢** — split destination dropdowns lack `allowCustomOptions` (no scan).

**Reviewed clean:** all 3 mutation NQs `type:"Query"`; single result set; `recordSplit`/`pickAndConsume` run validations before `BEGIN TRANSACTION` + inline sub-mutations (gotcha #16 satisfied, no nested status-row EXEC, no rollback outside CATCH); inline `Lot_AssertNotBlocked` mirror on all 3; closure depth+1 correct; in-txn minting under `ROWLOCK,UPDLOCK,HOLDLOCK`; `refreshToken` passed as runScript **arg**; `bidirectional` inside `config`.

---

## Area 6 — Phase 6: Assembly + MIP + Container Pack

- **P6-1 🟠 Correctness** — `ContainerTray_Close:108,149` picks source LOTs with only `sc.Code <> 'Closed'` — never excludes `BlocksProduction=1`, so a **HOLD/Scrap** component LOT is silently consumed into a tray + genealogy (defect-escape risk, violates source-not-HOLD). **Fix:** add `AND sc.BlocksProduction = 0` to both the pre-check and FIFO select.
- **P6-2 🟠 Correctness** — `ConsumptionEvent_RecordWithBomCheck:100` inserts the event but never decrements source `Lot.PieceCount` and never asserts-not-blocked (inconsistent with `ContainerTray_Close`). Latent today (serialized path unbuilt — see P6-5) but will let source LOTs never deplete. **Fix:** decrement + close-at-0 + reject blocked, in-txn.
- **P6-3 🟡 Data** — `@ContainerSerialId` is declared/threaded but the `ConsumptionEvent` INSERT has no such column and leaves `ProducedSerialNumber` NULL → serial↔consumption genealogy tie lost. **Fix:** persist `ProducedSerialNumber` or drop the dead param.
- **P6-4 🟡** — `AssemblySerialized`/`AssemblyNonSerialized` read `container`/`queueByPartText` via nested-path/`position.display` bindings but don't pre-declare them shaped (first-paint Component-Error — the documented Routes `StateBadge` incident). `AssemblyIn` does it right. **Fix:** seed shaped `container` + `queueByPartText:""`.
- **P6-5 🟡 Scope/FDS** — The **entire serialized-MIP per-part path is unbuilt**: `AssemblyPlc._handlePiece` is a logged no-op and `SerializedPart.mint`/`Container.serialAdd`/`Consumption.recordWithBomCheck`/`AimPool.claim`/`MaterialOverrideConfirm` are referenced by nothing. FDS-06-010/011/012 (PartSN validate/PartValid, NoRead bypass, per-piece BOM consume) are **not delivered end-to-end** (intentional commissioning no-op — only leaf procs/popups exist). The non-serialized tray path (FDS-06-013/014) *is* fully wired.
- **P6-6 🟡 FDS** — `MaterialOverrideConfirm:53` authorizes the override with **no AD elevation / supervisor identity**, but FDS-06-011/UJ-09 require a supervisor AD elevation yielding the `OverrideAppUserId` the proc mandates. **Fix:** route through AD elevation, carry supervisor `AppUserId` in the reply.
- **P6-7 🟡 Correctness** — `ContainerTray_Close` runs the BOM availability check **before** `BEGIN TRANSACTION` (un-locked); the in-txn FIFO `IF @SrcLotId IS NULL BREAK` then under-consumes yet COMMITs on a concurrent depletion. **Fix:** re-check under lock / force CATCH rollback on BREAK.
- **P6-8 🟢** — `Container_Complete:94` skips the fullness gate when `ContainerConfig` trays/parts are NULL → a misconfigured container can complete (claim AIM) with 0 parts.
- **P6-9 🟢** — `ScanQueueRow:150` StatusPill maps any non-`Good` to "Hold" (Scrap mislabeled).
- **P6-10 🟢** — `complete()`/`trayClose()` pass `session.custom.cell.locationId` as `terminalLocationId` (conflates terminal vs cell; benign on dedicated where cell==zone).

**Reviewed clean:** all 9 NQ `type:"Query"`; **Container_Complete atomicity correct** (FIFO claim + ShippingLabel(PrintedAt NULL) + status flip one txn; empty-pool **hard-fail rejects before BEGIN TRAN** leaving container Open — FDS-07-005/010a); **AIM FIFO locking correct** (`ROWLOCK,UPDLOCK,READPAST` + `ORDER BY FetchedAt,Id`); **per-validated-tray consumption** (one ConsumptionEvent per component per source slice, not per piece — FDS-06-014); `ContainerSerial_Add` persists+audits `HardwareInterlockBypassed` (UJ-16); `SerializedPart_Mint` gap-free row-locked; `Assembly_ScanIn` blocks Held/Closed + validates BOM-component-at-cell; `Container_GetOpenByCell` ET-casts `OpenedAt`; runScripts pass `refreshToken` as arg; uncommitted Assembly `resource.json` edits are **manifest-only** (thumbnail+signature) — no content regression.

---

## Area 8 — Phase 8: Downtime + Shift Boundary

- **P8-1 🟠 Correctness** — `DowntimeEntry:42` open-list `runScript(getOpenByLocation, …, filter.cellLocationId)`; Start/End/Assign "refresh" by cloning `filter` (same scalar arg) → runScript memoizes → **list never refreshes** after a mutation. **Fix:** bump a `refreshTick` and pass it as a trailing runScript arg.
- **P8-2 🟠 FDS** — `DowntimeEntry:7` reason filter `areaLocationId`/`downtimeReasonTypeId` hard-null + no Type selector → reason dropdown lists every code across all Areas/Types (incl. PLC codes), violating FDS-09-005 (filter by Area+Type, type-first). The proc already supports the params. **Fix:** derive Area from cell + add type-first selector.
- **P8-3 🟠 FDS** — `EndOfShiftEntry:9` is unconditionally visible; the FDS-09-013 ±15-min visibility window is **not implemented**. **Fix:** gate on now vs scheduled end.
- **P8-4 🟠 Data-contract/FDS** — All 4 views use a manual cell picker (not `session.custom.cell`), pass no `terminalLocationId`, and have no shared-flavor inline-initials path → FDS-09-001 "machine auto from terminal" unhonored, `submitEndOfShift` attributes to dev-fallback user, every Phase 8 audit row gets NULL terminal.
- **P8-5 🟠 Data-contract** — `ShiftBoundaryTicker:5` passes `system.date.now()` (gateway-local) into `Shift_Start/End @ActualStart/@ActualEnd` (UTC columns), while `DowntimeEvent.StartedAt` uses `SYSUTCDATETIME()` → **mixed-TZ data** that skews any shift-vs-event derivation. **Fix:** pass `None` (proc defaults to UTC) or explicit UTC.
- **P8-6 🟠 Correctness** — `Shift.tickShiftBoundary` calls `start()`/`end()` without `appUserId` → gateway-timer `_currentAppUserId()` returns dev-fallback `2`; if AppUser 2 absent in prod the audit FK insert throws → automated shift never starts. **Fix:** explicit system AppUser (like `DowntimePlc` uses `1`).
- **P8-7 🟡 OI-36** — `LotPause_GetByLocation:27` `PausedAt` raw UTC; `ShiftEndSummary:87` renders `str(PausedAt)` → UTC on summary (inconsistent with its ET `StartedAtEt`).
- **P8-8 🟡** — Zero-break End-of-Shift submit writes no rows → re-submittable (FDS-09-013 "single entry" unenforced for the zero case).
- **P8-9 🟡** — Late reason-assign reuses the Start-panel reason dropdown value (no per-row picker) + silent no-op when none selected.
- **P8-10 🟡** — `DowntimeEntry.rows` / `ShiftEndSummary.summary.*` read via `len()`/nested paths without shaped `custom` defaults (first-paint error).
- **P8-11 🟡 Scope** — SupervisorDashboard: Open-Downtime + Classified tiles are real; Paused-LOTs / Shift-Availability / AIM-Pool / Print-Failures are honest stubs ("—"). The built `AimPoolTile` component is orphaned (dashboard shows its own stub instead). **Fix/decide:** wire or remove.
- **P8-12 🟢** — `EndOfShiftEntry_Submit` writes overlapping break intervals `[ActualStart, +duration]` (nominal; will undercount if future OEE unions intervals).

**Reviewed clean:** B3 ≤1-open invariant (Start pre-check + filtered-unique indexes); B7 late-bind refuses overwrite; FDS-09-004 append-only (only EndedAt+reason mutable); FDS-09-010 no auto-split across boundary (events stay open); toggle-per-break writes schedule `StandardDurationMinutes` (no operator minutes); all 15 NQs `type:"Query"`; ET conversion on DowntimeEvent/Lot reads; DowntimePlc edge watcher uses explicit system user.

---

## Area 7 — Phase 7: Hold + Sort Cage + Shipping + AIM Pool *(uncommitted WIP)*

- **P7-1 🟠 FDS** — Place/Release/Bulk-hold, label Reprint, and AimPool-Save call entity methods **directly** — no AD elevation (FDS-04-007/08-007a/07-010c), though `HoldManagement:103` advertises "AD-elevated." `ElevationModal`+`AppUser.elevate` exist but are wired into **zero** views. *Nuance:* `_validateAdCredentials` is a hard-`False` deployment seam (enabling it now blocks all dev) — a known global deferral. **Fix:** gate these buttons through ElevationModal when the AD IdP is wired; soften the header claim until then. (Ship is correctly not elevated.)
- **P7-2 🟠 Correctness/FDS** — AimPoolConfig threshold ordering (`Critical<Warning<Topup<Target`, FDS-07-010c) is enforced **neither** at the table (only `CK_SingleRow`) **nor** in `_Update` (only non-negative) → an admin can invert the alarm logic. **Fix:** add the 3-clause CHECK + an ordering reject before `BEGIN TRAN`.
- **P7-3 🟠 FDS/Data** — `AimPoolConfig_Update` writes **no audit** at all; FDS-07-010c requires `Audit.ConfigLog`. **Fix:** emit `Audit_LogConfig` with old/new threshold JSON.
- **P7-4 🟠 FDS/Data** — `Container_Ship:61` flips status→Shipped but writes **no `LotMovement`** and doesn't update `CurrentLocationId` (FDS-07-014 requires the move-to-Shipped record — the Honda-permanent record). The view claims it happens. **Fix:** insert LotMovement (→Shipped) + update source LOT location in the same txn.
- **P7-5 🟠 FDS** — `Container_Ship` validates label/void/Complete/hold but never checks `AimShipperId` assigned/valid (FDS-07-013). **Fix:** add presence/format check + specific reject.
- **P7-6 🟠 Correctness** — `HoldRow:220` "Use" button `enabled = {params.lotStatusCode}='Good'`, but the HoldManagement transforms (`:343,:458`) emit rows without `lotStatusCode` → button **always disabled** → the only affordance to populate the Release form is dead. Orphan copy-paste `propConfig` params at `:10-32`. **Fix:** drop the gate (always enable Use) or supply the key.
- **P7-7 🟠 Correctness/Data** — A SHIPPED container placed on hold (recall) and released restores to **Complete** unconditionally (`Hold_Release:81`; no ContainerStatusHistory) → re-shippable via `Container_Ship` → **double-ship with no trace**. **Fix:** capture/restore prior container status, or reject holding an already-Shipped container.
- **P7-8 🟠 FDS (provisional/UJ-05)** — SortCage `migrateSerial` does the in-place ContainerSerial update + ContainerSerialHistory (ancestry preserved ✓), but FDS-07-017 steps unwired: no LotMovement to Sort Cage, no new LTT (`SortCageReIdentify`), no new shipping labels, **no void of old labels** (`voidLabel` exists, never called), **no AIM `UpdateAim`** (FDS-07-012); doesn't assert source container is on Hold. Re-containerize is UJ-05-open (provisional), but void-old-label + AIM-update are real MVP-EXPANDED obligations.
- **P7-9 🟡** — `AimPoolConfig.cfg` not pre-declared shaped; KPI exprs traverse `{view.custom.cfg.X}` (first-paint Quality-Bad until binding resolves).
- **P7-10 🟡** — `AimPoolTile:12` `getDepth` runScript is run-once (no poll/token) → supervisor depth tile never refreshes as IDs are consumed.
- **P7-11 🟡** — `PrintFailureBanner:102` shows on **every** session (no `session.custom.terminal` filter, contradicting FDS-07-006b); `PrintFailureGateway.sweepTick/broadcastTick` are no-op skeletons.
- **P7-12 🟡** — AIM alarms (`alarmTick`) fire only on rising edge — no auto-clear on recovery (FDS-07-010b) — and the seeded `AimPoolWarning/CriticalAlarmFired` audit events are never written.
- **P7-13 🟢** — AIM `placeOnHold`/`releaseFromHold`/`UpdateAim` are sim stubs **not invoked** by `Hold_Place`/`Hold_Release`/`ShippingLabel_Void` (commissioning hooks). Confirmed correct: Void keeps row + no-pool-return; `AimShipperIdPool_Claim` FIFO locking; bulk = one HoldEvent per LOT.
- **P7-14 🟢** — minor: HoldManagement filter placeholder over-promises; `Hold_Place` allows holding a Closed LOT.

**Reviewed clean:** all 14 NQ `type:"Query"`; single-result-set mutations + CATCH-only ROLLBACK; read procs ET-cast `PlacedAt`/`UpdatedAt` via `AT TIME ZONE … AS DATETIME2(3)`; `bidirectional` inside `config`; list reads bust runScript cache via refreshToken **arg**; `AimShipperIdPool_Claim` FIFO + `UPDLOCK,READPAST,ROWLOCK` + empty-pre-check + lost-race COMMIT; `placeBulk` one-HoldEvent-per-LOT; B3 one-open filtered-unique; `migrateSerial` preserves `SerializedPart.LotId` + writes ContainerSerialHistory; ShippingLabel Void keeps-row/no-pool-return + Reprint append-only.

---

## Area 9 — Phase 9: Quality Capture, CRT, Global Trace — **ESSENTIALLY UNBUILT**

Build status (full artifact grep; Arc-2 migrations stop at `0030`, no Phase-9 migration):

| Capability (FDS) | Status |
|---|---|
| Quality spec authoring (Arc-1 context) | Built |
| **Inspection capture** (QualitySample/Result/Attachment, dynamic render, auto pass/fail, attachments — FDS-08-010/011/013) | **MISSING** |
| Failed-inspection alert ≠ auto-hold (FDS-08-012) | **MISSING** (no capture path) |
| **CRT lifecycle** (issue/clear/missed, double-capture — FDS-10-011/012) | **MISSING** (column hook only) |
| **Global Trace tool** (multi-id resolve, disambiguation, export — FDS-12-012/013/014, FDS-05-018) | **MISSING** (lot-only precursors) |
| FUTURE discipline (NCM / OEE) | **Pass — clean** |

- **P9-1 🔴 FDS** — Inspection capture entirely absent: no `Quality.QualitySample`/`QualityResult`/`QualityAttachment` tables, proc, NQ, entity, or view. Only the Arc-1 spec-authoring layer exists. **Fix:** migration `0031` + the 3 tables (FK to spec **version** at inspection time) + `Inspection_Record` + dynamic-attribute view.
- **P9-2 🔴 FDS** — CRT lifecycle unbuilt; `Lot.CrtActive` (col at `0020:548`, read by `Lot_Get`/`Lot_List`) is **never written**. `Hold_Release` takes no disposition param; `ControlledRunTag` not in DispositionCode seed (`0004:200`); `MissedCrtInspect` not in hold-type seed (`0030:14`). No CrtIssued/Completed/Missed. **Fix:** seed the codes + CRT issue/clear/missed paths.
- **P9-3 🔴 FDS** — Global Trace tool missing. `Lot_Search` is LotName/Vendor/Part only (self-documents the gap); `GenealogyViewer` resolves exact LotName only. No serial/container/shipper resolution, no disambiguation, no unified output, no export. **Fix:** read-only `GlobalTrace_Resolve` over Lot/Serial/Container/Shipper + no-elevation trace view.
- **P9-4 🟠 FDS** — Honda genealogy report PDF/CSV export absent (FDS-05-018/12-014 — primary Honda deliverable).
- **P9-5 🟠 OI-36** — `Lot_Search:21` `CreatedAt` raw UTC displayed as ET-labeled "Created" (live; = P2-5). Fix at proc boundary.
- **P9-6 🟡** — `LotDetail:6` declares `CrtActive` default but renders no badge → a controlled-run LOT is invisible on the floor (compounds P9-2).
- **P9-7 🟢 Scope** — FUTURE boundaries respected: `NonConformance` is audit-seed-only (no table/proc/view); `OeeSnapshot` absent. Correct.

**Reviewed clean:** FUTURE-scope discipline; Arc-1 quality-spec authoring sound; `LotSearch` Ignition hygiene (`bidirectional` inside `config`, `onSelectionChange` row click, `results` pre-declared `[]`).

---

## Area 10 — App-wide / Cross-cutting

- **A1 🟠 Ignition-bestpractice/Scope** — `page-config/config.json:125` ships the **dev `TestNavHeader` as a 96px `top` shared dock on every page** (`viewPath: BlueRidge/Views/Dev/TestNavHeader`, `show:visible`), plus dev/test routes `/dev/test-nav` and `/navigation-testing` (→ `BlueRidge/Views/Navigation Testing`). Operator terminals would carry a dev nav bar + scaffolding routes in production. **Fix:** remove the dev dock + dev/test routes before cutover (or gate to a non-prod project).
- **A2 🟡** — Stylesheet (`Core/.../stylesheet.css`, 2773 lines) defines all the key `pf-*` classes the views use (`pf-pill-hold/bad/good`, `pf-btn*`, `pf-panel/field`, `pf-terminal-cell-context`, `canvas`, `surface-card`). `pf-tile` and `badge-warn` are referenced-but-undefined — verify usage; a missing class renders unstyled/invisible. A full 56-class coverage audit belongs in the best-practices pass.

**Reviewed clean:** `Common.Db` (`execList`/`execOne`/`execMutation` well-formed — empty-set→`[]`, no-status→`{Status:0,…}`, single `system.db.*` chokepoint, multi-row warnings); `Common.Notify` (toast FIFO stack over the restored `session.custom.toastInstances`, stale cleanup, MAX_VISIBLE cap); `NotifyHost` bottom dock (size-1 hidden host — correct pattern).

---

## Cross-cutting / systemic patterns (fix once, apply across the app)

These recur across phases and are the highest-leverage fixes:

1. **OI-36 ET conversion is incompletely applied** — raw-UTC display reads at P2-4, P2-5, P4-5, P5-6, P8-7, P9-5 (pause/created/movement/queue timestamps). Sweep every operator-facing read proc for `AT TIME ZONE … AS DATETIME2(3)`.
2. **Bound custom props not pre-declared with shaped defaults** — P3-6, P5-5, P6-4, P7-9, P8-10 (first-paint Component-Error risk on never-smoked views). Add shaped `custom`-block defaults wherever a binding traverses/`len()`s a custom prop.
3. **AD elevation (FDS-04-007) wired into ZERO views** — P7-1 (hold place/release, label reprint, AIM-config save), P3-5 (tool-mismatch edit), P6-6 (material override). The `ElevationModal`/`AppUser.elevate` primitives exist but are never invoked; blocked on the AD IdP deployment seam (`_validateAdCredentials` hard-False). Decide the wiring + soften the "AD-elevated" UI claims until then.
4. **Terminal/session attribution gaps** — P5-8, P6-10, P8-4 write events with NULL/cell-as-terminal `TerminalLocationId` instead of `session.custom.terminal`. Thread terminal context uniformly.
5. **runScript list-refresh discipline** — P8-1 (downtime list never refreshes), P7-10 (AIM tile) miss the refresh-token-as-arg pattern that the rest of the app uses correctly.

---
*(end of per-area findings)*
