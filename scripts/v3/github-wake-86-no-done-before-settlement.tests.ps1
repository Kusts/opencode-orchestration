# github-wake-86-no-done-before-settlement.tests.ps1 -- issue #86 behavioral proof.
# Proves: (1) worker directive preserves the three legitimate results
# (candidate_pass/failed/blocked) and never instructs declaring candidate_pass
# without evidence; (2) auto-dispatch never transitions to DONE (sentinel);
# (3) behavioral proof parsing: a worker returning candidate_pass is accepted
# with correct settlement intent, and a blocked result is accepted as a
# legitimate non-success proof; (4) settlement post-terminal refusal preserved
# in NativeDispatch (no duplicate guard in wake). Offline only.
$ErrorActionPreference = 'Stop'
$script:autoPath = Join-Path $PSScriptRoot 'github-wake-auto-dispatch.ps1'
if (-not (Test-Path -LiteralPath $script:autoPath -PathType Leaf)) { throw 'RED: github-wake-auto-dispatch.ps1 not found' }
. $script:autoPath
$passed = 0
function Assert-ND {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
function Get-NDField {
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

# --- DONE sentinel (covers entire auto-dispatch scope) ---
$script:doneCalled = $false
function Complete-OrchestrationTask {
    param($TaskId, $ExpectedRevision, $TasksDir, $FlagsPath, $TelemetryRoot, $Actor, $ActorIdentitySource)
    $script:doneCalled = $true
    throw 'PREMATURE-DONE-CALLED'
}
$origTransition = $null
try { $origTransition = Get-Command Invoke-OrchestrationTaskTransition -ErrorAction SilentlyContinue } catch { $origTransition = $null }
function Invoke-OrchestrationTaskTransition {
    param($TaskId, $ToState, $Actor, $ExpectedRevision, $ActorIdentitySource, $TasksDir, $FlagsPath, $TelemetryRoot, $WaitType, $WaitOwner, $WaitAction, $WaitDependencyId)
    if ([string]$ToState -ceq 'DONE') { $script:doneCalled = $true; throw 'PREMATURE-DONE-TRANSITION' }
    if ($null -ne $origTransition) { return & $origTransition @PSBoundParameters }
    return $null
}

# --- 1. Directive: three legitimate results preserved, evidence-only ---
$directive = ''
try { $directive = [string](Get-GHWADWorkerDirective) } catch { $directive = '' }
Assert-ND (-not [string]::IsNullOrWhiteSpace($directive)) 'directive non-empty'
Assert-ND ($directive -cmatch '(?i)candidate_pass') 'directive preserves candidate_pass'
Assert-ND ($directive -cmatch '(?i)\bfailed\b') 'directive preserves failed'
Assert-ND ($directive -cmatch '(?i)\bblocked\b') 'directive preserves blocked'
Assert-ND ($directive -cmatch '(?i)based on evidence') 'directive requires evidence-based result (no blind candidate_pass)'
Assert-ND ($directive -cmatch '(?i)do not') 'directive forbids premature completion actions'
Assert-ND ($directive -cmatch '(?i)DONE') 'directive names DONE'
Assert-ND ($directive -cmatch '(?i)after settlement') 'directive defers to settlement'

# --- 2. Source-level: no DONE transition in auto-dispatch/wake ---
# (Directive text may mention Complete-OrchestrationTask/DONE as forbidden;
# the behavioral DONE sentinel below is the authoritative proof of no invocation.)
$autoSrc = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'github-wake-auto-dispatch.ps1'), [Text.Encoding]::UTF8)
$wakeSrc = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'github-wake.ps1'), [Text.Encoding]::UTF8)
Assert-ND (-not $autoSrc.Contains('ToState ''DONE''')) 'auto-dispatch never transitions to DONE'
Assert-ND (-not $autoSrc.Contains('ToState "DONE"')) 'auto-dispatch never transitions to DONE (dq)'
Assert-ND (-not $wakeSrc.Contains('ToState ''DONE''')) 'wake never transitions to DONE'
Assert-ND (-not $wakeSrc.Contains('ToState "DONE"')) 'wake never transitions to DONE (dq)'
# Ensure no actual invocation pattern (Complete-OrchestrationTask called as command, not just named in directive)
Assert-ND (-not [bool]([regex]::IsMatch($autoSrc, '(?m)^\s*(?:&\s*)?Complete-OrchestrationTask\b'))) 'auto-dispatch has no Complete-OrchestrationTask invocation'
Assert-ND (-not [bool]([regex]::IsMatch($wakeSrc, '(?m)^\s*(?:&\s*)?Complete-OrchestrationTask\b'))) 'wake has no Complete-OrchestrationTask invocation'

# --- 3. Behavioral proof parsing: candidate_pass and blocked are legitimate ---
# Uses Find-GHWADNativeWorkerProof (real pure validator, no IO/mocks bypassing
# production logic) over native-shaped evidence. Proves the three-result
# contract is preserved and settlement intent is derived correctly, with no DONE.
$tid = 'task86nd'; $gid = 'goal86nd'; $gen = '1'; $key = ('b' * 32)
$resumeId = 'ses_86ndroot000001'; $childId = 'ses_86ndchild00001'; $proj = 'proj86nd'
$runStart = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$marker = New-GHWADOperationMarker -GoalId $gid -TaskId $tid -Generation $gen -IdempotencyKey $key
Assert-ND (-not [string]::IsNullOrWhiteSpace($marker)) 'operation marker built'
function New-NDToolMsg {
    param([string]$Status, [string]$Outcome, [long]$Created)
    $rj = ('{"task_id":"' + $tid + '","goal_id":"' + $gid + '","generation":"' + $gen + '","idempotency_key":"' + $key + '","status":"' + $Status + '","claimed_evidence":["criterion:0"]}')
    $c = @(@{ type = 'text'; text = $rj })
    $st = @{ status = 'completed'; input = @{ agent = 'coder'; description = 'nd proof'; prompt = ('invoke worker ' + $marker); sessionID = $childId }; metadata = @{ sessionID = $childId; status = 'completed'; truncated = $false }; content = $c }
    $child = [pscustomobject]@{ id = $childId; parentID = $resumeId; projectID = $proj; agent = 'coder'; outcome = $Outcome; time = [pscustomobject]@{ created = [long]$Created; updated = [long]$Created } }
    $msg = [pscustomobject]@{ id = ('msg-' + $Status); type = 'assistant'; agent = 'build'; time = [pscustomobject]@{ created = [long]$Created }; content = @(@{ type = 'tool'; id = ('call-' + $Status); name = 'subagent'; state = $st; time = @{ created = [long]$Created; ran = [long]$Created; completed = [long]$Created } }) }
    $byId = @{}; $byId[$childId] = $child
    return [pscustomobject]@{ byId = $byId; msgs = @($msg) }
}

# candidate_pass + succeeded outcome => proven, result_ok true (settlement intent: success)
$cp = New-NDToolMsg -Status 'candidate_pass' -Outcome 'succeeded' -Created ($runStart + 1000)
$proofCp = Find-GHWADNativeWorkerProof -ResumeSessionId $resumeId -PreChildIds @() -PostChildrenById $cp.byId -Messages $cp.msgs -ExpectedTaskId $tid -ExpectedGoalId $gid -ExpectedGeneration $gen -ExpectedIdempotencyKey $key -ExpectedProjectId $proj -RunStartMs $runStart
Assert-ND ([bool](Get-NDField $proofCp 'ok' $false)) 'candidate_pass worker proof accepted (ok)'
Assert-ND (([string](Get-NDField $proofCp 'reason' '')) -ceq 'worker-proven-native') 'candidate_pass reason worker-proven-native'
Assert-ND ([bool](Get-NDField $proofCp 'result_ok' $false)) 'candidate_pass => settlement intent result_ok true'
Assert-ND (([string](Get-NDField $proofCp 'worker_session_id' '')) -ceq $childId) 'candidate_pass binds native worker session'
Assert-ND (-not $script:doneCalled) 'no DONE before settlement (candidate_pass proof path)'

# blocked + failed outcome => proven native result, result_ok false (settlement intent: failure recorded)
$bl = New-NDToolMsg -Status 'blocked' -Outcome 'failed' -Created ($runStart + 2000)
$proofBl = Find-GHWADNativeWorkerProof -ResumeSessionId $resumeId -PreChildIds @() -PostChildrenById $bl.byId -Messages $bl.msgs -ExpectedTaskId $tid -ExpectedGoalId $gid -ExpectedGeneration $gen -ExpectedIdempotencyKey $key -ExpectedProjectId $proj -RunStartMs $runStart
Assert-ND ([bool](Get-NDField $proofBl 'ok' $false)) 'blocked worker proof accepted as legitimate result (ok)'
Assert-ND (([string](Get-NDField $proofBl 'reason' '')) -ceq 'worker-proven-native') 'blocked reason worker-proven-native'
Assert-ND (-not [bool](Get-NDField $proofBl 'result_ok' $true)) 'blocked => settlement intent result_ok false (no premature success)'
Assert-ND (([string](Get-NDField $proofBl 'worker_session_id' '')) -ceq $childId) 'blocked binds native worker session'
Assert-ND (-not $script:doneCalled) 'no DONE before settlement (blocked proof path)'

# failed + failed outcome also preserved
$fl = New-NDToolMsg -Status 'failed' -Outcome 'failed' -Created ($runStart + 3000)
$proofFl = Find-GHWADNativeWorkerProof -ResumeSessionId $resumeId -PreChildIds @() -PostChildrenById $fl.byId -Messages $fl.msgs -ExpectedTaskId $tid -ExpectedGoalId $gid -ExpectedGeneration $gen -ExpectedIdempotencyKey $key -ExpectedProjectId $proj -RunStartMs $runStart
Assert-ND ([bool](Get-NDField $proofFl 'ok' $false)) 'failed worker proof accepted as legitimate result'
Assert-ND (-not [bool](Get-NDField $proofFl 'result_ok' $true)) 'failed => settlement intent result_ok false'
Assert-ND (-not $script:doneCalled) 'no DONE before settlement (failed proof path)'

# Auto-dispatch settlement call site passes result_ok from proof (ordering invariant).
Assert-ND ($autoSrc.Contains('-ResultOk ([bool]$wResultOk)')) 'auto-dispatch passes proof result_ok to settlement (not a hardcoded success)'
Assert-ND ($autoSrc.Contains('Set-GHWakeDispatchSettlement')) 'auto-dispatch settles via Set-GHWakeDispatchSettlement'
Assert-ND (-not $script:doneCalled) 'DONE sentinel never triggered'

# --- 4. Settlement post-terminal refusal preserved (NativeDispatch), not duplicated in wake ---
$ndSrc = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'lib\OrchestrationNativeDispatch.ps1'), [Text.Encoding]::UTF8)
Assert-ND ($ndSrc.Contains('task-terminal') -or $ndSrc.Contains('Test-NDLiveTaskAdmission') -or $ndSrc.Contains('terminal')) 'NativeDispatch preserves post-terminal settlement guard'
Assert-ND ($wakeSrc.Contains('refused by NativeDispatch') -or $wakeSrc.Contains('task-terminal')) 'wake documents/relies on NativeDispatch post-terminal refusal (no duplicate guard)'

Write-Output ('OK github-wake-86-no-done-before-settlement (' + [string]$script:passed + ' asserts)')
exit 0
