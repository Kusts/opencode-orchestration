<#
.SYNOPSIS
    Mini-harness A/B de propagacao MCP para subagents (runtime V2 vivo).
.DESCRIPTION
    Harness de teste, fora do produto. Decide entre:
      H1: propagacao falha (parent ve MCPs, subagent debugger nao ve);
      H0: propagacao ok (ambos veem).
    Turno A: parent build dumpe discovery direto (servers/tools visiveis).
    Turno B: parent delega ao debugger que dumpe discovery.
    Padrao reutilizado da lane agent-mcp-integration-lane-v2 S1/S2: perfil
    isolado testing (2 MCPs) + serve owned (Job Object) + sessoes via API.
    Sem modelo: -DryRun monta perfil+serve+discovery local e sai.
    Seguranca: segredo do serve so em memoria; sanitizacao total em log e
    evidencia (redige segredos, padroes NOME=valor e URLs); ModelKeyEnvName
    opt-in por NOME apenas (default '' = desligado; turnos sem opt-in vao a
    blocked fail-closed, nunca executam modelo).
    PowerShell 5.1 compativel; ASCII-only.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$EvidenceDir = '',
    [string]$ModelKeyEnvName = '',
    [string]$CheapModel = 'opencode-go/muse-spark-1.3-contributor',
    [string]$StrongModel = 'openai/gpt-6.1-sol',
    [string]$BinaryPath = '',
    [int]$ServeTimeoutSeconds = 60,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'

# ---------- opt-in de model-key (operador; NOME apenas, nunca valor) ----------
$script:ModelKeyEnvNameClean = ''
try {
    $candKeyName = ([string]$ModelKeyEnvName).Trim()
    if (($candKeyName.Length -gt 0) -and ($candKeyName.Length -le 64) -and ($candKeyName -cmatch '^[A-Za-z_][A-Za-z0-9_]*$')) { $script:ModelKeyEnvNameClean = $candKeyName }
    $candKeyName = ''
} catch { $script:ModelKeyEnvNameClean = '' }

# ---------- bootstrap ----------
function Get-ProbeRepoRoot {
    try { return (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) } catch { return (Get-Location).Path }
}
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Get-ProbeRepoRoot }
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
$libDir = Join-Path $RepoRoot 'scripts\runtime\lib'
foreach ($lib in @(
        (Join-Path $libDir 'RuntimeVersions.ps1'),
        (Join-Path $libDir 'SpikeProcess.ps1'),
        (Join-Path $libDir 'RuntimePortPreflight.ps1'),
        (Join-Path $libDir 'RuntimeJobObject.ps1'))) {
    if (-not (Test-Path -LiteralPath $lib -PathType Leaf)) {
        Write-Error ('probe bootstrap: lib ausente: ' + $lib)
        exit 1
    }
    . $lib
}

# ---------- sanitizacao / evidencia ----------
$script:ProbeSanitizeFallback = $false
function Invoke-ProbeRedactRules {
    # Aplica TODAS as regras de redacao sobre UMA forma textual; retorna o
    # texto redigido. Pura (sem trim/max); chamada com a forma original E a
    # canonica desescapada. A regra escapada vem primeiro para nao deixar
    # redacao parcial (sufixo exposto) das regras simples.
    [CmdletBinding()] param([string]$Text = '')
    $v = [string]$Text
    try {
        $rk = '(token|password|passwd|secret|client_secret|api_key|apikey|api-key|access_token|refresh_token|authorization|credentials?|private_key)'
        $patEscVal = '(\\?(?:"|\x27)[^"\\\x27]*(?:\\.[^"\\\x27]*)*\\?(?:"|\x27)|\d+|true|false|null)'
        $patEsc = ('(?i)\\?(?:"|\x27)' + $rk + '\\?(?:"|\x27)\s*:\s*' + $patEscVal)
        $v = $v -replace $patEsc, '[REDACTED]'
        $v = $v -replace '(?i)\bBearer\s+[A-Za-z0-9\-._~+/=]+', 'Bearer [REDACTED]'
        $v = $v -replace '(?i)\bAuthorization\s*:\s*[^\r\n;,]+', 'Authorization: [REDACTED]'
        $patJsonDq = ('(?i)"' + $rk + '"\s*:\s*"[^"]*"')
        $v = $v -replace $patJsonDq, '"$1":"[REDACTED]"'
        $patJsonSq = ("(?i)'" + $rk + "'\s*:\s*'[^']*'")
        $v = $v -replace $patJsonSq, '''$1'':''[REDACTED]'''
        $patJsonBare = ('(?i)"' + $rk + '"\s*:\s*[^\s,;"}\]]+')
        $v = $v -replace $patJsonBare, '"$1":"[REDACTED]"'
        $patKv = ('(?i)\b' + $rk + '((?>\s*)[=:](?>\s*))("[^"]*"|\x27[^\x27]*\x27|[^\s,;"]+)')
        $v = $v -replace $patKv, '$1$2[REDACTED]'
        $v = $v -replace 'sk-[A-Za-z0-9_-]+', '[REDACTED]'
        $v = $v -replace 'sk_[A-Za-z0-9_-]+', '[REDACTED]'
        $v = $v -replace 'ghp_[A-Za-z0-9_-]+', '[REDACTED]'
        $v = $v -replace 'github_pat_[A-Za-z0-9_-]+', '[REDACTED]'
        $v = $v -replace 'xox[baprs]-[A-Za-z0-9-]+', '[REDACTED]'
        $v = $v -replace 'AKIA[0-9A-Z]{16}', '[REDACTED]'
        $v = $v -replace 'AIza[0-9A-Za-z\-_]{30,}', '[REDACTED]'
        try {
            if (-not [string]::IsNullOrWhiteSpace($script:ModelKeyEnvNameClean)) {
                $escKeyName = [regex]::Escape($script:ModelKeyEnvNameClean)
                $v = $v -replace ('(?i)' + $escKeyName + '\s*[=:]\s*[^\s,;"]+'), ($script:ModelKeyEnvNameClean + '=[REDACTED]')
            }
        } catch { }
        $v = $v -replace '(?i)https?://[^\s"]+', '[REDACTED-URL]'
        try {
            $up = [Environment]::GetEnvironmentVariable('USERPROFILE', 'Process')
            if (-not [string]::IsNullOrWhiteSpace($up)) {
                $v = $v -replace [regex]::Escape($up), '[REDACTED-PATH]'
                $v = $v -replace [regex]::Escape(($up -replace '\\', '/')), '[REDACTED-PATH]'
            }
        } catch { }
        $v = $v -replace '(?i)C:\\Users\\[^\\/\s":;,]+', 'C:\Users\[REDACTED]'
        $v = $v -replace '(?i)/home/[^/\s":;,]+', '/home/[REDACTED]'
        $v = $v -replace '(?i)/Users/[^/\s":;,]+', '/Users/[REDACTED]'
    } catch { }
    return $v
}
function Get-ProbeResidualPatterns {
    # Padroes compartilhados de deteccao/nuke de residual sensivel.
    # (a) chave sensivel + valor nao-redigido (forma : e forma =);
    # (b) prefixos de token conhecidos; (c) cauda colada a marcador
    # (redacao parcial: sufixo exposto). Gaps atomicos impedem o \s* de
    # recuar e invalidar o lookahead sobre valor ja redigido.
    $rkf = '(token|password|passwd|secret|client_secret|api_key|apikey|api-key|access_token|refresh_token|authorization|credentials?|private_key)'
    return [ordered]@{
        keys = $rkf
        keyColon = ('(?i)(?>\\?"?)' + $rkf + '(?>\\?"?)(?>\s*):(?>\s*)(?!(?>\\?"?)\[REDACTED)(?>\\?"?[^,;}\]]+)')
        keyEq = ('(?i)\b' + $rkf + '(?>\s*)=(?>\s*)(?!(?>\\?"?)\[REDACTED)("[^"]*"|\x27[^\x27]*\x27|[^\s,;]+)')
        prefixes = @('sk-[A-Za-z0-9_-]+', 'sk_[A-Za-z0-9_-]+', 'ghp_[A-Za-z0-9_-]+', 'github_pat_[A-Za-z0-9_-]+', 'xox[baprs]-[A-Za-z0-9-]+', 'AKIA[0-9A-Z]{16}', 'AIza[0-9A-Za-z\-_]{30,}')
        dangling = '\[REDACTED[^\]]*\][A-Za-z0-9_]'
    }
}
function Test-ProbeSensitiveResidual {
    # Retorna $true se o texto ainda contem (a) chave sensivel seguida de
    # valor que NAO comeca com [REDACTED, (b) prefixo de token conhecido,
    # ou (c) cauda colada a marcador (redacao parcial). Fail-closed: erro
    # presume residual.
    [CmdletBinding()] param([string]$Text = '')
    try {
        $t = [string]$Text
        if ([string]::IsNullOrEmpty($t)) { return $false }
        $rp = Get-ProbeResidualPatterns
        if ($t -match [string]$rp.keyColon) { return $true }
        if ($t -match [string]$rp.keyEq) { return $true }
        foreach ($pp in @([string[]]$rp.prefixes)) {
            try { if ($t -match $pp) { return $true } } catch { return $true }
        }
        if ($t -match [string]$rp.dangling) { return $true }
        return $false
    } catch { return $true }
}
function Get-ProbeSafeText {
    [CmdletBinding()] param($Value, [int]$Max = 200)
    try {
        if ($null -eq $Value) { return '' }
        $orig = [string]$Value
        # Formas candidatas: original + ate 3 desescapes progressivos.
        $forms = New-Object System.Collections.ArrayList
        [void]$forms.Add($orig)
        $cur = $orig
        for ($p = 1; $p -le 3; $p++) {
            $nx = $cur -replace '\\\\', '\'
            $nx = $nx -replace '\\"', '"'
            if ($nx -ceq $cur) { break }
            $cur = $nx
            [void]$forms.Add($cur)
        }
        # TODAS as regras em cada forma; selecao por ausencia de residual
        # (nunca por contagem): canonica limpa > original limpa. Se qualquer
        # forma restante tiver residual, nuke do campo inteiro por
        # [REDACTED-UNSAFE] + sanitize_fallback=true (fail-closed).
        $sanList = New-Object System.Collections.ArrayList
        foreach ($f in @($forms)) { [void]$sanList.Add((Invoke-ProbeRedactRules ([string]$f))) }
        $sanCanon = [string]$sanList[(@($sanList).Count - 1)]
        $sanOrig = [string]$sanList[0]
        if (-not (Test-ProbeSensitiveResidual $sanCanon)) { $v = $sanCanon }
        elseif (-not (Test-ProbeSensitiveResidual $sanOrig)) { $v = $sanOrig }
        else {
            # Fallback: nenhuma forma ficou limpa. ATRIBUI LITERALMENTE o
            # campo inteiro (sem substituicao parcial, que deixaria cauda)
            # e registra sanitize_fallback=true (fail-closed).
            $v = '[REDACTED-UNSAFE]'
            try { $script:ProbeSanitizeFallback = $true } catch { }
        }
        $v = $v -replace '[\x00-\x1f]', ' '
        $v = $v.Trim()
        if ($v.Length -gt $Max) { $v = $v.Substring(0, $Max) }
        return $v
    } catch { return '' }
}
function Write-ProbeJson {
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
function Get-ProbeTimestampUtc { return ([DateTime]::UtcNow.ToString('o')) }
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
        $sha = [Security.Cryptography]::CreateSHA256()
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Text)
            return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
        } finally { $sha.Dispose() }
    } catch { return '' }
}
function Test-ProbeLocalhostUrl([string]$Url) {
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    return ([regex]::IsMatch($Url, '^http://(127\.0\.0\.1|localhost)(:\d+)?(/|$)'))
}
function Get-ProbeModelKeyLogToken {
    if ([string]::IsNullOrWhiteSpace($script:ModelKeyEnvNameClean)) { return 'model-key-env=<unset>' }
    return ('model-key-env=' + $script:ModelKeyEnvNameClean)
}
function Test-ProbeModelKeyAvailable {
    try {
        if ([string]::IsNullOrWhiteSpace($script:ModelKeyEnvNameClean)) { return $false }
        $val = [Environment]::GetEnvironmentVariable($script:ModelKeyEnvNameClean, 'Process')
        return (-not [string]::IsNullOrWhiteSpace($val))
    } catch { return $false }
}

# ---------- estado ----------
$script:ProbeStarted = Get-ProbeTimestampUtc
$script:Checks = New-Object System.Collections.ArrayList
$script:OwnedProcs = New-Object System.Collections.ArrayList
$script:OwnedJobs = New-Object System.Collections.ArrayList
$script:Exe = ''
$script:LiveVersion = ''
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

function Add-ProbeCheck([string]$Name, [bool]$Ok, [string]$Detail) {
    [void]$script:Checks.Add([ordered]@{ check = $Name; ok = [bool]$Ok; detail = (Get-ProbeSafeText $Detail 400) })
}
function Write-ProbeSummary([string]$Status, [string]$Reason, [int]$Code) {
    $summary = [ordered]@{
        probe = 'mcp-subagent-propagation-probe'
        purpose = 'A/B: parent-build discovery direto (A) vs debugger delegado (B); H1=falha de propagacao, H0=propagacao ok'
        date = ([DateTime]::UtcNow.ToString('yyyy-MM-dd'))
        started_at = $script:ProbeStarted
        finished_at = (Get-ProbeTimestampUtc)
        status = $Status
        reason = (Get-ProbeSafeText $Reason 400)
        runtime_live = $script:LiveVersion
        model_key_env = (Get-ProbeModelKeyLogToken)
        dry_run = [bool]$DryRun
        sanitize_fallback = [bool]$script:ProbeSanitizeFallback
        checks = @($script:Checks)
        verdict = $script:Verdict
        turns = $script:TurnEvidence
    }
    [void](Write-ProbeJson $summary (Join-Path $script:EvidenceDir 'probe-summary.json'))
    $script:SummaryWritten = $true
    Write-Host ('[mcp-probe] ' + $Status + ': ' + (Get-ProbeSafeText $Reason 200))
    exit $Code
}

# ---------- dirs ----------
$tempRoot = [IO.Path]::GetTempPath()
if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $tempRoot = $env:RUNNER_TEMP }
$TargetHome = Join-Path $tempRoot ('oo-mcpprobe-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
if (Test-Path -LiteralPath $TargetHome) { Write-Error ('TargetHome ja existe: ' + $TargetHome); exit 1 }
if ([string]::IsNullOrWhiteSpace($EvidenceDir)) { $EvidenceDir = Join-Path $RepoRoot 'evidence\mcp-subagent-propagation' }
$script:EvidenceDir = $EvidenceDir
try {
    New-Item -ItemType Directory -Path $TargetHome -Force | Out-Null
    New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
} catch { Write-Error ('falha ao criar dirs: ' + $_.Exception.Message); exit 1 }

function New-ProbeProfile([string]$ProfileId) {
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
    $npmCache = Join-Path $root 'npm-cache'
    try { if (-not (Test-Path -LiteralPath $npmCache -PathType Container)) { New-Item -ItemType Directory -Path $npmCache -Force | Out-Null } } catch { }
    $laneTmp = Join-Path $TargetHome 'probe-tmp'
    try { if (-not (Test-Path -LiteralPath $laneTmp -PathType Container)) { New-Item -ItemType Directory -Path $laneTmp -Force | Out-Null } } catch { }
    $npmRcBlank = Join-Path $root 'npmrc-blank'
    try { if (-not (Test-Path -LiteralPath $npmRcBlank -PathType Leaf)) { [IO.File]::WriteAllText($npmRcBlank, "# probe-owned blank npmrc`n", (New-Object Text.UTF8Encoding $false)) } } catch { }
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
        id = $ProfileId
        root = $root
        xdg = $xdg
        home = $profHome
        cwd = $cwd
        db = $dbPath
        cfg_path = (Join-Path $xdg 'opencode\opencode.json')
        env = $servePwEnv
        tmp = $laneTmp
        auth_store = $false
    }
}

function Start-ProbeOwnedProcess {
    [CmdletBinding()] param([string]$FilePath = '', [string[]]$ArgumentList = @(), $EnvTable = $null, [string[]]$EnvRemove = @(), [string]$WorkDir = '')
    $res = [ordered]@{ ok = $false; reason = ''; proc = $null; job = $null }
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
        try { $psi.EnvironmentVariables.Clear() } catch { }
        foreach ($kn in @('PATH', 'SystemRoot', 'WINDIR', 'ComSpec', 'PATHEXT', 'TEMP', 'TMP', 'PSModulePath', 'SystemDrive', 'ProgramFiles', 'ProgramFiles(x86)', 'LOCALAPPDATA', 'APPDATA')) {
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
        try {
            if (-not [string]::IsNullOrWhiteSpace($TargetHome)) {
                $laneTmpOwned = Join-Path $TargetHome 'probe-tmp'
                if (-not (Test-Path -LiteralPath $laneTmpOwned -PathType Container)) { New-Item -ItemType Directory -Path $laneTmpOwned -Force | Out-Null }
                $psi.EnvironmentVariables['TEMP'] = $laneTmpOwned
                $psi.EnvironmentVariables['TMP'] = $laneTmpOwned
            }
        } catch { }
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
        $res.reason = (Get-ProbeSafeText $_.Exception.Message 160)
        return $res
    }
}
function Wait-ProbeListener([int]$Port, [int]$DeadlineSeconds) {
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
function Stop-ProbeOwned([string]$Why) {
    # Fail-closed: propaga Ok/Settled de Stop e Close; qualquer estado
    # desconhecido/incerto (nulo, excecao, Refresh/HasExited sem leitura)
    # marca unknown e derruba ok. Sem descarte silencioso.
    $res = [ordered]@{ leaks = @(); stopFailures = @(); closeFailures = @(); unknown = @(); ok = $false; settled = $false; why = $Why }
    try {
        foreach ($job in @($script:OwnedJobs)) {
            try {
                $sr = Stop-RuntimeJobObject -Job $job
                if ($null -eq $sr) { $res.stopFailures += 'job-stop-null'; $res.unknown += 'job-stop-null' }
                elseif (-not [bool]$sr.Ok) { $res.stopFailures += 'job-stop-fail'; $res.unknown += 'job-stop-unproven' }
                elseif (-not [bool]$sr.Settled) { $res.stopFailures += 'job-stop-unsettled' }
            } catch { $res.stopFailures += 'job-stop-throw'; $res.unknown += 'job-stop-throw' }
        }
        Start-Sleep -Milliseconds 500
        try { [void](Wait-ProbeOwnedExit 30) } catch { $res.unknown += 'wait-exit-unknown' }
        foreach ($job in @($script:OwnedJobs)) {
            try {
                $cr = Close-RuntimeJobObject -Job $job
                if (($null -eq $cr) -or (-not [bool]$cr.Ok)) { $res.closeFailures += 'job-close-fail' }
            } catch { $res.closeFailures += 'job-close-throw'; $res.unknown += 'job-close-throw' }
        }
        foreach ($p in @($script:OwnedProcs)) {
            try {
                $p.Refresh()
                if (-not [bool]$p.HasExited) { $res.leaks += $p.Id }
            } catch { $res.unknown += 'proc-state-unknown' }
        }
    } catch { $res.unknown += 'stop-owned-throw' }
    try { $script:OwnedJobs.Clear() } catch { }
    try { $script:OwnedProcs.Clear() } catch { }
    $res.settled = (((@($res.leaks).Count -eq 0) -and ((@($res.unknown).Count -eq 0))))
    $res.ok = (((@($res.stopFailures).Count -eq 0) -and ((@($res.closeFailures).Count -eq 0)) -and [bool]$res.settled))
    return $res
}
function Wait-ProbeOwnedExit([int]$DeadlineSeconds = 30) {
    $leaks = @()
    try {
        if ($DeadlineSeconds -lt 1) { $DeadlineSeconds = 1 }
        if ($DeadlineSeconds -gt 120) { $DeadlineSeconds = 120 }
        $deadline = [DateTime]::UtcNow.AddSeconds($DeadlineSeconds)
        do {
            $leaks = @()
            foreach ($p in @($script:OwnedProcs)) {
                try {
                    $p.Refresh()
                    if (-not [bool]$p.HasExited) { $leaks += $p.Id }
                } catch { }
            }
            if (@($leaks).Count -eq 0) { break }
            Start-Sleep -Milliseconds 500
        } while ([DateTime]::UtcNow -lt $deadline)
    } catch { }
    return @($leaks)
}
$script:ProbeSensitiveLeafNames = @('auth.json', 'account.json', 'kv.json', 'model.json', 'service.json', 'copycreds.py')
function Remove-ProbeTargetHome([int]$Retries = 5) {
    try {
        if ([string]::IsNullOrWhiteSpace($TargetHome)) { return $true }
        if (-not (Test-Path -LiteralPath $TargetHome)) { return $true }
        if ($Retries -lt 1) { $Retries = 1 }
        if ($Retries -gt 10) { $Retries = 10 }
        for ($i = 1; $i -le $Retries; $i++) {
            try { Remove-Item -LiteralPath $TargetHome -Recurse -Force -ErrorAction SilentlyContinue } catch { }
            try {
                if (-not (Test-Path -LiteralPath $TargetHome)) { return $true }
            } catch { }
            Start-Sleep -Milliseconds 1000
        }
        try { return (-not (Test-Path -LiteralPath $TargetHome)) } catch { return $false }
    } catch { return $false }
}
function Get-ProbeSensitiveResidue {
    $residue = New-Object System.Collections.ArrayList
    try {
        if ([string]::IsNullOrWhiteSpace($TargetHome)) { return @() }
        if (-not (Test-Path -LiteralPath $TargetHome)) { return @() }
        try {
            $items = Get-ChildItem -LiteralPath $TargetHome -Recurse -Force -ErrorAction SilentlyContinue
        } catch { $items = @() }
        foreach ($it in @($items)) {
            try {
                $leaf = [string]$it.Name
                if ([string]::IsNullOrWhiteSpace($leaf)) { continue }
                $low = $leaf.ToLowerInvariant()
                $hit = $false
                foreach ($sn in @($script:ProbeSensitiveLeafNames)) {
                    if ($low -ceq ([string]$sn).ToLowerInvariant()) { $hit = $true; break }
                }
                if (-not $hit) {
                    try {
                        if ($low.EndsWith('.db')) { $hit = $true }
                    } catch { }
                }
                if ([bool]$hit) {
                    $safeLeaf = (Get-ProbeSafeText $leaf 80)
                    if ([string]::IsNullOrWhiteSpace($safeLeaf)) { $safeLeaf = 'unreadable-name' }
                    if (-not ($residue -contains $safeLeaf)) { [void]$residue.Add($safeLeaf) }
                }
                if (@($residue).Count -ge 20) { break }
            } catch { }
        }
        if ((@($residue).Count -eq 0)) {
            [void]$residue.Add('TargetHome-present')
        }
    } catch {
        return @('TargetHome-present')
    }
    return @($residue)
}
function Test-ProbeMcpOperational([string]$Text, [string[]]$WantNames) {
    # Prova operacional por MCP a partir do GET /api/mcp parseado: exige
    # nome em campo de nome (name/id/server/label/key ou chave de mapa) +
    # estado conectado + sem erro/disabled. Nome em texto livre (ex. msg de
    # erro) nao conta; resposta nao-JSON = nada operacional (fail-closed).
    # Sem rede, sem log. PowerShell 5.1 compativel, ASCII-only.
    $res = [ordered]@{ ok = $false; found = @(); missing = @($WantNames); degraded = @() }
    try {
        if ($null -eq $WantNames) { $WantNames = @() }
        $want = @($WantNames | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if (@($want).Count -eq 0) { $res.ok = $true; $res.missing = @(); return $res }
        if ([string]::IsNullOrWhiteSpace($Text)) { return $res }
        $pj = $null
        try { $pj = ConvertFrom-Json ([string]$Text) -ErrorAction SilentlyContinue } catch { $pj = $null }
        if ($null -eq $pj) { return $res }
        $pairs = New-Object System.Collections.ArrayList
        $stack = New-Object System.Collections.ArrayList
        [void]$stack.Add($pj)
        $guard = 0
        while ((@($stack).Count -gt 0) -and ($guard -lt 2000)) {
            $guard += 1
            $top = @($stack).Count - 1
            $o = $stack[$top]
            $stack.RemoveAt($top)
            if ($null -eq $o) { continue }
            if ($o -is [string]) { continue }
            if (($o -is [System.Collections.IEnumerable]) -and ($o -isnot [System.Collections.IDictionary])) {
                foreach ($e in @($o)) {
                    if ($null -eq $e) { continue }
                    if ($e -is [string]) { continue }
                    [void]$stack.Add($e)
                }
                continue
            }
            if ($o -is [System.Collections.IDictionary]) {
                foreach ($k in @($o.Keys)) {
                    try {
                        $v = $o[$k]
                        $ks = [string]$k
                        foreach ($wn in @($want)) {
                            if ($ks -ieq [string]$wn) {
                                if (($null -ne $v) -and ($v -isnot [string])) { [void]$pairs.Add([ordered]@{ name = [string]$wn; obj = $v }) }
                            }
                        }
                        if (($null -ne $v) -and ($v -isnot [string])) { [void]$stack.Add($v) }
                    } catch { }
                }
            } else {
                try {
                    foreach ($pr in @($o.PSObject.Properties)) {
                        try {
                            $pn = [string]$pr.Name
                            $pv = $pr.Value
                            foreach ($wn in @($want)) {
                                if ($pn -ieq [string]$wn) {
                                    if (($null -ne $pv) -and ($pv -isnot [string])) { [void]$pairs.Add([ordered]@{ name = [string]$wn; obj = $pv }) }
                                }
                            }
                            if (($null -ne $pv) -and ($pv -isnot [string])) { [void]$stack.Add($pv) }
                        } catch { }
                    }
                } catch { }
            }
            foreach ($fn in @('name', 'id', 'server', 'label', 'key')) {
                try {
                    $fv = [string](Get-JsonProp $o $fn '')
                    if (-not [string]::IsNullOrWhiteSpace($fv)) {
                        foreach ($wn in @($want)) {
                            if (($fv -ieq [string]$wn) -or ($fv -match ('(?i)' + [regex]::Escape([string]$wn)))) {
                                [void]$pairs.Add([ordered]@{ name = [string]$wn; obj = $o })
                                break
                            }
                        }
                    }
                } catch { }
            }
        }
        $allowStatus = @('connected', 'ready', 'ok', 'running', 'enabled', 'active', 'available', 'healthy', 'success', 'completed', 'alive', 'up')
        $found = New-Object System.Collections.ArrayList
        $degraded = New-Object System.Collections.ArrayList
        foreach ($wn in @($want)) {
            $cands = @($pairs | Where-Object { [string]$_.name -ieq [string]$wn })
            $isUp = $false
            $seen = $false
            foreach ($cp in @($cands)) {
                $so = $null
                try { $so = $cp.obj } catch { $so = $null }
                if ($null -eq $so) { continue }
                if ($so -is [string]) { continue }
                $seen = $true
                $bad = $false
                $good = $false
                try {
                    $dv = Get-JsonProp $so 'disabled' $null
                    if ($null -ne $dv) {
                        $db = $false
                        try { $db = [bool]$dv } catch { $db = $false }
                        if ([bool]$db) { $bad = $true }
                    }
                } catch { }
                try {
                    $cv = Get-JsonProp $so 'connected' $null
                    if ($null -ne $cv) {
                        $cb = $false
                        try { $cb = [bool]$cv } catch { $cb = $false }
                        if ([bool]$cb) { $good = $true } else { $bad = $true }
                    }
                } catch { }
                $stText = ''
                try {
                    $sv = Get-JsonProp $so 'status' $null
                    if ($sv -is [string]) { $stText = [string]$sv }
                    elseif ($null -ne $sv) {
                        $st2 = [string](Get-JsonProp $sv 'status' '')
                        if (-not [string]::IsNullOrWhiteSpace($st2)) { $stText = $st2 }
                    }
                    if ([string]::IsNullOrWhiteSpace($stText)) {
                        $stv = Get-JsonProp $so 'state' $null
                        if ($stv -is [string]) { $stText = [string]$stv }
                        elseif ($null -ne $stv) {
                            $st3 = [string](Get-JsonProp $stv 'status' '')
                            if (-not [string]::IsNullOrWhiteSpace($st3)) { $stText = $st3 }
                        }
                    }
                    if ([string]::IsNullOrWhiteSpace($stText)) {
                        $cnv = Get-JsonProp $so 'connection' (Get-JsonProp $so 'connectionState' $null)
                        if (($cnv -is [string]) -and (-not [string]::IsNullOrWhiteSpace([string]$cnv))) { $stText = [string]$cnv }
                    }
                } catch { }
                if (-not [string]::IsNullOrWhiteSpace($stText)) {
                    $low = ([string]$stText).Trim().ToLowerInvariant()
                    if ($allowStatus -contains $low) { $good = $true } else { $bad = $true }
                }
                $errHolders = @($so)
                try {
                    $stObj = Get-JsonProp $so 'status' $null
                    if (($null -ne $stObj) -and ($stObj -isnot [string])) { $errHolders += $stObj }
                } catch { }
                try {
                    $seObj = Get-JsonProp $so 'state' $null
                    if (($null -ne $seObj) -and ($seObj -isnot [string])) { $errHolders += $seObj }
                } catch { }
                foreach ($holder in @($errHolders)) {
                    foreach ($ef in @('error', 'lastError', 'errorMessage')) {
                        try {
                            $evv = Get-JsonProp $holder $ef $null
                            if ($evv -is [string]) {
                                if (-not [string]::IsNullOrWhiteSpace([string]$evv)) { $bad = $true }
                            } elseif ($null -ne $evv) { $bad = $true }
                        } catch { }
                    }
                }
                if ($bad) { continue }
                if ($good) { $isUp = $true; break }
                # Sem estado positivo explicito (connected/status allowlist):
                # NAO assume operacional (fail-closed). Nome sem conexao
                # conta como degradado e bloqueia a jusante.
            }
            if ($isUp) { [void]$found.Add($wn) }
            elseif ($seen) { [void]$degraded.Add($wn) }
        }
        $miss = New-Object System.Collections.ArrayList
        foreach ($wn in @($want)) { if (-not ($found -contains $wn)) { [void]$miss.Add($wn) } }
        $res.found = @($found)
        $res.degraded = @($degraded)
        $res.missing = @($miss)
        $res.ok = ((@($miss).Count -eq 0))
        return $res
    } catch { }
    return $res
}
function Wait-ProbeMcpNames([string]$ServeUrl, $ApiEnv, [string[]]$ApiRemove, [string]$WorkDir, [string[]]$WantNames, [int]$DeadlineSeconds) {
    $res = [ordered]@{ text = ''; found = @(); missing = @($WantNames); degraded = @(); elapsed_ms = 0; queries = 0 }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        while ($sw.Elapsed.TotalSeconds -lt $DeadlineSeconds) {
            $ar = Invoke-PreflightBoundedExe -File $script:Exe -ArgsLine ('api --server ' + $ServeUrl + ' GET /api/mcp') -WorkDir $WorkDir -EnvTable $ApiEnv -EnvRemove $ApiRemove -TimeoutMs 30000 -MaxChars 65536
            $res.queries = [int]$res.queries + 1
            if ([bool]$ar.Finished -and ([int]$ar.ExitCode -eq 0)) {
                $t = [string]$ar.Output
                $res.text = $t
                $eval = Test-ProbeMcpOperational $t $WantNames
                $res.found = @($eval.found)
                $res.missing = @($eval.missing)
                $res.degraded = @($eval.degraded)
                if (@($res.missing).Count -eq 0) { break }
            }
            Start-Sleep -Milliseconds 5000
        }
    } catch { }
    $sw.Stop()
    $res.elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
    return $res
}
function Add-ProbeServeAuth($EnvTable) {
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
function Import-ProbeProfileCredentials($Profile) {
    try {
        if ($null -eq $Profile) { return $false }
        if (-not (Test-ProbeModelKeyAvailable)) { return $false }
        $root = [string]$Profile.root
        if ([string]::IsNullOrWhiteSpace($root)) { return $false }
        if (-not $root.StartsWith($TargetHome, [StringComparison]::OrdinalIgnoreCase)) { return $false }
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
function Copy-ProbeCredentials([string]$DstDb) {
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
        if ([int]$c.ExitCode -ne 0) { $res.reason = ('helper exit=' + [int]$c.ExitCode + ' ' + (Get-ProbeSafeText $o 120)); return $res }
        $m = [regex]::Match($o, 'ROWS=(\d+)')
        if (-not $m.Success) { $res.reason = 'helper sem contagem (infra)'; return $res }
        $res.ok = $true
        $res.rows = [int]$m.Groups[1].Value
        $res.reason = 'credential copiada (contagem apenas)'
        return $res
    } catch { $res.reason = (Get-ProbeSafeText $_.Exception.Message 120); return $res }
}
function Restart-ProbeServeAfterCredentials {
    [CmdletBinding()] param($OldServe = $null, [string]$FilePath = '', [string[]]$ArgumentList = @(), $EnvTable = $null, [string[]]$EnvRemove = @(), [string]$WorkDir = '', [int]$Port = 0, [int]$TimeoutSeconds = 60)
    $res = [ordered]@{ ok = $false; reason = ''; serve = $null }
    try {
        if ($null -eq $OldServe) { $res.reason = 'serve restart: OldServe ausente (fail-closed antes do start)'; return $res }
        $oldJob = $null
        $oldProc = $null
        try { $oldJob = $OldServe.job } catch { $oldJob = $null }
        try { $oldProc = $OldServe.proc } catch { $oldProc = $null }
        if ($null -eq $oldJob) { $res.reason = 'serve restart: OldServe sem job (fail-closed antes do start)'; return $res }
        if ($null -eq $oldProc) { $res.reason = 'serve restart: OldServe sem proc (fail-closed antes do start)'; return $res }
        $sr = $null
        try { $sr = Stop-RuntimeJobObject -Job $oldJob } catch { $sr = $null }
        if (($null -eq $sr) -or (-not [bool]$sr.Ok)) { $res.reason = 'serve restart: stop do processo antigo sem confirmacao (fail-closed antes do start)'; return $res }
        $oldExited = $false
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while ([DateTime]::UtcNow -lt $deadline) {
                try { $oldProc.Refresh() } catch { break }
                if ([bool]$oldProc.HasExited) { $oldExited = $true; break }
                Start-Sleep -Milliseconds 500
            }
        } catch { $oldExited = $false }
        if (-not [bool]$oldExited) { $res.reason = 'serve restart: processo antigo nao confirmou saida (fail-closed antes do start)'; return $res }
        $re = Start-ProbeOwnedProcess -FilePath $FilePath -ArgumentList $ArgumentList -EnvTable $EnvTable -EnvRemove $EnvRemove -WorkDir $WorkDir
        if (-not [bool]$re.ok) { $res.reason = ('serve restart nao iniciou: ' + $re.reason); return $res }
        $newAlive = $false
        try {
            if ($null -ne $re.proc) {
                try { $re.proc.Refresh() } catch { }
                if (-not [bool]$re.proc.HasExited) { $newAlive = $true }
            }
        } catch { $newAlive = $false }
        if (-not [bool]$newAlive) {
            try { if ($null -ne $re.job) { [void](Stop-RuntimeJobObject -Job $re.job) } } catch { }
            $res.reason = 'serve restart: novo processo nao esta vivo (fail-closed)'
            return $res
        }
        if (-not (Wait-ProbeListener -Port $Port -DeadlineSeconds $TimeoutSeconds)) {
            try { if ($null -ne $re.job) { [void](Stop-RuntimeJobObject -Job $re.job) } } catch { }
            $res.reason = 'serve restart sem listener (infra)'
            return $res
        }
        $newPid = 0
        try { $newPid = [int]$re.proc.Id } catch { $newPid = 0 }
        $lnPid = 0
        $lnProven = $false
        try {
            $ln = Get-PreflightNetTCPListenerBounded -Port $Port -TimeoutMs 4000
            if (($null -ne $ln) -and [bool]$ln.QuerySucceeded -and [bool]$ln.Exists) {
                $lnPid = [int]$ln.OwningPID
                $lnProven = $true
            }
        } catch { $lnProven = $false }
        if ((-not [bool]$lnProven) -or ($newPid -le 0) -or ($lnPid -ne $newPid)) {
            try { if ($null -ne $re.job) { [void](Stop-RuntimeJobObject -Job $re.job) } } catch { }
            $res.reason = ('serve restart: listener nao atribuivel ao novo processo (pid novo=' + $newPid + ' pid listener=' + $lnPid + ')')
            return $res
        }
        $res.ok = $true
        $res.serve = $re
        $res.reason = 'serve restart ok (pos-credential)'
        return $res
    } catch { $res.reason = (Get-ProbeSafeText $_.Exception.Message 160); return $res }
}
function New-ProbeApiSession([string]$ServerUrl, $EnvTable, [string]$Cwd) {
    try {
        if (-not (Test-ProbeLocalhostUrl $ServerUrl)) { return [ordered]@{ ok = $false; reason = 'URL fora de localhost (guard)'; id = '' } }
        $authN = Add-ProbeServeAuth $EnvTable
        $r = Invoke-PreflightBoundedExe -File $script:Exe -ArgsLine ('api --server ' + $ServerUrl + ' POST /api/session --data "{}"') -WorkDir $Cwd -EnvTable $authN.env -EnvRemove $script:ApiRemove -TimeoutMs 30000 -MaxChars 65536
        if ((-not [bool]$r.Finished) -or ([int]$r.ExitCode -ne 0)) { return [ordered]@{ ok = $false; reason = ('post-failed:exit=' + [int]$r.ExitCode + ' serve-auth-ok=' + [bool]$authN.hasPassword); id = '' } }
        $j = $null
        try { $j = ConvertFrom-Json ([string]$r.Output) } catch { $j = $null }
        $node = Get-JsonProp $j 'data' $j
        $sid = [string](Get-JsonProp $node 'id' '')
        if ([string]::IsNullOrWhiteSpace($sid)) { return [ordered]@{ ok = $false; reason = 'sem id na resposta'; id = '' } }
        return [ordered]@{ ok = $true; reason = ''; id = $sid }
    } catch { return [ordered]@{ ok = $false; reason = (Get-ProbeSafeText $_.Exception.Message 120); id = '' } }
}
function Invoke-ProbeModelRun {
    [CmdletBinding()] param([string]$ServerUrl = '', [string]$SessionId = '', [string]$Model = '', [string]$Agent = '', [string]$Prompt = '')
    $res = [ordered]@{ attempted = $false; ok = $false; exit = -1; timedout = $false; out = ''; out_stdout = ''; out_stderr = ''; job_assigned = $false; reason = '' }
    try {
        if (-not (Test-ProbeModelKeyAvailable)) { $res.reason = 'model-key indisponivel (fail-closed)'; return $res }
        if (-not (Test-ProbeLocalhostUrl $ServerUrl)) { $res.reason = 'URL fora de localhost (guard)'; return $res }
        $safePrompt = (([string]$Prompt) -replace '[&|<>\^%!"''();$`\{\}\[\]\r\n]', '-').Trim()
        if ([string]::IsNullOrWhiteSpace($safePrompt)) { $safePrompt = 'probe-discovery' }
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
        $modelEnv = @{}
        try { foreach ($k in @($profTesting.env.Keys)) { $modelEnv[[string]$k] = [string]$profTesting.env[$k] } } catch { }
        try {
            $modelEnv[$script:ModelKeyEnvNameClean] = [Environment]::GetEnvironmentVariable($script:ModelKeyEnvNameClean, 'Process')
        } catch { }
        $modelAuth = Add-ProbeServeAuth $modelEnv
        if (-not [bool]$modelAuth.hasPassword) { $res.reason = 'serve sem segredo legivel (auth fail-closed)'; return $res }
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
        $res.out_stdout = [string]$r.Stdout
        $res.out_stderr = [string]$r.Stderr
        $res.out = ([string]$r.Stdout + "`n" + [string]$r.Stderr)
        $res.ok = ((-not [bool]$r.TimedOut) -and ([int]$r.ExitCode -eq 0) -and ([bool]$r.JobAssigned))
        return $res
    } catch {
        $res.reason = (Get-ProbeSafeText $_.Exception.Message 160)
        return $res
    }
}
# Prova de ANEXACAO real (nao mencao): conta registros de tool com nome e
# status em dois formatos: (a) linhas normalizadas 'TOOL name=X status=Y'
# (padrao Get-LaneChildTranscript, uma por linha, fronteira de registro);
# (b) objetos JSON parseados com type=tool/tool_use (turn stdout
# --format json). Citacao textual (incl. JSON escapado \"...\") nunca
# parseia como objeto top-level e nao conta. Exit 0 sem registro em
# (a)/(b) conta 0 e nada prova.
function Get-ProbeJsonCandidates([string]$Text) {
    # Recorta objetos/arrays JSON top-level do texto respeitando strings e
    # escapes (JSON escapado \"...\" em prosa nao forma objeto valido e cai
    # no parse). Sem rede, sem log. PowerShell 5.1 compativel, ASCII-only.
    $out = New-Object System.Collections.ArrayList
    try {
        if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
        $t = [string]$Text
        $n = $t.Length
        $i = 0
        while ($i -lt $n) {
            $c = $t[$i]
            if (($c -eq '{') -or ($c -eq '[')) {
                $depth = 0
                $inStr = $false
                $esc = $false
                $j = $i
                $ok = $false
                while ($j -lt $n) {
                    $d = $t[$j]
                    if ($inStr) {
                        if ($esc) { $esc = $false }
                        elseif ($d -eq '\') { $esc = $true }
                        elseif ($d -eq '"') { $inStr = $false }
                    } else {
                        if ($d -eq '"') { $inStr = $true }
                        elseif (($d -eq '{') -or ($d -eq '[')) { $depth += 1 }
                        elseif (($d -eq '}') -or ($d -eq ']')) {
                            $depth -= 1
                            if ($depth -le 0) { $ok = $true; break }
                        }
                    }
                    $j += 1
                    if (($j - $i) -gt 131072) { $ok = $false; break }
                }
                if ($ok) {
                    $cand = $t.Substring($i, ($j - $i + 1))
                    if ($cand.Length -ge 8) {
                        if (@($out).Count -ge 200) { break }
                        [void]$out.Add($cand)
                    }
                    $i = $j + 1
                    continue
                }
            }
            $i += 1
        }
    } catch { }
    return @($out)
}
function Add-ProbeToolRecordsFromObject($Node, $Names, $Lines) {
    # Caminha objeto JSON ja parseado e registra SOMENTE type=tool /
    # type=tool_use com nome. Strings nunca sao re-parseadas, por isso
    # citacao em texto nao conta. $Names/$Lines sao ArrayLists.
    try {
        if ($null -eq $Node) { return }
        if ($null -eq $Names) { return }
        if ($null -eq $Lines) { return }
        $stack = New-Object System.Collections.ArrayList
        [void]$stack.Add($Node)
        $guard = 0
        while ((@($stack).Count -gt 0) -and ($guard -lt 2000)) {
            $guard += 1
            if (@($Names).Count -ge 200) { break }
            $top = @($stack).Count - 1
            $o = $stack[$top]
            $stack.RemoveAt($top)
            if ($null -eq $o) { continue }
            if ($o -is [string]) { continue }
            if (($o -is [System.Collections.IEnumerable]) -and ($o -isnot [System.Collections.IDictionary])) {
                foreach ($e in @($o)) {
                    if ($null -eq $e) { continue }
                    if ($e -is [string]) { continue }
                    [void]$stack.Add($e)
                }
                continue
            }
            $tp = [string](Get-JsonProp $o 'type' '')
            if (($tp -ceq 'tool') -or ($tp -ceq 'tool_use')) {
                $nm = [string](Get-JsonProp $o 'name' '')
                if ([string]::IsNullOrWhiteSpace($nm)) { $nm = [string](Get-JsonProp $o 'tool' '') }
                $st = 'unknown'
                try {
                    $state = Get-JsonProp $o 'state' $null
                    if ($null -ne $state) {
                        $s2 = [string](Get-JsonProp $state 'status' '')
                        if (-not [string]::IsNullOrWhiteSpace($s2)) { $st = $s2 }
                    }
                } catch { }
                if (($st -ceq 'unknown') -or [string]::IsNullOrWhiteSpace($st)) {
                    $s3 = [string](Get-JsonProp $o 'status' '')
                    if (-not [string]::IsNullOrWhiteSpace($s3)) { $st = $s3 }
                }
                if ((-not [string]::IsNullOrWhiteSpace($nm)) -and ($nm -cmatch '^[A-Za-z0-9_.\-]+$')) {
                    $sClean = 'unknown'
                    if ($st -cmatch '^[A-Za-z0-9_.\-]+$') { $sClean = $st }
                    [void]$Names.Add(($nm + '/' + $sClean))
                    [void]$Lines.Add(($nm + ' ' + $sClean))
                }
            }
            try {
                if ($o -is [System.Collections.IDictionary]) {
                    foreach ($v in @($o.Values)) {
                        if ($null -eq $v) { continue }
                        if ($v -is [string]) { continue }
                        [void]$stack.Add($v)
                    }
                } else {
                    foreach ($pr in @($o.PSObject.Properties)) {
                        try {
                            $v = $pr.Value
                            if ($null -eq $v) { continue }
                            if ($v -is [string]) { continue }
                            [void]$stack.Add($v)
                        } catch { }
                    }
                }
            } catch { }
        }
    } catch { }
}
function Get-ProbeToolEvidence([string]$Text) {
    $names = New-Object System.Collections.ArrayList
    $lines = New-Object System.Collections.ArrayList
    try {
        if ([string]::IsNullOrWhiteSpace($Text)) {
            return [ordered]@{ count = 0; names = @(); lines = @() }
        }
        foreach ($line in ([string]$Text -split "`r?`n")) {
            try {
                $head = [string]$line
                $ix = $head.IndexOf(' out=[')
                if ($ix -ge 0) { $head = $head.Substring(0, $ix) }
                $m = [regex]::Match($head, '(?im)^\s*TOOL name=([A-Za-z0-9_.\-]+) status=([A-Za-z0-9_.\-]*)')
                if ([bool]$m.Success) {
                    $mstat = [string]$m.Groups[2].Value
                    if ([string]::IsNullOrWhiteSpace($mstat)) { $mstat = 'unknown' }
                    [void]$names.Add(($m.Groups[1].Value + '/' + $mstat))
                    [void]$lines.Add(($m.Groups[1].Value + ' ' + $mstat))
                }
            } catch { }
        }
        try {
            foreach ($cand in @(Get-ProbeJsonCandidates ([string]$Text))) {
                $pj = $null
                try { $pj = ConvertFrom-Json $cand -ErrorAction SilentlyContinue } catch { $pj = $null }
                if ($null -eq $pj) { continue }
                try { Add-ProbeToolRecordsFromObject $pj $names $lines } catch { }
                if (@($names).Count -ge 200) { break }
            }
        } catch { }
    } catch { }
    return [ordered]@{ count = @($names).Count; names = @($names); lines = @($lines) }
}
function Convert-ProbeMessageJsonToToolText([string]$RawJson) {
    # Converte GET /api/session/:id/message em linhas TOOL normalizadas
    # (mesmo padrao do Get-LaneChildTranscript da lane). Sem rede, sem log.
    $ev = New-Object System.Collections.ArrayList
    try {
        if ([string]::IsNullOrWhiteSpace($RawJson)) { return '' }
        $mj = $null
        try { $mj = ConvertFrom-Json ([string]$RawJson) } catch { return '' }
        $rows = Get-JsonProp $mj 'data' $null
        if ($null -eq $rows) { $rows = @($mj) }
        foreach ($m in @($rows)) {
            try {
                foreach ($it in @(Get-JsonProp $m 'content' $null)) {
                    try {
                        $tp = [string](Get-JsonProp $it 'type' '')
                        if ($tp -ceq 'tool') {
                            $nm = [string](Get-JsonProp $it 'name' (Get-JsonProp $it 'tool' ''))
                            $st = [string](Get-JsonProp (Get-JsonProp $it 'state' $null) 'status' '')
                            if ([string]::IsNullOrWhiteSpace($st)) { $st = 'unknown' }
                            $ot = ''
                            try {
                                $tx = @()
                                foreach ($c in @(Get-JsonProp $it 'content' $null)) { $tx += [string](Get-JsonProp $c 'text' '') }
                                $ot = ($tx -join ' ').Trim()
                            } catch { }
                            if ($ot.Length -gt 300) { $ot = $ot.Substring(0, 300) }
                            [void]$ev.Add(('TOOL name=' + $nm + ' status=' + $st + ' out=[' + $ot + ']'))
                        }
                    } catch { }
                }
            } catch { }
        }
    } catch { }
    return ($ev -join "`n")
}
function Get-ProbeSessionMessageToolEvidence {
    # Prova por turno independente do modelo: le o transcript pos-turno via
    # GET /api/session/:id/message e conta registros type=tool.
    [CmdletBinding()] param([string]$ServeUrl = '', $ApiEnv = $null, [string[]]$ApiRemove = @(), [string]$WorkDir = '', [string]$SessionId = '')
    $res = [ordered]@{ ok = $false; parse_ok = $false; count = 0; names = @(); head = ''; reason = '' }
    try {
        if ([string]::IsNullOrWhiteSpace($SessionId)) { $res.reason = 'session vazia'; return $res }
        if (-not (Test-ProbeLocalhostUrl $ServeUrl)) { $res.reason = 'URL fora de localhost (guard)'; return $res }
        $mr = Invoke-PreflightBoundedExe -File $script:Exe -ArgsLine ('api --server ' + $ServeUrl + ' GET /api/session/' + $SessionId + '/message') -WorkDir $WorkDir -EnvTable $ApiEnv -EnvRemove $ApiRemove -TimeoutMs 30000 -MaxChars 524288
        if ((-not [bool]$mr.Finished) -or ([int]$mr.ExitCode -ne 0)) { $res.reason = 'GET message falhou'; return $res }
        # msg.ok so vale com transcript VALIDO e COMPLETO: GET exit 0 com
        # JSON invalido/truncado (conversor devolveria '') nao e prova de
        # nada => ok=false, parse_ok=false => veredito inconclusive.
        # JSON valido tambem nao basta: parse_ok=true SO com envelope de
        # transcript (root objeto + data array tipado); 42, {}, {"error":...}
        # sao resposta valida mas nao transcript => parse_ok=false.
        $rawOut = [string]$mr.Output
        if ([string]::IsNullOrWhiteSpace($rawOut)) { $res.reason = 'GET message vazio (truncado)'; return $res }
        $chkJson = $null
        try { $chkJson = ConvertFrom-Json $rawOut } catch { $chkJson = $null }
        # Envelope de transcript: root objeto + propriedade data ARRAY
        # (Get-JsonProp desenrolaria array vazio para $null; por isso le
        # Properties['data'] direto e exige [System.Array]).
        $envelopeOk = $false
        try {
            if (($null -ne $chkJson) -and ($chkJson -isnot [string]) -and ($chkJson -isnot [System.Collections.IEnumerable])) {
                $dataProp = $null
                try { $dataProp = $chkJson.PSObject.Properties['data'] } catch { $dataProp = $null }
                if (($null -ne $dataProp) -and ($dataProp.Value -is [System.Array])) { $envelopeOk = $true }
            }
        } catch { $envelopeOk = $false }
        if (-not [bool]$envelopeOk) { $res.reason = 'GET message sem envelope data[] valido (nao e transcript)'; return $res }
        $txt = Convert-ProbeMessageJsonToToolText $rawOut
        # Ordem: extrai do texto ESTRUTURADO antes de sanitizar/truncar
        # (sanitize colapsa quebras e truncate elimina registros; sanitize
        # serve so para gravar evidencia). Sem rede adicional, sem log.
        $ev = Get-ProbeToolEvidence $txt
        $safe = Get-ProbeSafeText $txt 2000
        $res.parse_ok = $true
        $res.ok = $true
        $res.count = [int]$ev.count
        $res.names = @($ev.names)
        $res.head = $safe
        if ($res.head.Length -gt 500) { $res.head = $res.head.Substring(0, 500) }
        return $res
    } catch { $res.reason = (Get-ProbeSafeText $_.Exception.Message 120); return $res }
}
function Get-ProbeChildSessionId {
    # Localiza a child session (parentID + agent) via GET /api/session.
    [CmdletBinding()] param([string]$ServeUrl = '', $ApiEnv = $null, [string[]]$ApiRemove = @(), [string]$WorkDir = '', [string]$ParentId = '', [string]$Agent = '')
    try {
        if ([string]::IsNullOrWhiteSpace($ParentId)) { return '' }
        if (-not (Test-ProbeLocalhostUrl $ServeUrl)) { return '' }
        $lr = Invoke-PreflightBoundedExe -File $script:Exe -ArgsLine ('api --server ' + $ServeUrl + ' GET /api/session') -WorkDir $WorkDir -EnvTable $ApiEnv -EnvRemove $ApiRemove -TimeoutMs 30000 -MaxChars 131072
        if ((-not [bool]$lr.Finished) -or ([int]$lr.ExitCode -ne 0)) { return '' }
        $lj = $null
        try { $lj = ConvertFrom-Json ([string]$lr.Output) } catch { return '' }
        foreach ($r in @(Get-JsonProp $lj 'data' $null)) {
            try {
                if (([string](Get-JsonProp $r 'parentID' '') -ceq $ParentId) -and ([string](Get-JsonProp $r 'agent' '') -ceq $Agent)) {
                    return [string](Get-JsonProp $r 'id' '')
                }
            } catch { }
        }
    } catch { }
    return ''
}
# Marcadores de discovery: conta servers/tools citados sem vazar conteudo.
# tool_count/tool_names contam SOMENTE registros estruturados TOOL name/status
# (Get-ProbeToolEvidence); mencao em prosa nao conta.
function Get-ProbeDiscoveryScore([string]$Text) {
    $res = [ordered]@{ sees_playwright = $false; sees_devtools = $false; tool_hits = 0; marker_a = $false; marker_b = $false; tool_count = 0; tool_names = @(); tool_browser_ok = $false; tool_subagent_ok = $false }
    try {
        if ([string]::IsNullOrWhiteSpace($Text)) { return $res }
        $res.sees_playwright = [bool]($Text -match '(?i)playwright')
        $res.sees_devtools = [bool]($Text -match '(?i)(chrome-)?devtools')
        $res.tool_hits = ([regex]::Matches($Text, '(?i)(browser_navigate|browser_snapshot|list_console_messages|take_snapshot|navigate_page)')).Count
        $res.marker_a = [bool]($Text -match 'DISCOVERY-A')
        $res.marker_b = [bool]($Text -match 'DISCOVERY-B')
        $ev = Get-ProbeToolEvidence $Text
        $res.tool_count = [int]$ev.count
        $res.tool_names = @($ev.names)
        foreach ($n in @($ev.names)) {
            try {
                $nn = [string]$n
                if ($nn -match '(?i)^(browser_snapshot|take_snapshot)/(completed|complete|success|ok|done)$') { $res.tool_browser_ok = $true }
                if ($nn -match '(?i)^subagent/(completed|complete|success|ok|done)$') { $res.tool_subagent_ok = $true }
            } catch { }
        }
    } catch { }
    return $res
}

function Get-ProbeMcpToolCounts($Names) {
    # Prova ESTRUTURAL por sessao: conta tool calls da superficie MCP
    # (mesmo conjunto do tool_hits) com status de execucao. Exclui a chamada
    # `subagent` em si e tools nao relacionadas. failed/denied/unknown nao
    # provam execucao (vao para other e bloqueiam H0).
    $exec = New-Object System.Collections.ArrayList
    $other = New-Object System.Collections.ArrayList
    try {
        foreach ($n in @($Names)) {
            try {
                $s = [string]$n
                if ([string]::IsNullOrWhiteSpace($s)) { continue }
                if ($s -match '(?i)^subagent/') { continue }
                $ix = $s.IndexOf('/')
                if ($ix -le 0) { continue }
                $tool = $s.Substring(0, $ix)
                $st = $s.Substring($ix + 1)
                if ($tool -notmatch '(?i)^(browser_navigate|browser_snapshot|list_console_messages|take_snapshot|navigate_page)$') { continue }
                if ($st -match '(?i)^(completed|complete|success|ok|done)$') { [void]$exec.Add($s) }
                else { [void]$other.Add($s) }
            } catch { }
        }
    } catch { }
    return [ordered]@{ executed = @($exec); other = @($other) }
}

function Get-ProbeVerdict {
    # Decisao 100% ESTRUTURAL H1/H0/inconclusive. Presenca (H1) = tool MCP
    # executada/completed em parent-A ou child (subagent excluida).
    # Ausencia (H0) = ambos transcripts completos/validos + zero registros
    # MCP estruturais. Mencao textual NUNCA cria presenca nem ausencia.
    # Leitura invalida/parcial ou timeout => inconclusive. Failed/denied/
    # unknown bloqueiam H0 sem estabelecer H1 => inconclusive.
    [CmdletBinding()] param(
        [bool]$TurnAOk = $false,
        [bool]$TurnBOk = $false,
        [bool]$MsgAOk = $false,
        [bool]$ChildMsgOk = $false,
        [string[]]$ParentANames = @(),
        [string[]]$ChildNames = @())
    $res = [ordered]@{ decision = 'inconclusive'; reason = ''; basis = 'textual'; mcp_a = $null; mcp_child = $null }
    try {
        $mA = Get-ProbeMcpToolCounts $ParentANames
        $mC = Get-ProbeMcpToolCounts $ChildNames
        $res.mcp_a = $mA
        $res.mcp_child = $mC
        if (-not [bool]$TurnAOk) { $res.reason = 'turno A sem ok (timeout/falha); sem decisao'; return $res }
        if (-not [bool]$TurnBOk) { $res.reason = 'turno B sem ok (timeout/falha); sem decisao'; return $res }
        if ((-not [bool]$MsgAOk) -or (-not [bool]$ChildMsgOk)) { $res.reason = ('transcript parcial/invalido (msgA.ok=' + [bool]$MsgAOk + ' child.ok=' + [bool]$ChildMsgOk + '); sem decisao'); return $res }
        $res.basis = 'structural'
        $execNames = @(@($mA.executed) + @($mC.executed))
        $otherNames = @(@($mA.other) + @($mC.other))
        if (@($execNames).Count -gt 0) {
            $res.decision = 'H1'
            $res.reason = ('base=structural; presenca: tool MCP executada [' + ((@($execNames) | ForEach-Object { [string]$_ }) -join ',') + ']')
            return $res
        }
        if (@($otherNames).Count -eq 0) {
            $res.decision = 'H0'
            $res.reason = 'base=structural; ausencia verificada: ambos transcripts completos e zero tools MCP estruturais'
            return $res
        }
        $res.reason = ('base=structural; tool MCP com status nao-executado [' + ((@($otherNames) | ForEach-Object { [string]$_ }) -join ',') + ']; sem prova de execucao nem de ausencia')
        return $res
    } catch { $res.reason = 'veredito indisponivel (fail-closed inconclusive)'; return $res }
}

$script:Verdict = [ordered]@{ decision = 'not-run'; reason = '' }
$script:TurnEvidence = $null

try {
    # ---------- 1. pin vs binario vivo ----------
    $pinv = $null
    try { $pinv = Get-OrchestrationRuntimeVersion -Name 'v2' -RepoRoot $RepoRoot } catch { Write-ProbeSummary 'blocked' ('pin v2 irresolvivel: ' + $_.Exception.Message) 0 }
    if ($null -eq $pinv -or [string]::IsNullOrWhiteSpace([string]$pinv.version)) { Write-ProbeSummary 'blocked' 'pin v2 ausente no registry.' 0 }
    $pinVersion = [string]$pinv.version
    $cands = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($BinaryPath)) {
        if (-not (Test-Path -LiteralPath $BinaryPath -PathType Leaf)) { Write-ProbeSummary 'blocked' '-BinaryPath inexistente.' 0 }
        [void]$cands.Add($BinaryPath)
    } else {
        foreach ($c in @(Get-Command -Name 'opencode' -All -ErrorAction SilentlyContinue)) {
            $src = ''
            try { $src = [string]$c.Source } catch { $src = '' }
            if (-not [string]::IsNullOrWhiteSpace($src) -and (Test-Path -LiteralPath $src)) { [void]$cands.Add($src) }
        }
        $profileBin = Join-Path $env:USERPROFILE '.opencode-orchestration\profiles\v2\runtime\node_modules\@opencode\cli\bin\opencode.exe'
        if ((Test-Path -LiteralPath $profileBin -PathType Leaf) -and (-not ($cands -contains $profileBin))) { [void]$cands.Add($profileBin) }
    }
    foreach ($cand in @($cands)) {
        $exePath = [string]$cand
        $ext = [IO.Path]::GetExtension($exePath).ToLowerInvariant()
        if ($ext -ne '.exe') {
            $resolved = ''
            try { $resolved = Resolve-SpikeShimTarget -ShimPath $exePath } catch { $resolved = '' }
            if ([string]::IsNullOrWhiteSpace($resolved) -or (-not (Test-Path -LiteralPath $resolved -PathType Leaf))) { continue }
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
    if ([string]::IsNullOrWhiteSpace($script:Exe)) { Write-ProbeSummary 'blocked' 'nenhum binario V2 respondeu --version (infra indisponivel).' 0 }
    Add-ProbeCheck 'binary_live_resolved' $true ('vivo=' + $script:LiveVersion + ' pin=' + $pinVersion)

    # ---------- 2. perfil testing + config a partir do template ----------
    $profTesting = New-ProbeProfile -ProfileId 'testing'
    $tmplPath = Join-Path $RepoRoot 'templates\opencode.v2.json.tmpl'
    if (-not (Test-Path -LiteralPath $tmplPath -PathType Leaf)) { Write-ProbeSummary 'blocked' ('template ausente: ' + $tmplPath) 0 }
    $tmplRaw = [IO.File]::ReadAllText($tmplPath, [Text.Encoding]::UTF8)
    $tmplRaw = $tmplRaw.Replace('{{MODEL_PLANNER}}', $CheapModel).Replace('{{MODEL_CHEAP}}', $CheapModel).Replace('{{MODEL_STRONG}}', $StrongModel)
    $tmplJson = $null
    try { $tmplJson = ConvertFrom-Json $tmplRaw } catch { Write-ProbeSummary 'blocked' ('template nao parseia: ' + $_.Exception.Message) 0 }
    $agBuild = Get-JsonProp (Get-JsonProp $tmplJson 'agents' $null) 'build' $null
    $agDebugger = Get-JsonProp (Get-JsonProp $tmplJson 'agents' $null) 'debugger' $null
    if (($null -eq $agBuild) -or ($null -eq $agDebugger)) { Write-ProbeSummary 'blocked' 'template sem blocos agents.build/debugger.' 0 }
    $mcpTesting = [ordered]@{
        servers = [ordered]@{
            playwright = [ordered]@{
                type = 'local'
                command = @('npx', '-y', '@playwright/mcp@0.0.83', '--headless', '--isolated')
                disabled = $false
            }
            'chrome-devtools' = [ordered]@{
                type = 'local'
                command = @('npx', '-y', 'chrome-devtools-mcp@1.10.1', '--headless', '--isolated', '--no-usage-statistics', '--no-performance-crux')
                disabled = $false
            }
        }
    }
    $cfg = [ordered]@{
        default_agent = 'build'
        experimental = [ordered]@{ subagent_depth = 1 }
        agents = [ordered]@{ build = $agBuild; debugger = $agDebugger }
        mcp = $mcpTesting
    }
    $cfgParent = Split-Path -Parent ([string]$profTesting.cfg_path)
    if (-not (Test-Path -LiteralPath $cfgParent -PathType Container)) { New-Item -ItemType Directory -Path $cfgParent -Force | Out-Null }
    [IO.File]::WriteAllText(([string]$profTesting.cfg_path), ((($cfg | ConvertTo-Json -Depth 8).TrimEnd() + "`n") -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
    Add-ProbeCheck 'config_testing_2mcp' $true 'agents.build/debugger do template + 2 MCPs (playwright, chrome-devtools)'

    # ---------- 3. isolamento via debug paths ----------
    $dp = Invoke-SpikeChild -FilePath $script:Exe -ArgumentList @('debug', 'paths') -EnvSet $profTesting.env -EnvRemove $script:IsoRemove -WorkingDirectory ([string]$profTesting.cwd) -TimeoutMs 30000 -CleanEnvironment -StdinNul
    $dpText = ([string]$dp.Stdout + "`n" + [string]$dp.Stderr)
    $inTemp = ($dpText.Contains($TargetHome) -or $dpText.Contains(($TargetHome -replace '\\', '/')))
    $touchesHome = $false
    try {
        if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
            $touchesHome = ($dpText.Contains((Join-Path $env:USERPROFILE '.config\opencode')) -or $dpText.Contains((Join-Path $env:USERPROFILE '.local')))
        }
    } catch { }
    Add-ProbeCheck 'isolation_testing' (($inTemp) -and (-not $touchesHome) -and ([int]$dp.ExitCode -eq 0)) ('debug paths em TEMP; sem ~/.config (toca-home=' + $touchesHome + ')')
    if ((-not $inTemp) -or $touchesHome -or ([int]$dp.ExitCode -ne 0)) { Write-ProbeSummary 'blocked' 'isolamento nao comprovado via debug paths (fail-closed).' 0 }

    # ---------- 3b. credential files pos-gate opt-in (TEMP-confinado) ----------
    if (Test-ProbeModelKeyAvailable) {
        $cf = $false
        try { $cf = Import-ProbeProfileCredentials $profTesting } catch { $cf = $false }
        Add-ProbeCheck 'credential_files' $true ('auth_store=' + [bool]$cf + ' (nomes/contagens apenas; segredos morrem com TargetHome)')
    } else {
        Add-ProbeCheck 'credential_files' $true 'opt-in ausente: nenhum arquivo de credencial tocado (fail-closed)'
    }

    # ---------- 4. porta + serve owned + discovery local ----------
    $portSvc = 0
    for ($i = 0; $i -lt 10; $i++) {
        $p = Get-SpikeFreePort
        if ($p -ne 49374) { $portSvc = $p; break }
    }
    if ($portSvc -eq 0) { Write-ProbeSummary 'blocked' 'sem porta livre fora de 49374 (infra).' 0 }
    $sp = Invoke-SpikeChild -FilePath $script:Exe -ArgumentList @('service', 'set', 'port', "$portSvc") -EnvSet $profTesting.env -EnvRemove $script:IsoRemove -WorkingDirectory ([string]$profTesting.cwd) -TimeoutMs 30000 -CleanEnvironment -StdinNul
    if ([bool]$sp.TimedOut -or ([int]$sp.ExitCode -ne 0)) { Write-ProbeSummary 'blocked' 'service set port falhou no perfil testing (infra).' 0 }
    $serveUrl = ('http://127.0.0.1:' + $portSvc)
    if (-not (Test-ProbeLocalhostUrl $serveUrl)) { Write-ProbeSummary 'blocked' 'guard localhost recusou a URL (defeito do probe).' 0 }
    if ([bool]$DryRun) {
        $so = Start-ProbeOwnedProcess -FilePath $script:Exe -ArgumentList @('serve', '--port', "$portSvc") -EnvTable $profTesting.env -EnvRemove $script:IsoRemove -WorkDir ([string]$profTesting.cwd)
    } else {
        $runEnv = @{}
        try { foreach ($k in @($profTesting.env.Keys)) { $runEnv[[string]$k] = [string]$profTesting.env[$k] } } catch { }
        if (Test-ProbeModelKeyAvailable) {
            try { $runEnv[$script:ModelKeyEnvNameClean] = [Environment]::GetEnvironmentVariable($script:ModelKeyEnvNameClean, 'Process') } catch { }
        }
        $so = Start-ProbeOwnedProcess -FilePath $script:Exe -ArgumentList @('serve', '--port', "$portSvc") -EnvTable $runEnv -EnvRemove $script:IsoRemove -WorkDir ([string]$profTesting.cwd)
    }
    if (-not [bool]$so.ok) { Write-ProbeSummary 'blocked' ('serve owned nao iniciou: ' + $so.reason) 0 }
    if (-not (Wait-ProbeListener -Port $portSvc -DeadlineSeconds $ServeTimeoutSeconds)) { Write-ProbeSummary 'blocked' 'serve owned sem listener (infra).' 0 }
    if ((-not [bool]$DryRun) -and (Test-ProbeModelKeyAvailable)) {
        $cc = Copy-ProbeCredentials ([string]$profTesting.db)
        Add-ProbeCheck 'credential_store' ([bool]$cc.ok) ('credential rows=' + [int]$cc.rows + ' (contagem apenas)')
        if (-not [bool]$cc.ok) { Write-ProbeSummary 'blocked' ('credential store indisponivel: ' + $cc.reason) 0 }
        $rs = Restart-ProbeServeAfterCredentials -OldServe $so -FilePath $script:Exe -ArgumentList @('serve', '--port', "$portSvc") -EnvTable $runEnv -EnvRemove $script:IsoRemove -WorkDir ([string]$profTesting.cwd) -Port $portSvc -TimeoutSeconds $ServeTimeoutSeconds
        Add-ProbeCheck 'serve_restart' ([bool]$rs.ok) $rs.reason
        if (-not [bool]$rs.ok) { Write-ProbeSummary 'blocked' ('serve restart pos-credential: ' + $rs.reason) 0 }
        $so = $rs.serve
    }
    $auth = Add-ProbeServeAuth $profTesting.env
    Add-ProbeCheck 'serve_auth' ([bool]$auth.hasPassword) 'segredo do serve em memoria (nunca logado)'
    if (-not [bool]$auth.hasPassword) { Write-ProbeSummary 'blocked' 'serve sem segredo (auth fail-closed).' 0 }
    $w = Wait-ProbeMcpNames $serveUrl $auth.env $script:ApiRemove ([string]$profTesting.cwd) @('playwright', 'chrome-devtools') 180
    Add-ProbeCheck 'mcp_local_discovery' ((@($w.missing).Count -eq 0)) ('queries=' + [int]$w.queries + ' elapsed_ms=' + [int]$w.elapsed_ms + ' missing=[' + ($w.missing -join ',') + '] degraded=[' + ($w.degraded -join ',') + ']')
    if ((@($w.missing).Count -gt 0) -and [string]::IsNullOrWhiteSpace($w.text)) { Write-ProbeSummary 'blocked' ('GET /api/mcp sem resposta (infra; queries=' + [int]$w.queries + ')') 0 }
    if (@($w.missing).Count -gt 0) { Write-ProbeSummary 'blocked' ('serve nao expoe os 2 MCPs localmente: missing=[' + ($w.missing -join ',') + '] (infra/modelo-indisponivel para provar)') 0 }

    if ([bool]$DryRun) {
        $stop = Stop-ProbeOwned 'dryrun-done'
        [void](Wait-ProbeOwnedExit 30)
        $removed = Remove-ProbeTargetHome 5
        $residue = @(Get-ProbeSensitiveResidue)
        $cleanOk = (((@($stop.leaks).Count -eq 0) -and (@($stop.stopFailures).Count -eq 0) -and (@($stop.closeFailures).Count -eq 0) -and (@($stop.unknown).Count -eq 0) -and [bool]$removed -and (@($residue).Count -eq 0)))
        Add-ProbeCheck 'dryrun_cleanup' ([bool]$cleanOk) ('leaks=' + @($stop.leaks).Count + ' stop-failures=' + @($stop.stopFailures).Count + ' removed=' + [bool]$removed + ' residue=[' + ((@($residue) | ForEach-Object { Get-ProbeSafeText ([string]$_) 80 }) -join ',') + ']')
        if (-not [bool]$cleanOk) {
            $script:Verdict = [ordered]@{ decision = 'cleanup-failed'; reason = 'residuo de cleanup em dry-run (fail-closed)' }
            Write-ProbeSummary 'failed' ('cleanup incompleto em dry-run: leaks=' + @($stop.leaks).Count + ' stop-failures=' + @($stop.stopFailures).Count + ' removed=' + [bool]$removed + ' residue=[' + ((@($residue) | ForEach-Object { Get-ProbeSafeText ([string]$_) 80 }) -join ',') + '] (nomes apenas)') 1
        }
        $script:Verdict = [ordered]@{ decision = 'dry-run-ok'; reason = 'perfil+serve+discovery local ok; nenhum turno com modelo executado' }
        Write-ProbeSummary 'completed' 'dry-run ok: perfil+serve+discovery local; turnos A/B nao executados (sem quota).' 0
    }

    # ---------- 5. turnos A/B (model-gated) ----------
    if (-not (Test-ProbeModelKeyAvailable)) {
        $script:Verdict = [ordered]@{ decision = 'blocked'; reason = ('OPERATOR_ACTION_REQUIRED: ' + (Get-ProbeModelKeyLogToken)) }
        Write-ProbeSummary 'blocked' ('OPERATOR_ACTION_REQUIRED: ' + (Get-ProbeModelKeyLogToken)) 0
    }
    $sessA = New-ProbeApiSession -ServerUrl $serveUrl -EnvTable $profTesting.env -Cwd ([string]$profTesting.cwd)
    $sessB = New-ProbeApiSession -ServerUrl $serveUrl -EnvTable $profTesting.env -Cwd ([string]$profTesting.cwd)
    if ((-not [bool]$sessA.ok) -or (-not [bool]$sessB.ok)) { Write-ProbeSummary 'blocked' 'sessao API indisponivel para A/B (infra).' 0 }
    Add-ProbeCheck 'sessions_ab' $true 'duas sessoes via API (A=parent direto, B=delegacao debugger)'
    $promptA = 'You MUST call a browser snapshot tool (browser_snapshot or take_snapshot) to prove the MCP is attached, then list the MCP servers and browser tools YOU can see right now (do NOT delegate to any subagent). Output one line per server/tool, then report the call result verbatim as: TOOL-RESULT name=<tool> status=<status>. End with exactly: DISCOVERY-A done servers=<n> tool_status=<status>.'
    $promptB = 'Delegate to the debugger subagent with this exact instruction: call a browser snapshot tool (browser_snapshot or take_snapshot) to prove the MCP is attached, list the MCP servers and browser tools IT can see, and report TOOL-RESULT name=<tool> status=<status>. Then relay its answer verbatim and end with exactly: DISCOVERY-B done.'
    $shaA = Get-PromptSha256 $promptA
    $shaB = Get-PromptSha256 $promptB
    # Pre-turn MCP re-check: elimina a corrida de anexacao assincrona como
    # confundidor; aborta como blocked se algum MCP sumir antes do turno.
    $preA = Wait-ProbeMcpNames $serveUrl $auth.env $script:ApiRemove ([string]$profTesting.cwd) @('playwright', 'chrome-devtools') 30
    Add-ProbeCheck 'preturn_mcp_a' ((@($preA.missing).Count -eq 0)) ('queries=' + [int]$preA.queries + ' elapsed_ms=' + [int]$preA.elapsed_ms + ' found=[' + ($preA.found -join ',') + '] missing=[' + ($preA.missing -join ',') + '] degraded=[' + ($preA.degraded -join ',') + ']')
    if (@($preA.missing).Count -gt 0) { Write-ProbeSummary 'blocked' ('pre-turn A: MCP ausente (missing=[' + ($preA.missing -join ',') + ']); anexacao nao comprovada antes do turno') 0 }
    $turnA = Invoke-ProbeModelRun -ServerUrl $serveUrl -SessionId ([string]$sessA.id) -Model $CheapModel -Agent 'build' -Prompt $promptA
    $preB = Wait-ProbeMcpNames $serveUrl $auth.env $script:ApiRemove ([string]$profTesting.cwd) @('playwright', 'chrome-devtools') 30
    Add-ProbeCheck 'preturn_mcp_b' ((@($preB.missing).Count -eq 0)) ('queries=' + [int]$preB.queries + ' elapsed_ms=' + [int]$preB.elapsed_ms + ' found=[' + ($preB.found -join ',') + '] missing=[' + ($preB.missing -join ',') + '] degraded=[' + ($preB.degraded -join ',') + ']')
    if (@($preB.missing).Count -gt 0) { Write-ProbeSummary 'blocked' ('pre-turn B: MCP ausente (missing=[' + ($preB.missing -join ',') + ']); anexacao nao comprovada antes do turno') 0 }
    $turnB = Invoke-ProbeModelRun -ServerUrl $serveUrl -SessionId ([string]$sessB.id) -Model $CheapModel -Agent 'build' -Prompt $promptB
    $scoreA = Get-ProbeDiscoveryScore $turnA.out
    $scoreB = Get-ProbeDiscoveryScore $turnB.out
    $childAgentsB = @()
    try {
        $authB = Add-ProbeServeAuth $profTesting.env
        if ([bool]$authB.hasPassword) {
            $lr = Invoke-PreflightBoundedExe -File $script:Exe -ArgsLine ('api --server ' + $serveUrl + ' GET /api/session') -WorkDir ([string]$profTesting.cwd) -EnvTable $authB.env -EnvRemove $script:ApiRemove -TimeoutMs 30000 -MaxChars 131072
            if ([bool]$lr.Finished -and ([int]$lr.ExitCode -eq 0)) {
                $lj = $null
                try { $lj = ConvertFrom-Json ([string]$lr.Output) } catch { $lj = $null }
                foreach ($r in @(Get-JsonProp $lj 'data' $null)) {
                    try {
                        if ([string](Get-JsonProp $r 'parentID' '') -ceq [string]$sessB.id) {
                            $an = [string](Get-JsonProp $r 'agent' '')
                            if (-not [string]::IsNullOrWhiteSpace($an)) { $childAgentsB += $an }
                        }
                    } catch { }
                }
            }
        }
    } catch { }
    $childDebugger = (@($childAgentsB) -contains 'debugger')
    Add-ProbeCheck 'turn_a_ok' ([bool]$turnA.ok) ('exit=' + [int]$turnA.exit + ' timeout=' + [bool]$turnA.timedout + ' sees_pw=' + [bool]$scoreA.sees_playwright + ' sees_dt=' + [bool]$scoreA.sees_devtools + ' tool_count=' + [int]$scoreA.tool_count + ' tool_browser_ok=' + [bool]$scoreA.tool_browser_ok)
    Add-ProbeCheck 'turn_b_ok' ([bool]$turnB.ok) ('exit=' + [int]$turnB.exit + ' timeout=' + [bool]$turnB.timedout + ' sees_pw=' + [bool]$scoreB.sees_playwright + ' sees_dt=' + [bool]$scoreB.sees_devtools + ' child_debugger=' + [bool]$childDebugger + ' tool_count=' + [int]$scoreB.tool_count + ' tool_subagent_ok=' + [bool]$scoreB.tool_subagent_ok)
    # Prova por turno independente do modelo: transcript pos-turno via
    # GET /api/session/:id/message (parent A, parent B, child debugger de B).
    $msgA = Get-ProbeSessionMessageToolEvidence -ServeUrl $serveUrl -ApiEnv $auth.env -ApiRemove $script:ApiRemove -WorkDir ([string]$profTesting.cwd) -SessionId ([string]$sessA.id)
    $msgB = Get-ProbeSessionMessageToolEvidence -ServeUrl $serveUrl -ApiEnv $auth.env -ApiRemove $script:ApiRemove -WorkDir ([string]$profTesting.cwd) -SessionId ([string]$sessB.id)
    Add-ProbeCheck 'turn_a_parent_tool' ([bool]$msgA.ok) ('count=' + [int]$msgA.count + ' names=[' + (($msgA.names | ForEach-Object { Get-ProbeSafeText ([string]$_) 60 }) -join ',') + '] ' + [string]$msgA.reason)
    Add-ProbeCheck 'turn_b_parent_tool' ([bool]$msgB.ok) ('count=' + [int]$msgB.count + ' names=[' + (($msgB.names | ForEach-Object { Get-ProbeSafeText ([string]$_) 60 }) -join ',') + '] ' + [string]$msgB.reason)
    $childIdB = Get-ProbeChildSessionId -ServeUrl $serveUrl -ApiEnv $auth.env -ApiRemove $script:ApiRemove -WorkDir ([string]$profTesting.cwd) -ParentId ([string]$sessB.id) -Agent 'debugger'
    $cmsgB = [ordered]@{ ok = $false; count = 0; names = @(); head = ''; reason = 'child debugger ausente' }
    if (-not [string]::IsNullOrWhiteSpace($childIdB)) {
        $cmsgB = Get-ProbeSessionMessageToolEvidence -ServeUrl $serveUrl -ApiEnv $auth.env -ApiRemove $script:ApiRemove -WorkDir ([string]$profTesting.cwd) -SessionId $childIdB
    }
    Add-ProbeCheck 'turn_b_child_tool' ([bool]$cmsgB.ok) ('count=' + [int]$cmsgB.count + ' names=[' + (($cmsgB.names | ForEach-Object { Get-ProbeSafeText ([string]$_) 60 }) -join ',') + '] ' + [string]$cmsgB.reason)
    # Veredito 100% estrutural (texto nunca decide); computado antes da
    # evidencia para que probe-ab.json carregue mcp counts + basis.
    $vd = Get-ProbeVerdict -TurnAOk ([bool]$turnA.ok) -TurnBOk ([bool]$turnB.ok) -MsgAOk ([bool]$msgA.ok) -ChildMsgOk ([bool]$cmsgB.ok) -ParentANames @($msgA.names) -ChildNames @($cmsgB.names)
    $script:TurnEvidence = [ordered]@{
        turn_a = [ordered]@{
            exit = [int]$turnA.exit
            timedout = [bool]$turnA.timedout
            turn_stdout_head = (Get-ProbeSafeText $turnA.out_stdout 500)
            turn_stderr_head = (Get-ProbeSafeText $turnA.out_stderr 500)
            preturn = [ordered]@{ queries = [int]$preA.queries; elapsed_ms = [int]$preA.elapsed_ms; found = @($preA.found); missing = @($preA.missing) }
            parent_tool = [ordered]@{ ok = [bool]$msgA.ok; count = [int]$msgA.count; names = @($msgA.names); mcp_executed = @($vd.mcp_a.executed); mcp_other = @($vd.mcp_a.other) }
            parent_tool_head = (Get-ProbeSafeText $msgA.head 500)
        }
        turn_b = [ordered]@{
            exit = [int]$turnB.exit
            timedout = [bool]$turnB.timedout
            turn_stdout_head = (Get-ProbeSafeText $turnB.out_stdout 500)
            turn_stderr_head = (Get-ProbeSafeText $turnB.out_stderr 500)
            preturn = [ordered]@{ queries = [int]$preB.queries; elapsed_ms = [int]$preB.elapsed_ms; found = @($preB.found); missing = @($preB.missing) }
            parent_tool = [ordered]@{ ok = [bool]$msgB.ok; count = [int]$msgB.count; names = @($msgB.names) }
            parent_tool_head = (Get-ProbeSafeText $msgB.head 500)
            child_tool = [ordered]@{ ok = [bool]$cmsgB.ok; count = [int]$cmsgB.count; names = @($cmsgB.names); mcp_executed = @($vd.mcp_child.executed); mcp_other = @($vd.mcp_child.other) }
            child_tool_head = (Get-ProbeSafeText $cmsgB.head 500)
        }
        verdict = [ordered]@{ decision = [string]$vd.decision; reason = [string]$vd.reason; basis = [string]$vd.basis }
    }
    [void](Write-ProbeJson ([ordered]@{
        prompt_sha256_a = $shaA
        prompt_sha256_b = $shaB
        child_agents_b = @($childAgentsB)
        score_a = $scoreA
        score_b = $scoreB
        mcp_parent_a = $vd.mcp_a
        mcp_child = $vd.mcp_child
        turn_a = $script:TurnEvidence.turn_a
        turn_b = $script:TurnEvidence.turn_b
        verdict = $script:TurnEvidence.verdict
        at = (Get-ProbeTimestampUtc)
    }) (Join-Path $script:EvidenceDir 'probe-ab.json'))

    # ---------- 6. decisao H1/H0 (presenca/ausencia estrutural; texto nunca decide) ----------
    if ([string]$vd.decision -ceq 'H1') {
        $script:Verdict = [ordered]@{ decision = 'H1'; reason = [string]$vd.reason; basis = [string]$vd.basis }
        Write-ProbeSummary 'completed' ('H1: presenca estrutural de tool MCP executada (' + [string]$vd.reason + ').') 0
    } elseif ([string]$vd.decision -ceq 'H0') {
        $script:Verdict = [ordered]@{ decision = 'H0'; reason = [string]$vd.reason; basis = [string]$vd.basis }
        Write-ProbeSummary 'completed' ('H0: ausencia estrutural verificada (' + [string]$vd.reason + ').') 0
    } else {
        $script:Verdict = [ordered]@{ decision = 'inconclusive'; reason = [string]$vd.reason; basis = [string]$vd.basis }
        Write-ProbeSummary 'blocked' ('inconclusivo (' + [string]$vd.reason + ')') 0
    }
} finally {
    $cleanupFailed = $false
    $cleanupResidueNames = @()
    $cleanupRemoved = $true
    $cleanupLeaks = 0
    $cleanupStopBad = $false
    $cleanupCloseBad = $false
    $cleanupUnknown = $false
    try {
        foreach ($job in @($script:OwnedJobs)) {
            try {
                $fsr = Stop-RuntimeJobObject -Job $job
                if ($null -eq $fsr) { $cleanupStopBad = $true; $cleanupUnknown = $true }
                elseif (-not [bool]$fsr.Ok) { $cleanupStopBad = $true; $cleanupUnknown = $true }
                elseif (-not [bool]$fsr.Settled) { $cleanupStopBad = $true }
            } catch { $cleanupStopBad = $true; $cleanupUnknown = $true }
        }
    } catch { $cleanupStopBad = $true; $cleanupUnknown = $true }
    try { [void](Wait-ProbeOwnedExit 30) } catch { $cleanupUnknown = $true }
    try {
        foreach ($job in @($script:OwnedJobs)) {
            try {
                $fcr = Close-RuntimeJobObject -Job $job
                if (($null -eq $fcr) -or (-not [bool]$fcr.Ok)) { $cleanupCloseBad = $true }
            } catch { $cleanupCloseBad = $true; $cleanupUnknown = $true }
        }
    } catch { $cleanupCloseBad = $true; $cleanupUnknown = $true }
    try {
        foreach ($p in @($script:OwnedProcs)) {
            try {
                $p.Refresh()
                if (-not [bool]$p.HasExited) { $cleanupLeaks += 1 }
            } catch { $cleanupUnknown = $true }
        }
    } catch { $cleanupUnknown = $true }
    try { $cleanupRemoved = [bool](Remove-ProbeTargetHome 5) } catch { $cleanupRemoved = $false }
    try { $cleanupResidueNames = @(Get-ProbeSensitiveResidue) } catch { $cleanupResidueNames = @('TargetHome-present') }
    if (([int]$cleanupLeaks -gt 0) -or [bool]$cleanupStopBad -or [bool]$cleanupCloseBad -or [bool]$cleanupUnknown -or (-not [bool]$cleanupRemoved) -or (@($cleanupResidueNames).Count -gt 0)) { $cleanupFailed = $true }
    try {
        if ((-not [bool]$script:SummaryWritten) -and (-not [string]::IsNullOrWhiteSpace($script:EvidenceDir))) {
            if ([bool]$cleanupFailed) {
                $residueList = ((@($cleanupResidueNames) | ForEach-Object { Get-ProbeSafeText ([string]$_) 80 }) -join ',')
                try { Add-ProbeCheck 'finally_cleanup' $false ('leaks=' + [int]$cleanupLeaks + ' removed=' + [bool]$cleanupRemoved + ' residue=[' + $residueList + '] (nomes apenas)') } catch { }
                $script:Verdict = [ordered]@{ decision = 'cleanup-failed'; reason = 'residuo de cleanup (fail-closed)' }
                $summary = [ordered]@{
                    probe = 'mcp-subagent-propagation-probe'
                    status = 'failed'
                    reason = (Get-ProbeSafeText ('cleanup incompleto: leaks=' + [int]$cleanupLeaks + ' removed=' + [bool]$cleanupRemoved + ' residue=[' + $residueList + '] (nomes apenas)') 400)
                    sanitize_fallback = [bool]$script:ProbeSanitizeFallback
                    verdict = $script:Verdict
                    checks = @($script:Checks)
                    turns = $script:TurnEvidence
                }
                [void](Write-ProbeJson $summary (Join-Path $script:EvidenceDir 'probe-summary.json'))
                try { Write-Host ('[mcp-probe] failed: cleanup incompleto (nomes apenas): [' + $residueList + ']') } catch { }
                exit 1
            } else {
                $summary = [ordered]@{
                    probe = 'mcp-subagent-propagation-probe'
                    status = 'completed-finally'
                    sanitize_fallback = [bool]$script:ProbeSanitizeFallback
                    verdict = $script:Verdict
                    checks = @($script:Checks)
                    turns = $script:TurnEvidence
                }
                [void](Write-ProbeJson $summary (Join-Path $script:EvidenceDir 'probe-summary.json'))
            }
        } elseif ([bool]$cleanupFailed) {
            $residueList = ((@($cleanupResidueNames) | ForEach-Object { Get-ProbeSafeText ([string]$_) 80 }) -join ',')
            try { Add-ProbeCheck 'finally_cleanup' $false ('leaks=' + [int]$cleanupLeaks + ' removed=' + [bool]$cleanupRemoved + ' residue=[' + $residueList + '] (nomes apenas)') } catch { }
            try {
                $failSummary = [ordered]@{
                    probe = 'mcp-subagent-propagation-probe'
                    status = 'failed'
                    reason = (Get-ProbeSafeText ('cleanup incompleto apos summary: leaks=' + [int]$cleanupLeaks + ' removed=' + [bool]$cleanupRemoved + ' residue=[' + $residueList + '] (nomes apenas)') 400)
                    sanitize_fallback = [bool]$script:ProbeSanitizeFallback
                    verdict = [ordered]@{ decision = 'cleanup-failed'; reason = 'residuo de cleanup (fail-closed)' }
                    checks = @($script:Checks)
                    turns = $script:TurnEvidence
                }
                if (-not [string]::IsNullOrWhiteSpace($script:EvidenceDir)) { [void](Write-ProbeJson $failSummary (Join-Path $script:EvidenceDir 'probe-summary.json')) }
            } catch { }
            try { Write-Host ('[mcp-probe] failed: cleanup incompleto (nomes apenas): [' + $residueList + ']') } catch { }
            exit 1
        }
    } catch { }
    if ([bool]$cleanupFailed) { exit 1 }
}
