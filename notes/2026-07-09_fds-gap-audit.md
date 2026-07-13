# FDS Gap Audit + PLC Integration Readiness — 2026-07-09

Two-agent audit on `hunter/explore` (post terminal-mint merge): every FDS MVP requirement
cross-checked against the built procs/views/tests, plus an architecture review of the four
PLC touchpoints. FUTURE-scoped items excluded per the Scope Matrix.

---

## A. MISSED (MVP) — genuinely absent, grep-verified

Two coherent slices plus a handful of singles:

### A1. Quality inspection capture (the biggest gap)
- **FDS-08-011** Inspection Recording — `QualitySample`/`QualityResult` tables are spec'd in the
  Data Model but never migrated; no inspection screen. (Quality Spec *authoring* is built;
  the consuming side is not.)
- **FDS-08-012** Failed-inspection handling (inspector alert, no auto-hold) — stacks on 08-011.
- **FDS-08-013** Quality attachments (`QualityAttachment`) — absent.
- **FDS-10-012** Controlled Run Tag workflow — `Lot.CrtActive` column exists and is displayed,
  but no CRT procs/workflow; also blocked by missing QualitySample. Ratified MVP 2026-06-08.

### A2. FDS §12 reporting & search screens
Data is captured for all of these; the report/search surfaces are not built:
- **FDS-12-005** Die Shot Report, **12-006** Rejects Report, **12-007** Downtime Report,
  **12-008** Production Report.
- **FDS-12-002** Serialized item search (by PartSN), **12-003** Container search.
- **FDS-12-013/014** trace input resolver only handles LOTs (serial/container/shipper inputs absent);
  **12-012** Home "Track" tile missing (GenealogyViewer route exists).

### A3. Singles
- **FDS-09-012** Shift Schedule import proc (cutover-time item, cf. OI-34).
- **FDS-10-005/009/010** vision line-stop + 10-consecutive-fail escalation + failure-type
  branching — partially hardware-gated, but the escalation state machine is design work that
  can be pre-built (see PLC section).
- **FDS-01-013/14-005** Flexware BOM bulk-load proc — manual seed-script path exists; confirm
  whether a one-shot proc is required for cutover.

## B. BUILT BUT UNVERIFIED (the test-me list)

1. **Terminal-mint views** — MachiningOutSplit mint form, route-driven queues, ranked-FG
   default (SQL tested; Designer smoke owed).
2. **2026-07-08 merge re-smoke** — TerminalSelector, DieCast*, RejectPanel, TrimBody, LotDetail,
   HistoryRow, Trim/InventoryRow + the reworked script modules.
3. **Assembly Spec-2 flow** — complete-tray → FG LOT → container complete; InventoryManager.
4. **Config Tool latest** — Category filter/cascade popup, Item deprecate-cascade confirm.
5. **Downtime Phase 8** — End-of-Shift, Shift-End Summary, Supervisor Dashboard (also: dashboard
   Paused/Availability tiles are stubs; FDS-09-013 ±15-min gating not wired).
6. **Presence/identity UI** (FDS-04-002/003/005/006) — no recorded dedicated smoke.
7. Long-owed visuals: ConfigChangeDetail color-diff, Quality state badges.
8. **Suite hygiene**: `010_Parts_codes_crud` thrower + demo-seed-dependent `0024/060` make every
   full run exit non-zero — masks real regressions; worth fixing as standalone cleanups.

## C. FDS PROSE STALE (superseded by terminal-mint — rewrite owed, not missed)
FDS-05-033 (rename BOM), FDS-06-007 (rename-at-IN queue), FDS-06-008 (+§6.4 coupling/AutoComplete),
FDS-05-009/010/011 partial (split demoted to exception-only). Data Model coupling/split prose
flagged in its v2.0 changelog.

## D. CONDITIONAL — confirm with MPP
Sampling (08-014/015 — note base inspection 08-011 is also unbuilt, so a "yes" costs more than
the FDS implies); operator-facing Work Orders (invisible auto-gen IS built); Data Migration
(14-002/003/004); Flexware BOM import proc; SCADA alarming.

## E. EXTERNAL / HARDWARE GATED
- **AIM (Honda EDI)** — the one unbuilt external; pool machinery + hard-fail + depth alarms built
  and tested, `AimPoolGateway` is sim-only (no HTTP endpoint).
- **Zebra printers** — software-complete, hardware-gated.
- **Scales / Cognex / assembly PLCs / downtime PLC triggers** — see PLC section.

---

## F. PLC INTEGRATION READINESS

**Verdict: the architecture is genuinely PLC-ready.** The three-layer rule (View → entity →
Common.Db → proc) held; every mutation a PLC needs is a gateway-callable status-row proc with
explicit `appUserId`/`terminalLocationId` params (no hidden `session.custom.*` reads on those
paths); two of four touchpoints already have sim-ready gateway-timer stubs on an identical
"thin dispatcher → Core module with `_WATCH` config" pattern (`DowntimePlcWatcher` is the
mature reference; `AssemblyMipWatcher` has edge detection built with a documented
`_handlePiece` skeleton). The retired coupling path (`MachiningPlc`) is a proper tombstone.

### Touchpoint state
| Touchpoint | Watcher | Mutation surface |
|---|---|---|
| Downtime PLC | sim-ready, most mature | complete (incl. DB-side idempotency) |
| MIP serialized assembly | edge detection built, `_handlePiece` skeleton | mostly complete (gaps below) |
| Scales / ByWeight | none | schema complete (WeightValue, ClosureMethod, TargetWeight); watcher missing |
| Cognex vision | none | least built — line-stop/escalation not written (overlaps missed 10-005/009/010) |

### Gaps that would force rework later
1. **No serial lookup/validate surface** — `SerializedPart_Mint` only allocates from the sequence;
   no `@SerialNumber` input, no `SerializedPart_GetBySerial`. FDS-10-002/003 needs read-and-validate
   of the PLC-reported PartSN (duplicate = validated status row, not a constraint violation).
2. **A4 etch-vs-completion ordering** — the deferred customer decision blocks the MIP handler's
   shape (`ProducingLotId` NOT NULL at etch vs FG LOT minted at completion). Zero code; get it
   on the next MPP agenda.
3. **Ad-hoc PLC attribution** — `_SYSTEM_APP_USER_ID = 1` duplicated in two modules; no verified
   system-user seed; watchers pass NULL terminal so machine events are indistinguishable from
   unattributed manual ones.
4. **`_WATCH` is config-in-code** — commissioning = editing a Core module. Should move to
   LocationAttributes on the Cell (the FDS-10-013 `ConfirmationMethod` precedent).
5. **Edge state in module memory** — resets on every scan; downtime self-heals via the DB guard,
   MIP has no durable guard yet; MIP likely needs project Tag Change events (latency) not a timer.
6. **ByWeight tray closure discards the measured weight** — no `ContainerTray.ObservedWeight`;
   a Honda traceability question waiting to happen.

### Cheap enabling moves (ranked)
1. `Lots.SerializedPart_GetBySerial` (+ NQ + entity) — the validate primitive; useful today.
2. Optional `@SerialNumber` on `SerializedPart_Mint` (external-serial path) — or document that MES
   mints and pushes to the laser. Partially gated on A4 → **put A4 on the next MPP agenda**.
3. Centralize `systemAppUserId()` in Common.Util + seed a verified system AppUser + pass
   `terminalLocationId` from watchers.
4. Move `_WATCH` to Cell LocationAttributes (`PlcStopTagPath`, `MipDataReadyTagPath`, …); seed
   `ConfirmationMethod` at the same time.
5. Stand up `ScaleWatcher`/`ScalePlc` no-op stub in the established pattern; add
   `ContainerTray.ObservedWeight DECIMAL NULL` while schema changes are cheap; decide
   timer-poll vs Tag Change per touchpoint.
6. Write the tag-namespace convention doc; pick the InterfaceLog-vs-OperationLog rule for
   handshake transactions.

### Commissioning-gated (correctly deferred)
Real OPC connections + tag maps; full MIP handshake state machine (TransInProc/PartValid/
WatchDog/AlarmMsg/ContainerCount, NoRead windows, timeouts); vision line-stop observation;
poll-rate tuning; scale calibration + weight-to-count semantics.

---

## Suggested order of attack
1. **Decisions to MPP/Jacques now (zero code):** A4 etch ordering; Sampling + WO + Data-Migration
   + SCADA conditionals; BOM import mechanics; weight-prefill semantics.
2. **Testing next:** the §B smoke list — most of the "unverified" is one thorough Designer
   smoke session away.
3. **Build slices, in rough priority:** Quality inspection capture (08-011/012/013 → unlocks CRT
   10-012) → §12 reports/searches (data all exists; read procs + screens) → PLC enabling moves
   1–4 (small) → shift-schedule import (cutover window).
