# =============================================================================
# Project Library:  BlueRidge.Common.Action
#
# Author:           Blue Ridge Automation
# Created:          2026-05-13
# Version:          1.0
#
# Description:
#   Standard wrapper for user-triggered mutation actions: runs a status-row
#   named query, surfaces the result via toast, returns a success bool the
#   caller uses to drive UI refresh.
#
#   The MES SQL convention is that every mutation proc emits a single
#   `(Status BIT, Message NVARCHAR(500), [NewId BIGINT])` result row.
#   Status=1 is success (including no-op cases like "already at the top
#   position"). Status=0 is a validation / business-rule failure with a
#   user-readable Message. Unexpected SQL errors RAISERROR through to
#   Ignition and land in the except branch.
#
# Public surface:
#   runMutation(namedQuery, params, successTitle, successMsg, errorTitle)
#       -> {Status, Message, NewId|None, ...} dict on Status=1
#       -> None                              on validation failure or exception
#
#   The dict-or-None return is a strict upgrade from the original bool
#   shape — callers that just check truthiness (`if result:` /
#   `if not result:`) still work as before. New callers that need the
#   proc-assigned NewId (Create-style mutations) read it from the row.
#
# Layer:
#   View event -> Entity script (handleX) -> Common.Action.runMutation
#                                         -> system.db.execQuery (NQ engine)
#                                         -> Common.Notify.toast (UI feedback)
#
# Change Log:
#   2026-05-13 - 1.0 - Initial version
#   2026-05-13 - 1.1 - runMutation returns the status-row dict (or None)
#                      so callers can access NewId. Truthiness preserved.
# =============================================================================

logger = system.util.getLogger("BlueRidge.Common.Action")


def runMutation(namedQuery, params, successTitle, successMsg, errorTitle):
    """
    Run a status-row mutation NQ, surface the result via toast, return a
    success bool. Standard wrapper for any user-triggered DB mutation that
    needs operator feedback.

    Args:
        namedQuery (str):   NQ path, e.g. "location/MoveSortOrderUp".
        params (dict):      Param map for the NQ.
        successTitle (str): Toast title shown when the proc returns Status=1.
        successMsg (str):   Toast body shown when the proc returns Status=1.
        errorTitle (str):   Toast title shown on Status=0 or exception.
                            The proc's Message (or str(e) on exception) is
                            the toast body.

    Returns:
        dict or None:
            On Status=1: the status row as a dict ({Status, Message, NewId, ...}).
                         Caller may refresh UI; treats the result as truthy.
            On validation failure or exception: None. Toast already fired,
                         caller skips refresh.
    """
    try:
        ds = system.db.execQuery(namedQuery, params)
        row = _firstRow(ds)
        status  = row.get("Status")  if row else 0
        message = row.get("Message") if row else "No result returned from procedure."

        if status == 1:
            BlueRidge.Common.Notify.toast(successTitle, successMsg, "success")
            return row

        logger.warnf("Mutation %s rejected: %s", namedQuery, message)
        BlueRidge.Common.Notify.toast(errorTitle, message, "error")
        return None

    except Exception as e:
        logger.errorf("Mutation %s raised: %s", namedQuery, str(e))
        BlueRidge.Common.Notify.toast(errorTitle, str(e), "error")
        return None


def _firstRow(ds):
    """First row of a Dataset as {columnName: value}. None for empty/null."""
    if ds is None or ds.getRowCount() == 0:
        return None
    headers = list(ds.getColumnNames())
    for row in ds:
        return dict(zip(headers, row))
    return None
