$ErrorActionPreference = 'Stop'
$v3 = $PSScriptRoot
$cli = Join-Path $v3 'jev-advisory-summary.ps1'
$repo = Split-Path -Parent (Split-Path -Parent $v3)

$total = 0
$passed = 0
function Assert-That($condition, $name, $detail) {
    $script:total++
    if ($condition) { $script:passed++; Write-Host "[PASS] $name" }
    else { Write-Host "[FAIL] $name -- $detail" }
}

function Write-Fixture {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $lf = ($Text -replace "`r`n", "`n" -replace "`r", "`n")
    [IO.File]::WriteAllText($Path, $lf, [Text.UTF8Encoding]::new($false))
}

function Invoke-Summary {
    param([string]$Dir)
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-File', $cli, '-EvidenceDir', $Dir) -NoNewWindow -Wait -PassThru -RedirectStandardOutput ([IO.Path]::GetTempFileName()) -RedirectStandardError ([IO.Path]::GetTempFileName())
    return $p
}

# 1. contagem de fixture sintetica em temp dir
$base = Join-Path ([IO.Path]::GetTempPath()) ('jev-sum-t-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base -Force | Out-Null
Write-Fixture -Path (Join-Path $base 'a.jsonl') -Text (@(
    '{"event":"JEV_UNAVAILABLE","trigger_reason":"route-uncertain","mode":"shadow"}',
    '{"event":"JEV_UNAVAILABLE","trigger_reason":"route-uncertain","mode":"shadow"}',
    '{"event":"JEV_ADVISORY","trigger_reason":"conflicting-evidence","mode":"active"}'
) -join "`n")
$outFile = [IO.Path]::GetTempFileName()
$errFile = [IO.Path]::GetTempFileName()
$proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-File', $cli, '-EvidenceDir', $base) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
$stdout = ''
try { $stdout = [IO.File]::ReadAllText($outFile) } catch { $stdout = '' }
$doc = $null
try { $doc = ($stdout | ConvertFrom-Json) } catch { $doc = $null }
Assert-That ($proc.ExitCode -eq 0) 'fixture: exit 0' ("exit=$($proc.ExitCode)")
Assert-That (($null -ne $doc) -and ([int]$doc.total_records -eq 3)) 'fixture: total 3' $stdout
$g1 = @()
try { $g1 = @($doc.groups | Where-Object { ($_.event -ceq 'JEV_UNAVAILABLE') -and ($_.trigger_reason -ceq 'route-uncertain') -and ($_.mode -ceq 'shadow') }) } catch { $g1 = @() }
Assert-That ((@($g1).Count -eq 1) -and ([int]$g1[0].count -eq 2)) 'fixture: grupo 2x' $stdout

# 2. diretorio ausente => falha (exit 1), sem rede/modelo
$missing = Join-Path ([IO.Path]::GetTempPath()) ('jev-sum-missing-' + [guid]::NewGuid().ToString('N'))
$proc2 = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-File', $cli, '-EvidenceDir', $missing) -NoNewWindow -Wait -PassThru -RedirectStandardOutput ([IO.Path]::GetTempFileName()) -RedirectStandardError ([IO.Path]::GetTempFileName())
Assert-That ($proc2.ExitCode -eq 1) 'ausente: exit 1' ("exit=$($proc2.ExitCode)")

# 3. linha malformada => falha (exit 2)
$bad = Join-Path ([IO.Path]::GetTempPath()) ('jev-sum-bad-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $bad -Force | Out-Null
Write-Fixture -Path (Join-Path $bad 'b.jsonl') -Text "{not json}`n"
$proc3 = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-File', $cli, '-EvidenceDir', $bad) -NoNewWindow -Wait -PassThru -RedirectStandardOutput ([IO.Path]::GetTempFileName()) -RedirectStandardError ([IO.Path]::GetTempFileName())
Assert-That ($proc3.ExitCode -eq 2) 'malformado: exit 2' ("exit=$($proc3.ExitCode)")

# 4. registro sem campo obrigatorio => falha (exit 2)
$bad2 = Join-Path ([IO.Path]::GetTempPath()) ('jev-sum-bad2-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $bad2 -Force | Out-Null
Write-Fixture -Path (Join-Path $bad2 'c.jsonl') -Text '{"event":"JEV_ADVISORY","mode":"shadow"}'
$proc4 = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-File', $cli, '-EvidenceDir', $bad2) -NoNewWindow -Wait -PassThru -RedirectStandardOutput ([IO.Path]::GetTempFileName()) -RedirectStandardError ([IO.Path]::GetTempFileName())
Assert-That ($proc4.ExitCode -eq 2) 'campo-ausente: exit 2' ("exit=$($proc4.ExitCode)")

# 5. -SelfTest embutido passa
$proc5 = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-File', $cli, '-SelfTest') -NoNewWindow -Wait -PassThru -RedirectStandardOutput ([IO.Path]::GetTempFileName()) -RedirectStandardError ([IO.Path]::GetTempFileName())
Assert-That ($proc5.ExitCode -eq 0) 'selftest: exit 0' ("exit=$($proc5.ExitCode)")

# 6. colisao de pipe: tuplas distintas que colidiriam com join '|' ficam separadas
$pipe = Join-Path ([IO.Path]::GetTempPath()) ('jev-sum-pipe-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $pipe -Force | Out-Null
Write-Fixture -Path (Join-Path $pipe 'p.jsonl') -Text (@(
    '{"event":"E|A","trigger_reason":"B","mode":"C"}',
    '{"event":"E","trigger_reason":"A|B","mode":"C"}'
) -join "`n")
$outPipe = [IO.Path]::GetTempFileName()
$proc6 = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-File', $cli, '-EvidenceDir', $pipe) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outPipe -RedirectStandardError ([IO.Path]::GetTempFileName())
$stdoutPipe = ''
try { $stdoutPipe = [IO.File]::ReadAllText($outPipe) } catch { $stdoutPipe = '' }
$docPipe = $null
try { $docPipe = ($stdoutPipe | ConvertFrom-Json) } catch { $docPipe = $null }
Assert-That ($proc6.ExitCode -eq 0) 'pipe: exit 0' ("exit=$($proc6.ExitCode) out=$stdoutPipe")
Assert-That (($null -ne $docPipe) -and ([int]$docPipe.total_records -eq 2) -and (@($docPipe.groups).Count -eq 2)) 'pipe: 2 grupos distintos' $stdoutPipe
$pa = @()
$pb = @()
try {
    $pa = @($docPipe.groups | Where-Object { ($_.event -ceq 'E|A') -and ($_.trigger_reason -ceq 'B') -and ($_.mode -ceq 'C') })
    $pb = @($docPipe.groups | Where-Object { ($_.event -ceq 'E') -and ($_.trigger_reason -ceq 'A|B') -and ($_.mode -ceq 'C') })
} catch { $pa = @(); $pb = @() }
Assert-That ((@($pa).Count -eq 1) -and ([int]$pa[0].count -eq 1) -and (@($pb).Count -eq 1) -and ([int]$pb[0].count -eq 1)) 'pipe: contagens 1+1 exatas' $stdoutPipe

# 7. caixa: 'OK' vs 'ok' sao grupos distintos (comparacao ordinal)
$case = Join-Path ([IO.Path]::GetTempPath()) ('jev-sum-case-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $case -Force | Out-Null
Write-Fixture -Path (Join-Path $case 'k.jsonl') -Text (@(
    '{"event":"OK","trigger_reason":"route-uncertain","mode":"shadow"}',
    '{"event":"ok","trigger_reason":"route-uncertain","mode":"shadow"}'
) -join "`n")
$outCase = [IO.Path]::GetTempFileName()
$proc7 = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-File', $cli, '-EvidenceDir', $case) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outCase -RedirectStandardError ([IO.Path]::GetTempFileName())
$stdoutCase = ''
try { $stdoutCase = [IO.File]::ReadAllText($outCase) } catch { $stdoutCase = '' }
$docCase = $null
try { $docCase = ($stdoutCase | ConvertFrom-Json) } catch { $docCase = $null }
Assert-That ($proc7.ExitCode -eq 0) 'caixa: exit 0' ("exit=$($proc7.ExitCode) out=$stdoutCase")
$ku = @()
$kl = @()
try {
    $ku = @($docCase.groups | Where-Object { ($_.event -ceq 'OK') -and ($_.trigger_reason -ceq 'route-uncertain') -and ($_.mode -ceq 'shadow') })
    $kl = @($docCase.groups | Where-Object { ($_.event -ceq 'ok') -and ($_.trigger_reason -ceq 'route-uncertain') -and ($_.mode -ceq 'shadow') })
} catch { $ku = @(); $kl = @() }
Assert-That ((@($docCase.groups).Count -eq 2) -and (@($ku).Count -eq 1) -and ([int]$ku[0].count -eq 1) -and (@($kl).Count -eq 1) -and ([int]$kl[0].count -eq 1)) 'caixa: OK vs ok distintos 1+1' $stdoutCase

Write-Host ("TOTAL=$total PASSED=$passed FAILED=" + ($total - $passed))
if ($passed -ne $total) { exit 1 }
exit 0
