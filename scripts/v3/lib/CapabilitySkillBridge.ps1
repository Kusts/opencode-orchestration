<#!
.SYNOPSIS
    V3 Skill execution bridge lib: Dispatch Contract + CAPABILITY_CONTEXT (Phase 10).
.DESCRIPTION
    Biblioteca dot-sourceable (sem execucao ao carregar). Implementa a ponte
    entre a proposta do Router V1 (advisory) e o Dispatch Contract do Planner:

      - Kill switch ESTRITO: so boolean $true em skill_routing.enabled
        habilita. Qualquer outro tipo ou valor (string "true"/"false",
        int, $null, ausente) => status disabled, skills vazias, SEM
        CAPABILITY_CONTEXT (null), exit 0 no CLI. Tipo invalido nunca
        habilita. Default FALSE (routing permanece desligado).
      - Quando habilitado: seleciona o MENOR conjunto util de skills a
        partir da proposta (proposed_skills do Router V1, do TaskFile ou
        do -RouteFile), valida cada skill contra a registry
        (type skill + status available + hard filter de visibilidade:
        eligibility.visibility em deny_rules.visibility da policy e
        descartada antes de emitir SELECTED_SKILLS), descarta
        unavailable/missing/
        invalid com warning e transmite APENAS identidade/intencao
        (SELECTED_SKILLS ids, CAPABILITY_REASON, CAPABILITY_SOURCE,
        CAPABILITY_CONSTRAINTS). NUNCA o conteudo/SKILL.md: description,
        tags e qualquer texto livre da registry sao DADOS e jamais entram
        no contrato nem alteram policy/trust.
      - Emite bloco CAPABILITY_CONTEXT canonico (JSON estavel) pronto para
        o Planner anexar ao Dispatch Contract, mais versao textual curta.
      - Fallback: nenhuma skill valida (ou entrada/registry invalida) =>
        skills vazias, fallback_used true, blocked FALSE. Nunca lanca,
        nunca bloqueia.
      - Read-only: nao carrega skill de fato (o carregamento e nativo no
        worker pela via nativa), nao executa nada, nao escreve arquivos,
        nao altera flags/policy/config/agentes.

    PowerShell 5.1 compativel. ASCII-only de proposito.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-SkillBridgeRepoRoot {
    [CmdletBinding()]
    param([string]$RepoRoot)
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { return $RepoRoot }
    return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
}

function Read-SkillBridgeUtf8Single {
    <#
    .SYNOPSIS
        Leitura unica de arquivo texto (TOCTOU-aware): um unico ReadAllText.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))
}

function Read-SkillBridgeJsonDoc {
    <#
    .SYNOPSIS
        Le JSON com limite de tamanho em leitura unica. Retorna
        @{ Ok=[bool]; Doc=...; Error=[string] }. Nunca lanca.
        MaxBytes default 16384 (task/route/flags/policy); 0 = sem
        limite (registry derivada, gerada pelo build).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [int]$MaxBytes = 16384)
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return @{ Ok = $false; Doc = $null; Error = 'not-found' }
        }
        $text = Read-SkillBridgeUtf8Single -Path $Path
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

function Read-SkillBridgeFlags {
    [CmdletBinding()]
    param([string]$FlagsPath, [string]$RepoRoot)
    $resolved = $FlagsPath
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        $resolved = Join-Path (Get-SkillBridgeRepoRoot -RepoRoot $RepoRoot) 'source\registry\capability-flags.json'
    }
    $r = Read-SkillBridgeJsonDoc -Path $resolved
    if (-not $r.Ok) { return $null }
    return $r.Doc
}

function Test-SkillBridgeEnabled {
    <#
    .SYNOPSIS
        Kill switch ESTRITO: so boolean $true em skill_routing.enabled
        habilita. Qualquer outro tipo/valor => desabilitado.
    #>
    [CmdletBinding()]
    param($Flags)
    if ($null -eq $Flags) { return $false }
    try {
        $node = $null
        if ($Flags -is [System.Collections.IDictionary]) {
            if ($Flags.Contains('skill_routing')) { $node = $Flags['skill_routing'] }
        }
        else {
            $p = $Flags.PSObject.Properties | Where-Object { $_.Name -ceq 'skill_routing' } | Select-Object -First 1
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

function Test-SkillBridgeTaskId {
    [CmdletBinding()]
    param([string]$TaskId)
    if ([string]::IsNullOrWhiteSpace($TaskId)) { return $false }
    $s = ([string]$TaskId).Trim()
    if ($s.Length -gt 64) { return $false }
    return ($s -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')
}

function Test-SkillBridgeCanonicalId {
    [CmdletBinding()]
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
    $s = ([string]$Id).Trim()
    if ($s.Length -gt 64) { return $false }
    return ($s -match '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$')
}

function Get-SkillBridgeSecretPattern {
    [CmdletBinding()]
    param()
    try {
        $fn = Get-Command 'Get-SecretValuePattern' -ErrorAction SilentlyContinue
        if ($null -ne $fn) { return (Get-SecretValuePattern) }
    }
    catch { }
    return 'Bearer\s+[A-Za-z0-9\-._~+/=]{8,}|sk-[A-Za-z0-9\-]{10,}'
}

function Get-SkillBridgeRedactedText {
    [CmdletBinding()]
    param([string]$Text)
    $s = [string]$Text
    if ([string]::IsNullOrEmpty($s)) { return '' }
    try {
        $pattern = Get-SkillBridgeSecretPattern
        return ($s -replace $pattern, '[REDACTED]')
    }
    catch { return $s }
}

function ConvertTo-SkillBridgeStringArray {
    <#
    .SYNOPSIS
        Achata enumeravel em [string[]] plano (DTO estavel, sem
        {value,Count}). Limite defensivo: 100 itens (trunca, sem lancar).
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

function Get-SkillBridgeMaxSkills {
    <#
    .SYNOPSIS
        Maximo de skills no contexto: override 1..5 vence; senao
        policy skill_bridge.max_skills (int 1..5); senao 3.
    #>
    [CmdletBinding()]
    param($Policy, [int]$Override = -1)
    if ($Override -ge 1 -and $Override -le 5) { return $Override }
    try {
        if ($null -ne $Policy) {
            $node = $null
            if ($Policy -is [System.Collections.IDictionary]) {
                if ($Policy.Contains('skill_bridge')) { $node = $Policy['skill_bridge'] }
            }
            else {
                $p = $Policy.PSObject.Properties | Where-Object { $_.Name -ceq 'skill_bridge' } | Select-Object -First 1
                if ($null -ne $p) { $node = $p.Value }
            }
            if ($null -ne $node) {
                $v = $null
                if ($node -is [System.Collections.IDictionary]) {
                    if ($node.Contains('max_skills')) { $v = $node['max_skills'] }
                }
                else {
                    $p2 = $node.PSObject.Properties | Where-Object { $_.Name -ceq 'max_skills' } | Select-Object -First 1
                    if ($null -ne $p2) { $v = $p2.Value }
                }
                $n = 0
                try { $n = [int]$v } catch { $n = 0 }
                if ($n -ge 1 -and $n -le 5) { return $n }
            }
        }
    }
    catch { }
    return 3
}

function Get-SkillBridgeDenyVisibility {
    <#
    .SYNOPSIS
        Visibilidades negadas pela policy (deny_rules.visibility; default
        hidden/internal/experimental). Somente policy; nunca metadata de
        skill. Nunca lanca.
    #>
    [CmdletBinding()]
    param($Policy)
    $deny = @('hidden', 'internal', 'experimental')
    try {
        if ($null -ne $Policy) {
            $node = $null
            if ($Policy -is [System.Collections.IDictionary]) {
                if ($Policy.Contains('deny_rules')) { $node = $Policy['deny_rules'] }
            }
            else {
                $p = $Policy.PSObject.Properties | Where-Object { $_.Name -ceq 'deny_rules' } | Select-Object -First 1
                if ($null -ne $p) { $node = $p.Value }
            }
            if ($null -ne $node) {
                $v = $null
                if ($node -is [System.Collections.IDictionary]) {
                    if ($node.Contains('visibility')) { $v = $node['visibility'] }
                }
                else {
                    $p2 = $node.PSObject.Properties | Where-Object { $_.Name -ceq 'visibility' } | Select-Object -First 1
                    if ($null -ne $p2) { $v = $p2.Value }
                }
                $list = @(ConvertTo-SkillBridgeStringArray -Value $v)
                if ($list.Count -gt 0) {
                    $norm = @()
                    foreach ($t in $list) {
                        $s = ([string]$t).Trim().ToLowerInvariant()
                        if (-not [string]::IsNullOrWhiteSpace($s)) { $norm += $s }
                    }
                    if ($norm.Count -gt 0) { $deny = @($norm) }
                }
            }
        }
    }
    catch { }
    return @($deny)
}

function Read-SkillBridgeRegistryMap {
    <#
    .SYNOPSIS
        Le a registry derivada e monta mapa id -> @{ Type; Status; Visibility }.
        Retorna @{ Available=[bool]; Map=@{}; Error=[string] }. Nunca lanca.
        So registra identidade/status/visibilidade estrutural:
        description/tags NUNCA saem daqui.
    #>
    [CmdletBinding()]
    param([string]$RegistryPath, [string]$RepoRoot)
    $resolved = $RegistryPath
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        $resolved = Join-Path (Get-SkillBridgeRepoRoot -RepoRoot $RepoRoot) 'cache\v3\capability-registry.json'
    }
    $r = Read-SkillBridgeJsonDoc -Path $resolved -MaxBytes 0
    if (-not $r.Ok) {
        return @{ Available = $false; Map = @{}; Error = ('registry ' + $r.Error) }
    }
    $map = @{}
    try {
        $caps = @()
        $doc = $r.Doc
        if ($doc -is [System.Collections.IDictionary]) {
            if ($doc.Contains('capabilities')) { $caps = @($doc['capabilities']) }
        }
        else {
            $p = $doc.PSObject.Properties | Where-Object { $_.Name -ceq 'capabilities' } | Select-Object -First 1
            if ($null -ne $p) { $caps = @($p.Value) }
        }
        foreach ($c in $caps) {
            try {
                $id = ''; $type = ''; $status = ''; $vis = ''
                if ($c -is [System.Collections.IDictionary]) {
                    if ($c.Contains('id')) { $id = [string]$c['id'] }
                    if ($c.Contains('type')) { $type = [string]$c['type'] }
                    if ($c.Contains('status')) { $status = [string]$c['status'] }
                    if ($c.Contains('eligibility')) {
                        $elig = $c['eligibility']
                        if ($elig -is [System.Collections.IDictionary]) {
                            if ($elig.Contains('visibility')) { $vis = ([string]$elig['visibility']).Trim().ToLowerInvariant() }
                        }
                        else {
                            try {
                                $pv = $elig.PSObject.Properties | Where-Object { $_.Name -ceq 'visibility' } | Select-Object -First 1
                                if ($null -ne $pv) { $vis = ([string]$pv.Value).Trim().ToLowerInvariant() }
                            } catch { }
                        }
                    }
                }
                else {
                    foreach ($f in @('id', 'type', 'status')) {
                        $pp = $c.PSObject.Properties | Where-Object { $_.Name -ceq $f } | Select-Object -First 1
                        if ($null -ne $pp) {
                            if ($f -ceq 'id') { $id = [string]$pp.Value }
                            elseif ($f -ceq 'type') { $type = [string]$pp.Value }
                            else { $status = [string]$pp.Value }
                        }
                    }
                    try {
                        $pe = $c.PSObject.Properties | Where-Object { $_.Name -ceq 'eligibility' } | Select-Object -First 1
                        if ($null -ne $pe -and ($null -ne $pe.Value)) {
                            $ev = $pe.Value
                            if ($ev -is [System.Collections.IDictionary]) {
                                if ($ev.Contains('visibility')) { $vis = ([string]$ev['visibility']).Trim().ToLowerInvariant() }
                            }
                            else {
                                $pv = $ev.PSObject.Properties | Where-Object { $_.Name -ceq 'visibility' } | Select-Object -First 1
                                if ($null -ne $pv) { $vis = ([string]$pv.Value).Trim().ToLowerInvariant() }
                            }
                        }
                    } catch { }
                }
                if (-not [string]::IsNullOrWhiteSpace($id) -and -not $map.ContainsKey($id)) {
                    $map[$id] = @{ Type = $type; Status = $status; Visibility = $vis }
                }
            }
            catch { }
        }
    }
    catch { return @{ Available = $false; Map = @{}; Error = 'registry unreadable' } }
    return @{ Available = $true; Map = $map; Error = '' }
}

function New-SkillBridgeDisabledResult {
    [CmdletBinding()]
    param([string]$TaskId)
    return [PSCustomObject]@{
        bridge_version          = '1'
        task_id                 = [string]$TaskId
        skills                  = @()
        capability_context      = $null
        capability_context_text = ''
        reason                  = 'skill routing disabled (skill_routing.enabled != true); no CAPABILITY_CONTEXT emitted'
        source                  = 'skill-bridge'
        fallback_used           = $false
        blocked                 = $false
        warnings                = @('skill routing disabled')
        status                  = 'disabled'
    }
}

function New-SkillBridgeFallbackResult {
    [CmdletBinding()]
    param([string]$TaskId, [string]$Reason, [string[]]$Warnings, $Constraints)
    if ($null -eq $Warnings -or $Warnings.Count -eq 0) { $Warnings = @('no valid skill; fallback') }
    if ($null -eq $Constraints) { $Constraints = @() }
    $ctx = [PSCustomObject]@{
        SELECTED_SKILLS        = @()
        SELECTED_MCPS          = @()
        CAPABILITY_REASON      = [string]$Reason
        CAPABILITY_SOURCE      = 'skill-bridge'
        CAPABILITY_CONSTRAINTS = @($Constraints)
    }
    return [PSCustomObject]@{
        bridge_version          = '1'
        task_id                 = [string]$TaskId
        skills                  = @()
        capability_context      = $ctx
        capability_context_text = 'CAPABILITY_CONTEXT skills=[] (fallback; no valid skill)'
        reason                  = [string]$Reason
        source                  = 'skill-bridge'
        fallback_used           = $true
        blocked                 = $false
        warnings                = @($Warnings)
        status                  = 'fallback'
    }
}

function Invoke-CapabilitySkillBridge {
    <#
    .SYNOPSIS
        Ponte skill -> Dispatch Contract (read-only, nunca bloqueia).
    .DESCRIPTION
        Parametros: TaskFile (contexto minimo), ProposedSkills (ids da
        proposta do Router V1), RouteFile (saida do Router/shadow com
        proposed_skills ou route.skills), RegistryPath, PolicyPath,
        FlagsPath, RepoRoot, MaxSkillsOverride. Nunca lanca: qualquer
        falha operacional vira disabled (kill switch) ou fallback.
    #>
    [CmdletBinding()]
    param(
        [string]$TaskFile,
        [string[]]$ProposedSkills,
        [string]$RouteFile,
        [string]$RegistryPath,
        [string]$PolicyPath,
        [string]$FlagsPath,
        [string]$RepoRoot,
        [int]$MaxSkillsOverride = -1
    )
    try {
        $repo = Get-SkillBridgeRepoRoot -RepoRoot $RepoRoot
        $flags = Read-SkillBridgeFlags -FlagsPath $FlagsPath -RepoRoot $repo
        if (-not (Test-SkillBridgeEnabled -Flags $flags)) {
            $tid = ''
            try {
                if (-not [string]::IsNullOrWhiteSpace($TaskFile)) {
                    $probe = Read-SkillBridgeJsonDoc -Path $TaskFile
                    if ($probe.Ok -and ($null -ne $probe.Doc)) {
                        $d = $probe.Doc
                        if ($d -is [System.Collections.IDictionary]) {
                            if ($d.Contains('task_id')) { $tid = [string]$d['task_id'] }
                        }
                        else {
                            $pp = $d.PSObject.Properties | Where-Object { $_.Name -ceq 'task_id' } | Select-Object -First 1
                            if ($null -ne $pp) { $tid = [string]$pp.Value }
                        }
                    }
                }
            }
            catch { $tid = '' }
            if (-not (Test-SkillBridgeTaskId -TaskId $tid)) { $tid = '' }
            return (New-SkillBridgeDisabledResult -TaskId $tid)
        }

        $policy = $null
        try {
            $resolvedPolicy = $PolicyPath
            if ([string]::IsNullOrWhiteSpace($resolvedPolicy)) {
                $resolvedPolicy = Join-Path $repo 'source\registry\capability-policy.json'
            }
            $pr = Read-SkillBridgeJsonDoc -Path $resolvedPolicy
            if ($pr.Ok) { $policy = $pr.Doc }
        }
        catch { $policy = $null }
        $maxSkills = Get-SkillBridgeMaxSkills -Policy $policy -Override $MaxSkillsOverride

        if ([string]::IsNullOrWhiteSpace($TaskFile) -and [string]::IsNullOrWhiteSpace($RouteFile)) {
            return (New-SkillBridgeFallbackResult -TaskId '' -Reason 'fallback: no TaskFile or RouteFile given' -Warnings @('missing input: TaskFile or RouteFile required') -Constraints @())
        }

        $taskId = ''
        $taskType = ''
        $domainCount = 0
        $constraints = @()
        $taskSkills = @()
        if (-not [string]::IsNullOrWhiteSpace($TaskFile)) {
            $tr = Read-SkillBridgeJsonDoc -Path $TaskFile
            if (-not $tr.Ok) {
                return (New-SkillBridgeFallbackResult -TaskId '' -Reason ('fallback: task file ' + $tr.Error) -Warnings @('task file unreadable; fallback') -Constraints @())
            }
            try {
                $d = $tr.Doc
                $get = {
                    param($Name)
                    if ($d -is [System.Collections.IDictionary]) {
                        if ($d.Contains($Name)) { return $d[$Name] }
                    }
                    else {
                        $pp = $d.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1
                        if ($null -ne $pp) { return $pp.Value }
                    }
                    return $null
                }
                $rawId = & $get 'task_id'
                if ($null -ne $rawId) { $taskId = ([string]$rawId).Trim() }
                if (-not (Test-SkillBridgeTaskId -TaskId $taskId)) {
                    return (New-SkillBridgeFallbackResult -TaskId '' -Reason 'fallback: invalid task_id' -Warnings @('invalid task_id; fallback') -Constraints @())
                }
                $rawType = & $get 'task_type'
                if ($null -ne $rawType) { $taskType = ([string]$rawType).Trim() }
                $rawDomains = & $get 'domain_hints'
                $domainCount = @(ConvertTo-SkillBridgeStringArray -Value $rawDomains).Count
                $rawConstraints = & $get 'constraints'
                $rawList = @(ConvertTo-SkillBridgeStringArray -Value $rawConstraints)
                $cc = @()
                foreach ($c in $rawList) {
                    if ($cc.Count -ge 10) { break }
                    $s = Get-SkillBridgeRedactedText -Text ([string]$c).Trim()
                    if ([string]::IsNullOrWhiteSpace($s)) { continue }
                    if ($s.Length -gt 120) { $s = $s.Substring(0, 120) }
                    $cc += $s
                }
                $constraints = @($cc)
                $rawSkills = & $get 'proposed_skills'
                $taskSkills = @(ConvertTo-SkillBridgeStringArray -Value $rawSkills)
            }
            catch {
                return (New-SkillBridgeFallbackResult -TaskId '' -Reason 'fallback: task fields unreadable' -Warnings @('task fields unreadable; fallback') -Constraints @())
            }
        }

        $routeSkills = @()
        $routeClasses = 0
        $routeSource = 'router-v1'
        if (-not [string]::IsNullOrWhiteSpace($RouteFile)) {
            $rr = Read-SkillBridgeJsonDoc -Path $RouteFile
            if ($rr.Ok -and ($null -ne $rr.Doc)) {
                try {
                    $d = $rr.Doc
                    $getR = {
                        param($Name)
                        if ($d -is [System.Collections.IDictionary]) {
                            if ($d.Contains($Name)) { return $d[$Name] }
                        }
                        else {
                            $pp = $d.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1
                            if ($null -ne $pp) { return $pp.Value }
                        }
                        return $null
                    }
                    $ps = & $getR 'proposed_skills'
                    if ($null -ne $ps) { $routeSkills = @(ConvertTo-SkillBridgeStringArray -Value $ps) }
                    if ($routeSkills.Count -eq 0) {
                        $route = & $getR 'route'
                        if ($null -ne $route) {
                            $sk = $null
                            if ($route -is [System.Collections.IDictionary]) {
                                if ($route.Contains('skills')) { $sk = $route['skills'] }
                            }
                            else {
                                $pp = $route.PSObject.Properties | Where-Object { $_.Name -ceq 'skills' } | Select-Object -First 1
                                if ($null -ne $pp) { $sk = $pp.Value }
                            }
                            if ($null -ne $sk) { $routeSkills = @(ConvertTo-SkillBridgeStringArray -Value $sk) }
                        }
                    }
                    $pc = & $getR 'proposed_capability_classes'
                    $routeClasses = @(ConvertTo-SkillBridgeStringArray -Value $pc).Count
                    $rt = & $getR 'task_id'
                    if (([string]::IsNullOrWhiteSpace($taskId)) -and ($null -ne $rt) -and (Test-SkillBridgeTaskId -TaskId ([string]$rt))) {
                        $taskId = ([string]$rt).Trim()
                    }
                    $routeSource = 'route-file'
                }
                catch { }
            }
        }

        $merged = @()
        foreach ($s in @($ProposedSkills)) {
            foreach ($v in @(ConvertTo-SkillBridgeStringArray -Value $s)) { $merged += $v }
        }
        foreach ($v in @($taskSkills)) { $merged += $v }
        foreach ($v in @($routeSkills)) { $merged += $v }
        if ($merged.Count -gt 20) { $merged = @($merged | Select-Object -First 20) }

        $reg = Read-SkillBridgeRegistryMap -RegistryPath $RegistryPath -RepoRoot $repo
        if (-not $reg.Available) {
            return (New-SkillBridgeFallbackResult -TaskId $taskId -Reason ('fallback: ' + $reg.Error) -Warnings @('registry unavailable; fallback') -Constraints $constraints)
        }
        $denyVis = @(Get-SkillBridgeDenyVisibility -Policy $policy)

        $warnings = @()
        $selected = @()
        $seen = @{}
        foreach ($raw in $merged) {
            $id = ([string]$raw).Trim()
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            if (-not (Test-SkillBridgeCanonicalId -Id $id)) {
                $warnings += ('skill descartada (id invalido): ' + $id)
                continue
            }
            $canon = $id
            if ($canon -notmatch ':') { $canon = ('skill:' + $canon) }
            if ($seen.ContainsKey($canon)) { continue }
            $seen[$canon] = $true
            if (-not $reg.Map.ContainsKey($canon)) {
                $warnings += ('skill descartada (missing): ' + $canon)
                continue
            }
            $rec = $reg.Map[$canon]
            $visNorm = ''
            try { $visNorm = ([string]$rec.Visibility).Trim().ToLowerInvariant() } catch { $visNorm = '' }
            if ((-not [string]::IsNullOrWhiteSpace($visNorm)) -and ($denyVis -ccontains $visNorm)) {
                $warnings += ('skill descartada (visibility): ' + $canon)
                continue
            }
            if ($rec.Type -cne 'skill') {
                $warnings += ('skill descartada (not-a-skill): ' + $canon)
                continue
            }
            if ($rec.Status -cne 'available') {
                $warnings += ('skill descartada (unavailable): ' + $canon)
                continue
            }
            $selected += $canon
            if ($selected.Count -ge $maxSkills) { break }
        }

        if ($selected.Count -eq 0) {
            $w = @($warnings)
            $w += 'no valid skill; fallback'
            $rtype = $taskType
            if ([string]::IsNullOrWhiteSpace($rtype)) { $rtype = 'unknown' }
            return (New-SkillBridgeFallbackResult -TaskId $taskId -Reason ('fallback: task_type=' + $rtype + ' proposed=' + $merged.Count + ' selected=0') -Warnings $w -Constraints $constraints)
        }

        $rtype = $taskType
        if ([string]::IsNullOrWhiteSpace($rtype)) { $rtype = 'unknown' }
        $reasonText = ('task_type=' + $rtype + ' domains=' + $domainCount + ' classes=' + $routeClasses + ' proposed=' + $merged.Count + ' selected=' + $selected.Count)
        $ctx = [PSCustomObject]@{
            SELECTED_SKILLS        = @($selected)
            SELECTED_MCPS          = @()
            CAPABILITY_REASON      = $reasonText
            CAPABILITY_SOURCE      = $routeSource
            CAPABILITY_CONSTRAINTS = @($constraints)
        }
        $joined = ($selected -join ',')
        $cjoined = ($constraints -join ';')
        $text = ('CAPABILITY_CONTEXT skills=[' + $joined + '] reason=' + $reasonText + ' source=' + $routeSource)
        if (-not [string]::IsNullOrWhiteSpace($cjoined)) { $text += (' constraints=[' + $cjoined + ']') }
        return [PSCustomObject]@{
            bridge_version          = '1'
            task_id                 = $taskId
            skills                  = @($selected)
            capability_context      = $ctx
            capability_context_text = $text
            reason                  = ('selected ' + $selected.Count + ' skill(s): ' + $joined + ' (' + $reasonText + ')')
            source                  = 'skill-bridge'
            fallback_used           = $false
            blocked                 = $false
            warnings                = @($warnings)
            status                  = 'success'
        }
    }
    catch {
        try {
            return (New-SkillBridgeFallbackResult -TaskId '' -Reason 'fallback: internal error contained' -Warnings @('internal error; fallback') -Constraints @())
        }
        catch {
            return [PSCustomObject]@{
                bridge_version = '1'; task_id = ''; skills = @()
                capability_context = $null; capability_context_text = ''
                reason = 'fallback'; source = 'skill-bridge'
                fallback_used = $true; blocked = $false
                warnings = @('internal error'); status = 'fallback'
            }
        }
    }
}
