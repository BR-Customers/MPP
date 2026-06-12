# Arc 2 Phase 2 — LOT Search View (Ignition) — Design

**Date:** 2026-06-12
**Status:** Draft for review
**Scope:** The **LOT Search** screen — a cross-Area lookup that lists LOTs and routes into LOT Detail. Second of the four deferred Phase 2 views.

## 1. Source of truth

Canonical mockup: `mockup/plantFloor.html` → `div[data-panel="lots"]` ("LOT Search"). Elevated, cross-Area lookup; search by LotName / SerialNumber / AIM Shipper ID / Vendor LOT / Part Number; Status + Origin filters; results list → click row → LOT Detail.

## 2. Layout (faithful to mockup)

- **Search bar:** free-text Query input + Status filter dropdown (Any / Good / Hold / Closed / Scrap) + Origin filter dropdown (Any / Manufactured / Received / ReceivedOffsite) + Search button.
- **Results:** count header ("N results · sorted by recency"); a list of result rows — each shows Origin · LotName (mono) · `Item · pcs · location` detail · status pill · created time · **Open** → navigates to `/shop-floor/lot-detail?lotId=<id>`.

## 3. Reconciliation to Phase 2 SQL

`Lots.Lot_List` (shipped) filters only by `@ItemId` / `@CurrentLocationId` / `@LotStatusId` — **no free-text**. The mockup's text search is not backed, so this view needs a **new `Lot_Search` proc**.

- **Buildable now:** text search over fields that live on built tables — `Lots.Lot.LotName`, `Lots.Lot.VendorLotNumber`, `Parts.Item.PartNumber`; plus Status + Origin filters.
- **Deferred (later-phase, not in the proc):** **SerialNumber** search (`Lots.SerializedPart` — Phase 3) and **AIM Shipper ID** search (`Lots.ShippingLabel` — Phase 6). The Query placeholder text will note "LotName / Vendor LOT / Part Number" until those land.

## 4. New SQL — `Lots.Lot_Search`

```
CREATE OR ALTER PROC Lots.Lot_Search
    @Query           NVARCHAR(100) = NULL,   -- LIKE over LotName / VendorLotNumber / Item.PartNumber
    @LotStatusId     BIGINT        = NULL,
    @LotOriginTypeId BIGINT        = NULL,
    @LimitRows       INT           = 100
```

Single result set mirroring `Lot_List`'s columns **plus** `LotOriginTypeCode`, `CreatedAt`, and `COUNT(*) OVER() AS TotalCount`. `@Query` NULL/empty → filter ignored (returns recent LOTs). `LIKE N'%' + @Query + '%'` across the three text columns; `@LotStatusId` / `@LotOriginTypeId` optional equality filters. `ORDER BY CreatedAt DESC`, `TOP (@LimitRows)`. READ proc — no status row (FDS-11-011 single result set). New test file in `sql/tests/0021_PlantFloor_Lot_Lifecycle/` asserting: text match on LotName, match on PartNumber, status filter, origin filter, limit cap, empty-query recency.

## 5. Data contract

| UI element | Proc | NQ (Core) | Entity method |
|---|---|---|---|
| Results list | **NEW** `Lots.Lot_Search` | `lots/Lot_Search` (params `query` s7, `lotStatusId` s3, `lotOriginTypeId` s3, `limitRows` s2) | `Lot.search(query, lotStatusId, lotOriginTypeId, limitRows)` |
| Status dropdown | `Lots.LotStatusCode` list (read-only code table) | `lots/LotStatusCode_List` (new, no params) | `Lot.getStatusOptions()` → `[{label,value}]` |
| Origin dropdown | `Lots.LotOriginType` list (read-only code table) | `lots/LotOriginType_List` (new, no params) | `Lot.getOriginOptions()` → `[{label,value}]` |

(If a code-table list NQ already exists for either, reuse it rather than adding one.)

## 6. View

- MPP `BlueRidge/Views/ShopFloor/LotSearch` + route `/shop-floor/lot-search` (title "LOT Search").
- Read-only. `view.custom.results` (`[]` default), `view.custom.query`/`statusId`/`originId` filter state. A `search()` customMethod calls `Lot.search(...)` and assigns `view.custom.results`; wired to the Search button and the Query field's `dom.onBlur` (commit-on-blur, per text-field convention). Results rendered via `ia.display.table` (full ~25-key column schema) or a flex-repeater; row/Open click navigates to LOT Detail with `lotId`.
- Pre-declare every bound custom prop with a shaped default; dropdown option props seeded `[]`.
- **Auth:** mockup tags this elevated. Gate the view (or the nav entry) behind the elevated role per the FDS-04-007 model; confirm the exact security level at build.

## 7. Done when

- `/shop-floor/lot-search`: typing a LotName / Vendor LOT / Part Number fragment + Search lists matching LOTs with status/origin/created; Status + Origin dropdowns filter; clicking a row opens that LOT in LOT Detail.
- `Lot_Search` shipped + tested; SQL suite green.
- Designer smoke: search returns rows; filters narrow; Open navigates and LOT Detail loads the right LOT.

## 8. Out of scope

SerialNumber + AIM Shipper ID search (Phase 3/6 tables). Other Phase 2 views (LOT Detail, Genealogy Viewer, Paused-LOT Indicator) — separate specs. LOT Search only *navigates* to LOT Detail; it does not embed it.
