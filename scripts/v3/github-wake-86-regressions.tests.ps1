# github-wake-86-regressions.tests.ps1 -- issue #86 scheduled-resume regressions.
# Offline only (no gh, no network, no opencode, no model). Proves the two
# pure contracts fixed for the scheduled wake path:
#   R1: a single-element required_checks array (unwrapped by ConvertFrom-Json)
#       still validates as a list in Test-GHRSWaitShape.
#   R2: New-GitHubWakeConfig persists max_age_seconds and the new
#       resume_timeout_ms, and invalid resume timeouts fall back to 30000.
# The live scheduled rerun is the end-to-end evidence for the max_age wiring
# and the real resume turn; this suite stays hermetic.
$ErrorActionPreference = 'Stop'
$script:wake = Join-Path $PSScriptRoot 'github-wake.ps1'
. $script:wake
. (Join-Path $PSScriptRoot 'lib\OrchestrationGitHubResume.ps1')
$passed = 0
function Assert-That {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}

# R1: single-element required_checks survives JSON round-trip as a scalar.
$repo = 'acme/widgets'
$pr = 7
$sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$dk = Get-OrchestrationGitHubResumeDedupKey -Repository $repo -PrNumber $pr -HeadSha $sha -Generation 1
Assert-That ([bool]$dk.ok) 'R1 dedup key built'
$wait = [ordered]@{
    schema_version = 1; wait_kind = 'github-ci-resume'; wait_state = 'waiting'
    dedup_key = [string]$dk.dedup_key; objective_id = 'goal-r1'; task_id = 'task-r1'
    run_id = 'run-r1'; generation = 1; repository = $repo; pr_number = $pr
    branch = 'fix/r1'; expected_head_sha = $sha; required_checks = @('ci86')
    review_expectation = 'ANY'; cursor = ''; deadline_utc = '2027-06-01T00:00:00Z'
    retry_budget_max = 5; retry_used = 0; lease_owner = 'planner-1'
    lease_expires_utc = '2027-06-01T00:00:00Z'; owner = 'planner-1'
    applied_events = @(); created_at = '2026-11-08T00:00:00Z'; updated_at = '2026-11-08T00:00:00Z'
}
$roundTrip = (($wait | ConvertTo-Json -Depth 6 -Compress) | ConvertFrom-Json)
$rawChecks = Get-GHRSValue $roundTrip 'required_checks' $null
Assert-That ($rawChecks -is [string]) 'R1 precondition: single item reaches shape as scalar'
$shape = Test-GHRSWaitShape -Wait $roundTrip
Assert-That ([bool]$shape.ok) 'R1 single-element required_checks validates'

# R2: config persists durable scheduler fields; invalid resume timeout falls back.
$cfgPath = Join-Path ([IO.Path]::GetTempPath()) ('ghw86-cfg-' + [guid]::NewGuid().ToString('N') + '.json')
$cfg = New-GitHubWakeConfig -Path $cfgPath -WaitsDir 'w' -TasksDir 't' -GoalStoreDir 'g' -CheckpointDir 'c' -FlagsPath 'f' -MaxAgeSeconds 3600 -ResumeTimeoutMs 600000
Assert-That ([bool]$cfg.ok) 'R2 config written'
$cfgDoc = [IO.File]::ReadAllText($cfgPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
Assert-That ([int]$cfgDoc.max_age_seconds -eq 3600) 'R2 max_age_seconds persisted'
Assert-That ([int]$cfgDoc.resume_timeout_ms -eq 600000) 'R2 resume_timeout_ms persisted'
$cfgPath2 = Join-Path ([IO.Path]::GetTempPath()) ('ghw86-cfg-' + [guid]::NewGuid().ToString('N') + '.json')
$cfg2 = New-GitHubWakeConfig -Path $cfgPath2 -WaitsDir 'w' -TasksDir 't' -GoalStoreDir 'g' -CheckpointDir 'c' -FlagsPath 'f' -ResumeTimeoutMs 10
Assert-That ([bool]$cfg2.ok) 'R2 second config written'
$cfgDoc2 = [IO.File]::ReadAllText($cfgPath2, [Text.Encoding]::UTF8) | ConvertFrom-Json
Assert-That ([int]$cfgDoc2.resume_timeout_ms -eq 30000) 'R2 invalid resume timeout falls back to default'

Write-Output ('OK github-wake-86-regressions (' + [string]$script:passed + ' asserts)')
exit 0
