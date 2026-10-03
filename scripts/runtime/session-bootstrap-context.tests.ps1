<#
    session-bootstrap-context.tests.ps1 -- RR-P31-S2-STARTUP-WIRING (V3.1).
    Suite for scripts/runtime/SessionBootstrapContext.ps1 (Phase 31 slice 2):
    session-start wiring over the slice 1 builder lib. Proves: startup never
    blocks (fail-open envelope + exit 0), exit 1 is invalid parameter usage
    only, output bounded and deterministic under an injected clock, parse-only
    (no spawn/network in the new lib, single dot-source of the builder),
    compliance telemetry matrix (one sanitized metadata line per run, 1 MB
    pre-size accounted cap fail-closed, lock-busy skip, zero writes without an
    explicit dir) and canary non-leakage in stdout and telemetry.
    PS 5.1 and PS7 compatible. ASCII only. No network. No secret. Temp dirs
    always carry a GUID suffix (cross-process races are real). No install, no
    registration, no activation, no commit.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$scriptPath = Join-Path $repoRoot 'scripts\runtime\SessionBootstrapContext.ps1'
$psExe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) { $psExe = 'powershell' }
$canary = 'sk-SYNTHETICSECRET'
$hostileName = ('evil.com ' + $canary + ' token=bad')

$script:passed = 0
$script:failed = 0

function Assert-That([bool]$Condition, [string]$Name, [string]$Detail) {
    if ($Condition) { $script:passed++; Write-Host ("[PASS] " + $Name) }
    else { $script:failed++; Write-Host ("[FAIL] " + $Name + " -- " + $Detail) }
}

function New-GuidDir([string]$Prefix) {
    $d = Join-Path ([IO.Path]::GetTempPath()) ($Prefix + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}

function Put-Text([string]$Path, [string]$Text) {
    $d = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($d)) {
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Invoke-BootstrapCli([string]$ScriptFile, [string]$Arguments, [hashtable]$EnvVars, [int]$TimeoutMs) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:psExe
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $ScriptFile + '" ' + $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $script:repoRoot
    try { $psi.StandardOutputEncoding = [Text.Encoding]::UTF8 } catch { }
    try { $psi.StandardErrorEncoding = [Text.Encoding]::UTF8 } catch { }
    try { $psi.EnvironmentVariables['PSModulePath'] = (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\Modules') } catch { }
    if ($null -ne $EnvVars) {
        foreach ($k in $EnvVars.Keys) { try { $psi.EnvironmentVariables[[string]$k] = [string]$EnvVars[$k] } catch { } }
    }
    $p = [System.Diagnostics.Process]::Start($psi)
    $so = $null
    $se = $null
    try { $so = $p.StandardOutput.ReadToEndAsync() } catch { $so = $null }
    try { $se = $p.StandardError.ReadToEndAsync() } catch { $se = $null }
    $finished = $false
    try { $finished = $p.WaitForExit($TimeoutMs) } catch { $finished = $false }
    if (-not $finished) {
        try { $p.Kill() } catch { }
        try { $p.WaitForExit(10000) } catch { }
    }
    $o = ''
    $e = ''
    try { if (($null -ne $so) -and $so.Wait(10000)) { $o = [string]$so.Result } } catch { $o = '' }
    try { if (($null -ne $se) -and $se.Wait(10000)) { $e = [string]$se.Result } } catch { $e = '' }
    $code = -1
    try { if ($finished) { $code = [int]$p.ExitCode } } catch { $code = -1 }
    try { $p.Close() } catch { }
    return [pscustomobject]@{ Code = $code; Out = $o; Err = $e; Finished = $finished }
}

function Get-OnlyJsonLine([string]$Text) {
    $lines = @()
    foreach ($l in ($Text -split "`r?`n")) { if (-not [string]::IsNullOrWhiteSpace($l)) { $lines += $l } }
    if ($lines.Count -ne 1) { return $null }
    try { return ConvertFrom-Json $lines[0] } catch { return $null }
}

function Get-ByteCount([string]$Text) {
    try { return [long][Text.Encoding]::UTF8.GetByteCount($Text) } catch { return [long]-1 }
}

function New-FixtureRepo([string]$Parent, [string]$Name, [string]$TaskId) {
    $root = Join-Path $Parent $Name
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Put-Text (Join-Path $root 'source/registry/capability-flags.json') '{"jev_advisory":{"enabled":false},"task_kernel":{"enabled":false}}'
    Put-Text (Join-Path $root 'source/registry/jev-advisory-policy.json') '{}'
    Put-Text (Join-Path $root 'source/registry/ai-memory-remote-policy.json') '{}'
    Put-Text (Join-Path $root 'cache/runtime/tasks/fix-1.json') ('{"task_id":"' + $TaskId + '","state":"IMPLEMENTING","active_wait":{"type":"human"}}')
    return $root
}

$base = New-GuidDir 'rr-p31s2-'
try {
    $fixedStamp = '2026-01-01T00:00:00.0000000Z'
    $quotedRepo = '"' + $repoRoot + '"'

    # ---- AC2 / AC7: real repo integration, valid JSON, exit 0 ----
    $real = Invoke-BootstrapCli $scriptPath ('-RepoRoot ' + $quotedRepo + ' -Timestamp ' + $fixedStamp) $null 120000
    $doc = Get-OnlyJsonLine $real.Out
    Assert-That ($real.Finished -and $real.Code -eq 0 -and ($null -ne $doc)) 'w1a: real repo run emits one valid JSON object with exit 0' ('code=' + $real.Code + ' raw=' + $real.Out)
    if ($null -ne $doc) {
        $names = @($doc.PSObject.Properties | ForEach-Object { $_.Name })
        $missing = @()
        foreach ($s in @('project_id', 'runtime', 'capability_health', 'tasks', 'pending_waits', 'jev_status', 'aimemory_status')) {
            if ($names -notcontains $s) { $missing += $s }
        }
        Assert-That ($missing.Count -eq 0) 'w1b: every builder section is present in the emitted JSON' ('missing=' + ($missing -join ','))
        Assert-That ($doc.project_id -eq 'opencode-orchestration' -and (Get-ByteCount $real.Out) -le 8192) 'w1c: project_id resolved and output bounded by default budget' ('project_id=' + $doc.project_id)
        # Contract fidelity: all_off must mirror the flags file under the builder
        # rule (top-level `enabled`, else `active`). capability_registry.enabled
        # is a registry marker (not a rollout flag), so the repo value is false.
        $flagsPath = Join-Path $repoRoot 'source/registry/capability-flags.json'
        $expectedAllOff = $true
        try {
            $flagsDoc = ConvertFrom-Json ([IO.File]::ReadAllText($flagsPath))
            foreach ($p in $flagsDoc.PSObject.Properties) {
                $on = $false
                try { $e1 = $p.Value.PSObject.Properties['enabled']; if ($null -ne $e1) { $on = [bool]$e1.Value } } catch { }
                if (-not $on) { try { $e2 = $p.Value.PSObject.Properties['active']; if ($null -ne $e2) { $on = [bool]$e2.Value } } catch { } }
                if ($on) { $expectedAllOff = $false }
            }
        }
        catch { $expectedAllOff = $null }
        Assert-That (($null -ne $expectedAllOff) -and ([bool]$doc.capability_health.all_off -eq $expectedAllOff)) 'w1d: capability_health.all_off mirrors capability-flags.json (builder rule)' ('expected=' + $expectedAllOff + ' got=' + [string]$doc.capability_health.all_off)
        # Conservative-rollout invariant: no capability is activated. Only the
        # registry markers may read true.
        $trueFlags = @()
        foreach ($p in $doc.capability_health.flags.PSObject.Properties) {
            if ([bool]$p.Value) { $trueFlags += $p.Name }
        }
        $illegal = @($trueFlags | Where-Object { $_ -notin @('capability_registry', 'runtime_support') })
        Assert-That ($illegal.Count -eq 0) 'w1e: no capability rollout flag is enabled in the real repo' ('enabled=' + ($trueFlags -join ','))
        Assert-That ([string]$doc.jev_status.transport -eq 'synthetic-hold' -and [string]$doc.aimemory_status.transport -eq 'unconfigured') 'w1f: jev and ai-memory sections present with honest transports' ('jev=' + [string]$doc.jev_status.transport + ' aimem=' + [string]$doc.aimemory_status.transport)
    }

    # ---- AC3: determinism with injected clock, and boundedness ----
    $detA = Invoke-BootstrapCli $scriptPath ('-RepoRoot ' + $quotedRepo + ' -Timestamp ' + $fixedStamp) $null 120000
    $detB = Invoke-BootstrapCli $scriptPath ('-RepoRoot ' + $quotedRepo + ' -Timestamp ' + $fixedStamp) $null 120000
    Assert-That ($detA.Out -ceq $detB.Out -and $detA.Code -eq 0 -and $detB.Code -eq 0) 'w2: two runs with the same -Timestamp are byte-identical (Ordinal)' 'outputs differ'
    $tight = Invoke-BootstrapCli $scriptPath ('-RepoRoot ' + $quotedRepo + ' -Timestamp ' + $fixedStamp + ' -ByteBudget 600') $null 120000
    $tightDoc = Get-OnlyJsonLine $tight.Out
    Assert-That ($tight.Code -eq 0 -and ($null -ne $tightDoc) -and (Get-ByteCount $tight.Out) -le 600) 'w3: -ByteBudget bounds the TOTAL stdout (payload + LF)' ('code=' + $tight.Code + ' bytes=' + (Get-ByteCount $tight.Out))
    if ($null -ne $tightDoc) {
        $honest = ([bool]$tightDoc.truncated -or [bool]$tightDoc.oversized -or [string]$tightDoc.status -eq 'oversized')
        Assert-That $honest 'w3b: over-budget output reports truncated/oversized honestly (never substring-cut)' ('status=' + [string]$tightDoc.status + ' truncated=' + [string]$tightDoc.truncated + ' oversized=' + [string]$tightDoc.oversized)
    }
    # FIX1 boundary: -ByteBudget bounds the total, so the payload only fits when
    # one byte is left for the LF. payload = total - 1 of a large-budget run.
    $big = Invoke-BootstrapCli $scriptPath ('-RepoRoot ' + $quotedRepo + ' -Timestamp ' + $fixedStamp + ' -ByteBudget 8192') $null 120000
    $payload = (Get-ByteCount $big.Out) - 1
    $edge = Invoke-BootstrapCli $scriptPath ('-RepoRoot ' + $quotedRepo + ' -Timestamp ' + $fixedStamp + ' -ByteBudget ' + $payload) $null 120000
    $edgeDoc = Get-OnlyJsonLine $edge.Out
    Assert-That ($edge.Code -eq 0 -and ($null -ne $edgeDoc) -and (Get-ByteCount $edge.Out) -le $payload) 'w3c: budget equal to the payload size still fits TOTAL (LF reserved) and degrades honestly' ('budget=' + $payload + ' bytes=' + (Get-ByteCount $edge.Out) + ' code=' + $edge.Code)
    $fit = Invoke-BootstrapCli $scriptPath ('-RepoRoot ' + $quotedRepo + ' -Timestamp ' + $fixedStamp + ' -ByteBudget ' + ($payload + 1)) $null 120000
    $fitDoc = Get-OnlyJsonLine $fit.Out
    Assert-That ($fit.Code -eq 0 -and ($null -ne $fitDoc) -and (Get-ByteCount $fit.Out) -eq ($payload + 1) -and (-not [bool]$fitDoc.truncated)) 'w3d: exact-fit boundary (budget = payload + 1) emits exactly the budget without truncation' ('expected=' + ($payload + 1) + ' bytes=' + (Get-ByteCount $fit.Out) + ' truncated=' + [string]$fitDoc.truncated)

    # ---- AC2: builder unavailable / malformed => fail-open, exit 0 ----
    # Isolated wrapper copy, kept INSIDE the suite base so the single finally
    # removes it (a wrapper whose ../v3/lib is absent/malformed must not leak).
$iso = Join-Path $base ('iso-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $iso -Force | Out-Null
    $isoScript = Join-Path $iso 'runtime\SessionBootstrapContext.ps1'
    Put-Text $isoScript ([IO.File]::ReadAllText($scriptPath))
    $noLib = Invoke-BootstrapCli $isoScript ('-RepoRoot ' + $quotedRepo) $null 120000
    $noLibDoc = Get-OnlyJsonLine $noLib.Out
    Assert-That ($noLib.Code -eq 0 -and ($null -ne $noLibDoc) -and [string]$noLibDoc.status -eq 'unavailable' -and [string]$noLibDoc.reason -eq 'builder-missing') 'w4a: missing builder lib => fail-open envelope (reason=builder-missing) with exit 0' ('code=' + $noLib.Code + ' reason=' + [string]$noLibDoc.reason + ' raw=' + $noLib.Out)
    if ($null -ne $noLibDoc) {
        Assert-That (-not [string]::IsNullOrWhiteSpace([string]$noLibDoc.reason)) 'w4b: fail-open envelope states the reason' ('reason=' + [string]$noLibDoc.reason)
        $n4 = @($noLibDoc.PSObject.Properties | ForEach-Object { $_.Name })
        $miss4 = @('project_id', 'runtime', 'capability_health', 'tasks', 'pending_waits', 'jev_status', 'aimemory_status') | Where-Object { $n4 -notcontains $_ }
        Assert-That (@($miss4).Count -eq 0) 'w4c: fail-open envelope keeps the same section shape' ('missing=' + (@($miss4) -join ','))
    }
    Put-Text (Join-Path $iso 'v3\lib\OrchestrationBootstrapContext.ps1') 'function New-OrchestrationBootstrapContext { if ('
    $badLib = Invoke-BootstrapCli $isoScript ('-RepoRoot ' + $quotedRepo) $null 120000
    $badLibDoc = Get-OnlyJsonLine $badLib.Out
    Assert-That ($badLib.Code -eq 0 -and ($null -ne $badLibDoc) -and [string]$badLibDoc.status -eq 'unavailable' -and [string]$badLibDoc.reason -eq 'builder-unparseable') 'w5: malformed builder lib => fail-open envelope (reason=builder-unparseable) with exit 0' ('code=' + $badLib.Code + ' reason=' + [string]$badLibDoc.reason + ' raw=' + $badLib.Out)

    # ---- AC2: exit 1 is invalid parameter usage only ----
    $notADir = Join-Path $base 'plain-file.txt'
    Put-Text $notADir 'x'
    $u1 = Invoke-BootstrapCli $scriptPath ('-RepoRoot ' + $quotedRepo + ' -ByteBudget -1') $null 120000
    $u2 = Invoke-BootstrapCli $scriptPath ('-RepoRoot ' + $quotedRepo + ' -TelemetryDir "' + $notADir + '"') $null 120000
    $u3 = Invoke-BootstrapCli $scriptPath ('-RepoRoot "' + (Join-Path $base 'no-such-dir-xyz') + '"') $null 120000
    $u4 = Invoke-BootstrapCli $scriptPath ('-RepoRoot ' + $quotedRepo + ' -ByteBudget not-a-number') $null 120000
    Assert-That ($u1.Code -eq 1 -and [string]::IsNullOrWhiteSpace($u1.Out)) 'w6a: negative -ByteBudget => exit 1 and no stdout JSON' ('code=' + $u1.Code + ' out=' + $u1.Out)
    Assert-That ($u2.Code -eq 1 -and [string]::IsNullOrWhiteSpace($u2.Out)) 'w6b: -TelemetryDir that exists and is a file => structural exit 1' ('code=' + $u2.Code + ' out=' + $u2.Out)
    Assert-That ($u3.Code -eq 1 -and [string]::IsNullOrWhiteSpace($u3.Out)) 'w6c: -RepoRoot that is not a directory => exit 1 and no stdout JSON' ('code=' + $u3.Code + ' out=' + $u3.Out)
    Assert-That ($u4.Code -eq 1 -and [string]::IsNullOrWhiteSpace($u4.Out)) 'w6d: non-numeric -ByteBudget => structural exit 1' ('code=' + $u4.Code + ' out=' + $u4.Out)

    # ---- AC5: telemetry matrix on the real repo ----
    $tel = Join-Path $base 'telemetry-ok'
    $t1 = Invoke-BootstrapCli $scriptPath ('-RepoRoot ' + $quotedRepo + ' -Timestamp ' + $fixedStamp + ' -TelemetryDir "' + $tel + '"') $null 120000
    $t2 = Invoke-BootstrapCli $scriptPath ('-RepoRoot ' + $quotedRepo + ' -Timestamp ' + $fixedStamp + ' -TelemetryDir "' + $tel + '"') $null 120000
    $telFile = Join-Path $tel ('bootstrap-compliance-' + ([datetimeoffset]::Parse($fixedStamp).ToUniversalTime().ToString('yyyyMMdd')) + '.jsonl')
    $exists = (Test-Path -LiteralPath $telFile -PathType Leaf)
    $telLines = @()
    if ($exists) { $telLines = @([IO.File]::ReadAllLines($telFile)) }
    Assert-That ($t1.Code -eq 0 -and $t2.Code -eq 0 -and $exists -and $telLines.Count -eq 2) 'w7a: one JSONL line per execution in bootstrap-compliance-YYYYMMDD.jsonl' ('exists=' + $exists + ' lines=' + $telLines.Count)
    if ($telLines.Count -eq 2) {
        $rec = $null
        try { $rec = ConvertFrom-Json $telLines[0] } catch { $rec = $null }
        $keys = @()
        if ($null -ne $rec) { $keys = @($rec.PSObject.Properties | ForEach-Object { $_.Name }) }
        $miss7 = @('ts', 'project_id', 'byte_length', 'sections_ok', 'sections_unavailable', 'truncated', 'oversized', 'runtime_generation') | Where-Object { $keys -notcontains $_ }
        Assert-That (($null -ne $rec) -and @($miss7).Count -eq 0) 'w7b: telemetry line carries the required metadata fields' ('missing=' + (@($miss7) -join ','))
        Assert-That (($null -ne $rec) -and ([long]$rec.byte_length -eq (Get-ByteCount $t1.Out))) 'w7c: telemetry byte_length equals the emitted stdout bytes' ('telemetry=' + [string]$rec.byte_length + ' stdout=' + (Get-ByteCount $t1.Out))
        $leak = @()
        foreach ($token in @('capability_health', 'all_off', 'flags', 'jev_status', 'aimemory_status', 'transport', 'active_count', 'refs', 'synthetic-hold')) {
            if ($telLines[0] -match [regex]::Escape($token)) { $leak += $token }
        }
        Assert-That ($leak.Count -eq 0) 'w7d: telemetry line never carries context content' ('leaked=' + ($leak -join ','))
    }
    # 1 MB cap with pre-size accounting: no append, no truncated line.
    $capDir = Join-Path $base 'telemetry-cap'
    $capProbe = Invoke-BootstrapCli $scriptPath ('-RepoRoot ' + $quotedRepo + ' -TelemetryDir "' + $capDir + '"') $null 120000
    $capFile = @(Get-ChildItem -LiteralPath $capDir -Filter '*.jsonl' -File)[0].FullName
    $pad = New-Object Text.StringBuilder
    [void]$pad.Append((' ' * 1000000))
    [void]$pad.Append((' ' * 48575))
    Put-Text $capFile ($pad.ToString() + "`n")
    $capLenBefore = (Get-Item -LiteralPath $capFile).Length
    $capLinesBefore = @([IO.File]::ReadAllLines($capFile)).Count
    $capProbe2 = Invoke-BootstrapCli $scriptPath ('-RepoRoot ' + $quotedRepo + ' -TelemetryDir "' + $capDir + '"') $null 120000
    $capLenAfter = (Get-Item -LiteralPath $capFile).Length
    Assert-That ($capProbe2.Code -eq 0 -and $capLenAfter -eq $capLenBefore -and $capLenAfter -eq 1048576) 'w8a: 1 MB cap refuses the append (fail-closed, file byte-identical)' ('before=' + $capLenBefore + ' after=' + $capLenAfter + ' code=' + $capProbe2.Code)
    # FIX2: real cross-process contention. The test holds the exclusive handle
    # on the telemetry file; the CLI must skip silently, still exit 0 and still
    # emit valid JSON, and must not append through the contended file.
    $busyDir = Join-Path $base 'telemetry-busy'
    New-Item -ItemType Directory -Path $busyDir -Force | Out-Null
    $busyFile = Join-Path $busyDir 'bootstrap-compliance-20260101.jsonl'
    Put-Text $busyFile ('{"pad":1}' + "`n")
    $busyLenBefore = (Get-Item -LiteralPath $busyFile).Length
    $busyArgs = '-RepoRoot ' + $quotedRepo + ' -Timestamp ' + $fixedStamp + ' -TelemetryDir "' + $busyDir + '"'
    $held = [System.IO.File]::Open($busyFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $busy = Invoke-BootstrapCli $scriptPath $busyArgs $null 120000
    }
    finally { try { $held.Dispose() } catch { } }
    $busyLenAfter = (Get-Item -LiteralPath $busyFile).Length
    Assert-That ($busy.Code -eq 0 -and $busyLenAfter -eq $busyLenBefore -and ($null -ne (Get-OnlyJsonLine $busy.Out))) 'w9a: exclusive handle held elsewhere => cross-process contention skips and startup still emits JSON with exit 0' ('code=' + $busy.Code + ' before=' + $busyLenBefore + ' after=' + $busyLenAfter)
    Assert-That ([string]::IsNullOrWhiteSpace($busy.Err)) 'w9b: contention skips SILENTLY (no stderr note, no error noise)' ('err=' + $busy.Err.Trim())
    # After release the very same directory is usable again (no poison state).
    $afterRelease = Invoke-BootstrapCli $scriptPath $busyArgs $null 120000
    Assert-That ($afterRelease.Code -eq 0 -and (Get-Item -LiteralPath $busyFile).Length -gt $busyLenBefore) 'w9c: telemetry resumes once the exclusive handle is released' ('code=' + $afterRelease.Code)

    # FIX3/FIX4: OPERATIONAL telemetry failures disable telemetry for that run
    # with an honest stderr note, full JSON and exit 0.
    $insideFile = Join-Path $notADir 'under-file'
    $oper1 = Invoke-BootstrapCli $scriptPath ('-RepoRoot ' + $quotedRepo + ' -Timestamp ' + $fixedStamp + ' -TelemetryDir "' + $insideFile + '"') $null 120000
    Assert-That ($oper1.Code -eq 0 -and ($null -ne (Get-OnlyJsonLine $oper1.Out)) -and $oper1.Err -match 'telemetry disabled') 'w15a: -TelemetryDir under a non-creatable path => exit 0 + valid JSON + honest stderr note' ('code=' + $oper1.Code + ' err=' + $oper1.Err.Trim())
    $roDir = Join-Path $base 'telemetry-readonly'
    New-Item -ItemType Directory -Path $roDir -Force | Out-Null
    $aclOk = $false
    try {
        # Arguments must stay separate: a single '/deny <ace>' string is
        # rejected as an invalid parameter by icacls.
        $null = & icacls $roDir '/deny' ($env:USERNAME + ':(OI)(CI)(W)') 2>&1
        # Functional proof (locale independent): the deny ACE must block writes.
        $probe = Join-Path $roDir 'acl-probe.tmp'
        $probeDenied = $false
        try { [IO.File]::WriteAllText($probe, 'x') } catch { $probeDenied = $true }
        if (-not $probeDenied) { try { Remove-Item -LiteralPath $probe -Force } catch { } }
        $aclOk = $probeDenied
    }
    catch { $aclOk = $false }
    if ($aclOk) {
        $oper2 = Invoke-BootstrapCli $scriptPath ('-RepoRoot ' + $quotedRepo + ' -Timestamp ' + $fixedStamp + ' -TelemetryDir "' + $roDir + '"') $null 120000
        $roFiles = @()
        try { $roFiles = @(Get-ChildItem -LiteralPath $roDir -File -Force -ErrorAction SilentlyContinue) } catch { $roFiles = @() }
        Assert-That ($oper2.Code -eq 0 -and ($null -ne (Get-OnlyJsonLine $oper2.Out)) -and $oper2.Err -match 'telemetry disabled' -and $roFiles.Count -eq 0) 'w15b: read-only -TelemetryDir (ACL denied) => exit 0 + valid JSON + honest stderr note, no write' ('code=' + $oper2.Code + ' files=' + $roFiles.Count + ' err=' + $oper2.Err.Trim())
        try { $null = & icacls $roDir '/remove:d' $env:USERNAME 2>&1 } catch { }
    }
    else {
        # Denied access without touching ACLs: the daily JSONL path is occupied
        # by a directory, so the exclusive open fails with access denied.
        $blockedDir = Join-Path $base 'telemetry-denied'
        New-Item -ItemType Directory -Path (Join-Path $blockedDir 'bootstrap-compliance-20260101.jsonl') -Force | Out-Null
        $oper3 = Invoke-BootstrapCli $scriptPath ('-RepoRoot ' + $quotedRepo + ' -Timestamp ' + $fixedStamp + ' -TelemetryDir "' + $blockedDir + '"') $null 120000
        Assert-That ($oper3.Code -eq 0 -and ($null -ne (Get-OnlyJsonLine $oper3.Out)) -and $oper3.Err -match 'telemetry disabled') 'w15b: denied telemetry path => exit 0 + valid JSON + honest stderr note (icacls unavailable)' ('code=' + $oper3.Code + ' err=' + $oper3.Err.Trim())
        Write-Host '[NOTE] icacls could not deny write on this host; w15b used the denied-path variant.'
    }

    # ---- AC5 / AC6: hostile fixture, no dir => zero writes, canary never leaks ----
    $fxBase = Join-Path $base 'fixtures'
    New-Item -ItemType Directory -Path $fxBase -Force | Out-Null
    $fixture = New-FixtureRepo $fxBase $hostileName $canary
    $before = @(Get-ChildItem -LiteralPath $fxBase -Recurse -File | ForEach-Object { $_.FullName + '|' + $_.Length })
    $noWrite = Invoke-BootstrapCli $scriptPath ('-RepoRoot "' + $fixture + '" -Timestamp ' + $fixedStamp) $null 120000
    $after = @(Get-ChildItem -LiteralPath $fxBase -Recurse -File | ForEach-Object { $_.FullName + '|' + $_.Length })
    Assert-That ($noWrite.Code -eq 0 -and ($before -join ';') -ceq ($after -join ';') -and (@($after).Count -eq 4)) 'w10: without -TelemetryDir there are zero writes' ('before=' + @($before).Count + ' after=' + @($after).Count)
    Assert-That ((-not ($noWrite.Out -match [regex]::Escape($canary))) -and (-not ($noWrite.Out -match 'evil\.com')) -and (-not ($noWrite.Out -match 'token=bad'))) 'w6-sanitize: hostile RepoRoot and task id never leak to stdout' ('out=' + $noWrite.Out)
    $telHostile = Join-Path $base 'telemetry-hostile'
    $hx = Invoke-BootstrapCli $scriptPath ('-RepoRoot "' + $fixture + '" -Timestamp ' + $fixedStamp + ' -TelemetryDir "' + $telHostile + '"') $null 120000
    $hxFile = @(Get-ChildItem -LiteralPath $telHostile -Filter '*.jsonl' -File)[0]
    $hxText = [IO.File]::ReadAllText($hxFile.FullName)
    $hxRec = ConvertFrom-Json $hxText
    Assert-That ((-not ($hxText -match [regex]::Escape($canary))) -and (-not ($hxText -match 'evil\.com')) -and (-not ([string]$hxRec.project_id -match 'evil\.com'))) 'w11: hostile project_id is sanitized in telemetry' ('line=' + $hxText.Trim())
    Assert-That ([string]$hxRec.project_id -match 'redacted' -and [int]$hxRec.sections_ok -ge 4) 'w11b: telemetry still reports honest metadata for the hostile fixture' ('project_id=' + [string]$hxRec.project_id + ' sections_ok=' + [string]$hxRec.sections_ok)

    # ---- AC2 / honesty: invalid -Timestamp falls back to internal UTC with a note ----
    $badStamp = Invoke-BootstrapCli $scriptPath ('-RepoRoot ' + $quotedRepo + ' -Timestamp not-a-timestamp') $null 120000
    $badStampDoc = Get-OnlyJsonLine $badStamp.Out
    $fresh = $false
    if ($null -ne $badStampDoc) {
        $parsedStamp = [datetimeoffset]::MinValue
        if ([datetimeoffset]::TryParse([string]$badStampDoc.generated_at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsedStamp)) {
            $fresh = ([Math]::Abs(([datetimeoffset]::UtcNow - $parsedStamp.ToUniversalTime()).TotalMinutes) -lt 10)
        }
    }
    Assert-That ($badStamp.Code -eq 0 -and ($null -ne $badStampDoc) -and $fresh) 'w13a: invalid -Timestamp falls back to internal UTC and still exits 0' ('code=' + $badStamp.Code + ' generated_at=' + [string]$badStampDoc.generated_at)
    Assert-That ($badStamp.Err -match 'Timestamp') 'w13b: clock fallback emits an honest note on stderr' ('err=' + $badStamp.Err.Trim())

    # ---- AC4: parse-only static contract of the new lib ----
    $libText = [IO.File]::ReadAllText($scriptPath)
    $forbidden = @('Start-Process', 'Invoke-Expression', 'Invoke-Command', 'Start-Job', 'Start-ThreadJob', 'Import-Module', 'Invoke-WebRequest', 'Invoke-RestMethod', 'WebClient', 'HttpClient', 'HttpWebRequest', 'Socket', 'Sockets', 'System.Net', 'Diagnostics.Process', 'cmd.exe', 'iex ', 'WriteAllText', 'WriteAllBytes', 'Copy-Item', 'Move-Item', 'Remove-Item', 'Out-File', 'Set-Content', 'Add-Content', 'Tee-Object', '-Parallel')
    $hits = @()
    foreach ($f in $forbidden) { if ($libText -match [regex]::Escape($f)) { $hits += $f } }
    Assert-That ($hits.Count -eq 0) 'w12a: new lib has no spawn, network, module import or whole-file write primitive' ('hits=' + ($hits -join ','))
    $callOps = @(Select-String -LiteralPath $scriptPath -Pattern '&\s*\$')
    Assert-That ($callOps.Count -eq 0) 'w12b: new lib has no call-operator invocation' ('hits=' + $callOps.Count)
    $dotSources = @(Select-String -LiteralPath $scriptPath -Pattern '(?m)^\s*\.\s+\$\w')
    Assert-That ($dotSources.Count -eq 1 -and ($dotSources[0].Line -match 'builderPath')) 'w12c: the only dot-source is the slice 1 builder lib' ('count=' + $dotSources.Count)
    $dirCreates = @(Select-String -LiteralPath $scriptPath -Pattern 'New-Item -ItemType Directory')
    Assert-That ($dirCreates.Count -eq 1) 'w12d: the only directory creation is the explicit -TelemetryDir' ('mkdir=' + $dirCreates.Count)
    # FIX2: cross-process exclusion must be a FileShare.None exclusive handle,
    # not an in-process Monitor (which cannot protect the cap).
    Assert-That ($libText -match 'FileShare\]::None' -and $libText -match 'FileAccess\]::ReadWrite') 'w12e: telemetry uses an exclusive FileShare.None handle for measure+append' 'exclusive handle not found'
    Assert-That ($libText -notmatch 'Threading\.Monitor') 'w12f: in-process Monitor lock removed (TOCTOU source)' 'Monitor still present'
    Assert-That ($libText -match 'skipped = ''contended''' -and $libText -match "-cne 'contended'") 'w12g: contention is a distinct silent skip token in lib and caller' 'contended token not wired'

    # ---- PS7 lane (executed only when pwsh exists) ----
    $pwshPath = ''
    try {
        # Get-Command can return several apps with the same name (Windows app
        # execution aliases), so enumerate and keep the first real file.
        foreach ($app in @(Get-Command -Name 'pwsh' -CommandType Application -ErrorAction SilentlyContinue)) {
            foreach ($cand in @([string]$app.Path, [string]$app.Source, [string]$app.Definition)) {
                if ((-not [string]::IsNullOrWhiteSpace($cand)) -and (Test-Path -LiteralPath $cand -PathType Leaf)) { $pwshPath = $cand; break }
            }
            if (-not [string]::IsNullOrWhiteSpace($pwshPath)) { break }
        }
    }
    catch { $pwshPath = '' }
    if (-not [string]::IsNullOrWhiteSpace($pwshPath)) {
        $psi7 = New-Object System.Diagnostics.ProcessStartInfo
        $psi7.FileName = $pwshPath
        $psi7.Arguments = '-NoProfile -File "' + $scriptPath + '" -RepoRoot "' + $repoRoot + '" -Timestamp ' + $fixedStamp
        $psi7.UseShellExecute = $false
        $psi7.RedirectStandardOutput = $true
        $psi7.RedirectStandardError = $true
        $psi7.CreateNoWindow = $true
        $psi7.WorkingDirectory = $script:repoRoot
        $p7 = [System.Diagnostics.Process]::Start($psi7)
        $so7 = $p7.StandardOutput.ReadToEndAsync()
        $se7 = $p7.StandardError.ReadToEndAsync()
        $f7 = $false
        try { $f7 = $p7.WaitForExit(120000) } catch { $f7 = $false }
        if (-not $f7) { try { $p7.Kill() } catch { } }
        $o7 = ''
        try { if ($so7.Wait(10000)) { $o7 = [string]$so7.Result } } catch { $o7 = '' }
        $c7 = -1
        try { if ($f7) { $c7 = [int]$p7.ExitCode } } catch { $c7 = -1 }
        try { $p7.Close() } catch { }
        $doc7 = Get-OnlyJsonLine $o7
        Assert-That ($c7 -eq 0 -and ($null -ne $doc7) -and [string]$doc7.project_id -eq 'opencode-orchestration') 'w14: same wiring runs green under PS7 (pwsh)' ('code=' + $c7 + ' out=' + $o7)
    }
    else {
        # Explicit marker: the runner reports SKIP instead of a silent PASS.
        Write-Host '[SKIP] ps7 lane not executed: no usable pwsh executable on this host.'
    }
}
finally {
    try { if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
}
Write-Host ("[SUMMARY] passed={0} failed={1}" -f $script:passed, $script:failed)
if ($script:failed -gt 0) { exit 1 }