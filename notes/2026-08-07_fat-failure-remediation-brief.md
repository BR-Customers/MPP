# FAT Failure Remediation Brief — 2026-08-07

Design-level triage of every remaining **Fail** in `docs/fat/MPP_MES_FAT_practice.xlsx`
(36 after the 4 stale rows were removed). Each entry: what the test expects, the current
state with file:line evidence, why it fails, and a proposed fix considered against our
existing patterns. Fixes are clustered into candidate specs so the fleet can pick them up
independently.

**Provenance:** the 6 original open items were investigated by dedicated exploration agents;
the 15 newly-found fails came from the code-inspection validation pass (marked `[insp]` in the
workbook). Re-test/partial items carry the git commit that addressed them.

**Status legend:** 🟢 ready-to-spec build · 🟡 needs a decision before spec · 🔵 non-build
(verify/re-test) · ⚪ scope-flag (may be FUTURE / reporting-module / commissioning).

Scope authority checked against `reference/MPP_Scope_Matrix.xlsx` per cluster.

---

## Spec A — Operation Template Draft/Published lifecycle 🟢

### FAT-OQ-030 — Operation template versioning (Op Templates & Quality Specs)
- **Expects:** creating a new template version follows the Draft/Published/Deprecated lifecycle; prior version retained.
- **Current:** `Parts.OperationTemplate` has only `VersionNumber` + `DeprecatedAt` — it never received the publish retrofit that `RouteTemplate` and `Bom` got in `sql/migrations/versioned/0007_bom_and_route_publish.sql:48-61`. `R__Parts_OperationTemplate_CreateNewVersion.sql:93-106` clones to `Version+1` and it is **immediately live** (no `PublishedAt`). No `OperationTemplate_Publish` proc, no Publish button/badge in the editor (`MPP_Config/.../Parts/OperationTemplates/view.json`).
- **Why fail:** the "prior version retained" half works; the Draft/Published lifecycle half is entirely absent — "broken" per the tester.
- **Proposed fix (mirror the RouteTemplate pattern exactly):**
  1. Versioned migration: `ADD PublishedAt DATETIME2(3) NULL`; **backfill existing non-deprecated rows `PublishedAt = CreatedAt`** so current routes keep resolving.
  2. New `Parts.OperationTemplate_Publish` proc (clone `R__Parts_RouteTemplate_Publish.sql`), audited per our ConfigLog convention; optional `_DiscardDraft`.
  3. `CreateNewVersion` leaves the clone a Draft (`PublishedAt` NULL); prior published version stays active until publish.
  4. `Get`/`List` surface `PublishedAt`; resolver `OperationTemplate_GetForRouteRole` + editor `getVersionsForCode` gate "active" on `PublishedAt IS NOT NULL` so a Draft never leaks into execution.
  5. Editor: Publish button + Draft/Published badge (mirror RouteTemplate editor); `OperationTemplate.publish(id)` entity method + `parts/OperationTemplate_Publish` NQ.
  6. Extend `sql/tests/0009_Parts_Process/010_OperationTemplate_crud.sql` with Draft→Publish→new-Draft-version→prior-retained assertions.
- **Explicitly OUT of scope:** the `ufn_OperationTemplateForLotRole` resolver convergence and the two Assembly latent bugs (AssemblyIn no checkpoint / AssemblyOut no template) — those stay in the PROJECT_STATUS TODO.
- **Effort:** small. Self-contained, Config-side.

---

## Spec B — Lineside inventory caps 🔵 validation only (build cancelled) + 🟡 ITM-050 clarify

### FAT-CC-060 — Lineside inventory cap / LinesideLimit (Container Configs)

**FEEDBACK:** this FAT item is tottally incorrect. lineside inventory is ment to protect too many of a single part to be put into inventory, NOT A LOCATIONS CAP. that would require balancing all sorts of stuff.so rather than making location based inventory cap, we do it from the part side. so validate that that works rather than chasing this down.



- **Expects (FAT wording):** scan-in rejected when lineside pieces across all items + incoming qty exceed a Cell cap.
- → **RESOLUTION (per feedback): the FAT premise is wrong — cancel the LinesideLimit build.** Lineside protection is a **per-part** cap (don't over-stock a single part), which is exactly `Parts.Item.MaxParts`, already enforced per-location at scan-in in `Lot_MoveToValidated:199-221`. A location-wide all-items cap is explicitly NOT wanted (would force cross-item balancing).
- **Revised action (no build):** **validate** that the part-side `MaxParts` cap rejects a lineside scan-in that would exceed it — identical to CC-050. Fold CC-060 into that one regression check. Drop the `LinesideLimit` attribute / aggregation / enforcement work entirely.
- **Effort:** none (validation only). Spec B is no longer a build.

### FAT-CC-050 — Per-item per-location piece cap 🔵
- **Already shipped:** enforced in `Lot_MoveToValidated:199-221` since Arc 2 Phase 4; `b36fe536` added it to the `Lot_Create` Received path too. Fold into Spec B as a **regression check only** — no build.

### FAT-ITM-050 — Max LOT size reasonability 🟡
- **FEEDBACK:**
- **Expects:** entry blocked when piece count exceeds the part's Max LOT Size.
- **Current/why:** tester note conflates `MaxParts` (per-location cap, enforced) with `MaxLotSize`/`PartsPerBasket` (basket capacity per LOT, `Parts.Item`). Need to confirm whether `MaxLotSize` is enforced at LOT creation piece-entry.
- **Proposed fix:** verify `Lot_Create`/die-cast entry against `MaxLotSize`; if unenforced, add a reasonability guard at piece-count entry (warn/block per the part's `MaxLotSize`). Small — **but confirm the intended field first** (this may be a re-test of CC-050 rather than new work). Decide before spec.

---

## Spec C — Machining defect/reject capture 🟢

### FAT-MACH-140 — Machining production event / RejectEvent per defect code (Machining)
- **Expects:** entering defect codes + reject quantities writes a `Workorder.RejectEvent` row per code.
- **Current:** Machining captures **zero** defect data. `MachiningOut_Mint` and `MachiningIn_RecordPick` write no rejects; no Machining view has a scrap surface (grep of ShopFloor views confirms).
- **Proposed fix (mechanical port of the Trim OUT scrap feature shipped last week):**
  1. Add `@ScrapLinesJson` to `MachiningOut_Mint` + pre-txn validations (ISJSON, qty>0, active DefectCode) + inline `INSERT … Workorder.RejectEvent … SELECT … FROM @Scrap` — copy verbatim from `R__Workorder_TrimOut_Record.sql:106-157,351-355`. Do **not** call the shared `RejectEvent_Record` (would double-decrement + nest INSERT-EXEC).
  2. Add `:scrapLinesJson` to `workorder/MachiningOut_Mint/query.sql`.
  3. `BlueRidge.Workorder.Machining.mint` JSON-encodes `scrapLines` (one line, mirror `TrimOut/code.py:29`).
  4. `MachiningOutSplit` view: `scrapLines`/`defectOptions` custom props, dropdown bound `getForDropdown("MachiningOut")` (resolves to `MachiningAssembly` category + plant-wide), flex-repeater + 4 handler methods — direct port of `TrimBody`.
  5. Tests mirroring `0024_.../050_TrimOut_Record_validation.sql`.
- **Design decisions (recommended):** scrap charges to the **source casting LOT** (the LOT being decremented); `ProductionEventId = NULL` — matches Trim and die-cast.
- **Effort:** small-medium (every piece copies a file already in the tree).

---

## Spec D — Print/label reliability & shipping-label content 🟢 (one coherent subsystem)

These four are one subsystem gap — treat as a single spec, not four.

→ **Finding (answers the ZPL question in the feedback):** two label paths, and they differ. **LTT labels are already DB-template-driven** — `Lots.LabelTemplate.ZplBody` holds the active ZPL with `{Placeholder}` tokens, resolved by `LotLabel_Print`/`Reprint` (`0021_arc2_phase2_lot_lifecycle.sql:183-195`). **The shipping label is hardcoded** — `ShippingDispatcher._renderZpl:30-34` is an inline minimal ZPL (AIM Shipper barcode only). **Holistic fix: bring the shipping label onto the same `LabelTemplate` pattern** — a shipping `LabelTypeCode` row with placeholder tokens rendered by a proc, not fields hardcoded in Python. Editable without code changes; consistent with LTT.

→ **Honda shipping-label field mapping (per feedback), authored as `{Placeholder}` tokens:** part number ← `Item.PartNumber` (config tool; matches AIM part) · description ← `Item.Description` (config tool) · DC part level ← die rank · MFG lot number ← AIM minted serial · bottom serial field ← **first 8 digits UNKNOWN (investigate) + last 8 = AIM serial**. Two open investigations the spec must resolve: the exact bottom-serial composition (first 8), and confirming the die-rank → "DC part level" mapping.

### FAT-ENV-170 / FAT-LBL-150 — Async print dispatch + retry
- **FEEDBACK:** this matches up with was is currently there to the best of my knowledge.  I believe the gateway async is a good idea.  I am not sure what the current system does to produce the zpl files.  I am not sure if they are hard coded or not.  
- **Expects:** label dispatch is Gateway-async (per FDS-01-014 external-interface pattern) with 3 attempts / 2s gap and a failure-gateway sweep + terminal banner.
- **Current:** `LotLabel.printLabel` / `ShippingDispatcher.dispatch` are **synchronous raw-TCP** with a single endpoint re-resolve retry (`BlueRidge/Lots/LotLabel/code.py:148-171`); `PrintFailureGateway.sweepTick/broadcastTick` are **skeleton no-ops** (`.../PrintFailureGateway/code.py:18-29`). `ARC2_FDS_CONFORMANCE.md:143` self-flags "dispatch sync not sendRequestAsync (006a)".
- **Proposed fix:** move dispatch to the Gateway-async pattern we already use for AIM (`ShippingDispatcher` → async worker), 3× retry w/ backoff, mark `PrintFailedAt`, implement the `PrintFailureGateway` sweep + terminal banner. Reuse the AIM `InterfaceLog` + async-dispatch idiom (FDS-01-014).
 
### FAT-LBL-060 — Shipping label ZPL persistence
- **FEEDBACK:** I believe adding a column makes sense, as mentioned above, I do not know how it is currently done.
- **Expects:** rendered ZPL content tracked on the shipping-label record.
- **Current:** `Lots.ShippingLabel` (`0028_arc2_phase6_assembly.sql:109-131`) has no `ZplContent` column; no proc persists rendered ZPL.
- **Proposed fix:** add `ZplContent NVARCHAR(MAX) NULL`; capture the rendered payload at dispatch time (parallels how `LotLabel` records its row). ASCII-only ZPL per our seed/payload rule.
 
### FAT-LBL-050 — Shipping label content (Honda fields)
- **FEEDBACK:** the part number comes from the part number in the config tool, this should match up with a part number from AIM.  The description will also come from the description field of the config tool.  the DC part level will come from the die rank I believe.  the MFG lot number will the the minted serial from AIM, the serial field at the bottom needs to be investigated.  the first 8 digits are unknown but the last 8 are the AIM serial.
- **Expects:** shipping label carries part number, quantity, and Honda-required fields.
- **Current:** `ShippingDispatcher._renderZpl` (`code.py:30-34`) builds a minimal label with **only** the AIM Shipper ID Code-128 barcode.
- **Proposed fix:** extend the ZPL builder to include part number, quantity, and the Honda fields (from the AIM interface contract + `reference/` label templates). Confirm exact field set with the label template spec.
- **Effort (Spec D whole):** medium. In scope (Integrations→Shipping/Printers "Included"). One spec covering all four.

## Spec E — Config-app AD authentication & attribution integrity 🟡/🟢
- **FEEDBACK:** this will happen through ignitions built in project authentication. NO NEED TO TOUCH THIS with the exception of USR-090, that one is a GO
### FAT-USR-070 — Interactive user AD auth (Config Tool login) — CLOSED (no build)
### FAT-USR-160 — Screen-level security — CLOSED (no build)
- → **RESOLUTION (per feedback):** handled by **Ignition's built-in project authentication** — no code work. Configure the project's identity provider / security levels; these pass via platform auth, not our session model. Removed from build scope.

### FAT-USR-090 — Deprecated initials blocked 🟢
- **Expects:** unknown **and deprecated** initials rejected at presence sign-in.
- **Current:** unknown initials are blocked (`AppUser.resolveForPresence` → valid=False), but **deprecated** initials are not — `R__Location_AppUser_GetByInitials.sql:36-45` returns deprecated rows unfiltered and `resolveForPresence` (`AppUser/code.py:169-179`) marks any found row valid without a `DeprecatedAt` check.
- **Proposed fix:** filter `DeprecatedAt IS NULL` in the presence-resolution path (SQL, per "business rules in SQL not Python"). **Genealogy-critical** (Honda attribution) — small but high value. Could ship standalone ahead of the AD-gate decision.
- **Effort:** USR-090 tiny; USR-070/160 medium pending the auth-surface decision.

---

## Spec F — Quality hold gaps 🟡
- **FEEDBACK:** I would like to allow a scrap event to occur against a held lot, rather than splitting the lot, simply register scrap against the lot rather than spliting it. and it acomplishes the same thing, in the same fassion that scrap is recorded throughout the application. override the FRS and FDS on this one.
### FAT-QH-150 — Partial disposition of a held LOT
- **Expects (FAT wording):** split a held LOT, then dispose the child.
- **Current:** `R__Lots_Lot_Split.sql:238-250` rejects splitting a held LOT; `Lot_UpdateStatus` allows only Good→Closed.
- → **RESOLUTION (per feedback): do NOT split — register a scrap event directly against the held LOT**, using the same `RejectEvent` + qty-decrement mechanism scrap uses everywhere else in the app. No split, no hold release. **Override FRS/FDS on this one.**
- **Proposed fix:** permit the scrap path through the hold guard so a `RejectEvent`-style scrap can be recorded against a `BlocksProduction=1` LOT, decrementing the LOT qty as recorded scrap does elsewhere. Reuse the existing scrap/RejectEvent pattern — no `Lot_Split`, no split-then-scrap. Small.

### FAT-QH-170 — Container hold integration alert
- **FEEDBACK:** 
- **Expects:** holding a LOT alerts about associated containers.
- **Current:** `R__Quality_Hold_Place.sql` does no container-association lookup; HoldManagement view shows no such notice. FDS-08-007 states it as a **SHOULD** — unimplemented.
- **Proposed fix:** on hold-place, look up associated containers and surface an advisory in the HoldManagement view. Low effort; SHOULD-level, so schedule accordingly.

---

## Spec G — Serialized MIP commissioning & vision-inspection escalation — ⛔ HELD (per feedback: do not spec; detail retained for later)
- **FEEDBACK:** HOLD ON THIS SPEC ALTOGETHER
Scope: Serialization is "Included / Expanded (two lines)" and PLC OPC-UA (cameras/scales) is "Included" — so this is in-scope, but heavily commissioning-dependent.

### FAT-PLC-020 / FAT-PLC-030 — Serialized MIP touch points + transaction flow 🔵/🟢
- **Current:** the watcher code is **complete and the gateway trigger is enabled** (`SerializedMipWatcher`, `PlcWatcher.dispatch`, `SerializedPart_Mint`, `TrayDataReady` tag-change enabled with the `5G0_A1/A2` paths). Not hardware-gated. Blocked only on: **no `TerminalPlcDevice` mapping row is seeded** for `5G0_A1` (only manual live inserts exist), a running `MPP_Sim` device, and a LOT queued at the terminal; the sim acceptance pass was never *recorded*.
- **Proposed fix:** (1) **commit a `TerminalPlcDevice` seed** for the 5G0 serialized stations so a reset DB resolves without manual inserts; (2) a documented simulator acceptance procedure (`/dev/sim/plc`) to record the pass. Caveat: serialized-FG-LOT attribution ("A4") is deliberately deferred — the mint attributes to the front open LOT, which still satisfies the FAT wording.

### FAT-PLC-120 / FAT-PLC-130 — Consecutive-fail escalation + failure-type branching
- **Expects:** a 10-consecutive-fail escalation state machine (leader escalation, supervisor badge, resume-elevation) and failure-type branching (wrong-part immediate flag / wrong-orientation stop-no-escalate / disposition counts / barcode-mis-scan-no-stop).
- **Current:** unwritten — `TrayInspectionWatcher` only does a per-event line-stop; `notes/2026-07-09_fds-gap-audit.md:32-33` explicitly logs the escalation state machine as unwritten design (FDS-10-010).
- **Proposed fix:** design + build the escalation state machine (consecutive-fail counter on the station/line, `LeaderEscalationFlagged`, supervisor-badge resume via our elevation model) and the failure-type branch matrix. Real design work — its own spec. **Scope-flag:** confirm this is MVP vs commissioning-phase.

### FAT-PLC-220 / FAT-PLC-230 — Confirmation method + dual-source agreement
- **Expects:** a `ConfirmationMethod` LocationAttribute (Vision/Barcode/Both) seeded + readable, and a dual-source agreement gate that withholds the production event until both sources agree.
- **Current:** `ConfirmationMethod` is **not seeded anywhere** in `sql/` (zero hits; contrast the seeded `RequiresCompletionConfirm`); no agreement gate exists.
- **Proposed fix:** seed a `ConfirmationMethod` `LocationAttributeDefinition` (mirror `RequiresCompletionConfirm` in `0020` + `011` seed); add the dual-source agreement check in the non-serialized/serialized watcher path. **Scope-flag** as above.
- **Effort (Spec G):** large + commissioning-dependent. Recommend splitting: PLC-020/030 (seed + sim procedure — small, do now) vs PLC-120/130/220/230 (escalation/vision — its own scoped spec, confirm MVP first).

---

## Spec H — Traceability reporting & Honda export — ⛔ HELD (per feedback: waiting on reporting-module content from Jacques)
- **FEEDBACK:** you need to learn how to work with the reporting module yet. Ill build some content, so you have to wait until ive got that for you on this one.
Scope note: genealogy/shipping **reports/exports** likely belong to the Ignition Reporting Module (per FDS §12.1), which is **not part of the file-synced repo**. `ARC2_FDS_CONFORMANCE.md` marks all of these "Missing." Confirm whether these are coded exports or reporting-module deliverables before speccing as code.

### FAT-TRC-100 — Genealogy report export

- **Expects:** printable/exportable genealogy (Excel/PDF).
- **Current:** on-screen `GenealogyViewer`/`GlobalTrace` exist; **no export** (grep finds none). FDS-05-018 / FDS-12-014 Missing.
- **Proposed fix:** add an export from the composed genealogy tree — either a coded Excel/PDF export or a Reporting Module report. **Decide mechanism.**

### FAT-TRC-310 — Trace output + Honda export
- **FEEDBACK:** we dont know what this looks like. formulate an email to MPP requesting an example
- **Expects:** upstream/downstream trace with Honda-format PDF/CSV export.
- **Current:** `GlobalTrace` composes `Lot_GetGenealogyTree` + events on screen; **no Honda-format export**. FDS-12-014 Missing.
- → **ACTION (per feedback):** we don't know the target format — draft an email to MPP requesting an example. Drafted at `notes/2026-08-07_mpp-email-honda-trace-export.md`. Spec deferred until the example arrives.

### FAT-TRC-280 — Shipping history report

- **Expects:** a shipping-history report/proc.
- **Current:** none — `Container_Ship` only flips status + audits. FDS-12-011 Missing.
- **Proposed fix:** `Container_ListShipped` read proc + a report/view (or Reporting Module report).

### FAT-TRC-170 — Post-sort merge gate
- **FEEDBACK:** we consume parts just like we would at assembly out, rather here, we consume and mint the same part, new lot.
- **Expects (FAT wording):** `Lot_Merge` gated on post-sort/inspection completion.
- → **RESOLUTION (per feedback): sorting is a same-part consume-mint, not a merge gate.** Model it like Assembly OUT — consume the input LOT and mint a NEW LOT of the **same** part (new identity), via the terminal-mint / `OperationRoleKind=ConsumeMint` machinery ([[project_mpp_terminal_mint_model]]), **not** `Lot_Merge`. Its own future sort-station spec; not immediately buildable (sort station unbuilt).
- **Effort (Spec H):** HELD — reporting items wait on the reporting module; TRC-310 waits on the MPP example; TRC-170 is a future sort-station consume-mint.

---

## Closeout & re-test (non-build) 🔵

### FAT-CT-070 — Downtime reason-code seed load
- **Not a build.** Seed is 353/353, wired, schema-correct (`sql/seeds/031_seed_downtime_reason_codes.sql`). Needs a deploy-day `COUNT=353` + core-columns-non-null verification query **treating reason-type as nullable** (~301 rows NULL by design — settle wording with FAT owner) + fix stale `reference/seed_data/README.md` (660→353).

### Re-test — fix already landed in git this week (11 items)
Re-run these against the current build; the covering commit is cited. If they still fail, the fix is incomplete.

| TestID | Fix commit |
|---|---|
| FAT-RB-040 BOM version on lot | `d979aefb` + `b8298b0b` |
| FAT-CC-040 serialized flag on config | `1f15c8bd` |
| FAT-CT-050 die-cast defect filter | `5f87410a` + `ea9a01bb` |
| FAT-CT-060 machine-shop defect filter | defect-code OperationCategory series |
| FAT-USR-020 event attribution AppUserId | `e47d9f2d` |
| FAT-USR-060 shared presence re-confirm | `5ac5a4b1` |
| FAT-USR-120 per-action AD elevation | `5ac5a4b1` + `aa2c5ded` + `64e2268c` |
| FAT-USR-170 elevated controls gated | `64e2268c` + `5ac5a4b1` |
| FAT-TERM-040 terminal by IP | `aac8137c` |
| FAT-TERM-050 unrecognized-terminal gate | `aac8137c` (IP fix) |
| FAT-TRIM-090 Trim OUT double-checkout block | `34266c86` + `657f3e39` |

---

## Recommended spec decomposition for the fleet

| Spec | Covers | Status after feedback |
|---|---|---|
| A | OQ-030 | ✅ **GO** — build now (approved as-is) |
| B | CC-050 + CC-060 | 🔵 **validation only** — LinesideLimit build cancelled (part-side `MaxParts` already does this) |
| C | MACH-140 | ✅ **GO** — build now |
| D | ENV-170, LBL-050/060/150 | ✅ **GO** — build; shipping label onto `LabelTemplate` pattern + Honda field mapping; investigate bottom-serial composition |
| E | USR-090 only | ✅ **GO** — build (tiny); USR-070/160 CLOSED (Ignition built-in auth) |
| F | QH-150, QH-170 | ✅ **GO** — build; QH-150 = scrap-against-held-LOT (no split), override FRS/FDS |
| G | PLC-020/030/120/130/220/230 | ⛔ **HELD** altogether |
| H | TRC-100/280/310/170 | ⛔ **HELD** (reporting module pending); TRC-310 → email to MPP; TRC-170 → future same-part consume-mint |
| ITM-050 | Max LOT size | 🟡 clarify field (`MaxLotSize` basket vs `MaxParts` location) — no direction given yet |
| — | CT-070, 11 re-tests | 🔵 verify / re-test |

**GO for spec-writing now: A, C, D, E (USR-090), F.** Recommended sequence **A → C → E → F → D** (D last — it carries the bottom-serial investigation). ITM-050 still needs your field call.
