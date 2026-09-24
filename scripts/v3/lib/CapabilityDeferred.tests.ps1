$ErrorActionPreference = 'Stop'
$v3 = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($v3) -or (-not (Test-Path -LiteralPath $v3 -PathType Container))) {
    $v3 = $PSScriptRoot
}
$lib = Join-Path $v3 'lib\CapabilityDeferred.ps1'
. $lib

$repo = Split-Path -Parent (Split-Path -Parent $v3)
$base = Join-Path ([IO.Path]::GetTempPath()) ('v3-deferredlib-' + [guid]::NewGuid().ToString('N'))
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

function Write-FlagsFixture {
    param([string]$Path, [bool]$Shadow = $true, [bool]$Active = $false, [bool]$Skill = $false, [bool]$Mcp = $false, [bool]$Adaptive = $false)
    $doc = [ordered]@{
        version = 1
        capability_registry = [ordered]@{ enabled = $true }
        capability_reconciler = [ordered]@{ enabled = $false }
        capability_router = [ordered]@{ shadow = $Shadow; active = $Active }
        skill_routing = [ordered]@{ enabled = $Skill }
        mcp_routing = [ordered]@{ enabled = $Mcp }
        routing_telemetry = [ordered]@{ enabled = $false; retention_days = 30 }
        adaptive_ranking = [ordered]@{ enabled = $Adaptive }
    }
    Write-Fixture -Path $Path -Text (($doc | ConvertTo-Json -Depth 10) + "`n")
}

function Write-ConfigFixture {
    param([string]$Path, [string[]]$AllowNames, [string]$Wild = 'deny')
    $task = [ordered]@{}
    foreach ($n in $AllowNames) { $task[$n] = 'allow' }
    $task['*'] = $Wild
    $doc = [ordered]@{
        agent = [ordered]@{ build = [ordered]@{ permission = [ordered]@{ task = $task } } }
    }
    Write-Fixture -Path $Path -Text (($doc | ConvertTo-Json -Depth 10) + "`n")
}

try {
    Assert-That (Test-Path -LiteralPath $lib -PathType Leaf) 'Lib file exists' "Missing $lib"
    foreach ($fn in @('Get-DeferredFlagsView', 'Get-DeferredSpikeView', 'Get-DeferredGovernedRecordView', 'Test-DeferredPathHasReparsePoint', 'Get-DeferredAuthorityView', 'Get-DeferredArtifactView', 'Get-DeferredOrchestrationView', 'Invoke-CapabilityDeferred', 'Get-DeferredItems', 'Get-DeferredExpectedAllowlist', 'Get-DeferredKnownOpencodeHash')) {
        Assert-That ($null -ne (Get-Command $fn -ErrorAction SilentlyContinue)) "Function exists: $fn" 'Missing'
    }

    $expected19 = @(Get-DeferredExpectedAllowlist)
    Assert-That ($expected19.Count -eq 19) 'Allowlist esperada tem 19 IDs' ([string]$expected19.Count)

    $items = @(Get-DeferredItems)
    Assert-That ($items.Count -eq 19) 'Deferred items: 19 listados' ([string]$items.Count)
    foreach ($id in @('semantic-retrieval', 'embeddings', 'adaptive-ranking', 'graph', 'mcp-gateway', 'daemon', 'hot-reload', 'self-modifying-policy', 'auto-trust-elevation', 'cross-project-learning', 'otel', 'sqlite-registry', 'tool-level-mcp-risk', 'skill-mass-migration', 'multi-level-hierarchy', 'peer-to-peer', 'arbiter', 'tool-exposure-unproven', 'hard-filter-exceptions')) {
        Assert-That ((@($items | Where-Object { [string]$_.id -ceq $id }).Count -eq 1)) "Deferred item listado: $id" 'Ausente'
    }
    $allDeferred = $true
    foreach ($it in $items) { if ([string]$it.status -cne 'deferred') { $allDeferred = $false } }
    Assert-That $allDeferred 'Todos os deferred items com status=deferred' 'Status divergente'

    $knownHash = Get-DeferredKnownOpencodeHash
    Assert-That ($knownHash.StartsWith('DE22307F')) 'Baseline conhecido de opencode.json (DE22307F...)' ([string]$knownHash)

    $flagsReal = Get-DeferredFlagsView -RepoRoot $repo
    Assert-That ([bool]$flagsReal.Available) 'Flags reais legiveis' ([string]$flagsReal.Error)
    Assert-That (([bool]$flagsReal.Shadow -eq $true)) 'Flags reais: shadow=true' ([string]$flagsReal.Shadow)
    Assert-That ($flagsReal.RouterActive -is [bool]) 'Flags reais: capability_router.active e bool (governado)' ([string]$flagsReal.RouterActive)
    Assert-That (([bool]$flagsReal.SkillEnabled -eq $false)) 'Flags reais: skill_routing.enabled=false' ([string]$flagsReal.SkillEnabled)
    Assert-That (([bool]$flagsReal.McpEnabled -eq $false)) 'Flags reais: mcp_routing.enabled=false' ([string]$flagsReal.McpEnabled)
    Assert-That (([bool]$flagsReal.AdaptiveEnabled -eq $false)) 'Flags reais: adaptive_ranking.enabled=false' ([string]$flagsReal.AdaptiveEnabled)

    $spikeReal = Get-DeferredSpikeView -RepoRoot $repo
    Assert-That ([bool]$spikeReal.Available) 'Spike real legivel' ([string]$spikeReal.Error)
    Assert-That (-not [bool]$spikeReal.Supported) 'Spike real: enforcement_supported=false' 'Spike true inesperado'

    $authReal = Get-DeferredAuthorityView -ConfigPath '' -IsDefaultPath $true
    Assert-That ([bool]$authReal.Available) 'Authority viva legivel' ([string]$authReal.Error)
    Assert-That ([bool]$authReal.ExpectedOk) 'Authority viva: 19 IDs + *=deny' (('wild=' + [string]$authReal.Wild + ' n=' + @($authReal.AllowNames).Count))
    Assert-That ((@($authReal.AllowNames).Count -eq 19)) 'Authority viva: 19 allows' ((@($authReal.AllowNames) -join ','))
    Assert-That ([string]$authReal.Wild -cne 'allow') 'Authority viva: sem wildcard allow' ("wild='$([string]$authReal.Wild)'")
    Assert-That ([string]$authReal.Hash -ceq $knownHash) 'Authority viva: hash igual ao baseline conhecido' ([string]$authReal.Hash)
    Assert-That (([bool]$authReal.HashMatchesKnown -eq $true)) 'Authority viva: HashMatchesKnown=true' ([string]$authReal.HashMatchesKnown)

    $evalReal = Invoke-CapabilityDeferred -RepoRoot $repo
    Assert-That ([string]$evalReal.decision -ceq 'ok') 'Repo real: decision=ok (flags off)' ((@($evalReal.reasons) -join ' | '))
    Assert-That ((@($evalReal.reasons).Count -eq 0)) 'Repo real: sem razoes de drift' ((@($evalReal.reasons) -join ' | '))
    Assert-That ([string]$evalReal.opencode_hash -ceq $knownHash) 'Repo real: opencode_hash DE22307F...' ([string]$evalReal.opencode_hash)
    Assert-That ((@($evalReal.deferred_items).Count -eq 19)) 'Repo real: 19 deferred_items no resultado' ([string](@($evalReal.deferred_items).Count))
    $artFail = @($evalReal.artifacts | Where-Object { -not [bool]$_.pass })
    Assert-That ($artFail.Count -eq 0) 'Repo real: todos os artifact checks passam' ((@($artFail | ForEach-Object { $_.name }) -join ','))
    $orchFail = @($evalReal.orchestration | Where-Object { -not [bool]$_.pass })
    Assert-That ($orchFail.Count -eq 0) 'Repo real: todos os orchestration checks passam' ((@($orchFail | ForEach-Object { $_.name }) -join ','))

    # Invariante governada ao vivo: active derive da presenca do canonico valido
    $govLive = Get-DeferredGovernedRecordView -RepoRoot $repo
    Assert-That ([bool]$govLive.Valid) 'Registro canonico real valido (Stage-1 governado)' ([string]$govLive.Error)
    Assert-That (([bool]$flagsReal.RouterActive) -eq ([bool]$govLive.Valid)) 'Coerencia ao vivo: active sse governado valido' (('active=' + [string]$flagsReal.RouterActive + ' valid=' + [string]$govLive.Valid))

    # Hide hermetico: esconde o canonico real durante as fixtures negativas;
    # restaurado byte-identico no finally (nunca o deixa ausente)
    $govDir = Join-Path $repo 'evidence\v3\activation'
    $canonGov = Join-Path $govDir 'agent-routing-controlled.json'
    $hiddenGovLib = Join-Path $govDir 'tmp-gov-hidden-lib.json'
    if (Test-Path -LiteralPath $hiddenGovLib -PathType Leaf) { Remove-Item -LiteralPath $hiddenGovLib -Force }
    $canonHashBeforeLib = ''
    if (Test-Path -LiteralPath $canonGov -PathType Leaf) { $canonHashBeforeLib = (Get-FileHash -LiteralPath $canonGov -Algorithm SHA256).Hash }
    $realCanonHiddenLib = Test-Path -LiteralPath $canonGov -PathType Leaf
    if ($realCanonHiddenLib) { Move-Item -LiteralPath $canonGov -Destination $hiddenGovLib -Force }
    Assert-That (-not (Test-Path -LiteralPath $canonGov -PathType Leaf)) 'Hide hermetico: canonico ausente durante fixtures' 'Vazou'

    $flagsOn = Join-Path $base 'flags-on.json'
    Write-FlagsFixture -Path $flagsOn -Active $true
    $evalOn = Invoke-CapabilityDeferred -RepoRoot $repo -FlagsPath $flagsOn
    Assert-That ([string]$evalOn.decision -ceq 'drift') 'Fixture flag ligada sem registro governado: decision=drift' ([string]$evalOn.decision)
    $joinedOn = ((@($evalOn.reasons) | ForEach-Object { "$_" }) -join ' | ')
    Assert-That ($joinedOn -match 'capability_router.active') 'Fixture flag ligada: razao cita capability_router.active' $joinedOn
    $govMissing = Get-DeferredGovernedRecordView -RepoRoot $repo
    Assert-That (-not [bool]$govMissing.Valid) 'Sem registro governado: Valid=false (fail-safe)' ([string]$govMissing.Error)

    # Registro governado CANONICO com backup/restore: preserva o real
    $govDir = Join-Path $repo 'evidence\v3\activation'
    $canonGov = Join-Path $govDir 'agent-routing-controlled.json'
    $govBackup = Join-Path $govDir 'tmp-gov-backup-lib.json'
    if (Test-Path -LiteralPath $govBackup -PathType Leaf) { Remove-Item -LiteralPath $govBackup -Force }
    $canonExisted = Test-Path -LiteralPath $canonGov -PathType Leaf
    if ($canonExisted) { Copy-Item -LiteralPath $canonGov -Destination $govBackup -Force }
    $validGovText = '{"stage":"stage1","gate_pass":true,"activation_status":"controlled_active","flags":{"capability_router":{"active":true},"skill_routing":{"enabled":false},"mcp_routing":{"enabled":false},"adaptive_ranking":{"enabled":false}}}'
    Write-Fixture -Path $canonGov -Text $validGovText
    $govView = Get-DeferredGovernedRecordView -ActivationRecordPath $canonGov -RepoRoot $repo
    Assert-That ([bool]$govView.Valid) 'Registro canonico valido: Valid=true' ([string]$govView.Error)
    $govDefault = Get-DeferredGovernedRecordView -RepoRoot $repo
    Assert-That ([bool]$govDefault.Valid) 'Caminho padrao (canonico): Valid=true' ([string]$govDefault.Error)
    $evalGov = Invoke-CapabilityDeferred -RepoRoot $repo -FlagsPath $flagsOn -ActivationRecordPath $canonGov
    Assert-That ([string]$evalGov.decision -ceq 'ok') 'Flag ligada + registro canonico valido: decision=ok' ((@($evalGov.reasons) -join ' | '))
    Assert-That ((@($evalGov.reasons).Count -eq 0)) 'Flag ligada + registro valido: sem razoes de drift' ((@($evalGov.reasons) -join ' | '))
    $govOrchHit = @($evalGov.orchestration | Where-Object { [string]$_.name -ceq 'router-active-governed' -and [bool]$_.pass })
    Assert-That ($govOrchHit.Count -eq 1) 'Orquestracao: router-active-governed passa sob registro valido' 'Ausente'

    # Nome nao-canonico no mesmo dir NAO governa (mesmo com conteudo valido)
    $govNonCanon = Join-Path $govDir 'tmp-gov-valid.json'
    if (Test-Path -LiteralPath $govNonCanon -PathType Leaf) { Remove-Item -LiteralPath $govNonCanon -Force }
    Write-Fixture -Path $govNonCanon -Text $validGovText
    $govNonCanonView = Get-DeferredGovernedRecordView -ActivationRecordPath $govNonCanon -RepoRoot $repo
    Assert-That (-not [bool]$govNonCanonView.Valid) 'Nome nao-canonico in-dir: Valid=false' ([string]$govNonCanonView.Error)
    Assert-That (([string]$govNonCanonView.Error -match 'canonico')) 'Nome nao-canonico: erro cita canonico' ([string]$govNonCanonView.Error)
    $evalGovNonCanon = Invoke-CapabilityDeferred -RepoRoot $repo -FlagsPath $flagsOn -ActivationRecordPath $govNonCanon
    Assert-That ([string]$evalGovNonCanon.decision -ceq 'drift') 'Flag ligada + nome nao-canonico: decision=drift' ([string]$evalGovNonCanon.decision)

    # Anti self-assert: registro valido fora de evidence/v3/activation NAO governa
    $govExternal = Join-Path $base 'agent-routing-controlled.json'
    Write-Fixture -Path $govExternal -Text $validGovText
    $govExtView = Get-DeferredGovernedRecordView -ActivationRecordPath $govExternal -RepoRoot $repo
    Assert-That (-not [bool]$govExtView.Valid) 'Registro externo (%TEMP%): Valid=false (confinado)' ([string]$govExtView.Error)
    Assert-That (([string]$govExtView.Error -match 'fora de evidence')) 'Registro externo: erro cita confinamento' ([string]$govExtView.Error)
    $evalGovExt = Invoke-CapabilityDeferred -RepoRoot $repo -FlagsPath $flagsOn -ActivationRecordPath $govExternal
    Assert-That ([string]$evalGovExt.decision -ceq 'drift') 'Flag ligada + registro externo: decision=drift' ([string]$evalGovExt.decision)
    $govExtOrch = @($evalGovExt.orchestration | Where-Object { [string]$_.name -ceq 'router-active-governed' -and (-not [bool]$_.pass) })
    Assert-That ($govExtOrch.Count -eq 1) 'Orquestracao: router-active-governed FALHA sob registro externo' 'Passou indevidamente'

    Write-Fixture -Path $canonGov -Text '{"stage":"stage1","gate_pass":true,"activation_status":"controlled_active","flags":{"capability_router":{"active":true},"skill_routing":{"enabled":true},"mcp_routing":{"enabled":false},"adaptive_ranking":{"enabled":false}}}'
    $govBadView = Get-DeferredGovernedRecordView -ActivationRecordPath $canonGov -RepoRoot $repo
    Assert-That (-not [bool]$govBadView.Valid) 'Registro com skill=true: Valid=false' ([string]$govBadView.Error)
    $evalGovBad = Invoke-CapabilityDeferred -RepoRoot $repo -FlagsPath $flagsOn -ActivationRecordPath $canonGov
    Assert-That ([string]$evalGovBad.decision -ceq 'drift') 'Flag ligada + registro invalido (skill=true): decision=drift' ([string]$evalGovBad.decision)

    Write-Fixture -Path $canonGov -Text '{"stage":"stage0","gate_pass":true,"activation_status":"controlled_active","flags":{"capability_router":{"active":true},"skill_routing":{"enabled":false},"mcp_routing":{"enabled":false},"adaptive_ranking":{"enabled":false}}}'
    Assert-That (-not [bool](Get-DeferredGovernedRecordView -ActivationRecordPath $canonGov -RepoRoot $repo).Valid) 'Registro com stage!=stage1: Valid=false' 'Aceitou indevidamente'
    Write-Fixture -Path $canonGov -Text 'not-json{{{'
    Assert-That (-not [bool](Get-DeferredGovernedRecordView -ActivationRecordPath $canonGov -RepoRoot $repo).Valid) 'Registro corrompido: Valid=false (fail-safe)' 'Aceitou indevidamente'
    if ($canonExisted) { Copy-Item -LiteralPath $govBackup -Destination $canonGov -Force }
    else { if (Test-Path -LiteralPath $canonGov -PathType Leaf) { Remove-Item -LiteralPath $canonGov -Force } }
    Assert-That (-not [bool](Get-DeferredGovernedRecordView -ActivationRecordPath (Join-Path $govDir 'tmp-gov-nao-existe.json') -RepoRoot $repo).Valid) 'Registro inexistente: Valid=false (fail-safe)' 'Aceitou indevidamente'

    $flagsSkill = Join-Path $base 'flags-skill.json'
    Write-FlagsFixture -Path $flagsSkill -Skill $true
    $evalSkill = Invoke-CapabilityDeferred -RepoRoot $repo -FlagsPath $flagsSkill
    Assert-That ([string]$evalSkill.decision -ceq 'drift') 'Fixture skill=true: decision=drift' ([string]$evalSkill.decision)
    Assert-That (((( @($evalSkill.reasons) | ForEach-Object { "$_" }) -join ' | ') -match 'skill_routing.enabled')) 'Fixture skill=true: razao cita skill_routing.enabled' 'Sem razao'

    $flagsAdapt = Join-Path $base 'flags-adapt.json'
    Write-FlagsFixture -Path $flagsAdapt -Adaptive $true
    $evalAdapt = Invoke-CapabilityDeferred -RepoRoot $repo -FlagsPath $flagsAdapt
    Assert-That ([string]$evalAdapt.decision -ceq 'drift') 'Fixture adaptive=true: decision=drift' ([string]$evalAdapt.decision)

    $flagsMcp = Join-Path $base 'flags-mcp.json'
    Write-FlagsFixture -Path $flagsMcp -Mcp $true
    $evalMcp = Invoke-CapabilityDeferred -RepoRoot $repo -FlagsPath $flagsMcp
    Assert-That ([string]$evalMcp.decision -ceq 'drift') 'Fixture mcp=true + spike false: decision=drift' ([string]$evalMcp.decision)
    $joinedMcp = ((@($evalMcp.reasons) | ForEach-Object { "$_" }) -join ' | ')
    Assert-That ($joinedMcp -match 'enforcement_supported=false') 'Fixture mcp=true: razao cita enforcement_supported=false' $joinedMcp

    $spikeTrue = Join-Path $base 'spike-true.json'
    Write-Fixture -Path $spikeTrue -Text '{"enforcement_supported":true}'
    $flagsOff = Join-Path $base 'flags-off.json'
    Write-FlagsFixture -Path $flagsOff
    $evalSpikeTrue = Invoke-CapabilityDeferred -RepoRoot $repo -FlagsPath $flagsOff -SpikePath $spikeTrue
    Assert-That ([string]$evalSpikeTrue.decision -ceq 'drift') 'Fixture spike=true: decision=drift (reavaliar adiados)' ([string]$evalSpikeTrue.decision)

    $cfgExtra = Join-Path $base 'config-extra.json'
    Write-ConfigFixture -Path $cfgExtra -AllowNames (@($expected19) + @('extra-agent'))
    $evalExtra = Invoke-CapabilityDeferred -RepoRoot $repo -FlagsPath $flagsOff -ConfigPath $cfgExtra
    Assert-That ([string]$evalExtra.decision -ceq 'drift') 'Fixture authority com allow extra: decision=drift' ([string]$evalExtra.decision)
    $joinedExtra = ((@($evalExtra.reasons) | ForEach-Object { "$_" }) -join ' | ')
    Assert-That ($joinedExtra -match 'agent.build.permission.task') 'Fixture authority extra: razao cita agent.build.permission.task' $joinedExtra

    $cfgWild = Join-Path $base 'config-wild.json'
    Write-ConfigFixture -Path $cfgWild -AllowNames $expected19 -Wild 'allow'
    $evalWild = Invoke-CapabilityDeferred -RepoRoot $repo -FlagsPath $flagsOff -ConfigPath $cfgWild
    Assert-That ([string]$evalWild.decision -ceq 'drift') 'Fixture authority com *=allow: decision=drift' ([string]$evalWild.decision)

    $cfgAsk = Join-Path $base 'config-ask.json'
    Write-ConfigFixture -Path $cfgAsk -AllowNames $expected19 -Wild 'ask'
    $authAsk = Get-DeferredAuthorityView -ConfigPath $cfgAsk -IsDefaultPath $false
    Assert-That (-not [bool]$authAsk.ExpectedOk) 'Fixture authority com *=ask: ExpectedOk=false (wildcard estrito exige deny)' (('wild=' + [string]$authAsk.Wild))
    $evalAsk = Invoke-CapabilityDeferred -RepoRoot $repo -FlagsPath $flagsOff -ConfigPath $cfgAsk
    Assert-That ([string]$evalAsk.decision -ceq 'drift') 'Fixture authority com *=ask: decision=drift' ([string]$evalAsk.decision)

    $cfgNoWild = Join-Path $base 'config-nowild.json'
    $taskNoWild = [ordered]@{}
    foreach ($n in $expected19) { $taskNoWild[$n] = 'allow' }
    $docNoWild = [ordered]@{ agent = [ordered]@{ build = [ordered]@{ permission = [ordered]@{ task = $taskNoWild } } } }
    Write-Fixture -Path $cfgNoWild -Text ((($docNoWild | ConvertTo-Json -Depth 10) + "`n"))
    $authNoWild = Get-DeferredAuthorityView -ConfigPath $cfgNoWild -IsDefaultPath $false
    Assert-That (-not [bool]$authNoWild.ExpectedOk) 'Fixture authority sem wildcard: ExpectedOk=false (ausencia tambem e drift)' (('wild=' + [string]$authNoWild.Wild))
    $evalNoWild = Invoke-CapabilityDeferred -RepoRoot $repo -FlagsPath $flagsOff -ConfigPath $cfgNoWild
    Assert-That ([string]$evalNoWild.decision -ceq 'drift') 'Fixture authority sem wildcard: decision=drift' ([string]$evalNoWild.decision)

    $cfgExact = Join-Path $base 'config-exact.json'
    Write-ConfigFixture -Path $cfgExact -AllowNames $expected19 -Wild 'deny'
    $authFix = Get-DeferredAuthorityView -ConfigPath $cfgExact -IsDefaultPath $false
    Assert-That ([bool]$authFix.ExpectedOk) 'Fixture authority exata (19+deny): ExpectedOk=true' (('n=' + @($authFix.AllowNames).Count + ' wild=' + [string]$authFix.Wild))
    Assert-That ($null -eq $authFix.HashMatchesKnown) 'Fixture authority: HashMatchesKnown nulo (baseline so no caminho padrao)' ([string]$authFix.HashMatchesKnown)
    $evalExact = Invoke-CapabilityDeferred -RepoRoot $repo -FlagsPath $flagsOff -ConfigPath $cfgExact
    Assert-That ([string]$evalExact.decision -ceq 'ok') 'Fixture authority exata + flags off: decision=ok' ((@($evalExact.reasons) -join ' | '))

    $threw = $false
    $evalBogus = $null
    try {
        $evalBogus = Invoke-CapabilityDeferred -RepoRoot $repo -FlagsPath (Join-Path $base 'nao-existe-flags.json') -PolicyPath (Join-Path $base 'nao-existe-policy.json') -ConfigPath (Join-Path $base 'nao-existe-config.json') -SpikePath (Join-Path $base 'nao-existe-spike.json')
    } catch { $threw = $true }
    Assert-That (-not $threw) 'Caminhos inexistentes: nunca lanca' 'Lancou excecao'
    if (-not $threw) {
        Assert-That ([string]$evalBogus.decision -ceq 'drift') 'Caminhos inexistentes: decision=drift (fail-safe)' ([string]$evalBogus.decision)
        Assert-That ((@($evalBogus.reasons).Count -gt 0)) 'Caminhos inexistentes: razoes presentes' 'Sem razoes'
    }

    $threw2 = $false
    try { $null = Get-DeferredArtifactView -RepoRoot (Join-Path $base 'repo-inexistente') } catch { $threw2 = $true }
    Assert-That (-not $threw2) 'Artifact scan em repo inexistente: nunca lanca' 'Lancou excecao'

    $threw3 = $false
    try { $null = Get-DeferredAuthorityView -ConfigPath (Join-Path $base 'cfg-inexistente.json') -IsDefaultPath $false } catch { $threw3 = $true }
    Assert-That (-not $threw3) 'Authority view com config inexistente: nunca lanca' 'Lancou excecao'
}
finally {
    try {
        foreach ($gf in @($govNonCanon)) {
            if ((-not [string]::IsNullOrWhiteSpace($gf)) -and (Test-Path -LiteralPath $gf -PathType Leaf)) {
                Remove-Item -LiteralPath $gf -Force -ErrorAction SilentlyContinue
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($canonGov)) {
            if ($canonExisted -and (-not [string]::IsNullOrWhiteSpace($govBackup)) -and (Test-Path -LiteralPath $govBackup -PathType Leaf)) {
                Copy-Item -LiteralPath $govBackup -Destination $canonGov -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $govBackup -Force -ErrorAction SilentlyContinue
            }
            elseif (-not $canonExisted) {
                if (Test-Path -LiteralPath $canonGov -PathType Leaf) { Remove-Item -LiteralPath $canonGov -Force -ErrorAction SilentlyContinue }
                if ((-not [string]::IsNullOrWhiteSpace($govBackup)) -and (Test-Path -LiteralPath $govBackup -PathType Leaf)) { Remove-Item -LiteralPath $govBackup -Force -ErrorAction SilentlyContinue }
            }
        }
        if ($realCanonHiddenLib -and (-not [string]::IsNullOrWhiteSpace($hiddenGovLib)) -and (Test-Path -LiteralPath $hiddenGovLib -PathType Leaf) -and (-not [string]::IsNullOrWhiteSpace($canonGov))) {
            Move-Item -LiteralPath $hiddenGovLib -Destination $canonGov -Force -ErrorAction SilentlyContinue
        }
        if ($realCanonHiddenLib -and (-not [string]::IsNullOrWhiteSpace($canonGov)) -and (Test-Path -LiteralPath $canonGov -PathType Leaf)) {
            $hRestored = (Get-FileHash -LiteralPath $canonGov -Algorithm SHA256).Hash
            Assert-That ($hRestored -ceq $canonHashBeforeLib) 'Restore: canonico byte-identico ao original' 'Divergiu'
        }
    } catch { }
    try { if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
}

Write-Host "TEST RESULTS: $passed / $total passed"
if ($passed -ne $total) { exit 1 }
exit 0
