<#!
.SYNOPSIS
    Testes standalone do CapabilityLifecycle.ps1 (Phase 5).
.DESCRIPTION
    Maquina de estados com baseline sintetico em TEMP; nenhum processo real
    e reiniciado. A "nova instancia" e simulada gravando um novo baseline.
    Roda com `powershell -NoProfile -File <este-arquivo>`; termina com exit 0/1.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$libPath = Join-Path $PSScriptRoot 'CapabilityLifecycle.ps1'
. $libPath

$passed = 0
$failed = 0

function Assert-LifecycleTrue {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) {
        Write-Host ("PASS {0}" -f $Name)
        $script:passed++
    } else {
        if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ("FAIL {0}" -f $Name) }
        else { Write-Host ("FAIL {0} -- {1}" -f $Name, $Detail) }
        $script:failed++
    }
}

function Write-LifecycleFixture {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $lf = ($Text -replace "`r`n", "`n" -replace "`r", "`n")
    [IO.File]::WriteAllText($Path, $lf, [Text.UTF8Encoding]::new($false))
}

$base = Join-Path ([IO.Path]::GetTempPath()) ('v3-capability-lifecycle-' + [guid]::NewGuid().ToString('N'))

try {
    $tgt = Join-Path $base 'target'
    $store = Join-Path $base 'reload-state.json'
    Write-LifecycleFixture -Path (Join-Path $tgt 'a.md') -Text "# A`n"
    Write-LifecycleFixture -Path (Join-Path $tgt 'b.md') -Text "# B`n"

    Assert-LifecycleTrue ((Get-RuntimeReloadStatus -TargetRoot $tgt -StorePath $store) -ceq 'UNKNOWN') 'no baseline reports UNKNOWN'

    $fp1 = Get-TargetFingerprint -TargetRoot $tgt
    $fp2 = Get-TargetFingerprint -TargetRoot $tgt
    Assert-LifecycleTrue (($fp1 -ceq $fp2) -and ($fp1 -match '^sha256:[0-9A-F]{64}$')) 'fingerprint is deterministic and well-formed' ("Got $fp1")

    $clone = Join-Path $base 'clone'
    Write-LifecycleFixture -Path (Join-Path $clone 'a.md') -Text "# A`n"
    Write-LifecycleFixture -Path (Join-Path $clone 'b.md') -Text "# B`n"
    Assert-LifecycleTrue ((Get-TargetFingerprint -TargetRoot $clone) -ceq $fp1) 'fingerprint depends on names plus content, not on location' 'Clone differs'

    $record = New-RuntimeBaseline -TargetRoot $tgt -StorePath $store
    Assert-LifecycleTrue ((Test-Path -LiteralPath $store -PathType Leaf)) 'baseline writes the store file' 'Store missing'
    Assert-LifecycleTrue (([string]$record.fingerprint -ceq $fp1) -and ([string]$record.status -ceq 'RUNTIME_ACTIVE')) 'baseline records fingerprint as RUNTIME_ACTIVE' 'Record wrong'
    Assert-LifecycleTrue ((Get-RuntimeReloadStatus -TargetRoot $tgt -StorePath $store) -ceq 'RUNTIME_ACTIVE') 'baseline equal to disk reports RUNTIME_ACTIVE' 'Status wrong'

    Write-LifecycleFixture -Path (Join-Path $tgt 'b.md') -Text "# B changed`n"
    Assert-LifecycleTrue ((Get-RuntimeReloadStatus -TargetRoot $tgt -StorePath $store) -ceq 'RUNTIME_RELOAD_REQUIRED') 'changed disk reports RUNTIME_RELOAD_REQUIRED' 'Status wrong'

    Write-LifecycleFixture -Path (Join-Path $tgt 'c.md') -Text "# C`n"
    Assert-LifecycleTrue ((Get-RuntimeReloadStatus -TargetRoot $tgt -StorePath $store) -ceq 'RUNTIME_RELOAD_REQUIRED') 'added file keeps RUNTIME_RELOAD_REQUIRED' 'Status wrong'

    Set-RuntimeReloadStatus -Status 'DISK_APPLIED_RELOAD_REQUIRED' -TargetRoot $tgt -StorePath $store | Out-Null
    $afterApply = Get-Content -LiteralPath $store -Raw | ConvertFrom-Json
    Assert-LifecycleTrue ([string]$afterApply.status -ceq 'DISK_APPLIED_RELOAD_REQUIRED') 'apply registers DISK_APPLIED_RELOAD_REQUIRED' ("Got $($afterApply.status)")
    Assert-LifecycleTrue ((Get-RuntimeReloadStatus -TargetRoot $tgt -StorePath $store) -ceq 'RUNTIME_RELOAD_REQUIRED') 'disk-applied status reads as RUNTIME_RELOAD_REQUIRED' 'Status wrong'

    New-RuntimeBaseline -TargetRoot $tgt -StorePath $store | Out-Null
    Assert-LifecycleTrue ((Get-RuntimeReloadStatus -TargetRoot $tgt -StorePath $store) -ceq 'RUNTIME_ACTIVE') 'fresh instance baseline returns to RUNTIME_ACTIVE' 'Status wrong'

    [IO.File]::WriteAllText($store, 'not-json{{{', [Text.UTF8Encoding]::new($false))
    Assert-LifecycleTrue ((Get-RuntimeReloadStatus -TargetRoot $tgt -StorePath $store) -ceq 'UNKNOWN') 'corrupt baseline reports UNKNOWN' 'Status wrong'

    $defaultStore = Resolve-ReloadStorePath
    Assert-LifecycleTrue ($defaultStore -like '*reload-state.json') 'default store resolves to reload-state.json' ("Got $defaultStore")
} catch {
    Write-Host ("FAIL unexpected error: {0}" -f $_)
    exit 1
} finally {
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ("CapabilityLifecycle: {0} / {1} tests passed" -f $passed, ($passed + $failed))
if ($failed -gt 0) { exit 1 }
exit 0
