# Inspection Station for Third-Party-Produced Parts — Design Spec + Implementation Plan

**Date:** 2026-07-23
**Author:** Blue Ridge Automation
**Status:** DRAFT — design only, no code written. **Blocked on customer input** (see Open Questions).
**Type:** Plant-floor (Arc 2) feature — new station flavor + thin SQL delta over existing MVP primitives.

> ⚠️ **This item has the most unknowns of any open plant-floor feature.** The *shape* is locked by the customer meeting (one station: check-in → inspect → check-out, "just like assembly out"), but almost every material detail — part identity, ItemType, what "check-out" produces, the fail gate, the driving quality spec, and above all the **scope boundary** — is an open question. The recommendations below are the lowest-risk reading of existing patterns; **do not start the build until the Open Questions are answered**, because two of them (Q1 identity, Q3 check-out shape) change the data model.

---

## 1. Executive summary

A physical reality surfaced late: **some parts are produced by a third party** and arrive at a dedicated **Inspection Station** where, at one station, an operator **checks them in, inspects them, and checks them out** into the plant. The customer described the check-out as behaving **"just like assembly out."**

The good news: **MPP already has every primitive this needs.** Nothing here is greenfield.

| Station step | Existing primitive to reuse | Built? |
|---|---|---|
| **Check-in** (create/receive the incoming LOT) | `Lots.Lot_Create` with `Received` / `ReceivedOffsite` origin + `VendorLotNumber` + serial range (the `ReceivingDock` view already does exactly this) | ✅ MVP, built |
| **Inspect** (capture a pass/fail quality result) | `Quality.QualitySample_Record` (Phase 9) — records a header + per-attribute results against a published `QualitySpecVersion`, computes overall Pass/Fail, **no auto-hold** | ✅ MVP, built |
| **Check-out** ("like assembly out") | `Workorder.Assembly_CompleteTray` → mint/label LOT + `Lots.Container_Complete` (AIM shipper-id + ShippingLabel) **OR** a simple `Lot_MoveToValidated` into inventory | ✅ both built |
| **Fail → hold** | `Quality.Hold_Place` (LOT or container) | ✅ MVP, built |

So this is a **composition + orchestration** feature, not a new subsystem. The design work is: (1) decide the identity/ItemType/check-out shape, (2) write one thin **dedicated station flavor** (a `ThirdPartyInspection` view) plus at most **one new orchestrating proc** that stitches the three steps into one screen, and (3) resolve the scope boundary so we don't accidentally build a FUTURE-scoped tracking workflow.

**Recommended default reading** (all subject to Open Questions):
- **Identity (Q1):** the incoming LOT is a normal `Received`-origin LOT, identity = scanned/entered **external LTT** (`@LotName`) if the vendor ticket is barcoded, else server-minted `LotName`, with `VendorLotNumber` capturing the vendor's lot. Not a consume-mint.
- **ItemType (Q2):** the third-party part is a **FinishedGood** (or a purchased component) — an existing `Parts.Item` flagged eligible at the inspection location; **not** die-cast/SubAssembly.
- **Check-out (Q3):** **simpler than assembly-out by default** — an inspection PASS releases the same LOT (no new part number minted) via a move into inventory / onto its route; only escalate to the full container+AIM+ShippingLabel path if MPP confirms these ship straight out under an AIM shipper id.
- **Pass/fail gate (Q4):** a **FAIL blocks check-out** and offers a one-tap Hold (`Quality.Hold_Place`); PASS enables check-out. (This is stricter than `QualitySample_Record`'s "record only, no auto-hold" default — the *station view* enforces the gate; the proc stays advisory.)
- **Scope (Q7):** check-in + inspect + check-out **at the single station** is composable from MVP primitives (Receiving = MVP, Inspections = MVP, Holds = MVP). But **"Pass-through Parts Tracking" is FUTURE** (Scope Matrix row 20). We must build the station, **not** the downstream in-plant genealogy/tracking of these parts.

---

## 2. Scope determination (read this first)

The Scope Matrix (`reference/MPP_Scope_Matrix.xlsx`, the authority) splits this feature across four rows:

| Row | Sub-Area | FRS Proposal | Effective scope |
|---|---|---|---|
| 3 | Production · **Receiving** | "Pass-through (not raw / dunnage) Parts Included" | **MVP** — check-in |
| 8 | Quality · **Inspections** | Included | **MVP** — inspect |
| 11 | Quality · **Holds** | Included and Expanded | **MVP** — fail path |
| 9 | Quality · **Sampling** | Included **conditionally** | **CONDITIONAL** — if inspection is sample-triggered |
| 20 | Traceability · **Pass-through Parts Tracking** | Included — **Notes: Future** | **FUTURE** — do NOT build downstream tracking |

**Interpretation.** The *station itself* (check-in → inspect → check-out) is assembled entirely from MVP-scoped primitives and is therefore **in scope to build**. What is **out of scope (FUTURE)** is the *full pass-through tracking workflow* — following these third-party LOTs through the rest of the plant with genealogy, consumption, WIP queues, etc. (`MPP_MES_SUMMARY.md`: "Pass-through full workflow — MVP entry, FUTURE tracking … full in-plant tracking workflow deferred").

**Design consequence:** check-out should **release the LOT to a terminal/inventory state and stop**, not thread it into machining/assembly route queues. If Q3's answer turns out to require route-driven downstream handling, that portion is FUTURE and must be flagged, not built. **Q7 must be confirmed with the customer before build.**

---

## 3. Current-state / reused-patterns summary

Grounded in the actual code (paths are load-bearing):

### 3.1 Check-in — `Lots.Lot_Create` (`sql/migrations/repeatable/R__Lots_Lot_Create.sql`)
- Already supports `Received` (id 2) and `ReceivedOffsite` (id 3) origins (`Lots.LotOriginType`, seeded in `0004`).
- Captures `@VendorLotNumber`, `@MinSerialNumber`/`@MaxSerialNumber`, NULL Tool/Cavity.
- `@LotName` (D4): a caller-supplied identity (pre-printed / external LTT) is used verbatim and does **not** burn the `Lot` sequence; NULL mints server-side. Die-cast enforces a 9-digit LTT via `Lots.ufn_IsValidExternalLtt`; other origins keep the identity optional/unvalidated.
- Eligibility is enforced against `Parts.v_EffectiveItemLocation` walking the location ancestor chain — the item must be eligible at (or above) the create location.
- Proven for receiving by test `sql/tests/0024_PlantFloor_Movement_Trim/070_Receiving_pass_through.sql` ("Receiving = Lot_Create reuse … no net-new SQL").
- **Ignition:** `ReceivingDock` view (`ignition/projects/MPP/.../ShopFloor/ReceivingDock/view.json`) — part dropdown (scan-or-pick, `allowCustomOptions`), vendor lot / piece count / serial range fields, `Received` origin resolved via `BlueRidge.Lots.Lot.getOriginTypeIdByCode(..., "Received")`, then prints an LTT and navigates to LOT Detail. **This view is essentially the check-in half already.**

### 3.2 Inspect — `Quality.QualitySample_Record` (`R__Quality_QualitySample_Record.sql`, migration `0037`)
- Records one `Quality.QualitySample` header + one `Quality.QualityResult` per attribute from a `@ResultsJson` array `[{qualitySpecAttributeId, measuredValue}]`.
- Pass/fail semantics: numeric-with-limits → range check into `[LowerLimit, UpperLimit]` (NULL bound = open), stored in `NumericValue`; non-numeric / no-limits → presence check. Overall = **Fail if any `IsRequired=1` attribute failed**, resolved to `Quality.InspectionResultCode` (Pass/Fail/Conditional, seeded `0004`).
- **Explicitly NO auto-hold on Fail (FDS-08-012)** — records + returns the result; alerting is the view's job. Inspection of a held/closed LOT is allowed (any status).
- `@SampleTriggerCodeId` (Manual / ShiftStart / DieChange / ToolChange / TimeInterval, ids 5–9) — for an inspection station, `Manual` (id 9) or a new `Receipt` trigger fits.
- Supporting reads: `QualitySample_ListByLot`, `QualityResult_ListBySample`, `QualityAttachment_Add/_ListBySample`, `SampleTriggerCode_List`, plus Core NQs under `ignition/projects/Core/.../named-query/quality/`.
- **Gap:** there is no view that drives `QualitySample_Record` on the shop floor yet (Phase 9 shipped the API + audit; the capture UI was noted as a Designer follow-up). The inspection station is the natural first consumer.

### 3.3 Check-out "like assembly out" — `Workorder.Assembly_CompleteTray` + `Lots.Container_Complete`
- `Assembly_CompleteTray` (`R__Workorder_Assembly_CompleteTray.sql`): mints a FinishedGood LOT (tray = LOT), consumes BOM×PieceCount FIFO into it (`Consumption` genealogy, `RelationshipTypeId=3`), attaches/auto-opens a `Lots.Container`, returns `@ContainerFull`. Delegates the ship-label step to `Container_Complete`.
- `Container_Complete` (`R__Lots_Container_Complete.sql`): validates full, claims an AIM shipper id FIFO from `Lots.AimShipperIdPool`, inserts a `Lots.ShippingLabel`, flips container → Complete. Hard-fails (leaves container Open) if the AIM pool is empty (OI-33).
- These are the "assembly out" mechanics the customer referenced. **The key design question (Q3) is how much of this a third-party check-out actually needs** — because unlike assembly, a third-party part is *not* being manufactured from components (no BOM to consume), so the FIFO-consume half of `Assembly_CompleteTray` is inapplicable. What may apply is the **container + AIM shipping-label** half, *if* these parts ship straight out.

### 3.4 Fail → hold — `Quality.Hold_Place` (`R__Quality_Hold_Place.sql`)
- Places a hold on exactly one LOT or one Container; LOT → status `Hold` (2, `BlocksProduction=1`) + `LotStatusHistory`; audits `HoldPlaced`. Rejects a second open hold. `Hold_Release` reverses. Hold taxonomy in `0030`/`0031`.

### 3.5 Route/identity model context (`OperationRoleKind`, migrations `0032`/`0035`)
- Terminal FIFO + part identity are **route-driven** (`Advance` / `OriginMint` / `ConsumeMint`). Die Cast = `OriginMint`; Machining/Assembly OUT = `ConsumeMint`; FinishedGoods are unrouted.
- A third-party received part has **no manufacturing route** — it is born by receipt, not minted at a die. This is why the recommended identity (Q1) is a plain `Received`-origin `Lot_Create`, not a consume-mint. **Do not** try to force it through the `OperationRoleKind` queue model unless Q7 pulls in FUTURE downstream tracking.

### 3.6 Station/session conventions (reused verbatim)
- **Dedicated station flavor** pattern (like `DieCastDedicated` / `TrimBody`): one plant-floor view bound to the terminal's session context. `BlueRidge.Location.Terminal.applyToSession` sets `session.custom.terminal` (`{terminalLocationId, zoneLocationId, zoneName, printer, plc, closure}`) and `session.custom.cell`; `appUserId` for attribution.
- Plant-floor `psc-pf-*` design system (Core stylesheet, canonical) + `pf-queue-row` / `pf-inventory-row` cards; `BlueRidge.Common.Notify.toast`; scan-or-dropdown; keyboard component; no drag-and-drop.

---

## 4. Proposed station flow

```
┌──────────────────────── Third-Party Inspection Station (one terminal/view) ────────────────────────┐
│                                                                                                     │
│  1. CHECK IN                    2. INSPECT                         3. CHECK OUT                      │
│  ───────────                    ──────────                         ───────────                      │
│  Scan/pick part                 Load part's active QualitySpec     [gated on PASS]                  │
│  Scan vendor LTT / enter        version → render attribute form    Release LOT to inventory /       │
│    VendorLotNumber              Enter measured values              disposition (Q3):                │
│  Enter piece count              Submit → QualitySample_Record       (A) simple move to storage, OR  │
│  (optional serial range)          → Pass / Fail / Conditional      (B) container + AIM ShippingLabel│
│         │                              │                                    │                        │
│         ▼                              ▼                                    ▼                        │
│   Lot_Create (Received)         Quality.QualitySample_Record        InspectionCheckOut proc         │
│   → LOT in "AwaitingInspection" → result stored + audited           → status transition + move      │
│     state at the station                │                             + label + audit               │
│                                    FAIL ▼                                                            │
│                                 one-tap Hold_Place (LOT) ─────────────► LOT held, check-out blocked │
└─────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

**One screen, three panels** (or a 3-step wizard), all scoped to the terminal's `session.custom.cell` = the Inspection Station location. A LOT flows check-in → inspect → check-out without leaving the station, mirroring the physical reality.

### 4.1 Station state (how the view knows where a LOT is in the 3 steps)
The cleanest signal that a LOT is "checked in but not yet checked out" is that it is a `Received`-origin LOT **currently residing at the inspection station location** with **no check-out event yet**. Two candidate encodings (Q5):
- **Recommended:** derive it — a `Received` LOT whose `CurrentLocationId` = the station and which has **not** been moved out / completed. A read proc `Lots.Lot_GetInspectionQueueByLocation(@LocationId)` returns the "at station, awaiting inspection/checkout" list (mirror the shape of `Lot_GetWipQueueByLocation`). No schema change.
- **Alternative:** a dedicated `LotStatusCode` (`AwaitingInspection`) or a `Received`-origin sub-state. Heavier; only if MPP wants an explicit reportable state.

---

## 5. Data model

**Design goal: minimize new schema.** Recommended default is **zero new tables** — the feature composes existing ones. New schema is introduced only if Open Questions force it.

### 5.1 Reused as-is (no change)
- `Lots.Lot` (+ `LotName`, `VendorLotNumber`, `LotOriginTypeId`, `CurrentLocationId`, serial range, B5 `InventoryAvailable`/`TotalInProcess`).
- `Lots.LotOriginType` — `Received` (2) / `ReceivedOffsite` (3).
- `Lots.LotStatusCode`, `LotStatusHistory`, `LotMovement`, `LotGenealogyClosure` (self-row only — no genealogy for a received part).
- `Quality.QualitySample` / `QualityResult` / `QualityAttachment` / `QualitySpecVersion` / `QualitySpecAttribute` / `InspectionResultCode` / `SampleTriggerCode`.
- `Quality.HoldEvent` / `HoldTypeCode`.
- `Lots.Container` / `ContainerTray` / `ShippingLabel` / `AimShipperIdPool` (**only if** Q3 → container/AIM check-out).

### 5.2 Candidate additive changes (each gated on an Open Question)
| Change | Gated on | Nature |
|---|---|---|
| `Quality.SampleTriggerCode` add `Receipt` / `IncomingInspection` row (additive, IDENTITY_INSERT, next id) | Q6 (trigger taxonomy) | Seed row, additive, idempotent — trivial |
| `Lots.LotStatusCode` add `AwaitingInspection` (BlocksProduction as appropriate) | Q5 (explicit state) | Only if derived-state is rejected |
| New `Quality.HoldTypeCode` row for incoming-inspection failures | Q4 (fail taxonomy) | Additive seed |
| `Parts.Item` flag / `ItemType` value marking "third-party produced" | Q2 (which items) | Only if the part list must be constrained beyond eligibility |
| **No new tables** in the recommended path | — | — |

**All additive changes follow conventions:** `BIGINT IDENTITY` PKs, `NVARCHAR`, ASCII-only seeds (byte-scan), idempotent guards, code-table backed, and a new versioned migration `00NN_inspection_station_*.sql` recording to `dbo.SchemaVersion`. Audit seeds (any new `LogEventType` / `LogEntityType`) guarded by `IF NOT EXISTS` with Id-or-Code, taking the next free ids (current max LogEventType 68, LogEntityType 58 per PROJECT_STATUS — **re-check at build time**, migration numbering is at ~`0043`).

---

## 6. SQL surface

Following the stored-proc template (`sql/scripts/_TEMPLATE_stored_procedure.sql`): three-tier errors, `RAISERROR` in CATCH, no `OUTPUT` params (FDS-11-011), single terminal `SELECT @Status, @Message, …`, all rejecting validations **before** `BEGIN TRANSACTION` (Msg 3915 rule), audit Description in `<SUBJECT> · <CATEGORY> · <ACTION>` shape with resolved-name FK JSON.

### 6.1 Reads (new)
- **`Lots.Lot_GetInspectionQueueByLocation(@LocationId, @IncludeDescendants BIT = 0)`** — the "checked-in, awaiting inspection/check-out" list at the station. Mirror `Lot_GetWipQueueByLocation` shape (position, LotName, part · pcs · arrived, latest inspection result pill). ET timestamps via `AT TIME ZONE`.
- Reuse `Quality.QualitySample_ListByLot` / `QualityResult_ListBySample` for the inspection-history panel; reuse `Quality.QualitySpecVersion` active-version resolution (there is an existing `GetActiveForSpec`-style read) to load the form. **Confirm the active-spec-for-item resolver exists** (Q8) — if inspection binds to the part's item-level quality spec, a `Quality.QualitySpecVersion_GetActiveForItem(@ItemId)` read may be needed (thin, likely already present from the Quality Spec Config Tool).

### 6.2 Mutations (mostly reuse)
- **Check-in:** reuse `Lots.Lot_Create` (`Received` origin, `@VendorLotNumber`, `@LotName` = scanned vendor LTT or NULL to mint, `@DepositToStorage = 0`). **No new proc.**
- **Inspect:** reuse `Quality.QualitySample_Record` verbatim. **No new proc.** The Pass/Fail gate lives in the view (§7/§8), not the proc — consistent with FDS-08-012 (proc records, does not act).
- **Fail → hold:** reuse `Quality.Hold_Place(@LotId, @HoldTypeCodeId, @Reason, …)`. **No new proc.**
- **Check-out — the one likely-new orchestrating proc:**
  **`Workorder.InspectionCheckOut`** (name TBD; could also live in `Lots`). Responsibilities depend on Q3:
  - **Path A (recommended default — simple release):** validate the LOT is `Received`-origin, at the station, has a **PASS** (or Conditional-with-override) inspection on record and no open hold → move it to the destination inventory location (inline `LotMovement`, mirror `Lot_MoveToValidated`'s eligibility check *only if* a destination route/eligibility applies; otherwise a system move to storage like the `@DepositToStorage` path), audit a `CheckedOut` / `LotMoved` event. **No BOM consume, no mint, no AIM.**
  - **Path B (full "assembly-out" — container + ship label):** additionally attach to / open a `Lots.Container` and, when full, delegate to `Lots.Container_Complete` for the AIM shipper-id + `ShippingLabel`. This is heavier and pulls AIM into the incoming-inspection path — **only build if MPP confirms these parts ship straight out under an AIM id** (Q3).

  Because `InspectionCheckOut` returns a status row and may be captured via `INSERT-EXEC`, it must **inline** any sub-mutation (movement, status flip) rather than `EXEC` a sibling status-row proc, and run all rejections pre-transaction — same discipline as `Assembly_CompleteTray` / `Lot_Split`.

  **Gate logic (Q4):** the proc SHOULD re-assert the pass gate server-side (defense in depth) — reject check-out if the most-recent `QualitySample.InspectionResultCode` for the LOT is `Fail` (or if an open `HoldEvent` exists). The view enforces it for UX; the proc enforces it for integrity.

### 6.3 Audit
New `LogEventType`s likely needed: `InspectionCheckedOut` (and possibly `InspectionCheckedIn` if we want a distinct event beyond `LotCreated`). New `LogEntityType` not needed (reuse `Lot`). Descriptions e.g. `<LotName> · Inspection · Checked out to <Dest> (Pass)`.

---

## 7. Ignition surface

### 7.1 New view — `ThirdPartyInspection` (dedicated station flavor)
`ignition/projects/MPP/.../ShopFloor/ThirdPartyInspection/view.json` (+ `resource.json`). New view → **file-authored + `scan.ps1`** (safe; no Designer cache). Structure:
- **Header/subtitle** bound to `session.custom.terminal.zoneName` (watch for the fallback-terminal trap: subtitle "Madison Facility" = unregistered IP → whole-facility zone).
- **Panel 1 — Check In:** scan-or-pick part dropdown (reuse `ReceivingDock`'s `allowCustomOptions` + `Item.getByPartNumber` resolution), vendor LTT field, piece count, optional serial range → calls `BlueRidge.Lots.Lot.create` with `Received` origin. (Consider literally forking `ReceivingDock`'s `createLot` customMethod.)
- **Panel 2 — Inspect:** an **inspection queue** (from `Lot_GetInspectionQueueByLocation`) as a `pf-inventory-row` selectable pick list; selecting a LOT loads its active `QualitySpecVersion` attributes into a dynamic form (numeric-entry-field for numeric attrs, text/dropdown otherwise; hide UOM/limits on non-numeric — reuse Quality Spec Config Tool row rendering). Submit builds `@ResultsJson` and calls `BlueRidge.Quality.QualitySample.record`. Result → toast (Pass green / Fail persistent-error).
- **Panel 3 — Check Out:** enabled only when the selected LOT has a PASS on record and no open hold; button calls `BlueRidge.Workorder.Inspection.checkOut(lotId, destination, appUserId, termId)`. On FAIL, this panel shows a **Place Hold** affordance instead (`BlueRidge.Quality.Hold.place`).

### 7.2 New Core scripts / NQs (all NQs in Core — project NQ topology)
- Core NQ `lots/Lot_GetInspectionQueueByLocation` + `workorder/InspectionCheckOut` (type `Query` for status-row procs; watch the NQ-type rule).
- Entity methods: `BlueRidge.Workorder.Inspection.checkOut`, `BlueRidge.Lots.Lot.getInspectionQueue`. **No business logic in Python** — thin glue over procs (matrices/gates live in SQL).
- Reuse existing `BlueRidge.Quality.QualitySample.record`, `BlueRidge.Quality.Hold.place`, `BlueRidge.Lots.Lot.create` entity wrappers (confirm the quality-capture entity wrapper exists from Phase 9; if not, add a thin one).

### 7.3 Routing / nav
`/shop-floor/third-party-inspection` route; add to NavigationTree / terminal flavor config so a terminal can be dedicated to it (like the Trim/DieCast dedicated flavors).

### 7.4 Operation-template note
This station is **not** a routed operation step in the recommended model (received parts are unrouted), so it does **not** resolve an `OperationTemplate` by role — **do not** call `getActiveTemplateIdByCode(...)`. If Q7 pulls in routed downstream handling (FUTURE), template resolution would follow the route-role convention, but that is out of MVP scope.

---

## 8. Pass/fail + hold interaction

| Inspection outcome | Station behavior | Underlying |
|---|---|---|
| **PASS** | Check-Out panel enabled; operator releases the LOT | `QualitySample_Record` → `Pass`; `InspectionCheckOut` allowed |
| **FAIL** | Check-Out **blocked**; "Place Hold" affordance shown; failed attributes highlighted (persistent error toast) | `QualitySample_Record` → `Fail` (proc still records, no auto-hold per FDS-08-012); operator taps → `Hold_Place(@LotId)` |
| **CONDITIONAL** | Q4 decision — either treat as blocking (require supervisor override) or allow check-out with a flagged disposition | `InspectionResultCode = Conditional` already exists |
| **Re-inspect after Fail** | Allowed — a held/any-status LOT can be re-inspected (`QualitySample_Record` accepts any LOT status); a subsequent PASS + `Hold_Release` clears the path | reuse `Hold_Release` |

**Key convention preserved:** the *proc* never auto-holds (FDS-08-012); the *station view* enforces the pass gate and offers the hold. The check-out proc re-asserts the gate server-side for integrity. This split keeps `QualitySample_Record` reusable elsewhere while giving the station its stricter UX.

**Supervisor override (Q4):** if a Conditional/Fail must be over-ridable to check out anyway, reuse the per-action AD-elevation pattern (initials + AD elevation for protected actions) rather than inventing a new mechanism.

---

## 9. Edge cases

1. **Duplicate check-in / re-scan of the same vendor LTT.** `Lot_Create` `@LotName` uniqueness pre-check + `UQ_Lot_LotName` backstop rejects a re-scanned pre-printed LTT. If vendor LTTs are *not* unique across shipments, minting server-side (Q1) avoids collisions — decide per Q1.
2. **Check-out before inspection.** Gate blocks (no PASS on record). Proc re-asserts. Toast: "Inspect before check-out."
3. **Fail then walk away.** LOT sits at the station in the inspection queue (derived state) until held, re-inspected, or checked out — visible to the next operator. Consider a stale-LOT surfacing (out of MVP; flag).
4. **Partial fail (some attributes fail, some pass).** Overall = Fail if any **required** attribute fails; optional-attribute fails are informational. Matches `QualitySample_Record` rollup exactly.
5. **No active quality spec for the part.** Inspection form can't load. Decide (Q8): block check-in? allow check-in but require a spec before check-out? allow check-out with a "not inspected" disposition? **Recommended:** allow check-in, block check-out until a spec exists / an inspection is recorded — surfaces the config gap without stranding material.
6. **AIM pool empty (only if Path B).** `Container_Complete` hard-fails and leaves the container open (OI-33) — same as assembly. Third-party parts likely have their **own** AIM shipper-id pool keyed by part number; confirm the pool is seeded (Q3/seeding registry).
7. **Held LOT re-inspection.** Allowed by proc. UX must make the "re-inspect a held LOT → pass → release hold → check out" path obvious.
8. **Fallback/unregistered terminal.** Whole-facility `zoneLocationId` → inspection queue reads plant-wide + false eligibility. Same trap as every plant-floor view; subtitle "Madison Facility" is the tell.
9. **Serial-range parts.** If third-party parts are serialized (Honda serialization on some lines), the serial range is captured at check-in; whether per-serial inspection is required is a spec question (Q2/Q8) — MVP likely inspects at the LOT level.
10. **Off-site receipt (`ReceivedOffsite`).** UJ-06 says off-site receiving is standard Perspective via VPN — the same station view could serve both origins, or off-site uses a separate flavor. Flag (Q9) but low-risk.

---

## 10. Phased TDD implementation plan

**Do not start until Open Questions Q1–Q7 are answered** (Q1/Q3 change the data model). Sequence SQL → NQ → view (SQL and NQ serial; only new views parallelize). Validate on a throwaway `MPP_MES_Test`, never destructively reset `MPP_MES_Dev`.

**Phase 0 — Decisions & scope lock.** Resolve Open Questions with MPP. Confirm Scope Matrix reading (Q7). Confirm the active-spec-for-item resolver exists (Q8). Output: a one-page decision annex appended here. *(No code.)*

**Phase 1 — Read + queue (SQL, TDD).**
- `Lots.Lot_GetInspectionQueueByLocation` (+ test suite `00NN_.../010_*`): checked-in-awaiting list, ET timestamps, descendant handling, empty-result = empty set (no invented 404).
- Confirm/add `Quality.QualitySpecVersion_GetActiveForItem` if missing (thin read + test).

**Phase 2 — Check-out proc (SQL, TDD) — the core new logic.**
- `Workorder.InspectionCheckOut` Path A (simple release): validations pre-txn (Received origin, at station, PASS on record, no open hold, destination valid), inline movement, audit `InspectionCheckedOut`. New audit `LogEventType` (guarded, next id).
- Test suite: happy path; reject no-inspection; reject Fail; reject open-hold; reject already-checked-out; INSERT-EXEC capture + rollback test.
- **Defer Path B** (container/AIM) behind Q3 — if selected, a second slice delegating to `Container_Complete`.

**Phase 3 — Additive seeds (SQL migration).**
- New versioned migration `00NN_inspection_station_*.sql`: any `SampleTriggerCode` (`Receipt`), `HoldTypeCode`, audit event/entity seeds — ASCII-only, idempotent, `SchemaVersion` row. Re-verify next-free ids at build time.

**Phase 4 — Ignition backend (Core NQs + entity glue).**
- Core NQs (`type` correct per status-row rule), thin entity methods. No business logic in Python.

**Phase 5 — Station view (new view, file-authored + scan).**
- `ThirdPartyInspection` view: three panels, reusing `ReceivingDock` check-in, a quality-capture form (first shop-floor consumer of Phase 9 capture), the check-out gate. Route + NavTree wiring. `scan.ps1`.

**Phase 6 — Designer smoke + docs.**
- Live smoke: check-in a vendor LOT → inspect (pass + fail paths) → hold on fail → re-inspect → check-out on pass. Verify audit timeline (LotCreated → InspectionRecorded → CheckedOut) and ET timestamps.
- Docs: FDS section (new `FDS-XX-NNN` requirements with FRS 2.1.1 / 2.1.12 crosswalk, scope-tagged), Data Model changelog if any additive schema, OIR entry, PROJECT_STATUS.

**TDD discipline throughout:** write the failing test first (INSERT-EXEC into a temp table matching the SELECT shape), then the proc; teardown FK order (closure/audit before LOTs); reuse dynamic location lookups (no legacy-seed coupling).

---

## 11. OPEN QUESTIONS (customer input required — this feature especially needs it)

> These are ordered by blast radius. **Q1, Q3, Q7 gate the data model / scope and must be answered before any build.** The rest can be defaulted per §1 but should be confirmed.

**Q1 — Identity of third-party parts. (Data-model gating.)**
What identity does an incoming third-party LOT get?
- (a) **External vendor LTT** scanned at check-in and used as `LotName` (`Lot_Create @LotName`), or
- (b) a **server-minted** MPP `LotName` with the vendor's number in `VendorLotNumber`, or
- (c) some **hybrid** (MPP LTT printed + vendor number retained)?
Are vendor LTTs guaranteed **unique**? (Affects the uniqueness pre-check vs. mint-server-side decision.) Is a **printed MPP LTT** required at check-in (like receiving prints one today)?
*Recommended default: (b)/(c) — mint MPP identity, print LTT, retain `VendorLotNumber`; safest against non-unique vendor tickets.*

**Q2 — ItemType and which items. (Data-model / config gating.)**
Are third-party parts modeled as existing `Parts.Item`s with `ItemType` = **FinishedGood**, or purchased **Component**, or a new "third-party" ItemType? How are they made **eligible** at the inspection station location (ItemLocation eligibility config)? Is there a finite catalog of third-party part numbers, and who maintains it?
*Recommended default: existing Items (FinishedGood or Component), eligible at the station via standard ItemLocation config; no new ItemType.*

**Q3 — What does "check-out" actually produce? ("Just like assembly out" — how literally?) (Data-model / scope gating.)**
Does check-out:
- (A) **Simply release** the same LOT into inventory / storage (a move, no new part number, no container, no ship label) — the lighter reading; or
- (B) **Package + label like assembly-out** — open/attach a `Container`, claim an **AIM shipper id**, print a `ShippingLabel`, and mark it ready to ship?
Do these parts **ship straight out** (→ AIM path B) or **feed into the plant** for further use (→ move-to-inventory path A, and note downstream tracking is FUTURE per Q7)? If (B), is there a **separate AIM shipper-id pool** for third-party part numbers, and is it seeded?
*Recommended default: (A) simple release for MVP; escalate to (B) only on explicit confirmation these ship straight out.*

**Q4 — Does inspection PASS/FAIL gate check-out? What about Conditional? (UX + proc-gate.)**
- Confirm **FAIL blocks check-out** and offers a one-tap Hold (recommended).
- **CONDITIONAL** result: block (require supervisor override), or allow check-out with a flagged disposition?
- Is a **supervisor/AD override** required to check out a failed/conditional LOT anyway? (Reuse per-action AD elevation.)
*Recommended default: Fail blocks + one-tap Hold; Conditional requires supervisor override; Pass releases.*

**Q5 — Explicit station state, or derived? (Minor schema.)**
Is a checked-in-not-yet-checked-out LOT tracked as a **derived state** (`Received` LOT residing at the station, no check-out event — recommended, no schema) or does MPP want an explicit reportable `AwaitingInspection` `LotStatusCode`?
*Recommended default: derived, no new status code.*

**Q6 — Sample trigger for incoming inspection. (Trivial seed.)**
Use the existing `Manual` trigger (id 9), or add a dedicated `Receipt` / `IncomingInspection` `SampleTriggerCode`? Is every incoming LOT inspected (100%), or **sample-triggered** (which pulls in Scope row 9 **Sampling = CONDITIONAL**)?
*Recommended default: add `Receipt` trigger; 100% inspection for MVP (sampling is CONDITIONAL, out of default scope).*

**Q7 — Scope boundary confirmation. (Scope gating — critical.)**
The Scope Matrix marks **Receiving / Inspections / Holds = MVP** but **"Pass-through Parts Tracking" = FUTURE** (row 20). Confirm we build **only the station** (check-in → inspect → check-out to inventory/ship) and **NOT** the downstream in-plant tracking/genealogy of these parts. If the customer actually expects these parts tracked through machining/assembly, that is **FUTURE scope** and a separate conversation — flag, don't build.

**Q8 — Which quality spec drives the inspection, and what if there isn't one? (Config dependency.)**
Does inspection bind to the part's **item-level active `QualitySpecVersion`** (confirm a `GetActiveForItem` resolver exists)? What happens when a third-party part has **no published spec** — block check-in, allow check-in but block check-out, or allow check-out uninspected with a disposition? Who authors these specs (MPP Quality)? Is this a **seeding-registry** dependency (specs owed before cutover)?
*Recommended default: bind to item-level active spec; allow check-in, block check-out until a spec + passing inspection exist.*

**Q9 — On-site vs off-site receipt.** Does this same station serve `ReceivedOffsite` (UJ-06 VPN) origin, or is off-site a separate flavor? *(Low risk; recommended: one view, origin selectable/derived from terminal.)*

**Q10 — Serialization.** Are any third-party parts serialized, and if so is inspection per-serial or per-LOT? *(Recommended default: per-LOT for MVP; per-serial is expanded scope.)*

---

## 12. Assumptions log (explicit, all flagged above)
- A1: The feature is composable from MVP primitives; **no new subsystem**. (High confidence.)
- A2: Received parts are **unrouted** — not threaded through `OperationRoleKind` queues. (Confirm via Q7.)
- A3: `QualitySample_Record` is reused **verbatim**; the pass gate lives in the view + re-asserted in the check-out proc, honoring FDS-08-012's no-auto-hold. (High confidence.)
- A4: At most **one new proc** (`InspectionCheckOut`) and **zero new tables** in the recommended path. (Gated on Q1/Q3.)
- A5: Check-in is a near-fork of the existing `ReceivingDock` view. (High confidence.)

---

## 13. Revision history
| Version | Date | Author | Change |
|---|---|---|---|
| 0.1 (DRAFT) | 2026-07-23 | Blue Ridge Automation | Initial design + implementation plan. Blocked on Open Questions Q1–Q10 (esp. Q1/Q3/Q7). No code written. |
