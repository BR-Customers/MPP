# =============================================================================
# Project Library:  BlueRidge.Common.Db
#
# Author:           Blue Ridge Automation
# Created:          2026-05-14
# Version:          1.0
#
# Description:
#   Three sibling helpers paired to the three shapes a stored-proc result
#   takes in this project:
#
#       execList(nq, params=None)      -> list[dict]    (0..N rows)
#       execOne(nq, params=None)       -> dict | None   (0 or 1 row)
#       execMutation(nq, params=None)  -> dict          (status row;
#                                                        Status BIT 1/0)
#
#   Every entity script in the project routes its DB calls through these
#   three. No entity script calls system.db.* directly. The three-layer
#   rule (View -> Entity script -> Common.Db) keeps:
#       - NQ names out of views
#       - the dict(zip(headers, row)) idiom in exactly one place
#       - audit logging, user-id injection, transient-retry policy all
#         centralizable here when needed
#
# Status convention (project-specific, source of truth: SQL repeatable procs):
#   Mutation procs DECLARE @Status BIT = 0; SET @Status = 1 on success;
#   return SELECT @Status AS Status, @Message AS Message [, @NewId AS NewId].
#   So execMutation result reads:
#       result["Status"]    -> 1 (truthy) on success, 0 on business-rule fail
#       result["Message"]   -> NVARCHAR(500) message text
#       result["NewId"]     -> BIGINT on Create/Add procs, absent otherwise
#
#   Callers should check `if result.get("Status"):` rather than
#   `== "OK"` -- the project's status type is BIT, not NVARCHAR.
#
# Layer:
#   Common helper -- the only layer permitted to call system.db.*.
#
# Change Log:
#   2026-05-14 - 1.0 - Initial version. Supersedes
#                      BlueRidge.Common.Action.runMutation (which mixed
#                      DB + toast). The toast firing is now the caller's
#                      explicit responsibility via Common.Ui.notifyResult.
# =============================================================================


def _rowsToDicts(ds):
    """Ignition Dataset -> list of {columnName: value} dicts.
       Returns [] for None or empty datasets."""
    if ds is None or ds.getRowCount() == 0:
        return []
    headers = list(ds.getColumnNames())
    return [dict(zip(headers, row)) for row in ds]


def execList(nq, params=None):
    """
    Run a read NQ that returns 0..N data rows.

    Args:
        nq (str):           Named-query path, e.g. "location/getAll".
        params (dict|None): Parameter map. Pass None for parameterless NQs.

    Returns:
        list[dict]: Rows keyed by the proc's SELECT aliases. Empty list
                    when no rows matched -- never None, never raises for
                    the not-found case.
    """
    BlueRidge.Common.Util.log("nq=%s params=%s" % (nq, params))
    ds = system.db.runNamedQuery(nq, params) if params is not None else system.db.runNamedQuery(nq)
    rows = _rowsToDicts(ds)
    BlueRidge.Common.Util.log("rows=%d" % len(rows))
    return rows


def execOne(nq, params=None):
    """
    Run a read NQ that returns 0 or 1 row.

    Args:
        nq (str):           Named-query path.
        params (dict|None): Parameter map. Pass None for parameterless NQs.

    Returns:
        dict or None: The row as a dict, or None when no row matched.
                      Logs a warning and returns the first row if the proc
                      returned more than one.
    """
    rows = execList(nq, params)
    if not rows:
        return None
    if len(rows) > 1:
        BlueRidge.Common.Util.log("WARN multi-row from execOne nq=%s" % nq)
    return rows[0]


def execMutation(nq, params=None):
    """
    Run a mutation NQ (Add / Update / Deprecate / SaveAll) that follows the
    project's status-row convention.

    The proc emits exactly one result set:
        SELECT @Status AS Status, @Message AS Message [, @NewId AS NewId];
    where @Status is BIT (1=success, 0=failure) and @Message is NVARCHAR(500).

    Args:
        nq (str):           Named-query path.
        params (dict|None): Parameter map.

    Returns:
        dict: Always returns a dict, even on failure. Keys match the proc's
              SELECT aliases:
                  Status (int)  1 = success, 0 = business-rule failure
                  Message (str) proc-supplied user-readable message
                  NewId (long)  present only on Create/Add procs
              Returns {"Status": 0, "Message": "No status returned from proc"}
              if the proc emits no result set (proc misconfigured).

              Does NOT raise on Status=0 -- business-rule failures are not
              exceptions. Hard SQL errors / RAISERROR propagate as
              system.db exceptions.
    """
    BlueRidge.Common.Util.log("nq=%s params=%s" % (nq, params))
    ds = system.db.runNamedQuery(nq, params) if params is not None else system.db.runNamedQuery(nq)
    rows = _rowsToDicts(ds)
    if not rows:
        return {"Status": 0, "Message": "No status returned from proc"}
    if len(rows) > 1:
        BlueRidge.Common.Util.log("WARN multi-row from execMutation nq=%s" % nq)
    result = rows[0]
    BlueRidge.Common.Util.log("result=%s" % result)
    return result
