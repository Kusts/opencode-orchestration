<#!
.SYNOPSIS
    V3 Skill utility + routing outcome telemetry lib (instrumentation ONLY)..DESCRIPTION
    Biblioteca dot-sourceable (sem execucao ao carregar). Telemetria local
    para responder "did the suggested skill actually help?" sem nunca
    habilitar roteamento, carregar skills ou mudar flags/autoridade:

      - Get-SkillUtilitySchemaFields: schema ordenado da skill-utility.
      - Get-RoutingOutcomeSchemaFields: schema ordenado do routing-outcome.
      - Test-SkillUtilitySecretLike + tokens seguros (V3-WS3-FIX):
        task_type/domain/agent/resultados passam por lowercase +
        `^[a-z][a-z0-9-]*$` + rejeicao de secret-like (substrings e
        prefixos sk|ghp|gho|ghs|akia|asia|aiza); secret-like e DESCARTADO
        (UNKNOWN/NOT_OBSERVED/registro nulo; nunca cru, nunca hash).
      - New-SkillUtilityObservation: normaliza UMA observacao de utilidade
        (TaskId, SkillId, Suggested, Accepted, Loaded, Used, Helpful,
        Unnecessary, UtilitySource). skill_id canonico `skill:<name>`
        (lowercase, [a-z0-9-]); invalido => $null (descartado, nada
        persistido). Flags => YES/NO/UNKNOWN/NOT_OBSERVED (default
        NOT_OBSERVED; invalido => UNKNOWN; aceita bool). Texto livre NUNCA
        e armazenado cru; task_id somente hash sha256:<16hex>.
      - Write-SkillUtilityObservation: append JSONL fail-closed em
        cache/v3/telemetry/skill-utility-YYYYMMDD.jsonl (confinado,
        reparse-aware; $false em qualquer recusa/falha; nunca lanca).
      - Read-SkillUtilityTelemetry + Get-SkillUtilitySummary: leitura e
        agregacao defensivas (nunca lancam).
      - New-RoutingOutcome + Write-RoutingOutcome: registros sanitizados
        per S18 (task_id, task_type, domain, router_candidate,
        router_selected_agent, actual_agent, classification_confidence,
        routing_reason, fallback_used, fallback_reason, task_success,
        validation_result, tester_result, reviewer_result, retry_count,
        debugger_invoked, architect_invoked, model_escalation_count,
        review_findings_count, security_findings_count,
        completion_status) em
        cache/v3/telemetry/outcomes-YYYYMMDD.jsonl. routing_reason e
        fallback_reason passam por redacao + token/hash (nunca texto cru);
        ausente => UNKNOWN/NOT_OBSERVED/0 conforme o campo.

    Reuso: quando CapabilityObservability.ps1 / CapabilitySanitize.ps1
    estao carregados no mesmo processo, delega para Get-Observability*
    (TaskIdHash, ReasonToken, RedactedText, Timestamp, ConfinedPath,
    PathHasReparsePoint) e Get-SecretValuePattern; caso contrario usa
    fallbacks locais equivalentes. Nunca lanca.

    PowerShell 5.1 compativel. ASCII-only de proposito.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-SkillUtilityRepoRoot {
    [CmdletBinding()]
    param([string]$RepoRoot)
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { return $RepoRoot }
    return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
}

function Get-SkillUtilitySchemaFields {
    [CmdletBinding()]
    param()
    return @('schema_version', 'event_type', 'ts', 'task_id_hash', 'skill_id', 'suggested', 'accepted', 'loaded', 'used', 'helpful', 'unnecessary', 'utility_source', 'warnings')
}

function Get-RoutingOutcomeSchemaFields {
    [CmdletBinding()]
    param()
    return @('schema_version', 'event_type', 'ts', 'task_id_hash', 'task_type', 'domain', 'secondary_domains', 'risk_class', 'route_mode', 'evidence_level', 'router_candidate', 'router_selected_agent', 'actual_agent', 'classification_confidence', 'routing_reason', 'fallback_used', 'fallback_reason', 'task_success', 'validation_result', 'tester_result', 'reviewer_result', 'retry_count', 'debugger_invoked', 'architect_invoked', 'model_escalation_count', 'review_findings_count', 'security_findings_count', 'completion_status', 'warnings')
}

function Get-SkillUtilityNodeProp {
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

function Get-SkillUtilitySecretPattern {
    [CmdletBinding()]
    param()
    try {
        $fn = Get-Command 'Get-SecretValuePattern' -ErrorAction SilentlyContinue
        if ($null -ne $fn) { return (Get-SecretValuePattern) }
    }
    catch { }
    return 'Bearer\s+[A-Za-z0-9\-._~+/=]{8,}|sk-[A-Za-z0-9]{10,}|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}'
}

function Get-SkillUtilityRedactedText {
    [CmdletBinding()]
    param([string]$Text)
    try {
        $fn = Get-Command 'Get-ObservabilityRedactedText' -ErrorAction SilentlyContinue
        if ($null -ne $fn) { return (Get-ObservabilityRedactedText -Text $Text) }
    }
    catch { }
    try {
        $s = [string]$Text
        if ([string]::IsNullOrEmpty($s)) { return '' }
        $pat = Get-SkillUtilitySecretPattern
        $s = ($s -replace $pat, '[REDACTED]')
        $s = $s.Trim()
        if ($s.Length -gt 500) { $s = $s.Substring(0, 500) }
        return $s
    }
    catch { return '' }
}

function Get-SkillUtilityTaskIdHash {
    [CmdletBinding()]
    param([string]$TaskId)
    try {
        $fn = Get-Command 'Get-ObservabilityTaskIdHash' -ErrorAction SilentlyContinue
        if ($null -ne $fn) { return (Get-ObservabilityTaskIdHash -TaskId $TaskId) }
    }
    catch { }
    try {
        $s = ([string]$TaskId).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return '' }
        if ($s -match '^sha256:[0-9a-f]{16}$') { return $s.ToLowerInvariant() }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($s)
            $hash = $sha.ComputeHash($bytes)
            $hex = (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
            return ('sha256:' + $hex.Substring(0, 16))
        }
        finally { try { $sha.Dispose() } catch { } }
    }
    catch { return '' }
}

function Get-SkillUtilityReasonToken {
    [CmdletBinding()]
    param([string]$Text)
    try {
        $fn = Get-Command 'Get-ObservabilityReasonToken' -ErrorAction SilentlyContinue
        if ($null -ne $fn) { return (Get-ObservabilityReasonToken -Text $Text) }
    }
    catch { }
    try {
        $s = ([string]$Text).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return '' }
        $low = $s.ToLowerInvariant()
        if ($low.Length -le 32 -and ($low -match '^[a-z][a-z0-9_-]{0,31}$')) { return $low }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($low)
            $hash = $sha.ComputeHash($bytes)
            $hex = (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
            return ('h:' + $hex.Substring(0, 16))
        }
        finally { try { $sha.Dispose() } catch { } }
    }
    catch { return '' }
}

function Get-SkillUtilityTimestamp {
    [CmdletBinding()]
    param([string]$Timestamp)
    try {
        $fn = Get-Command 'Get-ObservabilityTimestamp' -ErrorAction SilentlyContinue
        if ($null -ne $fn) { return (Get-ObservabilityTimestamp -Timestamp $Timestamp) }
    }
    catch { }
    try {
        $s = ([string]$Timestamp).Trim()
        if (-not [string]::IsNullOrWhiteSpace($s)) {
            $parsed = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse($s, [ref]$parsed)) {
                return ($parsed.ToUniversalTime().ToString('o'))
            }
        }
    }
    catch { }
    try { return ([DateTimeOffset]::UtcNow.ToString('o')) }
    catch { return '1970-01-01T00:00:00.0000000+00:00' }
}

function Test-SkillUtilityConfinedPath {
    [CmdletBinding()]
    param([string]$Path, [string]$AllowedDir, [string]$RepoRoot)
    try {
        $fn = Get-Command 'Test-ObservabilityConfinedPath' -ErrorAction SilentlyContinue
        if ($null -ne $fn) { return (Test-ObservabilityConfinedPath -Path $Path -AllowedDir $AllowedDir -RepoRoot $RepoRoot) }
    }
    catch { }
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

function Test-SkillUtilityConfinedInside {
    [CmdletBinding()]
    param([string]$Path, [string]$AllowedDir, [string]$RepoRoot)
    try {
        $fn = Get-Command 'Test-ObservabilityConfinedInside' -ErrorAction SilentlyContinue
        if ($null -ne $fn) { return (Test-ObservabilityConfinedInside -Path $Path -AllowedDir $AllowedDir -RepoRoot $RepoRoot) }
    }
    catch { }
    try {
        $full = ''
        if ([IO.Path]::IsPathRooted($Path)) { $full = [IO.Path]::GetFullPath($Path) }
        else { $full = [IO.Path]::GetFullPath((Join-Path $RepoRoot $Path)) }
        $base = [IO.Path]::GetFullPath($AllowedDir)
        if ($full.Equals($base, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        $sep = $base.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if ($full.StartsWith($sep, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    catch { }
    return $false
}

function Test-SkillUtilityPathHasReparsePoint {
    [CmdletBinding()]
    param([string]$Path)
    try {
        $fn = Get-Command 'Test-ObservabilityPathHasReparsePoint' -ErrorAction SilentlyContinue
        if ($null -ne $fn) { return (Test-ObservabilityPathHasReparsePoint -Path $Path) }
    }
    catch { }
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

function Get-SkillUtilityFullPath {
    [CmdletBinding()]
    param([string]$Path, [string]$RepoRoot)
    try {
        if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
        return [IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
    }
    catch { return $Path }
}

function Test-SkillUtilitySecretLike {
    <#
    .SYNOPSIS
        Detecta valor com cara de segredo (V3-WS3-FIX, MEDIUM).
        Casa case-insensitive substrings secret|password|passwd|
        passphrase|apikey|api[-_]?key|token|credential|bearer|jwt|
        private|access[-_]?key|client[-_]?secret OU prefixos
        ^(sk|ghp|gho|ghs|akia|asia|aiza)[0-9a-z_-]*$.
        Achou => $true (chamador DESCARTA, nunca persiste nem hasheia).
        Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$Text)
    try {
        $s = ([string]$Text).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($s)) { return $false }
        if ($s -match 'secret|password|passwd|passphrase|apikey|api[-_]?key|token|credential|bearer|jwt|private|access[-_]?key|client[-_]?secret') { return $true }
        if ($s -match '^(sk|ghp|gho|ghs|akia|asia|aiza)[0-9a-z_-]*$') { return $true }
        return $false
    }
    catch { return $false }
}

function Get-SkillUtilitySkillId {
    <#
    .SYNOPSIS
        Canoniza skill_id para `skill:<name>` (lowercase, [a-z0-9-]).
        Com cara de segredo ou invalido => '' (descartado). Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$SkillId)
    try {
        $s = ([string]$SkillId).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($s)) { return '' }
        if ($s.StartsWith('skill:')) { $s = $s.Substring(6) }
        elseif ($s.Contains(':')) { return '' }
        if ($s.Length -lt 1 -or $s.Length -gt 48) { return '' }
        if ($s -notmatch '^[a-z0-9][a-z0-9-]{0,47}$') { return '' }
        if (Test-SkillUtilitySecretLike -Text $s) { return '' }
        return ('skill:' + $s)
    }
    catch { return '' }
}

function Get-SkillUtilityFlag {
    <#
    .SYNOPSIS
        Normaliza flag de utilidade para YES/NO/UNKNOWN/NOT_OBSERVED.
        Default NOT_OBSERVED; invalido => UNKNOWN. Aceita bool/int/string.
        Nunca lanca.
    #>
    [CmdletBinding()]
    param($Value)
    try {
        if ($null -eq $Value) { return 'NOT_OBSERVED' }
        if ($Value -is [bool]) {
            if ($Value -eq $true) { return 'YES' }
            return 'NO'
        }
        if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) {
            $n = 0
            try { $n = [int]$Value } catch { return 'UNKNOWN' }
            if ($n -eq 1) { return 'YES' }
            if ($n -eq 0) { return 'NO' }
            return 'UNKNOWN'
        }
        $s = ([string]$Value).Trim().ToUpperInvariant() -replace '-', '_'
        $s = ($s -replace '\s+', '_')
        if ([string]::IsNullOrWhiteSpace($s)) { return 'NOT_OBSERVED' }
        if ($s -ceq 'YES' -or $s -ceq 'TRUE' -or $s -ceq 'Y' -or $s -ceq '1') { return 'YES' }
        if ($s -ceq 'NO' -or $s -ceq 'FALSE' -or $s -ceq 'N' -or $s -ceq '0') { return 'NO' }
        if ($s -ceq 'UNKNOWN') { return 'UNKNOWN' }
        if ($s -ceq 'NOT_OBSERVED') { return 'NOT_OBSERVED' }
        return 'UNKNOWN'
    }
    catch { return 'UNKNOWN' }
}

function Get-SkillUtilitySource {
    <#
    .SYNOPSIS
        Normaliza utility_source para enum fechado; vazio => NOT_OBSERVED,
        invalido => UNKNOWN. Nunca lanca, nunca preserva texto livre.
    #>
    [CmdletBinding()]
    param($Value)
    try {
        if ($null -eq $Value) { return 'NOT_OBSERVED' }
        $s = ([string]$Value).Trim().ToUpperInvariant() -replace '-', '_'
        $s = ($s -replace '\s+', '_')
        if ([string]::IsNullOrWhiteSpace($s)) { return 'NOT_OBSERVED' }
        $allowed = @('SELF_REPORT', 'WORKER', 'PLANNER', 'REVIEWER', 'TESTER', 'EXPLICIT', 'INFERRED', 'MANUAL', 'UNKNOWN', 'NOT_OBSERVED')
        if ($allowed -ccontains $s) { return $s }
        return 'UNKNOWN'
    }
    catch { return 'UNKNOWN' }
}

function Get-SkillUtilityIdToken {
    <#
    .SYNOPSIS
        Token seguro de identidade (task_type/domain/agent): lowercase,
        `^[a-z][a-z0-9-]{0,63}$`, sem cara de segredo; senao UNKNOWN.
        Valores secret-like sao DESCARTADOS (nunca crus, nunca hash).
    #>
    [CmdletBinding()]
    param([string]$Text)
    try {
        $s = ([string]$Text).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return 'UNKNOWN' }
        if ($s -ceq 'UNKNOWN') { return 'UNKNOWN' }
        $s = $s.ToLowerInvariant()
        if ($s.Length -gt 64) { return 'UNKNOWN' }
        if (Test-SkillUtilitySecretLike -Text $s) { return 'UNKNOWN' }
        if ($s -match '^[a-z][a-z0-9-]{0,63}$') { return $s }
        return 'UNKNOWN'
    }
    catch { return 'UNKNOWN' }
}

function Get-SkillUtilityResultToken {
    <#
    .SYNOPSIS
        Token de resultado (validation/tester/reviewer): minusculo ou
        NOT_OBSERVED (ausente) / UNKNOWN (invalido ou secret-like).
        Nunca texto cru.
    #>
    [CmdletBinding()]
    param([string]$Text)
    try {
        $s = ([string]$Text).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return 'NOT_OBSERVED' }
        if ($s -ceq 'NOT_OBSERVED') { return 'NOT_OBSERVED' }
        if ($s -ceq 'UNKNOWN') { return 'UNKNOWN' }
        $low = $s.ToLowerInvariant()
        if ($low.Length -gt 32) { return 'UNKNOWN' }
        if (Test-SkillUtilitySecretLike -Text $low) { return 'UNKNOWN' }
        if ($low -match '^[a-z][a-z0-9_-]{0,31}$') { return $low }
        return 'UNKNOWN'
    }
    catch { return 'UNKNOWN' }
}

function Get-SkillUtilityConfidence {
    [CmdletBinding()]
    param([string]$Text)
    try {
        $s = ([string]$Text).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($s)) { return 'UNKNOWN' }
        if ($s -ceq 'high' -or $s -ceq 'medium' -or $s -ceq 'low') { return $s }
        return 'UNKNOWN'
    }
    catch { return 'UNKNOWN' }
}

function Get-SkillUtilityBool {
    [CmdletBinding()]
    param($Value)
    try {
        if ($null -eq $Value) { return $false }
        if ($Value -is [bool]) { return ([bool]$Value) }
        $s = ([string]$Value).Trim().ToLowerInvariant()
        if ($s -ceq 'true' -or $s -ceq '1' -or $s -ceq 'yes') { return $true }
        return $false
    }
    catch { return $false }
}

function Get-SkillUtilityCount {
    [CmdletBinding()]
    param($Value)
    try {
        if ($null -eq $Value) { return 0 }
        $n = 0
        try { $n = [int]([string]$Value).Trim() } catch { try { $n = [int]$Value } catch { return 0 } }
        if ($n -lt 0) { return 0 }
        if ($n -gt 99) { return 99 }
        return $n
    }
    catch { return 0 }
}

function Get-SkillUtilityRouteMode {
    <#
    .SYNOPSIS
        Normaliza route_mode para enum fechado (lifecycle do Agent Routing).
        Ausente => NOT_OBSERVED; invalido => UNKNOWN. Nunca texto livre.
    #>
    [CmdletBinding()]
    param($Value)
    try {
        if ($null -eq $Value) { return 'NOT_OBSERVED' }
        $s = ([string]$Value).Trim().ToUpperInvariant() -replace '-', '_'
        if ([string]::IsNullOrWhiteSpace($s)) { return 'NOT_OBSERVED' }
        $allowed = @('DIRECT', 'ROUTER', 'FALLBACK', 'DETERMINISTIC', 'NOT_OBSERVED', 'UNKNOWN')
        if ($allowed -ccontains $s) { return $s }
        return 'UNKNOWN'
    }
    catch { return 'UNKNOWN' }
}

function Get-SkillUtilityRiskClass {
    <#
    .SYNOPSIS
        Normaliza risk_class para enum fechado. Ausente => UNKNOWN.
    #>
    [CmdletBinding()]
    param($Value)
    try {
        $s = ([string]$Value).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($s)) { return 'UNKNOWN' }
        $allowed = @('low', 'medium', 'high', 'critical')
        if ($allowed -ccontains $s) { return $s }
        return 'UNKNOWN'
    }
    catch { return 'UNKNOWN' }
}

function Get-SkillUtilityEvidenceLevel {
    <#
    .SYNOPSIS
        Nivel de evidencia do outcome. CONTROLLED_ROUTING = decisao real de
        roteamento sem execucao completa; EXECUTED = subtarefa executada e
        validada. Ausente => NOT_OBSERVED; invalido => UNKNOWN.
    #>
    [CmdletBinding()]
    param($Value)
    try {
        if ($null -eq $Value) { return 'NOT_OBSERVED' }
        $s = ([string]$Value).Trim().ToUpperInvariant() -replace '-', '_'
        if ([string]::IsNullOrWhiteSpace($s)) { return 'NOT_OBSERVED' }
        $allowed = @('CONTROLLED_ROUTING', 'EXECUTED', 'NOT_OBSERVED', 'UNKNOWN')
        if ($allowed -ccontains $s) { return $s }
        return 'UNKNOWN'
    }
    catch { return 'UNKNOWN' }
}

function Get-SkillUtilityTokenList {
    <#
    .SYNOPSIS
        Lista de tokens seguros (dominios secundarios), dedup ordinal,
        secret-like descartado. Nunca lanca.
    #>
    [CmdletBinding()]
    param($Value)
    $out = @()
    try {
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($v in @($Value)) {
            if ($null -eq $v) { continue }
            $t = Get-SkillUtilityIdToken -Text ([string]$v)
            if ($t -ceq 'UNKNOWN') { continue }
            if ($seen.Add($t)) { $out += $t }
        }
    }
    catch { $out = @() }
    return @($out)
}

function New-SkillUtilityObservation {
    <#
    .SYNOPSIS
        Constroi UMA observacao sanitizada de utilidade de skill.
        skill_id invalido => $null (nada persistido). Nunca lanca.
    #>
    [CmdletBinding()]
    param(
        [string]$TaskId = '',
        [string]$SkillId = '',
        $Suggested = 'NOT_OBSERVED',
        $Accepted = 'NOT_OBSERVED',
        $Loaded = 'NOT_OBSERVED',
        $Used = 'NOT_OBSERVED',
        $Helpful = 'NOT_OBSERVED',
        $Unnecessary = 'NOT_OBSERVED',
        $UtilitySource = 'NOT_OBSERVED',
        [string]$Timestamp = ''
    )
    try {
        $canon = Get-SkillUtilitySkillId -SkillId $SkillId
        if ([string]::IsNullOrWhiteSpace($canon)) { return $null }
        $warnings = New-Object System.Collections.Generic.List[string]
        $taskHash = ''
        try { $taskHash = Get-SkillUtilityTaskIdHash -TaskId $TaskId } catch { $taskHash = '' }
        $src = Get-SkillUtilitySource -Value $UtilitySource
        $fSuggested = Get-SkillUtilityFlag -Value $Suggested
        $fAccepted = Get-SkillUtilityFlag -Value $Accepted
        $fLoaded = Get-SkillUtilityFlag -Value $Loaded
        $fUsed = Get-SkillUtilityFlag -Value $Used
        $fHelpful = Get-SkillUtilityFlag -Value $Helpful
        $fUnnecessary = Get-SkillUtilityFlag -Value $Unnecessary
        # Anti-fabricacao: 'used'/'helpful' exigem uma fonte de evidencia real.
        # 'helpful' e mais estrito: somente REVIEWER/TESTER/EXPLICIT (avaliacao
        # independente explicita). INFERRED/UNKNOWN/NOT_OBSERVED nunca promovem
        # uso ou utilidade (nunca 'loaded => helpful'); o sinal rebaixa para
        # UNKNOWN com warning.
        $weakSources = @('INFERRED', 'UNKNOWN', 'NOT_OBSERVED')
        $helpfulSources = @('REVIEWER', 'TESTER', 'EXPLICIT')
        if (($fUsed -ceq 'YES') -and ($weakSources -ccontains $src)) {
            $fUsed = 'UNKNOWN'
            $warnings.Add('used_without_evidence_source') | Out-Null
        }
        if (($fHelpful -ceq 'YES') -and ($helpfulSources -cnotcontains $src)) {
            $fHelpful = 'UNKNOWN'
            $warnings.Add('helpful_without_evidence_source') | Out-Null
        }
        return [PSCustomObject]@{
            schema_version = 1
            event_type     = 'skill-utility'
            ts             = (Get-SkillUtilityTimestamp -Timestamp $Timestamp)
            task_id_hash   = [string]$taskHash
            skill_id       = [string]$canon
            suggested      = $fSuggested
            accepted       = $fAccepted
            loaded         = $fLoaded
            used           = $fUsed
            helpful        = $fHelpful
            unnecessary    = $fUnnecessary
            utility_source = $src
            warnings       = ([string[]]$warnings.ToArray())
        }
    }
    catch { return $null }
}

function Get-SkillUtilityDefaultTelemetryPath {
    [CmdletBinding()]
    param([string]$RepoRoot)
    try {
        $repo = Get-SkillUtilityRepoRoot -RepoRoot $RepoRoot
        $stamp = ([DateTimeOffset]::UtcNow.ToString('yyyyMMdd'))
        return (Join-Path $repo ('cache\v3\telemetry\skill-utility-' + $stamp + '.jsonl'))
    }
    catch { return '' }
}

function Get-RoutingOutcomeDefaultTelemetryPath {
    [CmdletBinding()]
    param([string]$RepoRoot)
    try {
        $repo = Get-SkillUtilityRepoRoot -RepoRoot $RepoRoot
        $stamp = ([DateTimeOffset]::UtcNow.ToString('yyyyMMdd'))
        return (Join-Path $repo ('cache\v3\telemetry\outcomes-' + $stamp + '.jsonl'))
    }
    catch { return '' }
}

function Write-SkillUtilityJsonlLine {
    [CmdletBinding()]
    param($Doc, [string]$TelemetryPath, [string]$RepoRoot)
    try {
        $repo = Get-SkillUtilityRepoRoot -RepoRoot $RepoRoot
        $target = $TelemetryPath
        if ([string]::IsNullOrWhiteSpace($target)) { return $false }
        $allowedDir = Join-Path $repo 'cache\v3\telemetry'
        if (-not (Test-SkillUtilityConfinedPath -Path $target -AllowedDir $allowedDir -RepoRoot $repo)) { return $false }
        if (Test-SkillUtilityPathHasReparsePoint -Path (Get-SkillUtilityFullPath -Path $target -RepoRoot $repo)) { return $false }
        $full = Get-SkillUtilityFullPath -Path $target -RepoRoot $repo
        try {
            if ((Test-Path -LiteralPath $full) -and -not (Test-Path -LiteralPath $full -PathType Leaf)) { return $false }
        }
        catch { return $false }
        $text = ''
        try { $text = ($Doc | ConvertTo-Json -Depth 10 -Compress) }
        catch { return $false }
        if ([string]::IsNullOrWhiteSpace($text)) { return $false }
        $text = ($text -replace "`r`n", "" -replace "`r", "" -replace "`n", "")
        try {
            $parent = Split-Path -Parent $full
            if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        }
        catch { return $false }
        try {
            [IO.File]::AppendAllText($full, ($text + "`n"), [Text.UTF8Encoding]::new($false))
            return $true
        }
        catch { return $false }
    }
    catch { return $false }
}

function Write-SkillUtilityObservation {
    <#
    .SYNOPSIS
        Anexa UMA observacao sanitizada ao JSONL skill-utility (fail-closed).
        Retorna $true ao anexar, $false em qualquer recusa/falha. Nunca lanca.
    #>
    [CmdletBinding()]
    param($Observation = $null, [string]$TelemetryPath = '', [string]$RepoRoot = '')
    try {
        if ($null -eq $Observation) { return $false }
        $repo = Get-SkillUtilityRepoRoot -RepoRoot $RepoRoot
        $target = $TelemetryPath
        if ([string]::IsNullOrWhiteSpace($target)) {
            $target = Get-SkillUtilityDefaultTelemetryPath -RepoRoot $repo
        }
        if ([string]::IsNullOrWhiteSpace($target)) { return $false }
        $norm = $null
        try {
            $norm = (New-SkillUtilityObservation `
                -TaskId ([string](Get-SkillUtilityNodeProp -Node $Observation -Name 'task_id')) `
                -SkillId ([string](Get-SkillUtilityNodeProp -Node $Observation -Name 'skill_id')) `
                -Suggested (Get-SkillUtilityNodeProp -Node $Observation -Name 'suggested') `
                -Accepted (Get-SkillUtilityNodeProp -Node $Observation -Name 'accepted') `
                -Loaded (Get-SkillUtilityNodeProp -Node $Observation -Name 'loaded') `
                -Used (Get-SkillUtilityNodeProp -Node $Observation -Name 'used') `
                -Helpful (Get-SkillUtilityNodeProp -Node $Observation -Name 'helpful') `
                -Unnecessary (Get-SkillUtilityNodeProp -Node $Observation -Name 'unnecessary') `
                -UtilitySource (Get-SkillUtilityNodeProp -Node $Observation -Name 'utility_source') `
                -Timestamp ([string](Get-SkillUtilityNodeProp -Node $Observation -Name 'ts')))
            if ($null -eq $norm) {
                $tsAlt = [string](Get-SkillUtilityNodeProp -Node $Observation -Name 'timestamp')
                if (-not [string]::IsNullOrWhiteSpace($tsAlt)) {
                    $norm = (New-SkillUtilityObservation `
                        -TaskId ([string](Get-SkillUtilityNodeProp -Node $Observation -Name 'task_id')) `
                        -SkillId ([string](Get-SkillUtilityNodeProp -Node $Observation -Name 'skill_id')) `
                        -Suggested (Get-SkillUtilityNodeProp -Node $Observation -Name 'suggested') `
                        -Accepted (Get-SkillUtilityNodeProp -Node $Observation -Name 'accepted') `
                        -Loaded (Get-SkillUtilityNodeProp -Node $Observation -Name 'loaded') `
                        -Used (Get-SkillUtilityNodeProp -Node $Observation -Name 'used') `
                        -Helpful (Get-SkillUtilityNodeProp -Node $Observation -Name 'helpful') `
                        -Unnecessary (Get-SkillUtilityNodeProp -Node $Observation -Name 'unnecessary') `
                        -UtilitySource (Get-SkillUtilityNodeProp -Node $Observation -Name 'utility_source') `
                        -Timestamp $tsAlt)
                }
            }
        }
        catch { $norm = $null }
        if ($null -eq $norm) { return $false }
        if ([string]::IsNullOrWhiteSpace($norm.task_id_hash)) {
            try {
                $pre = [string](Get-SkillUtilityNodeProp -Node $Observation -Name 'task_id_hash')
                if ($pre -match '^sha256:[0-9a-f]{16}$') { $norm.task_id_hash = $pre.ToLowerInvariant() }
            }
            catch { }
        }
        $doc = [ordered]@{
            schema_version = [int]$norm.schema_version
            event_type     = [string]$norm.event_type
            ts             = [string]$norm.ts
            task_id_hash   = [string]$norm.task_id_hash
            skill_id       = [string]$norm.skill_id
            suggested      = [string]$norm.suggested
            accepted       = [string]$norm.accepted
            loaded         = [string]$norm.loaded
            used           = [string]$norm.used
            helpful        = [string]$norm.helpful
            unnecessary    = [string]$norm.unnecessary
            utility_source = [string]$norm.utility_source
            warnings       = ([string[]]@($norm.warnings))
        }
        return (Write-SkillUtilityJsonlLine -Doc $doc -TelemetryPath $target -RepoRoot $repo)
    }
    catch { return $false }
}

function Read-SkillUtilityTelemetry {
    <#
    .SYNOPSIS
        Le linhas skill-utility de *.jsonl (defensivo; nunca lanca).
        Leitura nao e confinada (como telemetry-report.ps1): qualquer
        diretorio existente pode ser lido; a escrita continua confinada.
    #>
    [CmdletBinding()]
    param([string]$TelemetryDir = '', [string]$RepoRoot = '')
    $out = [PSCustomObject]@{ Records = @(); FilesSeen = 0; Parsed = 0; Skipped = 0; Error = '' }
    try {
        $repo = Get-SkillUtilityRepoRoot -RepoRoot $RepoRoot
        $allowedDir = Join-Path $repo 'cache\v3\telemetry'
        $dir = $TelemetryDir
        if ([string]::IsNullOrWhiteSpace($dir)) { $dir = $allowedDir }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { $out.Error = 'not-found'; return $out }
        $files = @()
        try { $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.jsonl' -File -Force -ErrorAction Stop | Sort-Object Name) }
        catch { $out.Error = 'list'; return $out }
        $recs = @()
        foreach ($f in $files) {
            $out.FilesSeen++
            $lines = @()
            try { $lines = [IO.File]::ReadAllLines($f.FullName, [Text.UTF8Encoding]::new($false)) }
            catch { continue }
            foreach ($raw in $lines) {
                $t = ([string]$raw).Trim()
                if ([string]::IsNullOrWhiteSpace($t)) { continue }
                $o = $null
                try { $o = ($t | ConvertFrom-Json) } catch { $out.Skipped++; continue }
                try {
                    $et = ([string](Get-SkillUtilityNodeProp -Node $o -Name 'event_type')).Trim().ToLowerInvariant()
                    if ($et -cne 'skill-utility') { continue }
                }
                catch { continue }
                $out.Parsed++
                $recs += $o
            }
        }
        $out.Records = $recs
        return $out
    }
    catch { return $out }
}

function Get-SkillUtilitySummary {
    <#
    .SYNOPSIS
        Agrega por skill: contagens YES por flag, UNKNOWN explicito e
        NOT_OBSERVED separados, estados de pipeline (accepted/loaded/used) e
        distribuicao de utility_source. Ordenado por skill. Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$TelemetryDir = '', [string]$RepoRoot = '')
    try {
        $read = Read-SkillUtilityTelemetry -TelemetryDir $TelemetryDir -RepoRoot $RepoRoot
        $agg = @{}
        foreach ($r in @($read.Records)) {
            try {
                $rawSk = ([string](Get-SkillUtilityNodeProp -Node $r -Name 'skill_id')).Trim()
                $sk = Get-SkillUtilitySkillId -SkillId $rawSk
                if ([string]::IsNullOrWhiteSpace($sk)) { continue }
                if (-not $agg.ContainsKey($sk)) {
                    $agg[$sk] = [ordered]@{
                        skill = $sk; suggested = 0; accepted = 0; loaded = 0
                        used = 0; helpful = 0; unnecessary = 0
                        unknown = 0; not_observed = 0
                        accepted_but_not_loaded = 0; loaded_but_not_used = 0
                        used_but_not_helpful = 0
                        utility_sources = [ordered]@{}
                    }
                }
                $flags = @{}
                foreach ($f in @('suggested', 'accepted', 'loaded', 'used', 'helpful', 'unnecessary')) {
                    $v = ([string](Get-SkillUtilityNodeProp -Node $r -Name $f)).Trim().ToUpperInvariant()
                    $state = 'unknown'
                    if ($v -ceq 'YES') { $state = 'yes' }
                    elseif ($v -ceq 'NO') { $state = 'no' }
                    elseif ($v -ceq 'NOT_OBSERVED') { $state = 'not_observed' }
                    $flags[$f] = $state
                    if ($state -ceq 'yes') { $agg[$sk][$f] = ([int]$agg[$sk][$f] + 1) }
                    elseif ($state -ceq 'not_observed') { $agg[$sk]['not_observed'] = ([int]$agg[$sk]['not_observed'] + 1) }
                    elseif ($state -ceq 'unknown') { $agg[$sk]['unknown'] = ([int]$agg[$sk]['unknown'] + 1) }
                }
                if (($flags['accepted'] -ceq 'yes') -and ($flags['loaded'] -cne 'yes')) { $agg[$sk]['accepted_but_not_loaded'] = ([int]$agg[$sk]['accepted_but_not_loaded'] + 1) }
                if (($flags['loaded'] -ceq 'yes') -and ($flags['used'] -cne 'yes')) { $agg[$sk]['loaded_but_not_used'] = ([int]$agg[$sk]['loaded_but_not_used'] + 1) }
                if (($flags['used'] -ceq 'yes') -and ($flags['helpful'] -cne 'yes')) { $agg[$sk]['used_but_not_helpful'] = ([int]$agg[$sk]['used_but_not_helpful'] + 1) }
                $src = Get-SkillUtilitySource -Value (Get-SkillUtilityNodeProp -Node $r -Name 'utility_source')
                if (-not $agg[$sk]['utility_sources'].Contains($src)) { $agg[$sk]['utility_sources'][$src] = 0 }
                $agg[$sk]['utility_sources'][$src] = ([int]$agg[$sk]['utility_sources'][$src] + 1)
            }
            catch { }
        }
        $rows = @()
        foreach ($k in @($agg.Keys | Sort-Object)) {
            $rows += ([PSCustomObject]$agg[$k])
        }
        return $rows
    }
    catch { return @() }
}

function New-RoutingOutcome {
    <#
    .SYNOPSIS
        Constroi UM registro sanitizado de routing outcome (S18).
        Texto livre (reasons) vira token/hash apos redacao; nunca cru.
        Ausente => UNKNOWN/NOT_OBSERVED/0 conforme o campo. Nunca lanca.
    #>
    [CmdletBinding()]
    param(
        [string]$TaskId = '',
        [string]$TaskType = '',
        [string]$Domain = '',
        $SecondaryDomains = $null,
        [string]$RiskClass = '',
        [string]$RouteMode = '',
        [string]$EvidenceLevel = '',
        [string]$RouterCandidate = '',
        [string]$RouterSelectedAgent = '',
        [string]$ActualAgent = '',
        [string]$ClassificationConfidence = '',
        [string]$RoutingReason = '',
        $FallbackUsed = $false,
        [string]$FallbackReason = '',
        $TaskSuccess = $false,
        [string]$ValidationResult = '',
        [string]$TesterResult = '',
        [string]$ReviewerResult = '',
        $RetryCount = 0,
        $DebuggerInvoked = $false,
        $ArchitectInvoked = $false,
        $ModelEscalationCount = 0,
        $ReviewFindingsCount = 0,
        $SecurityFindingsCount = 0,
        [string]$CompletionStatus = '',
        [string]$Timestamp = ''
    )
    try {
        $warnings = New-Object System.Collections.Generic.List[string]
        $taskHash = ''
        try { $taskHash = Get-SkillUtilityTaskIdHash -TaskId $TaskId } catch { $taskHash = '' }
        $reasonClean = 'NOT_OBSERVED'
        try {
            $rr = ([string]$RoutingReason).Trim()
            if (-not [string]::IsNullOrWhiteSpace($rr)) {
                if ($rr -ceq 'NOT_OBSERVED') { $reasonClean = 'NOT_OBSERVED' }
                elseif ($rr -ceq 'UNKNOWN') { $reasonClean = 'UNKNOWN' }
                elseif (Test-SkillUtilitySecretLike -Text $rr) { $reasonClean = 'UNKNOWN' }
                else {
                    $red = Get-SkillUtilityRedactedText -Text $rr
                    $tok = Get-SkillUtilityReasonToken -Text $red
                    if ([string]::IsNullOrWhiteSpace($tok)) { $reasonClean = 'UNKNOWN' }
                    else { $reasonClean = $tok }
                }
            }
        }
        catch { $reasonClean = 'UNKNOWN' }
        $fbReasonClean = 'NOT_OBSERVED'
        try {
            $fr = ([string]$FallbackReason).Trim()
            if (-not [string]::IsNullOrWhiteSpace($fr)) {
                if ($fr -ceq 'NOT_OBSERVED') { $fbReasonClean = 'NOT_OBSERVED' }
                elseif ($fr -ceq 'UNKNOWN') { $fbReasonClean = 'UNKNOWN' }
                elseif (Test-SkillUtilitySecretLike -Text $fr) { $fbReasonClean = 'UNKNOWN' }
                else {
                    $red = Get-SkillUtilityRedactedText -Text $fr
                    $tok = Get-SkillUtilityReasonToken -Text $red
                    if ([string]::IsNullOrWhiteSpace($tok)) { $fbReasonClean = 'UNKNOWN' }
                    else { $fbReasonClean = $tok }
                }
            }
        }
        catch { $fbReasonClean = 'UNKNOWN' }
        $completionClean = 'UNKNOWN'
        try {
            $cs = ([string]$CompletionStatus).Trim()
            if (-not [string]::IsNullOrWhiteSpace($cs)) {
                $completionClean = Get-SkillUtilityResultToken -Text $cs
                if ($completionClean -ceq 'NOT_OBSERVED') { $completionClean = 'UNKNOWN' }
            }
        }
        catch { $completionClean = 'UNKNOWN' }
        return [PSCustomObject]@{
            schema_version            = 1
            event_type                = 'routing-outcome'
            ts                        = (Get-SkillUtilityTimestamp -Timestamp $Timestamp)
            task_id_hash              = [string]$taskHash
            task_type                 = (Get-SkillUtilityIdToken -Text $TaskType)
            domain                    = (Get-SkillUtilityIdToken -Text $Domain)
            secondary_domains         = (Get-SkillUtilityTokenList -Value $SecondaryDomains)
            risk_class                = (Get-SkillUtilityRiskClass -Value $RiskClass)
            route_mode                = (Get-SkillUtilityRouteMode -Value $RouteMode)
            evidence_level            = (Get-SkillUtilityEvidenceLevel -Value $EvidenceLevel)
            router_candidate          = (Get-SkillUtilityIdToken -Text $RouterCandidate)
            router_selected_agent     = (Get-SkillUtilityIdToken -Text $RouterSelectedAgent)
            actual_agent              = (Get-SkillUtilityIdToken -Text $ActualAgent)
            classification_confidence = (Get-SkillUtilityConfidence -Text $ClassificationConfidence)
            routing_reason            = [string]$reasonClean
            fallback_used             = (Get-SkillUtilityBool -Value $FallbackUsed)
            fallback_reason           = [string]$fbReasonClean
            task_success              = (Get-SkillUtilityBool -Value $TaskSuccess)
            validation_result         = (Get-SkillUtilityResultToken -Text $ValidationResult)
            tester_result             = (Get-SkillUtilityResultToken -Text $TesterResult)
            reviewer_result           = (Get-SkillUtilityResultToken -Text $ReviewerResult)
            retry_count               = (Get-SkillUtilityCount -Value $RetryCount)
            debugger_invoked          = (Get-SkillUtilityBool -Value $DebuggerInvoked)
            architect_invoked         = (Get-SkillUtilityBool -Value $ArchitectInvoked)
            model_escalation_count    = (Get-SkillUtilityCount -Value $ModelEscalationCount)
            review_findings_count     = (Get-SkillUtilityCount -Value $ReviewFindingsCount)
            security_findings_count   = (Get-SkillUtilityCount -Value $SecurityFindingsCount)
            completion_status         = [string]$completionClean
            warnings                  = ([string[]]$warnings.ToArray())
        }
    }
    catch { return $null }
}

function Write-RoutingOutcome {
    <#
    .SYNOPSIS
        Anexa UM routing outcome sanitizado ao JSONL outcomes (fail-closed).
        Retorna $true ao anexar, $false em qualquer recusa/falha. Nunca lanca.
    #>
    [CmdletBinding()]
    param($Outcome = $null, [string]$TelemetryPath = '', [string]$RepoRoot = '')
    try {
        if ($null -eq $Outcome) { return $false }
        $repo = Get-SkillUtilityRepoRoot -RepoRoot $RepoRoot
        $target = $TelemetryPath
        if ([string]::IsNullOrWhiteSpace($target)) {
            $target = Get-RoutingOutcomeDefaultTelemetryPath -RepoRoot $repo
        }
        if ([string]::IsNullOrWhiteSpace($target)) { return $false }
        $norm = $null
        try {
            $norm = (New-RoutingOutcome `
                -TaskId ([string](Get-SkillUtilityNodeProp -Node $Outcome -Name 'task_id')) `
                -TaskType ([string](Get-SkillUtilityNodeProp -Node $Outcome -Name 'task_type')) `
                -Domain ([string](Get-SkillUtilityNodeProp -Node $Outcome -Name 'domain')) `
                -SecondaryDomains (Get-SkillUtilityNodeProp -Node $Outcome -Name 'secondary_domains') `
                -RiskClass ([string](Get-SkillUtilityNodeProp -Node $Outcome -Name 'risk_class')) `
                -RouteMode ([string](Get-SkillUtilityNodeProp -Node $Outcome -Name 'route_mode')) `
                -EvidenceLevel ([string](Get-SkillUtilityNodeProp -Node $Outcome -Name 'evidence_level')) `
                -RouterCandidate ([string](Get-SkillUtilityNodeProp -Node $Outcome -Name 'router_candidate')) `
                -RouterSelectedAgent ([string](Get-SkillUtilityNodeProp -Node $Outcome -Name 'router_selected_agent')) `
                -ActualAgent ([string](Get-SkillUtilityNodeProp -Node $Outcome -Name 'actual_agent')) `
                -ClassificationConfidence ([string](Get-SkillUtilityNodeProp -Node $Outcome -Name 'classification_confidence')) `
                -RoutingReason ([string](Get-SkillUtilityNodeProp -Node $Outcome -Name 'routing_reason')) `
                -FallbackUsed (Get-SkillUtilityNodeProp -Node $Outcome -Name 'fallback_used') `
                -FallbackReason ([string](Get-SkillUtilityNodeProp -Node $Outcome -Name 'fallback_reason')) `
                -TaskSuccess (Get-SkillUtilityNodeProp -Node $Outcome -Name 'task_success') `
                -ValidationResult ([string](Get-SkillUtilityNodeProp -Node $Outcome -Name 'validation_result')) `
                -TesterResult ([string](Get-SkillUtilityNodeProp -Node $Outcome -Name 'tester_result')) `
                -ReviewerResult ([string](Get-SkillUtilityNodeProp -Node $Outcome -Name 'reviewer_result')) `
                -RetryCount (Get-SkillUtilityNodeProp -Node $Outcome -Name 'retry_count') `
                -DebuggerInvoked (Get-SkillUtilityNodeProp -Node $Outcome -Name 'debugger_invoked') `
                -ArchitectInvoked (Get-SkillUtilityNodeProp -Node $Outcome -Name 'architect_invoked') `
                -ModelEscalationCount (Get-SkillUtilityNodeProp -Node $Outcome -Name 'model_escalation_count') `
                -ReviewFindingsCount (Get-SkillUtilityNodeProp -Node $Outcome -Name 'review_findings_count') `
                -SecurityFindingsCount (Get-SkillUtilityNodeProp -Node $Outcome -Name 'security_findings_count') `
                -CompletionStatus ([string](Get-SkillUtilityNodeProp -Node $Outcome -Name 'completion_status')) `
                -Timestamp ([string](Get-SkillUtilityNodeProp -Node $Outcome -Name 'ts')))
        }
        catch { $norm = $null }
        if ($null -eq $norm) { return $false }
        if ([string]::IsNullOrWhiteSpace($norm.task_id_hash)) {
            try {
                $pre = [string](Get-SkillUtilityNodeProp -Node $Outcome -Name 'task_id_hash')
                if ($pre -match '^sha256:[0-9a-f]{16}$') { $norm.task_id_hash = $pre.ToLowerInvariant() }
            }
            catch { }
        }
        $doc = [ordered]@{
            schema_version            = [int]$norm.schema_version
            event_type                = [string]$norm.event_type
            ts                        = [string]$norm.ts
            task_id_hash              = [string]$norm.task_id_hash
            task_type                 = [string]$norm.task_type
            domain                    = [string]$norm.domain
            secondary_domains         = @([string[]]@($norm.secondary_domains))
            risk_class                = [string]$norm.risk_class
            route_mode                = [string]$norm.route_mode
            evidence_level            = [string]$norm.evidence_level
            router_candidate          = [string]$norm.router_candidate
            router_selected_agent     = [string]$norm.router_selected_agent
            actual_agent              = [string]$norm.actual_agent
            classification_confidence = [string]$norm.classification_confidence
            routing_reason            = [string]$norm.routing_reason
            fallback_used             = [bool]$norm.fallback_used
            fallback_reason           = [string]$norm.fallback_reason
            task_success              = [bool]$norm.task_success
            validation_result         = [string]$norm.validation_result
            tester_result             = [string]$norm.tester_result
            reviewer_result           = [string]$norm.reviewer_result
            retry_count               = [int]$norm.retry_count
            debugger_invoked          = [bool]$norm.debugger_invoked
            architect_invoked         = [bool]$norm.architect_invoked
            model_escalation_count    = [int]$norm.model_escalation_count
            review_findings_count     = [int]$norm.review_findings_count
            security_findings_count   = [int]$norm.security_findings_count
            completion_status         = [string]$norm.completion_status
            warnings                  = ([string[]]@($norm.warnings))
        }
        return (Write-SkillUtilityJsonlLine -Doc $doc -TelemetryPath $target -RepoRoot $repo)
    }
    catch { return $false }
}
