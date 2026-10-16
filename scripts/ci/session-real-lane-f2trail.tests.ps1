# session-real-lane-f2trail.tests.ps1 -- F2 (trilha lifecycle advisory-only).
# Testes offline da trilha minima em scripts/ci/session-real-lane-v2.ps1:
# 1. Wait-LaneListener captura OwningPID sem quebrar Seen/Absent/Inconclusive.
# 2. Append JSONL advisory-only: confinado, bounded, sanitizado, nunca gate.
# 3. EXPECTED_TEST_RESTART nos 5 pontos + EXPECTED_TEST_STOP no final.
# Sem Pester. Sem rede/spawn/modelo/servico: helpers extraidos via AST (a
# lane nunca e executada) e exercitados em memoria com doubles sinteticos;
# o resto sao asserts estaticos sobre o texto da lane. So IDs/canarios
# sinteticos (SYN-*); nenhum segredo real. PS 5.1 e PS7 compativel.
# ASCII only.
$ErrorActionPreference = 'Stop'
$script:LanePath = Join-Path $PSScriptRoot 'session-real-lane-v2.ps1'
$script:total = 0
$script:passed = 0
function Assert-That($condition, $name, $detail) {
    $script:total++
    if ($condition) { $script:passed++; Write-Host "[PASS] $name" }
    else { Write-Host "[FAIL] $name -- $detail" }
}
try {
    Assert-That (Test-Path -LiteralPath $script:LanePath -PathType Leaf) 'lane file exists' $script:LanePath
    $text = ''
    try { $text = [IO.File]::ReadAllText($script:LanePath) } catch { $text = '' }
    Assert-That (-not [string]::IsNullOrEmpty($text)) 'lane text readable' 'empty'
    $tokens = $null
    $parseErrors = $null
    $ast = $null
    try { $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$parseErrors) } catch { $ast = $null }
    Assert-That (($null -ne $ast) -and ($null -ne $parseErrors) -and (@($parseErrors).Count -eq 0)) 'lane parses without syntax errors' ('errors=' + @($parseErrors).Count)
    $funcs = @{}
    try {
        $found = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        foreach ($f in @($found)) { $funcs[[string]$f.Name] = [string]$f.Extent.Text }
    } catch { }
    $need = @('Get-LaneSafeText', 'Get-LaneTimestampUtc', 'Get-LaneTrailPath', 'Get-LaneCurrentListenerPid', 'Write-LaneTrailEvent', 'Write-LaneServiceCycleTrail', 'Wait-LaneListener')
    foreach ($fn in @($need)) {
        Assert-That ($funcs.ContainsKey($fn)) ("helper $fn exists") 'RED: helper ausente na lane'
    }
    # ---- doubles: stub do probe de listener + estado isolado em TEMP ----
    function Get-PreflightNetTCPListenerBounded { param($Port, $TimeoutMs) return $script:StubListener }
    $script:StubListener = $null
    $script:Port = 45678
    $tmpTrail = Join-Path ([IO.Path]::GetTempPath()) ('oo-f2trail-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmpTrail -Force | Out-Null
    $script:EvidenceDir = $tmpTrail
    $script:LaneTrailMaxBytes = 262144
    if (($funcs.ContainsKey('Get-LaneSafeText')) -and ($funcs.ContainsKey('Get-LaneTimestampUtc')) -and ($funcs.ContainsKey('Get-LaneTrailPath')) -and ($funcs.ContainsKey('Get-LaneCurrentListenerPid')) -and ($funcs.ContainsKey('Write-LaneTrailEvent')) -and ($funcs.ContainsKey('Write-LaneServiceCycleTrail')) -and ($funcs.ContainsKey('Wait-LaneListener'))) {
        Invoke-Expression $funcs['Get-LaneSafeText']
        Invoke-Expression $funcs['Get-LaneTimestampUtc']
        Invoke-Expression $funcs['Get-LaneTrailPath']
        Invoke-Expression $funcs['Get-LaneCurrentListenerPid']
        Invoke-Expression $funcs['Write-LaneTrailEvent']
        Invoke-Expression $funcs['Write-LaneServiceCycleTrail']
        Invoke-Expression $funcs['Wait-LaneListener']
        # ---- 1. OwningPID sem quebrar o contrato Seen/Absent/Inconclusive ----
        $script:StubListener = [pscustomobject]@{ QuerySucceeded = $true; Exists = $true; OwningPID = 4242 }
        $rPres = Wait-LaneListener -DeadlineSeconds 2 -Mode 'presence'
        Assert-That (([bool]$rPres.Seen) -and ([int]$rPres.OwningPID -eq 4242) -and ([int]$rPres.Inconclusive -eq 0)) 'presence: Seen + OwningPID capturado' ('seen=' + [bool]$rPres.Seen + ' pid=' + $rPres.OwningPID)
        Assert-That ((($rPres.Keys -contains 'Seen') -and ($rPres.Keys -contains 'Absent') -and ($rPres.Keys -contains 'Inconclusive') -and ($rPres.Keys -contains 'OwningPID'))) 'retorno preserva Seen/Absent/Inconclusive + OwningPID' 'chave ausente'
        $script:StubListener = [pscustomobject]@{ QuerySucceeded = $true; Exists = $false; OwningPID = $null }
        $rAbs = Wait-LaneListener -DeadlineSeconds 2 -Mode 'absence'
        Assert-That (([bool]$rAbs.Absent) -and (-not [bool]$rAbs.Seen) -and ([int]$rAbs.OwningPID -eq 0)) 'absence: Absent sem PID (0)' ('absent=' + [bool]$rAbs.Absent + ' pid=' + $rAbs.OwningPID)
        $script:StubListener = [pscustomobject]@{ QuerySucceeded = $false; Exists = $false; OwningPID = $null }
        $rInc = Wait-LaneListener -DeadlineSeconds 2 -Mode 'presence'
        Assert-That (((-not [bool]$rInc.Seen) -and (-not [bool]$rInc.Absent) -and ([int]$rInc.Inconclusive -gt 0) -and ([int]$rInc.OwningPID -eq 0))) 'query falha: inconclusivo, sem PID' ('inc=' + [int]$rInc.Inconclusive)
        # ---- snapshot pontual: so trilha, nunca gate ----
        $script:StubListener = [pscustomobject]@{ QuerySucceeded = $true; Exists = $true; OwningPID = 5150 }
        Assert-That ((Get-LaneCurrentListenerPid) -eq 5150) 'snapshot retorna OwningPID' 'pid divergente'
        $script:StubListener = [pscustomobject]@{ QuerySucceeded = $true; Exists = $false; OwningPID = $null }
        Assert-That ((Get-LaneCurrentListenerPid) -eq 0) 'snapshot sem listener retorna 0' 'nao fail-closed'
        $script:Port = 0
        Assert-That ((Get-LaneCurrentListenerPid) -eq 0) 'snapshot sem porta retorna 0' 'nao fail-closed'
        $script:Port = 45678
        # ---- 2. trilha: caminho confinado, append, sanitizacao ----
        $trailPath = Get-LaneTrailPath
        Assert-That ((-not [string]::IsNullOrWhiteSpace($trailPath)) -and ([IO.Path]::GetFullPath($trailPath).StartsWith(([IO.Path]::GetFullPath($tmpTrail)), [StringComparison]::OrdinalIgnoreCase))) 'trilha confinada ao EvidenceDir' $trailPath
        $w1 = Write-LaneTrailEvent -Event 'SYN-EVENT' -Fields @{ site = 'SYN-SITE'; count_n = 3 }
        Assert-That ([bool]$w1) 'append advisory retorna true' 'write falhou'
        $lines1 = @([IO.File]::ReadAllLines($trailPath))
        Assert-That (@($lines1).Count -eq 1) 'uma linha JSONL por evento' ('count=' + @($lines1).Count)
        $doc1 = $null
        try { $doc1 = ConvertFrom-Json $lines1[0] } catch { $doc1 = $null }
        Assert-That (($null -ne $doc1) -and ([string]$doc1.event -ceq 'SYN-EVENT') -and ([bool]$doc1.advisory_only) -and ([string]$doc1.lane -ceq 'session-real-lane-v2') -and ([string]$doc1.site -ceq 'SYN-SITE')) 'linha carrega event/advisory_only/lane/site' 'shape divergente'
        $w2 = Write-LaneTrailEvent -Event 'SYN-SECRET' -Fields @{ note = 'token=abc123SYN deve redigir' }
        Assert-That ([bool]$w2) 'append com segredo candidato retorna true' 'write falhou'
        $rawTrail = [IO.File]::ReadAllText($trailPath)
        Assert-That ((($rawTrail -notmatch 'abc123SYN')) -and ($rawTrail -match '\[REDACTED\]')) 'valor com cara de segredo redigido' 'vazamento ou sem redacao'
        # evento vazio nunca escreve
        $beforeEmpty = @([IO.File]::ReadAllLines($trailPath)).Count
        $wEmpty = Write-LaneTrailEvent -Event '' -Fields $null
        Assert-That (((-not [bool]$wEmpty) -and (@([IO.File]::ReadAllLines($trailPath)).Count -eq $beforeEmpty))) 'evento vazio nao escreve' 'append espurio'
        # bounded: alem do teto, recusa sem crescer
        $script:LaneTrailMaxBytes = 10
        $lenBefore = ([IO.File]::ReadAllText($trailPath)).Length
        $wBound = Write-LaneTrailEvent -Event 'SYN-OVER-CAP' -Fields $null
        Assert-That (((-not [bool]$wBound) -and (([IO.File]::ReadAllText($trailPath)).Length -eq $lenBefore))) 'teto de bytes recusa append (bounded)' 'cresceu alem do teto'
        $script:LaneTrailMaxBytes = 262144
        Remove-Item -LiteralPath $trailPath -Force -ErrorAction SilentlyContinue
        # ---- 2b. teto preciso em bytes UTF-8 incluindo newline ----
        $mbChar = ([string][char]0xE9)
        $wProbe = Write-LaneTrailEvent -Event 'SYN-PROBE' -Fields @{ note = ('mb-' + $mbChar + '-SYN') }
        Assert-That ([bool]$wProbe) 'sonda de bytes escreve com teto folgado' 'write falhou'
        $probeLine = ''
        try { $probeLine = @([IO.File]::ReadAllLines($trailPath))[0] } catch { $probeLine = '' }
        $probeBytes = [long]0
        try { $probeBytes = [long](New-Object Text.UTF8Encoding $false).GetByteCount(($probeLine + "`n")) } catch { $probeBytes = [long]0 }
        $probeChars = [long](($probeLine + "`n").Length)
        Assert-That (([long]$probeBytes -gt [long]$probeChars)) 'sonda multibyte: bytes UTF-8 > chars' ('bytes=' + $probeBytes + ' chars=' + $probeChars)
        # exato: teto == bytes da linha permite (cur + linha == teto)
        Remove-Item -LiteralPath $trailPath -Force -ErrorAction SilentlyContinue
        $script:LaneTrailMaxBytes = [int]$probeBytes
        $wExact = Write-LaneTrailEvent -Event 'SYN-PROBE' -Fields @{ note = ('mb-' + $mbChar + '-SYN') }
        $exactLen = [long]0
        try { $exactLen = [long](Get-Item -LiteralPath $trailPath -ErrorAction SilentlyContinue).Length } catch { $exactLen = [long]0 }
        Assert-That (([bool]$wExact) -and ([long]$exactLen -eq [long]$probeBytes)) 'teto exato (cur+linha == teto) permite' ('ok=' + [bool]$wExact + ' len=' + $exactLen)
        # arquivo exatamente no teto: proxima linha recusada sem crescer
        $wAtCap = Write-LaneTrailEvent -Event 'SYN-PROBE' -Fields @{ note = ('mb-' + $mbChar + '-SYN') }
        $atCapLen = [long]0
        try { $atCapLen = [long](Get-Item -LiteralPath $trailPath -ErrorAction SilentlyContinue).Length } catch { $atCapLen = [long]0 }
        Assert-That (((-not [bool]$wAtCap) -and ([long]$atCapLen -eq [long]$exactLen))) 'arquivo no teto recusa proxima linha sem crescer' ('ok=' + [bool]$wAtCap + ' len=' + $atCapLen)
        # imediatamente inferior: teto == bytes-1 recusa sem criar
        Remove-Item -LiteralPath $trailPath -Force -ErrorAction SilentlyContinue
        $script:LaneTrailMaxBytes = ([int]$probeBytes - 1)
        $wUnder = Write-LaneTrailEvent -Event 'SYN-PROBE' -Fields @{ note = ('mb-' + $mbChar + '-SYN') }
        Assert-That (((-not [bool]$wUnder) -and (-not (Test-Path -LiteralPath $trailPath)))) 'um byte abaixo do exato recusa sem criar' ('ok=' + [bool]$wUnder)
        $script:LaneTrailMaxBytes = 262144
        Remove-Item -LiteralPath $trailPath -Force -ErrorAction SilentlyContinue
        # ---- 3. ciclo stop->start: vocabulario + classificacao ----
        $stop = [pscustomobject]@{ ExitCode = 0; TimedOut = $false }
        $start = [pscustomobject]@{ ExitCode = 0; TimedOut = $false; JobAssigned = $true }
        $settle = [ordered]@{ Absent = $true }
        $pres = [ordered]@{ Seen = $true; OwningPID = 7777 }
        $wc = Write-LaneServiceCycleTrail -Site 'SYN-SITE' -PidBefore 4242 -StopResult $stop -StartResult $start -Settle $settle -Presence $pres
        Assert-That ([bool]$wc) 'ciclo retorna true' 'helper falhou'
        $clines = @([IO.File]::ReadAllLines((Get-LaneTrailPath)))
        Assert-That (@($clines).Count -eq 6) 'ciclo com PID trocado emite 6 linhas (inclui PID_CHANGED)' ('count=' + @($clines).Count)
        $evNames = @()
        foreach ($cl in @($clines)) { try { $evNames += [string](ConvertFrom-Json $cl).event } catch { } }
        foreach ($ev in @('SERVICE_STOP_REQUESTED', 'SERVICE_STOPPED', 'SERVICE_START_REQUESTED', 'SERVICE_STARTED', 'EXPECTED_TEST_RESTART', 'PID_CHANGED')) {
            Assert-That (@($evNames) -contains $ev) ("ciclo contem $ev") 'evento ausente'
        }
        $restartDoc = $null
        foreach ($cl in @($clines)) { try { $d = ConvertFrom-Json $cl; if ([string]$d.event -ceq 'EXPECTED_TEST_RESTART') { $restartDoc = $d } } catch { } }
        Assert-That (($null -ne $restartDoc) -and ([string]$restartDoc.classification -ceq 'EXPECTED_TEST_RESTART') -and ([int]$restartDoc.pid_before -eq 4242) -and ([int]$restartDoc.pid_after -eq 7777) -and ([int]$restartDoc.port -eq 45678) -and ([bool]$restartDoc.job_assigned) -and ([int]$restartDoc.stop_rc -eq 0) -and ([bool]$restartDoc.settlement)) 'EXPECTED_TEST_RESTART carrega pid/porta/job/rc/settlement' 'campos divergentes'
        # PIDs iguais: sem PID_CHANGED (5 linhas)
        Remove-Item -LiteralPath (Get-LaneTrailPath) -Force -ErrorAction SilentlyContinue
        $presSame = [ordered]@{ Seen = $true; OwningPID = 4242 }
        [void](Write-LaneServiceCycleTrail -Site 'SYN-SAME' -PidBefore 4242 -StopResult $stop -StartResult $start -Settle $settle -Presence $presSame)
        $slines = @([IO.File]::ReadAllLines((Get-LaneTrailPath)))
        Assert-That ((@($slines).Count -eq 5) -and (([IO.File]::ReadAllText((Get-LaneTrailPath))) -notmatch 'PID_CHANGED')) 'PID igual nao emite PID_CHANGED' ('count=' + @($slines).Count)
        # resultados ausentes: NOT_OBSERVED, nunca excecao
        Remove-Item -LiteralPath (Get-LaneTrailPath) -Force -ErrorAction SilentlyContinue
        [void](Write-LaneServiceCycleTrail -Site 'SYN-NULL' -PidBefore 0 -StopResult $null -StartResult $null -Settle $null -Presence $null)
        $nraw = [IO.File]::ReadAllText((Get-LaneTrailPath))
        Assert-That (($nraw -match 'NOT_OBSERVED') -and ($nraw -match 'EXPECTED_TEST_RESTART')) 'resultados nulos viram NOT_OBSERVED' 'fail-closed quebrou'
        # sem stop e sem start: so EXPECTED_TEST_RESTART (1 linha)
        Remove-Item -LiteralPath (Get-LaneTrailPath) -Force -ErrorAction SilentlyContinue
        [void](Write-LaneServiceCycleTrail -Site 'SYN-NONULL' -PidBefore 0 -StopResult $null -StartResult $null -Settle $null -Presence $null)
        $zlines = @([IO.File]::ReadAllLines((Get-LaneTrailPath)))
        $zevs = @()
        foreach ($cl in @($zlines)) { try { $zevs += [string](ConvertFrom-Json $cl).event } catch { } }
        Assert-That (((@($zlines).Count -eq 1) -and (@($zevs) -contains 'EXPECTED_TEST_RESTART'))) 'sem operacoes: so EXPECTED_TEST_RESTART' ('count=' + @($zlines).Count)
        # caminho somente-start (post17-gate/pre19-gate): sem eventos de stop
        Remove-Item -LiteralPath (Get-LaneTrailPath) -Force -ErrorAction SilentlyContinue
        $startOnly = [pscustomobject]@{ ExitCode = 0; TimedOut = $false; JobAssigned = $true }
        $presOnly = [ordered]@{ Seen = $true; OwningPID = 8888 }
        [void](Write-LaneServiceCycleTrail -Site 'SYN-STARTONLY' -PidBefore 0 -StopResult $null -StartResult $startOnly -Settle $null -Presence $presOnly)
        $olines = @([IO.File]::ReadAllLines((Get-LaneTrailPath)))
        $oevs = @()
        foreach ($cl in @($olines)) { try { $oevs += [string](ConvertFrom-Json $cl).event } catch { } }
        Assert-That ((@($olines).Count -eq 3)) 'somente-start emite 3 linhas (sem stop)' ('count=' + @($olines).Count)
        Assert-That (((@($oevs) -contains 'SERVICE_START_REQUESTED') -and (@($oevs) -contains 'SERVICE_STARTED') -and (@($oevs) -contains 'EXPECTED_TEST_RESTART'))) 'somente-start contem start+restart' 'evento ausente'
        Assert-That ((((@($oevs) -contains 'SERVICE_STOP_REQUESTED') -eq $false) -and ((@($oevs) -contains 'SERVICE_STOPPED') -eq $false))) 'somente-start sem eventos de stop' 'stop espurio'
        # ordem real das operacoes no ciclo cheio: stop antes de start; ts nao-decrescentes
        $ordEv = @()
        $ordTs = @()
        foreach ($cl in @($clines)) { try { $dd = ConvertFrom-Json $cl; $ordEv += [string]$dd.event; $ordTs += [string]$dd.ts } catch { } }
        $expOrd = @('SERVICE_STOP_REQUESTED', 'SERVICE_STOPPED', 'SERVICE_START_REQUESTED', 'SERVICE_STARTED', 'EXPECTED_TEST_RESTART', 'PID_CHANGED')
        $ordOk = ((@($ordEv).Count -eq @($expOrd).Count))
        if ([bool]$ordOk) { for ($oi = 0; $oi -lt @($expOrd).Count; $oi++) { if ([string]$ordEv[$oi] -cne [string]$expOrd[$oi]) { $ordOk = $false; break } } }
        Assert-That ([bool]$ordOk) 'ciclo cheio preserva ordem stop->start->restart->pid' ('ordem=' + ($ordEv -join ','))
        $tsOk = $true
        for ($ti = 1; $ti -lt @($ordTs).Count; $ti++) { if ([string]$ordTs[$ti] -lt [string]$ordTs[$ti - 1]) { $tsOk = $false; break } }
        Assert-That ([bool]$tsOk) 'timestamps na ordem real das operacoes (nao-decrescentes)' 'ts fora de ordem'
        # ---- 3b. tentativa falha nao gera evento conclusivo (residual MEDIUM) ----
        # stop com timeout + Absent=false: so STOP_REQUESTED, sem STOPPED
        Remove-Item -LiteralPath (Get-LaneTrailPath) -Force -ErrorAction SilentlyContinue
        $stopTo = [pscustomobject]@{ ExitCode = 1; TimedOut = $true }
        $settleNeg = [ordered]@{ Absent = $false }
        [void](Write-LaneServiceCycleTrail -Site 'SYN-STOPTO' -PidBefore 4242 -StopResult $stopTo -StartResult $null -Settle $settleNeg -Presence $null)
        $toLines = @([IO.File]::ReadAllLines((Get-LaneTrailPath)))
        $toEvs = @()
        foreach ($cl in @($toLines)) { try { $toEvs += [string](ConvertFrom-Json $cl).event } catch { } }
        Assert-That (((@($toLines).Count -eq 2) -and (@($toEvs) -contains 'SERVICE_STOP_REQUESTED') -and (@($toEvs) -contains 'EXPECTED_TEST_RESTART'))) 'stop timeout+Absent=false: so REQUESTED+restart' ('count=' + @($toLines).Count + ' evs=' + ($toEvs -join ','))
        Assert-That ((((@($toEvs) -contains 'SERVICE_STOPPED') -eq $false))) 'stop falho nao emite SERVICE_STOPPED' 'conclusivo espurio'
        # start com Seen=false: so START_REQUESTED, sem STARTED
        Remove-Item -LiteralPath (Get-LaneTrailPath) -Force -ErrorAction SilentlyContinue
        $startNeg = [pscustomobject]@{ ExitCode = 0; TimedOut = $false; JobAssigned = $true }
        $presNeg = [ordered]@{ Seen = $false; OwningPID = 0 }
        [void](Write-LaneServiceCycleTrail -Site 'SYN-STARTNEG' -PidBefore 0 -StopResult $null -StartResult $startNeg -Settle $null -Presence $presNeg)
        $snLines = @([IO.File]::ReadAllLines((Get-LaneTrailPath)))
        $snEvs = @()
        foreach ($cl in @($snLines)) { try { $snEvs += [string](ConvertFrom-Json $cl).event } catch { } }
        Assert-That (((@($snLines).Count -eq 2) -and (@($snEvs) -contains 'SERVICE_START_REQUESTED') -and (@($snEvs) -contains 'EXPECTED_TEST_RESTART'))) 'start Seen=false: so REQUESTED+restart' ('count=' + @($snLines).Count + ' evs=' + ($snEvs -join ','))
        Assert-That ((((@($snEvs) -contains 'SERVICE_STARTED') -eq $false))) 'start sem presence nao emite SERVICE_STARTED' 'conclusivo espurio'
        # observacao nula com operacoes presentes: so REQUESTEDs, sem conclusivos
        Remove-Item -LiteralPath (Get-LaneTrailPath) -Force -ErrorAction SilentlyContinue
        $stopOk = [pscustomobject]@{ ExitCode = 0; TimedOut = $false }
        $startOk = [pscustomobject]@{ ExitCode = 0; TimedOut = $false; JobAssigned = $true }
        [void](Write-LaneServiceCycleTrail -Site 'SYN-NULLOBS' -PidBefore 0 -StopResult $stopOk -StartResult $startOk -Settle $null -Presence $null)
        $noLines = @([IO.File]::ReadAllLines((Get-LaneTrailPath)))
        $noEvs = @()
        foreach ($cl in @($noLines)) { try { $noEvs += [string](ConvertFrom-Json $cl).event } catch { } }
        Assert-That (((@($noLines).Count -eq 3) -and (@($noEvs) -contains 'SERVICE_STOP_REQUESTED') -and (@($noEvs) -contains 'SERVICE_START_REQUESTED') -and (@($noEvs) -contains 'EXPECTED_TEST_RESTART'))) 'observacao nula: so REQUESTEDs+restart' ('count=' + @($noLines).Count + ' evs=' + ($noEvs -join ','))
        Assert-That (((((@($noEvs) -contains 'SERVICE_STOPPED') -eq $false) -and ((@($noEvs) -contains 'SERVICE_STARTED') -eq $false)))) 'observacao nula nao emite conclusivos' 'conclusivo espurio'
        # restart carrega campos negativos quando sem observacao positiva
        $nullDoc = $null
        foreach ($cl in @($noLines)) { try { $d = ConvertFrom-Json $cl; if ([string]$d.event -ceq 'EXPECTED_TEST_RESTART') { $nullDoc = $d } } catch { } }
        Assert-That (($null -ne $nullDoc) -and ([string]$nullDoc.settlement -ceq 'NOT_OBSERVED') -and ([string]$nullDoc.presence_seen -ceq 'NOT_OBSERVED')) 'restart com observacao nula carrega NOT_OBSERVED' 'campos divergentes'
    }
    # ---- 4. estaticos: 5 pontos de restart + stop final, gates intactos ----
    $cycleSites = @([regex]::Matches($text, "Write-LaneServiceCycleTrail -Site '([^']+)'"))
    $siteNames = @()
    foreach ($m in @($cycleSites)) { $siteNames += $m.Groups[1].Value }
    foreach ($sn in @('RR-E2E-17', 'post17-gate', 'RR-E2E-18', 'pre19-gate', 'RR-E2E-19')) {
        Assert-That (@($siteNames) -contains $sn) ("ponto de restart com trilha: $sn") 'call ausente'
    }
    Assert-That (@($siteNames).Count -eq 5) 'exatamente 5 pontos de restart com trilha' ('count=' + @($siteNames).Count)
    $post17Call = "Write-LaneServiceCycleTrail -Site 'post17-gate' -PidBefore 0 -StopResult `$null"
    Assert-That ($text.Contains($post17Call)) 'post17-gate: somente-start (StopResult nulo)' 'call divergente'
    $pre19Call = "Write-LaneServiceCycleTrail -Site 'pre19-gate' -PidBefore 0 -StopResult `$null"
    Assert-That ($text.Contains($pre19Call)) 'pre19-gate: somente-start (StopResult nulo)' 'call divergente'
    Assert-That ($text.Contains("Write-LaneTrailEvent -Event 'EXPECTED_TEST_STOP'")) 'EXPECTED_TEST_STOP no encerramento' 'emit ausente'
    Assert-That ($text.Contains("classification = 'EXPECTED_TEST_STOP'")) 'STOP carrega classification' 'campo ausente'
    # ---- 3c. lane-final fail-closed: STOPPED so com settled=true ----
    Assert-That ($text.Contains("if ([bool]`$settledF)")) 'lane-final STOPPED guardado por settledF' 'guard ausente'
    $guardIdxF = $text.IndexOf("if ([bool]`$settledF)")
    $stopFinIdxF = $text.IndexOf("site = 'lane-final'; stop_rc")
    Assert-That ((($guardIdxF -ge 0) -and ($stopFinIdxF -gt $guardIdxF))) 'lane-final STOPPED apos guard settledF' 'ordem divergente'
    Assert-That ($text.Contains("Write-LaneTrailEvent -Event 'EXPECTED_TEST_STOP'")) 'lane-final STOP preservado com settlement negativo' 'emit ausente'
    # bloco REAL extraido da implementacao (brace matching) e executado de verdade
    $laneFinalSnippet = $null
    try {
        $openF = $text.IndexOf('{', $guardIdxF)
        $depthF = 0
        $posF = $openF
        $inStrF = $false
        while ($posF -lt $text.Length) {
            $chF = $text.Substring($posF, 1)
            if ($chF -ceq "'") { $inStrF = (-not $inStrF) }
            elseif (-not $inStrF) {
                if ($chF -ceq '{') { $depthF++ }
                elseif ($chF -ceq '}') { $depthF--; if ($depthF -le 0) { break } }
            }
            $posF++
        }
        $laneFinalSnippet = $text.Substring($guardIdxF, ($posF - $guardIdxF + 1))
    } catch { $laneFinalSnippet = $null }
    Assert-That (-not [string]::IsNullOrWhiteSpace($laneFinalSnippet)) 'bloco lane-final extraido da implementacao' 'extracao falhou'
    $laneFinalBlock = $null
    try { $laneFinalBlock = [ScriptBlock]::Create($laneFinalSnippet) } catch { $laneFinalBlock = $null }
    Assert-That ($null -ne $laneFinalBlock) 'bloco lane-final compila como ScriptBlock' 'parse falhou'
    Remove-Item -LiteralPath (Get-LaneTrailPath) -Force -ErrorAction SilentlyContinue
    $settledF = $false
    $stpF = [pscustomobject]@{ ExitCode = 1; TimedOut = $true }
    try { & $laneFinalBlock } catch { }
    $negRealStopped = $false
    if (Test-Path -LiteralPath (Get-LaneTrailPath)) {
        foreach ($cl in @([IO.File]::ReadAllLines((Get-LaneTrailPath)))) { try { if ([string](ConvertFrom-Json $cl).event -ceq 'SERVICE_STOPPED') { $negRealStopped = $true } } catch { } }
    }
    Assert-That ((-not $negRealStopped)) 'lane-final settled=false: bloco real nao emite STOPPED' 'conclusivo espurio'
    Remove-Item -LiteralPath (Get-LaneTrailPath) -Force -ErrorAction SilentlyContinue
    $settledF = $true
    $stpF = [pscustomobject]@{ ExitCode = 0; TimedOut = $false }
    try { & $laneFinalBlock } catch { }
    $posRealStopped = $false
    if (Test-Path -LiteralPath (Get-LaneTrailPath)) {
        foreach ($cl in @([IO.File]::ReadAllLines((Get-LaneTrailPath)))) { try { if ([string](ConvertFrom-Json $cl).event -ceq 'SERVICE_STOPPED') { $posRealStopped = $true } } catch { } }
    }
    Assert-That ($posRealStopped) 'lane-final settled=true: bloco real emite STOPPED' 'conclusivo ausente'
    $noUnexpected = @([regex]::Matches($text, "Write-LaneTrailEvent -Event 'UNEXPECTED_EXIT'"))
    Assert-That (@($noUnexpected).Count -eq 0) 'UNEXPECTED_EXIT segue NOT_OBSERVED (sem emit)' 'emit inesperado'
    foreach ($mev in @('MODEL_TURN_STARTED', 'MODEL_TURN_FINISHED')) {
        Assert-That ((@([regex]::Matches($text, "Write-LaneTrailEvent -Event '$mev'")).Count) -eq 3) "$mev nos 3 turnos (18/20/21)" 'count divergente'
    }
    Assert-That ($text.Contains("Write-LaneTrailEvent -Event 'LANE_START'")) 'LANE_START emitido' 'emit ausente'
    Assert-That ($text.Contains("Write-LaneTrailEvent -Event 'LANE_FINISHED'")) 'LANE_FINISHED emitido' 'emit ausente'
    Assert-That ($text.Contains("Write-LaneTrailEvent -Event 'LANE_CLEANUP'")) 'LANE_CLEANUP no finally' 'emit ausente'
    Assert-That ((@([regex]::Matches($text, "Wait-LaneListener -DeadlineSeconds")).Count) -eq 14) 'waits inalterados (14 calls)' 'wait adicionado/removido'
    Assert-That ((@([regex]::Matches($text, "'service', 'stop'")).Count) -eq 4) 'stops inalterados (4x)' 'stop adicionado/removido'
    Assert-That ((@([regex]::Matches($text, "'service', 'start'")).Count) -eq 6) 'starts inalterados (6x)' 'start adicionado/removido'
    Assert-That ($text.Contains('Fail-Lane (''service start: sem listener')) 'gate do start inicial preservado' 'gate alterado'
    Assert-That ($text.Contains("Fail-Lane 'servico indisponivel apos cenarios 16/17; lane abortada.'")) 'gate pos-16/17 preservado' 'gate alterado'
    Assert-That ($text.Contains("Fail-Lane 'servico indisponivel antes do cenario 19.'")) 'gate pre-19 preservado' 'gate alterado'
    Assert-That ($text.Contains("Fail-Lane 'invariante 49374 violada no encerramento.'")) 'invariante 49374 preservada' 'gate alterado'
    Assert-That ($text.Contains('foreach ($cc in @(''service_stop_owned'', ''service_settlement'', ''job_object_closed''))')) 'checks criticos de encerramento preservados' 'gate alterado'
    Assert-That ((@([regex]::Matches($text, '-TimeoutMs 180000')).Count) -eq 3) 'TimeoutMs 180000 intacto nos 3 turns' 'timeout alterado'
    $safeFn = ''
    if ($funcs.ContainsKey('Get-LaneSafeText')) { $safeFn = [string]$funcs['Get-LaneSafeText'] }
    Assert-That (($safeFn.Contains('param($Value, [int]$Max = 200)')) -and ($safeFn -notmatch 'OwningPID|LaneTrail|EXPECTED_TEST')) 'Get-LaneSafeText compartilhada intocada' 'assinatura alterada'
    # ---- NOLINT de segredos + ASCII-only ----
    $selfText = [IO.File]::ReadAllText($PSCommandPath)
    Assert-That (($selfText -notmatch 'sk-[A-Za-z0-9]') -and ($selfText -notmatch '(?i)password\s*=\s*[^=\s]')) 'teste sem segredos reais' 'padrao sensivel no teste'
    $nonAsciiSelf = @([regex]::Matches($selfText, '[^\x00-\x7F]'))
    Assert-That (@($nonAsciiSelf).Count -eq 0) 'teste ASCII-only' ('count=' + @($nonAsciiSelf).Count)
    $trailFn = ''
    if ($funcs.ContainsKey('Write-LaneTrailEvent')) { $trailFn += [string]$funcs['Write-LaneTrailEvent'] }
    if ($funcs.ContainsKey('Write-LaneServiceCycleTrail')) { $trailFn += "`n" + [string]$funcs['Write-LaneServiceCycleTrail'] }
    if ($funcs.ContainsKey('Get-LaneTrailPath')) { $trailFn += "`n" + [string]$funcs['Get-LaneTrailPath'] }
    if ($funcs.ContainsKey('Get-LaneCurrentListenerPid')) { $trailFn += "`n" + [string]$funcs['Get-LaneCurrentListenerPid'] }
    $nonAsciiNew = @([regex]::Matches($trailFn, '[^\x00-\x7F]'))
    Assert-That (@($nonAsciiNew).Count -eq 0) 'trilha nova ASCII-only' ('count=' + @($nonAsciiNew).Count)
    try { if (Test-Path -LiteralPath $tmpTrail) { Remove-Item -LiteralPath $tmpTrail -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
    Write-Host ('[f2trail-tests] ' + $script:passed + '/' + $script:total + ' PASS')
    if ($script:passed -ne $script:total) { exit 1 }
    exit 0
} catch {
    Write-Host ('[f2trail-tests] THROW: ' + $_.Exception.Message)
    exit 1
}
