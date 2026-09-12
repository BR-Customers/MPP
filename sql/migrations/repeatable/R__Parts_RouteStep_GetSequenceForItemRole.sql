-- ============================================================
-- Repeatable:  R__Parts_RouteStep_GetSequenceForItemRole.sql
-- Author:      Blue Ridge Automation
-- Modified:    2026-09-12
-- Version:     1.0
-- Description: The SequenceNumber at which an OperationType ROLE sits on a
--              part's active published route. The inventory cutover scan passes
--              the result straight to Lots.Lot_Create @EntryRouteSequence, so
--              this is the one place that decides where scanned stock joins its
--              route.
--
--              Resolution is by ROLE ('MachiningIn', 'AssemblyIn', 'TrimOut',
--              ...) and NEVER by OperationTemplate CODE. Template codes are
--              'M-In-A' / 'T-Out-A' / 'M-Out-A'; a by-code lookup on a role name
--              always misses and returns nothing, which is the root of the
--              recurring "template missing" class of bug.
--
--              This is domain logic and therefore lives in SQL, not in a
--              Perspective binding: the screen asks the question, it does not
--              compute the answer.
--
--              MIN() because a role could in principle appear more than once on
--              a route; the FIRST occurrence is where stock enters.
--
--              Read proc: no OUTPUT params. The HAVING is what makes "this route
--              carries no step with that role" an EMPTY RESULT SET rather than a
--              single row of NULL -- a bare aggregate always returns one row, and
--              the caller branches on absence (FDS-11-011).
-- ============================================================
CREATE OR ALTER PROCEDURE Parts.RouteStep_GetSequenceForItemRole
    @ItemId            BIGINT,
    @OperationTypeCode NVARCHAR(30)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT MIN(rs.SequenceNumber) AS SequenceNumber
    FROM Parts.RouteTemplate rt
    INNER JOIN Parts.RouteStep rs         ON rs.RouteTemplateId = rt.Id
    INNER JOIN Parts.OperationTemplate ot ON ot.Id  = rs.OperationTemplateId
    INNER JOIN Parts.OperationType oty    ON oty.Id = ot.OperationTypeId
    WHERE rt.ItemId = @ItemId
      AND rt.PublishedAt IS NOT NULL AND rt.DeprecatedAt IS NULL
      AND oty.Code = @OperationTypeCode
    HAVING MIN(rs.SequenceNumber) IS NOT NULL;
END;
GO
