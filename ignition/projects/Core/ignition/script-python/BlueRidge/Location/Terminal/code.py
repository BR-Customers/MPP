"""BlueRidge.Location.Terminal - thin read access to terminal resolution procs.

   Wrappers only; no business logic. Calls route View -> here ->
   BlueRidge.Common.Db -> system.db.*.

   Read surface:
       getByIpAddress(ipAddress)                      -> dict | None
       listAll()                                      -> list[dict]
       findById(terminals, terminalId)                -> dict | None
       findByCode(terminals, code)                    -> dict | None
       listContextCells(terminalLocationId)           -> list[dict]
       getContextCellsForDropdown(terminalLocationId) -> list[{label, value, code, name}]

   Change Log:
       2026-06-11 - Add listContextCells + getContextCellsForDropdown
                    (location/Terminal_ListContextCells NQ access layer)."""

import BlueRidge.Common.Db
import BlueRidge.Common.Util


def getByIpAddress(ipAddress):
    """Resolve the terminal (and its zone / default screen) for the
       caller's IP. Returns a dict or None when no terminal matches."""
    BlueRidge.Common.Util.log("ipAddress=%s" % ipAddress)
    return BlueRidge.Common.Db.execOne(
        "location/Terminal_GetByIpAddress",
        {"ipAddress": ipAddress},
    )


def listAll():
    """List every configured terminal. Returns list[dict].

       Always returns a list (Common.Db.execList never returns None) so the
       runScript-bound view.custom.terminals default ([]) on the Terminal
       Selector is never overwritten with null."""
    BlueRidge.Common.Util.log("listing terminals")
    return BlueRidge.Common.Db.execList("location/Terminal_List")


def findById(terminals, terminalId):
    """Find a terminal row in an already-loaded list by TerminalId.

       The Terminal Selector table's selection payload carries only the
       fields defined as table columns (TerminalId/Code/Name/ZoneName) -
       DefaultScreen, ZoneId and IsFallback are stripped. This re-resolves
       the FULL Terminal_List row from view.custom.terminals without a DB
       round-trip, same as findByCode does for the scan path.

       Returns the matching dict, or None if no terminal matches."""
    rows = BlueRidge.Common.Util.extractQualifiedValues(terminals) or []
    if terminalId is None:
        return None
    for r in rows:
        r = r or {}
        if r.get("TerminalId") == terminalId:
            return r
    return None


def findByCode(terminals, code):
    """Find a terminal row in an already-loaded list by TerminalCode
       (case-insensitive). Used by the Terminal Selector scan handler so
       a scanned barcode resolves to its row without a DB round-trip.

       The `terminals` arg arrives from view.custom (Java-wrapped), so it
       is unwrapped to plain dicts before matching.

       Returns the matching dict, or None if no terminal matches."""
    rows = BlueRidge.Common.Util.extractQualifiedValues(terminals) or []
    target = (code or "").strip().upper()
    if not target:
        return None
    for r in rows:
        r = r or {}
        if (r.get("TerminalCode") or "").strip().upper() == target:
            return r
    return None


def listForSelector(searchText=None):
    """Terminal Selector table rows: Terminal_List filtered case-insensitively
       on TerminalCode / TerminalName / ZoneName (Jacques 2026-07-06 search bar).

       Item-Master-style search: the runScript binding passes only the SCALAR
       search text and the rows are fetched HERE as plain execList dicts, so
       no Perspective container ever crosses the runScript boundary. (The
       previous filterForSelector took {view.custom.terminals} as an arg --
       re-evaluations receive it as ImmutableList, which neither
       extractQualifiedValues nor the JSON round-trip survive; see
       feedback_ignition_immutable_map_unwrap.) Always returns a list."""
    rows = listAll() or []
    s = ("%s" % (BlueRidge.Common.Util.extractQualifiedValues(searchText) or "")).strip().upper()
    if not s:
        return rows
    out = []
    for r in rows:
        r = r or {}
        hay = ("%s %s %s" % (r.get("TerminalCode") or "", r.get("TerminalName") or "", r.get("ZoneName") or "")).upper()
        if s in hay:
            out.append(r)
    return out


def listContextCells(terminalLocationId):
    """Eligible location-context rows for a shared-flavor view at the given
       terminal: active descendant EQUIPMENT cells of the terminal's parent
       (Terminal/Printer kinds excluded by the proc). Returns list[dict]
       (LocationId, Code, Name, Kind); always a list, empty when the
       terminal is unknown or its parent has no equipment cells."""
    BlueRidge.Common.Util.log("terminalLocationId=%s" % terminalLocationId)
    if terminalLocationId is None:
        return []
    return BlueRidge.Common.Db.execList(
        "location/Terminal_ListContextCells",
        {"terminalId": terminalLocationId},
    )


def getContextCellsForDropdown(terminalLocationId, kindFilter=None):
    """listContextCells shaped for ia.input.dropdown + scan matching:
       [{label: '<Code> - <Name>', value: LocationId, code, name}].
       Always returns a list (never None) so the runScript-bound
       view.custom.cells default ([]) is never overwritten with null.

       kindFilter (optional): when set (e.g. 'Trim Press'), only cells whose Kind
       matches are returned. The Trim terminal is area/fallback-scoped, so its raw
       context spans the whole facility on the FALLBACK terminal -- the filter keeps
       a single-process screen (Trim) showing only its own cell type."""
    rows = listContextCells(terminalLocationId) or []
    out = []
    for r in rows:
        if kindFilter and (r.get("Kind") or "") != kindFilter:
            continue
        code = r.get("Code") or ""
        name = r.get("Name") or ""
        out.append({
            "label": ("%s - %s" % (code, name)).strip(" -"),
            "value": r.get("LocationId"),
            "code":  code,
            "name":  name,
        })
    return out


def getPrinter(terminalLocationId):
    """Arc 2 Phase 4. Resolve the terminal's child Printer Location + its
       Endpoint/Model attribute values for the onStartup session resolution +
       the LTT dispatch path. Returns {locationId, code, endpoint, model} or {}
       (empty when the terminal has no Printer child -- the fail-fast case)."""
    tid = BlueRidge.Common.Util.extractQualifiedValues(terminalLocationId)
    BlueRidge.Common.Util.log("terminalLocationId=%s" % tid)
    if tid is None:
        return {}
    row = BlueRidge.Common.Db.execOne("location/Terminal_GetPrinter", {"terminalLocationId": tid})
    if not row:
        return {}
    return {
        "locationId": row.get("LocationId"),
        "code":       row.get("Code") or "",
        "endpoint":   row.get("Endpoint") or "",
        "model":      row.get("Model") or "",
    }


def getClosureContext(terminalLocationId):
    """Assembly-out closure context for a terminal:
       {CurrentClosureMethod, VisionAppUrl, ClosureCapabilities}. The capability
       set is derived server-side from the terminal's bound PLC devices. Returns
       {} when unresolved (fallback terminal / no id)."""
    tid = BlueRidge.Common.Util.extractQualifiedValues(terminalLocationId)
    if tid is None:
        return {}
    # Defensive: onStartup runs on every session connect. If the closure procs
    # are not yet deployed to this gateway's DB, degrade to empty rather than
    # break session establishment.
    try:
        row = BlueRidge.Common.Db.execOne(
            "location/Terminal_GetClosureContext", {"terminalLocationId": tid})
        return row if row is not None else {}
    except Exception as e:
        BlueRidge.Common.Util.log("getClosureContext failed: %s" % str(e))
        return {}


def applyToSession(session, terminal):
    """Single source of truth for binding a terminal's FULL context onto a
       Perspective session. `terminal` is the 7-key session-terminal dict
       (terminalLocationId, terminalCode, terminalName, zoneLocationId,
       zoneName, defaultScreen, isFallback).

       Sets, from the one terminalLocationId, everything a screen may read:
         session.custom.terminal            (+ derived visionAppUrl)
         session.custom.printer             (getPrinter)
         session.custom.plcDevices          (TerminalPlcDevice.getByTerminal)
         session.custom.closureMethod       (getClosureContext)
         session.custom.closureCapabilities (getClosureContext)
         session.custom.cell -> CLEARED     (a cell picked at a prior terminal
                                             must not leak into the new terminal)

       Called by onStartup (IP-resolved), NavigationTree launch, and
       TerminalSelector.selectTerminal so those three entry points can never
       drift (previously each set only the terminal dict, leaving printer / PLC
       / closure / vision stale after a navigate)."""
    import BlueRidge.Location.TerminalPlcDevice as _tpd
    t = BlueRidge.Common.Util.extractQualifiedValues(terminal) or {}
    tid = t.get("terminalLocationId")
    term = {
        "terminalLocationId": tid,
        "terminalCode":       t.get("terminalCode") or "",
        "terminalName":       t.get("terminalName") or "",
        "zoneLocationId":     t.get("zoneLocationId"),
        "zoneName":           t.get("zoneName") or "",
        "defaultScreen":      t.get("defaultScreen") or "",
        "isFallback":         bool(t.get("isFallback")),
        "visionAppUrl":       "",
    }
    # Always drop any prior cell selection when the terminal changes.
    session.custom.cell = {"locationId": None, "code": "", "name": ""}
    if tid is None:
        session.custom.terminal = term
        session.custom.printer = {"locationId": None, "code": "", "endpoint": "", "model": ""}
        session.custom.plcDevices = []
        # ByCount is the universal device-free baseline (mirrors the proc default);
        # keep the count-close UI usable on a fallback / unregistered terminal.
        session.custom.closureMethod = "ByCount"
        session.custom.closureCapabilities = ["ByCount"]
        return
    prn = getPrinter(tid) or {}
    session.custom.printer = {
        "locationId": prn.get("locationId"),
        "code":       prn.get("code") or "",
        "endpoint":   prn.get("endpoint") or "",
        "model":      prn.get("model") or "",
    }
    session.custom.plcDevices = _tpd.getByTerminal(tid) or []
    cc = getClosureContext(tid) or {}
    session.custom.closureMethod = cc.get("CurrentClosureMethod") or ""
    caps = cc.get("ClosureCapabilities") or "ByCount"
    session.custom.closureCapabilities = [c for c in caps.split(",") if c]
    term["visionAppUrl"] = cc.get("VisionAppUrl") or ""
    session.custom.terminal = term
