# PLC Readiness Addendum — 59BCH and 6FB — 2026-10-01

Extends `notes/2026-08-11_plc-commissioning-readiness-map.md`. That map was built from
PDF exports of three ladder programs (`MPPMACH`, `MPP_COG`, `SORTCAGE`). MPP supplied
five `.RSS` sources on 2026-09-29, now committed at `reference/PLC scripts/` with decoded
listings beside them. Three of the five are the ones the map already covers. **Two —
`59BCH` and `6FB` — had never been looked at.** This addendum covers those two, using the
map's own rubric, and corrects three statements in the map that the `.RSS` sources show
to be stale.

Scoring legend is the map's: 🟢 built + sim-validated · 🟡 built but blocked (seed/config)
· 🟠 stub / partial · 🔴 unbuilt · ⚪ commissioning/hardware witness only

---

## 1. What the two cells are

| | `59BCH` (172.17.21.239) | `6FB` (172.17.21.231) |
|---|---|---|
| **What it is** | 59B cam-holder cell: two-position tray inspection driving an Ethernet vision controller, plus a bench scale on serial channel 2 | 6FB inspection + **two-way diverter** — one station that sorts **cam holder right / oil pan left** |
| **Vision** | Ethernet vision controller at **172.17.21.241** via `MSG MG11:5`, full `N16`/`N17`/`N20` command block (the same block `MPP_COG` and `SORTCAGE` use) | **None over Ethernet.** No `N16`, `N17` or `N20` word exists anywhere. Verdicts arrive as discrete inputs `I:0.0/1..5` |
| **Serial out** | one port: `ARL 2 ST10:0 R6:1` — `WRITE TO SCALE` after `C5:0` reaches 48 | **two** ports: `ARL 2 … R6:1` after 26 cam trays, `ARL 0 … R6:2` after 13 oil trays, both commented `SEND MESSAGE TO OFFLINE COMPUTER` |
| **Counters** | `L9:0`/`L9:1` used for a compare, not production counts | `L9:5`/`L9:6` good/bad **cam**, `L9:0`/`L9:1` good/bad **oil**, `L9:2` total good, `L9:10` life |
| **N7 words used** | `N7:10` only | `N7:0`, `N7:2`, `N7:30` |
| **Host handshake** | **none** (§2) | **report-only, one way** (§3) |
| **Consecutive-fail counter** | none | none |
| **Escalation / supervisor gate** | none | none |
| **Failure-type branching** | none | none (`PART FAILED OR UNIDENTIFIED` is one bit) |
| **Barcode / dual-source** | none | none |
| **Label / print / void / AIM** | none | none in ladder; the serial batch message to the "offline computer" is the only outbound event |
| **Ladder files** | `LAD 2` (39 rungs), `LAD 3` (15) — both **unnamed**; `LAD 3` is the vision sequencer | `LAD 2 MAIN` (32), `LAD 3 HOST` (11) |
| **Symbol coverage** | **thin** — `MEM DATABASE` is 2.6 KB against 5.1 KB for `MPPMACH`. Most `N7`/`L9`/`B3` words carry no comment | good — 3.8 KB, nearly every bit named |

`6FB` matches the change-request form already in the repo,
`reference/6FB Oil Pass_ CH Flexware _MPP_Change_Request_Form.xlsx` — "6FB Oil Pass / CH"
is one station handling both parts, which is what the ladder does.

---

## 2. `59BCH` has no MES host seam at all

Not "a thin one" — none. Evidence, all from the decoded listing:

- **Zero occurrences of `FLEXWARE`** in the symbol database. Every other cell we hold names
  its host words (`TRAY READY TO FLEXWARE`, `OK TO TRIGGER FROM FLEXWARE`, `DONE TO HOST`).
- **One `N7` word in the whole program: `N7:10`**, and the ladder *writes* it — rung 037,
  `XIC B3:4/0 → MOV 2 → N7:10`, three HMI part-selection bits picking a value of 1, 2 or 3.
  There is no `N7:0` lock flag, no `N7:1` trigger gate, no `N7:30` done flag.
- **No `MSG` to a host.** The only `MSG` is `MG11:5`, reading results *from* the vision
  controller. Outbound traffic is that plus the scale write.

I derived the externally-written surface mechanically — every address the ladder reads but
never writes must be written from outside it — and after discarding `ONS` one-shot storage
bits, what remains on `59BCH` is **entirely HMI**: start, stop, reset, and the three
part-selection bits. Nothing else writes into this PLC.

> **Caveat on that method.** A ladder cannot distinguish an HMI writer from a host writer —
> both are just "something wrote this word." The conclusion here rests on the comments
> saying `HMI` and on the total absence of host-named words, not on the method alone.

**One anomaly I cannot explain and would like to ask about.** Rungs 033–035:

```
033: MOV 4702 -> L9:0
034: EQU? L9:0 , L9:1  |  OTE B3:2/0
035: XIC B3:2/0  |  NEQ? N7:10 , 2  |  OTL B3:2/1  |  XIC B3:2/1  |  MOV 0 -> L9:1 ...
```

`L9:0` is loaded with the constant **4702** every scan and compared against `L9:1`. Nothing
in the ladder ever writes a non-zero `L9:1` — it only *clears* it, one second after a match.
So `L9:1` is written by something outside the ladder, and the ladder recognises the value
4702 and acks by clearing it. That is the shape of a host handshake. On `MPPMACH` the `L9`
block *is* the host block (`L9:5 = SERIAL NUMBER FROM HOST`). **Question Q1 below.**

---

## 3. `6FB` reports to the host and accepts nothing

All three of its `N7` words are written by the PLC and never read by it:

| Word | Symbol | Direction | When |
|---|---|---|---|
| `N7:0` | `TRAY LOCK` | PLC → host | set on a verdict |
| `N7:2` | `1=CAM 2=OIL` | PLC → host | +1.0 s later |
| `N7:30` | `INSPECTION COMPLETE TO FLEXWARE` | PLC → host | +2.0 s later |

Rungs 008 and 009 are the same staged sequence, once for each variant — `CAM PASSED GO TO
RIGHT` and `OIL PASSED GO TO LEFT` each drive `N7:0 = 1`, then the variant code into `N7:2`,
then `N7:30 = 1`. Rung 017 clears all three when both side-clear timers run.

There is **no `N7:1`** and no other host-readable gate. The externally-written surface,
computed the same way as §2, is HMI-only: start, stop, reset-all, reset-counts, manual mode,
raise/lower transfer, go-left, go-right. **The MES cannot trigger, gate or recipe-select this
cell.** It can only watch.

Note the direction inversion: on `MPPMACH`, `MPP_COG` and `SORTCAGE`, `N7:2` is
`TRAY RECIPE FROM FLEXWARE` — host → PLC. On `6FB` the same word is a PLC → host *verdict*.
Same address, opposite direction. The OPC catalog already reflects this (§4).

---

## 4. Device mapping — what exists and what doesn't

**`6FB_CH` exists but is catalogued with exactly two items**
(`reference/seed_data/opc_tags.csv`):

```
TOP,TOPServer.V5,Write,6FB_CH.Micrologix1400,OkToContinue
TOP,TOPServer.V5,Read, 6FB_CH.MicroLogix1400,PartNumber
```

- `PartNumber` is **Read**, which agrees with the ladder — `N7:2` is an output. Good.
- `OkToContinue` is catalogued **Write**, but **nothing in the `6FB` ladder consumes a host
  write**, and in the current build `OkToContinue` is a **`memory`** member of
  `TrayInspectionStation`, not an OPC one. So this item is bound to nothing at either end.
- `TrayLocked` and `InspectionComplete` are **not in the catalog for `6FB_CH`** — yet they
  are the two wired edges (`ignition/tags/plc_trigger_tag_paths.txt:38-39`). The ladder shows
  both words genuinely exist (`N7:0`, `N7:30`), so here the **ladder is the better authority
  than FRS Appendix C**, and the catalog is simply incomplete for this cell.
- The **oil-pan half of 6FB has no device entry at all.** One station, two parts, one device
  named `_CH`.

**`59B_CH` does not exist anywhere.** No OPC item, no tag instance, no seed row, no mention
in any doc — I grepped for it. The 59B line carries only the scale `59B_1_FP_1`
(OmniServer, family A, 12 items). Given §2 that is *consistent* rather than a gap: a cell
with no host handshake has nothing to map. It becomes a gap only if MPP expects the MES to
cover 59B cam holder. **Question Q2.**

---

## 5. The sharpest finding: no existing protocol fits 6FB

`TrayInspectionWatcher` dispatches three protocols — `SkuVerify`, `SlcTray`,
`SlcPassPulse` — on the `TrayLocked` / `InspectionComplete` edge pair, which `6FB` does
provide. Two of the three obstacles are already solved by existing switches:

- **No vision register.** `VisionMatchOptional = True` is exactly this case, and its
  docstring says to confirm by decoding the real ladder rather than trusting an unmapped
  tag. Decoded: `6FB` has no `N16`/`N17` word anywhere. Confirmed.
- **Writeback would corrupt the verdict.** `SlcPassPulse` *writes* `N7:2` on `TrayLocked` to
  sync the vision program. On `6FB` that word is the PLC's own output, so
  `DisableWriteback = True` is **mandatory here, not a preference**.

The third obstacle is not solved by a switch. `_pulseOnTrayPassed` resolves the part from
the **terminal's** context (`_expectedRecipe(terminalLocationId) → finishedGoodItemId`) and
books that. `6FB`'s PLC decides the part **per tray** and announces it in `N7:2`. If the
station runs both variants in the same shift, booking from terminal context credits every
tray to one finished good and **roughly half of 6FB's output lands on the wrong part.**

I do not want to call that a defect before asking, because it turns entirely on how the cell
is actually run. **Question Q3.** If it runs one variant at a time with a changeover, the
terminal-context approach is already correct and `N7:2` is a useful cross-check rather than
the authority. If it runs both at once, `6FB` needs a fourth protocol that dispatches on the
PLC's part word.

---

## 6. Corrections to the 2026-08-11 map

1. **§3.1's `TrayInspectionStation` description is stale.** The UDT no longer declares
   `PartDisposition01..18` or `ContainerName`-as-family-D superset; its members are now
   `TrayLocked, InspectionComplete, PartNumber, VisionPartNumber, ContainerName` (OPC) and
   `OkToContinue, Protocol, DisableWriteback, WriteDisplayEnabled, VisionMatchOptional`
   (memory). `PartDisposition` appears **zero times** in the UDT file, though
   `TrayInspectionWatcher` still defines `_DISPOSITIONS`. Gap **P3** ("18 slots defined but
   never read") no longer describes the build — the slots are not defined either.
2. **§2's family-D row over-claims for `6FB_CH`.** It lists family D as
   `PartDisposition01..NN` (R) with `PartNumber` (W). `6FB_CH` has no disposition items and
   its `PartNumber` is Read. `6FB` is closer to family C minus the vision register.
3. **§3.2's `6FB_CH` blocker is the driver-name typo.** That is real and still stands, but it
   is not the binding constraint — §5 is.

---

## 7. Readiness

| Line / station | Family | MES watcher | Readiness | Blocker |
|---|---|---|---|---|
| `6FB_CH` (cam holder) | C-minus-vision | `TrayInspectionWatcher` | 🟠 | `Protocol` undecided (§5); needs `DisableWriteback=1` + `VisionMatchOptional=1`; `TerminalPlcDevice` seed row; driver-name typo |
| 6FB oil pan | — | — | 🔴 | **no device entry exists** |
| 59B cam holder (`59BCH`) | — | — | ⚪ | **no host handshake in the PLC and no device anywhere** — out of scope unless MPP says otherwise (Q2) |

Neither cell changes the map's §4 conclusion. `59BCH` and `6FB` both provide a raw per-cycle
verdict and nothing else: no consecutive-fail counter, no failure-type branching, no barcode.
FDS-10-009 / -010 / -013 remain wholly MES-side. `6FB` is in fact *weaker* than `MPPMACH`,
which at least has the tray-level `C5:1` 3-in-a-row counter.

---

## 8. Questions for MPP

- **Q1 — `59BCH`, the constant 4702.** `L9:1` is written by something outside the ladder and
  acked when it equals 4702. What writes it, and what is 4702 — a part number, a placard or
  job number, a tray code? If a host writes it, `59BCH` has a handshake after all and §2
  needs revisiting.
- **Q2 — is 59B cam holder in scope?** There is no device, no tag and no handshake. Should
  the MES cover this cell, and if so, is MPP willing to have the ladder changed to expose a
  lock/done pair? Today there is nothing to integrate against.
- **Q3 — does 6FB run cam holder and oil pan at the same time, or one at a time?** This
  decides whether an existing protocol works or a new one is needed (§5).
- **Q4 — are 26 / 13 container quantities?** `6FB`'s HOST ladder sends its serial batch
  message every **26 cam** trays and every **13 oil** trays; `MPPMACH` uses 24 and `59BCH`
  uses 48. If those are pack-out quantities, they are a free cross-check on the container
  config — there are no container-quantity seeds in `sql/` to compare against.
- **Q5 — what is the "offline computer"?** `6FB` and `59BCH` both push ASCII out a serial
  port on a batch count. Is that the legacy label printer, a data-collection PC, or dead?
  It is the only outbound event either cell generates, so it probably marks whatever the
  legacy system treated as a completed container.

---

## 9. Caveats on the decoded listings

- `EQU?` / `NEQ?` / `LIM?` are **inferred from operand shape**, not confirmed. Anything
  printing as `0xNN` is an unidentified opcode.
- A rung with no instructions prints nothing, so a gap in the rung numbering is an empty
  rung (usually `END`), not a decode failure.
- `59BCH`'s two ladder files are **unnamed** in the project; `LAD 2` / `LAD 3` are file
  numbers, which is how RSLogix itself addresses them. The segmentation was broken until
  `ff23ce75`; anything read out of an earlier copy of that listing is suspect.
- `59BCH` writes `N20:1`/`N20:4` command bits but carries no `MSG MG11:10` to send them,
  unlike `MPP_COG` and `SORTCAGE`. Either the send lives somewhere the decode does not
  reach, or those writes are dead. Not resolved.
