$ErrorActionPreference = 'Stop'
$v3 = $PSScriptRoot
$cli = Join-Path $v3 'route-accept.ps1'
$repo = Split-Path -Parent (Split-Path -Parent $v3)
$base = Join-Path ([IO.Path]::GetTempPath()) ('v3-routeaccept-' + [guid]::NewGuid().ToString('N'))
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

function Invoke-AcceptCliRaw {
    param([string[]]$Argv)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $text = & powershell -NoProfile -File $cli @Argv
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    return @{ Code = $code; Text = (($text | ForEach-Object { "$_" }) -join "`n") }
}

function Get-JsonTail {
    param([string]$Text)
    $idx = $Text.IndexOf('{')
    if ($idx -lt 0) { return $null }
    $tail = $Text.Substring($idx)
    try { return ($tail | ConvertFrom-Json) } catch { return $null }
}

$activeFlags = '{"version":1,"capability_registry":{"enabled":true},"capability_reconciler":{"enabled":false},"capability_router":{"shadow":true,"active":true},"skill_routing":{"enabled":false},"mcp_routing":{"enabled":false},"routing_telemetry":{"enabled":false,"retention_days":30},"adaptive_ranking":{"enabled":false}}'
$flagsActive = Join-Path $base 'flags-active.json'
$inactiveFlags = '{"version":1,"capability_registry":{"enabled":true},"capability_reconciler":{"enabled":false},"capability_router":{"shadow":true,"active":false},"skill_routing":{"enabled":false},"mcp_routing":{"enabled":false},"routing_telemetry":{"enabled":false,"retention_days":30},"adaptive_ranking":{"enabled":false}}'
$flagsInactive = Join-Path $base 'flags-inactive.json'

try {
    Assert-That (Test-Path -LiteralPath $cli -PathType Leaf) 'CLI file exists' "Missing $cli"
    Write-Fixture -Path $flagsActive -Text $activeFlags
    Write-Fixture -Path $flagsInactive -Text $inactiveFlags

    $flagsFile = Join-Path $repo 'source\registry\capability-flags.json'
    $policyFile = Join-Path $repo 'source\registry\capability-policy.json'
    $liveConfig = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
    $snapBefore = @{}
    foreach ($p in @($flagsFile, $policyFile, $liveConfig)) { $snapBefore[$p] = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }

    # --- Kill switch: inactive flags => deterministic ---
    $rOff = Invoke-AcceptCliRaw -Argv @('-Objective', 'revisar API backend', '-TaskType', 'review', '-Domain', 'backend', '-Risk', 'medium', '-FlagsPath', $flagsInactive, '-NoTelemetry')
    $oOff = Get-JsonTail -Text $rOff.Text
    Assert-That ($rOff.Code -eq 0) 'inactive: exit 0' ("Exit $($rOff.Code) :: $($rOff.Text)")
    Assert-That ($null -ne $oOff) 'inactive: JSON parseable' $rOff.Text
    if ($null -ne $oOff) {
        Assert-That (([string]$oOff.mode -ceq 'deterministic') -and ([string]$oOff.fallback_reason -ceq 'router_inactive')) 'inactive: mode deterministic router_inactive' ($oOff | ConvertTo-Json -Compress)
        Assert-That (-not [bool]$oOff.accepted) 'inactive: not accepted' 'x'
        Assert-That ([string]$oOff.selected_agent -ceq 'reviewer') 'inactive: deterministic expected agent (work-type precedence)' ([string]$oOff.selected_agent)
    }

    # --- Active: registry fresh => envelope decision; invariants always hold ---
    function Assert-AcceptInvariants($o, $label) {
        Assert-That ([string]$o.envelope.stage -ceq 'stage1') "$label envelope stage1" ($o | ConvertTo-Json -Compress)
        if ([bool]$o.accepted) {
            $okA = (([string]$o.mode -ceq 'active') -and (-not [string]::IsNullOrWhiteSpace([string]$o.selected_agent)) -and ([string]$o.selected_agent -ceq [string]$o.router_candidate) -and ([bool]$o.envelope.allowed) -and (-not [bool]$o.fallback_used))
            Assert-That $okA "$label accepted implies active+consistent route" ($o | ConvertTo-Json -Compress)
        }
        else {
            $okB = (([bool]$o.fallback_used) -or ([bool]$o.direct))
            Assert-That $okB "$label not accepted implies fallback/direct" ($o | ConvertTo-Json -Compress)
        }
        $isMcp = ([string]$o.selected_agent).StartsWith('mcp:')
        Assert-That (-not $isMcp) "$label selected agent is not an MCP" ([string]$o.selected_agent)
    }

    $rBg = Invoke-AcceptCliRaw -Argv @('-Objective', 'revisar API backend', '-TaskType', 'review', '-Domain', 'backend', '-Risk', 'medium', '-FlagsPath', $flagsActive, '-NoTelemetry')
    $oBg = Get-JsonTail -Text $rBg.Text
    Assert-That ($rBg.Code -eq 0) 'active backend: exit 0' ("Exit $($rBg.Code)")
    Assert-That ($null -ne $oBg) 'active backend: JSON parseable' $rBg.Text
    if ($null -ne $oBg) {
        Assert-AcceptInvariants $oBg 'active backend'
        Assert-That (([bool]$oBg.registry_ok) -or ((-not [bool]$oBg.accepted) -and [bool]$oBg.fallback_used)) 'active backend: registry ok or safe fallback' ($oBg | ConvertTo-Json -Compress)
    }

    # --- Security: Router never controls ---
    $rSec = Invoke-AcceptCliRaw -Argv @('-Objective', 'auditar autenticacao e autorizacao do servico', '-TaskType', 'review', '-Domain', 'security', '-Risk', 'high', '-FlagsPath', $flagsActive, '-NoTelemetry')
    $oSec = Get-JsonTail -Text $rSec.Text
    Assert-That ($null -ne $oSec) 'security: JSON parseable' $rSec.Text
    if ($null -ne $oSec) {
        Assert-That (-not [bool]$oSec.accepted) 'security: not accepted' ($oSec | ConvertTo-Json -Compress)
        Assert-That ([bool]$oSec.fallback_used) 'security: fallback used' ($oSec | ConvertTo-Json -Compress)
    }

    # --- Authority change: Router never controls ---
    $rAuth = Invoke-AcceptCliRaw -Argv @('-Objective', 'alterar allowlist e permissao de agentes', '-TaskType', 'planning', '-Domain', 'planning', '-Risk', 'high', '-FlagsPath', $flagsActive, '-NoTelemetry')
    $oAuth = Get-JsonTail -Text $rAuth.Text
    Assert-That ($null -ne $oAuth) 'authority: JSON parseable' $rAuth.Text
    if ($null -ne $oAuth) {
        Assert-That (-not [bool]$oAuth.accepted) 'authority: not accepted' ($oAuth | ConvertTo-Json -Compress)
        Assert-That ([bool]$oAuth.fallback_used) 'authority: fallback used' ($oAuth | ConvertTo-Json -Compress)
    }

    # --- Trivial: direct, no delegation ---
    $rTriv = Invoke-AcceptCliRaw -Argv @('-Objective', 'corrigir typo', '-TaskType', 'trivial', '-Domain', 'code', '-Risk', 'low', '-FlagsPath', $flagsActive, '-NoTelemetry')
    $oTriv = Get-JsonTail -Text $rTriv.Text
    Assert-That ($null -ne $oTriv) 'trivial: JSON parseable' $rTriv.Text
    if ($null -ne $oTriv) {
        Assert-That (([bool]$oTriv.direct) -and ([string]$oTriv.selected_agent -ceq 'build') -and (-not [bool]$oTriv.accepted)) 'trivial: direct build (no delegation)' ($oTriv | ConvertTo-Json -Compress)
    }

    # --- Debugging: out of stage1 => deterministic fallback (router does not control) ---
    $rDbg = Invoke-AcceptCliRaw -Argv @('-Objective', 'investigar bug flaky intermitente', '-TaskType', 'debugging', '-Domain', 'debugging', '-Risk', 'medium', '-FlagsPath', $flagsActive, '-NoTelemetry')
    $oDbg = Get-JsonTail -Text $rDbg.Text
    Assert-That ($null -ne $oDbg) 'debugging: JSON parseable' $rDbg.Text
    if ($null -ne $oDbg) { Assert-That (-not [bool]$oDbg.accepted) 'debugging: not accepted (out of stage1)' ($oDbg | ConvertTo-Json -Compress) }

    # --- Telemetry path confinement => exit 2 ---
    $rTelOut = Invoke-AcceptCliRaw -Argv @('-Objective', 'revisar API', '-TaskType', 'review', '-Domain', 'backend', '-TelemetryPath', (Join-Path $base 'fora.jsonl'))
    Assert-That ($rTelOut.Code -eq 2) 'telemetry outside cache/v3/telemetry: exit 2' ("Exit $($rTelOut.Code)")

    # --- Usage errors => exit 2 ---
    $rNoTask = Invoke-AcceptCliRaw -Argv @('-NoTelemetry')
    Assert-That ($rNoTask.Code -eq 2) 'no task: exit 2 (usage)' ("Exit $($rNoTask.Code)")
    $rMissing = Invoke-AcceptCliRaw -Argv @('-TaskFile', (Join-Path $base 'nao-existe.json'))
    Assert-That ($rMissing.Code -eq 2) 'missing TaskFile: exit 2 (usage)' ("Exit $($rMissing.Code)")

    # --- Telemetry written (sanitized) when enabled ---
    $telDir = Join-Path $repo 'cache\v3\telemetry'
    New-Item -ItemType Directory -Path $telDir -Force | Out-Null
    $telFile = Join-Path $telDir ('tmp-routeaccept-' + [guid]::NewGuid().ToString('N') + '.jsonl')
    $rTel = Invoke-AcceptCliRaw -Argv @('-Objective', 'revisar API backend', '-TaskType', 'review', '-Domain', 'backend', '-Risk', 'medium', '-TaskId', 'review-backend-1', '-FlagsPath', $flagsActive, '-TelemetryPath', $telFile)
    Assert-That ($rTel.Code -eq 0) 'telemetry run: exit 0' ("Exit $($rTel.Code)")
    if (Test-Path -LiteralPath $telFile -PathType Leaf) {
        $txt = [IO.File]::ReadAllText($telFile, [Text.UTF8Encoding]::new($false))
        Assert-That ($txt -match '"event_type"\s*:\s*"acceptance"') 'telemetry: acceptance line written' $txt
        Assert-That ($txt -match '"task_id_hash"\s*:\s*"sha256:[0-9a-f]{16}"') 'telemetry: task id hashed' $txt
        Assert-That ($txt -notmatch 'Bearer') 'telemetry: no raw secret' $txt
        Remove-Item -LiteralPath $telFile -Force
    }
    else {
        Assert-That $false 'telemetry: acceptance line written' 'file missing'
    }

    # --- Real state untouched ---
    $drift = $false
    foreach ($p in @($flagsFile, $policyFile, $liveConfig)) {
        $h = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
        if ($h -cne $snapBefore[$p]) { $drift = $true }
    }
    Assert-That (-not $drift) 'no drift of flags/policy/opencode.json' 'drift detected'
    $flagsReal = ([IO.File]::ReadAllText($flagsFile, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
    Assert-That (([bool]$flagsReal.capability_router.shadow -eq $true) -and ([bool]$flagsReal.skill_routing.enabled -eq $false) -and ([bool]$flagsReal.mcp_routing.enabled -eq $false) -and ([bool]$flagsReal.adaptive_ranking.enabled -eq $false) -and ($flagsReal.capability_router.active -is [bool])) 'real flags: shadow=true skill/mcp/adaptive=false (active governed)' 'flag changed'
}
finally {
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
}

Write-Output ''
Write-Output ('TEST RESULTS: ' + $passed + ' / ' + $total + ' passed')
if ($passed -eq $total) { exit 0 }
exit 1
