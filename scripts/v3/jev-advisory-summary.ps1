<#!
.SYNOPSIS
    Contador offline dos eventos Jev advisory (P1-02 slice 1). Somente leitura.
.DESCRIPTION
    Conta registros em cache/v3/jev-advisory/*.jsonl por
    event x trigger_reason x mode e imprime o resumo como JSON compacto em
    stdout. Nao chama rede, modelo, MCP real (Jev) nem le segredo algum:
    le apenas os campos event/trigger_reason/mode de cada linha JSONL.

    Falhas (fail-closed, sem alegar sucesso parcial):
      - diretorio de evidencia ausente, sem arquivos *.jsonl ou sem
        registros validos => exit 1 (sem evidencia), mensagem em stderr.
      - qualquer linha malformada (JSON invalido ou event/trigger_reason/
        mode ausente, nao-string ou em branco) => exit 2, mensagem em
        stderr indicando arquivo e numero da linha (1-based). Nenhum
        resumo e impresso nesse caso.

    -SelfTest: constroi fixture sintetica em temp dir, conta e valida as
      contagens esperadas (asserts embutidos). Offline, sem tocar o repo.

    PowerShell 5.1 compativel. ASCII-only de proposito.
#>
[CmdletBinding()]
param(
    [string]$EvidenceDir = '',
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

function Write-SummaryError {
    param([string]$Text)
    [Console]::Error.WriteLine($Text)
}

function Get-SummaryRepoRoot {
    $v3 = $PSScriptRoot
    return (Split-Path -Parent (Split-Path -Parent $v3))
}

function Get-FieldText {
    param($Node, [string]$Name)
    try {
        if ($null -eq $Node) { return '' }
        if ($Node -is [System.Collections.IDictionary]) {
            if ($Node.Contains($Name)) {
                $v = $Node[$Name]
                if ($v -is [string]) { return $v }
                return ''
            }
            return ''
        }
        $p = $Node.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1
        if ($null -eq $p) { return '' }
        if ($p.Value -is [string]) { return ([string]$p.Value) }
        return ''
    }
    catch { return '' }
}

function Measure-JevAdvisoryDir {
    param([Parameter(Mandatory = $true)][string]$Dir)
    $result = [ordered]@{
        ok = $false
        exit_code = 1
        error = ''
        total_records = 0
        files_read = 0
        groups = @()
    }
    try {
        if ([string]::IsNullOrWhiteSpace($Dir) -or (-not (Test-Path -LiteralPath $Dir -PathType Container))) {
            $result.error = 'no-evidence-dir'
            return ([PSCustomObject]$result)
        }
        $files = @()
        try { $files = @(Get-ChildItem -LiteralPath $Dir -Filter '*.jsonl' -File -ErrorAction Stop) }
        catch {
            $result.error = 'no-evidence-dir'
            return ([PSCustomObject]$result)
        }
        if (@($files).Count -eq 0) {
            $result.error = 'no-evidence-files'
            return ([PSCustomObject]$result)
        }
        $counts = New-Object System.Collections.Hashtable -ArgumentList @([System.StringComparer]::Ordinal)
        $total = 0
        $nfiles = 0
        foreach ($f in @($files)) {
            $nfiles++
            $lines = @()
            try { $lines = ([IO.File]::ReadAllLines($f.FullName, [Text.Encoding]::UTF8)) }
            catch {
                $result.exit_code = 2
                $result.error = ('unreadable-file:' + $f.Name)
                return ([PSCustomObject]$result)
            }
            $lineno = 0
            foreach ($line in @($lines)) {
                $lineno++
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $node = $null
                try { $node = ($line | ConvertFrom-Json) }
                catch {
                    $result.exit_code = 2
                    $result.error = ('malformed-json:' + $f.Name + '#' + $lineno)
                    return ([PSCustomObject]$result)
                }
                if ($null -eq $node) {
                    $result.exit_code = 2
                    $result.error = ('malformed-json:' + $f.Name + '#' + $lineno)
                    return ([PSCustomObject]$result)
                }
                $ev = (Get-FieldText -Node $node -Name 'event').Trim()
                $tr = (Get-FieldText -Node $node -Name 'trigger_reason').Trim()
                $mo = (Get-FieldText -Node $node -Name 'mode').Trim()
                if ([string]::IsNullOrWhiteSpace($ev) -or [string]::IsNullOrWhiteSpace($tr) -or [string]::IsNullOrWhiteSpace($mo)) {
                    $result.exit_code = 2
                    $result.error = ('malformed-record:' + $f.Name + '#' + $lineno)
                    return ([PSCustomObject]$result)
                }
                $key = (ConvertTo-Json -InputObject @($ev, $tr, $mo) -Compress -Depth 2)
                if (-not $counts.ContainsKey($key)) { $counts[$key] = 0 }
                $counts[$key] = ([int]$counts[$key] + 1)
                $total++
            }
        }
        if ($total -eq 0) {
            $result.error = 'no-records'
            return ([PSCustomObject]$result)
        }
        $groups = @()
        foreach ($k in @($counts.Keys | Sort-Object -CaseSensitive)) {
            $parts = ($k | ConvertFrom-Json)
            $groups += ([PSCustomObject][ordered]@{
                event = ([string]$parts[0])
                trigger_reason = ([string]$parts[1])
                mode = ([string]$parts[2])
                count = ([int]$counts[$k])
            })
        }
        $result.ok = $true
        $result.exit_code = 0
        $result.error = ''
        $result.total_records = $total
        $result.files_read = $nfiles
        $result.groups = $groups
        return ([PSCustomObject]$result)
    }
    catch {
        $result.exit_code = 2
        $result.error = 'internal-error'
        return ([PSCustomObject]$result)
    }
}

if ($SelfTest) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('jev-summary-selftest-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $fixture = @(
            '{"event":"JEV_UNAVAILABLE","trigger_reason":"route-uncertain","mode":"shadow"}',
            '{"event":"JEV_UNAVAILABLE","trigger_reason":"route-uncertain","mode":"shadow"}',
            '{"event":"JEV_ADVISORY","trigger_reason":"conflicting-evidence","mode":"active"}'
        )
        [IO.File]::WriteAllLines((Join-Path $tmp 'a.jsonl'), $fixture, [Text.UTF8Encoding]::new($false))
        $r = Measure-JevAdvisoryDir -Dir $tmp
        $ok = $true
        if (-not $r.ok) { $ok = $false }
        if ([int]$r.total_records -ne 3) { $ok = $false }
        $g1 = @($r.groups | Where-Object { ([string]$_.event -ceq 'JEV_UNAVAILABLE') -and ([string]$_.trigger_reason -ceq 'route-uncertain') -and ([string]$_.mode -ceq 'shadow') })
        if ((@($g1).Count -ne 1) -or ([int]$g1[0].count -ne 2)) { $ok = $false }
        $g2 = @($r.groups | Where-Object { ([string]$_.event -ceq 'JEV_ADVISORY') -and ([string]$_.trigger_reason -ceq 'conflicting-evidence') -and ([string]$_.mode -ceq 'active') })
        if ((@($g2).Count -ne 1) -or ([int]$g2[0].count -ne 1)) { $ok = $false }
        $bad = Join-Path ([IO.Path]::GetTempPath()) ('jev-summary-selftest-bad-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $bad -Force | Out-Null
        try {
            [IO.File]::WriteAllText((Join-Path $bad 'b.jsonl'), "{not json}`n", [Text.UTF8Encoding]::new($false))
            $rb = Measure-JevAdvisoryDir -Dir $bad
            if ($rb.ok -or ([int]$rb.exit_code -ne 2)) { $ok = $false }
        }
        finally { try { Remove-Item -LiteralPath $bad -Recurse -Force -ErrorAction SilentlyContinue } catch { } }
        if ($ok) { Write-Host 'SELFTEST PASS (3 records, 2 groups; malformed fails exit 2)'; exit 0 }
        Write-SummaryError 'SELFTEST FAIL'
        exit 1
    }
    finally { try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { } }
}

$dir = $EvidenceDir
if ([string]::IsNullOrWhiteSpace($dir)) {
    $dir = (Join-Path (Get-SummaryRepoRoot) 'cache\v3\jev-advisory')
}

$res = Measure-JevAdvisoryDir -Dir $dir
if (-not $res.ok) {
    Write-SummaryError ('jev-advisory-summary: ' + [string]$res.error + ' (dir=' + $dir + ')')
    exit ([int]$res.exit_code)
}

$out = [ordered]@{
    evidence_dir = $dir
    files_read = ([int]$res.files_read)
    total_records = ([int]$res.total_records)
    groups = @($res.groups)
}
Write-Output (($out | ConvertTo-Json -Depth 4 -Compress))
exit 0
