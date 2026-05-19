# Audit Pages — FailureLog + AuditLog (Config Tool Browsers)

**Date:** 2026-05-19
**Status:** Approved — ready for implementation plan
**Scope:** Wire the existing `BlueRidge/Views/Audit/FailureLog` and `AuditLog` views to live data per FDS §11 + the Config Tool Phased Plan §"Audit & Failure Log Browsers".

---

## 1. Goals

Stand up the two **read-only audit browsers** in the Configuration Tool:

- **FailureLog Browser** — every rejected mutation attempt with filters, dashboard tiles, and a per-row detail popup. The "Top Rejection Reasons" + "Top Failing Procedures" surface is explicitly called out by FDS-11-004 as a known pain point in the legacy MES that this MES fixes.
- **AuditLog Browser** — every successful configuration change (sister page, same structural pattern, no Top tiles).

Both pages already have ~30KB of UI on disk (converted from a mockup at some earlier point) but zero DB wiring. This spec covers the data layer, behavior, and integration.

---

## 2. Non-Goals

- **OperationLog browser** — shop-floor event history is out of MVP scope for the Configuration Tool (per FDS-11-001; that browser lives on the operator surface).
- **InterfaceLog browser** — admin-only screen not scoped to MVP per FDS-11-003 prose.
- **Cross-cutting "View Audit History" buttons** on entity Config Tool screens (PlantHierarchy, DefectCodes, etc.) — deferred to a polish pass once both main browsers prove out.
- **Server-side pagination** — `ia.display.table` has built-in client-side paging; we cap at TOP 1000 from the proc and let the table component page within that. If operators routinely hit the cap, revisit with server-side paging.

---

## 3. Architecture

Standard three-layer Configuration Tool pattern:

```
View bindings / event handlers
        ↓
BlueRidge.Audit.FailureLog | .ConfigLog | .LogEntityType | .LogSeverity   (NEW entity scripts)
        ↓
BlueRidge.Common.Db.execList                                              (existing helper)
        ↓
audit/* named queries                                                     (NEW NQs)
        ↓
Audit.* stored procedures                                                 (mostly already deployed)
```

No mutations. No SaveAll. No dirty-model. Detail popup mounted via `system.perspective.openPopup`; tile click → page-scoped messaging back to the parent view triggers `Apply` after mutating filter state.

**DRY note:** Two thin parallel entity-script modules (`FailureLog`, `ConfigLog`) — no shared `Audit._common` module yet. Defer extraction until a third audit page emerges (YAGNI). Existing infrastructure reused where possible:
- `Location.AppUser.list()` already exists → drives the AppUser dropdown
- `R__Audit_LogEntityType_List` proc already exists → wrap with NQ
- `R__Audit_LogSeverity_List` proc already exists → wrap with NQ
- `Common.Db.execList` already exists → no new helper needed

---

## 4. UI Layout (per existing converted view)

Both pages share this structure:

```
┌─────────────────────────────────────────────────────────────┐
│ TitleBar                                                    │
├──────────────┬──────────────────────────────────────────────┤
│ FilterSidebar│ ContentArea                                  │
│              │ ┌──────────────────────────────────────────┐ │
│ StartDate    │ │ DashboardTiles  (FailureLog only)        │ │
│ EndDate      │ │ ┌──────────────┐  ┌──────────────────┐   │ │
│ EntityType ▾ │ │ │ Top Reasons  │  │ Top Procedures   │   │ │
│ Procedure ▾  │ │ │  (Top 5)     │  │  (Top 5)         │   │ │
│ AppUser ▾    │ │ └──────────────┘  └──────────────────┘   │ │
│ Search       │ ├──────────────────────────────────────────┤ │
│              │ │ Banner: "Showing N rows" / "first 1000…" │ │
│ ┌──────────┐ │ ├──────────────────────────────────────────┤ │
│ │ Apply    │ │ │ FailureTable / AuditTable                │ │
│ │ Reset    │ │ │  (ia.display.table, built-in paging)     │ │
│ └──────────┘ │ │  Row click → DetailPopup                 │ │
└──────────────┴─┴──────────────────────────────────────────┘─┘
```

### FilterSidebar fields

| Field | FailureLog | AuditLog | Source | Default |
|---|---|---|---|---|
| StartDate | ✓ | ✓ | DatePicker | today − 7 days |
| EndDate | ✓ | ✓ | DatePicker | today |
| EntityType ▾ | ✓ | ✓ | `audit/LogEntityType_List` + `(All)` sentinel | `(All)` |
| Procedure ▾ | ✓ | — | `audit/FailureLog_DistinctProcedures` + `(All)` | `(All)` |
| Severity ▾ | — | ✓ | `audit/LogSeverity_List` + `(All)` | `(All)` |
| AppUser ▾ | ✓ | ✓ | existing `location/AppUser_List` + `(All)` | `(All)` |
| Search | ✓ | ✓ | text input (substring match) — `FailureReason` on FailureLog, `Description` on AuditLog | empty |

**Apply / Reset buttons** stacked at the bottom of the sidebar. Apply triggers re-query of table + tiles; Reset restores all fields to defaults AND applies (single click = back to safe state with data refreshed).

**No auto-apply.** Filter changes are local-only state; no DB churn until Apply. Defense against the "wide-range partial-state query" problem (operator picks a 6-month StartDate and the page auto-queries before EndDate is configured).

---

## 5. State Model

`view.custom` shape (FailureLog; AuditLog mirrors):

```
filter:
  startDate:        Date              (defaults today − 7d on view startup)
  endDate:          Date              (defaults today)
  entityTypeCode:   str | null        (null = "(All)" sentinel)
  procedureName:    str | null        (FailureLog only)
  logSeverityCode:  str | null        (AuditLog only)
  appUserId:        long | null
  searchText:       str               (substring match; null/empty = no filter)
rows:               list[dict]         (table data, capped TOP 1000 by proc)
totalCount:         int                (full count from COUNT(*) OVER();
                                       drives "Showing N of M" banner)
topReasons:         list[dict]         (top 5, FailureLog only)
topProcs:           list[dict]         (top 5, FailureLog only)
```

### Lifecycle

**onStartup** (view-level startup script):
1. Set `filter.startDate = system.date.addDays(now, -7)`
2. Set `filter.endDate = now`
3. Call `applySearch()` (the same handler the Apply button uses)

**Apply button** (sidebar footer, one-liner):
```python
result = BlueRidge.Audit.FailureLog.search(self.view.custom.filter)
self.view.custom.rows       = result["rows"]
self.view.custom.totalCount = result["totalCount"]
self.view.custom.topReasons = result["topReasons"]
self.view.custom.topProcs   = result["topProcs"]
```

`FailureLog.search` makes 3 NQ calls (List + GetTopReasons + GetTopProcs) and bundles the result so the view handler stays one line. ConfigLog's `search` makes 1 NQ call (List only — no Top tiles).

**Reset button**:
```python
self.view.custom.filter = {
    "startDate":       system.date.addDays(now, -7),
    "endDate":         now,
    "entityTypeCode":  None,
    "procedureName":   None,
    "appUserId":       None,
    "searchText":      "",
}
# then call applySearch
```

**Tile click — apply-as-filter**:
- Top Reasons row click → sets `filter.searchText` to that row's `FailureReason` text, fires Apply
- Top Procs row click → sets `filter.procedureName` to that row's `ProcedureName`, fires Apply
- Each tile row sub-view sends a page-scoped message (`applyFilterFromTile` with payload `{field, value}`) — parent view's handler mutates filter + applies

**Row click on FailureTable** → opens `BlueRidge/Components/Popups/FailureDetail` with the row data as params. Similar for AuditLog.

**Banner above table** — bound to expression:
```
if({view.custom.totalCount} < 1000,
   "Showing " + {view.custom.totalCount} + " rows",
   "Showing first 1000 of " + {view.custom.totalCount} + " — narrow your filter")
```

---

## 6. Detail Popups (two specific)

### `BlueRidge/Components/Popups/FailureDetail`

Params: row dict from FailureTable.

Layout:
```
┌────────────────────────────────────────────────────┐
│ Rejection Detail                              [X]  │
├────────────────────────────────────────────────────┤
│ Attempted at:   2026-05-19 14:23:07               │
│ User:           Jen Lewis (JL)                    │
│ Procedure:      Location.Location_SaveAll         │
│ Entity:         Location · 47                     │
│ Event:          Updated                           │
│ ─────────────────────────────────────────────────  │
│ Failure Reason:                                    │
│   A location with this Code already exists.       │
│ ─────────────────────────────────────────────────  │
│ Attempted Parameters:                              │
│ ┌────────────────────────────────────────────────┐│
│ │  {                                             ││
│ │    "Id": 47,                                   ││
│ │    "ParentLocationId": 3,                      ││
│ │    "Code": "DC-LINE-01",                       ││
│ │    "Name": "Die Cast Line 1 Renamed",          ││
│ │    ...                                          ││
│ │  }                                              ││
│ └────────────────────────────────────────────────┘│
│                                       [ Close ]    │
└────────────────────────────────────────────────────┘
```

- **AttemptedParameters JSON pretty-printed** at popup-open time via `system.util.jsonDecode` + `system.util.jsonEncode(..., True)` (or a Jython-side pretty-printer).
- Mono-spaced label inside a scrollable container.
- Close button + X-icon close the popup (no `Save` — this is read-only).

### `BlueRidge/Components/Popups/ConfigChangeDetail`

Same header shape, but body is:
- Description (large readable text)
- Old vs New JSON blocks stacked (or side-by-side if width permits)

Pretty-print both JSON blocks the same way as FailureDetail.

---

## 7. SQL Changes

### Proc updates

**`Audit.FailureLog_List`** — add filter param + cap + window count:

```sql
ALTER PROCEDURE Audit.FailureLog_List
    @StartDate           DATETIME2(3),
    @EndDate             DATETIME2(3),
    @LogEntityTypeCode   NVARCHAR(50)  = NULL,
    @AppUserId           BIGINT        = NULL,
    @ProcedureName       NVARCHAR(200) = NULL,
    @FailureReasonLike   NVARCHAR(500) = NULL   -- NEW
AS BEGIN
    SET NOCOUNT ON;
    SELECT TOP 1000
        fl.Id, fl.AttemptedAt, fl.AppUserId, au.DisplayName AS UserDisplayName,
        let.Code AS LogEntityTypeCode, let.Name AS LogEntityTypeName,
        fl.EntityId, fl.LogEventTypeId, lev.Code AS LogEventTypeCode,
        fl.FailureReason, fl.ProcedureName, fl.AttemptedParameters,
        COUNT(*) OVER() AS TotalCount
    FROM Audit.FailureLog fl
    INNER JOIN Audit.LogEntityType let ON let.Id = fl.LogEntityTypeId
    LEFT JOIN  Audit.LogEventType  lev ON lev.Id = fl.LogEventTypeId
    LEFT JOIN  Location.AppUser    au  ON au.Id  = fl.AppUserId
    WHERE fl.AttemptedAt >= @StartDate AND fl.AttemptedAt < DATEADD(day, 1, @EndDate)
      AND (@LogEntityTypeCode IS NULL OR let.Code = @LogEntityTypeCode)
      AND (@AppUserId         IS NULL OR fl.AppUserId = @AppUserId)
      AND (@ProcedureName     IS NULL OR fl.ProcedureName = @ProcedureName)
      AND (@FailureReasonLike IS NULL OR fl.FailureReason LIKE N'%' + @FailureReasonLike + N'%')
    ORDER BY fl.AttemptedAt DESC;
END;
```

**`Audit.ConfigLog_List`** — same shape with `@DescriptionLike` + `@LogSeverityCode` instead of `@ProcedureName` + `@FailureReasonLike`.

**New: `Audit.FailureLog_DistinctProcedures`**:

```sql
CREATE OR ALTER PROCEDURE Audit.FailureLog_DistinctProcedures
AS BEGIN
    SET NOCOUNT ON;
    SELECT DISTINCT ProcedureName
    FROM Audit.FailureLog
    WHERE ProcedureName IS NOT NULL
    ORDER BY ProcedureName;
END;
```

No date param — operator's Procedure dropdown sees every proc ever logged. Cheap query (DISTINCT scan; result set is small — likely <100 rows project-lifetime).

Other procs (`_GetByEntity`, `_GetTopReasons`, `_GetTopProcs`) — no changes.

### Tests

Extend existing test files for `FailureLog_List` and `ConfigLog_List`:
- New params behave correctly (LIKE substring match, severity filter)
- TOP 1000 cap returns exactly 1000 rows when 1001+ exist
- TotalCount column matches the unbounded COUNT (verify via SELECT COUNT(*) … same WHERE)
- New tests for `FailureLog_DistinctProcedures` (returns distinct values, sorted, excludes NULLs)

---

## 8. Named Queries — `audit/*` (NEW)

```
audit/
├── ConfigLog_List/                    {query.sql, resource.json}
├── ConfigLog_GetByEntity/             {query.sql, resource.json}
├── FailureLog_List/                   {query.sql, resource.json}
├── FailureLog_GetByEntity/            {query.sql, resource.json}
├── FailureLog_GetTopReasons/          {query.sql, resource.json}
├── FailureLog_GetTopProcs/            {query.sql, resource.json}
├── FailureLog_DistinctProcedures/     {query.sql, resource.json}
├── LogEntityType_List/                {query.sql, resource.json}
└── LogSeverity_List/                  {query.sql, resource.json}
```

All `version: 2` schema, Designer-canonical sqlType codes per `feedback_ignition_nq_resource_schema.md`. Standard thin `EXEC <proc>` wrappers per `ignition-context-pack/04_named_queries.md`.

---

## 9. Entity Scripts — `BlueRidge.Audit.*` (NEW)

```
BlueRidge/Audit/
├── FailureLog/code.py
│       def search(filter)                  → {rows, totalCount, topReasons, topProcs}
│       def getByEntity(typeCode, entityId) → list[dict]
│       def distinctProcedures()            → list[dict]
│
├── ConfigLog/code.py
│       def search(filter)                  → {rows, totalCount}
│       def getByEntity(typeCode, entityId) → list[dict]
│
├── LogEntityType/code.py
│       def list()                          → list[dict]   (EntityType dropdown options)
│
└── LogSeverity/code.py
        def list()                          → list[dict]   (Severity dropdown options)
```

Standard module shape per `ignition-context-pack/03_script_python.md`. All `system.db.*` calls routed through `Common.Db.execList`; logging via `Common.Util.log`; no per-module logger.

`FailureLog.search` and `ConfigLog.search` accept the filter dict, deep-unwrap via `Common.Util.extractQualifiedValues` at entry (defense against any future caller handing in wrapped values, per `feedback_ignition_tree_qv_unwrap.md`), then issue 3 NQ calls (FailureLog) or 1 (ConfigLog).

---

## 10. View Wiring

**FailureLog view** (existing `BlueRidge/Views/Audit/FailureLog/view.json` — wire only, no structural rewrite):

- Add `view.custom.filter` + sub-fields, `view.custom.rows`, `view.custom.totalCount`, `view.custom.topReasons`, `view.custom.topProcs` as defaults
- Add **view onStartup** script that seeds dates and calls Apply
- Bind every FilterSidebar input bidirectionally to the matching `view.custom.filter.X` field
- Bind StartDateInput.props.value, EndDateInput.props.value bidirectionally to `filter.startDate` / `filter.endDate`
- EntityTypeDropdown.props.options ← `runScript("BlueRidge.Audit.LogEntityType.list", 0)` transformed to `[{label,value}]` shape
- ProcedureDropdown.props.options ← `runScript("BlueRidge.Audit.FailureLog.distinctProcedures", 0)` similarly
- AppUserDropdown.props.options ← `runScript("BlueRidge.Location.AppUser.list", 0)` similarly
- Apply button onActionPerformed — the one-liner script above
- Reset button onActionPerformed — restore defaults + Apply
- FailureTable.props.data ← bound to `view.custom.rows` (will need to be reshaped if `ia.display.table` requires a Dataset rather than list[dict])
- FailureTable row click event → openPopup `FailureDetail`
- Top Reasons / Top Procs tile rows bound to `view.custom.topReasons` / `topProcs`; per-row sub-views send page-scoped `applyFilterFromTile` messages
- Page-scoped `applyFilterFromTile` message handler on root: mutates filter, calls Apply

**AuditLog view** — same pattern, swap Procedure → Severity, FailureReason → Description, drop the dashboard tiles section entirely.

**`ia.display.table` notes** per `ignition-context-pack/06_component_quirks.md`:
- Table component is virtualized div-based DOM (not native `<table>`)
- Body cells use `.ia_table__cell` (no `__body__cell`); head cells use `.ia_table__head__header__cell`
- `props.data` accepts Dataset or list[dict] (preferred shape verified during build)

---

## 11. Performance Considerations

- **Worst-case row count.** `Audit.FailureLog` and `Audit.ConfigLog` will grow without bound over the 20-year retention (FDS-11-009). At MVP launch we have maybe thousands of rows; year-3 we could have millions. The TOP 1000 cap protects the UI; the date-range filter is the operator's tool to narrow.
- **Indexes required.** Both log tables already have indexes on `AttemptedAt` / `ChangedAt` from migration 0001 (verify during build). If missing, add as part of this work — the date-range scan is the hottest path.
- **Procedure dropdown** is "all-time distinct" — cheap because the result set is small (procs are a closed set of code paths, ~50-100 entries for the project's lifetime).
- **Server-side filtering > client-side.** All filter params land as proc args; the proc returns at most 1000 rows. No "fetch everything and filter in Jython" patterns.

---

## 12. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Operator picks a wide date range and clicks Apply on it anyway | Server-side TOP 1000 cap; banner clearly says "first 1000 of N — narrow your filter" |
| Tile click stuck-state (rapid clicks while query in flight) | Apply is idempotent; multiple in-flight queries resolve in arrival order. Cheapest fix if observed: disable Apply button while query in flight (defer to v2 if not a problem). |
| `ia.display.table` data prop shape mismatch (Dataset vs list[dict]) | Test during build; if Dataset required, convert in `search()` via `system.dataset.toDataSet(headers, rows)` |
| Date validation (end > start) | Front-end visual cue (disable Apply if invalid). Proc still handles backwards ranges (returns empty set). |
| AttemptedParameters JSON malformed | Wrap pretty-print in try/except; fall back to raw string display on parse failure. |

---

## 13. Testing Plan

**Automated (SQL):**
- Updated tests for `FailureLog_List` / `ConfigLog_List` covering new params + TOP cap + TotalCount column
- New tests for `FailureLog_DistinctProcedures`

**Manual smoke test in Designer:**
1. View loads → date defaults seeded → table populates last-7d data
2. Change date / dropdown / search → click Apply → table + tiles refresh
3. Reset → defaults restored, table updates
4. Top Reasons tile row click → searchText set, Apply fires
5. Top Procs tile row click → procedureName set, Apply fires
6. FailureTable row click → detail popup opens with pretty-printed AttemptedParameters JSON
7. Banner shows correct text below cap and at cap
8. AuditLog mirrors all of (1)–(3), (6), (7) with Description in place of FailureReason and Severity in place of Procedure

---

## 14. Files Touched

**SQL (3 files):**
- `sql/migrations/repeatable/R__Audit_FailureLog_List.sql` (edit — add `@FailureReasonLike`, `TOP 1000`, `COUNT(*) OVER()`)
- `sql/migrations/repeatable/R__Audit_ConfigLog_List.sql` (edit — add `@DescriptionLike`, `@LogSeverityCode`, `TOP 1000`, `COUNT(*) OVER()`)
- `sql/migrations/repeatable/R__Audit_FailureLog_DistinctProcedures.sql` (new)

**SQL tests:**
- Extend `sql/tests/02_audit_readers/070_FailureLog_List.sql` and related ConfigLog test file
- New test for DistinctProcedures

**Named queries (9 new):**
- `ignition/projects/MPP_Config/ignition/named-query/audit/{ConfigLog_List, ConfigLog_GetByEntity, FailureLog_List, FailureLog_GetByEntity, FailureLog_GetTopReasons, FailureLog_GetTopProcs, FailureLog_DistinctProcedures, LogEntityType_List, LogSeverity_List}/`

**Entity scripts (4 new modules):**
- `ignition/projects/MPP_Config/ignition/script-python/BlueRidge/Audit/{FailureLog, ConfigLog, LogEntityType, LogSeverity}/code.py`

**Views (3 new + 2 edits):**
- New: `BlueRidge/Components/Popups/FailureDetail/`
- New: `BlueRidge/Components/Popups/ConfigChangeDetail/`
- New: `BlueRidge/Components/Audit/TopReasonRow/` (sub-view for tile rows; pageScope reply handler)
- New: `BlueRidge/Components/Audit/TopProcRow/` (same pattern)
- Edit: `BlueRidge/Views/Audit/FailureLog/view.json` (wire bindings + handlers — no structural rewrite)
- Edit: `BlueRidge/Views/Audit/AuditLog/view.json` (same)

Total: ~22 files changed/added.

---

## 15. Estimate

~2.5–3 hours including SQL test extensions and Designer smoke test.

Lowest-risk Ignition work in the project to date — no Tree gotchas, no QV unwrap challenges, no bidirectional bindings on complex props, no event coordination. Just NQ → entity script → `ia.display.table`.
