<#!
.SYNOPSIS
    V3 Deterministic verifier (Phase 12): independent re-verification of work.
.DESCRIPTION
    Dot-sourceable library (no execution on load). Verifies worker output
    INDEPENDENTLY of worker claims by re-running allowlisted validation
    commands and by classifying the working tree against task write scopes.

    Closed allowlist: only the fixed commands listed in
    source/registry/verification-policy.json may ever execute. No parameter
    injection from task JSON is possible: profile lookup is by exact name
    and the executed string comes from the policy file, never from the task.

    Integration seam (this lib never writes task state): the caller
    (task-kernel CLI / tests) pipes the Invoke-OrchestrationVerifier result
    into Set-OrchestrationTaskVerification from OrchestrationTaskKernel.ps1:

        $v = Invoke-OrchestrationVerifier -TaskId $id -RepoRoot $root `
            -BaseRevision $base -WriteScopes $scopes -ProfileNames $names
        Set-OrchestrationTaskVerification -TaskId $id `
            -VerifierEvidenceJson ($v | ConvertTo-Json -Depth 16) `
            -ExpectedRevision $rev ...

    Empty/'none' BaseRevision never yields a machine verdict: the scope
    check returns manual_verification_required/base_revision_required, so
    a verified_pass outcome always has a real base. Git parsing is
    NUL-separated (status --porcelain -z, diff --name-only -z) so paths
    with spaces survive and rename counterparts ('new\0old') are both
    counted.

    Verdict model: status is 'verified_pass', 'verification_failed' or
    'manual_verification_required'. ok is $true when the verifier reached a
    machine verdict (pass or failed); ok is $false when a human must step in
    (unknown profile, policy/git problems) or on internal errors.

    PowerShell 5.1 compatible. ASCII-only. Expected domain errors are
    returned as result objects, never thrown.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$verifierSanitizePath = Join-Path $PSScriptRoot 'CapabilitySanitize.ps1'
if (Test-Path -LiteralPath $verifierSanitizePath -PathType Leaf) {
    . $verifierSanitizePath
}

# RR-P22-JOB-OBJECTS: containment de ARVORE no timeout. Sem esta lib o unico
# primitivo disponivel seria matar so o root (cmd.exe), o que ORFA o filho real e
# deixa handles abertos (log travado) - comportamento PIOR que o antigo /T, nao
# apenas diferente. Carrega uma vez se ausente; falha de carga e neutra (o
# fallback honesto por handle continua valendo). Nao pode lancar no load.
try {
    if (-not (Get-Command -Name 'New-RuntimeJobObject' -ErrorAction SilentlyContinue)) {
        $verifierJobLib = ''
        try { $verifierJobLib = (Join-Path $PSScriptRoot '..\..\runtime\lib\RuntimeJobObject.ps1') } catch { $verifierJobLib = '' }
        if ((-not [string]::IsNullOrWhiteSpace($verifierJobLib)) -and (Test-Path -LiteralPath $verifierJobLib -PathType Leaf)) {
            . $verifierJobLib
        }
    }
}
catch { }

# ---------- path helpers ----------

function Get-VerifierRepoRoot {
    [CmdletBinding()]
    param([string]$RepoRoot)
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { return $RepoRoot }
    return (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
}

function Get-VerifierDefaultPolicyPath {
    [CmdletBinding()]
    param([string]$RepoRoot)
    $root = Get-VerifierRepoRoot -RepoRoot $RepoRoot
    return (Join-Path $root 'source\registry\verification-policy.json')
}

function New-VerifierError {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Code, $Extra)
    $r = [ordered]@{ ok = $false; error = $Code }
    if ($null -ne $Extra) {
        if ($Extra -is [System.Collections.IDictionary]) {
            foreach ($k in @($Extra.Keys)) { $r[[string]$k] = $Extra[$k] }
        }
        else {
            foreach ($p in @($Extra.PSObject.Properties)) { $r[$p.Name] = $p.Value }
        }
    }
    return ([PSCustomObject]$r)
}

function Test-VerifierTimeoutValue {
    [CmdletBinding()]
    param($Value)
    try {
        if (($Value -is [int]) -or ($Value -is [long])) {
            $n = [int]$Value
            return (($n -ge 1) -and ($n -le 1800))
        }
        return $false
    }
    catch { return $false }
}

function Get-VerifierPolicyNode {
    <#
    .SYNOPSIS
        Unwraps a wrapper ({ok,policy}) or an inner policy object.
    #>
    [CmdletBinding()]
    param($Policy)
    if ($null -eq $Policy) { return $null }
    if ($Policy -is [System.Collections.IDictionary]) {
        if ($Policy.Contains('profiles')) { return $Policy }
        if ($Policy.Contains('policy')) { return $Policy['policy'] }
        return $null
    }
    $pp = $Policy.PSObject.Properties | Where-Object { $_.Name -ceq 'profiles' } | Select-Object -First 1
    if ($null -ne $pp) { return $Policy }
    $wp = $Policy.PSObject.Properties | Where-Object { $_.Name -ceq 'policy' } | Select-Object -First 1
    if ($null -ne $wp) { return $wp.Value }
    return $null
}

# ---------- policy ----------

function Get-OrchestrationVerificationPolicy {
    <#
    .SYNOPSIS
        Parses and schema-validates the verification policy.
        Returns {ok, policy} or {ok:$false, error}.
    #>
    [CmdletBinding()]
    param([string]$PolicyPath = '', [string]$RepoRoot = '')
    try {
        $p = $PolicyPath
        if ([string]::IsNullOrWhiteSpace($p)) { $p = Get-VerifierDefaultPolicyPath -RepoRoot $RepoRoot }
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
            return (New-VerifierError -Code 'POLICY_NOT_FOUND' -Extra @{ status = 'manual_verification_required' })
        }
        $doc = $null
        try { $doc = ([IO.File]::ReadAllText($p, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json) }
        catch { return (New-VerifierError -Code 'POLICY_INVALID_JSON' -Extra @{ status = 'manual_verification_required' }) }
        if ($null -eq $doc) {
            return (New-VerifierError -Code 'POLICY_INVALID_JSON' -Extra @{ status = 'manual_verification_required' })
        }
        $node = $null
        if ($doc -is [System.Collections.IDictionary]) { $node = $doc }
        else {
            $node = @{}
            foreach ($prop in @($doc.PSObject.Properties)) { $node[$prop.Name] = $prop.Value }
        }
        try { if ([int]$node['version'] -ne 1) { throw 'bad' } }
        catch { return (New-VerifierError -Code 'POLICY_SCHEMA_INVALID' -Extra @{ status = 'manual_verification_required'; detail = 'version-must-be-1' }) }
        if (-not (Test-VerifierTimeoutValue -Value $node['default_timeout_seconds'])) {
            return (New-VerifierError -Code 'POLICY_SCHEMA_INVALID' -Extra @{ status = 'manual_verification_required'; detail = 'default_timeout_seconds-range' })
        }
        $maxChars = 0
        try {
            if (($node['max_output_chars'] -is [int]) -or ($node['max_output_chars'] -is [long])) {
                $maxChars = [int]$node['max_output_chars']
            }
        }
        catch { $maxChars = 0 }
        if (($maxChars -lt 1) -or ($maxChars -gt 1000000)) {
            return (New-VerifierError -Code 'POLICY_SCHEMA_INVALID' -Extra @{ status = 'manual_verification_required'; detail = 'max_output_chars-range' })
        }
        $rawProfiles = $node['profiles']
        if ($null -eq $rawProfiles) {
            return (New-VerifierError -Code 'POLICY_SCHEMA_INVALID' -Extra @{ status = 'manual_verification_required'; detail = 'profiles-missing' })
        }
        $entries = @()
        if ($rawProfiles -is [System.Collections.IDictionary]) {
            foreach ($k in @($rawProfiles.Keys)) {
                $entries += [PSCustomObject]@{ Name = [string]$k; Value = $rawProfiles[$k] }
            }
        }
        else {
            foreach ($prop in @($rawProfiles.PSObject.Properties)) {
                $entries += [PSCustomObject]@{ Name = [string]$prop.Name; Value = $prop.Value }
            }
        }
        if ($entries.Count -lt 1) {
            return (New-VerifierError -Code 'POLICY_SCHEMA_INVALID' -Extra @{ status = 'manual_verification_required'; detail = 'profiles-empty' })
        }
        $allowedClasses = @('test', 'lint', 'typecheck', 'build', 'diagnostic')
        $profiles = @{}
        foreach ($e in $entries) {
            $name = ([string]$e.Name).Trim()
            if ([string]::IsNullOrWhiteSpace($name)) {
                return (New-VerifierError -Code 'POLICY_SCHEMA_INVALID' -Extra @{ status = 'manual_verification_required'; detail = 'profile-blank-name' })
            }
            $pv = $e.Value
            $pmap = @{}
            if ($pv -is [System.Collections.IDictionary]) {
                foreach ($k in @($pv.Keys)) { $pmap[[string]$k] = $pv[$k] }
            }
            else {
                foreach ($prop in @($pv.PSObject.Properties)) { $pmap[$prop.Name] = $prop.Value }
            }
            $class = [string]$pmap['class']
            if ($allowedClasses -cnotcontains $class) {
                return (New-VerifierError -Code 'POLICY_SCHEMA_INVALID' -Extra @{ status = 'manual_verification_required'; detail = ('profile-class:' + $name) })
            }
            $cmd = [string]$pmap['command']
            if ([string]::IsNullOrWhiteSpace($cmd)) {
                return (New-VerifierError -Code 'POLICY_SCHEMA_INVALID' -Extra @{ status = 'manual_verification_required'; detail = ('profile-command:' + $name) })
            }
            if (-not (Test-VerifierTimeoutValue -Value $pmap['timeout_seconds'])) {
                return (New-VerifierError -Code 'POLICY_SCHEMA_INVALID' -Extra @{ status = 'manual_verification_required'; detail = ('profile-timeout:' + $name) })
            }
            $profiles[$name] = [PSCustomObject]@{
                class           = $class
                command         = $cmd.Trim()
                timeout_seconds = [int]$pmap['timeout_seconds']
            }
        }
        $policy = [PSCustomObject]@{
            version                = 1
            default_timeout_seconds = [int]$node['default_timeout_seconds']
            max_output_chars       = $maxChars
            profiles               = $profiles
        }
        return [PSCustomObject]@{ ok = $true; policy = $policy; error = '' }
    }
    catch { return (New-VerifierError -Code 'INTERNAL_ERROR' -Extra @{ status = 'manual_verification_required' }) }
}

function Test-OrchestrationCommandAllowlisted {
    <#
    .SYNOPSIS
        True only on exact (trimmed, case-sensitive) match against a profile
        command in the policy. Extra args never match.
    #>
    [CmdletBinding()]
    param([string]$Command, $Policy)
    try {
        $node = Get-VerifierPolicyNode -Policy $Policy
        if ($null -eq $node) { return $false }
        $c = ([string]$Command).Trim()
        if ([string]::IsNullOrWhiteSpace($c)) { return $false }
        $map = $null
        if ($node -is [System.Collections.IDictionary]) { $map = $node['profiles'] }
        else {
            $pp = $node.PSObject.Properties | Where-Object { $_.Name -ceq 'profiles' } | Select-Object -First 1
            if ($null -ne $pp) { $map = $pp.Value }
        }
        if ($null -eq $map) { return $false }
        if ($map -is [System.Collections.IDictionary]) {
            foreach ($k in @($map.Keys)) {
                $entry = $map[$k]
                $pc = ''
                if ($entry -is [System.Collections.IDictionary]) { $pc = [string]$entry['command'] }
                else {
                    $cp = $entry.PSObject.Properties | Where-Object { $_.Name -ceq 'command' } | Select-Object -First 1
                    if ($null -ne $cp) { $pc = [string]$cp.Value }
                }
                if ($c -ceq $pc.Trim()) { return $true }
            }
            return $false
        }
        foreach ($prop in @($map.PSObject.Properties)) {
            $entry = $prop.Value
            $pc = ''
            if ($entry -is [System.Collections.IDictionary]) { $pc = [string]$entry['command'] }
            else {
                $cp = $entry.PSObject.Properties | Where-Object { $_.Name -ceq 'command' } | Select-Object -First 1
                if ($null -ne $cp) { $pc = [string]$cp.Value }
            }
            if ($c -ceq $pc.Trim()) { return $true }
        }
        return $false
    }
    catch { return $false }
}

# ---------- output handling ----------

function Invoke-VerifierRedactText {
    <#
    .SYNOPSIS
        Inline secret-value redaction reusing CapabilitySanitize patterns.
        Only matched substrings become [REDACTED]; surrounding text survives.
    #>
    [CmdletBinding()]
    param([string]$Text)
    try {
        if ((Get-Command Get-SecretValuePattern -ErrorAction SilentlyContinue) -eq $null) { return [string]$Text }
        $pattern = Get-SecretValuePattern
        if ([string]::IsNullOrWhiteSpace($pattern)) { return [string]$Text }
        return ([regex]::Replace([string]$Text, $pattern, '[REDACTED]'))
    }
    catch { return [string]$Text }
}

function Limit-VerifierOutput {
    [CmdletBinding()]
    param([string]$Text, [int]$MaxChars)
    try {
        $t = [string]$Text
        if ($t.Length -le $MaxChars) { return $t }
        return ($t.Substring(0, $MaxChars) + "`n[TRUNCATED: output exceeded " + $MaxChars + " chars]")
    }
    catch { return [string]$Text }
}

# ---------- profile execution ----------

function Invoke-OrchestrationValidationProfile {
    <#
    .SYNOPSIS
        Runs ONLY the fixed allowlisted command for a profile name.
        Unknown names return manual_verification_required and run nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProfileName,
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [string]$PolicyPath = '',
        [int]$TimeoutSeconds = 0
    )
    $name = ([string]$ProfileName).Trim()
    try {
        $pol = Get-OrchestrationVerificationPolicy -PolicyPath $PolicyPath -RepoRoot $RepoRoot
        if (-not [bool]$pol.ok) {
            return [PSCustomObject]@{
                ok = $false; profile = $name; status = 'manual_verification_required'
                exit_code = -1; command_class = ''; command = ''
                output_capped = ''; duration_ms = 0; error = [string]$pol.error
            }
        }
        $policy = $pol.policy
        if (-not $policy.profiles.Contains($name)) {
            return [PSCustomObject]@{
                ok = $false; profile = $name; status = 'manual_verification_required'
                exit_code = -1; command_class = ''; command = ''
                output_capped = ''; duration_ms = 0; error = 'UNKNOWN_PROFILE'
            }
        }
        $entry = $policy.profiles[$name]
        $command = ([string]$entry.command).Trim()
        if ([string]::IsNullOrWhiteSpace($command)) {
            return [PSCustomObject]@{
                ok = $false; profile = $name; status = 'manual_verification_required'
                exit_code = -1; command_class = [string]$entry.class; command = ''
                output_capped = ''; duration_ms = 0; error = 'EMPTY_COMMAND'
            }
        }
        $timeout = [int]$entry.timeout_seconds
        if (($TimeoutSeconds -ge 1) -and ($TimeoutSeconds -le 1800)) { $timeout = $TimeoutSeconds }
        elseif (([int]$policy.default_timeout_seconds -ge 1) -and ([int]$policy.default_timeout_seconds -le 1800)) {
            if (($timeout -lt 1) -or ($timeout -gt 1800)) { $timeout = [int]$policy.default_timeout_seconds }
        }
        $root = Get-VerifierRepoRoot -RepoRoot $RepoRoot
        $logDir = Join-Path ([IO.Path]::GetTempPath()) ('v3-verifier-' + [guid]::NewGuid().ToString('N'))
        $logFile = Join-Path $logDir 'output.log'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $timedOut = $false
        $code = -1
        $raw = ''
        try {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            # cmd /c with file redirect: avoids pipe deadlock on verbose suites.
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'cmd.exe'
            $psi.Arguments = '/c ' + $command + ' > "' + $logFile + '" 2>&1'
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $false
            $psi.RedirectStandardError = $false
            $psi.CreateNoWindow = $true
            $psi.WorkingDirectory = $root
            try { $psi.EnvironmentVariables['PSModulePath'] = "$env:windir\System32\WindowsPowerShell\v1.0\Modules" } catch { }
            # RR-P22-JOB-OBJECTS: o job e criado ANTES do start e o filho (cmd /c)
            # e atribuido logo apos o spawn pelo handle do spawn PROPRIO. No
            # timeout, a arvore morre por KILL_ON_JOB_CLOSE (descendentes por
            # heranca, mais forte que arvore-por-PID). Cleanup NUNCA por arvore de PID
            # historico. Sem a lib carregada ou sem atribuicao provada, o fallback
            # e $p.Kill() no handle do proprio spawn (root-only: descendentes
            # podem escapar, sem claim de tree kill).
            $vJob = $null
            $vJobAssigned = $false
            $vJobNote = ''
            $p = $null
            try {
                # ANONIMO por chamada (sem -Name => CreateJobObjectW com nome
                # nulo): um nome fixo FARIA CreateJobObjectW ABRIR um job
                # preexistente de mesmo nome, e TerminateJobObject de uma
                # chamada mataria os filhos de outra. isolamento por handle.
                try {
                    if (Get-Command -Name 'New-RuntimeJobObject' -ErrorAction SilentlyContinue) {
                        $vJob = New-RuntimeJobObject
                        if ([bool]$vJob.Ok) { $vJobNote = 'job anonimo criado antes do start' }
                        else { $vJobNote = ('job nao criado: ' + [string]$vJob.Reason) }
                    }
                    else { $vJobNote = 'lib RuntimeJobObject.ps1 nao carregada: fallback root-only' }
                }
                catch { $vJobNote = 'falha ao criar o job: ' + [string]$_.Exception.Message; $vJob = $null }
                $p = [System.Diagnostics.Process]::Start($psi)
                if ($null -ne $vJob -and [bool]$vJob.Ok) {
                    try {
                        $vAdd = Add-RuntimeJobProcess -Job $vJob -Process $p
                        if ([bool]$vAdd.Ok) { $vJobAssigned = $true; $vJobNote = $vJobNote + ' | filho atribuido ao job' }
                        else { $vJobNote = $vJobNote + ' | atribuicao falhou: ' + [string]$vAdd.Reason }
                    }
                    catch { $vJobNote = $vJobNote + ' | atribuicao lancou: ' + [string]$_.Exception.Message }
                }
                $finished = $p.WaitForExit($timeout * 1000)
                if (-not $finished) {
                    $timedOut = $true
                    if ($vJobAssigned) {
                        try { [void](Stop-RuntimeJobObject -Job $vJob -TimeoutMs 15000) } catch { }
                    }
                    else {
                        try { $p.Kill() } catch { }
                    }
                    try { $p.WaitForExit(10000) } catch { }
                }
                else {
                    $code = $p.ExitCode
                }
            }
            finally {
                # OWNERSHIP: TODO caminho de saida fecha o job e libera o handle
                # do processo, inclusive excecao (start/wait/exitcode). Sem
                # isto o job vazava e um KILL_ON_JOB_CLOSE orfao continuava vivo
                # depois do veredito. Idempotente nos dois primitivos.
                try { [void](Close-RuntimeJobObject -Job $vJob) } catch { }
                if ($null -ne $p) {
                    try { $p.Close() } catch { }
                    try { $p.Dispose() } catch { }
                }
            }
            try {
                if (Test-Path -LiteralPath $logFile -PathType Leaf) {
                    $raw = [IO.File]::ReadAllText($logFile, [Text.Encoding]::UTF8)
                }
            }
            catch { $raw = '' }
        }
        catch {
            $sw.Stop()
            try { if (Test-Path -LiteralPath $logDir) { Remove-Item -LiteralPath $logDir -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
            return [PSCustomObject]@{
                ok = $false; profile = $name; status = 'manual_verification_required'
                exit_code = -1; command_class = [string]$entry.class; command = $command
                output_capped = ''; duration_ms = [long]$sw.ElapsedMilliseconds; error = 'LAUNCH_FAILED'
            }
        }
        $sw.Stop()
        try { if (Test-Path -LiteralPath $logDir) { Remove-Item -LiteralPath $logDir -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
        $status = 'failed'
        if ($timedOut) { $status = 'timeout'; $code = -1 }
        elseif ($code -eq 0) { $status = 'verified' }
        $redacted = Invoke-VerifierRedactText -Text $raw
        $capped = Limit-VerifierOutput -Text $redacted -MaxChars ([int]$policy.max_output_chars)
        return [PSCustomObject]@{
            ok = ($status -ceq 'verified'); profile = $name; status = $status
            exit_code = [int]$code; command_class = [string]$entry.class; command = $command
            output_capped = [string]$capped; duration_ms = [long]$sw.ElapsedMilliseconds; error = ''
        }
    }
    catch {
        return [PSCustomObject]@{
            ok = $false; profile = $name; status = 'manual_verification_required'
            exit_code = -1; command_class = ''; command = ''
            output_capped = ''; duration_ms = 0; error = 'INTERNAL_ERROR'
        }
    }
}

# ---------- git scope check ----------

function Invoke-VerifierGit {
    <#
    .SYNOPSIS
        Runs one git command, merged stdout, never throws.
        Returns @{started, exit_code, stdout}.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$GitExecutable,
        [Parameter(Mandatory = $true)][string]$Arguments
    )
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $GitExecutable
        $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.WorkingDirectory = $RepoRoot
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $p.StandardError.ReadToEnd() | Out-Null
        $p.WaitForExit(60000)
        $code = $p.ExitCode
        try { $p.Close() } catch { }
        return @{ started = $true; exit_code = [int]$code; stdout = [string]$out }
    }
    catch { return @{ started = $false; exit_code = -1; stdout = '' } }
}

function Get-VerifierNormalizedPath {
    [CmdletBinding()]
    param([string]$Path)
    $t = (([string]$Path).Trim() -replace '\\', '/')
    while ($t.StartsWith('./')) { $t = $t.Substring(2) }
    $t = $t.TrimEnd('/')
    return $t
}

function Test-VerifierScopeMatch {
    <#
    .SYNOPSIS
        Scope match: file equals scope OR starts with scope (directory
        prefix); / vs \ normalized; ordinal-ignore-case.
    #>
    [CmdletBinding()]
    param([string]$File, [string[]]$Scopes)
    try {
        $f = Get-VerifierNormalizedPath -Path $File
        if ([string]::IsNullOrWhiteSpace($f)) { return $false }
        foreach ($s in @($Scopes)) {
            $n = Get-VerifierNormalizedPath -Path ([string]$s)
            if ([string]::IsNullOrWhiteSpace($n)) { continue }
            if ($f -ceq $n) { return $true }
            if ($f.StartsWith($n, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        return $false
    }
    catch { return $false }
}

function Test-OrchestrationWriteScope {
    <#
    .SYNOPSIS
        Classifies working-tree changes against write scopes via git.
        Never throws; git problems return manual_verification_required.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [string]$BaseRevision = '',
        [string[]]$WriteScopes = @(),
        [string]$GitExecutable = 'git'
    )
    try {
        $root = ([string]$RepoRoot).Trim()
        $git = ([string]$GitExecutable).Trim()
        if ([string]::IsNullOrWhiteSpace($git)) { $git = 'git' }
        $gitFail = [PSCustomObject]@{
            ok = $false; error = ''; status = 'manual_verification_required'
            in_scope = ([string[]]@()); out_of_scope = ([string[]]@()); dirty_untracked = ([string[]]@())
        }
        if ([string]::IsNullOrWhiteSpace($root) -or (-not (Test-Path -LiteralPath $root -PathType Container))) {
            $gitFail.error = 'INVALID_REPO_ROOT'
            return $gitFail
        }
        $probe = Invoke-VerifierGit -RepoRoot $root -GitExecutable $git -Arguments '--version'
        if ((-not [bool]$probe.started) -or ([int]$probe.exit_code -ne 0)) {
            $gitFail.error = 'GIT_UNAVAILABLE'
            return $gitFail
        }
        $repoProbe = Invoke-VerifierGit -RepoRoot $root -GitExecutable $git -Arguments 'rev-parse --git-dir'
        if ((-not [bool]$repoProbe.started) -or ([int]$repoProbe.exit_code -ne 0)) {
            $gitFail.error = 'NOT_A_GIT_REPO'
            return $gitFail
        }
        $ref = ([string]$BaseRevision).Trim()
        if ([string]::IsNullOrWhiteSpace($ref) -or ($ref -ieq 'none')) {
            $gitFail.error = 'BASE_REVISION_REQUIRED'
            return $gitFail
        }
        $changed = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $verify = Invoke-VerifierGit -RepoRoot $root -GitExecutable $git -Arguments ('rev-parse --verify --quiet "' + $ref + '" --')
        if ((-not [bool]$verify.started) -or ([int]$verify.exit_code -ne 0)) {
            $gitFail.error = 'INVALID_REVISION'
            return $gitFail
        }
        $diff = Invoke-VerifierGit -RepoRoot $root -GitExecutable $git -Arguments ('diff --name-status -z "' + $ref + '" --')
        if ((-not [bool]$diff.started) -or ([int]$diff.exit_code -ne 0)) {
            $gitFail.error = 'GIT_COMMAND_FAILED'
            return $gitFail
        }
        $tokens = @(([string]$diff.stdout -split "`0"))
        $di = 0
        while ($di -lt $tokens.Count) {
            $rawTok = [string]$tokens[$di]
            $tok = $rawTok.Trim("`n", "`r")
            if ([string]::IsNullOrWhiteSpace($tok)) { $di++; continue }
            $statusOnly = $false
            $statusLetter = ''
            if ($tok -cmatch '^[ACDMRTUXB][0-9]*$') {
                $statusOnly = $true
                $statusLetter = $tok.Substring(0, 1).ToUpperInvariant()
            }
            $inlineStatus = ''
            $inlinePath = ''
            if (-not $statusOnly) {
                $tabIdx = $tok.IndexOf("`t")
                if ($tabIdx -ge 0) {
                    $maybeStatus = $tok.Substring(0, $tabIdx).Trim()
                    $maybePath = $tok.Substring($tabIdx + 1).Trim()
                    if ($maybeStatus -cmatch '^[ACDMRTUXB][0-9]*$') {
                        $inlineStatus = $maybeStatus.Substring(0, 1).ToUpperInvariant()
                        $inlinePath = $maybePath
                    }
                }
                else {
                    $spIdx = $tok.IndexOf(' ')
                    if ($spIdx -gt 0) {
                        $maybeStatus = $tok.Substring(0, $spIdx).Trim()
                        $maybePath = $tok.Substring($spIdx + 1).Trim()
                        if (($maybeStatus -cmatch '^[ACDMRTUXB][0-9]*$') -and (-not [string]::IsNullOrWhiteSpace($maybePath))) {
                            $inlineStatus = $maybeStatus.Substring(0, 1).ToUpperInvariant()
                            $inlinePath = $maybePath
                        }
                    }
                }
            }
            if ($statusOnly) {
                if (($statusLetter -ceq 'R') -or ($statusLetter -ceq 'C')) {
                    $pNew = ''
                    $pOld = ''
                    if (($di + 1) -lt $tokens.Count) { $pNew = ([string]$tokens[$di + 1]).Trim("`n", "`r", ' ', '"') }
                    if (($di + 2) -lt $tokens.Count) { $pOld = ([string]$tokens[$di + 2]).Trim("`n", "`r", ' ', '"') }
                    foreach ($pp in @($pNew, $pOld)) {
                        if (-not [string]::IsNullOrWhiteSpace($pp)) {
                            $changed.Add((Get-VerifierNormalizedPath -Path $pp)) | Out-Null
                        }
                    }
                    $di += 3
                    continue
                }
                else {
                    $pp = ''
                    if (($di + 1) -lt $tokens.Count) { $pp = ([string]$tokens[$di + 1]).Trim("`n", "`r", ' ', '"') }
                    if (-not [string]::IsNullOrWhiteSpace($pp)) {
                        $changed.Add((Get-VerifierNormalizedPath -Path $pp)) | Out-Null
                    }
                    $di += 2
                    continue
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($inlineStatus)) {
                if (($inlineStatus -ceq 'R') -or ($inlineStatus -ceq 'C')) {
                    foreach ($pp in @($inlinePath)) {
                        $t = $pp.Trim().Trim('"')
                        if (-not [string]::IsNullOrWhiteSpace($t)) {
                            $changed.Add((Get-VerifierNormalizedPath -Path $t)) | Out-Null
                        }
                    }
                    $pOld = ''
                    if (($di + 1) -lt $tokens.Count) { $pOld = ([string]$tokens[$di + 1]).Trim("`n", "`r", ' ', '"') }
                    if (-not [string]::IsNullOrWhiteSpace($pOld)) {
                        $changed.Add((Get-VerifierNormalizedPath -Path $pOld)) | Out-Null
                    }
                    $di += 2
                    continue
                }
                else {
                    $t = $inlinePath.Trim().Trim('"')
                    if (-not [string]::IsNullOrWhiteSpace($t)) {
                        $changed.Add((Get-VerifierNormalizedPath -Path $t)) | Out-Null
                    }
                    $di++
                    continue
                }
            }
            $t = $tok.Trim().Trim('"')
            if (-not [string]::IsNullOrWhiteSpace($t)) {
                $changed.Add((Get-VerifierNormalizedPath -Path $t)) | Out-Null
            }
            $di++
        }
        $untracked = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $st = Invoke-VerifierGit -RepoRoot $root -GitExecutable $git -Arguments 'status --porcelain -z --untracked-files=all --'
        if ((-not [bool]$st.started) -or ([int]$st.exit_code -ne 0)) {
            $gitFail.error = 'GIT_COMMAND_FAILED'
            return $gitFail
        }
        foreach ($tok in @(([string]$st.stdout -split "`0"))) {
            $tokTrim = $tok.Trim("`n", "`r")
            if ([string]::IsNullOrWhiteSpace($tokTrim)) { continue }
            $rest = ''
            $xy = ''
            if (($tokTrim.Length -ge 4) -and ($tokTrim[2] -ceq ' ')) {
                $xy = $tokTrim.Substring(0, 2)
                $rest = $tokTrim.Substring(3).Trim()
            }
            else {
                # Rename counterpart (old path follows 'new\0old' with no
                # status prefix): count it as a changed path too.
                $rest = $tokTrim.Trim()
            }
            if ([string]::IsNullOrWhiteSpace($rest)) { continue }
            if ($rest -match '^(.*) -> (.*)$') { $rest = $Matches[2].Trim() }
            $rest = $rest.Trim('"')
            if ([string]::IsNullOrWhiteSpace($rest)) { continue }
            $norm = Get-VerifierNormalizedPath -Path $rest
            $changed.Add($norm) | Out-Null
            if ($xy -ceq '??') { $untracked.Add($norm) | Out-Null }
        }
        $inScope = New-Object System.Collections.ArrayList
        $outScope = New-Object System.Collections.ArrayList
        foreach ($f in @($changed | Sort-Object)) {
            if (Test-VerifierScopeMatch -File $f -Scopes $WriteScopes) { [void]$inScope.Add($f) }
            else { [void]$outScope.Add($f) }
        }
        return [PSCustomObject]@{
            ok = $true; error = ''; status = 'scope_checked'
            in_scope = ([string[]]$inScope.ToArray())
            out_of_scope = ([string[]]$outScope.ToArray())
            dirty_untracked = ([string[]]@($untracked | Sort-Object))
        }
    }
    catch {
        return [PSCustomObject]@{
            ok = $false; error = 'INTERNAL_ERROR'; status = 'manual_verification_required'
            in_scope = ([string[]]@()); out_of_scope = ([string[]]@()); dirty_untracked = ([string[]]@())
        }
    }
}

# ---------- orchestrator ----------

function Get-VerifierScopeSummary {
    [CmdletBinding()]
    param($ScopeResult)
    try {
        $inCount = 0
        $outCount = 0
        if ($null -ne $ScopeResult) {
            if ($ScopeResult -is [System.Collections.IDictionary]) {
                if ($null -ne $ScopeResult['in_scope']) { $inCount = @($ScopeResult['in_scope']).Count }
                if ($null -ne $ScopeResult['out_of_scope']) { $outCount = @($ScopeResult['out_of_scope']).Count }
            }
            else {
                $pi = $ScopeResult.PSObject.Properties | Where-Object { $_.Name -ceq 'in_scope' } | Select-Object -First 1
                if ($null -ne $pi) { $inCount = @($pi.Value).Count }
                $po = $ScopeResult.PSObject.Properties | Where-Object { $_.Name -ceq 'out_of_scope' } | Select-Object -First 1
                if ($null -ne $po) { $outCount = @($po.Value).Count }
            }
        }
        return ([string]$inCount + ' in scope, ' + [string]$outCount + ' out')
    }
    catch { return '0 in scope, 0 out' }
}

function Get-VerifierCriterionProfiles {
    [CmdletBinding()]
    param($CriterionProfiles, [int]$Index, [string[]]$DefaultProfiles)
    try {
        if ($null -eq $CriterionProfiles) { return ([string[]]@($DefaultProfiles)) }
        $found = $false
        $raw = $null
        if ($CriterionProfiles -is [System.Collections.IDictionary]) {
            foreach ($k in @($CriterionProfiles.Keys)) {
                try {
                    $ki = -1
                    $isInt = [int]::TryParse([string]$k, [ref]$ki)
                    if ($isInt -and ([int]$ki -eq [int]$Index)) { $found = $true; $raw = $CriterionProfiles[$k]; break }
                }
                catch { }
                if (([string]$k -ceq [string]$Index)) { $found = $true; $raw = $CriterionProfiles[$k]; break }
            }
            if (-not $found) { return ([string[]]@($DefaultProfiles)) }
        }
        else {
            $prop = $CriterionProfiles.PSObject.Properties | Where-Object { ([string]$_.Name -ceq [string]$Index) } | Select-Object -First 1
            if ($null -eq $prop) { return ([string[]]@($DefaultProfiles)) }
            $found = $true
            $raw = $prop.Value
        }
        $list = New-Object System.Collections.ArrayList
        foreach ($e in @($raw)) {
            $t = ([string]$e).Trim()
            if (-not [string]::IsNullOrWhiteSpace($t)) { [void]$list.Add($t) }
        }
        return ([string[]]$list.ToArray())
    }
    catch { return ([string[]]@($DefaultProfiles)) }
}

function Get-VerifierCriterionVerdict {
    [CmdletBinding()]
    param([string[]]$MappedProfiles, $ProfileResults)
    try {
        $mapped = @($MappedProfiles)
        if ($mapped.Count -lt 1) { return 'unverified' }
        foreach ($mp in $mapped) {
            $hit = $null
            foreach ($r in @($ProfileResults)) {
                try {
                    $pn = ''
                    $ps = ''
                    if ($r -is [System.Collections.IDictionary]) {
                        if ($null -ne $r['profile']) { $pn = [string]$r['profile'] }
                        if ($null -ne $r['status']) { $ps = [string]$r['status'] }
                    }
                    else {
                        if ($null -ne $r.profile) { $pn = [string]$r.profile }
                        if ($null -ne $r.status) { $ps = [string]$r.status }
                    }
                    if ($pn -ceq $mp) { $hit = $ps; break }
                }
                catch { }
            }
            if ($hit -cne 'verified') { return 'unverified' }
        }
        return 'verified'
    }
    catch { return 'unverified' }
}

function Invoke-OrchestrationVerifier {
    <#
    .SYNOPSIS
        Fail-closed orchestrator: scope check first, then allowlisted
        profiles in order. Never executes anything outside the policy.
        Optional -AcceptanceCriteria (string[]) + -CriterionProfiles
        (hashtable idx -> string[] profiles; default ALL) emit one extra
        evidence string per criterion (criterion:<idx>:verified|unverified)
        plus criterion_map in the result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [string]$BaseRevision = '',
        [string[]]$WriteScopes = @(),
        [Parameter(Mandatory = $true)][string[]]$ProfileNames,
        [string]$PolicyPath = '',
        [string]$GitExecutable = 'git',
        [string[]]$AcceptanceCriteria = @(),
        $CriterionProfiles = $null
    )
    $tid = ([string]$TaskId).Trim()
    try {
        $names = @()
        foreach ($n in @($ProfileNames)) {
            $t = ([string]$n).Trim()
            if (-not [string]::IsNullOrWhiteSpace($t)) { $names += $t }
        }
        $scope = Test-OrchestrationWriteScope -RepoRoot $RepoRoot -BaseRevision $BaseRevision -WriteScopes $WriteScopes -GitExecutable $GitExecutable
        $summary = Get-VerifierScopeSummary -ScopeResult $scope
        if (-not [bool]$scope.ok) {
            return [PSCustomObject]@{
                ok = $false; task_id = $tid; status = 'manual_verification_required'
                reason = ([string]$scope.error).ToLowerInvariant()
                scope = $scope; profiles = @(); criterion_map = @{}
                evidence = ([string[]]@($summary)); command_classes = ([string[]]@())
            }
        }
        if (@($scope.out_of_scope).Count -gt 0) {
            return [PSCustomObject]@{
                ok = $true; task_id = $tid; status = 'verification_failed'
                reason = 'out_of_scope_write'
                scope = $scope; profiles = @(); criterion_map = @{}
                evidence = ([string[]]@($summary)); command_classes = ([string[]]@())
            }
        }
        if ($names.Count -lt 1) {
            return [PSCustomObject]@{
                ok = $false; task_id = $tid; status = 'manual_verification_required'
                reason = 'no_profiles'
                scope = $scope; profiles = @(); criterion_map = @{}
                evidence = ([string[]]@($summary)); command_classes = ([string[]]@())
            }
        }
        # Fail-closed BEFORE execution: validate every name first so an
        # unknown profile blocks the whole run (known ones never start).
        $pol = Get-OrchestrationVerificationPolicy -PolicyPath $PolicyPath -RepoRoot $RepoRoot
        if (-not [bool]$pol.ok) {
            return [PSCustomObject]@{
                ok = $false; task_id = $tid; status = 'manual_verification_required'
                reason = ([string]$pol.error).ToLowerInvariant()
                scope = $scope; profiles = @(); criterion_map = @{}
                evidence = ([string[]]@($summary)); command_classes = ([string[]]@())
            }
        }
        foreach ($n in $names) {
            if (-not $pol.policy.profiles.Contains($n)) {
                return [PSCustomObject]@{
                    ok = $false; task_id = $tid; status = 'manual_verification_required'
                    reason = 'unknown_profile'
                    scope = $scope; profiles = @(); criterion_map = @{}
                    evidence = ([string[]]@($summary)); command_classes = ([string[]]@())
                }
            }
        }
        $results = New-Object System.Collections.ArrayList
        $evidence = New-Object System.Collections.ArrayList
        $classes = New-Object System.Collections.ArrayList
        $failedName = ''
        foreach ($n in $names) {
            $r = Invoke-OrchestrationValidationProfile -ProfileName $n -RepoRoot $RepoRoot -PolicyPath $PolicyPath
            [void]$results.Add($r)
            [void]$evidence.Add(([string]$r.profile + ':' + [string]$r.status + ':' + [string]$r.exit_code))
            if (($null -ne $r.command_class) -and (-not [string]::IsNullOrWhiteSpace([string]$r.command_class)) -and ($classes -cnotcontains [string]$r.command_class)) {
                [void]$classes.Add([string]$r.command_class)
            }
            if ([string]$r.status -cne 'verified') { $failedName = [string]$r.profile; break }
        }
        [void]$evidence.Add($summary)
        $criteria = @()
        if ($null -ne $AcceptanceCriteria) { $criteria = @($AcceptanceCriteria) }
        $criterionMap = @{}
        foreach ($ci in 0..($criteria.Count - 1)) {
            if ($ci -lt 0 -or $ci -ge $criteria.Count) { continue }
            $mapped = Get-VerifierCriterionProfiles -CriterionProfiles $CriterionProfiles -Index ([int]$ci) -DefaultProfiles ([string[]]$names)
            $cstat = Get-VerifierCriterionVerdict -MappedProfiles ([string[]]$mapped) -ProfileResults ([object[]]$results.ToArray())
            $criterionMap[[string]$ci] = [PSCustomObject]@{ profiles = ([string[]]$mapped); status = [string]$cstat }
        }
        if ($criteria.Count -gt 0) {
            $orderedKeys = @($criterionMap.Keys | Sort-Object { [int]$_ })
            $tmpEv = New-Object System.Collections.ArrayList
            foreach ($e in @($evidence.ToArray())) { [void]$tmpEv.Add([string]$e) }
            $evidence.Clear()
            $profEv = New-Object System.Collections.ArrayList
            foreach ($e in @($tmpEv.ToArray())) {
                if ([string]$e -match '^\d+ in scope, \d+ out$') { continue }
                [void]$profEv.Add([string]$e)
            }
            foreach ($e in @($profEv.ToArray())) { [void]$evidence.Add([string]$e) }
            foreach ($k in $orderedKeys) {
                [void]$evidence.Add(('criterion:' + [string]$k + ':' + [string]$criterionMap[$k].status))
            }
            [void]$evidence.Add($summary)
        }
        if (-not [string]::IsNullOrWhiteSpace($failedName)) {
            return [PSCustomObject]@{
                ok = $true; task_id = $tid; status = 'verification_failed'
                reason = ('profile_' + [string]$results[$results.Count - 1].status + ':' + $failedName)
                scope = $scope; profiles = ([object[]]$results.ToArray()); criterion_map = $criterionMap
                evidence = ([string[]]$evidence.ToArray()); command_classes = ([string[]]$classes.ToArray())
            }
        }
        return [PSCustomObject]@{
            ok = $true; task_id = $tid; status = 'verified_pass'
            reason = ''
            scope = $scope; profiles = ([object[]]$results.ToArray()); criterion_map = $criterionMap
            evidence = ([string[]]$evidence.ToArray()); command_classes = ([string[]]$classes.ToArray())
        }
    }
    catch {
        return [PSCustomObject]@{
            ok = $false; task_id = $tid; status = 'manual_verification_required'
            reason = 'internal_error'
            scope = $null; profiles = @(); criterion_map = @{}
            evidence = ([string[]]@()); command_classes = ([string[]]@())
        }
    }
}
