"""BlueRidge.Oee.DowntimeReasonType - read-only access to the 6 seeded reason types."""

import BlueRidge.Common.Db
import BlueRidge.Common.Notify
import BlueRidge.Common.Util


def getAll():
    """List all DowntimeReasonType rows. Returns list[dict] keyed by SELECT aliases.
       Result is small (6 rows) and stable; NQ has 30-min cache enabled."""
    BlueRidge.Common.Util.log("loading downtime reason types")
    try:
        return BlueRidge.Common.Db.execList("oee/DowntimeReasonType_List")
    except Exception as e:
        BlueRidge.Common.Util.log("list failed: %s" % str(e))
        BlueRidge.Common.Notify.toast("Could not load downtime reason types", str(e), "error")
        return []


def getForDropdown(includeUnassigned=False, includeAll=False):
    """Returns [{label, value}] for ia.input.dropdown.

       includeUnassigned: prepends {label: '(Unassigned)', value: None}
         for filter sidebars that need to surface DowntimeReasonCode rows with NULL TypeId.
       includeAll: prepends {label: 'All Types', value: None}
         for the filter sidebar's 'no type filter' option.

       When both flags are True the final order is [All Types, (Unassigned), ...rows...].
       Filter sidebar typically calls with (True, True); editor popup calls with defaults."""
    rows = getAll()
    out = [{"label": r.get("Name") or "", "value": r.get("Id")} for r in rows]
    prefix = []
    if includeAll:
        prefix.append({"label": "All Types", "value": None})
    if includeUnassigned:
        prefix.append({"label": "(Unassigned)", "value": None})
    return prefix + out
