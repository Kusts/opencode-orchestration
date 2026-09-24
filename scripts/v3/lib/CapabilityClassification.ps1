<#!
.SYNOPSIS
    V3 Capability classification: conhecimento descritivo (category/capabilities/domains/technologies/task_types/roles).
.DESCRIPTION
    Biblioteca dot-sourceable (sem acesso a disco/rede alem do objeto $Policy
    passado pelo chamador). Implementa a camada DESCRITIVA da classificacao
    (capability-policy.json -> classification): explicit (agent) > curated
    (skill/mcp nesta secao) > deterministic inference > unknown.

    Classificacao NUNCA altera trust/risk/permission/allowlist: a saida nao
    contem campos trust/risk e o build so a usa para categories (skill/mcp),
    capabilities candidatas (filtradas pelo filtro canonico/produtor
    existente), tags/domains/technologies/task_types/roles e o bloco
    `classification` (confidence/source_kind/taxonomy_version).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Remove-ClassificationDuplicates {
    <#
    .SYNOPSIS
        Dedup ordinal preservando a ordem; ignora nulos/vazios.
    #>
    [CmdletBinding()]
    param($Items)
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $out = @()
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        $text = [string]$item
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($seen.Add($text)) { $out += $text }
    }
    return $out
}

function Get-RecordFieldValue {
    <#
    .SYNOPSIS
        Le um campo de um registro hashtable ou PSCustomObject (case-sensitive).
    #>
    [CmdletBinding()]
    param($Record, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Record) { return $null }
    if ($Record -is [System.Collections.IDictionary]) {
        foreach ($key in @($Record.Keys)) {
            if ("$key" -ceq $Name) { return $Record[$key] }
        }
        return $null
    }
    $property = @($Record.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1)
    if ($property.Count -eq 0) { return $null }
    return $property[0].Value
}

function Get-ClassificationEntry {
    <#
    .SYNOPSIS
        Retorna Policy.classification.<section>.<name> ou $null (hashtable ou PSCustomObject).
    #>
    [CmdletBinding()]
    param($Policy, [Parameter(Mandatory = $true)][string]$Section, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Policy) { return $null }
    $classification = $null
    if ($Policy -is [System.Collections.IDictionary]) {
        foreach ($key in @($Policy.Keys)) {
            if ("$key" -ceq 'classification') { $classification = $Policy[$key] }
        }
    }
    else {
        $slot = @($Policy.PSObject.Properties | Where-Object { $_.Name -ceq 'classification' } | Select-Object -First 1)
        if ($slot.Count -gt 0) { $classification = $slot[0].Value }
    }
    if ($null -eq $classification) { return $null }
    $sectionNode = $null
    if ($classification -is [System.Collections.IDictionary]) {
        foreach ($key in @($classification.Keys)) {
            if ("$key" -ceq $Section) { $sectionNode = $classification[$key] }
        }
    }
    else {
        $slot = @($classification.PSObject.Properties | Where-Object { $_.Name -ceq $Section } | Select-Object -First 1)
        if ($slot.Count -gt 0) { $sectionNode = $slot[0].Value }
    }
    if ($null -eq $sectionNode) { return $null }
    if ($sectionNode -is [System.Collections.IDictionary]) {
        foreach ($key in @($sectionNode.Keys)) {
            if ("$key" -ceq $Name) { return $sectionNode[$key] }
        }
        return $null
    }
    $slot = @($sectionNode.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1)
    if ($slot.Count -eq 0) { return $null }
    return $slot[0].Value
}

function Get-ClassificationEntryString {
    [CmdletBinding()]
    param($Entry, [Parameter(Mandatory = $true)][string]$Name)
    $value = Get-RecordFieldValue -Record $Entry -Name $Name
    if ($null -eq $value) { return $null }
    $text = [string]$value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text
}

function Get-ClassificationEntryStringArray {
    [CmdletBinding()]
    param($Entry, [Parameter(Mandatory = $true)][string]$Name)
    $value = Get-RecordFieldValue -Record $Entry -Name $Name
    if ($null -eq $value) { return @() }
    if ($value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($value)) { return @() }
        return @($value)
    }
    if (($value -is [System.Collections.IEnumerable]) -and -not ($value -is [System.Collections.IDictionary])) {
        return @(Remove-ClassificationDuplicates -Items @($value))
    }
    return @()
}

function Get-InternalCanonicalSet {
    <#
    .SYNOPSIS
        Chaves de capability_taxonomy.producers como HashSet ordinal (sem disco).
    #>
    [CmdletBinding()]
    param($Policy)
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    if ($null -eq $Policy) { return $set }
    $taxonomy = Get-RecordFieldValue -Record $Policy -Name 'capability_taxonomy'
    if ($null -eq $taxonomy) { return $set }
    $producers = Get-RecordFieldValue -Record $taxonomy -Name 'producers'
    if ($null -eq $producers) { return $set }
    if ($producers -is [System.Collections.IDictionary]) {
        foreach ($key in @($producers.Keys)) { $set.Add("$key") | Out-Null }
    }
    else {
        foreach ($p in @($producers.PSObject.Properties)) { $set.Add($p.Name) | Out-Null }
    }
    return $set
}

function Select-CanonicalCapability {
    <#
    .SYNOPSIS
        Mantem somente IDs canonicos (matching exato), dedup ordinal.
    #>
    [CmdletBinding()]
    param($Policy, $Ids)
    $canon = Get-InternalCanonicalSet -Policy $Policy
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $out = @()
    foreach ($id in @($Ids)) {
        if ($null -eq $id) { continue }
        $text = ([string]$id).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($canon.Contains($text) -and $seen.Add($text)) { $out += $text }
    }
    return $out
}

function Get-ClassificationInferenceRules {
    <#
    .SYNOPSIS
        Regras deterministas ordenadas (ordem = precedencia de categoria).
    .DESCRIPTION
        Cada regra: Category, Capabilities, Domains, Technologies, Patterns
        (regex com word-boundary; stems prefixados onde a flexao exige).
    #>
    [CmdletBinding()]
    param()
    return @(
        [PSCustomObject]@{ Category = 'infrastructure'; Capabilities = @('infrastructure.deployment'); Domains = @('cloudflare'); Technologies = @('cloudflare'); Patterns = @('\bcloudflare\w*', '\bworkers\.dev\b', '\bwrangler\w*', '\bdurable\s+objects?\b', '\bvectorize\w*', '\bhyperdrive\w*', '\br2\s+buckets?\b', '\bd1\s+databases?\b', '\bkv\s+namespaces?\b', '\bturnstile\w*', '\bsandbox\s+sdk\b', '\bemail\s+routing\b') },
        [PSCustomObject]@{ Category = 'business'; Capabilities = @(); Domains = @('business'); Technologies = @(); Patterns = @('\bcopy\b', '\bcopies\b', '\bcopywriting\b', '\bvendas\b', '\bsales\b', '\bmarketing\w*', '\btraffics?\b', '\bads\b', '\bpersuas\w*\b', '\bcampanhas?\b') },
        [PSCustomObject]@{ Category = 'frontend'; Capabilities = @('frontend.implementation'); Domains = @('frontend'); Technologies = @('react', 'tailwind', 'shadcn'); Patterns = @('\bfrontend\w*', '\bcss\b', '\bhtml\w*', '\breact\w*', '\btailwind\w*', '\bshadcn\w*', '\bcomponents?\b', '\blanding\s+pages?\b', '\bdashboards?\b', '\bresponsive\w*', '\bweb\s+uis?\b') },
        [PSCustomObject]@{ Category = 'design'; Capabilities = @('product.ux', 'design.states'); Domains = @('design'); Technologies = @(); Patterns = @('\bdesign\s+systems?\b', '\btypograph\w*\b', '\bcolou?r\s+palettes?\b', '\bthemes?\b', '\bposters?\b', '\bbrands?\b', '\bvisual\s+designs?\b', '\bux\b', '\buser\s+flows?\b', '\bwireframes?\b') },
        [PSCustomObject]@{ Category = 'security'; Capabilities = @('security.review'); Domains = @('security'); Technologies = @(); Patterns = @('\bsecurit\w*\b', '\bappsec\w*', '\bpentests?\b', '\bvulnerab\w*\b', '\bowasp\b', '\bcsrf\b', '\bxss\b', '\bsql\s+injections?\b', '\bfuzz\w*\b', '\bauthenticat\w*\b', '\bauthori\w*\b') },
        [PSCustomObject]@{ Category = 'quality'; Capabilities = @('debugging.root-cause'); Domains = @('quality'); Technologies = @(); Patterns = @('\bdebug\w*\b', '\broot\s+causes?\b', '\bdiagnos\w*\b', '\breproduc\w*\b', '\bflaky\b', '\bintermittent\w*') },
        [PSCustomObject]@{ Category = 'quality'; Capabilities = @('test.run', 'quality.test-design'); Domains = @('quality'); Technologies = @(); Patterns = @('\btest\w*\b', '\btdd\b', '\bverif\w*\b', '\bcoverages?\b', '\bassert\w*\b', '\bregressions?\b') },
        [PSCustomObject]@{ Category = 'quality'; Capabilities = @('quality.review'); Domains = @('quality'); Technologies = @(); Patterns = @('\bcode\s+reviews?\b', '\breviews?\b', '\bcritiques?\b', '\baudits?\b', '\bstandards?\b') },
        [PSCustomObject]@{ Category = 'planning'; Capabilities = @('requirements.clarification', 'requirements.acceptance-criteria'); Domains = @('planning'); Technologies = @(); Patterns = @('\bplan\w*\b', '\bprd\b', '\bspecs?\b', '\bspecifications?\b', '\bspecified\b', '\brequirements?\b', '\btickets?\b', '\bissues?\b', '\bbrainstorm\w*\b', '\bdecisions?\b', '\broadmaps?\b', '\bbacklogs?\b') },
        [PSCustomObject]@{ Category = 'memory'; Capabilities = @('memory.project-history'); Domains = @('memory'); Technologies = @(); Patterns = @('\bmemo\w*\b', '\bvaults?\b', '\bhandoffs?\b', '\bsecond\s+brains?\b', '\bobsidian\w*', '\bwikis?\b', '\bconsolidat\w*\b', '\bknowledge\s+bases?\b') },
        [PSCustomObject]@{ Category = 'orchestration'; Capabilities = @('ai.agent-design'); Domains = @('orchestration'); Technologies = @(); Patterns = @('\bagents?\b', '\borchestrat\w*\b', '\bsubagents?\b', '\bdelegat\w*\b', '\bmaestri\w*', '\bherdr\w*', '\bmulti[\s-]*agents?\b', '\bworkers?\b', '\bteams?\b', '\bterminals?\b') },
        [PSCustomObject]@{ Category = 'documentation'; Capabilities = @('docs.authoring'); Domains = @('documentation'); Technologies = @(); Patterns = @('\bdocuments?\b', '\barticles?\b', '\breports?\b', '\bproposals?\b', '\bslides?\b', '\bpresentations?\b', '\bspreadsheets?\b', '\bdocx\b', '\bxlsx\b', '\bnewsletters?\b', '\bcommunications?\b') },
        [PSCustomObject]@{ Category = 'research'; Capabilities = @('research.external'); Domains = @('research'); Technologies = @(); Patterns = @('\bresearch\w*', '\bscrap\w*\b', '\bweb\w*\b', '\bbrowsers?\b', '\bplaywright\w*', '\bwatch\w*\b', '\bvideos?\b', '\bcrawl\w*\b', '\bfetch\w*\b', '\bperfs?\b', '\blighthouse\w*') },
        [PSCustomObject]@{ Category = 'database'; Capabilities = @('database.schema', 'database.read'); Domains = @('database'); Technologies = @(); Patterns = @('\bdatabases?\b', '\bsqls?\b', '\bschemas?\b', '\bmigrat\w*\b', '\bquer\w*\b', '\bpostgres\w*\b', '\bsqlite\w*', '\bdata\s+models?\b', '\bindex\w*\b') },
        [PSCustomObject]@{ Category = 'backend'; Capabilities = @('backend.implementation', 'backend.api'); Domains = @('backend'); Technologies = @(); Patterns = @('\bapis?\b', '\bservers?\b', '\bbackends?\b', '\bservices?\b', '\bendpoints?\b', '\brest\b', '\brestful\b', '\bgraphql\w*', '\bhttp\w*\b') },
        [PSCustomObject]@{ Category = 'automation'; Capabilities = @('automation.workflow', 'automation.cicd'); Domains = @('automation'); Technologies = @(); Patterns = @('\bautomation\w*', '\bci\b', '\bcd\b', '\bpipelines?\b', '\bpre[\s-]*commits?\b', '\bhooks?\b', '\bschedul\w*\b', '\broutines?\b') },
        [PSCustomObject]@{ Category = 'architecture'; Capabilities = @('architecture.boundaries', 'architecture.tradeoffs'); Domains = @('architecture'); Technologies = @(); Patterns = @('\barchitectures?\b', '\bboundar\w*\b', '\bmodul\w*\b', '\binterfaces?\b', '\bintegrations?\b', '\btrade[\s-]*offs?\b', '\bscalab\w*\b', '\brefactor\w*\b') },
        [PSCustomObject]@{ Category = 'ai'; Capabilities = @('ai.agent-design'); Domains = @('ai'); Technologies = @(); Patterns = @('\bllms?\b', '\bprompts?\b', '\bmodels?\b', '\bmcp\s+servers?\b', '\banthropic\w*', '\bclaude\s+apis?\b', '\bopenai\w*', '\bembed\w*\b') },
        [PSCustomObject]@{ Category = 'engineering'; Capabilities = @('code.bounded-edit'); Domains = @('code'); Technologies = @(); Patterns = @('\bcode\w*\b', '\bcoding\b', '\bimplement\w*\b', '\bfunctions?\b', '\bskeletons?\b', '\basts?\b', '\blints?\b', '\bgit\w*\b', '\bbranch\w*\b', '\bmerges?\b', '\bworktrees?\b', '\bcommits?\b') }
    )
}

function New-EmptyClassification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Confidence,
        [Parameter(Mandatory = $true)][string]$SourceKind
    )
    return [ordered]@{
        category         = $null
        capabilities     = @()
        domains          = @()
        technologies     = @()
        task_types       = @()
        preferred_roles  = @()
        compatible_roles = @()
        confidence       = $Confidence
        source_kind      = $SourceKind
    }
}

function Get-InferredSkillClassification {
    <#
    .SYNOPSIS
        Inferencia deterministica sobre nome+descricao (lowercase invariante).
    .DESCRIPTION
        Aplica as regras ordenadas; a PRIMEIRA regra casada e a PRIMARIA
        (categoria/capabilities/domains/technologies). Regras adicionais
        enriquecem o resultado SOMENTE quando a categoria e igual a da
        primaria (mesmo dominio). confidence: >=2 regras casadas (total)
        -> inferred_high; 1 -> inferred_low; 0 -> unknown (tudo vazio).
        Somente IDs canonicos; dedup ordinal; caps<=6, techs<=4.
        source_kind='deterministic-inference'. Sem campos trust/risk.
    #>
    [CmdletBinding()]
    param(
        [string]$Name = '',
        [string]$Description = '',
        $Policy
    )
    $text = (([string]$Name) + ' ' + ([string]$Description)).ToLowerInvariant()
    $matched = @()
    foreach ($rule in @(Get-ClassificationInferenceRules)) {
        $hit = $false
        foreach ($pattern in @($rule.Patterns)) {
            try {
                if ([regex]::IsMatch($text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                    $hit = $true
                    break
                }
            }
            catch {
                continue
            }
        }
        if ($hit) { $matched += $rule }
    }
    if ($matched.Count -eq 0) {
        return (New-EmptyClassification -Confidence 'unknown' -SourceKind 'deterministic-inference')
    }
    $primary = $matched[0]
    $caps = @($primary.Capabilities)
    $domains = @($primary.Domains)
    $techs = @($primary.Technologies)
    foreach ($rule in @($matched | Select-Object -Skip 1)) {
        if ("$($rule.Category)" -ceq "$($primary.Category)") {
            $caps += @($rule.Capabilities)
            $domains += @($rule.Domains)
            $techs += @($rule.Technologies)
        }
    }
    $caps = @(Remove-ClassificationDuplicates -Items @(Select-CanonicalCapability -Policy $Policy -Ids $caps))
    $domains = @(Remove-ClassificationDuplicates -Items $domains)
    $techs = @(Remove-ClassificationDuplicates -Items $techs)
    if ($caps.Count -gt 6) { $caps = @($caps | Select-Object -First 6) }
    if ($techs.Count -gt 4) { $techs = @($techs | Select-Object -First 4) }
    $confidence = 'inferred_low'
    if ($matched.Count -ge 2) { $confidence = 'inferred_high' }
    return [ordered]@{
        category         = [string]$matched[0].Category
        capabilities     = $caps
        domains          = $domains
        technologies     = $techs
        task_types       = @()
        preferred_roles  = @()
        compatible_roles = @()
        confidence       = $confidence
        source_kind      = 'deterministic-inference'
    }
}

function Get-RecordClassification {
    <#
    .SYNOPSIS
        Classificacao descritiva de um registro (agent/skill/mcp) via $Policy.
    .DESCRIPTION
        agent: capabilities=@() sempre (classes explicitas ja veem do
        discovery; nunca sobrescrever). Com entrada em
        classification.agent.<name> -> domains/task_types dela,
        confidence='explicit', source_kind='agent-orchestration'; senao
        domains = primeiro segmento das capabilities do registro,
        confidence='inferred_high', source_kind='capability-prefix'.
        skill: entrada curada -> confidence='curated',
        source_kind='curated-policy'; senao inferencia deterministica.
        mcp: entrada curada -> confidence dela (ou 'curated'),
        source_kind='curated-policy'; senao unknown/vazio. Sem trust/risk.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        $Record,
        [Parameter(Mandatory = $true)]$Policy
    )
    $normalizedType = ([string]$Type).Trim().ToLowerInvariant()
    $recordName = [string](Get-RecordFieldValue -Record $Record -Name 'name')
    if ($null -eq $recordName) { $recordName = '' }

    if ($normalizedType -ceq 'agent') {
        $entry = Get-ClassificationEntry -Policy $Policy -Section 'agent' -Name $recordName
        if ($null -ne $entry) {
            return [ordered]@{
                category         = $null
                capabilities     = @()
                domains          = @(Get-ClassificationEntryStringArray -Entry $entry -Name 'domains')
                technologies     = @()
                task_types       = @(Get-ClassificationEntryStringArray -Entry $entry -Name 'task_types')
                preferred_roles  = @()
                compatible_roles = @()
                confidence       = 'explicit'
                source_kind      = 'agent-orchestration'
            }
        }
        $prefixes = @()
        $rawCaps = Get-RecordFieldValue -Record $Record -Name 'capabilities'
        foreach ($cap in @($rawCaps)) {
            if ($null -eq $cap) { continue }
            $text = ([string]$cap).Trim()
            if ([string]::IsNullOrWhiteSpace($text)) { continue }
            $dot = $text.IndexOf('.')
            if ($dot -gt 0) { $prefixes += $text.Substring(0, $dot) }
            else { $prefixes += $text }
        }
        return [ordered]@{
            category         = $null
            capabilities     = @()
            domains          = @(Remove-ClassificationDuplicates -Items $prefixes)
            technologies     = @()
            task_types       = @()
            preferred_roles  = @()
            compatible_roles = @()
            confidence       = 'inferred_high'
            source_kind      = 'capability-prefix'
        }
    }

    if ($normalizedType -ceq 'skill') {
        $entry = Get-ClassificationEntry -Policy $Policy -Section 'skill' -Name $recordName
        if ($null -ne $entry) {
            $caps = @(Remove-ClassificationDuplicates -Items @(Select-CanonicalCapability -Policy $Policy -Ids @(Get-ClassificationEntryStringArray -Entry $entry -Name 'capabilities')))
            if ($caps.Count -gt 6) { $caps = @($caps | Select-Object -First 6) }
            $techs = @(Get-ClassificationEntryStringArray -Entry $entry -Name 'technologies')
            if ($techs.Count -gt 4) { $techs = @($techs | Select-Object -First 4) }
            return [ordered]@{
                category         = (Get-ClassificationEntryString -Entry $entry -Name 'category')
                capabilities     = $caps
                domains          = @(Get-ClassificationEntryStringArray -Entry $entry -Name 'domains')
                technologies     = $techs
                task_types       = @(Get-ClassificationEntryStringArray -Entry $entry -Name 'task_types')
                preferred_roles  = @()
                compatible_roles = @()
                confidence       = 'curated'
                source_kind      = 'curated-policy'
            }
        }
        $skillDescription = [string](Get-RecordFieldValue -Record $Record -Name 'description')
        if ($null -eq $skillDescription) { $skillDescription = '' }
        return (Get-InferredSkillClassification -Name $recordName -Description $skillDescription -Policy $Policy)
    }

    if ($normalizedType -ceq 'mcp') {
        $entry = Get-ClassificationEntry -Policy $Policy -Section 'mcp' -Name $recordName
        if ($null -ne $entry) {
            $entryConfidence = Get-ClassificationEntryString -Entry $entry -Name 'confidence'
            if ([string]::IsNullOrWhiteSpace($entryConfidence)) { $entryConfidence = 'curated' }
            $caps = @(Remove-ClassificationDuplicates -Items @(Select-CanonicalCapability -Policy $Policy -Ids @(Get-ClassificationEntryStringArray -Entry $entry -Name 'capabilities')))
            if ($caps.Count -gt 6) { $caps = @($caps | Select-Object -First 6) }
            $techs = @(Get-ClassificationEntryStringArray -Entry $entry -Name 'technologies')
            if ($techs.Count -gt 4) { $techs = @($techs | Select-Object -First 4) }
            return [ordered]@{
                category         = (Get-ClassificationEntryString -Entry $entry -Name 'category')
                capabilities     = $caps
                domains          = @(Get-ClassificationEntryStringArray -Entry $entry -Name 'domains')
                technologies     = $techs
                task_types       = @(Get-ClassificationEntryStringArray -Entry $entry -Name 'task_types')
                preferred_roles  = @()
                compatible_roles = @()
                confidence       = $entryConfidence
                source_kind      = 'curated-policy'
            }
        }
        return (New-EmptyClassification -Confidence 'unknown' -SourceKind 'unknown')
    }

    return (New-EmptyClassification -Confidence 'unknown' -SourceKind 'unknown')
}
