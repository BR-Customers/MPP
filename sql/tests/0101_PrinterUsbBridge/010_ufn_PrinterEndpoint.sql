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
