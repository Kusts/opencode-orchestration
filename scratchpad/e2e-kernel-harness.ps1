# E2E harness for Task Kernel: Planner -> Coder -> Tester -> Reviewer -> DONE
# Uses the real Task Kernel CLI with acceptance criteria + verification profile.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$baseRevision = (& git -C $repo rev-parse HEAD 2>$null | Out-String).Trim()
if ($baseRevision -notmatch '^[0-9a-fA-F]{40}$') {
    throw "Could not determine a valid base revision for repo: $repo"
}
$kernel = Join-Path $repo 'scripts\v3\task-kernel.ps1'
$suffix = [guid]::NewGuid().ToString('N').Substring(0,8)
$taskId = "e2e-kernel-$suffix"
Write-Host "TASK_ID=$taskId"

function Invoke-Kernel {
    param([string[]]$CliArgs)
    $out = & powershell -NoProfile -File $kernel @CliArgs 2>&1
    $json = $null
    try { $json = ($out | Out-String) | ConvertFrom-Json } catch { }
    return @{ Raw = $out; Json = $json }
}

# 1. Create task with acceptance criteria + verification profile
$r = Invoke-Kernel @('-Action','create','-TaskId',$taskId,'-Objective','E2E kernel validation sanity','-TaskType','implementation','-Risk','low','-Actor','planner','-AcceptanceCriteria','criterion:0:sanity','-VerifierProfiles','criterion-smoke','-BaseRevision',$baseRevision,'-ReadScopes','src','-WriteScopes','scratchpad','-Grants','fs.read','fs.write')
Write-Host "CREATE: ok=$($r.Json.ok) state=$($r.Json.state) rev=$($r.Json.revision)"
if (-not $r.Json.ok) { throw "create failed: $($r.Raw)" }

# 2. DISCOVERING -> PLANNING -> IMPLEMENTING
$r = Invoke-Kernel @('-Action','transition','-TaskId',$taskId,'-ToState','PLANNING','-Actor','planner','-ExpectedRevision','1','-ActorIdentitySource','explicit-cli')
Write-Host "PLANNING: ok=$($r.Json.ok) rev=$($r.Json.revision)"
$r = Invoke-Kernel @('-Action','transition','-TaskId',$taskId,'-ToState','IMPLEMENTING','-Actor','planner','-ExpectedRevision','2','-ActorIdentitySource','explicit-cli')
Write-Host "IMPLEMENTING: ok=$($r.Json.ok) rev=$($r.Json.revision)"

# 3. Record worker result (Coder)
$r = Invoke-Kernel @('-Action','record-result','-TaskId',$taskId,'-WorkerStatus','candidate_pass','-ProducedBy','coder','-ExpectedRevision','3','-ClaimedEvidence','criterion:0:sanity')
Write-Host "RECORD: ok=$($r.Json.ok) rev=$($r.Json.revision)"
if (-not $r.Json.ok) { throw "record failed: $($r.Raw)" }

# 4. IMPLEMENTING -> VALIDATING
$r = Invoke-Kernel @('-Action','transition','-TaskId',$taskId,'-ToState','VALIDATING','-Actor','planner','-ExpectedRevision','4','-ActorIdentitySource','explicit-cli')
Write-Host "VALIDATING: ok=$($r.Json.ok) rev=$($r.Json.revision)"

# 5. verify-run (kernel-executed)
$r = Invoke-Kernel @('-Action','verify-run','-TaskId',$taskId,'-ExpectedRevision','5')
Write-Host "VERIFY-RUN: ok=$($r.Json.ok) error=$($r.Json.error)"
Write-Host ($r.Raw | Out-String)

# 6. VALIDATING -> REVIEWING
$r = Invoke-Kernel @('-Action','transition','-TaskId',$taskId,'-ToState','REVIEWING','-Actor','planner','-ExpectedRevision','6','-ActorIdentitySource','explicit-cli')
Write-Host "REVIEWING: ok=$($r.Json.ok) rev=$($r.Json.revision)"

# 7. Register review (approved)
$r = Invoke-Kernel @('-Action','review','-TaskId',$taskId,'-ReviewKind','reviewer','-ReviewStatus','approved','-ReviewBy','planner','-ExpectedRevision','7','-FindingsJson','[]')
Write-Host "REVIEW: ok=$($r.Json.ok) rev=$($r.Json.revision)"

# 8. Complete
$r = Invoke-Kernel @('-Action','complete','-TaskId',$taskId,'-Actor','planner','-ExpectedRevision','8','-ActorIdentitySource','explicit-cli','-ResidualRisks','none-identified','-OrchestrationCompliance','COMPLIANT')
Write-Host "COMPLETE: ok=$($r.Json.ok)"
if (-not $r.Json.ok) { Write-Host ($r.Raw | Out-String) } else { Write-Host "STATE=$($r.Json.state)" }

# 9. Get final status
$r = Invoke-Kernel @('-Action','get','-TaskId',$taskId)
Write-Host "FINAL STATE: $($r.Json.state) rev=$($r.Json.revision)"
Write-Host "E2E DONE"
