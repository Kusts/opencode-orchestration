<#!
.SYNOPSIS
    V3 MCP capability routing lib: advisory match agente -> MCPs (Phase 11).
.DESCRIPTION
    Biblioteca dot-sourceable (sem execucao ao carregar). Implementa o roteamento
    de MCPs por capability classes em 8 estagios explicitos e auditaveis:

      server_discovery, capability_discovery, required_capability,
      router_match, permission_hard_filter, tool_exposure,
      runtime_enforcement, execution.

    Regras duras (contrato Phase 11):

      - Kill switch ESTRITO: so boolean $true em mcp_routing.enabled
        habilita. Qualquer outro tipo ou valor => status disabled, mcps
        vazios, exit 0 no CLI. Default FALSE (roteamento desligado).
      - Hard filter OBRIGATORIO ANTES do scoring: exclui MCP com status
        missing/invalid/disabled; visibility em deny_rules.visibility da
        policy (hidden/internal/experimental); capability em forbidden do
        agente; trust
        (resolvido EXCLUSIVAMENTE da policy) fora de
        {TRUSTED_LOCAL, APPROVED} (case-insensitive) para execucao;
        trust unknown sob default-deny; classificacao critica em modo
        write. Permissao vence relevancia, sempre.
      - Matching por CAPABILITY CLASSES (nunca por nome de MCP): preferred
        do agente (capability_profile.preferred) intersectado com as
        capabilities estruturadas do MCP. Renomear um MCP nao muda o match.
      - Trust/risco EXCLUSIVAMENTE da policy (trust_rules, risk_policy,
        mcp_routing): description/tags/metadata do MCP sao DADOS e jamais
        elevam trust, jamais alteram policy/permissao.
      - Tool exposure/execution NAO habilitados: o resultado e ADVISORY.
        tool_exposure sai sempre {exposed_tools: [], deferred: true};
        runtime_enforcement sai {enforced: false, owner: 'runtime'};
        execution sai {executed: false}. Enforcement pertence ao runtime
        (ver evidence/v3/mcp/enforcement-spike.json).
      - Fallback: sem MCP valido => mcps vazios, fallback_used true,
        blocked FALSE. Nunca lanca, nunca bloqueia.
      - Read-only: nao executa tool, nao escreve arquivos, nao altera
        flags/policy/config/agentes, nao concede authority.

    PowerShell 5.1 compativel. ASCII-only de proposito.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-McpRouterRepoRoot {
    [CmdletBinding()]
    param([string]$RepoRoot)
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { return $RepoRoot }
    return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
}

function Read-McpRouterUtf8Single {
    <#
    .SYNOPSIS
        Leitura unica de arquivo texto (TOCTOU-aware): um unico ReadAllText.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))
}

function Read-McpRouterJsonDoc {
    <#
    .SYNOPSIS
        Le JSON com limite de tamanho em leitura unica. Retorna
        @{ Ok=[bool]; Doc=...; Error=[string] }. Nunca lanca.
        MaxBytes default 16384; 0 = sem limite (registry derivada).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [int]$MaxBytes = 16384)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return @{ Ok = $false; Doc = $null; Error = 'not-found' }
        }
        $text = Read-McpRouterUtf8Single -Path $Path
        if ($MaxBytes -gt 0 -and $text.Length -gt $MaxBytes) {
            return @{ Ok = $false; Doc = $null; Error = 'too-large' }
        }
        $doc = $null
        try { $doc = $text | ConvertFrom-Json }
        catch { return @{ Ok = $false; Doc = $null; Error = 'invalid-json' } }
        return @{ Ok = $true; Doc = $doc; Error = '' }
    }
    catch { return @{ Ok = $false; Doc = $null; Error = 'unreadable' } }
}

function Read-McpRouterFlags {
    [CmdletBinding()]
    param([string]$FlagsPath, [string]$RepoRoot)
    $resolved = $FlagsPath
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        $resolved = Join-Path (Get-McpRouterRepoRoot -RepoRoot $RepoRoot) 'source\registry\capability-flags.json'
    }
    $r = Read-McpRouterJsonDoc -Path $resolved
    if (-not $r.Ok) { return $null }
    return $r.Doc
}

function Test-McpRouterEnabled {
    <#
    .SYNOPSIS
        Kill switch ESTRITO: so boolean $true em mcp_routing.enabled
        habilita. Qualquer outro tipo/valor => desabilitado.
    #>
    [CmdletBinding()]
    param($Flags)
    if ($null -eq $Flags) { return $false }
    try {
        $node = $null
        if ($Flags -is [System.Collections.IDictionary]) {
            if ($Flags.Contains('mcp_routing')) { $node = $Flags['mcp_routing'] }
        }
        else {
            $p = $Flags.PSObject.Properties | Where-Object { $_.Name -ceq 'mcp_routing' } | Select-Object -First 1
            if ($null -ne $p) { $node = $p.Value }
        }
        if ($null -eq $node) { return $false }
        $value = $null
        if ($node -is [System.Collections.IDictionary]) {
            if ($node.Contains('enabled')) { $value = $node['enabled'] }
        }
        else {
            $p2 = $node.PSObject.Properties | Where-Object { $_.Name -ceq 'enabled' } | Select-Object -First 1
            if ($null -ne $p2) { $value = $p2.Value }
        }
        if ($value -is [bool] -and $value -eq $true) { return $true }
    }
    catch { }
    return $false
}

function Test-McpRouterTaskId {
    [CmdletBinding()]
    param([string]$TaskId)
    if ([string]::IsNullOrWhiteSpace($TaskId)) { return $false }
    $s = ([string]$TaskId).Trim()
    if ($s.Length -gt 64) { return $false }
    return ($s -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')
}

function Test-McpRouterAgentName {
    [CmdletBinding()]
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $s = ([string]$Name).Trim()
    if ($s.Length -gt 64) { return $false }
    return ($s -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')
}

function Test-McpRouterClassSyntax {
    <#
    .SYNOPSIS
        Sintaxe de capability class: segmentos minusculos separados por
        ponto, ex. database.read. Comparacao sempre normalizada (trim +
        lowercase). Nao consulta a policy (sintaxe, nao autoridade).
    #>
    [CmdletBinding()]
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
    $s = ([string]$Id).Trim().ToLowerInvariant()
    if ($s.Length -gt 64) { return $false }
    return ($s -match '^[a-z0-9][a-z0-9_-]*(\.[a-z0-9][a-z0-9_-]*)+$')
}

function ConvertTo-McpRouterStringArray {
    <#
    .SYNOPSIS
        Achata enumeravel em [string[]] plano. Limite defensivo: 100
        itens (trunca, sem lancar).
    #>
    [CmdletBinding()]
    param($Value)
    $out = @()
    if ($null -eq $Value) { return @() }
    $items = @($Value)
    if ($items.Count -eq 1 -and ($items[0] -is [System.Collections.IEnumerable]) -and (-not ($items[0] -is [string]))) {
        try { $items = @($items[0]) } catch { }
    }
    foreach ($v in $items) {
        if ($out.Count -ge 100) { break }
        if ($null -eq $v) { continue }
        if ($v -is [string]) { $out += $v }
        else {
            try { $out += ([string]$v) } catch { }
        }
    }
    return $out
}

function Get-McpRouterRedactedText {
    [CmdletBinding()]
    param([string]$Text)
    $s = [string]$Text
    if ([string]::IsNullOrEmpty($s)) { return '' }
    try {
        return ($s -replace 'Bearer\s+[A-Za-z0-9\-._~+/=]{8,}|sk-[A-Za-z0-9\-]{10,}', '[REDACTED]')
    }
    catch { return $s }
}

function Get-McpRouterNodeProp {
    <#
    .SYNOPSIS
        Leitura tolerante de propriedade (PSObject ou IDictionary).
        Retorna $null quando ausente. Nunca lanca.
    #>
    [CmdletBinding()]
    param($Node, [string]$Name)
    if ($null -eq $Node) { return $null }
    try {
        if ($Node -is [System.Collections.IDictionary]) {
            if ($Node.Contains($Name)) { return $Node[$Name] }
            return $null
        }
        $p = $Node.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1
        if ($null -ne $p) { return $p.Value }
    }
    catch { }
    return $null
}

function Get-McpRouterPolicyView {
    <#
    .SYNOPSIS
        Visao normalizada da policy (SOMENTE policy; nada de metadata de
        MCP). Retorna @{ MaxMcps; TrustAllow; DenyWrite; TrustMap;
        DefaultTrust; RiskMap; Canonical; DenyVisibility }. Nunca lanca.
    #>
    [CmdletBinding()]
    param($Policy)
    $maxMcps = 3
    $trustAllow = @('trusted_local', 'approved')
    $denyWrite = @('critical')
    $denyVis = @('hidden', 'internal', 'experimental')
    $trustMap = @{}
    $defaultTrust = 'untrusted'
    $riskMap = @{}
    $canonical = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    try {
        $sec = Get-McpRouterNodeProp -Node $Policy -Name 'mcp_routing'
        if ($null -ne $sec) {
            $mv = Get-McpRouterNodeProp -Node $sec -Name 'max_mcps'
            try {
                $n = [int]$mv
                if ($n -ge 1 -and $n -le 5) { $maxMcps = $n }
            }
            catch { }
            $ta = Get-McpRouterNodeProp -Node $sec -Name 'execution_trust_allow'
            $tal = @(ConvertTo-McpRouterStringArray -Value $ta)
            if ($tal.Count -gt 0) {
                $norm = @()
                foreach ($t in $tal) {
                    $s = ([string]$t).Trim().ToLowerInvariant()
                    if (-not [string]::IsNullOrWhiteSpace($s)) { $norm += $s }
                }
                if ($norm.Count -gt 0) { $trustAllow = @($norm) }
            }
            $dw = Get-McpRouterNodeProp -Node $sec -Name 'classification_deny_write'
            $dwl = @(ConvertTo-McpRouterStringArray -Value $dw)
            if ($dwl.Count -gt 0) {
                $norm = @()
                foreach ($t in $dwl) {
                    $s = ([string]$t).Trim().ToLowerInvariant()
                    if (-not [string]::IsNullOrWhiteSpace($s)) { $norm += $s }
                }
                if ($norm.Count -gt 0) { $denyWrite = @($norm) }
            }
        }
        $dr = Get-McpRouterNodeProp -Node $Policy -Name 'deny_rules'
        if ($null -ne $dr) {
            $dv = Get-McpRouterNodeProp -Node $dr -Name 'visibility'
            $dvl = @(ConvertTo-McpRouterStringArray -Value $dv)
            if ($dvl.Count -gt 0) {
                $norm = @()
                foreach ($t in $dvl) {
                    $s = ([string]$t).Trim().ToLowerInvariant()
                    if (-not [string]::IsNullOrWhiteSpace($s)) { $norm += $s }
                }
                if ($norm.Count -gt 0) { $denyVis = @($norm) }
            }
        }
        $tr = Get-McpRouterNodeProp -Node $Policy -Name 'trust_rules'
        if ($null -ne $tr) {
            $dflt = Get-McpRouterNodeProp -Node $tr -Name 'default'
            if ($null -ne $dflt -and -not [string]::IsNullOrWhiteSpace([string]$dflt)) {
                $defaultTrust = ([string]$dflt).Trim()
            }
            $mm = Get-McpRouterNodeProp -Node $tr -Name 'mcp'
            if ($null -ne $mm) {
                try {
                    if ($mm -is [System.Collections.IDictionary]) {
                        foreach ($k in @($mm.Keys)) {
                            $trustMap[[string]$k] = $mm[$k]
                        }
                    }
                    else {
                        foreach ($pp in @($mm.PSObject.Properties)) {
                            $trustMap[[string]$pp.Name] = $pp.Value
                        }
                    }
                }
                catch { }
            }
        }
        $rp = Get-McpRouterNodeProp -Node $Policy -Name 'risk_policy'
        if ($null -ne $rp) {
            $cr = Get-McpRouterNodeProp -Node $rp -Name 'capability_risk'
            if ($null -ne $cr) {
                try {
                    if ($cr -is [System.Collections.IDictionary]) {
                        foreach ($k in @($cr.Keys)) {
                            $riskMap[([string]$k).Trim().ToLowerInvariant()] = ([string]$cr[$k]).Trim().ToLowerInvariant()
                        }
                    }
                    else {
                        foreach ($pp in @($cr.PSObject.Properties)) {
                            $riskMap[([string]$pp.Name).Trim().ToLowerInvariant()] = ([string]$pp.Value).Trim().ToLowerInvariant()
                        }
                    }
                }
                catch { }
            }
        }
        $tax = Get-McpRouterNodeProp -Node $Policy -Name 'capability_taxonomy'
        if ($null -ne $tax) {
            $prod = Get-McpRouterNodeProp -Node $tax -Name 'producers'
            if ($null -ne $prod) {
                try {
                    if ($prod -is [System.Collections.IDictionary]) {
                        foreach ($k in @($prod.Keys)) {
                            $canonical.Add(([string]$k).Trim().ToLowerInvariant()) | Out-Null
                        }
                    }
                    else {
                        foreach ($pp in @($prod.PSObject.Properties)) {
                            $canonical.Add(([string]$pp.Name).Trim().ToLowerInvariant()) | Out-Null
                        }
                    }
                }
                catch { }
            }
        }
    }
    catch { }
    return @{
        MaxMcps      = $maxMcps
        TrustAllow   = @($trustAllow)
        DenyWrite    = @($denyWrite)
        DenyVisibility = @($denyVis)
        TrustMap     = $trustMap
        DefaultTrust = $defaultTrust
        RiskMap      = $riskMap
        Canonical    = $canonical
    }
}

function Get-McpRouterTrustFor {
    <#
    .SYNOPSIS
        Trust de um MCP resolvido EXCLUSIVAMENTE da policy
        (trust_rules.mcp por nome curto, case-insensitive; senao
        trust_rules.default; senao 'untrusted'). O campo trust do
        registro e metadata do MCP sao ignorados de proposito.
    #>
    [CmdletBinding()]
    param($PolicyView, [string]$ShortName)
    try {
        $key = ([string]$ShortName).Trim().ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($key)) {
            foreach ($k in @($PolicyView.TrustMap.Keys)) {
                if (([string]$k).Trim().ToLowerInvariant() -ceq $key) {
                    $v = $PolicyView.TrustMap[$k]
                    if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) {
                        return ([string]$v).Trim()
                    }
                }
            }
        }
    }
    catch { }
    return [string]$PolicyView.DefaultTrust
}

function Get-McpRouterRiskFor {
    <#
    .SYNOPSIS
        Risco de uma capability class resolvido EXCLUSIVAMENTE da policy
        (risk_policy.capability_risk; senao 'unknown').
    #>
    [CmdletBinding()]
    param($PolicyView, [string]$Capability)
    try {
        $key = ([string]$Capability).Trim().ToLowerInvariant()
        if ($PolicyView.RiskMap.ContainsKey($key)) { return [string]$PolicyView.RiskMap[$key] }
    }
    catch { }
    return 'unknown'
}

function Read-McpRouterRegistryView {
    <#
    .SYNOPSIS
        Le a registry derivada e monta a visao de roteamento MCP:
        Mcps (@{ Id; Name; Status; Caps; Visibility }) e Agents (nome -> @{
        Preferred; Forbidden }). Le SOMENTE campos estruturados
        (id/type/name/status/capabilities/capability_profile/eligibility.visibility);
        description/tags/metadata/trust/risk do registro NUNCA saem
        daqui (sao dados, nao autoridade). Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$RegistryPath, [string]$RepoRoot)
    $resolved = $RegistryPath
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        $resolved = Join-Path (Get-McpRouterRepoRoot -RepoRoot $RepoRoot) 'cache\v3\capability-registry.json'
    }
    $r = Read-McpRouterJsonDoc -Path $resolved -MaxBytes 0
    if (-not $r.Ok) {
        return @{ Available = $false; Mcps = @(); Agents = @{}; Error = ('registry ' + $r.Error) }
    }
    $mcps = @()
    $agents = @{}
    try {
        $caps = @()
        $doc = $r.Doc
        $rawCaps = Get-McpRouterNodeProp -Node $doc -Name 'capabilities'
        if ($null -ne $rawCaps) { $caps = @($rawCaps) }
        foreach ($c in $caps) {
            try {
                $id = [string](Get-McpRouterNodeProp -Node $c -Name 'id')
                $type = ([string](Get-McpRouterNodeProp -Node $c -Name 'type')).Trim().ToLowerInvariant()
                $name = [string](Get-McpRouterNodeProp -Node $c -Name 'name')
                $status = [string](Get-McpRouterNodeProp -Node $c -Name 'status')
                if ([string]::IsNullOrWhiteSpace($id)) { continue }
                if ($type -ceq 'mcp') {
                    $capList = @()
                    foreach ($v in @(ConvertTo-McpRouterStringArray -Value (Get-McpRouterNodeProp -Node $c -Name 'capabilities'))) {
                        $s = ([string]$v).Trim().ToLowerInvariant()
                        if ((Test-McpRouterClassSyntax -Id $s) -and ($capList -cnotcontains $s)) { $capList += $s }
                    }
                    $vis = ''
                    try {
                        $elig = Get-McpRouterNodeProp -Node $c -Name 'eligibility'
                        if ($null -ne $elig) {
                            $vv = Get-McpRouterNodeProp -Node $elig -Name 'visibility'
                            if ($null -ne $vv) { $vis = ([string]$vv).Trim().ToLowerInvariant() }
                        }
                    }
                    catch { $vis = '' }
                    $mcps += @{ Id = $id.Trim(); Name = $name.Trim(); Status = $status.Trim(); Caps = @($capList); Visibility = $vis }
                }
                elseif ($type -ceq 'agent') {
                    $prof = Get-McpRouterNodeProp -Node $c -Name 'capability_profile'
                    $pref = @()
                    $forb = @()
                    if ($null -ne $prof) {
                        foreach ($v in @(ConvertTo-McpRouterStringArray -Value (Get-McpRouterNodeProp -Node $prof -Name 'preferred'))) {
                            $s = ([string]$v).Trim().ToLowerInvariant()
                            if ((Test-McpRouterClassSyntax -Id $s) -and ($pref -cnotcontains $s)) { $pref += $s }
                        }
                        foreach ($v in @(ConvertTo-McpRouterStringArray -Value (Get-McpRouterNodeProp -Node $prof -Name 'forbidden'))) {
                            $s = ([string]$v).Trim().ToLowerInvariant()
                            if ((Test-McpRouterClassSyntax -Id $s) -and ($forb -cnotcontains $s)) { $forb += $s }
                        }
                    }
                    $key = $name.Trim()
                    if (-not [string]::IsNullOrWhiteSpace($key) -and -not $agents.ContainsKey($key)) {
                        $agents[$key] = @{ Preferred = @($pref); Forbidden = @($forb) }
                    }
                }
            }
            catch { }
        }
    }
    catch { return @{ Available = $false; Mcps = @(); Agents = @{}; Error = 'registry unreadable' } }
    return @{ Available = $true; Mcps = @($mcps); Agents = $agents; Error = '' }
}

function New-McpRouterStagesSkeleton {
    [CmdletBinding()]
    param()
    return [PSCustomObject]@{
        server_discovery     = [PSCustomObject]@{ servers_seen = 0; servers_available = 0; note = '' }
        capability_discovery = [PSCustomObject]@{ mcp_capability_classes = @(); note = '' }
        required_capability  = [PSCustomObject]@{ required = @(); source = ''; unknown_rejected = @(); note = '' }
        router_match         = [PSCustomObject]@{ candidates = @(); note = '' }
        permission_hard_filter = [PSCustomObject]@{ excluded = @(); note = '' }
        tool_exposure        = [PSCustomObject]@{ exposed_tools = @(); deferred = $true; note = '' }
        runtime_enforcement  = [PSCustomObject]@{ enforced = $false; owner = 'runtime'; enforcement_supported = $false; spike = 'evidence/v3/mcp/enforcement-spike.json'; note = '' }
        execution            = [PSCustomObject]@{ executed = $false; tools_executed = @(); note = '' }
    }
}

function New-McpRouterDisabledResult {
    [CmdletBinding()]
    param([string]$TaskId)
    $stages = New-McpRouterStagesSkeleton
    $stages.tool_exposure.note = 'advisory: routing desligado; nenhuma tool exposta'
    $stages.runtime_enforcement.note = 'advisory: enforcement pertence ao runtime; ver evidence/v3/mcp/enforcement-spike.json'
    $stages.execution.note = 'advisory: nenhuma execucao realizada'
    return [PSCustomObject]@{
        router_version = '1'
        task_id        = [string]$TaskId
        agent          = ''
        mcps           = @()
        stages         = $stages
        reason         = 'mcp routing disabled (mcp_routing.enabled != true); advisory sem efeito'
        source         = 'mcp-router'
        fallback_used  = $false
        blocked        = $false
        warnings       = @('mcp routing disabled')
        status         = 'disabled'
    }
}

function New-McpRouterFallbackResult {
    [CmdletBinding()]
    param([string]$TaskId, [string]$Agent, [string]$Reason, [string[]]$Warnings, $Stages)
    if ($null -eq $Warnings -or $Warnings.Count -eq 0) { $Warnings = @('no valid mcp; fallback') }
    if ($null -eq $Stages) { $Stages = New-McpRouterStagesSkeleton }
    return [PSCustomObject]@{
        router_version = '1'
        task_id        = [string]$TaskId
        agent          = [string]$Agent
        mcps           = @()
        stages         = $Stages
        reason         = [string]$Reason
        source         = 'mcp-router'
        fallback_used  = $true
        blocked        = $false
        warnings       = @($Warnings)
        status         = 'fallback'
    }
}

function Invoke-CapabilityMcpRouter {
    <#
    .SYNOPSIS
        Roteamento MCP por capability classes (read-only, advisory, nunca
        bloqueia, nunca executa).
    .DESCRIPTION
        Parametros: TaskFile (contexto minimo + agente selecionado),
        RouteFile (proposta com proposed_agent /
        proposed_mcp_capability_classes), Agent (nome inline),
        RegistryPath, PolicyPath, FlagsPath, RepoRoot, MaxMcpsOverride.
        Nunca lanca: qualquer falha operacional vira disabled (kill
        switch) ou fallback.
    #>
    [CmdletBinding()]
    param(
        [string]$TaskFile,
        [string]$RouteFile,
        [string]$Agent,
        [string]$RegistryPath,
        [string]$PolicyPath,
        [string]$FlagsPath,
        [string]$RepoRoot,
        [int]$MaxMcpsOverride = -1
    )
    try {
        $repo = Get-McpRouterRepoRoot -RepoRoot $RepoRoot
        $flags = Read-McpRouterFlags -FlagsPath $FlagsPath -RepoRoot $repo
        if (-not (Test-McpRouterEnabled -Flags $flags)) {
            $tid = ''
            try {
                if (-not [string]::IsNullOrWhiteSpace($TaskFile)) {
                    $probe = Read-McpRouterJsonDoc -Path $TaskFile
                    if ($probe.Ok) {
                        $pv = Get-McpRouterNodeProp -Node $probe.Doc -Name 'task_id'
                        if ($null -ne $pv) { $tid = ([string]$pv).Trim() }
                    }
                }
            }
            catch { $tid = '' }
            if (-not (Test-McpRouterTaskId -TaskId $tid)) { $tid = '' }
            return (New-McpRouterDisabledResult -TaskId $tid)
        }

        $policy = $null
        $policyOk = $false
        try {
            $resolvedPolicy = $PolicyPath
            if ([string]::IsNullOrWhiteSpace($resolvedPolicy)) {
                $resolvedPolicy = Join-Path $repo 'source\registry\capability-policy.json'
            }
            $pr = Read-McpRouterJsonDoc -Path $resolvedPolicy
            if ($pr.Ok -and ($null -ne $pr.Doc)) { $policy = $pr.Doc; $policyOk = $true }
        }
        catch { $policy = $null; $policyOk = $false }
        $view = Get-McpRouterPolicyView -Policy $policy
        $maxMcps = $view.MaxMcps
        if ($MaxMcpsOverride -ge 1 -and $MaxMcpsOverride -le 5) { $maxMcps = $MaxMcpsOverride }
        if (-not $policyOk) {
            return (New-McpRouterFallbackResult -TaskId '' -Agent '' -Reason 'fallback: policy ausente/corrompida; sem rota MCP' -Warnings @('policy unavailable; fallback') -Stages $null)
        }

        $reg = Read-McpRouterRegistryView -RegistryPath $RegistryPath -RepoRoot $repo
        if (-not $reg.Available) {
            return (New-McpRouterFallbackResult -TaskId '' -Agent '' -Reason ('fallback: ' + $reg.Error) -Warnings @('registry unavailable; fallback') -Stages $null)
        }

        if ([string]::IsNullOrWhiteSpace($TaskFile) -and [string]::IsNullOrWhiteSpace($RouteFile) -and [string]::IsNullOrWhiteSpace($Agent)) {
            return (New-McpRouterFallbackResult -TaskId '' -Agent '' -Reason 'fallback: no TaskFile, RouteFile or Agent given' -Warnings @('missing input: TaskFile, RouteFile or Agent required') -Stages $null)
        }

        $stages = New-McpRouterStagesSkeleton
        $warnings = @()

        $taskId = ''
        $taskType = ''
        $domainCount = 0
        $readWrite = 'read'
        $constraints = @()
        $taskRequired = @()
        $taskUnknown = @()
        $taskDeclared = 0
        $agentName = ''
        $inlinePref = @()
        $inlineForb = @()
        $hasInlineProfile = $false

        if (-not [string]::IsNullOrWhiteSpace($TaskFile)) {
            $tr = Read-McpRouterJsonDoc -Path $TaskFile
            if (-not $tr.Ok) {
                return (New-McpRouterFallbackResult -TaskId '' -Agent '' -Reason ('fallback: task file ' + $tr.Error) -Warnings @('task file unreadable; fallback') -Stages $null)
            }
            try {
                $d = $tr.Doc
                $rawId = Get-McpRouterNodeProp -Node $d -Name 'task_id'
                if ($null -ne $rawId) { $taskId = ([string]$rawId).Trim() }
                if (-not (Test-McpRouterTaskId -TaskId $taskId)) {
                    return (New-McpRouterFallbackResult -TaskId '' -Agent '' -Reason 'fallback: invalid task_id' -Warnings @('invalid task_id; fallback') -Stages $null)
                }
                $rawType = Get-McpRouterNodeProp -Node $d -Name 'task_type'
                if ($null -ne $rawType) { $taskType = ([string]$rawType).Trim() }
                $domainCount = @(ConvertTo-McpRouterStringArray -Value (Get-McpRouterNodeProp -Node $d -Name 'domain_hints')).Count
                $rawRw = Get-McpRouterNodeProp -Node $d -Name 'read_write_mode'
                if ($null -ne $rawRw -and -not [string]::IsNullOrWhiteSpace([string]$rawRw)) {
                    $readWrite = ([string]$rawRw).Trim().ToLowerInvariant()
                }
                $cc = @()
                foreach ($c in @(ConvertTo-McpRouterStringArray -Value (Get-McpRouterNodeProp -Node $d -Name 'constraints'))) {
                    if ($cc.Count -ge 10) { break }
                    $s = Get-McpRouterRedactedText -Text ([string]$c).Trim()
                    if ([string]::IsNullOrWhiteSpace($s)) { continue }
                    if ($s.Length -gt 120) { $s = $s.Substring(0, 120) }
                    $cc += $s
                }
                $constraints = @($cc)
                $reqRaw = Get-McpRouterNodeProp -Node $d -Name 'required_capabilities'
                if ($null -eq $reqRaw) { $reqRaw = Get-McpRouterNodeProp -Node $d -Name 'required_capability_classes' }
                foreach ($v in @(ConvertTo-McpRouterStringArray -Value $reqRaw)) {
                    $s = ([string]$v).Trim().ToLowerInvariant()
                    if (-not (Test-McpRouterClassSyntax -Id $s)) { continue }
                    $taskDeclared++
                    if ($view.Canonical.Contains($s)) {
                        if ($taskRequired -cnotcontains $s) { $taskRequired += $s }
                    }
                    else {
                        if ($taskUnknown -cnotcontains $s) { $taskUnknown += $s }
                    }
                }
                $sel = Get-McpRouterNodeProp -Node $d -Name 'selected_agent'
                if ($null -ne $sel) {
                    if ($sel -is [string]) {
                        $agentName = ([string]$sel).Trim()
                    }
                    else {
                        $nm = Get-McpRouterNodeProp -Node $sel -Name 'name'
                        if ($null -ne $nm) { $agentName = ([string]$nm).Trim() }
                        $prof = Get-McpRouterNodeProp -Node $sel -Name 'capability_profile'
                        if ($null -eq $prof) { $prof = Get-McpRouterNodeProp -Node $sel -Name 'capabilities' }
                        if ($null -ne $prof) {
                            $hasInlineProfile = $true
                            foreach ($v in @(ConvertTo-McpRouterStringArray -Value (Get-McpRouterNodeProp -Node $prof -Name 'preferred'))) {
                                $s = ([string]$v).Trim().ToLowerInvariant()
                                if ((Test-McpRouterClassSyntax -Id $s) -and ($view.Canonical.Contains($s)) -and ($inlinePref -cnotcontains $s)) { $inlinePref += $s }
                            }
                            foreach ($v in @(ConvertTo-McpRouterStringArray -Value (Get-McpRouterNodeProp -Node $prof -Name 'forbidden'))) {
                                $s = ([string]$v).Trim().ToLowerInvariant()
                                if ((Test-McpRouterClassSyntax -Id $s) -and ($view.Canonical.Contains($s)) -and ($inlineForb -cnotcontains $s)) { $inlineForb += $s }
                            }
                        }
                    }
                }
            }
            catch {
                return (New-McpRouterFallbackResult -TaskId '' -Agent '' -Reason 'fallback: task fields unreadable' -Warnings @('task fields unreadable; fallback') -Stages $null)
            }
        }

        $routeRequired = @()
        $routeUnknown = @()
        $routeDeclared = 0
        if (-not [string]::IsNullOrWhiteSpace($RouteFile)) {
            $rr = Read-McpRouterJsonDoc -Path $RouteFile
            if ($rr.Ok -and ($null -ne $rr.Doc)) {
                try {
                    $d = $rr.Doc
                    $rt = Get-McpRouterNodeProp -Node $d -Name 'task_id'
                    if ([string]::IsNullOrWhiteSpace($taskId) -and ($null -ne $rt) -and (Test-McpRouterTaskId -TaskId ([string]$rt))) {
                        $taskId = ([string]$rt).Trim()
                    }
                    if ([string]::IsNullOrWhiteSpace($agentName)) {
                        $pa = Get-McpRouterNodeProp -Node $d -Name 'proposed_agent'
                        if ($null -ne $pa -and -not [string]::IsNullOrWhiteSpace([string]$pa)) {
                            $agentName = ([string]$pa).Trim()
                        }
                    }
                    $pc = Get-McpRouterNodeProp -Node $d -Name 'proposed_mcp_capability_classes'
                    if ($null -eq $pc) { $pc = Get-McpRouterNodeProp -Node $d -Name 'proposed_capability_classes' }
                    foreach ($v in @(ConvertTo-McpRouterStringArray -Value $pc)) {
                        $s = ([string]$v).Trim().ToLowerInvariant()
                        if (-not (Test-McpRouterClassSyntax -Id $s)) { continue }
                        $routeDeclared++
                        if ($view.Canonical.Contains($s)) {
                            if ($routeRequired -cnotcontains $s) { $routeRequired += $s }
                        }
                        else {
                            if ($routeUnknown -cnotcontains $s) { $routeUnknown += $s }
                        }
                    }
                }
                catch { }
            }
            else {
                $warnings += ('route file ' + $rr.Error + '; ignorado')
            }
        }
        if ((-not [string]::IsNullOrWhiteSpace($Agent)) -and [string]::IsNullOrWhiteSpace($agentName)) {
            $agentName = ([string]$Agent).Trim()
        }

        if (-not [string]::IsNullOrWhiteSpace($agentName) -and -not (Test-McpRouterAgentName -Name $agentName)) {
            $warnings += ('agente com nome invalido (ignorado): ' + $agentName)
            $agentName = ''
        }

        $preferred = @()
        $forbidden = @()
        $profileSource = 'none'
        if ($hasInlineProfile) {
            $preferred = @($inlinePref)
            $forbidden = @($inlineForb)
            $profileSource = 'task-selected-agent'
        }
        elseif (-not [string]::IsNullOrWhiteSpace($agentName)) {
            $lookup = "agent:$agentName"
            $found = $false
            foreach ($k in @($reg.Agents.Keys)) {
                if ([string]$k -ceq $agentName) {
                    $preferred = @($reg.Agents[$k].Preferred)
                    $forbidden = @($reg.Agents[$k].Forbidden)
                    $profileSource = 'registry'
                    $found = $true
                    break
                }
            }
            if (-not $found) {
                $warnings += ('agente ausente na registry (perfil vazio): ' + $agentName)
            }
            $lookup = [string]$lookup
        }

        $required = @()
        $requiredSource = ''
        $unknownRejected = @($taskUnknown + $routeUnknown | Select-Object -Unique)
        if ($taskRequired.Count -gt 0) {
            $required = @($taskRequired)
            $requiredSource = 'task'
        }
        elseif ($routeRequired.Count -gt 0) {
            $required = @($routeRequired)
            $requiredSource = 'route-file'
        }
        elseif ((($taskDeclared + $routeDeclared) -eq 0) -and ($preferred.Count -gt 0)) {
            $required = @($preferred)
            $requiredSource = 'agent-preferred'
        }
        foreach ($u in $unknownRejected) {
            $warnings += ('capability desconhecida rejeitada (default-deny): ' + $u)
        }

        $stages.server_discovery.servers_seen = @($reg.Mcps).Count
        $stages.server_discovery.servers_available = @($reg.Mcps | Where-Object { ([string]$_.Status).Trim().ToLowerInvariant() -ceq 'available' }).Count
        $stages.server_discovery.note = 'registry derivada (somente leitura)'

        $discoverSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($m in @($reg.Mcps)) {
            $st = ([string]$m.Status).Trim().ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($st)) { $st = 'missing' }
            if (@('missing', 'invalid', 'disabled') -ccontains $st) { continue }
            foreach ($cp in @($m.Caps)) { $discoverSet.Add($cp) | Out-Null }
        }
        $discoverList = @($discoverSet | Sort-Object)
        $stages.capability_discovery.mcp_capability_classes = @($discoverList)
        $stages.capability_discovery.note = 'classes estruturadas dos MCPs (description/tags/metadata ignorados)'

        $stages.required_capability.required = @($required)
        $stages.required_capability.source = [string]$requiredSource
        $stages.required_capability.unknown_rejected = @($unknownRejected)
        $stages.required_capability.note = 'required = task.required_capabilities, senao route-file, senao agent preferred'

        if ($required.Count -eq 0) {
            $fbReason = 'fallback: no required capability class (task/route/agent vazios ou desconhecidos)'
            if (($taskDeclared + $routeDeclared) -gt 0) {
                $fbReason = 'fallback: required capabilities declaradas sao desconhecidas (default-deny)'
            }
            $stages.required_capability.note = 'sem capability requerida valida; fallback'
            return (New-McpRouterFallbackResult -TaskId $taskId -Agent $agentName -Reason $fbReason -Warnings (@($warnings) + @('no required capability; fallback')) -Stages $stages)
        }

        $isWrite = ($readWrite -ceq 'write')
        $excluded = @()
        $survivors = @()
        foreach ($m in @($reg.Mcps)) {
            $mid = [string]$m.Id
            $mname = [string]$m.Name
            if ([string]::IsNullOrWhiteSpace($mname)) { $mname = ($mid -replace '^(skill|agent|mcp):', '') }
            $st = ([string]$m.Status).Trim().ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($st)) { $st = 'missing' }
            if (@('missing', 'invalid', 'disabled') -ccontains $st) {
                $excluded += [PSCustomObject]@{ mcp = $mname; reason = ('status:{0} excluido' -f $st) }
                continue
            }
            $visNorm = ([string]$m.Visibility).Trim().ToLowerInvariant()
            if ((-not [string]::IsNullOrWhiteSpace($visNorm)) -and ($view.DenyVisibility -ccontains $visNorm)) {
                $excluded += [PSCustomObject]@{ mcp = $mname; reason = ('visibility:{0} negado pela policy (deny_rules.visibility)' -f $visNorm) }
                continue
            }
            $hitForb = @()
            foreach ($cp in @($m.Caps)) {
                if ($forbidden -ccontains $cp) { $hitForb += $cp }
            }
            if ($hitForb.Count -gt 0) {
                $excluded += [PSCustomObject]@{ mcp = $mname; reason = ('permission:forbidden (' + (($hitForb | Sort-Object) -join ',') + ')') }
                continue
            }
            $trustRaw = Get-McpRouterTrustFor -PolicyView $view -ShortName $mname
            $trustNorm = ([string]$trustRaw).Trim().ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($trustNorm)) { $trustNorm = 'unknown' }
            if ($view.TrustAllow -cnotcontains $trustNorm) {
                if ($trustNorm -ceq 'unknown') {
                    $excluded += [PSCustomObject]@{ mcp = $mname; reason = 'trust:unknown bloqueado sob default-deny' }
                }
                else {
                    $excluded += [PSCustomObject]@{ mcp = $mname; reason = ('trust:{0} bloqueado para execucao (exige {1})' -f $trustNorm, (($view.TrustAllow | Sort-Object) -join ',')) }
                }
                continue
            }
            $matched = @()
            foreach ($cp in @($m.Caps)) {
                if ($required -ccontains $cp) { $matched += $cp }
            }
            if ($isWrite) {
                $hitCrit = @()
                foreach ($cp in @($matched)) {
                    $rk = Get-McpRouterRiskFor -PolicyView $view -Capability $cp
                    if ($view.DenyWrite -ccontains $rk) { $hitCrit += ($cp + ':' + $rk) }
                }
                if ($hitCrit.Count -gt 0) {
                    $excluded += [PSCustomObject]@{ mcp = $mname; reason = ('classification:write bloqueado (' + (($hitCrit | Sort-Object) -join ',') + ')') }
                    continue
                }
            }
            $survivors += @{ Id = $mid; Name = $mname; Matched = @($matched | Sort-Object) }
        }

        $stages.permission_hard_filter.excluded = @($excluded)
        $stages.permission_hard_filter.note = 'hard filter ANTES do scoring: status/visibilidade/forbidden/trust/classificacao; permissao vence relevancia'

        $ranked = @($survivors | Sort-Object -Property @{ Expression = { -(@($_.Matched).Count) } }, @{ Expression = { [string]$_.Id } })
        $candidates = @()
        foreach ($s in $ranked) {
            if ((@($s.Matched).Count) -eq 0) { continue }
            $candidates += [PSCustomObject]@{ mcp = [string]$s.Name; matched_classes = @($s.Matched); score = @($s.Matched).Count }
        }
        $stages.router_match.candidates = @($candidates)
        $stages.router_match.note = 'match por capability classes (nunca por nome); score = classes em comum; desempate por id'

        $stages.tool_exposure.note = 'advisory: tool exposure adiado; nenhuma tool exposta (enforcement pertence ao runtime)'
        $stages.runtime_enforcement.note = 'advisory: sem enforcement no router; ver evidence/v3/mcp/enforcement-spike.json'
        $stages.execution.note = 'advisory: nenhuma tool executada'

        $picked = @()
        foreach ($c in $candidates) {
            if ($picked.Count -ge $maxMcps) { break }
            $picked += [string]$c.mcp
        }

        if ($picked.Count -eq 0) {
            $w = @($warnings) + @('no valid mcp; fallback')
            $rtype = $taskType
            if ([string]::IsNullOrWhiteSpace($rtype)) { $rtype = 'unknown' }
            return (New-McpRouterFallbackResult -TaskId $taskId -Agent $agentName -Reason ('fallback: task_type=' + $rtype + ' required=' + $required.Count + ' matched=0') -Warnings $w -Stages $stages)
        }

        $rtype = $taskType
        if ([string]::IsNullOrWhiteSpace($rtype)) { $rtype = 'unknown' }
        $reasonText = ('task_type=' + $rtype + ' domains=' + $domainCount + ' required=' + $required.Count + ' matched=' + $picked.Count + ' agent=' + $agentName + ' profile=' + $profileSource)
        return [PSCustomObject]@{
            router_version = '1'
            task_id        = $taskId
            agent          = $agentName
            mcps           = @($picked)
            stages         = $stages
            reason         = ('selected ' + $picked.Count + ' mcp(s): ' + ($picked -join ',') + ' (' + $reasonText + ')')
            source         = 'mcp-router'
            fallback_used  = $false
            blocked        = $false
            warnings       = @($warnings)
            status         = 'success'
        }
    }
    catch {
        try {
            return (New-McpRouterFallbackResult -TaskId '' -Agent '' -Reason 'fallback: internal error contained' -Warnings @('internal error; fallback') -Stages $null)
        }
        catch {
            return [PSCustomObject]@{
                router_version = '1'; task_id = ''; agent = ''; mcps = @()
                stages = (New-McpRouterStagesSkeleton)
                reason = 'fallback'; source = 'mcp-router'
                fallback_used = $true; blocked = $false
                warnings = @('internal error'); status = 'fallback'
            }
        }
    }
}
