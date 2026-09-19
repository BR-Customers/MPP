# =============================================================================
# Export-ProdConfig.ps1 -- pull a READ-ONLY snapshot of the plant configuration
# (locations, parts, routes, BOMs, tools/dies, quality + downtime codes, users,
# shifts, label templates, code tables) out of a database and save it locally.
#
#   Purpose: bring Dev's configuration in line with prod's real configuration
#   (for training material and realistic testing). This script only EXTRACTS.
#   Loading the snapshot into Dev is a separate, reviewed step.
#
# Usage (from the repo root):
#   .\sql\scripts\Export-ProdConfig.ps1                                   # prod, SQL login 'Ignition'
#   .\sql\scripts\Export-ProdConfig.ps1 -ServerInstance localhost -DatabaseName MPP_MES_Dev -Username ""
#
# Password: taken from $env:SQLCMDPASSWORD if set, else a masked prompt. It goes
# to SqlClient as a SqlCredential (SecureString), never into a connection string
# or onto a command line.
#
# Output (default): sql\scratch\_prod_config_<yyyyMMdd_HHmm>\   (git-ignored)
#   <Schema>.<Table>.json   authoritative: every column, NULLs kept, one row per line
#   <Schema>.<Table>.csv    the same rows for eyeballing in Excel (NULL -> empty)
#   _schema.json            column definitions + foreign keys of the extracted tables
#   _inventory.csv          EVERY table in the source: row count, extracted or why not
#   _manifest.json          source, capture time, migration level, per-table counts
#
# What is extracted: every table EXCEPT the transactional / log tables listed in
# $Transactional below and the test schema. A table this script has never heard
# of is extracted anyway and flagged "unclassified" in the inventory, so a new
# config table added by a later migration is not silently missed. An unclassified
# table over $LargeTableRows rows is skipped with a warning -- that is almost
# certainly transactional and belongs in $Transactional.
#
# Secrets: Lots.AimPoolConfig.AimPathToken is written as "<redacted>" (the AIM
# endpoint's path token authenticates the Honda interface; it has no business on
# a laptop or in Dev). Add further columns to $Redact.
#
# SAFETY: the only statements this script sends are SELECTs it builds itself
# from sys.tables / sys.columns metadata; there is no .sql file to drift. The
# connection is tagged "MPP Export-ProdConfig" so it is identifiable in
# sys.dm_exec_sessions. Each table is read with its own short query -- no
# long-held locks on a live plant.
# =============================================================================
param(
    [string]$ServerInstance  = "172.17.10.148",
    [string]$DatabaseName    = "MPP_MES_Prod",
    [string]$Username        = "Ignition",
    [string]$OutputDirectory = "",
    [int]   $LargeTableRows  = 100000
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# ---- Classification ---------------------------------------------------------
# Transactional / event / log tables: runtime history, not configuration.
$Transactional = @(
    'Audit.ConfigLog', 'Audit.FailureLog', 'Audit.InterfaceLog', 'Audit.OperationLog',
    'Lots.AimShipperIdPool', 'Lots.Container', 'Lots.ContainerSerial', 'Lots.ContainerSerialHistory',
    'Lots.ContainerTray', 'Lots.Lot', 'Lots.LotAttributeChange', 'Lots.LotEventLog',
    'Lots.LotGenealogy', 'Lots.LotGenealogyClosure', 'Lots.LotLabel', 'Lots.LotMovement',
    'Lots.LotStatusHistory', 'Lots.PauseEvent', 'Lots.SerializedPart', 'Lots.ShippingLabel',
    'Oee.DowntimeEvent', 'Oee.Shift', 'Oee.ShiftOverride',
    'Quality.HoldEvent', 'Quality.QualityAttachment', 'Quality.QualityResult', 'Quality.QualitySample',
    'Workorder.ConsumptionEvent', 'Workorder.DieCastContribution', 'Workorder.DieCastCounterAnchor',
    'Workorder.ProductionEvent', 'Workorder.ProductionEventValue', 'Workorder.RejectEvent',
    'Workorder.WorkOrder', 'Workorder.WorkOrderOperation',
    # Ignition's gateway audit profile (logins, project/resource saves) shares the
    # prod database. Not MES config, and its resource JSON can carry credentials.
    'dbo.audit_events'
)
$ExcludedSchemas = @('test')

# Configuration + code tables known as of migration 0095. Only used to flag a
# table that is in neither list as "unclassified" -- it does not limit the pull.
$KnownConfig = @(
    'dbo.SchemaVersion',
    'Audit.LogEntityType', 'Audit.LogEventType', 'Audit.LogSeverity', 'Audit.PartitionRetention',
    'Location.AppUser', 'Location.Location', 'Location.LocationAttribute', 'Location.LocationAttributeDefinition',
    'Location.LocationType', 'Location.LocationTypeDefinition', 'Location.PlcDeviceType',
    'Location.PrinterFgAssignment', 'Location.SessionPolicy', 'Location.TerminalPlcDevice',
    'Lots.AimPoolConfig', 'Lots.ContainerStatusCode', 'Lots.GenealogyRelationshipType',
    'Lots.IdentifierSequence', 'Lots.LabelTemplate', 'Lots.LabelTypeCode', 'Lots.LotOriginType',
    'Lots.LotStatusCode', 'Lots.PrintReasonCode',
    'Oee.DowntimeReasonCode', 'Oee.DowntimeReasonType', 'Oee.DowntimeSourceCode', 'Oee.ShiftSchedule',
    'Parts.Bom', 'Parts.BomLine', 'Parts.ClosureMethodCode', 'Parts.ContainerConfig',
    'Parts.DataCollectionField', 'Parts.DataCollectionFieldDataType', 'Parts.Item', 'Parts.ItemLocation',
    'Parts.ItemType', 'Parts.OperationCategory', 'Parts.OperationRoleKind', 'Parts.OperationTemplate',
    'Parts.OperationTemplateField', 'Parts.OperationType', 'Parts.RouteStep', 'Parts.RouteTemplate', 'Parts.Uom',
    'Quality.ChargeToParty', 'Quality.DefectCode', 'Quality.DispositionCode', 'Quality.HoldTypeCode',
    'Quality.InspectionResultCode', 'Quality.QualitySpec', 'Quality.QualitySpecAttribute',
    'Quality.QualitySpecVersion', 'Quality.SampleTriggerCode',
    'Tools.DieRank', 'Tools.DieRankCompatibility', 'Tools.Tool', 'Tools.ToolAssignment', 'Tools.ToolAttribute',
    'Tools.ToolAttributeDefinition', 'Tools.ToolCavity', 'Tools.ToolCavityStatusCode', 'Tools.ToolStatusCode',
    'Tools.ToolType',
    'Workorder.DieCastCounterAnchorReason', 'Workorder.DieCastVarianceReason', 'Workorder.OperationStatus',
    'Workorder.ScrapSource', 'Workorder.WorkOrderStatus', 'Workorder.WorkOrderType'
)

# Columns never written in clear. Key = Schema.Table, value = column names.
$Redact = @{
    'Lots.AimPoolConfig' = @('AimPathToken')
}

# ---- Helpers ----------------------------------------------------------------
function Quote-Ident([string]$name) { '[' + $name.Replace(']', ']]') + ']' }

function Invoke-Query([System.Data.SqlClient.SqlConnection]$conn, [string]$sql) {
    $cmd = $conn.CreateCommand()
    $cmd.CommandText    = $sql
    $cmd.CommandTimeout = 120
    $dt = New-Object System.Data.DataTable
    $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
    [void]$da.Fill($dt)
    , $dt
}

function Invoke-JsonQuery([System.Data.SqlClient.SqlConnection]$conn, [string]$sql) {
    # FOR JSON streams its result as several ~2 KB rows; concatenate them.
    $cmd = $conn.CreateCommand()
    $cmd.CommandText    = $sql
    $cmd.CommandTimeout = 120
    $sb = New-Object System.Text.StringBuilder
    $rdr = $cmd.ExecuteReader()
    try { while ($rdr.Read()) { [void]$sb.Append($rdr.GetString(0)) } }
    finally { $rdr.Close() }
    if ($sb.Length -eq 0) { return '[]' }      # FOR JSON on an empty table returns no rows
    $sb.ToString()
}

function Format-JsonArrayRows([string]$json) {
    # One top-level array element per line, so the files diff and read cleanly.
    # String-aware: a comma or brace inside a value is never touched.
    $sb = New-Object System.Text.StringBuilder ($json.Length + 1024)
    $depth = 0; $inStr = $false; $esc = $false
    foreach ($c in $json.ToCharArray()) {
        if ($inStr) {
            [void]$sb.Append($c)
            if ($esc) { $esc = $false }
            elseif ($c -eq '\') { $esc = $true }
            elseif ($c -eq '"') { $inStr = $false }
            continue
        }
        switch ($c) {
            '"' { $inStr = $true; [void]$sb.Append($c) }
            { $_ -eq '[' -or $_ -eq '{' } {
                $depth++; [void]$sb.Append($c)
                if ($depth -eq 1) { [void]$sb.Append("`n  ") }
            }
            { $_ -eq ']' -or $_ -eq '}' } {
                if ($depth -eq 1) { [void]$sb.Append("`n") }
                $depth--; [void]$sb.Append($c)
            }
            ',' { [void]$sb.Append($c); if ($depth -eq 1) { [void]$sb.Append("`n  ") } }
            default { [void]$sb.Append($c) }
        }
    }
    $sb.ToString() -replace "\[\n  \n\]", "[]"
}

$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
function Write-Utf8([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, $Utf8NoBom) }

# ---- Connect ----------------------------------------------------------------
$stamp  = Get-Date -Format "yyyyMMdd_HHmm"
$OutDir = if ($OutputDirectory -ne "") { $OutputDirectory } else { Join-Path $RepoRoot "sql\scratch\_prod_config_$stamp" }
if ((Test-Path $OutDir) -and (Get-ChildItem $OutDir -Force | Select-Object -First 1)) {
    throw "Output directory is not empty: $OutDir"
}
New-Item -ItemType Directory -Force $OutDir | Out-Null

$csb = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
$csb["Data Source"]              = $ServerInstance
$csb["Initial Catalog"]          = $DatabaseName
$csb["Application Name"]         = "MPP Export-ProdConfig"
$csb["ApplicationIntent"]        = "ReadOnly"
$csb["Encrypt"]                  = $true
$csb["TrustServerCertificate"]   = $true      # self-signed server cert, as sqlcmd -C in the deploy scripts
$csb["Connect Timeout"]          = 15

$credential = $null
if ($Username -ne "") {
    if ($env:SQLCMDPASSWORD) {
        $sec = ConvertTo-SecureString $env:SQLCMDPASSWORD -AsPlainText -Force
    } else {
        $sec = Read-Host "SQL password for '$Username' on $ServerInstance" -AsSecureString
    }
    if ($sec.Length -eq 0) { throw "No password entered." }
    $sec.MakeReadOnly()
    $credential = New-Object System.Data.SqlClient.SqlCredential($Username, $sec)
} else {
    $csb["Integrated Security"] = $true
}

$conn = New-Object System.Data.SqlClient.SqlConnection($csb.ConnectionString, $credential)

Write-Host ""
Write-Host "  Config export  <-  $DatabaseName on $ServerInstance  (read-only)" -ForegroundColor Cyan
Write-Host "  Output: $OutDir" -ForegroundColor DarkGray
Write-Host ""

$failures = @()
try {
    $conn.Open()
    $capturedUtc = (Invoke-Query $conn "SELECT CONVERT(NVARCHAR(30), SYSUTCDATETIME(), 126) AS Utc, @@SERVERNAME AS ServerName, DB_NAME() AS Db").Rows[0]

    $migration = $null
    try {
        $mv = Invoke-Query $conn "SELECT TOP (1) * FROM dbo.SchemaVersion ORDER BY MigrationId DESC"
        if ($mv.Rows.Count -gt 0) {
            $migration = [ordered]@{}
            foreach ($col in $mv.Columns) { $migration[$col.ColumnName] = "$($mv.Rows[0][$col.ColumnName])" }
        }
    } catch { Write-Host "  (could not read dbo.SchemaVersion: $($_.Exception.Message))" -ForegroundColor Yellow }

    # Every user table with its row count.
    $tables = Invoke-Query $conn @"
SELECT  s.name AS SchemaName, t.name AS TableName, t.object_id AS ObjectId,
        ISNULL((SELECT SUM(p.rows) FROM sys.partitions p
                WHERE p.object_id = t.object_id AND p.index_id IN (0, 1)), 0) AS RowCnt
FROM    sys.tables t
JOIN    sys.schemas s ON s.schema_id = t.schema_id
WHERE   t.is_ms_shipped = 0
ORDER BY s.name, t.name;
"@

    $columns = Invoke-Query $conn @"
SELECT  c.object_id AS ObjectId, c.column_id AS ColumnId, c.name AS ColumnName,
        TYPE_NAME(c.user_type_id) AS TypeName, c.max_length AS MaxLength,
        c.precision AS Prec, c.scale AS Scale, c.is_nullable AS IsNullable,
        c.is_identity AS IsIdentity, c.is_computed AS IsComputed
FROM    sys.columns c
JOIN    sys.tables t ON t.object_id = c.object_id
WHERE   t.is_ms_shipped = 0
ORDER BY c.object_id, c.column_id;
"@

    $fks = Invoke-Query $conn @"
SELECT  fk.name AS FkName,
        OBJECT_SCHEMA_NAME(fk.parent_object_id) + '.' + OBJECT_NAME(fk.parent_object_id) AS FromTable,
        pc.name AS FromColumn,
        OBJECT_SCHEMA_NAME(fk.referenced_object_id) + '.' + OBJECT_NAME(fk.referenced_object_id) AS ToTable,
        rc.name AS ToColumn
FROM    sys.foreign_keys fk
JOIN    sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
JOIN    sys.columns pc ON pc.object_id = fkc.parent_object_id     AND pc.column_id = fkc.parent_column_id
JOIN    sys.columns rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id
ORDER BY FromTable, fk.name, fkc.constraint_column_id;
"@

    $inventory = @()
    $extracted = @()
    $schemaDoc = [ordered]@{ tables = [ordered]@{}; foreignKeys = @() }

    foreach ($t in $tables.Rows) {
        $full    = "$($t.SchemaName).$($t.TableName)"
        $rowCnt  = [long]$t.RowCnt
        $known   = $KnownConfig -contains $full
        $status  = $null

        if ($ExcludedSchemas -contains $t.SchemaName) { $status = "skipped: test schema" }
        elseif ($Transactional -contains $full)       { $status = "skipped: transactional" }
        elseif (-not $known -and $rowCnt -gt $LargeTableRows) {
            $status = "SKIPPED: unclassified and $rowCnt rows (> $LargeTableRows) -- classify it"
            Write-Host ("  ! {0,-45} {1}" -f $full, $status) -ForegroundColor Yellow
        }

        if ($status) {
            $inventory += [pscustomobject]@{ Table = $full; SourceRows = $rowCnt; ExtractedRows = ""; Status = $status }
            continue
        }

        $cols = @($columns.Select("ObjectId = $($t.ObjectId)", "ColumnId ASC"))
        $redactCols = if ($Redact.ContainsKey($full)) { $Redact[$full] } else { @() }
        $selectList = ($cols | ForEach-Object {
            $q = Quote-Ident $_.ColumnName
            if ($redactCols -contains $_.ColumnName) { "CASE WHEN $q IS NULL THEN NULL ELSE N'<redacted>' END AS $q" }
            else { $q }
        }) -join ", "
        # CSV only: dates as ISO text with milliseconds, not the machine's locale format.
        $csvSelectList = ($cols | ForEach-Object {
            $q = Quote-Ident $_.ColumnName
            if ($redactCols -contains $_.ColumnName) { "CASE WHEN $q IS NULL THEN NULL ELSE N'<redacted>' END AS $q" }
            elseif (@('datetime2','datetime','smalldatetime','date','time','datetimeoffset') -contains $_.TypeName) { "CONVERT(NVARCHAR(40), $q, 126) AS $q" }
            else { $q }
        }) -join ", "
        $from = "$(Quote-Ident $t.SchemaName).$(Quote-Ident $t.TableName)"

        try {
            $json = Invoke-JsonQuery $conn "SELECT $selectList FROM $from ORDER BY 1 FOR JSON PATH, INCLUDE_NULL_VALUES;"
            Write-Utf8 (Join-Path $OutDir "$full.json") ((Format-JsonArrayRows $json) + "`n")

            $dt = Invoke-Query $conn "SELECT $csvSelectList FROM $from ORDER BY 1;"
            $colNames = @($dt.Columns | ForEach-Object { $_.ColumnName })
            $csvPath  = Join-Path $OutDir "$full.csv"
            if ($dt.Rows.Count -gt 0) {
                $dt.Rows | Select-Object -Property $colNames | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
            } else {
                Write-Utf8 $csvPath ((($colNames | ForEach-Object { '"' + $_ + '"' }) -join ",") + "`r`n")
            }

            $n = $dt.Rows.Count
            $status = if ($known) { "extracted" } else { "extracted (UNCLASSIFIED -- config or transactional?)" }
            if ($redactCols.Count -gt 0) { $status += "; redacted: $($redactCols -join ', ')" }
            $inventory += [pscustomobject]@{ Table = $full; SourceRows = $rowCnt; ExtractedRows = $n; Status = $status }
            $extracted += [ordered]@{ table = $full; rows = $n; redacted = @($redactCols) }

            $schemaDoc.tables[$full] = @($cols | ForEach-Object {
                [ordered]@{
                    name       = $_.ColumnName
                    type       = $_.TypeName
                    maxLength  = [int]$_.MaxLength
                    precision  = [int]$_.Prec
                    scale      = [int]$_.Scale
                    nullable   = [bool]$_.IsNullable
                    identity   = [bool]$_.IsIdentity
                    computed   = [bool]$_.IsComputed
                }
            })

            $color = if ($known) { "Gray" } else { "Yellow" }
            Write-Host ("  {0,-45} {1,7} rows{2}" -f $full, $n, $(if ($known) { "" } else { "   (unclassified)" })) -ForegroundColor $color
        } catch {
            $msg = $_.Exception.Message
            $failures += "$full : $msg"
            $inventory += [pscustomobject]@{ Table = $full; SourceRows = $rowCnt; ExtractedRows = ""; Status = "FAILED: $msg" }
            Write-Host ("  X {0,-43} FAILED: {1}" -f $full, $msg) -ForegroundColor Red
        }
    }

    $extractedNames = @($extracted | ForEach-Object { $_.table })
    $schemaDoc.foreignKeys = @($fks.Rows | Where-Object { $extractedNames -contains $_.FromTable } | ForEach-Object {
        [ordered]@{ name = $_.FkName; from = "$($_.FromTable).$($_.FromColumn)"; to = "$($_.ToTable).$($_.ToColumn)" }
    })

    Write-Utf8 (Join-Path $OutDir "_schema.json") (($schemaDoc | ConvertTo-Json -Depth 8) + "`n")
    $inventory | Export-Csv -Path (Join-Path $OutDir "_inventory.csv") -NoTypeInformation -Encoding UTF8

    $manifest = [ordered]@{
        purpose          = "Read-only configuration snapshot for syncing Dev. Not a seed; do not commit."
        sourceServer     = $ServerInstance
        serverName       = "$($capturedUtc.ServerName)"
        database         = "$($capturedUtc.Db)"
        capturedAtUtc    = "$($capturedUtc.Utc)"
        capturedBy       = $env:USERNAME
        latestMigration  = $migration
        tablesExtracted  = $extracted.Count
        tablesSkipped    = @($inventory | Where-Object { $_.Status -like "skipped*" -or $_.Status -like "SKIPPED*" }).Count
        failures         = @($failures)
        tables           = @($extracted)
    }
    Write-Utf8 (Join-Path $OutDir "_manifest.json") (($manifest | ConvertTo-Json -Depth 6) + "`n")
}
finally {
    if ($conn.State -ne 'Closed') { $conn.Close() }
}

Write-Host ""
Write-Host ("  {0} tables extracted, {1} skipped, {2} failed." -f $extracted.Count,
    @($inventory | Where-Object { $_.Status -like "skipped*" -or $_.Status -like "SKIPPED*" }).Count, $failures.Count) -ForegroundColor Cyan
if ($migration) { Write-Host "  Source migration level: $($migration['MigrationId'])" -ForegroundColor DarkGray }
Write-Host "  Saved to $OutDir" -ForegroundColor DarkGray
Write-Host ""
if ($failures.Count -gt 0) { exit 1 }
