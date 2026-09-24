<#!
.SYNOPSIS
    V3 Stage-1 controlled ACCEPTANCE executor (Phase 15): Router -> accepted route or deterministic fallback.
.DESCRIPTION
    Biblioteca dot-sourceable (sem execucao ao carregar) que e o EXECUTOR atras
    de capability_router.active. Ela NAO le flags por conta propria: o chamador
    passa -Active (da flag real). Requer que o chamador tenha dot-sourced
    CapabilityRouter.ps1 (New-RouterTask, Import-RouterPolicy,
    Read-RouterRegistry, Get-RouterAllowlist, Get-RouterExpectedAgent,
    Test-RouterTrivial, Get-RouterRequiredCapabilities,
    Test-RouterExecutionRequired, Invoke-RouterRoute, Get-RouterFallbackResult,
    Test-RouterHardFilter) antes de Invoke-CapabilityAcceptance.

    Semantica (o Planner continua sendo o Control Plane):
      - active=false  => kill switch: rota DETERMINISTICA (expected agent),
        fallback_used=true, fallback_reason=router_inactive. O Router nao
        influencia a decisao.
      - active=true   => o Router PODE controlar SOMENTE dentro do envelope
        Stage 1: categoria de tarefa permitida, sem hard exclusion, candidato
        valido (existe/allowlisted/available/role-compatible/fresh/nao
        forbidden), confidence gate suficiente e sem conflito fraco com a
        expectativa deterministica. Caso contrario => DETERMINISTIC_FALLBACK.
      - Tarefa trivial => DIRECT (sem delegacao).
      - Security/authority/permission/credentials/destructive/migration/
        infra-mutation/control-plane/MCP-execution => deterministic-first.
        O Router pode observar, nunca controlar.
      - Router output e DADO: nunca executa MCP, nunca carrega skill, nunca
        altera authority/permissao/allowlist/flags.

    Telemetria: linha JSONL sanitizada (enums/ids/hashes/bools/ints; sem texto
    livre) em cache/v3/telemetry/acceptance-YYYYMMDD.jsonl, confinada e
    fail-closed. ASCII-only de proposito (PowerShell 5.1). Nunca lanca para o
    chamador nos caminhos operacionais (fail-safe => fallback).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-AcceptanceRepoRoot {
    [CmdletBinding()]
    param([string]$RepoRoot)
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { return $RepoRoot }
    return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
}

function Get-AcceptanceHash16 {
    [CmdletBinding()]
    param([string]$Text)
    try {
        $s = [string]$Text
        if ([string]::IsNullOrEmpty($s)) { return '' }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($s)
            $hash = $sha.ComputeHash($bytes)
            $hex = (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
            return ('h:' + $hex.Substring(0, 16))
        }
        finally { try { $sha.Dispose() } catch { } }
    }
    catch { return '' }
}

function Get-AcceptanceToken {
    [CmdletBinding()]
    param([string]$Text)
    try {
        $s = ([string]$Text).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($s)) { return '' }
        if ($s.Length -gt 32) { return '' }
        if ($s -match '^[a-z][a-z0-9_-]{0,31}$') { return $s }
    }
    catch { }
    return ''
}

function Get-AcceptanceSafeToken {
    <#
    .SYNOPSIS
        Token canonico para campos de ID/enum de telemetria; descarta (vazio)
        valores secret-like (nunca persiste token/sk-/ghp_/AKIA/... no JSONL).
    #>
    [CmdletBinding()]
    param([string]$Text)
    try {
        $t = Get-AcceptanceToken -Text $Text
        if ([string]::IsNullOrWhiteSpace($t)) { return '' }
        if ($t -match '(secret|password|passwd|passphrase|apikey|api[-_]?key|token|credential|bearer|jwt|private|access[-_]?key|client[-_]?secret)') { return '' }
        if ($t -match '^(sk|ghp|gho|ghs|akia|asia|aiza)[0-9a-z_-]*$') { return '' }
        return $t
    }
    catch { return '' }
}

function Get-AcceptanceReasonToken {
    [CmdletBinding()]
    param([string]$Text)
    try {
        $s = ([string]$Text).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return '' }
        $tok = Get-AcceptanceToken -Text $s
        if (-not [string]::IsNullOrWhiteSpace($tok)) { return $tok }
        return (Get-AcceptanceHash16 -Text $s)
    }
    catch { return '' }
}

function Get-AcceptanceTaskIdHash {
    [CmdletBinding()]
    param([string]$TaskId)
    try {
        $s = ([string]$TaskId).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return '' }
        if ($s -match '^sha256:[0-9a-f]{16}$') { return $s.ToLowerInvariant() }
        $h = Get-AcceptanceHash16 -Text $s
        if ([string]::IsNullOrWhiteSpace($h)) { return '' }
        return ('sha256:' + $h.Substring(2))
    }
    catch { return '' }
}

function Get-AcceptanceRisk {
    [CmdletBinding()]
    param([string]$Risk)
    try {
        $s = ([string]$Risk).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($s)) { return 'unknown' }
        $allowed = @('low', 'medium', 'high', 'critical', 'unknown')
        if ($allowed -ccontains $s) { return $s }
    }
    catch { }
    return 'unknown'
}

function Test-AcceptanceAgentId {
    [CmdletBinding()]
    param([string]$Name)
    try {
        $s = ([string]$Name).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return $false }
        if ($s.Length -gt 64) { return $false }
        return ($s -match '^[a-z][a-z0-9-]{0,63}$')
    }
    catch { return $false }
}

function Get-AcceptanceNodeProp {
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

function Get-AcceptanceStringArray {
    [CmdletBinding()]
    param($Record, [string]$Field)
    $vals = @()
    try {
        $node = Get-AcceptanceNodeProp -Node $Record -Name $Field
        foreach ($v in @($node)) {
            if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) { $vals += [string]$v }
        }
    }
    catch { $vals = @() }
    return $vals
}

function Get-AcceptanceRecordConfidence {
    [CmdletBinding()]
    param($Record)
    try {
        $cls = Get-AcceptanceNodeProp -Node $Record -Name 'classification'
        if ($null -ne $cls) {
            $c = Get-AcceptanceNodeProp -Node $cls -Name 'confidence'
            if ($null -ne $c) {
                $s = ([string]$c).Trim().ToLowerInvariant()
                $allowed = @('explicit', 'curated', 'inferred_high', 'inferred_low', 'unknown')
                if ($allowed -ccontains $s) { return $s }
            }
        }
    }
    catch { }
    return 'unknown'
}

function Get-AcceptanceAgentRecord {
    [CmdletBinding()]
    param($Capabilities, [string]$Name)
    try {
        $want = ([string]$Name).Trim()
        if ([string]::IsNullOrWhiteSpace($want)) { return $null }
        foreach ($rec in @($Capabilities)) {
            $t = ([string](Get-AcceptanceNodeProp -Node $rec -Name 'type')).Trim().ToLowerInvariant()
            if ($t -cne 'agent') { continue }
            $n = ([string](Get-AcceptanceNodeProp -Node $rec -Name 'name')).Trim()
            $id = ([string](Get-AcceptanceNodeProp -Node $rec -Name 'id')).Trim()
            if (($n -ceq $want) -or ($id -ceq ('agent:' + $want))) { return $rec }
        }
    }
    catch { }
    return $null
}

function Get-AcceptanceStage1Categories {
    [CmdletBinding()]
    param()
    return @(
        'research', 'exploration', 'requirements', 'product-design',
        'engineering-advisory', 'frontend', 'backend', 'database',
        'testing', 'review', 'documentation'
    )
}

function Get-AcceptanceCategoryAgents {
    <#
    .SYNOPSIS
        Envelope ativo Stage 1+2: agentes permitidos por categoria. O Router so
        pode controlar se o candidato pertencer a esta lista; qualquer outro
        candidato (architect/debugger/ai/automation/security/...) cai em
        deterministic-first. Infra Stage 2: infra-planning e
        infra-implementation permitem somente infra-engineer.
    #>
    [CmdletBinding()]
    param([string]$Category)
    try {
        $c = ([string]$Category).Trim().ToLowerInvariant()
        switch ($c) {
            'research'             { return @('researcher') }
            'exploration'          { return @('explorer') }
            'requirements'         { return @('requirements-analyst') }
            'product-design'       { return @('product-designer') }
            'engineering-advisory' { return @('engineering-advisor', 'skeptic') }
            'frontend'             { return @('frontend-engineer') }
            'backend'              { return @('backend-engineer') }
            'database'             { return @('database-engineer') }
            'testing'              { return @('tester') }
            'review'               { return @('reviewer') }
            'documentation'        { return @('docs-manager') }
            'infra-planning'       { return @('infra-engineer') }
            'infra-implementation' { return @('infra-engineer') }
            default                { return @() }
        }
    }
    catch { return @() }
}

function Get-SimulatedTaskCategory {
    <#
    .SYNOPSIS
        Mapeamento de categoria SOMENTE para simulacao Stage 2 (inerte por padrao).
    .DESCRIPTION
        Retorna a categoria simulada quando o mapeamento base produziu vazio.
        Matching EXATO (case-insensitive, sem substring) sobre task_type,
        domain e expected_agent, dirigido pelo envelope passado — nunca por
        dados globais. Com $SimulateEnvelope=$null (default) retorna sempre
        vazio e o comportamento ativo e identico ao Stage 1.
    #>
    [CmdletBinding()]
    param($Task, [string]$ExpectedAgent, $SimulateEnvelope)
    try {
        if ($null -eq $SimulateEnvelope) { return '' }
        $map = $null
        if ($SimulateEnvelope -is [System.Collections.IDictionary]) {
            if ($SimulateEnvelope.Contains('ExtraTaskMap')) { $map = $SimulateEnvelope['ExtraTaskMap'] }
        }
        else {
            $p = $SimulateEnvelope.PSObject.Properties | Where-Object { $_.Name -ceq 'ExtraTaskMap' } | Select-Object -First 1
            if ($null -ne $p) { $map = $p.Value }
        }
        if ($null -eq $map) { return '' }
        $tt = ([string]$Task.TaskType).Trim().ToLowerInvariant()
        $dom = ([string]$Task.Domain).Trim().ToLowerInvariant()
        $exp = ([string]$ExpectedAgent).Trim().ToLowerInvariant()
        $tables = @('TaskTypes', 'Domains', 'ExpectedAgents')
        $keys = @($tt, $dom, $exp)
        for ($i = 0; $i -lt $tables.Count; $i++) {
            $table = $null
            try {
                if ($map -is [System.Collections.IDictionary]) {
                    if ($map.Contains($tables[$i])) { $table = $map[$tables[$i]] }
                }
                else {
                    $pp = $map.PSObject.Properties | Where-Object { $_.Name -ceq $tables[$i] } | Select-Object -First 1
                    if ($null -ne $pp) { $table = $pp.Value }
                }
            }
            catch { $table = $null }
            if ($null -eq $table) { continue }
            $hit = ''
            try {
                if ($table -is [System.Collections.IDictionary]) {
                    foreach ($k in @($table.Keys)) {
                        if (([string]$k).Trim().ToLowerInvariant() -ceq $keys[$i]) { $hit = [string]$table[$k]; break }
                    }
                }
            }
            catch { $hit = '' }
            if (-not [string]::IsNullOrWhiteSpace($hit)) { return $hit.Trim().ToLowerInvariant() }
        }
    }
    catch { }
    return ''
}

# Exploration semantics: explorer=repo/code discovery, researcher=external, domain=localized deep
function Get-AcceptanceTaskCategory {
    [CmdletBinding()]
    param($Task, [string]$ExpectedAgent)
    try {
        $tt = ([string]$Task.TaskType).Trim().ToLowerInvariant()
        $dom = ([string]$Task.Domain).Trim().ToLowerInvariant()
        # Stage 2 (infra): dominio infra com task_type explicito de
        # implementacao ou planejamento vira categoria infra dedicada.
        # Outros task_types de dominio infra caem em vazio (fallback),
        # nunca em categoria Stage 1.
        if ($dom -ceq 'infra') { if ($tt -ceq 'implementation') { return 'infra-implementation' }; if (($tt -ceq 'analysis') -or ($tt -ceq 'advisory') -or ($tt -ceq 'planning')) { return 'infra-planning' }; return '' }
        # 1) TIPO DE TRABALHO (task_type) define a categoria quando explicito:
        #    uma revisao/teste/pesquisa/documentacao de dominio nao deve virar
        #    implementacao do dominio nem ser sobrescrita pela expectativa.
        if ($tt -ceq 'research') { return 'research' }
        if (($tt -ceq 'discovery') -or ($tt -ceq 'exploration')) { return 'exploration' }
        if ($tt -ceq 'planning') { return 'requirements' }
        if ($tt -ceq 'design') { return 'product-design' }
        # Review semantics: task_type review vence domínio em prosa (backend/database/frontend)
        if ($tt -ceq 'review') { return 'review' }
        if (($tt -ceq 'validation') -or ($tt -ceq 'test') -or ($tt -ceq 'testing')) { return 'testing' }
        if ($tt -ceq 'documentation') { return 'documentation' }
        # 2) DOMINIO explicito.
        if ($dom -ceq 'research') { return 'research' }
        if ($dom -ceq 'documentation') { return 'documentation' }
        if ($dom -ceq 'design') { return 'product-design' }
        if ($dom -ceq 'engineering') { return 'engineering-advisory' }
        if ($dom -ceq 'frontend') { return 'frontend' }
        if ($dom -ceq 'backend') { return 'backend' }
        if (($dom -ceq 'database') -or ($dom -ceq 'data')) { return 'database' }
        # 3) Expectativa deterministica como ultimo recurso.
        if ($ExpectedAgent -ceq 'explorer') { return 'exploration' }
        if ($ExpectedAgent -ceq 'researcher') { return 'research' }
        if ($ExpectedAgent -ceq 'frontend-engineer') { return 'frontend' }
        if ($ExpectedAgent -ceq 'backend-engineer') { return 'backend' }
        if ($ExpectedAgent -ceq 'database-engineer') { return 'database' }
        if ($ExpectedAgent -ceq 'docs-manager') { return 'documentation' }
        if ($ExpectedAgent -ceq 'product-designer') { return 'product-design' }
        if ($ExpectedAgent -ceq 'requirements-analyst') { return 'requirements' }
        if ($ExpectedAgent -ceq 'engineering-advisor') { return 'engineering-advisory' }
        if ($ExpectedAgent -ceq 'tester') { return 'testing' }
        if ($ExpectedAgent -ceq 'reviewer') { return 'review' }
    }
    catch { }
    return ''
}

function Test-AcceptanceKeyword {
    <#
    .SYNOPSIS
        Matching boundary-aware: keyword simples [a-z0-9]+ casa por PREFIXO DE
        TOKEN (evita falso-positivo como 'senha' dentro de 'desenhar'); keyword
        com espaco/pontuacao casa por substring (frases como 'command injection',
        'opencode.json', 'cve-'). -Exact restringe a igualdade total de token
        (ex.: 'token' nao casa 'tokenizer').
    #>
    [CmdletBinding()]
    param([string]$Blob, [string[]]$Words, [string[]]$Exact = @())
    try {
        $tokens = @(([string]$Blob) -split '[^a-z0-9]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $exactSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($e in @($Exact)) {
            $es = ([string]$e).Trim().ToLowerInvariant()
            if (-not [string]::IsNullOrWhiteSpace($es)) { $exactSet.Add($es) | Out-Null }
        }
        if ($exactSet.Count -gt 0) {
            foreach ($tok in $tokens) { if ($exactSet.Contains($tok)) { return $true } }
        }
        foreach ($w in @($Words)) {
            $kw = ([string]$w).Trim().ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($kw)) { continue }
            if ($kw -match '^[a-z0-9]+$') {
                foreach ($tok in $tokens) { if ($tok.StartsWith($kw)) { return $true } }
            }
            else {
                if (([string]$Blob).Contains($kw)) { return $true }
            }
        }
    }
    catch { }
    return $false
}

function Get-AcceptanceHardExclusions {
    <#
    .SYNOPSIS
        Hard exclusions Stage 1. Retorna tokens canonicos (sem texto livre) e
        se a tarefa esta excluida do controle do Router (deterministic-first).
    #>
    [CmdletBinding()]
    param($Task, $Policy, [string]$ExpectedAgent, [string[]]$RequiredCaps, [string]$ReadWrite)
    $tokens = New-Object System.Collections.Generic.List[string]
    $add = { param([string]$t) if (-not $tokens.Contains($t)) { $tokens.Add($t) | Out-Null } }
    try {
        $obj = [string]$Task.Objective
        $secBlob = ''
        try { $secBlob = (@($Task.SecondaryDomains) | ForEach-Object { [string]$_ }) -join ' ' } catch { $secBlob = '' }
        $blob = ($obj + ' ' + [string]$Task.Domain + ' ' + [string]$Task.TaskType + ' ' + $secBlob).ToLowerInvariant()
        try {
            $fn = Get-Command 'Convert-RouterNormalizedText' -ErrorAction SilentlyContinue
            if ($null -ne $fn) { $blob = Convert-RouterNormalizedText -Text $blob }
        }
        catch { }
        $rw = ([string]$ReadWrite).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($rw)) { try { $rw = ([string]$Task.ReadWrite).Trim().ToLowerInvariant() } catch { } }
        $risk = 'unknown'
        try { $risk = ([string]$Task.Risk).Trim().ToLowerInvariant() } catch { }

        if ($ExpectedAgent -ceq 'security-reviewer') { & $add 'security_sensitive' }

        foreach ($cap in @($RequiredCaps)) {
            $c = ([string]$cap).Trim().ToLowerInvariant()
            if ($c.StartsWith('security.')) { & $add 'security_sensitive' }
            if ($c -ceq 'secrets.read') { & $add 'credentials' }
            if ($c -ceq 'production.destructive') { & $add 'destructive' }
            # H-C (hardening): 'release' gera a capability descritiva
            # production.control, mas aplicacao release NAO e control-plane.
            # control_plane exige tokens explicitos (linha control-plane abaixo:
            # control-plane, capability-flags, capability_router, ativacao...).
            if ($c -ceq 'database.migration') { & $add 'irreversible_migration' }
            if ($c -ceq 'infrastructure.deployment') { & $add 'infra_mutation' }
            if (($c -ceq 'database.write') -and (($risk -ceq 'high') -or ($risk -ceq 'critical'))) { & $add 'destructive' }
        }

        if (Test-AcceptanceKeyword -Blob $blob -Words @('autoridade', 'authority', 'allowlist', 'aprovacao de autoridade', 'authority change', 'mudanca de autoridade')) { & $add 'authority_change' }
        if (Test-AcceptanceKeyword -Blob $blob -Words @('permissao', 'permissoes', 'permission', 'permissions', 'agent.build.permission', 'opencode.json')) { & $add 'permission_change' }
        if (Test-AcceptanceKeyword -Blob $blob -Words @('security', 'seguranca', 'autenticacao', 'authentication', 'autorizacao', 'authorization', 'autentic', 'autoriz', 'vulnerabilidade', 'vulnerability', 'vulnerab', 'owasp', 'pentest', 'exploit', 'csrf', 'xss', 'sqli', 'idor', 'ssrf', 'saml', 'oauth', 'jwt', 'session', 'sessao', 'cookie', 'webhook', '2fa', 'mfa', 'rate limit', 'criptograf', 'encrypt', 'privacidade', 'privacy', 'lgpd', 'pii', 'pci', 'gdpr', 'command injection', 'shell injection', 'code injection', 'code execution', 'remote code execution', 'path traversal', 'traversal', 'deserializ', 'xxe', 'prototype pollution', 'supply chain', 'malware', 'backdoor', 'privilege escalation', 'escalacao de privilegio', 'cve-')) { & $add 'security_sensitive' }
        if (Test-AcceptanceKeyword -Blob $blob -Words @('secret', 'segredo', 'credencial', 'credential', 'password', 'senha', 'api key', 'apikey', 'private key', 'access key', 'chave de acesso', 'refresh token', 'bearer') -Exact @('token', 'tokens')) { & $add 'credentials' }
        if (Test-AcceptanceKeyword -Blob $blob -Words @('destrutiv', 'destructive', 'drop table', 'truncate', 'purge', 'wipe', 'rm -rf', 'delete all', 'apagar tudo')) { & $add 'destructive' }
        if (Test-AcceptanceKeyword -Blob $blob -Words @('irrevers', 'irreversible')) { & $add 'irreversible_migration' }
        # H-C/H3 hardening: release isolado não é mutação nem control-plane.
        if (Test-AcceptanceKeyword -Blob $blob -Words @('deploy', 'deployment', 'producao', 'production', 'rollout', 'terraform apply', 'kubectl apply', 'infra mutation')) { & $add 'infra_mutation' }
        if (Test-AcceptanceKeyword -Blob $blob -Words @('control-plane', 'control plane', 'runtime governance', 'registry governance', 'routing governance', 'ativacao', 'activation', 'capability-flags', 'capability_router')) { & $add 'control_plane' }
        if (Test-AcceptanceKeyword -Blob $blob -Words @('mcp', 'tool execution', 'executar tool', 'execute tool', 'mcp execution')) { & $add 'mcp_execution' }
        if (($rw -ceq 'write') -and (Test-AcceptanceKeyword -Blob $blob -Words @('migra', 'migration', 'migrate'))) { & $add 'irreversible_migration' }
        # Stage 2: high-risk infra write is infra_mutation even without keywords.
        try {
            $dom = ([string]$Task.Domain).Trim().ToLowerInvariant()
            if (($dom -ceq 'infra') -and (($risk -ceq 'high') -or ($risk -ceq 'critical')) -and ($rw -ceq 'write')) { & $add 'infra_mutation' }
        }
        catch { }
    }
    catch { }
    return [PSCustomObject]@{
        Excluded = ($tokens.Count -gt 0)
        Tokens   = [string[]]$tokens.ToArray()
    }
}

function Get-AcceptanceConfidenceGate {
    [CmdletBinding()]
    param([string]$ConfidenceClass)
    try {
        $c = ([string]$ConfidenceClass).Trim().ToLowerInvariant()
        if (($c -ceq 'explicit') -or ($c -ceq 'curated')) { return 'strong' }
        if ($c -ceq 'inferred_high') { return 'acceptable' }
    }
    catch { }
    return 'insufficient'
}

function Get-AcceptanceCandidateView {
    [CmdletBinding()]
    param($Record, $Task, [string[]]$RequiredCaps, [string[]]$Allowlist, $Policy, [bool]$ExecutionRequired, [bool]$Fresh)
    $view = [ordered]@{
        Valid         = $false
        Reasons       = @()
        HardPass      = $false
        Allowlisted   = $false
        Available     = $false
        RoleCompatible = $false
        Forbidden     = $false
        Confidence    = 'unknown'
        Name          = ''
    }
    try {
        if ($null -eq $Record) {
            $view['Reasons'] = @('record_not_found')
            return ([PSCustomObject]$view)
        }
        $name = ([string](Get-AcceptanceNodeProp -Node $Record -Name 'name')).Trim()
        $status = ([string](Get-AcceptanceNodeProp -Node $Record -Name 'status')).Trim().ToLowerInvariant()
        $view['Name'] = $name
        $view['Confidence'] = Get-AcceptanceRecordConfidence -Record $Record
        $hf = Test-RouterHardFilter -Record $Record -Task $Task -RequiredCaps $RequiredCaps -Allowlist $Allowlist -Policy $Policy -ExecutionRequired $ExecutionRequired
        $view['HardPass'] = [bool]$hf.Pass
        $view['Available'] = ($status -ceq 'available')
        $view['Allowlisted'] = (@($Allowlist) -ccontains $name)
        $view['RoleCompatible'] = ((Test-AcceptanceAgentId -Name $name) -and [bool]$view['Allowlisted'])
        $forb = $false
        foreach ($r in @($hf.FailReasons)) { if (([string]$r).StartsWith('permission:forbidden')) { $forb = $true } }
        $view['Forbidden'] = $forb
        $reasons = @()
        foreach ($r in @($hf.FailReasons)) { if (-not [string]::IsNullOrWhiteSpace([string]$r)) { $reasons += [string]$r } }
        if (-not $view['Available']) { $reasons += 'status_not_available' }
        if (-not $view['Allowlisted']) { $reasons += 'not_allowlisted' }
        if (-not $view['RoleCompatible']) { $reasons += 'role_incompatible' }
        if (-not $Fresh) { $reasons += 'registry_not_fresh' }
        $view['Reasons'] = @($reasons)
        $view['Valid'] = ([bool]$hf.Pass -and [bool]$view['Available'] -and [bool]$view['Allowlisted'] -and [bool]$view['RoleCompatible'] -and $Fresh)
    }
    catch {
        $view['Valid'] = $false
        $view['Reasons'] = @('candidate_view_error')
    }
    return ([PSCustomObject]$view)
}

function New-AcceptanceResult {
    [CmdletBinding()]
    param(
        [string]$Mode,
        [bool]$Accepted,
        [string]$SelectedAgent,
        [string]$RouterCandidate,
        [string]$ExpectedAgent,
        [bool]$Direct,
        [bool]$FallbackUsed,
        [string]$FallbackReason,
        [string]$Category,
        [bool]$EnvelopeAllowed,
        [string]$Exclusion,
        [string]$ConfidenceClass,
        [string]$ConfidenceGate,
        [bool]$Disagreement,
        [bool]$Blocked,
        $HardGate,
        $Signals,
        [string]$Reason
    )
    if ([string]::IsNullOrWhiteSpace($ConfidenceClass)) { $ConfidenceClass = 'unknown' }
    if ([string]::IsNullOrWhiteSpace($ConfidenceGate)) { $ConfidenceGate = 'insufficient' }
    if ($null -eq $HardGate) { $HardGate = [ordered]@{ security_required = $false; authority_required = $false; destructive = $false; mcp_execution = $false } }
    if ($null -eq $Signals) { $Signals = [ordered]@{ hard_filter_pass = $false; allowlisted = $false; available = $false; role_compatible = $false; fresh = $false } }
    return [PSCustomObject]@{
        mode               = [string]$Mode
        accepted           = [bool]$Accepted
        selected_agent     = [string]$SelectedAgent
        router_candidate   = [string]$RouterCandidate
        expected_agent     = [string]$ExpectedAgent
        direct             = [bool]$Direct
        fallback_used      = [bool]$FallbackUsed
        fallback_reason    = [string]$FallbackReason
        envelope_stage     = 'stage1'
        envelope_allowed   = [bool]$EnvelopeAllowed
        envelope_category  = [string]$Category
        envelope_exclusion = [string]$Exclusion
        confidence_class   = [string]$ConfidenceClass
        confidence_gate    = [string]$ConfidenceGate
        disagreement       = [bool]$Disagreement
        blocked            = [bool]$Blocked
        hard_gate          = $HardGate
        signals            = $Signals
        reason             = [string]$Reason
    }
}

function Get-AcceptanceHardGate {
    [CmdletBinding()]
    param($ExclusionTokens, [string]$ExpectedAgent, [bool]$McpProposed)
    $toks = @($ExclusionTokens)
    return [ordered]@{
        security_required  = (($ExpectedAgent -ceq 'security-reviewer') -or ($toks -ccontains 'security_sensitive'))
        authority_required = (($toks -ccontains 'authority_change') -or ($toks -ccontains 'permission_change') -or ($toks -ccontains 'control_plane'))
        destructive        = (($toks -ccontains 'destructive') -or ($toks -ccontains 'irreversible_migration') -or ($toks -ccontains 'infra_mutation'))
        mcp_execution      = (($toks -ccontains 'mcp_execution') -or $McpProposed)
    }
}

function New-AcceptanceFallbackResult {
    <#
    .SYNOPSIS
        Fallback deterministico SEGURO: sempre via Get-RouterFallbackResult, que
        respeita a allowlist (agente esperado fora da allowlist => agent=null +
        blocked=true). Nunca recomenda agente proibido/ausente.
    #>
    [CmdletBinding()]
    param(
        $Task,
        $Policy,
        [string[]]$Allowlist,
        [string]$FallbackReason,
        [string]$RouterCandidate,
        [string]$Category,
        [bool]$EnvelopeAllowed,
        [string]$Exclusion,
        [string]$ConfidenceClass,
        [string]$ConfidenceGate,
        $HardGate,
        $Signals,
        [bool]$Disagreement,
        [string]$Reason,
        [bool]$Deterministic,
        [string]$AgentOverride = ''
    )
    $sel = ''
    $blocked = $false
    $direct = $false
    $exp = ''
    try { $exp = Get-RouterExpectedAgent -Task $Task } catch { $exp = '' }
    if (-not [string]::IsNullOrWhiteSpace($AgentOverride)) { $exp = $AgentOverride }
    try {
        $fb = Get-RouterFallbackResult -Task $Task -Policy $Policy -Reason $FallbackReason -FiltersApplied @() -Allowlist $Allowlist -AgentOverride $AgentOverride
        if ($null -ne $fb.route.agent) { $sel = [string]$fb.route.agent }
        try { $blocked = [bool]$fb.blocked } catch { $blocked = $false }
        try { $direct = [bool]$fb.route.direct } catch { $direct = $false }
    }
    catch {
        $sel = ''
        $blocked = $true
    }
    $mode = 'fallback'
    if ($Deterministic) { $mode = 'deterministic' }
    return (New-AcceptanceResult -Mode $mode -Accepted $false -SelectedAgent $sel -Blocked $blocked -RouterCandidate $RouterCandidate -ExpectedAgent $exp -Direct $direct -FallbackUsed $true -FallbackReason $FallbackReason -Category $Category -EnvelopeAllowed $EnvelopeAllowed -Exclusion $Exclusion -ConfidenceClass $ConfidenceClass -ConfidenceGate $ConfidenceGate -Disagreement $Disagreement -HardGate $HardGate -Signals $Signals -Reason $Reason)
}

function Test-AcceptanceVagueTask {
    <#
    .SYNOPSIS
        Guarda de tarefa vaga: objective vazio (sempre vago) ou curto
        (<=20 chars) sem verbo de acao, COM task_type ausente/vago E
        (readwrite ausente OU risk desconhecido). Nunca lanca; em erro
        retorna $false (sem bloqueio).
    #>
    [CmdletBinding()]
    param($Task)
    try {
        $obj = ([string]$Task.Objective).Trim()
        $tt = ([string]$Task.TaskType).Trim().ToLowerInvariant()
        $rw = ([string]$Task.ReadWrite).Trim().ToLowerInvariant()
        $risk = ([string]$Task.Risk).Trim().ToLowerInvariant()
        $objEmpty = [string]::IsNullOrWhiteSpace($obj)
        # Objective vazio e sempre vago, incondicionalmente.
        if ($objEmpty) { return $true }
        $shortVague = $false
        if ($obj.Length -le 20) {
            $norm = $obj.ToLowerInvariant()
            try {
                $fn = Get-Command 'Convert-RouterNormalizedText' -ErrorAction SilentlyContinue
                if ($null -ne $fn) { $norm = Convert-RouterNormalizedText -Text $obj }
            }
            catch { }
            $verbs = @('fazer', 'faca', 'criar', 'crie', 'ler', 'leia', 'corrigir', 'corrija', 'implementar', 'implemente', 'revisar', 'revise', 'pesquisar', 'pesquise', 'analisar', 'analise', 'atualizar', 'atualize', 'validar', 'valide', 'explorar', 'explore', 'esclarecer', 'esclareca', 'avaliar', 'avalie', 'desenhar', 'desenhe', 'definir', 'defina', 'investigar', 'investigue', 'auditar', 'audite', 'alterar', 'altere', 'testar', 'teste', 'documentar', 'documente', 'escrever', 'escreva', 'executar', 'execute', 'configurar', 'configure', 'migrar', 'migre', 'adicionar', 'adicione', 'remover', 'remova', 'listar', 'liste', 'buscar', 'busque', 'gerar', 'gere', 'verificar', 'verifique', 'comparar', 'compare', 'consertar', 'conserte', 'otimizar', 'otimize', 'refatorar', 'refatore', 'publicar', 'publique', 'monitorar', 'monitore', 'medir', 'projetar', 'projete', 'planejar', 'planeje', 'descrever', 'descreva', 'explicar', 'explique', 'compilar', 'compile', 'instalar', 'instale', 'deletar', 'implement', 'review', 'research', 'analyze', 'analyse', 'fix', 'update', 'validate', 'explore', 'clarify', 'assess', 'design', 'define', 'investigate', 'audit', 'change', 'test', 'document', 'write', 'read', 'run', 'execute', 'configure', 'migrate', 'delete', 'remove', 'add', 'list', 'search', 'generate', 'verify', 'compare', 'check', 'build', 'create', 'correct', 'revise')
            $toks = @($norm -split '[^a-z0-9]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $hasVerb = $false
            foreach ($tok in $toks) { if ($verbs -ccontains $tok) { $hasVerb = $true; break } }
            if (-not $hasVerb) { $shortVague = $true }
        }
        if (-not $shortVague) { return $false }
        # Objective vazio e sempre vago, qualquer que seja o task_type.
        if (-not $objEmpty) {
            if (-not ([string]::IsNullOrWhiteSpace($tt) -or ($tt -ceq 'unknown') -or ($tt -ceq 'vague'))) { return $false }
        }
        if ([string]::IsNullOrWhiteSpace($rw)) { return $true }
        if ([string]::IsNullOrWhiteSpace($risk)) { return $true }
        if ($risk -ceq 'unknown') { return $true }
        return $false
    }
    catch { return $false }
}

# Precedence: safety/authority > explicit work-type > envelope > primary domain > secondary > capability > keyword > fallback; keywords nunca vencem sinais estruturados
function Get-AcceptanceDecision {
    <#
    .SYNOPSIS
        Decisao Stage 1. Nunca lanca; em erro interno cai em deterministic fallback.
    #>
    [CmdletBinding()]
    param($Task, $Policy, $Capabilities, [string[]]$Allowlist, [bool]$Fresh, $RouterResult, [bool]$Active, $SimulateEnvelope = $null)
    $emptySignals = [ordered]@{ hard_filter_pass = $false; allowlisted = $false; available = $false; role_compatible = $false; fresh = $false }
    try {
        $expected = Get-RouterExpectedAgent -Task $Task
        $trivial = Test-RouterTrivial -Task $Task -Policy $Policy
        $required = @(Get-RouterRequiredCapabilities -Task $Task -Policy $Policy)
        $exec = Test-RouterExecutionRequired -Task $Task
        $category = Get-AcceptanceTaskCategory -Task $Task -ExpectedAgent $expected
        # Simulacao Stage 2 (inerte por padrao): quando o mapeamento base nao
        # produz categoria e um envelope simulado foi fornecido, aplica o
        # mapeamento simulado. Nunca altera o envelope ativo. Defesa em
        # profundidade: envelope simulado que colida com categoria Stage 1
        # ativa e integralmente ignorado (nunca sobrescreve agentes do
        # envelope ativo).
        $simEnv = $SimulateEnvelope
        if ($null -ne $simEnv) {
            try {
                $baseCats = @(Get-AcceptanceStage1Categories)
                $extraCats = @()
                $extraAgentCats = @()
                if ($simEnv -is [System.Collections.IDictionary]) {
                    if ($simEnv.Contains('ExtraCategories')) { $extraCats = @($simEnv['ExtraCategories']) }
                    if ($simEnv.Contains('ExtraAgents') -and ($simEnv['ExtraAgents'] -is [System.Collections.IDictionary])) { $extraAgentCats = @($simEnv['ExtraAgents'].Keys) }
                }
                else {
                    $pc = $simEnv.PSObject.Properties | Where-Object { $_.Name -ceq 'ExtraCategories' } | Select-Object -First 1
                    if ($null -ne $pc) { $extraCats = @($pc.Value) }
                    $pa = $simEnv.PSObject.Properties | Where-Object { $_.Name -ceq 'ExtraAgents' } | Select-Object -First 1
                    if (($null -ne $pa) -and ($null -ne $pa.Value) -and ($pa.Value -is [System.Collections.IDictionary])) { $extraAgentCats = @($pa.Value.Keys) }
                }
                $extraMapDests = @()
                try {
                    $tm = $null
                    if ($simEnv -is [System.Collections.IDictionary]) {
                        if ($simEnv.Contains('ExtraTaskMap')) { $tm = $simEnv['ExtraTaskMap'] }
                    }
                    else {
                        $pt = $simEnv.PSObject.Properties | Where-Object { $_.Name -ceq 'ExtraTaskMap' } | Select-Object -First 1
                        if ($null -ne $pt) { $tm = $pt.Value }
                    }
                    if ($null -ne $tm) {
                        $tables = @()
                        if ($tm -is [System.Collections.IDictionary]) {
                            foreach ($tk in @('TaskTypes', 'Domains', 'ExpectedAgents')) {
                                if ($tm.Contains($tk) -and ($null -ne $tm[$tk])) { $tables += $tm[$tk] }
                            }
                        }
                        foreach ($table in $tables) {
                            if ($table -is [System.Collections.IDictionary]) {
                                foreach ($kk in @($table.Keys)) { $extraMapDests += [string]$table[$kk] }
                            }
                        }
                    }
                }
                catch { }
                foreach ($c in @($extraCats + $extraAgentCats + $extraMapDests)) {
                    if ($baseCats -ccontains ([string]$c).Trim().ToLowerInvariant()) { $simEnv = $null; break }
                }
            }
            catch { $simEnv = $null }
        }
        if ([string]::IsNullOrWhiteSpace($category) -and ($null -ne $simEnv)) {
            $category = Get-SimulatedTaskCategory -Task $Task -ExpectedAgent $expected -SimulateEnvelope $simEnv
        }
        $routerCandidate = ''
        $routerFallback = $true
        if ($null -ne $RouterResult) {
            try { if (-not [bool]$RouterResult.fallback_used) { $routerFallback = $false } } catch { $routerFallback = $true }
            try { if ([bool]$RouterResult.route.direct) { $routerFallback = $true } } catch { }
            try { $routerCandidate = [string]$RouterResult.route.agent } catch { $routerCandidate = '' }
        }
        $mcpsProposed = $false
        try { if (@($RouterResult.route.mcps).Count -gt 0) { $mcpsProposed = $true } } catch { }
        # GATE PRIMEIRO (Rev/Sec HIGH): hard exclusions e precedencia de
        # seguranca vencem kill switch, trivialidade, ausencia de candidato e
        # envelope. Trabalho security-sensitive cai deterministicamente no
        # security-reviewer mesmo sem marcador de seguranca no dominio primario
        # (ex.: security apenas em secondary_domains).
        $excl = Get-AcceptanceHardExclusions -Task $Task -Policy $Policy -ExpectedAgent $expected -RequiredCaps $required -ReadWrite '' 
        $hardGate = Get-AcceptanceHardGate -ExclusionTokens @($excl.Tokens) -ExpectedAgent $expected -McpProposed $mcpsProposed
        $secOverride = ''
        if ([bool]$hardGate.security_required) { $secOverride = 'security-reviewer' }
        if ($excl.Excluded) {
            $first = ''
            if (@($excl.Tokens).Count -gt 0) { $first = [string](@($excl.Tokens)[0]) }
            $fallbackReason = 'hard_exclusion_' + $first
            return (New-AcceptanceFallbackResult -Task $Task -Policy $Policy -Allowlist $Allowlist -FallbackReason $fallbackReason -RouterCandidate $routerCandidate -Category $category -EnvelopeAllowed $false -Exclusion $first -ConfidenceClass 'unknown' -ConfidenceGate 'insufficient' -HardGate $hardGate -Signals $emptySignals -Disagreement $false -Reason 'hard_exclusion' -AgentOverride $secOverride)
        }
        if ($expected -ceq 'security-reviewer') {
            return (New-AcceptanceFallbackResult -Task $Task -Policy $Policy -Allowlist $Allowlist -FallbackReason 'security_precedence' -RouterCandidate $routerCandidate -Category $category -EnvelopeAllowed $false -Exclusion 'security_sensitive' -ConfidenceClass 'unknown' -ConfidenceGate 'insufficient' -HardGate $hardGate -Signals $emptySignals -Disagreement $false -Reason 'security_precedence' -AgentOverride 'security-reviewer')
        }
        # Vague-task guard (nao bloqueia; fallback deterministico): tarefa
        # subespecificada com escrita/risco desconhecido cai em fallback
        # antes do kill switch, sem mascarar hard exclusions/seguranca.
        # Objective vazio e sempre vago, incondicionalmente: sem objetivo nao
        # ha escopo localizavel, qualquer que seja risk/readwrite/task_type.
        $objEmpty = $false
        try { $objEmpty = [string]::IsNullOrWhiteSpace([string]$Task.Objective) } catch { $objEmpty = $false }
        if ($objEmpty) {
            return (New-AcceptanceFallbackResult -Task $Task -Policy $Policy -Allowlist $Allowlist -FallbackReason 'vague_task_underspecified' -RouterCandidate $routerCandidate -Category $category -EnvelopeAllowed $false -Exclusion 'vague_task_underspecified' -ConfidenceClass 'unknown' -ConfidenceGate 'insufficient' -HardGate $hardGate -Signals $emptySignals -Disagreement $false -Reason 'vague_task_guard')
        }
        $vagueTask = Test-AcceptanceVagueTask -Task $Task
        $rwNorm = ''
        $riskNorm = 'unknown'
        try { $rwNorm = ([string]$Task.ReadWrite).Trim().ToLowerInvariant() } catch { $rwNorm = '' }
        try { $riskNorm = ([string]$Task.Risk).Trim().ToLowerInvariant() } catch { $riskNorm = 'unknown' }
        if ([string]::IsNullOrWhiteSpace($riskNorm)) { $riskNorm = 'unknown' }
        $rwWriteLike = (([string]::IsNullOrWhiteSpace($rwNorm)) -or ($rwNorm -ceq 'unknown') -or ($rwNorm -ceq 'write'))
        if ($vagueTask -and $rwWriteLike -and (($riskNorm -ceq 'unknown') -or ($riskNorm -ceq 'high'))) {
            return (New-AcceptanceFallbackResult -Task $Task -Policy $Policy -Allowlist $Allowlist -FallbackReason 'vague_task_underspecified' -RouterCandidate $routerCandidate -Category $category -EnvelopeAllowed $false -Exclusion 'vague_task_underspecified' -ConfidenceClass 'unknown' -ConfidenceGate 'insufficient' -HardGate $hardGate -Signals $emptySignals -Disagreement $false -Reason 'vague_task_guard')
        }
        if (-not $Active) {
            return (New-AcceptanceFallbackResult -Task $Task -Policy $Policy -Allowlist $Allowlist -FallbackReason 'router_inactive' -RouterCandidate '' -Category $category -EnvelopeAllowed $false -Exclusion 'router_inactive' -ConfidenceClass 'unknown' -ConfidenceGate 'insufficient' -HardGate $hardGate -Signals $emptySignals -Disagreement $false -Reason 'kill_switch_deterministic' -Deterministic $true)
        }
        if ($trivial) {
            return (New-AcceptanceResult -Mode 'deterministic' -Accepted $false -SelectedAgent 'build' -RouterCandidate '' -ExpectedAgent $expected -Direct $true -FallbackUsed $false -FallbackReason '' -Category '' -EnvelopeAllowed $false -Exclusion 'trivial_direct' -Reason 'trivial_direct')
        }
        if ($routerFallback -or [string]::IsNullOrWhiteSpace($routerCandidate)) {
            return (New-AcceptanceFallbackResult -Task $Task -Policy $Policy -Allowlist $Allowlist -FallbackReason 'router_no_candidate' -RouterCandidate $routerCandidate -Category $category -EnvelopeAllowed $false -Exclusion 'router_no_candidate' -ConfidenceClass 'unknown' -ConfidenceGate 'insufficient' -HardGate $hardGate -Signals $emptySignals -Disagreement $false -Reason 'router_no_candidate')
        }
        if ([string]::IsNullOrWhiteSpace($category)) {
            return (New-AcceptanceFallbackResult -Task $Task -Policy $Policy -Allowlist $Allowlist -FallbackReason 'category_not_in_stage1' -RouterCandidate $routerCandidate -Category '' -EnvelopeAllowed $false -Exclusion 'category_not_in_stage1' -ConfidenceClass 'unknown' -ConfidenceGate 'insufficient' -HardGate $hardGate -Signals $emptySignals -Disagreement $false -Reason 'category_not_in_stage1')
        }
        $allowedAgents = @(Get-AcceptanceCategoryAgents -Category $category)
        # Simulacao Stage 2: agentes permitidos do envelope simulado
        # substituem os da categoria quando fornecidos. Inerte por padrao;
        # $simEnv ja exclui colisao com o envelope ativo (ver acima).
        if ($null -ne $simEnv) {
            try {
                $extra = $null
                if ($simEnv -is [System.Collections.IDictionary]) {
                    if ($simEnv.Contains('ExtraAgents')) { $extra = $simEnv['ExtraAgents'] }
                }
                else {
                    $px = $simEnv.PSObject.Properties | Where-Object { $_.Name -ceq 'ExtraAgents' } | Select-Object -First 1
                    if ($null -ne $px) { $extra = $px.Value }
                }
                if ($null -ne $extra) {
                    if ($extra -is [System.Collections.IDictionary]) {
                        foreach ($k in @($extra.Keys)) {
                            if (([string]$k).Trim().ToLowerInvariant() -ceq ([string]$category).Trim().ToLowerInvariant()) {
                                $allowedAgents = @($extra[$k])
                                break
                            }
                        }
                    }
                }
            }
            catch { }
        }
        if (($allowedAgents.Count -gt 0) -and ($allowedAgents -cnotcontains $routerCandidate)) {
            return (New-AcceptanceFallbackResult -Task $Task -Policy $Policy -Allowlist $Allowlist -FallbackReason 'candidate_out_of_envelope' -RouterCandidate $routerCandidate -Category $category -EnvelopeAllowed $false -Exclusion 'candidate_out_of_envelope' -ConfidenceClass 'unknown' -ConfidenceGate 'insufficient' -HardGate $hardGate -Signals $emptySignals -Disagreement $false -Reason 'candidate_out_of_envelope')
        }
        $rec = Get-AcceptanceAgentRecord -Capabilities $Capabilities -Name $routerCandidate
        $cv = Get-AcceptanceCandidateView -Record $rec -Task $Task -RequiredCaps $required -Allowlist $Allowlist -Policy $Policy -ExecutionRequired $exec -Fresh $Fresh
        $signals = [ordered]@{
            hard_filter_pass = [bool]$cv.HardPass
            allowlisted      = [bool]$cv.Allowlisted
            available        = [bool]$cv.Available
            role_compatible  = [bool]$cv.RoleCompatible
            fresh            = [bool]$Fresh
        }
        $conf = [string]$cv.Confidence
        $gate = Get-AcceptanceConfidenceGate -ConfidenceClass $conf
        if ($gate -ceq 'insufficient') {
            return (New-AcceptanceFallbackResult -Task $Task -Policy $Policy -Allowlist $Allowlist -FallbackReason 'confidence_insufficient' -RouterCandidate $routerCandidate -Category $category -EnvelopeAllowed $true -Exclusion '' -ConfidenceClass $conf -ConfidenceGate $gate -HardGate $hardGate -Signals $signals -Disagreement $false -Reason 'confidence_insufficient')
        }
        if (-not [bool]$cv.Valid) {
            $first = ''
            if (@($cv.Reasons).Count -gt 0) { $first = [string](@($cv.Reasons)[0]) }
            $fallbackReason = 'candidate_invalid_' + (Get-AcceptanceReasonToken -Text $first)
            return (New-AcceptanceFallbackResult -Task $Task -Policy $Policy -Allowlist $Allowlist -FallbackReason $fallbackReason -RouterCandidate $routerCandidate -Category $category -EnvelopeAllowed $true -Exclusion '' -ConfidenceClass $conf -ConfidenceGate $gate -HardGate $hardGate -Signals $signals -Disagreement $false -Reason 'candidate_invalid')
        }
        $disagreement = ($routerCandidate -cne $expected)
        if ($disagreement -and ($gate -cne 'strong')) {
            return (New-AcceptanceFallbackResult -Task $Task -Policy $Policy -Allowlist $Allowlist -FallbackReason 'router_disagreement_weak' -RouterCandidate $routerCandidate -Category $category -EnvelopeAllowed $true -Exclusion '' -ConfidenceClass $conf -ConfidenceGate $gate -HardGate $hardGate -Signals $signals -Disagreement $true -Reason 'router_disagreement_weak')
        }
        return (New-AcceptanceResult -Mode 'active' -Accepted $true -SelectedAgent $routerCandidate -Blocked $false -RouterCandidate $routerCandidate -ExpectedAgent $expected -Direct $false -FallbackUsed $false -FallbackReason '' -Category $category -EnvelopeAllowed $true -Exclusion '' -ConfidenceClass $conf -ConfidenceGate $gate -Disagreement $disagreement -HardGate $hardGate -Signals $signals -Reason 'accepted_stage1')
    }
    catch {
        $exp = ''
        try { $exp = Get-RouterExpectedAgent -Task $Task } catch { $exp = '' }
        return (New-AcceptanceFallbackResult -Task $Task -Policy $Policy -Allowlist $Allowlist -FallbackReason 'acceptance_internal_error' -RouterCandidate '' -Category '' -EnvelopeAllowed $false -Exclusion 'acceptance_internal_error' -ConfidenceClass 'unknown' -ConfidenceGate 'insufficient' -HardGate $null -Signals $emptySignals -Disagreement $false -Reason 'acceptance_internal_error')
    }
}

function ConvertTo-AcceptanceSkillIds {
    [CmdletBinding()]
    param($Ids)
    $out = @()
    foreach ($v in @($Ids)) {
        $s = ([string]$v).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        if ($s -match '^[a-z][a-z0-9-]{0,63}$') { $out += ('skill:' + $s) }
    }
    return @($out)
}

function ConvertTo-AcceptanceMcpIds {
    [CmdletBinding()]
    param($Ids)
    $out = @()
    foreach ($v in @($Ids)) {
        $s = ([string]$v).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        if ($s -match '^[a-z][a-z0-9-]{0,63}$') { $out += ('mcp:' + $s) }
    }
    return @($out)
}

function ConvertTo-AcceptanceTelemetry {
    [CmdletBinding()]
    param($Decision, $Task, [string]$TaskId, [hashtable]$Latency, $RouterResult)
    $cand = ''
    if (Test-AcceptanceAgentId -Name ([string]$Decision.router_candidate)) { $cand = [string]$Decision.router_candidate }
    $sel = ''
    if (Test-AcceptanceAgentId -Name ([string]$Decision.selected_agent)) { $sel = [string]$Decision.selected_agent }
    $exp = ''
    if (Test-AcceptanceAgentId -Name ([string]$Decision.expected_agent)) { $exp = [string]$Decision.expected_agent }
    $skills = @()
    $mcps = @()
    try { $skills = @(ConvertTo-AcceptanceSkillIds -Ids @($RouterResult.route.skills)) } catch { $skills = @() }
    try { $mcps = @(ConvertTo-AcceptanceMcpIds -Ids @($RouterResult.route.mcps)) } catch { $mcps = @() }
    $secondary = @()
    try {
        foreach ($d in @($Task.SecondaryDomains)) {
            $t = Get-AcceptanceSafeToken -Text ([string]$d)
            if (-not [string]::IsNullOrWhiteSpace($t)) { $secondary += $t }
        }
    }
    catch { $secondary = @() }
    $registryLoad = 0; $routerMs = 0; $totalMs = 0
    try { if ($null -ne $Latency) { if ($Latency.ContainsKey('registry_load_ms')) { $registryLoad = [int]$Latency['registry_load_ms'] } } } catch { }
    try { if ($null -ne $Latency) { if ($Latency.ContainsKey('router_ms')) { $routerMs = [int]$Latency['router_ms'] } } } catch { }
    try { if ($null -ne $Latency) { if ($Latency.ContainsKey('total_ms')) { $totalMs = [int]$Latency['total_ms'] } } } catch { }
    return [ordered]@{
        schema_version     = 1
        event_type         = 'acceptance'
        ts                 = ([DateTimeOffset]::UtcNow.ToString('o'))
        task_id_hash       = (Get-AcceptanceTaskIdHash -TaskId $TaskId)
        task_type          = (Get-AcceptanceSafeToken -Text ([string]$Task.TaskType))
        domain             = (Get-AcceptanceSafeToken -Text ([string]$Task.Domain))
        secondary_domains  = @($secondary)
        risk               = (Get-AcceptanceRisk -Risk ([string]$Task.Risk))
        mode               = (Get-AcceptanceSafeToken -Text ([string]$Decision.mode))
        accepted           = [bool]$Decision.accepted
        blocked            = [bool]$Decision.blocked
        fallback_used      = [bool]$Decision.fallback_used
        fallback_reason    = (Get-AcceptanceReasonToken -Text ([string]$Decision.fallback_reason))
        router_candidate   = $cand
        expected_agent     = $exp
        selected_agent     = $sel
        envelope_stage     = 'stage1'
        envelope_allowed   = [bool]$Decision.envelope_allowed
        envelope_category  = (Get-AcceptanceToken -Text ([string]$Decision.envelope_category))
        envelope_exclusion = (Get-AcceptanceReasonToken -Text ([string]$Decision.envelope_exclusion))
        confidence_class   = (Get-AcceptanceToken -Text ([string]$Decision.confidence_class))
        disagreement       = [bool]$Decision.disagreement
        hard_gate          = [ordered]@{
            security_required  = [bool]$Decision.hard_gate.security_required
            authority_required = [bool]$Decision.hard_gate.authority_required
            destructive        = [bool]$Decision.hard_gate.destructive
            mcp_execution      = [bool]$Decision.hard_gate.mcp_execution
        }
        signals            = [ordered]@{
            hard_filter_pass = [bool]$Decision.signals.hard_filter_pass
            allowlisted      = [bool]$Decision.signals.allowlisted
            available        = [bool]$Decision.signals.available
            role_compatible  = [bool]$Decision.signals.role_compatible
            fresh            = [bool]$Decision.signals.fresh
        }
        skills_suggested   = @($skills)
        mcps_suggested     = @($mcps)
        latency_ms         = [ordered]@{ registry_load_ms = $registryLoad; router_ms = $routerMs; total_ms = $totalMs }
        warnings           = @()
    }
}

function Test-AcceptanceConfinedPath {
    [CmdletBinding()]
    param([string]$Path, [string]$AllowedDir, [string]$RepoRoot)
    try {
        $full = ''
        if ([IO.Path]::IsPathRooted($Path)) { $full = [IO.Path]::GetFullPath($Path) }
        else { $full = [IO.Path]::GetFullPath((Join-Path $RepoRoot $Path)) }
        $base = [IO.Path]::GetFullPath($AllowedDir)
        $sep = $base.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if ($full.StartsWith($sep, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    catch { }
    return $false
}

function Test-AcceptancePathHasReparsePoint {
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

function Get-AcceptanceDefaultTelemetryPath {
    [CmdletBinding()]
    param([string]$RepoRoot)
    $repo = Get-AcceptanceRepoRoot -RepoRoot $RepoRoot
    $stamp = ([DateTimeOffset]::UtcNow.ToString('yyyyMMdd'))
    return (Join-Path $repo ('cache\v3\telemetry\acceptance-' + $stamp + '.jsonl'))
}

function Write-AcceptanceTelemetry {
    <#
    .SYNOPSIS
        Append sanitizado, confinado e fail-closed. Retorna $true/$false, nunca lanca.
    #>
    [CmdletBinding()]
    param([hashtable]$Line, [string]$TelemetryPath, [string]$RepoRoot)
    try {
        $repo = Get-AcceptanceRepoRoot -RepoRoot $RepoRoot
        $path = $TelemetryPath
        if ([string]::IsNullOrWhiteSpace($path)) { $path = Get-AcceptanceDefaultTelemetryPath -RepoRoot $repo }
        $allowed = Join-Path $repo 'cache\v3\telemetry'
        if (-not (Test-AcceptanceConfinedPath -Path $path -AllowedDir $allowed -RepoRoot $repo)) { return $false }
        $full = ''
        if ([IO.Path]::IsPathRooted($path)) { $full = [IO.Path]::GetFullPath($path) } else { $full = [IO.Path]::GetFullPath((Join-Path $repo $path)) }
        if (Test-AcceptancePathHasReparsePoint -Path $full) { return $false }
        $dir = Split-Path -Parent $full
        if (-not [string]::IsNullOrWhiteSpace($dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $json = ($Line | ConvertTo-Json -Depth 10 -Compress)
        [IO.File]::AppendAllText($full, ($json + "`n"), [Text.UTF8Encoding]::new($false))
        return $true
    }
    catch { return $false }
}

function Read-AcceptanceFlags {
    [CmdletBinding()]
    param([string]$FlagsPath, [string]$RepoRoot)
    $repo = Get-AcceptanceRepoRoot -RepoRoot $RepoRoot
    $resolved = $FlagsPath
    if ([string]::IsNullOrWhiteSpace($resolved)) { $resolved = Join-Path $repo 'source\registry\capability-flags.json' }
    $active = $false
    try {
        if (Test-Path -LiteralPath $resolved -PathType Leaf) {
            $doc = ([IO.File]::ReadAllText($resolved, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json)
            $n = Get-AcceptanceNodeProp -Node $doc -Name 'capability_router'
            $a = Get-AcceptanceNodeProp -Node $n -Name 'active'
            if ($a -is [bool] -and $a -eq $true) { $active = $true }
        }
    }
    catch { }
    return [PSCustomObject]@{ Active = [bool]$active; Path = $resolved }
}

function Invoke-CapabilityAcceptance {
    <#
    .SYNOPSIS
        Executor Stage-1. Le flags (capability_router.active), roda o Router V1
        quando ativo e decide accept/fallback/deterministic. Nunca lanca.
    #>
    [CmdletBinding()]
    param(
        $Task,
        [string]$PolicyPath,
        [string]$RegistryPath,
        [string]$FlagsPath,
        [string]$ConfigPath,
        [string]$TelemetryPath,
        [bool]$NoTelemetry,
        [string]$RepoRoot,
        [int]$MaxAgeSeconds = -1,
        [string]$TaskId,
        $SimulateEnvelope = $null
    )
    $repo = Get-AcceptanceRepoRoot -RepoRoot $RepoRoot
    $total = [System.Diagnostics.Stopwatch]::StartNew()
    $regMs = 0
    $routerMs = 0
    $policy = $null
    $registryOk = $false
    $fresh = $false
    $decision = $null
    $routerResult = $null
    try {
        $flagView = Read-AcceptanceFlags -FlagsPath $FlagsPath -RepoRoot $repo
        $active = [bool]$flagView.Active
        $cfg = $ConfigPath
        if ([string]::IsNullOrWhiteSpace($cfg)) { $cfg = Join-Path $env:USERPROFILE '.config\opencode\opencode.json' }
        $allowlist = @(Get-RouterAllowlist -ConfigPath $cfg)
        if (-not $active) {
            $decision = Get-AcceptanceDecision -Task $Task -Policy $null -Capabilities @() -Allowlist $allowlist -Fresh $false -RouterResult $null -Active $false
        }
        else {
            try { $policy = Import-RouterPolicy -PolicyPath $PolicyPath -RepoRoot $repo }
            catch { $policy = $null }
            $regWatch = [System.Diagnostics.Stopwatch]::StartNew()
            $reg = $null
            try { $reg = Read-RouterRegistry -RegistryPath $RegistryPath -RepoRoot $repo -Policy $policy -MaxAgeSeconds $MaxAgeSeconds } catch { $reg = $null }
            $regWatch.Stop()
            $regMs = [int]$regWatch.ElapsedMilliseconds
            $regAvail = $false
            $regStale = $true
            $caps = @()
            if ($null -ne $reg) {
                try { $regAvail = [bool]$reg.Available } catch { $regAvail = $false }
                try { $regStale = [bool]$reg.Stale } catch { $regStale = $true }
                try { $caps = @($reg.Capabilities) } catch { $caps = @() }
                try { $fresh = [bool]$reg.Fresh } catch { $fresh = $false }
            }
            $registryOk = ($regAvail -and (-not $regStale))
            if ((-not $registryOk) -or ($null -eq $policy)) {
                $reason = 'fallback_registry_unavailable'
                if ($null -eq $policy) { $reason = 'fallback_policy_unavailable' }
                elseif ($regStale) { $reason = 'fallback_registry_stale' }
                $decision = New-AcceptanceFallbackResult -Task $Task -Policy $policy -Allowlist $allowlist -FallbackReason $reason -RouterCandidate '' -Category '' -EnvelopeAllowed $false -Exclusion $reason -ConfidenceClass 'unknown' -ConfidenceGate 'insufficient' -HardGate $null -Signals $null -Disagreement $false -Reason $reason
            }
            else {
                # Executor offline/puro: Invoke-RouterRoute e scoring
                # deterministico em-processo (sem spawn de jobs ou
                # processos, sem rede; inputs limitados: TaskFile ~16KB,
                # profundidade <=10, arrays <=100). Sem vetores de hang:
                # excecao cai em acceptance_internal_error; o caminho
                # isolado (shadow bridge) tem timeout proprio de 20s.
                $routerWatch = [System.Diagnostics.Stopwatch]::StartNew()
                try { $routerResult = Invoke-RouterRoute -Task $Task -Policy $policy -Capabilities $caps -Allowlist $allowlist -Fresh $fresh -StaleReasons @() }
                catch { $routerResult = $null }
                $routerWatch.Stop()
                $routerMs = [int]$routerWatch.ElapsedMilliseconds
                $decision = Get-AcceptanceDecision -Task $Task -Policy $policy -Capabilities $caps -Allowlist $allowlist -Fresh $fresh -RouterResult $routerResult -Active $true -SimulateEnvelope $SimulateEnvelope
            }
        }
    }
    catch {
        $al = @()
        try { $al = @($allowlist) } catch { $al = @() }
        $decision = New-AcceptanceFallbackResult -Task $Task -Policy $policy -Allowlist $al -FallbackReason 'acceptance_internal_error' -RouterCandidate '' -Category '' -EnvelopeAllowed $false -Exclusion 'acceptance_internal_error' -ConfidenceClass 'unknown' -ConfidenceGate 'insufficient' -HardGate $null -Signals $null -Disagreement $false -Reason 'acceptance_internal_error'
    }
    finally { $total.Stop() }
    $latency = @{ registry_load_ms = $regMs; router_ms = $routerMs; total_ms = [int]$total.ElapsedMilliseconds }
    $tid = $TaskId
    if ([string]::IsNullOrWhiteSpace($tid)) { try { $tid = [string]$Task.Project } catch { $tid = '' } }
    if (-not $NoTelemetry) {
        try {
            $line = ConvertTo-AcceptanceTelemetry -Decision $decision -Task $Task -TaskId $tid -Latency $latency -RouterResult $routerResult
            Write-AcceptanceTelemetry -Line $line -TelemetryPath $TelemetryPath -RepoRoot $repo | Out-Null
        }
        catch { }
    }
    return [PSCustomObject]@{
        decision = $decision
        latency = [PSCustomObject]$latency
        registry_fresh = [bool]$fresh
        registry_ok = [bool]$registryOk
        policy_available = ($null -ne $policy)
    }
}
