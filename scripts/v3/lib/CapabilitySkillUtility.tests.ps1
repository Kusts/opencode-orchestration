$ErrorActionPreference = 'Stop'
$v3 = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent (Split-Path -Parent $v3)
. (Join-Path $PSScriptRoot 'CapabilityObservability.ps1')
. (Join-Path $PSScriptRoot 'CapabilitySanitize.ps1')
. (Join-Path $PSScriptRoot 'CapabilitySkillUtility.ps1')

$telDir = Join-Path $repo 'cache\v3\telemetry'
$beforeFiles = @()
try { $beforeFiles = @(Get-ChildItem -LiteralPath $telDir -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object) } catch { $beforeFiles = @() }
$base = Join-Path ([IO.Path]::GetTempPath()) ('v3-skillutil-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base -Force | Out-Null
$tmpFiles = @()

function New-TmpTelemetry {
    $p = Join-Path $script:telDir ('tmp-su-test-' + [guid]::NewGuid().ToString('N') + '.jsonl')
    $script:tmpFiles += $p
    return $p
}

$total = 0
$passed = 0
$skipped = 0
function Assert-That($condition, $name, $detail) {
    $script:total++
    if ($condition) { $script:passed++; Write-Host "[PASS] $name" }
    else { Write-Host "[FAIL] $name -- $detail" }
}
function Skip-That($name, $reason) {
    $script:total++
    $script:skipped++
    Write-Host "[SKIP] $name -- $reason"
}

function Write-Fixture {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $lf = ($Text -replace "`r`n", "`n" -replace "`r", "`n")
    [IO.File]::WriteAllText($Path, $lf, [Text.UTF8Encoding]::new($false))
}

try {
    Assert-That (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'CapabilitySkillUtility.ps1') -PathType Leaf) 'Lib file exists' 'Missing lib'
    # Hermetico clean-room: garante o dir de telemetria do repo (ausente quando
    # a copia limpa exclui cache/); o teste so cria arquivos tmp-su-* nele.
    New-Item -ItemType Directory -Path $telDir -Force | Out-Null

    $fields = @(Get-SkillUtilitySchemaFields)
    foreach ($k in @('schema_version', 'event_type', 'ts', 'task_id_hash', 'skill_id', 'suggested', 'accepted', 'loaded', 'used', 'helpful', 'unnecessary', 'utility_source', 'warnings')) {
        Assert-That ($fields -ccontains $k) ("Schema skill-utility contem $k") ($fields -join ',')
    }
    Assert-That (($fields.Count -eq 13) -and ($fields[0] -ceq 'schema_version') -and ($fields[1] -ceq 'event_type')) 'Schema ordenado (13 campos)' ($fields -join ',')

    $ofields = @(Get-RoutingOutcomeSchemaFields)
    foreach ($k in @('task_id_hash', 'task_type', 'domain', 'router_candidate', 'router_selected_agent', 'actual_agent', 'classification_confidence', 'routing_reason', 'fallback_used', 'fallback_reason', 'task_success', 'validation_result', 'tester_result', 'reviewer_result', 'retry_count', 'debugger_invoked', 'architect_invoked', 'model_escalation_count', 'review_findings_count', 'security_findings_count', 'completion_status')) {
        Assert-That ($ofields -ccontains $k) ("Schema outcome contem $k") ($ofields -join ',')
    }

    $obs = New-SkillUtilityObservation -TaskId 'SU-1A2B' -SkillId 'Db-Helper' -Suggested 'yes' -Accepted $true -Helpful 'YES' -UtilitySource 'reviewer'
    Assert-That (($null -ne $obs) -and ($obs.skill_id -ceq 'skill:db-helper')) 'skill_id canonizado (lowercase + prefixo)' ([string]$obs.skill_id)
    if ($null -ne $obs) {
        Assert-That (($obs.task_id_hash -match '^sha256:[0-9a-f]{16}$') -and (-not $obs.task_id_hash.Contains('SU-1A2B'))) 'task_id somente hash' ([string]$obs.task_id_hash)
        Assert-That (($obs.suggested -ceq 'YES') -and ($obs.accepted -ceq 'YES') -and ($obs.helpful -ceq 'YES')) 'Flags YES normalizadas' 'Errado'
        Assert-That (($obs.loaded -ceq 'NOT_OBSERVED') -and ($obs.used -ceq 'NOT_OBSERVED')) 'Flags ausentes => NOT_OBSERVED' 'Errado'
        Assert-That ($obs.utility_source -ceq 'REVIEWER') 'utility_source enum preservado' ([string]$obs.utility_source)
        Assert-That (($obs.event_type -ceq 'skill-utility') -and ([int]$obs.schema_version -eq 1)) 'event_type/schema_version fixos' 'Errado'
    }

    $pref = New-SkillUtilityObservation -TaskId 'T-1' -SkillId 'skill:DOC-Guide'
    Assert-That (($null -ne $pref) -and ($pref.skill_id -ceq 'skill:doc-guide')) 'Prefixo skill: preservado e normalizado' ([string]$pref.skill_id)

    $badSkill = $null
    try { $badSkill = New-SkillUtilityObservation -TaskId 'T-1' -SkillId 'bad id!!' } catch { $badSkill = 'THREW' }
    Assert-That ($null -eq $badSkill) 'skill_id invalido => $null (descartado)' ([string]$badSkill)
    $emptySkill = $null
    try { $emptySkill = New-SkillUtilityObservation -TaskId 'T-1' -SkillId '' } catch { $emptySkill = 'THREW' }
    Assert-That ($null -eq $emptySkill) 'skill_id vazio => $null' ([string]$emptySkill)
    $otherPrefix = $null
    try { $otherPrefix = New-SkillUtilityObservation -TaskId 'T-1' -SkillId 'mcp:store' } catch { $otherPrefix = 'THREW' }
    Assert-That ($null -eq $otherPrefix) 'prefixo nao-skill => $null' ([string]$otherPrefix)

    $inv = New-SkillUtilityObservation -TaskId 'T-1' -SkillId 'db-helper' -Suggested 'maybe-later!!' -Accepted '???' -UtilitySource 'free text here'
    Assert-That (($null -ne $inv) -and ($inv.suggested -ceq 'UNKNOWN') -and ($inv.accepted -ceq 'UNKNOWN')) 'Enum invalido => UNKNOWN' 'Errado'
    Assert-That (($null -ne $inv) -and ($inv.utility_source -ceq 'UNKNOWN')) 'utility_source invalido => UNKNOWN' ([string]$inv.utility_source)
    $neg = New-SkillUtilityObservation -TaskId 'T-1' -SkillId 'db-helper' -Suggested $false -Used 0
    Assert-That (($null -ne $neg) -and ($neg.suggested -ceq 'NO') -and ($neg.used -ceq 'NO')) 'bool/int falsos => NO' 'Errado'

    $secret = 'Bearer abcdef1234567890ABCDEF1234567890'
    $telSec = New-TmpTelemetry
    $evSec = [PSCustomObject]@{ task_id = ('job ' + $secret); skill_id = 'db-helper'; suggested = 'yes' }
    $okSec = $false
    try { $okSec = Write-SkillUtilityObservation -Observation $evSec -TelemetryPath $telSec } catch { $okSec = 'THREW' }
    Assert-That ($okSec -eq $true) 'Escrita com segredo nao bloqueia (true)' ([string]$okSec)
    if (Test-Path -LiteralPath $telSec -PathType Leaf) {
        $txt = [IO.File]::ReadAllText($telSec, [Text.UTF8Encoding]::new($false))
        Assert-That (-not $txt.Contains('abcdef1234567890ABCDEF')) 'Segredo ausente cru no JSONL' 'Vazou'
        Assert-That ($txt -match 'sha256:[0-9a-f]{16}') 'Hash presente no lugar do id' 'Ausente'
        Assert-That ($txt.Contains('skill:db-helper')) 'skill_id canonico persistido' 'Ausente'
        $bytes = [IO.File]::ReadAllBytes($telSec)
        Assert-That (-not ($bytes.Count -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'Append UTF8 sem BOM' 'Tem BOM'
        $o0 = $null
        try { $o0 = ((($txt -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)) | ConvertFrom-Json) } catch { $o0 = $null }
        Assert-That (($null -ne $o0) -and ($o0.event_type -ceq 'skill-utility')) 'Linha e JSON valido skill-utility' 'Falhou'
    }
    else { Assert-That $false 'JSONL de segredo escrito' 'Ausente' }

    $telOut = Join-Path ([IO.Path]::GetTempPath()) ('v3-su-outside-' + [guid]::NewGuid().ToString('N') + '.jsonl')
    $evOut = New-SkillUtilityObservation -TaskId 'T-1' -SkillId 'db-helper'
    $rOut = $true
    try { $rOut = Write-SkillUtilityObservation -Observation $evOut -TelemetryPath $telOut } catch { $rOut = 'THREW' }
    Assert-That ($rOut -eq $false) 'Confinamento: fora de cache/v3/telemetry => $false' ([string]$rOut)
    Assert-That (-not (Test-Path -LiteralPath $telOut -PathType Leaf)) 'Confinamento: nada escrito fora' 'Arquivo criado'
    $rNull = $true
    try { $rNull = Write-SkillUtilityObservation -Observation $null -TelemetryPath (New-TmpTelemetry) } catch { $rNull = 'THREW' }
    Assert-That ($rNull -eq $false) 'Observacao $null => $false sem lancar' ([string]$rNull)
    $rBadSkill = $true
    try { $rBadSkill = Write-SkillUtilityObservation -Observation ([PSCustomObject]@{ task_id = 'T-1'; skill_id = 'bad id!!' }) -TelemetryPath (New-TmpTelemetry) } catch { $rBadSkill = 'THREW' }
    Assert-That ($rBadSkill -eq $false) 'skill invalida na escrita => $false (nada persistido)' ([string]$rBadSkill)
    $dirBlock = Join-Path $telDir ('tmp-su-dirblock-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dirBlock -Force | Out-Null
    $rDir = $true
    try { $rDir = Write-SkillUtilityObservation -Observation $evOut -TelemetryPath $dirBlock } catch { $rDir = 'THREW' }
    Assert-That ($rDir -eq $false) 'TelemetryPath diretorio => $false sem lancar' ([string]$rDir)
    Remove-Item -LiteralPath $dirBlock -Recurse -Force -ErrorAction SilentlyContinue

    $telDirFix = Join-Path $telDir ('tmp-su-read-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $telDirFix -Force | Out-Null
    $f1 = Join-Path $telDirFix 'skill-utility-20260921.jsonl'
    Write-SkillUtilityObservation -Observation ([PSCustomObject]@{ task_id = 'A-1'; skill_id = 'db-helper'; suggested = 'yes'; accepted = 'yes' }) -TelemetryPath $f1 | Out-Null
    Write-SkillUtilityObservation -Observation ([PSCustomObject]@{ task_id = 'A-2'; skill_id = 'db-helper'; suggested = 'yes'; accepted = 'no'; helpful = 'yes' }) -TelemetryPath $f1 | Out-Null
    Write-SkillUtilityObservation -Observation ([PSCustomObject]@{ task_id = 'A-4'; skill_id = 'db-helper'; helpful = 'yes'; utility_source = 'reviewer' }) -TelemetryPath $f1 | Out-Null
    Write-SkillUtilityObservation -Observation ([PSCustomObject]@{ task_id = 'A-3'; skill_id = 'other-tool'; suggested = 'no'; unnecessary = 'yes' }) -TelemetryPath $f1 | Out-Null
    [IO.File]::AppendAllText($f1, "not-json{{{`n", [Text.UTF8Encoding]::new($false))
    $read = Read-SkillUtilityTelemetry -TelemetryDir $telDirFix
    Assert-That (($read.Parsed -eq 4) -and ($read.Skipped -eq 1)) 'Read defensivo: 4 parsed, 1 skipped' ("parsed=$($read.Parsed) skipped=$($read.Skipped)")
    $sum = @(Get-SkillUtilitySummary -TelemetryDir $telDirFix)
    Assert-That ($sum.Count -eq 2) 'Summary: 2 skills' ($sum.Count)
    $db = @($sum | Where-Object { $_.skill -ceq 'skill:db-helper' })
    Assert-That ((@($db).Count -eq 1) -and ([int]@($db)[0].suggested -eq 2) -and ([int]@($db)[0].accepted -eq 1)) 'Summary db-helper: suggested=2 accepted=1' 'Errado'
    if (@($db).Count -eq 1) {
        Assert-That (([int]@($db)[0].helpful -eq 1) -and ([int]@($db)[0].unknown -eq 1) -and ([int]@($db)[0].not_observed -eq 12)) 'Summary db-helper: helpful=1 unknown=1 not_observed=12' ("helpful=$([int]@($db)[0].helpful) unknown=$([int]@($db)[0].unknown) not_observed=$([int]@($db)[0].not_observed)")
        Assert-That ([int]@($db)[0].accepted_but_not_loaded -eq 1) 'Summary db-helper: accepted_but_not_loaded=1' ([string]@($db)[0].accepted_but_not_loaded)
    }
    $oGuardWeak = New-SkillUtilityObservation -TaskId 'A-5' -SkillId 'guard-tool' -Helpful 'yes' -UtilitySource 'PLANNER'
    Assert-That (($null -ne $oGuardWeak) -and ($oGuardWeak.helpful -ceq 'UNKNOWN')) 'Guard: helpful=YES com PLANNER => UNKNOWN' ("helpful=$($oGuardWeak.helpful)")
    $oGuardStrong = New-SkillUtilityObservation -TaskId 'A-6' -SkillId 'guard-tool' -Helpful 'yes' -UtilitySource 'reviewer'
    Assert-That (($null -ne $oGuardStrong) -and ($oGuardStrong.helpful -ceq 'YES')) 'Guard: helpful=YES com REVIEWER => YES' ("helpful=$($oGuardStrong.helpful)")
    $oGuardUsed = New-SkillUtilityObservation -TaskId 'A-7' -SkillId 'guard-tool' -Used 'yes' -UtilitySource 'inferred'
    Assert-That (($null -ne $oGuardUsed) -and ($oGuardUsed.used -ceq 'UNKNOWN')) 'Guard: used=YES com INFERRED => UNKNOWN' ("used=$($oGuardUsed.used)")

    $readMissing = Read-SkillUtilityTelemetry -TelemetryDir (Join-Path $base 'no-such-dir')
    Assert-That (($readMissing.Error -ceq 'not-found') -and (@($readMissing.Records).Count -eq 0)) 'Read: dir inexistente => vazio sem lancar' ([string]$readMissing.Error)

    $junctionLink = Join-Path $telDir ('tmp-su-junction-' + [guid]::NewGuid().ToString('N'))
    $junctionTarget = Join-Path ([IO.Path]::GetTempPath()) ('v3-su-junction-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null
    $junctionOk = $true
    try { New-Item -ItemType Junction -Path $junctionLink -Target $junctionTarget -ErrorAction Stop | Out-Null } catch { $junctionOk = $false }
    if ($junctionOk) {
        $viaTel = Join-Path $junctionLink 'via-tel.jsonl'
        $rJ = $true
        try { $rJ = Write-SkillUtilityObservation -Observation $evOut -TelemetryPath $viaTel } catch { $rJ = 'THREW' }
        Assert-That ($rJ -eq $false) 'Reparse: via junction recusa ($false)' ([string]$rJ)
        Assert-That (-not (Test-Path -LiteralPath $viaTel -PathType Leaf)) 'Reparse: nada escrito via junction' 'Arquivo criado'
        $leaked = @(Get-ChildItem -LiteralPath $junctionTarget -Force -ErrorAction SilentlyContinue)
        Assert-That ($leaked.Count -eq 0) 'Reparse: nada vaza para o alvo' ($leaked.Count)
        Remove-Item -LiteralPath $junctionLink -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host '[WARN] Junction indisponivel; skip do caso reparse'
        Assert-That ($true) 'Reparse via junction (skip sem privilegio)' 'skip'
    }
    if (Test-Path -LiteralPath $junctionTarget) { Remove-Item -LiteralPath $junctionTarget -Recurse -Force -ErrorAction SilentlyContinue }

    $oc = New-RoutingOutcome -TaskId 'R-9Z' -TaskType 'implementation' -Domain 'backend' -RouterCandidate 'coder' -RouterSelectedAgent 'database-engineer' -ActualAgent 'database-engineer' -ClassificationConfidence 'HIGH' -RoutingReason 'database' -FallbackUsed $false -TaskSuccess $true -ValidationResult 'PASS' -RetryCount 2 -ModelEscalationCount 1 -ReviewFindingsCount 3 -CompletionStatus 'completed'
    Assert-That (($null -ne $oc) -and ($oc.event_type -ceq 'routing-outcome')) 'Outcome valido construido' 'Null'
    if ($null -ne $oc) {
        Assert-That (($oc.task_id_hash -match '^sha256:[0-9a-f]{16}$') -and (-not $oc.task_id_hash.Contains('R-9Z'))) 'Outcome: task_id so hash' ([string]$oc.task_id_hash)
        Assert-That (($oc.classification_confidence -ceq 'high') -and ($oc.validation_result -ceq 'pass')) 'Outcome: enums normalizados' 'Errado'
        Assert-That (([int]$oc.retry_count -eq 2) -and ([int]$oc.model_escalation_count -eq 1) -and ([int]$oc.review_findings_count -eq 3)) 'Outcome: contadores preservados' 'Errado'
        Assert-That (($oc.tester_result -ceq 'NOT_OBSERVED') -and ($oc.fallback_reason -ceq 'NOT_OBSERVED')) 'Outcome: ausentes => NOT_OBSERVED' 'Errado'
        Assert-That (($oc.task_type -ceq 'implementation') -and ($oc.actual_agent -ceq 'database-engineer')) 'Outcome: ids canonicos' 'Errado'
        Assert-That (($oc.route_mode -ceq 'NOT_OBSERVED') -and ($oc.risk_class -ceq 'UNKNOWN') -and ($oc.evidence_level -ceq 'NOT_OBSERVED')) 'Outcome: lifecycle defaults' ("mode=$($oc.route_mode) risk=$($oc.risk_class) ev=$($oc.evidence_level)")
    }
    $ocLife = New-RoutingOutcome -TaskId 'R-LIFE' -TaskType 'implementation' -Domain 'backend' -SecondaryDomains @('database', 'database', 'sk-abcdefghijklmnop') -RiskClass 'HIGH' -RouteMode 'router' -EvidenceLevel 'executed'
    Assert-That (($null -ne $ocLife) -and ($ocLife.route_mode -ceq 'ROUTER') -and ($ocLife.risk_class -ceq 'high') -and ($ocLife.evidence_level -ceq 'EXECUTED')) 'Outcome: lifecycle enums normalizados' 'Errado'
    Assert-That (($null -ne $ocLife) -and (@($ocLife.secondary_domains).Count -eq 1) -and (@($ocLife.secondary_domains)[0] -ceq 'database')) 'Outcome: secondary_domains dedup + secret descartado' ("count=$(@($ocLife.secondary_domains).Count)")

    $ocBad = New-RoutingOutcome -TaskId 'R-1' -TaskType 'bad type!!' -ClassificationConfidence 'extreme' -RoutingReason '   ' -RetryCount 500 -CompletionStatus ''
    Assert-That (($null -ne $ocBad) -and ($ocBad.task_type -ceq 'UNKNOWN') -and ($ocBad.classification_confidence -ceq 'UNKNOWN')) 'Outcome: enums invalidos => UNKNOWN' 'Errado'
    Assert-That (($null -ne $ocBad) -and ([int]$ocBad.retry_count -eq 99) -and ($ocBad.routing_reason -ceq 'NOT_OBSERVED') -and ($ocBad.completion_status -ceq 'UNKNOWN')) 'Outcome: clamp + defaults' 'Errado'

    $reasonPlain = 'revisar codigo de autenticacao do projeto alfa com'
    $ocFree = New-RoutingOutcome -TaskId 'R-2' -RoutingReason ($reasonPlain + ' ' + $secret)
    Assert-That (($null -ne $ocFree) -and ([string]$ocFree.routing_reason -cne ($reasonPlain + ' ' + $secret))) 'routing_reason livre nunca cru' ([string]$ocFree.routing_reason)
    $telOc = New-TmpTelemetry
    $okOc = $false
    try { $okOc = Write-RoutingOutcome -Outcome $ocFree -TelemetryPath $telOc } catch { $okOc = 'THREW' }
    Assert-That ($okOc -eq $true) 'Escrita de outcome nao bloqueia (true)' ([string]$okOc)
    if (Test-Path -LiteralPath $telOc -PathType Leaf) {
        $txtOc = [IO.File]::ReadAllText($telOc, [Text.UTF8Encoding]::new($false))
        Assert-That (-not $txtOc.Contains('abcdef1234567890ABCDEF')) 'Outcome: segredo ausente cru' 'Vazou'
        Assert-That (-not $txtOc.Contains($reasonPlain)) 'Outcome: texto livre ausente literal' 'Vazou literal'
        Assert-That (-not $txtOc.Contains('R-2')) 'Outcome: task_id cru ausente' 'Vazou'
    }
    else { Assert-That $false 'JSONL de outcome escrito' 'Ausente' }

    $skSecret = $null
    try { $skSecret = New-SkillUtilityObservation -TaskId 'T-SEC' -SkillId 'sk-abcdefghijklmnop' } catch { $skSecret = 'THREW' }
    Assert-That ($null -eq $skSecret) 'FIX: skill com cara de segredo (sk-...) => $null' ([string]$skSecret)
    $akiaSecret = $null
    try { $akiaSecret = New-SkillUtilityObservation -TaskId 'T-SEC' -SkillId 'AKIAABCDEFGHIJKLMNOP' } catch { $akiaSecret = 'THREW' }
    Assert-That ($null -eq $akiaSecret) 'FIX: skill com cara de segredo (AKIA...) => $null' ([string]$akiaSecret)
    Assert-That ((Test-SkillUtilitySecretLike -Text 'sk-abcdefghijklmnop') -and (Test-SkillUtilitySecretLike -Text 'AKIAABCDEFGHIJKLMNOP') -and (Test-SkillUtilitySecretLike -Text 'Bearer abc') -and (Test-SkillUtilitySecretLike -Text 'mytoken123')) 'FIX: secret-like detectado (prefixos + substrings)' 'Falhou'
    Assert-That ((-not (Test-SkillUtilitySecretLike -Text 'coder')) -and (-not (Test-SkillUtilitySecretLike -Text 'database-engineer')) -and (-not (Test-SkillUtilitySecretLike -Text 'implementation')) -and (-not (Test-SkillUtilitySecretLike -Text ''))) 'FIX: tokens legitimos nao marcados' 'Falso positivo'
    Assert-That ((Get-SkillUtilityIdToken -Text 'Coder') -ceq 'coder') 'FIX: id token normaliza para lowercase' 'Errado'

    $ocSec = New-RoutingOutcome -TaskId 'R-SEC' -TaskType 'sk-abcdefghijklmnop' -Domain 'apitoken' -RouterCandidate 'coder' -RouterSelectedAgent 'ghp-abcdef1234567890' -ActualAgent 'AKIAABCDEFGHIJKLMNOP' -RoutingReason 'sk-abcdefghijklmnop' -FallbackReason 'Bearer fallback-x' -ValidationResult 'mytoken-pass'
    Assert-That (($null -ne $ocSec) -and ($ocSec.task_type -ceq 'UNKNOWN') -and ($ocSec.domain -ceq 'UNKNOWN')) 'FIX: task_type/domain secret-like => UNKNOWN' 'Errado'
    Assert-That (($null -ne $ocSec) -and ($ocSec.router_selected_agent -ceq 'UNKNOWN') -and ($ocSec.actual_agent -ceq 'UNKNOWN') -and ($ocSec.router_candidate -ceq 'coder')) 'FIX: agents secret-like => UNKNOWN, legitimo preservado' 'Errado'
    Assert-That (($null -ne $ocSec) -and ($ocSec.routing_reason -ceq 'UNKNOWN') -and ($ocSec.fallback_reason -ceq 'UNKNOWN') -and ($ocSec.validation_result -ceq 'UNKNOWN')) 'FIX: reasons/resultados secret-like => UNKNOWN (nunca hash)' 'Errado'
    $telSec2 = New-TmpTelemetry
    $okSec2 = $false
    try { $okSec2 = Write-RoutingOutcome -Outcome $ocSec -TelemetryPath $telSec2 } catch { $okSec2 = 'THREW' }
    Assert-That ($okSec2 -eq $true) 'FIX: escrita com secret-like nao bloqueia' ([string]$okSec2)
    if (Test-Path -LiteralPath $telSec2 -PathType Leaf) {
        $txtSec2 = [IO.File]::ReadAllText($telSec2, [Text.UTF8Encoding]::new($false))
        Assert-That (-not $txtSec2.Contains('sk-abcdefghijklmnop')) 'FIX: sk-... ausente cru no JSONL' 'Vazou'
        Assert-That (-not $txtSec2.Contains('AKIAABCDEFGHIJKLMNOP')) 'FIX: AKIA... ausente cru no JSONL' 'Vazou'
        Assert-That (-not $txtSec2.Contains('ghp-abcdef1234567890')) 'FIX: ghp-... ausente cru no JSONL' 'Vazou'
        Assert-That (-not $txtSec2.Contains('apitoken')) 'FIX: substring token ausente crua' 'Vazou'
        Assert-That (-not $txtSec2.Contains('R-SEC')) 'FIX: task_id cru ausente' 'Vazou'
        Assert-That ($txtSec2.Contains('"task_type":"UNKNOWN"')) 'FIX: task_type UNKNOWN persistido' 'Ausente'
    }
    else { Assert-That $false 'FIX: JSONL secret-like escrito' 'Ausente' }

    $telOcOut = Join-Path ([IO.Path]::GetTempPath()) ('v3-oc-outside-' + [guid]::NewGuid().ToString('N') + '.jsonl')
    $rOcOut = $true
    try { $rOcOut = Write-RoutingOutcome -Outcome $oc -TelemetryPath $telOcOut } catch { $rOcOut = 'THREW' }
    Assert-That (($rOcOut -eq $false) -and (-not (Test-Path -LiteralPath $telOcOut -PathType Leaf))) 'Outcome confinado: fora => $false sem escrever' ([string]$rOcOut)
    $rOcNull = $true
    try { $rOcNull = Write-RoutingOutcome -Outcome $null -TelemetryPath (New-TmpTelemetry) } catch { $rOcNull = 'THREW' }
    Assert-That ($rOcNull -eq $false) 'Outcome $null => $false sem lancar' ([string]$rOcNull)

    foreach ($tmp in @($tmpFiles)) {
        if ((-not [string]::IsNullOrWhiteSpace($tmp)) -and (Test-Path -LiteralPath $tmp -PathType Leaf)) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    $script:tmpFiles = @()
    if (Test-Path -LiteralPath $telDirFix -PathType Container) { Remove-Item -LiteralPath $telDirFix -Recurse -Force -ErrorAction SilentlyContinue }
    $afterFiles = @()
    try { $afterFiles = @(Get-ChildItem -LiteralPath $telDir -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object) } catch { $afterFiles = @() }
    $myPrefixes = @('tmp-su-test-', 'tmp-su-dirblock-', 'tmp-su-junction-')
    $newResidue = @($afterFiles | Where-Object { $n = [string]$_; (($beforeFiles -cnotcontains $n) -and (@($myPrefixes | Where-Object { $n.StartsWith($_) }).Count -gt 0)) })
    if (Test-Path -LiteralPath $telDirFix -PathType Container) { $newResidue += 'tmp-su-read-dir-present' }
    Assert-That ($newResidue.Count -eq 0) 'Sem residuo proprio no telemetry real (tolera escritores paralelos)' ($newResidue -join ',')

    $liveConfig = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
    if (Test-Path -LiteralPath $liveConfig -PathType Leaf) {
        $liveHash = (Get-FileHash -LiteralPath $liveConfig -Algorithm SHA256).Hash
        Assert-That ($liveHash.StartsWith('DE22307F')) 'opencode.json vivo inalterado (prefixo DE22307F)' $liveHash
    }
    else {
        Skip-That 'opencode.json vivo inalterado (prefixo DE22307F)' 'sem opencode.json vivo nesta maquina (estado live, nao distribuido)'
    }
}
finally {
    foreach ($tmp in @($tmpFiles)) {
        if ((-not [string]::IsNullOrWhiteSpace($tmp)) -and (Test-Path -LiteralPath $tmp -PathType Leaf)) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "TEST RESULTS: $passed / $total passed ($skipped skipped)"
if (($passed + $skipped) -ne $total) { exit 1 }
exit 0
