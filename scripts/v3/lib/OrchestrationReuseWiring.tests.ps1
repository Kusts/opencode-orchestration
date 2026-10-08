<#!
.SYNOPSIS
    Tests for lib/OrchestrationReuseWiring.ps1 (PR-4).
.DESCRIPTION
    Hermetic: temp dirs under the user temp for reuse stores, cleanup
    in finally; the repo tree is never written (default store-dir is
    resolved against a temp RepoRoot). Bracketed output the runner
    parses. Exit 0 on all pass, exit 1 on any fail or unexpected
    exception. PS 5.1 compatible. ASCII-only. No network, no spawn.
    Covers PR-4 acceptance 2: a valid hit reduces work; stale or
    invalid records reexecute; missing provenance means no reuse;
    per-class TTL defaults (no global arbitrary TTL); reuse never
    equals verification (Planner decides).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationEvidenceStore.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationReuseWiring.ps1')

$script:passed = 0
$script:failed = 0

function Assert-ReuseWiring {
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

function New-RWRecordInput {
    param([string]$RunId, [string]$StoreDir, [string]$ExpiresAt, [string]$Revision = 'rev-a', [string]$Crit = 'crit-a', [string]$EnvVer = '7')
    $raw = Join-Path $StoreDir ($RunId + '.log')
    [IO.File]::WriteAllText($raw, ('evidence-bytes-' + $RunId))
    return [ordered]@{
        task_id = 'task-1'; run_id = $RunId; worker_id = 'coder_1'
        provenance = @{ created_by = 'coder'; kernel_task_ref = 'task-1' }
        base_revision = $Revision; criteria_hash = $Crit
        source_fingerprints = @{'src/a.ps1' = 'sha-a'}; diff_hash = 'diff-a'
        scope = @('src/a.ps1'); command = 'test-suite'
        environment = @{ runtime = 'pwsh'; version = $EnvVer }
        result = @{ summary = 'passed'; raw_ref = $raw }
        assumptions = @()
        invalidation_conditions = @(
            @{ type = 'source-changed'; paths = @('src/a.ps1') },
            @{ type = 'criteria-changed'; hash = $Crit },
            @{ type = 'base-revision'; require_same = $true },
            @{ type = 'env-changed'; runtime = 'pwsh'; version = $EnvVer },
            @{ type = 'ttl'; expires_at = $ExpiresAt }
        )
        created_at = ([DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o'))
    }
}

try {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('v3-reusewiring-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $storeA = Join-Path $tempRoot 'store-a'
    New-Item -ItemType Directory -Path $storeA -Force | Out-Null
    $now = [DateTimeOffset]::UtcNow
    $future = $now.AddMinutes(30).ToString('o')

    try {
        # ---------- version / contract ----------
        $v = Get-OrchestrationReuseWiringVersion
        Assert-ReuseWiring (([int]$v.schema_version -eq 1) -and ([string]$v.phase -ceq 'PR-4')) '[W0] wiring version schema 1 phase PR-4' ''

        # ---------- default store dir: automatic, canonical evidence-store (Fase F) ----------
        $auto = Get-OrchestrationReuseDefaultStoreDir -StoreDir '' -RepoRoot $tempRoot
        Assert-ReuseWiring (((-not [string]::IsNullOrWhiteSpace($auto)) -and ($auto -like '*evidence-store') -and (Test-Path -LiteralPath $auto -PathType Container))) '[W1] default store_dir resolves to canonical evidence-store and is created' $auto
        $canon = Get-OrchestrationReuseCanonicalStoreDir -RepoRoot $tempRoot
        Assert-ReuseWiring (($auto -ceq $canon)) '[W1] default equals canonical dir' $auto
        $leg = Get-OrchestrationReuseLegacyStoreDir -RepoRoot $tempRoot
        Assert-ReuseWiring (($leg -like '*reuse-store')) '[W1] legacy dir resolves to reuse-store (read fallback only)' $leg
        $explicit = Get-OrchestrationReuseDefaultStoreDir -StoreDir $storeA -RepoRoot $tempRoot
        Assert-ReuseWiring (($explicit -ceq $storeA)) '[W1] explicit store_dir wins' $explicit
        $unresolvable = Get-OrchestrationReuseDefaultStoreDir -StoreDir '' -RepoRoot ''
        if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { $unresolvable = '' }
        Assert-ReuseWiring (([string]::IsNullOrWhiteSpace($unresolvable)) -or (Test-Path -LiteralPath $unresolvable -PathType Container)) '[W1] empty RepoRoot never throws, resolves repo-local or empty' $unresolvable

        # ---------- TTL defaults per class, no global arbitrary TTL ----------
        Assert-ReuseWiring (([int](Get-OrchestrationReuseDefaultTtlSeconds -ReuseClass 'content-fingerprint') -eq 0)) '[W2] immutable content class requires no TTL' ''
        Assert-ReuseWiring (([int](Get-OrchestrationReuseDefaultTtlSeconds -ReuseClass 'service-response') -eq 3600)) '[W2] service class defaults to 3600s' ''
        Assert-ReuseWiring (([int](Get-OrchestrationReuseDefaultTtlSeconds -ReuseClass 'external-behavior') -eq 900)) '[W2] external-behavior class defaults to 900s' ''
        Assert-ReuseWiring (([int](Get-OrchestrationReuseDefaultTtlSeconds -ReuseClass 'mystery-class') -eq -1)) '[W2] unknown class fails closed (-1)' ''
        $exp = Get-OrchestrationReuseTtlExpiry -CreatedAt $now.ToString('o') -ReuseClass 'service-response'
        Assert-ReuseWiring ((-not [string]::IsNullOrWhiteSpace($exp))) '[W2] expiry computed for TTL class' $exp
        Assert-ReuseWiring ([string]::IsNullOrWhiteSpace((Get-OrchestrationReuseTtlExpiry -CreatedAt $now.ToString('o') -ReuseClass 'content-fingerprint'))) '[W2] no expiry for immutable class' ''
        Assert-ReuseWiring ([string]::IsNullOrWhiteSpace((Get-OrchestrationReuseTtlExpiry -CreatedAt $now.ToString('o') -ReuseClass 'mystery-class'))) '[W2] no expiry for unknown class' ''

        # ---------- seed one valid record ----------
        $seed = New-RWRecordInput -RunId 'seed-1' -StoreDir $storeA -ExpiresAt $future
        $made = New-OrchestrationEvidenceRecord $seed $storeA
        Assert-ReuseWiring ([bool]$made.created) '[S] seed record created' ([string]$made.reason)
        $fps = @{'src/a.ps1' = 'sha-a'}
        $envNow = @{ runtime = 'pwsh'; version = '7' }

        # ---------- R1: valid hit reduces work, never verifies ----------
        $hit = Find-OrchestrationReusableWork -Scope @('src/a.ps1') -CurrentSourceFingerprints $fps -CurrentBaseRevision 'rev-a' -CurrentCriteriaHash 'crit-a' -CurrentEnv $envNow -Now $now.ToString('o') -ReuseClass 'service-response' -StoreDir $storeA
        Assert-ReuseWiring (([bool]$hit.reused) -and ([string]$hit.decision -ceq 'reuse-candidate') -and ([bool]$hit.work_saved) -and (@($hit.candidates).Count -eq 1)) '[R1] valid hit is a work-saving candidate' ([string]$hit.decision)
        Assert-ReuseWiring (((-not [bool]$hit.verified_pass) -and ([bool]$hit.planner_decides) -and ($hit.blocked -eq $false))) '[R1] reuse never equals verification, Planner decides' ''

        # ---------- R2: stale records reexecute (each drift axis) ----------
        $missCrit = Find-OrchestrationReusableWork -Scope @('src/a.ps1') -CurrentSourceFingerprints $fps -CurrentBaseRevision 'rev-a' -CurrentCriteriaHash 'crit-changed' -CurrentEnv $envNow -Now $now.ToString('o') -ReuseClass 'service-response' -StoreDir $storeA
        Assert-ReuseWiring (((-not [bool]$missCrit.reused) -and ([string]$missCrit.decision -ceq 'reexecute') -and (@($missCrit.reasons) -contains 'criteria-changed'))) '[R2] criteria drift reexecutes' ((@($missCrit.reasons) -join ','))
        $missBase = Find-OrchestrationReusableWork -Scope @('src/a.ps1') -CurrentSourceFingerprints $fps -CurrentBaseRevision 'rev-b' -CurrentCriteriaHash 'crit-a' -CurrentEnv $envNow -Now $now.ToString('o') -ReuseClass 'service-response' -StoreDir $storeA
        Assert-ReuseWiring (((-not [bool]$missBase.reused) -and (@($missBase.reasons) -contains 'base-revision'))) '[R2] base drift reexecutes' ((@($missBase.reasons) -join ','))
        $envDrift = @{ runtime = 'pwsh'; version = '8' }
        $missEnv = Find-OrchestrationReusableWork -Scope @('src/a.ps1') -CurrentSourceFingerprints $fps -CurrentBaseRevision 'rev-a' -CurrentCriteriaHash 'crit-a' -CurrentEnv $envDrift -Now $now.ToString('o') -ReuseClass 'service-response' -StoreDir $storeA
        Assert-ReuseWiring (((-not [bool]$missEnv.reused) -and (@($missEnv.reasons) -contains 'env-changed'))) '[R2] env drift reexecutes' ((@($missEnv.reasons) -join ','))
        $missTtl = Find-OrchestrationReusableWork -Scope @('src/a.ps1') -CurrentSourceFingerprints $fps -CurrentBaseRevision 'rev-a' -CurrentCriteriaHash 'crit-a' -CurrentEnv $envNow -Now $now.AddMinutes(31).ToString('o') -ReuseClass 'service-response' -StoreDir $storeA
        Assert-ReuseWiring (((-not [bool]$missTtl.reused) -and (@($missTtl.reasons) -contains 'ttl'))) '[R2] expired TTL reexecutes' ((@($missTtl.reasons) -join ','))
        $fpsDrift = @{'src/a.ps1' = 'sha-b'}
        $missSrc = Find-OrchestrationReusableWork -Scope @('src/a.ps1') -CurrentSourceFingerprints $fpsDrift -CurrentBaseRevision 'rev-a' -CurrentCriteriaHash 'crit-a' -CurrentEnv $envNow -Now $now.ToString('o') -ReuseClass 'service-response' -StoreDir $storeA
        Assert-ReuseWiring (((-not [bool]$missSrc.reused) -and (@($missSrc.reasons) -contains 'source-changed:src/a.ps1'))) '[R2] provenance fingerprint drift reexecutes' ((@($missSrc.reasons) -join ','))

        # ---------- R3: revoked record never reuses ----------
        $rev = New-RWRecordInput -RunId 'seed-revoked' -StoreDir $storeA -ExpiresAt $future
        $rev.invalidation_conditions = @(@{ type = 'revoked'; revoked_by = 'operator-1' })
        $madeRev = New-OrchestrationEvidenceRecord $rev $storeA
        Assert-ReuseWiring ([bool]$madeRev.created) '[R3] revoked record stored' ([string]$madeRev.reason)
        $tRev = Test-OrchestrationReuseCandidate -Record $madeRev.record -Current @{ current_source_fingerprints = $fps; current_base_revision = 'rev-a'; current_criteria_hash = 'crit-a'; current_env = $envNow; now = $now.ToString('o') } -ReuseClass 'service-response'
        Assert-ReuseWiring (((-not [bool]$tRev.reusable) -and (@($tRev.reasons) -contains 'revoked'))) '[R3] revoked means no reuse' ((@($tRev.reasons) -join ','))

        # ---------- F6: canonical presence suppresses the legacy copy of the same ID ----------
        $rootF6 = Join-Path $tempRoot 'f6root'
        $legF6 = Join-Path (Join-Path $rootF6 'cache') 'reuse-store'
        $canonF6 = Join-Path (Join-Path $rootF6 'cache') 'evidence-store'
        New-Item -ItemType Directory -Path $legF6 -Force | Out-Null
        $legSeed = New-RWRecordInput -RunId 'f6-1' -StoreDir $legF6 -ExpiresAt $future
        $legMade = New-OrchestrationEvidenceRecord $legSeed $legF6
        Assert-ReuseWiring ([bool]$legMade.created) '[F6] legacy record stored' ([string]$legMade.reason)
        $eidF6 = ([string]$legMade.record.evidence_id)
        $fpsF6 = @{'src/a.ps1' = 'sha-a'}
        $envF6 = @{ runtime = 'pwsh'; version = '7' }
        $hitLeg = Find-OrchestrationReusableWork -Scope @('src/a.ps1') -CurrentSourceFingerprints $fpsF6 -CurrentBaseRevision 'rev-a' -CurrentCriteriaHash 'crit-a' -CurrentEnv $envF6 -Now $now.ToString('o') -ReuseClass 'service-response' -RepoRoot $rootF6
        Assert-ReuseWiring ([bool]$hitLeg.reused) '[F6] legacy-only copy is a candidate' ([string]$hitLeg.decision)
        New-Item -ItemType Directory -Path $canonF6 -Force | Out-Null
        $canonText = [IO.File]::ReadAllText((Join-Path $legF6 ($eidF6 + '.json')), [Text.Encoding]::UTF8)
        $canonRec = ConvertFrom-Json $canonText
        $canonRec.invalidation_conditions = @(@{ type = 'revoked'; revoked_by = 'operator-1' })
        [IO.File]::WriteAllText((Join-Path $canonF6 ($eidF6 + '.json')), (ConvertTo-Json -InputObject $canonRec -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
        $hitSup = Find-OrchestrationReusableWork -Scope @('src/a.ps1') -CurrentSourceFingerprints $fpsF6 -CurrentBaseRevision 'rev-a' -CurrentCriteriaHash 'crit-a' -CurrentEnv $envF6 -Now $now.ToString('o') -ReuseClass 'service-response' -RepoRoot $rootF6
        Assert-ReuseWiring (((-not [bool]$hitSup.reused) -and ([string]$hitSup.decision -ceq 'reexecute') -and (@($hitSup.reasons) -contains 'canonical-supersedes-legacy'))) '[F6] canonical revoked presence suppresses the legacy copy' ((@($hitSup.reasons) -join ','))

        # ---------- R4: missing provenance => no reuse ----------
        $storeB = Join-Path $tempRoot 'store-b'
        New-Item -ItemType Directory -Path $storeB -Force | Out-Null
        $good = New-RWRecordInput -RunId 'prov-1' -StoreDir $storeB -ExpiresAt $future
        $madeGood = New-OrchestrationEvidenceRecord $good $storeB
        $tampered = ([IO.File]::ReadAllText((Join-Path $storeB ($madeGood.record.evidence_id + '.json')), [Text.Encoding]::UTF8) | ConvertFrom-Json)
        $tampered.provenance.kernel_task_ref = ''
        [IO.File]::WriteAllText((Join-Path $storeB 'aa000000000000000000000000000000.json'), ($tampered | ConvertTo-Json -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
        $tNoProv = Test-OrchestrationReuseCandidate -Record $tampered -Current @{ current_source_fingerprints = $fps; current_base_revision = 'rev-a'; current_criteria_hash = 'crit-a'; current_env = $envNow; now = $now.ToString('o') } -ReuseClass 'service-response'
        Assert-ReuseWiring (((-not [bool]$tNoProv.reusable) -and (@($tNoProv.reasons) -contains 'provenance-missing-no-reuse'))) '[R4] blank kernel_task_ref means no reuse' ((@($tNoProv.reasons) -join ','))
        $noProvAtAll = Test-OrchestrationReuseCandidate -Record @{ task_id = 'x' } -Current @{} -ReuseClass 'service-response'
        Assert-ReuseWiring (((-not [bool]$noProvAtAll.reusable) -and (@($noProvAtAll.reasons) -contains 'provenance-missing-no-reuse'))) '[R4] absent provenance means no reuse' ''

        # ---------- R5: TTL-class record without ttl condition is stale; immutable class exempts ----------
        $storeC = Join-Path $tempRoot 'store-c'
        New-Item -ItemType Directory -Path $storeC -Force | Out-Null
        $noTtl = New-RWRecordInput -RunId 'nottl-1' -StoreDir $storeC -ExpiresAt $future
        $noTtl.invalidation_conditions = @(
            @{ type = 'source-changed'; paths = @('src/a.ps1') },
            @{ type = 'criteria-changed'; hash = 'crit-a' },
            @{ type = 'base-revision'; require_same = $true },
            @{ type = 'env-changed'; runtime = 'pwsh'; version = '7' }
        )
        $madeNoTtl = New-OrchestrationEvidenceRecord $noTtl $storeC
        Assert-ReuseWiring ([bool]$madeNoTtl.created) '[R5] ttl-less record stored' ([string]$madeNoTtl.reason)
        $findSvc = Find-OrchestrationReusableWork -Scope @('src/a.ps1') -CurrentSourceFingerprints $fps -CurrentBaseRevision 'rev-a' -CurrentCriteriaHash 'crit-a' -CurrentEnv $envNow -Now $now.ToString('o') -ReuseClass 'service-response' -StoreDir $storeC
        Assert-ReuseWiring (((-not [bool]$findSvc.reused) -and (@($findSvc.reasons) -contains 'ttl-missing-stale-reexecute'))) '[R5] TTL class without ttl condition is stale' ((@($findSvc.reasons) -join ','))
        $findFp = Find-OrchestrationReusableWork -Scope @('src/a.ps1') -CurrentSourceFingerprints $fps -CurrentBaseRevision 'rev-a' -CurrentCriteriaHash 'crit-a' -CurrentEnv $envNow -Now $now.ToString('o') -ReuseClass 'content-fingerprint' -StoreDir $storeC
        Assert-ReuseWiring (([bool]$findFp.reused) -and ([string]$findFp.decision -ceq 'reuse-candidate')) '[R5] immutable class needs no TTL' ([string]$findFp.decision)
        $findUnknown = Find-OrchestrationReusableWork -Scope @('src/a.ps1') -CurrentSourceFingerprints $fps -CurrentBaseRevision 'rev-a' -CurrentCriteriaHash 'crit-a' -CurrentEnv $envNow -Now $now.ToString('o') -ReuseClass 'mystery-class' -StoreDir $storeC
        Assert-ReuseWiring (((-not [bool]$findUnknown.reused) -and (@($findUnknown.reasons) -contains 'unknown-class-no-reuse'))) '[R5] unknown class fails closed' ((@($findUnknown.reasons) -join ','))

        # ---------- hygiene: no network/spawn/secrets, ASCII-only ----------
        $reusePath = Join-Path $PSScriptRoot 'OrchestrationReuseWiring.ps1'
        $reuseText = [IO.File]::ReadAllText($reusePath, [Text.UTF8Encoding]::new($false))
        Assert-ReuseWiring ((($reuseText -notmatch 'Invoke-WebRequest') -and ($reuseText -notmatch 'Invoke-RestMethod') -and ($reuseText -notmatch 'HttpClient') -and ($reuseText -notmatch 'Net\.WebClient') -and ($reuseText -notmatch 'HttpWebRequest') -and ($reuseText -notmatch 'Start-Process'))) '[NET] reuse wiring owns no network/spawn' ''
        Assert-ReuseWiring (($reuseText -notmatch '(?i)sk-[A-Za-z0-9]')) '[SEC] reuse wiring carries no secret value' ''
        foreach ($p in @($reusePath, (Join-Path $PSScriptRoot 'OrchestrationReuseWiring.tests.ps1'))) {
            $bytes = [IO.File]::ReadAllBytes($p)
            $bad = 0
            foreach ($by in $bytes) { if ([int]$by -gt 127) { $bad++ } }
            Assert-ReuseWiring ($bad -eq 0) ('[ASCII] ' + [IO.Path]::GetFileName($p)) ([string]$bad)
        }
    }
    finally {
        try { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }

    Write-Host ''
    Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + ($script:passed + $script:failed) + ' passed (0 skipped)')
    Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed)
    if ($script:failed -ne 0) { exit 1 }
    exit 0
}
catch {
    Write-Host ('[FAIL] harness-exception -- ' + $_.Exception.Message)
    $script:failed++
    Write-Host ''
    Write-Host ('TEST RESULTS: ' + $script:passed + ' / ' + ($script:passed + $script:failed) + ' passed (0 skipped)')
    Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed)
    exit 1
}
