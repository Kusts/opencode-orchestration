[CmdletBinding()]
param(
    [string]$OutFile,
    [string]$GeneratedAt = '2026-11-12T00:00:00Z',
    [string]$BaseRevision = '8fdeb89e51e0ef8d96f36c6f06a06e5b5a6817e7',
    [string]$GeneratedByCommit = ''
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $PSScriptRoot 'lib\OrchestrationPreflight.ps1')
$scenarioInputs = @(
    [pscustomobject]@{ id='A'; Objective='Where is the definition of the local setting?'; TaskType='lookup'; Domain='code'; Risk='low'; ReadWrite='read' },
    [pscustomobject]@{ id='B'; Objective='Fix typo in one file comment'; TaskType='trivial'; Domain='docs'; Risk='low'; ReadWrite='write' },
    [pscustomobject]@{ id='C'; Objective='Implement a new validation workflow'; TaskType='implementation'; Domain='code'; Risk='medium'; ReadWrite='write' },
    [pscustomobject]@{ id='D'; Objective='Design architecture for a local cache'; TaskType='planning'; Domain='architecture'; Risk='medium'; ReadWrite='write' }
)
$decisions = @()
$matrix = @()
$comparison = @()
foreach ($s in $scenarioInputs) {
    $inputs = [ordered]@{ Objective=$s.Objective; TaskType=$s.TaskType; Domain=$s.Domain; Risk=$s.Risk; ReadWrite=$s.ReadWrite }
    $r = Get-OrchestrationPreflight @inputs
    $agents = @($r.selected_agents)
    $decisions += [pscustomobject]@{ id=$s.id; inputs=$inputs; objective_chars_observed=$s.Objective.Length; decision=$r.orchestration_decision; selected_agents=$agents; direct_allowed=($r.orchestration_decision -eq 'DIRECT_VERIFIED') }
    $gateInputs = @()
    if ($r.task_class -eq 'trivial') {
        $gateInputs += ,@{ TaskClass='trivial'; Decision='SINGLE_WORKER'; ExecutionShape='SINGLE_WORKER'; ActualWorkerParticipation=0 }
        $gateInputs += ,@{ TaskClass='trivial'; Decision='SINGLE_WORKER'; ExecutionShape='SINGLE_WORKER'; ActualWorkerParticipation=1 }
        $gateInputs += ,@{ TaskClass='trivial'; Decision='DIRECT_VERIFIED'; ExecutionShape='DIRECT_VERIFIED'; DirectReason='DIRECT_VERIFIED_LOW_RISK_LOCALIZED'; ActualWorkerParticipation=0 }
        $gateInputs += ,@{ TaskClass='trivial'; Decision='DIRECT_VERIFIED'; ExecutionShape='DIRECT_VERIFIED'; ActualWorkerParticipation=0 }
    } else {
        $gateInputs += ,@{ TaskClass='non_trivial'; Decision='SINGLE_WORKER'; ActualWorkerParticipation=0 }
    }
    $tokens = @()
    foreach ($gi in $gateInputs) {
        $token = Test-OrchestrationDoneCompliance @gi
        $row = [ordered]@{ scenario_id=$s.id; inputs=$gi; declared_inputs=$true; token=$token }
        $matrix += [pscustomobject]$row
        $tokens += $token
    }
    $comparison += [pscustomobject]@{ scenario_id=$s.id; decision=$r.orchestration_decision; selected_agent_count=$agents.Count; selected_agents=$agents; execution_performed=$false; compliance_tokens=$tokens }
}
$strategies = @(
    [pscustomobject]@{ name='Direct'; status='implemented'; mapping='DIRECT_VERIFIED'; source='scripts/v3/lib/OrchestrationPreflight.ps1:Get-OrchestrationPreflight' },
    [pscustomobject]@{ name='Single'; status='implemented'; mapping='SINGLE_WORKER'; source='scripts/v3/lib/OrchestrationPreflight.ps1:Get-OrchestrationPreflight' },
    [pscustomobject]@{ name='Cascade'; status='NOT_IMPLEMENTED'; reason='Only present in docs; no selector, registry, or implementation.' },
    [pscustomobject]@{ name='Critique'; status='NOT_IMPLEMENTED'; reason='Only present in docs; no selector, registry, or implementation.' }
)
$metrics = [pscustomobject]@{ estimated_tokens=@($decisions | ForEach-Object { [pscustomobject]@{ scenario_id=$_.id; value=[math]::Ceiling($_.objective_chars_observed / 4.0); is_estimate=$true; method='chars/4' } }) }
$unknown = @(
    [pscustomobject]@{ name='wall_clock'; reason='No execution performed.' }, [pscustomobject]@{ name='provider_tokens'; reason='No model call.' },
    [pscustomobject]@{ name='provider_cost'; reason='No model call.' }, [pscustomobject]@{ name='execution_shape_observed'; reason='No execution performed; preflight returns no observed shape.' },
    [pscustomobject]@{ name='worker_participation_observed'; reason='No execution performed.' }, [pscustomobject]@{ name='cascade_outcome'; reason='Cascade is not implemented.' }, [pscustomobject]@{ name='critique_outcome'; reason='Critique is not implemented.' }
)
$result = [ordered]@{ evidence_kind='decision_and_policy_probe'; runtime_real=$false; execution_performed=$false; generated_at=$GeneratedAt; decisions=$decisions; compliance_matrix=$matrix; strategies=$strategies; comparison=$comparison; metrics=$metrics; unknown=$unknown; method=[ordered]@{ type='deterministic_local_io'; no_model_call=$true; no_second_router=$true; base_revision=$BaseRevision; generated_by_commit=$GeneratedByCommit; limitations=@('No execution was performed; decisions are pre-execution and the compliance matrix uses declared inputs.') } }
$json = $result | ConvertTo-Json -Depth 20
if (-not [string]::IsNullOrWhiteSpace($OutFile)) { [System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($OutFile), $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false))) }
else { $json }
