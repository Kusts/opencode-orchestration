<#!
.SYNOPSIS
    V3 Capability Observability lib: eventos JSONL locais + retencao (Phase 12).
.DESCRIPTION
    Biblioteca dot-sourceable (sem execucao ao carregar). Implementa a
    telemetria local da Phase 12 (sem OTEL, JSONL em cache/v3/telemetry):

      - Schema minimo (SPEC enxuto 17.2): trace_id, parent_task_id,
        task_id, timestamp, event_type, agent, model,
        selected_skills[], selected_mcps[], routing_reason, risk,
        status, validation, review_outcome, retry_count, escalation,
        duration_ms, metadata (+ warnings operacionais).
      - New-ObservabilityEvent: normaliza e valida enums fail-closed.
        event_type fora do enum => $null (nada persistido). Campos
        livres/desconhecidos => descartados ou hasheados, nunca crus.
        routing_reason => SOMENTE enum/token/hash (token canonico curto
        preservado; qualquer texto livre vira h:<16hex>; nunca a string
        crua). task_id/trace_id/parent_task_id => somente hash sha256:<16hex>.
      - Write-ObservabilityEvent: JSONL append fail-closed; arrays sempre
        como arrays; redacao de segredos; confinado a
        cache/v3/telemetry (canonicaliza; traversal/outros destinos
        recusam silenciosamente com $false); guard reparse-aware
        (junction/symlink em ancestor => $false sem escrever).
        Falha de escrita nunca bloqueia (retorna $false, nunca lanca).
      - Remove-ExpiredObservability: retencao rolling 30 dias sobre
        *-YYYYMMDD.jsonl; nunca apaga dias dentro da retencao.
      - Nenhuma funcao lanca: qualquer excecao interna vira $null/$false.

    PowerShell 5.1 compativel. ASCII-only de proposito.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-ObservabilityRepoRoot {
    [CmdletBinding()]
    param([string]$RepoRoot)
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { return $RepoRoot }
    return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
}

function Get-ObservabilityValidEventTypes {
    [CmdletBinding()]
    param()
    return @('TASK_RECEIVED', 'ROUTE_EVALUATED', 'AGENT_SELECTED', 'SKILL_SELECTED', 'MCP_SELECTED', 'DISPATCHED', 'STARTED', 'TOOL_USED', 'COMPLETED', 'VALIDATED', 'REVIEWED', 'RETRY', 'ESCALATED', 'FAILED', 'DONE')
}

function Get-ObservabilitySchemaFields {
    [CmdletBinding()]
    param()
    return @('trace_id', 'parent_task_id', 'task_id', 'timestamp', 'event_type', 'agent', 'model', 'selected_skills', 'selected_mcps', 'routing_reason', 'risk', 'status', 'validation', 'review_outcome', 'retry_count', 'escalation', 'duration_ms', 'metadata', 'warnings')
}

function Test-ObservabilityTaskId {
    [CmdletBinding()]
    param([string]$TaskId)
    if ([string]::IsNullOrWhiteSpace($TaskId)) { return $false }
    $s = ([string]$TaskId).Trim()
    if ($s.Length -gt 64) { return $false }
    return ($s -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')
}

function Test-ObservabilityCanonicalId {
    [CmdletBinding()]
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
    $s = ([string]$Id).Trim()
    if ($s.Length -gt 64) { return $false }
    return ($s -match '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$')
}

function Get-ObservabilityHash16 {
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

function Get-ObservabilityTaskKeyHex {
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

function Get-ObservabilityTaskIdHash {
    [CmdletBinding()]
    param([string]$TaskId)
    try {
        $s = ([string]$TaskId).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return '' }
        if ($s -match '^sha256:[0-9a-f]{16}$') { return $s.ToLowerInvariant() }
        $hex = Get-ObservabilityTaskKeyHex -TaskId $s
        if ([string]::IsNullOrWhiteSpace($hex)) { return '' }
        return ('sha256:' + $hex)
    }
    catch { return '' }
}

function Get-ObservabilityEventType {
    [CmdletBinding()]
    param([string]$EventType)
    try {
        $s = ([string]$EventType).Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($s)) { return '' }
        $allowed = @(Get-ObservabilityValidEventTypes)
        if ($allowed -ccontains $s) { return $s }
    }
    catch { }
    return ''
}

function Get-ObservabilityRisk {
    [CmdletBinding()]
    param([string]$Risk)
    try {
        $s = ([string]$Risk).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($s)) { return '' }
        $allowed = @('low', 'medium', 'high', 'critical', 'unknown')
        if ($allowed -ccontains $s) { return $s }
    }
    catch { }
    return ''
}

function Get-ObservabilityStatus {
    [CmdletBinding()]
    param([string]$Status)
    try {
        $s = ([string]$Status).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($s)) { return '' }
        $allowed = @('received', 'evaluated', 'selected', 'dispatched', 'started', 'tool_used', 'completed', 'validated', 'reviewed', 'retry', 'escalated', 'failed', 'done', 'success', 'fallback', 'disabled', 'degraded', 'timeout', 'deduped', 'pending')
        if ($allowed -ccontains $s) { return $s }
    }
    catch { }
    return ''
}

function Get-ObservabilityToken {
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

function Get-ObservabilityModel {
    [CmdletBinding()]
    param([string]$Model)
    try {
        $s = ([string]$Model).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return '' }
        if ($s.Length -gt 128) { return '' }
        if ($s -match '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$') { return $s }
    }
    catch { }
    return ''
}

function ConvertTo-ObservabilityStringArray {
    [CmdletBinding()]
    param($InputObject, [int]$MaxItems = 20)
    $out = New-Object System.Collections.Generic.List[string]
    try {
        if ($MaxItems -lt 1) { $MaxItems = 20 }
        if ($null -eq $InputObject) { return ([string[]]@()) }
        $items = @($InputObject)
        if ($items.Count -eq 1 -and ($items[0] -is [System.Collections.IEnumerable]) -and (-not ($items[0] -is [string]))) {
            try { $items = @($items[0]) } catch { }
        }
        foreach ($v in $items) {
            if ($out.Count -ge $MaxItems) { break }
            if ($null -eq $v) { continue }
            if ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) { continue }
            $t = ([string]$v).Trim()
            if ([string]::IsNullOrWhiteSpace($t)) { continue }
            if (-not (Test-ObservabilityCanonicalId -Id $t)) { continue }
            $out.Add($t) | Out-Null
        }
    }
    catch { }
    return ([string[]]$out.ToArray())
}

function Get-ObservabilityRedactedText {
    [CmdletBinding()]
    param([string]$Text, [int]$MaxLength = 500)
    try {
        $s = [string]$Text
        if ([string]::IsNullOrEmpty($s)) { return '' }
        try {
            $fn = Get-Command 'Get-SecretValuePattern' -ErrorAction SilentlyContinue
            if ($null -ne $fn) {
                $pat = (Get-SecretValuePattern)
                $s = ($s -replace $pat, '[REDACTED]')
            }
            else {
                $s = ($s -replace 'Bearer\s+[A-Za-z0-9\-._~+/=]{8,}|sk-[A-Za-z0-9]{10,}|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}', '[REDACTED]')
            }
        }
        catch { }
        $s = $s.Trim()
        if ($MaxLength -gt 0 -and $s.Length -gt $MaxLength) { $s = $s.Substring(0, $MaxLength) }
        return $s
    }
    catch { return '' }
}

function Get-ObservabilityReasonToken {
    <#
    .SYNOPSIS
        Normaliza routing_reason para enum/token/hash, NUNCA texto livre.
        Token canonico curto (<=32, [a-z][a-z0-9_-]*) e preservado como
        esta; qualquer outro texto vira hash h:<16hex> (sem valor cru).
        Vazio => ''. Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$Text)
    try {
        $s = ([string]$Text).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return '' }
        $tok = Get-ObservabilityToken -Text $s
        if (-not [string]::IsNullOrWhiteSpace($tok)) { return $tok }
        return (Get-ObservabilityHash16 -Text $s)
    }
    catch { return '' }
}

function Get-ObservabilityNodeProp {
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

function Get-SensitiveKeyPatternLocal {
    [CmdletBinding()]
    param()
    return '(?i)(token|secret|password|passwd|passphrase|apikey|api_key|api-key|x-api-key|authorization|auth|cookie|bearer|jwt|session|private|private_key|secret_key|access_key|refresh_token|connectionstring|connection_string|client_secret|credential)'
}

function Get-ObservabilitySanitizedMetadata {
    [CmdletBinding()]
    param($Metadata)
    $clean = [ordered]@{}
    try {
        if ($null -eq $Metadata) { return $clean }
        $pat = Get-SensitiveKeyPatternLocal
        $pairs = @()
        try {
            if ($Metadata -is [System.Collections.IDictionary]) {
                foreach ($k in @($Metadata.Keys)) { $pairs += ,@([string]$k, $Metadata[$k]) }
            }
            else {
                foreach ($p in @($Metadata.PSObject.Properties)) { $pairs += ,@([string]$p.Name, $p.Value) }
            }
        }
        catch { return $clean }
        $kept = 0
        foreach ($pair in $pairs) {
            if ($kept -ge 10) { break }
            $k = ([string]$pair[0]).Trim()
            if ([string]::IsNullOrWhiteSpace($k)) { continue }
            if ($k.Length -gt 32) { continue }
            if ($k -notmatch '^[A-Za-z][A-Za-z0-9_.-]{0,31}$') { continue }
            if ($k -match $pat) { continue }
            $v = $pair[1]
            if ($null -eq $v) { continue }
            if ($v -is [bool]) { $clean[$k] = [bool]$v; $kept++; continue }
            if ($v -is [int] -or $v -is [long] -or $v -is [double]) {
                try { $clean[$k] = [double]$v; $kept++ } catch { }
                continue
            }
            if ($v -is [string]) {
                $t = ([string]$v).Trim()
                if ([string]::IsNullOrWhiteSpace($t)) { continue }
                if ($t.Length -gt 128) { $t = $t.Substring(0, 128) }
                $clean[$k] = (Get-ObservabilityHash16 -Text $t)
                $kept++
                continue
            }
        }
    }
    catch { }
    return $clean
}

function Get-ObservabilityTimestamp {
    [CmdletBinding()]
    param([string]$Timestamp)
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

function New-ObservabilityEvent {
    <#
    .SYNOPSIS
        Constroi um evento de observabilidade normalizado (fail-closed).
        event_type invalido => $null. Nunca lanca.
    #>
    [CmdletBinding()]
    param(
        [string]$TraceId = '',
        [string]$ParentTaskId = '',
        [string]$TaskId = '',
        [string]$EventType = '',
        [string]$Agent = '',
        [string]$Model = '',
        $SelectedSkills = @(),
        $SelectedMcps = @(),
        [string]$RoutingReason = '',
        [string]$Risk = '',
        [string]$Status = '',
        [string]$Validation = '',
        [string]$ReviewOutcome = '',
        $RetryCount = 0,
        $Escalation = $false,
        $DurationMs = 0,
        $Metadata = $null,
        [string]$Timestamp = ''
    )
    try {
        $et = Get-ObservabilityEventType -EventType $EventType
        if ([string]::IsNullOrWhiteSpace($et)) { return $null }
        $warnings = New-Object System.Collections.Generic.List[string]
        $traceHash = ''
        try {
            $ts = ([string]$TraceId).Trim()
            if (-not [string]::IsNullOrWhiteSpace($ts)) {
                if ($ts -match '^sha256:[0-9a-f]{16}$') { $traceHash = $ts.ToLowerInvariant() }
                elseif (Test-ObservabilityTaskId -TaskId $ts) { $traceHash = (Get-ObservabilityTaskIdHash -TaskId $ts) }
                else { $warnings.Add('trace_id descartado (formato invalido)') | Out-Null }
            }
        }
        catch { }
        $parentHash = ''
        try {
            $ps = ([string]$ParentTaskId).Trim()
            if (-not [string]::IsNullOrWhiteSpace($ps)) {
                if ($ps -match '^sha256:[0-9a-f]{16}$') { $parentHash = $ps.ToLowerInvariant() }
                elseif (Test-ObservabilityTaskId -TaskId $ps) { $parentHash = (Get-ObservabilityTaskIdHash -TaskId $ps) }
                else { $warnings.Add('parent_task_id descartado (formato invalido)') | Out-Null }
            }
        }
        catch { }
        $taskHash = ''
        try {
            $qs = ([string]$TaskId).Trim()
            if (-not [string]::IsNullOrWhiteSpace($qs)) {
                if ($qs -match '^sha256:[0-9a-f]{16}$') { $taskHash = $qs.ToLowerInvariant() }
                elseif (Test-ObservabilityTaskId -TaskId $qs) { $taskHash = (Get-ObservabilityTaskIdHash -TaskId $qs) }
                else { $warnings.Add('task_id descartado (formato invalido; sem valor cru)') | Out-Null }
            }
        }
        catch { }
        $agentClean = ''
        try {
            $a = ([string]$Agent).Trim()
            if (-not [string]::IsNullOrWhiteSpace($a)) {
                if (Test-ObservabilityCanonicalId -Id $a) { $agentClean = $a }
                else { $warnings.Add('agent descartado (id nao canonico)') | Out-Null }
            }
        }
        catch { }
        $modelClean = Get-ObservabilityModel -Model $Model
        if ((-not [string]::IsNullOrWhiteSpace([string]$Model)) -and [string]::IsNullOrWhiteSpace($modelClean)) {
            $warnings.Add('model descartado (formato invalido)') | Out-Null
        }
        $skills = @(ConvertTo-ObservabilityStringArray -InputObject $SelectedSkills -MaxItems 20)
        $mcps = @(ConvertTo-ObservabilityStringArray -InputObject $SelectedMcps -MaxItems 20)
        $reason = Get-ObservabilityReasonToken -Text ([string]$RoutingReason)
        $riskClean = Get-ObservabilityRisk -Risk $Risk
        $statusClean = Get-ObservabilityStatus -Status $Status
        $validationClean = Get-ObservabilityToken -Text $Validation
        $reviewClean = Get-ObservabilityToken -Text $ReviewOutcome
        $retry = 0
        try {
            $retry = [int]$RetryCount
            if ($retry -lt 0) { $retry = 0 }
            if ($retry -gt 99) { $retry = 99 }
        }
        catch { $retry = 0 }
        $esc = $false
        try {
            if ($Escalation -is [bool] -and $Escalation -eq $true) { $esc = $true }
        }
        catch { $esc = $false }
        $dur = 0
        try {
            $dur = [long]$DurationMs
            if ($dur -lt 0) { $dur = 0 }
            if ($dur -gt 86400000) { $dur = 86400000 }
            $dur = [int]$dur
        }
        catch { $dur = 0 }
        $meta = Get-ObservabilitySanitizedMetadata -Metadata $Metadata
        $tsOut = Get-ObservabilityTimestamp -Timestamp $Timestamp
        return [PSCustomObject]@{
            trace_id        = $traceHash
            parent_task_id  = $parentHash
            task_id         = $taskHash
            timestamp       = $tsOut
            event_type      = $et
            agent           = $agentClean
            model           = $modelClean
            selected_skills = ([string[]]$skills)
            selected_mcps   = ([string[]]$mcps)
            routing_reason  = $reason
            risk            = $riskClean
            status          = $statusClean
            validation      = $validationClean
            review_outcome  = $reviewClean
            retry_count     = [int]$retry
            escalation      = [bool]$esc
            duration_ms     = [int]$dur
            metadata        = ([PSCustomObject]$meta)
            warnings        = ([string[]]$warnings.ToArray())
        }
    }
    catch { return $null }
}

function Test-ObservabilityConfinedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$AllowedDir,
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )
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

function Test-ObservabilityConfinedInside {
    <#
    .SYNOPSIS
        Confinamento para diretorios: aceita o caminho canonicamente IGUAL
        ao AllowedDir ou estritamente dentro dele. Qualquer outro destino
        (externo, traversal resolvido para fora) => $false. Nunca lanca.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$AllowedDir,
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )
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

function Test-ObservabilityPathHasReparsePoint {
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

function Get-ObservabilityFullPath {
    [CmdletBinding()]
    param([string]$Path, [string]$RepoRoot)
    try {
        if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
        return [IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
    }
    catch { return $Path }
}

function Get-ObservabilityDefaultTelemetryPath {
    [CmdletBinding()]
    param([string]$RepoRoot)
    try {
        $repo = Get-ObservabilityRepoRoot -RepoRoot $RepoRoot
        $stamp = ([DateTimeOffset]::UtcNow.ToString('yyyyMMdd'))
        return (Join-Path $repo ('cache\v3\telemetry\events-' + $stamp + '.jsonl'))
    }
    catch { return '' }
}

function Write-ObservabilityEvent {
    <#
    .SYNOPSIS
        Anexa um evento ao JSONL de telemetria (fail-closed, nunca bloqueia).
        Retorna $true ao anexar, $false em qualquer recusa/falha. Nunca lanca.
    #>
    [CmdletBinding()]
    param($Event = $null, [string]$TelemetryPath = '', [string]$RepoRoot = '')
    try {
        if ($null -eq $Event) { return $false }
        $repo = Get-ObservabilityRepoRoot -RepoRoot $RepoRoot
        $target = $TelemetryPath
        if ([string]::IsNullOrWhiteSpace($target)) {
            $target = Get-ObservabilityDefaultTelemetryPath -RepoRoot $repo
        }
        if ([string]::IsNullOrWhiteSpace($target)) { return $false }
        $allowedDir = Join-Path $repo 'cache\v3\telemetry'
        if (-not (Test-ObservabilityConfinedPath -Path $target -AllowedDir $allowedDir -RepoRoot $repo)) { return $false }
        if (Test-ObservabilityPathHasReparsePoint -Path (Get-ObservabilityFullPath -Path $target -RepoRoot $repo)) { return $false }
        $full = Get-ObservabilityFullPath -Path $target -RepoRoot $repo
        try {
            if ((Test-Path -LiteralPath $full) -and -not (Test-Path -LiteralPath $full -PathType Leaf)) { return $false }
        }
        catch { return $false }
        $norm = $null
        try {
            $norm = (New-ObservabilityEvent `
                -TraceId ([string](Get-ObservabilityNodeProp -Node $Event -Name 'trace_id')) `
                -ParentTaskId ([string](Get-ObservabilityNodeProp -Node $Event -Name 'parent_task_id')) `
                -TaskId ([string](Get-ObservabilityNodeProp -Node $Event -Name 'task_id')) `
                -EventType ([string](Get-ObservabilityNodeProp -Node $Event -Name 'event_type')) `
                -Agent ([string](Get-ObservabilityNodeProp -Node $Event -Name 'agent')) `
                -Model ([string](Get-ObservabilityNodeProp -Node $Event -Name 'model')) `
                -SelectedSkills (Get-ObservabilityNodeProp -Node $Event -Name 'selected_skills') `
                -SelectedMcps (Get-ObservabilityNodeProp -Node $Event -Name 'selected_mcps') `
                -RoutingReason ([string](Get-ObservabilityNodeProp -Node $Event -Name 'routing_reason')) `
                -Risk ([string](Get-ObservabilityNodeProp -Node $Event -Name 'risk')) `
                -Status ([string](Get-ObservabilityNodeProp -Node $Event -Name 'status')) `
                -Validation ([string](Get-ObservabilityNodeProp -Node $Event -Name 'validation')) `
                -ReviewOutcome ([string](Get-ObservabilityNodeProp -Node $Event -Name 'review_outcome')) `
                -RetryCount (Get-ObservabilityNodeProp -Node $Event -Name 'retry_count') `
                -Escalation (Get-ObservabilityNodeProp -Node $Event -Name 'escalation') `
                -DurationMs (Get-ObservabilityNodeProp -Node $Event -Name 'duration_ms') `
                -Metadata (Get-ObservabilityNodeProp -Node $Event -Name 'metadata') `
                -Timestamp ([string](Get-ObservabilityNodeProp -Node $Event -Name 'timestamp')))
        }
        catch { $norm = $null }
        if ($null -eq $norm) { return $false }
        $doc = [ordered]@{
            trace_id        = [string]$norm.trace_id
            parent_task_id  = [string]$norm.parent_task_id
            task_id         = [string]$norm.task_id
            timestamp       = [string]$norm.timestamp
            event_type      = [string]$norm.event_type
            agent           = [string]$norm.agent
            model           = [string]$norm.model
            selected_skills = ([string[]]@($norm.selected_skills))
            selected_mcps   = ([string[]]@($norm.selected_mcps))
            routing_reason  = [string]$norm.routing_reason
            risk            = [string]$norm.risk
            status          = [string]$norm.status
            validation      = [string]$norm.validation
            review_outcome  = [string]$norm.review_outcome
            retry_count     = [int]$norm.retry_count
            escalation      = [bool]$norm.escalation
            duration_ms     = [int]$norm.duration_ms
            metadata        = $norm.metadata
            warnings        = ([string[]]@($norm.warnings))
        }
        $text = ''
        try { $text = ($doc | ConvertTo-Json -Depth 10 -Compress) }
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

function Remove-ExpiredObservability {
    <#
    .SYNOPSIS
        Retencao rolling sobre *-YYYYMMDD.jsonl (default 30 dias),
        CONFINADA a cache/v3/telemetry: diretorio externo ou com reparse
        point => recusa sem deletar nada (nunca Remove-Item fora).
        Nunca apaga dias dentro da retencao. Nunca lanca.
    #>
    [CmdletBinding()]
    param([string]$TelemetryDir = '', $RetentionDays = 30, [string]$RepoRoot = '')
    $out = [PSCustomObject]@{ Removed = 0; Kept = 0; RemovedFiles = @(); Error = '' }
    try {
        $days = 30
        try {
            $days = [int]$RetentionDays
            if ($days -lt 1) { $days = 30 }
            if ($days -gt 365) { $days = 365 }
        }
        catch { $days = 30 }
        $repo = Get-ObservabilityRepoRoot -RepoRoot $RepoRoot
        $allowedDir = Join-Path $repo 'cache\v3\telemetry'
        $dir = $TelemetryDir
        try {
            if ([string]::IsNullOrWhiteSpace($dir)) {
                $dir = $allowedDir
            }
        }
        catch { $out.Error = 'resolve'; return $out }
        # Confinamento duro: so aceita diretorio canonicamente IGUAL ou
        # DENTRO de cache/v3/telemetry. Diretorio externo => recusa sem
        # deletar nada (nunca Remove-Item fora do perimetro).
        try {
            if (-not (Test-ObservabilityConfinedInside -Path $dir -AllowedDir $allowedDir -RepoRoot $repo)) {
                $out.Error = 'outside-telemetry-dir'
                return $out
            }
        }
        catch { $out.Error = 'outside-telemetry-dir'; return $out }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $out }
        try {
            if (Test-ObservabilityPathHasReparsePoint -Path ([IO.Path]::GetFullPath($dir))) { $out.Error = 'reparse'; return $out }
        }
        catch { }
        $today = [DateTimeOffset]::UtcNow.Date
        $files = @()
        try { $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.jsonl' -File -Force -ErrorAction Stop) }
        catch { $out.Error = 'list'; return $out }
        $removed = New-Object System.Collections.Generic.List[string]
        $kept = 0
        foreach ($f in $files) {
            try {
                $m = [regex]::Match($f.Name, '-(\d{8})\.jsonl$')
                if (-not $m.Success) { $kept++; continue }
                $stamp = $m.Groups[1].Value
                $parsed = [DateTime]::MinValue
                $ok = [DateTime]::TryParseExact($stamp, 'yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)
                if (-not $ok) { $kept++; continue }
                $age = ($today - [DateTimeOffset]::new([DateTime]::SpecifyKind($parsed, [DateTimeKind]::Utc)).Date).TotalDays
                if ($age -gt [double]$days) {
                    # Defesa em profundidade: so remove arquivo
                    # canonicamente dentro do perimetro (nunca fora).
                    try {
                        if (-not (Test-ObservabilityConfinedPath -Path $f.FullName -AllowedDir $allowedDir -RepoRoot $repo)) { $kept++; continue }
                    }
                    catch { $kept++; continue }
                    try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } catch { $kept++; continue }
                    $removed.Add($f.Name) | Out-Null
                }
                else { $kept++ }
            }
            catch { $kept++ }
        }
        $out.Removed = $removed.Count
        $out.Kept = $kept
        $out.RemovedFiles = ([string[]]$removed.ToArray())
        return $out
    }
    catch { return $out }
}
