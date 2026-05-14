# =============================================================================
# Project Library:  BlueRidge.Common.Util
#
# Author:           Blue Ridge Automation
# Created:          2026-05-14
# Version:          1.0
#
# Description:
#   Cross-cutting utility helpers shared by every entity script:
#       log(msg)                       function-trace logger with auto-fill
#                                      of calling module + function via
#                                      inspect.currentframe().f_back
#       _currentAppUserId()            session.custom.appUserId resolver
#                                      with dev fallback (returns 2 until
#                                      the initials/AD login wiring lands)
#       extractQualifiedValues(data)   unwrap QualifiedValue through nested
#                                      lists / tuples / dicts (binding
#                                      handoffs sometimes arrive wrapped)
#       convertWrapperObjectToJson(o)  TypeUtilities.pyToGson — PyDictionary
#                                      / PyList -> Gson-safe JSON for NQ
#                                      parameter binding
#
#   These are the only sanctioned source for each concern. Entity scripts
#   call them directly; no per-module log() wrappers, no per-script
#   appUserId lookup, no per-binding unwrap helpers.
#
# Layer:
#   Common helper — may call system.* and inspect Jython internals.
#   Other layers never duplicate this functionality.
#
# Change Log:
#   2026-05-14 - 1.0 - Initial version. Consolidates conventions from
#                      MPP_MES_CONFIG_TOOL_FRONTEND_CONVENTIONS.md +
#                      ignition-context-pack/03_script_python.md.
# =============================================================================

import inspect
from com.inductiveautomation.ignition.common import TypeUtilities
from com.inductiveautomation.ignition.common.model.values import QualifiedValue


# Dev fallback for _currentAppUserId. Swap-in target is session.custom.appUserId
# set at login by the initials/AD elevation flow. Until that lands, returning a
# known-valid AppUser.Id keeps mutation audit attribution working in dev.
_DEV_APP_USER_ID = 2


def log(msg):
    """
    Function-trace logger. Auto-fills the calling module's dotted name and
    the calling function's name into the gateway log line, so call sites
    do not need a per-module logger wrapper.

    Resulting log line shape:
        <module.path>: <funcName>() <msg>

    Args:
        msg (str): The message to log. Format yourself before calling --
                   the helper does no interpolation.
    """
    frame  = inspect.currentframe().f_back
    module = frame.f_globals.get("__name__", "unknown")
    func   = frame.f_code.co_name
    system.util.getLogger(module).info("%s() %s" % (func, msg))


def _currentAppUserId():
    """
    Resolves the calling session's AppUser.Id for audit attribution on
    mutations. Reads session.custom.appUserId (set at login). Falls back
    to a dev constant when the session has no appUserId set so dev work
    can proceed without the login flow wired.

    Pass the returned value to any mutation proc as @AppUserId. Callers
    should NOT hold appUserId values across function boundaries -- this
    helper is the only sanctioned source.

    Returns:
        long: AppUser.Id. Dev fallback while initials/AD wiring is pending.
    """
    try:
        info = system.perspective.getSessionInfo()
        appUserId = info["custom"].get("appUserId") if info else None
        if appUserId is not None:
            return appUserId
    except Exception:
        # getSessionInfo() unavailable outside a session-scoped call
        # (e.g., timer scripts, startup hooks). Fall through to dev value.
        pass
    return _DEV_APP_USER_ID


def extractQualifiedValues(data):
    """
    Recursively unwrap QualifiedValue (from tag / property bindings) through
    nested lists, tuples, and dicts. Use whenever a binding hands script-side
    code a value that might be wrapped -- bidirectional-bound props in
    particular sometimes arrive as QualifiedValue rather than the bare value.

    Args:
        data: Any value, possibly a QualifiedValue or a structure containing
              QualifiedValues at any depth.

    Returns:
        Same structure as input, with every QualifiedValue replaced by its
        .getValue() result.
    """
    if isinstance(data, QualifiedValue):
        return data.getValue()
    if isinstance(data, list):
        return [extractQualifiedValues(x) for x in data]
    if isinstance(data, tuple):
        return tuple(extractQualifiedValues(x) for x in data)
    if isinstance(data, dict):
        return {k: extractQualifiedValues(v) for k, v in data.items()}
    return data


def convertWrapperObjectToJson(obj):
    """
    Convert a Jython PyDictionary / PyList wrapper object into a Gson-safe
    JSON value before passing as a named-query parameter. Required when a
    view hands a self.custom.* dict to a script that forwards it to an NQ
    that expects NVARCHAR(MAX) JSON.

    Args:
        obj: Any PyDictionary, PyList, or nested combination.

    Returns:
        The Gson-safe equivalent ready to be jsonEncoded.
    """
    return TypeUtilities.pyToGson(obj)
