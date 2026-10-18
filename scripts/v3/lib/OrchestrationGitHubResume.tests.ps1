<#!
.SYNOPSIS
    Tests for lib/OrchestrationGitHubResume.ps1 (P0-05 resume caller).
.DESCRIPTION
    Hermetic: temp dirs under the user temp for the waits store, cleanup in
    finally; the repo tree is never written. Offline only (no network, no gh,
    no spawn): snapshots are built in-memory in the normalized shape owned by
    OrchestrationDelivery, readiness comes from the pure Delivery function.
    Covers: contract persistence without tokens/transcripts, verde->RESUME,
    vermelho->TERMINAL diagnostic, review-changes, novo-commit-invalida,
    duplicado, fora-de-ordem, restart (rehydrate from disk), PR-fechado,
    cancel, executor-ausente (READY, never false success), lease/auth gates,
    deadline/retry-budget, single-shot shape (no daemon/watcher/loop),
    policy-divergence gate (contrato vs policy efetiva), hash-derived
    filenames sem overwrite silencioso, optimistic CAS em Confirm/Register.
    Custom PS 5.1 / PS7 suite, no Pester. ASCII only.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationGitHubResume.ps1')

$script:passed = 0
function Assert-That {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}

$libText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'OrchestrationGitHubResume.ps1'), [Text.Encoding]::UTF8)
foreach ($bad in @('Start-Sleep', 'System.Timers', 'Register-ObjectEvent', 'Register-Scheduled', 'Start-Job', 'New-Service', 'Start-Service', 'FileSystemWatcher', 'Invoke-RestMethod', 'Invoke-WebRequest', 'Invoke-Expression', 'Start-Process', 'while\s*\(', 'for\s*\(', 'gh pr merge', 'gh pr create', 'gh pr comment', 'gh pr edit', 'gh pr close', '--method POST', '--method PUT', 'grants_authority = \$true', 'done_approved = \$true', 'merge_authority = \$true', 'kernel_mutated = \$true', 'GH_TOKEN', 'GITHUB_TOKEN', 'C:\\Users', 'function Get-OrchestrationGitHubReadiness')) {
    Assert-That ($libText -cnotmatch $bad) ('lib has no daemon/mutation/secret/readiness-dup pattern: ' + $bad)
}
Assert-That ($libText -cmatch 'OrchestrationDelivery\.ps1') 'lib references OrchestrationDelivery (readiness reuse)'
Assert-That ($libText -cmatch 'Get-OrchestrationGitHubReadiness') 'lib calls pure Delivery readiness (never reimplements)'
Assert-That ($null -ne (Get-Command Register-OrchestrationGitHubWait -ErrorAction SilentlyContinue)) 'dot-source exposes Register'
Assert-That ($null -ne (Get-Command Test-OrchestrationGitHubResume -ErrorAction SilentlyContinue)) 'dot-source exposes Test'
Assert-That ($null -ne (Get-Command Confirm-OrchestrationGitHubResumeApplied -ErrorAction SilentlyContinue)) 'dot-source exposes Confirm'
Assert-That ($null -ne (Get-Command Get-OrchestrationGitHubWaits -ErrorAction SilentlyContinue)) 'dot-source exposes rehydrate list'
Assert-That ($null -ne (Get-Command Get-OrchestrationGitHubResumeDedupKey -ErrorAction SilentlyContinue)) 'dot-source exposes dedup key'

$v = Get-OrchestrationGitHubResumeVersion
Assert-That (([long]$v.schema_version -eq 1) -and ([string]$v.phase -ceq 'P0-05')) 'version schema 1 phase P0-05'

$SHA_A = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$SHA_B = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$SHA_C = 'cccccccccccccccccccccccccccccccccccccccc'
$REPO = 'acme/widgets'
$PR = 42
$GEN = 3
$NOW = '2026-10-10T12:02:00Z'
$FUTURE = '2026-10-11T00:00:00Z'
$PAST = '2026-10-09T00:00:00Z'
$PolicyPath = Join-Path $PSScriptRoot '..\..\..\source\registry\delivery-policy.json'
$policy = ConvertFrom-Json ([IO.File]::ReadAllText([IO.Path]::GetFullPath($PolicyPath)))

function New-TCheck {
    param([string]$Name, [string]$Status, $Conclusion, [string]$Sha)
    return [pscustomobject]@{ name = $Name; head_sha = $Sha; status = $Status; conclusion = $Conclusion }
}
function New-TSnap {
    param($Head, $Commit, [string]$State = 'OPEN', [string]$Merge = 'MERGEABLE', [string]$Review = 'APPROVED', $Checks = @(), [bool]$Complete = $true, [string]$ObservedAt = $script:NOW)
    return [pscustomobject]@{
        repository = $script:REPO; pr_number = $script:PR
        head_sha = $Head; commit_sha = $Commit; observed_at = $ObservedAt
        pr_state = $State; mergeable = $Merge; review_decision = $Review
        checks_complete = $Complete; checks = @($Checks)
    }
}
function New-TGreenChecks {
    param([string]$Sha)
    $out = New-Object System.Collections.ArrayList
    foreach ($n in @($policy.required_checks)) {
        [void]$out.Add((New-TCheck ([string]$n) 'COMPLETED' 'success' $Sha))
    }
    return @($out.ToArray())
}
function New-TWait {
    param([string]$WaitsDir, [string]$Head = $script:SHA_A, [long]$Gen = $script:GEN, [string]$Deadline = $script:FUTURE, [long]$Budget = 5)
    return (Register-OrchestrationGitHubWait -WaitsDir $WaitsDir -ObjectiveId 'obj-1' -TaskId 'task.alpha-1' -RunId 'run-1' -Generation $Gen -Repository $script:REPO -PrNumber $script:PR -Branch 'fix/x' -ExpectedHeadSha $Head -RequiredChecks @($policy.required_checks) -ReviewExpectation 'APPROVED' -Cursor '' -DeadlineUtc $Deadline -RetryBudgetMax $Budget -LeaseOwner 'planner-1' -LeaseExpiresUtc $script:FUTURE -Owner 'planner-1')
}
function Invoke-TTest {
    param($Wait, $Snap, [bool]$Lease = $true, [bool]$Owner = $true, [bool]$Auth = $true, [bool]$Exec = $true, [bool]$Cancel = $false, [bool]$Applied = $false, [string]$EventKey = '', $Policy = $null)
    $pol = $Policy
    if ($null -eq $pol) { $pol = $script:policy }
    return (Test-OrchestrationGitHubResume -Wait $Wait -Snapshot $Snap -Policy $pol -NowUtc $script:NOW -MaxAgeSeconds 300 -LeaseAlive $Lease -OwnerAlive $Owner -AuthorizationAlive $Auth -ExecutorPresent $Exec -CancelRequested $Cancel -AlreadyApplied $Applied -EventDedupKey $EventKey)
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ghrs-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
try {
    # --- dedup key: canonical, fail-closed.
    $dk = Get-OrchestrationGitHubResumeDedupKey -Repository $REPO -PrNumber $PR -HeadSha $SHA_A -Generation $GEN
    Assert-That (([bool]$dk.ok) -and ([string]$dk.dedup_key -ceq ('github-resume:v1:' + $REPO + ':' + $PR + ':' + $SHA_A + ':' + $GEN))) 'dedup key canonical (repo,pr,head,generation)'
    $dkBad = Get-OrchestrationGitHubResumeDedupKey -Repository $REPO -PrNumber $PR -HeadSha 'zzz' -Generation $GEN
    Assert-That ((-not [bool]$dkBad.ok) -and ([string]$dkBad.reason -ceq 'invalid-head-sha')) 'dedup key rejects bad sha'

    # --- register: persists contract, no tokens/transcripts.
    $wd = Join-Path $root 'waits'
    $r = New-TWait -WaitsDir $wd
    Assert-That (([bool]$r.ok) -and (-not [bool]$r.reused) -and ([string]$r.reason -ceq 'registered')) 'register ok, not reused'
    Assert-That (([string]$r.wait.wait_state -ceq 'waiting') -and ([long]$r.wait.schema_version -eq 1)) 'contract carries waiting state + schema 1'
    Assert-That (([string]$r.wait.objective_id -ceq 'obj-1') -and ([string]$r.wait.task_id -ceq 'task.alpha-1') -and ([string]$r.wait.run_id -ceq 'run-1') -and ([long]$r.wait.generation -eq $GEN)) 'contract binds objective/task/run/generation'
    Assert-That (([string]$r.wait.repository -ceq $REPO) -and ([long]$r.wait.pr_number -eq $PR) -and ([string]$r.wait.branch -ceq 'fix/x') -and ([string]$r.wait.expected_head_sha -ceq $SHA_A)) 'contract binds repo/pr/branch/head_sha'
    Assert-That ((@($r.wait.required_checks).Count -eq 5) -and ([string]$r.wait.review_expectation -ceq 'APPROVED')) 'contract carries checks + review expectation'
    Assert-That ((-not [bool]$r.kernel_mutated) -and (-not [bool]$r.grants_authority) -and (-not [bool]$r.done_approved)) 'register grants zero authority'
    $text = [IO.File]::ReadAllText($r.wait_file, [Text.Encoding]::UTF8)
    Assert-That (($text -cnotmatch 'ghp_') -and ($text -cnotmatch 'github_pat_') -and ($text -cnotmatch 'xox-') -and ($text -cnotmatch '(?i)token')) 'contract file carries no tokens'
    Assert-That (($text -cnotmatch 'transcript') -and ($text -cnotmatch 'stdout') -and ($text -cnotmatch 'stderr')) 'contract file carries no transcripts/streams'
    Assert-That ((Test-Path -LiteralPath $r.wait_file -PathType Leaf) -and ([string]$r.dedup_key -ceq [string]$dk.dedup_key)) 'wait file on disk with dedup key'

    # --- register twice: idempotent, no duplicate effect.
    $before = [IO.File]::ReadAllText($r.wait_file, [Text.Encoding]::UTF8)
    $r2 = New-TWait -WaitsDir $wd
    Assert-That (([bool]$r2.ok) -and ([bool]$r2.reused) -and ([string]$r2.wait_file -ceq [string]$r.wait_file)) 'duplicate register reuses same file'
    $after = [IO.File]::ReadAllText($r.wait_file, [Text.Encoding]::UTF8)
    Assert-That ($before -ceq $after) 'duplicate register leaves file byte-identical'

    # --- different head / generation: distinct waits.
    $wd2 = Join-Path $root 'waits2'
    $rb = New-TWait -WaitsDir $wd2 -Head $SHA_B
    Assert-That (([bool]$rb.ok) -and (-not [bool]$rb.reused) -and ([string]$rb.dedup_key -cne [string]$r.dedup_key)) 'new commit head gets a distinct wait'
    $rg = New-TWait -WaitsDir $wd2 -Gen ($GEN + 1)
    Assert-That (([bool]$rg.ok) -and (-not [bool]$rg.reused)) 'new generation gets a distinct wait'

    # --- invalid register inputs fail closed.
    $badSha = Register-OrchestrationGitHubWait -WaitsDir (Join-Path $root 'wbad') -ObjectiveId 'obj-1' -TaskId 'task.alpha-1' -RunId 'run-1' -Generation $GEN -Repository $REPO -PrNumber $PR -Branch 'fix/x' -ExpectedHeadSha 'zzz' -RequiredChecks @() -ReviewExpectation 'APPROVED' -Cursor '' -DeadlineUtc $FUTURE -RetryBudgetMax 5 -LeaseOwner 'planner-1' -LeaseExpiresUtc $FUTURE -Owner 'planner-1'
    Assert-That ((-not [bool]$badSha.ok) -and ([string]$badSha.reason -ceq 'invalid-head-sha')) 'register rejects bad sha'
    $evil = Register-OrchestrationGitHubWait -WaitsDir (Join-Path $root 'wevil') -ObjectiveId 'obj-1' -TaskId 'task.alpha-1' -RunId 'run-1' -Generation $GEN -Repository $REPO -PrNumber $PR -Branch 'fix/x' -ExpectedHeadSha $SHA_A -RequiredChecks @() -ReviewExpectation 'APPROVED' -Cursor 'ghp_SYNTHETIC-9f8e-tail' -DeadlineUtc $FUTURE -RetryBudgetMax 5 -LeaseOwner 'planner-1' -LeaseExpiresUtc $FUTURE -Owner 'planner-1'
    Assert-That ((-not [bool]$evil.ok) -and ([string]$evil.reason -ceq 'secret-refused')) 'register refuses secret-like cursor (never persisted)'

    # --- verde -> RESUME (executor presente).
    $green = New-TSnap -Head $SHA_A -Commit $SHA_A -Checks (New-TGreenChecks -Sha $SHA_A)
    $t = Invoke-TTest -Wait $r.wait -Snap $green
    Assert-That (([string]$t.decision -ceq 'RESUME') -and [bool]$t.ok -and [bool]$t.resume_authorized) 'verde => RESUME autorizado'
    Assert-That ((-not [bool]$t.grants_authority) -and (-not [bool]$t.done_approved) -and (-not [bool]$t.merge_authority) -and (-not [bool]$t.kernel_mutated)) 'RESUME grants zero kernel/merge authority'
    Assert-That (([string]$t.readiness -ceq 'READY_FOR_RESUME') -and ([string]$t.observed_head_sha -ceq $SHA_A)) 'RESUME binds observed head to expected'

    # --- executor ausente -> READY, sem auto-avanco (nunca falso sucesso).
    $tNoExec = Invoke-TTest -Wait $r.wait -Snap $green -Exec $false
    Assert-That (([string]$tNoExec.decision -ceq 'READY') -and [bool]$tNoExec.ok -and (-not [bool]$tNoExec.resume_authorized)) 'executor ausente => READY sem resume_authorized'
    Assert-That (([string]$tNoExec.reason -ceq 'ready-no-executor') -and ([string]$tNoExec.notify -cmatch 'ready-no-executor')) 'READY carrega notificacao clara ao Planner'

    # --- vermelho (CI) -> TERMINAL diagnostico.
    $redChecks = New-TGreenChecks -Sha $SHA_A
    $redChecks[1] = New-TCheck ([string]$policy.required_checks[1]) 'COMPLETED' 'failure' $SHA_A
    $red = New-TSnap -Head $SHA_A -Commit $SHA_A -Checks $redChecks
    $tRed = Invoke-TTest -Wait $r.wait -Snap $red
    Assert-That (([string]$tRed.decision -ceq 'TERMINAL') -and ([string]$tRed.reason -ceq 'diagnostic')) 'CI vermelho => TERMINAL diagnostic'
    Assert-That ((@($tRed.reasons) -contains ('check-failed:' + [string]$policy.required_checks[1])) -and (-not [bool]$tRed.resume_authorized)) 'diagnostico cita o check exato, sem autorizacao'

    # --- review changes-requested -> TERMINAL diagnostico.
    $rc = New-TSnap -Head $SHA_A -Commit $SHA_A -Review 'CHANGES_REQUESTED' -Checks (New-TGreenChecks -Sha $SHA_A)
    $tRc = Invoke-TTest -Wait $r.wait -Snap $rc
    Assert-That (([string]$tRc.decision -ceq 'TERMINAL') -and (@($tRc.reasons) -contains 'changes-requested')) 'review-changes => TERMINAL com motivo'

    # --- novo commit invalida a espera (head-mismatch -> TERMINAL head-superseded).
    $staleSnap = New-TSnap -Head $SHA_B -Commit $SHA_B -Checks (New-TGreenChecks -Sha $SHA_B)
    $tStale = Invoke-TTest -Wait $r.wait -Snap $staleSnap
    Assert-That (([string]$tStale.decision -ceq 'TERMINAL') -and ([string]$tStale.reason -ceq 'head-superseded')) 'novo commit => TERMINAL head-superseded (re-registro exigido)'

    # --- checks pendentes -> KEEP_WAITING.
    $pendChecks = New-TGreenChecks -Sha $SHA_A
    $pendChecks[0] = New-TCheck ([string]$policy.required_checks[0]) 'IN_PROGRESS' $null $SHA_A
    $pend = New-TSnap -Head $SHA_A -Commit $SHA_A -Checks $pendChecks
    $tPend = Invoke-TTest -Wait $r.wait -Snap $pend
    Assert-That (([string]$tPend.decision -ceq 'KEEP_WAITING') -and (-not [bool]$tPend.resume_authorized)) 'checks pending => KEEP_WAITING sem autorizacao'

    # --- PR fechado -> TERMINAL pr-terminal.
    $closed = New-TSnap -Head $SHA_A -Commit $SHA_A -State 'CLOSED' -Checks (New-TGreenChecks -Sha $SHA_A)
    $tClosed = Invoke-TTest -Wait $r.wait -Snap $closed
    Assert-That (([string]$tClosed.decision -ceq 'TERMINAL') -and ([string]$tClosed.reason -ceq 'pr-terminal')) 'PR fechado => TERMINAL pr-terminal'

    # --- cancel explicito -> TERMINAL cancelled.
    $tCancel = Invoke-TTest -Wait $r.wait -Snap $green -Cancel $true
    Assert-That (([string]$tCancel.decision -ceq 'TERMINAL') -and ([string]$tCancel.reason -ceq 'cancelled')) 'cancel => TERMINAL cancelled'

    # --- lease/owner/autorizacao mortas bloqueiam RESUME.
    $tLease = Invoke-TTest -Wait $r.wait -Snap $green -Lease $false
    Assert-That (([string]$tLease.decision -ceq 'TERMINAL') -and ([string]$tLease.reason -ceq 'lease-expired')) 'lease morta => TERMINAL lease-expired'
    $tOwner = Invoke-TTest -Wait $r.wait -Snap $green -Owner $false
    Assert-That (([string]$tOwner.decision -ceq 'TERMINAL') -and ([string]$tOwner.reason -ceq 'owner-mismatch')) 'owner divergente => TERMINAL owner-mismatch'
    $tAuth = Invoke-TTest -Wait $r.wait -Snap $green -Auth $false
    Assert-That (([string]$tAuth.decision -ceq 'TERMINAL') -and ([string]$tAuth.reason -ceq 'authorization-revoked')) 'autorizacao revogada => TERMINAL'

    # --- deadline estourado / retry budget esgotado.
    $wPast = New-TWait -WaitsDir (Join-Path $root 'wpast') -Deadline $PAST
    $tPast = Invoke-TTest -Wait $wPast.wait -Snap $green
    Assert-That (([string]$tPast.decision -ceq 'TERMINAL') -and ([string]$tPast.reason -ceq 'wait-expired')) 'deadline passado => TERMINAL wait-expired'
    $wZero = New-TWait -WaitsDir (Join-Path $root 'wzero') -Budget 0
    $tZero = Invoke-TTest -Wait $wZero.wait -Snap $pend
    Assert-That (([string]$tZero.decision -ceq 'TERMINAL') -and ([string]$tZero.reason -ceq 'retry-budget-exhausted')) 'budget 0 com pendencia => TERMINAL retry-budget-exhausted'
    $tZeroGreen = Invoke-TTest -Wait $wZero.wait -Snap $green
    Assert-That ([string]$tZeroGreen.decision -ceq 'RESUME') 'budget nao bloqueia sucesso (so a espera continuada)'

    # --- evento duplicado nao duplica efeito (Confirm idempotente).
    $c1 = Confirm-OrchestrationGitHubResumeApplied -WaitsDir $wd -DedupKey ([string]$r.dedup_key) -EventId 'evt-1'
    Assert-That (([bool]$c1.ok) -and (-not [bool]$c1.reused) -and ([string]$c1.reason -ceq 'applied')) 'primeiro evento aplica'
    $fBefore = [IO.File]::ReadAllText($r.wait_file, [Text.Encoding]::UTF8)
    $c2 = Confirm-OrchestrationGitHubResumeApplied -WaitsDir $wd -DedupKey ([string]$r.dedup_key) -EventId 'evt-1'
    Assert-That (([bool]$c2.ok) -and ([bool]$c2.reused) -and ([string]$c2.reason -ceq 'duplicate-suppressed')) 'evento duplicado suprimido'
    $fAfter = [IO.File]::ReadAllText($r.wait_file, [Text.Encoding]::UTF8)
    Assert-That ($fBefore -ceq $fAfter) 'duplicado nao reescreve o arquivo (nenhum efeito duplo)'
    $tDup = Invoke-TTest -Wait $c2.wait -Snap $green -Applied $true
    Assert-That ([string]$tDup.decision -ceq 'DUPLICATE_NOOP') 'AlreadyApplied => DUPLICATE_NOOP'

    # --- evento fora-de-ordem (outra geracao) nao avanca.
    $tOoo = Invoke-TTest -Wait $r.wait -Snap $green -EventKey ([string]$rb.dedup_key)
    Assert-That (([string]$tOoo.decision -ceq 'OUT_OF_ORDER') -and (-not [bool]$tOoo.resume_authorized)) 'evento de outra geracao => OUT_OF_ORDER sem efeito'

    # --- restart: reidrata waits do disco (nova sessao).
    $reh = Get-OrchestrationGitHubWaits -WaitsDir $wd
    Assert-That (([bool]$reh.ok) -and (@($reh.waits).Count -eq 1) -and ([string]$reh.waits[0].dedup_key -ceq [string]$r.dedup_key)) 'restart reidrata a espera do disco'
    $tReh = Invoke-TTest -Wait $reh.waits[0] -Snap $green
    Assert-That ([string]$tReh.decision -ceq 'RESUME') 'espera reidratada decide RESUME no verde'

    # --- FINDING 1: contrato persistido vs policy efetiva (fail-closed).
    $divPolicy = ConvertFrom-Json (ConvertTo-Json $policy -Depth 10 -Compress)
    $divPolicy.required_checks = @(@($policy.required_checks) + @('CI (extra-sintetico)'))
    $tDiv = Invoke-TTest -Wait $r.wait -Snap $green -Policy $divPolicy
    Assert-That (([string]$tDiv.decision -ceq 'INVALID') -and (-not [bool]$tDiv.ok) -and (-not [bool]$tDiv.resume_authorized)) 'checks divergentes da policy => INVALID sem autorizacao'
    Assert-That (([string]$tDiv.reason -ceq 'policy-diverged') -and (@($tDiv.reasons) -contains 'policy-diverged')) 'divergencia de checks relata policy-diverged'
    $shortPolicy = ConvertFrom-Json (ConvertTo-Json $policy -Depth 10 -Compress)
    $shortPolicy.required_checks = @(@($policy.required_checks)[0..3])
    $tShort = Invoke-TTest -Wait $r.wait -Snap $green -Policy $shortPolicy
    Assert-That (([string]$tShort.decision -ceq 'INVALID') -and ([string]$tShort.reason -ceq 'policy-diverged') -and (-not [bool]$tShort.resume_authorized)) 'policy com checks a menos => INVALID policy-diverged'
    $badPol = ConvertFrom-Json '{"schema_version":1}'
    $tBadPol = Invoke-TTest -Wait $r.wait -Snap $green -Policy $badPol
    Assert-That (([string]$tBadPol.decision -ceq 'INVALID') -and ([string]$tBadPol.reason -ceq 'policy-invalid') -and (-not [bool]$tBadPol.resume_authorized)) 'policy inelegivel => INVALID policy-invalid'
    $wAny = Register-OrchestrationGitHubWait -WaitsDir (Join-Path $root 'wany') -ObjectiveId 'obj-1' -TaskId 'task.alpha-1' -RunId 'run-1' -Generation ($GEN + 10) -Repository $REPO -PrNumber $PR -Branch 'fix/x' -ExpectedHeadSha $SHA_A -RequiredChecks @($policy.required_checks) -ReviewExpectation 'ANY' -Cursor '' -DeadlineUtc $FUTURE -RetryBudgetMax 5 -LeaseOwner 'planner-1' -LeaseExpiresUtc $FUTURE -Owner 'planner-1'
    Assert-That ([bool]$wAny.ok) 'wait ANY registra (expectativa mais fraca que a policy)'
    $tAny = Invoke-TTest -Wait $wAny.wait -Snap $green
    Assert-That (([string]$tAny.decision -ceq 'INVALID') -and ([string]$tAny.reason -ceq 'policy-diverged') -and (-not [bool]$tAny.resume_authorized)) 'ANY sob policy que exige approval => INVALID policy-diverged'

    # --- FINDING 2: nome deriva do hash da chave completa; sem -Force silencioso.
    $SHA_SAME8 = 'aaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $n1 = Get-GHRSWaitFileName -Repository $REPO -PrNumber $PR -HeadSha $SHA_A -Generation $GEN
    $n1b = Get-GHRSWaitFileName -Repository $REPO -PrNumber $PR -HeadSha $SHA_A -Generation $GEN
    $n2 = Get-GHRSWaitFileName -Repository $REPO -PrNumber $PR -HeadSha $SHA_SAME8 -Generation $GEN
    Assert-That (([string]$n1 -cmatch '\Aghwait-[0-9a-f]{16}\.json\z') -and ([string]$n2 -cmatch '\Aghwait-[0-9a-f]{16}\.json\z')) 'nome deriva de hash (ghwait-16hex.json)'
    Assert-That ([string]$n1 -ceq [string]$n1b) 'mesma chave => mesmo nome (deterministico)'
    Assert-That ([string]$n1 -cne [string]$n2) 'prefixo SHA igual nao colide: nomes distintos'
    $wColDir = Join-Path $root 'wcol'
    $wCol = New-TWait -WaitsDir $wColDir
    Assert-That ([bool]$wCol.ok) 'wait de colisao registra'
    $planted = '{"schema_version":1,"dedup_key":"github-resume:v1:forjado/falso:9:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:0"}'
    [IO.File]::WriteAllText($wCol.wait_file, $planted, (New-Object Text.UTF8Encoding $false))
    $wCol2 = New-TWait -WaitsDir $wColDir
    Assert-That ((-not [bool]$wCol2.ok) -and ([string]$wCol2.reason -ceq 'wait-filename-collision')) 'sobrescrita com identidade divergente recusada (sem -Force silencioso)'
    Assert-That ([IO.File]::ReadAllText($wCol.wait_file, [Text.Encoding]::UTF8) -ceq $planted) 'arquivo divergente preservado byte-identico'

    # --- FINDING 3: controle otimista (sem perda silenciosa).
    # Limite documentado: sem threads neste suite hermetico, a concorrencia e
    # simulada sequencialmente; o ramo de conflito e exercido diretamente via
    # Write-GHRSWaitDocument com bytes originais obsoletos. A janela residual
    # TOCTOU entre a releitura e o Move nao e eliminada sem primitiva atomica
    # do SO; o CAS converte a condicao comum em erro explicito wait-modified.
    $wConcDir = Join-Path $root 'wconc'
    $wConc = New-TWait -WaitsDir $wConcDir
    $cA = Confirm-OrchestrationGitHubResumeApplied -WaitsDir $wConcDir -DedupKey ([string]$wConc.dedup_key) -EventId 'evt-a'
    Assert-That (([bool]$cA.ok) -and ([string]$cA.reason -ceq 'applied')) 'confirm A aplica'
    $cB = Confirm-OrchestrationGitHubResumeApplied -WaitsDir $wConcDir -DedupKey ([string]$wConc.dedup_key) -EventId 'evt-b'
    Assert-That (([bool]$cB.ok) -and ([string]$cB.reason -ceq 'applied')) 'confirm B aplica'
    $diskConc = ConvertFrom-Json ([IO.File]::ReadAllText($wConc.wait_file, [Text.Encoding]::UTF8))
    Assert-That ((@($diskConc.applied_events) -contains 'evt-a') -and (@($diskConc.applied_events) -contains 'evt-b') -and (@($diskConc.applied_events).Count -eq 2)) 'nenhum evento perdido em confirms sequenciais'
    $staleBytes = [IO.File]::ReadAllText($wConc.wait_file, [Text.Encoding]::UTF8)
    $staleDoc = ConvertFrom-Json $staleBytes
    $cC = Confirm-OrchestrationGitHubResumeApplied -WaitsDir $wConcDir -DedupKey ([string]$wConc.dedup_key) -EventId 'evt-c'
    Assert-That (([bool]$cC.ok) -and ([string]$cC.reason -ceq 'applied')) 'confirm C aplica (avanca o disco)'
    $staleDoc.applied_events = [string[]](@($staleDoc.applied_events) + @('evt-stale'))
    $wrStale = Write-GHRSWaitDocument -Path $wConc.wait_file -OriginalBytes $staleBytes -Document $staleDoc
    Assert-That ((-not [bool]$wrStale.ok) -and ([string]$wrStale.reason -ceq 'wait-modified')) 'escritor obsoleto aborta com wait-modified (sem perda silenciosa)'
    $diskAfter = ConvertFrom-Json ([IO.File]::ReadAllText($wConc.wait_file, [Text.Encoding]::UTF8))
    Assert-That ((@($diskAfter.applied_events) -contains 'evt-c') -and (-not (@($diskAfter.applied_events) -contains 'evt-stale'))) 'disco preserva evt-c; escrita obsoleta descartada'
    $freshBytes = [IO.File]::ReadAllText($wConc.wait_file, [Text.Encoding]::UTF8)
    $freshDoc = ConvertFrom-Json $freshBytes
    $freshDoc.applied_events = [string[]](@($freshDoc.applied_events) + @('evt-d'))
    $wrFresh = Write-GHRSWaitDocument -Path $wConc.wait_file -OriginalBytes $freshBytes -Document $freshDoc
    Assert-That ([bool]$wrFresh.ok) 'CAS com bytes atuais persiste'

    # --- P0-05 FIX: baseline presa a primeira leitura (sem segunda leitura).
    # Intercalacao no nivel do caller: leitura A captura v0; Confirm
    # concorrente via caller avanca o disco para v1; a escrita obsoleta,
    # construida exatamente como o caller constroi (doc desserializado do
    # texto v0 + evento novo, baseline v0), deve abortar com wait-modified
    # (erro explicito, nunca perda silenciosa); um Confirm fresco depois
    # faz merge e preserva ambos os eventos.
    $wRaceDir = Join-Path $root 'wrace'
    $wRace = New-TWait -WaitsDir $wRaceDir
    Assert-That ([bool]$wRace.ok) 'race wait registra'
    $v0Bytes = [IO.File]::ReadAllText($wRace.wait_file, [Text.Encoding]::UTF8)
    $cRace = Confirm-OrchestrationGitHubResumeApplied -WaitsDir $wRaceDir -DedupKey ([string]$wRace.dedup_key) -EventId 'evt-race'
    Assert-That (([bool]$cRace.ok) -and ([string]$cRace.reason -ceq 'applied')) 'confirm concorrente via caller aplica'
    $staleRaceDoc = ConvertFrom-Json $v0Bytes
    $staleRaceDoc.applied_events = [string[]](@($staleRaceDoc.applied_events) + @('evt-stale-loser'))
    $wrRace = Write-GHRSWaitDocument -Path $wRace.wait_file -OriginalBytes $v0Bytes -Document $staleRaceDoc
    Assert-That ((-not [bool]$wrRace.ok) -and ([string]$wrRace.reason -ceq 'wait-modified')) 'escritor com baseline obsoleta aborta (erro explicito, sem perda)'
    $diskRace = ConvertFrom-Json ([IO.File]::ReadAllText($wRace.wait_file, [Text.Encoding]::UTF8))
    Assert-That ((@($diskRace.applied_events) -contains 'evt-race') -and (-not (@($diskRace.applied_events) -contains 'evt-stale-loser'))) 'confirmacao concorrente preservada; escrita obsoleta descartada'
    $cMerge = Confirm-OrchestrationGitHubResumeApplied -WaitsDir $wRaceDir -DedupKey ([string]$wRace.dedup_key) -EventId 'evt-late'
    Assert-That (([bool]$cMerge.ok) -and ([string]$cMerge.reason -ceq 'applied')) 'confirm tardio com leitura fresca aplica (merge)'
    $diskMerged = ConvertFrom-Json ([IO.File]::ReadAllText($wRace.wait_file, [Text.Encoding]::UTF8))
    Assert-That ((@($diskMerged.applied_events) -contains 'evt-race') -and (@($diskMerged.applied_events) -contains 'evt-late') -and (@($diskMerged.applied_events).Count -eq 2)) 'merge preserva ambos os eventos'
    $confirmText = $libText.Substring($libText.IndexOf('function Confirm-OrchestrationGitHubResumeApplied'))
    $confirmText = $confirmText.Substring(0, $confirmText.IndexOf('function New-GHRSDecisionEnvelope'))
    Assert-That ($confirmText -cnotmatch 'ReadAllText\(\$targetPath') 'Confirm sem segunda leitura do alvo (baseline da primeira leitura)'

    # --- wait invalida / flags nao-bool: fail-closed, nunca RESUME.
    $tInv = Invoke-TTest -Wait $null -Snap $green
    Assert-That (([string]$tInv.decision -ceq 'INVALID') -and (-not [bool]$tInv.ok)) 'wait nula => INVALID'
    $tFlag = Test-OrchestrationGitHubResume -Wait $r.wait -Snapshot $green -Policy $policy -NowUtc $NOW -MaxAgeSeconds 300 -LeaseAlive 'yes' -OwnerAlive $true -AuthorizationAlive $true -ExecutorPresent $true -CancelRequested $false -AlreadyApplied $false
    Assert-That (([string]$tFlag.decision -ceq 'INVALID') -and (-not [bool]$tFlag.resume_authorized)) 'flag nao-bool => INVALID, nunca RESUME'

    Write-Output "PASS: $($script:passed) assertions"
    exit 0
}
catch {
    Write-Output ("FAIL: " + $_.Exception.Message)
    exit 1
}
finally {
    try { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
}
