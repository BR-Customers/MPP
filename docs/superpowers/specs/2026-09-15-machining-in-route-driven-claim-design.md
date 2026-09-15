# Machining IN — Route-Driven Claim — Design Spec

**Date:** 2026-09-15
**Status:** Design, awaiting Jacques's review
**Migration:** none — two repeatable procs only
**Supersedes:** the location half of the Trim-Storage model (2026-07-23). The
*line-assigned-at-claim-time* half stands unchanged.

---

## 1. Motivation

Some oil pans do not go through the trim shop at all. Their routes are authored
accordingly — `DieCast → MachiningIn → …`, no `TrimIn`/`TrimOut` steps. **A
Machining IN operator cannot reach those castings.** They sit in the warehouse
and no screen in the plant will surface or claim them.

The route is correct. Two independent gates, both keyed on physical location,
override it:

| # | Gate | Where |
|---|---|---|
| G1 | **Read.** The Machining IN queue selects only LOTs whose `CurrentLocationId` is an `InventoryLocation` (`LocationTypeDefinitionId = 14`) under an area whose `Code LIKE 'TRIM%'`. | `R__Lots_Lot_GetTrimStorageQueueForLine.sql:36` |
| G2 | **Write.** `MachiningIn_RecordPick` step 4 repeats the same test server-side and rejects otherwise. | `R__Workorder_MachiningIn_RecordPick.sql:163` |

A released die-cast basket lands in `WHSE` by default
(`R__Lots_DieCastLot_Release.sql:127`). `WHSE` is a `ProductionArea` (def 4)
hanging directly off `MPP-MAD` (`011_seed_locations_mpp_plant.sql:483`) — it
fails both predicates. So a trim-skipping casting is stranded: the queue's route
filter (`NextOperationTypeCode = 'MachiningIn'`) and its line-eligibility filter
both pass; only the location kills it. Scanning the LTT directly at
MachiningPickScan does not rescue it either — G2 rejects with *"LOT is not in
Trim Storage (currently at Warehouse); it may already be claimed by another
line."*

Every seeded route runs through trim (`029_seed_item_routes.sql`), which is why
this has not surfaced yet.

**The underlying error.** The Trim-Storage model conflated two ideas: *the line
is assigned at claim time, not at Trim* (the real intent, and still correct) with
*claimable stock lives in Trim Storage* (an incidental consequence of trim being
universal at the time). Only the second is wrong, and only the second is removed
here.

---

## 2. Decisions locked (from brainstorming)

| # | Decision |
|---|---|
| D1 | **The route is the gate.** A LOT is claimable at Machining IN when its next pending route step is `MachiningIn`. Physical location stops being a gate and reverts to being a fact. |
| D2 | **No replacement "already claimed" test is needed.** `MachiningIn` is an `Advance` role, satisfied by a `ProductionEvent` on its template — which is exactly what `RecordPick` writes. The claim self-cancels the pending state. (§3.1) |
| D3 | **The race protection is untouched.** The claim CAS is keyed on the LOT's *current* location, whatever it is; it never depended on Trim Storage. (§3.2) |
| D4 | **The read must additionally exclude `Open`.** This is the one thing the location gate was silently doing for us. (§3.3) |
| D5 | **Held LOTs stay visible in the queue.** Preserves the view's "On Hold" indicator. Existing visible-but-not-claimable behaviour is deliberate and is retained. |
| D6 | **Names are not changed.** `Lot_GetTrimStorageQueueForLine` keeps its name at every layer. Headers carry the warning instead. (§5) |
| D7 | **`@StorageLocationId` is retained and ignored** on both procs, documented the way `TrimOut_Record` documents `@DestinationCellLocationId`. No NQ signature churn. |
| D8 | **Steps 3 and 4 of `RecordPick` collapse into one route lookup** via `ufn_NextPendingRouteStep`, so the gate and the resolved template cannot disagree. (§3.4) |
| D9 | **Die cast release is not touched.** `WHSE` is the right destination for a trim-skipping casting. The bug was never where it went, only who could reach it. |

---

## 3. Mechanism

### 3.1 Why "not already claimed" is free

`MachiningIn` carries `OperationRoleKind = 'Advance'`
(`0035_operation_role_kind.sql:42-46` — `DieCast` is `OriginMint`,
`MachiningOut`/`AssemblyOut` are `ConsumeMint`, everything else `Advance`).

`Lots.ufn_NextPendingRouteStep` holds an `Advance` step pending only until a
`Workorder.ProductionEvent` exists for that LOT on that step's
`OperationTemplateId`. Writing that event is precisely what
`MachiningIn_RecordPick` does. So the instant a line claims a LOT, its next
pending step becomes `MachiningOut`/`AssemblyOut` and it drops off **every**
line's Machining IN queue — with no location predicate involved at all.

The route already answers the question the location gate was answering.

### 3.2 Why the race protection is free

The claim's concurrency control is a compare-and-swap, not a location test
(`R__Workorder_MachiningIn_RecordPick.sql:222-236`):

```sql
UPDATE Lots.Lot
SET CurrentLocationId = @LineLocationId, ...
WHERE Id = @LotId AND CurrentLocationId = @FromLoc;

IF @@ROWCOUNT = 0  -- another line moved it first; COMMIT the no-op and reject cleanly
```

`@FromLoc` is read before the transaction and re-asserted inside it. This works
from any source location. Two lines racing on a warehouse LOT resolves exactly
as two lines racing on a Trim Storage LOT does today. **Unchanged.**

### 3.3 The one hazard the location gate was covering

The read excludes only `Closed`. Today an actively-filling die-cast basket
(`Open`, sitting at the press) is kept out of the Machining IN queue purely
because a press is not Trim Storage.

Remove the location predicate and — on a trim-skipping route, where `DieCast` is
`OriginMint` (never pending) and the next step **is** `MachiningIn` — a half-full
basket appears in the queue and is miscounted by the "On Hold" indicator, which
counts every row where `lotStatusCode != 'Good'`.

`RecordPick` step 2 already rejects `Open`, so the defect is cosmetic rather than
a data risk. It is still fixed: the read excludes `Closed` **and** `Open`,
matching `Lot_GetWipQueueByLocation`'s existing precedent. Held LOTs are
deliberately *not* excluded (D5).

### 3.4 One source for the gate and the template

Today step 3 resolves the operation template with its own inline route query and
step 4 tests the location. Both become one `ufn_NextPendingRouteStep(@LotId)`
lookup:

| Result | Behaviour |
|---|---|
| no row | reject — no active published route, or nothing pending |
| `OperationTypeCode <> 'MachiningIn'` | reject, citing the **actual** next operation |
| `OperationTypeCode = 'MachiningIn'` | proceed; `OperationTemplateId` from the same row is the template the checkpoint is written against |

This closes two latent inconsistencies as a side effect:

- Step 3's inline query accepts a **Draft** route (`rt.DeprecatedAt IS NULL`
  only), where the queue read requires `PublishedAt IS NOT NULL`.
- Step 3 ignores `EntryRouteSequence`, so cutover inventory counted in mid-route
  (migration `0080`) resolved the wrong way.

After this, what the operator sees in the queue and what the proc accepts come
from one definition. It is also a step toward the
`Parts.ufn_OperationTemplateForLotRole` convergence flagged at the top of
`PROJECT_STATUS.md`.

---

## 4. Changes

### 4.1 `Lots.Lot_GetTrimStorageQueueForLine`

- **Delete** the `TrimStores` CTE and the
  `l.CurrentLocationId IN (SELECT Id FROM TrimStores)` predicate in `Eligible`.
- **Change** the status filter from `sc.Code <> N'Closed'` to
  `sc.Code NOT IN (N'Closed', N'Open')`.
- **Retain, ignored:** `@StorageLocationId`.
- **Unchanged:** the `oty.Code = N'MachiningIn'` route filter, the
  `Parts.v_EffectiveItemLocation` ancestor-cascade eligibility gate, FIFO
  ordering by `COALESCE(CastDate, LastMovementAt)`, the result column shape.
- **Header rewritten** to state plainly that the name is historic and that the
  proc no longer looks at trim storage.

### 4.2 `Workorder.MachiningIn_RecordPick`

- **Replace** steps 3 + 4 with the single `ufn_NextPendingRouteStep` lookup of
  §3.4. New rejection messages name the actual next operation rather than a
  location.
- **Retain, ignored:** `@StorageLocationId`.
- **Unchanged:** step 2 status guard (`Closed`/`Open`/`BlocksProduction`), step
  2b CRT guard, step 4b line eligibility, step 5 terminal-on-line, the claim CAS
  and its `@@ROWCOUNT = 0` race branch, the movement row, the checkpoint
  `ProductionEvent`, the `MachiningInPicked` audit row.
- All new rejections stay **before** `BEGIN TRANSACTION` (FDS-11-011 +
  Msg-3915: each SELECTs the status row and `RETURN`s with no open transaction).

### 4.3 One comment-only Ignition edit; nothing else

No migration. No **Perspective view** changes and no named-query changes — the NQ
is a thin `EXEC` passing both parameters, and retaining `@StorageLocationId` (D7)
plus the names (D6) keeps every caller's signature byte-identical. **No Designer
session and no project export.**

One exception: `BlueRidge.Lots.Lot.getTrimStorageQueueForLine`'s docstring
currently reads *"the open LOTs sitting in Trim Storage whose next pending route
step is MachiningIn"*. After this change that sentence is **factually wrong**,
not merely stale-named, so it is rewritten (§5). That is a comment-only edit to a
Python module — a file type explicitly safe for file-based edits under the
CLAUDE.md Ignition edit boundary — followed by `.\scan.ps1` to sync the gateway.
No behaviour changes.

---

## 5. On keeping the name

`Lot_GetTrimStorageQueueForLine` will no longer select on trim storage. This is
accepted deliberately to avoid touching the MachiningIn view's binding
expression, which names the Python wrapper — an edit to an **existing**
`view.json`, which per CLAUDE.md belongs in Designer rather than in a file edit.

The mitigation is documentary and must not be skipped. Both the **proc header**
and the **Python docstring** (`BlueRidge.Lots.Lot.getTrimStorageQueueForLine`)
state that the name is historic, that the read is route-driven, and that trim
storage is now just one of several places a claimable LOT may sit. The docstring
is not optional politeness — its current text asserts the LOT is "sitting in
Trim Storage", which this change makes false.

The NQ's `query.sql` is left alone: it is a three-line `EXEC` with no prose to
contradict, and the docstring directly above it in the calling module is where a
reader actually looks.

A future rename to `Lot_GetMachiningInQueueForLine` remains open and should be
bundled with the next Designer session that touches the MachiningIn view for
other reasons.

---

## 6. Testing

Written TDD — tests first, red, then the proc changes. The existing suite
largely validates the new model unchanged, which is the evidence that this is
behaviour-preserving for the trim path.

| File | Change |
|---|---|
| `0024/065_Lot_GetTrimStorageQueueForLine.sql` | All five assertions pass **as written**. Two test *labels* corrected: their stated reason changes (e.g. "gone from line B queue (no longer in Trim Storage)" → because the `MachiningIn` step is now satisfied). |
| `0027/010_MachiningIn_RecordPick_happy.sql` | Passes untouched. It already pre-advances past `DieCast`/`TrimIn`/`TrimOut` and stages in `TRIM1-STORE`; the staging simply stops being load-bearing. |
| `0027/020_MachiningIn_RecordPick_guards.sql` | Guard 1 keeps its fixture and still rejects — `P5T-GUARD-A` is created with no `ProductionEvent`s, so its next pending step is `TrimIn`. Only the assertion text moves from `not in Trim Storage` to the new route message, and the test label is renamed. Guards 2 and 3 unchanged. |
| `0027/030_MachiningIn_NoTrimRoute.sql` **(new)** | The regression test. A part routed `DieCast → MachiningIn → AssemblyOut`, eligible at a machining line, with a `Good` LOT in `WHSE`. Asserts: (a) the LOT **appears** in that line's queue; (b) `MachiningIn_RecordPick` claims it from `WHSE` successfully, moving it to the line and writing the checkpoint; (c) after the claim it is **gone** from the queue; (d) an `Open` basket on the same route does **not** appear (§3.3). |

Full suite green via `Run-Tests`, not just the touched files.

---

## 7. Residual risk

With no location predicate, the claimable set is exactly: *next pending route
step is `MachiningIn`* **and** *item eligible at this line* **and** *status not
`Closed`/`Open`*. A LOT parked somewhere unexpected — a sort cage, an offsite
facility — that satisfies all three becomes claimable where today it is not.

In practice the status guards and the eligibility cascade cover this, and
CRT/held LOTs are refused at step 2. It is nonetheless a wider door than today,
by design, and is recorded here so a future reader does not mistake it for an
oversight.

---

## 8. Revision History

| Version | Date | Author | Change |
|---|---|---|---|
| 1.0 | 2026-09-15 | Blue Ridge Automation | Initial design. Route-driven Machining IN claim; removes the Trim-Storage location gate from the queue read and the claim proc. |
