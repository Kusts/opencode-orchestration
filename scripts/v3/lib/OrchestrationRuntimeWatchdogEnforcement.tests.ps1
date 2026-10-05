<#!
.SYNOPSIS
    Tests for the Phase 26 watchdog ENFORCE path (safe process interrupt).
.DESCRIPTION
    Hermetic: temp dirs under $env:TEMP for telemetry + fixture flags +
    kernel task dirs, cleanup in finally. Bracketed output the runner
    parses. Exit 0 on all pass, exit 1 on any fail or unexpected
    exception. PS 5.1 compatible. ASCII-only.

    Every scenario carries an EXTERNAL bound: fast inline scenarios
    keep a per-scenario Stopwatch (asserted below 90s), bounded
    WaitForExit(milliseconds) instead of bare waits, bounded settlement
    waits inside the lib (shared enforce deadline across
    enum+verify+wait), and a finally-block safety kill restricted
    to OWN tracked child PIDs created by this file (never user
    processes, never AI Memory 49374, Docker or ssh). No infinite wait
    exists in this file. Scenarios that shell out (CLI calls), that run
    an interrupt, that build multi-level process trees, and deliberately
    hung scenarios run through a REAL-deadline harness
    (Invoke-EnforceScenario / Invoke-EnforceCliBounded: Start-Job +
    Wait-Job -Timeout + Stop-Job/Remove-Job cleanup); a deadline breach
    aborts the job and FAILS the scenario instead of hanging the suite.

    Covers (PLAN Phase 26 required tests):
      1. hung worker => HARD_TIMEOUT => interrupt on a REAL child
         process created by the test (REAL-deadline job); child exits;
         telemetry records WATCHDOG_INTERRUPTED + WATCHDOG_SETTLED
         (enforce source).
      2. no-progress worker => NO_PROGRESS => interrupt (real child).
      3. identical action repeated: soft 3 => STALL_SUSPECTED without
         interrupt (child alive); hard 5 => REPEATED_ACTION interrupt.
      4. A-B cycle length 2 repeated 3x => REPEATED_CYCLE interrupt.
      5. legitimate bounded iterator (declared budget + progress marker
         per action) is NOT killed; child survives.
      6. execution WITHOUT process identity under gate ENFORCE stays
         advisory-only (WATCHDOG_NO_PROCESS_IDENTITY); sentinel child
         untouched; unbound registration keeps the frozen P25 HOLD.
      7. successful interrupt: exit confirmed, settlement queryable via
         Get-OrchestrationWatchdogSettlement and Eval -IncludeEnforcement.
      8. failed interrupt: short-lived child exits alone before Stop =>
         ALREADY_EXITED settlement, no exception; PID/parent divergence
         => WATCHDOG_INTERRUPT_REFUSED with the process intact; stop on
         a dead PID maps to structured ALREADY_EXITED, never throws.
      9. kernel seam: release/complete blocked with SETTLEMENT_REQUIRED
         while an interrupt mark is pending; released after confirm;
         CLI watchdog-interrupt / watchdog-settle wired (temp dirs).
     10. sibling: interrupting one execution leaves the other execution
         registered, its child alive and its record intact.
     11. frozen-file guards: P25 test file still holds the unbound HOLD,
         capability-flags.json watchdog still {enabled:false,shadow:true}.
     P26-FIX1 hardening (review+security findings F1..F7):
     12. F1 exact identity: skewed start times (+1s/+6s, previously
         inside the 30s tolerance) are REFUSED start-time-mismatch;
         a full interrupt resolves the live process exactly ONCE
         (kill+wait reuse the verified instance; stale instances map
         to ALREADY_EXITED without PID re-resolution).
     13. F2 CIM fail-closed: registration with cim_failure under
         SHADOW registers UNBOUND (advisory NO_PROCESS_IDENTITY
         under ENFORCE); under ENFORCE it keeps the P25 HOLD with
         nothing stored; an interrupt on a proven binding with
         cim_failure REFUSES (parent-unverifiable, child alive);
         a divergent declared parent registers unbound.
     14. F3 tree kill (real-deadline jobs): a root that spawns a
         child that spawns a durable grandchild is interrupted as
         a verified tree (root+descendants killed via held
         instances, SETTLED only when ALL exit);
         tree_enum_failure REFUSES with the root alive;
         descendant links proven fail-closed at the verifier
         (unprovable fresh parent links => descendant-unverifiable).
         Residual: a child dying externally before the pre-kill
         snapshot vanishes from CIM, so orphans below it escape
         the snapshot (same class as no-Job-Objects).
     15. F4 inspection vs absence: query_failure on a live bound
         child => WATCHDOG_INTERRUPT_FAILED with PENDING
         settlement (never SETTLED, child alive); proven-gone PIDs
         still map to ALREADY_EXITED (distinct cases).
     16. F5 real deadlines + stop failure: stop_failure (injected
         OS refusal) on a live bound child =>
         WATCHDOG_INTERRUPT_FAILED, child alive, settlement
         FAILED-not-settled; invalid inject tokens rejected;
         scenario-9 CLI calls run under Invoke-EnforceCliBounded;
         a deliberately hung scenario is aborted by its external
         deadline (timeout proven).
     17. F6 terminal stickiness centralized: repeated interrupts
         via the dispatcher AND via the direct entry stay
         idempotent (settled_before, interrupted flag preserved,
         zero new live queries on the direct repeat);
         ALREADY_EXITED repeats intact.
     18. F7 kernel fail-closed: the generic transition to
         CANCELLED and to EXHAUSTED is blocked with
         SETTLEMENT_REQUIRED while an interrupt mark is pending
         (released after settle); the settlement-clear helper
         returns $false for every malformed shape;
         worker-result auto-exhaustion is gated the same way.
     P26-FIX2 hardening (re-review findings F-A..F-E):
     19. F-A pinned handle: the choke point fixes the native handle
         on first access (PS 5.1 / PS 7 cache it, later Kill/Wait/
         HasExited target the pinned process); skew +1s/+6s still
         REFUSED; a stale fixed instance maps to ALREADY_EXITED with
         zero new PID resolutions.
     20. F-B generation identity: the frontier carries pid+ticks; a
         candidate clearly older than its ancestor is EXCLUDED
         (transitively, counted, never killed, never a failure);
         the ambiguous band fails closed; a simulated PID-reuse
         orphan (test-only parent-link override, real creations)
         survives while the legitimate set settles.
     21. F-C caps fail closed: depth 32 / nodes 64 with a non-empty
         frontier => WATCHDOG_TREE_LIMIT_EXCEEDED, nothing killed,
         never settled, settlement REFUSED.
     22. F-D gone-root settlement: the verified set is always
         liquidated (root gone before stop; prior STILL_RUNNING with
         the root gone) => ALREADY_EXITED only after the whole set
         exits, else FAILED with settlement PENDING.
     23. F-E shared deadline (exact semantics): one enforce deadline
         covers preparation; it is checked at level entry, after every
         enumeration, at every candidate, before the first kill in BOTH
         paths including the empty gone branch, before every stop, and
         before ANY terminal settlement; post-deadline with kills =>
         FAILED/PENDING partial with preserved evidence (partial,
         killed_count), never terminal; post-deadline with nothing
         killed => WATCHDOG_DEADLINE_EXCEEDED. Residual: a single CIM
         call stays under WMI timeouts.
     P26-FIX3 hardening (final re-review FIX3-1..3):
     24. FIX3-1 late deadline: post-enumeration, per-candidate and
         pre-kill (both paths, empty branch included) re-checks plus
         per-stop and pre-terminalization gates => WATCHDOG_DEADLINE_EXCEEDED
         or FAILED/PENDING partial, never kill/settled past the deadline;
         predicate unit-tested.
     25. FIX3-2 gone-path attribution: only the last verified set
         (exact pid+ticks) or creations within lastAliveProof are
         liquidated; newer => WATCHDOG_TREE_EXCLUDED, never killed.
     26. FIX3-3 deterministic disposal: every non-transferred pinned
         handle closed via the disposal choke (diagnostic counter);
         refusal after accumulation exercised.
     P26-FIX4 hardening (final re-review FIX4-1..3):
     27. FIX4-1 validation instant: last_alive_proof is captured DURING
         validation with the live pinned instance (returned as proof_at)
         and stamped from it, never from a later now(); a stretched
         validation-to-recording window still excludes a child born in
         between.
     28. FIX4-2a empty-branch gate: an expired deadline in the gone
         path with no attributable descendants => DEADLINE_EXCEEDED,
         never terminal ALREADY_EXITED.
     29. FIX4-2b mid-kill expiry: deadline carried into every stop;
         expiry between kills => FAILED/PENDING partial with preserved
         evidence (partial, killed_count), never terminal; a later
         call resumes the remainder (F6 intact).
     P26-FIX5 hardening (final re-review FIX5-1..4):
     30. FIX5-1 explicit life proof: proof_at only after HasExited -eq
         $false on the pinned instance at capture; death between
         resolution and capture => INVALID/REFUSED with no proof, no
         now() fallback, nothing killed, nothing settled.
     31. FIX5-2 terminalization revalidation: deadline re-checked
         immediately before persisting ANY terminal settlement, after
         the blocking telemetry write, in all 3 paths (normal, gone,
         gone-empty); slow-writer crossing => partial PENDING with
         evidence when kills happened, DEADLINE_EXCEEDED otherwise;
         never post-deadline terminal.
     32. FIX5-3 per-instance disposal: every resolved instance tracked
         and closed exactly once (multisets match, no totals
         compensation).
     P26-FIX6 hardening (final re-review FIX6-1..3):
     33. FIX6-1b verified-but-unproven ownership => REFUSED
         proof-unavailable (identity and parentage verify; the reason
         is lack of proof, not CIM); end-to-end refusal stores
         REFUSED, kills nothing, stamps no late proof.
     34. FIX6-1c producer without proof_at => INVALID, never a binding
         with now() (stub producer, table stays empty).
    RR-P26-JOB-WIRING (backstop de Job Object no enforcement, 2026-10-05):
     35. JOB43 escape pos-snapshot FECHADO: a raiz verificada e atribuida ao
         job antes do snapshot; um descendente criado DEPOIS do snapshot
         (hook test-only pre_kill_delay_ms + arquivo de sinal observado pelo
         proprio filho da raiz) NAO consta de last_verified_tree (prova de que
         o kill CIM nao alcancava ele) e mesmo assim MORRE pelo
         TerminateJobObject; a arvore verificada morre pelo caminho CIM de
         sempre; job_members_remaining=0 e a evidencia do job fica no
         registro de settlement.
     36. JOB44 attach RECUSADO (hook test-only job_attach_refuse) => nota
         'refused:<motivo>', nenhum job kill, settlement gravado IDENTICO ao
         do run com attach (comparacao de todos os campos sem job_*) e
         sentinel nao relacionado intacto nos dois runs.
     37. JOB45 guards: nenhum taskkill nas duas libs; o enforcement nunca
         referencia o 49374 (a lib de job mantem a promessa no contrato);
         wiring presente; PID desconhecido => recusa estruturada no gone-path
         SEM tocar no job (nada morto).
     38. JOB43+ close-record: job_close_applied/job_close_note publicados no
         resultado E no registro de settlement (fechamento do handle como
         fato verificavel por leitura, sem leak silencioso).
     39. JOB46 D-2 CONTROLE NEGATIVO do discriminante: o MESMO cenario do
         JOB43 com o attach recusado => o descendente tardio (nascido depois
         do snapshot, ausente de last_verified_tree) SOBREVIVE ao settlement
         e segue vivo 2s depois, com settlement byte-identico ao do caso
         positivo na projecao sem job_*. Logo, no JOB43 quem o matou foi o
         backstop do job, nao o kill CIM. O cleanup do sobrevivente e pelo
         handle do job de teste (kill-on-close), nunca taskkill por PID.
     40. JOB47 FIX1 HIGH-1 (adversarial): o prazo expira ENTRE o kill CIM e o
         backstop (stop_delay_ms com orcamento curto) => nenhum
         TerminateJobObject, handle fechado INERTEMENTE, nota bounded
         job_skip='deadline-expired', membros vivos registrados, o descendente
         tardio SOBREVIVE (igual ao pre-wiring) e a classificacao de deadline
         ja existente (FAILED/PENDING partial, nunca terminal). Cleanup do
         sobrevivente pelo handle do job de teste.
     41. JOB48 FIX1 HIGH-2 (adversarial): a raiz sai sozinha DEPOIS do snapshot
         deixando SO o descendente tardio; a premissa "killed CIM = 0" e
         PROVADA (todo PID do snapshot verificado morto depois do interrupt),
         o booleano do ato letal do job entra na decisao (nunca como
         contagem: KilledCount segue 0) e ainda assim
         interrupted=true + ALREADY_EXITED (nenhum REFUSED falso depois de um
         ato letal).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$libPath = Join-Path $PSScriptRoot 'OrchestrationRuntimeWatchdog.ps1'
. $libPath
$kernelPath = Join-Path $PSScriptRoot 'OrchestrationTaskKernel.ps1'
. $kernelPath

$script:passed = 0
$script:failed = 0
$script:enfChildren = New-Object System.Collections.ArrayList

function Assert-Enforce {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) {
        Write-Host ("[PASS] {0}" -f $Name)
        $script:passed++
    }
    else {
        if ([string]::IsNullOrWhiteSpace($Detail)) { Write-Host ("[FAIL] {0}" -f $Name) }
        else { Write-Host ("[FAIL] {0} -- {1}" -f $Name, $Detail) }
        $script:failed++
    }
}

function Write-EnforceFixture {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $lf = ($Text -replace "`r`n", "`n" -replace "`r", "`n")
    [IO.File]::WriteAllText($Path, $lf, [Text.UTF8Encoding]::new($false))
}

function Read-EnforcePidFile {
    <#
    .SYNOPSIS
        Bounded read of a PID a test's OWN child wrote to disk (the child
        writes the real PID it created; we never invent one). Returns 0
        when the file never appears with a bare integer. Never throws.
    #>
    param([Parameter(Mandatory = $true)][string]$Path, [int]$TimeoutMs = 20000)
    $budget = [int]$TimeoutMs
    if ($budget -lt 0) { $budget = 0 }
    if ($budget -gt 60000) { $budget = 60000 }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt [long]$budget) {
        $txt = ''
        try { if (Test-Path -LiteralPath $Path -PathType Leaf) { $txt = ([IO.File]::ReadAllText($Path)).Trim() } } catch { $txt = '' }
        if ($txt -match '^\d+$') { return [int]$txt }
        Start-Sleep -Milliseconds 150
    }
    return 0
}

function Get-EnforceSettlementShape {
    <#
    .SYNOPSIS
        Canonical projection of a stored enforcement record with the job_*
        keys REMOVED (RR-P26-JOB-WIRING): lets a test prove that an
        attach-refused run stores exactly the same settlement as a run with
        the attach, i.e. the fallback is behavior-identical and the only
        difference is the added backstop evidence. Never throws.
    #>
    param($Exec)
    $acc = ''
    try {
        $enf = $Exec['enforcement']
        if (($null -eq $enf) -or (-not ($enf -is [System.Collections.IDictionary]))) { return '<none>' }
        $keys = @()
        foreach ($k in @($enf.Keys)) { $keys += ([string]$k) }
        $keys = @($keys | Where-Object { (-not ([string]$_).StartsWith('job_')) } | Sort-Object)
        foreach ($k in $keys) { $acc += ([string]$k + '=' + [string]$enf[$k] + ';') }
        return $acc
    }
    catch { return '<err>' }
}

function ConvertTo-EnforceArg {
    <#
    .SYNOPSIS
        Start-Process -ArgumentList does NOT quote array elements on PS 5.1
        nor on PS7 (measured on both engines), so a temp path containing a
        space is split and the child fails to start. This quotes the value
        when it needs quoting and leaves it untouched otherwise, identical
        on both engines. Never throws.
    #>
    param([string]$Value)
    $v = [string]$Value
    if (($v.Length -gt 1) -and ($v.StartsWith('"')) -and ($v.EndsWith('"'))) { return $v }
    if ($v.Contains(' ')) { return ('"' + $v + '"') }
    return $v
}

function New-EnforceBudget {
    param([int]$Steps, [int]$Wall, [int]$NoProg)
    return [ordered]@{
        profile = 'fast'; step_budget = $Steps; wall_clock_seconds = $Wall
        no_progress_seconds = $NoProg; repeated_action_soft_limit = 3
        repeated_action_hard_limit = 5; cycle_repeat_limit = 3; provider_retry_limit = 2
    }
}

function Get-EnforceShell {
    $c = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if (($null -ne $c) -and (-not [string]::IsNullOrWhiteSpace([string]$c.Source))) { return ([string]$c.Source) }
    return (Join-Path ([string]$env:SystemRoot) 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

function Start-EnforceChild {
    param([int]$SleepSeconds = 120)
    $shell = Get-EnforceShell
    $p = Start-Process -FilePath $shell -ArgumentList @('-NoProfile', '-Command', ('Start-Sleep -Seconds ' + [string]$SleepSeconds)) -WindowStyle Hidden -PassThru
    [void]$script:enfChildren.Add($p)
    return $p
}

function Start-EnforceShortChild {
    param([int]$SleepMs = 300)
    $shell = Get-EnforceShell
    $p = Start-Process -FilePath $shell -ArgumentList @('-NoProfile', '-Command', ('Start-Sleep -Milliseconds ' + [string]$SleepMs)) -WindowStyle Hidden -PassThru
    [void]$script:enfChildren.Add($p)
    return $p
}

function Test-EnforcePidAlive {
    <#
    .SYNOPSIS
        Liveness por PID de um descendente PROPRIO rastreado por este arquivo
        (uso unico: o descendente tardio, cujo PID o filho escreveu em disco).
        NUNCA e alvo de kill por PID aqui: o encerramento usa o handle do job
        de teste (ou Stop-EnforceSafety, que recebe o System.Diagnostics.
        Process). Never throws.
    #>
    param([int]$ProcessId)
    if ([int]$ProcessId -lt 1) { return $false }
    try {
        $live = Get-Process -Id ([int]$ProcessId) -ErrorAction Stop
        return ($null -ne $live)
    }
    catch { return $false }
}

function Test-EnforceAlive {
    param($Proc)
    try {
        $live = Get-Process -Id ([int]$Proc.Id) -ErrorAction Stop
        return ($null -ne $live)
    }
    catch { return $false }
}

function Wait-EnforceExit {
    param($Proc, [int]$TimeoutMs = 8000)
    try {
        try { $Proc.Refresh() } catch { }
        return ([bool]$Proc.WaitForExit([int]$TimeoutMs))
    }
    catch { return (Test-EnforceAlive -Proc $Proc) -eq $false }
}

function Stop-EnforceSafety {
    param($Proc)
    try {
        try { $Proc.Refresh() } catch { }
        if (-not $Proc.HasExited) { Stop-Process -Id ([int]$Proc.Id) -Force -ErrorAction SilentlyContinue }
    }
    catch { }
}

function Stop-EnforceSafetyId {
    param([int]$ProcessId)
    try {
        if (([int]$ProcessId -lt 1) -or ([int]$ProcessId -eq [int]$PID)) { return }
        Stop-Process -Id ([int]$ProcessId) -Force -ErrorAction SilentlyContinue
    }
    catch { }
}

function Invoke-EnforceScenario {
    <#
    .SYNOPSIS
        Real-deadline harness (P26-FIX1 F5): runs $Body in a supervised
        background job (separate process) with a REAL external deadline
        via Wait-Job -Timeout. Timeout => Stop-Job/Remove-Job and a
        timed_out verdict (the scenario FAILS instead of hanging the
        suite). $Body receives one $Ctx argument and must return a single
        @{enforce_verdict=$true; passed=[int]; failed=[int];
        lines=[string[]]} object (mini-asserts inside the job collect
        '[PASS]/[FAIL] ' lines). A job that ends non-Completed without a
        timeout is a harness-visible failure, never a pass. Only OWN
        temp/child resources are touched. Never throws.
    #>
    param([string]$Name, [int]$DeadlineSeconds = 90, [scriptblock]$Body, $Ctx = $null)
    $job = $null
    try {
        $job = Start-Job -ScriptBlock $Body -ArgumentList @($Ctx)
        $waited = Wait-Job -Job $job -Timeout ([int]$DeadlineSeconds)
        if ($null -eq $waited) {
            try { Stop-Job -Job $job -Force -ErrorAction SilentlyContinue } catch { }
            return [PSCustomObject]@{ timed_out = $true; passed = 0; failed = 0; lines = @() }
        }
        $raw = @(Receive-Job -Job $job -ErrorAction SilentlyContinue)
        if ([string]$job.State -cne 'Completed') {
            return [PSCustomObject]@{ timed_out = $false; passed = 0; failed = 1; lines = @('[FAIL] ' + $Name + ' job state=' + [string]$job.State) }
        }
        $verdict = $null
        foreach ($o in $raw) {
            if (($null -ne $o) -and ($o -is [System.Collections.IDictionary]) -and $o.Contains('enforce_verdict')) { $verdict = $o }
        }
        if ($null -eq $verdict) {
            return [PSCustomObject]@{ timed_out = $false; passed = 0; failed = 1; lines = @('[FAIL] ' + $Name + ' produced no verdict object') }
        }
        return [PSCustomObject]@{ timed_out = $false; passed = [int]$verdict['passed']; failed = [int]$verdict['failed']; lines = @($verdict['lines']) }
    }
    catch {
        return [PSCustomObject]@{ timed_out = $false; passed = 0; failed = 1; lines = @('[FAIL] ' + $Name + ' harness error') }
    }
    finally {
        if ($null -ne $job) { try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch { } }
    }
}

function Merge-EnforceScenario {
    param($Verdict, [string]$Name)
    foreach ($ln in @($Verdict.lines)) {
        $t = ([string]$ln).Trim()
        if ($t.StartsWith('[PASS]', [System.StringComparison]::Ordinal)) {
            Assert-Enforce $true ($Name + ' :: ' + $t.Substring(6).Trim())
        }
        elseif ($t.StartsWith('[FAIL]', [System.StringComparison]::Ordinal)) {
            Assert-Enforce $false ($Name + ' :: ' + $t.Substring(6).Trim())
        }
        else {
            Write-Host ('[INFO] ' + $Name + ' :: ' + $t)
        }
    }
    if ([bool]$Verdict.timed_out) {
        Assert-Enforce $false ($Name + ' finished before the external deadline') 'job aborted by deadline'
    }
    else {
        Assert-Enforce ((([int]$Verdict.failed -eq 0) -and ([int]$Verdict.passed -gt 0))) ($Name + ' verdict clean') ('pass=' + [string][int]$Verdict.passed + ' fail=' + [string][int]$Verdict.failed)
    }
}

function Invoke-EnforceCliBounded {
    <#
    .SYNOPSIS
        Runs one CLI invocation (powershell + script + args) inside a
        supervised job with a REAL external deadline (P26-FIX1 F5).
        Returns @{ok, timed_out, exit, out}. Never throws.
    #>
    param([Parameter(Mandatory = $true)][string]$Exe, [Parameter(Mandatory = $true)][string]$ScriptFile, [string[]]$CliArgs = @(), [int]$TimeoutSeconds = 60)
    $job = $null
    try {
        $job = Start-Job -ScriptBlock {
            param($E, $F, $A)
            $ErrorActionPreference = 'Stop'
            $o = @(& $E -NoProfile -File $F @A)
            $code = $LASTEXITCODE
            return @{ enforce_cli = $true; exit = [int]$code; out = ((@($o) | ForEach-Object { [string]$_ }) -join "`n") }
        } -ArgumentList @($Exe, $ScriptFile, $CliArgs)
        $waited = Wait-Job -Job $job -Timeout ([int]$TimeoutSeconds)
        if (($null -eq $waited) -or ([string]$job.State -cne 'Completed')) {
            try { Stop-Job -Job $job -Force -ErrorAction SilentlyContinue } catch { }
            return [PSCustomObject]@{ ok = $false; timed_out = $true; exit = -1; out = '' }
        }
        $raw = @(Receive-Job -Job $job -ErrorAction SilentlyContinue)
        foreach ($o in $raw) {
            if (($null -ne $o) -and ($o -is [System.Collections.IDictionary]) -and $o.Contains('enforce_cli')) {
                return [PSCustomObject]@{ ok = $true; timed_out = $false; exit = [int]$o['exit']; out = ([string]$o['out']) }
            }
        }
        return [PSCustomObject]@{ ok = $false; timed_out = $false; exit = -1; out = '' }
    }
    catch {
        return [PSCustomObject]@{ ok = $false; timed_out = $false; exit = -1; out = '' }
    }
    finally {
        if ($null -ne $job) { try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch { } }
    }
}

function Find-EnforceChildByPath {
    <#
    .SYNOPSIS
        Returns the PID of the first direct child of -ParentId whose
        live executable path equals -ExePath (case-insensitive), else 0.
        Used to pick the powershell mid/net processes out of a CIM
        children snapshot (conhost siblings never match). Never throws.
    #>
    param([int]$ParentId, [string]$ExePath)
    try {
        $want = ([string]$ExePath).Trim()
        if ([string]::IsNullOrWhiteSpace($want)) { return 0 }
        $enum = Get-WatchdogChildProcesses -ProcessId ([int]$ParentId)
        if (-not [bool]$enum.ok) { return 0 }
        foreach ($k in @($enum.children)) {
            $kp = 0
            try { $kp = [int]$k.process_id } catch { $kp = 0 }
            if ($kp -lt 1) { continue }
            $p = $null
            try { $p = Get-Process -Id $kp -ErrorAction Stop } catch { $p = $null }
            if ($null -eq $p) { continue }
            $pp = ''
            try { $pp = ([string]$p.Path).Trim() } catch { $pp = '' }
            if ((-not [string]::IsNullOrWhiteSpace($pp)) -and ($pp -eq $want)) { return $kp }
        }
    }
    catch { }
    return 0
}

function Wait-EnforceSnapshotDrained {
    <#
    .SYNOPSIS
        Drains transient conhost residue after a test root died so a
        gone-empty test observes a deterministically empty snapshot.
        pwsh-spawned console children get a conhost sibling that
        lingers briefly after its owner exits; only conhost.exe images
        are ever stopped here (never powershell.exe, never foreign
        PIDs — all drained PIDs are children of our own dead test
        process). Bounded 15s; returns $true when the snapshot is
        empty. Never throws.
    #>
    param([int]$ProcessId, [int]$TimeoutMs = 15000)
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt [long]$TimeoutMs) {
            $snap = $null
            try { $snap = Get-WatchdogTreeChildSnapshot -ProcessId ([int]$ProcessId) } catch { $snap = $null }
            $kids = @()
            if (($null -ne $snap) -and ([bool]$snap.ok)) { $kids = @($snap.children) }
            if ((@($kids).Count) -eq 0) { $sw.Stop(); return $true }
            $drained = $false
            foreach ($k in @($kids)) {
                $kp = 0
                try { $kpid = $k.process_id; $kp = ([int]$kpid) } catch { $kp = 0 }
                if ($kp -lt 1) { continue }
                $nm = ''
                try { $nm = ([string](Get-Process -Id $kp -ErrorAction Stop).ProcessName).Trim() } catch { $nm = '' }
                if ($nm -ceq 'conhost') {
                    try { Stop-Process -Id ([int]$kp) -Force -ErrorAction SilentlyContinue; $drained = $true } catch { }
                }
            }
            if (-not $drained) { Start-Sleep -Milliseconds 500 }
            else { Start-Sleep -Milliseconds 300 }
        }
        $sw.Stop()
        $fin = $null
        try { $fin = Get-WatchdogTreeChildSnapshot -ProcessId ([int]$ProcessId) } catch { $fin = $null }
        if (($null -ne $fin) -and ([bool]$fin.ok) -and ((@($fin.children).Count) -eq 0)) { return $true }
        return $false
    }
    catch { return $false }
}


function Get-EnforceTreeSize {
    <#
    .SYNOPSIS
        CIM-only recursive descendant count (no live-process queries):
        expected live resolutions for one interrupt = 1 (root) + this.
        Never throws.
    #>
    param([int]$RootPid)
    try {
        $n = 0
        $seen = @{}
        $seen[[int]$RootPid] = $true
        $frontier = @([int]$RootPid)
        $guard = 0
        while (($frontier.Count -gt 0) -and ($guard -lt 32)) {
            $guard++
            $next = New-Object System.Collections.ArrayList
            foreach ($f in $frontier) {
                $e = Get-WatchdogChildProcesses -ProcessId ([int]$f)
                if (-not [bool]$e.ok) { continue }
                foreach ($k in @($e.children)) {
                    $kp = 0
                    try { $kp = [int]$k.process_id } catch { $kp = 0 }
                    if (($kp -lt 1) -or $seen.ContainsKey($kp)) { continue }
                    $seen[$kp] = $true
                    $n++
                    [void]$next.Add($kp)
                }
            }
            $frontier = @($next.ToArray())
        }
        return $n
    }
    catch { return -1 }
}

function Get-EnforceBoundProcess {
    <#
    .SYNOPSIS
        Null-safe reader for the in-memory process binding (PS 5.1
        returns $null when indexing $null, PS 7 throws: this helper
        never throws). Returns the process node, $null when unbound,
        or the string 'missing' when the execution itself is absent.
        Never throws.
    #>
    param([string]$TaskId)
    try {
        $exec = $script:WatchdogExecutions[([string]$TaskId).Trim()]
        if ($null -eq $exec) { return 'missing' }
        try { return $exec['process'] } catch { return 'unreadable' }
    }
    catch { return 'unreadable' }
}

function Wait-EnforceReady {
    <#
    .SYNOPSIS
        Bounded readiness poll for a freshly spawned OWN child: returns
        $true once Get-Process + executable Path + StartTime are all
        readable (avoids just-spawned PID races, observed on .NET
        Core). Callers register only after readiness; downstream asserts
        still validate. Never throws, never waits unboundedly.
    #>
    param($Proc, [int]$TimeoutMs = 10000)
    try {
        $budget = [int]$TimeoutMs
        if ($budget -lt 0) { $budget = 0 }
        if ($budget -gt 30000) { $budget = 30000 }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt [long]$budget) {
            $ok = $false
            try {
                $live = Get-Process -Id ([int]$Proc.Id) -ErrorAction Stop
                if (($null -ne $live) -and (-not [string]::IsNullOrWhiteSpace([string]$live.Path))) {
                    $null = ([DateTime]$live.StartTime).ToUniversalTime()
                    $ok = $true
                }
            }
            catch { $ok = $false }
            if ($ok) { return $true }
            Start-Sleep -Milliseconds 200
        }
        return $false
    }
    catch { return $false }
}

function Register-EnforceBound {
    param(
        [string]$TaskId, [string]$SessionId, $Child, $Budget, $StartedAt,
        [string]$FlagsPath, [string]$Repo, [string]$Role = 'coder'
    )
    [void](Wait-EnforceReady -Proc $Child -TimeoutMs 10000)
    $livePath = ''
    try { $livePath = ([string](Get-Process -Id ([int]$Child.Id) -ErrorAction Stop).Path).Trim() } catch { $livePath = '' }
    $st = $null
    try { $st = ([DateTime]$Child.StartTime) } catch { $st = $null }
    return (Register-OrchestrationWatchdogExecution -TaskId $TaskId -AttemptN 1 -SessionId $SessionId -Role $Role `
        -Budget $Budget -StartedAtUtc $StartedAt -FlagsPath $FlagsPath -RepoRoot $Repo `
        -ProcessId ([int]$Child.Id) -ProcessPath $livePath -ParentProcessId ([int]$PID) -ProcessStartTime $st)
}

function Get-EnforceTeleText {
    param([string]$TeleRoot)
    $acc = ''
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $TeleRoot -Filter 'watchdog-*.jsonl' -File -ErrorAction SilentlyContinue)) {
            $acc += ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8))
        }
    }
    catch { }
    return $acc
}

$v3 = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent (Split-Path -Parent $v3)
$repoPolicy = Join-Path $repo 'source\registry\execution-budget-policy.json'
$repoFlags = Join-Path $repo 'source\registry\capability-flags.json'
$oldWatchdogTests = Join-Path $PSScriptRoot 'OrchestrationRuntimeWatchdog.tests.ps1'

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('v3-watchdog-enf-' + [guid]::NewGuid().ToString('N'))
$teleRoot = Join-Path $tempRoot 'telemetry'
$flagsShadow = Join-Path $tempRoot 'flags-shadow.json'
$flagsEnforce = Join-Path $tempRoot 'flags-enforce.json'
$kernelFlags = Join-Path $tempRoot 'flags-kernel.json'
$kernelTasks = Join-Path $tempRoot 'kernel-tasks'
New-Item -ItemType Directory -Path $teleRoot -Force | Out-Null
New-Item -ItemType Directory -Path $kernelTasks -Force | Out-Null
Write-EnforceFixture -Path $flagsShadow -Text '{"watchdog":{"enabled":false,"shadow":true}}'
Write-EnforceFixture -Path $flagsEnforce -Text '{"watchdog":{"enabled":true,"shadow":false}}'
Write-EnforceFixture -Path $kernelFlags -Text '{"task_kernel":{"enabled":true,"shadow":false}}'

try {
    Clear-OrchestrationWatchdogState

    # Policy limits are read from the central file (no literals here).
    $lim = Get-WatchdogLoopLimits -PolicyPath $repoPolicy -RepoRoot $repo
    Assert-Enforce (([bool]$lim.ok) -and ([int]$lim.soft -eq 3) -and ([int]$lim.hard -eq 5) -and ([int]$lim.cycle -eq 3)) 'policy loop_guard soft=3 hard=5 cycle=3' (([string]$lim.soft + '/' + [string]$lim.hard + '/' + [string]$lim.cycle))

    # 1. hung worker => HARD_TIMEOUT => interrupt on a REAL child (REAL-deadline job, F-E).
    $hungBody = {
        param($Ctx)
        $ErrorActionPreference = 'Stop'
        $script:jpass = 0
        $script:jfail = 0
        $script:jlines = New-Object System.Collections.ArrayList
        function Assert-Job {
            param([bool]$C, [string]$N)
            if ($C) { $script:jpass = ([int]$script:jpass + 1); [void]$script:jlines.Add('[PASS] ' + $N) }
            else { $script:jfail = ([int]$script:jfail + 1); [void]$script:jlines.Add('[FAIL] ' + $N) }
        }
        $jkids = New-Object System.Collections.ArrayList
        try {
            . ([string]$Ctx['lib'])
            $shell = ([string]$Ctx['shell'])
            $flags = ([string]$Ctx['flags'])
            $repo = ([string]$Ctx['repo'])
            $tele = ([string]$Ctx['tele'])
            $c1 = Start-Process -FilePath $shell -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 120') -WindowStyle Hidden -PassThru
            [void]$jkids.Add($c1)
            $ready = $false
            $rsw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($rsw.Elapsed.TotalSeconds -lt 10) {
                try {
                    $rl = Get-Process -Id ([int]$c1.Id) -ErrorAction Stop
                    if (($null -ne $rl) -and (-not [string]::IsNullOrWhiteSpace([string]$rl.Path))) {
                        $null = ([DateTime]$rl.StartTime).ToUniversalTime()
                        $ready = $true
                        break
                    }
                }
                catch { }
                Start-Sleep -Milliseconds 200
            }
            $rsw.Stop()
            Assert-Job ($ready) 'hung child ready (path+start readable)'
            $livePath = ''
            try { $livePath = ([string](Get-Process -Id ([int]$c1.Id) -ErrorAction Stop).Path).Trim() } catch { $livePath = '' }
            $st = $null
            try { $st = ([DateTime]$c1.StartTime) } catch { $st = $null }
            $budget = [ordered]@{ profile = 'fast'; step_budget = 64; wall_clock_seconds = 30; no_progress_seconds = 25; repeated_action_soft_limit = 3; repeated_action_hard_limit = 5; cycle_repeat_limit = 3; provider_retry_limit = 2 }
            $r1 = Register-OrchestrationWatchdogExecution -TaskId 'wd-enf-1' -AttemptN 1 -SessionId 'wd-enf-sess-1' -Role 'coder' `
                -Budget $budget -StartedAtUtc ((Get-Date).ToUniversalTime().AddSeconds(-31)) -FlagsPath $flags -RepoRoot $repo `
                -ProcessId ([int]$c1.Id) -ProcessPath $livePath -ParentProcessId ([int]$PID) -ProcessStartTime $st
            Assert-Job (([bool]$r1.ok) -and ([bool]$r1.enforced)) 'hung register bound under ENFORCE'
            $e1 = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-enf-1' -FlagsPath $flags -RepoRoot $repo -TelemetryRoot $tele
            Assert-Job (([bool]$e1.ok) -and ([string]$e1.classification -ceq 'HARD_TIMEOUT') -and ([bool]$e1.interrupted)) 'hung worker HARD_TIMEOUT interrupted'
            $gone = $false
            $gsw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($gsw.Elapsed.TotalSeconds -lt 10) {
                try { $lp = Get-Process -Id ([int]$c1.Id) -ErrorAction Stop; if ($null -eq $lp) { $gone = $true; break } } catch { $gone = $true; break }
                Start-Sleep -Milliseconds 500
            }
            $gsw.Stop()
            Assert-Job ($gone) 'hung child process exited after interrupt'
            $acc = ''
            try {
                foreach ($f in @(Get-ChildItem -LiteralPath $tele -Filter 'watchdog-*.jsonl' -File -ErrorAction SilentlyContinue)) {
                    $acc += ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8))
                }
            }
            catch { }
            Assert-Job (($acc.Contains('"event":"WATCHDOG_INTERRUPTED"')) -and ($acc.Contains('"event":"WATCHDOG_SETTLED"')) -and ($acc.Contains('"source":"watchdog-enforce"'))) 'telemetry holds WATCHDOG_INTERRUPTED + WATCHDOG_SETTLED (enforce source)'
            Assert-Job ((([string]$e1.enforcement.telemetry_file) -ne '') -and (Test-Path -LiteralPath ([string]$e1.enforcement.telemetry_file) -PathType Leaf)) 'enforcement result references the telemetry FILE (not content)'
        }
        catch {
            $script:jfail = ([int]$script:jfail + 1)
            [void]$script:jlines.Add('[FAIL] hung job unexpected error')
        }
        finally {
            foreach ($k in @($jkids)) {
                try {
                    try { $k.Refresh() } catch { }
                    if (-not $k.HasExited) { Stop-Process -Id ([int]$k.Id) -Force -ErrorAction SilentlyContinue }
                }
                catch { }
            }
        }
        return @{ enforce_verdict = $true; passed = ([int]$script:jpass); failed = ([int]$script:jfail); lines = ([string[]]$script:jlines.ToArray()) }
    }
    $hungCtx = @{ lib = $libPath; tele = $teleRoot; flags = $flagsEnforce; repo = $repo; shell = (Get-EnforceShell) }
    $hungVerdict = Invoke-EnforceScenario -Name 'scenario-1-hung' -DeadlineSeconds 90 -Body $hungBody -Ctx $hungCtx
    Merge-EnforceScenario -Verdict $hungVerdict -Name 'scenario-1-hung'

    # 2. no-progress worker => NO_PROGRESS => interrupt (real child).
    $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
    $c2 = Start-EnforceChild -SleepSeconds 120
    $b2 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 2
    $t2now = (Get-Date).ToUniversalTime()
    $r2 = Register-EnforceBound -TaskId 'wd-enf-2' -SessionId 'wd-enf-sess-2' -Child $c2 -Budget $b2 -StartedAt $t2now -FlagsPath $flagsEnforce -Repo $repo
    Assert-Enforce ([bool]$r2.ok) 'no-progress register bound' ''
    $e2 = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-enf-2' -AtUtc ($t2now.AddSeconds(3)) -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-Enforce (([bool]$e2.ok) -and ([string]$e2.classification -ceq 'NO_PROGRESS') -and ([bool]$e2.interrupted)) 'silent worker NO_PROGRESS interrupted' ([string]$e2.classification)
    Assert-Enforce ((Wait-EnforceExit -Proc $c2 -TimeoutMs 8000) -and (-not (Test-EnforceAlive -Proc $c2))) 'no-progress child exited after interrupt' ''
    $sw2.Stop()
    Assert-Enforce (($sw2.Elapsed.TotalSeconds -lt 90)) 'scenario 2 externally bounded' ([string][int]$sw2.Elapsed.TotalSeconds + 's')

    # 3. soft 3 => STALL_SUSPECTED (no interrupt, child alive); hard 5 => interrupt.
    $sw3 = [System.Diagnostics.Stopwatch]::StartNew()
    $c3 = Start-EnforceChild -SleepSeconds 120
    $b3 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
    $t3 = (Get-Date).ToUniversalTime()
    $r3 = Register-EnforceBound -TaskId 'wd-enf-3' -SessionId 'wd-enf-sess-3' -Child $c3 -Budget $b3 -StartedAt $t3 -FlagsPath $flagsEnforce -Repo $repo
    Assert-Enforce ([bool]$r3.ok) 'repeated register bound' ''
    $a3 = $null
    for ($i = 0; $i -lt 3; $i++) {
        $a3 = Add-OrchestrationWatchdogAction -TaskId 'wd-enf-3' -AttemptN 1 -SessionId 'wd-enf-sess-3' -Tool 'shell' -Arguments 'git status --short' -Target 'repo' -HasProgress $false -AtUtc ($t3.AddSeconds(1 + $i)) -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
    }
    Assert-Enforce (([string]$a3.classification -ceq 'STALL_SUSPECTED') -and (-not [bool]$a3.interrupted) -and ($null -eq $a3.enforcement)) 'soft 3 identical => STALL_SUSPECTED, no interrupt' ([string]$a3.classification)
    Assert-Enforce (Test-EnforceAlive -Proc $c3) 'child alive after soft stall (not killed)' ''
    for ($i = 3; $i -lt 5; $i++) {
        $a3 = Add-OrchestrationWatchdogAction -TaskId 'wd-enf-3' -AttemptN 1 -SessionId 'wd-enf-sess-3' -Tool 'shell' -Arguments 'git status --short' -Target 'repo' -HasProgress $false -AtUtc ($t3.AddSeconds(1 + $i)) -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
    }
    Assert-Enforce (([string]$a3.classification -ceq 'REPEATED_ACTION') -and ([bool]$a3.interrupted)) 'hard 5 identical => REPEATED_ACTION interrupt' ([string]$a3.classification)
    Assert-Enforce ((Wait-EnforceExit -Proc $c3 -TimeoutMs 8000) -and (-not (Test-EnforceAlive -Proc $c3))) 'repeated-action child exited after interrupt' ''
    $sw3.Stop()
    Assert-Enforce (($sw3.Elapsed.TotalSeconds -lt 90)) 'scenario 3 externally bounded' ([string][int]$sw3.Elapsed.TotalSeconds + 's')

    # 4. A-B cycle length 2 repeated 3x => REPEATED_CYCLE interrupt.
    $sw4 = [System.Diagnostics.Stopwatch]::StartNew()
    $c4 = Start-EnforceChild -SleepSeconds 120
    $b4 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
    $t4 = (Get-Date).ToUniversalTime()
    $r4 = Register-EnforceBound -TaskId 'wd-enf-4' -SessionId 'wd-enf-sess-4' -Child $c4 -Budget $b4 -StartedAt $t4 -FlagsPath $flagsEnforce -Repo $repo
    Assert-Enforce ([bool]$r4.ok) 'cycle register bound' ''
    $a4 = $null
    $cycArgs = @('cycle-alpha', 'cycle-beta', 'cycle-alpha', 'cycle-beta', 'cycle-alpha', 'cycle-beta')
    for ($i = 0; $i -lt 6; $i++) {
        $a4 = Add-OrchestrationWatchdogAction -TaskId 'wd-enf-4' -AttemptN 1 -SessionId 'wd-enf-sess-4' -Tool 'shell' -Arguments $cycArgs[$i] -Target 'repo' -HasProgress $false -AtUtc ($t4.AddSeconds(1 + $i)) -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
    }
    Assert-Enforce (([string]$a4.classification -ceq 'REPEATED_CYCLE') -and ([bool]$a4.interrupted)) 'A-B x3 => REPEATED_CYCLE interrupt' ([string]$a4.classification)
    Assert-Enforce ((Wait-EnforceExit -Proc $c4 -TimeoutMs 8000) -and (-not (Test-EnforceAlive -Proc $c4))) 'cycle child exited after interrupt' ''
    $sw4.Stop()
    Assert-Enforce (($sw4.Elapsed.TotalSeconds -lt 90)) 'scenario 4 externally bounded' ([string][int]$sw4.Elapsed.TotalSeconds + 's')

    # 5. legitimate bounded iterator (budget + progress marker each step) is NOT killed.
    $sw5 = [System.Diagnostics.Stopwatch]::StartNew()
    $c5 = Start-EnforceChild -SleepSeconds 60
    $b5 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
    $t5 = (Get-Date).ToUniversalTime()
    $r5 = Register-EnforceBound -TaskId 'wd-enf-5' -SessionId 'wd-enf-sess-5' -Child $c5 -Budget $b5 -StartedAt $t5 -FlagsPath $flagsEnforce -Repo $repo
    Assert-Enforce ([bool]$r5.ok) 'iterator register bound' ''
    $a5 = $null
    for ($i = 0; $i -lt 12; $i++) {
        $a5 = Add-OrchestrationWatchdogAction -TaskId 'wd-enf-5' -AttemptN 1 -SessionId 'wd-enf-sess-5' -Tool 'shell' -Arguments ('iter item ' + [string]$i + ' of 12') -Target 'repo' -HasProgress $true -AtUtc ($t5.AddSeconds(1 + $i)) -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
    }
    Assert-Enforce (([string]$a5.classification -ceq 'NONE') -and (-not [bool]$a5.would_interrupt) -and (-not [bool]$a5.interrupted) -and ($null -eq $a5.enforcement)) 'bounded progressing iterator stays NONE, never interrupted' ([string]$a5.classification)
    Assert-Enforce (Test-EnforceAlive -Proc $c5) 'iterator child survives (not killed)' ''
    Stop-EnforceSafety -Proc $c5
    $sw5.Stop()
    Assert-Enforce (($sw5.Elapsed.TotalSeconds -lt 90)) 'scenario 5 externally bounded' ([string][int]$sw5.Elapsed.TotalSeconds + 's')

    # 6. no process identity under ENFORCE => advisory only, nothing killed.
    $sw6 = [System.Diagnostics.Stopwatch]::StartNew()
    $sentinel = Start-EnforceChild -SleepSeconds 60
    $b6 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
    $t6 = (Get-Date).ToUniversalTime()
    $r6 = Register-OrchestrationWatchdogExecution -TaskId 'wd-enf-6' -AttemptN 1 -SessionId 'wd-enf-sess-6' -Role 'coder' -Budget $b6 -StartedAtUtc $t6 -FlagsPath $flagsShadow -RepoRoot $repo
    Assert-Enforce ([bool]$r6.ok) 'identity-less register ok under SHADOW' ''
    $a6 = $null
    for ($i = 0; $i -lt 5; $i++) {
        $a6 = Add-OrchestrationWatchdogAction -TaskId 'wd-enf-6' -AttemptN 1 -SessionId 'wd-enf-sess-6' -Tool 'shell' -Arguments 'git status --short' -Target 'repo' -HasProgress $false -AtUtc ($t6.AddSeconds(1 + $i)) -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
    }
    Assert-Enforce (([bool]$a6.ok) -and ([string]$a6.classification -ceq 'REPEATED_ACTION') -and (-not [bool]$a6.interrupted) -and ([string]$a6.enforcement.reason -ceq 'WATCHDOG_NO_PROCESS_IDENTITY')) 'identity-less hard stall stays advisory under ENFORCE' ([string]$a6.enforcement.reason)
    Assert-Enforce (Test-EnforceAlive -Proc $sentinel) 'sentinel child untouched (no PID harmed)' ''
    $t6b = Get-EnforceTeleText -TeleRoot $teleRoot
    Assert-Enforce ($t6b.Contains('"event":"WATCHDOG_NO_PROCESS_IDENTITY"')) 'WATCHDOG_NO_PROCESS_IDENTITY recorded' ''
    $eHold = Register-OrchestrationWatchdogExecution -TaskId 'wd-enf-hold' -AttemptN 1 -SessionId 'wd-enf-sess-6' -Role 'coder' -FlagsPath $flagsEnforce -RepoRoot $repo
    Assert-Enforce ([string]$eHold.error -ceq 'WATCHDOG_ENFORCEMENT_NOT_IMPLEMENTED') 'unbound registration keeps the frozen P25 HOLD' ([string]$eHold.error)
    $eHoldLookup = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-enf-hold' -FlagsPath $flagsShadow -RepoRoot $repo
    Assert-Enforce ([string]$eHoldLookup.error -ceq 'NOT_REGISTERED') 'rejected HOLD registration stored nothing' ([string]$eHoldLookup.error)
    Stop-EnforceSafety -Proc $sentinel
    $sw6.Stop()
    Assert-Enforce (($sw6.Elapsed.TotalSeconds -lt 90)) 'scenario 6 externally bounded' ([string][int]$sw6.Elapsed.TotalSeconds + 's')

    # 7. successful interrupt: exit confirmed, settlement queryable.
    $sw7 = [System.Diagnostics.Stopwatch]::StartNew()
    $c7 = Start-EnforceChild -SleepSeconds 120
    $b7 = New-EnforceBudget -Steps 64 -Wall 30 -NoProg 25
    $r7 = Register-EnforceBound -TaskId 'wd-enf-7' -SessionId 'wd-enf-sess-7' -Child $c7 -Budget $b7 -StartedAt ((Get-Date).ToUniversalTime().AddSeconds(-31)) -FlagsPath $flagsEnforce -Repo $repo
    Assert-Enforce ([bool]$r7.ok) 'settlement register bound' ''
    $e7 = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-enf-7' -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-Enforce (([bool]$e7.interrupted) -and ([string]$e7.enforcement.settlement -ceq 'SETTLED')) 'interrupt settles SETTLED' ([string]$e7.enforcement.settlement)
    $s7 = Get-OrchestrationWatchdogSettlement -TaskId 'wd-enf-7' -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-Enforce (([bool]$s7.ok) -and ([bool]$s7.engaged) -and ([bool]$s7.interrupted) -and ([string]$s7.settlement -ceq 'SETTLED') -and ([string]$s7.classification -ceq 'HARD_TIMEOUT')) 'settlement queryable post-interrupt' ([string]$s7.settlement + '/' + [string]$s7.classification)
    Assert-Enforce ((Test-Path -LiteralPath ([string]$s7.telemetry_file) -PathType Leaf)) 'settlement references an existing telemetry file' ''
    $e7b = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-enf-7' -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot -IncludeEnforcement
    Assert-Enforce (([string]$e7b.settlement.settlement -ceq 'SETTLED')) 'Eval -IncludeEnforcement carries settlement' ''
    Assert-Enforce ((Wait-EnforceExit -Proc $c7 -TimeoutMs 8000) -and (-not (Test-EnforceAlive -Proc $c7))) 'settled child is gone' ''
    $sw7.Stop()
    Assert-Enforce (($sw7.Elapsed.TotalSeconds -lt 90)) 'scenario 7 externally bounded' ([string][int]$sw7.Elapsed.TotalSeconds + 's')

    # 8a. short-lived child exits alone before Stop => ALREADY_EXITED, no exception.
    $sw8 = [System.Diagnostics.Stopwatch]::StartNew()
    $c8 = Start-EnforceShortChild -SleepMs 300
    $b8 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
    $t8 = (Get-Date).ToUniversalTime()
    $r8 = Register-EnforceBound -TaskId 'wd-enf-8' -SessionId 'wd-enf-sess-8' -Child $c8 -Budget $b8 -StartedAt $t8 -FlagsPath $flagsEnforce -Repo $repo
    Assert-Enforce ([bool]$r8.ok) 'short-lived register bound' ''
    Start-Sleep -Milliseconds 4000
    Assert-Enforce (-not (Test-EnforceAlive -Proc $c8)) 'short child already gone on its own' ''
    $a8 = $null
    for ($i = 0; $i -lt 5; $i++) {
        $a8 = Add-OrchestrationWatchdogAction -TaskId 'wd-enf-8' -AttemptN 1 -SessionId 'wd-enf-sess-8' -Tool 'shell' -Arguments 'git status --short' -Target 'repo' -HasProgress $false -AtUtc ($t8.AddSeconds(2 + $i)) -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
    }
    Assert-Enforce (([bool]$a8.ok) -and (-not [bool]$a8.interrupted) -and ([string]$a8.enforcement.settlement -ceq 'ALREADY_EXITED')) 'exited-alone settles ALREADY_EXITED without exception' ([string]$a8.enforcement.settlement)
    $s8 = Get-OrchestrationWatchdogSettlement -TaskId 'wd-enf-8' -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-Enforce (([string]$s8.settlement -ceq 'ALREADY_EXITED')) 'ALREADY_EXITED queryable' ([string]$s8.settlement)

    # 8b. divergent ownership => REFUSED, process intact. A genuine own
    # child whose live parent IS the test process still passes the parent
    # leg; divergence is proven via executable-path and start-time legs.
    $c8b = Start-EnforceChild -SleepSeconds 60
    $livePath8 = ''
    try { $livePath8 = ([string](Get-Process -Id ([int]$c8b.Id) -ErrorAction Stop).Path).Trim() } catch { $livePath8 = '' }
    $liveStart8 = ''
    try { $liveStart8 = (([DateTime]$c8b.StartTime).ToUniversalTime().ToString('o')) } catch { $liveStart8 = '' }
    $otherExe = Join-Path ([string]$env:SystemRoot) 'System32\cmd.exe'
    $pathExec = @{ process = [ordered]@{ process_id = ([int]$c8b.Id); process_path = $otherExe; parent_process_id = ([int]$PID); process_start_time = $liveStart8 } }
    $own8 = Test-WatchdogProcessOwnership -Execution $pathExec
    Assert-Enforce (((-not [bool]$own8.owned)) -and ([string]$own8.reason -ceq 'WATCHDOG_INTERRUPT_REFUSED') -and ([string]$own8.detail -ceq 'path-mismatch')) 'divergent path => REFUSED, never killed' ([string]$own8.reason + '/' + [string]$own8.detail)
    Assert-Enforce (Test-EnforceAlive -Proc $c8b) 'refused child intact' ''
    $skewStart = ''
    try { $skewStart = ((([DateTime]$c8b.StartTime).ToUniversalTime().AddHours(1)).ToString('o')) } catch { $skewStart = '' }
    $timeExec = @{ process = [ordered]@{ process_id = ([int]$c8b.Id); process_path = $livePath8; parent_process_id = ([int]$PID); process_start_time = $skewStart } }
    $ownTime = Test-WatchdogProcessOwnership -Execution $timeExec
    Assert-Enforce (((-not [bool]$ownTime.owned)) -and ([string]$ownTime.reason -ceq 'WATCHDOG_INTERRUPT_REFUSED') -and ([string]$ownTime.detail -ceq 'start-time-mismatch')) 'reused-PID skew => REFUSED, never killed' ([string]$ownTime.reason + '/' + [string]$ownTime.detail)
    Assert-Enforce (Test-EnforceAlive -Proc $c8b) 'skew-refused child intact' ''
    $selfExec = @{ process = [ordered]@{ process_id = ([int]$PID); process_path = ''; parent_process_id = 0; process_start_time = '' } }
    $ownSelf = Test-WatchdogProcessOwnership -Execution $selfExec
    Assert-Enforce (((-not [bool]$ownSelf.owned)) -and ([string]$ownSelf.reason -ceq 'WATCHDOG_INTERRUPT_REFUSED')) 'own test process is never owned' ([string]$ownSelf.detail)
    $noIdExec = @{ task_id = 'wd-enf-8'; attempt_n = 1 }
    $ownNone = Test-WatchdogProcessOwnership -Execution $noIdExec
    Assert-Enforce (((-not [bool]$ownNone.owned)) -and ([string]$ownNone.reason -ceq 'WATCHDOG_NO_PROCESS_IDENTITY')) 'missing binding => NO_PROCESS_IDENTITY' ([string]$ownNone.reason)

    # 8c. stop on a dead PID maps to structured ALREADY_EXITED, never throws.
    $stopDead = Stop-WatchdogVerifiedProcess -ProcessId 999999001
    Assert-Enforce (([bool]$stopDead.ok) -and ([bool]$stopDead.already_exited)) 'dead-PID stop => structured ALREADY_EXITED' ''
    Stop-EnforceSafety -Proc $c8b
    $sw8.Stop()
    Assert-Enforce (($sw8.Elapsed.TotalSeconds -lt 90)) 'scenario 8 externally bounded' ([string][int]$sw8.Elapsed.TotalSeconds + 's')

    # 9. kernel seam: SETTLEMENT_REQUIRED blocks release/complete; settle releases.
    $sw9 = [System.Diagnostics.Stopwatch]::StartNew()
    $kc = New-OrchestrationTask -TaskId 'wd-seam-9' -Objective 'watchdog settlement seam probe' -TaskType 'implementation' -Risk 'low' `
        -Actor 'planner' -RuntimeId 'opencode-v1' -RuntimeGeneration 1 -RuntimeProfile 'v1' `
        -AcceptanceCriteria @('criterion:0:seam') -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-Enforce ([bool]$kc.ok) 'seam task created' ''
    $krev = [int]$kc.revision
    $kEng = Set-OrchestrationTaskWatchdogInterrupt -TaskId 'wd-seam-9' -AttemptN 1 -Class 'HARD_TIMEOUT' -Actor 'planner' `
        -ExpectedRevision $krev -TelemetryFile 'watchdog-20261001.jsonl' -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-Enforce (([bool]$kEng.ok) -and ([bool]$kEng.watchdog_engaged)) 'interrupt mark engaged' ''
    $krev = [int]$kEng.revision
    $kComp = Complete-OrchestrationTask -TaskId 'wd-seam-9' -Actor 'planner' -ExpectedRevision $krev -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-Enforce ([string]$kComp.error -ceq 'SETTLEMENT_REQUIRED') 'complete blocked before settlement' ([string]$kComp.error)
    $kCanc = Cancel-OrchestrationTask -TaskId 'wd-seam-9' -Actor 'planner' -ExpectedRevision $krev -Reason 'seam probe' -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-Enforce ([string]$kCanc.error -ceq 'SETTLEMENT_REQUIRED') 'cancel blocked before settlement' ([string]$kCanc.error)
    $kSet = Confirm-OrchestrationTaskWatchdogSettlement -TaskId 'wd-seam-9' -Actor 'planner' -ExpectedRevision $krev -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-Enforce (([bool]$kSet.ok) -and ([bool]$kSet.watchdog_settled)) 'settlement confirmed' ''
    $krev = [int]$kSet.revision
    $kSet2 = Confirm-OrchestrationTaskWatchdogSettlement -TaskId 'wd-seam-9' -Actor 'planner' -ExpectedRevision $krev -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-Enforce (([bool]$kSet2.ok) -and ([bool]$kSet2.noop)) 'settlement confirm idempotent' ''
    $kCanc2 = Cancel-OrchestrationTask -TaskId 'wd-seam-9' -Actor 'planner' -ExpectedRevision $krev -Reason 'seam probe' -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-Enforce (([bool]$kCanc2.ok) -and ([string]$kCanc2.state -ceq 'CANCELLED')) 'release works after settlement' ([string]$kCanc2.state)
    $kRec = Get-OrchestrationTask -TaskId 'wd-seam-9' -TasksDir $kernelTasks -RepoRoot $repo
    Assert-Enforce (([bool]$kRec['watchdog_interrupt']['settled'])) 'settlement persisted on the record' ''
    $kc2 = New-OrchestrationTask -TaskId 'wd-seam-9b' -Objective 'watchdog CLI probe' -TaskType 'implementation' -Risk 'low' `
        -Actor 'planner' -RuntimeId 'opencode-v1' -RuntimeGeneration 1 -RuntimeProfile 'v1' `
        -AcceptanceCriteria @('criterion:0:cli') -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-Enforce ([bool]$kc2.ok) 'CLI probe task created' ''
    $cliIntArgs = @('-Action', 'watchdog-interrupt', '-TaskId', 'wd-seam-9b', '-Actor', 'planner', `
        '-ExpectedRevision', ([string][int]$kc2.revision), '-WatchdogAttemptN', '1', '-WatchdogClass', 'NO_PROGRESS', `
        '-WatchdogTelemetryFile', 'watchdog-20261001.jsonl', '-ActorIdentitySource', 'explicit-cli', '-TasksDir', $kernelTasks, '-FlagsPath', $kernelFlags)
    $cliInt = Invoke-EnforceCliBounded -Exe 'powershell' -ScriptFile (Join-Path $v3 'task-kernel.ps1') -CliArgs $cliIntArgs -TimeoutSeconds 60
    $cliIntLive = $true
    if ([bool]$cliInt.timed_out) { $cliIntLive = $false }
    $cliIntOk = (([bool]$cliIntLive) -and ([int]$cliInt.exit -eq 0) -and ([string]$cliInt.out -match 'watchdog_engaged'))
    Assert-Enforce ($cliIntOk) 'CLI watchdog-interrupt wired under a real external deadline' ('exit=' + [string][int]$cliInt.exit)
    $midRev = ((([string]$cliInt.out | ConvertFrom-Json)).revision)
    $cliSettleArgs = @('-Action', 'watchdog-settle', '-TaskId', 'wd-seam-9b', '-Actor', 'planner', `
        '-ExpectedRevision', ([string][int]$midRev), '-ActorIdentitySource', 'explicit-cli', '-TasksDir', $kernelTasks, '-FlagsPath', $kernelFlags)
    $cliSettle = Invoke-EnforceCliBounded -Exe 'powershell' -ScriptFile (Join-Path $v3 'task-kernel.ps1') -CliArgs $cliSettleArgs -TimeoutSeconds 60
    Assert-Enforce (((-not [bool]$cliSettle.timed_out)) -and ([int]$cliSettle.exit -eq 0) -and ([string]$cliSettle.out -match 'watchdog_settled')) 'CLI watchdog-settle wired under a real external deadline' ('exit=' + [string][int]$cliSettle.exit)
    $sw9.Stop()
    Assert-Enforce (($sw9.Elapsed.TotalSeconds -lt 90)) 'scenario 9 externally bounded' ([string][int]$sw9.Elapsed.TotalSeconds + 's')

    # 10. sibling stays intact after a neighbor interrupt.
    $sw10 = [System.Diagnostics.Stopwatch]::StartNew()
    $cA = Start-EnforceChild -SleepSeconds 120
    $cB = Start-EnforceChild -SleepSeconds 120
    $bSib = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
    $tSib = (Get-Date).ToUniversalTime()
    $rA = Register-EnforceBound -TaskId 'wd-sib-a' -SessionId 'wd-sib-sess-a' -Child $cA -Budget $bSib -StartedAt $tSib -FlagsPath $flagsEnforce -Repo $repo
    $rB = Register-EnforceBound -TaskId 'wd-sib-b' -SessionId 'wd-sib-sess-b' -Child $cB -Budget $bSib -StartedAt $tSib -FlagsPath $flagsEnforce -Repo $repo
    Assert-Enforce (([bool]$rA.ok) -and ([bool]$rB.ok)) 'siblings registered' ''
    $aB = $null
    for ($i = 0; $i -lt 2; $i++) {
        $aB = Add-OrchestrationWatchdogAction -TaskId 'wd-sib-b' -AttemptN 1 -SessionId 'wd-sib-sess-b' -Tool 'shell' -Arguments ('sibling work ' + [string]$i) -Target 'repo' -HasProgress $true -AtUtc ($tSib.AddSeconds(1 + $i)) -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
    }
    $aA = $null
    for ($i = 0; $i -lt 5; $i++) {
        $aA = Add-OrchestrationWatchdogAction -TaskId 'wd-sib-a' -AttemptN 1 -SessionId 'wd-sib-sess-a' -Tool 'shell' -Arguments 'git status --short' -Target 'repo' -HasProgress $false -AtUtc ($tSib.AddSeconds(1 + $i)) -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
    }
    Assert-Enforce (([bool]$aA.interrupted) -and ([string]$aA.classification -ceq 'REPEATED_ACTION')) 'sibling A interrupted' ([string]$aA.classification)
    Assert-Enforce ((Wait-EnforceExit -Proc $cA -TimeoutMs 8000) -and (-not (Test-EnforceAlive -Proc $cA))) 'sibling A child gone' ''
    $sA = Get-OrchestrationWatchdogSettlement -TaskId 'wd-sib-a' -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-Enforce (([string]$sA.settlement -ceq 'SETTLED')) 'sibling A settled' ([string]$sA.settlement)
    $eB = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-sib-b' -AtUtc ($tSib.AddSeconds(10)) -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-Enforce (([bool]$eB.ok) -and ([string]$eB.classification -ceq 'NONE') -and (-not [bool]$eB.interrupted)) 'sibling B intact and healthy' ([string]$eB.classification)
    Assert-Enforce (Test-EnforceAlive -Proc $cB) 'sibling B child alive' ''
    $sB = Get-OrchestrationWatchdogSettlement -TaskId 'wd-sib-b' -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-Enforce (([bool]$sB.ok) -and (-not [bool]$sB.engaged) -and ([string]$sB.settlement -ceq 'NONE')) 'sibling B never engaged' ([string]$sB.settlement)
    Stop-EnforceSafety -Proc $cB
    $sw10.Stop()
    Assert-Enforce (($sw10.Elapsed.TotalSeconds -lt 90)) 'scenario 10 externally bounded' ([string][int]$sw10.Elapsed.TotalSeconds + 's')

    # 12. F1 exact creation-time identity (no tolerance window).
    $sw12 = [System.Diagnostics.Stopwatch]::StartNew()
    $c12 = Start-EnforceChild -SleepSeconds 120
    [void](Wait-EnforceReady -Proc $c12 -TimeoutMs 10000)
    $livePath12 = ''
    try { $livePath12 = ([string](Get-Process -Id ([int]$c12.Id) -ErrorAction Stop).Path).Trim() } catch { $livePath12 = '' }
    $liveStart12 = $null
    try { $liveStart12 = ([DateTime]$c12.StartTime).ToUniversalTime() } catch { $liveStart12 = $null }
    Assert-Enforce (($null -ne $liveStart12)) 'F1 live start time retrievable' ''
    $exactExec12 = @{ process = [ordered]@{ process_id = ([int]$c12.Id); process_path = $livePath12; parent_process_id = ([int]$PID); process_start_time = $liveStart12.ToString('o') } }
    $ownExact12 = Test-WatchdogProcessOwnership -Execution $exactExec12
    Assert-Enforce ([bool]$ownExact12.owned) 'F1 exact creation time => owned' ([string]$ownExact12.reason + '/' + [string]$ownExact12.detail)
    foreach ($skewSec in @(1, 6)) {
        $skewIso12 = ''
        try { $skewIso12 = ($liveStart12.AddSeconds([double]$skewSec)).ToString('o') } catch { $skewIso12 = '' }
        $skewExec12 = @{ process = [ordered]@{ process_id = ([int]$c12.Id); process_path = $livePath12; parent_process_id = ([int]$PID); process_start_time = $skewIso12 } }
        $ownSkew12 = Test-WatchdogProcessOwnership -Execution $skewExec12
        Assert-Enforce (((-not [bool]$ownSkew12.owned)) -and ([string]$ownSkew12.reason -ceq 'WATCHDOG_INTERRUPT_REFUSED') -and ([string]$ownSkew12.detail -ceq 'start-time-mismatch') -and (Test-EnforceAlive -Proc $c12)) ('F1 +' + [string]$skewSec + 's skew (inside the old 30s window) => REFUSED, child intact') ([string]$ownSkew12.detail)
    }
    $c12b = Start-EnforceChild -SleepSeconds 120
    $b12 = New-EnforceBudget -Steps 64 -Wall 30 -NoProg 25
    $r12 = Register-EnforceBound -TaskId 'wd-fix1-once' -SessionId 'wd-fix1-sess-once' -Child $c12b -Budget $b12 -StartedAt ((Get-Date).ToUniversalTime().AddSeconds(-31)) -FlagsPath $flagsEnforce -Repo $repo
    Assert-Enforce ([bool]$r12.ok) 'F1 single-resolution register bound' ''
    $preCount12 = Get-EnforceTreeSize -RootPid ([int]$c12b.Id)
    Assert-Enforce (([int]$preCount12 -ge 0)) 'F1 CIM-only tree pre-count readable' ('descendants=' + [string][int]$preCount12)
    $script:WatchdogLiveQueryCount = 0
    $e12 = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-fix1-once' -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-Enforce (([bool]$e12.interrupted) -and ([string]$e12.enforcement.settlement -ceq 'SETTLED')) 'F1 interrupt settles SETTLED' ([string]$e12.enforcement.settlement)
    Assert-Enforce ((Wait-EnforceExit -Proc $c12b -TimeoutMs 8000) -and (-not (Test-EnforceAlive -Proc $c12b))) 'F1 interrupted child is gone' ''
    Assert-Enforce (([int]$script:WatchdogLiveQueryCount -eq (1 + [int]$preCount12))) 'F1 one root resolution plus one per enumerated descendant; kill+wait reuse instances' ('queries=' + [string][int]$script:WatchdogLiveQueryCount)
    $c12d = Start-EnforceChild -SleepSeconds 120
    [void](Wait-EnforceReady -Proc $c12d -TimeoutMs 10000)
    $q12d = Get-WatchdogLiveProcess -ProcessId ([int]$c12d.Id)
    Assert-Enforce ([bool]$q12d.found) 'F1 direct unit live instance resolved' ''
    $script:WatchdogLiveQueryCount = 0
    $s12d = Stop-WatchdogVerifiedProcess -ProcessInstance $q12d.process
    Assert-Enforce (([bool]$s12d.ok) -and (-not [bool]$s12d.already_exited)) 'F1 direct instance stop ok' ''
    $w12d = Wait-WatchdogProcessTreeExit -Instances @($q12d.process) -TimeoutMs 5000
    Assert-Enforce ([bool]$w12d.exited) 'F1 direct instance wait confirms exit' ''
    Assert-Enforce (([int]$script:WatchdogLiveQueryCount -eq 0)) 'F1 instance stop+wait never re-resolve by PID' ('queries=' + [string][int]$script:WatchdogLiveQueryCount)
    Assert-Enforce (-not (Test-EnforceAlive -Proc $c12d)) 'F1 direct-stop child is gone' ''
    $c12c = Start-EnforceChild -SleepSeconds 120
    $b12c = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
    $t12c = (Get-Date).ToUniversalTime()
    $r12c = Register-EnforceBound -TaskId 'wd-fix1-stale' -SessionId 'wd-fix1-sess-stale' -Child $c12c -Budget $b12c -StartedAt $t12c -FlagsPath $flagsEnforce -Repo $repo
    Assert-Enforce ([bool]$r12c.ok) 'F1 stale-instance register bound' ''
    $exec12c = $script:WatchdogExecutions['wd-fix1-stale']
    $own12c = Test-WatchdogProcessOwnership -Execution $exec12c
    Assert-Enforce ([bool]$own12c.owned) 'F1 stale-instance ownership verified' ''
    Stop-Process -Id ([int]$c12c.Id) -Force -ErrorAction SilentlyContinue
    Assert-Enforce ((Wait-EnforceExit -Proc $c12c -TimeoutMs 8000) -and (-not (Test-EnforceAlive -Proc $c12c))) 'F1 child exited externally' ''
    $script:WatchdogLiveQueryCount = 0
    $staleStop12 = Stop-WatchdogVerifiedProcess -ProcessId ([int]$c12c.Id) -ProcessInstance $own12c.process
    Assert-Enforce (([bool]$staleStop12.ok) -and ([bool]$staleStop12.already_exited)) 'F1 stale verified instance => ALREADY_EXITED, no PID re-kill' ''
    Assert-Enforce (([int]$script:WatchdogLiveQueryCount -eq 0)) 'F-A stale fixed instance settles with zero new PID resolutions' ('queries=' + [string][int]$script:WatchdogLiveQueryCount)
    try { $own12c.process.Dispose() } catch { }
    Stop-EnforceSafety -Proc $c12
    $sw12.Stop()
    Assert-Enforce (($sw12.Elapsed.TotalSeconds -lt 90)) 'scenario 12 externally bounded' ([string][int]$sw12.Elapsed.TotalSeconds + 's')

    # 13. F2 CIM fail-closed: no declared value is ever proof.
    $sw13 = [System.Diagnostics.Stopwatch]::StartNew()
    $c13 = Start-EnforceChild -SleepSeconds 120
    [void](Wait-EnforceReady -Proc $c13 -TimeoutMs 10000)
    $livePath13 = ''
    try { $livePath13 = ([string](Get-Process -Id ([int]$c13.Id) -ErrorAction Stop).Path).Trim() } catch { $livePath13 = '' }
    $st13 = $null
    try { $st13 = ([DateTime]$c13.StartTime) } catch { $st13 = $null }
    $b13 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
    $t13 = (Get-Date).ToUniversalTime()
    $r13a = Register-OrchestrationWatchdogExecution -TaskId 'wd-fix1-cim' -AttemptN 1 -SessionId 'wd-fix1-sess-cim' -Role 'coder' `
        -Budget $b13 -StartedAtUtc $t13 -FlagsPath $flagsShadow -RepoRoot $repo `
        -ProcessId ([int]$c13.Id) -ProcessPath $livePath13 -ParentProcessId ([int]$PID) -ProcessStartTime $st13 -FaultInject 'cim_failure'
    Assert-Enforce ([bool]$r13a.ok) 'F2 cim_failure under SHADOW registers (unbound)' ([string]$r13a.error)
    Assert-Enforce ((($null -eq (Get-EnforceBoundProcess -TaskId 'wd-fix1-cim')))) 'F2 no process binding stored without CIM proof' ''
    $a13 = $null
    for ($i = 0; $i -lt 5; $i++) {
        $a13 = Add-OrchestrationWatchdogAction -TaskId 'wd-fix1-cim' -AttemptN 1 -SessionId 'wd-fix1-sess-cim' -Tool 'shell' -Arguments 'git status --short' -Target 'repo' -HasProgress $false -AtUtc ($t13.AddSeconds(1 + $i)) -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
    }
    Assert-Enforce (([bool]$a13.ok) -and (-not [bool]$a13.interrupted) -and ([string]$a13.enforcement.reason -ceq 'WATCHDOG_NO_PROCESS_IDENTITY')) 'F2 unbound execution stays advisory under ENFORCE' ([string]$a13.enforcement.reason)
    Assert-Enforce (Test-EnforceAlive -Proc $c13) 'F2 child untouched without proof' ''
    $r13b = Register-OrchestrationWatchdogExecution -TaskId 'wd-fix1-cim-hold' -AttemptN 1 -SessionId 'wd-fix1-sess-cim' -Role 'coder' `
        -Budget $b13 -StartedAtUtc $t13 -FlagsPath $flagsEnforce -RepoRoot $repo `
        -ProcessId ([int]$c13.Id) -ProcessPath $livePath13 -ParentProcessId ([int]$PID) -ProcessStartTime $st13 -FaultInject 'cim_failure'
    Assert-Enforce ([string]$r13b.error -ceq 'WATCHDOG_ENFORCEMENT_NOT_IMPLEMENTED') 'F2 cim_failure under ENFORCE keeps the P25 HOLD' ([string]$r13b.error)
    $e13b = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-fix1-cim-hold' -FlagsPath $flagsShadow -RepoRoot $repo
    Assert-Enforce ([string]$e13b.error -ceq 'NOT_REGISTERED') 'F2 HOLD registration stored nothing' ([string]$e13b.error)
    $c13c = Start-EnforceChild -SleepSeconds 120
    $r13c = Register-EnforceBound -TaskId 'wd-fix1-cimint' -SessionId 'wd-fix1-sess-cimint' -Child $c13c -Budget $b13 -StartedAt $t13 -FlagsPath $flagsEnforce -Repo $repo
    Assert-Enforce ([bool]$r13c.ok) 'F2 proven-binding register bound' ''
    $exec13c = $script:WatchdogExecutions['wd-fix1-cimint']
    $int13c = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix1-cimint' -Execution $exec13c -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo -FaultInject 'cim_failure'
    Assert-Enforce (([string]$int13c.error -ceq 'WATCHDOG_INTERRUPT_REFUSED') -and ([string]$int13c.detail -ceq 'parent-unverifiable')) 'F2 CIM failure at interrupt => REFUSED, declaration not trusted' ([string]$int13c.detail)
    Assert-Enforce (Test-EnforceAlive -Proc $c13c) 'F2 refused child intact' ''
    $s13c = Get-OrchestrationWatchdogSettlement -TaskId 'wd-fix1-cimint' -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-Enforce (([string]$s13c.settlement -ceq 'REFUSED')) 'F2 refusal queryable, never SETTLED' ([string]$s13c.settlement)
    Stop-EnforceSafety -Proc $c13c
    $c13d = Start-EnforceChild -SleepSeconds 60
    [void](Wait-EnforceReady -Proc $c13d -TimeoutMs 10000)
    $livePath13d = ''
    try { $livePath13d = ([string](Get-Process -Id ([int]$c13d.Id) -ErrorAction Stop).Path).Trim() } catch { $livePath13d = '' }
    $st13d = $null
    try { $st13d = ([DateTime]$c13d.StartTime) } catch { $st13d = $null }
    $r13d = Register-OrchestrationWatchdogExecution -TaskId 'wd-fix1-divp' -AttemptN 1 -SessionId 'wd-fix1-sess-divp' -Role 'coder' `
        -Budget $b13 -StartedAtUtc $t13 -FlagsPath $flagsShadow -RepoRoot $repo `
        -ProcessId ([int]$c13d.Id) -ProcessPath $livePath13d -ParentProcessId 4 -ProcessStartTime $st13d
    Assert-Enforce ([bool]$r13d.ok) 'F2 divergent declared parent registers (unbound)' ([string]$r13d.error)
    Assert-Enforce ((($null -eq (Get-EnforceBoundProcess -TaskId 'wd-fix1-divp')))) 'F2 divergent declaration never trusted as proof' ''
    Stop-EnforceSafety -Proc $c13d
    Stop-EnforceSafety -Proc $c13
    $sw13.Stop()
    Assert-Enforce (($sw13.Elapsed.TotalSeconds -lt 90)) 'scenario 13 externally bounded' ([string][int]$sw13.Elapsed.TotalSeconds + 's')

    # 14. F3 verified tree kill under a REAL external deadline (job).
    $treeBody = {
        param($Ctx)
        $ErrorActionPreference = 'Stop'
        $script:jpass = 0
        $script:jfail = 0
        $script:jlines = New-Object System.Collections.ArrayList
        function Assert-Job {
            param([bool]$C, [string]$N)
            if ($C) { $script:jpass = ([int]$script:jpass + 1); [void]$script:jlines.Add('[PASS] ' + $N) }
            else { $script:jfail = ([int]$script:jfail + 1); [void]$script:jlines.Add('[FAIL] ' + $N) }
        }
        function Find-JobChild {
            param([int]$ParentId, [string]$ExePath)
            try {
                $want = ([string]$ExePath).Trim()
                $enum = Get-WatchdogChildProcesses -ProcessId ([int]$ParentId)
                if (-not [bool]$enum.ok) { return 0 }
                foreach ($k in @($enum.children)) {
                    $kp = 0
                    try { $kp = [int]$k.process_id } catch { $kp = 0 }
                    if ($kp -lt 1) { continue }
                    $p = $null
                    try { $p = Get-Process -Id $kp -ErrorAction Stop } catch { $p = $null }
                    if ($null -eq $p) { continue }
                    $pp = ''
                    try { $pp = ([string]$p.Path).Trim() } catch { $pp = '' }
                    if ((-not [string]::IsNullOrWhiteSpace($pp)) -and ($pp -eq $want)) { return $kp }
                }
            }
            catch { }
            return 0
        }
        $root = $null
        $midPid = 0
        $netPid = 0
        $work = ''
        try {
            . ([string]$Ctx['lib'])
            $shell = ([string]$Ctx['shell'])
            $flags = ([string]$Ctx['flags'])
            $repo = ([string]$Ctx['repo'])
            $tele = ([string]$Ctx['tele'])
            $work = Join-Path ([IO.Path]::GetTempPath()) ('v3-wd-tree-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $work -Force | Out-Null
            $midScript = Join-Path $work 'tree-mid.ps1'
            [IO.File]::WriteAllText($midScript, ("Start-Process -FilePath '" + $shell + "' -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 120') -WindowStyle Hidden" + "`r`nStart-Sleep -Seconds 120`r`n"), [Text.UTF8Encoding]::new($false))
            $rootScript = Join-Path $work 'tree-root.ps1'
            [IO.File]::WriteAllText($rootScript, ("Start-Process -FilePath '" + $shell + "' -ArgumentList @('-NoProfile','-File','" + $midScript + "') -WindowStyle Hidden" + "`r`nStart-Sleep -Seconds 120`r`n"), [Text.UTF8Encoding]::new($false))
            $root = Start-Process -FilePath $shell -ArgumentList @('-NoProfile', '-File', $rootScript) -WindowStyle Hidden -PassThru
            $rsw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($rsw.Elapsed.TotalSeconds -lt 10) {
                $rready = $false
                try {
                    $rlive = Get-Process -Id ([int]$root.Id) -ErrorAction Stop
                    if (($null -ne $rlive) -and (-not [string]::IsNullOrWhiteSpace([string]$rlive.Path))) {
                        $null = ([DateTime]$rlive.StartTime).ToUniversalTime()
                        $rready = $true
                    }
                }
                catch { $rready = $false }
                if ($rready) { break }
                Start-Sleep -Milliseconds 200
            }
            $rsw.Stop()
            $formed = $false
            $fsw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($fsw.Elapsed.TotalSeconds -lt 20) {
                $midPid = Find-JobChild -ParentId ([int]$root.Id) -ExePath $shell
                if ([int]$midPid -gt 0) {
                    $netPid = Find-JobChild -ParentId ([int]$midPid) -ExePath $shell
                    if ([int]$netPid -gt 0) { $formed = $true; break }
                }
                Start-Sleep -Milliseconds 500
            }
            $fsw.Stop()
            Assert-Job ($formed) 'F3 three-level tree formed (root->mid->net)'
            $livePath = ''
            try { $livePath = ([string](Get-Process -Id ([int]$root.Id) -ErrorAction Stop).Path).Trim() } catch { $livePath = '' }
            $st = $null
            try { $st = ([DateTime]$root.StartTime) } catch { $st = $null }
            $budget = [ordered]@{ profile = 'fast'; step_budget = 64; wall_clock_seconds = 30; no_progress_seconds = 25; repeated_action_soft_limit = 3; repeated_action_hard_limit = 5; cycle_repeat_limit = 3; provider_retry_limit = 2 }
            $rr = Register-OrchestrationWatchdogExecution -TaskId 'wd-fix1-tree' -AttemptN 1 -SessionId 'wd-fix1-sess-tree' -Role 'coder' `
                -Budget $budget -StartedAtUtc ((Get-Date).ToUniversalTime().AddSeconds(-31)) -FlagsPath $flags -RepoRoot $repo `
                -ProcessId ([int]$root.Id) -ProcessPath $livePath -ParentProcessId ([int]$PID) -ProcessStartTime $st
            Assert-Job ([bool]$rr.ok) 'F3 tree root registered bound'
            $ev = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-fix1-tree' -FlagsPath $flags -RepoRoot $repo -TelemetryRoot $tele
            Assert-Job (([bool]$ev.ok) -and ([bool]$ev.interrupted) -and ([string]$ev.enforcement.settlement -ceq 'SETTLED')) 'F3 tree interrupt SETTLED'
            $allGone = $false
            $gsw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($gsw.Elapsed.TotalSeconds -lt 10) {
                $allGone = $true
                foreach ($p in @(([int]$root.Id), ([int]$midPid), ([int]$netPid))) {
                    if ($p -lt 1) { $allGone = $false; break }
                    try { $lp = Get-Process -Id $p -ErrorAction Stop; if ($null -ne $lp) { $allGone = $false; break } } catch { }
                }
                if ($allGone) { break }
                Start-Sleep -Milliseconds 500
            }
            $gsw.Stop()
            Assert-Job ($allGone) 'F3 root+mid+net all exited before SETTLED'
        }
        catch {
            $script:jfail = ([int]$script:jfail + 1)
            [void]$script:jlines.Add('[FAIL] F3 unexpected job error')
        }
        finally {
            foreach ($p in @($midPid, $netPid)) {
                try { if (([int]$p -gt 0) -and ([int]$p -ne [int]$PID)) { Stop-Process -Id ([int]$p) -Force -ErrorAction SilentlyContinue } } catch { }
            }
            if (($null -ne $root)) {
                try { $root.Refresh() } catch { }
                try { if (-not $root.HasExited) { Stop-Process -Id ([int]$root.Id) -Force -ErrorAction SilentlyContinue } } catch { }
            }
            try { if ((-not [string]::IsNullOrWhiteSpace($work)) -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
        }
        return @{ enforce_verdict = $true; passed = ([int]$script:jpass); failed = ([int]$script:jfail); lines = ([string[]]$script:jlines.ToArray()) }
    }
    $treeCtx = @{ lib = $libPath; tele = $teleRoot; flags = $flagsEnforce; repo = $repo; shell = (Get-EnforceShell) }
    $treeVerdict = Invoke-EnforceScenario -Name 'F3-tree' -DeadlineSeconds 90 -Body $treeBody -Ctx $treeCtx
    Merge-EnforceScenario -Verdict $treeVerdict -Name 'F3-tree'

    # 15. F3 fail-closed tree legs (REAL-deadline job, F-E).
    $fcBody = {
        param($Ctx)
        $ErrorActionPreference = 'Stop'
        $script:jpass = 0
        $script:jfail = 0
        $script:jlines = New-Object System.Collections.ArrayList
        function Assert-Job {
            param([bool]$C, [string]$N)
            if ($C) { $script:jpass = ([int]$script:jpass + 1); [void]$script:jlines.Add('[PASS] ' + $N) }
            else { $script:jfail = ([int]$script:jfail + 1); [void]$script:jlines.Add('[FAIL] ' + $N) }
        }
        function Find-JobChild2 {
            param([int]$ParentId, [string]$ExePath)
            try {
                $want = ([string]$ExePath).Trim()
                $enum = Get-WatchdogChildProcesses -ProcessId ([int]$ParentId)
                if (-not [bool]$enum.ok) { return 0 }
                foreach ($k in @($enum.children)) {
                    $kp = 0
                    try { $kp = [int]$k.process_id } catch { $kp = 0 }
                    if ($kp -lt 1) { continue }
                    $p = $null
                    try { $p = Get-Process -Id $kp -ErrorAction Stop } catch { $p = $null }
                    if ($null -eq $p) { continue }
                    $pp = ''
                    try { $pp = ([string]$p.Path).Trim() } catch { $pp = '' }
                    if ((-not [string]::IsNullOrWhiteSpace($pp)) -and ($pp -eq $want)) { return $kp }
                }
            }
            catch { }
            return 0
        }
        function Wait-JobReady2 {
            param($Proc, [int]$TimeoutMs = 10000)
            try {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                while ($sw.ElapsedMilliseconds -lt [long]$TimeoutMs) {
                    $ok = $false
                    try {
                        $live = Get-Process -Id ([int]$Proc.Id) -ErrorAction Stop
                        if (($null -ne $live) -and (-not [string]::IsNullOrWhiteSpace([string]$live.Path))) {
                            $null = ([DateTime]$live.StartTime).ToUniversalTime()
                            $ok = $true
                        }
                    }
                    catch { $ok = $false }
                    if ($ok) { return $true }
                    Start-Sleep -Milliseconds 200
                }
                return $false
            }
            catch { return $false }
        }
        $jkids = New-Object System.Collections.ArrayList
        $work = ''
        try {
            . ([string]$Ctx['lib'])
            $shell = ([string]$Ctx['shell'])
            $flags = ([string]$Ctx['flags'])
            $repo = ([string]$Ctx['repo'])
            $tele = ([string]$Ctx['tele'])
            $work = Join-Path ([IO.Path]::GetTempPath()) ('v3-wd-fc-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $work -Force | Out-Null
            $c15a = Start-Process -FilePath $shell -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 120') -WindowStyle Hidden -PassThru
            [void]$jkids.Add($c15a)
            [void](Wait-JobReady2 -Proc $c15a -TimeoutMs 10000)
            $lp15 = ''
            try { $lp15 = ([string](Get-Process -Id ([int]$c15a.Id) -ErrorAction Stop).Path).Trim() } catch { $lp15 = '' }
            $st15 = $null
            try { $st15 = ([DateTime]$c15a.StartTime) } catch { $st15 = $null }
            $b15 = [ordered]@{ profile = 'fast'; step_budget = 64; wall_clock_seconds = 1200; no_progress_seconds = 600; repeated_action_soft_limit = 3; repeated_action_hard_limit = 5; cycle_repeat_limit = 3; provider_retry_limit = 2 }
            $t15 = (Get-Date).ToUniversalTime()
            $r15a = Register-OrchestrationWatchdogExecution -TaskId 'wd-fix1-treefail' -AttemptN 1 -SessionId 'wd-fix1-sess-treefail' -Role 'coder' `
                -Budget $b15 -StartedAtUtc $t15 -FlagsPath $flags -RepoRoot $repo `
                -ProcessId ([int]$c15a.Id) -ProcessPath $lp15 -ParentProcessId ([int]$PID) -ProcessStartTime $st15
            Assert-Job ([bool]$r15a.ok) 'F3 enum-failure register bound'
            $exec15a = $script:WatchdogExecutions['wd-fix1-treefail']
            $int15a = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix1-treefail' -Execution $exec15a -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $tele -RepoRoot $repo -FaultInject 'tree_enum_failure'
            Assert-Job (([string]$int15a.error -ceq 'WATCHDOG_INTERRUPT_REFUSED') -and ([string]$int15a.detail -ceq 'tree-unverifiable')) 'F3 enum failure => REFUSED, nothing killed'
            $alive15 = $false
            try { $lp = Get-Process -Id ([int]$c15a.Id) -ErrorAction Stop; $alive15 = ($null -ne $lp) } catch { $alive15 = $false }
            Assert-Job ($alive15) 'F3 enum-failure root intact'
            $s15a = Get-OrchestrationWatchdogSettlement -TaskId 'wd-fix1-treefail' -FlagsPath $flags -RepoRoot $repo -TelemetryRoot $tele
            Assert-Job (([string]$s15a.settlement -ceq 'REFUSED')) 'F3 enum failure queryable, never SETTLED'
            $rootScript15 = Join-Path $work 'tree-pair.ps1'
            [IO.File]::WriteAllText($rootScript15, ("Start-Process -FilePath '" + $shell + "' -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 120') -WindowStyle Hidden`r`nStart-Sleep -Seconds 120`r`n"), [Text.UTF8Encoding]::new($false))
            $root15 = Start-Process -FilePath $shell -ArgumentList @('-NoProfile', '-File', $rootScript15) -WindowStyle Hidden -PassThru
            [void]$jkids.Add($root15)
            [void](Wait-JobReady2 -Proc $root15 -TimeoutMs 10000)
            $kidPid15 = 0
            $fsw15 = [System.Diagnostics.Stopwatch]::StartNew()
            while ($fsw15.Elapsed.TotalSeconds -lt 20) {
                $kidPid15 = Find-JobChild2 -ParentId ([int]$root15.Id) -ExePath $shell
                if ([int]$kidPid15 -gt 0) { break }
                Start-Sleep -Milliseconds 500
            }
            $fsw15.Stop()
            Assert-Job (([int]$kidPid15 -gt 0)) 'F3 two-level tree formed'
            $tree15a = Get-WatchdogVerifiedProcessTree -RootProcessId ([int]$root15.Id) -RootInstance $root15
            Assert-Job (([bool]$tree15a.ok) -and ((@($tree15a.descendants)).Count -ge 1)) 'F3 verifier includes live descendants on a proven tree'
            $tree15b = Get-WatchdogVerifiedProcessTree -RootProcessId ([int]$root15.Id) -RootInstance $root15 -FaultInject 'cim_failure'
            Assert-Job (((-not [bool]$tree15b.ok) -and ([string]$tree15b.reason -ceq 'descendant-unverifiable'))) 'F3 unprovable fresh parent links fail closed (nothing killed by this path)'
            $tree15c = Get-WatchdogVerifiedProcessTree -RootProcessId ([int]$root15.Id) -RootInstance $root15 -FaultInject 'tree_enum_failure'
            Assert-Job (((-not [bool]$tree15c.ok) -and ([string]$tree15c.reason -ceq 'tree-unverifiable'))) 'F3 enum failure fails closed at the verifier'
        }
        catch {
            $script:jfail = ([int]$script:jfail + 1)
            [void]$script:jlines.Add('[FAIL] F3 fail-closed job unexpected error')
        }
        finally {
            foreach ($k in @($jkids)) {
                try {
                    try { $k.Refresh() } catch { }
                    if ((-not $k.HasExited) -and ([int]$k.Id -ne [int]$PID)) { Stop-Process -Id ([int]$k.Id) -Force -ErrorAction SilentlyContinue }
                }
                catch { }
            }
            try { if ((-not [string]::IsNullOrWhiteSpace($work)) -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
        }
        return @{ enforce_verdict = $true; passed = ([int]$script:jpass); failed = ([int]$script:jfail); lines = ([string[]]$script:jlines.ToArray()) }
    }
    $fcCtx = @{ lib = $libPath; tele = $teleRoot; flags = $flagsEnforce; repo = $repo; shell = (Get-EnforceShell) }
    $fcVerdict = Invoke-EnforceScenario -Name 'scenario-15-failclosed' -DeadlineSeconds 90 -Body $fcBody -Ctx $fcCtx
    Merge-EnforceScenario -Verdict $fcVerdict -Name 'scenario-15-failclosed'

    # 16. F4 inspection failure is not absence.
    $sw16 = [System.Diagnostics.Stopwatch]::StartNew()
    $c16 = Start-EnforceChild -SleepSeconds 120
    $b16 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
    $t16 = (Get-Date).ToUniversalTime()
    $r16 = Register-EnforceBound -TaskId 'wd-fix1-query' -SessionId 'wd-fix1-sess-query' -Child $c16 -Budget $b16 -StartedAt $t16 -FlagsPath $flagsEnforce -Repo $repo
    Assert-Enforce ([bool]$r16.ok) 'F4 register bound' ''
    $q16 = Get-WatchdogLiveProcess -ProcessId ([int]$c16.Id) -FaultInject 'query_failure'
    Assert-Enforce ((([bool]$q16.inspection_failed) -and (-not [bool]$q16.found) -and (-not [bool]$q16.gone))) 'F4 injected query failure reads inspection_failed (never gone)' ''
    $q16b = Get-WatchdogLiveProcess -ProcessId 999999001
    Assert-Enforce ((([bool]$q16b.gone) -and (-not [bool]$q16b.found))) 'F4 dead PID still reads proven gone' ''
    $exec16 = $script:WatchdogExecutions['wd-fix1-query']
    $int16 = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix1-query' -Execution $exec16 -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo -FaultInject 'query_failure'
    Assert-Enforce ([string]$int16.error -ceq 'WATCHDOG_INTERRUPT_FAILED') 'F4 inspection failure => WATCHDOG_INTERRUPT_FAILED' ([string]$int16.error)
    Assert-Enforce (Test-EnforceAlive -Proc $c16) 'F4 child alive (nothing killed on unproven identity)' ''
    $s16 = Get-OrchestrationWatchdogSettlement -TaskId 'wd-fix1-query' -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-Enforce (([string]$s16.settlement -ceq 'PENDING')) 'F4 settlement PENDING, never SETTLED' ([string]$s16.settlement)
    Stop-EnforceSafety -Proc $c16
    $sw16.Stop()
    Assert-Enforce (($sw16.Elapsed.TotalSeconds -lt 90)) 'scenario 16 externally bounded' ([string][int]$sw16.Elapsed.TotalSeconds + 's')

    # 17. F5 stop failure + real-deadline proof.
    $sw17 = [System.Diagnostics.Stopwatch]::StartNew()
    $c17 = Start-EnforceChild -SleepSeconds 120
    $b17 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
    $t17 = (Get-Date).ToUniversalTime()
    $r17 = Register-EnforceBound -TaskId 'wd-fix1-stopfail' -SessionId 'wd-fix1-sess-stopfail' -Child $c17 -Budget $b17 -StartedAt $t17 -FlagsPath $flagsEnforce -Repo $repo
    Assert-Enforce ([bool]$r17.ok) 'F5 stop-failure register bound' ''
    $exec17 = $script:WatchdogExecutions['wd-fix1-stopfail']
    $int17 = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix1-stopfail' -Execution $exec17 -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo -FaultInject 'stop_failure'
    Assert-Enforce ([string]$int17.error -ceq 'WATCHDOG_INTERRUPT_FAILED') 'F5 injected stop refusal => WATCHDOG_INTERRUPT_FAILED' ([string]$int17.error)
    Assert-Enforce (Test-EnforceAlive -Proc $c17) 'F5 stop-failed child alive' ''
    $s17 = Get-OrchestrationWatchdogSettlement -TaskId 'wd-fix1-stopfail' -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-Enforce (([string]$s17.settlement -ceq 'FAILED')) 'F5 stop failure stored FAILED, never settled' ([string]$s17.settlement)
    $bad17 = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix1-stopfail' -Execution $exec17 -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo -FaultInject 'bogus_token'
    Assert-Enforce ([string]$bad17.error -ceq 'INVALID_FAULT_INJECT') 'F5 unknown inject token rejected closed' ([string]$bad17.error)
    Stop-EnforceSafety -Proc $c17
    $hangBody = {
        param($Ctx)
        Start-Sleep -Seconds 300
        return @{ enforce_verdict = $true; passed = 0; failed = 1; lines = @('[FAIL] hang body returned instead of being aborted') }
    }
    $hangVerdict = Invoke-EnforceScenario -Name 'F5-hang' -DeadlineSeconds 15 -Body $hangBody
    Assert-Enforce ([bool]$hangVerdict.timed_out) 'F5 deliberately hung scenario aborted by the real external deadline' ''
    $sw17.Stop()
    Assert-Enforce (($sw17.Elapsed.TotalSeconds -lt 90)) 'scenario 17 externally bounded' ([string][int]$sw17.Elapsed.TotalSeconds + 's')

    # 18. F6 terminal stickiness centralized at the settlement writer.
    $sw18 = [System.Diagnostics.Stopwatch]::StartNew()
    $c18 = Start-EnforceChild -SleepSeconds 120
    $b18 = New-EnforceBudget -Steps 64 -Wall 30 -NoProg 25
    $r18 = Register-EnforceBound -TaskId 'wd-fix1-sticky' -SessionId 'wd-fix1-sess-sticky' -Child $c18 -Budget $b18 -StartedAt ((Get-Date).ToUniversalTime().AddSeconds(-31)) -FlagsPath $flagsEnforce -Repo $repo
    Assert-Enforce ([bool]$r18.ok) 'F6 stickiness register bound' ''
    $e18 = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-fix1-sticky' -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-Enforce (([bool]$e18.interrupted) -and ([string]$e18.enforcement.settlement -ceq 'SETTLED') -and ([bool]$e18.enforcement.interrupted)) 'F6 first interrupt SETTLED with interrupted=true' ([string]$e18.enforcement.settlement)
    $e18b = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-fix1-sticky' -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-Enforce ((([bool]$e18b.enforcement.settled_before) -and ([string]$e18b.enforcement.settlement -ceq 'SETTLED') -and ([bool]$e18b.enforcement.interrupted))) 'F6 dispatcher repeat idempotent, interrupted preserved' ([string]$e18b.enforcement.settlement)
    $exec18 = $script:WatchdogExecutions['wd-fix1-sticky']
    $script:WatchdogLiveQueryCount = 0
    $d18 = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix1-sticky' -Execution $exec18 -Classification 'NO_PROGRESS' -ElapsedSeconds 5 -Steps 1 -TelemetryRoot $teleRoot -RepoRoot $repo
    Assert-Enforce ((([bool]$d18.ok) -and ([bool]$d18.settled_before) -and ([string]$d18.settlement -ceq 'SETTLED') -and ([bool]$d18.interrupted))) 'F6 direct repeat idempotent via ANY entry (no degradation)' ([string]$d18.settlement)
    Assert-Enforce (([int]$script:WatchdogLiveQueryCount -eq 0)) 'F6 direct repeat issues zero live queries' ('queries=' + [string][int]$script:WatchdogLiveQueryCount)
    Assert-Enforce ((Wait-EnforceExit -Proc $c18 -TimeoutMs 8000) -and (-not (Test-EnforceAlive -Proc $c18))) 'F6 settled child is gone' ''
    $c18c = Start-EnforceShortChild -SleepMs 300
    $b18c = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
    $t18c = (Get-Date).ToUniversalTime()
    $r18c = Register-EnforceBound -TaskId 'wd-fix1-alr' -SessionId 'wd-fix1-sess-alr' -Child $c18c -Budget $b18c -StartedAt $t18c -FlagsPath $flagsEnforce -Repo $repo
    Assert-Enforce ([bool]$r18c.ok) 'F6 ALREADY_EXITED register bound' ''
    Start-Sleep -Milliseconds 4000
    Assert-Enforce (-not (Test-EnforceAlive -Proc $c18c)) 'F6 short child already gone on its own' ''
    $exec18c = $script:WatchdogExecutions['wd-fix1-alr']
    $d18c = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix1-alr' -Execution $exec18c -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
    Assert-Enforce (([string]$d18c.settlement -ceq 'ALREADY_EXITED') -and (-not [bool]$d18c.interrupted)) 'F6 direct ALREADY_EXITED intact' ([string]$d18c.settlement)
    $d18c2 = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix1-alr' -Execution $exec18c -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
    Assert-Enforce ((([string]$d18c2.settlement -ceq 'ALREADY_EXITED') -and (-not [bool]$d18c2.interrupted) -and ([bool]$d18c2.settled_before))) 'F6 ALREADY_EXITED direct repeat intact' ([string]$d18c2.settlement)
    $sw18.Stop()
    Assert-Enforce (($sw18.Elapsed.TotalSeconds -lt 90)) 'scenario 18 externally bounded' ([string][int]$sw18.Elapsed.TotalSeconds + 's')

    # 19. F7 kernel fail-closed: every terminal route gated.
    $sw19 = [System.Diagnostics.Stopwatch]::StartNew()
    $k19 = New-OrchestrationTask -TaskId 'wd-fix1-trans' -Objective 'watchdog generic transition gate probe' -TaskType 'implementation' -Risk 'low' `
        -Actor 'planner' -RuntimeId 'opencode-v1' -RuntimeGeneration 1 -RuntimeProfile 'v1' `
        -AcceptanceCriteria @('criterion:0:gate') -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-Enforce ([bool]$k19.ok) 'F7 gate task created' ''
    $e19 = Set-OrchestrationTaskWatchdogInterrupt -TaskId 'wd-fix1-trans' -AttemptN 1 -Class 'HARD_TIMEOUT' -Actor 'planner' `
        -ExpectedRevision ([int]$k19.revision) -TelemetryFile 'watchdog-20261001.jsonl' -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-Enforce ([bool]$e19.ok) 'F7 interrupt mark engaged' ''
    $t19 = Invoke-OrchestrationTaskTransition -TaskId 'wd-fix1-trans' -ToState 'CANCELLED' -Actor 'planner' -ExpectedRevision ([int]$e19.revision) `
        -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-Enforce ([string]$t19.error -ceq 'SETTLEMENT_REQUIRED') 'F7 generic CANCELLED transition blocked while interrupt pending' ([string]$t19.error)
    $k19b = New-OrchestrationTask -TaskId 'wd-fix1-transex' -Objective 'watchdog generic exhaust gate probe' -TaskType 'implementation' -Risk 'low' `
        -Actor 'planner' -RuntimeId 'opencode-v1' -RuntimeGeneration 1 -RuntimeProfile 'v1' `
        -AcceptanceCriteria @('criterion:0:gate') -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-Enforce ([bool]$k19b.ok) 'F7 exhaust task created' ''
    $rev19b = [int]$k19b.revision
    foreach ($hop19 in @('PLANNING', 'IMPLEMENTING', 'VALIDATING', 'FIXING')) {
        $h19 = Invoke-OrchestrationTaskTransition -TaskId 'wd-fix1-transex' -ToState $hop19 -Actor 'planner' -ExpectedRevision $rev19b `
            -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
        $rev19b = [int]$h19.revision
    }
    Assert-Enforce (([int]$rev19b -gt [int]$k19b.revision)) 'F7 task walked to FIXING' ('rev=' + [string]$rev19b)
    $e19b = Set-OrchestrationTaskWatchdogInterrupt -TaskId 'wd-fix1-transex' -AttemptN 1 -Class 'NO_PROGRESS' -Actor 'planner' `
        -ExpectedRevision $rev19b -TelemetryFile 'watchdog-20261001.jsonl' -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-Enforce ([bool]$e19b.ok) 'F7 exhaust interrupt mark engaged' ''
    $t19b = Invoke-OrchestrationTaskTransition -TaskId 'wd-fix1-transex' -ToState 'EXHAUSTED' -Actor 'planner' -ExpectedRevision ([int]$e19b.revision) `
        -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-Enforce ([string]$t19b.error -ceq 'SETTLEMENT_REQUIRED') 'F7 generic EXHAUSTED transition blocked while interrupt pending' ([string]$t19b.error)
    $s19b = Confirm-OrchestrationTaskWatchdogSettlement -TaskId 'wd-fix1-transex' -Actor 'planner' -ExpectedRevision ([int]$e19b.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-Enforce ([bool]$s19b.ok) 'F7 exhaust settlement confirmed' ''
    $t19c = Invoke-OrchestrationTaskTransition -TaskId 'wd-fix1-transex' -ToState 'EXHAUSTED' -Actor 'planner' -ExpectedRevision ([int]$s19b.revision) `
        -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-Enforce (([bool]$t19c.ok) -and ([string]$t19c.to -ceq 'EXHAUSTED')) 'F7 EXHAUSTED released after settlement' ([string]$t19c.to)
    $s19 = Confirm-OrchestrationTaskWatchdogSettlement -TaskId 'wd-fix1-trans' -Actor 'planner' -ExpectedRevision ([int]$e19.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-Enforce ([bool]$s19.ok) 'F7 cancel settlement confirmed' ''
    $t19d = Invoke-OrchestrationTaskTransition -TaskId 'wd-fix1-trans' -ToState 'CANCELLED' -Actor 'planner' -ExpectedRevision ([int]$s19.revision) `
        -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-Enforce (([bool]$t19d.ok) -and ([string]$t19d.to -ceq 'CANCELLED')) 'F7 CANCELLED released after settlement' ([string]$t19d.to)
    $mCases19 = @(
        @{ name = 'null record'; rec = $null; want = $false },
        @{ name = 'string record'; rec = 'nope'; want = $false },
        @{ name = 'no node'; rec = @{}; want = $true },
        @{ name = 'null node'; rec = @{ watchdog_interrupt = $null }; want = $false },
        @{ name = 'string node'; rec = @{ watchdog_interrupt = 'engaged' }; want = $false },
        @{ name = 'empty node'; rec = @{ watchdog_interrupt = @{} }; want = $false },
        @{ name = 'non-bool engaged'; rec = @{ watchdog_interrupt = @{ engaged = 'yes' } }; want = $false },
        @{ name = 'engaged false'; rec = @{ watchdog_interrupt = @{ engaged = $false } }; want = $true },
        @{ name = 'engaged unsettled'; rec = @{ watchdog_interrupt = @{ engaged = $true; settled = $false } }; want = $false },
        @{ name = 'engaged no settled'; rec = @{ watchdog_interrupt = @{ engaged = $true } }; want = $false },
        @{ name = 'engaged settled string'; rec = @{ watchdog_interrupt = @{ engaged = $true; settled = 'yes' } }; want = $false },
        @{ name = 'engaged settled'; rec = @{ watchdog_interrupt = @{ engaged = $true; settled = $true } }; want = $true }
    )
    foreach ($mc19 in $mCases19) {
        $got19 = Test-TaskKernelWatchdogSettlementClear -Record $mc19.rec
        Assert-Enforce (([bool]$got19 -eq [bool]$mc19.want)) ('F7 helper fail-closed: ' + [string]$mc19.name) ('got=' + [string][bool]$got19)
    }
    $k19d = New-OrchestrationTask -TaskId 'wd-fix1-exhaust' -Objective 'watchdog auto-exhaust gate probe' -TaskType 'implementation' -Risk 'low' `
        -Actor 'planner' -RuntimeId 'opencode-v1' -RuntimeGeneration 1 -RuntimeProfile 'v1' -AttemptBudget 1 `
        -AcceptanceCriteria @('criterion:0:gate') -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-Enforce ([bool]$k19d.ok) 'F7 exhaust-gate task created' ''
    $e19d = Set-OrchestrationTaskWatchdogInterrupt -TaskId 'wd-fix1-exhaust' -AttemptN 1 -Class 'REPEATED_ACTION' -Actor 'planner' `
        -ExpectedRevision ([int]$k19d.revision) -TelemetryFile 'watchdog-20261001.jsonl' -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-Enforce ([bool]$e19d.ok) 'F7 exhaust-gate mark engaged' ''
    $wr19d = Set-OrchestrationTaskWorkerResult -TaskId 'wd-fix1-exhaust' -Status 'failed' -ProducedBy 'coder' -ExpectedRevision ([int]$e19d.revision) -Hypothesis 'fix1 probe' `
        -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-Enforce ([string]$wr19d.error -ceq 'SETTLEMENT_REQUIRED') 'F7 worker-result auto-exhaustion blocked while interrupt pending' ([string]$wr19d.error)
    $rec19d = Get-OrchestrationTask -TaskId 'wd-fix1-exhaust' -TasksDir $kernelTasks -RepoRoot $repo
    Assert-Enforce (([int]$rec19d['revision'] -eq [int]$e19d.revision)) 'F7 blocked exhaustion mutated nothing' ''
    $s19d = Confirm-OrchestrationTaskWatchdogSettlement -TaskId 'wd-fix1-exhaust' -Actor 'planner' -ExpectedRevision ([int]$e19d.revision) -ActorIdentitySource 'explicit-cli' -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-Enforce ([bool]$s19d.ok) 'F7 exhaust-gate settlement confirmed' ''
    $wr19d2 = Set-OrchestrationTaskWorkerResult -TaskId 'wd-fix1-exhaust' -Status 'failed' -ProducedBy 'coder' -ExpectedRevision ([int]$s19d.revision) -Hypothesis 'fix1 probe' `
        -TasksDir $kernelTasks -FlagsPath $kernelFlags -RepoRoot $repo
    Assert-Enforce (([bool]$wr19d2.ok) -and ([bool]$wr19d2.exhausted)) 'F7 exhaustion released after settlement' ''
    $sw19.Stop()
    Assert-Enforce (($sw19.Elapsed.TotalSeconds -lt 90)) 'scenario 19 externally bounded' ([string][int]$sw19.Elapsed.TotalSeconds + 's')

    # 20. F-A pinned handle on the fixed instance.
    $sw20 = [System.Diagnostics.Stopwatch]::StartNew()
    $c20 = Start-EnforceChild -SleepSeconds 120
    [void](Wait-EnforceReady -Proc $c20 -TimeoutMs 10000)
    $q20 = Get-WatchdogLiveProcess -ProcessId ([int]$c20.Id)
    Assert-Enforce ([bool]$q20.found) 'F-A live instance resolved through the choke point' ''
    $h20 = 0
    try { $h20 = ([long]$q20.process.Handle) } catch { $h20 = 0 }
    Assert-Enforce (($h20 -ne 0)) 'F-A fixed instance carries a pinned native handle (kill/wait target the instance, never the PID)' ''
    try { $q20.process.Dispose() } catch { }
    Stop-EnforceSafety -Proc $c20
    $sw20.Stop()
    Assert-Enforce (($sw20.Elapsed.TotalSeconds -lt 90)) 'scenario 20 externally bounded' ([string][int]$sw20.Elapsed.TotalSeconds + 's')

    # 21. F-B generation rule (pure, no processes) + F-C default caps.
    $sw21 = [System.Diagnostics.Stopwatch]::StartNew()
    $tol21 = 10000000
    try { $tol21 = ([long]$script:WatchdogTreeIdentityToleranceTicks) } catch { $tol21 = 10000000 }
    Assert-Enforce (([long]$tol21 -eq 10000000)) 'F-B identity tolerance band is one second' ('ticks=' + [string][long]$tol21)
    Assert-Enforce (([string](Test-WatchdogTreeGeneration -ChildCreationTicks 200 -AncestorCreationTicks 100) -ceq 'include')) 'F-B newer child => include' ''
    Assert-Enforce (([string](Test-WatchdogTreeGeneration -ChildCreationTicks 100 -AncestorCreationTicks 100) -ceq 'include')) 'F-B same-tick child => include' ''
    Assert-Enforce (([string](Test-WatchdogTreeGeneration -ChildCreationTicks 100 -AncestorCreationTicks ([long]100 + [long]$tol21 + 1)) -ceq 'excluded')) 'F-B clearly-older child => excluded (proof of non-descendence)' ''
    Assert-Enforce (([string](Test-WatchdogTreeGeneration -ChildCreationTicks 100 -AncestorCreationTicks ([long]100 + [long]$tol21)) -ceq 'ambiguous')) 'F-B band-edge older child => ambiguous (fail closed)' ''
    Assert-Enforce (([string](Test-WatchdogTreeGeneration -ChildCreationTicks 100 -AncestorCreationTicks 101) -ceq 'ambiguous')) 'F-B slightly-older child => ambiguous (fail closed)' ''
    Assert-Enforce (([int]$script:WatchdogTreeMaxDepth -eq 32) -and ([int]$script:WatchdogTreeMaxNodes -eq 64)) 'F-C default caps depth=32 nodes=64' ''
    $sw21.Stop()
    Assert-Enforce (($sw21.Elapsed.TotalSeconds -lt 90)) 'scenario 21 externally bounded' ([string][int]$sw21.Elapsed.TotalSeconds + 's')

    # 22. F-B PID-reuse orphan excluded, never killed (test-only
    # parent-link override; creations stay REAL through CIM).
    $sw22 = [System.Diagnostics.Stopwatch]::StartNew()
    $sentinel22 = Start-EnforceChild -SleepSeconds 120
    [void](Wait-EnforceReady -Proc $sentinel22 -TimeoutMs 10000)
    Start-Sleep -Seconds 4
    $root22 = Start-EnforceChild -SleepSeconds 120
    [void](Wait-EnforceReady -Proc $root22 -TimeoutMs 10000)
    $script:WatchdogTreeTestOverride = @{ extra_children = @{ ([int]$root22.Id) = @([int]$sentinel22.Id) }; parent_links = @{ ([int]$sentinel22.Id) = ([int]$root22.Id) } }
    try {
        $b22 = New-EnforceBudget -Steps 64 -Wall 30 -NoProg 25
        $r22 = Register-EnforceBound -TaskId 'wd-fix2-excl' -SessionId 'wd-fix2-sess-excl' -Child $root22 -Budget $b22 -StartedAt ((Get-Date).ToUniversalTime().AddSeconds(-31)) -FlagsPath $flagsEnforce -Repo $repo
        Assert-Enforce ([bool]$r22.ok) 'F-B exclusion register bound' ''
        $e22 = Get-OrchestrationWatchdogEvaluation -TaskId 'wd-fix2-excl' -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
        Assert-Enforce (([bool]$e22.ok) -and ([bool]$e22.interrupted) -and ([string]$e22.enforcement.settlement -ceq 'SETTLED')) 'F-B legitimate set settles while the orphan is excluded' ([string]$e22.enforcement.settlement)
        Assert-Enforce (([int]$e22.enforcement.tree_excluded -ge 1)) 'F-B exclusion counted in the result (never a failure)' ('excluded=' + [string][int]$e22.enforcement.tree_excluded)
        Assert-Enforce (([string]$e22.enforcement.exclusion -ceq 'WATCHDOG_TREE_EXCLUDED')) 'F-B exclusion carries the closed token' ([string]$e22.enforcement.exclusion)
        Assert-Enforce ((Wait-EnforceExit -Proc $root22 -TimeoutMs 8000) -and (-not (Test-EnforceAlive -Proc $root22))) 'F-B legitimate root is gone' ''
        Assert-Enforce (Test-EnforceAlive -Proc $sentinel22) 'F-B PID-reuse orphan survives (never killed)' ''
    }
    finally { $script:WatchdogTreeTestOverride = $null }
    Stop-EnforceSafety -Proc $sentinel22
    Stop-EnforceSafety -Proc $root22
    $sw22.Stop()
    Assert-Enforce (($sw22.Elapsed.TotalSeconds -lt 90)) 'scenario 22 externally bounded' ([string][int]$sw22.Elapsed.TotalSeconds + 's')

    # 23. F-C depth and node caps fail closed with WATCHDOG_TREE_LIMIT_EXCEEDED.
    $sw23 = [System.Diagnostics.Stopwatch]::StartNew()
    $saveDepth23 = [int]$script:WatchdogTreeMaxDepth
    $script:WatchdogTreeMaxDepth = 1
    try {
        $treeWork23 = Join-Path $tempRoot 'tree23'
        New-Item -ItemType Directory -Path $treeWork23 -Force | Out-Null
        $shell23 = Get-EnforceShell
        $rootScript23 = Join-Path $treeWork23 'tree-deep.ps1'
        Write-EnforceFixture -Path $rootScript23 -Text ("Start-Process -FilePath '" + $shell23 + "' -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 120') -WindowStyle Hidden`nStart-Sleep -Seconds 120`n")
        $root23 = Start-Process -FilePath $shell23 -ArgumentList @('-NoProfile', '-File', $rootScript23) -WindowStyle Hidden -PassThru
        [void]$script:enfChildren.Add($root23)
        [void](Wait-EnforceReady -Proc $root23 -TimeoutMs 10000)
        $kid23 = 0
        $fsw23 = [System.Diagnostics.Stopwatch]::StartNew()
        while ($fsw23.Elapsed.TotalSeconds -lt 20) {
            $kid23 = Find-EnforceChildByPath -ParentId ([int]$root23.Id) -ExePath $shell23
            if ([int]$kid23 -gt 0) { break }
            Start-Sleep -Milliseconds 500
        }
        $fsw23.Stop()
        Assert-Enforce (([int]$kid23 -gt 0)) 'F-C two-level chain formed (deeper than the lowered cap)' ''
        $b23 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
        $r23 = Register-EnforceBound -TaskId 'wd-fix2-cap' -SessionId 'wd-fix2-sess-cap' -Child $root23 -Budget $b23 -StartedAt (Get-Date).ToUniversalTime() -FlagsPath $flagsEnforce -Repo $repo
        Assert-Enforce ([bool]$r23.ok) 'F-C cap register bound' ''
        $exec23 = $script:WatchdogExecutions['wd-fix2-cap']
        $int23 = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix2-cap' -Execution $exec23 -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
        Assert-Enforce ([string]$int23.error -ceq 'WATCHDOG_TREE_LIMIT_EXCEEDED') 'F-C depth cap with frontier pending => LIMIT_EXCEEDED, nothing killed' ([string]$int23.error)
        Assert-Enforce (Test-EnforceAlive -Proc $root23) 'F-C capped root survives' ''
        $kidAlive23 = $false
        try { $kl23 = Get-Process -Id ([int]$kid23) -ErrorAction Stop; $kidAlive23 = ($null -ne $kl23) } catch { $kidAlive23 = $false }
        Assert-Enforce ($kidAlive23) 'F-C deep child survives (no settlement, no kill)' ''
        $s23 = Get-OrchestrationWatchdogSettlement -TaskId 'wd-fix2-cap' -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
        Assert-Enforce (([string]$s23.settlement -ceq 'REFUSED')) 'F-C cap breach stored REFUSED, never SETTLED' ([string]$s23.settlement)
        Stop-EnforceSafetyId -ProcessId ([int]$kid23)
        Stop-EnforceSafety -Proc $root23
    }
    finally { $script:WatchdogTreeMaxDepth = [int]$saveDepth23 }
    $saveNodes23 = [int]$script:WatchdogTreeMaxNodes
    $script:WatchdogTreeMaxNodes = 1
    try {
        $c23b = Start-EnforceChild -SleepSeconds 120
        $b23b = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
        $r23b = Register-EnforceBound -TaskId 'wd-fix2-capn' -SessionId 'wd-fix2-sess-capn' -Child $c23b -Budget $b23b -StartedAt (Get-Date).ToUniversalTime() -FlagsPath $flagsEnforce -Repo $repo
        Assert-Enforce ([bool]$r23b.ok) 'F-C node-cap register bound' ''
        $exec23b = $script:WatchdogExecutions['wd-fix2-capn']
        $int23b = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix2-capn' -Execution $exec23b -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
        Assert-Enforce ([string]$int23b.error -ceq 'WATCHDOG_TREE_LIMIT_EXCEEDED') 'F-C node cap with frontier pending => LIMIT_EXCEEDED, nothing killed' ([string]$int23b.error)
        Assert-Enforce (Test-EnforceAlive -Proc $c23b) 'F-C node-capped child survives' ''
        Stop-EnforceSafety -Proc $c23b
    }
    finally { $script:WatchdogTreeMaxNodes = [int]$saveNodes23 }
    $sw23.Stop()
    Assert-Enforce (($sw23.Elapsed.TotalSeconds -lt 90)) 'scenario 23 externally bounded' ([string][int]$sw23.Elapsed.TotalSeconds + 's')

    # 24. F-D root gone before stop: the verified set is still liquidated.
    $sw24 = [System.Diagnostics.Stopwatch]::StartNew()
    $treeWork24 = Join-Path $tempRoot 'tree24'
    New-Item -ItemType Directory -Path $treeWork24 -Force | Out-Null
    $shell24 = Get-EnforceShell
    $rootScript24 = Join-Path $treeWork24 'tree-flash.ps1'
    Write-EnforceFixture -Path $rootScript24 -Text ("Start-Process -FilePath '" + $shell24 + "' -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 120') -WindowStyle Hidden`nStart-Sleep -Seconds 6`n")
    $root24 = Start-Process -FilePath $shell24 -ArgumentList @('-NoProfile', '-File', $rootScript24) -WindowStyle Hidden -PassThru
    [void]$script:enfChildren.Add($root24)
    $kid24 = 0
    $fsw24 = [System.Diagnostics.Stopwatch]::StartNew()
    while ($fsw24.Elapsed.TotalSeconds -lt 20) {
        $kid24 = Find-EnforceChildByPath -ParentId ([int]$root24.Id) -ExePath $shell24
        if ([int]$kid24 -gt 0) { break }
        Start-Sleep -Milliseconds 500
    }
    $fsw24.Stop()
    Assert-Enforce (([int]$kid24 -gt 0)) 'F-D durable child formed under the short-lived root' ''
    $b24 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
    $r24 = Register-EnforceBound -TaskId 'wd-fix2-gone' -SessionId 'wd-fix2-sess-gone' -Child $root24 -Budget $b24 -StartedAt (Get-Date).ToUniversalTime() -FlagsPath $flagsEnforce -Repo $repo
    Assert-Enforce ([bool]$r24.ok) 'F-D gone-path register bound while the root is alive' ([string]$r24.error)
    $rootGone24 = $false
    $gsw24 = [System.Diagnostics.Stopwatch]::StartNew()
    while ($gsw24.Elapsed.TotalSeconds -lt 15) {
        try { $lr24 = Get-Process -Id ([int]$root24.Id) -ErrorAction Stop; if ($null -eq $lr24) { $rootGone24 = $true; break } } catch { $rootGone24 = $true; break }
        Start-Sleep -Milliseconds 500
    }
    $gsw24.Stop()
    Assert-Enforce ($rootGone24) 'F-D root exited on its own before the stop' ''
    $kidAlive24 = $false
    try { $lk24 = Get-Process -Id ([int]$kid24) -ErrorAction Stop; $kidAlive24 = ($null -ne $lk24) } catch { $kidAlive24 = $false }
    Assert-Enforce ($kidAlive24) 'F-D durable child outlives the root' ''
    $exec24 = $script:WatchdogExecutions['wd-fix2-gone']
    $int24 = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix2-gone' -Execution $exec24 -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
    Assert-Enforce (([bool]$int24.ok) -and ([string]$int24.settlement -ceq 'ALREADY_EXITED')) 'F-D verified set liquidated, ALREADY_EXITED only after the whole set exits' ([string]$int24.settlement)
    $kidGone24 = $false
    $ksw24 = [System.Diagnostics.Stopwatch]::StartNew()
    while ($ksw24.Elapsed.TotalSeconds -lt 10) {
        try { $ck24 = Get-Process -Id ([int]$kid24) -ErrorAction Stop; if ($null -eq $ck24) { $kidGone24 = $true; break } } catch { $kidGone24 = $true; break }
        Start-Sleep -Milliseconds 500
    }
    $ksw24.Stop()
    Assert-Enforce ($kidGone24) 'F-D verified descendant was liquidated (not abandoned)' ''
    $s24 = Get-OrchestrationWatchdogSettlement -TaskId 'wd-fix2-gone' -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-Enforce (([string]$s24.settlement -ceq 'ALREADY_EXITED')) 'F-D gone-path settlement queryable' ([string]$s24.settlement)
    Stop-EnforceSafetyId -ProcessId ([int]$kid24)
    Stop-EnforceSafety -Proc $root24
    $sw24.Stop()
    Assert-Enforce (($sw24.Elapsed.TotalSeconds -lt 90)) 'scenario 24 externally bounded' ([string][int]$sw24.Elapsed.TotalSeconds + 's')

    # 25. F-D prior STILL_RUNNING with the root gone: descendants still processed.
    $sw25 = [System.Diagnostics.Stopwatch]::StartNew()
    $treeWork25 = Join-Path $tempRoot 'tree25'
    New-Item -ItemType Directory -Path $treeWork25 -Force | Out-Null
    $shell25 = Get-EnforceShell
    $rootScript25 = Join-Path $treeWork25 'tree-pair25.ps1'
    Write-EnforceFixture -Path $rootScript25 -Text ("Start-Process -FilePath '" + $shell25 + "' -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 120') -WindowStyle Hidden`nStart-Sleep -Seconds 120`n")
    $root25 = Start-Process -FilePath $shell25 -ArgumentList @('-NoProfile', '-File', $rootScript25) -WindowStyle Hidden -PassThru
    [void]$script:enfChildren.Add($root25)
    [void](Wait-EnforceReady -Proc $root25 -TimeoutMs 10000)
    $kid25 = 0
    $fsw25 = [System.Diagnostics.Stopwatch]::StartNew()
    while ($fsw25.Elapsed.TotalSeconds -lt 20) {
        $kid25 = Find-EnforceChildByPath -ParentId ([int]$root25.Id) -ExePath $shell25
        if ([int]$kid25 -gt 0) { break }
        Start-Sleep -Milliseconds 500
    }
    $fsw25.Stop()
    Assert-Enforce (([int]$kid25 -gt 0)) 'F-D second tree formed' ''
    $b25 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
    $r25 = Register-EnforceBound -TaskId 'wd-fix2-still' -SessionId 'wd-fix2-sess-still' -Child $root25 -Budget $b25 -StartedAt (Get-Date).ToUniversalTime() -FlagsPath $flagsEnforce -Repo $repo
    Assert-Enforce ([bool]$r25.ok) 'F-D still-path register bound' ''
    Stop-Process -Id ([int]$root25.Id) -Force -ErrorAction SilentlyContinue
    $rootGone25 = $false
    $gsw25 = [System.Diagnostics.Stopwatch]::StartNew()
    while ($gsw25.Elapsed.TotalSeconds -lt 10) {
        try { $lr25 = Get-Process -Id ([int]$root25.Id) -ErrorAction Stop; if ($null -eq $lr25) { $rootGone25 = $true; break } } catch { $rootGone25 = $true; break }
        Start-Sleep -Milliseconds 500
    }
    $gsw25.Stop()
    Assert-Enforce ($rootGone25) 'F-D root killed externally, child orphaned' ''
    $exec25 = $script:WatchdogExecutions['wd-fix2-still']
    $exec25['enforcement'] = @{ engaged = $true; interrupted = $true; settlement = 'STILL_RUNNING'; classification = 'HARD_TIMEOUT'; telemetry_file = 'watchdog-20261001.jsonl'; telemetry_written = $false }
    $int25 = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix2-still' -Execution $exec25 -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
    Assert-Enforce (([bool]$int25.ok) -and ([string]$int25.settlement -ceq 'ALREADY_EXITED')) 'F-D STILL_RUNNING is non-terminal: orphaned set processed, ALREADY_EXITED' ([string]$int25.settlement)
    $kidGone25 = $false
    $ksw25 = [System.Diagnostics.Stopwatch]::StartNew()
    while ($ksw25.Elapsed.TotalSeconds -lt 10) {
        try { $ck25 = Get-Process -Id ([int]$kid25) -ErrorAction Stop; if ($null -eq $ck25) { $kidGone25 = $true; break } } catch { $kidGone25 = $true; break }
        Start-Sleep -Milliseconds 500
    }
    $ksw25.Stop()
    Assert-Enforce ($kidGone25) 'F-D orphaned descendant was liquidated (not abandoned)' ''
    Stop-EnforceSafetyId -ProcessId ([int]$kid25)
    Stop-EnforceSafety -Proc $root25
    $sw25.Stop()
    Assert-Enforce (($sw25.Elapsed.TotalSeconds -lt 90)) 'scenario 25 externally bounded' ([string][int]$sw25.Elapsed.TotalSeconds + 's')

    # 26. F-E shared preparation deadline: an expired deadline REFUSES, never settles.
    $sw26 = [System.Diagnostics.Stopwatch]::StartNew()
    $saveWait26 = [int]$script:WatchdogSettleWaitMs
    $script:WatchdogSettleWaitMs = 0
    try {
        $c26 = Start-EnforceChild -SleepSeconds 120
        $b26 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
        $r26 = Register-EnforceBound -TaskId 'wd-fix2-deadline' -SessionId 'wd-fix2-sess-deadline' -Child $c26 -Budget $b26 -StartedAt (Get-Date).ToUniversalTime() -FlagsPath $flagsEnforce -Repo $repo
        Assert-Enforce ([bool]$r26.ok) 'F-E deadline register bound' ''
        $exec26 = $script:WatchdogExecutions['wd-fix2-deadline']
        $int26 = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix2-deadline' -Execution $exec26 -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
        Assert-Enforce (([string]$int26.error -ceq 'WATCHDOG_DEADLINE_EXCEEDED') -and ([string]$int26.detail -ceq 'tree-deadline-exceeded')) 'F-E expired preparation deadline => DEADLINE_EXCEEDED, never settled' ([string]$int26.detail)
        Assert-Enforce (Test-EnforceAlive -Proc $c26) 'F-E deadline-refused child alive (nothing killed)' ''
        $s26 = Get-OrchestrationWatchdogSettlement -TaskId 'wd-fix2-deadline' -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
        Assert-Enforce (([string]$s26.settlement -ceq 'REFUSED')) 'F-E deadline breach stored REFUSED, never SETTLED' ([string]$s26.settlement)
        Stop-EnforceSafety -Proc $c26
    }
    finally { $script:WatchdogSettleWaitMs = [int]$saveWait26 }
    $sw26.Stop()
    Assert-Enforce (($sw26.Elapsed.TotalSeconds -lt 90)) 'scenario 26 externally bounded' ([string][int]$sw26.Elapsed.TotalSeconds + 's')

    # 27. FIX3-1 deadline expiring DURING the last enumeration (empty result).
    $sw27 = [System.Diagnostics.Stopwatch]::StartNew()
    $saveWait27 = [int]$script:WatchdogSettleWaitMs
    $script:WatchdogSettleWaitMs = 2000
    $script:WatchdogTreeTestOverride = @{ enum_delay_ms = 4000 }
    try {
        $c27 = Start-EnforceChild -SleepSeconds 120
        $b27 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
        $r27 = Register-EnforceBound -TaskId 'wd-fix3-late' -SessionId 'wd-fix3-sess-late' -Child $c27 -Budget $b27 -StartedAt (Get-Date).ToUniversalTime() -FlagsPath $flagsEnforce -Repo $repo
        Assert-Enforce ([bool]$r27.ok) 'FIX3-1 late-deadline register bound' ''
        $exec27 = $script:WatchdogExecutions['wd-fix3-late']
        $int27 = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix3-late' -Execution $exec27 -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
        Assert-Enforce (([string]$int27.error -ceq 'WATCHDOG_DEADLINE_EXCEEDED') -and ([string]$int27.detail -ceq 'tree-deadline-exceeded')) 'FIX3-1 breach during the last (empty) enumeration => DEADLINE_EXCEEDED, no kill authorized' ([string]$int27.detail)
        Assert-Enforce (Test-EnforceAlive -Proc $c27) 'FIX3-1 late-breach child alive (nothing killed)' ''
        $s27 = Get-OrchestrationWatchdogSettlement -TaskId 'wd-fix3-late' -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
        Assert-Enforce (([string]$s27.settlement -ceq 'REFUSED')) 'FIX3-1 late breach stored REFUSED, never SETTLED' ([string]$s27.settlement)
        Stop-EnforceSafety -Proc $c27
    }
    finally { $script:WatchdogTreeTestOverride = $null; $script:WatchdogSettleWaitMs = [int]$saveWait27 }
    $sw27.Stop()
    Assert-Enforce (($sw27.Elapsed.TotalSeconds -lt 90)) 'scenario 27 externally bounded' ([string][int]$sw27.Elapsed.TotalSeconds + 's')

    # 28. FIX3-1 pre-kill gate: deadline expiring between a passed preparation and the kill.
    $sw28 = [System.Diagnostics.Stopwatch]::StartNew()
    $saveWait28 = [int]$script:WatchdogSettleWaitMs
    $script:WatchdogSettleWaitMs = 1500
    $script:WatchdogTreeTestOverride = @{ pre_kill_delay_ms = 2500 }
    try {
        $c28 = Start-EnforceChild -SleepSeconds 120
        $b28 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
        $r28 = Register-EnforceBound -TaskId 'wd-fix3-gate' -SessionId 'wd-fix3-sess-gate' -Child $c28 -Budget $b28 -StartedAt (Get-Date).ToUniversalTime() -FlagsPath $flagsEnforce -Repo $repo
        Assert-Enforce ([bool]$r28.ok) 'FIX3-1 gate register bound' ''
        $exec28 = $script:WatchdogExecutions['wd-fix3-gate']
        $int28 = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix3-gate' -Execution $exec28 -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
        Assert-Enforce (([string]$int28.error -ceq 'WATCHDOG_DEADLINE_EXCEEDED') -and ([string]$int28.detail -ceq 'tree-deadline-exceeded')) 'FIX3-1 pre-kill gate refuses an expired preparation, nothing killed' ([string]$int28.detail)
        Assert-Enforce (Test-EnforceAlive -Proc $c28) 'FIX3-1 gate-refused child alive' ''
        $s28 = Get-OrchestrationWatchdogSettlement -TaskId 'wd-fix3-gate' -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
        Assert-Enforce (([string]$s28.settlement -ceq 'REFUSED')) 'FIX3-1 gate breach stored REFUSED, never SETTLED' ([string]$s28.settlement)
        Stop-EnforceSafety -Proc $c28
    }
    finally { $script:WatchdogTreeTestOverride = $null; $script:WatchdogSettleWaitMs = [int]$saveWait28 }
    $sw28.Stop()
    Assert-Enforce (($sw28.Elapsed.TotalSeconds -lt 90)) 'scenario 28 externally bounded' ([string][int]$sw28.Elapsed.TotalSeconds + 's')

    # 29. FIX3-1 pre-kill gate on the gone path.
    $sw29 = [System.Diagnostics.Stopwatch]::StartNew()
    $treeWork29 = Join-Path $tempRoot 'tree29'
    New-Item -ItemType Directory -Path $treeWork29 -Force | Out-Null
    $shell29 = Get-EnforceShell
    $rootScript29 = Join-Path $treeWork29 'tree-flash29.ps1'
    Write-EnforceFixture -Path $rootScript29 -Text ("Start-Process -FilePath '" + $shell29 + "' -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 120') -WindowStyle Hidden`nStart-Sleep -Seconds 6`n")
    $root29 = Start-Process -FilePath $shell29 -ArgumentList @('-NoProfile', '-File', $rootScript29) -WindowStyle Hidden -PassThru
    [void]$script:enfChildren.Add($root29)
    $kid29 = 0
    $fsw29 = [System.Diagnostics.Stopwatch]::StartNew()
    while ($fsw29.Elapsed.TotalSeconds -lt 20) {
        $kid29 = Find-EnforceChildByPath -ParentId ([int]$root29.Id) -ExePath $shell29
        if ([int]$kid29 -gt 0) { break }
        Start-Sleep -Milliseconds 500
    }
    $fsw29.Stop()
    Assert-Enforce (([int]$kid29 -gt 0)) 'FIX3-1 gone-gate tree formed' ''
    $b29 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
    $r29 = Register-EnforceBound -TaskId 'wd-fix3-gonegate' -SessionId 'wd-fix3-sess-gonegate' -Child $root29 -Budget $b29 -StartedAt (Get-Date).ToUniversalTime() -FlagsPath $flagsEnforce -Repo $repo
    Assert-Enforce ([bool]$r29.ok) 'FIX3-1 gone-gate register bound' ([string]$r29.error)
    $rootGone29 = $false
    $gsw29 = [System.Diagnostics.Stopwatch]::StartNew()
    while ($gsw29.Elapsed.TotalSeconds -lt 15) {
        try { $lr29 = Get-Process -Id ([int]$root29.Id) -ErrorAction Stop; if ($null -eq $lr29) { $rootGone29 = $true; break } } catch { $rootGone29 = $true; break }
        Start-Sleep -Milliseconds 500
    }
    $gsw29.Stop()
    Assert-Enforce ($rootGone29) 'FIX3-1 gone-gate root exited on its own' ''
    $script:WatchdogTreeTestOverride = @{ pre_kill_delay_ms = 4000 }
    try {
        $exec29 = $script:WatchdogExecutions['wd-fix3-gonegate']
        $int29 = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix3-gonegate' -Execution $exec29 -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
        Assert-Enforce ([string]$int29.error -ceq 'WATCHDOG_DEADLINE_EXCEEDED') 'FIX3-1 gone-path gate refuses an expired preparation, nothing killed' ([string]$int29.error)
        $kidAlive29 = $false
        try { $lk29 = Get-Process -Id ([int]$kid29) -ErrorAction Stop; $kidAlive29 = ($null -ne $lk29) } catch { $kidAlive29 = $false }
        Assert-Enforce ($kidAlive29) 'FIX3-1 gone-gate descendant alive (never touched)' ''
        $s29 = Get-OrchestrationWatchdogSettlement -TaskId 'wd-fix3-gonegate' -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
        Assert-Enforce (([string]$s29.settlement -ceq 'REFUSED')) 'FIX3-1 gone-gate breach stored REFUSED, never SETTLED' ([string]$s29.settlement)
    }
    finally { $script:WatchdogTreeTestOverride = $null }
    Stop-EnforceSafetyId -ProcessId ([int]$kid29)
    Stop-EnforceSafety -Proc $root29
    $sw29.Stop()
    Assert-Enforce (($sw29.Elapsed.TotalSeconds -lt 90)) 'scenario 29 externally bounded' ([string][int]$sw29.Elapsed.TotalSeconds + 's')

    # 30. FIX3-2 gone-path: a child born after lastAliveProof is EXCLUDED, never killed.
    $sw30 = [System.Diagnostics.Stopwatch]::StartNew()
    $treeWork30 = Join-Path $tempRoot 'tree30'
    New-Item -ItemType Directory -Path $treeWork30 -Force | Out-Null
    $shell30 = Get-EnforceShell
    $rootScript30 = Join-Path $treeWork30 'tree-late30.ps1'
    Write-EnforceFixture -Path $rootScript30 -Text ("Start-Sleep -Seconds 4`nStart-Process -FilePath '" + $shell30 + "' -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 120') -WindowStyle Hidden`nStart-Sleep -Seconds 120`n")
    $root30 = Start-Process -FilePath $shell30 -ArgumentList @('-NoProfile', '-File', $rootScript30) -WindowStyle Hidden -PassThru
    [void]$script:enfChildren.Add($root30)
    $b30 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
    $r30 = Register-EnforceBound -TaskId 'wd-fix3-attr' -SessionId 'wd-fix3-sess-attr' -Child $root30 -Budget $b30 -StartedAt (Get-Date).ToUniversalTime() -FlagsPath $flagsEnforce -Repo $repo
    Assert-Enforce ([bool]$r30.ok) 'FIX3-2 attribution register bound before the child is born' ([string]$r30.error)
    $kid30 = 0
    $fsw30 = [System.Diagnostics.Stopwatch]::StartNew()
    while ($fsw30.Elapsed.TotalSeconds -lt 25) {
        $kid30 = Find-EnforceChildByPath -ParentId ([int]$root30.Id) -ExePath $shell30
        if ([int]$kid30 -gt 0) { break }
        Start-Sleep -Milliseconds 500
    }
    $fsw30.Stop()
    Assert-Enforce (([int]$kid30 -gt 0)) 'FIX3-2 late child formed after the proof' ''
    Stop-Process -Id ([int]$root30.Id) -Force -ErrorAction SilentlyContinue
    $rootGone30 = $false
    $gsw30 = [System.Diagnostics.Stopwatch]::StartNew()
    while ($gsw30.Elapsed.TotalSeconds -lt 10) {
        try { $lr30 = Get-Process -Id ([int]$root30.Id) -ErrorAction Stop; if ($null -eq $lr30) { $rootGone30 = $true; break } } catch { $rootGone30 = $true; break }
        Start-Sleep -Milliseconds 500
    }
    $gsw30.Stop()
    Assert-Enforce ($rootGone30) 'FIX3-2 root killed externally' ''
    $exec30 = $script:WatchdogExecutions['wd-fix3-attr']
    $int30 = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix3-attr' -Execution $exec30 -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
    Assert-Enforce (([bool]$int30.ok) -and ([string]$int30.settlement -ceq 'ALREADY_EXITED') -and (-not [bool]$int30.interrupted)) 'FIX3-2 post-proof child excluded: ALREADY_EXITED without interrupting' ([string]$int30.settlement)
    Assert-Enforce (([int]$int30.tree_excluded -ge 1) -and ([string]$int30.exclusion -ceq 'WATCHDOG_TREE_EXCLUDED')) 'FIX3-2 exclusion counted with the closed token' ('excluded=' + [string][int]$int30.tree_excluded)
    $kidAlive30 = $false
    try { $lk30 = Get-Process -Id ([int]$kid30) -ErrorAction Stop; $kidAlive30 = ($null -ne $lk30) } catch { $kidAlive30 = $false }
    Assert-Enforce ($kidAlive30) 'FIX3-2 unattributable child survives (never killed)' ''
    Stop-EnforceSafetyId -ProcessId ([int]$kid30)
    Stop-EnforceSafety -Proc $root30
    $sw30.Stop()
    Assert-Enforce (($sw30.Elapsed.TotalSeconds -lt 90)) 'scenario 30 externally bounded' ([string][int]$sw30.Elapsed.TotalSeconds + 's')

    # 31. FIX3-2 gone-path: exact stored identities are liquidated despite a stale proof.
    $sw31 = [System.Diagnostics.Stopwatch]::StartNew()
    $treeWork31 = Join-Path $tempRoot 'tree31'
    New-Item -ItemType Directory -Path $treeWork31 -Force | Out-Null
    $shell31 = Get-EnforceShell
    $rootScript31 = Join-Path $treeWork31 'tree-pair31.ps1'
    Write-EnforceFixture -Path $rootScript31 -Text ("Start-Process -FilePath '" + $shell31 + "' -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 120') -WindowStyle Hidden`nStart-Sleep -Seconds 120`n")
    $root31 = Start-Process -FilePath $shell31 -ArgumentList @('-NoProfile', '-File', $rootScript31) -WindowStyle Hidden -PassThru
    [void]$script:enfChildren.Add($root31)
    [void](Wait-EnforceReady -Proc $root31 -TimeoutMs 10000)
    $kid31 = 0
    $fsw31 = [System.Diagnostics.Stopwatch]::StartNew()
    while ($fsw31.Elapsed.TotalSeconds -lt 20) {
        $kid31 = Find-EnforceChildByPath -ParentId ([int]$root31.Id) -ExePath $shell31
        if ([int]$kid31 -gt 0) { break }
        Start-Sleep -Milliseconds 500
    }
    $fsw31.Stop()
    Assert-Enforce (([int]$kid31 -gt 0)) 'FIX3-2 stored-set tree formed' ''
    $b31 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
    $r31 = Register-EnforceBound -TaskId 'wd-fix3-stored' -SessionId 'wd-fix3-sess-stored' -Child $root31 -Budget $b31 -StartedAt (Get-Date).ToUniversalTime() -FlagsPath $flagsEnforce -Repo $repo
    Assert-Enforce ([bool]$r31.ok) 'FIX3-2 stored-set register bound' ''
    $exec31 = $script:WatchdogExecutions['wd-fix3-stored']
    $kidLine31 = Get-WatchdogCimProcessLine -ProcessId ([int]$kid31)
    Assert-Enforce ([bool]$kidLine31.found) 'FIX3-2 stored-set child CIM identity readable' ''
    $exec31['last_verified_tree'] = @(@{ process_id = ([int]$kid31); creation_ticks = ([long]$kidLine31.creation_ticks) })
    $exec31['last_alive_proof'] = ((Get-Date).ToUniversalTime().AddHours(-1)).ToString('o')
    Stop-Process -Id ([int]$root31.Id) -Force -ErrorAction SilentlyContinue
    $rootGone31 = $false
    $gsw31 = [System.Diagnostics.Stopwatch]::StartNew()
    while ($gsw31.Elapsed.TotalSeconds -lt 10) {
        try { $lr31 = Get-Process -Id ([int]$root31.Id) -ErrorAction Stop; if ($null -eq $lr31) { $rootGone31 = $true; break } } catch { $rootGone31 = $true; break }
        Start-Sleep -Milliseconds 500
    }
    $gsw31.Stop()
    Assert-Enforce ($rootGone31) 'FIX3-2 stored-set root killed externally' ''
    $int31 = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix3-stored' -Execution $exec31 -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
    Assert-Enforce (([bool]$int31.ok) -and ([string]$int31.settlement -ceq 'ALREADY_EXITED') -and ([bool]$int31.interrupted)) 'FIX3-2 stored identity liquidated despite the stale proof' ([string]$int31.settlement)
    $kidGone31 = $false
    $ksw31 = [System.Diagnostics.Stopwatch]::StartNew()
    while ($ksw31.Elapsed.TotalSeconds -lt 10) {
        try { $ck31 = Get-Process -Id ([int]$kid31) -ErrorAction Stop; if ($null -eq $ck31) { $kidGone31 = $true; break } } catch { $kidGone31 = $true; break }
        Start-Sleep -Milliseconds 500
    }
    $ksw31.Stop()
    Assert-Enforce ($kidGone31) 'FIX3-2 stored-set descendant is gone' ''
    Stop-EnforceSafetyId -ProcessId ([int]$kid31)
    Stop-EnforceSafety -Proc $root31
    $sw31.Stop()
    Assert-Enforce (($sw31.Elapsed.TotalSeconds -lt 90)) 'scenario 31 externally bounded' ([string][int]$sw31.Elapsed.TotalSeconds + 's')

    # 32. FIX3-3 refusal after accumulating descendants closes every handle.
    $sw32 = [System.Diagnostics.Stopwatch]::StartNew()
    $treeWork32 = Join-Path $tempRoot 'tree32'
    New-Item -ItemType Directory -Path $treeWork32 -Force | Out-Null
    $shell32 = Get-EnforceShell
    $midScript32 = Join-Path $treeWork32 'tree-mid32.ps1'
    Write-EnforceFixture -Path $midScript32 -Text ("Start-Process -FilePath '" + $shell32 + "' -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 120') -WindowStyle Hidden`nStart-Sleep -Seconds 120`n")
    $rootScript32 = Join-Path $treeWork32 'tree-root32.ps1'
    Write-EnforceFixture -Path $rootScript32 -Text ("Start-Process -FilePath '" + $shell32 + "' -ArgumentList @('-NoProfile','-File','" + $midScript32 + "') -WindowStyle Hidden`nStart-Sleep -Seconds 120`n")
    $root32 = Start-Process -FilePath $shell32 -ArgumentList @('-NoProfile', '-File', $rootScript32) -WindowStyle Hidden -PassThru
    [void]$script:enfChildren.Add($root32)
    [void](Wait-EnforceReady -Proc $root32 -TimeoutMs 10000)
    $mid32 = 0
    $leaf32 = 0
    $fsw32 = [System.Diagnostics.Stopwatch]::StartNew()
    while ($fsw32.Elapsed.TotalSeconds -lt 25) {
        if ([int]$mid32 -le 0) {
            $mid32 = Find-EnforceChildByPath -ParentId ([int]$root32.Id) -ExePath $shell32
        }
        elseif ([int]$leaf32 -le 0) {
            $leaf32 = Find-EnforceChildByPath -ParentId ([int]$mid32) -ExePath $shell32
        }
        else { break }
        Start-Sleep -Milliseconds 500
    }
    $fsw32.Stop()
    Assert-Enforce ((([int]$mid32 -gt 0) -and ([int]$leaf32 -gt 0))) 'FIX3-3 linear chain formed (root->mid->leaf)' ''
    $script:WatchdogTreeTestOverride = @{ ambiguous_pids = @([int]$leaf32); track_handles = $true }
    try {
        $b32 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
        $r32 = Register-EnforceBound -TaskId 'wd-fix3-dispose' -SessionId 'wd-fix3-sess-dispose' -Child $root32 -Budget $b32 -StartedAt (Get-Date).ToUniversalTime() -FlagsPath $flagsEnforce -Repo $repo
        Assert-Enforce ([bool]$r32.ok) 'FIX3-3 dispose register bound' ''
        $script:WatchdogDisposedCount = 0
        $script:WatchdogLiveQueryCount = 0
        $script:WatchdogTrackedResolved = New-Object System.Collections.ArrayList
        $script:WatchdogTrackedDisposed = New-Object System.Collections.ArrayList
        $exec32 = $script:WatchdogExecutions['wd-fix3-dispose']
        $int32 = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix3-dispose' -Execution $exec32 -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
        Assert-Enforce (([string]$int32.error -ceq 'WATCHDOG_INTERRUPT_REFUSED') -and ([string]$int32.detail -ceq 'descendant-ambiguous')) 'FIX3-3 accumulated set refused closed, nothing killed' ([string]$int32.detail)
        $resSorted32 = @(@($script:WatchdogTrackedResolved) | Sort-Object)
        $disSorted32 = @(@($script:WatchdogTrackedDisposed) | Sort-Object)
        $diff32 = @(Compare-Object -ReferenceObject @($resSorted32) -DifferenceObject @($disSorted32))
        $diffCount32 = 0
        foreach ($dd32 in @($diff32)) { if ($null -ne $dd32) { $diffCount32++ } }
        Assert-Enforce ((($diffCount32 -eq 0) -and ((@($resSorted32).Count) -ge 3))) 'FIX3-3/FIX5-3 every resolved instance disposed exactly once (per-instance multisets match, root+mid+leaf minimum; conhost siblings included)' ('resolved=' + [string](@($resSorted32).Count) + ' disposed=' + [string](@($disSorted32).Count))
        Assert-Enforce (Test-EnforceAlive -Proc $root32) 'FIX3-3 refused root survives' ''
        $midAlive32 = $false
        try { $lm32 = Get-Process -Id ([int]$mid32) -ErrorAction Stop; $midAlive32 = ($null -ne $lm32) } catch { $midAlive32 = $false }
        Assert-Enforce ($midAlive32) 'FIX3-3 accumulated mid survives (dropped, never killed)' ''
        $leafAlive32 = $false
        try { $ll32 = Get-Process -Id ([int]$leaf32) -ErrorAction Stop; $leafAlive32 = ($null -ne $ll32) } catch { $leafAlive32 = $false }
        Assert-Enforce ($leafAlive32) 'FIX3-3 ambiguous leaf survives (never killed)' ''
        $s32 = Get-OrchestrationWatchdogSettlement -TaskId 'wd-fix3-dispose' -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
        Assert-Enforce (([string]$s32.settlement -ceq 'REFUSED')) 'FIX3-3 refusal stored REFUSED, never SETTLED' ([string]$s32.settlement)
    }
    finally { $script:WatchdogTreeTestOverride = $null }
    Stop-EnforceSafetyId -ProcessId ([int]$leaf32)
    Stop-EnforceSafetyId -ProcessId ([int]$mid32)
    Stop-EnforceSafety -Proc $root32
    $sw32.Stop()
    Assert-Enforce (($sw32.Elapsed.TotalSeconds -lt 90)) 'scenario 32 externally bounded' ([string][int]$sw32.Elapsed.TotalSeconds + 's')

    # 33. FIX3-1 shared deadline predicate (pure).
    $sw33 = [System.Diagnostics.Stopwatch]::StartNew()
    $past33 = ((Get-Date).ToUniversalTime().AddSeconds(-5))
    $future33 = ((Get-Date).ToUniversalTime().AddSeconds(60))
    Assert-Enforce ((Test-WatchdogDeadlineExceeded -DeadlineUtc $past33)) 'FIX3-1 past deadline reads exceeded' ''
    Assert-Enforce ((-not (Test-WatchdogDeadlineExceeded -DeadlineUtc $future33))) 'FIX3-1 live deadline reads open' ''
    Assert-Enforce ((-not (Test-WatchdogDeadlineExceeded -DeadlineUtc $null))) 'FIX3-1 absent deadline reads open' ''
    Assert-Enforce ((-not (Test-WatchdogDeadlineExceeded -DeadlineUtc 'x'))) 'FIX3-1 non-date deadline reads open' ''
    $sw33.Stop()
    Assert-Enforce (($sw33.Elapsed.TotalSeconds -lt 90)) 'scenario 33 externally bounded' ([string][int]$sw33.Elapsed.TotalSeconds + 's')

    # 34. FIX4-1 proof instant comes from validation, not recording.
    $sw34 = [System.Diagnostics.Stopwatch]::StartNew()
    $treeWork34 = Join-Path $tempRoot 'tree34'
    New-Item -ItemType Directory -Path $treeWork34 -Force | Out-Null
    $shell34 = Get-EnforceShell
    $rootScript34 = Join-Path $treeWork34 'tree-late34.ps1'
    Write-EnforceFixture -Path $rootScript34 -Text ("Start-Sleep -Seconds 2`nStart-Process -FilePath '" + $shell34 + "' -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 120') -WindowStyle Hidden`nStart-Sleep -Seconds 120`n")
    $root34 = Start-Process -FilePath $shell34 -ArgumentList @('-NoProfile', '-File', $rootScript34) -WindowStyle Hidden -PassThru
    [void]$script:enfChildren.Add($root34)
    [void](Wait-EnforceReady -Proc $root34 -TimeoutMs 10000)
    $livePath34 = ''
    try { $livePath34 = ([string](Get-Process -Id ([int]$root34.Id) -ErrorAction Stop).Path).Trim() } catch { $livePath34 = '' }
    $st34 = $null
    try { $st34 = ([DateTime]$root34.StartTime) } catch { $st34 = $null }
    $ident34 = Test-WatchdogProcessIdentity -ProcessId ([int]$root34.Id) -ProcessPath $livePath34 -ParentProcessId ([int]$PID) -ProcessStartTime $st34
    Assert-Enforce (([bool]$ident34.ok) -and (-not [bool]$ident34.unbound)) 'FIX4-1 direct identity validates bound' ''
    $proofAt34 = ''
    try { $proofAt34 = ([string]$ident34.proof_at).Trim() } catch { $proofAt34 = '' }
    $proofDto34 = [DateTimeOffset]::MinValue
    $proofOk34 = ([DateTimeOffset]::TryParse($proofAt34, [ref]$proofDto34))
    Assert-Enforce ($proofOk34) 'FIX4-1 validation returns a parseable proof_at instant' ''
    if ($proofOk34) {
        $age34 = (([DateTimeOffset]::UtcNow - $proofDto34).TotalSeconds)
        Assert-Enforce ((($age34 -ge 0) -and ($age34 -le 60))) 'FIX4-1 proof_at is from the live validation window' ([string][int]$age34 + 's ago')
    }
    $script:WatchdogTreeTestOverride = @{ proof_delay_ms = 6000 }
    try {
        $tBefore34 = (Get-Date).ToUniversalTime()
        $b34 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
        $r34 = Register-EnforceBound -TaskId 'wd-fix4-proof' -SessionId 'wd-fix4-sess-proof' -Child $root34 -Budget $b34 -StartedAt (Get-Date).ToUniversalTime() -FlagsPath $flagsEnforce -Repo $repo
        Assert-Enforce ([bool]$r34.ok) 'FIX4-1 late-recording register bound' ([string]$r34.error)
        $exec34 = $script:WatchdogExecutions['wd-fix4-proof']
        $storedRaw34 = ''
        try { $storedRaw34 = ([string]$exec34['last_alive_proof']).Trim() } catch { $storedRaw34 = '' }
        $storedDto34 = [DateTimeOffset]::MinValue
        Assert-Enforce ([DateTimeOffset]::TryParse($storedRaw34, [ref]$storedDto34)) 'FIX4-1 stored proof is parseable' ''
        $kid34 = 0
        $fsw34 = [System.Diagnostics.Stopwatch]::StartNew()
        while ($fsw34.Elapsed.TotalSeconds -lt 25) {
            $kid34 = Find-EnforceChildByPath -ParentId ([int]$root34.Id) -ExePath $shell34
            if ([int]$kid34 -gt 0) { break }
            Start-Sleep -Milliseconds 500
        }
        $fsw34.Stop()
        Assert-Enforce (([int]$kid34 -gt 0)) 'FIX4-1 child born inside the stretched validation-to-recording window' ''
        $kidLine34 = Get-WatchdogCimProcessLine -ProcessId ([int]$kid34)
        Assert-Enforce ([bool]$kidLine34.found) 'FIX4-1 window-child CIM identity readable' ''
        Assert-Enforce (([long]$storedDto34.UtcDateTime.Ticks -lt [long]$kidLine34.creation_ticks)) 'FIX4-1 stored proof predates the window child (validation instant, not the late recording)' ''
        $lag34 = (((Get-Date).ToUniversalTime() - $storedDto34.UtcDateTime).TotalSeconds)
        Assert-Enforce (($lag34 -ge 4)) 'FIX4-1 recording lagged the proof by the injected delay' ([string][int]$lag34 + 's')
        Stop-Process -Id ([int]$root34.Id) -Force -ErrorAction SilentlyContinue
        $rootGone34 = $false
        $gsw34 = [System.Diagnostics.Stopwatch]::StartNew()
        while ($gsw34.Elapsed.TotalSeconds -lt 10) {
            try { $lr34 = Get-Process -Id ([int]$root34.Id) -ErrorAction Stop; if ($null -eq $lr34) { $rootGone34 = $true; break } } catch { $rootGone34 = $true; break }
            Start-Sleep -Milliseconds 500
        }
        $gsw34.Stop()
        Assert-Enforce ($rootGone34) 'FIX4-1 proof-test root killed externally' ''
        $int34 = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix4-proof' -Execution $exec34 -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
        Assert-Enforce (([bool]$int34.ok) -and ([string]$int34.settlement -ceq 'ALREADY_EXITED') -and (-not [bool]$int34.interrupted)) 'FIX4-1 window child excluded: ALREADY_EXITED without interrupting' ([string]$int34.settlement)
        Assert-Enforce (([int]$int34.tree_excluded -ge 1) -and ([string]$int34.exclusion -ceq 'WATCHDOG_TREE_EXCLUDED')) 'FIX4-1 window-child exclusion counted with the closed token' ('excluded=' + [string][int]$int34.tree_excluded)
        $kidAlive34 = $false
        try { $lk34 = Get-Process -Id ([int]$kid34) -ErrorAction Stop; $kidAlive34 = ($null -ne $lk34) } catch { $kidAlive34 = $false }
        Assert-Enforce ($kidAlive34) 'FIX4-1 window child survives (never killed)' ''
        Stop-EnforceSafetyId -ProcessId ([int]$kid34)
    }
    finally { $script:WatchdogTreeTestOverride = $null }
    Stop-EnforceSafety -Proc $root34
    $sw34.Stop()
    Assert-Enforce (($sw34.Elapsed.TotalSeconds -lt 90)) 'scenario 34 externally bounded' ([string][int]$sw34.Elapsed.TotalSeconds + 's')

    # 35. FIX4-2a expired deadline in the empty gone branch never terminalizes.
    $sw35 = [System.Diagnostics.Stopwatch]::StartNew()
    $saveWait35 = [int]$script:WatchdogSettleWaitMs
    $script:WatchdogSettleWaitMs = 1500
    $c35 = Start-EnforceChild -SleepSeconds 120
    $b35 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
    $r35 = Register-EnforceBound -TaskId 'wd-fix4-emptygate' -SessionId 'wd-fix4-sess-emptygate' -Child $c35 -Budget $b35 -StartedAt (Get-Date).ToUniversalTime() -FlagsPath $flagsEnforce -Repo $repo
    Assert-Enforce ([bool]$r35.ok) 'FIX4-2a empty-gate register bound' ''
    Stop-Process -Id ([int]$c35.Id) -Force -ErrorAction SilentlyContinue
    $rootGone35 = $false
    $gsw35 = [System.Diagnostics.Stopwatch]::StartNew()
    while ($gsw35.Elapsed.TotalSeconds -lt 10) {
        try { $lr35 = Get-Process -Id ([int]$c35.Id) -ErrorAction Stop; if ($null -eq $lr35) { $rootGone35 = $true; break } } catch { $rootGone35 = $true; break }
        Start-Sleep -Milliseconds 500
    }
    $gsw35.Stop()
    Assert-Enforce ($rootGone35) 'FIX4-2a empty-gate root killed externally' ''
    [void](Wait-EnforceSnapshotDrained -ProcessId ([int]$c35.Id) -TimeoutMs 15000)
    $script:WatchdogTreeTestOverride = @{ pre_kill_delay_ms = 2500 }
    try {
        $exec35 = $script:WatchdogExecutions['wd-fix4-emptygate']
        $int35 = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix4-emptygate' -Execution $exec35 -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
        Assert-Enforce ([string]$int35.error -ceq 'WATCHDOG_DEADLINE_EXCEEDED') 'FIX4-2a empty gone branch refuses an expired deadline, never ALREADY_EXITED' ([string]$int35.error)
        $s35 = Get-OrchestrationWatchdogSettlement -TaskId 'wd-fix4-emptygate' -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
        Assert-Enforce (([string]$s35.settlement -ceq 'REFUSED')) 'FIX4-2a empty-branch breach stored REFUSED, never terminal' ([string]$s35.settlement)
    }
    finally { $script:WatchdogTreeTestOverride = $null; $script:WatchdogSettleWaitMs = [int]$saveWait35 }
    Stop-EnforceSafety -Proc $c35
    $sw35.Stop()
    Assert-Enforce (($sw35.Elapsed.TotalSeconds -lt 90)) 'scenario 35 externally bounded' ([string][int]$sw35.Elapsed.TotalSeconds + 's')

    # 36. FIX4-2b expiry between kills => FAILED/PENDING partial, later call resumes.
    $sw36 = [System.Diagnostics.Stopwatch]::StartNew()
    $treeWork36 = Join-Path $tempRoot 'tree36'
    New-Item -ItemType Directory -Path $treeWork36 -Force | Out-Null
    $shell36 = Get-EnforceShell
    $rootScript36 = Join-Path $treeWork36 'tree-pair36.ps1'
    Write-EnforceFixture -Path $rootScript36 -Text ("Start-Process -FilePath '" + $shell36 + "' -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 120') -WindowStyle Hidden`nStart-Process -FilePath '" + $shell36 + "' -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 120') -WindowStyle Hidden`nStart-Sleep -Seconds 120`n")
    $root36 = Start-Process -FilePath $shell36 -ArgumentList @('-NoProfile', '-File', $rootScript36) -WindowStyle Hidden -PassThru
    [void]$script:enfChildren.Add($root36)
    [void](Wait-EnforceReady -Proc $root36 -TimeoutMs 10000)
    $kids36 = @()
    $fsw36 = [System.Diagnostics.Stopwatch]::StartNew()
    while ($fsw36.Elapsed.TotalSeconds -lt 25) {
        $kids36 = @()
        $snap36 = Get-WatchdogTreeChildSnapshot -ProcessId ([int]$root36.Id)
        if ([bool]$snap36.ok) {
            foreach ($crow36 in @($snap36.children)) {
                $cpid36 = 0
                try { $cpid36 = ([int]$crow36.process_id) } catch { $cpid36 = 0 }
                if ($cpid36 -lt 1) { continue }
                $cpath36 = ''
                try { $cpath36 = ([string](Get-Process -Id $cpid36 -ErrorAction Stop).Path).Trim() } catch { $cpath36 = '' }
                if ($cpath36 -ceq $shell36) { $kids36 += $cpid36 }
            }
        }
        if ((@($kids36).Count) -ge 2) { break }
        Start-Sleep -Milliseconds 500
    }
    $fsw36.Stop()
    Assert-Enforce (((@($kids36).Count) -ge 2)) 'FIX4-2b two-child tree formed' ('children=' + [string](@($kids36).Count))
    $saveWait36 = [int]$script:WatchdogSettleWaitMs
    # FIX4-2b budget (2026-10-03 flake, killed=1 1/4 on PS5.1): the shared
    # enforce deadline must absorb the real CIM tree preparation AND the root
    # stop, so the first child is still killed before the deadline bites, so
    # killed_count=2 (root + first child) holds. The invariant is
    # budget >= preparation AND stop_delay_ms > budget: the hook sleep before
    # the SECOND descendant then always breaches the deadline, breaking the
    # loop there and never killing the expected-extra process. Raising only
    # the budget (2500 -> 9000, 3.6x preparation slack) while leaving
    # stop_delay_ms at 5000 would breach nothing and kill 3. stop_delay_ms is
    # pinned at the lib clamp ceiling (10000) so the breach also survives a
    # short Start-Sleep undershoot. Asserts below are UNCHANGED.
    $script:WatchdogSettleWaitMs = 9000
    $b36 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
    $r36 = Register-EnforceBound -TaskId 'wd-fix4-partial' -SessionId 'wd-fix4-sess-partial' -Child $root36 -Budget $b36 -StartedAt (Get-Date).ToUniversalTime() -FlagsPath $flagsEnforce -Repo $repo
    Assert-Enforce ([bool]$r36.ok) 'FIX4-2b partial register bound' ''
    $script:WatchdogTreeTestOverride = @{ stop_delay_ms = 10000 }
    try {
        $exec36 = $script:WatchdogExecutions['wd-fix4-partial']
        $int36 = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix4-partial' -Execution $exec36 -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
        Assert-Enforce (([string]$int36.error -ceq 'WATCHDOG_INTERRUPT_FAILED') -and ([bool]$int36.partial) -and ([int]$int36.killed_count -eq 2)) 'FIX4-2b expiry between kills => FAILED/PENDING partial with evidence (root + first child)' ('killed=' + [string][int]$int36.killed_count)
        $s36 = Get-OrchestrationWatchdogSettlement -TaskId 'wd-fix4-partial' -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
        Assert-Enforce (([string]$s36.settlement -ceq 'PENDING')) 'FIX4-2b partial settlement PENDING (retryable, F6 intact)' ([string]$s36.settlement)
        $aliveKids36 = @(@($kids36) | Where-Object {
            $kp = [int]$_
            $found = $false
            try { $lp = Get-Process -Id $kp -ErrorAction Stop; $found = ($null -ne $lp) } catch { $found = $false }
            $found
        })
        Assert-Enforce (((@($aliveKids36).Count) -ge 1)) 'FIX4-2b at least one descendant remains alive (remainder pending)' ('alive=' + [string](@($aliveKids36).Count))
        Assert-Enforce ((-not (Test-EnforceAlive -Proc $root36))) 'FIX4-2b partial root is gone' ''
    }
    finally { $script:WatchdogTreeTestOverride = $null; $script:WatchdogSettleWaitMs = [int]$saveWait36 }
    $exec36b = $script:WatchdogExecutions['wd-fix4-partial']
    $int36b = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix4-partial' -Execution $exec36b -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
    Assert-Enforce (([bool]$int36b.ok) -and ([string]$int36b.settlement -ceq 'ALREADY_EXITED')) 'FIX4-2b later call resumes the remainder to ALREADY_EXITED' ([string]$int36b.settlement)
    $restGone36 = $true
    foreach ($kp36 in @($kids36)) {
        try { $lp36 = Get-Process -Id ([int]$kp36) -ErrorAction Stop; if ($null -ne $lp36) { $restGone36 = $false } } catch { }
    }
    Assert-Enforce ($restGone36) 'FIX4-2b resumed remainder is gone' ''
    foreach ($kp36 in @($kids36)) { Stop-EnforceSafetyId -ProcessId ([int]$kp36) }
    Stop-EnforceSafety -Proc $root36
    $sw36.Stop()
    Assert-Enforce (($sw36.Elapsed.TotalSeconds -lt 90)) 'scenario 36 externally bounded' ([string][int]$sw36.Elapsed.TotalSeconds + 's')

    # 37. FIX5-1 death between resolution and proof capture => no proof => fail-closed.
    $sw37 = [System.Diagnostics.Stopwatch]::StartNew()
    $c37a = Start-EnforceChild -SleepSeconds 120
    [void](Wait-EnforceReady -Proc $c37a -TimeoutMs 10000)
    $livePath37a = ''
    try { $livePath37a = ([string](Get-Process -Id ([int]$c37a.Id) -ErrorAction Stop).Path).Trim() } catch { $livePath37a = '' }
    $st37a = $null
    try { $st37a = ([DateTime]$c37a.StartTime) } catch { $st37a = $null }
    $script:WatchdogTreeTestOverride = @{ kill_after_resolve = $true }
    try {
        $ident37a = Test-WatchdogProcessIdentity -ProcessId ([int]$c37a.Id) -ProcessPath $livePath37a -ParentProcessId ([int]$PID) -ProcessStartTime $st37a
    }
    finally { $script:WatchdogTreeTestOverride = $null }
    Assert-Enforce (([string]$ident37a.error -ceq 'INVALID_PROCESS_IDENTITY') -and ([string]$ident37a.detail -ceq 'process identity is not provably alive')) 'FIX5-1 dead-at-capture identity => INVALID, no proof, no binding' ([string]$ident37a.detail)
    Stop-EnforceSafety -Proc $c37a
    $c37 = Start-EnforceChild -SleepSeconds 120
    $sent37 = Start-EnforceChild -SleepSeconds 120
    $b37 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
    $r37 = Register-EnforceBound -TaskId 'wd-fix5-noproof' -SessionId 'wd-fix5-sess-noproof' -Child $c37 -Budget $b37 -StartedAt (Get-Date).ToUniversalTime() -FlagsPath $flagsEnforce -Repo $repo
    Assert-Enforce ([bool]$r37.ok) 'FIX5-1 no-proof register bound' ''
    $exec37 = $script:WatchdogExecutions['wd-fix5-noproof']
    $p037 = ''
    try { $p037 = ([string]$exec37['last_alive_proof']).Trim() } catch { $p037 = '' }
    $script:WatchdogTreeTestOverride = @{ kill_after_resolve = $true }
    try {
        $int37 = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix5-noproof' -Execution $exec37 -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
    }
    finally { $script:WatchdogTreeTestOverride = $null }
    Assert-Enforce ([string]$int37.error -ceq 'WATCHDOG_INTERRUPT_REFUSED') 'FIX5-1 death mid-validation => REFUSED, nothing killed' ([string]$int37.error)
    $s37 = Get-OrchestrationWatchdogSettlement -TaskId 'wd-fix5-noproof' -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-Enforce (([string]$s37.settlement -ceq 'REFUSED')) 'FIX5-1 refusal stored REFUSED, never SETTLED' ([string]$s37.settlement)
    Assert-Enforce (Test-EnforceAlive -Proc $sent37) 'FIX5-1 sentinel survives (nothing killed by the watchdog)' ''
    $p137 = ''
    try { $p137 = ([string]$exec37['last_alive_proof']).Trim() } catch { $p137 = '' }
    Assert-Enforce (($p137 -ceq $p037)) 'FIX5-1 no late proof stamped on refusal' ''
    Stop-EnforceSafety -Proc $c37
    Stop-EnforceSafety -Proc $sent37
    $sw37.Stop()
    Assert-Enforce (($sw37.Elapsed.TotalSeconds -lt 90)) 'scenario 37 externally bounded' ([string][int]$sw37.Elapsed.TotalSeconds + 's')

    # 38. FIX5-2 slow terminal writer crossing the deadline (normal path) => partial, never terminal.
    $sw38 = [System.Diagnostics.Stopwatch]::StartNew()
    $treeWork38 = Join-Path $tempRoot 'tree38'
    New-Item -ItemType Directory -Path $treeWork38 -Force | Out-Null
    $shell38 = Get-EnforceShell
    $rootScript38 = Join-Path $treeWork38 'tree-pair38.ps1'
    Write-EnforceFixture -Path $rootScript38 -Text ("Start-Process -FilePath '" + $shell38 + "' -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 120') -WindowStyle Hidden`nStart-Sleep -Seconds 120`n")
    $root38 = Start-Process -FilePath $shell38 -ArgumentList @('-NoProfile', '-File', $rootScript38) -WindowStyle Hidden -PassThru
    [void]$script:enfChildren.Add($root38)
    [void](Wait-EnforceReady -Proc $root38 -TimeoutMs 10000)
    $kid38 = 0
    $fsw38 = [System.Diagnostics.Stopwatch]::StartNew()
    while ($fsw38.Elapsed.TotalSeconds -lt 20) {
        $kid38 = Find-EnforceChildByPath -ParentId ([int]$root38.Id) -ExePath $shell38
        if ([int]$kid38 -gt 0) { break }
        Start-Sleep -Milliseconds 500
    }
    $fsw38.Stop()
    Assert-Enforce (([int]$kid38 -gt 0)) 'FIX5-2 slow-writer tree formed' ''
    $saveWait38 = [int]$script:WatchdogSettleWaitMs
    $script:WatchdogSettleWaitMs = 5000
    $b38 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
    $r38 = Register-EnforceBound -TaskId 'wd-fix5-slowwrite' -SessionId 'wd-fix5-sess-slowwrite' -Child $root38 -Budget $b38 -StartedAt (Get-Date).ToUniversalTime() -FlagsPath $flagsEnforce -Repo $repo
    Assert-Enforce ([bool]$r38.ok) 'FIX5-2 slow-writer register bound' ''
    $script:WatchdogTreeTestOverride = @{ telemetry_delay_ms = 8000 }
    try {
        $exec38 = $script:WatchdogExecutions['wd-fix5-slowwrite']
        # NOTE (counterfactual coverage): the delay below applies ONLY to the
        # WATCHDOG_SETTLED terminal write. All pre-terminal gates (tree,
        # pre-kill, per-stop, post-wait) therefore observe a live deadline,
        # and the flow provably ARRIVES at the terminal store — asserted
        # via the SETTLED-line delta. Without the post-writer revalidation
        # gate, the delayed write would persist terminal SETTLED and the
        # PENDING/partial asserts below would fail.
        $telePath38 = ([string](Get-WatchdogTelemetryFile -TelemetryRoot $teleRoot -RepoRoot $repo))
        $settledBefore38 = 0
        try {
            if (Test-Path -LiteralPath $telePath38 -PathType Leaf) {
                $settledBefore38 = @(@(Get-Content -LiteralPath $telePath38 -ErrorAction Stop) | Where-Object { $_ -like '*"event":"WATCHDOG_SETTLED"*' }).Count
            }
        }
        catch { $settledBefore38 = 0 }
        $int38 = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix5-slowwrite' -Execution $exec38 -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
        Assert-Enforce (([string]$int38.error -ceq 'WATCHDOG_INTERRUPT_FAILED') -and ([bool]$int38.partial) -and ([int]$int38.killed_count -ge 2)) 'FIX5-2 terminal write crossing deadline => FAILED/PENDING partial with evidence' ('killed=' + [string][int]$int38.killed_count)
        Assert-Enforce (([string]$int38.telemetry_file -ceq $telePath38)) 'FIX5-2 partial references the measured telemetry file' ''
        $settledAfter38 = 0
        try {
            if (Test-Path -LiteralPath $telePath38 -PathType Leaf) {
                $settledAfter38 = @(@(Get-Content -LiteralPath $telePath38 -ErrorAction Stop) | Where-Object { $_ -like '*"event":"WATCHDOG_SETTLED"*' }).Count
            }
        }
        catch { $settledAfter38 = 0 }
        Assert-Enforce (([int]$settledAfter38 -gt [int]$settledBefore38)) 'FIX5-2 terminal store reached with initially-live deadline (SETTLED written, then diverted)' ('delta=' + [string]([int]$settledAfter38 - [int]$settledBefore38))
        $s38 = Get-OrchestrationWatchdogSettlement -TaskId 'wd-fix5-slowwrite' -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
        Assert-Enforce (([string]$s38.settlement -ceq 'PENDING')) 'FIX5-2 partial settlement PENDING (retryable)' ([string]$s38.settlement)
    }
    finally { $script:WatchdogTreeTestOverride = $null; $script:WatchdogSettleWaitMs = [int]$saveWait38 }
    $exec38b = $script:WatchdogExecutions['wd-fix5-slowwrite']
    $int38b = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix5-slowwrite' -Execution $exec38b -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
    Assert-Enforce (([bool]$int38b.ok) -and ([string]$int38b.settlement -ceq 'ALREADY_EXITED')) 'FIX5-2 later call resumes to ALREADY_EXITED' ([string]$int38b.settlement)
    Assert-Enforce ((-not (Test-EnforceAlive -Proc $root38))) 'FIX5-2 slow-write root is gone' ''
    $kidGone38 = $false
    try { $lk38 = Get-Process -Id ([int]$kid38) -ErrorAction Stop; $kidGone38 = ($null -eq $lk38) } catch { $kidGone38 = $true }
    Assert-Enforce ($kidGone38) 'FIX5-2 slow-write child is gone' ''
    Stop-EnforceSafetyId -ProcessId ([int]$kid38)
    Stop-EnforceSafety -Proc $root38
    $sw38.Stop()
    Assert-Enforce (($sw38.Elapsed.TotalSeconds -lt 90)) 'scenario 38 externally bounded' ([string][int]$sw38.Elapsed.TotalSeconds + 's')

    # 39. FIX5-2 slow terminal writer crossing the deadline (gone path) => partial, never terminal.
    $sw39 = [System.Diagnostics.Stopwatch]::StartNew()
    $treeWork39 = Join-Path $tempRoot 'tree39'
    New-Item -ItemType Directory -Path $treeWork39 -Force | Out-Null
    $shell39 = Get-EnforceShell
    $rootScript39 = Join-Path $treeWork39 'tree-flash39.ps1'
    Write-EnforceFixture -Path $rootScript39 -Text ("Start-Process -FilePath '" + $shell39 + "' -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 120') -WindowStyle Hidden`nStart-Sleep -Seconds 6`n")
    $root39 = Start-Process -FilePath $shell39 -ArgumentList @('-NoProfile', '-File', $rootScript39) -WindowStyle Hidden -PassThru
    [void]$script:enfChildren.Add($root39)
    $kid39 = 0
    $fsw39 = [System.Diagnostics.Stopwatch]::StartNew()
    while ($fsw39.Elapsed.TotalSeconds -lt 20) {
        $kid39 = Find-EnforceChildByPath -ParentId ([int]$root39.Id) -ExePath $shell39
        if ([int]$kid39 -gt 0) { break }
        Start-Sleep -Milliseconds 500
    }
    $fsw39.Stop()
    Assert-Enforce (([int]$kid39 -gt 0)) 'FIX5-2 gone slow-writer tree formed' ''
    $b39 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
    $r39 = Register-EnforceBound -TaskId 'wd-fix5-goneslow' -SessionId 'wd-fix5-sess-goneslow' -Child $root39 -Budget $b39 -StartedAt (Get-Date).ToUniversalTime() -FlagsPath $flagsEnforce -Repo $repo
    Assert-Enforce ([bool]$r39.ok) 'FIX5-2 gone slow-writer register bound' ([string]$r39.error)
    $rootGone39 = $false
    $gsw39 = [System.Diagnostics.Stopwatch]::StartNew()
    while ($gsw39.Elapsed.TotalSeconds -lt 15) {
        try { $lr39 = Get-Process -Id ([int]$root39.Id) -ErrorAction Stop; if ($null -eq $lr39) { $rootGone39 = $true; break } } catch { $rootGone39 = $true; break }
        Start-Sleep -Milliseconds 500
    }
    $gsw39.Stop()
    Assert-Enforce ($rootGone39) 'FIX5-2 gone slow-writer root exited on its own' ''
    $saveWait39 = [int]$script:WatchdogSettleWaitMs
    $script:WatchdogSettleWaitMs = 2000
    $script:WatchdogTreeTestOverride = @{ telemetry_delay_ms = 3000 }
    try {
        $exec39 = $script:WatchdogExecutions['wd-fix5-goneslow']
        $int39 = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix5-goneslow' -Execution $exec39 -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
        Assert-Enforce (([string]$int39.error -ceq 'WATCHDOG_INTERRUPT_FAILED') -and ([bool]$int39.partial) -and ([int]$int39.killed_count -ge 1)) 'FIX5-2 gone terminal write crossing deadline => FAILED/PENDING partial' ('killed=' + [string][int]$int39.killed_count)
        $s39 = Get-OrchestrationWatchdogSettlement -TaskId 'wd-fix5-goneslow' -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
        Assert-Enforce (([string]$s39.settlement -ceq 'PENDING')) 'FIX5-2 gone partial settlement PENDING (retryable)' ([string]$s39.settlement)
    }
    finally { $script:WatchdogTreeTestOverride = $null; $script:WatchdogSettleWaitMs = [int]$saveWait39 }
    $exec39b = $script:WatchdogExecutions['wd-fix5-goneslow']
    $int39b = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix5-goneslow' -Execution $exec39b -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
    Assert-Enforce (([bool]$int39b.ok) -and ([string]$int39b.settlement -ceq 'ALREADY_EXITED')) 'FIX5-2 gone later call resumes to ALREADY_EXITED' ([string]$int39b.settlement)
    $kidGone39 = $false
    $ksw39 = [System.Diagnostics.Stopwatch]::StartNew()
    while ($ksw39.Elapsed.TotalSeconds -lt 10) {
        try { $ck39 = Get-Process -Id ([int]$kid39) -ErrorAction Stop; if ($null -eq $ck39) { $kidGone39 = $true; break } } catch { $kidGone39 = $true; break }
        Start-Sleep -Milliseconds 500
    }
    $ksw39.Stop()
    Assert-Enforce ($kidGone39) 'FIX5-2 gone slow-write descendant is gone' ''
    Stop-EnforceSafetyId -ProcessId ([int]$kid39)
    Stop-EnforceSafety -Proc $root39
    $sw39.Stop()
    Assert-Enforce (($sw39.Elapsed.TotalSeconds -lt 90)) 'scenario 39 externally bounded' ([string][int]$sw39.Elapsed.TotalSeconds + 's')

    # 40. FIX5-2 slow terminal writer crossing the deadline (gone-empty path) => refuse, never terminal.
    $sw40 = [System.Diagnostics.Stopwatch]::StartNew()
    $saveWait40 = [int]$script:WatchdogSettleWaitMs
    $script:WatchdogSettleWaitMs = 2000
    $c40 = Start-EnforceChild -SleepSeconds 120
    $b40 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
    $r40 = Register-EnforceBound -TaskId 'wd-fix5-emptyslow' -SessionId 'wd-fix5-sess-emptyslow' -Child $c40 -Budget $b40 -StartedAt (Get-Date).ToUniversalTime() -FlagsPath $flagsEnforce -Repo $repo
    Assert-Enforce ([bool]$r40.ok) 'FIX5-2 empty slow-writer register bound' ''
    Stop-Process -Id ([int]$c40.Id) -Force -ErrorAction SilentlyContinue
    $rootGone40 = $false
    $gsw40 = [System.Diagnostics.Stopwatch]::StartNew()
    while ($gsw40.Elapsed.TotalSeconds -lt 10) {
        try { $lr40 = Get-Process -Id ([int]$c40.Id) -ErrorAction Stop; if ($null -eq $lr40) { $rootGone40 = $true; break } } catch { $rootGone40 = $true; break }
        Start-Sleep -Milliseconds 500
    }
    $gsw40.Stop()
    Assert-Enforce ($rootGone40) 'FIX5-2 empty slow-writer root killed externally' ''
    [void](Wait-EnforceSnapshotDrained -ProcessId ([int]$c40.Id) -TimeoutMs 15000)
    $script:WatchdogTreeTestOverride = @{ telemetry_delay_ms = 3000 }
    try {
        $exec40 = $script:WatchdogExecutions['wd-fix5-emptyslow']
        $int40 = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix5-emptyslow' -Execution $exec40 -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
        Assert-Enforce ([string]$int40.error -ceq 'WATCHDOG_DEADLINE_EXCEEDED') 'FIX5-2 empty gone branch refuses an expired deadline, never ALREADY_EXITED' ([string]$int40.error)
        $s40 = Get-OrchestrationWatchdogSettlement -TaskId 'wd-fix5-emptyslow' -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
        Assert-Enforce (([string]$s40.settlement -ceq 'REFUSED')) 'FIX5-2 empty-branch breach stored REFUSED, never terminal' ([string]$s40.settlement)
    }
    finally { $script:WatchdogTreeTestOverride = $null; $script:WatchdogSettleWaitMs = [int]$saveWait40 }
    Stop-EnforceSafety -Proc $c40
    $sw40.Stop()
    Assert-Enforce (($sw40.Elapsed.TotalSeconds -lt 90)) 'scenario 40 externally bounded' ([string][int]$sw40.Elapsed.TotalSeconds + 's')

    # 41. FIX6-1b verified-but-unproven ownership => REFUSED proof-unavailable (not CIM).
    $sw41 = [System.Diagnostics.Stopwatch]::StartNew()
    $c41 = Start-EnforceChild -SleepSeconds 120
    [void](Wait-EnforceReady -Proc $c41 -TimeoutMs 10000)
    $livePath41 = ''
    try { $livePath41 = ([string](Get-Process -Id ([int]$c41.Id) -ErrorAction Stop).Path).Trim() } catch { $livePath41 = '' }
    $liveStart41 = ''
    try { $liveStart41 = (([DateTime]$c41.StartTime).ToUniversalTime().ToString('o')) } catch { $liveStart41 = '' }
    $exec41 = @{ process = [ordered]@{ process_id = ([int]$c41.Id); process_path = $livePath41; parent_process_id = ([int]$PID); process_start_time = $liveStart41 } }
    $own41a = Test-WatchdogProcessOwnership -Execution $exec41
    Assert-Enforce (([bool]$own41a.owned) -and (-not [string]::IsNullOrWhiteSpace([string]$own41a.proof_at))) 'FIX6-1b same identity+parentage verifies owned with proof (control)' ''
    $script:WatchdogTreeTestOverride = @{ suppress_proof = $true }
    try {
        $own41b = Test-WatchdogProcessOwnership -Execution $exec41
    }
    finally { $script:WatchdogTreeTestOverride = $null }
    Assert-Enforce (((-not [bool]$own41b.owned) -and ([string]$own41b.reason -ceq 'WATCHDOG_INTERRUPT_REFUSED') -and ([string]$own41b.detail -ceq 'proof-unavailable'))) 'FIX6-1b verified-but-unproven => REFUSED for lack of proof, not CIM' ([string]$own41b.reason + '/' + [string]$own41b.detail)
    Assert-Enforce (Test-EnforceAlive -Proc $c41) 'FIX6-1b refused child intact (dropped, never killed)' ''
    $sent41 = Start-EnforceChild -SleepSeconds 120
    $b41 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
    $r41 = Register-EnforceBound -TaskId 'wd-fix6-noproofown' -SessionId 'wd-fix6-sess-noproofown' -Child $c41 -Budget $b41 -StartedAt (Get-Date).ToUniversalTime() -FlagsPath $flagsEnforce -Repo $repo
    Assert-Enforce ([bool]$r41.ok) 'FIX6-1b end-to-end register bound' ''
    $exec41b = $script:WatchdogExecutions['wd-fix6-noproofown']
    $p041 = ''
    try { $p041 = ([string]$exec41b['last_alive_proof']).Trim() } catch { $p041 = '' }
    $script:WatchdogTreeTestOverride = @{ suppress_proof = $true }
    try {
        $int41 = Invoke-WatchdogProcessInterrupt -TaskId 'wd-fix6-noproofown' -Execution $exec41b -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
    }
    finally { $script:WatchdogTreeTestOverride = $null }
    Assert-Enforce (([string]$int41.error -ceq 'WATCHDOG_INTERRUPT_REFUSED') -and ([string]$int41.detail -ceq 'proof-unavailable')) 'FIX6-1b dispatcher REFUSED proof-unavailable end-to-end' ([string]$int41.detail)
    $s41 = Get-OrchestrationWatchdogSettlement -TaskId 'wd-fix6-noproofown' -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
    Assert-Enforce (([string]$s41.settlement -ceq 'REFUSED')) 'FIX6-1b refusal stored REFUSED, never SETTLED' ([string]$s41.settlement)
    Assert-Enforce (Test-EnforceAlive -Proc $sent41) 'FIX6-1b sentinel survives (nothing killed)' ''
    $p141 = ''
    try { $p141 = ([string]$exec41b['last_alive_proof']).Trim() } catch { $p141 = '' }
    Assert-Enforce (($p141 -ceq $p041)) 'FIX6-1b stored proof untouched on refusal' ''
    Stop-EnforceSafety -Proc $c41
    Stop-EnforceSafety -Proc $sent41
    $sw41.Stop()
    Assert-Enforce (($sw41.Elapsed.TotalSeconds -lt 90)) 'scenario 41 externally bounded' ([string][int]$sw41.Elapsed.TotalSeconds + 's')

    # 42. FIX6-1c producer without proof_at => INVALID, never binding with now().
    $sw42 = [System.Diagnostics.Stopwatch]::StartNew()
    $c42 = Start-EnforceChild -SleepSeconds 120
    [void](Wait-EnforceReady -Proc $c42 -TimeoutMs 10000)
    $origIdentity42 = (Get-Item -Path 'function:Test-WatchdogProcessIdentity').ScriptBlock
    try {
        Set-Item -Path 'function:Test-WatchdogProcessIdentity' -Value {
            param($ProcessId, [string]$ProcessPath = '', $ParentProcessId = $null, $ProcessStartTime = $null, [string]$FaultInject = '')
            try {
                $lp42 = ''
                try { $lp42 = ([string](Get-Process -Id ([int]$ProcessId) -ErrorAction Stop).Path).Trim() } catch { $lp42 = '' }
                $lst42 = ''
                try { $lst42 = (([DateTime](Get-Process -Id ([int]$ProcessId) -ErrorAction Stop).StartTime).ToUniversalTime().ToString('o')) } catch { $lst42 = '' }
                $pp42 = 0
                try { $pp42 = ([int]$PID) } catch { $pp42 = 0 }
                $obs42 = [ordered]@{ process_id = ([int]$ProcessId); process_path = $lp42; parent_process_id = $pp42; process_start_time = $lst42 }
                return [PSCustomObject]@{ ok = $true; unbound = $false; observed = $obs42 }
            }
            catch { return (New-WatchdogError -Code 'INVALID_PROCESS_IDENTITY') }
        }
        $b42 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
        $r42 = Register-EnforceBound -TaskId 'wd-fix6-stubproof' -SessionId 'wd-fix6-sess-stubproof' -Child $c42 -Budget $b42 -StartedAt (Get-Date).ToUniversalTime() -FlagsPath $flagsEnforce -Repo $repo
        Assert-Enforce (([string]$r42.error -ceq 'INVALID_PROCESS_IDENTITY') -and ([string]$r42.detail -ceq 'proof-unavailable')) 'FIX6-1c proof-less producer => INVALID, never binding with now()' ([string]$r42.detail)
        Assert-Enforce ((-not $script:WatchdogExecutions.ContainsKey('wd-fix6-stubproof'))) 'FIX6-1c rejected registration stored nothing' ''
    }
    finally { Set-Item -Path 'function:Test-WatchdogProcessIdentity' -Value $origIdentity42 }
    Stop-EnforceSafety -Proc $c42
    $sw42.Stop()
    Assert-Enforce (($sw42.Elapsed.TotalSeconds -lt 90)) 'scenario 42 externally bounded' ([string][int]$sw42.Elapsed.TotalSeconds + 's')

    # 43. RR-P26-JOB-WIRING: o escape pos-snapshot FICA FECHADO. A raiz
    #     verificada e atribuida ao job ANTES do snapshot; um descendente
    #     criado DEPOIS do snapshot (durante a janela do pre-kill gate, via
    #     o hook test-only pre_kill_delay_ms + um arquivo de sinal que o
    #     PROPRIO filho da raiz observa) nao existe no conjunto verificado e
    #     so pode morrer pelo TerminateJobObject. Prova de que nao foi o kill
    #     CIM: o PID tardio NAO esta em last_verified_tree.
    $sw43 = [System.Diagnostics.Stopwatch]::StartNew()
    $shell43 = Get-EnforceShell
    $sig43 = Join-Path $tempRoot 'job43-signal.txt'
    $first43 = Join-Path $tempRoot 'job43-first.txt'
    $late43 = Join-Path $tempRoot 'job43-late.txt'
    $root43 = Join-Path $tempRoot 'job43-root.ps1'
    $sigScript43 = Join-Path $tempRoot 'job43-signal.ps1'
    Write-EnforceFixture -Path $sigScript43 -Text "param([string]`$Sig)`nStart-Sleep -Seconds 4`n[IO.File]::WriteAllText(`$Sig,'go')`n"
    $root43Body = @'
param([string]$Shell, [string]$First, [string]$Late, [string]$Signal)
$p1 = Start-Process -FilePath $Shell -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 120') -WindowStyle Hidden -PassThru
[IO.File]::WriteAllText($First, [string]$p1.Id)
$limit = [DateTime]::UtcNow.AddSeconds(40)
while ([DateTime]::UtcNow -lt $limit) {
  if (Test-Path -LiteralPath $Signal -PathType Leaf) { break }
  Start-Sleep -Milliseconds 200
}
if (Test-Path -LiteralPath $Signal -PathType Leaf) {
  $p2 = Start-Process -FilePath $Shell -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 120') -WindowStyle Hidden -PassThru
  [IO.File]::WriteAllText($Late, [string]$p2.Id)
}
Start-Sleep -Seconds 120
'@
    Write-EnforceFixture -Path $root43 -Text $root43Body
    $sigWriter43 = $null
    $root43Proc = $null
    $firstPid43 = 0
    $latePid43 = 0
    $saveWait43 = [int]$script:WatchdogSettleWaitMs
    try {
        $root43Proc = Start-Process -FilePath $shell43 -ArgumentList @('-NoProfile', '-File', (ConvertTo-EnforceArg $root43), '-Shell', (ConvertTo-EnforceArg $shell43), '-First', (ConvertTo-EnforceArg $first43), '-Late', (ConvertTo-EnforceArg $late43), '-Signal', (ConvertTo-EnforceArg $sig43)) -WindowStyle Hidden -PassThru
        $firstPid43 = Read-EnforcePidFile -Path $first43 -TimeoutMs 20000
        Assert-Enforce (([int]$firstPid43 -gt 0) -and (Test-EnforceAlive -Proc $root43Proc)) 'JOB43 tree formed (root + first child)' ('first=' + [string][int]$firstPid43)
        $b43 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
        $r43 = Register-EnforceBound -TaskId 'wd-job-late' -SessionId 'wd-job-sess-late' -Child $root43Proc -Budget $b43 -StartedAt (Get-Date).ToUniversalTime() -FlagsPath $flagsEnforce -RepoRoot $repo
        Assert-Enforce ([bool]$r43.ok) 'JOB43 register bound' ([string]$r43.error)
        # Sinalizador: escrita do arquivo DEPOIS do snapshot (o pre-kill gate
        # segura a janela) e ANTES do stop da raiz.
        $sigWriter43 = Start-Process -FilePath $shell43 -ArgumentList @('-NoProfile', '-File', (ConvertTo-EnforceArg $sigScript43), '-Sig', (ConvertTo-EnforceArg $sig43)) -WindowStyle Hidden -PassThru
        $script:WatchdogSettleWaitMs = 20000
        $script:WatchdogTreeTestOverride = @{ pre_kill_delay_ms = 8000 }
        $exec43 = $script:WatchdogExecutions['wd-job-late']
        $int43 = Invoke-WatchdogProcessInterrupt -TaskId 'wd-job-late' -Execution $exec43 -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
        Assert-Enforce (([bool]$int43.ok) -and ([string]$int43.settlement -ceq 'SETTLED') -and ([bool]$int43.interrupted)) 'JOB43 interrupt settles the verified tree' ([string]$int43.error + '/' + [string]$int43.settlement)
        Assert-Enforce ([bool]$int43.job_attached) 'JOB43 verified root attached to the job before the snapshot' ([string]$int43.job_attach)
        Assert-Enforce (([string]$int43.job_attach -ceq 'attached') -and ([bool]$int43.job_kill_applied)) 'JOB43 TerminateJobObject applied as backstop' ([string]$int43.job_attach)
        $latePid43 = Read-EnforcePidFile -Path $late43 -TimeoutMs 5000
        Assert-Enforce ([int]$latePid43 -gt 0) 'JOB43 late descendant really spawned during the kill window' ('late=' + [string][int]$latePid43)
        $snap43 = @($exec43['last_verified_tree'])
        $snapPids43 = @()
        foreach ($s43 in $snap43) { try { $snapPids43 += [int]$s43.process_id } catch { } }
        Assert-Enforce ((-not ($snapPids43 -contains [int]$latePid43))) 'JOB43 late descendant was NOT in the verified snapshot (kill CIM could not have targeted it)' ('snapshot=' + ($snapPids43 -join ',') + ' late=' + [string][int]$latePid43)
        Assert-Enforce (($snapPids43 -contains [int]$firstPid43)) 'JOB43 pre-attach child IS in the verified snapshot' ('snapshot=' + ($snapPids43 -join ','))
        $lateGone43 = $false
        $swLate43 = [System.Diagnostics.Stopwatch]::StartNew()
        while ($swLate43.ElapsedMilliseconds -lt 10000) {
            $lp43 = $null
            try { $lp43 = Get-Process -Id ([int]$latePid43) -ErrorAction Stop } catch { $lp43 = $null }
            if ($null -eq $lp43) { $lateGone43 = $true; break }
            Start-Sleep -Milliseconds 200
        }
        Assert-Enforce $lateGone43 'JOB43 late descendant post-snapshot DIED by the job backstop' ('late=' + [string][int]$latePid43)
        Assert-Enforce ((-not (Test-EnforceAlive -Proc $root43Proc))) 'JOB43 root gone' ''
        $firstGone43 = $false
        try { $fp43 = Get-Process -Id ([int]$firstPid43) -ErrorAction Stop; $firstGone43 = ($null -ne $fp43) } catch { $firstGone43 = $false }
        Assert-Enforce (-not $firstGone43) 'JOB43 pre-attach child gone (CIM-verified kill)' ''
        Assert-Enforce (([int]$int43.job_members_remaining -eq 0) -and ([bool]$int43.job_settled)) 'JOB43 bounded job settlement drained' ('remaining=' + [string][int]$int43.job_members_remaining)
        Assert-Enforce (([bool]$int43.job_close_applied) -and ([string]$int43.job_close_note -match 'close:')) 'JOB43 close do handle do job publicado no resultado (sem leak observavel)' ('note=' + [string]$int43.job_close_note)
        $rec43 = $exec43['enforcement']
        Assert-Enforce (($rec43 -is [System.Collections.IDictionary]) -and ([bool]$rec43['job_attached']) -and ([string]$rec43['job_attach'] -ceq 'attached')) 'JOB43 stored settlement carries the bounded job evidence' ([string]$rec43['job_attach'])
        Assert-Enforce (($rec43 -is [System.Collections.IDictionary]) -and ([bool]$rec43['job_close_applied'])) 'JOB43 stored settlement prova o fechamento do handle do job' ('note=' + [string]$rec43['job_close_note'])
        $shapeAttach43 = Get-EnforceSettlementShape -Exec $exec43
    }
    catch {
        Assert-Enforce $false 'JOB43 scenario ran without unexpected error' ([string]$_)
    }
    finally {
        $script:WatchdogTreeTestOverride = $null
        $script:WatchdogSettleWaitMs = [int]$saveWait43
        Stop-EnforceSafety -Proc $sigWriter43
        Stop-EnforceSafety -Proc $root43Proc
        Stop-EnforceSafetyId -ProcessId $firstPid43
        Stop-EnforceSafetyId -ProcessId $latePid43
    }
    $sw43.Stop()
    Assert-Enforce (($sw43.Elapsed.TotalSeconds -lt 90)) 'scenario 43 externally bounded' ([string][int]$sw43.Elapsed.TotalSeconds + 's')

    # 44. RR-P26-JOB-WIRING attach RECUSADO => fallback CIM com settlement
    #     IDENTICO ao do run com attach (a unica diferenca no registro sao as
    #     chaves job_*, evidencia do backstop). Sentinel nao relacionado
    #     intacto nos dois runs.
    $sw44 = [System.Diagnostics.Stopwatch]::StartNew()
    $shell44 = Get-EnforceShell
    $noSig44 = Join-Path $tempRoot 'job44-signal-never.txt'
    # Sentinel Nao relacionado: vive ate o fim da suite (registrado em
    # $script:enfChildren); o scenario 45 ainda o usa como prova de que o
    # PID desconhecido nao matou nada.
    $sentinel44 = Start-EnforceChild -SleepSeconds 120
    $shapeAttach44 = ''
    try {
        foreach ($mode in @('attach', 'refused')) {
            $firstFile = Join-Path $tempRoot ('job44-first-' + [string]$mode + '.txt')
            $rootFile = Join-Path $tempRoot ('job44-root-' + [string]$mode + '.ps1')
            Write-EnforceFixture -Path $rootFile -Text $root43Body
            $rootProc = $null
            $childPid = 0
            $task44 = ('wd-job-' + [string]$mode)
            try {
                $rootProc = Start-Process -FilePath $shell44 -ArgumentList @('-NoProfile', '-File', (ConvertTo-EnforceArg $rootFile), '-Shell', (ConvertTo-EnforceArg $shell44), '-First', (ConvertTo-EnforceArg $firstFile), '-Late', (ConvertTo-EnforceArg $firstFile), '-Signal', (ConvertTo-EnforceArg $noSig44)) -WindowStyle Hidden -PassThru
                $childPid = Read-EnforcePidFile -Path $firstFile -TimeoutMs 20000
                Assert-Enforce ([int]$childPid -gt 0) ('JOB44 ' + [string]$mode + ' tree formed') ('child=' + [string][int]$childPid)
                $b44 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
                $r44 = Register-EnforceBound -TaskId $task44 -SessionId ('wd-job-sess-' + [string]$mode) -Child $rootProc -Budget $b44 -StartedAt (Get-Date).ToUniversalTime() -FlagsPath $flagsEnforce -RepoRoot $repo
                Assert-Enforce ([bool]$r44.ok) ('JOB44 ' + [string]$mode + ' register bound') ([string]$r44.error)
                if ([string]$mode -ceq 'refused') { $script:WatchdogTreeTestOverride = @{ job_attach_refuse = $true } }
                $exec44 = $script:WatchdogExecutions[$task44]
                $int44 = Invoke-WatchdogProcessInterrupt -TaskId $task44 -Execution $exec44 -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
                $script:WatchdogTreeTestOverride = $null
                Assert-Enforce (([bool]$int44.ok) -and ([string]$int44.settlement -ceq 'SETTLED') -and ([bool]$int44.interrupted)) ('JOB44 ' + [string]$mode + ' settles the verified tree') ([string]$int44.error + '/' + [string]$int44.settlement)
                if ([string]$mode -ceq 'refused') {
                    Assert-Enforce (((-not [bool]$int44.job_attached)) -and (([string]$int44.job_attach).StartsWith('refused:')) -and (-not [bool]$int44.job_kill_applied)) 'JOB44 refused attach => structured note, no job kill' ([string]$int44.job_attach)
                }
                else {
                    Assert-Enforce ([bool]$int44.job_attached) 'JOB44 attached run attached the job' ([string]$int44.job_attach)
                }
                $childAlive44 = $false
                try { $cp44 = Get-Process -Id ([int]$childPid) -ErrorAction Stop; $childAlive44 = ($null -ne $cp44) } catch { $childAlive44 = $false }
                Assert-Enforce (-not $childAlive44) ('JOB44 ' + [string]$mode + ' child killed either way') ('child=' + [string][int]$childPid)
                Assert-Enforce (Test-EnforceAlive -Proc $sentinel44) ('JOB44 ' + [string]$mode + ' unrelated sentinel intact') ''
                $shape = Get-EnforceSettlementShape -Exec $exec44
                if ([string]$mode -ceq 'attach') { $shapeAttach44 = $shape }
                else { Assert-Enforce ($shape -ceq $shapeAttach44) 'JOB44 stored settlement identical apart from job_* evidence' ('attach=' + $shapeAttach44 + ' refused=' + $shape) }
            }
            finally {
                $script:WatchdogTreeTestOverride = $null
                Stop-EnforceSafety -Proc $rootProc
                Stop-EnforceSafetyId -ProcessId $childPid
            }
        }
    }
    catch {
        Assert-Enforce $false 'JOB44 scenario ran without unexpected error' ([string]$_)
    }
    $sw44.Stop()
    Assert-Enforce (($sw44.Elapsed.TotalSeconds -lt 90)) 'scenario 44 externally bounded' ([string][int]$sw44.Elapsed.TotalSeconds + 's')

    # 45. RR-P26-JOB-WIRING guards: nenhum taskkill nas libs (o job lib mantem
    # a promessa de nunca ler o 49374 no proprio contrato), o wiring existe,
    # e um PID desconhecido nunca chega ao caminho do job.
    $sw45 = [System.Diagnostics.Stopwatch]::StartNew()
    $jobLib45 = ''
    try { $jobLib45 = ([IO.File]::ReadAllText((Join-Path $repo 'scripts\runtime\lib\RuntimeJobObject.ps1'), [Text.Encoding]::UTF8)) } catch { $jobLib45 = '' }
    $wdLib45 = ''
    try { $wdLib45 = ([IO.File]::ReadAllText($libPath, [Text.Encoding]::UTF8)) } catch { $wdLib45 = '' }
    Assert-Enforce ((-not ($wdLib45 -match '(?i)taskkill')) -and (-not ($jobLib45 -match '(?i)taskkill'))) 'JOB45 no taskkill anywhere in the enforcement or the job lib' ''
    Assert-Enforce (($wdLib45 -notmatch '49374') -and ($jobLib45 -match 'Nao le 49374')) 'JOB45 enforcement never touches the AI Memory port 49374; the job lib keeps that promise in its own contract' ''
    Assert-Enforce (($wdLib45.Contains('Attach-RuntimeJobVerifiedProcess')) -and ($wdLib45.Contains('New-RuntimeJobObject -NoKillOnClose'))) 'JOB45 enforcement wires the verified attach through the non-lethal job seam' ''
    $unknown45 = @{ process = [ordered]@{ process_id = 999999; process_path = 'C:\nope\nope.exe'; parent_process_id = ([int]$PID); process_start_time = ((Get-Date).ToUniversalTime().ToString('o')) } }
    $int45 = Invoke-WatchdogProcessInterrupt -TaskId 'wd-job-unknown' -Execution $unknown45 -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
    Assert-Enforce (([string]$int45.error -ceq 'WATCHDOG_INTERRUPT_REFUSED') -and (-not ($int45.PSObject.Properties.Name -contains 'job_attach'))) 'JOB45 unknown PID => structured refusal on the gone path, job wiring never engaged' ([string]$int45.error)
    Assert-Enforce (Test-EnforceAlive -Proc $sentinel44) 'JOB45 unknown PID killed nothing (sentinel intact)' ''
    $sw45.Stop()
    Assert-Enforce (($sw45.Elapsed.TotalSeconds -lt 90)) 'scenario 45 externally bounded' ([string][int]$sw45.Elapsed.TotalSeconds + 's')

    # 46. RR-P26-JOB-WIRING D-2: CONTROLE NEGATIVO do discriminante. Mesmo
    #     cenario do JOB43 (descendente criado DEPOIS do snapshot, durante a
    #     janela do pre-kill gate) porem com o attach RECUSADO => caminho
    #     CIM-only => o descendente tardio SOBREVIVE ao settlement. E o que
    #     prova que, no JOB43, quem matou o tardio foi o backstop do job e
    #     nao o kill CIM (unico discriminante = a vida do tardio; o
    #     settlement gravado e byte-identico ao do caso positivo na projecao
    #     sem job_*). O cleanup do sobrevivente e pelo HANDLE do job de teste,
    #     nunca taskkill por PID solto.
    $sw46 = [System.Diagnostics.Stopwatch]::StartNew()
    $shell46 = Get-EnforceShell
    $sig46 = Join-Path $tempRoot 'job46-signal.txt'
    $first46 = Join-Path $tempRoot 'job46-first.txt'
    $late46 = Join-Path $tempRoot 'job46-late.txt'
    $root46 = Join-Path $tempRoot 'job46-root.ps1'
    $sigScript46 = Join-Path $tempRoot 'job46-signal.ps1'
    Write-EnforceFixture -Path $sigScript46 -Text "param([string]`$Sig)`nStart-Sleep -Seconds 4`n[IO.File]::WriteAllText(`$Sig,'go')`n"
    Write-EnforceFixture -Path $root46 -Text $root43Body
    $sigWriter46 = $null
    $root46Proc = $null
    $firstPid46 = 0
    $latePid46 = 0
    $saveWait46 = [int]$script:WatchdogSettleWaitMs
    try {
        $root46Proc = Start-Process -FilePath $shell46 -ArgumentList @('-NoProfile', '-File', (ConvertTo-EnforceArg $root46), '-Shell', (ConvertTo-EnforceArg $shell46), '-First', (ConvertTo-EnforceArg $first46), '-Late', (ConvertTo-EnforceArg $late46), '-Signal', (ConvertTo-EnforceArg $sig46)) -WindowStyle Hidden -PassThru
        $firstPid46 = Read-EnforcePidFile -Path $first46 -TimeoutMs 20000
        Assert-Enforce (([int]$firstPid46 -gt 0) -and (Test-EnforceAlive -Proc $root46Proc)) 'JOB46 negative tree formed (root + first child)' ('first=' + [string][int]$firstPid46)
        $b46 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
        $r46 = Register-EnforceBound -TaskId 'wd-job-late-neg' -SessionId 'wd-job-sess-late-neg' -Child $root46Proc -Budget $b46 -StartedAt (Get-Date).ToUniversalTime() -FlagsPath $flagsEnforce -RepoRoot $repo
        Assert-Enforce ([bool]$r46.ok) 'JOB46 negative register bound' ([string]$r46.error)
        $sigWriter46 = Start-Process -FilePath $shell46 -ArgumentList @('-NoProfile', '-File', (ConvertTo-EnforceArg $sigScript46), '-Sig', (ConvertTo-EnforceArg $sig46)) -WindowStyle Hidden -PassThru
        $script:WatchdogSettleWaitMs = 20000
        $script:WatchdogTreeTestOverride = @{ pre_kill_delay_ms = 8000; job_attach_refuse = $true }
        $exec46 = $script:WatchdogExecutions['wd-job-late-neg']
        $int46 = Invoke-WatchdogProcessInterrupt -TaskId 'wd-job-late-neg' -Execution $exec46 -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
        $script:WatchdogTreeTestOverride = $null
        Assert-Enforce ((([string]$int46.job_attach).StartsWith('refused:')) -and (-not [bool]$int46.job_attached)) 'JOB46 negative: attach recusado com nota fechada' ([string]$int46.job_attach)
        Assert-Enforce (-not [bool]$int46.job_kill_applied) 'JOB46 negative: nenhum TerminateJobObject (CIM-only de verdade)' ''
        Assert-Enforce (([bool]$int46.ok) -and ([string]$int46.settlement -ceq 'SETTLED') -and ([bool]$int46.interrupted)) 'JOB46 negative: mesmo settlement terminal de sempre (SETTLED)' ([string]$int46.error + '/' + [string]$int46.settlement)
        $latePid46 = Read-EnforcePidFile -Path $late46 -TimeoutMs 5000
        Assert-Enforce ([int]$latePid46 -gt 0) 'JOB46 negative: descendente tardio realmente nasceu na janela' ('late=' + [string][int]$latePid46)
        $snapPids46 = @()
        foreach ($s46 in @($exec46['last_verified_tree'])) { try { $snapPids46 += [int]$s46.process_id } catch { } }
        Assert-Enforce ((-not ($snapPids46 -contains [int]$latePid46))) 'JOB46 negative: o tardio tambem nao estava no snapshot verificado' ('snapshot=' + ($snapPids46 -join ','))
        Assert-Enforce (Test-EnforcePidAlive -ProcessId $latePid46) 'JOB46 DISCRIMINANTE: sem o job o tardio SOBREVIVE ao settlement (o kill CIM nao o alcancou)' ('late=' + [string][int]$latePid46)
        Start-Sleep -Milliseconds 2000
        Assert-Enforce (Test-EnforcePidAlive -ProcessId $latePid46) 'JOB46 negative: tardio segue vivo 2s depois (so o backstop o mataria)' ('late=' + [string][int]$latePid46)
        Assert-Enforce ((-not (Test-EnforceAlive -Proc $root46Proc))) 'JOB46 negative: raiz e arvore verificada mortas pelo caminho CIM de sempre' ''
        $cleanupJob46 = New-RuntimeJobObject
        $lateProc46 = $null
        $lateTicks46 = 0
        try { $lateProc46 = Get-Process -Id ([int]$latePid46) -ErrorAction Stop } catch { $lateProc46 = $null }
        if ($null -ne $lateProc46) { try { $lateTicks46 = [long](([DateTime]$lateProc46.StartTime).ToUniversalTime().Ticks) } catch { $lateTicks46 = 0 } }
        $att46 = Attach-RuntimeJobVerifiedProcess -Job $cleanupJob46 -Instance $lateProc46 -ExpectedCreationTicks ([long]$lateTicks46)
        Assert-Enforce ([bool]$att46.Ok) 'JOB46 cleanup: sobrevivente atribuido ao job de teste com identidade re-verificada' ([string]$att46.Reason)
        $cl46 = Close-RuntimeJobObject -Job $cleanupJob46
        Assert-Enforce ([bool]$cl46.Ok) 'JOB46 cleanup: job de teste fechado (kill-on-close, sem taskkill por PID)' ([string]$cl46.Reason)
        $swGone46 = [System.Diagnostics.Stopwatch]::StartNew()
        $gone46 = $false
        while ($swGone46.ElapsedMilliseconds -lt 10000) {
            if (-not (Test-EnforcePidAlive -ProcessId $latePid46)) { $gone46 = $true; break }
            Start-Sleep -Milliseconds 200
        }
        Assert-Enforce $gone46 'JOB46 cleanup: sobrevivente encerrado pelo handle do job de teste' ('late=' + [string][int]$latePid46)
        $shapeNeg46 = Get-EnforceSettlementShape -Exec $exec46
        Assert-Enforce ($shapeNeg46 -ceq $shapeAttach43) 'JOB46 negative: settlement byte-identico ao positivo na projecao sem job_*' ('pos=' + $shapeAttach43 + ' neg=' + $shapeNeg46)
    }
    catch {
        Assert-Enforce $false 'JOB46 scenario ran without unexpected error' ([string]$_)
    }
    finally {
        $script:WatchdogTreeTestOverride = $null
        $script:WatchdogSettleWaitMs = [int]$saveWait46
        Stop-EnforceSafety -Proc $sigWriter46
        Stop-EnforceSafety -Proc $root46Proc
        Stop-EnforceSafetyId -ProcessId $firstPid46
        Stop-EnforceSafetyId -ProcessId $latePid46
    }
    $sw46.Stop()
    Assert-Enforce (($sw46.Elapsed.TotalSeconds -lt 90)) 'scenario 46 externally bounded' ([string][int]$sw46.Elapsed.TotalSeconds + 's')

    # 47. RR-P26-JOB-WIRING-FIX1 HIGH-1 (adversarial): o prazo expira ENTRE o
    #     kill CIM e o backstop (o hook stop_delay_ms segura a janela ate o
    #     prazo estourar). O TerminateJobObject NAO pode rodar com prazo
    #     vencido => sem morte pelo job, o descendente tardio SOBREVIVE (como
    #     antes do wiring), handle fechado INERTEMENTE, nota bounded
    #     job_skip='deadline-expired' e a classacao de deadline ja existente
    #     (FAILED/PENDING partial, nunca terminal).
    $sw47 = [System.Diagnostics.Stopwatch]::StartNew()
    $shell47 = Get-EnforceShell
    $sig47 = Join-Path $tempRoot 'job47-signal.txt'
    $first47 = Join-Path $tempRoot 'job47-first.txt'
    $second47 = Join-Path $tempRoot 'job47-second.txt'
    $late47 = Join-Path $tempRoot 'job47-late.txt'
    $root47 = Join-Path $tempRoot 'job47-root.ps1'
    $sigScript47 = Join-Path $tempRoot 'job47-signal.ps1'
    Write-EnforceFixture -Path $sigScript47 -Text "param([string]`$Sig)`nStart-Sleep -Seconds 2`n[IO.File]::WriteAllText(`$Sig,'go')`n"
    $root47Body = @'
param([string]$Shell, [string]$First, [string]$Second, [string]$Late, [string]$Signal)
$a = Start-Process -FilePath $Shell -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 120') -WindowStyle Hidden -PassThru
[IO.File]::WriteAllText($First, [string]$a.Id)
$b = Start-Process -FilePath $Shell -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 120') -WindowStyle Hidden -PassThru
[IO.File]::WriteAllText($Second, [string]$b.Id)
$limit = [DateTime]::UtcNow.AddSeconds(40)
while ([DateTime]::UtcNow -lt $limit) {
  if (Test-Path -LiteralPath $Signal -PathType Leaf) { break }
  Start-Sleep -Milliseconds 200
}
if (Test-Path -LiteralPath $Signal -PathType Leaf) {
  $c = Start-Process -FilePath $Shell -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 120') -WindowStyle Hidden -PassThru
  [IO.File]::WriteAllText($Late, [string]$c.Id)
}
Start-Sleep -Seconds 120
'@
    Write-EnforceFixture -Path $root47 -Text $root47Body
    $sigWriter47 = $null
    $root47Proc = $null
    $firstPid47 = 0
    $secondPid47 = 0
    $latePid47 = 0
    $saveWait47 = [int]$script:WatchdogSettleWaitMs
    try {
        $root47Proc = Start-Process -FilePath $shell47 -ArgumentList @('-NoProfile', '-File', (ConvertTo-EnforceArg $root47), '-Shell', (ConvertTo-EnforceArg $shell47), '-First', (ConvertTo-EnforceArg $first47), '-Second', (ConvertTo-EnforceArg $second47), '-Late', (ConvertTo-EnforceArg $late47), '-Signal', (ConvertTo-EnforceArg $sig47)) -WindowStyle Hidden -PassThru
        $firstPid47 = Read-EnforcePidFile -Path $first47 -TimeoutMs 20000
        $secondPid47 = Read-EnforcePidFile -Path $second47 -TimeoutMs 20000
        Assert-Enforce (([int]$firstPid47 -gt 0) -and ([int]$secondPid47 -gt 0)) 'JOB47 tree formed (root + 2 verified children)' ('first=' + [string][int]$firstPid47 + ' second=' + [string][int]$secondPid47)
        $b47 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
        $r47 = Register-EnforceBound -TaskId 'wd-job-deadline' -SessionId 'wd-job-sess-deadline' -Child $root47Proc -Budget $b47 -StartedAt (Get-Date).ToUniversalTime() -FlagsPath $flagsEnforce -RepoRoot $repo
        Assert-Enforce ([bool]$r47.ok) 'JOB47 register bound' ([string]$r47.error)
        $sigWriter47 = Start-Process -FilePath $shell47 -ArgumentList @('-NoProfile', '-File', (ConvertTo-EnforceArg $sigScript47), '-Sig', (ConvertTo-EnforceArg $sig47)) -WindowStyle Hidden -PassThru
        $script:WatchdogSettleWaitMs = 9000
        $script:WatchdogTreeTestOverride = @{ pre_kill_delay_ms = 4000; stop_delay_ms = 10000 }
        $exec47 = $script:WatchdogExecutions['wd-job-deadline']
        $int47 = Invoke-WatchdogProcessInterrupt -TaskId 'wd-job-deadline' -Execution $exec47 -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
        $script:WatchdogTreeTestOverride = $null
        # No caminho partial o resultado e um erro sem os campos de job; a
        # evidencia vive no registro de settlement (mesmo dicionario do
        # JOB43), entao e de la que o skip e lido.
        $rec47job = $exec47['enforcement']
        Assert-Enforce (($rec47job -is [System.Collections.IDictionary]) -and ([string]$rec47job['settlement'] -ceq 'PENDING')) 'JOB47 HIGH-1: registro persistido em PENDING (nunca SETTLED com prazo vencido)' ([string]$rec47job['settlement'])
        Assert-Enforce ([bool]$rec47job['job_attached']) 'JOB47 attach aconteceu antes do prazo estourar (o skip e do backstop, nao do attach)' ([string]$rec47job['job_attach'])
        Assert-Enforce ((-not [bool]$rec47job['job_kill_applied'])) 'JOB47 HIGH-1: nenhum TerminateJobObject com o prazo vencido' ('skip=' + [string]$rec47job['job_skip'])
        Assert-Enforce (([string]$rec47job['job_skip'] -ceq 'deadline-expired')) 'JOB47 HIGH-1: nota bounded honesta do skip por prazo' ([string]$rec47job['job_skip'])
        Assert-Enforce ([bool]$rec47job['job_close_applied']) 'JOB47 HIGH-1: handle do job fechado inertemente (sem leak)' ''
        Assert-Enforce (([int]$rec47job['job_members_before'] -ge 1)) 'JOB47 HIGH-1: membros vivos no job no momento do skip (evidencia auditavel)' ('before=' + [string][int]$rec47job['job_members_before'])
        Assert-Enforce (([string]$int47.error -ceq 'WATCHDOG_INTERRUPT_FAILED') -and ([bool]$int47.partial)) 'JOB47 HIGH-1: classificacao de deadline ja existente (FAILED/PENDING partial, nao terminal)' ([string]$int47.error)
        $s47b = Get-OrchestrationWatchdogSettlement -TaskId 'wd-job-deadline' -FlagsPath $flagsEnforce -RepoRoot $repo -TelemetryRoot $teleRoot
        Assert-Enforce (([string]$s47b.settlement -ceq 'PENDING')) 'JOB47 HIGH-1: settlement consultavel em PENDING' ([string]$s47b.settlement)
        $latePid47 = Read-EnforcePidFile -Path $late47 -TimeoutMs 5000
        Assert-Enforce ([int]$latePid47 -gt 0) 'JOB47 HIGH-1: descendente tardio nasceu na janela pos-snapshot' ('late=' + [string][int]$latePid47)
        $snapPids47 = @()
        foreach ($s47c in @($exec47['last_verified_tree'])) { try { $snapPids47 += [int]$s47c.process_id } catch { } }
        Assert-Enforce ((-not ($snapPids47 -contains [int]$latePid47))) 'JOB47 HIGH-1: o tardio nao estava no snapshot verificado' ('snapshot=' + ($snapPids47 -join ','))
        Start-Sleep -Milliseconds 1500
        Assert-Enforce (Test-EnforcePidAlive -ProcessId $latePid47) 'JOB47 HIGH-1: o tardio SOBREVIVE (o job nao matou ninguem com prazo vencido)' ('late=' + [string][int]$latePid47)
        Assert-Enforce (Test-EnforceAlive -Proc $sentinel44) 'JOB47 HIGH-1: sentinel nao relacionado intacto' ''
        $cleanupJob47 = New-RuntimeJobObject
        $lateProc47 = $null
        $lateTicks47 = 0
        try { $lateProc47 = Get-Process -Id ([int]$latePid47) -ErrorAction Stop } catch { $lateProc47 = $null }
        if ($null -ne $lateProc47) { try { $lateTicks47 = [long](([DateTime]$lateProc47.StartTime).ToUniversalTime().Ticks) } catch { $lateTicks47 = 0 } }
        $att47 = Attach-RuntimeJobVerifiedProcess -Job $cleanupJob47 -Instance $lateProc47 -ExpectedCreationTicks ([long]$lateTicks47)
        Assert-Enforce ([bool]$att47.Ok) 'JOB47 cleanup: sobrevivente atribuido ao job de teste com identidade re-verificada' ([string]$att47.Reason)
        [void](Close-RuntimeJobObject -Job $cleanupJob47)
        $swGone47 = [System.Diagnostics.Stopwatch]::StartNew()
        $gone47 = $false
        while ($swGone47.ElapsedMilliseconds -lt 10000) {
            if (-not (Test-EnforcePidAlive -ProcessId $latePid47)) { $gone47 = $true; break }
            Start-Sleep -Milliseconds 200
        }
        Assert-Enforce $gone47 'JOB47 cleanup: sobrevivente encerrado pelo handle do job de teste' ('late=' + [string][int]$latePid47)
    }
    catch {
        Assert-Enforce $false 'JOB47 scenario ran without unexpected error' ([string]$_)
    }
    finally {
        $script:WatchdogTreeTestOverride = $null
        $script:WatchdogSettleWaitMs = [int]$saveWait47
        Stop-EnforceSafety -Proc $sigWriter47
        Stop-EnforceSafety -Proc $root47Proc
        Stop-EnforceSafetyId -ProcessId $firstPid47
        Stop-EnforceSafetyId -ProcessId $secondPid47
        Stop-EnforceSafetyId -ProcessId $latePid47
    }
    $sw47.Stop()
    Assert-Enforce (($sw47.Elapsed.TotalSeconds -lt 90)) 'scenario 47 externally bounded' ([string][int]$sw47.Elapsed.TotalSeconds + 's')

# 48. RR-P26-JOB-WIRING-FIX1 HIGH-2 (adversarial): a raiz sai sozinha
    #     DEPOIS do snapshot, deixando SO o descendente tardio. O kill CIM nao
    #     tem alvo nenhum (killed=0) e so o backstop do job mata o tardio =>
    #     interrupted=true e a contagem efetiva inclui o delta medido. Sem
    #     REFUSED falso depois de um ato letal.
    $sw48 = [System.Diagnostics.Stopwatch]::StartNew()
    $shell48 = Get-EnforceShell
    $sig48 = Join-Path $tempRoot 'job48-signal.txt'
    $late48 = Join-Path $tempRoot 'job48-late.txt'
    $root48 = Join-Path $tempRoot 'job48-root.ps1'
    $sigScript48 = Join-Path $tempRoot 'job48-signal.ps1'
    Write-EnforceFixture -Path $sigScript48 -Text "param([string]`$Sig)`nStart-Sleep -Seconds 5`n[IO.File]::WriteAllText(`$Sig,'go')`n"
    $root48Body = @'
param([string]$Shell, [string]$Late, [string]$Signal)
$limit = [DateTime]::UtcNow.AddSeconds(40)
while ([DateTime]::UtcNow -lt $limit) {
  if (Test-Path -LiteralPath $Signal -PathType Leaf) { break }
  Start-Sleep -Milliseconds 200
}
if (Test-Path -LiteralPath $Signal -PathType Leaf) {
  $c = Start-Process -FilePath $Shell -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 120') -WindowStyle Hidden -PassThru
  [IO.File]::WriteAllText($Late, [string]$c.Id)
}
Start-Sleep -Milliseconds 400
'@
    Write-EnforceFixture -Path $root48 -Text $root48Body
    $sigWriter48 = $null
    $root48Proc = $null
    $latePid48 = 0
    $saveWait48 = [int]$script:WatchdogSettleWaitMs
    try {
        $root48Proc = Start-Process -FilePath $shell48 -ArgumentList @('-NoProfile', '-File', (ConvertTo-EnforceArg $root48), '-Shell', (ConvertTo-EnforceArg $shell48), '-Late', (ConvertTo-EnforceArg $late48), '-Signal', (ConvertTo-EnforceArg $sig48)) -WindowStyle Hidden -PassThru
        $b48 = New-EnforceBudget -Steps 64 -Wall 1200 -NoProg 600
        $r48 = Register-EnforceBound -TaskId 'wd-job-onlyjob' -SessionId 'wd-job-sess-onlyjob' -Child $root48Proc -Budget $b48 -StartedAt (Get-Date).ToUniversalTime() -FlagsPath $flagsEnforce -RepoRoot $repo
        Assert-Enforce ([bool]$r48.ok) 'JOB48 register bound' ([string]$r48.error)
        $sigWriter48 = Start-Process -FilePath $shell48 -ArgumentList @('-NoProfile', '-File', (ConvertTo-EnforceArg $sigScript48), '-Sig', (ConvertTo-EnforceArg $sig48)) -WindowStyle Hidden -PassThru
        $script:WatchdogSettleWaitMs = 25000
        $script:WatchdogTreeTestOverride = @{ pre_kill_delay_ms = 8000 }
        $exec48 = $script:WatchdogExecutions['wd-job-onlyjob']
        $int48 = Invoke-WatchdogProcessInterrupt -TaskId 'wd-job-onlyjob' -Execution $exec48 -Classification 'HARD_TIMEOUT' -ElapsedSeconds 31 -Steps 0 -TelemetryRoot $teleRoot -RepoRoot $repo
        $script:WatchdogTreeTestOverride = $null
        Assert-Enforce ([bool]$int48.job_attached) 'JOB48 raiz verificada atribuida ao job antes do snapshot' ([string]$int48.job_attach)
        $latePid48 = Read-EnforcePidFile -Path $late48 -TimeoutMs 5000
        Assert-Enforce ([int]$latePid48 -gt 0) 'JOB48 tardio nasceu na janela pos-snapshot' ('late=' + [string][int]$latePid48)
        $snapPids48 = @()
        foreach ($s48 in @($exec48['last_verified_tree'])) { try { $snapPids48 += [int]$s48.process_id } catch { } }
        Assert-Enforce ((-not ($snapPids48 -contains [int]$latePid48))) 'JOB48 o tardio e pos-snapshot (fora do conjunto verificado)' ('snapshot=' + ($snapPids48 -join ',') + ' late=' + [string][int]$latePid48)
        Assert-Enforce (([string]$int48.error -eq '') -and ([string]$int48.settlement -ceq 'ALREADY_EXITED')) 'JOB48 raiz saiu sozinha => ALREADY_EXITED (nenhum REFUSED falso)' ([string]$int48.error + '/' + [string]$int48.settlement)
        # Premissa do cenario, provada e nao presumida: todo PID do snapshot
        # verificado esta morto depois do interrupt, logo o kill CIM NAO teve
        # alvo vivo (killed CIM = 0) e o interrupted=true so pode vir do job.
        $snapAlive48 = @()
        foreach ($sp48 in @($snapPids48)) {
            if ([int]$sp48 -lt 1) { continue }
            if (Test-EnforcePidAlive -ProcessId ([int]$sp48)) { $snapAlive48 += [int]$sp48 }
        }
        Assert-Enforce ((@($snapAlive48)).Count -eq 0) 'JOB48 premissa: nenhum PID do snapshot verificado sobreviveu (kill CIM = 0)' ('vivos=' + ($snapAlive48 -join ','))
        Assert-Enforce ([bool]$int48.interrupted) 'JOB48 FIX2: interrupted=true com contador CIM = 0 (o booleano do ato letal basta; KilledCount segue 0)' ('interrupted=' + [string][bool]$int48.interrupted)
        Assert-Enforce ([bool]$int48.job_kill_applied) 'JOB48 FIX2: ato letal autorizado aplicado (booleano TerminateJobObject ok; nunca vira contagem)' ('skip=' + [string]$int48.job_skip)
        Assert-Enforce (([int]$int48.job_members_reduction -ge 0)) 'JOB48 FIX2: reducao de membros do job observada e publicada SEM claim de autoria/causa' ('reducao=' + [string][int]$int48.job_members_reduction + ' before=' + [string][int]$int48.job_members_before)
        Assert-Enforce (([string]$int48.job_skip -eq '') -and ([int]$int48.job_members_before -ge 1)) 'JOB48 FIX2: sem skip (o prazo estava vivo) e havia membro vivo no job' ('skip=' + [string]$int48.job_skip)
        $swDead48 = [System.Diagnostics.Stopwatch]::StartNew()
        $lateGone48 = $false
        while ($swDead48.ElapsedMilliseconds -lt 10000) {
            if (-not (Test-EnforcePidAlive -ProcessId $latePid48)) { $lateGone48 = $true; break }
            Start-Sleep -Milliseconds 200
        }
        Assert-Enforce $lateGone48 'JOB48 o tardio nao sobreviveu (observacao: ato letal do job aplicado e unico alvo vivo; reducao observada em job_members_reduction sem claim de autoria)' ('late=' + [string][int]$latePid48)
        $rec48 = $exec48['enforcement']
        Assert-Enforce (($rec48 -is [System.Collections.IDictionary]) -and ([bool]$rec48['interrupted']) -and ([string]$rec48['settlement'] -ceq 'ALREADY_EXITED')) 'JOB48 registro persistido: interrupted=true + ALREADY_EXITED' ([string]$rec48['settlement'])
        Assert-Enforce (Test-EnforceAlive -Proc $sentinel44) 'JOB48 sentinel nao relacionado intacto' ''
    }
    catch {
        Assert-Enforce $false 'JOB48 scenario ran without unexpected error' ([string]$_)
    }
    finally {
        $script:WatchdogTreeTestOverride = $null
        $script:WatchdogSettleWaitMs = [int]$saveWait48
        Stop-EnforceSafety -Proc $sigWriter48
        Stop-EnforceSafety -Proc $root48Proc
        Stop-EnforceSafetyId -ProcessId $latePid48
    }
    $sw48.Stop()
    Assert-Enforce (($sw48.Elapsed.TotalSeconds -lt 90)) 'scenario 48 externally bounded' ([string][int]$sw48.Elapsed.TotalSeconds + 's')

# 11. frozen-file guards: P25 HOLD text and production flags untouched.
    $sw11 = [System.Diagnostics.Stopwatch]::StartNew()
    $oldText = ''
    try { $oldText = ([IO.File]::ReadAllText($oldWatchdogTests, [Text.Encoding]::UTF8)) } catch { $oldText = '' }
    Assert-Enforce ($oldText.Contains('WATCHDOG_ENFORCEMENT_NOT_IMPLEMENTED')) 'P25 test file still holds the unbound HOLD' ''
    $flagText = ''
    try { $flagText = ([IO.File]::ReadAllText($repoFlags, [Text.Encoding]::UTF8)) } catch { $flagText = '' }
    $flagDoc = $null
    try { $flagDoc = ($flagText | ConvertFrom-Json) } catch { $flagDoc = $null }
    $wdNode = $null
    try { $wdNode = $flagDoc.watchdog } catch { $wdNode = $null }
    Assert-Enforce ((($null -ne $wdNode)) -and ([bool]$wdNode.enabled -eq $true) -and ([bool]$wdNode.shadow -eq $false)) 'production watchdog flag ATIVADA 2026-10-04 {enabled:true,shadow:false}' ''
    $sw11.Stop()
    Assert-Enforce (($sw11.Elapsed.TotalSeconds -lt 90)) 'scenario 11 externally bounded' ([string][int]$sw11.Elapsed.TotalSeconds + 's')

    Write-Host ''
    Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed)
    if ($script:failed -ne 0) { exit 1 }
    exit 0
}
catch {
    Write-Host ("[FAIL] unexpected error: {0}" -f $_)
    $script:failed++
    Write-Host ('[SUMMARY] pass ' + $script:passed + ' fail ' + $script:failed)
    exit 1
}
finally {
    foreach ($p in @($script:enfChildren)) {
        try {
            try { $p.Refresh() } catch { }
            if ((-not $p.HasExited)) { Stop-Process -Id ([int]$p.Id) -Force -ErrorAction SilentlyContinue }
        }
        catch { }
    }
    try { Clear-OrchestrationWatchdogState } catch { }
    try { if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
}
