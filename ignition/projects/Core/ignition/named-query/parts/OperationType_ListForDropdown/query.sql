SELECT typ.Id, typ.Code, typ.Name, cat.Code AS CategoryCode, cat.Name AS CategoryName
FROM Parts.OperationType typ
INNER JOIN Parts.OperationCategory cat ON cat.Id = typ.OperationCategoryId
WHERE typ.DeprecatedAt IS NULL
ORDER BY cat.Code, typ.Code
