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
#       getIconLibrary(libraryName)    Browse a custom Perspective icon
#                                      library SVG sprite at runtime and
#                                      return [{path, name}] for each
#                                      <svg id="..."> in the sprite.
#                                      Powers the IconPicker popup.
#       buildIconPickerInstances(...)  Convert a getIconLibrary list into
#                                      the flex-repeater instances shape
#                                      for the IconPicker popup, with
#                                      'No icon' prepended + isSelected
#                                      computed per row.
#       buildIconPickerInstancesFromLibrary(...)
#                                      Convenience wrapper that fuses
#                                      getIconLibrary + buildIconPickerInstances
#                                      into one call -- avoids the chained-
#                                      binding latch we hit on the flex-
#                                      repeater's props.instances.
#       prettyJson(jsonString)         Format a JSON string with 2-space
#                                      indentation for audit detail popups.
#                                      Returns input unchanged on parse
#                                      failure; returns "" for None.
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
#   2026-05-18 - 1.1 - Add getIconLibrary + _humanizeIconName +
#                      _resolveIconLibraryPath. Powers the new IconPicker
#                      popup; reads the gateway's custom-icon SVG sprite
#                      directly so the picker always reflects what
#                      Designer can actually render. No CSV / hardcoded
#                      list to drift out of sync.
#   2026-05-19 - 1.2 - Add prettyJson. Formats JSON strings with 2-space
#                      indentation for the FailureDetail audit popup;
#                      gracefully handles None + malformed input.
# =============================================================================

import re
import inspect
from com.inductiveautomation.ignition.common import TypeUtilities
from com.inductiveautomation.ignition.common.model.values import QualifiedValue
from java.util import Map as JavaMap
from java.util import Collection as JavaCollection


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
    nested collections. Handles BOTH Python container types (dict, list,
    tuple) AND Java container types (java.util.Map, java.util.Collection)
    that arrive verbatim from Perspective's bidirectional writebacks --
    Java HashMaps look dict-like in Jython but `isinstance(javaMap, dict)`
    is False, so a naive Python-only walk skips them.

    A QualifiedValue may itself wrap another container of QualifiedValues
    (the Tree component does this -- node.data is wrapped, and each field
    inside is wrapped again). We recurse on the unwrapped payload so the
    final result has zero QV instances anywhere in the structure.

    Args:
        data: Any value, possibly a QualifiedValue, Python container, or
              Java container with QVs at any depth.

    Returns:
        A Python structure with every QualifiedValue replaced by its
        .getValue() result, recursively. Java containers are converted
        to Python equivalents (Map -> dict, Collection -> list).
    """
    if isinstance(data, QualifiedValue):
        return extractQualifiedValues(data.getValue())
    if isinstance(data, JavaMap):
        return {k: extractQualifiedValues(data.get(k)) for k in data.keySet()}
    if isinstance(data, dict):
        return {k: extractQualifiedValues(v) for k, v in data.items()}
    if isinstance(data, list):
        return [extractQualifiedValues(x) for x in data]
    if isinstance(data, tuple):
        return tuple(extractQualifiedValues(x) for x in data)
    if isinstance(data, JavaCollection):
        return [extractQualifiedValues(x) for x in data]
    return data


def _humanizeIconName(rawId):
    """die_cast -> 'Die Cast'.  qr_code_scanner -> 'Qr Code Scanner'.
       Used to build the display label that sits under each icon tile
       in the IconPicker grid."""
    if not rawId:
        return ""
    return " ".join(part.capitalize() for part in rawId.replace("-", "_").split("_"))


def _resolveIconLibraryPath(libraryName):
    """Resolve the absolute filesystem path to a Perspective custom-icon
       library's SVG sprite.

       Two-tier resolution:
         1. Ignition's documented gateway data directory via
            IgnitionGateway.get().getSystemManager().getDataDir(). This is
            the canonical API used by Ignition's own Modules SDK and is
            stable across installs.
         2. JVM 'user.dir' + '/data' fallback. The Ignition gateway
            service typically launches with its install root as the
            working directory, so user.dir/data usually matches the
            data directory. Used only if (1) is unavailable.

       Returns None if neither resolves -- caller logs + returns []."""
    rel = ("config/resources/core/com.inductiveautomation.perspective/"
           "icons/%s/%s.svg") % (libraryName, libraryName)

    try:
        from com.inductiveautomation.ignition.gateway import IgnitionGateway
        gw = IgnitionGateway.get()
        if gw is not None:
            dataDir = gw.getSystemManager().getDataDir()
            if dataDir is not None:
                return dataDir.getAbsolutePath() + "/" + rel
    except Exception:
        pass

    try:
        from java.lang import System as JSystem
        userDir = JSystem.getProperty("user.dir")
        if userDir:
            return userDir + "/data/" + rel
    except Exception:
        pass

    return None


def getIconLibrary(libraryName="mpp"):
    """Browse a Perspective custom-icon library SVG sprite at runtime
       and return its contents as picker-ready entries.

       Reads the gateway's deployed sprite (NOT the git-tracked copy
       under ignition/icons/) so the returned list reflects what
       Designer can actually render right now. Re-extracts every
       <svg id="..."> id from the sprite; ids are sorted alphabetically.

       Args:
           libraryName (str): Folder + sprite-file basename. Default
                              'mpp' resolves to .../icons/mpp/mpp.svg.

       Returns:
           list[dict]: [{path: '<library>/<id>', name: '<humanized id>'},
                        ...]. Empty list when the sprite cannot be read
           or contains no ids -- log line written so the failure is
           postmortem-traceable. The IconPicker popup tolerates empty
           lists by rendering only the 'No icon' tile.
    """
    log("library=%s" % libraryName)

    svgPath = _resolveIconLibraryPath(libraryName)
    if svgPath is None:
        log("FAILED: could not resolve sprite path for library=%s" % libraryName)
        return []

    try:
        svg = system.file.readFileAsString(svgPath)
    except Exception as e:
        log("FAILED: read %s -> %s" % (svgPath, str(e)))
        return []

    if not svg:
        log("FAILED: empty sprite at %s" % svgPath)
        return []

    # Every inner <svg id="..."> in the sprite is one renderable icon.
    # The outer wrapper <svg> normally has no id; if it does, we still
    # de-dupe + filter later. Robust to attribute order via \b id=.
    rawIds = re.findall(r'<svg\b[^>]*\bid="([^"]+)"', svg)
    uniqueIds = sorted(set(rawIds))
    log("found %d icon(s)" % len(uniqueIds))

    return [
        {"path": libraryName + "/" + iconId, "name": _humanizeIconName(iconId)}
        for iconId in uniqueIds
    ]


def buildIconPickerInstances(icons, selected, replyMessage, popupId):
    """Convert a getIconLibrary list into the flex-repeater instances
       shape that IconPickerTile expects.

       Prepends a synthetic 'No icon' tile (iconPath='') so operators
       can clear a previously-set icon. Per-row isSelected is computed
       against the picker's current selection.

       Designed to be called via runScript from the IconPicker view's
       flex-repeater props.instances expression, so view-side params
       can be passed in directly:

           runScript("BlueRidge.Common.Util.buildIconPickerInstances",
                     0,
                     {view.custom.icons},
                     {view.params.selected},
                     {view.params.replyMessage},
                     {view.params.popupId})

       Args:
           icons (list[dict]):    Output of getIconLibrary, or [] / None.
           selected (str | None): Picker's current selection. Empty string
                                  / None matches the 'No icon' tile.
           replyMessage (str):    Page-scoped message type the tile fires
                                  on click. Forwarded into each tile.
           popupId (str):         Popup id the tile closes after firing.
                                  Forwarded into each tile.

       Returns:
           list[dict]: One dict per tile, shaped for IconPickerTile params.
    """
    selectedPath = selected or ""
    iconsLen = len(icons) if icons is not None else "None"
    log("icons(type=%s len=%s) selected=%s" % (
        type(icons).__name__ if icons is not None else "None",
        iconsLen, selectedPath))
    result = [{
        "iconPath":     "",
        "iconName":     "No icon",
        "isSelected":   selectedPath == "",
        "replyMessage": replyMessage,
        "popupId":      popupId,
    }]
    for icon in (icons or []):
        if not hasattr(icon, "get"):
            continue
        path = icon.get("path") or ""
        result.append({
            "iconPath":     path,
            "iconName":     icon.get("name") or "",
            "isSelected":   path == selectedPath,
            "replyMessage": replyMessage,
            "popupId":      popupId,
        })
    log("returning %d tile(s)" % len(result))
    return result


def buildIconPickerInstancesFromLibrary(library, selected, replyMessage, popupId):
    """Single-shot wrapper that fuses getIconLibrary + buildIconPickerInstances
       so the IconPicker flex-repeater can bind props.instances with one
       runScript call -- no chained-binding latch.

       The IconPicker popup originally bound:
           view.custom.icons          <- runScript(getIconLibrary, 0, library)
           flex-repeater.instances    <- runScript(buildIconPickerInstances,
                                          0, view.custom.icons, ...)
       That chain misbehaved in practice -- the second binding fired
       before view.custom.icons had populated and never re-fired when it
       updated, leaving the repeater stuck on the empty-input result
       (just the 'No icon' tile). Collapsing into one runScript with
       library as a direct input sidesteps the chain entirely.

       Args, Returns: same as buildIconPickerInstances, except icons is
       sourced internally from getIconLibrary(library).
    """
    log("library=%s selected=%s" % (library, selected))
    return buildIconPickerInstances(
        getIconLibrary(library),
        selected,
        replyMessage,
        popupId,
    )


def prettyJson(jsonString):
    """
    Pretty-print a JSON string with 2-space indentation. Used by audit
    detail popups to render the AttemptedParameters / Old / New JSON
    snapshots in a readable form. On parse failure (malformed JSON, or
    NULL) returns the input unchanged -- the popup shows the raw text
    rather than crashing.

    Args:
        jsonString (str): JSON string to format, or None.

    Returns:
        str: pretty-printed JSON, or the input string if it can't be
             parsed, or empty string if input was None.
    """
    if jsonString is None:
        return ""
    try:
        parsed = system.util.jsonDecode(jsonString)
        return system.util.jsonEncode(parsed, 2)
    except Exception:
        return jsonString


def convertWrapperObjectToJson(obj):
    """
    Deep-unwrap a wrapped container (java.util.HashMap of BasicQualifiedValue,
    QualifiedValue, JavaCollection, nested combinations) into a Python-native
    structure, then JSON-encode it. Returns the JSON string.

    Used by the dirty-state binding expressions on the per-section ownership
    embeds (Identity / ContainerConfig / Routes / BOMs) where editDraft and
    selected come into the runScript wrapped as BasicQualifiedValue leaves
    inside a HashMap. Comparing those raw dicts via != is unstable (the QV
    timestamp/quality differs across reads even when the underlying value is
    identical). Routing both sides through this helper -- which strips the
    QV wrappers via extractQualifiedValues, then jsonEncodes -- yields
    type-stable, ordering-stable strings that compare correctly.

    Args:
        obj: Any wrapped container, plain Python dict/list, or primitive.

    Returns:
        str: JSON-encoded string. Compare two of these for type-stable
             dirty detection. Returns "null" for None.
    """
    return system.util.jsonEncode(extractQualifiedValues(obj))
