# Gateway logging index — every `Util.log()` call site

**Purpose:** you're sick of gateway console noise from dev/test-era logging. This indexes every
resource that fires an Ignition gateway log line (NOT `Audit.ConfigLog`/`Audit_Log*` — that's the
application's own SQL audit trail, out of scope here), so the noisy ones can be culled or
downgraded in one pass.

## How logging works in this codebase (read this first)

There is **no per-module logger wrapper**. Every gateway log line in the whole app goes through
one shared helper:

```python
# ignition/projects/Core/ignition/script-python/BlueRidge/Common/Util/code.py
def log(msg, level="info"):
    frame  = inspect.currentframe().f_back
    module = frame.f_globals.get("__name__", "unknown")
    func   = frame.f_code.co_name
    getattr(system.util.getLogger(module), level)("%s() %s" % (func, msg))
```

It auto-fills the **calling module's dotted name** as the gateway logger — that's why your
screenshot shows loggers named `AimPoolConfig`, `PlcWatcher`, `Sim`, `Container`, `Terminal`,
`TerminalPlcDevice`: those are just the leaf names of `BlueRidge.Lots.AimPoolConfig`,
`BlueRidge.Workorder.PlcWatcher`, `BlueRidge.Sim`, etc. `level` defaults to `"info"` whenever a
call site omits the kwarg — which is most of them, including plain read/list/get functions that
have no business being at INFO.

Two consequences for cleanup:
1. **"Which resource logs" = every call site of `BlueRidge.Common.Util.log(...)`.** There are no
   other logging entry points anywhere in `ignition/projects/{Core,MPP,MPP_Config,MPP_MES}` — MPP's
   own timer/tag-change/message-handler resources never call `log()` directly, they call into Core
   business-logic modules which log internally.
2. **A subset of the codebase already does this right**: `Common/Db/code.py` (the highest-traffic
   function in the app — every NQ read/write routes through it) and `Oee/Shift/code.py`'s
   polling/resolver functions are already at `level="debug"`, so they're silent at the gateway's
   default INFO threshold. That's the target pattern for everything flagged "noise" below.

Scope note: `ignition/projects/Refrence project/Spinner/...` is a separate, unrelated reference
project (not part of the MPP deliverable) — excluded from this index.

## Total: ~340 call sites across 69 files, all under `ignition/projects/Core/ignition/script-python/BlueRidge/`

| Domain | Files | Call sites |
|---|---|---|
| Location / Common / Audit | 19 | ~60 |
| Lots | 15 | 91 |
| Workorder + Sim | 14 | 37 |
| Parts / Quality / Oee | 22 | 179 |

## Top offenders — directly matching your screenshot

These are the loudest, most content-free, highest-frequency lines in the whole app. Fix these
first.

| Logger | File : Line | Fires on | Message |
|---|---|---|---|
| **Sim** | `Sim/code.py:76,93,129,142` | Every simulated PLC read/write | `"running"`, `"device=%s member=%s value=%s"`, etc. | 
| **AimPoolConfig** | `Lots/AimPoolConfig/code.py:13` | Every `topupTick`/`alarmTick` gateway-timer cycle (your screenshot: fires every ~1 min, message is literally `"get"`) | `"get"` |
| **PlcWatcher** | `Workorder/PlcWatcher/code.py:192` | **Every rising edge on every PLC device across the plant** — pure routing trace | `"edge %s on %s -> %s (terminal %s)"` |
| **TerminalPlcDevice** | `Location/TerminalPlcDevice/code.py:103` | Reverse lookup fired on every PLC-watcher trigger (i.e. same frequency as PlcWatcher above) | `"udtInstancePath=%s"` |
| **Terminal** | `Location/Terminal/code.py:39` | `listForSelector` — Terminal Selector search-as-you-type box, fires per keystroke | `"listing terminals"` |
| **Container** | `Lots/Container/code.py:198` | `getOpenByCell` — cell-status read, re-evaluated repeatedly while operators work a cell | `"cellLocationId=%s"` |
| **Assembly** | `Workorder/Assembly/code.py:40` | `completeTray` | *(Not noise — legitimate mutation log; your screenshot shows it firing twice back-to-back because it was fired twice in testing, not because it's chatty by design.)* |

**Not in your screenshot but arguably worse:** `AppUser.getActiveByInitials` /
`AppUser.resolveForPresence` (`Location/AppUser/code.py:124,187`) fire on **every operator
initials scan/type at every terminal, plant-wide** — likely your single highest-frequency logger
once the plant is live.

## Sim module — flag for removal entirely

`BlueRidge.Sim` (`ignition/projects/Core/ignition/script-python/BlueRidge/Sim/code.py`) is a
PLC/OPC device **simulator** — it fakes `writeMember`/`writeMembers`/tag writes when no real
hardware is connected. It exists purely for dev/test. All 4 of its log calls (lines 76, 93, 129,
142) should either be stripped, or — better — confirm the module itself is excluded from whatever
ships to the production gateway project. Worth a standalone check: is `BlueRidge.Sim` reachable at
all from a production-configured gateway, or does something already gate it out?

## Recommendation

Two independent levers, not mutually exclusive:

1. **Immediate, zero-code-change stopgap:** raise the per-logger level to WARN in the Ignition
   Gateway (Config → Logging) for the noisiest logger names — `Sim`, `AimPoolConfig`, `PlcWatcher`,
   `TerminalPlcDevice`, `Terminal`, `Container`, `AppUser`, plus most of the Parts/Quality/Oee
   config-tool read paths (`Tool`, `Item`, `OperationTemplate`, `DieRank`, `Eligibility`,
   `ItemType`, `Uom`, `DowntimeReasonType`, `Hold`, `QualitySample`, `ShiftOverride`,
   `ShiftSchedule`, `DowntimeReasonCode`, `GlobalTrace`, `LotPause`, `SerializedPart`, `Lot`).
   Reversible per-environment, no deploy needed.
2. **Source fix (the "correct" one, matches the pattern the codebase already uses):** for every
   call site marked "Noise" below — almost universally the plain `get`/`list`/`search`/`getAll`
   reads that carry no `level=` kwarg — add `level="debug"` at the call site, mirroring what
   `Common/Db/code.py` and `Oee/Shift/code.py`'s polling functions already do. This is a mechanical,
   low-risk sweep: no logic changes, just adding a kwarg to ~180 call sites. `Sim`'s 4 lines are the
   exception — those are candidates for outright deletion rather than downgrade.

Secondary finding (not noise, but worth a look while in this code): several genuine **error**
paths are logged at the default `info` level instead of `warn`/`error` — `Lot.getOriginTypeIdByCode`
(`Lots/Lot/code.py:78`), `Container.complete`'s print-failure line (`Lots/Container/code.py:85`),
`Machining.mint`'s print-failure line (`Workorder/Machining/code.py:63`),
`Assembly._rankedFinishedGoods` (`Workorder/Assembly/code.py:189`),
`ProductionEvent.recordTrimInCheckpoint`'s silent-no-op branch (`Workorder/ProductionEvent/code.py:29`).
Also `Lots/LotLabel/code.py:61`'s `_sessionPrinter` failure log wasn't downgraded to debug the way
its sibling in `Lots/ShippingDispatcher/code.py:46` was — same helper, inconsistent level.

---

## Full index by domain

### Location / Common / Audit

Logger name = leaf of the calling module's dotted path. Level shown is explicit `level=` kwarg, or
`info` (the default) when omitted. All paths relative to
`ignition/projects/Core/ignition/script-python/BlueRidge/`.

#### Location/TerminalPlcDevice/code.py

| Line | Logger | Level | Function | Message | Judgment |
|---|---|---|---|---|---|
| 65 | TerminalPlcDevice | warn | getInstancePathOptions | `"getInstancePathOptions browse failed: %s" % e` | Keep — error path |
| 73 | TerminalPlcDevice | info | getByTerminal | `"terminalLocationId=%s"` | Keep — session-start/switch, not hot |
| 103 | TerminalPlcDevice | info | getByInstancePath | `"udtInstancePath=%s"` | **Noise — fires on every PLC watcher trigger** |
| 134 | TerminalPlcDevice | info | save | `"save params=%s"` | Keep — mutation |
| 142 | TerminalPlcDevice | info | deprecate | `"id=%s"` | Keep — mutation |

#### Location/AppUser/code.py

| Line | Logger | Level | Function | Message | Judgment |
|---|---|---|---|---|---|
| 13 | AppUser | info | getUserList | `"includeDeprecated=%s textFilter=%s"` | Keep — admin screen load |
| 23 | AppUser | info | getUser | `"id=%s"` | Keep — click-driven |
| 49 | AppUser | info | createUser | `"initials=%s"` | Keep — mutation |
| 57 | AppUser | info | deprecateUser | `"id=%s appUserId=%s"` | Keep — mutation |
| 85 | AppUser | info | updateUser | `"initials=%s"` | Keep — mutation |
| 110 | AppUser | info | getByInitials | `"initials=%s"` | Keep — on-demand |
| 124 | AppUser | info | getActiveByInitials | `"initials=%s"` | **Noise — every operator initials scan, every terminal, plant-wide** |
| 138 | AppUser | info | create | `"data=%s"` | Keep — mutation |
| 152 | AppUser | info | authenticateAd | `"adAccount=%s actionCode=%s terminalLocationId=%s appUserId=%s"` | Keep — security audit |
| 167 | AppUser | info | getRoles | `"appUserId=%s"` | Keep — on-demand |
| 187 | AppUser | info | resolveForPresence | `"initials=%s"` | **Noise — every operator sign-in, every terminal, plant-wide** |
| 265 | AppUser | error | _validateAdCredentials | `"validateUser error (userSource=%s account=%s): %s"` | Keep — error |
| 286 | AppUser | info | elevate | `"adAccount=%s actionCode=%s terminalLocationId=%s"` | Keep — security audit |
| 325 | AppUser | warn | logOperatorChange | `"logOperatorChange failed (non-fatal): %s"` | Keep — failure-only |

#### Location/Terminal/code.py

| Line | Logger | Level | Function | Message | Judgment |
|---|---|---|---|---|---|
| 26 | Terminal | info | getByIpAddress | `"ipAddress=%s"` | Keep — once per session onStartup |
| 39 | Terminal | info | listAll | `"listing terminals"` | **Noise — via listForSelector, per keystroke** |
| 113 | Terminal | info | listContextCells | `"terminalLocationId=%s"` | Keep — occasional |
| 154 | Terminal | info | getPrinter | `"terminalLocationId=%s"` | Keep — session start/navigate |
| 184 | Terminal | info | getClosureContext | `"getClosureContext failed: %s"` | Keep — error path |

#### Location/SessionPolicy/code.py

| Line | Logger | Level | Function | Message | Judgment |
|---|---|---|---|---|---|
| 24 | SessionPolicy | info | getPolicy | `"getPolicy failed: %s"` | Keep — failure-only branch |

#### Location/Tree/code.py

| Line | Logger | Level | Function | Message | Judgment |
|---|---|---|---|---|---|
| 105 | Tree | info | buildTree | `"rootId=%s expandDepth=%s"` | Keep — fires once per tree mutation |
| 299 | Tree | info | injectDraftNode | `"parentLocationId=%s items(...)"` | Keep — +Add click only |
| 413 | Tree | info | buildLauncherTree | `"rootId=%s expandDepth=%s"` | Keep — dev launcher, low freq |

#### Location/PrinterFgAssignment/code.py

| Line | Logger | Level | Function | Message | Judgment |
|---|---|---|---|---|---|
| 13 | PrinterFgAssignment | info | listForStation | `"listForStation stationTerminalLocationId=%s"` | **Noise — refresh-token-driven, station fill updates** |

#### Location/Printer/code.py

| Line | Logger | Level | Function | Message | Judgment |
|---|---|---|---|---|---|
| 74 | Printer | info | validateEndpoint | `"endpoint=%r kind=%r"` | Keep — explicit validate action only |

#### Location/LocationTypeDefinition/code.py

| Line | Logger | Level | Function | Message | Judgment |
|---|---|---|---|---|---|
| 148 | LocationTypeDefinition | info | getAll | `"locationTypeId=%s"` | Keep — admin popup |
| 157 | LocationTypeDefinition | info | getAll (except) | `"getAll(%s) failed: %s"` | Keep — error |
| 197 | LocationTypeDefinition | info | handleSaveAll | `"meta=%s attributes(n)=%d"` | Keep — mutation |
| 256 | LocationTypeDefinition | info | handleDeprecate | `"definitionId=%s"` | Keep — mutation |

#### Location/LocationType/code.py

| Line | Logger | Level | Function | Message | Judgment |
|---|---|---|---|---|---|
| 55 | LocationType | info | getAll | `"loading tiers"` | Keep — occasional |
| 59 | LocationType | info | getAll (except) | `"getAll failed: %s"` | Keep — error |
| 87 | LocationType | info | nameForTier | `"tiers(type=%s len=%s) tierId=%s (type=%s)"` | **Noise — leftover postmortem breadcrumb from a past null-render bug (2026 change-log), safe to downgrade now** |
| 101 | LocationType | info | nameForTier (except) | `"FAILED: %s"` | Keep — error |

#### Location/LocationAttributeDefinition/code.py

| Line | Logger | Level | Function | Message | Judgment |
|---|---|---|---|---|---|
| 53 | LocationAttributeDefinition | info | getAll | `"definitionId=%s"` | Keep — selection-driven |
| 62 | LocationAttributeDefinition | info | getAll (except) | `"getAll(%s) failed: %s"` | Keep — error |

#### Location/Location/code.py

| Line | Logger | Level | Function | Message | Judgment |
|---|---|---|---|---|---|
| 98 | Location | info | getOne | `"locationId=%s"` | Keep-ish — fires per tree click |
| 130 | Location | info | getFilteredList | `"nameFilter=%s"` | Borderline — likely per-keystroke |
| 186 | Location | info | getAttributesByLocation | `"locationId=%s"` | Borderline — same as getOne |
| 220 | Location | info | getAllAreas | `"loading areas"` | Keep — occasional |
| 243 | Location | info | listByTier | `"tierCode=%s"` | Keep — dropdown-open frequency |
| 252 | Location | info | listByTier (except) | `"listByTier failed: %s"` | Keep — error |
| 278 | Location | info | getCellsForDropdown | `"loading cells for dropdown"` | Keep — occasional |
| 314 | Location | info | getMachiningDestinationsForDropdown | `"loading machining destinations, activeLotId=%s"` | Borderline — refresh-token bound, may re-fire on active-LOT change |
| 329 | Location | info | getMachiningDestinationsForDropdown (except) | `"...failed: %s"` | Keep — error |
| 388 | Location | info | getCellsForAreaDropdown | `"getCellsForAreaDropdown areaId=%s"` | Keep — page load |
| 399 | Location | info | getCellsForAreaDropdown (except) | `"...failed: %s"` | Keep — error |
| 499 | Location | info | handleMoveUp | `"selected=%s"` | Keep — mutation |
| 526 | Location | info | handleMoveDown | `"selected=%s"` | Keep — mutation |
| 740 | Location | info | beginCreate | `"parentLocationId=%s parentHierarchyLevel=%s"` | Keep — +Add click |
| 810 | Location | info | handleSaveAll | `"meta=%s attributes(n)=%d"` | Keep — mutation |
| 890 | Location | info | handleDeprecate | `"locationId=%s"` | Keep — mutation |

#### Common/Session/code.py

| Line | Logger | Level | Function | Message | Judgment |
|---|---|---|---|---|---|
| 207 | Session | warn | dispatchElevatedAction | `"stale intent discarded for code=%s"` | Keep — rare edge case |
| 214 | Session | info | dispatchElevatedAction | `"no handler wired for code=%s (params=%s)"` | Keep — wiring-gap signal |

#### Common/Db/code.py — already the target pattern

| Line | Logger | Level | Function | Message | Judgment |
|---|---|---|---|---|---|
| 74 | Db | debug | execList | `"nq=%s params=%s"` | Already correct — hottest path in the app, already debug |
| 77 | Db | debug | execList | `"rows=%d"` | Already correct |
| 98 | Db | warn | execOne | `"multi-row from execOne nq=%s"` | Keep — integrity-violation warn |
| 128 | Db | debug | execMutation | `"nq=%s params=%s"` | Already correct |
| 134 | Db | warn | execMutation | `"multi-row from execMutation nq=%s"` | Keep — integrity-violation warn |
| 136 | Db | debug | execMutation | `"result=%s"` | Already correct |
| 159 | Db | debug | execNonQuery | `"nq=%s params=%s"` | Already correct |

#### Common/Util/code.py (self-calls, same `log()` path)

| Line | Logger | Level | Function | Message | Judgment |
|---|---|---|---|---|---|
| 335 | Util | info | getIconLibrary | `"library=%s"` | Keep — popup open, low freq |
| 339 | Util | info | getIconLibrary | `"FAILED: could not resolve sprite path..."` | Keep — error |
| 345 | Util | info | getIconLibrary | `"FAILED: read %s -> %s"` | Keep — error |
| 349 | Util | info | getIconLibrary | `"FAILED: empty sprite at %s"` | Keep — error |
| 357 | Util | info | getIconLibrary | `"found %d icon(s)"` | Keep — low freq |
| 398 | Util | info | buildIconPickerInstances | `"icons(...) selected=%s"` | Keep — popup open |
| 419 | Util | info | buildIconPickerInstances | `"returning %d tile(s)"` | Keep — popup open |
| 441 | Util | info | buildIconPickerInstancesFromLibrary | `"library=%s selected=%s"` | Keep — popup open |

No bypass call sites: the only `system.util.getLogger(...)` usage in Location/Common/Audit is
inside `log()`'s own implementation.

#### Audit/Partition, LogSeverity, LogEntityType, FailureLog, ConfigLog

| File | Line | Logger | Level | Function | Message | Judgment |
|---|---|---|---|---|---|---|
| Audit/Partition/code.py | 9 | Partition | info | maintain | `"asOfUtc=%s retentionMonths=%s appUserId=%s terminalLocationId=%s"` | Keep — scheduled maintenance action |
| Audit/LogSeverity/code.py | 19 | LogSeverity | info | list | `"loading log severities"` | Keep — occasional dropdown |
| Audit/LogSeverity/code.py | 23 | LogSeverity | info | list (except) | `"list failed: %s"` | Keep — error |
| Audit/LogEntityType/code.py | 25 | LogEntityType | info | list | `"loading log-entity types"` | Keep — occasional |
| Audit/LogEntityType/code.py | 29 | LogEntityType | info | list (except) | `"list failed: %s"` | Keep — error |
| Audit/FailureLog/code.py | 57 | FailureLog | info | search | `"search filter=%s"` | Keep — user-initiated |
| Audit/FailureLog/code.py | 95 | FailureLog | info | search (except) | `"search failed: %s"` | Keep — error |
| Audit/FailureLog/code.py | 104 | FailureLog | info | getByEntity | `"typeCode=%s entityId=%s"` | Keep — drill-down click |
| Audit/FailureLog/code.py | 113 | FailureLog | info | getByEntity (except) | `"getByEntity failed: %s"` | Keep — error |
| Audit/FailureLog/code.py | 120 | FailureLog | info | distinctProcedures | `"loading distinct procedures"` | Keep — occasional |
| Audit/FailureLog/code.py | 124 | FailureLog | info | distinctProcedures (except) | `"...failed: %s"` | Keep — error |
| Audit/ConfigLog/code.py | 43 | ConfigLog | info | search | `"search filter=%s"` | Keep — user-initiated |
| Audit/ConfigLog/code.py | 65 | ConfigLog | info | search (except) | `"search failed: %s"` | Keep — error |
| Audit/ConfigLog/code.py | 74 | ConfigLog | info | getByEntity | `"typeCode=%s entityId=%s"` | Keep — drill-down click |
| Audit/ConfigLog/code.py | 83 | ConfigLog | info | getByEntity (except) | `"getByEntity failed: %s"` | Keep — error |

---

### Lots domain

Paths relative to `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/`.

#### ShippingDispatcher/code.py

| Line | Level | Function | Message | Judgment |
|---|---|---|---|---|
| 46 | debug | _sessionPrinter | `"_sessionPrinter failed: %s"` | Already correct |
| 98 | debug | _dispatchWorker | `"_dispatchWorker failed for label %s: %s"` | Already correct |
| 107 | info | dispatch | `"dispatch shippingLabelId=%s printerLocationId=%s"` | Keep — real print-dispatch attempt |

#### Lot/code.py

| Line | Level | Function | Message | Judgment |
|---|---|---|---|---|
| 41 | info | create | `"create data=%s appUserId=%s terminalLocationId=%s lotName=%s cavityNote=%s"` | Keep — LOT mint |
| 78 | info | getOriginTypeIdByCode (except) | `"getOriginTypeIdByCode failed: %s"` | Keep — but should be warn/error, not info |
| 88 | info | get | `"lotId=%s lotName=%s"` | **Noise — every LOT Detail bind/getOrEmpty/getByName** |
| 97 | info | list | `"itemId=%s currentLocationId=%s lotStatusId=%s limitRows=%s"` | **Noise — every grid refresh** |
| 113 | info | updateStatus | `"updateStatus data=%s appUserId=%s terminalLocationId=%s"` | Keep — mutation |
| 133 | info | moveTo | `"lotId=%s toLocationId=%s appUserId=%s terminalLocationId=%s"` | Keep — mutation |
| 151 | info | assertNotBlocked | `"lotId=%s"` | **Noise — guard-check ahead of most scan/move actions** |
| 159 | info | getParents | `"lotId=%s"` | **Noise — Genealogy tab load** |
| 164 | info | getChildren | `"lotId=%s"` | **Noise — Genealogy tab load** |
| 169 | info | getHistory | `"lotId=%s"` | **Noise — History tab load** |
| 295 | info | getLatestForToolCavityOrEmpty | `"toolId=%s toolCavityId=%s"` | **Noise — refresh-token die-cast card** |
| 312 | info | getScrapSummaryOrEmpty | `"lotId=%s"` | **Noise — Total Scrap card** |
| 321 | info | getPauses | `"lotId=%s"` | **Noise — pauses tab** |
| 330 | info | getLinkedContainer | `"lotId=%s"` | **Noise — Linked Container tab** |
| 348 | info | getGenealogyTree | `"lotId=%s direction=%s"` | **Noise — per view load** |
| 353 | info | search | `"query=%s statusId=%s originId=%s limit=%s"` | **Noise — likely per keystroke** |
| 368 | info | moveToValidated | `"lotId=%s toLocationId=%s operationTypeCode=%s ..."` | Keep — real scan-commit state transition |
| 388 | info | getCellLineQuantity | `"locationId=%s itemId=%s"` | **Noise — per scan flow** |
| 408 | info | getWipQueueByLocation | `"locationId=%s includeDescendants=%s operationTypeCode=%s"` | **Noise — refresh-token WIP queue, re-fires after every move** |
| 459 | info | getComponentsAtCell | `"getComponentsAtCell locationId=%s includeDescendants=%s"` | **Noise — refresh-token assembly-cell read** |
| 546 | info | getLineInventoryByPart | `"getLineInventoryByPart locationId=%s"` | **Noise — refresh-token inventory popup** |
| 568 | info | getShiftCavityTally | `"toolId=%s"` | **Noise — fanned out by 6+ KPI wrappers, die-cast right rail** |
| 710 | info | openDieCast | `"openDieCast data=%s"` | Keep — mutation |
| 735 | info | releaseDieCast | `"releaseDieCast data=%s"` | Keep — mutation |
| 757 | info | voidDieCast | `"voidDieCast lotId=%s appUserId=%s terminalLocationId=%s"` | Keep — mutation |
| 833 | info | getScrapEvents | `"lotId=%s topN=%s"` | **Noise — refresh-token Scrap tab** |
| 907 | info | recordScrapAtCurrentLocation | `"recordScrapAtCurrentLocation lotId=%s defectCodeId=%s quantity=%s chargeToArea=%s appUserId=%s"` | Keep — mutation |
| 940 | info | rectifyPieceCount | `"rectifyPieceCount lotId=%s newPieceCount=%s appUserId=%s"` | Keep — mutation |
| 956 | info | setCrt | `"setCrt lotId=%s appUserId=%s terminalLocationId=%s"` | Keep — mutation |
| 974 | info | clearCrt | `"clearCrt lotId=%s appUserId=%s terminalLocationId=%s"` | Keep — mutation |
| 1013 | warn | crtNamesFor | `"crtNamesFor: read failed for lotId=%s (%s) - LOT omitted..."` | Keep — fail-open warning |
| 1019 | warn | crtNamesFor | `"crtNamesFor: no row for lotId=%s - LOT omitted..."` | Keep — edge-case warning |

#### LotLabel/code.py

| Line | Level | Function | Message | Judgment |
|---|---|---|---|---|
| 61 | info (default) | _sessionPrinter | `"_sessionPrinter failed: %s"` | Inconsistent — sibling in ShippingDispatcher is debug, this isn't |
| 122 | info | printLabel | `"printLabel data=%s"` | Keep — mutation |
| 144 | info | reprint | `"reprint lotId=%s printReasonCodeId=%s"` | Keep — mutation |

#### Container/code.py

| Line | Level | Function | Message | Judgment |
|---|---|---|---|---|
| 15 | info | open | `"open itemId=%s containerConfigId=%s cellLocationId=%s appUserId=%s"` | Keep — mutation |
| 29 | info | trayClose | `"trayClose containerId=%s trayPosition=%s partsCount=%s closureMethod=%s appUserId=%s"` | Keep — mutation |
| 45 | info | serialAdd | `"serialAdd containerId=%s serializedPartId=%s containerTrayId=%s trayPosition=%s bypass=%s appUserId=%s"` | Keep — per-part mutation |
| 64 | info | complete | `"complete containerId=%s operatorConfirmed=%s plcCompletionConfirmed=%s appUserId=%s"` | Keep — mutation |
| 85 | info (default) | complete | `"Container shipping label print failed: %s"` | Error but at info — should be warn |
| 109 | error | complete | `"CRT-held check failed, defaulting to held: %s"` | Keep — error |
| 113 | error | complete | `"CRT-held check failed, defaulting to held: %s"` | Keep — error |
| 123 | error | complete | `"AIM post-back failed: %s"` | Keep — error |
| 126 | error | complete | `"AIM post-back failed: %s"` | Keep — error |
| 165 | info | validateCrt | `"validateCrt containerId=%s appUserId=%s terminalLocationId=%s"` | Keep — mutation |
| 186 | error | validateCrt | `"CRT validate post failed: %s"` | Keep — error |
| 189 | error | validateCrt | `"CRT validate post failed: %s"` | Keep — error |
| 198 | info | getOpenByCell | `"cellLocationId=%s"` | **Noise — cell-status read, screenshot example** |

#### SortCage, IdentifierSequence, AimPool, AimPoolConfig, PrintFailureGateway

| File | Line | Level | Function | Message | Judgment |
|---|---|---|---|---|---|
| SortCage/code.py | 16 | info | migrateSerial | `"migrateSerial containerSerialId=%s newContainerId=%s newTrayPosition=%s reason=%s appUserId=%s"` | Keep — mutation |
| IdentifierSequence/code.py | 8 | info | next | `"code=%s"` | Keep — 1:1 with real mint events |
| AimPool/code.py | 14 | info | topup | `"topup aimShipperId=%s fetchedInterfaceLogId=%s"` | Keep — mutation, bounded ≤25/tick |
| AimPool/code.py | 27 | info | claim | `"claim containerId=%s appUserId=%s"` | Keep — mutation |
| AimPool/code.py | 46 | error | getDepth | `"getDepth failed: %s"` | Keep — error only (success path deliberately silent, good pattern) |
| AimPool/code.py | 49 | error | getDepth | `"getDepth failed: %s"` | Keep — error |
| AimPool/code.py | 57 | debug | getForPost | `"getForPost aimShipperId=%s"` | Already correct |
| AimPool/code.py | 64 | debug | recordPostResult | `"recordPostResult poolId=%s success=%s"` | Already correct |
| **AimPoolConfig/code.py** | **13** | **info** | **get** | **`"get"`** | **PRIME NOISE EXAMPLE — your screenshot. Fires every topupTick/alarmTick.** |
| AimPoolConfig/code.py | 39 | info | update | `"update targetBufferDepth=... appUserId=%s"` | Keep — rare admin mutation |

#### PrintFailureGateway, GlobalTrace, AimPost, AimPoolGateway, LotPause, Shipping, SerializedPart

| File | Line | Level | Function | Message | Judgment |
|---|---|---|---|---|---|
| PrintFailureGateway/code.py | 42 | debug | _pushToAllSessions | `"_pushToAllSessions failed: %s"` | Already correct |
| PrintFailureGateway/code.py | 66 | warn | sweepTick | `"print sweep: %d stranded shipping labels..."` | Keep — conditional alarm only |
| PrintFailureGateway/code.py | 69 | debug | sweepTick | `"sweepTick failed: %s"` | Already correct |
| PrintFailureGateway/code.py | 86 | debug | broadcastTick | `"broadcastTick failed: %s"` | Already correct |
| GlobalTrace/code.py | 29 | info | resolve | `"resolve searchText=%s"` | **Noise — likely per keystroke** |
| AimPost/code.py | 86,89 | error | postOne | `"postOne %s failed: %s"` | Keep — error |
| AimPost/code.py | 111,114 | error | retryTick | `"retryTick row %s: %s"` | Keep — per-row error |
| AimPost/code.py | 116 | info | retryTick | `"retryTick %s" % stats` | Borderline — fires every 60s tick when anything attempted; downgrade if chatty |
| AimPost/code.py | 118,120 | error | retryTick | `"retryTick failed: %s"` | Keep — error |
| AimPoolGateway/code.py | 52,57 | warn | topupTick | `"topupTick stopping/could not pool: %s"` | Keep — real failure |
| AimPoolGateway/code.py | 63 | info | topupTick | `"topupTick fetched %d (depth was %d)"` | **Noise candidate — every tick with any fetch, on the topup timer** |
| AimPoolGateway/code.py | 66,69 | error | topupTick | `"topupTick failed: %s"` | Keep — error |
| AimPoolGateway/code.py | 110,126 | info | alarmTick | `"AIM pool %s: %d remaining"` / backlog msg | Keep — rising-edge alarm transition only |
| AimPoolGateway/code.py | 129,131 | error | alarmTick | `"alarmTick error: %s"` | Keep — error |
| AimPoolGateway/code.py | 144 | debug | _logAim | `"_logAim failed: %s"` | Already correct |
| LotPause/code.py | 6 | info | getCountByLocation | `"locationId=%s"` | **Noise — badge indicator, terminal header** |
| LotPause/code.py | 12 | info | getByLocation | `"locationId=%s"` | **Noise — badge-open read** |
| LotPause/code.py | 18 | info | resume | `"pauseEventId=%s"` | Keep — mutation |
| Shipping/code.py | 15,27,39,52 | info | ship/voidLabel/reprintLabel/ackBanner | various | Keep — all mutations |
| SerializedPart/code.py | 17 | info | mint | `"mint itemId=%s producingLotId=%s serialNumber=%s appUserId=%s"` | Keep — mutation |
| SerializedPart/code.py | 29 | info | getBySerial | `"serialNumber=%s"` | **Noise — MIP watcher dedup lookup, per-scan** |

---

### Workorder domain + Sim

Paths relative to `ignition/projects/Core/ignition/script-python/BlueRidge/`.

| File | Line | Level | Function | Message | Judgment |
|---|---|---|---|---|---|
| Workorder/DieCast/code.py | 36 | info | getShiftOutputBreakdown | `"getShiftOutputBreakdown toolId=%s shiftId=%s grossShots=%s"` | **Noise — routine read, every UI query** |
| Workorder/DieCast/code.py | 60 | info | recordShiftOutput | `"recordShiftOutput data=%s ..."` | Keep — mutation |
| Workorder/DieCast/code.py | 179 | info | registerShotLoss | `"registerShotLoss toolId=%s shiftId=%s defectCodeId=%s quantity=%s"` | Keep — mutation |
| Workorder/DieCast/code.py | 253 | info | getBulkOpenRowInstances | `"getBulkOpenRowInstances toolId=%s"` | **Noise — repeater builder, every render** |
| Workorder/DieCast/code.py | 260,265 | info | getBulkOpenRowInstances | `"...failed: %s"` | Keep — error |
| Workorder/DieCast/code.py | 341 | info | submitBulkOpen | `"submitBulkOpen toolId=%s cellLocationId=%s rows=%s"` | Keep — batch mutation |
| Workorder/DieCast/code.py | 439 | warn | submitBulkOpen | `"submitBulkOpen: CRT read-back failed (%s) - notice suppressed..."` | Keep — non-fatal error flag |
| Workorder/SerializedMipWatcher/code.py | 84 | warn | _finish | `"serialized handshake rejected %s: %s"` | Keep — real failure, though per-edge |
| Workorder/TrayInspectionWatcher/code.py | 62 | warn | _onTrayLocked | `"tray %s: front LOT item %s has no PlcId..."` | Keep — real config/error condition |
| Workorder/TrayInspectionWatcher/code.py | 94 | warn | _onInspectionComplete | `"tray %s LINE STOP: %s"` | Keep — real line-stop event (redundant with adjacent `logInterface` call — consider consolidating) |
| **Workorder/PlcWatcher/code.py** | 83 | debug | writeDisplay | `"display writes suppressed (WriteDisplayEnabled=0) for %s"` | **Noise — every display-write attempt while flag is off** |
| Workorder/PlcWatcher/code.py | 155 | warn | logInterface | `"logInterface failed: %s"` | Keep — error |
| Workorder/PlcWatcher/code.py | 186 | warn | dispatch | `"no TerminalPlcDevice mapping for %s (edge on %s ignored)"` | Keep but could flood if a device stays unmapped — consider dedup/throttle |
| **Workorder/PlcWatcher/code.py** | **192** | **info** | **dispatch** | **`"edge %s on %s -> %s (terminal %s)"`** | **Noise — every rising edge on every PLC device plantwide. Screenshot example.** |
| Workorder/PlcWatcher/code.py | 199 | error | dispatch | `"dispatch error tagPath=%s: %s"` | Keep — error |
| Workorder/PlcWatcher/code.py | 215 | warn | _route | `"unknown device type %s"` | Keep — real misconfiguration, though per-edge |
| Workorder/DieCastSupervisor/code.py | 184 | error | getDashboard | `"getDashboard: shift context read failed"` | Keep — error |
| Workorder/NonSerializedMipWatcher/code.py | 36 | warn | handleEdge | `"non-serialized line config missing for terminal %s -- ack only"` | **Noise risk — will flood on every DataReady edge for any unconfigured non-serialized line until commissioned** |
| Workorder/AssemblyPlc/code.py | 58 | error | tickWatcher | `"tickWatcher error: %s"` | Keep — error (currently unreachable, `_WATCH` empty) |
| Workorder/AssemblyPlc/code.py | 70 | debug | _handlePiece | `"MIP piece edge at cell %s (commissioning no-op)"` | **Noise risk once `_WATCH` populated at commissioning — per piece edge** |
| Workorder/Consumption/code.py | 19 | info | recordWithBomCheck | `"recordWithBomCheck sourceLotId=%s producingLotId=%s cellLocationId=%s consumedPieceCount=%s appUserId=%s"` | Keep — mutation |
| Workorder/Machining/code.py | 17 | info | recordPick | `"recordPick lotId=%s lineLocationId=%s appUserId=%s terminalLocationId=%s"` | Keep — mutation |
| Workorder/Machining/code.py | 42 | info | mint | `"mint sourceLotId=%s operationTemplateId=%s pieceCount=%s producedItemId=%s appUserId=%s allowPartial=%s scrapLines=%s"` | Keep — mutation |
| Workorder/Machining/code.py | 63 | info (default) | mint | `"MachiningOut sublot label print failed: %s"` | Error but at info — should be warn |
| Workorder/Assembly/code.py | 21 | info | scanIn | `"scanIn lotName=%s lotId=%s cellLocationId=%s appUserId=%s"` | Keep — mutation |
| Workorder/Assembly/code.py | 40 | info | completeTray | `"completeTray finishedGoodItemId=%s pieceCount=%s cellLocationId=%s appUserId=%s"` | Keep — mutation (screenshot's "completeTray()" is legit, not noise) |
| Workorder/Assembly/code.py | 145,149 | warn | notifyInventoryChanged | `"...send/enumerate failed: %s"` | Keep — error |
| Workorder/Assembly/code.py | 189 | info (default) | _rankedFinishedGoods | `"_rankedFinishedGoods failed: %s"` | Error but at info — should be warn |
| Workorder/TrimOut/code.py | 18 | info | record | `"record data=%s appUserId=%s terminalLocationId=%s"` | Keep — mutation |
| Workorder/RejectEvent/code.py | 18 | info | record | `"record data=%s appUserId=%s terminalLocationId=%s"` | Keep — mutation |
| Workorder/ProductionEvent/code.py | 29 | info (default) | recordTrimInCheckpoint | `"...no TrimIn route step for item %s (lot %s)"` | Silent no-op branch, arguably warn not info |
| Workorder/ProductionEvent/code.py | 42 | info | record | `"record data=%s appUserId=%s terminalLocationId=%s"` | Keep — mutation |
| Workorder/ProductionEvent/code.py | 70 | info | listByLot | `"listByLot lotId=%s"` | **Noise — every checkpoint-history fetch** |
| **Sim/code.py** | **76** | **info** | getDeviceOptions | `"running"` | **DEV/TEST-ONLY SIMULATOR — should never fire against prod gateway** |
| **Sim/code.py** | **93** | **info** | getScenariosForDeviceType | `"deviceType=%s"` | **DEV/TEST-ONLY SIMULATOR** |
| **Sim/code.py** | **129** | **info** | writeMember | `"device=%s member=%s value=%s"` | **DEV/TEST-ONLY SIMULATOR — screenshot example** |
| **Sim/code.py** | **142** | **info** | writeMembers | `"device=%s members=%s"` | **DEV/TEST-ONLY SIMULATOR — screenshot example** |

---

### Parts / Quality / Oee domain

Paths relative to `ignition/projects/Core/ignition/script-python/BlueRidge/`. 179 call sites — the
large majority of "Noise" rows below are unconditional-INFO reads (`get`/`getAll`/`getOne`/`list`/
`search`/dropdown builders) with no `level=` kwarg; every `except` branch and every
Create/Update/Deprecate/Publish/SaveAll mutation is "Keep."

#### Parts/Item/code.py (13 sites)

| Line | Level | Function | Judgment |
|---|---|---|---|
| 71 | info | getAll | Noise |
| 84 | info | getAll (except) | Keep — error |
| 94 | info | getOne | Noise |
| 103 | info | getOne (except) | Keep — error |
| 151 | info | getEligibleForLocationDropdown | Noise |
| 165 | info | getEligibleForLocationDropdown (except) | Keep — error |
| 325 | info | add | Keep — mutation |
| 369 | info | update | Keep — mutation |
| 406 | info | deprecate | Keep — mutation |
| 439 | info | getMaxParts | Noise — movement-scan read |
| 454 | info | getByPartNumber | Noise — every scan/pick |
| 468 | info | getPlcId | Noise |
| 476 | info | setPlcId | Keep — mutation |

#### Parts/Tool/code.py (43 sites)

| Line | Level | Function | Judgment |
|---|---|---|---|
| 127,147 | info | getAllForList (+except) | Noise / Keep-error |
| 179 | info | getOne | Noise |
| 215 | info | add | Keep — mutation |
| 264 | info | update | Keep — mutation |
| 311 | info | deprecate | Keep — mutation |
| 355 | info | getDuplicateSummary | Noise |
| 428 | info | handleDuplicate | Keep — clone/create mutation |
| 464,473 | info | getAttributeInstancesForTool (+except) | Noise / Keep-error |
| 499,508 | info | getCavityInstancesForTool (+except) | Noise / Keep-error |
| 536,545 | info | getAssignmentInstancesForTool (+except) | Noise / Keep-error |
| 572 | info | getActiveAssignmentForTool | Noise |
| 602 | info | getStatusCodesForDropdown (except) | Keep — error |
| 613 | info | getToolTypesForDropdown (except) | Keep — error |
| 665 | info | addAttributeDefinition | Keep — mutation |
| 694,703 | info | getAttributeDefinitionsForToolType (+except) | Noise / Keep-error |
| 717,732 | info | getAttributeDefinitionOptions (+except) | Noise / Keep-error |
| 752,761 | info | getCellsForDropdown (+except) | Noise / Keep-error |
| 783 | info | createCavity | Keep — mutation |
| 804 | info | updateCavityStatus | Keep — mutation |
| 820 | info | deprecateCavity | Keep — mutation |
| 837 | info | upsertAttribute | Keep — mutation |
| 856 | info | removeAttribute | Keep — mutation |
| 874 | info | saveAttributesAll | Keep — bundled SaveAll |
| 901 | info | saveCavitiesAll | Keep — bundled SaveAll |
| 930 | info | assignToCell | Keep — mutation |
| 952 | info | releaseAssignment | Keep — mutation |
| 976,983 | info | getCavitiesForDropdown (+except) | Noise (die-cast station, high-traffic) / Keep-error |
| 998,1005 | info | getMountedToolForCell (+except) | Noise (poll-driven) / Keep-error |
| 1036,1046 | info | getCellMountContextOrEmpty (+except) | Noise (plant hierarchy card, high-traffic) / Keep-error |
| 1062,1069 | info | getShotStatusForCell (+except) | Noise (badge, refresh-token polled) / Keep-error |
| 1091,1098 | info | getMountableToolsForCell (+except) | Noise / Keep-error |

#### Parts/Bom, DieRank, Eligibility, ItemType, ContainerConfig, Uom, RouteTemplate

| File | Line | Level | Function | Judgment |
|---|---|---|---|---|
| Bom/code.py | 122,142 | info | getActiveForItem (+except) | Noise / Keep-error |
| Bom/code.py | 172,230,252,264 | info | listByParentItem / getOneFull / listAvailableItems / listUoms (all except) | Keep — error paths only, no happy-path log |
| Bom/code.py | 367 | info | handleCreateOrCloneVersion (except) | Keep — mutation failure |
| DieRank/code.py | 51,58 | info | getAllForList (+except) | **Noise — literal `"call"` message** / Keep-error |
| DieRank/code.py | 66 | info | getOne | Noise |
| DieRank/code.py | 77 | info | getByCode | Noise |
| DieRank/code.py | 173 | info | getCompatibilityMatrix (except) | Keep — error |
| DieRank/code.py | 200,211,227,245,266 | info | saveCompatibilityMatrix/add/update/deprecate/setCompatibility | Keep — all mutations |
| Eligibility/code.py | 30 | info | listByItem | Noise |
| Eligibility/code.py | 47 | info | listLocationOptions | **Noise — literal `"running"` message** |
| Eligibility/code.py | 64 | info | handleSaveAll | Keep — mutation |
| ItemType/code.py | 29,36 | info | getAll (+except) | Noise / Keep-error |
| ContainerConfig/code.py | 33,43 | info | getByItem (+except) | Noise / Keep-error |
| ContainerConfig/code.py | 132,154,171 | info | add/deprecate/update | Keep — mutations |
| Uom/code.py | 29,36 | info | getAll (+except) | Noise / Keep-error |
| RouteTemplate/code.py | 102,122 | info | getActiveForItem (+except) | Noise / Keep-error |

#### Parts/OperationTemplate/code.py (25 sites) + ItemLocation

| Line | Level | Function | Judgment |
|---|---|---|---|
| 80,92 | info | getAllForList (+except) | Noise / Keep-error |
| 122 | info | search | Noise |
| 175 | info | getOne | Noise |
| 200,210 | info | getVersionsForCode (+except) | Noise / Keep-error |
| 278,287 | info | getFieldsForTemplate (+except) | Noise / Keep-error |
| 318 | info | getDieCastFieldsWithType (except) | Keep-error (on a die-cast hot path — consider debug if frequent) |
| 353,398,415,432,458,478 | info | various dropdown/resolver getters (all except) | Keep — error paths |
| 507,539,560,576,593,610 | info | add/update/deprecate/createNewVersion/publish/discardDraft | Keep — all mutations/state transitions |
| 628,648,664,683 | info | addField/removeField/setFieldRequired/saveFieldsAll | Keep — mutations |
| ItemLocation/code.py:14 | info | checkEligibility | **Noise — every movement scan, high-traffic** |

#### Quality/Crt, DefectCode, QualitySpec, Hold, QualitySample

| File | Line | Level | Function | Judgment |
|---|---|---|---|---|
| Crt/code.py | 33 | info | getRequiredInspections | Noise — likely polled |
| Crt/code.py | 44 | info | flagMissed | Keep — safety/audit mutation |
| DefectCode/code.py | 89,101 | info | getAll (+except) | Noise / Keep-error |
| DefectCode/code.py | 117,136 | info | getForDropdown/getCategoryOptions (except) | Keep-error |
| DefectCode/code.py | 148 | info | getOne | Noise |
| DefectCode/code.py | 162,180,196 | info | add/update/deprecate | Keep — mutations |
| DefectCode/code.py | 278 | info | getForTiles (except) | Keep-error |
| QualitySpec/code.py | 82,91 | info | listForItem (+except) | Noise / Keep-error |
| QualitySpec/code.py | 314,366 | info | listUoms/getActiveVersionForItemOrEmpty (except) | Keep-error |
| Hold/code.py | 15,29 | info | place/release | Keep — safety-critical mutations |
| Hold/code.py | 39,60,83,93 | info | getOpenByLot/getOpenByContainer/listOpen/listAssociatedContainers | Noise — all reads, fire on every panel/LOT-detail load |
| Hold/code.py | 117 | info | placeBulk | Keep — bulk mutation summary |
| QualitySample/code.py | 27 | info | record | Keep — mutation |
| QualitySample/code.py | 85,126,155 | info | listByLot/listResults/listAttachments | Noise — reads |
| QualitySample/code.py | 136 | info | addAttachment | Keep — mutation |
| QualitySample/code.py | 169 | info | getTriggerOptions (except) | Keep-error |

#### Oee/Shift, ShiftOverride, ShiftSchedule, DowntimeReasonType, DowntimePlc, DowntimeReasonCode

| File | Line | Level | Function | Judgment |
|---|---|---|---|---|
| **Shift/code.py** | 14,32 | info | start/end | Keep — shift-boundary mutations |
| Shift/code.py | 61,70,157,218 | **debug** | getActive/getOpen/getForInstant/tickShiftBoundary | **Already correct — template for the downgrade pass** |
| Shift/code.py | 92 | info | acknowledgeHandover | Keep — audit mutation |
| Shift/code.py | 222 | error | tickShiftBoundary (except) | Keep — error, already correct |
| ShiftOverride/code.py | 76,81 | info | listEquipment (+except) | Noise / Keep-error |
| ShiftOverride/code.py | 97,108 | info | search (+except) | Noise / Keep-error |
| ShiftOverride/code.py | 147,153 | info | getOne (+except) | Noise / Keep-error |
| ShiftOverride/code.py | 162,181,196,216 | info | add/update/deprecate/apply | Keep — mutations |
| ShiftOverride/code.py | 305,314 | info | availability (+except) | Noise (OEE dashboard, possibly high-traffic) / Keep-error |
| ShiftSchedule/code.py | 84,90 | info | search (+except) | Noise / Keep-error |
| ShiftSchedule/code.py | 118,124 | info | getOne (+except) | Noise / Keep-error |
| ShiftSchedule/code.py | 131,147,164 | info | add/update/deprecate | Keep — mutations |
| DowntimeReasonType/code.py | 7,11 | info | getAll (+except) | Noise — small lookup table, called on every dropdown despite NQ cache / Keep-error |
| **DowntimePlc/code.py** | **46** | **info** | tickWatcher | **Noise risk — fires every gateway-timer tick while misconfigured, would flood the log** |
| DowntimeReasonCode/code.py | 20,32 | info | search (+except) | Noise — 353-row grid, frequent refresh / Keep-error |
| DowntimeReasonCode/code.py | 53,59 | info | getOne (+except) | Noise / Keep-error |
| DowntimeReasonCode/code.py | 66,83,98 | info | add/update/deprecate | Keep — mutations |
| DowntimeReasonCode/code.py | 123,142 | info | getForDropdown/getCategoryOptions (except) | Keep-error |

---

## Revision history

| Date | Change |
|---|---|
| 2026-08-20 | Initial index — full sweep of `BlueRidge.Common.Util.log()` call sites across Core, requested after gateway console noise complaint (screenshot showed AimPoolConfig/Assembly/Container/Terminal/PlcWatcher/TerminalPlcDevice/Sim spam). |
