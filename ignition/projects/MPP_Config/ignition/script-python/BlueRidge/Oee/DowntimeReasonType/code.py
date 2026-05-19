"""BlueRidge.Oee.DowntimeReasonType - read-only access to the 6 seeded reason types."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def getAll():
    """List all DowntimeReasonType rows. Returns list[dict] keyed by SELECT aliases.
       Result is small (6 rows) and stable; NQ has 30-min cache enabled."""
    BlueRidge.Common.Util.log("running")
    try:
        return BlueRidge.Common.Db.execList("oee/DowntimeReasonType_List")
    except Exception as e:
        BlueRidge.Common.Util.log("ERROR %s" % str(e))
        return []


def getForDropdown(includeUnassigned=False, includeAll=False):
    """Returns [{label, value}] for ia.input.dropdown.

       includeUnassigned: prepends {label: '(Unassigned)', value: None}
         for filter sidebars that need to surface DowntimeReasonCode rows with NULL TypeId.
       includeAll: prepends {label: 'All Types', value: None}
         for the filter sidebar's 'no type filter' option.

       Filter sidebar typically calls with (True, True); editor popup calls with defaults."""
    rows = getAll()
    out = [{"label": r.get("Name") or "", "value": r.get("Id")} for r in rows]
    if includeUnassigned:
        out.insert(0, {"label": "(Unassigned)", "value": None})
    if includeAll:
        out.insert(0, {"label": "All Types", "value": None})
    return out
