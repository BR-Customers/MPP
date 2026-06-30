# Arc 2 Plant Floor — P4-tail → P5 → P6 → P7 Build Roadmap

> **Master roadmap (umbrella plan).** This decomposes the four-phase arc into work units, the
> dependency DAG, the parallelization map, and the agent-orchestration model. Each phase gets its
> own just-in-time `writing-plans` implementation plan (the Phased Plan doc sections are the specs);
> this roadmap is the sequencing + autonomy authority over all of them.

**Goal:** Finish the agent-doable Phase 4 tail, then build Phases 5 (Machining), 6 (Assembly + MIP + Container Pack), and 7 (Hold + Sort Cage + Shipping + AIM Pool) end-to-end on `hunter/explore`.

**Architecture:** Ignition Perspective (file-authored) + SQL Server 2022, following the established Arc-2 layering (migration + repeatable procs + TDD test suite → Core Named Queries → Core entity scripts → Gateway scripts → MPP plant-floor `pf-*` views → routes).

**Decisions locked (2026-06-19):**
- **Cadence:** Autonomous run, Designer smoke **batched** — build P5, P6, P7 back-to-back, commit each, hand ONE consolidated Designer-smoke + gateway-restart + hardware checklist at the end.
- **Phase 4 tail:** an agent does the 2 CLI-doable SQL bits now; all Designer/existing-view/hardware items fold into the consolidated handoff.

---

## 1. Sequencing & dependency DAG

The cross-phase **SQL layer is a strictly serial spine** — one migration at a time, each owned by a single agent. (Rationale: the project has been bitten by audit-Id / stale-base migration collisions when SQL was authored in parallel — see the Phase 3 stale-base incident. One owner per migration.)

```
P4 (SQL done, green) ──> P5 SQL ──> P6 SQL ──> P7 SQL      [SERIAL spine]
                          │            │           │
                          ▼            ▼           ▼
                     views+scripts  views+scripts  views+scripts   [PARALLEL fan-out within each phase]
```

Dependency facts:
- **P5** depends only on Phase 4 procs, all of which exist (`Lot_GetWipQueueByLocation`, `Lot_Split`, `Lot_MoveTo`, `ProductionEvent_Record`, `LotGenealogy_RecordConsumption`). → **P5 SQL is buildable now.**
- **P6** CREATEs the Container family and consumes P5's machined-LOT flow → starts after P5 SQL lands.
- **P7** operates on P6's Container family (Hold / Sort / Ship / AIM) → starts after P6 SQL lands.

**Real parallelism lives in two places:**
1. **Intra-phase fan-out:** once a phase's SQL + NQs + entity scripts land, its Perspective views and gateway scripts are built by multiple agents concurrently (the Phase 4 model: "3 views via parallel subagents").
2. **Cross-phase planning overlap:** while phase K's views/scripts are being built, the orchestrator runs `writing-plans` for phase K+1 (planning is read-only on the serial SQL spine).

## 2. Autonomy boundary

**Agents CAN do autonomously:** SQL migrations + repeatable procs + **TDD test suites**, Core Named Queries, Core entity scripts, Gateway (Jython) scripts, **brand-new** Perspective views (new `view.json` is safe to file-author), routes (`page-config/config.json`), smoke-seed scripts.

**Owed to Hunter (batched per the consolidated handoff):**
- **Designer smoke** of every new view (CLI-impossible).
- **Edits to *existing* views** (HomeRouter tiles, the existing TrimStation view) — file-edit boundary → Designer.
- **Gateway restart** (new Core NQs need it to register for inherited visibility; a scan is insufficient).
- **PLC / Zebra hardware integration checks** (MIP handshake, ZPL print) — dev-hardware gated.

## 3. Build cadence (locked: autonomous run, smoke batched)

Build P5 → P6 → P7 back-to-back. Each phase: SQL green → NQs → entity scripts → gateway scripts → new views file-authored → routes → smoke seed → commit. **No mid-arc pause for Designer smoke.** At the end, deliver one consolidated handoff (§7). Accepted risk: a view-pattern bug could propagate across phases before Hunter smoke-tests it — mitigated by reusing the proven Phase 4 / Phase 8 `pf-*` view patterns and by SQL being fully test-gated.

## 4. Renumbering & the P6↔P7 circular dependency

The Phased Plan's migration numbers are **stale** (it lists P5=0024, P6=0025, P7=0026; those slots are taken by P4×2 and P8). Real assignments:

| Phase | Migration | Test suite |
|---|---|---|
| P5 Machining | `0027_arc2_phase5_machining.sql` | `sql/tests/0027_PlantFloor_Machining/` |
| P6 Assembly/Container | `0028_arc2_phase6_assembly.sql` | `sql/tests/0028_PlantFloor_Assembly/` |
| P7 Hold/Sort/Ship/AIM | `0029_arc2_phase7_hold_sort_shipping_aim.sql` | `sql/tests/0029_PlantFloor_Hold_Sort_Shipping_Aim/` |

**Circular dep resolution:** P6's `Container_Complete` claims an AIM ID via `AimShipperIdPool_Claim` and inserts a `ShippingLabel` row. So **migration `0028` (P6) CREATEs** the Container family + `ShippingLabel` + `AimShipperIdPool` + `AimPoolConfig` tables and ships a **minimal `AimShipperIdPool_Claim` + `_Topup`** (enough for `Container_Complete` to be self-consistent and testable). **Migration `0029` (P7)** adds the Hold / SortCage / `ContainerSerialHistory` tables and the AIM pool *lifecycle* (depth reads, tier alarms, `AimPoolConfig` CRUD, the Gateway topup loop) on top.

**Housekeeping (non-blocking):** two `0026_*` test-suite folders coexist post-merge (`0026_PlantFloor_Downtime_Shift` + `0026_Tools_CellMount`). Leave as-is for now; only ensure new suites are `0027+`.

## 5. Per-phase work units

### Phase 4 tail (agent — 2 CLI bits)
- `sql/scratch/smoke_seed_phase4.sql` — dev seed so the Trim/Receiving views show data.
- A Machining-line-scoped destination read proc + NQ for the TrimStation OUT dropdown (replaces the generic all-cells list).
- *(Owed to Hunter: Designer smoke of the 3 P4 views, HomeRouter Trim/Receiving tiles, TrimStation IN checkpoint inputs + OUT dropdown swap, gateway restart, Zebra print check.)*

### Phase 5 — Machining (`0027`)
- **SQL agent (serial):** `RequiresSubLotSplit` ALTER on `OperationTemplate`; `MachiningIn_PickAndConsume` (composite: BOM-rename, mint machined LOT, ConsumptionEvent + genealogy + checkpoint, close source); `MachiningOut_AutoComplete` (PLC, coupled/uncoupled); `MachiningOut_RecordSplit` (sublotting); OperationTemplate + LogEventType seeds; test suite `0027` (target 80–110).
- **Parallel agents (after SQL+NQs+scripts):** Machining IN view (FIFO queue repeater + pick); Machining OUT Split view (Flex-repeater destination selectors) + BOM-Driven Rename Confirmation Modal + Cell-Selector-Repeater-Entity components; `MachiningOpCompleteWatcher` gateway script.

### Phase 6 — Assembly + MIP + Container Pack (`0028`)
- **SQL agent (serial):** Container family CREATE (`Container`, `ContainerTray`, `ContainerSerial`, `SerializedPart`, `ShippingLabel`) + `AimShipperIdPool`/`AimPoolConfig` (per §4) + `ContainerStatusCode` seed; procs `Container_Open`, `ContainerTray_Close`, `ContainerSerial_Add`, `SerializedPart_Mint`, `Container_Complete`, `ConsumptionEvent_RecordWithBomCheck`, minimal `AimShipperIdPool_Claim/_Topup`; seeds; test suite `0028` (target 100–135).
- **Parallel agents:** Assembly Serialized view; Assembly Non-Serialized view; Confirmation Method Resolver + Print Failure Banner + Material Substitute Override Modal components; `AssemblyMipHandler` + `NonSerializedLineHandler` + `ShippingLabelDispatcher` gateway scripts.

### Phase 7 — Hold + Sort Cage + Shipping + AIM Pool (`0029`)
- **SQL agent (serial):** `Quality.HoldEvent` + `HoldTypeCode` seed, `Lots.ContainerSerialHistory`, AIM pool lifecycle procs (`_GetDepth`, `_GetByContainer`, `AimPoolConfig_Get/_Update`); `Hold_Place`/`Hold_Release`/`Hold_GetOpenBy*`; `Container_Ship`, `ShippingLabel_Void`/`_Reprint`, `SortCage_MigrateSerial`; seeds; test suite `0029` (target 90–120).
- **Parallel agents:** Hold Management view; Sort Cage Workflow view; Shipping Dock view; AIM Pool Configuration view + AIM Pool Wallboard Tile; 6 gateway scripts (`AimPoolTopup`, `AimPoolAlarmMonitor`, `AimHoldHandler`, `AimUpdateHandler`, `PrintFailureSafetySweep`, `PrintFailureBroadcaster`).
- Build against documented defaults for open items: **OI-33** AIM empty-pool hard-fail; **UJ-05** Sort Cage update-in-place (`ContainerSerialHistory`). Flag both as pending Phase 0 customer validation.

## 6. Execution model (agent orchestration)

Per phase, the orchestrator (this session):
1. Runs `writing-plans` for the phase (spec = the Phased Plan section), producing the bite-sized implementation plan.
2. Dispatches **one SQL subagent** to build the migration + procs + tests via inline TDD; reviews on return; runs the full suite with the **`ignition` login-disable guard** around the reset (the gateway holds a single-user-mode connection pool to `MPP_MES_Dev` — disable `ignition`, reset/test, re-enable — see the merge-recovery incident).
3. Once SQL is green, builds the NQs + entity scripts (small — inline or one agent).
4. Dispatches **parallel subagents** for each view and each gateway script.
5. Converges: routes, `scan.ps1`, commit. Then runs `writing-plans` for the next phase while the current phase's view agents finish (overlap).
6. After P7: assemble the consolidated Hunter handoff (§7).

Subagent dispatch uses `superpowers:subagent-driven-development` (fresh subagent per task + two-stage review).

## 7. Consolidated Hunter handoff (delivered after P7)

- **Gateway restart** (registers all new Core NQs for inherited visibility).
- **Designer smoke** of every new view across P4-tail/P5/P6/P7, grouped by phase.
- **Existing-view edits** that need Designer: HomeRouter tiles (Trim, Receiving, Machining, Assembly, Hold, Shipping, etc.).
- **Hardware checks:** PLC `OperationComplete`/MIP handshake (P5/P6), Zebra ZPL print (P4/P6), OmniServer scale (P6 ByWeight).
- **Smoke seeds** to re-run per phase (`smoke_seed_phase4/5/6/7.sql`).
- **Open-item confirmations:** OI-33 (AIM empty-pool), UJ-05 (Sort Cage), OI-37 (break durations), and the pre-existing `DataCollectionField_Create`/`@DataTypeId` blocker (Msg 3915; not in this arc but the one non-green item in the suite).

## 8. Risks & open items

- **`DataCollectionField_Create` Msg 3915** (pre-existing): proc doesn't supply `DataTypeId` (NOT NULL since `0023`). Fails no assertions but makes the runner exit 1. Recommend a small fix early (a `@DataTypeId` path on Create) so the suite goes fully green — confirm with the owner.
- **Designer-smoke debt accumulates** across three phases before verification (accepted per the cadence decision).
- **PLC/Zebra/scale integration** is entirely dev-hardware gated — the gateway scripts are built + unit-reasoned but not hardware-verified until Hunter runs the checks.
- **OI-33 / UJ-05** built to documented defaults; a customer-validation reversal would require rework in P7.
