<#!
.SYNOPSIS
    V3 Capability Shadow bridge lib: consulta shadow-only ao Router V1 (Phase 9).
    .DESCRIPTION
    Biblioteca dot-sourceable (sem execucao ao carregar). Implementa a bridge
    executavel de live shadow do Planner para o Router V1:

      - Kill switch ESTRITO: se capability_router.shadow nao for boolean
        $true (ex.: string "false", 1, $null), retorna disabled sem consultar
        o Router e sem telemetria. Tipo invalido nunca habilita.
      - Consulta unica por chamada ao Router V1, por DEFAULT em processo
        isolado com timeout rigido (default 20s, 1..60): o contexto minimo
        e passado ao filho por STDIN (JSON), sem arquivo temporario com
        objective; kill no timeout => status timeout. Modo no-processo
        apenas opt-in (-InProcess), documentado como SEM timeout rigido
        (serve so para testes de velocidade), nunca como default.
      - Validacao de contexto ANTES de qualquer temp/stdin: task_id por
        regex de ID; objective truncado em 500 chars com redacao de
        padroes de segredo; domain_hints/constraints com cardinalidade e
        limite; skills/propostas por ID canonico. Rejeita/redige antes de
        criar temp ou stdin.
      - Dedupe por subtarefa: TTL curto por task_id (60s) em state file
        cache\v3\telemetry\.shadow-seen.json; repeticao dentro do TTL =>
        deduped=$true sem nova consulta ao Router (telemetria registra
        deduped); -AllowRepeat forca nova consulta. Repeticao fora do TTL
        gera warning.
      - Freshness via contrato do router (Read-RouterRegistry): ausente ou
        corrompido => failed + warning 'shadow unavailable'; STALE =>
        status degraded (novo estado) com proposed_agent=null,
        comparison NOT_COMPARABLE, fallback_used=true e warning
        'registry stale'. Nunca EQUAL/V3_BETTER/V3_WORSE em stale.
      - Comparacao nao-cega: EQUAL / V3_BETTER / V3_WORSE / UNCLEAR /
        NOT_COMPARABLE. EQUAL/V3_BETTER/V3_WORSE somente quando status
        e success e proposed_agent existir; falha/timeout/disabled/
        degraded/deduped ou proposta ausente => NOT_COMPARABLE
        (nunca V3_BETTER/WORSE). Sem expected_agent nunca afirma
        V3_BETTER/WORSE.
      - Telemetria JSONL append sanitizada por allowlist (fail-closed);
        DTO JSON estavel com arrays sempre como arrays (sem
        {value,Count}); registra apenas IDs canonicos/hashes, nunca
        objective, prompts, secrets, descricoes, content ou valores
        livres. Inclui flag deduped.
      - Nao altera config, agentes, flags; nao carrega skills; nao executa
        propostas; nao instrui o Planner vivo. Somente shadow.

    PowerShell 5.1 compativel. ASCII-only de proposito.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$__shadowRouterLib = Join-Path $PSScriptRoot 'CapabilityRouter.ps1'
if (Test-Path -LiteralPath $__shadowRouterLib -PathType Leaf) {
    . $__shadowRouterLib
}
$__shadowSanitizeLib = Join-Path $PSScriptRoot 'CapabilitySanitize.ps1'
if (Test-Path -LiteralPath $__shadowSanitizeLib -PathType Leaf) {
    . $__shadowSanitizeLib
}

function Get-ShadowRepoRoot {
    [CmdletBinding()]
    param([string]$RepoRoot)
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { return $RepoRoot }
    return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
}

function Read-ShadowUtf8Text {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))
}

function Read-ShadowFlags {
    [CmdletBinding()]
    param([string]$FlagsPath, [string]$RepoRoot)
    $resolved = $FlagsPath
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        $resolved = Join-Path (Get-ShadowRepoRoot -RepoRoot $RepoRoot) 'source\registry\capability-flags.json'
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { return $null }
    try {
        $text = Read-ShadowUtf8Text -Path $resolved
        return ($text | ConvertFrom-Json)
    }
    catch { return $null }
}

function Test-ShadowEnabled {
    <#
    .SYNOPSIS
        Kill switch ESTRITO: so boolean $true habilita. Qualquer outro
        tipo ou valor (string "false"/"true", int, $null) => desabilitado.
    #>
    [CmdletBinding()]
    param($Flags)
    if ($null -eq $Flags) { return $false }
    try {
        $node = $null
        if ($Flags -is [System.Collections.IDictionary]) {
            if ($Flags.Contains('capability_router')) { $node = $Flags['capability_router'] }
        }
        else {
            $p = $Flags.PSObject.Properties | Where-Object { $_.Name -ceq 'capability_router' } | Select-Object -First 1
            if ($null -ne $p) { $node = $p.Value }
        }
        if ($null -eq $node) { return $false }
        $value = $null
        if ($node -is [System.Collections.IDictionary]) {
            if ($node.Contains('shadow')) { $value = $node['shadow'] }
        }
        else {
            $p2 = $node.PSObject.Properties | Where-Object { $_.Name -ceq 'shadow' } | Select-Object -First 1
            if ($null -ne $p2) { $value = $p2.Value }
        }
        if ($value -is [bool] -and $value -eq $true) { return $true }
    }
    catch { }
    return $false
}

function Test-ShadowTaskId {
    <#
    .SYNOPSIS
        Valida task_id por regex de ID: inicia com alfanumerico, depois
        alfanumerico, ponto, underscore ou hifen, ate 64 chars.
    #>
    [CmdletBinding()]
    param([string]$TaskId)
    if ([string]::IsNullOrWhiteSpace($TaskId)) { return $false }
    $s = ([string]$TaskId).Trim()
    if ($s.Length -gt 64) { return $false }
    return ($s -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')
}

function Test-ShadowCanonicalId {
    <#
    .SYNOPSIS
        Valida ID canonico (agente/skill/capability curta): alfanumerico
        inicial, depois alfanumerico, ponto, underscore, hifen ou dois
        pontos, ate 64 chars.
    #>
    [CmdletBinding()]
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
    $s = ([string]$Id).Trim()
    if ($s.Length -gt 64) { return $false }
    return ($s -match '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$')
}

function Get-ShadowSecretPattern {
    [CmdletBinding()]
    param()
    try {
        $fn = Get-Command 'Get-SecretValuePattern' -ErrorAction SilentlyContinue
        if ($null -ne $fn) { return (Get-SecretValuePattern) }
    }
    catch { }
    return 'Bearer\s+[A-Za-z0-9\-._~+/=]{8,}|sk-[A-Za-z0-9]{10,}'
}

function Get-ShadowRedactedText {
    <#
    .SYNOPSIS
        Redige padroes de segredo em texto livre (substring => [REDACTED]).
    #>
    [CmdletBinding()]
    param([string]$Text)
    $s = [string]$Text
    if ([string]::IsNullOrEmpty($s)) { return '' }
    try {
        $pattern = Get-ShadowSecretPattern
        return ($s -replace $pattern, '[REDACTED]')
    }
    catch { return $s }
}

function Get-ShadowSanitizedObjective {
    <#
    .SYNOPSIS
        Objective sanitizado para encaminhar ao Router: redacao de
        segredos + truncamento em 500 chars.
    #>
    [CmdletBinding()]
    param([string]$Objective)
    $s = Get-ShadowRedactedText -Text ([string]$Objective)
    $s = $s.Trim()
    if ($s.Length -gt 500) { $s = $s.Substring(0, 500) }
    return $s
}

function ConvertTo-ShadowStringArray {
    <#
    .SYNOPSIS
        Achata qualquer enumeravel aninhado (List, ArrayList, array) em
        [string[]] plano. Garante DTO JSON estavel (sem {value,Count}).
        Limites defensivos (FIX2/FIX4): no maximo 100 itens, profundidade
        maxima 10; alem disso trunca (fail-safe, sem lancar).
    #>
    [CmdletBinding()]
    param($InputObject, [int]$MaxItems = 100, [int]$MaxDepth = 10)
    $out = New-Object System.Collections.Generic.List[string]
    try {
        if ($MaxItems -lt 1) { $MaxItems = 100 }
        if ($MaxDepth -lt 1) { $MaxDepth = 10 }
        $stack = New-Object System.Collections.Generic.Stack[object]
        foreach ($v in @($InputObject)) { $stack.Push(@{ Value = $v; Depth = 0 }) }
        while ($stack.Count -gt 0 -and $out.Count -lt $MaxItems) {
            $frame = $stack.Pop()
            $cur = $frame.Value
            $depth = [int]$frame.Depth
            if ($null -eq $cur) { continue }
            if ($cur -is [string]) {
                $t = ([string]$cur).Trim()
                if (-not [string]::IsNullOrWhiteSpace($t)) { $out.Add($t) }
                continue
            }
            if ($depth -ge $MaxDepth) { continue }
            if ($cur -is [System.Collections.IEnumerable]) {
                foreach ($x in $cur) {
                    if ($out.Count -ge $MaxItems -or $stack.Count -ge ($MaxItems * 2)) { break }
                    $stack.Push(@{ Value = $x; Depth = ($depth + 1) })
                }
                continue
            }
            $t2 = ([string]$cur).Trim()
            if (-not [string]::IsNullOrWhiteSpace($t2)) { $out.Add($t2) }
        }
    }
    catch { }
    $arr = $out.ToArray()
    return ([string[]]$arr)
}

function Get-ShadowCanonicalTaskType {
    <#
    .SYNOPSIS
        Valida task_type contra enum canonico (fail-closed). Desconhecido
        (inclui segredos/injecao) => '' (omitir). Nunca retorna texto livre.
    #>
    [CmdletBinding()]
    param([string]$TaskType)
    $s = ([string]$TaskType).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($s)) { return '' }
    $allowed = @('trivial', 'analysis', 'architecture', 'implementation', 'review', 'research', 'debug', 'exploration', 'test', 'complex', 'migration', 'execution', 'code', 'build', 'write', 'read')
    if ($allowed -ccontains $s) { return $s }
    return ''
}

function Get-ShadowCanonicalRisk {
    <#
    .SYNOPSIS
        Valida risk contra enum canonico (fail-closed). Desconhecido =>
        '' (omitir). Nunca retorna texto livre.
    #>
    [CmdletBinding()]
    param([string]$Risk)
    $s = ([string]$Risk).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($s)) { return '' }
    $allowed = @('low', 'medium', 'high', 'critical', 'unknown')
    if ($allowed -ccontains $s) { return $s }
    return ''
}

function Get-ShadowCanonicalFilters {
    <#
    .SYNOPSIS
        Converte filtros para enum fechado (fail-closed). Mapeia nomes
        legados do Router (status/permission/trust/unknown-deny/freshness)
        para filter.* canonico; valor nao reconhecido => descartado (nunca
        persistido cru). Nunca retorna texto livre.
    #>
    [CmdletBinding()]
    param($InputObject)
    $flat = @(ConvertTo-ShadowStringArray -InputObject $InputObject)
    $allowed = @('filter.status', 'filter.permission', 'filter.forbidden', 'filter.trust', 'filter.stale', 'filter.unknown-deny', 'filter.freshness')
    $map = @{
        'status' = 'filter.status'; 'filter.status' = 'filter.status';
        'permission' = 'filter.permission'; 'filter.permission' = 'filter.permission';
        'forbidden' = 'filter.forbidden'; 'filter.forbidden' = 'filter.forbidden'; 'unknown-deny' = 'filter.forbidden'; 'filter.unknown-deny' = 'filter.unknown-deny';
        'trust' = 'filter.trust'; 'filter.trust' = 'filter.trust';
        'stale' = 'filter.stale'; 'freshness' = 'filter.stale'; 'filter.stale' = 'filter.stale'; 'filter.freshness' = 'filter.freshness'
    }
    $keep = New-Object System.Collections.Generic.List[string]
    foreach ($v in $flat) {
        $k = ([string]$v).Trim().ToLowerInvariant()
        if ($map.ContainsKey($k)) {
            $canon = [string]$map[$k]
            if (($allowed -ccontains $canon) -and ($keep -cnotcontains $canon)) { $keep.Add($canon) }
        }
    }
    return ([string[]]$keep.ToArray())
}

function Get-ShadowCanonicalWarnings {
    <#
    .SYNOPSIS
        Converte warnings livres para enum fechado (fail-closed) para
        TELEMETRIA. Texto nao reconhecido => descartado (nunca persistido
        cru, nunca vaza segredo). O resultado operacional mantem warnings
        humanos; a telemetria usa apenas este enum.
    #>
    [CmdletBinding()]
    param($InputObject)
    $flat = @(ConvertTo-ShadowStringArray -InputObject $InputObject)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($w in $flat) {
        $lw = ([string]$w).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($lw)) { continue }
        $canon = $null
        if ($lw.Contains('registry stale') -or $lw.Contains('registry_stale') -or (($lw.Contains('stale')) -and ($lw.Contains('registry')))) { $canon = 'registry_stale' }
        elseif ($lw.Contains('registry corrupt') -or $lw.Contains('registry_corrupt') -or (($lw.Contains('corrupt')) -and ($lw.Contains('registry')))) { $canon = 'registry_corrupt' }
        elseif ($lw.Contains('registry missing') -or $lw.Contains('registry_missing') -or $lw.Contains('file not found') -or (($lw.Contains('missing')) -and ($lw.Contains('registry')))) { $canon = 'shadow_unavailable' }
        elseif ($lw.Contains('registry drift') -or $lw.Contains('drift')) { $canon = 'shadow_unavailable' }
        elseif ($lw.Contains('shadow unavailable')) { $canon = 'shadow_unavailable' }
        elseif ($lw.Contains('shadow timeout')) { $canon = 'shadow_unavailable' }
        elseif ($lw.Contains('shadow disabled')) { $canon = 'shadow_unavailable' }
        elseif ($lw.Contains('truncado') -or $lw.Contains('truncated') -or $lw.Contains('context_truncated')) { $canon = 'context_truncated' }
        elseif ($lw.Contains('deduped') -or $lw.Contains('dedup')) { $canon = 'deduped' }
        elseif ($lw.Contains('repeat') -and ($lw.Contains('ttl') -or $lw.Contains('fora'))) { $canon = 'deduped' }
        elseif ($lw.Contains('telemetry unavailable')) { $canon = 'shadow_unavailable' }
        elseif ($lw.Contains('shadow input invalido') -or $lw.Contains('input invalido')) { $canon = 'context_truncated' }
        elseif ($lw.Contains('non canon') -or $lw.Contains('nao canon')) { $canon = 'context_truncated' }
        if ($null -ne $canon -and ($out -cnotcontains $canon)) { $out.Add($canon) }
    }
    return ([string[]]$out.ToArray())
}

function Get-ShadowRegistryStatusName {
    <#
    .SYNOPSIS
        Classifica registry em fresh|stale|missing|corrupt|drift a partir
        de Available/Stale/Reasons (contrato do router). Nunca lanca.
    #>
    [CmdletBinding()]
    param([bool]$Available, [bool]$Stale, [string[]]$Reasons)
    try {
        $joined = ((@($Reasons) | ForEach-Object { [string]$_ }) -join ' | ').ToLowerInvariant()
        if (-not $Available) {
            if ($joined.Contains('corrupt')) { return 'corrupt' }
            return 'missing'
        }
        if ($Stale) {
            if ($joined.Contains('drift')) { return 'drift' }
            if ($joined.Contains('corrupt')) { return 'corrupt' }
            return 'stale'
        }
        return 'fresh'
    }
    catch { return 'missing' }
}

function Get-ShadowCanonicalArray {
    <#
    .SYNOPSIS
        Filtra lista para IDs canonicos apenas (remove valores livres).
    #>
    [CmdletBinding()]
    param($InputObject)
    $flat = @(ConvertTo-ShadowStringArray -InputObject $InputObject)
    $keep = New-Object System.Collections.Generic.List[string]
    foreach ($v in $flat) {
        if (Test-ShadowCanonicalId -Id $v) { $keep.Add($v) }
    }
    return ([string[]]$keep.ToArray())
}

function Get-ShadowHash16 {
    <#
    .SYNOPSIS
        Hash SHA256 (16 hex chars) para registrar hints livres como
        hash na telemetria, sem valores livres.
    #>
    [CmdletBinding()]
    param([string]$Text)
    $s = ([string]$Text).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($s)) { return 'h:empty' }
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($s)
            $hash = $sha.ComputeHash($bytes)
            $hex = (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
            return ('h:' + $hex.Substring(0, 16))
        }
        finally { try { $sha.Dispose() } catch { } }
    }
    catch { return 'h:unavailable' }
}

function Get-ShadowTaskKeyHex {
    <#
    .SYNOPSIS
        Nucleo estavel de 16 hex (SHA256) para identificar um task_id sem
        persistir o valor cru (telemetria, dedupe em disco, locks).
    #>
    [CmdletBinding()]
    param([string]$TaskId)
    $s = ([string]$TaskId).Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return '' }
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($s)
            $hash = $sha.ComputeHash($bytes)
            $hex = (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
            return ($hex.Substring(0, 16))
        }
        finally { try { $sha.Dispose() } catch { } }
    }
    catch { return '' }
}

function Get-ShadowTaskIdHash {
    <#
    .SYNOPSIS
        Identificador estavel do task_id para TELEMETRIA:
        'sha256:<16hex>'. O valor cru nunca e persistido; fica so em
        memoria para dedupe/lock.
    #>
    [CmdletBinding()]
    param([string]$TaskId)
    $hex = Get-ShadowTaskKeyHex -TaskId $TaskId
    if ([string]::IsNullOrWhiteSpace($hex)) { return '' }
    return ('sha256:' + $hex)
}

function Test-ShadowJsonBounds {
    <#
    .SYNOPSIS
        Pre-scan estrutural do TaskFile ANTES de materializar via
        ConvertFrom-Json: rejeita profundidade > 10 ou qualquer array com
        mais de 100 elementos. Varredura linear sobre o texto (sem alocar
        objetos), respeitando strings/escapes. Nunca lanca.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RawText, [int]$MaxDepth = 10, [int]$MaxArrayItems = 100)
    $out = [PSCustomObject]@{ Ok = $true; Reason = '' }
    try {
        if ($MaxDepth -lt 1) { $MaxDepth = 10 }
        if ($MaxArrayItems -lt 1) { $MaxArrayItems = 100 }
        $depth = 0
        $stack = New-Object System.Collections.Generic.Stack[object]
        $inStr = $false
        $esc = $false
        $text = [string]$RawText
        $n = $text.Length
        for ($i = 0; $i -lt $n; $i++) {
            $c = [string]$text[$i]
            if ($inStr) {
                if ($esc) { $esc = $false }
                elseif ($c -ceq '\') { $esc = $true }
                elseif ($c -ceq '"') { $inStr = $false }
                continue
            }
            if ($c -ceq '"') {
                $inStr = $true
                if ($stack.Count -gt 0) {
                    $top = $stack.Peek()
                    if ($top.Kind -ceq 'a') { $top.HasItem = $true }
                }
                continue
            }
            if (($c -ceq '{') -or ($c -ceq '[')) {
                $depth++
                if ($depth -gt $MaxDepth) { $out.Ok = $false; $out.Reason = 'depth'; return $out }
                if ($stack.Count -gt 0) {
                    $parent = $stack.Peek()
                    if ($parent.Kind -ceq 'a') { $parent.HasItem = $true }
                }
                $frame = [PSCustomObject]@{ Kind = 'o'; Commas = 0; HasItem = $false }
                if ($c -ceq '[') { $frame.Kind = 'a' }
                $stack.Push($frame)
                continue
            }
            if (($c -ceq '}') -or ($c -ceq ']')) {
                if ($stack.Count -eq 0) { $out.Ok = $false; $out.Reason = 'unbalanced'; return $out }
                $frame = $stack.Pop()
                $depth--
                if (($frame.Kind -ceq 'a') -and ([bool]$frame.HasItem)) {
                    if (([int]$frame.Commas + 1) -gt $MaxArrayItems) { $out.Ok = $false; $out.Reason = 'array'; return $out }
                }
                continue
            }
            if ($c -ceq ',') {
                if ($stack.Count -gt 0) {
                    $top = $stack.Peek()
                    if ($top.Kind -ceq 'a') {
                        $top.Commas = ([int]$top.Commas + 1)
                        if ([int]$top.Commas -ge $MaxArrayItems) { $out.Ok = $false; $out.Reason = 'array'; return $out }
                    }
                }
                continue
            }
            if (($c -ceq ' ') -or ($c -ceq "`t") -or ($c -ceq "`r") -or ($c -ceq "`n") -or ($c -ceq ':')) { continue }
            if ($stack.Count -gt 0) {
                $top2 = $stack.Peek()
                if ($top2.Kind -ceq 'a') { $top2.HasItem = $true }
            }
        }
        if ($inStr) { $out.Ok = $false; $out.Reason = 'unbalanced'; return $out }
    }
    catch { $out.Ok = $false; $out.Reason = 'scan' }
    return $out
}

function Read-ShadowTaskRaw {
    <#
    .SYNOPSIS
        Le o TaskFile por um UNICO handle com leitura limitada a 16KB
        (sem TOCTOU entre checagem e leitura). Estouro ou crescimento
        durante a leitura => erro seguro.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$TaskFile)
    $limit = 16384
    $fs = $null
    try {
        $fs = [IO.File]::Open($TaskFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        if ([long]$fs.Length -gt [long]$limit) {
            throw ("shadow TaskFile excede limite (~16KB): {0} bytes" -f [long]$fs.Length)
        }
        $cap = ($limit + 1)
        $buf = New-Object byte[] $cap
        $total = 0
        while ($total -lt $cap) {
            $n = $fs.Read($buf, $total, ($cap - $total))
            if ($n -le 0) { break }
            $total += $n
        }
        if ($total -gt $limit) {
            throw ("shadow TaskFile excede limite (~16KB): leitura limitada em {0} bytes" -f [int]$total)
        }
        return [Text.Encoding]::UTF8.GetString($buf, 0, $total)
    }
    finally {
        try { if ($null -ne $fs) { $fs.Close() } } catch { }
        try { if ($null -ne $fs) { $fs.Dispose() } } catch { }
    }
}

function Get-ShadowTelemetryHints {
    <#
    .SYNOPSIS
        Telemetria registra domain_hints apenas como hashes (sem valores
        livres). Cardinalidade maxima 5.
    #>
    [CmdletBinding()]
    param($DomainHints)
    $flat = @(ConvertTo-ShadowStringArray -InputObject $DomainHints)
    $n = $flat.Count
    if ($n -gt 5) { $flat = @($flat[0..4]) }
    $hashed = New-Object System.Collections.Generic.List[string]
    foreach ($h in $flat) { $hashed.Add((Get-ShadowHash16 -Text $h)) }
    return ([string[]]$hashed.ToArray())
}

function Get-ShadowSeenPath {
    [CmdletBinding()]
    param([string]$RepoRoot)
    $repo = Get-ShadowRepoRoot -RepoRoot $RepoRoot
    return (Join-Path $repo 'cache\v3\telemetry\.shadow-seen.json')
}

function Read-ShadowSeen {
    <#
    .SYNOPSIS
        Le o state file de dedupe (task_id -> timestamp ISO). Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$SeenPath)
    $table = @{}
    try {
        if (-not [string]::IsNullOrWhiteSpace($SeenPath) -and (Test-Path -LiteralPath $SeenPath -PathType Leaf)) {
            $text = Read-ShadowUtf8Text -Path $SeenPath
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $doc = ($text | ConvertFrom-Json)
                if ($null -ne $doc) {
                    if ($doc -is [System.Collections.IDictionary]) {
                        foreach ($k in @($doc.Keys)) { $table[[string]$k] = [string]$doc[$k] }
                    }
                    else {
                        foreach ($p in @($doc.PSObject.Properties)) { $table[[string]$p.Name] = [string]$p.Value }
                    }
                }
            }
        }
    }
    catch { $table = @{} }
    return $table
}

function Write-ShadowSeen {
    <#
    .SYNOPSIS
        Registra task_id com timestamp atual no state file (fail-silente).
        Poda entradas com mais de 1h para manter o arquivo pequeno.
    #>
    [CmdletBinding()]
    param([string]$SeenPath, [string]$TaskId)
    try {
        if ([string]::IsNullOrWhiteSpace($SeenPath)) { return $false }
        if (-not (Test-ShadowTaskId -TaskId $TaskId)) { return $false }
        $key = Get-ShadowTaskIdHash -TaskId ([string]$TaskId)
        if ([string]::IsNullOrWhiteSpace($key)) { return $false }
        $table = Read-ShadowSeen -SeenPath $SeenPath
        $now = [DateTimeOffset]::UtcNow
        $fresh = @{}
        foreach ($k in @($table.Keys)) {
            try {
                if ([string]$k -notmatch '^sha256:[0-9a-f]{16}$') { continue }
                $parsed = [DateTimeOffset]::MinValue
                if ([DateTimeOffset]::TryParse([string]$table[$k], [ref]$parsed)) {
                    if (($now - $parsed).TotalSeconds -le 3600) { $fresh[[string]$k] = [string]$table[$k] }
                }
            }
            catch { }
        }
        $fresh[$key] = $now.ToString('o')
        $parent = Split-Path -Parent $SeenPath
        if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $json = (($fresh | ConvertTo-Json -Depth 5 -Compress) + "`n")
        [IO.File]::WriteAllText($SeenPath, $json, [Text.UTF8Encoding]::new($false))
        return $true
    }
    catch { return $false }
}

function Get-ShadowLockPath {
    [CmdletBinding()]
    param([string]$RepoRoot, [string]$TaskId)
    $repo = Get-ShadowRepoRoot -RepoRoot $RepoRoot
    $safe = ([string]$TaskId).Trim()
    if (-not (Test-ShadowTaskId -TaskId $safe)) { return '' }
    $hex = Get-ShadowTaskKeyHex -TaskId $safe
    if ([string]::IsNullOrWhiteSpace($hex)) { return '' }
    return (Join-Path $repo ('cache\v3\telemetry\.shadow-locks\task-' + $hex + '.lock'))
}

function Try-AcquireShadowClaim {
    <#
    .SYNOPSIS
        Claim atomico por task_id via lock exclusivo (CreateNew) ANTES de
        consultar o Router. Sucesso => retorna @{ Acquired=$true; LockPath=...; Stream=... }
        Falha (lock existe e fresco) => @{ Acquired=$false }. Lock stale
        (>120s) e removido e nova tentativa feita uma vez. Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$RepoRoot, [string]$TaskId, [int]$StaleSeconds = 120)
    $out = [PSCustomObject]@{ Acquired = $false; LockPath = ''; Stream = $null }
    try {
        $lp = Get-ShadowLockPath -RepoRoot $RepoRoot -TaskId $TaskId
        if ([string]::IsNullOrWhiteSpace($lp)) { return $out }
        $parent = Split-Path -Parent $lp
        if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        try {
            $fs = [IO.File]::Open($lp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $payload = ((Get-ShadowTaskIdHash -TaskId ([string]$TaskId)) + ' ' + [DateTimeOffset]::UtcNow.ToString('o') + ' ' + [Diagnostics.Process]::GetCurrentProcess().Id)
                $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
                $fs.Write($bytes, 0, $bytes.Length)
                $fs.Flush()
            }
            catch { }
            $out.Acquired = $true
            $out.LockPath = $lp
            $out.Stream = $fs
            return $out
        }
        catch [IO.IOException] {
            try {
                $age = 1e9
                try {
                    $lw = [IO.File]::GetLastWriteTimeUtc($lp)
                    $age = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::new($lw, [TimeSpan]::Zero)).TotalSeconds
                }
                catch { $age = 0 }
                if ($age -gt [double]$StaleSeconds) {
                    try { Remove-Item -LiteralPath $lp -Force -ErrorAction SilentlyContinue } catch { }
                    try {
                        $fs2 = [IO.File]::Open($lp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                        $out.Acquired = $true
                        $out.LockPath = $lp
                        $out.Stream = $fs2
                        return $out
                    }
                    catch { }
                }
            }
            catch { }
            return $out
        }
    }
    catch { return $out }
}

function Release-ShadowClaim {
    [CmdletBinding()]
    param($Claim)
    try {
        if ($null -ne $Claim -and $null -ne $Claim.Stream) {
            try { $Claim.Stream.Close() } catch { }
            try { $Claim.Stream.Dispose() } catch { }
        }
        if ($null -ne $Claim -and -not [string]::IsNullOrWhiteSpace([string]$Claim.LockPath)) {
            try { Remove-Item -LiteralPath ([string]$Claim.LockPath) -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
    catch { }
}

function Test-ShadowDeduped {
    <#
    .SYNOPSIS
        Verifica dedupe por task_id com TTL 60s. Retorna objeto com
        Deduped (dentro do TTL) e RepeatOutsideTtl (ja visto, fora do TTL).
    #>
    [CmdletBinding()]
    param([string]$SeenPath, [string]$TaskId, [int]$TtlSeconds = 60)
    $out = [PSCustomObject]@{ Deduped = $false; RepeatOutsideTtl = $false }
    try {
        if ([string]::IsNullOrWhiteSpace($SeenPath)) { return $out }
        if (-not (Test-ShadowTaskId -TaskId $TaskId)) { return $out }
        $key = Get-ShadowTaskIdHash -TaskId ([string]$TaskId)
        if ([string]::IsNullOrWhiteSpace($key)) { return $out }
        $table = Read-ShadowSeen -SeenPath $SeenPath
        if (-not $table.Contains($key)) { return $out }
        $parsed = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$table[$key], [ref]$parsed)) { return $out }
        $age = ([DateTimeOffset]::UtcNow - $parsed).TotalSeconds
        if ($age -le [double]$TtlSeconds) { $out.Deduped = $true }
        else { $out.RepeatOutsideTtl = $true }
    }
    catch { }
    return $out
}

function Get-ShadowComparison {
    <#
    .SYNOPSIS
        Comparacao nao-cega entre rota atual e proposta (Phase 9).
        Nunca retorna V3_BETTER/V3_WORSE sem expected_agent explicito,
        sem rota atual, sem proposta (falha/timeout) ou fora de success:
        esses casos sao NOT_COMPARABLE (chamador garante o gate de status).
    #>
    [CmdletBinding()]
    param(
        [string]$ProposedAgent,
        [string]$CurrentAgent,
        [string]$ExpectedAgent,
        [bool]$HasCurrentRoute
    )
    if (-not $HasCurrentRoute) { return 'NOT_COMPARABLE' }
    $cur = ([string]$CurrentAgent).Trim().ToLowerInvariant()
    $prop = ([string]$ProposedAgent).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($cur)) { return 'NOT_COMPARABLE' }
    if ([string]::IsNullOrWhiteSpace($prop)) { return 'NOT_COMPARABLE' }
    if ($cur -ceq $prop) { return 'EQUAL' }
    $exp = ([string]$ExpectedAgent).Trim().ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($exp)) {
        $propHits = ($prop -ceq $exp)
        $curHits = ($cur -ceq $exp)
        if ($propHits -and -not $curHits) { return 'V3_BETTER' }
        if ($curHits -and -not $propHits) { return 'V3_WORSE' }
        return 'UNCLEAR'
    }
    return 'UNCLEAR'
}

function Get-ShadowConfidenceClass {
    [CmdletBinding()]
    param($Confidence)
    $c = 0.0
    try { $c = [double]$Confidence } catch { $c = 0.0 }
    if ($c -ge 0.8) { return 'high' }
    if ($c -ge 0.5) { return 'medium' }
    return 'low'
}

function Read-ShadowTask {
    <#
    .SYNOPSIS
        Le o TaskFile minimo da bridge por um UNICO handle com leitura
        limitada a 16KB (sem TOCTOU entre checagem e leitura) e com
        pre-scan estrutural (profundidade <= 10, arrays <= 100 itens)
        ANTES de materializar via ConvertFrom-Json. Excesso => erro
        seguro. Nao envia historico, dumps, secrets, skill content ou
        schemas: apenas os campos do contrato.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$TaskFile)
    if (-not (Test-Path -LiteralPath $TaskFile -PathType Leaf)) {
        throw ("shadow TaskFile nao encontrado: {0}" -f $TaskFile)
    }
    $raw = $null
    try { $raw = Read-ShadowTaskRaw -TaskFile $TaskFile }
    catch {
        if ([string]$_.Exception.Message -like 'shadow TaskFile excede limite*') { throw }
        throw ("shadow TaskFile ilegivel ou ausente: {0}" -f $TaskFile)
    }
    $bounds = Test-ShadowJsonBounds -RawText $raw
    if (-not [bool]$bounds.Ok) {
        throw ("shadow TaskFile excede limite estrutural (profundidade <= 10, arrays <= 100 itens): {0}" -f [string]$bounds.Reason)
    }
    $doc = $null
    try { $doc = $raw | ConvertFrom-Json }
    catch { throw ("shadow TaskFile JSON invalido: {0}" -f $_.Exception.Message) }
    $getStr = {
        param($Node, [string]$Field)
        try {
            if ($Node -is [System.Collections.IDictionary]) {
                if ($Node.Contains($Field) -and $null -ne $Node[$Field]) { return [string]$Node[$Field] }
            }
            else {
                $p = $Node.PSObject.Properties | Where-Object { $_.Name -ceq $Field } | Select-Object -First 1
                if ($null -ne $p -and $null -ne $p.Value) { return [string]$p.Value }
            }
        }
        catch { }
        return ''
    }
    $getArr = {
        param($Node, [string]$Field)
        $out = @()
        try {
            $val = $null
            if ($Node -is [System.Collections.IDictionary]) {
                if ($Node.Contains($Field)) { $val = $Node[$Field] }
            }
            else {
                $p = $Node.PSObject.Properties | Where-Object { $_.Name -ceq $Field } | Select-Object -First 1
                if ($null -ne $p) { $val = $p.Value }
            }
            foreach ($v in @(ConvertTo-ShadowStringArray -InputObject $val)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$v)) { $out += [string]$v }
            }
        }
        catch { }
        return $out
    }
    $taskId = & $getStr $doc 'task_id'
    if ([string]::IsNullOrWhiteSpace($taskId)) { $taskId = & $getStr $doc 'taskId' }
    $objective = & $getStr $doc 'objective'
    $taskType = & $getStr $doc 'task_type'
    if ([string]::IsNullOrWhiteSpace($taskType)) { $taskType = & $getStr $doc 'taskType' }
    $risk = & $getStr $doc 'risk'
    $rw = & $getStr $doc 'read_write_mode'
    if ([string]::IsNullOrWhiteSpace($rw)) { $rw = & $getStr $doc 'read_write' }
    if ([string]::IsNullOrWhiteSpace($rw)) { $rw = & $getStr $doc 'readWrite' }
    $expected = & $getStr $doc 'expected_agent'
    if ([string]::IsNullOrWhiteSpace($expected)) { $expected = & $getStr $doc 'expectedAgent' }
    $hints = & $getArr $doc 'domain_hints'
    if ($hints.Count -eq 0) {
        $d1 = & $getStr $doc 'domain'
        if (-not [string]::IsNullOrWhiteSpace($d1)) { $hints = @($d1) }
    }
    $constraints = @()
    try {
        $cv = $null
        if ($doc -is [System.Collections.IDictionary]) {
            if ($doc.Contains('constraints')) { $cv = $doc['constraints'] }
        }
        else {
            $p = $doc.PSObject.Properties | Where-Object { $_.Name -ceq 'constraints' } | Select-Object -First 1
            if ($null -ne $p) { $cv = $p.Value }
        }
        $constraints = @(ConvertTo-ShadowStringArray -InputObject $cv)
    }
    catch { $constraints = @() }
    $hasCurrent = $false
    $curAgent = ''
    $curSkills = @()
    try {
        $cr = $null
        if ($doc -is [System.Collections.IDictionary]) {
            if ($doc.Contains('current_route')) { $cr = $doc['current_route'] }
        }
        else {
            $p = $doc.PSObject.Properties | Where-Object { $_.Name -ceq 'current_route' } | Select-Object -First 1
            if ($null -ne $p) { $cr = $p.Value }
        }
        if ($null -ne $cr) {
            $hasCurrent = $true
            if ($cr -is [System.Collections.IDictionary]) {
                if ($cr.Contains('agent') -and $null -ne $cr['agent']) { $curAgent = [string]$cr['agent'] }
                if ($cr.Contains('skills')) { $curSkills = @(ConvertTo-ShadowStringArray -InputObject $cr['skills']) }
            }
            else {
                $pa = $cr.PSObject.Properties | Where-Object { $_.Name -ceq 'agent' } | Select-Object -First 1
                if ($null -ne $pa -and $null -ne $pa.Value) { $curAgent = [string]$pa.Value }
                $ps = $cr.PSObject.Properties | Where-Object { $_.Name -ceq 'skills' } | Select-Object -First 1
                if ($null -ne $ps) { $curSkills = @(ConvertTo-ShadowStringArray -InputObject $ps.Value) }
            }
        }
    }
    catch { }
    return [PSCustomObject]@{
        TaskId          = $taskId
        Objective       = $objective
        TaskType        = $taskType
        DomainHints     = $hints
        Risk            = $risk
        ReadWriteMode   = $rw
        Constraints     = @($constraints)
        ConstraintsCount = (@($constraints)).Count
        HasCurrentRoute = [bool]$hasCurrent
        CurrentAgent    = $curAgent
        CurrentSkills   = @($curSkills)
        ExpectedAgent   = $expected
    }
}

function Get-ShadowValidatedContext {
    <#
    .SYNOPSIS
        Valida e sanitiza o contexto ANTES de qualquer temp/stdin:
        task_id por regex; objective redigido + truncado (500); hints com
        cardinalidade maxima 5 e 32 chars cada; skills por ID canonico.
        Retorna validacao com warnings; InputValid=$false rejeita.
    #>
    [CmdletBinding()]
    param($Task)
    $warnings = New-Object System.Collections.Generic.List[string]
    $valid = $true
    $reason = ''
    $taskId = ([string]$Task.TaskId).Trim()
    if (-not (Test-ShadowTaskId -TaskId $taskId)) {
        return [PSCustomObject]@{
            InputValid = $false; Reason = 'shadow input invalido: task_id fora do formato de ID';
            TaskId = ''; Objective = ''; TaskType = ''; Domain = ''; Risk = '';
            ReadWrite = ''; DomainHints = [string[]]@(); CurrentAgent = '';
            CurrentSkills = [string[]]@(); ExpectedAgent = ''; ConstraintsCount = 0; Warnings = [string[]]@()
        }
    }
    $objective = Get-ShadowSanitizedObjective -Objective ([string]$Task.Objective)
    if ([string]::IsNullOrWhiteSpace($objective)) {
        return [PSCustomObject]@{
            InputValid = $false; Reason = 'shadow input invalido: objective ausente';
            TaskId = $taskId; Objective = ''; TaskType = ''; Domain = ''; Risk = '';
            ReadWrite = ''; DomainHints = [string[]]@(); CurrentAgent = '';
            CurrentSkills = [string[]]@(); ExpectedAgent = ''; ConstraintsCount = 0; Warnings = [string[]]@()
        }
    }
    if (([string]$Task.Objective).Length -gt 500) { $warnings.Add('shadow input truncado (objective > 500)') }
    $taskType = Get-ShadowCanonicalTaskType -TaskType ([string]$Task.TaskType)
    $risk = Get-ShadowCanonicalRisk -Risk ([string]$Task.Risk)
    $rw = ([string]$Task.ReadWriteMode).Trim().ToLowerInvariant()
    if (($rw -cne 'read') -and ($rw -cne 'write')) { $rw = '' }
    $rawHints = @(ConvertTo-ShadowStringArray -InputObject @($Task.DomainHints))
    if ($rawHints.Count -gt 5) {
        $warnings.Add('shadow input truncado (domain_hints > 5)')
        $rawHints = @($rawHints[0..4])
    }
    $cleanHints = New-Object System.Collections.Generic.List[string]
    foreach ($h in $rawHints) {
        $red = Get-ShadowRedactedText -Text ([string]$h)
        $red = $red.Trim().ToLowerInvariant()
        if ($red.Length -gt 32) { $red = $red.Substring(0, 32) }
        if (-not [string]::IsNullOrWhiteSpace($red)) { $cleanHints.Add($red) }
    }
    $hints = $cleanHints.ToArray()
    $domain = ''
    if ($hints.Count -gt 0) { $domain = [string]$hints[0] }
    $curAgent = ([string]$Task.CurrentAgent).Trim()
    if (-not [string]::IsNullOrWhiteSpace($curAgent) -and -not (Test-ShadowCanonicalId -Id $curAgent)) {
        $warnings.Add('shadow input com current agent nao canonico (ignorado na comparacao)')
        $curAgent = ''
    }
    $canonSkills = @(Get-ShadowCanonicalArray -InputObject @($Task.CurrentSkills))
    $rawSkillCount = @(ConvertTo-ShadowStringArray -InputObject @($Task.CurrentSkills)).Count
    if ($rawSkillCount -gt $canonSkills.Count) { $warnings.Add('shadow input com skills nao canonicas (removidas)') }
    if ($canonSkills.Count -gt 10) {
        $warnings.Add('shadow input truncado (skills > 10)')
        $canonSkills = @($canonSkills[0..9])
    }
    $expected = ([string]$Task.ExpectedAgent).Trim()
    if (-not [string]::IsNullOrWhiteSpace($expected) -and -not (Test-ShadowCanonicalId -Id $expected)) {
        $warnings.Add('shadow input com expected agent nao canonico (ignorado)')
        $expected = ''
    }
    $cc = [int]$Task.ConstraintsCount
    if ($cc -gt 99) { $cc = 99 }
    if ((@(ConvertTo-ShadowStringArray -InputObject @($Task.Constraints))).Count -gt 10) {
        $warnings.Add('shadow input com constraints acima do limite (contadas, valores nunca encaminhados)')
    }
    return [PSCustomObject]@{
        InputValid = $true; Reason = '';
        TaskId = $taskId; Objective = $objective; TaskType = $taskType; Domain = $domain;
        Risk = $risk; ReadWrite = $rw; DomainHints = ([string[]]$hints);
        CurrentAgent = $curAgent; CurrentSkills = ([string[]]$canonSkills);
        ExpectedAgent = $expected; ConstraintsCount = $cc; Warnings = ([string[]]$warnings.ToArray())
    }
}

function Invoke-ShadowRouterProcess {
    <#
    .SYNOPSIS
        Invoca um script de Router (shim de teste) como processo filho
        com timeout curto, passando o contexto por STDIN (sem -TaskFile e
        sem arquivo temporario com objective). Nunca lanca: retorna
        TimedOut/ExitCode/Stdout para o chamador decidir (fail-safe).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RouterPath,
        [Parameter(Mandatory = $true)][string]$StdinJson,
        [string]$RegistryPath,
        [string]$ConfigPath,
        [int]$TimeoutMs = 5000
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = [ordered]@{
        TimedOut   = $false
        ExitCode   = -1
        Stdout     = ''
        Stderr     = ''
        LatencyMs  = 0
    }
    try {
        if (-not (Test-Path -LiteralPath $RouterPath -PathType Leaf)) {
            $sw.Stop()
            $out['LatencyMs'] = [int]$sw.Elapsed.TotalMilliseconds
            return ([PSCustomObject]$out)
        }
        if ($TimeoutMs -lt 500) { $TimeoutMs = 500 }
        $argList = @('-NoProfile', '-File', ("`"{0}`"" -f $RouterPath))
        if (-not [string]::IsNullOrWhiteSpace($RegistryPath)) {
            $argList += @('-RegistryPath', ("`"{0}`"" -f $RegistryPath))
        }
        if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
            $argList += @('-ConfigPath', ("`"{0}`"" -f $ConfigPath))
        }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell'
        $psi.Arguments = ($argList -join ' ')
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $psi.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $started = $proc.Start()
        if (-not $started) {
            $sw.Stop()
            $out['LatencyMs'] = [int]$sw.Elapsed.TotalMilliseconds
            return ([PSCustomObject]$out)
        }
        try {
            $proc.StandardInput.Write([string]$StdinJson)
            $proc.StandardInput.Close()
        }
        catch { try { $proc.StandardInput.Close() } catch { } }
        $exited = $proc.WaitForExit($TimeoutMs)
        if (-not $exited) {
            try { $proc.Kill() } catch { }
            try { $proc.WaitForExit(2000) } catch { }
            $sw.Stop()
            $out['TimedOut'] = $true
            $out['LatencyMs'] = [int]$sw.Elapsed.TotalMilliseconds
            return ([PSCustomObject]$out)
        }
        $stdout = ''
        $stderr = ''
        try { $stdout = $proc.StandardOutput.ReadToEnd() } catch { $stdout = '' }
        try { $stderr = $proc.StandardError.ReadToEnd() } catch { $stderr = '' }
        $sw.Stop()
        $out['Stdout'] = [string]$stdout
        $out['Stderr'] = [string]$stderr
        try { $out['ExitCode'] = [int]$proc.ExitCode } catch { $out['ExitCode'] = -1 }
        $out['LatencyMs'] = [int]$sw.Elapsed.TotalMilliseconds
        try { $proc.Close() } catch { }
        return ([PSCustomObject]$out)
    }
    catch {
        try { $sw.Stop() } catch { }
        $out['LatencyMs'] = [int]$sw.Elapsed.TotalMilliseconds
        return ([PSCustomObject]$out)
    }
}

function Invoke-ShadowRouterIsolated {
    <#
    .SYNOPSIS
        Rota default: Router V1 em processo isolado com timeout rigido.
        O contexto minimo vai por STDIN (sem arquivo temporario com
        objective); o script do filho e codigo puro (caminhos apenas).
        Kill no timeout. Nunca lanca.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StdinJson,
        [string]$RouterLibPath,
        [string]$RegistryPath,
        [string]$ConfigPath,
        [string]$PolicyPath,
        [int]$TimeoutMs = 20000
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = [ordered]@{
        TimedOut   = $false
        ExitCode   = -1
        Stdout     = ''
        Stderr     = ''
        LatencyMs  = 0
    }
    $tmpChild = Join-Path ([IO.Path]::GetTempPath()) ('v3-shadow-child-' + [guid]::NewGuid().ToString('N') + '.ps1')
    try {
        $lib = $RouterLibPath
        if ([string]::IsNullOrWhiteSpace($lib)) { $lib = $__shadowRouterLib }
        $esc = {
            param([string]$S)
            return (([string]$S) -replace "'", "''")
        }
        $libQ = (& $esc $lib)
        $regQ = (& $esc ([string]$RegistryPath))
        $cfgQ = (& $esc ([string]$ConfigPath))
        $polQ = (& $esc ([string]$PolicyPath))
        $child = @'
$ErrorActionPreference = 'Stop'
. '__LIB__'
$stdinText = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($stdinText)) { [Console]::Error.WriteLine('shadow child: stdin vazio'); exit 2 }
$doc = ($stdinText | ConvertFrom-Json)
$policy = Import-RouterPolicy -PolicyPath '__POL__'
$task = New-RouterTask -Objective ([string]$doc.objective) -TaskType ([string]$doc.task_type) -Domain ([string]$doc.domain) -Risk ([string]$doc.risk) -ReadWrite ([string]$doc.read_write)
$allow = @(Get-RouterAllowlist -ConfigPath '__CFG__')
$reg = Read-RouterRegistry -RegistryPath '__REG__' -Policy $policy
$regStatus = 'fresh'
try {
    $rj = ((@($reg.StaleReasons) | ForEach-Object { "$_" }) -join ' | ').ToLowerInvariant()
    if (-not [bool]$reg.Available) {
        if ($rj.Contains('corrupt')) { $regStatus = 'corrupt' }
        else { $regStatus = 'missing' }
    }
    elseif ([bool]$reg.Stale) {
        if ($rj.Contains('drift')) { $regStatus = 'drift' }
        elseif ($rj.Contains('corrupt')) { $regStatus = 'corrupt' }
        else { $regStatus = 'stale' }
    }
    else { $regStatus = 'fresh' }
}
catch { $regStatus = 'missing' }
$res = $null
if ((-not [bool]$reg.Available) -or [bool]$reg.Stale) {
    $why = 'fallback: registry indisponivel'
    if ([bool]$reg.Available -and [bool]$reg.Stale) {
        $why = ('fallback: registry stale ({0})' -f ((@($reg.StaleReasons) | ForEach-Object { "$_" }) -join ' | '))
    }
    elseif (-not [bool]$reg.Available) {
        $why = ('fallback: registry indisponivel ({0})' -f ((@($reg.StaleReasons) | ForEach-Object { "$_" }) -join ' | '))
    }
    $res = Get-RouterFallbackResult -Task $task -Policy $policy -Reason $why -FiltersApplied @('status', 'permission', 'trust', 'unknown-deny', 'freshness') -Allowlist $allow
}
else {
    $res = Invoke-RouterRoute -Task $task -Policy $policy -Capabilities $reg.Capabilities -Allowlist $allow -Fresh ([bool]$reg.Fresh) -StaleReasons @($reg.StaleReasons)
}
$proj = [ordered]@{
    route           = [ordered]@{ agent = $res.route.agent; skills = ([string[]]@($res.route.skills)); direct = [bool]$res.route.direct }
    reason          = [string]$res.reason
    confidence      = $res.confidence
    fallback_used   = [bool]$res.fallback_used
    filters_applied = ([string[]]@($res.filters_applied))
    registry_status = [string]$regStatus
}
Write-Output ($proj | ConvertTo-Json -Depth 6 -Compress)
exit 0
'@
        $child = $child -replace '__LIB__', $libQ
        $child = $child -replace '__REG__', $regQ
        $child = $child -replace '__CFG__', $cfgQ
        $child = $child -replace '__POL__', $polQ
        [IO.File]::WriteAllText($tmpChild, $child, [Text.UTF8Encoding]::new($false))
        if ($TimeoutMs -lt 500) { $TimeoutMs = 500 }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell'
        $psi.Arguments = ('-NoProfile -File "' + $tmpChild + '"')
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $psi.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $started = $proc.Start()
        if (-not $started) {
            $sw.Stop()
            $out['LatencyMs'] = [int]$sw.Elapsed.TotalMilliseconds
            return ([PSCustomObject]$out)
        }
        try {
            $proc.StandardInput.Write([string]$StdinJson)
            $proc.StandardInput.Close()
        }
        catch { try { $proc.StandardInput.Close() } catch { } }
        $exited = $proc.WaitForExit($TimeoutMs)
        if (-not $exited) {
            try { $proc.Kill() } catch { }
            try { $proc.WaitForExit(2000) } catch { }
            $sw.Stop()
            $out['TimedOut'] = $true
            $out['LatencyMs'] = [int]$sw.Elapsed.TotalMilliseconds
            return ([PSCustomObject]$out)
        }
        $stdout = ''
        $stderr = ''
        try { $stdout = $proc.StandardOutput.ReadToEnd() } catch { $stdout = '' }
        try { $stderr = $proc.StandardError.ReadToEnd() } catch { $stderr = '' }
        $sw.Stop()
        $out['Stdout'] = [string]$stdout
        $out['Stderr'] = [string]$stderr
        try { $out['ExitCode'] = [int]$proc.ExitCode } catch { $out['ExitCode'] = -1 }
        $out['LatencyMs'] = [int]$sw.Elapsed.TotalMilliseconds
        try { $proc.Close() } catch { }
        return ([PSCustomObject]$out)
    }
    catch {
        try { $sw.Stop() } catch { }
        $out['LatencyMs'] = [int]$sw.Elapsed.TotalMilliseconds
        return ([PSCustomObject]$out)
    }
    finally {
        try { if (Test-Path -LiteralPath $tmpChild -PathType Leaf) { Remove-Item -LiteralPath $tmpChild -Force -ErrorAction SilentlyContinue } } catch { }
    }
}

function Invoke-ShadowRouterInProcess {
    <#
    .SYNOPSIS
        Consulta o Router V1 no mesmo processo (OPT-IN -InProcess, testes
        de velocidade). SEM timeout rigido: documentado como sem garantia
        de kill; nunca usar como default em producao shadow.
        Nunca lanca: retorna Succeeded/RouterResult para o chamador
        decidir (fail-safe).
    #>
    [CmdletBinding()]
    param(
        [string]$Objective,
        [string]$TaskType,
        [string]$Domain,
        [string]$Risk,
        [string]$ReadWrite,
        [string]$RegistryPath,
        [string]$ConfigPath,
        $Policy
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = [ordered]@{
        Succeeded    = $false
        RouterResult = $null
        LatencyMs    = 0
    }
    try {
        $fnTask = Get-Command 'New-RouterTask' -ErrorAction SilentlyContinue
        $fnRoute = Get-Command 'Invoke-RouterRoute' -ErrorAction SilentlyContinue
        $fnFb = Get-Command 'Get-RouterFallbackResult' -ErrorAction SilentlyContinue
        $fnReg = Get-Command 'Read-RouterRegistry' -ErrorAction SilentlyContinue
        $fnAllow = Get-Command 'Get-RouterAllowlist' -ErrorAction SilentlyContinue
        if (($null -eq $fnTask) -or ($null -eq $fnRoute) -or ($null -eq $fnFb) -or ($null -eq $fnReg) -or ($null -eq $fnAllow)) {
            $sw.Stop()
            $out['LatencyMs'] = [int]$sw.Elapsed.TotalMilliseconds
            return ([PSCustomObject]$out)
        }
        $rt = New-RouterTask -Objective $Objective -TaskType $TaskType -Domain $Domain -Risk $Risk -ReadWrite $ReadWrite
        $allow = @(Get-RouterAllowlist -ConfigPath $ConfigPath)
        $reg = Read-RouterRegistry -RegistryPath $RegistryPath -Policy $Policy
        $res = $null
        if ((-not [bool]$reg.Available) -or [bool]$reg.Stale) {
            $why = 'fallback: registry indisponivel'
            try {
                if ([bool]$reg.Available -and [bool]$reg.Stale) {
                    $why = ('fallback: registry stale ({0})' -f ((@($reg.StaleReasons) | ForEach-Object { "$_" }) -join ' | '))
                }
                elseif (-not [bool]$reg.Available) {
                    $why = ('fallback: registry indisponivel ({0})' -f ((@($reg.StaleReasons) | ForEach-Object { "$_" }) -join ' | '))
                }
            }
            catch { }
            $res = Get-RouterFallbackResult -Task $rt -Policy $Policy -Reason $why -FiltersApplied @('status', 'permission', 'trust', 'unknown-deny', 'freshness') -Allowlist $allow
        }
        else {
            $res = Invoke-RouterRoute -Task $rt -Policy $Policy -Capabilities $reg.Capabilities -Allowlist $allow -Fresh ([bool]$reg.Fresh) -StaleReasons @($reg.StaleReasons)
        }
        $sw.Stop()
        $out['Succeeded'] = ($null -ne $res -and $null -ne $res.route)
        $out['RouterResult'] = $res
        $out['LatencyMs'] = [int]$sw.Elapsed.TotalMilliseconds
        return ([PSCustomObject]$out)
    }
    catch {
        try { $sw.Stop() } catch { }
        $out['LatencyMs'] = [int]$sw.Elapsed.TotalMilliseconds
        return ([PSCustomObject]$out)
    }
}

function Get-ShadowRegistryStatus {
    <#
    .SYNOPSIS
        Valida o registry pelo contrato do router. Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$RegistryPath, [string]$RepoRoot, $Policy)
    $st = [ordered]@{
        Available   = $false
        Stale       = $true
        Reasons     = @('registry unavailable')
        LogicalHash = 'unknown'
    }
    try {
        $fn = Get-Command 'Read-RouterRegistry' -ErrorAction SilentlyContinue
        if ($null -ne $fn) {
            $r = Read-RouterRegistry -RegistryPath $RegistryPath -Policy $Policy -MaxAgeSeconds -1
            $st['Available'] = [bool]$r.Available
            $st['Stale'] = [bool]$r.Stale
            $st['Reasons'] = @(ConvertTo-ShadowStringArray -InputObject @($r.StaleReasons))
            try {
                if ($null -ne $r.Registry -and $null -ne $r.Registry.registry -and $null -ne $r.Registry.registry.logical_hash) {
                    $st['LogicalHash'] = [string]$r.Registry.registry.logical_hash
                }
            }
            catch { }
            return ([PSCustomObject]$st)
        }
        $resolved = $RegistryPath
        if ([string]::IsNullOrWhiteSpace($resolved)) {
            $resolved = Join-Path (Get-ShadowRepoRoot -RepoRoot $RepoRoot) 'cache\v3\capability-registry.json'
        }
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            $st['Reasons'] = @('registry file not found')
            return ([PSCustomObject]$st)
        }
        $text = Read-ShadowUtf8Text -Path $resolved
        $doc = ($text | ConvertFrom-Json)
        if ($null -eq $doc -or $null -eq $doc.capabilities) {
            $st['Reasons'] = @('registry corrupt (missing capabilities)')
            return ([PSCustomObject]$st)
        }
        $st['Available'] = $true
        $st['Stale'] = $false
        $st['Reasons'] = @()
        try {
            if ($null -ne $doc.registry -and $null -ne $doc.registry.logical_hash) {
                $st['LogicalHash'] = [string]$doc.registry.logical_hash
            }
        }
        catch { }
        return ([PSCustomObject]$st)
    }
    catch {
        return ([PSCustomObject]$st)
    }
}

function Get-ShadowRouterVersion {
    [CmdletBinding()]
    param($Policy)
    try {
        if ($null -ne $Policy -and $null -ne $Policy.routing -and $null -ne $Policy.routing.version) {
            return ([string]$Policy.routing.version)
        }
    }
    catch { }
    return '1'
}

function Get-ShadowSafeLogicalHash {
    <#
    .SYNOPSIS
        Logical hash seguro para telemetria: so aceita o formato estrito
        sha256:<64hex> (lowercase normalizado); qualquer outro formato
        (inclui segredos/marcadores) vira 'unknown' (omitido na pratica).
    #>
    [CmdletBinding()]
    param([string]$LogicalHash)
    $s = ([string]$LogicalHash).Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return 'unknown' }
    if ($s -match '^sha256:[0-9a-fA-F]{64}$') { return $s.ToLowerInvariant() }
    return 'unknown'
}

function New-ShadowTelemetryLine {
    <#
    .SYNOPSIS
        DTO sanitizado por allowlist para o JSONL de telemetria (fail-closed).
        DTO estavel: arrays sempre como arrays ([string[]] em PSCustomObject,
        sem {value,Count}); apenas IDs canonicos/hashes, nunca objective,
        prompts, secrets, descricoes, content ou valores livres. O task_id
        e persistido SOMENTE como hash estavel sha256:<16hex> (nunca o
        valor cru; o cru fica so em memoria para dedupe/lock).
        Campos conforme contrato: trace_id, task_id, timestamp,
        router_version, registry_logical_hash, current_route, shadow_route,
        current_agent, shadow_agent, current_capability_context,
        shadow_capability_context, comparison, filters, fallback, warnings,
        router_latency_ms, bridge_overhead_ms, deduped.
    #>
    [CmdletBinding()]
    param(
        [string]$TraceId,
        [string]$TaskId,
        [string]$Timestamp,
        [string]$RouterVersion,
        [string]$LogicalHash,
        [string]$CurrentAgent,
        [string[]]$CurrentSkills,
        [string]$ShadowAgent,
        [string[]]$ShadowSkills,
        [string[]]$ShadowClasses,
        [bool]$ShadowDirect,
        [string]$TaskType,
        [string[]]$DomainHints,
        [string]$Risk,
        [string]$ReadWriteMode,
        [int]$ConstraintsCount,
        [string]$Comparison,
        [string[]]$Filters,
        [bool]$Fallback,
        [string[]]$Warnings,
        [int]$RouterLatencyMs,
        [int]$BridgeOverheadMs,
        [bool]$Deduped = $false
    )
    $curSkills = @(Get-ShadowCanonicalArray -InputObject $CurrentSkills)
    $shSkills = @(Get-ShadowCanonicalArray -InputObject $ShadowSkills)
    $shClasses = @(Get-ShadowCanonicalArray -InputObject $ShadowClasses)
    $hintHashes = @(Get-ShadowTelemetryHints -DomainHints $DomainHints)
    $filterList = @(Get-ShadowCanonicalFilters -InputObject $Filters)
    $warnList = @(Get-ShadowCanonicalWarnings -InputObject $Warnings)
    $safeHash = Get-ShadowSafeLogicalHash -LogicalHash $LogicalHash
    $safeTaskType = Get-ShadowCanonicalTaskType -TaskType ([string]$TaskType)
    $safeRisk = Get-ShadowCanonicalRisk -Risk ([string]$Risk)
    $safeRw = ([string]$ReadWriteMode).Trim().ToLowerInvariant()
    if (($safeRw -cne 'read') -and ($safeRw -cne 'write') -and ($safeRw -cne '')) { $safeRw = '' }
    $safeCur = ([string]$CurrentAgent).Trim()
    if (-not [string]::IsNullOrWhiteSpace($safeCur) -and -not (Test-ShadowCanonicalId -Id $safeCur)) { $safeCur = '' }
    $safeShadow = ([string]$ShadowAgent).Trim()
    if (-not [string]::IsNullOrWhiteSpace($safeShadow) -and -not (Test-ShadowCanonicalId -Id $safeShadow)) { $safeShadow = '' }
    $safeTaskId = ''
    try {
        $tidTrim = ([string]$TaskId).Trim()
        if (Test-ShadowTaskId -TaskId $tidTrim) { $safeTaskId = Get-ShadowTaskIdHash -TaskId $tidTrim }
    }
    catch { $safeTaskId = '' }
    $line = [PSCustomObject]@{
        trace_id                  = [string]$TraceId
        task_id                   = $safeTaskId
        timestamp                 = [string]$Timestamp
        router_version            = [string]$RouterVersion
        registry_logical_hash     = $safeHash
        current_route             = [PSCustomObject]@{ agent = $safeCur; skills = ([string[]]$curSkills) }
        shadow_route              = [PSCustomObject]@{ agent = $safeShadow; skills = ([string[]]$shSkills); capability_classes = ([string[]]$shClasses); direct = [bool]$ShadowDirect }
        current_agent             = $safeCur
        shadow_agent              = $safeShadow
        current_capability_context = [PSCustomObject]@{ task_type = $safeTaskType; domain_hints = ([string[]]$hintHashes); risk = $safeRisk; read_write_mode = $safeRw; constraints_count = [int]$ConstraintsCount }
        shadow_capability_context = [PSCustomObject]@{ capability_classes = ([string[]]$shClasses); filters = ([string[]]$filterList) }
        comparison                = [string]$Comparison
        filters                   = ([string[]]$filterList)
        fallback                  = [bool]$Fallback
        warnings                  = ([string[]]$warnList)
        router_latency_ms         = [int]$RouterLatencyMs
        bridge_overhead_ms        = [int]$BridgeOverheadMs
        deduped                   = [bool]$Deduped
    }
    return $line
}

function Write-ShadowTelemetryLine {
    <#
    .SYNOPSIS
        Append JSONL fail-closed: falha de telemetria nunca bloqueia.
    #>
    [CmdletBinding()]
    param($Line, [Parameter(Mandatory = $true)][string]$TelemetryPath)
    try {
        $parent = Split-Path -Parent $TelemetryPath
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $text = ($Line | ConvertTo-Json -Depth 10 -Compress)
        $text = ($text -replace "`r`n", "" -replace "`r", "" -replace "`n", "")
        [IO.File]::AppendAllText($TelemetryPath, ($text + "`n"), [Text.UTF8Encoding]::new($false))
        return $true
    }
    catch { return $false }
}

function New-ShadowResult {
    [CmdletBinding()]
    param(
        [string]$RouterVersion, [string]$TaskId, $ProposedAgent,
        [string[]]$ProposedSkills, [string[]]$ProposedClasses, [string[]]$Filters,
        [string]$Reason, [string]$ConfidenceClass, [bool]$FallbackUsed,
        [string[]]$Warnings, [string]$Comparison, [string]$Status,
        [int]$RouterLatencyMs, [int]$BridgeOverheadMs, [bool]$Deduped = $false
    )
    return [PSCustomObject]@{
        router_version              = [string]$RouterVersion
        task_id                     = [string]$TaskId
        proposed_agent              = $ProposedAgent
        proposed_skills             = ([string[]]@(ConvertTo-ShadowStringArray -InputObject $ProposedSkills))
        proposed_capability_classes = ([string[]]@(Get-ShadowCanonicalArray -InputObject $ProposedClasses))
        filters_applied             = ([string[]]@(Get-ShadowCanonicalFilters -InputObject $Filters))
        reason                      = [string]$Reason
        confidence_class            = [string]$ConfidenceClass
        fallback_used               = [bool]$FallbackUsed
        warnings                    = ([string[]]@(ConvertTo-ShadowStringArray -InputObject $Warnings))
        comparison                  = [string]$Comparison
        status                      = [string]$Status
        router_latency_ms           = [int]$RouterLatencyMs
        bridge_overhead_ms          = [int]$BridgeOverheadMs
        deduped                     = [bool]$Deduped
    }
}

function Write-ShadowTelemetryForResult {
    [CmdletBinding()]
    param(
        $Result, $Ctx, [string]$RouterVersion, [string]$LogicalHash,
        [string]$ShadowAgentStr, [string[]]$PropSkills, [string[]]$PropClasses,
        [bool]$ShadowDirect, [string[]]$Filters, [int]$RouterLatencyMs, [int]$OverheadMs,
        [string]$TelemetryPath, [bool]$NoTelemetry, [bool]$Deduped = $false
    )
    if ([bool]$NoTelemetry) { return $Result }
    try {
        $trace = [guid]::NewGuid().ToString('N')
        $ts = ([DateTimeOffset]::UtcNow.ToString('o'))
        $curAgent = ''
        $curSkills = @()
        $tt = ''
        $hints = @()
        $risk = ''
        $rw = ''
        $cc = 0
        try { if ($null -ne $Ctx) {
            $curAgent = [string]$Ctx.CurrentAgent
            $curSkills = @($Ctx.CurrentSkills)
            $tt = [string]$Ctx.TaskType
            $hints = @($Ctx.DomainHints)
            $risk = [string]$Ctx.Risk
            $rw = [string]$Ctx.ReadWrite
            $cc = [int]$Ctx.ConstraintsCount
        } } catch { }
        $line = New-ShadowTelemetryLine -TraceId $trace -TaskId ([string]$Result.task_id) -Timestamp $ts -RouterVersion $RouterVersion -LogicalHash $LogicalHash -CurrentAgent $curAgent -CurrentSkills $curSkills -ShadowAgent $ShadowAgentStr -ShadowSkills $PropSkills -ShadowClasses $PropClasses -ShadowDirect ([bool]$ShadowDirect) -TaskType $tt -DomainHints $hints -Risk $risk -ReadWriteMode $rw -ConstraintsCount $cc -Comparison ([string]$Result.comparison) -Filters $Filters -Fallback ([bool]$Result.fallback_used) -Warnings @($Result.warnings) -RouterLatencyMs $RouterLatencyMs -BridgeOverheadMs $OverheadMs -Deduped ([bool]$Deduped)
        $ok = Write-ShadowTelemetryLine -Line $line -TelemetryPath $TelemetryPath
        if (-not $ok) { $Result.warnings = ([string[]]@(@($Result.warnings) + @('telemetry unavailable'))) }
    }
    catch { }
    return $Result
}

function Invoke-CapabilityShadow {
    <#
    .SYNOPSIS
        Orquestra uma consulta shadow unica. Fail-safe: nunca lanca.
        Default: Router em processo isolado com timeout rigido
        (-TimeoutSeconds, default 20s), contexto por STDIN, kill no
        timeout. Com -InProcess (opt-in, testes de velocidade), consulta
        no mesmo processo SEM timeout rigido. -RouterProcess e alias
        legado do modo isolado (default atual).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskFile,
        [string]$RouterPath,
        [string]$RegistryPath,
        [string]$PolicyPath,
        [string]$FlagsPath,
        [string]$ConfigPath,
        [int]$TimeoutSeconds = 20,
        [string]$TelemetryPath,
        [string]$RepoRoot,
        [switch]$NoTelemetry,
        [switch]$RouterProcess,
        [switch]$InProcess,
        [switch]$AllowRepeat
    )
    $bridgeSw = [System.Diagnostics.Stopwatch]::StartNew()
    $taskId = ''
    try {
        $repo = Get-ShadowRepoRoot -RepoRoot $RepoRoot
        $defaultRouter = Join-Path $repo 'scripts\v3\route-capabilities.ps1'
        if ([string]::IsNullOrWhiteSpace($RouterPath)) { $RouterPath = $defaultRouter }
        if ([string]::IsNullOrWhiteSpace($RegistryPath)) { $RegistryPath = Join-Path $repo 'cache\v3\capability-registry.json' }
        if ([string]::IsNullOrWhiteSpace($PolicyPath)) { $PolicyPath = Join-Path $repo 'source\registry\capability-policy.json' }
        if ([string]::IsNullOrWhiteSpace($FlagsPath)) { $FlagsPath = Join-Path $repo 'source\registry\capability-flags.json' }
        if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
            $ConfigPath = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
        }
        if ($TimeoutSeconds -lt 1) { $TimeoutSeconds = 20 }
        if ($TimeoutSeconds -gt 60) { $TimeoutSeconds = 60 }
        if ([string]::IsNullOrWhiteSpace($TelemetryPath)) {
            $stamp = ([DateTimeOffset]::UtcNow.ToString('yyyyMMdd'))
            $TelemetryPath = Join-Path $repo ('cache\v3\telemetry\live-shadow-' + $stamp + '.jsonl')
        }
        $useInProcess = ([bool]$InProcess)
        $flags = Read-ShadowFlags -FlagsPath $FlagsPath
        if (-not (Test-ShadowEnabled -Flags $flags)) {
            try {
                $probe = Read-ShadowTask -TaskFile $TaskFile
                if ((Test-ShadowTaskId -TaskId ([string]$probe.TaskId))) { $taskId = ([string]$probe.TaskId).Trim() }
            }
            catch { }
            $bridgeSw.Stop()
            return (New-ShadowResult -RouterVersion '1' -TaskId $taskId -ProposedAgent $null -ProposedSkills @() -ProposedClasses @() -Filters @() -Reason 'shadow disabled by flag (capability_router.shadow != true); nenhuma consulta, nenhuma telemetria' -ConfidenceClass 'low' -FallbackUsed $false -Warnings @('shadow disabled by flag') -Comparison 'NOT_COMPARABLE' -Status 'disabled' -RouterLatencyMs 0 -BridgeOverheadMs ([int]$bridgeSw.Elapsed.TotalMilliseconds))
        }
        $task = $null
        try { $task = Read-ShadowTask -TaskFile $TaskFile }
        catch {
            $bridgeSw.Stop()
            return (New-ShadowResult -RouterVersion '1' -TaskId '' -ProposedAgent $null -ProposedSkills @() -ProposedClasses @() -Filters @() -Reason ('shadow input invalido: {0}' -f $_.Exception.Message) -ConfidenceClass 'low' -FallbackUsed $false -Warnings @('shadow input invalido') -Comparison 'NOT_COMPARABLE' -Status 'failed' -RouterLatencyMs 0 -BridgeOverheadMs ([int]$bridgeSw.Elapsed.TotalMilliseconds))
        }
        $taskId = ([string]$task.TaskId).Trim()
        $ctx = Get-ShadowValidatedContext -Task $task
        if (-not [bool]$ctx.InputValid) {
            $bridgeSw.Stop()
            return (New-ShadowResult -RouterVersion '1' -TaskId ([string]$ctx.TaskId) -ProposedAgent $null -ProposedSkills @() -ProposedClasses @() -Filters @() -Reason ([string]$ctx.Reason) -ConfidenceClass 'low' -FallbackUsed $false -Warnings @('shadow input invalido') -Comparison 'NOT_COMPARABLE' -Status 'failed' -RouterLatencyMs 0 -BridgeOverheadMs ([int]$bridgeSw.Elapsed.TotalMilliseconds))
        }
        $taskId = [string]$ctx.TaskId
        $baseWarnings = @(ConvertTo-ShadowStringArray -InputObject @($ctx.Warnings))
        $policy = $null
        try {
            $fn = Get-Command 'Import-RouterPolicy' -ErrorAction SilentlyContinue
            if ($null -ne $fn) { $policy = Import-RouterPolicy -PolicyPath $PolicyPath }
        }
        catch { $policy = $null }
        $routerVersion = Get-ShadowRouterVersion -Policy $policy
        $seenPath = Get-ShadowSeenPath -RepoRoot $repo
        if (-not [bool]$AllowRepeat) {
            $dd = Test-ShadowDeduped -SeenPath $seenPath -TaskId $taskId -TtlSeconds 60
            if ([bool]$dd.Deduped) {
                $bridgeSw.Stop()
                $dw = @(@($baseWarnings) + @('shadow deduped (TTL)'))
                $result = New-ShadowResult -RouterVersion $routerVersion -TaskId $taskId -ProposedAgent $null -ProposedSkills @() -ProposedClasses @() -Filters @() -Reason 'shadow deduped: mesma subtarefa dentro do TTL 60s; sem nova consulta ao Router' -ConfidenceClass 'low' -FallbackUsed $false -Warnings $dw -Comparison 'NOT_COMPARABLE' -Status 'deduped' -RouterLatencyMs 0 -BridgeOverheadMs ([int]$bridgeSw.Elapsed.TotalMilliseconds) -Deduped $true
                $result = Write-ShadowTelemetryForResult -Result $result -Ctx $ctx -RouterVersion $routerVersion -LogicalHash 'unknown' -ShadowAgentStr '' -PropSkills @() -PropClasses @() -ShadowDirect $false -Filters @() -RouterLatencyMs 0 -OverheadMs ([int]$result.bridge_overhead_ms) -TelemetryPath $TelemetryPath -NoTelemetry ([bool]$NoTelemetry) -Deduped $true
                return $result
            }
        }
        $repeatNote = ''
        try {
            $dd2 = Test-ShadowDeduped -SeenPath $seenPath -TaskId $taskId -TtlSeconds 60
            if ([bool]$dd2.RepeatOutsideTtl) { $repeatNote = 'shadow repeat (fora do TTL)' }
        }
        catch { }
        $shadowClaim = $null
        try { $shadowClaim = Try-AcquireShadowClaim -RepoRoot $repo -TaskId $taskId } catch { $shadowClaim = $null }
        if ($null -eq $shadowClaim -or -not [bool]$shadowClaim.Acquired) {
            try {
                if ($null -ne $shadowClaim -and $null -ne $shadowClaim.Stream) {
                    try { $shadowClaim.Stream.Close() } catch { }
                    try { $shadowClaim.Stream.Dispose() } catch { }
                }
            }
            catch { }
            $bridgeSw.Stop()
            $dwc = @(@($baseWarnings) + @('shadow deduped (concurrent claim)'))
            if (-not [string]::IsNullOrWhiteSpace($repeatNote)) { $dwc = @($dwc + @($repeatNote)) }
            $result = New-ShadowResult -RouterVersion $routerVersion -TaskId $taskId -ProposedAgent $null -ProposedSkills @() -ProposedClasses @() -Filters @() -Reason 'shadow deduped: consulta concorrente para mesma subtarefa; sem nova consulta ao Router' -ConfidenceClass 'low' -FallbackUsed $false -Warnings $dwc -Comparison 'NOT_COMPARABLE' -Status 'deduped' -RouterLatencyMs 0 -BridgeOverheadMs ([int]$bridgeSw.Elapsed.TotalMilliseconds) -Deduped $true
            $result = Write-ShadowTelemetryForResult -Result $result -Ctx $ctx -RouterVersion $routerVersion -LogicalHash 'unknown' -ShadowAgentStr '' -PropSkills @() -PropClasses @() -ShadowDirect $false -Filters @() -RouterLatencyMs 0 -OverheadMs ([int]$result.bridge_overhead_ms) -TelemetryPath $TelemetryPath -NoTelemetry ([bool]$NoTelemetry) -Deduped $true
            return $result
        }
        $regStatus = Get-ShadowRegistryStatus -RegistryPath $RegistryPath -RepoRoot $repo -Policy $policy
        $logicalHash = [string]$regStatus.LogicalHash
        $registryMissing = (-not [bool]$regStatus.Available)
        $registryStale = ([bool]$regStatus.Available -and [bool]$regStatus.Stale)
        $warnList = New-Object System.Collections.Generic.List[string]
        foreach ($w in @($baseWarnings)) { $warnList.Add($w) }
        if (-not [string]::IsNullOrWhiteSpace($repeatNote)) { $warnList.Add($repeatNote) }
        if ($registryMissing) {
            $warnList.Add(('shadow unavailable: ' + ((@(ConvertTo-ShadowStringArray -InputObject @($regStatus.Reasons)) | ForEach-Object { "$_" }) -join ' | ')))
        }
        elseif ($registryStale) {
            $warnList.Add('registry stale')
        }
        $preFreshness = Get-ShadowRegistryStatusName -Available ([bool]$regStatus.Available) -Stale ([bool]$regStatus.Stale) -Reasons @($regStatus.Reasons)
        if ($preFreshness -cne 'fresh') {
            $bridgeSw.Stop()
            $overhead = [int]$bridgeSw.Elapsed.TotalMilliseconds
            $result = New-ShadowResult -RouterVersion $routerVersion -TaskId $taskId -ProposedAgent $null -ProposedSkills @() -ProposedClasses @() -Filters @('status', 'permission', 'trust', 'unknown-deny', 'freshness') -Reason ('shadow degraded: registry {0} no pre-check; sem proposta comparavel (sem bloquear)' -f $preFreshness) -ConfidenceClass 'low' -FallbackUsed $true -Warnings $warnList.ToArray() -Comparison 'NOT_COMPARABLE' -Status 'degraded' -RouterLatencyMs 0 -BridgeOverheadMs $overhead
            try { Write-ShadowSeen -SeenPath $seenPath -TaskId $taskId | Out-Null } catch { }
            try { Release-ShadowClaim -Claim $shadowClaim } catch { }
            $result = Write-ShadowTelemetryForResult -Result $result -Ctx $ctx -RouterVersion $routerVersion -LogicalHash $logicalHash -ShadowAgentStr '' -PropSkills @() -PropClasses @() -ShadowDirect $false -Filters @('status', 'permission', 'trust', 'unknown-deny', 'freshness') -RouterLatencyMs 0 -OverheadMs $overhead -TelemetryPath $TelemetryPath -NoTelemetry ([bool]$NoTelemetry)
            return $result
        }
        $stdinDoc = [ordered]@{
            objective = [string]$ctx.Objective
            task_type = [string]$ctx.TaskType
            domain    = [string]$ctx.Domain
            risk      = [string]$ctx.Risk
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$ctx.ReadWrite)) { $stdinDoc['read_write'] = [string]$ctx.ReadWrite }
        $stdinJson = (($stdinDoc | ConvertTo-Json -Depth 5 -Compress) + "`n")
        $isCustomShim = $false
        try {
            if (-not [string]::IsNullOrWhiteSpace($RouterPath)) {
                $fullGiven = [IO.Path]::GetFullPath($RouterPath)
                $fullDef = [IO.Path]::GetFullPath($defaultRouter)
                if (-not $fullGiven.Equals($fullDef, [System.StringComparison]::OrdinalIgnoreCase)) { $isCustomShim = $true }
            }
        }
        catch { $isCustomShim = $true }
        if ($useInProcess -and -not $isCustomShim) {
            $inProc = $null
            try {
                $inProc = Invoke-ShadowRouterInProcess -Objective ([string]$ctx.Objective) -TaskType ([string]$ctx.TaskType) -Domain ([string]$ctx.Domain) -Risk ([string]$ctx.Risk) -ReadWrite ([string]$ctx.ReadWrite) -RegistryPath $RegistryPath -ConfigPath $ConfigPath -Policy $policy
            }
            catch { $inProc = $null }
            $routerLatency = 0
            try { if ($null -ne $inProc) { $routerLatency = [int]$inProc.LatencyMs } } catch { $routerLatency = 0 }
            if (($null -eq $inProc) -or (-not [bool]$inProc.Succeeded) -or ($null -eq $inProc.RouterResult) -or ($null -eq $inProc.RouterResult.route)) {
                $bridgeSw.Stop()
                $totalMs = [int]$bridgeSw.Elapsed.TotalMilliseconds
                $overhead = $totalMs - $routerLatency
                if ($overhead -lt 0) { $overhead = 0 }
                $result = New-ShadowResult -RouterVersion $routerVersion -TaskId $taskId -ProposedAgent $null -ProposedSkills @() -ProposedClasses @() -Filters @() -Reason 'shadow consulta falhou no processo (sem bloquear)' -ConfidenceClass 'low' -FallbackUsed $false -Warnings (@($warnList.ToArray()) + @('shadow unavailable: router')) -Comparison 'NOT_COMPARABLE' -Status 'failed' -RouterLatencyMs $routerLatency -BridgeOverheadMs $overhead
                try { Write-ShadowSeen -SeenPath $seenPath -TaskId $taskId | Out-Null } catch { }
                try { Release-ShadowClaim -Claim $shadowClaim } catch { }
                $result = Write-ShadowTelemetryForResult -Result $result -Ctx $ctx -RouterVersion $routerVersion -LogicalHash $logicalHash -ShadowAgentStr '' -PropSkills @() -PropClasses @() -ShadowDirect $false -Filters @() -RouterLatencyMs $routerLatency -OverheadMs $overhead -TelemetryPath $TelemetryPath -NoTelemetry ([bool]$NoTelemetry)
                return $result
            }
            $res = $inProc.RouterResult
            $propAgent = $null
            $propSkills = @()
            $filters = @()
            $reason = ''
            $fallbackUsed = $false
            $shadowDirect = $false
            $confClass = 'low'
            try { if ($null -ne $res.route.agent) { $tmp = ([string]$res.route.agent).Trim(); if ((Test-ShadowCanonicalId -Id $tmp)) { $propAgent = $tmp } else { $propAgent = $null } } else { $propAgent = $null } } catch { $propAgent = $null }
            try { $propSkills = @(Get-ShadowCanonicalArray -InputObject @($res.route.skills)) } catch { $propSkills = @() }
            try { $filters = @(Get-ShadowCanonicalFilters -InputObject @($res.filters_applied)) } catch { $filters = @() }
            try { $reason = [string]$res.reason } catch { $reason = '' }
            try { $fallbackUsed = [bool]$res.fallback_used } catch { $fallbackUsed = $false }
            try { $shadowDirect = [bool]$res.route.direct } catch { $shadowDirect = $false }
            try { $confClass = Get-ShadowConfidenceClass -Confidence $res.confidence } catch { $confClass = 'low' }
            $inProcRegStatus = 'fresh'
            try {
                $fnReg2 = Get-Command 'Read-RouterRegistry' -ErrorAction SilentlyContinue
                if ($null -ne $fnReg2) {
                    $recheck = Read-RouterRegistry -RegistryPath $RegistryPath -Policy $policy -MaxAgeSeconds -1
                    $inProcRegStatus = Get-ShadowRegistryStatusName -Available ([bool]$recheck.Available) -Stale ([bool]$recheck.Stale) -Reasons @($recheck.StaleReasons)
                    try { if ($null -ne $recheck.Registry -and $null -ne $recheck.Registry.registry -and $null -ne $recheck.Registry.registry.logical_hash) { $logicalHash = [string]$recheck.Registry.registry.logical_hash } } catch { }
                }
            }
            catch { }
            if ($inProcRegStatus -cne 'fresh') {
                $bridgeSw.Stop()
                $totalMs = [int]$bridgeSw.Elapsed.TotalMilliseconds
                $overhead = $totalMs - $routerLatency
                if ($overhead -lt 0) { $overhead = 0 }
                $dwarn = @($warnList.ToArray()) + @('registry stale')
                $result = New-ShadowResult -RouterVersion $routerVersion -TaskId $taskId -ProposedAgent $null -ProposedSkills @() -ProposedClasses @() -Filters @('status', 'permission', 'trust', 'unknown-deny', 'freshness') -Reason ('shadow degraded: registry {0} na reconsulta (TOCTOU fechado; sem bloquear)' -f $inProcRegStatus) -ConfidenceClass 'low' -FallbackUsed $true -Warnings $dwarn -Comparison 'NOT_COMPARABLE' -Status 'degraded' -RouterLatencyMs $routerLatency -BridgeOverheadMs $overhead
                try { Write-ShadowSeen -SeenPath $seenPath -TaskId $taskId | Out-Null } catch { }
                try { Release-ShadowClaim -Claim $shadowClaim } catch { }
                $result = Write-ShadowTelemetryForResult -Result $result -Ctx $ctx -RouterVersion $routerVersion -LogicalHash $logicalHash -ShadowAgentStr '' -PropSkills @() -PropClasses @() -ShadowDirect $false -Filters @('status', 'permission', 'trust', 'unknown-deny', 'freshness') -RouterLatencyMs $routerLatency -OverheadMs $overhead -TelemetryPath $TelemetryPath -NoTelemetry ([bool]$NoTelemetry)
                return $result
            }
            $propClasses = @()
            try {
                $fnReq = Get-Command 'Get-RouterRequiredCapabilities' -ErrorAction SilentlyContinue
                $fnTask = Get-Command 'New-RouterTask' -ErrorAction SilentlyContinue
                if (($null -ne $fnReq) -and ($null -ne $fnTask)) {
                    $rt = New-RouterTask -Objective ([string]$ctx.Objective) -TaskType ([string]$ctx.TaskType) -Domain ([string]$ctx.Domain) -Risk ([string]$ctx.Risk) -ReadWrite ([string]$ctx.ReadWrite)
                    $propClasses = @(Get-ShadowCanonicalArray -InputObject @(Get-RouterRequiredCapabilities -Task $rt -Policy $policy))
                }
            }
            catch { $propClasses = @() }
            $status = 'success'
            if ($registryMissing) { $status = 'failed' }
            $cmp = 'NOT_COMPARABLE'
            if (($status -ceq 'success') -and ($null -ne $propAgent) -and (-not [string]::IsNullOrWhiteSpace([string]$propAgent))) {
                $cmp = Get-ShadowComparison -ProposedAgent ([string]$propAgent) -CurrentAgent ([string]$ctx.CurrentAgent) -ExpectedAgent ([string]$ctx.ExpectedAgent) -HasCurrentRoute ([bool]$task.HasCurrentRoute)
            }
            if ($registryMissing) { $propAgent = $null; $cmp = 'NOT_COMPARABLE' }
            $bridgeSw.Stop()
            $totalMs = [int]$bridgeSw.Elapsed.TotalMilliseconds
            $overhead = $totalMs - $routerLatency
            if ($overhead -lt 0) { $overhead = 0 }
            $result = New-ShadowResult -RouterVersion $routerVersion -TaskId $taskId -ProposedAgent $propAgent -ProposedSkills $propSkills -ProposedClasses $propClasses -Filters $filters -Reason $reason -ConfidenceClass $confClass -FallbackUsed ([bool]$fallbackUsed) -Warnings $warnList.ToArray() -Comparison $cmp -Status $status -RouterLatencyMs $routerLatency -BridgeOverheadMs $overhead
            try { Write-ShadowSeen -SeenPath $seenPath -TaskId $taskId | Out-Null } catch { }
            try { Release-ShadowClaim -Claim $shadowClaim } catch { }
            $shadowAgentStr = ''
            if ($null -ne $propAgent) { $shadowAgentStr = [string]$propAgent }
            $result = Write-ShadowTelemetryForResult -Result $result -Ctx $ctx -RouterVersion $routerVersion -LogicalHash $logicalHash -ShadowAgentStr $shadowAgentStr -PropSkills $propSkills -PropClasses $propClasses -ShadowDirect ([bool]$shadowDirect) -Filters $filters -RouterLatencyMs $routerLatency -OverheadMs $overhead -TelemetryPath $TelemetryPath -NoTelemetry ([bool]$NoTelemetry)
            return $result
        }
        $call = $null
        try {
            if ($isCustomShim) {
                $call = Invoke-ShadowRouterProcess -RouterPath $RouterPath -StdinJson $stdinJson -RegistryPath $RegistryPath -ConfigPath $ConfigPath -TimeoutMs ($TimeoutSeconds * 1000)
            }
            else {
                $call = Invoke-ShadowRouterIsolated -StdinJson $stdinJson -RouterLibPath $__shadowRouterLib -RegistryPath $RegistryPath -ConfigPath $ConfigPath -PolicyPath $PolicyPath -TimeoutMs ($TimeoutSeconds * 1000)
            }
        }
        catch { $call = $null }
        $routerLatency = 0
        try { if ($null -ne $call) { $routerLatency = [int]$call.LatencyMs } } catch { $routerLatency = 0 }
        if ($null -ne $call -and [bool]$call.TimedOut) {
            $cmp = 'NOT_COMPARABLE'
            $bridgeSw.Stop()
            $totalMs = [int]$bridgeSw.Elapsed.TotalMilliseconds
            $overhead = $totalMs - $routerLatency
            if ($overhead -lt 0) { $overhead = 0 }
            $result = New-ShadowResult -RouterVersion $routerVersion -TaskId $taskId -ProposedAgent $null -ProposedSkills @() -ProposedClasses @() -Filters @() -Reason ('shadow timeout apos {0}s (router isolado via stdin; sem bloquear)' -f $TimeoutSeconds) -ConfidenceClass 'low' -FallbackUsed $false -Warnings (@($warnList.ToArray()) + @('shadow timeout')) -Comparison $cmp -Status 'timeout' -RouterLatencyMs $routerLatency -BridgeOverheadMs $overhead
            try { Write-ShadowSeen -SeenPath $seenPath -TaskId $taskId | Out-Null } catch { }
            try { Release-ShadowClaim -Claim $shadowClaim } catch { }
            $result = Write-ShadowTelemetryForResult -Result $result -Ctx $ctx -RouterVersion $routerVersion -LogicalHash $logicalHash -ShadowAgentStr '' -PropSkills @() -PropClasses @() -ShadowDirect $false -Filters @() -RouterLatencyMs $routerLatency -OverheadMs $overhead -TelemetryPath $TelemetryPath -NoTelemetry ([bool]$NoTelemetry)
            return $result
        }
        $routerObj = $null
        $parseOk = $false
        try {
            if ($null -ne $call -and [int]$call.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$call.Stdout)) {
                $routerObj = ([string]$call.Stdout | ConvertFrom-Json)
                if ($null -ne $routerObj -and $null -ne $routerObj.route) { $parseOk = $true }
            }
        }
        catch { $parseOk = $false }
        if (-not $parseOk) {
            $cmp = 'NOT_COMPARABLE'
            $bridgeSw.Stop()
            $totalMs = [int]$bridgeSw.Elapsed.TotalMilliseconds
            $overhead = $totalMs - $routerLatency
            if ($overhead -lt 0) { $overhead = 0 }
            $result = New-ShadowResult -RouterVersion $routerVersion -TaskId $taskId -ProposedAgent $null -ProposedSkills @() -ProposedClasses @() -Filters @() -Reason 'shadow consulta falhou (router ausente, saida invalida ou exit != 0; sem bloquear)' -ConfidenceClass 'low' -FallbackUsed $false -Warnings (@($warnList.ToArray()) + @('shadow unavailable: router')) -Comparison $cmp -Status 'failed' -RouterLatencyMs $routerLatency -BridgeOverheadMs $overhead
            try { Write-ShadowSeen -SeenPath $seenPath -TaskId $taskId | Out-Null } catch { }
            try { Release-ShadowClaim -Claim $shadowClaim } catch { }
            $result = Write-ShadowTelemetryForResult -Result $result -Ctx $ctx -RouterVersion $routerVersion -LogicalHash $logicalHash -ShadowAgentStr '' -PropSkills @() -PropClasses @() -ShadowDirect $false -Filters @() -RouterLatencyMs $routerLatency -OverheadMs $overhead -TelemetryPath $TelemetryPath -NoTelemetry ([bool]$NoTelemetry)
            return $result
        }
        $propAgent = $null
        $propSkills = @()
        $filters = @()
        $reason = ''
        $fallbackUsed = $false
        $shadowDirect = $false
        $confClass = 'low'
        try { if ($null -ne $routerObj.route.agent) { $tmp = ([string]$routerObj.route.agent).Trim(); if ((Test-ShadowCanonicalId -Id $tmp)) { $propAgent = $tmp } else { $propAgent = $null } } else { $propAgent = $null } } catch { $propAgent = $null }
        try { $propSkills = @(Get-ShadowCanonicalArray -InputObject @($routerObj.route.skills)) } catch { $propSkills = @() }
        try { $filters = @(Get-ShadowCanonicalFilters -InputObject @($routerObj.filters_applied)) } catch { $filters = @() }
        try { $reason = [string]$routerObj.reason } catch { $reason = '' }
        try { $fallbackUsed = [bool]$routerObj.fallback_used } catch { $fallbackUsed = $false }
        try { $shadowDirect = [bool]$routerObj.route.direct } catch { $shadowDirect = $false }
        try { $confClass = Get-ShadowConfidenceClass -Confidence $routerObj.confidence } catch { $confClass = 'low' }
        $childRegStatus = ''
        try {
            if ($null -ne $routerObj.registry_status) { $childRegStatus = ([string]$routerObj.registry_status).Trim().ToLowerInvariant() }
        }
        catch { $childRegStatus = '' }
        $postRegStatus = 'fresh'
        try {
            $postCheck = Get-ShadowRegistryStatus -RegistryPath $RegistryPath -RepoRoot $repo -Policy $policy
            $postRegStatus = Get-ShadowRegistryStatusName -Available ([bool]$postCheck.Available) -Stale ([bool]$postCheck.Stale) -Reasons @($postCheck.StaleReasons)
            try { if ($null -ne $postCheck.LogicalHash -and -not [string]::IsNullOrWhiteSpace([string]$postCheck.LogicalHash)) { $logicalHash = [string]$postCheck.LogicalHash } } catch { }
        }
        catch { $postRegStatus = 'fresh' }
        $freshnessHit = ''
        if (@('stale', 'missing', 'corrupt', 'drift') -ccontains $childRegStatus) { $freshnessHit = $childRegStatus }
        elseif (@('stale', 'missing', 'corrupt', 'drift') -ccontains $postRegStatus) { $freshnessHit = $postRegStatus }
        if (-not [string]::IsNullOrWhiteSpace($freshnessHit)) {
            $bridgeSw.Stop()
            $totalMs = [int]$bridgeSw.Elapsed.TotalMilliseconds
            $overhead = $totalMs - $routerLatency
            if ($overhead -lt 0) { $overhead = 0 }
            $dwarn = @($warnList.ToArray()) + @('registry stale')
            $result = New-ShadowResult -RouterVersion $routerVersion -TaskId $taskId -ProposedAgent $null -ProposedSkills @() -ProposedClasses @() -Filters @('status', 'permission', 'trust', 'unknown-deny', 'freshness') -Reason ('shadow degraded: registry {0} pelo filho/pos-checagem (TOCTOU fechado; sem bloquear)' -f $freshnessHit) -ConfidenceClass 'low' -FallbackUsed $true -Warnings $dwarn -Comparison 'NOT_COMPARABLE' -Status 'degraded' -RouterLatencyMs $routerLatency -BridgeOverheadMs $overhead
            try { Write-ShadowSeen -SeenPath $seenPath -TaskId $taskId | Out-Null } catch { }
            try { Release-ShadowClaim -Claim $shadowClaim } catch { }
            $result = Write-ShadowTelemetryForResult -Result $result -Ctx $ctx -RouterVersion $routerVersion -LogicalHash $logicalHash -ShadowAgentStr '' -PropSkills @() -PropClasses @() -ShadowDirect $false -Filters @('status', 'permission', 'trust', 'unknown-deny', 'freshness') -RouterLatencyMs $routerLatency -OverheadMs $overhead -TelemetryPath $TelemetryPath -NoTelemetry ([bool]$NoTelemetry)
            return $result
        }
        $propClasses = @()
        try {
            $fnReq = Get-Command 'Get-RouterRequiredCapabilities' -ErrorAction SilentlyContinue
            $fnTask = Get-Command 'New-RouterTask' -ErrorAction SilentlyContinue
            if (($null -ne $fnReq) -and ($null -ne $fnTask)) {
                $rt = New-RouterTask -Objective ([string]$ctx.Objective) -TaskType ([string]$ctx.TaskType) -Domain ([string]$ctx.Domain) -Risk ([string]$ctx.Risk) -ReadWrite ([string]$ctx.ReadWrite)
                $propClasses = @(Get-ShadowCanonicalArray -InputObject @(Get-RouterRequiredCapabilities -Task $rt -Policy $policy))
            }
        }
        catch { $propClasses = @() }
        $status = 'success'
        if ($registryMissing) { $status = 'failed' }
        $cmp = 'NOT_COMPARABLE'
        if (($status -ceq 'success') -and ($null -ne $propAgent) -and (-not [string]::IsNullOrWhiteSpace([string]$propAgent))) {
            $cmp = Get-ShadowComparison -ProposedAgent ([string]$propAgent) -CurrentAgent ([string]$ctx.CurrentAgent) -ExpectedAgent ([string]$ctx.ExpectedAgent) -HasCurrentRoute ([bool]$task.HasCurrentRoute)
        }
        if ($registryMissing) { $propAgent = $null; $cmp = 'NOT_COMPARABLE' }
        $bridgeSw.Stop()
        $totalMs = [int]$bridgeSw.Elapsed.TotalMilliseconds
        $overhead = $totalMs - $routerLatency
        if ($overhead -lt 0) { $overhead = 0 }
        $result = New-ShadowResult -RouterVersion $routerVersion -TaskId $taskId -ProposedAgent $propAgent -ProposedSkills $propSkills -ProposedClasses $propClasses -Filters $filters -Reason $reason -ConfidenceClass $confClass -FallbackUsed ([bool]$fallbackUsed) -Warnings $warnList.ToArray() -Comparison $cmp -Status $status -RouterLatencyMs $routerLatency -BridgeOverheadMs $overhead
        try { Write-ShadowSeen -SeenPath $seenPath -TaskId $taskId | Out-Null } catch { }
        try { Release-ShadowClaim -Claim $shadowClaim } catch { }
        $shadowAgentStr = ''
        if ($null -ne $propAgent) { $shadowAgentStr = [string]$propAgent }
        $result = Write-ShadowTelemetryForResult -Result $result -Ctx $ctx -RouterVersion $routerVersion -LogicalHash $logicalHash -ShadowAgentStr $shadowAgentStr -PropSkills $propSkills -PropClasses $propClasses -ShadowDirect ([bool]$shadowDirect) -Filters $filters -RouterLatencyMs $routerLatency -OverheadMs $overhead -TelemetryPath $TelemetryPath -NoTelemetry ([bool]$NoTelemetry)
        return $result
    }
    catch {
        try { $bridgeSw.Stop() } catch { }
        try {
            if ($null -ne $shadowClaim -and [bool]$shadowClaim.Acquired) { Release-ShadowClaim -Claim $shadowClaim }
        }
        catch { }
        $ms = 0
        try { $ms = [int]$bridgeSw.Elapsed.TotalMilliseconds } catch { $ms = 0 }
        return (New-ShadowResult -RouterVersion '1' -TaskId $taskId -ProposedAgent $null -ProposedSkills @() -ProposedClasses @() -Filters @() -Reason 'shadow erro interno contido (fail-safe; sem bloquear)' -ConfidenceClass 'low' -FallbackUsed $false -Warnings @('shadow unavailable: interno') -Comparison 'NOT_COMPARABLE' -Status 'failed' -RouterLatencyMs 0 -BridgeOverheadMs $ms)
    }
}
