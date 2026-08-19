"""BlueRidge.Oee.ShiftOverride - CRUD wrappers for the Config Tool Shift
   Overrides screen (per-equipment shift windows, backlog 6.1).

   Wrappers only; no business logic. The resolution rule ("if the equipment has
   an override for the day use it, else fall back to the global shift") lives in
   SQL, in Oee.ufn_ShiftWindowForLocation -- deliberately NOT duplicated here,
   because the OEE math reads it directly and the two must never disagree.

   TIME BASIS: StartTime / EndTime are LOCAL (Eastern) wall clock 'HH:MM'
   strings and BusinessDate is a local 'YYYY-MM-DD' date, matching
   Oee.ShiftSchedule and Oee.Shift (OI-38). Nothing here converts a timezone.

   All public functions unwrap QualifiedValue wrappers at entry via _u()."""

import system.date

_MINUTES_PER_HOUR = 60.0


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


# ---- formatting (the procs return java.sql.Time/Date; normalize to text) ----
def _fmtTime(v):
    """java.sql.Time / Timestamp / string / None -> 'HH:MM' (or '').
       The JDBC driver returns a TIME column as a Timestamp with a 1900-01-01
       date prefix (e.g. '1900-01-01 06:00:00.0'), so drop any leading date part
       before taking HH:MM. Mirrors BlueRidge.Oee.ShiftSchedule._fmtTime."""
    if v is None:
        return ""
    s = unicode(v)
    if " " in s:
        s = s.split(" ")[-1]
    return s[:5]


def _fmtDate(v):
    """java.sql.Date / string / None -> 'YYYY-MM-DD' (or '')."""
    if v is None:
        return ""
    return unicode(v)[:10]


def _deltaLabel(mins):
    """Signed wall-clock delta vs the global schedule, as operator-facing text.
       '+2h', '-45m', '+1h 30m', 'no change'."""
    if mins is None:
        return ""
    m = int(mins)
    if m == 0:
        return "no change"
    sign = "+" if m > 0 else "-"
    m = abs(m)
    h, rem = m // 60, m % 60
    if h and rem:
        return "%s%dh %dm" % (sign, h, rem)
    if h:
        return "%s%dh" % (sign, h)
    return "%s%dm" % (sign, rem)


def _hoursLabel(mins):
    """Planned window length as hours text, e.g. '8.5 h'."""
    if mins is None:
        return ""
    return "%.4g h" % (int(mins) / _MINUTES_PER_HOUR)


# ---- reads ----
def listEquipment(searchText=None):
    """Equipment an override may be authored against (die cast presses +
       Machining/Assembly lines). Backed by the same SQL function the Create
       proc validates with, so the picker and the proc cannot disagree.
       Returns list[dict] with LocationId / Code / Name / DisplayLabel."""
    BlueRidge.Common.Util.log("searchText=%s" % searchText)
    try:
        return BlueRidge.Common.Db.execList(
            "oee/ShiftOverride_ListEquipment", {"searchText": _u(searchText)}) or []
    except Exception as e:
        BlueRidge.Common.Util.log("listEquipment failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Could not load equipment", str(e), "error")
        return []


def equipmentOptions(searchText=None):
    """Dropdown options [{label, value}] for the equipment picker. Safe [] on error."""
    return [{"label": r.get("DisplayLabel") or r.get("Name") or "",
             "value": r.get("LocationId")}
            for r in listEquipment(searchText)]


def search(filters=None):
    """Overrides shaped for the flex-repeater.
       filters: {locationId, fromDate, toDate, includeDeprecated}.
       Returns [] on any DB/JDBC error (never raises into a binding)."""
    BlueRidge.Common.Util.log("filters=%s" % filters)
    f = _u(filters) or {}
    params = {
        "locationId":        f.get("locationId") or None,
        "fromDate":          (f.get("fromDate") or None),
        "toDate":            (f.get("toDate") or None),
        "includeDeprecated": 1 if bool(f.get("includeDeprecated", False)) else 0,
    }
    try:
        rows = BlueRidge.Common.Db.execList("oee/ShiftOverride_List", params)
    except Exception as e:
        BlueRidge.Common.Util.log("list failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Could not load shift overrides", str(e), "error")
        return []

    needle = (f.get("searchText") or "").strip().lower()
    out = []
    for r in (rows or []):
        code = r.get("LocationCode") or ""
        name = r.get("LocationName") or ""
        if needle and needle not in code.lower() and needle not in name.lower():
            continue
        delta = r.get("DeltaMinutes")
        out.append({
            "Id":                r.get("Id"),
            "LocationId":        r.get("LocationId"),
            "EquipmentCode":     code,
            "EquipmentName":     name,
            "ShiftScheduleId":   r.get("ShiftScheduleId"),
            "ScheduleName":      r.get("ScheduleName") or "",
            "BusinessDateText":  _fmtDate(r.get("BusinessDate")),
            "BaselineText":      "%s - %s" % (_fmtTime(r.get("ScheduleStartTime")),
                                              _fmtTime(r.get("ScheduleEndTime"))),
            "OverrideText":      "%s - %s" % (_fmtTime(r.get("StartTime")),
                                              _fmtTime(r.get("EndTime"))),
            "StartTimeText":     _fmtTime(r.get("StartTime")),
            "EndTimeText":       _fmtTime(r.get("EndTime")),
            "DurationMinutes":   r.get("DurationMinutes"),
            "HoursText":         _hoursLabel(r.get("DurationMinutes")),
            "DeltaMinutes":      delta,
            "DeltaText":         _deltaLabel(delta),
            "Reason":            r.get("Reason") or "",
            "IsDeprecated":      bool(r.get("IsDeprecated")),
            "CreatedByInitials": r.get("CreatedByInitials") or "",
        })
    return out


def getOne(id):
    """Raw single-row lookup by Id. Returns dict or None."""
    BlueRidge.Common.Util.log("id=%s" % id)
    if id is None:
        return None
    try:
        return BlueRidge.Common.Db.execOne("oee/ShiftOverride_Get", {"id": _u(id)})
    except Exception as e:
        BlueRidge.Common.Util.log("get failed: %s" % str(e))
        return None


# ---- mutations ----
def add(meta):
    """Create. meta = {locationId, shiftScheduleId, businessDate, startTime,
       endTime, reason}. times 'HH:MM', date 'YYYY-MM-DD', all LOCAL.
       Returns {Status, Message, NewId}."""
    BlueRidge.Common.Util.log("meta=%s" % meta)
    m = _u(meta) or {}
    params = {
        "locationId":      m.get("locationId"),
        "shiftScheduleId": m.get("shiftScheduleId"),
        "businessDate":    m.get("businessDate"),
        "startTime":       m.get("startTime"),
        "endTime":         m.get("endTime"),
        "reason":          m.get("reason"),
        "appUserId":       BlueRidge.Common.Util._currentAppUserId(),
    }
    return BlueRidge.Common.Db.execMutation("oee/ShiftOverride_Create", params)


def update(meta):
    """Update the window / reason. meta = {id, startTime, endTime, reason}.
       The KEY (equipment, shift, date) is immutable -- moving an override is a
       deprecate + create, so the audit trail shows two distinct assertions.
       Returns {Status, Message}."""
    BlueRidge.Common.Util.log("meta=%s" % meta)
    m = _u(meta) or {}
    params = {
        "id":        m.get("id"),
        "startTime": m.get("startTime"),
        "endTime":   m.get("endTime"),
        "reason":    m.get("reason"),
        "appUserId": BlueRidge.Common.Util._currentAppUserId(),
    }
    return BlueRidge.Common.Db.execMutation("oee/ShiftOverride_Update", params)


def deprecate(id):
    """Soft-delete by Id; the equipment falls back to the global shift window.
       Returns {Status, Message}."""
    BlueRidge.Common.Util.log("id=%s" % id)
    params = {
        "id":        _u(id),
        "appUserId": BlueRidge.Common.Util._currentAppUserId(),
    }
    return BlueRidge.Common.Db.execMutation("oee/ShiftOverride_Deprecate", params)


# ---- editor shapes ----
def emptyMeta():
    """Blank editor dict (create mode). EVERY key the editor form binds is
       present -- a partially-shaped dict renders validation-error borders and
       literal 'null' text in the fields on first paint."""
    return {
        "id":               None,
        "locationId":       None,
        "equipmentLabel":   "",
        "shiftScheduleId":  None,
        "scheduleName":     "",
        "baselineText":     "",
        "businessDate":     "",     # 'YYYY-MM-DD'
        "businessDateVal":  None,   # java.util.Date backing the date picker
        "startTime":        "",     # 'HH:MM'
        "endTime":          "",     # 'HH:MM'
        "reason":           "",
        "isDeprecated":     False,
    }


def loadMeta(id):
    """Editor edit-mode dict: getOne(id) mapped to the emptyMeta() shape.
       NEVER returns None -- a binding that traverses a nested path against None
       renders the component as a Component Error."""
    row = getOne(id)
    if not row:
        return emptyMeta()
    bd = _fmtDate(row.get("BusinessDate"))
    # The date-time-input's props.value is a java.util.Date (NOT epoch millis),
    # so seed edit-mode with a Date the picker can display.
    dateVal = None
    if bd:
        try:
            dateVal = system.date.parse(bd, "yyyy-MM-dd")
        except Exception:
            dateVal = None
    return {
        "id":              row.get("Id"),
        "locationId":      row.get("LocationId"),
        "equipmentLabel":  "%s - %s" % (row.get("LocationCode") or "", row.get("LocationName") or ""),
        "shiftScheduleId": row.get("ShiftScheduleId"),
        "scheduleName":    row.get("ScheduleName") or "",
        "baselineText":    "%s - %s" % (_fmtTime(row.get("ScheduleStartTime")),
                                        _fmtTime(row.get("ScheduleEndTime"))),
        "businessDate":    bd,
        "businessDateVal": dateVal,
        "startTime":       _fmtTime(row.get("StartTime")),
        "endTime":         _fmtTime(row.get("EndTime")),
        "reason":          row.get("Reason") or "",
        "isDeprecated":    bool(row.get("IsDeprecated")),
    }


# ---- availability (the reason overrides exist) ----
_EMPTY_AVAILABILITY = {
    "ShiftId": None, "ScheduleName": "", "BusinessDate": None,
    "LocationId": None, "LocationCode": "", "LocationName": "",
    "PlannedMinutes": 0, "DowntimeMinutes": 0, "UnexcusedDowntimeMinutes": 0,
    "RunMinutes": 0, "Availability": None, "DowntimeEventCount": 0,
    "IsOverridden": False, "ShiftOverrideId": None, "OverrideReason": "",
    "PlannedHoursText": "", "AvailabilityPct": "",
}


def _shapeAvailability(r):
    planned = r.get("PlannedMinutes")
    avail = r.get("Availability")
    out = dict(_EMPTY_AVAILABILITY)
    out.update(r)
    out["PlannedHoursText"] = _hoursLabel(planned)
    out["AvailabilityPct"] = "" if avail is None else "%.1f%%" % (float(avail) * 100.0)
    out["IsOverridden"] = bool(r.get("IsOverridden"))
    out["OverrideReason"] = r.get("OverrideReason") or ""
    return out


def availability(shiftId, locationId=None):
    """Per-equipment availability for one shift instance, override-aware.
       locationId None -> one row per piece of equipment. Returns list[dict];
       [] on error or unknown shift."""
    BlueRidge.Common.Util.log("shiftId=%s locationId=%s" % (shiftId, locationId))
    if shiftId is None:
        return []
    try:
        rows = BlueRidge.Common.Db.execList("oee/Shift_GetAvailability", {
            "shiftId":    _u(shiftId),
            "locationId": _u(locationId),
        })
    except Exception as e:
        BlueRidge.Common.Util.log("availability failed: %s" % str(e))
        return []
    return [_shapeAvailability(r) for r in (rows or [])]


def availabilityOrEmpty(shiftId, locationId=None):
    """Binding-safe single-row availability: ALWAYS a fully-shaped dict, never
       None, so a binding that traverses a nested path cannot error on the
       empty/not-found path."""
    rows = availability(shiftId, locationId)
    return rows[0] if rows else dict(_EMPTY_AVAILABILITY)
