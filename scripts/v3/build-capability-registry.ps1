<#!
.SYNOPSIS
    Builds the derived V3 capability registry from source/agents + policy (distribution).
.DESCRIPTION
    Variante distribuicao do build-capability-registry do control plane: em vez
    de consumir um envelope de discovery (discover-capabilities.ps1, ausente
    nesta distribuicao), faz probe direto e deterministico de
    source/agents/*.md (frontmatter: description, mode, bloco orchestration
    com build_delegable/lifecycle/visibility/capabilities preferred/forbidden)
    e aplica a transversal source/registry/capability-policy.json (risk via
    risk_policy, trust default unknown, classificacao de dominios via
    CapabilityClassification, validacao via Test-CapabilityRecord).

    Registros invalidos viram status 'invalid' e sao reportados, nunca
    descartados em silencio. trust/risk v em EXCLUSIVAMENTE da policy
    curada; frontmatter contribui apenas description/capabilities candidatas
    (nao confiaveis ate filtragem por canonical + produtor autorizado).

    Idempotencia: registry.logical_hash cobre o conteudo SEM campos volateis
    (registry.generated_at, registry.freshness.computed_at e age_seconds, e
    evidence.captured_at por registro); duas runs sobre o mesmo estado logico
    produzem o MESMO logical_hash. source_fingerprint e computado sobre o
    probe SANEADO (sem timestamps).

    Escreve somente em -Out (default cache/v3/capability-registry.json). Com
    -Preview nada e escrito. Nunca toca alvos live.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$PolicyPath,
    [string]$AgentsDir,
    [string]$Out,
    [switch]$Preview,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

$libRoot = Join-Path $PSScriptRoot 'lib'
. (Join-Path $libRoot 'CapabilitySchema.ps1')
. (Join-Path $libRoot 'CapabilityTaxonomy.ps1')
. (Join-Path $libRoot 'CapabilityClassification.ps1')
. (Join-Path $libRoot 'CapabilitySanitize.ps1')

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
if ([string]::IsNullOrWhiteSpace($PolicyPath)) {
    $PolicyPath = Join-Path $RepoRoot 'source\registry\capability-policy.json'
}
if ([string]::IsNullOrWhiteSpace($AgentsDir)) {
    $AgentsDir = Join-Path $RepoRoot 'source\agents'
}
$defaultOut = Join-Path $RepoRoot 'cache\v3\capability-registry.json'

function Read-Utf8Text {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))
}

function Get-BuildFrontmatter {
    <#
    .SYNOPSIS
        Extrai o frontmatter YAML-subset dos agent .md (entre os dois '---').
    .DESCRIPTION
        Parser de subconjunto deterministico para o shape conhecido dos
        arquivos source/agents/*.md: chaves escalares de primeiro nivel
        (description/mode), bloco orchestration com escalares e listas
        capabilities preferred/forbidden ('- item' ou '[]'). Nao e um parser
        YAML geral; ignora blocos desconhecidos (ex.: permission).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    $lines = ([string]$Text) -split "`n"
    $start = -1
    $finish = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if (([string]$lines[$i]).Trim() -ceq '---') { $start = $i; break }
    }
    if ($start -lt 0) { return $null }
    for ($j = $start + 1; $j -lt $lines.Count; $j++) {
        if (([string]$lines[$j]).Trim() -ceq '---') { $finish = $j; break }
    }
    if ($finish -lt 0) { return $null }
    $fm = @{
        description = ''
        mode = 'subagent'
        build_delegable = $true
        lifecycle = 'stable'
        visibility = 'normal'
        preferred = @()
        forbidden = @()
    }
    $section = ''
    $listTarget = ''
    for ($k = $start + 1; $k -lt $finish; $k++) {
        $raw = ([string]$lines[$k]).Trim()
        if ([string]::IsNullOrWhiteSpace($raw) -or $raw.StartsWith('#')) { continue }
        if ($raw -ceq 'orchestration:') { $section = 'orchestration'; $listTarget = ''; continue }
        if ($raw -ceq 'capabilities:') { $section = 'capabilities'; $listTarget = ''; continue }
        if (($raw -ceq 'permission:') -or ($raw -ceq 'bash:')) { $section = 'other'; $listTarget = ''; continue }
        if ($raw.StartsWith('- ') -and ($section -ceq 'capabilities') -and (-not [string]::IsNullOrWhiteSpace($listTarget))) {
            $item = $raw.Substring(2).Trim()
            if (-not [string]::IsNullOrWhiteSpace($item)) {
                if ($listTarget -ceq 'preferred') { $fm['preferred'] = @($fm['preferred']) + @($item) }
                elseif ($listTarget -ceq 'forbidden') { $fm['forbidden'] = @($fm['forbidden']) + @($item) }
            }
            continue
        }
        $colon = $raw.IndexOf(':')
        if ($colon -lt 0) { continue }
        $key = $raw.Substring(0, $colon).Trim()
        $val = $raw.Substring($colon + 1).Trim()
        if ($section -ceq '') {
            if ($key -ceq 'description') { $fm['description'] = $val }
            elseif ($key -ceq 'mode') { if (-not [string]::IsNullOrWhiteSpace($val)) { $fm['mode'] = $val } }
            continue
        }
        if ($section -ceq 'orchestration') {
            if ($key -ceq 'build_delegable') { $fm['build_delegable'] = ($val -ceq 'true') }
            elseif ($key -ceq 'lifecycle') { if (-not [string]::IsNullOrWhiteSpace($val)) { $fm['lifecycle'] = $val } }
            elseif ($key -ceq 'visibility') { if (-not [string]::IsNullOrWhiteSpace($val)) { $fm['visibility'] = $val } }
            continue
        }
        if ($section -ceq 'capabilities') {
            if ($key -ceq 'preferred') {
                if (($val -ceq '[]') -or ($val -ceq '')) { $fm['preferred'] = @(); $listTarget = '' }
                else { $listTarget = 'preferred' }
                continue
            }
            if ($key -ceq 'forbidden') {
                if (($val -ceq '[]') -or ($val -ceq '')) { $fm['forbidden'] = @(); $listTarget = '' }
                else { $listTarget = 'forbidden' }
                continue
            }
        }
    }
    return $fm
}

function Get-StringSha256Hex {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $digest = $sha.ComputeHash($bytes) }
    finally { $sha.Dispose() }
    return (($digest | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-RiskRank {
    param([string]$Risk)
    switch ("$Risk".Trim().ToLowerInvariant()) {
        'low' { return 1 }
        'medium' { return 2 }
        'high' { return 3 }
        'critical' { return 4 }
        default { return 0 }
    }
}

function Get-PolicyRiskForCaps {
    [CmdletBinding()]
    param($Policy, [string[]]$Capabilities, [string]$DefaultRisk)
    $best = $DefaultRisk
    $bestRank = Get-RiskRank -Risk $best
    $map = $null
    if ($null -ne $Policy.risk_policy) { $map = $Policy.risk_policy.capability_risk }
    if ($null -eq $map) { return $best }
    foreach ($cap in @($Capabilities)) {
        $entry = @($map.PSObject.Properties | Where-Object { $_.Name -ceq $cap } | Select-Object -First 1)
        if ($entry.Count -gt 0 -and $null -ne $entry[0].Value) {
            $candidate = [string]$entry[0].Value
            if ((Get-RiskRank -Risk $candidate) -gt $bestRank) {
                $best = $candidate
                $bestRank = Get-RiskRank -Risk $candidate
            }
        }
    }
    return $best
}

function Repair-StringArray {
    [CmdletBinding()]
    param($Value)
    $items = @()
    if ($null -eq $Value) { $items = @() }
    elseif (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        foreach ($v in $Value) { $items += [string]$v }
    }
    else { $items = @([string]$Value) }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $deduped = @()
    foreach ($v in $items) {
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        if ($seen.Add($v)) { $deduped += $v }
    }
    Write-Output -NoEnumerate $deduped
}

if (-not (Test-Path -LiteralPath $PolicyPath -PathType Leaf)) {
    [Console]::Error.WriteLine("capability-policy.json not found: $PolicyPath")
    exit 2
}
$policy = (Read-Utf8Text -Path $PolicyPath) | ConvertFrom-Json
$defaultRisk = 'unknown'
$defaultTrust = 'unknown'
if ($null -ne $policy.defaults) {
    if ($null -ne $policy.defaults.risk) { $defaultRisk = [string]$policy.defaults.risk }
    if ($null -ne $policy.defaults.trust) { $defaultTrust = [string]$policy.defaults.trust }
}
$canonicalList = @(Get-CanonicalCapabilityList -Policy $policy)

if (-not (Test-Path -LiteralPath $AgentsDir -PathType Container)) {
    [Console]::Error.WriteLine("Agents dir not found: $AgentsDir")
    exit 2
}
$files = @(Get-ChildItem -LiteralPath $AgentsDir -Filter '*.md' -File | Sort-Object Name)
if ($files.Count -eq 0) {
    [Console]::Error.WriteLine("No agent files in: $AgentsDir")
    exit 2
}

$probed = @()
foreach ($f in $files) {
    $name = [IO.Path]::GetFileNameWithoutExtension($f.Name)
    $text = Read-Utf8Text -Path $f.FullName
    $fm = Get-BuildFrontmatter -Text $text
    if ($null -eq $fm) {
        [Console]::Error.WriteLine(("agent sem frontmatter parseavel (vira invalid): {0}" -f $f.Name))
        $probed += @{ name = $name; file = $f.Name; fm = $null }
        continue
    }
    $probed += @{ name = $name; file = $f.Name; fm = $fm }
}

$sanCaps = @()
foreach ($p in $probed) {
    if ($null -eq $p.fm) { continue }
    $sanCaps += [ordered]@{
        id = ('agent:' + ([string]$p.name).Trim().ToLowerInvariant())
        description = [string]$p.fm['description']
        preferred = @($p.fm['preferred'])
    }
}
$sanIds = @($sanCaps | ForEach-Object { [string]$_['id'] })
[Array]::Sort([string[]]$sanIds, [System.StringComparer]::Ordinal)
$orderedSan = @()
foreach ($id in $sanIds) {
    foreach ($c in $sanCaps) {
        if ([string]$c['id'] -ceq $id) { $orderedSan += $c; break }
    }
}
$fpInput = [ordered]@{ schema_version = 1; agents = @($orderedSan) }
$sourceFingerprint = Get-LogicalHash -InputObject $fpInput

$normalized = @()
$invalidReport = @()
$counts = [ordered]@{ agent = 0; skill = 0; mcp = 0; invalid = 0; total = 0 }
foreach ($p in $probed) {
    $agentName = ([string]$p.name).Trim().ToLowerInvariant()
    $id = ('agent:' + $agentName)
    $diagErrors = @()
    if ($null -eq $p.fm) {
        $rec = [ordered]@{
            id = $id; type = 'agent'; name = $agentName; description = ''
            source = ('source/agents/' + [string]$p.file); source_kind = 'filesystem'; runtime = 'opencode'
            status = 'invalid'; categories = @(); tags = @(); capabilities = @()
            risk = $defaultRisk; trust = $defaultTrust; read_only = $false
            fingerprint = ('sha256:' + (Get-StringSha256Hex -Text $id))
            metadata = [ordered]@{ mode = 'subagent' }
            eligibility = [ordered]@{ build_delegable = $false; lifecycle = 'unknown'; visibility = 'unknown'; reason = 'distribution-build: frontmatter ilegivel' }
            capability_profile = [ordered]@{ preferred = @(); forbidden = @() }
            provenance = [ordered]@{ trust = 'policy'; risk = 'policy'; capabilities = 'agent-frontmatter' }
            evidence = [ordered]@{ method = 'distribution-build' }
        }
        $invalidReport += [ordered]@{ id = $id; errors = @('frontmatter ilegivel ou ausente') }
        $normalized += $rec
        continue
    }
    $fm = $p.fm
    $desc = [string]$fm['description']
    try {
        if (-not [string]::IsNullOrEmpty($desc)) { $desc = Remove-SecretValues -InputObject $desc }
    } catch { }
    $prefRaw = Repair-StringArray -Value $fm['preferred']
    if ($null -eq $prefRaw) { $prefRaw = @() }
    $forbRaw = Repair-StringArray -Value $fm['forbidden']
    if ($null -eq $forbRaw) { $forbRaw = @() }
    $keptCaps = @()
    foreach ($cap in @($prefRaw)) {
        if (-not ($canonicalList -ccontains $cap)) {
            $diagErrors += ("preferred '{0}' nao canonico; removido" -f $cap)
            continue
        }
        if (Test-CapabilityProducerAuthorized -Policy $policy -Id $cap -Producer 'agent-orchestration') {
            $keptCaps += $cap
        }
        else {
            $diagErrors += ("producer 'agent-orchestration' nao autorizado para '{0}'; removido" -f $cap)
        }
    }
    $keptForb = @()
    foreach ($cap in @($forbRaw)) {
        if (-not ($canonicalList -ccontains $cap)) {
            $diagErrors += ("forbidden '{0}' nao canonico; removido" -f $cap)
            continue
        }
        $keptForb += $cap
    }
    $clsRec = @{ name = $agentName; capabilities = @($keptCaps) }
    $cls = Get-RecordClassification -Type 'agent' -Record $clsRec -Policy $policy
    $agentDomains = Repair-StringArray -Value $cls.domains
    if ($null -eq $agentDomains) { $agentDomains = @() }
    $agentTaskTypes = Repair-StringArray -Value $cls.task_types
    if ($null -eq $agentTaskTypes) { $agentTaskTypes = @() }
    $risk = Get-PolicyRiskForCaps -Policy $policy -Capabilities $keptCaps -DefaultRisk $defaultRisk
    $rec = [ordered]@{
        id = $id; type = 'agent'; name = $agentName; description = $desc
        source = ('source/agents/' + [string]$p.file); source_kind = 'filesystem'; runtime = 'opencode'
        status = 'available'; categories = @($agentDomains); tags = @($agentDomains)
        capabilities = @($keptCaps); risk = $risk; trust = $defaultTrust; read_only = $false
        fingerprint = ('sha256:' + (Get-StringSha256Hex -Text $id))
        metadata = [ordered]@{ mode = 'subagent' }
        eligibility = [ordered]@{ build_delegable = [bool]$fm['build_delegable']; lifecycle = [string]$fm['lifecycle']; visibility = [string]$fm['visibility']; reason = 'distribution-build' }
        capability_profile = [ordered]@{ preferred = @($keptCaps); forbidden = @($keptForb) }
        provenance = [ordered]@{ trust = 'policy'; risk = 'policy'; capabilities = 'agent-frontmatter' }
        evidence = [ordered]@{ method = 'distribution-build' }
        domains = @($agentDomains)
        task_types = @($agentTaskTypes)
        classification = [ordered]@{ confidence = [string]$cls.confidence; source_kind = [string]$cls.source_kind; taxonomy_version = 2 }
    }
    $check = Test-CapabilityRecord -Record $rec
    $allErrors = @($check.Errors) + @($diagErrors)
    if ((-not $check.Valid) -or ($diagErrors.Count -gt 0)) {
        $rec['status'] = 'invalid'
        $invalidReport += [ordered]@{ id = $id; errors = @($allErrors) }
    }
    $normalized += $rec
}

$rawIds = @($normalized | ForEach-Object { [string]$_['id'] })
[Array]::Sort($rawIds, [System.StringComparer]::Ordinal)
$seenIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
$ids = @()
foreach ($candidate in $rawIds) {
    if ($seenIds.Add($candidate)) { $ids += $candidate }
}
$ordered = @()
foreach ($id in $ids) {
    foreach ($rec in $normalized) {
        if ([string]$rec['id'] -ceq $id) { $ordered += $rec }
    }
}
foreach ($rec in $ordered) {
    $t = [string]$rec['type']
    if ($counts.Contains($t)) { $counts[$t] = [int]$counts[$t] + 1 }
    if ([string]$rec['status'] -ceq 'invalid') { $counts['invalid'] = [int]$counts['invalid'] + 1 }
    $counts['total'] = [int]$counts['total'] + 1
}

$stamp = (Get-Date).ToUniversalTime().ToString('o')
$runtimeVersion = '1.0.0-distribution'
$runtimeObj = [ordered]@{ name = 'opencode'; version = $runtimeVersion; isolated_claude_skills = $false }
$freshnessStable = [ordered]@{ source_fingerprint = $sourceFingerprint; runtime_version = $runtimeVersion }
$hashCaps = @()
foreach ($rec in $ordered) {
    $hc = @{}
    foreach ($k in @($rec.Keys)) {
        if ("$k" -ceq 'evidence') { continue }
        $hc["$k"] = $rec[$k]
    }
    if ($rec.Contains('evidence') -and $null -ne $rec['evidence'] -and ($rec['evidence'] -is [System.Collections.IDictionary])) {
        $evCopy = @{}
        foreach ($ek in @($rec['evidence'].Keys)) {
            if ("$ek" -ceq 'captured_at') { continue }
            $evCopy["$ek"] = $rec['evidence'][$ek]
        }
        $hc['evidence'] = $evCopy
    }
    elseif ($rec.Contains('evidence') -and $null -ne $rec['evidence']) {
        $hc['evidence'] = $rec['evidence']
    }
    $hashCaps += $hc
}
$hashInput = [ordered]@{
    schema_version = 1
    runtime = $runtimeObj
    freshness = $freshnessStable
    capabilities = @($hashCaps)
}
$logicalHash = Get-LogicalHash -InputObject $hashInput

$envelope = [ordered]@{
    schema_version = 1
    registry = [ordered]@{
        generated_at = $stamp
        runtime = $runtimeObj
        freshness = [ordered]@{
            source_fingerprint = $sourceFingerprint
            runtime_version = $runtimeVersion
            computed_at = $stamp
            age_seconds = 0
        }
        logical_hash = $logicalHash
    }
    counts = $counts
    capabilities = @($ordered)
}

$payloadJson = ConvertTo-DeterministicJsonNode -Node $envelope

if ($invalidReport.Count -gt 0) {
    [Console]::Error.WriteLine(('INVALID records: ' + $invalidReport.Count))
    foreach ($item in $invalidReport) {
        [Console]::Error.WriteLine(('  [invalid] ' + [string]$item.id + ' :: ' + ((@($item.errors) | ForEach-Object { "$_" }) -join ' | ')))
    }
}

if (-not $Preview) {
    $target = $Out
    if ([string]::IsNullOrWhiteSpace($target)) { $target = $defaultOut }
    $parent = Split-Path -Parent $target
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($target, ($payloadJson + "`n"), [Text.UTF8Encoding]::new($false))
    if (-not $Json) {
        Write-Host ("Registry built: {0} capabilitie(s) ({1} invalid), logical_hash {2}" -f $counts['total'], $counts['invalid'], $logicalHash)
        Write-Host ("Wrote: " + $target)
    }
}
if ($Json -or $Preview) {
    Write-Output $payloadJson
}
exit 0
