$ErrorActionPreference = 'Stop'
$v3 = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent (Split-Path -Parent $v3)

$total = 0
$passed = 0
$skipped = 0
function Assert-That($condition, $name, $detail) {
    $script:total++
    if ($condition) { $script:passed++; Write-Host "[PASS] $name" }
    else { Write-Host "[FAIL] $name -- $detail" }
}

try {
    $fp = Join-Path $repo 'source\registry\capability-flags.json'
    Assert-That (Test-Path -LiteralPath $fp -PathType Leaf) 'Flags file exists' 'Missing capability-flags.json'
    $flags = $null
    $parseErr = ''
    try { $flags = ([IO.File]::ReadAllText($fp, [Text.Encoding]::UTF8) | ConvertFrom-Json) }
    catch { $parseErr = $_.Exception.Message }
    Assert-That (($null -ne $flags) -and ([string]::IsNullOrWhiteSpace($parseErr))) 'Flags JSON parses' $parseErr
    if ($null -ne $flags) {
        Assert-That (($flags.runtime_support.v1 -eq $true)) 'runtime_support.v1 == true' ([string]$flags.runtime_support.v1)
        Assert-That (($flags.runtime_support.v2 -eq $false)) 'runtime_support.v2 == false' ([string]$flags.runtime_support.v2)
        Assert-That (($flags.runtime_support.dual_profile -eq $false)) 'runtime_support.dual_profile == false' ([string]$flags.runtime_support.dual_profile)
        Assert-That (($flags.task_kernel.enabled -eq $false)) 'task_kernel.enabled == false' ([string]$flags.task_kernel.enabled)
        Assert-That (($flags.task_kernel.shadow -eq $true)) 'task_kernel.shadow == true' ([string]$flags.task_kernel.shadow)
        Assert-That (($flags.worktree_isolation.enabled -eq $false)) 'worktree_isolation.enabled == false' ([string]$flags.worktree_isolation.enabled)
        Assert-That (($flags.runtime_grant_enforcement.v1 -eq $false)) 'runtime_grant_enforcement.v1 == false' ([string]$flags.runtime_grant_enforcement.v1)
        Assert-That (($flags.runtime_grant_enforcement.v2 -eq $false)) 'runtime_grant_enforcement.v2 == false' ([string]$flags.runtime_grant_enforcement.v2)
        Assert-That (([int]$flags.version -eq 1)) 'version == 1 (inalterado)' ([string]$flags.version)
        Assert-That (($flags.capability_registry.enabled -eq $true)) 'capability_registry.enabled == true (inalterado)' ([string]$flags.capability_registry.enabled)
        Assert-That (($flags.capability_reconciler.enabled -eq $false)) 'capability_reconciler.enabled == false (inalterado)' ([string]$flags.capability_reconciler.enabled)
        Assert-That (($flags.capability_router.active -eq $false)) 'capability_router.active == false (kill switch intacto)' ([string]$flags.capability_router.active)
        Assert-That (($flags.capability_router.shadow -eq $false)) 'capability_router.shadow == false (kill switch intacto)' ([string]$flags.capability_router.shadow)
        Assert-That (($flags.skill_routing.enabled -eq $false)) 'skill_routing.enabled == false (inalterado)' ([string]$flags.skill_routing.enabled)
        Assert-That (($flags.mcp_routing.enabled -eq $false)) 'mcp_routing.enabled == false (inalterado)' ([string]$flags.mcp_routing.enabled)
        Assert-That (($flags.routing_telemetry.enabled -eq $false)) 'routing_telemetry.enabled == false (inalterado)' ([string]$flags.routing_telemetry.enabled)
        Assert-That (([int]$flags.routing_telemetry.retention_days -eq 30)) 'routing_telemetry.retention_days == 30 (inalterado)' ([string]$flags.routing_telemetry.retention_days)
        Assert-That (($flags.adaptive_ranking.enabled -eq $false)) 'adaptive_ranking.enabled == false (inalterado)' ([string]$flags.adaptive_ranking.enabled)
        Assert-That (($flags.jev_advisory.enabled -eq $false)) 'jev_advisory.enabled == false (nasce OFF, P29)' ([string]$flags.jev_advisory.enabled)
        Assert-That (($flags.jev_advisory.shadow -eq $true)) 'jev_advisory.shadow == true (would-consult, P29)' ([string]$flags.jev_advisory.shadow)
    }
}
catch {
    $script:total++
    Write-Host ("[FAIL] CapabilityFlags suite nunca lanca -- " + $_.Exception.Message)
}

Write-Host "TEST RESULTS: $passed / $total passed ($skipped skipped)"
if (($passed + $skipped) -ne $total) { exit 1 }
exit 0
