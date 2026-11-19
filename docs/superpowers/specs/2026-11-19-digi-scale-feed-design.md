# Assembly Out By Weight: Scale Read Through a Digi One SP — Design Spec

**Date:** 2026-11-19
**Status:** Design approved by Jacques 2026-11-19. Not built.
**Author:** Blue Ridge (with Claude)
**Builds on:** `docs/superpowers/specs/2026-10-19-assembly-out-scale-station-design.md` (scale station screen, running part, override, press log) and `docs/superpowers/specs/2026-08-31-ind570-eprint-demand-output-design.md` (TCP driver transport, watcher shape).
**Findings:** `notes/2026-11-19_digi-one-sp-scale-capture.md` (bench capture with Tom Davis, record format, TCP settings).

---

## 1. Why

The production IND570 heads run compiled TaskExpert programs nobody can open. Reconfiguring them for EPrint means the scale vendor. A Digi One SP on each head's serial port reads what TaskExpert already sends, which is what Flexware's MES used. The bench test on 2026-11-19 proved the transport: 4 of 4 presses arrived through Ignition's TCP driver.

**Direction (Jacques, 2026-11-19): every production scale goes through a Digi box before it goes live. The EPrint path becomes legacy.** It keeps working unchanged (Template 1, Template 3, `CAM=`). Nothing new is built on it.

MPP wants a live test soon.

## 2. The record

One record per **good** press, ASCII, terminated `CR LF LF`:

```
(NET)15.5<UOM>LB<TWM>1<Part>TEST3
```

| Field | Meaning |
|---|---|
| `(NET)` | Net weight |
| `<UOM>` | Unit (`LB`); compared case-insensitively with `lb` |
| `<TWM>` | Target Weight Met. Only `1` observed: TaskExpert sends nothing for a bad weight (it turns the stack light red) |
| `<Part>` | The part selected on the scale |

The TCP driver is set **Character Based, delimiter `\r`**, so each message arrives with the previous record's two `LF`s at its front. The data is in **`MessageBytes`**; the `Message` string reads blank.

**What `<Part>` holds on production heads is not yet confirmed.** Each head's target table (`scale work/Scale Programs/*/Tables/a4.CSV`) has two text columns per record. On most heads both are the MES part number, spaces included (`12270-6NA -A000`), which equals `Parts.Item.PartNumber`. Some rows are free text (`Inner Housing`, `6MD Ftel Pump`, `Test`) or typos (`11300-RCA-A00`). The bench codes `66VTC` / `TEST3` are in no exported table. The `.cpt` programs are compiled or encrypted and carry no readable strings. **Confirm with one press per head on a real part** (commissioning, §9).

## 3. Decisions (Jacques, 2026-11-19)

1. **The scale decides the part.** Writing the part back to the scale is not possible over the Digi: TaskExpert does not read the serial line.
2. **The scale decides good.** `TWM=1` closes the tray. The MES still judges the net weight against `Parts.ContainerConfig` and logs a warning when it disagrees. It never blocks.
3. **A box never mixes parts.** A press for part X while the station has an open box of part Y is refused. The box stays open; the operator finishes or closes it, or switches the scale back, and presses again.
4. **If the part cannot be determined from the record, the operator picks it on screen** from the parts that can run (eligibility rule of the scale-station spec §5.1).
5. **That press is held, and the tray closes when the operator picks.** No re-press.

## 4. Approaches

| | Approach | Trade-off |
|---|---|---|
| **Chosen** | **New device type `ScaleStationDigi` + a sibling watcher `ScaleDigiWatcher`.** `PlcWatcher.dispatchMessage` routes by type. | One migration row. The EPrint watcher is not edited, so its variants cannot break. Shared helpers are called, not copied. |
| Rejected | Auto-detect inside `ScaleEPrintWatcher`. | No migration, but it edits the legacy module and changes how it reads (`Message` vs `MessageBytes`). |

## 5. Schema — migration `0134_scale_digi_and_pending_press.sql`

`0125`, `0126`, `0131`, `0132` are gaps on `origin/main`; `0134` is the next free number on every branch at the time of writing. Check again before merging.

1. `Location.PlcDeviceType` += **`ScaleStationDigi`**, `ClosureMethodCode = ByWeight`, the same as `ScaleStationEPrint` (so `Terminal_GetClosureContext` / `Terminal_SetClosureMethod` need no change; migration 0105 is the pattern).
2. Code table **`Workorder.ScalePendingPressStatus`**: `Pending`, `Closed`, `Discarded`.
3. **`Workorder.ScalePendingPress`**: one row per held press.

| Column | Type | |
|---|---|---|
| `Id` | `BIGINT IDENTITY` PK | |
| `TerminalLocationId` | `BIGINT` FK `Location.Location` | |
| `ReceivedAt` | `DATETIME2(3)` | UTC, when the press arrived |
| `NetWeight` | `DECIMAL(10,3)` | |
| `Uom` | `NVARCHAR(10)` | |
| `ScalePartCode` | `NVARCHAR(50)` | as sent, trimmed |
| `StatusId` | `BIGINT` FK `ScalePendingPressStatus` | |
| `ResolvedAt` | `DATETIME2(3) NULL` | |
| `ResolvedByAppUserId` | `BIGINT NULL` FK `Location.AppUser` | |
| `ResolvedItemId` | `BIGINT NULL` FK `Parts.Item` | the part picked |
| `FinishedGoodLotId` | `BIGINT NULL` FK `Lots.Lot` | the tray LOT the pick minted |

   - **Filtered unique index** `(TerminalLocationId) WHERE StatusId = Pending`: at most one held press per terminal, enforced by the database.
   - Low volume (a held press is an exception). Not partitioned.
   - Extended properties in `R__Descriptions_ExtendedProperties.sql`.

## 6. Per-press flow (`ScaleDigiWatcher`)

Trigger and guards as the EPrint watcher: `LastReceiveTime` change → `PlcWatcher.dispatchMessage` → `onReceive` (the same `_claim`: duplicate stamp, initial change, stale > 30 s). Then:

1. **Read `MessageBytes` from the device** (`system.opc.readValue` on the member's `OpcServer` / `OpcItemPath`, as `_readMessage` does for `Message`). Decode as ASCII (Jython bytes are signed: `& 0xFF`). No fallback to the tag value.
2. **Parse.** Strip leading and trailing CR / LF / whitespace. Exactly one `(NET)` record is required; none or several is a refusal. Grammar: `(NET)<number><UOM><letters><TWM><digit><Part><text>`. Part is trimmed and may contain spaces and dashes (`12270-6NA -A000`).
3. **Units** not `lb` → refuse (as EPrint).
4. **TWM** not `1` → refuse, "The scale did not pass this tray". Not expected, since the scale sends good presses only.
5. **Held press already waiting** at this terminal → refuse, "A tray is waiting for its part. Choose it on the screen, then press again." Logged.
6. **Resolve the part.** `Parts.Item_GetByPartNumber(<Part>)`, exact match on the trimmed code. A deprecated item (`DeprecatedAt` set; the proc returns those too) counts as no match.
   - **Match, same as the running part** (`ScaleStation_GetRunningPart`) → close.
   - **Match, a different part** → `Location.Terminal_SetScaleRunningPart(terminal, item, SYS)`, then close. If it refuses (another part's box is open, or the part cannot run at this line), refuse the press with its message. Nothing closes. The proc's audit row records the switch.
   - **No match**:
     - the running part is already **determined** (`Source = Override`, or the station has an open box, `OpenContainerId` not NULL) → close as the running part, and log a warning row (`ErrorCondition = ScaleFlagsPartUnknown`, naming the code);
     - otherwise (`Source = Default` or `None`: the MES would only be guessing) → **hold** the press (§7).
7. **Close.** `ContainerConfig_JudgeWeight(item, ByWeight, net)` as a cross-check. If its verdict is not `Ok`, log a warning row (`ErrorCondition = ScaleFlagsMesMismatch`, message with the window). The close goes ahead. Then `Assembly.plcCompleteTray(terminal, "ByWeight")`, logged as today.
8. Broadcast `scalePressRecorded` on every outcome (as EPrint).

**Interface-log payload `v: 2`:** `net`, `uom`, `twm`, `scalePart`, `partSource` (`Scale` | `Running` | `Picked`), `verdict` (`Ok`: the scale's, which decided), `scaleVerdict` (`Ok`), `mesVerdict`, `low`, `high`, `agree` (MES verdict = Ok). `verdict` / `scaleVerdict` / `agree` keep the keys the press log already reads, so `ScaleStation_GetPressLog` needs no change; verify it renders v2 rows.

**Warning rows stay out of the press log** because `GetPressLog` excludes `ErrorCondition LIKE 'ScaleFlags%'`, so every new warning condition carries that prefix: `ScaleFlagsPartUnknown`, `ScaleFlagsMesMismatch`, `ScaleFlagsHeld`.

## 7. A held press

1. **Hold.** `Workorder.ScalePendingPress_Hold(@TerminalLocationId, @NetWeight, @Uom, @ScalePartCode, @AppUserId = SYS)` inserts the `Pending` row. A unique-index collision (a second press racing the first) returns a refusal. Logged in the interface log with `ErrorCondition = ScaleFlagsHeld` (kept out of the press log; the banner shows it, and the pick writes the press's one Closed row). Warning toast at the terminal.
2. **Screen.** The scale station shows a banner while one is pending: "Tray waiting: 15.5 lb. The scale said 'TEST3', which is not a part here. Choose the part:" with **one button per eligible part** (`ScaleStation_ListEligibleParts`), closest to ready first, and a **Discard** button. Read through new `Workorder.ScalePendingPress_GetForTerminal(@TerminalLocationId)`, refreshed by `pressToken`.
3. **Pick.** The operator taps a part (PIN-signed-in, attributed to them; no elevation, like the override):
   1. `Workorder.ScalePendingPress_Claim(@Id, @AppUserId)`: Pending → Closed, conditional on still Pending, so a double tap or two screens cannot close it twice.
   2. `Terminal_SetScaleRunningPart(terminal, item, operator)`. Refused → `ScalePendingPress_Release(@Id)` back to Pending, toast its message.
   3. `plcCompleteTray(terminal, "ByWeight")`. Failed → `Release`, toast.
   4. `ScalePendingPress_Complete(@Id, @ItemId, @FinishedGoodLotId)` stamps the outcome. Interface-log row `partSource = Picked`.
4. **Discard.** `ScalePendingPress_Discard(@Id, @AppUserId)`: Pending → Discarded, audited. For a tray that was taken off and re-weighed.
5. **No expiry.** A held press waits until it is picked or discarded, across shift change. It blocks further presses at that scale, which is the point: the operator cannot weigh past it.

All five are status-row procs (FDS-11-011, `_TEMPLATE_stored_procedure.sql`). Audit rows on Claim / Discard in `Audit.OperationLog` with the house Description shape.

Python orchestrates 3.1-3.4 because `plcCompleteTray` is the existing Python entry point to the close; the rules (one pending, eligibility, no box mixing) stay in SQL.

## 8. Ignition

- **Core:** new `BlueRidge.Workorder.ScaleDigiWatcher` (parse, onReceive, handleMessage, resolve-part, hold, pick, discard). `PlcWatcher.dispatchMessage` gains the `ScaleStationDigi` branch; `ScaleStationEPrint` routing unchanged. `BlueRidge.Workorder.ScaleStation` gains the pending-press reads/actions for the view. NQs for the new procs (Core only).
- **Sim:** a typed-record path for the Digi format (`BlueRidge.Sim`), driving `ScaleDigiWatcher.handleMessage`.
- **Tags:** the Digi reuses the **`ScaleStationEPrint` UDT** (same three driver members; `BasePath` = `2101/`). The device type row, not the UDT, decides the watcher. The device instance needs the `ScaleEPrintMessage` tag-change script's `paths` list to include its `LastReceiveTime`.
- **MPP views:** the pending banner + part buttons in `Components/PlantFloor/ScaleStation` (existing view: file edit only when it is not open in a Designer).

## 9. Commissioning a head

1. Digi One SP on the scale's serial port, raw TCP 2101. One client only: close any capture first.
2. Ignition TCP device: Character Based, `\r`, Field Count 1, Inactivity Timeout 0, no writeback.
3. UDT instance + `TerminalPlcDevice` row of type `ScaleStationDigi` + tag-change path.
4. **One press on each part in the head's target table.** Confirm the `<Part>` code matches the MES part number. If it doesn't, either fix the target table at the scale or live with the picker for that part.

## 10. Tests

- `tools/test_scale_digi_watcher.py`: the bench record; leading `\n\n`; trailing CR; a record reassembled from fragments; two records in one message; no record; TWM 0; lowercase / other units; part with spaces and dashes; empty part; signed byte decoding. Watcher paths with stubs: match same, match switch, switch refused, unknown + determined, unknown + hold, pending blocks, MES-mismatch warning row, payload keys.
- `tools/test_scale_eprint_watcher.py` unchanged and passing.
- `sql/tests`: migration objects; Hold / one-pending rule; Claim (twice → second refused); Release; Complete; Discard; GetForTerminal; PressLog renders v2 rows. Full `Run-Tests.ps1`, assertion count before and after.
- Dev end to end: `digiTest` (`172.17.20.165:2101`) bound to a Dev terminal; real presses on a matched part close; `TEST3` holds, a pick closes it.

## 11. Out of scope

- Counting bad presses (I/O module idea parked in the findings note).
- A scale-code → item mapping table. Revisit if commissioning finds heads whose codes cannot be fixed at the scale.
- Retiring the EPrint watcher.

## 12. Calls made by the builder (not decided by Jacques)

- Reusing the `ScaleStationEPrint` UDT rather than a new one.
- Exact part-number match only (no space-insensitive match).
- An unknown code with an open box or an operator override closes as the running part (logged) instead of holding.
- A press arriving while one is held is refused, not queued.
- Held presses never expire.

## Revision History

| Rev | Date | Author | Change |
|---|---|---|---|
| 1 | 2026-11-19 | Blue Ridge / Claude | Initial design after Jacques's answers. |
