$ErrorActionPreference = 'Stop'
$v3 = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($v3) -or -not (Test-Path -LiteralPath $v3 -PathType Container)) {
    $v3 = Join-Path (Split-Path -Parent $PSScriptRoot) 'v3'
}
$lib = Join-Path $v3 'lib\CapabilityAuthority.ps1'
if (-not (Test-Path -LiteralPath $lib -PathType Leaf)) {
    $lib = Join-Path $PSScriptRoot 'CapabilityAuthority.ps1'
}
. $lib

$base = Join-Path ([IO.Path]::GetTempPath()) ('v3-authority-lib-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base -Force | Out-Null

$total = 0
$passed = 0
function Assert-That($condition, $name, $detail) {
    $script:total++
    if ($condition) { $script:passed++; Write-Host "[PASS] $name" }
    else { Write-Host "[FAIL] $name -- $detail" }
}

function Write-Fixture {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $lf = ($Text -replace "`r`n", "`n" -replace "`r", "`n")
    [IO.File]::WriteAllText($Path, $lf, [Text.UTF8Encoding]::new($false))
}

function New-FixtureRepo {
    param([Parameter(Mandatory)][string]$Root)
    $agents = Join-Path $Root 'source\agents'
    $reg = Join-Path $Root 'source\registry'
    New-Item -ItemType Directory -Path $agents -Force | Out-Null
    New-Item -ItemType Directory -Path $reg -Force | Out-Null
    $policy = '{"version":1,"defaults":{"build_delegable":false},"deny_rules":{"visibility":["hidden","internal","experimental"]},"overrides":{}}'
    Write-Fixture -Path (Join-Path $reg 'capability-policy.json') -Text $policy
    $runtimes = '{"version":1,"runtimes":{"opencode":{"id":"opencode","settings_targets":[{"path":"%USERPROFILE%/.config/opencode/opencode.json","format":"json","sections":{"agent.build.permission.task":"control-plane"}}]}}}'
    Write-Fixture -Path (Join-Path $reg 'runtimes.json') -Text $runtimes
    return @{ Agents = $agents; Policy = (Join-Path $reg 'capability-policy.json'); Runtimes = (Join-Path $reg 'runtimes.json'); Root = $Root }
}

function Write-Agent {
    param([Parameter(Mandatory)][string]$AgentsDir, [Parameter(Mandatory)][string]$Name, [string]$Delegable, [string]$Visibility, [switch]$NoOrchestration, [switch]$Malformed)
    $path = Join-Path $AgentsDir ($Name + '.md')
    if ($Malformed) {
        Write-Fixture -Path $path -Text "---`nbroken: [unclosed`n Body sem fechamento"
        return $path
    }
    if ($NoOrchestration) {
        Write-Fixture -Path $path -Text "---`ndescription: $Name`nmode: subagent`n---`nBody.`n"
        return $path
    }
    $delegLine = 'false'
    if ($Delegable -ceq 'true') { $delegLine = 'true' }
    $vis = 'normal'
    if (-not [string]::IsNullOrWhiteSpace($Visibility)) { $vis = $Visibility }
    $body = "---`ndescription: $Name`nmode: subagent`norchestration:`n  build_delegable: $delegLine`n  lifecycle: stable`n  visibility: $vis`n---`nBody.`n"
    Write-Fixture -Path $path -Text $body
    return $path
}

function Write-Config {
    param([Parameter(Mandatory)][string]$Path, [string[]]$Allow)
    $task = New-Object PSCustomObject
    $task | Add-Member -NotePropertyName '*' -NotePropertyValue 'deny'
    $sorted = @()
    if ($null -ne $Allow) { $sorted = @($Allow) }
    [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    foreach ($id in $sorted) { $task | Add-Member -NotePropertyName $id -NotePropertyValue 'allow' }
    $cfg = [ordered]@{
        agent = [ordered]@{ build = [ordered]@{ mode = 'primary'; permission = [ordered]@{ task = $task } } }
    }
    $json = (($cfg | ConvertTo-Json -Depth 10) + "`n")
    Write-Fixture -Path $Path -Text $json
}

function New-Approval {
    param($Request, [string]$Status = 'approved')
    return [PSCustomObject]@{
        change_id     = [string]$Request.change_id
        approval_hash = [string]$Request.approval_hash
        approver      = 'test-human'
        approved_at   = (Get-Date).ToUniversalTime().ToString('o')
        status        = $Status
    }
}

try {
    # --- REQUEST: no change ---
    $r1 = Join-Path $base 'r1'; $fx = New-FixtureRepo -Root $r1
    Write-Agent -AgentsDir $fx.Agents -Name 'coder' -Delegable 'true' | Out-Null
    Write-Agent -AgentsDir $fx.Agents -Name 'tester' -Delegable 'true' | Out-Null
    $cfg1 = Join-Path $r1 'opencode.json'
    Write-Config -Path $cfg1 -Allow @('coder', 'tester')
    $req1 = New-AuthorityChangeRequest -RepoRoot $r1 -ConfigPath $cfg1 -PolicyPath $fx.Policy
    Assert-That ((@($req1.agents_added).Count -eq 0) -and (@($req1.agents_removed).Count -eq 0)) 'Request no-change has empty added/removed' ((@($req1.agents_added) -join ',') + '/' + (@($req1.agents_removed) -join ','))
    Assert-That ((@($req1.drift).Count -eq 0)) 'Request no-change has empty drift' ((@($req1.drift) -join ','))
    Assert-That ([string]$req1.state -ceq 'VALIDATED') 'Request initial state VALIDATED' ([string]$req1.state)
    Assert-That ([string]$req1.change_id -match '^acr-[0-9a-f]{16}$') 'Request change_id format' ([string]$req1.change_id)
    Assert-That ([string]$req1.approval_hash -match '^sha256:[0-9a-f]{64}$') 'Request approval_hash format' ([string]$req1.approval_hash)

    # --- REQUEST: add one ---
    $r2 = Join-Path $base 'r2'; $fx2 = New-FixtureRepo -Root $r2
    Write-Agent -AgentsDir $fx2.Agents -Name 'coder' -Delegable 'true' | Out-Null
    Write-Agent -AgentsDir $fx2.Agents -Name 'tester' -Delegable 'true' | Out-Null
    $cfg2 = Join-Path $r2 'opencode.json'
    Write-Config -Path $cfg2 -Allow @('coder')
    $req2 = New-AuthorityChangeRequest -RepoRoot $r2 -ConfigPath $cfg2 -PolicyPath $fx2.Policy
    Assert-That ((@($req2.agents_added) -join ',') -ceq 'tester') 'Request add-one detects tester' ((@($req2.agents_added) -join ','))
    Assert-That (@($req2.agents_removed).Count -eq 0) 'Request add-one has no removals' ((@($req2.agents_removed) -join ','))

    # --- REQUEST: remove one ---
    $r3 = Join-Path $base 'r3'; $fx3 = New-FixtureRepo -Root $r3
    Write-Agent -AgentsDir $fx3.Agents -Name 'coder' -Delegable 'true' | Out-Null
    $cfg3 = Join-Path $r3 'opencode.json'
    Write-Config -Path $cfg3 -Allow @('coder', 'tester')
    $req3 = New-AuthorityChangeRequest -RepoRoot $r3 -ConfigPath $cfg3 -PolicyPath $fx3.Policy
    Assert-That ((@($req3.agents_removed) -join ',') -ceq 'tester') 'Request remove-one detects tester removal' ((@($req3.agents_removed) -join ','))
    Assert-That ((@($req3.drift) -join ',') -ceq 'tester') 'Request remove-one drift lists tester' ((@($req3.drift) -join ','))

    # --- REQUEST: add+remove ---
    $r4 = Join-Path $base 'r4'; $fx4 = New-FixtureRepo -Root $r4
    Write-Agent -AgentsDir $fx4.Agents -Name 'coder' -Delegable 'true' | Out-Null
    Write-Agent -AgentsDir $fx4.Agents -Name 'tester' -Delegable 'true' | Out-Null
    $cfg4 = Join-Path $r4 'opencode.json'
    Write-Config -Path $cfg4 -Allow @('coder', 'explorer')
    $req4 = New-AuthorityChangeRequest -RepoRoot $r4 -ConfigPath $cfg4 -PolicyPath $fx4.Policy
    Assert-That ((@($req4.agents_added) -join ',') -ceq 'tester') 'Request add+remove added' ((@($req4.agents_added) -join ','))
    Assert-That ((@($req4.agents_removed) -join ',') -ceq 'explorer') 'Request add+remove removed' ((@($req4.agents_removed) -join ','))

    # --- REQUEST: duplicated id dedupes ---
    $r5 = Join-Path $base 'r5'; $fx5 = New-FixtureRepo -Root $r5
    Write-Agent -AgentsDir $fx5.Agents -Name 'coder' -Delegable 'true' | Out-Null
    Write-Agent -AgentsDir $fx5.Agents -Name 'Coder' -Delegable 'true' | Out-Null
    $desired5 = @(Get-DesiredBuildDelegationSet -RepoRoot $r5 -PolicyPath $fx5.Policy -AgentsRoot $fx5.Agents)
    $dupCount = @($desired5 | Where-Object { $_ -ceq 'coder' }).Count
    Assert-That (($dupCount -eq 1) -and (@($desired5).Count -eq 1)) 'Duplicated id dedupes to single entry' ($desired5 -join ',')

    # --- PERMISSION: hidden sem override nao entra ---
    $r6 = Join-Path $base 'r6'; $fx6 = New-FixtureRepo -Root $r6
    Write-Agent -AgentsDir $fx6.Agents -Name 'coder' -Delegable 'true' | Out-Null
    Write-Agent -AgentsDir $fx6.Agents -Name 'ghost-hidden' -Delegable 'true' -Visibility 'hidden' | Out-Null
    $desired6 = @(Get-DesiredBuildDelegationSet -RepoRoot $r6 -PolicyPath $fx6.Policy -AgentsRoot $fx6.Agents)
    Assert-That (($desired6 -ccontains 'coder') -and -not ($desired6 -ccontains 'ghost-hidden')) 'Hidden without override is denied' ($desired6 -join ',')

    # --- PERMISSION: hidden COM override entra ---
    $policyOverride = '{"version":1,"defaults":{"build_delegable":false},"deny_rules":{"visibility":["hidden","internal","experimental"]},"overrides":{"ghost-hidden":{"allow_visibility":true}}}'
    Write-Fixture -Path $fx6.Policy -Text $policyOverride
    $desired6b = @(Get-DesiredBuildDelegationSet -RepoRoot $r6 -PolicyPath $fx6.Policy -AgentsRoot $fx6.Agents)
    Assert-That (($desired6b -ccontains 'ghost-hidden')) 'Hidden with explicit override is allowed' ($desired6b -join ',')

    # --- PERMISSION: non-delegable nunca entra; override nao remove deny ---
    $r7 = Join-Path $base 'r7'; $fx7 = New-FixtureRepo -Root $r7
    Write-Agent -AgentsDir $fx7.Agents -Name 'coder' -Delegable 'true' | Out-Null
    Write-Agent -AgentsDir $fx7.Agents -Name 'locked' -Delegable 'false' -Visibility 'normal' | Out-Null
    $policyLocked = '{"version":1,"defaults":{"build_delegable":false},"deny_rules":{"visibility":["hidden","internal","experimental"]},"overrides":{"locked":{"allow_visibility":true,"allow":true}}}'
    Write-Fixture -Path $fx7.Policy -Text $policyLocked
    $desired7 = @(Get-DesiredBuildDelegationSet -RepoRoot $r7 -PolicyPath $fx7.Policy -AgentsRoot $fx7.Agents)
    Assert-That (-not ($desired7 -ccontains 'locked')) 'Global deny wins: override cannot grant non-delegable' ($desired7 -join ',')

    # --- PERMISSION: discovery alone cannot grant (sem orchestration) ---
    $r8 = Join-Path $base 'r8'; $fx8 = New-FixtureRepo -Root $r8
    Write-Agent -AgentsDir $fx8.Agents -Name 'plain' -NoOrchestration | Out-Null
    Write-Agent -AgentsDir $fx8.Agents -Name 'coder' -Delegable 'true' | Out-Null
    $desired8 = @(Get-DesiredBuildDelegationSet -RepoRoot $r8 -PolicyPath $fx8.Policy -AgentsRoot $fx8.Agents)
    Assert-That (-not ($desired8 -ccontains 'plain')) 'Discovery alone cannot grant (no orchestration)' ($desired8 -join ',')

    # --- PERMISSION: malformed frontmatter => default deny ---
    Write-Agent -AgentsDir $fx8.Agents -Name 'broken' -Malformed | Out-Null
    $desired8b = @(Get-DesiredBuildDelegationSet -RepoRoot $r8 -PolicyPath $fx8.Policy -AgentsRoot $fx8.Agents)
    Assert-That (-not ($desired8b -ccontains 'broken')) 'Malformed orchestration defaults to deny' ($desired8b -join ',')

    # --- PERMISSION: unknown agent in config becomes drift, not proposed ---
    $cfg8 = Join-Path $r8 'opencode.json'
    Write-Config -Path $cfg8 -Allow @('coder', 'ghost-external')
    $req8 = New-AuthorityChangeRequest -RepoRoot $r8 -ConfigPath $cfg8 -PolicyPath $fx8.Policy
    Assert-That ((@($req8.drift) -ccontains 'ghost-external')) 'Unknown external entry appears in drift' ((@($req8.drift) -join ','))
    Assert-That (-not (@($req8.proposed_allowlist) -ccontains 'ghost-external')) 'Unknown entry does not survive in proposed_allowlist' ((@($req8.proposed_allowlist) -join ','))

    # --- REQUEST determinism ---
    $req8b = New-AuthorityChangeRequest -RepoRoot $r8 -ConfigPath $cfg8 -PolicyPath $fx8.Policy
    Assert-That (([string]$req8b.approval_hash -ceq [string]$req8.approval_hash) -and ([string]$req8b.change_id -ceq [string]$req8.change_id)) 'Determinism: same state yields same hash/id' ([string]$req8.approval_hash)

    # --- APPROVAL: valid ---
    $apprValid = New-Approval -Request $req8
    $chkValid = Test-AuthorityApproval -Request $req8 -ApprovalRecord $apprValid -RepoRoot $r8 -ConfigPath $cfg8 -PolicyPath $fx8.Policy -AgentsRoot $fx8.Agents
    Assert-That ([bool]$chkValid.Valid) 'Approval valid passes' (($chkValid.Reasons -join '|'))

    # --- APPROVAL: wrong change_id ---
    $apprBadId = New-Approval -Request $req8
    $apprBadId.change_id = 'acr-0000000000000000'
    $chkBadId = Test-AuthorityApproval -Request $req8 -ApprovalRecord $apprBadId -RepoRoot $r8 -ConfigPath $cfg8 -PolicyPath $fx8.Policy -AgentsRoot $fx8.Agents
    Assert-That (-not [bool]$chkBadId.Valid) 'Approval wrong change_id fails' (($chkBadId.Reasons -join '|'))

    # --- APPROVAL: wrong hash ---
    $apprBadHash = New-Approval -Request $req8
    $apprBadHash.approval_hash = 'sha256:0000000000000000000000000000000000000000000000000000000000000000'
    $chkBadHash = Test-AuthorityApproval -Request $req8 -ApprovalRecord $apprBadHash -RepoRoot $r8 -ConfigPath $cfg8 -PolicyPath $fx8.Policy -AgentsRoot $fx8.Agents
    Assert-That (-not [bool]$chkBadHash.Valid) 'Approval wrong hash fails' (($chkBadHash.Reasons -join '|'))

    # --- APPROVAL: missing ---
    $chkMissing = Test-AuthorityApproval -Request $req8 -ApprovalRecord $null -RepoRoot $r8 -ConfigPath $cfg8 -PolicyPath $fx8.Policy -AgentsRoot $fx8.Agents
    Assert-That (-not [bool]$chkMissing.Valid) 'Approval missing fails' (($chkMissing.Reasons -join '|'))

    # --- APPROVAL: rejected ---
    $apprRejected = New-Approval -Request $req8 -Status 'rejected'
    $chkRejected = Test-AuthorityApproval -Request $req8 -ApprovalRecord $apprRejected -RepoRoot $r8 -ConfigPath $cfg8 -PolicyPath $fx8.Policy -AgentsRoot $fx8.Agents
    Assert-That (-not [bool]$chkRejected.Valid) 'Approval rejected status fails' (($chkRejected.Reasons -join '|'))

    # --- APPROVAL: stale base hash (mudar config apos request) ---
    Write-Config -Path $cfg8 -Allow @('coder')
    $chkStaleBase = Test-AuthorityApproval -Request $req8 -ApprovalRecord $apprValid -RepoRoot $r8 -ConfigPath $cfg8 -PolicyPath $fx8.Policy -AgentsRoot $fx8.Agents
    Assert-That (-not [bool]$chkStaleBase.Valid) 'Approval stale base hash fails' (($chkStaleBase.Reasons -join '|'))
    Write-Config -Path $cfg8 -Allow @('coder', 'ghost-external')

    # --- APPROVAL: changed policy after approval ---
    $chkPolicyOk = Test-AuthorityApproval -Request $req8 -ApprovalRecord $apprValid -RepoRoot $r8 -ConfigPath $cfg8 -PolicyPath $fx8.Policy -AgentsRoot $fx8.Agents
    Assert-That ([bool]$chkPolicyOk.Valid) 'Approval still valid before policy change' (($chkPolicyOk.Reasons -join '|'))
    $policyChanged = '{"version":1,"defaults":{"build_delegable":false},"deny_rules":{"visibility":["hidden"]},"overrides":{}}'
    Write-Fixture -Path $fx8.Policy -Text $policyChanged
    $chkPolicyStale = Test-AuthorityApproval -Request $req8 -ApprovalRecord $apprValid -RepoRoot $r8 -ConfigPath $cfg8 -PolicyPath $fx8.Policy -AgentsRoot $fx8.Agents
    Assert-That (-not [bool]$chkPolicyStale.Valid) 'Approval changed policy after approval fails' (($chkPolicyStale.Reasons -join '|'))

    # --- APPROVAL: changed source agent after approval ---
    $r9 = Join-Path $base 'r9'; $fx9 = New-FixtureRepo -Root $r9
    Write-Agent -AgentsDir $fx9.Agents -Name 'coder' -Delegable 'true' | Out-Null
    $cfg9 = Join-Path $r9 'opencode.json'
    Write-Config -Path $cfg9 -Allow @('coder')
    $req9 = New-AuthorityChangeRequest -RepoRoot $r9 -ConfigPath $cfg9 -PolicyPath $fx9.Policy
    $appr9 = New-Approval -Request $req9
    $chk9ok = Test-AuthorityApproval -Request $req9 -ApprovalRecord $appr9 -RepoRoot $r9 -ConfigPath $cfg9 -PolicyPath $fx9.Policy -AgentsRoot $fx9.Agents
    Assert-That ([bool]$chk9ok.Valid) 'Approval source baseline valid' (($chk9ok.Reasons -join '|'))
    Write-Agent -AgentsDir $fx9.Agents -Name 'tester' -Delegable 'true' | Out-Null
    $chk9stale = Test-AuthorityApproval -Request $req9 -ApprovalRecord $appr9 -RepoRoot $r9 -ConfigPath $cfg9 -PolicyPath $fx9.Policy -AgentsRoot $fx9.Agents
    Assert-That (-not [bool]$chk9stale.Valid) 'Approval changed source agent after approval fails' (($chk9stale.Reasons -join '|'))

    # --- STATE MACHINE ---
    $st1 = Set-AuthorityRequestState -Request $req9 -NewState 'AWAITING_HUMAN_APPROVAL'
    Assert-That ([string]$st1.state -ceq 'AWAITING_HUMAN_APPROVAL') 'State VALIDATED->AWAITING_HUMAN_APPROVAL' ([string]$st1.state)
    $threw = $false
    try { Set-AuthorityRequestState -Request $req9 -NewState 'APPLIED_TO_DISK' | Out-Null } catch { $threw = $true }
    Assert-That ($threw) 'Illegal transition VALIDATED->APPLIED_TO_DISK throws' 'no throw'

    # --- APPLY: CAS success + backup + rollback + atomic ---
    $ra = Join-Path $base 'ra'; $fxa = New-FixtureRepo -Root $ra
    Write-Agent -AgentsDir $fxa.Agents -Name 'coder' -Delegable 'true' | Out-Null
    Write-Agent -AgentsDir $fxa.Agents -Name 'tester' -Delegable 'true' | Out-Null
    $cfgA = Join-Path $ra 'fixture-config\opencode.json'
    Write-Config -Path $cfgA -Allow @('coder')
    $testRootA = Join-Path $ra 'fixture-config'
    $reqA = New-AuthorityChangeRequest -RepoRoot $ra -ConfigPath $cfgA -PolicyPath $fxa.Policy
    $apprA = New-Approval -Request $reqA
    $beforeBytes = [IO.File]::ReadAllBytes($cfgA)
    $bkA = Join-Path $ra 'backups'
    $storeA = Join-Path $ra 'reload-state.json'
    $resA = Invoke-AuthorityApply -Request $reqA -ApprovalRecord $apprA -ConfigPath $cfgA -BackupRoot $bkA -ReloadStorePath $storeA -FixtureRoot $testRootA -RepoRoot $ra -PolicyPath $fxa.Policy -AgentsRoot $fxa.Agents
    Assert-That ([string]$resA.Status -ceq 'applied') 'Apply CAS success applies' ([string]$resA.Status)
    $afterAllow = @(Get-CurrentBuildAllowlist -ConfigPath $cfgA)
    Assert-That ((($afterAllow -join ',') -ceq 'coder,tester')) 'Apply atomic replace updates allowlist' ($afterAllow -join ',')
    Assert-That ((Test-Path -LiteralPath ([string]$resA.BackupPath) -PathType Leaf)) 'Apply backup criado' ([string]$resA.BackupPath)
    $backupBytes = [IO.File]::ReadAllBytes([string]$resA.BackupPath)
    $backupSame = ($backupBytes.Length -eq $beforeBytes.Length)
    if ($backupSame) {
        for ($i = 0; $i -lt $backupBytes.Length; $i++) {
            if ($backupBytes[$i] -ne $beforeBytes[$i]) { $backupSame = $false; break }
        }
    }
    Assert-That ($backupSame) 'Backup matches pre-apply bytes (restore source)' 'bytes differ'
    Assert-That ((Test-Path -LiteralPath ([string]$resA.RollbackPath) -PathType Leaf)) 'Apply rollback.json exists' ([string]$resA.RollbackPath)
    $rbA = Get-Content -LiteralPath ([string]$resA.RollbackPath) -Raw | ConvertFrom-Json
    Assert-That ([string]$rbA.status -ceq 'applied-and-verified') 'rollback.json applied-and-verified' ([string]$rbA.status)
    $leftovers = @(Get-ChildItem -LiteralPath $testRootA -Filter '*.tmp' -File -ErrorAction SilentlyContinue)
    Assert-That ($leftovers.Count -eq 0) 'Apply leaves no temp files' ("$($leftovers.Count) leftover(s)")

    # --- APPLY: idempotent retry (mesmo request apos sucesso => noop) ---
    $resRetry = Invoke-AuthorityApply -Request $reqA -ApprovalRecord $apprA -ConfigPath $cfgA -BackupRoot $bkA -ReloadStorePath $storeA -FixtureRoot $testRootA -RepoRoot $ra -PolicyPath $fxa.Policy -AgentsRoot $fxa.Agents
    Assert-That ([string]$resRetry.Status -ceq 'noop') 'Retry do mesmo request apos sucesso e noop' ([string]$resRetry.Status)

    # --- APPLY: restore from backup ---
    Copy-Item -LiteralPath ([string]$resA.BackupPath) -Destination $cfgA -Force
    $restoredAllow = @(Get-CurrentBuildAllowlist -ConfigPath $cfgA)
    Assert-That ((($restoredAllow -join ',') -ceq 'coder')) 'Restore from backup recovers prior allowlist' ($restoredAllow -join ',')

    # --- APPLY: idempotent 2nd run ---
    $resA2 = Invoke-AuthorityApply -Request $reqA -ApprovalRecord $apprA -ConfigPath $cfgA -BackupRoot $bkA -ReloadStorePath $storeA -FixtureRoot $testRootA -RepoRoot $ra -PolicyPath $fxa.Policy -AgentsRoot $fxa.Agents
    $afterFirst = @(Get-CurrentBuildAllowlist -ConfigPath $cfgA)
    Assert-That ((($afterFirst -join ',') -ceq 'coder,tester')) 'Re-apply reaches desired (setup for idempotence)' ($afterFirst -join ',')
    $reqA2 = New-AuthorityChangeRequest -RepoRoot $ra -ConfigPath $cfgA -PolicyPath $fxa.Policy
    $apprA2 = New-Approval -Request $reqA2
    $resA3 = Invoke-AuthorityApply -Request $reqA2 -ApprovalRecord $apprA2 -ConfigPath $cfgA -BackupRoot $bkA -ReloadStorePath $storeA -FixtureRoot $testRootA -RepoRoot $ra -PolicyPath $fxa.Policy -AgentsRoot $fxa.Agents
    Assert-That ([string]$resA3.Status -ceq 'noop') 'Idempotent 2nd run is no-op' ([string]$resA3.Status)

    # --- REQUEST no-op: target == base quando sem diff ---
    Assert-That ([string]$reqA2.target_config_hash -ceq [string]$reqA2.base_config_hash) 'No-op request tem target_config_hash == base_config_hash' (([string]$reqA2.target_config_hash) + ' vs ' + ([string]$reqA2.base_config_hash))

    # --- PARSER estrito: orchestration duplicado => deny ---
    $rP = Join-Path $base 'rp'; $fxP = New-FixtureRepo -Root $rP
    $dupOrch = "---`ndescription: x`nmode: subagent`norchestration:`n  build_delegable: true`n  lifecycle: stable`n  visibility: normal`norchestration:`n  build_delegable: true`n---`nBody.`n"
    Write-Fixture -Path (Join-Path $fxP.Agents 'dup.md') -Text $dupOrch
    Write-Agent -AgentsDir $fxP.Agents -Name 'coder' -Delegable 'true' | Out-Null
    $desP = @(Get-DesiredBuildDelegationSet -RepoRoot $rP -PolicyPath $fxP.Policy -AgentsRoot $fxP.Agents)
    Assert-That (-not ($desP -ccontains 'dup')) 'Parser: orchestration duplicado => deny' ($desP -join ',')
    $orchDup = Read-AgentOrchestration -Path (Join-Path $fxP.Agents 'dup.md')
    Assert-That ((-not [bool]$orchDup.Valid) -and -not [bool]$orchDup.BuildDelegable) 'Parser: duplicado carrega diagnostico' ([string]$orchDup.Error)

    # --- PARSER estrito: chave duplicada / desconhecida / alias / visibility invalida ---
    Write-Fixture -Path (Join-Path $fxP.Agents 'dupkey.md') -Text ("---`ndescription: x`nmode: subagent`norchestration:`n  build_delegable: true`n  build_delegable: true`n  lifecycle: stable`n  visibility: normal`n---`nBody.`n")
    Write-Fixture -Path (Join-Path $fxP.Agents 'unknown.md') -Text ("---`ndescription: x`nmode: subagent`norchestration:`n  build_delegable: true`n  lifecycle: stable`n  visibility: normal`n  superpower: true`n---`nBody.`n")
    Write-Fixture -Path (Join-Path $fxP.Agents 'alias.md') -Text ("---`ndescription: x`nmode: subagent`norchestration:`n  build_delegable: true`n  lifecycle: stable`n  visibility: normal`n  capabilities: *ref`n---`nBody.`n")
    Write-Fixture -Path (Join-Path $fxP.Agents 'badvis.md') -Text ("---`ndescription: x`nmode: subagent`norchestration:`n  build_delegable: true`n  lifecycle: stable`n  visibility: uber`n---`nBody.`n")
    Write-Fixture -Path (Join-Path $fxP.Agents 'nonbool.md') -Text ("---`ndescription: x`nmode: subagent`norchestration:`n  build_delegable: yes`n  lifecycle: stable`n  visibility: normal`n---`nBody.`n")
    Write-Fixture -Path (Join-Path $fxP.Agents 'topdup.md') -Text ("---`ndescription: x`ndescription: y`nmode: subagent`norchestration:`n  build_delegable: true`n  lifecycle: stable`n  visibility: normal`n---`nBody.`n")
    $desP2 = @(Get-DesiredBuildDelegationSet -RepoRoot $rP -PolicyPath $fxP.Policy -AgentsRoot $fxP.Agents)
    foreach ($n in @('dupkey', 'unknown', 'alias', 'badvis', 'nonbool', 'topdup')) {
        Assert-That (-not ($desP2 -ccontains $n)) ("Parser: $n => deny") ($desP2 -join ',')
    }

    # --- OVERRIDE: so allow_visibility:true libera; allow:true nao ---
    $rO = Join-Path $base 'ro'; $fxO = New-FixtureRepo -Root $rO
    Write-Agent -AgentsDir $fxO.Agents -Name 'shy' -Delegable 'true' -Visibility 'hidden' | Out-Null
    Write-Fixture -Path $fxO.Policy -Text '{"version":1,"defaults":{"build_delegable":false},"deny_rules":{"visibility":["hidden","internal","experimental"]},"overrides":{"shy":{"allow":true}}}'
    $desO = @(Get-DesiredBuildDelegationSet -RepoRoot $rO -PolicyPath $fxO.Policy -AgentsRoot $fxO.Agents)
    Assert-That (-not ($desO -ccontains 'shy')) 'Override alias allow:true nao libera' ($desO -join ',')
    Write-Fixture -Path $fxO.Policy -Text '{"version":1,"defaults":{"build_delegable":false},"deny_rules":{"visibility":["hidden","internal","experimental"]},"overrides":{"shy":{"allow_visibility":"true"}}}'
    $desO2 = @(Get-DesiredBuildDelegationSet -RepoRoot $rO -PolicyPath $fxO.Policy -AgentsRoot $fxO.Agents)
    Assert-That (-not ($desO2 -ccontains 'shy')) 'Override string allow_visibility nao libera (exige bool)' ($desO2 -join ',')

    # --- OWNERSHIP: runtimes.json sem declaracao => request falha ---
    $rW = Join-Path $base 'rw'; $fxW = New-FixtureRepo -Root $rW
    Write-Agent -AgentsDir $fxW.Agents -Name 'coder' -Delegable 'true' | Out-Null
    $cfgW = Join-Path $rW 'opencode.json'
    Write-Config -Path $cfgW -Allow @('coder')
    Write-Fixture -Path $fxW.Runtimes -Text '{"version":1,"runtimes":{"opencode":{"id":"opencode","settings_targets":[{"path":"%USERPROFILE%/.config/opencode/opencode.json","format":"json","sections":{"mcp":"shared"}}]}}}'
    $ownThrew = $false
    try { New-AuthorityChangeRequest -RepoRoot $rW -ConfigPath $cfgW -PolicyPath $fxW.Policy | Out-Null } catch { $ownThrew = $true }
    Assert-That ($ownThrew) 'Ownership sem declaracao falha o request' 'request passou sem ownership'

    # --- DRIFT bloqueia apply sem tocar o config ---
    $rD = Join-Path $base 'rd'; $fxD = New-FixtureRepo -Root $rD
    Write-Agent -AgentsDir $fxD.Agents -Name 'coder' -Delegable 'true' | Out-Null
    $cfgD = Join-Path $rD 'fix\opencode.json'
    Write-Config -Path $cfgD -Allow @('coder', 'ghost-external')
    $reqD = New-AuthorityChangeRequest -RepoRoot $rD -ConfigPath $cfgD -PolicyPath $fxD.Policy
    $apprD = New-Approval -Request $reqD
    $hashDBefore = (Get-FileHash -LiteralPath $cfgD -Algorithm SHA256).Hash
    $driftThrew = $false; $driftMsg = ''
    try {
        Invoke-AuthorityApply -Request $reqD -ApprovalRecord $apprD -ConfigPath $cfgD -BackupRoot (Join-Path $rD 'bk') -ReloadStorePath (Join-Path $rD 'reload.json') -FixtureRoot (Join-Path $rD 'fix') -RepoRoot $rD -PolicyPath $fxD.Policy -AgentsRoot $fxD.Agents | Out-Null
    } catch { $driftThrew = $true; $driftMsg = $_.Exception.Message }
    $hashDAfter = (Get-FileHash -LiteralPath $cfgD -Algorithm SHA256).Hash
    Assert-That ($driftThrew -and ($driftMsg -match 'DRIFT')) 'Drift bloqueia apply' $driftMsg
    Assert-That ($hashDBefore -ceq $hashDAfter) 'Drift bloqueado nao toca o config' "$hashDBefore vs $hashDAfter"

    # --- BOUNDARY: FixtureRoot no profile real => rejeita ---
    $realLike = Join-Path $env:USERPROFILE '.config\opencode'
    $boundThrew = $false
    try {
        Invoke-AuthorityApply -Request $reqA -ApprovalRecord $apprA -ConfigPath $cfgA -BackupRoot $bkA -ReloadStorePath $storeA -FixtureRoot $realLike -RepoRoot $ra -PolicyPath $fxa.Policy -AgentsRoot $fxa.Agents | Out-Null
    } catch { $boundThrew = $true }
    Assert-That ($boundThrew) 'FixtureRoot no profile real e rejeitado' 'apply passou com FixtureRoot real'

    # --- BOUNDARY: config real sempre rejeitado (mesmo sob TEMP aparente) ---
    $realCfg = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
    if (Test-Path -LiteralPath $realCfg -PathType Leaf) {
        $boundReal = $false
        try {
            Invoke-AuthorityApply -Request $reqA -ApprovalRecord $apprA -ConfigPath $realCfg -BackupRoot $bkA -ReloadStorePath $storeA -FixtureRoot ([IO.Path]::GetTempPath()) -RepoRoot $ra -PolicyPath $fxa.Policy -AgentsRoot $fxa.Agents | Out-Null
        } catch { $boundReal = $true }
        Assert-That ($boundReal) 'ConfigPath real e sempre rejeitado' 'apply passou no config real'
    }

    # --- BOUNDARY: reparse point (junction) rejeitado ---
    $rJ = Join-Path $base 'rj'; $fxJ = New-FixtureRepo -Root $rJ
    Write-Agent -AgentsDir $fxJ.Agents -Name 'coder' -Delegable 'true' | Out-Null
    Write-Agent -AgentsDir $fxJ.Agents -Name 'tester' -Delegable 'true' | Out-Null
    $realDirJ = Join-Path $rJ 'realdir'
    New-Item -ItemType Directory -Path $realDirJ -Force | Out-Null
    $cfgJ = Join-Path $realDirJ 'opencode.json'
    Write-Config -Path $cfgJ -Allow @('coder')
    $reqJ = New-AuthorityChangeRequest -RepoRoot $rJ -ConfigPath $cfgJ -PolicyPath $fxJ.Policy
    $linkJ = Join-Path $rJ 'linkdir'
    $junctionOk = $true
    try { New-Item -ItemType Junction -Path $linkJ -Target $realDirJ -ErrorAction Stop | Out-Null } catch { $junctionOk = $false }
    if ($junctionOk) {
        $apprJ = New-Approval -Request $reqJ
        $reparseThrew = $false
        try {
            Invoke-AuthorityApply -Request $reqJ -ApprovalRecord $apprJ -ConfigPath (Join-Path $linkJ 'opencode.json') -BackupRoot (Join-Path $rJ 'bk') -ReloadStorePath (Join-Path $rJ 'reload.json') -FixtureRoot $linkJ -RepoRoot $rJ -PolicyPath $fxJ.Policy -AgentsRoot $fxJ.Agents | Out-Null
        } catch { $reparseThrew = $true }
        Assert-That ($reparseThrew) 'Reparse point (junction) bloqueia apply' 'apply passou via junction'
    } else {
        Assert-That ($true) 'Reparse point (junction indisponivel; skip)' 'sem privilegio de junction'
    }

    # --- BOUNDARY: hard link (NOT a reparse point) must be allowed (Orca-shared config) ---
    $hlTarget = Join-Path $base 'hl-target.json'
    Write-Fixture -Path $hlTarget -Text '{ "agent": { "build": { "permission": { "task": { "*": "deny", "coder": "allow" } } } } }'
    $hlLink = Join-Path $base 'hl-link.json'
    $hlOk = $true
    try { New-Item -ItemType HardLink -Path $hlLink -Target $hlTarget -ErrorAction Stop | Out-Null } catch { $hlOk = $false }
    if ($hlOk) {
        Assert-That (-not (Test-AuthorityPathHasReparsePoint -Path $hlLink)) 'HardLink nao e tratado como reparse (permitido)' 'hardlink bloqueado'
        Assert-That (([string](Get-Item -LiteralPath $hlLink -Force).LinkType) -ieq 'HardLink') 'HardLink confirmado pelo SO' 'linktype diferente'
    } else {
        Assert-That ($true) 'HardLink indisponivel (skip)' 'sem privilegio de hardlink'
    }

    # --- ROLLBACK automatico: falha pos-replace simulada => ROLLED_BACK ---
    $rB = Join-Path $base 'rb'; $fxB = New-FixtureRepo -Root $rB
    Write-Agent -AgentsDir $fxB.Agents -Name 'coder' -Delegable 'true' | Out-Null
    Write-Agent -AgentsDir $fxB.Agents -Name 'tester' -Delegable 'true' | Out-Null
    $cfgB = Join-Path $rB 'fix\opencode.json'
    Write-Config -Path $cfgB -Allow @('coder')
    $reqB = New-AuthorityChangeRequest -RepoRoot $rB -ConfigPath $cfgB -PolicyPath $fxB.Policy
    $apprB = New-Approval -Request $reqB
    $hashBBefore = (Get-FileHash -LiteralPath $cfgB -Algorithm SHA256).Hash
    $resB = Invoke-AuthorityApply -Request $reqB -ApprovalRecord $apprB -ConfigPath $cfgB -BackupRoot (Join-Path $rB 'bk') -ReloadStorePath (Join-Path $rB 'reload.json') -FixtureRoot (Join-Path $rB 'fix') -RepoRoot $rB -PolicyPath $fxB.Policy -AgentsRoot $fxB.Agents -SimulatePostReplaceMismatch
    Assert-That ([string]$resB.Status -ceq 'ROLLED_BACK') 'Falha pos-replace => ROLLED_BACK' ([string]$resB.Status)
    $hashBAfter = (Get-FileHash -LiteralPath $cfgB -Algorithm SHA256).Hash
    Assert-That ($hashBBefore -ceq $hashBAfter) 'ROLLED_BACK restaura o config byte-a-byte' "$hashBBefore vs $hashBAfter"
    $rbDoc = Get-Content -LiteralPath ([string]$resB.RollbackPath) -Raw | ConvertFrom-Json
    Assert-That ([string]$rbDoc.status -ceq 'ROLLED_BACK') 'rollback.json marca ROLLED_BACK' ([string]$rbDoc.status)

    # --- APPLY: CAS conflict (base diverge sem convergir ao alvo) ---
    $rc = Join-Path $base 'rc'; $fxc = New-FixtureRepo -Root $rc
    Write-Agent -AgentsDir $fxc.Agents -Name 'coder' -Delegable 'true' | Out-Null
    $cfgC = Join-Path $rc 'fix\opencode.json'
    Write-Config -Path $cfgC -Allow @('coder')
    $reqC = New-AuthorityChangeRequest -RepoRoot $rc -ConfigPath $cfgC -PolicyPath $fxc.Policy
    $apprC = New-Approval -Request $reqC
    Write-Config -Path $cfgC -Allow @('coder', 'tester')
    $casThrew = $false
    $casMsg = ''
    try {
        Invoke-AuthorityApply -Request $reqC -ApprovalRecord $apprC -ConfigPath $cfgC -BackupRoot (Join-Path $rc 'bk') -ReloadStorePath (Join-Path $rc 'reload.json') -FixtureRoot (Join-Path $rc 'fix') -RepoRoot $rc -PolicyPath $fxc.Policy -AgentsRoot $fxc.Agents | Out-Null
    }
    catch { $casThrew = $true; $casMsg = $_.Exception.Message }
    Assert-That ($casThrew -and ($casMsg -match 'CAS|STALE|stale|approval|DRIFT')) 'CAS/stale conflict aborts apply' $casMsg
    $afterCas = @(Get-CurrentBuildAllowlist -ConfigPath $cfgC)
    Assert-That ((($afterCas -join ',') -ceq 'coder,tester')) 'CAS abort leaves changed target untouched' ($afterCas -join ',')

    # --- APPLY: falha antes do replace nao altera ---
    $rf = Join-Path $base 'rf'; $fxf = New-FixtureRepo -Root $rf
    Write-Agent -AgentsDir $fxf.Agents -Name 'coder' -Delegable 'true' | Out-Null
    Write-Agent -AgentsDir $fxf.Agents -Name 'tester' -Delegable 'true' | Out-Null
    $cfgF = Join-Path $rf 'fix\opencode.json'
    Write-Config -Path $cfgF -Allow @('coder')
    $reqF = New-AuthorityChangeRequest -RepoRoot $rf -ConfigPath $cfgF -PolicyPath $fxf.Policy
    $apprF = New-Approval -Request $reqF
    $hashBefore = (Get-FileHash -LiteralPath $cfgF -Algorithm SHA256).Hash
    $preThrew = $false
    try {
        Invoke-AuthorityApply -Request $reqF -ApprovalRecord $apprF -ConfigPath $cfgF -BackupRoot (Join-Path $rf 'bk') -ReloadStorePath (Join-Path $rf 'reload.json') -FixtureRoot (Join-Path $rf 'fix') -RepoRoot $rf -PolicyPath $fxf.Policy -AgentsRoot $fxf.Agents -SimulatePreReplaceFailure | Out-Null
    }
    catch { $preThrew = $true }
    $hashAfter = (Get-FileHash -LiteralPath $cfgF -Algorithm SHA256).Hash
    Assert-That ($preThrew -and ($hashBefore -ceq $hashAfter)) 'Pre-replace failure leaves file untouched' "$hashBefore vs $hashAfter"

    # --- APPLY sem FixtureRoot lanca (exit 2 no CLI) ---
    $noTestThrew = $false
    $noTestMsg = ''
    try {
        Invoke-AuthorityApply -Request $reqF -ApprovalRecord $apprF -ConfigPath $cfgF -BackupRoot (Join-Path $rf 'bk2') -ReloadStorePath (Join-Path $rf 'reload2.json') | Out-Null
    }
    catch { $noTestThrew = $true; $noTestMsg = $_.Exception.Message }
    Assert-That ($noTestThrew -and ($noTestMsg -match 'bloqueado')) 'Apply sem FixtureRoot lanca (bloqueado)' $noTestMsg
    # --- APPLY com -TestRoot legado lanca ---
    $legacyThrew = $false
    try {
        Invoke-AuthorityApply -Request $reqF -ApprovalRecord $apprF -ConfigPath $cfgF -BackupRoot (Join-Path $rf 'bk3') -ReloadStorePath (Join-Path $rf 'reload3.json') -FixtureRoot (Join-Path $rf 'fix') -TestRoot (Join-Path $rf 'fix') | Out-Null
    }
    catch { $legacyThrew = $true }
    Assert-That ($legacyThrew) 'Apply com -TestRoot legado lanca (removido)' 'aceitou -TestRoot'

    # --- PARSER: tokens YAML inline/flow em QUALQUER posicao de orchestration => deny ---
    $rT = Join-Path $base 'rt'; $fxT = New-FixtureRepo -Root $rT
    Write-Agent -AgentsDir $fxT.Agents -Name 'coder' -Delegable 'true' | Out-Null
    Write-Fixture -Path (Join-Path $fxT.Agents 'flowanchor.md') -Text ("---`ndescription: x`nmode: subagent`norchestration:`n  build_delegable: true`n  lifecycle: stable`n  visibility: normal`n  capabilities: [ &ref x ]`n---`nBody.`n")
    Write-Fixture -Path (Join-Path $fxT.Agents 'tagbool.md') -Text ("---`ndescription: x`nmode: subagent`norchestration:`n  build_delegable: !!bool true`n  lifecycle: stable`n  visibility: normal`n---`nBody.`n")
    Write-Fixture -Path (Join-Path $fxT.Agents 'aliasval.md') -Text ("---`ndescription: x`nmode: subagent`norchestration:`n  build_delegable: true`n  lifecycle: stable`n  visibility: normal`n  x: *anchor`n---`nBody.`n")
    Write-Fixture -Path (Join-Path $fxT.Agents 'mergemd.md') -Text ("---`ndescription: x`nmode: subagent`norchestration:`n  build_delegable: true`n  lifecycle: stable`n  visibility: normal`n  <<: *merge`n---`nBody.`n")
    Write-Fixture -Path (Join-Path $fxT.Agents 'topalias.md') -Text ("---`ndescription: x`nx: *anchor`nmode: subagent`norchestration:`n  build_delegable: true`n  lifecycle: stable`n  visibility: normal`n---`nBody.`n")
    $desT = @(Get-DesiredBuildDelegationSet -RepoRoot $rT -PolicyPath $fxT.Policy -AgentsRoot $fxT.Agents)
    foreach ($n in @('flowanchor', 'tagbool', 'aliasval', 'mergemd', 'topalias')) {
        Assert-That (-not ($desT -ccontains $n)) ("Parser inline/flow token: $n => deny") ($desT -join ',')
        $orchT = Read-AgentOrchestration -Path (Join-Path $fxT.Agents ($n + '.md'))
        Assert-That ((-not [bool]$orchT.Valid) -and -not [bool]$orchT.BuildDelegable) ("Parser inline/flow token diagnostico: $n") ([string]$orchT.Error)
    }
    Assert-That (($desT -ccontains 'coder')) 'Parser inline/flow: agente legitimo preservado' ($desT -join ',')

    # --- NOOP: retry valido => noop; retry com policy alterada => STALE (nao noop) ---
    $rN = Join-Path $base 'rn'; $fxN = New-FixtureRepo -Root $rN
    Write-Agent -AgentsDir $fxN.Agents -Name 'coder' -Delegable 'true' | Out-Null
    Write-Agent -AgentsDir $fxN.Agents -Name 'tester' -Delegable 'true' | Out-Null
    $cfgN = Join-Path $rN 'fix\opencode.json'
    Write-Config -Path $cfgN -Allow @('coder')
    $reqN = New-AuthorityChangeRequest -RepoRoot $rN -ConfigPath $cfgN -PolicyPath $fxN.Policy
    $apprN = New-Approval -Request $reqN
    $resN = Invoke-AuthorityApply -Request $reqN -ApprovalRecord $apprN -ConfigPath $cfgN -BackupRoot (Join-Path $rN 'bk') -ReloadStorePath (Join-Path $rN 'reload.json') -FixtureRoot (Join-Path $rN 'fix') -RepoRoot $rN -PolicyPath $fxN.Policy -AgentsRoot $fxN.Agents
    Assert-That ([string]$resN.Status -ceq 'applied') 'Noop setup: apply inicial sucede' ([string]$resN.Status)
    $resNNoop = Invoke-AuthorityApply -Request $reqN -ApprovalRecord $apprN -ConfigPath $cfgN -BackupRoot (Join-Path $rN 'bk') -ReloadStorePath (Join-Path $rN 'reload.json') -FixtureRoot (Join-Path $rN 'fix') -RepoRoot $rN -PolicyPath $fxN.Policy -AgentsRoot $fxN.Agents
    Assert-That ([string]$resNNoop.Status -ceq 'noop') 'Retry valido apos apply => noop' ([string]$resNNoop.Status)
    $policyBackupN = [IO.File]::ReadAllText($fxN.Policy)
    Write-Fixture -Path $fxN.Policy -Text '{"version":1,"defaults":{"build_delegable":false},"deny_rules":{"visibility":["hidden"]},"overrides":{}}'
    $staleNoopThrew = $false; $staleNoopMsg = ''
    try {
        Invoke-AuthorityApply -Request $reqN -ApprovalRecord $apprN -ConfigPath $cfgN -BackupRoot (Join-Path $rN 'bk') -ReloadStorePath (Join-Path $rN 'reload.json') -FixtureRoot (Join-Path $rN 'fix') -RepoRoot $rN -PolicyPath $fxN.Policy -AgentsRoot $fxN.Agents | Out-Null
    } catch { $staleNoopThrew = $true; $staleNoopMsg = $_.Exception.Message }
    Write-Fixture -Path $fxN.Policy -Text $policyBackupN
    Assert-That ($staleNoopThrew -and ($staleNoopMsg -match 'STALE')) 'Retry noop com policy alterada => STALE (nao noop)' $staleNoopMsg

    # --- ROLLBACK robusto: falha generica pos-replace => ROLLED_BACK + restore verificado ---
    $rR = Join-Path $base 'rr'; $fxR = New-FixtureRepo -Root $rR
    Write-Agent -AgentsDir $fxR.Agents -Name 'coder' -Delegable 'true' | Out-Null
    Write-Agent -AgentsDir $fxR.Agents -Name 'tester' -Delegable 'true' | Out-Null
    $cfgR = Join-Path $rR 'fix\opencode.json'
    Write-Config -Path $cfgR -Allow @('coder')
    $reqR = New-AuthorityChangeRequest -RepoRoot $rR -ConfigPath $cfgR -PolicyPath $fxR.Policy
    $apprR = New-Approval -Request $reqR
    $hashRBefore = (Get-FileHash -LiteralPath $cfgR -Algorithm SHA256).Hash
    $resR = Invoke-AuthorityApply -Request $reqR -ApprovalRecord $apprR -ConfigPath $cfgR -BackupRoot (Join-Path $rR 'bk') -ReloadStorePath (Join-Path $rR 'reload.json') -FixtureRoot (Join-Path $rR 'fix') -RepoRoot $rR -PolicyPath $fxR.Policy -AgentsRoot $fxR.Agents -SimulatePostReplaceError
    Assert-That ([string]$resR.Status -ceq 'ROLLED_BACK') 'Falha generica pos-replace => ROLLED_BACK' ([string]$resR.Status)
    $hashRAfter = (Get-FileHash -LiteralPath $cfgR -Algorithm SHA256).Hash
    Assert-That ($hashRBefore -ceq $hashRAfter) 'ROLLED_BACK pos-erro restaura bytes originais (hash verificado)' "$hashRBefore vs $hashRAfter"
    $rbR = Get-Content -LiteralPath ([string]$resR.RollbackPath) -Raw | ConvertFrom-Json
    Assert-That ([string]$rbR.status -ceq 'ROLLED_BACK') 'rollback.json marca ROLLED_BACK apos erro generico' ([string]$rbR.status)

    # --- BOOKKEEPING (nao-fatal): falha na escrita de rollback.json => applied + warnings, sem rollback ---
    # Contrato novo: bookkeeping e best-effort; o config ja esta correto e
    # verificado, entao NAO ha rollback. O resultado carrega os erros em
    # warnings[]/bookkeeping_errors[] com status `applied` mantido.
    $rK = Join-Path $base 'rk'; $fxK = New-FixtureRepo -Root $rK
    Write-Agent -AgentsDir $fxK.Agents -Name 'coder' -Delegable 'true' | Out-Null
    Write-Agent -AgentsDir $fxK.Agents -Name 'tester' -Delegable 'true' | Out-Null
    $cfgK = Join-Path $rK 'fix\opencode.json'
    Write-Config -Path $cfgK -Allow @('coder')
    $reqK = New-AuthorityChangeRequest -RepoRoot $rK -ConfigPath $cfgK -PolicyPath $fxK.Policy
    $apprK = New-Approval -Request $reqK
    $resK = Invoke-AuthorityApply -Request $reqK -ApprovalRecord $apprK -ConfigPath $cfgK -BackupRoot (Join-Path $rK 'bk') -ReloadStorePath (Join-Path $rK 'reload.json') -FixtureRoot (Join-Path $rK 'fix') -RepoRoot $rK -PolicyPath $fxK.Policy -AgentsRoot $fxK.Agents -SimulateRollbackWriteFailure
    Assert-That ([string]$resK.Status -ceq 'applied') 'Bookkeeping rollback.json falhou => applied mantido (sem rollback)' ([string]$resK.Status)
    $afterK = @(Get-CurrentBuildAllowlist -ConfigPath $cfgK)
    Assert-That ((($afterK -join ',') -ceq 'coder,tester')) 'Bookkeeping falhou: config permanece aplicado (nao restaurado)' ($afterK -join ',')
    Assert-That ((@($resK.Warnings).Count -gt 0) -and ((@($resK.Warnings) -join '|') -match 'rollback\.json')) 'Bookkeeping rollback.json falhou => warnings[] carrega o erro' ((@($resK.Warnings) -join '|'))
    Assert-That ((@($resK.BookkeepingErrors).Count -gt 0)) 'Bookkeeping rollback.json falhou => bookkeeping_errors[] carrega o erro' ((@($resK.BookkeepingErrors) -join '|'))

    # --- BOOKKEEPING (nao-fatal): falha generica de bookkeeping => applied + warnings, sem rollback ---
    $rK2 = Join-Path $base 'rk2'; $fxK2 = New-FixtureRepo -Root $rK2
    Write-Agent -AgentsDir $fxK2.Agents -Name 'coder' -Delegable 'true' | Out-Null
    Write-Agent -AgentsDir $fxK2.Agents -Name 'tester' -Delegable 'true' | Out-Null
    $cfgK2 = Join-Path $rK2 'fix\opencode.json'
    Write-Config -Path $cfgK2 -Allow @('coder')
    $reqK2 = New-AuthorityChangeRequest -RepoRoot $rK2 -ConfigPath $cfgK2 -PolicyPath $fxK2.Policy
    $apprK2 = New-Approval -Request $reqK2
    $resK2 = Invoke-AuthorityApply -Request $reqK2 -ApprovalRecord $apprK2 -ConfigPath $cfgK2 -BackupRoot (Join-Path $rK2 'bk') -ReloadStorePath (Join-Path $rK2 'reload.json') -FixtureRoot (Join-Path $rK2 'fix') -RepoRoot $rK2 -PolicyPath $fxK2.Policy -AgentsRoot $fxK2.Agents -SimulateBookkeepingFailure
    Assert-That ([string]$resK2.Status -ceq 'applied') 'Bookkeeping generico falhou => applied mantido (sem rollback)' ([string]$resK2.Status)
    $afterK2 = @(Get-CurrentBuildAllowlist -ConfigPath $cfgK2)
    Assert-That ((($afterK2 -join ',') -ceq 'coder,tester')) 'Bookkeeping generico falhou: config permanece aplicado' ($afterK2 -join ',')
    Assert-That ((@($resK2.Warnings).Count -gt 0) -and (@($resK2.BookkeepingErrors).Count -gt 0)) 'Bookkeeping generico falhou => warnings/bookkeeping_errors carregam erros' ((@($resK2.Warnings) -join '|'))

    # --- BOOKKEEPING sob WarningPreference=Stop nao pode disparar rollback ---
    $rStop = Join-Path $base 'warnstop'; $fxStop = New-FixtureRepo -Root $rStop
    Write-Agent -AgentsDir $fxStop.Agents -Name 'coder' -Delegable 'true' | Out-Null
    Write-Agent -AgentsDir $fxStop.Agents -Name 'tester' -Delegable 'true' | Out-Null
    $cfgStop = Join-Path $rStop 'fix\opencode.json'
    Write-Config -Path $cfgStop -Allow @('coder')
    $reqStop = New-AuthorityChangeRequest -RepoRoot $rStop -ConfigPath $cfgStop -PolicyPath $fxStop.Policy
    $apprStop = New-Approval -Request $reqStop
    $prevWp = $WarningPreference; $WarningPreference = 'Stop'
    try {
        $resStop = Invoke-AuthorityApply -Request $reqStop -ApprovalRecord $apprStop -ConfigPath $cfgStop -BackupRoot (Join-Path $rStop 'bk') -ReloadStorePath (Join-Path $rStop 'reload.json') -FixtureRoot (Join-Path $rStop 'fix') -RepoRoot $rStop -PolicyPath $fxStop.Policy -AgentsRoot $fxStop.Agents -SimulateBookkeepingFailure
    } finally { $WarningPreference = $prevWp }
    Assert-That ([string]$resStop.Status -ceq 'applied') 'WarningPreference=Stop: bookkeeping nao dispara rollback (applied)' ([string]$resStop.Status)
    $afterStop = @(Get-CurrentBuildAllowlist -ConfigPath $cfgStop)
    Assert-That ((($afterStop -join ',') -ceq 'coder,tester')) 'WarningPreference=Stop: config permanece aplicado' ($afterStop -join ',')
    Assert-That (@($resStop.BookkeepingErrors).Count -gt 0) 'WarningPreference=Stop: erros de bookkeeping registrados' ('count=' + @($resStop.BookkeepingErrors).Count)

    # --- ROLLBACK robusto: restauracao invalida (verificacao SHA-256 falha) => ROLLBACK_REQUIRED ---
    $rrThrew = $false; $rrMsg = ''
    try {
        Invoke-AuthorityApply -Request $reqR -ApprovalRecord $apprR -ConfigPath $cfgR -BackupRoot (Join-Path $rR 'bk') -ReloadStorePath (Join-Path $rR 'reload.json') -FixtureRoot (Join-Path $rR 'fix') -RepoRoot $rR -PolicyPath $fxR.Policy -AgentsRoot $fxR.Agents -SimulatePostReplaceMismatch -SimulateRestoreFailure | Out-Null
    } catch { $rrThrew = $true; $rrMsg = $_.Exception.Message }
    Assert-That ($rrThrew -and ($rrMsg -match 'ROLLBACK_REQUIRED')) 'Restauracao invalida (hash divergiu) => ROLLBACK_REQUIRED' $rrMsg
    $rbFiles = @(Get-ChildItem -LiteralPath (Join-Path $rR 'bk') -Recurse -Filter 'rollback.json' -File -ErrorAction SilentlyContinue)
    $foundRR = $false
    foreach ($f in $rbFiles) {
        try {
            $d = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
            if ([string]$d.status -ceq 'ROLLBACK_REQUIRED') { $foundRR = $true }
        } catch { }
    }
    Assert-That ($foundRR) 'rollback.json registra ROLLBACK_REQUIRED quando restore/verificacao falha' ("rollback.json files: $($rbFiles.Count)")

    # --- OWNERSHIP: igualdade ordinal do valor + path canonico do target ---
    $rOw = Join-Path $base 'row'; $fxOw = New-FixtureRepo -Root $rOw
    Write-Agent -AgentsDir $fxOw.Agents -Name 'coder' -Delegable 'true' | Out-Null
    $cfgOw = Join-Path $rOw 'opencode.json'
    Write-Config -Path $cfgOw -Allow @('coder')
    $rtBackup = [IO.File]::ReadAllText($fxOw.Runtimes)
    Write-Fixture -Path $fxOw.Runtimes -Text '{"version":1,"runtimes":{"opencode":{"id":"opencode","settings_targets":[{"path":"%USERPROFILE%/.config/opencode/opencode.json","format":"json","sections":{"agent.build.permission.task":"control-plane-ish"}}]}}}'
    $owThrew1 = $false
    try { New-AuthorityChangeRequest -RepoRoot $rOw -ConfigPath $cfgOw -PolicyPath $fxOw.Policy | Out-Null } catch { $owThrew1 = $true }
    Assert-That ($owThrew1) 'Ownership rejeita control-plane-ish (substring nao basta)' 'request passou com sufixo'
    Write-Fixture -Path $fxOw.Runtimes -Text '{"version":1,"runtimes":{"opencode":{"id":"opencode","settings_targets":[{"path":"%USERPROFILE%/.config/opencode/opencode.json","format":"json","sections":{"agent.build.permission.task":"not-control-plane"}}]}}}'
    $owThrew2 = $false
    try { New-AuthorityChangeRequest -RepoRoot $rOw -ConfigPath $cfgOw -PolicyPath $fxOw.Policy | Out-Null } catch { $owThrew2 = $true }
    Assert-That ($owThrew2) 'Ownership rejeita not-control-plane (substring nao basta)' 'request passou com prefixo'
    Write-Fixture -Path $fxOw.Runtimes -Text '{"version":1,"runtimes":{"opencode":{"id":"opencode","settings_targets":[{"path":"C:/other/opencode.json","format":"json","sections":{"agent.build.permission.task":"control-plane"}}]}}}'
    $owThrew3 = $false
    try { New-AuthorityChangeRequest -RepoRoot $rOw -ConfigPath $cfgOw -PolicyPath $fxOw.Policy | Out-Null } catch { $owThrew3 = $true }
    Assert-That ($owThrew3) 'Ownership rejeita path nao-canonico mesmo com valor exato' 'request passou fora do path canonico'
    Write-Fixture -Path $fxOw.Runtimes -Text $rtBackup
    $owOk = $false
    try { New-AuthorityChangeRequest -RepoRoot $rOw -ConfigPath $cfgOw -PolicyPath $fxOw.Policy | Out-Null; $owOk = $true } catch { $owOk = $false }
    Assert-That ($owOk) 'Ownership aceita control-plane exato no path canonico' 'request falhou com valor exato'
    # Comparacao ordinal explicita: case variantes nao passam (Ordinal, case-sensitive).
    Write-Fixture -Path $fxOw.Runtimes -Text '{"version":1,"runtimes":{"opencode":{"id":"opencode","settings_targets":[{"path":"%USERPROFILE%/.config/opencode/opencode.json","format":"json","sections":{"agent.build.permission.task":"Control-Plane"}}]}}}'
    $owThrewCase = $false
    try { New-AuthorityChangeRequest -RepoRoot $rOw -ConfigPath $cfgOw -PolicyPath $fxOw.Policy | Out-Null } catch { $owThrewCase = $true }
    Assert-That ($owThrewCase) 'Ownership rejeita Control-Plane (ordinal exige exato control-plane)' 'request passou com case variante'
    Write-Fixture -Path $fxOw.Runtimes -Text $rtBackup

    # --- REAL APPLY (TestMode): request+approval validos => applied em fixture ---
    $rT2 = Join-Path $base 'treal'; $fxT2 = New-FixtureRepo -Root $rT2
    Write-Agent -AgentsDir $fxT2.Agents -Name 'coder' -Delegable 'true' | Out-Null
    Write-Agent -AgentsDir $fxT2.Agents -Name 'tester' -Delegable 'true' | Out-Null
    $fixT = Join-Path $rT2 'fix'
    $cfgT = Join-Path $fixT 'opencode.json'
    Write-Fixture -Path $cfgT -Text '{"agent":{"build":{"mode":"primary","permission":{"task":{"*":"deny","coder":"allow"}}}},"other":{"keep":true},"version":3}'
    $preTextT = [IO.File]::ReadAllText($cfgT, [Text.UTF8Encoding]::new($false))
    $reqT = New-AuthorityChangeRequest -RepoRoot $rT2 -ConfigPath $cfgT -PolicyPath $fxT2.Policy
    $apprT = New-Approval -Request $reqT
    $bkT = Join-Path $fixT 'backups'
    $storeT = Join-Path $fixT 'reload-state.json'
    $consT = Join-Path $fixT 'consumed'
    $resT = Invoke-AuthorityRealApply -Request $reqT -ApprovalRecord $apprT -ConfigPath $cfgT -BackupRoot $bkT -ReloadStorePath $storeT -ExpectedConfigPath $cfgT -RepoRoot $rT2 -PolicyPath $fxT2.Policy -AgentsRoot $fxT2.Agents -ConsumedRoot $consT -TestMode -TestRoot $fixT
    Assert-That ([string]$resT.Status -ceq 'applied') 'RealApply TestMode valido aplica' ([string]$resT.Status)
    $afterT = @(Get-CurrentBuildAllowlist -ConfigPath $cfgT)
    Assert-That ((($afterT -join ',') -ceq 'coder,tester')) 'RealApply atualiza allowlist' ($afterT -join ',')
    $postObjT = Get-Content -LiteralPath $cfgT -Raw | ConvertFrom-Json
    Assert-That ([string]$postObjT.agent.build.permission.task.'*' -ceq 'deny') 'RealApply preserva *: deny' ([string]$postObjT.agent.build.permission.task.'*')
    Assert-That (([string]$postObjT.other.keep -ceq 'True') -and ($postObjT.version -eq 3) -and ([string]$postObjT.agent.build.mode -ceq 'primary')) 'RealApply preserva campos nao-governados' (([string]$postObjT.other.keep) + '/' + ([string]$postObjT.version))
    $oPreT = $preTextT | ConvertFrom-Json
    $oPostT = ([IO.File]::ReadAllText($cfgT, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
    $oPreT.agent.build.permission.PSObject.Properties.Remove('task')
    $oPostT.agent.build.permission.PSObject.Properties.Remove('task')
    Assert-That ((Get-LogicalHash -InputObject $oPreT) -ceq (Get-LogicalHash -InputObject $oPostT)) 'RealApply muda apenas o subtree task (hash logico igual)' 'nao-governados divergiram'
    Assert-That ((Test-Path -LiteralPath ([string]$resT.RollbackPath) -PathType Leaf)) 'RealApply grava rollback.json' ([string]$resT.RollbackPath)
    $rbT = Get-Content -LiteralPath ([string]$resT.RollbackPath) -Raw | ConvertFrom-Json
    Assert-That ([string]$rbT.status -ceq 'applied-and-verified') 'RealApply rollback.json applied-and-verified' ([string]$rbT.status)
    $consFileT = Join-Path $consT ([string]$reqT.change_id + '.json')
    Assert-That ((Test-Path -LiteralPath $consFileT -PathType Leaf)) 'RealApply marca consumed' $consFileT
    if (Test-Path -LiteralPath $consFileT -PathType Leaf) {
        $consDocT = Get-Content -LiteralPath $consFileT -Raw | ConvertFrom-Json
        Assert-That (([string]$consDocT.status -ceq 'consumed') -and ([string]$consDocT.approval_hash -ceq [string]$apprT.approval_hash)) 'RealApply consumed carrega status/hash' ([string]$consDocT.status)
    }
    $resT2 = Invoke-AuthorityRealApply -Request $reqT -ApprovalRecord $apprT -ConfigPath $cfgT -BackupRoot $bkT -ReloadStorePath $storeT -ExpectedConfigPath $cfgT -RepoRoot $rT2 -PolicyPath $fxT2.Policy -AgentsRoot $fxT2.Agents -ConsumedRoot $consT -TestMode -TestRoot $fixT
    Assert-That ([string]$resT2.Status -ceq 'noop') 'RealApply 2o apply => noop' ([string]$resT2.Status)

    # --- REAL APPLY REPLAY: marker + disco no alvo => noop estrito (sem escrita, sem novo marker) ---
    $replayMarkerBefore = [IO.File]::ReadAllText($consFileT)
    $replayHashBefore = (Get-FileHash -LiteralPath $cfgT -Algorithm SHA256).Hash
    $resReplayNoop = Invoke-AuthorityRealApply -Request $reqT -ApprovalRecord $apprT -ConfigPath $cfgT -BackupRoot $bkT -ReloadStorePath $storeT -ExpectedConfigPath $cfgT -RepoRoot $rT2 -PolicyPath $fxT2.Policy -AgentsRoot $fxT2.Agents -ConsumedRoot $consT -TestMode -TestRoot $fixT
    Assert-That ([string]$resReplayNoop.Status -ceq 'noop') 'RealApply replay com marker + disco no alvo => noop' ([string]$resReplayNoop.Status)
    $replayHashAfter = (Get-FileHash -LiteralPath $cfgT -Algorithm SHA256).Hash
    Assert-That ($replayHashBefore -ceq $replayHashAfter) 'RealApply replay noop nao escreve o config' "$replayHashBefore vs $replayHashAfter"
    $replayMarkerAfter = [IO.File]::ReadAllText($consFileT)
    Assert-That ($replayMarkerBefore -ceq $replayMarkerAfter) 'RealApply replay noop nao regrava o marker (estrito)' 'marker foi regravado'

    # --- REAL APPLY REPLAY: marker + disco fora do alvo => REPLAY_BLOCKED sem escrita ---
    Write-Config -Path $cfgT -Allow @('coder')
    $replayOffBefore = (Get-FileHash -LiteralPath $cfgT -Algorithm SHA256).Hash
    $replayBlocked = $false; $replayBlockedMsg = ''
    try { Invoke-AuthorityRealApply -Request $reqT -ApprovalRecord $apprT -ConfigPath $cfgT -BackupRoot $bkT -ReloadStorePath $storeT -ExpectedConfigPath $cfgT -RepoRoot $rT2 -PolicyPath $fxT2.Policy -AgentsRoot $fxT2.Agents -ConsumedRoot $consT -TestMode -TestRoot $fixT | Out-Null } catch { $replayBlocked = $true; $replayBlockedMsg = $_.Exception.Message }
    Assert-That (($replayBlocked) -and ($replayBlockedMsg -match 'REPLAY_BLOCKED')) 'RealApply replay com marker + disco fora do alvo => REPLAY_BLOCKED' $replayBlockedMsg
    $replayOffAfter = (Get-FileHash -LiteralPath $cfgT -Algorithm SHA256).Hash
    Assert-That ($replayOffBefore -ceq $replayOffAfter) 'RealApply REPLAY_BLOCKED nao escreve o config' "$replayOffBefore vs $replayOffAfter"

    # --- REAL APPLY: sem approval / hash errado / rejected => bloqueado sem escrita ---
    $rTN = Join-Path $base 'trealn'; $fxTN = New-FixtureRepo -Root $rTN
    Write-Agent -AgentsDir $fxTN.Agents -Name 'coder' -Delegable 'true' | Out-Null
    Write-Agent -AgentsDir $fxTN.Agents -Name 'tester' -Delegable 'true' | Out-Null
    $fixTN = Join-Path $rTN 'fix'
    $cfgTN = Join-Path $fixTN 'opencode.json'
    Write-Config -Path $cfgTN -Allow @('coder')
    $reqTN = New-AuthorityChangeRequest -RepoRoot $rTN -ConfigPath $cfgTN -PolicyPath $fxTN.Policy
    $apprTN = New-Approval -Request $reqTN
    $hashTNBefore = (Get-FileHash -LiteralPath $cfgTN -Algorithm SHA256).Hash
    $missingThrew = $false
    try { Invoke-AuthorityRealApply -Request $reqTN -ApprovalRecord $null -ConfigPath $cfgTN -ExpectedConfigPath $cfgTN -RepoRoot $rTN -PolicyPath $fxTN.Policy -AgentsRoot $fxTN.Agents -TestMode -TestRoot $fixTN | Out-Null } catch { $missingThrew = $true }
    Assert-That ($missingThrew) 'RealApply sem approval bloqueia' 'passou sem approval'
    $apprBadTN = New-Approval -Request $reqTN
    $apprBadTN.approval_hash = 'sha256:0000000000000000000000000000000000000000000000000000000000000000'
    $badThrew = $false; $badMsg = ''
    try { Invoke-AuthorityRealApply -Request $reqTN -ApprovalRecord $apprBadTN -ConfigPath $cfgTN -ExpectedConfigPath $cfgTN -RepoRoot $rTN -PolicyPath $fxTN.Policy -AgentsRoot $fxTN.Agents -TestMode -TestRoot $fixTN | Out-Null } catch { $badThrew = $true; $badMsg = $_.Exception.Message }
    Assert-That ($badThrew) 'RealApply approval hash errado bloqueia' $badMsg
    $apprRejTN = New-Approval -Request $reqTN -Status 'rejected'
    $rejThrew = $false
    try { Invoke-AuthorityRealApply -Request $reqTN -ApprovalRecord $apprRejTN -ConfigPath $cfgTN -ExpectedConfigPath $cfgTN -RepoRoot $rTN -PolicyPath $fxTN.Policy -AgentsRoot $fxTN.Agents -TestMode -TestRoot $fixTN | Out-Null } catch { $rejThrew = $true }
    Assert-That ($rejThrew) 'RealApply approval rejected bloqueia' 'passou com rejected'
    $hashTNAfter = (Get-FileHash -LiteralPath $cfgTN -Algorithm SHA256).Hash
    Assert-That ($hashTNBefore -ceq $hashTNAfter) 'RealApply bloqueado nao escreve' "$hashTNBefore vs $hashTNAfter"

    # --- REAL APPLY: STALE (policy/agent-source/base mudaram) => bloqueado sem escrita ---
    $policyBakTN = [IO.File]::ReadAllText($fxTN.Policy)
    Write-Fixture -Path $fxTN.Policy -Text '{"version":1,"defaults":{"build_delegable":false},"deny_rules":{"visibility":["hidden"]},"overrides":{}}'
    $staleThrew = $false; $staleMsg = ''
    try { Invoke-AuthorityRealApply -Request $reqTN -ApprovalRecord $apprTN -ConfigPath $cfgTN -ExpectedConfigPath $cfgTN -RepoRoot $rTN -PolicyPath $fxTN.Policy -AgentsRoot $fxTN.Agents -TestMode -TestRoot $fixTN | Out-Null } catch { $staleThrew = $true; $staleMsg = $_.Exception.Message }
    Write-Fixture -Path $fxTN.Policy -Text $policyBakTN
    Assert-That (($staleThrew) -and ($staleMsg -match 'STALE')) 'RealApply stale policy => STALE' $staleMsg
    Write-Agent -AgentsDir $fxTN.Agents -Name 'newcomer' -Delegable 'true' | Out-Null
    $staleSrcThrew = $false; $staleSrcMsg = ''
    try { Invoke-AuthorityRealApply -Request $reqTN -ApprovalRecord $apprTN -ConfigPath $cfgTN -ExpectedConfigPath $cfgTN -RepoRoot $rTN -PolicyPath $fxTN.Policy -AgentsRoot $fxTN.Agents -TestMode -TestRoot $fixTN | Out-Null } catch { $staleSrcThrew = $true; $staleSrcMsg = $_.Exception.Message }
    Remove-Item -LiteralPath (Join-Path $fxTN.Agents 'newcomer.md') -Force -ErrorAction SilentlyContinue
    Assert-That (($staleSrcThrew) -and ($staleSrcMsg -match 'STALE')) 'RealApply stale agent source => STALE' $staleSrcMsg
    Write-Config -Path $cfgTN -Allow @('coder', 'tester')
    $casThrewTN = $false; $casMsgTN = ''
    try { Invoke-AuthorityRealApply -Request $reqTN -ApprovalRecord $apprTN -ConfigPath $cfgTN -ExpectedConfigPath $cfgTN -RepoRoot $rTN -PolicyPath $fxTN.Policy -AgentsRoot $fxTN.Agents -TestMode -TestRoot $fixTN | Out-Null } catch { $casThrewTN = $true; $casMsgTN = $_.Exception.Message }
    $afterCasTN = @(Get-CurrentBuildAllowlist -ConfigPath $cfgTN)
    Write-Config -Path $cfgTN -Allow @('coder')
    Assert-That (($casThrewTN) -and ($casMsgTN -match 'STALE|CAS_CONFLICT|approval invalida')) 'RealApply base divergente => STALE/CAS bloqueia' $casMsgTN
    Assert-That ((($afterCasTN -join ',') -ceq 'coder,tester')) 'RealApply STALE/CAS nao escreve' ($afterCasTN -join ',')

    # --- REAL APPLY: drift bloqueia sem tocar o config ---
    $rTD = Join-Path $base 'treald'; $fxTD = New-FixtureRepo -Root $rTD
    Write-Agent -AgentsDir $fxTD.Agents -Name 'coder' -Delegable 'true' | Out-Null
    $fixTD = Join-Path $rTD 'fix'
    $cfgTD = Join-Path $fixTD 'opencode.json'
    Write-Config -Path $cfgTD -Allow @('coder', 'ghost-external')
    $reqTD = New-AuthorityChangeRequest -RepoRoot $rTD -ConfigPath $cfgTD -PolicyPath $fxTD.Policy
    $apprTD = New-Approval -Request $reqTD
    $hashTDBefore = (Get-FileHash -LiteralPath $cfgTD -Algorithm SHA256).Hash
    $driftThrewTD = $false; $driftMsgTD = ''
    try { Invoke-AuthorityRealApply -Request $reqTD -ApprovalRecord $apprTD -ConfigPath $cfgTD -ExpectedConfigPath $cfgTD -RepoRoot $rTD -PolicyPath $fxTD.Policy -AgentsRoot $fxTD.Agents -TestMode -TestRoot $fixTD | Out-Null } catch { $driftThrewTD = $true; $driftMsgTD = $_.Exception.Message }
    $hashTDAfter = (Get-FileHash -LiteralPath $cfgTD -Algorithm SHA256).Hash
    Assert-That (($driftThrewTD) -and ($driftMsgTD -match 'DRIFT')) 'RealApply drift bloqueia' $driftMsgTD
    Assert-That ($hashTDBefore -ceq $hashTDAfter) 'RealApply drift nao toca o config' "$hashTDBefore vs $hashTDAfter"

    # --- REAL APPLY: post-hash mismatch => ROLLED_BACK verificado ---
    $rTM = Join-Path $base 'trealm'; $fxTM = New-FixtureRepo -Root $rTM
    Write-Agent -AgentsDir $fxTM.Agents -Name 'coder' -Delegable 'true' | Out-Null
    Write-Agent -AgentsDir $fxTM.Agents -Name 'tester' -Delegable 'true' | Out-Null
    $fixTM = Join-Path $rTM 'fix'
    $cfgTM = Join-Path $fixTM 'opencode.json'
    Write-Config -Path $cfgTM -Allow @('coder')
    $reqTM = New-AuthorityChangeRequest -RepoRoot $rTM -ConfigPath $cfgTM -PolicyPath $fxTM.Policy
    $apprTM = New-Approval -Request $reqTM
    $hashTMBefore = (Get-FileHash -LiteralPath $cfgTM -Algorithm SHA256).Hash
    $resTM = Invoke-AuthorityRealApply -Request $reqTM -ApprovalRecord $apprTM -ConfigPath $cfgTM -ExpectedConfigPath $cfgTM -RepoRoot $rTM -PolicyPath $fxTM.Policy -AgentsRoot $fxTM.Agents -TestMode -TestRoot $fixTM -SimulatePostReplaceMismatch
    Assert-That ([string]$resTM.Status -ceq 'ROLLED_BACK') 'RealApply post-hash mismatch => ROLLED_BACK' ([string]$resTM.Status)
    $hashTMAfter = (Get-FileHash -LiteralPath $cfgTM -Algorithm SHA256).Hash
    Assert-That ($hashTMBefore -ceq $hashTMAfter) 'RealApply ROLLED_BACK restaura bytes originais' "$hashTMBefore vs $hashTMAfter"
    $rbTM = Get-Content -LiteralPath ([string]$resTM.RollbackPath) -Raw | ConvertFrom-Json
    Assert-That ([string]$rbTM.status -ceq 'ROLLED_BACK') 'RealApply rollback.json marca ROLLED_BACK' ([string]$rbTM.status)

    # --- REAL APPLY: boundary canonico/reparse ---
    $canThrew = $false; $canMsg = ''
    try { Invoke-AuthorityRealApply -Request $reqTN -ApprovalRecord $apprTN -ConfigPath $cfgTN -RepoRoot $rTN -PolicyPath $fxTN.Policy -AgentsRoot $fxTN.Agents | Out-Null } catch { $canThrew = $true; $canMsg = $_.Exception.Message }
    Assert-That (($canThrew) -and ($canMsg -match 'canonico')) 'RealApply fora de TestMode exige config canonico' $canMsg
    $noExpThrew = $false
    try { Invoke-AuthorityRealApply -Request $reqTN -ApprovalRecord $apprTN -ConfigPath $cfgTN -RepoRoot $rTN -PolicyPath $fxTN.Policy -AgentsRoot $fxTN.Agents -TestMode -TestRoot $fixTN | Out-Null } catch { $noExpThrew = $true }
    Assert-That ($noExpThrew) 'RealApply TestMode sem ExpectedConfigPath bloqueia' 'passou sem Expected'
    $rTJ = Join-Path $base 'trealj'; $fxTJ = New-FixtureRepo -Root $rTJ
    Write-Agent -AgentsDir $fxTJ.Agents -Name 'coder' -Delegable 'true' | Out-Null
    Write-Agent -AgentsDir $fxTJ.Agents -Name 'tester' -Delegable 'true' | Out-Null
    $realDirTJ = Join-Path $rTJ 'realdir'
    New-Item -ItemType Directory -Path $realDirTJ -Force | Out-Null
    $cfgTJ = Join-Path $realDirTJ 'opencode.json'
    Write-Config -Path $cfgTJ -Allow @('coder')
    $reqTJ = New-AuthorityChangeRequest -RepoRoot $rTJ -ConfigPath $cfgTJ -PolicyPath $fxTJ.Policy
    $linkTJ = Join-Path $rTJ 'linkdir'
    $jOkTJ = $true
    try { New-Item -ItemType Junction -Path $linkTJ -Target $realDirTJ -ErrorAction Stop | Out-Null } catch { $jOkTJ = $false }
    if ($jOkTJ) {
        $apprTJ = New-Approval -Request $reqTJ
        $reparseThrewTJ = $false
        try { Invoke-AuthorityRealApply -Request $reqTJ -ApprovalRecord $apprTJ -ConfigPath (Join-Path $linkTJ 'opencode.json') -ExpectedConfigPath (Join-Path $linkTJ 'opencode.json') -RepoRoot $rTJ -PolicyPath $fxTJ.Policy -AgentsRoot $fxTJ.Agents -TestMode -TestRoot $linkTJ | Out-Null } catch { $reparseThrewTJ = $true }
        Assert-That ($reparseThrewTJ) 'RealApply reparse point (junction) bloqueia' 'passou via junction'
    } else {
        Assert-That ($true) 'RealApply reparse (junction indisponivel; skip)' 'sem privilegio de junction'
    }
}
finally {
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "TEST RESULTS: $passed / $total passed"
if ($passed -ne $total) { exit 1 }
exit 0
