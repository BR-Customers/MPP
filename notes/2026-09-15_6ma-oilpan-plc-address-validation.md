# 6MA CH re-check + 6MA Oil Pan: PLC address validation without documentation

**2026-09-15.**

## What happened

Hunter supplied two fresh RSS uploads pulled directly from the controllers (not offline
project files): `6MA_CH.RSS` (Downloads) and `6MA_OP.RSS` (Desktop), plus a live gateway
tag export (`MPP.json`, Desktop) for `PlcDevices`. Goal: confirm the vision-completion tags
on `6MA_CH` are still right, then do the same validation for the 6MA oil pan station, which
has not been touched before.

Both RSS files, decoded with `reference/scripts/decode_rslogix500_rss.py`, carry **no
custom documentation** — their `MEM DATABASE` stream decompresses to the same 8,870-byte
block in both files, which is RSLogix 500's stock default comment set (e.g. "Fault
Override at Powerup" on `S2`), not engineer-authored symbol/rung comments. Confirmed by
diffing the decompressed bytes directly; not a decoder bug. Comments live in whatever
offline project file was used to originally write/maintain the ladder, not necessarily on
the processor — an upload only recovers what the processor itself was storing, and older
SLC-500/MicroLogix processors often have no room reserved for documentation. **No offline
documented copy of the oil pan program exists** (confirmed with Hunter).

## 6MA_CH: re-verified, unchanged

The fresh upload's ladder is byte-identical to the already-documented, already-validated
copy (`reference/6MA_PLC Logic` / `reference/6MA_PLC_Logic_decoded.txt`, from
[2026-09-11_6ma-ch-real-ladder-slcpasspulse.md](2026-09-11_6ma-ch-real-ladder-slcpasspulse.md)) —
diffed instruction-only streams, 71/71 lines matched. Nothing has changed on this PLC.
`InspectionComplete` (`N7:10`), `TrayLocked` (`I:0.0/0`), `VisionPartNumber` (`N16:2`) in the
current `MPP.json` export are all still correctly addressed.

Two things noticed in passing, neither blocking, both worth someone's attention:

- **`VisionPartNumber`'s binding on `6MA_CH` is a hardcoded literal** —
  `ns=1;s=[6MA CH Camera]N16:2` — instead of parameterized via `{Device}` the way
  `TrayLocked`/`InspectionComplete` are. Correct today only because `Device` happens to
  equal `"6MA CH Camera"`; a latent trap if that parameter is ever repointed.
- **`7MA_CH` is an unexplained duplicate.** The live gateway export carries a `7MA_CH`
  `TrayInspectionStation` instance with the identical `Device` ("6MA CH Camera"), identical
  `{Device}`-bound `InspectionComplete`/`TrayLocked`, and the same hardcoded
  `VisionPartNumber` path as `6MA_CH` — pointed at the exact same physical PLC. It is not in
  the repo's tracked `ignition/tags/instances/PlcDevices.json` and isn't referenced anywhere
  else in the project (no location seed, no other note). Needs a human call: deliberate
  test/duplicate instance, or stray leftover to delete.
- Separately, the **repo's tracked tag file is stale**: `ignition/tags/instances/PlcDevices.json`
  still shows `6MA_CH` on `Device: MPP_Sim` with no per-member overrides, i.e. it predates
  the 2026-09-11 fix and hasn't been re-synced from Designer since.

## 6MA Oil Pan (`6C2_6MA_OilPanAssy`, camera device `6MA Oil Pan Camera`, PLC `MPP_CA` @ 172.17.20.61)

No prior work exists on this PLC anywhere in the repo. Decoded ladder: 29 rungs across three
routines.

**MAIN (000–017)** — a small conveyor/index sequencer gated almost entirely by tray-present
input `I:0.0/1` (same role `I:0.0/0` plays on `6MA_CH`). A 1.5 s dwell (`T4:0`) then a 0.25 s
pulse sequence (`T4:1`) drive a couple of discrete outputs, gated by `I:0.0/0`, `I:0.0/2`,
`I:0.0/4`. `B3:0/11` latches off `I:0.0/4` (rungs 014/015) and only clears — along with
everything else — when `I:0.0/1` drops (rung 017). `B3:0/11` also gates an `ARL`/`ACL`
serial read/reset (rungs 000/001), same instruction shape as `6MA_CH`'s legacy "offline
computer" report — reads as a "cycle done" latch.

**VISION-analog (020–023)** mirrors `6MA_CH`'s VISION routine almost exactly: compares
`N16:2` (program loaded in the vision controller) against `N7:2` (recipe), pushes a
program-change via `MSG` on mismatch. Same instruction shapes, same addresses as the
validated CH program.

**Tail routine (025–029):**

```
025: XIC B3:0/11 -> TON T4:4 base 0.01 pre 10      (0.1s after "cycle done" latches)
026: XIC T4:4/DN -> MOV N7:2 -> N7:3
027: XIO I:0.0/1 -> MOV 0 -> N7:3                   (cleared when tray leaves)
028: XIC T4:4/DN -> MOV 1 -> N7:10
029: XIO I:0.0/1 -> MOV 0 -> N7:10                   (cleared when tray leaves)
```

### The address candidates (structural read, not comment-confirmed)

| UDT member | Candidate address | Basis |
|---|---|---|
| `TrayLocked` | `I:0.0/1` | Gates nearly every rung, same role as `6MA_CH`'s `I:0.0/0` |
| `PartNumber` | `N7:2` | Compared against `N16:2` in the VISION-analog routine, identical mechanism to CH's recipe word |
| `VisionPartNumber` | `N16:2` | Same address/role as CH |
| `InspectionComplete` | `N7:10` | Same numeric address as CH — **but different behavior, see below** |
| *(unmapped)* | `N7:3` | Mirrors `N7:2` on the same 0.1s delay as `N7:10`, cleared on tray-leave. No UDT member for it; meaning unconfirmed. |

### The critical difference from `6MA_CH`

`N7:10` here is **not** a pass-only, self-clearing pulse. It goes high a fixed 0.1 s after
`B3:0/11` latches and stays high until the tray physically leaves (`I:0.0/1` low) — a level
tied to tray dwell, not a verdict. **No discrete pass/fail input analogous to `6MA_CH`'s
`I:0.0/5` (PASS) / `I:0.0/6` (FAIL) appears anywhere in this ladder.** The state machine
that sets `B3:0/11` (rungs 014/015, driven by `I:0.0/4`) shows no dependency on any bit that
looks like a camera verdict.

### Independent corroboration: legacy EMMD/TOPServer extract

`reference/legacy_mes_extract/emmd_automation/` documents this exact device —
`6C2_6MA_OilPanAssy.MicroLogix1400` — plus its two siblings `5J6_OilPanAssy` and
`5K8_64A_OilPanAssy.MicroLogix1400`, all field-proven integrations predating this project.
All three carry **exactly four tags**, matching the structural read:

| Tag | Access type | Legacy usage |
|---|---|---|
| `TrayLocked` | T (trigger only) | On this edge: "Set Part Type" — **writes** `PartNumber` |
| `InspectionComplete` | T (trigger only) | On this edge: "Get Vision Part Number" — **reads** `VisionPartNumber`, then a generic "Process Tote" step |
| `PartNumber` | W (host writes) | The recipe |
| `VisionPartNumber` | R (host reads) | Program the vision controller actually ran |

(`device_rollup.tsv`, `tag_catalog.tsv`, `station_chain.tsv`.)

This is a second, independent source agreeing with the ladder read on all four addresses'
roles. It also confirms the negative finding: **legacy never reads a disposition tag for
this station family** — no `PartDisposition`, no `OkToContinue` (contrast: `6B2_CH` /
`6MA_CH` carry `PartDisposition01..18`). "Process Tote," the step legacy runs after
`InspectionComplete`, is documented in `mpp_frs_md/appendix_g_fwi_event_manager.md` only as
an opaque named script step (numbered 0300–0399) — no visible accept/reject logic exposed
in the FRS extract either.

## Where this leaves confidence

Two independent sources (raw ladder structure, field-proven legacy tag map) agree on
address roles and on the absence of a PLC-side pass/fail signal for this station family.
Address mapping is solid. What's still open:

- **How a physically-rejected oil pan is kept out of MES booking** is not confirmed — most
  likely it's diverted before `InspectionComplete` would reflect it at all, meaning a
  `VisionPartNumber`-vs-recipe match is the *only* trust check available, same as legacy
  relied on for years. This is an inference from the absence of evidence, not something
  watched happen.
- **`N7:3` is unexplained.** Mirrors the recipe on the same timing as `InspectionComplete`;
  no legacy tag or UDT member corresponds to it.

## If wiring `6MA_OilPan` up now

Current `MPP.json` shows `Protocol` already hardcoded to `"SlcPassPulse"` on this instance,
but none of `InspectionComplete` / `TrayLocked` / `PartNumber` / `ContainerName` /
`VisionPartNumber` carry per-member address overrides yet — same pre-fix state `6MA_CH` was
in before 2026-09-11.

**Do not treat `InspectionComplete` rising as "vision said pass."** There is no PLC-side
disposition for this station family — every completed cycle looks the same to the host.
Booking safety has to rely entirely on `VisionPartNumber == recipe`, exactly as legacy did.
That may well be fine (15 years of production history says so), but it means the *protocol
semantics* differ from `6MA_CH` even though `InspectionComplete` happens to land on the same
numeric address (`N7:10`) in both programs — don't assume `SlcPassPulse` behaves identically
across the two stations without accounting for this.

Recommended before cutover: live-watch `I:0.0/1`, `I:0.0/4`, `N7:10`, `N16:2`, and `N7:3` on
the real device (`6MA Oil Pan Camera`, 172.17.20.61) while running a known-good and a
known-reject oil pan through, to close the remaining gap on reject handling. If an offline
documented `.RSS` for this station family ever turns up, re-decode and confirm the comments
agree with this note.

## Addendum (same day): how the disposition/booking logic actually works

Traced the reject-handling question further. Two more sources, and a real conflict between
documented design and what's live on the gateway.

**Legacy: the verdict was never a PLC bit at all.** `mpp_frs_md/appendix_k_mes_em_routines.md`
(the FRS's SparkMES interface listing) shows
`ProcessTrayInspectionComplete(..., int disposition)` — the verdict is a parameter the legacy
VBScript *computes and passes in*, not something it reads off the wire. The script body that
computes it (`#N` grid) was never re-transcribed into this repo, and the design spec that
analyzed this extract flags it as a still-open question:
`docs/superpowers/specs/2026-07-10-plc-udt-terminal-mapping-design.md` §5.2 item 3 — *"Sort
recipes. `GetInProcessContainerSortRecipe` returns an integer written as `PartNumber` to the
sort PLC. Where is the mapping data today? ... Confirm it survives."* No later note or the
Open Issues Register resolves it. There's also a physically separate downstream PLC,
`Sort_OilPan.MicroLogix1400` (own line, "Sort Line - Oil Pan," task 16 vs. the inspection
station's task 15) — a distinct sortation cell that receives a written integer "sort recipe,"
not something on `6C2_6MA_OilPanAssy` at all. Not decoded (no RSS obtained for it); flagged
here since it's easy to conflate the two PLCs.

**The new system already has a documented answer for this — and it's not what the gateway is running.**
`ignition/projects/Core/ignition/script-python/BlueRidge/Workorder/TrayInspectionWatcher/code.py`
documents three handshake protocols. Its own docstring says plainly: *"SkuVerify (vision
SKU-ID cells: the `*_OilPan` devices)"* — i.e. `SkuVerify`, not `SlcPassPulse`, is the intended
protocol for this station family. `SkuVerify`'s logic needs no PLC-side pass/fail signal at
all: on `TrayLocked`, write the recipe and self-ack the trigger; on `InspectionComplete`, read
`VisionPartNumber` and compare to the expected recipe — match releases `OkToContinue` and
books the tray, **mismatch is a hard LINE STOP** (tray held, alarm, nothing released) rather
than SlcPassPulse's quieter "warn and skip." This is exactly the mechanism the legacy tag
catalog implies (no disposition tag exists for this device family, so program-match is the
only signal there ever was) — good independent alignment.

But the live gateway export (`MPP.json`) has `6MA_OilPan`'s `Protocol` hardcoded to the
**value `"SlcPassPulse"`**, not `SkuVerify` and not blank (which also defaults to `SkuVerify`
per `_protocol()`'s fallback). Someone set this explicitly, most likely by analogy to the
`6MA_CH` fix — but `6MA_CH` is a different physical mechanism (`N7:10` there is a genuine
pass-only pulse) from what this ladder shows for the oil pan.

**Neither documented protocol is actually a clean fit for this specific ladder, and that matters:**

- `SkuVerify` writes `OkToContinue = True` to release the tray and assumes a mismatch can
  *hold* it by not writing that. But nothing in this ladder reads an `OkToContinue`-equivalent
  word (no `N7:1`, no `EQU?`/gate on any MES-writable bit anywhere in the decoded MAIN routine)
  — the sequencer free-runs off raw photo-eyes (`I:0.0/0`, `I:0.0/1`, `I:0.0/2`, `I:0.0/4`)
  regardless of what the host writes. So `SkuVerify`'s "line stop" would not physically stop
  anything on this hardware — the tray keeps moving no matter what the MES does.
- `SlcPassPulse` (what's actually configured) doesn't try to write a hold at all — consistent
  with the hardware — but its core assumption, "`InspectionComplete` only pulses on a pass,"
  does **not** hold here: rung 028/029 show `N7:10` set unconditionally once `B3:0/11` latches,
  with no visible dependency on any pass/fail bit. If wired with the same address mapping as
  `6MA_CH` (`InspectionComplete → N7:10`), `_pulseOnTrayPassed` would book **every** completed
  cycle whose `VisionPartNumber` matches the recipe — good or bad — because this PLC gives the
  host no way to distinguish them.

**Working theory on where the real divert happens (unconfirmed):** rung 013 sets `B3:0/5` off
`I:0.0/5` — the same input address CH uses for its vision PASS discrete — and rung 007 drives
output `O:0.0/5` off `B3:0/5`. Neither feeds `B3:0/11` or `N7:10`. That's consistent with a
purely physical reject path: the vision controller's pass/fail output gates a divert solenoid
directly, with zero visibility to the host either way, and it's why legacy never had a
disposition tag for this station family — the MES was never meant to know. If that's right,
trusting `InspectionComplete` + a `VisionPartNumber` match (either protocol, really) is exactly
as safe as legacy's 15 years of production — but it's still an inference, not confirmed.

## Addendum 3 (same day): documented copies obtained — the open question is resolved

Hunter obtained three properly-documented `.RSS` files (`6MA_OP.RSS`, `64A_OILP.RSS`,
`V6OILPAN.RSS` — evidently from an engineer's `Desktop\For_Tom` folder, originally saved
offline rather than uploaded from a live controller). All three decompress their `MEM
DATABASE` stream to 12-15KB of real symbol/comment text (vs. the 8.7KB RSLogix stock
default the earlier controller-uploaded copies carried) — confirmed genuine, not another
stripped copy.

**This resolves the open question from the addenda above.** Confirmed symbol names:

| Address | Symbol |
|---|---|
| `B3:0/11` | RELEASE CART AND PRINT LABEL |
| `B3:0/5` | BAD SIGNAL MEMORY |
| `B3:0/0` | CART PRESENT WAIT FOR INSPECTION |
| `B3:0/2` | TRIGGER VISION SYSTEM |
| `B3:0/3` | WAIT FOR VISION SIGNAL |
| `N7:0` | CART PRESENT TO FLEXWARE / CART READY TO FLEXWARE |
| `N7:2` | vision program / recipe code from Flexware (6MA_OP: "1"=6C2, "2"=6L2, "3"=6MA — a shared 3-way selector) |
| `N7:10` | CART GOOD TO FLEXWARE / CART DONE AND GOOD TO FLEXWARE |
| `N16:0` | COMMAND NUMBER TO VISION SYSTEM |
| `N16:2` | PROGRAM NUMBER TO VISION CONTROLLER |

In `64A_OILP.RSS` and `V6OILPAN.RSS`, the rung that actually latches `B3:0/11` is an explicit
AND-NOT gate on the vision controller's good/bad discrete pair (`I:0.1/2`/`I:0.1/3` in those
two programs): `XIC B3:0/3 | XIC [good] | XIO [bad] -> OTL B3:0/11`. This is the same shape
as `6MA_CH`'s verdict rung and **confirms `N7:10` really is good-only** — the tag wiring
committed earlier this session (`InspectionComplete → N7:10`, `Protocol = SlcPassPulse`,
booking only on a rising edge with no `OkToContinue` write) is correct, not just a reasonable
guess. The lights match what was observed live: `O:0.0/3` (off `B3:0/11`) = green, `O:0.0/5`
(off `B3:0/5`, "bad signal memory") = red, `O:0.0/6` (off `B3:0/0`, no exclusion) = the
always-on yellow.

**One confirmed discrepancy:** `6MA_OP.RSS`'s equivalent rung —
`XIC B3:0/3 | XIC I:0.0/4 -> OTL B3:0/11` — is missing the `XIO [bad line]` exclusion its
two siblings both carry. Same symbol names, same shared program lineage (`N7:2`'s three-way
comment ties `6MA_OP` to a cart shared across 6C2/6L2/6MA), but this one PLC only checks
"good asserted," not "good asserted and bad not asserted." Very likely harmless if the
vision controller's good/bad discretes are hardware-mutually-exclusive (typical for this
kind of camera), but it's a real, confirmed inconsistency versus its sister stations and
worth flagging to whoever maintains these programs — it would only matter if the controller
ever produced a simultaneous or ambiguous signal.

**Bottom line:** this isn't a "just port the `6MA_CH` fix" job. Before wiring `6MA_OilPan`'s
addresses, someone needs to decide, deliberately: (a) confirm the physical-divert theory above
(live check), and (b) either fix `SkuVerify` to not assume a working `OkToContinue` gate on
this hardware, or fix `SlcPassPulse`'s comment/assumption that `InspectionComplete` is
pass-only for this device — whichever protocol is used, the code's mental model currently
doesn't match this ladder on at least one point.

## Addendum 2 (same day): customer confirms this is a presence check, not a quality inspection

Hunter talked to the customer directly: **the camera's job here is just to see whether an oil
pan is there** — not a quality/defect verdict. This fits the ladder far better than the
"physical reject divert" theory above and should supersede it:

- No `PartDisposition` array, no good-side/bad-side split anywhere in this program (contrast
  `6MA_CH`'s explicit `B3:2/0`/`B3:2/1`) — because there is no verdict to branch on, only
  present/absent.
- Re-read with that lens: `I:0.0/5` → latches `B3:0/5` (rung 013) → drives `O:0.0/5` (rung 007)
  is almost certainly the **presence result** itself (1 = pan seen, 0 = empty), not a
  pass/fail-quality discrete. Supersedes the earlier "candidate PASS input" guess.
- `I:0.0/0` → `B3:0/2` → the 0.25s pulse on `O:0.0/2` (rung 010) is very likely the **camera
  trigger** output (same role as `6MA_CH`'s `O:0.0/7`).
- `I:0.0/4` → latches `B3:0/11` (rungs 014/015) is the vision system's "done" signal, arriving
  as a direct discrete rather than a fixed settle timer.

**Still unresolved, and now the one thing that actually matters:** `B3:0/5` (presence) never
gates `B3:0/11`/`N7:10` anywhere in the decoded ladder — `InspectionComplete` fires off `I:0.0/4`
alone, with no visible dependency on whether a pan was actually detected. If that reading is
right, **an empty tote completes the cycle identically to a full one**, and whatever is
supposed to catch that isn't visible in this PLC's addresses — `O:0.0/5` looks like it drives
something local (indicator or an interlock elsewhere) rather than gating the sequence that
leads to `N7:10`. Next step: ask the customer directly what happens today when the camera
finds an empty tote (stop, alarm, nothing, downstream catch?) — that answer confirms or kills
this read and is the one open question left that has real consequences (mis-booking an empty
tote as a completed part), as opposed to the earlier, now largely moot, "could a
defective-but-present part get miscounted as good" concern — there's no such thing as
defective from this camera's point of view, only present or absent.
