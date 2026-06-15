# =============================================================================
# Project Library:  BlueRidge.Common.Session
#
# Author:           Blue Ridge Automation
# Created:          2026-05-13
# Version:          1.1
#
# Description:
#   Session-derived attribution accessors. Today this module is a thin
#   re-export of BlueRidge.Common.Util._currentAppUserId so existing call
#   sites that imported BlueRidge.Common.Session keep working while new
#   code calls Util directly.
#
#   Once initials-presence + AD elevation are wired in, the underlying
#   Util._currentAppUserId resolves from session.custom.appUserId and
#   this shim still returns the correct value -- no caller changes.
#
# Public surface:
#   getCurrentUserId()  -> long (AppUser.Id for the active session)
#
# Change Log:
#   2026-05-13 - 1.0 - Initial dev placeholder (returns hardcoded id)
#   2026-05-14 - 1.1 - Delegates to BlueRidge.Common.Util._currentAppUserId
#                      so the dev fallback + future session resolution
#                      live in one place.
# =============================================================================


def getCurrentUserId():
    """
    AppUser.Id attribution for the active session.

    Thin shim around BlueRidge.Common.Util._currentAppUserId. New code
    should call Util directly; this remains so existing call sites keep
    working.

    Returns:
        long: AppUser.Id of the current user. Dev fallback while
              initials/AD wiring is pending.
    """
    return BlueRidge.Common.Util._currentAppUserId()
