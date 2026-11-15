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
    . (Join-Path $PSScriptRoot 'lib/OrchestrationExternalExecutors.ps1')
    $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $fixtureRepo = Join-Path $script:Temp 'fixed-repo'
    [void](New-Item -ItemType Directory -Path $fixtureRepo)
    $registry = Get-Content -Raw (Join-Path $repoRoot 'source/registry/external-executors.json') | ConvertFrom-Json
    foreach ($executor in $registry.executors) { $executor.fixed.repo = $fixtureRepo }
    $registryPath = Join-Path $script:Temp 'registry.json'
    $grantsPath = Join-Path $script:Temp 'grants.json'
    $registry | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $registryPath -Encoding UTF8
    Copy-Item (Join-Path $repoRoot 'source/registry/execution-grants.json') $grantsPath
    $fixtureScripts = Join-Path $script:Temp 'fixture/scripts/v3'
    $fixtureLib = Join-Path $fixtureScripts 'lib'
    $fixtureRegistryDir = Join-Path $script:Temp 'fixture/source/registry'
    [void](New-Item -ItemType Directory -Path $fixtureLib -Force)
    [void](New-Item -ItemType Directory -Path $fixtureRegistryDir -Force)
    Copy-Item (Join-Path $PSScriptRoot 'external-action-exec.ps1') $fixtureScripts
    Copy-Item (Join-Path $PSScriptRoot 'lib/OrchestrationExternalExecutors.ps1') $fixtureLib
    Copy-Item (Join-Path $PSScriptRoot 'lib/OrchestrationExternalExecutorRegistry.ps1') $fixtureLib
    Copy-Item (Join-Path $PSScriptRoot 'lib/OrchestrationTaskKernel.ps1') $fixtureLib
    Copy-Item $registryPath (Join-Path $fixtureRegistryDir 'external-executors.json')
    Copy-Item $grantsPath (Join-Path $fixtureRegistryDir 'execution-grants.json')
    $script:CliPath = Join-Path $fixtureScripts 'external-action-exec.ps1'
    $fixtureRegistry = Get-Content -Raw $registryPath | ConvertFrom-Json
    Assert-ExternalExec (@($fixtureRegistry.executors | Where-Object { $_.fixed.repo -eq $fixtureRepo }).Count -eq 2 -and
        @($fixtureRegistry.executors | Where-Object { $_.fixed.repo -eq 'D:\projetos\telegran' }).Count -eq 0) 'fixture registry is isolated from real Telegran checkout'
    function Test-DirectRequest([string]$Json,[string]$Task='task-test') {
        Test-OcExternalActionRequest -ExecutorId 'telegran.fetch-one-message' -TaskId $Task -RequestJson $Json -RegistryPath $registryPath -GrantsPath $grantsPath
    }
    $directFileCountBefore = @(Get-ChildItem -LiteralPath $script:Temp -Recurse -File).Count
    $r=Test-DirectRequest '{"course":"maquina-de-prospeccao","message_id":7}'
    Assert-ExternalExec ($r.valid) 'direct valid request'
    $r=Test-DirectRequest '{"course":"maquina-de-prospeccao","message_id":7}' '../bad'
    Assert-ExternalExec ($r.error -eq 'INVALID_TASK_ID') 'direct invalid task id'
    foreach ($case in @(
        @('unknown key','{"course":"maquina-de-prospeccao","message_id":7,"extra":1}','UNKNOWN_REQUEST_KEY'),
        @('missing key','{"course":"maquina-de-prospeccao"}','MISSING_REQUEST_KEY'),
        @('case-variant key','{"Course":"maquina-de-prospeccao","message_id":7}','UNKNOWN_REQUEST_KEY'),
        @('exact duplicate','{"course":"maquina-de-prospeccao","message_id":7,"message_id":8}','DUPLICATE_REQUEST_KEY'),
        @('escaped duplicate','{"course":"maquina-de-prospeccao","message_id":7,"message\u005fid":8}','DUPLICATE_REQUEST_KEY'),
        @('case-folded duplicate','{"course":"maquina-de-prospeccao","message_id":7,"MESSAGE_ID":8}','UNKNOWN_REQUEST_KEY'),
        @('case-folded key is unknown, not exact duplicate','{"course":"maquina-de-prospeccao","message_id":7,"Message_id":8}','UNKNOWN_REQUEST_KEY'),
        @('nested duplicate','{"course":"maquina-de-prospeccao","message_id":7,"x":{"a":1,"a":2}}','DUPLICATE_REQUEST_KEY'),
        @('single-quoted duplicate malformed',"{'course':'maquina-de-prospeccao','message_id':7,'message_id':8}",'MALFORMED_REQUEST_JSON'),
        @('block comment with quote duplicate malformed','{"course":"maquina-de-prospeccao","message_id":7 /* " */,"message_id":8}','MALFORMED_REQUEST_JSON'),
        @('line comment duplicate malformed',("{`"course`":`"maquina-de-prospeccao`",`"message_id`":7 // comment`n,`"message_id`":8}"),'MALFORMED_REQUEST_JSON'),
        @('malformed after duplicate','{"course":"maquina-de-prospeccao","message_id":7,"message_id":8} trailing','MALFORMED_REQUEST_JSON'),
        @('malformed escaped key','{"course":"maquina-de-prospeccao","message_id\uZZZZ":7}','MALFORMED_REQUEST_JSON'),
        @('unquoted course and duplicate message id','{course:"maquina-de-prospeccao",message_id:7,message_id:8}','MALFORMED_REQUEST_JSON'),
        @('quoted course with unquoted duplicate message id','{"course":"x","message_id":7,message_id:8}','MALFORMED_REQUEST_JSON'),
        @('unquoted true property name','{true:1}','MALFORMED_REQUEST_JSON'),
        @('quoted course with unquoted message id','{"course":"maquina-de-prospeccao",message_id:7}','MALFORMED_REQUEST_JSON'),
        @('unquoted numeric property name','{"course":"maquina-de-prospeccao","message_id":7,123:8}','MALFORMED_REQUEST_JSON'),
        @('unquoted case-variant property name','{"course":"maquina-de-prospeccao","message_id":7,Message_Id:8}','MALFORMED_REQUEST_JSON'),
        @('nested unquoted property name','{"course":"maquina-de-prospeccao","message_id":7,"extra":{true:1}}','MALFORMED_REQUEST_JSON'),
        @('unquoted valid key','{"course":"maquina-de-prospeccao","message_id":7,other:1}','MALFORMED_REQUEST_JSON'),
        @('unquoted duplicate','{"course":"maquina-de-prospeccao",message_id:7,message_id:8}','MALFORMED_REQUEST_JSON'),
        @('mixed quoted and unquoted duplicate','{"course":"maquina-de-prospeccao","message_id":7,message_id:8}','MALFORMED_REQUEST_JSON'),
        @('trailing comma','{"course":"maquina-de-prospeccao","message_id":7,}','MALFORMED_REQUEST_JSON'),
        @('enum case','{"course":"Maquina-de-prospeccao","message_id":7}','INVALID_ENUM'),
        @('enum numeric type','{"course":1,"message_id":7}','INVALID_ENUM'),
        @('int coercion','{"course":"maquina-de-prospeccao","message_id":7.0}','INVALID_INT'),
        @('int range','{"course":"maquina-de-prospeccao","message_id":1000001}','INVALID_INT'),
        @('string int','{"course":"maquina-de-prospeccao","message_id":"7"}','INVALID_INT'),
        @('zero int','{"course":"maquina-de-prospeccao","message_id":0}','INVALID_INT'),
        @('array int','{"course":"maquina-de-prospeccao","message_id":[7]}','INVALID_INT'),
        @('array request','[{"course":"maquina-de-prospeccao","message_id":7}]','REQUEST_OBJECT_REQUIRED'),
        @('number array request','[7]','REQUEST_OBJECT_REQUIRED'),
        @('empty array request','[]','REQUEST_OBJECT_REQUIRED'),
        @('array-wrapped duplicate','[{"course":"maquina-de-prospeccao","message_id":7,"message_id":8}]','REQUEST_OBJECT_REQUIRED'),
        @('string request','"text"','REQUEST_OBJECT_REQUIRED'),
        @('unknown executor','{"course":"maquina-de-prospeccao","message_id":7}','UNKNOWN_EXECUTOR'),
        @('oversized request',( '{"course":"maquina-de-prospeccao","message_id":7,"pad":"' + ('x' * 8200) + '"}' ),'REQUEST_TOO_LARGE'),
        @('malformed json','{"course":','MALFORMED_REQUEST_JSON')
    )) {
        if ($case[0] -eq 'unknown executor') {
            $r=Test-OcExternalActionRequest -ExecutorId 'no.such.executor' -TaskId 'task-test' -RequestJson $case[1] -RegistryPath $registryPath -GrantsPath $grantsPath
        } else { $r=Test-DirectRequest $case[1] }
        Assert-ExternalExec ($r.error -eq $case[2]) ('direct '+$case[0]) ([pscustomobject]@{ExitCode=0;Stdout='error='+$r.error;Stderr=''})
    }
    foreach ($repoCase in @(
        @('relative','relative/path'),
        @('rooted missing',(Join-Path $script:Temp 'missing-root')),
        @('traversal',(Join-Path $fixtureRepo '..\outside'))
    )) {
        $badRegistry = Get-Content -Raw $registryPath | ConvertFrom-Json
        $badRegistry.executors[0].fixed.repo = $repoCase[1]
        $badRegistry | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $registryPath -Encoding UTF8
        $r=Test-DirectRequest '{"course":"maquina-de-prospeccao","message_id":7}'
        Assert-ExternalExec ($r.error -eq 'REGISTRY_INVALID') ('registry rejects '+$repoCase[0]+' fixed repo')
    }
    $stringRegistry = Get-Content -Raw (Join-Path $repoRoot 'source/registry/external-executors.json') | ConvertFrom-Json
    foreach ($executor in $stringRegistry.executors) {
        $executor.fixed.repo = $fixtureRepo
        $executor.request_schema = [pscustomobject]@{ label=[pscustomobject]@{ type='string'; regex='^.*$'; max_length=32 } }
        $executor.target_template = 'telegran:{label}'
    }
    $stringRegistry | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $registryPath -Encoding UTF8
    $r=Test-OcExternalActionRequest -ExecutorId 'telegran.fetch-one-message' -TaskId 'task-test' -RequestJson '{"label":"item\n"}' -RegistryPath $registryPath -GrantsPath $grantsPath
    Assert-ExternalExec ($r.error -eq 'INVALID_STRING') 'string schema rejects trailing newline'
    $r=Test-OcExternalActionRequest -ExecutorId 'telegran.fetch-one-message' -TaskId 'task-test' -RequestJson '{"label":"path/a /* comment-like text */"}' -RegistryPath $registryPath -GrantsPath $grantsPath
    Assert-ExternalExec ($r.valid) 'valid slash and comment-like string accepted'
    $registry = Get-Content -Raw (Join-Path $repoRoot 'source/registry/external-executors.json') | ConvertFrom-Json
    foreach ($executor in $registry.executors) { $executor.fixed.repo = $fixtureRepo }
    $registry | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $registryPath -Encoding UTF8
    $oldGrants = '{"version":1,"grants":["fs.read"]}'
    Set-Content -LiteralPath $grantsPath -Value $oldGrants -Encoding UTF8
    $r=Test-DirectRequest '{"course":"maquina-de-prospeccao","message_id":7}'
    Assert-ExternalExec ($r.error -eq 'REGISTRY_INVALID') 'old grants deny absent external grant'
    Set-Content -LiteralPath $grantsPath -Value (Get-Content -Raw (Join-Path $repoRoot 'source/registry/execution-grants.json')) -Encoding UTF8
    Set-Content -LiteralPath $registryPath -Value '{' -Encoding UTF8
    $r=Test-DirectRequest '{"course":"maquina-de-prospeccao","message_id":7}'
    Assert-ExternalExec ($r.error -eq 'REGISTRY_INVALID') 'malformed registry rejected'
    $directFileCountAfter = @(Get-ChildItem -LiteralPath $script:Temp -Recurse -File).Count
    Assert-ExternalExec ($directFileCountAfter -eq $directFileCountBefore) 'direct validator creates no helper side effects'

    $args = '-NoProfile -ExecutionPolicy Bypass -File ' + (Quote-Arg $script:CliPath)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$script:HostExe; $psi.Arguments=$args; $psi.UseShellExecute=$false
    $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
    $p=New-Object Diagnostics.Process; $p.StartInfo=$psi; [void]$p.Start()
    $usageOut=$p.StandardOutput.ReadToEnd(); $usageErr=$p.StandardError.ReadToEnd(); $p.WaitForExit()
    $usageJson=$null; try {$usageJson=$usageOut.Trim() | ConvertFrom-Json} catch {}
    Assert-ExternalExec ($p.ExitCode -eq 2 -and $usageJson.reasons -contains 'USAGE') 'usage without arguments' ([pscustomobject]@{ExitCode=$p.ExitCode;Stdout=$usageOut.Trim();Stderr=$usageErr.Trim()})

    $valid='{"course":"maquina-de-prospeccao","message_id":7}'
    $before=@(Get-ChildItem -LiteralPath $script:Temp -Recurse -File).Count
    $r=Invoke-ExternalCli @('-ExecutorId','telegran.fetch-one-message','-TaskId','task-test','-Request',$valid,'-DryRun','-Json')
    $after=@(Get-ChildItem -LiteralPath $script:Temp -Recurse -File).Count
    Assert-ExternalExec ($r.ExitCode -eq 0 -and $r.Json.outcome -eq 'WAIT' -and $r.Json.reasons -contains 'DRY_RUN_VALIDATED_NO_EFFECT' -and $before -eq $after) 'CLI dry-run validates without effects' $r
    $r=Invoke-ExternalCli @('-ExecutorId','telegran.fetch-one-message','-TaskId','task-test','-Request',$valid,'-Json')
    Assert-ExternalExec ($r.ExitCode -eq 3 -and $r.Json.reasons -contains 'EFFECTIVE_GRANT_SOURCE_UNAVAILABLE') 'CLI live path remains fail-closed' $r
    $r=Invoke-ExternalCli @('-ExecutorId','telegran.fetch-one-message','-TaskId','../escape','-Request',$valid,'-Json')
    Assert-ExternalExec ($r.ExitCode -eq 2 -and $r.Json.reasons -contains 'INVALID_TASK_ID') 'CLI rejects invalid task id' $r
    $r=Invoke-ExternalCli @('-ExecutorId','telegran.fetch-one-message','-TaskId','task-test','-Request',$valid,'-RegistryPath','evil.json','-Json')
    Assert-ExternalExec ($r.ExitCode -ne 0 -and $r.Stderr -match 'RegistryPath|parameter') 'registry override parameter unavailable' $r
} catch {
    Write-Host ('[FAIL] unexpected exception: ' + $_); $script:Failed++
} finally { Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ('EXTERNAL-ACTION-EXEC: ' + $script:Passed + ' passed / ' + $script:Failed + ' failed / skipped=' + $script:Skipped)
if ($script:Failed -gt 0) { exit 1 }
exit 0
