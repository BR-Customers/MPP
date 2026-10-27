-- ============================================================
-- Seed:        060_demo_quality_scenario.sql   (MPP_MES_Demo ONLY, opt-in)
-- Description: The quality-and-containment scenario for sales-kit module 4, on top of
--              050's shift, through the application's procs only. Loaded only by
--              Build-DemoDatabase.ps1 -WithQualityScenario, so modules 1-3 can still be
--              captured without super-lot state.
--
--                Before the window: casting 520100005 is trimmed out (waits for Machining
--                  IN), 16 more machined housings are minted from 520100003, and a third
--                  seal-kit box (SUP-1107) is checked in at the housing line.
--                Detect: casting 520100004 (waiting for Machining IN) goes on a hard Hold.
--                Contain: super-lot CR000001 is opened from it -- the housing castings of
--                  the shift and the machined housings still at the line -- with "keep
--                  adding new production" on for HSG-410 (no line named, so new baskets
--                  at the press join).
--                Pull back: a completed FG-4100 container and the SUP-1107 box are added.
--                New production: basket 520100007 is released and 520100009 opened on the
--                  same cavity -- born tagged; one FG-4100 tray is built from tagged
--                  machined housings -- born tagged (it is not a member: the tag carries,
--                  the container cannot ship).
--                Results: 520100006 recorded (46 accepted, 2 scrapped for porosity); the
--                  rest is left for the live session, as are release, deviation and repack.
--
--              The sample Quality user E. Novak (EN, PIN 61030) has AdAccount
--              'quality.sample'; Set-QualityAdAccount.ps1 points it at the presenter's
--              login at session time, so no real login is ever in this file.
--              Every call checks its status row and stops the script on failure. ASCII-only.
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;

DECLARE @Sys BIGINT = 1;
DECLARE @JK BIGINT = (SELECT Id FROM Location.AppUser WHERE Pin = N'04218');
DECLARE @AM BIGINT = (SELECT Id FROM Location.AppUser WHERE Pin = N'40218');
DECLARE @TN BIGINT = (SELECT Id FROM Location.AppUser WHERE Pin = N'31570');
DECLARE @LB BIGINT = (SELECT Id FROM Location.AppUser WHERE Pin = N'02693');
DECLARE @Shift BIGINT = (SELECT TOP 1 Id FROM Oee.Shift WHERE ActualEnd IS NULL ORDER BY Id DESC);
DECLARE @DCT BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'DC-T1');
DECLARE @P01 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'P-01');
DECLARE @TRIM BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM');
DECLARE @TRIMT BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'TRIM-T1');
DECLARE @L1 BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'L-1');
DECLARE @L1MOUT BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'L1-MOUT');
DECLARE @L1AOUT BIGINT = (SELECT Id FROM Location.Location WHERE Code = N'L1-AOUT');
DECLARE @OtTrimOut BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'TrimOut');
DECLARE @OtMachOut BIGINT = (SELECT Id FROM Parts.OperationTemplate WHERE Code = N'MachiningOut');
DECLARE @Received BIGINT = (SELECT Id FROM Lots.LotOriginType WHERE Code = N'Received');
DECLARE @Porosity BIGINT = (SELECT Id FROM Quality.DefectCode WHERE Code = N'DC-POR');
DECLARE @QualityHold BIGINT = (SELECT Id FROM Quality.HoldTypeCode WHERE Code = N'Quality');
DECLARE @Hsg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'HSG-410');
DECLARE @HsgM BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'HSG-410-M');
DECLARE @Seal BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'SEAL-01');
DECLARE @Fg BIGINT = (SELECT Id FROM Parts.Item WHERE PartNumber = N'FG-4100');
DECLARE @D210 BIGINT = (SELECT Id FROM Tools.Tool WHERE Code = N'D-210');
IF @Shift IS NULL RAISERROR('060_demo_quality_scenario: no open shift', 16, 1);

DECLARE @r2 TABLE (Status BIT, Message NVARCHAR(500));
DECLARE @r3 TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT);
DECLARE @rMint TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, Available INT);
DECLARE @rLot TABLE (Status BIT, Message NVARCHAR(500), NewId BIGINT, MintedLotName NVARCHAR(50));
DECLARE @rTray TABLE (Status BIT, Message NVARCHAR(500), FinishedGoodLotId BIGINT, ContainerId BIGINT, ContainerTrayId BIGINT, ContainerFull BIT, TraysPerContainer INT);
DECLARE @msg NVARCHAR(600), @lot BIGINT, @json NVARCHAR(MAX), @EN BIGINT, @Run BIGINT, @pcs INT;

-- ---- The sample Quality user ----
DELETE @r3;
INSERT INTO @r3 EXEC Location.AppUser_Create @Initials = N'EN', @DisplayName = N'E. Novak', @Pin = N'61030',
    @AdAccount = N'quality.sample', @IgnitionRole = NULL, @AppUserId = @Sys;
IF NOT EXISTS (SELECT 1 FROM @r3 WHERE Status = 1) BEGIN SELECT @msg = N'quality user: ' + Message FROM @r3; THROW 51000, @msg, 1; END
SET @EN = (SELECT Id FROM Location.AppUser WHERE Pin = N'61030');

-- ======================================================================================
-- Before the window opens
-- ======================================================================================
-- 520100005 (checked in at trim by 050) is checked out to the housing line: it waits for Machining IN.
SELECT @lot = Id, @pcs = PieceCount FROM Lots.Lot WHERE LotName = N'520100005';
DELETE @r3;
INSERT INTO @r3 EXEC Workorder.TrimOut_Record @ParentLotId = @lot, @OperationTemplateId = @OtTrimOut, @ShotCount = @pcs,
    @DestinationCellLocationId = @L1, @SourceLocationId = @TRIM, @AppUserId = @AM, @TerminalLocationId = @TRIMT;
IF NOT EXISTS (SELECT 1 FROM @r3 WHERE Status = 1) BEGIN SELECT @msg = N'trim out 520100005: ' + Message FROM @r3; THROW 51000, @msg, 1; END

-- 16 more machined housings from 520100003 (32 -> 16 left), so a tray can be built after the window opens.
SET @lot = (SELECT Id FROM Lots.Lot WHERE LotName = N'520100003');
DELETE @rMint;
INSERT INTO @rMint EXEC Workorder.MachiningOut_Mint @SourceLotId = @lot, @OperationTemplateId = @OtMachOut, @PieceCount = 16,
    @AppUserId = @TN, @TerminalLocationId = @L1MOUT;
IF NOT EXISTS (SELECT 1 FROM @rMint WHERE Status = 1) BEGIN SELECT @msg = N'mint from 520100003: ' + Message FROM @rMint; THROW 51000, @msg, 1; END

-- A third seal-kit box. The tray below uses SUP-1102 first (FIFO), so SUP-1107 stays open:
-- the received member Return to vendor is offered on.
DELETE @rLot;
INSERT INTO @rLot EXEC Lots.Lot_Create @ItemId = @Seal, @LotOriginTypeId = @Received, @CurrentLocationId = @L1, @PieceCount = 40,
    @VendorLotNumber = N'SUP-1107', @AppUserId = @LB, @TerminalLocationId = @L1AOUT;
IF NOT EXISTS (SELECT 1 FROM @rLot WHERE Status = 1) BEGIN SELECT @msg = N'seal box 3: ' + Message FROM @rLot; THROW 51000, @msg, 1; END
DECLARE @SealBox BIGINT = (SELECT NewId FROM @rLot);

-- ======================================================================================
-- Detect: the problem casting goes on a hard Hold
-- ======================================================================================
DECLARE @Problem BIGINT = (SELECT Id FROM Lots.Lot WHERE LotName = N'520100004');
DELETE @r3;
INSERT INTO @r3 EXEC Quality.Hold_Place @LotId = @Problem, @HoldTypeCodeId = @QualityHold,
    @Reason = N'Porosity found at incoming inspection', @AppUserId = @EN, @TerminalLocationId = @DCT;
IF NOT EXISTS (SELECT 1 FROM @r3 WHERE Status = 1) BEGIN SELECT @msg = N'hold 520100004: ' + Message FROM @r3; THROW 51000, @msg, 1; END

-- ======================================================================================
-- Contain: CR000001 from the problem casting, keep adding new production of HSG-410
-- ======================================================================================
SET @json = (
    SELECT l.Id AS lotId
    FROM Lots.Lot l JOIN Lots.LotStatusCode s ON s.Id = l.LotStatusId
    WHERE s.Code <> N'Closed' AND l.PieceCount > 0
      AND (l.LotName IN (N'520100003', N'520100004', N'520100005', N'520100006', N'520100007', N'520100008')
           OR l.ItemId = @HsgM)
    ORDER BY l.Id FOR JSON PATH);
DELETE @r3;
INSERT INTO @r3 EXEC Quality.ControlledRun_Open
    @Reason = N'Porosity found at incoming inspection - contain and 200% inspect',
    @AnchorLotId = @Problem, @SelectionItemId = @Hsg, @IncludeDescendants = 1, @AutoJoinEnabled = 1,
    @MembersJson = @json, @AppUserId = @EN, @TerminalLocationId = @DCT;
IF NOT EXISTS (SELECT 1 FROM @r3 WHERE Status = 1) BEGIN SELECT @msg = N'open super-lot: ' + Message FROM @r3; THROW 51000, @msg, 1; END
SET @Run = (SELECT NewId FROM @r3);

-- ---- Pull back: a completed container, and the received seal-kit box ----
DECLARE @Cont BIGINT = (SELECT TOP 1 c.Id FROM Lots.Container c WHERE c.CompletedAt IS NOT NULL ORDER BY c.Id);
SET @json = N'[{"containerId":' + CAST(@Cont AS NVARCHAR(20)) + N'},{"lotId":' + CAST(@SealBox AS NVARCHAR(20)) + N'}]';
DELETE @r2;
INSERT INTO @r2 EXEC Quality.ControlledRun_AddMembers @Id = @Run, @MembersJson = @json, @AppUserId = @EN, @TerminalLocationId = @DCT;
IF NOT EXISTS (SELECT 1 FROM @r2 WHERE Status = 1) BEGIN SELECT @msg = N'add members: ' + Message FROM @r2; THROW 51000, @msg, 1; END

-- ======================================================================================
-- New production after the window opened
-- ======================================================================================
-- Basket 520100007 (cavity a) is released and the next basket opened on the same cavity.
SET @lot = (SELECT Id FROM Lots.Lot WHERE LotName = N'520100007');
DELETE @r3;
INSERT INTO @r3 EXEC Lots.DieCastLot_Release @LotId = @lot, @CounterReading = 192, @ShiftId = @Shift,
    @AppUserId = @JK, @TerminalLocationId = @DCT, @CellLocationId = @P01;
IF NOT EXISTS (SELECT 1 FROM @r3 WHERE Status = 1) BEGIN SELECT @msg = N'release 520100007: ' + Message FROM @r3; THROW 51000, @msg, 1; END
DECLARE @CavA BIGINT = (SELECT Id FROM Tools.ToolCavity WHERE ToolId = @D210 AND ItemId = @Hsg AND CavityCode = N'a');
DELETE @r3;
INSERT INTO @r3 EXEC Lots.DieCastLot_Open @ItemId = @Hsg, @CurrentLocationId = @P01, @ToolId = @D210,
    @ToolCavityId = @CavA, @LotName = N'520100009', @AppUserId = @JK, @TerminalLocationId = @DCT;
IF NOT EXISTS (SELECT 1 FROM @r3 WHERE Status = 1) BEGIN SELECT @msg = N'open 520100009: ' + Message FROM @r3; THROW 51000, @msg, 1; END

-- One FG-4100 tray from the (tagged) machined housings: the tray LOT is born tagged.
DELETE @rTray;
INSERT INTO @rTray EXEC Workorder.Assembly_CompleteTray @FinishedGoodItemId = @Fg, @PieceCount = 12, @CellLocationId = @L1,
    @ClosureMethod = N'ByCount', @AppUserId = @LB, @TerminalLocationId = @L1AOUT;
IF NOT EXISTS (SELECT 1 FROM @rTray WHERE Status = 1) BEGIN SELECT @msg = N'tagged tray: ' + Message FROM @rTray; THROW 51000, @msg, 1; END

-- The gateway timer records auto-joined LOTs as members; run it once here.
DELETE @r2;
INSERT INTO @r2 EXEC Quality.ControlledRun_SyncAutoJoin @Id = @Run, @AppUserId = @Sys;
IF NOT EXISTS (SELECT 1 FROM @r2 WHERE Status = 1) BEGIN SELECT @msg = N'sync auto-join: ' + Message FROM @r2; THROW 51000, @msg, 1; END

-- ======================================================================================
-- Results part-way: 520100006 inspected (46 accepted, 2 scrapped for porosity)
-- ======================================================================================
DECLARE @Mem BIGINT = (SELECT m.Id FROM Quality.ControlledRunMember m JOIN Lots.Lot l ON l.Id = m.LotId
                        WHERE m.ControlledRunId = @Run AND m.EndedAt IS NULL AND l.LotName = N'520100006');
SET @json = N'[{"memberId":' + CAST(@Mem AS NVARCHAR(20)) + N',"dispositionCode":"Accepted","quantity":46,"defectCodeId":null,"remarks":null},'
          + N'{"memberId":' + CAST(@Mem AS NVARCHAR(20)) + N',"dispositionCode":"Scrap","quantity":2,"defectCodeId":' + CAST(@Porosity AS NVARCHAR(20)) + N',"remarks":null}]';
DELETE @r3;
INSERT INTO @r3 EXEC Quality.ControlledRunResult_Record @ControlledRunId = @Run, @ResultsJson = @json, @AppUserId = @EN, @TerminalLocationId = @DCT;
IF NOT EXISTS (SELECT 1 FROM @r3 WHERE Status = 1) BEGIN SELECT @msg = N'results 520100006: ' + Message FROM @r3; THROW 51000, @msg, 1; END
