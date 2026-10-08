<#!
.SYNOPSIS
    PR-6 Objective telemetry sink: per-Goal JSONL harness telemetry (CORRECTIVE-PLAN Fase PR-6).
.DESCRIPTION
    TEST HARNESS SUPPORT LIB - NOT PRODUCT RUNTIME. Dot-sourceable library
    (no execution on load). Per-Goal JSONL sink plus pure in-memory event
    constructors and baseline aggregation, fail-closed, PS 5.1 compatible,
    ASCII-only. Never throws on operational paths: every failure returns an
    object with ok=$false and a machine-readable reason. No network, no
    process spawn, no secrets (goal/objective ids are validated names only,
    never credential values), no flags read or written, no DONE and no
    verified_pass ever issued here.

    Every event carries harness_level=$true and runtime_real=$false by
    construction: this sink records HARNESS-LEVEL synthetic outcomes only.
    Runtime-real execution with a live OpenCode session stays HOLD/BLOCKED
    (provider/CI operator-owned) and is NEVER claimed through this lib.

    Cost-to-DONE is a PROXY without provider: estimated tokens = counted
    characters / 4 over the serialized event core, reported with
    is_proxy=$true and method='chars-div-4-proxy'. It is a comparable
    baseline signal, never a measured provider cost.

    Bounds: MaxEventsPerGoal (default 200) caps lines per goal file;
    MaxLineBytes (default 65536) caps one serialized event; MaxLines
    (default 500) caps baseline re-reads. All loops over files/lines are
    capped; there are no unbounded loops.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-OrchestrationObjectiveTelemetryVersion {
    [CmdletBinding()]
    param()
    return [pscustomobject]@{
        schema_version = [long]1
        contract       = 'UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-OBJECTIVE-TELEMETRY-PR6'
        phase          = 'PR-6'
        harness_level  = $true
        runtime_real   = $false
    }
}

function Get-OTField {
    param($Object, [string]$Name, $Default = $null)
    try {
        if ($null -eq $Object) { return $Default }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $Default
        }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p) { return $p.Value }
        return $Default
    }
    catch { return $Default }
}

function Get-OTNonNegativeLong {
    param($Value, [long]$Default = -1)
    try {
        if ($Value -is [long]) {
            if ([long]$Value -ge 0) { return [long]$Value }
            return $Default
        }
        if ($Value -is [int] -or $Value -is [int16] -or $Value -is [byte] -or $Value -is [sbyte]) {
            $n = [long]$Value
            if ($n -ge 0) { return $n }
            return $Default
        }
        return $Default
    }
    catch { return $Default }
}

function Get-OTStamp {
    try { return ([DateTime]::UtcNow.ToString('o')) } catch { return '' }
}

function Test-OTGoalId {
    param([string]$Value)
    try {
        $v = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        return ($v -cmatch '^[A-Za-z0-9._:-]{1,64}$')
    }
    catch { return $false }
}

function Get-OTHashHex32 {
    param([string]$Text)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Text)
            $h = $sha.ComputeHash($bytes)
            $hex = ([BitConverter]::ToString($h)).Replace('-', '').ToLowerInvariant()
            return $hex.Substring(0, 32)
        }
        finally { try { $sha.Dispose() } catch { } }
    }
    catch { return '' }
}

function Get-OTValidScenarios {
    [CmdletBinding()]
    param()
    $out = New-Object System.Collections.ArrayList
    for ($i = 1; $i -le 15; $i++) {
        [void]$out.Add(('E2E-' + ([string]$i).PadLeft(2, '0')))
    }
    return @($out.ToArray())
}

function Get-OTValidShapes {
    [CmdletBinding()]
    param()
    return @('SINGLE_WORKER', 'MULTI_WORKER', 'DETERMINISTIC_FALLBACK', 'BLOCKED')
}

function Get-OTValidGates {
    [CmdletBinding()]
    param()
    return @('G1', 'G2', 'G3', 'G4', 'G5', 'G6', 'G7', 'G8')
}

function Get-OTValidStopReasons {
    [CmdletBinding()]
    param()
    return @('OBJECTIVE_COMPLETED', 'HUMAN_AUTHORITY_REQUIRED', 'EXTERNAL_BLOCKER_WITH_NO_ALTERNATIVE', 'GOAL_HARD_BUDGET_EXHAUSTED', 'POLICY_BLOCKED', 'CANCELLED')
}

function Get-OTValidResults {
    [CmdletBinding()]
    param()
    return @('PASS', 'FAIL', 'INCONCLUSIVE')
}

function Get-OrchestrationObjectiveCostProxy {
    <#
    .SYNOPSIS
        Provider-free cost-to-DONE proxy (PR-6).
    .DESCRIPTION
        Estimates tokens as counted characters / 4 over -Text (or an
        explicit -CharCount). Always reports is_proxy=$true with
        method='chars-div-4-proxy' and provider=$null: a comparable
        baseline signal, never a measured provider cost. Bounded:
        inputs above 1MiB are rejected fail-closed. Never throws.
    #>
    [CmdletBinding()]
    param(
        [string]$Text = '',
        [long]$CharCount = -1
    )
    try {
        $chars = Get-OTNonNegativeLong $CharCount -1
        if ($chars -lt 0) {
            $t = [string]$Text
            if ($t.Length -gt 1048576) {
                return [pscustomobject]@{ ok = $false; reason = 'proxy-input-too-large'; proxy = $null }
            }
            $chars = [long]$t.Length
        }
        if ($chars -gt 1048576) {
            return [pscustomobject]@{ ok = $false; reason = 'proxy-input-too-large'; proxy = $null }
        }
        $tokens = [long]([Math]::Floor($chars / 4))
        $proxy = [pscustomobject][ordered]@{
            estimated_tokens = [long]$tokens
            counted_chars    = [long]$chars
            method           = 'chars-div-4-proxy'
            is_proxy         = $true
            provider         = $null
        }
        return [pscustomobject]@{ ok = $true; reason = ''; proxy = $proxy }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'proxy-internal'; proxy = $null }
    }
}

function Get-OTWorkerList {
    param($Value)
    try {
        if ($null -eq $Value) { return ,([string[]]@()) }
        if ($Value -is [string]) {
            if ([string]::IsNullOrWhiteSpace([string]$Value)) { return ,([string[]]@()) }
            $one = ([string]$Value).Trim()
            if (-not (Test-OTGoalId $one)) { return $null }
            return ,([string[]]@($one))
        }
        $out = New-Object System.Collections.ArrayList
        $n = 0
        foreach ($item in @($Value)) {
            $n++
            if ($n -gt 8) { return $null }
            if (-not ($item -is [string])) { return $null }
            $s = ([string]$item).Trim()
            if (-not (Test-OTGoalId $s)) { return $null }
            [void]$out.Add($s)
        }
        return ,([string[]]$out.ToArray())
    }
    catch { return $null }
}

function Get-OTGateList {
    param($Value)
    try {
        $valid = @(Get-OTValidGates)
        if ($null -eq $Value) { return ,([string[]]@()) }
        if ($Value -is [string]) {
            if ([string]::IsNullOrWhiteSpace([string]$Value)) { return ,([string[]]@()) }
            $g = ([string]$Value).Trim().ToUpperInvariant()
            if ($valid -cnotcontains $g) { return $null }
            return ,([string[]]@($g))
        }
        $out = New-Object System.Collections.ArrayList
        $n = 0
        foreach ($item in @($Value)) {
            $n++
            if ($n -gt 8) { return $null }
            if (-not ($item -is [string])) { return $null }
            $g = ([string]$item).Trim().ToUpperInvariant()
            if ($valid -cnotcontains $g) { return $null }
            if (@($out) -cnotcontains $g) { [void]$out.Add($g) }
        }
        return ,([string[]]$out.ToArray())
    }
    catch { return $null }
}

function Get-OTRedactFreeText {
    param([string]$Value)
    try {
        $s = ([string]$Value)
        if ([string]::IsNullOrEmpty($s)) { return '' }
        try {
            $homeVals = @()
            try { if (-not [string]::IsNullOrWhiteSpace([string]$env:USERPROFILE)) { $homeVals += [string]$env:USERPROFILE } } catch { }
            try { if (-not [string]::IsNullOrWhiteSpace([string]$env:HOME)) { $homeVals += [string]$env:HOME } } catch { }
            foreach ($h in @($homeVals)) {
                if ([string]::IsNullOrWhiteSpace($h)) { continue }
                try { $s = $s.Replace($h, '<home-redacted>') } catch { }
            }
        }
        catch { }
        try { $s = ([regex]::Replace($s, '(?i)C:\\Users\\[A-Za-z0-9._-]+', '<home-redacted>')) } catch { }
        try { $s = ([regex]::Replace($s, '(?i)/home/[A-Za-z0-9._-]+', '<home-redacted>')) } catch { }
        try { $s = ([regex]::Replace($s, '(?i)sk-[A-Za-z0-9\-_]+', '<redacted>')) } catch { }
        try { $s = ([regex]::Replace($s, '(?i)(token|api[_-]?key|secret|password)\s*=\s*[^\s|;,]+', '$1=<redacted>')) } catch { }
        try { $s = ([regex]::Replace($s, '(?i)JEV_API_KEY\s*[=:\s]+[^\s|;,]+', 'JEV_API_KEY <redacted>')) } catch { }
        return $s
    }
    catch { return '<redacted>' }
}

function Test-OTFreeTextLeak {
    param([string]$Value)
    try {
        $s = ([string]$Value)
        if ([string]::IsNullOrEmpty($s)) { return $false }
        if ([regex]::IsMatch($s, '(?i)sk-[A-Za-z0-9\-_]+')) { return $true }
        if ([regex]::IsMatch($s, '(?i)(token|api[_-]?key|secret|password)\s*=\s*[^\s|;,]+')) { return $true }
        if ([regex]::IsMatch($s, '(?i)JEV_API_KEY\s*[=:\s]+[^\s|;,]+')) { return $true }
        try {
            if (-not [string]::IsNullOrWhiteSpace([string]$env:USERPROFILE)) {
                if ($s.Contains([string]$env:USERPROFILE)) { return $true }
            }
        }
        catch { }
        try {
            if (-not [string]::IsNullOrWhiteSpace([string]$env:HOME)) {
                if ($s.Contains([string]$env:HOME)) { return $true }
            }
        }
        catch { }
        if ([regex]::IsMatch($s, '(?i)C:\\Users\\[A-Za-z0-9._-]+')) { return $true }
        if ([regex]::IsMatch($s, '(?i)/home/[A-Za-z0-9._-]+')) { return $true }
        return $false
    }
    catch { return $true }
}

function Test-OTDeepLeak {
    param($Value, [int]$Depth = 0)
    try {
        if ([int]$Depth -gt 10) { return $true }
        if ($null -eq $Value) { return $false }
        if ($Value -is [string]) { return (Test-OTFreeTextLeak ([string]$Value)) }
        if ($Value -is [System.Collections.IDictionary]) {
            foreach ($k in @($Value.Keys)) {
                try {
                    if ($k -is [string]) {
                        if (Test-OTFreeTextLeak ([string]$k)) { return $true }
                    }
                }
                catch { return $true }
                $vv = $null
                try { $vv = $Value[$k] } catch { return $true }
                if (Test-OTDeepLeak $vv ([int]($Depth + 1))) { return $true }
            }
            return $false
        }
        if ($Value -is [pscustomobject]) {
            foreach ($pp in @($Value.PSObject.Properties)) {
                try {
                    if (Test-OTFreeTextLeak ([string]$pp.Name)) { return $true }
                }
                catch { return $true }
                $vv = $null
                try { $vv = $pp.Value } catch { return $true }
                if (Test-OTDeepLeak $vv ([int]($Depth + 1))) { return $true }
            }
            return $false
        }
        if (($Value -is [System.Collections.IEnumerable]) -and (-not ($Value -is [string]))) {
            $nn = 0
            foreach ($it in @($Value)) {
                $nn++
                if ([int]$nn -gt 64) { return $true }
                if (Test-OTDeepLeak $it ([int]($Depth + 1))) { return $true }
            }
            return $false
        }
        return $false
    }
    catch { return $true }
}

function New-OrchestrationObjectiveTelemetryEvent {
    <#
    .SYNOPSIS
        Pure harness-level telemetry event constructor (PR-6).
    .DESCRIPTION
        Builds one validated event record. harness_level=$true and
        runtime_real=$false are fixed by construction. -Scenario must be
        E2E-01..E2E-15; -Shape one of the 4 orchestration shapes; -Gates a
        subset of G1..G8; -StopReason '' (non-terminal step) or one of the
        6 Fase-2 codes; -Result PASS/FAIL/INCONCLUSIVE. All counters are
        non-negative longs. Cost proxy is computed over the serialized
        event core (declared proxy, never provider-measured). Never
        throws; invalid input yields ok=$false with a reason.
    #>
    [CmdletBinding()]
    param(
        [string]$GoalId = '',
        [string]$Objective = '',
        [string]$Scenario = '',
        [string]$Shape = '',
        $Workers = @(),
        $Gates = @(),
        [long]$ReuseHits = 0,
        [long]$ReuseMisses = 0,
        [long]$JevCalls = 0,
        [long]$JevFallbacks = 0,
        [long]$Retries = 0,
        [long]$StrategyChanges = 0,
        [long]$ProgressDeltas = 0,
        [long]$Findings = 0,
        [long]$Interventions = 0,
        [long]$Dispatches = 0,
        [long]$OperationsAvoided = 0,
        [string]$Validation = '',
        [string]$StopReason = '',
        [string]$Result = '',
        [string]$Note = ''
    )
    try {
        $gid = ([string]$GoalId).Trim()
        if (-not (Test-OTGoalId $gid)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-goal-id'; event = $null }
        }
        $obj = Get-OTRedactFreeText ([string]$Objective).Trim()
        if ([string]::IsNullOrWhiteSpace($obj) -or ($obj.Length -gt 512)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-objective'; event = $null }
        }
        $sc = ([string]$Scenario).Trim().ToUpperInvariant()
        if (@(Get-OTValidScenarios) -cnotcontains $sc) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-scenario'; event = $null }
        }
        $sh = ([string]$Shape).Trim().ToUpperInvariant()
        if (@(Get-OTValidShapes) -cnotcontains $sh) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-shape'; event = $null }
        }
        $wl = Get-OTWorkerList $Workers
        if ($null -eq $wl) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-workers'; event = $null }
        }
        $gl = Get-OTGateList $Gates
        if ($null -eq $gl) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-gates'; event = $null }
        }
        $rh = Get-OTNonNegativeLong $ReuseHits -1
        $rm = Get-OTNonNegativeLong $ReuseMisses -1
        $jc = Get-OTNonNegativeLong $JevCalls -1
        $jf = Get-OTNonNegativeLong $JevFallbacks -1
        $rt = Get-OTNonNegativeLong $Retries -1
        $st = Get-OTNonNegativeLong $StrategyChanges -1
        $pd = Get-OTNonNegativeLong $ProgressDeltas -1
        $fd = Get-OTNonNegativeLong $Findings -1
        $iv = Get-OTNonNegativeLong $Interventions -1
        $dp = Get-OTNonNegativeLong $Dispatches -1
        $oa = Get-OTNonNegativeLong $OperationsAvoided -1
        if (($rh -lt 0) -or ($rm -lt 0) -or ($jc -lt 0) -or ($jf -lt 0) -or ($rt -lt 0) -or ($st -lt 0) -or ($pd -lt 0) -or ($fd -lt 0) -or ($iv -lt 0) -or ($dp -lt 0) -or ($oa -lt 0)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-counter'; event = $null }
        }
        if ($jf -gt $jc) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-jev-fallback-exceeds-calls'; event = $null }
        }
        $val = ([string]$Validation).Trim().ToLowerInvariant()
        if (@('', 'pass', 'fail', 'pending') -cnotcontains $val) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-validation'; event = $null }
        }
        $sr = ([string]$StopReason).Trim().ToUpperInvariant()
        if (($sr -ne '') -and ((@(Get-OTValidStopReasons) -cnotcontains $sr))) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-stop-reason'; event = $null }
        }
        $rs = ([string]$Result).Trim().ToUpperInvariant()
        if (@(Get-OTValidResults) -cnotcontains $rs) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-result'; event = $null }
        }
        $note = Get-OTRedactFreeText ([string]$Note).Trim()
        if ($note.Length -gt 512) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-note'; event = $null }
        }
        $core = [ordered]@{
            goal_id     = $gid
            objective   = $obj
            scenario    = $sc
            shape       = $sh
            workers     = @($wl)
            gates       = @($gl)
            stop_reason = $sr
            result      = $rs
        }
        $coreJson = ''
        try { $coreJson = (ConvertTo-Json -InputObject $core -Depth 10 -Compress) } catch { $coreJson = '' }
        if ([string]::IsNullOrWhiteSpace($coreJson)) {
            return [pscustomobject]@{ ok = $false; reason = 'event-serialize-failed'; event = $null }
        }
        $px = Get-OrchestrationObjectiveCostProxy -Text $coreJson
        if (($null -eq $px) -or (-not [bool]$px.ok)) {
            return [pscustomobject]@{ ok = $false; reason = 'event-cost-proxy-failed'; event = $null }
        }
        $ev = [ordered]@{
            schema_version      = [long]1
            harness_level       = $true
            runtime_real        = $false
            goal_id             = $gid
            objective           = $obj
            scenario            = $sc
            shape               = $sh
            workers             = @($wl)
            gates               = @($gl)
            reuse_hits          = [long]$rh
            reuse_misses        = [long]$rm
            jev_calls           = [long]$jc
            jev_fallbacks       = [long]$jf
            retries             = [long]$rt
            strategy_changes    = [long]$st
            progress_deltas     = [long]$pd
            findings            = [long]$fd
            interventions       = [long]$iv
            dispatches          = [long]$dp
            operations_avoided  = [long]$oa
            validation          = $val
            stop_reason         = $sr
            result              = $rs
            cost_proxy          = $px.proxy
            note                = $note
            recorded_at         = (Get-OTStamp)
        }
        return [pscustomobject]@{ ok = $true; reason = ''; event = $ev }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'event-internal'; event = $null }
    }
}

function Get-OTTelemetryFilePath {
    param([string]$Dir, [string]$GoalId)
    try {
        $gid = ([string]$GoalId).Trim()
        if (-not (Test-OTGoalId $gid)) { return '' }
        $h = Get-OTHashHex32 ($gid.ToLowerInvariant())
        if ([string]::IsNullOrWhiteSpace($h)) { return '' }
        return (Join-Path $Dir ('objective-' + $h + '.telemetry.jsonl'))
    }
    catch { return '' }
}

function Save-OrchestrationObjectiveTelemetryEvent {
    <#
    .SYNOPSIS
        Appends one telemetry event as JSONL (PR-6 sink).
    .DESCRIPTION
        Validates -Event via the constructor shape (schema_version=1,
        harness_level=$true, runtime_real=$false enforced), then appends
        one line to objective-<hash>.telemetry.jsonl under -StoreDir.
        Bounded: refuses when the goal file already holds MaxEventsPerGoal
        lines (default 200) or the serialized line exceeds MaxLineBytes
        (default 65536). Non-terminal step events and final events share
        the same sink. Never throws; failures are ok=$false envelopes.
    #>
    [CmdletBinding()]
    param(
        $Event = $null,
        [string]$StoreDir = '',
        [long]$MaxEventsPerGoal = 200,
        [long]$MaxLineBytes = 65536
    )
    try {
        if (($null -eq $Event) -or ((-not ($Event -is [System.Collections.IDictionary])) -and (-not ($Event -is [pscustomobject])))) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-event'; appended = $false }
        }
        $sv = Get-OTNonNegativeLong (Get-OTField $Event 'schema_version' $null) -1
        if ($sv -ne 1) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-event-schema'; appended = $false }
        }
        try {
            if (-not [bool](Get-OTField $Event 'harness_level' $false)) {
                return [pscustomobject]@{ ok = $false; reason = 'event-not-harness-level'; appended = $false }
            }
        }
        catch {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-event'; appended = $false }
        }
        try {
            if ([bool](Get-OTField $Event 'runtime_real' $true)) {
                return [pscustomobject]@{ ok = $false; reason = 'event-claims-runtime-real'; appended = $false }
            }
        }
        catch {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-event'; appended = $false }
        }
        $gid = [string](Get-OTField $Event 'goal_id' '')
        if (-not (Test-OTGoalId $gid)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-goal-id'; appended = $false }
        }
        $allowedKeys = @('schema_version', 'harness_level', 'runtime_real', 'goal_id', 'objective', 'scenario', 'shape', 'workers', 'gates', 'reuse_hits', 'reuse_misses', 'jev_calls', 'jev_fallbacks', 'retries', 'strategy_changes', 'progress_deltas', 'findings', 'interventions', 'dispatches', 'operations_avoided', 'validation', 'stop_reason', 'result', 'cost_proxy', 'note', 'recorded_at')
        try {
            $evKeys = @()
            if ($Event -is [System.Collections.IDictionary]) { $evKeys = @($Event.Keys) }
            else { $evKeys = @($Event.PSObject.Properties | ForEach-Object { $_.Name }) }
            foreach ($k in @($evKeys)) {
                if ($allowedKeys -cnotcontains ([string]$k)) {
                    return [pscustomobject]@{ ok = $false; reason = 'event-extra-property'; appended = $false }
                }
            }
        }
        catch {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-event'; appended = $false }
        }
        $canon = $null
        try {
            $pxRaw = Get-OTField $Event 'cost_proxy' $null
            if (($null -eq $pxRaw) -or ((-not ($pxRaw -is [System.Collections.IDictionary])) -and (-not ($pxRaw -is [pscustomobject])))) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-event'; appended = $false }
            }
            $pxAllowed = @('estimated_tokens', 'counted_chars', 'method', 'is_proxy', 'provider')
            $pxKeys = @()
            if ($pxRaw -is [System.Collections.IDictionary]) { $pxKeys = @($pxRaw.Keys) }
            else { $pxKeys = @($pxRaw.PSObject.Properties | ForEach-Object { $_.Name }) }
            foreach ($pk in @($pxKeys)) {
                if ($pxAllowed -cnotcontains ([string]$pk)) {
                    return [pscustomobject]@{ ok = $false; reason = 'event-extra-property'; appended = $false }
                }
            }
            try {
                if (Test-OTDeepLeak $Event) {
                    return [pscustomobject]@{ ok = $false; reason = 'event-sensitive-blocked'; appended = $false }
                }
            }
            catch {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-event'; appended = $false }
            }
            foreach ($sf in @('goal_id', 'objective', 'scenario', 'shape', 'validation', 'stop_reason', 'result', 'note')) {
                $svv = Get-OTField $Event $sf $null
                if (($null -ne $svv) -and (-not ($svv -is [string]))) {
                    return [pscustomobject]@{ ok = $false; reason = 'invalid-event'; appended = $false }
                }
            }
            $gidCanon = ([string]$gid).Trim()
            if (-not (Test-OTGoalId $gidCanon)) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-goal-id'; appended = $false }
            }
            $obj = Get-OTRedactFreeText ([string](Get-OTField $Event 'objective' '')).Trim()
            if ([string]::IsNullOrWhiteSpace($obj) -or ($obj.Length -gt 512)) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-objective'; appended = $false }
            }
            $sc = ([string](Get-OTField $Event 'scenario' '')).Trim().ToUpperInvariant()
            if (@(Get-OTValidScenarios) -cnotcontains $sc) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-scenario'; appended = $false }
            }
            $sh = ([string](Get-OTField $Event 'shape' '')).Trim().ToUpperInvariant()
            if (@(Get-OTValidShapes) -cnotcontains $sh) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-shape'; appended = $false }
            }
            $wl = Get-OTWorkerList (Get-OTField $Event 'workers' $null)
            if ($null -eq $wl) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-workers'; appended = $false }
            }
            $gl = Get-OTGateList (Get-OTField $Event 'gates' $null)
            if ($null -eq $gl) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-gates'; appended = $false }
            }
            $rh = Get-OTNonNegativeLong (Get-OTField $Event 'reuse_hits' $null) -1
            $rm = Get-OTNonNegativeLong (Get-OTField $Event 'reuse_misses' $null) -1
            $jc = Get-OTNonNegativeLong (Get-OTField $Event 'jev_calls' $null) -1
            $jf = Get-OTNonNegativeLong (Get-OTField $Event 'jev_fallbacks' $null) -1
            $rt = Get-OTNonNegativeLong (Get-OTField $Event 'retries' $null) -1
            $st = Get-OTNonNegativeLong (Get-OTField $Event 'strategy_changes' $null) -1
            $pd = Get-OTNonNegativeLong (Get-OTField $Event 'progress_deltas' $null) -1
            $fd = Get-OTNonNegativeLong (Get-OTField $Event 'findings' $null) -1
            $iv = Get-OTNonNegativeLong (Get-OTField $Event 'interventions' $null) -1
            $dp = Get-OTNonNegativeLong (Get-OTField $Event 'dispatches' $null) -1
            $oa = Get-OTNonNegativeLong (Get-OTField $Event 'operations_avoided' $null) -1
            if (($rh -lt 0) -or ($rm -lt 0) -or ($jc -lt 0) -or ($jf -lt 0) -or ($rt -lt 0) -or ($st -lt 0) -or ($pd -lt 0) -or ($fd -lt 0) -or ($iv -lt 0) -or ($dp -lt 0) -or ($oa -lt 0)) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-counter'; appended = $false }
            }
            if ($jf -gt $jc) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-jev-fallback-exceeds-calls'; appended = $false }
            }
            $val = ([string](Get-OTField $Event 'validation' '')).Trim().ToLowerInvariant()
            if (@('', 'pass', 'fail', 'pending') -cnotcontains $val) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-validation'; appended = $false }
            }
            $sr = ([string](Get-OTField $Event 'stop_reason' '')).Trim().ToUpperInvariant()
            if (($sr -ne '') -and ((@(Get-OTValidStopReasons) -cnotcontains $sr))) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-stop-reason'; appended = $false }
            }
            $rs = ([string](Get-OTField $Event 'result' '')).Trim().ToUpperInvariant()
            if (@(Get-OTValidResults) -cnotcontains $rs) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-result'; appended = $false }
            }
            $note = Get-OTRedactFreeText ([string](Get-OTField $Event 'note' '')).Trim()
            if ($note.Length -gt 512) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-note'; appended = $false }
            }
            $pxEt = Get-OTNonNegativeLong (Get-OTField $pxRaw 'estimated_tokens' $null) -1
            $pxCc = Get-OTNonNegativeLong (Get-OTField $pxRaw 'counted_chars' $null) -1
            $pxMethod = [string](Get-OTField $pxRaw 'method' '')
            $pxIsProxy = $false
            try { $pxIsProxy = [bool](Get-OTField $pxRaw 'is_proxy' $false) } catch { $pxIsProxy = $false }
            $pxProv = Get-OTField $pxRaw 'provider' $null
            $pxProvOk = (($null -eq $pxProv) -or ([string]$pxProv -eq ''))
            if (($pxEt -lt 0) -or ($pxCc -lt 0) -or ($pxMethod -cne 'chars-div-4-proxy') -or (-not $pxIsProxy) -or (-not $pxProvOk)) {
                return [pscustomobject]@{ ok = $false; reason = 'invalid-event'; appended = $false }
            }
            $core = [ordered]@{
                goal_id     = $gidCanon
                objective   = $obj
                scenario    = $sc
                shape       = $sh
                workers     = @($wl)
                gates       = @($gl)
                stop_reason = $sr
                result      = $rs
            }
            $coreJson = ''
            try { $coreJson = (ConvertTo-Json -InputObject $core -Depth 10 -Compress) } catch { $coreJson = '' }
            if ([string]::IsNullOrWhiteSpace($coreJson)) {
                return [pscustomobject]@{ ok = $false; reason = 'event-serialize-failed'; appended = $false }
            }
            $pxNew = Get-OrchestrationObjectiveCostProxy -Text $coreJson
            if (($null -eq $pxNew) -or (-not [bool]$pxNew.ok)) {
                return [pscustomobject]@{ ok = $false; reason = 'event-cost-proxy-failed'; appended = $false }
            }
            $gid = $gidCanon
            $canon = [ordered]@{
                schema_version     = [long]1
                harness_level      = $true
                runtime_real       = $false
                goal_id            = $gidCanon
                objective          = $obj
                scenario           = $sc
                shape              = $sh
                workers            = @($wl)
                gates              = @($gl)
                reuse_hits         = [long]$rh
                reuse_misses       = [long]$rm
                jev_calls          = [long]$jc
                jev_fallbacks      = [long]$jf
                retries            = [long]$rt
                strategy_changes   = [long]$st
                progress_deltas    = [long]$pd
                findings           = [long]$fd
                interventions      = [long]$iv
                dispatches         = [long]$dp
                operations_avoided = [long]$oa
                validation         = $val
                stop_reason        = $sr
                result             = $rs
                cost_proxy         = $pxNew.proxy
                note               = $note
                recorded_at        = (Get-OTStamp)
            }
        }
        catch {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-event'; appended = $false }
        }
        $dir = ([string]$StoreDir).Trim()
        if ([string]::IsNullOrWhiteSpace($dir)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-store-dir'; appended = $false }
        }
        $cap = Get-OTNonNegativeLong $MaxEventsPerGoal 200
        if ($cap -lt 1) { $cap = 1 }
        if ($cap -gt 1000) { $cap = 1000 }
        $lineCap = Get-OTNonNegativeLong $MaxLineBytes 65536
        if ($lineCap -lt 1024) { $lineCap = 1024 }
        if ($lineCap -gt 1048576) { $lineCap = 1048576 }
        try {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                [void][IO.Directory]::CreateDirectory($dir)
            }
        }
        catch {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-store-dir'; appended = $false }
        }
        $path = Get-OTTelemetryFilePath -Dir $dir -GoalId $gid
        if ([string]::IsNullOrWhiteSpace($path)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-goal-id'; appended = $false }
        }
        $line = ''
        try { $line = (ConvertTo-Json -InputObject $canon -Depth 20 -Compress) } catch { $line = '' }
        if ([string]::IsNullOrWhiteSpace($line)) {
            return [pscustomobject]@{ ok = $false; reason = 'event-serialize-failed'; appended = $false }
        }
        $bytes = $null
        try { $bytes = [Text.Encoding]::UTF8.GetBytes($line) } catch { $bytes = $null }
        if (($null -eq $bytes) -or ($bytes.Length -gt $lineCap)) {
            return [pscustomobject]@{ ok = $false; reason = 'event-line-too-large'; appended = $false }
        }
        try {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $count = 0
                try {
                    $sr = [IO.File]::OpenText($path)
                    try {
                        while (($null -ne $sr.ReadLine()) -and ($count -le $cap)) { $count++ }
                    }
                    finally { try { $sr.Dispose() } catch { } }
                }
                catch { $count = 0 }
                if ($count -ge $cap) {
                    return [pscustomobject]@{ ok = $false; reason = 'telemetry-cap'; appended = $false }
                }
            }
        }
        catch {
            return [pscustomobject]@{ ok = $false; reason = 'telemetry-read-failed'; appended = $false }
        }
        try {
            $sw = [IO.File]::AppendText($path)
            try {
                $sw.WriteLine($line)
                $sw.Flush()
            }
            finally { try { $sw.Dispose() } catch { } }
        }
        catch {
            return [pscustomobject]@{ ok = $false; reason = 'telemetry-write-failed'; appended = $false }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; appended = $true }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'telemetry-internal'; appended = $false }
    }
}

function New-OrchestrationObjectiveTelemetrySummary {
    <#
    .SYNOPSIS
        Pure in-memory aggregation over telemetry events (PR-6 baseline).
    .DESCRIPTION
        Aggregates an in-memory event array into one comparable baseline:
        events_total, scenarios, shapes, workers_total (distinct),
        reuse hits/misses + reuse_rate (hits/hits+misses, else $null),
        jev calls/fallbacks, retries, strategy_changes,
        progress_deltas_total, findings, interventions, dispatches,
        operations_avoided, stop_reasons, results, cost_proxy_tokens_total
        (proxy sum, declared), harness_level_all (every event harness),
        runtime_real_any (any event claiming runtime-real, must be
        $false). Bounded: at most 1000 events aggregated. Never throws;
        invalid input yields ok=$false.
    #>
    [CmdletBinding()]
    param($Events = @())
    try {
        $list = @()
        if ($null -ne $Events) {
            if (($Events -is [System.Collections.IDictionary]) -or ($Events -is [pscustomobject])) { $list = @($Events) }
            else { $list = @($Events) }
        }
        if ($list.Count -gt 1000) {
            return [pscustomobject]@{ ok = $false; reason = 'summary-too-many-events'; summary = $null }
        }
        $scenarios = @{}
        $shapes = @{}
        $workersSeen = @{}
        $workersTotal = [long]0
        $rh = [long]0
        $rm = [long]0
        $jc = [long]0
        $jf = [long]0
        $rt = [long]0
        $st = [long]0
        $pd = [long]0
        $fd = [long]0
        $iv = [long]0
        $dp = [long]0
        $oa = [long]0
        $stopReasons = @{}
        $results = @{}
        $costTotal = [long]0
        $harnessAll = $true
        $runtimeAny = $false
        $n = [long]0
        foreach ($e in $list) {
            if (($null -eq $e) -or ((-not ($e -is [System.Collections.IDictionary])) -and (-not ($e -is [pscustomobject])))) {
                return [pscustomobject]@{ ok = $false; reason = 'summary-invalid-event'; summary = $null }
            }
            if ([long](Get-OTNonNegativeLong (Get-OTField $e 'schema_version' $null) -1) -ne 1) {
                return [pscustomobject]@{ ok = $false; reason = 'summary-invalid-event-schema'; summary = $null }
            }
            $n++
            $s = [string](Get-OTField $e 'scenario' '')
            if (-not $scenarios.ContainsKey($s)) { $scenarios[$s] = [long]0 }
            $scenarios[$s] = [long]$scenarios[$s] + 1
            $h = [string](Get-OTField $e 'shape' '')
            if (-not $shapes.ContainsKey($h)) { $shapes[$h] = [long]0 }
            $shapes[$h] = [long]$shapes[$h] + 1
            foreach ($w in @(Get-OTField $e 'workers' @())) {
                $ws = ([string]$w).Trim()
                if ([string]::IsNullOrWhiteSpace($ws)) { continue }
                if (-not $workersSeen.ContainsKey($ws)) {
                    $workersSeen[$ws] = $true
                    $workersTotal++
                }
            }
            $rh += [long](Get-OTNonNegativeLong (Get-OTField $e 'reuse_hits' $null) 0)
            $rm += [long](Get-OTNonNegativeLong (Get-OTField $e 'reuse_misses' $null) 0)
            $jc += [long](Get-OTNonNegativeLong (Get-OTField $e 'jev_calls' $null) 0)
            $jf += [long](Get-OTNonNegativeLong (Get-OTField $e 'jev_fallbacks' $null) 0)
            $rt += [long](Get-OTNonNegativeLong (Get-OTField $e 'retries' $null) 0)
            $st += [long](Get-OTNonNegativeLong (Get-OTField $e 'strategy_changes' $null) 0)
            $pd += [long](Get-OTNonNegativeLong (Get-OTField $e 'progress_deltas' $null) 0)
            $fd += [long](Get-OTNonNegativeLong (Get-OTField $e 'findings' $null) 0)
            $iv += [long](Get-OTNonNegativeLong (Get-OTField $e 'interventions' $null) 0)
            $dp += [long](Get-OTNonNegativeLong (Get-OTField $e 'dispatches' $null) 0)
            $oa += [long](Get-OTNonNegativeLong (Get-OTField $e 'operations_avoided' $null) 0)
            $sr = [string](Get-OTField $e 'stop_reason' '')
            if (-not $stopReasons.ContainsKey($sr)) { $stopReasons[$sr] = [long]0 }
            $stopReasons[$sr] = [long]$stopReasons[$sr] + 1
            $rs = [string](Get-OTField $e 'result' '')
            if (-not $results.ContainsKey($rs)) { $results[$rs] = [long]0 }
            $results[$rs] = [long]$results[$rs] + 1
            $px = Get-OTField $e 'cost_proxy' $null
            $tok = [long](Get-OTNonNegativeLong (Get-OTField $px 'estimated_tokens' $null) 0)
            $costTotal += $tok
            try { if (-not [bool](Get-OTField $e 'harness_level' $false)) { $harnessAll = $false } } catch { $harnessAll = $false }
            try { if ([bool](Get-OTField $e 'runtime_real' $false)) { $runtimeAny = $true } } catch { }
        }
        $rate = $null
        if (($rh + $rm) -gt 0) {
            try { $rate = ([double]$rh / [double]($rh + $rm)) } catch { $rate = $null }
        }
        $summary = [pscustomobject][ordered]@{
            schema_version            = [long]1
            harness_level             = $true
            runtime_real              = $false
            events_total              = [long]$n
            scenarios                 = $scenarios
            shapes                    = $shapes
            workers_distinct          = [long]$workersTotal
            reuse_hits                = [long]$rh
            reuse_misses              = [long]$rm
            reuse_rate                = $rate
            jev_calls                 = [long]$jc
            jev_fallbacks             = [long]$jf
            retries                   = [long]$rt
            strategy_changes          = [long]$st
            progress_deltas_total     = [long]$pd
            findings                  = [long]$fd
            interventions             = [long]$iv
            dispatches                = [long]$dp
            operations_avoided        = [long]$oa
            stop_reasons              = $stopReasons
            results                   = $results
            cost_proxy_tokens_total   = [long]$costTotal
            cost_proxy_method         = 'chars-div-4-proxy'
            cost_proxy_is_proxy       = $true
            harness_level_all         = [bool]$harnessAll
            runtime_real_any          = [bool]$runtimeAny
        }
        return [pscustomobject]@{ ok = $true; reason = ''; summary = $summary }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'summary-internal'; summary = $null }
    }
}

function Get-OrchestrationObjectiveTelemetryBaseline {
    <#
    .SYNOPSIS
        Reads back one Goal JSONL file into a comparable baseline (PR-6).
    .DESCRIPTION
        Re-reads objective-<hash>.telemetry.jsonl for -GoalId under
        -StoreDir (bounded: at most MaxLines lines, default 500, cap
        1000; lines above 1MiB are skipped and reported via truncated)
        and aggregates via New-OrchestrationObjectiveTelemetrySummary.
        Missing file yields ok=$false 'telemetry-not-found' (fail-closed,
        never zeros-as-success). Never throws.
    #>
    [CmdletBinding()]
    param(
        [string]$GoalId = '',
        [string]$StoreDir = '',
        [long]$MaxLines = 500
    )
    try {
        $gid = ([string]$GoalId).Trim()
        if (-not (Test-OTGoalId $gid)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-goal-id'; summary = $null; lines = [long]0; truncated = $false }
        }
        $dir = ([string]$StoreDir).Trim()
        if ([string]::IsNullOrWhiteSpace($dir)) {
            return [pscustomobject]@{ ok = $false; reason = 'invalid-store-dir'; summary = $null; lines = [long]0; truncated = $false }
        }
        $cap = Get-OTNonNegativeLong $MaxLines 500
        if ($cap -lt 1) { $cap = 1 }
        if ($cap -gt 1000) { $cap = 1000 }
        $path = Get-OTTelemetryFilePath -Dir $dir -GoalId $gid
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return [pscustomobject]@{ ok = $false; reason = 'telemetry-not-found'; summary = $null; lines = [long]0; truncated = $false }
        }
        $events = New-Object System.Collections.ArrayList
        $lines = [long]0
        $truncated = $false
        $skipped = [long]0
        try {
            $sr = [IO.File]::OpenText($path)
            try {
                while ($true) {
                    $ln = $sr.ReadLine()
                    if ($null -eq $ln) { break }
                    if ($lines -ge $cap) { $truncated = $true; break }
                    if ([string]::IsNullOrWhiteSpace($ln)) { continue }
                    if ([Text.Encoding]::UTF8.GetByteCount($ln) -gt 1048576) {
                        $skipped++
                        $truncated = $true
                        continue
                    }
                    $ev = $null
                    try { $ev = ConvertFrom-Json $ln } catch { $ev = $null }
                    if ($null -eq $ev) {
                        return [pscustomobject]@{ ok = $false; reason = 'telemetry-line-invalid'; summary = $null; lines = $lines; truncated = $truncated }
                    }
                    [void]$events.Add($ev)
                    $lines++
                }
            }
            finally { try { $sr.Dispose() } catch { } }
        }
        catch {
            return [pscustomobject]@{ ok = $false; reason = 'telemetry-read-failed'; summary = $null; lines = $lines; truncated = $truncated }
        }
        $agg = New-OrchestrationObjectiveTelemetrySummary -Events @($events.ToArray())
        if (($null -eq $agg) -or (-not [bool]$agg.ok)) {
            $why = 'telemetry-aggregate-failed'
            try { if (($null -ne $agg) -and (-not [string]::IsNullOrWhiteSpace([string]$agg.reason))) { $why = [string]$agg.reason } } catch { }
            return [pscustomobject]@{ ok = $false; reason = $why; summary = $null; lines = $lines; truncated = $truncated }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; summary = $agg.summary; lines = $lines; truncated = [bool]$truncated; skipped_oversize = [long]$skipped }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'telemetry-internal'; summary = $null; lines = [long]0; truncated = $false }
    }
}
