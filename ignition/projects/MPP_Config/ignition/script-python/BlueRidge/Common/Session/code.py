# =============================================================================
# Project Library:  BlueRidge.Common.Session
#
# Author:           Blue Ridge Automation
# Created:          2026-05-13
# Version:          1.0
#
# Description:
#   Session-derived attribution accessors. Today returns a hardcoded dev
#   AppUser.Id so write-actions can attribute audit rows without blocking
#   on the security build-out. Once initials-presence + AD elevation are
#   wired in, the accessor resolves from session context so call sites
#   do not have to change.
#
# Public surface:
#   getCurrentUserId()  -> long (AppUser.Id for the active session)
#
# Change Log:
#   2026-05-13 - 1.0 - Initial dev placeholder (returns _DEV_USER_ID)
# =============================================================================

# Dev placeholder. Replace the body of getCurrentUserId() once initials-presence
# and AD elevation are wired in; do NOT change the public surface.
_DEV_USER_ID = 2


def getCurrentUserId():
    """
    AppUser.Id attribution for the active session.

    Today: returns a hardcoded dev value (AppUser.Id = 2). Pass the
    returned id straight into any proc's @AppUserId parameter.

    Once the security work lands, this accessor will resolve from session
    context (initials -> AppUser.Id lookup with AD-elevation override)
    without requiring any caller change.

    Returns:
        long: AppUser.Id of the current user.
    """
    return _DEV_USER_ID
