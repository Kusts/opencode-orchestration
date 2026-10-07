<#!
.SYNOPSIS
    Phase 2D Capability Resolver CLI (SHADOW ONLY). Fail-safe, never activates.
.DESCRIPTION
    Reads a TaskFile JSON, calls lib/CapabilityResolver.ps1, emits compact JSON:
    task_id, task_class, profiles_selected, agents_selected, skills_selected,
    capabilities_selected, risk, reason_codes, fallbacks, confidence,
    mode=shadow, resolver_version. Exit 0 on correct use (fail-safe, never
    throws); exit 2 only on usage error. Never activates profiles or MCPs.
    Optional sanitized telemetry (hashes/enums only) to
    cache/v3/telemetry/resolver-YYYYMMDD.jsonl unless -NoTelemetry.
    The persisted JSONL line carries task_id as a deterministic SHA256 hash
    (first 16 hex, lowercase), never the literal; stdout/OutFile keep the
    regex-validated task_id (ephemeral correlation). -TelemetryPath redirects
    the JSONL line to a confined file (cache/v3/telemetry or TEMP only,
    reparse-point refused, fail-closed); -RoutingPath selects an alternate
    routing registry (tests/fail-safe only, never activates).
    PowerShell 5.1 compatible. ASCII-only.
#>
[CmdletBinding()]
param(
    [string]$TaskFile,
    [string]$ProjectRoot,
    [string]$OutFile,
    [string]$RoutingPath,
    [string]$TelemetryPath,
    [switch]$NoTelemetry
)

$ErrorActionPreference = 'Stop'

$v3root = $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $v3root)

function Write-ResolveCliError {
    param([string]$Text)
    [Console]::Error.WriteLine($Text)
}

function Get-ResolveTaskIdHash {
    <#
    .SYNOPSIS
        task_id para TELEMETRIA: SHA256 deterministico (primeiros 16 hex,
        lowercase). O literal nunca e persistido; fica so em memoria/stdout
        (correlacao efemera). Mesmo padrao do shadow-route (Get-ShadowTaskKeyHex).
    #>
    [CmdletBinding()]
    param([string]$TaskId)
    $s = ([string]$TaskId).Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { $s = 'unknown' }
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($s)
            $hash = $sha.ComputeHash($bytes)
            $hex = (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
            return ($hex.Substring(0, 16).ToLowerInvariant())
        }
        finally { try { $sha.Dispose() } catch { } }
    }
    catch { return 'unavailable' }
}

function Test-ResolveConfinedTelemetry {
    [CmdletBinding()]
    param([string]$Path, [string]$Repo)
    try {
        $full = ''
        if ([IO.Path]::IsPathRooted($Path)) { $full = [IO.Path]::GetFullPath($Path) }
        else { $full = [IO.Path]::GetFullPath((Join-Path $Repo $Path)) }
        $sep = [IO.Path]::DirectorySeparatorChar
        $allowed1 = [IO.Path]::GetFullPath((Join-Path $Repo 'cache\v3\telemetry'))
        $prefix1 = $allowed1.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + $sep
        if ($full.StartsWith($prefix1, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        $tmp = $env:TEMP
        if (-not [string]::IsNullOrWhiteSpace($tmp)) {
            try {
                $tbase = [IO.Path]::GetFullPath($tmp)
                $prefixT = $tbase.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + $sep
                if ($full.StartsWith($prefixT, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
            }
            catch { }
        }
    }
    catch { }
    return $false
}

function Test-ResolvePathHasReparsePoint {
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

function Get-ResolveFullPath {
    param([string]$Path, [string]$Repo)
    try {
        if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
        return [IO.Path]::GetFullPath((Join-Path $Repo $Path))
    }
    catch { return $Path }
}

if ([string]::IsNullOrWhiteSpace($TaskFile)) {
    Write-ResolveCliError 'Usage: capability-resolve.ps1 -TaskFile <json> [-ProjectRoot <dir>] [-OutFile <json>] [-RoutingPath <json>] [-TelemetryPath <jsonl>] [-NoTelemetry].'
    exit 2
}

$taskPath = $TaskFile
try {
    if (-not [IO.Path]::IsPathRooted($taskPath)) { $taskPath = [IO.Path]::GetFullPath((Join-Path $repoRoot $taskPath)) }
} catch { }
if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) {
    Write-ResolveCliError ("capability-resolve.ps1: TaskFile not found: {0}" -f $TaskFile)
    exit 2
}

# R2 FIX 1: -TelemetryPath confinado (cache/v3/telemetry ou TEMP), recusa
# reparse point, fail-closed — mesmas guardas do shadow-route.ps1.
if (-not [string]::IsNullOrWhiteSpace($TelemetryPath) -and -not $NoTelemetry) {
    $allowedTel = Join-Path $repoRoot 'cache\v3\telemetry'
    if (-not (Test-ResolveConfinedTelemetry -Path $TelemetryPath -Repo $repoRoot)) {
        Write-ResolveCliError ("capability-resolve.ps1: -TelemetryPath fora de cache\v3\telemetry ou TEMP (negado): {0}" -f $TelemetryPath)
        exit 2
    }
    if (Test-ResolvePathHasReparsePoint -Path (Get-ResolveFullPath -Path $TelemetryPath -Repo $repoRoot)) {
        Write-ResolveCliError ("capability-resolve.ps1: -TelemetryPath com reparse point/junction em ancestor (negado): {0}" -f $TelemetryPath)
        exit 2
    }
}

try {
    . (Join-Path $v3root 'lib\CapabilityResolver.ps1')
}
catch {
    Write-ResolveCliError ("capability-resolve.ps1: cannot load CapabilityResolver.ps1 ({0})" -f $_.Exception.Message)
    exit 2
}

function Get-JsonField {
    param($Node, [string]$Field)
    try {
        if ($Node -is [System.Collections.IDictionary]) {
            if ($Node.Contains($Field)) { return $Node[$Field] }
            return $null
        }
        foreach ($p in @($Node.PSObject.Properties)) {
            if ($p.Name -ceq $Field) { return $p.Value }
        }
    }
    catch { }
    return $null
}

try {
    $raw = [IO.File]::ReadAllText($taskPath, [Text.UTF8Encoding]::new($false))
    $input = $null
    try { $input = $raw | ConvertFrom-Json }
    catch { $input = $null }
    $taskIdRaw = 'unknown'
    $taskClassRaw = ''
    if ($null -ne $input) {
        try {
            $v = Get-JsonField -Node $input -Field 'task_id'
            if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) { $taskIdRaw = ([string]$v).Trim() }
            else {
                $v = Get-JsonField -Node $input -Field 'taskId'
                if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) { $taskIdRaw = ([string]$v).Trim() }
            }
            $v = Get-JsonField -Node $input -Field 'task_class'
            if ($null -ne $v) { $taskClassRaw = ([string]$v).Trim() }
            if ([string]::IsNullOrWhiteSpace($taskClassRaw)) {
                $v = Get-JsonField -Node $input -Field 'task_type'
                if ($null -ne $v) { $taskClassRaw = ([string]$v).Trim() }
            }
        }
        catch { }
    }
    # sanitizacao: task_id por regex estrita; task_class contra allowlist do routing (fail-closed -> unknown)
    $taskId = 'unknown'
    if ($taskIdRaw -cmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') { $taskId = $taskIdRaw }
    $classAllow = @()
    try {
        $rdoc = Get-ResolverRoutingDoc -RepoRoot '' -RoutingPath $RoutingPath
        $classAllow = @(@($rdoc.task_classes) | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() })
    }
    catch { $classAllow = @() }
    $taskClassNorm = ([string]$taskClassRaw).Trim().ToLowerInvariant()
    $taskClass = 'unknown'
    $classInvalid = $true
    if (($classAllow -ccontains $taskClassNorm) -and (-not [string]::IsNullOrWhiteSpace($taskClassNorm))) {
        $taskClass = $taskClassNorm
        $classInvalid = $false
    }
    $resolveInput = $input
    if ($null -eq $resolveInput) { $resolveInput = [PSCustomObject]@{ task = ''; task_class = '' } }
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        try {
            $resolveInput | Add-Member -NotePropertyName 'projectRoot' -NotePropertyValue $ProjectRoot -Force
        }
        catch { }
    }
    $result = $null
    try { $result = Invoke-CapabilityResolve -TaskInput $resolveInput -RoutingPath $RoutingPath }
    catch { $result = $null }
    if ($null -eq $result) {
        $result = [PSCustomObject]@{
            agents         = @('coder')
            skills         = @('verification-before-completion')
            profiles       = @()
            pilot_profiles = @()
            mcps           = @()
            capabilities   = @('code.bounded-edit')
            permissions    = [PSCustomObject]@{ recommendation = 'allow'; enforcement_authority = 'advisory-shadow (no enforcement)' }
            risk           = [PSCustomObject]@{ level = 'MEDIUM' }
            fallbacks      = @()
            reason_codes   = @('AMBIGUOUS')
            confidence     = 'AMBIGUOUS'
            mode           = 'shadow'
        }
    }
    # task_class invalida -> reason AMBIGUOUS preservado
    try {
        if ($classInvalid) {
            $rc = @($result.reason_codes)
            if ($rc -cnotcontains 'AMBIGUOUS') {
                $result.reason_codes = @($rc + @('AMBIGUOUS'))
            }
        }
    }
    catch { }
    # permissions projetadas da lib (sanitizadas a enums fixos)
    $permRecOut = 'allow'
    $permAuthOut = 'advisory-shadow (no enforcement)'
    try {
        $pr = ([string]$result.permissions.recommendation).Trim().ToLowerInvariant()
        if (@('allow', 'deny', 'ask') -ccontains $pr) { $permRecOut = $pr }
    }
    catch { }
    $riskLevel = 'MEDIUM'
    try { if ($null -ne $result.risk -and $null -ne $result.risk.level) { $riskLevel = ([string]$result.risk.level).Trim().ToUpperInvariant() } } catch { }
    if (@('LOW', 'MEDIUM', 'HIGH', 'CRITICAL') -cnotcontains $riskLevel) { $riskLevel = 'MEDIUM' }
    $pilotOut = @()
    try { $pilotOut = @($result.pilot_profiles) } catch { $pilotOut = @() }
    $out = [PSCustomObject]@{
        task_id               = $taskId
        task_class            = $taskClass
        profiles_selected     = @($result.profiles)
        pilot_profiles        = @($pilotOut)
        agents_selected       = @($result.agents)
        skills_selected       = @($result.skills)
        capabilities_selected = @($result.capabilities)
        mcps_selected         = @($result.mcps)
        permissions           = [PSCustomObject]@{ recommendation = $permRecOut; enforcement_authority = $permAuthOut }
        risk                  = $riskLevel
        reason_codes          = @($result.reason_codes)
        fallbacks             = @($result.fallbacks)
        confidence            = [string]$result.confidence
        mode                  = 'shadow'
        resolver_version      = '2d-shadow-1'
    }
    $json = ($out | ConvertTo-Json -Depth 10 -Compress)
    if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
        $outPath = $OutFile
        try {
            if (-not [IO.Path]::IsPathRooted($outPath)) { $outPath = [IO.Path]::GetFullPath((Join-Path $repoRoot $outPath)) }
        } catch { }
        try {
            $dir = Split-Path -Parent $outPath
            if (-not [string]::IsNullOrWhiteSpace($dir) -and (-not (Test-Path -LiteralPath $dir))) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            [IO.File]::WriteAllText($outPath, $json, [Text.UTF8Encoding]::new($false))
        }
        catch {
            Write-ResolveCliError ("capability-resolve.ps1: cannot write OutFile ({0})" -f $_.Exception.Message)
        }
    }
    Write-Output $json
    if (-not $NoTelemetry) {
        try {
            $telPath = ''
            if (-not [string]::IsNullOrWhiteSpace($TelemetryPath)) {
                $telPath = Get-ResolveFullPath -Path $TelemetryPath -Repo $repoRoot
            }
            else {
                $telDir = Join-Path $repoRoot 'cache\v3\telemetry'
                if (-not (Test-Path -LiteralPath $telDir)) { New-Item -ItemType Directory -Path $telDir -Force | Out-Null }
                $stamp = (Get-Date).ToString('yyyyMMdd')
                $telPath = Join-Path $telDir ("resolver-{0}.jsonl" -f $stamp)
            }
            $telParent = Split-Path -Parent $telPath
            if (-not [string]::IsNullOrWhiteSpace($telParent) -and (-not (Test-Path -LiteralPath $telParent))) {
                New-Item -ItemType Directory -Path $telParent -Force | Out-Null
            }
            $tel = [PSCustomObject]@{
                task_id   = (Get-ResolveTaskIdHash -TaskId $taskId)
                task_class = $taskClass
                profiles  = @($result.profiles)
                agents    = @($result.agents)
                skills    = @($result.skills)
                risk      = $riskLevel
                confidence = [string]$result.confidence
                mode      = 'shadow'
                at        = (Get-Date).ToUniversalTime().ToString('o')
            }
            $line = ($tel | ConvertTo-Json -Depth 6 -Compress)
            [IO.File]::AppendAllText($telPath, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        }
        catch { }
    }
    exit 0
}
catch {
    try {
        $safe = [PSCustomObject]@{
            task_id               = 'unknown'
            task_class            = 'unknown'
            profiles_selected     = @()
            pilot_profiles        = @()
            agents_selected       = @('coder')
            skills_selected       = @('verification-before-completion')
            capabilities_selected = @('code.bounded-edit')
            mcps_selected         = @()
            permissions           = [PSCustomObject]@{ recommendation = 'allow'; enforcement_authority = 'advisory-shadow (no enforcement)' }
            risk                  = 'MEDIUM'
            reason_codes          = @('AMBIGUOUS')
            fallbacks             = @()
            confidence            = 'AMBIGUOUS'
            mode                  = 'shadow'
            resolver_version      = '2d-shadow-1'
        }
        Write-Output ($safe | ConvertTo-Json -Depth 10 -Compress)
        exit 0
    }
    catch {
        Write-ResolveCliError 'capability-resolve.ps1: internal failure contained.'
        exit 0
    }
}
