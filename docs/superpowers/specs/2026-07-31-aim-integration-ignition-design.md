# AIM Integration into Ignition — Generic Pool, Real Transport, Post-Back with Retry

**Date:** 2026-07-31
**Status:** Design — approved in brainstorming, pending spec review
**Interface reference:** `notes/2026-07-28_aim-interface-contract.md` (verified contract, diagnostic history, AIM Vision menu paths)

---

## 1. Why

The AIM (Honda EDI) interface was blocked from 2026-07-16 because every external call was a stub and
we had no verified contract. On 2026-07-31 both endpoints were proven end-to-end against MPP's live
AIM server (`172.17.10.86:8080`, test company `01`): `nextserial.csv` issues serials and
`postserial.csv` creates real labels. That unblocks the build.

Two facts from the verified contract force design changes beyond "fill in the stubs":

1. **`nextserial.csv` accepts no part parameter.** Serials are unique per *company code*. The built
   pool is per-part (`AimShipperIdPool.PartNumber NOT NULL`), and FDS-07-010's per-part topup loop
   is therefore unimplementable as specced. **The pool must become generic.**
2. **`postserial.csv` is the mechanism that creates the label in AIM**, not merely a re-sort
   concern as FDS-07-012 frames it. Today the MES claims a pooled ID at container completion and
   never posts back — **AIM would never learn what any container contains.**

## 2. Scope

**In scope**

- **A.** Genericize `Lots.AimShipperIdPool` — drop the part dimension from the table, procs, inline
  claim, alarm loop, tile, seed and tests.
- **B.** `BlueRidge.Lots.AimHttp` — the real HTTP transport, replacing the `topupTick` no-op.
- **C.** Post-back: payload + status columns on the pool row, synchronous post at completion, and a
  retry sweep with escalation and a manual-resolution path.

**Out of scope**

- `Parts.Item.AimCustomerPartNumber` — the column and its Item Master field are being added
  separately (Hunter). This design *consumes* it; see §10.
- AIM hold notifications (FDS-07-011). The agreement covers label creation only; Appendix L implies
  QA performs holds by hand in AIM's UI. Unresolved, tracked in the interface note.
- Sort Cage re-pack traceability (FDS-07-012's `previousSerial`). No HTTP equivalent exists.
- OI-33 empty-pool policy. Unchanged business decision; current hard-fail behaviour is retained.

## 3. Verified contract (summary)

Full detail in the interface note. What this design depends on:

```
POST /mes/floor/{Company}/{Token}/nextserial.csv          body: CRLF CRLF
  -> 9-digit zero-padded serial + CRLF

POST /mes/floor/{Company}/{Token}/postserial.csv?\r\n{serial}\t{part}\t{qty}\t{lot}\r\n
     body: EMPTY (Content-Length: 0)
  -> the same serial + CRLF on success
```

- The payload goes in the **query string**, URL-encoded, with an **empty body**. `%5C` is a
  backslash, so `%5Cr%5Cn` is the *text* `\r\n` and `%5Ct` is the *text* `\t` — literal escape
  sequences, not control characters.
- **Success** = reply equals the serial sent. **Failure** = an echo of the request (begins `POST `).
- The part field is AIM's **Customer Part**, not our part number and not AIM's item number.
- Verified behaviours: duplicate serials are **rejected** (no duplicate label, first write wins);
  serials may be posted **out of order**; quantity is **unconstrained**.

## 4. Schema

### 4.1 Migration `0048_aim_pool_generic_and_postback.sql`

**Genericize.** Drop `IX_AimShipperIdPool_AvailableByPart`, drop column
`AimShipperIdPool.PartNumber`, create:

```sql
CREATE INDEX IX_AimShipperIdPool_Available
    ON Lots.AimShipperIdPool (FetchedAt) WHERE ConsumedAt IS NULL;
```

Existing rows survive — they were always just IDs; only the part dimension disappears.

**Post-back columns** on `Lots.AimShipperIdPool`:

| Column | Type | Purpose |
|---|---|---|
| `CustomerPartNumber` | `NVARCHAR(50) NULL` | AIM customer part, snapshotted at completion |
| `Quantity` | `INT NULL` | sum of closed `ContainerTray.PartsClosedCount` |
| `LotNumber` | `NVARCHAR(50) NULL` | first tray's finished-good LOT name |
| `PostedAt` | `DATETIME2(3) NULL` | success stamp — the entire flag |
| `PostAttempts` | `INT NOT NULL DEFAULT 0` | drives escalation |
| `LastPostAttemptAt` | `DATETIME2(3) NULL` | last attempt |
| `LastPostError` | `NVARCHAR(500) NULL` | why it failed |

```sql
CREATE INDEX IX_AimShipperIdPool_Unposted
    ON Lots.AimShipperIdPool (ConsumedAt)
    WHERE ConsumedAt IS NOT NULL AND PostedAt IS NULL;
```

**`PostedAt IS NULL AND ConsumedAt IS NOT NULL` is the complete definition of "owed to AIM."** No
status enum, no state machine. Rows leave the sweep's index on success, so it stays small.

**Config columns** on `Lots.AimPoolConfig` (already single-row):

| Column | Type | Example |
|---|---|---|
| `AimBaseUrl` | `NVARCHAR(200) NULL` | `http://172.17.10.86:8080` |
| `AimCompanyCode` | `NVARCHAR(10) NULL` | `01` |
| `AimPathToken` | `NVARCHAR(50) NULL` | `636652666553236784` |
| `PostWarningAgeMinutes` | `INT NOT NULL DEFAULT 30` | backlog age warning |
| `PostCriticalAgeMinutes` | `INT NOT NULL DEFAULT 120` | backlog age critical |

The path token is configuration rather than a constant because we do not know whether it varies per
environment. The existing depth thresholds mean something different (pool supply, not post backlog),
hence separate age columns.

### 4.2 Procedure changes

| Proc | Change |
|---|---|
| `Lots.AimShipperIdPool_Claim` | drop `@PartNumber`; global FIFO claim; global empty-pool rejection |
| `Lots.AimShipperIdPool_Topup` | drop `@PartNumber` |
| `Lots.AimShipperIdPool_GetDepth` | drop `@PartNumber`; returns a single depth row, not per-part |
| `Lots.Container_Complete` | inline claim loses its part predicate; **writes payload columns inside the same transaction**; result-set shape unchanged |
| `Lots.AimPoolConfig_Get` / `_Update` | carry the new config columns |

**New:**

| Proc | Purpose |
|---|---|
| `Lots.AimShipperIdPool_GetForPost @AimShipperId` | read one row's payload for posting |
| `Lots.AimShipperIdPool_RecordPostResult @Id, @Success, @Error` | stamp `PostedAt` or increment attempts + record error |
| `Lots.AimShipperIdPool_ListUnposted @Top` | sweep + supervisor list read (ET timestamps) |
| `Lots.AimShipperIdPool_MarkPosted @Id, @AppUserId, @Note` | human-confirmed resolution, audited |

`Container_Complete`'s terminal `SELECT` is deliberately **unchanged**. Adding payload columns would
break every fixed-shape `INSERT-EXEC` capture in the existing suite for no benefit, since the post
path re-reads what it needs.

## 5. Transport — `BlueRidge.Lots.AimHttp`

The one place AIM calls leave the Gateway, mirroring what `LabelTransport` did for ZPL. Nothing else
builds a URL or interprets a reply.

```
nextSerial()                                -> {ok, serial, error}
postSerial(serial, customerPart, qty, lot)  -> {ok, error}
```

**Success detection is exact, not heuristic.** `nextSerial` succeeds when the trimmed reply is
exactly 9 digits. `postSerial` succeeds when the trimmed reply **equals the serial sent** — the echo
can never satisfy this because it begins `POST `. This is stricter than a byte-length rule and
catches truncated or interleaved replies.

On failure the first 200 characters of the reply become `LastPostError`, so a stuck row carries its
own diagnosis.

**Every call logs to `Audit.InterfaceLog`** through the `UpdateQuery`-typed `Audit_LogInterfaceCall`
NQ via `Common.Db.execNonQuery` (FDS-01-014). `AimShipperIdPool.FetchedInterfaceLogId` already links
a pooled ID back to the call that issued it.

**Neither function ever throws.** Bounded connect/read timeouts (a few seconds) — a container
completion must never hang on AIM.

### 5.1 URL-encoding hazard (commissioning gate)

The payload is `%5Cr%5Cn...` — and `%5C` is itself a percent-encoding. If Ignition's HTTP client
re-encodes the URI we hand it, those become `%255C`, AIM receives literal `%5C` text instead of
backslashes, and the call fails **exactly** the way our early attempts did. The module must build the
URI so no second encoding pass occurs.

**Verifying this in the Gateway Script Console against company `01` is a hard gate before any
terminal wiring.** It is the single failure mode that would be hardest to diagnose from inside
Perspective.

## 6. Runtime flow

### 6.1 One entry point

`BlueRidge.Lots.AimPost.postOne(aimShipperId)`:

1. Read the row (`_GetForPost`).
2. If `CustomerPartNumber` is missing -> return `NoCustomerPart` **without calling AIM**; record the
   attempt with a config-gap error.
3. Otherwise `AimHttp.postSerial(...)`.
4. `_RecordPostResult` — stamp `PostedAt` on success, else increment attempts and store the error.

Both the synchronous completion path and the retry sweep call exactly this, so there is one
definition of "post a serial" and retry cannot drift from first-attempt behaviour.

Because `postOne` **re-reads the payload on every attempt**, a config-gap row self-heals: the moment
someone sets the item's `AimCustomerPartNumber`, the next tick succeeds with no requeue.

### 6.2 Completion

`Container_Complete` writes `CustomerPartNumber`, `Quantity` and `LotNumber` onto the claimed row
**inside the existing claim transaction** — a rolled-back container never leaves an owed row; a
committed one is owed the instant it commits.

`Container.complete` (Ignition) then calls `postOne` **after** the proc has committed, alongside the
existing label dispatch. An AIM outage can therefore never roll back a container or lose a label.

Operator feedback branches on the outcome:

| Outcome | Feedback |
|---|---|
| Success | none (normal completion) |
| Transport failure | toast: *"AIM not updated for `000000024` — will retry automatically."* |
| `NoCustomerPart` | **modal popup requiring acknowledgement** (below) |

> **AIM not updated — no customer part number**
> Part `<PartNumber>` has no AIM customer part number configured. The container completed and the
> label printed, but Honda's system was not updated. A supervisor must set this in Item Master.

The config gap is an actionable configuration error, not a transient outage, so it gets a modal the
operator must dismiss rather than a passive toast. The row is still recorded and still retried in the
background — the popup is what makes it visible.

### 6.3 Retry sweep

New Gateway timer `AimPostTimer` (60 s) -> `AimPost.retryTick()`:

- `_ListUnposted` oldest-first, bounded batch (50).
- `postOne` each, individually guarded so one failure cannot abort the batch.
- The whole tick wrapped so it can never throw — same discipline as the existing pool and PLC timers.
- **No ordering discipline required** — serials are independent (verified).

**Ships disabled.** Enabled only after the §5.1 Script Console gate passes, so a half-configured
Gateway cannot post to AIM before the wire format is verified in situ.

### 6.4 Escalation and manual resolution

`alarmTick` extends to raise the existing session-alarm mechanism on **backlog age** against
`PostWarningAgeMinutes` / `PostCriticalAgeMinutes`.

The `/aim-pool` screen gains an unposted list — serial, container, age, attempts, `LastPostError` —
so the failure reason is visible without a log dig.

**`MarkPosted`** is the exit for the ambiguous case: AIM accepted a post but the reply was lost
(dropped connection, timeout after processing, Gateway restart mid-call). A retry then gets the echo
and reads as failure forever — safe, but never self-healing, and AIM exposes no query endpoint to
disambiguate. The supervisor confirms the label on AIM's Unshipped Labels report, marks it posted
behind a confirmation popup, and the row leaves the backlog. Audited as a human decision because the
MES cannot verify it.

## 7. Error handling summary

| Failure | Behaviour |
|---|---|
| AIM unreachable / timeout | post fails, row stays owed, toast, retried each tick |
| AIM rejects (echo) | same; `LastPostError` carries the reply |
| Missing customer part | no AIM call, modal popup, row owed, self-heals on config |
| Empty pool at completion | unchanged — hard-fail, container stays open (OI-33) |
| Gateway restart mid-post | row stays owed, retried; may need `MarkPosted` if AIM took it |
| Timer script throws | impossible by construction — guarded per-row and per-tick |

## 8. Testing

**SQL** — new: claim with no part dimension; global empty-pool rejection; concurrent claim (the
`READPAST` path without the part predicate); payload write inside the completion transaction;
`RecordPostResult` both branches; `MarkPosted` attribution; `ListUnposted` shape and ET conversion.
**Rewritten:** `0028/035` (`AimPool_claim_topup`) and `0029/040` (`AimPoolConfig`) for the dropped
parameter and new columns.

**Full-suite re-run is mandatory**, not optional: proc signature changes break fixed-shape
`INSERT-EXEC` captures in places that are not obvious. Note the branch already carries 7 pre-existing
`ERROR running` files (see PROJECT_STATUS 2026-07-28) — that baseline must be established before and
after so new breakage is distinguishable.

**Ignition** — no Jython unit harness, so two explicit gates:

1. **Script Console** — `AimHttp.nextSerial()` and `postSerial(...)` against company `01`, proving
   the URI survives without double-encoding (§5.1).
2. **End-to-end** — complete a real container in Dev; confirm the serial on AIM's Unshipped Labels
   report (Shipping -> Bar Code Reports -> Unshipped Labels -> by Destination/Customer Part, Print =
   All) with correct part, quantity and lot.

**Company `01` only.** Production runs on company `99` from the legacy MES box (`172.17.10.8`),
counter at ~13.84M. MES traffic must never target `99`.

## 9. Change inventory

| Layer | Items |
|---|---|
| SQL migration | `0048_aim_pool_generic_and_postback.sql` |
| SQL procs | 6 modified, 4 new (§4.2) |
| SQL seed | `028_seed_aim_pool_dev.sql` — drop part column |
| SQL tests | 2 suites rewritten, 1 new suite |
| Core scripts | new `AimHttp`, new `AimPost`; `AimPool` + `AimPoolConfig` signatures; `AimPoolGateway.topupTick` implemented, `alarmTick` extended |
| Named queries | 4 new (one per new proc); 5 modified (`AimShipperIdPool_Claim`/`_Topup`/`_GetDepth`, `AimPoolConfig_Get`/`_Update`) |
| MPP timers | new `AimPostTimer` (disabled at ship) |
| Views | `AimPoolConfig` screen (config + unposted list + MarkPosted); `AimPoolTile` (drop per-part, add backlog); `Container.complete` popup/toast branch |

## 10. Dependencies and open items

1. **`Parts.Item.AimCustomerPartNumber`** — owned by Hunter. Name follows the existing
   `MacolaPartNumber` precedent and must be agreed before the read is written.
2. **Customer-part data** — the values are not derivable from our part numbers (AIM's X-Ref shows
   `11300R70 A000` -> `11300R7- A000`, `112006FBAA000` -> `112006FB A000`). Sourcing them from AIM is
   an ask to MPP.
3. **Exceptions-folder access** — a rejected duplicate writes **no** exception file, so the folder is
   an incomplete failure oracle. Remote access (`C$`, WinRM) is blocked from the dev box. Needs MPP
   IT before anything is designed on it.
4. **Production company code** — `01` is test. The production code and its counter position must be
   confirmed with MPP before cutover.
5. **Holds and `previousSerial`** — no interface exists. FDS-07-011 and FDS-07-012 remain unsatisfied.
