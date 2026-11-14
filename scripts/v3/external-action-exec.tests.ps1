[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$script:Passed = 0; $script:Failed = 0; $script:Skipped = 0
$script:CliPath = Join-Path $PSScriptRoot 'external-action-exec.ps1'
$script:HostExe = [string](Get-Process -Id $PID).Path
$script:Temp = Join-Path ([IO.Path]::GetTempPath()) ('external-exec-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $script:Temp)

function Quote-Arg([string]$s) { return '"' + $s.Replace('"','\"') + '"' }
function Invoke-ExternalCli([string[]]$CliArgs) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $script:HostExe
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File ' + (Quote-Arg $script:CliPath) + ' ' + (($CliArgs | ForEach-Object { Quote-Arg ([string]$_) }) -join ' ')
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = New-Object Diagnostics.Process; $p.StartInfo = $psi
    [void]$p.Start(); $out=$p.StandardOutput.ReadToEnd(); $err=$p.StandardError.ReadToEnd(); $p.WaitForExit()
    $json=$null; try { $json=$out.Trim() | ConvertFrom-Json } catch {}
    return [pscustomobject]@{ ExitCode=[int]$p.ExitCode; Stdout=$out.Trim(); Stderr=$err.Trim(); Json=$json }
}
function Assert-ExternalExec([bool]$Ok,[string]$Name,$Run=$null) {
    if ($Ok) { Write-Host ('[PASS] ' + $Name); $script:Passed++ }
    else {
        $detail = if ($Run) { ' -- exit='+$Run.ExitCode+' stdout='+$Run.Stdout+' stderr='+$Run.Stderr } else { '' }
        Write-Host ('[FAIL] ' + $Name + $detail); $script:Failed++
    }
}
function Invoke-Request([string]$Request,[string]$Executor='telegran.fetch-one-message',[string]$Task='task-test',[switch]$DryRun) {
    $args = @('-ExecutorId',$Executor,'-TaskId',$Task,'-Request',$Request,'-Json')
    if ($DryRun) { $args += '-DryRun' }
    return Invoke-ExternalCli $args
}

try {
    $args = '-NoProfile -ExecutionPolicy Bypass -File ' + (Quote-Arg $script:CliPath)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$script:HostExe; $psi.Arguments=$args; $psi.UseShellExecute=$false
    $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
    $p=New-Object Diagnostics.Process; $p.StartInfo=$psi; [void]$p.Start()
    $usageOut=$p.StandardOutput.ReadToEnd(); $usageErr=$p.StandardError.ReadToEnd(); $p.WaitForExit()
    $usageJson=$null; try {$usageJson=$usageOut.Trim() | ConvertFrom-Json} catch {}
    Assert-ExternalExec ($p.ExitCode -eq 2 -and $usageJson.reasons -contains 'USAGE') 'usage without arguments' ([pscustomobject]@{ExitCode=$p.ExitCode;Stdout=$usageOut.Trim();Stderr=$usageErr.Trim()})

    $valid='{"course":"maquina-de-prospeccao","message_id":7}'
    $unknown=Invoke-Request $valid 'no.such.executor'
    Assert-ExternalExec ($unknown.ExitCode -eq 2 -and $unknown.Json.reasons -contains 'UNKNOWN_EXECUTOR') 'unknown executor' $unknown
    foreach ($case in @(
        @('string int','{"course":"maquina-de-prospeccao","message_id":"7"}'),
        @('zero int','{"course":"maquina-de-prospeccao","message_id":0}'),
        @('above max int','{"course":"maquina-de-prospeccao","message_id":1000001}'),
        @('array int','{"course":"maquina-de-prospeccao","message_id":[7]}')
    )) {
        $r=Invoke-Request $case[1]
        Assert-ExternalExec ($r.ExitCode -eq 2 -and $r.Json.reasons -contains 'INVALID_INT') ($case[0]+' rejected') $r
    }
    $r=Invoke-Request '{"course":"elsewhere","message_id":7}'
    Assert-ExternalExec ($r.ExitCode -eq 2 -and $r.Json.reasons -contains 'INVALID_ENUM') 'invalid enum' $r
    $r=Invoke-Request '{"course":"maquina-de-prospeccao","message_id":7,"extra":1}'
    Assert-ExternalExec ($r.ExitCode -eq 2 -and $r.Json.reasons -contains 'UNKNOWN_REQUEST_KEY') 'extra field rejected' $r
    $r=Invoke-Request '{"course":"maquina-de-prospeccao"}'
    Assert-ExternalExec ($r.ExitCode -eq 2 -and $r.Json.reasons -contains 'MISSING_REQUEST_KEY') 'missing field rejected' $r
    $r=Invoke-Request '[7]'
    Assert-ExternalExec ($r.ExitCode -eq 2 -and $r.Json.reasons -contains 'REQUEST_OBJECT_REQUIRED') 'non-object request rejected' $r
    $r=Invoke-Request '[{"course":"maquina-de-prospeccao","message_id":7,"message_id":8}]'
    Assert-ExternalExec ($r.ExitCode -eq 2 -and $r.Json.reasons -contains 'REQUEST_OBJECT_REQUIRED') 'array-wrapped duplicate request rejected' $r
    $r=Invoke-Request '[]'
    Assert-ExternalExec ($r.ExitCode -eq 2 -and $r.Json.reasons -contains 'REQUEST_OBJECT_REQUIRED') 'empty array rejected' $r
    $r=Invoke-Request '"texto"'
    Assert-ExternalExec ($r.ExitCode -eq 2 -and $r.Json.reasons -contains 'REQUEST_OBJECT_REQUIRED') 'string request rejected' $r
    $r=Invoke-Request '{"a":'
    Assert-ExternalExec ($r.ExitCode -eq 2 -and $r.Json.reasons -contains 'MALFORMED_REQUEST_JSON') 'malformed JSON rejected with fixed reason' $r
    $r=Invoke-Request '{"course":"maquina-de-prospeccao","message_id":7,"message_id":8}'
    Assert-ExternalExec ($r.ExitCode -eq 2 -and $r.Json.reasons -contains 'DUPLICATE_REQUEST_KEY') 'duplicate exact key rejected' $r
    $r=Invoke-Request '{"course":"maquina-de-prospeccao","message_id":7,"Message_id":8}'
    Assert-ExternalExec ($r.ExitCode -eq 2 -and $r.Json.reasons -contains 'UNKNOWN_REQUEST_KEY') 'case variant key rejected' $r
    $r=Invoke-Request ('{"course":"maquina-de-prospeccao","message_id":7,"pad":"' + ('x' * 8200) + '"}')
    Assert-ExternalExec ($r.ExitCode -eq 2 -and $r.Json.reasons -contains 'REQUEST_TOO_LARGE') 'oversized request rejected' $r
    $before=@(Get-ChildItem -LiteralPath $script:Temp -Recurse -File).Count
    $r=Invoke-Request $valid -DryRun
    $after=@(Get-ChildItem -LiteralPath $script:Temp -Recurse -File).Count
    Assert-ExternalExec ($r.ExitCode -eq 0 -and $r.Json.outcome -eq 'WAIT' -and $r.Json.reasons -contains 'DRY_RUN_VALIDATED_NO_EFFECT' -and $before -eq $after) 'dry-run validates without files or authority verification' $r
    $r=Invoke-Request $valid
    Assert-ExternalExec ($r.ExitCode -eq 3 -and $r.Json.reasons -contains 'EFFECTIVE_GRANT_SOURCE_UNAVAILABLE') 'live execution fails closed' $r
    $r=Invoke-Request $valid -Task '../escape'
    Assert-ExternalExec ($r.ExitCode -eq 2 -and $r.Json.reasons -contains 'INVALID_TASK_ID') 'invalid task id rejected' $r
    $r=Invoke-ExternalCli @('-ExecutorId','telegran.fetch-one-message','-TaskId','task-test','-Request',$valid,'-RegistryPath','evil.json','-Json')
    Assert-ExternalExec ($r.ExitCode -ne 0 -and $r.Stderr -match 'RegistryPath|parameter') 'registry override parameter unavailable' $r
} catch {
    Write-Host ('[FAIL] unexpected exception: ' + $_); $script:Failed++
} finally { Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ('EXTERNAL-ACTION-EXEC: ' + $script:Passed + ' passed / ' + $script:Failed + ' failed / skipped=' + $script:Skipped)
if ($script:Failed -gt 0) { exit 1 }
exit 0
