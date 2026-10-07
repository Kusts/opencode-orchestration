$ErrorActionPreference = 'Stop'
$v3 = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent (Split-Path -Parent $v3)
$evDir = Join-Path $repo 'evidence\capabilities-phase-2e'
$ledger = Join-Path $evDir 'real-world-pilots-2026-10-07.json'

$total = 0
$passed = 0
function Assert-That($condition, $name, $detail) {
    $script:total++
    if ($condition) { $script:passed++; Write-Host "[PASS] $name" }
    else { Write-Host "[FAIL] $name -- $detail" }
}

function Get-ResolverDoc([string]$PilotId) {
    $f = Join-Path $script:evDir ('resolver-' + $PilotId + '.json')
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return $null }
    try { return ([IO.File]::ReadAllText($f, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json) }
    catch { return $null }
}

function Has-Any($list, $names) {
    foreach ($n in @($names)) {
        foreach ($v in @($list)) {
            if ([string]$v -ceq [string]$n) { return $true }
        }
    }
    return $false
}

try {
    Assert-That (Test-Path -LiteralPath $ledger -PathType Leaf) 'Ledger file exists' "Missing $ledger"

    $doc = $null
    try { $doc = ([IO.File]::ReadAllText($ledger, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json) } catch { $doc = $null }
    Assert-That ($null -ne $doc) 'Ledger is valid JSON' 'Parse failed'

    if ($null -ne $doc) {
        Assert-That ([string]$doc.mode -ceq 'shadow') 'Ledger mode is shadow' ([string]$doc.mode)
        Assert-That ([string]$doc.resolver_version -ceq '2d-shadow-1') 'Ledger pins resolver_version 2d-shadow-1' ([string]$doc.resolver_version)
        Assert-That ((@($doc.pilots)).Count -eq 13) 'Ledger has 13 pilots' ("Got " + (@($doc.pilots)).Count)

        $ids = @($doc.pilots | ForEach-Object { [string]$_.id })
        foreach ($want in @('2E-P1-DOCS','2E-P2-RESEARCH','2E-P3-DEBUG','2E-P4-FRONTEND','2E-P5-BACKEND','2E-P6-TRIVIAL','2E-P7-DB','2E-P8-E2E','2E-P9-RUNTIME','2E-P10-PERF','2E-P11-DOCS2','2E-P12-REVIEW','2E-P13-CSS')) {
            Assert-That ($ids -ccontains $want) ("Ledger contains pilot $want") 'Missing'
        }

        $reqPilot = @('project','task_class','task_summary','resolver','planner','actual_execution','outcome','routing_assessment')
        $reqResolver = @('agents','skills','profiles','capabilities','mcps','risk','reason_codes','confidence')
        foreach ($p in @($doc.pilots)) {
            $names = @($p.PSObject.Properties | ForEach-Object { $_.Name })
            foreach ($f in $reqPilot) {
                Assert-That ($names -ccontains $f) ("Pilot $($p.id) has field $f") 'Missing'
            }
            $rnames = @($p.resolver.PSObject.Properties | ForEach-Object { $_.Name })
            foreach ($f in $reqResolver) {
                Assert-That ($rnames -ccontains $f) ("Pilot $($p.id) resolver has $f") 'Missing'
            }
            Assert-That ((@($p.actual_execution.mcps_activated)).Count -eq 0) ("Pilot $($p.id) activated zero MCPs") 'Activation found'
            Assert-That ([string]$p.outcome -ceq 'advisory-observed, no activation, safe') ("Pilot $($p.id) outcome marker") ([string]$p.outcome)
        }

        $correct = @(@($doc.pilots) | Where-Object { [string]$_.routing_assessment -ceq 'CORRECT' }).Count
        $ambig = @(@($doc.pilots) | Where-Object { [string]$_.routing_assessment -ceq 'AMBIGUOUS' }).Count
        Assert-That ($correct -eq 9) 'Ledger has 9 CORRECT assessments' ("Got $correct")
        Assert-That ($ambig -eq 4) 'Ledger has 4 AMBIGUOUS assessments' ("Got $ambig")
        $unsafe = @(@($doc.pilots) | Where-Object { [string]$_.routing_assessment -ceq 'UNSAFE' }).Count
        Assert-That ($unsafe -eq 0) 'Ledger has 0 UNSAFE assessments' ("Got $unsafe")

        Assert-That ([int]$doc.metrics.agent_agreement.agree_count -eq 9) 'Metric agent agreement 9/13' ([string]$doc.metrics.agent_agreement.agree_count)
        Assert-That ([int]$doc.metrics.profile_agreement.agree_count -eq 11) 'Metric profile agreement 11/13' ([string]$doc.metrics.profile_agreement.agree_count)
        Assert-That ([int]$doc.metrics.over_activation -eq 0) 'Metric over-activation 0' ([string]$doc.metrics.over_activation)
        Assert-That ([int]$doc.metrics.under_activation_unsafe -eq 0) 'Metric under-activation unsafe 0' ([string]$doc.metrics.under_activation_unsafe)
        Assert-That ([int]$doc.metrics.critical_routing_mistakes -eq 0) 'Metric critical routing mistakes 0' ([string]$doc.metrics.critical_routing_mistakes)
        Assert-That ([int]$doc.metrics.unsafe_capability_activation -eq 0) 'Metric unsafe capability activation 0' ([string]$doc.metrics.unsafe_capability_activation)

        Assert-That ([string]$doc.session_isolation.result -ceq 'PASS') 'Session isolation PASS' ([string]$doc.session_isolation.result)
        Assert-That ([bool]$doc.session_isolation.after_release_A_B_unaffected) 'Session B unaffected after release A' 'False'
        $notRun = @($doc.coverage.not_run | ForEach-Object { [string]$_.project })
        Assert-That ($notRun -ccontains 'Meu Ted') 'Coverage marks Meu Ted NOT RUN' ($notRun -join ',')
        $run = @($doc.coverage.run | ForEach-Object { [string]$_ })
        foreach ($rp in @('Synkroo','IPTV','opencode-orchestration')) {
            Assert-That ($run -ccontains $rp) ("Coverage marks $rp RUN") ($run -join ',')
        }

        $ledgerText = [IO.File]::ReadAllText($ledger, [Text.UTF8Encoding]::new($false))
        Assert-That (-not $ledgerText.Contains('sk-')) 'Ledger has no secret-like token' 'Found sk-'
        Assert-That (-not $ledgerText.Contains('Bearer ')) 'Ledger has no Bearer secret' 'Found'
    }

    # (a) Resolver outputs vs expectations: agents / profiles / mcps / risk.
    $expect = @{
        '2E-P1-DOCS'     = @{ agents = @('researcher'); profiles = @('core'); mcps = @('context7'); risk = 'LOW' }
        '2E-P2-RESEARCH' = @{ agents = @('researcher'); profiles = @('research'); mcps = @('jev'); risk = 'LOW' }
        '2E-P3-DEBUG'    = @{ agents = @('coder'); profiles = @(); mcps = @(); risk = 'LOW' }
        '2E-P4-FRONTEND' = @{ agents = @('frontend-engineer'); profiles = @(); mcps = @(); risk = 'LOW' }
        '2E-P5-BACKEND'  = @{ agents = @('backend-engineer'); profiles = @(); mcps = @(); risk = 'LOW' }
        '2E-P6-TRIVIAL'  = @{ agents = @('coder'); profiles = @(); mcps = @(); risk = 'LOW' }
        '2E-P7-DB'       = @{ agents = @('database-engineer'); profiles = @(); mcps = @(); risk = 'HIGH' }
        '2E-P8-E2E'      = @{ agents = @('tester'); profiles = @('testing'); mcps = @('playwright-mcp'); risk = 'MEDIUM' }
        '2E-P9-RUNTIME'  = @{ agents = @('debugger'); profiles = @('testing'); mcps = @('chrome-devtools-mcp'); risk = 'MEDIUM' }
        '2E-P10-PERF'    = @{ agents = @('coder'); profiles = @('testing'); mcps = @('chrome-devtools-mcp'); risk = 'MEDIUM' }
        '2E-P11-DOCS2'   = @{ agents = @('researcher'); profiles = @('core'); mcps = @('context7'); risk = 'LOW' }
        '2E-P12-REVIEW'  = @{ agents = @('coder'); profiles = @(); mcps = @(); risk = 'LOW' }
        '2E-P13-CSS'     = @{ agents = @('frontend-engineer'); profiles = @(); mcps = @(); risk = 'LOW' }
    }
    foreach ($rid in @($expect.Keys | Sort-Object)) {
        $r = Get-ResolverDoc -PilotId $rid
        Assert-That ($null -ne $r) ("Resolver file exists for $rid") 'Missing or invalid JSON'
        if ($null -ne $r) {
            $e = $expect[$rid]
            $ag = @($r.agents_selected | ForEach-Object { [string]$_ })
            $pf = @($r.profiles_selected | ForEach-Object { [string]$_ })
            $mc = @($r.mcps_selected | ForEach-Object { [string]$_ })
            Assert-That ((Compare-Object $ag @($e.agents)).Count -eq 0) ("$rid agents match") ($ag -join ',')
            Assert-That ((Compare-Object $pf @($e.profiles)).Count -eq 0) ("$rid profiles match") ($pf -join ',')
            Assert-That ((Compare-Object $mc @($e.mcps)).Count -eq 0) ("$rid mcps match") ($mc -join ',')
            Assert-That ([string]$r.risk -ceq [string]$e.risk) ("$rid risk $($e.risk)") ([string]$r.risk)
            Assert-That ([string]$r.mode -ceq 'shadow') ("$rid mode shadow") ([string]$r.mode)
        }
    }

    $p7 = Get-ResolverDoc -PilotId '2E-P7-DB'
    if ($null -ne $p7) {
        Assert-That ([string]$p7.confidence -ceq 'AMBIGUOUS') 'P7 confidence AMBIGUOUS (conflict suppresses stack MCP)' ([string]$p7.confidence)
    }

    # (b) No pilot activates supabase/neon/stripe MCP or database pilot profile without evidence.
    foreach ($rid in @($expect.Keys | Sort-Object)) {
        $r = Get-ResolverDoc -PilotId $rid
        if ($null -ne $r) {
            $badMcp = Has-Any -list @($r.mcps_selected) -names @('supabase-mcp','neon-mcp','stripe-mcp')
            Assert-That (-not $badMcp) ("$rid no supabase/neon/stripe MCP") (@($r.mcps_selected) -join ',')
            $badProf = Has-Any -list @($r.profiles_selected) -names @('database-supabase','database-neon')
            Assert-That (-not $badProf) ("$rid no database-supabase/neon profile") (@($r.profiles_selected) -join ',')
        }
    }

    # (c) CSS static read must not activate playwright.
    $p13 = Get-ResolverDoc -PilotId '2E-P13-CSS'
    if ($null -ne $p13) {
        Assert-That (-not (Has-Any -list @($p13.mcps_selected) -names @('playwright-mcp'))) 'P13 CSS-read has no playwright-mcp' (@($p13.mcps_selected) -join ',')
    }

    # (d) Frontend static analysis must not activate devtools.
    $p4 = Get-ResolverDoc -PilotId '2E-P4-FRONTEND'
    if ($null -ne $p4) {
        Assert-That (-not (Has-Any -list @($p4.mcps_selected) -names @('chrome-devtools-mcp'))) 'P4 frontend-analysis has no chrome-devtools-mcp' (@($p4.mcps_selected) -join ',')
    }

    # (e) E2E activates playwright with CLI fallback.
    $p8 = Get-ResolverDoc -PilotId '2E-P8-E2E'
    if ($null -ne $p8) {
        Assert-That (Has-Any -list @($p8.mcps_selected) -names @('playwright-mcp')) 'P8 E2E activates playwright-mcp' (@($p8.mcps_selected) -join ',')
        $fb = (@($p8.fallbacks) | ForEach-Object { [string]$_ }) -join ' '
        Assert-That ($fb.Contains('Playwright CLI')) 'P8 E2E records Playwright CLI fallback' $fb
    }

    # (f) Runtime debug activates devtools.
    $p9 = Get-ResolverDoc -PilotId '2E-P9-RUNTIME'
    if ($null -ne $p9) {
        Assert-That (Has-Any -list @($p9.mcps_selected) -names @('chrome-devtools-mcp')) 'P9 runtime-debug activates chrome-devtools-mcp' (@($p9.mcps_selected) -join ',')
    }
}
finally { }

Write-Host "TEST RESULTS: $passed / $total passed"
if ($passed -ne $total) { exit 1 }
exit 0
