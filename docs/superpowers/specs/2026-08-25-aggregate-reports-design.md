# Aggregate Reports — Rejects, Hold Status, Shipping History — Design

**Date:** 2026-08-25
**Trigger:** Companion to `2026-08-24-lot-search-and-trace-detail-panels-design.md`. That spec split the six unbuilt FDS §12 requirements by shape and delivered the three **search surfaces**; this one covers the three **aggregate reports**, built as Reporting-Module PDFs on the existing `/shop-floor/reports` registry.
**Status:** Draft for review. Decisions inherited from the search spec are restated in §2 so this document stands alone. Three new findings in §3, one of which removes a section of one report.
**Scope:** FDS-12-006 (Rejects), FDS-12-010 (Hold Status), FDS-12-011 (Shipping History).

---

## 1. Delivery shape

These three are **aggregate reports**, not interactive screens: periodic, printed or exported, read top-to-bottom. They join the six reports already on `/shop-floor/reports`, which is driven by the `BlueRidge.Reports.registry()` list — each entry names a `data.bin` report resource, its parameters, and an `available` flag that gates unbuilt ones.

Adding a report is therefore: a read proc, a `data.bin` authored via the global **`ignition-reporting`** skill (cloned from the validated `sample for claude` donor), and a registry entry.

**Five reports, not three** — FDS-12-006 is one requirement but the legacy PD delivers rejects at three distinct altitudes, and MPP uses all three. Per Jacques 2026-08-25, all three are in scope.

| Report | Legacy source | Audience |
|---|---|---|
| Rejects — Transaction Detail | `Search Reject.pdf` | Floor supervisor drilling a specific part/date |
| Rejects — Plant Summary | `Reject Summary Report.pdf` | Quality manager, period scrap % |
| Rejects — Part Matrix | `Reject Report.pdf` (15 pp) | Plant manager, per-part cross-tab |
| Hold Status | *(none — Intelex today)* | Quality management workflow |
| Shipping History | *(none)* | Honda ASN reconciliation |

---

## 2. Decisions inherited from the search spec

**`ChargeToParty` code table.** The legacy Departmental Scrap block groups by responsible party. Migration `0048` dropped `DefectCode.AreaLocationId` for `OperationCategoryId` (DieCast / Trim / MachiningAssembly, NULL = plant-wide), which collapses the legacy's *Non-Specific Supplier* and *Non-Specific MPP* rows into one bucket. Resolution: a `Quality.ChargeToParty` code table FK'd from `Quality.DefectCode`, seeded `DieCast`, `TrimShop`, `MachineShop`, `DieMaintenance`, `MppNonSpecific`, `SupplierNonSpecific`, backfilled from the `DeptDesc` column still present in `reference/seed_data/defect_codes.csv`. This keeps responsibility orthogonal to process — `OperationCategory` drives reject-screen filtering, a different job.

**Departmental scrap derives from `DefectCodeId`.** In every row of `Search Reject.pdf` the ChargeTo equals the defect code's home department, with no override observed. `Workorder.RejectEvent.ChargeToArea` (free-text `NVARCHAR(100)`) is therefore **not read by any report here** — the reports join through `DefectCode.ChargeToPartyId`. The legacy column is left in place, unused, rather than dropped in this spec.

**Persist scrap location on `RejectEvent`.** `Workorder.RejectEvent` has no location column while `ProductionEvent` and `ConsumptionEvent` both carry `TerminalLocationId`. `Workorder.RejectEvent_Record` **already accepts `@TerminalLocationId`**, commented `-- audit-only; no column on RejectEvent` — the caller passes it and it reaches only the audit log. Add the column, write it in the INSERT, backfill once from the last `LotMovement` before `RecordedAt`. Read-time derivation was rejected: `Lot.CurrentLocationId` drifts (a casting scrapped at Die Cast then moved onward reports as Machining — the failure FDS-02-002a exists to prevent).

**Shipping History ranges on `Container.CompletedAt`.** Decided by Jacques 2026-08-25, and the rationale settles it rather than compromising: **there is no integration with MPP's actual shipping information, and no future phase that adds one.** Container closure is therefore not a degraded proxy for ship time — it is the ceiling of what this system can ever know. The report ranges on `CompletedAt` and **labels that column "Completed"**, consistent with the trace detail panels. The FDS-12-011 title stays "Shipping History"; the date semantics are stated on the report itself so no reader infers truck-departure time.

---

## 3. New findings

### 3.1 "Non-Reject Scrap" is a named set of defect codes, not a flag

`Reject Summary Report.pdf` carries a **Non-Reject Scrap** block — Trial Parts, Test Parts, Assembled-on-to-NG-part — counted but excluded from every reject percentage. Those map to specific seeded codes:

| Legacy bucket | Defect codes |
|---|---|
| Test Parts | `107` Test Part (Die Cast), `170` Machine Trial (Machine Shop) |
| Trial Parts | `229` Trial Part (Die Cast) |
| Assembled on to NG part | `230` Assembled on to NG part DC, `199` Assembled on to NG part MS |

**`IsExcused` is a different axis and must not be reused.** It flags 8 codes (Bent Pin, Computer Reject, Double Shot, Bad Repair, Drags, Flatness, No Cup, No Clip Ring) for the OEE quality calculation — an unrelated concern that happens to also mean "don't count this against us."

**Decision: add `Quality.DefectCode.IsNonRejectScrap BIT NOT NULL DEFAULT 0`**, seeded `1` for those five codes. A boolean classification alongside `IsExcused` follows the existing precedent, and keeps the report from hard-coding a literal code list the way the legacy did.

### 3.2 There is no customer dimension — the customer-scrap block cannot be built

`Reject Summary Report.pdf` ends with **Customer Scrap Percentage (Die Cast Only)**, broken out by American Honda, Honda, Honda Alabama, Honda Anna Eng Plnt and Metts.

No such data exists. `Parts.Item` has no customer column. The only `CustomerCode` in the schema is on `Parts.ContainerConfig`, and in Dev it is **NULL on 37 of 39 configs and empty string on the other 2** — it has never been populated. (Migration `0057` is unrelated: it dropped `Item.AimCustomerPartNumber`, an AIM-posting field, after proving that value is derivable from `PartNumber`.)

**Decision (Jacques, 2026-08-25): build the Plant Summary without the customer block, and print an explicit note where that block would sit.** The departmental scrap and non-reject scrap blocks — the other two thirds of that report — are fully buildable. No customer dimension is invented, and nothing is silently missing: the note names what is needed, which makes the printed report itself the prompt to MPP for the data.

Closing the block later needs a customer dimension on `Parts.Item` plus the per-part customer mapping from MPP. That is a **seed-data item**, not a design decision, and belongs in the Seeding Registry.

Note text to render in place of the block:

> **Customer scrap percentage — not available.** This section requires a per-part customer assignment, which the MES does not yet hold. Supply the part-to-customer mapping to enable it.

This is the one place where a legacy report section is knowingly not reproduced.

### 3.3 `Quality.Hold_ListOpen` is load-bearing and lacks duration

`Hold_ListOpen(@FilterText, @FilterTypeCodeId)` returns HoldEventId, LotId, LotName, ContainerId, ContainerItemPartNumber, HoldTypeCodeId, HoldTypeCode, Reason, PlacedByInitials, PlacedAt — most of FDS-12-010, but **not the "duration on hold"** the requirement names.

It backs the Hold Management screen. Widening it repeats exactly the `Lot_Search` mistake this project just paid for, so it is **frozen**: Hold Status gets a sibling read, `Quality.Hold_ListOpenForReport`, which adds the duration and the LOT context a printed report needs.

---

## 4. Schema work — one migration

`sql/migrations/versioned/0067_reject_chargeto_and_reject_location.sql`:

1. **`Quality.ChargeToParty`** — read-only code table (`Id`, `Code`, `Name`, `SortOrder`), seeded with the six parties in §2.
2. **`Quality.DefectCode.ChargeToPartyId BIGINT NULL FK`** + index, backfilled from the CSV's `DeptDesc`: Die Cast → `DieCast`, Trim Shop → `TrimShop`, Machine Shop → `MachineShop`, HSP → `SupplierNonSpecific`, Prod. Control + Quality Control → `MppNonSpecific`. Nullable — an unclassified code reports under an explicit "Unassigned" row rather than being silently dropped.
3. **`Quality.DefectCode.IsNonRejectScrap BIT NOT NULL DEFAULT 0`**, seeded `1` for codes `107`, `170`, `229`, `230`, `199`.
4. **`Workorder.RejectEvent.TerminalLocationId BIGINT NULL FK → Location.Location(Id)`** + index, backfilled from the last `LotMovement` at or before `RecordedAt`.

`Workorder.RejectEvent_Record` gains `TerminalLocationId` in its INSERT — the parameter already exists, so no signature change and no caller changes.

All four are additive. `Lots.Lot_Search`, `Quality.Hold_ListOpen` and `Quality.Hold_GetOpenByContainer` are untouched.

---

## 5. Read procs

| Proc | Serves | Notes |
|---|---|---|
| `Quality.Reject_SearchDetail` | Rejects — Transaction Detail | Params: part-number LIKE, defect, charge-to party, date range (Eastern days), area. Row per `RejectEvent`: id, part, prod date, operator, shift, defect, charge-to, qty. |
| `Quality.Reject_GetPlantSummary` | Rejects — Plant Summary | One row per `ChargeToParty` plus totals: good pcs, reject pcs, total, reject %. Second call for the non-reject-scrap block. |
| `Quality.Reject_GetNonRejectScrap` | Rejects — Plant Summary | Sibling — quantities for `IsNonRejectScrap = 1` codes, grouped by code. One proc, one result set. |
| `Quality.Reject_GetPartMatrix` | Rejects — Part Matrix | Per part: production and reject counts per `ChargeToParty`, plus a per-defect breakdown. Emitted **long, not pivoted** — see §6. |
| `Quality.Hold_ListOpenForReport` | Hold Status | Sibling to the frozen `Hold_ListOpen`; adds `HoursOnHold` and LOT piece count / location. |
| `Lots.Container_ListShipped` | Shipping History | Containers with `ContainerStatusCodeId = 3`, ranged on `CompletedAt` (Eastern days), with part, piece count, AIM shipper id and source-LOT count. |

Every one: one result set, no OUTPUT params, Eastern-converted timestamps at the boundary, Eastern-day `DATE` parameters converted to a half-open UTC range inside the proc (the pattern established by `Lots.Lot_SearchAdvanced`).

---

## 6. The Part Matrix is emitted long, pivoted in the layout

`Reject Report.pdf` is a cross-tab: parts as **columns**, eight per page, fifteen pages. SQL cannot return a variable column set without dynamic SQL, and the Reporting Module cannot consume one cleanly either.

**The proc returns long rows** — one row per `(part, charge-to party)` and one per `(part, defect code)` — and the **ReportMill layout pivots** them, one part-group per block, parts flowing down the page rather than across it.

This is a deliberate departure from the legacy shape. Reading fifteen landscape pages of eight-column cross-tab is an artifact of the tool that produced it, not a requirement; a per-part block carries the same numbers and prints legibly.

**Confirmed by Jacques 2026-08-25** — long rows with per-part blocks, with the caveat that the data may need massaging or subqueries to nest correctly. Jacques is supplying **two worked examples of table nesting in Reporting-Module reports from another project**; the Part Matrix layout waits on those.

**Sequencing consequence:** the Part Matrix is the only report whose layout depends on the nesting examples. The migration, all read procs, and the other four reports proceed now. There is an in-project precedent to draw on meanwhile — the existing **Downtime by Shift** report already renders machine-grouped nested detail.

---

## 7. Registry entries

Five new `BlueRidge.Reports.registry()` entries, each `available: True` once its `data.bin` renders:

| key | title | params |
|---|---|---|
| `rejects_detail` | Rejects — Transaction Detail | date range, part (optional), defect (optional), charge-to (optional) |
| `rejects_summary` | Rejects — Plant Summary | date range |
| `rejects_matrix` | Rejects — Part Matrix | date range |
| `hold_status` | Hold Status | *(none — current holds)* |
| `shipping_history` | Shipping History | date range |

The landing page already renders `dateRange` parameter inputs; `part`, `defect` and `chargeTo` need picker option sources, added beside the existing ones.

---

## 8. Testing

Per-proc test files under `sql/tests/0069_Aggregate_Reports/`, each building its own fixture — `Run-Tests.ps1` resets to a schema-only database, so `Lots.Lot`, `Lots.Container`, `Tools.Tool` and `Oee.Shift` are empty and only code tables are seeded.

Specific cases worth pinning:

- **Migration**: every seeded defect code resolves a `ChargeToParty`; the five non-reject-scrap codes carry `IsNonRejectScrap = 1` and no others do; `RejectEvent.TerminalLocationId` backfill populates rows that have a prior movement and leaves the rest NULL.
- **Freeze**: `Quality.Hold_ListOpen` still has exactly 2 parameters, mirroring the `Lot_Search` parity assertion.
- **Reject %**: a fixture with known good and reject counts asserts the percentage, and asserts that a non-reject-scrap code contributes to its own block but **not** to the reject percentage — the single most consequential arithmetic in the report set.
- **Eastern-day boundary** on all three date-ranged procs, same 01:00-UTC case as `Lot_SearchAdvanced`.

Report rendering is verified against the live gateway per the `ignition-reporting` workflow: a report resolves by its internal `setTitle` (folder name must match), every layout literal is `L.esc`'d and the layout XML validated before deploy, and the Report Viewer is never handed an empty params dict.

---

## 9. Out of scope

- **Customer scrap percentage** (§3.2) — no customer dimension exists. Needs `Parts.Item` customer plus MPP's per-part mapping; a Seeding Registry item.
- **Actual ship timestamps** (§2) — no shipping integration exists or is planned. `CompletedAt` is the ceiling of what the system can know, and is labelled as such.
- **Columns-across cross-tab** for the Part Matrix (§6) — pending Jacques's call.
- **NCM / non-conformance data** (FRS 3.13.4) — FUTURE per the scope matrix.
- **Downtime pareto** (FRS 3.15.5) and **CSV export from the downtime screen** (FRS 3.15.6) — real gaps in the *existing* downtime reports, not in these three. Recorded here because they surfaced during the same review; they belong to whoever next touches downtime.
