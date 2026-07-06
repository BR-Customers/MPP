-- Resolve the active OperationTemplate for a part's route step of a given
-- OperationType role (Spec 2 Task M3). The terminal knows its role (e.g.
-- 'MachiningOut'); this returns the template Id configured for that role on the
-- scanned part's active (non-deprecated, latest-version) route. Empty result = the
-- part's route has no step of that role.
SELECT TOP 1
    ot.Id            AS OperationTemplateId,
    ot.Code          AS OperationTemplateCode,
    ot.Name          AS OperationTemplateName,
    oty.Code         AS OperationTypeCode
FROM Parts.RouteTemplate rt
INNER JOIN Parts.RouteStep rs        ON rs.RouteTemplateId = rt.Id
INNER JOIN Parts.OperationTemplate ot ON ot.Id = rs.OperationTemplateId
INNER JOIN Parts.OperationType oty    ON oty.Id = ot.OperationTypeId
WHERE rt.ItemId = :itemId
  AND rt.DeprecatedAt IS NULL
  AND ot.DeprecatedAt IS NULL
  AND oty.Code = :operationTypeCode
ORDER BY rt.VersionNumber DESC, rs.SequenceNumber ASC;
