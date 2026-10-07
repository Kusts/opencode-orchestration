[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationTelemetry.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationEvidenceStore.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationGoalKernel.ps1')
$passed = 0
function Assert-TLMThat {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
function New-TLMTempDir {
    param([string]$Prefix)
    $t = Join-Path ([IO.Path]::GetTempPath()) ($Prefix + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($t)
    return $t
}
function New-TLMEvidenceBase {
    param([string]$StoreDir, [string]$RunId, [string]$ExpiresAt, [string]$CreatedAt)
    $raw = Join-Path $StoreDir ('raw-' + $RunId + '.log')
    [IO.File]::WriteAllText($raw, ('tlm-' + $RunId))
    return [ordered]@{
        task_id = 'tlm-task'; run_id = $RunId; worker_id = 'coder_1'
        provenance = @{ created_by = 'coder'; kernel_task_ref = 'tlm-task' }
        base_revision = 'rev-a'; criteria_hash = 'crit-a'
        source_fingerprints = @{'src/a.ps1' = 'sha-a'}; diff_hash = 'diff-a'
        scope = @('src/a.ps1'); command = 'test'
        environment = @{ runtime = 'pwsh'; version = '7' }
        result = @{ summary = 'passed'; raw_ref = $raw }
        assumptions = @()
        invalidation_conditions = @(
            @{ type = 'source-changed'; paths = @('src/a.ps1') },
            @{ type = 'criteria-changed'; hash = 'crit-a' },
            @{ type = 'base-revision'; require_same = $true },
            @{ type = 'env-changed'; runtime = 'pwsh'; version = '7' },
            @{ type = 'ttl'; expires_at = $ExpiresAt }
        )
        created_at = $CreatedAt
    }
}
# --- Missing dirs: fail-open zeros + note, never throw.
$ghost = Join-Path ([IO.Path]::GetTempPath()) ('tlm-ghost-' + [Guid]::NewGuid().ToString('N'))
$s = Get-OrchestrationTelemetrySummary -EvidenceStoreDir (Join-Path $ghost 'ev') -GoalStoreDir (Join-Path $ghost 'goals')
Assert-TLMThat (([long]$s.version -eq 1)) 'missing dirs: version 1'
Assert-TLMThat (([long]$s.reuse.queries -eq 0) -and ([long]$s.reuse.hits -eq 0) -and ([long]$s.reuse.misses -eq 0)) 'missing dirs: reuse zeros'
Assert-TLMThat ($null -eq $s.reuse.reuse_rate) 'missing dirs: reuse_rate null without queries'
Assert-TLMThat (([long]$s.goals.goals_total -eq 0)) 'missing dirs: goals zeros'
Assert-TLMThat (([bool]$s.decisions.persisted -eq $false)) 'missing dirs: decisions not persisted'
Assert-TLMThat ([string]$s.decisions.note -ceq 'decision telemetry via evidence reuse_metrics em Fase futura') 'missing dirs: decisions honest note'
Assert-TLMThat (-not [string]::IsNullOrWhiteSpace([string]$s.note)) 'missing dirs: note names the gap'
Assert-TLMThat (-not [string]::IsNullOrWhiteSpace([string]$s.timestamp)) 'missing dirs: timestamp stamped'
# --- Empty existing dirs: zeros, reuse_rate null, empty note.
$emptyEv = New-TLMTempDir 'tlm-empty-ev-'
$emptyGoals = New-TLMTempDir 'tlm-empty-goals-'
$s = Get-OrchestrationTelemetrySummary -EvidenceStoreDir $emptyEv -GoalStoreDir $emptyGoals
Assert-TLMThat (([long]$s.reuse.queries -eq 0) -and ($null -eq $s.reuse.reuse_rate)) 'empty stores: no queries means null rate'
Assert-TLMThat (([long]$s.goals.goals_total -eq 0) -and (@($s.goals.goal_states.Keys).Count -eq 0)) 'empty stores: no goals'
Assert-TLMThat ([string]$s.note -ceq '') 'empty stores: clean note'
# --- Live stores: 1 hit + 1 miss and 2 goals in distinct states.
$evDir = New-TLMTempDir 'tlm-ev-'
$goalDir = New-TLMTempDir 'tlm-goals-'
$now = [DateTimeOffset]::UtcNow
$created = $now.AddMinutes(-1).ToString('o')
$expires = $now.AddMinutes(30).ToString('o')
$rec = New-OrchestrationEvidenceRecord (New-TLMEvidenceBase $evDir 'tlm-run-1' $expires $created) $evDir
Assert-TLMThat ([bool]$rec.created) ('live stores: record created (' + [string]$rec.reason + ')')
$hit = Find-ReusableOrchestrationEvidence -StoreDir $evDir -Scope @('src/a.ps1') -CurrentSourceFingerprints @{'src/a.ps1' = 'sha-a'} -CurrentBaseRevision 'rev-a' -CurrentCriteriaHash 'crit-a' -CurrentEnv @{runtime = 'pwsh'; version = '7'} -Now $now.ToString('o') -MaxResults 5
Assert-TLMThat ((@($hit).Count -eq 1)) 'live stores: identical query hits'
$miss = Find-ReusableOrchestrationEvidence -StoreDir $evDir -Scope @('src/a.ps1') -CurrentSourceFingerprints @{'src/a.ps1' = 'sha-b'} -CurrentBaseRevision 'rev-a' -CurrentCriteriaHash 'crit-a' -CurrentEnv @{runtime = 'pwsh'; version = '7'} -Now $now.ToString('o') -MaxResults 5
Assert-TLMThat ((@($miss).Count -eq 0)) 'live stores: drifted fingerprint misses'
$g1 = New-OrchestrationGoal -GoalId 'TLMg1' -Objective 'First goal' -StoreDir $goalDir
Assert-TLMThat ([bool]$g1.ok) 'live stores: goal 1 drafted'
$sv1 = Save-OrchestrationGoal -Goal $g1.goal -StoreDir $goalDir
Assert-TLMThat ([bool]$sv1.ok) 'live stores: goal 1 saved'
$g2 = New-OrchestrationGoal -GoalId 'TLMg2' -Objective 'Second goal' -StoreDir $goalDir
Assert-TLMThat ([bool]$g2.ok) 'live stores: goal 2 drafted'
$act2 = Set-OrchestrationGoalState -Goal $g2.goal -ToState 'ACTIVE'
Assert-TLMThat ([bool]$act2.ok) 'live stores: goal 2 activated'
$sv2 = Save-OrchestrationGoal -Goal $act2.goal -StoreDir $goalDir
Assert-TLMThat ([bool]$sv2.ok) 'live stores: goal 2 saved'
$s = Get-OrchestrationTelemetrySummary -EvidenceStoreDir $evDir -GoalStoreDir $goalDir
Assert-TLMThat (([long]$s.reuse.queries -eq 2) -and ([long]$s.reuse.hits -eq 1)) 'live stores: 2 queries 1 hit'
Assert-TLMThat (([long]$s.reuse.misses -ge 1)) 'live stores: drift miss counted'
Assert-TLMThat (($s.reuse.reuse_rate -is [double]) -and ([double]$s.reuse.reuse_rate -eq 0.5)) 'live stores: reuse_rate 0.5'
Assert-TLMThat (([long]$s.goals.goals_total -eq 2)) 'live stores: 2 goals counted'
Assert-TLMThat (([long]$s.goals.goal_states['DRAFT'] -eq 1) -and ([long]$s.goals.goal_states['ACTIVE'] -eq 1)) 'live stores: distinct states split 1 and 1'
Assert-TLMThat (([bool]$s.decisions.persisted -eq $false) -and ([string]$s.decisions.note -ceq 'decision telemetry via evidence reuse_metrics em Fase futura')) 'live stores: decisions honest'
Assert-TLMThat ([string]$s.note -ceq '') 'live stores: clean note'
# --- Hostile goal file is skipped, never counted, never throws.
[IO.File]::WriteAllText((Join-Path $goalDir 'hostile.json'), 'not-json')
$s = Get-OrchestrationTelemetrySummary -EvidenceStoreDir $evDir -GoalStoreDir $goalDir
Assert-TLMThat (([long]$s.goals.goals_total -eq 2)) 'hostile goal file skipped'
Assert-TLMThat (([long]$s.goals.goals_invalid -eq 1)) 'malformed goal file is invalid'
Assert-TLMThat (([bool]$s.goals.truncated -eq $false)) 'malformed file alone does not truncate'
Assert-TLMThat ([string]$s.goals.note -match 'goals-invalid') 'invalid file is signaled in goals note'
Assert-TLMThat ([string]$s.note -match 'goals-invalid') 'invalid file is signaled in top note'
# --- Schemaless record (state only, no goal_id/revision) is invalid, never counted.
[IO.File]::WriteAllText((Join-Path $goalDir 'schemaless.json'), '{"state":"COMPLETED"}')
$s = Get-OrchestrationTelemetrySummary -EvidenceStoreDir $evDir -GoalStoreDir $goalDir
Assert-TLMThat (([long]$s.goals.goals_total -eq 2)) 'schemaless record not counted in total'
Assert-TLMThat (([long]$s.goals.goals_invalid -eq 2)) 'schemaless record is invalid'
Assert-TLMThat ((@($s.goals.goal_states.Keys).Count -eq 2)) 'invalid records never leak into states'
# --- Oversize goal file (>1MiB) is skipped with a note, never counted, never throws.
$bigBytes = New-Object byte[] (1048576 + 1)
[IO.File]::WriteAllBytes((Join-Path $goalDir 'oversize.json'), $bigBytes)
$s = Get-OrchestrationTelemetrySummary -EvidenceStoreDir $evDir -GoalStoreDir $goalDir
Assert-TLMThat (([long]$s.goals.goals_total -eq 2)) 'oversize file not counted in total'
Assert-TLMThat (([bool]$s.goals.truncated -eq $true)) 'oversize skip marks truncated'
Assert-TLMThat ([string]$s.goals.note -match 'skipped-oversize') 'oversize skip is signaled in goals note'
Assert-TLMThat ([string]$s.note -match 'skipped-oversize') 'oversize skip is signaled in top note'
Assert-TLMThat (-not [string]::IsNullOrWhiteSpace([string]$s.note)) 'partial scan never has an empty note'
# --- File cap is explicit and testable via -MaxFiles (default 1000 in production).
$capDir = New-TLMTempDir 'tlm-cap-'
foreach ($cid in @('TLMcap1', 'TLMcap2', 'TLMcap3')) {
    $cg = New-OrchestrationGoal -GoalId $cid -Objective ('Cap goal ' + $cid) -StoreDir $capDir
    Assert-TLMThat ([bool]$cg.ok) ('cap stores: goal drafted (' + $cid + ')')
    $csv = Save-OrchestrationGoal -Goal $cg.goal -StoreDir $capDir
    Assert-TLMThat ([bool]$csv.ok) ('cap stores: goal saved (' + $cid + ')')
}
$sc = Get-OrchestrationTelemetrySummary -EvidenceStoreDir $emptyEv -GoalStoreDir $capDir -MaxFiles 2
Assert-TLMThat (([long]$sc.goals.goals_total -eq 2)) 'cap: only MaxFiles goals counted'
Assert-TLMThat (([bool]$sc.goals.truncated -eq $true)) 'cap: truncation is signaled'
Assert-TLMThat ([string]$sc.goals.note -match 'truncated-file-cap') 'cap: cap note in goals note'
Assert-TLMThat ([string]$sc.note -match 'truncated-file-cap') 'cap: cap note in top note'
$scFull = Get-OrchestrationTelemetrySummary -EvidenceStoreDir $emptyEv -GoalStoreDir $capDir
Assert-TLMThat ((([long]$scFull.goals.goals_total -eq 3) -and ([bool]$scFull.goals.truncated -eq $false))) 'cap: default limit counts all without truncation'
Assert-TLMThat ([string]$scFull.note -ceq '') 'cap: full scan keeps a clean note'
# --- Fallback validation (no kernel): revision must be an integral
# numeric type. The fallback function is pure, so it is tested
# directly even though the goal kernel is dot-sourced above.
$fbInt = @{ goal_id = 'TLMfb1'; state = 'ACTIVE'; revision = 1 }
Assert-TLMThat ([bool](Test-TLMFallbackGoalValid $fbInt)) 'fallback: int revision is valid'
$fbStr = @{ goal_id = 'TLMfb1'; state = 'ACTIVE'; revision = '1' }
Assert-TLMThat (-not [bool](Test-TLMFallbackGoalValid $fbStr)) 'fallback: string revision is invalid'
$fbBool = @{ goal_id = 'TLMfb1'; state = 'ACTIVE'; revision = $true }
Assert-TLMThat (-not [bool](Test-TLMFallbackGoalValid $fbBool)) 'fallback: bool revision is invalid'
$fbArr = @{ goal_id = 'TLMfb1'; state = 'ACTIVE'; revision = @(1) }
Assert-TLMThat (-not [bool](Test-TLMFallbackGoalValid $fbArr)) 'fallback: array revision is invalid'
Remove-Item -LiteralPath $capDir -Recurse -Force
Remove-Item -LiteralPath $emptyEv -Recurse -Force
Remove-Item -LiteralPath $emptyGoals -Recurse -Force
Remove-Item -LiteralPath $evDir -Recurse -Force
Remove-Item -LiteralPath $goalDir -Recurse -Force
Write-Output ("OrchestrationTelemetry: PASS ($passed assertions)")
