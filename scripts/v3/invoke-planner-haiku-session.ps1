<#
.SYNOPSIS
    Productive Planner Haiku session caller (thin CLI wrapper, no inference by itself).
.DESCRIPTION
    Connects task-kernel model-select to a productive Planner session:
      1. Creates the kernel task intent (task-kernel create) with the
         Planner-supplied immutable verification plan.
      2. Reads the Planner selection via the real CLI
         (task-kernel -Action model-select -AttemptRole build): tier T2,
         provider/model, policy_hash, planner fallback. No dispatch here.
      3. Hands TaskId + CLI-returned model to Invoke-PlannerHaikuDispatch,
         which probes capability, dispatches EXACTLY ONE `opencode run`
         session with the CLI-returned model (fail-closed MODEL_MISMATCH on
         divergence), and records task/session/message/provider/model/tier/
         tokens/cache/cost evidence plus model-attempt, worker result and
         verify-run outcome.
    Exactly-once per RunId. Timeout, provider error, missing telemetry,
    ambiguous outcome or caller-supplied no-start yield UNKNOWN/PROOF_ABSENT
    with no retry and no fallback; the Luna fallback runs only on demonstrated
    pre-run Haiku unavailability. Cost for subscription reports is UNKNOWN.
    Independent review and DONE stay Planner-owned (kernel refuses
    self-review). Executing this wrapper dispatches a real billed/subscription
    session: the Planner runs it at integration time, never the implementer.
    PowerShell 5.1 compatible. ASCII-only.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TaskId,
    [Parameter(Mandatory = $true)][string]$Objective,
    [Parameter(Mandatory = $true)][string[]]$VerificationProfiles,
    [Parameter(Mandatory = $true)][string[]]$AcceptanceCriteria,
    [string]$RunId = '',
    [string]$EvidenceOut = '',
    [int]$TimeoutMs = 600000
)
$ErrorActionPreference = 'Stop'
$v3root = $PSScriptRoot
. (Join-Path $v3root 'lib\OrchestrationPlannerHaikuDispatch.ps1')

$tid = ([string]$TaskId).Trim()
$runId = ([string]$RunId).Trim()
if ([string]::IsNullOrWhiteSpace($runId)) { $runId = $tid }

function Invoke-KernelCliJson {
    param([string[]]$CliArgs)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell'
    $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $v3root 'task-kernel.ps1') + '" ' + ($CliArgs -join ' '))
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    [void]$p.WaitForExit(120000)
    return @{ exit_code = $p.ExitCode; stdout = $out; stderr = $err }
}

function ConvertTo-CliArgList {
    param([string[]]$Profiles, [string[]]$Criteria)
    $args = @()
    foreach ($s in @($Profiles)) { $args += @('-VerificationProfiles', ('"' + ([string]$s).Replace('"', '\"') + '"')) }
    foreach ($s in @($Criteria)) { $args += @('-AcceptanceCriteria', ('"' + ([string]$s).Replace('"', '\"') + '"')) }
    return $args
}

$createArgs = @('-Action', 'create', '-TaskId', ('"' + $tid + '"'), '-Objective', ('"' + ([string]$Objective).Replace('"', '\"') + '"'),
    '-TaskType', 'implementation', '-Risk', 'medium', '-Actor', 'planner-dispatch',
    '-RuntimeId', 'opencode-v2', '-RuntimeGeneration', '2', '-RuntimeProfile', 'v2') + (ConvertTo-CliArgList -Profiles $VerificationProfiles -Criteria $AcceptanceCriteria)
$created = Invoke-KernelCliJson -CliArgs $createArgs
$createdDoc = $null
try { $createdDoc = ($created.stdout | ConvertFrom-Json -ErrorAction Stop) } catch { $createdDoc = $null }
$createErr = ''
try { if ($null -ne $createdDoc -and $null -ne $createdDoc.error) { $createErr = [string]$createdDoc.error } } catch { }
if (($created.exit_code -ne 0) -and ($createErr -cne 'ALREADY_EXISTS')) {
    Write-Output (($createdDoc | ConvertTo-Json -Depth 8 -Compress))
    exit 1
}

$selArgs = @('-Action', 'model-select', '-TaskId', ('"' + $tid + '"'), '-AttemptRole', 'build', '-Risk', 'medium', '-ModelComplexity', 'medium')
$sel = Invoke-KernelCliJson -CliArgs $selArgs
$selDoc = $null
try { $selDoc = ($sel.stdout | ConvertFrom-Json -ErrorAction Stop) } catch { $selDoc = $null }
if (($null -eq $selDoc) -or (-not [bool]$selDoc.ok)) {
    if ($null -eq $selDoc) { Write-Output '{"ok":false,"status":"MODEL_SELECT_CLI_FAILED"}' } else { Write-Output (($selDoc | ConvertTo-Json -Depth 8 -Compress)) }
    exit 1
}
$cliModel = ''
try { $cliModel = ([string]$selDoc.model).Trim() } catch { $cliModel = '' }
$cliTier = ''
try { $cliTier = ([string]$selDoc.tier).Trim() } catch { $cliTier = '' }
if ([string]::IsNullOrWhiteSpace($cliModel) -or ($cliTier -cne 'T2')) {
    Write-Output ([PSCustomObject]@{ ok = $false; status = 'MODEL_OVERRIDE_UNPROVEN'; reason = 'model-select returned no dispatchable T2 model'; run_id = $runId; task_id = $tid } | ConvertTo-Json -Depth 6 -Compress)
    exit 1
}

$dispatch = Invoke-PlannerHaikuDispatch -TaskId $tid -Objective ([string]$Objective) `
    -VerificationProfiles $VerificationProfiles -AcceptanceCriteria $AcceptanceCriteria `
    -RunId $runId -EvidenceOut $EvidenceOut -TimeoutMs $TimeoutMs -ExpectedModel $cliModel
Write-Output (($dispatch | ConvertTo-Json -Depth 10 -Compress))
if ([bool]$dispatch.ok) { exit 0 } else { exit 1 }
