# Shift Schedules Config Screen — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the already-built `Oee.ShiftSchedule_*` SQL procs to a Config Tool CRUD screen so the dead `/shifts` nav link becomes a working Shift Schedules editor.

**Architecture:** Pure Named-Query + Perspective-view + page-route layer over existing procs. Five Core named queries wrap the procs; a Core Python module adds thin wrappers plus pure bitmask/time formatting helpers; three MPP_Config Perspective views (list + row + editor popup) mirror the Downtime Codes screen; one page-route entry activates the existing Sidebar nav item.

**Tech Stack:** Ignition 8.3 file-based Perspective, Jython 2.7 gateway scripts, SQL Server 2022 (procs already deployed), `scan.ps1` gateway sync.

## Global Constraints

- **No SQL changes.** All 5 `Oee.ShiftSchedule_*` procs exist and are deployed. Do not modify them.
- **All named queries live in Core** (`ignition/projects/Core/ignition/named-query/`). MPP/MPP_Config have zero local NQs. (`project_mpp_nq_core_topology`)
- **Status-row mutation procs need `attributes.type: "Query"`** in resource.json, else Ignition throws "result set generated for update". (`feedback_ignition_nq_type_for_status_row_procs`)
- **New views are safe to write as files + scan;** never hand-edit existing views on disk. All three views here are NEW. (`feedback_ignition_view_edit_boundary`)
- **After any new Ignition resource, run `.\scan.ps1`.** (`feedback_ignition_gateway_scan`)
- **Ignition `sqlType` ordinals** (DataType enum): Int4 = `2`, Int8/BIGINT = `3`, Boolean = `6`, String = `7`, DateTime = `8`.
- **Every bound `view.custom.*` property needs a fully-shaped default;** editor `editDraft` must pre-seed every key the form binds. (`feedback_ignition_predeclare_bound_custom_props`, `feedback_ignition_bidi_nested_path_init`)
- **`load()`/reseed writes `state`/draft in ONE property write**, never two sequential writes. (Item Master atomic-state rule)
- **`bidirectional: true` goes INSIDE the binding `config`** block. (`feedback_ignition_bidirectional_inside_config`)
- **`system.perspective.openPopup` from a DOM event needs `scope: "G"`.** (`feedback_ignition_popup_open_scope`)
- **Event-script bodies start with a tab** (`\t`) — Designer wraps in `def runAction(self, event):`. (`feedback_ignition_event_script_indent`)
- **Toasts:** `BlueRidge.Common.Notify.toast(title, msg, level, ttl?)`; levels `info|success|warning|error`. (`project_mpp_toast_system`)
- **Commit to `jacques/working`**, explicit path staging only — never `git add -A`/`-u`. (`feedback_jacques_working_branch`, `feedback_git_explicit_staging`)
- **ASCII-only** in seed/label strings that reach SQL; view label copy may use the en-dash char literally in JSON (UTF-8 view.json is fine — the ASCII rule is about `sqlcmd` codepage, not view files).
- **Times passed to procs as `HH:MM` strings, dates as `YYYY-MM-DD` strings** (sqlType String=7); JDBC coerces to `TIME(0)`/`DATE`. This sidesteps the Perspective date-picker timezone trap.

## Reference files to mirror (read before starting)

- NQ query + resource: `ignition/projects/Core/ignition/named-query/oee/DowntimeReasonCode_Create/{query.sql,resource.json}`, `.../DowntimeReasonCode_List/query.sql`
- Python module: `ignition/projects/Core/ignition/script-python/BlueRidge/Oee/DowntimeReasonCode/code.py`
- List view: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Oee/DowntimeCodes/view.json`
- Row view: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/DowntimeCodeRow/view.json`
- Editor popup: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/DowntimeCodeEditor/view.json`
- Page route: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/page-config/config.json`

## Proc signatures (already deployed — the contract this screen consumes)

```
Oee.ShiftSchedule_List   @ActiveOnly BIT = 1
  -> Id, Name, Description, StartTime, EndTime, DaysOfWeekBitmask, EffectiveFrom,
     CreatedAt, CreatedByUserId, UpdatedAt, UpdatedByUserId, DeprecatedAt
Oee.ShiftSchedule_Get    @Id BIGINT                     -> same columns (0 or 1 row)
Oee.ShiftSchedule_Create @Name, @Description=NULL, @StartTime TIME, @EndTime TIME,
                         @DaysOfWeekBitmask INT, @EffectiveFrom DATE, @AppUserId
                         -> Status, Message, NewId
Oee.ShiftSchedule_Update @Id, @Name, @Description=NULL, @StartTime, @EndTime,
                         @DaysOfWeekBitmask, @EffectiveFrom, @AppUserId
                         -> Status, Message
Oee.ShiftSchedule_Deprecate @Id, @AppUserId            -> Status, Message
```

Bitmask: Mon=1, Tue=2, Wed=4, Thu=8, Fri=16, Sat=32, Sun=64; valid 1–127. Overnight shift = `EndTime < StartTime` (proc accepts it).

---

## Task 1: Named Queries (5, in Core)

Wrap each proc as a Core named query. Each folder gets `query.sql` + `resource.json`.

**Files:**
- Create: `ignition/projects/Core/ignition/named-query/oee/ShiftSchedule_List/{query.sql,resource.json}`
- Create: `ignition/projects/Core/ignition/named-query/oee/ShiftSchedule_Get/{query.sql,resource.json}`
- Create: `ignition/projects/Core/ignition/named-query/oee/ShiftSchedule_Create/{query.sql,resource.json}`
- Create: `ignition/projects/Core/ignition/named-query/oee/ShiftSchedule_Update/{query.sql,resource.json}`
- Create: `ignition/projects/Core/ignition/named-query/oee/ShiftSchedule_Deprecate/{query.sql,resource.json}`

**Interfaces:**
- Produces (consumed by Task 2): NQ paths `oee/ShiftSchedule_List`, `oee/ShiftSchedule_Get`, `oee/ShiftSchedule_Create`, `oee/ShiftSchedule_Update`, `oee/ShiftSchedule_Deprecate` with the parameter identifiers named below.

- [ ] **Step 1: Write `ShiftSchedule_List/query.sql`**

```sql
EXEC Oee.ShiftSchedule_List
    @ActiveOnly = :activeOnly
```

- [ ] **Step 2: Write `ShiftSchedule_List/resource.json`**

Mirror `DowntimeReasonCode_Create/resource.json` exactly, replacing only the `parameters` array. `type: "Query"`, `database: "MPP"`, scope `DG`.

```json
{
  "scope": "DG",
  "version": 2,
  "restricted": false,
  "overridable": true,
  "files": [ "query.sql" ],
  "attributes": {
    "useMaxReturnSize": false,
    "autoBatchEnabled": false,
    "fallbackValue": "",
    "maxReturnSize": 100,
    "cacheUnit": "SEC",
    "type": "Query",
    "enabled": true,
    "cacheAmount": 1,
    "cacheEnabled": false,
    "database": "MPP",
    "fallbackEnabled": false,
    "lastModificationSignature": "",
    "permissions": [ { "zone": "", "role": "" } ],
    "lastModification": { "actor": "claude", "timestamp": "2026-07-21T00:00:00Z" },
    "parameters": [
      { "type": "Parameter", "identifier": "activeOnly", "sqlType": 6 }
    ]
  }
}
```

- [ ] **Step 3: Write `ShiftSchedule_Get/query.sql` + resource.json**

query.sql:
```sql
EXEC Oee.ShiftSchedule_Get
    @Id = :id
```
resource.json: same skeleton as Step 2, parameters:
```json
"parameters": [ { "type": "Parameter", "identifier": "id", "sqlType": 3 } ]
```

- [ ] **Step 4: Write `ShiftSchedule_Create/query.sql` + resource.json**

query.sql:
```sql
EXEC Oee.ShiftSchedule_Create
    @Name              = :name,
    @Description       = :description,
    @StartTime         = :startTime,
    @EndTime           = :endTime,
    @DaysOfWeekBitmask = :daysOfWeekBitmask,
    @EffectiveFrom     = :effectiveFrom,
    @AppUserId         = :appUserId
```
resource.json parameters (Create is a status-row proc → `type: "Query"` already in skeleton):
```json
"parameters": [
  { "type": "Parameter", "identifier": "name",              "sqlType": 7 },
  { "type": "Parameter", "identifier": "description",       "sqlType": 7 },
  { "type": "Parameter", "identifier": "startTime",         "sqlType": 7 },
  { "type": "Parameter", "identifier": "endTime",           "sqlType": 7 },
  { "type": "Parameter", "identifier": "daysOfWeekBitmask", "sqlType": 2 },
  { "type": "Parameter", "identifier": "effectiveFrom",     "sqlType": 7 },
  { "type": "Parameter", "identifier": "appUserId",         "sqlType": 3 }
]
```

- [ ] **Step 5: Write `ShiftSchedule_Update/query.sql` + resource.json**

query.sql:
```sql
EXEC Oee.ShiftSchedule_Update
    @Id                = :id,
    @Name              = :name,
    @Description       = :description,
    @StartTime         = :startTime,
    @EndTime           = :endTime,
    @DaysOfWeekBitmask = :daysOfWeekBitmask,
    @EffectiveFrom     = :effectiveFrom,
    @AppUserId         = :appUserId
```
resource.json parameters:
```json
"parameters": [
  { "type": "Parameter", "identifier": "id",                "sqlType": 3 },
  { "type": "Parameter", "identifier": "name",              "sqlType": 7 },
  { "type": "Parameter", "identifier": "description",       "sqlType": 7 },
  { "type": "Parameter", "identifier": "startTime",         "sqlType": 7 },
  { "type": "Parameter", "identifier": "endTime",           "sqlType": 7 },
  { "type": "Parameter", "identifier": "daysOfWeekBitmask", "sqlType": 2 },
  { "type": "Parameter", "identifier": "effectiveFrom",     "sqlType": 7 },
  { "type": "Parameter", "identifier": "appUserId",         "sqlType": 3 }
]
```

- [ ] **Step 6: Write `ShiftSchedule_Deprecate/query.sql` + resource.json**

query.sql:
```sql
EXEC Oee.ShiftSchedule_Deprecate
    @Id        = :id,
    @AppUserId = :appUserId
```
resource.json parameters:
```json
"parameters": [
  { "type": "Parameter", "identifier": "id",        "sqlType": 3 },
  { "type": "Parameter", "identifier": "appUserId", "sqlType": 3 }
]
```

- [ ] **Step 7: Scan and verify the NQs load**

Run: `.\scan.ps1`
Then check the gateway log has no "Named query not found"/parse errors for the 5 new queries:
Run: `Select-String -Path C:\...\wrapper.log -Pattern "ShiftSchedule" | Select-Object -Last 20` (use the project's actual wrapper.log path from `pull.ps1`).
Expected: scan reports the 5 new resources added; no parse/deploy errors.

- [ ] **Step 8: Commit**

```bash
git add ignition/projects/Core/ignition/named-query/oee/ShiftSchedule_List \
        ignition/projects/Core/ignition/named-query/oee/ShiftSchedule_Get \
        ignition/projects/Core/ignition/named-query/oee/ShiftSchedule_Create \
        ignition/projects/Core/ignition/named-query/oee/ShiftSchedule_Update \
        ignition/projects/Core/ignition/named-query/oee/ShiftSchedule_Deprecate
git commit -m "feat(oee): named queries for ShiftSchedule CRUD"
```

---

## Task 2: Python wrapper module + bitmask/time helpers

Thin proc wrappers plus the pure formatting logic (bitmask <-> days, time/date formatting). This is the only genuinely new logic, so it gets a real red/green test on the pure helpers.

**Files:**
- Create: `ignition/projects/Core/ignition/script-python/BlueRidge/Oee/ShiftSchedule/code.py`
- Create: `ignition/projects/Core/ignition/script-python/BlueRidge/Oee/ShiftSchedule/resource.json`
- Test (throwaway, not committed): `<scratchpad>/test_bitmask.py`

**Interfaces:**
- Consumes: NQ paths from Task 1; `BlueRidge.Common.Db.{execList,execOne,execMutation}`, `BlueRidge.Common.Util.{extractQualifiedValues,_currentAppUserId,log}`, `BlueRidge.Common.Notify.toast`.
- Produces (consumed by Tasks 3–5):
  - `search(filters)` -> list[dict] with keys `Id, Name, Description, StartTimeText, EndTimeText, DaysLabel, DaysMask, EffectiveFromText, DeprecatedAt`
  - `getOne(id)` -> dict|None (raw proc columns)
  - `add(meta)` / `update(meta)` / `deprecate(id)` -> `{Status, Message, NewId?}`
  - `emptyMeta()` -> blank editor dict
  - `bitmaskToDays(mask)` -> list[int] of day indices 0..6 (Mon..Sun) that are set
  - `daysToBitmask(days)` -> int
  - `bitmaskToLabel(mask)` -> str (collapses contiguous runs, e.g. "Mon-Fri")

- [ ] **Step 1: Write the failing test for the pure helpers**

Create `<scratchpad>/test_bitmask.py`. The three helpers are copied inline into the test (they use no Ignition APIs), so this runs under plain Python 3:

```python
# Paste the three pure helpers here (identical to what goes in code.py), then:
_DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

def bitmaskToDays(mask):
    mask = int(mask or 0)
    return [i for i in range(7) if mask & (1 << i)]

def daysToBitmask(days):
    m = 0
    for d in (days or []):
        m |= (1 << int(d))
    return m

def bitmaskToLabel(mask):
    idx = bitmaskToDays(mask)
    if not idx:
        return "(none)"
    runs = []
    start = prev = idx[0]
    for d in idx[1:]:
        if d == prev + 1:
            prev = d
            continue
        runs.append((start, prev)); start = prev = d
    runs.append((start, prev))
    parts = []
    for a, b in runs:
        if a == b:
            parts.append(_DAYS[a])
        elif b == a + 1:
            parts.append(_DAYS[a]); parts.append(_DAYS[b])
        else:
            parts.append("%s-%s" % (_DAYS[a], _DAYS[b]))
    return " ".join(parts)

def test():
    assert daysToBitmask([0,1,2,3,4]) == 31
    assert daysToBitmask([5,6]) == 96
    assert daysToBitmask([0,2,4]) == 21
    assert bitmaskToDays(31) == [0,1,2,3,4]
    assert bitmaskToDays(96) == [5,6]
    assert bitmaskToLabel(31) == "Mon-Fri"
    assert bitmaskToLabel(96) == "Sat Sun"          # 2-day run lists both
    assert bitmaskToLabel(21) == "Mon Wed Fri"
    assert bitmaskToLabel(0) == "(none)"
    assert bitmaskToLabel(127) == "Mon-Sun"
    # round-trip
    for m in range(1, 128):
        assert daysToBitmask(bitmaskToDays(m)) == m
    print("OK")

test()
```

- [ ] **Step 2: Run the test, expect FAIL first (introduce a deliberate wrong expected value, run, confirm AssertionError, then correct it)**

Run: `python <scratchpad>/test_bitmask.py`
Expected initially: `AssertionError`. After correcting the intentionally-wrong assert: `OK`.
(This confirms the harness actually exercises the logic rather than trivially passing.)

- [ ] **Step 3: Write `BlueRidge/Oee/ShiftSchedule/code.py`**

```python
"""BlueRidge.Oee.ShiftSchedule - CRUD wrappers + bitmask/time formatting for the
   Config Tool Shift Schedules screen. Wrappers only; the only real logic is the
   pure bitmask <-> day-list conversion (single source of truth for both the row
   label and the editor chips). All public functions unwrap QualifiedValue
   wrappers at entry via _u()."""

import BlueRidge.Common.Db
import BlueRidge.Common.Notify
import BlueRidge.Common.Util

_DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


# ---- pure bitmask helpers (Mon=index0/bit0 .. Sun=index6/bit6) ----
def bitmaskToDays(mask):
    mask = int(mask or 0)
    return [i for i in range(7) if mask & (1 << i)]


def daysToBitmask(days):
    m = 0
    for d in (days or []):
        m |= (1 << int(d))
    return m


def bitmaskToLabel(mask):
    idx = bitmaskToDays(mask)
    if not idx:
        return "(none)"
    runs = []
    start = prev = idx[0]
    for d in idx[1:]:
        if d == prev + 1:
            prev = d
            continue
        runs.append((start, prev)); start = prev = d
    runs.append((start, prev))
    parts = []
    for a, b in runs:
        if a == b:
            parts.append(_DAYS[a])
        elif b == a + 1:
            parts.append(_DAYS[a]); parts.append(_DAYS[b])
        else:
            parts.append("%s-%s" % (_DAYS[a], _DAYS[b]))
    return " ".join(parts)


# ---- time/date formatting (proc returns java.sql.Time/Date; normalize to text) ----
def _fmtTime(v):
    """java.sql.Time / string / None -> 'HH:MM' (or '')."""
    if v is None:
        return ""
    s = unicode(v)                      # '06:00:00' or '06:00'
    return s[:5]


def _fmtDate(v):
    """java.sql.Date / string / None -> 'YYYY-MM-DD' (or '')."""
    if v is None:
        return ""
    return unicode(v)[:10]


# ---- CRUD ----
def search(filters=None):
    """List schedules shaped for the flex-repeater. filters: {searchText, includeDeprecated}."""
    BlueRidge.Common.Util.log("filters=%s" % filters)
    f = _u(filters) or {}
    active_only = 0 if bool(f.get("includeDeprecated", False)) else 1
    try:
        rows = BlueRidge.Common.Db.execList("oee/ShiftSchedule_List", {"activeOnly": active_only})
    except Exception as e:
        BlueRidge.Common.Util.log("list failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Could not load shift schedules", str(e), "error")
        return []

    needle = (f.get("searchText") or "").strip().lower()
    out = []
    for r in (rows or []):
        name = r.get("Name") or ""
        desc = r.get("Description") or ""
        if needle and needle not in name.lower() and needle not in desc.lower():
            continue
        mask = int(r.get("DaysOfWeekBitmask") or 0)
        out.append({
            "Id":                r.get("Id"),
            "Name":              name,
            "Description":       desc,
            "StartTimeText":     _fmtTime(r.get("StartTime")),
            "EndTimeText":       _fmtTime(r.get("EndTime")),
            "DaysMask":          mask,
            "DaysLabel":         bitmaskToLabel(mask),
            "EffectiveFromText": _fmtDate(r.get("EffectiveFrom")),
            "DeprecatedAt":      r.get("DeprecatedAt"),
        })
    return out


def getOne(id):
    """Raw single-row lookup by Id. Returns dict or None."""
    BlueRidge.Common.Util.log("id=%s" % id)
    if id is None:
        return None
    try:
        return BlueRidge.Common.Db.execOne("oee/ShiftSchedule_Get", {"id": _u(id)})
    except Exception as e:
        BlueRidge.Common.Util.log("get failed: %s" % str(e))
        return None


def add(meta):
    """Create. meta = {name, description, daysOfWeekBitmask, startTime, endTime, effectiveFrom}.
       times as 'HH:MM', date as 'YYYY-MM-DD'. Returns {Status, Message, NewId}."""
    BlueRidge.Common.Util.log("meta=%s" % meta)
    m = _u(meta) or {}
    params = {
        "name":              m.get("name"),
        "description":       m.get("description"),
        "startTime":         m.get("startTime"),
        "endTime":           m.get("endTime"),
        "daysOfWeekBitmask": int(m.get("daysOfWeekBitmask") or 0),
        "effectiveFrom":     m.get("effectiveFrom"),
        "appUserId":         BlueRidge.Common.Util._currentAppUserId(),
    }
    return BlueRidge.Common.Db.execMutation("oee/ShiftSchedule_Create", params)


def update(meta):
    """Update. meta adds {id}. Returns {Status, Message}."""
    BlueRidge.Common.Util.log("meta=%s" % meta)
    m = _u(meta) or {}
    params = {
        "id":                m.get("id"),
        "name":              m.get("name"),
        "description":       m.get("description"),
        "startTime":         m.get("startTime"),
        "endTime":           m.get("endTime"),
        "daysOfWeekBitmask": int(m.get("daysOfWeekBitmask") or 0),
        "effectiveFrom":     m.get("effectiveFrom"),
        "appUserId":         BlueRidge.Common.Util._currentAppUserId(),
    }
    return BlueRidge.Common.Db.execMutation("oee/ShiftSchedule_Update", params)


def deprecate(id):
    """Soft-delete by Id. Returns {Status, Message}."""
    BlueRidge.Common.Util.log("id=%s" % id)
    params = {
        "id":        _u(id),
        "appUserId": BlueRidge.Common.Util._currentAppUserId(),
    }
    return BlueRidge.Common.Db.execMutation("oee/ShiftSchedule_Deprecate", params)


def emptyMeta():
    """Blank editor dict (create mode). Every key the editor form binds is present."""
    return {
        "id":                None,
        "name":              "",
        "description":       "",
        "days":              [],       # list of day indices 0..6 (editor chips)
        "startTime":         "",       # 'HH:MM'
        "endTime":           "",       # 'HH:MM'
        "effectiveFrom":     "",       # 'YYYY-MM-DD'
    }


def loadMeta(id):
    """Editor edit-mode dict: getOne(id) mapped to the emptyMeta() shape (with days list)."""
    row = getOne(id)
    if not row:
        return emptyMeta()
    mask = int(row.get("DaysOfWeekBitmask") or 0)
    return {
        "id":            row.get("Id"),
        "name":          row.get("Name") or "",
        "description":   row.get("Description") or "",
        "days":          bitmaskToDays(mask),
        "startTime":     _fmtTime(row.get("StartTime")),
        "endTime":       _fmtTime(row.get("EndTime")),
        "effectiveFrom": _fmtDate(row.get("EffectiveFrom")),
    }
```

- [ ] **Step 4: Confirm the helper bodies in `code.py` are byte-identical to the tested versions**

Diff the three helper functions in `code.py` against the copies in `<scratchpad>/test_bitmask.py`. They must match exactly (the test validated these exact bodies). Re-run `python <scratchpad>/test_bitmask.py` -> `OK`.

- [ ] **Step 5: Write `BlueRidge/Oee/ShiftSchedule/resource.json`**

Copy `BlueRidge/Oee/DowntimeReasonCode/resource.json` verbatim (same scope/structure — a script-python resource pointing at `code.py`).

- [ ] **Step 6: Scan**

Run: `.\scan.ps1`
Expected: `BlueRidge/Oee/ShiftSchedule` added; no script-compile errors in the gateway log.

- [ ] **Step 7: Commit**

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Oee/ShiftSchedule
git commit -m "feat(oee): ShiftSchedule python wrappers + bitmask/time helpers"
```

---

## Task 3: `ShiftScheduleRow` component view

One repeater row. Mirror `Components/DowntimeCodeRow`, adapt columns to Name · Days · Start · End · Effective From · (edit).

**Files:**
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/ShiftScheduleRow/{view.json,resource.json}`

**Interfaces:**
- Consumes: `params.value` = one dict from `ShiftSchedule.search()` (keys `Id, Name, Description, StartTimeText, EndTimeText, DaysLabel, DaysMask, EffectiveFromText, DeprecatedAt`), plus a `selected` bool the list transform adds.
- Produces: opens popup `BlueRidge/Components/Popups/ShiftScheduleEditor` with `params {mode:"edit", editId: <Id>}` on edit-button click.

- [ ] **Step 1: Copy `DowntimeCodeRow` as the starting point**

Copy both files from `Components/DowntimeCodeRow/` to `Components/ShiftScheduleRow/`. This carries the `params.value` input param, the row flex layout, deprecated-dimming style, and the edit-button pattern.

- [ ] **Step 2: Adapt the columns**

Replace the row's cell labels to bind these `params.value` keys with matching `basis` widths (mirror the DowntimeCodes header widths in Task 5):
- Name — `{view.params.value.Name}`, `basis: 220px`
- Days — `{view.params.value.DaysLabel}`, `basis: 0, grow: 1`
- Start — `{view.params.value.StartTimeText}`, `basis: 90px`
- End — `{view.params.value.EndTimeText}`, `basis: 90px`
- Effective From — `{view.params.value.EffectiveFromText}`, `basis: 130px`
- Edit button — `basis: 80px`

- [ ] **Step 3: Wire the edit button's `onActionPerformed`**

Body starts with `\t`; `scope: "G"`:
```python
	system.perspective.openPopup(
		id="mpp-shift-schedule-editor",
		view="BlueRidge/Components/Popups/ShiftScheduleEditor",
		modal=True,
		showCloseIcon=False,
		draggable=False,
		params={"mode": "edit", "editId": self.view.params.value.Id}
	)
```

- [ ] **Step 4: Deprecated dimming**

Keep the DowntimeCodeRow pattern: bind the row container style opacity/class on `{view.params.value.DeprecatedAt}` being non-null (mirror whatever DowntimeCodeRow does — same key name, `DeprecatedAt`).

- [ ] **Step 5: Scan and eyeball**

Run: `.\scan.ps1`
Expected: `ShiftScheduleRow` added; no view-deserialize error in the log. (Full visual check happens in Task 5 when the list renders rows.)

- [ ] **Step 6: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/ShiftScheduleRow
git commit -m "feat(config): ShiftScheduleRow repeater row"
```

---

## Task 4: `ShiftScheduleEditor` popup view

Modal create/edit. Mirror `Components/Popups/DowntimeCodeEditor`; swap the fields for Name, Description, 7 day-chips, Start/End HH:MM text, Effective From date picker; add Deprecate in edit mode.

**Files:**
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/ShiftScheduleEditor/{view.json,resource.json}`

**Interfaces:**
- Consumes: `params {mode: "create"|"edit", editId: BIGINT|None}`; `BlueRidge.Oee.ShiftSchedule.{loadMeta,emptyMeta,add,update,deprecate,daysToBitmask}`; `BlueRidge.Common.Notify.toast`.
- Produces: broadcasts page-scoped message `shiftSchedulesRefresh` after successful save/deprecate; closes popup `mpp-shift-schedule-editor`.

- [ ] **Step 1: Copy `DowntimeCodeEditor` as the starting point**

Copy both files to `Components/Popups/ShiftScheduleEditor/`. This carries the modal chrome, `editDraft` custom prop, save/close footer, and the `onStartup` load pattern.

- [ ] **Step 2: Pre-seed `editDraft` with the full shape**

In `view.custom`, set `editDraft` default to the `emptyMeta()` shape so first paint has every bound key (no red borders / literal "null"):
```json
"custom": {
  "editDraft": {
    "id": null, "name": "", "description": "",
    "days": [], "startTime": "", "endTime": "", "effectiveFrom": ""
  }
}
```

- [ ] **Step 3: Load on startup (atomic single write)**

Use `events.system` `onStartup` (NOT `events.component.onStartup`). Body starts with `\t`:
```python
	import BlueRidge.Oee.ShiftSchedule as SS
	mode = self.view.params.mode
	if mode == "edit" and self.view.params.editId is not None:
		self.view.custom.editDraft = SS.loadMeta(self.view.params.editId)
	else:
		self.view.custom.editDraft = SS.emptyMeta()
```
(One property write — never seed field-by-field.)

- [ ] **Step 4: Build the field rows**

Replace the DowntimeCode fields with:
- **Name** — `ia.input.text-field`, `props.text` bidi to `view.custom.editDraft.name`.
- **Description** — `ia.input.text-field`, bidi to `...editDraft.description`.
- **Days** — a horizontal flex of 7 chip buttons (Step 5).
- **Start Time** — `ia.input.text-field`, bidi to `...editDraft.startTime`, `placeholder: "HH:MM"`.
- **End Time** — `ia.input.text-field`, bidi to `...editDraft.endTime`, `placeholder: "HH:MM"`.
- **Effective From** — `ia.input.date-time` picker (Step 6).

Each wrapped in the label+field column pattern from DowntimeCodeEditor.

- [ ] **Step 5: Build the 7 day-chip toggles**

A flex row named `DayChips` with 7 `ia.input.button` children (Mon..Sun). Each chip `i` (0..6):
- `props.text`: the day name.
- `props.style.classes` via an expression binding that highlights when selected:
  `if(contains(toStr({view.custom.editDraft.days}), toStr(<i>)), 'chip chip-on', 'chip')`
  (use the project chip classes if present; otherwise inline `background`/`border` style — mirror any existing chip styling in the codebase, else a filled vs outlined look).
- `onActionPerformed` (body starts `\t`) toggles index `<i>` in the days list:
```python
	days = list(self.view.custom.editDraft.days or [])
	i = <i>
	if i in days:
		days.remove(i)
	else:
		days.append(i)
		days.sort()
	self.view.custom.editDraft.days = days
```
(Author 7 buttons with `<i>` = 0..6. Repeat the code per button — do not abstract; the literal index differs each time.)

- [ ] **Step 6: Effective From date picker (TZ-safe string on save)**

`ia.input.date-time` bound to a local `view.custom.editDraft.effectiveFromMillis` (epoch millis), initialized in Step 3 loader from the `effectiveFrom` string when editing:
- In the loader, after `loadMeta`, if `effectiveFrom` present set `effectiveFromMillis = system.date.getMillis(system.date.parse(effectiveFrom, "yyyy-MM-dd"))`, else `None`.
- On save, derive the string: `system.date.format(system.date.fromMillis(millis), "yyyy-MM-dd")`.
Add `effectiveFromMillis: null` to the `editDraft` default in Step 2.

- [ ] **Step 7: Save handler**

The Save button `onActionPerformed` (body starts `\t`):
```python
	import BlueRidge.Oee.ShiftSchedule as SS
	import BlueRidge.Common.Notify as Notify
	d = dict(self.view.custom.editDraft)

	# required-field + HH:MM pre-validation (server re-validates)
	import re
	name = (d.get("name") or "").strip()
	days = list(d.get("days") or [])
	st = (d.get("startTime") or "").strip()
	et = (d.get("endTime") or "").strip()
	millis = d.get("effectiveFromMillis")
	pat = re.compile(r"^([01]?\d|2[0-3]):[0-5]\d$")
	if not name or not days or not pat.match(st) or not pat.match(et) or millis is None:
		Notify.toast("Cannot save", "Name, at least one day, valid HH:MM times, and an effective date are required.", "warning")
		return

	meta = {
		"id":                d.get("id"),
		"name":              name,
		"description":       (d.get("description") or "").strip(),
		"daysOfWeekBitmask": SS.daysToBitmask(days),
		"startTime":         st,
		"endTime":           et,
		"effectiveFrom":     system.date.format(system.date.fromMillis(millis), "yyyy-MM-dd"),
	}
	res = SS.update(meta) if meta["id"] is not None else SS.add(meta)
	if res and res.get("Status"):
		Notify.toast("Saved", res.get("Message") or "Shift schedule saved.", "success")
		system.perspective.sendMessage("shiftSchedulesRefresh", {}, scope="page")
		system.perspective.closePopup("mpp-shift-schedule-editor")
	else:
		Notify.toast("Save failed", (res or {}).get("Message") or "Unknown error.", "error")
```

- [ ] **Step 8: Deprecate button (edit mode only)**

Visible when `{view.params.mode} = 'edit'`. `onActionPerformed` (body starts `\t`):
```python
	import BlueRidge.Oee.ShiftSchedule as SS
	import BlueRidge.Common.Notify as Notify
	res = SS.deprecate(self.view.params.editId)
	if res and res.get("Status"):
		Notify.toast("Deprecated", res.get("Message") or "Shift schedule deprecated.", "success")
		system.perspective.sendMessage("shiftSchedulesRefresh", {}, scope="page")
		system.perspective.closePopup("mpp-shift-schedule-editor")
	else:
		Notify.toast("Deprecate failed", (res or {}).get("Message") or "Unknown error.", "error")
```

- [ ] **Step 9: Close/X button**

Mirror DowntimeCodeEditor's close (it closes `mpp-shift-schedule-editor`). Keep it simple — closePopup on the editor id. (ConfirmUnsaved dirty-guard is a nice-to-have; DowntimeCodeEditor's own close behavior is the baseline to match — do whatever it does.)

- [ ] **Step 10: Scan**

Run: `.\scan.ps1`
Expected: `ShiftScheduleEditor` added; no view-deserialize error. If the log shows a GSON schema error, check `customMethods` params are `list[str]` and there are no trailing commas. (`feedback_ignition_view_deserialize_schema`, `feedback_ignition_view_json_corruption`)

- [ ] **Step 11: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Components/Popups/ShiftScheduleEditor
git commit -m "feat(config): ShiftScheduleEditor popup (day chips, HH:MM times, deprecate)"
```

---

## Task 5: `ShiftSchedules` list view + `/shifts` route

The screen the nav points at. Mirror `Views/Oee/DowntimeCodes`; drop the Area/Type filter sidebar (keep only Search + Include-deprecated in a lighter top bar); register `/shifts`.

**Files:**
- Create: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Oee/ShiftSchedules/{view.json,resource.json}`
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/page-config/config.json`

**Interfaces:**
- Consumes: `BlueRidge.Oee.ShiftSchedule.search`; repeater child `BlueRidge/Components/ShiftScheduleRow`; page-scoped message `shiftSchedulesRefresh` from the editor.
- Produces: page route `/shifts`.

- [ ] **Step 1: Copy `DowntimeCodes` as the starting point**

Copy both files from `Views/Oee/DowntimeCodes/` to `Views/Oee/ShiftSchedules/`.

- [ ] **Step 2: Simplify `custom.filter` and the bindings**

Set:
```json
"custom": {
  "filter": { "includeDeprecated": false, "searchText": "" }
}
```
Remove `areaOptions`/`reasonTypeOptions`/`areaLocationId`/`downtimeReasonTypeId` propConfig entries. Repoint the rows binding:
```
"custom.rows" expression: runScript("BlueRidge.Oee.ShiftSchedule.search", 0, {view.custom.filter})
```
Keep `custom.filter.searchText` and `custom.filter.includeDeprecated` `persistent: true`.

- [ ] **Step 3: Replace the 220px filter sidebar with a lighter top-bar filter**

Delete the `FilterSidebar`/`FilterPanel` (Area + Reason Type + Search + Include-deprecated). In its place keep just a Search text field (bidi to `view.custom.filter.searchText`) and an Include-deprecated checkbox (bidi to `view.custom.filter.includeDeprecated`) — place them in the title row or a slim bar above the table. Set `MainSplit` to a single full-width content column.

- [ ] **Step 4: Update title + breadcrumb + Add button**

- Breadcrumb active crumb text: `Shift Schedules`; Title `h1`: `Shift Schedules`.
- Add button text: `+ Add Schedule`; its `onActionPerformed` opens the editor in create mode:
```python
	system.perspective.openPopup(
		id="mpp-shift-schedule-editor",
		view="BlueRidge/Components/Popups/ShiftScheduleEditor",
		modal=True,
		showCloseIcon=False,
		draggable=False,
		params={"mode": "create", "editId": None}
	)
```

- [ ] **Step 5: Update the table header + repeater**

- Header columns/widths to match Task 3: Name(220) · Days(grow) · Start(90) · End(90) · Effective From(130) · (edit,80).
- Repeater `path`: `BlueRidge/Components/ShiftScheduleRow`.
- Repeater `props.instances` transform: map each `search()` row dict straight through plus `"selected": False` (the search proc already shaped/renamed the keys, so the transform is a simple passthrough):
```python
	return [dict(r, selected=False) for r in (value or [])]
```

- [ ] **Step 6: Update the refresh message handler**

Rename the root `messageHandlers` entry `messageType` to `shiftSchedulesRefresh`, keep `pageScope: true`, body re-seeds the filter to re-run the rows binding:
```python
	self.view.custom.filter = dict(self.view.custom.filter)
```

- [ ] **Step 7: Register the `/shifts` route**

In `page-config/config.json`, add a `/shifts` entry mirroring `/downtime-codes`:
```json
"/shifts": {
  "viewPath": "BlueRidge/Views/Oee/ShiftSchedules"
}
```
(Match the exact shape/keys of the existing `/downtime-codes` object, including any `navIcon`/`title` keys it carries.)

- [ ] **Step 8: Scan and verify end-to-end**

Run: `.\scan.ps1`
Then in the Config app:
- Navigate via the Sidebar "Shift Schedules" item — the `/shifts` route resolves (no blank page; dead-link symptom gone).
- Click "+ Add Schedule": create a Mon–Fri 06:00–14:30 schedule effective today → toast success, row appears with Days label "Mon-Fri", Start 06:00, End 14:30.
- Edit it: chips reflect Mon–Fri; change to add Sat → save → row label "Mon-Sat".
- Create an overnight shift 22:00–06:00 → accepted (no error).
- Duplicate name → toast "already exists".
- Deprecate → row disappears; check "Include deprecated" → reappears dimmed.
- Confirm `Audit.ConfigLog` has Created/Updated/Deprecated rows for `ShiftSchedule` (Audit Browser or `SELECT TOP 5 ... FROM Audit.ConfigLog WHERE ... ORDER BY Id DESC`).

- [ ] **Step 9: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Oee/ShiftSchedules \
        ignition/projects/MPP_Config/com.inductiveautomation.perspective/page-config/config.json
git commit -m "feat(config): Shift Schedules list screen + /shifts route"
```

---

## Task 6: Downtime dashboard follow-up note

Record the downtime/OEE dashboard need (raised by Jacques) as a dated note and a PROJECT_STATUS line. Note-only; nothing built.

**Files:**
- Create: `notes/2026-07-21_downtime-dashboard-need.md`
- Modify: `PROJECT_STATUS.md` (append a follow-up line; append-only)

- [ ] **Step 1: Write the note**

```markdown
# Downtime / OEE dashboard — need noted 2026-07-21

Raised by Jacques while building the Shift Schedules config screen.

**Context:** The downtime subsystem records everything (Oee.DowntimeEvent open/close
intervals, ShiftId linkage, IsExcused, source Operator/PLC, break durations via
EndOfShiftEntry_Submit) but there is NO rollup/dashboard surface. Today only
Oee.DowntimeEvent_GetOpenSummary (plant-wide open counts, triage) and
Oee.DowntimeEvent_GetOpenByLocation exist.

**Wanted (future spec):**
- Open downtime by cell/line (live).
- Downtime Pareto by reason code and by reason type, over a shift/day/date-range.
- Availability % once a shift-availability rollup exists (downtime minutes vs shift
  minutes per Oee.Shift) — no proc computes A/P/Q today.

**Not started.** Separate brainstorm -> spec -> plan when scheduled. Related: the
shift-availability rollup gap and the absence of any OEE metric calculation.
```

- [ ] **Step 2: Append the PROJECT_STATUS line**

Add under the appropriate open-items/follow-ups area (do not rewrite existing content):
```markdown
- **Downtime/OEE dashboard (not started)** — supervisor dashboard: open downtime by cell, downtime Pareto by reason/type, availability once a shift rollup exists. See `notes/2026-07-21_downtime-dashboard-need.md`. (Shift Schedules config screen shipped 2026-07-21.)
```

- [ ] **Step 3: Commit**

```bash
git add notes/2026-07-21_downtime-dashboard-need.md PROJECT_STATUS.md
git commit -m "docs: note downtime/OEE dashboard follow-up"
```

---

## Self-Review

**Spec coverage:**
- 5 named queries → Task 1. ✅
- Python wrappers + bitmask/time helpers (single source of truth) → Task 2. ✅
- `ShiftSchedules` list (lighter filter, no sidebar) → Task 5. ✅
- `ShiftScheduleRow` (compact Days label) → Task 3. ✅
- `ShiftScheduleEditor` (7 day chips, HH:MM text, date picker, deprecate, atomic load, shaped default) → Task 4. ✅
- `/shifts` route; Sidebar unchanged → Task 5. ✅
- Overnight shift accepted; overlap validation NOT built (limitation) → verified Task 5 Step 8; no SQL touched. ✅
- Downtime dashboard note + PROJECT_STATUS line → Task 6. ✅
- Conventions (Core NQ, status-row type:Query, sqlType ordinals, atomic state, shaped defaults, scope:G popups, tab-prefixed event bodies, toasts, explicit staging) → Global Constraints + inline. ✅

**Placeholder scan:** No TBD/TODO; the one genuinely-new logic (bitmask helpers) has full code + a real red/green test; view tasks give exact bindings/scripts and a concrete mirror source. View.json body is authored by copy-and-adapt from a named reference file rather than pasted verbatim (600+ lines each) — deliberate, matches how this project builds views.

**Type consistency:** `search()` output keys (`Id, Name, Description, StartTimeText, EndTimeText, DaysLabel, DaysMask, EffectiveFromText, DeprecatedAt`) are consumed identically in Task 3 (row) and Task 5 (repeater transform). Editor uses `loadMeta/emptyMeta` shape (`id, name, description, days, startTime, endTime, effectiveFrom` + local `effectiveFromMillis`) consistently across load (Step 3) and save (Step 7). `daysToBitmask`/`bitmaskToDays`/`bitmaskToLabel` names match across Tasks 2/3/4. Popup id `mpp-shift-schedule-editor` and message `shiftSchedulesRefresh` match across Tasks 3/4/5.
