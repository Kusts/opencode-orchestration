[CmdletBinding()] param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OrchestrationValidationPolicy.ps1')
$policy=ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\..\..\source\registry\validation-policy.json')))
$passed=0
function Assert-That {param([bool]$Condition,[string]$Name);if(-not $Condition){throw "FAIL: $Name"};$script:passed++}
$l1=Get-OrchestrationValidationLevel @{localized=$true;risk='low'} $policy
Assert-That ($l1.level -eq 'L1' -and $l1.required_roles.Count -eq 1 -and $l1.required_roles[0] -eq 'coder') 'L1 avoids tester and reviewer'
Assert-That ((Get-OrchestrationValidationLevel @{single_worker=$true;risk='low'} $policy).level -eq 'L0') 'L0 trivial level'
$l2=Get-OrchestrationValidationLevel @{risk='medium'} $policy
Assert-That ($l2.level -eq 'L2' -and $l2.required_roles -contains 'tester' -and $l2.required_roles -contains 'reviewer') 'L2 independent validation'
$hostile=Get-OrchestrationValidationLevel @{localized=$true;risk='low';risk_triggers=@('payments')} $policy
Assert-That ($hostile.level -eq 'L3' -and $hostile.required_roles -contains 'security-reviewer') 'hard trigger cannot downgrade'
Assert-That (-not (Test-OrchestrationCompletionPolicy 'L2' @('coder','tester') @{risk='medium'} $policy).allowed) 'completion rejects missing reviewer'
Assert-That (Test-OrchestrationCompletionPolicy 'L1' @('coder') @{localized=$true;risk='low'} $policy).allowed 'L1 completion only requires coder'
Assert-That ((Test-OrchestrationCompletionPolicy 'L1' @('coder','tester','reviewer') @{risk='critical'} $policy).effective_level -eq 'L3') 'completion risk cannot be lowered by caller'
Assert-That (-not (Test-OrchestrationCompletionPolicy 'L1' @('coder','tester','reviewer') @{risk='critical'} $policy).allowed) 'critical-risk bypass requires security reviewer'
Assert-That ((Test-OrchestrationCompletionPolicy 'L2' @('coder','tester','reviewer') @{domain='auth service';risk='medium'} $policy).effective_level -eq 'L3') 'textual auth domain cannot be lowered'
$custom=ConvertFrom-Json '{"levels":{"L0":{"required_roles":["coder"]},"L1":{"required_roles":["coder"]},"L2":{"required_roles":["coder","tester","reviewer"]},"L3":{"required_roles":["coder","tester","reviewer","security-reviewer"]}},"hard_risk_triggers":["auth"],"minimum_level_by_risk":{"low":"L0","medium":"L2","high":"L3","critical":"L3"},"descriptor_rules":[{"when":{"risk":"low"},"level":"L2"}]}'
Assert-That ((Get-OrchestrationValidationLevel @{risk='low'} $custom).level -eq 'L2') 'descriptor rules in supplied policy are authoritative'
$unavailable=Get-OrchestrationValidationLevel @{risk='low'} @{levels=@{}}
Assert-That ($unavailable.level -eq 'L3' -and $unavailable.status -eq 'policy-unavailable') 'malformed policy fails closed'
Assert-That ((Get-OrchestrationValidationLevel @{risk='unknown';single_worker=$true} $policy).level -eq 'L3') 'unknown risk fails closed to L3'
$textTriggers=Get-OrchestrationValidationLevel @{risk='low';domain='auth';operation='payments transfer';summary='production'} $policy
Assert-That ($textTriggers.level -eq 'L3' -and $textTriggers.triggers.Count -ge 3) 'multiple textual triggers are detected'
$current=@{a='1'};$coverage=Test-OrchestrationEvidenceCoverage @(@{status='confirmed';source_fingerprints=@{a='1'};created_at='2026-10-02T00:00:00Z'}) $current -Now '2026-10-02T00:00:00Z'
Assert-That $coverage.can_skip_tester_check 'equivalent confirmed evidence permits skip'
Assert-That (-not (Test-OrchestrationEvidenceCoverage @(@{status='confirmed';source_fingerprints=@{a='old'};created_at='2026-10-02T00:00:00Z'}) $current -Now '2026-10-02T00:00:00Z').can_skip_tester_check) 'edge/source change requires new test'
Assert-That (-not (Test-OrchestrationEvidenceCoverage @(@{status='confirmed';source_fingerprints=@{}}) $current -ExpectedFingerprints @{a='1';b='2'}).can_skip_tester_check) 'empty evidence fingerprints invalid'
Assert-That (-not (Test-OrchestrationEvidenceCoverage @(@{status='confirmed';source_fingerprints=@{a='1'}}) $current -ExpectedFingerprints @{a='1';b='2'}).can_skip_tester_check) 'partial evidence fingerprints invalid'
Assert-That (-not (Test-OrchestrationEvidenceCoverage @(@{status='confirmed';source_fingerprints=@{a='1'};created_at='2026-01-01T00:00:00Z'}) $current -Now '2026-10-02T00:00:00Z').can_skip_tester_check) 'old coverage without explicit TTL expires by policy default'
Assert-That ((Get-OrchestrationReviewerBundle @('src/a.ps1') @('src/a.tests.ps1','other/b.ps1')).Count -eq 2) 'review bundle includes deterministic related file'
Assert-That ((ConvertTo-Json (Get-OrchestrationReviewerBundle @('src/a.ps1','src/b.ps1') @('src/a.tests.ps1','src/b.tests.ps1','other/b.tests.ps1')) -Compress) -ceq (ConvertTo-Json (Get-OrchestrationReviewerBundle @('src/a.ps1','src/b.ps1') @('src/a.tests.ps1','src/b.tests.ps1','other/b.tests.ps1')) -Compress)) 'multi-file bundle deterministic across calls'
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('validation-ledger-'+[guid]::NewGuid().ToString('N')+'.jsonl')
try {
    Assert-That (Write-OrchestrationSecurityCoverage $tmp 'scope/a' @{a='one'} 'confirmed' '2026-10-02T00:00:00Z' -BaseRevision 'rev-a') 'ledger write'
    Assert-That (Test-OrchestrationSecurityCoverage $tmp 'scope/a' @{a='one'} -ExpectedFingerprints @{a='one'} -CurrentBaseRevision 'rev-a' -Now '2026-10-02T00:00:00Z').covered 'matching security coverage'
    Assert-That (-not (Test-OrchestrationSecurityCoverage $tmp 'scope/a' @{a='two'}).covered) 'changed source invalidates security coverage'
    Assert-That (-not (Test-OrchestrationSecurityCoverage $tmp 'scope/a' @{} -ExpectedFingerprints @{}).covered) 'empty ledger/current fingerprints invalid'
    Assert-That (-not (Test-OrchestrationSecurityCoverage $tmp 'scope/a' @{a='one';b='two'} -ExpectedFingerprints @{a='one';b='two'}).covered) 'partial ledger fingerprints invalid'
    Assert-That (Write-OrchestrationSecurityCoverage $tmp 'scope/ttl' @{a='one'} 'confirmed' '2026-10-02T00:00:00Z' -BaseRevision 'rev-a' -ExpiresAt '2026-10-03T00:00:00Z') 'TTL ledger write'
    Assert-That (Test-OrchestrationSecurityCoverage $tmp 'scope/ttl' @{a='one'} -ExpectedFingerprints @{a='one'} -CurrentBaseRevision 'rev-a' -Now '2026-10-02T12:00:00Z').covered 'unexpired coverage query'
    Assert-That (-not (Test-OrchestrationSecurityCoverage $tmp 'scope/ttl' @{a='one'} -ExpectedFingerprints @{a='one'} -CurrentBaseRevision 'rev-a' -Now '2026-10-04T00:00:00Z').covered) 'expired coverage requires validation'
    Assert-That (Write-OrchestrationSecurityCoverage $tmp 'scope/no-fingerprints' @{} 'confirmed' '2026-10-02T00:00:00Z' -BaseRevision 'rev-a') 'confirmed without fingerprints downgraded to needs-validation'
    Assert-That (-not (Test-OrchestrationSecurityCoverage $tmp 'scope/no-fingerprints' @{} -ExpectedFingerprints @{} -CurrentBaseRevision 'rev-a').covered) 'no-fingerprint coverage never confirmed'
    Assert-That (Write-OrchestrationSecurityCoverage $tmp 'scope/a' @{note='sk-SYNTHETICSECRET'} 'needs-validation' '2026-10-02T00:00:00Z') 'needs-validation ledger write'
    Assert-That (-not ([IO.File]::ReadAllText($tmp).Contains('sk-SYNTHETICSECRET'))) 'ledger sanitizes secret-like values'
    Assert-That (-not (Test-OrchestrationSecurityCoverage $tmp 'scope/a' @{note='[REDACTED]'}).covered) 'needs-validation never counts as confirmed'
} finally {if(Test-Path $tmp){Remove-Item $tmp -Force}}
Assert-That (-not (Assert-VerifiedPassAuthority 'coder' $policy) -and (Assert-VerifiedPassAuthority 'verifier' $policy)) 'verified pass authority is allowlisted'
$one=Get-OrchestrationValidationLevel @{risk='medium'} $policy;$two=Get-OrchestrationValidationLevel @{risk='medium'} $policy
Assert-That ((ConvertTo-Json $one -Compress) -ceq (ConvertTo-Json $two -Compress)) 'classification deterministic'
Write-Output "PASS: $passed assertions"
