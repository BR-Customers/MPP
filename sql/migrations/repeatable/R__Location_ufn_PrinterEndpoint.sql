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
--              endpoint host is by construction its parent Terminal's IpAddress.
--              There is no second address, so storing one would be two fields
--              that must agree by convention. This removes a class of defect
--              instead of mitigating it: 54 hand-entered addresses become zero,
--              the port can never be omitted, endpoint and terminal IP cannot
--              drift, and a re-addressed terminal stays correct with no second
--              edit. Spec sections 7, 8 and 8.1.
--
--              The Terminal IpAddress is set during commissioning, one terminal
--              at a time as a line is walked -- so it is present one step before
--              anything consumes it, which is what makes derivation correct here
--              rather than merely workable.
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
