<#
.SYNOPSIS
    Teste unitario do extrator TOOL do mcp-subagent-propagation-probe (sem modelo, sem rede).
.DESCRIPTION
    Extrai Get-JsonProp, Get-ProbeJsonCandidates,
    Add-ProbeToolRecordsFromObject, Get-ProbeToolEvidence,
    Convert-ProbeMessageJsonToToolText, Get-ProbeDiscoveryScore e
    Test-ProbeMcpOperational do probe (parse textual, sem executar o
    harness) e valida contra a fixture real (turn-output-head com
    tool_use subagent) + JSON sintetico de message API + casos negativos
    (citacao JSON em texto, objeto sem type, MCP degradado).
    PowerShell 5.1 compativel, ASCII-only. Exit 0 = PASS, exit 1 = FAIL.
#>
[CmdletBinding()] param([string]$RepoRoot = '')
$ErrorActionPreference = 'Stop'
function Get-TRepoRoot {
    try { return (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) } catch { return (Get-Location).Path }
}
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Get-TRepoRoot }
$probePath = Join-Path $RepoRoot 'scripts\ci\mcp-subagent-propagation-probe.ps1'
$fixturePath = Join-Path $RepoRoot 'tests\fixtures\mcp-probe-turn-output-head.txt'
$script:Fail = 0
function Assert-T([bool]$Cond, [string]$Name, [string]$Detail) {
    if ([bool]$Cond) { Write-Host ('[probe-test] PASS ' + $Name) }
    else { $script:Fail += 1; Write-Host ('[probe-test] FAIL ' + $Name + ' :: ' + $Detail) }
}
function Get-TFunctionText([string]$Src, [string]$Name) {
    $m = [regex]::Match($Src, ('(?m)^function\s+' + [regex]::Escape($Name) + '(?=[\s\(]|$)'))
    if (-not $m.Success) { return '' }
    $start = $Src.IndexOf('{', ($m.Index + $m.Length))
    if ($start -lt 0) { return '' }
    $depth = 0
    $inS = $false; $inD = $false
    $j = $start
    while ($j -lt $Src.Length) {
        $c = [int][char]$Src[$j]
        if ($inS) {
            if ($c -eq 39) {
                if ((($j + 1) -lt $Src.Length) -and (([int][char]$Src[$j + 1]) -eq 39)) { $j += 1 } else { $inS = $false }
            }
        } elseif ($inD) {
            if ($c -eq 96) { $j += 1 }
            elseif ($c -eq 34) { $inD = $false }
        } else {
            if ($c -eq 35) { while (($j -lt $Src.Length) -and (([int][char]$Src[$j]) -ne 10)) { $j += 1 }; continue }
            elseif ($c -eq 39) { $inS = $true }
            elseif ($c -eq 34) { $inD = $true }
            elseif ($c -eq 123) { $depth += 1 }
            elseif ($c -eq 125) { $depth -= 1; if ($depth -eq 0) { return $Src.Substring($m.Index, ($j - $m.Index + 1)) } }
        }
        $j += 1
    }
    return ''
}
if (-not (Test-Path -LiteralPath $probePath -PathType Leaf)) { Write-Host '[probe-test] FAIL probe ausente'; exit 1 }
if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) { Write-Host '[probe-test] FAIL fixture ausente'; exit 1 }
$src = [IO.File]::ReadAllText($probePath, [Text.Encoding]::UTF8)
foreach ($fn in @('Get-JsonProp', 'Get-ProbeSafeText', 'Invoke-ProbeRedactRules', 'Get-ProbeResidualPatterns', 'Test-ProbeSensitiveResidual', 'Test-ProbeLocalhostUrl', 'Get-ProbeVerdict', 'Get-ProbeMcpToolCounts', 'Stop-ProbeOwned', 'Get-ProbeJsonCandidates', 'Add-ProbeToolRecordsFromObject', 'Get-ProbeToolEvidence', 'Convert-ProbeMessageJsonToToolText', 'Get-ProbeDiscoveryScore', 'Test-ProbeMcpOperational', 'Wait-ProbeMcpNames', 'Get-ProbeSessionMessageToolEvidence')) {
    $ft = Get-TFunctionText $src $fn
    Assert-T ((-not [string]::IsNullOrWhiteSpace($ft))) ('extract-' + $fn) 'funcao nao localizada no probe'
    if ([string]::IsNullOrWhiteSpace($ft)) { exit 1 }
    . ([scriptblock]::Create($ft))
}
# 1. fixture real: excerto com tool_use subagent status completed
$raw = [IO.File]::ReadAllText($fixturePath, [Text.Encoding]::UTF8)
$ev = Get-ProbeToolEvidence $raw
Assert-T (([int]$ev.count -ge 1)) 'fixture-raw-count' ('count=' + [int]$ev.count)
$hasSub = $false
foreach ($n in @($ev.names)) { if ([string]$n -match '(?i)^subagent/(completed|complete|success|ok|done)$') { $hasSub = $true } }
Assert-T $hasSub 'fixture-raw-subagent-completed' ('names=[' + (($ev.names) -join ',') + ']')
$sc = Get-ProbeDiscoveryScore $raw
Assert-T ([bool]$sc.tool_subagent_ok) 'fixture-score-subagent-ok' ('tool_count=' + [int]$sc.tool_count)
# 2. message API sintetico -> linhas TOOL normalizadas
$msg = '{"data":[{"content":[{"type":"tool","name":"browser_snapshot","state":{"status":"completed"},"content":[{"type":"text","text":"ok len 455"}]}]}]}'
$txt = Convert-ProbeMessageJsonToToolText $msg
Assert-T ($txt -match '(?i)^TOOL name=browser_snapshot status=completed') 'convert-message-tool' $txt
$ev2 = Get-ProbeToolEvidence $txt
Assert-T (([int]$ev2.count -eq 1)) 'convert-evidence-count' ('count=' + [int]$ev2.count)
$sc2 = Get-ProbeDiscoveryScore ($txt + "`n" + 'playwright chrome-devtools')
Assert-T ([bool]$sc2.tool_browser_ok) 'score-browser-ok' ('names=[' + (($sc2.tool_names) -join ',') + ']')
# 3. casos negativos: vazio e mencao sem registro nao contam
$ev0 = Get-ProbeToolEvidence ''
Assert-T (([int]$ev0.count -eq 0)) 'empty-count-zero' ('count=' + [int]$ev0.count)
$ev3 = Get-ProbeToolEvidence 'I can see take_snapshot and browser_navigate in the docs.'
Assert-T (([int]$ev3.count -eq 0)) 'mention-not-proof' ('count=' + [int]$ev3.count)
$ev4 = Get-ProbeToolEvidence 'TOOL-RESULT name=take_snapshot status=completed'
Assert-T (([int]$ev4.count -eq 0)) 'tool-result-echo-not-counted' ('count=' + [int]$ev4.count)
# 4. FINDING 1: citacao JSON em texto nao conta (escapada ou sem type)
$evQ = Get-ProbeToolEvidence 'He wrote: {\"tool\":\"subagent\", \"status\":\"completed\"} in the docs.'
Assert-T (([int]$evQ.count -eq 0)) 'quoted-json-not-proof' ('count=' + [int]$evQ.count)
$evBare = Get-ProbeToolEvidence '{"tool":"subagent","status":"completed"}'
Assert-T (([int]$evBare.count -eq 0)) 'bare-tool-without-type-not-proof' ('count=' + [int]$evBare.count)
$evTyped = Get-ProbeToolEvidence '{"type":"tool_use","tool":"subagent","state":{"status":"completed"}}'
Assert-T (([int]$evTyped.count -eq 1)) 'typed-tooluse-counts' ('count=' + [int]$evTyped.count + ' names=[' + (($evTyped.names) -join ',') + ']')
$hasTypedSub = $false
foreach ($n in @($evTyped.names)) { if ([string]$n -match '(?i)^subagent/(completed|complete|success|ok|done)$') { $hasTypedSub = $true } }
Assert-T $hasTypedSub 'typed-tooluse-subagent-completed' ('names=[' + (($evTyped.names) -join ',') + ']')
# 5. FINDING 2: multiplas tools pelo caminho completo (estruturado -> TOOL
# bruto -> evidencia, sem sanitize/truncate no meio)
$msg2 = '{"data":[{"content":[{"type":"tool","name":"browser_snapshot","state":{"status":"completed"},"content":[{"type":"text","text":"ok len 455"}]},{"type":"tool","name":"take_snapshot","state":{"status":"completed"},"content":[{"type":"text","text":"ok len 12"}]}]}]}'
$txt2 = Convert-ProbeMessageJsonToToolText $msg2
$evM = Get-ProbeToolEvidence $txt2
Assert-T (([int]$evM.count -eq 2)) 'multi-tool-structured-path' ('count=' + [int]$evM.count + ' names=[' + (($evM.names) -join ',') + ']')
$fMsgEv = Get-TFunctionText $src 'Get-ProbeSessionMessageToolEvidence'
$ixEv = -1; $ixSafe = -1
try { $ixEv = $fMsgEv.IndexOf('Get-ProbeToolEvidence $txt') } catch { $ixEv = -1 }
try { $ixSafe = $fMsgEv.IndexOf('Get-ProbeSafeText $txt') } catch { $ixSafe = -1 }
Assert-T ((($ixEv -ge 0) -and (($ixSafe -lt 0) -or ($ixEv -lt $ixSafe)))) 'extract-before-sanitize' ('ixEv=' + $ixEv + ' ixSafe=' + $ixSafe)
# 6. FINDING 3: pre-turn operacional (connected/sem erro), nao so nomes
$mcOk = '{"data":[{"name":"playwright","status":"connected"},{"name":"chrome-devtools","status":"connected"}]}'
$tOk = Test-ProbeMcpOperational $mcOk @('playwright', 'chrome-devtools')
Assert-T ([bool]$tOk.ok) 'preturn-healthy-ok' ('missing=[' + (($tOk.missing) -join ',') + '] degraded=[' + (($tOk.degraded) -join ',') + ']')
$mcDown = '{"data":[{"name":"playwright","status":"disconnected","error":"transport closed"},{"name":"chrome-devtools","status":"connected"}]}'
$tDown = Test-ProbeMcpOperational $mcDown @('playwright', 'chrome-devtools')
Assert-T (((-not [bool]$tDown.ok) -and (@($tDown.missing) -contains 'playwright'))) 'preturn-disconnected-aborts' ('missing=[' + (($tDown.missing) -join ',') + '] degraded=[' + (($tDown.degraded) -join ',') + ']')
$mcDis = '{"data":[{"name":"playwright","status":"connected","disabled":true},{"name":"chrome-devtools","status":"connected"}]}'
$tDis = Test-ProbeMcpOperational $mcDis @('playwright', 'chrome-devtools')
Assert-T (((-not [bool]$tDis.ok) -and (@($tDis.missing) -contains 'playwright'))) 'preturn-disabled-aborts' ('missing=[' + (($tDis.missing) -join ',') + '] degraded=[' + (($tDis.degraded) -join ',') + ']')
$mcErr = 'GET /api/mcp failed: playwright transport error; chrome-devtools missing'
$tErr = Test-ProbeMcpOperational $mcErr @('playwright', 'chrome-devtools')
Assert-T ((-not [bool]$tErr.ok)) 'preturn-text-not-proof' ('missing=[' + (($tErr.missing) -join ',') + ']')
$mcNest = '{"data":[{"name":"playwright","status":{"error":"Connection closed: exited 1"}},{"name":"chrome-devtools","status":{"status":"connected"}}]}'
$tNest = Test-ProbeMcpOperational $mcNest @('playwright', 'chrome-devtools')
Assert-T (((-not [bool]$tNest.ok) -and (@($tNest.missing) -contains 'playwright') -and (@($tNest.found) -contains 'chrome-devtools'))) 'preturn-nested-error-aborts' ('missing=[' + (($tNest.missing) -join ',') + '] found=[' + (($tNest.found) -join ',') + ']')
$fWait = Get-TFunctionText $src 'Wait-ProbeMcpNames'
Assert-T (($fWait -match 'Test-ProbeMcpOperational')) 'wait-uses-operational' 'Wait-ProbeMcpNames nao usa Test-ProbeMcpOperational'
Assert-T ((-not ($fWait -match '\$t\s+-match'))) 'wait-no-substring-match' 'match por substring ainda presente em Wait-ProbeMcpNames'
# 7. HIGH: redacao deterministica (canarios sinteticos; nunca segredos reais)
$rJ = Get-ProbeSafeText '{"token":"sk-SYNTHETIC12345","password":"hunter2synth"}' 400
Assert-T ((($rJ -notmatch 'SYNTHETIC') -and ($rJ -notmatch 'hunter2synth') -and ($rJ -match '\[REDACTED\]'))) 'redact-json-token-password' $rJ
$rQ = Get-ProbeSafeText "{'api_key':'SYNTHETIC_CREDENTIAL_123'}" 400
Assert-T ((($rQ -notmatch 'SYNTHETIC') -and ($rQ -match '\[REDACTED\]'))) 'redact-singlequote-apikey' $rQ
$rC = Get-ProbeSafeText '{"API_KEY":"XYZSYNTH1","Client_Secret":"CS-SYNTH-9"}' 400
Assert-T ((($rC -notmatch 'SYNTH') -and ($rC -match '\[REDACTED\]'))) 'redact-keys-case-insensitive' $rC
$rK = Get-ProbeSafeText '{"passwd":"pwSYNTH1","access_token":"atSYNTH2","refresh_token":"rtSYNTH3","credentials":"crSYNTH4","private_key":"pkSYNTH5"}' 500
Assert-T ((($rK -notmatch 'SYNTH') -and ($rK -match '\[REDACTED\]'))) 'redact-extended-keys' $rK
$rH = Get-ProbeSafeText 'Authorization: Bearer mytokenSYNTH123' 400
Assert-T ((($rH -notmatch 'mytokenSYNTH123') -and ($rH -match 'Authorization: \[REDACTED\]'))) 'redact-auth-header' $rH
$rB = Get-ProbeSafeText 'use Bearer abcDEF123xyz now' 400
Assert-T ((($rB -notmatch 'abcDEF123xyz') -and ($rB -match 'Bearer \[REDACTED\]'))) 'redact-bearer-standalone' $rB
$rKV = Get-ProbeSafeText 'api_key=SYNTHETIC_CREDENTIAL_123' 400
Assert-T ((($rKV -notmatch 'SYNTHETIC') -and ($rKV -match '\[REDACTED\]'))) 'redact-keyvalue-form' $rKV
$rP1 = Get-ProbeSafeText 'key sk-SYNTHETIC12345 end' 400
Assert-T ((($rP1 -notmatch 'SYNTHETIC') -and ($rP1 -match '\[REDACTED\]'))) 'redact-sk-prefix' $rP1
$rP2 = Get-ProbeSafeText 'ghp_SYNTHETIC_CREDENTIAL_123 and github_pat_SYNTH123abc and xoxb-SYNTH12345' 500
Assert-T ((($rP2 -notmatch 'SYNTH') -and ($rP2 -match '\[REDACTED\]'))) 'redact-ghp-pat-xox' $rP2
$rP3 = Get-ProbeSafeText 'AKIAIOSFODNN7EXAMPLE' 400
Assert-T ((($rP3 -notmatch 'AKIAIOSFODNN7EXAMPLE') -and ($rP3 -match '\[REDACTED\]'))) 'redact-akia' $rP3
$rP4 = Get-ProbeSafeText 'AIzaSySYNTHETIC_EXAMPLE_KEY_1234567' 400
Assert-T ((($rP4 -notmatch 'SYNTHETIC') -and ($rP4 -match '\[REDACTED\]'))) 'redact-aiza' $rP4
$rU = Get-ProbeSafeText 'see https://example.com/secret?x=1 ok' 400
Assert-T (($rU -match '\[REDACTED-URL\]')) 'redact-url-regression' $rU
# 7b. HIGH FIX2: JSON escapado (desescape progressivo; canarios sinteticos)
$script:ProbeSanitizeFallback = $false
$e1 = Get-ProbeSafeText '{\"ToKen\":\"SYNTH_ESCAPED_123\"}' 400
Assert-T ((($e1 -notmatch 'SYNTH_ESCAPED_123') -and ($e1 -match '\[REDACTED'))) 'redact-escaped-json-simple' $e1
$e2 = Get-ProbeSafeText '{\\\"password\\\":\\\"SYNTH_DOUBLE_ESC_456\\\"}' 400
Assert-T ((($e2 -notmatch 'SYNTH_DOUBLE_ESC_456') -and ($e2 -match '\[REDACTED'))) 'redact-escaped-json-double' $e2
$e3 = Get-ProbeSafeText '{"outer":"{\\"api_key\\":\\"SYNTH_NESTED_789\\"}"}' 500
Assert-T ((($e3 -notmatch 'SYNTH_NESTED_789') -and ($e3 -match '\[REDACTED'))) 'redact-escaped-json-nested' $e3
$e4 = Get-ProbeSafeText '{\"secret\":\"abc\\\"defSYNTH_SUFFIX_321\"}' 500
Assert-T ((($e4 -notmatch 'SYNTH_SUFFIX_321') -and ($e4 -notmatch 'abc') -and ($e4 -match '\[REDACTED'))) 'redact-escaped-quote-suffix' $e4
Assert-T ((-not [bool]$script:ProbeSanitizeFallback)) 'redact-escaped-no-fallback' 'fallback disparou sem necessidade'
# 7c. FIX3: sem heuristica de contagem; atribuicao com aspas; residual real
$script:ProbeSanitizeFallback = $false
$e5 = Get-ProbeSafeText '{\\\"ToKeN\\\":\\\"SYNTH_TRIPLE_111\\\"}' 400
Assert-T ((($e5 -notmatch 'SYNTH_TRIPLE_111') -and ($e5 -match '\[REDACT'))) 'redact-escaped-triple' $e5
$e6 = Get-ProbeSafeText 'token="SYNTH_QUOTED_123"' 400
Assert-T ((($e6 -notmatch 'SYNTH_QUOTED_123') -and ($e6 -match '\[REDACTED\]'))) 'redact-quoted-value' $e6
$e6b = Get-ProbeSafeText "password='SYNTH_SQ_456'" 400
Assert-T ((($e6b -notmatch 'SYNTH_SQ_456') -and ($e6b -match '\[REDACTED\]'))) 'redact-singlequoted-value' $e6b
$e7 = Get-ProbeSafeText '{"service":"playwright","status":"connected"}' 400
Assert-T ((($e7 -match 'playwright') -and ($e7 -match 'connected') -and ($e7 -notmatch '\[REDACTED'))) 'redact-clean-preserved' $e7
$e8 = Get-ProbeSafeText '{\"service\":\"playwright\"}' 400
Assert-T ((($e8 -match 'playwright') -and ($e8 -notmatch '\[REDACTED'))) 'redact-clean-escaped-preserved' $e8
Assert-T ((-not [bool]$script:ProbeSanitizeFallback)) 'redact-fix3-no-fallback' 'fallback disparou sem necessidade'
Assert-T ((Test-ProbeSensitiveResidual 'token="abc"') -and (-not (Test-ProbeSensitiveResidual 'token="[REDACTED]"')) -and (Test-ProbeSensitiveResidual 'sk-abc123')) 'residual-detector' 'Test-ProbeSensitiveResidual incorreto'
$script:ProbeSanitizeFallback = $false
$eD = Get-ProbeSafeText '[REDACTED]XSYNTH_CANARY_123' 400
Assert-T ((($eD -notmatch 'SYNTH_CANARY_123') -and ($eD -ceq '[REDACTED-UNSAFE]'))) 'redact-dangling-literal' $eD
Assert-T ([bool]$script:ProbeSanitizeFallback) 'redact-dangling-flag' 'fallback nao registrado no dangling'
$script:ProbeSanitizeFallback = $false
$eF = Get-ProbeSafeText '{token:"SYNTH_FALLBACK_999}' 400
Assert-T ((($eF -notmatch 'SYNTH_FALLBACK_999') -and ($eF -match '\[REDACTED-UNSAFE\]'))) 'redact-fallback-field' $eF
Assert-T ([bool]$script:ProbeSanitizeFallback) 'redact-fallback-flag' 'sanitize_fallback nao registrado'
Assert-T (($src -match 'sanitize_fallback')) 'redact-fallback-in-summary' 'resumo nao registra sanitize_fallback'
# 8. MEDIUM: veredito 100% estrutural (texto nunca cria presenca/ausencia)
# 8a. contagem MCP por sessao: superficie MCP, subagent excluida, failed separado
$mc1 = Get-ProbeMcpToolCounts @('take_snapshot/completed', 'browser_snapshot/failed', 'subagent/completed', 'some_other_tool/completed')
Assert-T (((@($mc1.executed).Count -eq 1) -and (@($mc1.other).Count -eq 1))) 'mcp-counts-split' ('exec=[' + (($mc1.executed) -join ',') + '] other=[' + (($mc1.other) -join ',') + ']')
$mc2 = Get-ProbeMcpToolCounts @('Take_Snapshot/Completed', 'browser_navigate/unknown')
Assert-T (((@($mc2.executed).Count -eq 1) -and (@($mc2.other).Count -eq 1))) 'mcp-counts-case-unknown' ('exec=[' + (($mc2.executed) -join ',') + '] other=[' + (($mc2.other) -join ',') + ']')
$mc3 = Get-ProbeMcpToolCounts @('subagent/completed')
Assert-T (((@($mc3.executed).Count -eq 0) -and (@($mc3.other).Count -eq 0))) 'mcp-counts-subagent-excluded' ('exec=' + (@($mc3.executed).Count) + ' other=' + (@($mc3.other).Count))
# 8b. H1 = presenca estrutural (child-only e parent-only)
$vH1c = Get-ProbeVerdict -TurnAOk $true -TurnBOk $true -MsgAOk $true -ChildMsgOk $true -ParentANames @() -ChildNames @('take_snapshot/completed')
Assert-T ((([string]$vH1c.decision -ceq 'H1') -and ([string]$vH1c.basis -ceq 'structural') -and ([string]$vH1c.reason -match 'take_snapshot/completed'))) 'verdict-h1-child-only' ([string]$vH1c.decision + ' basis=' + [string]$vH1c.basis + ' ' + [string]$vH1c.reason)
$vH1p = Get-ProbeVerdict -TurnAOk $true -TurnBOk $true -MsgAOk $true -ChildMsgOk $true -ParentANames @('browser_snapshot/completed') -ChildNames @()
Assert-T (([string]$vH1p.decision -ceq 'H1')) 'verdict-h1-parent-only' ([string]$vH1p.decision + ' ' + [string]$vH1p.reason)
# 8c. H0 = ausencia verificada (leituras completas + zero MCP)
$vH0 = Get-ProbeVerdict -TurnAOk $true -TurnBOk $true -MsgAOk $true -ChildMsgOk $true -ParentANames @() -ChildNames @()
Assert-T ((([string]$vH0.decision -ceq 'H0') -and ([string]$vH0.basis -ceq 'structural'))) 'verdict-h0-absence' ([string]$vH0.decision + ' basis=' + [string]$vH0.basis + ' ' + [string]$vH0.reason)
# 8d. mencao negativa + zero tools + leitura parcial => inconclusive (texto nao decide)
$vMention = 'Playwright and DevTools unavailable in this session.'
$vTx = Get-ProbeVerdict -TurnAOk $true -TurnBOk $true -MsgAOk $false -ChildMsgOk $true -ParentANames @() -ChildNames @()
Assert-T ((([string]$vTx.decision -ceq 'inconclusive') -and ([string]$vTx.basis -ceq 'textual'))) 'verdict-mention-unavailable-inconclusive' ([string]$vTx.decision + ' basis=' + [string]$vTx.basis + ' mention=[' + $vMention + ']')
$fVerdict = Get-TFunctionText $src 'Get-ProbeVerdict'
Assert-T ((($fVerdict -notmatch 'ASees') -and ($fVerdict -notmatch 'sees_playwright') -and ($fVerdict -notmatch 'ParentBToolCount'))) 'verdict-no-textual-inputs' 'veredito ainda recebe sinal textual'
# 8e. apenas chamada subagent (excluida) + child indisponivel => inconclusive
$vSub = Get-ProbeVerdict -TurnAOk $true -TurnBOk $true -MsgAOk $true -ChildMsgOk $false -ParentANames @() -ChildNames @('subagent/completed')
Assert-T (([string]$vSub.decision -ceq 'inconclusive')) 'verdict-subagent-only-inconclusive' ([string]$vSub.decision + ' ' + [string]$vSub.reason)
# 8f. child indisponivel invalida ate presenca no parent => inconclusive
$vNc = Get-ProbeVerdict -TurnAOk $true -TurnBOk $true -MsgAOk $true -ChildMsgOk $false -ParentANames @('take_snapshot/completed') -ChildNames @()
Assert-T (([string]$vNc.decision -ceq 'inconclusive')) 'verdict-child-unavailable-inconclusive' ([string]$vNc.decision + ' ' + [string]$vNc.reason)
# 8g. failed/denied: bloqueia H0 sem estabelecer H1 => inconclusive (explicito)
$vFail = Get-ProbeVerdict -TurnAOk $true -TurnBOk $true -MsgAOk $true -ChildMsgOk $true -ParentANames @() -ChildNames @('take_snapshot/failed')
Assert-T (([string]$vFail.decision -ceq 'inconclusive')) 'verdict-failed-not-proof' ([string]$vFail.decision + ' ' + [string]$vFail.reason)
$vDeny = Get-ProbeVerdict -TurnAOk $true -TurnBOk $true -MsgAOk $true -ChildMsgOk $true -ParentANames @('browser_snapshot/denied') -ChildNames @()
Assert-T (([string]$vDeny.decision -ceq 'inconclusive')) 'verdict-denied-not-proof' ([string]$vDeny.decision + ' ' + [string]$vDeny.reason)
# 8h. timeout parcial => inconclusive
$vTo = Get-ProbeVerdict -TurnAOk $false -TurnBOk $true -MsgAOk $true -ChildMsgOk $true -ParentANames @('take_snapshot/completed') -ChildNames @()
Assert-T (([string]$vTo.decision -ceq 'inconclusive')) 'verdict-timeout-partial-inconclusive' ([string]$vTo.decision + ' ' + [string]$vTo.reason)
# 8i. FIX3: pipeline REAL (GET stub -> conversor -> coletor -> veredito)
$script:ProbeFakeOutput = ''
$script:Exe = 'fake-exe'
function Invoke-PreflightBoundedExe { param([string]$File = '', [string]$ArgsLine = '', [string]$WorkDir = '', $EnvTable = $null, [string[]]$EnvRemove = @(), [int]$TimeoutMs = 0, [int]$MaxChars = 0) return @{ Finished = $true; ExitCode = 0; Output = [string]$script:ProbeFakeOutput } }
$script:ProbeFakeOutput = 'THIS-IS-NOT-JSON{{{'
$rInv = Get-ProbeSessionMessageToolEvidence -ServeUrl 'http://127.0.0.1:9' -WorkDir $RepoRoot -SessionId 'ses_test'
Assert-T (((-not [bool]$rInv.ok) -and (-not [bool]$rInv.parse_ok))) 'pipeline-invalid-json-not-ok' ('ok=' + [bool]$rInv.ok + ' parse_ok=' + [bool]$rInv.parse_ok + ' reason=' + [string]$rInv.reason)
$vInv = Get-ProbeVerdict -TurnAOk $true -TurnBOk $true -MsgAOk ([bool]$rInv.ok) -ChildMsgOk $true -ParentANames @() -ChildNames @()
Assert-T (([string]$vInv.decision -ceq 'inconclusive')) 'pipeline-invalid-verdict-inconclusive' ([string]$vInv.decision + ' ' + [string]$vInv.reason)
$script:ProbeFakeOutput = '{"data":[{"content":'
$rTrunc = Get-ProbeSessionMessageToolEvidence -ServeUrl 'http://127.0.0.1:9' -WorkDir $RepoRoot -SessionId 'ses_test'
Assert-T (((-not [bool]$rTrunc.ok) -and (-not [bool]$rTrunc.parse_ok))) 'pipeline-truncated-not-ok' ('ok=' + [bool]$rTrunc.ok + ' parse_ok=' + [bool]$rTrunc.parse_ok)
$script:ProbeFakeOutput = ''
$rEmpty = Get-ProbeSessionMessageToolEvidence -ServeUrl 'http://127.0.0.1:9' -WorkDir $RepoRoot -SessionId 'ses_test'
Assert-T (((-not [bool]$rEmpty.ok) -and (-not [bool]$rEmpty.parse_ok))) 'pipeline-empty-not-ok' ('ok=' + [bool]$rEmpty.ok + ' parse_ok=' + [bool]$rEmpty.parse_ok)
# FIX4: JSON valido != transcript valido (envelope data[] exigido)
$script:ProbeFakeOutput = '42'
$r42 = Get-ProbeSessionMessageToolEvidence -ServeUrl 'http://127.0.0.1:9' -WorkDir $RepoRoot -SessionId 'ses_test'
Assert-T (((-not [bool]$r42.ok) -and (-not [bool]$r42.parse_ok))) 'pipeline-42-no-envelope' ('ok=' + [bool]$r42.ok + ' parse_ok=' + [bool]$r42.parse_ok + ' reason=' + [string]$r42.reason)
$v42 = Get-ProbeVerdict -TurnAOk $true -TurnBOk $true -MsgAOk ([bool]$r42.ok) -ChildMsgOk $true -ParentANames @() -ChildNames @()
Assert-T (([string]$v42.decision -ceq 'inconclusive')) 'pipeline-42-inconclusive' ([string]$v42.decision + ' ' + [string]$v42.reason)
$script:ProbeFakeOutput = '{"error":"unavailable"}'
$rErr = Get-ProbeSessionMessageToolEvidence -ServeUrl 'http://127.0.0.1:9' -WorkDir $RepoRoot -SessionId 'ses_test'
Assert-T (((-not [bool]$rErr.ok) -and (-not [bool]$rErr.parse_ok))) 'pipeline-error-no-envelope' ('ok=' + [bool]$rErr.ok + ' parse_ok=' + [bool]$rErr.parse_ok + ' reason=' + [string]$rErr.reason)
$vErr = Get-ProbeVerdict -TurnAOk $true -TurnBOk $true -MsgAOk ([bool]$rErr.ok) -ChildMsgOk $true -ParentANames @() -ChildNames @()
Assert-T (([string]$vErr.decision -ceq 'inconclusive')) 'pipeline-error-inconclusive' ([string]$vErr.decision + ' ' + [string]$vErr.reason)
$script:ProbeFakeOutput = '{}'
$rEmptyObj = Get-ProbeSessionMessageToolEvidence -ServeUrl 'http://127.0.0.1:9' -WorkDir $RepoRoot -SessionId 'ses_test'
Assert-T (((-not [bool]$rEmptyObj.ok) -and (-not [bool]$rEmptyObj.parse_ok))) 'pipeline-emptyobj-no-envelope' ('ok=' + [bool]$rEmptyObj.ok + ' parse_ok=' + [bool]$rEmptyObj.parse_ok + ' reason=' + [string]$rEmptyObj.reason)
$vEmptyObj = Get-ProbeVerdict -TurnAOk $true -TurnBOk $true -MsgAOk ([bool]$rEmptyObj.ok) -ChildMsgOk $true -ParentANames @() -ChildNames @()
Assert-T (([string]$vEmptyObj.decision -ceq 'inconclusive')) 'pipeline-emptyobj-inconclusive' ([string]$vEmptyObj.decision + ' ' + [string]$vEmptyObj.reason)
$script:ProbeFakeOutput = '{"data":[]}'
$rEmptyData = Get-ProbeSessionMessageToolEvidence -ServeUrl 'http://127.0.0.1:9' -WorkDir $RepoRoot -SessionId 'ses_test'
Assert-T ((([bool]$rEmptyData.ok) -and ([bool]$rEmptyData.parse_ok) -and ([int]$rEmptyData.count -eq 0))) 'pipeline-empty-envelope-ok' ('ok=' + [bool]$rEmptyData.ok + ' parse_ok=' + [bool]$rEmptyData.parse_ok + ' count=' + [int]$rEmptyData.count)
$script:ProbeFakeOutput = '{"data":[{"content":[{"type":"tool","name":"take_snapshot","content":[{"type":"text","text":"ok"}]}]}]}'
$rNoStatus = Get-ProbeSessionMessageToolEvidence -ServeUrl 'http://127.0.0.1:9' -WorkDir $RepoRoot -SessionId 'ses_test'
Assert-T ((([bool]$rNoStatus.ok) -and ([bool]$rNoStatus.parse_ok) -and (@($rNoStatus.names) -contains 'take_snapshot/unknown'))) 'pipeline-empty-status-unknown' ('ok=' + [bool]$rNoStatus.ok + ' names=[' + (($rNoStatus.names) -join ',') + ']')
$vNoStatus = Get-ProbeVerdict -TurnAOk $true -TurnBOk $true -MsgAOk ([bool]$rNoStatus.ok) -ChildMsgOk $true -ParentANames @($rNoStatus.names) -ChildNames @()
Assert-T (([string]$vNoStatus.decision -ceq 'inconclusive')) 'pipeline-empty-status-not-h0' ([string]$vNoStatus.decision + ' ' + [string]$vNoStatus.reason)
$script:ProbeFakeOutput = '{"data":[{"content":[{"type":"tool","name":"take_snapshot","state":{"status":"completed"},"content":[{"type":"text","text":"ok"}]}]}]}'
$rGood = Get-ProbeSessionMessageToolEvidence -ServeUrl 'http://127.0.0.1:9' -WorkDir $RepoRoot -SessionId 'ses_test'
Assert-T ((([bool]$rGood.ok) -and ([bool]$rGood.parse_ok) -and (@($rGood.names) -contains 'take_snapshot/completed'))) 'pipeline-valid-tool-ok' ('ok=' + [bool]$rGood.ok + ' names=[' + (($rGood.names) -join ',') + ']')
$vGood = Get-ProbeVerdict -TurnAOk $true -TurnBOk $true -MsgAOk $true -ChildMsgOk ([bool]$rGood.ok) -ParentANames @() -ChildNames @($rGood.names)
Assert-T (([string]$vGood.decision -ceq 'H1')) 'pipeline-valid-tool-h1' ([string]$vGood.decision + ' ' + [string]$vGood.reason)
Assert-T (($src -match 'Get-ProbeVerdict -TurnAOk')) 'verdict-wired-in-probe' 'decision block nao chama Get-ProbeVerdict'
Assert-T (($src -match "basis = \[string\]\`$vd\.basis")) 'verdict-basis-in-summary' 'basis nao chega ao resumo'
# 9. MEDIUM: cleanup fail-closed (fault-injection via stubs; sem processo real)
$script:ProbeFaultStop = 'ok'
$script:ProbeFaultClose = 'ok'
function Stop-RuntimeJobObject { param($Job) if ([string]$script:ProbeFaultStop -ceq 'fail') { return @{ Ok = $false; Settled = $false } }; if ([string]$script:ProbeFaultStop -ceq 'null') { return $null }; if ([string]$script:ProbeFaultStop -ceq 'throw') { throw 'injected-stop-throw' }; if ([string]$script:ProbeFaultStop -ceq 'unsettled') { return @{ Ok = $true; Settled = $false } }; return @{ Ok = $true; Settled = $true } }
function Close-RuntimeJobObject { param($Job) if ([string]$script:ProbeFaultClose -ceq 'fail') { return @{ Ok = $false; Closed = $false } }; if ([string]$script:ProbeFaultClose -ceq 'throw') { throw 'injected-close-throw' }; return @{ Ok = $true; Closed = $true } }
function Wait-ProbeOwnedExit { param([int]$DeadlineSeconds = 30) return @() }
$script:OwnedJobs = New-Object System.Collections.ArrayList
$script:OwnedProcs = New-Object System.Collections.ArrayList
[void]$script:OwnedJobs.Add(@{ id = 'fake-job-1' })
$script:ProbeFaultStop = 'ok'; $script:ProbeFaultClose = 'ok'
$rOk = Stop-ProbeOwned 'test-ok'
Assert-T ((([bool]$rOk.ok) -and [bool]$rOk.settled -and (@($rOk.unknown).Count -eq 0))) 'cleanup-ok-propagates' ('ok=' + [bool]$rOk.ok + ' settled=' + [bool]$rOk.settled)
[void]$script:OwnedJobs.Add(@{ id = 'fake-job-1' })
$script:ProbeFaultStop = 'fail'
$rSf = Stop-ProbeOwned 'test-stop-fail'
Assert-T (((-not [bool]$rSf.ok) -and (@($rSf.stopFailures).Count -gt 0))) 'cleanup-stop-failed' ('ok=' + [bool]$rSf.ok)
[void]$script:OwnedJobs.Add(@{ id = 'fake-job-1' })
$script:ProbeFaultStop = 'null'
$rN = Stop-ProbeOwned 'test-stop-null'
Assert-T (((-not [bool]$rN.ok) -and (@($rN.unknown).Count -gt 0))) 'cleanup-stop-null-unknown' ('ok=' + [bool]$rN.ok)
[void]$script:OwnedJobs.Add(@{ id = 'fake-job-1' })
$script:ProbeFaultStop = 'throw'
$rTh = Stop-ProbeOwned 'test-stop-throw'
Assert-T (((-not [bool]$rTh.ok) -and (@($rTh.unknown).Count -gt 0))) 'cleanup-stop-throw-unknown' ('ok=' + [bool]$rTh.ok)
[void]$script:OwnedJobs.Add(@{ id = 'fake-job-1' })
$script:ProbeFaultStop = 'unsettled'
$rUs = Stop-ProbeOwned 'test-stop-unsettled'
Assert-T ((-not [bool]$rUs.ok)) 'cleanup-stop-unsettled-fails' ('ok=' + [bool]$rUs.ok)
[void]$script:OwnedJobs.Add(@{ id = 'fake-job-1' })
$script:ProbeFaultStop = 'ok'; $script:ProbeFaultClose = 'fail'
$rCf = Stop-ProbeOwned 'test-close-fail'
Assert-T (((-not [bool]$rCf.ok) -and (@($rCf.closeFailures).Count -gt 0))) 'cleanup-close-failed' ('ok=' + [bool]$rCf.ok)
[void]$script:OwnedJobs.Add(@{ id = 'fake-job-1' })
$script:ProbeFaultClose = 'throw'
$rCt = Stop-ProbeOwned 'test-close-throw'
Assert-T (((-not [bool]$rCt.ok) -and (@($rCt.unknown).Count -gt 0))) 'cleanup-close-throw-unknown' ('ok=' + [bool]$rCt.ok)
$script:ProbeFaultStop = 'ok'; $script:ProbeFaultClose = 'ok'
$badProc = New-Object PSObject
$badProc | Add-Member -MemberType NoteProperty -Name Id -Value 999991
$badProc | Add-Member -MemberType ScriptMethod -Name Refresh -Value { throw 'injected-refresh-throw' }
[void]$script:OwnedProcs.Add($badProc)
$rPu = Stop-ProbeOwned 'test-proc-unknown'
Assert-T (((-not [bool]$rPu.ok) -and (@($rPu.unknown).Count -gt 0))) 'cleanup-proc-state-unknown' ('ok=' + [bool]$rPu.ok)
Assert-T ((($src -match 'cleanupUnknown') -and ($src -match 'cleanupStopBad') -and ($src -match 'cleanupCloseBad'))) 'finally-propagates-ok-settled' 'finally nao propaga Ok/Settled/unknown'
# 10. MEDIUM: gate operacional fail-closed (nome sem estado bloqueia)
$mcNameOnly = '{"data":[{"name":"playwright"}]}'
$tNameOnly = Test-ProbeMcpOperational $mcNameOnly @('playwright')
Assert-T (((-not [bool]$tNameOnly.ok) -and (@($tNameOnly.missing) -contains 'playwright'))) 'name-only-blocks' ('missing=[' + (($tNameOnly.missing) -join ',') + ']')
$mcBothNames = '{"data":{"playwright":{"name":"playwright"},"chrome-devtools":{"name":"chrome-devtools"}}}'
$tBothNames = Test-ProbeMcpOperational $mcBothNames @('playwright', 'chrome-devtools')
Assert-T ((-not [bool]$tBothNames.ok)) 'names-only-block' ('missing=[' + (($tBothNames.missing) -join ',') + ']')
Assert-T (($src -notmatch 'if \(-not \$hasState\)')) 'no-failopen-line' 'linha fail-open ainda presente'
if ([int]$script:Fail -gt 0) { Write-Host ('[probe-test] RESULT FAIL (' + [int]$script:Fail + ')'); exit 1 }
Write-Host '[probe-test] RESULT PASS'
exit 0
