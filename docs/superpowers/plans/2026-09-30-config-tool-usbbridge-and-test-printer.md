# Config Tool: `UsbBridge` ConnectionKind, Derived Endpoints, and "Test this printer" -- Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a USB-attached printer configurable in one dropdown and testable in one click. A printer whose `ConnectionKind` is the new `UsbBridge` stores **no endpoint** -- it derives from the parent Terminal's `IpAddress` plus port 9100 -- and a **Test printer** button issues the frozen `?STATUS` probe so commissioning proves route, firewall, service *and* queue binding without consuming a label. The three existing `Networked` printers keep their stored endpoints, provably untouched.

**Architecture:** Three layers, each doing exactly one thing.

1. **SQL owns derivation.** A pure scalar function `Location.ufn_PrinterEndpoint(@ConnectionKind, @StoredEndpoint, @TerminalIp)` composes the endpoint; the three read procs that already project a printer's endpoint (`Printer_GetById`, `Terminal_GetPrinter`, `PrinterFgAssignment_ListForStation`) call it through a `CROSS APPLY` and return the **resolved** value in the existing `Endpoint` column, plus `StoredEndpoint`, `ConnectionKind`, `TerminalIpAddress` and `EndpointSource` alongside. Because the resolved value lands in the column every consumer already reads, `ShippingDispatcher._resolveEndpoint`, `LotLabel._dispatchAfterRender` and `Terminal.applyToSession` need **no change at all** -- they were already asking SQL for an endpoint and now get a correct one. This is the "No business logic in Python" rule applied literally: no Python learns what `UsbBridge` means.
2. **`LabelTransport` owns the wire.** `_parseAck` gains the three `?STATUS` keys (`bridge`, `ready`, `jobs`) so there is still exactly **one** parser for the ACK grammar, and `probeStatus(host, port)` is `_sendTcp(host, port, "?STATUS")` -- the payload is the only difference between a print and a probe, so the framing, half-close, bounded read and parse are reused rather than copied.
3. **`Location.Printer` owns the diagnosis.** `validateEndpoint` keeps its signature and its `Hardwired` and `Networked` behaviour byte for byte, and gains a `UsbBridge` branch that probes. `testPrinter(printerLocationId)` is the id-driven entry point the button calls.

**Tech Stack:** SQL Server 2022 (T-SQL, `CREATE OR ALTER` repeatables + one versioned migration), Jython 2.7 project-library scripts, Perspective 8.3 file-based views, pytest for the Jython pure helpers, `sql/tests/Run-Tests.ps1` for T-SQL.

**Spec:** `docs/superpowers/specs/2026-09-29-zebra-bridge-service-and-print-traceability-design.md` sections 5, 8, 8.1 and 9.
**Wire contract:** `zebraPrinter/PROTOCOL.md` v1.0.0. **Frozen. This plan changes nothing in it and adds no request or response key.**

## Global Constraints

- **`PROTOCOL.md` is normative and frozen.** The probe sends exactly `?STATUS` and reads exactly one line. No new command, no new key, no change to framing.
- **Derivation is SQL, never Python.** No Jython function may know that `UsbBridge` means "parent terminal IP + 9100". A Python file that contains the string `9100` as a bridge port is a defect introduced by this plan -- the sole legitimate `9100` in Python is `_DEFAULT_ZEBRA_PORT` in `Printer/code.py`, which already exists and is a *parsing* fallback for a port-less string, not a derivation.
- **The three existing `Networked` printers (`172.17.20.228` / `172.17.20.229`, both `:9100`) must come out of every read proc with their stored endpoint unchanged.** Task 4 asserts this against the live shape; `ufn_PrinterEndpoint` returns `@StoredEndpoint` untouched for every kind that is not `UsbBridge`, including an unrecognised one.
- **`_parseAck` is extended, never duplicated.** One parser for the ACK grammar. Same rule for `_sendTcp`: the probe calls it.
- **`validateEndpoint(endpoint, connectionKind)` keeps its signature.** Two live call sites bind to it -- `PrinterCard` (MPP, plant floor) and `PlantHierarchy` (MPP_Config) -- and one of them is not edited by this plan at all.
- **A `Networked` printer is still probed with a bare connect that sends zero bytes.** That is `PROTOCOL.md`'s "(no bytes at all)" row and it is why the existing check never wasted a label. Only `UsbBridge` writes `?STATUS`.
- **NVARCHAR everywhere, `DATETIME2(3)`, ASCII-only seed and description strings.** No em-dash, no middle dot, in any `.sql` string literal added here.
- **No `OUTPUT` parameters.** Read procs return one result set; `Location_SaveAll` keeps its `SELECT @Status, @Message, @NewId` on every exit path, and every new rejection returns **before** `BEGIN TRANSACTION`.
- **Terminal 147 (`MA2-6MACH-AOUT3`, `IpAddress = http://172.17.21.237`) is not touched.** Spec section 10.2 records it as unresolved on a live 6MA parallel-run row. `ufn_PrinterEndpoint` returns NULL for a value carrying a scheme, so the failure is loud and named rather than a composed nonsense host.
- **Do not run `Deploy-ProdRelease.ps1` or any prod script from this plan.** This is Dev work. A prod release for it is a separate exercise against `prod-release-context-pack/`.
- Python tests live in `ignition/tests/` and run with `python -m pytest`; T-SQL tests live in `sql/tests/<NNNN>_<Name>/` and run with `.\sql\tests\Run-Tests.ps1 -Filter "<NNNN>"` (which resets the throwaway `MPP_MES_Test`, never `MPP_MES_Dev`).

## What the investigation found, before designing

Two facts shaped the plan and are worth having in front of you.

**`ConnectionKind`'s allowed values are constrained nowhere in SQL.** `Location.LocationAttributeDefinition` has `AttributeName`, `DataType`, `IsRequired`, `DefaultValue` -- and no allowed-values column. `Location.LocationAttribute.AttributeValue` is one `NVARCHAR(255)` column shared by every attribute of every location type, so a code table with an FK (the `sql_best_practices_mes.md` rule for enums) is not expressible without restructuring the EAV model. The *only* thing constraining the value today is the Python list `_CONNECTION_KINDS` in `BlueRidge.Location.AttributeOptions`, feeding a dropdown authored `allowCustomOptions: true` -- advisory, not enforcing. **Adding the third value is therefore a one-line Python edit plus a description update, not a constraint change**, and `ufn_PrinterEndpoint` is written so an unrecognised kind degrades to the stored-endpoint path rather than to a guess. Introducing a real code table for EAV values is a larger design question and is deliberately out of scope here.

**`Location.Location_SaveAll` will refuse to save a `UsbBridge` printer as things stand.** `Endpoint` on LTD 16 is `IsRequired = 1`; the proc parses incoming values with `NULLIF(LTRIM(RTRIM(...)), N'')`, so a blank endpoint becomes NULL, and the required-attribute check then rejects with `Required attribute missing a value: Endpoint.`. The spec says "No endpoint is entered" but does not mention this gate. Task 1 relaxes the flag and Task 3 restores the guard **conditionally**, where the sibling `ConnectionKind` value is visible -- because relaxing it alone would let a `Networked` printer save with no address at all and fail silently at dispatch, which is the exact class of defect this spec exists to remove.

---

### Task 1: Migration 0101 -- make `UsbBridge` a legal kind and let an endpoint be absent

Data-only. Two `Location.LocationAttributeDefinition` rows on LTD 16 change: `ConnectionKind`'s description gains the third value, and `Endpoint` stops being unconditionally required. No DDL.

**Files:**
- Create: `sql/migrations/versioned/0101_printer_usbbridge_connectionkind.sql`

**Interfaces:**
- Consumes: nothing
- Produces: `Endpoint.IsRequired = 0` on LTD 16 (consumed by Task 3's conditional guard) and a `ConnectionKind` description naming all three values (read by the Config Tool attribute panel).

- [ ] **Step 1: Confirm 0101 is the next free number and nothing already claims it**

```bash
ls sql/migrations/versioned/ | tail -5
grep -rn "0101_" sql/migrations/ sql/scripts/ || echo "0101 free"
```

Expected: `0100_session_policy_elevation_max.sql` is the highest, and `0101 free`. (`0092` is absent from the sequence; that is pre-existing and not this plan's business.)

- [ ] **Step 2: Write the migration**

Create `sql/migrations/versioned/0101_printer_usbbridge_connectionkind.sql`:

```sql
-- ============================================================
-- Migration:   0101_printer_usbbridge_connectionkind.sql
-- Author:      Blue Ridge Automation
-- Date:        2026-09-30
-- Description: A third ConnectionKind for Printer locations (LTD 16): UsbBridge.
--
--              WHY. MPP is going 100% USB-attached: 54 printers on 77 terminal
--              PCs, each reached through the MesZebraBridge service listening on
--              TCP 9100 on the terminal PC itself. With every printer USB
--              attached, the bridge ALWAYS runs on the terminal, so a bridge
--              printer's endpoint host is by construction its parent Terminal's
--              IpAddress -- which the terminals already carry, because that is
--              how screen selection resolves. There is no second address, so it
--              is not stored: 54 hand-entered addresses become zero, and the
--              port-omission trap (a bare '10.20.11.157' is silently
--              reclassified by LabelTransport's grammar as a Windows print-QUEUE
--              name) becomes unreachable because no human types the endpoint.
--              Spec: docs/superpowers/specs/
--              2026-09-29-zebra-bridge-service-and-print-traceability-design.md
--              sections 8 and 8.1.
--
--              WHAT.
--              1. ConnectionKind's Description now names all three values. The
--                 ALLOWED-VALUE SET IS NOT CONSTRAINED IN SQL and this migration
--                 does not pretend otherwise: LocationAttributeDefinition has no
--                 allowed-values column, and LocationAttribute.AttributeValue is
--                 one NVARCHAR(255) column shared by every attribute of every
--                 location type, so a code table with an FK is not expressible
--                 without restructuring the polymorphic model. The dropdown in
--                 BlueRidge.Location.AttributeOptions is the only list, and it is
--                 authored allowCustomOptions = true. Location.ufn_PrinterEndpoint
--                 is written so an UNRECOGNISED kind falls to the stored-endpoint
--                 path rather than to a guess.
--              2. Endpoint.IsRequired 1 -> 0. A UsbBridge printer stores no
--                 endpoint, and Location.Location_SaveAll parses incoming values
--                 with NULLIF(LTRIM(RTRIM(..)), N''), so a blank Endpoint becomes
--                 NULL and the generic required-attribute check refuses the save
--                 with "Required attribute missing a value: Endpoint."
--                 Relaxing the flag alone would let a Networked printer save with
--                 NO address and fail silently at dispatch, so the requirement
--                 MOVES into Location_SaveAll v1.4, which can see the sibling
--                 ConnectionKind value. Apply that repeatable in the same window.
--
--              NOT DONE HERE. No existing printer row is re-kinded. The three
--              live Networked printers (172.17.20.228 / .229, both :9100) keep
--              their stored endpoints; their addresses are genuinely independent
--              of their terminals', which is precisely why the kinds stay
--              distinct instead of derivation being applied universally.
--
--              Idempotent-guarded; no explicit transaction (repo convention).
--              ASCII-only.
-- ============================================================
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0101_printer_usbbridge_connectionkind')
BEGIN PRINT 'Migration 0101 already applied -- skipping.'; RETURN; END
GO

UPDATE Location.LocationAttributeDefinition
SET Description = N'Networked = stored host:port, TCP direct to a printer with its own NIC. Hardwired = stored Windows print-queue name, printed through the Gateway host. UsbBridge = NO endpoint stored; it derives from the parent Terminal IpAddress plus port 9100, where the MesZebraBridge service listens.'
WHERE LocationTypeDefinitionId = 16
  AND AttributeName = N'ConnectionKind'
  AND DeprecatedAt IS NULL;
GO

UPDATE Location.LocationAttributeDefinition
SET IsRequired  = 0,
    Description = N'Zebra print target - IP:port or print-queue name. Leave BLANK when ConnectionKind is UsbBridge: the endpoint derives from the parent Terminal IpAddress plus port 9100. Required for Networked and Hardwired, enforced by Location.Location_SaveAll.'
WHERE LocationTypeDefinitionId = 16
  AND AttributeName = N'Endpoint'
  AND DeprecatedAt IS NULL;
GO

-- Guarded like 0079: the top-of-file RETURN only exits its OWN batch.
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE MigrationId = N'0101_printer_usbbridge_connectionkind')
    INSERT INTO dbo.SchemaVersion (MigrationId, Description)
    VALUES (N'0101_printer_usbbridge_connectionkind',
            N'Printer (LTD 16): ConnectionKind description names the third value UsbBridge; Endpoint.IsRequired 1 -> 0 (the requirement moves to Location_SaveAll v1.4, conditional on ConnectionKind).');
GO
PRINT 'Migration 0101 (printer_usbbridge_connectionkind) applied.';
GO
```

- [ ] **Step 3: Byte-scan the file for non-ASCII before it ever reaches sqlcmd**

`sqlcmd` reads `.sql` in the Windows codepage, so an em-dash or middle dot lands in the DB as mojibake and then shows up in Ignition.

Run: `python -c "import io; s=io.open('sql/migrations/versioned/0101_printer_usbbridge_connectionkind.sql',encoding='utf-8').read(); bad=[(i,c) for i,c in enumerate(s) if ord(c)>127]; print('non-ascii:', bad[:10], 'count', len(bad))"`
Expected: `non-ascii: [] count 0`

- [ ] **Step 4: Also update the seed so a fresh database is born correct**

`sql/seeds/011_seed_locations_mpp_plant.sql` is GENERATED from `sql/seeds/gen_locations_mpp.js`. Edit the **generator**, then regenerate, so the change is not lost the next time anyone runs it.

In `sql/seeds/gen_locations_mpp.js`, find the `ConnectionKind` attribute-definition emit (the line whose text contains `Networked = reachable at Endpoint IP:port`) and replace that description string with the same wording used in Step 2's first `UPDATE`. Find the `Endpoint` emit (text contains `Zebra print target - IP:port or print-queue name`), change its `IsRequired` argument from `1` to `0`, and replace its description with Step 2's second wording.

Then run: `node sql/seeds/gen_locations_mpp.js`
Expected: `sql/seeds/011_seed_locations_mpp_plant.sql` is rewritten. Verify with `git diff --stat sql/seeds/011_seed_locations_mpp_plant.sql` that **only** the two attribute-definition lines changed -- the generator also emits ~1400 location rows and a large diff means something else moved.

Run: `python -c "import io; s=io.open('sql/seeds/011_seed_locations_mpp_plant.sql',encoding='utf-8').read(); print('non-ascii', len([c for c in s if ord(c)>127]))"`
Expected: `non-ascii 0`

- [ ] **Step 5: Apply to the throwaway test DB and read the rows back**

```bash
sqlcmd -S localhost -d MPP_MES_Test -i sql/migrations/versioned/0101_printer_usbbridge_connectionkind.sql -b -I -C
sqlcmd -S localhost -d MPP_MES_Test -Q "SET NOCOUNT ON; SELECT AttributeName, IsRequired, DefaultValue, Descr=LEFT(Description,60) FROM Location.LocationAttributeDefinition WHERE LocationTypeDefinitionId = 16 ORDER BY SortOrder;" -b -I -C -W -s "|"
```

Expected: `Migration 0101 ... applied.`, then `Endpoint|0|NULL|Zebra print target...`, `Model|0|...`, `ConnectionKind|0|Networked|Networked = stored host:port...`.

Run it a second time. Expected: `Migration 0101 already applied -- skipping.` and no second `SchemaVersion` row.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/versioned/0101_printer_usbbridge_connectionkind.sql sql/seeds/gen_locations_mpp.js sql/seeds/011_seed_locations_mpp_plant.sql
git commit -m "feat(sql): UsbBridge is a legal ConnectionKind, and an endpoint may be absent"
```

---

### Task 2: `Location.ufn_PrinterEndpoint` -- the derivation, in SQL, and pure

One scalar function. Given a kind, a stored endpoint and a terminal IP, it returns the endpoint to dial. It touches no table, so it is deterministic, `SCHEMABINDING`-safe and inlinable in the three read procs -- the same shape as the `Location.ufn_VisionAppUrl` precedent.

**Files:**
- Create: `sql/migrations/repeatable/R__Location_ufn_PrinterEndpoint.sql`
- Test: `sql/tests/0101_PrinterUsbBridge/010_ufn_PrinterEndpoint.sql`

**Interfaces:**
- Consumes: `Location.ufn_NormalizeIpAddress(@Ip NVARCHAR(64)) RETURNS NVARCHAR(64)` (existing)
- Produces: `Location.ufn_PrinterEndpoint(@ConnectionKind NVARCHAR(50), @StoredEndpoint NVARCHAR(255), @TerminalIp NVARCHAR(64)) RETURNS NVARCHAR(255)`, consumed by Task 4's three read procs.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0101_PrinterUsbBridge/010_ufn_PrinterEndpoint.sql`:

```sql
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0101_PrinterUsbBridge/010_ufn_PrinterEndpoint.sql';
GO
-- Networked and Hardwired keep whatever is stored. This is the guard that the
-- three live Networked printers (172.17.20.228 / .229 :9100) are untouched.
DECLARE @a NVARCHAR(255) = Location.ufn_PrinterEndpoint(N'Networked', N'172.17.20.228:9100', N'10.20.11.53');
EXEC test.Assert_IsEqual @TestName = N'[ufnPrinterEndpoint] Networked keeps its stored endpoint',
     @Expected = N'172.17.20.228:9100', @Actual = @a;

DECLARE @b NVARCHAR(255) = Location.ufn_PrinterEndpoint(N'Hardwired', N'Zebra GX420d (RAW)', N'10.20.11.53');
EXEC test.Assert_IsEqual @TestName = N'[ufnPrinterEndpoint] Hardwired keeps its queue name',
     @Expected = N'Zebra GX420d (RAW)', @Actual = @b;

-- An absent kind reads as the attribute DefaultValue, 'Networked'.
DECLARE @c NVARCHAR(255) = Location.ufn_PrinterEndpoint(NULL, N'172.17.20.229:9100', N'10.20.11.53');
EXEC test.Assert_IsEqual @TestName = N'[ufnPrinterEndpoint] NULL kind defaults to Networked',
     @Expected = N'172.17.20.229:9100', @Actual = @c;

-- An UNRECOGNISED kind must not be guessed at. Nothing constrains this column,
-- so a typo is reachable, and the safe read of a typo is "leave it alone".
DECLARE @d NVARCHAR(255) = Location.ufn_PrinterEndpoint(N'UsbBridg', N'172.17.20.228:9100', N'10.20.11.53');
EXEC test.Assert_IsEqual @TestName = N'[ufnPrinterEndpoint] unknown kind falls to the stored endpoint',
     @Expected = N'172.17.20.228:9100', @Actual = @d;
GO
DECLARE @e NVARCHAR(255) = Location.ufn_PrinterEndpoint(N'UsbBridge', NULL, N'172.17.20.5');
EXEC test.Assert_IsEqual @TestName = N'[ufnPrinterEndpoint] UsbBridge derives terminal IP + 9100',
     @Expected = N'172.17.20.5:9100', @Actual = @e;

-- The stored endpoint is IGNORED for UsbBridge, not preferred. A leftover value
-- from a printer that was re-kinded must not win over the derivation.
DECLARE @f NVARCHAR(255) = Location.ufn_PrinterEndpoint(N'UsbBridge', N'10.20.11.157:9100', N'172.17.20.5');
EXEC test.Assert_IsEqual @TestName = N'[ufnPrinterEndpoint] UsbBridge ignores a leftover stored endpoint',
     @Expected = N'172.17.20.5:9100', @Actual = @f;

-- Perspective reports loopback bracketed and expanded; ufn_NormalizeIpAddress
-- already canonicalizes that, and this proves it is actually being reused.
DECLARE @g NVARCHAR(255) = Location.ufn_PrinterEndpoint(N'UsbBridge', NULL, N'[0:0:0:0:0:0:0:1]');
EXEC test.Assert_IsEqual @TestName = N'[ufnPrinterEndpoint] bracketed loopback normalizes before composing',
     @Expected = N'127.0.0.1:9100', @Actual = @g;

-- An explicit port is honoured, never doubled.
DECLARE @h NVARCHAR(255) = Location.ufn_PrinterEndpoint(N'UsbBridge', NULL, N'172.17.20.5:9101');
EXEC test.Assert_IsEqual @TestName = N'[ufnPrinterEndpoint] an explicit port is not doubled',
     @Expected = N'172.17.20.5:9101', @Actual = @h;

DECLARE @i NVARCHAR(255) = Location.ufn_PrinterEndpoint(N'UsbBridge', NULL, N'  172.17.20.5  ');
EXEC test.Assert_IsEqual @TestName = N'[ufnPrinterEndpoint] whitespace is trimmed',
     @Expected = N'172.17.20.5:9100', @Actual = @i;
GO
-- No terminal IP -> NULL, so the resolve stage logs EndpointUnresolved and names
-- the row, instead of composing ':9100' and failing at the socket.
DECLARE @j NVARCHAR(255) = Location.ufn_PrinterEndpoint(N'UsbBridge', NULL, NULL);
EXEC test.Assert_IsNull @TestName = N'[ufnPrinterEndpoint] no terminal IP -> NULL', @Value  = @j;

DECLARE @k NVARCHAR(255) = Location.ufn_PrinterEndpoint(N'UsbBridge', NULL, N'   ');
EXEC test.Assert_IsNull @TestName = N'[ufnPrinterEndpoint] blank terminal IP -> NULL', @Value  = @k;

-- Terminal 147 (MA2-6MACH-AOUT3) really holds 'http://172.17.21.237' -- spec
-- section 10.2, live 6MA parallel-run row, unresolved and NOT touched. A scheme
-- is not a host: composing 'http://172.17.21.237:9100' would parse as a TCP
-- endpoint whose HOST is 'http://172.17.21.237' and die with an unknown-host
-- error pointing nowhere near the real problem.
DECLARE @l NVARCHAR(255) = Location.ufn_PrinterEndpoint(N'UsbBridge', NULL, N'http://172.17.21.237');
EXEC test.Assert_IsNull @TestName = N'[ufnPrinterEndpoint] a URL is not a host -> NULL', @Value  = @l;
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "0101"`
Expected: the file errors on `Invalid object name 'Location.ufn_PrinterEndpoint'` / cannot find the function. (Per `feedback_runtests_exit1_zero_failures`: exit 1 with 0 reported failures means a file's sqlcmd errored -- which is exactly the expected state here.)

- [ ] **Step 3: Write the function**

Create `sql/migrations/repeatable/R__Location_ufn_PrinterEndpoint.sql`:

```sql
-- ============================================================
-- Repeatable:  R__Location_ufn_PrinterEndpoint.sql
-- Author:      Blue Ridge Automation
-- Created:     2026-09-30
-- Version:     1.0
-- Description: Resolves the endpoint a Printer location is actually dialled at.
--
--              Three ConnectionKinds, and only one of them derives:
--                Networked  -> the STORED host:port (a printer with its own NIC)
--                Hardwired  -> the STORED Windows print-queue name
--                UsbBridge  -> DERIVED: parent Terminal IpAddress + port 9100
--
--              WHY DERIVE. With every printer USB attached, the MesZebraBridge
--              service always runs ON the terminal PC, so a bridge printer's
--              endpoint host is by construction its parent Terminal's IpAddress
--              -- which terminals already carry, because that is how screen
--              selection resolves. There is no second address, so storing one
--              would be two fields that must agree by convention. This removes
--              a class of defect instead of mitigating it: 54 hand-entered
--              addresses become zero, the port can never be omitted, endpoint
--              and terminal IP cannot drift, and a re-addressed terminal stays
--              correct with no second edit. Spec sections 8 and 8.1.
--
--              PURE. No table access, deterministic, SCHEMABINDING -- so the
--              read procs can call it inline, the same shape as
--              Location.ufn_VisionAppUrl. It reuses
--              Location.ufn_NormalizeIpAddress rather than re-deriving the
--              bracket / IPv4-mapped handling that function already owns.
--
--              WHAT IT RETURNS NULL FOR, deliberately:
--                - a UsbBridge printer whose terminal has no IpAddress
--                - a UsbBridge printer whose terminal IpAddress carries a URL
--                  scheme (terminal 147 holds 'http://172.17.21.237' -- spec
--                  section 10.2, unresolved, untouched)
--              NULL makes the resolve stage log EndpointUnresolved and name the
--              row. Composing a host out of a URL would instead produce a
--              plausible-looking endpoint that fails at the socket with a
--              message pointing nowhere near the misconfigured attribute.
--
--              An UNRECOGNISED kind falls to the stored-endpoint path. Nothing
--              in SQL constrains this attribute's value set (see migration
--              0101), so a typo is reachable, and the honest read of a typo is
--              "do not derive" -- which is also what keeps the three live
--              Networked printers provably untouched.
--
--              LIMITATION, stated rather than papered over: the explicit-port
--              test assumes IPv4, which is what every Terminal IpAddress row
--              holds. A bare IPv6 host would have its last hextet read as a
--              port -- but a bare IPv6 host is not a usable endpoint for
--              BlueRidge.Lots.LabelTransport's grammar either, so nothing that
--              works today breaks.
-- ============================================================
CREATE OR ALTER FUNCTION Location.ufn_PrinterEndpoint
(
    @ConnectionKind NVARCHAR(50),
    @StoredEndpoint NVARCHAR(255),
    @TerminalIp     NVARCHAR(64)
)
RETURNS NVARCHAR(255)
WITH SCHEMABINDING
AS
BEGIN
    -- An absent kind reads as the attribute DefaultValue, 'Networked'.
    DECLARE @kind NVARCHAR(50) =
        ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(@ConnectionKind, N''))), N''), N'Networked');

    IF @kind <> N'UsbBridge'
        RETURN @StoredEndpoint;

    DECLARE @ip NVARCHAR(64) = Location.ufn_NormalizeIpAddress(@TerminalIp);
    IF @ip IS NULL
        RETURN NULL;
    SET @ip = LTRIM(RTRIM(@ip));
    IF @ip = N''
        RETURN NULL;

    -- A scheme is not a host.
    IF CHARINDEX(N'://', @ip) > 0
        RETURN NULL;

    -- Already carries an explicit port -> honour it, never double it.
    DECLARE @tail NVARCHAR(64) = NULL;
    IF CHARINDEX(N':', @ip) > 0
        SET @tail = SUBSTRING(@ip, LEN(@ip) - CHARINDEX(N':', REVERSE(@ip)) + 2, LEN(@ip));
    IF @tail IS NOT NULL AND @tail <> N'' AND @tail NOT LIKE N'%[^0-9]%'
        RETURN @ip;

    -- PROTOCOL.md: "Transport: TCP, default port 9100". The bridge listens on one
    -- port and binds one queue, and the port is not per-printer configurable --
    -- spec section 11.1 defers the multi-printer station that would need it. So
    -- 9100 is a constant here and lives in exactly this one place.
    RETURN @ip + N':9100';
END
GO
```

- [ ] **Step 4: Apply it and run the test to verify it passes**

```bash
sqlcmd -S localhost -d MPP_MES_Test -i sql/migrations/repeatable/R__Location_ufn_PrinterEndpoint.sql -b -I -C
```

Run: `.\sql\tests\Run-Tests.ps1 -Filter "0101"`
Expected: PASS, 12 assertions, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add sql/migrations/repeatable/R__Location_ufn_PrinterEndpoint.sql sql/tests/0101_PrinterUsbBridge/010_ufn_PrinterEndpoint.sql
git commit -m "feat(sql): a USB-bridge printer's endpoint is derived from its terminal, in SQL"
```

---

### Task 3: `Location_SaveAll` v1.4 -- Endpoint is required *unless* the kind is `UsbBridge`

Task 1 relaxed `Endpoint.IsRequired` so a bridge printer can save. On its own that lets a `Networked` printer save with no address at all and fail silently at dispatch. The requirement moves here, where the sibling `ConnectionKind` value is in scope.

**Files:**
- Modify: `sql/migrations/repeatable/R__Location_Location_SaveAll.sql`
- Test: `sql/tests/0101_PrinterUsbBridge/020_SaveAll_conditional_endpoint.sql`

**Interfaces:**
- Consumes: migration 0101's `Endpoint.IsRequired = 0`
- Produces: `Location.Location_SaveAll` v1.4. Result-set shape unchanged: `Status BIT, Message NVARCHAR(500), NewId BIGINT`, one row on every exit path. New refusal message: `Endpoint is required unless ConnectionKind is UsbBridge.`

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0101_PrinterUsbBridge/020_SaveAll_conditional_endpoint.sql`:

```sql
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0101_PrinterUsbBridge/020_SaveAll_conditional_endpoint.sql';
GO
-- Fixture: an arbitrary active Terminal to hang test printers under.
DELETE la FROM Location.LocationAttribute la
    INNER JOIN Location.Location l ON l.Id = la.LocationId
    WHERE l.Code IN (N'TEST-PRN-UB', N'TEST-PRN-NW');
DELETE FROM Location.Location WHERE Code IN (N'TEST-PRN-UB', N'TEST-PRN-NW');
GO
DECLARE @Parent BIGINT = (SELECT TOP 1 Id FROM Location.Location
                          WHERE LocationTypeDefinitionId = 7 AND DeprecatedAt IS NULL ORDER BY Id);
DECLARE @EpDef   BIGINT = (SELECT Id FROM Location.LocationAttributeDefinition
                           WHERE LocationTypeDefinitionId = 16 AND AttributeName = N'Endpoint' AND DeprecatedAt IS NULL);
DECLARE @CkDef   BIGINT = (SELECT Id FROM Location.LocationAttributeDefinition
                           WHERE LocationTypeDefinitionId = 16 AND AttributeName = N'ConnectionKind' AND DeprecatedAt IS NULL);
DECLARE @Usr     BIGINT = (SELECT TOP 1 Id FROM Location.AppUser ORDER BY Id);

-- A UsbBridge printer saves with a BLANK Endpoint. Before this change the generic
-- required-attribute check refused it with "Required attribute missing a value".
DECLARE @Json1 NVARCHAR(MAX) =
    N'[{"LocationAttributeDefinitionId":' + CAST(@EpDef AS NVARCHAR(20)) + N',"Value":""},'
  + N' {"LocationAttributeDefinitionId":' + CAST(@CkDef AS NVARCHAR(20)) + N',"Value":"UsbBridge"}]';
CREATE TABLE #R1 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R1 EXEC Location.Location_SaveAll
    @Id = NULL, @ParentLocationId = @Parent, @LocationTypeDefinitionId = 16,
    @Name = N'Test Printer UB', @Code = N'TEST-PRN-UB', @Description = N'test',
    @SortOrder = 951, @AppUserId = @Usr, @AttributeValuesJson = @Json1;
DECLARE @S1 BIT, @M1 NVARCHAR(500);
SELECT @S1 = Status, @M1 = Message FROM #R1;
DROP TABLE #R1;
EXEC test.Assert_IsTrue @TestName = N'[SaveAll] UsbBridge printer saves with no endpoint', @Condition = @S1;
GO
-- A Networked printer with a blank Endpoint is still REFUSED -- the guard moved,
-- it did not disappear.
DECLARE @EpDef2 BIGINT = (SELECT Id FROM Location.LocationAttributeDefinition
                          WHERE LocationTypeDefinitionId = 16 AND AttributeName = N'Endpoint' AND DeprecatedAt IS NULL);
DECLARE @CkDef2 BIGINT = (SELECT Id FROM Location.LocationAttributeDefinition
                          WHERE LocationTypeDefinitionId = 16 AND AttributeName = N'ConnectionKind' AND DeprecatedAt IS NULL);
DECLARE @Parent2 BIGINT = (SELECT TOP 1 Id FROM Location.Location
                           WHERE LocationTypeDefinitionId = 7 AND DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Usr2 BIGINT = (SELECT TOP 1 Id FROM Location.AppUser ORDER BY Id);
DECLARE @Json2 NVARCHAR(MAX) =
    N'[{"LocationAttributeDefinitionId":' + CAST(@EpDef2 AS NVARCHAR(20)) + N',"Value":""},'
  + N' {"LocationAttributeDefinitionId":' + CAST(@CkDef2 AS NVARCHAR(20)) + N',"Value":"Networked"}]';
CREATE TABLE #R2 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R2 EXEC Location.Location_SaveAll
    @Id = NULL, @ParentLocationId = @Parent2, @LocationTypeDefinitionId = 16,
    @Name = N'Test Printer NW', @Code = N'TEST-PRN-NW', @Description = N'test',
    @SortOrder = 952, @AppUserId = @Usr2, @AttributeValuesJson = @Json2;
DECLARE @S2 BIT, @M2 NVARCHAR(500);
SELECT @S2 = Status, @M2 = Message FROM #R2;
DROP TABLE #R2;
EXEC test.Assert_IsEqual @TestName = N'[SaveAll] Networked printer with no endpoint is refused',
     @Expected = N'0', @Actual = CAST(@S2 AS NVARCHAR(1));
EXEC test.Assert_Contains @TestName = N'[SaveAll] the refusal names the condition',
     @HaystackStr = @M2, @NeedleStr = N'unless ConnectionKind is UsbBridge';
GO
-- An ABSENT ConnectionKind reads as the DefaultValue 'Networked', so a blank
-- endpoint with no kind at all is refused too -- the common typo case.
DECLARE @EpDef3 BIGINT = (SELECT Id FROM Location.LocationAttributeDefinition
                          WHERE LocationTypeDefinitionId = 16 AND AttributeName = N'Endpoint' AND DeprecatedAt IS NULL);
DECLARE @Parent3 BIGINT = (SELECT TOP 1 Id FROM Location.Location
                           WHERE LocationTypeDefinitionId = 7 AND DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Usr3 BIGINT = (SELECT TOP 1 Id FROM Location.AppUser ORDER BY Id);
DECLARE @Json3 NVARCHAR(MAX) =
    N'[{"LocationAttributeDefinitionId":' + CAST(@EpDef3 AS NVARCHAR(20)) + N',"Value":""}]';
CREATE TABLE #R3 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R3 EXEC Location.Location_SaveAll
    @Id = NULL, @ParentLocationId = @Parent3, @LocationTypeDefinitionId = 16,
    @Name = N'Test Printer NK', @Code = N'TEST-PRN-NK', @Description = N'test',
    @SortOrder = 953, @AppUserId = @Usr3, @AttributeValuesJson = @Json3;
DECLARE @S3 BIT;
SELECT @S3 = Status FROM #R3;
DROP TABLE #R3;
EXEC test.Assert_IsEqual @TestName = N'[SaveAll] absent kind defaults to Networked and is refused',
     @Expected = N'0', @Actual = CAST(@S3 AS NVARCHAR(1));
GO
-- A NON-printer location type is unaffected by the new block.
DECLARE @Site BIGINT = (SELECT TOP 1 Id FROM Location.Location WHERE LocationTypeDefinitionId = 2 AND DeprecatedAt IS NULL ORDER BY Id);
DECLARE @Usr4 BIGINT = (SELECT TOP 1 Id FROM Location.AppUser ORDER BY Id);
CREATE TABLE #R4 (Status BIT, Message NVARCHAR(500), NewId BIGINT);
INSERT INTO #R4 EXEC Location.Location_SaveAll
    @Id = NULL, @ParentLocationId = @Site, @LocationTypeDefinitionId = 4,
    @Name = N'Test Support Area', @Code = N'TEST-AREA-UB', @Description = N'test',
    @SortOrder = 954, @AppUserId = @Usr4, @AttributeValuesJson = N'[]';
DECLARE @S4 BIT;
SELECT @S4 = Status FROM #R4;
DROP TABLE #R4;
EXEC test.Assert_IsTrue @TestName = N'[SaveAll] a non-printer type is unaffected', @Condition = @S4;
GO
-- Teardown. LocationAttribute BEFORE Location (FK).
DELETE la FROM Location.LocationAttribute la
    INNER JOIN Location.Location l ON l.Id = la.LocationId
    WHERE l.Code IN (N'TEST-PRN-UB', N'TEST-PRN-NW', N'TEST-PRN-NK', N'TEST-AREA-UB');
DELETE FROM Location.Location WHERE Code IN (N'TEST-PRN-UB', N'TEST-PRN-NW', N'TEST-PRN-NK', N'TEST-AREA-UB');
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run to verify it fails**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "0101"`
Expected: `010` still passes; `020`'s first assertion **fails** -- the UsbBridge save is refused with `Required attribute missing a value: Endpoint.` if the reset DB has not yet had 0101 applied, or the Networked-refusal assertions fail if it has. Either way `020` is red and `010` is green.

(`Run-Tests.ps1` resets its target from migrations + seeds, so 0101 and the Task 2 repeatable are picked up automatically once committed. If `020` reports "Required attribute missing a value", 0101 has not landed in the reset path -- check it is in `sql/migrations/versioned/` and named `0101_...`.)

- [ ] **Step 3: Add the conditional guard**

In `sql/migrations/repeatable/R__Location_Location_SaveAll.sql`, find the end of the generic required-attribute block -- the `END` that closes `IF @MissingAttrName IS NOT NULL`, immediately before the comment line `-- Branch: CREATE vs UPDATE`. Insert this **between** them, so it runs with the other rejecting validations and before any `BEGIN TRANSACTION`:

```sql
        -- ====================
        -- Printer (LTD 16): Endpoint is CONDITIONALLY required
        -- ====================
        -- Endpoint was IsRequired = 1 until migration 0101. ConnectionKind =
        -- 'UsbBridge' stores NO endpoint -- it derives from the parent Terminal's
        -- IpAddress via Location.ufn_PrinterEndpoint -- so the definition-level
        -- flag had to be relaxed. Relaxing it ALONE would let a Networked printer
        -- save with no address at all and fail silently at dispatch, so the
        -- requirement lives here, where the sibling ConnectionKind value is in
        -- scope. @Incoming.Value is already NULL for empty/whitespace.
        --
        -- Runs with the other rejecting validations, BEFORE any transaction: this
        -- proc is captured via INSERT-EXEC, so a ROLLBACK inside it would throw
        -- Msg 3915. Every rejection SELECTs the status row and RETURNs with no
        -- open transaction.
        IF @LocationTypeDefinitionId = 16
        BEGIN
            DECLARE @IncomingKind NVARCHAR(255) = (
                SELECT TOP 1 i.Value
                FROM @Incoming i
                INNER JOIN Location.LocationAttributeDefinition lad
                    ON lad.Id = i.LocationAttributeDefinitionId
                   AND lad.AttributeName = N'ConnectionKind'
            );
            DECLARE @IncomingEndpoint NVARCHAR(255) = (
                SELECT TOP 1 i.Value
                FROM @Incoming i
                INNER JOIN Location.LocationAttributeDefinition lad
                    ON lad.Id = i.LocationAttributeDefinitionId
                   AND lad.AttributeName = N'Endpoint'
            );

            -- An absent ConnectionKind reads as the attribute DefaultValue,
            -- 'Networked' -- the same default Location.ufn_PrinterEndpoint applies.
            IF ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(@IncomingKind, N''))), N''), N'Networked') <> N'UsbBridge'
               AND @IncomingEndpoint IS NULL
            BEGIN
                SET @Message = N'Endpoint is required unless ConnectionKind is UsbBridge.';
                EXEC Audit.Audit_LogFailure
                    @AppUserId           = @AppUserId,
                    @LogEntityTypeCode   = N'Location',
                    @EntityId            = @Id,
                    @LogEventTypeCode    = @EventCode,
                    @FailureReason       = @Message,
                    @ProcedureName       = @ProcName,
                    @AttemptedParameters = @Params;
                SELECT @Status AS Status, @Message AS Message, @NewId AS NewId;
                RETURN;
            END
        END

```

- [ ] **Step 4: Bump the header version and change log**

In the same file, change `-- Version:     1.3` to `-- Version:     1.4`, and append to the Change Log block at the top of the header:

```sql
--   2026-09-30 - 1.4 - Printer (LTD 16) Endpoint is conditionally required:
--                       demanded for Networked / Hardwired, permitted absent for
--                       ConnectionKind = 'UsbBridge' (endpoint derives from the
--                       parent Terminal IpAddress). Migration 0101 relaxed the
--                       definition-level IsRequired flag; this is where the
--                       requirement actually lives now, because only here is the
--                       sibling ConnectionKind value visible.
```

- [ ] **Step 5: Apply and run to verify it passes**

```bash
sqlcmd -S localhost -d MPP_MES_Test -i sql/migrations/repeatable/R__Location_Location_SaveAll.sql -b -I -C
```

Run: `.\sql\tests\Run-Tests.ps1 -Filter "0101"`
Expected: PASS, 0 failures.

Then run the existing Plant Hierarchy suite, because this proc is shared by every location type:

Run: `.\sql\tests\Run-Tests.ps1 -Filter "Location"`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add sql/migrations/repeatable/R__Location_Location_SaveAll.sql sql/tests/0101_PrinterUsbBridge/020_SaveAll_conditional_endpoint.sql
git commit -m "fix(sql): Endpoint is required unless the printer is a USB bridge"
```

---

### Task 4: The three read procs return a resolved endpoint

`Printer_GetById`, `Terminal_GetPrinter` and `PrinterFgAssignment_ListForStation` are the only three places a printer's endpoint reaches the Gateway. Each gains a `CROSS APPLY` through `ufn_PrinterEndpoint` and four new columns. Because the resolved value lands in the **existing `Endpoint` column**, `ShippingDispatcher`, `LotLabel` and `Terminal.applyToSession` are correct with no edit.

**Files:**
- Modify: `sql/migrations/repeatable/R__Location_Printer_GetById.sql`
- Modify: `sql/migrations/repeatable/R__Location_Terminal_GetPrinter.sql`
- Modify: `sql/migrations/repeatable/R__Location_PrinterFgAssignment_ListForStation.sql`
- Modify: `sql/tests/0029_AssemblyPrinterCards/020_Printer_GetById.sql`
- Modify: `sql/tests/0029_AssemblyPrinterCards/030_PrinterFgAssignment_ListForStation.sql`
- Modify: `sql/tests/0029_AssemblyPrinterCards/040_PrinterFgAssignment_SaveAll.sql`
- Test: `sql/tests/0101_PrinterUsbBridge/030_read_procs_resolve_endpoint.sql`

**Interfaces:**
- Consumes: `Location.ufn_PrinterEndpoint` from Task 2
- Produces, on all three procs, these columns appended in this order after the existing ones:
  - `StoredEndpoint NVARCHAR(255)` -- the raw `Endpoint` attribute value
  - `TerminalIpAddress NVARCHAR(255)` -- the parent Terminal's `IpAddress` attribute (raw, not normalized)
  - `EndpointSource NVARCHAR(30)` -- `'stored'` | `'derived-terminal-ip'` | `'unresolved'`
  - and on `Terminal_GetPrinter` only, `ConnectionKind NVARCHAR(255)` (the other two already project it)
  
  `Endpoint` changes **meaning, not name**: it is now the resolved value. Consumed by `BlueRidge.Location.Printer.getById`, `BlueRidge.Location.Terminal.getPrinter`, `BlueRidge.Location.PrinterFgAssignment.listForStation` -- all unchanged, and by `Printer.testPrinter` in Task 7, which reads the new columns.

**No Named Query changes.** All three NQs are bare `EXEC <proc> @p = :p` and added result columns flow straight through `execOne` / `execList`.

- [ ] **Step 1: Write the failing test**

Create `sql/tests/0101_PrinterUsbBridge/030_read_procs_resolve_endpoint.sql`:

```sql
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0101_PrinterUsbBridge/030_read_procs_resolve_endpoint.sql';
GO
-- Fixture: a dedicated Terminal with a known IpAddress, and two printers under
-- it -- one UsbBridge (no stored endpoint), one Networked (stored endpoint).
DELETE la FROM Location.LocationAttribute la
    INNER JOIN Location.Location l ON l.Id = la.LocationId
    WHERE l.Code IN (N'TEST-UB-PRN', N'TEST-NW-PRN', N'TEST-UB-TERM');
DELETE FROM Location.Location WHERE Code IN (N'TEST-UB-PRN', N'TEST-NW-PRN');
DELETE FROM Location.Location WHERE Code = N'TEST-UB-TERM';
GO
DECLARE @Zone BIGINT = (SELECT TOP 1 ParentLocationId FROM Location.Location
                        WHERE LocationTypeDefinitionId = 7 AND ParentLocationId IS NOT NULL
                          AND DeprecatedAt IS NULL ORDER BY Id);
INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES (7, @Zone, N'Test UB Terminal', N'TEST-UB-TERM', N'test', 960);
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-UB-TERM');
DECLARE @IpDef BIGINT = (SELECT Id FROM Location.LocationAttributeDefinition
                         WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'IpAddress' AND DeprecatedAt IS NULL);
INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue)
VALUES (@Term, @IpDef, N'172.17.20.5');

DECLARE @EpDef BIGINT = (SELECT Id FROM Location.LocationAttributeDefinition
                         WHERE LocationTypeDefinitionId = 16 AND AttributeName = N'Endpoint' AND DeprecatedAt IS NULL);
DECLARE @CkDef BIGINT = (SELECT Id FROM Location.LocationAttributeDefinition
                         WHERE LocationTypeDefinitionId = 16 AND AttributeName = N'ConnectionKind' AND DeprecatedAt IS NULL);

INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES (16, @Term, N'Test UB Printer', N'TEST-UB-PRN', N'test', 1);
DECLARE @Ub BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-UB-PRN');
INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue)
VALUES (@Ub, @CkDef, N'UsbBridge');

INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES (16, @Term, N'Test NW Printer', N'TEST-NW-PRN', N'test', 2);
DECLARE @Nw BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-NW-PRN');
INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue)
VALUES (@Nw, @CkDef, N'Networked'), (@Nw, @EpDef, N'172.17.20.228:9100');
GO
-- Printer_GetById: the UsbBridge printer derives; the Networked one does not.
CREATE TABLE #P (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200),
                 Endpoint NVARCHAR(255), Model NVARCHAR(255), ConnectionKind NVARCHAR(255),
                 StoredEndpoint NVARCHAR(255), TerminalIpAddress NVARCHAR(255),
                 EndpointSource NVARCHAR(30));
DECLARE @Ub BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-UB-PRN');
INSERT INTO #P EXEC Location.Printer_GetById @PrinterLocationId = @Ub;
DECLARE @Ep NVARCHAR(255), @Src NVARCHAR(30), @Stored NVARCHAR(255), @Tip NVARCHAR(255);
SELECT @Ep = Endpoint, @Src = EndpointSource, @Stored = StoredEndpoint, @Tip = TerminalIpAddress FROM #P;
DROP TABLE #P;
EXEC test.Assert_IsEqual @TestName = N'[PrinterById] UsbBridge endpoint derives from the terminal IP',
     @Expected = N'172.17.20.5:9100', @Actual = @Ep;
EXEC test.Assert_IsEqual @TestName = N'[PrinterById] and says where it came from',
     @Expected = N'derived-terminal-ip', @Actual = @Src;
EXEC test.Assert_IsNull @TestName = N'[PrinterById] UsbBridge stores no endpoint', @Value  = @Stored;
EXEC test.Assert_IsEqual @TestName = N'[PrinterById] the terminal IP is reported for diagnosis',
     @Expected = N'172.17.20.5', @Actual = @Tip;
GO
CREATE TABLE #P2 (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200),
                  Endpoint NVARCHAR(255), Model NVARCHAR(255), ConnectionKind NVARCHAR(255),
                  StoredEndpoint NVARCHAR(255), TerminalIpAddress NVARCHAR(255),
                  EndpointSource NVARCHAR(30));
DECLARE @Nw BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-NW-PRN');
INSERT INTO #P2 EXEC Location.Printer_GetById @PrinterLocationId = @Nw;
DECLARE @Ep2 NVARCHAR(255), @Src2 NVARCHAR(30);
SELECT @Ep2 = Endpoint, @Src2 = EndpointSource FROM #P2;
DROP TABLE #P2;
-- THE REGRESSION GUARD for the three live Networked printers.
EXEC test.Assert_IsEqual @TestName = N'[PrinterById] a Networked printer keeps its stored endpoint',
     @Expected = N'172.17.20.228:9100', @Actual = @Ep2;
EXEC test.Assert_IsEqual @TestName = N'[PrinterById] and reports it as stored',
     @Expected = N'stored', @Actual = @Src2;
GO
-- Terminal_GetPrinter: TOP 1 by SortOrder, so it lands on the UsbBridge printer.
CREATE TABLE #T (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200),
                 Endpoint NVARCHAR(255), Model NVARCHAR(255), ConnectionKind NVARCHAR(255),
                 StoredEndpoint NVARCHAR(255), TerminalIpAddress NVARCHAR(255),
                 EndpointSource NVARCHAR(30));
DECLARE @Term BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-UB-TERM');
INSERT INTO #T EXEC Location.Terminal_GetPrinter @TerminalLocationId = @Term;
DECLARE @Ep3 NVARCHAR(255), @Ck3 NVARCHAR(255);
SELECT @Ep3 = Endpoint, @Ck3 = ConnectionKind FROM #T;
DROP TABLE #T;
EXEC test.Assert_IsEqual @TestName = N'[TerminalGetPrinter] resolves the derived endpoint',
     @Expected = N'172.17.20.5:9100', @Actual = @Ep3;
EXEC test.Assert_IsEqual @TestName = N'[TerminalGetPrinter] now projects ConnectionKind',
     @Expected = N'UsbBridge', @Actual = @Ck3;
GO
-- PrinterFgAssignment_ListForStation: both printers, each resolved its own way.
CREATE TABLE #L (PrinterLocationId BIGINT, PrinterCode NVARCHAR(50), PrinterName NVARCHAR(200),
                 Endpoint NVARCHAR(255), ConnectionKind NVARCHAR(255), AssignedItemId BIGINT,
                 PartNumber NVARCHAR(50), Description NVARCHAR(500), SortOrder INT,
                 StoredEndpoint NVARCHAR(255), TerminalIpAddress NVARCHAR(255),
                 EndpointSource NVARCHAR(30));
DECLARE @Term2 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-UB-TERM');
INSERT INTO #L EXEC Location.PrinterFgAssignment_ListForStation @StationTerminalLocationId = @Term2;
DECLARE @UbEp NVARCHAR(255) = (SELECT Endpoint FROM #L WHERE PrinterCode = N'TEST-UB-PRN');
DECLARE @NwEp NVARCHAR(255) = (SELECT Endpoint FROM #L WHERE PrinterCode = N'TEST-NW-PRN');
DECLARE @Cnt  INT = (SELECT COUNT(*) FROM #L);
DROP TABLE #L;
EXEC test.Assert_RowCount @TestName = N'[FgList] both printers returned', @ExpectedCount = 2, @ActualCount = @Cnt;
EXEC test.Assert_IsEqual @TestName = N'[FgList] the UsbBridge card gets a derived endpoint',
     @Expected = N'172.17.20.5:9100', @Actual = @UbEp;
EXEC test.Assert_IsEqual @TestName = N'[FgList] the Networked card is unchanged',
     @Expected = N'172.17.20.228:9100', @Actual = @NwEp;
GO
-- A terminal with NO IpAddress: the UsbBridge printer resolves to NULL and says
-- so, rather than composing ':9100'. This is what makes the resolve stage log
-- EndpointUnresolved instead of a socket error naming a nonsense host.
DELETE la FROM Location.LocationAttribute la
    INNER JOIN Location.Location l ON l.Id = la.LocationId
    INNER JOIN Location.LocationAttributeDefinition lad ON lad.Id = la.LocationAttributeDefinitionId
    WHERE l.Code = N'TEST-UB-TERM' AND lad.AttributeName = N'IpAddress';
GO
CREATE TABLE #P3 (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200),
                  Endpoint NVARCHAR(255), Model NVARCHAR(255), ConnectionKind NVARCHAR(255),
                  StoredEndpoint NVARCHAR(255), TerminalIpAddress NVARCHAR(255),
                  EndpointSource NVARCHAR(30));
DECLARE @Ub2 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-UB-PRN');
INSERT INTO #P3 EXEC Location.Printer_GetById @PrinterLocationId = @Ub2;
DECLARE @Ep4 NVARCHAR(255), @Src4 NVARCHAR(30);
SELECT @Ep4 = Endpoint, @Src4 = EndpointSource FROM #P3;
DROP TABLE #P3;
EXEC test.Assert_IsNull @TestName = N'[PrinterById] no terminal IP -> no endpoint', @Value  = @Ep4;
EXEC test.Assert_IsEqual @TestName = N'[PrinterById] and it is reported unresolved',
     @Expected = N'unresolved', @Actual = @Src4;
GO
-- Teardown. LocationAttribute BEFORE Location; printers BEFORE their terminal.
DELETE la FROM Location.LocationAttribute la
    INNER JOIN Location.Location l ON l.Id = la.LocationId
    WHERE l.Code IN (N'TEST-UB-PRN', N'TEST-NW-PRN', N'TEST-UB-TERM');
DELETE FROM Location.Location WHERE Code IN (N'TEST-UB-PRN', N'TEST-NW-PRN');
DELETE FROM Location.Location WHERE Code = N'TEST-UB-TERM';
GO
EXEC test.EndTestFile;
GO
```

- [ ] **Step 2: Run to verify it fails**

Run: `.\sql\tests\Run-Tests.ps1 -Filter "0101"`
Expected: `030` errors -- `INSERT INTO #P EXEC` fails because the temp table declares nine columns and the proc returns six (`Column name or number of supplied values does not match table definition`). `010` and `020` stay green.

- [ ] **Step 3: Rewrite `Printer_GetById`**

Replace the whole body of `sql/migrations/repeatable/R__Location_Printer_GetById.sql` with:

```sql
-- ============================================================
-- Repeatable:  R__Location_Printer_GetById.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-30
-- Version:     2.0
-- Description: Resolve one Printer Location (DefId 16) by its own Id, with the
--   endpoint it is ACTUALLY dialled at. Unlike Terminal_GetPrinter (TOP 1 child
--   of a terminal), this addresses a SPECIFIC printer -- used to derive a
--   shipping-label dispatch endpoint from a printer id (printer-cards) and by
--   the Config Tool's Test printer action.
--   Read proc: one row, or empty set when the id is not an active Printer.
--
--   v2.0: the Endpoint column is now RESOLVED through
--   Location.ufn_PrinterEndpoint. For ConnectionKind = 'UsbBridge' it derives
--   from the PARENT TERMINAL's IpAddress plus port 9100 (spec section 8.1);
--   every other kind returns the stored value untouched, which is why the three
--   live Networked printers are unaffected. Resolving HERE rather than in Python
--   is what keeps every caller correct with no edit -- they were already asking
--   SQL for an endpoint. StoredEndpoint / TerminalIpAddress / EndpointSource are
--   added for commissioning diagnosis: without them a derived endpoint names a
--   host that appears nowhere on the printer row.
-- ============================================================
CREATE OR ALTER PROCEDURE Location.Printer_GetById
    @PrinterLocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        p.Id                AS LocationId,
        p.Code              AS Code,
        p.Name              AS Name,
        e.Ep                AS Endpoint,
        mdv.AttributeValue  AS Model,
        ckv.AttributeValue  AS ConnectionKind,
        epv.AttributeValue  AS StoredEndpoint,
        tipv.AttributeValue AS TerminalIpAddress,
        CASE WHEN e.Ep IS NULL        THEN N'unresolved'
             WHEN k.Kind = N'UsbBridge' THEN N'derived-terminal-ip'
             ELSE N'stored' END        AS EndpointSource
    FROM Location.Location p
    LEFT JOIN Location.LocationAttributeDefinition epd
        ON epd.LocationTypeDefinitionId = 16 AND epd.AttributeName = N'Endpoint' AND epd.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttribute epv ON epv.LocationId = p.Id AND epv.LocationAttributeDefinitionId = epd.Id
    LEFT JOIN Location.LocationAttributeDefinition mdd
        ON mdd.LocationTypeDefinitionId = 16 AND mdd.AttributeName = N'Model' AND mdd.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttribute mdv ON mdv.LocationId = p.Id AND mdv.LocationAttributeDefinitionId = mdd.Id
    LEFT JOIN Location.LocationAttributeDefinition ckd
        ON ckd.LocationTypeDefinitionId = 16 AND ckd.AttributeName = N'ConnectionKind' AND ckd.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttribute ckv ON ckv.LocationId = p.Id AND ckv.LocationAttributeDefinitionId = ckd.Id
    -- The parent Terminal (DefId 7). A DEPRECATED parent contributes no IpAddress,
    -- so a bridge printer under a retired terminal resolves to NULL and is reported
    -- unresolved rather than silently dialling a machine nobody runs any more.
    LEFT JOIN Location.Location t
        ON t.Id = p.ParentLocationId AND t.LocationTypeDefinitionId = 7 AND t.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttributeDefinition tipd
        ON tipd.LocationTypeDefinitionId = 7 AND tipd.AttributeName = N'IpAddress' AND tipd.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttribute tipv ON tipv.LocationId = t.Id AND tipv.LocationAttributeDefinitionId = tipd.Id
    -- Compute the kind and the endpoint ONCE, so EndpointSource cannot disagree
    -- with Endpoint.
    CROSS APPLY (SELECT Kind = ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(ckv.AttributeValue, N''))), N''), N'Networked')) k
    CROSS APPLY (SELECT Ep = Location.ufn_PrinterEndpoint(k.Kind, epv.AttributeValue, tipv.AttributeValue)) e
    WHERE p.Id = @PrinterLocationId
      AND p.LocationTypeDefinitionId = 16
      AND p.DeprecatedAt IS NULL;
END;
GO
```

- [ ] **Step 4: Rewrite `Terminal_GetPrinter`**

Replace the whole body of `sql/migrations/repeatable/R__Location_Terminal_GetPrinter.sql` with:

```sql
-- ============================================================
-- Repeatable:  R__Location_Terminal_GetPrinter.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-30
-- Version:     2.0
-- Description: Arc 2 Phase 4 (Spec 2 sec 5). Resolves the child Printer Location
--              of a Terminal + the endpoint it is ACTUALLY dialled at, for the
--              onStartup printer-into-session resolution and the LTT dispatch
--              path. The Printer is a LocationTypeDefinition (Name 'Printer',
--              DefId 16) child of the Terminal. Read proc: one row (TOP 1) or
--              empty when the terminal has no Printer child (the no-printer /
--              FALLBACK terminal case -> session.custom.printer stays empty ->
--              fail-fast on dispatch). Attributes are LEFT-joined so a row
--              returns even when a value is unset.
--
--              v2.0: Endpoint is RESOLVED through Location.ufn_PrinterEndpoint.
--              For ConnectionKind = 'UsbBridge' it derives from THIS terminal's
--              own IpAddress plus port 9100 (spec section 8.1) -- the bridge runs
--              on the terminal PC, so there is no second address to store. Every
--              other kind returns the stored value untouched.
--              ConnectionKind / StoredEndpoint / TerminalIpAddress /
--              EndpointSource are new columns; BlueRidge.Location.Terminal.
--              getPrinter maps only the four it already used, so adding them is
--              safe, and session.custom.printer.endpoint now carries the resolved
--              value with no Python change.
-- ============================================================
CREATE OR ALTER PROCEDURE Location.Terminal_GetPrinter
    @TerminalLocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 1
        p.Id                AS LocationId,
        p.Code              AS Code,
        p.Name              AS Name,
        e.Ep                AS Endpoint,
        mdv.AttributeValue  AS Model,
        ckv.AttributeValue  AS ConnectionKind,
        epv.AttributeValue  AS StoredEndpoint,
        tipv.AttributeValue AS TerminalIpAddress,
        CASE WHEN e.Ep IS NULL          THEN N'unresolved'
             WHEN k.Kind = N'UsbBridge' THEN N'derived-terminal-ip'
             ELSE N'stored' END          AS EndpointSource
    FROM Location.Location p
    INNER JOIN Location.LocationTypeDefinition def ON def.Id = p.LocationTypeDefinitionId
    LEFT JOIN Location.LocationAttributeDefinition epd
        ON epd.LocationTypeDefinitionId = def.Id AND epd.AttributeName = N'Endpoint' AND epd.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttribute epv
        ON epv.LocationId = p.Id AND epv.LocationAttributeDefinitionId = epd.Id
    LEFT JOIN Location.LocationAttributeDefinition mdd
        ON mdd.LocationTypeDefinitionId = def.Id AND mdd.AttributeName = N'Model' AND mdd.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttribute mdv
        ON mdv.LocationId = p.Id AND mdv.LocationAttributeDefinitionId = mdd.Id
    LEFT JOIN Location.LocationAttributeDefinition ckd
        ON ckd.LocationTypeDefinitionId = def.Id AND ckd.AttributeName = N'ConnectionKind' AND ckd.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttribute ckv
        ON ckv.LocationId = p.Id AND ckv.LocationAttributeDefinitionId = ckd.Id
    -- The terminal IS the parameter here, so the IpAddress lookup is direct.
    LEFT JOIN Location.LocationAttributeDefinition tipd
        ON tipd.LocationTypeDefinitionId = 7 AND tipd.AttributeName = N'IpAddress' AND tipd.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttribute tipv
        ON tipv.LocationId = @TerminalLocationId AND tipv.LocationAttributeDefinitionId = tipd.Id
    CROSS APPLY (SELECT Kind = ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(ckv.AttributeValue, N''))), N''), N'Networked')) k
    CROSS APPLY (SELECT Ep = Location.ufn_PrinterEndpoint(k.Kind, epv.AttributeValue, tipv.AttributeValue)) e
    WHERE p.ParentLocationId = @TerminalLocationId
      AND def.Name = N'Printer'
      AND p.DeprecatedAt IS NULL
    ORDER BY p.SortOrder, p.Id;
END;
GO
```

- [ ] **Step 5: Rewrite `PrinterFgAssignment_ListForStation`**

Replace the whole body of `sql/migrations/repeatable/R__Location_PrinterFgAssignment_ListForStation.sql` with:

```sql
-- ============================================================
-- Repeatable:  R__Location_PrinterFgAssignment_ListForStation.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-30
-- Version:     2.0
-- Description: One row per active child Printer (DefId 16) of a station terminal,
--   LEFT-joined to its FG assignment (unassigned printers appear with NULLs) +
--   the endpoint it is ACTUALLY dialled at. Drives the printer-card panel.
--   Ordered by the assignment SortOrder then printer Id. Empty set = no child
--   printers.
--
--   v2.0: Endpoint is RESOLVED through Location.ufn_PrinterEndpoint -- derived
--   from the station terminal's IpAddress plus 9100 for ConnectionKind =
--   'UsbBridge', stored value untouched for everything else (spec section 8.1).
--   The plant-floor PrinterCard's Validate button therefore probes a real address
--   with no view change. New columns: StoredEndpoint, TerminalIpAddress,
--   EndpointSource.
-- ============================================================
CREATE OR ALTER PROCEDURE Location.PrinterFgAssignment_ListForStation
    @StationTerminalLocationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        p.Id                AS PrinterLocationId,
        p.Code              AS PrinterCode,
        p.Name              AS PrinterName,
        e.Ep                AS Endpoint,
        ckv.AttributeValue  AS ConnectionKind,
        pfa.ItemId          AS AssignedItemId,
        i.PartNumber        AS PartNumber,
        i.Description       AS Description,
        ISNULL(pfa.SortOrder, p.SortOrder) AS SortOrder,
        epv.AttributeValue  AS StoredEndpoint,
        tipv.AttributeValue AS TerminalIpAddress,
        CASE WHEN e.Ep IS NULL          THEN N'unresolved'
             WHEN k.Kind = N'UsbBridge' THEN N'derived-terminal-ip'
             ELSE N'stored' END          AS EndpointSource
    FROM Location.Location p
    LEFT JOIN Location.LocationAttributeDefinition epd
        ON epd.LocationTypeDefinitionId = 16 AND epd.AttributeName = N'Endpoint' AND epd.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttribute epv ON epv.LocationId = p.Id AND epv.LocationAttributeDefinitionId = epd.Id
    LEFT JOIN Location.LocationAttributeDefinition ckd
        ON ckd.LocationTypeDefinitionId = 16 AND ckd.AttributeName = N'ConnectionKind' AND ckd.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttribute ckv ON ckv.LocationId = p.Id AND ckv.LocationAttributeDefinitionId = ckd.Id
    LEFT JOIN Location.LocationAttributeDefinition tipd
        ON tipd.LocationTypeDefinitionId = 7 AND tipd.AttributeName = N'IpAddress' AND tipd.DeprecatedAt IS NULL
    LEFT JOIN Location.LocationAttribute tipv
        ON tipv.LocationId = @StationTerminalLocationId AND tipv.LocationAttributeDefinitionId = tipd.Id
    LEFT JOIN Location.PrinterFgAssignment pfa ON pfa.PrinterLocationId = p.Id
    LEFT JOIN Parts.Item i ON i.Id = pfa.ItemId
    CROSS APPLY (SELECT Kind = ISNULL(NULLIF(LTRIM(RTRIM(ISNULL(ckv.AttributeValue, N''))), N''), N'Networked')) k
    CROSS APPLY (SELECT Ep = Location.ufn_PrinterEndpoint(k.Kind, epv.AttributeValue, tipv.AttributeValue)) e
    WHERE p.ParentLocationId = @StationTerminalLocationId
      AND p.LocationTypeDefinitionId = 16
      AND p.DeprecatedAt IS NULL
    ORDER BY ISNULL(pfa.SortOrder, p.SortOrder), p.Id;
END;
GO
```

Note: the original had `i.Description        AS Description` with a stray double space; the replacement normalizes it. Behaviour identical.

- [ ] **Step 6: Widen the three existing temp tables in the 0029 suite**

These `INSERT ... EXEC` against the changed procs and will fail on column count until the temp tables match.

In `sql/tests/0029_AssemblyPrinterCards/020_Printer_GetById.sql`, replace **both** occurrences of:

```sql
CREATE TABLE #P (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200), Endpoint NVARCHAR(200), Model NVARCHAR(200), ConnectionKind NVARCHAR(50));
```
and
```sql
CREATE TABLE #U (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200), Endpoint NVARCHAR(200), Model NVARCHAR(200), ConnectionKind NVARCHAR(50));
```

with the nine-column form (keeping each table's own name):

```sql
CREATE TABLE #P (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200), Endpoint NVARCHAR(255), Model NVARCHAR(255), ConnectionKind NVARCHAR(255), StoredEndpoint NVARCHAR(255), TerminalIpAddress NVARCHAR(255), EndpointSource NVARCHAR(30));
```

In `sql/tests/0029_AssemblyPrinterCards/030_PrinterFgAssignment_ListForStation.sql` and `sql/tests/0029_AssemblyPrinterCards/040_PrinterFgAssignment_SaveAll.sql`, replace each occurrence of:

```sql
CREATE TABLE #L (PrinterLocationId BIGINT, PrinterCode NVARCHAR(50), PrinterName NVARCHAR(200), Endpoint NVARCHAR(200), ConnectionKind NVARCHAR(50), AssignedItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), SortOrder INT);
```

with:

```sql
CREATE TABLE #L (PrinterLocationId BIGINT, PrinterCode NVARCHAR(50), PrinterName NVARCHAR(200), Endpoint NVARCHAR(255), ConnectionKind NVARCHAR(255), AssignedItemId BIGINT, PartNumber NVARCHAR(50), Description NVARCHAR(500), SortOrder INT, StoredEndpoint NVARCHAR(255), TerminalIpAddress NVARCHAR(255), EndpointSource NVARCHAR(30));
```

(`040` has one occurrence at line ~88; `030` has one at line ~18. Confirm with `grep -n "CREATE TABLE #L" sql/tests/0029_AssemblyPrinterCards/*.sql`.)

- [ ] **Step 7: Apply the three procs and run the tests**

```bash
sqlcmd -S localhost -d MPP_MES_Test -i sql/migrations/repeatable/R__Location_Printer_GetById.sql -b -I -C
sqlcmd -S localhost -d MPP_MES_Test -i sql/migrations/repeatable/R__Location_Terminal_GetPrinter.sql -b -I -C
sqlcmd -S localhost -d MPP_MES_Test -i sql/migrations/repeatable/R__Location_PrinterFgAssignment_ListForStation.sql -b -I -C
```

Run: `.\sql\tests\Run-Tests.ps1 -Filter "0101"` -> 0 failures.
Run: `.\sql\tests\Run-Tests.ps1 -Filter "0029"` -> 0 failures (the pre-existing printer-card tests stay green; that is the regression guard for the live `Networked` rows).
Run: `.\sql\tests\Run-Tests.ps1` (full) -> 0 failures.

If the full run exits 1 with 0 reported failures, a test file's `sqlcmd` errored -- usually a teardown FK ordering problem. Read `sql/tests/test_output.txt` for the file that broke.

- [ ] **Step 8: Verify the live Dev rows read back unchanged, read-only**

The three live `Networked` printers are the thing this task must not disturb. Apply the three repeatables to `MPP_MES_Dev` and read them back.

```bash
sqlcmd -S localhost -d MPP_MES_Dev -i sql/migrations/versioned/0101_printer_usbbridge_connectionkind.sql -b -I -C
sqlcmd -S localhost -d MPP_MES_Dev -i sql/migrations/repeatable/R__Location_ufn_PrinterEndpoint.sql -b -I -C
sqlcmd -S localhost -d MPP_MES_Dev -i sql/migrations/repeatable/R__Location_Location_SaveAll.sql -b -I -C
sqlcmd -S localhost -d MPP_MES_Dev -i sql/migrations/repeatable/R__Location_Printer_GetById.sql -b -I -C
sqlcmd -S localhost -d MPP_MES_Dev -i sql/migrations/repeatable/R__Location_Terminal_GetPrinter.sql -b -I -C
sqlcmd -S localhost -d MPP_MES_Dev -i sql/migrations/repeatable/R__Location_PrinterFgAssignment_ListForStation.sql -b -I -C
```

Then, read-only:

```bash
sqlcmd -S localhost -d MPP_MES_Dev -Q "SET NOCOUNT ON; SELECT p.Code, Kind=ISNULL(ck.AttributeValue,'(unset)'), Stored=ISNULL(ep.AttributeValue,'(none)'), Resolved=ISNULL(Location.ufn_PrinterEndpoint(ck.AttributeValue, ep.AttributeValue, tip.AttributeValue),'(null)'), TermIp=ISNULL(tip.AttributeValue,'(none)') FROM Location.Location p LEFT JOIN Location.LocationAttributeDefinition epd ON epd.LocationTypeDefinitionId=16 AND epd.AttributeName='Endpoint' AND epd.DeprecatedAt IS NULL LEFT JOIN Location.LocationAttribute ep ON ep.LocationId=p.Id AND ep.LocationAttributeDefinitionId=epd.Id LEFT JOIN Location.LocationAttributeDefinition ckd ON ckd.LocationTypeDefinitionId=16 AND ckd.AttributeName='ConnectionKind' AND ckd.DeprecatedAt IS NULL LEFT JOIN Location.LocationAttribute ck ON ck.LocationId=p.Id AND ck.LocationAttributeDefinitionId=ckd.Id LEFT JOIN Location.Location t ON t.Id=p.ParentLocationId AND t.LocationTypeDefinitionId=7 AND t.DeprecatedAt IS NULL LEFT JOIN Location.LocationAttributeDefinition tipd ON tipd.LocationTypeDefinitionId=7 AND tipd.AttributeName='IpAddress' AND tipd.DeprecatedAt IS NULL LEFT JOIN Location.LocationAttribute tip ON tip.LocationId=t.Id AND tip.LocationAttributeDefinitionId=tipd.Id WHERE p.LocationTypeDefinitionId=16 AND p.DeprecatedAt IS NULL ORDER BY p.Code;" -b -I -C -W -s "|"
```

Expected: every existing printer shows `Resolved` **identical** to `Stored`. No row shows a derived value yet, because no row has been re-kinded. Specifically, the two `172.17.20.228:9100` rows and the `172.17.20.229:9100` row must read `Resolved = Stored`.

If any existing row's `Resolved` differs from `Stored`, **stop and report it** -- that means a printer already carries `ConnectionKind = UsbBridge` in Dev, which nothing in this plan put there.

- [ ] **Step 9: Also survey the 77 terminals' IpAddress shape, read-only**

Spec section 10.2 asks for this before the rollout, not during it.

```bash
sqlcmd -S localhost -d MPP_MES_Dev -Q "SET NOCOUNT ON; SELECT t.Code, Ip=la.AttributeValue, Shape=CASE WHEN la.AttributeValue LIKE '%://%' THEN 'URL - will not derive' WHEN la.AttributeValue LIKE '%[^0-9.]%' THEN 'not a dotted quad' WHEN la.AttributeValue IS NULL THEN 'missing' ELSE 'ok' END FROM Location.Location t INNER JOIN Location.LocationAttributeDefinition lad ON lad.LocationTypeDefinitionId=7 AND lad.AttributeName='IpAddress' AND lad.DeprecatedAt IS NULL LEFT JOIN Location.LocationAttribute la ON la.LocationId=t.Id AND la.LocationAttributeDefinitionId=lad.Id WHERE t.LocationTypeDefinitionId=7 AND t.DeprecatedAt IS NULL AND (la.AttributeValue IS NULL OR la.AttributeValue LIKE '%://%' OR la.AttributeValue LIKE '%[^0-9.]%') ORDER BY t.Code;" -b -I -C -W -s "|"
```

Expected: `MA2-6MACH-AOUT3` appears with `URL - will not derive` (known, spec section 10.2, **do not fix it here** -- it is a live 6MA parallel-run row). Record everything else this prints and report it; do not change any of it. A terminal that cannot derive is a commissioning input, not a code change.

- [ ] **Step 10: Commit**

```bash
git add sql/migrations/repeatable/R__Location_Printer_GetById.sql sql/migrations/repeatable/R__Location_Terminal_GetPrinter.sql sql/migrations/repeatable/R__Location_PrinterFgAssignment_ListForStation.sql sql/tests/0029_AssemblyPrinterCards/020_Printer_GetById.sql sql/tests/0029_AssemblyPrinterCards/030_PrinterFgAssignment_ListForStation.sql sql/tests/0029_AssemblyPrinterCards/040_PrinterFgAssignment_SaveAll.sql sql/tests/0101_PrinterUsbBridge/030_read_procs_resolve_endpoint.sql
git commit -m "feat(sql): the three printer reads resolve the endpoint, so no caller has to"
```

---

### Task 5: The dropdown offers the third kind

One Python list. The `LocationAttributeValueRow` component renders a dropdown whenever `BlueRidge.Location.AttributeOptions.forAttr(name)` returns a non-empty list, so **no view edit is needed** for the option to appear.

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Location/AttributeOptions/code.py`

**Interfaces:**
- Consumes: nothing
- Produces: `forAttr("ConnectionKind")` returns three `{label, value}` dicts, bound by `LocationAttributeValueRow`'s `custom.options` expression.

- [ ] **Step 1: Add the option**

In `AttributeOptions/code.py`, replace:

```python
_CONNECTION_KINDS = [
    ("Networked", "Networked (IP:port - validatable)"),
    ("Hardwired", "Hardwired (print-queue name)"),
]
```

with:

```python
# Order is deliberate: UsbBridge is what MPP is deploying to 54 terminals, and it
# is the one kind that needs NO endpoint typed, so it goes first to be the obvious
# pick. Networked stays second because three live printers use it.
_CONNECTION_KINDS = [
    ("UsbBridge", "USB bridge (no endpoint - derives from the terminal IP)"),
    ("Networked", "Networked (IP:port - validatable)"),
    ("Hardwired", "Hardwired (print-queue name)"),
]
```

- [ ] **Step 2: Update the module docstring**

In the same file, replace the line:

```python
     - ConnectionKind is the Printer networked/hardwired choice (FAT #14).
```

with:

```python
     - ConnectionKind is the Printer transport choice. UsbBridge printers store
       NO endpoint -- Location.ufn_PrinterEndpoint derives it from the parent
       Terminal's IpAddress plus port 9100 (design 2026-09-29 sec 8.1). This list
       is the ONLY place the three values are enumerated anywhere in the system:
       Location.LocationAttributeDefinition has no allowed-values column and
       LocationAttribute.AttributeValue is one NVARCHAR shared by every attribute,
       so nothing in SQL constrains the set. The dropdown is also authored
       allowCustomOptions = true, so this list is advisory even in the UI --
       Location.ufn_PrinterEndpoint is written to fall back to the stored endpoint
       for any kind it does not recognise rather than guess.
```

and append to the Change Log:

```python
       2026-09-30 - UsbBridge added as a third ConnectionKind (migration 0101).
```

- [ ] **Step 3: Confirm the file still parses**

Run: `python -c "import ast, io; ast.parse(io.open('ignition/projects/Core/ignition/script-python/BlueRidge/Location/AttributeOptions/code.py', encoding='utf-8').read()); print('parses')"`
Expected: `parses`

- [ ] **Step 4: Commit**

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Location/AttributeOptions/code.py
git commit -m "feat(ignition): the printer ConnectionKind dropdown offers USB bridge"
```

---

### Task 6: `LabelTransport` reads a `?STATUS` reply and can send one

`_parseAck` already parses the ACK grammar. `?STATUS` uses the **same** grammar with three different keys, so it is extended, not duplicated. `probeStatus` is `_sendTcp` with a different payload -- the framing, half-close, bounded read and parse are identical and must not be copied.

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LabelTransport/code.py`
- Modify: `ignition/tests/test_label_transport_ack.py`

**Interfaces:**
- Consumes: `_parseAck(line) -> dict`, `_sendTcp(host, port, zpl) -> {ok, error, ack}` (both existing)
- Produces:
  - `_parseAck` return dict gains `bridge: str|None`, `ready: bool|None`, `jobs: int|None`. **`ready` is `None` when the line did not state it**, which is how a print ACK is told from a status ACK.
  - `_describeProbe(outcome) -> {reached: bool, isBridge: bool, bridge, queue, ready, jobs, error}` -- pure, self-contained
  - `probeStatus(host, port) -> the same dict`, consumed by `BlueRidge.Location.Printer.validateEndpoint` in Task 7

- [ ] **Step 1: Write the failing tests**

In `ignition/tests/test_label_transport_ack.py`, change the extractor's wanted set from:

```python
WANTED = ("_parseAck", "_unquote", "_dispatchLogParams", "_resolveLogParams")
```

to:

```python
WANTED = ("_parseAck", "_unquote", "_dispatchLogParams", "_resolveLogParams",
          "_describeProbe")
```

and append to the file:

```python
# ---------------------------------------------------------------- ?STATUS
# PROTOCOL.md section "?STATUS". The probe is what makes commissioning 54
# printers tractable -- it proves route, firewall, service AND queue binding in
# one call with no label consumed -- so its grammar is pinned here exactly as
# the print ACK's is.


def test_a_status_reply_is_parsed_by_the_same_parser(helpers):
    """One grammar, one parser. A second copy would drift."""
    got = helpers["_parseAck"](
        "OK bridge=1.0.0 queue='Zebra GX420d (RAW)' ready=true jobs=0")
    assert got["acked"] is True
    assert got["ok"] is True
    assert got["bridge"] == "1.0.0"
    assert got["queue"] == "Zebra GX420d (RAW)"
    assert got["ready"] is True
    assert got["jobs"] == 0


def test_a_not_ready_queue_is_reported_as_such(helpers):
    got = helpers["_parseAck"]("OK bridge=1.0.0 queue='Q' ready=false jobs=3")
    assert got["ready"] is False
    assert got["jobs"] == 3


def test_a_print_ack_states_no_readiness(helpers):
    """ready is None, not False, when the line never mentioned it -- that is how
       a print ACK is told apart from a status ACK."""
    got = helpers["_parseAck"]("OK queue='Q' job=41 bytes=1264")
    assert got["ready"] is None
    assert got["jobs"] is None
    assert got["bridge"] is None


def test_jobs_and_job_are_not_confused(helpers):
    got = helpers["_parseAck"]("OK bridge=1.0.0 queue='Q' ready=true jobs=7")
    assert got["jobs"] == 7
    assert got["job"] is None


def test_an_unknown_command_err_is_carried_through(helpers):
    got = helpers["_parseAck"]("ERR unknown command '?WAT'")
    assert got["acked"] is True
    assert got["ok"] is False
    assert "?WAT" in got["error"]


def test_a_probe_that_could_not_connect_is_not_reached(helpers):
    out = {"ok": False, "error": "Connect timed out",
           "ack": {"acked": False, "ok": False, "queue": None, "job": None,
                   "bytes": None, "error": None, "bridge": None,
                   "ready": None, "jobs": None}}
    got = helpers["_describeProbe"](out)
    assert got["reached"] is False
    assert got["isBridge"] is False
    assert got["error"] == "Connect timed out"


def test_a_silent_far_end_is_reached_but_is_not_the_bridge(helpers):
    """A real networked Zebra on raw 9100 never replies (PROTOCOL.md
       'Non-bridge printers'). It is a legitimate printer and NOT a bridge --
       conflating the two sends whoever is commissioning to the wrong machine."""
    out = {"ok": True, "error": None,
           "ack": {"acked": False, "ok": False, "queue": None, "job": None,
                   "bytes": None, "error": None, "bridge": None,
                   "ready": None, "jobs": None}}
    got = helpers["_describeProbe"](out)
    assert got["reached"] is True
    assert got["isBridge"] is False
    assert got["error"] is None


def test_a_bridge_err_is_the_bridge_answering(helpers):
    out = {"ok": False, "error": "queue not found: 'ZDesigner GX420d'",
           "ack": {"acked": True, "ok": False, "queue": None, "job": None,
                   "bytes": None, "error": "queue not found: 'ZDesigner GX420d'",
                   "bridge": None, "ready": None, "jobs": None}}
    got = helpers["_describeProbe"](out)
    assert got["reached"] is True
    assert got["isBridge"] is True
    assert got["ready"] is False
    assert "ZDesigner GX420d" in got["error"]


def test_a_good_status_carries_the_bound_queue(helpers):
    out = {"ok": True, "error": None,
           "ack": {"acked": True, "ok": True, "queue": "Zebra GX420d (RAW)",
                   "job": None, "bytes": None, "error": None,
                   "bridge": "1.0.0", "ready": True, "jobs": 0}}
    got = helpers["_describeProbe"](out)
    assert got["reached"] is True
    assert got["isBridge"] is True
    assert got["ready"] is True
    assert got["queue"] == "Zebra GX420d (RAW)"
    assert got["bridge"] == "1.0.0"
    assert got["jobs"] == 0
```

- [ ] **Step 2: Run to verify they fail**

Run: `python -m pytest ignition/tests/test_label_transport_ack.py -v`
Expected: the module-scope fixture fails everything with `helper(s) missing from the module: _describeProbe`.

- [ ] **Step 3: Extend `_parseAck`**

In `LabelTransport/code.py`, replace the initial dict in `_parseAck`:

```python
    out = {"acked": False, "ok": False, "queue": None,
           "job": None, "bytes": None, "error": None}
```

with:

```python
    # bridge / ready / jobs are the ?STATUS keys (PROTOCOL.md section "?STATUS").
    # ready stays None when the line never stated it -- that is how a PRINT ack
    # ("OK queue=.. job=.. bytes=..") is told apart from a STATUS ack, and why it
    # is not defaulted to False.
    out = {"acked": False, "ok": False, "queue": None,
           "job": None, "bytes": None, "error": None,
           "bridge": None, "ready": None, "jobs": None}
```

and replace the key-handling tail of the same function:

```python
        if k == "queue":
            out["queue"] = _unquote(v)
        elif k in ("job", "bytes"):
            try:
                out[k] = int(v)
            except (TypeError, ValueError):
                out[k] = None
    return out
```

with:

```python
        if k == "queue":
            out["queue"] = _unquote(v)
        elif k == "bridge":
            out["bridge"] = _unquote(v)
        elif k == "ready":
            # PROTOCOL.md: "ready is true or false". Anything else is not ready,
            # which is the honest read of a value we do not understand.
            out["ready"] = (_unquote(v).strip().lower() == "true")
        elif k in ("job", "bytes", "jobs"):
            try:
                out[k] = int(v)
            except (TypeError, ValueError):
                out[k] = None
    return out
```

- [ ] **Step 4: Add `_describeProbe` and `probeStatus`**

In `LabelTransport/code.py`, insert immediately after `_sendTcp` (before `def _sendQueue`):

```python
def _describeProbe(outcome):
    """Classify one ?STATUS exchange. Self-contained (no BlueRidge.*, no java)
       so the tests can exec it.

       reached  -- the socket connected and the write completed
       isBridge -- the far end answered at all, so it speaks this protocol

       The three failure shapes are kept apart on purpose, because each sends
       whoever is commissioning to a different place:
         not reached            -> the service is down, or packets are dropped
         reached, not a bridge  -> something else owns 9100 on that PC, OR it is
                                   a real networked Zebra, which never replies
                                   (PROTOCOL.md 'Non-bridge printers')
         bridge answered ERR    -> right machine, wrong queue name
       Flattening these into one 'printer offline' was the 2026-09-29 cost."""
    out = outcome or {}
    ack = out.get("ack") or {}
    if not out.get("ok") and not ack.get("acked"):
        return {"reached": False, "isBridge": False, "bridge": None, "queue": None,
                "ready": None, "jobs": None, "error": out.get("error") or "unknown"}
    if not ack.get("acked"):
        return {"reached": True, "isBridge": False, "bridge": None, "queue": None,
                "ready": None, "jobs": None, "error": None}
    if not ack.get("ok"):
        return {"reached": True, "isBridge": True, "bridge": ack.get("bridge"),
                "queue": ack.get("queue"), "ready": False, "jobs": ack.get("jobs"),
                "error": ack.get("error") or "unknown"}
    return {"reached": True, "isBridge": True, "bridge": ack.get("bridge"),
            "queue": ack.get("queue"), "ready": bool(ack.get("ready")),
            "jobs": ack.get("jobs"), "error": None}


def probeStatus(host, port):
    """PROTOCOL.md section "?STATUS": connect, send the command, half-close, read
       one line. NO LABEL IS CONSUMED, so this is safe to call against a live
       printer's bridge at any time -- which is the whole point: it proves route,
       firewall, service and queue binding in one call, and that is what makes
       commissioning 54 printers tractable instead of manufacturing a real
       container per printer.

       Reuses _sendTcp because the PAYLOAD is the only difference between a print
       and a probe. The framing, the half-close, the bounded read and _parseAck
       are identical, and a second copy of them would drift from the frozen
       protocol. Never raises."""
    return _describeProbe(_sendTcp(host, port, "?STATUS"))
```

- [ ] **Step 5: Note the new export in the module docstring**

In `LabelTransport/code.py`, append to the module docstring, immediately before the closing `"""`:

```
   Also owns the ?STATUS PROBE (probeStatus), because it owns the socket and the
   ACK grammar. The probe prints nothing and is the basis of the Config Tool's
   Test printer action (design 2026-09-29 sec 4.2 / 9).
```

- [ ] **Step 6: Run to verify they pass**

Run: `python -m pytest ignition/tests/test_label_transport_ack.py -v`
Expected: PASS, 21 passed (12 pre-existing + 9 new).

- [ ] **Step 7: Commit**

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Lots/LabelTransport/code.py ignition/tests/test_label_transport_ack.py
git commit -m "feat(ignition): one parser reads both the print ack and the ?STATUS reply"
```

---

### Task 7: `Test this printer`

`validateEndpoint` keeps its signature and its `Hardwired` / `Networked` behaviour unchanged, and gains a `UsbBridge` branch that probes. `testPrinter(id)` is the id-driven entry point; `testFromSelection(id, attributes)` is what the Plant Hierarchy button calls.

**Files:**
- Modify: `ignition/projects/Core/ignition/script-python/BlueRidge/Location/Printer/code.py`
- Test: `ignition/tests/test_printer_probe.py`

**Interfaces:**
- Consumes: `BlueRidge.Lots.LabelTransport.probeStatus(host, port)` from Task 6; `location/Printer_GetById` (v2.0 columns) from Task 4
- Produces, all returning the `{status, level, title, message}` shape that maps 1:1 onto `Common.Notify.toast(title, message, level)`:
  - `validateEndpoint(endpoint, connectionKind=None)` -- signature unchanged
  - `testPrinter(printerLocationId)`
  - `testFromSelection(printerLocationId, attributes)` -- consumed by the view in Task 8
  - plus pure helpers `_kindOrDefault(kind) -> str`, `_draftPrinterFields(rows) -> (endpoint, kind)`, `_describeBridgeResult(host, port, probe) -> dict`, `_withSource(message, row) -> str`

- [ ] **Step 1: Write the failing tests**

Create `ignition/tests/test_printer_probe.py`:

```python
"""Guard for the Config Tool's Test printer action.

The point of this action is that it makes 54 printers commissionable without
manufacturing 54 containers -- so what it SAYS matters as much as whether it
works. Each of the four outcomes sends a person to a different machine:

    unreachable  -> the bridge service, or the firewall on the terminal PC
    not a bridge -> something else owns 9100 there
    refused      -> right machine, wrong queue name
    not ready    -> right queue, printer offline or paused

These tests pin those four apart. Flattening them into one "printer offline"
is the failure mode the 2026-09-29 bring-up actually hit.

Printer/code.py imports java.net at module level, so it cannot be imported under
CPython. These tests ast-extract the self-contained helpers and exec those --
the same approach as test_label_transport_ack.py.

Run: python -m pytest ignition/tests/test_printer_probe.py
"""

import ast
import io
import os

import pytest

MODULE = os.path.join(
    os.path.dirname(__file__), os.pardir,
    "projects", "Core", "ignition", "script-python",
    "BlueRidge", "Location", "Printer", "code.py",
)

WANTED = ("_parseHostPort", "_kindOrDefault", "_draftPrinterFields",
          "_describeBridgeResult", "_withSource")


def load_helpers(path=MODULE):
    src = io.open(path, encoding="utf-8").read()
    tree = ast.parse(src)
    keep = [n for n in tree.body
            if isinstance(n, ast.FunctionDef) and n.name in WANTED]
    ns = {"_DEFAULT_ZEBRA_PORT": 9100}
    exec(compile(ast.Module(body=keep, type_ignores=[]), path, "exec"), ns)
    return ns


@pytest.fixture(scope="module")
def helpers():
    ns = load_helpers()
    missing = [n for n in WANTED if n not in ns]
    if missing:
        pytest.fail("helper(s) missing from the module: %s" % ", ".join(missing))
    return ns


def _probe(**kw):
    base = {"reached": True, "isBridge": True, "bridge": "1.0.0",
            "queue": "Zebra GX420d (RAW)", "ready": True, "jobs": 0, "error": None}
    base.update(kw)
    return base


def test_an_absent_kind_reads_as_networked(helpers):
    """The same default Location.ufn_PrinterEndpoint and Location_SaveAll apply,
       because it is the attribute's DefaultValue."""
    for v in (None, "", "   "):
        assert helpers["_kindOrDefault"](v) == "Networked"
    assert helpers["_kindOrDefault"](" UsbBridge ") == "UsbBridge"


def test_a_ready_bridge_names_the_queue_it_is_bound_to(helpers):
    got = helpers["_describeBridgeResult"]("172.17.20.5", 9100, _probe())
    assert got["status"] is True
    assert got["level"] == "success"
    assert "Zebra GX420d (RAW)" in got["message"]
    assert "172.17.20.5:9100" in got["message"]


def test_nothing_listening_points_at_the_service_and_the_firewall(helpers):
    got = helpers["_describeBridgeResult"](
        "172.17.20.5", 9100,
        _probe(reached=False, isBridge=False, bridge=None, queue=None,
               ready=None, error="Connection refused: getsockopt"))
    assert got["status"] is False
    assert got["level"] == "error"
    assert "Connection refused" in got["message"]
    assert "MesZebraBridge" in got["message"]


def test_a_silent_far_end_is_not_reported_as_a_working_printer(helpers):
    """Something accepted the connection but did not answer ?STATUS. For a
       UsbBridge printer that is a real fault -- the old bare-connect test passed
       in exactly this state and a label still never printed."""
    got = helpers["_describeBridgeResult"](
        "172.17.20.5", 9100,
        _probe(isBridge=False, bridge=None, queue=None, ready=None))
    assert got["status"] is False
    assert "did not answer" in got["message"]


def test_a_wrong_queue_name_is_a_different_diagnosis(helpers):
    """The bridge ANSWERED, so the network is fine and the queue is wrong. This
       is the ZDesigner-vs-Zebra trap, and it must not read as connectivity."""
    got = helpers["_describeBridgeResult"](
        "172.17.20.5", 9100,
        _probe(ready=False, queue=None,
               error="queue not found: 'ZDesigner GX420d'"))
    assert got["status"] is False
    assert "ZDesigner GX420d" in got["message"]


def test_a_bound_but_not_ready_queue_says_which_queue(helpers):
    got = helpers["_describeBridgeResult"](
        "172.17.20.5", 9100, _probe(ready=False, jobs=3))
    assert got["status"] is False
    assert "Zebra GX420d (RAW)" in got["message"]
    assert "3" in got["message"]


def test_a_derived_endpoint_says_where_the_host_came_from(helpers):
    """Without this the message names an address that appears nowhere on the
       printer row, because a UsbBridge printer stores no endpoint at all."""
    msg = helpers["_withSource"]("Printer ready.", {
        "EndpointSource": "derived-terminal-ip",
        "TerminalIpAddress": "172.17.20.5",
        "ConnectionKind": "UsbBridge", "StoredEndpoint": None})
    assert "172.17.20.5" in msg
    assert "terminal" in msg.lower()


def test_an_unresolved_endpoint_dumps_the_three_facts_that_explain_it(helpers):
    msg = helpers["_withSource"]("No endpoint.", {
        "EndpointSource": "unresolved", "TerminalIpAddress": None,
        "ConnectionKind": "UsbBridge", "StoredEndpoint": None})
    assert "UsbBridge" in msg


def test_a_stored_endpoint_says_so(helpers):
    msg = helpers["_withSource"]("Reachable.", {
        "EndpointSource": "stored", "TerminalIpAddress": None,
        "ConnectionKind": "Networked", "StoredEndpoint": "172.17.20.228:9100"})
    assert "stored" in msg


def test_the_draft_reader_pulls_endpoint_and_kind(helpers):
    ep, kind = helpers["_draftPrinterFields"]([
        {"name": "Endpoint", "value": "", "defaultValue": None},
        {"name": "Model", "value": "GX420d", "defaultValue": None},
        {"name": "ConnectionKind", "value": "UsbBridge", "defaultValue": "Networked"},
    ])
    assert ep == ""
    assert kind == "UsbBridge"


def test_the_draft_reader_falls_back_to_the_default_value(helpers):
    ep, kind = helpers["_draftPrinterFields"]([
        {"name": "Endpoint", "value": None, "defaultValue": None},
        {"name": "ConnectionKind", "value": None, "defaultValue": "Networked"},
    ])
    assert ep == ""
    assert kind == "Networked"


def test_the_draft_reader_survives_junk_rows(helpers):
    ep, kind = helpers["_draftPrinterFields"]([None, {}, {"name": "Endpoint"}])
    assert ep == ""
    assert kind == ""


def test_a_port_less_endpoint_still_parses_to_the_zebra_default(helpers):
    """Unchanged behaviour, pinned because Task 4 now feeds this function a
       value SQL composed rather than one a human typed."""
    assert helpers["_parseHostPort"]("172.17.20.5") == ("172.17.20.5", 9100)
    assert helpers["_parseHostPort"]("172.17.20.5:9101") == ("172.17.20.5", 9101)
```

- [ ] **Step 2: Run to verify they fail**

Run: `python -m pytest ignition/tests/test_printer_probe.py -v`
Expected: every test fails on `helper(s) missing from the module: _kindOrDefault, _draftPrinterFields, _describeBridgeResult, _withSource`.

- [ ] **Step 3: Add the pure helpers**

In `Printer/code.py`, insert immediately after `_parseHostPort` (before `def validateEndpoint`):

```python
def _kindOrDefault(kind):
    """Normalize a ConnectionKind. An absent value reads as 'Networked', which is
       the attribute's own DefaultValue -- the same default Location.
       ufn_PrinterEndpoint and Location.Location_SaveAll apply, so the three
       layers agree. Self-contained so the tests can exec it."""
    k = ("%s" % (kind or "")).strip()
    return k or "Networked"


def _draftPrinterFields(rows):
    """Pull (Endpoint, ConnectionKind) out of already-decoded plain attribute
       dicts. Takes PLAIN dicts, not the view wrapper, so it is self-contained
       and testable; callers do the unwrap. Missing keys read as ''. Returns the
       RAW values (no default applied) so a caller can tell 'unset' from
       'Networked'."""
    endpoint = ""
    kind = ""
    for r in (rows or []):
        r = r or {}
        name = r.get("name")
        if name == "Endpoint":
            endpoint = r.get("value") or r.get("defaultValue") or ""
        elif name == "ConnectionKind":
            kind = r.get("value") or r.get("defaultValue") or ""
    return ("%s" % endpoint, "%s" % kind)


def _describeBridgeResult(host, port, probe):
    """Turn a LabelTransport.probeStatus result into the toast shape.
       Self-contained (no BlueRidge.*, no java) so the tests can exec it.

       The four failures are DELIBERATELY different sentences, because each sends
       a person to a different place. Collapsing them into one 'printer offline'
       is what cost most of 2026-09-29: 'Connect timed out' (firewall) and
       'Connection refused' (service down) are the distinction that found the
       real fault, and a bridge that ANSWERED proves the network, so a wrong
       queue name must not read as a connectivity problem."""
    target = "%s:%d" % (host, port)
    if not probe.get("reached"):
        return {"status": False, "level": "error", "title": "Bridge unreachable",
                "message": "Nothing answered at %s (%s). Check MesZebraBridge is running "
                           "on the terminal PC and that its inbound rule for TCP %d allows "
                           "the Gateway. 'Connection refused' means the service is down; "
                           "'Connect timed out' means packets are being dropped."
                           % (target, probe.get("error") or "unknown", port)}
    if not probe.get("isBridge"):
        return {"status": False, "level": "warning", "title": "Not the bridge",
                "message": "%s accepted the connection but did not answer ?STATUS. That is "
                           "a raw printer or another service on this port, not "
                           "MesZebraBridge -- a connect test passes in this state and a "
                           "label still never prints." % target}
    if probe.get("error"):
        return {"status": False, "level": "error", "title": "Bridge refused",
                "message": "The bridge at %s answered: %s. The network is fine and the "
                           "queue name is wrong -- fix it on that PC, not here."
                           % (target, probe.get("error"))}
    if not probe.get("ready"):
        return {"status": False, "level": "error", "title": "Queue not ready",
                "message": "Bridge %s at %s is bound to queue '%s', which reports NOT ready "
                           "(%s job(s) queued). Check the queue exists on that PC and is "
                           "online." % (probe.get("bridge") or "?", target,
                                        probe.get("queue") or "(none)", probe.get("jobs"))}
    return {"status": True, "level": "success", "title": "Printer ready",
            "message": "Bridge %s at %s, bound to queue '%s', ready, %s job(s) queued. "
                       "No label was consumed." % (probe.get("bridge") or "?", target,
                                                   probe.get("queue") or "(none)",
                                                   probe.get("jobs"))}


def _withSource(message, row):
    """Append where the endpoint came from. Self-contained so the tests can exec it.

       This line is not decoration. A UsbBridge printer stores NO endpoint, so
       without it the message names a host that appears nowhere on the printer
       row and nobody typed -- which is exactly the confusion the derivation is
       meant to remove."""
    r = row or {}
    src = r.get("EndpointSource") or ""
    if src == "derived-terminal-ip":
        return "%s  Endpoint derived from the parent terminal's IpAddress (%s) plus port 9100." % (
            message, r.get("TerminalIpAddress") or "?")
    if src == "unresolved":
        return "%s  No endpoint could be resolved: ConnectionKind '%s', stored endpoint '%s', terminal IpAddress '%s'." % (
            message, r.get("ConnectionKind") or "(unset)",
            r.get("StoredEndpoint") or "", r.get("TerminalIpAddress") or "")
    return "%s  Endpoint is stored on the printer." % message
```

- [ ] **Step 4: Run to verify the helper tests pass**

Run: `python -m pytest ignition/tests/test_printer_probe.py -v`
Expected: PASS, 13 passed.

- [ ] **Step 5: Wire the probe into `validateEndpoint`**

In `Printer/code.py`, replace the body of `validateEndpoint` from its `# Hardwired printers...` comment to the end of the function with:

```python
    # Hardwired printers cannot be reached from the config app -> never fail them.
    if kind == "Hardwired":
        return {"status": None, "level": "info", "title": "Cannot validate here",
                "message": "Hardwired printer '%s' is a print-queue name; reachability "
                           "cannot be checked from the config app." % (ep or "(unset)")}

    if not ep:
        # For a UsbBridge printer the endpoint should have been DERIVED by SQL, so
        # an empty one is a different fault from a Networked printer nobody has
        # addressed yet -- and it is fixed on the TERMINAL, not here.
        if kind == "UsbBridge":
            return {"status": False, "level": "error", "title": "No endpoint derived",
                    "message": "This USB-bridge printer has no endpoint. Its host comes from "
                               "the parent terminal's IpAddress attribute -- set that on the "
                               "TERMINAL as a bare address (no http://), then test again."}
        return {"status": None, "level": "warning", "title": "No endpoint",
                "message": "Set the Endpoint (IP:port) before validating."}

    host, port = _parseHostPort(ep)
    if not host:
        return {"status": False, "level": "error", "title": "Invalid endpoint",
                "message": "Could not parse a host from '%s'. Expected IP:port." % ep}

    # A UsbBridge endpoint is OUR service, so ask it what it is bound to. A connect
    # alone proves something answered; on 2026-09-29 the bridge was started with no
    # argument and bound the DEFAULT queue -- a connect test passes in that state and
    # a label still never prints (design sec 1 / 9).
    if kind == "UsbBridge":
        probe = BlueRidge.Lots.LabelTransport.probeStatus(host, port)
        return _describeBridgeResult(host, port, probe)

    # Networked: bare connect, sending ZERO bytes. That is PROTOCOL.md's
    # "(no bytes at all)" request and it is why this check has never wasted a
    # label. A real Zebra on raw 9100 would receive any bytes we wrote, so the
    # probe is deliberately NOT used here.
    sock = None
    try:
        sock = _jnet.Socket()
        sock.connect(_jnet.InetSocketAddress(host, port), _CONNECT_TIMEOUT_MS)
        return {"status": True, "level": "success", "title": "Valid endpoint",
                "message": "Reachable: %s:%d is accepting connections." % (host, port)}
    except (Exception, java.lang.Exception) as e:
        return {"status": False, "level": "error", "title": "Endpoint unreachable",
                "message": "Could not connect to %s:%d (%s)." % (host, port, type(e).__name__)}
    finally:
        try:
            if sock is not None:
                sock.close()
        except (Exception, java.lang.Exception):
            pass
```

Also update that function's docstring `connectionKind:` line from:

```python
       connectionKind: 'Networked' | 'Hardwired' | None/'' (treated as the
                       'Networked' default, matching the attribute DefaultValue).
```

to:

```python
       connectionKind: 'Networked' | 'Hardwired' | 'UsbBridge' | None/'' (treated
                       as the 'Networked' default, matching the attribute
                       DefaultValue).

       Networked  -- bare TCP connect, sends ZERO bytes (PROTOCOL.md's "(no bytes
                     at all)" request), so it can never consume a label.
       Hardwired  -- never reported invalid; a queue name is not reachable here.
       UsbBridge  -- connect and issue ?STATUS, so the result names the queue the
                     bridge is actually BOUND to. The endpoint arrives already
                     derived from the parent terminal's IpAddress by
                     Location.ufn_PrinterEndpoint; this function derives nothing.
```

- [ ] **Step 6: Refactor `validateFromAttributes` onto the shared draft reader, and add the two entry points**

In `Printer/code.py`, replace the body of `validateFromAttributes` after its docstring:

```python
    rows = system.util.jsonDecode(
        BlueRidge.Common.Util.convertWrapperObjectToJson(attributes)) or []
    endpoint = ""
    kind = ""
    for r in rows:
        r = r or {}
        name = r.get("name")
        if name == "Endpoint":
            endpoint = r.get("value") or r.get("defaultValue") or ""
        elif name == "ConnectionKind":
            kind = r.get("value") or r.get("defaultValue") or ""
    return validateEndpoint(endpoint, kind)
```

with:

```python
    rows = system.util.jsonDecode(
        BlueRidge.Common.Util.convertWrapperObjectToJson(attributes)) or []
    endpoint, kind = _draftPrinterFields(rows)
    return validateEndpoint(endpoint, kind)
```

Then append to the end of the module:

```python
def testPrinter(printerLocationId):
    """Config Tool 'Test printer' (design sec 9 step 1). Reads the SAVED printer
       row and probes it.

       Location.Printer_GetById already resolves the endpoint -- deriving it from
       the parent terminal's IpAddress for ConnectionKind = UsbBridge -- so this
       function derives NOTHING and holds no knowledge of what UsbBridge means.
       That is the point: one resolver, in SQL, and every caller reads the same
       answer.

       Proves route, firewall, service AND queue binding in one call with no
       label consumed. Without it the only test is manufacturing a real
       container, which on 2026-09-29 took ten component LOTs, two purchased-part
       LOTs and a temporarily shrunk container configuration -- per printer.

       Returns {status, level, title, message}, ready for
       Common.Notify.toast(title, message, level)."""
    row = getById(printerLocationId)
    if not row:
        return {"status": False, "level": "error", "title": "Printer not found",
                "message": "No active Printer location with that id."}
    res = validateEndpoint(row.get("Endpoint"), row.get("ConnectionKind"))
    return {"status":  res["status"],
            "level":   res["level"],
            "title":   res["title"],
            "message": _withSource(res["message"], row)}


def testFromSelection(printerLocationId, attributes):
    """Plant Hierarchy button entry point: the selected Location's id plus the
       open editDraft attribute rows.

       The test reads the SAVED row, because that is what the Gateway will dial.
       So an unsaved edit to Endpoint or ConnectionKind would test something the
       operator is not looking at -- which is worse than refusing, because it
       reads as a pass. Say so plainly instead."""
    pid = BlueRidge.Common.Util.extractQualifiedValues(printerLocationId)
    if pid is None:
        return {"status": None, "level": "info", "title": "Save first",
                "message": "Save this printer before testing -- the test reads the saved "
                           "configuration."}
    row = getById(pid)
    if not row:
        return {"status": False, "level": "error", "title": "Printer not found",
                "message": "No active Printer location with id %s." % pid}

    rows = system.util.jsonDecode(
        BlueRidge.Common.Util.convertWrapperObjectToJson(attributes)) or []
    draftEndpoint, draftKind = _draftPrinterFields(rows)
    savedEndpoint = "%s" % (row.get("StoredEndpoint") or "")
    savedKind     = "%s" % (row.get("ConnectionKind") or "")
    if (draftEndpoint.strip() != savedEndpoint.strip()
            or _kindOrDefault(draftKind) != _kindOrDefault(savedKind)):
        return {"status": None, "level": "info", "title": "Unsaved changes",
                "message": "Save your changes first. A test reads the saved configuration, "
                           "which is currently %s / %s."
                           % (_kindOrDefault(savedKind),
                              savedEndpoint or "no stored endpoint")}
    return testPrinter(pid)
```

- [ ] **Step 7: Update the module docstring**

In `Printer/code.py`, replace the `Design:` block and the Change Log with:

```python
   Design:
     - Hardwired printers (Endpoint is an OS/print-queue NAME, not an
       IP:port) are NOT reachable from the config app -> return a neutral
       "cannot validate here" result. A hardwired printer is NEVER reported
       invalid.
     - Networked printers are probed with a short TCP connect that sends ZERO
       bytes (PROTOCOL.md's "(no bytes at all)" request), so the check can never
       consume a label on a real Zebra. A successful connect means the print
       server is accepting connections.
     - UsbBridge printers get the full ?STATUS probe, so the result names the
       Windows queue the bridge is actually BOUND to. A connect alone cannot see
       that, and a wrong queue binding is a real failure mode: on 2026-09-29 the
       bridge was started with no argument, bound the default queue, passed a
       connect test, and no label ever printed.

   This module derives NOTHING. A UsbBridge printer's endpoint is composed by
   Location.ufn_PrinterEndpoint from the parent terminal's IpAddress and arrives
   already resolved in Printer_GetById's Endpoint column. Keeping the rule in one
   SQL function is why ShippingDispatcher, LotLabel and Terminal.applyToSession
   needed no change at all.

   This is an infrastructure probe (socket IO), not domain logic.

   Change Log:
       2026-08-05 - Initial version (FAT #14 printer endpoint validation).
       2026-09-30 - UsbBridge branch: ?STATUS probe via
                    BlueRidge.Lots.LabelTransport.probeStatus, plus testPrinter /
                    testFromSelection for the Config Tool's Test printer action
                    (design 2026-09-29 sec 8.1 / 9)."""
```

- [ ] **Step 8: Run both Python suites and confirm the file parses**

Run: `python -m pytest ignition/tests/ -v`
Expected: PASS, 0 failures. The new helpers are still extractable (`_kindOrDefault`, `_draftPrinterFields`, `_describeBridgeResult`, `_withSource` are all module-level `def`s with no `BlueRidge.*` or `java.*` reference in their bodies -- if a test now fails on a `NameError`, a dependency leaked into one of them and it must come back out).

Run: `python -c "import ast, io; ast.parse(io.open('ignition/projects/Core/ignition/script-python/BlueRidge/Location/Printer/code.py', encoding='utf-8').read()); print('parses')"`
Expected: `parses`

- [ ] **Step 9: Commit**

```bash
git add ignition/projects/Core/ignition/script-python/BlueRidge/Location/Printer/code.py ignition/tests/test_printer_probe.py
git commit -m "feat(ignition): Test printer reports the queue the bridge is bound to"
```

---

### Task 8: The Plant Hierarchy button calls it

One existing view, one component, two strings. `BlueRidge/Views/Location/PlantHierarchy/view.json` (MPP_Config) already has a `ValidateEndpointButton` displayed when `{view.custom.selected.definitionId} = 16`. Its script gets the printer id so it can test a derived endpoint, and its label changes.

**The plant-floor `PrinterCard` view is deliberately NOT edited.** It calls `validateEndpoint(self.view.params.endpoint, self.view.params.connectionKind)`, and Task 4 makes `params.endpoint` arrive already resolved, so its button starts probing UsbBridge cards with zero changes.

**Files:**
- Modify: `ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Location/PlantHierarchy/view.json`

**Interfaces:**
- Consumes: `BlueRidge.Location.Printer.testFromSelection(printerLocationId, attributes)` from Task 7
- Produces: nothing downstream

- [ ] **Step 1: Close Designer for MPP_Config before editing anything**

Designer keeps an in-memory model of every open view and its "Files vs Gateway" conflict dialog can overwrite disk with that cached state. Confirm the Ignition Designer is **closed** (or at least that this project is not open in it) before touching the file. If it is open with unsaved changes, save or discard them in Designer first, then close it. Do not proceed with Designer holding this view.

- [ ] **Step 2: Record the exact bytes of the three anchors before editing**

Designer's GSON serialization writes `=`, `'`, `<` and `>` as six-character unicode escapes (`=`, `'`, `<`, `>`). This file is **mixed**: it holds about twenty escaped `=` and four literal ` = `, because parts were hand-authored after the last Designer save. So a literal-string match on any text containing those characters can silently fail. Every anchor below is chosen to be free of them.

Run: `grep -n "validateFromAttributes\|ValidateEndpointButton\|Validate endpoint" "ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Location/PlantHierarchy/view.json"`

Expected: exactly three lines, around 605 / 613 / 629 -- the script, the component name, and the button text. If any of them appears more than once, stop: the edits below assume each anchor is unique.

- [ ] **Step 3: Swap the script's function call, anchoring only on escape-free text**

Replace **only** this substring -- it contains no `=`, `'`, `<` or `>`, so it matches whatever form the surrounding `res = ` is in:

```
validateFromAttributes(self.view.custom.state.editDraft.attributes)
```

with:

```
testFromSelection((self.view.custom.selected or {}).get(\"id\"), self.view.custom.state.editDraft.attributes)
```

Three things about the replacement text:

- `\"id\"` is written with **backslash-escaped double quotes** because it sits inside a JSON string. `"` is a standard JSON escape that GSON also emits as `\"`, so it is stable across a Designer round trip -- unlike a single quote, which is why `'id'` is not used.
- `(self.view.custom.selected or {}).get("id")` is a single expression with **no `=` in it**, deliberately, so the whole edit stays escape-free and the script remains a one-liner. The `or {}` handles the selected-is-None case even though the button's `position.display` binding already hides it then.
- The key is `"id"`, not `"locationId"`. That is the key the sibling `DeprecateButton` script on this same view reads (`sel.get("id")`), so it is the established shape of `view.custom.selected`.

- [ ] **Step 4: Relabel the button**

Replace:

```
"text": "Validate endpoint"
```

with:

```
"text": "Test printer"
```

Escape-free and unique. Do **not** rename the component's `meta.name` -- `ValidateEndpointButton` is referenced nowhere else, and leaving it alone keeps the diff to two strings.

- [ ] **Step 5: Verify the file is still valid JSON and the edits landed**

```bash
python -c "import io, json; d=json.load(io.open('ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Location/PlantHierarchy/view.json', encoding='utf-8')); print('valid json,', len(d['root']['children']), 'root children')"
grep -c "testFromSelection" "ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Location/PlantHierarchy/view.json"
grep -c "validateFromAttributes" "ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Location/PlantHierarchy/view.json"
```

Expected: `valid json, ...`, then `1`, then `0`.

Also check the diff is exactly two lines: `git diff --stat` should show this one file with 2 insertions and 2 deletions. **A larger diff means Designer rewrote the file** (it re-serializes the whole document and would convert every literal ` = ` to `=`) -- in that case reset the file and start again with Designer closed.

Per `feedback_designer_pickles_live_data`: also confirm no runtime dataset got baked in, which a large diff would reveal.

- [ ] **Step 6: Push it to the gateway**

Run: `.\scan.ps1`
Expected: a success response from `POST /data/api/v1/scan/projects`. A file edit alone does not reach the running gateway; the scan is what makes it live.

If `scan.ps1` reports a manifest problem, per `feedback_ignition_manifest_designer_npe`: a `resource.json` naming a missing file gives Designer a "project is null" NPE and needs a restart, not another scan. Nothing in this task adds or removes a file, so that should not arise.

- [ ] **Step 7: Click it, in the Config Tool**

Open MPP_Config, Plant Hierarchy, select a Printer location, click **Test printer**.

Expected, for one of the existing `Networked` printers (`172.17.20.228:9100` or `.229`): either `Valid endpoint / Reachable: ...` or `Endpoint unreachable / Could not connect ...` depending on whether that printer is powered -- **plus** the new trailing sentence `Endpoint is stored on the printer.` The verdict itself must be unchanged from before this plan; only the extra sentence is new.

Expected, with an edit pending in the attribute panel: `Unsaved changes -- Save your changes first.`

Expected, on a Printer location with no saved row yet (a draft `+Add` node): `Save first`.

- [ ] **Step 8: Commit**

```bash
git add ignition/projects/MPP_Config/com.inductiveautomation.perspective/views/BlueRidge/Views/Location/PlantHierarchy/view.json
git commit -m "feat(ignition): the printer button tests the endpoint the Gateway will actually dial"
```

---

### Task 9: Commission one real printer end to end

Everything above is proven without hardware. Only a terminal PC with a bridge and a driver proves the whole path, and this is the sequence the other 53 follow.

**HARDWARE-GATED.** Needs a terminal PC running `MesZebraBridge` (or `zebraPrinter/usb_tcp_bridge.py` as the reference implementation) with a Zebra driver installed. Do not start anything on port 9100 on the Gateway host.

**Files:**
- Modify: `docs/superpowers/specs/2026-09-29-zebra-bridge-service-and-print-traceability-design.md` (record the observed result in section 9)

**Interfaces:**
- Consumes: everything from Tasks 1-8
- Produces: an observed commissioning sequence, and a recorded answer to the one thing this plan cannot know -- whether a `?STATUS` probe carrying this protocol survives the real network between the Gateway host and a terminal (`PROTOCOL.md` "Not yet verified" lists exactly this).

- [ ] **Step 1: Confirm the terminal's `IpAddress` attribute is a bare address**

In the Config Tool, Plant Hierarchy, select the chosen Terminal and read its `IpAddress`. It must be a bare dotted quad -- no `http://`, no port, no trailing slash. This is the single value the printer's endpoint derives from, so getting it wrong is the one remaining way to mis-address a printer.

- [ ] **Step 2: Create the Printer row -- one dropdown, no endpoint**

Under that Terminal, add a child Location of type **Printer**, give it a Code and Name, set `ConnectionKind` to **USB bridge**, and **leave `Endpoint` blank**. Save.

Expected: the save succeeds (Task 3 permits a blank endpoint for this kind; before migration 0101 it was refused with `Required attribute missing a value: Endpoint.`).

- [ ] **Step 3: Read back what SQL derived, read-only**

```bash
sqlcmd -S localhost -d MPP_MES_Dev -Q "SET NOCOUNT ON; DECLARE @Id BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'<printer-code>'); CREATE TABLE #P (LocationId BIGINT, Code NVARCHAR(50), Name NVARCHAR(200), Endpoint NVARCHAR(255), Model NVARCHAR(255), ConnectionKind NVARCHAR(255), StoredEndpoint NVARCHAR(255), TerminalIpAddress NVARCHAR(255), EndpointSource NVARCHAR(30)); INSERT INTO #P EXEC Location.Printer_GetById @PrinterLocationId = @Id; SELECT Code, Endpoint, StoredEndpoint, TerminalIpAddress, EndpointSource FROM #P; DROP TABLE #P;" -b -I -C -W -s "|"
```

Expected: `Endpoint` is `<terminal-ip>:9100`, `StoredEndpoint` is NULL, `EndpointSource` is `derived-terminal-ip`.

- [ ] **Step 4: Test it from the Config Tool**

Click **Test printer** on that Printer location.

Expected: `Printer ready -- Bridge 1.0.0 at <terminal-ip>:9100, bound to queue '<queue>', ready, 0 job(s) queued. No label was consumed.  Endpoint derived from the parent terminal's IpAddress (<terminal-ip>) plus port 9100.`

**And no label physically emerges.** Watch the printer. If one does, the bridge is treating `?STATUS` as ZPL and `PROTOCOL.md`'s command dispatch is not being honoured -- stop and report it rather than proceeding.

If instead you see:
- `Bridge unreachable / Connection refused` -- the service is not running on that PC.
- `Bridge unreachable / Connect timed out` -- packets are being dropped; the inbound rule for TCP 9100 on the terminal PC does not allow the Gateway.
- `Not the bridge` -- something else owns 9100 on that PC, or it is a raw printer.
- `Bridge refused / queue not found` -- the bridge is bound to a queue name that does not exist there. `Zebra GX420d (RAW)` vs `ZDesigner GX420d` is the observed trap.
- `Queue not ready` -- right queue, printer offline or paused.

Each of those is a different machine to walk to, which is the point of the action.

- [ ] **Step 5: Start a new session and print one real label**

`session.custom.printer` resolves once at session **startup**, so a page refresh is not enough after a configuration change. Start a new Perspective session on that terminal, then print one LTT or shipping label from the screen that terminal defaults to.

Expected: a label emerges, and the `Audit.InterfaceLog` tail reads a resolve row followed by a spooled row:

```bash
sqlcmd -S localhost -d MPP_MES_Dev -Q "SET NOCOUNT ON; SELECT TOP 6 Id, LoggedAt, ErrorCondition, Descr=LEFT(Description,70), Resp=LEFT(ResponsePayload,70) FROM Audit.InterfaceLog ORDER BY Id DESC;" -b -I -C -W -s "|"
```

Expected: one row whose Description contains `endpoint resolved via` and the derived `<terminal-ip>:9100`, then one whose `ResponsePayload` reads `Spooled queue='<queue>' job=<n> bytes=<n>` with `ErrorCondition` NULL. Per spec section 6.4 we log **spooled**, never **printed** -- whether media fed is the one step a human still confirms.

- [ ] **Step 6: Record the observed result in the spec**

In `docs/superpowers/specs/2026-09-29-zebra-bridge-service-and-print-traceability-design.md`, append to section 9 (after the numbered commissioning steps):

```markdown
**Observed 2026-09-30**, terminal `<terminal-code>` (`<terminal-ip>`), printer
`<printer-code>`, queue `<queue>`:

- The Printer row saved with `ConnectionKind = UsbBridge` and a blank `Endpoint`;
  `Location.Printer_GetById` returned `Endpoint = <terminal-ip>:9100`,
  `EndpointSource = derived-terminal-ip`. No address was typed anywhere.
- **Test printer** returned `queue='<queue>' ready=true jobs=0` and **no label was
  consumed** -- the `?STATUS` exchange over the real network between the Gateway
  host and a terminal, which `PROTOCOL.md` listed as not yet verified.
- One real label then spooled as `Audit.InterfaceLog` <id>, `ResponsePayload`
  `Spooled queue='<queue>' job=<n> bytes=<n>`, and physically emerged.

Per-terminal cost from here is the driver install and one dropdown.
```

Replace every `<...>` with what you actually observed. If step 4 or step 5 did not behave as expected, record what happened instead -- a spec that says something was verified when it was not is worse than one that says nothing.

- [ ] **Step 7: Commit**

```bash
git add docs/superpowers/specs/2026-09-29-zebra-bridge-service-and-print-traceability-design.md
git commit -m "docs(spec): record the first USB-bridge printer commissioned end to end"
```
