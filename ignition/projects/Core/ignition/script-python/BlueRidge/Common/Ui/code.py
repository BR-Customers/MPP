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
#   2026-08-20 - 1.1 - Add crtNotice (ONE part-scoped Controlled Run Tag
#                      creation notice per SUBMIT, design D9) and
#                      notifyResultCrtAware (drop-in for notifyResult that
#                      routes a CRT refusal to a modal popup instead of a
#                      toast). Both drive
#                      BlueRidge/Components/Popups/CrtNotice.
#   2026-08-20 - 1.2 - CrtNotice popup moved MPP -> Core so MPP_Config
#                      callers resolve it too (the path constant is
#                      unchanged). Refusal detection widened beyond the
#                      "marked CRT" phrase to also catch the spelled-out
#                      "Controlled Run Tag" wording Lots.Container_Ship
#                      refuses with.
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


# =============================================================================
# Controlled Run Tag (part-scoped CRT) - operator-facing popups
#
#   crtNotice(...)            ONE creation notice per SUBMIT (design D9).
#   notifyResultCrtAware(...) blocking notice when a proc refused a CRT LOT.
#
# Both drive the same reusable popup, BlueRidge/Components/Popups/CrtNotice,
# under a single popup id -- a second open replaces the first rather than
# stacking dialogs on top of each other.
# =============================================================================

_CRT_POPUP_ID = "mpp-crt-notice"
# The view lives in Core (alongside ConfirmDestructive and the other shared
# popups), NOT in MPP -- Core is inherited by both MPP and MPP_Config, and
# notifyResultCrtAware returns BEFORE reaching notifyResult when it fires, so
# a path that failed to resolve for a Config-Tool caller would leave the
# operator with no popup AND no toast.
_CRT_POPUP_PATH = "BlueRidge/Components/Popups/CrtNotice"

# The phrases a CRT rejection message carries. "marked CRT" covers the six
# guarded procs (Lot_MoveTo / Lot_MoveToValidated / Lot_Split / Lot_Merge /
# MachiningIn_RecordPick / MachiningOut_Mint); "Controlled Run Tag" covers the
# spelled-out wording (Lots.Container_Ship refuses with "Container is pending
# Controlled Run Tag validation (cannot ship)."), so swapping this helper in
# at a site that uses that wording does not silently downgrade to a toast.
# Matching a phrase rather than the bare token "CRT" keeps a part number or
# free-text reason containing those three letters from being misread.
_CRT_REFUSAL_MARKERS = ("marked CRT", "Controlled Run Tag")


def _isCrtRefusal(result):
    """True when result is a business-rule failure whose Message names CRT."""
    if not result or result.get("Status"):
        return False
    message = result.get("Message") or ""
    for marker in _CRT_REFUSAL_MARKERS:
        if marker in message:
            return True
    return False


def crtNotice(lotNames, mintedCount=None):
    """
    Tell the operator that a mint just produced CRT LOTs.

    ONE popup per SUBMIT, listing every CRT LOT created by that press
    (design D9) -- never one dialog per LOT. A bulk basket open at Die Cast
    mints one LOT per cavity in a single action, and a dialog each would
    train operators to dismiss dialogs reflexively, which defeats the point.
    Degrades to the singular wording at Trim / Machining / Assembly, where a
    submit mints exactly one LOT.

    Args:
        lotNames (list[str]|None): names of the LOTs that came back CRT.
                                   Empty / None is the normal case and is a
                                   no-op -- callers may call unconditionally.
        mintedCount (int|None): how many LOTs the submit minted in total, so
                                the body can read "3 of 5". Defaults to the
                                number of CRT LOTs.

    Returns:
        bool: True when a popup was opened.
    """
    names = [n for n in (lotNames or []) if n]
    if not names:
        return False
    total = mintedCount or len(names)
    if total > 1:
        body = ("%d of %d LOTs just created are marked CRT. They cannot advance "
                "until Quality clears them." % (len(names), total))
    else:
        body = ("The LOT just created is marked CRT. It cannot advance until "
                "Quality clears it.")
    system.perspective.openPopup(
        _CRT_POPUP_ID, _CRT_POPUP_PATH,
        params={"title": "Marked CRT", "body": body,
                "lotNames": ", ".join(names), "popupId": _CRT_POPUP_ID},
        modal=True, showCloseIcon=False)
    return True


def notifyResultCrtAware(result, successTitle, successMsg=None, errorTitle=None):
    """
    notifyResult(), except that a CRT refusal gets a modal popup instead of a
    toast -- a refusal the operator has to acknowledge cannot be missed the
    way a toast can.

    The proc's own Message is what is shown: it already names the LOT and the
    reason. The PROC remains authoritative -- this is presentation only, and
    the block still holds if a screen forgets to call this.

    Args / Returns:
        Same arguments as notifyResult. Returns True when the CRT popup was
        opened (and no toast was raised), False when the result was routed to
        notifyResult as usual.
    """
    message = (result.get("Message") if result else None) or ""
    if _isCrtRefusal(result):
        system.perspective.openPopup(
            _CRT_POPUP_ID, _CRT_POPUP_PATH,
            params={"title": "LOT is marked CRT", "body": message,
                    "lotNames": "", "popupId": _CRT_POPUP_ID},
            modal=True, showCloseIcon=False)
        return True
    notifyResult(result, successTitle, successMsg, errorTitle)
    return False
