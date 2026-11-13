# Deterministic shadow-only slow path. No provider, network, or kernel calls.
. (Join-Path $PSScriptRoot 'OrchestrationEventCorrelation.ps1')

function Get-SlowPathFieldLine {
    param([string]$Name, [string]$Value)
    $length = [Text.Encoding]::UTF8.GetByteCount($Value)
    return "$Name=$length`:$Value"
}

function Get-SlowPathArrayField {
    param($Node, [string]$Name)
    if ($null -eq $Node) { return $null }
    if ($Node -is [System.Collections.IDictionary]) {
        if (-not $Node.Contains($Name)) { return $null }
        return ,$Node[$Name]
    }
    $property = $Node.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return ,$property.Value
}

function Get-SlowPathCanonicalDocument {
    param($Request)
    $signals = @((Get-OrchestrationEventField $Request 'signals')) -join ','
    $classes = @((Get-OrchestrationEventField $Request 'classes')) -join ','
    $confidence = [string]::Format(
        [Globalization.CultureInfo]::InvariantCulture,
        '{0:F6}', [double](Get-OrchestrationEventField $Request 'min_confidence'))
    $rationaleLimit = [string]::Format(
        [Globalization.CultureInfo]::InvariantCulture,
        '{0}', [int](Get-OrchestrationEventField $Request 'max_rationale_chars'))
    $parts = @(
        (Get-SlowPathFieldLine 'version' ([string](Get-OrchestrationEventField $Request 'version'))),
        (Get-SlowPathFieldLine 'policy_version' ([string](Get-OrchestrationEventField $Request 'policy_version'))),
        (Get-SlowPathFieldLine 'dedup_key' ([string](Get-OrchestrationEventField $Request 'dedup_key'))),
        (Get-SlowPathFieldLine 'thread' ([string](Get-OrchestrationEventField $Request 'thread'))),
        (Get-SlowPathFieldLine 'trigger' ([string](Get-OrchestrationEventField $Request 'trigger'))),
        (Get-SlowPathFieldLine 'summary' ([string](Get-OrchestrationEventField $Request 'summary'))),
        (Get-SlowPathFieldLine 'signals' $signals),
        (Get-SlowPathFieldLine 'classes' $classes),
        (Get-SlowPathFieldLine 'max_rationale_chars' $rationaleLimit),
        (Get-SlowPathFieldLine 'min_confidence' $confidence)
    )
    return ($parts -join "`n")
}

function Get-SlowPathDigest {
    param($Request)
    # Digest detects corruption, not caller identity; HMAC/nonce await an external caller.
    $bytes = [Text.Encoding]::UTF8.GetBytes((Get-SlowPathCanonicalDocument $Request))
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Get-SlowPathRedactedText {
    param([string]$Text)
    $value = $Text
    $pem = '-----BEGIN [^\r\n]*PRIVATE KEY-----[\s\S]*?-----END [^\r\n]*PRIVATE KEY-----'
    $value = Invoke-SlowPathRegexReplace $value $pem '[REDACTED]' 'IgnoreCase'
    $unterminatedPem = '-----BEGIN [^\r\n]*PRIVATE KEY-----[\s\S]*\z'
    $value = Invoke-SlowPathRegexReplace $value $unterminatedPem '[REDACTED]' 'IgnoreCase'
    $prefixes = 'github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|' +
        'glpat-[A-Za-z0-9_-]{20,}|sk_live_[A-Za-z0-9]{16,}|' +
        'sk-[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|' +
        'xox[abposr]-[A-Za-z0-9-]{10,}|xapp-[A-Za-z0-9-]{10,}|npm_[A-Za-z0-9]{30,}'
    $value = Invoke-SlowPathRegexReplace $value $prefixes '[REDACTED]' 'IgnoreCase'
    $jwt = 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
    $value = Invoke-SlowPathRegexReplace $value $jwt '[REDACTED]' 'IgnoreCase'
    $auth = '(?i)(?<![A-Za-z0-9])(authorization|proxy-authorization)["'']?\s*[:=]\s*["'']?(?:bearer|basic|token|digest)?\s*("[^"]*"|''[^'']*''|[^\r\n]+)'
    $value = Invoke-SlowPathRegexReplace $value $auth 'Authorization=[REDACTED]' 'IgnoreCase'
    $key = '(?i)(?<![A-Za-z0-9])([A-Za-z0-9_.-]*' +
        '(?:api[_-]?key|access[_-]?token|token|secret|password|passwd|' +
        'credential|private[_-]?key|access[_-]?key)[A-Za-z0-9_.-]*)' +
        '["'']?\s*[:=]\s*("[^"]*"|''[^'']*''|[^\s,;&"'']+)'
    $value = Invoke-SlowPathRegexReplace $value $key '$1=[REDACTED]' 'IgnoreCase'
    $url = '(?i)\b([a-z][a-z0-9+.-]*://)[^/\s:@]+(:[^/\s@]*)?@'
    return Invoke-SlowPathRegexReplace $value $url '$1[REDACTED]@' 'IgnoreCase'
}

function Invoke-SlowPathRegexReplace {
    param([string]$Text, [string]$Pattern, [string]$Replacement, [string]$Options)
    $regexOptions = [Text.RegularExpressions.RegexOptions]::$Options
    try {
        return [regex]::Replace($Text, $Pattern, $Replacement, $regexOptions, [TimeSpan]::FromMilliseconds(250))
    } catch [TimeoutException] {
        return '[REDACTED]'
    }
}

function Limit-SlowPathText {
    param([string]$Text, [int]$Limit)
    if ($Text.Length -le $Limit) { return $Text }
    $end = $Limit
    if ($end -gt 0 -and [char]::IsHighSurrogate($Text[$end - 1]) -and
        [char]::IsLowSurrogate($Text[$end])) { $end-- }
    return $Text.Substring(0, $end)
}

function Test-SlowPathNumber {
    param($Value, [double]$Minimum = 0, [double]$Maximum = 1)
    if ($Value -is [bool] -or $Value -isnot [ValueType]) { return $false }
    if ($Value -isnot [int] -and $Value -isnot [long] -and $Value -isnot [double] -and $Value -isnot [decimal]) { return $false }
    $number = [double]$Value
    return (-not [double]::IsNaN($number) -and -not [double]::IsInfinity($number) -and
        $number -ge $Minimum -and $number -le $Maximum)
}

function Import-OrchestrationEventAdmissionSlowPathPolicy {
    <#
    .DESCRIPTION
    Strict policy root: all nine keys are mandatory, with no defaults.
    max_requests_per_* = 0 means no declared budget and therefore skip.
    #>
    [CmdletBinding()]
    param([string]$Path, [string]$RepoRoot, [int]$MaxBytes = 65536)
    $result = [ordered]@{ ok = $false; policy = $null; error = '' }
    $phase = 'path'
    try {
        if (-not $Path) {
            if (-not $RepoRoot) { $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path }
            $Path = Join-Path $RepoRoot 'source\registry\event-admission-slow-path-policy.json'
        }
        if ($Path -match '^[\\/]{2}' -or $Path -match '^FileSystem::') {
            $result.error = 'SLOWPATH_POLICY_PATH_INVALID'; return [pscustomobject]$result
        }
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            $result.error = 'SLOWPATH_POLICY_PATH_NOT_FOUND'; return [pscustomobject]$result
        }
        $full = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path)
        if ($full -match '^[\\/]{2}' -or $full -match '^FileSystem::') {
            $result.error = 'SLOWPATH_POLICY_PATH_INVALID'; return [pscustomobject]$result
        }
        $root = [IO.Path]::GetPathRoot($full)
        $cursor = $root
        foreach ($part in ($full.Substring($root.Length) -split '[\\/]')) {
            if (-not $part) { continue }
            $cursor = Join-Path $cursor $part
            $entry = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                $result.error = 'SLOWPATH_POLICY_PATH_INVALID'; return [pscustomobject]$result
            }
        }
        $file = Get-Item -LiteralPath $full -ErrorAction Stop
        if ($file.Length -gt $MaxBytes) {
            $result.error = 'SLOWPATH_POLICY_TOO_LARGE'; return [pscustomobject]$result
        }
        $raw = [IO.File]::ReadAllText($full, [Text.Encoding]::UTF8)
        $phase = 'parse'
        try { $doc = ConvertFrom-Json -InputObject $raw -ErrorAction Stop }
        catch { $result.error = 'SLOWPATH_POLICY_SCHEMA_INVALID'; return [pscustomobject]$result }

        $names = @('schema_version', 'policy_version', 'enabled', 'min_confidence',
            'max_summary_chars', 'max_rationale_chars', 'max_requests_per_day',
            'max_requests_per_thread', 'classes')
        foreach ($property in $doc.PSObject.Properties) {
            if ($property.Name -cnotin $names) {
                $result.error = 'SLOWPATH_POLICY_SCHEMA_INVALID'; return [pscustomobject]$result
            }
        }
        $schemaType = ($doc.schema_version -is [int] -or $doc.schema_version -is [long])
        if ($doc -isnot [pscustomobject] -or @($doc.PSObject.Properties).Count -ne 9 -or
            -not $schemaType -or $doc.schema_version -ne 1 -or
        $doc.policy_version -isnot [string] -or $doc.policy_version.Length -lt 1 -or
            $doc.policy_version.Length -gt 64 -or $doc.enabled -isnot [bool] -or
            -not (Test-SlowPathNumber $doc.min_confidence) -or
            $doc.classes -isnot [array] -or $doc.classes.Count -eq 0) {
            $result.error = 'SLOWPATH_POLICY_SCHEMA_INVALID'; return [pscustomobject]$result
        }
        foreach ($name in @('max_summary_chars', 'max_rationale_chars',
                'max_requests_per_day', 'max_requests_per_thread')) {
            $number = $doc.$name
            if (($number -isnot [int] -and $number -isnot [long]) -or $number -lt 0 -or $number -gt 100000) {
                $result.error = 'SLOWPATH_POLICY_SCHEMA_INVALID'; return [pscustomobject]$result
            }
        }
        $seen = @{}
        foreach ($class in $doc.classes) {
            if ($class -isnot [string] -or $class -cnotin @('candidate', 'context_only', 'ignore') -or $seen.ContainsKey($class)) {
                $result.error = 'SLOWPATH_POLICY_SCHEMA_INVALID'; return [pscustomobject]$result
            }
            $seen[$class] = $true
        }
        $result.ok = $true
        $result.policy = [pscustomobject][ordered]@{
            policy_version = $doc.policy_version; enabled = $doc.enabled
            min_confidence = [double]$doc.min_confidence
            max_summary_chars = [int]$doc.max_summary_chars
            max_rationale_chars = [int]$doc.max_rationale_chars
            max_requests_per_day = [int]$doc.max_requests_per_day
            max_requests_per_thread = [int]$doc.max_requests_per_thread
            classes = @($doc.classes)
        }
    } catch {
        if ($phase -eq 'parse') { $result.error = 'SLOWPATH_POLICY_SCHEMA_INVALID' }
        else { $result.error = 'SLOWPATH_POLICY_PATH_INVALID' }
    }
    return [pscustomobject]$result
}

function Test-SlowPathPolicyObject {
    param($Policy)
    if ($null -eq $Policy) { return $false }
    $required = @('policy_version', 'enabled', 'min_confidence', 'max_summary_chars',
        'max_rationale_chars', 'max_requests_per_day', 'max_requests_per_thread', 'classes')
    $names = if ($Policy -is [System.Collections.IDictionary]) { @($Policy.Keys) }
        else { @($Policy.PSObject.Properties | ForEach-Object { $_.Name }) }
    if ($names.Count -ne $required.Count) { return $false }
    foreach ($name in $required) { if ($names -cnotcontains $name) { return $false } }
    if ((Get-OrchestrationEventField $Policy 'policy_version') -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string](Get-OrchestrationEventField $Policy 'policy_version')) -or
        (Get-OrchestrationEventField $Policy 'policy_version').Length -gt 64 -or
        (Get-OrchestrationEventField $Policy 'enabled') -isnot [bool] -or
        -not (Test-SlowPathNumber (Get-OrchestrationEventField $Policy 'min_confidence'))) { return $false }
    foreach ($name in @('max_summary_chars', 'max_rationale_chars', 'max_requests_per_day', 'max_requests_per_thread')) {
        $value = Get-OrchestrationEventField $Policy $name
        if (($value -isnot [int] -and $value -isnot [long]) -or $value -lt 0 -or $value -gt 100000) { return $false }
    }
    $classes = Get-OrchestrationEventField $Policy 'classes'
    if ($classes -isnot [array] -or $classes.Count -eq 0) { return $false }
    $seen = @{}
    foreach ($class in $classes) {
        if ($class -isnot [string] -or $class -cnotin @('candidate', 'context_only', 'ignore') -or $seen.ContainsKey($class)) { return $false }
        $seen[$class] = $true
    }
    return $true
}

function Request-OrchestrationEventAdmissionSlowPath {
    [CmdletBinding()]
    param($Envelope, $Context, $FastResult, $Policy, $UsageState = $null)
    $out = [ordered]@{ ok = $true; decision = 'skip'; reason = 'invalid-fast-result'; request = $null; shadow = $true; executable = $false }
    try {
        # Validate the policy object before reading any policy-controlled field.
        if (-not (Test-SlowPathPolicyObject $Policy)) { $out.ok = $false; $out.reason = 'invalid-policy'; return [pscustomobject]$out }
        if (-not $Policy.enabled) { $out.reason = 'policy-disabled'; return [pscustomobject]$out }

        # Fast-result shape and signals are trusted only after strict validation.
        $fastOk = Get-OrchestrationEventField $FastResult 'ok'
        $intent = Get-OrchestrationEventField $FastResult 'intent'
        $signals = Get-SlowPathArrayField $FastResult 'signals'
        if ($fastOk -isnot [bool] -or -not $fastOk -or
            $intent -cnotin @('explicit', 'candidate', 'context_only', 'ignore') -or
            $signals -isnot [array] -or $signals.Count -gt 16) {
            $out.ok = $false; $out.reason = 'invalid-fast-result'; return [pscustomobject]$out
        }
        foreach ($signal in $signals) {
            if ($signal -isnot [string] -or $signal -cnotmatch '^[a-z0-9_:-]{1,64}\z') {
                $out.ok = $false; $out.reason = 'invalid-fast-result'; return [pscustomobject]$out
            }
        }
        if ($intent -cne 'context_only') { $out.reason = 'not-ambiguous:' + $intent; return [pscustomobject]$out }

        # Context flags must be present strict booleans; malformed data cannot admit.
        foreach ($flag in @('source_allowlisted', 'blocklisted', 'duplicate')) {
            if ((Get-OrchestrationEventField $Context $flag) -isnot [bool]) {
                $out.ok = $false; $out.reason = 'invalid-context'; return [pscustomobject]$out
            }
        }
        $actor = Get-OrchestrationEventField $Context 'actor_type'
        if ($actor -isnot [string] -or [string]::IsNullOrWhiteSpace($actor)) {
            $out.ok = $false; $out.reason = 'invalid-context'; return [pscustomobject]$out
        }
        if ($actor -ceq 'bot') { $out.reason = 'bot'; return [pscustomobject]$out }
        if ($Context.blocklisted) { $out.reason = 'blocklisted'; return [pscustomobject]$out }
        if ($Context.duplicate) { $out.reason = 'duplicate'; return [pscustomobject]$out }

        # Normalize envelope fields locally; never trust a caller-supplied dedup key.
        $info = Get-OrchestrationEventField $Envelope 'informational_only'
        if ($info -isnot [bool]) { $out.ok = $false; $out.reason = 'invalid-envelope'; return [pscustomobject]$out }
        if ($info) { $out.reason = 'informational-only'; return [pscustomobject]$out }
        if ($actor -ceq 'unknown') { $out.reason = 'unknown-actor'; return [pscustomobject]$out }
        if ($actor -cne 'human') { $out.reason = 'non-human-actor'; return [pscustomobject]$out }
        if (-not $Context.source_allowlisted) { $out.reason = 'source-not-allowlisted'; return [pscustomobject]$out }
        foreach ($field in @('source', 'trigger', 'thread', 'delivery_id', 'repo')) {
            $value = Get-OrchestrationEventField $Envelope $field
            if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
                $out.ok = $false; $out.reason = 'invalid-envelope'; return [pscustomobject]$out
            }
        }
        $normalized = New-OrchestrationEventEnvelope `
            -Source ([string](Get-OrchestrationEventField $Envelope 'source')) `
            -Trigger ([string](Get-OrchestrationEventField $Envelope 'trigger')) `
            -Thread ([string](Get-OrchestrationEventField $Envelope 'thread')) `
            -DeliveryId ([string](Get-OrchestrationEventField $Envelope 'delivery_id')) `
            -Repo ([string](Get-OrchestrationEventField $Envelope 'repo')) `
            -InformationalOnly $info `
            -Summary ([string](Get-OrchestrationEventField $Envelope 'summary'))
        if (-not $normalized.ok) { $out.ok = $false; $out.reason = 'invalid-envelope'; return [pscustomobject]$out }

        # Usage counters are strict integers and zero budgets never mean unlimited.
        if ($null -eq $UsageState) { $out.reason = 'usage-cap'; return [pscustomobject]$out }
        $today = Get-OrchestrationEventField $UsageState 'requests_today'
        $threadUsage = Get-OrchestrationEventField $UsageState 'requests_for_thread'
        foreach ($counter in @($today, $threadUsage)) {
            if (($counter -isnot [int] -and $counter -isnot [long]) -or $counter -lt 0) {
                $out.ok = $false; $out.reason = 'invalid-usage'; return [pscustomobject]$out
            }
        }
        if ($Policy.max_requests_per_day -eq 0 -or $Policy.max_requests_per_thread -eq 0 -or
            $today -ge $Policy.max_requests_per_day -or $threadUsage -ge $Policy.max_requests_per_thread) {
            $out.reason = 'usage-cap'; return [pscustomobject]$out
        }

        # Redact before truncation so truncation cannot expose the end of a secret.
        $summary = Get-SlowPathRedactedText ([string]$normalized.summary)
        $summary = Limit-SlowPathText $summary $Policy.max_summary_chars
        $request = [ordered]@{
            version = 1
            policy_version = [string]$Policy.policy_version
            dedup_key = [string]$normalized.dedup_key
            thread = [string]$normalized.thread
            trigger = [string]$normalized.trigger
            summary = $summary
            signals = @($signals)
            classes = @($Policy.classes)
            max_rationale_chars = [int]$Policy.max_rationale_chars
            min_confidence = [double]$Policy.min_confidence
        }
        $request.request_digest = Get-SlowPathDigest $request
        $out.decision = 'request'; $out.reason = 'ambiguous'; $out.request = [pscustomobject]$request
    } catch { $out.ok = $false; $out.reason = 'internal-error' }
    return [pscustomobject]$out
}

function Invoke-OrchestrationEventAdmissionSlowPathResponseCore {
    [CmdletBinding()]
    param($Request, $Response, $Policy)
    $out = [ordered]@{ ok = $false; intent = 'ignore'; action = 'ignore'; reason = 'SLOWPATH_RESPONSE_INVALID'; error = ''; source = 'slow-path'; shadow = $true; executable = $false }
    if (-not (Test-SlowPathPolicyObject $Policy)) { $out.error = 'SLOWPATH_POLICY_INVALID'; return [pscustomobject]$out }
    if (-not $Policy.enabled) { $out.reason = 'policy-disabled'; $out.error = 'SLOWPATH_POLICY_DISABLED'; return [pscustomobject]$out }
    if ($null -eq $Request -or $null -eq $Response) { return [pscustomobject]$out }

    # Digest is integrity, not authenticity; HMAC/nonce need an external caller.
    # Exact request keys prevent omitted or attacker-added fields being ignored.
    $expected = @('version', 'policy_version', 'dedup_key', 'thread', 'trigger', 'summary',
        'signals', 'classes', 'max_rationale_chars', 'min_confidence', 'request_digest')
    $names = if ($Request -is [System.Collections.IDictionary]) { @($Request.Keys) }
        else { @($Request.PSObject.Properties | ForEach-Object { $_.Name }) }
    if ($names.Count -ne $expected.Count) { $out.error = 'SLOWPATH_REQUEST_INVALID'; return [pscustomobject]$out }
    foreach ($name in $expected) {
        if ($names -cnotcontains $name) { $out.error = 'SLOWPATH_REQUEST_INVALID'; return [pscustomobject]$out }
    }
    $version = Get-OrchestrationEventField $Request 'version'
    $policyVersion = Get-OrchestrationEventField $Request 'policy_version'
    $dedup = Get-OrchestrationEventField $Request 'dedup_key'
    $thread = Get-OrchestrationEventField $Request 'thread'
    $trigger = Get-OrchestrationEventField $Request 'trigger'
    $summary = Get-OrchestrationEventField $Request 'summary'
    $signals = Get-SlowPathArrayField $Request 'signals'
    $classes = Get-SlowPathArrayField $Request 'classes'
    $rationaleLimit = Get-OrchestrationEventField $Request 'max_rationale_chars'
    $confidence = Get-OrchestrationEventField $Request 'min_confidence'
    if (($version -isnot [int] -and $version -isnot [long]) -or $version -ne 1 -or
        $policyVersion -isnot [string] -or $policyVersion.Length -lt 1 -or $policyVersion.Length -gt 64 -or
        $dedup -isnot [string] -or $dedup -cnotmatch '^[0-9a-f]{64}\z' -or
        $thread -isnot [string] -or $thread -cnotmatch '^(pr|issue|branch):\S{1,200}\z' -or
        $trigger -isnot [string] -or $trigger -cnotin @('issue_comment', 'pull_request_review', 'ci_status', 'push') -or
        $summary -isnot [string] -or $summary.Length -gt $Policy.max_summary_chars -or
        $signals -isnot [array] -or $signals.Count -gt 16 -or
        $classes -isnot [array] -or $classes.Count -eq 0 -or
        ($rationaleLimit -isnot [int] -and $rationaleLimit -isnot [long]) -or
        $rationaleLimit -lt 1 -or $rationaleLimit -gt 100000 -or
        -not (Test-SlowPathNumber $confidence)) {
        $out.error = 'SLOWPATH_REQUEST_INVALID'; return [pscustomobject]$out
    }
    foreach ($signal in $signals) {
        if ($signal -isnot [string] -or $signal -cnotmatch '^[a-z0-9_:-]{1,64}\z') {
            $out.error = 'SLOWPATH_REQUEST_INVALID'; return [pscustomobject]$out
        }
    }
    foreach ($class in $classes) {
        if ($class -isnot [string] -or $class -cnotin @('candidate', 'context_only', 'ignore')) {
            $out.error = 'SLOWPATH_REQUEST_INVALID'; return [pscustomobject]$out
        }
    }
    if ($policyVersion -cne $Policy.policy_version -or
        (($classes -join "`n") -cne (@($Policy.classes) -join "`n")) -or
        $rationaleLimit -ne $Policy.max_rationale_chars -or
        [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:F6}', [double]$confidence) -cne
        [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:F6}', [double]$Policy.min_confidence)) {
        $out.error = 'SLOWPATH_POLICY_DRIFT'; return [pscustomobject]$out
    }
    $digest = Get-SlowPathDigest $Request
    if ((Get-OrchestrationEventField $Request 'request_digest') -cnotmatch '^[0-9a-f]{64}\z' -or
        (Get-OrchestrationEventField $Request 'request_digest') -cne $digest) {
        $out.error = 'SLOWPATH_DIGEST_MISMATCH'; return [pscustomobject]$out
    }

    $allowedResponse = @('request_digest', 'classification', 'confidence', 'rationale', 'provider', 'model')
    $responseNames = if ($Response -is [System.Collections.IDictionary]) { @($Response.Keys) }
        else { @($Response.PSObject.Properties | ForEach-Object { $_.Name }) }
    foreach ($name in $responseNames) {
        if ($name -cnotin $allowedResponse) { $out.error = 'SLOWPATH_RESPONSE_INVALID'; return [pscustomobject]$out }
    }
    $class = Get-OrchestrationEventField $Response 'classification'
    if ($class -isnot [string] -or $class -cnotin $classes) { $out.error = 'SLOWPATH_CLASS_INVALID'; return [pscustomobject]$out }
    $responseDigest = Get-OrchestrationEventField $Response 'request_digest'
    if ($responseDigest -isnot [string] -or $responseDigest -cne $digest) {
        $out.error = 'SLOWPATH_DIGEST_MISMATCH'; return [pscustomobject]$out
    }
    $responseConfidence = Get-OrchestrationEventField $Response 'confidence'
    if (($responseConfidence -isnot [int] -and $responseConfidence -isnot [long] -and $responseConfidence -isnot [double]) -or
        -not (Test-SlowPathNumber $responseConfidence)) {
        $out.error = 'SLOWPATH_CONFIDENCE_INVALID'; return [pscustomobject]$out
    }
    $rationale = Get-OrchestrationEventField $Response 'rationale'
    if ($rationale -isnot [string] -or $rationale.Length -gt $Policy.max_rationale_chars) {
        $out.error = 'SLOWPATH_RATIONALE_INVALID'; return [pscustomobject]$out
    }
    foreach ($name in @('provider', 'model')) {
        $metadata = Get-OrchestrationEventField $Response $name
        if ($null -ne $metadata -and ($metadata -isnot [string] -or $metadata.Length -gt 100)) {
            $out.error = 'SLOWPATH_METADATA_INVALID'; return [pscustomobject]$out
        }
    }
    $rationale = Limit-SlowPathText (Get-SlowPathRedactedText $rationale) $Policy.max_rationale_chars
    $out.ok = $true; $out.error = ''; $out.classification = $class
    $out.confidence = [double]$responseConfidence; $out.rationale = $rationale
    $out.rationale_trust = 'untrusted-external'
    if ([double]$responseConfidence -lt $Policy.min_confidence) {
        $out.intent = 'context_only'; $out.action = 'observe'; $out.reason = 'low-confidence'
    } else {
        $out.intent = $class; $out.reason = 'classified'
        $out.action = switch ($class) { 'candidate' { 'would_new_task' } 'context_only' { 'observe' } default { 'ignore' } }
    }
    return [pscustomobject]$out
}

function Test-OrchestrationEventAdmissionSlowPathResponse {
    [CmdletBinding()]
    param($Request, $Response, $Policy)
    try {
        return Invoke-OrchestrationEventAdmissionSlowPathResponseCore `
            -Request $Request -Response $Response -Policy $Policy
    } catch {
        return [pscustomobject][ordered]@{
            ok = $false; intent = 'ignore'; action = 'ignore'
            reason = 'SLOWPATH_RESPONSE_INVALID'; error = 'SLOWPATH_RESPONSE_INVALID'
            source = 'slow-path'; shadow = $true; executable = $false
        }
    }
}
