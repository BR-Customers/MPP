# IND570 scale integration — 2026-08-31 working notes

**Outcome:** the Modbus TCP transport is dead (no PLC option card fitted). Replaced with
**EPrint demand output** over the terminal's existing Ethernet option. Transport is
**proven working** end to end into Ignition. Stopped before validating demand output;
resumes when Tom is back on the floor.

Spec: `docs/superpowers/specs/2026-08-31-ind570-eprint-demand-output-design.md`

---

## 1. How the Modbus path died

Three independent lines of evidence, in the order they landed:

1. **Port scan from the Ignition gateway** (`172.17.10.161` → `172.17.20.127`, two runs,
   identical): 21, 80, 1701 open in under 100 ms; **502 and 44818 silent for the full
   2500 ms timeout**. Zero `REFUSED` anywhere — every failure was a silent drop.
2. **The option board Tom photographed** carries `Bluetooth` / `WLAN` silkscreen and an
   `RF` status LED, and has no MAC-ID DIP switches. It is not the Figure 4-1 fieldbus
   module.
3. **Decisive:** the terminal's `Communication` branch contains
   `Access/Security · Templates · Reports · Connections · Serial · Network · Reset`.
   **There is no `PLC` node.** PLC Interface Manual §4.8: the branch is *enabled on
   detection* of the option board. It isn't there, so no card is fitted.

**The "Tom configured EtherNet/IP" report was a naming conflation.** He set the terminal's
**Ethernet IP address** at `Communication > Network > Ethernet`. That is unrelated to
**EtherNet/IP**, the ODVA protocol. Two nearly identical names, completely different things.

MPP's call: use `Communication > Connections` over Ethernet rather than buy and fit cards.

## 2. What the User Guide settled

Acquired mid-session (`reference/IND570_User_Guide.pdf` + `.txt`, MT 30205308 r07). We had
only the PLC Interface Manual before, which documents fieldbus and nothing else.

- **Port 1701 is the Shared Data Server, fixed.** That is the open port the scan found; it
  accepted and immediately closed because we never sent a login. Explains an anomaly that
  had been open for hours.
- **EPrint is effectively mandatory.** *"EPrint offers a method to access the demand or
  continuous output data directly through the Ethernet port. Shared Data Server login and
  commands are not required."* The `Ethernet 1-3` ports deliver data *through* Shared Data
  registration — a login handshake Ignition's TCP driver cannot perform.
- **EPrint lives only on the secondary port**, and there is one. So one stream: the
  weighment record, not a live-weight mirror.
- **Primary and secondary run concurrently** — EPrint does not displace whatever holds 1701.
- **Demand Output has a Trigger field**: `Scale` (PRINT key) or `Trigger 1/2/3`, which bind
  *"a separate softkey, discrete input or a PLC command."*
- **Templates are ours to author**, 10 slots, 1000 bytes each. Templates 1, 2 and 5 ship with
  default content. Template 1 = three lines: gross, tare (`T`), net (`N`).
- **FTP is read-only** (§1.9) — templates cannot be pushed remotely. Front panel or InSite SL.

## 3. The operator buttons

**Wired to discrete inputs 1 and 2** — confirmed by Tom. This answers the highest-risk open
question in the superseded Modbus spec (§8.3 Q0), which had been unresolved since rev 2.

`Setup > Application > Discrete I/O > Inputs` (note: **Application**, not Communication).
Address `0.1.1` = input 1, Assignment `Trigger 1`, Polarity `+True`.

**`Trigger 1` in the Connections row does nothing on its own** — the discrete input must be
mapped to it separately, in the Discrete I/O table.

`Setup > Maintenance > Run > Diagnostics > Discrete I/O Test` shows live input state and
**confirmed the board is fitted and the button is seen by the terminal**.

## 4. Transport proven — and the two traps that cost the afternoon

Bisected the problem into *trigger* and *transport* after two wrong guesses (Print Interlock,
then polarity). Test A (does the terminal see the button) **passed**. Test B (does a PRINT
key press reach Ignition) **failed** — which proved the trigger was never the issue and sent
us at the transport.

Two separate faults, both in the delimiter:

**Trap 1 — CR, not CRLF.** Table C-6: the MT Standard Continuous frame is
`STX | SWA SWB SWC | 6 weight digits | 6 tare digits | CR | [CHK]`, 17 or 18 bytes,
terminated by **`<CR>` (0x0D) only — no LF**. The spec had said `\r\n`, carried across from
the IND400/SICS work where CRLF *is* correct. Wrong frame format, wrong lesson transferred.
Ignition sat connected forever waiting for a line feed that never comes.

**Trap 2 — `/r` vs `\r`.** The delimiter was typed with a **forward slash**. Two literal
characters that never appear in the stream. Cost roughly an hour on its own.

**After fixing both, data landed:**

```
MessageBytes = [2, 44, 33, 32, 32, 32, 32, 48, 48, 48, 32, 32, 32, 49, 55, 51, 51]
                STX  ,   !  <-- SWA SWB SWC
                        weight "   000" = 0 (empty platform)
                        tare   "  1733" = 17.33 lb  (SWA low bits = decimal position)
```

**Note:** the `Message` *string* tag renders **empty** while `MessageBytes` carries the data —
the leading `STX` control character. Irrelevant for demand output (printable text), but if
anything ever parses continuous output, use `MessageBytes`.

## 5. Current state

| | |
|---|---|
| Terminal secondary port | `1702` |
| Connections | one row: Port `EPrint`, Assignment **`Continuous Output`** (test mode) |
| Discrete input | `0.1.1` → `Trigger 1`, `+True` |
| Ignition device | TCP driver, `172.17.20.127:1702`, CharacterBased, delimiter `\r`, Field Count 1, Inactivity Timeout 0, writeback off |
| Status | **streaming continuous frames into Ignition** |

## 6. Tomorrow, in order

1. **Switch the EPrint row to `Demand Output`**, Trigger `Trigger 1`, Template `Template 1`.
2. **Capture raw hex** with the Ignition device disabled, then press the operator button:
   ```
   $c=new-object net.sockets.tcpclient("172.17.20.127",1702);$s=$c.getstream();$b=new-object byte[] 256;$n=$s.read($b,0,256);($b[0..($n-1)]|%{"{0:X2}" -f $_}) -join " "
   ```
3. **Re-check the delimiter.** Template line endings are template-defined and may be CRLF,
   unlike the fixed continuous frame. Do not assume `\r` carries over.
4. Confirm three lines per press (gross / `T` / `N`); we act on the `N` line only.
5. Pin the parse grammar in spec §5.2 against the real bytes.
6. Clear the stored **17.33 lb tare** before any weight testing, or every reading is net of it.

## 7. Still open

- What is currently in `Connections` on the *production* scales — this head's list was empty,
  which does not explain how OmniServer gets data today.
- Is `172.17.20.127` a production scale or a test head? IT called it "the test scale."
- Are all seven terminals the same variant/firmware? Chassis label reads `IND570TE`.
- What is discrete input 2 for? Only input 1 has been touched.
- Whether `Print Interlock` or `Minimum Weight` will bite once demand output is live — neither
  was ever confirmed or ruled out, because the transport fault masked everything.

## 8. Artifacts produced today

- `docs/superpowers/specs/2026-08-31-ind570-eprint-demand-output-design.md` — the new design
- `reference/IND570_User_Guide.pdf` / `.txt` — acquired, extracted, now greppable
- `Test-IND570-Link.ps1` — port sweep, EtherNet/IP ListIdentity, Modbus read, byte-order decode
- `Test-IND570-EPrint.ps1` — EPrint frame listener, text + hex
- This note

**Everything above is uncommitted.**
