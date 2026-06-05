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
#       convertWrapperObjectToJson(o)  extractQualifiedValues + jsonEncode --
#                                      deep-unwrap then JSON string for NQ
#                                      params / dirty-state comparison
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
#   2026-05-28 - 1.3 - Add summarizeJsonDiff (+ _formatDiffValue helper)
#                      for the AuditLog "Changes" column. Compact one-line
#                      diff summary computed from Audit.ConfigLog
#                      OldValue / NewValue JSON snapshots. Identity-style
#                      keys (Id, RowVersion, AppUserId, UserId) are
#                      excluded so they don't crowd the meaningful fields.
#   2026-05-29 - 1.4 - Add prettyJsonDiff (+ _diffLines / _diffLeaf /
#                      _diffElemKey / _diffEmit / _decodeJsonOrNone helpers)
#                      for the ConfigChangeDetail popup. Unified colorized
#                      OldValue/NewValue diff as HTML <div> lines (green
#                      add / red remove / yellow change), rendered by an
#                      ia.display.markdown component with escapeHtml=false.
#                      Resolved-FK sub-objects collapse to 'Code — Name'.
#                      Slice 2.5 of the audit-readability refactor.
# =============================================================================

import re
import inspect
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
    # NOTE: Perspective's com.inductiveautomation.perspective.common.ImmutableMap
    # / ImmutableList are NOT java.util.Map / Collection and are NOT unwrapped
    # here. For those, JSON round-trip via convertWrapperObjectToJson, or use
    # bracket access v['key'] (v.get('key') AttributeErrors). See
    # feedback_ignition_immutable_map_unwrap.
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


# Identity / audit columns that show up in audit JSON payloads but aren't
# conceptually "changes" — skip them so the diff summary shows real edits.
_DIFF_SKIP_KEYS = ("Id", "RowVersion", "AppUserId", "UserId")


def _formatDiffValue(value, maxLen=30):
    """Render one JSON value for the inline ChangesSummary diff string.

    None becomes the empty-set glyph (visually distinct from the literal
    string 'None'); strings are quoted so spaces read clearly; everything
    else is str()-ified. Values longer than maxLen are truncated with an
    ellipsis so a single huge field can't blow the table column out.
    """
    if value is None:
        return u"∅"
    if isinstance(value, basestring):
        s = value
        if len(s) > maxLen:
            s = s[:maxLen - 1] + u"…"
        return u'"' + s + u'"'
    s = unicode(value)
    if len(s) > maxLen:
        s = s[:maxLen - 1] + u"…"
    return s


def summarizeJsonDiff(oldJson, newJson, maxFields=3):
    """Compact one-line diff summary for the AuditLog "Changes" column.

    Compares the OldValue / NewValue JSON snapshots an Audit.ConfigLog row
    carries and returns a single short string suitable for inline display
    next to the templated Description. The full pretty-printed payload
    still lives in the ConfigChangeDetail popup -- this helper is the
    scannable summary, not the source of truth.

    Output shapes:
        Create (old NULL):       "+ Code, Name, Description"
        Deprecate (new NULL):    "- Code, Name, Description"
        Field added:             "+DeprecatedAt: \"2026-05-28...\""
        Field removed:           "-LegacyFlag"
        Field changed:           "CountryOfOrigin: \"US\" -> \"MX\""
        No meaningful diff:      ""
        Overflow:                "..., +N more"  (cap = maxFields)

    Identity-style keys (_DIFF_SKIP_KEYS) are filtered before counting so
    a row whose only "change" is an Id echo renders as "" (truthful).

    Args:
        oldJson (str | None): Audit.ConfigLog.OldValue JSON string.
        newJson (str | None): Audit.ConfigLog.NewValue JSON string.
        maxFields (int):      Inline-display cap; overflow becomes "+N more".

    Returns:
        str: Compact diff. Empty string when both sides are null,
             unparseable, or structurally identical after skip-key filtering.
    """
    def _decode(s):
        if s is None:
            return None
        try:
            return system.util.jsonDecode(s)
        except Exception:
            return None

    oldObj = _decode(oldJson)
    newObj = _decode(newJson)

    if oldObj is None and newObj is None:
        return ""

    def _meaningfulKeys(obj):
        if not isinstance(obj, dict):
            return []
        return [k for k in obj.keys() if k not in _DIFF_SKIP_KEYS]

    if oldObj is None:
        keys = _meaningfulKeys(newObj)
        if not keys:
            return ""
        shown = keys[:maxFields]
        suffix = u" +%d more" % (len(keys) - maxFields) if len(keys) > maxFields else u""
        return u"+ " + u", ".join(shown) + suffix

    if newObj is None:
        keys = _meaningfulKeys(oldObj)
        if not keys:
            return ""
        shown = keys[:maxFields]
        suffix = u" +%d more" % (len(keys) - maxFields) if len(keys) > maxFields else u""
        return u"- " + u", ".join(shown) + suffix

    if not isinstance(oldObj, dict) or not isinstance(newObj, dict):
        return ""

    # Preserve a stable display order: old keys first, then new-only keys.
    seen = set()
    allKeys = []
    for k in list(oldObj.keys()) + list(newObj.keys()):
        if k in _DIFF_SKIP_KEYS or k in seen:
            continue
        seen.add(k)
        allKeys.append(k)

    diffs = []
    for k in allKeys:
        if k in oldObj and k in newObj:
            if oldObj[k] != newObj[k]:
                diffs.append(("change", k, oldObj[k], newObj[k]))
        elif k in newObj:
            diffs.append(("add", k, None, newObj[k]))
        else:
            diffs.append(("remove", k, oldObj[k], None))

    if not diffs:
        return ""

    shown = diffs[:maxFields]
    parts = []
    for kind, key, oldVal, newVal in shown:
        if kind == "add":
            parts.append(u"+%s: %s" % (key, _formatDiffValue(newVal)))
        elif kind == "remove":
            parts.append(u"-%s" % key)
        else:
            parts.append(u"%s: %s → %s" % (
                key,
                _formatDiffValue(oldVal),
                _formatDiffValue(newVal),
            ))
    suffix = u" +%d more" % (len(diffs) - maxFields) if len(diffs) > maxFields else u""
    return u", ".join(parts) + suffix


# -----------------------------------------------------------------------------
# prettyJsonDiff — unified, colorized OldValue/NewValue diff for the
# ConfigChangeDetail popup. Depends on the resolved-name JSON the audit-
# readability refactor writes (FK sub-objects {Id, Code, Name} /
# {Id, PartNumber, Description}); collapses those to a short "Code — Name"
# label so the diff reads as a narrative, not raw nested JSON.
# Emits HTML <div> lines (one per field / row), colored by change kind:
#   +  add     -> green  (--mpp-state-good-fg)
#   -  remove  -> red    (--mpp-state-bad-fg)
#   ~  change  -> yellow (--mpp-state-warn-fg)
# Rendered by an ia.display.markdown component with escapeHtml=false. If
# HTML rendering is unavailable the leading +/-/~ symbols still convey the
# diff, so it degrades gracefully.
# -----------------------------------------------------------------------------

_DIFF_COLOR_ADD    = u"#4ADE80"   # --mpp-state-good-fg
_DIFF_COLOR_REMOVE = u"#F87171"   # --mpp-state-bad-fg
_DIFF_COLOR_CHANGE = u"#FACC15"   # --mpp-state-warn-fg
_DIFF_LINE_BASE    = (u"font-family:ui-monospace,Menlo,Consolas,monospace;"
                      u"font-size:11px;line-height:1.5;white-space:pre-wrap;")


def _decodeJsonOrNone(s):
    """jsonDecode that returns None for null/empty/unparseable input."""
    if s is None or s == "":
        return None
    try:
        return system.util.jsonDecode(s)
    except Exception:
        return None


def _diffLeaf(value):
    """Compact single-value render for the unified diff. Resolved-FK
    sub-objects ({Id, Code, Name} / {Id, PartNumber, Description}) collapse
    to a short 'Code — Name' label rather than dumping the whole object."""
    if value is None:
        return u"null"
    if isinstance(value, bool):
        return u"true" if value else u"false"
    if isinstance(value, dict):
        code = value.get("Code") or value.get("PartNumber")
        name = value.get("Name") or value.get("Description") or value.get("Initials")
        if code and name:
            return u"%s — %s" % (unicode(code), unicode(name))
        if code:
            return unicode(code)
        if name:
            return unicode(name)
        try:
            return system.util.jsonEncode(value)
        except Exception:
            return unicode(value)
    if isinstance(value, basestring):
        return u'"%s"' % value
    return unicode(value)


def _diffEmit(lines, indent, kind, text):
    """Append one colored HTML <div> diff line. kind in {add, remove,
    change, None}; None renders as plain unchanged context."""
    color = {
        "add":    _DIFF_COLOR_ADD,
        "remove": _DIFF_COLOR_REMOVE,
        "change": _DIFF_COLOR_CHANGE,
    }.get(kind)
    colorStyle = (u"color:%s;" % color) if color else u"color:var(--mpp-text-secondary);"
    padStyle = u"padding-left:%dpx;" % (indent * 14)
    safe = text.replace(u"&", u"&amp;").replace(u"<", u"&lt;").replace(u">", u"&gt;")
    lines.append(u'<div style="%s%s%s">%s</div>' % (
        _DIFF_LINE_BASE, padStyle, colorStyle, safe))


def _diffElemKey(elem):
    """Stable identity for a list element so two arrays can be matched by
    business key (the resolved FK's Code/PartNumber) rather than by index.
    Returns None when no stable unique key is derivable (caller falls back
    to index pairing)."""
    if not isinstance(elem, dict):
        return None
    for v in elem.values():
        if isinstance(v, dict):
            kk = v.get("PartNumber") or v.get("Code")
            if kk:
                return unicode(kk)
    kk = elem.get("Code") or elem.get("PartNumber") or elem.get("Name")
    return unicode(kk) if kk else None


def _diffLines(old, new, lines, indent):
    """Recursively walk two decoded JSON structures, appending colored diff
    lines. Handles dict-vs-dict (per key), list-vs-list (matched by business
    key, else by index), and scalar leaves."""
    # --- dict vs dict (one side may be None -> treated as empty) ---
    if isinstance(old, dict) or isinstance(new, dict):
        oldD = old if isinstance(old, dict) else {}
        newD = new if isinstance(new, dict) else {}
        seen = set()
        keys = []
        for k in list(oldD.keys()) + list(newD.keys()):
            if k in _DIFF_SKIP_KEYS or k in seen:
                continue
            seen.add(k)
            keys.append(k)
        for k in keys:
            inOld = k in oldD
            inNew = k in newD
            if inOld and inNew:
                if oldD[k] == newD[k]:
                    _diffEmit(lines, indent, None, u"%s: %s" % (k, _diffLeaf(newD[k])))
                else:
                    _diffEmit(lines, indent, "change",
                              u"~ %s: %s → %s" % (k, _diffLeaf(oldD[k]), _diffLeaf(newD[k])))
            elif inNew:
                _diffEmit(lines, indent, "add", u"+ %s: %s" % (k, _diffLeaf(newD[k])))
            else:
                _diffEmit(lines, indent, "remove", u"- %s: %s" % (k, _diffLeaf(oldD[k])))
        return

    # --- list vs list ---
    if isinstance(old, list) or isinstance(new, list):
        oldL = old if isinstance(old, list) else []
        newL = new if isinstance(new, list) else []
        oldKeys = [_diffElemKey(e) for e in oldL]
        newKeys = [_diffElemKey(e) for e in newL]
        canMatch = (
            oldL and newL
            and all(k is not None for k in oldKeys) and len(set(oldKeys)) == len(oldKeys)
            and all(k is not None for k in newKeys) and len(set(newKeys)) == len(newKeys)
        )
        if canMatch:
            oldMap = dict(zip(oldKeys, oldL))
            newMap = dict(zip(newKeys, newL))
            for k in newKeys:
                if k in oldMap:
                    if oldMap[k] != newMap[k]:
                        _diffEmit(lines, indent, None, u"%s:" % k)
                        _diffLines(oldMap[k], newMap[k], lines, indent + 1)
                else:
                    _diffEmit(lines, indent, "add", u"+ %s:" % k)
                    _diffLines(None, newMap[k], lines, indent + 1)
            for k in oldKeys:
                if k not in newMap:
                    _diffEmit(lines, indent, "remove", u"- %s:" % k)
                    _diffLines(oldMap[k], None, lines, indent + 1)
        else:
            n = max(len(oldL), len(newL))
            for i in range(n):
                o = oldL[i] if i < len(oldL) else None
                nv = newL[i] if i < len(newL) else None
                if o != nv:
                    _diffEmit(lines, indent, None, u"[%d]:" % i)
                    _diffLines(o, nv, lines, indent + 1)
        return

    # --- scalar leaf ---
    if old == new:
        return
    if old is None:
        _diffEmit(lines, indent, "add", u"+ %s" % _diffLeaf(new))
    elif new is None:
        _diffEmit(lines, indent, "remove", u"- %s" % _diffLeaf(old))
    else:
        _diffEmit(lines, indent, "change",
                  u"~ %s → %s" % (_diffLeaf(old), _diffLeaf(new)))


def prettyJsonDiff(oldJson, newJson):
    """Unified, colorized diff of an Audit.ConfigLog row's OldValue / NewValue
    JSON snapshots, for the ConfigChangeDetail popup. Returns an HTML string
    (a stack of <div> lines) rendered by an ia.display.markdown component with
    escapeHtml=false.

    Reads best against the resolved-name JSON the audit-readability refactor
    writes -- FK sub-objects collapse to 'Code — Name', so a diff line reads
    'Location: DC-401 — Die Cast 401' rather than 'LocationId: 4 → 5'.

    Args:
        oldJson (str | None): Audit.ConfigLog.OldValue JSON string.
        newJson (str | None): Audit.ConfigLog.NewValue JSON string.

    Returns:
        str: HTML diff. Empty string when both sides are null / unparseable;
             a "(no field-level differences)" line when both parse but are
             structurally identical after skip-key filtering.
    """
    oldObj = _decodeJsonOrNone(oldJson)
    newObj = _decodeJsonOrNone(newJson)
    if oldObj is None and newObj is None:
        return u""
    lines = []
    _diffLines(oldObj, newObj, lines, 0)
    if not lines:
        return (u'<div style="%scolor:var(--mpp-text-secondary);">'
                u'(no field-level differences)</div>') % _DIFF_LINE_BASE
    return u"\n".join(lines)


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
