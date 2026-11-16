<#
.SYNOPSIS
    Focused tests for the Windows-side n8n Syncthing inbox mount verifier.
.DESCRIPTION
    Process-local and function-level tests for
    scripts/v3/n8n-syncthing-mount-smoke.ps1 and its verification-policy
    profile. A fake docker invoker simulates the fixed command forms
    (`--context <ctx> inspect --format <template> <container>`,
    `exec <container> id -un`, `exec <container> test -f <path>` and
    `exec <container> cat <path>`) so no docker daemon, context, container,
    network or real inbox is required. Every probe runs against a throwaway
    temp directory that stands in for the sync root; the fake rejects any
    command outside the contract and records every call so the tests can prove
    the context prefix, the field projection and the absence of secrets.

    PowerShell 5.1/7 compatible, ASCII-only, temporary files only.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:Passed = 0
$script:Failed = 0
$script:SmokePath = Join-Path $PSScriptRoot 'n8n-syncthing-mount-smoke.ps1'
$script:VerifierLib = Join-Path $PSScriptRoot 'lib\OrchestrationVerifier.ps1'
$script:PolicyPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'source\registry\verification-policy.json'
$script:HostExe = ''
try { $script:HostExe = [string](Get-Process -Id $PID).Path } catch { }
if ([string]::IsNullOrWhiteSpace($script:HostExe)) {
    if ($PSVersionTable.PSEdition -eq 'Core') { $script:HostExe = Join-Path $PSHOME 'pwsh.exe' }
    else { $script:HostExe = Join-Path $PSHOME 'powershell.exe' }
}

function Assert-N8nSmoke {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) { Write-Host ('[PASS] ' + $Name); $script:Passed++ }
    else {
        Write-Host ('[FAIL] ' + $Name + $(if ([string]::IsNullOrWhiteSpace($Detail)) { '' } else { ' -- ' + $Detail }))
        $script:Failed++
    }
}

$env:ORCHESTRATION_N8N_CONTAINER = ''
$env:ORCHESTRATION_N8N_SYNCTHING_MOUNT_DEST = ''
$env:ORCHESTRATION_N8N_DOCKER_CONTEXT = ''
$env:ORCHESTRATION_N8N_DOCKER_EXECUTABLE = ''
$env:ORCHESTRATION_N8N_REQUIRE_HEALTHCHECK = ''
$env:ORCHESTRATION_N8N_ALLOW_INBOX_WRITE = ''
$env:DOCKER_HOST = ''
$env:DOCKER_CONTEXT = ''
$env:DOCKER_CONFIG = ''
$env:DOCKER_CERT_PATH = ''
$env:DOCKER_TLS_VERIFY = ''
$env:DOCKER_TLS = ''

if (-not (Test-Path -LiteralPath $script:SmokePath -PathType Leaf)) {
    Assert-N8nSmoke $false 'smoke script exists' $script:SmokePath
    Write-Host ''
    Write-Host ('N8N-MOUNT-SMOKE: ' + $script:Passed + ' passed / ' + $script:Failed + ' failed')
    exit 1
}
. $script:SmokePath
. $script:VerifierLib

$script:RemoteRoot = '/home/deploy/Sync'
$script:RemoteInbox = '/home/deploy/Sync/synkroo-forge-inbox'
$script:Context = 'contabo-prod'

function New-N8nMountSpec {
    param(
        [string]$Source,
        [string]$Destination = '/data/inbox',
        [string]$Type = 'bind',
        [bool]$ReadWrite = $false,
        [string]$Mode = 'ro'
    )
    return [ordered]@{ Type = $Type; Source = $Source; Destination = $Destination; Mode = $Mode; RW = $ReadWrite; Propagation = 'rprivate' }
}

function New-N8nInspectSpec {
    param(
        [string]$Name = 'n8n',
        [string]$Image = 'docker.n8n.io/n8nio/n8n:2.0.0',
        [bool]$Running = $true,
        [bool]$Restarting = $false,
        [bool]$Paused = $false,
        [string]$StatusText = 'running',
        [string]$Health = 'healthy',
        $Mounts = @()
    )
    $state = [ordered]@{ Status = $StatusText; Running = $Running; Restarting = $Restarting; Paused = $Paused }
    if (-not [string]::IsNullOrEmpty($Health)) { $state['Health'] = [ordered]@{ Status = $Health } }
    return [ordered]@{
        Id     = 'c0ffee'
        Name   = ('/' + $Name)
        Config = [ordered]@{ Image = $Image }
        State  = $state
        Mounts = @($Mounts)
    }
}

function New-N8nInspectLine {
    param($Document)
    if ($null -eq $Document) { return '' }
    $state = $Document.State
    $healthLiteral = 'null'
    if ($null -ne $state.Health) {
        $healthLiteral = ConvertTo-Json -InputObject ([string]$state.Health.Status) -Compress
    }
    $mounts = @($Document.Mounts)
    $mountLiteral = 'null'
    if ($mounts.Count -gt 0) {
        $mountLiteral = ConvertTo-Json -InputObject $mounts -Depth 8 -Compress
    }
    $parts = @(
        (ConvertTo-Json -InputObject ([string]$Document.Name) -Compress),
        (ConvertTo-Json -InputObject ([string]$Document.Config.Image) -Compress),
        (ConvertTo-Json -InputObject ([string]$state.Status) -Compress),
        (ConvertTo-Json -InputObject ([bool]$state.Running) -Compress),
        (ConvertTo-Json -InputObject ([bool]$state.Restarting) -Compress),
        (ConvertTo-Json -InputObject ([bool]$state.Paused) -Compress),
        $healthLiteral,
        $mountLiteral
    )
    return ($parts -join '|')
}

function New-N8nFakeState {
    param(
        $Document = $null,
        [string]$HostRoot = '',
        [string]$ContainerRoot = '/data/inbox',
        [string]$ExpectContext = 'contabo-prod'
    )
    return @{
        Document       = $Document
        InspectExit    = 0
        InspectStderr  = ''
        InspectOutput  = $null
        ContextExit    = 0
        ContextOutput  = ('"' + 'ssh://deploy@contabo-prod' + '"')
        ContextFormat  = ''
        ContextStarted = $true
        HostRoot       = $HostRoot
        ContainerRoot  = $ContainerRoot
        ExpectContext  = $ExpectContext
        User           = 'node'
        UserExit       = 0
        StillVisible   = $false
        TestCallCount  = 0
        CleanupTestExit = $null
        CleanupTestStarted = $true
        CleanupTestStderr = ''
        LivenessExit = 0
        LivenessStarted = $true
        LivenessStderr = ''
        LivenessCallCount = 0
        CatAs          = $null
        InspectFormat  = ''
        Timeouts       = (New-Object System.Collections.ArrayList)
        Calls          = (New-Object System.Collections.ArrayList)
        Violations     = (New-Object System.Collections.ArrayList)
    }
}

function Get-N8nFakeHostPath {
    param($State, [string]$ContainerPath)
    $root = [string]$State.ContainerRoot
    if (-not $ContainerPath.StartsWith($root + '/')) { return '' }
    $relative = $ContainerPath.Substring($root.Length + 1)
    return (Join-Path ([string]$State.HostRoot) ($relative -replace '/', '\'))
}

$script:fake = New-N8nFakeState
$script:fakeInvoker = {
    param([string[]]$Arguments, [int]$TimeoutSeconds)
    $f = $script:fake
    $a = @($Arguments)
    [void]$f.Calls.Add(($a -join ' '))
    [void]$f.Timeouts.Add([int]$TimeoutSeconds)
    if (($a.Count -lt 3) -or ($a[0] -cne '--context')) {
        [void]$f.Violations.Add('missing context prefix: ' + ($a -join ' '))
        return @{ started = $true; exit_code = 125; stdout = ''; stderr = 'CONTRACT_CONTEXT' }
    }
    if (-not ([string]$a[1] -ceq [string]$f.ExpectContext)) {
        [void]$f.Violations.Add('unexpected context: ' + [string]$a[1])
        return @{ started = $true; exit_code = 125; stdout = ''; stderr = 'CONTRACT_CONTEXT' }
    }
    $verb = [string]$a[2]
    if ($verb -ceq 'context') {
        if (($a.Count -ne 7) -or ($a[3] -cne 'inspect') -or ($a[4] -cne [string]$f.ExpectContext) -or ($a[5] -cne '--format')) {
            [void]$f.Violations.Add('context inspect shape: ' + ($a -join ' '))
            return @{ started = $true; exit_code = 125; stdout = ''; stderr = 'CONTRACT_CONTEXT' }
        }
        $f.ContextFormat = [string]$a[6]
        return @{ started = [bool]$f.ContextStarted; exit_code = [int]$f.ContextExit; stdout = [string]$f.ContextOutput; stderr = '' }
    }
    if ($verb -ceq 'inspect') {
        if (($a.Count -ne 6) -or ($a[3] -cne '--format') -or ($a[5] -cne 'n8n')) {
            [void]$f.Violations.Add('inspect shape: ' + ($a -join ' '))
            return @{ started = $true; exit_code = 125; stdout = ''; stderr = 'CONTRACT_INSPECT' }
        }
        $f.InspectFormat = [string]$a[4]
        $text = ''
        if ($null -ne $f.Document) { $text = New-N8nInspectLine -Document $f.Document }
        if ($null -ne $f.InspectOutput) { $text = [string]$f.InspectOutput }
        return @{ started = $true; exit_code = [int]$f.InspectExit; stdout = $text; stderr = [string]$f.InspectStderr }
    }
    if ($verb -ceq 'exec') {
        if (($a.Count -lt 5) -or ($a[3] -cne 'n8n')) {
            [void]$f.Violations.Add('exec shape: ' + ($a -join ' '))
            return @{ started = $true; exit_code = 125; stdout = ''; stderr = 'CONTRACT_EXEC' }
        }
        $op = [string]$a[4]
        if ($op -ceq 'id') {
            if (($a.Count -ne 6) -or ($a[5] -cne '-un')) {
                [void]$f.Violations.Add('exec id shape: ' + ($a -join ' '))
                return @{ started = $true; exit_code = 125; stdout = ''; stderr = 'CONTRACT_EXEC' }
            }
            return @{ started = $true; exit_code = [int]$f.UserExit; stdout = [string]$f.User; stderr = '' }
        }
        if ($op -ceq 'test') {
            if (($a.Count -ne 7) -or (@('-f', '-d') -cnotcontains [string]$a[5])) {
                [void]$f.Violations.Add('exec test shape: ' + ($a -join ' '))
                return @{ started = $true; exit_code = 125; stdout = ''; stderr = 'CONTRACT_EXEC' }
            }
            if ($a[5] -ceq '-d') {
                $f.LivenessCallCount = [int]$f.LivenessCallCount + 1
                return @{ started = [bool]$f.LivenessStarted; exit_code = [int]$f.LivenessExit; stdout = ''; stderr = [string]$f.LivenessStderr }
            }
            $f.TestCallCount = [int]$f.TestCallCount + 1
            if (($f.TestCallCount -gt 1) -and ($null -ne $f.CleanupTestExit)) {
                return @{ started = [bool]$f.CleanupTestStarted; exit_code = [int]$f.CleanupTestExit; stdout = ''; stderr = [string]$f.CleanupTestStderr }
            }
            if ([bool]$f.StillVisible) { return @{ started = $true; exit_code = 0; stdout = ''; stderr = '' } }
            $hostPath = Get-N8nFakeHostPath -State $f -ContainerPath ([string]$a[6])
            $code = 1
            if ((-not [string]::IsNullOrWhiteSpace($hostPath)) -and (Test-Path -LiteralPath $hostPath -PathType Leaf)) { $code = 0 }
            return @{ started = $true; exit_code = $code; stdout = ''; stderr = '' }
        }
        if ($op -ceq 'cat') {
            if ($a.Count -ne 6) {
                [void]$f.Violations.Add('exec cat shape: ' + ($a -join ' '))
                return @{ started = $true; exit_code = 125; stdout = ''; stderr = 'CONTRACT_EXEC' }
            }
            $hostPath = Get-N8nFakeHostPath -State $f -ContainerPath ([string]$a[5])
            if (([string]::IsNullOrWhiteSpace($hostPath)) -or (-not (Test-Path -LiteralPath $hostPath -PathType Leaf))) {
                return @{ started = $true; exit_code = 1; stdout = ''; stderr = 'cat: no such file' }
            }
            $text = [IO.File]::ReadAllText($hostPath)
            if ($null -ne $f.CatAs) { $text = [string]$f.CatAs }
            return @{ started = $true; exit_code = 0; stdout = $text; stderr = '' }
        }
        [void]$f.Violations.Add('unsupported exec op: ' + $op)
        return @{ started = $true; exit_code = 125; stdout = ''; stderr = 'CONTRACT_EXEC' }
    }
    [void]$f.Violations.Add('unsupported verb: ' + $verb)
    return @{ started = $true; exit_code = 125; stdout = ''; stderr = 'CONTRACT_VERB' }
}

function Invoke-N8nSmokeCase {
    param([hashtable]$State, [hashtable]$CaseArguments = @{})
    $script:fake = $State
    $splat = @{
        ContainerName          = 'n8n'
        MountDestination       = '/data/inbox'
        DockerContext          = 'contabo-prod'
        LocalSyncRoot          = [string]$script:syncRoot
        RemoteSyncRoot         = [string]$script:RemoteRoot
        ProbeAttempts          = 1
        ProbeDelayMilliseconds = 0
        RuntimeBudgetSeconds   = 60
        AllowProductionInboxWrite = $true
        DockerInvoker          = $script:fakeInvoker
    }
    foreach ($k in @($CaseArguments.Keys)) { $splat[[string]$k] = $CaseArguments[$k] }
    return (Invoke-N8nMountSmoke @splat)
}

function Test-N8nSentinelLeftovers {
    param([string]$Directory, [switch]$LeafOnly)
    $found = @()
    if ($LeafOnly) {
        $found = @(Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\.orchestration-mount-smoke-[0-9a-f]{32}\.tmp$' })
    }
    else {
        $found = @(Get-ChildItem -LiteralPath $Directory -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\.orchestration-mount-smoke-[0-9a-f]{32}\.tmp$' })
    }
    return ($found.Count -gt 0)
}

function Invoke-N8nSmokeCli {
    param([string[]]$CliArgs)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:HostExe
    $quoted = @()
    foreach ($arg in @($CliArgs)) { $quoted += ('"' + ([string]$arg).Replace('"', '\"') + '"') }
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:SmokePath + '" ' + ($quoted -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $exitCode = [int]$process.ExitCode
    $process.Dispose()
    $json = $null
    try { if (-not [string]::IsNullOrWhiteSpace($stdout)) { $json = ConvertFrom-Json -InputObject $stdout } } catch { }
    return [pscustomobject]@{ ExitCode = $exitCode; Stdout = $stdout.Trim(); Stderr = $stderr.Trim(); Json = $json }
}

$script:root = Join-Path ([IO.Path]::GetTempPath()) ('n8n-mount-smoke-' + [Guid]::NewGuid().ToString('N'))
$script:syncRoot = Join-Path $script:root 'sync'
$script:localInbox = Join-Path $script:syncRoot 'synkroo-forge-inbox'
$script:decoyInbox = Join-Path $script:root 'decoy-inbox'
$script:emptySyncRoot = Join-Path $script:root 'empty-sync'
$script:keepFile = Join-Path $script:localInbox 'keep-existing.txt'
$script:rootKeepFile = Join-Path $script:syncRoot 'root-keep.txt'

try {
    [void][IO.Directory]::CreateDirectory($script:localInbox)
    [void][IO.Directory]::CreateDirectory($script:decoyInbox)
    [void][IO.Directory]::CreateDirectory($script:emptySyncRoot)
    [IO.File]::WriteAllText($script:keepFile, 'preexisting', [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText($script:rootKeepFile, 'preexisting-root', [Text.Encoding]::ASCII)

    $goodMount = New-N8nMountSpec -Source $script:RemoteInbox
    $goodDocument = New-N8nInspectSpec -Mounts @($goodMount)

    # 1. happy path: remote inbox bind, ro, node user, visible and identical
    $goodState = New-N8nFakeState -Document $goodDocument -HostRoot $script:localInbox
    $good = Invoke-N8nSmokeCase -State $goodState
    Assert-N8nSmoke (([string]$good.status -ceq 'verified') -and ([bool]$good.ok)) 'remote context + ro inbox bind + node + visible probe => verified' ([string]$good.status + ' ' + [string]$good.error)
    Assert-N8nSmoke ((Get-N8nSmokeExitCode -Result $good) -eq 0) 'verified maps to exit 0'
    Assert-N8nSmoke ($goodState.Violations.Count -eq 0) 'fake received only allowlisted command shapes' ($goodState.Violations -join '; ')
    Assert-N8nSmoke ((@($goodState.Calls | Where-Object { -not ([string]$_).StartsWith('--context contabo-prod ') }).Count -eq 0)) 'every docker call carries --context contabo-prod'
    Assert-N8nSmoke ([string]$good.transport.context -ceq 'contabo-prod') 'verdict reports the explicit context'
    Assert-N8nSmoke ([string]$goodState.InspectFormat -ceq $script:N8nSmokeInspectFormat) 'inspect uses the fixed field projection'
    Assert-N8nSmoke ($goodState.InspectFormat -notmatch '(?i)env') 'inspect projection never mentions environment fields'
    Assert-N8nSmoke (([string]$good.source.local_inbox -ceq $script:localInbox) -and ([string]$good.source.remote_inbox -ceq $script:RemoteInbox)) 'verdict reports local and remote dedicated sources'
    Assert-N8nSmoke (([string]$good.probe.user -ceq 'node') -and ([string]$good.mount.matched -ceq 'inbox')) 'probe ran as node against the inbox bind'
    Assert-N8nSmoke (([int]$good.probe.bytes -gt 0) -and ([string]$good.probe.local_sha256 -match '^[0-9a-f]{64}$')) 'probe reports bytes and local sha256'
    Assert-N8nSmoke ([string]$good.probe.local_sha256 -ceq [string]$good.probe.remote_sha256) 'local and remote sha256 match byte-for-byte'
    Assert-N8nSmoke (([bool]$good.cleanup.host_removed) -and ([bool]$good.cleanup.container_hidden)) 'cleanup verified on both sides'
    Assert-N8nSmoke (($goodState.LivenessCallCount -gt 0) -and ([string]$goodState.Calls[$goodState.Calls.Count - 2] -match 'exec n8n test -d /data/inbox$') -and ([string]$goodState.Calls[$goodState.Calls.Count - 1] -match 'exec n8n test -f ')) 'cleanup file absence is preceded by positive liveness in the same attempt'
    Assert-N8nSmoke (-not (Test-N8nSentinelLeftovers -Directory $script:syncRoot)) 'no sentinel left anywhere under the sync root'
    Assert-N8nSmoke (-not (Test-N8nSentinelLeftovers -Directory $script:syncRoot -LeafOnly)) 'no sentinel left at the sync root level'
    Assert-N8nSmoke (Test-Path -LiteralPath $script:keepFile -PathType Leaf) 'pre-existing inbox file preserved'
    Assert-N8nSmoke (Test-Path -LiteralPath $script:rootKeepFile -PathType Leaf) 'pre-existing sync root file preserved'
    $execOps = @($goodState.Calls | Where-Object { ([string]$_ -split ' ')[2] -ceq 'exec' } | ForEach-Object { ([string]$_ -split ' ')[4] } | Sort-Object -Unique)
    Assert-N8nSmoke ((@($execOps | Where-Object { @('id', 'test', 'cat') -notcontains $_ }).Count -eq 0) -and ($execOps.Count -eq 3)) 'exec only used id, test and cat' ($execOps -join ',')
    $catCall = @($goodState.Calls | Where-Object { ([string]$_ -split ' ')[4] -ceq 'cat' } | Select-Object -First 1)
    Assert-N8nSmoke (($catCall.Count -eq 1) -and ([string]$catCall[0] -match '^--context contabo-prod exec n8n cat /data/inbox/\.orchestration-mount-smoke-[0-9a-f]{32}\.tmp$')) 'sentinel is uniquely named and read through the mount' ([string]$catCall)
    Assert-N8nSmoke (@($good.checks | Where-Object { [string]$_.status -cne 'ok' }).Count -eq 0) 'every check reports ok on the happy path'

    # 2. sync-root bind: the dedicated inbox may live inside the mounted tree
    $rootState = New-N8nFakeState -Document (New-N8nInspectSpec -Mounts @((New-N8nMountSpec -Source $script:RemoteRoot -Destination '/data/files'))) -HostRoot $script:localInbox -ContainerRoot '/data/files/synkroo-forge-inbox'
    $rootBind = Invoke-N8nSmokeCase -State $rootState -CaseArguments @{ MountDestination = '/data/files' }
    Assert-N8nSmoke (([string]$rootBind.status -ceq 'verified') -and ([string]$rootBind.mount.matched -ceq 'sync_root')) 'sync-root bind with the dedicated inbox inside => verified' ([string]$rootBind.status + ' ' + [string]$rootBind.error)
    $rootCat = @($rootState.Calls | Where-Object { ([string]$_ -split ' ')[4] -ceq 'cat' } | Select-Object -First 1)
    Assert-N8nSmoke (($rootCat.Count -eq 1) -and ([string]$rootCat[0] -match '/data/files/synkroo-forge-inbox/\.orchestration-mount-smoke-[0-9a-f]{32}\.tmp$')) 'sync-root probe targets the dedicated inbox subdirectory' ([string]$rootCat)
    Assert-N8nSmoke (-not (Test-N8nSentinelLeftovers -Directory $script:syncRoot)) 'sync-root probe leaves no sentinel'

    # 3. required configuration
    $noConfigState = New-N8nFakeState -Document $goodDocument -HostRoot $script:localInbox
    $noConfig = Invoke-N8nSmokeCase -State $noConfigState -CaseArguments @{ MountDestination = '' }
    Assert-N8nSmoke (([string]$noConfig.status -ceq 'not_configured') -and ([string]$noConfig.error -ceq 'CONFIG_REQUIRED')) 'missing container destination => not_configured' ([string]$noConfig.status + ' ' + [string]$noConfig.error)
    Assert-N8nSmoke ((Get-N8nSmokeExitCode -Result $noConfig) -eq 2) 'not_configured maps to exit 2'
    Assert-N8nSmoke ($noConfigState.Calls.Count -eq 0) 'not_configured issues no docker call'

    # 3b. production write opt-in (default off)
    $noOptInState = New-N8nFakeState -Document $goodDocument -HostRoot $script:localInbox
    $noOptIn = Invoke-N8nSmokeCase -State $noOptInState -CaseArguments @{ AllowProductionInboxWrite = $false }
    Assert-N8nSmoke (([string]$noOptIn.status -ceq 'not_configured') -and ([string]$noOptIn.error -ceq 'WRITE_OPT_IN_REQUIRED')) 'without operator opt-in the write is refused' ([string]$noOptIn.status + ' ' + [string]$noOptIn.error)
    Assert-N8nSmoke ((Get-N8nSmokeExitCode -Result $noOptIn) -eq 2) 'missing opt-in maps to exit 2'
    Assert-N8nSmoke ($noOptInState.Calls.Count -eq 0) 'missing opt-in issues no docker call'
    Assert-N8nSmoke (-not (Test-N8nSentinelLeftovers -Directory $script:syncRoot)) 'missing opt-in writes no sentinel'
    $env:ORCHESTRATION_N8N_ALLOW_INBOX_WRITE = '1'
    $envOptInState = New-N8nFakeState -Document $goodDocument -HostRoot $script:localInbox
    $envOptIn = Invoke-N8nSmokeCase -State $envOptInState -CaseArguments @{ AllowProductionInboxWrite = $false }
    $env:ORCHESTRATION_N8N_ALLOW_INBOX_WRITE = ''
    Assert-N8nSmoke ([string]$envOptIn.status -ceq 'verified') 'environment opt-in enables the write' ([string]$envOptIn.status + ' ' + [string]$envOptIn.error)
    $env:ORCHESTRATION_N8N_ALLOW_INBOX_WRITE = '0'
    $optOutState = New-N8nFakeState -Document $goodDocument -HostRoot $script:localInbox
    $optOut = Invoke-N8nSmokeCase -State $optOutState -CaseArguments @{ AllowProductionInboxWrite = $false }
    $env:ORCHESTRATION_N8N_ALLOW_INBOX_WRITE = ''
    Assert-N8nSmoke ([string]$optOut.error -ceq 'WRITE_OPT_IN_REQUIRED') 'falsey environment opt-in stays off'

    # 4. transport contract
    $env:DOCKER_HOST = 'tcp://10.0.0.9:2375'
    $hostState = New-N8nFakeState -Document $goodDocument -HostRoot $script:localInbox
    $hostTransport = Invoke-N8nSmokeCase -State $hostState
    $env:DOCKER_HOST = ''
    Assert-N8nSmoke (([string]$hostTransport.status -ceq 'unavailable') -and ([string]$hostTransport.error -ceq 'DOCKER_HOST_REFUSED')) 'DOCKER_HOST is refused' ([string]$hostTransport.error)
    Assert-N8nSmoke ($hostState.Calls.Count -eq 0) 'refused DOCKER_HOST issues no docker call'
    $hostJson = ConvertTo-Json -InputObject $hostTransport -Compress -Depth 10
    Assert-N8nSmoke ($hostJson -notmatch '10\.0\.0\.9') 'refused DOCKER_HOST value is never serialized'
    $overrideValues = @{
        DOCKER_CONFIG     = 'C:\synthetic-docker-config'
        DOCKER_CERT_PATH  = 'C:\synthetic-docker-certs'
        DOCKER_TLS_VERIFY = '1'
        DOCKER_TLS        = '1'
    }
    foreach ($overrideName in @($overrideValues.Keys | Sort-Object)) {
        $overrideValue = [string]$overrideValues[$overrideName]
        Set-Item -Path ('Env:' + $overrideName) -Value $overrideValue
        $overrideState = New-N8nFakeState -Document $goodDocument -HostRoot $script:localInbox
        $overrideResult = Invoke-N8nSmokeCase -State $overrideState
        Remove-Item -Path ('Env:' + $overrideName) -ErrorAction SilentlyContinue
        Assert-N8nSmoke (([string]$overrideResult.status -ceq 'unavailable') -and ([string]$overrideResult.error -ceq 'DOCKER_ENV_OVERRIDE_REFUSED')) ($overrideName + ' override is refused') ([string]$overrideResult.error)
        Assert-N8nSmoke ($overrideState.Calls.Count -eq 0) ($overrideName + ' override issues no docker call')
        $overrideJson = ConvertTo-Json -InputObject $overrideResult -Compress -Depth 10
        Assert-N8nSmoke ($overrideJson -notmatch [regex]::Escape($overrideValue)) ($overrideName + ' value is never serialized')
    }
    $env:DOCKER_CONTEXT = 'local-context'
    $conflictState = New-N8nFakeState -Document $goodDocument -HostRoot $script:localInbox
    $conflict = Invoke-N8nSmokeCase -State $conflictState
    $env:DOCKER_CONTEXT = ''
    Assert-N8nSmoke (([string]$conflict.status -ceq 'unavailable') -and ([string]$conflict.error -ceq 'DOCKER_CONTEXT_CONFLICT')) 'conflicting DOCKER_CONTEXT is refused' ([string]$conflict.error)
    Assert-N8nSmoke ($conflictState.Calls.Count -eq 0) 'conflicting DOCKER_CONTEXT issues no docker call'
    $env:DOCKER_CONTEXT = 'contabo-prod'
    $sameContextState = New-N8nFakeState -Document $goodDocument -HostRoot $script:localInbox
    $sameContext = Invoke-N8nSmokeCase -State $sameContextState
    $env:DOCKER_CONTEXT = ''
    Assert-N8nSmoke ([string]$sameContext.status -ceq 'verified') 'matching DOCKER_CONTEXT is accepted'
    Assert-N8nSmoke ([string](Invoke-N8nSmokeCase -State (New-N8nFakeState -HostRoot $script:localInbox) -CaseArguments @{ DockerContext = 'default' }).error -ceq 'DOCKER_CONTEXT_LOCAL_REFUSED') 'default local context is refused'
    Assert-N8nSmoke ([string](Invoke-N8nSmokeCase -State (New-N8nFakeState -HostRoot $script:localInbox) -CaseArguments @{ DockerContext = 'bad ctx; rm -rf /' }).error -ceq 'DOCKER_CONTEXT_INVALID') 'unsafe context name is blocked'
    $unreachableState = New-N8nFakeState -HostRoot $script:localInbox
    $unreachableState.InspectExit = 1
    $unreachableState.InspectStderr = 'unable to resolve docker endpoint: context "contabo-prod" does not exist'
    $unreachable = Invoke-N8nSmokeCase -State $unreachableState
    Assert-N8nSmoke (([string]$unreachable.status -ceq 'unavailable') -and ([string]$unreachable.error -ceq 'DOCKER_UNAVAILABLE')) 'unreachable ssh context => unavailable' ([string]$unreachable.error)
    $unreachableJson = ConvertTo-Json -InputObject $unreachable -Compress -Depth 10
    Assert-N8nSmoke ($unreachableJson -notmatch 'unable to resolve') 'raw docker/ssh stderr is never serialized'

    # 4b. docker context endpoint validation (one fixed context inspect form)
    Assert-N8nSmoke ([string]$goodState.ContextFormat -ceq $script:N8nSmokeContextInspectFormat) 'context probe uses the fixed endpoint projection'
    $contextCall = @($goodState.Calls | Where-Object { ([string]$_ -split ' ')[2] -ceq 'context' } | Select-Object -First 1)
    Assert-N8nSmoke (($contextCall.Count -eq 1) -and ([string]$contextCall[0] -ceq '--context contabo-prod context inspect contabo-prod --format ' + $script:N8nSmokeContextInspectFormat)) 'context endpoint probe uses exactly one fixed docker context inspect form' ([string]$contextCall)
    $mismatchState = New-N8nFakeState -Document $goodDocument -HostRoot $script:localInbox
    $mismatchState.ContextOutput = '"ssh://deploy@contabo-prod.evil"'
    $mismatch = Invoke-N8nSmokeCase -State $mismatchState
    Assert-N8nSmoke (([string]$mismatch.status -ceq 'failed') -and ([string]$mismatch.error -ceq 'DOCKER_CONTEXT_ENDPOINT_MISMATCH')) 'non-exact context endpoint blocks' ([string]$mismatch.error)
    Assert-N8nSmoke ($mismatchState.Calls.Count -eq 1) 'endpoint mismatch stops before the main inspect'
    $emptyEndpointState = New-N8nFakeState -Document $goodDocument -HostRoot $script:localInbox
    $emptyEndpointState.ContextOutput = ''
    Assert-N8nSmoke ([string](Invoke-N8nSmokeCase -State $emptyEndpointState).error -ceq 'DOCKER_CONTEXT_ENDPOINT_INVALID') 'empty context endpoint blocks'
    $contextStartedState = New-N8nFakeState -Document $goodDocument -HostRoot $script:localInbox
    $contextStartedState.ContextStarted = $false
    $contextStarted = Invoke-N8nSmokeCase -State $contextStartedState
    Assert-N8nSmoke (([string]$contextStarted.status -ceq 'unavailable') -and ([string]$contextStarted.error -ceq 'DOCKER_CONTEXT_NOT_STARTED')) 'unstarted context probe is unavailable'
    $contextExitState = New-N8nFakeState -Document $goodDocument -HostRoot $script:localInbox
    $contextExitState.ContextExit = 125
    $contextExit = Invoke-N8nSmokeCase -State $contextExitState
    Assert-N8nSmoke (([string]$contextExit.status -ceq 'failed') -and ([string]$contextExit.error -ceq 'DOCKER_CONTEXT_INSPECT_FAILED')) 'context probe client error blocks' ([string]$contextExit.error)
    Assert-N8nSmoke ($contextExitState.Calls.Count -eq 1) 'context probe failure stops before the main inspect'

    # 5. source and destination guards
    $missingInbox = Invoke-N8nSmokeCase -State (New-N8nFakeState -HostRoot $script:localInbox) -CaseArguments @{ LocalSyncRoot = $script:emptySyncRoot }
    Assert-N8nSmoke (([string]$missingInbox.error -ceq 'SOURCE_NOT_FOUND') -and ((Get-N8nSmokeExitCode -Result $missingInbox) -eq 1)) 'missing dedicated local inbox blocks' ([string]$missingInbox.error)
    $missingRoot = Invoke-N8nSmokeCase -State (New-N8nFakeState -HostRoot $script:localInbox) -CaseArguments @{ LocalSyncRoot = (Join-Path $script:root 'no-such-root') }
    Assert-N8nSmoke ([string]$missingRoot.error -ceq 'SYNC_ROOT_NOT_FOUND') 'missing local sync root blocks'
    $driveRoot = [IO.Path]::GetPathRoot($script:root)
    $driveResult = Invoke-N8nSmokeCase -State (New-N8nFakeState -HostRoot $script:localInbox) -CaseArguments @{ LocalSyncRoot = $driveRoot }
    Assert-N8nSmoke ([string]$driveResult.error -ceq 'SYNC_ROOT_INVALID') 'drive root sync root blocked'
    $systemRoot = [string]$env:SystemRoot
    if (-not [string]::IsNullOrWhiteSpace($systemRoot)) {
        $systemResult = Invoke-N8nSmokeCase -State (New-N8nFakeState -HostRoot $script:localInbox) -CaseArguments @{ LocalSyncRoot = (Join-Path $systemRoot 'Sync') }
        Assert-N8nSmoke ([string]$systemResult.error -ceq 'SYNC_ROOT_INVALID') 'system-directory sync root blocked'
    }
    $badRemoteRoot = Invoke-N8nSmokeCase -State (New-N8nFakeState -HostRoot $script:localInbox) -CaseArguments @{ RemoteSyncRoot = '/home/deploy/Syn c' }
    Assert-N8nSmoke ([string]$badRemoteRoot.error -ceq 'REMOTE_SYNC_ROOT_INVALID') 'unsafe remote sync root blocked'
    $rootRemote = Invoke-N8nSmokeCase -State (New-N8nFakeState -HostRoot $script:localInbox) -CaseArguments @{ RemoteSyncRoot = '/' }
    Assert-N8nSmoke ([string]$rootRemote.error -ceq 'REMOTE_SYNC_ROOT_INVALID') 'container root sync root blocked'
    $unsafeDestination = Invoke-N8nSmokeCase -State (New-N8nFakeState -HostRoot $script:localInbox) -CaseArguments @{ MountDestination = '/data/in box' }
    Assert-N8nSmoke ([string]$unsafeDestination.error -ceq 'DESTINATION_INVALID') 'unsafe destination blocked'
    foreach ($unsafePath in @('/data/../etc', '/data/./x', '/data//x')) {
        Assert-N8nSmoke (-not (Test-N8nSafeContainerPath -Path $unsafePath)) ('unsafe path segment blocked: ' + $unsafePath)
    }
    $rootDestination = Invoke-N8nSmokeCase -State (New-N8nFakeState -HostRoot $script:localInbox) -CaseArguments @{ MountDestination = '/' }
    Assert-N8nSmoke ([string]$rootDestination.error -ceq 'DESTINATION_INVALID') 'container root destination blocked'
    $unsafeName = Invoke-N8nSmokeCase -State (New-N8nFakeState -HostRoot $script:localInbox) -CaseArguments @{ ContainerName = 'bad name; rm -rf /' }
    Assert-N8nSmoke ([string]$unsafeName.error -ceq 'CONTAINER_NAME_INVALID') 'unsafe container name blocked'

    # 6. container identity and state
    Assert-N8nSmoke ([string](Invoke-N8nSmokeCase -State (New-N8nFakeState -Document (New-N8nInspectSpec -Name 'other' -Mounts @($goodMount)) -HostRoot $script:localInbox)).error -ceq 'CONTAINER_IDENTITY_MISMATCH') 'container identity mismatch blocks'
    Assert-N8nSmoke ([string](Invoke-N8nSmokeCase -State (New-N8nFakeState -Document (New-N8nInspectSpec -Name 'N8N' -Mounts @($goodMount)) -HostRoot $script:localInbox)).error -ceq 'CONTAINER_IDENTITY_MISMATCH') 'container identity is case-sensitive'
    Assert-N8nSmoke ([string](Invoke-N8nSmokeCase -State (New-N8nFakeState -Document (New-N8nInspectSpec -Name '/n8n' -Mounts @($goodMount)) -HostRoot $script:localInbox)).error -ceq 'CONTAINER_IDENTITY_MISMATCH') 'container identity rejects a doubled leading slash'
    Assert-N8nSmoke ([string](Invoke-N8nSmokeCase -State (New-N8nFakeState -Document (New-N8nInspectSpec -Image 'redis:7' -Mounts @($goodMount)) -HostRoot $script:localInbox)).error -ceq 'CONTAINER_NOT_N8N') 'non-n8n image blocks'
    $digestImage = 'docker.io/n8nio/n8n@sha256:' + ('a' * 64)
    $officialImages = @('n8nio/n8n:latest', $digestImage, 'docker.n8n.io/n8nio/n8n:2.1.0')
    foreach ($officialImage in $officialImages) {
        $officialState = New-N8nFakeState -Document (New-N8nInspectSpec -Image $officialImage -Mounts @($goodMount)) -HostRoot $script:localInbox
        $official = Invoke-N8nSmokeCase -State $officialState
        Assert-N8nSmoke ([string]$official.status -ceq 'verified') ('official image form accepted: ' + $officialImage) ([string]$official.error)
    }
    $lookalikeImages = @('evil/n8nio/n8n:1', 'n8nio/n8n-backdoor:1', 'docker.n8n.io.evil/n8nio/n8n:1', 'myregistry.local/n8nio/n8n:1')
    foreach ($lookalike in $lookalikeImages) {
        $lookalikeResult = Invoke-N8nSmokeCase -State (New-N8nFakeState -Document (New-N8nInspectSpec -Image $lookalike -Mounts @($goodMount)) -HostRoot $script:localInbox)
        Assert-N8nSmoke ([string]$lookalikeResult.error -ceq 'CONTAINER_NOT_N8N') ('lookalike image rejected: ' + $lookalike) ([string]$lookalikeResult.error)
    }
    Assert-N8nSmoke (-not (Test-N8nDockerExecutableSafe -Executable 'docker.cmd')) 'a .cmd docker wrapper is unsafe'
    Assert-N8nSmoke (-not (Test-N8nDockerExecutableSafe -Executable 'C:\tools\docker.bat')) 'a .bat docker wrapper is unsafe'
    Assert-N8nSmoke (-not (Test-N8nDockerExecutableSafe -Executable 'docker.ps1')) 'a .ps1 docker wrapper is unsafe'
    Assert-N8nSmoke ((Test-N8nDockerExecutableSafe -Executable 'docker') -and (Test-N8nDockerExecutableSafe -Executable 'C:\tools\docker.exe')) 'docker on PATH and docker.exe stay allowed'
    $unsafeExeState = New-N8nFakeState -Document $goodDocument -HostRoot $script:localInbox
    $unsafeExe = Invoke-N8nSmokeCase -State $unsafeExeState -CaseArguments @{ DockerExecutable = 'docker.cmd' }
    Assert-N8nSmoke (([string]$unsafeExe.status -ceq 'failed') -and ([string]$unsafeExe.error -ceq 'DOCKER_EXECUTABLE_UNSAFE')) 'unsafe .cmd executable override blocks' ([string]$unsafeExe.error)
    Assert-N8nSmoke ($unsafeExeState.Calls.Count -eq 0) 'unsafe executable override issues no docker call'
    Assert-N8nSmoke ([string](Invoke-N8nSmokeCase -State (New-N8nFakeState -Document (New-N8nInspectSpec -Running $false -StatusText 'exited' -Mounts @($goodMount)) -HostRoot $script:localInbox)).error -ceq 'CONTAINER_NOT_RUNNING') 'stopped container blocks'
    Assert-N8nSmoke ([string](Invoke-N8nSmokeCase -State (New-N8nFakeState -Document (New-N8nInspectSpec -Restarting $true -Mounts @($goodMount)) -HostRoot $script:localInbox)).error -ceq 'CONTAINER_RESTARTING') 'restarting container blocks'
    Assert-N8nSmoke ([string](Invoke-N8nSmokeCase -State (New-N8nFakeState -Document (New-N8nInspectSpec -Paused $true -Mounts @($goodMount)) -HostRoot $script:localInbox)).error -ceq 'CONTAINER_PAUSED') 'paused container blocks'
    Assert-N8nSmoke ([string](Invoke-N8nSmokeCase -State (New-N8nFakeState -Document (New-N8nInspectSpec -Health 'starting' -Mounts @($goodMount)) -HostRoot $script:localInbox)).error -ceq 'CONTAINER_UNHEALTHY') 'starting health blocks'
    $noHealthDoc = New-N8nInspectSpec -Health '' -Mounts @($goodMount)
    $noHealth = Invoke-N8nSmokeCase -State (New-N8nFakeState -Document $noHealthDoc -HostRoot $script:localInbox)
    Assert-N8nSmoke (([string]$noHealth.status -ceq 'verified') -and (-not [bool]$noHealth.container.healthcheck)) 'no healthcheck passes on running with explicit detail'
    $strictHealth = Invoke-N8nSmokeCase -State (New-N8nFakeState -Document $noHealthDoc -HostRoot $script:localInbox) -CaseArguments @{ RequireHealthcheck = $true }
    Assert-N8nSmoke ([string]$strictHealth.error -ceq 'CONTAINER_HEALTHCHECK_MISSING') 'required healthcheck missing blocks'
    $twoRecords = New-N8nInspectLine -Document $goodDocument
    $twoState = New-N8nFakeState -HostRoot $script:localInbox
    $twoState.InspectOutput = ($twoRecords + "`n" + $twoRecords)
    Assert-N8nSmoke ([string](Invoke-N8nSmokeCase -State $twoState).error -ceq 'CONTAINER_AMBIGUOUS') 'two inspect records block as ambiguous'
    $malformedState = New-N8nFakeState -HostRoot $script:localInbox
    $malformedState.InspectOutput = 'not-the-projection'
    Assert-N8nSmoke ([string](Invoke-N8nSmokeCase -State $malformedState).error -ceq 'INSPECT_INVALID') 'malformed projection blocks'
    $genericInspectState = New-N8nFakeState -HostRoot $script:localInbox
    $genericInspectState.InspectExit = 1
    $genericInspectState.InspectStderr = 'some unexpected failure'
    Assert-N8nSmoke ([string](Invoke-N8nSmokeCase -State $genericInspectState).error -ceq 'INSPECT_FAILED') 'generic inspect failure blocks'
    $missingContainerState = New-N8nFakeState -HostRoot $script:localInbox
    $missingContainerState.InspectExit = 1
    $missingContainerState.InspectStderr = 'Error: No such object: n8n'
    Assert-N8nSmoke ([string](Invoke-N8nSmokeCase -State $missingContainerState).error -ceq 'CONTAINER_NOT_FOUND') 'missing container blocks as not found'

    # 7. container user
    $rootUserState = New-N8nFakeState -Document $goodDocument -HostRoot $script:localInbox
    $rootUserState.User = 'root'
    $rootUser = Invoke-N8nSmokeCase -State $rootUserState
    Assert-N8nSmoke ([string]$rootUser.error -ceq 'CONTAINER_USER_MISMATCH') 'container user other than node blocks'
    Assert-N8nSmoke (@($rootUserState.Calls | Where-Object { ([string]$_ -split ' ')[4] -ceq 'cat' }).Count -eq 0) 'user mismatch writes and reads no sentinel'
    Assert-N8nSmoke (-not (Test-N8nSentinelLeftovers -Directory $script:syncRoot)) 'user mismatch leaves no sentinel'
    $unknownUserState = New-N8nFakeState -Document $goodDocument -HostRoot $script:localInbox
    $unknownUserState.UserExit = 1
    Assert-N8nSmoke ([string](Invoke-N8nSmokeCase -State $unknownUserState).error -ceq 'CONTAINER_USER_UNKNOWN') 'unreadable container user blocks'
    foreach ($badUser in @(('x' * 33), 'node;echo')) {
        $badUserState = New-N8nFakeState -Document $goodDocument -HostRoot $script:localInbox
        $badUserState.User = $badUser
        $badUserResult = Invoke-N8nSmokeCase -State $badUserState
        Assert-N8nSmoke (([string]$badUserResult.error -ceq 'CONTAINER_USER_UNKNOWN') -and ([string]$badUserResult.probe.user -ceq 'UNKNOWN')) 'invalid/oversized user stdout is replaced with UNKNOWN'
    }

    # 8. mount resolution
    $noMatchState = New-N8nFakeState -Document (New-N8nInspectSpec -Mounts @((New-N8nMountSpec -Source '/home/deploy/other'))) -HostRoot $script:localInbox
    Assert-N8nSmoke ([string](Invoke-N8nSmokeCase -State $noMatchState).error -ceq 'MOUNT_NOT_FOUND') 'absent dedicated bind blocks'
    $ambiguousState = New-N8nFakeState -Document (New-N8nInspectSpec -Mounts @($goodMount, (New-N8nMountSpec -Source $script:RemoteInbox -Destination '/data/inbox2'))) -HostRoot $script:localInbox
    Assert-N8nSmoke ([string](Invoke-N8nSmokeCase -State $ambiguousState).error -ceq 'MOUNT_AMBIGUOUS') 'two binds from the same source block'
    $twoKindState = New-N8nFakeState -Document (New-N8nInspectSpec -Mounts @($goodMount, (New-N8nMountSpec -Source $script:RemoteRoot -Destination '/data/root'))) -HostRoot $script:localInbox
    Assert-N8nSmoke ([string](Invoke-N8nSmokeCase -State $twoKindState).error -ceq 'MOUNT_AMBIGUOUS') 'inbox bind plus sync-root bind block'
    $volumeState = New-N8nFakeState -Document (New-N8nInspectSpec -Mounts @((New-N8nMountSpec -Source $script:RemoteInbox -Type 'volume' -Mode ''))) -HostRoot $script:localInbox
    Assert-N8nSmoke ([string](Invoke-N8nSmokeCase -State $volumeState).error -ceq 'MOUNT_NOT_BIND') 'volume source blocks'
    $rwState = New-N8nFakeState -Document (New-N8nInspectSpec -Mounts @((New-N8nMountSpec -Source $script:RemoteInbox -ReadWrite $true -Mode 'rw'))) -HostRoot $script:localInbox
    Assert-N8nSmoke ([string](Invoke-N8nSmokeCase -State $rwState).error -ceq 'MOUNT_NOT_READONLY') 'writable bind blocked by RW flag'
    $modeRwState = New-N8nFakeState -Document (New-N8nInspectSpec -Mounts @((New-N8nMountSpec -Source $script:RemoteInbox -ReadWrite $false -Mode 'rw'))) -HostRoot $script:localInbox
    Assert-N8nSmoke ([string](Invoke-N8nSmokeCase -State $modeRwState).error -ceq 'MOUNT_NOT_READONLY') 'writable bind blocked by Mode'
    $labeledRoState = New-N8nFakeState -Document (New-N8nInspectSpec -Mounts @((New-N8nMountSpec -Source $script:RemoteInbox -ReadWrite $false -Mode 'ro,z'))) -HostRoot $script:localInbox
    $labeledRo = Invoke-N8nSmokeCase -State $labeledRoState
    Assert-N8nSmoke (([string]$labeledRo.status -ceq 'verified') -and ([bool]$labeledRo.mount.readonly)) 'read-only bind with an SELinux label token is accepted'
    $labelOnlyState = New-N8nFakeState -Document (New-N8nInspectSpec -Mounts @((New-N8nMountSpec -Source $script:RemoteInbox -ReadWrite $false -Mode 'z'))) -HostRoot $script:localInbox
    Assert-N8nSmoke ([string](Invoke-N8nSmokeCase -State $labelOnlyState).error -ceq 'MOUNT_NOT_READONLY') 'bind without an explicit ro token is blocked'
    $destMismatch = Invoke-N8nSmokeCase -State (New-N8nFakeState -Document $goodDocument -HostRoot $script:localInbox) -CaseArguments @{ MountDestination = '/data/other' }
    Assert-N8nSmoke ([string]$destMismatch.error -ceq 'MOUNT_DESTINATION_MISMATCH') 'configured destination mismatch blocks'
    $overlapState = New-N8nFakeState -Document (New-N8nInspectSpec -Mounts @($goodMount, (New-N8nMountSpec -Source $script:decoyInbox -Destination '/data/inbox/extra'))) -HostRoot $script:localInbox
    Assert-N8nSmoke ([string](Invoke-N8nSmokeCase -State $overlapState).error -ceq 'MOUNT_SHADOWED') 'overlapping mount destination blocks'
    $parentShadowState = New-N8nFakeState -Document (New-N8nInspectSpec -Mounts @($goodMount, (New-N8nMountSpec -Source $script:decoyInbox -Destination '/data'))) -HostRoot $script:localInbox
    Assert-N8nSmoke ([string](Invoke-N8nSmokeCase -State $parentShadowState).error -ceq 'MOUNT_SHADOWED') 'parent mount shadowing the destination blocks'

    # 9. probe visibility, bytes and cleanup
    $blindState = New-N8nFakeState -Document $goodDocument -HostRoot $script:decoyInbox
    $blind = Invoke-N8nSmokeCase -State $blindState
    Assert-N8nSmoke (([string]$blind.status -ceq 'failed') -and ([string]$blind.error -ceq 'PROBE_NOT_VISIBLE')) 'invisible sentinel blocks' ([string]$blind.error)
    Assert-N8nSmoke ([bool]$blind.cleanup.host_removed) 'sentinel removed after an invisible probe'
    Assert-N8nSmoke (-not (Test-N8nSentinelLeftovers -Directory $script:syncRoot)) 'no sentinel left after an invisible probe'
    $tamperedState = New-N8nFakeState -Document $goodDocument -HostRoot $script:localInbox
    $tamperedState.CatAs = 'tampered-content'
    $tampered = Invoke-N8nSmokeCase -State $tamperedState
    Assert-N8nSmoke ([string]$tampered.error -ceq 'PROBE_CONTENT_MISMATCH') 'content mismatch blocks'
    Assert-N8nSmoke (-not (Test-N8nSentinelLeftovers -Directory $script:syncRoot)) 'no sentinel left after a content mismatch'
    $staleState = New-N8nFakeState -Document $goodDocument -HostRoot $script:localInbox
    $staleState.StillVisible = $true
    $stale = Invoke-N8nSmokeCase -State $staleState
    Assert-N8nSmoke ([string]$stale.error -ceq 'CLEANUP_NOT_VERIFIED') 'sentinel still visible after cleanup blocks'
    Assert-N8nSmoke (-not (Test-N8nSentinelLeftovers -Directory $script:syncRoot)) 'host sentinel still removed when container verify fails'
    Assert-N8nSmoke (Test-Path -LiteralPath $script:keepFile -PathType Leaf) 'pre-existing inbox file still preserved after failures'
    Assert-N8nSmoke (Test-Path -LiteralPath $script:rootKeepFile -PathType Leaf) 'pre-existing sync root file still preserved after failures'

    # 9b. cleanup verification requires positive liveness in the same attempt.
    foreach ($cleanupCode in @(125, 126, 127, 2, -1)) {
        $transportState = New-N8nFakeState -Document $goodDocument -HostRoot $script:localInbox
        $transportState.CleanupTestExit = $cleanupCode
        $transportResult = Invoke-N8nSmokeCase -State $transportState
        $cleanupLabel = 'cleanup exit ' + [string]$cleanupCode
        Assert-N8nSmoke (([string]$transportResult.status -ceq 'failed') -and ([string]$transportResult.error -ceq 'CLEANUP_NOT_VERIFIED')) ($cleanupLabel + ' fails closed') ([string]$transportResult.error)
        Assert-N8nSmoke (-not [bool]$transportResult.cleanup.container_hidden) ($cleanupLabel + ' is never treated as hidden')
        Assert-N8nSmoke (([string]$transportResult.cleanup.error -ceq 'CLEANUP_TRANSPORT_FAILED') -and ([string]$transportResult.cleanup.docker_exit -ceq [string]$cleanupCode)) ($cleanupLabel + ' reports the bounded exit code') ([string]$transportResult.cleanup.error + ' ' + [string]$transportResult.cleanup.docker_exit)
        $transportJson = ConvertTo-Json -InputObject $transportResult -Compress -Depth 10
        Assert-N8nSmoke ($transportJson -notmatch 'CONTRACT_|stderr') ($cleanupLabel + ' serializes no raw stderr')
        Assert-N8nSmoke (-not (Test-N8nSentinelLeftovers -Directory $script:syncRoot)) ($cleanupLabel + ' leaves no host sentinel')
    }
    $notStartedState = New-N8nFakeState -Document $goodDocument -HostRoot $script:localInbox
    $notStartedState.CleanupTestExit = 1
    $notStartedState.CleanupTestStarted = $false
    $notStarted = Invoke-N8nSmokeCase -State $notStartedState
    Assert-N8nSmoke (([string]$notStarted.status -ceq 'failed') -and ([string]$notStarted.error -ceq 'CLEANUP_NOT_VERIFIED')) 'cleanup with a docker command that never started fails closed' ([string]$notStarted.error)
    Assert-N8nSmoke (-not [bool]$notStarted.cleanup.container_hidden) 'unstarted cleanup probe is never treated as hidden'
    Assert-N8nSmoke ([string]$notStarted.cleanup.docker_exit -ceq 'not_started') 'unstarted cleanup probe reports a generic diagnostic'
    $transportOneState = New-N8nFakeState -Document $goodDocument -HostRoot $script:localInbox
    $transportOneState.CleanupTestExit = 1
    $transportOneState.CleanupTestStderr = 'error during connect: connection refused'
    $transportOne = Invoke-N8nSmokeCase -State $transportOneState
    Assert-N8nSmoke ((-not [bool]$transportOne.cleanup.container_hidden) -and ([string]$transportOne.cleanup.error -ceq 'CLEANUP_TRANSPORT_FAILED')) 'exit 1 with transport stderr is not interpreted as hidden'
    $deadContainerState = New-N8nFakeState -Document $goodDocument -HostRoot $script:localInbox
    $deadContainerState.LivenessExit = 1
    $deadContainerState.LivenessStderr = 'container is not running'
    $deadContainer = Invoke-N8nSmokeCase -State $deadContainerState
    Assert-N8nSmoke (([string]$deadContainer.error -ceq 'CONTAINER_UNREACHABLE_DURING_CLEANUP') -and (-not [bool]$deadContainer.cleanup.container_hidden)) 'failed liveness produces explicit cleanup failure'
    Assert-N8nSmoke ($deadContainerState.TestCallCount -eq 1) 'failed liveness stops before missing-file probe'
    $visibleState = New-N8nFakeState -Document $goodDocument -HostRoot $script:localInbox
    $visibleState.CleanupTestExit = 0
    $visibleAfterCleanup = Invoke-N8nSmokeCase -State $visibleState
    Assert-N8nSmoke (([string]$visibleAfterCleanup.error -ceq 'CLEANUP_NOT_VERIFIED') -and ([string]$visibleAfterCleanup.cleanup.error -ceq 'CONTAINER_STILL_VISIBLE')) 'cleanup exit 0 remains visible and blocks' ([string]$visibleAfterCleanup.cleanup.error)

    # 9c. atomic marker creation and partial-write cleanup
    $atomicPath = Join-Path $script:localInbox 'atomic-sentinel-test.tmp'
    $atomicFirst = New-N8nSentinelFile -Path $atomicPath -Content 'first'
    Assert-N8nSmoke (([bool]$atomicFirst.created) -and ([string]$atomicFirst.error -ceq '') -and ([int]$atomicFirst.bytes -eq 5)) 'sentinel is created atomically'
    $atomicSecond = New-N8nSentinelFile -Path $atomicPath -Content 'second'
    Assert-N8nSmoke ((-not [bool]$atomicSecond.created) -and ([string]$atomicSecond.error -ceq 'PROBE_NAME_COLLISION')) 'CreateNew refuses to truncate an existing marker'
    Assert-N8nSmoke (([IO.File]::ReadAllText($atomicPath)) -ceq 'first') 'existing marker content is preserved on collision'
    Remove-Item -LiteralPath $atomicPath -Force -ErrorAction SilentlyContinue
    $badPath = Join-Path $script:localInbox 'atomic-write-failure.tmp'
    $badContent = 'a' + [char]0xD800
    $atomicBad = New-N8nSentinelFile -Path $badPath -Content $badContent
    Assert-N8nSmoke (([string]$atomicBad.error -ceq 'PROBE_WRITE_FAILED') -and (-not (Test-Path -LiteralPath $badPath))) 'a partial write is cleaned up and reported'

    # 9d. reparse-point inbox redirection (junction) is refused before docker
    Assert-N8nSmoke (-not (Test-N8nReparsePoint -Path $script:localInbox)) 'normal inbox is not a reparse point'
    $junctionRoot = Join-Path $script:root 'junction-sync'
    [void][IO.Directory]::CreateDirectory($junctionRoot)
    $junctionInbox = Join-Path $junctionRoot 'synkroo-forge-inbox'
    $junctionOutput = & cmd.exe /c mklink /J $junctionInbox $script:localInbox 2>&1
    if ($LASTEXITCODE -eq 0) {
        Assert-N8nSmoke (Test-N8nReparsePoint -Path $junctionInbox) 'junction inbox is detected as a reparse point'
        $junctionState = New-N8nFakeState -Document $goodDocument -HostRoot $script:localInbox
        $junctionResult = Invoke-N8nSmokeCase -State $junctionState -CaseArguments @{ LocalSyncRoot = $junctionRoot }
        Assert-N8nSmoke (([string]$junctionResult.status -ceq 'failed') -and ([string]$junctionResult.error -ceq 'INBOX_REPARSE_POINT')) 'junction inbox redirection is refused' ([string]$junctionResult.error)
        Assert-N8nSmoke ($junctionState.Calls.Count -eq 0) 'junction inbox refusal issues no docker call'
        try { & cmd.exe /c rmdir $junctionInbox 2>&1 | Out-Null } catch { }
        if (Test-Path -LiteralPath $junctionInbox) {
            try { [IO.Directory]::Delete($junctionInbox, $false) } catch { }
        }
    }
    else {
        Write-Host ('[INFO] junction creation unavailable; reparse-point integration check limited to the detector: ' + ($junctionOutput -join ' '))
    }

    # 9e. bounded runtime budget
    Assert-N8nSmoke (([int]$script:N8nSmokeRuntimeBudgetSeconds -lt 240) -and ([int]$script:N8nSmokeRuntimeBudgetSeconds -ge 120)) 'default runtime budget is below the allowlisted 240s'
    $shortBudget = New-N8nRuntimeBudget -Seconds 120
    $shortBudget.deadline_utc = [DateTime]::UtcNow.AddSeconds(5)
    $shortTimeout = Get-N8nBoundedDockerTimeout -Budget $shortBudget -ReserveSeconds 0
    Assert-N8nSmoke (($shortTimeout -ge 3) -and ($shortTimeout -le 5)) 'bounded timeout uses the remaining budget' ([string]$shortTimeout)
    Assert-N8nSmoke ((Get-N8nBoundedDockerTimeout -Budget $shortBudget -ReserveSeconds 10) -eq 0) 'cleanup reserve yields no negative timeout'
    $longBudget = New-N8nRuntimeBudget -Seconds 120
    Assert-N8nSmoke ((Get-N8nBoundedDockerTimeout -Budget $longBudget -ReserveSeconds 45) -eq 30) 'bounded timeout caps at the per-call limit'
    $delayBudget = New-N8nRuntimeBudget -Seconds 120
    $delayBudget.deadline_utc = [DateTime]::UtcNow.AddSeconds(2)
    Assert-N8nSmoke ((Get-N8nBoundedDelayMilliseconds -Budget $delayBudget -DelayMilliseconds 10000) -le 2000) 'retry delay is clamped to the remaining budget'
    $tinyStart = [DateTime]::UtcNow
    $tinyBudgetState = New-N8nFakeState -Document $goodDocument -HostRoot $script:localInbox
    $tinyBudgetResult = Invoke-N8nSmokeCase -State $tinyBudgetState -CaseArguments @{ RuntimeBudgetSeconds = 10 }
    $tinyElapsed = ([DateTime]::UtcNow - $tinyStart).TotalSeconds
    Assert-N8nSmoke (([string]$tinyBudgetResult.status -ceq 'failed') -and ([string]$tinyBudgetResult.error -ceq 'RUNTIME_BUDGET_EXHAUSTED')) 'exhausted budget fails closed' ([string]$tinyBudgetResult.error)
    Assert-N8nSmoke (($tinyElapsed -lt 10) -and ($tinyBudgetState.Calls.Count -eq 0)) 'exhausted budget returns quickly without a docker call' ([string]$tinyElapsed)

    # 10. argument quoting for the docker CLI
    Assert-N8nSmoke ((ConvertTo-N8nArgumentToken -Value 'inspect') -ceq 'inspect') 'plain argument stays unquoted'
    Assert-N8nSmoke ((ConvertTo-N8nArgumentToken -Value 'a b') -ceq '"a b"') 'argument with a space is quoted'
    $formatToken = ConvertTo-N8nArgumentToken -Value $script:N8nSmokeInspectFormat
    Assert-N8nSmoke (($formatToken.StartsWith('"')) -and ($formatToken.EndsWith('"'))) 'inspect template is passed as one quoted argument'
    Assert-N8nSmoke ((ConvertTo-N8nArgumentToken -Value '') -ceq '""') 'empty argument is preserved'
    $quoteToken = ConvertTo-N8nArgumentToken -Value ('a' + [char]34 + 'b')
    Assert-N8nSmoke ($quoteToken -ceq ('"a' + [char]92 + [char]34 + 'b"')) 'embedded quote is escaped for CreateProcess' $quoteToken

    # 11. policy profile
    $policy = $null
    try { $policy = (Get-Content -LiteralPath $script:PolicyPath -Raw -Encoding UTF8) | ConvertFrom-Json } catch { $policy = $null }
    Assert-N8nSmoke ($null -ne $policy) 'verification policy parses'
    $profileNode = $null
    if (($null -ne $policy) -and ($null -ne $policy.profiles)) { $profileNode = $policy.profiles.'n8n-syncthing-mount' }
    Assert-N8nSmoke ($null -ne $profileNode) 'policy carries n8n-syncthing-mount profile'
    if ($null -ne $profileNode) {
        Assert-N8nSmoke ([string]$profileNode.class -ceq 'diagnostic') 'profile class is diagnostic' ([string]$profileNode.class)
        Assert-N8nSmoke ([string]$profileNode.command -ceq 'powershell -NoProfile -File scripts/v3/n8n-syncthing-mount-smoke.ps1') 'profile command is the fixed allowlisted string' ([string]$profileNode.command)
        Assert-N8nSmoke (([int]$profileNode.timeout_seconds -ge 120) -and ([int]$profileNode.timeout_seconds -le 600)) 'profile timeout covers bounded ssh and sync polling' ([string]$profileNode.timeout_seconds)
        $profileKeys = @($profileNode.PSObject.Properties.Name | Sort-Object)
        Assert-N8nSmoke ((($profileKeys -join ',') -ceq 'class,command,timeout_seconds')) 'profile carries no extra permission surface' ($profileKeys -join ',')
        $targetScript = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'scripts\v3\n8n-syncthing-mount-smoke.ps1'
        Assert-N8nSmoke (Test-Path -LiteralPath $targetScript -PathType Leaf) 'profile command target exists'
        $runtimePolicy = $null
        try { $runtimePolicy = Get-OrchestrationVerificationPolicy -PolicyPath $script:PolicyPath } catch { $runtimePolicy = $null }
        Assert-N8nSmoke (($null -ne $runtimePolicy) -and [bool]$runtimePolicy.ok -and $runtimePolicy.policy.profiles.Contains('n8n-syncthing-mount')) 'kernel verifier accepts the policy and profile'
        if (($null -ne $runtimePolicy) -and [bool]$runtimePolicy.ok) {
            $allowExact = Test-OrchestrationCommandAllowlisted -Command 'powershell -NoProfile -File scripts/v3/n8n-syncthing-mount-smoke.ps1' -Policy $runtimePolicy.policy
            $allowExtra = Test-OrchestrationCommandAllowlisted -Command 'powershell -NoProfile -File scripts/v3/n8n-syncthing-mount-smoke.ps1 -MountDestination /data/inbox' -Policy $runtimePolicy.policy
            Assert-N8nSmoke ([bool]$allowExact) 'allowlist accepts the exact profile command'
            Assert-N8nSmoke (-not [bool]$allowExtra) 'allowlist rejects the profile command with extra arguments'
        }
    }

    # 11b. compressed JSON stays inside the policy output budget
    if ($null -ne $policy) {
        $maxOutputChars = [int]$policy.max_output_chars
        Assert-N8nSmoke ($maxOutputChars -eq 4000) 'policy max_output_chars is the expected 4000' ([string]$maxOutputChars)
        $goodJson = ConvertTo-Json -InputObject $good -Compress -Depth 10
        Assert-N8nSmoke (($goodJson -split "`n").Count -eq 1) 'verdict JSON is compressed to one line'
        Assert-N8nSmoke ($goodJson.Length -le $maxOutputChars) 'happy-path verdict fits the policy output budget' ([string]$goodJson.Length)
        $worst = ($good | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
        $worst.container.name = ('n' * 128)
        $worst.container.image = 'docker.n8n.io/n8nio/n8n:' + ('1' * 64)
        $worst.source.local_sync_root = 'C:\' + ('s' * 160)
        $worst.source.local_inbox = [string]$worst.source.local_sync_root + '\synkroo-forge-inbox'
        $worst.source.remote_sync_root = '/' + ('r' * 160)
        $worst.source.remote_inbox = [string]$worst.source.remote_sync_root + '/synkroo-forge-inbox'
        $worst.probe.file = [string]$worst.source.local_inbox + '\.orchestration-mount-smoke-' + ('a' * 32) + '.tmp'
        $worst.probe.container_path = '/data/inbox/.orchestration-mount-smoke-' + ('a' * 32) + '.tmp'
    $worstJson = ConvertTo-Json -InputObject $worst -Compress -Depth 10
    Assert-N8nSmoke ($worstJson.Length -le $maxOutputChars) 'worst-case successful verdict fits max_output_chars=4000' ([string]$worstJson.Length)
    $failureChecks = @()
    for ($i = 0; $i -lt 40; $i++) {
        $failureChecks += (New-N8nCheckRecord -Id ('failure_' + $i) -Status 'fail' -Detail ('d' * 500))
    }
    $boundedFailure = New-N8nSmokeResult -Status 'failed' -ErrorCode 'SENTINEL_CONTENT_MISMATCH' -Checks $failureChecks -Detail ('x' * 5000)
    $boundedFailureJson = ConvertTo-Json -InputObject $boundedFailure -Compress -Depth 10
    Assert-N8nSmoke (($boundedFailureJson.Length -le $maxOutputChars) -and ([string]$boundedFailure.status -ceq 'failed') -and ([string]$boundedFailure.error -ceq 'SENTINEL_CONTENT_MISMATCH')) 'worst-case failure fits budget without truncating decision fields' ([string]$boundedFailureJson.Length)
    Assert-N8nSmoke (([string]$boundedFailure.checks[-1].id -ceq 'checks_truncated') -and ([string]$boundedFailure.detail).Length -le 160) 'optional failure diagnostics are capped with a truncation marker'
    }

    # 12. static contract
    $smokeText = [IO.File]::ReadAllText($script:SmokePath)
    Assert-N8nSmoke ($smokeText -notmatch '(?i)docker\s+(compose|restart|stop|rm|kill|cp|run|start|create|pull|push|build|login)\b') 'script issues no container mutation command'
    Assert-N8nSmoke ($smokeText -notmatch '\.Config\.Env') 'script never requests container environment fields'
    Assert-N8nSmoke (($smokeText.Contains("'--context'")) -and ($smokeText.Contains("'contabo-prod'"))) 'context transport is explicit and defaults to contabo-prod'
    Assert-N8nSmoke ($smokeText.Contains('DOCKER_HOST_REFUSED')) 'script documents and enforces the DOCKER_HOST refusal'
    Assert-N8nSmoke (($smokeText.Contains('DOCKER_CONFIG')) -and ($smokeText.Contains('DOCKER_CERT_PATH')) -and ($smokeText.Contains('DOCKER_TLS_VERIFY'))) 'script refuses docker config/cert/tls overrides'
    Assert-N8nSmoke ($smokeText.Contains('ORCHESTRATION_N8N_ALLOW_INBOX_WRITE')) 'script documents the production write opt-in'
    Assert-N8nSmoke (($smokeText.Contains('[IO.FileMode]::CreateNew')) -and (-not $smokeText.Contains('[IO.File]::WriteAllText($probePath'))) 'sentinel creation is exclusive and not WriteAllText'
    Assert-N8nSmoke ($smokeText.Contains('CLEANUP_TRANSPORT_FAILED')) 'cleanup treats transport/client results as failures'
    Assert-N8nSmoke ($smokeText.Contains('ConvertTo-Json -InputObject $final -Compress')) 'CLI verdict JSON is compressed'
    Assert-N8nSmoke (($smokeText.Contains("'context'")) -and ($smokeText.Contains('Endpoints.docker.Host'))) 'script validates the context endpoint with the fixed inspect form'
    Assert-N8nSmoke (($smokeText.Contains('n8nio/n8n')) -and ($smokeText.Contains('docker.n8n.io/n8nio/n8n'))) 'script pins the official n8n image repository forms'
    Assert-N8nSmoke ($smokeText.Contains('ReparsePoint')) 'script refuses reparse-point inbox redirection'
    Assert-N8nSmoke ($smokeText -notmatch 'Add-Check[^\r\n]*stderr') 'script never serializes docker stderr in a check'
    Assert-N8nSmoke (($smokeText.Contains("'inspect'")) -and ($smokeText.Contains("'test'")) -and ($smokeText.Contains("'cat'")) -and ($smokeText.Contains("'id'"))) 'verifier uses only the fixed inspect and exec forms'
    $nonAscii = @([IO.File]::ReadAllBytes($script:SmokePath) | Where-Object { $_ -gt 127 }).Count
    Assert-N8nSmoke ($nonAscii -eq 0) 'smoke script is ASCII-only' ([string]$nonAscii)

    # 13. CLI process
    $cliNoConfig = Invoke-N8nSmokeCli @()
    Assert-N8nSmoke (($cliNoConfig.ExitCode -eq 2) -and ($null -ne $cliNoConfig.Json) -and ([string]$cliNoConfig.Json.status -ceq 'not_configured')) 'CLI without configuration exits 2 with JSON verdict' ($cliNoConfig.Stdout + ' ' + $cliNoConfig.Stderr)
    Assert-N8nSmoke (($cliNoConfig.Stdout -split "`n").Count -eq 1) 'CLI emits compressed single-line JSON'
    $missingDocker = Join-Path $script:root 'no-such-docker.exe'
    $cliNoDocker = Invoke-N8nSmokeCli @('-MountDestination', '/data/inbox', '-LocalSyncRoot', $script:syncRoot, '-DockerExecutable', $missingDocker, '-AllowProductionInboxWrite')
    Assert-N8nSmoke (($cliNoDocker.ExitCode -eq 2) -and ($null -ne $cliNoDocker.Json) -and ([string]$cliNoDocker.Json.status -ceq 'unavailable')) 'CLI with a missing docker binary exits 2 as unavailable' ($cliNoDocker.Stdout + ' ' + $cliNoDocker.Stderr)
    $env:DOCKER_HOST = 'ssh://deploy@example.invalid'
    $cliHost = Invoke-N8nSmokeCli @('-MountDestination', '/data/inbox', '-LocalSyncRoot', $script:syncRoot, '-AllowProductionInboxWrite')
    $env:DOCKER_HOST = ''
    Assert-N8nSmoke (($cliHost.ExitCode -eq 2) -and ([string]$cliHost.Json.error -ceq 'DOCKER_HOST_REFUSED')) 'CLI refuses DOCKER_HOST before touching docker' ($cliHost.Stdout + ' ' + $cliHost.Stderr)
    Assert-N8nSmoke ($cliHost.Stdout -notmatch 'deploy@example\.invalid') 'CLI never prints the refused DOCKER_HOST value'
    Assert-N8nSmoke (-not (Test-N8nSentinelLeftovers -Directory $script:syncRoot)) 'CLI runs leave no sentinel behind'
}
finally {
    $env:DOCKER_HOST = ''
    $env:DOCKER_CONTEXT = ''
    $env:DOCKER_CONFIG = ''
    $env:DOCKER_CERT_PATH = ''
    $env:DOCKER_TLS_VERIFY = ''
    $env:DOCKER_TLS = ''
    $env:ORCHESTRATION_N8N_ALLOW_INBOX_WRITE = ''
    if (Test-Path -LiteralPath $script:root) { Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host ('N8N-MOUNT-SMOKE: ' + $script:Passed + ' passed / ' + $script:Failed + ' failed')
if ($script:Failed -gt 0) { exit 1 }
exit 0
