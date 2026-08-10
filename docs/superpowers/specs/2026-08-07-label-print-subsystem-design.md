# Label / Print subsystem — design (Brief D)

**FAT rows:** FAT-ENV-170, FAT-LBL-050, FAT-LBL-060, FAT-LBL-150
**Scope authority:** Integrations → Shipping/Printers = *Included*.
**Migration number:** `0054` (pre-assigned; `0053` is taken by Brief A / operation-template-publish).
**Branch:** `jacques/working`. Explicit-path staging only. ASCII-only ZPL.

---

## 1. Problem

Four FAT fails are one subsystem gap around the **container shipping label**:

- **LBL-050** — the shipping label is missing Honda-required content. Today
  `ShippingDispatcher._renderZpl` (Python) hardcodes a minimal label: the AIM Shipper ID as
  a single Code-128 barcode, nothing else.
- **LBL-060** — the rendered ZPL is not persisted. `Lots.ShippingLabel` has no `ZplContent`
  column, so there is no record of what was printed (contrast `Lots.LotLabel.ZplContent`).
- **ENV-170 / LBL-150** — dispatch is **synchronous raw-TCP** on the Perspective session
  thread with a single endpoint re-resolve retry; the `PrintFailureGateway` sweep/broadcast
  ticks are skeleton no-ops, so there is no real failure lifecycle (no retry policy, no
  stranded-print recovery, no terminal banner).

The **LTT (LOT) label** is already correct and template-driven — `Lots.LabelTemplate.ZplBody`
holds an active ASCII ZPL with `{Placeholder}` tokens resolved by `Lots.LotLabel_Print`. This
spec brings the shipping label onto that **same pattern** and adds the failure lifecycle.

## 2. Goals / non-goals

**Goals**
1. Shipping label is **DB-template-driven** (editable without code) and **Honda-complete**,
   ported faithfully from the real legacy container label (`zebraPrinter/Label Template -
   Container.zpl`).
2. Rendered ZPL is **persisted** on the `ShippingLabel` row (`ZplContent`).
3. Dispatch is **gateway-async** with a bounded **3-attempt / ~2 s backoff** policy, a
   **stranded-print sweep**, and a **terminal failure banner** — the FDS-01-014 external-
   interface idiom already used for AIM.
4. `Audit.InterfaceLog` records every dispatch attempt (already true — preserved).

**Non-goals / explicitly deferred**
- The **FN3 2D DataMatrix composite** (Honda one-shot dock-scan barcode). Neither Blue Ridge
  nor MPP has the Honda field-concatenation spec. The template **keeps the field in the
  layout but resolves its token to blank**, flagged TODO — request the Honda 2D spec from MPP.
  Do **not** fabricate a scan-critical barcode.
- Real networked-Zebra print certification (hardware-gated; no printer in dev). The dispatch
  transport stays SIM-guarded; the **lifecycle** (persist ZPL, mark state, sweep, banner) is
  fully built and tested.
- LTT-label changes (already correct). Master/void label types.

## 3. The real Honda container label — field map

Source: `zebraPrinter/Label Template - Container.zpl` (legacy Flexware, `<<TOKEN:{0}>>`
mail-merge). We port the ZPL **layout verbatim** (field positions, `^GB` rules, `^A0R`
rotations, `^B3`/`^BXR` barcodes) and swap Flexware `<<…:{0}>>` merge fields for our
`{Placeholder}` tokens resolved in SQL.

| FN | Label field (legacy caption) | `{Placeholder}` | Source | Status |
|----|------------------------------|-----------------|--------|--------|
| FN1, FN2 | PART NO. (P) — text ×2 | `{PartNumber}` | `Parts.Item.PartNumber` (container's Item) | confirmed |
| FN3 | 2D DataMatrix (composite) | `{DataMatrix}` | **blank** (TODO: Honda 2D spec from MPP) | deferred-blank |
| FN4, FN5 | PART NO. EXT (C) — text + barcode | `{PartNumberExt}` | **blank** — empty on every observed MPP label; layout + caption retained, value perpetually blank (per MPP) | blank-by-design |
| FN6 | DESCRIPTION | `{Description}` | `Parts.Item.Description` | confirmed |
| FN7 | MFG LOT NUMBER | `{MfgLotNumber}` | AIM minted serial = `ShippingLabel.AimShipperId` | confirmed |
| FN8 | MFG DATE | `{MfgDate}` | container `CompletedAt`, `M/dd/yy`, ET | derivable |
| FN9 | AUDIT | `{Auditor}` | completing operator initials (`PrintedByUserId` → `AppUser.Initials`); blank if unresolved | default |
| FN10, FN11 | D/C PART LEVEL (2P) — text + barcode | `{DcPartLevel}` | **die rank via genealogy trace** (§4.3) → `Tools.DieRank.Code` | confirmed |
| FN12, FN13 | QUANTITY (Q) — text + Q-barcode | `{Quantity}` | container piece total (§4.4) | derivable |
| FN14, FN15 | SERIAL (1S) — text + barcode | `{Serial}` | `13218001` (fixed supplier code, 8) **+** AIM serial (8) = 16 chars (§4.5) | confirmed |
| FN16 | Made In / C.O.O. | `{Coo}` | static `USA` | default |

Static text on the label (Madison Precision Products address line, captions, `^GB` lines) is
carried verbatim in the template body — not tokenized.

> **Note on empty barcodes:** FN5 (`^B3` Code-39) and FN3 (`^BXR` DataMatrix) may render
> empty in dev when their token is blank. This matches the legacy behaviour (blank merge) and
> is acceptable — real-hardware behaviour with empty `^FD` is a commissioning detail, not a
> blocker (no Zebra in dev). The template author can drop the barcode command later via a DB
> edit if a printer rejects an empty symbol.

## 4. Architecture

### 4.1 Where rendering happens — **render-at-complete, persist immediately**

`Container_Complete` already runs the atomic transaction that claims the AIM Shipper ID and
inserts the `ShippingLabel` row. We render the ZPL **inside that same proc/transaction** and
store it in `ShippingLabel.ZplContent`. Rationale:

- **LBL-060** satisfied directly — the row is born with its rendered payload.
- The **stranded-print sweep works**: a gateway restart between the `Container_Complete`
  commit and the dispatch leaves a row that already carries its ZPL, so the sweep can
  re-dispatch the **exact persisted bytes** with no re-render and no missing context.
- Dispatch becomes a pure transport read: `dispatch(shippingLabelId)` reads `ZplContent` and
  writes it — no business logic in Python (convention).

Token resolution is **deterministic SQL string substitution** (mirrors `LotLabel_Print`), so
it is proc-enforced and unit-assertable. Rendering is factored into a reusable helper the
complete proc calls, so it can also back a **reprint** re-render.

### 4.2 Components

**SQL**
- **Migration `0054`** (versioned):
  - `ALTER TABLE Lots.ShippingLabel ADD ZplContent NVARCHAR(MAX) NULL;`
  - Seed one **active `Lots.LabelTemplate`** row for the **existing** `LabelTypeCode` `Container`
    (Id 2 — the code `Container_Complete` already stamps on the row). ASCII-only ZPL ported
    from the legacy container label with `{Placeholder}` tokens. Filtered-unique index already
    enforces one active template per type.
  - Idempotent `IF NOT EXISTS` seed guard; record in `SchemaVersion`.
- **`Lots.ufn_ShippingLabelZpl(@ContainerId, @AimShipperId)`** — a scalar/inline function (or
  a private render block in the complete proc) that resolves the active Container template +
  substitutes all §3 tokens and returns the rendered ASCII ZPL. Pure, deterministic, no side
  effects → callable from both `Container_Complete` and `ShippingLabel_Reprint`.
- **`Tools.ufn_ContainerOriginDieRankCode(@ContainerId)`** (or inline in the render function) —
  the genealogy resolver (§4.3). Returns the `DieRank.Code` string, `''` when unresolved.
- **`R__Lots_Container_Complete.sql`** — extend the mutation to render + persist `ZplContent`
  in the existing transaction. No signature change to callers.
- **`R__Lots_ShippingLabel_Reprint.sql`** — re-render `ZplContent` on reprint (currently it
  only writes a history row). Mirror the complete-proc render call.
- **`R__Lots_ShippingLabel_MarkDispatch.sql`** — new mutation the dispatcher calls to record
  outcome on the row: on success set `PrintedAt`, bump `PrintAttempts`, set
  `LastPrintAttemptAt`; on failure bump `PrintAttempts`, set `LastPrintAttemptAt` +
  `LastPrintError` and, when attempts are exhausted, `PrintFailedAt`. Status-row shape;
  `type:"Query"` NQ.
- **`R__Lots_ShippingLabel_GetStranded.sql`** — read proc for the sweep: rows with
  `PrintedAt IS NULL AND PrintFailedAt IS NULL AND CreatedAt < DATEADD(second,-60,SYSUTCDATETIME())`
  (uses the existing `IX_ShippingLabel_Stranded` filtered index). Returns Id, ContainerId,
  AimShipperId, TerminalLocationId, ZplContent, PrintAttempts.
- **`R__Lots_ShippingLabel_GetFailedForBanner.sql`** — read proc for the broadcast:
  `PrintFailedAt IS NOT NULL AND BannerAcknowledgedAt IS NULL`, joined to the terminal so the
  banner can filter by `session.custom.terminal`.
- **`R__Lots_ShippingLabel_AckBanner.sql`** — set `BannerAcknowledgedAt` when the operator
  dismisses the banner.

**Named queries** (Core only): `lots/ShippingLabel_MarkDispatch`, `lots/ShippingLabel_GetStranded`,
`lots/ShippingLabel_GetFailedForBanner`, `lots/ShippingLabel_AckBanner`. Status-row mutations
`type:"Query"`; reads default.

**Ignition Python (Core)**
- **`BlueRidge.Lots.ShippingDispatcher`** — replace hardcoded `_renderZpl`. `dispatch` now:
  1. resolves the endpoint (session/terminal/printer-card override — unchanged),
  2. reads persisted `ZplContent` (via a `ShippingLabel_Get`-style read by id) — **or** accepts
     it from the caller when just completed,
  3. attempts the raw-TCP write with **3 attempts / ~2 s backoff**, logging every attempt to
     `Audit.InterfaceLog` (preserved),
  4. calls `ShippingLabel_MarkDispatch` with the outcome.
  Runs in **gateway-async** scope (`system.util.invokeAsynchronous`) so the 3×/backoff never
  blocks the Perspective session thread; the UI returns "printing…" immediately and the
  ShippingLabel state + banner reflect the result. Transport stays SIM-guarded (no dev Zebra).
- **`BlueRidge.Lots.PrintFailureGateway`** — implement the two ticks (currently no-ops):
  - `sweepTick()` (~5 min): for each `GetStranded` row → re-`dispatch`; on a second strand
    the mark proc flips `PrintFailedAt`; when the stranded count exceeds a threshold, raise a
    supervisor/IT session alarm (mirror `AimPoolGateway.alarmTick`).
  - `broadcastTick()` (~5 s): for each `GetFailedForBanner` row → `system.perspective.sendMessage`
    `'print-failure-alert'` targeted at the terminal's session/page (gateway-scope send needs
    explicit sessionId+pageId — memory `feedback_ignition_gateway_sendmessage_needs_session_page`).
  Both fully guarded — a timer must never throw (`except (Exception, java.lang.Exception)`).
- **`completeBoxToPrinter`** (`Workorder.Assembly`) — unchanged call shape; the dispatch it
  already fires now runs the async lifecycle. On a completed-but-unprinted box the row
  persists (re-dispatchable) exactly as today.

**Perspective (MPP)** — the gateway timers for `sweepTick`/`broadcastTick` already exist
(skeleton). Add/confirm a **`PrintFailureBanner`** component on the shipping/dock surface that
subscribes to `'print-failure-alert'`, filters by `session.custom.terminal`, shows the failed
container + a Dismiss (→ `ShippingLabel_AckBanner`) and Reprint action. Single-lane
`view.json` + `scan.ps1`.

### 4.3 Die-rank genealogy resolver (`{DcPartLevel}`)

The label's "D/C PART LEVEL (2P)" is the **die rank** of the casting the container's parts
descend from. `DieRankId` lives on `Tools.Tool` (the die), not on any LOT/Container/Item, so
resolve by tracing genealogy:

```
Container (@ContainerId)
  → Lots.ContainerTray  (ClosedAt NOT NULL, ORDER BY TrayPosition)  -- representative = first closed tray
      .FinishedGoodLotId                                            -- FG LOT (migration 0034)
  → Lots.LotGenealogyClosure  (AncestorLotId of the FG LOT, Depth > 0)
  → Lots.Lot  WHERE ToolId IS NOT NULL                              -- the origin casting LOT
      (deepest ancestor with a ToolId = the die-cast origin)
  → Tools.Tool.DieRankId → Tools.DieRank.Code
```

**Representative rule (decided):** resolve from the origin casting of the container's **first
closed tray** (`MIN(TrayPosition)`). Relies on die-rank compatibility keeping a production run
single-rank; multi-rank reconciliation is **not** in scope. Return `''` (blank token, not an
error) when no die-rank ancestor resolves — the label still prints; genealogy edge cases never
block a shipment.

Implemented as a set-based read (closure table is O(1) per row — no recursion), packaged as
`Tools.ufn_ContainerOriginDieRankCode` or inlined in the render function.

### 4.4 Quantity

Container piece total = `SUM(ContainerTray.PartsClosedCount)` over closed trays for the
container (the same accumulator `Container_Complete`/`Assembly_CompleteTray` already compute).

### 4.5 Serial composition

`{Serial}` = `'13218001'` (fixed MPP→Honda supplier code, 8 digits) concatenated with the
**8-digit AIM serial** taken from `ShippingLabel.AimShipperId` = 16 chars total. If the stored
AIM serial is longer/shorter than 8, take its **last 8** (right-justified) per the "last 8 =
AIM serial" rule; document the assumption in the proc header. `{MfgLotNumber}` = the AIM serial
as stored (no supplier prefix).

### 4.6 Timestamps

`{MfgDate}` renders `CompletedAt` converted UTC→Eastern at the read boundary
(`AT TIME ZONE 'UTC' AT TIME ZONE 'Eastern Standard Time'`), formatted `M/dd/yy` — consistent
with the project's stored-UTC / displayed-ET rule.

## 5. Data flow

```
Operator completes box (completeBoxToPrinter)
  → Lots.Container_Complete  [TXN]:
        claim AIM shipper
        render ZPL (resolve Container template + tokens; die-rank trace; serial; qty)
        INSERT Lots.ShippingLabel (…, ZplContent = rendered, PrintedAt NULL, PrintFailedAt NULL)
        flip container status
     [COMMIT]
  → ShippingDispatcher.dispatch(shippingLabelId)   [gateway-async]
        read ZplContent + endpoint
        attempt raw-TCP write ×3, 2s backoff, log each to Audit.InterfaceLog
        ShippingLabel_MarkDispatch(outcome)  → PrintedAt | PrintFailedAt+LastPrintError

PrintFailureGateway.sweepTick   (~5 min):  GetStranded → re-dispatch; 2nd strand → PrintFailedAt; >N → alarm
PrintFailureGateway.broadcastTick (~5 s):  GetFailedForBanner → 'print-failure-alert' → PrintFailureBanner
Operator: Dismiss → ShippingLabel_AckBanner ;  Reprint → ShippingLabel_Reprint (re-render + re-dispatch)
```

## 6. Error handling

- Render failure (no active template, unresolved Item) → the existing `Container_Complete`
  Tier-2 validation + nested-CATCH failure log; the container complete **fails atomically**
  (no half-completed box). ZPL render is deterministic; the only realistic failure is a
  missing active template, which the migration seed guarantees exists.
- Dispatch failure → never rolls back the container (complete and print are separate steps,
  as today). Surfaced via `PrintFailedAt` + banner + Reprint.
- All FDS-11-011: no OUTPUT params; every mutation ends with the status row; audit writers
  emit no result set; validations before `BEGIN TRANSACTION`; no nested INSERT-EXEC.
- Timers fully guarded (`except (Exception, java.lang.Exception)`), never throw.

## 7. Testing (TDD)

New tests under `sql/tests/0025_PlantFloor_Label_Dispatch/` (dispatch/label home) and/or a new
`0029`-area shipping test file:

1. **Render / token resolution** — `Container_Complete` persists a `ZplContent` containing the
   resolved part number, description, quantity, MFG lot (AIM serial), and the 16-char serial
   `13218001`+AIM; ASCII-only (byte scan, no non-ASCII).
2. **Die-rank trace** — build casting(ToolId→DieRank)→SubAssembly→FG→container genealogy;
   assert `{DcPartLevel}` renders the origin casting's `DieRank.Code`; assert blank (not error)
   when no die-rank ancestor exists.
3. **Serial edge** — AIM serial >8 and <8 chars → last-8 / documented handling.
4. **Persistence (LBL-060)** — `ShippingLabel.ZplContent` non-null after complete; reprint
   re-renders it.
5. **Mark lifecycle** — `MarkDispatch` success sets `PrintedAt` + bumps `PrintAttempts`;
   failure sets `LastPrintError`; attempt-exhaustion sets `PrintFailedAt`.
6. **Stranded read** — `GetStranded` returns only rows older than 60 s with both timestamps
   null; excludes printed/failed.
7. **Banner read** — `GetFailedForBanner` returns failed-unacked rows; `AckBanner` clears them.

Python transport (socket) stays SIM/hardware-gated — verify the lifecycle via SQL + proc
(memory `feedback_ignition_browser_input_commit`: don't rely on the in-app browser to fire the
real print).

## 8. Open items to escalate (tracked, non-blocking)

- **Honda 2D DataMatrix composite (FN3)** — request the field-concatenation spec from MPP
  (add to the MPP questions list alongside the existing Honda-trace-export email note). Until
  then `{DataMatrix}` renders blank; the field/layout is retained.
- **AUDIT (FN9)** and **C.O.O. (FN16)** defaults (`operator initials` / `USA`) — confirm with
  MPP at label-verification time; both DB-editable.

## 9. Files

- Migration: `sql/migrations/versioned/0054_shipping_label_zpl_and_template.sql`
- Repeatables: `R__Lots_Container_Complete.sql` (extend), `R__Lots_ShippingLabel_Reprint.sql`
  (extend), new `R__Lots_ShippingLabel_MarkDispatch.sql`, `R__Lots_ShippingLabel_GetStranded.sql`,
  `R__Lots_ShippingLabel_GetFailedForBanner.sql`, `R__Lots_ShippingLabel_AckBanner.sql`,
  render/​die-rank functions (`R__Lots_ufn_ShippingLabelZpl.sql`,
  `R__Tools_ufn_ContainerOriginDieRankCode.sql`).
- NQs (Core): `lots/ShippingLabel_MarkDispatch`, `lots/ShippingLabel_GetStranded`,
  `lots/ShippingLabel_GetFailedForBanner`, `lots/ShippingLabel_AckBanner`
  (+ a `ShippingLabel_Get` by id if not present).
- Python (Core): `Lots/ShippingDispatcher/code.py` (render removed; async 3× dispatch + mark),
  `Lots/PrintFailureGateway/code.py` (implement ticks), `Workorder/Assembly/code.py`
  (`completeBoxToPrinter` passes the `ShippingLabelId` from `Container_Complete` to `dispatch`;
  `dispatch` gains a back-compat path — if given only an AIM id it resolves the newest
  unprinted ShippingLabel row for that shipper).
- Perspective (MPP): `PrintFailureBanner` component on the shipping/dock surface + `scan.ps1`.
- Tests: `sql/tests/0025_PlantFloor_Label_Dispatch/…` (+ shipping-area files).

## 10. Definition of done

Spec committed; plan followed; tests green via the project harness; `.\scan.ps1` after the
Ignition change; `superpowers:requesting-code-review` passed; FAT rows ENV-170 / LBL-050 /
LBL-060 / LBL-150 re-testable with evidence (or the 2D-barcode escalation reported). Stay on
`jacques/working`, explicit staging, migration `0054`, ASCII-only ZPL.
