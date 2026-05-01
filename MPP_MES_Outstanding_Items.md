# MPP MES — Outstanding Items for Review

**Document:** FDS-MPP-MES-OUTSTANDING-001
**Version:** 2.0 — Working Draft
**Date:** 2026-05-01
**Source:** Open Issues Register v2.17 (2026-05-01)
**Prepared By:** Blue Ridge Automation
**Prepared For:** Madison Precision Products, Inc. (Madison, IN)

This document is a focused extract of the **6 items currently ⬜ Open** in the Open Issues Register after Jacques's 2026-05-01 closure pass. It is intended as a working / discussion document — pull each item into the appropriate Phase 0 customer-validation walkthrough or architecture review session. The full register (which includes the 47 already-resolved items for context) lives in `MPP_MES_Open_Issues_Register.md` / `.docx`.

Each item retains its original `OI-NN` / `UJ-NN` identifier. Cross-references between items are noted per entry.

---

## Revision History

| Version | Date | Author | Change Summary |
|---|---|---|---|
| 2.0 | 2026-05-01 | Blue Ridge Automation | **Reduced to 6 items** after Jacques's 2026-05-01 markup closed 9 of the original 15 (OI-07, -24, -25, -27, -28, -29, -30, -31, UJ-03 → all ✅ Resolved per OIR v2.17). UJ-19 confirmed in MVP scope (the four PD reports are deliverables); reports beyond the four are post-deployment change order per OI-30 closure. |
| 1.0 | 2026-05-01 | Blue Ridge Automation | Initial extract of the 15 outstanding items (2 In Review + 13 Open) from OIR v2.16. Customer-facing working draft. |

---

## Summary

**6 outstanding items, all ⬜ Open.** No items are In Review.

### Priority breakdown

| Priority | ⬜ Open | Items |
|---|---|---|
| HIGH | 3 | OI-33, OI-35, UJ-19 |
| MEDIUM | 3 | OI-32, OI-34, UJ-05 |
| **Total** | **6** | |

### Quick index

| # | ID | Title | Priority | Owner | Coupled to |
|---|---|---|---|---|---|
| 1 | OI-32 | Material Allocation operator screen | MEDIUM | Blue Ridge / Ben | UJ-09 (resolved), OI-18 (resolved) |
| 2 | OI-33 | AIM Shipper ID pool empty-pool hard-fail | HIGH | MPP Operations / IT | UJ-04 (resolved) |
| 3 | OI-34 | Production schedule leverage | MEDIUM | MPP Production Control | UJ-19, OI-30 (resolved) |
| 4 | OI-35 | Long-horizon scaling, retention, archiving | HIGH **HARD GATE** | Blue Ridge architecture + MPP IT | OI-23 (resolved) |
| 5 | UJ-05 | Sort Cage serial number migration | MEDIUM | MPP Quality + Honda | — |
| 6 | UJ-19 | Productivity DB replacement (4 reports) | HIGH | Ben + MPP Production Control | OI-30 (resolved), UJ-11 (resolved), OI-31 (resolved) |

### 🚨 Hard-gate items

Two items must resolve before Arc 2 Phase 1 SQL build (`0014_arc2_phase1_shop_floor_foundation.sql`) commences:

- **OI-35** — Long-horizon scaling, retention, archiving strategy. Several architectural decisions (partition functions, materialization columns, closure-table presence, OperationLog split) must be in the **CREATE migration** for the affected tables. Retrofitting them to populated 100M+ row tables is operationally expensive.
- **Phase 0 Customer Validation Workshop** — covers OI-32, OI-33 from this list, plus several non-OIR items requiring sign-off (WorkOrder BIT-flag enumeration, historical data migration scope, ShotCount semantics, Workstation seeding, Honda AIM Hold contract detail, label template scope).

OI-34 + UJ-05 + UJ-19 are not Arc-2-Phase-1 gates — they can be answered later in the schedule without delaying the SQL build. All other Arc 2 work (Perspective screens, Configuration Tool extensions, mockup) remains unblocked.

---

# Outstanding Items

---

## 1 · OI-32 — Material Allocation operator screen — ⬜ Open

**Priority:** MEDIUM
**Owner:** Blue Ridge / Ben
**FDS §:** 5.11 or §6.6a (new section — Allocate Material workflow)
**References:** Legacy Storyboards PDF screen-map family (`MaterialAllocationMenuView` / `MaterialAllocationView` / `MaterialAllocationCreateView` / `MaterialAllocationUpdateView` / `BomComponentDetailsView`); `Workstation.MaterialAllocationRequired BIT`; couples to UJ-09 (resolved — material verification at assembly) and OI-18 (resolved — ItemLocation consumption metadata)

**Description:** Flexware has a dedicated pre-production **Material Allocation** capability separate from scan-time material verification. An operator (or changeover technician) pre-allocates N baskets of a BOM component to a specific Cell; the allocation shows up on a grid at the workstation; the PLC handshake consumes **against** the allocation rather than against raw LOT scans. Flexware `Workstation.MaterialAllocationRequired BIT` gates whether this is mandatory per terminal.

Our current design has the **data** for allocation via OI-18 (`Parts.ItemLocation.MinQuantity` / `MaxQuantity` / `DefaultQuantity` / `IsConsumptionPoint`) but **no explicit operator screen** and no `Workorder.MaterialAllocation` lifecycle table. FDS-06-011 covers verify-on-scan but not pre-allocate.

**Options considered:**
- (a) Build `Workorder.MaterialAllocation` table (Cell, Item, AllocatedQuantity, ConsumedQuantity, AppUserId, AllocatedAt, ReleasedAt) + Perspective Allocate Material screen + consumption gate in `ConsumptionEvent_Record`.
- (b) Confirm MPP doesn't use the step and close as "intentionally not reproduced."
- (c) Allocate implicitly on first scan (current FDS posture) but expose a read-only "current allocations at this cell" grid on the Assembly view for operator awareness.

**Clarification exchange (2026-04-24):**

**Jacques's pushback:** *"Parts are 'checked into' Line side storage that can then be consumed by the station or Cell. The line side storage is a typedefinition of Cell. I clearly don't understand the tension with consumption here. Please elucidate."*

**Response (Blue Ridge, 2026-04-24):** The tension flagged does not exist in our model. In Flexware, `MaterialAllocation` is a separate pre-production workflow step where an operator declares "these N baskets are allocated to this cell" as a dedicated action *before* the PLC handshake runs. The allocation exists as a DB row even though the baskets are just physically staged. It is a workflow artifact of Flexware's data model, not a real-world step.

Under our design:
- **Lineside storage IS a `LocationTypeDefinition` under Cell** — per Jacques's 2026-04-24 note.
- An operator "checks in" a LOT to that lineside Cell via a normal `LotMovement` event (the scan-in).
- When the production Cell consumes from the lineside LOT, our `ConsumptionEvent` captures it with full genealogy.
- The operator's "what's at my lineside" grid is answered by a simple read query (`Lots.Lot_ListByLocation @LocationId = <lineside cell id>`), not a separate allocation table.
- The Flexware `Workstation.MaterialAllocationRequired BIT` is satisfied in our model by the act of scanning the LOT into the lineside Cell — the movement itself IS the allocation.

**Revised resolution:** Close OI-32 as **not-reproduced** on the same grounds as OI-32b. No new `Workorder.MaterialAllocation` table needed. No separate Allocate-Material Perspective screen needed. The Flexware concept collapses cleanly into our existing LOT-at-location + ConsumptionEvent model.

**What's needed to close:** Phase 0 question to Ben confirming the revised "close as not-reproduced" framing. Specifically: *"Do operators pre-allocate baskets of material to Assembly / Machining cells before production begins as a dedicated separate action, or is allocation implicit in the first LTT scan into the lineside Cell?"*

**Impact if unresolved:** Arc 2 Plan Phase 6 (Assembly + MIP + Container) cannot finalize design.

---

## 2 · OI-33 — AIM Shipper ID pool empty-pool hard-fail behavior — ⬜ Open

**Priority:** HIGH
**Owner:** MPP Operations / IT
**FDS §:** 7.4 (FDS-07-010a)
**References:** UJ-04 (resolved 2026-04-27 — pool design locked); FDS-07-005 (Container_Complete atomic close); FDS-07-010 (pool topup); FDS-07-010a (empty-pool behavior); `Lots.AimShipperIdPool` + `Lots.AimPoolConfig` (Data Model v1.9h)

**Description:** UJ-04 closed the AIM Shipper ID design as a pre-fetched local pool with synchronous FIFO claim at `Container_Complete`. The 2026-04-28 FDS continuity pass surfaced one customer-validation question still outstanding: **what happens when the pool is empty at close time?** The current FDS-07-010a posture is **hard-fail**: `Container_Complete` raises a business-rule error, the open transaction rolls back, the operator sees an explicit "AIM pool empty — contact IT" error, and the line stops on affected workstations until the topup script refills the pool. There is no soft-fallback, no placeholder-then-reconcile pattern, no offline-mode AIM ID generator.

**Why this is a customer-validation question:** Trucks cannot ship without valid Honda-issued AIM IDs printed on container labels. Any soft-fallback (placeholder ID, locally minted ID with later swap, queued pending-AIM container state) creates a window in which a container exists physically but has no valid Honda identifier — and the reconciliation flow if Honda later refuses the ID is non-trivial. The hard-fail posture trades operational availability (line stops immediately on pool exhaustion) for traceability integrity (every closed container has a real Honda ID at close time, period).

**Operational mitigations already in place:**
- `Lots.AimPoolConfig` thresholds (`TargetBufferDepth=50`, `TopupThreshold=30`, `AlarmWarningDepth=20`, `AlarmCriticalDepth=10`) give a topup script and a two-tier alarm (supervisor wallboard at Warning, supervisor + IT alert at Critical) ample headroom — reaching `0` requires the topup script to be fully broken AND the Warning + Critical alarms to be ignored for the burn rate to consume the remaining buffer.
- `AIM.GetNextNumber` is sync direct-call (no MES-side dependency); pool exhaustion only happens if AIM itself is unreachable (network / Honda-side outage) or the topup Gateway script is failing.
- The Configuration Tool exposes the four thresholds — MPP can raise `TargetBufferDepth` if their burn rate justifies more headroom.

**Options considered:**
- **(a) Hard-fail (current FDS-07-010a posture)** — Container_Complete rejects on empty pool; line stops; operator sees error; recovery = topup script catches up, then operator re-attempts the close. Pro: traceability integrity preserved at close time; no reconciliation flow needed. Con: line stops on AIM/network outage even if the local pool was nearly full when the outage began.
- **(b) Soft-fallback with placeholder-then-reconcile** — Container_Complete proceeds with a locally minted placeholder ID (e.g., `MESC-tmp-NNNNNN`); a background reconciliation script swaps the placeholder for a real AIM ID once the pool refills; the printed label is reprinted at swap time; if Honda later rejects the ID at receipt, a manual workflow handles the dispute. Pro: line never stops. Con: window where containers physically exist with non-Honda IDs; reprint labor; reconciliation flow + Honda-rejection edge case to design.
- **(c) Pre-emptive line-pause at low-pool** — when pool depth drops below a configurable LineHaltThreshold (e.g., 5), block further `Container_Complete` calls **before** depth hits zero, with a softer error and a supervisor-override path. Pro: graceful slow-down vs. cliff-edge stop. Con: extra threshold to tune; supervisor override still has to be used responsibly.

**Recommended direction:** Confirm Option (a) — hard-fail. It matches the existing FDS-07-010a text and is consistent with how Honda treats AIM IDs (every issued ID is permanently consumed, no expiry). The two-tier alarm + topup script + configurable buffer depth give MPP operational levers to never reach the cliff edge under normal conditions. Option (b) is rejected — placeholder reconciliation introduces a window of broken traceability that is exactly what the AIM-issued-ID model exists to prevent. Option (c) MAY be reconsidered post-deployment if MPP observes pool depth approaching the floor in production, but is unnecessary up front given the headroom configured.

**What's needed to close:** Phase 0 customer-validation answer from MPP Operations + IT: *"On AIM pool empty at container close time, do you want hard-fail (line stops; current design) or do you want a soft-fallback / pre-emptive halt? Acknowledge that hard-fail prioritizes traceability integrity over availability."*

**Impact if unresolved:** No design change required to keep building toward MVP — the FDS-07-010a hard-fail posture is the implemented behavior. This is a customer-acceptance question, not a build-gating question. Resolution either (i) confirms the current design (no work) or (ii) triggers a redesign of `Container_Complete` + reconciliation Gateway scripts + label-reprint flow (significant scope addition).

---

## 3 · OI-34 — Production schedule leverage beyond shift-window timing — ⬜ Open

**Priority:** MEDIUM
**Owner:** MPP Production Control
**FDS §:** 9.4 (FDS-09-008 / FDS-09-012)
**References:** FDS-09-008 (Shift instance creation from authored schedule); FDS-09-012 (event-derived availability math against shift windows); UJ-19 (Productivity DB replacement); OI-30 (Reports tile scope — resolved 2026-05-01)

**Description:** Our current design imports MPP's authored production schedules and uses them for two purposes: (1) creating `Oee.Shift` instance rows with the right start / end timestamps so OEE math has shift windows to bucket events into (FDS-09-008), and (2) deriving availability against those shift windows from the operator-driven event stream (FDS-09-012). The FDS continuity pass on 2026-04-28 surfaced that this is a **minimal use** of authored-schedule data — MPP may want the MES to leverage the schedules more substantively.

**Possible additional uses (not yet scoped):**
- **Per-shift target quotas** — schedule carries a target quantity per Item per shift; the MES displays attainment vs. target on the workstation banner, the supervisor dashboard, and the shift-end summary screen (FDS-09-015). Schema impact: add `TargetQuantity INT NULL` and `ItemId BIGINT NULL FK` to `Oee.Shift` (or a new `Oee.ShiftPlan` child table if multiple Items per shift are common).
- **Line scheduling drift detection** — compare actual shift-instance run time and actual quantity against the authored schedule; surface drift > X% as a supervisor alert. Schema impact: same as above + drift-threshold LocationAttribute on Line / WorkCenter.
- **Throughput / forecast planning** — feed the MES's actual availability + performance numbers back to MPP Production Control as an input to their next planning cycle. Likely a Reports candidate (subject to the MVP / change-order boundary OI-30 already locked).
- **Tool / Cell scheduling** — authored schedule includes which Tool runs on which Cell at which time; the MES warns on Tool / Cell mismatch at Lot creation. Schema impact: link `Oee.ShiftPlan` to `Tools.Tool` and `Location.Location` (Cell). Note: this is FUTURE territory — current design has Tool assignment authoritative on `Tools.ToolAssignment`, not on a schedule.
- **None — stop at the current minimal use** — authored schedules drive shift-window timing only; everything else stays operator-driven.

**Why this is open:** MPP gave us authored schedules to consume but did not explicitly tell us *which* of the above (or others not listed) they want the MES to use. We made a reasonable starting choice (shift-window timing only — the smallest defensible scope) and parked the rest. This is a discovery question, not a design defect.

**Couples to:**
- **UJ-19** — Productivity DB replacement. The four PD reports MPP names may include schedule-attainment reports (per-shift target quotas) — answers to UJ-19 may resolve OI-34 directly.
- **FDS-09-015** — Shift-end summary screen (UJ-10 closed). Adding target attainment lines to that screen is the natural surface area if Per-shift target quotas is in scope.

**What's needed to close:** Phase 0 walkthrough question to MPP Production Control: *"Beyond using your authored schedules for shift-window timing, what else should the MES do with them? Examples: per-shift target quotas displayed at the workstation, drift detection alerts, schedule-attainment reports, etc. Or is the current minimal use sufficient?"* Couples best with the UJ-19 walkthrough — same SME, overlapping scope.

**Impact if unresolved:** No design change required to keep building toward MVP — the current FDS-09-008 / FDS-09-012 minimal use is implemented. This is a scope-expansion question. Resolution either (i) confirms the current scope (no work) or (ii) triggers a Phase 9 (Oee) revisit + possible schema additions to `Oee.Shift` / new `Oee.ShiftPlan` child + workstation banner additions.

---

## 4 · OI-35 — Long-horizon scaling, retention, and archiving strategy — ⬜ Open / **MUST DECIDE BEFORE ARC 2 PHASE 1 SQL BUILD**

**Priority:** HIGH
**Owner:** Blue Ridge architecture + MPP IT (retention policy negotiation)
**FDS §:** 11 (Audit) — retention policy paragraph; cross-cutting impact on §5/§6/§9
**References:** Indexing & query-perf review at `Meeting_Notes/2026-04-28_DataModel_Indexing_Scaling_Review.md`; FDS-11 audit retention paragraph; existing data model spec for `Lots.LotGenealogy` / `Lots.Lot` / `Workorder.ProductionEvent` / `Audit.OperationLog` / `Lots.IdentifierSequence`; `Lots.v_LotDerivedQuantities` view (OI-23, Resolved); the queued indexing pass on Arc 2 deferred tables.

**Description:** The legacy MES retention requirement is **20 years** of historical data (Honda Tier 2 supplier compliance + product-life traceability). At MPP's observed throughput (~150K LOTs / year derived from the Flexware `IdentifierFormat` baseline of `Lot=1,710,932` after ~10–15 years of operation), and accounting for system-wide event amplification, a 20-year horizon implies these per-table volumes:

| Table class | 20-year row estimate |
|---|---|
| `Lots.Lot` | 3–5M |
| `Lots.LotGenealogy` | 10–15M |
| `Lots.LotMovement` / `LotStatusHistory` / `LotAttributeChange` | 100–200M each |
| `Lots.ContainerSerial` | 50–80M |
| `Workorder.ProductionEvent` / `ConsumptionEvent` | **150–300M** each |
| `Audit.OperationLog` | **300M–1B** |
| `Audit.InterfaceLog` | **300–600M** |

The audit + interface tables are structurally larger than the entire traceability dataset. A 20-year blanket retention policy without architectural mitigations is not tractable on a single SQL Server 2022 instance — query plans against unpartitioned 1B-row tables degrade beyond useful thresholds, recursive `LotGenealogy` walks for Honda audits hit timeouts, and OLTP buffer pool gets crowded out by historical data scans.

**Why this is a "must decide before Arc 2 Phase 1 SQL" gate:** Several of the architectural mitigations — partition functions, materialization columns, closure-table presence — must be in the **CREATE migration** for the affected tables. Adding a partition scheme to a populated 100M-row table is operationally expensive (rebuild, log-volume blow-up, downtime window). Adding a materialized closure table after 5 years of LOT genealogy means backfilling 50M+ ancestor pairs from a recursive walk. The schema-shape decisions made in Arc 2 Phase 1 set the ceiling on what's possible without painful migration later.

**Decision space (to discuss in architecture review):**

1. **Per-table retention class.** Negotiate which tables genuinely need 20 years vs which can carry 7-year retention. Push-back candidates: `Audit.OperationLog`, `Audit.FailureLog`, `Audit.InterfaceLog`, `Oee.DowntimeEvent`, `Audit.ConfigLog`. Honda traceability data (`Lots.*` events, `ContainerSerial`, `ShippingLabel`, `LotGenealogy`) almost certainly stays at 20 years.
2. **Partitioning scheme.** Native SQL Server 2022 range partitioning, monthly partitions, sliding-window automation. Applies to ~14 deferred high-volume event tables. Partition column is `CreatedAt` / `EventAt` / `LoggedAt` per table (already non-null on every event table by design — clean partition keys throughout). **Must be in CREATE migration.**
3. **Columnstore on aged partitions.** Convert partitions older than 90 days from rowstore to clustered columnstore. Typical 8–15× compression on event-shape data because `LotId` / `LocationId` / `AppUserId` columns repeat heavily.
4. **`Lots.LotGenealogy` materialized closure table.** Pre-compute every ancestor-descendant pair at LOT creation time (`AncestorLotId`, `DescendantLotId`, `Depth`). Honda audit query becomes O(1) lookup vs O(depth) recursion against partitioned tables. Cost: extra INSERTs at LOT creation (~4 rows per LOT in MPP's flow). Trade ~20% slower OLTP writes for "Honda audits actually return." **Must be in CREATE migration.**
5. **Materialize `TotalInProcess` / `InventoryAvailable` columns onto `Lots.Lot`.** OI-23 chose the view-based path (`Lots.v_LotDerivedQuantities`); at scale the view aggregates over 200M+ event rows per query. The deferred-decision criteria from OI-23 are now imminent — if we materialize, do it in the same `Lot_Create` / event-write procs that already touch the Lot row. The view stays as a fallback for diagnostics. **Must be in CREATE migration.**
6. **`Lots.IdentifierSequence_Next` locking model.** Single-row hot table updated on every LOT creation. ~150K LOTs/year, ~500/day in bursts → row-level update lock contention. Two paths: (a) explicit `WITH (ROWLOCK, UPDLOCK)` with serializable transaction (current implicit pattern); (b) replace with SQL Server `SEQUENCE` object — eliminates the row, native concurrency, format string applied via wrapping function. `SEQUENCE` doesn't support our `EndingValue` rollover semantics out of the box, but rollover is a 30+ year horizon problem.
7. **Split `Audit.OperationLog`.** Today every mutating proc across every schema writes here. Keep `OperationLog` for general 7-year audit, add a separate `Lots.LotEventLog` or similar for traceability-relevant subset (LOT events, container close events, ShippingLabel mints) at full 20-year retention. Cuts the largest table in the system in half. **Must be in CREATE migration.**
8. **Filtered indexes on hot subsets.** Lower-stakes per-table decision but should be made systematically: every "active subset" query (`WHERE LotStatusCodeId IN (active codes)`, `WHERE ResumedAt IS NULL`, `WHERE ConsumedAt IS NULL`, `WHERE PrintFailedAt IS NOT NULL AND BannerAcknowledgedAt IS NULL`) gets a filtered index that is 0.1–1% the size of the full table.

**Options on overall posture:**

- **(a) Defer to last responsible moment, build Arc 2 Phase 1 SQL with stub schemas.** Risk: at decision time we discover the partition / closure / materialization choices require restructuring tables we've already populated in dev. Re-runnable migrations help but don't fully insulate. **This is the current direction.**
- **(b) Make partial / conservative decisions now (partition + filtered indexes only) and defer the higher-cost items (closure table, OperationLog split).** Lower risk, but partial commits constrain later moves.
- **(c) Hold Arc 2 Phase 1 SQL until the full strategy is decided.** Highest correctness, highest schedule cost.

**Recommended direction:** **Option (a) with explicit gating.** Defer the architectural decisions, but Arc 2 Phase 1 SQL build does not commence until OI-35 is resolved. Phase 0 facilitation workshop adds OI-35 as a topic alongside the existing 8 gating items. Resolution may be a single architectural design review session between Blue Ridge architecture and MPP IT — does not require full Phase 0 customer walkthrough.

**What's needed to close:**

1. Negotiation with MPP IT on per-table retention policy — for the audit / interface log tables specifically. Single-meeting deliverable; does not gate other decisions.
2. Internal Blue Ridge architecture review covering decisions 2–7 above. Output: data model spec § "Scaling Decisions" pinning partition columns, materialization columns, closure-table schema, and `IdentifierSequence_Next` locking choice. Drives Arc 2 Phase 1 migration content.
3. Optional load test against synthetic 20-year data volumes to validate the chosen approach before production cutover. Higher-confidence-but-deferable.

**Impact if unresolved:** **Arc 2 Phase 1 SQL build cannot commence.** All other Arc 2 work (frontend / Perspective screens / Configuration Tool extensions) remains unblocked.

**Coupled items:**

- **OI-23 (Resolved)** — chose view; OI-35 may flip to materialized columns. Not a re-open; OI-23's choice was correct for MVP, OI-35 supersedes it for production scale.
- **Indexing pass on Arc 2 deferred tables** — already-queued separate follow-up.
- **FDS-11 audit retention paragraph** — currently silent on the per-table retention class. OI-35 resolution drives an FDS-11 amendment.

**Last-responsible-moment posture confirmed by Jacques 2026-04-29.** The decision is deferred but the gate is hard.

---

## 5 · UJ-05 — Sort Cage serial number migration — ⬜ Open

**Priority:** MEDIUM
**Owner:** MPP Quality + Honda compliance
**Blocks:** Sort Cage screen
**References:** FDS-07-018; FRS 2.1.10, 2.2.7

**Description:** At the Sort Cage, parts from one container can be re-sorted into a new container — for example, a held container is opened, parts are re-inspected, and good parts move to a fresh container while bad parts route to scrap. The serialized parts (those with laser-etched serial numbers) need to keep their original LOT/genealogy provenance while gaining new container associations. This is the highest traceability-loss risk in the system: getting it wrong loses Honda's part-by-part trace.

**Options:**

| Option | Storage shape | Impact |
|---|---|---|
| **A — Update-in-place + history table** (current direction, schema in place) | `Lots.SerializedPart.ContainerId` is updated to point at the new container. A `Lots.ContainerSerialHistory` row records the old `ContainerId` + the move event (`MovedAt`, `MovedByUserId`, reason). | Cleanest for "where is serial X now?" queries — the SerializedPart row always reflects current position. Audit trail in append-only ContainerSerialHistory. Schema already supports this. |
| **B — Soft-end + re-create** | The original `SerializedPart` row gets `DeprecatedAt`; a new row is INSERTed with the same `SerialNumber` but a new `ContainerId`. Both rows persist. | Preserves immutability of the original row. Query "where is serial X now?" becomes "give me the active row." Adds complexity — every read query must filter `DeprecatedAt IS NULL`. |
| **C — Cascading bulk move** | `Lots.Container_Resort` proc moves all serials from container A to container B in a single transaction; same A pattern at the row level but operationally batched. | Faster operationally for bulk re-sorts. Same row-level semantics as A. |

**Recommended direction:** A (update-in-place + ContainerSerialHistory). Already supported by schema. The `SerializedPart.UpdatedAt` + the append-only history table preserves the audit trail without splitting the SerializedPart row into multiple lifecycle records. C is a minor proc-layer optimization — `Container_Resort` can be added in Arc 2 Phase 7 if bulk re-sorts prove common.

**What's needed to close:** MPP Quality + Honda compliance affirmation that update-in-place satisfies traceability requirements (the typical Honda question is "show me every container this serial has ever been in" — answerable via `ContainerSerialHistory` join). Operational walk-through: confirm Sort Cage operators understand what re-sort does to the serial trail. Edge case: serial moves to a container, then that destination container is voided — what's the right next step? (Likely: another move event + container void event.)

**Decision (existing):** Highest traceability-loss risk of any sort scenario. Schema supports update-in-place via `ContainerSerialHistory` but the business rule needs explicit MPP Quality / Honda affirmation.

---

## 6 · UJ-19 — Productivity DB replacement — ⬜ Open

**Priority:** HIGH
**Owner:** Ben + MPP Production Control
**Blocks:** All production screens, reporting
**Maps to:** UJ-11 (paper transition — resolved), OI-30 (Reports tile — resolved 2026-05-01), OI-31 (rollout shape — resolved 2026-05-01)
**References:** FDS-15-007; FRS 5.6.6; Appendix F (Productivity DB); DCFM / MS1FM Paper Sheets

**Description:** The legacy Productivity Database (PD) is a custom Excel-and-flat-file system that operators / supervisors use today for production summaries, downtime aggregates, and shift reports. The MES replaces it. **Four named PD reports must be reproduced** — confirmed in MVP scope per OI-30 closure. Reports beyond the four are post-deployment change order. The remaining open question is the **transition shape** — do operators dual-enter for a period, or hard-cut?

**Options:**

| Option | Transition shape | Impact |
|---|---|---|
| **A — Hard cutover** | PD shuts down on MES go-live; all entry shifts to terminals; PD reports recreated as MES reports. | Cleanest reporting from day 1. Highest training burden — no fallback if MES has gaps. Operator pushback risk. |
| **B — Dual-run with reconciliation** | PD continues for N weeks alongside MES. Reconciliation tooling compares the two. Cutover when discrepancies hit acceptable threshold. | Risk reduction at cost of dual entry. Doubles operator burden during overlap. Validates MES data accuracy against the legacy ground truth. |
| **C — Phased per station** | Each station cuts over individually as terminals deploy and operators are trained. Couples to UJ-11. | Real-world operational. Adds complexity — some stations on PD, others on MES, until full rollout completes. |
| **D — Reports-first** | MES reporting layer goes live first (reading PD's data store), operators continue with paper/PD entry. Then operator-entry stations cut over. | Low-risk reporting validation. Doesn't address the entry-side transition (which is what UJ-11 is about). |

**Recommended direction:** C, mirroring UJ-11's recommended phased rollout. PD lives at any given station as long as paper does at that station. The four PD reports get implemented in MES reporting as MES data accumulates per station; until each station is fully on MES, its PD report falls back to the paper source.

**Four PD reports — needs enumeration from MPP:**
1. _(Pending — MPP names the four)_
2.
3.
4.

**What's needed to close:** Customer (likely Ben + Production Control) names the four PD reports + the data sources behind them; MES reporting subsystem replicates them. Couples to UJ-11 (paper transition — resolved). Couples to OI-30 (Reports tile — resolved; closes the boundary question). Couples to OI-31 (rollout shape — resolved; the +10K identifier-counter buffer means the rollout shape itself doesn't constrain UJ-19 timing).

**Decision (existing):** Pending customer discussion. Four PD reports must be replicated; real-time entry at the machine is the default but some stations may need a paper-first-then-enter bridge.

---

## Notes

- The full Open Issues Register (with all 47 resolved items, full revision history, and the Part A / Part B summary tables) lives in `MPP_MES_Open_Issues_Register.md` / `.docx`.
- This extract reflects OIR v2.17 (2026-05-01). Re-extract from the OIR after each MPP review session to keep this working doc in sync.
- The Phase 0 Customer Validation Workshop also covers items not in this register (because they were never folded in as OIs): WorkOrder BIT-flag enumeration (FDS-06-030), historical data migration scope, ShotCount semantics, Workstation `DefaultScreen` + `ConfirmationMethod` seeding, Honda AIM Hold/Update contract detail, and label template scope (couples to Seeding Registry S-09).
