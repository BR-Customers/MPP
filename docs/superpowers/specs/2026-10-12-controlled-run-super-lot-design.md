# Controlled Run (super-lot) — the case, its members, its label, its view

> **Status: DRAFT 2026-10-12. NOT APPROVED. NOT BUILT.** First of six pieces; context and
> the other five are in `notes/2026-10-12_crt-super-lot-and-nonconformance-overview.md`.
> Section 9 records Jacques's answers of 2026-10-12 and the one decision still open.
> **All six pieces ship together** -- nothing here is released on its own. Mockups come
> before the plan: `mockup/controlled_run_super_lot_mock.html`.

**Author:** Blue Ridge Automation (Jacques Potgieter, with Claude)
**Scope tag:** Change order — outside the accepted baseline.

---

## 1. Problem

CRT today is a bit on one LOT. Each LOT is tagged alone, released alone, and nothing
records that forty baskets and twelve containers were tagged for the same reason on the
same afternoon.

MPP work in groups. A customer reports a problem traced to one LOT; MPP put everything
produced from that LOT up to now on CRT, then inspect and disposition the whole set.
They call the set a **super-lot**. The system has no object for it, so there is nothing
to label, nothing to list, nothing to release as a unit, and nothing to hang an
inspection outcome or a deviation on.

This spec adds that object and nothing else. It is the structure the later pieces
(retroactive tagging of finished containers, results and sign-off, repack, rework and
return, visibility) attach to.

## 2. Scope

**In:**

- A stored case, the **Controlled Run**, with a number, a reason, and its selection
  criteria.
- A stored member list of LOTs and containers.
- Selecting members by part, production line, time window, genealogy, or by hand.
- An open-ended window: while the run is open and set to auto-join, new production that
  matches joins it.
- A Controlled Run label.
- A dedicated Quality view to open, review, extend, label and close runs.

**Out (later pieces — do not build here):**

| Not here | Piece |
|---|---|
| Tagging a container whose finished-good LOTs are already Closed; AIM consequences | 2 |
| Bulk release, the "200% inspection completed" confirmation, per-member results, signature record, Quality-only role gate, the deviation (nonconformance) record | 3 |
| Scrap from a Closed LOT; container top-up, re-serial, relabel | 3 / 4 |
| Rework, Return to Vendor | 5 |
| Run number on Lot Detail, genealogy, reports, dashboards | 6 |

Release in this piece stays exactly as it is today: per LOT on Lot Detail, per container
in the `CrtValidation` popup. A run closes when all its members have been cleared that
way. That makes piece 1 usable on its own and leaves the release redesign to piece 3.

## 3. What is reused unchanged

| Existing | Role here |
|---|---|
| `Lots.Lot.CrtActive` | Still the per-LOT truth and still what every block reads. The run never replaces it. |
| `Lots.ufn_CrtBlocksAdvance` / `ufn_CrtBlocksMoveTo`, `Container_Ship`, `AimShipperIdPool_ListUnposted` | Unchanged. A member is blocked because its bit is set, not because it is a member. |
| `Lots.Lot_ClearCrt`, `Lots.Container_ValidateCrt` | Unchanged. Still how a member is released in this piece. |
| `CrtActivated` / `CrtCleared` audit events (entity `Lot`) | Still written once per LOT, so the 20-year LOT timeline is unaffected by grouping. |
| `CrtBanner` label | Unchanged. The run label is additional. |
| `Lots.IdentifierSequence` | Issues the run number. |
| Elevation (`CrtToggle` precedent) | Same mechanism, new action code. |

## 4. Decisions

| # | Decision | Rationale |
|---|---|---|
| **D1** | **The run is a stored member list, not a rule.** | MPP do not yet know what opens and closes their window. A list is indifferent to how its members were chosen, so the rule can change without a schema change. It is also the only form an audit can trust: the answer to "what was in it" must not depend on re-running a query against data that has since moved. |
| **D2** | **Selection criteria are stored on the header as structured columns.** | They explain why each member is there and they drive auto-join. Structured, not JSON or free text, so they can be validated, displayed and queried. |
| **D3** | **A member is a LOT or a container, never both** (`LotId` XOR `ContainerId`, the `HoldEvent` shape). WIP is listed as LOTs. Packed finished goods are listed as the container; its tray LOTs are implied and are not separate members. | It matches what is physically on the floor and what a label is stuck to. Listing a container's tray LOTs as well would double-count it. |
| **D4** | **A LOT or container is in at most one OPEN run.** Enforced by a filtered unique index. | One physical unit, one open quality case. Two would mean two labels, two releases and an argument about which wins. History is unaffected: a unit can be in many runs over time. |
| **D5** | **Joining a run sets `CrtActive` if it is not already set.** The set is an inlined mirror of `Lots.Lot_SetCrt`, with its own per-LOT `CrtActivated` audit row. | A member that is not blocked is a list entry with no teeth. Inlined, not `EXEC`'d, per the INSERT-EXEC / single-result-set rule. |
| **D6** | **Leaving a run does NOT clear `CrtActive`.** Removing a member is a correction to the list; releasing material is a separate, deliberate act. | Otherwise "remove from run" becomes an unaudited back door around release. |
| **D7** | **Auto-join is two steps: the resolver makes new production CRT at mint; a sync proc records the membership.** `Lots.ufn_CrtForMint` gains a fourth arm: an open auto-join run matches this part (and, when the run names one, this line). `Quality.ControlledRun_SyncAutoJoin` then adds the rows. | Every mint proc already calls the resolver, so one function edit covers all seven mint points with no proc edits. A function cannot insert, hence the second step. The gap between mint and membership is harmless because the block is the bit, which is set in the mint transaction. **(still open — see section 9, item 3)** |
| **D8** | **Sync also pulls in CRT-active descendants of current members** when the run was opened with genealogy on. | CRT already propagates through consumption. Without this a tagged casting's sub-assembly is blocked but belongs to no case. |
| **D9** | **Ending the window is explicit.** `ControlledRun_SetAutoJoin(@Enabled = 0)` stamps `AutoJoinEndedAt`. The run stays open for inspection and release. | "Stop adding to it" and "we are finished with it" are different moments on the floor. |
| **D10** | **A run closes only when no member is still CRT-active.** `ControlledRun_Close` refuses otherwise and says how many are outstanding. | In this piece release is per member. Close is the statement that all of it has been dealt with. Piece 3 replaces this with the signed release. |
| **D11** | **The label belongs to the SUPER-LOT, not to a member.** It is printed on demand, four copies per request, it is built to stand out, and its barcode is the run number. Scanning it opens that super-lot in the Quality view, where every management action lives. | Jacques, 2026-10-12. The label's job is to get Quality from a piece of paper on the floor to the whole case in one scan. It carries no member detail, so it never goes stale as the window rolls and any copy can go on any unit in the group. |
| **D12** | **Internal name `ControlledRun`; on screen and on the label, "Super-lot". `RunNumber` is `NVARCHAR(15)`.** | "Controlled Run" is what the T in CRT is tagging, so the model reads naturally (`ControlledRun` 1-N members, each carrying a Controlled Run Tag). MPP say "super-lot", so that is what they see. Width per Jacques, 2026-10-12. |

### Deliberately not built

- **No window rule engine.** No count, quantity or shift boundaries. The criteria are
  part, line, from-time, to-time, genealogy. A shift is a from/to pair; a count is the
  operator unticking rows in the preview. Add a rule when MPP name one.
- **No origin/category code table** (customer complaint, internal, supplier). `Reason`
  is text in this piece. Piece 3's deviation record is where categorisation belongs.
- **No retroactive part flag.** Opening a run does not switch on `Parts.Item.CrtEnabled`.
  Auto-join achieves the same effect and ends with the run.
- **No nested runs, no merging or splitting of runs.**

## 5. Schema

One versioned migration, next free ordinal at build time (`0109` as of 2026-10-12; check
the directory and `main`). Schema `Quality`.

```sql
CREATE TABLE Quality.ControlledRunStatusCode (      -- read-only code table
    Id   BIGINT        NOT NULL IDENTITY(1,1) PRIMARY KEY,
    Code NVARCHAR(20)  NOT NULL,
    Name NVARCHAR(100) NOT NULL,
    CONSTRAINT UQ_ControlledRunStatusCode_Code UNIQUE (Code)
);  -- 1 Open, 2 Closed, 3 Cancelled

CREATE TABLE Quality.ControlledRunJoinMethod (      -- read-only code table
    Id   BIGINT        NOT NULL IDENTITY(1,1) PRIMARY KEY,
    Code NVARCHAR(20)  NOT NULL,
    Name NVARCHAR(100) NOT NULL,
    CONSTRAINT UQ_ControlledRunJoinMethod_Code UNIQUE (Code)
);  -- 1 Selected (from the preview), 2 Manual (scanned in later), 3 AutoJoined, 4 Descendant

CREATE TABLE Quality.ControlledRunMemberEndReason ( -- read-only code table
    Id   BIGINT        NOT NULL IDENTITY(1,1) PRIMARY KEY,
    Code NVARCHAR(20)  NOT NULL,
    Name NVARCHAR(100) NOT NULL,
    CONSTRAINT UQ_ControlledRunMemberEndReason_Code UNIQUE (Code)
);  -- 1 Removed, 2 RunClosed, 3 RunCancelled   (piece 3 adds the disposition outcomes)

CREATE TABLE Quality.ControlledRun (
    Id                     BIGINT        NOT NULL IDENTITY(1,1) PRIMARY KEY,
    RunNumber              NVARCHAR(15)  NOT NULL,           -- Lots.IdentifierSequence 'ControlledRun'
    ControlledRunStatusId  BIGINT        NOT NULL REFERENCES Quality.ControlledRunStatusCode(Id),
    Reason                 NVARCHAR(500) NOT NULL,
    -- selection criteria (D2). All optional; at least one of them, or a manual list.
    AnchorLotId            BIGINT        NULL REFERENCES Lots.Lot(Id),          -- the suspect LOT
    SelectionItemId        BIGINT        NULL REFERENCES Parts.Item(Id),
    SelectionLocationId    BIGINT        NULL REFERENCES Location.Location(Id), -- production line/area
    SelectionFromAt        DATETIME2(3)  NULL,                                  -- UTC
    SelectionToAt          DATETIME2(3)  NULL,                                  -- UTC; NULL = open-ended
    IncludeDescendants     BIT           NOT NULL CONSTRAINT DF_ControlledRun_IncludeDescendants DEFAULT 0,
    -- rolling window (D7, D9)
    AutoJoinEnabled        BIT           NOT NULL CONSTRAINT DF_ControlledRun_AutoJoinEnabled DEFAULT 0,
    AutoJoinEndedAt        DATETIME2(3)  NULL,
    AutoJoinEndedByUserId  BIGINT        NULL REFERENCES Location.AppUser(Id),
    -- lifecycle
    OpenedByUserId         BIGINT        NOT NULL REFERENCES Location.AppUser(Id),
    OpenedAt               DATETIME2(3)  NOT NULL CONSTRAINT DF_ControlledRun_OpenedAt DEFAULT SYSUTCDATETIME(),
    OpenedAtTerminalId     BIGINT        NULL REFERENCES Location.Location(Id),
    ClosedByUserId         BIGINT        NULL REFERENCES Location.AppUser(Id),
    ClosedAt               DATETIME2(3)  NULL,
    CloseRemarks           NVARCHAR(500) NULL,
    RowVersion             ROWVERSION    NOT NULL,
    CONSTRAINT UQ_ControlledRun_RunNumber UNIQUE (RunNumber),
    CONSTRAINT CK_ControlledRun_ClosePaired CHECK (
        (ClosedByUserId IS NULL AND ClosedAt IS NULL) OR
        (ClosedByUserId IS NOT NULL AND ClosedAt IS NOT NULL)),
    -- auto-join needs a part to match on; "everything at a line" is too wide to leave open
    CONSTRAINT CK_ControlledRun_AutoJoinNeedsItem CHECK (
        AutoJoinEnabled = 0 OR SelectionItemId IS NOT NULL)
);
CREATE INDEX IX_ControlledRun_Open ON Quality.ControlledRun (ControlledRunStatusId, OpenedAt)
    WHERE ControlledRunStatusId = 1;
-- the lookup ufn_CrtForMint's fourth arm makes on EVERY mint: keep it a seek on a tiny set
CREATE INDEX IX_ControlledRun_AutoJoin ON Quality.ControlledRun (SelectionItemId)
    INCLUDE (SelectionLocationId)
    WHERE ControlledRunStatusId = 1 AND AutoJoinEnabled = 1;

CREATE TABLE Quality.ControlledRunMember (
    Id                     BIGINT        NOT NULL IDENTITY(1,1) PRIMARY KEY,
    ControlledRunId        BIGINT        NOT NULL REFERENCES Quality.ControlledRun(Id),
    LotId                  BIGINT        NULL REFERENCES Lots.Lot(Id),
    ContainerId            BIGINT        NULL REFERENCES Lots.Container(Id),
    ControlledRunJoinMethodId BIGINT     NOT NULL REFERENCES Quality.ControlledRunJoinMethod(Id),
    CrtSetByRun            BIT           NOT NULL,   -- 1 = joining set the tag; 0 = it was already tagged
    AddedByUserId          BIGINT        NOT NULL REFERENCES Location.AppUser(Id),
    AddedAt                DATETIME2(3)  NOT NULL CONSTRAINT DF_ControlledRunMember_AddedAt DEFAULT SYSUTCDATETIME(),
    EndedAt                DATETIME2(3)  NULL,       -- NULL = currently a member
    EndedByUserId          BIGINT        NULL REFERENCES Location.AppUser(Id),
    ControlledRunMemberEndReasonId BIGINT NULL REFERENCES Quality.ControlledRunMemberEndReason(Id),
    EndRemarks             NVARCHAR(500) NULL,
    CONSTRAINT CK_ControlledRunMember_LotXorContainer CHECK (
        (LotId IS NOT NULL AND ContainerId IS NULL) OR
        (LotId IS NULL AND ContainerId IS NOT NULL)),
    CONSTRAINT CK_ControlledRunMember_EndPaired CHECK (
        (EndedAt IS NULL AND EndedByUserId IS NULL AND ControlledRunMemberEndReasonId IS NULL) OR
        (EndedAt IS NOT NULL AND EndedByUserId IS NOT NULL AND ControlledRunMemberEndReasonId IS NOT NULL))
);
-- D4: one OPEN membership per unit, across all runs
CREATE UNIQUE INDEX UX_ControlledRunMember_OpenLot
    ON Quality.ControlledRunMember (LotId) WHERE EndedAt IS NULL AND LotId IS NOT NULL;
CREATE UNIQUE INDEX UX_ControlledRunMember_OpenContainer
    ON Quality.ControlledRunMember (ContainerId) WHERE EndedAt IS NULL AND ContainerId IS NOT NULL;
CREATE INDEX IX_ControlledRunMember_Run ON Quality.ControlledRunMember (ControlledRunId, EndedAt);

CREATE TABLE Quality.ControlledRunLabel (           -- append-only print log, one row per print request
    Id                    BIGINT        NOT NULL IDENTITY(1,1) PRIMARY KEY,
    ControlledRunId       BIGINT        NOT NULL REFERENCES Quality.ControlledRun(Id),
    Copies                INT           NOT NULL,   -- 4 per request (D11)
    ZplContent            NVARCHAR(MAX) NOT NULL,
    PrinterName           NVARCHAR(100) NULL,
    PrintedByUserId       BIGINT        NOT NULL REFERENCES Location.AppUser(Id),
    TerminalLocationId    BIGINT        NULL REFERENCES Location.Location(Id),
    PrintedAt             DATETIME2(3)  NOT NULL CONSTRAINT DF_ControlledRunLabel_PrintedAt DEFAULT SYSUTCDATETIME()
);
```

Why a member carries its own `EndedAt` and the uniqueness is not derived from the run's
status: a filtered index cannot look at a parent row. Closing a run stamps every still-open
member `RunClosed` in the same transaction, which is also what frees those units to join a
later run.

Why a new label log and not `Lots.LotLabel`: `LotLabel.LotId` is `NOT NULL`, and this
label belongs to the run, not to any LOT.

**Seeds in the migration** (ASCII-only, idempotent):

- The three code tables above.
- `Lots.IdentifierSequence` row `ControlledRun`, format `CR{0:D6}` (8 characters; the
  column allows 15).
- `Lots.LabelTypeCode` `ControlledRun` + one active `Lots.LabelTemplate` (section 7).
- `Audit.LogEntityType` `ControlledRun`; `Audit.LogEventType` `ControlledRunOpened`,
  `ControlledRunMemberAdded`, `ControlledRunMemberRemoved`, `ControlledRunWindowEnded`,
  `ControlledRunClosed`. Explicit ids, next free at build time (those PKs are not
  identity).
- Extended-property descriptions for every table and column (the ERD is generated from
  them).

## 6. Procedures

All in `Quality`, all to the project template: no `OUTPUT` parameters, one result set,
every rejecting validation before `BEGIN TRANSACTION`, `CATCH` the only `ROLLBACK` site.

### Reads

| Proc | Returns |
|---|---|
| `ControlledRun_PreviewSelection` | The candidate list for a set of criteria. Nothing is written. See below. |
| `ControlledRun_List(@StatusCode, @ItemId, @Text)` | Runs with part, reason, opened (ET), open/cleared/total member counts, auto-join state. |
| `ControlledRun_Get(@Id)` / `_GetByNumber(@RunNumber)` | One header. Empty set = not found. |
| `ControlledRun_ListMembers(@Id, @IncludeEnded)` | Kind, id, LOT name or container id, part, current location, piece count, `CrtActive` now, join method, added (ET). For a container, "CRT active" means any of its tray LOTs is. |
| `ControlledRun_GetOpenByMember(@LotId, @ContainerId)` | The open run a unit belongs to, if any. Used by the scan box, and by piece 6. |

**`ControlledRun_PreviewSelection(@AnchorLotId, @ItemId, @LocationId, @FromAt, @ToAt,
@IncludeDescendants)`** builds the candidate set as the union of:

1. **By production:** LOTs of `@ItemId` minted at a terminal at or under `@LocationId`
   (`Lot.CreatedAtTerminalId`, descendant walk as in `Lot_GetWipQueueByLocation`) with
   `CreatedAt` in the window.
2. **By genealogy** (when `@IncludeDescendants = 1`): every descendant of `@AnchorLotId`
   from `Lots.LotGenealogyClosure`, plus the anchor itself.

It then folds finished-good tray LOTs up to their container (D3) and returns one row per
candidate, ordered oldest first, with:

`Kind, LotId, ContainerId, DisplayName, PartNumber, CurrentLocationName, StatusCode,
PieceCount, ProducedAt (ET), CrtActive, Eligible, IneligibleReason`

A candidate is **ineligible**, and says why, when it is: Scrap; Shipped; already in
another open run (the reason names that run's number); or a Closed LOT that is not a
tray of an unshipped container. A completed, unshipped container IS eligible (9.2).
Ineligible rows are shown, not hidden — "these twelve already
left the building" is exactly what Quality needs to see when the window is drawn.

When no `@FromAt` is given and an anchor is, the window starts at the anchor's
`CreatedAt`. When no `@ToAt` is given it ends now.

### Mutations

| Proc | Does |
|---|---|
| `ControlledRun_Open(@Reason, criteria…, @AutoJoinEnabled, @MembersJson, @AppUserId, @TerminalLocationId)` | Bundled save, as `LocationTypeDefinition_SaveAll`: issues the run number, inserts the header, inserts every member in `@MembersJson` (`[{"lotId":n}|{"containerId":n}, …]`), sets `CrtActive` where needed (D5), audits. All or nothing. Re-validates eligibility itself; the preview is advice, this is the guard. Returns `Status, Message, NewId`. |
| `ControlledRun_AddMembers(@Id, @MembersJson, …)` | Same member logic against an open run. Join method `Manual`. |
| `ControlledRun_RemoveMember(@MemberId, @Remarks, …)` | Ends the membership as `Removed`. Remarks required. Does not touch `CrtActive` (D6); the message says so when the tag is still set. |
| `ControlledRun_SyncAutoJoin(@Id = NULL, @AppUserId)` | For one open run, or all of them: adds CRT-active LOTs that match the run's part and line, were minted after the run opened and before `AutoJoinEndedAt`, and are not in an open run (`AutoJoined`); and, when `IncludeDescendants = 1`, CRT-active descendants of current members (`Descendant`). A finished-good tray LOT is folded up to its container exactly as in the preview (D3), so the container joins once, not once per tray. Idempotent. Returns `Status, Message` with the count added. |
| `ControlledRun_SetAutoJoin(@Id, @Enabled, …)` | Runs a final sync, then switches the window off and stamps `AutoJoinEndedAt` (D9). Switching it back on is allowed while the run is open and clears the stamp. |
| `ControlledRun_Close(@Id, @Remarks, …)` | Runs a final sync. Refuses if any member is still CRT-active, or if auto-join is still on (D10). Otherwise stamps the header and ends every open member as `RunClosed`. |
| `ControlledRun_Cancel(@Id, @Remarks, …)` | For a run opened by mistake. Ends every open member as `RunCancelled`. **Does not clear `CrtActive`** — it lists the members still tagged in the message so they can be cleared deliberately. |
| `ControlledRunLabel_Print(@Id, @PrinterName, ...)` | Renders the run label, logs one row, returns the ZPL for four copies (section 7). |

**Member insert, shared by `_Open`, `_AddMembers` and `_SyncAutoJoin`.** For a LOT: set
`CrtActive = 1` if it is 0, write the per-LOT `CrtActivated` audit row, record
`CrtSetByRun`. For a container: do the same to each of its tray LOTs that is not Closed.
A completed container, whose tray LOTs ARE Closed, is still accepted as a member; tagging
it is piece 2, which ships in the same release (9.2).
This block is an inlined mirror of `Lots.Lot_SetCrt` and must be commented as such in
each proc.

**Sync is called** when the view loads a run, before `_SetAutoJoin` and `_Close`, and
from a gateway timer (system user, `Common.Util.systemAppUserId()`), committed disabled
per the timer convention.

### The resolver change

`Lots.ufn_CrtForMint` v1.1 gains a fourth `OR EXISTS`:

```sql
-- (4) An open auto-join Controlled Run covers this part at this line.
OR EXISTS (SELECT 1
             FROM Quality.ControlledRun r
            WHERE r.ControlledRunStatusId = 1
              AND r.AutoJoinEnabled = 1
              AND r.SelectionItemId = @ItemId
              AND (r.SelectionLocationId IS NULL
                   OR EXISTS (/* @TerminalLocationId is at or under r.SelectionLocationId */)))
```

No mint proc changes. `Quality.ControlledRun` is created by a versioned migration, which
runs before any repeatable, so the function's `zz_` deploy-order marker still holds.

This is the one edit in this piece that touches every mint in the plant. It must stay a
seek on `IX_ControlledRun_AutoJoin` (normally zero rows), and the test suite must prove
that with no open auto-join run the function's result is unchanged for every existing
case.

### Audit

Run events go through `Audit.Audit_LogOperation` with entity `ControlledRun`, following
`<SUBJECT> · <CATEGORY?> · <ACTION>` with the middle-dot function and resolved-name JSON:

- `CR000123 · Opened: 14 LOTs, 6 containers`
- `CR000123 · Members · + MESL3000456, + Container 8812`
- `CR000123 · Members · - MESL3000456: scanned in error`
- `CR000123 · Window · Ended`
- `CR000123 · Closed`

Each LOT whose tag the run sets still gets its own `CrtActivated` row as entity `Lot`,
so nothing about a LOT's own timeline depends on knowing it was in a run.

## 7. The label

New `Lots.LabelTypeCode` `ControlledRun`, one active `Lots.LabelTemplate`. The body is
data, editable through the existing template path, ASCII only.

**One label design per super-lot, four copies per print request, printed on demand**
(D11). Nothing prints automatically when a run opens or when a member joins.

Tokens (substituted in SQL, same convention as the LTT templates):

| Token | Value |
|---|---|
| `{RunNumber}` | Human-readable, large, and as a Code 128 barcode |
| `{PartNumber}` | The run's part (`SelectionItemId`); blank when the run names none |
| `{Reason}` | Truncated to fit one field block |
| `{OpenedAt}` | Eastern time |
| `{OpenedBy}` | Initials |

**It has to stand out.** Layout: a solid black band across the top with `SUPER-LOT`
reversed out of it in white; the run number in the largest type on the label; the
run-number barcode full width; then part, reason and the opened line in small type; a
solid black band along the bottom reading `QUALITY - DO NOT USE - SCAN FOR STATUS`.
Same 4-inch, 203 dpi stock the `CrtBanner` assumes. It begins with `^LH0,0` for the reason
documented in migration `0066`, and the four copies are `^PQ4` in the one document.

No member name and no member count: any of the four copies can go on any unit in the
group, and a count would be wrong as soon as the window rolled.

**The barcode is the way in.** It encodes the run number and nothing else. The scan box
on the Quality view resolves it through `ControlledRun_GetByNumber` and opens that
super-lot. Scanning it at a production terminal is not handled in this piece; the
existing CRT block already stops the material there.

Dispatch uses the existing label print path. Which printer a Quality terminal prints to,
and whether the current dispatcher needs anything new for a label that is not a
`LotLabel` or a `ShippingLabel`, is to be confirmed when the plan is written -- that
path has not been traced.

## 8. The view

New page `/shop-floor/controlled-runs`, view `BlueRidge/Views/ShopFloor/ControlledRuns`
(new folder, so file-authored), with its row and wizard pieces as sibling component
folders, never nested views. All named queries in Core. Script module
`BlueRidge.Quality.ControlledRun` — thin wrappers only; every rule above lives in SQL.

**Layout: master–detail, one page.**

- **Left — runs.** Filter (open / closed / all, part, text). Each row: run number, part,
  reason, opened, a "12 of 20 cleared" count, and a marker while the window is still
  open. A scan box at the top takes a run label, an LTT or a container label and selects
  the run it belongs to. **New super-lot** button.
- **Right — the selected run.** Header: number, reason, criteria in words ("5G0 castings
  made on Line 3 since 06:10, and everything made from MESL3000412"), window state with
  an **End window** button. Member table: kind, name, part, location, pieces, tagged or
  cleared, how it joined. Actions: **Add** (scan), **Remove** (with a reason),
  **Print 4 labels**, **Close super-lot**.
  A row opens Lot Detail for a LOT.

**New super-lot** is a three-step popup:

1. **What.** Reason (required). Scan or pick the suspect LOT (optional). Part, line,
   from, to — pre-filled from the suspect LOT when one is given. "Include everything
   made from this LOT" checkbox. "Keep adding new production" checkbox (needs a part).
2. **Preview.** The candidate list from `ControlledRun_PreviewSelection`, oldest first,
   every eligible row ticked. Ineligible rows are listed with their reason and cannot be
   ticked. Totals at the top: LOTs, containers, pieces.
3. **Confirm.** One elevation, then `ControlledRun_Open`. On success the new run is
   selected and the label prompt is offered.

**Elevation.** Opening, adding, removing, ending the window, closing and cancelling each
take the per-action AD credential, new action code `ControlledRun`, same mechanism as
`CrtToggle`. Reading and printing do not. Whether these run under the stateless one-shot
form or the elevated window is a plan-time choice; the wizard's single confirm suggests
one-shot. A Quality-only gate is piece 3 and depends on AD roles that do not exist yet.

**Attribution.** Every call passes `appUserId` from
`BlueRidge.Common.Session.currentAppUserId(self.session)`. No defaults.

**View conventions that apply:** every bound custom property pre-declared with a shaped
default; binding sources return the shaped empty object, never `None`; no drag and drop;
all displayed times Eastern.

## 9. Decisions

### Answered by Jacques, 2026-10-12

1. **Run number width:** `NVARCHAR(15)`. (The names `ControlledRun` / "Super-lot" and
   the `CR000123` format were not objected to and stand until MPP say otherwise.)
2. **Finished containers:** not an issue, because everything in this plan is built before
   any of it is released. A completed, unshipped container is an eligible member in this
   piece; piece 2 supplies the tag and the shipping block for it. **Consequence: pieces 1
   and 2 must not be deployed apart.** Until piece 2 is in, a completed container on a
   super-lot is listed but can still be loaded at the dock.
4. **Label:** it is the super-lot's label, not a member's. Four at a time, on demand, made
   to stand out. The barcode takes Quality to the full super-lot in the app, and all
   management happens from there. (D11, section 7.)
5. **The generic `CrtBanner` still prints** for a LOT that is in a super-lot. Nothing in
   `LotLabel_Print` changes.
6. **"Produced at a line" means where the LOT was minted**, not where it is now.

### Still open

3. **How new production gets into a super-lot that has been left open.** This is the
   "rolling" part of the window. Two ways to do it:

   - **A (written into this spec as D7).** While a super-lot is open with "keep adding
     new production" ticked, every new LOT of that part made on that line is tagged CRT
     as it is made and added to the super-lot automatically. It stops when Quality press
     **End window**. Scoped to one part on one line.
   - **B.** Opening the super-lot switches on the part's existing CRT flag
     (`Parts.Item.CrtEnabled`), and closing switches it off. Simpler to build, but the
     flag is plant-wide for that part: it cannot be limited to one line, and two
     super-lots on the same part would each try to own it.

   A is recommended. The question for Jacques is whether the automatic adding is wanted
   at all, and if so whether "one part on one line" is the right reach.

## 10. Known limitations

- **A run is not a hold.** Members stay status `Good`. Anything that keys on
  `LotStatus = Hold` (hold reports, AIM `PlaceOnHold`) does not see a run.
- **`RejectEvent_RecordByPartFifo` does not look at `CrtActive`.** At a line it will
  spread a scrap entry across run members and clean LOTs alike. Not changed here; flagged
  for piece 3, which owns scrap against a run.
- **Membership lags the tag by one sync** for auto-joined LOTs (D7). The block does not
  lag.
- **Clearing a member's tag on Lot Detail does not end its membership.** It shows as
  cleared and counts toward close. That is intended in this piece.
- **Elevation still resolves to "any active AD-mapped user".** Unchanged from every
  other protected action.

## 11. Testing

SQL suite under `sql/tests/` in a new folder, run against a private throwaway database
(never `MPP_MES_Dev`, never `MPP_MES_Test`). Check the assertion **count** against the
baseline as well as failures — a file that throws stops every batch after it.

- **Schema.** XOR and pairing checks reject bad rows; the two filtered unique indexes
  refuse a second open membership and allow one after the first has ended.
- **Preview.** Part + line + window finds the right LOTs and excludes one minute either
  side; genealogy finds descendants at depth 1 and 2; tray LOTs fold to one container
  row; each ineligible reason is produced by its case; nothing is written.
- **Open.** Members inserted; clean LOTs become CRT-active with one `CrtActivated` row
  each; already-tagged LOTs get `CrtSetByRun = 0` and no second audit row; an ineligible
  id in the JSON rejects the whole call with nothing written; the run number increments.
- **Enforcement inherits.** A LOT tagged by joining a run is refused by `Lot_MoveTo` to a
  production destination and by `MachiningIn_RecordPick` — proving the run needs no
  blocks of its own.
- **Resolver regression.** With no open auto-join run, `ufn_CrtForMint` returns exactly
  what it did before for every existing case in `sql/tests/0064_Crt_PartScoped/`. With
  one: a matching part mints tagged; a different part does not; a matching part at a
  different line does not when the run names a line and does when it names none; after
  the window is ended it does not.
- **Sync.** Adds a matching mint once and only once; ignores LOTs minted before the run
  opened or after the window ended; adds a CRT descendant only when
  `IncludeDescendants = 1`; skips a LOT already in another open run.
- **Remove / close / cancel.** Remove needs remarks and leaves `CrtActive` alone; close is
  refused with tagged members outstanding and with the window still open, and succeeds
  once they are cleared, ending every member `RunClosed`; a closed run's members can join
  a new run; cancel ends members and leaves tags.
- **Label.** One log row per print request with `Copies = 4`; the ZPL carries `^PQ4`;
  every token substituted, none left as `{Token}`; a run with no part prints a blank part
  field; ASCII byte scan of the seeded template.
- **Teardown order.** `ControlledRunLabel` → `ControlledRunMember` → `ControlledRun`
  before the LOTs and containers they reference, and `LotGenealogyClosure` before LOTs.

Gateway smoke, no automated coverage: open a run from a scanned LOT, confirm the preview
matches the floor, print four labels and scan one back into the view, mint a new basket of the same part and watch it join,
end the window, clear the members, close the run.

## Revision History

| Date | Change |
|---|---|
| 2026-10-12 | Initial draft from the exploration session. Not approved. |
| 2026-10-12 | Jacques's answers recorded (section 9): run number 15 chars; all pieces ship together, so completed containers are eligible members; label is per super-lot, 4 copies, scan opens the run; banner still prints; line = mint location. Decision 3 (auto-join) restated and still open. |
