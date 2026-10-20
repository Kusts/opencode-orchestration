<#!
.SYNOPSIS
    Tests for lib/OrchestrationNativeDispatchGrantProjection.ps1 (F1-S5).
.DESCRIPTION
    Hermetic: temp dirs under $env:TEMP, fixture flags/registry files,
    cleanup in finally. Bracketed output the runner parses. Exit 0 on all
    pass, exit 1 on any fail or unexpected exception. PS 5.1 and PS7.
    ASCII-only.

    Covers (plan section 8.1):
      * snapshot: valid role/grants (sorted, authority=false,
        denied_by_default=true, 32hex source_revision, deterministic and
        source-sensitive); unknown role (ok, empty effective); missing
        role/task/registry (fail-closed codes); invalid registry/task
        shape; runtime/env empty (empty effective); sensitive grant
        excluded without HumanApproved and included with the three lists +
        approval; task grant outside the baseline excluded; HumanApproved
        non-bool rejected; non-string array elements rejected; scalar
        task-grants normalized (single-grant kernel record); flags
        missing/relative rejected; zero allow/authority.
      * projection: clear; outside-effective/unknown/invocation-extra/
        case-divergent denied (ordinal); duplicates deduped; empty request
        clear; invalid snapshot/request shapes (scalar, number, array with
        non-string, empty string, object, forged authority/revision);
        authority=false always; never allow.
      * adversarial: strictness at the projection boundary (scalar request,
        forged snapshot); nested single-element JSON arrays evaluate
        (preserved on both engines); envelope beyond 64 KiB falls back
        to the encode-failed literal carrying the refused projection.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$libDir = $PSScriptRoot
$ndPath = Join-Path $libDir 'OrchestrationNativeDispatch.ps1'
. $ndPath
$kernelPath = Join-Path $libDir 'OrchestrationTaskKernel.ps1'
. $kernelPath
$projPath = Join-Path $libDir 'OrchestrationNativeDispatchGrantProjection.ps1'
. $projPath
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $libDir))
$canonGrants = Join-Path $repoRoot 'source\registry\execution-grants.json'

$script:passed = 0
$script:failed = 0

function Assert-GP {
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

function Write-GPFixture {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $lf = (($Text -replace "`r`n", "`n") -replace "`r", "`n")
    [IO.File]::WriteAllText($Path, $lf, [Text.UTF8Encoding]::new($false))
}

function New-GPTask {
    param($Grants = @(), [long]$Revision = 3)
    $g = $Grants
    if ($null -eq $g) { $g = $null }
    return [pscustomobject][ordered]@{
        task_id  = 'gp-task-01'
        revision = $Revision
        grants   = $g
    }
}

function Test-GPHex32 {
    param([string]$Value = '')
    try { return (([string]$Value) -cmatch '\A[a-f0-9]{32}\z') } catch { return $false }
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('v3-ndgp-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$flagsPath = Join-Path $tempRoot 'flags.json'
Write-GPFixture -Path $flagsPath -Text '{"task_kernel":{"enabled":true,"shadow":false}}'
$flagsPath2 = Join-Path $tempRoot 'flags2.json'
Write-GPFixture -Path $flagsPath2 -Text '{"task_kernel":{"enabled":true,"shadow":true}}'

try {
    Assert-GP (Test-Path -LiteralPath $canonGrants -PathType Leaf) 'fixture canonical registry present' $canonGrants
    Assert-GP ($null -ne (Get-Command Get-NDGrantSourceSnapshot -ErrorAction SilentlyContinue)) 'snapshot function loaded' 'missing'
    Assert-GP ($null -ne (Get-Command Test-NDGrantProjection -ErrorAction SilentlyContinue)) 'projection function loaded' 'missing'

    # ---------- snapshot: valid ----------
    $task = New-GPTask -Grants @('git.diff', 'fs.read') -Revision 3
    $snap = Get-NDGrantSourceSnapshot -Role 'coder' -Task $task -RuntimeCapabilityGrants @('fs.read', 'git.diff') -EnvironmentGrants @('fs.read', 'git.diff') -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot
    Assert-GP ([bool](Get-NDGPRawField -Object $snap -Name 'ok').value) 'snapshot valid ok' ''
    Assert-GP (([string]$snap.reason) -ceq '') 'snapshot valid empty reason' ([string]$snap.reason)
    $sgr = @((Get-NDGPRawField -Object $snap -Name 'grants').value)
    Assert-GP ((@($sgr).Count -eq 2) -and (([string]$sgr[0]) -ceq 'fs.read') -and (([string]$sgr[1]) -ceq 'git.diff')) 'snapshot grants sorted ordinal' (@($sgr) -join ',')
    Assert-GP ([bool]$snap.denied_by_default) 'snapshot denied_by_default true' ''
    Assert-GP ([bool]$snap.authority -eq $false) 'snapshot authority false' ''
    Assert-GP (Test-GPHex32 -Value ([string]$snap.source_revision)) 'snapshot source_revision 32hex' ([string]$snap.source_revision)
    Assert-GP ($null -eq $snap.PSObject.Properties['allow']) 'snapshot carries no allow field' ''
    $snap2 = Get-NDGrantSourceSnapshot -Role 'coder' -Task $task -RuntimeCapabilityGrants @('fs.read', 'git.diff') -EnvironmentGrants @('fs.read', 'git.diff') -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot
    Assert-GP (([string]$snap2.source_revision) -ceq ([string]$snap.source_revision)) 'snapshot source_revision deterministic' ''
    $snapDiff = Get-NDGrantSourceSnapshot -Role 'coder' -Task $task -RuntimeCapabilityGrants @('fs.read') -EnvironmentGrants @('fs.read') -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot
    Assert-GP (([string]$snapDiff.source_revision) -cne ([string]$snap.source_revision)) 'snapshot revision sensitive to effective change' ''
    $snapDiffF = Get-NDGrantSourceSnapshot -Role 'coder' -Task $task -RuntimeCapabilityGrants @('fs.read', 'git.diff') -EnvironmentGrants @('fs.read', 'git.diff') -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath2 -RepoRoot $repoRoot
    Assert-GP (([string]$snapDiffF.source_revision) -cne ([string]$snap.source_revision)) 'snapshot revision sensitive to flags change' ''
    $snapDefaultGp = Get-NDGrantSourceSnapshot -Role 'coder' -Task $task -RuntimeCapabilityGrants @('fs.read', 'git.diff') -EnvironmentGrants @('fs.read', 'git.diff') -HumanApproved:$false -GrantsPath '' -FlagsPath $flagsPath -RepoRoot $repoRoot
    Assert-GP (([bool]$snapDefaultGp.ok) -and (([string]$snapDefaultGp.source_revision) -ceq ([string]$snap.source_revision))) 'snapshot default grants path resolves canonically' ([string]$snapDefaultGp.reason)

    # ---------- snapshot: role ----------
    $snapUR = Get-NDGrantSourceSnapshot -Role 'no-such-role' -Task $task -RuntimeCapabilityGrants @('fs.read') -EnvironmentGrants @('fs.read') -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot
    Assert-GP (([bool]$snapUR.ok) -and (@((Get-NDGPRawField -Object $snapUR -Name 'grants').value).Count -eq 0)) 'snapshot unknown role ok with empty effective' ([string]$snapUR.reason)
    $snapNR = Get-NDGrantSourceSnapshot -Role '' -Task $task -RuntimeCapabilityGrants @() -EnvironmentGrants @() -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot
    Assert-GP ((-not [bool]$snapNR.ok) -and (([string]$snapNR.reason) -ceq 'grant-source-role-missing')) 'snapshot missing role fail-closed' ([string]$snapNR.reason)
    Assert-GP ([bool]$snapNR.authority -eq $false) 'snapshot failure keeps authority false' ''
    $snapWS = Get-NDGrantSourceSnapshot -Role '   ' -Task $task -RuntimeCapabilityGrants @() -EnvironmentGrants @() -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot
    Assert-GP ((-not [bool]$snapWS.ok) -and (([string]$snapWS.reason) -ceq 'grant-source-role-missing')) 'snapshot whitespace role fail-closed' ([string]$snapWS.reason)

    # ---------- snapshot: task ----------
    $snapNT = Get-NDGrantSourceSnapshot -Role 'coder' -Task $null -RuntimeCapabilityGrants @() -EnvironmentGrants @() -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot
    Assert-GP ((-not [bool]$snapNT.ok) -and (([string]$snapNT.reason) -ceq 'grant-source-task-missing')) 'snapshot null task fail-closed' ([string]$snapNT.reason)
    $taskNF = [pscustomobject][ordered]@{ error = 'NOT_FOUND' }
    $snapNF = Get-NDGrantSourceSnapshot -Role 'coder' -Task $taskNF -RuntimeCapabilityGrants @() -EnvironmentGrants @() -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot
    Assert-GP ((-not [bool]$snapNF.ok) -and (([string]$snapNF.reason) -ceq 'grant-source-task-missing')) 'snapshot NOT_FOUND task fail-closed' ([string]$snapNF.reason)
    $taskMal = [pscustomobject][ordered]@{ error = 'MALFORMED' }
    $snapMal = Get-NDGrantSourceSnapshot -Role 'coder' -Task $taskMal -RuntimeCapabilityGrants @() -EnvironmentGrants @() -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot
    Assert-GP ((-not [bool]$snapMal.ok) -and (([string]$snapMal.reason) -ceq 'grant-source-invalid')) 'snapshot MALFORMED task invalid' ([string]$snapMal.reason)
    $taskNoGrants = [pscustomobject][ordered]@{ task_id = 'x'; revision = 1 }
    $snapNG = Get-NDGrantSourceSnapshot -Role 'coder' -Task $taskNoGrants -RuntimeCapabilityGrants @() -EnvironmentGrants @() -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot
    Assert-GP ((-not [bool]$snapNG.ok) -and (([string]$snapNG.reason) -ceq 'grant-source-invalid')) 'snapshot task without grants invalid' ([string]$snapNG.reason)
    $taskNumGrants = [pscustomobject][ordered]@{ task_id = 'x'; revision = 1; grants = 7 }
    $snapNumG = Get-NDGrantSourceSnapshot -Role 'coder' -Task $taskNumGrants -RuntimeCapabilityGrants @() -EnvironmentGrants @() -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot
    Assert-GP ((-not [bool]$snapNumG.ok) -and (([string]$snapNumG.reason) -ceq 'grant-source-invalid')) 'snapshot numeric task grants invalid' ([string]$snapNumG.reason)
    $taskArrNum = [pscustomobject][ordered]@{ task_id = 'x'; revision = 1; grants = @('fs.read', 7) }
    $snapArrNum = Get-NDGrantSourceSnapshot -Role 'coder' -Task $taskArrNum -RuntimeCapabilityGrants @() -EnvironmentGrants @() -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot
    Assert-GP ((-not [bool]$snapArrNum.ok) -and (([string]$snapArrNum.reason) -ceq 'grant-source-invalid')) 'snapshot array with number invalid' ([string]$snapArrNum.reason)
    $taskEmptyStr = [pscustomobject][ordered]@{ task_id = 'x'; revision = 1; grants = @('fs.read', '  ') }
    $snapEmptyStr = Get-NDGrantSourceSnapshot -Role 'coder' -Task $taskEmptyStr -RuntimeCapabilityGrants @() -EnvironmentGrants @() -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot
    Assert-GP ((-not [bool]$snapEmptyStr.ok) -and (([string]$snapEmptyStr.reason) -ceq 'grant-source-invalid')) 'snapshot whitespace grant invalid' ([string]$snapEmptyStr.reason)
    $taskScalar = [pscustomobject][ordered]@{ task_id = 'x'; revision = 1; grants = 'fs.read' }
    $snapScalar = Get-NDGrantSourceSnapshot -Role 'coder' -Task $taskScalar -RuntimeCapabilityGrants @('fs.read') -EnvironmentGrants @('fs.read') -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot
    Assert-GP (([bool]$snapScalar.ok) -and (@((Get-NDGPRawField -Object $snapScalar -Name 'grants').value).Count -eq 1)) 'snapshot scalar task grant normalized (single-grant record)' ([string]$snapScalar.reason)

    # ---------- snapshot: registry ----------
    $snapRM = Get-NDGrantSourceSnapshot -Role 'coder' -Task $task -RuntimeCapabilityGrants @() -EnvironmentGrants @() -HumanApproved:$false -GrantsPath (Join-Path $tempRoot 'no-such-registry.json') -FlagsPath $flagsPath -RepoRoot $repoRoot
    Assert-GP ((-not [bool]$snapRM.ok) -and (([string]$snapRM.reason) -ceq 'grant-source-registry-missing')) 'snapshot missing registry fail-closed' ([string]$snapRM.reason)
    $badReg = Join-Path $tempRoot 'bad-registry.json'
    Write-GPFixture -Path $badReg -Text '{not json'
    $snapBR = Get-NDGrantSourceSnapshot -Role 'coder' -Task $task -RuntimeCapabilityGrants @() -EnvironmentGrants @() -HumanApproved:$false -GrantsPath $badReg -FlagsPath $flagsPath -RepoRoot $repoRoot
    Assert-GP ((-not [bool]$snapBR.ok) -and (([string]$snapBR.reason) -ceq 'grant-source-registry-invalid')) 'snapshot malformed registry registry-invalid (F1)' ([string]$snapBR.reason)
    $thinReg = Join-Path $tempRoot 'thin-registry.json'
    Write-GPFixture -Path $thinReg -Text '{"version":1}'
    $snapTR = Get-NDGrantSourceSnapshot -Role 'coder' -Task $task -RuntimeCapabilityGrants @() -EnvironmentGrants @() -HumanApproved:$false -GrantsPath $thinReg -FlagsPath $flagsPath -RepoRoot $repoRoot
    Assert-GP ((-not [bool]$snapTR.ok) -and (([string]$snapTR.reason) -ceq 'grant-source-registry-invalid')) 'snapshot registry without keys registry-invalid (F1)' ([string]$snapTR.reason)

    # ---------- F1: registry semantics (fail-closed before intersection) ----------
    $regEvil = Join-Path $tempRoot 'evil-registry.json'
    Write-GPFixture -Path $regEvil -Text '{"version":1,"grants":["fs.read"],"role_baselines":{"coder":["fs.read","no.such.grant"]}}'
    $taskEvil = New-GPTask -Grants @('fs.read', 'no.such.grant') -Revision 1
    $snapEvil = Get-NDGrantSourceSnapshot -Role 'coder' -Task $taskEvil -RuntimeCapabilityGrants @('fs.read', 'no.such.grant') -EnvironmentGrants @('fs.read', 'no.such.grant') -HumanApproved:$false -GrantsPath $regEvil -FlagsPath $flagsPath -RepoRoot $repoRoot
    Assert-GP ((-not [bool]$snapEvil.ok) -and (([string]$snapEvil.reason) -ceq 'grant-source-registry-invalid')) 'F1 unknown baseline grant registry-invalid (no bogus clear)' ([string]$snapEvil.reason)
    Assert-GP ([bool]$snapEvil.authority -eq $false) 'F1 evil registry keeps authority false' ''
    $regSmall = Join-Path $tempRoot 'small-registry.json'
    Write-GPFixture -Path $regSmall -Text '{"version":1,"grants":["fs.read","git.diff"],"role_baselines":{"coder":["fs.read"]}}'
    $snapSmall = Get-NDGrantSourceSnapshot -Role 'coder' -Task $task -RuntimeCapabilityGrants @('fs.read', 'git.diff') -EnvironmentGrants @('fs.read', 'git.diff') -HumanApproved:$false -GrantsPath $regSmall -FlagsPath $flagsPath -RepoRoot $repoRoot
    Assert-GP (([bool]$snapSmall.ok) -and (@((Get-NDGPRawField -Object $snapSmall -Name 'grants').value).Count -eq 1)) 'F1 minimal valid registry ok' ([string]$snapSmall.reason)
    $regEmptyBase = Join-Path $tempRoot 'emptybase-registry.json'
    Write-GPFixture -Path $regEmptyBase -Text '{"version":1,"grants":["fs.read"],"role_baselines":{"coder":[]}}'
    $snapEmptyBase = Get-NDGrantSourceSnapshot -Role 'coder' -Task $task -RuntimeCapabilityGrants @('fs.read') -EnvironmentGrants @('fs.read') -HumanApproved:$false -GrantsPath $regEmptyBase -FlagsPath $flagsPath -RepoRoot $repoRoot
    Assert-GP (([bool]$snapEmptyBase.ok) -and (@((Get-NDGPRawField -Object $snapEmptyBase -Name 'grants').value).Count -eq 0)) 'F1 empty baseline array valid with empty effective' ([string]$snapEmptyBase.reason)
    $regCases = @(
        @{ name = 'null grants'; text = '{"version":1,"grants":null,"role_baselines":{"coder":[]}}' },
        @{ name = 'scalar grants'; text = '{"version":1,"grants":"fs.read","role_baselines":{"coder":[]}}' },
        @{ name = 'duplicate grants'; text = '{"version":1,"grants":["fs.read","fs.read"],"role_baselines":{"coder":[]}}' },
        @{ name = 'empty-string grant'; text = '{"version":1,"grants":["fs.read"," "],"role_baselines":{"coder":[]}}' },
        @{ name = 'numeric grant'; text = '{"version":1,"grants":["fs.read",7],"role_baselines":{"coder":[]}}' },
        @{ name = 'null baselines'; text = '{"version":1,"grants":["fs.read"],"role_baselines":null}' },
        @{ name = 'array baselines'; text = '{"version":1,"grants":["fs.read"],"role_baselines":[]}' },
        @{ name = 'scalar baselines'; text = '{"version":1,"grants":["fs.read"],"role_baselines":"x"}' },
        @{ name = 'scalar baseline value'; text = '{"version":1,"grants":["fs.read"],"role_baselines":{"coder":"fs.read"}}' },
        @{ name = 'null baseline value'; text = '{"version":1,"grants":["fs.read"],"role_baselines":{"coder":null}}' },
        @{ name = 'duplicate baseline entry'; text = '{"version":1,"grants":["fs.read"],"role_baselines":{"coder":["fs.read","fs.read"]}}' },
        @{ name = 'numeric baseline entry'; text = '{"version":1,"grants":["fs.read"],"role_baselines":{"coder":[7]}}' },
        @{ name = 'blank baseline entry'; text = '{"version":1,"grants":["fs.read"],"role_baselines":{"coder":[""]}}' },
        @{ name = 'version 2'; text = '{"version":2,"grants":["fs.read"],"role_baselines":{"coder":[]}}' },
        @{ name = 'string version'; text = '{"version":"1","grants":["fs.read"],"role_baselines":{"coder":[]}}' },
        @{ name = 'missing version'; text = '{"grants":["fs.read"],"role_baselines":{"coder":[]}}' }
    )
    $regIdx = 0
    foreach ($rc in $regCases) {
        $regIdx++
        $rp = Join-Path $tempRoot ('f1-reg-' + $regIdx + '.json')
        Write-GPFixture -Path $rp -Text $rc.text
        $sr = Get-NDGrantSourceSnapshot -Role 'coder' -Task $task -RuntimeCapabilityGrants @('fs.read') -EnvironmentGrants @('fs.read') -HumanApproved:$false -GrantsPath $rp -FlagsPath $flagsPath -RepoRoot $repoRoot
        Assert-GP ((-not [bool]$sr.ok) -and (([string]$sr.reason) -ceq 'grant-source-registry-invalid') -and ([bool]$sr.authority -eq $false)) ("F1 registry case: " + $rc.name) ([string]$sr.reason)
    }

    # ---------- snapshot: empty runtime/env (fail-closed intersection) ----------
    $snapEmpty = Get-NDGrantSourceSnapshot -Role 'coder' -Task $task -RuntimeCapabilityGrants @() -EnvironmentGrants @() -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot
    Assert-GP (([bool]$snapEmpty.ok) -and (@((Get-NDGPRawField -Object $snapEmpty -Name 'grants').value).Count -eq 0)) 'snapshot empty runtime/env yields empty effective' ([string]$snapEmpty.reason)

    # ---------- snapshot: sensitive grants ----------
    $taskSens = New-GPTask -Grants @('fs.read', 'git.push') -Revision 5
    $snapSensOff = Get-NDGrantSourceSnapshot -Role 'coder' -Task $taskSens -RuntimeCapabilityGrants @('fs.read', 'git.push') -EnvironmentGrants @('fs.read', 'git.push') -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot
    $sensOffGrants = @((Get-NDGPRawField -Object $snapSensOff -Name 'grants').value)
    Assert-GP (([bool]$snapSensOff.ok) -and ($sensOffGrants -cnotcontains 'git.push')) 'snapshot sensitive excluded without approval' (@($sensOffGrants) -join ',')
    $snapSensOn = Get-NDGrantSourceSnapshot -Role 'coder' -Task $taskSens -RuntimeCapabilityGrants @('fs.read', 'git.push') -EnvironmentGrants @('fs.read', 'git.push') -HumanApproved:$true -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot
    $sensOnGrants = @((Get-NDGPRawField -Object $snapSensOn -Name 'grants').value)
    Assert-GP (([bool]$snapSensOn.ok) -and ($sensOnGrants -ccontains 'git.push') -and ($sensOnGrants -ccontains 'fs.read')) 'snapshot sensitive included with three lists plus approval' (@($sensOnGrants) -join ',')
    $snapSensPartial = Get-NDGrantSourceSnapshot -Role 'coder' -Task $taskSens -RuntimeCapabilityGrants @('fs.read') -EnvironmentGrants @('fs.read', 'git.push') -HumanApproved:$true -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot
    $sensPartGrants = @((Get-NDGPRawField -Object $snapSensPartial -Name 'grants').value)
    Assert-GP (([bool]$snapSensPartial.ok) -and ($sensPartGrants -cnotcontains 'git.push')) 'snapshot sensitive excluded when one list lacks it' (@($sensPartGrants) -join ',')

    # ---------- snapshot: outside baseline ----------
    $taskOut = New-GPTask -Grants @('fs.read', 'deploy.production') -Revision 2
    $snapOut = Get-NDGrantSourceSnapshot -Role 'coder' -Task $taskOut -RuntimeCapabilityGrants @('fs.read', 'deploy.production') -EnvironmentGrants @('fs.read', 'deploy.production') -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot
    $outGrants = @((Get-NDGPRawField -Object $snapOut -Name 'grants').value)
    Assert-GP (([bool]$snapOut.ok) -and ($outGrants -cnotcontains 'deploy.production') -and ($outGrants -ccontains 'fs.read')) 'snapshot grant outside baseline excluded' (@($outGrants) -join ',')

    # ---------- F1-FIX2: sensitive grants rejected in baselines ----------
    # Exact reviewer scenario: universe+baseline carry git.push, present in
    # all three lists, HumanApproved=false. The plain intersection would
    # keep it and project clear; the semantic check must refuse first.
    $regSensBase = Join-Path $tempRoot 'sensbase-registry.json'
    Write-GPFixture -Path $regSensBase -Text '{"version":1,"grants":["fs.read","git.push"],"role_baselines":{"coder":["fs.read","git.push"]}}'
    $taskSensBase = New-GPTask -Grants @('fs.read', 'git.push') -Revision 1
    $snapSensBase = Get-NDGrantSourceSnapshot -Role 'coder' -Task $taskSensBase -RuntimeCapabilityGrants @('fs.read', 'git.push') -EnvironmentGrants @('fs.read', 'git.push') -HumanApproved:$false -GrantsPath $regSensBase -FlagsPath $flagsPath -RepoRoot $repoRoot
    Assert-GP ((-not [bool]$snapSensBase.ok) -and (([string]$snapSensBase.reason) -ceq 'grant-source-registry-invalid')) 'FIX2 sensitive in baseline registry-invalid even with all lists present (never clear)' ([string]$snapSensBase.reason)
    Assert-GP ([bool]$snapSensBase.authority -eq $false) 'FIX2 sensitive baseline keeps authority false' ''
    foreach ($sg in @(Get-TaskKernelSensitiveGrants)) {
        $sgp = Join-Path $tempRoot 'sens-one.json'
        Write-GPFixture -Path $sgp -Text ('{"version":1,"grants":["fs.read","' + [string]$sg + '"],"role_baselines":{"coder":["fs.read","' + [string]$sg + '"]}}')
        $ssr = Get-NDGrantSourceSnapshot -Role 'coder' -Task (New-GPTask -Grants @('fs.read') -Revision 1) -RuntimeCapabilityGrants @('fs.read') -EnvironmentGrants @('fs.read') -HumanApproved:$false -GrantsPath $sgp -FlagsPath $flagsPath -RepoRoot $repoRoot
        Assert-GP ((-not [bool]$ssr.ok) -and (([string]$ssr.reason) -ceq 'grant-source-registry-invalid')) ("FIX2 sensitive baseline rejected: " + [string]$sg) ([string]$ssr.reason)
    }
    $projSensLegit = Test-NDGrantProjection -Snapshot $snapSensOn -RequestedGrants @('fs.read', 'git.push')
    Assert-GP (([bool]$projSensLegit.ok) -and (([string]$projSensLegit.reason) -ceq 'grant-projection-clear')) 'FIX2 legit sensitive path (approval, clean baselines) still clear' ([string]$projSensLegit.reason)
    # ---------- F2: revision binding ----------
    $snapMatch = Get-NDGrantSourceSnapshot -Role 'coder' -Task $task -RuntimeCapabilityGrants @('fs.read', 'git.diff') -EnvironmentGrants @('fs.read', 'git.diff') -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot -ExpectedRevision 3
    Assert-GP ([bool]$snapMatch.ok) 'F2 matching expected revision ok' ([string]$snapMatch.reason)
    $snapMismatch = Get-NDGrantSourceSnapshot -Role 'coder' -Task $task -RuntimeCapabilityGrants @('fs.read', 'git.diff') -EnvironmentGrants @('fs.read', 'git.diff') -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot -ExpectedRevision 4
    Assert-GP ((-not [bool]$snapMismatch.ok) -and (([string]$snapMismatch.reason) -ceq 'grant-source-task-revision-mismatch')) 'F2 divergent revision mismatch' ([string]$snapMismatch.reason)
    Assert-GP ([bool]$snapMismatch.authority -eq $false) 'F2 mismatch keeps authority false' ''
    $snapExpStr = Get-NDGrantSourceSnapshot -Role 'coder' -Task $task -RuntimeCapabilityGrants @('fs.read', 'git.diff') -EnvironmentGrants @('fs.read', 'git.diff') -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot -ExpectedRevision '3'
    Assert-GP ((-not [bool]$snapExpStr.ok) -and (([string]$snapExpStr.reason) -ceq 'grant-source-task-revision-mismatch')) 'F2 string expected revision mismatch (no coercion)' ([string]$snapExpStr.reason)
    $snapExpZero = Get-NDGrantSourceSnapshot -Role 'coder' -Task $task -RuntimeCapabilityGrants @('fs.read', 'git.diff') -EnvironmentGrants @('fs.read', 'git.diff') -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot -ExpectedRevision 0
    Assert-GP ((-not [bool]$snapExpZero.ok) -and (([string]$snapExpZero.reason) -ceq 'grant-source-task-revision-mismatch')) 'F2 stale expected revision mismatch' ([string]$snapExpZero.reason)

    # ---------- F2-FIX2: exact integer task revision (no coercion) ----------
    $taskStrRev = [pscustomobject][ordered]@{ task_id = 'gp-x'; revision = '3'; grants = @('fs.read', 'git.diff') }
    $snapStrRev = Get-NDGrantSourceSnapshot -Role 'coder' -Task $taskStrRev -RuntimeCapabilityGrants @('fs.read', 'git.diff') -EnvironmentGrants @('fs.read', 'git.diff') -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot -ExpectedRevision 3
    Assert-GP ((-not [bool]$snapStrRev.ok) -and (([string]$snapStrRev.reason) -ceq 'grant-source-task-revision-mismatch')) 'FIX2 string task revision mismatch (no coercion)' ([string]$snapStrRev.reason)
    $taskDblRev = [pscustomobject][ordered]@{ task_id = 'gp-x'; revision = 3.0; grants = @('fs.read', 'git.diff') }
    $snapDblRev = Get-NDGrantSourceSnapshot -Role 'coder' -Task $taskDblRev -RuntimeCapabilityGrants @('fs.read', 'git.diff') -EnvironmentGrants @('fs.read', 'git.diff') -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot -ExpectedRevision 3
    Assert-GP ((-not [bool]$snapDblRev.ok) -and (([string]$snapDblRev.reason) -ceq 'grant-source-task-revision-mismatch')) 'FIX2 fractional task revision mismatch' ([string]$snapDblRev.reason)
    $taskNullRev = [pscustomobject][ordered]@{ task_id = 'gp-x'; revision = $null; grants = @('fs.read', 'git.diff') }
    $snapNullRev = Get-NDGrantSourceSnapshot -Role 'coder' -Task $taskNullRev -RuntimeCapabilityGrants @('fs.read', 'git.diff') -EnvironmentGrants @('fs.read', 'git.diff') -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot -ExpectedRevision 3
    Assert-GP ((-not [bool]$snapNullRev.ok) -and (([string]$snapNullRev.reason) -ceq 'grant-source-task-revision-mismatch')) 'FIX2 null task revision mismatch' ([string]$snapNullRev.reason)
    $taskNoRev = [pscustomobject][ordered]@{ task_id = 'gp-x'; grants = @('fs.read', 'git.diff') }
    $snapNoRev = Get-NDGrantSourceSnapshot -Role 'coder' -Task $taskNoRev -RuntimeCapabilityGrants @('fs.read', 'git.diff') -EnvironmentGrants @('fs.read', 'git.diff') -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot -ExpectedRevision 3
    Assert-GP ((-not [bool]$snapNoRev.ok) -and (([string]$snapNoRev.reason) -ceq 'grant-source-task-revision-mismatch')) 'FIX2 missing task revision mismatch' ([string]$snapNoRev.reason)
    $taskIntRev = [pscustomobject][ordered]@{ task_id = 'gp-x'; revision = [int]3; grants = @('fs.read', 'git.diff') }
    $snapIntRev = Get-NDGrantSourceSnapshot -Role 'coder' -Task $taskIntRev -RuntimeCapabilityGrants @('fs.read', 'git.diff') -EnvironmentGrants @('fs.read', 'git.diff') -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot -ExpectedRevision 3
    Assert-GP ([bool]$snapIntRev.ok) 'FIX2 exact int task revision ok' ([string]$snapIntRev.reason)
    $snapUnboundStr = Get-NDGrantSourceSnapshot -Role 'coder' -Task $taskStrRev -RuntimeCapabilityGrants @('fs.read', 'git.diff') -EnvironmentGrants @('fs.read', 'git.diff') -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot
    Assert-GP ([bool]$snapUnboundStr.ok) 'FIX2 unbound string revision ok (no binding to violate)' ([string]$snapUnboundStr.reason)

    # ---------- snapshot: strict input types ----------
    $snapHA1 = Get-NDGrantSourceSnapshot -Role 'coder' -Task $task -RuntimeCapabilityGrants @('fs.read') -EnvironmentGrants @('fs.read') -HumanApproved 1 -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot
    Assert-GP ((-not [bool]$snapHA1.ok) -and (([string]$snapHA1.reason) -ceq 'grant-source-invalid')) 'snapshot numeric human_approved invalid (no coercion)' ([string]$snapHA1.reason)
    $snapHAS = Get-NDGrantSourceSnapshot -Role 'coder' -Task $task -RuntimeCapabilityGrants @('fs.read') -EnvironmentGrants @('fs.read') -HumanApproved 'true' -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot
    Assert-GP ((-not [bool]$snapHAS.ok) -and (([string]$snapHAS.reason) -ceq 'grant-source-invalid')) 'snapshot string human_approved invalid (no coercion)' ([string]$snapHAS.reason)
    $snapRTNum = Get-NDGrantSourceSnapshot -Role 'coder' -Task $task -RuntimeCapabilityGrants @('fs.read', 7) -EnvironmentGrants @('fs.read') -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot
    Assert-GP ((-not [bool]$snapRTNum.ok) -and (([string]$snapRTNum.reason) -ceq 'grant-source-invalid')) 'snapshot numeric runtime grant invalid' ([string]$snapRTNum.reason)
    $snapRTScalar = Get-NDGrantSourceSnapshot -Role 'coder' -Task $task -RuntimeCapabilityGrants 'fs.read' -EnvironmentGrants @('fs.read') -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot
    Assert-GP ((-not [bool]$snapRTScalar.ok) -and (([string]$snapRTScalar.reason) -ceq 'grant-source-invalid')) 'snapshot scalar runtime grants invalid (no promotion)' ([string]$snapRTScalar.reason)
    $snapRelFlags = Get-NDGrantSourceSnapshot -Role 'coder' -Task $task -RuntimeCapabilityGrants @('fs.read') -EnvironmentGrants @('fs.read') -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath 'relative\flags.json' -RepoRoot $repoRoot
    Assert-GP ((-not [bool]$snapRelFlags.ok) -and (([string]$snapRelFlags.reason) -ceq 'grant-source-invalid')) 'snapshot relative flags path invalid' ([string]$snapRelFlags.reason)
    $snapNoFlags = Get-NDGrantSourceSnapshot -Role 'coder' -Task $task -RuntimeCapabilityGrants @('fs.read') -EnvironmentGrants @('fs.read') -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath (Join-Path $tempRoot 'no-flags.json') -RepoRoot $repoRoot
    Assert-GP ((-not [bool]$snapNoFlags.ok) -and (([string]$snapNoFlags.reason) -ceq 'grant-source-unavailable')) 'snapshot missing flags unavailable' ([string]$snapNoFlags.reason)

    # ---------- projection: clear ----------
    $proj = Test-NDGrantProjection -Snapshot $snap -RequestedGrants @('fs.read', 'git.diff')
    Assert-GP (([bool]$proj.ok) -and (([string]$proj.reason) -ceq 'grant-projection-clear') -and (@($proj.denied).Count -eq 0)) 'projection clear when requested within effective' ([string]$proj.reason)
    Assert-GP ([bool]$proj.authority -eq $false) 'projection authority false' ''
    Assert-GP ($null -eq $proj.PSObject.Properties['allow']) 'projection carries no allow field' ''
    $projEmpty = Test-NDGrantProjection -Snapshot $snapEmpty -RequestedGrants @()
    Assert-GP (([bool]$projEmpty.ok) -and (([string]$projEmpty.reason) -ceq 'grant-projection-clear')) 'projection empty request clear even on empty effective' ([string]$projEmpty.reason)
    $projNullReq = Test-NDGrantProjection -Snapshot $snap -RequestedGrants $null -InvocationGrants $null
    Assert-GP (([bool]$projNullReq.ok) -and (([string]$projNullReq.reason) -ceq 'grant-projection-clear')) 'projection null request treated as empty (clear)' ([string]$projNullReq.reason)

    # ---------- projection: denied ----------
    $projOut = Test-NDGrantProjection -Snapshot $snap -RequestedGrants @('fs.read', 'deploy.production')
    Assert-GP (([bool]$projOut.ok) -and (([string]$projOut.reason) -ceq 'grant-projection-denied')) 'projection outside-effective denied' ([string]$projOut.reason)
    $outDenied = @($projOut.denied)
    Assert-GP ((@($outDenied).Count -eq 1) -and (([string]$outDenied[0].grant) -ceq 'deploy.production') -and (([string]$outDenied[0].reason) -ceq 'grant-not-effective')) 'projection denied entry shape (grant+reason)' ''
    Assert-GP ([bool]$projOut.authority -eq $false) 'projection denied keeps authority false' ''
    $projUnknown = Test-NDGrantProjection -Snapshot $snap -RequestedGrants @('no.such.grant')
    Assert-GP (([bool]$projUnknown.ok) -and (@($projUnknown.denied).Count -eq 1)) 'projection unknown grant denied' ([string]$projUnknown.reason)
    $projCase = Test-NDGrantProjection -Snapshot $snap -RequestedGrants @('FS.READ')
    Assert-GP (([bool]$projCase.ok) -and (([string]$projCase.reason) -ceq 'grant-projection-denied') -and (@($projCase.denied).Count -eq 1)) 'projection case divergence denied (ordinal)' ([string]$projCase.reason)
    $projInv = Test-NDGrantProjection -Snapshot $snap -RequestedGrants @('fs.read', 'git.diff') -InvocationGrants @('shell.validation')
    Assert-GP (([bool]$projInv.ok) -and (([string]$projInv.reason) -ceq 'grant-projection-denied') -and (@($projInv.denied).Count -eq 1) -and (([string]$projInv.denied[0].grant) -ceq 'shell.validation')) 'projection invocation extra denied' ([string]$projInv.reason)
    $projDup = Test-NDGrantProjection -Snapshot $snap -RequestedGrants @('deploy.production', 'deploy.production')
    Assert-GP ((@($projDup.denied).Count -eq 1)) 'projection duplicates deduped to one denied entry' (@($projDup.denied).Count)
    $projAllDenied = Test-NDGrantProjection -Snapshot $snapEmpty -RequestedGrants @('fs.read', 'git.diff')
    Assert-GP ((@($projAllDenied.denied).Count -eq 2) -and (([string]$projAllDenied.denied[0].grant) -ceq 'fs.read') -and (([string]$projAllDenied.denied[1].grant) -ceq 'git.diff')) 'projection denied list sorted ordinal' ''
    $projSensClear = Test-NDGrantProjection -Snapshot $snapSensOn -RequestedGrants @('fs.read', 'git.push')
    Assert-GP (([bool]$projSensClear.ok) -and (([string]$projSensClear.reason) -ceq 'grant-projection-clear')) 'projection sensitive clear when effective covers it' ([string]$projSensClear.reason)
    $projSensDeny = Test-NDGrantProjection -Snapshot $snapSensOff -RequestedGrants @('fs.read', 'git.push')
    Assert-GP ((@($projSensDeny.denied).Count -eq 1) -and (([string]$projSensDeny.denied[0].grant) -ceq 'git.push')) 'projection sensitive denied when effective lacks it' ''

    # ---------- projection: invalid ----------
    $badSnaps = @(
        @{ name = 'null snapshot'; snap = $null },
        @{ name = 'array snapshot'; snap = @($snap) },
        @{ name = 'string snapshot'; snap = 'nope' },
        @{ name = 'not-ok snapshot'; snap = ([pscustomobject][ordered]@{ ok = $false; reason = 'x'; source_revision = ([string]$snap.source_revision); grants = @('fs.read'); denied_by_default = $true; authority = $false }) },
        @{ name = 'forged authority'; snap = ([pscustomobject][ordered]@{ ok = $true; reason = ''; source_revision = ([string]$snap.source_revision); grants = @('fs.read'); denied_by_default = $true; authority = $true }) },
        @{ name = 'missing authority'; snap = ([pscustomobject][ordered]@{ ok = $true; reason = ''; source_revision = ([string]$snap.source_revision); grants = @('fs.read'); denied_by_default = $true }) },
        @{ name = 'denied_by_default false'; snap = ([pscustomobject][ordered]@{ ok = $true; reason = ''; source_revision = ([string]$snap.source_revision); grants = @('fs.read'); denied_by_default = $false; authority = $false }) },
        @{ name = 'malformed revision'; snap = ([pscustomobject][ordered]@{ ok = $true; reason = ''; source_revision = 'ZZZ'; grants = @('fs.read'); denied_by_default = $true; authority = $false }) },
        @{ name = 'empty revision'; snap = ([pscustomobject][ordered]@{ ok = $true; reason = ''; source_revision = ''; grants = @('fs.read'); denied_by_default = $true; authority = $false }) },
        @{ name = 'numeric grants'; snap = ([pscustomobject][ordered]@{ ok = $true; reason = ''; source_revision = ([string]$snap.source_revision); grants = 7; denied_by_default = $true; authority = $false }) }
    )
    foreach ($bs in $badSnaps) {
        $pr = Test-NDGrantProjection -Snapshot $bs.snap -RequestedGrants @('fs.read')
        Assert-GP ((-not [bool]$pr.ok) -and (([string]$pr.reason) -ceq 'grant-projection-invalid') -and (@($pr.denied).Count -eq 0) -and ([bool]$pr.authority -eq $false)) ("projection invalid: " + $bs.name) ([string]$pr.reason)
    }
    $nestedHolder = New-Object System.Collections.ArrayList
    [void]$nestedHolder.Add(@('fs.read'))
    $nestedReq = $nestedHolder.ToArray()
    $badReqs = @(
        @{ name = 'scalar string'; req = 'fs.read'; inv = $null },
        @{ name = 'number'; req = 7; inv = $null },
        @{ name = 'bool'; req = $true; inv = $null },
        @{ name = 'object'; req = ([pscustomobject]@{ g = 'fs.read' }); inv = $null },
        @{ name = 'array with number'; req = @('fs.read', 7); inv = $null },
        @{ name = 'array with empty string'; req = @('fs.read', ''); inv = $null },
        @{ name = 'array with array'; req = $nestedReq; inv = $null },
        @{ name = 'bad invocation'; req = @('fs.read'); inv = 'shell.validation' }
    )
    foreach ($br in $badReqs) {
        $pr = Test-NDGrantProjection -Snapshot $snap -RequestedGrants $br.req -InvocationGrants $br.inv
        Assert-GP ((-not [bool]$pr.ok) -and (([string]$pr.reason) -ceq 'grant-projection-invalid')) ("projection invalid request: " + $br.name) ([string]$pr.reason)
    }

    # ---------- adversarial: nested single-element JSON arrays are preserved
    # on both engines, so a one-grant request evaluates (never coerced) ----------
    $jsonSingle = '{"grants":["fs.read"]}' | ConvertFrom-Json
    $singleRaw = $jsonSingle.grants
    $projSingle = Test-NDGrantProjection -Snapshot $snap -RequestedGrants $singleRaw
    if ($singleRaw -is [string]) {
        Assert-GP ((-not [bool]$projSingle.ok) -and (([string]$projSingle.reason) -ceq 'grant-projection-invalid')) 'projection rejects unrolled single-element scalar (strict)' ''
    }
    else {
        Assert-GP (([bool]$projSingle.ok)) 'projection evaluates preserved nested single-element array' ([string]$projSingle.reason)
    }
    $jsonEmpty = '{"grants":[]}' | ConvertFrom-Json
    $projJsonEmpty = Test-NDGrantProjection -Snapshot $snapEmpty -RequestedGrants $jsonEmpty.grants
    Assert-GP (([bool]$projJsonEmpty.ok) -and (([string]$projJsonEmpty.reason) -ceq 'grant-projection-clear')) 'projection empty JSON array clear' ([string]$projJsonEmpty.reason)

    # ---------- envelope beyond 64 KiB falls back to the refused literal ----------
    $cliPath = Join-Path (Split-Path -Parent $libDir) 'native-dispatch-claim.ps1'
    . $cliPath
    Assert-GP ($null -ne (Get-Command Write-NCEnvelope -ErrorAction SilentlyContinue)) 'bridge envelope writer available' 'missing'
    $many = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt 2500; $i++) { [void]$many.Add(('grant-' + ([string]$i).PadLeft(5, '0'))) }
    $bigSnap = Get-NDGrantSourceSnapshot -Role 'coder' -Task (New-GPTask -Grants @('fs.read') -Revision 1) -RuntimeCapabilityGrants @('fs.read') -EnvironmentGrants @('fs.read') -HumanApproved:$false -GrantsPath $canonGrants -FlagsPath $flagsPath -RepoRoot $repoRoot
    $bigProj = Test-NDGrantProjection -Snapshot $bigSnap -RequestedGrants @($many.ToArray())
    Assert-GP (([bool]$bigProj.ok) -and (([string]$bigProj.reason) -ceq 'grant-projection-denied') -and (@($bigProj.denied).Count -eq 2500)) 'projection 2500 denied entries evaluated' (@($bigProj.denied).Count)
    $bigEnv = New-NCOkEnvelope -Claim ([pscustomobject]@{ ok = $true; claimed = $true; reason = ''; session_id = 's'; message_id = 'm'; call_id = 'c' }) -Key ('a' * 32) -PreparedFp ('b' * 32) -CallFp ('c' * 32) -CallMaterial 'mat' -TargetAgent 'coder' -ToolName 'subagent' -GrantProjection ([pscustomobject][ordered]@{ ok = $true; source_revision = ([string]$bigSnap.source_revision); denied = @($bigProj.denied); reason = 'grant-projection-denied'; authority = $false })
    $bigText = ConvertTo-Json -InputObject $bigEnv -Depth 10 -Compress
    Assert-GP ($bigText.Length -gt 65536) 'oversized projection envelope exceeds 64 KiB' ("len=" + $bigText.Length)
    $caught = & {
        $ErrorActionPreference = 'Continue'
        Write-NCEnvelope $bigEnv
    }
    $caughtText = ((@($caught) | ForEach-Object { "$_" }) -join "`n")
    $caughtDoc = $null
    try { $caughtDoc = ($caughtText | ConvertFrom-Json) } catch { $caughtDoc = $null }
    Assert-GP (($null -ne $caughtDoc) -and (-not [bool]$caughtDoc.ok) -and (([string]$caughtDoc.reason) -ceq 'encode-failed')) 'oversized envelope falls back to encode-failed literal' $caughtText.Substring(0, [Math]::Min(120, $caughtText.Length))
    Assert-GP (($null -ne $caughtDoc) -and ($null -ne $caughtDoc.grant_projection) -and (-not [bool]$caughtDoc.grant_projection.ok) -and (([string]$caughtDoc.grant_projection.reason) -ceq 'grant-source-not-evaluated') -and ([bool]$caughtDoc.grant_projection.authority -eq $false)) 'fallback literal carries refused grant_projection' ''
    Assert-GP (($null -ne $caughtDoc) -and ([bool]$caughtDoc.grants_authority -eq $false) -and ([bool]$caughtDoc.verified_pass -eq $false) -and ([bool]$caughtDoc.done_approved -eq $false)) 'fallback literal keeps authority pins false' ''
}
catch {
    Assert-GP $false 'suite completed without harness error' ($_.Exception.Message)
}
finally {
    try {
        if ((-not [string]::IsNullOrWhiteSpace($tempRoot)) -and (Test-Path -LiteralPath $tempRoot -PathType Container)) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    catch { }
}

Write-Host ("TOTAL: {0} / PASS: {1} / FAIL: {2}" -f ($script:passed + $script:failed), $script:passed, $script:failed)
if (($script:passed + $script:failed) -eq 0) { exit 1 }
if ($script:failed -ne 0) { exit 1 }
exit 0
