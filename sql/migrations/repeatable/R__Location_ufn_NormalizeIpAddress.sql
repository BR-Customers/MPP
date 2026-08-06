-- ============================================================
-- Repeatable:  R__Location_ufn_NormalizeIpAddress.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-08-05
-- Version:     1.0
-- Description: Canonicalizes an IP-address STRING so equivalent representations
--              of the same host compare equal (FAT #16). A single host reaches
--              the Gateway in many forms:
--                - Perspective session.props.address reports loopback as the
--                  bracketed expanded IPv6 form '[0:0:0:0:0:0:0:1]'.
--                - A dual-stack JVM can surface a genuine IPv4 client IPv4-mapped
--                  ('::ffff:192.168.1.5'), optionally bracketed.
--                - An admin types the human IPv4 form ('127.0.0.1',
--                  '192.168.1.5') into the terminal's IpAddress attribute.
--              A raw exact-string compare therefore fails and silently falls to
--              the Facility-wide FALLBACK terminal. Terminal_GetByIpAddress runs
--              BOTH the stored attribute value and the connecting address through
--              this function before comparing.
--
--              Transformations (in order):
--                1. Trim + lowercase.
--                2. Strip a single surrounding bracket pair:  [::1] -> ::1
--                3. Drop an IPv6 zone/scope index:  fe80::1%eth0 -> fe80::1
--                4. Collapse the three loopback synonyms + IPv4-mapped loopback
--                   to the canonical '127.0.0.1'.
--                5. Strip the IPv4-mapped-IPv6 prefix (compact '::ffff:' and the
--                   fully-expanded '0:0:0:0:0:0:ffff:') to the bare IPv4 dotted-quad.
--              NULL in -> NULL out. This is string canonicalization only -- it
--              does not validate that the input is a well-formed address; an
--              unrecognized form is returned trimmed/lowercased unchanged, so a
--              non-matching value still falls through to the fallback terminal.
-- ============================================================
CREATE OR ALTER FUNCTION Location.ufn_NormalizeIpAddress (@Ip NVARCHAR(64))
RETURNS NVARCHAR(64)
WITH SCHEMABINDING
AS
BEGIN
    IF @Ip IS NULL RETURN NULL;

    DECLARE @s NVARCHAR(64) = LOWER(LTRIM(RTRIM(@Ip)));
    IF @s = N'' RETURN @s;

    -- Strip a single surrounding bracket pair:  [::1] -> ::1
    IF LEN(@s) >= 2 AND LEFT(@s, 1) = N'[' AND RIGHT(@s, 1) = N']'
        SET @s = LTRIM(RTRIM(SUBSTRING(@s, 2, LEN(@s) - 2)));

    -- Drop an IPv6 zone/scope index:  fe80::1%eth0 -> fe80::1
    IF CHARINDEX(N'%', @s) > 0
        SET @s = LEFT(@s, CHARINDEX(N'%', @s) - 1);

    -- Collapse every loopback synonym (incl. IPv4-mapped loopback) to 127.0.0.1
    IF @s IN (N'::1',
              N'0:0:0:0:0:0:0:1',
              N'0000:0000:0000:0000:0000:0000:0000:0001',
              N'::ffff:127.0.0.1',
              N'0:0:0:0:0:0:ffff:127.0.0.1')
        SET @s = N'127.0.0.1';

    -- Strip the compact IPv4-mapped-IPv6 prefix:  ::ffff:192.168.1.5 -> 192.168.1.5
    IF @s LIKE N'::ffff:%.%.%.%'
        SET @s = SUBSTRING(@s, 8, LEN(@s));

    -- Strip the fully-expanded IPv4-mapped prefix:  0:0:0:0:0:0:ffff:a.b.c.d
    IF @s LIKE N'0:0:0:0:0:0:ffff:%.%.%.%'
        SET @s = SUBSTRING(@s, CHARINDEX(N'ffff:', @s) + 5, LEN(@s));

    RETURN @s;
END
GO
