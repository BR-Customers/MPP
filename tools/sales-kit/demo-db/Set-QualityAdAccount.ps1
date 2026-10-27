# Set-QualityAdAccount.ps1 -- point the sample Quality user (E. Novak, PIN 61030) in MPP_MES_Demo at
# the presenter's directory login, at capture time. A signed release or deviation then authenticates
# the presenter but is recorded under the sample name. The login is never written to a committed
# file: add it to banned_terms.txt / substitutions.json (MPP repo only) before capturing.
#
#   .\tools\sales-kit\demo-db\Set-QualityAdAccount.ps1 -Login <ad-login> [-ServerInstance localhost]
#
# Goes through Location.AppUser_Update (validation + audit), as SYS. MPP_MES_Demo only.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Login,
    [string]$ServerInstance = "localhost",
    [string]$DatabaseName   = "MPP_MES_Demo"
)
$ErrorActionPreference = "Stop"
if ($DatabaseName -ne "MPP_MES_Demo") { throw "Set-QualityAdAccount: only changes MPP_MES_Demo (got '$DatabaseName')." }
if ($Login -notmatch '^[A-Za-z0-9._\\-]{1,100}$') { throw "Set-QualityAdAccount: '$Login' does not look like a directory login." }

$sql = @"
SET NOCOUNT ON;
DECLARE @Id BIGINT = (SELECT Id FROM Location.AppUser WHERE Pin = N'61030' AND Initials = N'EN');
IF @Id IS NULL BEGIN RAISERROR('Sample Quality user EN not found: build with -WithQualityScenario first.', 16, 1); RETURN; END
DECLARE @r TABLE (Status BIT, Message NVARCHAR(500));
INSERT INTO @r EXEC Location.AppUser_Update @Id = @Id, @Initials = N'EN', @DisplayName = N'E. Novak', @Pin = N'61030',
    @AdAccount = N'$Login', @IgnitionRole = NULL, @AppUserId = 1;
IF NOT EXISTS (SELECT 1 FROM @r WHERE Status = 1) BEGIN DECLARE @m NVARCHAR(500) = (SELECT Message FROM @r); RAISERROR(@m, 16, 1); RETURN; END
SELECT N'PASS  sample Quality user EN signs in with the presenter''s login';
"@
$out = & sqlcmd -S $ServerInstance -E -C -I -b -d $DatabaseName -h -1 -W -Q $sql 2>&1
if ($LASTEXITCODE -ne 0) { $out | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }; throw "Set-QualityAdAccount failed" }
$out | Where-Object { $_ -match 'PASS' } | ForEach-Object { Write-Host "  $_" }
