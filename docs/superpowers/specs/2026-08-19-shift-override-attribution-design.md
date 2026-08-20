# Shift Override — Attribution Design

> **Status: DESIGN, NOT BUILT.** Written 2026-08-19 for Hunter's review. Extends the
> shift-override work already in the working tree (`0059_oee_shift_override.sql`,
> `Oee.ufn_ShiftWindowForLocation`, `Oee.ufn_ResolveOeeEquipment`,
> `Oee.Shift_GetAvailability`, `Views/Oee/ShiftOverrides`) — none of that changes.
> What is missing is *attribution*: making work performed during an extension count
> against the extended shift instead of rolling onto the next one.

---

## 1. The requirement

> "The shift time a shift runs on a specific day at a machine can be extended so that
> the OEE calculations can handle work being done for shift one after its normal time.
> This is supposed to make it so the work done against a shift and a machine stays at
> that shift instead of overlapping onto the next." — Hunter, 2026-08-19

Concretely: First shift ends 14:30 plant-wide. Press `DC1-M01` runs to 16:00. A basket
released at 15:00 must count against **First**, for that press only. Every other press
rolls to Second at 14:30 as usual.

## 2. Why the current build does not do this

`Oee.ShiftOverride` + `ufn_ShiftWindowForLocation` resolve a **window**. Nothing consumes
that window when an event is *stamped*. Two distinct stamping styles exist:

| Site | How it gets `ShiftId` |
|---|---|
| `Oee.DowntimeEvent_Start` | **server-resolved**: `SELECT TOP 1 Id FROM Oee.Shift WHERE ActualEnd IS NULL ORDER BY ActualStart DESC` |
| `Oee.DowntimeEvent_RecordApproximate` | `@ShiftId` param, falling back to the open shift |
| `Oee.DowntimeEvent_RecordHistorical` | resolves by comparing the event instant to `Oee.Shift` bounds |
| `Oee.EndOfShiftEntry_Submit` | from the submitted shift |
| `Workorder.DieCastShiftOutput_Record` | `@ShiftId` **param, chosen by the operator on screen** |
| `Lots.DieCastLot_Release` | `@ShiftId` param |

So production entry is *already* operator-attributed — an operator can pick First at
15:00. The gap is (a) everything server-stamped, and (b) the fact that the screen's
preselection and every downstream read still say "the plant-open shift".

`Oee.Shift` itself stays plant-global and single-open (OI-35 B3). **This design does not
change that**, and does not create per-equipment `Oee.Shift` rows.

## 3. Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | **An override moves a BOUNDARY, it does not create an overlap.** If First ends 16:00 for a press, Second *starts* 16:00 for that press. | Makes attribution total and unambiguous — every instant maps to exactly one shift. Removes the double-count the OEE agent flagged, where extension minutes counted toward both shifts' availability. |
| D2 | **Attribution resolves at WRITE time, into the existing `ShiftId` columns.** Not derived at read time. | `ShiftId` feeds die-cast totals, the downtime report, EOS and availability, on partitioned tables with 20-year retention. Converting every shift-bucketed read to a range join is a large, risky change that gives up an indexed equality. Keeping the column authoritative preserves every existing read, index and test. |
| D3 | **Retroactive overrides are allowed, and re-stamp existing rows.** | Confirmed by Hunter 2026-08-19. Nobody knows a shift ran long until after it did, so retroactive is the NORMAL path, not the exception. Write-time resolution alone would leave the 15:00 basket stamped Second forever. |
| D4 | **No hard cutoff on how far back an override may be edited — yet.** | Hunter, 2026-08-19: "not yet". Design so a lock point can be added later without rework: the restamp is a single proc, so a guard becomes one rejecting validation in one place. See OI-1. |
| D5 | **Equipment grain is the Cell (the press).** | Confirmed by Hunter. Matches `Oee.ufn_ResolveOeeEquipment` and `Oee.ufn_ResolveDowntimeScope`, and matches `Oee.DowntimeEvent.LocationId`. |
| D6 | **`Oee.ShiftOverride` keeps `LocationId NOT NULL`** — no plant-wide row. | A plant-wide change is a `ShiftSchedule` edit, which already exists. Two ways to express the same thing invites drift. |

## 4. What gets built

### 4.1 `Oee.ufn_ShiftIdForInstant(@LocationId, @InstantUtc)`

The single attribution authority. Returns at most one row: `ShiftId`, `ShiftScheduleId`,
`IsOverridden`.

- Resolves the effective window per D1: equipment override if present for that
  (LocationId, ShiftScheduleId, BusinessDate), else the global `Oee.ShiftSchedule`.
- **Half-open bounds** (`>= start`, `< end`) so back-to-back shifts never both match.
- **`(-1, 0)` business-date spine** — an instant at 02:00 local belongs to the *previous*
  business date's third shift.
- **Converts at the boundary.** `Oee.Shift.ActualStart/ActualEnd` and
  `Oee.ShiftOverride.StartTime/EndTime` are LOCAL Eastern (OI-38); event instants are UTC.
  This is the single most dangerous detail in the whole design — the same mismatch produced
  six defects on 2026-08-19, two of which corrupted stored data. Convert with
  `AT TIME ZONE` (DST-aware) and `CAST(... AS DATETIME2(3))`.
- **Zero rows is a real answer** (no shift running), not an error.

It maps an instant to an *existing* `Oee.Shift` row's Id. It never creates one — B3 intact.
When the press is still on First at 15:00 but First's `Oee.Shift` row is already closed,
that row still exists and is what gets stamped.

### 4.2 Stamping changes

- `Oee.DowntimeEvent_Start` — replace the open-shift lookup with
  `ufn_ShiftIdForInstant(@LocationId, SYSUTCDATETIME())`.
- `Oee.DowntimeEvent_RecordApproximate` / `_RecordHistorical` — same resolver for the
  fallback path; an explicit `@ShiftId` still wins.
- **Die-cast production**: the operator's shift picker stays authoritative. Only its
  *preselection* changes — point it at the resolver for the terminal's cell rather than
  "current plant shift". (The preselection was just wired in this session; it becomes
  equipment-aware rather than being rewritten.)

### 4.3 `Oee.ShiftOverride_Apply` — the restamp

Runs on override create / update / deprecate. For the affected
(LocationId, BusinessDate) it re-stamps rows whose correct shift changed, bounded to the
two shifts either side of each moved boundary.

- Rows in scope: `Oee.DowntimeEvent` (by `LocationId`), and
  `Workorder.DieCastContribution` — **but see §5, its grain does not match**.
- Writes one audit row per apply summarising what moved: shape
  `<EQUIPMENT> · Shift Override · Reattributed N events from <A> to <B>`, using
  `Audit.ufn_MidDot()` and `JSON_QUERY(...)` for resolved-name FK sub-objects.
- Idempotent — re-running changes nothing.
- This is the only part of the system that rewrites historical attribution. It must be
  explicit, audited and reversible by deprecating the override and re-applying.

## 5. The unresolved problem — DieCastContribution grain

**`Workorder.DieCastContribution` stores the TERMINAL, not the press.** The supervisor
dashboard had to derive the press as `Lot.ToolId` → the `Tools.ToolAssignment` active at
`EventAt`. That derivation is correct but historical: a die moved mid-shift attributes each
contribution to the press it was on at the time.

The restamp needs the same derivation, which makes it more expensive than a `LocationId`
equality and means **a die reassignment can retroactively change which override applies to
a past contribution.**

Options, none chosen:

1. **Derive at restamp time** via `ToolAssignment` (no schema change; the derivation is
   already written for the dashboard).
2. **Add `CellLocationId` to `DieCastContribution`**, stamped at write time. Makes the
   restamp a simple equality and freezes the press against later die moves — but it is a
   schema change plus a backfill, and only `DieCastShiftOutput_Record` /
   `DieCastLot_Release` write that table.

**DECIDED 2026-08-19 (Hunter): option (2) — stamp `CellLocationId` on
`Workorder.DieCastContribution` at write time.** Attribution must not silently change
when a die moves months later. Requires a new versioned migration adding the column
(NULL-able, FK to `Location.Location`), a backfill of existing rows via the
`Lot.ToolId` -> `ToolAssignment`-active-at-`EventAt` derivation, and both writers
(`Workorder.DieCastShiftOutput_Record`, `Lots.DieCastLot_Release`) stamping it. The
restamp then keys on a plain equality.

Backfilled rows carry the derivation's answer, which is the best available reading of
history; rows whose die had no active assignment at `EventAt` stay NULL and are
excluded from equipment-scoped restamps rather than being guessed.

## 6. Consequences to accept

- **Historical attribution becomes mutable.** With no cutoff (D4), a supervisor can rewrite
  the shift attribution of any past day. The audit row is the only record that it happened.
- **Availability and counts diverge in how they respond.** `Shift_GetAvailability` sums
  downtime by *time overlap*, so it is already correct without a restamp. Production counts
  are `ShiftId`-bucketed and only move once `ShiftOverride_Apply` runs. Both end up correct;
  they just get there differently.
- **DST is still unsolved.** Override windows are wall clock, so a window spanning a
  transition is off by 60 min — the Sat 23:00 → Sun 07:00 third shift, twice a year.
  Inherited from OI-38, not introduced here.
- **Sepasoft-style external consumers** do not exist in MPP, so nothing outside this schema
  needs to agree. If Honda-facing reporting ever buckets by shift, it must read through the
  same resolver.

## 7. Open items

| id | item |
|---|---|
| **OI-1** | No lock point on how far back an override may be edited (D4, deferred). When one is wanted, it is one rejecting validation in `ShiftOverride_Apply`, before `BEGIN TRANSACTION`. |
| ~~**OI-2**~~ | ~~`DieCastContribution` press grain~~ — **RESOLVED 2026-08-19**: stamp `CellLocationId` at write time. See §5. |
| **OI-3** | Should `ShiftOverride` gain a `DidNotRun` equivalent — "this equipment did not run this shift" — so availability can distinguish zero planned time from a data error? Not required by the stated requirement. |
| **OI-4** | Contiguity validation for D1: reject an override that would leave a gap or an overlap in a day's windows for one equipment. |
| **OI-5** | Elevation gating on override create/edit. Peer to backlog 4.1; interacts with 4.3 (no AD user source exists yet). |

## 8. Test obligations

- Instant exactly on a boundary lands in exactly one shift (half-open).
- 02:00 instant attributes to the previous business date's third shift.
- Extending First to 16:00 for one press moves a 15:00 event from Second to First **for
  that press only**; a sibling press is untouched.
- Deprecating the override restores the original attribution.
- Re-applying is idempotent.
- A midnight-crossing shift extended past midnight still ends next-day.
- Restamp writes exactly one audit row and reports the correct moved count.
