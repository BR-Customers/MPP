# Arc 2 (Plant Floor) — FDS Conformance Matrix

**Reviewer:** Claude (Opus 4.8) · **Date:** 2026-06-26 · **Branch:** `hunter/explore`
**Method:** Every plant-floor FDS requirement (FDS v1.4) checked against the actual code (procs `sql/migrations/repeatable/`, NQs, views, entity scripts, gateway timers, seeds). Status verified by locating the implementing artifact ("Built") or grepping to confirm absence ("Missing"). Bug-level detail and `file:line` evidence live in the companion **`ARC2_REVIEW_FINDINGS.md`** (cited as `P#-#`).

**Status key:** **Built** = implemented + conformant · **Partial** = incomplete / server-only / UI-only · **Divergent** = implemented but deviates from the requirement text · **Missing** = no implementing artifact · **N/A** = FUTURE/CONDITIONAL (out of MVP build scope) · **Verify** = needs a live-session/seed check.

---

## Rollup

| FDS § | Area | Built | Partial | Divergent | Missing | N/A | Verify |
|---|---|---|---|---|---|---|---|
| §2 | Terminals / cell context | 5 | 0 | 0 | 0 | 1 | 1 |
| §4 | Identity / presence / elevation | 6 | 3 | 1 | 0 | 0 | 0 |
| §5 | LOT lifecycle & genealogy | 28 | 8 | 3 | 1 | 0 | 0 |
| §6 | Production execution | 19 | 5 | 1 | 3 | 1 | 0 |
| §7 | Container & shipping | 8 | 13 | 3 | 0 | 0 | 0 |
| §8 | Quality & holds | 9 | 3 | 1 | 3 | 3 | 0 |
| §9 | Downtime & shift | 8 | 3 | 0 | 1 | 1 | 2 |
| §10 | PLC / OPC / MIP / line-stop / CRT | 2 | 1 | 0 | 10 | 0 | 0 |
| §11 | Audit & logging | 10 | 1 | 0 | 0 | 0 | 0 |
| §12 | Reporting / trace | 0 | 1 | 0 | 5 | 0 | 0 |
| §16 | Identifier sequences | 2 | 1 | 0 | 0 | 0 | 0 |

**Headline:** The **proc/SQL data layer is strongly conformant** (LOT lifecycle, genealogy, minting, holds, audit, container closure, AIM claim). Conformance collapses in three families: **§10 PLC/MIP/line-stop/CRT (10/13 Missing)**, **§12 reporting/Global-Trace (5/6 Missing)**, and **§8 inspection capture (3 Missing)** — i.e. the unbuilt Phase 9 + the serialized-MIP commissioning layer. Plus discrete data defects (shipping `LotMovement`, double-ship, defect-code seed) detailed below.

---

## §2 — Plant Model & Terminals

| Req | Keyword | Status | Evidence | Note |
|-----|---------|--------|----------|------|
| FDS-02-008 Terminal as Cell kind | SHALL | Built | `LocationTypeDefinition` DefId 7 Terminal; IP/printer/HasPrinter attrs; `Terminal_GetByIpAddress` | — |
| FDS-02-009 Cell context (Terminal+Location FKs; shared scan/dropdown) | SHALL | Built | events carry `TerminalLocationId`+`LocationId`; dedicated=`zoneLocationId`; shared=`Terminal_ListContextCells` | F4 (verify seed parenting) |
| FDS-02-010 Behavior by assigned view flavor | SHALL · MVP | Built | DieCast/Trim Shared+Dedicated views; `session.custom.presence.policy` strict/confirm | strict-policy behavior incomplete → see FDS-04-003 (F2) |
| FDS-02-011 Cell-context change rules | SHALL | Built | dedicated read-only; shared via selectors only | shared context-change doesn't re-prompt initials (F2) |
| FDS-02-012 Part↔Cell eligibility (Direct ∪ BOM) | SHALL | Built | `ItemLocation_CheckEligibility`, `v_EffectiveItemLocation`; enforced in `Lot_MoveToValidated` | — |
| FDS-02-013 Tablet-friendly Die Cast | SHALL | Verify | `pf-*` 44px touch design | needs Designer/device smoke |
| FDS-02-014 RFID-ready labels | FUTURE | N/A | — | correctly not built |

## §4 — User Identity, Presence & Elevation

| Req | Keyword | Status | Evidence | Note |
|-----|---------|--------|----------|------|
| FDS-04-001 Two AppUser classes | SHALL | Built | Operator (AdAccount NULL + Initials) vs Interactive (AD+role); `AppUser` schema | — |
| FDS-04-002 First action → presence | SHALL | Built | `InitialsEntry` popup + work-view onStartup gates | — |
| FDS-04-003 Presence follows flavor | SHALL · MVP | Partial | dedicated `confirm` 30-min built; **shared `strict` idle + context-change re-prompt UNBUILT** | **F2 🟠** |
| FDS-04-004 Interactive via AD; operators not in AD | SHALL | Built | `AppUser.authenticateAd`; `_validateAdCredentials` seam | AD IdP wired at deploy (default-deny) |
| FDS-04-005 Initials field pre-populated/override/resolve/block | SHALL | Built | `InitialsField`, `resolveForPresence` blocks unknown | — |
| FDS-04-006 30-min re-confirm "Operate as [XY]?" | SHALL | Divergent | `PresenceIdleWatcher` (`>=30`) + `IdleReconfirmModal` | 30 is **hard-coded**; FDS says SHALL be a Config-Tool setting |
| FDS-04-007 Per-action AD elevation | SHALL | Partial | `AppUser.elevate` + `ElevationModal` exist | **wired into ZERO views** (P7-1, P3-5, P6-6); `_validateAdCredentials` default-deny |
| FDS-04-008 Roles → AD groups | SHALL | Built | `AppUser_GetRoles` + Ignition IdP | deploy-config |
| FDS-04-009 Shop-floor no-auth access; elevated controls gate | SHALL | Partial | presence-only access built | elevated controls don't trigger elevation (P7-1) |
| FDS-04-010 Operator AppUser admin (unique initials, soft-delete) | SHALL | Built | Arc-1 config; `AppUser_Create`; `DeprecatedAt` | — |

## §5 — LOT Lifecycle & Genealogy *(+ §16 Identifiers)*

| Req | Keyword | Status | Evidence | Note |
|-----|---------|--------|----------|------|
| FDS-05-001 LOT uniqueness | SHALL | Built | `UQ_Lot_LotName` + `Lot_Create` pre-check | — |
| FDS-05-002 LTT pre-printing (no pre-register) | SHALL | Built | `Lot_Create @LotName` D4 path | — |
| FDS-05-003 LOT attributes | SHALL | Built | `Lots.Lot` + `Lot_Create` INSERT | — |
| FDS-05-004 Manufactured (Die Cast) create | SHALL | Partial | `Lot_Create` + `DieCastBody` | no ProductionEvent checkpoint (P3-1); no inline elevated tool-edit (P3-5) |
| FDS-05-005 Received create + Initial print | SHALL | Built | `ReceivingDock` + `LotLabel_Print` | — |
| FDS-05-006 Off-site received | SHALL | Partial | `LotOriginType` ReceivedOffsite seeded | **no UI/workflow built** (origin type only) |
| FDS-05-007 Movement tracking | SHALL | Built | `Lot_MoveToValidated` (LotMovement + CurrentLocationId) | — |
| FDS-05-008 Movement workflow | SHALL | Built | `MovementScan` + `Lot_MoveToValidated` | implicit-movement clause not separately evidenced |
| FDS-05-009 Machining-OUT sub-LOT split | SHALL | Divergent | `MachiningOut_RecordSplit` (N-way proc) | UI hardcodes 2 (P5-1); mints vs "scan fresh LTT" (P5-11); no child labels; UJ-03 pending |
| FDS-05-010 Uneven split | SHALL | Partial | proc enforces Σ=parent | "closest even" + >2 is UI; UI=2 (P5-1) |
| FDS-05-011 Split genealogy permanence | SHALL | Built | `ParentLotId` + Split edge + closure | — |
| FDS-05-012 Merge capability | SHALL | Built | `Lot_Merge` | — |
| FDS-05-013 Status codes | SHALL | Built | `LotStatusCode` Good/Hold/Scrap/Closed + BlocksProduction | — |
| FDS-05-014 Status transition rules | SHALL | Partial | `Lot_UpdateStatus` (Good→Closed); Hold↔Good via Hold procs | **GOOD→SCRAP / HOLD→SCRAP / HOLD→CLOSED not implemented** (no proc sets Scrap) — P9-2 |
| FDS-05-015 Status history | SHALL | Built | `LotStatusHistory` | — |
| FDS-05-016 Genealogy graph | SHALL | Built | `LotGenealogy` + RelationshipType | — |
| FDS-05-017 Bidirectional query | SHALL | Built | `Lot_GetGenealogyTree`/`GetParents`/`GetChildren` | UI drill-down clicks dead (P2-1) |
| FDS-05-018 Genealogy report | SHALL | Partial | `GenealogyViewer` + tree proc | LotName-only resolve (P9-3); **no printable export** (P9-4) |
| FDS-05-019 Label print tracking | SHALL | Built | `LotLabel_Print` INSERT | — |
| FDS-05-020 Print reasons | SHALL | Built | `PrintReasonCode` (5 seeded) | em-dash mojibake (P4-7) |
| FDS-05-021 Attribute-change log | SHALL | Built | `LotAttributeChange` + writers | — |
| FDS-05-022 Sublot pattern | SHALL | Built | `MachiningOut_RecordSplit` children | — |
| FDS-05-024 Sublot labels (parent ref) | SHALL | Built | `LotLabel_Print` `{ParentLotNumber}` | — |
| FDS-05-025 Post-sort merge gate | SHALL | **Missing** | `Lot_Merge` validations | **no sort/inspection-completion gate** (sort infra unbuilt, P9-1) |
| FDS-05-026 Part-number match | SHALL | Built | `Lot_Merge` ItemId reject | — |
| FDS-05-027 Die-rank compatibility | SHALL | Built | `Lot_Merge` `DieRankCompatibility` + override | — |
| FDS-05-028 Quality-status gating | SHALL | Built | `Lot_Merge` non-Good reject | — |
| FDS-05-029 Machining is FIFO not merge | SHALL | Built | `Lot_GetWipQueueByLocation` + Consumption edge | FIFO NULL-sort edge (P4-6) |
| FDS-05-030 Post-merge NULL tool/cavity | SHALL | Built | `Lot_Merge` output NULL | — |
| FDS-05-031 Computed quantities | SHALL | Divergent | `v_LotDerivedQuantities` + B5 materialized cols | B5 materialization **contradicts** "SHALL NOT materialize"; formula differs (OI-35 supersedes — reconcile FDS) |
| FDS-05-032 Partial start/complete | SHALL | Divergent | checkpoint model | no independent Start/Complete events (FDS-03-017a supersedes; "verify before rollout") |
| FDS-05-033 Trim→Machining rename | SHALL | Partial | `MachiningIn_PickAndConsume` | confirm shows src not dst (P5-2); mints LTT (P5-11) |
| FDS-05-034 Die-cast tool+cavity required | SHALL | Built | `Lot_Create` validation | — |
| FDS-05-035 Tools SoR on Lot | SHALL | Built | `Lot.ToolId/ToolCavityId`; PE has none | — |
| FDS-05-036 Lazy operator-driven create | SHALL | Built | `Lot_Create` single invoke | — |
| FDS-05-037 LOT close semantics | SHALL | Partial | container auto-close; component closes inlined | no generic atomic "Complete + Move" proc |
| FDS-05-038 Pausable LOT | SHALL | Built | `LotPause_*` + `PauseEvent` + indicator | PausedAt UTC (P2-4); terminal not threaded (P2-7) |
| FDS-16-001 IdentifierSequence table | SHALL | Built | `Lots.IdentifierSequence` MESL/MESI seed | — |
| FDS-16-002 `IdentifierSequence_Next` | SHALL | Built | atomic ROWLOCK/UPDLOCK/HOLDLOCK, rollover raise, single set | — |
| FDS-16-003 Cutover-day seeding | SHALL | Partial | provisional dev seed | exact cutover `+10,000` value is a deploy-day step (owed) |

## §6 — Production Execution

| Req | Keyword | Status | Evidence | Note |
|-----|---------|--------|----------|------|
| FDS-06-001 Die Cast screen | SHALL | Built | `DieCastBody`/`DieCastEntry/*` | P3-6/P3-7 |
| FDS-06-002 Pre-record validation | SHALL | Built | `Lot_Create`+event procs (status/eligible/max) | — |
| FDS-06-003 ProductionEvent on submit | SHALL | Partial | `ProductionEvent_Record` | doesn't update PieceCount (D2); not called by die-cast (P3-1); `ProductionEventValue` dropped (P3-4) |
| FDS-06-004 Trim IN | SHALL | Built | `MovementScan`→`Lot_MoveToValidated` | handoff msg mismatch (P4-2) |
| FDS-06-005 Trim weight count estimate | SHALL | **Missing** | grep Trim views → none | scale read/theoretical-count/accept-keep/log all unbuilt |
| FDS-06-006 Trim OUT whole-move | SHALL | Divergent | `TrimOut_Record` | `shotCount:0` raw trips guard → **Trim OUT blocked** (P4-1 🔴) |
| FDS-06-007 Machining IN FIFO + rename | SHALL | Built | `MachiningIn_PickAndConsume` | P5-2/P5-3/P5-11 |
| FDS-06-008 Machining OUT branch | SHALL | Partial | RecordSplit + AutoComplete + `MachiningPlc` | UI 2-way (P5-1); watcher unfiltered queue[0] (P5-4) |
| FDS-06-009 Reject on submit | SHALL | Built | `RejectEvent_Record` | — |
| FDS-06-010 Serialized MIP per-part | SHALL | Partial | leaf procs only; `AssemblyPlc._handlePiece` no-op | per-piece flow unbuilt (P6-5) |
| FDS-06-011 BOM material verification + override | SHALL | Partial | `ConsumptionEvent_RecordWithBomCheck` + `MaterialOverrideConfirm` | no AD elevation (P6-6); not wired (P6-5) |
| FDS-06-012 Hardware interlock bypass | SHALL | Partial | `ContainerSerial_Add` persists `HardwareInterlockBypassed` | NoRead path unbuilt (P6-5) |
| FDS-06-013 Non-serialized tray fill | SHALL | Built | `ContainerTray_Close` | HOLD/Scrap source consumable (P6-1) |
| FDS-06-014 Tray validation + accumulation | SHALL | Built | `ContainerTray_Close`+`Container_Complete` | pre-txn race (P6-7); NULL-config skip (P6-8) |
| FDS-06-015 ProductionEvent append-only | SHALL | Built | no update/delete proc | — |
| FDS-06-016 PE fields | SHALL | Built | `ProductionEvent` columns | — |
| FDS-06-017 Reject not required | SHALL | Built | `RejectEvent_Record` optional | — |
| FDS-06-018 RejectEvent fields | SHALL | Built | `Workorder.RejectEvent` | — |
| FDS-06-019 Two scrap patterns | SHALL | Built | inline reject (A) + `Lot_Split`→Scrap (B) | — |
| FDS-06-023a Scrap source discriminator | SHALL · MVP | Built | `ScrapSource` + `ProductionEvent.ScrapSourceId` | NULL-vs-NOTNULL not strictly enforced |
| FDS-06-020 ConsumptionEvent | SHALL | Built | `ConsumptionEvent_*` | — |
| FDS-06-021 Consumption genealogy | SHALL | Built | `LotGenealogy` Consumption rows | — |
| FDS-06-022 Auto-generate Production WO | SHALL | **Missing** | `WorkOrder` table never `INSERT`ed | unpopulated placeholder |
| FDS-06-023/024/025 WO schema/op/types | SHALL | Built (schema) | `WorkOrder`/`WorkOrderOperation` + `0013` type collapse | never instantiated (06-022) |
| FDS-06-026 Maintenance WO | FUTURE | N/A | nullable `WorkOrder.ToolId` hook | — |
| FDS-06-028 Auto-finish modes | SHALL · MVP | Partial | `RequiresCompletionConfirm` + `Container_Complete` gate | no WO cumulative count/weight close, no `CompletionConfirmed` observe |
| FDS-06-029 Tray-divisibility on WO close | SHALL · MVP | **Missing** | no WO-close proc | — |
| FDS-06-030 Live WO flag columns | SHALL · MVP | Built (schema) | camera/scale/weight/recipe/tray cols on `WorkOrder` | — |

## §7 — Container Management & Shipping

| Req | Keyword | Status | Evidence | Note |
|-----|---------|--------|----------|------|
| FDS-07-001 Container creation | SHALL | Partial | `Container_Open` (non-ser); serialized auto-create unwired (P6-5) | — |
| FDS-07-002 Status codes | SHALL | Built | Open/Complete/Shipped/Hold/Void seed | — |
| FDS-07-003 Serialized fill | SHALL | Partial | leaf procs; orchestration unbuilt (P6-5) | — |
| FDS-07-004 Non-serialized fill | SHALL | Built | `ContainerTray_Close`/`Container_Complete` | — |
| FDS-07-005 Container closure (1 txn) | SHALL | Built | `Container_Complete` atomic claim+label+status | dispatch sync not `sendRequestAsync` (006a) |
| FDS-07-006 Label content | SHALL | Partial | `ShippingDispatcher._renderZpl` | AIM barcode only; **Honda part/qty fields absent** |
| FDS-07-006a Print dispatch (GW-async) | SHALL · MVP | Partial | `ShippingDispatcher` | label state machine / retry / write-back sim/unbuilt |
| FDS-07-006b Print-failure sweep/banner | SHALL · MVP | Partial | timers + `PrintFailureGateway` | ticks no-op; banner not terminal-filtered (P7-11) |
| FDS-07-007 Label tracking | SHALL | Built | `ShippingLabel` + Void/Reprint | — |
| FDS-07-008 Label void | SHALL | Partial | `ShippingLabel_Void` (row kept, no pool return) | AIM void notify not invoked (P7-13) |
| FDS-07-009 Label reprint | SHALL | Built | `ShippingLabel_Reprint` (new row) | no AD gate (P7-1) |
| FDS-07-010 AIM local pool | SHALL | Partial | claim/topup/depth + provenance | topup loop sim (commissioning) |
| FDS-07-010a Empty-pool hard-fail | SHALL · MVP | Built | `Container_Complete` rejects pre-txn | — |
| FDS-07-010b Pool alarms | SHALL · MVP | Partial | `alarmTick` rising-edge | no auto-clear / IT notify / audit (P7-12) |
| FDS-07-010c Pool config | SHALL · MVP | Divergent | `AimPoolConfig_Update` | **no ordering CHECK + no ConfigLog audit** (P7-2, P7-3) |
| FDS-07-011 AIM hold notify | SHALL | Partial | `AimPoolGateway.placeOnHold` sim | not invoked by Hold_Place (P7-13) |
| FDS-07-012 AIM update (re-sort) | SHALL | Partial | `AimPoolGateway.update` sim | not invoked by SortCage (P7-8) |
| FDS-07-013 Shipping validation | SHALL | Partial | `Container_Ship` checks | **no AimShipperId valid check** (P7-5) |
| FDS-07-014 Ship confirmation | SHALL | Divergent | `Container_Ship` status→Shipped | **no LotMovement/CurrentLocationId** (P7-4 🟠 trace gap) |
| FDS-07-015 Container hold | SHALL | Partial | `Hold_Place @ContainerId` | AIM PlaceOnHold not invoked (P7-13) |
| FDS-07-016 Container hold release | SHALL | Divergent | `Hold_Release` → Complete | **shipped→hold→release re-shippable** double-ship (P7-7) |
| FDS-07-017 Sort Cage | SHALL · MVP-EXP | Partial | `SortCage_MigrateSerial` + history | LotMovement/new LTT/labels/void-old/AIM-update unwired (P7-8) |
| FDS-07-018 Sort Cage scope | (desc) | Built | holds + split | — |
| FDS-07-019 Sort Cage not a merge | SHALL NOT | Built | preserves `SerializedPart.LotId` | — |

## §8 — Quality & Hold Management

| Req | Keyword | Status | Evidence | Note |
|-----|---------|--------|----------|------|
| FDS-08-001 Hold placement | SHALL | Built | `Hold_Place` + HoldTypeCode seed | seed **drops PRECAUTIONARY**, adds EngineeringHold (divergent taxonomy) |
| FDS-08-002 Hold effect (BlocksProduction) | SHALL | Built | status→Hold + `Lot_AssertNotBlocked` | — |
| FDS-08-003 Hold release | SHALL | Built | `Hold_Release` | container path divergence (P7-7) |
| FDS-08-004 Hold without NCM | SHALL | Built | `HoldEvent.NonConformanceId` nullable | — |
| FDS-08-005 Partial disposition via split | SHALL | Built | `Lot_Split` | — |
| FDS-08-006 Bulk hold | SHALL | Built | `Hold.placeBulk` | — |
| FDS-08-007 Container hold integration | SHOULD | Built | `Hold_GetOpenByContainer` | advisory |
| FDS-08-007a Hold Management screen | SHALL · MVP-EXP | Partial | `HoldManagement` + `Hold_ListOpen` | Release "Use" dead (P7-6); no AD elevation (P7-1) |
| FDS-08-008 Quality spec mgmt | SHALL | Built | Arc-1 `QualitySpec_*` | — |
| FDS-08-009 Spec versioning | SHALL | Built | `QualitySpecVersion_*` | — |
| FDS-08-010 Spec attributes | SHALL | Partial | `QualitySpecAttribute_*` | dynamic inspection render missing (P9-1) |
| FDS-08-011 Inspection recording | SHALL | **Missing** | no QualitySample/Result table/proc/view | **P9-1 🔴** |
| FDS-08-012 Failed inspection (alert ≠ auto-hold) | SHALL | **Missing** | no capture path | P9-1 |
| FDS-08-013 Quality attachments | SHALL | **Missing** | no QualityAttachment | P9-1 |
| FDS-08-014 Sample triggers | SHOULD | N/A | `SampleTriggerCode` seed only | CONDITIONAL |
| FDS-08-015 Sample representative | (stmt) | N/A | — | CONDITIONAL |
| FDS-08-016 Defect-code mgmt | SHALL | Partial | table + Arc-1 editor | **~153 Appendix-E codes never seeded** → reject dropdown empty |
| FDS-08-017 Area filtering | SHALL | Divergent | `DefectCode_List @AreaLocationId` | consumer passes hardcoded `0` → matches nothing |
| FDS-08-018 NCM scope boundary | FUTURE | N/A | audit-seed only | discipline respected (P9-7) |

## §9 — Downtime & Shift

| Req | Keyword | Status | Evidence | Note |
|-----|---------|--------|----------|------|
| FDS-09-001 Manual downtime | SHALL | Partial | `DowntimeEvent_Start` | reason not Area+Type filtered (P8-2); machine from picker not terminal (P8-4) |
| FDS-09-002 PLC-triggered downtime | SHALL | Partial | `DowntimePlcWatcher` | sim/no-op until `_WATCH` configured (commissioning) |
| FDS-09-003 Open event prominent | SHALL | Built | `EndedAt NULL` + `getOpenByLocation` | list never refreshes (P8-1) |
| FDS-09-004 Append-only StartedAt | SHALL | Built | only EndedAt+reason mutable | — |
| FDS-09-005 Reason filter Area+Type, type-first | SHALL | **Missing** | hard-null filter, no type selector | P8-2 |
| FDS-09-006 ~660 reason codes seeded | SHALL | Verify | `reference/seed_data/downtime_reason_codes.csv` (353) | **confirm a migration loads them** (cf. defect-code seed gap 08-016) |
| FDS-09-007 Reason types (6 fixed) | SHALL | Built | `DowntimeReasonType` seed | — |
| FDS-09-008 Shift schedules | SHALL | Built | `ShiftSchedule` (Arc-1) | spreadsheet import = deploy |
| FDS-09-009 Shift instances, event-derived, no minutes | SHALL | Built | `Shift_Start/End`; toggle-per-break | — |
| FDS-09-010 No auto-split; open events span | SHALL | Built | `Shift_End` leaves open | — |
| FDS-09-011 OEE snapshot | FUTURE | N/A | — | — |
| FDS-09-012 Idempotent schedule import | SHALL | Built | Arc-1 | — |
| FDS-09-013 End-of-shift entry | SHALL | Partial | toggle-per-break + schedule durations | **±15-min window missing (P8-3); shared inline initials missing (P8-4); zero-break re-submittable (P8-8)** |
| FDS-09-014 Early-start acceptance | SHALL | Verify | `Shift_GetActive` | not specifically exercised |
| FDS-09-015 Shift-end summary | SHALL · MVP | Built | `ShiftEndSummary` + 3 reads + ack | PausedAt UTC (P8-7) |

## §10 — PLC/OPC, MIP, Line-Stop, CRT

| Req | Keyword | Status | Evidence | Note |
|-----|---------|--------|----------|------|
| FDS-10-001 MIP touch points | SHALL | **Missing** | tags in commissioning comment only; `_WATCH=[]` | P6-5 |
| FDS-10-002 Transaction flow | SHALL | **Missing** | `_handlePiece` no-op | P6-5 |
| FDS-10-003 AlarmMsg (low-inv/invalid/dup) | SHALL | **Missing** | grep → none | — |
| FDS-10-004 Non-serialized PLC disposition | SHALL | **Missing** | grep `PartDisposition` → none | — |
| FDS-10-005 Line-stop (vision/operator conflict) | SHALL | **Missing** | grep `LineStop`/`VisionPartNumber` → none | **safety-critical, absent** |
| FDS-10-006 OmniServer scale reads | SHALL | **Missing** | commissioning docstring only | compounds 06-005 |
| FDS-10-007 Barcode wedge + server validation | SHALL | Built | wedge inputs + server LTT/AIM format checks | — |
| FDS-10-008 Zebra ZPL dispatch | SHALL | Built | `LotLabel`/`ShippingDispatcher` raw-TCP 9100 + InterfaceLog | "configurable" only via proc edit |
| FDS-10-009 10-fail leader escalation | SHALL | **Missing** | grep `consecutive`/`LeaderEscalation` → none | — |
| FDS-10-010 Failure-type branching | SHALL | **Missing** | no line-stop handler | depends on 10-005 |
| FDS-10-011 Hold/CRT release | SHALL | Partial | `Hold_Release` (Quality path) | CRT path missing (P9-2); not AD-gated (P7-1) |
| FDS-10-012 CRT lifecycle | SHALL | **Missing** | `CrtActive` col never written; codes not seeded | **P9-2 🔴** |
| FDS-10-013 ConfirmationMethod Vision/Barcode/Both | SHALL · MVP | **Missing** | grep `ConfirmationMethod` → none | no attr/resolver/branching |

## §11 — Audit & Logging

| Req | Keyword | Status | Evidence | Note |
|-----|---------|--------|----------|------|
| FDS-11-001 Operation log | SHALL | Built | `Audit_LogOperation` (in-txn; B7 LotEventLog) | — |
| FDS-11-002 Config log | SHALL | Built | `Audit_LogConfigChange` | `AimPoolConfig_Update` omits it (P7-3) |
| FDS-11-003 Interface log | SHALL | Built | `Audit_LogInterfaceCall` | — |
| FDS-11-004 Failure log | SHALL | Built | `Audit_LogFailure` + browser | — |
| FDS-11-005 High-fidelity interface logging | SHALL | Partial | `IsHighFidelity` BIT | caller-hardcoded `True`; no per-system toggle |
| FDS-11-006 Event-type vocabulary | SHALL | Built | `LogEventType` seeds | — |
| FDS-11-007 Entity-type vocabulary | SHALL | Built | `LogEntityType` seeds | — |
| FDS-11-008 Code-string signatures | SHALL | Built | writers resolve code→id | — |
| FDS-11-009 Retention policy | SHALL | Built | `Partition_MaintainWindow` + timer | windows pending MPP IT (OI-35 B1) |
| FDS-11-010 BIGINT PKs | SHALL | Built | all audit tables | — |
| FDS-11-011 JDBC single-set/no-OUTPUT | SHALL | Built | upheld app-wide | strongest area |

## §12 — Reporting / Trace

| Req | Keyword | Status | Evidence | Note |
|-----|---------|--------|----------|------|
| FDS-12-009 In-process LOT tracking | SHALL | **Missing** | no real-time active-LOT report; dashboard tile stub (P8-11) | — |
| FDS-12-010 Hold status report | SHALL | Partial | `Hold_ListOpen` + HoldManagement | no duration-on-hold + export |
| FDS-12-011 Shipping history | SHALL | **Missing** | grep → no report/proc | Honda ASN reconciliation absent |
| FDS-12-012 Track tile | SHALL · MVP | **Missing** | no Track tile / Global Trace view | P9-3 |
| FDS-12-013 Trace input (multi-id resolve) | SHALL · MVP | **Missing** | `Lot_Search` LotName/Vendor/Part only | P9-3 |
| FDS-12-014 Trace output + Honda PDF/CSV | SHALL · MVP | **Missing** | no trace output / export | **P9-3/P9-4 — primary Honda deliverable** |

---

## Top MVP conformance gaps (consolidated)

**Unbuilt capability families (Phase 9 + commissioning layer):**
1. **§8 Inspection capture** (08-011/012/013) — no QualitySample/Result/Attachment.
2. **§10 PLC/MIP/line-stop/CRT** — 10/13 Missing: MIP handshake (10-001/002), AlarmMsg (10-003), non-serialized disposition (10-004), **line-stop + 10-fail escalation + failure branching (10-005/009/010 — safety-critical)**, ConfirmationMethod (10-013), CRT (10-012), scales (10-006).
3. **§12 Global Trace + Honda export** (12-012/013/014) + in-process (12-009) + shipping history (12-011).
4. **§6 Work Order runtime** (06-022 never populated → cascades to 06-028/029) and Trim weight estimation (06-005).
5. **Serialized-assembly MIP per-part path** (06-010/011/012 Partial — `AssemblyPlc` commissioning no-op).

**Discrete data/trace defects to fix in built code:**
- FDS-07-014 ship writes no `LotMovement`/`CurrentLocationId` (Honda-trace gap, P7-4).
- FDS-07-016 shipped→hold→release double-ship (P7-7).
- FDS-08-016 ~153 defect codes never seeded → reject dropdown empty; FDS-08-017 area filter hardcoded `0`.
- FDS-05-014 GOOD→SCRAP / HOLD→SCRAP / HOLD→CLOSED transitions unimplemented (P9-2).
- FDS-05-025 no post-sort merge gate.
- FDS-07-010c AIM-config no ordering CHECK + no audit (P7-2/P7-3).
- FDS-06-006 Trim OUT blocked by shotCount bug (P4-1).

**Divergences to reconcile in the FDS (intentional design evolution):**
- FDS-05-031 (B5 materialized qty vs "SHALL NOT materialize"); FDS-05-032 (checkpoint vs Start/Complete event-replay); FDS-05-009/033 system-mint vs "scan a fresh LTT"; FDS-05-004 die-cast checkpoint; FDS-04-006 hard-coded 30-min; FDS-08-001 hold-type taxonomy (PRECAUTIONARY dropped).

**Deferred-by-seam (deployment/commissioning, not bugs):** AD elevation IdP (04-007), AIM/print gateway dispatch side-effects (07-006a/b, 07-010b/011/012), PLC `_WATCH` configs (09-002, 10-*), cutover identifier seed (16-003), retention windows (11-009), spreadsheet/seed loads (08-016, 09-006).
