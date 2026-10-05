# MesZebraBridge -- release record

Wire protocol: `zebraPrinter/PROTOCOL.md` v1.0.0.
Spec: `docs/superpowers/specs/2026-09-29-zebra-bridge-service-and-print-traceability-design.md`.

## 1.0.0

| | |
|---|---|
| Built | 2026-09-30, from the tree at the commit that adds this file |
| Target | .NET Framework 4.8 (`net48`), AnyCPU |
| Toolchain | .NET SDK 10.0.201, `Microsoft.NETFramework.ReferenceAssemblies` 1.0.3 |
| Size | 54784 bytes |
| SHA-256 | **`A4DCFDA1B0B3903990C42F349183B1C77DF2405400D1EB96E1C8D0F50F574430`** -- rebuilt 2026-10-04 at `55b925a8`, and this is the copy staged in `dist/bridge-flashdrive/`. |
| Superseded hash | `6A208EDD...5B70` was recorded on 2026-09-30 and **does not match any binary that now exists**. Do not give it to MPP IT. |
| Reproducible | **Only for a fixed source + build directory + toolchain.** `Deterministic=true` makes repeated clean rebuilds in the same checkout byte-identical (verified twice on 2026-10-04: both `A4DCFDA1...`), but it does NOT make the hash portable: there is no `PathMap`, so a build from a different directory embeds different absolute paths and lands on a different hash. Three builds of this same unchanged source have produced three hashes (`6A208EDD...` in an agent worktree, `DD0467AB...` in the main tree on 2026-09-30, `A4DCFDA1...` in the main tree on 2026-10-04). |

> **Rule that follows from this: ship ONE exe and hash THAT FILE.** Never quote a hash from this
> file to MPP IT without first running `sha256sum` (or `Get-FileHash`) over the exact binary going
> on the flash drive. The source has not changed since `c3827380` -- no `.cs` or `.csproj` commit
> after it -- so all three builds are the same reviewed 1.0.0 code; they are simply not the same
> bytes. If a portable, quotable hash is ever actually required, add `<PathMap>` to the csproj and
> re-record; that is the fix, and it has not been done.

| Signed | **No.** Spec open item 12.4 is unresolved -- this hash is what MPP IT can allowlist in the meantime. |
| Service account | `LocalSystem`. Spec open item 12.3, assumption stated in the plan's Global Constraints. |
| Verified | Protocol and socket behaviour by the 113-test suite, and the two-file pair run standalone. **Not yet against a physical Zebra or over the network** -- that is the plan's Task 15, which needs a terminal PC with a printer attached. |

Rebuild:

    dotnet build zebraPrinter/MesZebraBridge/MesZebraBridge.csproj -c Release

`bin/Release/` must contain only `MesZebraBridge.exe` and `MesZebraBridge.pdb`.
Two csproj properties keep it that way: `AutoGenerateBindingRedirects=false`
suppresses the assembly-redirect block, and `GenerateSupportedRuntime=false`
suppresses the `<supportedRuntime>` stub MSBuild otherwise emits for a `net48`
target even with no `App.config` in the project. If a `.exe.config` reappears,
one of those two was dropped; if a `.dll` appears, a `PackageReference` is
missing `PrivateAssets="All"`. Fix the csproj -- do not ship the folder.

## What gets copied to a machine

**Two files, same pair on all 54 machines:**

| File | Per machine? |
|---|---|
| `MesZebraBridge.exe` | identical everywhere |
| `MesZebraBridge.conf` | identical everywhere as shipped -- it carries `GatewayAddress=172.17.10.161` and no queue. `install` adds this machine's `Queue=` line. |

Nothing is compiled into the exe (spec section 10.1). The Gateway address is in the
conf, authored once, never typed per machine. If it is ever wrong, it is wrong
visibly in a text file rather than invisibly in a binary.

The `.pdb` is optional at the target and is only worth copying when a stack trace
with line numbers is wanted.

## Per-machine deployment (spec section 7)

This is a **single visit per terminal**, walking the line. Steps 1, 3, 4 and 7
happen at the machine; 2, 5 and 6 from the Config Tool.

1. **Read the address and the queue name** -- `ipconfig` and `Get-Printer`.
   Write down the exact queue name; step 4 checks against it.
2. **Terminal IP** -- set it on the Terminal row in the Config Tool to match what
   the PC reports. This must precede steps 4-6: the printer endpoint derives from it.
3. **Driver** -- install the Zebra driver if it is not already there.
4. **Bridge** -- copy **both** `MesZebraBridge.exe` and `MesZebraBridge.conf` to a
   local folder (`C:\BlueRidge\` by convention), then from an **elevated** prompt:

       MesZebraBridge.exe install

   It reads the conf beside it, detects the queue, writes the `Queue=` line, registers
   the service as `LocalSystem` with start=auto, sets restart-on-failure recovery
   (5s / 5s / 60s), adds the inbound TCP 9100 rule scoped to the Gateway, starts, and
   prints `BOUND QUEUE: <name>`.

   **Check that against the name from step 1.**

   If it reports more than one Zebra candidate, or none, it installs nothing and asks
   for the name -- pick it from the listing it printed:

       MesZebraBridge.exe install --queue "Zebra GX420d (RAW)"

   If it refuses with `no GatewayAddress`, the conf file was not copied alongside the exe.
5. **Printer row** -- under that terminal in the Config Tool, `ConnectionKind = UsbBridge`.
   No endpoint is entered; it derives from the terminal IP from step 2.
6. **Verify from the Gateway** -- the `?STATUS` probe (spec section 9), then one real
   label. The probe consumes nothing.
7. **Launch the workstation session**, last, so it resolves the printer on its first startup.

## Swapping a printer on a terminal already in service

    MesZebraBridge.exe set-queue "<exact new queue name>"

Writes the conf, restarts the service, prints the new binding. `MesZebraBridge.exe detect`
lists the machine's queues if the name is not to hand. Then probe with `?STATUS` to confirm.

`MesZebraBridge.exe install` is safe to re-run instead and does the same thing plus
re-checking the service and firewall rule. It will **not** re-detect and move an
existing binding: a conf that already names a queue reports `detection skipped`.

**Also restart the workstation session.** `session.custom.printer` resolved once at its
startup, so a live operator session keeps printing to the old endpoint and the Config Tool
test will pass against the database while it does (spec section 7).

## Diagnostics

| Symptom at the Gateway | Where to look |
|---|---|
| `Connection refused` | the service is not running. `MesZebraBridge.exe status`, then the log. |
| `Connect timed out` | the firewall rule is missing or scoped to the wrong address. Re-run `install`. |
| `ERR queue unconfigured: ...` | the bridge is up and the network is fine, but no `Queue=` was ever written. Run `install` at the machine. |
| `ERR queue not found: 'X'; visible: ...` | the conf names a queue this host does not have -- usually a typo or a swapped printer. `set-queue "<name>"` from the `visible:` list. |
| `?STATUS` says `ready=false` | the queue exists but is offline, paused or in error. Check the printer itself. |
| nothing at all in reply | not our bridge -- a real networked Zebra on raw 9100. Expected for `ConnectionKind = Networked`. |

`MesZebraBridge.exe status` answers most of these at the machine in one command: it
prints the conf it read, the queue it will use, whether the spooler actually has that
queue, and the service state.

Logs: `%ProgramData%\BlueRidge\MesZebraBridge\logs\bridge-YYYYMMDD.log`, local
time with offset, 14 days retained.
