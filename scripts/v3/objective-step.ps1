<#!
.SYNOPSIS
    ORFS-F1-STEPCLI: thin cooperative CLI that runs ONE step of the productive
    path WITHOUT replacing the Planner native tool.
.DESCRIPTION
    Two actions, both cooperative and bounded:

      next   : reconcile (live goal re-read) -> next-move -> PREPARE a durable
               reservation, then emit the validated dispatch_intent JSON so the
               Planner itself invokes the native tool (outside PowerShell) and
               later calls back with `settle`. No worker ever runs here.
      settle : validate a DECLARED envelope + DECLARED worker-result as a
               settle CANDIDATE only. Never promotes to canonical settlement:
               no kernel write, no receipt transition, no verification, no
               approval, no DONE, no grants.

    Stores/receipts are used ONLY under explicit caller dirs (-GoalStoreDir,
    -TasksDir, -ReceiptDir, -FlagsPath); repo defaults are never touched.
    Authorization is never synthesized here: it arrives in -AuthorizationFile
    (explicit_allow as a real bool, fencing owner+generation, non-callback
    source) and is only validated by the library gate. Cooperative input is
    data, never authorization (PLAN native Sec.1/Sec.3, divergence B10).

    Output: exactly one bounded JSON envelope on stdout. Exit 0 carries a
    valid observation (whose ok may be false on honest refusal). Exit 1 =
    lib unavailable / internal failure. Exit 2 = invalid args.

    Authority pins on every envelope: grants_authority=false,
    done_approved=false, verified_pass=false. kernel_mutated is true ONLY
    when this call effectively persisted a prepared receipt, proven by a
    before/after diff over the operation's own files (the goal's receipt
    namespace plus activations.jsonl at the explicit ReceiptDir; locks
    excluded, namespace capped at 128 receipts). An idempotent reuse or any
    refusal reports false. When the measurement itself is refused (flooded
    namespace, unreadable path, missing hash), the envelope reports
    conservative unknown (reason snapshot-incomplete, kernel_mutated=true)
    instead of a false negative. Every envelope also reports receipt_written
    and activation_log_written exactly as observed: the library gate
    appends activations.jsonl even on refusals, so a refusal carries
    activation_log_written=true when the append happened. A persisted
    receipt is documented as a reservation, not a settlement.

    Binding (HIGH): the requested -GoalId is compared (exact ordinal) with
    Authorization.goal_id BEFORE any prepare; divergence refuses with the
    stable code authorization-goal-mismatch and zero writes. Declared
    task_id/reference values are validated by canonical format (charset
    [A-Za-z0-9._-], limits 128/160) plus type shape (kernel task shape /
    opaque 32hex reference) and never echoed unless valid; an invalid
    action value is reported as the fixed action unknown.

    Dot-source safe: without -Action this file defines functions and does
    nothing else. PS 5.1 and PS7 compatible. ASCII-only. No network, no
    process spawn, no model calls, no secrets.
#>
param(
    [string]$Action = '',
    [string]$GoalId = '',
    [string]$GoalStoreDir = '',
    [string]$TasksDir = '',
    [string]$ReceiptDir = '',
    [string]$FlagsPath = '',
    [string]$AuthorizationFile = '',
    [string]$IntentFile = '',
    [string]$SessionId = '',
    [string]$EnvelopeFile = '',
    [string]$ResultFile = ''
)

$ErrorActionPreference = 'Stop'

function Get-OSValue {
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

function Read-OSJsonFile {
    param([string]$Path = '')
    try {
        $p = ([string]$Path).Trim()
        if ([string]::IsNullOrWhiteSpace($p)) {
            return [pscustomobject]@{ ok = $false; reason = 'file-missing'; doc = $null }
        }
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
            return [pscustomobject]@{ ok = $false; reason = 'file-missing'; doc = $null }
        }
        $size = [long]0
        try { $size = [long]((Get-Item -LiteralPath $p).Length) } catch { $size = -1 }
        if (($size -le 0) -or ($size -gt 262144)) {
            return [pscustomobject]@{ ok = $false; reason = 'file-unreadable'; doc = $null }
        }
        $raw = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
        $doc = ConvertFrom-Json $raw
        if ($null -eq $doc) {
            return [pscustomobject]@{ ok = $false; reason = 'json-invalid'; doc = $null }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; doc = $doc }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'json-invalid'; doc = $null }
    }
}

function Write-OSEnvelope {
    param($Envelope)
    try {
        Write-Output (ConvertTo-Json -InputObject $Envelope -Depth 10 -Compress)
    }
    catch {
        Write-Output '{"tool":"objective-step.ps1","action":"unknown","ok":false,"reason":"encode-failed","grants_authority":false,"done_approved":false,"verified_pass":false,"kernel_mutated":false}'
    }
}

function New-OSErrorEnvelope {
    param([string]$ActionName = 'unknown', [string]$Reason = 'invalid-args')
    $fixed = ([string]$ActionName).Trim().ToLowerInvariant()
    if (($fixed -cne 'next') -and ($fixed -cne 'settle')) { $fixed = 'unknown' }
    return [pscustomobject][ordered]@{
        tool             = 'objective-step.ps1'
        action           = $fixed
        ok               = $false
        reason           = ([string]$Reason)
        grants_authority = $false
        done_approved    = $false
        verified_pass    = $false
        kernel_mutated   = $false
    }
}

function Test-OSCanonicalToken {
    param([string]$Value = '', [int]$MaxLength = 128)
    try {
        $v = ([string]$Value)
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        if ($v.Length -gt [int]$MaxLength) { return $false }
        return ($v -cmatch '\A[A-Za-z0-9._-]+\z')
    }
    catch { return $false }
}

function Test-OSTaskIdShape {
    param([string]$Value = '')
    try {
        if (-not (Test-OSCanonicalToken -Value ([string]$Value) -MaxLength 128)) { return $false }
        return (([string]$Value) -cmatch '\A[a-z0-9][a-z0-9._-]{2,63}\z')
    }
    catch { return $false }
}

function Test-OSReferenceShape {
    param([string]$Value = '')
    try {
        if (-not (Test-OSCanonicalToken -Value ([string]$Value) -MaxLength 160)) { return $false }
        return (([string]$Value) -cmatch '\A[a-f0-9]{32}\z')
    }
    catch { return $false }
}

function Read-OSFileLen {
    param([string]$Path = '')
    try {
        $p = ([string]$Path).Trim()
        if ([string]::IsNullOrWhiteSpace($p)) { return [long]-1 }
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return [long]-1 }
        return [long]((Get-Item -LiteralPath $p).Length)
    }
    catch { return [long]-2 }
}

function Get-OSOperationFootprint {
    <#
    .SYNOPSIS
        Observes ONLY this operation's files: activations.jsonl at the
        receipt root plus the *.json receipts inside this goal's namespace.
        Never scans the whole tree, so a flooded directory cannot hide the
        receipt or the log from the diff. Listing errors are terminating
        (-ErrorAction Stop, never swallowed): an ACL that denies listing
        while allowing writes refuses the measurement instead of reporting
        a blind empty map. A namespace with more than 128 receipts, an
        unreadable path, or a missing hash helper refuses the measurement
        (ok=false) instead of reporting a false negative.
    #>
    param([string]$ReceiptDir = '', [string]$GoalId = '')
    try {
        $root = ([string]$ReceiptDir).Trim()
        $gid = ([string]$GoalId).Trim()
        if ([string]::IsNullOrWhiteSpace($root) -or [string]::IsNullOrWhiteSpace($gid)) {
            return [pscustomobject]@{ ok = $false; reason = 'snapshot-impossible'; log_len = [long]-1; receipts = @{} }
        }
        $hCmd = Get-Command Get-NativeDispatchHash32 -ErrorAction SilentlyContinue
        if ($null -eq $hCmd) {
            return [pscustomobject]@{ ok = $false; reason = 'snapshot-impossible'; log_len = [long]-1; receipts = @{} }
        }
        $sub = ''
        try { $sub = Get-NativeDispatchHash32 $gid } catch { $sub = '' }
        if ([string]::IsNullOrWhiteSpace($sub)) {
            return [pscustomobject]@{ ok = $false; reason = 'snapshot-impossible'; log_len = [long]-1; receipts = @{} }
        }
        $nsDir = Join-Path $root $sub
        $logLen = Read-OSFileLen -Path (Join-Path $root 'activations.jsonl')
        if ($logLen -eq -2) {
            return [pscustomobject]@{ ok = $false; reason = 'snapshot-impossible'; log_len = [long]-1; receipts = @{} }
        }
        $map = @{}
        if (Test-Path -LiteralPath $nsDir -PathType Container) {
            $n = 0
            foreach ($f in @(Get-ChildItem -LiteralPath $nsDir -File -Filter '*.json' -ErrorAction Stop)) {
                try {
                    if ([string]$f.Name -like '*.lock') { continue }
                    $map[[string]$f.Name] = [long]$f.Length
                    $n++
                    if ($n -gt 128) {
                        return [pscustomobject]@{ ok = $false; reason = 'snapshot-incomplete'; log_len = [long]-1; receipts = @{} }
                    }
                }
                catch {
                    return [pscustomobject]@{ ok = $false; reason = 'snapshot-impossible'; log_len = [long]-1; receipts = @{} }
                }
            }
        }
        return [pscustomobject]@{ ok = $true; reason = ''; log_len = $logLen; receipts = $map }
    }
    catch { return [pscustomobject]@{ ok = $false; reason = 'snapshot-impossible'; log_len = [long]-1; receipts = @{} } }
}

function Compare-OSOperationFootprint {
    param($Before = $null, $After = $null)
    try {
        if (($null -eq $Before) -or (-not [bool]$Before.ok) -or ($null -eq $After) -or (-not [bool]$After.ok)) {
            return [pscustomobject]@{ complete = $false; receipt_written = $false; activation_log_written = $false }
        }
        $bFiles = $Before.receipts
        $aFiles = $After.receipts
        if ($null -eq $bFiles) { $bFiles = @{} }
        if ($null -eq $aFiles) { $aFiles = @{} }
        $receiptWritten = $false
        foreach ($k in @($aFiles.Keys)) {
            $changed = $true
            try {
                if (($bFiles.ContainsKey($k)) -and ([long]$aFiles[$k] -eq [long]$bFiles[$k])) { $changed = $false }
            }
            catch { $changed = $true }
            if ($changed) { $receiptWritten = $true; break }
        }
        $logWritten = ([long]$After.log_len -ne [long]$Before.log_len)
        return [pscustomobject]@{ complete = $true; receipt_written = [bool]$receiptWritten; activation_log_written = [bool]$logWritten }
    }
    catch { return [pscustomobject]@{ complete = $false; receipt_written = $false; activation_log_written = $false } }
}

function New-OSNextEnvelope {
    param([bool]$Ok = $false, [string]$Reason = '', [string]$Goal = '', [long]$Revision = 0, $NextMove = $null, $Intent = $null, $Prepare = $null, [bool]$Mutated = $false, [string]$Move = '', [bool]$ReceiptWritten = $false, [bool]$LogWritten = $false)
    $mutNote = ''
    if ($Mutated) { $mutNote = 'receipt-reservation-not-settlement' }
    return [pscustomobject][ordered]@{
        tool                 = 'objective-step.ps1'
        action               = 'next'
        ok                   = [bool]$Ok
        reason               = ([string]$Reason)
        goal_id              = ([string]$Goal)
        goal_revision        = [long]$Revision
        next_move            = $NextMove
        admitted             = [bool](Get-OSValue $Prepare 'admitted' $false)
        prepare              = $Prepare
        dispatch_intent      = $Intent
        grants_authority     = $false
        done_approved        = $false
        verified_pass        = $false
        kernel_mutated       = [bool]$Mutated
        receipt_written      = [bool]$ReceiptWritten
        activation_log_written = [bool]$LogWritten
        mutation_note        = $mutNote
        planner_note         = 'planner-runs-native-tool-then-settle-candidate'
    }
}

function New-OSSettleEnvelope {
    param([bool]$Ok = $false, [string]$Reason = '', $Candidate = $null)
    return [pscustomobject][ordered]@{
        tool               = 'objective-step.ps1'
        action             = 'settle'
        ok                 = [bool]$Ok
        reason             = ([string]$Reason)
        settle_candidate   = $Candidate
        settlement_promoted = $false
        grants_authority   = $false
        done_approved      = $false
        verified_pass      = $false
        kernel_mutated     = $false
        planner_note       = 'canonical-settlement-stays-on-planner-path'
    }
}

# CLI entrypoint. Runs only when -Action is supplied, so dot-sourcing this
# file as a library defines the functions above and does nothing else.
if (-not [string]::IsNullOrWhiteSpace($Action)) {
    $act = ([string]$Action).Trim().ToLowerInvariant()
    if (($act -cne 'next') -and ($act -cne 'settle')) {
        Write-OSEnvelope (New-OSErrorEnvelope -ActionName $act -Reason 'invalid-action')
        exit 2
    }
    $libDir = Join-Path $PSScriptRoot 'lib'
    $ndLib = Join-Path $libDir 'OrchestrationNativeDispatch.ps1'
    $gkLib = Join-Path $libDir 'OrchestrationGoalKernel.ps1'
    if ((-not (Test-Path -LiteralPath $ndLib -PathType Leaf)) -or (-not (Test-Path -LiteralPath $gkLib -PathType Leaf))) {
        Write-OSEnvelope (New-OSErrorEnvelope -ActionName $act -Reason 'lib-unavailable')
        exit 1
    }
    try { . $ndLib } catch { . $ndLib }
    try { . $gkLib } catch { . $gkLib }
    $needCmds = @('Get-OrchestrationGoal', 'Get-OrchestrationGoalNextMove', 'Invoke-OrchestrationNativeDispatchPrepare', 'Test-OrchestrationDispatchResultShape')
    $libsOk = $true
    foreach ($nc in $needCmds) {
        try {
            if ($null -eq (Get-Command $nc -ErrorAction SilentlyContinue)) { $libsOk = $false; break }
        }
        catch { $libsOk = $false; break }
    }
    if (-not $libsOk) {
        Write-OSEnvelope (New-OSErrorEnvelope -ActionName $act -Reason 'lib-unavailable')
        exit 1
    }

    if ($act -ceq 'next') {
        $gid = ([string]$GoalId).Trim()
        $gDir = ([string]$GoalStoreDir).Trim()
        if ([string]::IsNullOrWhiteSpace($gid) -or [string]::IsNullOrWhiteSpace($gDir) -or (-not (Test-Path -LiteralPath $gDir -PathType Container))) {
            Write-OSEnvelope (New-OSErrorEnvelope -ActionName 'next' -Reason 'invalid-goal-params')
            exit 2
        }
        if ($gid -cnotmatch '\A[A-Za-z0-9._:-]{1,64}\z') {
            Write-OSEnvelope (New-OSErrorEnvelope -ActionName 'next' -Reason 'invalid-goal-params')
            exit 2
        }
        # Reconcile: live re-read of the durable goal; never a stale copy.
        $liveGoal = $null
        $liveRev = [long]0
        try {
            $gslot = Get-OrchestrationGoal -GoalId $gid -StoreDir $gDir
            if (($null -ne $gslot) -and [bool](Get-OSValue $gslot 'ok' $false)) {
                $liveGoal = Get-OSValue $gslot 'goal' $null
            }
        }
        catch { $liveGoal = $null }
        if ($null -eq $liveGoal) {
            Write-OSEnvelope (New-OSNextEnvelope -Ok $false -Reason 'goal-reread-failed' -Goal $gid -Move 'none')
            exit 0
        }
        try { $liveRev = [long](Get-OSValue $liveGoal 'revision' 0) } catch { $liveRev = [long]0 }
        # Next-move: pure controller advice, never an authorization.
        $moveSlot = $null
        try { $moveSlot = Get-OrchestrationGoalNextMove -Goal $liveGoal } catch { $moveSlot = $null }
        if (($null -eq $moveSlot) -or (-not [bool](Get-OSValue $moveSlot 'ok' $false))) {
            $why = 'next-move-failed'
            try {
                $r = ([string](Get-OSValue $moveSlot 'reason' ''))
                if (-not [string]::IsNullOrWhiteSpace($r)) { $why = $r }
            }
            catch { }
            Write-OSEnvelope (New-OSNextEnvelope -Ok $false -Reason $why -Goal $gid -Revision $liveRev -Move 'none')
            exit 0
        }
        $move = Get-OSValue $moveSlot 'next_move' $null
        $moveName = ''
        try { $moveName = (([string](Get-OSValue $move 'move' '')).Trim().ToUpperInvariant()) } catch { $moveName = '' }
        if ($moveName -ceq 'COMPLETE') {
            # Report only: this CLI never completes a goal.
            Write-OSEnvelope (New-OSNextEnvelope -Ok $true -Reason 'goal-complete-no-dispatch' -Goal $gid -Revision $liveRev -NextMove $move -Move 'COMPLETE')
            exit 0
        }
        if (($moveName -cne 'CONTINUE') -and ($moveName -cne 'RETRY')) {
            Write-OSEnvelope (New-OSNextEnvelope -Ok $true -Reason 'move-needs-no-dispatch' -Goal $gid -Revision $liveRev -NextMove $move -Move $moveName)
            exit 0
        }
        # Dispatch branch: every store/input must be explicit from the caller.
        $tDir = ([string]$TasksDir).Trim()
        $rDir = ([string]$ReceiptDir).Trim()
        $fPath = ([string]$FlagsPath).Trim()
        $aFile = ([string]$AuthorizationFile).Trim()
        $iFile = ([string]$IntentFile).Trim()
        $sid = ([string]$SessionId).Trim()
        if ([string]::IsNullOrWhiteSpace($tDir) -or [string]::IsNullOrWhiteSpace($rDir) -or [string]::IsNullOrWhiteSpace($fPath) -or [string]::IsNullOrWhiteSpace($aFile) -or [string]::IsNullOrWhiteSpace($iFile) -or [string]::IsNullOrWhiteSpace($sid)) {
            Write-OSEnvelope (New-OSErrorEnvelope -ActionName 'next' -Reason 'invalid-dispatch-params')
            exit 2
        }
        $authSlot = Read-OSJsonFile -Path $aFile
        if (-not [bool]$authSlot.ok) {
            Write-OSEnvelope (New-OSErrorEnvelope -ActionName 'next' -Reason ('invalid-authorization-file:' + [string]$authSlot.reason))
            exit 2
        }
        $intentSlot = Read-OSJsonFile -Path $iFile
        if (-not [bool]$intentSlot.ok) {
            Write-OSEnvelope (New-OSErrorEnvelope -ActionName 'next' -Reason ('invalid-intent-file:' + [string]$intentSlot.reason))
            exit 2
        }
        # Binding: the authorization must name EXACTLY the consulted goal.
        # Compared by exact ordinal BEFORE any prepare; divergence refuses
        # with a stable code and zero writes (the foreign id is never
        # echoed). The library gate still owns admission of everything else.
        $authGoal = ([string](Get-OSValue $authSlot.doc 'goal_id' '')).Trim()
        if ($authGoal -cne $gid) {
            Write-OSEnvelope (New-OSNextEnvelope -Ok $false -Reason 'authorization-goal-mismatch' -Goal $gid -Revision $liveRev -NextMove $move -Move $moveName)
            exit 0
        }
        # Footprint BEFORE the only write this CLI ever performs, taken on
        # the operation's own files only (receipt namespace + activation
        # log). When the measurement itself is refused (flooded namespace,
        # unreadable path), the envelope reports conservative unknown
        # below instead of a false negative.
        $fpBefore = Get-OSOperationFootprint -ReceiptDir $rDir -GoalId $gid
        # PREPARE persists the durable reservation. The worker runs later,
        # outside PowerShell, when the Planner invokes its native tool with
        # dispatch_intent below.
        $prep = $null
        try {
            $prep = Invoke-OrchestrationNativeDispatchPrepare -Intent $intentSlot.doc -Authorization $authSlot.doc -SessionId $sid -ReceiptDir $rDir -GoalStoreDir $gDir -TasksDir $tDir -FlagsPath $fPath
        }
        catch { $prep = $null }
        $fpAfter = Get-OSOperationFootprint -ReceiptDir $rDir -GoalId $gid
        $fpDiff = Compare-OSOperationFootprint -Before $fpBefore -After $fpAfter
        $prepOk = (($null -ne $prep) -and ([bool](Get-OSValue $prep 'ok' $false)))
        $intentOut = Get-OSValue $prep 'intent' $null
        $prepView = $null
        if ($prepOk) {
            $prepView = [pscustomobject][ordered]@{
                admitted             = [bool](Get-OSValue $prep 'admitted' $false)
                reused               = [bool](Get-OSValue $prep 'reused' $false)
                phase                = ([string](Get-OSValue $prep 'phase' ''))
                reference            = ([string](Get-OSValue $prep 'reference' ''))
                intent_fingerprint   = ([string](Get-OSValue $prep 'intent_fingerprint' ''))
                prepared_fingerprint = ([string](Get-OSValue $prep 'prepared_fingerprint' ''))
                session_id           = ([string](Get-OSValue $prep 'session_id' ''))
                task_id              = ([string](Get-OSValue $prep 'task_id' ''))
                agent                = ([string](Get-OSValue $prep 'agent' ''))
                executor_calls       = [int](Get-OSValue $prep 'executor_calls' 0)
            }
        }
        if (-not [bool]$fpDiff.complete) {
            # Measurement refused: report conservative unknown. The outcome
            # (prepare view / refusal) is still carried, but mutation is
            # assumed, never denied.
            if ($prepOk) {
                Write-OSEnvelope (New-OSNextEnvelope -Ok $true -Reason 'snapshot-incomplete' -Goal $gid -Revision $liveRev -NextMove $move -Intent $intentOut -Prepare $prepView -Mutated $true -Move $moveName -ReceiptWritten $false -LogWritten $false)
            }
            else {
                Write-OSEnvelope (New-OSNextEnvelope -Ok $false -Reason 'snapshot-incomplete' -Goal $gid -Revision $liveRev -NextMove $move -Move $moveName -Mutated $true -ReceiptWritten $false -LogWritten $false)
            }
            exit 0
        }
        if (($null -eq $prep) -or (-not [bool](Get-OSValue $prep 'ok' $false))) {
            $why = 'prepare-refused'
            try {
                $r = ([string](Get-OSValue $prep 'reason' ''))
                if (-not [string]::IsNullOrWhiteSpace($r)) { $why = $r }
            }
            catch { }
            Write-OSEnvelope (New-OSNextEnvelope -Ok $false -Reason $why -Goal $gid -Revision $liveRev -NextMove $move -Move $moveName -ReceiptWritten ([bool]$fpDiff.receipt_written) -LogWritten ([bool]$fpDiff.activation_log_written))
            exit 0
        }
        $intentOut = Get-OSValue $prep 'intent' $null
        Write-OSEnvelope (New-OSNextEnvelope -Ok $true -Reason 'prepared-awaits-planner-tool' -Goal $gid -Revision $liveRev -NextMove $move -Intent $intentOut -Prepare $prepView -Mutated ([bool]$fpDiff.receipt_written) -Move $moveName -ReceiptWritten ([bool]$fpDiff.receipt_written) -LogWritten ([bool]$fpDiff.activation_log_written))
        exit 0
    }
    else {
        # settle: candidate validation only. The declared envelope and the
        # declared worker-result are checked for shape and binding; nothing
        # is written, promoted, verified, approved or completed here.
        $eFile = ([string]$EnvelopeFile).Trim()
        $resFile = ([string]$ResultFile).Trim()
        if ([string]::IsNullOrWhiteSpace($eFile) -or [string]::IsNullOrWhiteSpace($resFile)) {
            Write-OSEnvelope (New-OSErrorEnvelope -ActionName 'settle' -Reason 'invalid-settle-params')
            exit 2
        }
        $envSlot = Read-OSJsonFile -Path $eFile
        if (-not [bool]$envSlot.ok) {
            Write-OSEnvelope (New-OSErrorEnvelope -ActionName 'settle' -Reason ('invalid-envelope-file:' + [string]$envSlot.reason))
            exit 2
        }
        $resSlot = Read-OSJsonFile -Path $resFile
        if (-not [bool]$resSlot.ok) {
            Write-OSEnvelope (New-OSErrorEnvelope -ActionName 'settle' -Reason ('invalid-result-file:' + [string]$resSlot.reason))
            exit 2
        }
        $env = $envSlot.doc
        $envIntent = Get-OSValue $env 'dispatch_intent' $null
        $envPrep = Get-OSValue $env 'prepare' $null
        $candTask = ([string](Get-OSValue $env 'task_id' ''))
        if ([string]::IsNullOrWhiteSpace($candTask) -and ($null -ne $envIntent)) {
            $candTask = ([string](Get-OSValue $envIntent 'task_id' ''))
        }
        $candKey = ([string](Get-OSValue $env 'idempotency_key' ''))
        if ([string]::IsNullOrWhiteSpace($candKey) -and ($null -ne $envIntent)) {
            $candKey = ([string](Get-OSValue $envIntent 'idempotency_key' ''))
        }
        $candRef = ([string](Get-OSValue $env 'reference' ''))
        if ([string]::IsNullOrWhiteSpace($candRef) -and ($null -ne $envPrep)) {
            $candRef = ([string](Get-OSValue $envPrep 'reference' ''))
        }
        $candFp = ([string](Get-OSValue $env 'prepared_fingerprint' ''))
        if ([string]::IsNullOrWhiteSpace($candFp) -and ($null -ne $envPrep)) {
            $candFp = ([string](Get-OSValue $envPrep 'prepared_fingerprint' ''))
        }
        # Declared values are validated by canonical format (charset
        # [A-Za-z0-9._-], limits 128/160) plus type shape (kernel task shape
        # for task_id, opaque 32hex for reference); anything else refuses as
        # envelope-unbound WITHOUT echoing the offending value.
        if ((-not (Test-OSTaskIdShape -Value $candTask)) -or ($candKey -cnotmatch '\A[a-f0-9]{32}\z') -or (-not (Test-OSReferenceShape -Value $candRef)) -or ($candFp -cnotmatch '\A[a-f0-9]{32}\z')) {
            Write-OSEnvelope (New-OSSettleEnvelope -Ok $false -Reason 'envelope-unbound')
            exit 0
        }
        $shape = $null
        try { $shape = Test-OrchestrationDispatchResultShape -Result $resSlot.doc } catch { $shape = $null }
        if (($null -eq $shape) -or (-not [bool](Get-OSValue $shape 'ok' $false))) {
            $why = 'status-not-allowed-from-worker'
            try {
                $r = ([string](Get-OSValue $shape 'reason' ''))
                if (-not [string]::IsNullOrWhiteSpace($r)) { $why = $r }
            }
            catch { }
            Write-OSEnvelope (New-OSSettleEnvelope -Ok $false -Reason $why)
            exit 0
        }
        $cand = [pscustomobject][ordered]@{
            task_id              = $candTask
            idempotency_key      = ($candKey.ToLowerInvariant())
            reference            = $candRef
            prepared_fingerprint = ($candFp.ToLowerInvariant())
            worker_status        = ([string](Get-OSValue $shape 'status' ''))
            claimed_evidence     = @((Get-OSValue $shape 'claimed_evidence' @()))
        }
        Write-OSEnvelope (New-OSSettleEnvelope -Ok $true -Reason 'settle-candidate-ready' -Candidate $cand)
        exit 0
    }
}
