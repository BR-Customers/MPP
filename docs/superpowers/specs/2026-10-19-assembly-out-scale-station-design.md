# Assembly Out, By Weight: Scale Station Screen — Design Spec

**Date:** 2026-10-19
**Status:** Built on Dev 2026-10-20 (branch `claude/scale-station`, plan `docs/superpowers/plans/2026-10-19-assembly-out-scale-station.md`), verified with simulated presses. Not yet wired into the Assembly Out view (Designer step) and not deployed to prod.
**Author:** Blue Ridge (with Claude)
**Arc / Phase:** Arc 2 (Plant Floor) — Machining & Assembly checkweigh.
**Builds on:** `docs/superpowers/specs/2026-08-31-ind570-eprint-demand-output-design.md` (EPrint transport, rev 2 option C).
**Mockup:** Artifact "Assembly Out - Scale Station" (two screens: after a good close; refused press with the part override open).

---

## 1. Why

The office scale test (2026-10-19) proved the EPrint path end to end: under, over and in-range presses were judged, closed or refused, and labelled. The Assembly Out screen showed none of it. The only visible change after a good close was the Line Inventory dock.

What the trace of `Views/ShopFloor/AssemblyNonSerialized` found:

1. **Everything on the screen reads the station's open box.** A scale close already pushes `inventoryChanged` and the view refreshes. But with 1 tray per box, every close completes the box in the same transaction, so the re-read finds no open box and the screen falls back to "No part in production" / "No open container".
2. **"PartsPerTray = 0" means no selected part.** The view's selection is set once at page load. In By Weight there is no way to pick a part: the part dropdown sits in the By Count form, which is hidden.
3. **The screen and the scale pick the part by different rules.** The screen uses the top-ranked eligible finished good (`getRecommendedFinishedGoodId`). The scale close uses the first-ranked one that has a By Weight pack-out (`_recommendedWithPackout`) and never reads the screen. They agree on the 6MA oil pan line only because it has one eligible part.
4. **Weigh & Close Tray can never be enabled.** Its enabled expression reads `Weight/InMotion`, `Weight/IsValid` and `Setpoint/State`, members of the retired Modbus UDT. Over EPrint the MES cannot request a weighment (EPrint spec §6.3), so the control and its "press Weigh & Close Tray" text are dead.
5. **A refused press leaves no production record.** Under, over, wrong units or an unreadable print exist only as a free-text `Audit.InterfaceLog` row, and that row cannot be tied reliably to a terminal (its only handle is the tag instance name, and the device mapping it resolves through changes — it was repointed on 2026-10-19), to a part (text inside the payload), or to the production record a good press made (a printed Python dict in `ResponsePayload`).

## 2. Decisions

1. **No new event table.** The interface log is the record of every integration call, so it is the record of every press. It gets the structured context it is missing (§3) and the screen reads it.
2. **`Audit.InterfaceLog` gains three nullable context columns**: `LocationId`, `ItemId`, `LotId`. Shift is not stored: it is derived from `LocationId` + `LoggedAt` through `Oee.ufn_ShiftIdForInstant`, the way the rest of the system attributes shift.
3. **Integration payloads become JSON**, read in SQL with `JSON_VALUE`. Each integration keeps its own keys without a column per value.
4. **One rule decides the running part, in SQL**, used by both the scale close and the screen. An **audited per-terminal override** lets an operator run a different eligible part. It is stored as a terminal `LocationAttribute`, beside `CurrentClosureMethod`.
5. **Weigh & Close Tray is removed**, with its stale text and its `scaleInstancePath` binding.
6. **The screen shows what the scale will do and what it just did**: running part, last press, press log, shift tally, recent boxes, scale health. See the mockup.

## 3. Schema — migration `0113_interfacelog_context.sql`

`0109`–`0112` are taken on `jacques/controlled-run-super-lot`. `0113` avoids a collision when the two branches meet.

```sql
ALTER TABLE Audit.InterfaceLog ADD
    LocationId BIGINT NULL CONSTRAINT FK_InterfaceLog_Location REFERENCES Location.Location(Id),
    ItemId     BIGINT NULL CONSTRAINT FK_InterfaceLog_Item     REFERENCES Parts.Item(Id),
    LotId      BIGINT NULL CONSTRAINT FK_InterfaceLog_Lot      REFERENCES Lots.Lot(Id);

CREATE INDEX IX_InterfaceLog_Location_LoggedAt
    ON Audit.InterfaceLog (LocationId, LoggedAt DESC)
    WHERE LocationId IS NOT NULL
    ON ps_MonthlyUtc (LoggedAt);
```

- `InterfaceLog` is born partitioned on `ps_MonthlyUtc` (B2). Adding nullable columns is metadata-only. The new index is **partition-aligned** so the sliding-window `TRUNCATE` keeps working (`project_mpp_partition_aligned_pk`). Verify the filtered index is aligned before relying on it.
- FKs point **out** of the audit table, which does not block partition truncation. Nothing references `InterfaceLog`.
- Meaning, for any writer:
  - `LocationId` — the place the call was made **for**: the terminal for a scale or PLC watcher, the terminal that requested the print for a label.
  - `ItemId` — the part the call concerned, when there was one.
  - `LotId` — the production record the call **produced or acted on**: the finished-good LOT a tray close minted; the LOT a label was printed for.
- Existing rows stay NULL. No backfill: ~50 Dev scale rows from testing, and nothing on prod writes PLC scale rows yet.
- Extended properties for the three columns go in `R__Descriptions_ExtendedProperties.sql`.

`Audit.Audit_LogInterfaceCall` gains `@LocationId`, `@ItemId`, `@LotId` (all `= NULL`). It stays silent (no result set). Its NQ (`audit/Audit_LogInterfaceCall`) gains the three parameters. `PlcWatcher.logInterface` gains matching optional keyword arguments. All other callers are unchanged and write NULL.

## 4. The scale watcher's log rows

Every press writes one row, as today. Changes:

- `LocationId` = the terminal, always (known before parsing).
- `ItemId` = the finished good, once `resolvePlcCloseContext` has resolved it (NULL on a refusal before that: unreadable print, wrong units, no eligible part).
- `LotId` = the minted finished-good LOT on a good close, read from the `Assembly_CompleteTray` result (`FinishedGoodLotId`).
- `RequestPayload` becomes JSON. The keys:

```json
{"v":1,"net":49.9,"uom":"lb","cam":null,
 "flags":{"under":0,"over":0,"ok":1},"flagsState":"read",
 "verdict":"Ok","low":48.0,"high":52.0,
 "scaleVerdict":"Ok","agree":true}
```

  Keys that were not reached are omitted. For example, a wrong-units refusal has no `verdict`. `v` versions the shape.
- `ResponsePayload` becomes the close result as JSON (`system.util.jsonEncode`), not `str(dict)`.
- **One row per press stays the rule for the press log.** The separate `Scale flags warning` row (rev 2 §5.4) is kept for the interface-log viewers, carries the same `LocationId` / `ItemId`, and is excluded from the press log by its `ErrorCondition LIKE 'ScaleFlags%'`.

The Zebra label writer should fill `LocationId` (the requesting terminal) and `LotId` the same way. That is a follow-up, not part of this build.

## 5. Running part — one rule, in SQL

New read proc **`Workorder.ScaleStation_GetRunningPart(@TerminalLocationId)`**, returning one row: `ItemId`, `PartNumber`, `Description`, `Source` (`Override` | `Default` | `None`), `PartsPerTray`, `TraysPerContainer`, `TargetWeight`, `ToleranceWeight`, `LowLimit`, `HighLimit`, `EligibleCount`, `Message`.

Resolution:
1. The station's own open By Weight box, if any → its part (`Default`: an open box always wins, so a box is never split across parts).
2. Else the terminal's override (§6), if that part is still eligible → `Override`.
3. Else the **eligible** finished good closest to ready (§5.1) → `Default`.
4. Else `None` with a `Message` naming what is missing.

`resolvePlcCloseContext(terminal, "ByWeight")` calls this proc instead of `_recommendedWithPackout`, so the scale and the screen cannot disagree. ByVision keeps its current path until it gets the same treatment. The rule moving out of Python is in line with `feedback_no_business_logic_in_python`.

`EligibleCount` = the number of eligible parts (§5.1). It drives the "Change part (N can run)" button, which is hidden when `EligibleCount <= 1`.

### 5.1 Eligible, and closest to ready (Jacques, 2026-10-19)

A finished good is **eligible** at the terminal's line when all of these hold:
- It is already eligible to be built at that line: `Parts.v_EffectiveItemLocation` places it at the line or one of its ancestors, the same base filter `Item_ListEligibleFinishedGoodsRanked` uses. Stock alone never makes a part runnable at a line it isn't set up for.
- It has a By Weight pack-out with `PartsPerTray > 0`.
- The line has **at least one** of its **raw cast goods** in inventory (Jacques, 2026-10-19).
- The line has **at least 60% of its other BOM lines** in inventory.

The default is the eligible part **closest to ready**: the highest share of BOM lines covered. Ties go to the existing order (earliest ready stock, then part number).

Definitions, from the published BOM and the item types:
- **Raw cast good** = a BOM line whose child is `Component` or `SubAssembly`. On Dev, every `Component` child (40) has a die-cast route and every `SubAssembly` child (26) is a machined casting. `PassThrough` children (33) are bought parts.
- **Covered** = unblocked stock at the line of at least `QtyPer × PartsPerTray`, enough for one tray close. A close consumes a whole tray at once (Jacques, 2026-10-19).
- **Share covered** = covered lines ÷ all BOM lines.
- A finished good with **no cast line** (pass-through repack: 10 on Dev) passes the cast test only on its own received stock, the rule `Item_ListEligibleFinishedGoodsRanked` v1.1 already uses.

The 60% threshold is a number in the proc, not a setting, until there is a reason to tune it per line.

This is a new rule beside `Item_ListEligibleFinishedGoodsRanked`, not a change to it. The By Count dropdown keeps its current ranking.

## 6. Part override

- Stored as terminal `LocationAttribute` **`ScaleRunningItemId`** (new `LocationAttributeDefinition` on the Terminal definition, seeded in `0113`). The value is the `Parts.Item.Id` as text, the same pattern as `CurrentClosureMethod`.
- Set through new **`Location.Terminal_SetScaleRunningPart(@TerminalLocationId, @ItemId NULL, @AppUserId)`**, a status-row mutation proc (FDS-11-011):
  - `@ItemId = NULL` clears the override, back to the default.
  - It refuses a part that is not eligible (no By Weight pack-out, not buildable at the line).
  - It refuses while the station has an open By Weight box of another part: finish or close that box first.
  - Audited: `Audit.ConfigLog` with the house Description shape: `<terminal> · Scale running part · <old part> -> <new part>`.
- Lifetime: until someone changes or clears it. It survives shift change (Jacques, 2026-10-19).
- Who: any PIN-signed-in operator. No elevation; the audit row is the control (Jacques, 2026-10-19).
- The picker lists `Workorder.ScaleStation_ListEligibleParts(@TerminalLocationId)`: every eligible part (§5.1), closest to ready first, with part, description, pack-out, window, share of BOM lines covered, and whole trays the line's stock covers.

## 7. Reads for the screen

All read procs, one result set each, timestamps converted to Eastern at the boundary.

| Proc | Returns |
|---|---|
| `Workorder.ScaleStation_GetPressLog(@TerminalLocationId, @Top = 20)` | One row per press, newest first: `LoggedAtEt`, `Net`, `Uom`, `Verdict`, `Low`, `High`, `ScaleVerdict`, `FlagsAgree`, `Outcome` (`Closed` / `Refused` / `Failed`), `Detail` (`ErrorDescription` on a refusal), `LotId`, `LotName`, `ContainerId`, `AimShipperId`, `LabelStatus`. Source: `Audit.InterfaceLog WHERE LocationId = @t AND SystemName LIKE N'PLC:%' AND (ErrorCondition IS NULL OR ErrorCondition NOT LIKE N'ScaleFlags%')`, with JSON fields via `JSON_VALUE`. `LEFT JOIN Lots.Lot` → `Lots.ContainerTray` (`FinishedGoodLotId`) → `Lots.Container` → `Lots.ShippingLabel` for the box, AIM ID and label status of a closed press. Rows without `v` in the payload (pre-0113) are skipped. |
| `Workorder.ScaleStation_GetShiftTally(@TerminalLocationId)` | For the current shift at the terminal (`Oee.ufn_ShiftIdForInstant` / `ufn_ShiftWindowForLocation`): `TraysClosed`, `PartsPacked`, `BoxesCompleted`, `Refused`, `RefusedUnder`, `RefusedOver`, `RefusedOther`. Closes from production records (`Lots.ContainerTray` by terminal via `Container.StationLocationId`), refusals from the interface log, so a manual close by count is counted too. |
| `Workorder.ScaleStation_GetRecentBoxes(@TerminalLocationId, @Top = 5)` | Completed boxes at this station: `ContainerId`, `CompletedAtEt`, `Pieces`, `LotName`, `AimShipperId`, `LabelStatus` (`Sent` / `Failed` / `Reprinted`, from `ShippingLabel.LastPrintErrorCondition` and reprint history). |
| `ScaleStation_GetRunningPart` | §5. |

"Last press" on the screen is row 1 of the press log, so no separate proc.

## 8. The screen

`Views/ShopFloor/AssemblyNonSerialized` in By Weight mode. Layout per the mockup:

0. **Open box** (when the station has one): "Box #20041 · tray 7 of 16 · 420 of 960 parts", with a progress bar. Most By Weight pack-outs are multi-tray: 14 of the 20 on Dev are 4 to 24 trays per box, and only 6 are 1 tray per box. So a box is usually open across many presses, and this is the operator's main progress view. Mockup screen "Multi-tray box in progress (16 x 6)" uses 19321-66V -A000. It shows a 16-cell tray strip, parts and trays to go, and "label prints when tray 16 closes". Each tray close mints its own LOT, so the last-press card shows the tray and LOT, and the label line appears only on the box-completing tray.
1. **Running part banner** (`GetRunningPart`): part, description, source line ("Default: …" / "Override set by JGP at 2:41 PM"), pack-out tiles (parts per tray, trays per box, window), **Change part (N can run)**. `Source = None` shows the `Message` in the banner in red.
2. **Last press card**:
   - The large net weight and an OK / UNDER / OVER pill.
   - A window gauge.
   - The outcome line: "Tray closed · LOT … · Box #… complete · Label sent to <printer> (2 copies)", or "Not closed: 16.5 lb under the window…".
   - "Scale agrees / differs" in small type.

   The card is amber for UNDER, red-orange for OVER, and neutral for OK.
3. **This shift at this scale** (`GetShiftTally`).
4. **Press log** (`GetPressLog`, 10 visible): time, net, verdict, outcome, scale flags. A ⚑ marks `FlagsAgree = 0`, for supervisors.
5. **Recent boxes** (`GetRecentBoxes`) with **Reprint** per row (opens the existing `ShippingLabelReprint` popup).
6. **Scale strip**: connection state and last message time from the instance's `LastReceiveTime` / device connection, plus the instruction "Tare the container, load the tray, then press the button on the scale."

**Removed:** `WeighCloseTrayButton`, its enabled expression, the "Waiting for scale - press Weigh & Close Tray…" text, and `custom.scaleInstancePath`. The By Count and By Vision layouts are unchanged.

**Live update.** The watcher already broadcasts `inventoryChanged` after a good close. Add a page-scoped **`scalePressRecorded`** broadcast `{terminalLocationId}` after **every** press, refusals included, through `PlcWatcher.broadcastPageMessage`. The view's handler matches its own terminal and bumps a `pressToken` that the four reads above key on. The refusal toast stays as it is.

**Existing view, edited in Designer** (CLAUDE.md file-edit boundary). The new cards are best built as new embedded views under `Components/PlantFloor/ScaleStation/…` (new files are safe to author on disk), placed into the By Weight pane in Designer.

## 9. Tests

- `sql/tests`:
  - `Audit_LogInterfaceCall` writes and omits the three columns.
  - `ScaleStation_GetRunningPart`: open-box precedence; override honoured, and ignored once ineligible; default by ranking; `None`.
  - `Terminal_SetScaleRunningPart`: set, clear, refuse ineligible, refuse with another part's open box, audit row.
  - `GetPressLog`: closed / refused / failed rows; flags-warning rows excluded; pre-`v` rows skipped; ET conversion.
  - `GetShiftTally` within and outside the current shift.
  - `GetRecentBoxes` label status.
- `tools/test_scale_eprint_watcher.py`: the JSON payload keys per path; `LocationId` / `ItemId` / `LotId` passed to `logInterface`; `scalePressRecorded` sent on refusals and closes.
- Dev: an under, over and good press on the office scale. Each appears in the press log with its outcome, the tally moves, and the box shows with its label status. A second eligible part: override set, the next close mints that part, the audit row is present.

## 10. Out of scope

- The Zebra label writer's context columns (§4, follow-up).
- ByVision's part resolution (keeps `_recommendedWithPackout` until it gets the same treatment).
- Backfilling pre-0113 interface-log rows.
- A supervisor report of flag disagreements across terminals (the interface log can answer it with one query once `LocationId` exists).

## 11. Open questions

| # | Question | Blocks |
|---|---|---|
| 1 | ~~Override lifetime~~. **Resolved 2026-10-19:** until someone changes it. | — |
| 2 | ~~Elevation~~. **Resolved 2026-10-19:** PIN sign-in plus an audit row. | — |
| 3 | ~~Eligibility~~. **Resolved 2026-10-19:** raw cast good plus at least 60% of other BOM lines in inventory, closest to ready by default (§5.1). | — |
| 4 | ~~Trays per box~~. **Resolved 2026-10-19** from the configs: 14 of 20 By Weight pack-outs are multi-tray, so the open box gets its own card (§8 item 0). | — |
| 5 | ~~Covered threshold~~. **Resolved 2026-10-19:** one full tray, `QtyPer × PartsPerTray`. | — |
| 6 | ~~Several cast lines~~. **Resolved 2026-10-19:** at least one cast line covered; the rest count toward the 60%. | — |

## Revision History

| Rev | Date | Author | Change |
|---|---|---|---|
| 2 | 2026-10-19 | Blue Ridge / Claude | Jacques's answers. The override persists until changed, and is set by PIN with an audit row. Eligibility is the raw cast good plus at least 60% of the other BOM lines, closest to ready by default (§5.1). An open-box card is added, since 14 of 20 By Weight pack-outs are multi-tray. New open questions 5 and 6. |
| 1 | 2026-10-19 | Blue Ridge / Claude | Initial draft after the office scale test. No new event table: `Audit.InterfaceLog` gains `LocationId` / `ItemId` / `LotId` and JSON payloads; one SQL rule for the running part plus an audited per-terminal override; Weigh & Close removed. |
