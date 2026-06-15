"""BlueRidge.Oee.DowntimeReasonCode - full CRUD for downtime reason codes.

   All public functions unwrap QualifiedValue wrappers at entry via _u() so
   bidirectional-bound view properties can be passed straight through."""

import BlueRidge.Common.Db
import BlueRidge.Common.Notify
import BlueRidge.Common.Util


def _u(value):
    return BlueRidge.Common.Util.extractQualifiedValues(value)


def search(filters=None):
    """List DowntimeReasonCode rows filtered by the supplied dict.

       filters keys (all optional):
         areaLocationId        BIGINT or None  (server-side filter via proc)
         downtimeReasonTypeId  BIGINT or None  (server-side filter via proc)
         includeDeprecated     bool, default False (server-side filter via proc)
         searchText            string or None  (CLIENT-side filter applied here;
                                                 the proc itself has no @SearchText)"""
    BlueRidge.Common.Util.log("filters=%s" % filters)
    f = _u(filters) or {}
    params = {
        "areaLocationId":       f.get("areaLocationId"),
        "downtimeReasonTypeId": f.get("downtimeReasonTypeId"),
        "includeDeprecated":    bool(f.get("includeDeprecated", False)),
    }
    try:
        rows = BlueRidge.Common.Db.execList("oee/DowntimeReasonCode_List", params)
    except Exception as e:
        BlueRidge.Common.Util.log("list failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Could not load downtime codes", str(e), "error")
        return []

    # Client-side search filter (proc has no @SearchText param).
    # 353-row max set; in-process filter on Code + Description is trivial.
    # Row dict keys are PascalCase -- they mirror the proc's SELECT aliases
    # (drc.Code, drc.Description). If the proc ever renames those, this
    # filter silently no-ops and returns the unfiltered list.
    needle = (f.get("searchText") or "").strip().lower()
    if not needle:
        return rows
    return [
        r for r in rows
        if needle in (r.get("Code") or "").lower()
        or needle in (r.get("Description") or "").lower()
    ]


def getOne(id):
    """Single-row lookup by Id. Returns dict or None."""
    BlueRidge.Common.Util.log("id=%s" % id)
    if id is None:
        return None
    try:
        return BlueRidge.Common.Db.execOne("oee/DowntimeReasonCode_Get", {"id": _u(id)})
    except Exception as e:
        BlueRidge.Common.Util.log("get failed: %s" % str(e))
        return None


def add(meta):
    """Create. meta = {code, description, areaLocationId, downtimeReasonTypeId, isExcused}.
       Returns {Status, Message, NewId}."""
    BlueRidge.Common.Util.log("meta=%s" % meta)
    m = _u(meta) or {}
    params = {
        "code":                 m.get("code"),
        "description":          m.get("description"),
        "areaLocationId":       m.get("areaLocationId"),
        "downtimeReasonTypeId": m.get("downtimeReasonTypeId"),
        "isExcused":            bool(m.get("isExcused", False)),
        "appUserId":            BlueRidge.Common.Util._currentAppUserId(),
    }
    return BlueRidge.Common.Db.execMutation("oee/DowntimeReasonCode_Create", params)


def update(meta):
    """Update. meta = {id, description, areaLocationId, downtimeReasonTypeId, isExcused}.
       Code is immutable post-create; proc rejects changes.
       Returns {Status, Message}."""
    BlueRidge.Common.Util.log("meta=%s" % meta)
    m = _u(meta) or {}
    params = {
        "id":                   m.get("id"),
        "description":          m.get("description"),
        "areaLocationId":       m.get("areaLocationId"),
        "downtimeReasonTypeId": m.get("downtimeReasonTypeId"),
        "isExcused":            bool(m.get("isExcused", False)),
        "appUserId":            BlueRidge.Common.Util._currentAppUserId(),
    }
    return BlueRidge.Common.Db.execMutation("oee/DowntimeReasonCode_Update", params)


def deprecate(id):
    """Soft-delete by Id. Returns {Status, Message}."""
    BlueRidge.Common.Util.log("id=%s" % id)
    params = {
        "id":        _u(id),
        "appUserId": BlueRidge.Common.Util._currentAppUserId(),
    }
    return BlueRidge.Common.Db.execMutation("oee/DowntimeReasonCode_Deprecate", params)


def emptyMeta():
    """Blank meta dict for editor create-mode initialization."""
    return {
        "id":                   None,
        "code":                 "",
        "description":          "",
        "areaLocationId":       None,
        "downtimeReasonTypeId": None,
        "isExcused":            False,
    }
