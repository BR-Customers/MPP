-- =============================================
-- File: 0136_PackOut/030_crud.sql
-- Desc: Parts.PackOut_Save / _SetDefault / _Deprecate / _ListByItem and the
--       Item_Deprecate cascade. An edit to a pack-out's values retires the
--       active version and saves the next one (D5); a box keeps its version.
-- =============================================
SET NOCOUNT ON;
EXEC test.BeginTestFile @FileName = N'0136_PackOut/030_crud.sql';
GO

DELETE FROM Lots.Container WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'TST-PO-CRUD', N'TST-PO-CASC'));
DELETE FROM Parts.ContainerConfig WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'TST-PO-CRUD', N'TST-PO-CASC'));
DELETE FROM Parts.Item WHERE PartNumber IN (N'TST-PO-CRUD', N'TST-PO-CASC');
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.ItemType WHERE Code = N'FinishedGood');
DECLARE @Ea BIGINT = (SELECT TOP 1 Id FROM Parts.Uom ORDER BY Id);
INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedByUserId) VALUES (@Fg, N'TST-PO-CRUD', N'Pack-out CRUD', @Ea, 1);
INSERT INTO Parts.Item (ItemTypeId, PartNumber, Description, UomId, CreatedByUserId) VALUES (@Fg, N'TST-PO-CASC', N'Pack-out cascade', @Ea, 1);
CREATE TABLE #R (Status BIT, Message NVARCHAR(500), NewId BIGINT);
CREATE TABLE #S (Status BIT, Message NVARCHAR(500));
GO

-- ---- Create ----
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-PO-CRUD');
DECLARE @S NVARCHAR(500);

DELETE FROM #R;
INSERT INTO #R EXEC Parts.PackOut_Save @ItemId = @Item, @ClosureMethod = N'ByWeight', @Name = N'  Cardboard ',
    @TraysPerContainer = 1, @PartsPerTray = 6, @TargetWeight = 15.0, @ToleranceWeight = 1.35, @AppUserId = 1;
SET @S = (SELECT CONCAT(r.Status, N'|', p.Name, N'|', p.IsDefault, N'|', cc.VersionNumber, N'|', cc.PartsPerTray)
          FROM #R r JOIN Parts.PackOut p ON p.Id = r.NewId JOIN Parts.ContainerConfig cc ON cc.PackOutId = p.Id AND cc.DeprecatedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Save] first pack-out created, trimmed, default, v1', @Expected = N'1|Cardboard|1|1|6', @Actual = @S;

DELETE FROM #R;
INSERT INTO #R EXEC Parts.PackOut_Save @ItemId = @Item, @ClosureMethod = N'ByWeight', @Name = N'Tote',
    @TraysPerContainer = 4, @PartsPerTray = 8, @TargetWeight = 62.0, @ToleranceWeight = 1.5, @AppUserId = 1;
SET @S = (SELECT CONCAT(r.Status, N'|', p.IsDefault) FROM #R r JOIN Parts.PackOut p ON p.Id = r.NewId);
EXEC test.Assert_IsEqual @TestName = N'[Save] second pack-out is not the default', @Expected = N'1|0', @Actual = @S;

DELETE FROM #R;
INSERT INTO #R EXEC Parts.PackOut_Save @ItemId = @Item, @ClosureMethod = N'ByWeight', @Name = N' tote',
    @TraysPerContainer = 4, @PartsPerTray = 8, @TargetWeight = 62.0, @ToleranceWeight = 1.5, @AppUserId = 1;
SET @S = (SELECT CONCAT(Status, N'|', CASE WHEN Message LIKE N'%already%' THEN N'dup' ELSE Message END) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[Save] duplicate name (case / spaces) refused', @Expected = N'0|dup', @Actual = @S;

DELETE FROM #R;
INSERT INTO #R EXEC Parts.PackOut_Save @ItemId = @Item, @ClosureMethod = N'ByWeight', @Name = N'Zero tol',
    @TraysPerContainer = 1, @PartsPerTray = 6, @TargetWeight = 15.0, @ToleranceWeight = 0, @AppUserId = 1;
SET @S = (SELECT CONCAT(Status, N'|', CASE WHEN Message LIKE N'%positive tolerance%' THEN N'tol' ELSE Message END) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[Save] By Weight zero tolerance refused', @Expected = N'0|tol', @Actual = @S;

DELETE FROM #R;
INSERT INTO #R EXEC Parts.PackOut_Save @ItemId = @Item, @ClosureMethod = N'ByWeight', @Name = N'No target',
    @TraysPerContainer = 1, @PartsPerTray = 6, @ToleranceWeight = 1, @AppUserId = 1;
SET @S = (SELECT CONCAT(Status, N'|', CASE WHEN Message LIKE N'%target weight%' THEN N'tgt' ELSE Message END) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[Save] By Weight missing target refused', @Expected = N'0|tgt', @Actual = @S;

DELETE FROM #R;
INSERT INTO #R EXEC Parts.PackOut_Save @ItemId = @Item, @ClosureMethod = N'ByCount', @Name = N'   ',
    @TraysPerContainer = 1, @PartsPerTray = 6, @AppUserId = 1;
SET @S = (SELECT CONCAT(Status, N'|', CASE WHEN Message LIKE N'%name%' THEN N'name' ELSE Message END) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[Save] blank name refused', @Expected = N'0|name', @Actual = @S;

DELETE FROM #R;
INSERT INTO #R EXEC Parts.PackOut_Save @ItemId = @Item, @ClosureMethod = N'ByCount', @Name = N'Bulk',
    @TraysPerContainer = 0, @PartsPerTray = 6, @AppUserId = 1;
SET @S = (SELECT CAST(Status AS NVARCHAR(1)) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[Save] non-positive trays refused', @Expected = N'0', @Actual = @S;

DELETE FROM #R;
INSERT INTO #R EXEC Parts.PackOut_Save @ItemId = @Item, @ClosureMethod = N'ByCount', @Name = N'Tote',
    @TraysPerContainer = 2, @PartsPerTray = 12, @AppUserId = 1;
SET @S = (SELECT CONCAT(r.Status, N'|', p.IsDefault) FROM #R r JOIN Parts.PackOut p ON p.Id = r.NewId);
EXEC test.Assert_IsEqual @TestName = N'[Save] By Count pack-out has its own default', @Expected = N'1|1', @Actual = @S;
GO

-- ---- Edit = new version; a box keeps its version ----
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-PO-CRUD');
DECLARE @Line BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-PO-LINE');
DECLARE @Card BIGINT = (SELECT Id FROM Parts.PackOut WHERE ItemId = @Item AND ClosureMethod = N'ByWeight' AND Name = N'Cardboard' AND DeprecatedAt IS NULL);
DECLARE @V1 BIGINT = (SELECT Id FROM Parts.ContainerConfig WHERE PackOutId = @Card AND DeprecatedAt IS NULL);
INSERT INTO Lots.Container (ItemId, ContainerConfigId, CurrentLocationId, ContainerStatusCodeId, CreatedByUserId)
VALUES (@Item, @V1, @Line, 1, 1);
DECLARE @Box BIGINT = SCOPE_IDENTITY();
DECLARE @S NVARCHAR(500);

DELETE FROM #R;
INSERT INTO #R EXEC Parts.PackOut_Save @PackOutId = @Card, @ItemId = @Item, @ClosureMethod = N'ByWeight', @Name = N'Cardboard',
    @TraysPerContainer = 1, @PartsPerTray = 7, @TargetWeight = 17.5, @ToleranceWeight = 1.35, @AppUserId = 1;
SET @S = (SELECT CONCAT(r.Status, N'|', r.NewId - @Card, N'|', cc.VersionNumber, N'|', cc.PartsPerTray)
          FROM #R r JOIN Parts.ContainerConfig cc ON cc.PackOutId = r.NewId AND cc.DeprecatedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Save] value edit -> same pack-out, version 2', @Expected = N'1|0|2|7', @Actual = @S;

SET @S = (SELECT CONCAT(CASE WHEN cc.DeprecatedAt IS NOT NULL THEN N'retired' ELSE N'active' END, N'|', cc.PartsPerTray)
          FROM Lots.Container c JOIN Parts.ContainerConfig cc ON cc.Id = c.ContainerConfigId WHERE c.Id = @Box);
EXEC test.Assert_IsEqual @TestName = N'[Save] open box keeps version 1 (retired, 6/tray)', @Expected = N'retired|6', @Actual = @S;

DELETE FROM #R;
INSERT INTO #R EXEC Parts.PackOut_Save @PackOutId = @Card, @ItemId = @Item, @ClosureMethod = N'ByWeight', @Name = N'Cardboard 7',
    @TraysPerContainer = 1, @PartsPerTray = 7, @TargetWeight = 17.5, @ToleranceWeight = 1.35, @AppUserId = 1;
SET @S = (SELECT CONCAT(r.Status, N'|', p.Name, N'|', cc.VersionNumber)
          FROM #R r JOIN Parts.PackOut p ON p.Id = r.NewId JOIN Parts.ContainerConfig cc ON cc.PackOutId = p.Id AND cc.DeprecatedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Save] rename only -> same version', @Expected = N'1|Cardboard 7|2', @Actual = @S;

DELETE FROM #R;
INSERT INTO #R EXEC Parts.PackOut_Save @PackOutId = @Card, @ItemId = @Item, @ClosureMethod = N'ByWeight', @Name = N'Cardboard',
    @TraysPerContainer = 2, @PartsPerTray = 7, @TargetWeight = 17.5, @ToleranceWeight = 1.35, @AppUserId = 1;
SET @S = (SELECT CONCAT(r.Status, N'|', p.Name, N'|', cc.VersionNumber, N'|', cc.TraysPerContainer)
          FROM #R r JOIN Parts.PackOut p ON p.Id = r.NewId JOIN Parts.ContainerConfig cc ON cc.PackOutId = p.Id AND cc.DeprecatedAt IS NULL);
EXEC test.Assert_IsEqual @TestName = N'[Save] rename + value change -> one new version', @Expected = N'1|Cardboard|3|2', @Actual = @S;

DELETE FROM #R;
INSERT INTO #R EXEC Parts.PackOut_Save @PackOutId = @Card, @ItemId = @Item, @ClosureMethod = N'ByWeight', @Name = N'Cardboard',
    @TraysPerContainer = 2, @PartsPerTray = 7, @TargetWeight = 17.5, @ToleranceWeight = 1.35, @AppUserId = 1;
SET @S = (SELECT CONCAT(Status, N'|', Message) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[Save] no change refused', @Expected = N'0|No changes to save.', @Actual = @S;

DELETE FROM #R;
INSERT INTO #R EXEC Parts.PackOut_Save @PackOutId = @Card, @ItemId = @Item, @ClosureMethod = N'ByCount', @Name = N'Cardboard',
    @TraysPerContainer = 2, @PartsPerTray = 7, @AppUserId = 1;
SET @S = (SELECT CAST(Status AS NVARCHAR(1)) FROM #R);
EXEC test.Assert_IsEqual @TestName = N'[Save] closure method of an existing pack-out is immutable', @Expected = N'0', @Actual = @S;

DECLARE @Audit NVARCHAR(10) = (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM Audit.ConfigLog cl
    JOIN Audit.LogEntityType et ON et.Id = cl.LogEntityTypeId AND et.Code = N'PackOut'
    JOIN Audit.LogEventType ev ON ev.Id = cl.LogEventTypeId AND ev.Code = N'PackOutVersioned'
    WHERE cl.EntityId = @Card);
EXEC test.Assert_IsEqual @TestName = N'[Save] each version audited (2 PackOutVersioned)', @Expected = N'2', @Actual = @Audit;

DELETE FROM Lots.Container WHERE Id = @Box;
GO

-- ---- Default + Deprecate ----
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-PO-CRUD');
DECLARE @T1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-PO-T1');
DECLARE @Card BIGINT = (SELECT Id FROM Parts.PackOut WHERE ItemId = @Item AND ClosureMethod = N'ByWeight' AND Name = N'Cardboard' AND DeprecatedAt IS NULL);
DECLARE @Tote BIGINT = (SELECT Id FROM Parts.PackOut WHERE ItemId = @Item AND ClosureMethod = N'ByWeight' AND Name = N'Tote' AND DeprecatedAt IS NULL);
DECLARE @S NVARCHAR(500);

DELETE FROM #S; INSERT INTO #S EXEC Parts.PackOut_SetDefault @PackOutId = @Tote, @AppUserId = 1;
SET @S = (SELECT CONCAT((SELECT Status FROM #S), N'|',
          (SELECT STRING_AGG(Name, N',') FROM Parts.PackOut WHERE ItemId = @Item AND ClosureMethod = N'ByWeight' AND IsDefault = 1 AND DeprecatedAt IS NULL)));
EXEC test.Assert_IsEqual @TestName = N'[Default] moves the flag (exactly one default)', @Expected = N'1|Tote', @Actual = @S;

DELETE FROM #S; INSERT INTO #S EXEC Parts.PackOut_SetDefault @PackOutId = @Tote, @AppUserId = 1;
SET @S = (SELECT CAST(Status AS NVARCHAR(1)) FROM #S);
EXEC test.Assert_IsEqual @TestName = N'[Default] already default refused', @Expected = N'0', @Actual = @S;

DELETE FROM #S; INSERT INTO #S EXEC Parts.PackOut_Deprecate @PackOutId = @Tote, @AppUserId = 1;
SET @S = (SELECT CONCAT(Status, N'|', CASE WHEN Message LIKE N'%another pack-out the default%' THEN N'def' ELSE Message END) FROM #S);
EXEC test.Assert_IsEqual @TestName = N'[Deprecate] the default with siblings refused', @Expected = N'0|def', @Actual = @S;

INSERT INTO Location.TerminalPackOutSelection (TerminalLocationId, ItemId, ClosureMethod, PackOutId, SetByUserId) VALUES (@T1, @Item, N'ByWeight', @Card, 1);
DELETE FROM #S; INSERT INTO #S EXEC Parts.PackOut_Deprecate @PackOutId = @Card, @AppUserId = 1;
SET @S = (SELECT CONCAT((SELECT Status FROM #S), N'|',
          (SELECT COUNT(*) FROM Location.TerminalPackOutSelection WHERE PackOutId = @Card), N'|',
          (SELECT COUNT(*) FROM Parts.ContainerConfig WHERE PackOutId = @Card AND DeprecatedAt IS NULL), N'|',
          (SELECT CASE WHEN DeprecatedAt IS NULL THEN N'active' ELSE N'gone' END FROM Parts.PackOut WHERE Id = @Card)));
EXEC test.Assert_IsEqual @TestName = N'[Deprecate] non-default removed with its version and picks', @Expected = N'1|0|0|gone', @Actual = @S;

DELETE FROM #S; INSERT INTO #S EXEC Parts.PackOut_Deprecate @PackOutId = @Tote, @AppUserId = 1;
SET @S = (SELECT CAST(Status AS NVARCHAR(1)) FROM #S);
EXEC test.Assert_IsEqual @TestName = N'[Deprecate] the last pack-out may be removed', @Expected = N'1', @Actual = @S;
GO

-- ---- ListByItem ----
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-PO-FG');
DECLARE @T1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TST-PO-T1');
DECLARE @Tote BIGINT = (SELECT Id FROM Parts.PackOut WHERE ItemId = @Item AND Name = N'Tote' AND DeprecatedAt IS NULL);
CREATE TABLE #L (PackOutId BIGINT, ClosureMethod NVARCHAR(20), Name NVARCHAR(50), IsDefault BIT, IsSelected BIT, IsRunning BIT,
                 ContainerConfigId BIGINT, VersionNumber INT, PartsPerTray INT, TraysPerContainer INT, TargetWeight DECIMAL(10,4),
                 ToleranceWeight DECIMAL(10,4), IsSerialized BIT, DunnageCode NVARCHAR(50), CustomerCode NVARCHAR(50), UpdatedAtEt DATETIME2(3));
INSERT INTO #L EXEC Parts.PackOut_ListByItem @ItemId = @Item;
DECLARE @S NVARCHAR(500) = (SELECT STRING_AGG(CONCAT(Name, N':', IsDefault, IsSelected, IsRunning), N',') WITHIN GROUP (ORDER BY IsDefault DESC, Name) FROM #L);
EXEC test.Assert_IsEqual @TestName = N'[List] no terminal: running = default', @Expected = N'Cardboard:101,Tote:000', @Actual = @S;

INSERT INTO Location.TerminalPackOutSelection (TerminalLocationId, ItemId, ClosureMethod, PackOutId, SetByUserId) VALUES (@T1, @Item, N'ByWeight', @Tote, 1);
DELETE FROM #L; INSERT INTO #L EXEC Parts.PackOut_ListByItem @ItemId = @Item, @TerminalLocationId = @T1;
SET @S = (SELECT STRING_AGG(CONCAT(Name, N':', IsDefault, IsSelected, IsRunning), N',') WITHIN GROUP (ORDER BY IsDefault DESC, Name) FROM #L);
EXEC test.Assert_IsEqual @TestName = N'[List] terminal pick flagged selected + running', @Expected = N'Cardboard:100,Tote:011', @Actual = @S;
DELETE FROM Location.TerminalPackOutSelection WHERE TerminalLocationId = @T1;
DROP TABLE #L;
GO

-- ---- Item_Deprecate cascades to pack-outs ----
DECLARE @Item BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'TST-PO-CASC');
INSERT INTO #R EXEC Parts.PackOut_Save @ItemId = @Item, @ClosureMethod = N'ByCount', @Name = N'Box', @TraysPerContainer = 1, @PartsPerTray = 6, @AppUserId = 1;
DECLARE @Dep TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @Dep EXEC Parts.Item_Deprecate @Id = @Item, @AppUserId = 1;
DECLARE @S NVARCHAR(100) = (SELECT CONCAT((SELECT TOP 1 Status FROM @Dep), N'|',
    (SELECT COUNT(*) FROM Parts.PackOut WHERE ItemId = @Item AND DeprecatedAt IS NULL), N'|',
    (SELECT COUNT(*) FROM Parts.ContainerConfig WHERE ItemId = @Item AND DeprecatedAt IS NULL)));
EXEC test.Assert_IsEqual @TestName = N'[Item_Deprecate] cascades to pack-out headers and versions', @Expected = N'1|0|0', @Actual = @S;
GO

DROP TABLE #R; DROP TABLE #S;
DELETE FROM Parts.ContainerConfig WHERE ItemId IN (SELECT Id FROM Parts.Item WHERE PartNumber IN (N'TST-PO-CRUD', N'TST-PO-CASC'));
DELETE FROM Parts.Item WHERE PartNumber IN (N'TST-PO-CRUD', N'TST-PO-CASC');
GO
EXEC test.EndTestFile;
GO
