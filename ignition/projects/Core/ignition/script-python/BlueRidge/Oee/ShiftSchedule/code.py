"""BlueRidge.Oee.ShiftSchedule - CRUD wrappers + bitmask/time formatting for the
   Config Tool Shift Schedules screen. Wrappers only; the only real logic is the
   pure bitmask <-> day-list conversion (single source of truth for both the row
   label and the editor chips). All public functions unwrap QualifiedValue
   wrappers at entry via _u()."""

import BlueRidge.Common.Db
import BlueRidge.Common.Notify
import BlueRidge.Common.Util
import system.date

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


def chipOn(days, i):
    """True if day index i (0=Mon..6=Sun) is in the selected-days list. Used by the
       editor's per-chip style bindings (runScript inside an expr if())."""
    d = _u(days) or []
    return int(i) in [int(x) for x in d]


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
    """java.sql.Time / Timestamp / string / None -> 'HH:MM' (or '').
       The JDBC driver returns a TIME column as a Timestamp with a 1900-01-01 date
       prefix (e.g. '1900-01-01 06:00:00.0'), so drop any leading date part before
       taking HH:MM."""
    if v is None:
        return ""
    s = unicode(v)
    if " " in s:                        # 'YYYY-MM-DD HH:MM:SS[.f]' -> 'HH:MM:SS[.f]'
        s = s.split(" ")[-1]
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
        "effectiveFromMillis": None,   # epoch millis backing the date picker
    }


def loadMeta(id):
    """Editor edit-mode dict: getOne(id) mapped to the emptyMeta() shape (with days list)."""
    row = getOne(id)
    if not row:
        return emptyMeta()
    mask = int(row.get("DaysOfWeekBitmask") or 0)
    eff = _fmtDate(row.get("EffectiveFrom"))
    millis = None
    if eff:
        try:
            millis = system.date.getMillis(system.date.parse(eff, "yyyy-MM-dd"))
        except Exception:
            millis = None
    return {
        "id":                  row.get("Id"),
        "name":                row.get("Name") or "",
        "description":         row.get("Description") or "",
        "days":                bitmaskToDays(mask),
        "startTime":           _fmtTime(row.get("StartTime")),
        "endTime":             _fmtTime(row.get("EndTime")),
        "effectiveFrom":       eff,
        "effectiveFromMillis": millis,
    }
