# Load-Testing Harness — Design Spec

**Date:** 2026-07-04
**Author:** Jacques Potgieter (with Claude)
**Status:** Draft — pending review
**Branch:** `jacques/working`

---

## 1. Purpose & Goal

Prove that **normal plant production never causes performance problems** in the MPP MES, and find the point at which it *would* — i.e. the headroom margin above expected load.

The concern is **not** UI rendering or Ignition Perspective session capacity (the Gateway is expected to render sessions comfortably on the prod Stratus). The concern is the **database interaction layer**: connection requests, query throughput, lock contention, and — above all — **query performance against full, aged tables** after a year of Honda-genealogy accumulation.

Success = a repeatable harness that drives the real production code paths (stored procs, Named Queries, gateway scripts) at and *well beyond* peak production rate, against a production-scale aged database, and reports where (if anywhere) performance degrades.

## 2. Scope

**In scope**
- A backend (DB-engine) load harness driving the stored procs under concurrency.
- An Ignition data-path load harness (gateway script) driving the real Named Queries + entity scripts through the real JDBC connection pool.
- A data-aging generator that builds a 12-month, production-scale database.
- Metrics capture across three planes (client, SQL Server, self-calibration baseline) and a reporting rollup.
- A runbook.

**Out of scope**
- Perspective UI rendering / WebSocket session-capacity testing (browsers). Explicitly de-prioritized — the Gateway is trusted to render.
- AIM integration load (AIM is the one unbuilt external).
- Any change to production procs/NQs/views. This is a *test* harness; it observes, it does not modify the system under test.

## 3. Environment

| Component | Target | Availability |
|---|---|---|
| Ignition Gateway | Prod Stratus (fault-tolerant, high-spec) | **Available now** |
| SQL Server | Customer's dedicated box | **Not yet in hand** |
| Dev SQL | `MPP_MES_Dev` on workstation | Available now |

**Implication:** the backend *absolute* acceptance numbers can only be produced on the dedicated SQL box once it lands. Therefore the harness is **portable + self-calibrating**: every result is stamped with a captured hardware baseline of the box it ran on, so dev-box numbers (relative, contention-focused) and dedicated-box numbers (absolute, acceptance) are directly comparable. Build and rehearse everything now on dev; re-run Stage B/C on the dedicated box when available.

## 4. Plant Scale (derived from `sql/seeds/011_seed_locations_mpp_plant.sql`, 95% accurate)

- **Die cast:** 22 machines (DC1–DC4), 4 area terminals.
- **Trim:** 2 terminals.
- **MA1:** 6 lines → 16 role-terminals. **MA2:** 12 lines → 40 role-terminals.
- **~62 real operator terminals.** Test envelope: **100 concurrent terminals** (comfortable margin + future/tablets).
- **~22 assembly-out completion points** (AOUT / AFIN / ASER roles) — each completing a tray-LOT every 2–4 min at peak.

## 5. Workload Model (peak hour)

The harness replays a plant-wide peak hour assembled from per-operation cadences. **Rates are starting estimates — tunable in config.**

| Operation | Driver | Est. peak rate | Cost profile |
|---|---|---|---|
| Die-cast LOT create | 22 machines, ~1 / 3 min | ~7 / min | sequence burn + closure self-row |
| Die-cast checkpoint (`ProductionEvent`) | per machine | ~15–22 / min | append event + materialized qty |
| Trim-out | 2 shops | ~2–4 / min | checkpoint + whole-LOT move |
| Machining in/out | MA1 + MA2 lines | ~15–25 / min | pick/consume, extract-one split |
| **Assembly tray-complete** | ~22 AOUT points, 1 / 2–4 min | **~6–11 / min** | **heaviest: mint FG LOT + FIFO-consume BOM + closure edges + container mgmt** |
| **Reads** (screen polls + scans) | 100 terminals | **~30–35 / sec (~2000 / min)** | **aging-sensitive: WIP queue / LOT search / KPI against full tables** |

**Two structural risks this model exposes:**
1. **Writes are concurrency-bound, not volume-bound** — only a few hundred/min, but they collide on the sequence generator (B6) and the genealogy closure table (B4). → Surface-1 focus.
2. **Reads are the sharpest aging risk** — ~2000/min of WIP-queue / LOT-search / KPI queries scanning tables that, aged, hold tens of millions of rows. This is the "querying against full tables" concern, and where query plans silently degrade. → aged-DB + Query Store focus.

**Rate multipliers & ramp-to-failure.** Every operation scales by a global multiplier. The harness does **not** stop at a fixed pass/fail — it runs a **ramp**: 1× → 2× → 5× → 10× → keep climbing until a monitored metric crosses threshold, and reports the **knee** (the multiplier at which degradation begins). Finding the breaking point and the headroom margin is the primary output, not a single pass at an arbitrary multiple.

## 6. Test Architecture — Staged 3×2 Matrix

Two harnesses (surfaces), each run across three stages:

| | **Surface 1 — DB engine**<br>(direct concurrent connections → procs) | **Surface 2 — Ignition data path**<br>(gateway script → real NQs / pool) |
|---|---|---|
| **Stage A — fresh DB** | Shake out lock contention cheaply (dev SQL) | Shake out pool / NQ wiring (dev SQL) |
| **Stage B — aged DB** | **Acceptance test** — engine under production-scale tables | **Acceptance test** — real data path at scale |
| **Stage C — combined** | Both surfaces driving the same aged DB simultaneously — the true production picture |

Stage A: now, on dev SQL — relative numbers + contention bugs. Stage B/C: dry-run now on dev, **re-run on the dedicated SQL box** for acceptance numbers.

### Surface 1 — DB engine harness

A purpose-built concurrency driver (language decided in planning — candidates: Python + pyodbc, a small .NET async harness; `ostress` as a raw-concurrency fallback) that:
- Reads the **workload profile** (Section 5) as config: ops, weights, multiplier, ramp schedule.
- Maintains a configurable pool of worker connections mapped to "terminals," each firing operations at the weighted cadence with think-time.
- **Sources parameters from a live-working-set catalog** pulled from the aged DB at startup — reads hit real LOT ids, assembly consumes real FIFO source lots, machining picks real WIP, etc. Feeding procs invalid ids would test error paths, not production.
- Captures per-op latency (p50/p95/p99/max), achieved-vs-target throughput, error rate.
- Ramp controller steps the multiplier until a threshold breaches → reports the knee.

### Surface 2 — Ignition data-path harness

A **gateway script** (triggered from a hidden "load test" tag/page kept out of the operator projects) that simulates ~100 terminals by invoking the **real Named Queries + entity scripts** at the same profile cadence, through the real JDBC connection pool on the Stratus.
- Dispatches via `system.util.invokeAsynchronous` (or the gateway thread pools) so it exercises **real pool concurrency**, not a single serial thread — otherwise the driver, not the system, is the bottleneck.
- Records NQ timing + connection-pool stats (active / idle / waiting connections, lease-wait time, exhaustion events).
- Runs against the aged **test** DB, never prod.

## 7. Data-Aging Generator (Approach C — Hybrid)

The aged DB does two different jobs; the split is the core design insight:
1. **Bloat the tables** so index depth, page counts, and query plans match production (tens of millions of genealogy / event / closure rows across populated monthly partitions).
2. **Provide a realistic live working set** — the open WIP, in-process LOTs, and FIFO queues that the concurrent load will actually read, join, lock, and mutate.

**Approach C splits the build accordingly:**

- **Cold history** (closed / shipped LOTs from the prior ~11 months — never mutated, exist only to bloat) → **bulk synthetic, set-based inserts**, partition-aligned on the `(Id, ts)` composite keys (per `project_mpp_partition_aligned_pk`). Fast path to 12-month scale.
- **Live working set** (the recent window: open WIP, in-process LOTs, active FIFO queues) → built by **running the real procs**. The rows the load test actually touches are genuinely proc-built and structurally correct (closure, materialized qty, audit, partitions all real).

**Target age: 12 months.** (Honda genealogy is a 20-year retention class, but query-plan realism saturates after ~1–2 years; the B2 partitioning keeps only recent partitions hot regardless of total depth.)

**Fidelity risk & mitigation.** The bulk-synthetic cold path must faithfully replicate every invariant the procs maintain — transitive closure rows, materialized quantities, partition-key alignment, filtered-unique constraints. Mitigation: (a) restrict bulk-synthetic to *closed* history the load never mutates or joins into live paths deeply; (b) validate the seam with a set of invariant-check queries (closure transitivity, materialized-qty reconciliation, orphan-FK scan) before the DB is blessed; (c) the live working set — the only data the concurrency deeply exercises — is 100% proc-built.

## 8. Run Hygiene

**Reset via backup / restore.** The harness writes real rows (mints LOTs, consumes FIFO, ships), so each measured run mutates and further ages the DB and drains the working set. Therefore: build the 12-month aged DB **once**, `BACKUP` it, and `RESTORE` before each measured run. Reproducible starting state, zero cleanup logic. This is the single most important hygiene decision — it makes every run comparable.

## 9. Metrics

Three planes captured around every run:

- **Client-side:** latency percentiles (p50/p95/p99/max) per operation, achieved-vs-target throughput, error rate.
- **SQL Server:** `sys.dm_os_wait_stats` diffs (watch `LCK_*`, `PAGELATCH_*`, `WRITELOG`), **Query Store enabled** (auto-captures aging-induced plan regressions — directly targets the full-table-query concern), tempdb usage, CPU, memory grants. Connection-pool stats for Surface 2.
- **Self-calibration baseline:** CPU model / core count / RAM + a quick storage-latency probe, stamped on every result set so dev-box and dedicated-box numbers are comparable.

## 10. Acceptance Criteria

**TBD — to be set by Jacques against the FDS.** Placeholder shape:
- p95 read latency < **X** ms and p95 write latency < **Y** ms at 1× and 2× on the dedicated box.
- No connection-pool exhaustion at ≤ 2×.
- Ramp knee ≥ **N×** expected peak (headroom margin).
- No Query Store plan regression flagged on the aged DB versus fresh for the top-N hottest reads.

## 11. Deliverables

New `loadtest/` tree:
- Workload-profile config (Section 5 rates as data).
- Aged-DB builder — cold-bulk synthetic + live-proc replay (Section 7), producing a restorable 12-month DB.
- Surface-1 harness (DB engine).
- Surface-2 gateway script (Ignition data path).
- Metrics capture (DMV snapshots + Query Store export + pool stats) and a report rollup.
- Runbook.

## 12. Open Decisions

| # | Decision | Owner | Default if unresolved |
|---|---|---|---|
| D1 | Surface-1 harness language (Python/pyodbc vs .NET async vs ostress) | planning | Python + pyodbc (portable, matches tooling comfort) |
| D2 | Acceptance thresholds (§10) | Jacques / FDS | Leave TBD; capture raw numbers first, set thresholds from observed baseline |
| D3 | Exact cold-history volume per table for 12 months (row-count targets) | planning | Derive from Section 5 rates × 12 months × operating calendar |
| D4 | Where the aged-DB backup lives + restore automation | planning | Local `.bak`; scripted `RESTORE` in the runbook |

## 13. Revision History

| Version | Date | Author | Change |
|---|---|---|---|
| 0.1 | 2026-07-04 | Jacques + Claude | Initial draft from brainstorming session |
