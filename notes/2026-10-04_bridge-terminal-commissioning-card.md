# Zebra Bridge terminal card -- onsite commissioning, 2026-10-05

Git mirror of the Artifact published for the 2026-10-05 onsite visit. Same content; the note is the
record, the Artifact is the instrument.

**Authority:** `zebraPrinter/MesZebraBridge/RELEASE.md` and spec section 7
(`docs/superpowers/specs/2026-09-29-zebra-bridge-service-and-print-traceability-design.md`).
**Wire contract:** `zebraPrinter/PROTOCOL.md` v1.0.0, FROZEN.

---

## Flash drive contents

Staged at `dist/bridge-flashdrive/`. **Two files are required**; the `.pdb` is optional and only worth
copying if a stack trace with line numbers is ever wanted.

| File | Bytes | Per machine? |
|---|---|---|
| `MesZebraBridge.exe` | 54,784 | identical everywhere |
| `MesZebraBridge.conf` | 1,161 | identical as shipped -- carries `GatewayAddress=172.17.10.161`, no queue; `install` writes the `Queue=` line |
| `MesZebraBridge.pdb` | 101,888 | optional |

**SHA-256 of the exe that ships** -- this is the value to give MPP IT:

    A4DCFDA1B0B3903990C42F349183B1C77DF2405400D1EB96E1C8D0F50F574430

> **Do NOT quote `6A208EDD...5B70`.** That hash was recorded on 2026-09-30 and matches no binary that
> now exists. `Deterministic=true` without `<PathMap>` makes repeated rebuilds identical *in one
> checkout* but not portable across build directories, so the same unchanged 1.0.0 source has produced
> three different hashes. The source itself has not changed since `c3827380` -- there is no `.cs` or
> `.csproj` commit after it -- so all three are the same reviewed code, just not the same bytes.
> **Rule: ship one exe, and hash that file.** Full argument in `RELEASE.md`.

The exe is **not signed** (spec open item 12.4). SmartScreen will warn; click through, or have IT
allowlist the hash above.

---

## Per-terminal procedure -- ONE visit

Steps 1, 3, 4 and 7 at the machine; 2, 5 and 6 from the Config Tool.

1. **Read the PC's address and queue name** (at the machine). Write the queue name down *exactly* --
   step 4 checks against it.

       ipconfig
       Get-Printer | Select-Object Name, PortName, PrinterStatus

2. **Set the Terminal IP** in the Config Tool (Plant Hierarchy -> that Terminal -> `IpAddress`) to match
   what `ipconfig` reported. **Must precede steps 4-6** -- the printer endpoint derives from it. As of
   2026-09-30 only 17 of 77 terminals carried an address and 38 already had a printer and none; that is
   the rollout worklist, not a defect list.

3. **Install the Zebra driver** if not already present.

4. **Copy BOTH files** to `C:\BlueRidge\`, then from an **elevated** prompt:

       cd C:\BlueRidge
       MesZebraBridge.exe install

   Registers the service as `LocalSystem` start=auto with recovery 5s/5s/60s, adds the inbound TCP 9100
   rule scoped to the Gateway, starts, and prints `BOUND QUEUE: <name>`. **Check that against step 1.**

   Several candidates or none -> it installs nothing and asks; pick from its listing:

       MesZebraBridge.exe install --queue "Zebra GX420d (RAW)"

   `no GatewayAddress` -> the `.conf` was not copied beside the exe.

5. **Add the Printer row** under that Terminal: `ConnectionKind = UsbBridge`. **Leave Endpoint blank** --
   it derives from the Terminal IP as `<ip>:9100`.

6. **Probe, then one real label.** Plant Hierarchy -> **Test printer**. The `?STATUS` probe proves route,
   firewall, service and queue binding in one call and **consumes no label**.

7. **Launch the workstation session LAST.** `session.custom.printer` resolves once at startup.

---

## Swapping a printer already in service

    MesZebraBridge.exe detect
    MesZebraBridge.exe set-queue "<exact new queue name>"

**Restart the workstation session too**, or the operator keeps printing to the old endpoint while the
Config Tool test passes against the database. `install` is safe to re-run and re-checks service and
firewall, but will **not** move an existing binding -- a conf naming a queue reports `detection skipped`.

---

## Failure taxonomy (spec section 6.3)

Each row sends you to a different machine. Produced against real hardware, not predicted -- collapsing
them is what cost most of 2026-09-29.

| Gateway says | Means | Fix |
|---|---|---|
| `Connection refused` | service not running | `MesZebraBridge.exe status`, then the log |
| `Connect timed out` | firewall rule missing or scoped wrong | re-run `install` |
| `ERR queue unconfigured` | bridge up, network fine, no `Queue=` written | run `install` at the machine |
| `ERR queue not found: 'X'; visible: ...` | conf names a queue this host lacks | `set-queue` from the `visible:` list |
| `EndpointUnresolved` | config problem, nothing attempted -- usually no Terminal IP | step 2 |
| `?STATUS ready=false` | queue exists but offline, paused or errored | the printer itself |
| nothing at all | not our bridge -- a networked Zebra on raw 9100 | expected for `ConnectionKind = Networked` |

`MesZebraBridge.exe status` answers most of these in one command: the conf it read, the queue it will
use, whether the spooler actually has that queue, and the service state.

Logs: `%ProgramData%\BlueRidge\MesZebraBridge\logs\bridge-YYYYMMDD.log`, local time with offset,
14 days retained.

---

## Status

**The path is proven end to end on real hardware, across a VPN.** A shipping label went from the Gateway in
gateway scope, through this service on another machine, to a physical Zebra -- installed by a second person
working from these instructions, running under the real SCM, printed from a remote Ignition instance over
VPN. So the first terminal is **not** a bring-up: the technology, the wire contract and the failure taxonomy
(spec 6.3, produced against that hardware) are all settled.

What is still per-terminal is **commissioning**, not proof: each machine's driver, its exact queue name, its
Terminal `IpAddress`, and its firewall rule. `?STATUS` confirms all four per machine without consuming a
label, which is what makes 54 of them tractable. The live risks are therefore the mundane ones -- a queue
named differently than expected, a terminal with no `IpAddress` set yet (38 of 77 as of 2026-09-30), or
something else already holding port 9100.
