# Arc 2 (Plant Floor) — FDS Conformance Matrix

**Reviewer:** Claude (Opus 4.8) · **Original:** 2026-06-26 (`hunter/explore`, FDS v1.4, migration ~0030) · **Re-verified:** 2026-08-13 (`jacques/working`, **FDS v1.7, migration 0054**)
**Method:** Every plant-floor FDS requirement checked against the actual code (procs `sql/migrations/versioned/` + `sql/migrations/repeatable/`, seeds, Named Queries in the Ignition **Core** project, Perspective views, entity/gateway scripts). Status verified by locating the implementing artifact ("Built") or grepping to confirm absence ("Missing"). Bug-level detail and `file:line` evidence live in the companion **`ARC2_REVIEW_FINDINGS.md`** (cited as `P#-#`); its 2026-08-13 resolution overlay tracks which findings the intervening work closed.

**Status key:** **Built** = implemented + conformant · **Partial** = incomplete / server-only / UI-only · **Divergent** = implemented but deviates from the requirement text (see "Divergences to reconcile") · **Missing** = no implementing artifact · **N/A** = FUTURE/CONDITIONAL (out of MVP build scope) · **Verify** = needs a live-session/seed check.

> **2026-08-13 re-verification note.** The original matrix predated the back half of Arc 2 — 24 migrations (`0031`→`0054`), the **terminal-mint model** (`0035`/`0036`), the **die-cast per-cavity lifecycle** (`0045`), **Phase 9 quality capture + CRT** (`0037`), the **PLC integration** (`0038`/`0039` + seed `012`), the **Reporting Module suite** (6 PDF reports) + trace procs, and **FAT remediation Briefs A–F**. Every section was re-checked against current code; per-row `OLD → NEW` is shown inline. The headline finding is **inverted**: the three families the original called "collapsed" (§10 PLC, §12 reporting/trace, §8 inspection) are now substantially or fully built.

---

## Rollup

| FDS § | Area | Built | Partial | Divergent | Missing | N/A | Verify |
|---|---|---|---|---|---|---|---|
| §2 | Terminals / cell context | 4 | 1 | 0 | 0 | 1 | 1 |
| §4 | Identity / presence / elevation | 7 | 2 | 1 | 0 | 0 | 0 |
| §5 | LOT lifecycle & genealogy | 30 | 4 | 7 | 0 | 0 | 0 |
| §6 | Production execution | 19 | 4 | 1 | 3 | 1 | 0 |
| §7 | Container & shipping | 12 | 11 | 1 | 0 | 0 | 0 |
| §8 | Quality & holds | 16 | 1 | 0 | 0 | 2 | 0 |
| §9 | Downtime & shift | 8 | 5 | 0 | 0 | 1 | 1 |
| §10 | PLC / OPC / MIP / line-stop / CRT | 6 | 4 | 0 | 3 (*Missing*) | 0 | 0 |
| §11 | Audit & logging | 10 | 1 | 0 | 0 | 0 | 0 |
| §12 | Reporting / trace | 4 | 2 | 0 | 0 | 0 | 0 |
| §16 | Identifier sequences | 2 | 1 | 0 | 0 | 0 | 0 |
| **Totals** | | **118** | **36** | **10** | **6** | **5** | **2** |

**Delta since 2026-06-26:** Built **97 → 118 (+21)** · Missing **23 → 6 (−17)** · Partial 39 → 36 · Divergent 9 → 10 · N/A 6 → 5 · Verify 3 → 2.

**Headline.** The proc/SQL data layer remains the strength, and the three original "collapse" families have largely closed:
- **§10 PLC/MIP/line-stop/CRT** went **2 Built / 10 Missing → 6 Built / 4 Partial / 3 Missing.** The end-to-end PLC integration (`0038`/`0039`, 4 watchers, dispatch), the PLC-020 mapping seed (`012`), and Phase-9 CRT (`0037`) flipped MIP handshake, vision line-stop enforcement, scale reads, and CRT off "Missing."
- **§12 reporting/trace** went **0 Built / 5 Missing → 4 Built / 2 Partial.** The Reporting Module suite + Global Trace tool + trace procs delivered in-process inventory, the Track & Trace tile, multi-id resolve, and the Honda Lot-Detail **PDF**.
- **§8 inspection capture** went **3 Missing → Built** (Phase-9 `QualitySample` layer), plus defect-code seed (153 codes) and taxonomy now conformant.

**The 6 remaining Missing rows are concentrated and known:** §6 Work-Order runtime (`06-022` never instantiated → cascades to `06-028`/`06-029`) + Trim weight estimation (`06-005`); §10 consecutive-fail escalation (`10-009`), failure-type branching (`10-010`), ConfirmationMethod (`10-013`) — **all three §10 gaps are the gap-brief's Specs P2/P3/P4 and are gated by one open scope question: are PLC-120/130/220/230 MVP or commissioning-phase?** The **10 Divergent** rows are mostly *intentional design evolution* (terminal-mint, per-cavity) whose FDS prose needs reconciling — see the consolidated list at the bottom.

---

## §2 — Plant Model & Terminals

| Req | Keyword | OLD → NEW | Evidence | Note |
|-----|---------|-----------|----------|------|
| FDS-02-008 Terminal as Cell kind | SHALL | Built → **Built** | `0020` foundation; `Terminal_GetByIpAddress`; `Terminal/code.py:19,144` | printer child now via `Terminal_GetPrinter` + `0052`. |
| FDS-02-009 Cell context (Terminal+Location FKs) | SHALL | Built → **Built** | `Terminal/code.py:206-271` (`applyToSession`), `:103-141`; NQ `Terminal_ListContextCells` | centralized in `applyToSession`; clears `session.custom.cell` on change (`:242`). F4 still Verify. |
| FDS-02-010 Behavior by view flavor | SHALL·MVP | Built → **Built** | `DieCastShared:28` (`policy=strict`); `DieCastDedicated:25` (`confirm`); `AppHeader:42-51` idle watcher | idle re-prompt unified in AppHeader (both flavors) — F2 idle gap closed. |
| FDS-02-011 Cell-context change rules | SHALL | Built → **Partial** | `DieCastDedicated:25`; `DieCastBody:189` → `applyCell:1723-1727` | `applyCell` sets cell with **no strict re-prompt on change** (2026-08-04 spec #6 designed, unwired). |
| FDS-02-012 Part↔Cell eligibility (Direct∪BOM) | SHALL | Built → **Built** | `ItemLocation_CheckEligibility`; `v_EffectiveItemLocation`; enforced `MovementScan:324` | — |
| FDS-02-013 Tablet-friendly Die Cast | SHALL | Verify → **Verify** | `pf-*` 44px touch classes | still needs device smoke. |
| FDS-02-014 RFID-ready labels | FUTURE | N/A → **N/A** | — | correctly not built. |

## §4 — User Identity, Presence & Elevation

| Req | Keyword | OLD → NEW | Evidence | Note |
|-----|---------|-----------|----------|------|
| FDS-04-001 Two AppUser classes | SHALL | Built → **Built** | `AppUser/code.py:30-52` | — |
| FDS-04-002 First action → presence | SHALL | Built → **Built** | `InitialsEntry:227-229,217-224` | resolves via `getActiveByInitials`. |
| FDS-04-003 Presence follows flavor | SHALL·MVP | Partial → **Partial** | `AppHeader:49` → `IdleReconfirmModal`; `Session/code.py:106-112` | idle re-prompt now BUILT (both flavors); **context-change re-prompt still unbuilt** (F2). |
| FDS-04-004 Interactive via AD; operators not in AD | SHALL | Built → **Built** | `AppUser/code.py:149-162,254-279`; `AuthenticateAd` | `_validateAdCredentials` now challenges the internal user source (two-layer) — no longer hard-deny. |
| FDS-04-005 Initials pre-pop/override/resolve/block | SHALL | Built → **Built** | `AppUser/code.py:117-128,174-202`; `InitialsEntry:229` | **deprecated initials now blocked at presence sign-in** (Brief E). |
| FDS-04-006 30-min re-confirm | SHALL | Divergent → **Built** | `0049_session_policy:13-28` (180/300); `Session/code.py:60-66`; `AppHeader:49` | hard-coded-30 divergence **RESOLVED** → DB-config `SessionPolicy`. |
| FDS-04-007 Per-action AD elevation | SHALL | Partial → **Divergent** | `AppHeader:221,241,268`; `DieCastBody:634-637`; `MovementScan:324`; `ElevationModal:313`; `Session/code.py:85-171` | now WIRED (multiple views), but evolved to a **time-boxed session-sticky window** (`elevatedUntil`, 5-min rolling) — contradicts FDS "per-action, not session-sticky." Reconcile FDS. |
| FDS-04-008 Roles → AD groups | SHALL | Built → **Built** | `AppUser/code.py:165-171,97,139` | deploy-config. |
| FDS-04-009 Shop-floor no-auth; elevated controls gate | SHALL | Partial → **Partial** | `AppHeader:73-78`; `DieCastBody:634-637`; `MovementScan:324` | controls gate on `isElevated`, but **elevate-then-reveal** diverges from FDS "visible, prompt on activation." |
| FDS-04-010 Operator AppUser admin | SHALL | Built → **Built** | `AppUser_Create`; `DeprecatedAt`; `code.py:66-88` | — |

## §5 — LOT Lifecycle & Genealogy *(+ §16 Identifiers below)*

| Req | Keyword | OLD → NEW | Evidence | Note |
|-----|---------|-----------|----------|------|
| FDS-05-001 LOT uniqueness | SHALL | Built → **Built** | `Lot_Create`; `UQ_Lot_LotName` | — |
| FDS-05-002 LTT pre-printing | SHALL | Built → **Built** | `Lot_Create` (`@LotName` path) | — |
| FDS-05-003 LOT attributes | SHALL | Built → **Built** | `Lot_Create`; `0047_lot_bom_asbuilt` | as-built `Lot.BomId` stamped by mint procs + surfaced by `Lot_Get`. |
| FDS-05-004 Manufactured (Die Cast) create | SHALL | Partial → **Divergent-by-design** | `DieCastLot_Open:39-119`; `0045` | REDESIGNED to per-cavity **Open** basket (one-open-per-(Tool,Cavity) guard `:86-88`). Reconcile FDS. |
| FDS-05-005 Received create + Initial print | SHALL | Built → **Built** | `Lot_Create`; `LotLabel_Print` | — |
| FDS-05-006 Off-site received | SHALL | Partial → **Partial** | `LotOriginType` ReceivedOffsite seed | still origin-type only; no UI/workflow. |
| FDS-05-007 Movement tracking | SHALL | Built → **Built** | `Lot_MoveToValidated` | — |
| FDS-05-008 Movement workflow | SHALL | Built → **Built** | `MovementScan` + `Lot_MoveToValidated` | — |
| FDS-05-009 Machining-OUT sub-LOT split | SHALL | Divergent → **Divergent-by-design** | `MachiningOut_Mint:37-343` (replaces `RecordSplit`); `0035`/`0036` | standard OUT path is now a FIFO **consume-mint** (casting→SubAssembly, `Consumption` edge `:305-306`). Reconcile FDS. |
| FDS-05-010 Uneven split | SHALL | Partial → **Divergent-by-design** | `MachiningOut_Mint:196-207` (flexible qty, `@AllowPartial`) | consume-mint replaces even/uneven split arithmetic. |
| FDS-05-011 Split genealogy permanence | SHALL | Built → **Built** | `Lot_Split:360-376` (edge + closure) | `Lot_Split` retained as **exception-only** path. |
| FDS-05-012 Merge capability | SHALL | Built → **Built** | `Lot_Merge` | — |
| FDS-05-013 Status codes | SHALL | Built → **Built** | `LotStatusCode`; `0045` adds `Open` | `Open` (BlocksProduction=0) for die-cast basket. |
| FDS-05-014 Status transition rules | SHALL | Partial → **Partial (real gap)** | `Lot_UpdateStatus:144` (Good→Closed only); `DieCastLot_Void:56-61` (Open→Scrap); `DieCastLot_Release` (Open→Good); `RejectEvent_Record:302-341` (close-at-zero) | new Open→Good/Scrap built. **GOOD→SCRAP / HOLD→SCRAP / HOLD→CLOSED still NOT implemented** — scrap is a decrement/close model; held-LOT scrap (Brief F) keeps status **Hold**. *(Original mis-cited P9-2 here.)* |
| FDS-05-015 Status history | SHALL | Built → **Built** | `LotStatusHistory` writers | — |
| FDS-05-016 Genealogy graph | SHALL | Built → **Built** | `LotGenealogy` + `GenealogyRelationshipType` | Consumption (id=3) now dominant via mint procs. |
| FDS-05-017 Bidirectional query | SHALL | Built → **Built (UI gap persists)** | `Lot_GetGenealogyEdgeTree:27-96`; `GetParents`/`GetChildren`/`GetGenealogyTree`; `GlobalTrace_Resolve` | query layer strengthened. **P2-1 dead drill-down clicks STILL-OPEN** (`ParentRow:23-24,43`, `NodeRow:69` — handler on flex root). |
| FDS-05-018 Genealogy report | SHALL | Partial → **Built** | report `reports/Lot Detail/data.bin` (commits `d0d8ff64`,`6e2e8f06`); `Lot_GetGenealogyEdgeTree`/`Lot_GetLifecycle`/`Lot_GetShippedContainers` | printable both-direction full-depth genealogy + per-edge qty + shipped-container/lifecycle bands. |
| FDS-05-019 Label print tracking | SHALL | Built → **Built** | `LotLabel_Print` | — |
| FDS-05-020 Print reasons | SHALL | Built → **Built (cosmetic open)** | `0004:114` | P4-7 em-dash mojibake still present (`N'Reprint — Damaged'`). |
| FDS-05-021 Attribute-change log | SHALL | Built → **Built** | `LotAttributeChange` + writers | — |
| FDS-05-022 Sublot pattern (Machining) | SHALL | Built → **Divergent-by-design** | `MachiningOut_Mint:266-309` | sublots minted via consume-mint (`Consumption`, not `Split`); `-NN` naming + closure preserved. Reconcile FDS. |
| FDS-05-024 Sublot labels (parent ref) | SHALL | Built → **Built** | `LotLabel_Print {ParentLotNumber}` | — |
| FDS-05-025 Post-sort merge gate | SHALL | Missing → **Partial** | `Lot_Merge` (no sort gate); `SortCage_MigrateSerial` exists | inspection capture built (P9-1), but `Lot_Merge` still has **no sort/inspection-completion gate**. |
| FDS-05-026 Part-number match | SHALL | Built → **Built** | `Lot_Merge` ItemId reject | — |
| FDS-05-027 Die-rank compatibility | SHALL | Built → **Built** | `Lot_Merge` `DieRankCompatibility` + override | — |
| FDS-05-028 Quality-status gating | SHALL | Built → **Built** | `Lot_Merge` non-Good reject | — |
| FDS-05-029 Machining is FIFO not merge | SHALL | Built → **Built (FIFO edge open)** | `Lot_GetWipQueueByLocation:103` `ORDER BY lm.LastMovementAt ASC, l.Id ASC` | route-driven queue correct. **P4-6 not fixed**: no `ISNULL(LastMovementAt, CreatedAt)` (also `MachiningOut_Mint:264`). |
| FDS-05-030 Post-merge NULL tool/cavity | SHALL | Built → **Built** | `Lot_Merge` output NULL | — |
| FDS-05-031 Computed quantities | SHALL | Divergent → **Divergent** | `v_LotDerivedQuantities` + B5 materialized cols | B5 materialization contradicts "SHALL NOT materialize" (OI-35 supersedes). Reconcile FDS. |
| FDS-05-032 Partial start/complete | SHALL | Divergent → **Divergent** | checkpoint model | FDS-03-017a supersedes. |
| FDS-05-033 Trim→Machining rename | SHALL | Partial → **Divergent-by-design** | `MachiningIn_RecordPick:6-25` (checkpoint-only; no new LOT / no ConsumptionEvent / no rename) | rename-at-IN **removed** by terminal-mint; identity change moved to Machining OUT. **FDS text (lines 1231-1243, 1287) still describes the old rename — highest-priority reconcile.** |
| FDS-05-034 Die-cast tool+cavity required | SHALL | Built → **Built** | `DieCastLot_Open:66-71` (ToolAssignment + active-cavity) | enforced at basket Open. |
| FDS-05-035 Tools SoR on Lot | SHALL | Built → **Built** | `Lot.ToolId/ToolCavityId` | — |
| FDS-05-036 Lazy operator-driven create | SHALL | Built → **Built** | `Lot_Create` single invoke | — |
| FDS-05-037 LOT close semantics | SHALL | Partial → **Partial** | `Lot_CloseInline` (Good-only silent close helper) | helper exists but close-only — still no atomic "Complete + Move" proc. |
| FDS-05-038 Pausable LOT | SHALL | Built → **Built** | `LotPause_*`; `LotPause_Resume:21,112` | P2-4 resolved (OI-36 ET). P2-7: proc threads `@TerminalLocationId`; Ignition wiring VERIFY. |
| **FDS-05-039** Per-cavity basket lifecycle | SHALL | *(new, `0045`)* → **Built** | `DieCastLot_Open/_Release/_Void` | Open→accumulate→release. |
| **FDS-05-040** Shift-output accumulate | SHALL | *(new)* → **Built** | `DieCastShiftOutput_Record`; `DieCastContribution` ledger | additive good/scrap per shift. |
| **FDS-05-041** Basket release | SHALL | *(new)* → **Built** | `DieCastLot_Release` | Open→Good + first route move to WHSE. |
| **FDS-05-042** Basket void | SHALL | *(new)* → **Built** | `DieCastLot_Void` | empty Open→Scrap. |

## §16 — Identifier Sequences

| Req | Keyword | OLD → NEW | Evidence | Note |
|-----|---------|-----------|----------|------|
| FDS-16-001 IdentifierSequence table | SHALL | Built → **Built** | `0020:491-519` (MESL/MESI seed) | — |
| FDS-16-002 `IdentifierSequence_Next` | SHALL | Built → **Built** | `IdentifierSequence_Next:54-140` (ROWLOCK/UPDLOCK/HOLDLOCK, rollover raise, single set) | — |
| FDS-16-003 Cutover-day seeding | SHALL | Partial → **Partial** | `0020:513-519` provisional floor | exact cutover `+10,000` value still owed (deploy-day). |

## §6 — Production Execution

| Req | Keyword | OLD → NEW | Evidence | Note |
|-----|---------|-----------|----------|------|
| FDS-06-001 Die Cast screen | SHALL | Built → **Built (rebuilt)** | `DieCastLot_Open/_Release/_Void`; `DieCast_GetShiftOutputBreakdown`; `0045` | per-cavity Open→accumulate→release; `DieCastBody` two-surface. |
| FDS-06-002 Pre-record validation | SHALL | Built → **Built** | `DieCastShiftOutput_Record:86-118`; `DieCastLot_Release` guards | — |
| FDS-06-003 ProductionEvent on submit | SHALL | Partial → **Built (reconciled)** | `DieCastShiftOutput_Record:129-146` (`DieCastContribution` + `PieceCount +=` + additive `RejectEvent`) | die-cast no longer writes `ProductionEvent` (FDS-06-003 amended) — resolves P3-1/P3-4/D2 by design. |
| FDS-06-004 Trim IN | SHALL | Built → **Built** | `TrimBody:516` (`trimInMoved`) + handler `:1193` | P4-2 fixed. |
| FDS-06-005 Trim weight count estimate | SHALL | Missing → **Missing** | grep → none | scale-read/theoretical-count/accept-keep still unbuilt. |
| FDS-06-006 Trim OUT whole-move | SHALL | Divergent → **Built (divergent dest)** | `TrimOut_Record:307-366`; `TrimBody:1156,1188` | P4-1 fixed. **Divergence:** routes to Trim Storage, not operator-picked machining line (assigned at Machining IN). Reconcile FDS. |
| FDS-06-007 Machining IN FIFO + rename | SHALL | Built → **Divergent** | `MachiningIn_RecordPick:6-14` | checkpoint only; NO rename/mint at IN (moved to OUT). Reconcile FDS. |
| FDS-06-008 Machining OUT branch | SHALL | Partial → **Built** | `MachiningOut_Mint` (consume-mint FIFO + genealogy) | `RecordSplit`+`AutoComplete` retired; P5-4 resolved, P5-1 superseded. |
| FDS-06-009 Reject on submit | SHALL | Built → **Built (enhanced)** | `MachiningOut_Mint:217-234,301-302` (FAT-MACH-140); `RejectEvent_Record` | Machining OUT now captures per-line reject + source decrement. |
| FDS-06-010 Serialized MIP per-part | SHALL | Partial → **Partial (advanced)** | `SerializedMipWatcher`; `PlcWatcher:187-188`; `0037/0038/0039` | handshake + serial mint dispatched. Per-piece BOM consume/rollup `AssemblyPlc:61-70` still no-op (P6-5). |
| FDS-06-011 BOM material verify + override | SHALL | Partial → **Partial** | `ConsumptionEvent_RecordWithBomCheck:74-120` | leaf built; **no AD elevation** (P6-6); not wired into serialized watcher (P6-5). |
| FDS-06-012 Hardware interlock bypass | SHALL | Partial → **Partial** | `ContainerSerial_Add:18,92-93` (persists `HardwareInterlockBypassed`) | NoRead-accept path commissioning-stubbed (P6-5). |
| FDS-06-013 Non-serialized tray fill | SHALL | Built → **Built** | `Assembly_CompleteTray:201,347` (BlocksProduction=0 guard) | **P6-1 RESOLVED**; consume moved out of `ContainerTray_Close`. |
| FDS-06-014 Tray validation + accumulation | SHALL | Built → **Built** | `Assembly_CompleteTray:185-213,350-351`; `Container_Complete:94-117` | **P6-7 RESOLVED** (in-txn drained-mid-consume RAISERROR). P6-8 still-open (NULL-config skip `:96`). |
| FDS-06-015 PE append-only | SHALL | Built → **Built** | no update/delete proc | — |
| FDS-06-016 PE fields | SHALL | Built → **Built** | `ProductionEvent_Record:224-233` | — |
| FDS-06-017 Reject not required | SHALL | Built → **Built** | `RejectEvent_Record` optional | — |
| FDS-06-018 RejectEvent fields | SHALL | Built → **Built** | `Workorder.RejectEvent` | — |
| FDS-06-019 Two scrap patterns | SHALL | Built → **Built** | inline `RejectEvent` (A) + `Lot_Split`→Scrap (B); additive `:89,234-246` | scrap-additive (`0042`). |
| FDS-06-023a Scrap source discriminator | SHALL·MVP | Built → **Built** | `ProductionEvent.ScrapSourceId:41,193-205` | NULL-vs-NOTNULL not strictly enforced. |
| FDS-06-020 ConsumptionEvent | SHALL | Built → **Built** | `ConsumptionEvent_*` | — |
| FDS-06-021 Consumption genealogy | SHALL | Built → **Built** | `LotGenealogy` RelType=3 | — |
| FDS-06-022 Auto-generate Production WO | SHALL | Missing → **Missing** | grep `INSERT INTO Workorder.WorkOrder` → none | still never instantiated. |
| FDS-06-023/024/025 WO schema/op/types | SHALL | Built(schema) → **Built(schema)** | `0010`; `0013` type collapse | never instantiated (06-022). |
| FDS-06-026 Maintenance WO | FUTURE | N/A → **N/A** | nullable `WorkOrder.ToolId` hook | — |
| FDS-06-028 Auto-finish modes | SHALL·MVP | Partial → **Partial (advanced)** | `Container_Complete:80-92` + `@PlcCompletionConfirmed` | `CompletionConfirmed` now observed; no WO cumulative count/weight close (blocked on 06-022). |
| FDS-06-029 Tray-divisibility on WO close | SHALL·MVP | Missing → **Missing** | no WO-close proc | cascades from 06-022. |
| FDS-06-030 Live WO flag columns | SHALL·MVP | Built(schema) → **Built(schema)** | camera/scale/weight/recipe/tray cols | — |

## §7 — Container Management & Shipping

| Req | Keyword | OLD → NEW | Evidence | Note |
|-----|---------|-----------|----------|------|
| FDS-07-001 Container creation | SHALL | Partial → **Partial** | `Container_Open` (non-ser); serialized auto-create unwired (P6-5) | commissioning. |
| FDS-07-002 Status codes | SHALL | Built → **Built** | `0029` status seed | — |
| FDS-07-003 Serialized fill | SHALL | Partial → **Partial** | leaf procs; P6-5 | commissioning-seam. |
| FDS-07-004 Non-serialized fill | SHALL | Built → **Built** | `ContainerTray_Close`; `Container_Complete` | — |
| FDS-07-005 Closure (1 txn) | SHALL | Built → **Built** | `Container_Complete:132-205` | now also renders+persists ZPL (`:162-165`); async dispatch resolved (006a). |
| FDS-07-006 Label content | SHALL | Partial → **Built** | `0054:47-81`; `ufn_ShippingLabelZpl:39-57` | **Honda part/qty/MFG-lot/serial/DC-level fields now present** (Brief D). Was the doc's headline gap. |
| FDS-07-006a Print dispatch (GW-async) | SHALL·MVP | Partial → **Built** | `ShippingDispatcher/code.py:123-170`; `ShippingLabel_MarkDispatch:40-47` | async worker, 3×/backoff, per-attempt InterfaceLog, write-back. Live Zebra TCP = commissioning-seam. |
| FDS-07-006b Failure sweep/banner | SHALL·MVP | Partial → **Built** | `PrintFailureGateway/code.py:45-87`; `PrintFailureBanner:107` | sweep/broadcast functional; **banner terminal-filtered** + Acknowledge (P7-11 fixed). Email/IT-notify = commissioning. |
| FDS-07-007 Label tracking | SHALL | Built → **Built** | `ShippingLabel` + `0054` ZplContent | persists rendered ZPL. |
| FDS-07-008 Label void | SHALL | Partial → **Partial** | `ShippingLabel_Void:49` | row kept, no pool return (correct per UJ-04). AIM void-notify not invoked (P7-13, commissioning). |
| FDS-07-009 Label reprint | SHALL | Built → **Built** | `ShippingLabel_Reprint:47-51` | re-renders ZPL; AD gate still absent (P7-1). |
| FDS-07-010 AIM local pool | SHALL | Partial → **Partial** | `AimShipperIdPool_Claim/Topup/GetDepth`; `topupTick:20-23` | claim/depth/provenance built; topup loop sim (commissioning). |
| FDS-07-010a Empty-pool hard-fail | SHALL·MVP | Built → **Built** | `Container_Complete:120-127` | rejects pre-txn. |
| FDS-07-010b Pool alarms | SHALL·MVP | Partial → **Partial** | `AimPoolGateway.alarmTick:26-51` | alarmTick functional (rising-edge). Still no seeded audit events / clear-broadcast / IT-notify (P7-12). |
| FDS-07-010c Pool config | SHALL·MVP | Divergent → **Divergent** | `AimPoolConfig_Update:32`; `0029` | **STILL no ordering CHECK + no ConfigLog audit** (P7-2/P7-3). Small proc edit. |
| FDS-07-011 AIM hold notify | SHALL | Partial → **Partial** | `AimPoolGateway.placeOnHold:67-70` | sim stub, not invoked (P7-13). |
| FDS-07-012 AIM update (re-sort) | SHALL | Partial → **Partial** | `AimPoolGateway.update:78-81` | sim stub (P7-8/P7-13). |
| FDS-07-013 Shipping validation | SHALL | Partial → **Partial** | `Container_Ship:39-57` | **still no AimShipperId presence/format check** (P7-5). |
| FDS-07-014 Ship confirmation | SHALL | Divergent → **Partial** | `Container_Ship:66-72` | now updates `CurrentLocationId→SHIPOUT` + audit (P7-4 fix). No `LotMovement` = by-design N/A (container has no `LotId`); FDS text needs reconciliation. |
| FDS-07-015 Container hold | SHALL | Partial → **Partial** | `Hold_Place:93,105-106,117` | captures `PriorContainerStatusCodeId`; AIM PlaceOnHold not invoked (P7-13). |
| FDS-07-016 Container hold release | SHALL | Divergent → **Built** | `Hold_Release:106-111`; `0031` | **shipped→hold→release restores to Shipped, not re-shippable** (P7-7 fixed). |
| FDS-07-017 Sort Cage | SHALL·MVP-EXP | Partial → **Partial** | `SortCage_MigrateSerial` | serial migrate + history built; the 8-step orchestration (LotMovement / new LTT / labels / void-old / AIM-update) unwired (P7-8). |
| FDS-07-018 Sort Cage scope | (desc) | Built → **Built** | holds + split | — |
| FDS-07-019 Sort Cage not a merge | SHALL NOT | Built → **Built** | `SortCage_MigrateSerial:76-78` | preserves genealogy. |

## §8 — Quality & Hold Management

| Req | Keyword | OLD → NEW | Evidence | Note |
|-----|---------|-----------|----------|------|
| FDS-08-001 Hold placement | SHALL | Built(divergent taxonomy) → **Built** | `0030_holdtype_taxonomy_fds0801:14-16` | seed = Quality / CustomerComplaint / **Precautionary**; EngineeringHold removed. **Original "PRECAUTIONARY dropped" note is stale.** |
| FDS-08-002 Hold effect | SHALL | Built → **Built** | `Lot_AssertNotBlocked` | — |
| FDS-08-003 Hold release | SHALL | Built → **Built** | `Hold_Release`; prior-status restore `0031` | container path fixed (P7-7). |
| FDS-08-004 Hold without NCM | SHALL | Built → **Built** | `HoldEvent.NonConformanceId` nullable | — |
| FDS-08-005 Partial disposition via split | SHALL | Built → **Built** | `Lot_Split` | — |
| FDS-08-006 Bulk hold | SHALL | Built → **Built** | `Hold.placeBulk:84` | — |
| FDS-08-007 Container hold integration | SHOULD | Built → **Built** | `Hold.listAssociatedContainers:74`; `Hold_GetOpenByContainer` | advisory alert wired (FAT-QH-170). |
| FDS-08-007a Hold Management screen | SHALL·MVP-EXP | Partial → **Built** | `HoldManagement:1601-1855` (ReleasePanel + `releaseDraft`); `LotDetail:264-278` ON HOLD pill, `:1965-1994` one-click Release | Release path live (P7-6 fixed). **AD elevation still absent (P7-1).** |
| FDS-08-008 Quality spec mgmt | SHALL | Built → **Built** | Arc-1 `QualitySpec_*` | — |
| FDS-08-009 Spec versioning | SHALL | Built → **Built** | `QualitySpecVersion_*` | inspection FKs spec version. |
| FDS-08-010 Spec attributes (dynamic render) | SHALL | Partial → **Built** | `InspectionEntry:608` AttributeRow repeater | dynamic render landed (P9-1). |
| FDS-08-011 Inspection recording | SHALL | Missing → **Built** | `0037:31-70`; `QualitySample_Record:41`; `InspectionEntry:676,962`; NQ `quality/QualitySample_Record` | header + per-attribute results, auto pass/fail rollup, audit. |
| FDS-08-012 Failed inspection (alert ≠ auto-hold) | SHALL | Missing → **Built** | proc `:322` "NO AUTO-HOLD"; view `:657,109` Fail toast | conforms exactly. |
| FDS-08-013 Quality attachments | SHALL | Missing → **Built (API); upload UI pending** | `0037:73-89`; `QualitySample/code.py:134-159`; NQ `QualityAttachment_Add` | metadata API complete; file-upload widget = Designer follow-up. |
| FDS-08-014 Sample triggers | SHOULD | N/A → **Built (CONDITIONAL)** | `0037:113-146` (SampleTriggerCode 5-9); `getTriggerOptions` | seeded + selectable. |
| FDS-08-015 Sample representative | (stmt) | N/A → **N/A** | — | CONDITIONAL. |
| FDS-08-016 Defect-code mgmt | SHALL | Partial → **Built** | `sql/seeds/030_seed_defect_codes.sql` (**153 codes**) | Appendix-E seed gap closed → dropdown populated. |
| FDS-08-017 Area filtering | SHALL | Divergent → **Built** | `0048`; `DefectCode_List` v2.0 `:21-55` (`@OperationTypeCode`→category + plant-wide NULL) | re-scoped Area→OperationCategory; hardcoded-`0` bug gone. |
| FDS-08-018 NCM scope boundary | FUTURE | N/A → **N/A** | no `NonConformance` table/proc/view | discipline respected (P9-7). |

## §9 — Downtime & Shift

| Req | Keyword | OLD → NEW | Evidence | Note |
|-----|---------|-----------|----------|------|
| FDS-09-001 Manual downtime | SHALL | Partial → **Partial** | `EndOfShiftEntry:59-66` (manual CellSelect); `DowntimeManager:198` (`session.custom.cell`) | machine still from picker on EndOfShift/DowntimeEntry (P8-4). |
| FDS-09-002 PLC-triggered downtime | SHALL | Partial → **Partial** | `DowntimePlc/code.py` | sim/no-op until `_WATCH` configured (commissioning). |
| FDS-09-003 Open event prominent | SHALL | Built → **Built** | `DowntimeManager:196-234` `refreshRows()`; mutation handlers call it (`:52,141,206,213,220`) | **P8-1 RESOLVED** — imperative re-query. |
| FDS-09-004 Append-only StartedAt | SHALL | Built → **Built** | only EndedAt/reason/duration mutable | — |
| FDS-09-005 Reason filter Area+Type, type-first | SHALL | Missing → **Partial/Divergent** | `DowntimeReasonCode_List:14-61` (category+type); `DowntimeEntry:31` scopes by `operationCategoryCode`; `0051` | axis changed **Area→OperationCategory**; category filter applied on primary dropdown; **type-first selector still absent**; DowntimeManager per-row dropdown filters neither. |
| FDS-09-006 ~660 reason codes seeded | SHALL | Verify → **Partial** | loader `DowntimeReasonCode_BulkLoadFromSeed` (353-row CSV→JSON, idempotent); `0026:74-79` seeds only 3 break codes | **no migration auto-loads them** — cutover deployment action (same class as 08-016). FDS says ~660; CSV has 353. |
| FDS-09-007 Reason types (6 + Break) | SHALL | Built → **Built** | `0026:60` | — |
| FDS-09-008 Shift schedules | SHALL | Built → **Built** | `ShiftSchedule` (Arc-1) | — |
| FDS-09-009 Shift instances, event-derived | SHALL | Built → **Built (+OI-38)** | `Shift_Reconcile:7,55` | NEW divergence **OI-38**: reconcile stores **LOCAL** time deliberately vs UTC downtime. |
| FDS-09-010 No auto-split | SHALL | Built → **Built** | `Shift_End` leaves open | — |
| FDS-09-011 OEE snapshot | FUTURE | N/A → **N/A** | — | — |
| FDS-09-012 Idempotent schedule import | SHALL | Built → **Built** | Arc-1 | — |
| FDS-09-013 End-of-shift entry | SHALL | Partial → **Partial** | `EndOfShiftEntry:91-107`; `EndOfShiftEntry_Submit:84-94` | **P8-3 (±15-min), P8-4 (machine-from-terminal + inline initials), P8-8 (zero-break re-submit) all STILL-OPEN**; proc now accepts `@TerminalLocationId`, view passes none. |
| FDS-09-014 Early-start acceptance | SHALL | Verify → **Verify** | `Shift_GetActive` | not specifically exercised. |
| FDS-09-015 Shift-end summary | SHALL·MVP | Built → **Built** | `LotPause_GetByLocation:27` (UTC→ET) | **P8-7 RESOLVED** (OI-36 sweep). |

## §10 — PLC/OPC, MIP, Line-Stop, CRT

*On-disk migration numbering (verified): PLC foundation = `0038_plc_integration_foundation`, `0039_plc_handshake_audit`; Phase-9/CRT = `0037_arc2_phase9_quality_capture`; PLC-020 mapping = seed `sql/seeds/012_seed_terminal_plc_device.sql`.*

| Req | Keyword | OLD → NEW | Evidence | Note |
|-----|---------|-----------|----------|------|
| FDS-10-001 MIP touch points | SHALL | Missing → **Built** | `SerializedMipWatcher:20-80`; `PlcWatcher:155-194`; `0038:19-71`; seed `012:34-37` | full handshake spine + UDT + mapping seeded. Commissioning-seam = sim→TOPServer repoint. |
| FDS-10-002 Transaction flow | SHALL | Missing → **Built** | `SerializedMipWatcher:27-80` | TransInProc→mint→PartValid→reset. Old `AssemblyPlc` superseded (P6-5). |
| FDS-10-003 AlarmMsg (low-inv/invalid/dup) | SHALL | Missing → **Partial** | `SerializedMipWatcher:79`; `TrayInspectionWatcher:85,106`; `PlcWatcher:79-87` | generic HMI alarm channel on reject; the 3 **specific** categories not distinctly implemented. |
| FDS-10-004 Non-serialized PLC disposition | SHALL | Missing → **Partial** | `TrayInspectionStation.json` (18 `PartDisposition` slots) vs `TrayInspectionWatcher:69` (reads only `VisionPartNumber`/`OkToContinue`) | disposition reads unbuilt (rolls into Spec P3). |
| FDS-10-005 Line-stop (vision/operator conflict) | SHALL | Missing → **Partial** | `TrayInspectionWatcher:78-87`; `0039:19-22` (PlcLineStop 68) | **core enforcement built** (mismatch → no release + HMI alarm + `PlcLineStop` log). Unbuilt: escalation routing + `OperationLog LineStopped`/`FailureLog` shape + MES popup. |
| FDS-10-006 OmniServer scale reads | SHALL | Missing → **Built** | `ScaleWatcher:28-70` | reads NET_* on `NET_DataReady`, acks, logs, couples to container close. Weight persistence = open decision G-2. |
| FDS-10-007 Barcode wedge + server validation | SHALL | Built → **Built** | wedge inputs + server LTT/AIM format checks | — |
| FDS-10-008 Zebra ZPL dispatch | SHALL | Built → **Built** | `LotLabel`/`ShippingDispatcher` raw-TCP 9100 + InterfaceLog | — |
| FDS-10-009 10-fail leader escalation | SHALL | Missing → **Missing** | grep `consecutive`/`LeaderEscalationFlagged`/`CellFailState` → 0 artifacts; threshold unseeded | genuinely unbuilt = gap-brief **Spec P2**. |
| FDS-10-010 Failure-type branching | SHALL | Missing → **Missing** | `TrayInspectionWatcher:78` single uniform check | genuinely unbuilt = **Spec P3**. |
| FDS-10-011 Hold/CRT release | SHALL | Partial → **Partial (improved)** | `Hold_Release:20,70-115`; `Lot_SetCrt:27` | CRT-release proc exists, not yet a `ReleaseDispositionCode`; AD elevation zero views (P7-1). |
| FDS-10-012 CRT lifecycle | SHALL | Missing → **Built** | `0037:16-24`; `Lot_SetCrt:109-113` (`CrtActive=1`), `Lot_ClearCrt`, `Crt_GetRequiredInspections`, `Crt_FlagMissedInspection`; test `040_Crt_workflow` | **P9-2 resolved** (the single most-stale 🔴 row); codes seeded (LogEventType 63-66). UI badge caveat (P9-6) — LotDetail now has CRT set/clear + badge. |
| FDS-10-013 ConfirmationMethod Vision/Barcode/Both | SHALL·MVP | Missing → **Missing** | grep `ConfirmationMethod` → 0 files | genuinely unbuilt = **Spec P4**. |

## §11 — Audit & Logging

| Req | Keyword | OLD → NEW | Evidence | Note |
|-----|---------|-----------|----------|------|
| FDS-11-001 Operation log | SHALL | Built → **Built** | `Audit_LogOperation`; `ufn_MidDot`/`ufn_TruncateActivity` | Description-convention helpers in place. |
| FDS-11-002 Config log | SHALL | Built → **Built** | `Audit_LogConfigChange`; `AimPoolConfig_Update:40-52` (no call) | **P7-3 STILL-OPEN** — `AimPoolConfig_Update` writes no ConfigLog. |
| FDS-11-003 Interface log | SHALL | Built → **Built** | `Audit_LogInterfaceCall` | — |
| FDS-11-004 Failure log | SHALL | Built → **Built** | `Audit_LogFailure` + browser | — |
| FDS-11-005 High-fidelity interface logging | SHALL | Partial → **Partial** | `IsHighFidelity` BIT | caller-hardcoded; no per-system toggle. |
| FDS-11-006 Event-type vocabulary | SHALL | Built → **Built (+new)** | `0044:13-16` (`OperatorChanged` id 75) + `OperatorChange_Log` | — |
| FDS-11-007 Entity-type vocabulary | SHALL | Built → **Built** | `LogEntityType` seeds | — |
| FDS-11-008 Code-string signatures | SHALL | Built → **Built** | writers resolve code→id | — |
| FDS-11-009 Retention policy | SHALL | Built → **Built** | `Partition_MaintainWindow` + timer | windows pending MPP IT (OI-35 B1). |
| FDS-11-010 BIGINT PKs | SHALL | Built → **Built** | all audit tables | — |
| FDS-11-011 JDBC single-set/no-OUTPUT | SHALL | Built → **Built** | upheld app-wide | strongest area. |

## §12 — Reporting / Trace

| Req | Keyword | OLD → NEW | Evidence | Note |
|-----|---------|-----------|----------|------|
| FDS-12-009 In-process LOT tracking | SHALL | Missing → **Built** | registry `Reports/code.py:50-52` "Current Inventory"; `reports/Inventory/data.bin` | plantwide WIP snapshot report. SupervisorDashboard tile itself may still be a stub (P8-11). |
| FDS-12-010 Hold status report | SHALL | Partial → **Partial** | `Hold_ListOpen` + HoldManagement | no dedicated report; no duration-on-hold/export. |
| FDS-12-011 Shipping history | SHALL | Missing → **Partial** | `Lot_GetShippedContainers:21` (AIM shipper + container + completed-at); surfaced in Lot Detail | **no standalone date-range/part/ASN reconciliation report.** |
| FDS-12-012 Track tile / Global Trace | SHALL·MVP | Missing → **Built** | `page-config/config.json:123-125` `/shop-floor/trace` → `GlobalTrace` view | Track tile reachable. |
| FDS-12-013 Trace input (multi-id resolve) | SHALL·MVP | Missing → **Built** | `GlobalTrace_Resolve:35-137` (LOT/Serial/Container/Shipper + prefix + disambiguation); `GlobalTrace/code.py:22-51` | supersedes the `Lot_Search` gap. |
| FDS-12-014 Trace output + Honda PDF/CSV | SHALL·MVP | Missing → **Built (PDF); CSV owed** | Lot Detail report → `Lot_GetGenealogyEdgeTree` + `Lot_GetLifecycle` + `Lot_GetShippedContainers`; on-screen `GlobalTrace/code.py:54-105` | Honda **PDF** built; **CSV export + a Print/Export button on the Global Trace screen still absent.** |

---

## Top MVP conformance gaps (consolidated, 2026-08-13)

**Genuinely Missing (6 rows), concentrated in two clusters:**
1. **§6 Work-Order runtime** — `06-022` (`Workorder.WorkOrder` never `INSERT`ed) cascades to `06-028` (WO cumulative-count/weight close) and `06-029` (tray-divisibility on WO close). Also **`06-005` Trim weight/theoretical-count estimation** unbuilt.
2. **§10 vision logic — the gap-brief's Specs P2/P3/P4, all gated by one scope question** (are PLC-120/130/220/230 MVP or commissioning-phase?): `10-009` consecutive-fail leader escalation (Spec P2), `10-010` failure-type branching (Spec P3), `10-013` ConfirmationMethod Vision/Barcode/Both (Spec P4). The foundational finding holds — all three vision PLCs emit only a raw per-cycle verdict, so this logic is wholly MES-side.

**Discrete data/behavior gaps in otherwise-built code (small, self-contained):**
- `07-010c` / **P7-2** (no AIM-pool ordering CHECK) + **P7-3** (`AimPoolConfig_Update` writes no `Audit.ConfigLog`).
- `07-013` / **P7-5** (`Container_Ship` never validates `AimShipperId` presence/format).
- `05-014` — GOOD→SCRAP / HOLD→SCRAP / HOLD→CLOSED not implemented as status transitions (scrap is a decrement/close model; decide: implement, or document the model as authoritative).
- `05-029` / **P4-6** — FIFO `ORDER BY LastMovementAt` with no `ISNULL(…, CreatedAt)` (also `MachiningOut_Mint:264`).
- `05-025` — no post-sort/inspection-completion merge gate on `Lot_Merge`.
- `05-037` — no atomic "Complete + Move" proc.
- `05-020` / **P4-7** — `PrintReasonCode` em-dash mojibake (cosmetic, `0004:114`).
- `02-011` — shared cell-context change performs no strict presence re-prompt (2026-08-04 spec #6 unwired).
- **P2-1** — genealogy drill-down clicks dead (handler on a flex container root).

**Seed/deploy actions (loader exists, no migration runs it):**
- `08-016` defect codes — **loaded** (`030_seed_defect_codes.sql`, 153 rows). ✅
- `09-006` downtime reason codes — **NOT auto-loaded**; run `DowntimeReasonCode_BulkLoadFromSeed` (353-row CSV) at cutover.
- `16-003` exact cutover identifier `+10,000` seed; `11-009` retention windows (MPP IT).

**Divergences to reconcile in the FDS (intentional design evolution — NOT gaps):**
- **Terminal-mint model** (`0035`/`0036`): `05-009`/`05-010`/`05-022` (consume-mint replaced sub-LOT split; `Lot_Split` now exception-only), `05-033` + `06-007` (Machining-IN rename **removed**, identity mint moved to Machining OUT), `06-006` (Trim OUT routes to Trim Storage). **`05-033` is highest-priority — FDS text lines 1231-1243 / 1287 still describe the removed rename.**
- **Die-cast per-cavity lifecycle** (`0045`): `05-004`/`06-001`/`06-003` (Open-basket accumulate; die-cast writes `DieCastContribution`, not `ProductionEvent`) + new rows `05-039`…`05-042`.
- **Elevation** (`04-007`/`04-009`): now a time-boxed session-sticky window + elevate-then-reveal — reconcile against the FDS "per-action, not session-sticky" text.
- **Shipping** (`07-014`): container-centric ship sets `CurrentLocationId→SHIPOUT`; the FDS "LotMovement for source LOT" wording is N/A to a container with no `LotId`.
- Carried forward: `05-031` (B5 materialized qty vs "SHALL NOT materialize", OI-35), `05-032` (checkpoint vs Start/Complete replay), `08-001` taxonomy note now stale (already conformant via `0030`).
- New TZ divergence **OI-38**: `Shift_Reconcile` deliberately stores LOCAL time (couples to OI-36).

**Deferred-by-seam (deployment/commissioning, not code gaps):** AD-elevation IdP wiring across views (`04-007`/`P7-1`, `08-007a`, `10-011`), AIM gateway side-effects (`07-008`/`011`/`012`, `07-010b`, P7-13), serialized-assembly per-part MIP consume path (`06-010/011/012`, P6-5), PLC `_WATCH`/sim→TOPServer repoint (`09-002`, `10-*`), scale weight persistence (decision G-2), Honda **CSV** export (`12-014`), standalone shipping-history/ASN report (`12-011`).

---

## Open convergence TODO (unchanged, confirmed still deferred)

`Workorder.ProductionEvent_Record` has **no `@RoleCode` parameter** — the "converge operation-template execution to ONE SQL methodology" refactor at the top of `PROJECT_STATUS.md` is **not started**. Re-confirmed 2026-08-13.
