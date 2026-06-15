# =============================================================================
# Project Library:  BlueRidge.Common.Ui
#
# Author:           Blue Ridge Automation
# Created:          2026-05-14
# Version:          1.0
#
# Description:
#   Thin UI-feedback helpers shared by every mutation call site.
#
#   notifyResult(result, successTitle, successMsg=None, errorTitle=None)
#       Routes a Common.Db.execMutation result to the toast system.
#       On Status=1 (success): success toast.
#       On Status=0 (business-rule failure): error toast carrying the
#                                            proc's Message.
#
#   The mutation result dict shape (from Common.Db.execMutation) is:
#       {"Status": 1|0, "Message": <str>, "NewId": <long>|None}
#   so this helper is purely a router -- the DB layer does the work,
#   this layer surfaces the outcome to the operator.
#
# Why this exists separately from Common.Db:
#   Database concerns and UI concerns are orthogonal. A timer / gateway
#   call may want to run a mutation WITHOUT firing a toast. A view event
#   wants the toast. Keeping the two layers separate lets callers compose
#   them as needed.
#
#   Underlying toast surface is BlueRidge.Common.Notify (popup-per-toast,
#   top-right, FIFO max 5).
#
# Layer:
#   Common helper -- routes to Common.Notify.
#
# Change Log:
#   2026-05-14 - 1.0 - Initial version.
# =============================================================================


def notifyResult(result, successTitle, successMsg=None, errorTitle=None):
    """
    Surface a mutation result to the operator via a single toast.

    Args:
        result (dict): Return value from Common.Db.execMutation. Required
                       keys: Status (BIT 1/0), Message (str). NewId is
                       inspected by the caller, not here.
        successTitle (str): Toast headline on Status=1. Required.
        successMsg (str|None): Toast body on Status=1. Defaults to empty.
        errorTitle (str|None): Toast headline on Status=0. Defaults to
                               "Action failed". The proc's Message
                               populates the body.

    Returns:
        None. Toasts dispatch via session message; caller continues
        synchronously.
    """
    status = result.get("Status") if result else 0
    if status:
        BlueRidge.Common.Notify.toast(
            successTitle,
            successMsg or "",
            "success",
        )
        return

    message = (result.get("Message") if result else None) or "No additional detail."
    BlueRidge.Common.Notify.toast(
        errorTitle or "Action failed",
        message,
        "error",
    )
