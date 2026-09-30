<#!
.SYNOPSIS
    Tests for lib/OrchestrationVerifier.ps1 (Phase 12).
.DESCRIPTION
    Hermetic: temp git repo fixtures + temp fixture policies; no repo state
    mutated. Bracketed output the runner parses. Exit 0 on all pass,
    exit 1 on any fail or unexpected exception. PS 5.1. ASCII-only.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$libPath = Join-Path $PSScriptRoot 'OrchestrationVerifier.ps1'
. $libPath

$script:passed = 0
$script:failed = 0

function Assert-Verifier {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) {
        Write-Host ("[PASS] {0}" -f $Name)
        $script:passed++
    }
    else {
        if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ("[FAIL] {0}" -f $Name) }
        else { Write-Host ("[FAIL] {0} -- {1}" -f $Name, $Detail) }
        $script:failed++
    }
}

function Write-VerifierFixture {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $lf = ($Text -replace "`r`n", "`n" -replace "`r", "`n")
    [IO.File]::WriteAllText($Path, $lf, [Text.UTF8Encoding]::new($false))
}

function Write-VerifierPolicy {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][hashtable]$Profiles)
    $profObj = New-Object PSCustomObject
    foreach ($k in @($Profiles.Keys | Sort-Object)) {
        $profObj | Add-Member -NotePropertyName $k -NotePropertyValue $Profiles[$k]
    }
    $doc = [ordered]@{
        version = 1
        default_timeout_seconds = 120
        max_output_chars = 4000
        profiles = $profObj
    }
    $json = (New-Object PSCustomObject -Property $doc | ConvertTo-Json -Depth 6 -Compress)
    Write-VerifierFixture -Path $Path -Text $json
}

function New-VerifierGitRepo {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('v3-verifier-repo-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    & git -C $dir init -b master *>$null
    if ($LASTEXITCODE -ne 0) {
        & git -C $dir init *>$null
    }
    & git -C $dir config user.email 'verifier-test@example.com' *>$null
    & git -C $dir config user.name 'Verifier Test' *>$null
    & git -C $dir config core.autocrlf false *>$null
    & git -C $dir config core.safecrlf false *>$null
    Write-VerifierFixture -Path (Join-Path $dir 'allowed\base.txt') -Text "base`n"
    & git -C $dir add -A *>$null
    & git -C $dir commit -m init -q *>$null
    if ($LASTEXITCODE -ne 0) { throw ('git fixture commit failed in ' + $dir) }
    return $dir
}

$roots = New-Object System.Collections.ArrayList
$repoRoot = (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$repoPolicy = Join-Path $repoRoot 'source\registry\verification-policy.json'

try {
    # 1. repo policy parses
    $p = Get-OrchestrationVerificationPolicy -PolicyPath $repoPolicy
    Assert-Verifier ([bool]$p.ok) 'repo policy parses ok' ([string]$p.error)
    Assert-Verifier (([int]$p.policy.version -eq 1) -and ([int]$p.policy.default_timeout_seconds -eq 120) -and ([int]$p.policy.max_output_chars -eq 4000)) 'repo policy carries expected header values'

    # 2. schema invalid rejected (bad class)
    $badDir = Join-Path ([IO.Path]::GetTempPath()) ('v3-verifier-pol-' + [guid]::NewGuid().ToString('N'))
    [void]$roots.Add($badDir)
    $badPol = Join-Path $badDir 'policy.json'
    Write-VerifierPolicy -Path $badPol -Profiles @{
        'bad' = [PSCustomObject]@{ class = 'deploy'; command = 'echo hi'; timeout_seconds = 10 }
    }
    $bad = Get-OrchestrationVerificationPolicy -PolicyPath $badPol
    Assert-Verifier ((-not [bool]$bad.ok) -and ([string]$bad.error -ceq 'POLICY_SCHEMA_INVALID')) 'policy with bad class rejected'

    # 2b. schema invalid rejected (timeout out of range)
    $badPol2 = Join-Path $badDir 'policy2.json'
    Write-VerifierPolicy -Path $badPol2 -Profiles @{
        'bad' = [PSCustomObject]@{ class = 'test'; command = 'echo hi'; timeout_seconds = 0 }
    }
    $bad2 = Get-OrchestrationVerificationPolicy -PolicyPath $badPol2
    Assert-Verifier ((-not [bool]$bad2.ok)) 'policy with timeout 0 rejected'

    # 2c. missing file
    $missing = Get-OrchestrationVerificationPolicy -PolicyPath (Join-Path $badDir 'nope.json')
    Assert-Verifier ((-not [bool]$missing.ok) -and ([string]$missing.error -ceq 'POLICY_NOT_FOUND')) 'missing policy file returns POLICY_NOT_FOUND'

    # 3. allowlist exact match (repo policy)
    $knownCmd = 'powershell -NoProfile -File scripts/test-package-consistency.ps1'
    Assert-Verifier ([bool](Test-OrchestrationCommandAllowlisted -Command $knownCmd -Policy $p.policy)) 'exact policy command is allowlisted'
    Assert-Verifier (-not [bool](Test-OrchestrationCommandAllowlisted -Command ($knownCmd + ' -Extra arg') -Policy $p.policy)) 'command with extra args NOT allowlisted'
    Assert-Verifier (-not [bool](Test-OrchestrationCommandAllowlisted -Command 'powershell -noprofile -file scripts/test-package-consistency.ps1' -Policy $p.policy)) 'case-differing command NOT allowlisted'
    Assert-Verifier (-not [bool](Test-OrchestrationCommandAllowlisted -Command '' -Policy $p.policy)) 'empty command NOT allowlisted'

    # 4. unknown profile => manual_verification_required, NOTHING runs (canary)
    $canDir = Join-Path ([IO.Path]::GetTempPath()) ('v3-verifier-can-' + [guid]::NewGuid().ToString('N'))
    [void]$roots.Add($canDir)
    $marker = Join-Path $canDir 'marker-should-not-exist.txt'
    $canPol = Join-Path $canDir 'policy.json'
    $markerQ = "'" + $marker + "'"
    Write-VerifierPolicy -Path $canPol -Profiles @{
        'good' = [PSCustomObject]@{ class = 'test'; command = ("powershell -NoProfile -Command ""New-Item -ItemType File -Path " + $markerQ + " -Force | Out-Null"""); timeout_seconds = 60 }
    }
    $canRepo = New-VerifierGitRepo
    [void]$roots.Add($canRepo)
    $u = Invoke-OrchestrationValidationProfile -ProfileName 'should-not-run' -RepoRoot $canRepo -PolicyPath $canPol
    Assert-Verifier (([string]$u.status -ceq 'manual_verification_required') -and ([string]$u.error -ceq 'UNKNOWN_PROFILE')) 'unknown profile returns manual_verification_required'
    $v = Invoke-OrchestrationVerifier -TaskId 'canary-001' -RepoRoot $canRepo -BaseRevision 'HEAD' -WriteScopes @('allowed') -ProfileNames @('good', 'should-not-run') -PolicyPath $canPol
    Assert-Verifier (([string]$v.status -ceq 'manual_verification_required') -and ([string]$v.reason -ceq 'unknown_profile')) 'verifier fail-closed on unknown profile'
    Assert-Verifier (-not (Test-Path -LiteralPath $marker -PathType Leaf)) 'known profile did NOT run when unknown profile present (no side effect)'

    # 5. out-of-scope write blocks BEFORE any command
    $scopeRepo = New-VerifierGitRepo
    [void]$roots.Add($scopeRepo)
    Write-VerifierFixture -Path (Join-Path $scopeRepo 'outside\evil.txt') -Text "evil`n"
    $scopePol = Join-Path $scopeRepo 'fixture-policy.json'
    $scopeMarker = Join-Path $scopeRepo 'allowed\probe-marker.txt'
    $scopeMarkerQ = "'" + $scopeMarker + "'"
    Write-VerifierPolicy -Path $scopePol -Profiles @{
        'probe' = [PSCustomObject]@{ class = 'test'; command = ("powershell -NoProfile -Command ""New-Item -ItemType File -Path " + $scopeMarkerQ + " -Force | Out-Null"""); timeout_seconds = 60 }
    }
    $o = Invoke-OrchestrationVerifier -TaskId 'scope-001' -RepoRoot $scopeRepo -BaseRevision 'HEAD' -WriteScopes @('allowed') -ProfileNames @('probe') -PolicyPath $scopePol
    Assert-Verifier (([string]$o.status -ceq 'verification_failed') -and ([string]$o.reason -ceq 'out_of_scope_write')) 'out-of-scope write yields verification_failed/out_of_scope_write'
    Assert-Verifier (-not (Test-Path -LiteralPath $scopeMarker -PathType Leaf)) 'no command ran after out-of-scope block (marker absent)'
    Assert-Verifier ((@($o.profiles).Count -eq 0)) 'no profiles executed on scope block'

    # 6. in-scope write passes scope check
    Write-VerifierFixture -Path (Join-Path $scopeRepo 'allowed\ok.txt') -Text "ok`n"
    $s = Test-OrchestrationWriteScope -RepoRoot $scopeRepo -BaseRevision 'HEAD' -WriteScopes @('allowed')
    Assert-Verifier ([bool]$s.ok) 'scope check ok on mixed tree' ([string]$s.error)
    Assert-Verifier (((@($s.in_scope) -join '|') -match 'allowed/ok.txt') -and ((@($s.out_of_scope) -join '|') -match 'outside/evil.txt')) 'in/out classification correct'
    Assert-Verifier (((@($s.dirty_untracked) -join '|') -match 'outside/evil.txt')) 'untracked file listed in dirty_untracked'

    # 6b. empty/'none' BaseRevision => manual_verification_required (no machine verdict without a base)
    $sNone = Test-OrchestrationWriteScope -RepoRoot $scopeRepo -BaseRevision 'none' -WriteScopes @('allowed')
    Assert-Verifier ((-not [bool]$sNone.ok) -and ([string]$sNone.status -ceq 'manual_verification_required') -and ([string]$sNone.error -ceq 'BASE_REVISION_REQUIRED')) 'BaseRevision none requires manual verification'
    $sEmpty = Test-OrchestrationWriteScope -RepoRoot $scopeRepo -BaseRevision '' -WriteScopes @('allowed')
    Assert-Verifier ((-not [bool]$sEmpty.ok) -and ([string]$sEmpty.error -ceq 'BASE_REVISION_REQUIRED')) 'empty BaseRevision requires manual verification'

    # 6c. paths with spaces classify correctly (NUL-separated parsing)
    $spaceRepo = New-VerifierGitRepo
    [void]$roots.Add($spaceRepo)
    Write-VerifierFixture -Path (Join-Path $spaceRepo 'allowed\my spaced file.txt') -Text "spaced`n"
    $sSpace = Test-OrchestrationWriteScope -RepoRoot $spaceRepo -BaseRevision 'HEAD' -WriteScopes @('allowed')
    Assert-Verifier ([bool]$sSpace.ok) 'scope check ok with spaced path' ([string]$sSpace.error)
    Assert-Verifier (((@($sSpace.in_scope) -join '|') -match 'my spaced file')) 'spaced file classified in scope'

    # 6d. renames detected (both sides counted)
    $renRepo = New-VerifierGitRepo
    [void]$roots.Add($renRepo)
    & git -C $renRepo mv allowed/base.txt allowed/renamed.txt *>$null
    $sRen = Test-OrchestrationWriteScope -RepoRoot $renRepo -BaseRevision 'HEAD' -WriteScopes @('allowed')
    Assert-Verifier ([bool]$sRen.ok) 'scope check ok after rename' ([string]$sRen.error)
    Assert-Verifier (((@($sRen.in_scope) -join '|') -match 'renamed')) 'renamed file visible in scope classification'

    # 6e. committed rename between base and HEAD => BOTH old and new paths classified
    $renCRepo = New-VerifierGitRepo
    [void]$roots.Add($renCRepo)
    $renCBase = ((& git -C $renCRepo rev-parse HEAD 2>$null) | Out-String).Trim()
    & git -C $renCRepo mv allowed/base.txt allowed/renamed-committed.txt *>$null
    & git -C $renCRepo commit -m rename-in-scope -q *>$null
    $sRenC = Test-OrchestrationWriteScope -RepoRoot $renCRepo -BaseRevision $renCBase -WriteScopes @('allowed')
    Assert-Verifier ([bool]$sRenC.ok) 'scope check ok after committed rename' ([string]$sRenC.error)
    Assert-Verifier (((( @($sRenC.in_scope) -join '|') -match 'renamed-committed') -and ((@($sRenC.in_scope) -join '|') -match 'allowed/base.txt'))) 'committed rename contributes BOTH old and new paths in scope'
    $renORepo = New-VerifierGitRepo
    [void]$roots.Add($renORepo)
    $renOBase = ((& git -C $renORepo rev-parse HEAD 2>$null) | Out-String).Trim()
    & git -C $renORepo mv allowed/base.txt evicted.txt *>$null
    & git -C $renORepo commit -m rename-out-scope -q *>$null
    $sRenO = Test-OrchestrationWriteScope -RepoRoot $renORepo -BaseRevision $renOBase -WriteScopes @('allowed')
    Assert-Verifier ([bool]$sRenO.ok) 'scope check ok after committed rename out of scope' ([string]$sRenO.error)
    Assert-Verifier (((( @($sRenO.in_scope) -join '|') -match 'allowed/base.txt') -and ((@($sRenO.out_of_scope) -join '|') -match 'evicted'))) 'committed rename old in scope, new out of scope'

    # 7. false worker pass: exit 1 => failed; exit 0 => verified
    $exitDir = Join-Path ([IO.Path]::GetTempPath()) ('v3-verifier-exit-' + [guid]::NewGuid().ToString('N'))
    [void]$roots.Add($exitDir)
    $exitPol = Join-Path $exitDir 'policy.json'
    Write-VerifierPolicy -Path $exitPol -Profiles @{
        'fails' = [PSCustomObject]@{ class = 'test'; command = 'powershell -NoProfile -Command exit 1'; timeout_seconds = 60 }
        'passes' = [PSCustomObject]@{ class = 'test'; command = 'powershell -NoProfile -Command exit 0'; timeout_seconds = 60 }
    }
    $exitRepo = New-VerifierGitRepo
    [void]$roots.Add($exitRepo)
    $f1 = Invoke-OrchestrationValidationProfile -ProfileName 'fails' -RepoRoot $exitRepo -PolicyPath $exitPol
    Assert-Verifier (([string]$f1.status -ceq 'failed') -and ([int]$f1.exit_code -eq 1)) 'exit 1 profile => failed' ([string]$f1.status + ':' + [string]$f1.exit_code)
    $f0 = Invoke-OrchestrationValidationProfile -ProfileName 'passes' -RepoRoot $exitRepo -PolicyPath $exitPol
    Assert-Verifier (([string]$f0.status -ceq 'verified') -and ([bool]$f0.ok)) 'exit 0 profile => verified'
    $vf = Invoke-OrchestrationVerifier -TaskId 'exit-001' -RepoRoot $exitRepo -BaseRevision 'HEAD' -WriteScopes @('allowed') -ProfileNames @('fails') -PolicyPath $exitPol
    Assert-Verifier (([string]$vf.status -ceq 'verification_failed')) 'verifier with failing profile => verification_failed'
    $vp = Invoke-OrchestrationVerifier -TaskId 'exit-002' -RepoRoot $exitRepo -BaseRevision 'HEAD' -WriteScopes @('allowed') -ProfileNames @('passes') -PolicyPath $exitPol
    Assert-Verifier (([string]$vp.status -ceq 'verified_pass') -and ([bool]$vp.ok)) 'verifier with passing profile => verified_pass'
    $vNone = Invoke-OrchestrationVerifier -TaskId 'scope-none-001' -RepoRoot $exitRepo -BaseRevision '' -WriteScopes @('allowed') -ProfileNames @('passes') -PolicyPath $exitPol
    Assert-Verifier (([string]$vNone.status -ceq 'manual_verification_required') -and ([string]$vNone.reason -ceq 'base_revision_required')) 'verifier with empty base => manual/base_revision_required, never verified_pass'

    # 8. timeout kills the tree quickly
    $toDir = Join-Path ([IO.Path]::GetTempPath()) ('v3-verifier-to-' + [guid]::NewGuid().ToString('N'))
    [void]$roots.Add($toDir)
    $toPol = Join-Path $toDir 'policy.json'
    Write-VerifierPolicy -Path $toPol -Profiles @{
        'slow' = [PSCustomObject]@{ class = 'test'; command = 'powershell -NoProfile -Command "Start-Sleep -Seconds 8"'; timeout_seconds = 1 }
    }
    $wall = [System.Diagnostics.Stopwatch]::StartNew()
    $to = Invoke-OrchestrationValidationProfile -ProfileName 'slow' -RepoRoot $exitRepo -PolicyPath $toPol
    $wall.Stop()
    Assert-Verifier (([string]$to.status -ceq 'timeout')) 'sleeping profile with 1s timeout => timeout' ([string]$to.status)
    Assert-Verifier ([long]$wall.ElapsedMilliseconds -lt 8000) 'timeout wall clock well under 8s sleep' ([string]$wall.ElapsedMilliseconds + 'ms')
    $vto = Invoke-OrchestrationVerifier -TaskId 'exit-003' -RepoRoot $exitRepo -BaseRevision 'HEAD' -WriteScopes @('allowed') -ProfileNames @('slow') -PolicyPath $toPol
    Assert-Verifier (([string]$vto.status -ceq 'verification_failed') -and ([string]$vto.reason -ceq 'profile_timeout:slow')) 'verifier with timing-out profile => verification_failed/profile_timeout'

    # 9. secret redaction (synthetic marker only)
    $secDir = Join-Path ([IO.Path]::GetTempPath()) ('v3-verifier-sec-' + [guid]::NewGuid().ToString('N'))
    [void]$roots.Add($secDir)
    $secPol = Join-Path $secDir 'policy.json'
    Write-VerifierPolicy -Path $secPol -Profiles @{
        'leaky' = [PSCustomObject]@{ class = 'test'; command = "powershell -NoProfile -Command ""Write-Output 'token sk-SYNTHETICSECRET done'"""; timeout_seconds = 60 }
    }
    $sec = Invoke-OrchestrationValidationProfile -ProfileName 'leaky' -RepoRoot $exitRepo -PolicyPath $secPol
    Assert-Verifier (([string]$sec.output_capped -notmatch 'sk-SYNTHETICSECRET')) 'synthetic secret absent from capped output'
    Assert-Verifier (([string]$sec.output_capped -match '\[REDACTED\]')) 'redaction marker present in capped output'

    # 10. evidence format
    $evOk = $true
    foreach ($e in @($vp.evidence)) {
        if ($e -match '^\w[\w.-]*:(verified|failed|timeout):-?\d+$') { continue }
        if ($e -match '^\d+ in scope, \d+ out$') { continue }
        $evOk = $false
    }
    Assert-Verifier ($evOk -and (@($vp.evidence).Count -ge 2)) 'evidence strings well-formed (profile + scope summary)' ((@($vp.evidence) -join ' | '))
    Assert-Verifier (((@($vp.command_classes) -join ',') -ceq 'test')) 'command_classes carries profile class'

    # 10b. criterion evidence: default-all-profiles mapping emits verified per criterion
    $vcDef = Invoke-OrchestrationVerifier -TaskId 'crit-def-001' -RepoRoot $exitRepo -BaseRevision 'HEAD' -WriteScopes @('allowed') -ProfileNames @('passes') -PolicyPath $exitPol -AcceptanceCriteria @('crit-a', 'crit-b')
    Assert-Verifier (([string]$vcDef.status -ceq 'verified_pass')) 'criterion default mapping keeps verified_pass'
    Assert-Verifier (((( @($vcDef.evidence) -join '|') -match 'criterion:0:verified') -and ((@($vcDef.evidence) -join '|') -match 'criterion:1:verified'))) 'default-all mapping emits criterion verified per idx'
    Assert-Verifier ((([string]$vcDef.criterion_map['0'].status -ceq 'verified') -and ([string]$vcDef.criterion_map['1'].status -ceq 'verified'))) 'criterion_map carries verified per idx by default'

    # 10c. criterion unverified when a mapped profile fails
    $vcFail = Invoke-OrchestrationVerifier -TaskId 'crit-fail-001' -RepoRoot $exitRepo -BaseRevision 'HEAD' -WriteScopes @('allowed') -ProfileNames @('fails') -PolicyPath $exitPol -AcceptanceCriteria @('crit-a')
    Assert-Verifier (([string]$vcFail.status -ceq 'verification_failed')) 'failing profile keeps verification_failed with criteria'
    Assert-Verifier (((@($vcFail.evidence) -join '|') -match 'criterion:0:unverified')) 'failed mapped profile emits criterion unverified'
    Assert-Verifier (([string]$vcFail.criterion_map['0'].status -ceq 'unverified')) 'criterion_map marks failed mapping unverified'

    # 10d. explicit per-criterion mapping splits verified/unverified
    $vcMix = Invoke-OrchestrationVerifier -TaskId 'crit-mix-001' -RepoRoot $exitRepo -BaseRevision 'HEAD' -WriteScopes @('allowed') -ProfileNames @('passes', 'fails') -PolicyPath $exitPol -AcceptanceCriteria @('crit-a', 'crit-b') -CriterionProfiles @{0 = @('passes'); 1 = @('fails') }
    Assert-Verifier (([string]$vcMix.status -ceq 'verification_failed')) 'mixed profiles keep verification_failed'
    Assert-Verifier (((( @($vcMix.evidence) -join '|') -match 'criterion:0:verified') -and ((@($vcMix.evidence) -join '|') -match 'criterion:1:unverified'))) 'explicit mapping splits verified/unverified per criterion'

    # 11. git unavailable path
    $g = Test-OrchestrationWriteScope -RepoRoot $exitRepo -BaseRevision 'HEAD' -WriteScopes @('allowed') -GitExecutable 'nonexistent-git-exe-xyz'
    Assert-Verifier ((-not [bool]$g.ok) -and ([string]$g.error -ceq 'GIT_UNAVAILABLE') -and ([string]$g.status -ceq 'manual_verification_required')) 'missing git exe => GIT_UNAVAILABLE/manual_verification_required'
}
catch {
    Write-Host ("[FAIL] unexpected error: {0}" -f $_)
    $script:failed++
}
finally {
    foreach ($r in @($roots)) {
        if (Test-Path -LiteralPath $r) { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host ("OrchestrationVerifier: {0} / {1} tests passed" -f $script:passed, ($script:passed + $script:failed))
if ($script:failed -gt 0) { exit 1 }
exit 0
