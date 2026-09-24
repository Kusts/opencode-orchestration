<#!
.SYNOPSIS
    Amostra controlada da bridge shadow (Phase 9). Offline e advisory.
.DESCRIPTION
    Roda a bridge shadow-route.ps1 sobre uma amostra controlada com 15
    categorias (trivial/direct, ambiguous requirements, architecture,
    engineering feasibility, product UX, skeptic/high-risk plan, frontend,
    backend, database, research, security-sensitive, debugging, mixed-domain,
    fallback/degraded e no-baseline), cada uma com current_route deterministico
    (baseline) e task_id. O caso fallback/degraded (SHADOW-014) injeta um
    registry STALE de verdade (copia do registry real com computed_at de
    10 dias atras) e espera status degraded/failed com fallback_used=true e
    comparison NOT_COMPARABLE. fallback_success (Sec 28) e a fracao de
    fallbacks seguros (status degraded/failed/timeout, sem excecao) sobre
    fallbacks usados: o caso degradado e sucesso (100%). Escreve evidence/v3/shadow/report.json e imprime um
    resumo humano com as metricas: shadow_queries_total/success/failure/
    timeout/degraded, equal/v3_better/v3_worse/unclear/not_comparable,
    no_delegation_rate, router_latency_p50/p95, fallback_success,
    permission_violations e authority_changes.

    OFFLINE por construcao: zero chamadas de rede, nao instrui o Planner,
    nao ativa routing nem authority. Guard: se as flags pedirem roteamento
    ativo (capability_router.active, skill_routing.enabled ou
    mcp_routing.enabled), recusa com exit 2 sem escrever nada.     Escrita
    confinada: -ReportPath so em evidence/v3/shadow e -TelemetryPath so em
    cache/v3/telemetry (traversal ou outro destino recusa com exit 2). Nunca
    altera opencode.json, agentes, adapters, flags ou policy; apenas report
    (+ telemetria via bridge, fail-closed). Opt-in -CanonicalPath (mesmo dir
    do report) grava a projecao canonica por caso sem mudar o default.

    Saida: exit 0 (advisory; falhas shadow viram metricas, nao erro de uso),
    exit 2 em uso/guard. PowerShell 5.1 compativel. ASCII-only de proposito.
#>
[CmdletBinding()]
param(
    [string]$ReportPath,
    [string]$TelemetryPath,
    [string]$FlagsPath,
    [string]$RegistryPath,
    [string]$PolicyPath,
    [string]$ConfigPath,
    [string]$CanonicalPath,
    [int]$TimeoutSeconds = 20
)

$ErrorActionPreference = 'Stop'

$v3root = $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $v3root)

function Write-SampleError {
    param([string]$Text)
    [Console]::Error.WriteLine($Text)
}

function Test-SampleConfined {
    [CmdletBinding()]
    param([string]$Path, [string]$AllowedDir, [string]$Repo)
    try {
        $full = ''
        if ([IO.Path]::IsPathRooted($Path)) { $full = [IO.Path]::GetFullPath($Path) }
        else { $full = [IO.Path]::GetFullPath((Join-Path $Repo $Path)) }
        $base = [IO.Path]::GetFullPath($AllowedDir)
        $sep = $base.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if ($full.StartsWith($sep, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    catch { }
    return $false
}

function Test-SamplePathHasReparsePoint {
    <#
    .SYNOPSIS
        True se o caminho ou QUALQUER ancestor existente for reparse
        point/junction. Replica Test-AuthorityPathHasReparsePoint
        (CapabilityAuthority.ps1): ReparsePoint attribute OR LinkType
        diferente de HardLink. HardLink NAO e reparse (permitido).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $current = $null
    try { $current = [IO.Path]::GetFullPath($Path) } catch { $current = $Path }
    $guard = 0
    while (-not [string]::IsNullOrWhiteSpace($current) -and $guard -lt 128) {
        $guard++
        if (Test-Path -LiteralPath $current) {
            try {
                $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
                try {
                    $linkType = [string]$item.LinkType
                    if ($item.PSObject.Properties['LinkType'] -and -not [string]::IsNullOrWhiteSpace($linkType) -and $linkType -ine 'HardLink') { return $true }
                } catch { }
            } catch { }
        }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $current) { break }
        $current = $parent
    }
    return $false
}

function Get-SampleFullPath {
    param([string]$Path, [string]$Repo)
    try {
        if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
        return [IO.Path]::GetFullPath((Join-Path $Repo $Path))
    }
    catch { return $Path }
}

function Read-SampleJson {
    param([string]$Path)
    $text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))
    return ($text | ConvertFrom-Json)
}

function Test-SampleFlagsAskActive {
    # capability_router.active=true (roteamento governado Stage 1) NAO e
    # recusado: a amostragem shadow continua observando. Apenas skill_routing/
    # mcp_routing (sem executor) recusam.
    param($Flags)
    if ($null -eq $Flags) { return $false }
    try {
        if ($null -ne $Flags.skill_routing -and $null -ne $Flags.skill_routing.enabled) {
            if ([bool]$Flags.skill_routing.enabled) { return $true }
        }
    }
    catch { }
    try {
        if ($null -ne $Flags.mcp_routing -and $null -ne $Flags.mcp_routing.enabled) {
            if ([bool]$Flags.mcp_routing.enabled) { return $true }
        }
    }
    catch { }
    return $false
}

function Get-SampleFileHash {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'MISSING' }
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
    catch { return 'UNREADABLE' }
}

function Get-SamplePercentile {
    param([int[]]$Sorted, [double]$P)
    if ($Sorted.Count -eq 0) { return 0 }
    $rank = [Math]::Ceiling($P * $Sorted.Count) - 1
    if ($rank -lt 0) { $rank = 0 }
    if ($rank -ge $Sorted.Count) { $rank = $Sorted.Count - 1 }
    return [int]$Sorted[$rank]
}

function Write-SampleFixture {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $lf = ($Text -replace "`r`n", "`n" -replace "`r", "`n")
    [IO.File]::WriteAllText($Path, $lf, [Text.UTF8Encoding]::new($false))
}

$report = $ReportPath
if ([string]::IsNullOrWhiteSpace($report)) { $report = Join-Path $repoRoot 'evidence\v3\shadow\report.json' }
$flagsFile = $FlagsPath
if ([string]::IsNullOrWhiteSpace($flagsFile)) { $flagsFile = Join-Path $repoRoot 'source\registry\capability-flags.json' }
$policyFile = $PolicyPath
if ([string]::IsNullOrWhiteSpace($policyFile)) { $policyFile = Join-Path $repoRoot 'source\registry\capability-policy.json' }
$adapterFile = Join-Path $repoRoot 'source\adapters\opencode.md'
$liveConfig = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
$bridge = Join-Path $v3root 'shadow-route.ps1'

$allowedReportDir = Join-Path $repoRoot 'evidence\v3\shadow'
$allowedTelemetryDir = Join-Path $repoRoot 'cache\v3\telemetry'
if (-not (Test-SampleConfined -Path $report -AllowedDir $allowedReportDir -Repo $repoRoot)) {
    Write-SampleError ("shadow-sample.ps1: -ReportPath fora de evidence\v3\shadow (negado): {0}" -f $report)
    exit 2
}
if (Test-SamplePathHasReparsePoint -Path (Get-SampleFullPath -Path $report -Repo $repoRoot)) {
    Write-SampleError ("shadow-sample.ps1: -ReportPath com reparse point/junction em ancestor (negado): {0}" -f $report)
    exit 2
}
if (-not [string]::IsNullOrWhiteSpace($TelemetryPath)) {
    if (-not (Test-SampleConfined -Path $TelemetryPath -AllowedDir $allowedTelemetryDir -Repo $repoRoot)) {
        Write-SampleError ("shadow-sample.ps1: -TelemetryPath fora de cache\v3\telemetry (negado): {0}" -f $TelemetryPath)
        exit 2
    }
    if (Test-SamplePathHasReparsePoint -Path (Get-SampleFullPath -Path $TelemetryPath -Repo $repoRoot)) {
        Write-SampleError ("shadow-sample.ps1: -TelemetryPath com reparse point/junction em ancestor (negado): {0}" -f $TelemetryPath)
        exit 2
    }
}
if (-not [string]::IsNullOrWhiteSpace($CanonicalPath)) {
    if (-not (Test-SampleConfined -Path $CanonicalPath -AllowedDir $allowedReportDir -Repo $repoRoot)) {
        Write-SampleError ("shadow-sample.ps1: -CanonicalPath fora de evidence\v3\shadow (negado): {0}" -f $CanonicalPath)
        exit 2
    }
    if (Test-SamplePathHasReparsePoint -Path (Get-SampleFullPath -Path $CanonicalPath -Repo $repoRoot)) {
        Write-SampleError ("shadow-sample.ps1: -CanonicalPath com reparse point/junction em ancestor (negado): {0}" -f $CanonicalPath)
        exit 2
    }
}
if ($TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 60) {
    Write-SampleError 'shadow-sample.ps1: -TimeoutSeconds deve estar entre 1 e 60.'
    exit 2
}
if (-not (Test-Path -LiteralPath $bridge -PathType Leaf)) {
    Write-SampleError ("shadow-sample.ps1: bridge nao encontrada: {0}" -f $bridge)
    exit 2
}

$flags = $null
if (Test-Path -LiteralPath $flagsFile -PathType Leaf) {
    try { $flags = Read-SampleJson -Path $flagsFile }
    catch { $flags = $null }
}
if (Test-SampleFlagsAskActive -Flags $flags) {
    Write-SampleError 'shadow-sample.ps1 e OFFLINE/advisory: flags pedem roteamento nao suportado (skill_routing.enabled|mcp_routing.enabled); recusando com exit 2 sem escrever nada.'
    exit 2
}

$authBefore = @{
    flags   = (Get-SampleFileHash -Path $flagsFile)
    policy  = (Get-SampleFileHash -Path $policyFile)
    adapter = (Get-SampleFileHash -Path $adapterFile)
    live    = (Get-SampleFileHash -Path $liveConfig)
}

$cases = @(
    @{ task_id = 'SHADOW-001'; category = 'trivial-direct'; objective = 'corrigir typo em texto de ajuda'; task_type = 'trivial'; domain_hints = @('general'); risk = 'low'; read_write_mode = 'read'; current_route = @{ agent = 'build'; skills = @() }; expected_agent = 'build' },
    @{ task_id = 'SHADOW-002'; category = 'ambiguous-requirements'; objective = 'ajudar com requisitos vagos do projeto'; task_type = 'analysis'; domain_hints = @('general'); risk = 'low'; read_write_mode = 'read'; current_route = @{ agent = 'coder'; skills = @() }; expected_agent = '' },
    @{ task_id = 'SHADOW-003'; category = 'architecture'; objective = 'definir fronteiras entre modulos e protocolo'; task_type = 'architecture'; domain_hints = @('architecture'); risk = 'high'; read_write_mode = 'read'; current_route = @{ agent = 'coder'; skills = @() }; expected_agent = 'architect' },
    @{ task_id = 'SHADOW-004'; category = 'engineering-feasibility'; objective = 'avaliar viabilidade de integracao com riscos'; task_type = 'analysis'; domain_hints = @('backend'); risk = 'medium'; read_write_mode = 'read'; current_route = @{ agent = 'coder'; skills = @() }; expected_agent = '' },
    @{ task_id = 'SHADOW-005'; category = 'product-ux'; objective = 'melhorar jornada de acessibilidade da interface'; task_type = 'implementation'; domain_hints = @('ux'); risk = 'medium'; read_write_mode = 'write'; current_route = @{ agent = 'coder'; skills = @() }; expected_agent = 'frontend-engineer' },
    @{ task_id = 'SHADOW-006'; category = 'skeptic-high-risk-plan'; objective = 'desafiar premissas do plano de alto risco'; task_type = 'review'; domain_hints = @('general'); risk = 'high'; read_write_mode = 'read'; current_route = @{ agent = 'reviewer'; skills = @() }; expected_agent = '' },
    @{ task_id = 'SHADOW-007'; category = 'frontend'; objective = 'implementar componente de interface da jornada'; task_type = 'implementation'; domain_hints = @('frontend'); risk = 'medium'; read_write_mode = 'write'; current_route = @{ agent = 'coder'; skills = @() }; expected_agent = 'frontend-engineer' },
    @{ task_id = 'SHADOW-008'; category = 'backend'; objective = 'implementar endpoint de API do servico'; task_type = 'implementation'; domain_hints = @('backend'); risk = 'medium'; read_write_mode = 'write'; current_route = @{ agent = 'backend-engineer'; skills = @() }; expected_agent = 'backend-engineer' },
    @{ task_id = 'SHADOW-009'; category = 'database'; objective = 'modelar schema sql e leitura do banco'; task_type = 'implementation'; domain_hints = @('database'); risk = 'medium'; read_write_mode = 'write'; current_route = @{ agent = 'coder'; skills = @() }; expected_agent = 'database-engineer' },
    @{ task_id = 'SHADOW-010'; category = 'research'; objective = 'pesquisar documentacao atual sobre o tema'; task_type = 'research'; domain_hints = @('docs'); risk = 'low'; read_write_mode = 'read'; current_route = @{ agent = 'coder'; skills = @() }; expected_agent = 'researcher' },
    @{ task_id = 'SHADOW-011'; category = 'security-sensitive'; objective = 'revisar permissoes de acesso e segredos'; task_type = 'review'; domain_hints = @('security'); risk = 'high'; read_write_mode = 'read'; current_route = @{ agent = 'reviewer'; skills = @() }; expected_agent = 'security-reviewer' },
    @{ task_id = 'SHADOW-012'; category = 'debugging'; objective = 'investigar stacktrace intermitente do teste'; task_type = 'debug'; domain_hints = @('general'); risk = 'medium'; read_write_mode = 'read'; current_route = @{ agent = 'coder'; skills = @() }; expected_agent = 'debugger' },
    @{ task_id = 'SHADOW-013'; category = 'mixed-domain'; objective = 'implementar API com leitura do banco e deploy'; task_type = 'implementation'; domain_hints = @('backend', 'database', 'infra'); risk = 'medium'; read_write_mode = 'write'; current_route = @{ agent = 'backend-engineer'; skills = @() }; expected_agent = '' },
    @{ task_id = 'SHADOW-014'; category = 'fallback-degraded'; objective = 'implementar leitura do banco sob registry degradado'; task_type = 'implementation'; domain_hints = @('database'); risk = 'medium'; read_write_mode = 'write'; current_route = @{ agent = 'database-engineer'; skills = @() }; expected_agent = 'database-engineer' },
    @{ task_id = 'SHADOW-015'; category = 'no-baseline'; objective = 'explorar codebase sem rota atual definida'; task_type = 'exploration'; domain_hints = @('general'); risk = 'low'; read_write_mode = 'read'; current_route = $null; expected_agent = '' }
)

$workDir = Join-Path ([IO.Path]::GetTempPath()) ('v3-shadowsample-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
$results = @()

function New-SampleStaleRegistry {
    param([string]$OutPath, [string]$SourcePath, [string]$FallbackRepoRoot)
    $src = $SourcePath
    if ([string]::IsNullOrWhiteSpace($src)) { $src = Join-Path $FallbackRepoRoot 'cache\v3\capability-registry.json' }
    $old = ([DateTimeOffset]::UtcNow.AddDays(-10)).ToString('o')
    try {
        if (Test-Path -LiteralPath $src -PathType Leaf) {
            $text = [IO.File]::ReadAllText($src, [Text.UTF8Encoding]::new($false))
            $doc = ($text | ConvertFrom-Json)
            if ($null -ne $doc -and $null -ne $doc.registry -and $null -ne $doc.registry.freshness) {
                $doc.registry.freshness.computed_at = $old
                Write-SampleFixture -Path $OutPath -Text ((($doc | ConvertTo-Json -Depth 20) + "`n"))
                return $true
            }
        }
    }
    catch { }
    try {
        $now = ([DateTimeOffset]::UtcNow.ToString('o'))
        $min = [ordered]@{
            schema_version = 1
            registry = [ordered]@{
                generated_at = $now
                runtime = [ordered]@{ name = 'opencode'; version = '9.9.9-test' }
                freshness = [ordered]@{ source_fingerprint = 'sha256:fixture'; runtime_version = '9.9.9-test'; computed_at = $old; age_seconds = 864000 }
                logical_hash = 'sha256:stale-fixture'
            }
            counts = [ordered]@{ agent = 0; skill = 0; mcp = 0; invalid = 0; total = 0 }
            capabilities = @()
        }
        Write-SampleFixture -Path $OutPath -Text ((($min | ConvertTo-Json -Depth 10) + "`n"))
        return $true
    }
    catch { return $false }
}

$staleFixture = Join-Path $workDir 'stale-registry.json'
$staleOk = New-SampleStaleRegistry -OutPath $staleFixture -SourcePath $RegistryPath -FallbackRepoRoot $repoRoot
try {
    foreach ($c in $cases) {
        $taskDoc = [ordered]@{
            task_id          = [string]$c.task_id
            objective        = [string]$c.objective
            task_type        = [string]$c.task_type
            domain_hints     = @($c.domain_hints)
            risk             = [string]$c.risk
            read_write_mode  = [string]$c.read_write_mode
            constraints      = @()
        }
        if ($null -ne $c.current_route) {
            $taskDoc['current_route'] = [ordered]@{
                agent  = [string]$c.current_route.agent
                skills = @($c.current_route.skills)
            }
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$c.expected_agent)) {
            $taskDoc['expected_agent'] = [string]$c.expected_agent
        }
        $taskFile = Join-Path $workDir ([string]$c.task_id + '.json')
        Write-SampleFixture -Path $taskFile -Text (($taskDoc | ConvertTo-Json -Depth 6) + "`n")
        $argList = @('-NoProfile', '-File', ("`"{0}`"" -f $bridge), '-TaskFile', ("`"{0}`"" -f $taskFile), '-TimeoutSeconds', ([string]$TimeoutSeconds), '-AllowRepeat')
        $effectiveRegistry = $RegistryPath
        if (([string]$c.category -ceq 'fallback-degraded') -and $staleOk) { $effectiveRegistry = $staleFixture }
        if (-not [string]::IsNullOrWhiteSpace($effectiveRegistry)) { $argList += @('-RegistryPath', ("`"{0}`"" -f $effectiveRegistry)) }
        if (-not [string]::IsNullOrWhiteSpace($PolicyPath)) { $argList += @('-PolicyPath', ("`"{0}`"" -f $PolicyPath)) }
        if (-not [string]::IsNullOrWhiteSpace($FlagsPath)) { $argList += @('-FlagsPath', ("`"{0}`"" -f $FlagsPath)) }
        if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { $argList += @('-ConfigPath', ("`"{0}`"" -f $ConfigPath)) }
        if (-not [string]::IsNullOrWhiteSpace($TelemetryPath)) { $argList += @('-TelemetryPath', ("`"{0}`"" -f $TelemetryPath)) }
        else {
            $defaultTel = Join-Path $repoRoot ('cache\v3\telemetry\live-shadow-' + ([DateTimeOffset]::UtcNow.ToString('yyyyMMdd')) + '.jsonl')
            $argList += @('-TelemetryPath', ("`"{0}`"" -f $defaultTel))
        }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell'
        $psi.Arguments = ($argList -join ' ')
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        $done = $proc.WaitForExit(65000)
        $stdout = ''
        try { $stdout = $proc.StandardOutput.ReadToEnd() } catch { $stdout = '' }
        $code = -1
        try { $code = [int]$proc.ExitCode } catch { $code = -1 }
        try { $proc.Close() } catch { }
        $parsed = $null
        try { $parsed = ([string]$stdout | ConvertFrom-Json) } catch { $parsed = $null }
        if ($null -eq $parsed) {
            $parsed = [PSCustomObject]@{
                task_id = [string]$c.task_id; proposed_agent = $null; proposed_skills = @()
                proposed_capability_classes = @(); filters_applied = @(); reason = 'sample: bridge sem resposta parseavel'
                confidence_class = 'low'; fallback_used = $false; warnings = @('sample: resposta invalida')
                comparison = 'UNCLEAR'; status = 'failed'; router_latency_ms = 0; bridge_overhead_ms = 0
            }
        }
        $curAgent = ''
        if ($null -ne $c.current_route) { $curAgent = [string]$c.current_route.agent }
        $propAgent = $null
        try { if ($null -ne $parsed.proposed_agent -and -not [string]::IsNullOrWhiteSpace([string]$parsed.proposed_agent)) { $propAgent = [string]$parsed.proposed_agent } } catch { $propAgent = $null }
        $results += [PSCustomObject]@{
            task_id         = [string]$c.task_id
            id              = [string]$c.task_id
            category        = [string]$c.category
            current_agent   = $curAgent
            proposed_agent  = $propAgent
            comparison      = [string]$parsed.comparison
            status          = [string]$parsed.status
            degraded        = ([string]$parsed.status -ceq 'degraded')
            fallback_used   = [bool]$parsed.fallback_used
            router_latency_ms = [int]$parsed.router_latency_ms
            warnings        = @($parsed.warnings)
        }
    }
}
finally {
    if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue }
}

$allowlist = @()
try {
    . (Join-Path $v3root 'lib\CapabilityRouter.ps1')
    $cfgForAllow = $ConfigPath
    if ([string]::IsNullOrWhiteSpace($cfgForAllow)) { $cfgForAllow = Join-Path $env:USERPROFILE '.config\opencode\opencode.json' }
    $allowlist = @(Get-RouterAllowlist -ConfigPath $cfgForAllow)
}
catch { $allowlist = @() }

$total = $results.Count
$success = @($results | Where-Object { $_.status -ceq 'success' }).Count
$failure = @($results | Where-Object { $_.status -ceq 'failed' }).Count
$timeout = @($results | Where-Object { $_.status -ceq 'timeout' }).Count
$disabled = @($results | Where-Object { $_.status -ceq 'disabled' }).Count
$degraded = @($results | Where-Object { $_.status -ceq 'degraded' }).Count
$eq = @($results | Where-Object { $_.comparison -ceq 'EQUAL' }).Count
$better = @($results | Where-Object { $_.comparison -ceq 'V3_BETTER' }).Count
$worse = @($results | Where-Object { $_.comparison -ceq 'V3_WORSE' }).Count
$unclear = @($results | Where-Object { $_.comparison -ceq 'UNCLEAR' }).Count
$notcomp = @($results | Where-Object { $_.comparison -ceq 'NOT_COMPARABLE' }).Count
$noDeleg = 0
foreach ($r in $results) {
    $pa = ([string]$r.proposed_agent).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($pa) -or ($pa -ceq 'build') -or ($pa -ceq 'direct')) { $noDeleg++ }
}
$noDelegRate = 0.0
if ($total -gt 0) { $noDelegRate = [Math]::Round(([double]$noDeleg / [double]$total), 4) }
$latSorted = @($results | ForEach-Object { [int]$_.router_latency_ms } | Sort-Object)
$p50 = Get-SamplePercentile -Sorted $latSorted -P 0.5
$p95 = Get-SamplePercentile -Sorted $latSorted -P 0.95
# Sec 28: fallback_success e a FRACAO de fallbacks seguros sobre fallbacks usados.
# Seguro = fallback_used=true e a bridge retornou sem excecao/sem bloquear com
# status em {degraded, failed, timeout} (o caso degradado e sucesso de fallback).
# Sem nenhum fallback usado, define-se 1.0 (nada falhou; advisory).
$fallbackUsed = @($results | Where-Object { [bool]$_.fallback_used }).Count
$fallbackSafe = @($results | Where-Object { ([bool]$_.fallback_used) -and (@('degraded', 'failed', 'timeout') -ccontains [string]$_.status) }).Count
$fallbackSuccess = 1.0
if ($fallbackUsed -gt 0) { $fallbackSuccess = [Math]::Round(([double]$fallbackSafe / [double]$fallbackUsed), 4) }
$permViol = 0
foreach ($r in $results) {
    if ($r.status -cne 'success') { continue }
    $pa = [string]$r.proposed_agent
    if ([string]::IsNullOrWhiteSpace($pa)) { continue }
    if (([string]$pa).Trim().ToLowerInvariant() -ceq 'build') { continue }
    if ($allowlist -cnotcontains $pa) { $permViol++ }
}
$authAfter = @{
    flags   = (Get-SampleFileHash -Path $flagsFile)
    policy  = (Get-SampleFileHash -Path $policyFile)
    adapter = (Get-SampleFileHash -Path $adapterFile)
    live    = (Get-SampleFileHash -Path $liveConfig)
}
$authChanges = 0
foreach ($k in @('flags', 'policy', 'adapter', 'live')) {
    if ($authAfter[$k] -cne $authBefore[$k]) { $authChanges++ }
}

$generatedAt = ([DateTimeOffset]::UtcNow.ToString('o'))
$reportDoc = [ordered]@{
    generated_at = $generatedAt
    offline      = $true
    harness      = 'shadow live OFFLINE (advisory; sem ativar routing nem authority)'
    sample       = [ordered]@{ cases = $total; categories = @($results | ForEach-Object { [string]$_.category }) }
    metrics      = [ordered]@{
        shadow_queries_total = $total
        shadow_success       = $success
        shadow_failure       = $failure
        shadow_timeout       = $timeout
        shadow_degraded      = $degraded
        shadow_disabled      = $disabled
        equal                = $eq
        v3_better            = $better
        v3_worse             = $worse
        unclear              = $unclear
        not_comparable       = $notcomp
        no_delegation        = $noDeleg
        no_delegation_rate   = $noDelegRate
        router_latency_p50   = $p50
        router_latency_p95   = $p95
        fallback_used        = $fallbackUsed
        fallback_success     = $fallbackSuccess
        permission_violations = $permViol
        authority_changes    = $authChanges
    }
    results = @($results)
}
$repParent = Split-Path -Parent $report
if (-not [string]::IsNullOrWhiteSpace($repParent)) { New-Item -ItemType Directory -Path $repParent -Force | Out-Null }
$repJson = (($reportDoc | ConvertTo-Json -Depth 10) + "`n")
$repJson = ($repJson -replace "`r`n", "`n" -replace "`r", "`n")
[IO.File]::WriteAllText($report, $repJson, [Text.UTF8Encoding]::new($false))

# Projecao canonica deterministica por caso (exclui generated_at e latencias).
# Opt-in via -CanonicalPath (confinado a evidence/v3/shadow); default inalterado.
if (-not [string]::IsNullOrWhiteSpace($CanonicalPath)) {
    $canonFull = $CanonicalPath
    try {
        if ([IO.Path]::IsPathRooted($CanonicalPath)) { $canonFull = [IO.Path]::GetFullPath($CanonicalPath) }
        else { $canonFull = [IO.Path]::GetFullPath((Join-Path $repoRoot $CanonicalPath)) }
    }
    catch { $canonFull = $CanonicalPath }
    $canonParent = Split-Path -Parent $canonFull
    if (-not [string]::IsNullOrWhiteSpace($canonParent)) { New-Item -ItemType Directory -Path $canonParent -Force | Out-Null }
    $projection = @($results | Sort-Object { [string]$_.task_id } | ForEach-Object {
        $pa = $null
        try { if ($null -ne $_.proposed_agent -and -not [string]::IsNullOrWhiteSpace([string]$_.proposed_agent)) { $pa = [string]$_.proposed_agent } } catch { $pa = $null }
        [ordered]@{
            id = [string]$_.task_id
            status = [string]$_.status
            proposed_agent = $pa
            comparison = [string]$_.comparison
            fallback_used = [bool]$_.fallback_used
            degraded = [bool]$_.degraded
        }
    })
    $canonDoc = [ordered]@{ generated_at = $generatedAt; projection = @($projection) }
    $canonJson = ((($canonDoc | ConvertTo-Json -Depth 10) + "`n") -replace "`r`n", "`n" -replace "`r", "`n")
    [IO.File]::WriteAllText($canonFull, $canonJson, [Text.UTF8Encoding]::new($false))
}

Write-Output '=== V3 SHADOW SAMPLE (OFFLINE) ==='
Write-Output ('casos: {0} | gerado em: {1}' -f $total, $generatedAt)
Write-Output ('shadow: total={0} success={1} failure={2} timeout={3} degraded={4} disabled={5}' -f $total, $success, $failure, $timeout, $degraded, $disabled)
Write-Output ('comparison: equal={0} v3_better={1} v3_worse={2} unclear={3} not_comparable={4}' -f $eq, $better, $worse, $unclear, $notcomp)
Write-Output ('no_delegation: {0}/{1} (rate {2}) | fallback_used={3} fallback_success={4}' -f $noDeleg, $total, $noDelegRate, $fallbackUsed, $fallbackSuccess)
Write-Output ('router_latency_ms: p50={0} p95={1} | permission_violations={2} authority_changes={3}' -f $p50, $p95, $permViol, $authChanges)
Write-Output ('report: ' + $report)
exit 0
