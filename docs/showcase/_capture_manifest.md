# Showcase Capture Manifest (staging)

Gateway: `http://localhost:8088`. Perspective clients:
- Shop floor: `http://localhost:8088/data/perspective/client/MPP`
- Config tool: `http://localhost:8088/data/perspective/client/MPP_Config`

**Hero FG lot:** Id **31**, LotName **MESL3000014** — "Oil Pump Housing Assembly", shipped, genealogy depth 5.

## Capture list (against MPP_MES_Showcase after datasource swap)

| Cap | Screen | URL (append to shop-floor/config client base) | Notes |
|-----|--------|-----------------------------------------------|-------|
| C1 | LOT Detail (hero) | `/MPP/shop-floor/lot-detail/31` | header + genealogy + production events + as-built BOM tab; AVOID linked-container/AIM tab |
| C2 | Genealogy tree | `/MPP/shop-floor/genealogy` (resolve lot 31 / MESL3000014) | multi-level tree |
| C3 | LOT search | `/MPP/shop-floor/lot-search` | results list |
| C4 | Movement (operator) | `/MPP/shop-floor/machining` or `/MPP/shop-floor/assembly-nonserialized` | WIP queue + move |
| C5 | Plant-wide WIP | `/MPP/shop-floor/supervisor` | live inventory |
| C6 | Reporting hub | `/MPP/shop-floor/reports` | tile rail |
| C7 | Lot Detail PDF | Reports hub -> Lot Detail (lot 31) | 2-page traceability |
| C8 | Current Inventory PDF | Reports hub -> Current Inventory | plantwide WIP |
| C9 | Production Line Performance PDF | Reports hub -> Production Line Performance | 4-week trend |
| C10 | Plant Hierarchy | `/MPP_Config/plant` | ISA-95 tree |
| C11 | Item Master | `/MPP_Config/items` | part config |
| C12 | Operation Templates (was Quality Specs) | `/MPP_Config/parts/operation-templates` | 7 templates + Draft/Published lifecycle (reinforces versioning/compliance) |
| C13 | Audit Browser (compliance support) | `/MPP_Config/audit-log` | attribution + old/new values |

Config note: `Fuel Pump (6NA 6VJ)` is a line Name that may appear on inventory/supervisor screens — not a forbidden identifier (no Honda/Madison/MPP/AIM) but code-y; acceptable, rename only if it reads poorly on capture.

## Verified compliance table (slide 13) — all rows schema-confirmed 2026-08-12

| Architecture (verified object) | Supports |
|---|---|
| Append-only event tables (`LotEventLog`, `OperationLog`, `ProductionEvent`, `ConsumptionEvent`) + `Audit.ConfigLog` (`UserId`, `OldValue`, `NewValue`, `Description`, `LogEventTypeId`) | 21 CFR Part 11 audit trail; ALCOA+ Attributable / Contemporaneous / Enduring |
| AD identity mapping (`AppUser.AdAccount`) + audited per-action elevation (`ElevationGranted` / `ElevationDenied` event types) | Part 11 authority checks / electronic-signature-style authorization (grant AND deny recorded) |
| No hard deletes — 31 `DeprecatedAt` soft-delete columns; 42 UTC `CreatedAt` columns | Record protection & retention; ALCOA+ Original / Enduring / Available |
| Full lot genealogy (`LotGenealogy` adjacency + `LotGenealogyClosure`) + production-event history + as-built BOM (`Lot.BomId`) | Device History Record traceability (21 CFR 820 / QMSR / ISO 13485), forward + backward |
| Spec-driven quality (`QualitySpec` / `QualitySpecVersion` / `QualitySample`) + hold / nonconformance (`HoldEvent`, `HoldTypeCode`, `DefectCode`) | Nonconformance handling (820.90 / ISO 13485 §8.3) |
| Draft -> Published -> Deprecated version control (`VersionNumber` + `PublishedAt` on `Bom`, `RouteTemplate`, `OperationTemplate`, `QualitySpecVersion`) | Controlled document / specification revision control |
