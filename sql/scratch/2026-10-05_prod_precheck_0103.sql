/* ============================================================
   PRE-CHECK for migration 0103 -- run against PROD before the deploy.
   READ-ONLY. Takes a second.

   WHY THIS EXISTS. 0103 patches the Container label by exact string match on
   three fields, and THROWs if any of them is not found verbatim -- deliberately,
   because a REPLACE that silently matched nothing would ship a label that looks
   fixed and is not. The failure is safe (the whole release rolls back) but it
   costs you the window. This tells you beforehand.

   ALL THREE must come back FOUND. Anything else = prod's template has diverged
   from the seeded text; send me the ZplBody and do not run the deploy.
   ============================================================ */
SET NOCOUNT ON;

DECLARE @Id BIGINT = (SELECT TOP 1 t.Id FROM Lots.LabelTemplate t
                      JOIN Lots.LabelTypeCode c ON c.Id = t.LabelTypeCodeId
                      WHERE c.Code = N'Container' AND t.DeprecatedAt IS NULL
                      ORDER BY t.Id);
DECLARE @Body NVARCHAR(MAX) = (SELECT ZplBody FROM Lots.LabelTemplate WHERE Id = @Id);

SELECT TemplateId = @Id, BodyLength = LEN(@Body);   -- expect Id 5, length 1317

SELECT Field = '1. human-readable serial',
       Expected = '^A0R,72,72^FO140,200^FD{Serial}^FS',
       Result = CASE WHEN CHARINDEX(N'^A0R,72,72^FO140,200^FD{Serial}^FS', @Body) > 0
                     THEN 'FOUND' ELSE '*** NOT FOUND ***' END
UNION ALL
SELECT '2. Code 39 serial',
       '^A0R^FO50,60^BY3^B3,,95,N,^FD{Serial}^FS',
       CASE WHEN CHARINDEX(N'^A0R^FO50,60^BY3^B3,,95,N,^FD{Serial}^FS', @Body) > 0
            THEN 'FOUND' ELSE '*** NOT FOUND ***' END
UNION ALL
SELECT '3. PART NO. EXT Code 39 (to be removed)',
       '^A0R^FO410,70^BY3^B3,,80,N,^FD{PartNumberExt}^FS',
       CASE WHEN CHARINDEX(N'^A0R^FO410,70^BY3^B3,,80,N,^FD{PartNumberExt}^FS', @Body) > 0
            THEN 'FOUND' ELSE '*** NOT FOUND ***' END
UNION ALL
SELECT '4. already patched?',
       '{SerialText} present',
       CASE WHEN CHARINDEX(N'{SerialText}', @Body) > 0
            THEN 'ALREADY PATCHED -- 0103 will no-op' ELSE 'not yet (expected)' END;

/* Optional: the whole body, if any line above says NOT FOUND. */
-- SELECT ZplBody FROM Lots.LabelTemplate WHERE Id = @Id;
