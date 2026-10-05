<#
.SYNOPSIS
    Tests for lib/OrchestrationE2eManifest.ps1 (Phase 42 slice 1).
.DESCRIPTION
    Covers the manifest + harness contract, not the release gate:

      A1 manifest integrity: 41 scenarios (the plan's 40 ordinals plus the
         ordinal 41 harness addendum), contiguous ordinals, unique ids, closed
         classification set, every runnable-synthetic names a known check, no
         blocked scenario carries one.
      A2 honest execution: the runnable subset really runs and passes; blocked
         scenarios stay blocked and are never executed; blocked is never pass.
         The operator-runtime block (16..22, 32, 33) is asserted PER ID against
         the registry, so a silent reclassification cannot pass on the counts.
         The real V2 policy deny (39) stays blocked while the offline gating
         invariant (41) is its own separate row.
      A3 fail-closed: a missing library turns every runnable scenario into
         failed-synthetic and the harness status into non-ok; a damaged
         manifest yields invalid-manifest with zero scenario claims.
      A4 rollout checklist: 19 contiguous steps derived from real state; the V2
         native step is blocked-evidence because its proof registry is absent;
         no activation flag is claimed active.
      A5 sanitized, bounded, deterministic output; hostile manifest values are
         redacted and capped; a fixed timestamp value makes repeated runs
         byte-identical.
      A6 no side effects: capability flags untouched, no repository file added,
         no work directory left behind, zero network in the library source.
      A7 negatives for the review findings: an unreadable flag registry or an
         unparseable evidence record never promotes a rollout step; a flag the
         policy does not declare is blocked-activation while an UNRESOLVABLE
         flag is blocked-evidence; a declared flag leaf that is not exactly a
         boolean (string, number, null, object) resolves to no state at all and
         can never promote a step, while a real boolean false/true keeps its
         honest status; the public APIs expose no -Clock and no
         scriptblock seam and never echo an unparseable timestamp; the MCP
         timeout seam is classified timeout and stays distinct from network;
         scenario 39 cannot be reclassified as offline-decidable.

    Hermetic: fixtures under the user temp, cleanup in finally. PS 5.1
    compatible. ASCII-only. Exit 0 on all pass, exit 1 on any fail.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
. (Join-Path $PSScriptRoot 'OrchestrationE2eManifest.ps1')

$passed = 0
$total = 0
function Assert-That {
    param([bool]$Condition, [string]$Name)
    $script:total++
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}

# A VALUE seam, never a callback: one fixed instant drives every deterministic
# assertion in this file.
$stamp = '2026-01-02T03:04:05Z'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('e2e-manifest-tests-' + [Guid]::NewGuid().ToString('N').Substring(0, 12))
[void][IO.Directory]::CreateDirectory($tempRoot)
$realManifestPath = Join-Path $RepoRoot 'source/registry/e2e-scenarios.json'
$flagsPath = Join-Path $RepoRoot 'source/registry/capability-flags.json'
$utf8 = New-Object Text.UTF8Encoding($false)

function New-FixtureManifest {
    param([string]$Name, [scriptblock]$Mutate)
    $doc = ConvertFrom-Json ([IO.File]::ReadAllText($realManifestPath))
    if ($null -ne $Mutate) { & $Mutate $doc }
    $path = Join-Path $tempRoot $Name
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $doc -Depth 24), (New-Object Text.UTF8Encoding($false)))
    return $path
}

# A minimal rollout fixture repo: the real manifest, a caller-supplied flag
# registry, EMPTY placeholder libs (the checklist only tests their existence)
# and synthetic evidence/proof records. No real repository state is touched and
# no library is executed, so a fixture can damage one input and prove the
# derived status cannot be promoted.
function New-RolloutFixture {
    param([string]$Name, [string]$RegistryJson, [hashtable]$Damaged = @{})
    $root = Join-Path $tempRoot $Name
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'source/registry'))
    [IO.File]::Copy($realManifestPath, (Join-Path $root 'source/registry/e2e-scenarios.json'), $true)
    if ($null -ne $RegistryJson) {
        [IO.File]::WriteAllText((Join-Path $root 'source/registry/capability-flags.json'), $RegistryJson, $utf8)
    }
    $doc = ConvertFrom-Json ([IO.File]::ReadAllText($realManifestPath))
    foreach ($st in $doc.rollout_steps) {
        $lib = Join-Path $root $st.lib
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $lib))
        [IO.File]::WriteAllText($lib, '', $utf8)
        foreach ($ref in @($st.evidence, $st.proof)) {
            $full = Join-Path $root $ref
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $full))
            $body = '{"status":"synthetic-fixture"}'
            if ($Damaged.ContainsKey($ref)) { $body = $Damaged[$ref] }
            [IO.File]::WriteAllText($full, $body, $utf8)
        }
    }
    return $root
}

function Get-FixtureRow {
    param($Checklist, [int]$Step)
    return @($Checklist.steps | Where-Object { [int]$_.step -eq $Step })[0]
}

# Registry CONTROLADO para os invariantes: deriva da FORMA do registry real (nenhuma
# folha inventada) e forca cada folha de ativacao para $false, com a perna de shadow
# no valor pedido. Assim "flag OFF nao entrega nada" e provado num estado CONHECIDO,
# e nao por leitura do registry vivo (ativado em 2026-10-04, batch cca566f).
function New-ControlledFlagsJson([bool]$ShadowOn) {
    $doc = ConvertFrom-Json ([IO.File]::ReadAllText($flagsPath))
    foreach ($node in @($doc.PSObject.Properties)) {
        foreach ($leaf in @($node.Value.PSObject.Properties)) {
            if ($leaf.Name -eq 'shadow') { $node.Value.($leaf.Name) = [bool]$ShadowOn }
            elseif (@('enabled', 'active', 'v1', 'v2', 'dual_profile') -contains $leaf.Name) { $node.Value.($leaf.Name) = $false }
        }
    }
    return (ConvertTo-Json -InputObject $doc -Depth 24)
}

# The seam libraries are dot-sourced INSIDE these helpers, never at test scope:
# loading them globally would make every function visible to the harness, and the
# missing-library case in A3 depends on those functions being genuinely absent.
function Get-McpSeamObservation {
    param([string]$LibPath, [string]$WorkRoot)
    . $LibPath
    $turn = [Guid]::NewGuid().ToString('N')
    $marker = Join-Path $WorkRoot 'probe-ran.marker'
    $timeoutProbe = [scriptblock]::Create('param($p) if($p){[IO.File]::WriteAllText($p,''ran'')}; throw ''mcp_sim_timeout''')
    $networkProbe = [scriptblock]::Create('param($p) if($p){[IO.File]::WriteAllText($p,''ran'')}; throw ''mcp_sim_network''')
    $timeoutCall = Invoke-McpSafetyCall -Server 'jev' -Capability 'jev.advise' -TurnId ('e2e-tests-timeout-' + $turn) `
        -Class 'advisory' -Criticality 'optional' -Probe $timeoutProbe -ProbeArgs @($marker) -TelemetryRoot $WorkRoot -RepoRoot $RepoRoot -BudgetSecondsOverride 5
    $probeRan = (Test-Path -LiteralPath $marker -PathType Leaf)
    $networkCall = Invoke-McpSafetyCall -Server 'jev' -Capability 'jev.advise' -TurnId ('e2e-tests-network-' + $turn) `
        -Class 'advisory' -Criticality 'optional' -Probe $networkProbe -ProbeArgs @($marker) -TelemetryRoot $WorkRoot -RepoRoot $RepoRoot -BudgetSecondsOverride 5
    return [pscustomobject]@{
        timeout_token = [string](Classify-McpSafetyProbeError -Message 'mcp_sim_timeout')
        network_token = [string](Classify-McpSafetyProbeError -Message 'mcp_sim_network')
        timeout_call  = $timeoutCall
        network_call  = $networkCall
        probe_ran     = $probeRan
    }
}

function Get-V2GateCandidates {
    param([string]$LibPath)
    . $LibPath
    return @(Get-OrchestrationV2NativeFeatures)
}

try {
    # ---------- A1 manifest integrity ----------
    $manifest = Get-OrchestrationE2eManifest -RepoRoot $RepoRoot
    Assert-That ($manifest.status -eq 'ok') ('real manifest is valid: ' + $manifest.reason)
    Assert-That (@($manifest.scenarios).Count -eq 41) 'manifest declares exactly 41 scenarios'
    Assert-That (@($manifest.rollout_steps).Count -eq 19) 'manifest declares exactly 19 rollout steps'

    $ordinals = @($manifest.scenarios | ForEach-Object { [int]$_.ordinal })
    Assert-That ((($ordinals -join ',') -eq ((1..41) -join ','))) 'scenario ordinals are contiguous 1..41'
    $ids = @($manifest.scenarios | ForEach-Object { [string]$_.scenario_id })
    Assert-That ((@($ids | Sort-Object -Unique)).Count -eq 41) 'scenario ids are unique'
    $classes = @($manifest.scenarios | ForEach-Object { [string]$_.classification } | Sort-Object -Unique)
    $allowed = @('requires-flag-activation', 'requires-operator-runtime', 'requires-real-transport', 'runnable-synthetic')
    Assert-That ((@($classes | Where-Object { $_ -notin $allowed })).Count -eq 0) 'every classification is in the closed set'
    $runnable = @($manifest.scenarios | Where-Object { $_.classification -eq 'runnable-synthetic' })
    Assert-That ($runnable.Count -eq 18) 'exactly 18 scenarios are runnable-synthetic'
    Assert-That ((@($runnable | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.check) })).Count -eq 0) 'every runnable scenario names a check'
    Assert-That ((@($runnable | Where-Object { -not $script:E2eLibMap.ContainsKey([string]$_.check) })).Count -eq 0) 'every runnable check is implemented by the harness'
    $blocked = @($manifest.scenarios | Where-Object { $_.classification -ne 'runnable-synthetic' })
    Assert-That ($blocked.Count -eq 23) 'exactly 23 scenarios are operator, flag or transport blocked'
    Assert-That ((@($blocked | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.check) })).Count -eq 0) 'no blocked scenario carries an executable check'
    Assert-That ((@($manifest.scenarios | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.mapped_component) -or [string]::IsNullOrWhiteSpace([string]$_.evidence_ref) })).Count -eq 0) 'every scenario maps a component and an evidence ref'
    Assert-That ((@($manifest.scenarios | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.required_activation) })).Count -eq 0) 'every scenario declares its required activation'
    $stepNumbers = @($manifest.rollout_steps | ForEach-Object { [int]$_.step })
    Assert-That ((($stepNumbers -join ',') -eq ((1..19) -join ','))) 'rollout steps are contiguous 1..19'
    Assert-That ((@($manifest.rollout_steps | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.proof) })).Count -eq 0) 'every rollout step names a proof artifact'

    # ---------- A2 honest execution ----------
    $result = Invoke-OrchestrationE2eManifest -RepoRoot $RepoRoot -TimestampUtc $stamp
    Assert-That ($result.status -eq 'ok') ('harness reports ok: ' + $result.status + '/' + $result.reason)
    Assert-That ($result.release_gate -eq 'open-pending-operator') 'harness never closes the release gate'
    Assert-That ($result.counts.total -eq 41) 'harness reports exactly 41 scenarios'
    Assert-That ($result.counts.pass_synthetic -eq 18) 'all 18 runnable-synthetic scenarios really pass'
    Assert-That ($result.counts.failed_synthetic -eq 0) 'no runnable-synthetic scenario failed'
    Assert-That ($result.counts.blocked_requires_operator -eq 20) '20 scenarios blocked on the operator runtime'
    Assert-That ($result.counts.blocked_requires_flag -eq 0) 'no scenario is blocked on flag activation (the last one, RR-E2E-32, moved to the operator runtime)'
    Assert-That ($result.counts.blocked_requires_transport -eq 3) '3 scenarios blocked on real transport'
    Assert-That ((($result.counts.pass_synthetic + $result.counts.failed_synthetic + $result.counts.blocked_requires_operator + $result.counts.blocked_requires_flag + $result.counts.blocked_requires_transport) -eq 41)) 'status counts partition all 41 scenarios'

    $rows = @{}
    foreach ($row in $result.scenarios) { $rows[[string]$row.scenario_id] = $row }
    Assert-That (@($result.scenarios).Count -eq 41) 'harness returns one row per scenario'
    $vocabulary = @('pass-synthetic', 'failed-synthetic', 'blocked-requires-operator', 'blocked-requires-flag', 'blocked-requires-transport')
    Assert-That ((@($result.scenarios | Where-Object { [string]$_.status -notin $vocabulary })).Count -eq 0) 'every status is in the closed vocabulary'
    Assert-That ((@($result.scenarios | Where-Object { [string]$_.status -like 'blocked*' -and $_.classification -eq 'runnable-synthetic' })).Count -eq 0) 'no runnable-synthetic scenario is reported blocked'
    Assert-That ((@($result.scenarios | Where-Object { [string]$_.status -eq 'pass-synthetic' -and $_.classification -ne 'runnable-synthetic' })).Count -eq 0) 'no blocked-classification scenario is reported as a pass'
    Assert-That ((@($result.scenarios | Where-Object { [string]$_.status -like 'blocked*' -and [string]::IsNullOrWhiteSpace([string]$_.detail) })).Count -eq 0) 'every blocked scenario states why it is blocked'
    Assert-That ((@($result.scenarios | Where-Object { [string]$_.status -like 'blocked*' -and [string]$_.detail -ne [string]$_.required_activation })).Count -eq 0) 'blocked reason comes from the declared required activation'
    Assert-That ((@($result.scenarios | Where-Object { [string]$_.status -eq 'pass-synthetic' -and [string]::IsNullOrWhiteSpace([string]$_.detail) })).Count -eq 0) 'every passing scenario reports what it proved'

    # The scenarios named in the objective, asserted by identity.
    Assert-That ($rows['RR-E2E-36'].status -eq 'pass-synthetic' -and $rows['RR-E2E-36'].detail -match 'cannot widen') 'scenario 36 proves a worker cannot widen grants'
    Assert-That ($rows['RR-E2E-40'].status -eq 'pass-synthetic' -and $rows['RR-E2E-40'].detail -match 'nothing killed') 'scenario 40 proves an unknown PID is never killed'
    Assert-That ($rows['RR-E2E-11'].status -eq 'pass-synthetic' -and $rows['RR-E2E-12'].status -eq 'pass-synthetic') 'scenarios 11 and 12 run real synthetic MCP checks'
    Assert-That ($rows['RR-E2E-13'].status -eq 'blocked-requires-transport' -and $rows['RR-E2E-15'].status -eq 'blocked-requires-transport') 'AI Memory remote scenarios stay blocked on real transport'
    Assert-That ($rows['RR-E2E-32'].status -eq 'blocked-requires-operator' -and $rows['RR-E2E-32'].detail -match 'advisory-only contract' -and $rows['RR-E2E-32'].detail -match 'not a flag flip') 'the Jev route scenario is blocked on the advisory-only contract, not on a flag activation'
    Assert-That ($rows['RR-E2E-33'].status -eq 'blocked-requires-operator' -and $rows['RR-E2E-33'].detail -match 'never consults Jev' -and $rows['RR-E2E-33'].detail -match 'operator-owned') 'the obvious-task Jev scenario is blocked on the real runtime turn, with the kernel-side proof stated'
    # Per-ID honesty for the operator-runtime block. The aggregate counts say HOW
    # MANY rows are blocked; these asserts say WHICH ones, so a silent
    # reclassification (or a row quietly turned into a pass) cannot keep passing
    # on the counts alone. Each id is asserted against the registry itself, so a
    # registry and a report that drift apart fail here.
    $operatorBlockedIds = @('RR-E2E-16', 'RR-E2E-17', 'RR-E2E-18', 'RR-E2E-19', 'RR-E2E-20', 'RR-E2E-21', 'RR-E2E-22', 'RR-E2E-32', 'RR-E2E-33')
    $registryRows = @{}
    foreach ($s in $manifest.scenarios) { $registryRows[[string]$s.scenario_id] = $s }
    foreach ($id in $operatorBlockedIds) {
        Assert-That ($registryRows.ContainsKey($id)) ('scenario ' + $id + ' is declared in the registry')
        Assert-That ($registryRows[$id].classification -eq 'requires-operator-runtime') ('scenario ' + $id + ' is classified requires-operator-runtime in the registry')
        Assert-That ($rows.ContainsKey($id)) ('scenario ' + $id + ' has its own report row')
        Assert-That ([string]$rows[$id].status -eq 'blocked-requires-operator') ('scenario ' + $id + ' is reported blocked on the operator runtime')
        Assert-That ([string]$rows[$id].detail -ceq [string]$registryRows[$id].required_activation) ('scenario ' + $id + ' reports its declared required activation verbatim as the blocked detail')
        Assert-That ([string]$rows[$id].classification -eq 'requires-operator-runtime') ('scenario ' + $id + ' carries the operator-runtime classification into the report')
    }
    Assert-That ((@($result.scenarios | Where-Object { $operatorBlockedIds -contains [string]$_.scenario_id })).Count -eq $operatorBlockedIds.Count) 'every operator-blocked id appears exactly once in the report'
    Assert-That ((@($result.scenarios | Where-Object { $operatorBlockedIds -contains [string]$_.scenario_id -and [string]$_.status -ne 'blocked-requires-operator' })).Count -eq 0) 'no operator-blocked id is ever reported as a pass of any kind or as an executed check'
    # Scenario 35 reads the real policy, where semantic discovery is activated on
    # windows: the row must prove the fallback under an UNHEALTHY probe and must
    # not depend on the capability being platform-unsupported.
    Assert-That ($rows['RR-E2E-35'].status -eq 'pass-synthetic' -and $rows['RR-E2E-35'].detail -match 'not blocked' -and $rows['RR-E2E-35'].detail -match 'direct-search') 'scenario 35 proves an unhealthy optional semantic discovery is not blocked and falls back to direct-search'
    Assert-That (@($result.holds).Count -ge 4) 'the harness states its release-gate holds'

    # ---------- A3 fail-closed ----------
    $emptyRoot = Join-Path $tempRoot 'empty-root'
    [void][IO.Directory]::CreateDirectory((Join-Path $emptyRoot 'source/registry'))
    Copy-Item -LiteralPath $realManifestPath -Destination (Join-Path $emptyRoot 'source/registry/e2e-scenarios.json') -Force
    $noLibs = Invoke-OrchestrationE2eManifest -RepoRoot $emptyRoot -TimestampUtc $stamp
    Assert-That ($noLibs.status -eq 'failed') 'missing libraries make the harness status failed'
    Assert-That ($noLibs.counts.pass_synthetic -eq 0) 'no scenario is a pass when its library is absent'
    Assert-That ($noLibs.counts.failed_synthetic -eq 18) 'every runnable scenario becomes failed-synthetic when its library is absent'
    Assert-That ((@($noLibs.scenarios | Where-Object { [string]$_.status -eq 'pass-synthetic' })).Count -eq 0) 'a missing library never yields a soft pass'

    $absent = Invoke-OrchestrationE2eManifest -ManifestPath (Join-Path $tempRoot 'no-such-manifest.json') -RepoRoot $RepoRoot -TimestampUtc $stamp
    Assert-That ($absent.status -eq 'invalid-manifest') 'an absent manifest is fail-closed'
    Assert-That (@($absent.scenarios).Count -eq 0) 'an absent manifest claims no scenario'
    Assert-That ($absent.release_gate -eq 'open-pending-operator') 'an invalid manifest still never closes the gate'

    $shortCount = New-FixtureManifest 'short.json' { param($d) $d.scenarios = @($d.scenarios | Select-Object -First 40) }
    $short = Get-OrchestrationE2eManifest -ManifestPath $shortCount -RepoRoot $RepoRoot
    Assert-That ($short.status -eq 'invalid' -and $short.reason -eq 'scenario-count:40') '40 scenarios is rejected'

    $ordinalGap = New-FixtureManifest 'ordinal.json' { param($d) $d.scenarios[3].ordinal = 99 }
    $gap = Get-OrchestrationE2eManifest -ManifestPath $ordinalGap -RepoRoot $RepoRoot
    Assert-That ($gap.status -eq 'invalid' -and $gap.reason -like 'scenario-ordinal-gap*') 'an ordinal gap is rejected'

    $duplicate = New-FixtureManifest 'dup.json' { param($d) $d.scenarios[5].scenario_id = 'RR-E2E-01' }
    $dup = Get-OrchestrationE2eManifest -ManifestPath $duplicate -RepoRoot $RepoRoot
    Assert-That ($dup.status -eq 'invalid' -and $dup.reason -like 'duplicate-scenario-id*') 'a duplicate scenario id is rejected'

    $unknownClass = New-FixtureManifest 'class.json' { param($d) $d.scenarios[0].classification = 'runnable-later' }
    $cls = Get-OrchestrationE2eManifest -ManifestPath $unknownClass -RepoRoot $RepoRoot
    Assert-That ($cls.status -eq 'invalid' -and $cls.reason -like 'unknown-classification*') 'an unknown classification is rejected'

    $noCheck = New-FixtureManifest 'nocheck.json' { param($d) $d.scenarios[10].check = '' }
    $nc = Get-OrchestrationE2eManifest -ManifestPath $noCheck -RepoRoot $RepoRoot
    Assert-That ($nc.status -eq 'invalid' -and $nc.reason -like 'runnable-without-check*') 'a runnable scenario without a check is rejected'

    $blockedCheck = New-FixtureManifest 'blockedcheck.json' { param($d) $d.scenarios[0] | Add-Member -NotePropertyName 'check' -NotePropertyValue 'mcp-healthy' -Force }
    $bc = Get-OrchestrationE2eManifest -ManifestPath $blockedCheck -RepoRoot $RepoRoot
    Assert-That ($bc.status -eq 'invalid' -and $bc.reason -like 'blocked-with-check*') 'a blocked scenario carrying a check is rejected'

    $shortRollout = New-FixtureManifest 'rollout.json' { param($d) $d.rollout_steps = @($d.rollout_steps | Select-Object -First 18) }
    $sr = Get-OrchestrationE2eManifest -ManifestPath $shortRollout -RepoRoot $RepoRoot
    Assert-That ($sr.status -eq 'invalid' -and $sr.reason -eq 'rollout-count:18') '18 rollout steps is rejected'

    $rolloutBad = Invoke-OrchestrationE2eManifest -ManifestPath $shortRollout -RepoRoot $RepoRoot -TimestampUtc $stamp
    Assert-That ($rolloutBad.status -eq 'invalid-manifest' -and @($rolloutBad.scenarios).Count -eq 0) 'a damaged rollout manifest claims no scenario'
    $rolloutBadList = Get-OrchestrationRolloutChecklist -ManifestPath $shortRollout -RepoRoot $RepoRoot -TimestampUtc $stamp
    Assert-That ($rolloutBadList.status -eq 'invalid-manifest' -and @($rolloutBadList.steps).Count -eq 0) 'a damaged rollout manifest claims no step'

    $unregistered = Invoke-E2eScenarioCheck -Check 'not-a-registered-check' -Context $null
    Assert-That ($unregistered.ok -eq $false -and $unregistered.detail -eq 'unregistered-check') 'an unregistered check id fails closed'

    $badManifest = Join-Path $tempRoot 'malformed.json'
    [IO.File]::WriteAllText($badManifest, '{ "scenarios": [', $utf8)
    $malformed = Get-OrchestrationE2eManifest -ManifestPath $badManifest -RepoRoot $RepoRoot
    Assert-That ($malformed.status -eq 'invalid') 'a malformed manifest is rejected without throwing'

    $scalarScenarios = Join-Path $tempRoot 'scalar.json'
    [IO.File]::WriteAllText($scalarScenarios, '{ "scenarios": "RR-E2E-01", "rollout_steps": [] }', $utf8)
    $scalar = Get-OrchestrationE2eManifest -ManifestPath $scalarScenarios -RepoRoot $RepoRoot
    Assert-That ($scalar.status -eq 'invalid') 'a scalar scenarios field is rejected without coercion'

    # ---------- A4 rollout checklist ----------
    $checklist = Get-OrchestrationRolloutChecklist -RepoRoot $RepoRoot -TimestampUtc $stamp
    Assert-That ($checklist.status -eq 'ok') 'rollout checklist is derived'
    Assert-That ($checklist.counts.total -eq 19) 'rollout checklist has 19 steps'
    $stepStatus = @('shipped', 'shadow-ready', 'blocked-activation', 'blocked-evidence')
    Assert-That ((@($checklist.steps | Where-Object { [string]$_.status -notin $stepStatus })).Count -eq 0) 'every rollout status is in the closed set'
    Assert-That ((($checklist.counts.shipped + $checklist.counts.shadow_ready + $checklist.counts.blocked_activation + $checklist.counts.blocked_evidence) -eq 19)) 'rollout status counts partition all 19 steps'
    $stepRows = @{}
    foreach ($s in $checklist.steps) { $stepRows[[int]$s.step] = $s }
    Assert-That ($stepRows[17].status -eq 'blocked-evidence' -and $stepRows[17].proof_present -eq $false) 'V2 native step is blocked on its absent evidence registry'
    Assert-That ($stepRows[17].reason -eq 'proof-artifact-absent') 'V2 native step states the proof artifact is absent'
    # Estado ATIVADO (batch cca566f, 2026-10-04): asserts de estado EXATO, com a
    # data da ativacao no nome. Drift para qualquer lado falha. O invariant
    # "nenhuma flag ativa e reportada como ativa sem prova" segue provado adiante,
    # em fixture com registry CONTROLADO (nao por leitura do registry vivo).
    Assert-That ($stepRows[6].status -eq 'shipped' -and $stepRows[6].flag -eq 'watchdog' -and $stepRows[6].flag_active -eq $true -and $stepRows[6].reason -eq 'flag-active-with-evidence') 'watchdog enforcement step is shipped on its activated flag with evidence'
    Assert-That ($stepRows[5].status -eq 'shipped' -and $stepRows[5].shadow_on -eq $false) 'watchdog step ships on the activated flag (shadow leg is off, never shadow-ready)'
    Assert-That ($stepRows[4].status -eq 'shipped' -and $stepRows[4].shadow_on -eq $false) 'Jev health-only step ships on the activated flag (shadow leg off)'
    Assert-That ($stepRows[1].status -eq 'shipped' -and $null -eq $stepRows[1].flag_active) 'a step with no activation flag reports shipped, not flag-active'
    Assert-That ($stepRows[1].note -match 'real V2 Windows lane result stays pending') 'the shipped port-preflight step keeps its pending-lane note'
    $activatedSteps = @($checklist.steps | Where-Object { $_.flag_active -eq $true } | ForEach-Object { [int]$_.step })
    Assert-That (($activatedSteps -join ',') -ceq '4,5,6,7,8,9,10,11,12,14,17,18') 'the live registry activates exactly the steps whose flag resolves ON (batch cca566f)'
    Assert-That (($checklist.counts.shipped -eq 12) -and ($checklist.counts.shadow_ready -eq 0) -and ($checklist.counts.blocked_activation -eq 6) -and ($checklist.counts.blocked_evidence -eq 1)) 'rollout counts partition the 19 steps in the activated state (12/0/6/1)'
    # INVARIANTE (nao estado): num registry CONTROLADO com toda ativacao OFF, nenhuma
    # flag e reportada ativa. A prova nao depende do estado vivo.
    $allOffList = Get-OrchestrationRolloutChecklist -RepoRoot (New-RolloutFixture 'fx-all-off' (New-ControlledFlagsJson $false)) -TimestampUtc $stamp
    Assert-That (($allOffList.status -eq 'ok') -and ((@($allOffList.steps | Where-Object { $_.flag_active -eq $true })).Count -eq 0)) 'INVARIANT: no activation flag is reported active on a controlled all-OFF registry'
    Assert-That ((@($checklist.steps | Where-Object { $_.lib_present -eq $false })).Count -eq 0) 'every rollout library is present in the repo'
    Assert-That ((@($checklist.steps | Where-Object { $_.evidence_present -eq $false })).Count -eq 0) 'every rollout evidence record is present in the repo'
    Assert-That ((@($checklist.steps | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.note) })).Count -eq 0) 'every rollout step carries its note'

    # A fabricated absent proof artifact must flip the step to blocked-evidence:
    # the status is derived, never declared by the manifest.
    $tempRepo = Join-Path $tempRoot 'temp-repo'
    [void][IO.Directory]::CreateDirectory($tempRepo)
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'source') -Destination $tempRepo -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'scripts') -Destination $tempRepo -Recurse -Force
    # Registry CONTROLADO (toda ativacao OFF, perna de shadow ON) no fixture repo:
    # e o estado conhecido em que os invariantes das linhas abaixo tem de valer.
    # Sem isto o fixture herdava o registry real (ja ativado em 2026-10-04) e os
    # invariantes viravam leitura do estado vivo em vez de prova.
    [IO.File]::WriteAllText((Join-Path $tempRepo 'source/registry/capability-flags.json'), (New-ControlledFlagsJson $true), $utf8)
    $fakeRepo = Join-Path $tempRepo 'source/registry/e2e-scenarios.json'
    $mutated = New-FixtureManifest 'allshadow.json' { param($d) foreach ($s in $d.rollout_steps) { $s.shadow_sufficient = $true; $s.shadow_flag = 'task_kernel' } }
    [IO.File]::Copy($mutated, $fakeRepo, $true)
    [void][IO.Directory]::CreateDirectory((Join-Path $tempRepo 'evidence/v3.1/runtime-reliability'))
    foreach ($name in @('phase22', 'phase25', 'phase26', 'phase28', 'phase29', 'phase30', 'phase31', 'phase32', 'phase33', 'phase34', 'phase35', 'phase36', 'phase37', 'phase38', 'phase39', 'phase40', 'phase41')) {
        [IO.File]::WriteAllText((Join-Path $tempRepo ('evidence/v3.1/runtime-reliability/' + $name + '.json')), '{"status":"synthetic-fixture"}', $utf8)
    }
    $derived = Get-OrchestrationRolloutChecklist -RepoRoot $tempRepo -TimestampUtc $stamp
    $derivedRows = @{}
    foreach ($s in $derived.steps) { $derivedRows[[int]$s.step] = $s }
    Assert-That ($derived.status -eq 'ok') 'derived checklist over a fixture repo is computed'
    Assert-That ($derivedRows[17].status -eq 'blocked-evidence') 'a fabricated shadow claim still cannot promote an absent proof artifact'
    Assert-That ($derivedRows[1].status -eq 'shadow-ready') 'a sufficient shadow leg promotes a delivered step to shadow-ready'
    Assert-That ((@($derived.steps | Where-Object { $_.status -eq 'shipped' })).Count -eq 0) 'no step is shipped while its activation flag is OFF'
    Assert-That ($derivedRows[1].status -ne 'blocked-activation') 'step 1 is not silently blocked while the shadow leg is sufficient'

    # ---------- A5 sanitized, bounded, deterministic ----------
    $long = 'A' * 4000
    $hostile = New-FixtureManifest 'hostile.json' {
        param($d)
        $d.scenarios[0].description = $long + ' sk-SYNTHETICSECRET token=abc123 https://evil.example.com/x'
        $d.scenarios[0].evidence_ref = 'k sk-SYNTHETICSECRET ' + $long
        $d.scenarios[0].required_activation = 'hostile.example.com ' + $long
    }
    $hostileResult = Invoke-OrchestrationE2eManifest -ManifestPath $hostile -RepoRoot $RepoRoot -TimestampUtc $stamp
    Assert-That ($hostileResult.status -eq 'ok') 'a hostile but structurally valid manifest still runs'
    $hostileRow = @($hostileResult.scenarios | Where-Object { $_.scenario_id -eq 'RR-E2E-01' })[0]
    Assert-That ($hostileRow.description.Length -le 160) 'a hostile description is bounded'
    Assert-That ($hostileRow.evidence_ref.Length -le 240) 'a hostile evidence ref is bounded'
    Assert-That ($hostileRow.detail.Length -le 300) 'a hostile required activation is bounded'
    $hostileText = (ConvertTo-Json -InputObject $hostileResult -Depth 8 -Compress)
    Assert-That ($hostileText -notmatch 'SYNTHETICSECRET' -and $hostileText -notmatch 'token=abc123' -and $hostileText -notmatch 'evil\.example\.com') 'hostile values are redacted out of the whole report'
    $caps = @{ scenario_id = 40; ordinal = 4; category = 40; classification = 40; status = 40; detail = 300; evidence_ref = 240; mapped_component = 240; required_activation = 300 }
    $oversized = 0
    foreach ($row in $hostileResult.scenarios) {
        foreach ($field in $caps.Keys) {
            $value = [string]$row.PSObject.Properties[$field].Value
            if ($value.Length -gt $caps[$field]) { $oversized++ }
        }
    }
    Assert-That ($oversized -eq 0) 'every emitted field stays inside its declared cap'
    $hostileReportBytes = [Text.Encoding]::UTF8.GetByteCount($hostileText)
    Assert-That ($hostileReportBytes -lt 262144) 'the hostile report stays inside a bounded envelope'

    $first = Invoke-OrchestrationE2eManifest -RepoRoot $RepoRoot -TimestampUtc $stamp
    $second = Invoke-OrchestrationE2eManifest -RepoRoot $RepoRoot -TimestampUtc $stamp
    Assert-That ((ConvertTo-Json -InputObject $first -Depth 8 -Compress) -ceq (ConvertTo-Json -InputObject $second -Depth 8 -Compress)) 'two harness runs with a fixed timestamp value are byte-identical'
    Assert-That ($first.generated_at -eq '2026-01-02T03:04:05.0000000Z') 'the supplied timestamp value is preserved verbatim'
    $listFirst = Get-OrchestrationRolloutChecklist -RepoRoot $RepoRoot -TimestampUtc $stamp
    $listSecond = Get-OrchestrationRolloutChecklist -RepoRoot $RepoRoot -TimestampUtc $stamp
    Assert-That ((ConvertTo-Json -InputObject $listFirst -Depth 8 -Compress) -ceq (ConvertTo-Json -InputObject $listSecond -Depth 8 -Compress)) 'two checklist runs with a fixed timestamp value are byte-identical'

    # ---------- A6 no side effects ----------
    $flagsBefore = [IO.File]::ReadAllText($flagsPath)
    $flags = ConvertFrom-Json $flagsBefore
    Assert-That ($flags.watchdog.enabled -eq $true -and $flags.watchdog.shadow -eq $false) 'watchdog is activated with no shadow leg before the suite (batch cca566f)'
    $absentPid = 0
    foreach ($candidate in 4180000..4180099) {
        if ($null -eq (Get-Process -Id $candidate -ErrorAction SilentlyContinue)) { $absentPid = $candidate; break }
    }
    $repeat = Invoke-OrchestrationE2eManifest -RepoRoot $RepoRoot -TimestampUtc $stamp
    Assert-That ([IO.File]::ReadAllText($flagsPath) -ceq $flagsBefore) 'the harness never writes capability-flags.json'
    Assert-That ($repeat.counts.pass_synthetic -eq 18 -and $repeat.status -eq 'ok') 'the harness is repeatable in the same process'
    Assert-That (@(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'orchestration-e2e-*' -ErrorAction SilentlyContinue).Count -eq 0) 'the harness leaves no work directory behind'
    $work = Join-Path $tempRoot 'owned-work'
    $owned = Invoke-OrchestrationE2eManifest -RepoRoot $RepoRoot -WorkRoot $work -TimestampUtc $stamp
    Assert-That ($owned.counts.pass_synthetic -eq 18) 'a caller-supplied work root does not change results'
    Assert-That (Test-Path -LiteralPath $work -PathType Container) 'a caller-supplied work root is not deleted by the harness'

    $libText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'OrchestrationE2eManifest.ps1'))
    Assert-That ($libText -notmatch '(?i)Invoke-WebRequest|Invoke-RestMethod|WebClient|TcpClient|Socket\b|Start-BitsTransfer|Invoke-Command') 'the harness library contains no network transport'
    Assert-That ($libText -notmatch '(?i)Stop-Process|taskkill|\.Kill\(') 'the harness library never kills a process'
    Assert-That ($libText -notmatch '[^\x00-\x7F]') 'the harness library is ASCII-only'
    Assert-That (([IO.File]::ReadAllText($PSCommandPath)) -notmatch '[^\x00-\x7F]') 'the test file is ASCII-only'

    # Every passing scenario names the library it exercised, so a pass is always
    # traceable to a delivered component.
    Assert-That ((@($result.scenarios | Where-Object { $_.status -eq 'pass-synthetic' -and [string]::IsNullOrWhiteSpace([string]$_.mapped_component) })).Count -eq 0) 'every passing scenario names its mapped component'
    Assert-That ((@($result.scenarios | Where-Object { $_.status -eq 'pass-synthetic' -and $_.mapped_component -notlike '*Orchestration*' -and $_.mapped_component -notlike '*scripts*' })).Count -eq 0) 'every mapped component is a delivered library path'

    # ---------- A7 negatives: rollout derivation never over-promotes ----------
    $realFlagsJson = $flagsBefore
    $healthyFixture = Get-OrchestrationRolloutChecklist -RepoRoot (New-RolloutFixture 'fx-healthy' $realFlagsJson) -TimestampUtc $stamp
    Assert-That ($healthyFixture.status -eq 'ok' -and $healthyFixture.counts.total -eq 19) 'the healthy fixture repo derives 19 steps'
    Assert-That ((@($healthyFixture.steps | Where-Object { $_.proof_present -eq $false -or $_.evidence_present -eq $false })).Count -eq 0) 'the healthy fixture proves every artifact parses'

    # F1: an unreadable flag registry must never look like a delivered step.
    $corruptFlags = Get-OrchestrationRolloutChecklist -RepoRoot (New-RolloutFixture 'fx-corrupt-reg' '{ "watchdog": ') -TimestampUtc $stamp
    Assert-That ($corruptFlags.counts.shipped -eq 0) 'a corrupted flag registry ships no step'
    Assert-That ($corruptFlags.counts.shadow_ready -eq 0) 'a corrupted flag registry promotes no shadow leg'
    Assert-That ($corruptFlags.counts.blocked_evidence -eq 19) 'a corrupted flag registry blocks every step on evidence'
    Assert-That ((Get-FixtureRow $corruptFlags 1).reason -eq 'flag-registry-unreadable') 'the corrupted registry is named as the reason'

    $absentFlags = Get-OrchestrationRolloutChecklist -RepoRoot (New-RolloutFixture 'fx-absent-reg' $null) -TimestampUtc $stamp
    Assert-That ($absentFlags.counts.shipped -eq 0 -and $absentFlags.counts.shadow_ready -eq 0) 'an absent flag registry ships no step either'
    Assert-That ((@($absentFlags.steps | Where-Object { [string]$_.status -notin @('blocked-evidence') })).Count -eq 0) 'an absent flag registry leaves every step blocked on evidence'

    # F1: an evidence record that exists but does not parse is not proof.
    $badProof = Get-OrchestrationRolloutChecklist -RepoRoot (New-RolloutFixture 'fx-bad-proof' $realFlagsJson @{ 'evidence/v3.1/runtime-reliability/v2-native-evidence.json' = 'not json at all' }) -TimestampUtc $stamp
    $badProofRow = Get-FixtureRow $badProof 17
    Assert-That ($badProofRow.status -eq 'blocked-evidence') 'an unparseable proof record does not promote the step'
    Assert-That ($badProofRow.reason -eq 'proof-artifact-unparseable') 'the unparseable proof record is named as the reason'
    Assert-That ($badProofRow.proof_present -eq $false) 'existence without parsing is never proof'
    Assert-That ($badProofRow.status -ne 'shipped' -and $badProofRow.status -ne 'shadow-ready') 'an unparseable proof can never be shipped or shadow-ready'

    $badEvidence = Get-OrchestrationRolloutChecklist -RepoRoot (New-RolloutFixture 'fx-bad-evidence' $realFlagsJson @{ 'evidence/v3.1/runtime-reliability/phase40.json' = '{"status": ' }) -TimestampUtc $stamp
    $badEvidenceRow = Get-FixtureRow $badEvidence 17
    Assert-That ($badEvidenceRow.status -eq 'blocked-evidence') 'an unparseable evidence record does not promote the step'
    Assert-That ($badEvidenceRow.reason -eq 'evidence-record-unparseable') 'the unparseable evidence record is named as the reason'
    Assert-That ($badEvidenceRow.evidence_present -eq $false) 'an unparseable evidence record is reported as not present'

    # F1: a flag the policy does not declare is blocked-activation, never shipped.
    $noRuntimeSupport = ConvertFrom-Json $realFlagsJson
    $noRuntimeSupport.PSObject.Properties.Remove('runtime_support')
    $undeclared = Get-OrchestrationRolloutChecklist -RepoRoot (New-RolloutFixture 'fx-undeclared' (ConvertTo-Json -InputObject $noRuntimeSupport -Depth 24)) -TimestampUtc $stamp
    $undeclaredRow = Get-FixtureRow $undeclared 17
    Assert-That ($undeclaredRow.flag_declared -eq $false) 'the V2 native flag is reported undeclared in this fixture'
    Assert-That ($undeclaredRow.status -eq 'blocked-activation') 'an undeclared activation flag is blocked-activation'
    Assert-That ($undeclaredRow.reason -eq 'flag-not-declared-in-policy') 'the undeclared flag is named as the reason'
    Assert-That ($undeclaredRow.status -ne 'shipped') 'an undeclared flag is never shipped even with complete parsing evidence'

    # F1: an UNRESOLVABLE flag is not OFF, so it is blocked-evidence.
    $emptyFlagNode = ConvertFrom-Json $realFlagsJson
    $emptyFlagNode.watchdog = [pscustomobject]@{}
    $unresolvable = Get-OrchestrationRolloutChecklist -RepoRoot (New-RolloutFixture 'fx-unresolvable' (ConvertTo-Json -InputObject $emptyFlagNode -Depth 24)) -TimestampUtc $stamp
    $unresolvableRow = Get-FixtureRow $unresolvable 6
    Assert-That ($unresolvableRow.flag_declared -eq $true -and $null -eq $unresolvableRow.flag_active) 'a declared but unreadable flag reports declared with no state'
    Assert-That ($unresolvableRow.status -eq 'blocked-evidence') 'an unresolvable flag state is blocked-evidence, never OFF'
    Assert-That ($unresolvableRow.reason -eq 'flag-state-unresolvable') 'the unresolvable flag is named as the reason'
    Assert-That ((@($unresolvable.steps | Where-Object { [string]$_.status -eq 'shipped' -and $_.flag -eq 'watchdog' })).Count -eq 0) 'no watchdog step is shipped while its flag state is unreadable'

    # F1 invariant over the real repository result.
    Assert-That ((@($checklist.steps | Where-Object { $_.status -eq 'shipped' -and ($_.proof_present -eq $false -or $_.evidence_present -eq $false -or $_.flag_registry_present -eq $false) })).Count -eq 0) 'no real shipped step lacks a parsed proof, evidence or flag registry'

    # F1: a flag leaf is a state ONLY when it is exactly a boolean. [bool]'false'
    # is $true and [bool]@{} is $true, so a coerced leaf promotes a disabled or
    # unreadable flag to shipped. Every other type must resolve to no state at
    # all, which is blocked-evidence and never OFF.
    $hostileLeaves = @(
        @{ label = 'string-false'; value = 'false' }
        @{ label = 'string-true'; value = 'true' }
        @{ label = 'number-one'; value = 1 }
        @{ label = 'number-zero'; value = 0 }
        @{ label = 'null-leaf'; value = $null }
        @{ label = 'object-leaf'; value = [pscustomobject]@{ note = 'enabled' } }
    )
    foreach ($case in $hostileLeaves) {
        $hostileFlags = ConvertFrom-Json $realFlagsJson
        $hostileFlags.watchdog.enabled = $case.value
        $hostileList = Get-OrchestrationRolloutChecklist -RepoRoot (New-RolloutFixture ('fx-leaf-' + $case.label) (ConvertTo-Json -InputObject $hostileFlags -Depth 24)) -TimestampUtc $stamp
        $hostileRow = Get-FixtureRow $hostileList 6
        Assert-That ($null -eq $hostileRow.flag_active) ('a ' + $case.label + ' enabled leaf resolves to no activation state at all')
        Assert-That ($hostileRow.status -eq 'blocked-evidence' -and $hostileRow.reason -eq 'flag-state-unresolvable') ('a ' + $case.label + ' enabled leaf is blocked-evidence, never OFF')
        Assert-That ((@($hostileList.steps | Where-Object { [string]$_.flag -eq 'watchdog' -and [string]$_.status -in @('shipped', 'shadow-ready') })).Count -eq 0) ('a ' + $case.label + ' enabled leaf promotes no step carrying that flag')
    }

    # F1: the 'active' leaf follows exactly the same rule as 'enabled'.
    $activeFlags = ConvertFrom-Json $realFlagsJson
    $activeFlags.capability_router.active = 'false'
    $activeList = Get-OrchestrationRolloutChecklist -RepoRoot (New-RolloutFixture 'fx-leaf-active' (ConvertTo-Json -InputObject $activeFlags -Depth 24)) -TimestampUtc $stamp
    $activeRow = Get-FixtureRow $activeList 13
    Assert-That ($null -eq $activeRow.flag_active) 'a string active leaf resolves to no activation state'
    Assert-That ($activeRow.status -eq 'blocked-evidence' -and $activeRow.reason -eq 'flag-state-unresolvable') 'a malformed active leaf is blocked-evidence, never shipped'
    Assert-That ((@($activeList.steps | Where-Object { [string]$_.flag -eq 'capability_router' -and [string]$_.status -in @('shipped', 'shadow-ready') })).Count -eq 0) 'a malformed active leaf promotes no step carrying that flag'

    # F1: a malformed shadow leaf can never be read as an ON shadow leg.
    # Registry CONTROLADO (ativacoes OFF) + leaf de shadow ilegivel: com nenhuma
    # flag ativa, um shipped/shadow-ready so poderia vir da shadow leg. O
    # registry real esta ativado (batch cca566f), entao herdar dele tornaria o
    # shipped legitimo (pela flag) e o assert perderia o que prova.
    $shadowFlags = ConvertFrom-Json (New-ControlledFlagsJson $false)
    $shadowFlags.watchdog.shadow = 'false'
    $shadowList = Get-OrchestrationRolloutChecklist -RepoRoot (New-RolloutFixture 'fx-leaf-shadow' (ConvertTo-Json -InputObject $shadowFlags -Depth 24)) -TimestampUtc $stamp
    $shadowRow = Get-FixtureRow $shadowList 5
    Assert-That ($null -eq $shadowRow.shadow_on) 'a string shadow leaf resolves to no shadow state'
    Assert-That ($shadowRow.status -ne 'shadow-ready' -and $shadowRow.status -ne 'shipped') 'a malformed shadow leaf is never shadow-ready or shipped'
    Assert-That ((@($shadowList.steps | Where-Object { [string]$_.shadow_flag -eq 'watchdog' -and [string]$_.status -in @('shadow-ready', 'shipped') })).Count -eq 0) 'a malformed shadow leaf promotes no step on that shadow leg'

    # F1: a real boolean still resolves, so strict typing costs no honest state.
    $falseFlags = ConvertFrom-Json $realFlagsJson
    $falseFlags.watchdog.enabled = $false
    $falseFlags.watchdog.shadow = $false
    $falseList = Get-OrchestrationRolloutChecklist -RepoRoot (New-RolloutFixture 'fx-leaf-bool-false' (ConvertTo-Json -InputObject $falseFlags -Depth 24)) -TimestampUtc $stamp
    $falseRow = Get-FixtureRow $falseList 5
    Assert-That ($falseRow.flag_active -eq $false) 'a real boolean false is reported as a resolved OFF activation state'
    Assert-That ($falseRow.shadow_on -eq $false) 'a real boolean false is reported as a resolved OFF shadow state'
    Assert-That ($falseRow.status -eq 'blocked-activation' -and $falseRow.reason -eq 'activation-flag-off') 'a real boolean false leaves the step honestly blocked on activation'

    $trueFlags = ConvertFrom-Json $realFlagsJson
    $trueFlags.watchdog.enabled = $true
    $trueList = Get-OrchestrationRolloutChecklist -RepoRoot (New-RolloutFixture 'fx-leaf-bool-true' (ConvertTo-Json -InputObject $trueFlags -Depth 24)) -TimestampUtc $stamp
    Assert-That ((Get-FixtureRow $trueList 6).status -eq 'shipped') 'a real boolean true still ships a step whose proof and evidence parse'

    # ---------- A7 negatives: no callback seam on either public API ----------
    $harnessCmd = Get-Command Invoke-OrchestrationE2eManifest
    $checklistCmd = Get-Command Get-OrchestrationRolloutChecklist
    Assert-That ($harnessCmd.Parameters.Keys -notcontains 'Clock') 'the harness API exposes no -Clock parameter'
    Assert-That ($checklistCmd.Parameters.Keys -notcontains 'Clock') 'the rollout API exposes no -Clock parameter'
    foreach ($api in @($harnessCmd, $checklistCmd)) {
        $sb = @($api.Parameters.Values | Where-Object { $_.ParameterType -eq [scriptblock] })
        Assert-That ($sb.Count -eq 0) ('the ' + $api.Name + ' API takes no scriptblock parameter')
    }
    Assert-That ($harnessCmd.Parameters.Keys -contains 'TimestampUtc') 'the harness API takes TimestampUtc as a value'
    Assert-That ($checklistCmd.Parameters.Keys -contains 'TimestampUtc') 'the rollout API takes TimestampUtc as a value'

    $badStamp = 'not-a-timestamp'
    $invalidStamp = Invoke-OrchestrationE2eManifest -RepoRoot $RepoRoot -TimestampUtc $badStamp
    $parsedStamp = [DateTimeOffset]::MinValue
    $parsedOk = [DateTimeOffset]::TryParse([string]$invalidStamp.generated_at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsedStamp)
    Assert-That ($invalidStamp.timestamp_valid -eq $false) 'an unparseable timestamp is reported as invalid'
    Assert-That ($parsedOk -and $invalidStamp.generated_at -like '*Z') 'an unparseable timestamp falls back to an internal UTC instant'
    Assert-That ((@($invalidStamp.holds | Where-Object { [string]$_ -match 'not a parseable ISO-8601' })).Count -eq 1) 'the invalid timestamp is stated as a hold note'
    Assert-That ((ConvertTo-Json -InputObject $invalidStamp -Depth 8 -Compress) -notmatch [regex]::Escape($badStamp)) 'the hostile timestamp value is never echoed into the report'
    $invalidList = Get-OrchestrationRolloutChecklist -RepoRoot $RepoRoot -TimestampUtc $badStamp
    Assert-That ($invalidList.timestamp_valid -eq $false -and @($invalidList.holds).Count -eq 1) 'the rollout API states the invalid timestamp as a hold too'

    # ---------- A7 negatives: the MCP timeout seam stays distinct ----------
    $mcpLib = Join-Path $RepoRoot 'scripts/v3/lib/OrchestrationMcpSafety.ps1'
    $timeoutWork = Join-Path $tempRoot 'mcp-timeout-work'
    [void][IO.Directory]::CreateDirectory($timeoutWork)
    $seam = Get-McpSeamObservation -LibPath $mcpLib -WorkRoot $timeoutWork
    Assert-That ($seam.timeout_token -eq 'timeout') 'the timeout probe token classifies as timeout'
    Assert-That ($seam.timeout_token -ne 'network') 'the timeout probe token is never classified as network'
    Assert-That ($seam.network_token -eq 'network') 'the network probe token classifies as network'
    Assert-That ($seam.network_token -ne 'timeout') 'the network probe token is never classified as timeout'

    Assert-That ([string]$seam.timeout_call.failure_class -eq 'timeout') 'a real timeout probe is classified timeout'
    Assert-That ([string]$seam.timeout_call.failure -eq 'MCP_TIMEOUT') 'a real timeout probe reports the MCP_TIMEOUT failure'
    Assert-That ([string]$seam.timeout_call.status -eq 'MCP_UNAVAILABLE' -and $seam.timeout_call.fallback_continue -eq $true) 'an optional timeout degrades to continue'
    Assert-That ([string]$seam.timeout_call.circuit -eq 'CLOSED') 'a first timeout in a turn leaves the circuit closed'
    Assert-That ($seam.probe_ran -eq $true) 'the timeout probe seam really executed'
    Assert-That ([string]$seam.network_call.failure_class -eq 'network') 'a real network probe is classified network'
    Assert-That ([string]$seam.network_call.failure -ne 'MCP_TIMEOUT') 'a network failure is never reported as the timeout result'
    Assert-That ([string]$seam.network_call.failure -eq 'MCP_NETWORK_ERROR') 'a real network probe reports the MCP_NETWORK_ERROR failure'
    Assert-That ($rows['RR-E2E-12'].detail -match 'distinct') 'the timeout scenario reports its distinct classification'

    # ---------- A7 negatives: the real V2 deny is not offline-decidable ----------
    $scenario39 = @($manifest.scenarios | Where-Object { $_.scenario_id -eq 'RR-E2E-39' })[0]
    $scenario41 = @($manifest.scenarios | Where-Object { $_.scenario_id -eq 'RR-E2E-41' })[0]
    Assert-That ($scenario39.classification -eq 'requires-operator-runtime') 'scenario 39 stays requires-operator-runtime'
    Assert-That ([string]::IsNullOrWhiteSpace([string]$scenario39.check)) 'scenario 39 declares no offline check'
    Assert-That ($rows['RR-E2E-39'].status -eq 'blocked-requires-operator') 'scenario 39 is reported blocked on the operator runtime'
    Assert-That ($rows['RR-E2E-39'].status -ne 'pass-synthetic') 'scenario 39 is never reported as a pass'
    Assert-That ($scenario41.scenario_id -ne $scenario39.scenario_id -and [int]$scenario41.ordinal -eq 41) 'the synthetic gating invariant is its own scenario 41 row'
    Assert-That ($scenario41.classification -eq 'runnable-synthetic' -and $scenario41.check -eq 'v2-native-no-evidence') 'scenario 41 is the separate synthetic gating invariant'
    Assert-That ($rows['RR-E2E-41'].status -eq 'pass-synthetic') 'scenario 41 passes as its own synthetic row'
    Assert-That ($rows['RR-E2E-41'].detail -match 'not-proven') 'the synthetic row reports a refusal, not a real deny'

    $demoted = New-FixtureManifest 'demote39.json' { param($d) $d.scenarios[38].classification = 'runnable-synthetic' }
    $demotedDoc = Get-OrchestrationE2eManifest -ManifestPath $demoted -RepoRoot $RepoRoot
    Assert-That ($demotedDoc.status -eq 'invalid' -and $demotedDoc.reason -like 'runnable-without-check*') 'promoting the real V2 deny to offline-decidable without a check is rejected'
    $forged39 = New-FixtureManifest 'forge39.json' { param($d) $d.scenarios[38].classification = 'runnable-synthetic'; $d.scenarios[38] | Add-Member -NotePropertyName 'check' -NotePropertyValue 'v2-runtime-deny' -Force }
    $forged39Doc = Get-OrchestrationE2eManifest -ManifestPath $forged39 -RepoRoot $RepoRoot
    Assert-That ($forged39Doc.status -eq 'invalid' -and $forged39Doc.reason -like 'unknown-check*') 'a forged offline check for the real V2 deny is rejected'

    # The synthetic invariant is a refusal, never an enablement.
    $candidates = @(Get-V2GateCandidates -LibPath (Join-Path $RepoRoot 'scripts/v3/lib/OrchestrationV2NativeGating.ps1'))
    Assert-That ($candidates.Count -eq 8) 'the V2 gating registry declares 8 candidates'
    foreach ($c in $candidates) {
        Assert-That ($c.enabled -eq $false -and -not [string]::IsNullOrWhiteSpace([string]$c.reason)) ('every declared V2 candidate stays refused with a reason: ' + $c.feature_id)
    }

    if ($absentPid -ge 1) {
        Assert-That ($null -eq (Get-Process -Id $absentPid -ErrorAction SilentlyContinue)) 'an absent PID probed by the suite is still absent after the harness run'
    }
}
finally {
    try { if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
}

Write-Host ('[E2E-MANIFEST] passed=' + $passed + '/' + $total)
if ($passed -ne $total) { exit 1 }
exit 0