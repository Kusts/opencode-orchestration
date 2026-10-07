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

        # (a2) Ledger project mapping matches ground truth (per-pilot identity).
        $projExpect = @{
            '2E-P1-DOCS' = 'opencode-orchestration'; '2E-P2-RESEARCH' = 'Synkroo';
            '2E-P3-DEBUG' = 'opencode-orchestration'; '2E-P4-FRONTEND' = 'Synkroo';
            '2E-P5-BACKEND' = 'IPTV'; '2E-P6-TRIVIAL' = 'opencode-orchestration';
            '2E-P7-DB' = 'IPTV'; '2E-P8-E2E' = 'Synkroo'; '2E-P9-RUNTIME' = 'Synkroo';
            '2E-P10-PERF' = 'Synkroo'; '2E-P11-DOCS2' = 'IPTV';
            '2E-P12-REVIEW' = 'opencode-orchestration'; '2E-P13-CSS' = 'Synkroo'
        }
        foreach ($p in @($doc.pilots)) {
            $pilotId = [string]$p.id
            if ($projExpect.ContainsKey($pilotId)) {
                Assert-That ([string]$p.project -ceq [string]$projExpect[$pilotId]) ("Pilot $pilotId project $([string]$projExpect[$pilotId])") ([string]$p.project)
            }
        }
        $summaryExpect = @{
            '2E-P3-DEBUG' = 'Investigate failing capability-routing phase2d test, unexpected assertion mismatch in routing suite.';
            '2E-P5-BACKEND' = 'Analyze IPTV api endpoint request flow for outbox worker, trace handler logic.';
            '2E-P10-PERF' = 'Trace slow page load performance, analyze network waterfall and rendering bottleneck.';
            '2E-P11-DOCS2' = 'Write setup guide for local dev environment, docs-only markdown change.'
        }
        foreach ($p in @($doc.pilots)) {
            $pilotId = [string]$p.id
            if ($summaryExpect.ContainsKey($pilotId)) {
                Assert-That ([string]$p.task_summary -ceq [string]$summaryExpect[$pilotId]) ("Pilot $pilotId task_summary matches execution") ([string]$p.task_summary)
            }
        }

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

    # (g) LIVE session isolation: real overlay cycle, never a ledger re-read.
    # Invokes capability-profile-overlay.ps1 for two test sessions (unique
    # 2E-TEST- prefix, isolated OutDir), checks MCP separation, releases A,
    # checks A gone / B intact, then releases every created session in a
    # single finally with verified cleanup (no TEMP residue even on
    # failure). SKIP is allowed only when the overlay script file is
    # missing; any overlay execution, parsing, or separation failure is a
    # FAIL, never a SKIP.
    $overlayScript = Join-Path $v3 'capability-profile-overlay.ps1'
    if (-not (Test-Path -LiteralPath $overlayScript -PathType Leaf)) {
        Write-Host '[SKIP] live session isolation: overlay script missing'
    }
    else {
        $isoSuffix = ([Guid]::NewGuid().ToString('N')).Substring(0, 8)
        $isoSidA = ('2E-TEST-ISO-A-' + $isoSuffix)
        $isoSidB = ('2E-TEST-ISO-B-' + $isoSuffix)
        $isoOutDir = Join-Path ([IO.Path]::GetTempPath()) ('2e-test-iso-' + [Guid]::NewGuid().ToString('N'))
        $isoCreated = @()
        $isoA = $null
        $isoB = $null
        $isoPathA = ''
        $isoPathB = ''
        $isoBBefore = ''
        try {
            $rawA = & powershell -NoProfile -File $overlayScript -Profiles testing -SessionId $isoSidA -OutDir $isoOutDir
            if ($LASTEXITCODE -ne 0) { throw ('overlay A invocation failed, exit ' + $LASTEXITCODE) }
            $isoCreated += $isoSidA
            $isoA = ((($rawA | ForEach-Object { "$_" }) -join "`n") | ConvertFrom-Json)
            if ($null -eq $isoA) { throw 'overlay A output did not parse as JSON' }
            $rawB = & powershell -NoProfile -File $overlayScript -Profiles research -SessionId $isoSidB -OutDir $isoOutDir
            if ($LASTEXITCODE -ne 0) { throw ('overlay B invocation failed, exit ' + $LASTEXITCODE) }
            $isoCreated += $isoSidB
            $isoB = ((($rawB | ForEach-Object { "$_" }) -join "`n") | ConvertFrom-Json)
            if ($null -eq $isoB) { throw 'overlay B output did not parse as JSON' }
            $isoPathA = [string]$isoA.path
            $isoPathB = [string]$isoB.path
            if ([string]::IsNullOrWhiteSpace($isoPathA) -or [string]::IsNullOrWhiteSpace($isoPathB)) { throw 'overlay did not return paths' }
            $isoBBefore = [IO.File]::ReadAllText($isoPathB, [Text.UTF8Encoding]::new($false))
            $mcpsA = @($isoA.mcps | ForEach-Object { [string]$_ })
            $mcpsB = @($isoB.mcps | ForEach-Object { [string]$_ })
            Assert-That ((Has-Any -list $mcpsA -names @('playwright-mcp')) -and (Has-Any -list $mcpsA -names @('chrome-devtools-mcp'))) 'LIVE iso A has playwright-mcp + chrome-devtools-mcp' ($mcpsA -join ',')
            Assert-That ((Has-Any -list $mcpsB -names @('context7')) -and (Has-Any -list $mcpsB -names @('jev'))) 'LIVE iso B has context7 + jev' ($mcpsB -join ',')
            Assert-That (-not (Has-Any -list $mcpsB -names @('playwright-mcp', 'chrome-devtools-mcp'))) 'LIVE iso B has no browser MCPs' ($mcpsB -join ',')
            Assert-That ((Test-Path -LiteralPath $isoPathA) -and (Test-Path -LiteralPath $isoPathB)) 'LIVE iso overlay files exist' ($isoOutDir)
            & powershell -NoProfile -File $overlayScript -SessionId $isoSidA -OutDir $isoOutDir -Release | Out-Null
            Assert-That ($LASTEXITCODE -eq 0) 'LIVE iso release A exit 0' ("exit $LASTEXITCODE")
            Assert-That (-not (Test-Path -LiteralPath $isoPathA)) 'LIVE iso A file removed after release' ($isoPathA)
            Assert-That (Test-Path -LiteralPath $isoPathB) 'LIVE iso B file survives release A' ($isoPathB)
            $isoBAfter = [IO.File]::ReadAllText($isoPathB, [Text.UTF8Encoding]::new($false))
            Assert-That ($isoBAfter -ceq $isoBBefore) 'LIVE iso B content intact after release A' 'content changed'
        }
        catch {
            Assert-That $false 'LIVE iso cycle completes without product error' ($_.Exception.Message)
        }
        finally {
            foreach ($sid in @($isoCreated)) {
                try { & powershell -NoProfile -File $overlayScript -SessionId $sid -OutDir $isoOutDir -Release | Out-Null } catch { }
            }
            foreach ($sid in @($isoCreated)) {
                $p = Join-Path $isoOutDir ('overlay-' + $sid + '.json')
                Assert-That (-not (Test-Path -LiteralPath $p)) ("LIVE iso overlay released for $sid") ($p)
            }
            if ((-not [string]::IsNullOrWhiteSpace($isoOutDir)) -and (Test-Path -LiteralPath $isoOutDir)) {
                $left = @()
                try { $left = @(Get-ChildItem -LiteralPath $isoOutDir -Force) } catch { $left = @() }
                Assert-That ($left.Count -eq 0) 'LIVE iso OutDir has no residue' (($left | ForEach-Object { $_.Name }) -join ',')
                try { Remove-Item -LiteralPath $isoOutDir -Force -Recurse } catch { }
                Assert-That (-not (Test-Path -LiteralPath $isoOutDir)) 'LIVE iso OutDir removed' ($isoOutDir)
            }
            else {
                Assert-That $true 'LIVE iso OutDir removed' 'already gone'
            }
        }
    }
}
finally { }

Write-Host "TEST RESULTS: $passed / $total passed"
if ($passed -ne $total) { exit 1 }
exit 0
