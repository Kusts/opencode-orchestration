# Probe HTTPS dedicado do AI Memory (transport-level, separado do round-trip MCP).
# Read/test oriented: nenhuma credencial lida ou gravada; host sanitizado na
# evidencia (host user-owned fora do repo). Timeout bounded; resultado real.
# PowerShell 5.1 compativel; ASCII-only.
[CmdletBinding()] param([string]$OutPath = '')
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutPath)) {
    $OutPath = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'evidence\v3.1\runtime-reliability\transport-probe-aimem-https-2026-10-06.json'
}
$url = ''
try {
    $cfgPath = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $url = [string]$cfg.mcp.'ai-memory'.url
} catch { $url = '' }
$redact = { param([string]$u) if ([string]::IsNullOrWhiteSpace($u)) { return '' }; return ($u -replace '://[^/]+', '://[REDACTED-HOST]') }
$result = [ordered]@{
    probe          = 'aimem-https-dedicated-transport'
    date           = ([DateTime]::UtcNow.ToString('yyyy-MM-dd'))
    endpoint       = (& $redact $url)
    endpoint_note  = 'caminho registrado sem query/credenciais; host user-owned fora do repo'
    tls_note       = 'o handshake com callback permissivo prova protocolo/latencia/validade temporal do certificado; NAO prova confianca de cadeia/hostname (eso e do cliente MCP real, cujo round-trip autenticado ja foi provado em 2026-10-04)'
    config_source  = 'user-owned ~/.config/opencode/opencode.json (mcp.ai-memory.url; valor nunca logado por completo)'
    checks         = New-Object System.Collections.ArrayList
    at             = ([DateTime]::UtcNow.ToString('o'))
}
function Add-Check([string]$Name, [bool]$Ok, [string]$Detail) {
    [void]$result.checks.Add([ordered]@{ check = $Name; ok = [bool]$Ok; detail = $Detail })
}
if ([string]::IsNullOrWhiteSpace($url)) {
    Add-Check 'endpoint-configured' $false 'mcp.ai-memory.url ausente no config user-owned; probe nao executa (BLOCKED honesto)'
} else {
$uri = [Uri]$url
    $hostName = $uri.Host
    $port = $(if ($uri.IsDefaultPort) { 443 } else { $uri.Port })
    # endpoint registrado SEMPRE redigido (host user-owned) e sem query
    # (query pode carregar credenciais em alguns setups)
    $result['endpoint'] = ($uri.Scheme + '://[REDACTED-HOST]:' + $port + $uri.AbsolutePath)
    # 1. TCP+TLS com SslStream: versao do protocolo, certificado (SNI real)
    $tcp = $null; $ssl = $null
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $tcp = New-Object Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect($hostName, $port, $null, $null)
        $connected = $iar.AsyncWaitHandle.WaitOne(10000)
        if (-not $connected) { throw 'tcp-connect-timeout-10s' }
        $tcp.EndConnect($iar)
        $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, { param($a, $b, $c, $d) return $true })
        # REV2: handshake com deadline - AuthenticateAsClient e sincrono e pode
        # bloquear indefinidamente contra endpoint que aceita TCP e nao conclui
        # TLS; o padrao async + Wait(10s) bounda o handshake (fail-closed)
        $hsTask = $ssl.AuthenticateAsClientAsync($hostName)
        if (-not $hsTask.Wait(10000)) { throw 'tls-handshake-timeout-10s' }
        $sw.Stop()
        $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
        $tlsOk = ($ssl.SslProtocol -ge [Security.Authentication.SslProtocols]::Tls12)
        Add-Check 'tls-handshake' $tlsOk ("protocolo=" + [string]$ssl.SslProtocol + " latencia_ms=" + $sw.ElapsedMilliseconds + " cert_subject=" + ($cert.Subject -replace 'CN=[^,]+', 'CN=[REDACTED]') + " cert_notafter=" + $cert.NotAfter.ToString('yyyy-MM-dd') + " tls12_ou_maior=" + $tlsOk)
        Add-Check 'tls-cert-valid-now' (($cert.NotAfter -gt [DateTime]::Now) -and ($cert.NotBefore -lt [DateTime]::Now)) ("validade atual ok; notAfter=" + $cert.NotAfter.ToString('yyyy-MM-dd'))
    } catch {
        Add-Check 'tls-handshake' $false ('falha: ' + $_.Exception.Message)
    } finally {
        if ($null -ne $ssl) { try { $ssl.Dispose() } catch {} }
        if ($null -ne $tcp) { try { $tcp.Close() } catch {} }
    }
    # 2. HTTP real contra o endpoint MCP (POST com body MCP minimo) + GET no host
    Add-Type -AssemblyName System.Net.Http
    foreach ($leg in @(@{ name = 'mcp-post'; method = 'POST'; path = $uri.PathAndQuery; body = '{"jsonrpc":"2.0","id":1,"method":"ping"}' },
                       @{ name = 'http-get'; method = 'GET'; path = '/'; body = '' })) {
        try {
            $handler = New-Object System.Net.Http.HttpClientHandler
            $client = New-Object System.Net.Http.HttpClient($handler)
            $client.Timeout = [TimeSpan]::FromSeconds(15)
            $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::new([string]$leg.method), ($uri.Scheme + '://' + $uri.Authority + [string]$leg.path))
            if (-not [string]::IsNullOrEmpty([string]$leg.body)) {
                $req.Content = New-Object System.Net.Http.StringContent([string]$leg.body, [Text.Encoding]::UTF8, 'application/json')
            }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $resp = $client.SendAsync($req).GetAwaiter().GetResult()
            $sw.Stop()
            $code = [int]$resp.StatusCode
            # qualquer resposta HTTP estruturada prova transporte; 4xx/5xx sao
            # observacoes reais (nao sao convertidas em saude)
            Add-Check ([string]$leg.name) $true ('http_status=' + $code + ' latencia_ms=' + $sw.ElapsedMilliseconds + ' server_respondeu=true (observacao real; status nao convertido em saude)')
            $resp.Dispose(); $client.Dispose(); $handler.Dispose()
        } catch {
            $msg = $_.Exception.Message
            if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
            # redacao agressiva: hosts/URLs nunca saem em mensagens de erro
            $msg = ($msg -replace '[^ ]*@[^ ]+', '[REDACTED]' -replace '(?i)https?://[^\s]+', '[REDACTED-URL]' -replace [regex]::Escape($hostName), '[REDACTED-HOST]')
            Add-Check ([string]$leg.name) $false ('falha de transporte (tipo: ' + $_.Exception.GetType().Name + '): ' + $msg)
        }
    }
}
$tmp = $OutPath + '.tmp-' + [guid]::NewGuid().ToString('N')
[IO.File]::WriteAllText($tmp, ((($result | ConvertTo-Json -Depth 8).TrimEnd() + "`n") -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
Move-Item -LiteralPath $tmp -Destination $OutPath -Force
foreach ($c in @($result.checks)) { Write-Host ("{0} {1} :: {2}" -f $(if ($c.ok) { 'OK ' } else { 'FAIL' }), $c.check, $c.detail) }
