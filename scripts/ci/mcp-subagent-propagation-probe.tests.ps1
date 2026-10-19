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
foreach ($fn in @('Get-JsonProp', 'Get-ProbeJsonCandidates', 'Add-ProbeToolRecordsFromObject', 'Get-ProbeToolEvidence', 'Convert-ProbeMessageJsonToToolText', 'Get-ProbeDiscoveryScore', 'Test-ProbeMcpOperational', 'Wait-ProbeMcpNames', 'Get-ProbeSessionMessageToolEvidence')) {
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
if ([int]$script:Fail -gt 0) { Write-Host ('[probe-test] RESULT FAIL (' + [int]$script:Fail + ')'); exit 1 }
Write-Host '[probe-test] RESULT PASS'
exit 0
