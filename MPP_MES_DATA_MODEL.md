# MPP MES — Data Model Reference

**Version:** v1.9 working draft (rev 2026-06-08q - **section 3 `Lot.CrtActive BIT`** added (FDS-10-012 Controlled Run Tag hook, MVP-ratified 2026-06-08); rev 2026-06-08p - Location `CoupledDownstreamCellLocationId` typed-FK promotion + `QualityResult.NumericValue`; rev 2026-06-05o — **§7 `Tools.ToolType.CompatibleLocationTypeDefinitionId`** added (migration `0018`) for the Mount-to-Cell tool-type→cell-kind dropdown filter; `Die → DieCastMachine` seeded. Earlier: rev 2026-06-04n — sub-LOT split relocated from Trim OUT to **Machining OUT** per FDS v1.3 / Phased Plan v1.1; `Parts.OperationTemplate.RequiresSubLotSplit` now controls the Machining OUT outbound flow (FDS-05-009), and the ALTER lands in Phase 5 migration `0018` rather than Phase 4 `0017`. v1.9m (2026-04-29) had added the column under the prior Trim-OUT design. See revision history.)
**Schemas:** 8 | **Tables:** ~73
**Target:** Microsoft SQL Server 2022 Standard Edition

---

## Revision History

| Version | Date | Author | Change Summary |
|---|---|---|---|
| 1.9r | 2026-06-08 | Blue Ridge Automation | **§5 Quality doc-sync — three migration-`0017` columns back-filled into the spec (were live in the DB but missing from this doc and the ERD).** `Quality.QualitySpec` gains `DeprecatedAt DATETIME2(3) NULL` + `DeprecatedByUserId BIGINT NULL FK → AppUser.Id` (header-level soft-delete). `Quality.QualitySpecAttribute` gains `UomId BIGINT NULL FK → Parts.Uom.Id` (replaces free-text `Uom` usage by the Config Tool QualitySpec editor; legacy `Uom NVARCHAR(20)` retained for back-compat). All three shipped in versioned migration `0017_qualityspec_attribute_uom_fk` (applied) but were never reflected in the data model §5 or `MPP_MES_ERD.html` — surfaced by the 2026-06-08 ERD-vs-DM parallel audit. No SQL change (migration already live); spec + ERD Quality tab updated to match the built schema. |
| 1.9q | 2026-06-08 | Blue Ridge Automation | **section 3 Lot - `CrtActive BIT NOT NULL DEFAULT 0` added (FDS-10-012 Controlled Run Tag).** CRT workflow ratified for MVP 2026-06-08: a CRT-active LOT forces 200% downstream inspection (via `Quality.QualitySample`) with a supervisor-elevated release path and a `MissedCrtInspect` re-run rule. The column lands in the Arc 2 Phase 1 `Lots.Lot` CREATE; the workflow procs + audit event types build in the Arc 2 Quality phase. No other shipped table affected. |
| 1.9p | 2026-06-08 | Blue Ridge Automation | **EAV-at-scale review follow-up — two structural changes + scaling-plan fold-in.** (1) **§1 Location — `CoupledDownstreamCellLocationId` promoted from a `CNCMachine` LocationAttribute (EAV, NVARCHAR(255)) to a typed self-FK column `BIGINT NULL FK → Location.Location.Id`** (migration `0019_location_coupled_downstream_cell`). It is a `Location → Location` relationship read on the hot path of every coupled Machining-OUT completion (FDS-06-008) — EAV gave it no referential integrity and forced a string→Id pivot per event. It was spec'd in v1.9k but **never seeded**, so this is pure-forward (no value backfill, no `0002` seed to remove). The self-FK enforces integrity; the "target must be a Cell-tier Assembly Location" rule stays in the Arc 2 write proc (mirrors `Tools.ToolType.CompatibleLocationTypeDefinitionId`, migration `0018`). The CNCMachine attribute-example block is removed; FDS-06-008 already referenced it as a location property, so no FDS change. Surfacing it in `Location_Get` + a Config Tool Cell-picker is Arc 2 wiring — the column + constraint exist now. (2) **§5 QualityResult — `NumericValue DECIMAL(18,4) NULL` added**, a numeric shadow of `MeasuredValue` enabling indexable range / SPC / Cpk queries without string parsing. Mirrors the existing `Workorder.ProductionEventValue.NumericValue`. QualityResult is Arc 2-deferred (unbuilt) so this is a spec-only change — the column lands when the Arc 2 Quality CREATE migration writes the table; cheap now, painful to retrofit onto a 20M+ row table. (3) **Scaling plan (OI-35) folded in the two runtime-EAV children** `Workorder.ProductionEventValue` and `Quality.QualityResult` — they grow as multiples of their parents (events × extension-fields; samples × attrs-per-spec) but were absent from the OI-35 row-estimate table and the 2026-04-28 indexing-review gap table. Both now carry index commitments and partition-alignment notes so the Arc 2 Phase 1 CREATE doesn't miss them. No change to any currently-shipped table beyond the additive Location column. Source: 2026-06-08 EAV-at-scale review session. |
| 1.9o | 2026-06-05 | Blue Ridge Automation | **§7 ToolType — `CompatibleLocationTypeDefinitionId BIGINT NULL FK → Location.LocationTypeDefinition` added (migration `0018_tooltype_compatible_celldef`).** Gives each tool type a one-to-one mapping to the `Cell`-kind it mounts on, so the Configuration Tool's Mount-to-Cell dropdown filters Cell-tier Locations down to the relevant kind (a Die Cast Die lists only Die Cast Machine cells, not CNC machines / terminals / printers / scales — the seeded Cell tier had 146 Locations, only 22 of them presses). NON-NULL restricts the dropdown; NULL = no restriction (all `Cell`-tier Locations). Seeded `Die → DieCastMachine` by Code; all other tool types NULL until their flows activate. Consumed by new repeatable proc `Tools.Tool_ListCompatibleCells @ToolId` (rule lives in SQL, not the Jython layer per the no-business-logic-in-Python convention); `ToolType_List` / `ToolType_Get` extended to surface the column. Frontend: `BlueRidge.Parts.Tool.getCellsForDropdown(toolId)` + `MountToCell` popup binding pass the tool id. **Migration-number note:** this took the next free versioned number `0018`; the doc header / Arc 2 plan had earmarked a *planned* Phase 5 `0018` for the OperationTemplate sub-LOT-split ALTER — that future Arc 2 migration re-numbers to `0019+` when it actually builds (Arc 2 is OI-35-gated and unbuilt). No change to currently-shipped tables beyond the additive column. |
| 1.9n | 2026-06-04 | Blue Ridge Automation | **Sub-LOT split relocated Trim OUT → Machining OUT** (per MPP, confirmed 2026-06; mirrors FDS v1.3 + Phased Plan v1.1). `Parts.OperationTemplate.RequiresSubLotSplit` (§2) now controls the **Machining OUT** outbound flow, not Trim OUT — when `1` the line splits the machined LOT into N sub-LOTs at Machining OUT (`MachiningOut_RecordSplit`); Trim OUT is a 1:1 whole-LOT move. The ALTER moves from Phase 4 migration `0017` to **Phase 5 `0018`**. `Parts.Item.DefaultSubLotQty` description corrected (split at Machining OUT). **No schema change** — `Lot.ParentLotId` / `LotGenealogy` already model machining-origin sub-LOTs; the column definition is unchanged, only its consuming operation moved. Also: **§3 ContainerConfig.ClosureMethod** description aligned to FDS-06-014 tray-level semantics (camera validates the full tray as one image — one event per tray, not per piece; prior text said "per piece") and annotated with the customer-dependent-completion decision (2026-06-04): `ClosureMethod` is per-Item/per-customer (one line runs both `ByCount` and `ByVision` parts for different customers), and the binding to a camera/MIP-capable Cell is **routing-trusted, not proc-enforced**. |
| 1.9m | 2026-04-29 | Blue Ridge Automation | **§2 OperationTemplate — `RequiresSubLotSplit BIT NOT NULL DEFAULT 0` added.** Control flag flowing from the 2026-04-29 Phased Plan v1.0 rebuild — Phase 4 Trim OUT branches on this flag (per FDS-05-009): when `1`, the closing proc splits the parent LOT into N children and calls `Lot_MoveTo` per child to selected destination Machining Cells; when `0` (default), the closing proc calls only `Lot_MoveTo` and the parent LOT moves whole. Engineering authors per Item per Cell via the Configuration Tool. Versioned with the rest of the OperationTemplate row per the existing clone-to-modify pattern. Not all OperationTemplate codes consume the flag — Die Cast, Receiving, Machining IN, and Assembly operations ignore it (they have no outbound-distribution branch). SQL ALTER lands in the Phase 4 Plant-Floor migration (`0017_arc2_phase4_movement_trim_receiving.sql`). No companion FDS change — FDS-05-009 already specifies the per-Item-per-Cell split decision; this column gives the FDS rule a queryable home in the data model. |
| 1.9l | 2026-04-29 | Blue Ridge Automation | **FDS v0.11m reconciliation pass — DM aligned to FDS as source of truth.** Comprehensive sweep of stale wording across the doc following the FDS continuity + clarity passes in v0.11k/l/m. **§2 ContainerConfig:** `ClosureMethod` row reframed as **tray-level** trigger per FDS-06-014 — `ByCount` / `ByWeight` / `ByVision` all describe per-tray validation; container fill is MES-side accumulation (no PLC `ContainerFullFlag` tag). **§2 Casting → Trim subsection retitled `Trim → Machining`** per FDS-05-033 v0.11m boundary clarification — LOT keeps cast-part identity through Casting and Trim; Trim sprue/deburr is yield loss via `RejectEvent` on the same LOT; rename fires at first Machining Cell. BOM example rewritten (`5G0-TRIM` Component + `5G0-MACHINED` Sub-Assembly). Backward-trace narrative rewritten — single Machining-IN consumption hop. **§2 NEW VIEW `Parts.v_EffectiveItemLocation` (LocationId, ItemId, Source)** documented per FDS-02-012 — Direct ∪ BomDerived eligibility resolution; created in Arc 2 Phase 1 alongside `ItemLocation_CheckEligibility`. **§2 Item.DefaultSubLotQty** description corrected — split fires at Trim OUT (FDS-05-009), not Machining IN. **§2 ContainerSerial** UJ-16 `🔶 PENDING` callout converted to flowing prose — Resolved 2026-04-27 per OIR v2.14, Option A: `HardwareInterlockBypassed BIT` lands on `Lots.ContainerSerial`. **§4 WorkOrderType** SQL correction follow-up note replaced with past-tense one-liner — migration `0013_oi07_oi12_corrections.sql` landed 2026-04-28, 858/858 tests passing. **§4 WorkOrder** narrative tightened — dropped Arc 2 Phase 1 deployment-state admonition; column contract is the spec. **§4 ProductionEvent** narrative tightened — dropped v1.9 reshape framing and Arc 2 admonition; "Checkpoint-shape event table" describes the shape directly. **§4 deferred event tables (`WorkOrderOperation`, `ConsumptionEvent`, `RejectEvent`) and §6 `DowntimeEvent`:** `OperatorId` columns renamed to `AppUserId` for consistency with the SP template (`@AppUserId BIGINT`) and the v1.9 `ProductionEvent` reshape. Rule-of-law check: SP template at `sql/scripts/_TEMPLATE_stored_procedure.sql` uses `@AppUserId`; the deferred event tables are not yet CREATEd in any of the 13 shipped migrations, so this is purely a DM spec alignment with no SQL impact. **§6 DowntimeEvent** UJ-14 `🔶 PENDING` callout converted to flowing prose — Resolved 2026-04-27 per OIR v2.14. **§7 Tools cross-references rewritten:** `Workorder.WorkOrder.ToolId` parenthetical no longer references the deleted `Recipe` WorkOrderType (OI-07); `Workorder.ProductionEvent.DieIdentifier` cross-ref replaced with `Lots.Lot.ToolId` derivation rule (DieIdentifier column was DROPPED in v1.9 reshape); ItemTransform tombstone clause removed. **§1 Location:** `Terminal` LocationTypeDefinition seed-row description updated to "mode derived from parent tier"; "Terminals in the New Model" callout rewritten for FDS-02-009/010/011 (two-mode model + scan-or-dropdown context selection); `NumberOfCavities` removed as `DieCastMachine` LocationAttribute example (cavity data lives on `Tools.ToolCavity`); explanatory note added — cavities belong to the die, not the press. **§3 Lots `IdentifierSequence` reference** updated `.md` → `.docx` for the OIR cross-ref (matches FDS v0.11m convention). **Document-wide:** `⚠ Implementation deferred to Arc 2 Phase N` admonitions stripped (5 instances) — DM is the big-picture end-goal final solution; deployment state belongs in the phased plan. No schema changes to currently-shipped tables; all changes are spec-doc alignment to FDS v0.11m. |
| 1.9k | 2026-04-28 | Blue Ridge Automation | **Two FDS-driven additions queued from 2026-04-28 working sessions.** (1) **`Lots.ShippingLabel.BannerAcknowledgedAt DATETIME2(3) NULL`** — supports the FDS-07-006b broadcast-with-session-filter Acknowledge action, where the per-terminal print-failure banner shown by FDS-07-006a's retry-exhausted state can be dismissed by the operator. Independent of `PrintFailedAt`: the row stays in failed state for the safety-sweep alarm even after acknowledgement; this column only suppresses the banner UI on the closing terminal. State derivation table updated: Failed = `PrintFailedAt IS NOT NULL AND BannerAcknowledgedAt IS NULL`; Failed-acknowledged = both non-NULL. SQL deferred to Arc 2 Phase 7 alongside the rest of the Container schema CREATE — column contract above is authoritative. (2) **`CoupledDownstreamCellLocationId` LocationAttributeDefinition seed under `CNCMachine`** — supports the FDS-06-008 Machining OUT auto-move-to-coupled-Assembly-Cell flow. New illustrative seed row added to the §2 LocationAttributeDefinition examples block under a new "For `Cell` → `CNCMachine` definition" subsection: `AttributeName=CoupledDownstreamCellLocationId`, `DataType=Integer` (parsed as a `Location.Location.Id` reference), `IsRequired=0` (NULL = legacy uncoupled path). When non-NULL, PLC-signalled machining completion writes the `ProductionEvent` and a `LotMovement` to the referenced Cell + updates `CurrentLocationId`; when NULL, completion writes the event only and the LOT stays at the Machining Cell awaiting operator-driven movement. Phase G seed delta on the next migration: +1 row for `CoupledDownstreamCellLocationId` on the `CNCMachine` definition. No other schema changes. |
| 1.9j | 2026-04-28 | Blue Ridge Automation | **§3 ContainerConfig — `ClosureMethod` extended with `ByVision`.** Camera-validated container closure added per Jacques's 2026-04-28 review: a third trigger alongside the existing count and weight modes. Camera validates each part (pass/fail), PLC accumulates the validated count, asserts `ContainerFullFlag` when target met. Code values renamed to UpperCamelCase per project convention (`ByCount` / `ByWeight` / `ByVision`; previously documented as `BY_COUNT` / `BY_WEIGHT`). "Pending OI-02 closure" caveat retired (OI-02 ✅ Resolved 2026-04-24 per OIR v2.14). No schema change — `ClosureMethod` is `NVARCHAR(20) NULL`; the new value is purely an additional allowed string. FDS-03-017 + FDS-06-014 are authoritative for the per-method mechanics. |
| 0.1 | 2026-04-02 | Blue Ridge Automation | Initial data model — 7 schemas, ~50 tables |
| 0.2 | 2026-04-09 | Blue Ridge Automation | Eliminated `Terminal` table — terminals are now `Location` records (type=Terminal) with config as `LocationAttribute`. Renamed `TerminalId` FKs to `TerminalLocationId` across all event tables. Added `ShotCount` to `DowntimeEvent` for warm-up tracking (UJ-14). Added hardware interlock bypass flag discussion on `ContainerSerial` (UJ-16). Updated workorder schema scope to MVP-LITE (OI-07). |
| 0.3 | 2026-04-09 | Blue Ridge Automation | Naming convention changed from snake_case to UpperCamelCase for all DB identifiers. Merged Department into Area per ISA-95 — `DepartmentLocationId` FKs renamed to `AreaLocationId`, `ChargeToDepartment` renamed to `ChargeToArea`. Added Enterprise (level 0) to `LocationType`. Updated `LocationType` seed rows. |
| 0.4 | 2026-04-10 | Blue Ridge Automation | Major restructure of location schema: `LocationType` reduced to 5 ISA-95 tiers (Enterprise, Site, Area, WorkCenter, Cell). `LocationTypeDefinition` repurposed from "attribute definitions" to "polymorphic kinds" (Terminal, DieCastMachine, CNCMachine, etc. — all under Cell). New `LocationAttributeDefinition` table holds attribute schemas per kind. `Location.LocationTypeId` replaced by `Location.LocationTypeDefinitionId`. `LocationAttribute.LocationTypeDefinitionId` renamed to `LocationAttributeDefinitionId`. Added seed data tables for LocationType, LocationTypeDefinition, and sample LocationAttributeDefinition sets. |
| 0.4.1 | 2026-04-10 | Blue Ridge Automation | Consistency pass: normalized terminal FK columns on append-only Lot event tables (LotGenealogy, LotStatusHistory, LotMovement, LotAttributeChange) to `TerminalLocationId` — were previously `EventTerminalId` / `ChangedAtTerminalId` / `MovedAtTerminalId`. Fixed stale UPPER_CASE code values in column descriptions (Split/Merge/Consumption, Good/Hold/Scrap/Closed, Open/Complete/Shipped/Hold/Void, Manufactured/Received/ReceivedOffsite, Initial/ReprintDamaged/Split/Merge/SortCageReIdentify, UseAsIs/Rework/etc.). Fixed snake_case in UJ-14 warm-up note and UJ-16 interlock bypass note. |
| 0.5 | 2026-04-10 | Blue Ridge Automation | Added `Audit.FailureLog` table to track attempted-but-rejected stored procedure calls (parameter validation failures, business-rule violations, caught exceptions). Complements ConfigLog/OperationLog which track successful mutations. 4 indexes defined (AttemptedAt, AppUser, EntityEvent, ProcedureName). Written by the new `Audit_LogFailure` shared proc from every validation-failure path and every CATCH handler in mutating procs. |
| 0.5.1 | 2026-04-13 | Blue Ridge Automation | Added `SortOrder INT NOT NULL DEFAULT 0` column to `Location.Location` table for display ordering among siblings. Auto-incremented on creation, updated via MoveUp/MoveDown operations. |
| 0.6 | 2026-04-13 | Blue Ridge Automation | **Data type standardization across all ~51 tables.** All primary keys changed from `INT` to `BIGINT IDENTITY`. All foreign keys changed from `INT` to `BIGINT` to match. All `VARCHAR(N)` columns changed to `NVARCHAR(N)` (Unicode support for Honda EDI data). Audit `EntityId` columns (OperationLog, ConfigLog, FailureLog) changed to `BIGINT` to match arbitrary PK references. Non-PK/FK value columns (SortOrder, SequenceNumber, PieceCount, VersionNumber, counts, quantities) remain `INT`. `BIT`, `DECIMAL`, and `DATETIME2(3)` columns unchanged. ERD updated to match. |
| 1.1 | 2026-04-14 | Blue Ridge Automation | **OperationTemplate versioning — schema change.** Added `VersionNumber INT NOT NULL DEFAULT 1` to `Parts.OperationTemplate`; changed `UNIQUE (Code)` → `UNIQUE (Code, VersionNumber)`. Supports the clone-to-modify workflow: `_CreateNewVersion` inserts a new row sharing the Code with `VersionNumber = MAX(siblings)+1`, copies the parent's `OperationTemplateField` rows, and historical `RouteStep` rows continue pointing at the parent's Id so production traceability is preserved. Mirrors the versioning pattern already used by `RouteTemplate` and (later) `Bom` / `QualitySpec`. Schema plumbing delivered as part of Phase 5 — see Phased Plan v1.3. |
| 1.8 | 2026-04-22 | Blue Ridge Automation | **Phase E Group 1 — schema additions from the 2026-04-22 legacy-screenshot gap analysis.** Four items (v1.8 initially drafted five, OI-11 reverted — see row below): (1) **OI-12** — `Parts.ContainerConfig.MaxParts INT NULL` (per-container cap — rejects scan-in beyond this limit to stop operators over-scanning). Lineside inventory quantity cap modelled as a new `LocationAttribute` (`LinesideLimit`) attached to Cell definitions via the existing `Location.LocationAttributeDefinition` pattern — no schema change, just a seed entry. (2) **OI-18** — `Parts.ItemLocation` extended with consumption metadata: `MinQuantity INT NULL`, `MaxQuantity INT NULL`, `DefaultQuantity INT NULL`, `IsConsumptionPoint BIT NOT NULL DEFAULT 0`. Drives the runtime Allocations grid at the workstation (quantities the operator is hinted to scan in) and distinguishes consumption points (inputs to the cell) from production points (outputs). (3) **OI-19** — `Parts.Item.CountryOfOrigin NVARCHAR(2) NULL` (ISO 3166-1 alpha-2). Honda compliance field surfaced in the Flexware Material configuration. (4) **OI-20** — new `Workorder.ScrapSource` read-only code table (seeded `Inventory` + `Location` at Phase G) and `Workorder.ProductionEvent.ScrapSourceId BIGINT NULL FK → ScrapSource.Id` (column deferred to Arc 2 Phase 1 — ProductionEvent table doesn't exist yet; code table lands in Phase G). Captures the Flexware "Scrap from inventory" vs "Scrap from the selected location" distinction on the Lot Details screen. `Audit.LogEntityType` gains 1 row (ScrapSource) in Phase G. All four changes are additive — no breaking changes to existing procs or tests. SQL lands in Phase G migration `0010_phase9_tools_and_workorder.sql` alongside the Tools schema. Discovery items (OI-24..30) parked for MPP input. Source: `Meeting_Notes/2026-04-20_OI_Review_Status_Summary.md` v1.1 §"Additional discovered gaps" + `MPP_MES_Open_Issues_Register.md` v2.5. |
| 1.9i | 2026-04-27 | Blue Ridge Automation | **§3 ShippingLabel — UJ-18 Gateway-script-async print pattern.** `Lots.ShippingLabel` +5 columns: `PrintAttempts INT DEFAULT 0`, `LastPrintAttemptAt DATETIME2(3) NULL`, `LastPrintError NVARCHAR(2000) NULL`, `PrintFailedAt DATETIME2(3) NULL`, `TerminalLocationId BIGINT FK → Location.Location.Id NULL`. State derivation: Pending = `PrintedAt IS NULL AND PrintFailedAt IS NULL`; Completed = `PrintedAt IS NOT NULL`; Failed = `PrintFailedAt IS NOT NULL`. No separate queue table — print state lives on the audit row. FDS v0.11j companion. SQL deferred to Arc 2 Phase 7 alongside the rest of the Container schema. |
| 1.9h | 2026-04-27 | Blue Ridge Automation | **UJ-04 — `Lots.AimShipperIdPool` + `Lots.AimPoolConfig` for synchronous container closure (zero AIM latency).** Per Jacques's 2026-04-27 design lock: AIM Shipper IDs are pre-fetched into a local pool by a background Gateway script and consumed FIFO by `Container_Complete` synchronously — never blocks production on AIM availability. Container closure with an empty pool **hard fails** (rejects close, operator sees error, line stops). All Assembly Lines have dedicated terminals; AIM IDs attach to Containers only (never sub-assemblies / sub-LOTs). New `Lots.AimShipperIdPool` table: `AimShipperId` (the Honda-issued ID, UNIQUE), `FetchedAt`, `FetchedInterfaceLogId` FK → `Audit.InterfaceLog` (provenance), `ConsumedAt` / `ConsumedByContainerId` FK → `Lots.Container` / `ConsumedByUserId` FK → `Location.AppUser` (all NULL while available). Filtered index `IX_AimShipperIdPool_Available (FetchedAt) WHERE ConsumedAt IS NULL` drives the FIFO claim. **No reuse on void** — once `ConsumedAt` is set, the row never returns to available state regardless of subsequent container void / re-pack (Honda treats every issued ID as permanently consumed). **No expiry** — Honda doesn't TTL Shipper IDs. New `Lots.AimPoolConfig` single-row table (`Id INT CHECK Id=1`) holds the operator-configurable thresholds: `TargetBufferDepth INT DEFAULT 50`, `TopupThreshold INT DEFAULT 30` (topup script refills toward target when below this), `AlarmWarningDepth INT DEFAULT 20` (supervisor wallboard tile), `AlarmCriticalDepth INT DEFAULT 10` (supervisor alarm + IT notification). Configuration Tool exposes the four thresholds via `Lots.AimPoolConfig_Get` / `_Update`. Procs (Arc 2 Phase 7): `Lots.AimShipperIdPool_Claim` (atomic FIFO claim using `UPDATE TOP (1) WITH (UPDLOCK, READPAST, ROWLOCK) ... OUTPUT ... ORDER BY FetchedAt`, raises on empty pool — caller's transaction ROLLBACKs the container close), `_Topup`, `_GetDepth`, `_GetByContainer`. `Audit.LogEntityType` +2 rows (`AimShipperIdPool`, `AimPoolConfig`) at Arc 2 Phase 7. SQL deferred to Arc 2 Phase 7 (Container schema doesn't yet exist either). |
| 1.9g | 2026-04-27 | Blue Ridge Automation | **OI-21 — `Lots.PauseEvent` table for Pausable LOT at Workstation.** Per Jacques's 2026-04-27 design lock: pause is a (Lot, Location) lifecycle event — operator pauses a partially-progressed LOT at a Cell to attend to a different LOT at the same Cell, returns later (could be the next shift, by a different operator). New append-only table `Lots.PauseEvent` with open + close lifecycle (mirrors `Quality.HoldEvent` shape): `LotId`, `LocationId`, `PausedByUserId`, `PausedAt`, optional `PausedReason`, nullable `ResumedByUserId`/`ResumedAt`/`ResumedRemarks`. CHECK pairing on resume columns; filtered UNIQUE on `(LotId, LocationId) WHERE ResumedAt IS NULL` (at most one open pause per LOT-at-Location — same LOT MAY pause at multiple Cells simultaneously, e.g., Machining + Assembly partial-progress). No TTL — paused LOTs persist indefinitely; manual operational cleanup. Pause is **orthogonal** to `Workorder.WorkOrderStatus` and `Workorder.OperationStatus` — no `Paused` rows added to those code tables (WO/WOO are MVP-LITE/invisible per OI-07; pause is a LOT-level operator workflow concept). No `Paused` row added to `Lots.LotStatusCode` — pause is a transient operator focus shift, not a LOT quality status. `Audit.LogEntityType` +1 row (`PauseEvent`) at Arc 2 Phase 1 alongside the rest of the Lots schema CREATE. FDS-05-038 authoritative. SQL deferred to Arc 2 Phase 1 (Lots schema does not yet exist in the Phase 1–8 codebase). |
| 1.9f | 2026-04-24 | Blue Ridge Automation | **OI-16 additions — `RequiresCompletionConfirm` LocationAttribute on `Terminal`.** Per Jacques's 2026-04-24 OIR review: new `LocationAttributeDefinition` seed row on the `Terminal` `LocationTypeDefinition` with `Code='RequiresCompletionConfirm'`, `DataType='Boolean'`, `IsRequired=0` (NULL = no confirm button, treated as 0). Meaningful only on Dedicated Terminals (FDS-02-010). Toggles between "large Confirm Completion button" UX and passive popup UX on the Perspective Assembly view at WO/Tray/Container close. PLC confirmation BIT (expected tag name `CompletionConfirmed` on the MIP) is a Gateway-script concern — no schema column; observed via OPC tag reads and participates in the FDS-06-028 auto-close gate. Phase G LocationAttributeDefinition seed delta: +1 row for `RequiresCompletionConfirm`. No other schema changes. |
| 1.9e | 2026-04-24 | Blue Ridge Automation | **OI-23 — `Lots.v_LotDerivedQuantities` view for TotalInProcess / InventoryAvailable.** Per Jacques's 2026-04-24 OIR review: LOT derived quantities are computed via a SQL view, not materialized on the `Lots.Lot` row. No columns added to `Lots.Lot`. New view `Lots.v_LotDerivedQuantities (LotId, TotalInProcess, InventoryAvailable)` joins `Lots.Lot` with aggregations over `Workorder.ProductionEvent` (checkpoint counters: `Σ StartedCount − Σ CompletedCount − Σ ScrappedCount` grouped by LocationId) and `Workorder.ConsumptionEvent` (consumed quantities). Arc 2 Phase 2 migration creates the view. Read procs join it to base `Lots.Lot` at read time; no on-write maintenance. If performance becomes an issue post-MVP, the view MAY be replaced by an indexed view or materialized table without changing caller contracts. FDS-05-031 revised accordingly. |
| 1.9d | 2026-04-24 | Blue Ridge Automation | **OI-18 extension — `Parts.ItemLocation.LocationId` supports Area / WorkCenter / Cell granularity (hierarchy cascade).** Per Jacques's 2026-04-24 OIR review: `ItemLocation.LocationId` already FKs generically to `Location.Id` — no schema change needed. The semantics broaden: an `ItemLocation` row can designate eligibility at any tier (Area, WorkCenter, Cell). When a Part is checked into a specific Cell, compatibility checks cascade UP the Location hierarchy from the scanned Cell: if an `ItemLocation` row exists for the Cell, its ancestor WorkCenter, or its ancestor Area, the Part is eligible there. This enables rules like "Part 5G0 eligible across all of Die Cast Area" with one row, without enumerating every Cell. Consumption metadata (Min/Max/Default/IsConsumptionPoint) retained — orthogonal to the hierarchy extension, orthogonal to OI-12's `Item.MaxParts`. New helper proc spec: `Parts.ItemLocation_IsEligible(@ItemId, @CellLocationId)` walks the Location parentage up to Site looking for a matching `ItemLocation` row (walk stops at first match). No column changes; spec doc only this revision. |
| 1.9c | 2026-04-24 | Blue Ridge Automation | **OI-12 `MaxParts` moved from `Parts.ContainerConfig` to `Parts.Item`.** Jacques's 2026-04-24 OIR review flagged the original placement as fundamentally inaccurate — `MaxParts` is a **Part attribute** evaluated when inventory is checked into a Location, not a container-packing attribute. The column was originally added to `Parts.ContainerConfig` in v1.8 (landed Phase G migration `0010`); this revision relocates it. New column: `Parts.Item.MaxParts INT NULL` — hard cap on pieces of this Item allowed at any single Location. Scan-in mutation sums existing pieces of this Item at the destination Location + incoming quantity and rejects if the result would exceed `MaxParts`. Complements `LinesideLimit` (`LocationAttribute` on Cell, per-Location aggregate cap across all Items) — the two are orthogonal per Jacques's confirmation. SQL correction migration queued: DROP `Parts.ContainerConfig.MaxParts`, ADD `Parts.Item.MaxParts`, update FDS-03-019 + ERD + test suite `0019`. |
| 1.9b | 2026-04-24 | Blue Ridge Automation | **OI-07 correction — `Workorder.WorkOrderType` seed corrected to `Production` only.** Jacques clarified the 2026-04-20 meeting note was mis-recorded: the "Recipe" line was actually describing the **Production** work orders already modelled (MVP-LITE, auto-generated, invisible to operators), not a separate Recipe type. Under MPP's actual taxonomy, `Demand` = planned preventative maintenance (FUTURE) and `Maintenance` = emergency maintenance (FUTURE); neither is being built in this project. Seed changes (documented here; SQL correction migration queued — shipped Phase G migration `0010` has 3 rows at Ids 1/2/3 that need correcting via a follow-up migration): rename Id=1 `Demand`→`Production`, DELETE Ids 2 (`Maintenance`) and 3 (`Recipe`). Code table **mechanism** stays as a future hook — future maintenance-engine project INSERTs `Demand` and `Maintenance` rows without schema change. `Workorder.WorkOrder.ToolId` FK to `Tools.Tool` stays as a hook for future Maintenance WOs targeting a Tool. No changes to the code table schema itself. Downstream docs updated: OIR v2.9 OI-07 rewrite, FDS v0.11 §6.10 rename + FDS-06-027 deletion, Arc 2 Plan v0.2 overlay, ERD Workorder + Master tabs. |
| 1.9 | 2026-04-24 | Blue Ridge Automation | **Arc 2 model revisions (2026-04-23 session) — Tool/Cavity promoted to `Lots.Lot`, `Workorder.ProductionEvent` reshaped as checkpoint table, new `Lots.IdentifierSequence` table, `Parts.Item.MaxLotSize` semantic repurpose.** Four changes land:<br><br>**(1) `Lots.Lot` ADDs `ToolId BIGINT NULL FK → Tools.Tool.Id` and `ToolCavityId BIGINT NULL FK → Tools.ToolCavity.Id`.** Required at `Lot_Create` for die-cast-origin LOTs (validated against `ToolAssignment_ListActiveByCell` + Cavity belongs to Tool + Cavity Active). NULL for all other origins (Received, Trim / Machining intermediate, Assembly, Serialized). NULL after `Lot_Merge` on blended-origin LOTs. Downstream LOTs do NOT inherit — Honda-trace via `LotGenealogy` recursive traversal. Codifies OI-09: a die-cast machine with N active cavities produces **N parallel independent LOTs, not sublots** (each LOT fills at its own rate, closes independently, no parent/child FK between cavity peers). Pre-v1.9 `Lot.DieNumber NVARCHAR(50)` + `Lot.CavityNumber NVARCHAR(50)` columns are now legacy — retained in this release for any future migration script that needs them during cutover, slated for removal in a follow-up migration once all writers use the new FKs.<br><br>**(2) `Workorder.ProductionEvent` reshaped to checkpoint form.** Per FRS §2.1.2 operator-driven capture: operators visit terminals periodically (checkout from die cast, check-in to trim, complete + move, quality-operation transitions), not per-shot. Each checkpoint writes one event carrying cumulative counters; deltas derived via `LAG()` over `(LotId, EventAt)`. Columns ADDed: `ShotCount INT NULL` (cumulative at event time — **open item** OI-20/Decision 5: may migrate to derived-from-aggregated-LOT-quantity before Arc 2 Phase 3), `ScrapCount INT NULL` (cumulative), `EventAt DATETIME2(3)` (replaces `RecordedAt`), `AppUserId` (replaces `OperatorId` — align to initials-based model). Columns DROPPED: `LocationId` (derivable from `LotMovement` at `EventAt`), `DieIdentifier NVARCHAR(50)` + `CavityNumber INT` (derivable from `Lot.ToolId`/`Lot.ToolCavityId`), `GoodCount` + `NoGoodCount` (replaced by `ShotCount` cumulative with `LAG()`-derived delta — avoids compounding errors from missed events), `ItemId` (derivable from `Lot.ItemId`). Required index `(LotId, EventAt DESC)`. Table is still deferred to Arc 2 Phase 1 CREATE — the column contract in §4 is authoritative.<br><br>**(3) New `Lots.IdentifierSequence` table (OI-31).** Replaces Flexware's `IdentifierFormat`. Columns: `Id`, `Code NVARCHAR(30) UNIQUE`, `Name`, `Description`, `FormatString NVARCHAR(50)` (.NET `string.Format`, e.g., `MESL{0:D7}`), `StartingValue BIGINT DEFAULT 1`, `EndingValue BIGINT DEFAULT 9999999`, `LastValue BIGINT DEFAULT 0`, `ResetIntervalMinutes INT NULL`, `LastResetAt DATETIME2(3) NULL`, `UpdatedAt DATETIME2(3)`. Companion proc `Lots.IdentifierSequence_Next @Code` atomically increments `LastValue`, formats via the `.NET`-style string, raises on rollover. Seeded at cutover with `Lot` (`MESL{0:D7}`, ~1,710,932 baseline) and `SerializedItem` (`MESI{0:D7}`, ~2,492 baseline) — actual `LastValue` sampled from Flexware on cutover day. Lands in Arc 2 Phase 1 migration.<br><br>**(4) `Parts.Item.MaxLotSize` semantic repurpose.** No schema change — the column stays `INT NULL`. In this doc and the Config Tool Item screen the label/caption becomes **`PartsPerBasket`**: one LOT = one basket = one LTT label, so "max parts per LOT" IS "basket capacity" by definition. Basket (Item-level capacity) is distinct from Container (`Parts.ContainerConfig` with tray math for shipping — unchanged). Formal column rename deferred to a later migration.<br><br>**Other v1.9 notes:** `Tools.ToolAssignment` has **two** filtered unique indexes today (`UQ_ToolAssignment_ActiveTool` on `ToolId`, `UQ_ToolAssignment_ActiveCell` on `CellLocationId`). The Cell UNIQUE is correct for Die Cast (one mounted die per cell) but wrong for Machining / Trim / Assembly where multiple Tools coexist on a cell. Documented as a known limitation to resolve when non-Die Tool types go live post-MVP (scope the UNIQUE to `ToolType=Die` or drop it). Source: `docs/superpowers/specs/2026-04-23-arc2-model-revisions.md`. |
| 1.8-rev | 2026-04-22 | Blue Ridge Automation | **OI-11 reverted — Casting → Trim part rename resolved via 1-line BOM (no new schema).** The v1.8 draft added a dedicated `Parts.ItemTransform` table. On review it was redundant: every column duplicates `Workorder.ConsumptionEvent`. The Casting → Trim boundary is a **degenerate 1-line BOM consumption** — trim part has cast part as its sole component at QtyPer=1; the existing ConsumptionEvent + LotGenealogy flow captures the physical movement and backward trace; the operator prompt is BOM-driven ("receive as trim part?"). No `ItemTransform` table is created in Phase G or deferred to Arc 2. The Phase G migration's `Audit.LogEntityType` seed shrinks from 10 rows to 9 (removed `ItemTransform`; `ScrapSource` shifted from Id=40 to Id=39). OI-11 moves from ⬜ Open to ✅ Resolved in the Open Issues Register (v2.6). This row is a correction to the v1.8 entry above — the table count "~73" also drops back to "~72". |
| 1.7 | 2026-04-21 | Blue Ridge Automation | **Phase B Tool Management schema — Tool promoted to a first-class polymorphic subsystem (OI-10 superseded).** New `Tools` schema with 10 tables: `ToolType` (seeded read-only — Die/Cutter/Jig/Gauge/AssemblyFixture/TrimTool, `HasCavities` flag), `ToolAttributeDefinition` (per-type attribute schema mirroring `Location.LocationAttributeDefinition`), `Tool` (system of record for tool identity, nullable `DieRankId` for Die-type only, no shot counter — derived from `ProductionEvent`), `ToolAttribute` (values), `ToolCavity` (child of Tool for HasCavities types, 3-state Active/Closed/Scrapped status), `ToolAssignment` (append-only check-in/out history against Cells, filtered UNIQUE on active assignment), `ToolStatusCode` + `ToolCavityStatusCode` (read-only code tables), `DieRank` (empty seed — MPP Quality owes the list), `DieRankCompatibility` (empty seed — merge proc rejects cross-die merges until populated, supervisor AD override per FDS-04-007). `Workorder` gains `WorkOrderType` code table (Demand/Maintenance/Recipe, seeded read-only) and two columns on `Workorder.WorkOrder`: `WorkOrderTypeId BIGINT NOT NULL DEFAULT Demand-Id` (existing rows backfill to Demand) and `ToolId BIGINT NULL FK → Tools.Tool` (Maintenance WOs only — enforced at proc layer, not CHECK, because Recipe WOs legitimately have NULL ToolId). `Audit.LogEntityType` gets 8 new seed rows (Tool, ToolAttributeDefinition, ToolAttribute, ToolCavity, ToolAssignment, DieRank, DieRankCompatibility, WorkOrderType). Maintenance WO *flow* is FUTURE — schema hook only in MVP. Tool-life threshold alarms are FUTURE (scheduled Gateway Script pattern). Block concept (from 2026-04-20 meeting) dropped from Tools — handled by ISA-95 hierarchy + `Parts.ItemLocation` per Phase D / OI-08 addenda. Phase G migration `0010_phase9_tools_and_workorder.sql` delivers the SQL (~35 procs, ~60 tests); same migration drops the legacy `Location.AppUser.ClockNumber` + `.PinHash` columns deferred from Phase C. Full design spec: `docs/superpowers/specs/2026-04-21-tool-management-design.md` v0.2. |
| 1.6 | 2026-04-21 | Blue Ridge Automation | **AppUser schema realigned to the initials-based security model (OI-06 closed — Phase C of the 2026-04-20 OI review refactor).** `AppUser` now carries `Initials NVARCHAR(10) NOT NULL UNIQUE` as its universal shop-floor stamp. `AdAccount` becomes NULL-capable (filtered UNIQUE where NOT NULL) so Operator-class rows can exist without an AD identity. Added CHECK constraint `IgnitionRole IS NULL OR AdAccount IS NOT NULL`. `ClockNumber` and `PinHash` columns marked legacy — they remain in the Phase 1–8 live schema but will be dropped in the Phase G Tool & Security migration, along with the `AppUser_SetPin` and `AppUser_GetByClockNumber` procs. No changes to event tables — user attribution via `AppUserId` FK already resolves transparently from initials at the UI layer. |
| 1.5 | 2026-04-15 | Blue Ridge Automation | **Phase 8 Oee reference tables built.** Migration `0009_phase8_oee_reference.sql` creates `Oee.DowntimeReasonType` (6 seeded rows, read-only), `Oee.DowntimeReasonCode` (mutable, FK to Area Location + nullable ReasonType + nullable SourceCode), `Oee.ShiftSchedule` (mutable, `DaysOfWeekBitmask INT` with Mon=1…Sun=64 and CHECK 1-127, `TIME(0)` start/end), and `Oee.Shift` (runtime instances). +1 `Audit.LogEntityType` row (ShiftSchedule at Id=30). 13 new procs including a JSON-fed `DowntimeReasonCode_BulkLoadFromSeed` that maps CSV `DeptCode` (DC/MS/TS) to three caller-supplied Area Location Ids and generates unique `Code` as `{DeptCode}-{NNNN}` from zero-padded `ReasonId`. Dev seed updated with Trim Shop Area row. 779/779 tests passing. |
| 1.4 | 2026-04-15 | Blue Ridge Automation | **Production data collection capture — closing the template→event gap.** `OperationTemplate` + `OperationTemplateField` + `DataCollectionField` define *what* to collect at an operation, but nothing persisted *what was actually collected* when a LOT passed through. Fixed by extending `Workorder.ProductionEvent` and adding a new child table: (1) added `OperationTemplateId BIGINT FK → Parts.OperationTemplate NOT NULL` to tie each event to the template it executed under (previously only inferable via WorkOrderOperation→RouteStep, which is unreliable given OI-07's background-only work orders); (2) added hot typed columns `DieIdentifier NVARCHAR(50) NULL` (die name/number captured from the machine's `LocationAttribute` value at event time — NOT an FK to Location; OI-10 tool life may later add a parallel `DieId BIGINT FK` if a `Die` table is introduced), `CavityNumber INT NULL`, `WeightValue DECIMAL(10,3) NULL`, `WeightUomId BIGINT FK → Parts.Uom NULL`; (3) new `Workorder.ProductionEventValue` child keyed by `(ProductionEventId, DataCollectionFieldId)` with `Value NVARCHAR(255)` + `NumericValue DECIMAL(18,4) NULL` for any field not promoted to a hot column (extensible vocabulary path). UI behavior: the die-cast screen reads `OperationTemplateField` to render the required inputs; submit writes one `ProductionEvent` header + N `ProductionEventValue` children. Phase 8 procs to implement. |
| 1.3 | 2026-04-14 | Blue Ridge Automation | **Phase 6 BOM Management built + Phase 5 Draft/Published retrofit.** Migration `0007_bom_and_route_publish.sql` creates `Parts.Bom` (versioned, Draft/Published/Deprecated states via `PublishedAt DATETIME2(3) NULL` + existing `DeprecatedAt`) and `Parts.BomLine` (no soft-delete — hard DELETE with SortOrder compaction; filtered unique index `UQ_BomLine_Bom_ChildItem` prevents duplicate child references in one BOM). Same migration ALTERs `Parts.RouteTemplate` to add `PublishedAt DATETIME2(3) NULL` — retroactive three-state model for Phase 5. Drafts are mutable but invisible to production; `_GetActiveForItem` procs filter `PublishedAt IS NOT NULL`. Published rows are immutable — BomLine/RouteStep mutations reject on published parents. New procs: `Bom_{Publish, ListByParentItem, Get, GetActiveForItem, Create, CreateNewVersion, Deprecate, WhereUsedByChildItem}` (8), `BomLine_{Add, Update, MoveUp, MoveDown, Remove, ListByBom}` (6), `RouteTemplate_Publish` (1) = 15 new procs. Phase 5 retrofit also updated 5 RouteStep mutation procs to reject on published parents. Audit.LogEntityType +1 (BomLine at Id=27). Audit.FailureLog_GetTopReasons enhanced with optional `@ProcedureName` filter (legitimate production feature + test-noise mitigation). 2 new test files + 1 updated (Phase 5), ~100 new assertions. Full suite now 737/737. |
| 1.2 | 2026-04-14 | Blue Ridge Automation | **Phase 5 Process Definition built and tested.** Migration `0006_routes_operations_eligibility.sql` creates 5 tables: `Parts.OperationTemplate` (versioned, clone-to-modify), `Parts.OperationTemplateField`, `Parts.RouteTemplate` (versioned per Item), `Parts.RouteStep` (no soft-delete — hard DELETE scoped to un-deprecated parent routes; production history preserved via the immutable route snapshot), `Parts.ItemLocation` (eligibility junction with active/deprecated toggle). Filtered unique indexes enforce active-set semantics: `UQ_OperationTemplate_Code_Version`, `UQ_OperationTemplateField_ActiveTemplateField`, `UQ_RouteTemplate_Item_Version`, `UQ_ItemLocation_ActiveItemLocation`. 21 new stored procedures: OperationTemplate ×5 + OperationTemplateField ×3 + RouteTemplate ×5 + RouteStep ×6 + ItemLocation ×4 (ListByItem/Add + reactivate/ListByLocation/Remove). 3 new test files, ~145 new assertions. Full suite now 637/637 passing. One test correctness fix along the way: historical-AsOfDate test needed v1.EffectiveFrom backdated so the AsOf window actually catches v1 (Create and CreateNewVersion ran milliseconds apart in test). |
| 1.0 | 2026-04-14 | Blue Ridge Automation | **Phase 4 Item Master + Container Config built and tested.** Migration `0005_item_master_container_config.sql` creates `Parts.Item` with full user attribution (`CreatedAt`, `UpdatedAt`, `CreatedByUserId FK`, `UpdatedByUserId FK`) and `Parts.ContainerConfig` with Honda packing rules plus the OI-02 columns `ClosureMethod NVARCHAR(20) NULL` and `TargetWeight DECIMAL(10,4) NULL` added proactively as nullable pending MPP customer validation of scale-driven container closure. Filtered unique index `UQ_ContainerConfig_ActiveItemId` enforces one active config per Item at the schema level. 10 new stored procedures (6 Item + 4 ContainerConfig), ~80 new tests. Bulk-load proc deferred — will be written once MPP supplies a parts-list export format. Also fixed `Parts.Uom_Deprecate` column reference bug (was checking `DefaultUomId`, corrected to `UomId OR WeightUomId`). Full suite now 509/509 passing. |
| 0.9 | 2026-04-13 | Blue Ridge Automation | **Phase 3 reference lookups built and tested.** Migration `0004_phase3_reference_lookups.sql` creates 16 code tables across 5 schemas: `Lots.LotOriginType`, `Lots.LotStatusCode` (with `BlocksProduction` flag), `Lots.ContainerStatusCode`, `Lots.GenealogyRelationshipType`, `Lots.PrintReasonCode`, `Lots.LabelTypeCode`, `Quality.InspectionResultCode`, `Quality.SampleTriggerCode`, `Quality.HoldTypeCode`, `Quality.DispositionCode`, `Oee.DowntimeSourceCode`, `Workorder.OperationStatus`, `Workorder.WorkOrderStatus`, `Parts.Uom`, `Parts.ItemType`, `Parts.DataCollectionField`. Read-only tables (13) carry just `{Id, Code, Name}` (+ `BlocksProduction` on LotStatusCode). Mutable tables (3) carry `{Id, Code, Name, Description, CreatedAt, DeprecatedAt}`. All seeded with deterministic Ids. `Workorder.WorkOrderStatus` seed values were PascalCased (Created/InProgress/Completed/Cancelled — the data model had stale UPPER_SNAKE_CASE). `Lots.LabelTypeCode` values were proposed from Honda shipping conventions (Primary/Container/Master/Void) as the data model didn't enumerate them. Added 2 new `Audit.LogEntityType` rows (Uom, ItemType). 41 new stored procedures (26 read-only List/Get + 15 mutable CRUD). 117 new tests (440 total now passing). |
| 0.8 | 2026-04-13 | Blue Ridge Automation | Added `Icon NVARCHAR(100) NULL` column to `LocationTypeDefinition` for Perspective Tree component icon mapping. Values are intentionally left NULL at deployment — they'll be populated via the Config Tool once the `LocationTypeDefinition` CRUD frontend is built. The Jython tree builder falls back to a default icon when NULL. Added seed script (`sql/seeds/seed_locations.sql`) with 12 Location rows spanning all 5 ISA-95 tiers for dev/test. |
| 0.7 | 2026-04-13 | Blue Ridge Automation | **Architectural refactor — 4 changes for polymorphism, consistency, and template portability.** (1) **Free-text enums → code tables:** Added 7 new code tables (`Lots.PrintReasonCode`, `Lots.LabelTypeCode`, `Quality.InspectionResultCode`, `Quality.SampleTriggerCode`, `Quality.HoldTypeCode`, `Quality.DispositionCode`, `Oee.DowntimeSourceCode`) and replaced corresponding `NVARCHAR` columns with `BIGINT FK` references on `LotLabel`, `ShippingLabel`, `QualitySample`, `NonConformance`, `DowntimeEvent`. (2) **CreatedBy/UpdatedBy → FK:** Replaced 8 free-text `NVARCHAR` user-attribution columns with `BIGINT FK → AppUser.Id` across `Item`, `Bom`, `RouteTemplate`, `QualitySpecVersion`, `LocationAttribute`, `QualityAttachment`, `NonConformance`, `Lot`, `ShippingLabel`. (3) **HoldEvent refactored:** Retained as a single table (same place/release lifecycle as `DowntimeEvent`). Replaced free-text `HoldType NVARCHAR` with `HoldTypeCodeId BIGINT FK → HoldTypeCode.Id`. (4) **OperationTemplate data collection configurable:** Removed 7 hardcoded `BIT` flags, added `Parts.DataCollectionField` code table and `Parts.OperationTemplateField` junction with `IsRequired` and `DeprecatedAt`. Net: +11 new tables, −1 removed (`HoldEvent`), ~60 tables total. Conventions updated: enum/status code-table rule broadened, user-attribution convention added. ERD and Phased Plan updated to match. |

---

## Conventions

- `UpperCamelCase` singular noun table and column names (e.g., `LocationType`, `PieceCount`, `CreatedAt`)
- Surrogate `BIGINT Id` primary keys (auto-increment) — natural keys are unique-indexed columns
- `DeprecatedAt DATETIME2(3) NULL` for soft deletes (non-null = inactive)
- `DATETIME2(3)` for all timestamps (millisecond precision)
- `DECIMAL(x,y)` for measurements — never `FLOAT`
- UOM as an explicit column on every quantitative field
- All enum and status values are code-table backed with FK — no free-text enums, no magic integers
- `CreatedAt`, `UpdatedAt`, `CreatedBy`, `UpdatedBy` on mutable entities
- Append-only tables (events, movements, logs) have `CreatedAt` only — no updates
- User attribution via `BIGINT FK → AppUser.Id` — never free-text username strings

---

## 1. Location Schema — `MVP`

> **Scope:** All tables MVP. Foundation schema — every other schema references location.

Self-referential ISA-95 plant hierarchy with a three-tier classification model: **Type** (ISA-95 tier) → **Definition** (polymorphic kind within a tier) → **Attribute** (configurable metadata per kind).

### Design Overview

The location model uses three classification tables to support polymorphic location kinds within each ISA-95 hierarchy tier:

1. **`LocationType`** — the broad ISA-95 category (Enterprise, Site, Area, Work Center, Cell). Five rows total. Defines the hierarchy tier.
2. **`LocationTypeDefinition`** — the specific *kind* of a location within a type. For the `Cell` type, definitions include `Terminal`, `DieCastMachine`, `CNCMachine`, `InventoryLocation`, `Scale`, etc. Every location has a definition.
3. **`LocationAttributeDefinition`** — the attribute schema for a given kind. A `Terminal` definition has attributes like `IpAddress`, `DefaultPrinter`, `HasBarcodeScanner`. A `DieCastMachine` definition has `Tonnage`, `RefCycleTimeSec`. Different definitions carry different attribute sets. (Cavity count is **not** a press attribute — cavities belong to the die; see `Tools.Tool` / `Tools.ToolCavity` in §7.)
4. **`Location`** — an actual node in the plant model. FKs to `LocationTypeDefinition` (which determines both its type and its attribute schema) and to its parent location.
5. **`LocationAttribute`** — attribute values for a specific location, constrained by its definition's attribute schema.

**Analogy:** If `LocationType` is "Writing Implements," then `LocationTypeDefinition` rows are "Pen," "Pencil," "Marker" — each with their own attributes. A specific "Bic ballpoint, black" is a `Location` of definition "Pen."

### LocationType

The five ISA-95 equipment hierarchy tiers. Seeded at deployment; not operator-editable.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Code | NVARCHAR(20) | NOT NULL, UNIQUE | Short code (Enterprise, Site, Area, WorkCenter, Cell) |
| Name | NVARCHAR(100) | NOT NULL | Display name |
| HierarchyLevel | INT | NOT NULL | 0=Enterprise, 1=Site, 2=Area, 3=WorkCenter, 4=Cell |
| Description | NVARCHAR(500) | NULL | |

**Seeded rows:**

| Code | Name | HierarchyLevel | Description |
|---|---|---|---|
| Enterprise | Enterprise | 0 | Top-level organization (MPP Inc.) |
| Site | Site | 1 | Physical plant/facility |
| Area | Area | 2 | Subdivision within a site (Die Cast, Trim Shop, Machine Shop, Production Control, Quality Control) |
| WorkCenter | Work Center | 3 | Production line or grouping of equipment (ISA-95 Work Center) |
| Cell | Cell | 4 | Individual station/unit (ISA-95 Work Unit) — machines, terminals, inventory locations, scales |

### LocationTypeDefinition

Polymorphic *kinds* within each `LocationType`. Every `Location` row references one definition, which determines both its ISA-95 tier (via `LocationTypeId`) and its attribute schema (via the attached `LocationAttributeDefinition` rows).

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| LocationTypeId | BIGINT | FK → LocationType.Id, NOT NULL | Which ISA-95 tier this kind belongs to |
| Code | NVARCHAR(50) | NOT NULL, UNIQUE | Short code (e.g., Terminal, DieCastMachine) |
| Name | NVARCHAR(100) | NOT NULL | Display name |
| Description | NVARCHAR(500) | NULL | |
| Icon | NVARCHAR(100) | NULL | Perspective icon path (e.g., `material/precision_manufacturing`). Used by tree components. NULL falls back to a default. |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT GETDATE() | |
| DeprecatedAt | DATETIME2(3) | NULL | |

**Seeded definitions (initial set — extensible):**

| LocationType | Definition Code | Purpose |
|---|---|---|
| Enterprise | Organization | The company root node (single row) |
| Site | Facility | A physical manufacturing plant |
| Area | ProductionArea | Production areas (Die Cast, Trim, Machining, Assembly) |
| Area | SupportArea | Support areas (Production Control, Quality Control, Shipping, Receiving) |
| WorkCenter | ProductionLine | Generic production line within an area |
| WorkCenter | InspectionLine | Multi-part inspection lines (e.g., MS1FM-1028) |
| Cell | Terminal | Operator HMI station — mode derived from parent tier (Cell-parent = Dedicated; WorkCenter- or Area-parent = Shared, per FDS-02-010) |
| Cell | DieCastMachine | Die cast press |
| Cell | CNCMachine | Machining center / CNC cell |
| Cell | TrimPress | Trim shop press |
| Cell | AssemblyStation | Manual assembly station |
| Cell | SerializedAssemblyLine | PLC-integrated serialized assembly (5G0, etc.) |
| Cell | InspectionStation | Manual or vision-based inspection station |
| Cell | InventoryLocation | WIP storage, receiving dock, shipping dock, Sort Cage |
| Cell | Scale | OmniServer-connected weight scale |

### LocationAttributeDefinition

Attribute schema per `LocationTypeDefinition`. Each definition carries its own set of configurable attributes.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| LocationTypeDefinitionId | BIGINT | FK → LocationTypeDefinition.Id, NOT NULL | Which kind this attribute belongs to |
| AttributeName | NVARCHAR(100) | NOT NULL | e.g., `Tonnage`, `IpAddress`, `DefaultPrinter` |
| DataType | NVARCHAR(50) | NOT NULL | INT, DECIMAL, BIT, VARCHAR |
| IsRequired | BIT | NOT NULL, DEFAULT 0 | Must every location of this definition carry a value? |
| DefaultValue | NVARCHAR(255) | NULL | Default if not explicitly set |
| Uom | NVARCHAR(20) | NULL | Unit of measure for this attribute |
| SortOrder | INT | NOT NULL, DEFAULT 0 | Display ordering on config screens |
| Description | NVARCHAR(500) | NULL | |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT GETDATE() | |
| DeprecatedAt | DATETIME2(3) | NULL | |

**Example attribute sets (illustrative — not exhaustive):**

*For `Cell` → `Terminal` definition:*

| AttributeName | DataType | Required | Uom | Description |
|---|---|---|---|---|
| IpAddress | NVARCHAR | No | — | Terminal IP address for diagnostics |
| DefaultPrinter | NVARCHAR | No | — | Associated Zebra printer name for label output |
| HasBarcodeScanner | BIT | Yes | — | Whether terminal has scanner hardware |

*For `Cell` → `DieCastMachine` definition:*

| AttributeName | DataType | Required | Uom | Description |
|---|---|---|---|---|
| Tonnage | DECIMAL | No | tons | Die cast press tonnage |
| RefCycleTimeSec | DECIMAL | No | seconds | Reference cycle time for OEE performance calculation |
| OeeTarget | DECIMAL | No | — | Target OEE (0.00–1.00). FUTURE — designed for but not used in MVP. |

> **Cavity count is not a press attribute.** Cavities belong to the die that's currently mounted on the press, not to the press itself. See `Tools.Tool` (`HasCavities=1` for Die-type Tools) and `Tools.ToolCavity` in §7. The press's cavity behavior changes with each die change; the data model captures that via `Tools.ToolAssignment` (which die is currently on which Cell) rather than as a fixed press attribute.

*For `Cell` → `InventoryLocation` definition:*

| AttributeName | DataType | Required | Uom | Description |
|---|---|---|---|---|
| IsPhysical | BIT | Yes | — | Physical location vs. logical bucket |
| IsLineside | BIT | No | — | Whether this is a lineside staging area |
| MaxLotCapacity | INT | No | — | Maximum LOTs that can be stored here |
| LinesideLimit | INT | No | pieces | Maximum total pieces allowed on this lineside location at one time (sum across **all Items**, all open LOTs at this Location). Scan-in mutation rejects when cumulative lineside quantity would exceed this. Added v1.8 (OI-12). Complements `Parts.Item.MaxParts` — `MaxParts` is Item-scoped (cap on one Item at one Location); `LinesideLimit` is Location-scoped (cap across everything at that Location). |

> The `CNCMachine` definition's machining→assembly auto-move pairing is **not** an EAV attribute — `CoupledDownstreamCellLocationId` is a typed self-FK column on `Location.Location` (see the Location table below). Promoted out of the attribute model in v1.9p because it is a `Location → Location` relationship read on the hot path of every coupled Machining OUT (FDS-06-008).

### Location

Every node in the plant model — self-referential hierarchy. Each location references a single `LocationTypeDefinition`, which determines both its ISA-95 tier and its attribute schema.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| LocationTypeDefinitionId | BIGINT | FK → LocationTypeDefinition.Id, NOT NULL | Determines both ISA-95 tier (via join) and attribute schema |
| ParentLocationId | BIGINT | FK → Location.Id, NULL | Parent in hierarchy (NULL = root/Enterprise) |
| Name | NVARCHAR(200) | NOT NULL | Display name |
| Code | NVARCHAR(50) | NOT NULL, UNIQUE | Short identifier (barcode-scannable for machines) |
| Description | NVARCHAR(500) | NULL | |
| SortOrder | INT | NOT NULL, DEFAULT 0 | Display ordering among siblings. Auto-incremented on creation, updated via move-up/move-down operations. |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT GETDATE() | |
| DeprecatedAt | DATETIME2(3) | NULL | |
| CoupledDownstreamCellLocationId | BIGINT | FK → Location.Id (self), NULL | **Typed column (was a `CNCMachine` LocationAttribute pre-v1.9p).** On a Machining Cell, the `Location.Id` of the Cell that machined LOTs auto-move to on Machining OUT (FDS-06-008) — typically the paired Assembly Cell in the same WorkCenter. When non-NULL, PLC-signalled machining completion writes a `Workorder.ProductionEvent` + a `Lots.LotMovement` from this Cell to the referenced Cell and updates the LOT's `CurrentLocationId` — no operator scan. NULL = uncoupled/legacy path: completion writes the `ProductionEvent` only and the LOT stays put awaiting operator-driven movement. The self-FK gives referential integrity; the "target must be a Cell-tier (Assembly) Location" rule is enforced by the Arc 2 write/config-save proc, not a CHECK (mirrors `Tools.ToolType.CompatibleLocationTypeDefinitionId`). Migration `0019_location_coupled_downstream_cell`. |

> Note: `LocationType` is not stored directly on `Location`; it's derivable via `LocationTypeDefinition.LocationTypeId`. Hierarchy queries use `ParentLocationId` (adjacency list) and join through `LocationTypeDefinition` when tier-based filtering is needed.

> **Why `CoupledDownstreamCellLocationId` is a typed self-FK, not a `LocationAttribute` (v1.9p):** it is a `Location → Location` relationship read on the hot path of every coupled Machining-OUT completion. As an EAV `LocationAttribute.AttributeValue NVARCHAR(255)` it carried no referential integrity (could dangle to a deprecated / non-Cell row) and forced a string→Id pivot per event. Promoted to a typed column **before** the Arc 2 auto-move flow consumes it (cheapest moment — it was spec'd but never seeded, so no value backfill). The generic LocationAttribute editor no longer manages it; surfacing it in `Location_Get` + a Config Tool Cell-picker dropdown is Arc 2 wiring — the column exists and is integrity-checked now.

### LocationAttribute

Actual attribute values per location, constrained by the location's definition.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| LocationId | BIGINT | FK → Location.Id, NOT NULL | |
| LocationAttributeDefinitionId | BIGINT | FK → LocationAttributeDefinition.Id, NOT NULL | Which attribute (must belong to the location's definition) |
| AttributeValue | NVARCHAR(255) | NOT NULL | Stored as string, parsed per `LocationAttributeDefinition.DataType` |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT GETDATE() | |
| UpdatedAt | DATETIME2(3) | NULL | |
| UpdatedByUserId | BIGINT | FK → AppUser.Id, NULL | |

**Integrity rule:** A `LocationAttribute.LocationAttributeDefinitionId` SHALL reference an attribute definition whose `LocationTypeDefinitionId` matches the location's `LocationTypeDefinitionId`. Enforced via application logic or trigger — no direct SQL constraint expresses this without a redundant column.

### Terminals in the New Model

> ✅ **RESOLVED — OI-08 / UJ-12 / FDS-02-009/010/011:** Terminal mode is derived from the parent Location's ISA-95 tier — there is no `TerminalMode` LocationAttribute. Cell-parented terminals operate in **Dedicated** mode (Cell context = parent Cell, fixed, no selector). WorkCenter- or Area-parented terminals operate in **Shared** mode (operator selects the active Cell at session start by scan **or** dropdown, MAY switch mid-session by either mechanism). Descendant Cells of the terminal's parent Location define the eligible context set on Shared terminals.

In the polymorphic model, `Terminal` is a `LocationTypeDefinition` under the `Cell` type — it's one of many kinds of Cells. A `DieCastMachine` is another kind of Cell. Both are Cell-tier locations but carry entirely different attribute schemas.

Event tables carry two location references when both operator position and machine context matter:
- `TerminalLocationId` — FK → `Location.Id` where the definition is `Terminal` (where the operator is standing)
- `LocationId` — FK → `Location.Id` where the definition is a machine kind (the active Cell context — either fixed by parent on Dedicated terminals or selected by scan/dropdown on Shared terminals)

### AppUser

MES users in two classes (FDS §4):

- **Operator** rows — `AdAccount` NULL, `IgnitionRole` NULL. Identified by initials entered at a terminal; no authentication. Managed via the Configuration Tool Admin screen.
- **Interactive User** rows (Quality, Supervisor, Engineering, Admin) — `AdAccount` NOT NULL, `IgnitionRole` NOT NULL. Authenticate via Active Directory.

Roles managed in Ignition (mapped to AD groups for interactive users).

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Initials | NVARCHAR(10) | NOT NULL, UNIQUE | Shop-floor identification stamp. All classes carry this. Initials populate the Initials field on every shop-floor mutation screen. |
| AdAccount | NVARCHAR(100) | NULL, filtered UNIQUE where NOT NULL | Active Directory identity. NULL for Operator class, NOT NULL for Interactive Users. |
| DisplayName | NVARCHAR(200) | NOT NULL | |
| IgnitionRole | NVARCHAR(100) | NULL | NULL for Operator class. References Ignition's internal role config for Interactive Users. |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT GETDATE() | |
| DeprecatedAt | DATETIME2(3) | NULL | |

**Check constraint:** `IgnitionRole IS NULL OR AdAccount IS NOT NULL` — an Operator (no AD) cannot carry an Ignition role; roles apply only to AD-backed users.

**Legacy columns to be removed in the Phase G Tool & Security migration** (Phase G of the 2026-04-20 OI review refactor): `ClockNumber NVARCHAR(20)` and `PinHash NVARCHAR(255)` are no longer used by the design. They remain in the live schema from Phases 1–8 and will be dropped alongside the related procs (`AppUser_SetPin`, `AppUser_GetByClockNumber`) when Phase G runs.

---

## 2. Parts Schema — `MVP`

> **Scope:** All tables MVP. Master data schema — items, BOMs, routes, and container configs support core LOT lifecycle and shipping.

Item master, bills of material, routes, operation templates, container configurations.

**Views (v1.9l):** `Parts.v_EffectiveItemLocation (LocationId, ItemId, Source)` — fronts the FDS-02-012 eligibility check at scan-in. Computes the union of two paths: **Direct** = a `Parts.ItemLocation` row exists for the LOT's `ItemId` at the scanned Cell or any ancestor tier (per FDS-03-014 hierarchy cascade — Cell → WorkCenter → Area → Site); **BomDerived** = the LOT's `ItemId` appears as a child line on the active `Parts.Bom` of any Item whose Direct eligibility resolves at this Cell. A LOT is eligible if **either** path matches. Active BOM membership requires `Parts.Bom.PublishedAt IS NOT NULL AND Parts.Bom.DeprecatedAt IS NULL`. The `Source` column distinguishes `Direct` vs `BomDerived` for diagnostic queries; the eligibility check itself only cares whether *any* row exists. Consumed by the `Parts.ItemLocation_CheckEligibility` proc that fronts every scan-in mutation. Avoids the configuration explosion of enumerating every pass-through component (e.g., a 20-line BOM × N assembly Cells = 20N rows). Created in the Arc 2 Phase 1 migration alongside `Parts.ItemLocation_CheckEligibility`. See FDS-02-012 for the eligibility resolution rule.

### ItemType

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Name | NVARCHAR(100) | NOT NULL | Raw Material, Component, Sub-Assembly, Finished Good, Pass-Through |
| Description | NVARCHAR(500) | NULL | |

### Uom

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Code | NVARCHAR(10) | NOT NULL, UNIQUE | EA, LB, KG, etc. |
| Name | NVARCHAR(50) | NOT NULL | |

### Item

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| ItemTypeId | BIGINT | FK → ItemType.Id, NOT NULL | |
| PartNumber | NVARCHAR(50) | NOT NULL, UNIQUE | MPP part number |
| Description | NVARCHAR(500) | NULL | |
| MacolaPartNumber | NVARCHAR(50) | NULL | ERP cross-reference |
| DefaultSubLotQty | INT | NULL | Default pieces per sub-LOT split. Used at **Machining OUT** when a machined LOT is split across N downstream destinations on a sublotting line (per FDS-05-009). |
| MaxLotSize | INT | NULL | **Repurposed v1.9 as `PartsPerBasket`.** One LOT = one basket = one LTT label at Die Cast / Trim / intermediate Machining, so "max parts per LOT" IS basket capacity. Config Tool Item screen labels this field `PartsPerBasket`. Distinct from `MaxParts` (see next row). Formal column rename deferred. |
| MaxParts | INT | NULL | **Added v1.9c (OI-12 correction).** Hard cap on pieces of this Item allowed at any single Location (e.g., "no more than 500 5G0 parts at any one Cell"). Scan-in mutation (LotMovement to a Cell) sums existing pieces of this Item already present at the destination Location across all open LOTs + incoming quantity; rejects if result > `MaxParts`. Complements `LinesideLimit` (LocationAttribute on Cell — per-Location aggregate cap across **all** Items). Stops operators from over-scanning to avoid re-scan friction. |
| UomId | BIGINT | FK → Uom.Id, NOT NULL | Counting UOM |
| UnitWeight | DECIMAL(10,4) | NULL | Weight per piece |
| WeightUomId | BIGINT | FK → Uom.Id, NULL | Weight UOM |
| CountryOfOrigin | NVARCHAR(2) | NULL | ISO 3166-1 alpha-2 country code (e.g., `US`, `JP`, `MX`). Honda compliance surface — appears on genealogy and shipping output. Added v1.8 (OI-19). |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT GETDATE() | |
| UpdatedAt | DATETIME2(3) | NULL | |
| CreatedByUserId | BIGINT | FK → AppUser.Id, NOT NULL | |
| UpdatedByUserId | BIGINT | FK → AppUser.Id, NULL | |
| DeprecatedAt | DATETIME2(3) | NULL | |

### Bom

Versioned bill of materials header. **Three-state lifecycle** via `PublishedAt` + `DeprecatedAt`: Draft (both NULL) → Published (`PublishedAt` NOT NULL) → Deprecated (`DeprecatedAt` NOT NULL). Drafts are mutable but invisible to production's `GetActiveForItem`. Published BOMs are immutable — lines can't be added/updated/moved/removed; use `_CreateNewVersion` to fork a new Draft. Same model as `RouteTemplate`.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| ParentItemId | BIGINT | FK → Item.Id, NOT NULL | The product this BOM is for |
| VersionNumber | INT | NOT NULL | Versioning within the (ParentItemId) family. UNIQUE(ParentItemId, VersionNumber). |
| EffectiveFrom | DATETIME2(3) | NOT NULL | When this version becomes active (gated by PublishedAt for production selection) |
| PublishedAt | DATETIME2(3) | NULL | NULL = Draft (mutable, invisible to production). Non-NULL = Published (immutable, visible). Set by `Bom_Publish`. |
| DeprecatedAt | DATETIME2(3) | NULL | Non-NULL = Retired. |
| CreatedByUserId | BIGINT | FK → AppUser.Id, NOT NULL | |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT GETDATE() | |

### BomLine

Individual components within a BOM.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| BomId | BIGINT | FK → Bom.Id, NOT NULL | |
| ChildItemId | BIGINT | FK → Item.Id, NOT NULL | Component part |
| QtyPer | DECIMAL(10,4) | NOT NULL | Quantity per parent |
| UomId | BIGINT | FK → Uom.Id, NOT NULL | |
| SortOrder | INT | NOT NULL, DEFAULT 0 | |

### RouteTemplate

Versioned manufacturing route for a product. **Three-state lifecycle** via `PublishedAt` + `DeprecatedAt` (same pattern as `Bom`): Draft → Published → Deprecated. Drafts are mutable (RouteSteps can be added/updated/moved/removed) but invisible to production. Published routes are immutable.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| ItemId | BIGINT | FK → Item.Id, NOT NULL | |
| VersionNumber | INT | NOT NULL | UNIQUE(ItemId, VersionNumber). |
| Name | NVARCHAR(200) | NOT NULL | |
| EffectiveFrom | DATETIME2(3) | NOT NULL | |
| PublishedAt | DATETIME2(3) | NULL | NULL = Draft. Non-NULL = Published (immutable). Set by `RouteTemplate_Publish`. |
| DeprecatedAt | DATETIME2(3) | NULL | |
| CreatedByUserId | BIGINT | FK → AppUser.Id, NOT NULL | |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT GETDATE() | |

### RouteStep

Ordered steps within a route.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| RouteTemplateId | BIGINT | FK → RouteTemplate.Id, NOT NULL | |
| OperationTemplateId | BIGINT | FK → OperationTemplate.Id, NOT NULL | What happens at this step |
| SequenceNumber | INT | NOT NULL | Execution order |
| IsRequired | BIT | NOT NULL, DEFAULT 1 | |
| Description | NVARCHAR(500) | NULL | |

### OperationTemplate

Defines what data to collect at a type of operation. Reusable across products. **Versioned** via `Code` + `VersionNumber` — multiple rows share a Code to represent the evolution of one operation over time. See the clone-to-modify workflow in the Phase 5 `_CreateNewVersion` proc.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Code | NVARCHAR(20) | NOT NULL | Operation family code (e.g., DIE-CAST-801T). Multiple rows may share this value across versions. |
| VersionNumber | INT | NOT NULL, DEFAULT 1 | Version within the Code family. UNIQUE(Code, VersionNumber) enforces one row per version. |
| Name | NVARCHAR(100) | NOT NULL | |
| AreaLocationId | BIGINT | FK → Location.Id, NOT NULL | Area (ISA-95 Area, organizational grouping) |
| Description | NVARCHAR(500) | NULL | |
| RequiresSubLotSplit | BIT | NOT NULL, DEFAULT 0 | **Added v1.9m; relocated to Machining OUT in v1.9n.** Control flag for outbound flows that split a LOT across multiple downstream destinations (used at **Machining OUT** per FDS-05-009 — the physical correlate is a line with a dedicated Machining OUT terminal). When `1`, the Machining OUT screen presents a multi-destination split UX (one sub-LOT per destination, N total); the closing proc (`MachiningOut_RecordSplit`) calls `Lot_Split` and `Lot_MoveTo` per child. When `0` (default), Machining OUT is the PLC-driven auto-move (coupled) or a manual whole-move (uncoupled) — no split. Engineering authors per Item per Cell via the Configuration Tool. Versioned with the rest of the row per the clone-to-modify pattern. Operations with no outbound-split branch — Die Cast, Receiving, **Trim OUT** (now a 1:1 whole-LOT move), Machining IN, Assembly — ignore the column. The ALTER lands in Phase 5 migration `0018`. |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT GETDATE() | |
| DeprecatedAt | DATETIME2(3) | NULL | |

### DataCollectionField

Extensible vocabulary of data collection capabilities. Seeded with initial set, extensible by engineering.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Code | NVARCHAR(50) | NOT NULL, UNIQUE | MaterialVerification, SerialNumber, DieInfo, CavityInfo, Weight, GoodCount, BadCount |
| Name | NVARCHAR(100) | NOT NULL | |
| Description | NVARCHAR(500) | NULL | |

### OperationTemplateField

Junction: which data collection fields an operation template requires. Replaces the former hardcoded BIT flags on `OperationTemplate`.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| OperationTemplateId | BIGINT | FK → OperationTemplate.Id, NOT NULL | |
| DataCollectionFieldId | BIGINT | FK → DataCollectionField.Id, NOT NULL | |
| IsRequired | BIT | NOT NULL, DEFAULT 1 | Whether this field is mandatory or optional for this operation |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT GETDATE() | |
| DeprecatedAt | DATETIME2(3) | NULL | |

### ItemLocation

Part-to-location eligibility (which parts can run where) **plus consumption metadata** for runtime Allocations.

**v1.9d (2026-04-24) — hierarchy-cascade extension (OI-18):** `LocationId` can point at **any Location tier** (Area, WorkCenter, or Cell). Eligibility checks at scan-in time cascade UP the hierarchy from the scanned Cell: if an `ItemLocation` row exists for the Cell, its ancestor WorkCenter, or its ancestor Area, the Part is eligible. This enables "Part 5G0 eligible across all of Die Cast Area" with a single row. A helper proc `Parts.ItemLocation_IsEligible(@ItemId, @CellLocationId)` walks parentage from the scanned Cell up to Site; first match returns eligible.

**v1.8 — consumption metadata:** four columns surfaced in the legacy Flexware "Compatible work cells" configuration: `MinQuantity`, `MaxQuantity`, `DefaultQuantity`, and `IsConsumptionPoint`. These drive the runtime Allocations grid — when a LOT is scanned into a Cell flagged `IsConsumptionPoint = 1`, the UI pre-populates `DefaultQuantity`, validates the scan against `MinQuantity`/`MaxQuantity`, and rejects over-scanning. Consumption metadata is orthogonal to the hierarchy cascade — a row at the Area tier applies to every Cell under that Area.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| ItemId | BIGINT | FK → Item.Id, NOT NULL | |
| LocationId | BIGINT | FK → Location.Id, NOT NULL | **v1.9d:** any tier (Area, WorkCenter, Cell). Eligibility at a Cell = ItemLocation row exists for the Cell OR any ancestor. |
| MinQuantity | INT | NULL | Minimum pieces per scan-in at this Cell for this Item. Added v1.8 (OI-18). |
| MaxQuantity | INT | NULL | Maximum pieces per scan-in — rejects over-scan. Added v1.8 (OI-18). |
| DefaultQuantity | INT | NULL | Pre-populated quantity on the Allocations scan form. Added v1.8 (OI-18). |
| IsConsumptionPoint | BIT | NOT NULL, DEFAULT 0 | `1` = this Cell consumes this Item (input); `0` = this Cell produces this Item (output) or is merely eligible. Added v1.8 (OI-18). |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT GETDATE() | |
| DeprecatedAt | DATETIME2(3) | NULL | |

### ContainerConfig

Honda-specified packing rules per product.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| ItemId | BIGINT | FK → Item.Id, NOT NULL | |
| TraysPerContainer | INT | NOT NULL | |
| PartsPerTray | INT | NOT NULL | |
| IsSerialized | BIT | NOT NULL, DEFAULT 0 | |
| ClosureMethod | NVARCHAR(20) | NULL | One of `ByCount`, `ByWeight`, or `ByVision` (NULL when not yet configured). Selects the **tray-level** closure trigger per FDS-06-014. `ByCount` = operator-entered count per tray; `ByWeight` = scale feedback via OmniServer (target on `TargetWeight`, PLC asserts `TrayFullFlag` at threshold); `ByVision` = camera validates the **full tray as a single image** (one validation event per tray, not per piece), PLC asserts `TrayFullFlag` on pass. Container fill is derived in MES from accumulated tray closes — no separate `ContainerFullFlag` PLC tag is required. **`ClosureMethod` is a per-Item / per-customer attribute** — a `ByVision` part and a `ByCount` part may run on the same physical line for different customers, each with its own `ContainerConfig`. The binding to a camera/MIP-capable Cell is **routing-trusted, not proc-enforced** (decided 2026-06-04): Engineering routes a `ByVision` part to a vision-equipped Cell; a mis-route simply never receives `TrayFullFlag`. Distinct from the per-Cell `ConfirmationMethod` LocationAttribute (part-identity verification, FDS-10-013) — they may use the same physical Cognex but are separate concerns. |
| TargetWeight | DECIMAL(10,4) | NULL | Target weight for `ByWeight` closure. Required when `ClosureMethod = 'ByWeight'`; ignored otherwise. |
| DunnageCode | NVARCHAR(50) | NULL | Returnable dunnage identifier |
| CustomerCode | NVARCHAR(50) | NULL | Honda customer code |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT GETDATE() | |
| UpdatedAt | DATETIME2(3) | NULL | |
| DeprecatedAt | DATETIME2(3) | NULL | |

### ✅ Resolved (v1.8 rev / FDS-05-033 v0.11m): Trim → Machining Part Identity Change → 1-line BOM

> **OI-11 resolution (2026-04-22) + FDS v0.11m boundary clarification (2026-04-28):** The part-identity rename was originally framed as **Casting → Trim**; the v0.11m FDS continuity pass clarified that the rename actually fires one step downstream at **Trim → Machining**. Within Casting and Trim the LOT retains a single cast-part identity — Trim's sprue removal / deburr / wash work is yield loss recorded via `Workorder.RejectEvent` on the same LOT, not a rename. The earlier v1.8 draft of a dedicated `Parts.ItemTransform` table is still rejected on the same OI-11 grounds — every column it carried (`SourceItemId` / `DestinationItemId` / `SourceLotId` / `DestinationLotId` / `LocationId` / `Quantity` / `AppUserId` / `TerminalLocationId` / `RecordedAt`) is already on `Workorder.ConsumptionEvent`. The physical flow (one trim piece becomes one machined piece) is a **degenerate 1-line BOM consumption** — the same pattern assembly uses, with a BOM of `1 × 5G0-TRIM-4102` on the machined part.
>
> **Modelled as:**
>
> - `Parts.Item` has two rows for the same physical part: `5G0-TRIM-4102` (Component — covers both Casting and Trim work) and `5G0-MACHINED-4102` (Sub-Assembly or Component depending on downstream use). Trim does **not** introduce a new Item; the cast/trim LOT carries the same `ItemId` from Die Cast through Trim OUT.
> - `Parts.Bom` for the machined part has a single `BomLine` with `ChildItemId = 5G0-TRIM` and `QtyPer = 1`.
> - At the first Machining Cell, the operator picks the next sub-LOT from the Cell's FIFO queue (per FDS-06-007 — no scan-to-receive). The MES applies the BOM-driven rename: *"This LOT is 5G0-TRIM-4102. Receive as 5G0-MACHINED-4102?"* — the prompt is driven by BOM lookup (which finished items have the scanned Item as a component).
> - On confirm, a new destination LOT of the machined part is created; `Workorder.ConsumptionEvent` records the flow (source trim LOT → produced machined LOT); `Lots.LotGenealogy` records the parent/child with `RelationshipType = Consumption`.
> - Yield loss at Trim (sprue removal, deburr, wash) is captured via `Workorder.RejectEvent` on the cast/trim LOT — no rename, no consumption event; trim work is rework against the same LOT.
> - Yield loss at Machining (after the rename) is captured via `Workorder.RejectEvent` on the machined LOT.
> - Backward trace: a shipped machined LOT walks `LotGenealogy` back to the trim/cast LOT in **one read** (single Machining-IN consumption hop). The trim/cast LOT carries the original Die Cast `ProductionEvent` rows directly (cast machine / die / cavity / operator / timestamp reachable without a second hop) — Casting and Trim share the same `LotId`.
>
> **No new schema.** The `Parts.ItemTransform` table was removed from the v1.8 draft before any SQL landed. The operator-facing flow (FIFO pick + BOM-driven rename prompt + confirmation), the backward trace, and the FDS §5.7 Genealogy queries all work unchanged.

### ✅ Resolved (v1.7): Tool Life Tracking → §7 Tools Schema

> **Scope Matrix row 26** (Tool Life, FRS 5.6.6) is resolved by the dedicated **§7 Tools Schema** added in v1.7 as part of the Phase B Tool Management refactor (see `docs/superpowers/specs/2026-04-21-tool-management-design.md`). Tools are now a first-class polymorphic subsystem — `Tools.Tool` holds tool identity; `Tools.ToolCavity` tracks per-cavity status; `Tools.ToolAssignment` is the append-only check-in/out history against Cells. Shot counts derive from `Workorder.ProductionEvent` (no live counter column). Tool-life threshold alarms remain **FUTURE** — delivered later via a scheduled Gateway Script that reads the derived shot counts.
>
> **Historical context (pre-v1.7):** The gap was originally left open because MPP hadn't confirmed whether tool life needed its own event history or could ride on `LocationAttribute`. The 2026-04-20 MPP review resolved it in favour of a dedicated subsystem so that dies, cutters, jigs, gauges, and trim tools all share a consistent identity and maintenance hook.

---

## 3. Lots Schema — `MVP`

> **Scope:** All tables MVP. Core tracking entity schema. Serialization is MVP-EXPANDED (expanded beyond legacy two-line support).
>
> **Note on pass-through parts:** Receiving pass-through parts into MES is MVP (Scope Matrix row 3) — supported via `LotOriginType` Received/ReceivedOffsite. Full in-plant pass-through tracking workflows are noted as Future (Scope Matrix row 20). The existing `Lot` + `LotMovement` tables handle both; the future work is operational workflow design, not schema.

LOT lifecycle, genealogy, containers, serialized parts, shipping.

**Views (v1.9e):** `Lots.v_LotDerivedQuantities (LotId, TotalInProcess, InventoryAvailable)` — computes Lot Details header quantities at read time from `Lots.Lot.PieceCount` + `Workorder.ProductionEvent` aggregations + `Workorder.ConsumptionEvent` aggregations. No materialized columns on `Lots.Lot`. Created in the Arc 2 Phase 2 migration. See FDS-05-031 for derivation formulas and rationale.

### LotOriginType

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Code | NVARCHAR(30) | NOT NULL, UNIQUE | Manufactured, Received, ReceivedOffsite |
| Name | NVARCHAR(100) | NOT NULL | |

### LotStatusCode

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Code | NVARCHAR(20) | NOT NULL, UNIQUE | Good, Hold, Scrap, Closed |
| Name | NVARCHAR(100) | NOT NULL | |
| BlocksProduction | BIT | NOT NULL, DEFAULT 0 | Hold = true, drives interlocks |

### GenealogyRelationshipType

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Code | NVARCHAR(20) | NOT NULL, UNIQUE | Split, Merge, Consumption |
| Name | NVARCHAR(100) | NOT NULL | |

### Lot

The central tracking entity.

> **v1.9 changes:** Added `ToolId` + `ToolCavityId` FKs (Tool/Cavity is system of record on the LOT, not on `ProductionEvent`). Required at `Lot_Create` for die-cast-origin LOTs; NULL elsewhere; NULL after `Lot_Merge` on blended-origin LOTs. Codifies OI-09: a die-cast machine with N active cavities produces **N parallel independent LOTs (not sublots)** — each LOT has fixed Tool + Cavity at creation, fills at its own rate, closes independently via explicit operator action. Pre-v1.9 `DieNumber` + `CavityNumber` NVARCHAR columns are now legacy (retained for cutover transition; slated for removal once all writers use the FKs).

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| LotName | NVARCHAR(50) | NOT NULL, UNIQUE | The LTT barcode number |
| ItemId | BIGINT | FK → Item.Id, NOT NULL | |
| LotOriginTypeId | BIGINT | FK → LotOriginType.Id, NOT NULL | How it entered MES |
| LotStatusId | BIGINT | FK → LotStatusCode.Id, NOT NULL | Current quality status |
| PieceCount | INT | NOT NULL | Current count |
| MaxPieceCount | INT | NULL | Reasonability ceiling |
| Weight | DECIMAL(12,4) | NULL | |
| WeightUomId | BIGINT | FK → Uom.Id, NULL | |
| ToolId | BIGINT | FK → Tools.Tool.Id, NULL | Added v1.9. **Required at `Lot_Create` for die-cast-origin LOTs** (validated against `Tools.ToolAssignment_ListActiveByCell` — the Tool must be currently mounted on the cell). NULL for other origins (Received, Trim / Machining intermediate, Assembly, Serialized). NULL after `Lot_Merge` on blended-origin LOTs (can't denormalize multiple Tools). Downstream LOTs do NOT carry — Honda-trace via `LotGenealogy` traversal. |
| ToolCavityId | BIGINT | FK → Tools.ToolCavity.Id, NULL | Added v1.9. **Required at `Lot_Create` for die-cast-origin LOTs** (validated: cavity belongs to `ToolId` + cavity status is Active). NULL elsewhere. |
| DieNumber | NVARCHAR(50) | NULL | **Legacy as of v1.9** — superseded by `ToolId` FK above. Retained this release to support any cutover script needing the NVARCHAR form; scheduled for removal in a follow-up migration once all writers move to the Tool FK. |
| CavityNumber | NVARCHAR(50) | NULL | **Legacy as of v1.9** — superseded by `ToolCavityId` FK. Retained for cutover transition; scheduled for removal. |
| VendorLotNumber | NVARCHAR(100) | NULL | Received LOTs only |
| MinSerialNumber | INT | NULL | Vendor serial range (received bulk parts) |
| MaxSerialNumber | INT | NULL | |
| ParentLotId | BIGINT | FK → Lot.Id, NULL | Adjacency list link for **Machining sub-LOTs** (FDS §5.4). Not used for cavity-parallel LOTs at Die Cast — those are peers, not parent/child. |
| CurrentLocationId | BIGINT | FK → Location.Id, NOT NULL | Where this LOT is now |
| CrtActive | BIT | NOT NULL, DEFAULT 0 | Added v1.9q (FDS-10-012). Controlled Run Tag flag. When 1, downstream operations require 200% inspection (every part, captured via `Quality.QualitySample`) until cleared by a supervisor-elevated release. Missed CRT inspections (`MissedCrtInspect`) are detected against the per-operation inspection record. Set / cleared by the Arc 2 CRT workflow; MVP-ratified 2026-06-08. |
| CreatedByUserId | BIGINT | FK → AppUser.Id, NOT NULL | |
| CreatedAtTerminalId | BIGINT | FK → Location.Id (Terminal), NULL | |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT GETDATE() | |
| UpdatedAt | DATETIME2(3) | NULL | |
| UpdatedByUserId | BIGINT | FK → AppUser.Id, NULL | |

### LotGenealogy

Edge table for the genealogy graph. Adjacency list supporting recursive CTE traversal.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| ParentLotId | BIGINT | FK → Lot.Id, NOT NULL | |
| ChildLotId | BIGINT | FK → Lot.Id, NOT NULL | |
| RelationshipTypeId | BIGINT | FK → GenealogyRelationshipType.Id, NOT NULL | Split, Merge, Consumption |
| PieceCount | INT | NULL | Pieces transferred in this relationship |
| EventUserId | BIGINT | FK → AppUser.Id, NOT NULL | |
| TerminalLocationId | BIGINT | FK → Location.Id (Terminal), NULL | Terminal where action was performed |
| EventAt | DATETIME2(3) | NOT NULL | |

### LotStatusHistory

Immutable log of every status transition.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| LotId | BIGINT | FK → Lot.Id, NOT NULL | |
| OldStatusId | BIGINT | FK → LotStatusCode.Id, NOT NULL | |
| NewStatusId | BIGINT | FK → LotStatusCode.Id, NOT NULL | |
| Reason | NVARCHAR(500) | NULL | |
| ChangedByUserId | BIGINT | FK → AppUser.Id, NOT NULL | |
| TerminalLocationId | BIGINT | FK → Location.Id (Terminal), NULL | Terminal where action was performed |
| ChangedAt | DATETIME2(3) | NOT NULL | |

### LotMovement

Append-only location change log.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| LotId | BIGINT | FK → Lot.Id, NOT NULL | |
| FromLocationId | BIGINT | FK → Location.Id, NULL | NULL on first placement |
| ToLocationId | BIGINT | FK → Location.Id, NOT NULL | |
| MovedByUserId | BIGINT | FK → AppUser.Id, NOT NULL | |
| TerminalLocationId | BIGINT | FK → Location.Id (Terminal), NULL | Terminal where action was performed |
| MovedAt | DATETIME2(3) | NOT NULL | |

### LotAttributeChange

Audit log for attribute modifications.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| LotId | BIGINT | FK → Lot.Id, NOT NULL | |
| AttributeName | NVARCHAR(100) | NOT NULL | e.g., PieceCount, Weight |
| OldValue | NVARCHAR(255) | NULL | |
| NewValue | NVARCHAR(255) | NOT NULL | |
| ChangedByUserId | BIGINT | FK → AppUser.Id, NOT NULL | |
| TerminalLocationId | BIGINT | FK → Location.Id (Terminal), NULL | Terminal where action was performed |
| ChangedAt | DATETIME2(3) | NOT NULL | |

### PrintReasonCode

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Code | NVARCHAR(50) | NOT NULL, UNIQUE | Initial, ReprintDamaged, Split, Merge, SortCageReIdentify |
| Name | NVARCHAR(100) | NOT NULL | |

### LabelTypeCode

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Code | NVARCHAR(50) | NOT NULL, UNIQUE | |
| Name | NVARCHAR(100) | NOT NULL | |

### IdentifierSequence

Added v1.9 (OI-31). Replaces Flexware's `IdentifierFormat` table and drives all MPP-internal identifier minting — Lot LTT barcode (`MESL{0:D7}`), SerializedItem ID (`MESI{0:D7}`), and any future non-AIM counters. Honda AIM shipper IDs are out of scope (those come from `AIM.GetNextNumber`). Cutover-day migration seeds `LastValue` at or above the live Flexware value to avoid collisions with in-circulation LOTs.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK IDENTITY | |
| Code | NVARCHAR(30) | NOT NULL, UNIQUE | Sequence key (e.g., `Lot`, `SerializedItem`). Passed to `IdentifierSequence_Next @Code`. |
| Name | NVARCHAR(100) | NOT NULL | Display name |
| Description | NVARCHAR(500) | NULL | |
| FormatString | NVARCHAR(50) | NOT NULL | `.NET` `string.Format` pattern, e.g., `MESL{0:D7}` produces `MESL0000001` for value 1. |
| StartingValue | BIGINT | NOT NULL, DEFAULT 1 | Lower bound of the numeric range |
| EndingValue | BIGINT | NOT NULL, DEFAULT 9999999 | Upper bound before rollover — `IdentifierSequence_Next` raises a business-rule error when `LastValue + 1 > EndingValue` without an explicit reset policy |
| LastValue | BIGINT | NOT NULL, DEFAULT 0 | Most recent issued numeric value. `IdentifierSequence_Next` atomically increments this and returns the formatted string. |
| ResetIntervalMinutes | INT | NULL | Unused at MPP today (Flexware has no reset policy); nullable for future line/shift-specific reset rules if MPP elects them. |
| LastResetAt | DATETIME2(3) | NULL | Timestamp of last reset (manual or scheduled); unused at MPP today |
| UpdatedAt | DATETIME2(3) | NOT NULL, DEFAULT SYSUTCDATETIME() | |

**Companion proc:** `Lots.IdentifierSequence_Next @Code` — single-row lookup + atomic `UPDATE ... SET LastValue = LastValue + 1 OUTPUT inserted.LastValue, inserted.FormatString` inside a transaction, then formats the result. Raises on unknown `@Code` and on rollover. Returns a single result set `(Value NVARCHAR(50))` per the Ignition JDBC single-result-set convention (FDS-11-011).

**Seed data (Arc 2 Phase 1 migration, values confirmed on cutover day):**

| Code | FormatString | LastValue (Flexware sample 2026-04-23) |
|---|---|---|
| Lot | `MESL{0:D7}` | 1,710,932 (drift expected; re-sample at cutover) |
| SerializedItem | `MESI{0:D7}` | 2,492 (drift expected; re-sample at cutover) |

**Open questions (OI-31):** format carry-forward (keep `MESL`/`MESI`, or mint new?), reset policy, rollover policy at 9,999,999. Counter inventory is the two rows shown above — the Flexware `IdentifierFormat` export is the authoritative list. See `MPP_MES_Open_Issues_Register.docx` OI-31.

### LotLabel

LTT barcode label print/reprint tracking.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| LotId | BIGINT | FK → Lot.Id, NOT NULL | |
| PrintReasonCodeId | BIGINT | FK → PrintReasonCode.Id, NOT NULL | Why this label was printed |
| ZplContent | NVARCHAR(MAX) | NULL | Full ZPL payload |
| PrinterName | NVARCHAR(100) | NULL | |
| PrintedByUserId | BIGINT | FK → AppUser.Id, NOT NULL | |
| TerminalLocationId | BIGINT | FK → Location.Id (Terminal), NULL | Terminal where action was performed |
| PrintedAt | DATETIME2(3) | NOT NULL | |

### ContainerStatusCode

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Code | NVARCHAR(20) | NOT NULL, UNIQUE | Open, Complete, Shipped, Hold, Void |
| Name | NVARCHAR(100) | NOT NULL | |

### Container

Shipping containers for finished goods.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| ContainerName | NVARCHAR(50) | NOT NULL, UNIQUE | |
| ItemId | BIGINT | FK → Item.Id, NOT NULL | |
| ContainerConfigId | BIGINT | FK → ContainerConfig.Id, NULL | |
| ContainerStatusId | BIGINT | FK → ContainerStatusCode.Id, NOT NULL | |
| LotId | BIGINT | FK → Lot.Id, NULL | Source LOT |
| CurrentLocationId | BIGINT | FK → Location.Id, NOT NULL | |
| AimShipperId | NVARCHAR(50) | NULL | From AIM system |
| HoldNumber | NVARCHAR(50) | NULL | Sort Cage hold reference |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT GETDATE() | |
| UpdatedAt | DATETIME2(3) | NULL | |

### ContainerTray

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| ContainerId | BIGINT | FK → Container.Id, NOT NULL | |
| TrayNumber | INT | NOT NULL | |
| PieceCount | INT | NOT NULL | |

### SerializedPart

Individual laser-etched serial numbers.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| SerialNumber | NVARCHAR(50) | NOT NULL, UNIQUE | |
| ItemId | BIGINT | FK → Item.Id, NOT NULL | |
| LotId | BIGINT | FK → Lot.Id, NOT NULL | Source LOT |
| ContainerId | BIGINT | FK → Container.Id, NULL | Current container |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT GETDATE() | |

### ContainerSerial

Junction: serial numbers in container tray positions.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| ContainerId | BIGINT | FK → Container.Id, NOT NULL | |
| ContainerTrayId | BIGINT | FK → ContainerTray.Id, NULL | |
| SerializedPartId | BIGINT | FK → SerializedPart.Id, NOT NULL | |
| TrayPosition | INT | NULL | Position within tray |

**HardwareInterlockBypassed flag (UJ-16, ✅ Resolved 2026-04-27 per OIR v2.14, Option A).** When `HardwareInterlockEnable=false`, parts enter containers without MES serial validation. A `HardwareInterlockBypassed BIT NOT NULL DEFAULT 0` column SHALL be added to `ContainerSerial` to mark the specific serial-to-container assignment as having skipped validation. The flag lives on `ContainerSerial` (not `ProductionEvent`) because the bypass is observed at the per-piece serial-assignment level — broader event-level tracking via `ProductionEvent` would lose the per-piece granularity. Schema add deferred to Arc 2 Phase 7 alongside the rest of the Container schema CREATE.

### ShippingLabel

Container shipping label print/void history. **v1.9i (UJ-18 Gateway-script-async print pattern):** print state lives on this row — no separate queue table. Operator close transaction is atomic and zero-latency (same v1.9h AIM pool flow); print dispatch is event-driven via Gateway message handler with 3 retries (2s gap), banner-on-failure at the closing terminal. **v1.9k:** `BannerAcknowledgedAt` added to record operator dismissal of the print-failure banner — supports the FDS-07-006b broadcast-with-session-filter Acknowledge action.

State derivation:

- **Pending** — `PrintedAt IS NULL AND PrintFailedAt IS NULL`
- **Completed** — `PrintedAt IS NOT NULL`
- **Failed** — `PrintFailedAt IS NOT NULL AND BannerAcknowledgedAt IS NULL` (banner showing)
- **Failed-acknowledged** — `PrintFailedAt IS NOT NULL AND BannerAcknowledgedAt IS NOT NULL` (banner dismissed; row remains in failed state for the safety-sweep alarm)

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| ContainerId | BIGINT | FK → Container.Id, NOT NULL | |
| AimShipperId | NVARCHAR(50) | NOT NULL | From the AimShipperIdPool claim at close time. |
| LabelTypeCodeId | BIGINT | FK → LabelTypeCode.Id, NOT NULL | |
| ZplContent | NVARCHAR(MAX) | NULL | Full ZPL payload |
| IsVoid | BIT | NOT NULL, DEFAULT 0 | |
| PrintedAt | DATETIME2(3) | NULL | NULL until the Gateway print handler succeeds. |
| VoidedAt | DATETIME2(3) | NULL | |
| PrintedByUserId | BIGINT | FK → AppUser.Id, NULL | |
| PrintAttempts | INT | NOT NULL, DEFAULT 0 | **Added v1.9i.** Increments per print attempt by the Gateway message handler. |
| LastPrintAttemptAt | DATETIME2(3) | NULL | **Added v1.9i.** Timestamp of most recent print try. |
| LastPrintError | NVARCHAR(2000) | NULL | **Added v1.9i.** Captured exception text from the most recent failed attempt. |
| PrintFailedAt | DATETIME2(3) | NULL | **Added v1.9i.** Non-NULL = retries exhausted (3 attempts × 2s gap). Drives the banner shown at `TerminalLocationId`. |
| TerminalLocationId | BIGINT | FK → Location.Location.Id, NULL | **Added v1.9i.** The Terminal where the closing operator was — drives both the printer pick (resolved via `LocationAttribute` on parent Cell) and the banner routing (banner shows only at this Terminal). |
| BannerAcknowledgedAt | DATETIME2(3) | NULL | **Added v1.9k.** Non-NULL when the operator at `TerminalLocationId` dismissed the print-failure banner via the Acknowledge action (FDS-07-006b). Independent of `PrintFailedAt` — the row stays in failed state for the safety-sweep alarm even after acknowledgement; this column only suppresses the banner UI. NULL while the banner is active. |

### PauseEvent

**Added v1.9g (OI-21 — Pausable LOT at Workstation).** Captures an operator's deliberate pause of a partially-progressed LOT at a Cell so the operator may shift focus to a different LOT at the same Cell. Append-only place + close lifecycle — mirrors `Quality.HoldEvent`. The same LOT MAY be paused at multiple Cells simultaneously (e.g., a Machining LOT pending mid-assembly while another assembly LOT is run); the filtered UNIQUE limits at most one **open** pause per `(LotId, LocationId)`. Pause is orthogonal to `Workorder.WorkOrderStatus`, `Workorder.OperationStatus`, and `Lots.LotStatusCode` — no enum extension is required on any of those code tables. There is no TTL — paused LOTs persist indefinitely; resume MAY be performed by any operator (does not need to match `PausedByUserId`). Drives the **Paused-LOT indicator** on every workstation screen (count + tap-through to detail list, per FDS-05-038).

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK IDENTITY | |
| LotId | BIGINT | FK → Lot.Id, NOT NULL | The LOT being paused at this Cell. |
| LocationId | BIGINT | FK → Location.Id, NOT NULL | The Cell where the pause is recorded. Should be a Cell-tier production location; not enforced at the schema level (proc layer enforces). |
| PausedByUserId | BIGINT | FK → AppUser.Id, NOT NULL | Operator who placed the pause. |
| PausedAt | DATETIME2(3) | NOT NULL, DEFAULT SYSUTCDATETIME() | |
| PausedReason | NVARCHAR(500) | NULL | Optional — operator MAY pause without entering a reason. |
| ResumedByUserId | BIGINT | FK → AppUser.Id, NULL | NULL while pause is open. NOT required to match `PausedByUserId` — paused LOTs cross shift / operator boundaries. |
| ResumedAt | DATETIME2(3) | NULL | NULL while pause is open. |
| ResumedRemarks | NVARCHAR(500) | NULL | Optional resume note. |

**Constraints:**

- `CK_PauseEvent_ResumePaired` — `(ResumedAt IS NULL AND ResumedByUserId IS NULL) OR (ResumedAt IS NOT NULL AND ResumedByUserId IS NOT NULL)`. Resume timestamp and resumer are paired.
- `UQ_PauseEvent_OpenLotLocation` — filtered UNIQUE on `(LotId, LocationId) WHERE ResumedAt IS NULL`. Blocks duplicate open pauses for the same LOT at the same Cell.

**Indexes:**

- `IX_PauseEvent_OpenByLocation` on `(LocationId) WHERE ResumedAt IS NULL` — supports the wallboard counter / paused-LOT detail-list lookup.
- `IX_PauseEvent_Lot` on `(LotId, PausedAt DESC)` — supports per-LOT pause history (Lot Details view).

**Audit:** `Audit.LogEntityType` carries a `PauseEvent` row. Place / Resume operations write to `Audit.OperationLog`.

### AimShipperIdPool

**Added v1.9h (UJ-04 — AIM Shipper ID local pool).** Local buffer of pre-fetched Honda AIM Shipper IDs. A background Gateway script (Arc 2 Phase 7) calls `AIM.GetNextNumber` to keep the pool topped up; `Container_Complete` claims one row FIFO, synchronously, inside its own transaction — sub-millisecond, never blocked on AIM. AIM IDs attach to **`Lots.Container` only** — never to sub-assemblies, sub-LOTs, or any other entity. Honda treats every issued ID as permanently consumed; once `ConsumedAt` is set the row stays terminal regardless of any downstream container void / re-pack (the new container at re-pack draws a fresh ID from the pool). Honda does not expire IDs — no TTL column.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK IDENTITY | |
| AimShipperId | NVARCHAR(50) | NOT NULL, UNIQUE | The Honda-issued shipper ID returned by `AIM.GetNextNumber`. UNIQUE protects against double-INSERT under topup-script retries. |
| FetchedAt | DATETIME2(3) | NOT NULL, DEFAULT SYSUTCDATETIME() | When AIM gave this ID to us. Drives FIFO ordering at claim time. |
| FetchedInterfaceLogId | BIGINT | FK → Audit.InterfaceLog.Id, NOT NULL | Provenance — points at the exact AIM call that issued this ID. |
| ConsumedAt | DATETIME2(3) | NULL | NULL = available in the pool. Non-NULL = permanently consumed. |
| ConsumedByContainerId | BIGINT | FK → Lots.Container.Id, NULL | The container that claimed this ID. NULL ↔ ConsumedAt NULL. |
| ConsumedByUserId | BIGINT | FK → Location.AppUser.Id, NULL | The operator whose closing-container action consumed this ID. NULL ↔ ConsumedAt NULL. |

**Constraints:**

- `CK_AimShipperIdPool_ConsumedFieldsPaired` — `(ConsumedAt IS NULL AND ConsumedByContainerId IS NULL AND ConsumedByUserId IS NULL) OR (ConsumedAt IS NOT NULL AND ConsumedByContainerId IS NOT NULL AND ConsumedByUserId IS NOT NULL)`. The three consumption columns are paired; either all NULL (available) or all set (consumed).

**Indexes:**

- `IX_AimShipperIdPool_Available (FetchedAt) WHERE ConsumedAt IS NULL` — drives the FIFO `_Claim` query (`UPDATE TOP (1) WITH (UPDLOCK, READPAST, ROWLOCK)`) and the `_GetDepth` count.
- `IX_AimShipperIdPool_Container ON (ConsumedByContainerId) WHERE ConsumedByContainerId IS NOT NULL` — supports `_GetByContainer` traceability.

**Audit:** `Audit.LogEntityType` carries an `AimShipperIdPool` row. `_Claim` writes an `OperationLog` `Consumed` row (linked back to the closing container's audit chain). Each `_Topup` is *itself* preceded by an `Audit.InterfaceLog` row (the AIM call) — `FetchedInterfaceLogId` carries the FK so provenance is end-to-end queryable.

### AimPoolConfig

**Added v1.9h (UJ-04 — AIM Pool configuration).** Single-row table holding the operator-configurable thresholds for the AIM Shipper ID pool. The Configuration Tool exposes these via `Lots.AimPoolConfig_Get` / `_Update`. Single-row enforced via `CHECK (Id = 1)`.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | INT | PK, CHECK (Id = 1) | Always 1. Single-row table. |
| TargetBufferDepth | INT | NOT NULL, DEFAULT 50, CHECK (TargetBufferDepth > 0) | The desired pool depth — topup script refills toward this value. |
| TopupThreshold | INT | NOT NULL, DEFAULT 30, CHECK (TopupThreshold >= 0 AND TopupThreshold < TargetBufferDepth) | Topup script triggers when `AvailableCount < TopupThreshold`. |
| AlarmWarningDepth | INT | NOT NULL, DEFAULT 20, CHECK (AlarmWarningDepth >= 0 AND AlarmWarningDepth < TopupThreshold) | Supervisor wallboard tile turns yellow when `AvailableCount < AlarmWarningDepth`. |
| AlarmCriticalDepth | INT | NOT NULL, DEFAULT 10, CHECK (AlarmCriticalDepth >= 0 AND AlarmCriticalDepth < AlarmWarningDepth) | Supervisor alarm + IT notification fires when `AvailableCount < AlarmCriticalDepth`. |
| UpdatedAt | DATETIME2(3) | NULL | |
| UpdatedByUserId | BIGINT | FK → Location.AppUser.Id, NULL | |

**Seed (at Arc 2 Phase 7 migration):**

| Id | TargetBufferDepth | TopupThreshold | AlarmWarningDepth | AlarmCriticalDepth |
|---|---|---|---|---|
| 1 | 50 | 30 | 20 | 10 |

**Audit:** `Audit.LogEntityType` carries an `AimPoolConfig` row. `_Update` writes a `ConfigLog` row.

---

## 4. Workorder Schema — MIXED SCOPE

> **Scope:**
> - `WorkOrder`, `WorkOrderStatus`, `WorkOrderOperation`, `OperationStatus`, `WorkOrderType` — **MVP-LITE** (auto-generated, invisible to operators, no WO screens — per OI-07 resolution)
> - `ProductionEvent`, `ProductionEventValue`, `ConsumptionEvent`, `RejectEvent`, `ScrapSource` — **MVP** (Production Data Acquisition is included and expanded)
> - Demand (planned PM) and Maintenance (emergency) WO flows — **FUTURE** (separate project scope; this system only provides the code-table hook via `WorkOrderType` and the nullable `ToolId` on `WorkOrder`)
>
> **OI-07 status (2026-04-24 correction of 2026-04-20):** MVP ships with **one** active WO type — `Production` — preserving the pre-existing MVP-LITE bookkeeping (auto-generated on LOT start, invisible to operators). The 2026-04-20 meeting note was mis-recorded; the "Recipe" line was describing this same Production flow. No separate Recipe concept exists. `Demand` (planned preventative maintenance) and `Maintenance` (emergency) are genuinely separate future WO types under MPP's taxonomy — they are NOT built in this project; the `WorkOrderType` code table exists as a future hook so new rows can be INSERTed without schema change when MPP scopes the maintenance engine. Operators never see or interact with any WO in MVP. Production events function independently via nullable `WorkOrderOperationId` FKs.
>
> Production events have nullable FKs to `WorkOrderOperation`, allowing them to function independently even if the work order capability is deferred.

Internal work order context, production events, consumption tracking.

### WorkOrderStatus

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Code | NVARCHAR(20) | NOT NULL, UNIQUE | Created, InProgress, Completed, Cancelled |
| Name | NVARCHAR(100) | NOT NULL | |

### ScrapSource

Read-only code table distinguishing the two scrap entry paths surfaced in the legacy Flexware Lot Details screen: **Inventory** (scrapping unallocated stock on a LOT) vs **Location** (scrapping in-process material at a specific workstation). Added v1.8 (OI-20). Seeded at migration time.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Code | NVARCHAR(20) | NOT NULL, UNIQUE | `Inventory`, `Location` |
| Name | NVARCHAR(100) | NOT NULL | |
| Description | NVARCHAR(500) | NULL | |

**Seed data (Phase G migration):**

| Code | Name | Description |
|---|---|---|
| Inventory | Scrap From Inventory | Scrap of unallocated pieces on a LOT — no workstation context. Used by the Lot Details "Scrap from inventory" button. |
| Location | Scrap From Location | Scrap of in-process pieces at a specific Cell — workstation context required. Used by the workstation "Scrap from the selected location" button. |

### OperationStatus

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Code | NVARCHAR(20) | NOT NULL, UNIQUE | Pending, InProgress, Completed, Skipped |
| Name | NVARCHAR(100) | NOT NULL | |

### WorkOrderType

Read-only code table. Added in v1.7 (Phase B); seed corrected in v1.9b (2026-04-24) per OI-07. Serves as a **future hook** — new WO type rows can be INSERTed without schema change when MPP scopes separate Demand (planned PM) and Maintenance (emergency) engines.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Code | NVARCHAR(20) | NOT NULL, UNIQUE | `Production` (the only active code in MVP) |
| Name | NVARCHAR(100) | NOT NULL | |
| Description | NVARCHAR(500) | NULL | |

**Seed data (authoritative — Arc 2 Phase 1 migration or follow-up correction migration):**

| Code | Name | Description |
|---|---|---|
| Production | Production Work Order | MVP-LITE — auto-generated on LOT start, invisible to operators, no WO screens. Retains the v1.7 bookkeeping behaviour. |

**FUTURE — not seeded in this project** (MPP can INSERT these rows when scoping the maintenance engine):

| Code | Purpose |
|---|---|
| Demand | Planned preventative maintenance. |
| Maintenance | Emergency maintenance. |

> **SQL correction landed:** Migration `0013_oi07_oi12_corrections.sql` (2026-04-28) collapsed the seed to a single `Production` row and updated `sql/tests/0019_Parts_ConsumptionMetadata_And_ScrapSource/010_Phase_E_additives.sql` accordingly. 858/858 tests passing.

### WorkOrder

Auto-generated internal work order. Operators never see this. The table carries `WorkOrderTypeId` (discriminator FK → `WorkOrderType`, defaults to the single-seeded `Production` row) and `ToolId` (nullable FK → `Tools.Tool`, schema hook for FUTURE Maintenance WOs — unpopulated in MVP).

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| WoNumber | NVARCHAR(50) | NOT NULL, UNIQUE | System-generated |
| WorkOrderTypeId | BIGINT | FK → WorkOrderType.Id, NOT NULL | Added v1.7. **v1.9b (2026-04-24):** defaults to `Production` (the corrected single-seed row). FUTURE Demand / Maintenance rows are added without schema change. |
| ItemId | BIGINT | FK → Item.Id, NOT NULL | |
| RouteTemplateId | BIGINT | FK → RouteTemplate.Id, NOT NULL | The route version active at creation |
| WorkOrderStatusId | BIGINT | FK → WorkOrderStatus.Id, NOT NULL | |
| ToolId | BIGINT | FK → Tools.Tool.Id, NULL | Added v1.7 as a schema hook for **FUTURE** Maintenance WOs (targets a specific Tool). Not populated in MVP. Enforced at the proc layer when Maintenance flow activates. |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT GETDATE() | |
| CompletedAt | DATETIME2(3) | NULL | |

### WorkOrderOperation

Individual operation execution — the actual step that happened.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| WorkOrderId | BIGINT | FK → WorkOrder.Id, NOT NULL | |
| RouteStepId | BIGINT | FK → RouteStep.Id, NOT NULL | The planned step |
| LocationId | BIGINT | FK → Location.Id, NULL | Where it actually ran |
| OperationStatusId | BIGINT | FK → OperationStatus.Id, NOT NULL | |
| SequenceNumber | INT | NOT NULL | |
| StartedAt | DATETIME2(3) | NULL | |
| CompletedAt | DATETIME2(3) | NULL | |
| AppUserId | BIGINT | FK → AppUser.Id, NULL | Operator who ran the operation |

### ProductionEvent

**Checkpoint-shape event table.** Per FRS §2.1.2 operator-driven capture: operators are not at the terminal for every shot — they log at checkpoints (checkout from die cast, check-in to trim, complete + move, quality-operation transitions). Each checkpoint fires one row carrying the **cumulative** counters as-of-that-moment; deltas are derived by the reader via `LAG()` window function over `(LotId, EventAt)`. A missed event doesn't compound errors — the next event carries truth.

**What's deliberately NOT on this table:**
- **No `LocationId`** — derivable from `LotMovement` at `EventAt` timestamp. Redundant.
- **No `ItemId`** — derivable from `Lot.ItemId`.
- **No `DieIdentifier` / `CavityNumber`** — `Lot.ToolId` / `Lot.ToolCavityId` are system of record; ProductionEvent does not carry.
- **No `ToolId` / `ToolCavityId`** — derived via `ProductionEvent.LotId → Lot.ToolId / Lot.ToolCavityId`.
- **No `StartedAt` / `EndedAt`** — the "start" of any event's interval is the previous event for the same LOT (derived via `LAG()`). Avoids dangling "started-but-not-ended" rows entirely.
- **No `GoodCount` / `NoGoodCount`** per-event — replaced by cumulative `ShotCount` + `ScrapCount` with `LAG()`-derived deltas.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK IDENTITY | |
| LotId | BIGINT | FK → Lots.Lot.Id, NOT NULL | Tool + Cavity derived via `Lot.ToolId` / `Lot.ToolCavityId`. |
| OperationTemplateId | BIGINT | FK → Parts.OperationTemplate.Id, NOT NULL | Captures the FDS-03-017a data-collection contract — what fields were required at this checkpoint. Direct FK so events remain queryable when work orders are absent (OI-07 background-only WOs). |
| WorkOrderOperationId | BIGINT | FK → Workorder.WorkOrderOperation.Id, NULL | Nullable (MVP-LITE WO model). |
| EventAt | DATETIME2(3) | NOT NULL, DEFAULT SYSUTCDATETIME() | Checkpoint timestamp. Used with `LAG()` for delta derivation. |
| ShotCount | INT | NULL | **Cumulative** shot counter at event time. Reader derives `ShotsSinceLast = ShotCount - LAG(ShotCount) OVER (PARTITION BY LotId ORDER BY EventAt)`. **Open item** (per Decision 5 of the 2026-04-23 spec): may migrate to derived-from-aggregated-LOT-quantity before Arc 2 Phase 3 if the LOT-quantity aggregation proves authoritative for "shots per die" reporting. Kept nullable and provisional until resolved. |
| ScrapCount | INT | NULL | Cumulative scrap counter at event time. Delta via `LAG()`. |
| ScrapSourceId | BIGINT | FK → Workorder.ScrapSource.Id, NULL | Populated only when this event represents a scrap action. Distinguishes scrap-from-inventory vs scrap-from-location per OI-20. NULL for non-scrap checkpoints. |
| WeightValue | DECIMAL(12,4) | NULL | Captured when the operation template requires `Weight` (e.g., scale-driven container closure, OI-02). |
| WeightUomId | BIGINT | FK → Parts.Uom.Id, NULL | Required whenever `WeightValue` is set. |
| AppUserId | BIGINT | FK → Location.AppUser.Id, NOT NULL | Who captured this event (initials-based per Phase C). |
| TerminalLocationId | BIGINT | FK → Location.Location.Id (Terminal), NULL | Terminal where the checkpoint was registered. |
| Remarks | NVARCHAR(500) | NULL | Free-text note attached to the checkpoint. |

**Required index:** `(LotId, EventAt DESC)` — "previous event for this LOT" must be a single-row seek.

**Sample delta query:**
```sql
SELECT
    pe.Id,
    pe.EventAt,
    pe.ShotCount,
    pe.ShotCount - LAG(pe.ShotCount) OVER (PARTITION BY pe.LotId ORDER BY pe.EventAt) AS ShotsSinceLast,
    pe.ScrapCount - LAG(pe.ScrapCount) OVER (PARTITION BY pe.LotId ORDER BY pe.EventAt) AS ScrapSinceLast
FROM Workorder.ProductionEvent pe
WHERE pe.LotId = @LotId
ORDER BY pe.EventAt;
```

**Honda-trace (finished part → originating die):** walks `LotGenealogy` from the finished LOT back to the die-cast-origin LOT, then reads `Lot.ToolId`. See Arc 2 Phase 7 narrative.

**Data collection capture:** Any `DataCollectionField` configured on the operation template that isn't promoted to a typed column above is captured in child `ProductionEventValue` rows.

### ProductionEventValue

Child of `ProductionEvent` — holds any `DataCollectionField` value configured on the operation template but *not* promoted to a typed column on `ProductionEvent`. Lets engineering extend the data collection vocabulary without schema changes. One row per field collected for a given event.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| ProductionEventId | BIGINT | FK → ProductionEvent.Id, NOT NULL, ON DELETE CASCADE | |
| DataCollectionFieldId | BIGINT | FK → Parts.DataCollectionField.Id, NOT NULL | Which field this value satisfies |
| Value | NVARCHAR(255) | NOT NULL | String representation (canonical storage) |
| NumericValue | DECIMAL(18,4) | NULL | Populated when the field is numeric — enables range queries without parsing `Value` |
| UomId | BIGINT | FK → Parts.Uom.Id, NULL | Required when the field is a measurement |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT GETDATE() | |

**Unique constraint:** `UNIQUE (ProductionEventId, DataCollectionFieldId)` — a given field is captured once per event.

**Rule:** fields already represented as typed columns on `ProductionEvent` (`ShotCount`, `ScrapCount`, `WeightValue`) SHALL NOT also be written to `ProductionEventValue`. The Arc 2 Phase 1 write proc enforces this. (Pre-v1.9 the list included `GoodCount`, `NoGoodCount`, `DieIdentifier`, `CavityNumber` — all removed from ProductionEvent in the v1.9 reshape.)

### ConsumptionEvent

Records which source LOTs were consumed to produce output.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| WorkOrderOperationId | BIGINT | FK → WorkOrderOperation.Id, NULL | |
| SourceLotId | BIGINT | FK → Lot.Id, NOT NULL | What was consumed |
| ProducedLotId | BIGINT | FK → Lot.Id, NULL | Output LOT (if applicable) |
| ProducedContainerId | BIGINT | FK → Container.Id, NULL | Output container (if applicable) |
| ConsumedItemId | BIGINT | FK → Item.Id, NOT NULL | |
| ProducedItemId | BIGINT | FK → Item.Id, NOT NULL | |
| PieceCount | INT | NOT NULL | |
| LocationId | BIGINT | FK → Location.Id, NOT NULL | |
| AppUserId | BIGINT | FK → AppUser.Id, NOT NULL | Operator who scanned the consumption |
| TerminalLocationId | BIGINT | FK → Location.Id (Terminal), NULL | Terminal where action was performed |
| TrayId | BIGINT | FK → ContainerTray.Id, NULL | |
| ProducedSerialNumber | NVARCHAR(50) | NULL | |
| ConsumedAt | DATETIME2(3) | NOT NULL | |

### RejectEvent

Detailed reject/scrap records.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| ProductionEventId | BIGINT | FK → ProductionEvent.Id, NULL | |
| LotId | BIGINT | FK → Lot.Id, NOT NULL | |
| DefectCodeId | BIGINT | FK → DefectCode.Id, NOT NULL | |
| Quantity | INT | NOT NULL | |
| ChargeToArea | NVARCHAR(100) | NULL | Area responsible for the reject |
| Remarks | NVARCHAR(500) | NULL | |
| AppUserId | BIGINT | FK → AppUser.Id, NOT NULL | Operator who recorded the reject |
| RecordedAt | DATETIME2(3) | NOT NULL | |

---

## 5. Quality Schema — MIXED SCOPE

> **Scope:**
> - `DefectCode` — **MVP** (supports reject tracking in Production Data Acquisition)
> - `QualitySpec`, `QualitySpecVersion`, `QualitySpecAttribute` — **MVP** (Inspections included)
> - `QualitySample`, `QualityResult` — **MVP** for inspections; **CONDITIONAL** for expanded sampling workflows (Scope Matrix row 9)
> - `QualityAttachment` — **MVP** (supports inspections and holds)
> - `HoldEvent` — **MVP-EXPANDED** (Holds included and expanded)
> - `NonConformance` — **FUTURE** — *NCM/Failure Analysis is not in current scope. Table retained because it completes the hold→NCM design separation. When activated, provides structured defect disposition without schema changes.*

Specification-driven inspections, non-conformance, hold management.

### DefectCode

~170 reject/defect reason codes.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Code | NVARCHAR(20) | NOT NULL, UNIQUE | |
| Description | NVARCHAR(500) | NOT NULL | |
| AreaLocationId | BIGINT | FK → Location.Id, NOT NULL | Area (ISA-95 Area, organizational grouping) |
| IsExcused | BIT | NOT NULL, DEFAULT 0 | Affects OEE quality calculation |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT GETDATE() | |
| DeprecatedAt | DATETIME2(3) | NULL | |

### QualitySpec

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Name | NVARCHAR(200) | NOT NULL | |
| ItemId | BIGINT | FK → Item.Id, NULL | |
| OperationTemplateId | BIGINT | FK → OperationTemplate.Id, NULL | |
| Description | NVARCHAR(500) | NULL | |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT GETDATE() | |
| DeprecatedAt | DATETIME2(3) | NULL | Header-level soft-delete — lets a spec be deprecated at the header level. Added migration `0017`. |
| DeprecatedByUserId | BIGINT | FK → AppUser.Id, NULL | Who deprecated the spec. Added migration `0017`. |

### QualitySpecVersion

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| QualitySpecId | BIGINT | FK → QualitySpec.Id, NOT NULL | |
| VersionNumber | INT | NOT NULL | |
| EffectiveFrom | DATETIME2(3) | NOT NULL | |
| DeprecatedAt | DATETIME2(3) | NULL | |
| CreatedByUserId | BIGINT | FK → AppUser.Id, NOT NULL | |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT GETDATE() | |

### QualitySpecAttribute

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| QualitySpecVersionId | BIGINT | FK → QualitySpecVersion.Id, NOT NULL | |
| AttributeName | NVARCHAR(100) | NOT NULL | |
| DataType | NVARCHAR(50) | NOT NULL | |
| Uom | NVARCHAR(20) | NULL | Legacy free-text UoM. Superseded by `UomId` for Config Tool editing; retained for back-compat. |
| UomId | BIGINT | FK → Parts.Uom.Id, NULL | Added migration `0017` — replaces free-text `Uom` usage by the Config Tool QualitySpec editor. |
| TargetValue | DECIMAL(18,6) | NULL | |
| LowerLimit | DECIMAL(18,6) | NULL | |
| UpperLimit | DECIMAL(18,6) | NULL | |
| IsRequired | BIT | NOT NULL, DEFAULT 1 | |
| SortOrder | INT | NOT NULL, DEFAULT 0 | |

### QualitySample

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| LotId | BIGINT | FK → Lot.Id, NOT NULL | |
| QualitySpecVersionId | BIGINT | FK → QualitySpecVersion.Id, NOT NULL | Version active at time of sampling |
| LocationId | BIGINT | FK → Location.Id, NULL | |
| SampleTriggerCodeId | BIGINT | FK → SampleTriggerCode.Id, NULL | What triggered this sample |
| SampledByUserId | BIGINT | FK → AppUser.Id, NOT NULL | |
| SampledAt | DATETIME2(3) | NOT NULL | |
| InspectionResultCodeId | BIGINT | FK → InspectionResultCode.Id, NOT NULL | Pass/Fail outcome |
| Remarks | NVARCHAR(500) | NULL | |

### QualityResult

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| QualitySampleId | BIGINT | FK → QualitySample.Id, NOT NULL | |
| QualitySpecAttributeId | BIGINT | FK → QualitySpecAttribute.Id, NOT NULL | |
| MeasuredValue | NVARCHAR(255) | NOT NULL | Canonical string storage of the measured value, parsed per `QualitySpecAttribute.DataType`. |
| NumericValue | DECIMAL(18,4) | NULL | **Added v1.9p.** Numeric shadow of `MeasuredValue`, populated when the attribute is numeric — enables indexable range / SPC / Cpk queries over measured results without parsing `MeasuredValue`. Mirrors `Workorder.ProductionEventValue.NumericValue`. NULL for non-numeric (string / boolean) attributes; the Arc 2 write proc sets it when `QualitySpecAttribute.DataType` ∈ {Integer, Decimal}. Cheap to add now (table is Arc 2-deferred, unbuilt); painful to retrofit onto a 20M+ row table later. |
| Uom | NVARCHAR(20) | NULL | |
| IsPass | BIT | NOT NULL | |

### QualityAttachment

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| QualitySampleId | BIGINT | FK → QualitySample.Id, NULL | |
| NonConformanceId | BIGINT | FK → NonConformance.Id, NULL | |
| FileName | NVARCHAR(255) | NOT NULL | |
| FileType | NVARCHAR(50) | NOT NULL | CSV, XLSX, PDF, PNG, JPG |
| FilePath | NVARCHAR(500) | NOT NULL | |
| UploadedAt | DATETIME2(3) | NOT NULL | |
| UploadedByUserId | BIGINT | FK → AppUser.Id, NOT NULL | |

### InspectionResultCode

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Code | NVARCHAR(20) | NOT NULL, UNIQUE | Pass, Fail |
| Name | NVARCHAR(100) | NOT NULL | |

### SampleTriggerCode

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Code | NVARCHAR(50) | NOT NULL, UNIQUE | ShiftStart, DieChange, ToolChange, FirstPiece, LastPiece, etc. |
| Name | NVARCHAR(100) | NOT NULL | |
| Description | NVARCHAR(500) | NULL | |

### HoldTypeCode

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Code | NVARCHAR(50) | NOT NULL, UNIQUE | Quality, CustomerComplaint, Precautionary |
| Name | NVARCHAR(100) | NOT NULL | |

### DispositionCode

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Code | NVARCHAR(50) | NOT NULL, UNIQUE | Pending, UseAsIs, Rework, Scrap, ReturnToVendor |
| Name | NVARCHAR(100) | NOT NULL | |

### NonConformance

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| LotId | BIGINT | FK → Lot.Id, NOT NULL | |
| DefectCodeId | BIGINT | FK → DefectCode.Id, NOT NULL | |
| Quantity | INT | NOT NULL | |
| DispositionCodeId | BIGINT | FK → DispositionCode.Id, NOT NULL | Current disposition |
| Remarks | NVARCHAR(500) | NULL | |
| ReportedByUserId | BIGINT | FK → AppUser.Id, NOT NULL | |
| TerminalLocationId | BIGINT | FK → Location.Id (Terminal), NULL | Terminal where action was performed |
| ReportedAt | DATETIME2(3) | NOT NULL | |
| ResolvedAt | DATETIME2(3) | NULL | |
| ResolvedByUserId | BIGINT | FK → AppUser.Id, NULL | |

### HoldEvent

A hold placed on a LOT. Same lifecycle pattern as `DowntimeEvent` — created on placement, updated on release. Active holds have `ReleasedAt IS NULL`.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| LotId | BIGINT | FK → Lot.Id, NOT NULL | |
| NonConformanceId | BIGINT | FK → NonConformance.Id, NULL | Nullable — holds can be precautionary |
| HoldTypeCodeId | BIGINT | FK → HoldTypeCode.Id, NOT NULL | Quality, CustomerComplaint, Precautionary |
| Reason | NVARCHAR(500) | NOT NULL | |
| PlacedByUserId | BIGINT | FK → AppUser.Id, NOT NULL | |
| PlacedAt | DATETIME2(3) | NOT NULL | |
| ReleasedByUserId | BIGINT | FK → AppUser.Id, NULL | |
| ReleasedAt | DATETIME2(3) | NULL | NULL while hold is active |
| ReleaseRemarks | NVARCHAR(500) | NULL | |

---

## 6. OEE Schema — MIXED SCOPE

> **Scope:**
> - `DowntimeReasonType`, `DowntimeReasonCode` — **MVP** (Downtime included)
> - `ShiftSchedule`, `Shift` — **MVP** (supports downtime context and production reporting)
> - `DowntimeEvent` — **MVP** (Downtime included)
> - `OeeSnapshot` — **FUTURE** — *OEE is not in current scope. Table retained because it is purely derivative of MVP data (downtime events + production events + shift instances). Activation requires only a scheduled calculation job — no new data capture.*

Downtime tracking, shift management, materialized OEE metrics.

### DowntimeReasonType

Read-only, seeded in migration `0009`. 6 fixed rows.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Code | NVARCHAR(30) | NOT NULL, UNIQUE | Equipment, Miscellaneous, Mold, Quality, Setup, Unscheduled |
| Name | NVARCHAR(100) | NOT NULL | |

### DowntimeReasonCode

~353 active seed rows from `downtime_reason_codes.csv` (DC=86, MS=239, TS=25). Loaded via `Oee.DowntimeReasonCode_BulkLoadFromSeed`.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Code | NVARCHAR(20) | NOT NULL, UNIQUE | Generated as `{DeptCode}-{NNNN}` (e.g., `DC-0003`) by the bulk-load proc from the CSV's `DeptCode` + zero-padded `ReasonId`. Engineering-created codes are free-form. |
| Description | NVARCHAR(500) | NOT NULL | |
| AreaLocationId | BIGINT | FK → Location.Id, NOT NULL | Area (organizational grouping) |
| DowntimeReasonTypeId | BIGINT | FK → DowntimeReasonType.Id, NULL | NULL allowed — CSV rows with missing TypeDesc load as NULL and engineering backfills via `_Update` before go-live |
| DowntimeSourceCodeId | BIGINT | FK → DowntimeSourceCode.Id, NULL | CSV carries no source column; always NULL at initial load |
| IsExcused | BIT | NOT NULL, DEFAULT 0 | |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT SYSUTCDATETIME() | |
| CreatedByUserId | BIGINT | FK → AppUser.Id, NOT NULL | |
| UpdatedAt | DATETIME2(3) | NULL | |
| UpdatedByUserId | BIGINT | FK → AppUser.Id, NULL | |
| DeprecatedAt | DATETIME2(3) | NULL | |

### ShiftSchedule

Named shift patterns (First Shift 6a–2p M-F, Second Shift 2p–10p, Weekend OT, etc.).

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Name | NVARCHAR(100) | NOT NULL, UNIQUE | |
| Description | NVARCHAR(500) | NULL | |
| StartTime | TIME(0) | NOT NULL | |
| EndTime | TIME(0) | NOT NULL | Shift spans midnight when `EndTime < StartTime` (runtime handles this) |
| DaysOfWeekBitmask | INT | NOT NULL, CHECK 1-127 | Mon=1, Tue=2, Wed=4, Thu=8, Fri=16, Sat=32, Sun=64. Mon-Fri = 31; Sat+Sun = 96. |
| EffectiveFrom | DATE | NOT NULL | |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT SYSUTCDATETIME() | |
| CreatedByUserId | BIGINT | FK → AppUser.Id, NOT NULL | |
| UpdatedAt | DATETIME2(3) | NULL | |
| UpdatedByUserId | BIGINT | FK → AppUser.Id, NULL | |
| DeprecatedAt | DATETIME2(3) | NULL | |

### Shift

Runtime shift instances — written by Arc 2 (plant-floor shift controller) when a scheduled shift starts. The Config Tool only reads via `Oee.Shift_List` for admin visibility.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| ShiftScheduleId | BIGINT | FK → ShiftSchedule.Id, NOT NULL | |
| ActualStart | DATETIME2(3) | NOT NULL | |
| ActualEnd | DATETIME2(3) | NULL | NULL while the shift is active |
| Remarks | NVARCHAR(500) | NULL | |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT SYSUTCDATETIME() | |

### DowntimeSourceCode

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Code | NVARCHAR(20) | NOT NULL, UNIQUE | Manual, PLC |
| Name | NVARCHAR(100) | NOT NULL | |

### DowntimeEvent

Append-only. Never overwrite started_at.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| LocationId | BIGINT | FK → Location.Id, NOT NULL | Machine |
| DowntimeReasonCodeId | BIGINT | FK → DowntimeReasonCode.Id, NULL | May be assigned later |
| ShiftId | BIGINT | FK → Shift.Id, NULL | |
| StartedAt | DATETIME2(3) | NOT NULL | |
| EndedAt | DATETIME2(3) | NULL | NULL while event is open |
| DowntimeSourceCodeId | BIGINT | FK → DowntimeSourceCode.Id, NOT NULL | How this event was recorded |
| AppUserId | BIGINT | FK → AppUser.Id, NULL | Operator who recorded / acknowledged the event (NULL for PLC-driven events without operator action) |
| ShotCount | INT | NULL | Die cast warm-up/setup shot count (when reason_type = Setup) |
| Remarks | NVARCHAR(500) | NULL | |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT GETDATE() | |

**Warm-up shot tracking (UJ-14, ✅ Resolved 2026-04-27 per OIR v2.14).** Warm-up shots are tracked as a downtime sub-category (`DowntimeReasonType` = Setup) with the `ShotCount` column on the `DowntimeEvent` record itself. This keeps warm-up time and shot count in a single record. The Die Cast production screen records good/bad shot counts on the `ProductionEvent`; warm-up shot counts go here.

### OeeSnapshot

Materialized OEE per machine per shift. Derivative, not system of record.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| LocationId | BIGINT | FK → Location.Id, NOT NULL | Machine |
| ShiftId | BIGINT | FK → Shift.Id, NOT NULL | |
| SnapshotDate | DATE | NOT NULL | |
| Availability | DECIMAL(5,4) | NOT NULL | 0.0000 – 1.0000 |
| Performance | DECIMAL(5,4) | NOT NULL | |
| QualityRate | DECIMAL(5,4) | NOT NULL | |
| Oee | DECIMAL(5,4) | NOT NULL | availability × performance × quality_rate |
| PlannedProductionTimeMin | INT | NOT NULL | |
| ActualRunTimeMin | INT | NOT NULL | |
| TotalDowntimeMin | INT | NOT NULL | |
| GoodCount | INT | NOT NULL | |
| TotalCount | INT | NOT NULL | |
| RejectCount | INT | NOT NULL | |
| CalculatedAt | DATETIME2(3) | NOT NULL | |

---

## 7. Tools Schema — MIXED SCOPE

> **Scope:**
> - `ToolType`, `ToolAttributeDefinition`, `Tool`, `ToolAttribute`, `ToolCavity`, `ToolAssignment`, status code tables, `DieRank`, `DieRankCompatibility` — **MVP**
> - Configuration Tool CRUD screens for all of the above — **MVP** (Phase 9 of the Config Tool phased plan)
> - Maintenance WO *flow* (screens / scheduling / state machine) — **FUTURE** (schema hook is the `Workorder.WorkOrderType=Maintenance` seed + nullable `Workorder.WorkOrder.ToolId` — see §4)
> - Tool-life threshold alarms — **FUTURE** (scheduled Gateway Script pattern when MPP asks; no schema changes required — shot counts derive from `Workorder.ProductionEvent`)
> - Cross-plant tool transfer history — **FUTURE** (single-plant MVP)
> - Tool photograph / document attachments — **FUTURE**

Added v1.7 as part of the Phase B Tool Management refactor. Promotes **Tool** from the pre-v1.7 `LocationAttribute` historical-snapshot pattern (where `Workorder.ProductionEvent.DieIdentifier` is just an `NVARCHAR` copy of the machine's current die-attribute value) to a **first-class polymorphic subsystem** covering dies, cutters, jigs, gauges, assembly fixtures, trim tools — any discrete piece of production equipment that has its own identity and lifecycle, can be checked in/out of Cells, carries type-specific attributes, optionally has cavities, and may be the target of a (FUTURE) maintenance work order.

Full design spec: `docs/superpowers/specs/2026-04-21-tool-management-design.md` v0.2.

### Design Overview — polymorphic pattern (mirrors Location)

The Tools model follows the same polymorphism Location uses, but with one layer removed. Location needed two header tables (`LocationType` for the ISA-95 tier + `LocationTypeDefinition` for polymorphic kinds within a tier) because it has both a fixed hierarchy AND polymorphic kinds within the hierarchy. Tools are a **grouping**, not a hierarchy — there is no tier structure — so the equivalent pattern collapses to one `ToolType` header table plus the attribute-definition and value tables:

```
Tools.ToolType                   -- polymorphic kinds (Die, Cutter, Jig, Gauge, AssemblyFixture, TrimTool)
Tools.ToolAttributeDefinition    -- attribute schema per kind
Tools.Tool                       -- concrete tools
Tools.ToolAttribute              -- attribute values
Tools.ToolCavity                 -- cavity children (only for HasCavities types)
Tools.ToolAssignment             -- check-in/out history against Cells
```

If sub-categories ever become useful (e.g., splitting "Die" into "Single-Cavity Die" vs "Multi-Cavity Die"), that's the point to introduce a `ToolSubType` table — not now.

**Block concept** (raised in the 2026-04-20 meeting, "assign them to blocks" for fast die-cast changeover): deliberately **not** modelled in the Tools schema. Location-eligibility for a part running on a machine is already covered by the ISA-95 hierarchy + `Parts.ItemLocation`. Phase D's OI-08 addenda confirms hierarchical resolution: an Item that's eligible on an Area propagates to every Cell under that Area without explicit rows.

### ToolType

Polymorphic kinds. Read-only in MVP — seeded at migration time, no CRUD procs. Follows the precedent set by `Location.LocationType` / `Location.LocationTypeDefinition`.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK IDENTITY | |
| Code | NVARCHAR(50) | NOT NULL, UNIQUE | `Die`, `Cutter`, `Jig`, `Gauge`, `AssemblyFixture`, `TrimTool` |
| Name | NVARCHAR(100) | NOT NULL | Display name |
| Description | NVARCHAR(500) | NULL | |
| Icon | NVARCHAR(100) | NULL | Perspective tree component icon (matches `LocationTypeDefinition.Icon` pattern; NULL at deployment, populated via Config Tool) |
| HasCavities | BIT | NOT NULL, DEFAULT 0 | `ToolCavity` rows are only valid for Tools whose type has this flag set |
| CompatibleLocationTypeDefinitionId | BIGINT | FK → Location.LocationTypeDefinition.Id, NULL | Added v1.9o (migration `0018`). The `Cell`-kind a tool of this type may mount on — drives the Mount-to-Cell dropdown filter (`Tools.Tool_ListCompatibleCells`). NON-NULL restricts the dropdown to that single cell kind; NULL = no restriction (all `Cell`-tier Locations). One-to-one by design — a tool type maps to at most one cell kind. Seeded `Die → DieCastMachine`; all other types NULL until their flows activate. |
| SortOrder | INT | NOT NULL, DEFAULT 0 | UI ordering |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT GETDATE() | |
| DeprecatedAt | DATETIME2(3) | NULL | Soft delete |

**Seed data (Phase G migration):**

| Code | Name | HasCavities | Notes |
|---|---|---|---|
| Die | Die Cast Die | 1 | Dies used on die cast machines. `CompatibleLocationTypeDefinitionId → DieCastMachine` (seeded v1.9o). |
| Cutter | Machining Cutter | 0 | Tool heads / inserts on CNC machines |
| Jig | Assembly Jig | 0 | Fixtures on assembly stations |
| Gauge | Inspection Gauge | 0 | Measurement tools |
| AssemblyFixture | Assembly Fixture | 0 | Trim-shop and assembly fixtures |
| TrimTool | Trim Shop Tool | 0 | Trim-specific tooling |

### ToolAttributeDefinition

Attribute schema per tool type. Mirrors `Location.LocationAttributeDefinition`.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK IDENTITY | |
| ToolTypeId | BIGINT | FK → ToolType.Id, NOT NULL | Which kind this attribute applies to |
| Code | NVARCHAR(50) | NOT NULL | Attribute code (e.g., `CycleTimeSec`, `Tonnage`, `InsertCount`) |
| Name | NVARCHAR(100) | NOT NULL | Display label |
| DataType | NVARCHAR(20) | NOT NULL | `String`, `Integer`, `Decimal`, `Boolean`, `Date` (matches `LocationAttributeDefinition.DataType` values) |
| IsRequired | BIT | NOT NULL, DEFAULT 0 | |
| SortOrder | INT | NOT NULL, DEFAULT 0 | Up/down arrow ordering — no drag-and-drop per UI convention |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT GETDATE() | |
| DeprecatedAt | DATETIME2(3) | NULL | Soft delete |

**Unique:** `UQ_ToolAttributeDefinition_ActiveTypeCode` — filtered UNIQUE `(ToolTypeId, Code)` where `DeprecatedAt IS NULL`.

**Seed:** none. Ships empty; engineering adds `CycleTimeSec`, `CavityCount`, `Tonnage`, etc. via the Config Tool as real tools arrive (same empty-at-rollout pattern as `LocationAttributeDefinition`).

### Tool

Concrete tools. System of record for tool identity.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK IDENTITY | |
| ToolTypeId | BIGINT | FK → ToolType.Id, NOT NULL | Polymorphic type |
| Code | NVARCHAR(50) | NOT NULL, UNIQUE | Die number, cutter ID, etc. (e.g., `DC-042`) |
| Name | NVARCHAR(100) | NOT NULL | Human-friendly name |
| Description | NVARCHAR(500) | NULL | |
| DieRankId | BIGINT | FK → DieRank.Id, NULL | Die-type only; NULL for all other types. Application-level validation enforces this — no CHECK because the "die-type only" rule needs a join |
| StatusCodeId | BIGINT | FK → ToolStatusCode.Id, NOT NULL | Active / UnderRepair / Scrapped / Retired |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT GETDATE() | |
| UpdatedAt | DATETIME2(3) | NULL | |
| CreatedByUserId | BIGINT | FK → AppUser.Id, NOT NULL | |
| UpdatedByUserId | BIGINT | FK → AppUser.Id, NULL | |
| DeprecatedAt | DATETIME2(3) | NULL | Soft delete — separate from `StatusCode = Retired` (Retired is the business state; DeprecatedAt is the row-lifecycle state) |

**No shot counter column.** Shot counts derive from `Workorder.ProductionEvent` group-by `(Tool, Cavity)`. Rationale: avoids the double-write + drift problem between an aggregate column and the event stream; leaves all reset-logic to a future Gateway script rather than embedding it in every write path.

### ToolAttribute

Attribute values. Mirrors `Location.LocationAttribute`.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK IDENTITY | |
| ToolId | BIGINT | FK → Tool.Id, NOT NULL | |
| ToolAttributeDefinitionId | BIGINT | FK → ToolAttributeDefinition.Id, NOT NULL | |
| Value | NVARCHAR(500) | NOT NULL | Stored as text; interpreted per definition's `DataType` |
| UpdatedAt | DATETIME2(3) | NULL | |
| UpdatedByUserId | BIGINT | FK → AppUser.Id, NULL | |

**Unique:** `UQ_ToolAttribute_ToolAttributeDefinition` — UNIQUE `(ToolId, ToolAttributeDefinitionId)`. One value per attribute per tool.

### ToolCavity

Child of Tool. Only valid for Tools whose `ToolType.HasCavities = 1` — application-level validation enforces, no CHECK.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK IDENTITY | |
| ToolId | BIGINT | FK → Tool.Id, NOT NULL | Parent die |
| CavityNumber | INT | NOT NULL | 1, 2, 3, … up to the die's cavity count |
| StatusCodeId | BIGINT | FK → ToolCavityStatusCode.Id, NOT NULL | Active / Closed / Scrapped |
| Description | NVARCHAR(500) | NULL | Per-cavity notes (e.g., "small porosity tendency") |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT GETDATE() | |
| UpdatedAt | DATETIME2(3) | NULL | |
| CreatedByUserId | BIGINT | FK → AppUser.Id, NOT NULL | |
| UpdatedByUserId | BIGINT | FK → AppUser.Id, NULL | |
| DeprecatedAt | DATETIME2(3) | NULL | Soft delete |

**Unique:** `UQ_ToolCavity_ActiveToolCavityNumber` — filtered UNIQUE `(ToolId, CavityNumber)` where `DeprecatedAt IS NULL`.

**Status semantics:**
- **Active** — cavity producing acceptable parts.
- **Closed** — cavity physically shut off (die still runs on remaining cavities).
- **Scrapped** — cavity physically destroyed (die may still run on remaining cavities, or die itself may be scrapped — the two are independent state changes).

Shoot-and-scrap behaviour (producing rejected parts each cycle from a degraded cavity) is **not** a cavity state — it's operational behaviour captured at `Workorder.RejectEvent`. Cavity stays Active until someone decides to Close or Scrap it.

Cavity numbers are immutable after creation (only `StatusCodeId` is editable via the runtime proc surface); the spec only exposes `_Create`, `_UpdateStatus`, `_Deprecate` — no general `_Update`.

### ToolAssignment

Append-only check-in / out history. A Tool can be mounted on a Cell; release closes the row by setting `ReleasedAt`.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK IDENTITY | |
| ToolId | BIGINT | FK → Tool.Id, NOT NULL | |
| CellLocationId | BIGINT | FK → Location.Location.Id, NOT NULL | Cell the tool is mounted on (application validates the Location is Cell-tier) |
| AssignedAt | DATETIME2(3) | NOT NULL, DEFAULT GETDATE() | |
| ReleasedAt | DATETIME2(3) | NULL | NULL = currently mounted |
| AssignedByUserId | BIGINT | FK → AppUser.Id, NOT NULL | Supervisor who mounted (elevated action per FDS-04-007) |
| ReleasedByUserId | BIGINT | FK → AppUser.Id, NULL | Supervisor who released (elevated action per FDS-04-007) |
| Notes | NVARCHAR(500) | NULL | |

**Unique constraints (migration `0010_phase9_tools_and_workorder.sql`):**
- `UQ_ToolAssignment_ActiveTool` — filtered UNIQUE on `ToolId` where `ReleasedAt IS NULL`. A tool can only be mounted on one Cell at a time; mounting elsewhere requires releasing the previous assignment first.
- `UQ_ToolAssignment_ActiveCell` — filtered UNIQUE on `CellLocationId` where `ReleasedAt IS NULL`. Enforces **one active mounted Tool per Cell** — correct for Die Cast.

**Known limitation (flagged v1.9, non-blocking for MVP):** The `UQ_ToolAssignment_ActiveCell` rule is **Die-only-correct**. When non-Die Tool types activate (Machining cutters/fixtures/jigs coexist on a cell; Trim dies + deburr tools + jigs; Assembly fixtures + jigs + gauges), this constraint breaks. Tool tracking is Die-focused in MVP, so the constraint doesn't bite yet. Post-MVP adjustment path: either scope the UNIQUE to `(CellLocationId, ToolTypeId=Die)` by joining `Tool.ToolTypeId` via an indexed view or a filtered-on-Die filtered unique, OR drop the Cell UNIQUE entirely and let `UQ_ToolAssignment_ActiveTool` carry the rule. Either is a one-migration refactor when the time comes.

**Elevated action:** Tool mount / release is in the FDS-04-007 elevated-action list (per-action AD elevation prompt, no session-sticky elevation).

### ToolStatusCode

Read-only code table. Seeded at migration time.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Code | NVARCHAR(20) | NOT NULL, UNIQUE | Active / UnderRepair / Scrapped / Retired |
| Name | NVARCHAR(100) | NOT NULL | |
| Description | NVARCHAR(500) | NULL | |

**Seed data:**

| Code | Name | Notes |
|---|---|---|
| Active | Active | In service |
| UnderRepair | Under Repair | Removed from service for repair |
| Scrapped | Scrapped | Physically destroyed / discarded |
| Retired | Retired | End-of-life, archived |

### ToolCavityStatusCode

Read-only code table. Seeded at migration time.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Code | NVARCHAR(20) | NOT NULL, UNIQUE | Active / Closed / Scrapped |
| Name | NVARCHAR(100) | NOT NULL | |
| Description | NVARCHAR(500) | NULL | |

**Seed data:**

| Code | Name | Notes |
|---|---|---|
| Active | Active | Producing acceptable parts |
| Closed | Closed | Shut off; die runs without this cavity |
| Scrapped | Scrapped | Physically destroyed |

### DieRank

Code table. Ships **empty** — MPP Quality owes the authoritative ranking scheme (the 2026-04-20 meeting proposed A–E but MPP hasn't confirmed).

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK IDENTITY | |
| Code | NVARCHAR(20) | NOT NULL, UNIQUE | Engineering populates via Config Tool once MPP Quality delivers |
| Name | NVARCHAR(100) | NOT NULL | |
| Description | NVARCHAR(500) | NULL | |
| SortOrder | INT | NOT NULL, DEFAULT 0 | Up/down arrow ordering |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT GETDATE() | |
| DeprecatedAt | DATETIME2(3) | NULL | |

**Seed data:** none. The Configuration Tool has a Die Rank admin screen for Engineering to populate.

### DieRankCompatibility

Junction. Ships **empty** — MPP Quality owes the compatibility matrix.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK IDENTITY | |
| RankAId | BIGINT | FK → DieRank.Id, NOT NULL | |
| RankBId | BIGINT | FK → DieRank.Id, NOT NULL | |
| CanMix | BIT | NOT NULL | |
| CreatedAt | DATETIME2(3) | NOT NULL, DEFAULT GETDATE() | |
| UpdatedAt | DATETIME2(3) | NULL | |

**Unique:** `UQ_DieRankCompatibility_Pair` — UNIQUE `(RankAId, RankBId)`. Application-level convention: pairs are stored canonicalised (smaller `Id` first) so a single lookup covers both directions.

**Merge validation rule (OI-05):** `Lots.Lot_Merge` consults this table on cross-die merges:
- Same die on both lots → merge proceeds (no rank involvement).
- Different dies → merge is **rejected** with message "Cross-die merges require die rank compatibility rules — contact MPP Quality" *until the matrix is populated*.
- Once populated, merge succeeds when the pair's `CanMix = 1`, else the rejection is specific ("Die rank {A} cannot mix with die rank {B}").
- **Supervisor override:** the standard FDS-04-007 AD elevation prompt unlocks the merge regardless of the matrix state (same pattern as every other gated action).

### Cross-references

- **Workorder.WorkOrder.ToolId** (§4) — nullable FK into `Tools.Tool`. Schema hook for **FUTURE** Maintenance WOs targeting a Tool. The only `WorkOrderType` seeded in MVP is `Production`, which legitimately has NULL `ToolId`; the proc layer will enforce non-NULL on Maintenance WOs once that flow activates.
- **Workorder.ProductionEvent → Lots.Lot.ToolId / Lots.Lot.ToolCavityId** (§4 + §3) — Tool and Cavity at event time are derived via `ProductionEvent.LotId → Lots.Lot.ToolId` / `.ToolCavityId`. The pre-v1.9 `ProductionEvent.DieIdentifier` (NVARCHAR snapshot) and `CavityNumber` columns were dropped in the v1.9 reshape — `Lots.Lot` is the system of record for die-cast LOTs and never mutates the Tool / Cavity FK after creation, so the snapshot was redundant.
- **Audit.LogEntityType** (§8) — 8 new seed rows in Phase G for Tool, ToolAttributeDefinition, ToolAttribute, ToolCavity, ToolAssignment, DieRank, DieRankCompatibility, and `Workorder.WorkOrderType`. Every `Tools.*` mutation proc logs to `Audit.ConfigLog` on success and `Audit.FailureLog` on rejection.
- **Audit.LogEntityType** (§8) — v1.8 adds 1 further seed row in Phase G: `ScrapSource` (Workorder.ScrapSource, OI-20).

---

## 8. Audit Schema — `MVP`

> **Scope:** All tables MVP. Foundational — 20-year retention requirement applies across all scope phases.

Immutable, append-only logging. BIGINT PKs for high-volume append.

### LogSeverity

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Code | NVARCHAR(20) | NOT NULL, UNIQUE | ERROR, WARNING, INFO |
| Name | NVARCHAR(100) | NOT NULL | |

### LogEventType

Normalized vocabulary for what happened. Shared across all log tables.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Code | NVARCHAR(50) | NOT NULL, UNIQUE | LotCreated, LotMoved, ProductionRecorded, HoldPlaced, etc. |
| Name | NVARCHAR(200) | NOT NULL | |
| Description | NVARCHAR(500) | NULL | |

### LogEntityType

Normalized vocabulary for what was affected. Shared across operation_log and config_log.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK | |
| Code | NVARCHAR(50) | NOT NULL, UNIQUE | LOT, CONTAINER, WORK_ORDER, ITEM, LOCATION, etc. |
| Name | NVARCHAR(200) | NOT NULL | |
| Description | NVARCHAR(500) | NULL | |

### OperationLog

Every shop-floor action.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK, IDENTITY | |
| LoggedAt | DATETIME2(3) | NOT NULL | |
| UserId | BIGINT | FK → AppUser.Id, NULL | |
| TerminalLocationId | BIGINT | FK → Location.Id (Terminal), NULL | Terminal where action was performed |
| LocationId | BIGINT | FK → Location.Id, NULL | Machine/location context |
| LogSeverityId | BIGINT | FK → LogSeverity.Id, NOT NULL | |
| LogEventTypeId | BIGINT | FK → LogEventType.Id, NOT NULL | |
| LogEntityTypeId | BIGINT | FK → LogEntityType.Id, NOT NULL | |
| EntityId | BIGINT | NULL | PK of the affected entity |
| Description | NVARCHAR(1000) | NOT NULL | |
| OldValue | NVARCHAR(500) | NULL | |
| NewValue | NVARCHAR(500) | NULL | |

### ConfigLog

Engineering and admin configuration changes.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK, IDENTITY | |
| LoggedAt | DATETIME2(3) | NOT NULL | |
| UserId | BIGINT | FK → AppUser.Id, NULL | |
| LogSeverityId | BIGINT | FK → LogSeverity.Id, NOT NULL | |
| LogEventTypeId | BIGINT | FK → LogEventType.Id, NOT NULL | |
| LogEntityTypeId | BIGINT | FK → LogEntityType.Id, NOT NULL | |
| EntityId | BIGINT | NULL | |
| Description | NVARCHAR(1000) | NOT NULL | |
| Changes | NVARCHAR(MAX) | NULL | JSON or structured diff |

### InterfaceLog

External system communications.

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK, IDENTITY | |
| LoggedAt | DATETIME2(3) | NOT NULL | |
| SystemName | NVARCHAR(50) | NOT NULL | AIM, PLC, MACOLA, INTELEX |
| Direction | NVARCHAR(10) | NOT NULL | Inbound, OUTBOUND |
| LogEventTypeId | BIGINT | FK → LogEventType.Id, NOT NULL | |
| Description | NVARCHAR(1000) | NOT NULL | |
| RequestPayload | NVARCHAR(MAX) | NULL | When high-fidelity logging enabled |
| ResponsePayload | NVARCHAR(MAX) | NULL | |
| ErrorCondition | NVARCHAR(200) | NULL | |
| ErrorDescription | NVARCHAR(1000) | NULL | |
| IsHighFidelity | BIT | NOT NULL, DEFAULT 0 | |

### FailureLog

Records attempted but **rejected** stored procedure calls — parameter validation failures, business rule violations, FK mismatches, and unexpected exceptions caught by a CATCH handler. Complements `ConfigLog` and `OperationLog`: those tables record what *succeeded*, `FailureLog` records what was *attempted and blocked*. Used for UX improvement (surface common rejection reasons), abuse detection, and root-cause analysis.

Every shared audit proc writes here on failure. Mutating stored procs call `Audit_LogFailure` from any validation-failure path **and** from their CATCH handler (outside the rolled-back transaction, so the failure record survives).

| Column | Type | Constraints | Description |
|---|---|---|---|
| Id | BIGINT | PK, IDENTITY | |
| AttemptedAt | DATETIME2(3) | NOT NULL, DEFAULT SYSUTCDATETIME() | When the call was attempted |
| AppUserId | BIGINT | FK → AppUser.Id, NOT NULL | Who attempted the action |
| LogEntityTypeId | BIGINT | FK → LogEntityType.Id, NOT NULL | What kind of entity (e.g., Location, Item, Bom) |
| EntityId | BIGINT | NULL | Target entity Id; NULL for Create attempts where no Id exists yet |
| LogEventTypeId | BIGINT | FK → LogEventType.Id, NOT NULL | What action was attempted (Created, Updated, Deprecated, etc.) |
| FailureReason | NVARCHAR(500) | NOT NULL | The `@Message` value returned to the caller |
| ProcedureName | NVARCHAR(200) | NOT NULL | Fully-qualified proc name (e.g., `Location.Location_Create`) |
| AttemptedParameters | NVARCHAR(MAX) | NULL | JSON snapshot of the input parameters for debugging |

**Indexes:**

| Index | Columns | Purpose |
|---|---|---|
| IX_FailureLog_AttemptedAt | `AttemptedAt DESC` | Recent failures dashboard |
| IX_FailureLog_AppUser | `AppUserId, AttemptedAt DESC` | Per-user failure history |
| IX_FailureLog_EntityEvent | `LogEntityTypeId, LogEventTypeId, AttemptedAt DESC` | "Top rejection reasons by entity type" |
| IX_FailureLog_ProcedureName | `ProcedureName, AttemptedAt DESC` | "Which procs are failing most" |
