# PLC Interaction — Gap Design Brief — 2026-08-11

Design-level triage of every unbuilt / blocked item on the PLC interaction surface,
clustered into candidate specs. Companion to `2026-08-11_plc-commissioning-readiness-map.md`
(the full surface + evidence). Each entry: what's required (FDS + FAT), current state with
file:line evidence, and a pattern-aware proposed design.

**Status legend:** 🟢 ready-to-spec build · 🟡 needs a decision first · 🔵 non-build (seed/verify) · ⚪ scope-flag (MVP vs commissioning-phase).

**The one scope question that gates half of this:** FDS §10 tags escalation/vision as `MVP`, but the remediation brief and plan flagged PLC-120/130/220/230 as *possibly* commissioning-phase. **Confirm MVP vs commissioning for Spec P2/P3/P4 before speccing** — it changes sequencing, not design.

---

## Foundational finding (drives everything below)

All three vision PLCs (`MPP_COG`, `MPPMACH`, `SORTCAGE`) provide a **raw per-cycle pass/fail verdict and nothing else** — no consecutive-fail escalation, no failure-type classification, no barcode/dual-source, no supervised resume. The only PLC-side counter (`MPPMACH` `C5:1` "3-in-a-row") is tray-level and HMI-reset, not the FDS model. **Therefore FDS-10-009 / -010 / -013 are wholly MES responsibilities** — the MES cannot delegate any of them to the PLC. It receives a verdict edge and must layer all logic on top.

---

## Spec P1 — Serialized-MIP deployment closeout (PLC-020/030) 🔵 seed + verify, no new logic

### PLC-020 — TerminalPlcDevice mapping seed
- **Expects:** a serialized MIP station resolves to a mapped device at runtime.
- **Current:** the edge spine is complete (`PlcWatcher/code.py:148-194`) and 33 trigger paths are wired (`resource.json:16-50`), but **`sql/` contains zero `INSERT INTO Location.TerminalPlcDevice`** — `0038` seeds only `PlcDeviceType`. Every edge hits the "no mapping → ignored" branch (`PlcWatcher/code.py:164-168`).
- **Proposed fix:** a seed migration (mirror `011_seed_locations_mpp_plant.sql`) inserting a `TerminalPlcDevice` row per UDT instance (~24), mapping each to its terminal + device type + instance path. Resolve terminals/paths by name (robust to identity drift). **This is the single highest-leverage PLC task** — without it nothing routes on a reset DB.
- **Effort:** small (data, no logic). Blocks the whole surface — do first.

### PLC-030 — transaction flow
- **Already COMPLETE** (`SerializedMipWatcher/code.py:20-80`). Deferrals are commissioning-phase: serial min-length/interlock rule (proc `:9-11`), `ContainerCount` write-back (`:59-60`). **Action:** record a simulator acceptance pass; no build.

---

## Spec P2 — Vision line-stop consecutive-fail escalation (PLC-120 / FDS-10-009) 🟢 (⚪ confirm MVP)

- **Expects:** the MES tracks consecutive validation failures **per Cell per active part**; on the **10th** (configurable via `LineStopConsecutiveFailThreshold`, default 10): auto-escalate (`LogEventType=LeaderEscalationFlagged` + Supervisor-dashboard badge), require supervisor AD elevation (FDS-04-007) to resume, reset counter on next success or override.
- **Current:** `TrayInspectionWatcher/code.py:78-87` records an **independent per-event** line-stop (`OkToContinue` false + `PlcLineStop` InterfaceLog + HMI alarm) with **no counter, no threshold, no escalation, no resume-gate**. Grep `consecutive|LeaderEscalationFlagged|FailCount` across `ignition/` = 0 hits. `LineStopConsecutiveFailThreshold` unseeded.
- **Proposed design:**
  1. **State in SQL, not Python** (per "no business logic in Python"). A per-Cell-per-part consecutive-fail counter — new table `Workorder.CellFailState (LocationId, ItemId, ConsecutiveFails, LastFailAt, EscalatedAt, ...)` or a materialized column set — incremented by a proc `Workorder.VisionFail_Record(@LocationId, @ItemId, @FailureType)` and **reset to zero by any successful validation** and by supervisor override.
  2. Seed `LineStopConsecutiveFailThreshold` as a `LocationAttributeDefinition` (mirror `RequiresCompletionConfirm` in `0020` + `011`), default 10, readable per Cell.
  3. At threshold the proc writes `LeaderEscalationFlagged` to `Audit.OperationLog` and sets an escalation flag the Supervisor dashboard binds to (badge). Resume requires supervisor AD elevation — reuse the existing per-action elevation model (`5ac5a4b1`/`64e2268c` AppHeader elevation).
  4. `TrayInspectionWatcher` becomes thin: on mismatch it calls `VisionFail_Record` and reads back whether the cell is now escalation-locked (gates `OkToContinue`).
- **Design decisions:** (a) counter granularity = Cell × active-part (per FDS) — confirm "active part" = the LOT's Item at that Cell; (b) does a *different* failure-type interrupt the consecutive run, or only a success? (FDS says "not interrupted by a successful validation" → only success resets); (c) escalation badge delivery — reuse the toast/notification system or a dedicated supervisor queue.
- **Effort:** medium. Self-contained; SQL-heavy + one dashboard badge + thin watcher change.

---

## Spec P3 — Vision failure-type branching (PLC-130 / FDS-10-010) 🟡 needs a data-source decision

- **Expects:** branch by failure type — **Wrong part** (vision≠operator): stop + **leader flag immediately**; **Wrong orientation**: stop, no escalate (unless the P2 10-fail hits); **PartDisposition fail** (PLC reject): stop, counts toward P2; **Barcode mis-scan**: no stop, operator re-scans.
- **Current:** `TrayInspectionWatcher/code.py:78` does a **single uniform** `int(vision) != int(expected)` mismatch — no branch matrix. It **never reads the 18 `PartDisposition` slots** that exist in the UDT (`TrayInspectionStation.json:77+`). The PLCs surface only an undifferentiated fail; the finer signals (`MPP_COG` `N17:4/0..2`, `MPPMACH` per-part words) are read-but-unused *in the PLC*.
- **The blocker (decision required):** FDS-10-010 says the branch key is "knowable at the point of failure from the source data" — but **the vision PLC does not classify failures today**. Wrong-part is derivable MES-side (vision SKU ≠ operator/expected). Wrong-*orientation* requires the Cognex job to emit an orientation sub-result — currently the `N17:4/x` outputs are unlabeled and unused. **Two options:**
  - **(A) MES-derivable subset only:** implement Wrong-part (vision≠expected → immediate leader flag) + PartDisposition-fail (read the slots → counts) + barcode-mis-scan (MES scan reject → no stop) now; defer Wrong-orientation until the Cognex job exposes an orientation flag.
  - **(B) Full matrix:** first get the Cognex job author to map `N17:4/0..2` (and/or the `N7:100` PLACARD check) to failure categories, publish those bits through TOPServer, then branch on all four.
- **Proposed design (either option):** a hardcoded branch in the line-stop handler keyed on event-type category (FDS-10-010 explicitly says no `DefectCode` lookup) — implemented in the SQL line-stop proc that P2 introduces (`@FailureType` param), so branching and counting live together. `TrayInspectionWatcher` must start **reading the `PartDisposition01..NN` slots** to detect PLC-side rejects.
- **Effort:** small-medium if Option A; larger + external dependency (Cognex job) if Option B. **Recommend Option A now, Option B at commissioning** once the camera output map is obtained.

---

## Spec P4 — ConfirmationMethod + dual-source agreement (PLC-220/230 / FDS-10-013) 🟢 (⚪ confirm which cells)

- **Expects:** each PLC-integrated Cell declares a `ConfirmationMethod` LocationAttribute (`Vision`/`Barcode`/`Both`); the production proc + UI honor it. **`Both`** = vision AND barcode must confirm matching identity before the event records; mismatch counts toward the P2 threshold. Operator manual override available, supervisor-elevated, logged via `HardwareInterlockBypassed`.
- **Current:** `ConfirmationMethod` = **0 files in `sql/`** (no `LocationAttributeDefinition`, nothing reads it — only doc/FAT text). No agreement gate anywhere. **And there is no barcode scanner in any vision PLC's I/O** — dual-source at the *Cell* today means MES-side scan (keyboard-wedge, FDS-10-007) + vision tag, reconciled in the MES.
- **Proposed design:**
  1. **PLC-220:** seed a `ConfirmationMethod` `LocationAttributeDefinition` (allowed `Vision`/`Barcode`/`Both`) on the relevant `LocationTypeDefinition`s, mirror the `RequiresCompletionConfirm` seed pattern (`0020` + `011`). Read it in the production/identity-check proc + expose to the operator UI.
  2. **PLC-230:** in the identity-check proc, branch on the attribute — `Vision` (compare `VisionPartNumber` only), `Barcode` (compare scanned LTT/SKU only), `Both` (require both present AND matching; mismatch → line-stop path from P2/P3, counts toward threshold). Override path sets `HardwareInterlockBypassed=1` on the resulting `ContainerSerial` row (FDS-06-009/UJ-16), supervisor-elevated.
- **Design decisions:** (a) which Cells are actually `Both`? — the catalog shows vision cells (family C) with no scanner, so `Both` presumes an MES-side operator scan at that station; confirm the operational reality per Cell with MPP; (b) the future `VisionAuthoritativeBarcodeReconcile` 4th value is a proc-only extension — no schema change.
- **Effort:** small-medium. P4 depends on P2's line-stop proc existing (shared `@FailureType` path). Natural sequence: **P2 → P3 → P4**.

---

## Adjacent gaps (surfaced, not in the FAT PLC-1xx set)

### G-1 — Non-serialized line completion is a stub (5A2) 🟡
`NonSerializedMipWatcher._resolveLineConfig()` hard-returns `None` (`:69-74`), so every edge takes the ack-only branch and `Assembly_CompleteTray` (`:48-50`) is **dead code**. **Decision needed:** where does line→FG-item + tray-piece-count config live (Item attribute vs per-line row vs active WO)? Also confirm the `5A2_*` write-only catalog is a true MIP vs command-only HMI. Then wire `_resolveLineConfig`.

### G-2 — Scale raw-weight not persisted 🟡
`ScaleWatcher` gates on `NET_TargetWeightMetFlag` but the weight lives only in `Audit.InterfaceLog.requestPayload` (`:16-21, 43-45`) — no `ProductionEvent`/`QualitySample` weight row. **Decision:** is a persisted weight required for Honda traceability / OEE? If yes, add a weight-capture proc.

### G-3 — Sort-cage serial migration (UJ-05 / FAT-MOVE-190/200 / TRC-170) 🟡 future
`SORTCAGE` is a **dumb vision-sort conveyor** — its serial registers (`L9:5`, `N19:x`) are declared but **never referenced in ladder**; it has **no scan, no re-serialize, no print, no void, no AIM**. So the entire sort-cage serial-migration concept (re-serialize / mint new LTT / void old label / AIM UpdateAim) is **100% MES-orchestrated**, keyed off (a) the recipe/job the MES pushed down and (b) the good/bad result it reads. This aligns with the terminal-mint reframe (TRC-170: a same-part consume-mint at the sort station, not a `Lot_Merge` gate). **Highest traceability-loss-risk item (OI open UJ-05)** — needs the MPP Quality + Honda compliance decision before speccing.

---

## Recommended spec decomposition

| Spec | Covers | FDS | Effort | Gate |
|---|---|---|---|---|
| **P1** | PLC-020 seed + PLC-030 sim closeout | 10-001/002 | small | do first — unblocks everything |
| **P2** | consecutive-fail escalation | 10-009 | medium | ⚪ confirm MVP vs commissioning |
| **P3** | failure-type branching | 10-010 | small→large | 🟡 Option A now / B needs Cognex job map |
| **P4** | ConfirmationMethod + dual-source | 10-013 | small-med | needs P2 proc; confirm which Cells are `Both` |
| G-1 | non-serialized completion | 06-013 | small | 🟡 line-config source decision |
| G-2 | scale weight persistence | 10-006 | small | 🟡 is it required? |
| G-3 | sort-cage serial migration | 07-007/UJ-05 | medium | 🟡 Honda/Quality decision (highest risk) |

**Build sequence:** P1 (seed, immediately) → P2 → P3(A) → P4, then G-1/G-2 as decisions land; G-3 held on the UJ-05 compliance decision.

**Open questions for MPP / the Cognex integrator:**
1. Are PLC-120/130/220/230 **MVP or commissioning-phase**? (gates P2–P4 timing)
2. Cognex job **output map** — what do `N17:4/0..2` mean? Does the job compute orientation / a placard (`N7:100`) check? (unblocks P3 Option B)
3. Which Cells genuinely run `Both` confirmation, given no scanner exists in the vision I/O? (P4)
4. `MPPMACH` "3-in-a-row" threshold — data preset `30` vs symbol `3`: intended value? (readiness)
5. `5A2_*` Pro-face cells — true serialized MIP or MES→HMI command-only? (G-1)
