[CmdletBinding()]
param(
    [string]$GatePath = '',
    [string]$ReportPath = '',
    [string]$RegistryPath = '',
    [string]$SpikePath = '',
    [string]$ShadowReportPath = '',
    [string]$ConfigPath = ''
)
$ErrorActionPreference = 'Stop'
$v3 = $PSScriptRoot
$lib = Join-Path $v3 'CapabilityActivation.ps1'
. $lib
$repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $v3))
# Fixtures sinteticas da distribuicao (P5): default repo-relativo; override
# via param. Caminhos de evidence/cache (gitignored por desenho) e o
# opencode.json vivo nunca sao pre-requisito: o que for live vira SKIP.
$fxRoot = Join-Path $repo 'tests\fixtures\v3'
if ([string]::IsNullOrWhiteSpace($GatePath)) { $GatePath = Join-Path $fxRoot 'evals\gate.json' }
if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath = Join-Path $fxRoot 'evals\report.json' }
if ([string]::IsNullOrWhiteSpace($RegistryPath)) { $RegistryPath = Join-Path $fxRoot 'activation\registry.json' }
if ([string]::IsNullOrWhiteSpace($SpikePath)) { $SpikePath = Join-Path $fxRoot 'activation\spike.json' }
if ([string]::IsNullOrWhiteSpace($ShadowReportPath)) { $ShadowReportPath = Join-Path $fxRoot 'activation\shadow-report.json' }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $fxRoot 'activation\config.json' }

$total = 0
$passed = 0
$skipped = 0
function Assert-That($condition, $name, $detail) {
    $script:total++
    if ($condition) { $script:passed++; Write-Host "[PASS] $name" }
    else { Write-Host "[FAIL] $name -- $detail" }
}
function Skip-That($name, $reason) {
    $script:total++
    $script:skipped++
    Write-Host "[SKIP] $name -- $reason"
}

function Write-Fixture {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $lf = ($Text -replace "`r`n", "`n" -replace "`r", "`n")
    [IO.File]::WriteAllText($Path, $lf, [Text.UTF8Encoding]::new($false))
}

$base = Join-Path ([IO.Path]::GetTempPath()) ('v3-activation-lib-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base -Force | Out-Null

try {
    Assert-That (Test-Path -LiteralPath $lib -PathType Leaf) 'Lib file exists' "Missing $lib"
    foreach ($fn in @('Test-ActivationGate', 'Get-ActivationRegistryStats', 'Test-ActivationSpike', 'Get-ActivationShadowView', 'Get-ActivationDecision', 'Invoke-CapabilityActivation', 'Get-ActivationSafeFlagsDoc', 'Update-ActivationFlagsDoc')) {
        Assert-That ($null -ne (Get-Command $fn -ErrorAction SilentlyContinue)) "Function exists: $fn" 'Missing'
    }

    # Registry fixture com freshness renovada em runtime (fixture estatica
    # envelhece; o frescor e propriedade temporal, nao conteudo).
    $freshReg = Join-Path $base 'fresh-reg.json'
    $freshDoc = ([IO.File]::ReadAllText($RegistryPath, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
    $nowStamp = ([DateTimeOffset]::UtcNow.ToString('o'))
    try { $freshDoc.registry.generated_at = $nowStamp } catch { }
    try { $freshDoc.registry.freshness.computed_at = $nowStamp } catch { }
    try { $freshDoc.registry.freshness.age_seconds = 0 } catch { }
    Write-Fixture -Path $freshReg -Text ((($freshDoc | ConvertTo-Json -Depth 20) + "`n"))

    $gateReal = ([IO.File]::ReadAllText($GatePath, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
    $reportReal = ([IO.File]::ReadAllText($ReportPath, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
    $metricsReal = $reportReal.metrics

    $gPass = Test-ActivationGate -Metrics $metricsReal -Gate $gateReal
    Assert-That ([bool]$gPass.Pass) 'Gate real PASS (report atual passa)' (($gPass.Reasons -join ' | '))
    Assert-That ((@($gPass.Checks).Count -eq 8)) 'Gate tem 8 checks' ((@($gPass.Checks).Count))

    $strictGate = $gateReal | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    try { $strictGate.thresholds.agent_selection_correctness = 1.01 } catch { }
    $gStrict = Test-ActivationGate -Metrics $metricsReal -Gate $strictGate
    Assert-That (-not [bool]$gStrict.Pass) 'Gate estrito (1.01) FAIL' 'Passou indevidamente'

    $badMetrics = @{
        agent_selection_correctness = 1.0; permission_violations = 1; forbidden_capability_selection = 0
        auto_trust_elevation = 0; authority_escalation = 0; fallback_correctness = 1.0
        missing_specialist = 0; unnecessary_delegation = 0
    }
    $gBad = Test-ActivationGate -Metrics $badMetrics -Gate $gateReal
    Assert-That (-not [bool]$gBad.Pass) 'Gate com permission=1 FAIL (zero-tolerancia)' 'Passou indevidamente'

    $badFb = @{
        agent_selection_correctness = 1.0; permission_violations = 0; forbidden_capability_selection = 0
        auto_trust_elevation = 0; authority_escalation = 0; fallback_correctness = 0.9
        missing_specialist = 0; unnecessary_delegation = 0
    }
    $gFb = Test-ActivationGate -Metrics $badFb -Gate $gateReal
    Assert-That (-not [bool]$gFb.Pass) 'Gate com fallback<1.0 FAIL' 'Passou indevidamente'

    $policyReal = ([IO.File]::ReadAllText((Join-Path $repo 'source\registry\capability-policy.json'), [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
    $statsReal = Get-ActivationRegistryStats -RegistryPath $freshReg -RepoRoot $repo -Policy $policyReal
    Assert-That ([bool]$statsReal.Available) 'Registry REAL legivel' ([string]$statsReal.Error)
    Assert-That ([int]$statsReal.AgentsAvailable -ge 5) 'Registry REAL tem agentes suficientes' ([string]$statsReal.AgentsAvailable)
    Assert-That ([int]$statsReal.AgentsWithCaps -ge 5) 'Registry REAL rico: agentes com caps >= 5' ([string]$statsReal.AgentsWithCaps)
    Assert-That ([int]$statsReal.SkillsWithCaps -ge 5) 'Registry REAL rico: skills com caps >= 5' ([string]$statsReal.SkillsWithCaps)
    Assert-That ([int]$statsReal.McpsWithCaps -ge 1) 'Registry REAL rico: mcps com caps >= 1' ([string]$statsReal.McpsWithCaps)
    Assert-That ([int]$statsReal.AgentsWithCategories -ge 5) 'Registry REAL rico: agentes com categories >= 5' ([string]$statsReal.AgentsWithCategories)

    $spikeReal = Test-ActivationSpike -SpikePath $SpikePath -RepoRoot $repo
    Assert-That ([bool]$spikeReal.Available) 'Spike legivel' ([string]$spikeReal.Error)
    Assert-That (-not [bool]$spikeReal.Supported) 'Spike hoje: enforcement_supported=false' 'Spike true inesperado'

    $shadowReal = Get-ActivationShadowView -ShadowReportPath $ShadowReportPath -RepoRoot $repo
    Assert-That ([bool]$shadowReal.Available) 'Shadow report legivel' ([string]$shadowReal.Error)
    Assert-That ([bool]$shadowReal.Ok) 'Shadow sem regressao (v3_worse=0 perm=0 auth=0)' ('w={0} p={1} a={2}' -f $shadowReal.Worse, $shadowReal.PermissionViolations, $shadowReal.AuthorityChanges)

    $allowReal = Get-ActivationAllowlist -ConfigPath $ConfigPath
    Assert-That ([bool]$allowReal.Available) 'Allowlist legivel' ([string]$allowReal.Error)
    Assert-That ((@($allowReal.AllowNames).Count -ge 5)) 'Allowlist tem agentes' ((@($allowReal.AllowNames).Count))

    $evalReal = Invoke-CapabilityActivation -RegistryPath $freshReg -GatePath $GatePath -ReportPath $ReportPath -SpikePath $SpikePath -ShadowReportPath $ShadowReportPath -ConfigPath $ConfigPath -RepoRoot $repo
    Assert-That ([bool]$evalReal.gate_pass) 'Invoke real: gate_pass=true (fixture offline passa)' (($evalReal.gate_reasons -join ' | '))
    Assert-That ((@($evalReal.areas).Count -eq 3)) 'Invoke real: 3 areas decididas' ((@($evalReal.areas).Count))
    $decMap = @{}
    foreach ($a in @($evalReal.areas)) { $decMap[[string]$a.area] = [string]$a.decision }
    Assert-That ((($decMap['router_active'] -ceq 'hold') -or ($decMap['router_active'] -ceq 'activate'))) 'Real router_active e hold ou activate (readiness pode ativar)' ($decMap['router_active'])
    Assert-That ((($decMap['skill_routing'] -ceq 'hold') -or ($decMap['skill_routing'] -ceq 'activate'))) 'Real skill_routing e hold ou activate (readiness pode ativar)' ($decMap['skill_routing'])
    Assert-That (($decMap['mcp_routing'] -ceq 'hold')) 'Real mcp_routing=hold sempre (trava de versao)' ($decMap['mcp_routing'])
    $allReasons = ((@($evalReal.areas) | ForEach-Object { (@($_.reasons) -join ' | ') }) -join ' || ')
    Assert-That (-not ($allReasons -match 'registry thin|classes vazias')) 'Razoes reais nao citam thin/classes vazias (registry enriquecido)' $allReasons
    Assert-That ($allReasons -match 'enforcement_supported=false') 'Razoes citam enforcement false (mcp)' $allReasons
    Assert-That ([int]$evalReal.authority_changes -eq 0) 'authority_changes=0' ([string]$evalReal.authority_changes)

    # Fixture rica: registry com caps + fresca + spike true + shadow Ok => router/skill activate; mcp sempre hold (trava de versao)
    $now = ([DateTimeOffset]::UtcNow.ToString('o'))
    $richReg = Join-Path $base 'rich-reg.json'
    $caps = @()
    foreach ($n in @('coder', 'explorer', 'researcher', 'architect', 'reviewer', 'tester')) {
        $caps += [ordered]@{ id = ('agent:' + $n); type = 'agent'; name = $n; status = 'available'; categories = @('engineering'); capabilities = @('code.bounded-edit'); capability_profile = [ordered]@{ preferred = @('code.bounded-edit'); forbidden = @() } }
    }
    for ($i = 1; $i -le 10; $i++) {
        $caps += [ordered]@{ id = ('skill:rich-' + $i); type = 'skill'; name = ('rich-' + $i); status = 'available'; categories = @('skill'); capabilities = @('docs.current'); capability_profile = [ordered]@{ preferred = @(); forbidden = @() } }
    }
    $caps += [ordered]@{ id = 'mcp:good-store'; type = 'mcp'; name = 'good-store'; status = 'available'; categories = @('mcp'); capabilities = @('memory.project-history'); capability_profile = [ordered]@{ preferred = @(); forbidden = @() } }
    $richDoc = [ordered]@{
        schema_version = 1
        registry = [ordered]@{
            generated_at = $now
            runtime = [ordered]@{ name = 'opencode'; version = '9.9.9-test'; isolated_claude_skills = $false }
            freshness = [ordered]@{ source_fingerprint = 'sha256:fixture'; runtime_version = '9.9.9-test'; computed_at = $now; age_seconds = 0 }
            logical_hash = 'sha256:rich-fixture'
        }
        counts = [ordered]@{ agent = 6; skill = 10; mcp = 1; invalid = 0; total = 17 }
        capabilities = $caps
    }
    Write-Fixture -Path $richReg -Text (($richDoc | ConvertTo-Json -Depth 10) + "`n")
    $richPolicy = Join-Path $base 'rich-policy.json'
    Write-Fixture -Path $richPolicy -Text ((($policyReal | ConvertTo-Json -Depth 10) + "`n"))
    $statsRich = Get-ActivationRegistryStats -RegistryPath $richReg -RepoRoot $repo -Policy $policyReal
    Assert-That ([int]$statsRich.AgentsWithCaps -ge 5) 'Fixture rica: agentes com caps >= 5' ([string]$statsRich.AgentsWithCaps)
    Assert-That ([int]$statsRich.SkillsWithCaps -ge 5) 'Fixture rica: skills com caps >= 5' ([string]$statsRich.SkillsWithCaps)
    Assert-That ([int]$statsRich.McpsWithCaps -ge 1) 'Fixture rica: mcps com caps >= 1' ([string]$statsRich.McpsWithCaps)

    $spikeTrue = Join-Path $base 'spike-true.json'
    Write-Fixture -Path $spikeTrue -Text '{"enforcement_supported":true}'
    $spTrue = Test-ActivationSpike -SpikePath $spikeTrue -RepoRoot $repo
    Assert-That ([bool]$spTrue.Supported) 'Spike fixture true reconhecido' 'False inesperado'

    # Allowlist rica precisa conter os agentes da fixture rica; usa allowlist viva? coder/explorer/etc. estao na viva.
    $decRich = Get-ActivationDecision -GateResult $gPass -Stats $statsRich -Spike $spTrue -Shadow $shadowReal -Allowlist $allowReal
    $richMap = @{}
    foreach ($a in @($decRich)) { $richMap[[string]$a.area] = [string]$a.decision }
    Assert-That (($richMap['router_active'] -ceq 'activate')) 'Fixture rica+spike true: router_active=activate' ((@($decRich | Where-Object { $_.area -ceq 'router_active' } | ForEach-Object { (@($_.reasons) -join '|') }) -join ''))
    Assert-That (($richMap['skill_routing'] -ceq 'activate')) 'Fixture rica+spike true: skill_routing=activate' 'hold inesperado'
    Assert-That (($richMap['mcp_routing'] -ceq 'hold')) 'Fixture rica+spike true: mcp_routing=hold (hold incondicional; MCP nunca ativa nesta versao)' ((@($decRich | Where-Object { $_.area -ceq 'mcp_routing' } | ForEach-Object { (@($_.reasons) -join '|') }) -join ''))

    # Mesma fixture rica mas spike false => mcp hold, resto activate (trava dura)
    $decSpikeFalse = Get-ActivationDecision -GateResult $gPass -Stats $statsRich -Spike $spikeReal -Shadow $shadowReal -Allowlist $allowReal
    $sfMap = @{}
    foreach ($a in @($decSpikeFalse)) { $sfMap[[string]$a.area] = [string]$a.decision }
    Assert-That (($sfMap['mcp_routing'] -ceq 'hold')) 'Spike false: mcp nunca ativa (mesmo com registry rica)' ($sfMap['mcp_routing'])

    # Update-ActivationFlagsDoc so muda areas aprovadas (hold sintetico: nada muda)
    $flagsHold = [ordered]@{
        version = 1
        capability_router = [ordered]@{ shadow = $true; active = $false }
        skill_routing = [ordered]@{ enabled = $false }
        mcp_routing = [ordered]@{ enabled = $false }
    }
    $synthHold = @(
        [PSCustomObject]@{ area = 'router_active'; decision = 'hold'; reasons = @('synthetic hold') },
        [PSCustomObject]@{ area = 'skill_routing'; decision = 'hold'; reasons = @('synthetic hold') },
        [PSCustomObject]@{ area = 'mcp_routing'; decision = 'hold'; reasons = @('synthetic hold') }
    )
    $updHold = Update-ActivationFlagsDoc -Flags ($flagsHold | ConvertTo-Json -Depth 10 | ConvertFrom-Json) -Areas @($synthHold)
    Assert-That (([bool](Get-ActivationNodeProp -Node (Get-ActivationNodeProp -Node $updHold -Name 'capability_router') -Name 'active') -eq $false)) 'Apply hold: active permanece false' 'Mudou indevidamente'
    Assert-That (([bool](Get-ActivationNodeProp -Node (Get-ActivationNodeProp -Node $updHold -Name 'skill_routing') -Name 'enabled') -eq $false)) 'Apply hold: skill permanece false' 'Mudou'
    Assert-That (([bool](Get-ActivationNodeProp -Node (Get-ActivationNodeProp -Node $updHold -Name 'mcp_routing') -Name 'enabled') -eq $false)) 'Apply hold: mcp permanece false' 'Mudou'

    # Hold sintetico em skill_routing=activate liga SOMENTE a flag temp de skill; flags reais intactas
    $synthSkill = @(
        [PSCustomObject]@{ area = 'router_active'; decision = 'hold'; reasons = @('synthetic hold') },
        [PSCustomObject]@{ area = 'skill_routing'; decision = 'activate'; reasons = @('synthetic activate') },
        [PSCustomObject]@{ area = 'mcp_routing'; decision = 'hold'; reasons = @('synthetic hold') }
    )
    $realFlagsBefore = [IO.File]::ReadAllText((Join-Path $repo 'source\registry\capability-flags.json'), [Text.UTF8Encoding]::new($false))
    $updSkill = Update-ActivationFlagsDoc -Flags ($flagsHold | ConvertTo-Json -Depth 10 | ConvertFrom-Json) -Areas @($synthSkill)
    Assert-That (([bool](Get-ActivationNodeProp -Node (Get-ActivationNodeProp -Node $updSkill -Name 'skill_routing') -Name 'enabled') -eq $true)) 'Apply sintetico skill=activate: skill temp vira true' 'Nao mudou'
    Assert-That (([bool](Get-ActivationNodeProp -Node (Get-ActivationNodeProp -Node $updSkill -Name 'capability_router') -Name 'active') -eq $false)) 'Apply sintetico skill=activate: router temp permanece false' 'Mudou indevidamente'
    Assert-That (([bool](Get-ActivationNodeProp -Node (Get-ActivationNodeProp -Node $updSkill -Name 'mcp_routing') -Name 'enabled') -eq $false)) 'Apply sintetico skill=activate: mcp temp permanece false' 'Mudou indevidamente'
    $realFlagsAfter = [IO.File]::ReadAllText((Join-Path $repo 'source\registry\capability-flags.json'), [Text.UTF8Encoding]::new($false))
    Assert-That ($realFlagsAfter -ceq $realFlagsBefore) 'Apply sintetico nao toca flags reais' 'Flags reais mudaram'

    $updRich = Update-ActivationFlagsDoc -Flags (($flagsHold | ConvertTo-Json -Depth 10) | ConvertFrom-Json) -Areas @($decRich)
    Assert-That (([bool](Get-ActivationNodeProp -Node (Get-ActivationNodeProp -Node $updRich -Name 'capability_router') -Name 'active') -eq $true)) 'Apply aprovado: active vira true' 'Nao mudou'
    Assert-That (([bool](Get-ActivationNodeProp -Node (Get-ActivationNodeProp -Node $updRich -Name 'skill_routing') -Name 'enabled') -eq $true)) 'Apply aprovado: skill vira true' 'Nao mudou'
    Assert-That (([bool](Get-ActivationNodeProp -Node (Get-ActivationNodeProp -Node $updRich -Name 'mcp_routing') -Name 'enabled') -eq $false)) 'Apply aprovado: mcp permanece false (hold incondicional; nenhum caminho ativa)' 'Ativou indevidamente'

    $safe = Get-ActivationSafeFlagsDoc
    Assert-That (([bool](Get-ActivationNodeProp -Node (Get-ActivationNodeProp -Node $safe -Name 'capability_router') -Name 'shadow') -eq $true)) 'Safe defaults: shadow=true' 'Errado'
    Assert-That (([bool](Get-ActivationNodeProp -Node (Get-ActivationNodeProp -Node $safe -Name 'capability_router') -Name 'active') -eq $false)) 'Safe defaults: active=false' 'Errado'

    # Fail-safe: caminhos invalidos nao lancam, viram hold
    $evalBad = Invoke-CapabilityActivation -RegistryPath (Join-Path $base 'nao-existe.json') -GatePath (Join-Path $base 'nao-existe.json') -ReportPath (Join-Path $base 'nao-existe.json') -RepoRoot $repo
    Assert-That (-not [bool]$evalBad.gate_pass) 'Caminhos invalidos: gate_pass=false (fail-safe)' 'True inesperado'
    Assert-That ((@($evalBad.areas | Where-Object { [string]$_.decision -ceq 'hold' }).Count -eq 3)) 'Caminhos invalidos: 3 holds (fail-safe)' 'Outro'

    # Sem authority: hash da config inalterado apos Invoke (SKIP sem config live;
    # opencode.json vivo e estado da maquina, nao do repo).
    $liveConfig = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
    if (-not (Test-Path -LiteralPath $liveConfig -PathType Leaf)) {
        Skip-That 'Lib nunca altera opencode.json' 'sem opencode.json vivo nesta maquina'
        Skip-That 'opencode.json com prefixo DE22307F' 'sem opencode.json vivo nesta maquina (hash do control plane)'
    }
    else {
        $hBefore = (Get-FileHash -LiteralPath $liveConfig -Algorithm SHA256).Hash
        $null = Invoke-CapabilityActivation -RegistryPath $freshReg -GatePath $GatePath -ReportPath $ReportPath -SpikePath $SpikePath -ShadowReportPath $ShadowReportPath -ConfigPath $liveConfig -RepoRoot $repo
        $hAfter = (Get-FileHash -LiteralPath $liveConfig -Algorithm SHA256).Hash
        Assert-That ($hAfter -ceq $hBefore) 'Lib nunca altera opencode.json' $hAfter
        if ($hAfter.StartsWith('DE22307F')) {
            Assert-That ($true) 'opencode.json com prefixo DE22307F' $hAfter
        }
        else {
            Skip-That 'opencode.json com prefixo DE22307F' 'opencode.json vivo desta maquina nao e o canonico do control plane'
        }
    }
}
finally {
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "TEST RESULTS: $passed / $total passed ($skipped skipped)"
if (($passed + $skipped) -ne $total) { exit 1 }
exit 0
