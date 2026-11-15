[CmdletBinding()]
param(
    [string]$ExecutorId = '', [string]$TaskId = '', [string]$Request = '',
    [switch]$DryRun, [switch]$Json
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $PSScriptRoot 'lib/OrchestrationExternalExecutors.ps1')
if ([string]::IsNullOrWhiteSpace($ExecutorId) -or [string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($Request)) {
    $result = @{outcome='INVALID_REQUEST';reasons=@('USAGE');executor_id=$ExecutorId;task_id=$TaskId;idempotency_key=$null;intent_path=$null;receipt=$null;enforcement='SOFT_ADVISORY';replayed=$false;dry_run=[bool]$DryRun}
    $exitCode = 2
} else {
    $result = Invoke-OcExternalActionCli -ExecutorId $ExecutorId -TaskId $TaskId -Request $Request -RepoRoot $root -DryRun:$DryRun
    $exitCode = switch -Exact ($result.outcome) {
        'WAIT' { 0 } 'NEEDS_USER_AUTHORITY' { 3 } 'INVALID_REQUEST' { 2 } default { 1 }
    }
}
try { [Console]::Out.WriteLine((ConvertTo-Json -InputObject $result -Depth 24 -Compress)) }
catch { [Console]::Error.WriteLine('JSON serialization failed'); exit 1 }
exit $exitCode
