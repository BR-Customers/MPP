"""BlueRidge.Oee.Summary - keeps Oee.ShiftSummary (the stored per-shift OEE
   figures) current. OEE dashboard spec
   docs/superpowers/specs/2026-10-27-oee-dashboard-design.md v0.3.2 sec 6.8.

   Wrappers only; every rule (which shifts are stale, the fingerprints, the
   calculation) lives in SQL. Callers:
     OeeSummaryRefresh timer (15 min)  -> refreshChanged
     OeeSummaryNightly timer (daily)   -> nightly (the last 7 days, safety net)
     tickShiftBoundary, after it closes a shift -> refreshChanged
     the release runbook / a data repair -> recomputeRange

   Gateway scope has no session: callers pass Common.Util.systemAppUserId().
   Never-throw: a timer must not raise (Java exceptions included)."""
import java.lang


def _fail(fn, e):
    BlueRidge.Common.Util.log("%s error: %s" % (fn, e), level="error")
    return {"Status": 0, "Message": "%s error: %s" % (fn, e)}


def refreshChanged(appUserId=None, maxShifts=60):
    """Recompute every stale closed shift, newest first, up to maxShifts.
       Returns {Status, Message, ShiftsComputed, ShiftsStillStale}."""
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    try:
        return BlueRidge.Common.Db.execMutation("oee/ShiftSummary_RefreshChanged", {
            "appUserId": appUserId,
            "maxShifts": maxShifts,
        })
    except (Exception, java.lang.Exception) as e:
        return _fail("refreshChanged", e)


def recomputeRange(fromUtc, toUtc, appUserId=None):
    """Recompute every closed shift that starts in [fromUtc, toUtc).
       Returns {Status, Message, ShiftsComputed}."""
    appUserId = BlueRidge.Common.Util.requireAppUserId(appUserId)
    try:
        return BlueRidge.Common.Db.execMutation("oee/ShiftSummary_RecomputeRange", {
            "fromUtc":   fromUtc,
            "toUtc":     toUtc,
            "appUserId": appUserId,
        })
    except (Exception, java.lang.Exception) as e:
        return _fail("recomputeRange", e)


def nightly(appUserId=None):
    """The nightly safety net: recompute the last 7 days. system.date.now() is
       passed as the UTC bound; the window is generous on both sides (8 days
       back to 1 day ahead) so a gateway clock in local time cannot clip it."""
    now = system.date.now()
    return recomputeRange(system.date.addDays(now, -8), system.date.addDays(now, 1), appUserId)
