[CmdletBinding()]
param(
    [string]$ExecutorId = '', [string]$TaskId = '', [string]$Request = '',
    [string]$TasksDir = '', [string]$RegistryPath = '', [string]$GrantsPath = '', [string]$IntentRoot = '',
    [switch]$DryRun, [switch]$Json
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $PSScriptRoot 'lib/OrchestrationExternalActionBoundary.ps1')
. (Join-Path $PSScriptRoot 'lib/OrchestrationExternalExecutorRegistry.ps1')
. (Join-Path $PSScriptRoot 'lib/OrchestrationExternalExecutors.ps1')
. (Join-Path $PSScriptRoot 'lib/OrchestrationExternalIntentStore.ps1')

function ConvertTo-OcCanonicalNode {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object -CaseSensitive)) { $o[[string]$key] = ConvertTo-OcCanonicalNode $Value[$key] }
        return ,$o
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $o = [ordered]@{}
        foreach ($key in @($Value.PSObject.Properties.Name | Sort-Object -CaseSensitive)) { $o[$key] = ConvertTo-OcCanonicalNode $Value.$key }
        return ,$o
    }
    if ($Value -is [System.Array]) { $a = @(); foreach ($item in $Value) { $a += ,(ConvertTo-OcCanonicalNode $item) }; return ,$a }
    return $Value
}
function Get-OcSha256Text([string]$Text) {
    $h = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','') } finally { $h.Dispose() }
}
function Get-OcExitForOutcome([string]$Outcome) {
    switch -Exact ($Outcome) {
        'EXECUTED' { return 0 } 'WAIT' { return 5 } 'NEEDS_USER_AUTHORITY' { return 3 }
        'POLICY_BLOCKED' { return 4 } 'REMEDIATE' { return 6 } 'RECONCILE' { return 7 }
        default { return 1 }
    }
}
function Write-OcResult($Value, [int]$ExitCode) {
    try { [Console]::Out.WriteLine((ConvertTo-Json -InputObject $Value -Depth 24 -Compress)) }
    catch { [Console]::Error.WriteLine('JSON serialization failed'); exit 1 }
    exit $ExitCode
}

$result = $null
try {
    if ([string]::IsNullOrWhiteSpace($ExecutorId) -or [string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($Request)) {
        $result = @{outcome='INVALID_REQUEST';reasons=@('USAGE');executor_id=$ExecutorId;task_id=$TaskId;idempotency_key=$null;intent_path=$null;receipt=$null;enforcement='SOFT_ADVISORY';replayed=$false;dry_run=[bool]$DryRun}
        Write-OcResult $result 2
    }
    if ([string]::IsNullOrWhiteSpace($TasksDir)) { $TasksDir = Join-Path $root 'cache/runtime/tasks' }
    if ([string]::IsNullOrWhiteSpace($RegistryPath)) { $RegistryPath = Join-Path $root 'source/registry/external-executors.json' }
    if ([string]::IsNullOrWhiteSpace($GrantsPath)) { $GrantsPath = Join-Path $root 'source/registry/execution-grants.json' }
    $impl = Get-OcExternalExecutors
    $registry = Import-OcExternalExecutorRegistry $RegistryPath $GrantsPath $impl
    $entry = @($registry.executors | Where-Object { $_.id -ceq $ExecutorId })
    if ($entry.Count -ne 1) { throw 'INVALID_REQUEST:UNKNOWN_EXECUTOR' }
    if (Test-Path -LiteralPath $Request -PathType Leaf) { $raw = Get-Content -Raw -LiteralPath $Request } else { $raw = $Request }
    $req = $raw | ConvertFrom-Json
    if ($null -eq $req -or $req -isnot [System.Management.Automation.PSCustomObject]) { throw 'INVALID_REQUEST:REQUEST_OBJECT_REQUIRED' }
    $schemaKeys = @($entry[0].request_schema.PSObject.Properties.Name)
    $requestKeys = @($req.PSObject.Properties.Name)
    foreach ($k in $requestKeys) { if ($k -notin $schemaKeys) { throw "INVALID_REQUEST:UNKNOWN_REQUEST_KEY:$k" } }
    foreach ($k in $schemaKeys) {
        if ($k -notin $requestKeys) { throw "INVALID_REQUEST:MISSING_REQUEST_KEY:$k" }
        $v = $req.$k; $s = $entry[0].request_schema.$k
        if ($s.type -eq 'enum' -and $v -notin @($s.values)) { throw "INVALID_REQUEST:INVALID_ENUM:$k" }
        if ($s.type -eq 'int') {
            $isIntegral = $null -ne $v -and (
                $v -is [System.SByte] -or $v -is [System.Byte] -or
                $v -is [System.Int16] -or $v -is [System.UInt16] -or
                $v -is [System.Int32] -or $v -is [System.UInt32] -or
                $v -is [System.Int64] -or $v -is [System.UInt64]
            )
            if (-not $isIntegral -or $v -lt $s.min -or $v -gt $s.max) { throw "INVALID_REQUEST:INVALID_INT:$k" }
        }
        if ($s.type -eq 'string' -and ($v -isnot [string] -or $v.Length -gt $s.max_length -or $v -cnotmatch $s.regex)) { throw "INVALID_REQUEST:INVALID_STRING:$k" }
    }
    $canonical = ConvertTo-Json -InputObject (ConvertTo-OcCanonicalNode $req) -Depth 24 -Compress
    $grantBytes = [IO.File]::ReadAllBytes((Resolve-Path $GrantsPath).Path)
    $registryBytes = [IO.File]::ReadAllBytes((Resolve-Path $RegistryPath).Path)
    $policyBytes = New-Object byte[] ($grantBytes.Length + $registryBytes.Length)
    [Array]::Copy($grantBytes,0,$policyBytes,0,$grantBytes.Length); [Array]::Copy($registryBytes,0,$policyBytes,$grantBytes.Length,$registryBytes.Length)
    $policyHash = [Security.Cryptography.SHA256]::Create()
    try { $policyDigest = [BitConverter]::ToString($policyHash.ComputeHash($policyBytes)).Replace('-','') } finally { $policyHash.Dispose() }
    $payloadHash = Get-OcSha256Text $canonical
    $key = Get-OcSha256Text ($ExecutorId + '|' + $TaskId + '|' + $payloadHash)
    $taskKernel = Join-Path $PSScriptRoot 'task-kernel.ps1'
    $hostExe = [string](Get-Process -Id $PID).Path
    $taskPsi = New-Object Diagnostics.ProcessStartInfo
    $taskPsi.FileName = $hostExe
    $taskPsi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $taskKernel + '" -Action get -TaskId "' + $TaskId + '" -TasksDir "' + $TasksDir + '"'
    $taskPsi.UseShellExecute = $false; $taskPsi.RedirectStandardOutput = $true; $taskPsi.RedirectStandardError = $true
    $taskProc = New-Object Diagnostics.Process; $taskProc.StartInfo = $taskPsi
    [void]$taskProc.Start(); $taskOutput = $taskProc.StandardOutput.ReadToEnd(); $null = $taskProc.StandardError.ReadToEnd(); $taskProc.WaitForExit()
    $taskExit = [int]$taskProc.ExitCode
    if ($taskExit -ne 0) {
        $result = @{outcome='NEEDS_USER_AUTHORITY';reasons=@('TASK_NOT_FOUND');executor_id=$ExecutorId;task_id=$TaskId;idempotency_key=$key;intent_path=$null;receipt=$null;enforcement='SOFT_ADVISORY';replayed=$false;dry_run=[bool]$DryRun}
        Write-OcResult $result 3
    }
    $task = $taskOutput | ConvertFrom-Json
    $taskGrants = @($task.grants)
    $missing = @($entry[0].required_grants | Where-Object { $_ -notin $taskGrants })
    $stateOk = [string]$task.state -in @('IMPLEMENTING','VALIDATING')
    $envOk = 'local' -in @($task.environment_authorization.allowed_environments)
    $authOk = ($null -ne $task.task_id -and $stateOk -and $envOk -and $missing.Count -eq 0)
    $checks = @(@{id='task-authority';status=$(if($authOk){'PASS'}else{'FAIL'});reason=$(if($authOk){''}else{'task authorization conditions failed'})})
    $authority = @{authorized=[bool]$authOk;grants=$taskGrants;environment=''}
    if (-not $authOk) {
        $reason = if ($missing.Count -gt 0) {'TASK_GRANT_MISSING'} elseif (-not $envOk) {'LOCAL_ENVIRONMENT_NOT_AUTHORIZED'} else {'TASK_STATE_NOT_AUTHORIZED'}
        $result = @{outcome='NEEDS_USER_AUTHORITY';reasons=@($reason);executor_id=$ExecutorId;task_id=$TaskId;idempotency_key=$key;intent_path=$null;receipt=$null;enforcement='SOFT_ADVISORY';replayed=$false;dry_run=[bool]$DryRun}
        Write-OcResult $result 3
    }
    $machine = [Environment]::MachineName+'|'+[Environment]::UserName+'|'+[IO.Path]::GetFullPath((Get-Location).Path)+'|'+$policyDigest
    $envId = Get-OcSha256Text $machine
    $authority.environment = $envId
    $receiptRoot = $root
    if (-not [string]::IsNullOrWhiteSpace($IntentRoot)) { $receiptRoot = $IntentRoot }
    elseif ($TasksDir -ne (Join-Path $root 'cache/runtime/tasks')) { $receiptRoot = Split-Path -Parent $TasksDir }
    $cached = Get-OcExternalReceipt $receiptRoot $key
    if (-not $DryRun -and $cached -and $cached.outcome -eq 'EXECUTED') {
        $result = @{outcome='EXECUTED';reasons=@('REPLAY');executor_id=$ExecutorId;task_id=$TaskId;idempotency_key=$key;intent_path=$null;receipt=$cached;enforcement='SOFT_ADVISORY';replayed=$true;dry_run=[bool]$DryRun}
        Write-OcResult $result 0
    }
    $target = [string]$entry[0].target_template
    foreach ($k in $schemaKeys) { $target = $target.Replace('{' + $k + '}',[string]$req.$k) }
    $intent = New-OcExternalIntent -Goal $TaskId -Action $ExecutorId -Target $target -Sha $policyDigest -Payload $canonical -IdempotencyKey $key -Grants $taskGrants -Environment $envId -PolicyDigest $policyDigest
    $intent | Add-Member -NotePropertyName request -NotePropertyValue $req
    $intent | Add-Member -NotePropertyName timeout_seconds -NotePropertyValue $entry[0].timeout_seconds
    $intent | Add-Member -NotePropertyName fixed -NotePropertyValue $entry[0].fixed
    $evidence = @{subject_sha=$policyDigest;policy_digest=$policyDigest;provenance='task-model'}
    $persist = New-OcExternalIntentPersistFn $receiptRoot
    $executor = if ($DryRun) { $null } else { $impl[$ExecutorId] }
    $priorIntentPath = $env:OC_EXTERNAL_INTENT_PATH
    $env:OC_EXTERNAL_INTENT_PATH = Join-Path $receiptRoot ('cache/runtime/external-intents/' + $key + '.json')
    $r = Invoke-OcExternalActionBoundary -PersistedIntent $intent -Authority $authority -Risk $entry[0].risk -Checks $checks -Evidence $evidence -Executor $executor -RequiredCheckIds @('task-authority') -PersistFn $persist
    if ($null -eq $priorIntentPath) { Remove-Item Env:OC_EXTERNAL_INTENT_PATH -ErrorAction SilentlyContinue } else { $env:OC_EXTERNAL_INTENT_PATH = $priorIntentPath }
    if ($r.reasons -contains 'PERSIST_FAILED' -and $script:OcExternalPersistError) { $r.reasons += ('STORE:' + $script:OcExternalPersistError) }
    if ($DryRun -and $r.outcome -eq 'WAIT') { $r.outcome = 'WAIT' }
    $outputHash = [string]$intent.output_hash
    $outputTail = [string]$intent.output_tail
    $receipt = $null
    if ($r.outcome -eq 'EXECUTED') {
        $receipt = @{idempotency_key=$key;outcome='EXECUTED';executor_id=$ExecutorId;task_id=$TaskId;target=$target;enforcement='SOFT_ADVISORY';output_hash=$outputHash;output_tail=$outputTail;receipt=$r.receipt}
        Save-OcExternalReceipt -Root $receiptRoot -Receipt $receipt
    }
    $result = @{outcome=$r.outcome;reasons=@($r.reasons);executor_id=$ExecutorId;task_id=$TaskId;idempotency_key=$key;intent_path=(Join-Path $receiptRoot "cache/runtime/external-intents/$key.json");receipt=$(if($receipt){$receipt}else{$r.receipt});enforcement='SOFT_ADVISORY';replayed=$false;dry_run=[bool]$DryRun}
    $exitCode = Get-OcExitForOutcome $r.outcome
    if ($DryRun -and $r.outcome -eq 'WAIT') { $exitCode = 0 }
    Write-OcResult $result $exitCode
}
catch {
    $msg = [string]$_.Exception.Message
    $invalid = $msg -match 'INVALID_REQUEST|registry|schema|executor implementation|Unknown executor|Invalid|Missing|placeholder|grant|timeout'
    $outcome = if ($invalid) {'INVALID_REQUEST'} else {'POLICY_BLOCKED'}
    $reason = if ($invalid) {'INVALID_REQUEST_OR_REGISTRY'} else {'POLICY_BLOCKED'}
    $result = @{outcome=$outcome;reasons=@($reason);executor_id=$ExecutorId;task_id=$TaskId;idempotency_key=$null;intent_path=$null;receipt=$null;enforcement='SOFT_ADVISORY';replayed=$false;dry_run=[bool]$DryRun}
    Write-OcResult $result $(if($invalid){2}else{4})
}
