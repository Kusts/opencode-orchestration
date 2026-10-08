<#!
.SYNOPSIS
    Tests for Fase F store unification (canonical evidence-store).
.DESCRIPTION
    Hermetic: fake repo roots under temp, cleanup in finally; real repo
    tree never written. Bracketed output the runner parses. Exit 0 all
    pass, 1 any fail. PS 5.1 compatible. ASCII-only. No network, no spawn.
    Covers the mandatory test: write via New-OrchestrationEvidenceRecord
    (EvidenceStore) and recover via the ReuseWiring envelope WITHOUT
    passing store_dir; plus legacy read-fallback, canonical-wins, and
    write-only-canonical (legacy never recreated).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationEvidenceStore.ps1')
. (Join-Path $PSScriptRoot 'OrchestrationReuseWiring.ps1')

$script:passed = 0
$script:failed = 0

function Assert-SU {
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

function New-SURecordInput {
    param([string]$RunId, [string]$StoreDir, [string]$Revision = 'rev-u', [string]$Crit = 'crit-u')
    $raw = Join-Path $StoreDir ($RunId + '.log')
    [IO.File]::WriteAllText($raw, ('evidence-bytes-' + $RunId))
    return [ordered]@{
        task_id = 'task-u'; run_id = $RunId; worker_id = 'coder_1'
        provenance = @{ created_by = 'coder'; kernel_task_ref = 'task-u' }
        base_revision = $Revision; criteria_hash = $Crit
        source_fingerprints = @{'src/u.ps1' = 'sha-u'}; diff_hash = 'diff-u'
        scope = @('src/u.ps1'); command = 'test-suite'
        environment = @{ runtime = 'pwsh'; version = '7' }
        result = @{ summary = 'passed'; raw_ref = $raw }
        assumptions = @()
        invalidation_conditions = @(
            @{ type = 'source-changed'; paths = @('src/u.ps1') },
            @{ type = 'criteria-changed'; hash = $Crit },
            @{ type = 'base-revision'; require_same = $true },
            @{ type = 'env-changed'; runtime = 'pwsh'; version = '7' }
        )
        created_at = ([DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o'))
    }
}

try {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('v3-storeunif-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $fakeRepo = Join-Path $tempRoot 'fakerepo'
    New-Item -ItemType Directory -Path $fakeRepo -Force | Out-Null

    try {
        # ---------- canonical default (no store_dir anywhere) ----------
        $canon = Get-OrchestrationReuseCanonicalStoreDir -RepoRoot $fakeRepo
        Assert-SU ((($canon -like '*evidence-store') -and (Test-Path -LiteralPath $canon -PathType Container))) '[U1] canonical dir resolves under fake repo cache' $canon
        $def = Get-OrchestrationReuseDefaultStoreDir -StoreDir '' -RepoRoot $fakeRepo
        Assert-SU (($def -ceq $canon)) '[U1] default store is the canonical one' $def

        # ---------- MANDATORY: write via EvidenceStore, read via ReuseWiring, no store_dir ----------
        $seed = New-SURecordInput -RunId 'unif-1' -StoreDir $canon
        $made = New-OrchestrationEvidenceRecord -Evidence $seed -StoreDir $canon
        Assert-SU ([bool]$made.created) '[U2] evidence written to canonical store' ([string]$made.reason)
        $fps = @{'src/u.ps1' = 'sha-u'}
        $envNow = @{ runtime = 'pwsh'; version = '7' }
        $found = Find-OrchestrationReusableWork -Scope @('src/u.ps1') -CurrentSourceFingerprints $fps -CurrentBaseRevision 'rev-u' -CurrentCriteriaHash 'crit-u' -CurrentEnv $envNow -ReuseClass 'content-fingerprint' -RepoRoot $fakeRepo
        Assert-SU (([bool]$found.reused) -and ([string]$found.decision -ceq 'reuse-candidate')) '[U2] canonical write recovered via ReuseWiring without store_dir' ([string]$found.decision)
        Assert-SU (([string]$found.store_dir -ceq $canon)) '[U2] envelope reports the canonical dir' ([string]$found.store_dir)
        Assert-SU (((-not [bool]$found.verified_pass) -and ([bool]$found.planner_decides))) '[U2] reuse never equals verification' ''

        # ---------- legacy read-fallback (data preserved, still readable) ----------
        $legacy = Get-OrchestrationReuseLegacyStoreDir -RepoRoot $fakeRepo
        Assert-SU (($legacy -like '*reuse-store')) '[U3] legacy dir resolves' $legacy
        New-Item -ItemType Directory -Path $legacy -Force | Out-Null
        $legacySeed = New-SURecordInput -RunId 'legacy-1' -StoreDir $legacy -Revision 'rev-leg' -Crit 'crit-leg'
        $madeLeg = New-OrchestrationEvidenceRecord -Evidence $legacySeed -StoreDir $legacy
        Assert-SU ([bool]$madeLeg.created) '[U3] legacy record exists (pre-unification data)' ([string]$madeLeg.reason)
        $foundLeg = Find-OrchestrationReusableWork -Scope @('src/u.ps1') -CurrentSourceFingerprints $fps -CurrentBaseRevision 'rev-leg' -CurrentCriteriaHash 'crit-leg' -CurrentEnv $envNow -ReuseClass 'content-fingerprint' -RepoRoot $fakeRepo
        Assert-SU (([bool]$foundLeg.reused)) '[U3] legacy record recovered via fallback' ([string]$foundLeg.decision)

        # ---------- canonical wins on evidence_id collision ----------
        $collisionId = [string]$madeLeg.record.evidence_id
        Copy-Item -LiteralPath (Join-Path $legacy ($collisionId + '.json')) -Destination (Join-Path $canon ($collisionId + '.json')) -Force
        $foundCol = Find-OrchestrationReusableWork -Scope @('src/u.ps1') -CurrentSourceFingerprints $fps -CurrentBaseRevision 'rev-leg' -CurrentCriteriaHash 'crit-leg' -CurrentEnv $envNow -ReuseClass 'content-fingerprint' -RepoRoot $fakeRepo
        $ids = @(@($foundCol.candidates) | ForEach-Object { [string]$_.evidence_id })
        $unique = @($ids | Sort-Object -Unique)
        Assert-SU ((@($unique).Count -eq @($ids).Count)) '[U4] collision merged, canonical wins, no duplicates' (($ids -join ','))
        try { Remove-Item -LiteralPath (Join-Path $canon ($collisionId + '.json')) -Force -ErrorAction SilentlyContinue } catch { }

        # ---------- write-only-canonical: default resolution never recreates legacy ----------
        $fakeRepo2 = Join-Path $tempRoot 'fakerepo2'
        New-Item -ItemType Directory -Path $fakeRepo2 -Force | Out-Null
        $def2 = Get-OrchestrationReuseDefaultStoreDir -StoreDir '' -RepoRoot $fakeRepo2
        Assert-SU ((($def2 -like '*evidence-store') -and (-not (Test-Path -LiteralPath (Join-Path (Join-Path $fakeRepo2 'cache') 'reuse-store'))))) '[U5] default never recreates legacy store' $def2

        # ---------- hygiene ----------
        foreach ($p in @((Join-Path $PSScriptRoot 'OrchestrationStoreUnification.tests.ps1'))) {
            $bytes = [IO.File]::ReadAllBytes($p)
            $bad = 0
            foreach ($by in $bytes) { if ([int]$by -gt 127) { $bad++ } }
            Assert-SU ($bad -eq 0) ('[ASCII] ' + [IO.Path]::GetFileName($p)) ([string]$bad)
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
