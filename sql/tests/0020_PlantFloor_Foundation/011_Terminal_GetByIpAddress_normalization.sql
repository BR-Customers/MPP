-- =============================================
-- File:         0020_PlantFloor_Foundation/011_Terminal_GetByIpAddress_normalization.sql
-- Author:       Blue Ridge Automation
-- Created:      2026-08-05
-- Description:  IP-representation normalization tests for
--               Location.Terminal_GetByIpAddress (FAT #16).
--
--               A single host has many equivalent string representations. The
--               gateway (Perspective session.props.address) reports loopback as
--               the bracketed IPv6 form '[0:0:0:0:0:0:0:1]', and a real IPv4
--               client can arrive IPv4-mapped ('::ffff:a.b.c.d') and/or bracketed
--               -- while an admin configures the terminal's IpAddress attribute in
--               the human IPv4 form ('127.0.0.1', '192.168.1.50'). A raw exact
--               string compare therefore silently falls to the Facility-wide
--               FALLBACK terminal (the observed FAT #16 defect). The proc SHALL
--               normalize BOTH the stored value and the connecting address so
--               equivalent representations of the same host resolve identically.
--
--               Fixtures created here (both parented at Cell 'DC1-M01'):
--                 * TEST-TERM-LOOP  IpAddress '127.0.0.1'     (human loopback)
--                 * TEST-TERM-NORMV4 IpAddress '192.168.1.50' (human IPv4 LAN)
-- =============================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
EXEC test.BeginTestFile @FileName = N'0020_PlantFloor_Foundation/011_Terminal_GetByIpAddress_normalization.sql';
GO

-- ---- teardown any prior fixtures (FK-safe: attributes -> locations) ----
DELETE la
FROM Location.LocationAttribute la
INNER JOIN Location.Location l ON l.Id = la.LocationId
WHERE l.Code IN (N'TEST-TERM-LOOP', N'TEST-TERM-NORMV4');
DELETE FROM Location.Location WHERE Code IN (N'TEST-TERM-LOOP', N'TEST-TERM-NORMV4');
GO

-- ---- create the two Terminal fixtures ----
DECLARE @CellParentId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC1-M01');  -- Cell tier (die-cast machine)

INSERT INTO Location.Location (LocationTypeDefinitionId, ParentLocationId, Name, Code, Description, SortOrder)
VALUES
    (7, @CellParentId, N'Test Terminal Loopback', N'TEST-TERM-LOOP',  N'Loopback-configured test terminal', 910),
    (7, @CellParentId, N'Test Terminal LAN v4',   N'TEST-TERM-NORMV4', N'IPv4-LAN test terminal',           911);
GO

-- ---- attach IpAddress attribute values in the HUMAN (admin-typed) form ----
DECLARE @IpDefId BIGINT = (
    SELECT Id FROM Location.LocationAttributeDefinition
    WHERE LocationTypeDefinitionId = 7 AND AttributeName = N'IpAddress' AND DeprecatedAt IS NULL);

DECLARE @LoopTermId BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-TERM-LOOP');
DECLARE @V4TermId   BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TEST-TERM-NORMV4');

INSERT INTO Location.LocationAttribute (LocationId, LocationAttributeDefinitionId, AttributeValue)
VALUES
    (@LoopTermId, @IpDefId, N'127.0.0.1'),
    (@V4TermId,   @IpDefId, N'192.168.1.50');
GO

-- ---- reusable assert helper: resolve @Ip and assert the resolved TerminalCode ----
-- (Inlined per-test below; the harness has no parameterized fixture helper.)

-- =============================================
-- Test 1: gateway-observed bracketed IPv6 loopback resolves the '127.0.0.1'
--         terminal (the exact FAT #16 reproduction).
-- =============================================
DECLARE @Code NVARCHAR(50);
CREATE TABLE #R1 (TerminalLocationId BIGINT, TerminalCode NVARCHAR(50), TerminalName NVARCHAR(200),
                  ZoneLocationId BIGINT, ZoneCode NVARCHAR(50), ZoneName NVARCHAR(200),
                  DefaultScreen NVARCHAR(255), IsFallback BIT);
INSERT INTO #R1 EXEC Location.Terminal_GetByIpAddress @IpAddress = N'[0:0:0:0:0:0:0:1]';
SELECT @Code = TerminalCode FROM #R1;
DROP TABLE #R1;
EXEC test.Assert_IsEqual
    @TestName = N'[IpNorm] Bracketed IPv6 loopback resolves the 127.0.0.1 terminal',
    @Expected = N'TEST-TERM-LOOP', @Actual = @Code;
GO

-- =============================================
-- Test 2: compact IPv6 loopback '::1' resolves the '127.0.0.1' terminal.
-- =============================================
DECLARE @Code NVARCHAR(50);
CREATE TABLE #R2 (TerminalLocationId BIGINT, TerminalCode NVARCHAR(50), TerminalName NVARCHAR(200),
                  ZoneLocationId BIGINT, ZoneCode NVARCHAR(50), ZoneName NVARCHAR(200),
                  DefaultScreen NVARCHAR(255), IsFallback BIT);
INSERT INTO #R2 EXEC Location.Terminal_GetByIpAddress @IpAddress = N'::1';
SELECT @Code = TerminalCode FROM #R2;
DROP TABLE #R2;
EXEC test.Assert_IsEqual
    @TestName = N'[IpNorm] Compact IPv6 loopback ::1 resolves the 127.0.0.1 terminal',
    @Expected = N'TEST-TERM-LOOP', @Actual = @Code;
GO

-- =============================================
-- Test 3: expanded IPv6 loopback (unbracketed) resolves the '127.0.0.1' terminal.
-- =============================================
DECLARE @Code NVARCHAR(50);
CREATE TABLE #R3 (TerminalLocationId BIGINT, TerminalCode NVARCHAR(50), TerminalName NVARCHAR(200),
                  ZoneLocationId BIGINT, ZoneCode NVARCHAR(50), ZoneName NVARCHAR(200),
                  DefaultScreen NVARCHAR(255), IsFallback BIT);
INSERT INTO #R3 EXEC Location.Terminal_GetByIpAddress @IpAddress = N'0:0:0:0:0:0:0:1';
SELECT @Code = TerminalCode FROM #R3;
DROP TABLE #R3;
EXEC test.Assert_IsEqual
    @TestName = N'[IpNorm] Expanded IPv6 loopback resolves the 127.0.0.1 terminal',
    @Expected = N'TEST-TERM-LOOP', @Actual = @Code;
GO

-- =============================================
-- Test 4: IPv4-mapped IPv6 resolves the plain-IPv4 terminal.
-- =============================================
DECLARE @Code NVARCHAR(50);
CREATE TABLE #R4 (TerminalLocationId BIGINT, TerminalCode NVARCHAR(50), TerminalName NVARCHAR(200),
                  ZoneLocationId BIGINT, ZoneCode NVARCHAR(50), ZoneName NVARCHAR(200),
                  DefaultScreen NVARCHAR(255), IsFallback BIT);
INSERT INTO #R4 EXEC Location.Terminal_GetByIpAddress @IpAddress = N'::ffff:192.168.1.50';
SELECT @Code = TerminalCode FROM #R4;
DROP TABLE #R4;
EXEC test.Assert_IsEqual
    @TestName = N'[IpNorm] IPv4-mapped IPv6 resolves the 192.168.1.50 terminal',
    @Expected = N'TEST-TERM-NORMV4', @Actual = @Code;
GO

-- =============================================
-- Test 5: bracketed IPv4-mapped IPv6 resolves the plain-IPv4 terminal.
-- =============================================
DECLARE @Code NVARCHAR(50);
CREATE TABLE #R5 (TerminalLocationId BIGINT, TerminalCode NVARCHAR(50), TerminalName NVARCHAR(200),
                  ZoneLocationId BIGINT, ZoneCode NVARCHAR(50), ZoneName NVARCHAR(200),
                  DefaultScreen NVARCHAR(255), IsFallback BIT);
INSERT INTO #R5 EXEC Location.Terminal_GetByIpAddress @IpAddress = N'[::ffff:192.168.1.50]';
SELECT @Code = TerminalCode FROM #R5;
DROP TABLE #R5;
EXEC test.Assert_IsEqual
    @TestName = N'[IpNorm] Bracketed IPv4-mapped IPv6 resolves the 192.168.1.50 terminal',
    @Expected = N'TEST-TERM-NORMV4', @Actual = @Code;
GO

-- =============================================
-- Test 6 (regression): plain IPv4 still resolves its terminal exactly.
-- =============================================
DECLARE @Code NVARCHAR(50);
CREATE TABLE #R6 (TerminalLocationId BIGINT, TerminalCode NVARCHAR(50), TerminalName NVARCHAR(200),
                  ZoneLocationId BIGINT, ZoneCode NVARCHAR(50), ZoneName NVARCHAR(200),
                  DefaultScreen NVARCHAR(255), IsFallback BIT);
INSERT INTO #R6 EXEC Location.Terminal_GetByIpAddress @IpAddress = N'192.168.1.50';
SELECT @Code = TerminalCode FROM #R6;
DROP TABLE #R6;
EXEC test.Assert_IsEqual
    @TestName = N'[IpNorm] Plain IPv4 still resolves exactly (regression)',
    @Expected = N'TEST-TERM-NORMV4', @Actual = @Code;
GO

-- =============================================
-- Test 7 (regression): exact human loopback '127.0.0.1' still resolves.
-- =============================================
DECLARE @Code NVARCHAR(50);
CREATE TABLE #R7 (TerminalLocationId BIGINT, TerminalCode NVARCHAR(50), TerminalName NVARCHAR(200),
                  ZoneLocationId BIGINT, ZoneCode NVARCHAR(50), ZoneName NVARCHAR(200),
                  DefaultScreen NVARCHAR(255), IsFallback BIT);
INSERT INTO #R7 EXEC Location.Terminal_GetByIpAddress @IpAddress = N'127.0.0.1';
SELECT @Code = TerminalCode FROM #R7;
DROP TABLE #R7;
EXEC test.Assert_IsEqual
    @TestName = N'[IpNorm] Exact 127.0.0.1 still resolves the loopback terminal (regression)',
    @Expected = N'TEST-TERM-LOOP', @Actual = @Code;
GO

-- =============================================
-- Test 8 (regression): a genuinely unrelated IP does NOT over-match; -> fallback.
-- =============================================
DECLARE @Code NVARCHAR(50), @Fb BIT, @FbStr NVARCHAR(1);
CREATE TABLE #R8 (TerminalLocationId BIGINT, TerminalCode NVARCHAR(50), TerminalName NVARCHAR(200),
                  ZoneLocationId BIGINT, ZoneCode NVARCHAR(50), ZoneName NVARCHAR(200),
                  DefaultScreen NVARCHAR(255), IsFallback BIT);
INSERT INTO #R8 EXEC Location.Terminal_GetByIpAddress @IpAddress = N'203.0.113.99';
SELECT @Code = TerminalCode, @Fb = IsFallback FROM #R8;
DROP TABLE #R8;
SET @FbStr = CAST(@Fb AS NVARCHAR(1));
EXEC test.Assert_IsEqual
    @TestName = N'[IpNorm] Unrelated IP does not over-match -> fallback (regression)',
    @Expected = N'FALLBACK-TERMINAL', @Actual = @Code;
EXEC test.Assert_IsEqual
    @TestName = N'[IpNorm] Unrelated IP IsFallback=1 (regression)',
    @Expected = N'1', @Actual = @FbStr;
GO

-- =============================================
-- Test 9..14: direct unit tests of Location.ufn_NormalizeIpAddress.
-- (Runs only once the function exists; documents the canonical-form contract.)
-- Function results are computed into @variables first: EXEC parameters must be
-- literals or @variables -- an inline function call is a syntax error.
-- =============================================
DECLARE @n1 NVARCHAR(64) = Location.ufn_NormalizeIpAddress(N'[0:0:0:0:0:0:0:1]');
DECLARE @n2 NVARCHAR(64) = Location.ufn_NormalizeIpAddress(N'::1');
DECLARE @n3 NVARCHAR(64) = Location.ufn_NormalizeIpAddress(N'::ffff:192.168.1.50');
DECLARE @n4 NVARCHAR(64) = Location.ufn_NormalizeIpAddress(N'  192.168.1.50  ');
DECLARE @n5 NVARCHAR(64) = Location.ufn_NormalizeIpAddress(N'192.168.1.50');
DECLARE @n6 NVARCHAR(64) = Location.ufn_NormalizeIpAddress(NULL);
EXEC test.Assert_IsEqual
    @TestName = N'[IpNorm][ufn] Bracketed IPv6 loopback -> 127.0.0.1',
    @Expected = N'127.0.0.1', @Actual = @n1;
EXEC test.Assert_IsEqual
    @TestName = N'[IpNorm][ufn] ::1 -> 127.0.0.1',
    @Expected = N'127.0.0.1', @Actual = @n2;
EXEC test.Assert_IsEqual
    @TestName = N'[IpNorm][ufn] IPv4-mapped -> bare IPv4',
    @Expected = N'192.168.1.50', @Actual = @n3;
EXEC test.Assert_IsEqual
    @TestName = N'[IpNorm][ufn] Surrounding whitespace trimmed',
    @Expected = N'192.168.1.50', @Actual = @n4;
EXEC test.Assert_IsEqual
    @TestName = N'[IpNorm][ufn] Plain IPv4 passes through unchanged',
    @Expected = N'192.168.1.50', @Actual = @n5;
EXEC test.Assert_IsNull
    @TestName = N'[IpNorm][ufn] NULL in -> NULL out',
    @Value = @n6;
GO

-- ---- cleanup (FK-safe: attributes -> locations) ----
DELETE la
FROM Location.LocationAttribute la
INNER JOIN Location.Location l ON l.Id = la.LocationId
WHERE l.Code IN (N'TEST-TERM-LOOP', N'TEST-TERM-NORMV4');
DELETE FROM Location.Location WHERE Code IN (N'TEST-TERM-LOOP', N'TEST-TERM-NORMV4');
GO

EXEC test.EndTestFile;
GO
