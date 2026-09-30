# `MesZebraBridge` -- C# Windows Service -- Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `MesZebraBridge.exe` that replaces `zebraPrinter/usb_tcp_bridge.py` as the deployed artifact on 54 plant PCs. It listens on `0.0.0.0:9100`, speaks `zebraPrinter/PROTOCOL.md` v1.0.0 byte for byte, spools ZPL to the Windows print queue **named in its conf file** through `winspool.drv` RAW, rolls a local log, and installs itself as a service with SCM restart-on-failure recovery and its own inbound firewall rule scoped to the Gateway.

**Architecture:** The Python reference's testability seam is carried over verbatim: request-to-response is a pure function with the spooler and the queue-status reader injected. Everything that touches Win32 sits behind a thin, barely-logic-bearing shim so that the parts worth testing are testable with no printer attached.

```
Program.cs        verbs: (no args) | run | install | set-queue | uninstall | status | detect
  Host.cs         shared bootstrap -- conf -> log -> QueueBinding -> BridgeServer
    BridgeConfig  key=value conf file beside the exe + CLI overrides     [pure, tested]
    RollingLog    daily file, N-day retention, never throws             [tested]
    QueueBinding  the conf'd queue name, or null -> ERR queue unconfigured [tested]
    BridgeServer  SO_EXCLUSIVEADDRUSE socket, half-close read, 1 line out [tested]
      Router.Route(data, binding, spool, status)                        [pure, tested]
        Protocol.HandleRequest(data, queue, spool, status)              [pure, tested]
      Spooler.SpoolRaw / ReadQueueStatus                                [P/Invoke shim]
  Installer.cs    CreateService + failure actions + netsh rule + conf write
      Installer.BuildFirewallAddArgs(...)                               [pure, tested]
      QueueResolver.Select(IEnumerable<PrinterEntry>) -> QueueResolution [pure, tested]
        ^^ INSTALL-TIME ONLY. Never on the runtime path.
      Spooler.EnumerateLocalQueues()                                    [P/Invoke shim]
```

`Protocol.cs` is a direct transliteration of `usb_tcp_bridge.handle_request` / `_quote` / `_oneline`, and `Spooler.cs` of `send_raw` / `queue_status`. Where the two implementations could drift, a test pins the C# side to the bytes recorded in `PROTOCOL.md` § Verified.

**Tech Stack:** C# 7.3, .NET Framework 4.8 (`net48`), BCL only -- **zero runtime NuGet dependencies**, so the build output is a single `.exe`. Built with the .NET 10 SDK (`dotnet build`); `Microsoft.NETFramework.ReferenceAssemblies` 1.0.3 supplies the targeting pack, because no .NET Framework reference assemblies are installed on this machine and there is no Visual Studio or standalone MSBuild. Tests: xUnit 2.9.3 + Microsoft.NET.Test.Sdk 17.14.1 + xunit.runner.visualstudio 3.1.4, all already in the local NuGet cache, run with `dotnet test`.

**Spec:** `docs/superpowers/specs/2026-09-29-zebra-bridge-service-and-print-traceability-design.md` §§ 2, 3, 4, 7, 9, 10.1, 11, 12.
**Contract:** `zebraPrinter/PROTOCOL.md` v1.0.0 -- **frozen**. Nothing in this plan changes it.
**Reference implementation:** `zebraPrinter/usb_tcp_bridge.py`, and its protocol tests at `zebraPrinter/tests/test_bridge_protocol.py`, whose every case has a C# counterpart here.

> **Note on spec § 3.** Its "Changed:" bullet still describes runtime queue auto-detection *"on a live port"*. That is superseded -- see Global Constraint 5. Spec § 7 step 4 (*"copy `MesZebraBridge.exe` **and its conf file**"*, *"**reports the queue it bound** so it can be checked against step 1"*), § 7's `set-queue` reference, and § 10.1 (*"Nothing may be compiled into the bridge binary"*) are the current model, and this plan follows those.

---

## Global Constraints

### Non-negotiable

- **`PROTOCOL.md` is frozen.** If an implementation detail seems to require a wire change, stop and raise it with Jacques. Three workstreams build against that file.
- **Zero runtime NuGet dependencies.** A `PackageReference` that lands a DLL in `bin/` turns a two-file deployment into a folder deployment. `Microsoft.NETFramework.ReferenceAssemblies` carries `PrivateAssets="All"` and is build-time only.
- **BCL only, and `net48` only.** No `net8.0`, no self-contained publish, no ILMerge. .NET Framework 4.8 is on every Windows 10/11 image, which is the entire reason for the target.
- **The deployed artifact is two files: `MesZebraBridge.exe` and `MesZebraBridge.conf`** (spec § 7 step 4). The exe is identical on all 54 machines; the conf is authored **once** with the Gateway address and copied with it.
- **Nothing is compiled in** (spec § 10.1). No Gateway address, no queue name, no port. Every deployment-specific value comes from the conf file or the command line, and `install` refuses rather than defaulting where a wrong value would be silent.
- **No runtime queue detection.** The queue name is explicit configuration. See Global Constraint 5.
- **`SO_EXCLUSIVEADDRUSE`, never `SO_REUSEADDR`.** Set via `Socket.ExclusiveAddressUse = true` **before `Bind`** (setting it after throws `InvalidOperationException`). On Windows `SO_REUSEADDR` lets a *second live process* bind the same port with undefined delivery between them. Task 11 pins both halves of this as tests.
- **An empty request gets no response at all**, configured queue or not. `BlueRidge.Location.Printer.validateEndpoint` connects and closes without sending; that bare-connect probe must keep working unchanged. The silence check runs *before* the queue check in `Router.Route`.
- **Responses are exactly one line**, ASCII, terminated `\n`. Any embedded newline in error text is collapsed to spaces before it reaches the socket.
- **Do not touch port 9100 during development.** Other work is using it. Every automated test binds `127.0.0.1:0` (ephemeral). Only Task 15, at the machine with the printer, uses 9100.
- **Do not touch the database, the Ignition gateway, `scan.ps1`, or any Ignition resource.** This workstream is entirely under `zebraPrinter/`.
- **Logging must never fail a print.** Every log write is inside a `try`/`catch` that swallows.

### Assumptions made where spec § 12 leaves an open item

These are **decisions taken to unblock the build**, not resolutions. Each is cheap to change and is called out in the task that implements it.

1. **Configuration file (open item 12.1 -- "format and location not yet specified").**
   Assumed: an ASCII `key=value` text file named **`MesZebraBridge.conf`, beside the
   executable**, `#` for comments, keys case-insensitive. Keys: `Queue`,
   `GatewayAddress`, `Port`, `LogDirectory`, `LogRetainDays`. Overridable with
   `--conf <path>`.
   *Location:* spec § 7 step 4 says the deployment is *"`MesZebraBridge.exe` and its
   conf file"* and § 10.1 says the Gateway address *"lives in the conf file shipped
   beside the executable -- authored once for all 54 installs"*. Beside the exe is
   therefore the spec's location, not mine.
   *Format:* XML `app.config` would bind the file to assembly loading and make it
   awkward for a human to author once and copy; `net48` has no first-class JSON
   reader; `key=value` parses in 30 lines with no dependency and a commissioner can
   read it over someone's shoulder. Chosen for that, not on merit.
   Logs stay under `%ProgramData%\BlueRidge\MesZebraBridge\logs` -- machine state, not
   shipped configuration, and it keeps the deployment directory clean.
2. **Gateway address -- NO LONGER AN ASSUMPTION. Settled by spec § 10.1.**
   `172.17.10.161`, the plant Ignition Gateway (confirmed 2026-09-30), **in the conf
   file**, and *"Nothing may be compiled into the bridge binary."* There is no
   `DefaultGatewayAddress` constant and `install` **fails loudly** when the conf
   carries no address rather than widening the rule.
   *Recorded because an earlier revision of this plan got it wrong:* it carried a
   compile-time default of `10.20.11.53`, which was the **development** Gateway on a
   laptop -- correct on 2026-09-29 and stale that same evening when the machine
   changed networks. A hardcoded address is invisible when it is wrong.
3. **Service account (open item 12.3).** Assumed **`LocalSystem`** (`CreateServiceW` with
   `lpServiceStartName = null`). `winspool`'s `OpenPrinter` must see the local queue, and a
   lower-privilege account may not; install already needs elevation for the SCM and the
   firewall. `install` prints the account it used, so tightening it later is a one-line
   change plus a re-install.
4. **Code signing (open item 12.4).** Assumed **unsigned**. No Authenticode or strong-name
   step. Task 14 emits the release binary's SHA-256 so MPP IT can allowlist by hash if
   SmartScreen or AV heuristics bite, and sets `AssemblyTitle` / `Company` / `Product` /
   `FileVersion` so the binary at least identifies itself.

### Interpretations of under-specified behaviour

Each of these is a place the spec or `PROTOCOL.md` does not say, where a C# implementation
has to say something. Flagged rather than buried.

5. **The queue name is EXPLICIT CONFIGURATION. Detection is an install-time
   convenience and never runs at runtime.**

   An earlier revision of this plan implemented spec § 3's *"single Zebra/ZDesigner
   driver **on a live port**"* as a runtime heuristic, with a dead-port name list
   standing in for a "live port" test that Win32 does not provide. **Real data
   settles it against that.** One observed printer host carried three candidates:

   | Queue | Driver | Port | |
   |---|---|---|---|
   | `ZDesigner GX420d (Copy 1)` | ZDesigner GX420d | `USB001` | live |
   | `ZDesigner GX420d` | ZDesigner GX420d | `LPT1:` | stale |
   | `Zebra GX420d (RAW)` | ZDesigner GX420d | `USB001` | live -- **the one in use** |

   Dead-port filtering removes only the `LPT1:` row and leaves **two live candidates
   on the same port**, which no status bit separates. Any rule that picks one is a
   coin flip whose wrong side is a terminal that spools to a queue nobody watches.

   So:
   - The **runtime** path reads `Queue=` from the conf and does nothing else. No
     enumeration, no heuristic, no retry, no latch.
   - `install` runs detection **once, as a convenience**: exactly one candidate and it
     writes that name into the conf and **prints it**; zero or several and it lists
     every queue it found with its driver and port and **requires
     `--queue "<name>"`**. It never guesses and never proceeds unbound.
   - `detect` exposes the same listing as a standalone verb.

   This costs the commissioner nothing: spec § 7 step 1 has them run `Get-Printer` at
   the machine before anything else, and § 7 step 4 wants `install` to *"report the
   queue it bound so it can be checked against step 1"*. Confirming a name they are
   already looking at removes a whole class of silent mis-binding.
6. **An unconfigured queue does not stop the service listening.** If the conf carries no
   `Queue=`, the bridge **starts, logs the error loudly, binds, and answers every request
   `ERR queue unconfigured: ...`**. A service that refuses to start presents to the Gateway
   as `Connection refused`, which spec § 6.3 maps to *"host is up, nothing listening --
   bridge is down"* -- sending the diagnosis to the wrong machine and defeating § 9's
   commissioning probe. A `Queue=` naming a queue that is **not on the host** needs nothing
   extra: `PROTOCOL.md` already requires `?STATUS` to answer `ready=false` while naming it,
   and a print to answer `ERR queue not found: 'X'; visible: ...`.
7. **`PROTOCOL.md`'s `ERR queue not found: 'X'; visible: ...` example is richer than what
   the Python bridge actually emits** (it emits the bare `WinError` text). Assumed: the C#
   service produces the documented richer shape for the specific "no such queue" error codes
   (1801 / 123 / 2) by enumerating visible queues, and the plain Win32 message otherwise.
   This matches the example in the frozen document and is what makes spec § 6.3's
   `QueueRejected` diagnostic -- and it is now the *primary* signal for a mistyped `Queue=`.
8. **`PROTOCOL.md` caps the request at 1 MiB but says nothing about the response.** Assumed
   a **1024-byte cap**, truncating with `...`, because `; visible: <30 queues>` on a real host
   could otherwise produce a very long line. The Gateway's `_parseAck` reads one line, so a
   cap is safe; the number is invented.
9. **1 MiB truncation is exact.** The Python loop checks its cap *after* appending, so it can
   overshoot by up to 4095 bytes. C# reads the same way but hard-truncates to exactly
   1048576 before spooling, so the `bytes=` in the ACK is a number the Gateway can trust.
   A deliberate, tiny divergence from the reference.
10. **Connections are served concurrently; the spooler is serialised.** The Python bridge
    accepts serially, so one client holding a socket open stalls the next dispatch for the
    full 2s read timeout. Each connection is handed to the thread pool instead, with
    `Spooler.SpoolRaw` under a lock -- job ordering at the queue is the thing that would
    otherwise be arbitrary. Per-connection wire behaviour is byte-identical either way.
11. **Log timestamps are local time with offset** (`yyyy-MM-dd HH:mm:ss.fff K`), not UTC.
    CLAUDE.md's UTC-store/ET-display rule governs the database; this file is read by a person
    standing at the machine. Deliberate, and the offset makes it unambiguous.
12. **`?STATUS` parse parity.** `Encoding.ASCII.GetString(data).Trim().ToUpperInvariant()`
    mirrors Python's `.decode("ascii","replace").strip().upper()`. One cosmetic difference:
    a non-ASCII byte becomes `?` in C# and U+FFFD in Python. It can only ever appear in the
    echoed text of an unknown command, never in a verified exchange.
13. **A printer swap must not require a reinstall.** Printers get swapped in service, and
    spec § 7 calls re-commissioning *"the case that needs care, not first commissioning"*.
    So:
    - **`install` is idempotent.** Run against a machine that already has the service, it
      rewrites the conf, reconfigures the service and the firewall rule, and **restarts**
      rather than failing.
    - **`set-queue "<name>"`** is the narrow verb for the swap case: write the conf, restart
      the service, print the new binding. No SCM or firewall work.
    - Both write the same conf file and take the same code path, so they cannot diverge.
    - After either, `?STATUS` reports the new queue. A swap is: re-run, probe, done.

    The bridge does **not** reload the conf while running -- the restart is the reload, and
    it is one line of either verb. A file watcher would be a second, quieter path to the
    same state.

    Note for whoever runs the swap: spec § 7 says a swap on a terminal already in service
    also needs the **workstation session** restarted, because `session.custom.printer`
    resolved once at its startup. That is Config-Tool-side and outside this plan.

### Conventions

- Namespace `BlueRidge.MesZebraBridge`; tests `BlueRidge.MesZebraBridge.Tests`.
- Every source file opens with a comment saying what it guards or mirrors, matching the
  `zebraPrinter/tests/` convention.
- `Protocol.BridgeVersion` is `"1.0.0"` and a test asserts it, so a bump is deliberate.
- Commit after each task. Branch `jacques/working`. Stage explicit paths -- never `git add -A`.
- Omit the `Co-Authored-By: Claude` trailer.

---

### Task 1: Scaffold the two projects and prove the `net48` toolchain

Nothing here is bridge logic. The point is to find out **now** whether `net48` builds and
tests on this machine, because there is no Visual Studio, no MSBuild, and no .NET Framework
targeting pack on disk -- only the .NET 10 SDK. If this task fails, every later task is
blocked and the failure is a toolchain problem, not a design one.

**Files:**
- Create: `zebraPrinter/MesZebraBridge/MesZebraBridge.csproj`
- Create: `zebraPrinter/MesZebraBridge/Protocol.cs`
- Create: `zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj`
- Create: `zebraPrinter/MesZebraBridge.Tests/ProtocolTests.cs`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `zebraPrinter/PROTOCOL.md` (the version string)
- Produces: `Protocol.BridgeVersion : const string`, and a buildable/testable project pair

- [ ] **Step 1: Confirm the prerequisite is reachable before anything else**

`Microsoft.NETFramework.ReferenceAssemblies` is **not** in the local NuGet cache, so the
first restore needs the internet.

```powershell
dotnet nuget list source
```

Expected: `nuget.org [Enabled] https://api.nuget.org/v3/index.json`. If nuget.org is not
reachable from this machine, stop -- `net48` cannot be built here and that is the finding.

- [ ] **Step 2: Ignore .NET build output**

Append to `.gitignore`:

```gitignore

# .NET build output (zebraPrinter/MesZebraBridge)
[Bb]in/
[Oo]bj/
*.csproj.user
```

Verify nothing tracked is about to be ignored:

```bash
git ls-files | grep -E "(^|/)(bin|obj)/" ; echo "exit=$?"
```

Expected: no output, `exit=1`.

- [ ] **Step 3: Write the service project file**

Create `zebraPrinter/MesZebraBridge/MesZebraBridge.csproj`:

```xml
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net48</TargetFramework>
    <LangVersion>7.3</LangVersion>
    <AssemblyName>MesZebraBridge</AssemblyName>
    <RootNamespace>BlueRidge.MesZebraBridge</RootNamespace>

    <!-- Identity, so a plant PC's Task Manager and Properties dialog name the binary.
         Relevant to spec open item 12.4: an unsigned exe that at least identifies
         itself fares better with AV heuristics than an anonymous one. -->
    <Company>Blue Ridge Automation</Company>
    <Product>MES Zebra Bridge</Product>
    <AssemblyTitle>MES Zebra Bridge</AssemblyTitle>
    <Description>Accepts ZPL on TCP 9100 and spools it to the local Zebra print queue (RAW datatype). Wire protocol: zebraPrinter/PROTOCOL.md v1.0.0.</Description>
    <Copyright>Blue Ridge Automation</Copyright>
    <Version>1.0.0</Version>
    <FileVersion>1.0.0.0</FileVersion>

    <!-- The deployment is the exe plus its conf file (spec section 7 step 4) and
         NOTHING ELSE. No PackageReference may put a DLL in bin/.
         AutoGenerateBindingRedirects off keeps MesZebraBridge.exe.config from
         being emitted at all, so bin/ holds the exe and its pdb and nothing else. -->
    <AutoGenerateBindingRedirects>false</AutoGenerateBindingRedirects>
    <GenerateDocumentationFile>false</GenerateDocumentationFile>
    <AppendTargetFrameworkToOutputPath>false</AppendTargetFrameworkToOutputPath>
    <DebugType>pdbonly</DebugType>
    <Deterministic>true</Deterministic>
  </PropertyGroup>

  <ItemGroup>
    <!-- Build-time only: supplies the net48 targeting pack. No .NET Framework
         reference assemblies are installed on the build machine and there is no
         Visual Studio. PrivateAssets=All keeps it out of the output. -->
    <PackageReference Include="Microsoft.NETFramework.ReferenceAssemblies" Version="1.0.3" PrivateAssets="All" />
  </ItemGroup>

  <ItemGroup>
    <!-- SDK-style net48 projects do NOT auto-reference System.ServiceProcess.
         ServiceBase and ServiceController both live there. -->
    <Reference Include="System.ServiceProcess" />
  </ItemGroup>

</Project>
```

- [ ] **Step 4: Write the test project file**

Create `zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj`:

```xml
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <TargetFramework>net48</TargetFramework>
    <LangVersion>7.3</LangVersion>
    <RootNamespace>BlueRidge.MesZebraBridge.Tests</RootNamespace>
    <IsPackable>false</IsPackable>
    <AppendTargetFrameworkToOutputPath>false</AppendTargetFrameworkToOutputPath>
    <!-- The test host DOES need redirects; only the shipped exe must stay bare. -->
    <AutoGenerateBindingRedirects>true</AutoGenerateBindingRedirects>
    <GenerateBindingRedirectsOutputType>true</GenerateBindingRedirectsOutputType>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.NETFramework.ReferenceAssemblies" Version="1.0.3" PrivateAssets="All" />
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.14.1" />
    <PackageReference Include="xunit" Version="2.9.3" />
    <PackageReference Include="xunit.runner.visualstudio" Version="3.1.4" />
  </ItemGroup>

  <ItemGroup>
    <ProjectReference Include="..\MesZebraBridge\MesZebraBridge.csproj" />
  </ItemGroup>

</Project>
```

- [ ] **Step 5: Write the failing test**

Create `zebraPrinter/MesZebraBridge.Tests/ProtocolTests.cs`:

```csharp
// Wire-protocol guard for the MES Zebra bridge, C# side.
//
// zebraPrinter/PROTOCOL.md is the contract three workstreams build against -- this
// service, LabelTransport's ACK read, and the Config Tool's test button. Every case
// in zebraPrinter/tests/test_bridge_protocol.py has a counterpart here, so the two
// implementations cannot drift apart silently.
//
// The spooler and the queue-status reader are injected, so nothing here needs a
// printer, a driver, or Windows print services.
//
// Run: dotnet test zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj

using BlueRidge.MesZebraBridge;
using Xunit;

namespace BlueRidge.MesZebraBridge.Tests
{
    public class ProtocolTests
    {
        [Fact]
        public void Bridge_version_is_the_one_PROTOCOL_md_publishes()
        {
            // PROTOCOL.md's verified exchange reads `OK bridge=1.0.0 ...`. A bump here
            // is a protocol change and needs the document changed first.
            Assert.Equal("1.0.0", Protocol.BridgeVersion);
        }
    }
}
```

- [ ] **Step 6: Run the test to verify it fails**

```powershell
dotnet test zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj
```

Expected: a **compile** failure, `error CS0246: The type or namespace name 'Protocol' could not be found`. A restore error instead means Step 1's prerequisite is not actually satisfied.

- [ ] **Step 7: Create the minimal `Protocol`**

Create `zebraPrinter/MesZebraBridge/Protocol.cs`:

```csharp
// The wire protocol, transliterated from zebraPrinter/usb_tcp_bridge.py's
// handle_request / _quote / _oneline. Pure apart from the two injected callables,
// so the whole protocol is testable with no printer attached.
//
// zebraPrinter/PROTOCOL.md is normative and frozen. Change it there first.

using System;

namespace BlueRidge.MesZebraBridge
{
    public static class Protocol
    {
        /// <summary>Reported by ?STATUS. Must match PROTOCOL.md's version heading.</summary>
        public const string BridgeVersion = "1.0.0";
    }
}
```

- [ ] **Step 8: Run the test to verify it passes**

```powershell
dotnet test zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj
```

Expected: `Passed!  - Failed: 0, Passed: 1`.

- [ ] **Step 9: Commit**

```bash
git add .gitignore zebraPrinter/MesZebraBridge/MesZebraBridge.csproj zebraPrinter/MesZebraBridge/Protocol.cs zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj zebraPrinter/MesZebraBridge.Tests/ProtocolTests.cs
git commit -m "build(bridge): a net48 project pair that builds and tests without Visual Studio"
```

---

### Task 2: The silent empty request, and the handler seam

The first real protocol rule, and the one most easily broken by accident: a bare connect must
get **no bytes at all**, because `BlueRidge.Location.Printer.validateEndpoint` probes
reachability that way. Mirrors `test_empty_request_gets_no_reply`.

**Files:**
- Modify: `zebraPrinter/MesZebraBridge/Protocol.cs`
- Modify: `zebraPrinter/MesZebraBridge.Tests/ProtocolTests.cs`

**Interfaces:**
- Consumes: `Protocol.BridgeVersion` from Task 1
- Produces:
  - `struct SpoolResult { int JobId; int BytesWritten; }`
  - `struct QueueStatus { string Queue; bool Ready; int Jobs; }`
  - `Protocol.HandleRequest(byte[] data, string queueName, Func<byte[], SpoolResult> spool, Func<QueueStatus> status) -> string` (`null` = stay silent)
  - `Protocol.Quote(string) -> string`, `Protocol.OneLine(string) -> string`, `Protocol.Cap(string) -> string`
  - `Protocol.MaxRequestBytes = 1048576`, `Protocol.MaxResponseBytes = 1024`

- [ ] **Step 1: Write the failing tests**

Add to the `ProtocolTests` class in `zebraPrinter/MesZebraBridge.Tests/ProtocolTests.cs`:

```csharp
        private static SpoolResult SpoolOk(byte[] data)
        {
            return new SpoolResult(41, data.Length);
        }

        private static QueueStatus StatusOk()
        {
            return new QueueStatus("Zebra GX420d (RAW)", true, 0);
        }

        [Fact]
        public void An_empty_request_gets_no_reply()
        {
            // validateEndpoint connects and closes without sending. Replying to that
            // would be a protocol change; staying silent is the contract.
            Assert.Null(Protocol.HandleRequest(new byte[0], "Q", SpoolOk, StatusOk));
        }

        [Fact]
        public void A_null_request_gets_no_reply()
        {
            Assert.Null(Protocol.HandleRequest(null, "Q", SpoolOk, StatusOk));
        }

        [Fact]
        public void A_quoted_value_doubles_an_embedded_quote()
        {
            Assert.Equal("'Bob''s Zebra'", Protocol.Quote("Bob's Zebra"));
            Assert.Equal("'Zebra GX420d (RAW)'", Protocol.Quote("Zebra GX420d (RAW)"));
            Assert.Equal("''", Protocol.Quote(null));
        }

        [Fact]
        public void Oneline_collapses_every_whitespace_run_to_a_single_space()
        {
            // One-line framing is not negotiable, and Win32 messages are multi-line.
            Assert.Equal("a b c", Protocol.OneLine("a\r\n  b\t\tc\n"));
            Assert.Equal("", Protocol.OneLine("   "));
            Assert.Equal("", Protocol.OneLine(null));
        }

        [Fact]
        public void A_response_longer_than_the_cap_is_truncated_with_an_ellipsis()
        {
            string line = "ERR " + new string('x', 4000);
            string capped = Protocol.Cap(line);
            Assert.Equal(Protocol.MaxResponseBytes, capped.Length);
            Assert.EndsWith("...", capped);
            Assert.StartsWith("ERR xxx", capped);
            Assert.Equal("ERR short", Protocol.Cap("ERR short"));
        }
```

- [ ] **Step 2: Run the tests to verify they fail**

```powershell
dotnet test zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj
```

Expected: compile failure, `error CS0117: 'Protocol' does not contain a definition for 'HandleRequest'` (and the same for `Quote`, `OneLine`, `Cap`, `MaxResponseBytes`), plus `CS0246` for `SpoolResult` and `QueueStatus`.

- [ ] **Step 3: Implement the seam**

Replace the whole of `zebraPrinter/MesZebraBridge/Protocol.cs` with:

```csharp
// The wire protocol, transliterated from zebraPrinter/usb_tcp_bridge.py's
// handle_request / _quote / _oneline. Pure apart from the two injected callables,
// so the whole protocol is testable with no printer attached.
//
// zebraPrinter/PROTOCOL.md is normative and frozen. Change it there first.

using System;
using System.Text;

namespace BlueRidge.MesZebraBridge
{
    /// <summary>What the Windows spooler gave back: the job id and the bytes it took.</summary>
    public struct SpoolResult
    {
        public readonly int JobId;
        public readonly int BytesWritten;

        public SpoolResult(int jobId, int bytesWritten)
        {
            JobId = jobId;
            BytesWritten = bytesWritten;
        }
    }

    /// <summary>A queue's current state, as ?STATUS reports it.</summary>
    public struct QueueStatus
    {
        public readonly string Queue;
        public readonly bool Ready;
        public readonly int Jobs;

        public QueueStatus(string queue, bool ready, int jobs)
        {
            Queue = queue;
            Ready = ready;
            Jobs = jobs;
        }
    }

    public static class Protocol
    {
        /// <summary>Reported by ?STATUS. Must match PROTOCOL.md's version heading.</summary>
        public const string BridgeVersion = "1.0.0";

        /// <summary>PROTOCOL.md "Framing": a larger request is truncated at this limit.</summary>
        public const int MaxRequestBytes = 1048576;

        /// <summary>
        /// PROTOCOL.md caps the request but not the response. A "queue not found"
        /// error names every visible queue, which on a host with thirty of them would
        /// be a very long line, so it is capped here. The wire is ASCII, so one char
        /// is one byte and Length is the byte count.
        /// </summary>
        public const int MaxResponseBytes = 1024;

        private static readonly char[] Whitespace = { ' ', '\t', '\n', '\r', '\f', '\v' };

        /// <summary>Single-quote a wire value, doubling any embedded quote (PROTOCOL.md).</summary>
        public static string Quote(string value)
        {
            return "'" + (value ?? "").Replace("'", "''") + "'";
        }

        /// <summary>Collapse whitespace so an error can never break the one-line framing.</summary>
        public static string OneLine(string text)
        {
            if (text == null) return "";
            return string.Join(" ", text.Split(Whitespace, StringSplitOptions.RemoveEmptyEntries));
        }

        /// <summary>Hold a response inside MaxResponseBytes, marking the truncation.</summary>
        public static string Cap(string line)
        {
            if (line == null) return "";
            if (line.Length <= MaxResponseBytes) return line;
            return line.Substring(0, MaxResponseBytes - 3) + "...";
        }

        /// <summary>
        /// Map one request's bytes to one response line WITHOUT its trailing newline,
        /// or null when the protocol says stay silent.
        ///
        /// spool(data)  -> SpoolResult, throws on failure
        /// status()     -> QueueStatus
        /// </summary>
        public static string HandleRequest(byte[] data, string queueName,
                                           Func<byte[], SpoolResult> spool,
                                           Func<QueueStatus> status)
        {
            if (data == null || data.Length == 0) return null;
            return Cap("ERR not implemented");
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```powershell
dotnet test zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj
```

Expected: `Failed: 0, Passed: 6`.

- [ ] **Step 5: Commit**

```bash
git add zebraPrinter/MesZebraBridge/Protocol.cs zebraPrinter/MesZebraBridge.Tests/ProtocolTests.cs
git commit -m "test(bridge): a silent reply to an empty request is the contract, not an accident"
```

---

### Task 3: `?STATUS`

The commissioning primitive (spec § 4.2, § 9). Mirrors `test_status_reports_version_queue_and_readiness`, `test_status_is_case_insensitive`, `test_status_reports_a_not_ready_queue`, `test_a_quote_in_a_queue_name_is_doubled`, `test_unknown_command_is_refused_not_ignored`.

**Files:**
- Modify: `zebraPrinter/MesZebraBridge/Protocol.cs`
- Modify: `zebraPrinter/MesZebraBridge.Tests/ProtocolTests.cs`

**Interfaces:**
- Consumes: `Protocol.HandleRequest`, `Quote`, `Cap`, `BridgeVersion` from Task 2
- Produces: the `?STATUS` response line, consumed by the Config Tool's "Test this printer" action

- [ ] **Step 1: Write the failing tests**

Add to the `ProtocolTests` class:

```csharp
        [Fact]
        public void Status_reports_version_queue_and_readiness()
        {
            string reply = Protocol.HandleRequest(
                Encoding.ASCII.GetBytes("?STATUS"), "Zebra GX420d (RAW)", SpoolOk, StatusOk);
            Assert.Equal("OK bridge=1.0.0 queue='Zebra GX420d (RAW)' ready=true jobs=0", reply);
        }

        [Fact]
        public void Status_is_case_insensitive()
        {
            string lower = Protocol.HandleRequest(Encoding.ASCII.GetBytes("?status"), "Q", SpoolOk, StatusOk);
            string upper = Protocol.HandleRequest(Encoding.ASCII.GetBytes("?STATUS"), "Q", SpoolOk, StatusOk);
            // Assert the CONTENT too, not just that the two agree -- comparing them
            // alone passes against any stub that returns one constant for both.
            Assert.Equal(upper, lower);
            Assert.StartsWith("OK bridge=", lower);
        }

        [Fact]
        public void Status_tolerates_a_trailing_newline_from_a_line_oriented_client()
        {
            string reply = Protocol.HandleRequest(
                Encoding.ASCII.GetBytes("?STATUS\r\n"), "Q", SpoolOk, StatusOk);
            Assert.StartsWith("OK bridge=", reply);
        }

        [Fact]
        public void Status_reports_a_not_ready_queue()
        {
            string reply = Protocol.HandleRequest(
                Encoding.ASCII.GetBytes("?STATUS"), "Q", SpoolOk, () => new QueueStatus("Q", false, 3));
            Assert.Contains("ready=false", reply);
            Assert.Contains("jobs=3", reply);
        }

        [Fact]
        public void A_quote_in_a_queue_name_is_doubled_on_the_wire()
        {
            string reply = Protocol.HandleRequest(
                Encoding.ASCII.GetBytes("?STATUS"), "Q", SpoolOk,
                () => new QueueStatus("Bob's Zebra", true, 0));
            Assert.Contains("queue='Bob''s Zebra'", reply);
        }

        [Fact]
        public void An_unknown_command_is_refused_not_ignored()
        {
            string reply = Protocol.HandleRequest(
                Encoding.ASCII.GetBytes("?WAT"), "Q", SpoolOk, StatusOk);
            Assert.StartsWith("ERR unknown command", reply);
            Assert.Contains("?WAT", reply);
        }
```

Add `using System.Text;` to the file's using block.

- [ ] **Step 2: Run the tests to verify they fail**

```powershell
dotnet test zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj
```

Expected: `Failed: 6, Passed: 6` -- each failure showing the actual value `ERR not implemented`.

- [ ] **Step 3: Implement command dispatch**

In `zebraPrinter/MesZebraBridge/Protocol.cs`, replace the body of `HandleRequest` after the empty-data guard:

```csharp
            if (data == null || data.Length == 0) return null;

            if (data[0] == (byte)'?')
            {
                // Mirrors Python's data.decode("ascii","replace").strip().upper().
                // Encoding.ASCII substitutes '?' for a non-ASCII byte where Python
                // substitutes U+FFFD -- cosmetic, and reachable only in the echoed
                // text of an unknown command.
                string cmd = Encoding.ASCII.GetString(data).Trim().ToUpperInvariant();
                if (cmd == "?STATUS")
                {
                    QueueStatus s = status();
                    return Cap(string.Format("OK bridge={0} queue={1} ready={2} jobs={3}",
                        BridgeVersion, Quote(s.Queue), s.Ready ? "true" : "false", s.Jobs));
                }
                return Cap("ERR unknown command " + Quote(cmd));
            }

            return Cap("ERR not implemented");
```

- [ ] **Step 4: Run the tests to verify they pass**

```powershell
dotnet test zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj
```

Expected: `Failed: 0, Passed: 12`.

- [ ] **Step 5: Commit**

```bash
git add zebraPrinter/MesZebraBridge/Protocol.cs zebraPrinter/MesZebraBridge.Tests/ProtocolTests.cs
git commit -m "feat(bridge): ?STATUS answers which queue it is bound to, printing nothing"
```

---

### Task 4: The print ACK

Mirrors `test_zpl_is_spooled_and_acked_with_the_job_id` and `test_a_spooler_failure_is_reported_on_exactly_one_line`. `job` is the Windows spooler job id (`PROTOCOL.md` § Print); `OK` means the queue took the bytes as that job and never that a label printed (spec § 6.4).

**Files:**
- Modify: `zebraPrinter/MesZebraBridge/Protocol.cs`
- Modify: `zebraPrinter/MesZebraBridge.Tests/ProtocolTests.cs`

**Interfaces:**
- Consumes: `Protocol.HandleRequest` from Tasks 2-3
- Produces: the print response line, consumed by `BlueRidge.Lots.LabelTransport._parseAck`

- [ ] **Step 1: Write the failing tests**

Add to the `ProtocolTests` class:

```csharp
        [Fact]
        public void Zpl_is_spooled_and_acked_with_the_job_id()
        {
            byte[] seen = null;
            Func<byte[], SpoolResult> spool = d => { seen = d; return new SpoolResult(41, d.Length); };

            string reply = Protocol.HandleRequest(
                Encoding.ASCII.GetBytes("^XA^XZ"), "Zebra GX420d (RAW)", spool, StatusOk);

            Assert.Equal(Encoding.ASCII.GetBytes("^XA^XZ"), seen);
            Assert.Equal("OK queue='Zebra GX420d (RAW)' job=41 bytes=6", reply);
        }

        [Fact]
        public void A_spooler_failure_is_reported_on_exactly_one_line()
        {
            // The queue-not-found error names every visible queue, which is
            // multi-line. One-line framing is not negotiable, so it is collapsed.
            Func<byte[], SpoolResult> spool = d =>
            {
                throw new SpoolException("queue not found: 'ZDesigner GX420d'\nvisible:\n  A\n  B");
            };

            string reply = Protocol.HandleRequest(Encoding.ASCII.GetBytes("^XA^XZ"), "Q", spool, StatusOk);

            Assert.StartsWith("ERR ", reply);
            Assert.DoesNotContain("\n", reply);
            Assert.Contains("ZDesigner GX420d", reply);
        }

        [Fact]
        public void An_unexpected_exception_type_is_named_so_it_is_diagnosable()
        {
            // A SpoolException's Message is already self-describing; anything else
            // ("Object reference not set...") is not, so its type is prefixed.
            Func<byte[], SpoolResult> spool = d => { throw new InvalidOperationException("boom"); };

            string reply = Protocol.HandleRequest(Encoding.ASCII.GetBytes("^XA^XZ"), "Q", spool, StatusOk);

            Assert.Equal("ERR InvalidOperationException: boom", reply);
        }
```

Add `using System;` to the file's using block if not already present.

- [ ] **Step 2: Run the tests to verify they fail**

```powershell
dotnet test zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj
```

Expected: a compile failure, `error CS0246: The type or namespace name 'SpoolException' could not be found`.

- [ ] **Step 3: Add `SpoolException`**

Create `zebraPrinter/MesZebraBridge/SpoolException.cs`:

```csharp
// A spooler failure whose Message is already a complete, self-describing,
// single-line diagnosis -- so Protocol.HandleRequest can put it on the wire as-is.
// Spooler.cs is the only thing that throws it.

using System;
using System.Runtime.Serialization;

namespace BlueRidge.MesZebraBridge
{
    [Serializable]
    public class SpoolException : Exception
    {
        public SpoolException(string message) : base(message) { }

        protected SpoolException(SerializationInfo info, StreamingContext context)
            : base(info, context) { }
    }
}
```

- [ ] **Step 4: Implement the print branch**

In `zebraPrinter/MesZebraBridge/Protocol.cs`, replace the trailing `return Cap("ERR not implemented");` with:

```csharp
            SpoolResult result;
            try
            {
                result = spool(data);
            }
            catch (SpoolException ex)
            {
                return Cap("ERR " + OneLine(ex.Message));
            }
            catch (Exception ex)
            {
                return Cap("ERR " + OneLine(ex.GetType().Name + ": " + ex.Message));
            }

            return Cap(string.Format("OK queue={0} job={1} bytes={2}",
                Quote(queueName), result.JobId, result.BytesWritten));
```

- [ ] **Step 5: Run the tests to verify they pass**

```powershell
dotnet test zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj
```

Expected: `Failed: 0, Passed: 15`.

- [ ] **Step 6: Commit**

```bash
git add zebraPrinter/MesZebraBridge/Protocol.cs zebraPrinter/MesZebraBridge/SpoolException.cs zebraPrinter/MesZebraBridge.Tests/ProtocolTests.cs
git commit -m "feat(bridge): a print is acked with the queue and the spooler job id"
```

---

### Task 5: Byte-for-byte parity with `PROTOCOL.md` § Verified

`PROTOCOL.md` closes with: *"The C# `MesZebraBridge` service is correct when it reproduces the three verified exchanges above byte for byte."* That sentence becomes a test, so the claim is checked rather than asserted.

**Files:**
- Modify: `zebraPrinter/MesZebraBridge.Tests/ProtocolTests.cs`

**Interfaces:**
- Consumes: the whole of `Protocol` from Tasks 2-4
- Produces: no new interface. A regression gate on the frozen contract.

- [ ] **Step 1: Write the parity tests**

Add to the `ProtocolTests` class:

```csharp
        // ---- PROTOCOL.md "Verified": the exchanges observed 2026-09-29 against the
        // real Windows spooler and the real ZDesigner GX420d / USB002 driver.
        // PROTOCOL.md says this service is correct when it reproduces them byte for
        // byte, so that sentence is these tests.

        [Fact]
        public void Verified_exchange_1_status_against_ZDesigner_GX420d()
        {
            string reply = Protocol.HandleRequest(
                Encoding.ASCII.GetBytes("?STATUS"), "ZDesigner GX420d",
                SpoolOk, () => new QueueStatus("ZDesigner GX420d", true, 0));
            Assert.Equal("OK bridge=1.0.0 queue='ZDesigner GX420d' ready=true jobs=0", reply);
        }

        [Fact]
        public void Verified_exchange_2_a_38_byte_label_acked_as_job_15()
        {
            // Get-PrintJob independently reported `Id 15, MES ZPL, 38 bytes` for this
            // exchange, so both numbers on this line came from the spooler, not from us.
            byte[] zpl = new byte[38];
            for (int i = 0; i < zpl.Length; i++) zpl[i] = (byte)'x';

            string reply = Protocol.HandleRequest(zpl, "ZDesigner GX420d",
                d => new SpoolResult(15, d.Length), StatusOk);

            Assert.Equal("OK queue='ZDesigner GX420d' job=15 bytes=38", reply);
        }

        [Fact]
        public void Verified_exchange_3_empty_gets_no_reply()
        {
            Assert.Null(Protocol.HandleRequest(new byte[0], "ZDesigner GX420d", SpoolOk, StatusOk));
        }

        [Fact]
        public void A_queue_that_does_not_exist_on_the_host_reports_not_ready_while_naming_it()
        {
            // PROTOCOL.md: "Binding a queue name that does not exist on the host
            // returns ready=false while still naming what it tried -- which is how
            // commissioning catches the wrong-queue-name mistake before any label
            // is wasted."
            string reply = Protocol.HandleRequest(
                Encoding.ASCII.GetBytes("?STATUS"), "Zebra GX420d (RAW)",
                SpoolOk, () => new QueueStatus("Zebra GX420d (RAW)", false, 0));
            Assert.Equal("OK bridge=1.0.0 queue='Zebra GX420d (RAW)' ready=false jobs=0", reply);
        }

        [Fact]
        public void The_documented_queue_not_found_error_shape_survives_the_wire()
        {
            // PROTOCOL.md's Print example:
            //   ERR queue not found: 'ZDesigner GX420d'; visible: Zebra GX420d (RAW)
            Func<byte[], SpoolResult> spool = d =>
            {
                throw new SpoolException(
                    "queue not found: 'ZDesigner GX420d'; visible: Zebra GX420d (RAW)");
            };

            string reply = Protocol.HandleRequest(Encoding.ASCII.GetBytes("^XA^XZ"), "Q", spool, StatusOk);

            Assert.Equal("ERR queue not found: 'ZDesigner GX420d'; visible: Zebra GX420d (RAW)", reply);
        }
```

- [ ] **Step 2: Run the tests -- they should pass immediately**

```powershell
dotnet test zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj
```

Expected: `Failed: 0, Passed: 20`. These are a **gate, not a red-green step** -- Tasks 2-4 already implement the behaviour. If any fails, the transliteration is wrong and the fix goes in `Protocol.cs`, never in the test.

- [ ] **Step 3: Commit**

```bash
git add zebraPrinter/MesZebraBridge.Tests/ProtocolTests.cs
git commit -m "test(bridge): PROTOCOL.md's verified exchanges, pinned byte for byte"
```

---

### Task 6: The spooler -- `winspool.drv` RAW via P/Invoke

A transliteration of `usb_tcp_bridge.send_raw` and `queue_status`. `StartDocPrinterW`'s return value **is** the spooler job id -- verified 2026-09-29 against the real driver, with `Get-PrintJob` independently confirming `Id 15`. Plus Global Constraint 7: the "no such queue" error codes produce `PROTOCOL.md`'s documented `queue not found: 'X'; visible: ...` shape.

**Files:**
- Create: `zebraPrinter/MesZebraBridge/NativeMethods.cs`
- Create: `zebraPrinter/MesZebraBridge/Spooler.cs`
- Create: `zebraPrinter/MesZebraBridge.Tests/SpoolerTests.cs`

**Interfaces:**
- Consumes: `SpoolResult`, `QueueStatus`, `SpoolException`, `Protocol.Quote` / `.OneLine`
- Produces:
  - `struct PrinterEntry { string Name; string Driver; string Port; uint Attributes; uint Status; }`
  - `Spooler.SpoolRaw(string queueName, byte[] data) -> SpoolResult` (throws `SpoolException`)
  - `Spooler.ReadQueueStatus(string queueName) -> QueueStatus` (never throws)
  - `Spooler.EnumerateLocalQueues() -> IList<PrinterEntry>` (throws `SpoolException`)
  - `Spooler.NotReadyStatusMask : const uint`

- [ ] **Step 1: Write the failing tests**

These touch the real local spooler service, which every Windows box has, and need **no printer and no Zebra driver** -- the failure paths are driven with a queue name that cannot exist. No label is consumed and nothing is spooled.

Create `zebraPrinter/MesZebraBridge.Tests/SpoolerTests.cs`:

```csharp
// The winspool.drv shim. These touch the REAL local spooler but never a real
// printer: the failure paths use a queue name that cannot exist, and the
// enumeration is only checked for shape.

using System.Collections.Generic;
using System.Text;
using BlueRidge.MesZebraBridge;
using Xunit;

namespace BlueRidge.MesZebraBridge.Tests
{
    public class SpoolerTests
    {
        // Long enough that no host has it, and deliberately ASCII.
        private const string NoSuchQueue = "MesZebraBridge NoSuchQueue 8f3a1c47";

        [Fact]
        public void The_not_ready_mask_is_the_one_the_python_bridge_uses()
        {
            // PRINTER_STATUS_PAUSED | _ERROR | _OFFLINE | _NOT_AVAILABLE | _NO_TONER.
            // Reproduced exactly so ?STATUS agrees between the two implementations.
            Assert.Equal(0x00041083u, Spooler.NotReadyStatusMask);
        }

        [Fact]
        public void Reading_the_status_of_a_queue_that_does_not_exist_is_not_ready_and_never_throws()
        {
            QueueStatus s = Spooler.ReadQueueStatus(NoSuchQueue);
            Assert.Equal(NoSuchQueue, s.Queue);
            Assert.False(s.Ready);
            Assert.Equal(0, s.Jobs);
        }

        [Fact]
        public void Spooling_to_a_queue_that_does_not_exist_names_it_and_lists_what_is_visible()
        {
            // PROTOCOL.md's documented ERR shape, and spec 6.3's QueueRejected.
            var ex = Assert.Throws<SpoolException>(
                () => Spooler.SpoolRaw(NoSuchQueue, Encoding.ASCII.GetBytes("^XA^XZ")));

            Assert.StartsWith("queue not found: ", ex.Message);
            Assert.Contains(NoSuchQueue, ex.Message);
            Assert.Contains("; visible: ", ex.Message);
            Assert.DoesNotContain("\n", ex.Message);
        }

        [Fact]
        public void Enumerating_local_queues_returns_a_shaped_list_and_does_not_throw()
        {
            IList<PrinterEntry> queues = Spooler.EnumerateLocalQueues();
            Assert.NotNull(queues);
            foreach (PrinterEntry q in queues)
            {
                // A queue with no name would break both detection and the ACK.
                Assert.False(string.IsNullOrEmpty(q.Name));
            }
        }

        [Fact]
        public void A_printer_entry_carries_what_detection_needs_to_decide()
        {
            var e = new PrinterEntry("Zebra GX420d (RAW)", "ZDesigner GX420d", "USB002", 0x40u, 0u);
            Assert.Equal("Zebra GX420d (RAW)", e.Name);
            Assert.Equal("ZDesigner GX420d", e.Driver);
            Assert.Equal("USB002", e.Port);
            Assert.Equal(0x40u, e.Attributes);
            Assert.Equal(0u, e.Status);
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```powershell
dotnet test zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj
```

Expected: compile failure, `error CS0246: The type or namespace name 'Spooler' could not be found`, and the same for `PrinterEntry`.

- [ ] **Step 3: Write the P/Invoke declarations**

Create `zebraPrinter/MesZebraBridge/NativeMethods.cs`:

```csharp
// winspool.drv, declared to match zebraPrinter/usb_tcp_bridge.py's ctypes block
// argument for argument. The W entry points are named explicitly rather than left
// to CharSet auto-mapping, so there is no ambiguity about which one is bound.

using System;
using System.Runtime.InteropServices;

namespace BlueRidge.MesZebraBridge
{
    internal static class NativeMethods
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        internal struct DOCINFOW
        {
            [MarshalAs(UnmanagedType.LPWStr)] public string pDocName;
            [MarshalAs(UnmanagedType.LPWStr)] public string pOutputFile;
            [MarshalAs(UnmanagedType.LPWStr)] public string pDatatype;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        internal struct PRINTER_INFO_2
        {
            [MarshalAs(UnmanagedType.LPWStr)] public string pServerName;
            [MarshalAs(UnmanagedType.LPWStr)] public string pPrinterName;
            [MarshalAs(UnmanagedType.LPWStr)] public string pShareName;
            [MarshalAs(UnmanagedType.LPWStr)] public string pPortName;
            [MarshalAs(UnmanagedType.LPWStr)] public string pDriverName;
            [MarshalAs(UnmanagedType.LPWStr)] public string pComment;
            [MarshalAs(UnmanagedType.LPWStr)] public string pLocation;
            public IntPtr pDevMode;
            [MarshalAs(UnmanagedType.LPWStr)] public string pSepFile;
            [MarshalAs(UnmanagedType.LPWStr)] public string pPrintProcessor;
            [MarshalAs(UnmanagedType.LPWStr)] public string pDatatype;
            [MarshalAs(UnmanagedType.LPWStr)] public string pParameters;
            public IntPtr pSecurityDescriptor;
            public uint Attributes;
            public uint Priority;
            public uint DefaultPriority;
            public uint StartTime;
            public uint UntilTime;
            public uint Status;
            public uint cJobs;
            public uint AveragePPM;
        }

        internal const uint PRINTER_ENUM_LOCAL = 0x00000002;

        [DllImport("winspool.drv", EntryPoint = "OpenPrinterW", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern bool OpenPrinter(string pPrinterName, out IntPtr phPrinter, IntPtr pDefault);

        [DllImport("winspool.drv", EntryPoint = "ClosePrinter", SetLastError = true)]
        internal static extern bool ClosePrinter(IntPtr hPrinter);

        /// <summary>Returns the spooler JOB ID, or 0 on failure. Verified 2026-09-29.</summary>
        [DllImport("winspool.drv", EntryPoint = "StartDocPrinterW", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern int StartDocPrinter(IntPtr hPrinter, int level, ref DOCINFOW pDocInfo);

        [DllImport("winspool.drv", EntryPoint = "EndDocPrinter", SetLastError = true)]
        internal static extern bool EndDocPrinter(IntPtr hPrinter);

        [DllImport("winspool.drv", EntryPoint = "StartPagePrinter", SetLastError = true)]
        internal static extern bool StartPagePrinter(IntPtr hPrinter);

        [DllImport("winspool.drv", EntryPoint = "EndPagePrinter", SetLastError = true)]
        internal static extern bool EndPagePrinter(IntPtr hPrinter);

        [DllImport("winspool.drv", EntryPoint = "WritePrinter", SetLastError = true)]
        internal static extern bool WritePrinter(IntPtr hPrinter, byte[] pBytes, int dwCount, out int dwWritten);

        [DllImport("winspool.drv", EntryPoint = "GetPrinterW", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern bool GetPrinter(IntPtr hPrinter, int level, IntPtr pPrinter, int cbBuf, out int pcbNeeded);

        [DllImport("winspool.drv", EntryPoint = "EnumPrintersW", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern bool EnumPrinters(uint flags, string name, uint level,
            IntPtr pPrinterEnum, uint cbBuf, out uint pcbNeeded, out uint pcReturned);
    }
}
```

- [ ] **Step 4: Implement `Spooler`**

Create `zebraPrinter/MesZebraBridge/Spooler.cs`:

```csharp
// The Windows spooler, RAW datatype, so ZPL passes through untransformed.
// A transliteration of zebraPrinter/usb_tcp_bridge.py's send_raw and queue_status.
//
// StartDocPrinterW's return value IS the spooler job id: verified 2026-09-29 against
// the real ZDesigner GX420d driver, with Get-PrintJob independently reporting
// `Id 15, MES ZPL, 38 bytes` for the same exchange (PROTOCOL.md, "Verified").

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace BlueRidge.MesZebraBridge
{
    /// <summary>One local print queue, as EnumPrinters level 2 reports it.</summary>
    public struct PrinterEntry
    {
        public readonly string Name;
        public readonly string Driver;
        public readonly string Port;
        public readonly uint Attributes;
        public readonly uint Status;

        public PrinterEntry(string name, string driver, string port, uint attributes, uint status)
        {
            Name = name;
            Driver = driver;
            Port = port;
            Attributes = attributes;
            Status = status;
        }
    }

    public static class Spooler
    {
        /// <summary>
        /// PRINTER_STATUS_PAUSED | _ERROR | _OFFLINE | _NOT_AVAILABLE | _NO_TONER.
        /// The same mask usb_tcp_bridge.py uses, reproduced exactly so ?STATUS agrees
        /// between the two implementations. NO_TONER is meaningless on a thermal Zebra
        /// and is kept only for that parity.
        /// </summary>
        public const uint NotReadyStatusMask =
            0x00000001u | 0x00000002u | 0x00000080u | 0x00001000u | 0x00040000u;

        private const int ERROR_FILE_NOT_FOUND = 2;
        private const int ERROR_INVALID_NAME = 123;
        private const int ERROR_INVALID_PRINTER_NAME = 1801;

        /// <summary>Hand bytes to a Windows print queue as one RAW job.</summary>
        public static SpoolResult SpoolRaw(string queueName, byte[] data)
        {
            if (data == null) data = new byte[0];

            IntPtr h;
            if (!NativeMethods.OpenPrinter(queueName, out h, IntPtr.Zero))
                throw QueueOpenFailure(queueName, Marshal.GetLastWin32Error());
            try
            {
                var di = new NativeMethods.DOCINFOW
                {
                    pDocName = "MES ZPL",
                    pOutputFile = null,
                    pDatatype = "RAW"
                };

                int job = NativeMethods.StartDocPrinter(h, 1, ref di);
                if (job == 0) throw Win32Failure("StartDocPrinter", Marshal.GetLastWin32Error());
                try
                {
                    if (!NativeMethods.StartPagePrinter(h))
                        throw Win32Failure("StartPagePrinter", Marshal.GetLastWin32Error());

                    int written;
                    if (!NativeMethods.WritePrinter(h, data, data.Length, out written))
                        throw Win32Failure("WritePrinter", Marshal.GetLastWin32Error());

                    return new SpoolResult(job, written);
                }
                finally
                {
                    // Mirrors the Python finally: the job is closed out even on a
                    // partial write, so the spooler is never left holding an open doc.
                    NativeMethods.EndPagePrinter(h);
                    NativeMethods.EndDocPrinter(h);
                }
            }
            finally
            {
                NativeMethods.ClosePrinter(h);
            }
        }

        /// <summary>
        /// The queue's real state. ready = the queue opens and reports no
        /// error/offline/paused bit; jobs = its current job count. Never throws --
        /// an unopenable queue is a not-ready answer, which is the honest one, and
        /// is what PROTOCOL.md requires for a queue name that is not on the host.
        /// </summary>
        public static QueueStatus ReadQueueStatus(string queueName)
        {
            IntPtr h;
            if (!NativeMethods.OpenPrinter(queueName, out h, IntPtr.Zero))
                return new QueueStatus(queueName, false, 0);
            try
            {
                int needed;
                NativeMethods.GetPrinter(h, 2, IntPtr.Zero, 0, out needed);
                if (needed <= 0) return new QueueStatus(queueName, false, 0);

                IntPtr buf = Marshal.AllocHGlobal(needed);
                try
                {
                    int unused;
                    if (!NativeMethods.GetPrinter(h, 2, buf, needed, out unused))
                        return new QueueStatus(queueName, false, 0);

                    var info = (NativeMethods.PRINTER_INFO_2)Marshal.PtrToStructure(
                        buf, typeof(NativeMethods.PRINTER_INFO_2));

                    return new QueueStatus(queueName,
                        (info.Status & NotReadyStatusMask) == 0, (int)info.cJobs);
                }
                finally
                {
                    Marshal.FreeHGlobal(buf);
                }
            }
            catch (Exception)
            {
                return new QueueStatus(queueName, false, 0);
            }
            finally
            {
                NativeMethods.ClosePrinter(h);
            }
        }

        /// <summary>
        /// Every local print queue with its driver, port and status.
        ///
        /// PRINTER_ENUM_LOCAL only, deliberately without PRINTER_ENUM_CONNECTIONS:
        /// a USB Zebra is a local queue, per-user printer connections are not visible
        /// to LocalSystem anyway, and including them would only widen the candidate
        /// list that Task 7's detection has to disambiguate.
        /// </summary>
        public static IList<PrinterEntry> EnumerateLocalQueues()
        {
            var list = new List<PrinterEntry>();

            uint needed, returned;
            NativeMethods.EnumPrinters(NativeMethods.PRINTER_ENUM_LOCAL, null, 2,
                IntPtr.Zero, 0, out needed, out returned);
            if (needed == 0) return list;

            IntPtr buf = Marshal.AllocHGlobal((int)needed);
            try
            {
                uint needed2;
                if (!NativeMethods.EnumPrinters(NativeMethods.PRINTER_ENUM_LOCAL, null, 2,
                        buf, needed, out needed2, out returned))
                    throw Win32Failure("EnumPrinters", Marshal.GetLastWin32Error());

                int stride = Marshal.SizeOf(typeof(NativeMethods.PRINTER_INFO_2));
                for (int i = 0; i < returned; i++)
                {
                    var info = (NativeMethods.PRINTER_INFO_2)Marshal.PtrToStructure(
                        new IntPtr(buf.ToInt64() + (long)i * stride),
                        typeof(NativeMethods.PRINTER_INFO_2));

                    list.Add(new PrinterEntry(info.pPrinterName, info.pDriverName,
                        info.pPortName, info.Attributes, info.Status));
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buf);
            }

            return list;
        }

        /// <summary>
        /// The documented ERR shape for a queue that is not on this host
        /// (PROTOCOL.md, Print): names what was tried and lists what is visible,
        /// which is what makes spec 6.3's QueueRejected actionable at the machine.
        /// </summary>
        private static SpoolException QueueOpenFailure(string queueName, int err)
        {
            if (err == ERROR_INVALID_PRINTER_NAME || err == ERROR_INVALID_NAME || err == ERROR_FILE_NOT_FOUND)
            {
                var visible = new List<string>();
                try
                {
                    foreach (PrinterEntry q in EnumerateLocalQueues()) visible.Add(q.Name);
                }
                catch (Exception)
                {
                    // Naming what we tried is worth more than naming nothing.
                }

                return new SpoolException(string.Format("queue not found: {0}; visible: {1}",
                    Protocol.Quote(queueName),
                    visible.Count == 0 ? "(none)" : string.Join(", ", visible.ToArray())));
            }

            return new SpoolException(string.Format("OpenPrinter {0} failed: [{1}] {2}",
                Protocol.Quote(queueName), err,
                Protocol.OneLine(new Win32Exception(err).Message)));
        }

        private static SpoolException Win32Failure(string call, int err)
        {
            return new SpoolException(string.Format("{0} failed: [{1}] {2}",
                call, err, Protocol.OneLine(new Win32Exception(err).Message)));
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```powershell
dotnet test zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj
```

Expected: `Failed: 0, Passed: 25`.

If `Spooling_to_a_queue_that_does_not_exist...` fails because `OpenPrinter` set a different error code, print the code and add it to the three constants rather than loosening the assertion -- the point of the test is the documented ERR shape.

- [ ] **Step 6: Commit**

```bash
git add zebraPrinter/MesZebraBridge/NativeMethods.cs zebraPrinter/MesZebraBridge/Spooler.cs zebraPrinter/MesZebraBridge.Tests/SpoolerTests.cs
git commit -m "feat(bridge): spool RAW through winspool and return the real job id"
```

---

### Task 7: Install-time queue detection

**This code never runs at runtime** (Global Constraint 5). It exists so `install` and `detect` can offer the commissioner a name to confirm, and so that when it cannot offer one it says exactly what it saw. The runtime path reads `Queue=` from the conf and does nothing else.

The rule is deliberately strict: **Zebra/ZDesigner driver, on a live port, exactly one, or nothing.** The real host that killed the earlier heuristic is the headline test:

| Queue | Driver | Port | |
|---|---|---|---|
| `ZDesigner GX420d (Copy 1)` | ZDesigner GX420d | `USB001` | live |
| `ZDesigner GX420d` | ZDesigner GX420d | `LPT1:` | stale |
| `Zebra GX420d (RAW)` | ZDesigner GX420d | `USB001` | live -- the one in use |

Dead-port filtering removes one row and leaves **two live candidates on the same port**. No status bit separates them, so `Select` returns **unresolved** and names all three. That is the correct answer, and getting it is the whole point of this task.

There is **no status tie-breaker**. An earlier revision had one; with the human confirming the name anyway it only adds a way to pick wrong quietly.

`IsLivePort` survives for two reasons: on a single-Zebra machine it stops a stale `LPT1:` queue making the answer ambiguous, and in the `detect` listing it is what labels that row `DEAD-PORT` for the person reading it.

**Files:**
- Create: `zebraPrinter/MesZebraBridge/QueueResolver.cs`
- Create: `zebraPrinter/MesZebraBridge.Tests/QueueResolverTests.cs`

**Interfaces:**
- Consumes: `PrinterEntry` from Task 6, `Protocol.Quote` / `.Cap` / `.OneLine`
- Produces (all **install-time only**):
  - `sealed class QueueResolution { string Queue; string Diagnosis; bool Resolved; }`
  - `QueueResolver.Select(IEnumerable<PrinterEntry>) -> QueueResolution`
  - `QueueResolver.IsZebraDriver(string) -> bool`
  - `QueueResolver.IsLivePort(string) -> bool`

- [ ] **Step 1: Write the failing tests**

Create `zebraPrinter/MesZebraBridge.Tests/QueueResolverTests.cs`:

```csharp
// INSTALL-TIME queue detection. Nothing here is on the runtime path: the service
// reads Queue= from its conf file and does not enumerate anything.
//
// Detection exists so `install` can offer the commissioner a name to confirm
// against the Get-Printer they just ran (spec section 7 step 1), and so that when
// it cannot offer one it says exactly what it saw.
//
// The headline case is the REAL observed host: three candidates, one stale on
// LPT1: and TWO LIVE ONES ON USB001. It must come back UNRESOLVED. An earlier
// revision of this plan picked one of those two with a heuristic; the wrong side
// of that coin flip is a terminal spooling to a queue nobody watches.

using System.Collections.Generic;
using BlueRidge.MesZebraBridge;
using Xunit;

namespace BlueRidge.MesZebraBridge.Tests
{
    public class QueueResolverTests
    {
        private static PrinterEntry Q(string name, string driver, string port)
        {
            return new PrinterEntry(name, driver, port, 0, 0);
        }

        private static readonly PrinterEntry[] NonZebraNoise =
        {
            Q("Microsoft Print to PDF", "Microsoft Print To PDF", "PORTPROMPT:"),
            Q("Microsoft XPS Document Writer", "Microsoft XPS Document Writer", "PORTPROMPT:"),
            Q("Fax", "Microsoft Shared Fax Driver", "SHRFAX:"),
            Q("OneNote (Desktop)", "Send To Microsoft OneNote 16 Driver", "nul:")
        };

        private static List<PrinterEntry> WithNoise(params PrinterEntry[] zebras)
        {
            var all = new List<PrinterEntry>(NonZebraNoise);
            all.AddRange(zebras);
            return all;
        }

        [Fact]
        public void The_real_observed_host_is_UNRESOLVED_because_two_live_queues_share_a_port()
        {
            // THE case this task exists for. Two live candidates on USB001 plus one
            // stale on LPT1:. Dead-port filtering leaves two, nothing separates them,
            // so install must stop and ask rather than pick.
            QueueResolution r = QueueResolver.Select(WithNoise(
                Q("ZDesigner GX420d (Copy 1)", "ZDesigner GX420d", "USB001"),
                Q("ZDesigner GX420d", "ZDesigner GX420d", "LPT1:"),
                Q("Zebra GX420d (RAW)", "ZDesigner GX420d", "USB001")));

            Assert.False(r.Resolved);
            Assert.Null(r.Queue);

            // Every candidate named, with its port, so the commissioner can pick.
            Assert.Contains("ZDesigner GX420d (Copy 1)", r.Diagnosis);
            Assert.Contains("Zebra GX420d (RAW)", r.Diagnosis);
            Assert.Contains("USB001", r.Diagnosis);
            Assert.Contains("LPT1:", r.Diagnosis);
            Assert.Contains("dead-port", r.Diagnosis);
            Assert.Contains("--queue", r.Diagnosis);   // tells them what to do about it
            Assert.DoesNotContain("\n", r.Diagnosis);
        }

        [Fact]
        public void A_zebra_driver_is_recognised_by_either_vendor_spelling()
        {
            Assert.True(QueueResolver.IsZebraDriver("ZDesigner GX420d"));
            Assert.True(QueueResolver.IsZebraDriver("Zebra GX420d"));
            Assert.True(QueueResolver.IsZebraDriver("zdesigner zt411-203dpi ZPL"));
            Assert.False(QueueResolver.IsZebraDriver("Microsoft Print To PDF"));
            Assert.False(QueueResolver.IsZebraDriver(""));
            Assert.False(QueueResolver.IsZebraDriver(null));
        }

        [Fact]
        public void A_legacy_hardware_port_is_dead_and_a_usb_port_is_live()
        {
            // LPT1: is the exact stale binding on the observed host.
            Assert.False(QueueResolver.IsLivePort("LPT1:"));
            Assert.False(QueueResolver.IsLivePort("COM3:"));
            Assert.False(QueueResolver.IsLivePort("PORTPROMPT:"));
            Assert.False(QueueResolver.IsLivePort("FILE:"));
            Assert.False(QueueResolver.IsLivePort("nul:"));
            Assert.False(QueueResolver.IsLivePort(""));
            Assert.False(QueueResolver.IsLivePort(null));

            Assert.True(QueueResolver.IsLivePort("USB001"));
            Assert.True(QueueResolver.IsLivePort("USB002"));
            Assert.True(QueueResolver.IsLivePort("DOT4_001"));
            Assert.True(QueueResolver.IsLivePort("IP_10.20.11.157"));
            Assert.True(QueueResolver.IsLivePort(@"\\host\ZebraShare"));
        }

        [Fact]
        public void One_live_zebra_resolves_and_the_diagnosis_names_the_queue_and_its_port()
        {
            // install prints this line, and spec section 7 step 4 wants it checked
            // against the Get-Printer from step 1 -- so the port and driver are in it.
            QueueResolution r = QueueResolver.Select(
                WithNoise(Q("Zebra GX420d (RAW)", "ZDesigner GX420d", "USB002")));

            Assert.True(r.Resolved);
            Assert.Equal("Zebra GX420d (RAW)", r.Queue);
            Assert.Contains("USB002", r.Diagnosis);
            Assert.Contains("ZDesigner GX420d", r.Diagnosis);
            Assert.DoesNotContain("\n", r.Diagnosis);
        }

        [Fact]
        public void One_live_zebra_beside_a_stale_one_on_a_dead_port_still_resolves()
        {
            // The case dead-port filtering DOES settle, and the only reason
            // IsLivePort is still here rather than deleted.
            QueueResolution r = QueueResolver.Select(WithNoise(
                Q("Zebra GX420d (RAW)", "ZDesigner GX420d", "USB002"),
                Q("ZDesigner GX420d", "ZDesigner GX420d", "LPT1:")));

            Assert.True(r.Resolved);
            Assert.Equal("Zebra GX420d (RAW)", r.Queue);
        }

        [Fact]
        public void Two_live_zebras_on_different_ports_are_also_unresolved()
        {
            // Two printers on one PC is out of scope (spec 11.1) -- but guessing
            // between them is worse than saying so.
            QueueResolution r = QueueResolver.Select(WithNoise(
                Q("Zebra One", "ZDesigner GX420d", "USB002"),
                Q("Zebra Two", "ZDesigner GX420d", "USB003")));

            Assert.False(r.Resolved);
            Assert.Contains("Zebra One", r.Diagnosis);
            Assert.Contains("Zebra Two", r.Diagnosis);
        }

        [Fact]
        public void An_offline_status_bit_never_decides_anything()
        {
            // No tie-breaker: an earlier revision used printer status to separate
            // two live candidates. It cannot separate the observed host's pair, and
            // a rule that only sometimes applies is a rule that surprises people.
            const uint workOffline = 0x00000400;
            const uint statusOffline = 0x00000080;

            QueueResolution ambiguous = QueueResolver.Select(WithNoise(
                new PrinterEntry("Zebra Stale", "ZDesigner GX420d", "USB001", workOffline, 0),
                new PrinterEntry("Zebra Real", "ZDesigner GX420d", "USB001", 0, 0)));
            Assert.False(ambiguous.Resolved);

            // And the converse: a lone Zebra that is merely switched off still resolves.
            QueueResolution lone = QueueResolver.Select(WithNoise(
                new PrinterEntry("Zebra GX420d (RAW)", "ZDesigner GX420d", "USB002", 0, statusOffline)));
            Assert.True(lone.Resolved);
            Assert.Equal("Zebra GX420d (RAW)", lone.Queue);
        }

        [Fact]
        public void No_zebra_at_all_is_unresolved_and_says_how_many_queues_it_looked_at()
        {
            QueueResolution r = QueueResolver.Select(WithNoise());

            Assert.False(r.Resolved);
            Assert.Null(r.Queue);
            Assert.Contains("no Zebra", r.Diagnosis);
            Assert.Contains("4 local queue", r.Diagnosis);
        }

        [Fact]
        public void A_zebra_only_on_a_dead_port_is_refused_and_named()
        {
            // "the queue exists but is bound to LPT1:" is a different fix from
            // "no driver is installed", so the two must not read the same.
            QueueResolution r = QueueResolver.Select(
                WithNoise(Q("ZDesigner GX420d", "ZDesigner GX420d", "LPT1:")));

            Assert.False(r.Resolved);
            Assert.Contains("ZDesigner GX420d", r.Diagnosis);
            Assert.Contains("LPT1:", r.Diagnosis);
            Assert.Contains("dead-port", r.Diagnosis);
        }

        [Fact]
        public void An_empty_or_null_enumeration_is_unresolved_and_does_not_throw()
        {
            QueueResolution empty = QueueResolver.Select(new PrinterEntry[0]);
            Assert.False(empty.Resolved);
            Assert.Contains("0 local queue", empty.Diagnosis);

            QueueResolution nothing = QueueResolver.Select(null);
            Assert.False(nothing.Resolved);
            Assert.NotNull(nothing.Diagnosis);
        }

        [Fact]
        public void The_diagnosis_is_always_one_capped_line()
        {
            var many = new List<PrinterEntry>();
            for (int i = 0; i < 60; i++)
                many.Add(Q("Zebra With A Fairly Long Name Number " + i, "ZDesigner GX420d", "USB" + i));

            QueueResolution r = QueueResolver.Select(many);

            Assert.False(r.Resolved);
            Assert.DoesNotContain("\n", r.Diagnosis);
            Assert.True(r.Diagnosis.Length <= Protocol.MaxResponseBytes);
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```powershell
dotnet test zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj
```

Expected: compile failure, `error CS0246: The type or namespace name 'QueueResolver' could not be found`, and the same for `QueueResolution`.

- [ ] **Step 3: Implement `QueueResolver`**

Create `zebraPrinter/MesZebraBridge/QueueResolver.cs`:

```csharp
// INSTALL-TIME queue detection. NOT on the runtime path -- the service reads
// Queue= from its conf file and enumerates nothing (Global Constraint 5).
//
// This exists so `install` can offer the commissioner a name to confirm against
// the Get-Printer they ran in spec section 7 step 1, and so that when it cannot
// offer one it names everything it saw and asks for --queue.
//
// The rule is Zebra/ZDesigner driver + live port + EXACTLY ONE, or nothing.
//
// Why "exactly one, or nothing" and not a cleverer rule: one real printer host
// carried `ZDesigner GX420d (Copy 1)` on USB001, `ZDesigner GX420d` on LPT1:
// (stale), and `Zebra GX420d (RAW)` on USB001 (the one actually in use). Dead-port
// filtering removes the LPT1: row and leaves TWO LIVE CANDIDATES ON THE SAME PORT.
// No status bit separates those, so there is no rule that picks correctly -- only
// rules that pick quietly. The wrong side of that coin flip is a terminal spooling
// to a queue nobody watches.
//
// IsLivePort is kept because it settles the single-Zebra-plus-stale-LPT1: case,
// and because the `detect` listing uses it to label that row for a human.

using System;
using System.Collections.Generic;

namespace BlueRidge.MesZebraBridge
{
    public sealed class QueueResolution
    {
        /// <summary>The detected queue name, or null when detection would have to guess.</summary>
        public string Queue { get; internal set; }

        /// <summary>Always populated, always one line: what was found and what was chosen.</summary>
        public string Diagnosis { get; internal set; }

        public bool Resolved { get { return Queue != null; } }
    }

    public static class QueueResolver
    {
        /// <summary>
        /// Ports a queue can be bound to while having no hardware behind it. Matched
        /// as a case-insensitive prefix, because a port name may or may not carry its
        /// trailing colon depending on how the queue was created.
        /// </summary>
        private static readonly string[] DeadPortPrefixes =
        {
            "LPT", "COM", "FILE:", "PORTPROMPT:", "NUL", "XPSPORT:", "SHRFAX:",
            "MICROSOFT.OFFICE.", "ONENOTE"
        };

        public static bool IsZebraDriver(string driver)
        {
            if (string.IsNullOrEmpty(driver)) return false;
            return driver.IndexOf("ZDesigner", StringComparison.OrdinalIgnoreCase) >= 0
                || driver.IndexOf("Zebra", StringComparison.OrdinalIgnoreCase) >= 0;
        }

        public static bool IsLivePort(string port)
        {
            if (string.IsNullOrEmpty(port)) return false;
            foreach (string dead in DeadPortPrefixes)
                if (port.StartsWith(dead, StringComparison.OrdinalIgnoreCase)) return false;
            return true;
        }

        public static QueueResolution Select(IEnumerable<PrinterEntry> queues)
        {
            var all = new List<PrinterEntry>(queues ?? new PrinterEntry[0]);
            var zebra = new List<PrinterEntry>();
            var live = new List<PrinterEntry>();

            foreach (PrinterEntry q in all)
            {
                if (!IsZebraDriver(q.Driver)) continue;
                zebra.Add(q);
                if (IsLivePort(q.Port)) live.Add(q);
            }

            // Exactly one, or nothing. No tie-breaker.
            if (live.Count == 1)
            {
                string line = string.Format(
                    "{0} on port {1} (driver {2}); {3} Zebra candidate(s) among {4} local queue(s)",
                    Protocol.Quote(live[0].Name), live[0].Port, Protocol.Quote(live[0].Driver),
                    zebra.Count, all.Count);
                return new QueueResolution
                {
                    Queue = live[0].Name,
                    Diagnosis = Protocol.Cap(Protocol.OneLine(line))
                };
            }

            return new QueueResolution { Queue = null, Diagnosis = Describe(all, zebra, live) };
        }

        private static string Describe(List<PrinterEntry> all, List<PrinterEntry> zebra, List<PrinterEntry> live)
        {
            if (zebra.Count == 0)
                return Protocol.Cap(Protocol.OneLine(string.Format(
                    "no Zebra/ZDesigner driver among {0} local queue(s): {1}. "
                    + "Install the driver, or name the queue with --queue \"<name>\".",
                    all.Count, JoinNames(all))));

            var parts = new List<string>();
            foreach (PrinterEntry q in zebra)
                parts.Add(string.Format("{0} port={1} {2}",
                    Protocol.Quote(q.Name),
                    string.IsNullOrEmpty(q.Port) ? "(none)" : q.Port,
                    IsLivePort(q.Port) ? "live-port" : "dead-port"));

            return Protocol.Cap(Protocol.OneLine(string.Format(
                "cannot choose between {0} Zebra candidate(s), {1} on a live port -- {2}. "
                + "Name the one you want with --queue \"<name>\".",
                zebra.Count, live.Count, string.Join(", ", parts.ToArray()))));
        }

        private static string JoinNames(List<PrinterEntry> queues)
        {
            if (queues.Count == 0) return "(none)";
            var names = new List<string>();
            foreach (PrinterEntry q in queues) names.Add(Protocol.Quote(q.Name));
            return string.Join(", ", names.ToArray());
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```powershell
dotnet test zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj
```

Expected: `Failed: 0, Passed: 36`.

- [ ] **Step 5: Commit**

```bash
git add zebraPrinter/MesZebraBridge/QueueResolver.cs zebraPrinter/MesZebraBridge.Tests/QueueResolverTests.cs
git commit -m "feat(bridge): detection offers a queue name to confirm, or names every candidate and asks"
```

---

### Task 8: The request router, and the unconfigured-queue answer

The runtime queue binding, which after Global Constraint 5 is almost nothing: the conf'd name, or null. No enumeration, no heuristic, no retry, no latch -- `QueueResolver` from Task 7 is install-time only and is not referenced from here.

What is left is still load-bearing, in two parts:

- **`Router.Route`'s ordering.** The silence check runs **before** the queue check. `validateEndpoint` connects and closes without sending, and that bare-connect probe must get zero bytes back whatever state the bridge is in -- including on a terminal whose conf has no queue yet. Getting this backwards breaks reachability testing on every un-commissioned terminal, and it is the single most valuable test in this task.
- **`ERR queue unconfigured`.** If the conf carries no `Queue=`, the bridge still listens and says so. A service that refuses to start presents to the Gateway as `Connection refused`, which spec § 6.3 maps to *"host is up, nothing listening -- bridge is down"* -- the wrong machine to go and look at.

A `Queue=` naming a queue that is **not on the host** needs nothing here: Task 6's spooler already answers `ERR queue not found: 'X'; visible: ...`, and `?STATUS` already answers `ready=false` while naming it, which is what `PROTOCOL.md` requires and what catches a mistyped conf.

> **Smallest task in the plan, and deliberately still its own task.** An earlier revision had `QueueBinding` doing runtime detection with latching and retry; all of that is gone. The Router ordering contract is what justifies the remaining boundary, and folding it into Task 11 would bury the one test nobody should delete.

**Files:**
- Create: `zebraPrinter/MesZebraBridge/QueueBinding.cs`
- Create: `zebraPrinter/MesZebraBridge/Router.cs`
- Create: `zebraPrinter/MesZebraBridge.Tests/RouterTests.cs`

**Interfaces:**
- Consumes: `Protocol.HandleRequest`, `Protocol.Cap` / `.OneLine`
- Produces:
  - `sealed class QueueBinding(string configuredQueue)`
  - `QueueBinding.Queue -> string` (null when the conf named none)
  - `QueueBinding.IsConfigured -> bool`, `.Diagnosis -> string`
  - `Router.Route(byte[] data, QueueBinding binding, Func<string, byte[], SpoolResult> spool, Func<string, QueueStatus> status) -> string`

- [ ] **Step 1: Write the failing tests**

Create `zebraPrinter/MesZebraBridge.Tests/RouterTests.cs`:

```csharp
// One request -> one response line, with the conf'd queue in between.
//
// Two things are pinned here. First, the ORDER: silence before the queue check,
// because validateEndpoint's bare connect must get zero bytes on a terminal that
// is not commissioned yet. Second, that a missing Queue= still listens and says
// so -- spec 6.3 reads `Connection refused` as "bridge is down", which would send
// somebody to the wrong machine.
//
// There is no detection here. QueueResolver is install-time only.

using System;
using System.Text;
using BlueRidge.MesZebraBridge;
using Xunit;

namespace BlueRidge.MesZebraBridge.Tests
{
    public class RouterTests
    {
        private static SpoolResult SpoolOk(string queue, byte[] data)
        {
            return new SpoolResult(41, data.Length);
        }

        private static QueueStatus StatusOk(string queue)
        {
            return new QueueStatus(queue, true, 0);
        }

        [Fact]
        public void The_configured_queue_is_used_verbatim_with_no_detection()
        {
            var binding = new QueueBinding("Zebra GX420d (RAW)");

            string queueSeen = null;
            string reply = Router.Route(Encoding.ASCII.GetBytes("^XA^XZ"), binding,
                (q, d) => { queueSeen = q; return new SpoolResult(41, d.Length); }, StatusOk);

            Assert.Equal("Zebra GX420d (RAW)", queueSeen);
            Assert.Equal("OK queue='Zebra GX420d (RAW)' job=41 bytes=6", reply);
        }

        [Fact]
        public void A_name_that_is_not_on_this_host_is_passed_through_so_the_spooler_can_name_it()
        {
            // PROTOCOL.md requires the wrong-queue-name mistake to be caught by the
            // spooler's own ERR, not pre-empted here -- that ERR is the one that
            // lists what IS visible, which is the useful half.
            var binding = new QueueBinding("Typo GX420d");

            string reply = Router.Route(Encoding.ASCII.GetBytes("^XA^XZ"), binding,
                (q, d) => { throw new SpoolException("queue not found: 'Typo GX420d'; visible: A, B"); },
                StatusOk);

            Assert.Equal("ERR queue not found: 'Typo GX420d'; visible: A, B", reply);
        }

        [Fact]
        public void An_unconfigured_queue_refuses_the_print_and_says_what_to_do()
        {
            var binding = new QueueBinding(null);

            string reply = Router.Route(Encoding.ASCII.GetBytes("^XA^XZ"), binding, SpoolOk, StatusOk);

            Assert.StartsWith("ERR queue unconfigured: ", reply);
            Assert.Contains("install", reply);       // the fix, named on the wire
            Assert.DoesNotContain("\n", reply);
        }

        [Fact]
        public void An_unconfigured_queue_also_refuses_STATUS_rather_than_inventing_a_queue()
        {
            var binding = new QueueBinding("");

            string reply = Router.Route(Encoding.ASCII.GetBytes("?STATUS"), binding, SpoolOk, StatusOk);

            Assert.StartsWith("ERR queue unconfigured: ", reply);
        }

        [Fact]
        public void An_unconfigured_queue_never_reaches_the_spooler()
        {
            var binding = new QueueBinding(null);

            Router.Route(Encoding.ASCII.GetBytes("^XA^XZ"), binding,
                (q, d) => { throw new InvalidOperationException("must not spool without a queue"); },
                StatusOk);
        }

        [Fact]
        public void An_empty_request_is_silent_even_when_the_queue_is_unconfigured()
        {
            // ORDERING MATTERS, AND THIS IS THE TEST THAT SAYS SO. validateEndpoint's
            // bare-connect probe must get zero bytes whatever state the bridge is in,
            // so the silence check runs before the queue check. Backwards, this breaks
            // reachability testing on every un-commissioned terminal.
            var binding = new QueueBinding(null);

            Assert.Null(Router.Route(new byte[0], binding, SpoolOk, StatusOk));
            Assert.Null(Router.Route(null, binding, SpoolOk, StatusOk));
        }

        [Fact]
        public void An_empty_request_is_silent_when_the_queue_is_configured_too()
        {
            var binding = new QueueBinding("Zebra GX420d (RAW)");

            Assert.Null(Router.Route(new byte[0], binding, SpoolOk, StatusOk));
        }

        [Fact]
        public void A_binding_reports_whether_it_is_configured_and_why_for_the_startup_log()
        {
            var bound = new QueueBinding("Zebra GX420d (RAW)");
            Assert.True(bound.IsConfigured);
            Assert.Equal("Zebra GX420d (RAW)", bound.Queue);
            Assert.Contains("Zebra GX420d (RAW)", bound.Diagnosis);

            var unbound = new QueueBinding(null);
            Assert.False(unbound.IsConfigured);
            Assert.Null(unbound.Queue);
            Assert.Contains("no Queue=", unbound.Diagnosis);
        }

        [Fact]
        public void A_blank_or_whitespace_queue_value_counts_as_unconfigured()
        {
            // A conf line left as `Queue=` must not become a queue named "".
            Assert.False(new QueueBinding("").IsConfigured);
            Assert.False(new QueueBinding("   ").IsConfigured);
            Assert.Null(new QueueBinding("  ").Queue);
        }

        [Fact]
        public void A_configured_name_is_trimmed_because_a_conf_file_is_hand_edited()
        {
            Assert.Equal("Zebra GX420d (RAW)", new QueueBinding("  Zebra GX420d (RAW)  ").Queue);
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```powershell
dotnet test zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj
```

Expected: compile failure, `error CS0246: The type or namespace name 'QueueBinding' could not be found`, and the same for `Router`.

- [ ] **Step 3: Implement `QueueBinding`**

Create `zebraPrinter/MesZebraBridge/QueueBinding.cs`:

```csharp
// Which queue this bridge is bound to. It is whatever the conf file said, and
// nothing else (Global Constraint 5): no enumeration, no heuristic, no retry.
//
// Detection lives in QueueResolver and runs only during `install` / `detect`,
// where a human is standing at the machine to confirm the name. Nothing on this
// path can guess.
//
// A name that is not actually on the host is NOT rejected here. PROTOCOL.md
// requires ?STATUS to answer ready=false while naming what it tried, and a print
// to answer `ERR queue not found: 'X'; visible: ...` -- the spooler's error is the
// one that lists what IS present, which is the half that helps.

using System;

namespace BlueRidge.MesZebraBridge
{
    public sealed class QueueBinding
    {
        /// <summary>The conf'd queue name, trimmed, or null when the conf named none.</summary>
        public string Queue { get; private set; }

        public bool IsConfigured { get { return Queue != null; } }

        /// <summary>One line for the startup log, the `status` verb, and the wire.</summary>
        public string Diagnosis { get; private set; }

        public QueueBinding(string configuredQueue)
        {
            string name = (configuredQueue ?? "").Trim();

            if (name.Length == 0)
            {
                Queue = null;
                Diagnosis = Protocol.Cap(
                    "no Queue= in the configuration. Nothing will print. Run "
                    + "'MesZebraBridge.exe install' at this machine (it detects the queue and "
                    + "writes it), or 'MesZebraBridge.exe set-queue \"<exact queue name>\"'.");
            }
            else
            {
                Queue = name;
                Diagnosis = Protocol.Cap("queue " + Protocol.Quote(name) + " from the configuration");
            }
        }
    }
}
```

- [ ] **Step 4: Implement `Router`**

Create `zebraPrinter/MesZebraBridge/Router.cs`:

```csharp
// One request -> one response line, with the conf'd queue in between.
//
// The silence check comes FIRST and is not negotiable: validateEndpoint connects
// and closes without sending, and that bare-connect probe must get zero bytes back
// whatever state the bridge is in -- including on a terminal that has no Queue= yet.

using System;

namespace BlueRidge.MesZebraBridge
{
    public static class Router
    {
        public static string Route(byte[] data, QueueBinding binding,
                                   Func<string, byte[], SpoolResult> spool,
                                   Func<string, QueueStatus> status)
        {
            if (data == null || data.Length == 0) return null;

            if (!binding.IsConfigured)
                return Protocol.Cap("ERR queue unconfigured: " + Protocol.OneLine(binding.Diagnosis));

            string queue = binding.Queue;
            return Protocol.HandleRequest(data, queue,
                d => spool(queue, d),
                () => status(queue));
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```powershell
dotnet test zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj
```

Expected: `Failed: 0, Passed: 46`.

- [ ] **Step 6: Commit**

```bash
git add zebraPrinter/MesZebraBridge/QueueBinding.cs zebraPrinter/MesZebraBridge/Router.cs zebraPrinter/MesZebraBridge.Tests/RouterTests.cs
git commit -m "feat(bridge): the queue comes from the conf, and a missing one answers instead of going dark"
```

---

### Task 9: The rolling log

Spec § 3: *"A rolling local log file. On 2026-09-29 the bridge's output existed only because it happened to be redirected."* And spec § 1: diagnosing one label required *"a human reading a console window on a machine in the plant"* -- a service has no console, so the file is the only record at the machine.

Timestamps are **local time with offset** (Global Constraint 11): CLAUDE.md's UTC-store/ET-display rule governs the database, and this file is read by a person standing at the terminal.

**Files:**
- Create: `zebraPrinter/MesZebraBridge/RollingLog.cs`
- Create: `zebraPrinter/MesZebraBridge.Tests/RollingLogTests.cs`

**Interfaces:**
- Consumes: `Protocol.OneLine`
- Produces:
  - `sealed class RollingLog(string directory, int retainDays, bool echoToConsole)`
  - `RollingLog.Write(string level, string message)` -- never throws
  - `RollingLog.Info(string) / .Error(string)`
  - `RollingLog.CurrentPath -> string`

- [ ] **Step 1: Write the failing tests**

Create `zebraPrinter/MesZebraBridge.Tests/RollingLogTests.cs`:

```csharp
// The local log file. A service has no console, so this file is the only record at
// the machine -- spec section 3 calls it out because on 2026-09-29 the bridge's
// output survived only because someone happened to redirect it.
//
// Every test writes into its own temp directory and deletes it afterwards.

using System;
using System.IO;
using System.Text.RegularExpressions;
using BlueRidge.MesZebraBridge;
using Xunit;

namespace BlueRidge.MesZebraBridge.Tests
{
    public class RollingLogTests : IDisposable
    {
        private readonly string _dir;

        public RollingLogTests()
        {
            _dir = Path.Combine(Path.GetTempPath(), "MesZebraBridgeTests_" + Guid.NewGuid().ToString("N"));
        }

        public void Dispose()
        {
            try { if (Directory.Exists(_dir)) Directory.Delete(_dir, true); }
            catch (Exception) { }
        }

        [Fact]
        public void A_line_carries_a_local_timestamp_with_offset_a_level_and_the_message()
        {
            var log = new RollingLog(_dir, 14, false);

            log.Info("bound 'Zebra GX420d (RAW)' on port USB002");

            string text = File.ReadAllText(log.CurrentPath);
            Assert.Matches(
                @"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} [+-]\d{2}:\d{2} INFO bound 'Zebra GX420d \(RAW\)' on port USB002",
                text);
        }

        [Fact]
        public void The_file_name_carries_the_date_so_it_rolls_daily()
        {
            var log = new RollingLog(_dir, 14, false);
            log.Info("hello");

            string name = Path.GetFileName(log.CurrentPath);
            Assert.Matches(@"^bridge-\d{8}\.log$", name);
            Assert.Contains(DateTime.Now.ToString("yyyyMMdd"), name);
        }

        [Fact]
        public void The_directory_is_created_on_first_write()
        {
            Assert.False(Directory.Exists(_dir));
            var log = new RollingLog(_dir, 14, false);
            log.Info("hello");
            Assert.True(Directory.Exists(_dir));
        }

        [Fact]
        public void A_multi_line_message_becomes_one_line_so_the_log_stays_greppable()
        {
            var log = new RollingLog(_dir, 14, false);

            log.Error("queue not found: 'X'\nvisible:\n  A\n  B");

            string[] lines = File.ReadAllLines(log.CurrentPath);
            Assert.Single(lines);
            Assert.Contains("visible: A B", lines[0]);
        }

        [Fact]
        public void Writes_append_rather_than_truncate()
        {
            var log = new RollingLog(_dir, 14, false);
            log.Info("first");
            log.Info("second");

            string[] lines = File.ReadAllLines(log.CurrentPath);
            Assert.Equal(2, lines.Length);
            Assert.EndsWith("first", lines[0]);
            Assert.EndsWith("second", lines[1]);
        }

        [Fact]
        public void A_log_older_than_the_retention_window_is_pruned_on_the_first_write()
        {
            Directory.CreateDirectory(_dir);
            string stale = Path.Combine(_dir,
                "bridge-" + DateTime.Now.AddDays(-40).ToString("yyyyMMdd") + ".log");
            string recent = Path.Combine(_dir,
                "bridge-" + DateTime.Now.AddDays(-2).ToString("yyyyMMdd") + ".log");
            File.WriteAllText(stale, "old\n");
            File.WriteAllText(recent, "recent\n");

            var log = new RollingLog(_dir, 14, false);
            log.Info("hello");

            Assert.False(File.Exists(stale));
            Assert.True(File.Exists(recent));
            Assert.True(File.Exists(log.CurrentPath));
        }

        [Fact]
        public void A_file_in_the_directory_that_is_not_ours_is_left_alone()
        {
            Directory.CreateDirectory(_dir);
            string foreign = Path.Combine(_dir, "notes.txt");
            File.WriteAllText(foreign, "keep me\n");

            var log = new RollingLog(_dir, 1, false);
            log.Info("hello");

            Assert.True(File.Exists(foreign));
        }

        [Fact]
        public void An_unwritable_directory_does_not_throw_because_a_print_must_not_fail_on_logging()
        {
            // A path that cannot be created on Windows. The bridge has to keep
            // printing regardless -- a lost log line is not worth a lost label.
            var log = new RollingLog("Z:\\definitely\\not\\a\\real\\volume\\logs", 14, false);

            log.Info("this must not throw");
            log.Error("nor this");
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```powershell
dotnet test zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj
```

Expected: compile failure, `error CS0246: The type or namespace name 'RollingLog' could not be found`.

- [ ] **Step 3: Implement `RollingLog`**

Create `zebraPrinter/MesZebraBridge/RollingLog.cs`:

```csharp
// The local log file (spec section 3). A service has no console, so this is the
// only record at the machine, and on 2026-09-29 the Python bridge's equivalent
// survived only because someone happened to redirect stdout.
//
// Timestamps are LOCAL time with the UTC offset. CLAUDE.md's UTC-store/ET-display
// rule governs the database; this file is read by a person standing at the terminal,
// and the offset makes it unambiguous anyway.
//
// Nothing here throws. A print must never fail because logging did.

using System;
using System.Globalization;
using System.IO;
using System.Text;

namespace BlueRidge.MesZebraBridge
{
    public sealed class RollingLog
    {
        private const string FilePrefix = "bridge-";
        private const string FileSuffix = ".log";
        private const string StampFormat = "yyyyMMdd";

        private readonly string _directory;
        private readonly int _retainDays;
        private readonly bool _echoToConsole;
        private readonly object _gate = new object();

        private string _lastPath;

        public RollingLog(string directory, int retainDays, bool echoToConsole)
        {
            _directory = directory;
            _retainDays = retainDays < 1 ? 1 : retainDays;
            _echoToConsole = echoToConsole;
        }

        /// <summary>Today's file. The name carries the date, so the log rolls daily.</summary>
        public string CurrentPath
        {
            get
            {
                return Path.Combine(_directory,
                    FilePrefix + DateTime.Now.ToString(StampFormat, CultureInfo.InvariantCulture) + FileSuffix);
            }
        }

        public void Info(string message) { Write("INFO", message); }

        public void Error(string message) { Write("ERROR", message); }

        public void Write(string level, string message)
        {
            string line = string.Format(CultureInfo.InvariantCulture, "{0} {1} {2}",
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff K", CultureInfo.InvariantCulture),
                level, Protocol.OneLine(message));

            lock (_gate)
            {
                try
                {
                    Directory.CreateDirectory(_directory);
                    string path = CurrentPath;
                    if (path != _lastPath)
                    {
                        _lastPath = path;
                        Prune();
                    }
                    File.AppendAllText(path, line + Environment.NewLine, Encoding.ASCII);
                }
                catch (Exception)
                {
                    // Swallowed on purpose: a lost log line is not worth a lost label.
                }
            }

            if (_echoToConsole)
            {
                try { Console.WriteLine(line); }
                catch (Exception) { }
            }
        }

        /// <summary>
        /// Delete our own day files older than the retention window. Only files
        /// matching our exact name shape are considered, so nothing else in the
        /// directory is ever touched.
        /// </summary>
        private void Prune()
        {
            try
            {
                DateTime cutoff = DateTime.Now.Date.AddDays(-_retainDays);
                foreach (string file in Directory.GetFiles(_directory, FilePrefix + "????????" + FileSuffix))
                {
                    string stamp = Path.GetFileNameWithoutExtension(file).Substring(FilePrefix.Length);
                    DateTime day;
                    if (DateTime.TryParseExact(stamp, StampFormat, CultureInfo.InvariantCulture,
                            DateTimeStyles.None, out day) && day < cutoff)
                        File.Delete(file);
                }
            }
            catch (Exception)
            {
            }
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```powershell
dotnet test zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj
```

Expected: `Failed: 0, Passed: 54`.

If `An_unwritable_directory...` fails because the machine happens to have a `Z:` drive, change the path in the test to an unused drive letter -- do not weaken the assertion.

- [ ] **Step 5: Commit**

```bash
git add zebraPrinter/MesZebraBridge/RollingLog.cs zebraPrinter/MesZebraBridge.Tests/RollingLogTests.cs
git commit -m "feat(bridge): a daily log file that prunes itself and never fails a print"
```

---

### Task 10: The configuration file and the command line

The conf file is now the **authority** for the queue name, not an override of a runtime heuristic (Global Constraint 5), and it is where the Gateway address lives.

Spec § 12.1 still leaves the *format* unspecified -- Global Constraint 1 is the assumption taken. But the **location** and the **no-compiled-in-values** rule are settled by the spec:

- § 7 step 4: *"copy `MesZebraBridge.exe` **and its conf file**"* -> the conf ships **beside the executable**, named `MesZebraBridge.conf`.
- § 10.1: *"**Nothing may be compiled into the bridge binary.** The Gateway address for the firewall rule is `172.17.10.161` ... It lives in the conf file shipped beside the executable -- authored once for all 54 installs, never typed per machine, and never baked in."*

So there is **no `DefaultGatewayAddress` constant**. `GatewayAddress` defaults to `null`, and `install` refuses (Task 13) rather than widening the rule. § 10.1 records why: an earlier revision of this plan compiled in `10.20.11.53`, which was the *development* Gateway on a laptop -- correct on 2026-09-29 and stale that same evening. *A hardcoded address is invisible when it is wrong.*

Logs stay under `%ProgramData%\BlueRidge\MesZebraBridge\logs`: machine state, not shipped configuration, and it keeps the two-file deployment directory clean.

An unknown key or an unparseable number is a **warning, not a failure** -- a typo in a conf file must not stop 9100 listening, but it must be visible in the log.

**Files:**
- Create: `zebraPrinter/MesZebraBridge/BridgeConfig.cs`
- Create: `zebraPrinter/MesZebraBridge.conf` (the authored template that ships with the exe)
- Create: `zebraPrinter/MesZebraBridge.Tests/BridgeConfigTests.cs`

**Interfaces:**
- Consumes: `Protocol.OneLine`
- Produces:
  - `sealed class BridgeConfig` with `Queue`, `GatewayAddress`, `Port`, `LogDirectory`, `LogRetainDays`, `Warnings`
  - `BridgeConfig.DefaultPort` = 9100, `.DefaultLogRetainDays` = 14 (**no gateway constant**)
  - `BridgeConfig.DefaultPath -> string` (beside the executable), `.DefaultLogDirectory -> string`
  - `BridgeConfig.Parse(IEnumerable<string> lines) -> BridgeConfig`
  - `BridgeConfig.Load(string path) -> BridgeConfig`
  - `BridgeConfig.ApplyCommandLine(string[] args) -> void`
  - `BridgeConfig.ConfPathFromCommandLine(string[] args) -> string`
  - `BridgeConfig.ToConfLines() -> IList<string>` / `.Save(string path)`
  - `BridgeConfig.SetQueue(string) -> void`

- [ ] **Step 1: Write the failing tests**

Create `zebraPrinter/MesZebraBridge.Tests/BridgeConfigTests.cs`:

```csharp
// The conf file and the command line. Spec 12.1 leaves the FORMAT open; this is
// the assumption, and these tests are where it is pinned. The LOCATION (beside the
// exe) and the no-compiled-in-values rule are settled by spec 7 step 4 and 10.1.
//
// A typo must never stop the bridge listening, so an unknown key or a bad number
// is a warning the log will name, not a startup failure.

using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using BlueRidge.MesZebraBridge;
using Xunit;

namespace BlueRidge.MesZebraBridge.Tests
{
    public class BridgeConfigTests
    {
        [Fact]
        public void Nothing_deployment_specific_is_compiled_in()
        {
            // Spec 10.1: "Nothing may be compiled into the bridge binary." An earlier
            // revision of this plan carried a DefaultGatewayAddress of 10.20.11.53 --
            // the DEVELOPMENT gateway on a laptop, correct on 2026-09-29 and stale
            // that same evening. A hardcoded address is invisible when it is wrong.
            Type t = typeof(BridgeConfig);
            Assert.Null(t.GetField("DefaultGatewayAddress",
                BindingFlags.Public | BindingFlags.Static | BindingFlags.NonPublic));

            BridgeConfig c = BridgeConfig.Parse(new string[0]);
            Assert.Null(c.GatewayAddress);
            Assert.Null(c.Queue);
        }

        [Fact]
        public void An_absent_file_is_all_defaults_and_not_an_error()
        {
            BridgeConfig c = BridgeConfig.Load(Path.Combine(
                Path.GetTempPath(), "no-such-bridge-conf-" + Guid.NewGuid().ToString("N") + ".conf"));

            Assert.Null(c.Queue);                 // unconfigured, not detected
            Assert.Null(c.GatewayAddress);        // install will refuse, not widen
            Assert.Equal(9100, c.Port);
            Assert.Equal(14, c.LogRetainDays);
            Assert.Equal(BridgeConfig.DefaultLogDirectory, c.LogDirectory);
            Assert.Empty(c.Warnings);
        }

        [Fact]
        public void The_conf_lives_beside_the_executable_not_under_ProgramData()
        {
            // Spec 7 step 4: the deployment is "MesZebraBridge.exe and its conf file".
            // Spec 10.1: the gateway address "lives in the conf file shipped beside
            // the executable -- authored once for all 54 installs".
            string exeDir = Path.GetDirectoryName(typeof(BridgeConfig).Assembly.Location);

            Assert.Equal(Path.Combine(exeDir, "MesZebraBridge.conf"), BridgeConfig.DefaultPath);
        }

        [Fact]
        public void The_log_directory_is_machine_state_under_ProgramData()
        {
            // Not beside the exe: logs are machine state, not shipped configuration,
            // and the deployment directory stays two files.
            Assert.Contains("BlueRidge", BridgeConfig.DefaultLogDirectory);
            Assert.Contains("MesZebraBridge", BridgeConfig.DefaultLogDirectory);
            Assert.EndsWith("logs", BridgeConfig.DefaultLogDirectory);
        }

        [Fact]
        public void Keys_are_case_insensitive_and_values_are_trimmed()
        {
            BridgeConfig c = BridgeConfig.Parse(new[]
            {
                "queue =  Zebra GX420d (RAW)  ",
                "GATEWAYADDRESS=172.17.10.161",
                "Port = 9100",
                "LogRetainDays=30"
            });

            Assert.Equal("Zebra GX420d (RAW)", c.Queue);
            Assert.Equal("172.17.10.161", c.GatewayAddress);
            Assert.Equal(9100, c.Port);
            Assert.Equal(30, c.LogRetainDays);
            Assert.Empty(c.Warnings);
        }

        [Fact]
        public void Comments_and_blank_lines_are_ignored()
        {
            BridgeConfig c = BridgeConfig.Parse(new[]
            {
                "# MES Zebra Bridge configuration",
                "",
                "   ",
                "# Queue = written by install",
                "GatewayAddress=172.17.10.161"
            });

            Assert.Null(c.Queue);
            Assert.Equal("172.17.10.161", c.GatewayAddress);
            Assert.Empty(c.Warnings);
        }

        [Fact]
        public void A_value_containing_an_equals_sign_keeps_it()
        {
            BridgeConfig c = BridgeConfig.Parse(new[] { @"LogDirectory=C:\Logs\a=b" });
            Assert.Equal(@"C:\Logs\a=b", c.LogDirectory);
        }

        [Fact]
        public void An_unknown_key_is_a_warning_not_a_failure()
        {
            BridgeConfig c = BridgeConfig.Parse(new[] { "Prnter=Zebra", "Port=9100" });

            Assert.Equal(9100, c.Port);
            Assert.Single(c.Warnings);
            Assert.Contains("Prnter", c.Warnings[0]);
        }

        [Fact]
        public void A_line_with_no_equals_sign_is_a_warning_not_a_failure()
        {
            BridgeConfig c = BridgeConfig.Parse(new[] { "just some text", "Port=9100" });

            Assert.Equal(9100, c.Port);
            Assert.Single(c.Warnings);
            Assert.Contains("just some text", c.Warnings[0]);
        }

        [Fact]
        public void An_unparseable_or_out_of_range_number_keeps_the_default_and_warns()
        {
            BridgeConfig c = BridgeConfig.Parse(new[] { "Port=nine thousand", "LogRetainDays=0" });

            Assert.Equal(9100, c.Port);
            Assert.Equal(14, c.LogRetainDays);
            Assert.Equal(2, c.Warnings.Count);
        }

        [Fact]
        public void An_empty_queue_value_stays_unconfigured_rather_than_becoming_a_blank_name()
        {
            BridgeConfig c = BridgeConfig.Parse(new[] { "Queue=" });
            Assert.Null(c.Queue);
        }

        [Fact]
        public void Command_line_options_override_the_file()
        {
            BridgeConfig c = BridgeConfig.Parse(new[] { "Queue=From File", "GatewayAddress=10.0.0.1" });

            c.ApplyCommandLine(new[] { "install", "--queue", "From Args", "--gateway", "172.17.10.161", "--port", "9101" });

            Assert.Equal("From Args", c.Queue);
            Assert.Equal("172.17.10.161", c.GatewayAddress);
            Assert.Equal(9101, c.Port);
            Assert.Empty(c.Warnings);
        }

        [Fact]
        public void An_option_with_no_value_is_a_warning_and_changes_nothing()
        {
            BridgeConfig c = BridgeConfig.Parse(new[] { "GatewayAddress=172.17.10.161" });

            c.ApplyCommandLine(new[] { "install", "--gateway" });

            Assert.Equal("172.17.10.161", c.GatewayAddress);
            Assert.Single(c.Warnings);
            Assert.Contains("--gateway", c.Warnings[0]);
        }

        [Fact]
        public void An_unknown_option_is_a_warning_and_changes_nothing()
        {
            BridgeConfig c = BridgeConfig.Parse(new string[0]);

            c.ApplyCommandLine(new[] { "install", "--printer", "Zebra" });

            Assert.Single(c.Warnings);
            Assert.Contains("--printer", c.Warnings[0]);
        }

        [Fact]
        public void The_conf_path_can_be_redirected_from_the_command_line()
        {
            Assert.Equal(@"D:\alt\bridge.conf",
                BridgeConfig.ConfPathFromCommandLine(new[] { "run", "--conf", @"D:\alt\bridge.conf" }));

            Assert.Equal(BridgeConfig.DefaultPath,
                BridgeConfig.ConfPathFromCommandLine(new[] { "run" }));

            Assert.Equal(BridgeConfig.DefaultPath,
                BridgeConfig.ConfPathFromCommandLine(new[] { "run", "--conf" }));   // no value
        }

        [Fact]
        public void Set_queue_records_the_name_and_blanks_it_back_out_when_asked()
        {
            BridgeConfig c = BridgeConfig.Parse(new string[0]);

            c.SetQueue("  Zebra GX420d (RAW) ");
            Assert.Equal("Zebra GX420d (RAW)", c.Queue);

            c.SetQueue("");
            Assert.Null(c.Queue);
        }

        [Fact]
        public void A_written_conf_file_reads_back_identically()
        {
            // install and set-queue both write this file, so the round trip is the
            // contract -- a printer swap must not lose the gateway address.
            BridgeConfig original = BridgeConfig.Parse(new string[0]);
            original.Queue = "Zebra GX420d (RAW)";
            original.GatewayAddress = "172.17.10.161";
            original.Port = 9100;
            original.LogRetainDays = 21;

            string path = Path.Combine(Path.GetTempPath(),
                "bridge-conf-" + Guid.NewGuid().ToString("N") + ".conf");
            try
            {
                original.Save(path);

                BridgeConfig reloaded = BridgeConfig.Load(path);

                Assert.Equal(original.Queue, reloaded.Queue);
                Assert.Equal(original.GatewayAddress, reloaded.GatewayAddress);
                Assert.Equal(original.Port, reloaded.Port);
                Assert.Equal(original.LogRetainDays, reloaded.LogRetainDays);
                Assert.Equal(original.LogDirectory, reloaded.LogDirectory);
                Assert.Empty(reloaded.Warnings);
            }
            finally
            {
                try { File.Delete(path); } catch (Exception) { }
            }
        }

        [Fact]
        public void A_rewrite_after_a_printer_swap_keeps_every_other_value()
        {
            // The swap path: load, SetQueue, Save. Nothing else may move.
            BridgeConfig c = BridgeConfig.Parse(new[]
            {
                "Queue=Old Printer",
                "GatewayAddress=172.17.10.161",
                "Port=9100",
                "LogRetainDays=21"
            });

            c.SetQueue("New Printer");
            IList<string> lines = c.ToConfLines();
            BridgeConfig reloaded = BridgeConfig.Parse(lines);

            Assert.Equal("New Printer", reloaded.Queue);
            Assert.Equal("172.17.10.161", reloaded.GatewayAddress);
            Assert.Equal(21, reloaded.LogRetainDays);
        }

        [Fact]
        public void A_written_conf_file_is_commented_and_ascii_so_a_human_can_read_it()
        {
            BridgeConfig c = BridgeConfig.Parse(new string[0]);
            IList<string> lines = c.ToConfLines();

            Assert.Contains(lines, l => l.StartsWith("#"));
            Assert.Contains(lines, l => l.StartsWith("Port="));
            foreach (string l in lines)
                foreach (char ch in l)
                    Assert.True(ch < 128, "non-ASCII in conf line: " + l);
        }

        [Fact]
        public void An_unconfigured_gateway_is_written_as_a_commented_placeholder_not_a_guess()
        {
            BridgeConfig c = BridgeConfig.Parse(new string[0]);

            string text = string.Join("\n", new List<string>(c.ToConfLines()).ToArray());

            Assert.Contains("# GatewayAddress=", text);
            Assert.DoesNotContain("\nGatewayAddress=", "\n" + text);
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```powershell
dotnet test zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj
```

Expected: compile failure, `error CS0246: The type or namespace name 'BridgeConfig' could not be found`.

- [ ] **Step 3: Implement `BridgeConfig`**

Create `zebraPrinter/MesZebraBridge/BridgeConfig.cs`:

```csharp
// Configuration.
//
//   <beside the exe>\MesZebraBridge.conf    (ASCII, key=value, # comments)
//
// Location per spec 7 step 4 ("copy MesZebraBridge.exe AND ITS CONF FILE") and
// spec 10.1 ("lives in the conf file shipped beside the executable -- authored
// once for all 54 installs"). Format per spec open item 12.1, which leaves it
// unspecified; key=value is the assumption, chosen because a commissioner can read
// it over someone's shoulder and net48 has no first-class JSON reader.
//
// NOTHING DEPLOYMENT-SPECIFIC IS COMPILED IN (spec 10.1). There is deliberately no
// DefaultGatewayAddress and no default Queue. GatewayAddress defaults to null and
// `install` refuses rather than widening the firewall rule; Queue defaults to null
// and the bridge answers `ERR queue unconfigured` rather than guessing.
//
// An earlier revision of this plan compiled in 10.20.11.53 -- the DEVELOPMENT
// gateway on a laptop, correct on 2026-09-29 and stale that same evening when the
// machine changed networks. That is the whole argument.
//
// A typo must never stop 9100 listening: an unknown key or a bad number is a
// warning the startup log names, not a failure.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Text;

namespace BlueRidge.MesZebraBridge
{
    public sealed class BridgeConfig
    {
        public const int DefaultPort = 9100;
        public const int DefaultLogRetainDays = 14;
        public const string ConfFileName = "MesZebraBridge.conf";

        /// <summary>null = unconfigured. The bridge will answer ERR, never guess.</summary>
        public string Queue { get; set; }

        /// <summary>null = unconfigured. install refuses rather than widening the rule.</summary>
        public string GatewayAddress { get; set; }

        public int Port { get; set; }
        public string LogDirectory { get; set; }
        public int LogRetainDays { get; set; }

        /// <summary>Everything that was ignored and why. The startup log names each one.</summary>
        public IList<string> Warnings { get { return _warnings; } }

        private readonly List<string> _warnings = new List<string>();

        private BridgeConfig()
        {
            Queue = null;
            GatewayAddress = null;
            Port = DefaultPort;
            LogDirectory = DefaultLogDirectory;
            LogRetainDays = DefaultLogRetainDays;
        }

        /// <summary>Beside the executable -- it ships with it and is copied with it.</summary>
        public static string DefaultPath
        {
            get
            {
                string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
                return Path.Combine(exeDir, ConfFileName);
            }
        }

        /// <summary>
        /// Machine state, not shipped configuration -- so under ProgramData rather
        /// than beside the exe, which keeps the deployment directory two files.
        /// </summary>
        public static string DefaultLogDirectory
        {
            get
            {
                return Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                    Path.Combine("BlueRidge", Path.Combine("MesZebraBridge", "logs")));
            }
        }

        /// <summary>--conf &lt;path&gt;, else the file beside the exe.</summary>
        public static string ConfPathFromCommandLine(string[] args)
        {
            if (args != null)
            {
                for (int i = 1; i < args.Length - 1; i++)
                    if (string.Equals(args[i], "--conf", StringComparison.OrdinalIgnoreCase))
                        return args[i + 1];
            }
            return DefaultPath;
        }

        public static BridgeConfig Load(string path)
        {
            try
            {
                if (!File.Exists(path)) return new BridgeConfig();
                return Parse(File.ReadAllLines(path));
            }
            catch (Exception ex)
            {
                var c = new BridgeConfig();
                c._warnings.Add("could not read " + path + ": " + Protocol.OneLine(ex.Message));
                return c;
            }
        }

        public static BridgeConfig Parse(IEnumerable<string> lines)
        {
            var c = new BridgeConfig();
            if (lines == null) return c;

            foreach (string raw in lines)
            {
                string line = (raw ?? "").Trim();
                if (line.Length == 0 || line[0] == '#') continue;

                int eq = line.IndexOf('=');
                if (eq < 1)
                {
                    c._warnings.Add("ignored conf line (no key=value): " + line);
                    continue;
                }

                string key = line.Substring(0, eq).Trim();
                string value = line.Substring(eq + 1).Trim();

                switch (key.ToUpperInvariant())
                {
                    case "QUEUE":
                        c.Queue = value.Length == 0 ? null : value;
                        break;
                    case "GATEWAYADDRESS":
                        c.GatewayAddress = value.Length == 0 ? null : value;
                        break;
                    case "LOGDIRECTORY":
                        if (value.Length > 0) c.LogDirectory = value;
                        break;
                    case "PORT":
                        c.Port = c.ReadInt(key, value, 1, 65535, DefaultPort);
                        break;
                    case "LOGRETAINDAYS":
                        c.LogRetainDays = c.ReadInt(key, value, 1, 3650, DefaultLogRetainDays);
                        break;
                    default:
                        c._warnings.Add("ignored unknown conf key: " + key);
                        break;
                }
            }

            return c;
        }

        private int ReadInt(string key, string value, int min, int max, int fallback)
        {
            int parsed;
            if (int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out parsed)
                && parsed >= min && parsed <= max)
                return parsed;

            _warnings.Add(string.Format("{0}={1} is not an integer in [{2}, {3}]; using {4}",
                key, value, min, max, fallback));
            return fallback;
        }

        /// <summary>
        /// Apply --queue / --gateway / --port / --log-dir / --retain-days, which win
        /// over the file. args[0] is the verb and is skipped; --conf is consumed by
        /// ConfPathFromCommandLine and ignored here.
        /// </summary>
        public void ApplyCommandLine(string[] args)
        {
            if (args == null) return;

            for (int i = 1; i < args.Length; i++)
            {
                string opt = (args[i] ?? "").ToLowerInvariant();
                if (!opt.StartsWith("--"))
                {
                    _warnings.Add("ignored unexpected argument: " + args[i]);
                    continue;
                }

                if (i + 1 >= args.Length)
                {
                    _warnings.Add("ignored " + args[i] + ": it takes a value and none followed");
                    return;
                }

                string value = args[++i];
                switch (opt)
                {
                    case "--conf": break;                          // handled separately
                    case "--queue": SetQueue(value); break;
                    case "--gateway": GatewayAddress = value.Length == 0 ? null : value; break;
                    case "--log-dir": LogDirectory = value; break;
                    case "--port": Port = ReadInt("--port", value, 1, 65535, Port); break;
                    case "--retain-days": LogRetainDays = ReadInt("--retain-days", value, 1, 3650, LogRetainDays); break;
                    default:
                        _warnings.Add("ignored unknown option: " + args[i - 1]);
                        break;
                }
            }
        }

        /// <summary>
        /// The one place a queue name is recorded. install and set-queue both go
        /// through it, so a first install and a printer swap cannot diverge.
        /// </summary>
        public void SetQueue(string name)
        {
            string trimmed = (name ?? "").Trim();
            Queue = trimmed.Length == 0 ? null : trimmed;
        }

        public IList<string> ToConfLines()
        {
            var lines = new List<string>
            {
                "# MES Zebra Bridge configuration",
                "# Sits beside MesZebraBridge.exe and is copied with it (spec section 7 step 4).",
                "# Wire protocol: zebraPrinter/PROTOCOL.md v1.0.0.",
                "#",
                "# GatewayAddress  the ONLY source address the inbound firewall rule admits.",
                "#                 Authored once for all 54 installs; never typed per machine",
                "#                 and never compiled into the binary (spec section 10.1).",
                "#                 install refuses to run without it rather than widening",
                "#                 the rule to any source.",
                "# Queue           the exact Windows print queue name to spool to. Written by",
                "#                 'install' when detection finds exactly one candidate, or by",
                "#                 'set-queue \"<name>\"' after a printer swap. There is no",
                "#                 runtime detection: an absent Queue means nothing prints and",
                "#                 the bridge answers 'ERR queue unconfigured'.",
                "# Port            TCP port to listen on. 9100 unless something else owns it.",
                "# LogDirectory    where the daily bridge-YYYYMMDD.log files go.",
                "# LogRetainDays   how many days of those files to keep.",
                ""
            };

            lines.Add(GatewayAddress == null
                ? "# GatewayAddress=172.17.10.161"
                : "GatewayAddress=" + GatewayAddress);

            lines.Add(Queue == null
                ? "# Queue="
                : "Queue=" + Queue);

            lines.Add("Port=" + Port.ToString(CultureInfo.InvariantCulture));
            lines.Add("LogDirectory=" + LogDirectory);
            lines.Add("LogRetainDays=" + LogRetainDays.ToString(CultureInfo.InvariantCulture));

            return lines;
        }

        public void Save(string path)
        {
            string dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

            // ASCII, same rule as every other MPP-authored data file: a stray
            // em-dash read back in the Windows codepage becomes mojibake.
            var sb = new StringBuilder();
            foreach (string line in ToConfLines()) sb.Append(line).Append(Environment.NewLine);
            File.WriteAllText(path, sb.ToString(), Encoding.ASCII);
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```powershell
dotnet test zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj
```

Expected: `Failed: 0, Passed: 74`.

- [ ] **Step 5: Author the conf file that ships with the binary**

This is the file copied to all 54 machines alongside the exe. It carries the Gateway address and **nothing machine-specific** -- `install` adds the `Queue=` line per machine.

Create `zebraPrinter/MesZebraBridge.conf`:

```ini
# MES Zebra Bridge configuration
# Sits beside MesZebraBridge.exe and is copied with it (spec section 7 step 4).
# Wire protocol: zebraPrinter/PROTOCOL.md v1.0.0.
#
# GatewayAddress  the ONLY source address the inbound firewall rule admits.
#                 Authored once for all 54 installs; never typed per machine
#                 and never compiled into the binary (spec section 10.1).
#                 install refuses to run without it rather than widening
#                 the rule to any source.
# Queue           the exact Windows print queue name to spool to. Written by
#                 'install' when detection finds exactly one candidate, or by
#                 'set-queue "<name>"' after a printer swap. There is no
#                 runtime detection: an absent Queue means nothing prints and
#                 the bridge answers 'ERR queue unconfigured'.
# Port            TCP port to listen on. 9100 unless something else owns it.
# LogDirectory    where the daily bridge-YYYYMMDD.log files go.
# LogRetainDays   how many days of those files to keep.

GatewayAddress=172.17.10.161
# Queue=
Port=9100
LogRetainDays=14
```

`LogDirectory` is left out on purpose: omitted means `%ProgramData%\BlueRidge\MesZebraBridge\logs`, which is what every machine should use.

Verify it is ASCII, since `Save` will round-trip it:

```powershell
$bytes = [IO.File]::ReadAllBytes("zebraPrinter\MesZebraBridge.conf")
($bytes | Where-Object { $_ -ge 128 }).Count
```

Expected: `0`.

- [ ] **Step 6: Commit**

```bash
git add zebraPrinter/MesZebraBridge/BridgeConfig.cs zebraPrinter/MesZebraBridge.conf zebraPrinter/MesZebraBridge.Tests/BridgeConfigTests.cs
git commit -m "feat(bridge): the conf file beside the exe is the authority, and nothing is compiled in"
```

---

### Task 11: The TCP server

The socket. Three things here are not interchangeable with the obvious alternative:

- **`SO_EXCLUSIVEADDRUSE`, not `SO_REUSEADDR`** (spec § 3). On Windows the latter permits a *second live process* to bind the same port with undefined delivery between them -- unlike POSIX, where it only permits rebinding a `TIME_WAIT` port. Both halves of that are pinned as tests, so nobody "simplifies" it back.
- **The half-close ends the read** (`PROTOCOL.md` § Framing). In .NET a peer FIN surfaces as `Receive` returning 0, but a client that connects and *holds* the socket open hits the receive timeout, which surfaces as a **`SocketException`, not a clean 0**. That difference from Python's `socket.timeout` is the one easy way to get this wrong.
- **Connections are served on the thread pool; the spooler is serialised** (Global Constraint 10). The Python bridge accepts serially, so one client holding a socket open stalls the next dispatch for the full 2s. Per-connection wire behaviour is identical either way.

Mirrors `test_half_close_then_read_the_ack_over_a_real_socket` and `test_a_bare_connect_gets_no_bytes_and_no_hang`.

**Files:**
- Create: `zebraPrinter/MesZebraBridge/BridgeServer.cs`
- Create: `zebraPrinter/MesZebraBridge.Tests/BridgeServerTests.cs`

**Interfaces:**
- Consumes: `Router.Route`, `QueueBinding`, `RollingLog`
- Produces:
  - `sealed class BridgeServer(IPAddress bind, int port, QueueBinding binding, RollingLog log, Func<string, byte[], SpoolResult> spool, Func<string, QueueStatus> status)`
  - `BridgeServer.ReadTimeoutMs { get; set; }` (default 2000)
  - `BridgeServer.BoundPort -> int`
  - `BridgeServer.Start()` / `.Stop()` / `.Dispose()`
  - `BridgeServer.ReadRequest(Socket) -> byte[]` (internal, for the truncation test)

- [ ] **Step 1: Write the failing tests**

Every test binds `127.0.0.1:0` -- an ephemeral port. **Nothing here touches 9100**, which other work is using.

Create `zebraPrinter/MesZebraBridge.Tests/BridgeServerTests.cs`:

```csharp
// The socket. Binds 127.0.0.1:0 (ephemeral) everywhere -- nothing here touches
// 9100, which other work is using.
//
// The two exclusive-address tests are a pair on purpose: one shows the bridge
// refusing a second binder, the other shows what Windows does WITHOUT the option,
// so the option is demonstrably the thing doing the work.

using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using BlueRidge.MesZebraBridge;
using Xunit;

namespace BlueRidge.MesZebraBridge.Tests
{
    public class BridgeServerTests : IDisposable
    {
        private readonly List<BridgeServer> _servers = new List<BridgeServer>();
        private readonly string _logDir;

        public BridgeServerTests()
        {
            _logDir = Path.Combine(Path.GetTempPath(), "MesZebraBridgeSrv_" + Guid.NewGuid().ToString("N"));
        }

        public void Dispose()
        {
            foreach (BridgeServer s in _servers) { try { s.Dispose(); } catch (Exception) { } }
            try { if (Directory.Exists(_logDir)) Directory.Delete(_logDir, true); } catch (Exception) { }
        }

        private const string ConfiguredQueue = "Zebra GX420d (RAW)";

        private BridgeServer Serve(Func<string, byte[], SpoolResult> spool = null,
                                   Func<string, QueueStatus> status = null,
                                   string queue = ConfiguredQueue)
        {
            // The queue comes from the conf file and nothing else -- pass null to
            // model a terminal that has not been commissioned yet.
            var binding = new QueueBinding(queue);

            var server = new BridgeServer(IPAddress.Loopback, 0, binding,
                new RollingLog(_logDir, 14, false),
                spool ?? ((q, d) => new SpoolResult(7, d.Length)),
                status ?? (q => new QueueStatus(q, true, 0)));

            server.ReadTimeoutMs = 400;   // keep the suite quick; 2000 in production
            server.Start();
            _servers.Add(server);
            return server;
        }

        /// <summary>Write, half-close, read one line. Exactly what the Gateway does.</summary>
        private static string Exchange(int port, byte[] request)
        {
            using (var client = new TcpClient())
            {
                client.Connect(IPAddress.Loopback, port);
                client.ReceiveTimeout = 5000;
                NetworkStream stream = client.GetStream();
                if (request.Length > 0) stream.Write(request, 0, request.Length);
                stream.Flush();
                client.Client.Shutdown(SocketShutdown.Send);
                return new StreamReader(stream, Encoding.ASCII).ReadLine();
            }
        }

        [Fact]
        public void Half_close_then_read_the_ack_over_a_real_socket()
        {
            BridgeServer s = Serve();
            string line = Exchange(s.BoundPort, Encoding.ASCII.GetBytes("^XA^XZ"));
            Assert.Equal("OK queue='Zebra GX420d (RAW)' job=7 bytes=6", line);
        }

        [Fact]
        public void The_reply_is_terminated_with_exactly_one_newline_and_nothing_follows()
        {
            BridgeServer s = Serve();
            using (var client = new TcpClient())
            {
                client.Connect(IPAddress.Loopback, s.BoundPort);
                client.ReceiveTimeout = 5000;
                NetworkStream stream = client.GetStream();
                byte[] req = Encoding.ASCII.GetBytes("^XA^XZ");
                stream.Write(req, 0, req.Length);
                stream.Flush();
                client.Client.Shutdown(SocketShutdown.Send);

                var all = new MemoryStream();
                var buf = new byte[256];
                int n;
                while ((n = stream.Read(buf, 0, buf.Length)) > 0) all.Write(buf, 0, n);

                string text = Encoding.ASCII.GetString(all.ToArray());
                Assert.Equal("OK queue='Zebra GX420d (RAW)' job=7 bytes=6\n", text);
            }
        }

        [Fact]
        public void A_bare_connect_gets_no_bytes_and_no_hang()
        {
            // The reachability probe: connect, send nothing, close. Must not print
            // and must not leave the client waiting. This is validateEndpoint.
            BridgeServer s = Serve(spool: (q, d) =>
                throw new InvalidOperationException("a bare connect must never spool"));

            Assert.Null(Exchange(s.BoundPort, new byte[0]));
        }

        [Fact]
        public void Status_answers_over_the_socket()
        {
            BridgeServer s = Serve(status: q => new QueueStatus(q, true, 0));
            string line = Exchange(s.BoundPort, Encoding.ASCII.GetBytes("?STATUS"));
            Assert.Equal("OK bridge=1.0.0 queue='Zebra GX420d (RAW)' ready=true jobs=0", line);
        }

        [Fact]
        public void A_client_that_sends_then_holds_the_socket_open_still_gets_its_ack_after_the_timeout()
        {
            // No half-close. PROTOCOL.md: the server waits out the idle timeout and
            // answers anyway -- slower, but never a dropped label.
            BridgeServer s = Serve();
            using (var client = new TcpClient())
            {
                client.Connect(IPAddress.Loopback, s.BoundPort);
                client.ReceiveTimeout = 5000;
                NetworkStream stream = client.GetStream();
                byte[] req = Encoding.ASCII.GetBytes("^XA^XZ");
                stream.Write(req, 0, req.Length);
                stream.Flush();
                // deliberately NO Shutdown(Send)
                string line = new StreamReader(stream, Encoding.ASCII).ReadLine();
                Assert.Equal("OK queue='Zebra GX420d (RAW)' job=7 bytes=6", line);
            }
        }

        [Fact]
        public void An_unconfigured_queue_answers_over_the_socket_rather_than_refusing_the_connection()
        {
            // Spec 6.3 maps `Connection refused` to "bridge is down". A conf file
            // with no Queue= is a different fault needing a different fix, so it
            // must not present that way.
            BridgeServer s = Serve(queue: null);

            string line = Exchange(s.BoundPort, Encoding.ASCII.GetBytes("^XA^XZ"));

            Assert.StartsWith("ERR queue unconfigured: ", line);
        }

        [Fact]
        public void An_unconfigured_bridge_still_answers_a_bare_connect_with_silence()
        {
            // Both halves at once, over a real socket: the un-commissioned terminal
            // is exactly where validateEndpoint's probe gets used.
            BridgeServer s = Serve(queue: null);

            Assert.Null(Exchange(s.BoundPort, new byte[0]));
        }

        [Fact]
        public void A_spooler_failure_comes_back_as_one_ERR_line()
        {
            BridgeServer s = Serve(spool: (q, d) =>
                throw new SpoolException("queue not found: 'X'; visible: A, B"));

            string line = Exchange(s.BoundPort, Encoding.ASCII.GetBytes("^XA^XZ"));

            Assert.Equal("ERR queue not found: 'X'; visible: A, B", line);
        }

        [Fact]
        public void Two_requests_are_served_concurrently()
        {
            // A status callback that will not return until BOTH connections are
            // inside it. A serial accept loop deadlocks here and the test fails on
            // the assertion rather than hanging forever.
            var arrived = new CountdownEvent(2);
            BridgeServer s = Serve(status: q =>
            {
                arrived.Signal();
                bool both = arrived.Wait(TimeSpan.FromSeconds(5));
                return new QueueStatus(q, both, 0);
            });

            string a = null, b = null;
            var t1 = new Thread(() => a = Exchange(s.BoundPort, Encoding.ASCII.GetBytes("?STATUS")));
            var t2 = new Thread(() => b = Exchange(s.BoundPort, Encoding.ASCII.GetBytes("?STATUS")));
            t1.Start(); t2.Start();
            Assert.True(t1.Join(TimeSpan.FromSeconds(15)));
            Assert.True(t2.Join(TimeSpan.FromSeconds(15)));

            Assert.Contains("ready=true", a);
            Assert.Contains("ready=true", b);
        }

        [Fact]
        public void The_spooler_is_serialised_so_job_order_at_the_queue_is_not_arbitrary()
        {
            int concurrent = 0;
            int maxConcurrent = 0;
            var gate = new object();

            BridgeServer s = Serve(spool: (q, d) =>
            {
                lock (gate) { concurrent++; if (concurrent > maxConcurrent) maxConcurrent = concurrent; }
                Thread.Sleep(50);
                lock (gate) { concurrent--; }
                return new SpoolResult(1, d.Length);
            });

            var threads = new List<Thread>();
            for (int i = 0; i < 4; i++)
            {
                var t = new Thread(() => Exchange(s.BoundPort, Encoding.ASCII.GetBytes("^XA^XZ")));
                threads.Add(t);
                t.Start();
            }
            foreach (Thread t in threads) Assert.True(t.Join(TimeSpan.FromSeconds(15)));

            Assert.Equal(1, maxConcurrent);
        }

        [Fact]
        public void A_request_over_one_mebibyte_is_truncated_to_exactly_the_limit()
        {
            int spooledBytes = -1;
            BridgeServer s = Serve(spool: (q, d) => { spooledBytes = d.Length; return new SpoolResult(1, d.Length); });

            var oversized = new byte[Protocol.MaxRequestBytes + 50000];
            for (int i = 0; i < oversized.Length; i++) oversized[i] = (byte)'x';

            string line = Exchange(s.BoundPort, oversized);

            Assert.Equal(Protocol.MaxRequestBytes, spooledBytes);
            Assert.Equal("OK queue='Zebra GX420d (RAW)' job=1 bytes=1048576", line);
        }

        [Fact]
        public void The_bridge_refuses_a_second_binder_on_its_port()
        {
            // SO_EXCLUSIVEADDRUSE. The intruder asks for SO_REUSEADDR, which on a
            // plain listener WOULD succeed (see the next test) -- so this assertion
            // is specifically about the option, not merely about the port being busy.
            BridgeServer s = Serve();

            var intruder = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            try
            {
                intruder.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                var ex = Assert.Throws<SocketException>(
                    () => intruder.Bind(new IPEndPoint(IPAddress.Loopback, s.BoundPort)));
                Assert.Equal(SocketError.AddressAlreadyInUse, ex.SocketErrorCode);
            }
            finally
            {
                intruder.Close();
            }
        }

        [Fact]
        public void Without_exclusive_use_windows_lets_a_second_live_socket_steal_the_port()
        {
            // Why SO_EXCLUSIVEADDRUSE is not optional on Windows, pinned so nobody
            // "simplifies" BridgeServer.Start back to the default. Unlike POSIX,
            // SO_REUSEADDR here admits a second LIVE socket, with delivery between
            // the two undefined -- which for a print bridge means labels vanishing
            // into whichever process happens to win.
            var first = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            var second = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            try
            {
                first.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                first.Bind(new IPEndPoint(IPAddress.Loopback, 0));
                first.Listen(1);
                int port = ((IPEndPoint)first.LocalEndPoint).Port;

                second.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                second.Bind(new IPEndPoint(IPAddress.Loopback, port));

                Assert.Equal(port, ((IPEndPoint)second.LocalEndPoint).Port);
            }
            finally
            {
                first.Close();
                second.Close();
            }
        }

        [Fact]
        public void Stop_releases_the_port_and_is_idempotent()
        {
            BridgeServer s = Serve();
            int port = s.BoundPort;

            s.Stop();
            s.Stop();   // must not throw

            var rebind = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            try
            {
                rebind.ExclusiveAddressUse = true;
                rebind.Bind(new IPEndPoint(IPAddress.Loopback, port));
                rebind.Listen(1);
            }
            finally
            {
                rebind.Close();
            }
        }

        [Fact]
        public void A_dispatch_is_logged_with_its_source_address_and_the_reply()
        {
            // Spec section 1: diagnosing 2026-09-29's label needed three uncorrelated
            // sources, one of them a human reading a console. The log is the machine's
            // own copy, and it self-documents where a print came from.
            BridgeServer s = Serve();
            var log = new RollingLog(_logDir, 14, false);

            Exchange(s.BoundPort, Encoding.ASCII.GetBytes("^XA^XZ"));
            Thread.Sleep(200);   // the handler logs after the send, on a pool thread

            string text = File.ReadAllText(log.CurrentPath);
            Assert.Contains("connection from 127.0.0.1", text);
            Assert.Contains("OK queue='Zebra GX420d (RAW)' job=7 bytes=6", text);
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```powershell
dotnet test zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj
```

Expected: compile failure, `error CS0246: The type or namespace name 'BridgeServer' could not be found`.

- [ ] **Step 3: Implement `BridgeServer`**

Create `zebraPrinter/MesZebraBridge/BridgeServer.cs`:

```csharp
// The socket. One request per connection: read until the peer half-closes, write
// one line, close.
//
// SO_EXCLUSIVEADDRUSE, not SO_REUSEADDR (spec section 3). On Windows SO_REUSEADDR
// permits a SECOND LIVE PROCESS to bind the same port, with delivery between them
// undefined -- unlike POSIX, where it only permits rebinding a TIME_WAIT port. For
// a print bridge that means labels disappearing into whichever process wins.
//
// Connections are served on the thread pool so one client holding a socket open
// cannot stall the next dispatch for the whole read timeout, which is what the
// Python bridge's serial accept loop does. The SPOOLER is serialised instead:
// job ordering at the queue is the thing that would otherwise be arbitrary.

using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace BlueRidge.MesZebraBridge
{
    public sealed class BridgeServer : IDisposable
    {
        private readonly IPAddress _bind;
        private readonly int _requestedPort;
        private readonly QueueBinding _binding;
        private readonly RollingLog _log;
        private readonly Func<string, byte[], SpoolResult> _spool;
        private readonly Func<string, QueueStatus> _status;
        private readonly object _spoolGate = new object();
        private readonly object _lifecycleGate = new object();

        private Socket _listener;
        private Thread _acceptThread;
        private volatile bool _stopping;

        /// <summary>
        /// PROTOCOL.md: without the client's half-close the server waits this long
        /// before answering. Settable so tests do not pay 2s each.
        /// </summary>
        public int ReadTimeoutMs { get; set; }

        /// <summary>The port actually bound. Differs from the request only when 0 was asked for.</summary>
        public int BoundPort { get; private set; }

        public BridgeServer(IPAddress bind, int port, QueueBinding binding, RollingLog log,
                            Func<string, byte[], SpoolResult> spool,
                            Func<string, QueueStatus> status)
        {
            if (bind == null) throw new ArgumentNullException("bind");
            if (binding == null) throw new ArgumentNullException("binding");
            if (log == null) throw new ArgumentNullException("log");
            if (spool == null) throw new ArgumentNullException("spool");
            if (status == null) throw new ArgumentNullException("status");

            _bind = bind;
            _requestedPort = port;
            _binding = binding;
            _log = log;
            _spool = spool;
            _status = status;
            ReadTimeoutMs = 2000;
        }

        /// <summary>
        /// Bind and start accepting. Throws on a bind failure -- deliberately, so the
        /// SCM records a failed start and the recovery actions fire. An UNRESOLVED
        /// QUEUE is not a bind failure and does not stop the listener (spec 3 vs 6.3).
        /// </summary>
        public void Start()
        {
            lock (_lifecycleGate)
            {
                if (_listener != null) throw new InvalidOperationException("already started");

                var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);

                // MUST be set before Bind; setting it afterwards throws.
                socket.ExclusiveAddressUse = true;

                socket.Bind(new IPEndPoint(_bind, _requestedPort));
                socket.Listen(16);

                _listener = socket;
                BoundPort = ((IPEndPoint)socket.LocalEndPoint).Port;
                _stopping = false;

                _acceptThread = new Thread(AcceptLoop);
                _acceptThread.IsBackground = true;
                _acceptThread.Name = "MesZebraBridge.Accept";
                _acceptThread.Start();

                _log.Info(string.Format("listening on {0}:{1}", _bind, BoundPort));
            }
        }

        public void Stop()
        {
            Thread accept;
            lock (_lifecycleGate)
            {
                _stopping = true;

                Socket socket = _listener;
                _listener = null;
                accept = _acceptThread;
                _acceptThread = null;

                // Closing the listener is what unblocks the blocking Accept below.
                if (socket != null)
                {
                    try { socket.Close(); } catch (Exception) { }
                    _log.Info("stopped listening on port " + BoundPort);
                }
            }

            if (accept != null) accept.Join(5000);
        }

        public void Dispose() { Stop(); }

        private void AcceptLoop()
        {
            while (!_stopping)
            {
                Socket conn;
                try
                {
                    conn = _listener.Accept();
                }
                catch (ObjectDisposedException)
                {
                    return;                       // Stop() closed the listener
                }
                catch (NullReferenceException)
                {
                    return;                       // Stop() nulled it mid-call
                }
                catch (SocketException ex)
                {
                    if (_stopping) return;
                    _log.Error("accept failed: " + ex.Message);
                    continue;
                }

                ThreadPool.QueueUserWorkItem(ServeOne, conn);
            }
        }

        private void ServeOne(object state)
        {
            var conn = (Socket)state;
            try
            {
                string peer = "?";
                try { peer = ((IPEndPoint)conn.RemoteEndPoint).Address.ToString(); }
                catch (Exception) { }

                conn.ReceiveTimeout = ReadTimeoutMs;
                conn.SendTimeout = ReadTimeoutMs;

                byte[] data = ReadRequest(conn, ReadTimeoutMs);

                // Log the source so a dispatch self-documents its origin: a
                // Gateway-scope print shows the Gateway's IP, a Script Console test
                // shows the local machine.
                _log.Info(string.Format("connection from {0} ({1} bytes)", peer, data.Length));

                string reply = Router.Route(data, _binding, SpoolSerialized, _status);
                if (reply != null)
                {
                    conn.Send(Encoding.ASCII.GetBytes(reply + "\n"));
                    _log.Info("  " + reply);
                }
            }
            catch (Exception ex)
            {
                _log.Error("handler error: " + ex.Message);
            }
            finally
            {
                try { conn.Shutdown(SocketShutdown.Both); } catch (Exception) { }
                try { conn.Close(); } catch (Exception) { }
            }
        }

        private SpoolResult SpoolSerialized(string queue, byte[] data)
        {
            lock (_spoolGate) { return _spool(queue, data); }
        }

        /// <summary>
        /// Read until the peer half-closes, the idle timeout, or the size cap.
        ///
        /// A FIN surfaces as Receive returning 0. A client that connects and HOLDS
        /// the socket open instead trips the receive timeout, which in .NET is a
        /// SocketException rather than a clean 0 -- unlike Python's socket.timeout
        /// sitting outside the loop. That asymmetry is the easy way to get this wrong.
        /// </summary>
        internal static byte[] ReadRequest(Socket conn, int timeoutMs)
        {
            conn.ReceiveTimeout = timeoutMs;
            var buffer = new byte[4096];

            using (var received = new MemoryStream())
            {
                while (received.Length < Protocol.MaxRequestBytes)
                {
                    int n;
                    try
                    {
                        n = conn.Receive(buffer);
                    }
                    catch (SocketException ex)
                    {
                        if (ex.SocketErrorCode == SocketError.TimedOut
                            || ex.SocketErrorCode == SocketError.ConnectionReset)
                            break;
                        throw;
                    }

                    if (n == 0) break;            // FIN: the half-close that ends the read
                    received.Write(buffer, 0, n);
                }

                byte[] all = received.ToArray();
                if (all.Length <= Protocol.MaxRequestBytes) return all;

                // The loop checks its cap after appending, so it can overshoot by up
                // to one buffer. Truncate to exactly the limit, so the `bytes=` in the
                // ACK is a number the Gateway can trust (PROTOCOL.md "Framing").
                var capped = new byte[Protocol.MaxRequestBytes];
                Array.Copy(all, capped, Protocol.MaxRequestBytes);
                return capped;
            }
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```powershell
dotnet test zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj
```

Expected: `Failed: 0, Passed: 89`.

If `Without_exclusive_use_windows_lets_a_second_live_socket_steal_the_port` fails, the OS is not behaving as the spec's rationale assumes -- **report that rather than deleting the test**, because it is the entire justification for the option.

- [ ] **Step 5: Commit**

```bash
git add zebraPrinter/MesZebraBridge/BridgeServer.cs zebraPrinter/MesZebraBridge.Tests/BridgeServerTests.cs
git commit -m "feat(bridge): an exclusive listener that reads to the half-close and answers on one line"
```

---

### Task 12: The host, the service wrapper, and the console verbs

One bootstrap shared by the service and the console, so `run` and the installed service cannot diverge. Plus `detect` and `status`, which are the commissioning tools at the machine: `detect` is what turns the 2026-09-29 three-candidate host from a mystery into a sentence, and `install` calls it so the deploying human sees an ambiguity where they can still fix it.

**Files:**
- Create: `zebraPrinter/MesZebraBridge/Host.cs`
- Create: `zebraPrinter/MesZebraBridge/BridgeService.cs`
- Create: `zebraPrinter/MesZebraBridge/Program.cs`
- Create: `zebraPrinter/MesZebraBridge.Tests/HostTests.cs`

**Interfaces:**
- Consumes: `BridgeConfig`, `RollingLog`, `QueueBinding`, `BridgeServer`, `Spooler`
- Produces:
  - `Host.Build(BridgeConfig config, bool echoToConsole, out RollingLog log, out QueueBinding binding) -> BridgeServer`
  - `Host.LoadConfig(string[] args) -> BridgeConfig`
  - `Host.StartupBanner(BridgeConfig, string diagnosis) -> IList<string>`
  - `Host.RunConsole(string[] args) -> int`
  - `Host.PrintDetection() -> int`, `Host.PrintStatus(string[] args) -> int`
  - `Program.Usage : const string`, `Program.Main(string[] args) -> int`
  - `BridgeService : ServiceBase`

- [ ] **Step 1: Write the failing tests**

Only the pure parts are tested here. `ServiceBase.Run` and a real SCM start cannot be unit-tested; Task 15 exercises them against a live install.

Create `zebraPrinter/MesZebraBridge.Tests/HostTests.cs`:

```csharp
// The bootstrap's pure parts: what the startup banner says, and that the config
// the service builds from is the same one the console verbs build from.
//
// ServiceBase.Run and a real SCM start are exercised in Task 15, not here.

using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Text;
using BlueRidge.MesZebraBridge;
using Xunit;

namespace BlueRidge.MesZebraBridge.Tests
{
    public class HostTests : IDisposable
    {
        private readonly string _dir;

        public HostTests()
        {
            _dir = Path.Combine(Path.GetTempPath(), "MesZebraBridgeHost_" + Guid.NewGuid().ToString("N"));
        }

        public void Dispose()
        {
            try { if (Directory.Exists(_dir)) Directory.Delete(_dir, true); }
            catch (Exception) { }
        }

        [Fact]
        public void The_startup_banner_names_the_version_the_port_the_queue_and_the_log_path()
        {
            // Spec section 1: the 2026-09-29 diagnosis needed three uncorrelated
            // sources. The banner is the machine's own answer to "what is this thing
            // bound to", which is the question that cost the most time.
            BridgeConfig c = BridgeConfig.Parse(new[]
            {
                "Port=9100",
                "Queue=Zebra GX420d (RAW)",
                "GatewayAddress=172.17.10.161",
                "LogDirectory=" + _dir
            });

            IList<string> banner = Host.StartupBanner(c, new QueueBinding(c.Queue).Diagnosis);
            string text = string.Join(" | ", new List<string>(banner).ToArray());

            Assert.Contains("MesZebraBridge", text);
            Assert.Contains(Protocol.BridgeVersion, text);
            Assert.Contains("0.0.0.0:9100", text);
            Assert.Contains("Zebra GX420d (RAW)", text);
            Assert.Contains(_dir, text);
            Assert.Contains("172.17.10.161", text);
            Assert.Contains(BridgeConfig.ConfFileName, text);   // where to go and change it
        }

        [Fact]
        public void The_banner_shouts_when_there_is_no_queue_to_bind()
        {
            // A commissioned terminal and an un-commissioned one must not produce
            // banners that read the same at a glance.
            BridgeConfig c = BridgeConfig.Parse(new[] { "GatewayAddress=172.17.10.161" });

            string text = string.Join(" | ", new List<string>(
                Host.StartupBanner(c, new QueueBinding(c.Queue).Diagnosis)).ToArray());

            Assert.Contains("(none)", text);
            Assert.Contains("no Queue=", text);
        }

        [Fact]
        public void The_banner_repeats_every_configuration_warning_so_a_typo_is_visible()
        {
            BridgeConfig c = BridgeConfig.Parse(new[] { "Prnter=Zebra", "Port=nope" });

            string text = string.Join(" | ", new List<string>(Host.StartupBanner(c, "x")).ToArray());

            Assert.Contains("Prnter", text);
            Assert.Contains("nope", text);
        }

        [Fact]
        public void Loading_the_config_applies_the_command_line_over_the_file()
        {
            BridgeConfig c = Host.LoadConfig(new[] { "run", "--queue", "Hand Picked", "--log-dir", _dir });

            Assert.Equal("Hand Picked", c.Queue);
            Assert.Equal(_dir, c.LogDirectory);
        }

        [Fact]
        public void The_host_binds_all_interfaces_because_the_gateway_is_on_another_machine()
        {
            // 0.0.0.0, carried over from the Python bridge (spec section 3). The
            // firewall rule Task 13 adds is what keeps that from being wide open.
            Assert.Equal(IPAddress.Any, Host.BindAddress);
        }

        [Fact]
        public void The_host_builds_a_server_that_starts_and_stops_cleanly()
        {
            BridgeConfig c = BridgeConfig.Parse(new[] { "LogDirectory=" + _dir });

            // Set Port DIRECTLY rather than through the conf: `Port=0` is outside
            // BridgeConfig's valid [1, 65535] range, so parsing it would warn and
            // fall back to 9100 -- and this test would then bind the real port that
            // other work is using. 0 here means "ephemeral", which is what we want.
            c.Port = 0;

            RollingLog log;
            QueueBinding binding;
            using (BridgeServer server = Host.Build(c, false, out log, out binding))
            {
                Assert.NotNull(log);
                Assert.NotNull(binding);
                server.Start();
                Assert.True(server.BoundPort > 0);
                server.Stop();
            }
        }

        [Fact]
        public void The_usage_text_names_every_verb_and_every_option()
        {
            foreach (string token in new[]
            {
                "install", "uninstall", "run", "status", "detect",
                "--queue", "--gateway", "--port", "--log-dir", "--retain-days"
            })
            {
                Assert.Contains(token, Program.Usage);
            }
        }

        [Fact]
        public void The_usage_text_is_ascii_only()
        {
            foreach (char ch in Program.Usage)
                Assert.True(ch < 128, "non-ASCII in usage text");
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```powershell
dotnet test zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj
```

Expected: compile failure, `error CS0246: The type or namespace name 'Host' could not be found`, and the same for `Program`.

- [ ] **Step 3: Implement `Host`**

Create `zebraPrinter/MesZebraBridge/Host.cs`:

```csharp
// One bootstrap, shared by the installed service and the `run` console verb, so
// the two cannot drift apart. Also the `detect` and `status` verbs, which are the
// commissioning tools at the machine.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Net;
using System.ServiceProcess;
using System.Threading;

namespace BlueRidge.MesZebraBridge
{
    public static class Host
    {
        /// <summary>
        /// 0.0.0.0, carried over from the Python bridge (spec section 3): the Gateway
        /// is on another machine. The scoped inbound firewall rule Task 13 adds is
        /// what keeps binding every interface from being wide open.
        /// </summary>
        public static IPAddress BindAddress { get { return IPAddress.Any; } }

        /// <summary>Read the conf beside the exe (or --conf), then apply CLI overrides.</summary>
        public static BridgeConfig LoadConfig(string[] args)
        {
            BridgeConfig config = BridgeConfig.Load(BridgeConfig.ConfPathFromCommandLine(args));
            config.ApplyCommandLine(args);
            return config;
        }

        public static IList<string> StartupBanner(BridgeConfig config, string diagnosis)
        {
            var lines = new List<string>
            {
                string.Format(CultureInfo.InvariantCulture,
                    "MesZebraBridge {0} starting -- wire protocol PROTOCOL.md v{0}", Protocol.BridgeVersion),
                string.Format(CultureInfo.InvariantCulture,
                    "listen        {0}:{1}", BindAddress, config.Port),
                string.Format(CultureInfo.InvariantCulture,
                    "queue         {0}", config.Queue == null ? "(none)" : config.Queue),
                string.Format(CultureInfo.InvariantCulture,
                    "binding       {0}", diagnosis),
                string.Format(CultureInfo.InvariantCulture,
                    "gateway       {0} (the only source the firewall rule admits)",
                    config.GatewayAddress == null ? "(none)" : config.GatewayAddress),
                string.Format(CultureInfo.InvariantCulture,
                    "conf          {0}", BridgeConfig.DefaultPath),
                string.Format(CultureInfo.InvariantCulture,
                    "log           {0} (keeping {1} day(s))", config.LogDirectory, config.LogRetainDays)
            };

            foreach (string w in config.Warnings) lines.Add("CONFIG WARNING " + w);
            return lines;
        }

        /// <summary>
        /// Build the server, the log and the binding from a config. Does not Start().
        ///
        /// The binding is the conf'd queue name and nothing else -- no enumeration
        /// on this path (Global Constraint 5). Detection is install-time only.
        /// </summary>
        public static BridgeServer Build(BridgeConfig config, bool echoToConsole,
                                         out RollingLog log, out QueueBinding binding)
        {
            log = new RollingLog(config.LogDirectory, config.LogRetainDays, echoToConsole);
            binding = new QueueBinding(config.Queue);

            return new BridgeServer(BindAddress, config.Port, binding, log,
                (queue, data) => Spooler.SpoolRaw(queue, data),
                queue => Spooler.ReadQueueStatus(queue));
        }

        /// <summary>
        /// Start, log the banner, and hand back the running server. Shared by
        /// BridgeService.OnStart and the `run` verb.
        ///
        /// An UNCONFIGURED QUEUE is logged as an error and does NOT stop the listener
        /// (Global Constraint 6): a service that refuses to start looks to the
        /// Gateway like `Connection refused`, which spec 6.3 reads as "bridge is
        /// down" -- the wrong machine to go and look at. A BIND failure does throw,
        /// so the SCM records a failed start and the recovery actions fire.
        /// </summary>
        public static BridgeServer StartUp(BridgeConfig config, bool echoToConsole, out RollingLog log)
        {
            QueueBinding binding;
            BridgeServer server = Build(config, echoToConsole, out log, out binding);

            foreach (string line in StartupBanner(config, binding.Diagnosis)) log.Info(line);

            if (!binding.IsConfigured)
                log.Error("NO QUEUE CONFIGURED -- listening, but every request will be refused "
                          + "with 'ERR queue unconfigured'. Nothing is guessed and nothing will "
                          + "print. " + binding.Diagnosis);

            server.Start();
            return server;
        }

        public static int RunConsole(string[] args)
        {
            BridgeConfig config = LoadConfig(args);
            RollingLog log;

            using (BridgeServer server = StartUp(config, true, out log))
            {
                Console.WriteLine();
                Console.WriteLine("Ctrl-C to stop.");

                var stop = new ManualResetEventSlim(false);
                Console.CancelKeyPress += (s, e) => { e.Cancel = true; stop.Set(); };
                stop.Wait();

                Console.WriteLine("stopping...");
                server.Stop();
            }

            return 0;
        }

        /// <summary>
        /// Every local queue with its driver, its port, and the detection verdict.
        /// INSTALL-TIME ONLY -- the running service never calls this.
        ///
        /// This is what turns the ambiguous three-candidate host into a sentence a
        /// commissioner can act on, and `install` prints it when it has to ask for
        /// --queue. Exit code 1 for unresolved so a script can branch on it.
        /// </summary>
        public static int PrintDetection()
        {
            IList<PrinterEntry> queues;
            try
            {
                queues = Spooler.EnumerateLocalQueues();
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("could not enumerate local print queues: " + Protocol.OneLine(ex.Message));
                return 1;
            }

            Console.WriteLine("Local print queues ({0}):", queues.Count);
            foreach (PrinterEntry q in queues)
            {
                Console.WriteLine("  {0,-40} driver={1,-32} port={2,-16} {3}{4}",
                    q.Name, q.Driver, q.Port,
                    QueueResolver.IsZebraDriver(q.Driver) ? "ZEBRA " : "",
                    QueueResolver.IsZebraDriver(q.Driver)
                        ? (QueueResolver.IsLivePort(q.Port) ? "live-port" : "DEAD-PORT")
                        : "");
            }

            QueueResolution r = QueueResolver.Select(queues);
            Console.WriteLine();
            if (r.Resolved)
            {
                Console.WriteLine("ONE CANDIDATE: " + r.Diagnosis);
                Console.WriteLine("'install' would write that name into the conf file.");
                return 0;
            }
            Console.WriteLine("CANNOT CHOOSE: " + r.Diagnosis);
            return 1;
        }

        /// <summary>
        /// Configuration, binding and service state, for commissioning. Reads the
        /// conf -- it does not detect, so it reports what the service will actually do.
        /// </summary>
        public static int PrintStatus(string[] args)
        {
            BridgeConfig config = LoadConfig(args);
            var binding = new QueueBinding(config.Queue);

            foreach (string line in StartupBanner(config, binding.Diagnosis)) Console.WriteLine(line);

            Console.WriteLine();
            try
            {
                using (var sc = new ServiceController(Installer.ServiceName))
                    Console.WriteLine("service       {0} is {1}", Installer.ServiceName, sc.Status);
            }
            catch (Exception)
            {
                Console.WriteLine("service       {0} is NOT INSTALLED (run: MesZebraBridge.exe install)",
                    Installer.ServiceName);
            }

            // The queue is a name from a text file, so say whether the spooler
            // actually has it -- that is the mistyped-conf case, and PROTOCOL.md
            // requires ?STATUS to report it as ready=false rather than an error.
            if (binding.IsConfigured)
            {
                QueueStatus s = Spooler.ReadQueueStatus(binding.Queue);
                Console.WriteLine("spooler       queue {0} ready={1} jobs={2}",
                    Protocol.Quote(binding.Queue), s.Ready ? "true" : "false", s.Jobs);
                if (!s.Ready)
                    Console.WriteLine("              not ready -- is the name exactly right, and is the "
                                      + "printer on? 'detect' lists this machine's queues.");
            }

            return 0;
        }
    }
}
```

- [ ] **Step 4: Implement `BridgeService`**

Create `zebraPrinter/MesZebraBridge/BridgeService.cs`:

```csharp
// The SCM wrapper. Chosen over a session process because "no touch" is stronger
// than "possible" (spec section 3): a service starts before any logon, survives
// the kiosk session being cycled, and is restarted by the SCM when it dies.
//
// On 2026-09-29 the Python bridge exited on a queued Ctrl-C the instant an
// unrelated probe released accept(), consumed the print job it was mid-way through
// handling, and stayed dead. Across 54 unattended plant PCs that reaches us as
// "the printer is broken."

using System;
using System.ServiceProcess;

namespace BlueRidge.MesZebraBridge
{
    internal sealed class BridgeService : ServiceBase
    {
        private BridgeServer _server;
        private RollingLog _log;

        public BridgeService()
        {
            ServiceName = Installer.ServiceName;
            CanStop = true;
            CanShutdown = true;
            CanPauseAndContinue = false;
            AutoLog = true;   // start/stop go in the Windows Event Log as well
        }

        protected override void OnStart(string[] args)
        {
            try
            {
                // Always the conf beside the exe -- the SCM binary path carries no
                // arguments, so a --conf override is a console-only thing.
                BridgeConfig config = Host.LoadConfig(new string[] { "service" });
                _server = Host.StartUp(config, false, out _log);
            }
            catch (Exception ex)
            {
                // Let it throw: the SCM records a failed start and the recovery
                // actions set at install time restart us. Logging first means the
                // reason survives even though the process does not.
                if (_log != null) _log.Error("STARTUP FAILED: " + Protocol.OneLine(ex.Message));
                throw;
            }
        }

        protected override void OnStop()
        {
            try
            {
                if (_server != null) _server.Stop();
                if (_log != null) _log.Info("service stopped");
            }
            catch (Exception ex)
            {
                if (_log != null) _log.Error("stop failed: " + Protocol.OneLine(ex.Message));
            }
        }

        protected override void OnShutdown() { OnStop(); }
    }
}
```

- [ ] **Step 5: Implement `Program`**

Create `zebraPrinter/MesZebraBridge/Program.cs`:

```csharp
// Verb dispatch.
//
// No arguments under the SCM means "be the service". No arguments at an interactive
// prompt means the human double-clicked it, so print usage instead of the SCM's
// baffling "cannot be started from the command line" dialog.

using System;
using System.ServiceProcess;

namespace BlueRidge.MesZebraBridge
{
    public static class Program
    {
        public const string Usage =
@"MES Zebra Bridge " + Protocol.BridgeVersion + @" -- Blue Ridge Automation
Accepts ZPL on TCP 9100 and spools it to the local Zebra queue (RAW).
Wire protocol: zebraPrinter/PROTOCOL.md v" + Protocol.BridgeVersion + @"

  MesZebraBridge.exe install             register the service, set SCM restart-on-failure
                                         recovery, write the conf, add the inbound firewall
                                         rule, start, and report the queue it bound.
                                         Safe to re-run: it reconfigures and restarts.
  MesZebraBridge.exe set-queue ""<name>""   point the bridge at a different print queue
                                         after a printer swap, and restart
  MesZebraBridge.exe uninstall           stop, remove the service, remove the firewall rule
  MesZebraBridge.exe run                 run in this console instead of as a service
  MesZebraBridge.exe status              configuration, bound queue, and service state
  MesZebraBridge.exe detect              list every local print queue and say whether one
                                         Zebra candidate can be picked out

Options (install / set-queue / run / status):
  --conf <path>         use this conf file instead of MesZebraBridge.conf beside the exe.
  --queue <name>        the exact Windows print queue name to bind. Required when
                        this machine has zero or several Zebra candidates.
  --gateway <address>   the only source address the firewall rule admits. Normally
                        already in the shipped conf file; install refuses without it.
  --port <n>            TCP port to listen on. Default 9100.
  --log-dir <path>      where the daily bridge-YYYYMMDD.log files go.
  --retain-days <n>     how many days of log files to keep. Default 14.

There is no runtime queue detection: the bridge spools to the queue named in its
conf file, and answers 'ERR queue unconfigured' when there is none.

install, set-queue and uninstall require an elevated (Administrator) prompt.
";

        public static int Main(string[] args)
        {
            if (args == null || args.Length == 0)
            {
                if (!Environment.UserInteractive)
                {
                    ServiceBase.Run(new BridgeService());
                    return 0;
                }
                Console.Error.Write(Usage);
                return 2;
            }

            switch (args[0].ToLowerInvariant())
            {
                case "install":   return Installer.Install(args);
                case "set-queue": return Installer.SetQueue(args);
                case "uninstall": return Installer.Uninstall();
                case "run":       return Host.RunConsole(args);
                case "status":    return Host.PrintStatus(args);
                case "detect":    return Host.PrintDetection();
                default:
                    Console.Error.WriteLine("unknown verb: " + args[0]);
                    Console.Error.WriteLine();
                    Console.Error.Write(Usage);
                    return 2;
            }
        }
    }
}
```

- [ ] **Step 6: Add the `Installer` stub so this task compiles on its own**

`Program` and `Host.PrintStatus` reference `Installer`. Task 13 fills it in; it must not be broken in between.

Create `zebraPrinter/MesZebraBridge/Installer.cs`:

```csharp
// Self-install: SCM registration, restart-on-failure recovery, and the service's
// own inbound firewall rule scoped to the Gateway (spec sections 3 and 7).
// Task 13 implements it; this is the shape the rest of the program compiles against.

using System;

namespace BlueRidge.MesZebraBridge
{
    public static class Installer
    {
        public const string ServiceName = "MesZebraBridge";

        public static int Install(string[] args)
        {
            Console.Error.WriteLine("install is not implemented yet");
            return 1;
        }

        public static int SetQueue(string[] args)
        {
            Console.Error.WriteLine("set-queue is not implemented yet");
            return 1;
        }

        public static int Uninstall()
        {
            Console.Error.WriteLine("uninstall is not implemented yet");
            return 1;
        }
    }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

```powershell
dotnet test zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj
```

Expected: `Failed: 0, Passed: 96`.

- [ ] **Step 8: Run the bridge in a console, on a port that is not 9100**

Other work is using 9100, so prove the whole path on a spare port.

Task 10 has not shipped the conf template yet at this point in the plan, so drive it from the command line. Run it **twice**: once unconfigured, to see the degraded answer, and once with `--queue` to see a real binding.

```powershell
dotnet build zebraPrinter/MesZebraBridge/MesZebraBridge.csproj -c Debug
$env:TEMP_BRIDGE_LOG = Join-Path $env:TEMP "bridge-smoke"
Start-Process -FilePath "zebraPrinter\MesZebraBridge\bin\Debug\MesZebraBridge.exe" -ArgumentList "run","--port","19100","--log-dir",$env:TEMP_BRIDGE_LOG
```

Then probe it, consuming no label:

```powershell
$c = New-Object Net.Sockets.TcpClient('127.0.0.1', 19100)
$s = $c.GetStream()
$b = [Text.Encoding]::ASCII.GetBytes('?STATUS')
$s.Write($b, 0, $b.Length); $s.Flush(); $c.Client.Shutdown('Send')
(New-Object IO.StreamReader($s)).ReadLine()
$c.Close()
```

Expected, with no `--queue` and no conf: `ERR queue unconfigured: no Queue= in the configuration. Nothing will print. Run 'MesZebraBridge.exe install' ...` -- which is Global Constraint 6, and is a far better answer than a refused connection, because it names both the fault and the fix. Confirm a bare connect is still silent:

```powershell
(Test-NetConnection 127.0.0.1 -Port 19100).TcpTestSucceeded
```

Expected: `True`, and a `connection from 127.0.0.1 (0 bytes)` line in the log -- an un-commissioned terminal must still answer `validateEndpoint`'s probe with silence.

Now stop it and run it bound to a queue this machine really has, so the other half is exercised:

```powershell
Stop-Process -Name MesZebraBridge
$q = (Get-Printer | Select-Object -First 1).Name
Start-Process -FilePath "zebraPrinter\MesZebraBridge\bin\Debug\MesZebraBridge.exe" -ArgumentList "run","--port","19100","--queue",$q,"--log-dir",$env:TEMP_BRIDGE_LOG
```

Probe it again with the same `?STATUS` snippet.

Expected: `OK bridge=1.0.0 queue='<that queue>' ready=true jobs=0`. **Any local queue will do** -- `?STATUS` prints nothing, so this is safe against a PDF writer. Do not send ZPL to it.

Then check the banner landed in the log and stop it:

```powershell
Get-Content (Join-Path $env:TEMP_BRIDGE_LOG ("bridge-" + (Get-Date -Format 'yyyyMMdd') + ".log"))
Stop-Process -Name MesZebraBridge
```

Expected: the seven banner lines including `binding queue '<that queue>' from the configuration`, `listening on 0.0.0.0:19100`, the `connection from 127.0.0.1` lines, and both replies.

- [ ] **Step 9: Commit**

```bash
git add zebraPrinter/MesZebraBridge/Host.cs zebraPrinter/MesZebraBridge/BridgeService.cs zebraPrinter/MesZebraBridge/Program.cs zebraPrinter/MesZebraBridge/Installer.cs zebraPrinter/MesZebraBridge.Tests/HostTests.cs
git commit -m "feat(bridge): one bootstrap for the service and the console, plus detect and status"
```

---

### Task 13: Self-install, idempotently, plus `set-queue`

Spec § 7 step 4: copy the exe **and its conf file**, run `MesZebraBridge.exe install`. It registers the service, sets its own recovery options, adds its own inbound firewall rule scoped to the Gateway, starts, and **reports the queue it bound** so it can be checked against the `Get-Printer` from step 1.

Four things this task must get right:

- **Detection decides nothing on its own.** Exactly one live Zebra candidate and `install` writes that name into the conf and prints it. Zero or several and it prints the full listing and **exits requiring `--queue "<name>"`** (Global Constraint 5). It never proceeds unbound and never guesses.
- **A missing `GatewayAddress` is a hard refusal**, not a widened rule (spec § 10.1). `BuildFirewallAddArgs` throws on empty or `"any"`; `install` checks first and names the conf file it read.
- **`install` is idempotent** (Global Constraint 13). Against a machine that already has the service it rewrites the conf, reconfigures the service and the rule, and **restarts**. Printers get swapped in service and spec § 7 calls re-commissioning *"the case that needs care"*.
- **`set-queue "<name>"`** is the narrow swap verb: write the conf, restart, print the new binding. It shares `WriteConf` and `RestartService` with `install`, so the two cannot diverge.

Mechanism notes: SCM work goes through `advapi32` P/Invoke rather than `sc.exe`, for real error codes and no output parsing. The firewall rule goes through `netsh advfirewall`, called by **absolute path** from `%SystemRoot%\System32` so nothing on `PATH` can be substituted into an elevated run -- and because the command is one line the operator can read, re-run and verify by hand, which matters for a rule whose absence presented on 2026-09-29 as `DispatchFailed / "Connect timed out"`. The rule is deleted before it is added, because spec § 10.1 wants stale source-scoped rules *"pruned rather than accumulated"* -- the Gateway host still carries one for `10.20.11.106`.

Only the command builders, the refusals and the elevation check are unit-testable; Task 15 exercises the rest against a live install.

**Files:**
- Modify: `zebraPrinter/MesZebraBridge/Installer.cs`
- Create: `zebraPrinter/MesZebraBridge.Tests/InstallerTests.cs`

**Interfaces:**
- Consumes: `BridgeConfig`, `QueueResolver`, `Spooler.EnumerateLocalQueues`, `Host.PrintDetection`
- Produces:
  - `Installer.ServiceName` / `.DisplayName` / `.Description` / `.FirewallRuleName` (consts)
  - `Installer.QuoteArg(string) -> string`
  - `Installer.BuildFirewallAddArgs(string gatewayAddress, int port) -> string`
  - `Installer.BuildFirewallDeleteArgs() -> string`
  - `Installer.NetshPath -> string`, `.ExecutablePath -> string`
  - `Installer.IsElevated() -> bool`
  - `Installer.ResolveQueueForInstall(BridgeConfig, IList<PrinterEntry>, out string message) -> bool`
  - `Installer.Install(string[] args) -> int`, `.SetQueue(string[] args) -> int`, `.Uninstall() -> int`

- [ ] **Step 1: Write the failing tests**

Create `zebraPrinter/MesZebraBridge.Tests/InstallerTests.cs`:

```csharp
// The install verb's decisions and command strings. Pure, so the exact netsh
// arguments and the exact refusals are pinned here -- a missing inbound rule is
// the failure that on 2026-09-29 read as `DispatchFailed / "Connect timed out"`
// and cost most of an afternoon, and a wrongly-scoped one is worse than missing.
//
// CreateService, ChangeServiceConfig2, the real netsh call and the restart need an
// elevated prompt and a real machine; Task 15 covers those.

using System;
using System.Collections.Generic;
using System.IO;
using BlueRidge.MesZebraBridge;
using Xunit;

namespace BlueRidge.MesZebraBridge.Tests
{
    public class InstallerTests
    {
        private static PrinterEntry Q(string name, string driver, string port)
        {
            return new PrinterEntry(name, driver, port, 0, 0);
        }

        private static BridgeConfig Conf(params string[] lines)
        {
            return BridgeConfig.Parse(lines);
        }

        [Fact]
        public void The_service_identity_is_the_one_the_spec_names()
        {
            Assert.Equal("MesZebraBridge", Installer.ServiceName);
            Assert.False(string.IsNullOrEmpty(Installer.DisplayName));
            Assert.Contains("9100", Installer.Description);
            Assert.Contains("9100", Installer.FirewallRuleName);
        }

        [Fact]
        public void An_argument_is_quoted_so_a_queue_name_with_spaces_survives()
        {
            Assert.Equal("\"Zebra GX420d (RAW)\"", Installer.QuoteArg("Zebra GX420d (RAW)"));
            Assert.Equal("\"\"", Installer.QuoteArg(null));
            Assert.Equal("\"a\\\"b\"", Installer.QuoteArg("a\"b"));
        }

        [Fact]
        public void The_firewall_rule_is_inbound_tcp_on_the_port_and_scoped_to_the_gateway()
        {
            string args = Installer.BuildFirewallAddArgs("172.17.10.161", 9100);

            Assert.StartsWith("advfirewall firewall add rule ", args);
            Assert.Contains("dir=in", args);
            Assert.Contains("action=allow", args);
            Assert.Contains("protocol=TCP", args);
            Assert.Contains("localport=9100", args);
            Assert.Contains("remoteip=\"172.17.10.161\"", args);
            Assert.Contains("enable=yes", args);
            Assert.Contains("name=" + Installer.QuoteArg(Installer.FirewallRuleName), args);
            Assert.DoesNotContain("\n", args);
        }

        [Fact]
        public void A_non_default_port_reaches_the_rule()
        {
            Assert.Contains("localport=19100", Installer.BuildFirewallAddArgs("172.17.10.161", 19100));
        }

        [Fact]
        public void The_rule_is_never_left_unscoped_because_an_unscoped_rule_defeats_the_point()
        {
            // 9100 open to the plant is an unauthenticated raw-print listener on 54
            // machines. Refusing beats silently widening.
            Assert.Throws<ArgumentException>(() => Installer.BuildFirewallAddArgs(null, 9100));
            Assert.Throws<ArgumentException>(() => Installer.BuildFirewallAddArgs("", 9100));
            Assert.Throws<ArgumentException>(() => Installer.BuildFirewallAddArgs("   ", 9100));
            Assert.Throws<ArgumentException>(() => Installer.BuildFirewallAddArgs("any", 9100));
            Assert.Throws<ArgumentException>(() => Installer.BuildFirewallAddArgs("ANY", 9100));
        }

        [Fact]
        public void The_delete_args_name_the_same_rule_so_install_is_idempotent()
        {
            string del = Installer.BuildFirewallDeleteArgs();

            Assert.StartsWith("advfirewall firewall delete rule ", del);
            Assert.Contains("name=" + Installer.QuoteArg(Installer.FirewallRuleName), del);
        }

        [Fact]
        public void Netsh_is_called_by_absolute_path_from_system32()
        {
            // Never by bare name: an install runs elevated, and a `netsh.exe`
            // earlier on PATH would then run elevated too.
            Assert.True(Path.IsPathRooted(Installer.NetshPath));
            Assert.EndsWith("netsh.exe", Installer.NetshPath, StringComparison.OrdinalIgnoreCase);
            Assert.True(File.Exists(Installer.NetshPath), "netsh.exe not found at " + Installer.NetshPath);
        }

        [Fact]
        public void The_elevation_check_answers_without_throwing()
        {
            bool elevated = Installer.IsElevated();
            Assert.True(elevated || !elevated);
        }

        // ---- what install decides about the queue -----------------------------

        [Fact]
        public void An_explicit_queue_wins_and_detection_is_not_consulted_at_all()
        {
            // --queue is how the commissioner resolves the ambiguous host, so it
            // must not be second-guessed by a detection result.
            BridgeConfig c = Conf();
            c.SetQueue("Zebra GX420d (RAW)");

            string message;
            bool ok = Installer.ResolveQueueForInstall(c, new List<PrinterEntry>(), out message);

            Assert.True(ok);
            Assert.Equal("Zebra GX420d (RAW)", c.Queue);
            Assert.Contains("Zebra GX420d (RAW)", message);
            Assert.Contains("detection skipped", message);
        }

        [Fact]
        public void Exactly_one_live_candidate_is_written_to_the_conf_and_reported()
        {
            // Spec 7 step 4: install "reports the queue it bound so it can be checked
            // against step 1".
            BridgeConfig c = Conf();

            string message;
            bool ok = Installer.ResolveQueueForInstall(c, new List<PrinterEntry>
            {
                Q("Microsoft Print to PDF", "Microsoft Print To PDF", "PORTPROMPT:"),
                Q("Zebra GX420d (RAW)", "ZDesigner GX420d", "USB002")
            }, out message);

            Assert.True(ok);
            Assert.Equal("Zebra GX420d (RAW)", c.Queue);
            Assert.Contains("Zebra GX420d (RAW)", message);
            Assert.Contains("USB002", message);
        }

        [Fact]
        public void The_real_ambiguous_host_stops_the_install_and_demands_a_name()
        {
            // Two live candidates on USB001 plus a stale LPT1:. install must NOT
            // proceed -- an unbound service that silently picked wrong is worse than
            // a commissioner re-running one command with a name they can see.
            BridgeConfig c = Conf();

            string message;
            bool ok = Installer.ResolveQueueForInstall(c, new List<PrinterEntry>
            {
                Q("ZDesigner GX420d (Copy 1)", "ZDesigner GX420d", "USB001"),
                Q("ZDesigner GX420d", "ZDesigner GX420d", "LPT1:"),
                Q("Zebra GX420d (RAW)", "ZDesigner GX420d", "USB001")
            }, out message);

            Assert.False(ok);
            Assert.Null(c.Queue);
            Assert.Contains("--queue", message);
            Assert.Contains("Zebra GX420d (RAW)", message);
            Assert.Contains("ZDesigner GX420d (Copy 1)", message);
        }

        [Fact]
        public void No_zebra_driver_stops_the_install_and_says_so()
        {
            BridgeConfig c = Conf();

            string message;
            bool ok = Installer.ResolveQueueForInstall(c, new List<PrinterEntry>
            {
                Q("Microsoft Print to PDF", "Microsoft Print To PDF", "PORTPROMPT:")
            }, out message);

            Assert.False(ok);
            Assert.Null(c.Queue);
            Assert.Contains("no Zebra", message);
        }

        [Fact]
        public void A_queue_already_in_the_conf_is_kept_across_a_re_install()
        {
            // Idempotency: re-running install on a commissioned machine must not
            // re-detect and silently move the binding.
            BridgeConfig c = Conf("Queue=Zebra GX420d (RAW)", "GatewayAddress=172.17.10.161");

            string message;
            bool ok = Installer.ResolveQueueForInstall(c, new List<PrinterEntry>
            {
                Q("Some Other Zebra", "ZDesigner GX420d", "USB003")
            }, out message);

            Assert.True(ok);
            Assert.Equal("Zebra GX420d (RAW)", c.Queue);
            Assert.Contains("detection skipped", message);
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```powershell
dotnet test zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj
```

Expected: compile failure, `error CS0117: 'Installer' does not contain a definition for 'DisplayName'`, and the same for `Description`, `FirewallRuleName`, `QuoteArg`, `BuildFirewallAddArgs`, `BuildFirewallDeleteArgs`, `NetshPath`, `IsElevated`, `ResolveQueueForInstall`.

- [ ] **Step 3: Implement `Installer`**

Replace the whole of `zebraPrinter/MesZebraBridge/Installer.cs` with:

```csharp
// Self-install (spec sections 3, 7 and 10.1). Registers the service, sets
// restart-on-failure recovery, writes the conf, adds its own inbound firewall rule
// scoped to the Gateway, starts, and REPORTS THE QUEUE IT BOUND so the commissioner
// can check it against the Get-Printer from spec section 7 step 1.
//
// IDEMPOTENT. Printers get swapped in service and spec section 7 calls
// re-commissioning "the case that needs care, not first commissioning", so running
// install again reconfigures and restarts rather than failing. `set-queue` is the
// narrow verb for the same job; both share WriteConf and RestartService so a first
// install and a swap cannot diverge.
//
// DETECTION DECIDES NOTHING ON ITS OWN (Global Constraint 5). Exactly one live
// candidate and the name goes in the conf; zero or several and install stops and
// requires --queue. An unbound service that silently picked wrong is worse than one
// more command typed by someone who can see both names.
//
// A MISSING GatewayAddress IS A HARD REFUSAL, never a widened rule (spec 10.1).
//
// SCM work goes through advapi32 rather than sc.exe, for real error codes and no
// output parsing. The firewall rule goes through netsh advfirewall, called by
// ABSOLUTE PATH from System32 so nothing on PATH can be substituted into an
// elevated run -- and because the command is one line the operator can read,
// re-run and verify, which matters for a rule whose absence presented on
// 2026-09-29 as `DispatchFailed / "Connect timed out"`.

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.ServiceProcess;

namespace BlueRidge.MesZebraBridge
{
    public static class Installer
    {
        public const string ServiceName = "MesZebraBridge";
        public const string DisplayName = "MES Zebra Bridge";

        public const string Description =
            "Accepts ZPL on TCP 9100 from the Ignition Gateway and spools it to the local "
            + "Zebra print queue using the RAW datatype. Blue Ridge Automation.";

        public const string FirewallRuleName = "MES Zebra Bridge (TCP 9100 inbound)";

        private const string FirewallRuleDescription =
            "Inbound raw-print from the Ignition Gateway only. Added by MesZebraBridge.exe install.";

        // --- SCM ---------------------------------------------------------------

        private const uint SC_MANAGER_ALL_ACCESS = 0x000F003F;
        private const uint SERVICE_ALL_ACCESS = 0x000F01FF;
        private const uint SERVICE_WIN32_OWN_PROCESS = 0x00000010;
        private const uint SERVICE_AUTO_START = 0x00000002;
        private const uint SERVICE_ERROR_NORMAL = 0x00000001;

        private const int SERVICE_CONFIG_DESCRIPTION = 1;
        private const int SERVICE_CONFIG_FAILURE_ACTIONS = 2;
        private const int SC_ACTION_RESTART = 1;

        private const int ERROR_SERVICE_EXISTS = 1073;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct SERVICE_DESCRIPTION
        {
            [MarshalAs(UnmanagedType.LPWStr)] public string lpDescription;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SC_ACTION
        {
            public int Type;
            public uint Delay;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct SERVICE_FAILURE_ACTIONS
        {
            public uint dwResetPeriod;
            public IntPtr lpRebootMsg;
            public IntPtr lpCommand;
            public uint cActions;
            public IntPtr lpsaActions;
        }

        [DllImport("advapi32.dll", EntryPoint = "OpenSCManagerW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr OpenSCManager(string machineName, string databaseName, uint access);

        [DllImport("advapi32.dll", EntryPoint = "CreateServiceW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateService(IntPtr scManager, string serviceName, string displayName,
            uint access, uint serviceType, uint startType, uint errorControl, string binaryPath,
            string loadOrderGroup, IntPtr tagId, string dependencies, string serviceStartName, string password);

        [DllImport("advapi32.dll", EntryPoint = "OpenServiceW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr OpenService(IntPtr scManager, string serviceName, uint access);

        [DllImport("advapi32.dll", EntryPoint = "ChangeServiceConfig2W", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool ChangeServiceConfig2(IntPtr service, int infoLevel, IntPtr info);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool DeleteService(IntPtr service);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool CloseServiceHandle(IntPtr handle);

        // --- helpers -----------------------------------------------------------

        public static string NetshPath
        {
            get
            {
                return Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.System), "netsh.exe");
            }
        }

        public static string ExecutablePath
        {
            get { return Assembly.GetExecutingAssembly().Location; }
        }

        public static bool IsElevated()
        {
            try
            {
                using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
                    return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
            }
            catch (Exception)
            {
                return false;
            }
        }

        public static string QuoteArg(string value)
        {
            return "\"" + (value ?? "").Replace("\"", "\\\"") + "\"";
        }

        public static string BuildFirewallAddArgs(string gatewayAddress, int port)
        {
            string address = (gatewayAddress ?? "").Trim();
            if (address.Length == 0 || address.Equals("any", StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException(
                    "a scoped Gateway address is required -- an unscoped rule would leave an "
                    + "unauthenticated raw-print listener open to the plant", "gatewayAddress");

            return string.Format(
                "advfirewall firewall add rule name={0} dir=in action=allow protocol=TCP "
                + "localport={1} remoteip={2} profile=any enable=yes description={3}",
                QuoteArg(FirewallRuleName), port, QuoteArg(address), QuoteArg(FirewallRuleDescription));
        }

        public static string BuildFirewallDeleteArgs()
        {
            return "advfirewall firewall delete rule name=" + QuoteArg(FirewallRuleName);
        }

        private static int Netsh(string arguments)
        {
            var psi = new ProcessStartInfo(NetshPath, arguments)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };

            using (Process p = Process.Start(psi))
            {
                string stdout = p.StandardOutput.ReadToEnd();
                string stderr = p.StandardError.ReadToEnd();
                p.WaitForExit();

                string text = (stdout + " " + stderr).Trim();
                if (text.Length > 0) Console.WriteLine("  netsh: " + Protocol.OneLine(text));
                return p.ExitCode;
            }
        }

        /// <summary>
        /// Decide the queue name for an install. Returns false when the operator has
        /// to name it, with `message` explaining exactly what was seen.
        ///
        /// An already-configured name (conf or --queue) is kept and detection is not
        /// consulted: re-running install on a commissioned machine must not silently
        /// move the binding, and --queue is how the ambiguous host gets resolved.
        /// </summary>
        public static bool ResolveQueueForInstall(BridgeConfig config,
                                                  IList<PrinterEntry> queues,
                                                  out string message)
        {
            if (!string.IsNullOrEmpty(config.Queue))
            {
                message = "queue " + Protocol.Quote(config.Queue)
                    + " from the configuration / --queue; detection skipped";
                return true;
            }

            QueueResolution r = QueueResolver.Select(queues);
            if (r.Resolved)
            {
                config.SetQueue(r.Queue);
                message = "detected " + r.Diagnosis;
                return true;
            }

            message = r.Diagnosis;
            return false;
        }

        // --- verbs -------------------------------------------------------------

        public static int Install(string[] args)
        {
            if (!IsElevated())
            {
                Console.Error.WriteLine(
                    "install needs an elevated prompt. Right-click Command Prompt or PowerShell, "
                    + "choose 'Run as administrator', and run it again.");
                return 3;
            }

            string confPath = BridgeConfig.ConfPathFromCommandLine(args);
            BridgeConfig config = BridgeConfig.Load(confPath);
            config.ApplyCommandLine(args);
            foreach (string w in config.Warnings) Console.WriteLine("CONFIG WARNING " + w);

            Console.WriteLine("MesZebraBridge {0} install", Protocol.BridgeVersion);
            Console.WriteLine("  binary   {0}", ExecutablePath);
            Console.WriteLine("  conf     {0}", confPath);
            Console.WriteLine("  account  LocalSystem");
            Console.WriteLine("  port     {0}", config.Port);
            Console.WriteLine();

            // 1. The Gateway address. A hard refusal, never a widened rule (spec 10.1).
            if (string.IsNullOrEmpty(config.GatewayAddress))
            {
                Console.Error.WriteLine(
                    "REFUSING: no GatewayAddress. Nothing is compiled into this binary, so the "
                    + "inbound firewall rule has no source to scope to, and an unscoped rule "
                    + "would leave an unauthenticated raw-print listener open to the plant.");
                Console.Error.WriteLine();
                Console.Error.WriteLine("Fix either way:");
                Console.Error.WriteLine("  * add   GatewayAddress=172.17.10.161   to {0}", confPath);
                Console.Error.WriteLine("    (that is the conf file that ships beside the exe -- check it was copied)");
                Console.Error.WriteLine("  * or run  MesZebraBridge.exe install --gateway 172.17.10.161");
                return 4;
            }
            Console.WriteLine("  gateway  {0}   <-- the ONLY source the firewall rule will admit",
                config.GatewayAddress);
            Console.WriteLine();

            // 2. The queue. Detection offers a name; it never decides alone.
            IList<PrinterEntry> queues;
            try
            {
                queues = Spooler.EnumerateLocalQueues();
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("could not enumerate local print queues: "
                                        + Protocol.OneLine(ex.Message));
                return 1;
            }

            string queueMessage;
            if (!ResolveQueueForInstall(config, queues, out queueMessage))
            {
                Console.Error.WriteLine("REFUSING: " + queueMessage);
                Console.Error.WriteLine();
                Host.PrintDetection();
                Console.Error.WriteLine();
                Console.Error.WriteLine(
                    "Nothing was installed. Pick the queue from the list above -- it is the one "
                    + "'Get-Printer' showed you in step 1 -- and run:");
                Console.Error.WriteLine("  MesZebraBridge.exe install --queue \"<exact queue name>\"");
                return 5;
            }
            Console.WriteLine("queue    {0}", queueMessage);
            Console.WriteLine();

            // 3. Write the conf, so `status` reads back exactly what this install decided.
            if (!WriteConf(config, confPath)) return 1;

            // 4. Register, or reconfigure if it is already there (idempotent).
            if (!RegisterService(ExecutablePath)) return 1;

            // 5. The inbound rule. Delete first so re-running install prunes the old
            //    scoping instead of accumulating rules (spec 10.1).
            Netsh(BuildFirewallDeleteArgs());
            int rc = Netsh(BuildFirewallAddArgs(config.GatewayAddress, config.Port));
            if (rc != 0)
            {
                Console.Error.WriteLine("netsh add rule failed with exit code " + rc
                    + " -- the service is installed but the Gateway will see 'Connect timed out'.");
                return 1;
            }
            Console.WriteLine("firewall rule {0} -> allow TCP {1} inbound from {2}",
                FirewallRuleName, config.Port, config.GatewayAddress);

            // 6. Start, or restart if it was already running with the old conf.
            if (!RestartService()) return 1;

            Console.WriteLine();
            Console.WriteLine("BOUND QUEUE: {0}", config.Queue);
            Console.WriteLine("Check that against the 'Get-Printer' from step 1, then verify from");
            Console.WriteLine("the Gateway with a ?STATUS probe (spec section 9) and one real label.");
            Console.WriteLine("'MesZebraBridge.exe status' reports state here.");
            return 0;
        }

        /// <summary>
        /// The printer-swap verb. Same conf write and same restart as install, no SCM
        /// or firewall work -- so a swap cannot drift from a first install.
        /// </summary>
        public static int SetQueue(string[] args)
        {
            if (!IsElevated())
            {
                Console.Error.WriteLine("set-queue needs an elevated prompt (it restarts the service).");
                return 3;
            }

            string name = null;
            for (int i = 1; i < args.Length; i++)
            {
                if (args[i].StartsWith("--")) { i++; continue; }   // skip --conf <path> etc.
                name = args[i];
                break;
            }

            if (string.IsNullOrEmpty((name ?? "").Trim()))
            {
                Console.Error.WriteLine("usage: MesZebraBridge.exe set-queue \"<exact queue name>\"");
                Console.Error.WriteLine();
                Console.Error.WriteLine("Run 'MesZebraBridge.exe detect' to list this machine's queues.");
                return 2;
            }

            string confPath = BridgeConfig.ConfPathFromCommandLine(args);
            BridgeConfig config = BridgeConfig.Load(confPath);
            foreach (string w in config.Warnings) Console.WriteLine("CONFIG WARNING " + w);

            string previous = config.Queue == null ? "(none)" : config.Queue;
            config.SetQueue(name);

            if (!WriteConf(config, confPath)) return 1;
            Console.WriteLine("queue {0} -> {1}", previous, config.Queue);

            if (!RestartService()) return 1;

            Console.WriteLine();
            Console.WriteLine("BOUND QUEUE: {0}", config.Queue);
            Console.WriteLine("Probe it with ?STATUS to confirm the new binding.");
            Console.WriteLine();
            Console.WriteLine("If this terminal already has an operator session running, restart the");
            Console.WriteLine("workstation session too: session.custom.printer resolved once at its");
            Console.WriteLine("startup and will keep printing to the old endpoint (spec section 7).");
            return 0;
        }

        private static bool WriteConf(BridgeConfig config, string confPath)
        {
            try
            {
                config.Save(confPath);
                Console.WriteLine("wrote {0}", confPath);
                return true;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("could not write " + confPath + ": " + Protocol.OneLine(ex.Message));
                return false;
            }
        }

        /// <summary>Start it, or stop-then-start so a new conf is actually picked up.</summary>
        private static bool RestartService()
        {
            try
            {
                using (var sc = new ServiceController(ServiceName))
                {
                    if (sc.Status != ServiceControllerStatus.Stopped)
                    {
                        sc.Stop();
                        sc.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(30));
                    }
                    sc.Start();
                    sc.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(30));
                    Console.WriteLine("service {0} is {1}", ServiceName, sc.Status);
                }
                return true;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("the service did not come back up: " + Protocol.OneLine(ex.Message));
                Console.Error.WriteLine("check the log directory and the Windows Event Log.");
                return false;
            }
        }

        private static bool RegisterService(string exePath)
        {
            IntPtr scm = OpenSCManager(null, null, SC_MANAGER_ALL_ACCESS);
            if (scm == IntPtr.Zero)
            {
                Console.Error.WriteLine("OpenSCManager failed: " + Win32Text(Marshal.GetLastWin32Error()));
                return false;
            }

            IntPtr service = IntPtr.Zero;
            try
            {
                service = CreateService(scm, ServiceName, DisplayName, SERVICE_ALL_ACCESS,
                    SERVICE_WIN32_OWN_PROCESS, SERVICE_AUTO_START, SERVICE_ERROR_NORMAL,
                    QuoteArg(exePath),
                    null, IntPtr.Zero, null,
                    null,    // lpServiceStartName = null -> LocalSystem (spec open item 12.3)
                    null);

                if (service == IntPtr.Zero)
                {
                    int err = Marshal.GetLastWin32Error();
                    if (err != ERROR_SERVICE_EXISTS)
                    {
                        Console.Error.WriteLine("CreateService failed: " + Win32Text(err));
                        return false;
                    }

                    // Idempotent: a re-install reconfigures rather than failing.
                    Console.WriteLine("service {0} already exists -- reconfiguring it", ServiceName);
                    service = OpenService(scm, ServiceName, SERVICE_ALL_ACCESS);
                    if (service == IntPtr.Zero)
                    {
                        Console.Error.WriteLine("OpenService failed: " + Win32Text(Marshal.GetLastWin32Error()));
                        return false;
                    }
                }
                else
                {
                    Console.WriteLine("registered service {0} ({1}), start=auto, account=LocalSystem",
                        ServiceName, DisplayName);
                }

                SetDescription(service);
                SetFailureActions(service);
                return true;
            }
            finally
            {
                if (service != IntPtr.Zero) CloseServiceHandle(service);
                CloseServiceHandle(scm);
            }
        }

        private static void SetDescription(IntPtr service)
        {
            var desc = new SERVICE_DESCRIPTION { lpDescription = Description };
            IntPtr block = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(SERVICE_DESCRIPTION)));
            try
            {
                Marshal.StructureToPtr(desc, block, false);
                if (!ChangeServiceConfig2(service, SERVICE_CONFIG_DESCRIPTION, block))
                    Console.Error.WriteLine("could not set the service description: "
                        + Win32Text(Marshal.GetLastWin32Error()));
            }
            finally
            {
                Marshal.FreeHGlobal(block);
            }
        }

        /// <summary>
        /// Restart on failure (spec section 3). On 2026-09-29 the Python bridge died
        /// mid-job and stayed dead; across 54 unattended PCs that reaches us as
        /// "the printer is broken." 5s, 5s, then 60s, with the failure count
        /// resetting after a day.
        /// </summary>
        private static void SetFailureActions(IntPtr service)
        {
            var actions = new[]
            {
                new SC_ACTION { Type = SC_ACTION_RESTART, Delay = 5000 },
                new SC_ACTION { Type = SC_ACTION_RESTART, Delay = 5000 },
                new SC_ACTION { Type = SC_ACTION_RESTART, Delay = 60000 }
            };

            int actionSize = Marshal.SizeOf(typeof(SC_ACTION));
            IntPtr actionArray = Marshal.AllocHGlobal(actionSize * actions.Length);
            IntPtr block = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(SERVICE_FAILURE_ACTIONS)));
            try
            {
                for (int i = 0; i < actions.Length; i++)
                    Marshal.StructureToPtr(actions[i], new IntPtr(actionArray.ToInt64() + i * actionSize), false);

                var failure = new SERVICE_FAILURE_ACTIONS
                {
                    dwResetPeriod = 86400,
                    lpRebootMsg = IntPtr.Zero,
                    lpCommand = IntPtr.Zero,
                    cActions = (uint)actions.Length,
                    lpsaActions = actionArray
                };

                Marshal.StructureToPtr(failure, block, false);
                if (ChangeServiceConfig2(service, SERVICE_CONFIG_FAILURE_ACTIONS, block))
                    Console.WriteLine("recovery: restart after 5s, 5s, then 60s; count resets after 24h");
                else
                    Console.Error.WriteLine("could not set recovery actions: "
                        + Win32Text(Marshal.GetLastWin32Error()));
            }
            finally
            {
                Marshal.FreeHGlobal(block);
                Marshal.FreeHGlobal(actionArray);
            }
        }

        public static int Uninstall()
        {
            if (!IsElevated())
            {
                Console.Error.WriteLine("uninstall needs an elevated prompt.");
                return 3;
            }

            try
            {
                using (var sc = new ServiceController(ServiceName))
                {
                    if (sc.Status != ServiceControllerStatus.Stopped)
                    {
                        sc.Stop();
                        sc.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(30));
                    }
                    Console.WriteLine("service {0} is {1}", ServiceName, sc.Status);
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine("could not stop the service (continuing): " + Protocol.OneLine(ex.Message));
            }

            IntPtr scm = OpenSCManager(null, null, SC_MANAGER_ALL_ACCESS);
            if (scm == IntPtr.Zero)
            {
                Console.Error.WriteLine("OpenSCManager failed: " + Win32Text(Marshal.GetLastWin32Error()));
                return 1;
            }
            try
            {
                IntPtr service = OpenService(scm, ServiceName, SERVICE_ALL_ACCESS);
                if (service == IntPtr.Zero)
                {
                    Console.WriteLine("service {0} is not installed", ServiceName);
                }
                else
                {
                    try
                    {
                        if (DeleteService(service)) Console.WriteLine("removed service " + ServiceName);
                        else Console.Error.WriteLine("DeleteService failed: "
                            + Win32Text(Marshal.GetLastWin32Error()));
                    }
                    finally
                    {
                        CloseServiceHandle(service);
                    }
                }
            }
            finally
            {
                CloseServiceHandle(scm);
            }

            // Prune the rule rather than leaving it behind (spec 10.1).
            Netsh(BuildFirewallDeleteArgs());
            Console.WriteLine("removed firewall rule {0}", FirewallRuleName);
            Console.WriteLine();
            Console.WriteLine("The conf file and {0} were left in place.",
                BridgeConfig.DefaultLogDirectory);
            return 0;
        }

        private static string Win32Text(int err)
        {
            return string.Format("[{0}] {1}", err, Protocol.OneLine(new Win32Exception(err).Message));
        }
    }
}
```

- [ ] **Step 4: Wire the `set-queue` verb into `Program`**

In `zebraPrinter/MesZebraBridge/Program.cs`, add the case beside `install`:

```csharp
                case "install":   return Installer.Install(args);
                case "set-queue": return Installer.SetQueue(args);
                case "uninstall": return Installer.Uninstall();
```

Task 12 already put `set-queue` and `--conf` in `Program.Usage`, and `HostTests.The_usage_text_names_every_verb_and_every_option` asserts they are there.

- [ ] **Step 5: Run the tests to verify they pass**

```powershell
dotnet test zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj
```

Expected: `Failed: 0, Passed: 109`.

- [ ] **Step 6: Confirm the refusal paths without installing anything**

From a **non-elevated** prompt:

```powershell
dotnet build zebraPrinter/MesZebraBridge/MesZebraBridge.csproj -c Debug
Copy-Item zebraPrinter\MesZebraBridge.conf zebraPrinter\MesZebraBridge\bin\Debug\
.\zebraPrinter\MesZebraBridge\bin\Debug\MesZebraBridge.exe install
echo "exit=$LASTEXITCODE"
```

Expected: the elevation refusal text and `exit=3`. Nothing is registered, no rule is added.

Then prove the missing-gateway refusal, which is the one that must never silently widen:

```powershell
$alt = Join-Path $env:TEMP "no-gateway.conf"
"Port=9100" | Set-Content -Encoding ascii $alt
.\zebraPrinter\MesZebraBridge\bin\Debug\MesZebraBridge.exe install --conf $alt
echo "exit=$LASTEXITCODE"
```

Expected on an elevated prompt: `REFUSING: no GatewayAddress`, the two suggested fixes naming the conf path, and `exit=4`. From a non-elevated prompt the elevation refusal fires first (`exit=3`) -- run this one elevated to see it, and **only** with `--conf` pointed at the temp file so the real conf is untouched.

```powershell
.\zebraPrinter\MesZebraBridge\bin\Debug\MesZebraBridge.exe detect
.\zebraPrinter\MesZebraBridge\bin\Debug\MesZebraBridge.exe status
.\zebraPrinter\MesZebraBridge\bin\Debug\MesZebraBridge.exe set-queue
.\zebraPrinter\MesZebraBridge\bin\Debug\MesZebraBridge.exe wat
```

Expected: `detect` lists this machine's queues with the verdict; `status` prints the banner and `MesZebraBridge is NOT INSTALLED`; `set-queue` with no name prints its usage and exits 2 (or 3 unelevated); `wat` prints `unknown verb: wat` plus usage and exits 2.

**Do not run a real `install` here** -- it would bind 9100, which other work is using.

- [ ] **Step 7: Commit**

```bash
git add zebraPrinter/MesZebraBridge/Installer.cs zebraPrinter/MesZebraBridge/Program.cs zebraPrinter/MesZebraBridge.Tests/InstallerTests.cs
git commit -m "feat(bridge): install is idempotent, reports the queue it bound, and refuses an unscoped rule"
```

---

### Task 14: The release build, the two-file check, and the binary hash

The deployment is **`MesZebraBridge.exe` plus `MesZebraBridge.conf`, and nothing else** (spec § 7 step 4). This task **proves** that rather than assuming it -- a stray DLL in `bin/Release` turns a copy-two-files install into a copy-a-folder install, and nobody notices until a machine is missing one. It also produces the SHA-256 that spec § 12.4 needs: with no code-signing certificate, a hash is what MPP IT can allowlist against SmartScreen and AV heuristics.

**Files:**
- Create: `zebraPrinter/MesZebraBridge/RELEASE.md`
- Create: `zebraPrinter/MesZebraBridge.Tests/AssemblyMetadataTests.cs`

**Interfaces:**
- Consumes: everything from Tasks 1-13
- Produces: `zebraPrinter/MesZebraBridge/bin/Release/MesZebraBridge.exe` (gitignored) plus its recorded hash and a per-machine deployment sheet

- [ ] **Step 1: Write the failing test**

Create `zebraPrinter/MesZebraBridge.Tests/AssemblyMetadataTests.cs`:

```csharp
// The binary has to identify itself. With no Authenticode signature (spec open
// item 12.4), the assembly metadata plus a recorded hash is all a plant PC's
// Properties dialog and MPP IT's allowlist have to go on.

using System.Diagnostics;
using System.Reflection;
using BlueRidge.MesZebraBridge;
using Xunit;

namespace BlueRidge.MesZebraBridge.Tests
{
    public class AssemblyMetadataTests
    {
        private static FileVersionInfo BridgeFileInfo()
        {
            Assembly bridge = typeof(Protocol).Assembly;
            return FileVersionInfo.GetVersionInfo(bridge.Location);
        }

        [Fact]
        public void The_assembly_names_the_company_the_product_and_the_version()
        {
            FileVersionInfo info = BridgeFileInfo();

            Assert.Equal("Blue Ridge Automation", info.CompanyName);
            Assert.Equal("MES Zebra Bridge", info.ProductName);
            Assert.StartsWith(Protocol.BridgeVersion, info.FileVersion);
        }

        [Fact]
        public void The_assembly_file_version_tracks_the_protocol_version()
        {
            // A bridge whose exe says 1.0.0 must be the one that answers
            // `bridge=1.0.0`, or a commissioning report means nothing.
            FileVersionInfo info = BridgeFileInfo();
            Assert.Equal(Protocol.BridgeVersion, info.FileMajorPart + "." + info.FileMinorPart + "." + info.FileBuildPart);
        }

        [Fact]
        public void The_bridge_assembly_references_no_third_party_dependency()
        {
            // The two-file deployment depends on this. A PackageReference that
            // lands a DLL in bin/ makes "copy the exe and its conf" a broken install.
            foreach (AssemblyName reference in typeof(Protocol).Assembly.GetReferencedAssemblies())
            {
                bool bcl = reference.Name == "mscorlib"
                        || reference.Name == "System"
                        || reference.Name.StartsWith("System.");
                Assert.True(bcl, "unexpected dependency: " + reference.Name);
            }
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they pass or tell you what is missing**

```powershell
dotnet test zebraPrinter/MesZebraBridge.Tests/MesZebraBridge.Tests.csproj
```

Expected: `Failed: 0, Passed: 112`. Task 1's csproj already sets the metadata, so these should be green; a failure here means a `PackageReference` crept in or a property was dropped.

- [ ] **Step 3: Build Release and prove the output is two deployable files, not a folder**

```powershell
dotnet build zebraPrinter/MesZebraBridge/MesZebraBridge.csproj -c Release
Get-ChildItem zebraPrinter\MesZebraBridge\bin\Release | Select-Object Name, Length
```

Expected: exactly `MesZebraBridge.exe` and `MesZebraBridge.pdb`, and **no `.dll` and no `MesZebraBridge.exe.config`**. If a `.config` appears, `AutoGenerateBindingRedirects` is not `false`. If any `.dll` appears, a `PackageReference` is missing `PrivateAssets="All"` -- fix the csproj, do not ship the folder.

The conf file is authored separately (Task 10) and is the second deployed file; the `.pdb` is optional at the target and is only worth copying when a stack trace with line numbers is wanted.

- [ ] **Step 4: Confirm the pair works with nothing else present**

```powershell
$probe = Join-Path $env:TEMP ("bridge-deploy-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory $probe | Out-Null
Copy-Item zebraPrinter\MesZebraBridge\bin\Release\MesZebraBridge.exe $probe
Copy-Item zebraPrinter\MesZebraBridge.conf $probe
& (Join-Path $probe "MesZebraBridge.exe") detect
& (Join-Path $probe "MesZebraBridge.exe") status
Remove-Item -Recurse -Force $probe
```

Expected: `detect` lists the queues and its verdict. `status` reads the conf **from that directory** and prints `gateway 172.17.10.161`, `queue (none)` and `conf <$probe>\MesZebraBridge.conf`. A `FileNotFoundException` for an assembly means the deployment is not two files; a `conf` line pointing anywhere other than `$probe` means `BridgeConfig.DefaultPath` is not resolving beside the executable.

- [ ] **Step 5: Record the hash and write the deployment sheet**

```powershell
Get-FileHash zebraPrinter\MesZebraBridge\bin\Release\MesZebraBridge.exe -Algorithm SHA256 | Format-List
(Get-Item zebraPrinter\MesZebraBridge\bin\Release\MesZebraBridge.exe).Length
```

Create `zebraPrinter/MesZebraBridge/RELEASE.md`, replacing `<...>` with what the two commands printed:

```markdown
# MesZebraBridge -- release record

Wire protocol: `zebraPrinter/PROTOCOL.md` v1.0.0.
Spec: `docs/superpowers/specs/2026-09-29-zebra-bridge-service-and-print-traceability-design.md`.

## 1.0.0

| | |
|---|---|
| Built | <date> from commit `<short sha>` |
| Target | .NET Framework 4.8 (`net48`), AnyCPU |
| Toolchain | .NET SDK <version>, `Microsoft.NETFramework.ReferenceAssemblies` 1.0.3 |
| Size | <bytes> bytes |
| SHA-256 | `<hash>` |
| Signed | **No.** Spec open item 12.4 is unresolved -- this hash is what MPP IT can allowlist in the meantime. |
| Service account | `LocalSystem`. Spec open item 12.3, assumption stated in the plan's Global Constraints. |

Rebuild:

    dotnet build zebraPrinter/MesZebraBridge/MesZebraBridge.csproj -c Release

`bin/Release/` must contain only `MesZebraBridge.exe` and `MesZebraBridge.pdb`.

## What gets copied to a machine

**Two files, same pair on all 54 machines:**

| File | Per machine? |
|---|---|
| `MesZebraBridge.exe` | identical everywhere |
| `MesZebraBridge.conf` | identical everywhere as shipped -- it carries `GatewayAddress=172.17.10.161` and no queue. `install` adds this machine's `Queue=` line. |

Nothing is compiled into the exe (spec section 10.1). The Gateway address is in the
conf, authored once, never typed per machine. If it is ever wrong, it is wrong
visibly in a text file rather than invisibly in a binary.

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
re-checking the service and firewall rule.

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
```

- [ ] **Step 6: Commit**

```bash
git add zebraPrinter/MesZebraBridge/RELEASE.md zebraPrinter/MesZebraBridge.Tests/AssemblyMetadataTests.cs
git commit -m "docs(bridge): record the 1.0.0 release hash and the per-machine deployment sheet"
```

---

### Task 15: Verify against the real printer and the real Gateway

The tests prove the protocol. Only hardware proves the spooler path, and only the
network proves the exchange -- `PROTOCOL.md` § "Not yet verified" lists both gaps
explicitly, including *"The exchange over the network, Gateway host to a remote
bridge."*

**This task runs at the machine with the Zebra attached, and it is the only task
that touches port 9100.** Do not start it while another workstream is using 9100.

**Files:**
- Modify: `zebraPrinter/PROTOCOL.md` (append to § Verified only -- **no change to any normative section**)
- Modify: `zebraPrinter/MesZebraBridge/RELEASE.md` (record the verified host)

**Interfaces:**
- Consumes: the release binary from Task 14
- Produces: the evidence that `MesZebraBridge` reproduces the Python bridge's verified exchanges, which is what lets spec § 2 call the Python script superseded

- [ ] **Step 1: Read the queue name first, the way a commissioner does**

Spec § 7 step 1. Everything after this is checked against what it prints.

```powershell
Get-Printer | Select-Object Name, DriverName, PortName
```

Write down the exact name of the queue actually in use. If this host is the one with three candidates, **record all three with their ports** -- that listing is the evidence behind Global Constraint 5 and is worth keeping.

- [ ] **Step 2: Confirm 9100 is free, and that both files are present, then install**

On the printer host, from an **elevated** prompt:

```powershell
Get-NetTCPConnection -LocalPort 9100 -ErrorAction SilentlyContinue
Get-ChildItem . | Select-Object Name
```

Expected: no connection on 9100, and **both** `MesZebraBridge.exe` and `MesZebraBridge.conf` in the folder. If the Python bridge is still running, stop it first -- with `SO_EXCLUSIVEADDRUSE` our `install` would otherwise fail its start with a bind error, which is the option working as intended.

```powershell
.\MesZebraBridge.exe install
```

Expected, in order: the header naming the binary, the conf path, `account LocalSystem` and the gateway address; then `queue ...`, `wrote <folder>\MesZebraBridge.conf`, `registered service MesZebraBridge`, `recovery: restart after 5s, 5s, then 60s`, `firewall rule ... -> allow TCP 9100 inbound from 172.17.10.161`, `service MesZebraBridge is Running`, and finally **`BOUND QUEUE: <name>`**.

**Check `BOUND QUEUE` against the name from Step 1.** That comparison is the whole reason spec § 7 step 4 asks install to report it.

Two outcomes are also correct and must be recorded rather than worked around:

- **It refuses with `no GatewayAddress`** -- the conf file was not copied beside the exe. Copy it and re-run; do **not** pass `--gateway` to get past it, or the next machine hides the same mistake.
- **It refuses and lists several Zebra candidates** -- exactly the observed three-candidate case. Re-run naming the one from Step 1:

  ```powershell
  .\MesZebraBridge.exe install --queue "<exact queue name>"
  ```

  Confirm nothing was installed by the refused run (`Get-Service MesZebraBridge` should error), then confirm the second run reports the name you gave it.

- [ ] **Step 3: Confirm `status` reads back what install decided**

```powershell
.\MesZebraBridge.exe status
```

Expected: `queue <name>`, `binding queue '<name>' from the configuration`, `conf <folder>\MesZebraBridge.conf`, `gateway 172.17.10.161`, `service MesZebraBridge is Running`, and `spooler queue '<name>' ready=true jobs=0`.

This is the one command to run on any machine later that somebody reports as "the printer is broken".

- [ ] **Step 4: Probe locally, consuming no label**

```powershell
$c = New-Object Net.Sockets.TcpClient('127.0.0.1', 9100)
$s = $c.GetStream()
$b = [Text.Encoding]::ASCII.GetBytes('?STATUS')
$s.Write($b, 0, $b.Length); $s.Flush(); $c.Client.Shutdown('Send')
(New-Object IO.StreamReader($s)).ReadLine()
$c.Close()
```

Expected: `OK bridge=1.0.0 queue='ZDesigner GX420d' ready=true jobs=0` -- byte for byte the line `PROTOCOL.md` § Verified records for the Python bridge. **No label prints.**

- [ ] **Step 5: Print one label locally and read the ACK**

```powershell
$c = New-Object Net.Sockets.TcpClient('127.0.0.1', 9100)
$s = $c.GetStream()
$b = [Text.Encoding]::ASCII.GetBytes('^XA^CFA,30^FO50,50^FDMESZEBRABRIDGE^FS^XZ')
$s.Write($b, 0, $b.Length); $s.Flush(); $c.Client.Shutdown('Send')
(New-Object IO.StreamReader($s)).ReadLine()
$c.Close()
```

Expected: `OK queue='ZDesigner GX420d' job=<n> bytes=41`, with `<n>` a non-zero spooler job id, and a label reading `MESZEBRABRIDGE` physically emerging.

Confirm the job id is the spooler's own, not ours:

```powershell
Get-PrintJob -PrinterName 'ZDesigner GX420d' | Select-Object Id, DocumentName, Size
```

Expected: an entry whose `Id` matches `<n>` and whose `DocumentName` is `MES ZPL`. If the job has already completed it will not be listed -- re-run with the printer paused to catch it.

**If `job=0`**, `StartDocPrinterW`'s return is not the job id under this marshaling. Record that and stop: shipping a zero would make every `InterfaceLog` row's `job=` meaningless.

- [ ] **Step 6: Confirm the bare-connect probe still prints nothing**

```powershell
(Test-NetConnection 127.0.0.1 -Port 9100).TcpTestSucceeded
```

Expected: `True`, a `connection from 127.0.0.1 (0 bytes)` line in the log, and **no label**. This is the behaviour `BlueRidge.Location.Printer.validateEndpoint` depends on.

- [ ] **Step 7: Close the network gap `PROTOCOL.md` names**

From the **Gateway host whose address the firewall rule admits** -- `172.17.10.161`, the plant Gateway (spec § 10.1) -- against the printer host. Substitute the printer host's real address for `<printer-host>` throughout.

**The rule is scoped, so this only works from that host.** Running it from anywhere else times out, and that is the rule doing its job -- worth trying from a second machine once, so the difference between `Connect timed out` (scoped out) and `Connection refused` (nothing listening) is one you have seen rather than read about.

```powershell
$c = New-Object Net.Sockets.TcpClient('<printer-host>', 9100)
$s = $c.GetStream()
$b = [Text.Encoding]::ASCII.GetBytes('?STATUS')
$s.Write($b, 0, $b.Length); $s.Flush(); $c.Client.Shutdown('Send')
(New-Object IO.StreamReader($s)).ReadLine()
$c.Close()
```

Expected: the same `OK bridge=1.0.0 queue='...' ready=true jobs=0`. This is the **first time this protocol has crossed the network** -- `PROTOCOL.md` § "Not yet verified" says raw TCP reachability was proven on 2026-09-29 but not carrying this protocol.

Then from the Designer Script Console on that Gateway:

```python
print BlueRidge.Lots.LabelTransport.send("<printer-host>:9100",
    "^XA^CFA,30^FO50,50^FDGATEWAY TO BRIDGE^FS^XZ")
```

Expected: a result carrying the parsed ACK with `job` and `bytes`, a label emerging, and a `Spooled queue='...' job=<n> bytes=<m>` row in `Audit.InterfaceLog` (spec § 6.3). **This step only reads and dispatches -- it changes no schema and no Ignition resource.**

- [ ] **Step 8: Prove the recovery actions, which are the reason for a service at all**

```powershell
Stop-Process -Name MesZebraBridge -Force
Start-Sleep -Seconds 12
Get-Service MesZebraBridge | Select-Object Status
```

Expected: `Running`. On 2026-09-29 the Python bridge *"exited on a queued Ctrl-C ... consumed the print job it was mid-way through handling, and stayed dead"* (spec § 3). This is the one-line proof that no longer happens.

Then confirm the bridge still answers:

```powershell
(Test-NetConnection 127.0.0.1 -Port 9100).TcpTestSucceeded
```

Expected: `True`, and a fresh banner in today's log from the restart.

- [ ] **Step 9: Confirm the firewall rule is scoped and not duplicated**

```powershell
Get-NetFirewallRule -DisplayName "MES Zebra Bridge (TCP 9100 inbound)" |
  Get-NetFirewallAddressFilter | Select-Object RemoteAddress
(Get-NetFirewallRule -DisplayName "MES Zebra Bridge (TCP 9100 inbound)").Count
```

Expected: `RemoteAddress` is `172.17.10.161`, not `Any`, and the count is `1`. Then re-run `install` and check the count is still `1` -- spec § 10.1 wants stale rules pruned rather than accumulated, and the Gateway host still carries an orphan rule for `10.20.11.106` as the example of what not to do.

- [ ] **Step 10: Prove a printer swap, and that re-installing is safe**

The case spec § 7 calls *"the case that needs care"*. Printers get swapped in service, so this has to work without a reinstall and without anyone editing a file by hand.

First a re-install on a machine that is already commissioned:

```powershell
.\MesZebraBridge.exe install
```

Expected: `service MesZebraBridge already exists -- reconfiguring it`, the same `BOUND QUEUE: <name>` as before, and `service MesZebraBridge is Running`. It must **not** fail, and it must **not** silently re-detect and move the binding -- the conf already names a queue, so the output says `detection skipped`.

Now the swap itself. Point it at any other local queue (a PDF writer will do -- `?STATUS` prints nothing):

```powershell
$other = (Get-Printer | Where-Object Name -ne "<the real queue>" | Select-Object -First 1).Name
.\MesZebraBridge.exe set-queue $other
```

Expected: `queue <real queue> -> <other>`, `wrote <folder>\MesZebraBridge.conf`, `service MesZebraBridge is Running`, `BOUND QUEUE: <other>`, and the reminder about restarting the workstation session.

Then confirm `?STATUS` reports the **new** binding, which is what makes a swap verifiable in one probe:

```powershell
$c = New-Object Net.Sockets.TcpClient('127.0.0.1', 9100)
$s = $c.GetStream()
$b = [Text.Encoding]::ASCII.GetBytes('?STATUS')
$s.Write($b, 0, $b.Length); $s.Flush(); $c.Client.Shutdown('Send')
(New-Object IO.StreamReader($s)).ReadLine()
$c.Close()
```

Expected: `OK bridge=1.0.0 queue='<other>' ready=... jobs=0`.

Also confirm the swap did not lose the rest of the conf -- a swap that drops the Gateway address would break the next `install`:

```powershell
Get-Content .\MesZebraBridge.conf | Select-String "GatewayAddress|Queue|Port"
```

Expected: `GatewayAddress=172.17.10.161` still present, `Queue=<other>`, `Port=9100`.

Then put it back:

```powershell
.\MesZebraBridge.exe set-queue "<the real queue>"
```

Expected: `BOUND QUEUE: <the real queue>`, and a `?STATUS` probe agreeing.

- [ ] **Step 11: Record the observed exchange in `PROTOCOL.md`**

Append to the **existing** `## Verified` section of `zebraPrinter/PROTOCOL.md` -- adding evidence, changing no normative text:

```markdown
### Verified against `MesZebraBridge` (C#)

Observed <date> against the real Windows spooler and the real Zebra driver
(`<queue>` / `<port>`), service running as `LocalSystem` on `<printer host>`:

    ?STATUS  -> OK bridge=1.0.0 queue='<queue>' ready=true jobs=0
    ^XA...   -> OK queue='<queue>' job=<n> bytes=41      (label printed)
    (empty)  -> no reply, no label

`Get-PrintJob` independently reported `Id <n>, MES ZPL` for that exchange, so
`StartDocPrinterW`'s return value is the spooler job id under the C#
marshaling as well.

**Over the network**, Gateway `<gateway host>` to bridge `<printer host>:9100`,
which closes the gap listed under "Not yet verified":

    ?STATUS  -> OK bridge=1.0.0 queue='<queue>' ready=true jobs=0
    ^XA...   -> OK queue='<queue>' job=<m> bytes=<k>     (label printed)
```

Also strike the now-closed bullet from `### Not yet verified`, leaving the
*"That a label physically emerges"* caveat only if it still holds -- it does not,
if Step 3 produced a label, so record that instead of carrying a stale caveat.

- [ ] **Step 12: Record the verified host in `RELEASE.md`**

Add to the `## 1.0.0` table in `zebraPrinter/MesZebraBridge/RELEASE.md`:

```markdown
| Verified | <date> on `<printer host>` / `<queue>` / `<port>`, driver `<driver>`; Gateway `<gateway host>` end to end |
```

- [ ] **Step 13: Commit**

```bash
git add zebraPrinter/PROTOCOL.md zebraPrinter/MesZebraBridge/RELEASE.md
git commit -m "docs(bridge): MesZebraBridge reproduces the verified exchanges, over the network too"
```

---

## What this plan deliberately does not do

- **It does not change `PROTOCOL.md`'s normative sections.** Task 15 appends evidence to § Verified and nothing else.
- **It does not touch `LabelTransport`, the Config Tool, the database, or any Ignition resource.** The ACK read and the resolve-stage logging are the sibling plan `docs/superpowers/plans/2026-09-29-labeltransport-ack-and-dispatch-logging.md`; `validateEndpoint`'s `?STATUS` branch and the `UsbBridge` `ConnectionKind` (spec § 8.1) are a third workstream.
- **It does not delete `zebraPrinter/usb_tcp_bridge.py`.** Spec § 2 supersedes it *as a deployment artifact* while keeping it as the bench tool and the reference implementation of the spooler call, and `zebraPrinter/tests/test_bridge_protocol.py` remains the other half of the cross-implementation guard.
- **It does not implement a heartbeat or a status board** (spec § 11.2) or **multiple printers behind one bridge** (spec § 11.1). `MA2-59B-AOUT1`'s ten printer rows are the case that would force the endpoint grammar to grow a queue selector; revisit before that station is commissioned.
- **It does not detect the queue at runtime, and it does not reload the conf while running.** The queue name is explicit configuration (Global Constraint 5); `install` and `set-queue` restart the service, and that restart *is* the reload. A file watcher would be a second, quieter path to the same state.
- **It does not restart the workstation session after a printer swap.** Spec § 7 says a swap on a terminal already in service needs that too, because `session.custom.printer` resolved once at the session's startup -- the Config Tool test will pass against the database while the live session keeps printing to the old endpoint. `set-queue` prints the reminder; doing it is Config-Tool-side and outside this plan.
- **It does not claim a label printed.** `OK` means the named Windows queue took the bytes as that job, which is the strongest honest claim available (spec § 6.4).
- **It does not resolve spec § 12.2** (the reprint toast reporting success on a failed send) **or § 12.5** (the created-but-not-yet-dispatched silent window). Both are Gateway-side and were raised, not decided.
