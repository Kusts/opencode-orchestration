<#
.SYNOPSIS
    Windows-side operational verifier for the dedicated Syncthing inbox mount
    read by the n8n container on the VPS.
.DESCRIPTION
    Topology this verifier is built for:
      - the dedicated Windows inbox D:\Sync\synkroo-forge-inbox is synchronized
        by Syncthing to the VPS host path
        /home/deploy/Sync/synkroo-forge-inbox;
      - the n8n container on that VPS bind-mounts the synced path read-only at
        the configured container destination;
      - Docker is reached from Windows ONLY through an explicit context
        (default: contabo-prod over SSH). The default local daemon and any
        DOCKER_HOST override are refused.

    Two jobs only:
      1. validate the expected bind of ONE n8n container: unique mount whose
         Source is exactly the dedicated remote inbox (or exactly the synced
         root with the dedicated inbox inside it), read-only, at the expected
         destination, not shadowed, with the container running and healthy;
      2. prove the mount is live: write ONE uniquely named disposable sentinel
         inside D:\Sync\synkroo-forge-inbox only, confirm the container user
         `node` can read it byte-for-byte through the remote mount, then remove
         only that sentinel and verify it disappeared from both sides.

    The only docker commands ever issued are these fixed forms:
      docker --context <ctx> inspect --format <fixed template> <container>
      docker --context <ctx> exec <container> id -un
      docker --context <ctx> exec <container> test -f <path>
      docker --context <ctx> exec <container> cat <path>
    `inspect --format` selects only Name, Config.Image, State.Status,
    State.Running, State.Restarting, State.Paused, State.Health.Status and
    Mounts. The container environment is never requested, never captured and
    never printed. It never calls the n8n API, never imports/activates/executes
    a workflow, never touches the Pi Agent, never edits Compose files, never
    creates/starts/restarts/stops/reconfigures containers, and never contacts
    customers. The sentinel is the only artifact written and the only path
    deleted.

    Fail closed: missing configuration or missing operator opt-in, an invalid
    or local-only context, a context endpoint other than the exact
    ssh://deploy@contabo-prod SSH endpoint, any DOCKER_HOST/DOCKER_CONTEXT
    conflict or DOCKER_CONFIG/DOCKER_CERT_PATH/DOCKER_TLS_VERIFY/DOCKER_TLS
    override, a missing or reparse-point local inbox, a wrong or ambiguous
    mount, a non-bind mount, a writable bind, a shadowed destination, a
    container that is not n8n (exact name and official image repository), not
    running or unhealthy, a container user other than node, a sentinel that is
    not visible or not byte-identical, and an unverified cleanup all end in a
    non-zero exit with a machine-readable JSON verdict.

    Exit codes: 0 verified, 1 failed, 2 not_configured / unavailable.

    PRODUCTION WRITE OPT-IN (default OFF):
      The verifier writes one disposable sentinel into the local inbox. That is
      a production-side write, so it is refused unless the operator explicitly
      opts in for this invocation. Opt in with the switch
      -AllowProductionInboxWrite or, when the exact allowlisted profile command
      is used (extra CLI arguments are rejected by the allowlist), with the
      environment variable ORCHESTRATION_N8N_ALLOW_INBOX_WRITE=1. Without the
      opt-in the verifier returns WRITE_OPT_IN_REQUIRED with exit 2 and makes
      no Docker call and no file write. Dry inspection is deliberately not
      offered: validation of a production context is still production contact.

    RUNTIME BUDGET:
      The allowlisted profile timeout is 240 seconds. The script bounds its own
      wall-clock runtime at 210 seconds by default (-RuntimeBudgetSeconds,
      accepted range 10..225), including the context endpoint probe, inspect,
      user probe and BOTH polling phases. A cleanup reserve (45 seconds) is
      held back so cleanup verification always gets time, and the remaining
      bounded time is passed to every Docker call (capped at 30 seconds per
      call). Retry sleeps are clamped to the remaining budget and never
      overrun it. Exhaustion fails closed (never a success verdict).

    DEFAULTS AND CONFIGURATION (parameters win over environment):
      -DockerContext          ORCHESTRATION_N8N_DOCKER_CONTEXT       default: contabo-prod
      -ContainerName          ORCHESTRATION_N8N_CONTAINER            default: n8n
      -MountDestination       ORCHESTRATION_N8N_SYNCTHING_MOUNT_DEST required (no inference)
      -DockerExecutable       ORCHESTRATION_N8N_DOCKER_EXECUTABLE    default: docker
      -RequireHealthcheck     ORCHESTRATION_N8N_REQUIRE_HEALTHCHECK  default: off
      -AllowProductionInboxWrite ORCHESTRATION_N8N_ALLOW_INBOX_WRITE default: off
      -LocalSyncRoot          parameter only                         default: D:\Sync
      -RemoteSyncRoot         parameter only                         default: /home/deploy/Sync
      -ProbeAttempts          parameter only                         default: 20
      -ProbeDelayMilliseconds parameter only                         default: 1500
      -RuntimeBudgetSeconds   parameter only                         default: 210

    SAFE DIAGNOSTICS: raw DOCKER_HOST/DOCKER_CONTEXT values and raw Docker/SSH
    stderr are never serialized. Verdict checks and details carry only generic
    error codes and bounded numeric Docker exit codes.

    The local and remote sync roots are parameters (never environment) because
    they define the safety boundary: the sentinel is only ever created under
    <LocalSyncRoot>\synkroo-forge-inbox and only ever matched against
    <RemoteSyncRoot>/synkroo-forge-inbox.

    PATH AND TRANSPORT ASSUMPTIONS (keep aligned with the code):
      - the dedicated local inbox must already exist; this verifier never
        creates directories and never writes outside it;
      - the bind Source reported by inspect is the VPS host path, compared
        case-sensitively against the dedicated remote inbox (or the remote sync
        root, when the inbox is inside the mounted tree);
      - the configured destination is mandatory: the verifier never infers it
        from an arbitrary mount;
      - the container must resolve to user `node`; a permission or identity
        error fails closed instead of skipping the probe;
      - the sentinel is ASCII-only with LF line endings, so ordinal text
        equality with the expected payload is byte-for-byte equality;
        SHA-256 is reported for both sides as evidence;
      - Syncthing propagation is asynchronous, so visibility and disappearance
        are polled with a bounded number of attempts;
      - the sentinel is a single `.orchestration-mount-smoke-<guid>.tmp` file in
        the inbox. A workflow watching that inbox may observe it; the verifier
        itself never starts a workflow. This residual risk is documented, not
        hidden.

    PowerShell 5.1 / 7 compatible. ASCII-only. Expected domain errors are
    returned as result objects, never thrown.

    Dot-sourcing this file only loads the functions; the CLI body runs when the
    file is executed (used by the focused test suite).
#>
[CmdletBinding()]
param(
    [string]$ContainerName = '',
    [string]$MountDestination = '',
    [string]$DockerContext = '',
    [string]$DockerExecutable = '',
    [string]$LocalSyncRoot = '',
    [string]$RemoteSyncRoot = '',
    [ValidateRange(1, 60)][int]$ProbeAttempts = 20,
    [ValidateRange(0, 10000)][int]$ProbeDelayMilliseconds = 1500,
    [ValidateRange(0, 225)][int]$RuntimeBudgetSeconds = 0,
    [switch]$AllowProductionInboxWrite,
    [switch]$RequireHealthcheck
)

$ErrorActionPreference = 'Stop'

$script:N8nSmokeVerifier = 'n8n-syncthing-mount-smoke'
$script:N8nSmokeInboxLeaf = 'synkroo-forge-inbox'
$script:N8nSmokeProbePrefix = '.orchestration-mount-smoke-'
$script:N8nSmokeProbeSuffix = '.tmp'
$script:N8nSmokeDockerTimeoutSeconds = 30
$script:N8nSmokeRuntimeBudgetSeconds = 210
$script:N8nSmokeCleanupReserveSeconds = 45
$script:N8nSmokeRequiredContextEndpoint = 'ssh://deploy@contabo-prod'
$script:N8nSmokeContextInspectFormat = '{{json .Endpoints.docker.Host}}'
$script:N8nSmokeOfficialImageRepositories = @(
    'n8nio/n8n'
    'docker.io/n8nio/n8n'
    'index.docker.io/n8nio/n8n'
    'docker.n8n.io/n8nio/n8n'
)
$script:N8nSmokeUnsafeExecutableExtensions = @('.cmd', '.bat', '.ps1')

# Fixed inspect projection: eight pipe-separated JSON fields, in this order.
# It deliberately excludes Config.Env and every other secret-bearing field.
$script:N8nSmokeInspectFormat = '{{json .Name}}|{{json .Config.Image}}|{{json .State.Status}}|{{json .State.Running}}|{{json .State.Restarting}}|{{json .State.Paused}}|{{if .State.Health}}{{json .State.Health.Status}}{{else}}null{{end}}|{{json .Mounts}}'

function Get-N8nSmokeConfigValue {
    param([string]$Explicit, [string]$EnvName, [string]$Default)
    $value = ([string]$Explicit).Trim()
    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    if (-not [string]::IsNullOrWhiteSpace($EnvName)) {
        $fromEnv = ''
        try { $fromEnv = [string]([Environment]::GetEnvironmentVariable($EnvName)) } catch { $fromEnv = '' }
        if (-not [string]::IsNullOrWhiteSpace($fromEnv)) { return $fromEnv.Trim() }
    }
    return ([string]$Default)
}

function Get-N8nComparablePath {
    param([string]$Path, [switch]$CaseSensitive)
    $p = ([string]$Path).Trim()
    if ([string]::IsNullOrWhiteSpace($p)) { return '' }
    $p = $p -replace '\\', '/'
    while (($p.Length -gt 1) -and $p.EndsWith('/')) { $p = $p.Substring(0, $p.Length - 1) }
    if ($CaseSensitive) { return $p }
    return $p.ToLowerInvariant()
}

function Test-N8nTruthyValue {
    param($Value)
    if ($null -eq $Value) { return $false }
    $text = ([string]$Value).Trim().ToLowerInvariant()
    return (@('1', 'true', 'yes', 'on') -contains $text)
}

function Test-N8nSafeContainerName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    return ($Name -cmatch '\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z')
}

function Test-N8nSafeContextName {
    param([string]$Name)
    if (-not (Test-N8nSafeContainerName -Name $Name)) { return $false }
    return ($Name -cnotmatch '^(?i)default$')
}

function Test-N8nSafeContainerPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not $Path.StartsWith('/')) { return $false }
    if ($Path -ceq '/') { return $false }
    if ($Path.Contains('//')) { return $false }
    if (-not ($Path -cmatch '\A/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*\z')) { return $false }
    foreach ($segment in @($Path.Split('/') | Where-Object { $_.Length -gt 0 })) {
        if (($segment -ceq '.') -or ($segment -ceq '..')) { return $false }
    }
    return $true
}

function Test-N8nPathWithin {
    param([string]$Parent, [string]$Child, [switch]$CaseSensitive)
    $p = Get-N8nComparablePath -Path $Parent -CaseSensitive:$CaseSensitive
    $c = Get-N8nComparablePath -Path $Child -CaseSensitive:$CaseSensitive
    if ([string]::IsNullOrWhiteSpace($p) -or [string]::IsNullOrWhiteSpace($c)) { return $false }
    if ($p -ceq $c) { return $true }
    if ($p -ceq '/') { return $true }
    return $c.StartsWith($p + '/', [System.StringComparison]::Ordinal)
}

function Test-N8nDockerExecutableSafe {
    param([string]$Executable)
    $exe = ([string]$Executable).Trim()
    if ([string]::IsNullOrWhiteSpace($exe)) { return $true }
    $leaf = $exe
    try { $leaf = [IO.Path]::GetFileName($exe) } catch { $leaf = $exe }
    if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = $exe }
    $ext = ''
    try { $ext = [IO.Path]::GetExtension($leaf).ToLowerInvariant() } catch { $ext = '' }
    if ([string]::IsNullOrWhiteSpace($ext)) { return $true }
    return (-not ($script:N8nSmokeUnsafeExecutableExtensions -contains $ext))
}

function Test-N8nOfficialImageRepository {
    param([string]$Image)
    $img = ([string]$Image).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($img)) { return $false }
    $name = $img
    $at = $name.IndexOf('@')
    if ($at -ge 0) { $name = $name.Substring(0, $at) }
    $slash = $name.LastIndexOf('/')
    $colon = $name.LastIndexOf(':')
    if ($colon -gt $slash) { $name = $name.Substring(0, $colon) }
    return ($script:N8nSmokeOfficialImageRepositories -ccontains $name)
}

function Test-N8nReparsePoint {
    param([string]$Path)
    try {
        $attributes = [IO.File]::GetAttributes($Path)
        return (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
    }
    catch { return $true }
}

function New-N8nRuntimeBudget {
    param([int]$Seconds)
    $total = [int]$Seconds
    if (($total -lt 1) -or ($total -gt 225)) { $total = [int]$script:N8nSmokeRuntimeBudgetSeconds }
    $started = [DateTime]::UtcNow
    return [pscustomobject]@{
        seconds      = $total
        started_utc  = $started
        deadline_utc = $started.AddSeconds([double]$total)
    }
}

function Get-N8nRuntimeRemainingSeconds {
    param($Budget)
    try {
        $remaining = ($Budget.deadline_utc - [DateTime]::UtcNow).TotalSeconds
        if ($remaining -lt 0) { return 0 }
        return [int][Math]::Floor($remaining)
    }
    catch { return 0 }
}

function Get-N8nBoundedDelayMilliseconds {
    param($Budget, [int]$DelayMilliseconds)
    $remainingMs = 0.0
    try {
        $remainingMs = ($Budget.deadline_utc - [DateTime]::UtcNow).TotalMilliseconds
    }
    catch { return 0 }
    if ($remainingMs -lt 1) { return 0 }
    $delay = [int]$DelayMilliseconds
    if ($delay -lt 0) { $delay = 0 }
    if ($delay -gt $remainingMs) { return [int][Math]::Floor($remainingMs) }
    return $delay
}

function Get-N8nBoundedDockerTimeout {
    param($Budget, [int]$ReserveSeconds = 0)
    $remaining = Get-N8nRuntimeRemainingSeconds -Budget $Budget
    $usable = $remaining - [int]$ReserveSeconds
    if ($usable -lt 1) { return 0 }
    if ($usable -gt [int]$script:N8nSmokeDockerTimeoutSeconds) { return [int]$script:N8nSmokeDockerTimeoutSeconds }
    return [int]$usable
}

function Get-N8nSafeStepDetail {
    param($Step)
    $started = $false
    $code = -1
    try { $started = [bool]$Step.started } catch { $started = $false }
    try { $code = [int]$Step.exit_code } catch { $code = -1 }
    if (-not $started) { return 'docker_exit=not_started' }
    return ('docker_exit=' + [string]$code)
}

function Test-N8nWriteOptIn {
    param([switch]$Explicit)
    if ([bool]$Explicit) { return $true }
    $fromEnv = ''
    try { $fromEnv = [string]([Environment]::GetEnvironmentVariable('ORCHESTRATION_N8N_ALLOW_INBOX_WRITE')) } catch { $fromEnv = '' }
    return (Test-N8nTruthyValue -Value $fromEnv)
}

function ConvertTo-N8nArgumentToken {
    param([string]$Value)
    $v = [string]$Value
    if ($v.Length -eq 0) { return '""' }
    if ($v -notmatch '[\s"]') { return $v }
    $token = '"'
    $slashes = 0
    foreach ($ch in $v.ToCharArray()) {
        if ($ch -eq '\') { $slashes++; continue }
        if ($ch -eq '"') {
            $token += ('\' * (($slashes * 2) + 1)) + '"'
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) { $token += ('\' * $slashes); $slashes = 0 }
        $token += $ch
    }
    if ($slashes -gt 0) { $token += ('\' * ($slashes * 2)) }
    $token += '"'
    return $token
}

function New-N8nCheckRecord {
    param([string]$Id, [string]$Status, [string]$Detail)
    return [pscustomobject]@{ id = [string]$Id; status = [string]$Status; detail = [string]$Detail }
}

function Invoke-N8nDockerCli {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 30
    )
    $exe = ([string]$Executable).Trim()
    if ([string]::IsNullOrWhiteSpace($exe)) { $exe = 'docker' }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $tokens = @()
        foreach ($arg in @($Arguments)) { $tokens += (ConvertTo-N8nArgumentToken -Value ([string]$arg)) }
        $psi.Arguments = ($tokens -join ' ')
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        $finished = $p.WaitForExit([int]($TimeoutSeconds * 1000))
        if (-not $finished) {
            try { $p.Kill() } catch { }
            try { $p.WaitForExit(5000) } catch { }
            return @{ started = $true; exit_code = -1; stdout = ''; stderr = 'TIMEOUT' }
        }
        $stdout = ''
        $stderr = ''
        try { $stdout = [string]$outTask.Result } catch { $stdout = '' }
        try { $stderr = [string]$errTask.Result } catch { $stderr = '' }
        $code = -1
        try { $code = [int]$p.ExitCode } catch { $code = -1 }
        try { $p.Close() } catch { }
        return @{ started = $true; exit_code = $code; stdout = $stdout; stderr = $stderr }
    }
    catch {
        return @{ started = $false; exit_code = -1; stdout = ''; stderr = [string]$_.Exception.Message }
    }
}

function New-N8nDockerArguments {
    param([string]$Context, [string[]]$VerbArguments)
    # The explicit context is always the first pair, so the default local daemon
    # can never be selected implicitly.
    return @('--context', [string]$Context) + @($VerbArguments)
}

function Invoke-N8nDockerStep {
    param(
        $Invoker,
        [string]$Executable,
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 30
    )
    $raw = $null
    if ($null -ne $Invoker) {
        try { $raw = & $Invoker -Arguments ([string[]]$Arguments) -TimeoutSeconds $TimeoutSeconds }
        catch { $raw = @{ started = $false; exit_code = -1; stdout = ''; stderr = [string]$_.Exception.Message } }
    }
    else {
        $raw = Invoke-N8nDockerCli -Executable $Executable -Arguments ([string[]]$Arguments) -TimeoutSeconds $TimeoutSeconds
    }
    $started = $false
    $code = -1
    $stdout = ''
    $stderr = ''
    try {
        if ($raw -is [System.Collections.IDictionary]) {
            $started = [bool]$raw['started']
            $code = [int]$raw['exit_code']
            $stdout = [string]$raw['stdout']
            $stderr = [string]$raw['stderr']
        }
        elseif ($null -ne $raw) {
            if ($null -ne $raw.PSObject.Properties['started']) { $started = [bool]$raw.started }
            if ($null -ne $raw.PSObject.Properties['exit_code']) { $code = [int]$raw.exit_code }
            if ($null -ne $raw.PSObject.Properties['stdout']) { $stdout = [string]$raw.stdout }
            if ($null -ne $raw.PSObject.Properties['stderr']) { $stderr = [string]$raw.stderr }
        }
    }
    catch { }
    return @{ started = $started; exit_code = $code; stdout = $stdout; stderr = $stderr }
}

function Invoke-N8nBoundedDockerStep {
    param(
        $Invoker,
        [string]$Executable,
        [string[]]$Arguments,
        $Budget,
        [int]$ReserveSeconds = 0
    )
    $timeout = Get-N8nBoundedDockerTimeout -Budget $Budget -ReserveSeconds $ReserveSeconds
    if ($timeout -lt 1) {
        return @{ started = $false; exit_code = -1; stdout = ''; stderr = ''; budget_exhausted = $true }
    }
    $step = Invoke-N8nDockerStep -Invoker $Invoker -Executable $Executable -Arguments ([string[]]$Arguments) -TimeoutSeconds $timeout
    $step['budget_exhausted'] = $false
    return $step
}

function Test-N8nDockerUnavailableText {
    param([string]$Text)
    $t = ([string]$Text).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($t)) { return $false }
    foreach ($needle in @(
        'cannot connect', 'failed to connect', 'is the docker daemon running',
        'docker_engine', 'error during connect', 'connection refused',
        'container is not running', 'no such container', 'is not running',
        'context does not exist', 'no such context', 'unable to resolve docker endpoint',
        'ssh: connect', 'ssh: handshake', 'permission denied (publickey)',
        'error while loading context', 'could not resolve'
    )) {
        if ($t.Contains($needle)) { return $true }
    }
    return $false
}

function New-N8nSmokeResult {
    param(
        [string]$Status,
        [string]$ErrorCode,
        $Checks = @(),
        $Transport = $null,
        $Source = $null,
        $Container = $null,
        $Mount = $null,
        $Probe = $null,
        $Cleanup = $null,
        [string]$Detail = ''
    )
    $ok = ($Status -ceq 'verified')
    # Keep the machine verdict below the shared 4000-character policy budget.
    # Decision fields (status/error and measured probe/cleanup facts) are never
    # truncated; only free-form diagnostics and the optional check list are.
    $boundedDetail = [string]$Detail
    if ($boundedDetail.Length -gt 160) { $boundedDetail = $boundedDetail.Substring(0, 157) + '...' }
    $boundedChecks = @()
    $allChecks = @($Checks)
    $checkLimit = 16
    foreach ($check in @($allChecks | Select-Object -First $checkLimit)) {
        $checkDetail = [string]$check.detail
        if ($checkDetail.Length -gt 64) { $checkDetail = $checkDetail.Substring(0, 61) + '...' }
        $boundedChecks += [pscustomobject]@{
            id = [string]$check.id
            status = [string]$check.status
            detail = $checkDetail
        }
    }
    if ($allChecks.Count -gt $checkLimit) {
        $boundedChecks += [pscustomobject]@{
            id = 'checks_truncated'
            status = 'ok'
            detail = [string]($allChecks.Count - $checkLimit) + ' omitted'
        }
    }
    return [pscustomobject]@{
        ok          = [bool]$ok
        verifier    = [string]$script:N8nSmokeVerifier
        status      = [string]$Status
        error       = [string]$ErrorCode
        detail      = $boundedDetail
        transport   = $Transport
        source      = $Source
        container   = $Container
        mount       = $Mount
        probe       = $Probe
        cleanup     = $Cleanup
        checks      = @($boundedChecks)
    }
}

function Get-N8nSmokeExitCode {
    param($Result)
    $status = ''
    try {
        if ($null -ne $Result) { $status = [string]$Result.status }
    }
    catch { $status = '' }
    if ($status -ceq 'verified') { return 0 }
    if ($status -ceq 'failed') { return 1 }
    return 2
}

function Get-N8nPropertyValue {
    param($Node, [string]$Name)
    if ($null -eq $Node) { return $null }
    try {
        if ($Node -is [System.Collections.IDictionary]) { return $Node[$Name] }
        $prop = $Node.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1
        if ($null -ne $prop) { return $prop.Value }
    }
    catch { }
    return $null
}

function Get-N8nSha256Hex {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { try { $sha.Dispose() } catch { } }
}

function New-N8nSentinelFile {
    # Atomic exclusive create (FileMode.CreateNew): an existing path is never
    # truncated or overwritten. A partial write is removed before returning so a
    # failed creation cannot leave a sentinel behind.
    param([string]$Path, [string]$Content)
    $state = @{ created = $false; bytes = 0; sha256 = ''; error = '' }
    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    }
    catch {
        if (Test-Path -LiteralPath $Path) { $state.error = 'PROBE_NAME_COLLISION' }
        else { $state.error = 'PROBE_WRITE_FAILED' }
        return $state
    }
    $state.created = $true
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $bytes = $utf8.GetBytes([string]$Content)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    catch {
        $state.error = 'PROBE_WRITE_FAILED'
        try { $stream.Dispose() } catch { }
        $stream = $null
        try {
            if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
        }
        catch { }
        if (-not (Test-Path -LiteralPath $Path)) { $state.created = $false }
        return $state
    }
    finally {
        if ($null -ne $stream) { try { $stream.Dispose() } catch { } }
    }
    try {
        $written = [IO.File]::ReadAllBytes($Path)
        $state.bytes = [int]$written.Length
        $state.sha256 = Get-N8nSha256Hex -Bytes $written
    }
    catch {
        $state.error = 'PROBE_WRITE_FAILED'
    }
    return $state
}

function Invoke-N8nContextCheck {
    param(
        $Invoker,
        [string]$Executable,
        [string]$Context,
        $Budget,
        [int]$ReserveSeconds = 0
    )
    $state = @{ ok = $false; error = ''; detail = ''; unavailable = $false }
    $args = New-N8nDockerArguments -Context $Context -VerbArguments @('context', 'inspect', $Context, '--format', $script:N8nSmokeContextInspectFormat)
    $step = Invoke-N8nBoundedDockerStep -Invoker $Invoker -Executable $Executable -Arguments $args -Budget $Budget -ReserveSeconds $ReserveSeconds
    if ([bool]$step['budget_exhausted']) { $state.error = 'RUNTIME_BUDGET_EXHAUSTED'; return $state }
    if (-not [bool]$step.started) {
        $state.error = 'DOCKER_CONTEXT_NOT_STARTED'
        $state.detail = Get-N8nSafeStepDetail -Step $step
        $state.unavailable = $true
        return $state
    }
    if ([int]$step.exit_code -ne 0) {
        $state.error = 'DOCKER_CONTEXT_INSPECT_FAILED'
        $state.detail = Get-N8nSafeStepDetail -Step $step
        if (Test-N8nDockerUnavailableText -Text ([string]$step.stderr)) {
            $state.error = 'DOCKER_UNAVAILABLE'
            $state.unavailable = $true
        }
        return $state
    }
    $endpoint = ''
    try {
        $endpoint = [string](ConvertFrom-Json -InputObject (([string]$step.stdout).Trim()))
    }
    catch { $endpoint = ([string]$step.stdout).Trim() }
    $endpoint = ([string]$endpoint).Trim()
    if ([string]::IsNullOrWhiteSpace($endpoint)) {
        $state.error = 'DOCKER_CONTEXT_ENDPOINT_INVALID'
        $state.detail = 'endpoint_empty'
        return $state
    }
    if (-not ($endpoint -ceq $script:N8nSmokeRequiredContextEndpoint)) {
        $state.error = 'DOCKER_CONTEXT_ENDPOINT_MISMATCH'
        $state.detail = 'endpoint_mismatch'
        return $state
    }
    $state.ok = $true
    return $state
}

function ConvertFrom-N8nInspectOutput {
    param([string]$Text)
    $parsed = @{ ok = $false; error = ''; detail = ''; record = $null }
    $raw = [string]$Text
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $parsed.error = 'INSPECT_OUTPUT_EMPTY'
        return $parsed
    }
    $lines = @($raw -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($lines.Count -ne 1) {
        $parsed.error = 'INSPECT_OUTPUT_RECORDS'
        $parsed.detail = [string]$lines.Count
        return $parsed
    }
    $parts = @(([string]$lines[0]).Split('|'))
    if ($parts.Count -ne 8) {
        $parsed.error = 'INSPECT_OUTPUT_FIELDS'
        $parsed.detail = [string]$parts.Count
        return $parsed
    }
    try {
        $name = [string](ConvertFrom-Json -InputObject ([string]$parts[0]))
        $image = [string](ConvertFrom-Json -InputObject ([string]$parts[1]))
        $statusText = [string](ConvertFrom-Json -InputObject ([string]$parts[2]))
        $running = [bool](ConvertFrom-Json -InputObject ([string]$parts[3]))
        $restarting = [bool](ConvertFrom-Json -InputObject ([string]$parts[4]))
        $paused = [bool](ConvertFrom-Json -InputObject ([string]$parts[5]))
        $healthNode = $null
        if (-not ([string]$parts[6] -ceq 'null')) {
            $healthNode = [string](ConvertFrom-Json -InputObject ([string]$parts[6]))
        }
        $mounts = @()
        $mountNode = ConvertFrom-Json -InputObject ([string]$parts[7])
        if ($null -ne $mountNode) { $mounts = @($mountNode) }
        $parsed.record = [pscustomobject]@{
            name        = $name
            image       = $image
            status      = $statusText
            running     = $running
            restarting  = $restarting
            paused      = $paused
            health      = $(if ($null -eq $healthNode) { '' } else { [string]$healthNode })
            healthcheck = ($null -ne $healthNode)
            mounts      = @($mounts)
        }
        $parsed.ok = $true
    }
    catch {
        $parsed.error = 'INSPECT_OUTPUT_INVALID'
        $parsed.detail = 'projection_parse_failed'
    }
    return $parsed
}

function Invoke-N8nUserProbe {
    param(
        $Invoker,
        [string]$Executable,
        [string]$Context,
        [string]$ContainerName,
        $Budget,
        [int]$ReserveSeconds = 0
    )
    $state = @{ ok = $false; user = ''; error = '' }
    $step = Invoke-N8nBoundedDockerStep -Invoker $Invoker -Executable $Executable -Arguments (New-N8nDockerArguments -Context $Context -VerbArguments @('exec', $ContainerName, 'id', '-un')) -Budget $Budget -ReserveSeconds $ReserveSeconds
    if ([bool]$step['budget_exhausted']) { $state.error = 'RUNTIME_BUDGET_EXHAUSTED'; return $state }
    if (-not [bool]$step.started) { $state.error = 'DOCKER_NOT_STARTED'; return $state }
    if ([int]$step.exit_code -ne 0) { $state.error = 'CONTAINER_USER_UNKNOWN'; return $state }
    $user = ([string]$step.stdout).Trim()
    if (($user.Length -gt 32) -or ($user -cnotmatch '\A[a-z_][a-z0-9_-]*\z')) {
        $state.user = 'UNKNOWN'
        $state.error = 'CONTAINER_USER_UNKNOWN'
        return $state
    }
    $state.user = $user
    if (-not ($user -ceq 'node')) { $state.error = 'CONTAINER_USER_MISMATCH'; return $state }
    $state.ok = $true
    return $state
}

function Invoke-N8nMountProbe {
    param(
        $Invoker,
        [string]$Executable,
        [string]$Context,
        [string]$ContainerName,
        [string]$HostInboxPath,
        [string]$ContainerDirectory,
        [string]$ProbeRelativeDirectory,
        [int]$Attempts,
        [int]$DelayMilliseconds,
        $Budget,
        [int]$ReserveSeconds = 0
    )
    $state = @{
        created        = $false
        file           = ''
        container_path = ''
        content        = ''
        bytes          = 0
        local_sha256   = ''
        remote_sha256  = ''
        visible        = $false
        matched        = $false
        readError      = ''
        cleanup        = [pscustomobject]@{ host_removed = $false; container_hidden = $false; error = ''; docker_exit = '' }
    }
    $probeName = $script:N8nSmokeProbePrefix + ([guid]::NewGuid().ToString('N')) + $script:N8nSmokeProbeSuffix
    $probePath = Join-Path (Join-Path $HostInboxPath '') $probeName
    $nonce = [guid]::NewGuid().ToString('N')
    $content = 'orchestration-n8n-mount-smoke' + "`n" + 'nonce=' + $nonce + "`n" + 'utc=' + [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture) + "`n"
    $relativeDir = ([string]$ProbeRelativeDirectory).Trim().Trim('/')
    if ([string]::IsNullOrWhiteSpace($relativeDir)) { $relative = $probeName }
    else { $relative = $relativeDir + '/' + $probeName }
    if ($ContainerDirectory -ceq '/') { $containerPath = '/' + $relative }
    else { $containerPath = $ContainerDirectory + '/' + $relative }
    $state.file = $probePath
    $state.container_path = $containerPath
    $state.content = $content
    try {
        if (-not (Test-N8nPathWithin -Parent $HostInboxPath -Child $probePath)) {
            $state.readError = 'PROBE_PATH_REJECTED'
            return $state
        }
        if (-not (Test-N8nSafeContainerPath -Path $containerPath)) {
            $state.readError = 'PROBE_PATH_REJECTED'
            return $state
        }
        if (Test-N8nReparsePoint -Path $HostInboxPath) {
            $state.readError = 'PROBE_PATH_REJECTED'
            return $state
        }
        if (Test-Path -LiteralPath $probePath) {
            $state.readError = 'PROBE_NAME_COLLISION'
            return $state
        }
        $created = New-N8nSentinelFile -Path $probePath -Content $content
        $state.created = [bool]$created.created
        if (-not [string]::IsNullOrWhiteSpace([string]$created.error)) {
            $state.readError = [string]$created.error
            return $state
        }
        $state.bytes = [int]$created.bytes
        $state.local_sha256 = [string]$created.sha256
        if (Test-N8nReparsePoint -Path $probePath) {
            $state.readError = 'PROBE_PATH_REJECTED'
            return $state
        }
        for ($i = 0; $i -lt [int]$Attempts; $i++) {
            $test = Invoke-N8nBoundedDockerStep -Invoker $Invoker -Executable $Executable -Arguments (New-N8nDockerArguments -Context $Context -VerbArguments @('exec', $ContainerName, 'test', '-f', $containerPath)) -Budget $Budget -ReserveSeconds $ReserveSeconds
            if ([bool]$test['budget_exhausted']) {
                $state.readError = 'PROBE_TIMEOUT'
                return $state
            }
            if ([bool]$test.started -and ([int]$test.exit_code -eq 0)) { $state.visible = $true; break }
            if (($i + 1) -lt [int]$Attempts) {
                $delay = Get-N8nBoundedDelayMilliseconds -Budget $Budget -DelayMilliseconds $DelayMilliseconds
                if ($delay -lt 1) {
                    $state.readError = 'PROBE_TIMEOUT'
                    return $state
                }
                Start-Sleep -Milliseconds $delay
            }
        }
        if (-not $state.visible) {
            $state.readError = 'PROBE_NOT_VISIBLE'
            return $state
        }
        $read = Invoke-N8nBoundedDockerStep -Invoker $Invoker -Executable $Executable -Arguments (New-N8nDockerArguments -Context $Context -VerbArguments @('exec', $ContainerName, 'cat', $containerPath)) -Budget $Budget -ReserveSeconds $ReserveSeconds
        if ([bool]$read['budget_exhausted']) {
            $state.readError = 'PROBE_TIMEOUT'
            return $state
        }
        if ((-not [bool]$read.started) -or ([int]$read.exit_code -ne 0)) {
            $state.readError = 'PROBE_READ_FAILED'
            return $state
        }
        $actual = [string]$read.stdout
        $remoteBytes = [Text.Encoding]::UTF8.GetBytes($actual)
        $state.remote_sha256 = Get-N8nSha256Hex -Bytes $remoteBytes
        if ($actual -ceq $content) { $state.matched = $true }
        else { $state.readError = 'PROBE_CONTENT_MISMATCH' }
        return $state
    }
    catch {
        $state.readError = 'PROBE_ERROR'
        return $state
    }
    finally {
        $cleanup = $state.cleanup
        try {
            if ($state.created) {
                $leaf = Split-Path -Leaf $probePath
                $parent = Split-Path -Parent $probePath
                $safeLeaf = ($leaf -cmatch ('\A' + [regex]::Escape($script:N8nSmokeProbePrefix) + '[0-9a-f]{32}' + [regex]::Escape($script:N8nSmokeProbeSuffix) + '\z'))
                $sameParent = ((Get-N8nComparablePath -Path $parent) -ceq (Get-N8nComparablePath -Path $HostInboxPath))
                if ($safeLeaf -and $sameParent) {
                    if (Test-Path -LiteralPath $probePath -PathType Leaf) {
                        Remove-Item -LiteralPath $probePath -Force -ErrorAction Stop
                    }
                    if (-not (Test-Path -LiteralPath $probePath)) { $cleanup.host_removed = $true }
                    else { $cleanup.error = 'HOST_REMOVE_VERIFY_FAILED' }
                }
                else {
                    $cleanup.error = 'CLEANUP_TARGET_REJECTED'
                }
            }
            if ($state.created -and $cleanup.host_removed) {
                # A missing file is proven only when the container is live in
                # the same observation and the file probe has no transport error.
                $hidden = $false
                $verdictKnown = $false
                for ($j = 0; $j -lt [int]$Attempts; $j++) {
                    $live = Invoke-N8nBoundedDockerStep -Invoker $Invoker -Executable $Executable -Arguments (New-N8nDockerArguments -Context $Context -VerbArguments @('exec', $ContainerName, 'test', '-d', $ContainerDirectory)) -Budget $Budget -ReserveSeconds 0
                    if ([bool]$live['budget_exhausted']) {
                        $cleanup.error = 'CLEANUP_TIMEOUT'
                        $cleanup.docker_exit = 'not_started'
                        $verdictKnown = $true
                        break
                    }
                    if ((-not [bool]$live.started) -or ([int]$live.exit_code -ne 0)) {
                        $cleanup.error = 'CONTAINER_UNREACHABLE_DURING_CLEANUP'
                        $cleanup.docker_exit = Get-N8nSafeStepDetail -Step $live
                        $verdictKnown = $true
                        break
                    }
                    $still = Invoke-N8nBoundedDockerStep -Invoker $Invoker -Executable $Executable -Arguments (New-N8nDockerArguments -Context $Context -VerbArguments @('exec', $ContainerName, 'test', '-f', $containerPath)) -Budget $Budget -ReserveSeconds 0
                    if ([bool]$still['budget_exhausted']) {
                        $cleanup.error = 'CLEANUP_TIMEOUT'
                        $cleanup.docker_exit = 'not_started'
                        $verdictKnown = $true
                        break
                    }
                    if (-not [bool]$still.started) {
                        $cleanup.error = 'CLEANUP_TRANSPORT_FAILED'
                        $cleanup.docker_exit = 'not_started'
                        $verdictKnown = $true
                        break
                    }
                    $code = [int]$still.exit_code
                    $cleanup.docker_exit = [string]$code
                    if (($code -eq 1) -and (Test-N8nDockerUnavailableText -Text ([string]$still.stderr))) {
                        $cleanup.error = 'CLEANUP_TRANSPORT_FAILED'
                        $verdictKnown = $true
                        break
                    }
                    if ($code -eq 1) { $hidden = $true; break }
                    if ($code -ne 0) {
                        $cleanup.error = 'CLEANUP_TRANSPORT_FAILED'
                        $verdictKnown = $true
                        break
                    }
                    if (($j + 1) -lt [int]$Attempts) {
                        $delay = Get-N8nBoundedDelayMilliseconds -Budget $Budget -DelayMilliseconds $DelayMilliseconds
                        if ($delay -lt 1) {
                            $cleanup.error = 'CLEANUP_TIMEOUT'
                            $verdictKnown = $true
                            break
                        }
                        Start-Sleep -Milliseconds $delay
                    }
                }
                $cleanup.container_hidden = $hidden
                if ((-not $hidden) -and (-not $verdictKnown)) { $cleanup.error = 'CONTAINER_STILL_VISIBLE' }
            }
        }
        catch { $cleanup.error = 'CLEANUP_FAILED' }
    }
}

function Invoke-N8nMountSmoke {
    [CmdletBinding()]
    param(
        [string]$ContainerName = '',
        [string]$MountDestination = '',
        [string]$DockerContext = '',
        [string]$DockerExecutable = '',
        [string]$LocalSyncRoot = '',
        [string]$RemoteSyncRoot = '',
        [int]$ProbeAttempts = 20,
        [int]$ProbeDelayMilliseconds = 1500,
        [int]$RuntimeBudgetSeconds = 0,
        [switch]$AllowProductionInboxWrite,
        [switch]$RequireHealthcheck,
        [scriptblock]$DockerInvoker = $null
    )
    $checks = New-Object System.Collections.ArrayList
    function Add-Check {
        param([string]$Id, [string]$Status, [string]$Detail)
        [void]$checks.Add((New-N8nCheckRecord -Id $Id -Status $Status -Detail $Detail))
    }

    $containerValue = Get-N8nSmokeConfigValue -Explicit $ContainerName -EnvName 'ORCHESTRATION_N8N_CONTAINER' -Default 'n8n'
    $destinationValue = Get-N8nSmokeConfigValue -Explicit $MountDestination -EnvName 'ORCHESTRATION_N8N_SYNCTHING_MOUNT_DEST' -Default ''
    $contextValue = Get-N8nSmokeConfigValue -Explicit $DockerContext -EnvName 'ORCHESTRATION_N8N_DOCKER_CONTEXT' -Default 'contabo-prod'
    $dockerValue = Get-N8nSmokeConfigValue -Explicit $DockerExecutable -EnvName 'ORCHESTRATION_N8N_DOCKER_EXECUTABLE' -Default 'docker'
    $localRootValue = Get-N8nSmokeConfigValue -Explicit $LocalSyncRoot -EnvName '' -Default 'D:\Sync'
    $remoteRootValue = Get-N8nSmokeConfigValue -Explicit $RemoteSyncRoot -EnvName '' -Default '/home/deploy/Sync'
    $requireHealth = [bool]$RequireHealthcheck
    if (-not $requireHealth) {
        $healthEnv = ''
        try { $healthEnv = [string]([Environment]::GetEnvironmentVariable('ORCHESTRATION_N8N_REQUIRE_HEALTHCHECK')) } catch { $healthEnv = '' }
        $requireHealth = Test-N8nTruthyValue -Value $healthEnv
    }

    if (-not (Test-N8nSafeContainerName -Name $containerValue)) {
        Add-Check 'container_name_safe' 'fail' ('invalid container name: ' + $containerValue)
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'CONTAINER_NAME_INVALID' -Checks $checks.ToArray() -Detail 'container name must match ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$')
    }
    Add-Check 'container_name_safe' 'ok' $containerValue

    if (-not (Test-N8nSafeContextName -Name $contextValue)) {
        Add-Check 'docker_context_safe' 'fail' $contextValue
        if ($contextValue -match '^(?i)default$') {
            return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'DOCKER_CONTEXT_LOCAL_REFUSED' -Checks $checks.ToArray() -Detail 'the default local daemon is refused; configure the remote ssh context (contabo-prod)')
        }
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'DOCKER_CONTEXT_INVALID' -Checks $checks.ToArray() -Detail 'context must match ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ and must not be default')
    }
    Add-Check 'docker_context_safe' 'ok' $contextValue

    if ([string]::IsNullOrWhiteSpace($destinationValue)) {
        Add-Check 'config_anchor' 'fail' 'container destination is not configured'
        return (New-N8nSmokeResult -Status 'not_configured' -ErrorCode 'CONFIG_REQUIRED' -Checks $checks.ToArray() -Detail 'set ORCHESTRATION_N8N_SYNCTHING_MOUNT_DEST (or -MountDestination) to the expected container path of the read-only inbox mount')
    }
    $trimmedDest = $destinationValue
    while (($trimmedDest.Length -gt 1) -and $trimmedDest.EndsWith('/')) { $trimmedDest = $trimmedDest.Substring(0, $trimmedDest.Length - 1) }
    if (-not (Test-N8nSafeContainerPath -Path $trimmedDest)) {
        Add-Check 'destination_safe' 'fail' $destinationValue
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'DESTINATION_INVALID' -Checks $checks.ToArray() -Detail 'destination must be an absolute POSIX path without spaces or shell characters')
    }
    $destinationValue = $trimmedDest
    Add-Check 'destination_safe' 'ok' $destinationValue
    Add-Check 'config_anchor' 'ok' ('destination=' + $destinationValue)

    if (-not (Test-N8nDockerExecutableSafe -Executable $dockerValue)) {
        Add-Check 'docker_executable_safe' 'fail' 'unsafe script wrapper refused'
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'DOCKER_EXECUTABLE_UNSAFE' -Checks $checks.ToArray() -Detail 'the docker executable must not be a .cmd/.bat/.ps1 script wrapper; use docker.exe or docker on PATH')
    }
    Add-Check 'docker_executable_safe' 'ok' 'not a script wrapper'

    if (-not (Test-N8nWriteOptIn -Explicit:$AllowProductionInboxWrite)) {
        Add-Check 'write_opt_in' 'fail' 'operator opt-in is required'
        return (New-N8nSmokeResult -Status 'not_configured' -ErrorCode 'WRITE_OPT_IN_REQUIRED' -Checks $checks.ToArray() -Detail 'this verifier writes a disposable sentinel into the production inbox; opt in with -AllowProductionInboxWrite or ORCHESTRATION_N8N_ALLOW_INBOX_WRITE=1 (default off)')
    }
    Add-Check 'write_opt_in' 'ok' 'explicit operator opt-in'

    $dockerHost = ''
    try { $dockerHost = [string]([Environment]::GetEnvironmentVariable('DOCKER_HOST')) } catch { $dockerHost = '' }
    if (-not [string]::IsNullOrWhiteSpace($dockerHost)) {
        Add-Check 'transport_context_only' 'fail' 'DOCKER_HOST is set'
        return (New-N8nSmokeResult -Status 'unavailable' -ErrorCode 'DOCKER_HOST_REFUSED' -Checks $checks.ToArray() -Detail 'DOCKER_HOST is refused; the verifier only accepts an explicit remote ssh context')
    }
    $overrideNames = @('DOCKER_CONFIG', 'DOCKER_CERT_PATH', 'DOCKER_TLS_VERIFY', 'DOCKER_TLS')
    $refusedOverride = ''
    foreach ($overrideName in $overrideNames) {
        $overrideValue = ''
        try { $overrideValue = [string]([Environment]::GetEnvironmentVariable($overrideName)) } catch { $overrideValue = '' }
        if (-not [string]::IsNullOrWhiteSpace($overrideValue)) { $refusedOverride = $overrideName; break }
    }
    if (-not [string]::IsNullOrWhiteSpace($refusedOverride)) {
        Add-Check 'transport_env_safe' 'fail' ($refusedOverride + ' is set')
        return (New-N8nSmokeResult -Status 'unavailable' -ErrorCode 'DOCKER_ENV_OVERRIDE_REFUSED' -Checks $checks.ToArray() -Detail 'nonempty DOCKER_CONFIG/DOCKER_CERT_PATH/DOCKER_TLS_VERIFY/DOCKER_TLS overrides are refused; unset them')
    }
    Add-Check 'transport_env_safe' 'ok' 'no docker config/cert/tls override'
    $dockerContextEnv = ''
    try { $dockerContextEnv = [string]([Environment]::GetEnvironmentVariable('DOCKER_CONTEXT')) } catch { $dockerContextEnv = '' }
    if ((-not [string]::IsNullOrWhiteSpace($dockerContextEnv)) -and (-not ($dockerContextEnv.Trim() -ceq $contextValue))) {
        Add-Check 'transport_context_only' 'fail' 'DOCKER_CONTEXT differs from the requested context'
        return (New-N8nSmokeResult -Status 'unavailable' -ErrorCode 'DOCKER_CONTEXT_CONFLICT' -Checks $checks.ToArray() -Detail 'DOCKER_CONTEXT conflicts with the requested context; unset it or use the same value')
    }
    Add-Check 'transport_context_only' 'ok' ('--context ' + $contextValue)

    $budget = New-N8nRuntimeBudget -Seconds $RuntimeBudgetSeconds
    $transportView = [pscustomobject]@{
        context              = $contextValue
        docker_host          = ''
        mode                 = 'explicit-context'
        required_endpoint    = [string]$script:N8nSmokeRequiredContextEndpoint
        runtime_budget_seconds = [int]$budget.seconds
        cleanup_reserve_seconds = [int]$script:N8nSmokeCleanupReserveSeconds
    }

    # Local side: the dedicated inbox must exist inside the local sync root.
    $localRootFull = ''
    try { if ([IO.Path]::IsPathRooted($localRootValue)) { $localRootFull = [IO.Path]::GetFullPath($localRootValue) } } catch { $localRootFull = '' }
    if ([string]::IsNullOrWhiteSpace($localRootFull)) {
        Add-Check 'local_sync_root' 'fail' $localRootValue
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'SYNC_ROOT_INVALID' -Checks $checks.ToArray() -Detail 'the local sync root must be an absolute path')
    }
    $localSourceRoot = ''
    try { $localSourceRoot = [IO.Path]::GetPathRoot($localRootFull) } catch { $localSourceRoot = '' }
    $systemRoot = ''
    try { $systemRoot = [string]$env:SystemRoot } catch { $systemRoot = '' }
    if ((-not [string]::IsNullOrWhiteSpace($localSourceRoot)) -and ((Get-N8nComparablePath -Path $localSourceRoot) -ceq (Get-N8nComparablePath -Path $localRootFull))) {
        Add-Check 'local_sync_root' 'fail' $localRootFull
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'SYNC_ROOT_INVALID' -Checks $checks.ToArray() -Detail 'the local sync root may not be a drive root')
    }
    if ((-not [string]::IsNullOrWhiteSpace($systemRoot)) -and (Test-N8nPathWithin -Parent $systemRoot -Child $localRootFull)) {
        Add-Check 'local_sync_root' 'fail' $localRootFull
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'SYNC_ROOT_INVALID' -Checks $checks.ToArray() -Detail 'the local sync root may not live under the system directory')
    }
    if (-not (Test-Path -LiteralPath $localRootFull -PathType Container)) {
        Add-Check 'local_sync_root' 'fail' $localRootFull
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'SYNC_ROOT_NOT_FOUND' -Checks $checks.ToArray() -Detail 'the local sync root must already exist')
    }
    if (Test-N8nReparsePoint -Path $localRootFull) {
        Add-Check 'local_sync_root' 'fail' 'reparse point refused'
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'SYNC_ROOT_REPARSE_POINT' -Checks $checks.ToArray() -Detail 'the local sync root may not be a reparse point (symlink or junction); reparse redirection is refused')
    }
    $localRootFull = $localRootFull.TrimEnd('\', '/')
    Add-Check 'local_sync_root' 'ok' $localRootFull
    $localInbox = Join-Path $localRootFull $script:N8nSmokeInboxLeaf
    if (-not (Test-Path -LiteralPath $localInbox -PathType Container)) {
        Add-Check 'source_exists' 'fail' $localInbox
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'SOURCE_NOT_FOUND' -Checks $checks.ToArray() -Detail 'the dedicated local inbox must already exist; it is never created by this verifier')
    }
    if (Test-N8nReparsePoint -Path $localInbox) {
        Add-Check 'source_exists' 'fail' 'reparse point refused'
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'INBOX_REPARSE_POINT' -Checks $checks.ToArray() -Detail 'the dedicated local inbox may not be a reparse point (symlink or junction); reparse redirection is refused')
    }
    Add-Check 'source_exists' 'ok' $localInbox

    # Remote side: the expected bind source derives from the remote sync root.
    $remoteRootKey = Get-N8nComparablePath -Path $remoteRootValue -CaseSensitive
    if (-not (Test-N8nSafeContainerPath -Path $remoteRootKey)) {
        Add-Check 'remote_sync_root' 'fail' $remoteRootValue
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'REMOTE_SYNC_ROOT_INVALID' -Checks $checks.ToArray() -Detail 'the remote sync root must be an absolute POSIX path without spaces or shell characters')
    }
    $remoteInbox = $remoteRootKey + '/' + $script:N8nSmokeInboxLeaf
    if (-not (Test-N8nSafeContainerPath -Path $remoteInbox)) {
        Add-Check 'remote_sync_root' 'fail' $remoteInbox
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'REMOTE_SYNC_ROOT_INVALID' -Checks $checks.ToArray())
    }
    Add-Check 'remote_sync_root' 'ok' $remoteInbox

    $sourceView = [pscustomobject]@{
        local_sync_root = $localRootFull
        local_inbox     = $localInbox
        remote_sync_root = $remoteRootKey
        remote_inbox    = $remoteInbox
    }

    $contextCheck = Invoke-N8nContextCheck -Invoker $DockerInvoker -Executable $dockerValue -Context $contextValue -Budget $budget -ReserveSeconds $script:N8nSmokeCleanupReserveSeconds
    if (-not [bool]$contextCheck.ok) {
        Add-Check 'docker_context_endpoint' 'fail' ([string]$contextCheck.error)
        $contextStatus = 'failed'
        if ([bool]$contextCheck.unavailable) { $contextStatus = 'unavailable' }
        return (New-N8nSmokeResult -Status $contextStatus -ErrorCode ([string]$contextCheck.error) -Checks $checks.ToArray() -Transport $transportView -Source $sourceView -Detail ('docker context endpoint validation failed: ' + [string]$contextCheck.detail))
    }
    Add-Check 'docker_context_endpoint' 'ok' 'exact ssh://deploy@contabo-prod endpoint'

    $inspectArgs = New-N8nDockerArguments -Context $contextValue -VerbArguments @('inspect', '--format', $script:N8nSmokeInspectFormat, $containerValue)
    $inspect = Invoke-N8nBoundedDockerStep -Invoker $DockerInvoker -Executable $dockerValue -Arguments $inspectArgs -Budget $budget -ReserveSeconds $script:N8nSmokeCleanupReserveSeconds
    if ([bool]$inspect['budget_exhausted']) {
        Add-Check 'docker_available' 'fail' 'runtime budget exhausted before inspect'
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'RUNTIME_BUDGET_EXHAUSTED' -Checks $checks.ToArray() -Transport $transportView -Source $sourceView -Detail 'the bounded runtime budget was exhausted before the inspect call')
    }
    if (-not [bool]$inspect.started) {
        Add-Check 'docker_available' 'fail' (Get-N8nSafeStepDetail -Step $inspect)
        return (New-N8nSmokeResult -Status 'unavailable' -ErrorCode 'DOCKER_NOT_STARTED' -Checks $checks.ToArray() -Transport $transportView -Source $sourceView -Detail 'docker CLI could not be started')
    }
    if ([int]$inspect.exit_code -ne 0) {
        $unavailable = Test-N8nDockerUnavailableText -Text ([string]$inspect.stderr)
        Add-Check 'docker_available' 'fail' (Get-N8nSafeStepDetail -Step $inspect)
        if ($unavailable) {
            return (New-N8nSmokeResult -Status 'unavailable' -ErrorCode 'DOCKER_UNAVAILABLE' -Checks $checks.ToArray() -Transport $transportView -Source $sourceView -Detail ('docker context ' + $contextValue + ' is not reachable'))
        }
        if (([string]$inspect.stderr) -match '(?i)no such (object|container)') {
            return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'CONTAINER_NOT_FOUND' -Checks $checks.ToArray() -Transport $transportView -Source $sourceView -Detail ('inspect exited ' + [string]$inspect.exit_code))
        }
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'INSPECT_FAILED' -Checks $checks.ToArray() -Transport $transportView -Source $sourceView -Detail ('inspect exited ' + [string]$inspect.exit_code))
    }
    Add-Check 'docker_available' 'ok' ('inspect succeeded through context ' + $contextValue)

    $parsed = ConvertFrom-N8nInspectOutput -Text ([string]$inspect.stdout)
    if (-not [bool]$parsed.ok) {
        Add-Check 'inspect_output' 'fail' ([string]$parsed.error + ' ' + [string]$parsed.detail)
        $code = 'INSPECT_INVALID'
        if ([string]$parsed.error -ceq 'INSPECT_OUTPUT_RECORDS') { $code = 'CONTAINER_AMBIGUOUS' }
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode $code -Checks $checks.ToArray() -Transport $transportView -Source $sourceView -Detail 'inspect output did not match the fixed field projection')
    }
    Add-Check 'inspect_output' 'ok' 'fixed 8-field projection parsed'
    $record = $parsed.record

    $reportedRawName = [string]$record.name
    if (-not $reportedRawName.StartsWith('/')) {
        Add-Check 'container_identity' 'fail' 'inspect name missing the leading slash'
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'CONTAINER_IDENTITY_MISMATCH' -Checks $checks.ToArray() -Transport $transportView -Source $sourceView)
    }
    $reportedName = $reportedRawName.Substring(1)
    if (-not ($reportedName -ceq $containerValue)) {
        Add-Check 'container_identity' 'fail' ('reported=' + $reportedName + ' expected=' + $containerValue)
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'CONTAINER_IDENTITY_MISMATCH' -Checks $checks.ToArray() -Transport $transportView -Source $sourceView)
    }
    Add-Check 'container_identity' 'ok' $reportedName

    $image = [string]$record.image
    if (-not (Test-N8nOfficialImageRepository -Image $image)) {
        Add-Check 'container_image' 'fail' $image
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'CONTAINER_NOT_N8N' -Checks $checks.ToArray() -Transport $transportView -Source $sourceView -Detail 'the resolved container image is not an official n8n repository form (n8nio/n8n or docker.n8n.io/n8nio/n8n)')
    }
    Add-Check 'container_image' 'ok' $image

    $statusText = [string]$record.status
    $running = [bool]$record.running
    $restarting = [bool]$record.restarting
    $paused = [bool]$record.paused
    $healthStatus = [string]$record.health
    $hasHealth = [bool]$record.healthcheck
    $containerView = [pscustomobject]@{
        name        = $reportedName
        image       = $image
        status      = $statusText
        running     = $running
        restarting  = $restarting
        paused      = $paused
        health      = $healthStatus
        healthcheck = $hasHealth
    }
    if (-not $running) {
        Add-Check 'container_running' 'fail' ('status=' + $statusText)
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'CONTAINER_NOT_RUNNING' -Checks $checks.ToArray() -Transport $transportView -Source $sourceView -Container $containerView)
    }
    Add-Check 'container_running' 'ok' ('status=' + $statusText)
    if ($restarting) {
        Add-Check 'container_not_restarting' 'fail' 'Restarting=true'
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'CONTAINER_RESTARTING' -Checks $checks.ToArray() -Transport $transportView -Source $sourceView -Container $containerView)
    }
    Add-Check 'container_not_restarting' 'ok' 'Restarting=false'
    if ($paused) {
        Add-Check 'container_not_paused' 'fail' 'Paused=true'
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'CONTAINER_PAUSED' -Checks $checks.ToArray() -Transport $transportView -Source $sourceView -Container $containerView)
    }
    Add-Check 'container_not_paused' 'ok' 'Paused=false'
    if ($hasHealth) {
        if (-not ($healthStatus -ceq 'healthy')) {
            Add-Check 'container_health' 'fail' ('health=' + $healthStatus)
            return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'CONTAINER_UNHEALTHY' -Checks $checks.ToArray() -Transport $transportView -Source $sourceView -Container $containerView)
        }
        Add-Check 'container_health' 'ok' 'health=healthy'
    }
    else {
        if ($requireHealth) {
            Add-Check 'container_health' 'fail' 'healthcheck required but not defined'
            return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'CONTAINER_HEALTHCHECK_MISSING' -Checks $checks.ToArray() -Transport $transportView -Source $sourceView -Container $containerView -Detail 'the container has no Docker healthcheck while a healthcheck is required')
        }
        Add-Check 'container_health' 'ok' 'no healthcheck defined; running is the contractual health signal'
    }

    $mounts = @($record.mounts)
    if ($mounts.Count -lt 1) {
        Add-Check 'mount_present' 'fail' 'inspect reports no mounts'
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'MOUNT_NOT_FOUND' -Checks $checks.ToArray() -Transport $transportView -Source $sourceView -Container $containerView)
    }
    $candidates = @()
    $matchedKind = ''
    foreach ($m in $mounts) {
        if ($null -eq $m) { continue }
        $sourceSeen = Get-N8nComparablePath -Path ([string](Get-N8nPropertyValue -Node $m -Name 'Source')) -CaseSensitive
        if ($sourceSeen -ceq $remoteInbox) { $candidates += $m; if ($matchedKind -eq '') { $matchedKind = 'inbox' } }
        elseif ($sourceSeen -ceq $remoteRootKey) { $candidates += $m; if ($matchedKind -eq '') { $matchedKind = 'sync_root' } }
    }
    if ($candidates.Count -eq 0) {
        Add-Check 'mount_present' 'fail' ('no mount source matches ' + $remoteInbox + ' or ' + $remoteRootKey)
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'MOUNT_NOT_FOUND' -Checks $checks.ToArray() -Transport $transportView -Source $sourceView -Container $containerView)
    }
    if ($candidates.Count -gt 1) {
        Add-Check 'mount_unique' 'fail' ('matched ' + [string]$candidates.Count + ' mounts')
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'MOUNT_AMBIGUOUS' -Checks $checks.ToArray() -Transport $transportView -Source $sourceView -Container $containerView)
    }
    Add-Check 'mount_present' 'ok' 'exactly one dedicated source mount'

    $mount = $candidates[0]
    $mountType = [string](Get-N8nPropertyValue -Node $mount -Name 'Type')
    $mountSource = [string](Get-N8nPropertyValue -Node $mount -Name 'Source')
    $mountDestination = [string](Get-N8nPropertyValue -Node $mount -Name 'Destination')
    $mountMode = [string](Get-N8nPropertyValue -Node $mount -Name 'Mode')
    $mountRw = $true
    $rwValue = Get-N8nPropertyValue -Node $mount -Name 'RW'
    if ($rwValue -is [bool]) { $mountRw = [bool]$rwValue }
    elseif ($null -ne $rwValue) { $mountRw = ([string]$rwValue -ieq 'true') }
    $mountView = [pscustomobject]@{
        type        = $mountType
        source      = $mountSource
        destination = $mountDestination
        mode        = $mountMode
        readonly    = (-not $mountRw)
        matched     = $matchedKind
    }
    if (-not ($mountType -ceq 'bind')) {
        Add-Check 'mount_type_bind' 'fail' ('type=' + $mountType)
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'MOUNT_NOT_BIND' -Checks $checks.ToArray() -Transport $transportView -Source $sourceView -Container $containerView -Mount $mountView)
    }
    Add-Check 'mount_type_bind' 'ok' 'type=bind'
    if (-not ((Get-N8nComparablePath -Path $mountDestination -CaseSensitive) -ceq (Get-N8nComparablePath -Path $destinationValue -CaseSensitive))) {
        Add-Check 'mount_destination' 'fail' ('reported=' + $mountDestination + ' expected=' + $destinationValue)
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'MOUNT_DESTINATION_MISMATCH' -Checks $checks.ToArray() -Transport $transportView -Source $sourceView -Container $containerView -Mount $mountView)
    }
    Add-Check 'mount_destination' 'ok' $mountDestination
    $modeOk = $true
    if (-not [string]::IsNullOrWhiteSpace($mountMode)) {
        $modeTokens = @($mountMode.Split(',') | ForEach-Object { $_.Trim().ToLowerInvariant() })
        $modeOk = (($modeTokens -contains 'ro') -and (-not ($modeTokens -contains 'rw')))
    }
    $mountView.readonly = ((-not $mountRw) -and $modeOk)
    if ($mountRw -or (-not $modeOk)) {
        Add-Check 'mount_readonly' 'fail' ('RW=' + [string]$mountRw + '; Mode=' + $mountMode)
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'MOUNT_NOT_READONLY' -Checks $checks.ToArray() -Transport $transportView -Source $sourceView -Container $containerView -Mount $mountView)
    }
    Add-Check 'mount_readonly' 'ok' ('RW=false; Mode=' + $mountMode)
    foreach ($other in $mounts) {
        if ($null -eq $other) { continue }
        $otherSource = [string](Get-N8nPropertyValue -Node $other -Name 'Source')
        $otherDestination = [string](Get-N8nPropertyValue -Node $other -Name 'Destination')
        $isSame = ((Get-N8nComparablePath -Path $otherSource -CaseSensitive) -ceq (Get-N8nComparablePath -Path $mountSource -CaseSensitive)) -and ((Get-N8nComparablePath -Path $otherDestination -CaseSensitive) -ceq (Get-N8nComparablePath -Path $mountDestination -CaseSensitive))
        if ($isSame) { continue }
        if ((Test-N8nPathWithin -Parent $mountDestination -Child $otherDestination -CaseSensitive) -or (Test-N8nPathWithin -Parent $otherDestination -Child $mountDestination -CaseSensitive)) {
            Add-Check 'mount_not_shadowed' 'fail' ('overlapping mount destination: ' + $otherDestination)
            return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'MOUNT_SHADOWED' -Checks $checks.ToArray() -Transport $transportView -Source $sourceView -Container $containerView -Mount $mountView)
        }
    }
    Add-Check 'mount_not_shadowed' 'ok' 'no overlapping mount destination'

    $userProbe = Invoke-N8nUserProbe -Invoker $DockerInvoker -Executable $dockerValue -Context $contextValue -ContainerName $containerValue -Budget $budget -ReserveSeconds $script:N8nSmokeCleanupReserveSeconds
    $probeUserView = [pscustomobject]@{
        user  = [string]$userProbe.user
        error = [string]$userProbe.error
    }
    if (-not [bool]$userProbe.ok) {
        Add-Check 'container_user' 'fail' ([string]$userProbe.error + ' ' + [string]$userProbe.user)
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode ([string]$userProbe.error) -Checks $checks.ToArray() -Transport $transportView -Source $sourceView -Container $containerView -Mount $mountView -Probe $probeUserView)
    }
    Add-Check 'container_user' 'ok' ('user=' + [string]$userProbe.user)

    $probeDirectory = ''
    if ($matchedKind -ceq 'sync_root') { $probeDirectory = $script:N8nSmokeInboxLeaf }
    $probe = Invoke-N8nMountProbe -Invoker $DockerInvoker -Executable $dockerValue -Context $contextValue -ContainerName $containerValue -HostInboxPath $localInbox -ContainerDirectory $mountDestination -ProbeRelativeDirectory $probeDirectory -Attempts $ProbeAttempts -DelayMilliseconds $ProbeDelayMilliseconds -Budget $budget -ReserveSeconds $script:N8nSmokeCleanupReserveSeconds
    $probeView = [pscustomobject]@{
        file           = [string]$probe.file
        container_path = [string]$probe.container_path
        user           = [string]$userProbe.user
        visible        = [bool]$probe.visible
        content_match  = [bool]$probe.matched
        bytes          = [int]$probe.bytes
        local_sha256   = [string]$probe.local_sha256
        remote_sha256  = [string]$probe.remote_sha256
    }
    if ([bool]$probe.created -and (-not [bool]$probe.cleanup.host_removed)) {
        Add-Check 'cleanup_host' 'fail' ([string]$probe.cleanup.error)
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'CLEANUP_FAILED' -Checks $checks.ToArray() -Transport $transportView -Source $sourceView -Container $containerView -Mount $mountView -Probe $probeView -Cleanup $probe.cleanup -Detail ([string]$probe.cleanup.error))
    }
    if (-not $probe.visible) {
        Add-Check 'probe_visible' 'fail' ([string]$probe.readError)
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode ([string]$probe.readError) -Checks $checks.ToArray() -Transport $transportView -Source $sourceView -Container $containerView -Mount $mountView -Probe $probeView -Cleanup $probe.cleanup)
    }
    Add-Check 'probe_visible' 'ok' ('visible at ' + [string]$probe.container_path + ' after write')
    if (-not $probe.matched) {
        Add-Check 'probe_content' 'fail' ([string]$probe.readError)
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode ([string]$probe.readError) -Checks $checks.ToArray() -Transport $transportView -Source $sourceView -Container $containerView -Mount $mountView -Probe $probeView -Cleanup $probe.cleanup)
    }
    Add-Check 'probe_content' 'ok' ('sha256=' + [string]$probe.local_sha256)
    if (-not [bool]$probe.cleanup.host_removed) {
        Add-Check 'cleanup_host' 'fail' ([string]$probe.cleanup.error)
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode 'CLEANUP_FAILED' -Checks $checks.ToArray() -Transport $transportView -Source $sourceView -Container $containerView -Mount $mountView -Probe $probeView -Cleanup $probe.cleanup)
    }
    Add-Check 'cleanup_host' 'ok' 'sentinel removed from the local inbox'
    if (-not [bool]$probe.cleanup.container_hidden) {
        $cleanupDetail = [string]$probe.cleanup.error
        if (-not [string]::IsNullOrWhiteSpace([string]$probe.cleanup.docker_exit)) {
            $cleanupDetail = $cleanupDetail + ' docker_exit=' + [string]$probe.cleanup.docker_exit
        }
        Add-Check 'cleanup_container' 'fail' $cleanupDetail
        $cleanupErrorCode = 'CLEANUP_NOT_VERIFIED'
        if ([string]$probe.cleanup.error -ceq 'CONTAINER_UNREACHABLE_DURING_CLEANUP') { $cleanupErrorCode = 'CONTAINER_UNREACHABLE_DURING_CLEANUP' }
        return (New-N8nSmokeResult -Status 'failed' -ErrorCode $cleanupErrorCode -Checks $checks.ToArray() -Transport $transportView -Source $sourceView -Container $containerView -Mount $mountView -Probe $probeView -Cleanup $probe.cleanup -Detail ([string]$probe.cleanup.error))
    }
    Add-Check 'cleanup_container' 'ok' 'sentinel no longer visible in the container'
    return (New-N8nSmokeResult -Status 'verified' -ErrorCode '' -Checks $checks.ToArray() -Transport $transportView -Source $sourceView -Container $containerView -Mount $mountView -Probe $probeView -Cleanup $probe.cleanup)
}

if ($MyInvocation.InvocationName -ne '.') {
    $final = $null
    try {
        $final = Invoke-N8nMountSmoke -ContainerName $ContainerName -MountDestination $MountDestination -DockerContext $DockerContext -DockerExecutable $DockerExecutable -LocalSyncRoot $LocalSyncRoot -RemoteSyncRoot $RemoteSyncRoot -ProbeAttempts $ProbeAttempts -ProbeDelayMilliseconds $ProbeDelayMilliseconds -RuntimeBudgetSeconds $RuntimeBudgetSeconds -AllowProductionInboxWrite:$AllowProductionInboxWrite -RequireHealthcheck:$RequireHealthcheck
    }
    catch {
        $final = New-N8nSmokeResult -Status 'failed' -ErrorCode 'INTERNAL_ERROR' -Detail 'internal verifier error'
    }
    try { Write-Output (ConvertTo-Json -InputObject $final -Compress -Depth 10) }
    catch { Write-Output ('{"ok":false,"status":"failed","error":"OUTPUT_FAILED"}') }
    exit (Get-N8nSmokeExitCode -Result $final)
}
