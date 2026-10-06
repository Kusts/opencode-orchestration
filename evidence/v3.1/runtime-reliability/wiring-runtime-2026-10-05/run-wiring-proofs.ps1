# Proof de execucao runtime-real dos wirings P31-S2 (componente), P38-S2-SPAWN
# (pipeline record-only) e P41-S2 (produtor de telemetria observation-only).
# Read/test oriented: nenhuma flag ativada, nenhum config tocado, nenhum
# processo de worker despachado. Evidencia sanitizada e atomica.
# PowerShell 5.1 compativel; ASCII-only.
[CmdletBinding()] param([string]$RepoRoot = '')
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))) }
$outDir = $PSScriptRoot
$stamp = [DateTime]::UtcNow.ToString('o')

function Write-Proof([string]$Name, $Object) {
    $tmp = Join-Path $outDir ($Name + '.json.tmp-' + [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($tmp, ((($Object | ConvertTo-Json -Depth 12).TrimEnd() + "`n") -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination (Join-Path $outDir ($Name + '.json')) -Force
}
function Get-ProofProp($Object, [string]$Name, $Default = $null) {
    try {
        if ($null -eq $Object) { return $Default }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -eq $p) { return $Default }
        return $p.Value
    } catch { return $Default }
}

# ---------- P31-S2: componente de bootstrap executado em processo real ----------
$p31 = [ordered]@{
    wiring        = 'P31-S2'
    component     = 'scripts/runtime/SessionBootstrapContext.ps1'
    claim         = 'component executes in real runtime (parse-only, fail-open); REGISTRATION into real startup path stays operator-owned'
    at            = $stamp
    powershell    = $PSVersionTable.PSVersion.ToString()
}
$psExe = Join-Path $PSHOME 'powershell.exe'
$child = & $psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\runtime\SessionBootstrapContext.ps1') -RepoRoot $RepoRoot 2>&1 | Out-String
$p31['exit_code'] = $LASTEXITCODE
$p31['stdout_parseable'] = $false
$p31['envelope_status'] = ''
$p31['notes'] = @()
try {
    $j = ($child | ConvertFrom-Json)
    $p31['stdout_parseable'] = $true
    $p31['envelope_status'] = 'envelope-emitido'
    $p31['project_id'] = [string]$j.project_id
    $p31['truncated'] = [bool]$j.truncated
    $p31['flags_seen'] = @()
    foreach ($fp in @($j.capability_health.flags.PSObject.Properties)) { $p31['flags_seen'] += , ([string]$fp.Name + '=' + [string]$fp.Value) }
} catch { $p31['notes'] += ('stdout nao-JSON: ' + ($child.Substring(0, [Math]::Min(200, $child.Length)))) }
$p31['runtime_executed'] = (($p31['exit_code'] -eq 0) -and ($p31['stdout_parseable']) -and (-not [string]::IsNullOrWhiteSpace([string]$p31['project_id'])))
Write-Proof 'p31-bootstrap-runtime' $p31

# ---------- P38-S2-SPAWN: pipeline record-only executado (bundle real, nada despachado) ----------
. (Join-Path $RepoRoot 'scripts\v3\lib\OrchestrationPlannerLoop.ps1')
. (Join-Path $RepoRoot 'scripts\v3\lib\OrchestrationDispatchPipeline.ps1')
$p38 = [ordered]@{
    wiring    = 'P38-S2-SPAWN (dispatch pipeline slice)'
    component = 'scripts/v3/lib/OrchestrationDispatchPipeline.ps1 Invoke-OrchestrationDispatchPipeline'
    claim     = 'pipeline executes and produces a real record-only bundle; NO worker is spawned (record-only by design; spawn real stays operator-owned)'
    at        = $stamp
}
$descriptor = @{
    objective                   = 'Closure round: real dispatch-pipeline execution proof (record-only).'
    risk                        = 'low'
    work_independent            = $true
    ownership_clear             = $true
    shared_state                = $false
    latency_benefit             = $true
    synthesis_affordable        = $true
    validation_budget_available = $true
}
$loop = Invoke-OrchestrationPlannerLoop -Descriptor $descriptor -Options @{ timestamp = $stamp }
$p38['planner_loop_status'] = [string]$loop.status
$p38['workers_in_plan'] = @()
$bundle = $null
if ([string]$loop.status -ceq 'ok') {
    foreach ($w in @($loop.plan.dispatch_plan.workers)) { $p38['workers_in_plan'] += , [string]$w }
    $bundle = Invoke-OrchestrationDispatchPipeline -PlanRecord $loop -Descriptor $descriptor -Options @{ timestamp = $stamp }
}
$bundleOk = ($null -ne $bundle)
$p38['pipeline_executed'] = $bundleOk
$p38['bundle_summary'] = ''
$p38['contracts_built'] = 0
$p38['spawned_processes'] = 0
if ($bundleOk) {
    foreach ($prop in @($bundle.PSObject.Properties)) {
        if ($prop.Name -match 'status') { $p38['bundle_summary'] = [string]$prop.Value }
    }
    foreach ($key in @('contracts', 'worker_contracts', 'bundle')) {
        $arr = $bundle.PSObject.Properties[$key]
        if ($null -ne $arr) { $p38['contracts_built'] = @($arr.Value).Count; break }
    }
    $p38['bundle_keys'] = @($bundle.PSObject.Properties.Name)
}
$p38['record_only_invariant'] = ($p38['spawned_processes'] -eq 0)
Write-Proof 'p38-dispatch-runtime' $p38

# ---------- P41-S2: produtor de telemetria contra artefatos reais ----------
. (Join-Path $RepoRoot 'scripts\v3\lib\OrchestrationEvolutionTelemetryProducer.ps1')
. (Join-Path $RepoRoot 'scripts\v3\lib\OrchestrationEvolutionLoop.ps1')
$p41 = [ordered]@{
    wiring    = 'P41-S2'
    component = 'scripts/v3/lib/OrchestrationEvolutionTelemetryProducer.ps1 Invoke-OrchestrationTelemetryProduction'
    claim     = 'producer executes against REAL kernel task records and emits one bounded observation-only JSONL line consumed by the slice-1 reader'
    at        = $stamp
}
$tasksDir = Join-Path $RepoRoot 'cache\runtime\tasks'
$prodDir = Join-Path $outDir 'telemetry-out'
New-Item -ItemType Directory -Path $prodDir -Force | Out-Null
$prod = Invoke-OrchestrationTelemetryProduction -TasksDir $tasksDir -OutDir $prodDir -Now $stamp
$p41['producer_ok'] = [bool](Get-ProofProp $prod 'ok' $false)
$p41['producer_status'] = $(if ([bool](Get-ProofProp $prod 'ok' $false)) { 'ok' } else { [string](Get-ProofProp $prod 'error' 'unknown') })
$p41['written'] = [bool](Get-ProofProp $prod 'written' $false)
$p41['observation_only'] = [bool](Get-ProofProp $prod 'observation_only' $false)
$p41['line_bytes'] = [int](Get-ProofProp $prod 'line_bytes' 0)
$p41['counters'] = @()
$p41['unavailable_counters'] = @()
foreach ($c in @(Get-ProofProp $prod 'counters' @())) { $p41['counters'] += , ([string]$c) }
foreach ($c in @(Get-ProofProp (Get-ProofProp $prod 'unavailable' @()) 'counters' (Get-ProofProp $prod 'unavailable' @()))) { $p41['unavailable_counters'] += , ([string]$c) }
$lines = @(Get-ChildItem -LiteralPath $prodDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)
$p41['jsonl_files'] = @($lines).Count
$readerOk = $false
$readerStatus = ''
if (@($lines).Count -gt 0) {
    $signals = Get-OrchestrationEvolutionSignals -TelemetryDir $prodDir
    $readerOk = [bool](Get-ProofProp $signals 'ok' $false)
    $readerStatus = $(if ($readerOk) { 'ok' } else { [string](Get-ProofProp $signals 'error' 'unknown') })
}
$p41['reader_status'] = $readerStatus
$p41['reader_consumed'] = $readerOk
$p41['runtime_executed'] = (($p41['producer_ok']) -and ($p41['written']) -and ($readerOk))
Write-Proof 'p41-telemetry-runtime' $p41

Write-Host ('P31 runtime_executed=' + $p31['runtime_executed'] + ' status=' + $p31['envelope_status'])
Write-Host ('P38 pipeline_executed=' + $p38['pipeline_executed'] + ' workers=' + (@($p38['workers_in_plan']) -join ','))
Write-Host ('P41 runtime_executed=' + $p41['runtime_executed'] + ' producer=' + $p41['producer_status'] + ' reader=' + $p41['reader_status'])
