<#!
.SYNOPSIS
    V3 Capability Router V1: roteamento deterministico OFFLINE e advisory (Phase 8).
.DESCRIPTION
    Biblioteca dot-sourceable (sem execucao ao carregar). Implementa o Router V1
    deterministico OFFLINE (plano §10/§12, SPEC §13/§14/§25):

      - HARD FILTERS antes do scoring: status em {missing,invalid,disabled};
        permission denied (agente fora da allowlist real de
        agent.build.permission.task, wildcard "*" nunca conta) e forbidden
        (capability requerida em capability_profile.forbidden); trust fora de
        {trusted, trusted_local, approved} para MCPs quando a operacao exigir
        execucao; unknown sob default-deny (unknown_policy=deny_execution);
        stale global conforme policy. relevance nunca vence permission.
      - Scoring deterministico e explicavel (sem ML/semantic/embeddings):
        explicit_trigger + category_match + tag_match + domain_match +
        role_affinity + project_affinity + availability + freshness, com pesos
        em capability-policy.json#routing (documentado na policy).
      - Stage A (role routing): agente entre os allowlisted compativel com
        tipo/dominio; tarefa trivial => direct=true (sem delegacao).
      - Stage B (capability routing): skills por categoria/tags/capability
        classes; MCPs por capability classes (nunca por nome). Top-k 0-3
        (comum), ate 5 (complexo), com clamp (0 = nenhum, sem indexar).
        ELEGIBILIDADE exige relevancia positiva: availability/freshness so
        reponderam candidatos ja relevantes, nunca criam elegibilidade.
      - Fallback: registry ausente/corrompido/stale => fallback_used=true,
        rota pela politica em prosa (keywords->agente; default coder), nunca
        lanca excecao, sem bloquear a tarefa. Com allowlist informada, o
        fallback NUNCA recomenda agente fora da allowlist: retorna
        agent=null + blocked=true.
      - Shadow/offline: comparacao simples e deterministica com baseline
        opcional (equal|v3_better|v3_worse|unclear). NAO instrui o Planner vivo.
      - Poisoning: description/tags de skill/MCP sao DADOS; nunca alteram
        trust/policy/permission; hard filters usam SOMENTE policy/registry
        (status, allowlist, forbidden, trust curado, unknown_policy,
        freshness). Description nunca entra no scoring.
      - Freshness: respeita registry.freshness (source_fingerprint,
        runtime_version, idade); stale => fallback conforme policy.

    Esta biblioteca nao le flags nem escreve arquivos; o guard de flags vive
    em route-accept.ps1 (execucao) e shadow-route.ps1 (observacao).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-RouterRepoRoot {
    [CmdletBinding()]
    param([string]$RepoRoot)
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { return $RepoRoot }
    return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
}

function Read-RouterUtf8Text {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))
}

function Convert-RouterNormalizedText {
    <#
    .SYNOPSIS
        Normalizacao Unicode para matching (Phase 8 fix Rev HIGH: tokenizacao).
        Decompoe FormD e remove marcas NonSpacingMark (diacriticos), depois
        minusculas invariantes. "produção"->"producao", "permissões"->"permissoes",
        "documentação"->"documentacao", "destrutiva" permanece "destrutiva".
        Listas de keywords usam as formas normalizadas. PowerShell 5.1 ok.
    #>
    [CmdletBinding()]
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $formD = ([string]$Text).Normalize([System.Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder ($formD.Length)
    foreach ($ch in $formD.ToCharArray()) {
        $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
        if ($cat -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) { $sb.Append($ch) | Out-Null }
    }
    return ($sb.ToString().ToLowerInvariant())
}

function Test-RouterKeyword {
    <#
    .SYNOPSIS
        Matching boundary-aware para prosa normalizada (hardening H-A/B).
    .DESCRIPTION
        Keyword simples [a-z0-9]+ casa por PREFIXO DE TOKEN: 'ux' nao casa
        'fluxo', 'api' nao casa 'rapido', 'script' nao casa 'description'.
        Keyword com espaco/pontuacao casa por substring (frases como
        'information architecture', 'agent workflow', 'ui:', 'test:').
        Mesma semantica de Test-AcceptanceKeyword, local ao Router para
        processos que nao carregam a Acceptance lib (eval/shadow).
        PowerShell 5.1 compativel, ASCII-only.
    #>
    [CmdletBinding()]
    param([string]$Blob, [string[]]$Words, [string[]]$Exact = @())
    try {
        # Cache de processo por blob: Get-RouterExpectedAgent avalia ~15
        # conjuntos de keywords por tarefa; tokeniza uma vez. Bounded: a
        # tokenizacao e funcao pura do blob (sem policy/registry).
        if ($null -eq $script:RouterTokCache) { $script:RouterTokCache = @{} }
        $key = [string]$Blob
        if (-not $script:RouterTokCache.ContainsKey($key)) {
            $script:RouterTokCache[$key] = @($key -split '[^a-z0-9]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
        $tokens = @($script:RouterTokCache[$key])
        $exactSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($e in @($Exact)) {
            $es = ([string]$e).Trim()
            if (-not [string]::IsNullOrWhiteSpace($es)) { $exactSet.Add($es) | Out-Null }
        }
        if ($exactSet.Count -gt 0) {
            foreach ($tok in $tokens) { if ($exactSet.Contains($tok)) { return $true } }
        }
        foreach ($w in @($Words)) {
            $kw = ([string]$w).Trim()
            if ([string]::IsNullOrWhiteSpace($kw)) { continue }
            if ($kw -match '^[a-z0-9]+$') {
                foreach ($tok in $tokens) {
                    if ($tok.StartsWith($kw, [System.StringComparison]::Ordinal)) { return $true }
                }
            }
            else {
                if (([string]$Blob).Contains($kw)) { return $true }
            }
        }
    }
    catch { }
    return $false
}

function Get-RouterStopwords {
    <#
    .SYNOPSIS
        Stopwords genericas (V3-P8-FIX2 MED Rev): palavras vagas que nunca
        criam relevancia sozinhas para trigger/tag/domain. Normalizadas
        (minusculas, sem diacriticos). 'projeto' sozinho nao implica
        memory.project-history; tarefa vaga => sem skills/MCPs.
        Cache de processo (a lista e constante) para evitar rebuild no loop
        de scoring (uma vez por registro).
    #>
    [CmdletBinding()]
    param()
    if ($null -ne $script:RouterStopwordsCache) { return $script:RouterStopwordsCache }
    $script:RouterStopwordsCache = @('projeto', 'projetos', 'tarefa', 'tarefas', 'arquivo', 'arquivos', 'coisa', 'coisas', 'geral', 'gerais', 'general')
    return $script:RouterStopwordsCache
}

function Test-RouterStopword {
    [CmdletBinding()]
    param([string]$Word)
    $s = Convert-RouterNormalizedText -Text ([string]$Word).Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return $true }
    return (@(Get-RouterStopwords) -ccontains $s)
}

function Import-RouterPolicy {
    [CmdletBinding()]
    param([string]$PolicyPath, [string]$RepoRoot)
    $resolved = $PolicyPath
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        $root = Get-RouterRepoRoot -RepoRoot $RepoRoot
        $resolved = Join-Path $root 'source\registry\capability-policy.json'
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw ("capability-policy.json not found: {0}" -f $resolved)
    }
    $text = Read-RouterUtf8Text -Path $resolved
    $policy = $null
    try { $policy = $text | ConvertFrom-Json }
    catch { throw ("capability-policy.json invalido: {0} ({1})" -f $resolved, $_.Exception.Message) }
    return $policy
}

function Get-RouterWeights {
    [CmdletBinding()]
    param($Policy)
    $defaults = [ordered]@{
        explicit_trigger = 10
        category_match   = 5
        tag_match        = 4
        domain_match     = 4
        role_affinity    = 3
        project_affinity = 2
        availability     = 2
        freshness        = 1
        classification_confidence = 1
    }
    try {
        if ($null -ne $Policy -and $null -ne $Policy.routing -and $null -ne $Policy.routing.weights) {
            $w = $Policy.routing.weights
            foreach ($k in @('explicit_trigger', 'category_match', 'tag_match', 'domain_match', 'role_affinity', 'project_affinity', 'availability', 'freshness', 'classification_confidence')) {
                $prop = $null
                try {
                    if ($w -is [System.Collections.IDictionary]) {
                        if ($w.Contains($k)) { $prop = $w[$k] }
                    }
                    else {
                        $p = $w.PSObject.Properties | Where-Object { $_.Name -ceq $k } | Select-Object -First 1
                        if ($null -ne $p) { $prop = $p.Value }
                    }
                }
                catch { $prop = $null }
                if ($null -ne $prop) {
                    $n = 0
                    try { $n = [int]$prop } catch { $n = 0 }
                    $defaults[$k] = $n
                }
            }
        }
    }
    catch { }
    return $defaults
}

function Get-RouterTopK {
    <#
    .SYNOPSIS
        Top-k com clamp (Phase 8 fix Rev MED): normal 0..3, complexo 0..5.
        Valores invalidos/negativos/altos sao clampados; 0 significa "nenhum"
        e o chamador nao deve indexar [0..-1].
    #>
    [CmdletBinding()]
    param($Policy, [bool]$Complex)
    $def = 3
    $cpx = 5
    try {
        if ($null -ne $Policy -and $null -ne $Policy.routing -and $null -ne $Policy.routing.top_k) {
            $tk = $Policy.routing.top_k
            if ($tk -is [System.Collections.IDictionary]) {
                if ($tk.Contains('default')) { $def = [int]$tk['default'] }
                if ($tk.Contains('complex')) { $cpx = [int]$tk['complex'] }
            }
            else {
                foreach ($p in @($tk.PSObject.Properties)) {
                    if ($p.Name -ceq 'default') { $def = [int]$p.Value }
                    if ($p.Name -ceq 'complex') { $cpx = [int]$p.Value }
                }
            }
        }
    }
    catch { }
    if ($Complex) {
        if ($cpx -lt 0) { $cpx = 0 }
        if ($cpx -gt 5) { $cpx = 5 }
        return $cpx
    }
    if ($def -lt 0) { $def = 0 }
    if ($def -gt 3) { $def = 3 }
    return $def
}

function Get-RouterStaleMaxAge {
    [CmdletBinding()]
    param($Policy)
    try {
        if ($null -ne $Policy -and $null -ne $Policy.routing -and $null -ne $Policy.routing.stale_max_age_seconds) {
            return [int]$Policy.routing.stale_max_age_seconds
        }
    }
    catch { }
    return 86400
}

function Get-RouterExecutionTrustAllow {
    [CmdletBinding()]
    param($Policy)
    $allow = @('trusted', 'trusted_local', 'approved')
    try {
        if ($null -ne $Policy -and $null -ne $Policy.routing -and $null -ne $Policy.routing.execution_trust_allow) {
            $raw = @($Policy.routing.execution_trust_allow)
            if ($raw.Count -gt 0) {
                $allow = @()
                foreach ($v in $raw) {
                    $s = ([string]$v).Trim().ToLowerInvariant()
                    if (-not [string]::IsNullOrWhiteSpace($s)) { $allow += $s }
                }
                if ($allow.Count -eq 0) { $allow = @('trusted', 'trusted_local', 'approved') }
            }
        }
    }
    catch { $allow = @('trusted', 'trusted_local', 'approved') }
    return $allow
}

function Get-RouterTrivialTypes {
    [CmdletBinding()]
    param($Policy)
    $types = @('trivial')
    try {
        if ($null -ne $Policy -and $null -ne $Policy.routing -and $null -ne $Policy.routing.trivial_task_types) {
            $raw = @($Policy.routing.trivial_task_types)
            if ($raw.Count -gt 0) {
                $types = @()
                foreach ($v in $raw) {
                    $s = ([string]$v).Trim().ToLowerInvariant()
                    if (-not [string]::IsNullOrWhiteSpace($s)) { $types += $s }
                }
            }
        }
    }
    catch { $types = @('trivial') }
    return $types
}

function Get-RouterCanonicalList {
    [CmdletBinding()]
    param($Policy)
    $names = @()
    try {
        $producers = $Policy.capability_taxonomy.producers
        if ($null -ne $producers) {
            if ($producers -is [System.Collections.IDictionary]) {
                foreach ($k in @($producers.Keys)) { $names += [string]$k }
            }
            else {
                foreach ($p in @($producers.PSObject.Properties)) { $names += [string]$p.Name }
            }
        }
    }
    catch { $names = @() }
    [Array]::Sort([string[]]$names, [System.StringComparer]::Ordinal)
    return $names
}

function Test-RouterCanonical {
    [CmdletBinding()]
    param($Policy, [string]$Id)
    $list = @(Get-RouterCanonicalList -Policy $Policy)
    return ($list -ccontains $Id)
}

function Get-RouterUnknownPolicy {
    [CmdletBinding()]
    param($Policy)
    try {
        if ($null -ne $Policy -and $null -ne $Policy.capability_taxonomy -and $null -ne $Policy.capability_taxonomy.unknown_policy) {
            return ([string]$Policy.capability_taxonomy.unknown_policy).Trim().ToLowerInvariant()
        }
    }
    catch { }
    return 'deny_execution'
}

function Convert-RouterNodeToHashtable {
    [CmdletBinding()]
    param($Node)
    if ($null -eq $Node) { return $null }
    if ($Node -is [System.Collections.IDictionary]) {
        $table = @{}
        foreach ($key in $Node.Keys) { $table["$key"] = Convert-RouterNodeToHashtable -Node $Node[$key] }
        return $table
    }
    if (($Node -is [System.Collections.IEnumerable]) -and -not ($Node -is [string])) {
        $items = @()
        foreach ($element in $Node) { $items += (Convert-RouterNodeToHashtable -Node $element) }
        Write-Output -NoEnumerate $items
        return
    }
    if (($Node -is [string]) -or ($Node -is [System.ValueType])) { return $Node }
    $props = @($Node.PSObject.Properties)
    if ($props.Count -eq 0) { return $Node }
    $table = @{}
    foreach ($p in $props) { $table[$p.Name] = Convert-RouterNodeToHashtable -Node $p.Value }
    return $table
}

function Read-RouterRegistry {
    <#
    .SYNOPSIS
        Le o registry derivado; nunca lanca para o chamador do CLI (retorna
        Available=false com Reasons). Avalia freshness (idade, runtime,
        fingerprint).
    #>
    [CmdletBinding()]
    param(
        [string]$RegistryPath,
        [string]$RepoRoot,
        $Policy,
        [int]$MaxAgeSeconds = -1
    )
    $result = [ordered]@{
        Available    = $false
        Stale        = $true
        StaleReasons = @('registry unavailable')
        Registry     = $null
        Capabilities = @()
        Fresh        = $false
    }
    $resolved = $RegistryPath
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        $root = Get-RouterRepoRoot -RepoRoot $RepoRoot
        $resolved = Join-Path $root 'cache\v3\capability-registry.json'
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        $result['StaleReasons'] = @('registry file not found')
        return ([PSCustomObject]$result)
    }
    $text = ''
    try { $text = Read-RouterUtf8Text -Path $resolved }
    catch {
        $result['StaleReasons'] = @('registry unreadable')
        return ([PSCustomObject]$result)
    }
    $doc = $null
    try { $doc = $text | ConvertFrom-Json }
    catch {
        $result['StaleReasons'] = @('registry corrupt (invalid JSON)')
        return ([PSCustomObject]$result)
    }
    if ($null -eq $doc -or $null -eq $doc.capabilities) {
        $result['StaleReasons'] = @('registry corrupt (missing capabilities)')
        return ([PSCustomObject]$result)
    }
    $result['Available'] = $true
    $result['Registry'] = $doc
    $result['Capabilities'] = @($doc.capabilities)
    $reasons = New-Object System.Collections.Generic.List[string]
    $maxAge = $MaxAgeSeconds
    if ($maxAge -lt 0) { $maxAge = Get-RouterStaleMaxAge -Policy $Policy }
    $computedAt = ''
    $fp = ''
    $freshRt = ''
    $regRt = ''
    try { if ($null -ne $doc.registry -and $null -ne $doc.registry.freshness -and $null -ne $doc.registry.freshness.computed_at) { $computedAt = [string]$doc.registry.freshness.computed_at } } catch { }
    try { if ($null -ne $doc.registry -and $null -ne $doc.registry.freshness -and $null -ne $doc.registry.freshness.source_fingerprint) { $fp = [string]$doc.registry.freshness.source_fingerprint } } catch { }
    try { if ($null -ne $doc.registry -and $null -ne $doc.registry.freshness -and $null -ne $doc.registry.freshness.runtime_version) { $freshRt = [string]$doc.registry.freshness.runtime_version } } catch { }
    try { if ($null -ne $doc.registry -and $null -ne $doc.registry.runtime -and $null -ne $doc.registry.runtime.version) { $regRt = [string]$doc.registry.runtime.version } } catch { }
    if ([string]::IsNullOrWhiteSpace($fp)) { $reasons.Add('stale: missing source_fingerprint') }
    if ([string]::IsNullOrWhiteSpace($computedAt)) {
        $reasons.Add('stale: missing computed_at')
    }
    else {
        $parsed = [DateTimeOffset]::MinValue
        $ok = [DateTimeOffset]::TryParse($computedAt, [ref]$parsed)
        if (-not $ok) {
            $reasons.Add('stale: computed_at unparseable')
        }
        else {
            $age = ([DateTimeOffset]::UtcNow - $parsed).TotalSeconds
            if ($age -gt $maxAge) {
                $reasons.Add(('stale: age {0}s exceeds max {1}s' -f [int]$age, $maxAge))
            }
            elseif ($age -lt -300) {
                # Phase 8 fix Rev MED: computed_at muito no futuro (além da
                # tolerancia de 300s p/ skew de relogio) e tratado como stale.
                # Um fingerprint "fresco" com timestamp impossivel nao confere
                # frescura; o harness documenta que NAO recomputa o
                # source_fingerprint (usa constante), logo drift de fingerprint
                # real nao e exercitado aqui (ver CapabilityEval.ps1).
                $reasons.Add(('stale: computed_at in the future ({0}s ahead, tolerance 300s)' -f [int](-$age)))
            }
        }
    }
    $freshUnknown = [string]::IsNullOrWhiteSpace($freshRt) -or ($freshRt.Trim().ToLowerInvariant() -ceq 'unknown')
    $regUnknown = [string]::IsNullOrWhiteSpace($regRt) -or ($regRt.Trim().ToLowerInvariant() -ceq 'unknown')
    if (-not ($freshUnknown -or $regUnknown)) {
        if ($freshRt -cne $regRt) {
            $reasons.Add(('stale: runtime_version drift (freshness {0} vs registry {1})' -f $freshRt, $regRt))
        }
    }
    if ($reasons.Count -eq 0) {
        $result['Stale'] = $false
        $result['Fresh'] = $true
        $result['StaleReasons'] = @()
    }
    else {
        $result['Stale'] = $true
        $result['Fresh'] = $false
        $result['StaleReasons'] = [string[]]$reasons
    }
    return ([PSCustomObject]$result)
}

function Get-RouterAllowlist {
    <#
    .SYNOPSIS
        Entries explicitas de agent.build.permission.task com valor "allow".
        Exclui "*" (wildcard nunca conta como agente valido).
    #>
    [CmdletBinding()]
    param([string]$ConfigPath)
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
    }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return @() }
    $text = ''
    try { $text = Read-RouterUtf8Text -Path $ConfigPath }
    catch { return @() }
    $cfg = $null
    try { $cfg = $text | ConvertFrom-Json }
    catch { return @() }
    $task = $null
    try {
        if ($null -ne $cfg.agent -and $null -ne $cfg.agent.build -and $null -ne $cfg.agent.build.permission) {
            $task = $cfg.agent.build.permission.task
        }
    }
    catch { return @() }
    if ($null -eq $task) { return @() }
    if ($task -is [string]) { return @() }
    $entries = @()
    if ($task -is [System.Collections.IDictionary]) {
        foreach ($k in @($task.Keys)) {
            if ("$k" -ceq '*') { continue }
            if ("$($task[$k])" -ceq 'allow') { $entries += "$k" }
        }
    }
    else {
        foreach ($p in @($task.PSObject.Properties)) {
            if ($p.Name -ceq '*') { continue }
            if ("$($p.Value)" -ceq 'allow') { $entries += [string]$p.Name }
        }
    }
    [Array]::Sort([string[]]$entries, [System.StringComparer]::Ordinal)
    $unique = @()
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($e in $entries) { if ($seen.Add($e)) { $unique += $e } }
    return $unique
}

function New-RouterTask {
    [CmdletBinding()]
    param(
        [string]$Objective = '',
        [string]$TaskType = '',
        [string]$Domain = '',
        [string]$Risk = 'unknown',
        [string]$ReadWrite = '',
        [string]$Project = '',
        $ExplicitTriggers,
        $Categories,
        $Tags,
        $SecondaryDomains
    )
    $exp = @()
    if ($null -ne $ExplicitTriggers) { foreach ($v in @($ExplicitTriggers)) { if (-not [string]::IsNullOrWhiteSpace([string]$v)) { $exp += ([string]$v).Trim() } } }
    $cats = @()
    if ($null -ne $Categories) { foreach ($v in @($Categories)) { if (-not [string]::IsNullOrWhiteSpace([string]$v)) { $cats += ([string]$v).Trim() } } }
    $tags = @()
    if ($null -ne $Tags) { foreach ($v in @($Tags)) { if (-not [string]::IsNullOrWhiteSpace([string]$v)) { $tags += ([string]$v).Trim() } } }
    # Dominios secundarios (mixed-domain): nao substituem o primario; dao
    # contexto de elegibilidade ao Router sem criar fan-out. Normalizados como
    # o dominio primario e deduplicados.
    $sec = @()
    if ($null -ne $SecondaryDomains) {
        $seenSec = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($v in @($SecondaryDomains)) {
            if ([string]::IsNullOrWhiteSpace([string]$v)) { continue }
            $n = Convert-RouterNormalizedText -Text ([string]$v).Trim()
            if (-not [string]::IsNullOrWhiteSpace($n) -and $seenSec.Add($n)) { $sec += $n }
        }
    }
    # TaskType/Domain/Risk/ReadWrite normalizados (diacriticos+case) para que
    # "implementação", "produção" etc. casem as listas normalizadas.
    return [PSCustomObject]@{
        Objective        = [string]$Objective
        TaskType         = Convert-RouterNormalizedText -Text ([string]$TaskType).Trim()
        Domain           = Convert-RouterNormalizedText -Text ([string]$Domain).Trim()
        SecondaryDomains = $sec
        Risk             = Convert-RouterNormalizedText -Text ([string]$Risk).Trim()
        ReadWrite        = Convert-RouterNormalizedText -Text ([string]$ReadWrite).Trim()
        Project          = ([string]$Project).Trim()
        ExplicitTriggers = $exp
        Categories       = $cats
        Tags             = $tags
    }
}

function Get-RouterTaskKeywords {
    [CmdletBinding()]
    param($Task)
    $blob = (([string]$Task.Objective) + ' ' + ([string]$Task.Domain) + ' ' + ([string]$Task.TaskType) + ' ' + ((@($Task.Tags) | ForEach-Object { "$_" }) -join ' ') + ' ' + ((@($Task.Categories) | ForEach-Object { "$_" }) -join ' '))
    # Cache de processo por assinatura do blob: o mesmo task e tokenizado uma
    # vez por registro no scoring (ate 120+ vezes). Bounded: so leitura.
    if ($null -eq $script:RouterKwCache) { $script:RouterKwCache = @{} }
    if ($script:RouterKwCache.ContainsKey($blob)) { return $script:RouterKwCache[$blob] }
    $lower = Convert-RouterNormalizedText -Text $blob
    $parts = @($lower -split '[^a-z0-9][^a-z0-9]*' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $out = @()
    foreach ($p in $parts) { if ($seen.Add($p)) { $out += $p } }
    $script:RouterKwCache[$blob] = $out
    return $out
}

function Get-RouterRequiredCapabilities {
    <#
    .SYNOPSIS
        Mapeamento deterministico tarefa -> capability classes canonicas.
        Usa SOMENTE task + taxonomy (nunca description de skill/MCP).
    #>
    [CmdletBinding()]
    param($Task, $Policy)
    $kw = @(Get-RouterTaskKeywords -Task $Task)
    $kwSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($k in $kw) { $kwSet.Add($k) | Out-Null }
    # V3-P8-FIX2 (MED Rev): stopwords genericas nunca disparam capability.
    # Remove do conjunto antes do mapeamento (ex.: 'projeto' sozinho nao
    # implica memory.project-history).
    foreach ($s in @(Get-RouterStopwords)) { $kwSet.Remove($s) | Out-Null }
    $required = New-Object System.Collections.Generic.List[string]
    $add = {
        param([string]$Cap)
        if ($required -cnotcontains $Cap) { $required.Add($Cap) }
    }
    $hasAny = {
        param([string[]]$Words)
        foreach ($w in $Words) { if ($kwSet.Contains($w)) { return $true } }
        return $false
    }
    if (& $hasAny @('database', 'sql', 'banco', 'postgres', 'sqlite')) {
        & $add 'database.read'
        if (& $hasAny @('schema', 'migration', 'migrate', 'ddl')) { & $add 'database.schema' }
        if ((& $hasAny @('write', 'insert', 'update', 'delete', 'escrita')) -or ($Task.ReadWrite -ceq 'write')) { & $add 'database.write' }
    }
    if (& $hasAny @('memory', 'history', 'historico', 'recall')) { & $add 'memory.project-history' }
    if (& $hasAny @('documentation', 'documentacao', 'docs', 'current', 'web', 'research', 'pesquisa', 'latest')) {
        & $add 'knowledge.current-documentation'
        & $add 'docs.current'
    }
    if (& $hasAny @('test', 'teste', 'qa', 'spec', 'testing', 'validation', 'validacao', 'validar', 'verificacao', 'assurance')) { & $add 'test.run' }
    if (& $hasAny @('implement', 'implementacao', 'code', 'codigo', 'build', 'feature', 'refactor', 'fix')) { & $add 'code.bounded-edit' }
    if (& $hasAny @('architecture', 'arquitetura', 'boundary', 'protocol', 'datamodel', 'adr')) { & $add 'architecture.reference' }
    if (& $hasAny @('ux', 'ui', 'jornada', 'frontend', 'design', 'acessibilidade')) { & $add 'product.ux' }
    if (& $hasAny @('infra', 'deploy', 'observe', 'observabilidade', 'devops', 'pipeline')) { & $add 'infra.observe' }
    if (& $hasAny @('production', 'producao', 'control', 'release')) { & $add 'production.control' }
    if (& $hasAny @('destructive', 'destrutivo', 'destrutiva', 'destruicao', 'delete', 'drop', 'destroy')) { & $add 'production.destructive' }
    if (& $hasAny @('secret', 'segredo', 'token', 'password', 'credential')) { & $add 'secrets.read' }
    if (& $hasAny @('external', 'webhook', 'side', 'effect', 'payment', 'pagamento', 'upload')) { & $add 'external.side-effect' }
    foreach ($c in @($Task.Categories)) {
        $s = ([string]$c).Trim()
        if ((Test-RouterCanonical -Policy $Policy -Id $s) -and ($required -cnotcontains $s)) { $required.Add($s) }
    }
    foreach ($t in @($Task.Tags)) {
        $s = ([string]$t).Trim()
        if ((Test-RouterCanonical -Policy $Policy -Id $s) -and ($required -cnotcontains $s)) { $required.Add($s) }
    }
    $arr = [string[]]$required
    [Array]::Sort([string[]]$arr, [System.StringComparer]::Ordinal)
    return $arr
}

function Test-RouterExecutionRequired {
    [CmdletBinding()]
    param($Task)
    if ($Task.ReadWrite -ceq 'write') { return $true }
    if ($Task.ReadWrite -ceq 'read') { return $false }
    $writeTypes = @('implementation', 'implementacao', 'code', 'build', 'migration', 'execution', 'write')
    if ($writeTypes -ccontains $Task.TaskType) { return $true }
    return $false
}

function Get-RouterExpectedAgent {
    <#
    .SYNOPSIS
        Mapeamento deterministico dominio/tipo -> agente (prosa + Stage A).
    .DESCRIPTION
        Precedencia canonica (deterministic precedence, hardening H-A/B):
          hard safety (security/credentials)
          > work-type explicito para tipos-ato (review/debug/exploration/test)
          > dominio em prosa
          > marcadores de objetivo e fallbacks tematicos (inclui
            research/architecture/documentation, resolvidos com contexto)
          > coder (default).
        Matching boundary-aware (Test-RouterKeyword): TASK_TYPE/DOMINIO/RISK
        estruturados e work-types explicitos prevalecem sobre palavras
        incidentais do texto (§27). Nunca lanca.
    #>
    [CmdletBinding()]
    param($Task)
    $blob = Convert-RouterNormalizedText -Text (([string]$Task.Domain) + ' ' + ([string]$Task.TaskType) + ' ' + ([string]$Task.Objective))
    $has = {
        param([string[]]$Words, [string[]]$Exact = @())
        return (Test-RouterKeyword -Blob $blob -Words $Words -Exact $Exact)
    }
    $securityWords = @('security', 'seguranca', 'autentic', 'authent', 'autoriz', 'secret', 'segredo', 'permiss', 'credential', 'credenc', 'vulnerab', 'owasp', 'csrf', 'xss', 'jwt', 'saml', 'oauth', 'pentest', 'exploit', 'idor', 'ssrf', 'privileg', 'escalac', 'injection', 'traversal')
    $securityExact = @('auth')
    # 1) design especial (mantem o guard de security).
    if (($Task.TaskType -ceq 'design') -and (& $has @('jornada','estados','fluxo','acessiv','information architecture')) -and (-not (& $has @('security','auth','token','secret','segred','permiss','autoriza','seguranca')))) { return 'product-designer' }
    # 2) hard safety: security/credentials vencem work-type e dominio em prosa.
    # 'auth' e exato (token) para nao casar 'author'/'authoring'; radicais
    # 'autentic'/'authent' cobrem authentication/autenticacao.
    if (& $has $securityWords -Exact $securityExact) { return 'security-reviewer' }
    # 3) work-type explicito (task_type tipado) vence keyword incidental de
    # dominio — somente para tipos-ato com owner Stage-1 inequivoco
    # (review/debug/exploration/test). Tipos de conhecimento/estrutura
    # (research/architecture/documentation/planning/analysis) resolvem via
    # scoring com contexto de dominio (ramo 5), sem bias artificial.
    if (($Task.TaskType -ceq 'test') -or ($Task.TaskType -ceq 'tests') -or ($Task.TaskType -ceq 'testing') -or ($Task.TaskType -ceq 'validation')) { return 'tester' }
    if ($Task.TaskType -ceq 'review') { return 'reviewer' }
    if (($Task.TaskType -ceq 'debug') -or ($Task.TaskType -ceq 'debugging')) { return 'debugger' }
    if (($Task.TaskType -ceq 'exploration') -or ($Task.TaskType -ceq 'discovery')) { return 'explorer' }
    # 4) dominio em prosa.
    if (& $has @('frontend', 'ux', 'ui:', 'jornada')) { return 'frontend-engineer' }
    if (& $has @('backend', 'api')) { return 'backend-engineer' }
    if (& $has @('database', 'sql', 'banco')) { return 'database-engineer' }
    if (& $has @('infra', 'devops', 'deploy', 'pipeline')) { return 'infra-engineer' }
    if (& $has @('automation', 'script', 'workflow')) { return 'automation-engineer' }
    if (& $has @('ai-agent', 'agent workflow', 'prompt', 'evaluation', 'memory architecture')) { return 'ai-agent-engineer' }
    # 5) marcadores de objetivo e fallbacks tematicos.
    if (& $has @('doc', 'documenta')) { return 'docs-manager' }
    if (& $has @('test:', 'qa')) { return 'tester' }
    if (& $has @('review')) { return 'reviewer' }
    if (& $has @('debug', 'bug', 'stacktrace', 'flaky')) { return 'debugger' }
    if (& $has @('research', 'pesquisa externa')) { return 'researcher' }
    if (& $has @('explore', 'codebase', 'impacto')) { return 'explorer' }
    if (& $has @('architect', 'migra', 'protocolo')) { return 'architect' }
    if (& $has @('requisito', 'criterio', 'ambiguidade', 'acceptance criteria', 'caso de uso')) { return 'requirements-analyst' }
    if (& $has @('viabilidade', 'feasibility', 'incremental', 'rollback', 'manutenib', 'maintainab')) { return 'engineering-advisor' }
    if (& $has @('premissa', 'yagni', 'high-risk', 'complexidade', 'alternativa', 'contradic')) { return 'skeptic' }
    if (& $has @('information architecture', 'estados de ui', 'user flow')) { return 'product-designer' }
    return 'coder'
}

function Test-RouterTrivial {
    [CmdletBinding()]
    param($Task, $Policy)
    $trivialTypes = @(Get-RouterTrivialTypes -Policy $Policy)
    if ($trivialTypes -ccontains $Task.TaskType) { return $true }
    if ($Task.TaskType -ceq 'read' -and $Task.Risk -ceq 'low') {
        $len = ([string]$Task.Objective).Length
        if ($len -gt 0 -and $len -lt 80) { return $true }
    }
    $blob = ([string]$Task.Objective).ToLowerInvariant()
    $trivialWords = @('typo', 'cosmetico', 'cosmetic', 'leitura pontual', 'small read')
    foreach ($w in $trivialWords) {
        if ($blob.Contains($w) -and ($Task.Risk -ceq 'low' -or [string]::IsNullOrWhiteSpace($Task.Risk))) { return $true }
    }
    return $false
}

function Get-RecordStringArray {
    [CmdletBinding()]
    param($Record, [string]$Field)
    $vals = @()
    try {
        $node = $null
        if ($Record -is [System.Collections.IDictionary]) {
            if ($Record.Contains($Field)) { $node = $Record[$Field] }
        }
        else {
            # foreach direto (sem pipeline Where-Object): mesmo matching
            # case-sensitive, muito mais rapido no loop de scoring.
            foreach ($prop in $Record.PSObject.Properties) { if ($prop.Name -ceq $Field) { $node = $prop.Value; break } }
        }
        foreach ($v in @($node)) {
            if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) { $vals += [string]$v }
        }
    }
    catch { $vals = @() }
    return $vals
}

function Get-RecordScalar {
    [CmdletBinding()]
    param($Record, [string]$Field)
    try {
        if ($Record -is [System.Collections.IDictionary]) {
            if ($Record.Contains($Field)) { return [string]$Record[$Field] }
        }
        else {
            foreach ($prop in $Record.PSObject.Properties) { if ($prop.Name -ceq $Field) { if ($null -ne $prop.Value) { return [string]$prop.Value } ; break } }
        }
    }
    catch { }
    return ''
}

function Test-RouterHardFilter {
    <#
    .SYNOPSIS
        Hard filters deterministico por capability. Usa SOMENTE policy/registry
        (status, allowlist, forbidden, trust curado, unknown_policy,
        freshness global). NUNCA le description/tags para decidir permissao.
    #>
    [CmdletBinding()]
    param(
        $Record,
        $Task,
        [string[]]$RequiredCaps,
        [string[]]$Allowlist,
        $Policy,
        [bool]$ExecutionRequired
    )
    $fail = New-Object System.Collections.Generic.List[string]
    $id = Get-RecordScalar -Record $Record -Field 'id'
    $type = (Get-RecordScalar -Record $Record -Field 'type').Trim().ToLowerInvariant()
    $name = Get-RecordScalar -Record $Record -Field 'name'
    $status = (Get-RecordScalar -Record $Record -Field 'status').Trim().ToLowerInvariant()
    $trust = (Get-RecordScalar -Record $Record -Field 'trust').Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($status)) { $status = 'unknown' }
    if ([string]::IsNullOrWhiteSpace($trust)) { $trust = 'unknown' }
    if (@('missing', 'invalid', 'disabled') -ccontains $status) {
        $fail.Add(('status:{0} excluido' -f $status))
    }
    if ($type -ceq 'agent') {
        if ([string]::IsNullOrWhiteSpace($name) -or ($name -ceq '*')) {
            $fail.Add('permission:wildcard invalido (nunca conta como agente)')
        }
        elseif ($Allowlist -cnotcontains $name) {
            $fail.Add(('permission:denied (agente {0} fora da allowlist)' -f $name))
        }
    }
    $forbidden = @()
    try {
        $prof = $null
        if ($Record -is [System.Collections.IDictionary]) {
            if ($Record.Contains('capability_profile')) { $prof = $Record['capability_profile'] }
        }
        else {
            $p = $Record.PSObject.Properties | Where-Object { $_.Name -ceq 'capability_profile' } | Select-Object -First 1
            if ($null -ne $p) { $prof = $p.Value }
        }
        if ($null -ne $prof) {
            $flist = $null
            if ($prof -is [System.Collections.IDictionary]) {
                if ($prof.Contains('forbidden')) { $flist = $prof['forbidden'] }
            }
            else {
                $fp = $prof.PSObject.Properties | Where-Object { $_.Name -ceq 'forbidden' } | Select-Object -First 1
                if ($null -ne $fp) { $flist = $fp.Value }
            }
            foreach ($v in @($flist)) {
                if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) { $forbidden += ([string]$v).Trim() }
            }
        }
    }
    catch { $forbidden = @() }
    foreach ($req in @($RequiredCaps)) {
        if ($forbidden -ccontains $req) {
            $fail.Add(('permission:forbidden ({0})' -f $req))
            break
        }
    }
    if ($type -ceq 'mcp' -and $ExecutionRequired) {
        $allow = @(Get-RouterExecutionTrustAllow -Policy $Policy)
        if ($allow -cnotcontains $trust) {
            $fail.Add(('trust:{0} bloqueado para execucao (exige {1})' -f $trust, ($allow -join ',')))
        }
    }
    $unknownPolicy = Get-RouterUnknownPolicy -Policy $Policy
    if ($unknownPolicy -ceq 'deny_execution' -and $ExecutionRequired) {
        if ($trust -ceq 'unknown') {
            $already = $false
            foreach ($f in $fail) { if ($f.StartsWith('trust:')) { $already = $true } }
            if ((-not $already) -and ($type -ceq 'mcp')) {
                $fail.Add('trust:unknown bloqueado sob default-deny')
            }
        }
        foreach ($req in @($RequiredCaps)) {
            if (-not (Test-RouterCanonical -Policy $Policy -Id $req)) {
                $fail.Add(('unknown capability {0} sob default-deny' -f $req))
                break
            }
        }
    }
    $pass = ($fail.Count -eq 0)
    return [PSCustomObject]@{ Pass = $pass; FailReasons = [string[]]$fail; Trust = $trust; Status = $status; Type = $type; Name = $name; Id = $id }
}

function Get-RouterClassificationConfidencePoints {
    <#
    .SYNOPSIS
        Pontos de confianca da classificacao (desempate; nunca elegibilidade).
        Le policy routing.classification_confidence_weights quando presente
        (explicit=4,curated=3,inferred_high=2,inferred_low=1,unknown=0);
        valor ausente/invalido => 0.
    #>
    [CmdletBinding()]
    param($Record, $Policy)
    $name = ''
    try {
        $clsNode = $null
        if ($Record -is [System.Collections.IDictionary]) {
            if ($Record.Contains('classification')) { $clsNode = $Record['classification'] }
        }
        else {
            foreach ($prop in $Record.PSObject.Properties) { if ($prop.Name -ceq 'classification') { $clsNode = $prop.Value; break } }
        }
        if ($null -ne $clsNode) {
            if ($clsNode -is [System.Collections.IDictionary]) {
                if ($clsNode.Contains('confidence')) { $name = ([string]$clsNode['confidence']).Trim().ToLowerInvariant() }
            }
            else {
                foreach ($prop in $clsNode.PSObject.Properties) { if ($prop.Name -ceq 'confidence') { if ($null -ne $prop.Value) { $name = ([string]$prop.Value).Trim().ToLowerInvariant() } ; break } }
            }
        }
    }
    catch { $name = '' }
    $map = [ordered]@{ explicit = 4; curated = 3; inferred_high = 2; inferred_low = 1; unknown = 0 }
    try {
        if ($null -ne $Policy -and $null -ne $Policy.routing -and $null -ne $Policy.routing.classification_confidence_weights) {
            $w = $Policy.routing.classification_confidence_weights
            foreach ($k in @('explicit', 'curated', 'inferred_high', 'inferred_low', 'unknown')) {
                $prop = $null
                try {
                    if ($w -is [System.Collections.IDictionary]) {
                        if ($w.Contains($k)) { $prop = $w[$k] }
                    }
                    else {
                        $p = $w.PSObject.Properties | Where-Object { $_.Name -ceq $k } | Select-Object -First 1
                        if ($null -ne $p) { $prop = $p.Value }
                    }
                }
                catch { $prop = $null }
                if ($null -ne $prop) {
                    $n = 0
                    try { $n = [int]$prop } catch { $n = 0 }
                    $map[$k] = $n
                }
            }
        }
    }
    catch { }
    if ([string]::IsNullOrWhiteSpace($name)) { return 0 }
    if ($map.Contains($name)) { return [int]$map[$name] }
    return 0
}

function Get-RouterScore {
    <#
    .SYNOPSIS
        Scoring deterministico e explicavel. Usa SOMENTE campos estruturados
        (capabilities/categories/tags/nome) + task; NUNCA description.
    #>
    [CmdletBinding()]
    param(
        $Record,
        $Task,
        [string[]]$RequiredCaps,
        $Weights,
        [string]$ExpectedAgent,
        [bool]$Fresh,
        $Policy = $null
    )
    $caps = @(Get-RecordStringArray -Record $Record -Field 'capabilities')
    $cats = @(Get-RecordStringArray -Record $Record -Field 'categories')
    $tags = @(Get-RecordStringArray -Record $Record -Field 'tags')
    $name = Convert-RouterNormalizedText -Text (Get-RecordScalar -Record $Record -Field 'name').Trim()
    $id = (Get-RecordScalar -Record $Record -Field 'id')
    $type = (Get-RecordScalar -Record $Record -Field 'type').Trim().ToLowerInvariant()
    $status = (Get-RecordScalar -Record $Record -Field 'status').Trim().ToLowerInvariant()
    $explicit = 0
    foreach ($t in @($Task.ExplicitTriggers)) {
        $s = Convert-RouterNormalizedText -Text ([string]$t).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        if (($s -ceq $name) -or ($s -ceq (Convert-RouterNormalizedText -Text $id))) { $explicit = 1; break }
    }
    $catMatch = 0
    foreach ($req in @($RequiredCaps)) {
        if ($caps -ccontains $req) { $catMatch++ }
    }
    $taskKw = @(Get-RouterTaskKeywords -Task $Task)
    $stopList = @(Get-RouterStopwords)
    $tagLower = @()
    foreach ($t in ($tags + $cats)) {
        $s = Convert-RouterNormalizedText -Text ([string]$t).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        if ($stopList -ccontains $s) { continue }
        $tagLower += $s
    }
    $tagSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($t in $tagLower) { $tagSet.Add($t) | Out-Null }
    $tagMatch = 0
    foreach ($k in $taskKw) {
        if ($stopList -ccontains $k) { continue }
        if ($tagSet.Contains($k)) { $tagMatch++ }
    }
    if ($tagMatch -gt 5) { $tagMatch = 5 }
    $domainMatch = 0
    $primaryDom = Convert-RouterNormalizedText -Text ([string]$Task.Domain).Trim()
    if ([string]::IsNullOrWhiteSpace($primaryDom) -or ($stopList -ccontains $primaryDom)) {
        if (($type -ceq 'agent') -and ($name -ceq (Convert-RouterNormalizedText -Text $ExpectedAgent))) {
            # Dominio generico/ausente nao cria match por tag, mas a
            # afinidade ao agente esperado (Stage A) permanece.
            $domainMatch = 1
        }
    }
    else {
        foreach ($t in $tagLower) {
            if ($t -ceq $primaryDom -or $t.Contains($primaryDom) -or $primaryDom.Contains($t)) { $domainMatch = 1; break }
        }
        if (($domainMatch -eq 0) -and ($type -ceq 'agent')) {
            if ($name -ceq (Convert-RouterNormalizedText -Text $ExpectedAgent)) { $domainMatch = 1 }
        }
    }
    # Mixed-domain: dominios secundarios sao um sinal DE PESO BAIXO. Nunca
    # substituem o papel primario (domain_match peso alto + envelope da
    # categoria primaria); servem de contexto/tie-break e como elegibilidade
    # quando o dominio primario sozinho nao casa nenhum candidato.
    $secondaryDomainMatch = 0
    foreach ($sd in @($Task.SecondaryDomains)) {
        $s = Convert-RouterNormalizedText -Text ([string]$sd).Trim()
        if ([string]::IsNullOrWhiteSpace($s) -or ($stopList -ccontains $s)) { continue }
        foreach ($t in $tagLower) {
            if ($t -ceq $s -or $t.Contains($s) -or $s.Contains($t)) { $secondaryDomainMatch = 1; break }
        }
        if ($secondaryDomainMatch -eq 1) { break }
    }
    $roleAff = 0
    if ($type -ceq 'agent' -and ($name -ceq (Convert-RouterNormalizedText -Text $ExpectedAgent))) { $roleAff = 1 }
    elseif ($type -ne 'agent') {
        if ($catMatch -gt 0) { $roleAff = 1 }
    }
    $projAff = 0
    $proj = Convert-RouterNormalizedText -Text ([string]$Task.Project).Trim()
    if ((-not [string]::IsNullOrWhiteSpace($proj)) -and ($stopList -cnotcontains $proj)) {
        foreach ($t in $tagLower) { if ($t -ceq $proj) { $projAff = 1; break } }
    }
    $avail = 0
    if ($status -ceq 'available') { $avail = 1 }
    $freshBit = 0
    if ($Fresh) { $freshBit = 1 }
    $confPoints = Get-RouterClassificationConfidencePoints -Record $Record -Policy $Policy
    $confWeight = 1
    try {
        if ($null -ne $Weights) {
            if ($Weights -is [System.Collections.IDictionary]) {
                if ($Weights.Contains('classification_confidence')) { $confWeight = [int]$Weights['classification_confidence'] }
            }
            else {
                $wp = $Weights.PSObject.Properties | Where-Object { $_.Name -ceq 'classification_confidence' } | Select-Object -First 1
                if ($null -ne $wp -and $null -ne $wp.Value) { $confWeight = [int]$wp.Value }
            }
        }
    }
    catch { $confWeight = 1 }
    $secWeight = 1
    try {
        if ($null -ne $Weights) {
            if ($Weights -is [System.Collections.IDictionary]) {
                if ($Weights.Contains('secondary_domain_match')) { $secWeight = [int]$Weights['secondary_domain_match'] }
            }
            else {
                $swp = $Weights.PSObject.Properties | Where-Object { $_.Name -ceq 'secondary_domain_match' } | Select-Object -First 1
                if ($null -ne $swp -and $null -ne $swp.Value) { $secWeight = [int]$swp.Value }
            }
        }
    }
    catch { $secWeight = 1 }
    if ($secWeight -lt 0) { $secWeight = 0 }
    $score = ([int]$Weights['explicit_trigger'] * $explicit) + ([int]$Weights['category_match'] * $catMatch) + ([int]$Weights['tag_match'] * $tagMatch) + ([int]$Weights['domain_match'] * $domainMatch) + ($secWeight * $secondaryDomainMatch) + ([int]$Weights['role_affinity'] * $roleAff) + ([int]$Weights['project_affinity'] * $projAff) + ([int]$Weights['availability'] * $avail) + ([int]$Weights['freshness'] * $freshBit) + ($confWeight * $confPoints)
    # Phase 8 fix Rev HIGH: elegibilidade exige relevancia positiva.
    # availability/freshness so REPONDERAM candidatos ja relevantes; nunca
    # criam elegibilidade. Skill/MCP sem match de capability requerida,
    # categoria/tag/dominio, trigger explicito ou afinidade nao e candidata
    # (tarefa sem required caps nao recomenda MCPs/skills irrelevantes).
    $relevant = (($explicit -gt 0) -or ($catMatch -gt 0) -or ($tagMatch -gt 0) -or ($domainMatch -gt 0) -or ($secondaryDomainMatch -gt 0) -or ($roleAff -gt 0) -or ($projAff -gt 0))
    return [PSCustomObject]@{
        Score      = $score
        Relevant   = [bool]$relevant
        Components = [ordered]@{
            explicit_trigger = $explicit
            category_match   = $catMatch
            tag_match        = $tagMatch
            domain_match     = $domainMatch
            secondary_domain_match = $secondaryDomainMatch
            role_affinity    = $roleAff
            project_affinity = $projAff
            availability     = $avail
            freshness        = $freshBit
            classification_confidence = $confPoints
        }
    }
}

function Get-RouterFallbackResult {
    <#
    .SYNOPSIS
        Fallback em prosa (keywords->agente; default coder). Nunca lanca.
        Phase 8 fix Sec HIGH: o fallback NUNCA recomenda agente fora da
        allowlist. Quando a allowlist e informada (-Allowlist) e o agente em
        prosa nao e elegivel, retorna agent=null + blocked=true (sem delegar)
        com fallback_used=true; nunca sugere agente proibido. Tarefa trivial
        (direct=true, sem delegacao) nao e bloqueada: nao ha delegacao.
    #>
    [CmdletBinding()]
    param($Task, $Policy, [string]$Reason, [string[]]$FiltersApplied, [string[]]$Allowlist, [string]$AgentOverride = '')
    $expected = Get-RouterExpectedAgent -Task $Task
    $trivial = Test-RouterTrivial -Task $Task -Policy $Policy
    $agent = $expected
    $direct = $false
    if ($trivial) {
        $agent = 'build'
        $direct = $true
    }
    # Override deterministico explicito vence inclusive a trivialidade: uma
    # tarefa security-sensitive nunca pode virar DIRECT/build.
    if (-not [string]::IsNullOrWhiteSpace($AgentOverride)) {
        $agent = $AgentOverride
        $direct = $false
    }
    if ($agent -ceq '') { $agent = 'coder' }
    $risk = Convert-RouterNormalizedText -Text ([string]$Task.Risk).Trim()
    if ([string]::IsNullOrWhiteSpace($risk)) { $risk = 'unknown' }
    if ((-not $direct) -and $PSBoundParameters.ContainsKey('Allowlist') -and ($null -ne $Allowlist)) {
        if ($Allowlist -cnotcontains $agent) {
            return [PSCustomObject]@{
                route           = [PSCustomObject]@{ agent = $null; skills = @(); mcps = @(); direct = $false }
                reason          = ('fallback BLOQUEADO: agente em prosa {0} fora da allowlist ({1}); sem delegacao' -f $agent, $Reason)
                source          = 'fallback-policy'
                risk            = $risk
                confidence      = 0.2
                fallback_used   = $true
                blocked         = $true
                filters_applied = @($FiltersApplied)
                explain         = @()
            }
        }
    }
    return [PSCustomObject]@{
        route           = [PSCustomObject]@{ agent = $agent; skills = @(); mcps = @(); direct = [bool]$direct }
        reason          = $Reason
        source          = 'fallback-policy'
        risk            = $risk
        confidence      = 0.4
        fallback_used   = $true
        blocked         = $false
        filters_applied = @($FiltersApplied)
        explain         = @()
    }
}

function Invoke-RouterRoute {
    <#
    .SYNOPSIS
        Stage A (role) + Stage B (capabilities). Nunca lanca; em erro interno
        retorna fallback.
    #>
    [CmdletBinding()]
    param($Task, $Policy, $Capabilities, [string[]]$Allowlist, [bool]$Fresh, [string[]]$StaleReasons)
    $filters = @('status', 'permission', 'trust', 'unknown-deny', 'freshness')
    try {
        $required = @(Get-RouterRequiredCapabilities -Task $Task -Policy $Policy)
        $exec = Test-RouterExecutionRequired -Task $Task
        $trivial = Test-RouterTrivial -Task $Task -Policy $Policy
        $expected = Get-RouterExpectedAgent -Task $Task
        $weights = Get-RouterWeights -Policy $Policy
        $risk = ([string]$Task.Risk).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($risk)) { $risk = 'unknown' }
        if ($trivial) {
            $explain = @()
            foreach ($req in @($required)) {
                $explain += [PSCustomObject]@{
                    capability_id       = $req
                    type                = 'capability-class'
                    reason              = 'trivial: sem delegacao (direct)'
                    source              = 'registry'
                    status              = 'available'
                    trust               = 'n/a'
                    risk                = $risk
                    score               = 0
                    hard_filters_passed = $true
                }
            }
            return [PSCustomObject]@{
                route           = [PSCustomObject]@{ agent = 'build'; skills = @(); mcps = @(); direct = $true }
                reason          = ('tarefa trivial: sem delegacao (expected {0})' -f $expected)
                source          = 'registry'
                risk            = $risk
                confidence      = 0.9
                fallback_used   = $false
                filters_applied = @($filters)
                explain         = @($explain)
            }
        }
        $agentCands = @()
        $skillCands = @()
        $mcpCands = @()
        $explain = New-Object System.Collections.Generic.List[object]
        foreach ($rec in @($Capabilities)) {
            $hf = Test-RouterHardFilter -Record $rec -Task $Task -RequiredCaps $required -Allowlist $Allowlist -Policy $Policy -ExecutionRequired $exec
            $id = $hf.Id
            if ([string]::IsNullOrWhiteSpace($id)) { $id = Get-RecordScalar -Record $rec -Field 'id' }
            $scoreObj = Get-RouterScore -Record $rec -Task $Task -RequiredCaps $required -Weights $weights -ExpectedAgent $expected -Fresh $Fresh -Policy $Policy
            $entry = [PSCustomObject]@{
                capability_id       = [string]$id
                type                = [string]$hf.Type
                reason              = ''
                source              = 'registry'
                status              = [string]$hf.Status
                trust               = [string]$hf.Trust
                risk                = [string](Get-RecordScalar -Record $rec -Field 'risk')
                score               = [int]$scoreObj.Score
                hard_filters_passed = [bool]$hf.Pass
            }
            if ($hf.Pass) {
                $entry.reason = ('score {0} (explicit {1}, category {2}, tag {3}, domain {4}, role {5}, project {6}, avail {7}, fresh {8}, conf {9})' -f $scoreObj.Score, $scoreObj.Components['explicit_trigger'], $scoreObj.Components['category_match'], $scoreObj.Components['tag_match'], $scoreObj.Components['domain_match'], $scoreObj.Components['role_affinity'], $scoreObj.Components['project_affinity'], $scoreObj.Components['availability'], $scoreObj.Components['freshness'], $scoreObj.Components['classification_confidence'])
            }
            else {
                $entry.reason = ('hard-filter bloqueou: ' + (($hf.FailReasons | ForEach-Object { "$_" }) -join ' | '))
                $entry.score = 0
            }
            $explain.Add($entry) | Out-Null
            if (-not $hf.Pass) { continue }
            if ($hf.Type -ceq 'agent') {
                $agentCands += [PSCustomObject]@{ Id = [string]$id; Name = [string]$hf.Name; Score = [int]$scoreObj.Score; Relevant = [bool]$scoreObj.Relevant }
            }
            elseif ($hf.Type -ceq 'skill') {
                $skillCands += [PSCustomObject]@{ Id = [string]$id; Name = [string]$hf.Name; Score = [int]$scoreObj.Score; Relevant = [bool]$scoreObj.Relevant }
            }
            elseif ($hf.Type -ceq 'mcp') {
                $mcpCands += [PSCustomObject]@{ Id = [string]$id; Name = [string]$hf.Name; Score = [int]$scoreObj.Score; Relevant = [bool]$scoreObj.Relevant }
            }
        }
        $sortedExplain = @($explain | Sort-Object @{ Expression = { [string]$_.capability_id } })
        [Array]::Sort([string[]]@($sortedExplain | ForEach-Object { $_.capability_id }), [System.StringComparer]::Ordinal) | Out-Null
        $orderedExplain = @()
        $ids = @($explain | ForEach-Object { [string]$_.capability_id })
        [Array]::Sort([string[]]$ids, [System.StringComparer]::Ordinal)
        foreach ($cid in $ids) {
            foreach ($e in $explain) {
                if ([string]$e.capability_id -ceq $cid) { $orderedExplain += $e; break }
            }
        }
        $chosenAgent = ''
        # V3-P8-FIX2 (HIGH Rev): agentes tambem exigem relevancia positiva.
        # Filtra por Relevant ANTES do ranking; availability/freshness so
        # reponderam. Sem agente relevante => fallback seguro (nunca escolhe
        # agente irrelevante por availability).
        $relevantAgents = @($agentCands | Where-Object { [bool]$_.Relevant })
        if ($relevantAgents.Count -gt 0) {
            $ranked = @($relevantAgents | Sort-Object -Property @{ Expression = { -$_.Score } }, @{ Expression = { [string]$_.Id } })
            $rankedIds = @($ranked | ForEach-Object { $_.Id })
            $byScore = @{}
            foreach ($c in $ranked) { $byScore[$c.Id] = $c.Score }
            $sortedIds = @($rankedIds)
            $chosenAgent = [string]$ranked[0].Name
            if ([string]::IsNullOrWhiteSpace($chosenAgent)) { $chosenAgent = ([string]$ranked[0].Id -replace '^agent:', '') }
        }
        else {
            $fb = Get-RouterFallbackResult -Task $Task -Policy $Policy -Reason 'sem agente relevante/elegivel no registry (hard filters + relevancia); fallback seguro' -FiltersApplied $filters -Allowlist $Allowlist
            $fb.explain = @($orderedExplain)
            return $fb
        }
        $complex = $false
        if (($risk -ceq 'high') -or ($risk -ceq 'critical')) { $complex = $true }
        elseif ($required.Count -ge 3) { $complex = $true }
        elseif (([string]$Task.TaskType -ceq 'complex') -or ([string]$Task.TaskType -ceq 'migration')) { $complex = $true }
        $topk = Get-RouterTopK -Policy $Policy -Complex $complex
        $allCaps = @($skillCands + $mcpCands)
        $rankedCaps = @()
        # Elegibilidade (fix Rev HIGH): skills/MCPs sem relevancia positiva
        # (score.Relevant=$false) nunca sao candidatas, mesmo com score>0 via
        # availability/freshness. Filtra antes do top-k; top-k 0 nao indexa.
        $eligibleCaps = @($allCaps | Where-Object { ($_.Score -gt 0) -and ([bool]$_.Relevant) })
        if (($eligibleCaps.Count -gt 0) -and ($topk -gt 0)) {
            $rankedCaps = @($eligibleCaps | Sort-Object -Property @{ Expression = { -$_.Score } }, @{ Expression = { [string]$_.Id } })
            if ($rankedCaps.Count -gt $topk) { $rankedCaps = @($rankedCaps[0..($topk - 1)]) }
        }
        $skills = @()
        $mcps = @()
        foreach ($c in $rankedCaps) {
            $cidLower = ([string]$c.Id).ToLowerInvariant()
            $short = ([string]$c.Id -replace '^(skill|mcp):', '')
            if ($cidLower.StartsWith('skill:')) { $skills += $short }
            elseif ($cidLower.StartsWith('mcp:')) { $mcps += $short }
        }
        $conf = 0.85
        if ($complex) { $conf = 0.8 }
        return [PSCustomObject]@{
            route           = [PSCustomObject]@{ agent = $chosenAgent; skills = @($skills); mcps = @($mcps); direct = $false }
            reason          = ('Stage A expected {0} -> escolhido {1} (relevantes {2}/{3}); Stage B top-{4} sobre {5} capability(ies) elegivel(eis) (requeridas: {6})' -f $expected, $chosenAgent, $relevantAgents.Count, $agentCands.Count, $topk, $allCaps.Count, ($required -join ','))
            source          = 'registry'
            risk            = $risk
            confidence      = $conf
            fallback_used   = $false
            filters_applied = @($filters)
            explain         = @($orderedExplain)
        }
    }
    catch {
        # V3-P8-FIX2 (MED Sec): fallback de excecao interna respeita a
        # allowlist; sem agente relevante/elegivel => agent=null + blocked.
        return (Get-RouterFallbackResult -Task $Task -Policy $Policy -Reason ('fallback: erro interno do router ({0})' -f $_.Exception.Message) -FiltersApplied @('status', 'permission', 'trust', 'unknown-deny', 'freshness') -Allowlist $Allowlist)
    }
}

function Compare-RouterBaseline {
    [CmdletBinding()]
    param(
        [string]$ChosenAgent,
        [string[]]$ChosenSkills,
        [string]$BaselineAgent,
        [string[]]$BaselineSkills,
        [string]$ExpectedAgent
    )
    $ca = ([string]$ChosenAgent).Trim().ToLowerInvariant()
    $ba = ([string]$BaselineAgent).Trim().ToLowerInvariant()
    $cs = @()
    foreach ($v in @($ChosenSkills)) { if (-not [string]::IsNullOrWhiteSpace([string]$v)) { $cs += ([string]$v).Trim().ToLowerInvariant() } }
    $bs = @()
    foreach ($v in @($BaselineSkills)) { if (-not [string]::IsNullOrWhiteSpace([string]$v)) { $bs += ([string]$v).Trim().ToLowerInvariant() } }
    [Array]::Sort([string[]]$cs, [System.StringComparer]::Ordinal)
    [Array]::Sort([string[]]$bs, [System.StringComparer]::Ordinal)
    if (($ca -ceq $ba) -and (($cs -join '|') -ceq ($bs -join '|'))) { return 'equal' }
    $exp = ([string]$ExpectedAgent).Trim().ToLowerInvariant()
    $v3Hits = ($ca -ceq $exp)
    $baseHits = ($ba -ceq $exp)
    if ($v3Hits -and -not $baseHits) { return 'v3_better' }
    if ($baseHits -and -not $v3Hits) { return 'v3_worse' }
    return 'unclear'
}
