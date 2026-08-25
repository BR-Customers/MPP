# Serialized Lines — What Number Validates a Part? (Brief for Tom)

**Date:** 2026-08-18
**Raised by:** FAT Day 1 punch list, item 7
**Owner:** Jacques → Tom → MPP
**Blocks:** MIP/PLC commissioning of the serialized assembly lines (`BlueRidge.Workorder.AssemblyPlc`)

---

## Purpose

On the serialized assembly lines, the MES is required to validate a part serial number
and hand a pass/fail bit back to the automation before the part may continue. We have
built that path, but **we do not know what the number actually is** — its format, who
generates it, or the scope over which it must be unique.

This brief gathers everything we know from the source documents and from what is already
built, isolates exactly what is ambiguous, and states the questions that need answering.

---

## 1. What the automation agreement specifies

Source: `reference/5GO_AP4_Automation_Touchpoint_Agreement.pdf` (Flexware Innovation,
document `2011230 5GO_AP4`, VCM Traceability System, last saved 2012-04-13). Converted
markdown at `reference/5GO_AP4_Automation_Touchpoint_Agreement.md`.

### 1.1 The tag

| Touch point | MES R/W | Type | Description (verbatim) |
|---|---|---|---|
| **`PartSN`** | Read | String | *"Serial Number is set in automation and is to be collected by MES upon DataRdy."* |
| **`PartValid`** | Write | Bool | *"MES Station Validation — Indicates that all rules and logic defined for the station have passed and the part is valid to continue through the process. MES sets this True when validation is passed. Required for the part to continue the process."* |
| **`MESInterlockEnable`** | Read/Write | Bool | Enables/disables *"the MES checks (e.g., duplicate serial number, serial number format validation) executed at the MES software level. MES will not record any information if the MES Interlock is Disabled."* |
| **`HardwareInterlockEnable`** | Read | Bool | Enables/disables MES checks executed **at the automation level** (quality checks, serial number processing). |

So the agreement names exactly two MES-side validations: **duplicate serial number** and
**serial number format validation**. It never says what the format *is*.

### 1.2 Which stations are serialized

From the touch point map (§1.2 of the agreement):

| Touch point | 5GO Assembly Fronts | 5GO Assembly Rears | PNA Assembly Out CH IN/EX 5,6 FP | PNA Assembly Out 1 RH 1-4 CH IN/EX 1-4 |
|---|---|---|---|---|
| **`PartSN`** | **Yes** | **Yes** | No | No |
| `PartValid` | Yes | Yes | Yes | Yes |
| `HardwareInterlockEnable` | Yes | Yes | Yes | Yes |

Glossary confirms: **5GO** = *"Production station designation (serialized, uses laser
marker)"*; **PNA** = *"Production station designation (lot-tracked, no serial number)."*

**Only the two 5GO assembly stations carry `PartSN`.** That is the entire serialized
footprint described by this document — which is dated 2012 and covers one project.

### 1.3 Where the number comes from — and the ambiguity

The architecture diagram (§1.3) shows the chain:

```
MES  ──ModBus TCP (OPC)/TopServer──  MIP (HMI + serial comms)  ──  Assembly PLC
                                       │
                                       └── Laser Marker   (serial comms)
```

`PartSN` is listed among the touch points communicated MES↔MIP over ModBus TCP, and the
MIP↔Laser Marker link is listed as carrying "Serial Number (serial comms)".

The 5GO part-complete flow (§1.4) reads:

```
[MIP] PartComplete set
  └─ MESInterlockEnable?
       └─ Yes ─► HardwareInterlockEnable?
                   ├─ No  ─► Set PartSN with "NoRead"
                   └─ Yes ─► Read PartSN from Laser Marker (Serial Comms)
                                └─ PartSN New and Valid Format?
                                     ├─ No  ─► Set PartSN with "NoRead"
                                     └─ Yes ─► [MIP] Set DataReady
```

> **This is the crux.** The flow says the MIP **reads** `PartSN` *from* the laser marker,
> which implies the **marker generates** the number. But the architecture diagram lists
> the MIP→Laser Marker link as carrying the serial number, which implies something
> **upstream supplies** it and the marker only marks it. Both readings are supportable
> from this document.
>
> It matters a great deal which is true — see §3.

Note also that the MIP performs its **own** "New and Valid Format?" check before ever
raising `DataReady`, and substitutes the literal string **`"NoRead"`** on failure. So MES
can receive `PartSN = "NoRead"` as a legitimate value and must decide what to do with it.

### 1.4 What MES does on `DataReady`

```
[MES] DataReady received
  └─ Reset DataReady; Set TransInProc; Read PartSN; Read HardwareInterlockEnable
       └─ PartSN Validation
            ├─ Fail ─► MES Alarms: Low Inventory Level / Invalid PartSN /
            │                      Duplicate PartSN / (others TBD)
            └─ Pass ─► Inventory > 0? ─► Open Container Exists?
                                          ├─ No  ─► Create Container, get ID from Base2,
                                          │          associate PartSN to new container
                                          └─ Yes ─► Add part count to container
                                                     └─ Last part? ─► Close container,
                                                                      transact with Base2,
                                                                      print label
                            └─ Reset TransInProc; Set PartValid;
                               Write ContainerCount; Write PartType
```

`Base2` is glossed as *"External system used for container ID management and label
printing"* — in our build that role is filled by the AIM pool and the Zebra/ZPL path.

---

## 2. What we have already built

### 2.1 Data model

`Lots.SerializedPart` (migration `0028_arc2_phase6_assembly.sql`):

| Column | Type | Notes |
|---|---|---|
| `SerialNumber` | `NVARCHAR(50)` | `CONSTRAINT UQ_SerializedPart_SerialNumber UNIQUE (SerialNumber)` — **globally unique, plant-wide, forever** |
| `ItemId` | `BIGINT` | FK `Parts.Item` |
| `ProducingLotId` | `BIGINT` | FK `Lots.Lot` — genealogy anchor |
| `EtchedAt` / `EtchedByUserId` | | PLC flow passes the system AppUser |

`Lots.ContainerSerial` links a serialized part to its container
(`UQ_ContainerSerial_Part UNIQUE (SerializedPartId)` — one container per part).
`Lots.ContainerSerialHistory` (migration `0029`) records moves.

**There is no format constraint on `SerialNumber` anywhere.** Any string up to 50
characters is accepted. Uniqueness is enforced globally.

### 2.2 The mint proc supports both models

[`Lots.SerializedPart_Mint`](../sql/migrations/repeatable/R__Lots_SerializedPart_Mint.sql)
takes an optional `@SerialNumber NVARCHAR(50) = NULL`, documented as
*"PLC/etch-supplied serial; NULL/empty = auto-generate"*:

- **Supplied** → checks `EXISTS (SELECT 1 FROM Lots.SerializedPart WHERE SerialNumber = @SerialNumber)`
  and rejects with *"Serial number `<x>` already exists."*
- **NULL/empty** → mints from the `SerializedItem` `Lots.IdentifierSequence` row, inline
  and row-locked so a rollback un-burns the counter.

So we can operate either way **today**. What we cannot do today is validate a *format*,
because we have not been told one.

### 2.3 The auto-generated format we inherited

`Lots.IdentifierSequence` seed (migration `0020_arc2_phase1_shop_floor_foundation.sql`):

| Code | FormatString | Start | End | LastValue (seed) |
|---|---|---|---|---|
| `Lot` | `MESL{0:D7}` | 1 | 9999999 | 3000000 |
| `SerializedItem` | `MESI{0:D7}` | 1 | 9999999 | 3000000 |

→ produces `MESI3000001`, `MESI3000002`, …

These formats are **carried over from the legacy Flexware MES**. Confirmed in the legacy
extract `reference/legacy_mes_extract/identifier_formats.csv`:

```
Id,Name,Format,StartingCounterValue,EndingCounterValue,ResetIntervalInMinutes
1,Lot Format,MESL{0:D7},1,9999999,
2,Serialized Item Format,MESI{0:D7},1,9999999,
```

> **This is strong evidence that the legacy MES *minted* the serial rather than reading it
> from the marker** — a marker-generated number would not be defined as an MES identifier
> sequence with a counter, a start value and an end value. If MPP confirms this, the
> "MES mints → MIP → marker marks it" reading of §1.3 is the correct one, and the flow
> diagram's "Read PartSN from Laser Marker" is a read-*back* for verification.

Both `LastValue` seeds are marked **PROVISIONAL** at the 3,000,000 floor, with the exact
cutover value owed from Ben (Seeding Registry **S-10**, cutover-only, not dev-blocking).

### 2.4 The gateway side

[`BlueRidge.Workorder.AssemblyPlc`](../ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/AssemblyPlc/code.py)
holds the orchestration skeleton. Its documented per-piece serialized flow on a `DataReady`
rising edge:

1. read `PartSN` (or mint via `SerializedPart.mint` when the MES mints the serial),
2. validate uniqueness + write `PartValid` back,
3. `ContainerSerial.serialAdd` (`HardwareInterlockBypassed=1` if the interlock is off),
4. `ConsumptionEvent.recordWithBomCheck` per BOM component consumed,
5. on tray-full → `Container.trayClose`; on container-full → `Container.complete`
   (claims an AIM ID from the pool).

`_WATCH = []` — the watcher is a deliberate no-op until commissioning supplies the
per-line tag map. Rising-edge detection, guarded error handling and system-user
attribution are all in place.

`Lots.ContainerSerial_Add` already carries a `HardwareInterlockBypassed` flag, so a piece
admitted while the hardware interlock was off is recorded as such.

---

## 3. Why the answers change what we build

| If … | Then … |
|---|---|
| **Marker generates the serial** | MES is a pure validator. We need the format spec to implement "Invalid PartSN". `SerializedPart_Mint` is always called with `@SerialNumber` supplied. The `SerializedItem` IdentifierSequence becomes dead for serialized lines. |
| **MES mints the serial** | We own the counter and must confirm `MESI{0:D7}` is still correct, and get the true cutover `LastValue` (S-10). Format validation is trivially satisfied because we generate it. We must also define how the number reaches the marker. |
| **Uniqueness is global** | Current `UQ_SerializedPart_SerialNumber` is correct as built. |
| **Uniqueness is per part number, or per line/day** | The unique index is **wrong** and must be re-scoped, or legitimate parts will be rejected as duplicates. This is a schema change — cheap now, expensive after go-live. |
| **`"NoRead"` should be rejected** | `PartValid` stays false, part is diverted; MES records nothing. |
| **`"NoRead"` should be accepted unserialized** | Needs a distinct path — `SerializedPart` cannot hold repeated `"NoRead"` values under a global unique index. **This is a live defect risk**: the second `"NoRead"` piece would be rejected as a duplicate, not because it is one. |
| **More lines are serialized than the 2012 doc lists** | Commissioning scope, tag map and `_WATCH` config all grow. |

---

## 4. Questions

### Q1 — Who generates the number? *(highest priority)*

On the serialized lines, is the part serial number:

- **(a)** generated by the **laser marker**, marked on the part, and read back by the MIP; or
- **(b)** generated by the **MES**, sent to the marker to be marked, and read back for verification; or
- **(c)** generated by some **third system**?

Our evidence points to **(b)** — the legacy MES defined `MESI{0:D7}` as a counter-based
identifier sequence, which only makes sense if the MES was the generator. Confirmation
either way settles the largest open question in the design.

### Q2 — What is the format?

- What is the mask, and the total length?
- **An example of a real serial number from a part currently in production would answer
  most of this on its own.**
- Is it still `MESI` + 7 digits, or did that change?
- If MPP mints it, what is the current counter value at cutover? (This is Seeding Registry
  item **S-10**, owed from Ben.)

### Q3 — What is the uniqueness scope?

Must the serial be unique:

- **globally** (plant-wide, forever) — what we have built; or
- **per part number**; or
- **per line per day**, or some other rolling window?

This determines our unique index. Getting it wrong in either direction is bad: too narrow
and we reject good parts, too wide and we admit duplicates Honda would reject.

### Q4 — Is it the same number the vision system reads?

Some stations use Cognex vision for tray validation. Is the number the camera reads at the
tray stations **the same** `PartSN`, or a different identifier (e.g. a SKU/model code
rather than a per-piece serial)?

Context: our analysis of the legacy camera/tray configuration
(`project_mpp_legacy_camera_tray_validation`) found **three distinct patterns** in use —
serialized per-part, tray per-slot, and tray vision-SKU-ID — and the OPC tag matrix
contradicts the FRS's assumption of a uniform positional scheme. So we should not assume
these are the same number.

### Q5 — Which lines are serialized today?

The 2012 agreement covers **5GO Assembly Fronts** and **5GO Assembly Rears** only. Is that
still the complete list, or have other lines been serialized since? We need the current
list to scope the MIP tag map and the `_WATCH` configuration.

### Q6 — What should MES do on `"NoRead"`?

When the MIP cannot read the marker it sets `PartSN = "NoRead"` and still raises
`DataReady`. Should MES:

- **reject** the piece (`PartValid` false, part diverted),
- **accept** it as an unserialized piece counted into the container, or
- **hold** it for operator/quality disposition?

Flagging the risk explicitly: option 2 does **not** work against the current schema,
because `SerialNumber` is globally unique and the second `"NoRead"` would collide. If MPP
wants "accept unserialized", we need to design that path deliberately.

### Q7 — What is the expected behaviour when the interlocks are off?

`HardwareInterlockEnable = false` means the automation-side checks are bypassed and
`PartSN` arrives as `"NoRead"`. `MESInterlockEnable = false` means *"MES will not record
any information"*. Confirm:

- With **MES interlock off**, does MES really record **nothing** — no container count, no
  genealogy? That is a traceability hole; we should understand when and why it is used.
- With **hardware interlock off** only, we currently record the piece with
  `HardwareInterlockBypassed = 1`. Is that the desired behaviour?

---

## 5. What would unblock us fastest

In rough order of value:

1. **One real serial number** from a part in production on a 5GO line (answers most of Q2).
2. **A yes/no on Q1** — MES-generated or marker-generated.
3. **The current list of serialized lines** (Q5).
4. Everything else can follow.

---

## 6. Related open items

- **Seeding Registry S-10** — identifier sequence baselines (`Lots.IdentifierSequence.LastValue`),
  owed from MPP IT at cutover. Directly related to Q2 if MPP mints.
- **PLC commissioning** — `notes/2026-07-14_plc-commissioning-runbook.md` and
  `notes/2026-08-11_plc-commissioning-readiness-map.md`. The MIP tag map is the other
  half of what `AssemblyPlc._WATCH` needs.
- **Legacy camera/tray validation analysis** — memory
  `project_mpp_legacy_camera_tray_validation`, relevant to Q4.

---

## Revision History

| Date | Rev | Change |
|---|---|---|
| 2026-08-18 | 1.0 | Initial — full context assembled from the touchpoint agreement, the legacy MES identifier formats, and the as-built serial model; 7 questions posed. |
