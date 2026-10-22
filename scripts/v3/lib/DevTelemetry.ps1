<#!
.SYNOPSIS
    Dev telemetry lib: local aggregate-only dev metrics (slice 1).
.DESCRIPTION
    Dot-sourceable library (no execution on load). Local-only dev telemetry:
    normalized JSONL events under cache/v3/telemetry/dev, pure snapshot
    aggregation, and JSON+MD export to cache/v3/dev-metrics (plus explicit
    publish to evidence/dev-telemetry). No network, no OTEL, no SQLite.
    Every telemetry-path function never throws and never writes to stdout.
    PowerShell 5.1 compatible. ASCII-only on purpose.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-DevTelemetryRepoRoot {
    [CmdletBinding()]
    param([string]$RepoRoot)
    try {
        if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { return $RepoRoot }
        return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
    }
    catch { return '' }
}

function Get-DevTelemetryTimestamp {
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

function Test-DevTelemetrySecretText {
    [CmdletBinding()]
    param([string]$Text)
    try {
        $s = [string]$Text
        if ([string]::IsNullOrEmpty($s)) { return $false }
        if ($s -match 'sk-[A-Za-z0-9]') { return $true }
        if ($s -match 'ghp_|gho_|github_pat_') { return $true }
        if ($s -match 'AKIA[0-9A-Z]') { return $true }
        if ($s -match '(?i)bearer\s+[A-Za-z0-9]') { return $true }
        if ($s -match '-----BEGIN [A-Z ]*PRIVATE KEY') { return $true }
        if ($s -match '(?i)(password|passwd|secret|api[_-]?key|client_secret|access_token|refresh_token)\s*[:=]') { return $true }
    }
    catch { }
    return $false
}

function Get-DevTelemetryToken {
    [CmdletBinding()]
    param([string]$Text, [string]$Pattern)
    try {
        $s = ([string]$Text).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { return '' }
        if ($s.Length -gt 64) { return '' }
        if (Test-DevTelemetrySecretText -Text $s) { return '' }
        if ($s -cmatch $Pattern) { return $s }
    }
    catch { }
    return ''
}

function Get-DevTelemetryKind {
    [CmdletBinding()]
    param([string]$Kind)
    try {
        $s = ([string]$Kind).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($s)) { return '' }
        $allowed = @('suite_result', 'gate_result', 'preflight_decision', 'plugin_health', 'review_outcome')
        if ($allowed -ccontains $s) { return $s }
    }
    catch { }
    return ''
}

function Get-DevTelemetryVerdict {
    [CmdletBinding()]
    param([string]$Verdict)
    try {
        $s = ([string]$Verdict).Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($s)) { return '' }
        $allowed = @('PASS', 'FAIL', 'SKIP', 'ERROR', 'APPROVED', 'CHANGES_REQUIRED', 'UNKNOWN')
        if ($allowed -ccontains $s) { return $s }
    }
    catch { }
    return ''
}

function Get-DevTelemetrySeverity {
    [CmdletBinding()]
    param([string]$Severity)
    try {
        $s = ([string]$Severity).Trim().ToUpperInvariant()
        if (@('NONE','LOW','MEDIUM','HIGH','CRITICAL') -ccontains $s) { return $s }
    } catch { }
    return ''
}

function Get-DevTelemetryEngine {
    [CmdletBinding()]
    param([string]$Engine)
    try {
        $s = ([string]$Engine).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($s)) { return '' }
        if (($s -ceq 'ps51') -or ($s -ceq 'ps7') -or ($s -ceq 'unknown')) { return $s }
    }
    catch { }
    return ''
}

function Get-DevTelemetryInt {
    [CmdletBinding()]
    param($Value, [int]$Min, [int]$Max, [int]$Default)
    try {
        if ($null -eq $Value) { return $Default }
        if ($Value -is [bool]) { return $Default }
        if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) { return $Default }
        $n = 0
        try { $n = [int]$Value }
        catch { return $Default }
        if ($n -lt $Min) { return $Min }
        if ($n -gt $Max) { return $Max }
        return $n
    }
    catch { return $Default }
}

function ConvertTo-DevTelemetryAgents {
    [CmdletBinding()]
    param($Agents)
    $out = New-Object System.Collections.Generic.List[string]
    try {
        if ($null -eq $Agents) { return ([string[]]@()) }
        $items = @($Agents)
        if (($items.Count -eq 1) -and ($items[0] -is [System.Collections.IEnumerable]) -and (-not ($items[0] -is [string]))) {
            try { $items = @($items[0]) } catch { }
        }
        foreach ($v in $items) {
            if ($out.Count -ge 8) { break }
            if ($null -eq $v) { continue }
            if ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) { continue }
            $t = Get-DevTelemetryToken -Text ([string]$v) -Pattern '^[a-z0-9][a-z0-9._-]{0,63}$'
            if ([string]::IsNullOrWhiteSpace($t)) { continue }
            $out.Add($t) | Out-Null
        }
    }
    catch { }
    return ([string[]]$out.ToArray())
}

function ConvertTo-DevTelemetryMap {
    [CmdletBinding()]
    param($InputObject, [bool]$AllowBool)
    $clean = [ordered]@{}
    try {
        if ($null -eq $InputObject) { return $clean }
        $pairs = @()
        try {
            if ($InputObject -is [System.Collections.IDictionary]) {
                foreach ($k in @($InputObject.Keys)) { $pairs += ,@([string]$k, $InputObject[$k]) }
            }
            else {
                foreach ($p in @($InputObject.PSObject.Properties)) { $pairs += ,@([string]$p.Name, $p.Value) }
            }
        }
        catch { return $clean }
        $sorted = @($pairs | Sort-Object { [string]$_[0] })
        $kept = 0
        foreach ($pair in $sorted) {
            if ($kept -ge 8) { break }
            $k = ([string]$pair[0]).Trim().ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($k)) { continue }
            if ($k -cnotmatch '^[a-z][a-z0-9_]{0,31}$') { continue }
            if (Test-DevTelemetrySecretText -Text $k) { continue }
            $v = $pair[1]
            if ($null -eq $v) { continue }
            if ($v -is [bool]) {
                if ($AllowBool) { $clean[$k] = [bool]$v; $kept++ }
                continue
            }
            if ($v -is [string] -and [string]::IsNullOrWhiteSpace($v)) { continue }
            if ($v -is [string] -and (Test-DevTelemetrySecretText -Text ([string]$v))) { continue }
            $n = $null
            try {
                if ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [string]) {
                    $d = 0.0
                    if ([double]::TryParse([string]$v, [ref]$d)) {
                        $n = [int][Math]::Floor($d)
                        if ($n -lt 0) { $n = 0 }
                        if ($n -gt 1000000) { $n = 1000000 }
                    }
                }
            }
            catch { $n = $null }
            if ($null -eq $n) { continue }
            $clean[$k] = [int]$n
            $kept++
        }
    }
    catch { }
    return $clean
}

function New-DevTelemetryEvent {
    [CmdletBinding()]
    param(
        [string]$Kind = '',
        [string]$Source = '',
        [string]$Suite = '',
        [string]$Verdict = '',
        $ExitCode = $null,
        $DurationMs = $null,
        $Counts = $null,
        $Metrics = $null,
        [string]$Decision = '',
        [string]$TaskClass = '',
        [string]$Risk = '',
        $Agents = $null,
        [string]$FallbackReason = '',
        [string]$Engine = '',
        [string]$Detail = '',
        [string]$Timestamp = '',
        [string]$Severity = ''
    )
    try {
        $k = Get-DevTelemetryKind -Kind $Kind
        if ([string]::IsNullOrWhiteSpace($k)) { return $null }
        $src = Get-DevTelemetryToken -Text $Source -Pattern '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'
        if ([string]::IsNullOrWhiteSpace($src)) { return $null }
        $ev = [ordered]@{
            schema    = 1
            timestamp = (Get-DevTelemetryTimestamp -Timestamp $Timestamp)
            kind      = $k
            source    = $src
        }
        $suiteClean = Get-DevTelemetryToken -Text $Suite -Pattern '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
        if (-not [string]::IsNullOrWhiteSpace($suiteClean)) { $ev['suite'] = $suiteClean }
        $verClean = Get-DevTelemetryVerdict -Verdict $Verdict
        if (-not [string]::IsNullOrWhiteSpace($verClean)) { $ev['verdict'] = $verClean }
        $severityClean = Get-DevTelemetrySeverity -Severity $Severity
        if (-not [string]::IsNullOrWhiteSpace($severityClean)) { $ev['severity'] = $severityClean }
        if ($null -ne $ExitCode -and -not ($ExitCode -is [bool])) {
            try {
                $ecStr = ([string]$ExitCode).Trim()
                if (-not [string]::IsNullOrWhiteSpace($ecStr)) {
                    $ec = 0
                    if ([int]::TryParse($ecStr, [ref]$ec)) {
                        if ($ec -lt -1) { $ec = -1 }
                        if ($ec -gt 9999) { $ec = 9999 }
                        $ev['exit_code'] = [int]$ec
                    }
                }
            }
            catch { }
        }
        if ($null -ne $DurationMs -and -not ($DurationMs -is [bool])) {
            try {
                $dmStr = ([string]$DurationMs).Trim()
                if (-not [string]::IsNullOrWhiteSpace($dmStr)) {
                    $dm = 0
                    if ([int]::TryParse($dmStr, [ref]$dm)) {
                        if ($dm -lt 0) { $dm = 0 }
                        if ($dm -gt 86400000) { $dm = 86400000 }
                        $ev['duration_ms'] = [int]$dm
                    }
                }
            }
            catch { }
        }
        try {
            if ($null -ne $Counts) {
                $c = ConvertTo-DevTelemetryMap -InputObject $Counts -AllowBool $false
                if ($c.Count -gt 0) { $ev['counts'] = $c }
            }
        }
        catch { }
        try {
            if ($null -ne $Metrics) {
                $m = ConvertTo-DevTelemetryMap -InputObject $Metrics -AllowBool $true
                if ($m.Count -gt 0) { $ev['metrics'] = $m }
            }
        }
        catch { }
        $decClean = Get-DevTelemetryToken -Text $Decision -Pattern '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'
        if (-not [string]::IsNullOrWhiteSpace($decClean)) { $ev['decision'] = $decClean }
        $tcClean = Get-DevTelemetryToken -Text $TaskClass -Pattern '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'
        if (-not [string]::IsNullOrWhiteSpace($tcClean)) { $ev['task_class'] = $tcClean }
        $riskClean = Get-DevTelemetryToken -Text $Risk -Pattern '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'
        if (-not [string]::IsNullOrWhiteSpace($riskClean)) { $ev['risk'] = $riskClean }
        try {
            if ($null -ne $Agents) {
                $ag = @(ConvertTo-DevTelemetryAgents -Agents $Agents)
                if (@($ag).Count -gt 0) { $ev['agents'] = ([string[]]$ag) }
            }
        }
        catch { }
        $fbClean = Get-DevTelemetryToken -Text $FallbackReason -Pattern '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'
        if (-not [string]::IsNullOrWhiteSpace($fbClean)) { $ev['fallback_reason'] = $fbClean }
        $engClean = Get-DevTelemetryEngine -Engine $Engine
        if (-not [string]::IsNullOrWhiteSpace($engClean)) { $ev['engine'] = $engClean }
        $detClean = Get-DevTelemetryToken -Text $Detail -Pattern '^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$'
        if (-not [string]::IsNullOrWhiteSpace($detClean)) { $ev['detail'] = $detClean }
        return ([PSCustomObject]$ev)
    }
    catch { return $null }
}

function Test-DevTelemetryConfinedPath {
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

function Test-DevTelemetryConfinedInside {
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

function Test-DevTelemetryReparse {
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

function Get-DevTelemetryFullPath {
    [CmdletBinding()]
    param([string]$Path, [string]$RepoRoot)
    try {
        if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
        return [IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
    }
    catch { return $Path }
}

function Write-DevTelemetryFileAtomic {
    [CmdletBinding()]
    param([string]$Dest = '', [string]$Content = '', [string]$AllowedDir = '', [string]$RepoRoot = '', $Encoding = $null)
    $tmp = ''
    $backup = ''
    try {
        if ([string]::IsNullOrWhiteSpace($Dest)) { return $false }
        if ($null -eq $Content) { return $false }
        if ([string]::IsNullOrWhiteSpace($AllowedDir)) { return $false }
        if ([string]::IsNullOrWhiteSpace($RepoRoot)) { return $false }
        if (-not (Test-DevTelemetryConfinedPath -Path $Dest -AllowedDir $AllowedDir -RepoRoot $RepoRoot)) { return $false }
        $full = Get-DevTelemetryFullPath -Path $Dest -RepoRoot $RepoRoot
        try {
            $full = [IO.Path]::GetFullPath($full)
            $base = [IO.Path]::GetFullPath($AllowedDir)
            $sep = $base.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            if (-not $full.StartsWith($sep, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        }
        catch { return $false }
        if (Test-DevTelemetryReparse -Path $full) { return $false }
        try {
            if ((Test-Path -LiteralPath $full) -and (-not (Test-Path -LiteralPath $full -PathType Leaf))) { return $false }
        }
        catch { return $false }
        $parent = Split-Path -Parent $full
        if ([string]::IsNullOrWhiteSpace($parent)) { return $false }
        try {
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                if (Test-DevTelemetryReparse -Path $parent) { return $false }
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
        }
        catch { return $false }
        if (Test-DevTelemetryReparse -Path $parent) { return $false }
        $enc = $Encoding
        if ($null -eq $enc) { $enc = [Text.UTF8Encoding]::new($false) }
        $tmp = Join-Path $parent ('.' + [IO.Path]::GetFileName($full) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
        $backup = Join-Path $parent ('.' + [IO.Path]::GetFileName($full) + '.' + [guid]::NewGuid().ToString('N') + '.bak')
        try {
            $tmpFull = [IO.Path]::GetFullPath($tmp)
            $bakFull = [IO.Path]::GetFullPath($backup)
            $base2 = [IO.Path]::GetFullPath($AllowedDir)
            $sep2 = $base2.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            if (-not $tmpFull.StartsWith($sep2, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
            if (-not $bakFull.StartsWith($sep2, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        }
        catch { return $false }
        try { [IO.File]::WriteAllText($tmp, $Content, $enc) }
        catch { return $false }
        if (Test-DevTelemetryReparse -Path $tmp) { return $false }
        try {
            if ((Test-Path -LiteralPath $tmp) -and (-not (Test-Path -LiteralPath $tmp -PathType Leaf))) { return $false }
        }
        catch { return $false }
        if (Test-DevTelemetryReparse -Path $backup) { return $false }
        $destExists = $false
        try { $destExists = (Test-Path -LiteralPath $full -PathType Leaf) }
        catch { $destExists = $false }
        try {
            if ((Test-Path -LiteralPath $full) -and (-not (Test-Path -LiteralPath $full -PathType Leaf))) { return $false }
        }
        catch { return $false }
        if ($destExists) {
            if (Test-DevTelemetryReparse -Path $full) { return $false }
            try {
                [IO.File]::Replace($tmp, $full, $backup) | Out-Null
                $tmp = ''
            }
            catch {
                $ex = $_.Exception
                $isFnf = $false
                try {
                    $cur = $ex
                    while ($null -ne $cur) {
                        if ($cur -is [System.IO.FileNotFoundException]) { $isFnf = $true; break }
                        $cur = $cur.InnerException
                    }
                }
                catch { $isFnf = $false }
                $gone = $false
                try { $gone = -not (Test-Path -LiteralPath $full -PathType Leaf) }
                catch { $gone = $false }
                if ($isFnf -and $gone) {
                    try {
                        [IO.File]::Move($tmp, $full) | Out-Null
                        $tmp = ''
                        try {
                            if (Test-Path -LiteralPath $backup -PathType Leaf) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue | Out-Null }
                        }
                        catch { }
                        $backup = ''
                        return $true
                    }
                    catch { return $false }
                }
                return $false
            }
            try {
                if ((-not [string]::IsNullOrWhiteSpace($backup)) -and (Test-Path -LiteralPath $backup -PathType Leaf)) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue | Out-Null }
            }
            catch { }
            $backup = ''
        }
        else {
            try {
                [IO.File]::Move($tmp, $full) | Out-Null
                $tmp = ''
            }
            catch { return $false }
        }
        return $true
    }
    catch { return $false }
    finally {
        try {
            if ((-not [string]::IsNullOrWhiteSpace($tmp)) -and (Test-Path -LiteralPath $tmp -PathType Leaf)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue | Out-Null }
        }
        catch { }
        try {
            if ((-not [string]::IsNullOrWhiteSpace($backup)) -and (Test-Path -LiteralPath $backup -PathType Leaf)) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue | Out-Null }
        }
        catch { }
    }
}

function Get-DevTelemetryNodeProp {
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

function Write-DevTelemetryEvent {
    [CmdletBinding()]
    param(
        $Event = $null,
        [string]$Kind = '',
        [string]$Source = '',
        [string]$Suite = '',
        [string]$Verdict = '',
        $ExitCode = $null,
        $DurationMs = $null,
        $Counts = $null,
        $Metrics = $null,
        [string]$Decision = '',
        [string]$TaskClass = '',
        [string]$Risk = '',
        $Agents = $null,
        [string]$FallbackReason = '',
        [string]$Engine = '',
        [string]$Detail = '',
        [string]$Timestamp = '',
        [string]$Severity = '',
        [string]$RepoRoot = '',
        [string]$TelemetryPath = ''
    )
    $mutex = $null
    $acquired = $false
    try {
        $repo = Get-DevTelemetryRepoRoot -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($repo)) { return $false }
        $allowedDir = Join-Path $repo 'cache\v3\telemetry\dev'
        $target = $TelemetryPath
        if ([string]::IsNullOrWhiteSpace($target)) {
            $stamp = ([DateTimeOffset]::UtcNow.ToString('yyyyMMdd'))
            $target = Join-Path $allowedDir ('dev-' + $stamp + '.jsonl')
        }
        if (-not (Test-DevTelemetryConfinedPath -Path $target -AllowedDir $allowedDir -RepoRoot $repo)) { return $false }
        $full = Get-DevTelemetryFullPath -Path $target -RepoRoot $repo
        if (Test-DevTelemetryReparse -Path $full) { return $false }
        try {
            if ((Test-Path -LiteralPath $full) -and -not (Test-Path -LiteralPath $full -PathType Leaf)) { return $false }
        }
        catch { return $false }
        $norm = $null
        try {
            if ($null -ne $Event) {
                $norm = (New-DevTelemetryEvent `
                    -Kind ([string](Get-DevTelemetryNodeProp -Node $Event -Name 'kind')) `
                    -Source ([string](Get-DevTelemetryNodeProp -Node $Event -Name 'source')) `
                    -Suite ([string](Get-DevTelemetryNodeProp -Node $Event -Name 'suite')) `
                    -Verdict ([string](Get-DevTelemetryNodeProp -Node $Event -Name 'verdict')) `
                    -ExitCode (Get-DevTelemetryNodeProp -Node $Event -Name 'exit_code') `
                    -DurationMs (Get-DevTelemetryNodeProp -Node $Event -Name 'duration_ms') `
                    -Counts (Get-DevTelemetryNodeProp -Node $Event -Name 'counts') `
                    -Metrics (Get-DevTelemetryNodeProp -Node $Event -Name 'metrics') `
                    -Decision ([string](Get-DevTelemetryNodeProp -Node $Event -Name 'decision')) `
                    -TaskClass ([string](Get-DevTelemetryNodeProp -Node $Event -Name 'task_class')) `
                    -Risk ([string](Get-DevTelemetryNodeProp -Node $Event -Name 'risk')) `
                    -Agents (Get-DevTelemetryNodeProp -Node $Event -Name 'agents') `
                    -FallbackReason ([string](Get-DevTelemetryNodeProp -Node $Event -Name 'fallback_reason')) `
                    -Engine ([string](Get-DevTelemetryNodeProp -Node $Event -Name 'engine')) `
                    -Detail ([string](Get-DevTelemetryNodeProp -Node $Event -Name 'detail')) `
                    -Timestamp ([string](Get-DevTelemetryNodeProp -Node $Event -Name 'timestamp')) `
                    -Severity ([string](Get-DevTelemetryNodeProp -Node $Event -Name 'severity')))
                if ($null -eq $norm -and $null -ne (Get-DevTelemetryNodeProp -Node $Event -Name 'Kind')) {
                    $norm = (New-DevTelemetryEvent `
                        -Kind ([string](Get-DevTelemetryNodeProp -Node $Event -Name 'Kind')) `
                        -Source ([string](Get-DevTelemetryNodeProp -Node $Event -Name 'Source')) `
                        -Suite ([string](Get-DevTelemetryNodeProp -Node $Event -Name 'Suite')) `
                        -Verdict ([string](Get-DevTelemetryNodeProp -Node $Event -Name 'Verdict')) `
                        -ExitCode (Get-DevTelemetryNodeProp -Node $Event -Name 'ExitCode') `
                        -DurationMs (Get-DevTelemetryNodeProp -Node $Event -Name 'DurationMs') `
                        -Counts (Get-DevTelemetryNodeProp -Node $Event -Name 'Counts') `
                        -Metrics (Get-DevTelemetryNodeProp -Node $Event -Name 'Metrics') `
                        -Decision ([string](Get-DevTelemetryNodeProp -Node $Event -Name 'Decision')) `
                        -TaskClass ([string](Get-DevTelemetryNodeProp -Node $Event -Name 'TaskClass')) `
                        -Risk ([string](Get-DevTelemetryNodeProp -Node $Event -Name 'Risk')) `
                        -Agents (Get-DevTelemetryNodeProp -Node $Event -Name 'Agents') `
                        -FallbackReason ([string](Get-DevTelemetryNodeProp -Node $Event -Name 'FallbackReason')) `
                        -Engine ([string](Get-DevTelemetryNodeProp -Node $Event -Name 'Engine')) `
                        -Detail ([string](Get-DevTelemetryNodeProp -Node $Event -Name 'Detail')) `
                        -Timestamp ([string](Get-DevTelemetryNodeProp -Node $Event -Name 'Timestamp')) `
                        -Severity ([string](Get-DevTelemetryNodeProp -Node $Event -Name 'Severity')))
                }
            }
            else {
                $norm = (New-DevTelemetryEvent -Kind $Kind -Source $Source -Suite $Suite -Verdict $Verdict -ExitCode $ExitCode -DurationMs $DurationMs -Counts $Counts -Metrics $Metrics -Decision $Decision -TaskClass $TaskClass -Risk $Risk -Agents $Agents -FallbackReason $FallbackReason -Engine $Engine -Detail $Detail -Timestamp $Timestamp -Severity $Severity)
            }
        }
        catch { $norm = $null }
        if ($null -eq $norm) { return $false }
        $text = ''
        try { $text = ($norm | ConvertTo-Json -Depth 10 -Compress) }
        catch { return $false }
        if ([string]::IsNullOrWhiteSpace($text)) { return $false }
        if (Test-DevTelemetrySecretText -Text $text) { return $false }
        $text = ($text -replace "`r`n", "" -replace "`r", "" -replace "`n", "")
        try {
            $parent = Split-Path -Parent $full
            if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        }
        catch { return $false }
        try {
            $mutex = New-Object System.Threading.Mutex($false, 'Global\DevTelemetryDevJsonl')
            try { $acquired = $mutex.WaitOne(0) }
            catch { $acquired = $false }
            if (-not $acquired) { return $false }
            [IO.File]::AppendAllText($full, ($text + "`n"), [Text.UTF8Encoding]::new($false))
            try { Invoke-DevTelemetryRetentionIfDue -RepoRoot $repo | Out-Null } catch { }
            return $true
        }
        catch { return $false }
        finally {
            try {
                if ($acquired -and $null -ne $mutex) { $mutex.ReleaseMutex() | Out-Null }
            } catch { }
        }
    }
    catch { return $false }
    finally {
        try { if ($null -ne $mutex) { $mutex.Dispose() } } catch { }
    }
}

function Read-DevTelemetryEvents {
    [CmdletBinding()]
    param([string]$RepoRoot = '', $SinceDays = 30, [string]$Now = '')
    $out = New-Object System.Collections.ArrayList
    try {
        $days = 30
        try {
            $days = [int]$SinceDays
            if ($days -lt 1) { $days = 30 }
            if ($days -gt 3650) { $days = 3650 }
        }
        catch { $days = 30 }
        $repo = Get-DevTelemetryRepoRoot -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($repo)) { return @() }
        $nowInstant = [DateTimeOffset]::UtcNow
        try {
            if (-not [string]::IsNullOrWhiteSpace($Now)) {
                $probeNow = [DateTimeOffset]::MinValue
                if ([DateTimeOffset]::TryParse($Now, [ref]$probeNow)) { $nowInstant = $probeNow.ToUniversalTime() }
            }
        }
        catch { }
        $allowedDir = Join-Path $repo 'cache\v3\telemetry\dev'
        if (-not (Test-Path -LiteralPath $allowedDir -PathType Container)) { return @() }
        try {
            if (Test-DevTelemetryReparse -Path ([IO.Path]::GetFullPath($allowedDir))) { return @() }
        }
        catch { }
        $files = @()
        try { $files = @(Get-ChildItem -LiteralPath $allowedDir -Filter 'dev-*.jsonl' -File -Force -ErrorAction Stop | Sort-Object { $_.Name } | Select-Object -Last 31) }
        catch { return @() }
        $cutoff = ($nowInstant.AddDays(-[double]$days))
        $maxBytes = 4194304
        foreach ($f in $files) {
            try {
                if (-not (Test-DevTelemetryConfinedPath -Path $f.FullName -AllowedDir $allowedDir -RepoRoot $repo)) { continue }
                if (Test-DevTelemetryReparse -Path $f.FullName) { continue }
                $content = ''
                try {
                    $fs = New-Object System.IO.FileStream($f.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                    try {
                        $cap = $maxBytes
                        $ms = New-Object System.IO.MemoryStream
                        try {
                            $chunk = New-Object byte[] 65536
                            $total = 0
                            while ($total -lt $cap) {
                                $want = 65536
                                if (($total + $want) -gt $cap) { $want = ($cap - $total) }
                                $read = $fs.Read($chunk, 0, $want)
                                if ($read -le 0) { break }
                                $ms.Write($chunk, 0, $read)
                                $total += $read
                                if ($read -lt $want) { break }
                            }
                        }
                        finally { try { $ms.Close() } catch { } }
                        $arr = $null
                        try { $arr = $ms.ToArray() } catch { $arr = $null }
                        if (($null -eq $arr) -or ($arr.Length -le 0)) { continue }
                        $truncated = $false
                        try { $truncated = (($total -ge $cap) -and ($fs.Position -lt $fs.Length)) }
                        catch { $truncated = $false }
                        if ($truncated) {
                            $cut = -1
                            for ($i = ($arr.Length - 1); $i -ge 0; $i--) {
                                if ($arr[$i] -eq 10) { $cut = $i; break }
                            }
                            if ($cut -lt 0) { continue }
                            $trimmed = New-Object byte[] ($cut + 1)
                            [Array]::Copy($arr, 0, $trimmed, 0, ($cut + 1))
                            $arr = $trimmed
                        }
                        if (($null -eq $arr) -or ($arr.Length -le 0)) { continue }
                        $content = [Text.Encoding]::UTF8.GetString($arr)
                    }
                    finally { try { $fs.Close() } catch { } try { $fs.Dispose() } catch { } }
                }
                catch { continue }
                if ([string]::IsNullOrWhiteSpace($content)) { continue }
                $lines = $content -split "`n"
                foreach ($ln in $lines) {
                    try {
                        $t = ([string]$ln).Trim()
                        if ([string]::IsNullOrWhiteSpace($t)) { continue }
                        $obj = $null
                        try { $obj = ($t | ConvertFrom-Json) } catch { continue }
                        if ($null -eq $obj) { continue }
                        $schRaw = Get-DevTelemetryNodeProp -Node $obj -Name 'schema'
                        if ($null -eq $schRaw) { continue }
                        if (-not (($schRaw -is [int]) -or ($schRaw -is [long]))) { continue }
                        $schOk = $false
                        try { $schOk = ([long]$schRaw -eq 1) } catch { continue }
                        if (-not $schOk) { continue }
                        $tsRawObj = [string](Get-DevTelemetryNodeProp -Node $obj -Name 'timestamp')
                        if ([string]::IsNullOrWhiteSpace($tsRawObj)) { continue }
                        $preParsed = [DateTimeOffset]::MinValue
                        if (-not [DateTimeOffset]::TryParse($tsRawObj, [ref]$preParsed)) { continue }
                        $norm = $null
                        try {
                            $norm = (New-DevTelemetryEvent `
                                -Kind ([string](Get-DevTelemetryNodeProp -Node $obj -Name 'kind')) `
                                -Source ([string](Get-DevTelemetryNodeProp -Node $obj -Name 'source')) `
                                -Suite ([string](Get-DevTelemetryNodeProp -Node $obj -Name 'suite')) `
                                -Verdict ([string](Get-DevTelemetryNodeProp -Node $obj -Name 'verdict')) `
                                -ExitCode (Get-DevTelemetryNodeProp -Node $obj -Name 'exit_code') `
                                -DurationMs (Get-DevTelemetryNodeProp -Node $obj -Name 'duration_ms') `
                                -Counts (Get-DevTelemetryNodeProp -Node $obj -Name 'counts') `
                                -Metrics (Get-DevTelemetryNodeProp -Node $obj -Name 'metrics') `
                                -Decision ([string](Get-DevTelemetryNodeProp -Node $obj -Name 'decision')) `
                                -TaskClass ([string](Get-DevTelemetryNodeProp -Node $obj -Name 'task_class')) `
                                -Risk ([string](Get-DevTelemetryNodeProp -Node $obj -Name 'risk')) `
                                -Agents (Get-DevTelemetryNodeProp -Node $obj -Name 'agents') `
                                -FallbackReason ([string](Get-DevTelemetryNodeProp -Node $obj -Name 'fallback_reason')) `
                                -Engine ([string](Get-DevTelemetryNodeProp -Node $obj -Name 'engine')) `
                                -Detail ([string](Get-DevTelemetryNodeProp -Node $obj -Name 'detail')) `
                                -Severity ([string](Get-DevTelemetryNodeProp -Node $obj -Name 'severity')) `
                                -Timestamp $tsRawObj)
                        }
                        catch { $norm = $null; continue }
                        if ($null -eq $norm) { continue }
                        $parsed = $preParsed
                        if ($parsed.ToUniversalTime() -lt $cutoff) { continue }
                        [void]$out.Add($norm)
                    }
                    catch { continue }
                }
            }
            catch { continue }
        }
        return @($out.ToArray())
    }
    catch { return @($out.ToArray()) }
}

function Invoke-DevTelemetryRetention {
    [CmdletBinding()]
    param([string]$RepoRoot = '', $RetentionDays = 30)
    try {
        $repo = Get-DevTelemetryRepoRoot -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($repo)) { return $null }
        try {
            $hasFn = (Get-Command 'Remove-ExpiredObservability' -ErrorAction SilentlyContinue)
            if ($null -eq $hasFn) {
                $obsPath = Join-Path $repo 'scripts\v3\lib\CapabilityObservability.ps1'
                if (Test-Path -LiteralPath $obsPath -PathType Leaf) {
                    . $obsPath
                }
            }
        }
        catch { }
        $days = 30
        try {
            $days = [int]$RetentionDays
            if ($days -lt 1) { $days = 30 }
            if ($days -gt 365) { $days = 365 }
        }
        catch { $days = 30 }
        $teleDir = Join-Path $repo 'cache\v3\telemetry\dev'
        try {
            $fn = Get-Command 'Remove-ExpiredObservability' -ErrorAction SilentlyContinue
            if ($null -ne $fn) {
                return (Remove-ExpiredObservability -TelemetryDir $teleDir -RetentionDays $days -RepoRoot $repo)
            }
        }
        catch { }
        return $null
    }
    catch { return $null }
}

function Invoke-DevTelemetryRetentionIfDue {
    [CmdletBinding()]
    param([string]$RepoRoot = '')
    try {
        $repo = Get-DevTelemetryRepoRoot -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($repo)) { return $false }
        $allowedDir = Join-Path $repo 'cache\v3\telemetry\dev'
        $stamp = ([DateTimeOffset]::UtcNow.ToString('yyyyMMdd'))
        $marker = Join-Path $allowedDir ('.retention-' + $stamp)
        if (-not (Test-DevTelemetryConfinedPath -Path $marker -AllowedDir $allowedDir -RepoRoot $repo)) { return $false }
        $full = Get-DevTelemetryFullPath -Path $marker -RepoRoot $repo
        if (Test-DevTelemetryReparse -Path $full) { return $false }
        try {
            if (Test-Path -LiteralPath $full -PathType Leaf) { return $true }
            if ((Test-Path -LiteralPath $full) -and (-not (Test-Path -LiteralPath $full -PathType Leaf))) { return $false }
        }
        catch { return $false }
        $ret = $null
        try { $ret = Invoke-DevTelemetryRetention -RepoRoot $repo -RetentionDays 30 }
        catch { return $false }
        try {
            if ($null -eq $ret) { return $false }
            $retErr = [string](Get-DevTelemetryNodeProp -Node $ret -Name 'Error')
            if (-not [string]::IsNullOrWhiteSpace($retErr)) { return $false }
        }
        catch { return $false }
        try {
            $parent = Split-Path -Parent $full
            if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        }
        catch { return $false }
        if (Test-DevTelemetryReparse -Path $full) { return $false }
        try { [IO.File]::WriteAllText($full, '', [Text.UTF8Encoding]::new($false)) }
        catch { return $false }
        return $true
    }
    catch { return $false }
}

function Get-DevTelemetryPercentile {
    [CmdletBinding()]
    param([long[]]$Values, [int]$Percent)
    try {
        $arr = @($Values | Sort-Object)
        $n = $arr.Count
        if ($n -le 0) { return 0 }
        if ($Percent -lt 1) { $Percent = 1 }
        if ($Percent -gt 100) { $Percent = 100 }
        $rank = [int][Math]::Ceiling(([double]$Percent / 100.0) * [double]$n)
        if ($rank -lt 1) { $rank = 1 }
        if ($rank -gt $n) { $rank = $n }
        return ([long]$arr[$rank - 1])
    }
    catch { return 0 }
}

function Get-DevTelemetryRate {
    [CmdletBinding()]
    param([int]$Num, [int]$Den)
    try {
        if ($Den -le 0) { return 0.0 }
        return ([Math]::Round(([double]$Num / [double]$Den), 4))
    }
    catch { return 0.0 }
}

function New-DevTelemetrySnapshot {
    [CmdletBinding()]
    param($Events = @(), [int]$WindowDays = 30, [string]$GeneratedAt = '')
    try {
        $wd = 30
        try {
            $wd = [int]$WindowDays
            if ($wd -lt 1) { $wd = 30 }
            if ($wd -gt 3650) { $wd = 3650 }
        }
        catch { $wd = 30 }
        $gen = Get-DevTelemetryTimestamp -Timestamp $GeneratedAt
        $items = @()
        try { $items = @($Events) } catch { $items = @() }
        $count = 0
        $firstTs = ''
        $lastTs = ''
        $minT = [DateTimeOffset]::MaxValue
        $maxT = [DateTimeOffset]::MinValue
        $dates = @{}
        $suiteGroups = @{}
        $gatePass = 0
        $gateFail = 0
        $gateReports = 0
        $checksTotal = 0
        $checksFail = 0
        $preTotal = 0
        $preByDecision = @{}
        $preByTaskClass = @{}
        $preByRisk = @{}
        $preAgents = @{}
        $preFallback = 0
        $plugReports = 0
        $plugLatest = $null
        $plugLatestTs = [DateTimeOffset]::MinValue
        $revTotal = 0
        $revApproved = 0
        $revChanges = 0
        $revBySource = @{}
        $revBySeverity = @{}
        $revHighCritical = 0
        foreach ($e in $items) {
            try {
                if ($null -eq $e) { continue }
                $kind = ([string](Get-DevTelemetryNodeProp -Node $e -Name 'kind')).Trim().ToLowerInvariant()
                if ([string]::IsNullOrWhiteSpace($kind)) { continue }
                $tsRaw = [string](Get-DevTelemetryNodeProp -Node $e -Name 'timestamp')
                $parsed = [DateTimeOffset]::MinValue
                if (-not [DateTimeOffset]::TryParse($tsRaw, [ref]$parsed)) { continue }
                $pu = $parsed.ToUniversalTime()
                $count++
                if ($pu -lt $minT) { $minT = $pu }
                if ($pu -gt $maxT) { $maxT = $pu }
                $dates[$pu.ToString('yyyyMMdd')] = $true
                if ($kind -ceq 'suite_result') {
                    $suite = ([string](Get-DevTelemetryNodeProp -Node $e -Name 'suite')).Trim()
                    if ([string]::IsNullOrWhiteSpace($suite)) { $suite = 'unknown' }
                    if (-not $suiteGroups.ContainsKey($suite)) {
                        $suiteGroups[$suite] = New-Object System.Collections.ArrayList
                    }
                    $vd = ([string](Get-DevTelemetryNodeProp -Node $e -Name 'verdict')).Trim().ToUpperInvariant()
                    $dm = 0
                    try {
                        $dmRaw = Get-DevTelemetryNodeProp -Node $e -Name 'duration_ms'
                        if ($null -ne $dmRaw) { $dm = [long]$dmRaw }
                        if ($dm -lt 0) { $dm = 0 }
                    }
                    catch { $dm = 0 }
                    [void]$suiteGroups[$suite].Add([PSCustomObject]@{ verdict = $vd; duration_ms = [long]$dm; ts = $pu; ts_raw = $tsRaw })
                }
                elseif ($kind -ceq 'gate_result') {
                    $gateReports++
                    $vd = ([string](Get-DevTelemetryNodeProp -Node $e -Name 'verdict')).Trim().ToUpperInvariant()
                    if ($vd -ceq 'PASS') { $gatePass++ }
                    elseif ($vd -ceq 'FAIL') { $gateFail++ }
                    $cn = Get-DevTelemetryNodeProp -Node $e -Name 'counts'
                    if ($null -ne $cn) {
                        $tp = Get-DevTelemetryNodeProp -Node $cn -Name 'total'
                        $pp = Get-DevTelemetryNodeProp -Node $cn -Name 'pass'
                        $fp = Get-DevTelemetryNodeProp -Node $cn -Name 'fail'
                        $tN = 0
                        $fN = 0
                        try { if ($null -ne $tp) { $tN = [int]$tp } } catch { $tN = 0 }
                        try { if ($null -ne $pp) { $pNv = [int]$pp } else { $pNv = 0 } } catch { $pNv = 0 }
                        try { if ($null -ne $fp) { $fN = [int]$fp } } catch { $fN = 0 }
                        if ($tN -le 0) { $tN = ($pNv + $fN) }
                        if ($tN -lt 0) { $tN = 0 }
                        if ($fN -lt 0) { $fN = 0 }
                        $checksTotal += $tN
                        $checksFail += $fN
                    }
                }
                elseif ($kind -ceq 'preflight_decision') {
                    $preTotal++
                    $dec = ([string](Get-DevTelemetryNodeProp -Node $e -Name 'decision')).Trim()
                    if ([string]::IsNullOrWhiteSpace($dec)) { $dec = 'unknown' }
                    if (-not $preByDecision.ContainsKey($dec)) { $preByDecision[$dec] = 0 }
                    $preByDecision[$dec] = ([int]$preByDecision[$dec] + 1)
                    $tc = ([string](Get-DevTelemetryNodeProp -Node $e -Name 'task_class')).Trim()
                    if (-not [string]::IsNullOrWhiteSpace($tc)) {
                        if (-not $preByTaskClass.ContainsKey($tc)) { $preByTaskClass[$tc] = 0 }
                        $preByTaskClass[$tc] = ([int]$preByTaskClass[$tc] + 1)
                    }
                    $rk = ([string](Get-DevTelemetryNodeProp -Node $e -Name 'risk')).Trim()
                    if (-not [string]::IsNullOrWhiteSpace($rk)) {
                        if (-not $preByRisk.ContainsKey($rk)) { $preByRisk[$rk] = 0 }
                        $preByRisk[$rk] = ([int]$preByRisk[$rk] + 1)
                    }
                    $fb = ([string](Get-DevTelemetryNodeProp -Node $e -Name 'fallback_reason')).Trim()
                    if (-not [string]::IsNullOrWhiteSpace($fb)) { $preFallback++ }
                    $agRaw = Get-DevTelemetryNodeProp -Node $e -Name 'agents'
                    foreach ($a in @($agRaw)) {
                        $an = ([string]$a).Trim()
                        if ([string]::IsNullOrWhiteSpace($an)) { continue }
                        if (-not $preAgents.ContainsKey($an)) { $preAgents[$an] = 0 }
                        $preAgents[$an] = ([int]$preAgents[$an] + 1)
                    }
                }
                elseif ($kind -ceq 'plugin_health') {
                    $plugReports++
                    if ($pu -ge $plugLatestTs) {
                        $plugLatestTs = $pu
                        $plugLatest = $e
                    }
                }
                elseif ($kind -ceq 'review_outcome') {
                    $revTotal++
                    $src = ([string](Get-DevTelemetryNodeProp -Node $e -Name 'source')).Trim()
                    if ([string]::IsNullOrWhiteSpace($src)) { $src = 'unknown' }
                    if (-not $revBySource.ContainsKey($src)) { $revBySource[$src] = 0 }
                    $revBySource[$src]++
                    $sev = Get-DevTelemetrySeverity -Severity ([string](Get-DevTelemetryNodeProp -Node $e -Name 'severity'))
                    if ([string]::IsNullOrWhiteSpace($sev)) { $sev = 'UNSPECIFIED' }
                    if (-not $revBySeverity.ContainsKey($sev)) { $revBySeverity[$sev] = 0 }
                    $revBySeverity[$sev]++
                    if ($sev -ceq 'HIGH' -or $sev -ceq 'CRITICAL') { $revHighCritical++ }
                    $vd = ([string](Get-DevTelemetryNodeProp -Node $e -Name 'verdict')).Trim().ToUpperInvariant()
                    if ($vd -ceq 'APPROVED') { $revApproved++ }
                    elseif ($vd -ceq 'CHANGES_REQUIRED') { $revChanges++ }
                }
            }
            catch { continue }
        }
        if ($count -gt 0) {
            $firstTs = $minT.ToString('o')
            $lastTs = $maxT.ToString('o')
        }
        $suiteRuns = 0
        $suitePass = 0
        $suiteFail = 0
        $suiteSkip = 0
        $suiteError = 0
        $suitesList = New-Object System.Collections.ArrayList
        $flakyList = New-Object System.Collections.ArrayList
        foreach ($name in @($suiteGroups.Keys | Sort-Object)) {
            try {
                $rows = @($suiteGroups[$name] | Sort-Object { $_.ts })
                $runs = $rows.Count
                $p = @($rows | Where-Object { $_.verdict -ceq 'PASS' }).Count
                $fl = @($rows | Where-Object { $_.verdict -ceq 'FAIL' }).Count
                $sk = @($rows | Where-Object { $_.verdict -ceq 'SKIP' }).Count
                $er = @($rows | Where-Object { $_.verdict -ceq 'ERROR' }).Count
                $suiteRuns += $runs
                $suitePass += $p
                $suiteFail += $fl
                $suiteSkip += $sk
                $suiteError += $er
                $durs = @($rows | ForEach-Object { [long]$_.duration_ms })
                $p50 = Get-DevTelemetryPercentile -Values $durs -Percent 50
                $p95 = Get-DevTelemetryPercentile -Values $durs -Percent 95
                $trans = 0
                for ($i = 1; $i -lt $rows.Count; $i++) {
                    $prev = ([string]$rows[$i - 1].verdict).ToUpperInvariant()
                    $cur = ([string]$rows[$i].verdict).ToUpperInvariant()
                    if ((($prev -ceq 'FAIL') -or ($prev -ceq 'ERROR')) -and ($cur -ceq 'PASS')) {
                        $trans++
                        [void]$flakyList.Add([PSCustomObject]@{
                            suite        = [string]$name
                            from_verdict = [string]$prev
                            to_verdict   = 'PASS'
                            from_ts      = [string]$rows[$i - 1].ts_raw
                            to_ts        = [string]$rows[$i].ts_raw
                        })
                    }
                }
                [void]$suitesList.Add([PSCustomObject]@{
                    suite             = [string]$name
                    runs              = [int]$runs
                    pass              = [int]$p
                    fail              = [int]$fl
                    skip              = [int]$sk
                    error             = [int]$er
                    pass_rate         = (Get-DevTelemetryRate -Num $p -Den ($p + $fl + $er))
                    p50_ms            = [long]$p50
                    p95_ms            = [long]$p95
                    flaky_transitions = [int]$trans
                })
            }
            catch { continue }
        }
        $flakySorted = @($flakyList.ToArray() | Sort-Object { $_.suite }, { $_.to_ts })
        $slowest = @($suitesList.ToArray() | Sort-Object { $_.p95_ms } -Descending | Select-Object -First 5)
        $byDec = [ordered]@{}
        foreach ($kk in @($preByDecision.Keys | Sort-Object)) { $byDec[$kk] = [int]$preByDecision[$kk] }
        $byTc = [ordered]@{}
        foreach ($kk in @($preByTaskClass.Keys | Sort-Object)) { $byTc[$kk] = [int]$preByTaskClass[$kk] }
        $byRk = [ordered]@{}
        foreach ($kk in @($preByRisk.Keys | Sort-Object)) { $byRk[$kk] = [int]$preByRisk[$kk] }
        $byAg = [ordered]@{}
        foreach ($kk in @($preAgents.Keys | Sort-Object)) { $byAg[$kk] = [int]$preAgents[$kk] }
        $revSrcSorted = [ordered]@{}
        foreach ($kk in @($revBySource.Keys | Sort-Object)) { $revSrcSorted[$kk] = [int]$revBySource[$kk] }
        $revSevSorted = [ordered]@{}
        foreach ($kk in @($revBySeverity.Keys | Sort-Object)) { $revSevSorted[$kk] = [int]$revBySeverity[$kk] }
        $plugOverall = ''
        $plugLoad = 0
        $plugExp = 0
        $plugTele = 0
        $plugPresent = 0
        if ($null -ne $plugLatest) {
            try {
                $plugOverall = ([string](Get-DevTelemetryNodeProp -Node $plugLatest -Name 'verdict')).Trim().ToUpperInvariant()
                $pm = Get-DevTelemetryNodeProp -Node $plugLatest -Name 'metrics'
                if ($null -ne $pm) {
                    try { $plugLoad = [int](Get-DevTelemetryNodeProp -Node $pm -Name 'load_errors') } catch { $plugLoad = 0 }
                    try { $plugExp = [int](Get-DevTelemetryNodeProp -Node $pm -Name 'expected_load_errors') } catch { $plugExp = 0 }
                    try { $plugTele = [int](Get-DevTelemetryNodeProp -Node $pm -Name 'telemetry_present') } catch { $plugTele = 0 }
                    try { $plugPresent = [int](Get-DevTelemetryNodeProp -Node $pm -Name 'plugins_present') } catch { $plugPresent = 0 }
                }
            }
            catch { }
        }
        $snap = [PSCustomObject]@{
            generated_at = [string]$gen
            window_days  = [int]$wd
            raw          = [PSCustomObject]@{
                events   = [int]$count
                files    = [int]@($dates.Keys).Count
                first_ts = [string]$firstTs
                last_ts  = [string]$lastTs
            }
            totals       = [PSCustomObject]@{
                suite_runs = [int]$suiteRuns
                pass       = [int]$suitePass
                fail       = [int]$suiteFail
                skip       = [int]$suiteSkip
                error      = [int]$suiteError
                pass_rate  = (Get-DevTelemetryRate -Num $suitePass -Den ($suitePass + $suiteFail + $suiteError))
            }
            suites       = @($suitesList.ToArray() | Sort-Object { $_.suite })
            flaky        = @($flakySorted)
            slowest      = @($slowest)
            preflight    = [PSCustomObject]@{
                total          = [int]$preTotal
                by_decision    = ([PSCustomObject]$byDec)
                fallback_rate  = (Get-DevTelemetryRate -Num $preFallback -Den $preTotal)
                by_task_class  = ([PSCustomObject]$byTc)
                by_risk        = ([PSCustomObject]$byRk)
                agents         = ([PSCustomObject]$byAg)
            }
            plugin       = [PSCustomObject]@{
                reports                      = [int]$plugReports
                latest_overall               = [string]$plugOverall
                latest_load_errors           = [int]$plugLoad
                latest_expected_load_errors  = [int]$plugExp
                latest_telemetry_present     = [int]$plugTele
                latest_plugins_present       = [int]$plugPresent
            }
            review       = [PSCustomObject]@{
                total            = [int]$revTotal
                approved         = [int]$revApproved
                changes_required = [int]$revChanges
                by_source        = ([PSCustomObject]$revSrcSorted)
                by_severity      = ([PSCustomObject]$revSevSorted)
                high_or_critical = [int]$revHighCritical
            }
            gates        = [PSCustomObject]@{
                reports      = [int]$gateReports
                pass         = [int]$gatePass
                fail         = [int]$gateFail
                checks_total = [int]$checksTotal
                checks_fail  = [int]$checksFail
            }
        }
        return $snap
    }
    catch { return $null }
}

function Get-DevTelemetryIsoWeekFile {
    [CmdletBinding()]
    param([string]$Timestamp)
    try {
        $parsed = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse($Timestamp, [ref]$parsed)) {
            $parsed = [DateTimeOffset]::UtcNow
        }
        $local = $parsed.ToUniversalTime().DateTime.Date
        $isoDow = 0
        if ($local.DayOfWeek -ceq [DayOfWeek]::Sunday) { $isoDow = 7 } else { $isoDow = [int]$local.DayOfWeek }
        $thursday = $local.AddDays((4 - $isoDow))
        $isoYear = $thursday.Year
        $jan4 = New-Object DateTime($isoYear, 1, 4)
        $jan4IsoDow = 0
        if ($jan4.DayOfWeek -ceq [DayOfWeek]::Sunday) { $jan4IsoDow = 7 } else { $jan4IsoDow = [int]$jan4.DayOfWeek }
        $week = (1 + [int][Math]::Floor((($thursday - $jan4).TotalDays + ($jan4IsoDow - 1)) / 7.0))
        $ww = ([string]$week).PadLeft(2, '0')
        return ([string]$isoYear + '-W' + $ww)
    }
    catch { return 'unknown' }
}

function Export-DevTelemetrySnapshot {
    [CmdletBinding()]
    param([string]$RepoRoot = '', [int]$WindowDays = 30, [switch]$Publish, [string]$Now = '')
    try {
        $repo = Get-DevTelemetryRepoRoot -RepoRoot $RepoRoot
        if ([string]::IsNullOrWhiteSpace($repo)) { return $null }
        $wd = 30
        try {
            $wd = [int]$WindowDays
            if ($wd -lt 1) { $wd = 30 }
            if ($wd -gt 3650) { $wd = 3650 }
        }
        catch { $wd = 30 }
        $gen = Get-DevTelemetryTimestamp -Timestamp $Now
        $events = @()
        try { $events = @(Read-DevTelemetryEvents -RepoRoot $repo -SinceDays $wd -Now $gen) }
        catch { $events = @() }
        $snap = $null
        try { $snap = New-DevTelemetrySnapshot -Events $events -WindowDays $wd -GeneratedAt $gen }
        catch { $snap = $null }
        if ($null -eq $snap) {
            $snap = New-DevTelemetrySnapshot -Events @() -WindowDays $wd -GeneratedAt $gen
        }
        if ($null -eq $snap) { return $null }
        $doc = [ordered]@{
            schema       = 1
            note         = 'generated by scripts/dev-telemetry-report.ps1; aggregate only; nothing leaves this machine'
            generated_at = [string]$snap.generated_at
            window_days  = [int]$snap.window_days
            raw          = $snap.raw
            totals       = $snap.totals
            suites       = @($snap.suites)
            flaky        = @($snap.flaky)
            slowest      = @($snap.slowest)
            preflight    = $snap.preflight
            plugin       = $snap.plugin
            review       = $snap.review
            gates        = $snap.gates
        }
        $json = ''
        try { $json = ($doc | ConvertTo-Json -Depth 12) }
        catch { return $null }
        $jsonLf = (($json -replace "`r`n", "`n") -replace "`r", "`n")
        if (-not $jsonLf.EndsWith("`n")) { $jsonLf = ($jsonLf + "`n") }
        $md = ''
        try { $md = (New-DevTelemetryMarkdown -Snapshot $snap) }
        catch { $md = "# dev-telemetry`n`nno data`n" }
        $mdLf = (($md -replace "`r`n", "`n") -replace "`r", "`n")
        if (-not $mdLf.EndsWith("`n")) { $mdLf = ($mdLf + "`n") }
        $enc = [Text.UTF8Encoding]::new($false)
        $cacheDir = Join-Path $repo 'cache\v3\dev-metrics'
        $pubDir = Join-Path $repo 'evidence\dev-telemetry'
        $histDir = Join-Path $pubDir 'history'
        try {
            if ($Publish) {
                foreach ($d in @($cacheDir, $pubDir, $histDir)) {
                    try { if (Test-DevTelemetryReparse -Path ([IO.Path]::GetFullPath($d))) { return $null } } catch { }
                }
            }
            else {
                try { if (Test-DevTelemetryReparse -Path ([IO.Path]::GetFullPath($cacheDir))) { return $null } } catch { }
            }
        }
        catch { return $null }
        try {
            New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
            if ($Publish) {
                New-Item -ItemType Directory -Path $pubDir -Force | Out-Null
                New-Item -ItemType Directory -Path $histDir -Force | Out-Null
            }
        }
        catch { return $null }
        try {
            if ($Publish) {
                foreach ($d in @($cacheDir, $pubDir, $histDir)) {
                    try { if (Test-DevTelemetryReparse -Path ([IO.Path]::GetFullPath($d))) { return $null } } catch { return $null }
                }
            }
            else {
                try { if (Test-DevTelemetryReparse -Path ([IO.Path]::GetFullPath($cacheDir))) { return $null } } catch { return $null }
            }
        }
        catch { return $null }
        $cj = Join-Path $cacheDir 'latest.json'
        $cm = Join-Path $cacheDir 'latest.md'
        $okCj = $false
        $okCm = $false
        try { $okCj = Write-DevTelemetryFileAtomic -Dest $cj -Content $jsonLf -AllowedDir $cacheDir -RepoRoot $repo -Encoding $enc } catch { $okCj = $false }
        try { $okCm = Write-DevTelemetryFileAtomic -Dest $cm -Content $mdLf -AllowedDir $cacheDir -RepoRoot $repo -Encoding $enc } catch { $okCm = $false }
        if ((-not $okCj) -or (-not $okCm)) { return $null }
        if ($Publish) {
            try {
                $pj = Join-Path $pubDir 'latest.json'
                $pm = Join-Path $pubDir 'latest.md'
                $wk = Get-DevTelemetryIsoWeekFile -Timestamp $gen
                $hj = Join-Path $histDir ($wk + '.json')
                $okPj = $false
                $okPm = $false
                $okHj = $false
                try { $okPj = Write-DevTelemetryFileAtomic -Dest $pj -Content $jsonLf -AllowedDir $pubDir -RepoRoot $repo -Encoding $enc } catch { $okPj = $false }
                try { $okPm = Write-DevTelemetryFileAtomic -Dest $pm -Content $mdLf -AllowedDir $pubDir -RepoRoot $repo -Encoding $enc } catch { $okPm = $false }
                try { $okHj = Write-DevTelemetryFileAtomic -Dest $hj -Content $jsonLf -AllowedDir $histDir -RepoRoot $repo -Encoding $enc } catch { $okHj = $false }
                if ((-not $okPj) -or (-not $okPm) -or (-not $okHj)) { return $null }
            }
            catch { return $null }
        }
        try { Invoke-DevTelemetryRetentionIfDue -RepoRoot $repo | Out-Null } catch { }
        return $snap
    }
    catch { return $null }
}

function New-DevTelemetryMarkdown {
    [CmdletBinding()]
    param($Snapshot = $null)
    try {
        $lines = New-Object System.Collections.Generic.List[string]
        [void]$lines.Add('# dev-telemetry')
        [void]$lines.Add('')
        if ($null -eq $Snapshot) {
            [void]$lines.Add('no data')
            [void]$lines.Add('')
            return ($lines -join "`n")
        }
        $gen = [string](Get-DevTelemetryNodeProp -Node $Snapshot -Name 'generated_at')
        $wd = 0
        try { $wd = [int](Get-DevTelemetryNodeProp -Node $Snapshot -Name 'window_days') } catch { $wd = 0 }
        [void]$lines.Add(('generated_at: ' + $gen + ' | window_days: ' + $wd))
        [void]$lines.Add('')
        $raw = Get-DevTelemetryNodeProp -Node $Snapshot -Name 'raw'
        $tot = Get-DevTelemetryNodeProp -Node $Snapshot -Name 'totals'
        $re = 0
        $rf = 0
        $rFirst = ''
        $rLast = ''
        try {
            $re = [int](Get-DevTelemetryNodeProp -Node $raw -Name 'events')
            $rf = [int](Get-DevTelemetryNodeProp -Node $raw -Name 'files')
            $rFirst = [string](Get-DevTelemetryNodeProp -Node $raw -Name 'first_ts')
            $rLast = [string](Get-DevTelemetryNodeProp -Node $raw -Name 'last_ts')
        } catch { }
        $sr = 0
        $sp = 0
        $sf = 0
        $ssk = 0
        $ser = 0
        $spr = 0.0
        try {
            $sr = [int](Get-DevTelemetryNodeProp -Node $tot -Name 'suite_runs')
            $sp = [int](Get-DevTelemetryNodeProp -Node $tot -Name 'pass')
            $sf = [int](Get-DevTelemetryNodeProp -Node $tot -Name 'fail')
            $ssk = [int](Get-DevTelemetryNodeProp -Node $tot -Name 'skip')
            $ser = [int](Get-DevTelemetryNodeProp -Node $tot -Name 'error')
            $spr = [double](Get-DevTelemetryNodeProp -Node $tot -Name 'pass_rate')
        } catch { }
        [void]$lines.Add('## resumo')
        [void]$lines.Add('')
        [void]$lines.Add('| metrica | valor |')
        [void]$lines.Add('| --- | --- |')
        [void]$lines.Add('| events | ' + $re + ' |')
        [void]$lines.Add('| files | ' + $rf + ' |')
        [void]$lines.Add('| first_ts | ' + $rFirst + ' |')
        [void]$lines.Add('| last_ts | ' + $rLast + ' |')
        [void]$lines.Add('| suite_runs | ' + $sr + ' |')
        [void]$lines.Add('| pass | ' + $sp + ' |')
        [void]$lines.Add('| fail | ' + $sf + ' |')
        [void]$lines.Add('| skip | ' + $ssk + ' |')
        [void]$lines.Add('| error | ' + $ser + ' |')
        [void]$lines.Add('| pass_rate | ' + $spr + ' |')
        [void]$lines.Add('')
        $suites = @()
        try { $suites = @(Get-DevTelemetryNodeProp -Node $Snapshot -Name 'suites') } catch { $suites = @() }
        [void]$lines.Add('## suites com falha')
        [void]$lines.Add('')
        $failSuites = @($suites | Where-Object {
            try {
                (([int](Get-DevTelemetryNodeProp -Node $_ -Name 'fail') + [int](Get-DevTelemetryNodeProp -Node $_ -Name 'error')) -gt 0)
            } catch { $false }
        })
        if (@($failSuites).Count -eq 0) {
            [void]$lines.Add('| suite | runs | pass | fail | skip | error | pass_rate |')
            [void]$lines.Add('| --- | --- | --- | --- | --- | --- | --- |')
            [void]$lines.Add('no data')
        }
        else {
            [void]$lines.Add('| suite | runs | pass | fail | skip | error | pass_rate |')
            [void]$lines.Add('| --- | --- | --- | --- | --- | --- | --- |')
            foreach ($s in $failSuites) {
                try {
                    [void]$lines.Add(('| ' + [string](Get-DevTelemetryNodeProp -Node $s -Name 'suite') + ' | ' + [int](Get-DevTelemetryNodeProp -Node $s -Name 'runs') + ' | ' + [int](Get-DevTelemetryNodeProp -Node $s -Name 'pass') + ' | ' + [int](Get-DevTelemetryNodeProp -Node $s -Name 'fail') + ' | ' + [int](Get-DevTelemetryNodeProp -Node $s -Name 'skip') + ' | ' + [int](Get-DevTelemetryNodeProp -Node $s -Name 'error') + ' | ' + [double](Get-DevTelemetryNodeProp -Node $s -Name 'pass_rate') + ' |'))
                } catch { }
            }
        }
        [void]$lines.Add('')
        [void]$lines.Add('## 5 mais lentas (p95_ms)')
        [void]$lines.Add('')
        $slow = @()
        try { $slow = @(Get-DevTelemetryNodeProp -Node $Snapshot -Name 'slowest') } catch { $slow = @() }
        if (@($slow).Count -eq 0) {
            [void]$lines.Add('| suite | p95_ms | p50_ms | runs |')
            [void]$lines.Add('| --- | --- | --- | --- |')
            [void]$lines.Add('no data')
        }
        else {
            [void]$lines.Add('| suite | p95_ms | p50_ms | runs |')
            [void]$lines.Add('| --- | --- | --- | --- |')
            foreach ($s in $slow) {
                try {
                    [void]$lines.Add(('| ' + [string](Get-DevTelemetryNodeProp -Node $s -Name 'suite') + ' | ' + [long](Get-DevTelemetryNodeProp -Node $s -Name 'p95_ms') + ' | ' + [long](Get-DevTelemetryNodeProp -Node $s -Name 'p50_ms') + ' | ' + [int](Get-DevTelemetryNodeProp -Node $s -Name 'runs') + ' |'))
                } catch { }
            }
        }
        [void]$lines.Add('')
        [void]$lines.Add('## flaky (FAIL/ERROR -> PASS)')
        [void]$lines.Add('')
        $fl = @()
        try { $fl = @(Get-DevTelemetryNodeProp -Node $Snapshot -Name 'flaky') } catch { $fl = @() }
        if (@($fl).Count -eq 0) {
            [void]$lines.Add('| suite | from | to | from_ts | to_ts |')
            [void]$lines.Add('| --- | --- | --- | --- | --- |')
            [void]$lines.Add('no data')
        }
        else {
            [void]$lines.Add('| suite | from | to | from_ts | to_ts |')
            [void]$lines.Add('| --- | --- | --- | --- | --- |')
            foreach ($f in $fl) {
                try {
                    [void]$lines.Add(('| ' + [string](Get-DevTelemetryNodeProp -Node $f -Name 'suite') + ' | ' + [string](Get-DevTelemetryNodeProp -Node $f -Name 'from_verdict') + ' | ' + [string](Get-DevTelemetryNodeProp -Node $f -Name 'to_verdict') + ' | ' + [string](Get-DevTelemetryNodeProp -Node $f -Name 'from_ts') + ' | ' + [string](Get-DevTelemetryNodeProp -Node $f -Name 'to_ts') + ' |'))
                } catch { }
            }
        }
        [void]$lines.Add('')
        [void]$lines.Add('## preflight')
        [void]$lines.Add('')
        $pre = Get-DevTelemetryNodeProp -Node $Snapshot -Name 'preflight'
        if ($null -eq $pre) {
            [void]$lines.Add('no data')
        }
        else {
            try {
                [void]$lines.Add(('| total | ' + [int](Get-DevTelemetryNodeProp -Node $pre -Name 'total') + ' |'))
                [void]$lines.Add(('| fallback_rate | ' + [double](Get-DevTelemetryNodeProp -Node $pre -Name 'fallback_rate') + ' |'))
                $bd = Get-DevTelemetryNodeProp -Node $pre -Name 'by_decision'
                [void]$lines.Add('')
                [void]$lines.Add('| decision | count |')
                [void]$lines.Add('| --- | --- |')
                $hasBd = $false
                if ($null -ne $bd) {
                    foreach ($pp in @($bd.PSObject.Properties | Sort-Object { $_.Name })) {
                        [void]$lines.Add(('| ' + [string]$pp.Name + ' | ' + [int]$pp.Value + ' |'))
                        $hasBd = $true
                    }
                }
                if (-not $hasBd) { [void]$lines.Add('no data') }
            } catch { [void]$lines.Add('no data') }
        }
        [void]$lines.Add('')
        [void]$lines.Add('## plugin')
        [void]$lines.Add('')
        $pl = Get-DevTelemetryNodeProp -Node $Snapshot -Name 'plugin'
        if ($null -eq $pl) {
            [void]$lines.Add('no data')
        }
        else {
            try {
                [void]$lines.Add('| metrica | valor |')
                [void]$lines.Add('| --- | --- |')
                [void]$lines.Add(('| reports | ' + [int](Get-DevTelemetryNodeProp -Node $pl -Name 'reports') + ' |'))
                [void]$lines.Add(('| latest_overall | ' + [string](Get-DevTelemetryNodeProp -Node $pl -Name 'latest_overall') + ' |'))
                [void]$lines.Add(('| latest_load_errors | ' + [int](Get-DevTelemetryNodeProp -Node $pl -Name 'latest_load_errors') + ' |'))
                [void]$lines.Add(('| latest_expected_load_errors | ' + [int](Get-DevTelemetryNodeProp -Node $pl -Name 'latest_expected_load_errors') + ' |'))
                [void]$lines.Add(('| latest_telemetry_present | ' + [int](Get-DevTelemetryNodeProp -Node $pl -Name 'latest_telemetry_present') + ' |'))
            } catch { [void]$lines.Add('no data') }
        }
        [void]$lines.Add('')
        [void]$lines.Add('## review')
        [void]$lines.Add('')
        $rv = Get-DevTelemetryNodeProp -Node $Snapshot -Name 'review'
        if ($null -eq $rv) {
            [void]$lines.Add('no data')
        }
        else {
            try {
                [void]$lines.Add('| metrica | valor |')
                [void]$lines.Add('| --- | --- |')
                [void]$lines.Add(('| total | ' + [int](Get-DevTelemetryNodeProp -Node $rv -Name 'total') + ' |'))
                [void]$lines.Add(('| approved | ' + [int](Get-DevTelemetryNodeProp -Node $rv -Name 'approved') + ' |'))
                [void]$lines.Add(('| changes_required | ' + [int](Get-DevTelemetryNodeProp -Node $rv -Name 'changes_required') + ' |'))
                [void]$lines.Add(('| high_or_critical | ' + [int](Get-DevTelemetryNodeProp -Node $rv -Name 'high_or_critical') + ' |'))
                foreach ($groupName in @('by_source','by_severity')) {
                    [void]$lines.Add('')
                    [void]$lines.Add(('### ' + $groupName.Replace('_',' ')))
                    $group = Get-DevTelemetryNodeProp -Node $rv -Name $groupName
                    $props = @($group.PSObject.Properties | Sort-Object Name)
                    if ($props.Count -eq 0) { [void]$lines.Add('no data') }
                    else {
                        [void]$lines.Add('| valor | count |')
                        [void]$lines.Add('| --- | ---: |')
                        foreach ($prop in $props) { [void]$lines.Add(('| ' + $prop.Name + ' | ' + [int]$prop.Value + ' |')) }
                    }
                }
            } catch { [void]$lines.Add('no data') }
        }
        [void]$lines.Add('')
        [void]$lines.Add('## gates')
        [void]$lines.Add('')
        $gt = Get-DevTelemetryNodeProp -Node $Snapshot -Name 'gates'
        if ($null -eq $gt) {
            [void]$lines.Add('no data')
        }
        else {
            try {
                [void]$lines.Add('| metrica | valor |')
                [void]$lines.Add('| --- | --- |')
                [void]$lines.Add(('| reports | ' + [int](Get-DevTelemetryNodeProp -Node $gt -Name 'reports') + ' |'))
                [void]$lines.Add(('| pass | ' + [int](Get-DevTelemetryNodeProp -Node $gt -Name 'pass') + ' |'))
                [void]$lines.Add(('| fail | ' + [int](Get-DevTelemetryNodeProp -Node $gt -Name 'fail') + ' |'))
                [void]$lines.Add(('| checks_total | ' + [int](Get-DevTelemetryNodeProp -Node $gt -Name 'checks_total') + ' |'))
                [void]$lines.Add(('| checks_fail | ' + [int](Get-DevTelemetryNodeProp -Node $gt -Name 'checks_fail') + ' |'))
            } catch { [void]$lines.Add('no data') }
        }
        [void]$lines.Add('')
        return ($lines -join "`n")
    }
    catch { return "# dev-telemetry`n`nno data`n" }
}
