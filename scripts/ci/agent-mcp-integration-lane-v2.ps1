<#
.SYNOPSIS
    Lane de integracao agent->MCP (S1..S8) em runtime REAL com binario V2 vivo.
.DESCRIPTION
    Harness de evidencia runtime-real, seguindo o precedente
    scripts/ci/session-real-lane-v2.ps1. NAO e produto: e test harness /
    evidence tooling especifico da branch feat/opencode-v2-agent-mcp-integration.

    Cenarios (cada um registra pass-real|fail|blocked com motivo; blocked
    nunca e pass; falha de infra => blocked com motivo, nunca PASS forjado):

      S1 process isolation: dois perfis XDG isolados em TEMP (testing com
         mcp.servers playwright + chrome-devtools no user-config; default sem
         MCPs) + OPENCODE_DB distintos (convencao lane-owned, verificada via
         debug paths resolvendo em TEMP); serve dedicado owned por perfil +
         GET /api/mcp via api --server (sonda `mcp list` aposentada: o CLI
         vivo 2.0.26 nao aceita --standalone no subcomando e o fallback sem
         flag atinge o servico compartilhado, nao o perfil -- observado
         2026-10-12); testing expoe os 2 servidores, default expoe zero.
         Sem modelo.
      S2 availability: serve dedicado owned do perfil testing + GET /api/mcp
         mostra os servidores sem disabled=true (sonda `debug config`
         aposentada: TIMEOUT 60s observado contra o servico compartilhado --
         2026-10-12). Sem modelo.
      S3 stdio smoke: cada MCP via npx stdio com as flags EXATAS do registry
         (playwright: @playwright/mcp@0.0.83 --headless --isolated; devtools:
         chrome-devtools-mcp@1.10.1 --headless --isolated
         --no-usage-statistics --no-performance-crux); tools/list conta
         >=25/>=30; mede startup_ms; encerra o processo owned pinado; cleanup.
         Sem modelo (pode virar blocked se a rede do npx estiver indisponivel,
         com motivo).
      S4 negative static: perfil default sem chaves mcp.servers.*browser*
         (config-absent, distinto de nao-exposicao). Sem modelo.
      S5 tester->Playwright (model-gated; exige ModelKeyEnvName existente,
         senao blocked OPERATOR_ACTION_REQUIRED): fixture servida por python
         http.server owned em 127.0.0.1 porta efemera; `serve --port` dedicado
         owned com perfil testing (Job Object); `run --server URL --agent
         build` com prompt que manda o Planner delegar o E2E ao tester
         (tester e mode=subagent: invocacao direta via --agent e rejeitada;
         observado no contrato); feixe de provas: TOOL records extraidos do
         transcript da child (navigate+>=3 clicks com status/trechos de
         resultado) + child session estrutural + CLICKS_DONE=3 + scan de
         run_code_unsafe (fail se presente); snapshot stdio como auxiliar
         (nao gating: contexto do browser e efemero por perfil).
         verificacao independente = snapshot stdio coerente. Limite honesto:
         os clicks ocorreram no contexto efemero do tester (sem contexto
         compartilhado); o valor e corroborado por feixe, nao re-observado.
         Timeout 240s.
      S6 debugger->DevTools (model-gated, mesmo setup): `run --agent build`
         com prompt que manda delegar o diagnostico ao debugger SEM entregar
         o marcador (prova que o agente leu console/DOM); feixe: TOOL
         records do transcript da child + cita FIXTURE-ERROR-42 +
         scan run_code_unsafe.
      S7 negative dynamic (model-gated): serve dedicado do perfil default +
         `run --agent build`, tarefa sem browser (reportar versao do node);
         asserts zero tool calls browser + zero ativacao MCP no transcript.
      Auth serve dedicado: segredo gerado pela lane por perfil (memoria
         apenas, valor nunca logado); todo filho api/run o recebe via env;
         ausencia => blocked fail-closed (serves frescos exigem password).
         Auth de modelos via store: provider opencode-go autentica pelo
         credential store (auth.json/account.json copiados para o XDG_DATA
         isolado; segredos morrem com TargetHome); env de chave sozinha NAO
         basta sob isolamento total (provider.no-route observado). Filhos npx
         recebem npm_config_cache + npmrc em branco sob TargetHome.
      S8 cleanup/release: para fixture+serve owned, remove TEMP profiles,
         verifica handles pinados encerrados, escreve evidence JSON com os
         campos do contrato + prompt_sha256 (nunca prompt completo, nunca
         credencial/valor de env; padroes NOME=valor redigidos).

    Seguranca/guards: home isolado EXCLUSIVO em TEMP; -CleanEnvironment nos
    filhos Spike; Job Object com KILL_ON_JOB_CLOSE antes de qualquer processo
    owned de longa vida; ModelKeyEnvName opt-in por NOME apenas (default ''
    = desligado; pernas model-gated seguem blocked fail-closed);
    Get-LaneSafeText redige segredos e padroes NOME=valor; nunca escreve fora
    de TEMP/EvidenceDir; nunca mata processo nao-owned (so jobs/processos
    owned desta lane); nunca toca ~/.config (todas as resolucoes verificadas
    via debug paths em TEMP); localhost apenas (127.0.0.1); evidencia
    sanitizada, atomica, com cleanup em finally.

    Saida: exit 0 quando nenhum cenario falhou (soment pass-real/blocked);
    exit 1 quando houver ao menos um fail. blocked nunca e pass.

    PowerShell 5.1 compativel; ASCII-only (sem ??, sem ternario, sem
    Invoke-Expression).
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$EvidenceDir = '',
    [string]$FixtureDir = '',
    [string[]]$ScenarioFilter = @(),
    [string]$ModelKeyEnvName = '',
    [string]$CheapModel = 'opencode-go/muse-spark-1.3-contributor',
    [string]$StrongModel = 'openai/gpt-6.1-sol',
    [string]$BinaryPath = '',
    [int]$ServeTimeoutSeconds = 60
)
$ErrorActionPreference = 'Stop'

# ---------- opt-in de model-key (operator-owned; NOME apenas, nunca valor) ----------
$script:ModelKeyEnvNameClean = ''
try {
    $candKeyName = ([string]$ModelKeyEnvName).Trim()
    if (($candKeyName.Length -gt 0) -and ($candKeyName.Length -le 64) -and ($candKeyName -cmatch '^[A-Za-z_][A-Za-z0-9_]*$')) { $script:ModelKeyEnvNameClean = $candKeyName }
    $candKeyName = ''
} catch { $script:ModelKeyEnvNameClean = '' }

# ---------- bootstrap ----------
function Get-LaneRepoRoot {
    try { return (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) } catch { return (Get-Location).Path }
}
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Get-LaneRepoRoot }
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
$libDir = Join-Path $RepoRoot 'scripts\runtime\lib'
foreach ($lib in @(
        (Join-Path $libDir 'RuntimeVersions.ps1'),
        (Join-Path $libDir 'SpikeProcess.ps1'),
        (Join-Path $libDir 'RuntimePortPreflight.ps1'),
        (Join-Path $libDir 'RuntimeJobObject.ps1'))) {
    if (-not (Test-Path -LiteralPath $lib -PathType Leaf)) {
        Write-Error ('lane bootstrap: lib ausente: ' + $lib)
        exit 1
    }
    . $lib
}

# ---------- sanitizacao / evidencia ----------
function Get-LaneSafeText {
    [CmdletBinding()] param($Value, [int]$Max = 200)
    try {
        if ($null -eq $Value) { return '' }
        $v = [string]$Value
        $v = $v -replace '(?i)sk-[A-Za-z0-9_-]+', '[REDACTED]'
        $v = $v -replace '(?i)(password|token|secret|authorization)\s*[=:]\s*[^\s,;"]+', '$1=[REDACTED]'
        try {
            if (-not [string]::IsNullOrWhiteSpace($script:ModelKeyEnvNameClean)) {
                $escKeyName = [regex]::Escape($script:ModelKeyEnvNameClean)
                $v = $v -replace ('(?i)' + $escKeyName + '\s*[=:]\s*[^\s,;"]+'), ($script:ModelKeyEnvNameClean + '=[REDACTED]')
            }
        } catch { }
        $v = $v -replace '(?i)https?://[^\s"]+', '[REDACTED-URL]'
        $v = $v -replace '[\x00-\x1f]', ' '
        $v = $v.Trim()
        if ($v.Length -gt $Max) { $v = $v.Substring(0, $Max) }
        return $v
    } catch { return '' }
}
function Write-LaneJson {
    [CmdletBinding()] param($Object, [string]$Path)
    try {
        $parent = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $tmp = $Path + '.tmp-' + [guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText($tmp, ((($Object | ConvertTo-Json -Depth 12).TrimEnd() + "`n") -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
        Move-Item -LiteralPath $tmp -Destination $Path -Force
        return $true
    } catch { return $false }
}
function Get-LaneTimestampUtc {
    return ([DateTime]::UtcNow.ToString('o'))
}
function Get-JsonProp($Object, [string]$Name, $Default = $null) {
    try {
        if ($null -eq $Object) { return $Default }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $Default
        }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -eq $p) { return $Default }
        return $p.Value
    } catch { return $Default }
}
function Get-PromptSha256([string]$Text) {
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Text)
            return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
        } finally { $sha.Dispose() }
    } catch { return '' }
}
function Test-LaneLocalhostUrl([string]$Url) {
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    return ([regex]::IsMatch($Url, '^http://(127\.0\.0\.1|localhost)(:\d+)?(/|$)'))
}

# ---------- estado da lane ----------
$script:LaneStarted = Get-LaneTimestampUtc
$script:LaneChecks = New-Object System.Collections.ArrayList
$script:LaneNotes = New-Object System.Collections.ArrayList
$script:ScenarioResults = New-Object System.Collections.ArrayList
$script:OwnedProcs = New-Object System.Collections.ArrayList
$script:OwnedJobs = New-Object System.Collections.ArrayList
$script:EvidenceRecords = New-Object System.Collections.ArrayList
$script:Exe = ''
$script:LiveVersion = ''
$script:PinVersion = ''
$script:PinDrift = $false
$script:SummaryWritten = $false
$script:IsoRemove = @('OPENCODE_CONFIG', 'OPENCODE_CONFIG_DIR', 'OPENCODE_CONFIG_FILE', 'OPENCODE_CONFIG_CONTENT')
$script:SensitiveEnvRemove = @(
    'OPENCODE_PASSWORD', 'OPENCODE_API_KEY', 'JEV_API_KEY', 'JEVDATA_DIR',
    'AIMEMORY_REMOTE_TOKEN', 'AI_MEMORY_TOKEN', 'GITHUB_TOKEN', 'GH_TOKEN',
    'GIT_TOKEN', 'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY',
    'AZURE_CLIENT_SECRET', 'GOOGLE_APPLICATION_CREDENTIALS',
    'OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'ZAI_API_KEY', 'Z_AI_API_KEY',
    'NODE_OPTIONS', 'NODE_ENV', 'npm_config_userconfig', 'npm_config__auth',
    'NPM_TOKEN', 'npm_token', 'NODE_EXTRA_CA_CERTS'
)
$script:ApiRemove = @($script:IsoRemove + ($script:SensitiveEnvRemove | Where-Object { $_ -cne 'OPENCODE_PASSWORD' }))
function Add-LaneServeAuth($EnvTable) {
    # Clona env do perfil; o segredo do serve dedicado (gerado em
    # New-LaneProfile) viaja so em memoria para os filhos api/run,
    # nunca em log ou evidencia (presenca registrada como booleano).
    $out = @{}
    try { if ($null -ne $EnvTable) { foreach ($k in @($EnvTable.Keys)) { $out[[string]$k] = [string]$EnvTable[$k] } } } catch { }
    $hasPw = $false
    try {
        $pv = [string]$out['OPENCODE_PASSWORD']
        if (-not [string]::IsNullOrWhiteSpace($pv)) { $hasPw = $true }
        $pv = ''
    } catch { }
    return [ordered]@{ env = $out; hasPassword = [bool]$hasPw }
}
function Wait-LaneMcpNames([string]$ServeUrl, $ApiEnv, [string[]]$ApiRemove, [string]$WorkDir, [string[]]$WantNames, [int]$DeadlineSeconds) {
    # Sonda GET /api/mcp ate os nomes desejados aparecerem: a conexao MCP e
    # assincrona pos-listener (observado: [] aos ~15s, connected aos ~30s).
    # WantNames vazio = 1 sonda (caso default: ausencia estavel e o esperado).
    $res = [ordered]@{ text = ''; found = @(); missing = @($WantNames); elapsed_ms = 0; queries = 0 }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        while ($sw.Elapsed.TotalSeconds -lt $DeadlineSeconds) {
            $ar = Invoke-PreflightBoundedExe -File $script:Exe -ArgsLine ('api --server ' + $ServeUrl + ' GET /api/mcp') -WorkDir $WorkDir -EnvTable $ApiEnv -EnvRemove $ApiRemove -TimeoutMs 30000 -MaxChars 65536
            $res.queries = [int]$res.queries + 1
            if ([bool]$ar.Finished -and ([int]$ar.ExitCode -eq 0)) {
                $t = [string]$ar.Output
                $res.text = $t
                $f = New-Object System.Collections.ArrayList
                $m = New-Object System.Collections.ArrayList
                foreach ($wn in @($WantNames)) {
                    if ($t -match ('(?i)' + [regex]::Escape($wn))) { [void]$f.Add($wn) } else { [void]$m.Add($wn) }
                }
                $res.found = @($f)
                $res.missing = @($m)
                if (@($m).Count -eq 0) { break }
            }
            Start-Sleep -Milliseconds 5000
        }
    } catch { }
    $sw.Stop()
    $res.elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
    return $res
}
function Copy-LaneCredentials([string]$DstDb) {
    # Copia SOMENTE a tabela credential (o store de credenciais do provider)
    # do DB do usuario para o DB isolado JA migrado pelo serve. Sem DDL
    # (o serve migra sozinho); INSERT OR REPLACE por id via helper python3
    # em TargetHome. Retorna ok/rows/reason. Valores nunca vao para log.
    $res = [ordered]@{ ok = $false; rows = 0; reason = '' }
    try {
        $py = Get-Command python3 -ErrorAction SilentlyContinue
        if ($null -eq $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
        if ($null -eq $py) { $res.reason = 'python3 indisponivel (infra)'; return $res }
        $helper = Join-Path $TargetHome 'copycreds.py'
        if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) {
            $code = @'
import sqlite3, sys
src, dst = sys.argv[1], sys.argv[2]
s = sqlite3.connect('file:' + src + '?mode=ro', uri=True, timeout=15)
rows = s.execute('select id, integration_id, label, value, connector_id, method_id, active, time_created, time_updated from credential').fetchall()
cols = [r[1] for r in s.execute('PRAGMA table_info(credential)')]
s.close()
d = sqlite3.connect(dst, timeout=30)
try:
    ncol = [r[1] for r in d.execute('PRAGMA table_info(credential)')]
except Exception:
    print('NO-TABLE'); sys.exit(3)
if ncol != cols:
    print('SCHEMA-MISMATCH'); sys.exit(4)
d.executemany('INSERT OR REPLACE INTO credential VALUES (?,?,?,?,?,?,?,?,?)', rows)
d.commit()
print('ROWS=' + str(len(rows)))
'@
            [IO.File]::WriteAllText($helper, ($code -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
        }
        $userDb = Join-Path $env:USERPROFILE '.local\share\opencode\opencode.db'
        if (-not [string]::IsNullOrWhiteSpace($env:XDG_DATA_HOME)) {
            $alt = Join-Path ([string]$env:XDG_DATA_HOME) 'opencode\opencode.db'
            if (Test-Path -LiteralPath $alt -PathType Leaf) { $userDb = $alt }
        }
        if (-not (Test-Path -LiteralPath $userDb -PathType Leaf)) { $res.reason = 'DB do usuario ausente (infra)'; return $res }
        if (-not (Test-Path -LiteralPath $DstDb -PathType Leaf)) { $res.reason = 'DB isolado ainda nao migrado (ordenacao)'; return $res }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = ([string]$py.Source)
        $psi.Arguments = (ConvertTo-SpikeArguments -ArgumentList @($helper, $userDb, $DstDb))
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.WorkingDirectory = $TargetHome
        try { $psi.EnvironmentVariables.Clear() } catch { }
        foreach ($kn in @('PATH', 'SystemRoot', 'WINDIR', 'ComSpec', 'PATHEXT', 'TEMP', 'TMP', 'SystemDrive')) {
            try { $v = [Environment]::GetEnvironmentVariable($kn, 'Process'); if ($null -ne $v) { $psi.EnvironmentVariables[$kn] = [string]$v } } catch { }
        }
        $c = [System.Diagnostics.Process]::Start($psi)
        if ($null -eq $c) { $res.reason = 'helper nao iniciou (infra)'; return $res }
        if (-not $c.WaitForExit(60000)) { try { $c.Kill() } catch { }; $res.reason = 'helper TIMEOUT 60s (infra)'; return $res }
        $o = $c.StandardOutput.ReadToEnd()
        if ([int]$c.ExitCode -ne 0) { $res.reason = ('helper exit=' + [int]$c.ExitCode + ' ' + (Get-LaneSafeText $o 120)); return $res }
        $m = [regex]::Match($o, 'ROWS=(\d+)')
        if (-not $m.Success) { $res.reason = 'helper sem contagem (infra)'; return $res }
        $res.ok = $true
        $res.rows = [int]$m.Groups[1].Value
        $res.reason = 'credential copiada (contagem apenas)'
        return $res
    } catch { $res.reason = (Get-LaneSafeText $_.Exception.Message 120); return $res }
}
function Get-LaneChildAgents([string]$ServeUrl, $ApiEnv, [string[]]$ApiRemove, [string]$WorkDir, [string]$ParentId) {    # Lista agentes de child sessions (parentID == ParentId): prova estrutural
    # de delegacao (vai alem de mencao textual no transcript).
    $out = New-Object System.Collections.ArrayList
    try {
        if ([string]::IsNullOrWhiteSpace($ParentId)) { return @() }
        if (-not (Test-LaneLocalhostUrl $ServeUrl)) { return @() }
        $ar = Invoke-PreflightBoundedExe -File $script:Exe -ArgsLine ('api --server ' + $ServeUrl + ' GET /api/session') -WorkDir $WorkDir -EnvTable $ApiEnv -EnvRemove $ApiRemove -TimeoutMs 30000 -MaxChars 131072
        if ((-not [bool]$ar.Finished) -or ([int]$ar.ExitCode -ne 0)) { return @() }
        $j = $null
        try { $j = ConvertFrom-Json ([string]$ar.Output) } catch { return @() }
        $rows = Get-JsonProp $j 'data' $null
        foreach ($r in @($rows)) {
            try {
                if ([string](Get-JsonProp $r 'parentID' '') -ceq $ParentId) {
                    $an = [string](Get-JsonProp $r 'agent' '')
                    if (-not [string]::IsNullOrWhiteSpace($an)) { [void]$out.Add($an) }
                }
            } catch { }
        }
    } catch { }
    return @($out)
}
function Get-LaneChildTranscript([string]$ServeUrl, $ApiEnv, [string[]]$ApiRemove, [string]$WorkDir, [string]$ParentId, [string]$Agent) {
    # Extrai da child session SOMENTE registros de tool (nome+status+trecho
    # do resultado) + linhas de relatorio. Evita blobs de reasoning e
    # independe do TargetHome post-hoc (que se mostrou efemero).
    try {
        if ([string]::IsNullOrWhiteSpace($ParentId)) { return '' }
        if (-not (Test-LaneLocalhostUrl $ServeUrl)) { return '' }
        $lr = Invoke-PreflightBoundedExe -File $script:Exe -ArgsLine ('api --server ' + $ServeUrl + ' GET /api/session') -WorkDir $WorkDir -EnvTable $ApiEnv -EnvRemove $ApiRemove -TimeoutMs 30000 -MaxChars 131072
        if ((-not [bool]$lr.Finished) -or ([int]$lr.ExitCode -ne 0)) { return '' }
        $lj = $null
        try { $lj = ConvertFrom-Json ([string]$lr.Output) } catch { return '' }
        $cid = ''
        foreach ($r in @(Get-JsonProp $lj 'data' $null)) {
            try {
                if (([string](Get-JsonProp $r 'parentID' '') -ceq $ParentId) -and ([string](Get-JsonProp $r 'agent' '') -ceq $Agent)) { $cid = [string](Get-JsonProp $r 'id' ''); break }
            } catch { }
        }
        if ([string]::IsNullOrWhiteSpace($cid)) { return '' }
        $mr = Invoke-PreflightBoundedExe -File $script:Exe -ArgsLine ('api --server ' + $ServeUrl + ' GET /api/session/' + $cid + '/message') -WorkDir $WorkDir -EnvTable $ApiEnv -EnvRemove $ApiRemove -TimeoutMs 30000 -MaxChars 524288
        if ((-not [bool]$mr.Finished) -or ([int]$mr.ExitCode -ne 0)) { return '' }
        $childRawForbidden = Test-LaneForbiddenCall ([string]$mr.Output)
        $mj = $null
        try { $mj = ConvertFrom-Json ([string]$mr.Output) } catch { return '' }
        $rows = Get-JsonProp $mj 'data' $mj
        if ($null -eq $rows) { $rows = @($mj) }
        $ev = New-Object System.Collections.ArrayList
        if ([bool]$childRawForbidden) { [void]$ev.Add('FORBIDDEN-CALL-DETECTED run_code_unsafe (scan pre-truncamento do transcript raw da child)') }
        foreach ($m in @($rows)) {
            try {
                foreach ($it in @(Get-JsonProp $m 'content' $null)) {
                    try {
                        $tp = [string](Get-JsonProp $it 'type' '')
                        if ($tp -ceq 'tool') {
                            $nm = [string](Get-JsonProp $it 'name' (Get-JsonProp $it 'tool' ''))
                            $st = [string](Get-JsonProp (Get-JsonProp $it 'state' $null) 'status' '')
                            $ot = ''
                            try {
                                $oc = @(Get-JsonProp $it 'content' $null)
                                $tx = @()
                                foreach ($c in @($oc)) { $tx += [string](Get-JsonProp $c 'text' '') }
                                $ot = ($tx -join ' ').Trim()
                            } catch { }
                            if ($ot.Length -gt 300) { $ot = $ot.Substring(0, 300) }
                            [void]$ev.Add(('TOOL name=' + $nm + ' status=' + $st + ' out=[' + $ot + ']'))
                        } elseif ($tp -ceq 'text') {
                            $tx = [string](Get-JsonProp $it 'text' '')
                            if (($tx -match 'CLICKS_DONE') -or ($tx -match 'FIXTURE-ERROR-42')) {
                                if ($tx.Length -gt 300) { $tx = $tx.Substring(0, 300) }
                                [void]$ev.Add(('REPORT ' + $tx))
                            }
                        }
                    } catch { }
                }
            } catch { }
        }
        return (Get-LaneSafeText ($ev -join "`n") 4000)
    } catch { return '' }
}

function Add-LaneCheck([string]$Name, [bool]$Ok, [string]$Detail) {
    [void]$script:LaneChecks.Add([ordered]@{ check = $Name; ok = [bool]$Ok; detail = (Get-LaneSafeText $Detail 400) })
}
function Add-LaneNote([string]$Text) {
    [void]$script:LaneNotes.Add((Get-LaneSafeText $Text 400))
}
function Set-ScenarioResult([string]$Id, [string]$Status, [string]$Detail, $Proofs, $Coverage) {
    $row = [ordered]@{
        scenario_id = $Id
        status      = $Status
        detail      = (Get-LaneSafeText $Detail 500)
        proofs      = @($Proofs)
        coverage    = @($Coverage)
        at          = (Get-LaneTimestampUtc)
    }
    $replaced = $false
    for ($i = 0; $i -lt $script:ScenarioResults.Count; $i++) {
        if ([string]$script:ScenarioResults[$i]['scenario_id'] -ceq $Id) { $script:ScenarioResults[$i] = $row; $replaced = $true; break }
    }
    if (-not $replaced) { [void]$script:ScenarioResults.Add($row) }
    Write-Host ('[agent-mcp-lane] ' + $Id + ' => ' + $Status + ' :: ' + (Get-LaneSafeText $Detail 120))
}
function Add-ScenarioProof($Proofs, [string]$Name, [bool]$Ok, [string]$Detail) {
    [void]$Proofs.Add([ordered]@{ proof = $Name; ok = [bool]$Ok; detail = (Get-LaneSafeText $Detail 4000) })
    return $Proofs
}
function Add-EvidenceRecord($Rec) {
    [void]$script:EvidenceRecords.Add($Rec)
}
function New-LaneSummary([string]$Status, [string]$Reason) {
    $scen = @()
    foreach ($r in @($script:ScenarioResults)) { $scen += $r }
    $pass = @($scen | Where-Object { [string]$_['status'] -ceq 'pass-real' }).Count
    $fail = @($scen | Where-Object { [string]$_['status'] -ceq 'fail' }).Count
    $blocked = @($scen | Where-Object { [string]$_['status'] -ceq 'blocked' }).Count
    return [ordered]@{
        lane              = 'agent-mcp-integration-lane-v2'
        purpose           = 'integracao agent->MCP (tester->Playwright, debugger->DevTools) em runtime REAL com binario V2 vivo'
        date              = ([DateTime]::UtcNow.ToString('yyyy-MM-dd'))
        started_at        = $script:LaneStarted
        finished_at       = (Get-LaneTimestampUtc)
        status            = $Status
        reason            = (Get-LaneSafeText $Reason 400)
        runtime_pin       = $script:PinVersion
        runtime_live      = $script:LiveVersion
        pin_drift         = [bool]$script:PinDrift
        binary            = (Get-LaneSafeText $script:ExeForEvidence 240)
        model_key_env     = (Get-LaneModelKeyLogToken)
        scenarios         = $scen
        scenario_counts   = [ordered]@{ pass_real = $pass; fail = $fail; blocked = $blocked }
        checks            = @($script:LaneChecks)
        notes             = @($script:LaneNotes)
        evidence_records  = @($script:EvidenceRecords)
        isolation         = 'dois perfis XDG isolados em TEMP + OPENCODE_DB distintos (convencao lane-owned); -CleanEnvironment nos filhos Spike; cwd nos perfis; stdin fechado'
        job_backstop      = 'Job Object com KILL_ON_JOB_CLOSE criado ANTES de cada processo owned de longa vida; contem somente processos desta lane'
    }
}
function Write-LaneSummaryAndExit([string]$Status, [string]$Reason, [int]$Code) {
    $summary = New-LaneSummary -Status $Status -Reason $Reason
    $main = Join-Path $script:EvidenceDir 'lane-summary.json'
    [void](Write-LaneJson $summary $main)
    $script:SummaryWritten = $true
    Write-Host ('[agent-mcp-lane] ' + $Status + ': ' + (Get-LaneSafeText $Reason 200))
    Write-Host ('[agent-mcp-lane] evidencia em ' + $main)
    exit $Code
}

# ---------- model-key opt-in ----------
function Get-LaneModelKeyLogToken {
    if ([string]::IsNullOrWhiteSpace($script:ModelKeyEnvNameClean)) { return 'model-key-env=<unset>' }
    return ('model-key-env=' + $script:ModelKeyEnvNameClean)
}
function Test-LaneModelKeyAvailable {
    try {
        if ([string]::IsNullOrWhiteSpace($script:ModelKeyEnvNameClean)) { return $false }
        $val = [Environment]::GetEnvironmentVariable($script:ModelKeyEnvNameClean, 'Process')
        return (-not [string]::IsNullOrWhiteSpace($val))
    } catch { return $false }
}
function Get-LaneModelChildEnv {
    [CmdletBinding()] param($BaseEnv = $null)
    $out = @{}
    try {
        if ($null -ne $BaseEnv) { foreach ($k in @($BaseEnv.Keys)) { $out[[string]$k] = [string]$BaseEnv[$k] } }
    } catch { }
    try {
        if (Test-LaneModelKeyAvailable) {
            $out[$script:ModelKeyEnvNameClean] = [Environment]::GetEnvironmentVariable($script:ModelKeyEnvNameClean, 'Process')
        }
    } catch { }
    return $out
}

# ---------- filtro de cenarios ----------
function Test-ScenarioSelected([string]$Id) {
    $flat = New-Object System.Collections.ArrayList
    foreach ($e in @($ScenarioFilter)) {
        foreach ($p in @(([string]$e -split ','))) {
            $t = ([string]$p).Trim().ToUpperInvariant()
            if (-not [string]::IsNullOrWhiteSpace($t)) { [void]$flat.Add($t) }
        }
    }
    if ($flat.Count -eq 0) { return $true }
    return ($flat -contains $Id.ToUpperInvariant())
}
function Test-InfraMarkers([string]$Text) {
    $t = ([string]$Text).ToLowerInvariant()
    foreach ($m in @('timedout', 'timeout', 'enotfound', 'etimedout', 'econnrefused', 'fetch failed', 'socket hang up', 'exit -3', 'nao iniciou', 'dns', 'network is unreachable', 'getaddrinfo')) {
        if ($t.Contains($m)) { return $true }
    }
    return $false
}

# ---------- inicializacao de dirs ----------
$tempRoot = [IO.Path]::GetTempPath()
if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $tempRoot = $env:RUNNER_TEMP }
$TargetHome = Join-Path $tempRoot ('oo-agentmcp-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
if (Test-Path -LiteralPath $TargetHome) {
    Write-Error ('TargetHome ja existe: ' + $TargetHome + ' (home EXCLUSIVO por execucao).')
    exit 1
}
if ([string]::IsNullOrWhiteSpace($EvidenceDir)) {
    $EvidenceDir = Join-Path $RepoRoot 'evidence\agent-mcp-integration'
}
$script:EvidenceDir = $EvidenceDir
try {
    New-Item -ItemType Directory -Path $TargetHome -Force | Out-Null
    New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
} catch { Write-Error ('falha ao criar dirs: ' + $_.Exception.Message); exit 1 }

function New-LaneProfile([string]$ProfileId) {
    $root = Join-Path $TargetHome $ProfileId
    $xdg = Join-Path $root 'xdg'
    $xdgData = Join-Path $root 'xdg-data'
    $xdgState = Join-Path $root 'xdg-state'
    $xdgCache = Join-Path $root 'xdg-cache'
    $profHome = Join-Path $root 'home'
    $cwd = Join-Path $root 'cwd'
    $dbDir = Join-Path $root 'db'
    foreach ($d in @($xdg, $xdgData, $xdgState, $xdgCache, $profHome, $cwd, $dbDir)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
    $dbPath = Join-Path $dbDir 'opencode.db'
    $servePw = ([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N'))
    # SECFIX(CLOSURE-F1-PR71-SECFFIX): nenhuma credencial materializada aqui.
    # A importacao de auth.json/account.json (+kv/model/service) foi adiada
    # para Import-LaneProfileCredentials, chamada SOMENTE apos o gate de
    # opt-in de modelo (Test-LaneModelKeyAvailable) nos setups de S5/S6/S7.
    # Caminho sem opt-in nunca toca credencial alguma (fail-closed preservado).
    $authCopied = $false
    $npmCache = Join-Path $root 'npm-cache'
    try { if (-not (Test-Path -LiteralPath $npmCache -PathType Container)) { New-Item -ItemType Directory -Path $npmCache -Force | Out-Null } } catch { }
    # FIXTURE(S5S6-BROWSER-FIX): dirs lane-owned (sob TargetHome, nunca TEMP
    # real/usuario real): TEMP/TMP dos filhos + user-data-dir distinto por MCP.
    $laneTmp = Join-Path $TargetHome 'lane-tmp'
    try { if (-not (Test-Path -LiteralPath $laneTmp -PathType Container)) { New-Item -ItemType Directory -Path $laneTmp -Force | Out-Null } } catch { }
    $browserPw = Join-Path $root 'browser-profile-pw'
    $browserDt = Join-Path $root 'browser-profile-dt'
    foreach ($bd in @($browserPw, $browserDt)) {
        try { if (-not (Test-Path -LiteralPath $bd -PathType Container)) { New-Item -ItemType Directory -Path $bd -Force | Out-Null } } catch { }
    }
    $npmRcBlank = Join-Path $root 'npmrc-blank'
    try { if (-not (Test-Path -LiteralPath $npmRcBlank -PathType Leaf)) { [IO.File]::WriteAllText($npmRcBlank, "# lane-owned blank npmrc`n", (New-Object Text.UTF8Encoding $false)) } } catch { }
    $servePwEnv = @{
        XDG_CONFIG_HOME = $xdg
        XDG_DATA_HOME   = $xdgData
        XDG_STATE_HOME  = $xdgState
        XDG_CACHE_HOME  = $xdgCache
        HOME            = $profHome
        USERPROFILE     = $profHome
        OPENCODE_DB     = $dbPath
        OPENCODE_PASSWORD = $servePw
        npm_config_cache = $npmCache
        npm_config_userconfig = $npmRcBlank
    }
    $servePw = ''
    return [ordered]@{
        id       = $ProfileId
        root     = $root
        xdg      = $xdg
        home     = $profHome
        cwd      = $cwd
        db       = $dbPath
        lane_tmp = $laneTmp
        browser_pw = $browserPw
        browser_dt = $browserDt
        cfg_path = (Join-Path $xdg 'opencode\opencode.json')
        env      = $servePwEnv
        auth_store = [bool]$authCopied
    }
}

function Import-LaneProfileCredentials($Profile) {
    # SECFIX(CLOSURE-F1-PR71-SECFFIX): importacao pos-gate de opt-in.
    # Chamar SOMENTE apos Test-LaneModelKeyAvailable == $true, nos setups
    # de S5/S6/S7 selecionados. Sem opt-in retorna $false sem copiar nada.
    # Valores nunca vao para log; segredos morrem com TargetHome.
    try {
        if ($null -eq $Profile) { return $false }
        if (-not (Test-LaneModelKeyAvailable)) { return $false }
        $root = [string]$Profile.root
        if ([string]::IsNullOrWhiteSpace($root)) { return $false }
        $xdgData = Join-Path $root 'xdg-data'
        $xdgState = Join-Path $root 'xdg-state'
        $userData = $env:XDG_DATA_HOME
        if ([string]::IsNullOrWhiteSpace($userData)) { $userData = Join-Path $env:USERPROFILE '.local\share' }
        $userOpDir = Join-Path ([string]$userData) 'opencode'
        $profOpData = Join-Path $xdgData 'opencode'
        if (-not (Test-Path -LiteralPath $profOpData -PathType Container)) { New-Item -ItemType Directory -Path $profOpData -Force | Out-Null }
        $copiedAny = $false
        foreach ($af in @('auth.json', 'account.json')) {
            try {
                $src = Join-Path $userOpDir $af
                if (Test-Path -LiteralPath $src -PathType Leaf) {
                    Copy-Item -LiteralPath $src -Destination (Join-Path $profOpData $af) -Force
                    $copiedAny = $true
                }
            } catch { }
        }
        $userState = $env:XDG_STATE_HOME
        if ([string]::IsNullOrWhiteSpace($userState)) { $userState = Join-Path $env:USERPROFILE '.local\state' }
        $userOpState = Join-Path ([string]$userState) 'opencode'
        $profOpState = Join-Path $xdgState 'opencode'
        if (-not (Test-Path -LiteralPath $profOpState -PathType Container)) { New-Item -ItemType Directory -Path $profOpState -Force | Out-Null }
        foreach ($sf in @('kv.json', 'model.json', 'service.json')) {
            try {
                $src = Join-Path $userOpState $sf
                if (Test-Path -LiteralPath $src -PathType Leaf) {
                    Copy-Item -LiteralPath $src -Destination (Join-Path $profOpState $sf) -Force
                    $copiedAny = $true
                }
            } catch { }
        }
        try { $Profile.auth_store = [bool]$copiedAny } catch { }
        return [bool]$copiedAny
    } catch { return $false }
}

# ---------- processos owned de longa vida (fixture + serve) ----------
function Start-LaneOwnedProcess {
    [CmdletBinding()] param([string]$FilePath = '', [string[]]$ArgumentList = @(), $EnvTable = $null, [string[]]$EnvRemove = @(), [string]$WorkDir = '', [string]$LogName = 'owned')
    $res = [ordered]@{ ok = $false; reason = ''; proc = $null; job = $null; log = '' }
    try {
        $job = New-RuntimeJobObject
        if (($null -eq $job) -or (-not [bool]$job.Ok)) { $res.reason = 'job object NAO criado (fail-closed antes do start)'; return $res }
        $flags = $null
        try { $flags = Get-RuntimeJobLimitFlags -Job $job } catch { $flags = $null }
        if (($null -eq $flags) -or (-not [bool]$flags.Ok) -or (-not [bool]$flags.KillOnClose)) {
            try { [void](Close-RuntimeJobObject -Job $job) } catch { }
            $res.reason = 'job sem KILL_ON_JOB_CLOSE provado (fail-closed antes do start)'
            return $res
        }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        $psi.Arguments = (ConvertTo-SpikeArguments -ArgumentList $ArgumentList)
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.CreateNoWindow = $true
        if (-not [string]::IsNullOrWhiteSpace($WorkDir)) { $psi.WorkingDirectory = $WorkDir }
        $keepNames = @('PATH', 'SystemRoot', 'WINDIR', 'ComSpec', 'PATHEXT', 'TEMP', 'TMP', 'PSModulePath', 'SystemDrive', 'ProgramFiles', 'ProgramFiles(x86)', 'LOCALAPPDATA', 'APPDATA')
        try { $psi.EnvironmentVariables.Clear() } catch { }
        foreach ($kn in $keepNames) {
            try {
                $kv = [Environment]::GetEnvironmentVariable($kn, 'Process')
                if ($null -ne $kv) { $psi.EnvironmentVariables[$kn] = [string]$kv }
            } catch { }
        }
        if ($null -ne $EnvTable) {
            foreach ($k in @($EnvTable.Keys)) {
                try { $psi.EnvironmentVariables[[string]$k] = [string]$EnvTable[$k] } catch { }
            }
        }
        foreach ($r in @($EnvRemove)) {
            try { [void]$psi.EnvironmentVariables.Remove([string]$r) } catch { }
        }
        # FIXTURE(S5S6-BROWSER-FIX): TEMP/TMP lane-owned sob TargetHome para os
        # filhos serve/fixture (browser/MCP nao tocam TEMP real do usuario).
        # Fail-closed: falha de preparacao aborta o start (nunca segue com
        # TEMP/TMP herdado).
        try {
            if ([string]::IsNullOrWhiteSpace($TargetHome)) { throw 'TargetHome vazio (sem TEMP lane-owned)' }
            $laneTmpOwned = Join-Path $TargetHome 'lane-tmp'
            if (-not (Test-Path -LiteralPath $laneTmpOwned -PathType Container)) { New-Item -ItemType Directory -Path $laneTmpOwned -Force | Out-Null }
            if (-not (Test-Path -LiteralPath $laneTmpOwned -PathType Container)) { throw ('lane-tmp indisponivel: ' + $laneTmpOwned) }
            $psi.EnvironmentVariables['TEMP'] = $laneTmpOwned
            $psi.EnvironmentVariables['TMP'] = $laneTmpOwned
        } catch {
            try { [void](Close-RuntimeJobObject -Job $job) } catch { }
            $prepMsg = ''
            try { $prepMsg = [string]$_.Exception.Message } catch { $prepMsg = '' }
            if ([string]::IsNullOrWhiteSpace($prepMsg)) { $prepMsg = 'falha ao preparar lane-tmp' }
            $res.reason = ('TEMP lane-owned indisponivel (fail-closed antes do start): ' + (Get-LaneSafeText $prepMsg 160))
            return $res
        }
        $p = [System.Diagnostics.Process]::Start($psi)
        if ($null -eq $p) {
            try { [void](Close-RuntimeJobObject -Job $job) } catch { }
            $res.reason = 'processo nao iniciou'
            return $res
        }
        try { $p.StandardInput.Close() } catch { }
        $add = Add-RuntimeJobProcess -Job $job -Process $p
        if (-not [bool]$add.Ok) {
            try { $p.Kill() } catch { }
            try { [void](Close-RuntimeJobObject -Job $job) } catch { }
            $res.reason = ('atribuicao ao job falhou: ' + [string]$add.Reason)
            return $res
        }
        [void]$script:OwnedProcs.Add($p)
        [void]$script:OwnedJobs.Add($job)
        $res.ok = $true
        $res.proc = $p
        $res.job = $job
        $res.reason = ('pid=' + $p.Id + ' job-assigned')
        return $res
    } catch {
        $res.reason = (Get-LaneSafeText $_.Exception.Message 160)
        return $res
    }
}
function Wait-LaneListener([int]$Port, [int]$DeadlineSeconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($DeadlineSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $ln = Get-PreflightNetTCPListenerBounded -Port $Port -TimeoutMs 4000
            if (($null -ne $ln) -and [bool]$ln.QuerySucceeded -and [bool]$ln.Exists) { return $true }
        } catch { }
        Start-Sleep -Milliseconds 1000
    }
    return $false
}
# ---------- gates estruturados (CLOSURE-F1-PR71-GATES) ----------
function Test-LaneForbiddenCall([string]$Text) {
    # Scan de ferramenta proibida + equivalentes (parent E child, sempre no
    # texto pre-truncamento; nunca so no $turn.out).
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return ([regex]::IsMatch([string]$Text, '(?i)run[_-]?code[_-]?unsafe'))
}
function Test-LaneToolSuccess([string]$Transcript, [string]$ToolPattern, [int]$MinCount = 1) {
    # Exige >=MinCount registros estruturados (extrator TOOL name/status) com
    # status de sucesso; QUALQUER registro do mesmo nome com status de falha
    # reprova (ferramenta falhando => nunca pass-real).
    # Ancoragem GATES2: conta SOMENTE registros em fronteira de registro
    # (inicio de linha, uma linha por registro gerada por
    # Get-LaneChildTranscript). O sufixo out=[...] e cortado antes do match,
    # entao texto 'TOOL name=... status=...' aninhado no conteudo (ou em
    # blocos REPORT) NUNCA conta.
    try {
        if ([string]::IsNullOrWhiteSpace($Transcript)) { return $false }
        $okRe = ('(?i)^\s*TOOL name=' + $ToolPattern + ' status=(completed|complete|success|ok|done)\b')
        $badRe = ('(?i)^\s*TOOL name=' + $ToolPattern + ' status=(fail\w*|error\w*|abort\w*|reject\w*|timeout\w*|cancel\w*)\b')
        $okN = 0
        $badN = 0
        foreach ($line in ([string]$Transcript -split "`r?`n")) {
            $head = [string]$line
            $ix = $head.IndexOf(' out=[')
            if ($ix -ge 0) { $head = $head.Substring(0, $ix) }
            if ([regex]::IsMatch($head, $okRe)) { $okN += 1 }
            if ([regex]::IsMatch($head, $badRe)) { $badN += 1 }
        }
        return (([int]$okN -ge [int]$MinCount) -and ([int]$badN -eq 0))
    } catch { return $false }
}
function Stop-LaneOwned([string]$Why) {
    if ($null -eq $script:LaneCleanupLog) { $script:LaneCleanupLog = New-Object System.Collections.ArrayList }
    $notes = New-Object System.Collections.ArrayList
    $stopFail = New-Object System.Collections.ArrayList
    $remainingJobs = New-Object System.Collections.ArrayList
    $jobIx = 0
    foreach ($job in @($script:OwnedJobs)) {
        $jobIx += 1
        $sr = $null
        try { $sr = Stop-RuntimeJobObject -Job $job } catch { $sr = $null }
        if ($null -eq $sr) {
            [void]$stopFail.Add(('job#' + $jobIx + ' stop-throw (handle preservado no tracking)'))
            [void]$remainingJobs.Add($job)
        } elseif (-not [bool]$sr.Ok) {
            [void]$stopFail.Add(('job#' + $jobIx + ' stop-ok=false api=' + [string]$sr.Api + ' remaining=' + [string]$sr.Remaining + ' (handle preservado no tracking)'))
            [void]$remainingJobs.Add($job)
        } elseif (-not [bool]$sr.Settled) {
            [void]$stopFail.Add(('job#' + $jobIx + ' settlement-pendente remaining=' + [string]$sr.Remaining + ' (handle preservado no tracking)'))
            [void]$remainingJobs.Add($job)
        }
    }
    Start-Sleep -Milliseconds 1500
    $closeIx = 0
    foreach ($job in @($script:OwnedJobs)) {
        $closeIx += 1
        # GATES2 (handle-sem-close): job cujo stop falhou NAO e fechado aqui;
        # o handle e preservado no tracking como evidencia e o registro
        # original em stopFailures permanece intacto (sem close pós-falha
        # que o destrua).
        $stopFailed = $false
        foreach ($k in @($remainingJobs)) { if ([object]::ReferenceEquals($k, $job)) { $stopFailed = $true; break } }
        if ([bool]$stopFailed) {
            [void]$notes.Add(('close-skip-job#' + $closeIx + ' (stop falhou; handle preservado no tracking, sem close pós-falha)'))
            continue
        }
        $cr = $null
        try { $cr = Close-RuntimeJobObject -Job $job } catch { $cr = $null }
        if (($null -eq $cr) -or (-not [bool]$cr.Ok)) {
            [void]$notes.Add(('close-job#' + $closeIx + '-falhou (handle preservado no tracking)'))
            [void]$stopFail.Add(('close-job#' + $closeIx + '-falhou (handle preservado no tracking)'))
            $already = $false
            foreach ($k in @($remainingJobs)) { if ([object]::ReferenceEquals($k, $job)) { $already = $true; break } }
            if (-not $already) { [void]$remainingJobs.Add($job) }
        }
    }
    $leaks = New-Object System.Collections.ArrayList
    $remainingProcs = New-Object System.Collections.ArrayList
    foreach ($p in @($script:OwnedProcs)) {
        try {
            $p.Refresh()
            if (-not $p.HasExited) { [void]$leaks.Add($p.Id); [void]$remainingProcs.Add($p) }
        } catch {
            [void]$notes.Add('proc-estado-desconhecido (preservado no tracking)')
            [void]$stopFail.Add('proc-estado-desconhecido (preservado no tracking)')
            [void]$remainingProcs.Add($p)
        }
    }
    try { $script:OwnedJobs.Clear() } catch { }
    try { $script:OwnedProcs.Clear() } catch { }
    foreach ($j in @($remainingJobs)) { try { [void]$script:OwnedJobs.Add($j) } catch { } }
    foreach ($p in @($remainingProcs)) { try { [void]$script:OwnedProcs.Add($p) } catch { } }
    $res = [ordered]@{ leaks = @($leaks); notes = @($notes); stopFailures = @($stopFail); why = $Why }
    try { [void]$script:LaneCleanupLog.Add($res) } catch { }
    return $res
}

# ---------- fixture (deterministica; FixtureDir opt-in, senao gerada em TEMP) ----------
function Get-LaneFixture {
    [CmdletBinding()] param([string]$Wanted = '')
    if (-not [string]::IsNullOrWhiteSpace($Wanted) -and (Test-Path -LiteralPath $Wanted -PathType Container)) {
        $ixOk = $false
        $exOk = $false
        try {
            $ixT = [IO.File]::ReadAllText((Join-Path $Wanted 'index.html'), [Text.Encoding]::UTF8)
            $exT = [IO.File]::ReadAllText((Join-Path $Wanted 'error.html'), [Text.Encoding]::UTF8)
            $ixOk = (($ixT -match 'id="count-btn"') -and ($ixT -match 'id="count"'))
            $exOk = ($exT -match 'FIXTURE-ERROR-42')
        } catch { $ixOk = $false; $exOk = $false }
        if ($ixOk -and $exOk) { return [ordered]@{ ok = $true; dir = $Wanted; generated = $false; reason = 'FixtureDir do operador (contrato validado)' } }
        return [ordered]@{ ok = $false; dir = ''; generated = $false; reason = 'FixtureDir incompativel (contrato: index.html com count-btn+span#count; error.html com FIXTURE-ERROR-42)' }
    }
    try {
        $dir = Join-Path $TargetHome 'fixture'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $index = @'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>lane-fixture</title></head>
<body>
<h1 id="title">lane-fixture-counter</h1>
<button id="count-btn">click me</button>
<span id="count">0</span>
<script>
var n = 0;
document.getElementById("count-btn").addEventListener("click", function () {
  n = n + 1;
  document.getElementById("count").textContent = String(n);
});
window.__laneCount = function () { return n; };
</script>
</body></html>
'@
        $err = @'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>lane-fixture-error</title></head>
<body>
<h1 id="etitle">fixture-error-page</h1>
<p id="emarker">FIXTURE-ERROR-42: widget render failed (deterministic marker)</p>
<button id="ebtn">trigger error</button>
<script>
document.getElementById("ebtn").addEventListener("click", function () {
  console.error("FIXTURE-ERROR-42: widget render failed (deterministic marker)");
  throw new Error("FIXTURE-ERROR-42: widget render failed (deterministic marker)");
});
console.error("FIXTURE-ERROR-42: widget render failed (deterministic marker)");
</script>
</body></html>
'@
        [IO.File]::WriteAllText((Join-Path $dir 'index.html'), ($index -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
        [IO.File]::WriteAllText((Join-Path $dir 'error.html'), ($err -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
        return [ordered]@{ ok = $true; dir = $dir; generated = $true; reason = 'fixture deterministica gerada em TEMP' }
    } catch {
        return [ordered]@{ ok = $false; dir = ''; generated = $false; reason = (Get-LaneSafeText $_.Exception.Message 160) }
    }
}

try {
    # ---------- 1. pin vs binario vivo (drift registrado; prossegue com o vivo) ----------
    $pinv = $null
    try { $pinv = Get-OrchestrationRuntimeVersion -Name 'v2' -RepoRoot $RepoRoot } catch { Write-LaneSummaryAndExit 'failed' ('pin v2 irresolvivel: ' + $_.Exception.Message) 1 }
    if ($null -eq $pinv -or [string]::IsNullOrWhiteSpace([string]$pinv.version)) { Write-LaneSummaryAndExit 'failed' 'pin v2 ausente no registry.' 1 }
    $script:PinVersion = [string]$pinv.version
    $cands = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($BinaryPath)) {
        if (-not (Test-Path -LiteralPath $BinaryPath -PathType Leaf)) { Write-LaneSummaryAndExit 'blocked' ('-BinaryPath inexistente: ' + $BinaryPath) 0 }
        [void]$cands.Add($BinaryPath)
    } else {
        foreach ($c in @(Get-Command -Name 'opencode' -All -ErrorAction SilentlyContinue)) {
            $src = ''
            try { $src = [string]$c.Source } catch { $src = '' }
            if (-not [string]::IsNullOrWhiteSpace($src) -and (Test-Path -LiteralPath $src)) { [void]$cands.Add($src) }
        }
        $profileBin = Join-Path $env:USERPROFILE '.opencode-orchestration\profiles\v2\runtime\node_modules\@opencode\cli\bin\opencode.exe'
        if ((Test-Path -LiteralPath $profileBin -PathType Leaf) -and (-not ($cands -contains $profileBin))) { [void]$cands.Add($profileBin) }
        $npmCli = Join-Path $env:APPDATA 'npm\node_modules\@opencode\cli'
        foreach ($plat in @('cli-windows-x64-baseline', 'cli-windows-x64', 'cli-windows-arm64')) {
            $pb = Join-Path $npmCli ('node_modules\@opencode\' + $plat + '\bin\opencode.exe')
            if ((Test-Path -LiteralPath $pb -PathType Leaf) -and (-not ($cands -contains $pb))) { [void]$cands.Add($pb) }
        }
    }
    foreach ($cand in @($cands)) {
        $exePath = [string]$cand
        $ext = [IO.Path]::GetExtension($exePath).ToLowerInvariant()
        if ($ext -ne '.exe') {
            $resolved = ''
            try { $resolved = Resolve-SpikeShimTarget -ShimPath $exePath } catch { $resolved = '' }
            if ([string]::IsNullOrWhiteSpace($resolved) -or -not (Test-Path -LiteralPath $resolved -PathType Leaf)) { continue }
            $exePath = $resolved
        }
        $vr = Invoke-SpikeChild -FilePath $exePath -ArgumentList @('--version') -TimeoutMs 30000 -CleanEnvironment -StdinNul
        if ([bool]$vr.TimedOut) { continue }
        if ([int]$vr.ExitCode -ne 0) { continue }
        $verText = ([string]$vr.Stdout + "`n" + [string]$vr.Stderr)
        $m = [regex]::Match($verText, '(?m)^opencode v(\S+)\s*$')
        if (-not $m.Success) { continue }
        $script:Exe = $exePath
        $script:LiveVersion = $m.Groups[1].Value.Trim()
        break
    }
    if ([string]::IsNullOrWhiteSpace($script:Exe)) { Write-LaneSummaryAndExit 'blocked' 'nenhum binario V2 respondeu --version (infra indisponivel).' 0 }
    $script:PinDrift = ($script:LiveVersion -cne $script:PinVersion)
    $script:ExeForEvidence = ([string]$script:Exe)
    try {
        if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $script:ExeForEvidence = $script:ExeForEvidence.Replace($env:USERPROFILE, '~') }
    } catch { }
    Add-LaneCheck 'binary_live_resolved' $true ('vivo=' + $script:LiveVersion + ' pin=' + $script:PinVersion + ' pin_drift=' + $script:PinDrift + ' (prossegue com o binario vivo documentado)')
    if ($script:PinDrift) { Add-LaneNote ('pin_drift: registry=' + $script:PinVersion + ' vivo=' + $script:LiveVersion + '; nenhuma alegacao de conformidade com o pin') }

    # ---------- 2. perfis isolados + configs a partir do template ----------
    $profTesting = New-LaneProfile -ProfileId 'testing'
    $profDefault = New-LaneProfile -ProfileId 'default'
    if ($profTesting.db -ceq $profDefault.db) { Write-LaneSummaryAndExit 'failed' 'OPENCODE_DB colidiu entre perfis (defeito da lane).' 1 }
    Add-LaneCheck 'profiles_isolated_temp' $true ('testing+default sob TargetHome exclusivo; OPENCODE_DB distintos (convencao lane-owned)')
    Add-LaneCheck 'auth_store_deferred' ((-not [bool]$profTesting.auth_store) -and (-not [bool]$profDefault.auth_store)) 'perfis iniciam SEM credencial; importacao adiada para pos-gate opt-in via Import-LaneProfileCredentials (S5/S6/S7); segredos morrem com TargetHome'
    $tmplPath = Join-Path $RepoRoot 'templates\opencode.v2.json.tmpl'
    if (-not (Test-Path -LiteralPath $tmplPath -PathType Leaf)) { Write-LaneSummaryAndExit 'failed' ('template ausente: ' + $tmplPath) 1 }
    $tmplRaw = [IO.File]::ReadAllText($tmplPath, [Text.Encoding]::UTF8)
    $tmplRaw = $tmplRaw.Replace('{{MODEL_PLANNER}}', $CheapModel).Replace('{{MODEL_CHEAP}}', $CheapModel).Replace('{{MODEL_STRONG}}', $StrongModel)
    $tmplJson = $null
    try { $tmplJson = ConvertFrom-Json $tmplRaw } catch { Write-LaneSummaryAndExit 'failed' ('template apos substituicao nao parseia: ' + $_.Exception.Message) 1 }
    $agBuild = Get-JsonProp (Get-JsonProp $tmplJson 'agents' $null) 'build' $null
    $agTester = Get-JsonProp (Get-JsonProp $tmplJson 'agents' $null) 'tester' $null
    $agDebugger = Get-JsonProp (Get-JsonProp $tmplJson 'agents' $null) 'debugger' $null
    if (($null -eq $agBuild) -or ($null -eq $agTester) -or ($null -eq $agDebugger)) { Write-LaneSummaryAndExit 'failed' 'template sem blocos agents.build/tester/debugger.' 1 }
    # Restricoes de menor privilegio materializadas no perfil descartavel
    # (registry declara; template nao traz; sem isso o veto seria so texto).
    # Vetores de execucao de codigo: deny; evaluate: ask (headless: ask sem
    # aprovador trava o turn => blocked fail-closed, nunca execucao).
    $mcpRestrict = @(
        [ordered]@{ agent = 'tester'; action = 'playwright_browser_run_code_unsafe'; effect = 'deny' },
        [ordered]@{ agent = 'tester'; action = 'browser_run_code_unsafe'; effect = 'deny' },
        [ordered]@{ agent = 'tester'; action = 'playwright_browser_evaluate'; effect = 'ask' },
        [ordered]@{ agent = 'tester'; action = 'browser_evaluate'; effect = 'ask' },
        [ordered]@{ agent = 'debugger'; action = 'chrome-devtools_evaluate_script'; effect = 'ask' },
        [ordered]@{ agent = 'debugger'; action = 'chrome_devtools_evaluate_script'; effect = 'ask' },
        [ordered]@{ agent = 'debugger'; action = 'evaluate_script'; effect = 'ask' },
        [ordered]@{ agent = 'build'; action = 'playwright_browser_run_code_unsafe'; effect = 'deny' },
        [ordered]@{ agent = 'build'; action = 'browser_run_code_unsafe'; effect = 'deny' },
        [ordered]@{ agent = 'build'; action = 'playwright_browser_evaluate'; effect = 'ask' },
        [ordered]@{ agent = 'build'; action = 'browser_evaluate'; effect = 'ask' },
        [ordered]@{ agent = 'build'; action = 'chrome-devtools_evaluate_script'; effect = 'ask' },
        [ordered]@{ agent = 'build'; action = 'chrome_devtools_evaluate_script'; effect = 'ask' },
        [ordered]@{ agent = 'build'; action = 'evaluate_script'; effect = 'ask' }
    )
    $agById = @{ build = $agBuild; tester = $agTester; debugger = $agDebugger }
    foreach ($rr in @($mcpRestrict)) {
        $ag = $agById[[string]$rr.agent]
        if ($null -eq $ag) { Write-LaneSummaryAndExit 'failed' ('agente ausente para restricao MCP: ' + [string]$rr.agent) 1 }
        $cur = @()
        try { $cur = @($ag.permissions) } catch { $cur = @() }
        $entry = [ordered]@{ action = [string]$rr.action; resource = '*'; effect = [string]$rr.effect }
        try { $ag.permissions = @($cur + $entry) } catch { Write-LaneSummaryAndExit 'failed' ('restricao MCP nao aplicavel: ' + [string]$rr.agent + '/' + [string]$rr.action) 1 }
    }
    $mcpTesting = [ordered]@{
        servers = [ordered]@{
            playwright = [ordered]@{
                type = 'local'
                command = @('npx', '-y', '@playwright/mcp@0.0.83', '--headless', '--isolated', '--user-data-dir', ([string]$profTesting.browser_pw))
                disabled = $false
            }
            'chrome-devtools' = [ordered]@{
                type = 'local'
                command = @('npx', '-y', 'chrome-devtools-mcp@1.10.1', '--headless', '--isolated', '--no-usage-statistics', '--no-performance-crux', '--userDataDir', ([string]$profTesting.browser_dt))
                disabled = $false
            }
        }
    }
    foreach ($prof in @($profTesting, $profDefault)) {
        $cfg = [ordered]@{
            default_agent = 'build'
            experimental = [ordered]@{ subagent_depth = 1 }
            agents = [ordered]@{ build = $agBuild; tester = $agTester; debugger = $agDebugger }
        }
        if ([string]$prof.id -ceq 'testing') { $cfg['mcp'] = $mcpTesting }
        $cfgParent = Split-Path -Parent ([string]$prof.cfg_path)
        if (-not (Test-Path -LiteralPath $cfgParent -PathType Container)) { New-Item -ItemType Directory -Path $cfgParent -Force | Out-Null }
        [IO.File]::WriteAllText(([string]$prof.cfg_path), ((($cfg | ConvertTo-Json -Depth 8).TrimEnd() + "`n") -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
    }
    Add-LaneCheck 'configs_from_template' $true ('agents.build/tester/debugger extraidos em runtime + 14 restricoes MCP materializadas (deny code-exec, ask evaluate); modelos: cheap=' + $CheapModel + ' strong=' + $StrongModel + '; testing com 2 MCPs, default sem mcp')
    if (-not [string]::IsNullOrWhiteSpace($script:ModelKeyEnvNameClean)) {
        Add-LaneNote (('model-key opt-in (' + (Get-LaneModelKeyLogToken) + '); passthrough pontual SOMENTE aos filhos opencode run de S5/S6/S7'))
    }

    # ---------- 3. isolamento verificado via debug paths (nunca ~/.config) ----------
    $isoOk = $true
    foreach ($prof in @($profTesting, $profDefault)) {
        $dp = Invoke-SpikeChild -FilePath $script:Exe -ArgumentList @('debug', 'paths') -EnvSet $prof.env -EnvRemove $script:IsoRemove -WorkingDirectory ([string]$prof.cwd) -TimeoutMs 30000 -CleanEnvironment -StdinNul
        $dpText = ([string]$dp.Stdout + "`n" + [string]$dp.Stderr)
        $inTemp = ($dpText.Contains($TargetHome) -or $dpText.Contains(($TargetHome -replace '\\', '/')))
        $touchesHome = $false
        try {
            if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
                $touchesHome = ($dpText.Contains((Join-Path $env:USERPROFILE '.config\opencode')) -or $dpText.Contains((Join-Path $env:USERPROFILE '.local')))
            }
        } catch { }
        if ([bool]$dp.TimedOut -or ([int]$dp.ExitCode -ne 0) -or (-not $inTemp) -or $touchesHome) { $isoOk = $false }
        Add-LaneCheck ('isolation_' + [string]$prof.id) (($inTemp) -and (-not $touchesHome) -and ([int]$dp.ExitCode -eq 0)) ('debug paths resolve em TEMP; sem ~/.config (toca-home=' + $touchesHome + ')')
    }
    if (-not $isoOk) { Write-LaneSummaryAndExit 'blocked' 'isolamento nao comprovado via debug paths (fail-closed; ver checks).' 0 }

    # ---------- portas livres dedicadas (nunca 49374) ----------
    function Get-LaneFreePortNot49374 {
        for ($i = 0; $i -lt 10; $i++) {
            $p = Get-SpikeFreePort
            if ($p -ne 49374) { return $p }
        }
        return 0
    }
    $portSvcTesting = Get-LaneFreePortNot49374
    $portSvcDefault = Get-LaneFreePortNot49374
    $portFixture = Get-LaneFreePortNot49374
    if (($portSvcTesting -eq 0) -or ($portSvcDefault -eq 0) -or ($portFixture -eq 0)) { Write-LaneSummaryAndExit 'blocked' 'sem porta livre fora de 49374 (infra).' 0 }
    foreach ($prof in @($profTesting, $profDefault)) {
        $want = $portSvcTesting
        if ([string]$prof.id -cne 'testing') { $want = $portSvcDefault }
        $sp = Invoke-SpikeChild -FilePath $script:Exe -ArgumentList @('service', 'set', 'port', "$want") -EnvSet $prof.env -EnvRemove $script:IsoRemove -WorkingDirectory ([string]$prof.cwd) -TimeoutMs 30000 -CleanEnvironment -StdinNul
        if ([bool]$sp.TimedOut -or ([int]$sp.ExitCode -ne 0)) { Write-LaneSummaryAndExit 'blocked' ('service set port falhou no perfil ' + [string]$prof.id + ' (infra).') 0 }
    }
    Add-LaneCheck 'service_ports_isolated' $true ('testing=' + $portSvcTesting + ' default=' + $portSvcDefault + ' fixture=' + $portFixture + '; 49374 recusada')

    # ==================================================================
    # S1 process isolation (sem modelo)
    # ==================================================================
    if (Test-ScenarioSelected 'S1') {
        $proofs = New-Object System.Collections.ArrayList
        $coverage = New-Object System.Collections.ArrayList
        try {
            $s1fail = ''
            $s1blocked = ''
            foreach ($prof in @($profTesting, $profDefault)) {
                $want = $portSvcTesting
                if ([string]$prof.id -cne 'testing') { $want = $portSvcDefault }
                $serveUrl = ('http://127.0.0.1:' + $want)
                if (-not (Test-LaneLocalhostUrl $serveUrl)) { $s1blocked = 'guard localhost recusou a URL (defeito da lane).'; break }
                $so = Start-LaneOwnedProcess -FilePath $script:Exe -ArgumentList @('serve', '--port', "$want") -EnvTable $prof.env -EnvRemove $script:IsoRemove -WorkDir ([string]$prof.cwd) -LogName ('serve-s1-' + [string]$prof.id)
                if (-not [bool]$so.ok) { $s1blocked = ('serve owned nao iniciou no perfil ' + [string]$prof.id + ': ' + (Get-LaneSafeText $so.reason 160)); break }
                try {
                    if (-not (Wait-LaneListener -Port $want -DeadlineSeconds $ServeTimeoutSeconds)) { $s1blocked = ('serve owned sem listener no perfil ' + [string]$prof.id + ' (infra).'); break }
                    $auth = Add-LaneServeAuth $prof.env
                    [void](Add-ScenarioProof $proofs ('serve-auth-' + [string]$prof.id) ([bool]$auth.hasPassword) 'segredo do serve em memoria (nunca logado)')
                    if (-not [bool]$auth.hasPassword) { $s1blocked = ('serve sem segredo no perfil ' + [string]$prof.id + ' (auth fail-closed)'); break }
                    $wantNames = @('playwright', 'chrome-devtools')
                    if ([string]$prof.id -cne 'testing') { $wantNames = @() }
                    $w = Wait-LaneMcpNames $serveUrl $auth.env $script:ApiRemove ([string]$prof.cwd) $wantNames 180
                    [void](Add-ScenarioProof $proofs ('mcp-connect-' + [string]$prof.id) $true ('queries=' + [int]$w.queries + ' elapsed_ms=' + [int]$w.elapsed_ms))
                    $mlText = [string]$w.text
                    if ([string]::IsNullOrWhiteSpace($mlText)) { $s1blocked = ('GET /api/mcp sem resposta no perfil ' + [string]$prof.id + ' (infra; queries=' + [int]$w.queries + ')'); break }
                    if ($mlText.Contains('49374')) { $s1blocked = 'saida menciona 49374 (invariante do servico do usuario; fail-closed)'; break }
                    $hasPw = ($mlText -match '(?i)playwright')
                    $hasDt = ($mlText -match '(?i)(chrome-)?devtools')
                if ([string]$prof.id -ceq 'testing') {
                    [void](Add-ScenarioProof $proofs 'testing-exposes-playwright' ([bool]$hasPw) 'serve dedicado + GET /api/mcp')
                    [void](Add-ScenarioProof $proofs 'testing-exposes-devtools' ([bool]$hasDt) 'serve dedicado + GET /api/mcp')
                    if ((-not $hasPw) -or (-not $hasDt)) {
                        $s1fail = 'testing nao expoe os 2 MCPs no serve dedicado (isolamento quebrado)'
                    }
                } else {
                    [void](Add-ScenarioProof $proofs 'default-zero-browser' (((-not $hasPw) -and (-not $hasDt))) 'serve dedicado + GET /api/mcp')
                    if ($hasPw -or $hasDt) { $s1fail = 'default expoe MCP browser (vazamento entre perfis)' }
                }
                } finally {
                    $s1stop = Stop-LaneOwned ('s1-serve-' + [string]$prof.id + '-done')
                    [void](Add-ScenarioProof $proofs ('cleanup-' + [string]$prof.id) (((@($s1stop.leaks).Count -eq 0) -and (@($s1stop.stopFailures).Count -eq 0))) ('Stop-LaneOwned acumulado na LaneCleanupLog: leaks=' + @($s1stop.leaks).Count + ' stop-failures=' + @($s1stop.stopFailures).Count))
                }
                if (-not [string]::IsNullOrWhiteSpace($s1fail)) { break }
            }
            if (-not [string]::IsNullOrWhiteSpace($s1blocked)) { Set-ScenarioResult 'S1' 'blocked' $s1blocked $proofs $coverage }
            elseif (-not [string]::IsNullOrWhiteSpace($s1fail)) { Set-ScenarioResult 'S1' 'fail' $s1fail $proofs $coverage }
            else { Set-ScenarioResult 'S1' 'pass-real' 'testing expoe playwright+devtools; default expoe zero; DBs distintos; 49374 intocada' $proofs $coverage }
        } catch {
            Set-ScenarioResult 'S1' 'blocked' ('excecao (infra): ' + (Get-LaneSafeText $_.Exception.Message 160)) $proofs $coverage
        }
    }

    # ==================================================================
    # S2 availability (sem modelo)
    # ==================================================================
    if (Test-ScenarioSelected 'S2') {
        $proofs = New-Object System.Collections.ArrayList
        $coverage = New-Object System.Collections.ArrayList
        try {
            [void](Add-ScenarioProof $proofs 'debug-config-probe-retired' $true 'debug config aposentado: TIMEOUT 60s observado (2026-10-12); disponibilidade via serve dedicado + GET /api/mcp')
            Add-LaneNote 'S2 sem debug config (TIMEOUT provado); usa serve owned + GET /api/mcp'
                    $apiLeg = 'skipped'
                    $serveUrl = ('http://127.0.0.1:' + $portSvcTesting)
                    if (-not (Test-LaneLocalhostUrl $serveUrl)) {
                        [void](Add-ScenarioProof $proofs 'api-mcp' $false 'URL fora de localhost (recusada pelo guard)')
                        Set-ScenarioResult 'S2' 'blocked' 'guard localhost recusou a URL (defeito da lane).' $proofs $coverage
                    } else {
                        $so = Start-LaneOwnedProcess -FilePath $script:Exe -ArgumentList @('serve', '--port', "$portSvcTesting") -EnvTable $profTesting.env -EnvRemove $script:IsoRemove -WorkDir ([string]$profTesting.cwd) -LogName 'serve-testing'
                        if (-not [bool]$so.ok) {
                            [void](Add-ScenarioProof $proofs 'api-mcp' $false $so.reason)
                            Set-ScenarioResult 'S2' 'blocked' ('serve owned nao iniciou: ' + $so.reason) $proofs $coverage
                        } else {
                            try {
                                if (-not (Wait-LaneListener -Port $portSvcTesting -DeadlineSeconds $ServeTimeoutSeconds)) {
                                    [void](Add-ScenarioProof $proofs 'api-mcp' $false 'sem listener no serve owned (infra)')
                                    Set-ScenarioResult 'S2' 'blocked' 'serve owned sem listener (infra).' $proofs $coverage
                                } else {
                                    $auth2 = Add-LaneServeAuth $profTesting.env
                                    [void](Add-ScenarioProof $proofs 'serve-auth' ([bool]$auth2.hasPassword) 'segredo do serve em memoria (nunca logado)')
                                    if (-not [bool]$auth2.hasPassword) {
                                        Set-ScenarioResult 'S2' 'blocked' 'serve sem segredo (auth fail-closed).' $proofs $coverage
                                    } else {
                                    $w2 = Wait-LaneMcpNames $serveUrl $auth2.env $script:ApiRemove ([string]$profTesting.cwd) @('playwright', 'chrome-devtools') 180
                                    [void](Add-ScenarioProof $proofs 'mcp-connect' $true ('queries=' + [int]$w2.queries + ' elapsed_ms=' + [int]$w2.elapsed_ms))
                                    $ab = [string]$w2.text
                                    if ([string]::IsNullOrWhiteSpace($ab)) {
                                        [void](Add-ScenarioProof $proofs 'api-mcp' $false ('sem resposta (infra; queries=' + [int]$w2.queries + ')'))
                                        Set-ScenarioResult 'S2' 'blocked' ('GET /api/mcp sem resposta (infra; queries=' + [int]$w2.queries + ')') $proofs $coverage
                                    } else {
                                        $apiPw = ($ab -match '(?i)playwright')
                                        $apiDt = ($ab -match '(?i)(chrome-)?devtools')
                                        $apiDis = ($ab -match '(?i)"disabled"\s*:\s*true')
                                        [void](Add-ScenarioProof $proofs 'api-mcp-playwright' ([bool]$apiPw) 'GET /api/mcp cita playwright')
                                        [void](Add-ScenarioProof $proofs 'api-mcp-devtools' ([bool]$apiDt) 'GET /api/mcp cita devtools')
                                        [void](Add-ScenarioProof $proofs 'api-mcp-not-disabled' (-not [bool]$apiDis) 'sem disabled=true na resposta')
                                        if ($apiPw -and $apiDt -and (-not $apiDis)) {
                                            $apiLeg = 'pass'
                                            Set-ScenarioResult 'S2' 'pass-real' 'GET /api/mcp no serve dedicado mostra os 2 servidores sem disabled=true.' $proofs $coverage
                                        } else {
                                            Set-ScenarioResult 'S2' 'fail' 'GET /api/mcp respondeu mas nao confirma os 2 servidores habilitados.' $proofs $coverage
                                        }
                                    }
                                }
                            }
                            } finally {
                                $s2stop = Stop-LaneOwned 's2-serve-done'
                                [void](Add-ScenarioProof $proofs 'cleanup-s2' (((@($s2stop.leaks).Count -eq 0) -and (@($s2stop.stopFailures).Count -eq 0))) ('Stop-LaneOwned acumulado na LaneCleanupLog: leaks=' + @($s2stop.leaks).Count + ' stop-failures=' + @($s2stop.stopFailures).Count))
                            }
                        }
                    }
        } catch {
            Set-ScenarioResult 'S2' 'blocked' ('excecao (infra): ' + (Get-LaneSafeText $_.Exception.Message 160)) $proofs $coverage
        }
    }

    # ==================================================================
    # S3 stdio smoke (sem modelo; rede npx ausente => blocked com motivo)
    # ==================================================================
    if (Test-ScenarioSelected 'S3') {
        $proofs = New-Object System.Collections.ArrayList
        $coverage = New-Object System.Collections.ArrayList
        try {
            $npxCmd = Get-Command npx.cmd -ErrorAction SilentlyContinue
            if ($null -eq $npxCmd) { $npxCmd = Get-Command npx -ErrorAction SilentlyContinue }
            $nodeExe = ''
            $npxCli = ''
            if ($null -ne $npxCmd) {
                try {
                    $npxDir = Split-Path -Parent ([string]$npxCmd.Source)
                    $nodeCand = Join-Path $npxDir 'node.exe'
                    $cliCand = Join-Path (Join-Path (Join-Path $npxDir 'node_modules') 'npm') 'bin\npx-cli.js'
                    if ((Test-Path -LiteralPath $nodeCand -PathType Leaf) -and (Test-Path -LiteralPath $cliCand -PathType Leaf)) {
                        $nodeExe = $nodeCand
                        $npxCli = $cliCand
                    }
                } catch { }
            }
            if ([string]::IsNullOrWhiteSpace($nodeExe)) {
                [void](Add-ScenarioProof $proofs 'npx-resolved' $false 'node+npx-cli.js nao resolvidos (infra)')
                Set-ScenarioResult 'S3' 'blocked' 'npx indisponivel para stdio smoke (infra).' $proofs $coverage
            } else {
                [void](Add-ScenarioProof $proofs 'npx-resolved' $true 'node + npx-cli.js resolvidos (sem valores logados)')
                $specs = @(
                    [ordered]@{ id = 'playwright'; pkg = '@playwright/mcp@0.0.83'; flags = @('--headless', '--isolated'); min_tools = 25 },
                    [ordered]@{ id = 'devtools'; pkg = 'chrome-devtools-mcp@1.10.1'; flags = @('--headless', '--isolated', '--no-usage-statistics', '--no-performance-crux'); min_tools = 30 }
                )
                $s3fail = ''
                $s3blocked = ''
                foreach ($spec in $specs) {
                    $argv = New-Object System.Collections.ArrayList
                    [void]$argv.Add($npxCli)
                    [void]$argv.Add('-y')
                    [void]$argv.Add([string]$spec.pkg)
                    foreach ($f in @($spec.flags)) { [void]$argv.Add([string]$f) }
                    $job = $null
                    try { $job = New-RuntimeJobObject } catch { $job = $null }
                    if (($null -eq $job) -or (-not [bool]$job.Ok)) { $s3blocked = 'job object indisponivel (fail-closed)'; break }
                    $sw = [System.Diagnostics.Stopwatch]::StartNew()
                    $firstMs = -1
                    $toolCount = -1
                    $stdioNote = ''
                    try {
                        $psi = New-Object System.Diagnostics.ProcessStartInfo
                        $psi.FileName = $nodeExe
                        $psi.Arguments = (ConvertTo-SpikeArguments -ArgumentList ([string[]]$argv))
                        $psi.UseShellExecute = $false
                        $psi.RedirectStandardOutput = $true
                        $psi.RedirectStandardError = $true
                        $psi.RedirectStandardInput = $true
                        $psi.CreateNoWindow = $true
                        $psi.WorkingDirectory = $TargetHome
                        try { $psi.EnvironmentVariables.Clear() } catch { }
                        foreach ($kn in @('PATH', 'SystemRoot', 'WINDIR', 'ComSpec', 'PATHEXT', 'TEMP', 'TMP', 'SystemDrive', 'ProgramFiles', 'ProgramFiles(x86)', 'LOCALAPPDATA', 'APPDATA')) {
                            try {
                                $kv = [Environment]::GetEnvironmentVariable($kn, 'Process')
                                if ($null -ne $kv) { $psi.EnvironmentVariables[$kn] = [string]$kv }
                            } catch { }
                        }
                        $npmHome3 = Join-Path $TargetHome 'npm-home'
                        $npmCache3 = Join-Path $TargetHome 'npm-cache'
                        foreach ($dd in @($npmHome3, $npmCache3)) { try { if (-not (Test-Path -LiteralPath $dd -PathType Container)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null } } catch { } }
                        $psi.EnvironmentVariables['HOME'] = $npmHome3
                        $psi.EnvironmentVariables['USERPROFILE'] = $npmHome3
                        $psi.EnvironmentVariables['npm_config_cache'] = $npmCache3
                        # FIXTURE(S5S6-BROWSER-FIX): mesmo env lane-owned dos filhos serve.
                        $laneTmp3 = Join-Path $TargetHome 'lane-tmp'
                        try { if (-not (Test-Path -LiteralPath $laneTmp3 -PathType Container)) { New-Item -ItemType Directory -Path $laneTmp3 -Force | Out-Null } } catch { }
                        $psi.EnvironmentVariables['TEMP'] = $laneTmp3
                        $psi.EnvironmentVariables['TMP'] = $laneTmp3
                        foreach ($r in @($script:SensitiveEnvRemove)) {
                            try { [void]$psi.EnvironmentVariables.Remove([string]$r) } catch { }
                        }
                        $p = [System.Diagnostics.Process]::Start($psi)
                        if ($null -eq $p) { $stdioNote = 'processo stdio nao iniciou (infra)' }
                        else {
                            $add = Add-RuntimeJobProcess -Job $job -Process $p
                            if (-not [bool]$add.Ok) {
                                try { $p.Kill() } catch { }
                                $stdioNote = 'sem atribuicao ao job (fail-closed; processo morto)'
                            } else {
                                $init = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"oo-lane","version":"1.0"}}}'
                                $notif = '{"jsonrpc":"2.0","method":"notifications/initialized"}'
                                $list = '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
                                try {
                                    $p.StandardInput.WriteLine($init)
                                    $p.StandardInput.WriteLine($notif)
                                    $p.StandardInput.WriteLine($list)
                                    $p.StandardInput.Flush()
                                } catch { $stdioNote = 'stdin falhou (infra)' }
                                if ([string]::IsNullOrWhiteSpace($stdioNote)) {
                                    $deadline = [DateTime]::UtcNow.AddSeconds(120)
                                    $task = $null
                                    while ([DateTime]::UtcNow -lt $deadline) {
                                        $line = $null
                                        try {
                                            if ($p.HasExited) { break }
                                            if ($null -eq $task) { $task = $p.StandardOutput.ReadLineAsync() }
                                            if (-not $task.Wait(2000)) { continue }
                                            try { $line = $task.Result } catch { $line = $null }
                                            $task = $null
                                        } catch { break }
                                        if ($null -eq $line) { Start-Sleep -Milliseconds 500; continue }
                                        if ($firstMs -lt 0) { $firstMs = [int]$sw.ElapsedMilliseconds }
                                        $j = $null
                                        try { $j = ConvertFrom-Json $line } catch { $j = $null }
                                        if ($null -eq $j) { continue }
                                        if ([int](Get-JsonProp $j 'id' -1) -eq 2) {
                                            $tools = Get-JsonProp (Get-JsonProp $j 'result' $null) 'tools' $null
                                            if ($null -ne $tools) { $toolCount = @($tools).Count }
                                            break
                                        }
                                    }
                                    if ($toolCount -lt 0) {
                                        $errTail = ''
                                        try {
                                            if (-not $p.HasExited) {
                                                try { $p.StandardInput.Close() } catch { }
                                                if (-not $p.WaitForExit(5000)) { try { $p.Kill() } catch { }; $p.WaitForExit(5000) }
                                            }
                                            $errTail = $p.StandardError.ReadToEnd()
                                        } catch { $errTail = '' }
                                        if (Test-InfraMarkers $errTail) { $stdioNote = 'rede npx indisponivel: ' + (Get-LaneSafeText $errTail 160) }
                                        elseif ($p.HasExited) { $stdioNote = ('saida prematura exit=' + $p.ExitCode + ' ' + (Get-LaneSafeText $errTail 120)) }
                                        else { $stdioNote = 'tools/list sem resposta em 120s (infra)' }
                                    }
                                }
                                try { $p.StandardInput.Close() } catch { }
                            }
                        }
                    } catch { $stdioNote = (Get-LaneSafeText $_.Exception.Message 160) }
                    finally {
                        try { [void](Stop-RuntimeJobObject -Job $job) } catch { }
                        try { [void](Close-RuntimeJobObject -Job $job) } catch { }
                        try {
                            if (($null -ne $p) -and (-not $p.HasExited)) {
                                $p.Refresh()
                                if (-not $p.HasExited) { $stdioNote = $stdioNote + ' [LEAK: pid vivo apos stop]'; $s3fail = 'handle pinado nao encerrado (' + [string]$spec.id + ')'; [void](Add-ScenarioProof $proofs ('stdio-cleanup-' + [string]$spec.id) $false 'pid vivo apos stop do job') }
                            }
                        } catch { }
                        $sw.Stop()
                    }
                    if (-not [string]::IsNullOrWhiteSpace($s3fail)) { break }
                    if ($toolCount -ge 0) {
                        $okCount = ([int]$toolCount -ge [int]$spec.min_tools)
                        [void](Add-ScenarioProof $proofs ('stdio-tools-' + [string]$spec.id) ([bool]$okCount) ('tools=' + $toolCount + ' min=' + [int]$spec.min_tools + ' startup_ms=' + $firstMs))
                        if (-not $okCount) { $s3fail = ('contagem abaixo do registry (' + [string]$spec.id + ': ' + $toolCount + ' < ' + [int]$spec.min_tools + ')') }
                    } else {
                        [void](Add-ScenarioProof $proofs ('stdio-' + [string]$spec.id) $false $stdioNote)
                        if (Test-InfraMarkers $stdioNote) { $s3blocked = ('stdio ' + [string]$spec.id + ' (infra): ' + $stdioNote); break }
                        $s3fail = ('stdio ' + [string]$spec.id + ' falhou com saida limpa: ' + $stdioNote)
                        break
                    }
                }
                if (-not [string]::IsNullOrWhiteSpace($s3blocked)) { Set-ScenarioResult 'S3' 'blocked' $s3blocked $proofs $coverage }
                elseif (-not [string]::IsNullOrWhiteSpace($s3fail)) { Set-ScenarioResult 'S3' 'fail' $s3fail $proofs $coverage }
                else { Set-ScenarioResult 'S3' 'pass-real' 'stdio tools/list >=25 (playwright) e >=30 (devtools); processos owned encerrados; cleanup ok.' $proofs $coverage }
            }
        } catch {
            Set-ScenarioResult 'S3' 'blocked' ('excecao (infra): ' + (Get-LaneSafeText $_.Exception.Message 160)) $proofs $coverage
        }
    }

    # ==================================================================
    # S4 negative static (sem modelo)
    # ==================================================================
    if (Test-ScenarioSelected 'S4') {
        $proofs = New-Object System.Collections.ArrayList
        $coverage = New-Object System.Collections.ArrayList
        try {
            $raw = ''
            try { $raw = [IO.File]::ReadAllText(([string]$profDefault.cfg_path), [Text.Encoding]::UTF8) } catch { $raw = '' }
            if ([string]::IsNullOrWhiteSpace($raw)) {
                [void](Add-ScenarioProof $proofs 'default-config-readable' $false 'config ilegivel (infra)')
                Set-ScenarioResult 'S4' 'blocked' 'config do perfil default ilegivel (infra).' $proofs $coverage
            } else {
                $doc = $null
                try { $doc = ConvertFrom-Json $raw } catch { $doc = $null }
                if ($null -eq $doc) {
                    [void](Add-ScenarioProof $proofs 'default-config-parse' $false 'JSON invalido (defeito da lane)')
                    Set-ScenarioResult 'S4' 'fail' 'config do default invalida (defeito da lane).' $proofs $coverage
                } else {
                    $mcp = Get-JsonProp $doc 'mcp' $null
                    $servers = Get-JsonProp $mcp 'servers' $null
                    $browserKeys = @()
                    if ($null -ne $servers) {
                        foreach ($pn in @($servers.PSObject.Properties)) {
                            if ([string]$pn.Name -match '(?i)(browser|playwright|devtools|chrome)') { $browserKeys += [string]$pn.Name }
                        }
                    }
                    [void](Add-ScenarioProof $proofs 'default-config-absent' ($browserKeys.Count -eq 0) ('browser-keys=' + ($browserKeys -join ',')))
                    [void](Add-ScenarioProof $proofs 'default-no-mcp-section' ($null -eq $mcp) 'ausencia de secao mcp (config-absent, nao apenas nao-exposicao)')
                    if ($browserKeys.Count -gt 0) { Set-ScenarioResult 'S4' 'fail' ('default contem chaves browser: ' + ($browserKeys -join ',')) $proofs $coverage }
                    else { Set-ScenarioResult 'S4' 'pass-real' 'perfil default sem chaves mcp.servers.*browser* (config-absent estatico).' $proofs $coverage }
                }
            }
        } catch {
            Set-ScenarioResult 'S4' 'blocked' ('excecao (infra): ' + (Get-LaneSafeText $_.Exception.Message 160)) $proofs $coverage
        }
    }

    # ---------- setup compartilhado S5/S6/S7 (model-gated; serve+fixture owned) ----------
    $script:ModelSetup = $null
    function Get-LaneModelSetup {
        if ($null -ne $script:ModelSetup) { return $script:ModelSetup }
        $st = [ordered]@{ ok = $false; reason = ''; fixture = $null; fixture_url = ''; serve = $null; serve_url = ''; serve_port = 0; fixture_port = 0 }
        if (-not (Test-LaneModelKeyAvailable)) {
            $st.reason = 'OPERATOR_ACTION_REQUIRED: ModelKeyEnvName ausente ou vazio (' + (Get-LaneModelKeyLogToken) + ')'
            $script:ModelSetup = $st
            return $st
        }
        # SECFIX: importacao de credenciais SOMENTE aqui (pos-gate, S5/S6
        # selecionados via Get-LaneModelSetup), antes de subir fixture/serve.
        [void](Import-LaneProfileCredentials $profTesting)
        $fx = Get-LaneFixture -Wanted $FixtureDir
        if (-not [bool]$fx.ok) { $st.reason = ('fixture: ' + $fx.reason); $script:ModelSetup = $st; return $st }
        $py = Get-Command python -ErrorAction SilentlyContinue
        if ($null -eq $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
        if ($null -eq $py) { $st.reason = 'python indisponivel para fixture http.server (infra)'; $script:ModelSetup = $st; return $st }
        $fjob = $null
        try { $fjob = New-RuntimeJobObject } catch { $fjob = $null }
        if (($null -eq $fjob) -or (-not [bool]$fjob.Ok)) { $st.reason = 'job da fixture indisponivel (fail-closed)'; $script:ModelSetup = $st; return $st }
        $fProc = Start-LaneOwnedProcess -FilePath ([string]$py.Source) -ArgumentList @('-m', 'http.server', "$portFixture", '--bind', '127.0.0.1', '--directory', ([string]$fx.dir)) -EnvTable $profTesting.env -EnvRemove $script:SensitiveEnvRemove -WorkDir ([string]$fx.dir) -LogName 'fixture'
        if (-not [bool]$fProc.ok) {
            try { [void](Close-RuntimeJobObject -Job $fjob) } catch { }
            $st.reason = ('fixture http.server nao iniciou: ' + $fProc.reason)
            $script:ModelSetup = $st
            return $st
        }
        if (-not (Wait-LaneListener -Port $portFixture -DeadlineSeconds 30)) {
            $st.reason = 'fixture sem listener em 30s (infra)'
            $script:ModelSetup = $st
            return $st
        }
        $serveProc = Start-LaneOwnedProcess -FilePath $script:Exe -ArgumentList @('serve', '--port', "$portSvcTesting") -EnvTable (Get-LaneModelChildEnv -BaseEnv $profTesting.env) -EnvRemove ($script:IsoRemove + ($script:SensitiveEnvRemove | Where-Object { ($_ -cne $script:ModelKeyEnvNameClean) -and ($_ -cne 'OPENCODE_PASSWORD') })) -WorkDir ([string]$profTesting.cwd) -LogName 'serve-testing-model'
        if (-not [bool]$serveProc.ok) { $st.reason = ('serve testing nao iniciou: ' + $serveProc.reason); $script:ModelSetup = $st; return $st }
        if (-not (Wait-LaneListener -Port $portSvcTesting -DeadlineSeconds $ServeTimeoutSeconds)) {
            $st.reason = 'serve testing sem listener (infra)'
            $script:ModelSetup = $st
            return $st
        }
        $cc = Copy-LaneCredentials ([string]$profTesting.db)
        if (-not [bool]$cc.ok) { $st.reason = ('credential store indisponivel: ' + [string]$cc.reason); $script:ModelSetup = $st; return $st }
        $st.cred_rows = [int]$cc.rows
        $st.ok = $true
        $st.fixture = $fx
        $st.fixture_port = $portFixture
        $st.fixture_url = ('http://127.0.0.1:' + $portFixture + '/index.html')
        $st.serve = $serveProc
        $st.serve_url = ('http://127.0.0.1:' + $portSvcTesting)
        $st.serve_port = $portSvcTesting
        $st.reason = 'setup ok'
        $script:ModelSetup = $st
        return $st
    }
    function Invoke-LaneModelRun {
        [CmdletBinding()] param([string]$ServerUrl = '', [string]$SessionId = '', [string]$Model = '', [string]$Agent = '', [string]$Prompt = '')
        $res = [ordered]@{ attempted = $false; ok = $false; exit = -1; timedout = $false; out = ''; job_assigned = $false; reason = '' }
        try {
            if (-not (Test-LaneModelKeyAvailable)) { $res.reason = 'model-key indisponivel (fail-closed)'; return $res }
            if (-not (Test-LaneLocalhostUrl $ServerUrl)) { $res.reason = 'URL fora de localhost (guard)'; return $res }
            $safePrompt = (([string]$Prompt) -replace '[&|<>\^%!"''();$`\{\}\[\]\r\n]', '-').Trim()
            if ([string]::IsNullOrWhiteSpace($safePrompt)) { $safePrompt = 'lane-model-probe' }
            if ($safePrompt.Length -gt 800) { $safePrompt = $safePrompt.Substring(0, 800) }
            $turnJob = $null
            try { $turnJob = New-RuntimeJobObject } catch { $turnJob = $null }
            if (($null -eq $turnJob) -or (-not [bool]$turnJob.Ok)) { $res.reason = 'job do turn indisponivel (fail-closed)'; return $res }
            $turnFlags = $null
            try { $turnFlags = Get-RuntimeJobLimitFlags -Job $turnJob } catch { $turnFlags = $null }
            if (($null -eq $turnFlags) -or (-not [bool]$turnFlags.Ok) -or (-not [bool]$turnFlags.KillOnClose)) {
                try { [void](Close-RuntimeJobObject -Job $turnJob) } catch { }
                $res.reason = 'job do turn sem KILL_ON_JOB_CLOSE (fail-closed)'
                return $res
            }
            $modelEnv = Get-LaneModelChildEnv -BaseEnv $profTesting.env
            $modelAuth = Add-LaneServeAuth $modelEnv
            if (-not [bool]$modelAuth.hasPassword) { $res.reason = 'serve sem segredo legivel (auth fail-closed) (auth fail-closed)'; return $res }
            $modelEnv = $modelAuth.env
            $modelRemove = @($script:ApiRemove | Where-Object { $_ -cne $script:ModelKeyEnvNameClean })
            $res.attempted = $true
            $r = $null
            try {
                $r = Invoke-SpikeChild -FilePath $script:Exe -ArgumentList @('run', '--server', $ServerUrl, '--session', $SessionId, '--model', $Model, '--agent', $Agent, '--format', 'json', $safePrompt) -EnvSet $modelEnv -EnvRemove $modelRemove -WorkingDirectory ([string]$profTesting.cwd) -TimeoutMs 240000 -CleanEnvironment -StdinNul -JobObject $turnJob
            } finally {
                try { [void](Close-RuntimeJobObject -Job $turnJob) } catch { }
            }
            if ($null -eq $r) { $res.reason = 'spawn sem resultado (fail-closed)'; return $res }
            $res.exit = [int]$r.ExitCode
            $res.timedout = [bool]$r.TimedOut
            $res.job_assigned = [bool]$r.JobAssigned
            $res.out = ([string]$r.Stdout + "`n" + [string]$r.Stderr)
            $res.ok = ((-not [bool]$r.TimedOut) -and ([int]$r.ExitCode -eq 0) -and ([bool]$r.JobAssigned))
            if ((-not [bool]$r.JobAssigned) -and ([int]$r.ExitCode -eq 0) -and (-not [bool]$r.TimedOut)) {
                $res.reason = 'rc=0 mas atribuicao ao job NAO comprovada (nao conta como ok)'
            }
            return $res
        } catch {
            $res.reason = (Get-LaneSafeText $_.Exception.Message 160)
            return $res
        }
    }
    function New-LaneApiSession([string]$ServerUrl, $EnvTable, [string]$Cwd) {
        try {
            if (-not (Test-LaneLocalhostUrl $ServerUrl)) { return [ordered]@{ ok = $false; reason = 'URL fora de localhost (guard)'; id = '' } }
            $authN = Add-LaneServeAuth $EnvTable
            $r = Invoke-PreflightBoundedExe -File $script:Exe -ArgsLine ('api --server ' + $ServerUrl + ' POST /api/session --data "{}"') -WorkDir $Cwd -EnvTable $authN.env -EnvRemove $script:ApiRemove -TimeoutMs 30000 -MaxChars 65536
            if ((-not [bool]$r.Finished) -or ([int]$r.ExitCode -ne 0)) { return [ordered]@{ ok = $false; reason = ('post-failed:exit=' + [int]$r.ExitCode + ' timedout=' + [bool]$r.TimedOut + ' serve-auth-ok=' + [bool]$authN.hasPassword); id = '' } }
            $j = $null
            try { $j = ConvertFrom-Json ([string]$r.Output) } catch { $j = $null }
            $node = Get-JsonProp $j 'data' $j
            $sid = [string](Get-JsonProp $node 'id' '')
            if ([string]::IsNullOrWhiteSpace($sid)) { return [ordered]@{ ok = $false; reason = 'sem id na resposta'; id = '' } }
            return [ordered]@{ ok = $true; reason = ''; id = $sid }
        } catch { return [ordered]@{ ok = $false; reason = (Get-LaneSafeText $_.Exception.Message 120); id = '' } }
    }

    # ==================================================================
    # S5 tester->Playwright (model-gated)
    # ==================================================================
    if (Test-ScenarioSelected 'S5') {
        $proofs = New-Object System.Collections.ArrayList
        $coverage = New-Object System.Collections.ArrayList
        try {
            $ms = Get-LaneModelSetup
            if (-not [bool]$ms.ok) {
                [void](Add-ScenarioProof $proofs 'model-setup' $false $ms.reason)
                Set-ScenarioResult 'S5' 'blocked' $ms.reason $proofs $coverage
            } else {
                [void](Add-ScenarioProof $proofs 'model-setup' $true ('fixture+serve owned; ' + (Get-LaneModelKeyLogToken)))
                [void](Add-ScenarioProof $proofs 'credential-store' $true ('credential rows=' + [int]$ms.cred_rows + ' no DB isolado'))
                $sess = New-LaneApiSession -ServerUrl ([string]$ms.serve_url) -EnvTable $profTesting.env -Cwd ([string]$profTesting.cwd)
                if (-not [bool]$sess.ok) {
                    [void](Add-ScenarioProof $proofs 'session-created' $false $sess.reason)
                    Set-ScenarioResult 'S5' 'blocked' ('sessao API indisponivel: ' + $sess.reason) $proofs $coverage
                } else {
                    [void](Add-ScenarioProof $proofs 'session-created' $true ('id len=' + ([string]$sess.id).Length))
                    $prompt5 = 'Delegate to the tester subagent: open ' + [string]$ms.fixture_url + ' with the Playwright browser tools ONLY (browser_navigate, browser_snapshot, browser_click). Do NOT read the page via shell, curl, cat or any file tool. Click the button id count-btn exactly 3 times, read span id count, and report CLICKS_DONE=<n>.'
                    $sha5 = Get-PromptSha256 $prompt5
                    $turn = Invoke-LaneModelRun -ServerUrl ([string]$ms.serve_url) -SessionId ([string]$sess.id) -Model $CheapModel -Agent 'build' -Prompt $prompt5
                    if (-not [bool]$turn.attempted) {
                        [void](Add-ScenarioProof $proofs 'model-turn' $false $turn.reason)
                        Set-ScenarioResult 'S5' 'blocked' ('turn nao tentado: ' + $turn.reason) $proofs $coverage
                    } elseif ([bool]$turn.timedout) {
                        [void](Add-ScenarioProof $proofs 'model-turn' $false 'TIMEOUT 240s')
                        [void](Add-ScenarioProof $proofs 'turn-output-head' $true (Get-LaneSafeText $turn.out 2000))
                        Set-ScenarioResult 'S5' 'blocked' 'turn TIMEOUT 240s (infra/modelo).' $proofs $coverage
                    } elseif (-not [bool]$turn.ok) {
                        [void](Add-ScenarioProof $proofs 'model-turn' $false ('exit=' + [int]$turn.exit + ' job=' + [bool]$turn.job_assigned + ' ' + $turn.reason))
                        [void](Add-ScenarioProof $proofs 'turn-output-head' $true (Get-LaneSafeText $turn.out 2000))
                        if (Test-InfraMarkers $turn.out) { Set-ScenarioResult 'S5' 'blocked' ('turn infra: exit=' + [int]$turn.exit) $proofs $coverage }
                        else { Set-ScenarioResult 'S5' 'fail' ('turn falhou com saida limpa: exit=' + [int]$turn.exit + ' ' + $turn.reason) $proofs $coverage }
                    } else {
                        [void](Add-ScenarioProof $proofs 'turn-output-head' $true (Get-LaneSafeText $turn.out 2000))
                        $matchLines = @($turn.out -split "`n" | Where-Object { $_ -match '(?i)browser_(navigate|snapshot|click|take_screenshot|console_messages|network_requests|evaluate|fill_form|type|hover|drag|wait_for|tabs|press_key|select_option)|CLICKS_DONE|tool[-_ ]?call|subagent|delegate' } | Select-Object -First 40)
                        [void](Add-ScenarioProof $proofs 'transcript-match-lines' $true (($matchLines -join "`n").Substring(0, [Math]::Min(3500, ($matchLines -join "`n").Length))))
                        $hasPwCall = (($turn.out -match '(?i)playwright_') -or ($turn.out -match '(?i)browser_(navigate|snapshot|click|take_screenshot|console_messages|network_requests|evaluate|fill_form|type|hover|drag|wait_for|tabs|press_key|select_option)\b'))
                        $hasTester = ($turn.out -match '(?i)tester')
                        $clicks = ([regex]::Matches($turn.out, '(?i)browser_click')).Count
                        $forbidden = Test-LaneForbiddenCall $turn.out
                        $mVal = [regex]::Match($turn.out, '(?i)CLICKS_DONE\s*[=:]\s*(\d+)')
                        $reported = ''
                        if ($mVal.Success) { $reported = $mVal.Groups[1].Value }
                        [void](Add-ScenarioProof $proofs 'toolcalls-playwright' ([bool]$hasPwCall) 'transcript contem playwright_*')
                        [void](Add-ScenarioProof $proofs 'click-calls' ([int]$clicks -ge 3) ('browser_click no transcript=' + [int]$clicks + ' (esperado >=3)'))
                        [void](Add-ScenarioProof $proofs 'child-tester-text' ([bool]$hasTester) 'transcript cita tester (auxiliar; prova estrutural abaixo)')
                        [void](Add-ScenarioProof $proofs 'reported-value' ($reported -ceq '3') ('CLICKS_DONE=' + $reported + ' (esperado 3)'))
                        [void](Add-ScenarioProof $proofs 'zero-forbidden-calls' (-not [bool]$forbidden) 'nenhum run_code_unsafe no transcript')
                        if ([bool]$forbidden) {
                            Set-ScenarioResult 'S5' 'fail' 'transcript contem chamada proibida run_code_unsafe.' $proofs $coverage
                        } else {
                        $auth5 = Add-LaneServeAuth $profTesting.env
                        $childAgents = @()
                        if ([bool]$auth5.hasPassword) { $childAgents = @(Get-LaneChildAgents ([string]$ms.serve_url) $auth5.env $script:ApiRemove ([string]$profTesting.cwd) ([string]$sess.id)) }
                        $childTester = (@($childAgents) -contains 'tester')
                        [void](Add-ScenarioProof $proofs 'child-session-tester' ([bool]$childTester) ('child sessions via GET /api/session com parentID da sessao: [' + ($childAgents -join ',') + ']'))
                        $childTx = Get-LaneChildTranscript ([string]$ms.serve_url) $auth5.env $script:ApiRemove ([string]$profTesting.cwd) ([string]$sess.id) 'tester'
                        [void](Add-ScenarioProof $proofs 'child-transcript-tester' (-not [string]::IsNullOrWhiteSpace($childTx)) $childTx)
                        $childForbidden5 = Test-LaneForbiddenCall $childTx
                        [void](Add-ScenarioProof $proofs 'zero-forbidden-calls-child' (-not [bool]$childForbidden5) 'child transcript sem run_code_unsafe (scan pre-truncamento do raw)')
                        $indep = 'nao-executada'
                        $indepOk = $false
                        try {
                            $nodeExe2 = ''
                            $npxCli2 = ''
                            $nc2 = Get-Command npx.cmd -ErrorAction SilentlyContinue
                            if ($null -ne $nc2) {
                                $nd2 = Split-Path -Parent ([string]$nc2.Source)
                                $n2 = Join-Path $nd2 'node.exe'
                                $c2 = Join-Path (Join-Path (Join-Path $nd2 'node_modules') 'npm') 'bin\npx-cli.js'
                                if ((Test-Path -LiteralPath $n2 -PathType Leaf) -and (Test-Path -LiteralPath $c2 -PathType Leaf)) { $nodeExe2 = $n2; $npxCli2 = $c2 }
                            }
                            if (-not [string]::IsNullOrWhiteSpace($nodeExe2)) {
                                $ijob = New-RuntimeJobObject
                                $ijok = (($null -ne $ijob) -and [bool]$ijob.Ok)
                                if ($ijok) {
                                    $ipsi = New-Object System.Diagnostics.ProcessStartInfo
                                    $ipsi.FileName = $nodeExe2
                                    $ipsi.Arguments = (ConvertTo-SpikeArguments -ArgumentList @($npxCli2, '-y', '@playwright/mcp@0.0.83', '--headless', '--isolated'))
                                    $ipsi.UseShellExecute = $false
                                    $ipsi.RedirectStandardOutput = $true
                                    $ipsi.RedirectStandardError = $true
                                    $ipsi.RedirectStandardInput = $true
                                    $ipsi.CreateNoWindow = $true
                                    $ipsi.WorkingDirectory = $TargetHome
                                    try { $ipsi.EnvironmentVariables.Clear() } catch { }
                                    foreach ($kn in @('PATH', 'SystemRoot', 'WINDIR', 'ComSpec', 'PATHEXT', 'TEMP', 'TMP', 'SystemDrive', 'ProgramFiles', 'ProgramFiles(x86)', 'LOCALAPPDATA', 'APPDATA')) {
                                        try {
                                            $kv = [Environment]::GetEnvironmentVariable($kn, 'Process')
                                            if ($null -ne $kv) { $ipsi.EnvironmentVariables[$kn] = [string]$kv }
                                        } catch { }
                                    }
                                    $npmHomeV = Join-Path $TargetHome 'npm-home'
                                    $npmCacheV = Join-Path $TargetHome 'npm-cache'
                                    foreach ($dd in @($npmHomeV, $npmCacheV)) { try { if (-not (Test-Path -LiteralPath $dd -PathType Container)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null } } catch { } }
                                    $ipsi.EnvironmentVariables['HOME'] = $npmHomeV
                                    $ipsi.EnvironmentVariables['USERPROFILE'] = $npmHomeV
                                    $ipsi.EnvironmentVariables['npm_config_cache'] = $npmCacheV
                                    # FIXTURE(S5S6-BROWSER-FIX): mesmo env lane-owned dos filhos serve.
                                    $laneTmpV = Join-Path $TargetHome 'lane-tmp'
                                    try { if (-not (Test-Path -LiteralPath $laneTmpV -PathType Container)) { New-Item -ItemType Directory -Path $laneTmpV -Force | Out-Null } } catch { }
                                    $ipsi.EnvironmentVariables['TEMP'] = $laneTmpV
                                    $ipsi.EnvironmentVariables['TMP'] = $laneTmpV
                                    $ip = [System.Diagnostics.Process]::Start($ipsi)
                                    $iadd = Add-RuntimeJobProcess -Job $ijob -Process $ip
                                    if ([bool]$iadd.Ok) {
                                        $escUrl = ([string]$ms.fixture_url -replace '"', '%22')
                                        $callNav = '{"jsonrpc":"2.0","id":10,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"oo-lane","version":"1.0"}}}'
                                        $callList = '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"browser_navigate","arguments":{"url":"' + $escUrl + '"}}}'
                                        $callSnap = '{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"browser_snapshot","arguments":{}}}'
                                        try {
                                            $ip.StandardInput.WriteLine($callNav)
                                            $ip.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')
                                            $ip.StandardInput.WriteLine($callList)
                                            $ip.StandardInput.WriteLine($callSnap)
                                            $ip.StandardInput.Flush()
                                        } catch { }
                                        $snapText = ''
                                        $navOk = $false
                                        $dl = [DateTime]::UtcNow.AddSeconds(240)
                                        $t2 = $null
                                        while ([DateTime]::UtcNow -lt $dl) {
                                            try {
                                                if ($ip.HasExited) { break }
                                                if ($null -eq $t2) { $t2 = $ip.StandardOutput.ReadLineAsync() }
                                                if (-not $t2.Wait(2000)) { continue }
                                                $ln2 = $null
                                                try { $ln2 = $t2.Result } catch { $ln2 = $null }
                                                $t2 = $null
                                                if ($null -eq $ln2) { Start-Sleep -Milliseconds 500; continue }
                                                $snapText = $snapText + "`n" + $ln2
                                                if ($snapText -match '"id"\s*:\s*11') { $navOk = $true }
                                                if ($snapText -match '"id"\s*:\s*12') { break }
                                            } catch { break }
                                        }
                                        $hasCount = ($snapText -match '(?i)count')
                                        $titleHit = ($snapText -match '(?i)lane-fixture-counter')
                                        [void](Add-ScenarioProof $proofs 'stdio-raw-head' $true (Get-LaneSafeText $snapText 1000))
                                        [void](Add-ScenarioProof $proofs 'stdio-full' $true (Get-LaneSafeText $snapText 6000))
                                        $indepOk = ([bool]$navOk -and [bool]$hasCount)
                                        $indep = 'snapshot(stdio): navigate-ok=' + $navOk + ' count-presente=' + $hasCount + ' titulo-lane=' + $titleHit
                                        try { $ip.StandardInput.Close() } catch { }
                                    } else { $indep = 'sem atribuicao ao job (fail-closed)' }
                                    try { [void](Stop-RuntimeJobObject -Job $ijob) } catch { }
                                    try { [void](Close-RuntimeJobObject -Job $ijob) } catch { }
                                } else { $indep = 'job da verificacao indisponivel' }
                            } else { $indep = 'npx indisponivel para verificacao' }
                        } catch { $indep = (Get-LaneSafeText $_.Exception.Message 120) }
                        [void](Add-ScenarioProof $proofs 'independent-stdio-verify' ([bool]$indepOk) $indep)
                        Add-EvidenceRecord ([ordered]@{
                            objective_id = 'AGENT-MCP-B-LANE'; task_id = 'S5-tester-playwright'; session_id = ([string]$sess.id).Substring(0, [Math]::Min(8, ([string]$sess.id).Length)) + '...'
                            run_id = 'lane-run'; agent_id = 'tester'; profile_id = 'testing'; mcp_id = 'playwright-mcp'
                            tool_id = 'playwright_*'; invocation_status = 'turn-ok'; result_status = 'reported=' + $reported
                            timestamp = (Get-LaneTimestampUtc); evidence_source = 'run --server build->tester + stdio snapshot independente'
                            prompt_sha256 = $sha5
                        })
                        $txNav = Test-LaneToolSuccess $childTx 'browser_navigate' 1
                        $txClick = Test-LaneToolSuccess $childTx 'browser_click' 3
                        [void](Add-ScenarioProof $proofs 'child-tools-nav' ([bool]$txNav) 'child transcript com TOOL browser_navigate com status de sucesso (estruturado)')
                        [void](Add-ScenarioProof $proofs 'child-tools-click' ([bool]$txClick) 'child transcript com >=3 TOOL browser_click com status de sucesso (falha => reprova)')
                        if ([bool]$childForbidden5) {
                            Set-ScenarioResult 'S5' 'fail' 'child transcript contem chamada proibida run_code_unsafe (scan pre-truncamento).' $proofs $coverage
                        } elseif ($hasPwCall -and $txNav -and $txClick -and $childTester -and ($reported -ceq '3')) {
                            $stdNote = 'stdio auxiliar inconclusivo'
                            if ([bool]$indepOk) { $stdNote = 'stdio auxiliar coerente' }
                            Set-ScenarioResult 'S5' 'pass-real' ('tester via Playwright: child transcript com navigate+>=3 clicks + CLICKS_DONE=3 + zero proibidas; ' + $stdNote + '.') $proofs $coverage
                        } else {
                            Set-ScenarioResult 'S5' 'fail' 'turn ok mas sem feixe completo (TOOL records na child + valor 3).' $proofs $coverage
                        }
                        }
                    }
                }
            }
        } catch {
            Set-ScenarioResult 'S5' 'blocked' ('excecao (infra): ' + (Get-LaneSafeText $_.Exception.Message 160)) $proofs $coverage
        }
    }

    # ==================================================================
    # S6 debugger->DevTools (model-gated)
    # ==================================================================
    if (Test-ScenarioSelected 'S6') {
        $proofs = New-Object System.Collections.ArrayList
        $coverage = New-Object System.Collections.ArrayList
        try {
            $ms = Get-LaneModelSetup
            if (-not [bool]$ms.ok) {
                [void](Add-ScenarioProof $proofs 'model-setup' $false $ms.reason)
                Set-ScenarioResult 'S6' 'blocked' $ms.reason $proofs $coverage
            } else {
                [void](Add-ScenarioProof $proofs 'model-setup' $true ('fixture+serve owned; ' + (Get-LaneModelKeyLogToken)))
                [void](Add-ScenarioProof $proofs 'credential-store' $true ('credential rows=' + [int]$ms.cred_rows + ' no DB isolado'))
                $sess = New-LaneApiSession -ServerUrl ([string]$ms.serve_url) -EnvTable $profTesting.env -Cwd ([string]$profTesting.cwd)
                if (-not [bool]$sess.ok) {
                    [void](Add-ScenarioProof $proofs 'session-created' $false $sess.reason)
                    Set-ScenarioResult 'S6' 'blocked' ('sessao API indisponivel: ' + $sess.reason) $proofs $coverage
                } else {
                    [void](Add-ScenarioProof $proofs 'session-created' $true ('id len=' + ([string]$sess.id).Length))
                    $errUrl = ([string]$ms.serve_url).Replace(([string]$ms.serve_port), ([string]$ms.fixture_port)) + '/error.html'
                    if (-not (Test-LaneLocalhostUrl $errUrl)) { $errUrl = ('http://127.0.0.1:' + $ms.fixture_port + '/error.html') }
                    $prompt6 = 'Delegate to the debugger subagent: open ' + $errUrl + ' with the Chrome DevTools browser tools, read console messages and DOM snapshot, and diagnose the failure citing the exact error text found in console and DOM.'
                    $sha6 = Get-PromptSha256 $prompt6
                    $turn = Invoke-LaneModelRun -ServerUrl ([string]$ms.serve_url) -SessionId ([string]$sess.id) -Model $StrongModel -Agent 'build' -Prompt $prompt6
                    if (-not [bool]$turn.attempted) {
                        [void](Add-ScenarioProof $proofs 'model-turn' $false $turn.reason)
                        Set-ScenarioResult 'S6' 'blocked' ('turn nao tentado: ' + $turn.reason) $proofs $coverage
                    } elseif ([bool]$turn.timedout) {
                        [void](Add-ScenarioProof $proofs 'model-turn' $false 'TIMEOUT 240s')
                        [void](Add-ScenarioProof $proofs 'turn-output-head' $true (Get-LaneSafeText $turn.out 2000))
                        Set-ScenarioResult 'S6' 'blocked' 'turn TIMEOUT 240s (infra/modelo).' $proofs $coverage
                    } elseif (-not [bool]$turn.ok) {
                        [void](Add-ScenarioProof $proofs 'model-turn' $false ('exit=' + [int]$turn.exit + ' ' + $turn.reason))
                        [void](Add-ScenarioProof $proofs 'turn-output-head' $true (Get-LaneSafeText $turn.out 2000))
                        if (Test-InfraMarkers $turn.out) { Set-ScenarioResult 'S6' 'blocked' ('turn infra: exit=' + [int]$turn.exit) $proofs $coverage }
                        else { Set-ScenarioResult 'S6' 'fail' ('turn falhou com saida limpa: exit=' + [int]$turn.exit) $proofs $coverage }
                    } else {
                        [void](Add-ScenarioProof $proofs 'turn-output-head' $true (Get-LaneSafeText $turn.out 2000))
                        $matchLines6 = @($turn.out -split "`n" | Where-Object { $_ -match '(?i)(chrome[-_]?devtools[_-])?(navigate_page|take_snapshot|take_screenshot|list_console_messages|list_network_requests|evaluate_script|get_console_message|get_network_request|performance_|take_heapsnapshot|lighthouse_audit|new_page|select_page|press_key|type_text|upload_file|fill_form)|FIXTURE-ERROR-42|tool[-_ ]?call|subagent|delegate' } | Select-Object -First 40)
                        [void](Add-ScenarioProof $proofs 'transcript-match-lines' $true (($matchLines6 -join "`n").Substring(0, [Math]::Min(3500, ($matchLines6 -join "`n").Length))))
                        $hasDtCall = (($turn.out -match '(?i)(chrome[-_]?devtools[_-])?(navigate_page|take_snapshot|take_screenshot|list_console_messages|list_network_requests|evaluate_script|get_console_message|get_network_request|performance_|take_heapsnapshot|lighthouse_audit|new_page|select_page|press_key|type_text|upload_file|fill_form)\b') -or ($turn.out -match '(?i)devtools_'))
                        $hasDbg = ($turn.out -match '(?i)debugger')
                        $citesErr = ($turn.out -match 'FIXTURE-ERROR-42')
                        $forbidden6 = Test-LaneForbiddenCall $turn.out
                        [void](Add-ScenarioProof $proofs 'toolcalls-devtools' ([bool]$hasDtCall) 'transcript contem (chrome-)devtools_*')
                        [void](Add-ScenarioProof $proofs 'child-debugger-text' ([bool]$hasDbg) 'transcript cita debugger (auxiliar; prova estrutural abaixo)')
                        [void](Add-ScenarioProof $proofs 'cites-real-error' ([bool]$citesErr) 'diagnostico cita FIXTURE-ERROR-42 (marcador NAO entregue no prompt)')
                        [void](Add-ScenarioProof $proofs 'zero-forbidden-calls' (-not [bool]$forbidden6) 'nenhum run_code_unsafe no transcript')
                        if ([bool]$forbidden6) {
                            Set-ScenarioResult 'S6' 'fail' 'transcript contem chamada proibida run_code_unsafe.' $proofs $coverage
                        } else {
                        $auth6 = Add-LaneServeAuth $profTesting.env
                        $childAgents6 = @()
                        if ([bool]$auth6.hasPassword) { $childAgents6 = @(Get-LaneChildAgents ([string]$ms.serve_url) $auth6.env $script:ApiRemove ([string]$profTesting.cwd) ([string]$sess.id)) }
                        $childDebugger = (@($childAgents6) -contains 'debugger')
                        [void](Add-ScenarioProof $proofs 'child-session-debugger' ([bool]$childDebugger) ('child sessions via GET /api/session com parentID da sessao: [' + ($childAgents6 -join ',') + ']'))
                        $auth6b = Add-LaneServeAuth $profTesting.env
                        $childTx6 = ''
                        if ([bool]$auth6b.hasPassword) { $childTx6 = Get-LaneChildTranscript ([string]$ms.serve_url) $auth6b.env $script:ApiRemove ([string]$profTesting.cwd) ([string]$sess.id) 'debugger' }
                        [void](Add-ScenarioProof $proofs 'child-transcript-debugger' (-not [string]::IsNullOrWhiteSpace($childTx6)) $childTx6)
                        $childForbidden6 = Test-LaneForbiddenCall $childTx6
                        [void](Add-ScenarioProof $proofs 'zero-forbidden-calls-child' (-not [bool]$childForbidden6) 'child transcript sem run_code_unsafe (scan pre-truncamento do raw)')
                        Add-EvidenceRecord ([ordered]@{
                            objective_id = 'AGENT-MCP-B-LANE'; task_id = 'S6-debugger-devtools'; session_id = ([string]$sess.id).Substring(0, [Math]::Min(8, ([string]$sess.id).Length)) + '...'
                            run_id = 'lane-run'; agent_id = 'debugger'; profile_id = 'testing'; mcp_id = 'chrome-devtools-mcp'
                            tool_id = 'devtools_*'; invocation_status = 'turn-ok'; result_status = 'cites-error=' + $citesErr
                            timestamp = (Get-LaneTimestampUtc); evidence_source = 'run --server build->debugger'
                            prompt_sha256 = $sha6
                        })
                        $txDiagConsole = Test-LaneToolSuccess $childTx6 '(list_console_messages|get_console_message)' 1
                        $txDiagDom = Test-LaneToolSuccess $childTx6 'take_snapshot' 1
                        [void](Add-ScenarioProof $proofs 'child-tools-diag-console' ([bool]$txDiagConsole) 'child transcript com TOOL de leitura de console com status de sucesso')
                        [void](Add-ScenarioProof $proofs 'child-tools-diag-dom' ([bool]$txDiagDom) 'child transcript com TOOL take_snapshot (DOM) com status de sucesso; close_page/hover sozinhos reprovam')
                        if ([bool]$childForbidden6) {
                            Set-ScenarioResult 'S6' 'fail' 'child transcript contem chamada proibida run_code_unsafe (scan pre-truncamento).' $proofs $coverage
                        } elseif ($hasDtCall -and $txDiagConsole -and $txDiagDom -and $hasDbg -and $citesErr -and $childDebugger) {
                            Set-ScenarioResult 'S6' 'pass-real' 'debugger via DevTools: child transcript com TOOL diagnostica + diagnostico citando FIXTURE-ERROR-42 (nao entregue no prompt).' $proofs $coverage
                        } else {
                            Set-ScenarioResult 'S6' 'fail' 'turn ok mas sem feixe completo (TOOL diagnostica na child + erro real).' $proofs $coverage
                        }
                        }
                    }
                }
            }
        } catch {
            Set-ScenarioResult 'S6' 'blocked' ('excecao (infra): ' + (Get-LaneSafeText $_.Exception.Message 160)) $proofs $coverage
        }
    }

    # ==================================================================
    # S7 negative dynamic (model-gated, perfil default)
    # ==================================================================
    if (Test-ScenarioSelected 'S7') {
        $proofs = New-Object System.Collections.ArrayList
        $coverage = New-Object System.Collections.ArrayList
        try {
            if (-not (Test-LaneModelKeyAvailable)) {
                [void](Add-ScenarioProof $proofs 'model-gate' $false ('OPERATOR_ACTION_REQUIRED (' + (Get-LaneModelKeyLogToken) + ')'))
                Set-ScenarioResult 'S7' 'blocked' ('OPERATOR_ACTION_REQUIRED: ' + (Get-LaneModelKeyLogToken)) $proofs $coverage
            } else {
                # SECFIX: importacao de credenciais SOMENTE aqui (pos-gate S7).
                [void](Import-LaneProfileCredentials $profDefault)
                $serveD = Start-LaneOwnedProcess -FilePath $script:Exe -ArgumentList @('serve', '--port', "$portSvcDefault") -EnvTable (Get-LaneModelChildEnv -BaseEnv $profDefault.env) -EnvRemove ($script:IsoRemove + ($script:SensitiveEnvRemove | Where-Object { ($_ -cne $script:ModelKeyEnvNameClean) -and ($_ -cne 'OPENCODE_PASSWORD') })) -WorkDir ([string]$profDefault.cwd) -LogName 'serve-default'
                if (-not [bool]$serveD.ok) {
                    [void](Add-ScenarioProof $proofs 'serve-default' $false $serveD.reason)
                    Set-ScenarioResult 'S7' 'blocked' ('serve default nao iniciou: ' + $serveD.reason) $proofs $coverage
                } elseif (-not (Wait-LaneListener -Port $portSvcDefault -DeadlineSeconds $ServeTimeoutSeconds)) {
                    [void](Add-ScenarioProof $proofs 'serve-default' $false 'sem listener (infra)')
                    Set-ScenarioResult 'S7' 'blocked' 'serve default sem listener (infra).' $proofs $coverage
                } else {
                    $cc7 = Copy-LaneCredentials ([string]$profDefault.db)
                    [void](Add-ScenarioProof $proofs 'credential-store' ([bool]$cc7.ok) ('credential copiada: rows=' + [int]$cc7.rows + ' ' + [string]$cc7.reason))
                    if (-not [bool]$cc7.ok) {
                        Set-ScenarioResult 'S7' 'blocked' ('credential store indisponivel: ' + [string]$cc7.reason) $proofs $coverage
                    } else {
                    $urlD = ('http://127.0.0.1:' + $portSvcDefault)
                    $sess = New-LaneApiSession -ServerUrl $urlD -EnvTable $profDefault.env -Cwd ([string]$profDefault.cwd)
                    if (-not [bool]$sess.ok) {
                        [void](Add-ScenarioProof $proofs 'session-created' $false $sess.reason)
                        Set-ScenarioResult 'S7' 'blocked' ('sessao API indisponivel: ' + $sess.reason) $proofs $coverage
                    } else {
                        $prompt7 = 'Report the Node.js version available in this environment (run node --version). Do not use any browser tool.'
                        $sha7 = Get-PromptSha256 $prompt7
                        $tjob = $null
                        try { $tjob = New-RuntimeJobObject } catch { $tjob = $null }
                        $turn = [ordered]@{ attempted = $false; ok = $false; exit = -1; timedout = $false; out = ''; job_assigned = $false; reason = '' }
                        $jok7 = (($null -ne $tjob) -and [bool]$tjob.Ok)
                        if ($jok7) {
                            try {
                                $jf7 = Get-RuntimeJobLimitFlags -Job $tjob
                                $jok7 = (($null -ne $jf7) -and [bool]$jf7.Ok -and [bool]$jf7.KillOnClose)
                            } catch { $jok7 = $false }
                        }
                        if (-not $jok7) { $turn.reason = 'job do turn indisponivel (fail-closed)' }
                        else {
                            $runEnv7 = Add-LaneServeAuth (Get-LaneModelChildEnv -BaseEnv $profDefault.env)
                            $hasPw7 = [bool]$runEnv7.hasPassword
                            [void](Add-ScenarioProof $proofs 'serve-auth' ([bool]$hasPw7) 'segredo do serve em memoria (nunca logado)')
                            if (-not $hasPw7) { $turn.reason = 'serve default sem segredo (auth fail-closed)' }
                            else {
                            $safeP7 = ($prompt7 -replace '[&|<>\^%!"''();$`\{\}\[\]\r\n]', '-')
                            $turn.attempted = $true
                            $r7 = $null
                            try {
                                $r7 = Invoke-SpikeChild -FilePath $script:Exe -ArgumentList @('run', '--server', $urlD, '--session', ([string]$sess.id), '--model', $CheapModel, '--agent', 'build', '--format', 'json', $safeP7) -EnvSet $runEnv7.env -EnvRemove (@($script:ApiRemove | Where-Object { $_ -cne $script:ModelKeyEnvNameClean })) -WorkingDirectory ([string]$profDefault.cwd) -TimeoutMs 240000 -CleanEnvironment -StdinNul -JobObject $tjob
                            } finally {
                                try { [void](Close-RuntimeJobObject -Job $tjob) } catch { }
                            }
                            if ($null -ne $r7) {
                                $turn.exit = [int]$r7.ExitCode
                                $turn.timedout = [bool]$r7.TimedOut
                                $turn.job_assigned = [bool]$r7.JobAssigned
                                $turn.out = ([string]$r7.Stdout + "`n" + [string]$r7.Stderr)
                                $turn.ok = ((-not [bool]$r7.TimedOut) -and ([int]$r7.ExitCode -eq 0) -and ([bool]$r7.JobAssigned))
                            }
                            }
                        }
                        if (-not [bool]$turn.attempted) {
                            [void](Add-ScenarioProof $proofs 'model-turn' $false $turn.reason)
                            Set-ScenarioResult 'S7' 'blocked' ('turn nao tentado: ' + $turn.reason) $proofs $coverage
                        } elseif ([bool]$turn.timedout) {
                            [void](Add-ScenarioProof $proofs 'model-turn' $false 'TIMEOUT 240s')
                            Set-ScenarioResult 'S7' 'blocked' 'turn TIMEOUT 240s (infra/modelo).' $proofs $coverage
                        } elseif (-not [bool]$turn.ok) {
                            [void](Add-ScenarioProof $proofs 'model-turn' $false ('exit=' + [int]$turn.exit))
                            [void](Add-ScenarioProof $proofs 'turn-output-head' $true (Get-LaneSafeText $turn.out 2000))
                            if (Test-InfraMarkers $turn.out) { Set-ScenarioResult 'S7' 'blocked' ('turn infra: exit=' + [int]$turn.exit) $proofs $coverage }
                            else { Set-ScenarioResult 'S7' 'fail' ('turn falhou com saida limpa: exit=' + [int]$turn.exit) $proofs $coverage }
                        } else {
                            $bCall = (($turn.out -match '(?i)playwright_') -or ($turn.out -match '(?i)devtools_') -or ($turn.out -match '(?i)browser_'))
                            $mcpAct = (($turn.out -match '(?i)mcp.*(playwright|devtools|browser)') -or ($turn.out -match '(?i)(playwright|devtools).*mcp'))
                            [void](Add-ScenarioProof $proofs 'zero-browser-toolcalls' (-not [bool]$bCall) 'nenhum playwright_/devtools_/browser_ no transcript')
                            [void](Add-ScenarioProof $proofs 'zero-mcp-activation' (-not [bool]$mcpAct) 'nenhuma ativacao MCP browser no transcript')
                            Add-EvidenceRecord ([ordered]@{
                                objective_id = 'AGENT-MCP-B-LANE'; task_id = 'S7-negative-dynamic'; session_id = ([string]$sess.id).Substring(0, [Math]::Min(8, ([string]$sess.id).Length)) + '...'
                                run_id = 'lane-run'; agent_id = 'build'; profile_id = 'default'; mcp_id = 'none'
                                tool_id = 'none-browser'; invocation_status = 'turn-ok'; result_status = 'zero-browser=' + ((-not $bCall) -and (-not $mcpAct))
                                timestamp = (Get-LaneTimestampUtc); evidence_source = 'run --server perfil default (tarefa sem browser)'
                                prompt_sha256 = $sha7
                            })
                            if ((-not $bCall) -and (-not $mcpAct)) {
                                Set-ScenarioResult 'S7' 'pass-real' 'perfil default, tarefa sem browser: zero tool calls browser + zero ativacao MCP.' $proofs $coverage
                            } else {
                                Set-ScenarioResult 'S7' 'fail' 'transcript mostra uso browser/MCP em tarefa sem browser.' $proofs $coverage
                            }
                            }
                        }
                    }
                }
            }
        } catch {
            Set-ScenarioResult 'S7' 'blocked' ('excecao (infra): ' + (Get-LaneSafeText $_.Exception.Message 160)) $proofs $coverage
        }
    }

    # ==================================================================
    # S8 cleanup/release
    # ==================================================================
    if (Test-ScenarioSelected 'S8') {
        $proofs = New-Object System.Collections.ArrayList
        $coverage = New-Object System.Collections.ArrayList
        try {
            $ownedBefore = @($script:OwnedProcs).Count
            [void](Add-ScenarioProof $proofs 'owned-before' ($ownedBefore -ge 0) ('processos owned rastreados=' + $ownedBefore))
            $stop = Stop-LaneOwned 's8'
            $leakN = @($stop.leaks).Count
            $stopFailN = @($stop.stopFailures).Count
            $priorBad = 0
            try {
                if ($null -ne $script:LaneCleanupLog) {
                    foreach ($r in @($script:LaneCleanupLog)) {
                        if ([string]$r['why'] -cne 's8') {
                            if (((@($r['leaks']).Count -gt 0) -or ((@($r['stopFailures']).Count -gt 0)))) { $priorBad += 1 }
                        }
                    }
                }
            } catch { }
            [void](Add-ScenarioProof $proofs 'owned-stopped' (($leakN -eq 0) -and ($stopFailN -eq 0)) ('leaks=' + $leakN + ' stop-failures=' + $stopFailN))
            [void](Add-ScenarioProof $proofs 'cleanup-attempts-all' ($priorBad -eq 0) ('tentativas anteriores com leak/falha=' + $priorBad + ' (LaneCleanupLog: todas as tentativas consideradas)'))
            $removed = $true
            try {
                if (Test-Path -LiteralPath $TargetHome) { Remove-Item -LiteralPath $TargetHome -Recurse -Force }
                if (Test-Path -LiteralPath $TargetHome) { $removed = $false }
            } catch { $removed = $false }
            [void](Add-ScenarioProof $proofs 'temp-profiles-removed' ([bool]$removed) 'TargetHome (perfis+fixture) removido')
            Add-EvidenceRecord ([ordered]@{
                objective_id = 'AGENT-MCP-B-LANE'; task_id = 'S8-cleanup-release'; session_id = 'n/a'
                run_id = 'lane-run'; agent_id = 'lane'; profile_id = 'both'; mcp_id = 'n/a'
                tool_id = 'n/a'; invocation_status = 'cleanup'; result_status = 'leaks=' + $leakN + ' stop-failures=' + $stopFailN + ' removed=' + $removed
                timestamp = (Get-LaneTimestampUtc); evidence_source = 'Stop-LaneOwned + Remove-Item TargetHome'
                prompt_sha256 = 'n/a'
            })
            $evPath = Join-Path $script:EvidenceDir 'agent-mcp-evidence.json'
            [void](Write-LaneJson @($script:EvidenceRecords) $evPath)
            [void](Add-ScenarioProof $proofs 'evidence-written' (Test-Path -LiteralPath $evPath -PathType Leaf) ('evidence JSON em EvidenceDir (records=' + @($script:EvidenceRecords).Count + ')'))
            if (($leakN -gt 0) -or ($stopFailN -gt 0) -or ($priorBad -gt 0) -or (-not $removed)) {
                Set-ScenarioResult 'S8' 'fail' ('cleanup incompleto: leaks=' + $leakN + ' stop-failures=' + $stopFailN + ' tentativas-anteriores-com-falha=' + $priorBad + ' removed=' + $removed) $proofs $coverage
            } else {
                Set-ScenarioResult 'S8' 'pass-real' 'fixture+serve owned parados; TEMP profiles removidos; handles pinados encerrados; evidence JSON escrito.' $proofs $coverage
            }
        } catch {
            Set-ScenarioResult 'S8' 'blocked' ('excecao (infra): ' + (Get-LaneSafeText $_.Exception.Message 160)) $proofs $coverage
        }
    }

    # ---------- veredito ----------
    $fails = @($script:ScenarioResults | Where-Object { [string]$_['status'] -ceq 'fail' }).Count
    if ($fails -gt 0) { Write-LaneSummaryAndExit 'failed' ($fails.ToString() + ' cenario(s) fail.') 1 }
    Write-LaneSummaryAndExit 'completed' 'sem fail (apenas pass-real/blocked).' 0
} finally {
    try {
        foreach ($job in @($script:OwnedJobs)) {
            try { [void](Stop-RuntimeJobObject -Job $job) } catch { }
        }
        foreach ($job in @($script:OwnedJobs)) {
            try { [void](Close-RuntimeJobObject -Job $job) } catch { }
        }
    } catch { }
    try {
        if (-not [string]::IsNullOrWhiteSpace($TargetHome) -and (Test-Path -LiteralPath $TargetHome)) {
            Remove-Item -LiteralPath $TargetHome -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch { }
    try {
        if ((-not [bool]$script:SummaryWritten) -and (-not [string]::IsNullOrWhiteSpace($script:EvidenceDir))) {
            $summary = New-LaneSummary -Status 'completed-finally' -Reason 'saida via finally (cleanup executado)'
            [void](Write-LaneJson $summary (Join-Path $script:EvidenceDir 'lane-summary.json'))
        }
    } catch { }
}
