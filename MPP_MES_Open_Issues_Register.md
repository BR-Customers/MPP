# MPP MES — Open Issues Register

**Document:** FDS-MPP-MES-OIR-001
**Version:** 2.18 — Working Draft
**Date:** 2026-05-01
**Prepared By:** Blue Ridge Automation
**Prepared For:** Madison Precision Products, Inc. (Madison, IN)

This register consolidates all open items and design decisions that gate Perspective screen design and implementation. Part A holds the FDS-numbered open items (OI-01 through OI-35). Part B holds the 19 User Journey assumptions/decisions (UJ-01 through UJ-19). Cross-references between the two parts are noted per-item.

---

## Revision History

| Version | Date | Author | Change Summary |
|---|---|---|---|
| 2.18 | 2026-06-09 | Blue Ridge Automation | **OI-35 RESOLVED — Phase 0 architecture gate cleared (Arc-2 Phase-1 SQL unblocked).** Track B (OI-35 B1–B8) signed off 2026-06-08 (`Meeting_Notes/2026-06-08_Phase0_Decision_Log.md`); decisions baked into migration `0020` (design spec `docs/superpowers/specs/2026-06-09-arc2-phase1-sql-foundation-design.md`): B2 monthly partitioning + `TRUNCATE` sliding-window (singleton `Id` PK preserved), B3 columnstore deferred, B4 `LotGenealogyClosure`, B5 materialized qty + fallback view, B6 row-locked `IdentifierSequence_Next` (seed ≈3M, MESL/MESI), B7 `OperationLog`→`LotEventLog` split, B8 filtered indexes, B1 retention → FDS §11. Track A = build-on-assumed-defaults (A4 ShotCount cumulative locked; A1/A2/A5/A6/A7 MPP-confirm in parallel; A8 close-as-not-reproduced; A9 hard-fail). **UJ-03 ⚠️ changed** (Phase 0 T008): no auto even-split default — operator enters all split quantities; FDS §5/§6 even-split-default prose to be removed at next FDS pass. **UJ-05** build default locked to update-in-place + `ContainerSerialHistory` (B10), stays Open pending Quality/Honda affirmation. **Count shifts:** Part A Resolved 30 → 31, Open 4 → 3 (OI-32/-34 + OI-33 remain; OI-35 → Resolved). Grand total: 48 resolved, 0 in review, 5 open, 1 superseded. Companion edits applied same pass: Data Model § "Scaling Decisions" (rev 1.9s), FDS-11-009 retention table, Plant Floor plan B10. |
| 2.17 | 2026-05-01 | Blue Ridge Automation | **Nine items closed from Jacques's 2026-05-01 markup of the Outstanding Items extract.** OI-07 (Production-only WO seed confirmed → ✅ Resolved). OI-24 (legacy Automation tile not reproduced; covered by `Audit.InterfaceLog` + OPC tag management → ✅ Resolved). OI-25 (Notifications module out-of-MVP; banner notifications already covered via terminal context per FDS-07-006a/b; text/email notifications a future change order or follow-on project → ✅ Resolved). OI-27 (Supply-part flag covered by existing component-part modeling — `Parts.Item` + `Parts.Bom` + `Parts.ItemType` Cast/Machined/Assembled/Received → ✅ Resolved). OI-28 (Cast-override flag covered by `LocationAttribute` system; no new BIT column on Cell → ✅ Resolved). OI-29 (Workstation Category covered by ISA-95 hierarchy; no `WorkstationCategory` LocationAttribute → ✅ Resolved). OI-30 (Legacy Reports-tile contents not mirrored 1:1; the four named PD reports stay MVP via UJ-19; additional Ignition reports beyond those four = post-deployment change order → ✅ Resolved). OI-31 (Proposed direction confirmed + new business rule: cutover seed at **+10,000 above current Flexware `LastCounterValue`** — or MPP-agreed delta — to avoid LTT collisions during partial-cutover windows. Format `MESL{0:D7}` / `MESI{0:D7}` retained, no reset policy, rollover deferred ~30 yrs → ✅ Resolved). UJ-03 (Per-Operation `Parts.OperationTemplate.RequiresSubLotSplit BIT` flag confirmed; mockup verified at Trim OUT with `+ Add sub-LOT` button toggling 1 vs N destination rows; Configuration Tool surfaces this as "may split for machining" toggle on the per-Operation row of the Item edit screen → ✅ Resolved). UJ-19 confirmed in MVP scope: the four named PD reports are deliverables for this project; the post-deployment change-order comment in OI-30 was about reports BEYOND the four. **Count shifts:** Part A Resolved 22 → 30, In Review 1 → 0, Open 11 → 4 (only OI-32, OI-33, OI-34, OI-35 remain); Part B Resolved 16 → 17, In Review 1 → 0, Open 2 → 2 (UJ-05, UJ-19). Grand total: 54 items, 47 resolved, 0 in review, 6 open, 1 superseded. **Companion FDS amendments queued separately:** §16 cutover-offset rule (FDS-16-003) + §12 banners-only / text-out one-liner; FDS embedded Open Items Register trimmed to the 6 remaining items. No data model / SQL changes this revision — register entries + FDS prose only. |
| 2.16 | 2026-04-29 | Blue Ridge Automation | **OI-35 NEW / ⬜ Open / HIGH — Long-horizon scaling, retention, and archiving strategy.** Captures the 20-year-retention architectural decisions surfaced during the 2026-04-28 indexing & query-perf review. **Tagged "must decide before Arc 2 Phase 1 SQL build"** — partition functions, materialization columns, and closure-table presence all need to be in the CREATE migration; retrofitting them on a populated 100M+ row table is operationally painful. The decision space: per-table retention class (push-back candidates: `Audit.OperationLog` / `InterfaceLog` / `FailureLog` at 7-year vs 20-year), monthly range partitioning + sliding-window automation for ~14 high-volume event tables, clustered columnstore on partitions older than 90 days, materialized closure table for `Lots.LotGenealogy` (so Honda audits don't recursive-CTE-walk 100M+ rows at year 15), materialize `TotalInProcess` / `InventoryAvailable` columns onto `Lots.Lot` (replaces the read-time `v_LotDerivedQuantities` view at scale), switch `Lots.IdentifierSequence_Next` to SQL Server `SEQUENCE` object (eliminates row-level lock contention at LOT creation), split `Audit.OperationLog` into a 7-year retention general audit + a separate 20-year `Lots.LotEventLog` for traceability events. Owner: Blue Ridge architecture + MPP IT (retention policy negotiation). Last-responsible-moment posture confirmed by Jacques 2026-04-29 — the decision is deferred but the gate is hard. Couples to: indexing review meeting note (`Meeting_Notes/2026-04-28_DataModel_Indexing_Scaling_Review.md`), the data model spec § for Arc 2 deferred tables, and the existing "indexing pass" follow-up. Count shifts: Part A Open 10 → 11 (added OI-35 HIGH). Active Part A item count 34 → 35. No FDS / data model / SQL changes this revision — register entry only. |
| 2.15 | 2026-04-28 | Blue Ridge Automation | **Canonical sync of OI-33 + OI-34 from the embedded FDS Open Items Register.** Both items were added to the FDS body's Open Items Register during the 2026-04-28 v0.11m continuity + clarity pass but had not yet been folded into this canonical OIR. **OI-33 ⬜ Open / HIGH** — AIM Shipper ID pool empty-pool **hard-fail** behavior (FDS-07-010a). When the local pool is exhausted, `Container_Complete` rolls back and production stops on affected lines until the pool refills (no soft-fallback, no placeholder-then-reconcile). Customer validation needed: confirm hard-fail is the desired operational posture given trucks cannot ship without valid Honda-issued AIM IDs. Owner: MPP Operations / IT. Couples to UJ-04 (already Resolved — pool design locked v2.12). **OI-34 ⬜ Open / MEDIUM** — MPP-authored production schedules — how should the MES leverage them beyond shift-window timing (FDS-09-008 / FDS-09-012)? Current design imports them for shift-instance creation and event-derived availability math. Whether MPP wants additional uses (target quotas per shift, line scheduling drift detection, throughput planning, etc.) is unanswered. Owner: MPP Production Control. Couples to UJ-19 (PD report enumeration) and OI-30 (Reports tile contents). Count shifts: Part A Resolved 22 → 22, In Review 1 → 1, Open 8 → 10 (added OI-33 + OI-34), Superseded 1 → 1. Active Part A item count 32 → 34. No FDS / data model / SQL changes — OIR sync only. |
| 2.1 | 2026-04-06 | Blue Ridge Automation | Initial register consolidating FDS open items and User Journey assumptions |
| 2.2 | 2026-04-08 | Blue Ridge Automation | FRS reference crosswalk added per-item; priorities normalized |
| 2.3 | 2026-04-09 | Blue Ridge Automation | First round of MPP review decisions applied — OI-01, UJ-06, UJ-15 closed; 10 items moved to In Review |
| 2.4 | 2026-04-21 | Blue Ridge Automation | **Phase A of the 2026-04-20 OI review refactor.** Closed OI-03 (shift runtime derived from events) and OI-06 (initials-based operator identity — see Phase C / FDS v0.8). Revised OI-04 (line-stop, not LOT-hold; 10-fail escalation; CRT 200% inspect), OI-05 (die-rank compatibility merge rules), OI-07 (three WO types, Maintenance targets Tools), OI-08 addenda (terminal locked to machine context; part↔machine validity map; mobile consideration), OI-09 addenda (sublot pattern with parent FK), OI-10 (superseded by Phase B Tool Management design). Added four new items: OI-11 (part rename at Casting → Trim), OI-12 (lineside inventory caps), OI-13 (BOM source = Flexware app @ IP .919), OI-14 (admin remove-item). Structural change: each OI and UJ now has its own subsection instead of living inside a giant grid table — easier to read, diff, and update. Source meeting notes at `Meeting_Notes/2026-04-20_OI_Review.md`. Running plan in `memory/project_mpp_oi_refactor.md`. |
| 2.5 | 2026-04-22 | Blue Ridge Automation | **Legacy MES screenshot review gap analysis.** 36 screenshots of the Flexware Madison MES reviewed against the current FDS / Data Model. 16 new Part A items added (OI-15 through OI-30): 9 concrete design additions (Track screen, auto-finish-on-target WO, tray-divisibility rule, ItemLocation consumption metadata, Country of Origin, scrap source enum, partial start/complete, Hold Management screen, Lot computed fields) and 7 discovery items to confirm with MPP (Automation tile scope, Notifications, per-workstation scripting, Supply Part flag, cast-override cell flag, Workstation Category grouping, Reports tile contents). Source summary at `Meeting_Notes/2026-04-20_OI_Review_Status_Summary.md` §"Additional discovered gaps". Legacy screenshots at `reference/MPP_Current_MES_screenshots.docx`. |
| 2.6 | 2026-04-22 | Blue Ridge Automation | **OI-11 resolved — Casting → Trim rename modelled via 1-line BOM, not `Parts.ItemTransform`.** Review of the v2.5 design surfaced that the proposed `Parts.ItemTransform` table duplicated every column of `Workorder.ConsumptionEvent`. The rename is a degenerate 1-line BOM consumption: trim part has cast part as its sole component at QtyPer=1; existing ConsumptionEvent + LotGenealogy machinery handles the flow and the Honda backward trace. OI-11 moves ⬜ Open → ✅ Resolved. Downstream corrections: Data Model v1.8-rev (ItemTransform table section replaced with a ✅ Resolved callout; `Audit.LogEntityType` seed shrinks from 10 to 9 rows; table count "~73" → "~72"), FDS v0.10-rev (§5.10 retained, rewritten around FDS-05-033 BOM-driven scan-in; FDS-05-034/-035 retired), User Journeys v0.7-rev (Trim Shop narrative simplified to normal consumption), Phase G migration `0010_phase9_tools_and_workorder.sql` (ItemTransform LogEntityType row dropped; ScrapSource shifted from Id=40 to Id=39; re-run green, 779/779 tests still pass). |
| 2.14 | 2026-04-27 | Blue Ridge Automation | **Part B — 10 UJ closures from Jacques's review batch.** UJ-07 (Option A), UJ-08, UJ-09 (Option C — strict + supervisor override), UJ-10 (Option D — shift-end summary), UJ-11 (Option A — flagged risk), UJ-13 (Option A), UJ-14, UJ-16, UJ-17 (Option A), UJ-18 (Gateway-script-async — architectural). Downstream FDS edits land in v0.11j (FDS-04-007 elevated-action list extension for UJ-09; FDS-07-005 amended for print extraction; FDS-07-006a/b NEW print dispatch + retry; §1.6 / FDS-01-014 NEW cross-cutting integration pattern; FDS-09-015 NEW shift-end summary; FDS-10-013 NEW ConfirmationMethod LocationAttribute). Data Model v1.9i (ShippingLabel +5 print-state columns). Part B counts shift: Resolved 6 → 16, In Review 2 → 1, Open 11 → 2 (UJ-03 stays In Review; UJ-05 + UJ-19 stay Open). |
| 2.13 | 2026-04-27 | Blue Ridge Automation | **Part B UJ enrichment pass — 13 of 19 UJ entries restructured to match OI-entry depth (Description → Options A/B/C with impact analysis → Recommended direction → What's needed to decide).** Per Jacques's 2026-04-24 flag that UJ entries lacked options/impact framing. Two In-Review entries (UJ-03 sublot trigger, UJ-14 warm-up shots) and 11 Open entries (UJ-05, UJ-07, UJ-08, UJ-09, UJ-10, UJ-11, UJ-13, UJ-16, UJ-17, UJ-18, UJ-19) now carry Blue Ridge's recommended direction with reasoning and the explicit input needed to lock each. Six already-Resolved entries (UJ-01, UJ-02, UJ-04, UJ-06, UJ-12, UJ-15) left as-is — their resolution narratives already carry the depth. No status changes; this is a structure / readability refinement to make the next MPP review more actionable. |
| 2.12 | 2026-04-27 | Blue Ridge Automation | **UJ-04 design locked — AIM Shipper ID local pool (zero-latency container closure).** Follow-up to v2.10's "queue async" Decision-with-addition. The Claude-proposed async-queue model (container completes in pending state, queue drains and back-fills `AimShipperId`) was rejected by Jacques on 2026-04-27 because it still introduces latency at close time. Replaced with a **pre-fetched local pool**: a background Gateway script keeps `Lots.AimShipperIdPool` topped up to a configurable target depth; `Container_Complete` claims one row FIFO synchronously inside its own transaction — sub-millisecond, never blocked on AIM. Empty pool = **hard fail** (close rejects, operator sees error, line stops; no soft fallback). Once consumed, IDs are permanently terminal — no return-to-pool on void / re-pack (Honda treats every issued ID as consumed regardless). Honda does not expire IDs. Two new tables (`Lots.AimShipperIdPool` + single-row `Lots.AimPoolConfig`) and four supporting procs (`_Claim` / `_Topup` / `_GetDepth` / `_GetByContainer` plus Config `_Get` / `_Update`). Configuration Tool exposes the four configurable thresholds (TargetBufferDepth=50, TopupThreshold=30, AlarmWarningDepth=20, AlarmCriticalDepth=10). Two-tier alarm: supervisor wallboard tile at Warning, supervisor alarm + IT notification at Critical. Downstream commits in this revision: Data Model v1.9h, FDS v0.11i (FDS-07-005 rewrite, FDS-07-008 amendment, FDS-07-010 rewrite, FDS-07-010a/b/c NEW), ERD Lots tab. SQL deferred to Arc 2 Phase 7 alongside the Container schema CREATE. No count changes (UJ-04 was already counted Resolved in v2.10 — this is a body refinement closing the design). |
| 2.11 | 2026-04-27 | Blue Ridge Automation | **OI-21 design locked — Pausable LOT at Workstation as `Lots.PauseEvent`, not a `WorkOrderStatus` extension.** Follow-up to the v2.10 Decision-with-addition that left four open questions for Claude + Jacques. Decision body rewritten with the locked design: pause is a `(Lot, Location)` event recorded in a new append-only `Lots.PauseEvent` table mirroring `Quality.HoldEvent`. Pause is orthogonal to `WorkOrderStatus`, `OperationStatus`, and `LotStatusCode` — no enum extension on any of those. The same LOT MAY be paused at multiple Cells simultaneously (Machining + Assembly partial-progress); filtered UNIQUE blocks duplicate **open** pauses for `(LotId, LocationId)` only. **No auto-prompt** when starting a different LOT at the same Cell (rationale: Assembly auto-loads from upstream Machining FIFO — an unconditional resume prompt would interrupt the normal flow). Every workstation screen surfaces a **Paused-LOT indicator** (count + tap-through to detail list) for explicit operator-driven resume. **No TTL** — paused LOTs persist across shifts and operators; resume MAY be performed by a different operator from the one who paused. PausedReason and ResumedRemarks both optional. WO/Operation/Lot status do not transition on pause; no DowntimeEvent is written. Downstream commits in this revision: Data Model v1.9g (new `Lots.PauseEvent` table contract), FDS v0.11h (FDS-05-038 NEW under §5.3), ERD Lots tab. SQL deferred to Arc 2 Phase 1 alongside the rest of the Lots schema CREATE — procs `Lots.LotPause_Place / _Resume / _GetByLocation / _GetCountsByLocation`. No count changes to the Resolved/InReview/Open totals (OI-21 was already counted Resolved in v2.10 — this is a body refinement that closes the four open design questions). |
| 2.10 | 2026-04-24 | Blue Ridge Automation | **Jacques OIR review annotations applied.** Jacques annotated v2.8 of this register and returned it; this revision folds every inline "Decision (4/24/2026):" note back into the register source with matching status changes. 17 items moved Resolved (OI-02, -04, -05, -08, -12, -13, -14, -15, -16, -17, -18, -19, -20, -21, -22, -23, -32b). 2 UJs closed (UJ-02, UJ-04). Several carry modifications that trigger downstream data-model / FDS / ERD updates: **OI-12** — `MaxParts` reclassified as a `Parts.Item` attribute (not `ContainerConfig`). **OI-17** — tray-divisibility reclassified as a Finished-Good Part attribute. **OI-18** — `Parts.ItemLocation` extended to support Area / WorkCenter / Cell hierarchy (not Cell-only) with compatibility validation cascading up the hierarchy at check-in. **OI-16** — adds expected PLC confirmation BIT and a new Terminal-scoped `LocationAttribute` toggling a "Confirm Completion" button style (large button on designated lines vs passive popup). **OI-21** — adds a **Pausable WorkOrder** concept (resume prompt on starting a new job while one is paused). **OI-23** — derivation implemented as a view (not materialized columns). **OI-32b** closed: `Parts.ItemType` suffices; no Material Classes table. **OI-32** remains open — Jacques challenged the framing; clarification response logged in Decision narrative. **OI-08** closes with new terminal-mode-by-assignment rule: Terminal assigned to a WorkCenter → Dedicated + no location scan; Terminal assigned to an Area → Shared + location selection is the first step of every interaction. Count shifts: Resolved 5 → 22, In Review 6 → 1 (OI-07 only, mid-revision), Open 20 → 8, Part B Resolved 4 → 6, Part B In Review 3 → 2, Part B Open 12 → 10 (UJ-02 and UJ-04 closed). **UJ insufficiency noted but not addressed this revision** — Jacques flagged that the UJ entries lack the options/impact depth of the OI entries; a separate enrichment pass is queued. **Downstream doc integration queued as a list (data model, FDS, ERD, Arc 2 Plan) but not executed in this commit** — each "Section needs Integrated into other Docs" note from Jacques becomes its own targeted commit. |
| 2.9 | 2026-04-24 | Blue Ridge Automation | **OI-07 rewritten — WorkOrderType corrected to `Production` only; `Recipe` deleted; `Demand` and `Maintenance` reclassified as FUTURE hooks.** Jacques clarified that the 2026-04-20 meeting note "recipe work orders to not be operator visible" was a mis-recording — the "Recipe" line was actually about the **Production** work orders already modelled (MVP-lite, auto-generated, invisible to operators). There is no separate Recipe concept. The existing WO our design supports is Production. Under MPP's framing, **Demand** (planned preventative maintenance) and **Maintenance** (emergency maintenance) are genuinely separate future WO types — but building them is out of scope for this project; the data model only needs to **not block** their future addition. OI-07 scope narrows accordingly: the `Workorder.WorkOrderType` code table remains in the schema as a future hook (new rows can be INSERTed for Demand/Maintenance when Ben scopes the maintenance engine), but the seed is corrected to a single `Production` row. `Recipe` is stripped from every doc, seed, proc comment, and test description. Downstream effects: FDS §6.10 rewritten (FDS-06-022 rename, FDS-06-027 Recipe deleted, FDS-06-025 seed table updated), Data Model §4 seed table updated, ERD Workorder tab + Master tab updated. **SQL follow-up queued** (not executed this turn): a correction migration is needed to rename the shipped `WorkOrderType` seed row `Demand`→`Production`, DELETE `Recipe`, and DELETE `Maintenance` (re-addable later), plus a test update in `sql/tests/0019_Parts_ConsumptionMetadata_And_ScrapSource/010_Phase_E_additives.sql` (current test asserts 3 seed rows + Code='Demand'). |
| 2.8 | 2026-04-24 | Blue Ridge Automation | **Legacy MES Storyboards review additions.** Review of `reference/NewInput/Madison MES - Storyboards.pdf` (2012 Flexware) + `5GO-AP4 IPAddresses.xlsx` against v1.9 / v0.11 / v0.8 / v2.7 design: 43/52 legacy capabilities covered (83%), 5 partial (10%), 4 gaps (7%), 0 out-of-scope. Two register updates: (1) **OI-32 NEW / ⬜ Open** — Material Allocation operator screen. Flexware has a dedicated pre-PLC allocation workflow (`MaterialAllocationMenuView` / `CreateView` / `UpdateView`) gated by `Workstation.MaterialAllocationRequired` BIT; we have the data (OI-18 ItemLocation metadata) but no operator screen. Phase 6 Assembly gates on resolving this. Couples to UJ-09. (2) **OI-32b NEW / ⬜ Open (discovery)** — Material Classes as a first-class entity. Flexware's `Material.MaterialClassID` FK may cover Honda-customer groupings our `Parts.ItemType` misses. Phase 0 confirmation of live usage needed. Full review report at `reference/NewInput/REVIEW_2026-04-24.md`. OI-31 "extend counters" inference from the review was **reverted** — Jacques confirmed the `IdentifierFormat` export he provided (Lot + SerializedItem, 2 rows) is the complete live counter list, not a sample. Design confirmations: DashboardConfiguration / UserInterfaceScript / clock# + PIN rejections validated — no functional loss. |
| 2.7 | 2026-04-24 | Blue Ridge Automation | **Arc 2 model revisions (2026-04-23 session) landed.** OI-09 ✅ Closed — Die Cast cavity-parallel LOTs codified into Data Model v1.9 via `Lot.ToolId` + `Lot.ToolCavityId` (N active cavities → N parallel independent LOTs, not sublots). Machining sub-LOT split remains a separate concept in FDS §5.4. **OI-26 DELETED** (not Resolved, not Superseded — removed entirely). Flexware's `UserInterfaceScript` DB-stored-runtime-code pattern is not reproduced: LocationAttribute on Terminal/Workstation tier + Perspective session-scoped scripts cover every legitimate use case; runtime code lives in Ignition project files, version-controlled. **OI-31 NEW / ⬜ Open** — `Lots.IdentifierSequence` table (Flexware `IdentifierFormat` equivalent, carries `MESL{0:D7}` Lot and `MESI{0:D7}` SerializedItem counters). Schema locked; seed values pending Flexware cutover snapshot. OI-05 confirmed — post-merge LOT has NULL Tool / Cavity (blended-origin can't denormalize). Source decisions: `docs/superpowers/specs/2026-04-23-arc2-model-revisions.md`. Downstream commits in the same refresh pass: Data Model v1.9, FDS v0.11, User Journeys v0.8, Arc 2 phased plan refresh. |

---

## Summary

**Part A counts (35 items — updated v2.18):**

| Priority | ✅ Resolved | 🔶 In Review | ⬜ Open | Superseded | **Total** |
|---|---|---|---|---|---|
| HIGH | 5 (OI-01, OI-02, OI-05, OI-07, OI-35) | 0 | 1 (OI-33) | 0 | **6** |
| MEDIUM | 16 (OI-03, OI-04, OI-06, OI-08, OI-09, OI-11, OI-12, OI-16, OI-17, OI-18, OI-21, OI-22, OI-24, OI-28, OI-30, OI-31) | 0 | 2 (OI-32, OI-34) | 0 | **18** |
| LOW | 10 (OI-13, OI-14, OI-15, OI-19, OI-20, OI-23, OI-25, OI-27, OI-29, OI-32b) | 0 | 0 | 0 | **10** |
| — | 0 | 0 | 0 | 1 (OI-10) | **1** |
| **Total** | **31** | **0** | **3** | **1** | **35** |

> **Authoritative row lists (after v2.18 sync):**
>
> - Resolved (31) = OI-01, -02, -03, -04, -05, -06, -07, -08, -09, -11, -12, -13, -14, -15, -16, -17, -18, -19, -20, -21, -22, -23, -24, -25, -27, -28, -29, -30, -31, -32b, -35
> - In Review (0) = —
> - Open (3) = OI-32, -33, -34
> - Superseded (1) = OI-10

**Part B counts (19 items) — updated v2.17:**

| Priority | ✅ Resolved | 🔶 In Review | ⬜ Open | **Total** |
|---|---|---|---|---|
| HIGH | 7 (UJ-01, UJ-04, UJ-07, UJ-08, UJ-11, UJ-13, UJ-18) | 0 | 1 (UJ-19) | **8** |
| MEDIUM | 9 (UJ-02, UJ-03, UJ-09, UJ-10, UJ-12, UJ-14, UJ-15, UJ-16, UJ-17) | 0 | 1 (UJ-05) | **10** |
| LOW | 1 (UJ-06) | 0 | 0 | **1** |
| **Total** | **17** | **0** | **2** | **19** |

**Grand total:** 54 items (35 Part A + 19 Part B). **48 resolved, 0 in review, 5 open, 1 superseded.**

> **Note on UJ descriptions:** Jacques flagged 2026-04-24 that UJ entries lack the options/impact/reference depth of the OI entries. A separate enrichment pass is queued before the next MPP review — not addressed in v2.10.

---

# Part A — FDS Open Items

These items are called out inline in the FDS with `> **RESOLVED**` / `> **PENDING CUSTOMER VALIDATION**` / `> **OPEN**` callouts. Each requires a decision before its FDS section can be finalised.

---

### OI-01 — Event outbox dispatch pattern — ✅ Resolved

**Priority:** HIGH
**Owner:** Blue Ridge / MPP IT
**FDS §:** 1.6
**References:** FDS-01-006; FRS 3.17.4; FRS 5.5.1; Spark Dep. B.12

**Description:** SQL event outbox table vs. Ignition application-layer dispatch for external calls (AIM, printers, etc.).

**Options considered:**
- (a) SQL event outbox table in the Audit schema — persisted, survives restarts, queryable.
- (b) Ignition Gateway Scheduled Scripts / tag-based queuing — simpler, but queue state lives in memory / tags.

**Decision (2026-04-09):** Ignition application layer. Direct calls with an `Audit.InterfaceLog` write on every request and response — no outbox table. Removes a whole pattern from the FDS and keeps the dispatch flow in one place.

---

### OI-02 — Weight-based container closure — ✅ Resolved (2026-04-24)

**Priority:** HIGH
**Owner:** Blue Ridge / MPP Engineering
**FDS §:** 6.6
**References:** FDS-06-014, FDS-03-017; FRS 3.6.6, 3.9.7; Appendix C (OPC Tags: `TargetWeightValue`, `TargetWeightMetFlag`)

**Description:** On non-serialized / inspection lines, does `Parts.ContainerConfig` need a `ClosureMethod` (`BY_COUNT` vs `BY_WEIGHT`) and a `TargetWeight` field?

**Options considered:**
- (a) Add `ClosureMethod` + `TargetWeight` to `ContainerConfig`.
- (b) Weight closure handled entirely in the PLC — MES responds to a "container full" signal only.

**Proposed decision (pending customer validation):** Non-serialized lines should receive feedback from a scale. The two columns (`ClosureMethod`, `TargetWeight`) were added as nullable to `ContainerConfig` in Phase 4 pending confirmation.

**Decision (2026-04-24):** Proposed decision confirmed by Jacques. `ClosureMethod` + `TargetWeight` on `Parts.ContainerConfig` stay. Non-serialized lines drive closure via scale feedback per FDS-06-014. **Integration queued:** remove "pending validation" language from FDS §6.6 / §3.6; ERD Parts tab card updated to drop the "pending" caveat. UJ-13 (duplicate open item) also closes.

---

### OI-03 — Shift runtime adjustments — ✅ Resolved (2026-04-20)

**Priority:** MEDIUM
**Owner:** MPP Production Control
**FDS §:** 9.4
**References:** FDS-09-009; FRS 3.15.2; DCFM Paper Sheets (lunch/break/OT adjustments)

**Description:** Legacy paper forms add minutes for running through lunch (+30), breaks (+10), or 10-hour overtime (+110). How are those adjustments captured in the MES?

**Options considered:**
- (a) Adjust `Oee.Shift.ActualEnd` to reflect the true end time.
- (b) Add an adjustment field to the shift record.
- (c) Derive runtime purely from downtime events (available time = shift duration − total downtime).

**Decision (2026-04-20):** Option (c). MES captures **event + duration**, never minute adjustments. Shift schedule imports from MPP's 5–6-spreadsheet rollup (customer to share the template). Shifts are Monday–Friday at fixed times; early starts automatically increase availability because events drive runtime. Operators register breaks at end of shift as a single uptime-vs-downtime categorisation — no live per-break entry. Implementation lands in Phase D (FDS §9.4 rewrite).

---

### OI-04 — Vision system conflict resolution — ✅ Resolved (2026-04-24)

**Priority:** MEDIUM
**Owner:** MPP Engineering / Quality
**FDS §:** 10.3
**References:** FDS-10-003, FDS-10-005; FRS 3.16.1, 3.16.9; Appendix C (OPC Tags: `VisionPartNumber`); FRS 2.1.8

**Description:** Cognex says part X, operator said part Y. What happens?

**Options considered:**
- (a) Block production until resolved.
- (b) Allow override with supervisor PIN.
- (c) Log discrepancy and continue.

**Revised decision (2026-04-20):** MPP pushed back on the earlier "auto-hold LOT + supervisor override" recommendation. New direction:
1. **Stop the operation/line** until the issue is rectified — do NOT place the LOT on hold.
2. **10-consecutive-fail escalation** — after 10 back-to-back failures the system escalates to a leader.
3. **Branch by failure type** — *wrong part* triggers leader flag; *wrong orientation* requires no escalation.
4. **Hold release** — Quality releases a hold; a Controlled Run Tag (CRT) requires a subsequent 200%-inspect; if the CRT run wasn't inspected when executed, material must re-run through the process.

Supervisor elevation uses the per-action AD prompt from FDS-04-007 (no PIN). Requires FDS §10.3 rewrite and a new escalation-state model. Work lands in Phase D.

**Decision (2026-04-24):** Proposed decision confirmed by Jacques. FDS §10.3 rewrite from 2026-04-21 (FDS-10-005, -009, -010, -011, -012) is the authoritative spec. **Integration queued:** UJ-17 (duplicate open item) closes.

---

### OI-05 — LOT merge business rules — ✅ Resolved (2026-04-24)

**Priority:** HIGH
**Owner:** MPP Production Control / Quality
**FDS §:** 5.5
**References:** FDS-05-012; FRS 3.9.13, 3.9.12, 3.13.1, 3.13.2

**Description:** What rules govern LOT merges? Same part only? Same die/cavity? Additive piece counts? Reversible?

**Revised decision (2026-04-20):** MPP provided concrete rules:
- Merges only allowed **after sort is complete**.
- Same part number, but **different dies are allowed only if die ranks are compatible** — e.g., rank A cannot be mixed; rank E can. Full compatibility matrix owed by MPP Quality.
- Machining is **FIFO by cavity**.
- An "IPP tag" is attached when a die arrives; IPP is an identifier only (details modelled as flexible Tool attributes under OI-10 → Phase B).

**Addendum (2026-04-23):** Post-merge LOT has **NULL `ToolId` + `ToolCavityId`** on `Lots.Lot` — blended-origin material cannot denormalize multiple Tool origins into a single FK pair. Tool-specific trace reconstructed via genealogy of the pre-merge source LOTs (`Lots.LotGenealogy` walk).

Implementation couples to the Phase B Tool Management design because die rank lives on the Tool / Cavity entity. Data model will grow a `Tools.DieRankCompatibility` lookup seeded from the MPP matrix. FDS §5.5 rewrite in Phase D.

**Decision (2026-04-24):** Revised decision + 2026-04-23 post-merge-NULL-Tool addendum both confirmed by Jacques. `Tools.DieRankCompatibility` matrix still owed by MPP Quality; supervisor AD override is the only cross-die merge path until the matrix loads. **Integration queued:** UJ-08 (duplicate open item) closes.

---

### OI-06 — Operator identity & session model — ✅ Resolved (Phase C, 2026-04-21)

**Priority:** MEDIUM
**Owner:** MPP Operations
**FDS §:** 4 (entire)
**References:** FDS-04-001 through FDS-04-010; FRS 3.3.1, 3.3.4, 3.6.1; FRS 5.3; Spark Dep. B.8

**Description:** Session lifecycle for operators, quality, and supervisors. Badge-per-shift, badge-per-action, timeouts, re-auth triggers.

**Options considered:**
- (a) Badge once per shift — re-auth only for elevated actions.
- (b) Badge per transaction.
- (c) Hybrid.
- (d) *(added after 2026-04-20 meeting)* Operators don't authenticate at all; initials only.

**Decision (2026-04-20, implemented 2026-04-21):** Option (d). Operators are identified by **initials** entered at a shop-floor terminal (no clock number, no PIN), which establish an operator presence context that stamps `AppUserId` on events. Interactive users (Quality, Supervisor, Engineering, Admin) continue via Active Directory. Elevated actions are per-action AD re-prompts — no session-sticky elevation, no 5-minute timeout. Dedicated vs Shared terminal modes via `LocationAttribute`. 30-minute idle re-confirmation overlay ("Operate as [XY]? Y / N — change"). Pre-populated defeasible Initials field on every mutation screen. Operator `AppUser` rows are managed in the Configuration Tool (Admin screen). Tom (MPP security SME) still owes a final review of the elevated-action list (see FDS-04-007).

Delivered via FDS v0.8, Data Model v1.6, User Journeys v0.6, Config Tool phased plan v1.7 (commit `dbeac08`). Schema cleanup (drop legacy `ClockNumber` / `PinHash` columns) deferred to Phase G.

---

### OI-07 — Work order scope — ✅ Resolved (2026-05-01)

**Priority:** HIGH (active); FUTURE hooks are LOW
**Owner:** MPP / Blue Ridge (Ben is SME for the future Demand / Maintenance engine)
**FDS §:** 6.10
**References:** FDS-06-022, FDS-06-023, FDS-06-024, FDS-06-025, FDS-06-026; FRS 3.1.5, 3.10.1, 3.10.2, 3.10.5; Spark Dep. B.5

**Description:** Include Work Orders in MVP or defer entirely? Biggest CONDITIONAL decision.

**Options considered:**
- (a) Include — auto-generated, invisible to operators.
- (b) Defer — all WO tables exist but are not populated.
- (c) MVP-lite — create WOs but no operator-facing screens.

**Decision (2026-04-24 correction of 2026-04-20):** **MVP-LITE with a single active type — `Production`.** Plus a code-table hook that allows future Demand (planned PM) and Maintenance (emergency) types to be added without schema change. Recipe is deleted entirely.

**The 2026-04-20 meeting note was mis-recorded.** The raw note read:

```
Ben has more information about work orders
maintenance engine
demand work orders, maintenance work orders
recipe work orders to not be operator visible
```

Jacques clarified 2026-04-24: the "recipe work orders to not be operator visible" line was actually describing the **Production** work orders already in our design (MVP-lite, auto-generated on LOT start, invisible to operators). There is no separate Recipe concept and there never was. The earlier three-type `Demand` / `Maintenance` / `Recipe` model (FDS v0.10, Data Model v1.7) grew out of extrapolating those four meeting-note words into a full taxonomy — a drafter's error.

**Under MPP's actual taxonomy:**

| Type | Meaning | MVP status |
|---|---|---|
| **Production** | The existing auto-generated, per-LOT, invisible-to-operators bookkeeping (formerly mis-named "Demand"). | **MVP-LITE** — built, auto-generated, no operator screens. |
| **Demand** | Planned preventative maintenance. | **FUTURE** — not in scope for this project. |
| **Maintenance** | Emergency maintenance. | **FUTURE** — not in scope for this project. |

The existing **MVP-lite behaviour does not change.** What changes is:
- The code value in `Workorder.WorkOrderType` is renamed `Demand` → `Production`.
- `Recipe` is deleted from the code table and from every doc.
- `Maintenance` is also removed from the current seed (it was only a placeholder for a future flow). The code table **mechanism** stays as the schema hook — future MPP work can INSERT `Demand` and `Maintenance` rows without a schema change.
- The nullable `ToolId` FK on `Workorder.WorkOrder` stays as a schema hook for future Maintenance WOs targeting a Tool. No flow or proc enforcement in MVP.

**Data model impact:** `Workorder.WorkOrderType` remains. Seed shrinks from 3 rows to 1 row (`Production`).

**SQL correction follow-up (queued, not executed this turn):**
1. New versioned migration (next unclaimed number, e.g., `0013_workordertype_correction.sql`): `UPDATE Workorder.WorkOrderType SET Code='Production', Name='Production Work Order', Description='...' WHERE Id=1`; `DELETE WHERE Id IN (2, 3);` — leaves a single-row seed.
2. Update `sql/tests/0019_Parts_ConsumptionMetadata_And_ScrapSource/010_Phase_E_additives.sql` — current test asserts 3 seed rows + presence of Code='Demand'. Should assert 1 seed row + Code='Production'.
3. Update repeatable proc comments for `R__Workorder_WorkOrderType_List.sql` and `R__Workorder_WorkOrderType_Get.sql` (comment-only change landing this turn).

**Ben's maintenance-engine scope** is NOT gating this project. When MPP later scopes a maintenance MES project, they can INSERT the new `Demand` (planned PM) and `Maintenance` (emergency) code rows and build the flow on top of the existing schema hook. Until then, leave the code table single-seeded.

**Decision (2026-05-01):** Closed. Production-only seed confirmed by Jacques in markup of the 2026-05-01 Outstanding Items extract. SQL correction migration `0013_oi07_oi12_corrections.sql` already landed (2026-04-28); no further work this project. The schema hook for future Demand / Maintenance code rows remains in place.

---

### OI-08 — Terminal architecture — ✅ Resolved (2026-04-24)

**Priority:** MEDIUM
**Owner:** MPP IT / Operations
**FDS §:** 2.5
**References:** FDS-02-008, FDS-02-009; FRS 3.7.1, 3.7.2; Spark Dep. B.1; FRS Appendix B (~230 machines)

**Description:** Count of terminals (~230 1:1 with machines, or fewer shared)? If shared, how does the operator pick the active machine?

**Earlier decision (2026-04-09, retained as baseline):** Fewer shared terminals, with a machine barcode / QR scan as the first step of any interaction. `Terminal` is a `LocationTypeDefinition` under `Cell`; events carry both `TerminalLocationId` and `LocationId`.

**Addenda (2026-04-20):** MPP added more texture that needs to be folded into the design:
- **Terminal-to-cell mode.** About 80% of terminals are dedicated (1:1 with a Cell); the remaining 20% (e.g., trim shop with multiple stations on one terminal) are shared. Model this as a `LocationAttribute` on the Terminal (`TerminalMode` = `Dedicated` / `Shared`). Dedicated terminals persist the operator presence context through the shift; shared terminals prompt on first action and on machine change. Already captured in FDS §4 / Phase C.
- **Operator cannot navigate off-machine.** A terminal's machine context is locked unless the operator explicitly re-scans (force-print workflow). Not a free-for-all dropdown.
- **Part ↔ machine validity map.** Need a configurable mapping of which parts can run on which machines (extension of Phase 5's `Parts.ItemLocation` eligibility junction — likely sufficient; confirm in Phase D).
- **Tablets planned for casting.** Mobile-friendly layout is a design input, not just a nice-to-have. Affects Perspective view sizing.
- **Honda RFID on labels (future).** Honda plans RFID; the MES should not block that path. Out-of-scope for MVP but worth a forward-compatibility note in FDS §2.5.

Work lands in Phase D (FDS §2.5 addenda pass).

**Decision (2026-04-24) — new clarification from Jacques:** The Terminal's **Location assignment determines its mode**:
- **Terminal assigned to a WorkCenter (or Cell)** → `TerminalMode = Dedicated`. Machine context is pre-known from the Location hierarchy. No location scan/select required at the start of an interaction.
- **Terminal assigned to an Area** → `TerminalMode = Shared`. Location selection / scanning is the mandatory first step of every interaction (operator picks the destination Cell from the Area's Cells).

This supersedes the earlier `TerminalMode` LocationAttribute approach with a simpler rule: the Location the Terminal is attached to *is* the signal. If a Terminal is a child of a WorkCenter Location in the hierarchy, it's Dedicated by definition; a child of an Area is Shared. No separate attribute value required.

**Integration queued:** FDS §2.5 (FDS-02-010 `TerminalMode` LocationAttribute) rewritten to derive from Terminal parent-Location tier instead of being a separately-seeded attribute. Arc 2 Plan Phase 1 `Terminal_ResolveFromSession` proc reads the parent tier and returns Dedicated/Shared accordingly. Data Model Phase 9 migration may drop the `TerminalMode` `LocationAttributeDefinition` seed if fully superseded (verify during integration). UJ-12 already closed.

---

### OI-09 — Multi-part lines & cavity-parallel LOTs — ✅ Closed (2026-04-23)

**Priority:** MEDIUM
**Owner:** MPP Engineering
**FDS §:** 3.6, 5.1, 5.3, 5.4
**References:** FDS-03-016, FDS-03-017; FRS 3.9.7, 3.16.1, 3.16.2; MS1FM-1028 (multi-part line example)

**Description:** On lines that run multiple part numbers (MS1FM-1028 → 59B / 5PA / 6NA), how are containers handled? And separately: how do cavity-parallel LOTs at die cast work?

**Earlier decision (2026-04-09, retained):** One part at a time per line. Operator selects the active LOT for consumption, which determines the part number. No mixed-part containers. Changeover is an operator action.

**Decision (2026-04-23) — cavity-parallel LOTs codified:** A die-cast machine mounting a Tool with N active cavities produces **N parallel independent LOTs, not sublots**:

- Each LOT is created **lazily** at operator logging time with `ToolId` + `ToolCavityId` set (new FKs on `Lots.Lot` in Data Model v1.9).
- Each LOT fills at its own rate (scrap + cavity health + shutdowns vary).
- Each LOT closes independently via explicit operator action (Complete + Move).
- **No parent/child FK** between them — they're peers. Genealogy is flat at die cast.
- One LTT barcode per LOT (one physical basket = one LOT = one label).

**Distinct from Machining sub-LOT split (remains in FDS §5.4):**
- Machining OUT sometimes breaks a parent LOT into N child sub-LOTs at `Item.DefaultSubLotQty`.
- Parent→children recorded in `LotGenealogy` as SPLIT rows; parent transitions to CLOSED via `Lot_UpdateStatus`.

The 2026-04-20 meeting note conflated cavity-parallel LOTs with sub-LOT splitting — they are two distinct workflows. Cavity-parallel LOTs at die cast are peers, not sublots. Machining sub-LOT split is a legitimate sublot pattern.

Implementation lands in Data Model v1.9 (Lot.ToolId / Lot.ToolCavityId), FDS v0.11 (§§5.1, 5.3, 5.4 revisions), User Journeys v0.8 (Carlos Die Cast scene), and Arc 2 Plan Phase 3 (Die Cast terminal UX).

---

### OI-10 — Tool Life tracking — Superseded (rolled into Phase B)

**Priority:** HIGH
**Owner:** Blue Ridge / MPP Engineering
**FDS §:** 5.6 (new section in Phase B)
**References:** FRS 5.6.6, 3.14.8; Scope Matrix Row 26

**Description:** Where does Tool Life data live? Extend `LocationAttribute` vs. a dedicated table?

**Original options:**
- (a) Extend `LocationAttribute` with tool life attributes per machine.
- (b) Dedicated `ToolLife` table with shot counters, thresholds, reset events.
- (c) Hybrid — attribute for targets, event table for resets.

**Resolution path (2026-04-20):** Rolled into the **Phase B Tool Management design spec**. Tool is now a first-class subsystem: `Tools.Tool`, `Tools.ToolCavity`, die rank compatibility, check-in/out against Cells, shot counters (both materialized and event-append), maintenance WO linkage (OI-07). Six specific design questions are parked in `memory/project_mpp_tool_mgmt_design.md` awaiting Jacques's answers before the data-model work begins.

This item remains in the register for traceability but is no longer a stand-alone decision — its closure is the Phase B design spec landing.

---

### OI-11 — Part identity change at Casting → Trim Shop — ✅ Resolved (2026-04-22)

**Priority:** MEDIUM
**Owner:** MPP Engineering / Blue Ridge
**FDS §:** 5.10 (reframed around BOM-driven resolution)
**References:** Meeting notes 2026-04-20; derived from OI-05 / OI-10 context

**Description:** Per MPP, a part **changes its identity** as it moves from Casting to the Trim Shop — the part number is different on the two sides of that boundary, even though genealogy must tie them together.

**Options considered:**
- (a) Dedicated `Parts.ItemTransform` table (source Item + destination Item, with an `EventAt` and genealogy FKs).
- (b) Treat Trim as a renaming operation — add an attribute to the existing `LotGenealogy` flow.
- (c) Require BOM-driven resolution — the Trim part is a "produced from" of the Casting part.

**Decision (2026-04-22):** Option (c). Option (a) was initially chosen and drafted into Data Model v1.8 / FDS v0.10 / User Journeys v0.7; on review the `Parts.ItemTransform` table was fully redundant with `Workorder.ConsumptionEvent` — every column duplicated. The Casting → Trim boundary is a **degenerate 1-line BOM consumption**:

- Trim part's `Parts.Bom` has a single `BomLine` referencing the cast part at `QtyPer = 1`.
- At the first Trim Shop Cell, the MES uses `Parts.ItemLocation` + BOM lookup to find the destination trim part; prompts the operator to confirm receive-as; on confirm writes a normal `Workorder.ConsumptionEvent` (consumed cast / produced trim) + `Lots.LotGenealogy` row.
- Honda backward trace: same walk as any assembly consumption — shipped trim LOT → LotGenealogy → cast LOT → die / cavity / operator / timestamp.
- Yield loss (if any) handled normally via `Workorder.RejectEvent` on the source side.

**No new schema** — `Parts.ItemTransform` was removed from the v1.8 draft before any SQL landed. Affected docs updated to v1.8-rev / v0.10-rev / v0.7-rev; Phase G migration dropped the ItemTransform `Audit.LogEntityType` seed row (9 rows instead of 10; re-run green, 779/779 tests still pass).

---

### OI-12 — Lineside inventory caps — ✅ Resolved with modification (2026-04-24)

**Priority:** MEDIUM
**Owner:** MPP Operations / Blue Ridge
**FDS §:** TBD (§3 addenda in Phase E)
**References:** Meeting notes 2026-04-20; FRS 3.6.6 (container config)

**Description:** Operators game the current system by scanning in a large quantity of parts-to-consume at once so they don't have to re-scan as often. MPP wants a cap:
- **Max parts per basket** (ContainerConfig-level).
- **Max lineside inventory quantity** (per Cell / workstation).

Exceeding either limit should reject the scan-in.

**Proposed direction:** Add `MaxParts INT NULL` to `Parts.ContainerConfig`. Add a `LinesideLimit` concept as a `LocationAttribute` on Cells. Validation fires in the scan-in mutation proc. Designed in Phase E, implemented in Phase G.

**Decision (2026-04-24) — modification from Jacques:** Proposed decision is **fundamentally inaccurate** on the `MaxParts` placement. **`MaxParts` is a Part attribute, not a ContainerConfig attribute** — it's evaluated when inventory is checked into a Location, against the Part identity, not against the container's packing recipe. The lineside-limit concept (per-Cell `LinesideLimit` `LocationAttribute`) stays — that is a Location concern. But the per-basket-type cap moves off `Parts.ContainerConfig` and onto `Parts.Item`.

**Integration queued:**
- **Data Model v1.9b** (or next rev): DROP `Parts.ContainerConfig.MaxParts` column (shipped in Phase G migration `0010`); ADD `Parts.Item.MaxParts INT NULL` — cap of pieces allowed to check into any single Location for this Item. Validation: on `LotMovement` to a Cell, sum pieces already at the destination Cell of this Item + incoming quantity ≤ `Parts.Item.MaxParts`.
- **FDS-03-019** rewritten to target `Parts.Item`, not `Parts.ContainerConfig`.
- **FDS-03-020** (Lineside cap via `LocationAttribute`) stays as-is.
- **SQL correction migration queued**: drop `Parts.ContainerConfig.MaxParts`, add `Parts.Item.MaxParts`, update test `sql/tests/0019_Parts_ConsumptionMetadata_And_ScrapSource/`. Coordinate with the OI-07 correction migration.
- **ERD Parts tab** — move the `MaxParts` annotation from `ContainerConfig` to `Item`.

---

### OI-13 — BOM source system — ✅ Resolved with caveat (2026-04-24)

**Priority:** HIGH
**Owner:** MPP IT / Blue Ridge
**FDS §:** 1.4 (Interfaces) / 3 (Master Data) — Phase E
**References:** Meeting notes 2026-04-20 ("BOMs are on the flexware app on 919")

**Description:** BOMs are authoritative in the legacy **Flexware application at IP `.919`** — the predecessor MES being replaced. The new MES's `Parts.Bom` seed data must come from there.

**Options:**
- (a) One-shot export from the Flexware app into a CSV / Excel file, bulk-loaded into the new MES at cutover.
- (b) Periodic re-sync from the Flexware app until MPP cuts over fully.
- (c) Live integration (ODBC / API / file drop) — unlikely to be worth it if Flexware is being retired.

**Proposed direction:** Option (a) — one-shot export at cutover. Document the export spec in FDS §1.4, add to the Reference Material list, and plan a bulk-load proc (similar to `Oee.DowntimeReasonCode_BulkLoadFromSeed`) once MPP delivers the export. Designed in Phase E; bulk-load proc in Phase G.

**Decision (2026-04-24) — caveat from Jacques:** Proposed direction confirmed with **two-pull** timing: (1) first export pulled **NOW** for dev integration + validation (load into dev DB; verify parts/BOMs resolve correctly; surface missing items and data gaps before cutover); (2) cutover-day re-export + re-run of the bulk-load migration to catch any changes MPP made in the interim. This converts the "one-shot at cutover" into a rehearsed two-phase process — dev load is the rehearsal, cutover load is the production run.

**Integration queued:**
- FDS-14-005 Flexware BOM Import — update "Cutover handoff" bullet to describe the two-pull timing.
- **Action needed NOW:** coordinate with MPP IT for the first Flexware export delivery. Pre-flight validation proc (`Parts.Bom_BulkLoadFromSeed`) design starts immediately.

---

### OI-14 — Admin remove-item capability — ✅ Resolved (2026-04-24)

**Priority:** LOW
**Owner:** Blue Ridge
**FDS §:** 4.3 (elevated actions) + Config Tool phased plan
**References:** Meeting notes 2026-04-20

**Description:** Admin needs to be able to **remove items** (LOTs, Containers, inventory rows) directly — for cleanup, mis-entry correction, and general "oops" recovery that can't flow through normal deprecate paths.

**Proposed direction:** Admin-only Configuration Tool screen with full audit trail. Already listed in FDS-04-007 elevated-action list (Phase C). Detail design in Phase E; proc in Phase G.

**Decision (2026-04-24):** Proposed direction confirmed by Jacques. **Integration queued:** Config Tool phased plan — add admin remove-item screen to Phase 9 or later Config Tool pass; SQL procs to land in the next Phase G-equivalent batch for Arc 2.

---

### OI-15 — Global Trace / Track screen — ✅ Resolved (2026-04-24)

**Priority:** HIGH
**Owner:** Blue Ridge / MPP Operations
**FDS §:** TBD (new section in Phase E — likely §5 addendum or new §15 operator tools)
**References:** Screenshot review 2026-04-22 (`reference/MPP_Current_MES_screenshots.docx` image 1, "Track" top-level tile)

**Description:** Legacy MES has a top-level **Track** tile providing a non-workstation path to look up any LOT, serial number, or container and view its full genealogy. Our current FDS does not call out a global trace operator tool — trace today is implicit through the Lot Details screen but requires a workstation context.

**Options:**
- (a) Dedicated Perspective screen reachable from the home tile bar: input = LOT / serial / container ID, output = genealogy tree + lot details.
- (b) Rely on the Configuration Tool's Lot browser for supervisors / quality only.
- (c) Inline "search" box on the home page that drills into the Lot Details screen.

**Proposed direction:** Option (a). Honda traceability is the core mission of the project; operators, supervisors, and quality all need a zero-context lookup path. Designed in Phase E.

**Decision (2026-04-24):** Proposed direction confirmed by Jacques. FDS-12-012 / -013 / -014 Global Trace Tool is authoritative. **Integration queued:** Arc 2 Plan Phase 7 (or earlier Phase that ships the home-tile router) to include the Track tile wiring.

---

### OI-16 — Auto-finish-on-target WO semantics — ✅ Resolved with additions (2026-04-24)

**Priority:** MEDIUM
**Owner:** Blue Ridge / MPP Engineering
**FDS §:** 6.10 addendum + data-collection capture contract (FDS-03-017a)
**References:** Screenshot review 2026-04-22 (image 7, Work Order "Camera system automatic processing" + "Scale system automatic processing"); FRS 3.10

**Description:** Legacy WO configuration exposes **Camera system automatic processing** (tray quantity + part recipe number) and **Scale system automatic processing** (target set quantity) with an explicit "automatically finish when target is reached" semantic. FDS-03-017a covers capturing counts and weights but does not specify the auto-close behaviour at the WO boundary.

**Proposed direction:** Extend §6.10 and `Workorder.ProductionEvent_Record` to fire a WO-close event when cumulative ProductionEvent count (camera) or cumulative weight (scale) reaches the WO target. Configurable per WO.

**Decision (2026-04-24) — additions from Jacques:** Proposed direction confirmed with two additions:

1. **Expect a PLC confirmation BIT.** When camera / scale target is reached, the PLC writes a confirmation BIT; our Gateway script observes the BIT (not just the cumulative count) before firing the auto-close. Belt-and-suspenders: count crosses target AND PLC affirms, not either-or.

2. **Confirm-button style is a per-Terminal `LocationAttribute`.** Some production lines require the operator to physically press a large "Confirm Completion" button at a fixed 1:1 terminal before the WO / Tray / Container closes (manual acknowledgement step). Other lines just show a passive popup ("WorkOrder completed" / "Tray completed" / "Container completed" — whichever is relevant) and proceed. This is configurable per Terminal via a new `LocationAttribute` (e.g., `RequiresCompletionConfirm BIT`) on the Terminal Location.

**Integration queued:**
- **Data Model:** new `LocationAttributeDefinition` seed row for `RequiresCompletionConfirm` on the `Terminal` `LocationTypeDefinition`.
- **FDS-06-028** extended with the PLC-confirmation-BIT requirement and the `RequiresCompletionConfirm` LocationAttribute rule.
- **Arc 2 Plan Phase 6** Perspective Assembly view gains the conditional confirm-button vs popup renderer driven by `session.custom.terminal.requiresCompletionConfirm`.

---

### OI-17 — Tray-divisibility validation on WO close — ✅ Resolved with modification (2026-04-24)

**Priority:** MEDIUM
**Owner:** Blue Ridge
**FDS §:** 6.10
**References:** Screenshot review 2026-04-22 (image 30, "Work order target quantity exceeded. Ensure target quantity is evenly divisible by the tray quantity.")

**Description:** Legacy MES enforces a business rule at container close: target quantity must be evenly divisible by tray quantity, otherwise the container cannot be processed. Rule is not captured in the current FDS or data model.

**Proposed direction:** Validate at WO Create / Edit (target `MOD` tray = 0) and re-validate at Close. Enforced in `Workorder.WorkOrder_*` mutation procs with a specific error code.

**Decision (2026-04-24) — modification from Jacques:** Tray-divisibility is a **Finished-Good Part attribute**. The PartsPerTray value (or the tray-divisibility rule) belongs on `Parts.Item` (or `Parts.ContainerConfig` as already modelled — needs verification during integration), not as free-standing WO validation logic. Validation still fires at WO Create / Edit / Close, but the authoritative source of the tray quantity is the Part, accessed via its ContainerConfig for shipping math.

**Integration queued:**
- **Data Model:** confirm `Parts.ContainerConfig.PartsPerTray` is the authoritative tray quantity (it is — no schema change needed). Document the rule: "WO target must be evenly divisible by `Parts.ContainerConfig.PartsPerTray` of the WO's finished-good Item."
- **FDS-03-021** (WO-create tray-divisibility validation) and **FDS-06-029** (WO-close tray-divisibility validation) — both explicitly reference `Parts.ContainerConfig.PartsPerTray` as the source; confirm FDS language and update if not already explicit.

---

### OI-18 — Parts.ItemLocation consumption metadata — ✅ Resolved with extension (2026-04-24)

**Priority:** MEDIUM
**Owner:** Blue Ridge / MPP Engineering
**FDS §:** 3 (Master Data) + §5/6 consumption flows
**References:** Screenshot review 2026-04-22 (image 12, Material "Compatible work cells" table with Min Quantity / Max Quantity / Default Quantity / Consumption Point columns)

**Description:** Legacy Material → Compatible Work Cells mapping carries four extra attributes — **Min Quantity**, **Max Quantity**, **Default Quantity**, and **Consumption Point (BIT)**. These feed the runtime Allocations grid at the workstation. Our `Parts.ItemLocation` is a plain boolean eligibility junction.

**Proposed direction:** Extend `Parts.ItemLocation` with `MinQuantity INT NULL`, `MaxQuantity INT NULL`, `DefaultQuantity INT NULL`, `IsConsumptionPoint BIT NOT NULL DEFAULT 0`. Designed in Phase E; SQL in Phase G.

**Decision (2026-04-24) — extension from Jacques:** Proposed decision confirmed, with an additional hierarchy requirement. `Parts.ItemLocation` must support designation at **Area / WorkCenter / Cell** granularity — not Cell-only. The junction row's `LocationId` FK can point at any Location tier (Area, WorkCenter, or Cell); when a Part is checked into a specific Cell, the compatibility check cascades up: if the Part has an `ItemLocation` row for *any* ancestor Location of the scanned Cell (including the Cell itself), the Part is eligible there.

This enables rules like "Part 5G0 is eligible across all of Die Cast Area" with a single row, without enumerating every Cell.

The consumption metadata (Min / Max / Default / IsConsumptionPoint) **retains** — these are orthogonal to the hierarchy extension. **Does NOT duplicate OI-12's work** per Jacques's review:
- **OI-12** = per-Location runtime inventory cap (`Parts.Item.MaxParts` evaluated at check-in; per-Cell `LinesideLimit` LocationAttribute).
- **OI-18** = design-time eligibility + consumption-point quantities (Min/Max/Default for the Allocations grid UX).

**Integration queued:**
- **Data Model v1.9c (or next rev):** `Parts.ItemLocation.LocationId` — no schema change (already a generic `FK → Location.Id`); document the hierarchy-cascade rule. The scan-in guard is the place where the cascade is enforced.
- **FDS-03-014 / -015 / -018** — rewrite the eligibility checks to include the Area/WorkCenter/Cell cascade logic.
- **New SQL helper proc** (`Parts.ItemLocation_IsEligible(@ItemId, @CellLocationId)` or equivalent) that walks the Location hierarchy from `@CellLocationId` upward looking for a matching `ItemLocation` row.
- **Config Tool Eligibility screen** (existing) — UI additions to allow selecting the target Location at any tier when creating an `ItemLocation` row.

---

### OI-19 — Parts.Item.CountryOfOrigin — ✅ Resolved (2026-04-24)

**Priority:** LOW (effort) / HIGH (compliance)
**Owner:** Blue Ridge
**FDS §:** 3 (Master Data)
**References:** Screenshot review 2026-04-22 (image 13, Material configuration "Country of origin" field)

**Description:** Legacy Item carries a Country of Origin code. Honda compliance may require it on genealogy / shipping output. Not currently modelled.

**Proposed direction:** Add `CountryOfOrigin NVARCHAR(2) NULL` (ISO 3166-1 alpha-2) to `Parts.Item`. Designed in Phase E; SQL in Phase G.

**Decision (2026-04-24):** Proposed direction confirmed by Jacques. Column already shipped in Phase G migration. **Integration queued:** FDS §3.1 language can drop any "pending" framing.

---

### OI-20 — Scrap source enum (Inventory vs Location) — ✅ Resolved (2026-04-24)

**Priority:** LOW
**Owner:** Blue Ridge
**FDS §:** 5 + ProductionEvent spec
**References:** Screenshot review 2026-04-22 (image 31, "Scrap from inventory" vs "Scrap from the selected location" buttons on Lot Details)

**Description:** Legacy Lot Details screen exposes two distinct scrap paths: scrap from *inventory* (unallocated stock on a lot) vs scrap from a *selected location* (in-process at a specific workstation). Our current `Workorder.ProductionEvent.Type = Scrap` does not capture the distinction.

**Proposed direction:** Add a `ScrapSource` code table (Inventory / Location) and `ScrapSourceId BIGINT NULL` on `Workorder.ProductionEvent`. Designed in Phase E; SQL in Phase G.

**Decision (2026-04-24):** Proposed direction confirmed by Jacques. `Workorder.ScrapSource` code table + `ProductionEvent.ScrapSourceId` FK — both already in Data Model v1.9 / shipped via Phase G migration. FDS-06-023a is authoritative.

---

### OI-21 — Partial start / partial complete at a workstation + Pausable LOT — ✅ Resolved (2026-04-27, design locked)

**Priority:** MEDIUM
**Owner:** Blue Ridge / Ben
**FDS §:** 5.3 (FDS-05-032 partial start/complete + FDS-05-038 Pausable LOT)
**References:** Screenshot review 2026-04-22 (image 33, Tumbling Move Lot with separate "Start lot quantity" and "Complete lot quantity" fields; "0 in inventory available to start, 11 available to complete")

**Description:** Legacy Move Lot UX allows starting N-of-M pieces now and completing the remainder later — start and complete quantities are decoupled per lot per workstation. Beyond that, MPP wants the operator to be able to deliberately **pause** a partially-progressed LOT at a Cell to attend to a different LOT at the same Cell, and return to it later (potentially across shifts, potentially with a different operator).

**Decision (2026-04-24) — partial start/complete confirmed by Jacques:** `Workorder.ProductionEvent` already supports independent Start and Complete event emission with derived WIP — FDS-05-032 is authoritative. (No changes to ProductionEvent shape required by this OI.)

**Decision (2026-04-27) — Pausable LOT design locked (Claude + Jacques discussion):** the four open design questions from the v2.10 entry are answered as follows.

**Q1 — Where does Pause live in the schema?** **Not on `WorkOrderStatus`, not on `OperationStatus`, not on `LotStatusCode`.** Pause is a `(Lot, Location)` lifecycle event — a new append-only `Lots.PauseEvent` table mirroring `Quality.HoldEvent`'s open + close lifecycle. Rationale: WO and WOO are MVP-LITE / invisible to operators (OI-07); a `Paused` row on `WorkOrderStatus` would awkwardly couple operator workflow state to bookkeeping that operators never see. `LotStatusCode` (Good / Hold / Scrap / Closed) is for LOT quality state, not for transient operator focus shifts. A dedicated `PauseEvent` table gives direct `LotId` + `LocationId` for the wallboard counter and detail-list queries, and full pause/resume history (not just current state).

**Q2 — Cross-location concurrency?** **Allowed.** The same LOT MAY be paused at multiple Cells simultaneously (e.g., a Machining LOT mid-progress at one Cell, paused there to handle Assembly work at another Cell). The schema-level filtered UNIQUE on `(LotId, LocationId) WHERE ResumedAt IS NULL` enforces at most one **open** pause per `(LotId, LocationId)` pair only — multiple Locations are independent.

**Q3 — Resume UX trigger?** **No auto-prompt.** When an operator selects or scans a fresh LOT at a Cell that has a paused LOT open, the system SHALL NOT automatically prompt "resume paused LOT?". Rationale (Jacques): Assembly auto-loads the next LOT from upstream Machining FIFO — an unconditional resume prompt would interrupt the normal flow. Instead, every workstation screen SHALL surface a **Paused-LOT indicator** showing the current open-pause count at that Cell. Tapping the indicator opens a list (LotName, Part, PausedAt, PausedByUserId) and allows the operator to resume any paused LOT explicitly. Resume MAY be performed by a different operator from the one who paused.

**Q4 — TTL / cleanup?** **None.** Paused LOTs persist indefinitely. No auto-resume, no auto-cancel. Cleanup of long-paused LOTs is an operational concern handled outside the system (supervisor sweep, "long-paused LOTs" report).

**Other locked decisions:**
- `PausedReason` is **optional** (`NVARCHAR(500) NULL`) — operators MAY pause without entering one.
- `ResumedRemarks` is also optional.
- No FK to `WorkOrderOperation` — `LotId` + `LocationId` is sufficient; the WO/WOO link is recoverable via `ProductionEvent.LotId` if ever needed for reporting.
- Pause does NOT write a `Oee.DowntimeEvent` — the Cell is not down (another LOT may be running).
- Pause does NOT transition `WorkOrderStatus`, `OperationStatus`, or `LotStatusCode`.

**Integration landed (this commit):**
- **Data Model v1.9g** — new `Lots.PauseEvent` table contract (mirrors `Quality.HoldEvent`): `LotId`, `LocationId`, `PausedByUserId`, `PausedAt`, optional `PausedReason`, nullable `ResumedByUserId/ResumedAt/ResumedRemarks`. CHECK pairing on resume cols + filtered UNIQUE on `(LotId, LocationId) WHERE ResumedAt IS NULL` + supporting indexes. `Audit.LogEntityType` +1 row (`PauseEvent`) at Arc 2 Phase 1.
- **FDS v0.11h** — FDS-05-038 (NEW) under §5.3.
- **ERD** — Lots tab `PauseEvent` table card + mermaid box + relationships to `Lot`, `Location`, `AppUser`.

**Integration queued (Arc 2 Phase 1 SQL):**
- Versioned migration adds `Lots.PauseEvent` table + constraints alongside the rest of the Lots schema CREATE.
- Repeatable procs: `Lots.LotPause_Place`, `_Resume`, `_GetByLocation`, `_GetCountsByLocation`.
- Test suite: open / open-conflict / cross-location concurrency / resume / resume-no-open-pause / counter / detail-list.
- Arc 2 Plan Phase 3 / 4 wires the wallboard indicator into every Cell-level Perspective view.

---

### OI-22 — Dedicated Hold Management screen — ✅ Resolved (2026-04-24)

**Priority:** MEDIUM
**Owner:** Blue Ridge / MPP Quality
**FDS §:** 5.7 (Holds)
**References:** Screenshot review 2026-04-22 (image 1, top-level "Hold" tile)

**Description:** Legacy MES gives Holds a top-level navigation tile. Our FDS §5.7 specifies the `HoldEvent` place/release lifecycle but does not explicitly mandate a dedicated Hold-management screen — it may currently be implicit via per-lot hold buttons only.

**Proposed direction:** Add a Hold Management Perspective screen: list of all active holds, filterable by area / line / lot / hold reason, with place / release actions (supervisor-elevated). Designed in Phase E.

**Decision (2026-04-24):** Proposed direction confirmed by Jacques. FDS-08-007a is authoritative. **Integration queued:** Arc 2 Plan Phase 7 (or earlier) to include the Hold tile + screen wiring.

---

### OI-23 — Lot computed TotalInProcess / InventoryAvailable — ✅ Resolved with modification (2026-04-24)

**Priority:** LOW
**Owner:** Blue Ridge
**FDS §:** 5
**References:** Screenshot review 2026-04-22 (image 31, Lot Details header "Total in-process" and "Inventory available")

**Description:** Legacy Lot Details surfaces two derived figures in the header: **Total in-process** (sum across workstations) and **Inventory available** (unconsumed stock on the lot). Our FDS implies these are derivable from `ProductionEvent` but does not specify the exact derivation or whether they should be materialized for UI performance.

**Proposed direction:** Document the derivation in FDS §5 and decide materialized-column-vs-view. If materialized, update on every ProductionEvent write. Designed in Phase E.

**Decision (2026-04-24) — modification from Jacques:** Use a **view**, calculate on view update. Not materialized columns.

**Integration queued:**
- **Data Model:** no columns added to `Lots.Lot` for these derivations. Instead, create `Lots.v_LotDerivedQuantities` (or similar) as a SQL view that computes `TotalInProcess` and `InventoryAvailable` from `Lots.Lot.PieceCount` + `Workorder.ProductionEvent` + `Workorder.ConsumptionEvent` aggregations. Read-only.
- **FDS-05-031** rewritten to specify "view-backed derivation" and drop any "materialized-column option."
- **Arc 2 Plan Phase 2** — add the view creation to the LOT-lifecycle SQL migration.

---

### OI-24 — "Automation" top-level tile scope — ✅ Resolved (2026-05-01)

**Priority:** MEDIUM
**Owner:** MPP IT / Blue Ridge
**FDS §:** TBD
**References:** Screenshot review 2026-04-22 (image 1, top-level "Automation" tile — contents not captured in the provided screenshots)

**Description:** Legacy MES home page has an "Automation" tile. The screenshot set does not include its contents; likely OPC / interface management UI that overlaps with our `Audit.InterfaceLog`. Scope unknown.

**Proposed direction:** Ask MPP for screenshots or a walk-through of the Automation tile. Confirm any in-scope functionality is already covered by our interface-logging / OPC-tag management design. Discovery only — no design commitment until contents known.

**Decision (2026-05-01):** Closed — can be entirely ignored. The legacy Automation tile is not reproduced. Interface logging is covered by `Audit.InterfaceLog` and OPC tag management is covered by the Ignition Gateway's native tooling. No new schema; no Configuration Tool tile.

---

### OI-25 — Notifications configuration scope — ✅ Resolved (2026-05-01)

**Priority:** LOW
**Owner:** MPP Operations / Blue Ridge
**FDS §:** Out-of-MVP (banner-only via terminal context)
**References:** Screenshot review 2026-04-22 (image 10, Configuration "Setup > Notifications" tile); FDS-07-006a/b (banner notification mechanics)

**Description:** Legacy Configuration has a Notifications module for email / alert rules (likely fires on events such as hold placed, line stopped, etc.). Not in our design.

**Proposed direction:** Confirm MPP considers this out-of-MVP and that its absence is not a regression. If in-scope, schema and FDS §12 additions needed. Discovery only.

**Decision (2026-05-01):** Closed. Legacy Notifications configuration tile is out-of-MVP. Banner notifications are already covered by the workstation terminal-context feedback (FDS-07-006a/b print-failure broadcast pattern + elevation banners + hold/AIM-pool alarm tiles). Text and email notifications MAY be added as a post-deployment change order or as scope of a follow-on project — not gating this engagement.

**Integration queued:** FDS §12 (Reporting) one-liner: "Text and email notifications are out-of-MVP. Banner notifications via terminal context cover the in-scope notification surface."

---

### OI-27 — Material "Supply part" flag purpose — ✅ Resolved (2026-05-01)

**Priority:** LOW
**Owner:** MPP Engineering
**FDS §:** 3 (Master Data)
**References:** Screenshot review 2026-04-22 (image 12, Material config "Supply part" BIT)

**Description:** Legacy Material configuration has a "Supply part" BIT. Purpose not obvious from the UI — possibly distinguishes supplier-provided components from in-house produced items. Not in our model.

**Proposed direction:** Ask MPP what a "Supply part" is and whether it drives any workflow (BOM expansion, shipping, etc.). If confirmed, add `IsSupplyPart BIT NOT NULL DEFAULT 0` to `Parts.Item`. Discovery only.

**Decision (2026-05-01):** Closed — already handled. Our component-part modeling (`Parts.Item` + `Parts.Bom` + `Parts.ItemType` covering Cast / Machined / Assembled / Received) captures the supplier-vs-in-house distinction implicit in Flexware's `Supply part` BIT. No new `Parts.Item.IsSupplyPart` column needed.

---

### OI-28 — Work Cell "Require override for cast parts" flag — ✅ Resolved (2026-05-01)

**Priority:** MEDIUM
**Owner:** MPP Engineering / Blue Ridge
**FDS §:** 10 (Automation) — relates to OI-04
**References:** Screenshot review 2026-04-22 (image 19, Work Cell config "Require override for cast parts" checkbox)

**Description:** Legacy Work Cell has a flag requiring supervisor override specifically for cast parts. Likely relates to the OI-04 vision-conflict / line-stop flow but at cell-level granularity — appears to force a supervisor AD prompt for any cast-part mutation at that cell.

**Proposed direction:** Confirm with MPP whether this is still needed and how it interacts with OI-04's line-stop / escalation model. If retained, add `RequiresCastOverride BIT` as a `LocationAttribute` on the Cell type. Discovery only.

**Decision (2026-05-01):** Closed — built into the existing attribute system. Per-cell override behavior can be configured via the existing `LocationAttribute` slots without a new dedicated `RequiresCastOverride` BIT column on the Cell type.

---

### OI-29 — Workstation Category grouping orthogonal to Area/Line — ✅ Resolved (2026-05-01)

**Priority:** LOW
**Owner:** MPP Operations / Blue Ridge
**FDS §:** 2 (Physical Plant)
**References:** Screenshot review 2026-04-22 (image 22, Category configuration with Casting / Tumbling / 5A2 Line 1 / Sort / Shipping / Astemo / etc. two-level grouping independent of Area / Line)

**Description:** Legacy MES groups workstations by Category + Sub-category independently of the Area / Line / Cell physical hierarchy. Examples: "Sort", "Shipping", "Tumbling" appear as Categories alongside line-specific entries like "5A2 Line 1". Appears to be a UI navigation convenience.

**Proposed direction:** Confirm MPP operators rely on this grouping for floor navigation. Our Area / Line / Cell ISA-95 hierarchy should cover it — if not, add a `WorkstationCategory` attribute via `LocationAttribute`. Discovery only.

**Decision (2026-05-01):** Closed — legacy configuration ignored, covered by the ISA-95 model. Our Area / Line / Cell / Terminal hierarchy provides the operator floor-navigation grouping without a separate `WorkstationCategory` LocationAttribute.

---

### OI-30 — "Reports" tile contents enumeration — ✅ Resolved (2026-05-01)

**Priority:** MEDIUM
**Owner:** MPP Production Control / Blue Ridge
**FDS §:** 12 (Reporting) + UJ-19
**References:** Screenshot review 2026-04-22 (image 1, top-level "Reports" tile — contents not captured); UJ-19 (Productivity DB replacement)

**Description:** Legacy home page has a Reports tile. UJ-19 flags the four Productivity DB reports as a known requirement but the full Reports menu has not been enumerated — there may be additional reports MPP considers baseline.

**Proposed direction:** Walk through the legacy Reports tile with MPP and list every report, then match against our MVP reporting scope. Couples directly to UJ-19 closure.

**Decision (2026-05-01):** Closed. The legacy Reports-tile contents are not reproduced as a 1:1 mirror. **The four named Productivity DB reports (UJ-19) ARE in MVP scope** and will be delivered as MES reports as part of this project. Any reports BEYOND those four — additional Ignition reports MPP may want — are scoped as a post-deployment change order or follow-on project, not in this engagement.

**Boundary with UJ-19:** UJ-19 delivers the four named PD reports (MVP, in scope). OI-30 closure scopes everything else (post-deployment change order). When MPP names the four reports, UJ-19 closes; the Reports tile shipped in MVP carries those four entries.

---

### OI-31 — Identifier sequence table + format carry-forward — ✅ Resolved (2026-05-01)

**Priority:** MEDIUM
**Owner:** MPP IT / Blue Ridge
**FDS §:** New § (Identifier Sequences) + §1.4 interfaces
**References:** Arc 2 model revisions spec (`docs/superpowers/specs/2026-04-23-arc2-model-revisions.md` §3); Flexware `IdentifierFormat` table (sampled values `MESL{0:D7}`=1,710,932 for Lot and `MESI{0:D7}`=2,492 for SerializedItem); FRS 3.9.6 (LTT barcode format)

**Description:** Flexware `IdentifierFormat` drives two counters critical to cutover continuity: the Lot LTT barcode (`MESL{0:D7}`) and the serialized-item ID (`MESI{0:D7}`). Both are **MPP-internal identifiers** (not Honda AIM shipper IDs — those come from `AIM.GetNextNumber`). Our current design has no equivalent table; identifiers have been treated as ad-hoc.

**Schema (Arc 2 Phase 1 migration, Data Model v1.9):**

```sql
CREATE TABLE Lots.IdentifierSequence (
    Id                   BIGINT       NOT NULL IDENTITY(1,1) PRIMARY KEY,
    Code                 NVARCHAR(30) NOT NULL,
    Name                 NVARCHAR(100) NOT NULL,
    Description          NVARCHAR(500) NULL,
    FormatString         NVARCHAR(50) NOT NULL,    -- .NET string.Format, e.g., 'MESL{0:D7}'
    StartingValue        BIGINT       NOT NULL DEFAULT 1,
    EndingValue          BIGINT       NOT NULL DEFAULT 9999999,
    LastValue            BIGINT       NOT NULL DEFAULT 0,
    ResetIntervalMinutes INT          NULL,        -- unused at MPP today; nullable for future
    LastResetAt          DATETIME2(3) NULL,
    UpdatedAt            DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_IdentifierSequence_Code UNIQUE (Code)
);
```

Companion proc `Lots.IdentifierSequence_Next @Code` atomically increments `LastValue`, formats the result using the `.NET`-style format string, and raises a business-rule error if `EndingValue` would be breached.

**Cutover seeding:** Migration script fetches Flexware `LastCounterValue` on cutover day and seeds at or above those values to avoid LTT collisions with in-circulation LOTs. Sampled baseline values (subject to drift): `Lot=1,710,932`, `SerializedItem=2,492`.

**Open questions for MPP (Phase 0):**
1. **Format continuity** — keep `MESL{0:D7}` / `MESI{0:D7}`, or mint new prefixes in the replacement MES? (Default: keep.)
2. **Reset policy** — currently none in Flexware; any line-specific or shift-specific counter-reset rules MPP wants honored going forward?
3. **Rollover policy at 9,999,999** — at current burn rate, Lots hit rollover in ~30+ years. Planned for, or do we want a warning/error mechanism earlier?

**Counter inventory:** The Flexware `IdentifierFormat` export Jacques provided (2026-04-23) contains exactly two rows — `Lot` (`MESL{0:D7}`, `LastCounterValue=1,710,932`) and `SerializedItem` (`MESI{0:D7}`, `LastCounterValue=2,492`). No other live counters. Any FK references to `IdentifierFormat` from other Flexware tables (WorkOrder, ProductionOrder, etc.) are schema placeholders with no populated format rows.

**Proposed direction:** Implement schema as shown in Arc 2 Phase 1. Phase 0 resolves the three open questions above before cutover-day seeding. `Lots.IdentifierSequence_Next` replaces ad-hoc identifier generation for LOT and SerializedItem minting; no additional counters needed.

**Decision (2026-05-01):** Proposed direction confirmed by Jacques with one new business rule on cutover-day seeding: **start the new MES counter at +10,000 above the current Flexware `LastCounterValue`** (or an MPP-agreed delta) to avoid LTT collisions during any partial-cutover window where both systems mint LOTs in parallel. This subsumes the original "seed at or above Flexware values" guidance with a concrete buffer.

The three open questions also resolve:
1. **Format continuity:** keep `MESL{0:D7}` / `MESI{0:D7}` (Jacques default).
2. **Reset policy:** none — no line / shift / time-based counter resets.
3. **Rollover policy:** ~30+ year horizon at current burn rate; warning mechanism is a future concern, not MVP.

Rollout shape (single-line vs full-cutover vs shadow) still couples to Ben's deployment-shape decision (memo `Meeting_Notes/2026-04-24_OI-31_Single-Line_Deployment_Impact.md`); the +10K seed-offset rule applies regardless of which rollout shape Ben picks.

**Integration queued:**
- **Data Model** — add the +10K seeding rule to the `Lots.IdentifierSequence` table description as a deployment-time note.
- **FDS §16** — FDS-16-003 amended to bake in the `+10,000` cutover offset rule explicitly. "Open items (OI-31)" paragraph absorbed into design fact.
- **Phase 1 migration** (`0014_arc2_phase1_shop_floor_foundation.sql`) — seed both rows at `<Flexware-current> + 10000` (or final MPP-agreed delta captured before cutover).

---

### OI-32 — Material Allocation operator screen — ⬜ Open (new, 2026-04-24)

**Priority:** MEDIUM
**Owner:** Blue Ridge / Ben
**FDS §:** 5.11 or §6.6a (new section — Allocate Material workflow)
**References:** Legacy Storyboards PDF screen-map family (`MaterialAllocationMenuView` / `MaterialAllocationView` / `MaterialAllocationCreateView` / `MaterialAllocationUpdateView` / `BomComponentDetailsView`); `reference/Flexware_MES_DashboardConfiguration.png` (`Workstation.MaterialAllocationRequired BIT`); Review report §4 Gap 1 at `reference/NewInput/REVIEW_2026-04-24.md`; couples to UJ-09 (material verification at assembly) and OI-18 (ItemLocation consumption metadata)

**Description:** Flexware has a dedicated pre-production **Material Allocation** capability separate from scan-time material verification. An operator (or changeover technician) pre-allocates N baskets of a BOM component to a specific Cell; the allocation shows up on a grid at the workstation; the PLC handshake consumes **against** the allocation rather than against raw LOT scans. Flexware `Workstation.MaterialAllocationRequired BIT` gates whether this is mandatory per terminal.

Our current design has the **data** for allocation via OI-18 (`Parts.ItemLocation.MinQuantity` / `MaxQuantity` / `DefaultQuantity` / `IsConsumptionPoint`) but **no explicit operator screen** and no `Workorder.MaterialAllocation` lifecycle table. FDS-06-011 covers verify-on-scan but not pre-allocate.

**Options considered:**
- (a) Build `Workorder.MaterialAllocation` table (Cell, Item, AllocatedQuantity, ConsumedQuantity, AppUserId, AllocatedAt, ReleasedAt) + Perspective Allocate Material screen + consumption gate in `ConsumptionEvent_Record`.
- (b) Confirm MPP doesn't use the step and close as "intentionally not reproduced."
- (c) Allocate implicitly on first scan (current FDS posture) but expose a read-only "current allocations at this cell" grid on the Assembly view for operator awareness.

**Proposed direction:** Phase 0 question to Ben: *"Do operators pre-allocate baskets of material to Assembly / Machining cells before production begins, or is allocation implicit in the first LTT scan?"* If yes → Option (a), gates Phase 6 Assembly design. If no → Option (b) or (c) documented and closed.

**Impact if unresolved:** Arc 2 Plan Phase 6 (Assembly + MIP + Container) cannot finalize design.

**Clarification exchange (2026-04-24):**

**Jacques's pushback:** *"Parts are 'checked into' Line side storage that can then be consumed by the station or Cell. The line side storage is a typedefinition of Cell. I clearly don't understand the tension with consumption here. Please elucidate."*

**Response (Blue Ridge, 2026-04-24):** The tension I flagged does not exist in our model — your framing is right. In Flexware, `MaterialAllocation` is a separate pre-production workflow step where an operator (or changeover tech) declares "these N baskets are allocated to this cell" as a dedicated action *before* the PLC handshake runs. The allocation exists as a DB row (`MaterialAllocationView` / `MaterialAllocationCreateView`) even though the baskets are just physically staged. It is a workflow artifact of Flexware's data model, not a real-world step.

Under our design:
- **Lineside storage IS a `LocationTypeDefinition` under Cell** — per your 2026-04-24 note.
- An operator "checks in" a LOT to that lineside Cell via a normal `LotMovement` event (the scan-in you describe).
- When the production Cell consumes from the lineside LOT, our `ConsumptionEvent` captures it with full genealogy.
- The operator's "what's at my lineside" grid is answered by a simple read query (`Lots.Lot_ListByLocation @LocationId = <lineside cell id>`), not a separate allocation table.
- The Flexware `Workstation.MaterialAllocationRequired BIT` is satisfied in our model by the act of scanning the LOT into the lineside Cell — the movement itself IS the allocation.

**Revised resolution:** Close OI-32 as **not-reproduced** on the same grounds as OI-32b. No new `Workorder.MaterialAllocation` table needed. No separate Allocate-Material Perspective screen needed. The Flexware concept collapses cleanly into our existing LOT-at-location + ConsumptionEvent model.

**Decision pending:** Jacques to confirm the revised "close as not-reproduced" framing before flipping the status tag. Status stays ⬜ Open until explicit confirmation.

**Integration queued (once closed):**
- **Review report** (`reference/NewInput/REVIEW_2026-04-24.md` §4 Gap 1) — add strike-through + closure note.
- No data model / FDS additions required.

---

### OI-32b — Material Classes — ✅ Resolved / Closed (2026-04-24)

**Priority:** LOW
**Owner:** MPP Engineering / Blue Ridge
**FDS §:** 3 (Master Data) — addendum if retained
**References:** Legacy Storyboards PDF Configuration Menu; `reference/Flexware_MES_ContainerTracking.png` (`Material.MaterialClassID` FK); Review report §4 Gap 2 at `reference/NewInput/REVIEW_2026-04-24.md`

**Description:** Flexware has a `Material` → `MaterialClassID` FK driving a "Material Classes" tile in Configuration. Our data model has `Parts.ItemType` (Cast / Machined / Assembled / Received) which is coarser. `MaterialClass` in Flexware could hold Honda-customer-specific categorisation or finer ItemType granularity — purpose unclear from the 2012 storyboards.

**Options:**
- (a) If Honda-customer groupings → add `Parts.Item.CustomerCode NVARCHAR(50) NULL`.
- (b) If finer ItemType slice → add `Parts.ItemSubType` code table + FK.
- (c) Legacy residue — document the deliberate omission and close.

**Proposed direction:** Phase 0 discovery-only question to MPP Engineering. Low-effort phone call. Resolution drives a small schema delta at most.

**Decision (2026-04-24):** Closed by Jacques — "Don't worry about the language difference, our `Parts.ItemType` will suffice." No `MaterialClass` table. No `Parts.Item.CustomerCode` column. `Parts.ItemType` (Cast / Machined / Assembled / Received / …) is the authoritative grouping.

**Integration queued:** Review report (`reference/NewInput/REVIEW_2026-04-24.md` §4 Gap 2) — add strike-through + closure note. No data model or FDS changes.

---

### OI-33 — AIM Shipper ID pool empty-pool hard-fail behavior — ⬜ Open (new, 2026-04-28)

**Priority:** HIGH
**Owner:** MPP Operations / IT
**FDS §:** 7.4 (FDS-07-010a)
**References:** UJ-04 (✅ Resolved 2026-04-27 — pool design locked, OIR v2.12); FDS-07-005 (Container_Complete atomic close); FDS-07-010 (pool topup); FDS-07-010a (empty-pool behavior); `Lots.AimShipperIdPool` + `Lots.AimPoolConfig` (Data Model v1.9h)

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

**What's needed to decide:** Phase 0 customer-validation answer from MPP Operations + IT: *"On AIM pool empty at container close time, do you want hard-fail (line stops; current design) or do you want a soft-fallback / pre-emptive halt? Acknowledge that hard-fail prioritizes traceability integrity over availability."*

**Impact if unresolved:** No design change required to keep building toward MVP — the FDS-07-010a hard-fail posture is the implemented behavior. This is a customer-acceptance question, not a build-gating question. Resolution either (i) confirms the current design (no work) or (ii) triggers a redesign of `Container_Complete` + reconciliation Gateway scripts + label-reprint flow (significant scope addition).

---

### OI-34 — Production schedule leverage beyond shift-window timing — ⬜ Open (new, 2026-04-28)

**Priority:** MEDIUM
**Owner:** MPP Production Control
**FDS §:** 9.4 (FDS-09-008 / FDS-09-012)
**References:** FDS-09-008 (Shift instance creation from authored schedule); FDS-09-012 (event-derived availability math against shift windows); UJ-19 (Productivity DB replacement — couples here); OI-30 (Reports tile contents — couples here)

**Description:** Our current design imports MPP's authored production schedules and uses them for two purposes: (1) creating `Oee.Shift` instance rows with the right start / end timestamps so OEE math has shift windows to bucket events into (FDS-09-008), and (2) deriving availability against those shift windows from the operator-driven event stream (FDS-09-012). The FDS continuity pass on 2026-04-28 surfaced that this is a **minimal use** of authored-schedule data — MPP may want the MES to leverage the schedules more substantively. The unanswered question recorded in the FDS embedded register: *"How would MPP like to leverage the provided production schedules in the MES?"*

**Possible additional uses (not yet scoped):**
- **Per-shift target quotas** — schedule carries a target quantity per Item per shift; the MES displays attainment vs. target on the workstation banner, the supervisor dashboard, and the shift-end summary screen (FDS-09-015). Schema impact: add `TargetQuantity INT NULL` and `ItemId BIGINT NULL FK` to `Oee.Shift` (or a new `Oee.ShiftPlan` child table if multiple Items per shift are common).
- **Line scheduling drift detection** — compare actual shift-instance run time and actual quantity against the authored schedule; surface drift > X% as a supervisor alert. Schema impact: same as above + drift-threshold LocationAttribute on Line / WorkCenter.
- **Throughput / forecast planning** — feed the MES's actual availability + performance numbers back to MPP Production Control as an input to their next planning cycle. Likely a Reports tile item, couples to OI-30.
- **Tool / Cell scheduling** — authored schedule includes which Tool runs on which Cell at which time; the MES warns on Tool / Cell mismatch at Lot creation. Schema impact: link `Oee.ShiftPlan` to `Tools.Tool` and `Location.Location` (Cell). Note: this is FUTURE territory — current design has Tool assignment authoritative on `Tools.ToolAssignment`, not on a schedule.
- **None — stop at the current minimal use** — authored schedules drive shift-window timing only; everything else stays operator-driven.

**Why this is open:** MPP gave us authored schedules to consume but did not explicitly tell us *which* of the above (or others not listed) they want the MES to use. We made a reasonable starting choice (shift-window timing only — the smallest defensible scope) and parked the rest. This is a discovery question, not a design defect.

**Couples to:**
- **UJ-19** — Productivity DB replacement. The four PD reports MPP names may include schedule-attainment reports (per-shift target quotas) — answers to UJ-19 may resolve OI-34 directly.
- **OI-30** — Reports tile enumeration. Schedule-derived reports are likely candidates for the Reports tile.
- **FDS-09-015** — Shift-end summary screen (UJ-10 closed). Adding target attainment lines to that screen is the natural surface area if Per-shift target quotas is in scope.

**What's needed to decide:** Phase 0 walkthrough question to MPP Production Control: *"Beyond using your authored schedules for shift-window timing, what else should the MES do with them? Examples: per-shift target quotas displayed at the workstation, drift detection alerts, schedule-attainment reports, etc. Or is the current minimal use sufficient?"* Couples best with the OI-30 + UJ-19 walkthrough — same SME, overlapping scope.

**Impact if unresolved:** No design change required to keep building toward MVP — the current FDS-09-008 / FDS-09-012 minimal use is implemented. This is a scope-expansion question. Resolution either (i) confirms the current scope (no work) or (ii) triggers a Phase 9 (Oee) revisit + possible schema additions to `Oee.Shift` / new `Oee.ShiftPlan` child + Reports tile entries + workstation banner additions.

---

### OI-35 — Long-horizon scaling, retention, and archiving strategy — ✅ RESOLVED (2026-06-08, Blue Ridge architecture review)

**Resolution (2026-06-08, Phase 0 Track B — `Meeting_Notes/2026-06-08_Phase0_Decision_Log.md`):** Architecture gate **CLEARED — Arc-2 Phase-1 SQL unblocked.** Decisions baked into migration `0020_arc2_phase1_shop_floor_foundation.sql` (design spec `docs/superpowers/specs/2026-06-09-arc2-phase1-sql-foundation-design.md`; Data Model § "Scaling Decisions"): **B2** monthly `RANGE RIGHT` partitioning + **`TRUNCATE`-based sliding-window** (CREATE; singleton `Id` PK preserved — TRUNCATE imposes no aligned-index requirement); **B3** columnstore deferred (partition-compatible, not built); **B4** `LotGenealogyClosure` table (CREATE); **B5** materialized `TotalInProcess`/`InventoryAvailable` + `v_LotDerivedQuantities` fallback view (CREATE); **B6** row-locked `IdentifierSequence_Next` (NOT SQL `SEQUENCE`), seed ≈3,000,000, MESL/MESI retained (CREATE); **B7** `OperationLog`→7-yr + 20-yr `Lots.LotEventLog` split (CREATE); **B8** known filtered indexes (CREATE); **B1** per-table retention → FDS §11 (20-yr Honda / 7-yr general, MPP IT confirms). **Track A (customer validation):** gate posture = build on assumed-defaults, MPP confirms in parallel; only S-08 a true blocker. A4 ShotCount = **cumulative** (locked). A1 seed ≈3M / keep MESL/MESI (Ben → exact seeds + rollout shape). A2/A5/A6/A7 adopt-default, MPP confirms. A8 (OI-32) close-as-not-reproduced (Ben). A9 (OI-33) hard-fail posture confirmed.

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
| `Workorder.ProductionEventValue` (EAV child of ProductionEvent) | **150–600M** (events × non-promoted data-collection fields) |
| `Quality.QualityResult` (EAV child of QualitySample) | 20–50M (samples × attrs-per-spec; sampling-rate dependent) |
| `Audit.OperationLog` | **300M–1B** |
| `Audit.InterfaceLog` | **300–600M** |

> **EAV children (added 2026-06-08 EAV-at-scale review):** `Workorder.ProductionEventValue` and `Quality.QualityResult` are Entity-Attribute-Value child tables that grow as a *multiple* of their already-high-volume parents. They were absent from the original row-estimate table and the 2026-04-28 indexing-review gap table — they must be treated like the event tables they hang off: monthly range-partitioned + retention-classed + columnstore-aged, partition-aligned with their parent (`ProductionEventValue` co-located with `ProductionEvent`, `QualityResult` with `QualitySample`). Both are structurally sound (each already carries / now carries a `NumericValue DECIMAL` shadow column for indexable numeric queries) — the gap was *planning*, not schema.

The audit + interface tables are structurally larger than the entire traceability dataset. A 20-year blanket retention policy without architectural mitigations is not tractable on a single SQL Server 2022 instance — query plans against unpartitioned 1B-row tables degrade beyond useful thresholds, recursive `LotGenealogy` walks for Honda audits hit timeouts, and OLTP buffer pool gets crowded out by historical data scans.

**Why this is a "must decide before Arc 2 Phase 1 SQL" gate:** Several of the architectural mitigations — partition functions, materialization columns, closure-table presence — must be in the **CREATE migration** for the affected tables. Adding a partition scheme to a populated 100M-row table is operationally expensive (rebuild, log-volume blow-up, downtime window). Adding a materialized closure table after 5 years of LOT genealogy means backfilling 50M+ ancestor pairs from a recursive walk. The schema-shape decisions made in Arc 2 Phase 1 set the ceiling on what's possible without painful migration later.

**Decision space (the conversation Jacques + Blue Ridge defer to last responsible moment):**

1. **Per-table retention class.** Negotiate which tables genuinely need 20 years vs which can carry 7-year retention. Push-back candidates: `Audit.OperationLog`, `Audit.FailureLog`, `Audit.InterfaceLog`, `Oee.DowntimeEvent`, `Audit.ConfigLog`. Honda traceability data (`Lots.*` events, `ContainerSerial`, `ShippingLabel`, `LotGenealogy`) almost certainly stays at 20 years.
2. **Partitioning scheme.** Native SQL Server 2022 range partitioning, monthly partitions, sliding-window automation. Applies to ~14 deferred high-volume event tables **plus the two runtime-EAV child tables** (`Workorder.ProductionEventValue`, `Quality.QualityResult`) — partition-aligned with their parents so a parent + its children age and roll off together. Partition column is `CreatedAt` / `EventAt` / `LoggedAt` per table (already non-null on every event table by design — clean partition keys throughout; the EAV children carry `CreatedAt`).
3. **Columnstore on aged partitions.** Convert partitions older than 90 days from rowstore to clustered columnstore. Typical 8–15× compression on event-shape data because `LotId` / `LocationId` / `AppUserId` columns repeat heavily.
4. **`Lots.LotGenealogy` materialized closure table.** Pre-compute every ancestor-descendant pair at LOT creation time (`AncestorLotId`, `DescendantLotId`, `Depth`). Honda audit query becomes O(1) lookup vs O(depth) recursion against partitioned tables. Cost: extra INSERTs at LOT creation (~4 rows per LOT in MPP's flow). Trade ~20% slower OLTP writes for "Honda audits actually return."
5. **Materialize `TotalInProcess` / `InventoryAvailable` columns onto `Lots.Lot`.** OI-23 chose the view-based path (`Lots.v_LotDerivedQuantities`); at scale the view aggregates over 200M+ event rows per query. The deferred-decision criteria from OI-23 are now imminent — if we materialize, do it in the same `Lot_Create` / event-write procs that already touch the Lot row. The view stays as a fallback for diagnostics.
6. **`Lots.IdentifierSequence_Next` locking model.** Single-row hot table updated on every LOT creation. ~150K LOTs/year, ~500/day in bursts → row-level update lock contention. Two paths: (a) explicit `WITH (ROWLOCK, UPDLOCK)` with serializable transaction (current implicit pattern); (b) replace with SQL Server `SEQUENCE` object — eliminates the row, native concurrency, format string applied via wrapping function. `SEQUENCE` doesn't support our `EndingValue` rollover semantics out of the box, but rollover is a 30+ year horizon problem.
7. **Split `Audit.OperationLog`.** Today every mutating proc across every schema writes here. Keep `OperationLog` for general 7-year audit, add a separate `Lots.LotEventLog` or similar for traceability-relevant subset (LOT events, container close events, ShippingLabel mints) at full 20-year retention. Cuts the largest table in the system in half.
8. **Filtered indexes on hot subsets.** Lower-stakes per-table decision but should be made systematically: every "active subset" query (`WHERE LotStatusCodeId IN (active codes)`, `WHERE ResumedAt IS NULL`, `WHERE ConsumedAt IS NULL`, `WHERE PrintFailedAt IS NOT NULL AND BannerAcknowledgedAt IS NULL`) gets a filtered index that is 0.1–1% the size of the full table.

**Options on overall posture (the meta-question Jacques is deferring):**

- **(a) Defer to last responsible moment, build Arc 2 Phase 1 SQL with stub schemas.** Risk: at decision time we discover the partition / closure / materialization choices require restructuring tables we've already populated in dev. Re-runnable migrations help but don't fully insulate. **This is the current direction.**
- **(b) Make partial / conservative decisions now (partition + filtered indexes only) and defer the higher-cost items (closure table, OperationLog split).** Lower risk, but partial commits constrain later moves.
- **(c) Hold Arc 2 Phase 1 SQL until the full strategy is decided.** Highest correctness, highest schedule cost.

**Recommended direction:** **Option (a) with explicit gating.** Defer the architectural decisions, but Arc 2 Phase 1 SQL build does not commence until OI-35 is resolved. Phase 0 facilitation workshop adds OI-35 as a topic alongside the existing 8 gating items. Resolution may be a single architectural design review session between Blue Ridge architecture and MPP IT — does not require full Phase 0 customer walkthrough.

**What's needed to decide:**

1. Negotiation with MPP IT on per-table retention policy — for the audit / interface log tables specifically. Single-meeting deliverable; does not gate other decisions.
2. Internal Blue Ridge architecture review covering decisions 2–7 above. Output: data model spec § "Scaling Decisions" pinning partition columns, materialization columns, closure-table schema, and `IdentifierSequence_Next` locking choice. Drives Arc 2 Phase 1 migration content.
3. Optional load test against synthetic 20-year data volumes to validate the chosen approach before production cutover. Higher-confidence-but-deferable.

**Impact if unresolved:** **Arc 2 Phase 1 SQL build cannot commence.** All other Arc 2 work (frontend / Perspective screens / Configuration Tool extensions) remains unblocked.

**Coupled items:**

- **OI-23 (Resolved)** — chose view; OI-35 may flip to materialized columns. Not a re-open; OI-23's choice was correct for MVP, OI-35 supersedes it for production scale.
- **Indexing pass on Arc 2 deferred tables** — already-queued separate follow-up. Lands as data model bump v1.9k or v1.10. OI-35 sets the **retention / partitioning / materialization** layer; the indexing pass sets the **per-table index list** layer. Both feed the Arc 2 Phase 1 migration; both must land before SQL writes.
- **FDS-11 audit retention paragraph** — currently silent on the per-table retention class. OI-35 resolution drives an FDS-11 amendment.

**Last-responsible-moment posture confirmed by Jacques 2026-04-29.** The decision is deferred but the gate is hard.

---

# Part B — User Journey Assumptions & Decisions

These are the 19 assumptions from `MPP_MES_USER_JOURNEYS.md`. Each gates one or more Perspective screens. Cross-references to Part A items are noted per entry.

---

### UJ-01 — Operator identity & elevation model — ✅ Resolved (2026-04-21)

**Priority:** HIGH
**Blocks:** Every screen
**Maps to:** OI-06
**References:** FDS-04-001 through FDS-04-010; FRS 3.3.1, 3.3.4, 3.6.1; FRS 5.3; Spark Dep. B.8

**Decision:** See OI-06. Initials-based operator presence; per-action AD elevation.

---

### UJ-02 — LOT creation flow at Die Cast — ✅ Resolved (2026-04-24)

**Priority:** MEDIUM
**Blocks:** Die Cast LOT creation screen
**Maps to:** (own item)
**References:** FDS-05-001, FDS-05-002; FRS 3.9.6, 2.2.1, 2.2.2

**Decision:** LTT tags are pre-printed; first scan of a barcode creates the LOT record. No pre-registration, no tag inventory feature. Confirms FDS-05-002. Pending MPP validation.

**Decision (2026-04-24):** Confirmed to close by Jacques. FDS-05-002 + FDS-05-036 (lazy operator-driven creation, v0.11) are authoritative.

---

### UJ-03 — Sub-LOT split trigger — ✅ Resolved (2026-05-01)

**Priority:** MEDIUM
**Blocks:** Machining OUT screen
**Maps to:** (interacts with OI-09 sublot addenda)
**References:** FDS-05-008 through FDS-05-011; FRS 3.9.12, 2.1.4, 2.2.5

**Description:** When a LOT arrives at Machining IN, the sublot pattern (FDS-05-022) lets the operator split the parent into N machining sublots that fill independently from there. The open question is the **trigger** — does the system auto-prompt the split on every arrival, or wait for the operator to explicitly initiate one when they decide they need it?

**Options:**

| Option | Behavior | Impact |
|---|---|---|
| **A — Auto-prompt 50/50** (current proposed direction) | Every Machining IN scan opens a split confirmation dialog with an editable 50/50 default. Operator confirms, adjusts, or cancels. | Simplest if most parts split. Adds friction for parts that never do. Aligns with FDS-05-009 auto-split workflow as written. |
| **B — Operator-triggered only** | No auto-prompt. Operator selects "Split" from a menu when needed. | Cleaner UX for parts that don't split. Risk of forgetting to split. |
| **C — Per-Item conditional** | `Parts.Item` carries a `MachiningAutoSplit BIT` flag. Per-Item determines whether the dialog auto-opens. | Most flexible but introduces a new per-Item config field — adds engineering setup burden. |

**Recommended direction:** A initially (already coded into FDS-05-009). Evolve to C if Ben's feedback shows certain parts never split.

**What's needed to decide:** Ben's input on which Machining workflows split vs run through whole. Specifically: does every part that hits Machining IN get split, or only some? If only some, by what rule?

**Decision (existing):** Auto-split on arrival at machining, defaulting to 50/50, with operator override. Sublots treated via `Lots.LotGenealogy` (relationship = Split). Needs review with Ben, and reconciliation with the sublot pattern now in OI-09 addenda.

**Decision (2026-05-01):** Per-Operation flag confirmed — `Parts.OperationTemplate.RequiresSubLotSplit BIT` (Data Model v1.9m) is the implemented mechanism. The Trim OUT screen toggles between a **single-destination panel** (flag OFF, parent moves whole) and an **N-destination Sub-LOT Distribution panel with `+ Add sub-LOT` button** (flag ON, parent splits into N children routed to N machining cells). Mockup verified: `mockup/plantFloor.html` `terminal/trim` (and `terminal/trim-out`) with the `RequiresSubLotSplit` toggle. The Configuration Tool surfaces this as a **"may split for machining"** toggle on the per-Operation row of the Item edit screen — operators / engineers configure it once per Operation per Item, not per LOT at run time.

**Trigger location** is **Trim OUT** (split happens when LOT exits Trim, sub-LOTs route into Machining FIFO already split), not Machining IN — matches the 2026-04-29 design decision.

**Decision (2026-06-08, Phase 0 T008) — split-quantity entry + trigger location updated:** **No auto even-split default.** The operator enters **all** split quantities manually at the split screen; the system does not pre-fill a 50/50 (or any) even division. This **supersedes the Option-A "auto-prompt 50/50 default"** language above. Separately, per FDS v1.3 / Phased Plan v1.1 the split **trigger moved from Trim OUT to Machining OUT** (Trim is now a 1:1 whole-LOT move at Area resolution); the `RequiresSubLotSplit` per-Operation mechanism is unchanged. Action: remove the 50/50 even-split-default wording from FDS §5/§6 sub-LOT-split prose at the next FDS pass.

**Per-Operation vs per-Item placement (locked):** the flag stays on `Parts.OperationTemplate` (per-Op-per-Item) rather than directly on `Parts.Item`. Per-Operation gives more flexibility — the same Item could split at one Operation but not another in some future workflow — without losing the simpler day-to-day UX (Item edit screen surfaces a single "may split" toggle on the relevant Operation row).

**Integration queued:**
- **Configuration Tool** — Item edit screen surfaces "may split for machining" toggle on the per-Operation row. Backend storage is the existing `Parts.OperationTemplate.RequiresSubLotSplit` column — no schema change.
- **FDS §5** — already references the flag (FDS-05-009 / -011); confirm UI-labeling alignment in next FDS pass.
- **No SQL change.**

---

### UJ-04 — Container lifecycle + AIM Shipper ID pool — ✅ Resolved (2026-04-27, design locked)

**Priority:** HIGH
**Blocks:** Assembly / Shipping screens
**Maps to:** OI-02
**References:** FDS-07-005, FDS-07-008, FDS-07-010 (rewritten), FDS-07-010a/b/c (NEW); FRS 3.6.6, 3.9.7

**Decision (2026-04-09):** Auto-create container on LOT arrival; AIM shipper ID requested at the last route step for the part prior to LOT closure.

**Decision (2026-04-24) — addition from Jacques (superseded):** "Queue AIM requests asynchronously so production isn't held up by integration latency." Closed UJ-04 to ✅ Resolved with the queue-pattern integration item.

**Decision (2026-04-27) — design locked (Claude + Jacques discussion):** the queue-pattern path was reconsidered and rejected. Even with an async queue, container close briefly transits a pending-ShipperID state before the queue drain back-fills the ID — and pending-state containers can't ship until they get an ID. The cleaner pattern is a **pre-fetched local pool**: AIM Shipper IDs are fetched ahead of time by a background script and consumed FIFO at container close. Container close becomes synchronous and zero-latency.

**Six locked answers (the questions Jacques resolved):**

**Q1 — Empty-pool behavior?** **Hard fail.** If the pool is empty when `Container_Complete` runs, `Lots.AimShipperIdPool_Claim` raises and the close transaction rolls back. The operator sees a clear error; the line is blocked from completing further containers until the pool refills. No soft-fallback "complete with NULL ID" path. Rationale: trucks can't ship without valid AIM IDs, so allowing further closes against an empty pool would just create a pile of un-shippable containers and obscure the actual integration outage.

**Q2 — Per-line scope?** **All Assembly Lines have dedicated terminals.** AIM Shipper IDs attach to **Containers only**, never to sub-assemblies, sub-LOTs, or any other entity. Other Container-completion paths (Die Cast, Trim, intermediate Machining containers if they exist) do not consume AIM IDs.

**Q3 — Buffer sizing.** **Configurable via Configuration Tool.** Single-row `Lots.AimPoolConfig` table with four operator-tunable thresholds (Admin-elevated). Defaults: `TargetBufferDepth = 50`, `TopupThreshold = 30`, `AlarmWarningDepth = 20`, `AlarmCriticalDepth = 10`. CHECK constraint enforces strict ordering (`Critical < Warning < Topup < Target`). Tunable post-deployment based on observed throughput and AIM responsiveness.

**Q4 — AIM ID expiration.** **None.** Honda does not expire AIM Shipper IDs — pool rows can sit indefinitely without staleness. No `ExpiresAt` column on `AimShipperIdPool`; no expiration sweep.

**Q5 — Voided container ID lifecycle.** **Permanent consumption — no reuse.** Once `AimShipperIdPool.ConsumedAt` is set, the row is terminal. Voided / re-packed containers do not return their original ID to the pool — Honda treats every issued ID as consumed regardless. The re-packed container draws a fresh ID from the pool via FDS-07-005's synchronous `_Claim`. FDS-07-008 amended explicitly with this rule.

**Q6 — Failed-topup escalation.** **Two-tier — supervisor alarm + IT notification.** Wallboard tile turns yellow at `AvailableCount < AlarmWarningDepth` (default 20). Supervisor alarm + IT notification fires at `AvailableCount < AlarmCriticalDepth` (default 10), with severity upgraded to "POOL EXHAUSTED — line stops imminent" if depth hits zero. Notifications carry `AvailableCount`, `OldestAvailableAt`, and the most recent `Audit.InterfaceLog` AIM-failure entry. Recovery clears alarms automatically.

**Other locked decisions:**
- **Schema home:** `Lots.AimShipperIdPool` + `Lots.AimPoolConfig`. Container is in Lots; pool follows.
- **Concurrency:** `UPDATE TOP (1) WITH (UPDLOCK, READPAST, ROWLOCK) ... OUTPUT inserted.AimShipperId ORDER BY FetchedAt`. `READPAST` lets concurrent claims skip in-flight locks instead of blocking — two simultaneous closes return two distinct IDs.
- **Provenance:** `AimShipperIdPool.FetchedInterfaceLogId` FK → `Audit.InterfaceLog`. End-to-end traceability from a `Container.AimShipperId` back to the precise AIM `GetNextNumber` call that issued it.
- **Topup cadence:** Gateway timer ~30s. No backoff — the script just re-evaluates depth every cycle.
- **Container/Sub-assembly attribution:** AIM IDs ONLY at Container.

**Integration landed (this commit):**
- **Data Model v1.9h** — new `Lots.AimShipperIdPool` table (FetchedAt, FetchedInterfaceLogId, ConsumedAt/ByContainerId/ByUserId; CHECK pairing the consumed cols; filtered UNIQUE-style indexes for FIFO + traceability) + new single-row `Lots.AimPoolConfig` (four tunables with CHECK ordering, seeded 50/30/20/10).
- **FDS v0.11i** — FDS-07-005 rewritten (synchronous claim, no inline AIM call), FDS-07-008 amended (no ID reuse on void), FDS-07-010 rewritten (pool model + topup state machine), FDS-07-010a NEW (empty-pool hard fail), FDS-07-010b NEW (alarm thresholds + IT notification), FDS-07-010c NEW (Configuration Tool exposure).
- **ERD** — Lots tab adds `AimShipperIdPool` and `AimPoolConfig` cards + mermaid boxes + relationships to Container / AppUser / Audit.InterfaceLog.

**Integration queued (Arc 2 Phase 7):**
- Versioned migration creates both tables alongside `Lots.Container`. `Audit.LogEntityType` +2 rows.
- Repeatable procs: `Lots.AimShipperIdPool_Claim / _Topup / _GetDepth / _GetByContainer` + `Lots.AimPoolConfig_Get / _Update`.
- Test suite covering: FIFO claim ordering, concurrent-claim distinct-ID guarantee, empty-pool hard fail, no-reuse-on-void, config CHECK enforcement, topup INSERT, depth count.
- Gateway timer script (Phase 7) implements the topup loop + alarm evaluation.

---

### UJ-05 — Sort Cage serial number migration — ⬜ Open

**Priority:** MEDIUM
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

**What's needed to decide:** MPP Quality + Honda compliance affirmation that update-in-place satisfies traceability requirements (the typical Honda question is "show me every container this serial has ever been in" — answerable via `ContainerSerialHistory` join). Operational walk-through: confirm Sort Cage operators understand what re-sort does to the serial trail. Edge case: serial moves to a container, then that destination container is voided — what's the right next step? (Likely: another move event + container void event.)

**Decision (existing):** Highest traceability-loss risk of any sort scenario. Needs customer discussion. Schema supports update-in-place via `ContainerSerialHistory` but the business rule is undefined.

**Decision (2026-06-08, Phase 0 T008):** Build default **locked to Option A** — update-in-place + `Lots.ContainerSerialHistory` (one row per superseded serial: timestamp + reason + actor; no new container row minted; see Plant Floor plan Cross-Cutting **B10**). **Stays ⬜ Open** pending MPP Quality + Honda affirmation, but is **buildable now** — Phase 7 procs are structured so a void-and-recreate flip can swap in without a migration rebuild if MPP rejects update-in-place.

---

### UJ-06 — Off-site receiving — ✅ Resolved

**Priority:** LOW
**Blocks:** Off-site receiving app
**References:** No FRS coverage — MPP operational decision

**Decision (2026-04-09):** Online only, no concerns. Standard Perspective client via VPN. No offline mode needed.

---

### UJ-07 — Work order visibility and lifecycle — ✅ Resolved (2026-04-27, Option A)

**Priority:** HIGH
**Blocks:** Production tracking architecture
**Maps to:** OI-07 (corrected 2026-04-24 — single `Production` WO type)
**References:** FDS-06-022 through FDS-06-024; FRS 3.1.5, 3.10.1, 3.10.2, 3.10.5; Spark Dep. B.5

**Description:** When does a `Production` WO get auto-created, what does it span, and does it ever surface to the operator? OI-07's correction (2026-04-24) settled that there's only one active WO type (`Production`, MVP-LITE, invisible to operators). What remains open is the **trigger** and **span**.

**Options:**

| Option | Trigger | Span | Impact |
|---|---|---|---|
| **A — Per-LOT** (current proposed) | Auto-create at `Lot_Create` | One WO per LOT, covers the LOT's full route | Matches MVP-LITE. Simplest. WO is purely bookkeeping — never queried by operators. ProductionEvents reference `WorkOrderOperationId` for the route step they ran under. |
| **B — Per-route-run** | Auto-create at the start of a Cell-level Production run | One WO covers all LOTs of a part on a single route during one continuous run | Closer to ERP-style WO. Easier ERP integration. Harder to attribute individual LOTs to individual WOs (becomes 1:N). |
| **C — Per-operation** | Auto-create per LOT per RouteStep | One WO per (LOT, RouteStep) | Cardinality explosion. ProductionEvent already captures this granularity via `WorkOrderOperationId`. WO becomes redundant. |
| **D — ERP-derived** | Macola pushes WOs into MES on a queue | One WO per ERP work order | Tight ERP coupling. Adds an integration we don't currently need. Requires MPP IT engagement. |

**Recommended direction:** A. Already in design (FDS-06-022 / FDS-06-024). Operators never see WOs; they exist for ProductionEvent attribution and future Maintenance/Demand WO hooks (OI-07 corrected). If MPP later wants ERP-derived WOs, B or D can be added without breaking A — `Workorder.WorkOrder.WorkOrderTypeId` is a discriminator the future taxonomy slots into.

**What's needed to decide:** Ben's confirmation that operators truly do not need WO visibility (which OI-07 already implies but was originally pending UJ-07). Confirmation from MPP IT that Macola does not push or expect to receive `Production` WOs from the MES — if it does, A may need to coexist with D.

**Decision (2026-04-27 — closed by Jacques):** **Option A — Per-LOT WO.** WorkOrders do not need to be seen by operators. FDS-06-022 / FDS-06-024 already specify the Per-LOT auto-create + MVP-LITE invisibility. No FDS edit required. ERP-derived (D) deferred — not in scope. The `WorkOrderTypeId` discriminator stays as a future hook for Demand / Maintenance per OI-07.

**Decision (historical):** Pending Ben's input on WO triggers, span (per-operation vs. per-route), and optional ERP derivation path. Now coupled to the three-WO-type model from OI-07 revised.

---

### UJ-08 — LOT merge business rules — ✅ Resolved (2026-04-27, Option A)

**Priority:** HIGH
**Blocks:** LOT merge screen
**Maps to:** OI-05
**References:** FDS-05-012, FDS-05-025..030; FRS 3.9.13

**Description:** Two LOTs of the same part can sometimes be merged into one (combining piece counts). The rules for *when* this is allowed are partially defined in OI-05 (post-sort only, same part, die-rank compatibility). The remaining open question is **how the rules are encoded** (proc-enforced vs configurable) and **what happens at the supervisor-override edge case** (when rank matrix incomplete).

**Options:**

| Option | Encoding | Impact |
|---|---|---|
| **A — Hard-coded rules + supervisor override** (current direction) | Rules in `Lots.Lot_Merge` proc: same `ItemId`, post-sort only (FDS-05-025), `Tools.DieRankCompatibility` lookup or supervisor AD elevation (FDS-05-027), no `Hold` × `Good` mixing (FDS-05-026), piece counts additive. | Simplest. Enforcement at proc layer, not UX. Supervisor override per FDS-04-007 unblocks edge cases without code change. Awaits S-08 die rank matrix from MPP Quality. |
| **B — Per-Item configurable rules** | New `Parts.Item.MergeRules` JSON column or junction table. Each Item carries its own merge eligibility flags. | Maximum flexibility. Per-Item engineering setup burden. Most rules are universal (post-sort, same part), so per-Item granularity is overkill for them. |
| **C — Per-route configurable** | `RouteTemplate` row carries merge-eligible flag per RouteStep. | Couples merge to route. Awkward — merge is a LOT operation, not a route step. |

**Recommended direction:** A — already in design (OI-05 v0.9 FDS rewrite). Universal rules in proc; per-pair compatibility in `Tools.DieRankCompatibility`; supervisor override for edge cases. Empty-matrix behavior: cross-die merges reject with a clear message until matrix populated; supervisor override always works as the escape hatch.

**What's needed to decide:** S-08 die rank compatibility matrix from MPP Quality (now tracked in seeding registry — not a build blocker). Operator validation of supervisor-override workflow UX (Sort Cage scenario where supervisor approves the cross-die merge while operator waits at terminal). MPP Quality + supervisor walkthrough.

**Decision (2026-04-27 — closed by Jacques):** **Option A — hard-coded rules + supervisor override.** Already in design — FDS-05-025..030 carry the merge rule set; supervisor AD elevation per FDS-04-007 is the override path. No FDS edit required. Awaits S-08 die rank compatibility matrix (seeding registry, not a build blocker).

**Decision (historical):** Configurable per part or die / cavity. Rules now partially supplied (rank compatibility, post-sort only, FIFO-by-cavity). Full die-rank matrix owed by MPP Quality (S-08).

---

### UJ-09 — Material verification at assembly — ✅ Resolved (2026-04-27, Option C)

**Priority:** MEDIUM
**Blocks:** Assembly material ID screen
**Maps to:** OI-32 (Material Allocation operator screen — currently challenged by Jacques, in clarification)
**References:** FDS-06-011; FRS 3.10.6, 3.16.1; FRS 3.4.2 (BOM structure)

**Description:** When an operator at an Assembly Cell scans a component LOT into the workstation, the MES must validate that the part is a legitimate component on the BOM for the parent Assembly being built. The intent is to prevent substitution errors — wrong sub-assembly going into the finished product. The open question is the **strictness** of the check.

**Options:**

| Option | Validation rule | Impact |
|---|---|---|
| **A — Strict BOM check, no override** (current direction) | Only the exact `ChildItemId` on the active BOM passes. Wrong-part scans are rejected outright. Substitutions require an explicit BOM revision (`Bom_CreateNewVersion` → `Bom_Publish`). | Cleanest, lowest substitution risk. Honda compliance wins. Operator friction if substitutions are routine — BOM revision is heavyweight for a temporary substitute. |
| **B — Strict + substitute table** | New `Parts.ItemSubstitute` junction (`PrimaryItemId`, `SubstituteItemId`, `EffectiveFrom`, `DeprecatedAt`). Scan validates against `BomLine.ChildItemId` OR matching `ItemSubstitute` row. | Per-part substitution flexibility without BOM revision. Adds engineering setup burden — someone maintains the substitute list. Potentially abused — substitutes added "temporarily" become permanent. |
| **C — Strict + supervisor override** | Strict by default; on a wrong-part scan, supervisor AD elevation (FDS-04-007) unlocks a one-shot override that records the substitution event in `Audit.OperationLog` for traceability. | Catches abuse via audit trail — every substitution has a supervisor name attached. No persistent config. Honda likely accepts this if the override events are reviewable. |

**Recommended direction:** A initially (already in design). C as the escape hatch for legitimate emergencies (right part not available, supervisor approves substitute). Avoid B — substitution should be the BOM author's call (engineering / quality), not a runtime configuration. If MPP later confirms that certain parts have routine substitutes (rare in Honda Tier 2), revisit B.

**What's needed to decide:** MPP confirmation that substitutions are rare and BOM revision is the right path for permanent substitutes. Honda compliance affirmation. If C accepted, design the supervisor-override UX (PIN entry mid-scan, override-event audit row).

**Decision (2026-04-27 — closed by Jacques):** **Option C — Strict BOM check + supervisor override.** Strict by default; on a wrong-part scan, supervisor AD elevation (FDS-04-007) unlocks a one-shot override that records the substitution event in `Audit.OperationLog` for traceability. FDS edits in v0.11j: FDS-04-007 elevated-action list adds "BOM substitute override at material scan-in"; FDS-06-011 extended with the override flow.

**Decision (historical):** BOM check on scan-in — reject substitutes. Pending customer validation.

---

### UJ-10 — Shift boundary handling — ✅ Resolved (2026-04-27, Option D)

**Priority:** MEDIUM
**Blocks:** Downtime, container, production screens
**Maps to:** OI-03 (resolved — event-derived runtime)
**References:** FDS-09-009, FDS-09-010; FRS 3.15.2

**Description:** Production runs continuously across shift boundaries. Downtime events, container fills, and LOT progressions in flight at shift change need to be handled without forcing the operator (or the system) to artificially close and reopen them. The OI-03 resolution already establishes the underlying model (shift boundaries are pure timestamps; events span freely; OEE math slices post-hoc). What remains open is the **operator UX expectations** at the boundary itself.

**Options:**

| Option | UX behavior at boundary | Impact |
|---|---|---|
| **A — Events span naturally, no UX disruption** (current direction per OI-03) | Open downtime events / containers / LOTs persist across the boundary unchanged. Outgoing operator's session handover is per-terminal (initials re-confirmation per FDS-04-009). OEE reports slice events by `ShiftSchedule` windows at query time. | Cleanest — no artificial event splitting. Operators see continuous state. OEE math handles the slicing. Already in OI-03 closed model. |
| **B — Auto-close + auto-reopen at boundary** | At shift transition, every open event is closed (`EndedAt = boundary`) and a new event auto-opened in the next shift with the same context. | Easier OEE math (events are pre-sliced). Loses event continuity — a 12-hour downtime becomes 2 events with awkward genealogy. Operator may see "new" event when nothing physically changed. |
| **C — Operator-driven boundary close** | Operator must close any open events as part of their shift-end checklist; incoming operator opens new ones. | Operator burden. Doesn't match how shifts actually transition (operators leave the floor, machines keep running). |
| **D — Hybrid: events span, but optional shift-end summary** | A still applies. At shift end, the outgoing operator gets a one-screen summary of in-flight events (downtimes, containers, LOTs) for handover-acknowledgement purposes. No auto-close. | Best of both worlds. Adds a UJ-level summary screen — small UX addition. Audit trail captures the handover acknowledgement. |

**Recommended direction:** D — events span (A) plus an optional shift-end summary screen for handover. The summary screen reads `Workorder.ProductionEvent` + `Oee.DowntimeEvent` for the outgoing operator's terminal at shift close and presents a quick scan of state. No data model change required (purely a Perspective view); just a per-station summary query.

**What's needed to decide:** Customer confirmation on OEE reporting expectations (slice-by-shift query is the OI-03 baseline). Operator + Supervisor walk-through on whether the shift-end summary screen has value (D enhancement) — if not, A suffices. Couples to UJ-11 (paper transition: legacy paper sheets are the current shift handover artifact).

**Decision (2026-04-27 — closed by Jacques):** **Option D — events span (per OI-03) + optional shift-end summary screen.** Already-OI-03-resolved event-spans-naturally model is the foundation; on top, the outgoing operator gets a one-screen handover summary (open `DowntimeEvent` rows, open `PauseEvent` rows, in-process LOTs at the operator's terminal). Implementation note: the in-process-LOT query joins `LotMovement` to `v_LotDerivedQuantities` — same pattern already used by Lot Details. FDS edit in v0.11j: FDS-09-015 NEW.

**Decision (historical):** Pending customer discussion. Now partially addressed by OI-03's event-derived runtime model — shift boundaries become pure timestamps, downtime events can freely span them.

---

### UJ-11 — Paper to screen transition — ✅ Resolved (2026-04-27, Option A — flagged risk)

**Priority:** HIGH
**Blocks:** All production screens
**Maps to:** OI-08 addenda (tablet design input), OI-31 (single-line vs full-cutover rollout shape)
**References:** FDS-15-007; FRS 5.6.6; Appendix F (Productivity DB)

**Description:** When MES go-live happens, does every station cut over from paper data entry on the same day, or do some stations stay on paper temporarily? The decision interacts with terminal availability (some Die Cast stations are pending tablet deployment per OI-08 addenda) and the rollout shape (OI-31 — Ben owes the call between single-line, full-cutover, or shadow).

**Options:**

| Option | Cutover shape | Impact |
|---|---|---|
| **A — All-at-once** | Every station goes digital on day 1. Paper sheets become invalid. | Cleanest data — single source of truth from go-live. Highest training and operations risk. Requires every terminal in place before flip. |
| **B — Phased per station** | Stations not yet equipped (e.g., Die Cast pending tablets) stay on paper until terminal arrives; equipped stations go digital. Reconciliation tooling spans the gap. | Real-world — matches actual deployment readiness. Adds reconciliation complexity (paper logs vs MES events) for the transitional weeks. |
| **C — Dual-write (parallel run)** | Every operator records on both paper AND MES for N weeks. Reconciliation report flags discrepancies. | Highest data confidence (catches MES bugs against paper truth). Doubles operator burden during transition — high training cost and potential operator pushback. |
| **D — Single-line pilot** | One Assembly Line goes fully digital first; other lines stay on paper until pilot validates. (Ben's OI-31 single-line option.) | Lowest risk — bugs caught on a single line before plant-wide. Longest timeline to full benefit. Operationally fragile if pilot line operators can't visit other lines. |

**Recommended direction:** B with a preferred D-then-B sequence — single-line pilot (per OI-31 if Ben picks single-line) followed by phased rollout to remaining stations as terminals are deployed. Paper-only stations get a short reconciliation tool to capture missed events post-hoc into MES.

**What's needed to decide:** Ben's OI-31 rollout shape decision (single-line vs full-cutover vs shadow — memo at `Meeting_Notes/2026-04-24_OI-31_Single-Line_Deployment_Impact.md`). MPP IT joint deployment plan with station-by-station terminal-readiness timeline. Couples to UJ-19 (Productivity DB transition).

**Decision (2026-04-27 — closed by Jacques):** **Option A — All-at-once cutover. Flagged as a risk.** Every station goes digital on go-live; paper sheets become invalid. Risk: requires every terminal in place before flip; highest training and operations burden. Risk owner: Ben (rollout shape decision per OI-31). Couples to UJ-19 (Productivity DB transition). No FDS edit required — go-live shape is a deployment plan concern, not an FDS requirement.

**Decision (historical):** Pending discussion with Ben. Question is whether some stations stay paper-first until tablets are deployed (OI-08 addenda).

---

### UJ-12 — Terminal-to-machine mapping — ✅ Resolved (addenda in OI-08)

**Priority:** MEDIUM
**Blocks:** All operator screens
**Maps to:** OI-08
**References:** FDS-02-008, FDS-02-009; FRS 3.7.1, 3.7.2; Spark Dep. B.1

**Decision:** Terminals are shared with a machine-barcode scan as the first step. 80% are dedicated (1:1) mode, 20% shared — see OI-08 addenda for the `TerminalMode` attribute and the terminal-lock behaviour.

---

### UJ-13 — Weight vs. count-based container closure — ✅ Resolved (2026-04-27, Option A)

**Priority:** HIGH
**Blocks:** Container management screens
**Maps to:** OI-02
**References:** FDS-06-014, FDS-03-017; FRS 3.6.6, 3.9.7; Appendix C

**Description:** Container closure can be triggered by either piece count (operator confirms when N pieces reached) or scale weight (system reads weight from OmniServer scale, closes when target weight hit). Different parts use different methods. How does the MES determine which method applies?

**Options:**

| Option | Configuration | Impact |
|---|---|---|
| **A — Per-Item via ContainerConfig** (current direction, schema in place) | `Parts.ContainerConfig.ClosureMethod NVARCHAR ('Count' / 'Weight')` + nullable `TargetWeight DECIMAL`. Already added in v1.0 (Phase 4) proactively for OI-02. | Per-Part granularity matches how MPP defines container packing. Schema columns already present, just need procs and UX wired. Operator screen reads the flag and shows the appropriate UX (count vs weight readout). |
| **B — Per-Cell** | Cell determines the method via LocationAttribute. Same part on different Cells could close differently. | Couples closure rule to physical Cell, not the part. Doesn't match how Honda specifies container packing rules (per part, not per location). |
| **C — Operator selects at close time** | UI exposes both Count and Weight options; operator picks. | Operator burden + error risk. Counter-productive. |

**Recommended direction:** A — schema already supports it from Phase 4 / OI-02 proactive addition. ContainerConfig is the natural home: it already captures `PartsPerTray` and `TraysPerContainer` for Count parts; `TargetWeight` extends it for Weight parts.

**What's needed to decide:** MPP confirmation of which parts are weight-based vs count-based. This is part of S-05 (Parts master export — the MPP IT export should carry `ClosureMethod` + `TargetWeight` per part, or MPP supplies a separate two-column mapping). Engineering walk-through with Ben on weight-based UX (does the operator see live weight readout? auto-close on threshold? confirm-before-close?).

**Decision (2026-04-27 — closed by Jacques):** **Option A — Per-Item via ContainerConfig.** Schema columns `Parts.ContainerConfig.ClosureMethod` + `TargetWeight` already shipped in v1.0 (Phase 4) proactively for OI-02. No FDS edit required. ClosureMethod values per Item come in via S-05 (Parts master export — seeding registry).

**Decision (historical):** Pending Ben — dual-mode closure logic per ContainerConfig (proposed: `ClosureMethod` + `TargetWeight`).

---

### UJ-14 — Warm-up shots and setup tracking — ✅ Resolved (2026-04-27, Option A)

**Priority:** MEDIUM
**Blocks:** Die Cast production screen
**References:** FDS-06-003; FRS 2.2.2; DCFM Paper Sheets

**Description:** Die Cast warm-up shots (the first N shots after a die change or extended downtime) are not production — they're scrap by design. The current paper-sheet practice records them as setup time + a shot count. The MES must capture both the time and the shot count without polluting `ProductionEvent` with non-production shots.

**Options:**

| Option | Storage | Impact |
|---|---|---|
| **A — DowntimeEvent + ShotCount** (current direction, v1.5 already shipped) | `Oee.DowntimeEvent` row with `DowntimeReasonTypeId = Setup` + `ShotCount INT NULL` column on the same row. | Reuses existing tables. Warm-up time stays in OEE downtime numerator. Shot count is queryable per setup event. Schema change already landed in Phase 8. |
| **B — ProductionEvent + IsWarmup flag** | New `IsWarmup BIT` column on `ProductionEvent`; rows excluded from good-count aggregations. | Pollutes the production-event stream with non-production rows. Aggregation queries everywhere need a `WHERE IsWarmup = 0` filter. Pollution risk. |
| **C — Dedicated WarmupEvent table** | New `Workorder.WarmupEvent` table — `LotId NULL`, `LocationId`, `ShotCount`, `StartedAt`, `EndedAt`, `OperatorId`. | Cleanest semantics. New table for a niche concept. Extra schema overhead. |

**Recommended direction:** A — already shipped. Warm-up is operationally a setup downtime; the shot count is metadata on that downtime. No need for a separate event stream.

**What's needed to decide:** Ben's final confirmation that warm-up tracking under `DowntimeEvent.ShotCount` matches operator practice. Edge case to validate: what happens if warm-up partially produces good shots (atypical but possible)? Currently those would be recorded on a separate `ProductionEvent` once production starts — the warm-up downtime closes when the operator transitions to production.

**Decision (2026-04-27 — closed by Jacques):** **Option A — DowntimeEvent + ShotCount.** Already shipped in v1.5 / Phase 8 migration `0009_phase8_oee_reference.sql`. No FDS edit required.

**Decision (historical):** Treat as downtime sub-category. `ShotCount` added to `DowntimeEvent`. Pending Ben's final confirmation. Schema column shipped in Phase 8 migration `0009_phase8_oee_reference.sql`.

---

### UJ-15 — Multi-part-number lines — ✅ Resolved (addenda in OI-09)

**Priority:** MEDIUM
**Blocks:** Assembly / inspection screens
**Maps to:** OI-09
**References:** FDS-03-016, FDS-03-017; FRS 3.9.7, 3.16.1, 3.16.2; MS1FM-1028

**Decision:** "Select Part Number" pattern, not concurrent multi-part. See OI-09 addenda for the sublot pattern that concurrent same-part-different-cavity produces.

---

### UJ-16 — Hardware interlock bypass mode — ✅ Resolved (2026-04-27, Option A)

**Priority:** MEDIUM
**Blocks:** Serialized assembly screens
**References:** FDS-06-009; Appendix C (OPC tag: `HardwareInterlockEnable`); Touchpoint Agreement §1.4

**Description:** Serialized Assembly lines have a hardware interlock at the MIP (Machine Integration Panel) that gates the press cycle on a successful serial-validation handshake from the MES. Sometimes the operator needs to bypass the interlock — typical scenarios: vision-system fault recovery, MES connectivity loss, end-of-shift abandonment with parts mid-process. When bypass happens, those parts must be flagged for downstream traceability (Honda needs to know "this serial was made with validation skipped").

**Options:**

| Option | Storage | Impact |
|---|---|---|
| **A — BIT flag on `Lots.ContainerSerial`** (current direction, drafted v0.4.1) | `ContainerSerial.HardwareInterlockBypassed BIT NOT NULL DEFAULT 0`. Set to 1 by the production proc when bypass occurs. Per-serial precision. | Captures the affected serial directly. Aligns with the "this serial bypassed validation" semantic. Reports queryable per-serial. |
| **B — BIT flag on `Workorder.ProductionEvent`** | `ProductionEvent.HardwareInterlockBypassed BIT`. Captures per-event (broader context — multiple serials may share an event). | Captures broader production context but fuzzier — if an event covers a batch of serials, a single bypass marks the whole batch ambiguously. |
| **C — Both** | A + B; full traceability at both granularities. | Most defensive. Redundant — A is the authoritative per-serial mark, B's value is mainly for OEE downtime cross-reference (which `DowntimeEvent` already captures via `DowntimeReasonType = Equipment` if the bypass was triggered by an equipment fault). |
| **D — Dedicated InterlockBypassEvent table** | New event table linking the bypass occurrence (operator, terminal, reason, affected serial range, bypass start/end timestamps). | Most expressive. New table for an edge-case concept — overhead high. |

**Recommended direction:** A. Per-serial flag is the primary use case ("show me every serial made under bypass"). The trigger context (why bypass happened) is already capturable via existing `DowntimeEvent` + `Audit.OperationLog` writes — no need for a dedicated table.

**What's needed to decide:** Ben's input on actual bypass triggering conditions and frequency. Specifically: (1) Is bypass operator-initiated, or supervisor-required? (2) Does it auto-clear after N events, or stays active until explicitly turned off? (3) What's the typical reason — vision fault, manual override, recovery? Couples to UJ-17 (vision/barcode confirmation conflicts can trigger bypass need). Honda compliance: confirm the serial-level flag satisfies their traceability requirement.

**Decision (2026-04-27 — closed by Jacques):** **Option A — BIT flag on `Lots.ContainerSerial`.** Per-serial precision; column drafted in v0.4.1 (`HardwareInterlockBypassed BIT NOT NULL DEFAULT 0`). No new FDS edit required — FDS-06-009 covers the bypass capture.

**Decision (historical):** Add a bypass flag to the data model and mark affected serials as "serial validation skipped." Pending discussion with Ben.

---

### UJ-17 — Vision system vs. barcode confirmation — ✅ Resolved (2026-04-27, Option A)

**Priority:** MEDIUM
**Blocks:** PLC-integrated production screens
**Maps to:** OI-04 (resolved — line-stop, 10-fail escalation, CRT workflow)
**References:** FDS-10-003; FRS 3.16.9; Appendix C

**Description:** Some Assembly stations confirm the part identity via Cognex vision OCR, others via barcode scan, and a few have both available. When both are present, what's the rule — both required (AND), either acceptable (OR), or single configured source per station? And how do conflicts resolve when one passes but the other fails?

**Options:**

| Option | Confirmation rule | Conflict handling | Impact |
|---|---|---|---|
| **A — Single configured source per Cell** (recommended) | Cell carries a `LocationAttribute` `ConfirmationMethod NVARCHAR ('Vision' / 'Barcode' / 'Both')`. Procs read the flag and validate per the configured source(s). | Edge cases (e.g., barcode unreadable but vision OK) require operator manual override (logged as bypass per UJ-16). | Simplest. One source of truth per Cell. Configured once at deployment. Matches actual line behavior — most lines have a single source available. |
| **B — Both required when both available (AND)** | Cell with both vision and barcode requires both to confirm before the production event records. | Highest reliability — single fault hides nothing. Highest operator friction if either source is unreliable. Single sensor failure halts the line. |
| **C — Either acceptable when both available (OR)** | If either vision or barcode confirms, the production event records. | Lowest friction. Lowest reliability — a single fault on one source hides issues from the other. |
| **D — Vision authoritative + barcode reconciliation** | Vision is the primary; barcode is read on every cycle but only reconciled (logged for audit, not gating). Mismatches log a warning event. | Captures both sources' data without doubling the friction. Adds a reconciliation log entity. Useful only on lines where both are present and reliable. |

**Recommended direction:** A — configured per Cell via LocationAttribute. Each line operator works with the source(s) actually present. Edge-case mismatches surface as 10-fail line stops per OI-04. If MPP later identifies lines where both sources are reliable and reconciliation is valuable, layer D on top of those specific Cells.

**What's needed to decide:** Ben's input on actual line behavior — for each Assembly Cell with vision and/or barcode, which source(s) are present and operationally reliable. Walk-through for the few "both available" lines: would MPP value the AND rule (B) or accept the configured-source rule (A)? Couples to OI-04 (line-stop / 10-fail / CRT workflow already covers fail escalation).

**Decision (2026-04-27 — closed by Jacques):** **Option A — Single configured source per Cell.** New `LocationAttributeDefinition` seed `ConfirmationMethod NVARCHAR ('Vision' / 'Barcode' / 'Both')` on relevant LocationTypeDefinitions. Edge-case mismatches surface as 10-fail line stops per OI-04 (already covered). FDS edit in v0.11j: FDS-10-013 NEW.

**Decision (historical):** Pending Ben. Now coupled to OI-04 revised (line-stop, 10-fail escalation, CRT workflow).

---

### UJ-18 — Event processing: sync vs. async — ✅ Resolved (2026-04-27, Gateway-script-async)

**Priority:** HIGH
**Blocks:** Every label-printing touchpoint, all non-AIM external integrations
**Maps to:** OI-01 (resolved — no outbox), UJ-04 (resolved — AIM uses pool pattern)
**References:** FDS-01-006; FRS 3.17.4; Spark Dep. B.12

**Description:** External integrations beyond AIM `GetNextNumber` (which is special-cased to the pool pattern per UJ-04) include: Zebra label printers, AIM `UpdateAim` (re-pack), AIM `PlaceOnHold` / `ReleaseFromHold`, future Macola pushes. What's the default integration pattern — synchronous direct call with logging, or asynchronous outbox with eventual consistency?

**Options:**

| Option | Pattern | Impact |
|---|---|---|
| **A — Sync direct call + InterfaceLog** (current direction per OI-01) | MES calls the external system inline; `Audit_LogInterfaceCall` writes the request/response to `Audit.InterfaceLog`; the calling proc waits for the response. | Simplest. Matches OI-01 resolution (no outbox). Single source of truth (InterfaceLog). Risk: slow integrations briefly block the calling operator. Acceptable for label print (fast) and Hold notifications (not on operator critical path). |
| **B — Outbox pattern** | All outbound events written to a `Workorder.OutboxEvent` table; a background drain script picks them up and calls the external system. On failure, retry; on permanent failure, dead-letter. | Decouples MES from external availability. Adds operational complexity (outbox state machine, retry logic, dead-letter handling, drain monitoring). FRS does not require this. |
| **C — Hybrid (per-integration choice)** | Sync for fast/critical-path (label print at container close); async outbox for slow/recoverable (AIM UpdateAim, Hold notifications). | Most operationally tuned. Adds inconsistency — two patterns in the codebase. Some calls already special-cased (UJ-04 AIM pool); piling more variants risks ad-hoc mess. |

**Recommended direction:** A for everything except AIM `GetNextNumber` (which is already special-cased to the pool pattern via UJ-04). Sync direct call + InterfaceLog. The pool pattern is a *narrower* case of "buffered async" — applied surgically only where operator-blocking matters most (container close on the AIM line).

**Per-integration confirmation:**
- **Zebra label print:** Sync. Print failures (printer offline) surface as a clear operator error; reprint via FDS-07-009 once printer recovers.
- **AIM `UpdateAim` (re-pack at Sort Cage):** Sync. Sort Cage operations are not time-critical to the same degree as Assembly close; brief AIM latency is acceptable.
- **AIM `PlaceOnHold` / `ReleaseFromHold`:** Sync. Hold operations are quality-driven, not operator-critical.
- **Future Macola pushes:** Sync, with InterfaceLog. If Macola becomes a critical-path integration later, revisit per integration.

**What's needed to decide:** Ben's validation of A as the default. Confirm acceptable label-print latency budget. Confirm Hold operations can tolerate a few seconds of sync AIM call.

**Decision (2026-04-27 — closed by Jacques):** **Gateway-script-async pattern (architectural, not just an integration choice).** All external integrations SHALL be made via Ignition Gateway scripting; async dispatch via `system.util.sendMessageAsync` rather than synchronous in-MES-proc calls. Failures handled in script and logged to `Audit.FailureLog`. AIM `GetNextNumber` is the special case — UJ-04's pre-fetched pool insulates Container_Complete from any network call at all.

**Print-path implications (Q&A locked with Jacques 2026-04-27):**
- **Container close** (FDS-07-005) — atomic block now holds: pool claim, status flip, `ShippingLabel` INSERT (PrintedAt NULL, attempts 0, terminal), OperationLog. Print is **extracted** — Perspective view fires `system.util.sendMessageAsync('mes', 'print-shipping-label', {ShippingLabelId})` on close success.
- **Print attempts:** 3 retries with **fixed 2s gap** between attempts — handled inline in the Gateway message handler (no re-send-to-self pattern; concern was Gateway thread-pool lockup).
- **Failure surface:** UI banner at the closing terminal only (per-terminal scope, not plant-wide). Banner shows container + AIM ID + last error + Retry/Reprint/Acknowledge actions. Other operators at other terminals do not see it.
- **Stranded-prints alarm:** safety-sweep timer at low cadence (every 5 min) checks `ShippingLabel WHERE PrintedAt IS NULL AND PrintFailedAt IS NULL AND CreatedAt < NOW() - 60s`. If count > **5**, supervisor alarm + IT notification fires (mirrors AIM pool alarm pattern).
- **Schema delta on `Lots.ShippingLabel`:** +`PrintAttempts INT NOT NULL DEFAULT 0`, +`LastPrintAttemptAt DATETIME2(3) NULL`, +`LastPrintError NVARCHAR(2000) NULL`, +`PrintFailedAt DATETIME2(3) NULL`, +`TerminalLocationId BIGINT FK → Location.Location.Id, NULL` (banner routing). State derivation, no separate code table.
- **Other external integrations:** AIM `UpdateAim`, AIM `PlaceOnHold` / `ReleaseFromHold`, future Macola pushes — same Gateway-script-async pattern. Sync direct call from MES proc is retired except where the call is genuinely instantaneous (local DB).

**Integration landed (this commit — v2.14):**
- **Data Model v1.9i** — `Lots.ShippingLabel` +5 columns above.
- **FDS v0.11j** — FDS-01-014 (NEW under §1.6) cross-cutting Gateway-script-async pattern; FDS-07-005 amended (print extracted from atomic block); FDS-07-006a (NEW) print dispatch + retry; FDS-07-006b (NEW) banner + safety sweep.

**Decision (historical):** FRS does not require the outbox pattern — just a log of all sent and received content (`Audit.InterfaceLog`). Pending Ben's validation of the direct-call-with-logging approach.

---

### UJ-19 — Productivity DB replacement & change management — ⬜ Open

**Priority:** HIGH
**Blocks:** All production screens, reporting
**Maps to:** UJ-11 (paper transition), OI-30 (Reports tile enumeration)
**References:** FDS-15-007; FRS 5.6.6; Appendix F (Productivity DB); DCFM / MS1FM Paper Sheets

**Description:** The legacy Productivity Database (PD) is a custom Excel-and-flat-file system that operators / supervisors use today for production summaries, downtime aggregates, and shift reports. The MES replaces it. Four named PD reports must be reproduced. The open question is the **transition shape** — do operators dual-enter for a period, or hard-cut?

**Options:**

| Option | Transition shape | Impact |
|---|---|---|
| **A — Hard cutover** | PD shuts down on MES go-live; all entry shifts to terminals; PD reports recreated as MES reports. | Cleanest reporting from day 1. Highest training burden — no fallback if MES has gaps. Operator pushback risk. |
| **B — Dual-run with reconciliation** | PD continues for N weeks alongside MES. Reconciliation tooling compares the two. Cutover when discrepancies hit acceptable threshold. | Risk reduction at cost of dual entry. Doubles operator burden during overlap. Validates MES data accuracy against the legacy ground truth. |
| **C — Phased per station** | Each station cuts over individually as terminals deploy and operators are trained. Couples to UJ-11. | Real-world operational. Adds complexity — some stations on PD, others on MES, until full rollout completes. |
| **D — Reports-first** | MES reporting layer goes live first (reading PD's data store), operators continue with paper/PD entry. Then operator-entry stations cut over. | Low-risk reporting validation. Doesn't address the entry-side transition (which is what UJ-11 is about). |

**Recommended direction:** C, mirroring UJ-11's recommended phased rollout. PD lives at any given station as long as paper does at that station. The four PD reports get implemented in MES reporting as MES data accumulates per station; until each station is fully on MES, its PD report falls back to the paper source.

**Four PD reports — needs enumeration from MPP** (couples to OI-30 Reports tile discovery item):
1. _(Pending — MPP names the four)_
2.
3.
4.

**What's needed to decide:** Customer (likely Ben + Production Control) names the four PD reports + the data sources behind them; MES reporting subsystem replicates them. Couples to OI-30 (top-level Reports tile enumeration is itself a discovery item awaiting MPP input). Couples to UJ-11 (paper transition). Couples to OI-31 (rollout shape).

**Decision (existing):** Pending customer discussion. Four PD reports must be replicated; real-time entry at the machine is the default but some stations may need a paper-first-then-enter bridge.

---

## Notes

- The 2026-04-20 MPP review driving v2.4's changes is captured in `Meeting_Notes/2026-04-20_OI_Review.md`.
- The 2026-04-22 legacy screenshot review driving v2.5's additions (OI-15 through OI-30) is captured in `Meeting_Notes/2026-04-20_OI_Review_Status_Summary.md` §"Additional discovered gaps". Source screenshots at `reference/MPP_Current_MES_screenshots.docx`.
- Execution plan for Phases A–G is held in `memory/project_mpp_oi_refactor.md` (session-durable memory). Gap-analysis items (OI-15..30) fold into Phase E (design + doc) and Phase G (SQL) except where noted.
- Phase A (this register) was the first deliverable in the multi-session refactor. Phase B (Tool Management design spec) is complete; Phases C + D (security + FDS rewrites) are complete. Phase E now incorporates the 16 newly-discovered items alongside OI-11..14.
