[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$script:Passed = 0; $script:Failed = 0; $script:Skipped = 0
$script:CliPath = Join-Path $PSScriptRoot 'external-action-exec.ps1'
$script:HostExe = [string](Get-Process -Id $PID).Path
$script:Temp = Join-Path ([IO.Path]::GetTempPath()) ('external-exec-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $script:Temp)
. (Join-Path $PSScriptRoot 'lib/OrchestrationTaskKernel.ps1')

function Assert-ExternalExec {
    param([bool]$Ok,[string]$Name)
    if ($Ok) { Write-Host ('[PASS] ' + $Name); $script:Passed++ }
    else { Write-Host ('[FAIL] ' + $Name + $(if($script:LastRun){' -- exit='+$script:LastRun.ExitCode+' stdout='+$script:LastRun.Stdout+' stderr='+$script:LastRun.Stderr}else{''})); $script:Failed++ }
}
function Skip-ExternalExec([string]$Name,[string]$Reason) {
    Write-Host ('[SKIP] ' + $Name + ' -- ' + $Reason)
    $script:Skipped++
}
function Quote-Arg([string]$s) { return '"' + $s.Replace('"','\"') + '"' }
function Invoke-ExternalCli([string[]]$CliArgs) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $script:HostExe
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File ' + (Quote-Arg $script:CliPath) + ' ' + (($CliArgs | ForEach-Object { Quote-Arg ([string]$_) }) -join ' ')
    if ($env:OC_TEST_DEBUG -eq '1') { Write-Host ('[DIAG] args='+$psi.Arguments) }
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = New-Object Diagnostics.Process; $p.StartInfo = $psi
    [void]$p.Start(); $out=$p.StandardOutput.ReadToEnd(); $err=$p.StandardError.ReadToEnd(); $p.WaitForExit()
    $json=$null; try { $json=$out.Trim() | ConvertFrom-Json } catch {}
    $script:LastRun=[pscustomobject]@{ ExitCode=[int]$p.ExitCode; Stdout=$out.Trim(); Stderr=$err.Trim(); Json=$json }
    return $script:LastRun
}
function New-TestTask([string]$Id,[string[]]$Grants,[string]$State='IMPLEMENTING',[string[]]$Environments=@('local')) {
    $dir=Join-Path $script:Temp ($Id+'-tasks'); [void](New-Item -ItemType Directory -Force -Path $dir)
    $flags=Join-Path $script:Temp 'flags.json'
    [IO.File]::WriteAllText($flags,'{"task_kernel":{"enabled":true,"shadow":false}}')
    $r=New-OrchestrationTask -TaskId $Id -Objective 'External executor test' -Actor 'planner' -Grants $Grants -EnvironmentAllowed $Environments -TasksDir $dir -FlagsPath $flags -TelemetryRoot $script:Temp
    $taskPath=Join-Path $dir ($Id+'.json')
    $record=Get-Content -Raw $taskPath | ConvertFrom-Json
    $record.state=$State
    [IO.File]::WriteAllText($taskPath,(ConvertTo-Json -InputObject $record -Depth 24),(New-Object Text.UTF8Encoding($false)))
    if ($State -eq 'BLOCKED') {
        $null=Block-OrchestrationTask -TaskId $Id -Actor 'planner' -Reason 'fixture' -ExpectedRevision $rev -TasksDir $dir -FlagsPath $flags -TelemetryRoot $script:Temp
    }
    return @{dir=$dir;flags=$flags}
}
function Write-Fixtures([string]$TestRoot,[string]$Risk='low',[int]$Timeout=5,[string]$Id='telegran.fetch-one-message') {
    [void](New-Item -ItemType Directory -Force -Path $TestRoot)
    $repo=Join-Path $TestRoot 'fake-repo'; $py=Join-Path $repo '.venv\Scripts\python.exe'
    [void](New-Item -ItemType Directory -Force -Path (Split-Path $py))
    if (-not (Test-Path $py)) { [IO.File]::Copy($script:FakeExe,$py) }
    $grantsPath=Join-Path $TestRoot 'grants.json'
    [IO.File]::WriteAllText($grantsPath,'{"grants":["external.telegran.fetch","external.telegran.learn"]}')
    $regPath=Join-Path $TestRoot 'registry.json'
    $reg=@{schema_version=1;executors=@(@{id=$Id;required_grants=@('external.telegran.fetch');risk=$Risk;request_schema=[ordered]@{course=@{type='enum';values=@('maquina-de-prospeccao')};message_id=@{type='int';min=1;max=1000000}};target_template='telegran:{course}:{message_id}';fixed=@{repo=$repo};timeout_seconds=$Timeout;idempotent=$true})}
    [IO.File]::WriteAllText($regPath,(ConvertTo-Json -InputObject $reg -Depth 12))
    return @{registry=$regPath;grants=$grantsPath;repo=$repo}
}
function Invoke-ForTask($Fixture,$Task,[string]$Request='{"message_id":7,"course":"maquina-de-prospeccao"}',[string]$ExecutorId='telegran.fetch-one-message',[switch]$DryRun,[string]$IntentRoot='',[string]$TaskId='task-test') {
    $requestPath=Join-Path $script:Temp ('request-'+[guid]::NewGuid().ToString('N')+'.json')
    [IO.File]::WriteAllText($requestPath,$Request)
    $a=@('-ExecutorId',$ExecutorId,'-TaskId',$TaskId,'-Request',$requestPath,'-TasksDir',$Task.dir,'-RegistryPath',$Fixture.registry,'-GrantsPath',$Fixture.grants,'-IntentRoot',$(if($IntentRoot){$IntentRoot}else{$script:Temp}),'-Json')
    if ($DryRun) {$a+= '-DryRun'}
    return Invoke-ExternalCli $a
}

try {
    # Compile a tiny fake python.exe: it writes test ordering evidence and a controlled output, never invokes Telegran.
    $script:FakeExe=Join-Path $script:Temp 'fake-python.exe'
    $source=@'
using System;
using System.IO;
using System.Threading;
class FakePython {
  static int Main() {
    string order=Environment.GetEnvironmentVariable("OC_TEST_ORDER");
    if (!String.IsNullOrEmpty(order)) {
      string intent=Environment.GetEnvironmentVariable("OC_EXTERNAL_INTENT_PATH");
      string phase=(!String.IsNullOrEmpty(intent) && File.Exists(intent)) ? "INTENT_BEFORE_EXEC" : "MISSING_INTENT";
      File.AppendAllText(order, File.Exists(order) ? "|"+phase : phase);
    }
    string mode=Environment.GetEnvironmentVariable("OC_TEST_MODE") ?? "";
    if (mode=="sleep") Thread.Sleep(10000);
    string text=Environment.GetEnvironmentVariable("OC_TEST_OUTPUT") ?? "fake-success";
    Console.WriteLine(text);
    return mode=="fail" ? 9 : 0;
  }
}
'@
    $compiled = $false
    try {
        Add-Type -TypeDefinition $source -OutputType ConsoleApplication -OutputAssembly $script:FakeExe -ErrorAction Stop
        $compiled = Test-Path -LiteralPath $script:FakeExe
    } catch {}
    if (-not $compiled) {
        $sourcePath = Join-Path $script:Temp 'fake-python.cs'
        [IO.File]::WriteAllText($sourcePath,$source,(New-Object Text.UTF8Encoding($false)))
        $candidates = @(
            (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
            (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
        )
        $csc = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($csc) {
            & $csc /nologo /target:exe ("/out:" + $script:FakeExe) $sourcePath
            $compiled = ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $script:FakeExe))
        }
    }
    if (-not $compiled) {
        $reason = 'fake executor compilation unavailable (Add-Type and .NET Framework csc.exe failed or were not found)'
        foreach ($name in @(
            'valid request executes with receipt','intent persisted before executor','replay does not execute again',
            'blocked task cannot use replay','dry run waits without executor','unknown executor rejected',
            'invalid request value rejected (1)','invalid request value rejected (2)','invalid request value rejected (3)',
            'invalid request value rejected (4)','invalid request value rejected (5)','request field command rejected',
            'request field path rejected','request field env rejected','request field limit rejected',
            'request field workspace rejected','request field project rejected','task without grant denied',
            'missing task denied','secret sentinel redacted from output and receipt','timeout reconciles after child kill'
        )) { Skip-ExternalExec $name $reason }
    } else {
    $fix=Write-Fixtures $script:Temp
    $task=New-TestTask 'task-test' @('external.telegran.fetch')
    $order=Join-Path $script:Temp 'order.txt'; $env:OC_TEST_ORDER=$order; $env:OC_TEST_MODE=''; $env:OC_TEST_OUTPUT='fake-success'
    $ok=Invoke-ForTask $fix $task
    Assert-ExternalExec ($ok.ExitCode -eq 0 -and $ok.Json.outcome -eq 'EXECUTED' -and $ok.Json.receipt.enforcement -eq 'SOFT_ADVISORY') 'valid request executes with receipt'
    $intent=Join-Path $script:Temp ('cache/runtime/external-intents/'+$ok.Json.idempotency_key+'.json')
    Assert-ExternalExec ((Test-Path $intent) -and ((Get-Content -Raw $order) -eq 'INTENT_BEFORE_EXEC')) 'intent persisted before executor'
    $again=Invoke-ForTask $fix $task
    Assert-ExternalExec ($again.ExitCode -eq 0 -and $again.Json.replayed -and (Get-Content -Raw $order) -eq 'INTENT_BEFORE_EXEC') 'replay does not execute again'
    $blocked=New-TestTask 'task-blocked' @('external.telegran.fetch') 'BLOCKED'
    $blockedReq=Join-Path $script:Temp 'blocked-request.json'; [IO.File]::WriteAllText($blockedReq,'{"course":"maquina-de-prospeccao","message_id":7}')
    $blockedRun=Invoke-ExternalCli @('-ExecutorId','telegran.fetch-one-message','-TaskId','task-blocked','-Request',$blockedReq,'-TasksDir',$blocked.dir,'-RegistryPath',$fix.registry,'-GrantsPath',$fix.grants,'-IntentRoot',$script:Temp,'-Json')
    Assert-ExternalExec ($blockedRun.ExitCode -eq 3 -and -not $blockedRun.Json.replayed) 'blocked task cannot use replay'
    Remove-Item -LiteralPath $order -Force -ErrorAction SilentlyContinue
    $dry=Invoke-ForTask $fix $task -DryRun
    Assert-ExternalExec ($dry.ExitCode -eq 0 -and $dry.Json.outcome -eq 'WAIT' -and -not (Test-Path $order)) 'dry run waits without executor'

    $unknown=Invoke-ForTask $fix $task -ExecutorId 'no.such.executor'
    Assert-ExternalExec ($unknown.ExitCode -eq 2 -and $unknown.Json.outcome -eq 'INVALID_REQUEST') 'unknown executor rejected'
    $badCases=@(
        '{"course":"maquina-de-prospeccao","message_id":"7"}','{"course":"maquina-de-prospeccao","message_id":0}',
        '{"course":"maquina-de-prospeccao","message_id":1000001}','{"course":"maquina-de-prospeccao","message_id":[7]}',
        '{"course":"elsewhere","message_id":7}'
    )
    foreach($req in $badCases){$x=Invoke-ForTask $fix $task -Request $req; Assert-ExternalExec ($x.ExitCode -eq 2) 'invalid request value rejected'}
    foreach($field in @('command','path','env','limit','workspace','project')) {
        $req='{"course":"maquina-de-prospeccao","message_id":7,"'+$field+'":"x"}'
        $x=Invoke-ForTask $fix $task -Request $req; Assert-ExternalExec ($x.ExitCode -eq 2) ('request field '+$field+' rejected')
    }
    $noGrant=New-TestTask 'task-no-grant' @()
    $noGrantReq=Join-Path $script:Temp 'no-grant-request.json'; [IO.File]::WriteAllText($noGrantReq,'{"course":"maquina-de-prospeccao","message_id":7}')
    Remove-Item -LiteralPath $order -Force -ErrorAction SilentlyContinue
    $x=Invoke-ExternalCli @('-ExecutorId','telegran.fetch-one-message','-TaskId','task-no-grant','-Request',$noGrantReq,'-TasksDir',$noGrant.dir,'-RegistryPath',$fix.registry,'-GrantsPath',$fix.grants,'-IntentRoot',$script:Temp,'-Json')
    Assert-ExternalExec ($x.ExitCode -eq 3 -and -not (Test-Path $order)) 'task without grant denied'
    $missing=Invoke-ExternalCli @('-ExecutorId','telegran.fetch-one-message','-TaskId','not-there','-Request',$noGrantReq,'-TasksDir',$task.dir,'-RegistryPath',$fix.registry,'-GrantsPath',$fix.grants,'-IntentRoot',$script:Temp,'-Json')
    Assert-ExternalExec ($missing.ExitCode -eq 3 -and $missing.Json.reasons -contains 'TASK_NOT_FOUND') 'missing task denied'

    $sentinel='API_TOKEN=SECRET_CANARY_92'
    $env:OC_TEST_OUTPUT=$sentinel
    $secretTask=New-TestTask 'task-secret' @('external.telegran.fetch')
    $secret=Invoke-ForTask $fix $secretTask -TaskId 'task-secret'
    $serialized=ConvertTo-Json -InputObject $secret.Json -Depth 20 -Compress
    Assert-ExternalExec ($secret.ExitCode -eq 0 -and $serialized -notmatch 'SECRET_CANARY_92') 'secret sentinel redacted from output and receipt'
    $timedFix=Write-Fixtures (Join-Path $script:Temp 'timeout') 'low' 1
    $timedTask=New-TestTask 'task-timeout' @('external.telegran.fetch')
    $env:OC_TEST_MODE='sleep'
    $timedReq=Join-Path $script:Temp 'timeout-request.json'; [IO.File]::WriteAllText($timedReq,'{"course":"maquina-de-prospeccao","message_id":7}')
    $timed=Invoke-ExternalCli @('-ExecutorId','telegran.fetch-one-message','-TaskId','task-timeout','-Request',$timedReq,'-TasksDir',$timedTask.dir,'-RegistryPath',$timedFix.registry,'-GrantsPath',$timedFix.grants,'-IntentRoot',$script:Temp,'-Json')
    Assert-ExternalExec ($timed.ExitCode -eq 7 -and $timed.Json.outcome -eq 'RECONCILE') 'timeout reconciles after child kill'
    $env:OC_TEST_ORDER=$null; $env:OC_TEST_MODE=$null; $env:OC_TEST_OUTPUT=$null
    }
} catch {
    Write-Host ('[FAIL] unexpected exception: ' + $_); $script:Failed++
} finally {
    $env:OC_TEST_ORDER=$null; $env:OC_TEST_MODE=$null; $env:OC_TEST_OUTPUT=$null
    Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ('EXTERNAL-ACTION-EXEC: ' + $script:Passed + ' passed / ' + $script:Failed + ' failed / skipped=' + $script:Skipped)
if ($script:Failed -gt 0) { exit 1 }
exit 0
