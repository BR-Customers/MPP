EXEC Workorder.MachiningOut_RecordSplit
    @ParentLotId         = :parentLotId,
    @OperationTemplateId = :operationTemplateId,
    @SplitChildrenJson   = :splitChildrenJson,
    @AppUserId           = :appUserId,
    @TerminalLocationId  = :terminalLocationId
