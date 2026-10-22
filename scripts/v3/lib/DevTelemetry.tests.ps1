<#!
.SYNOPSIS
    Tests for DevTelemetry.ps1 (slice 1, aggregate-only local telemetry).
.DESCRIPTION
    Standalone suite (no Pester). Uses synthetic values only, TEMP fixtures
    owned by this suite. Run: powershell -NoProfile -File <this-file>.
    Exit 0/1, one [PASS]/[FAIL] line per check. PS 5.1 and PS7.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$libPath = Join-Path $PSScriptRoot 'DevTelemetry.ps1'
. $libPath

$script:total = 0
$script:passed = 0
$script:skipped = 0
function Assert-That($condition, $name, $detail) {
    $script:total++
    if ($condition) { $script:passed++; Write-Host ("[PASS] " + $name) }
    else { Write-Host ("[FAIL] " + $name + " -- " + $detail) }
}

function Skip-DevTele($name, $reason) {
    $script:skipped++
    Write-Host ("[SKIP] " + $name + " -- " + $reason)
}

function New-DevTeleTempRepo {
    $p = Join-Path ([IO.Path]::GetTempPath()) ('devtele-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    return $p
}

function Remove-DevTeleTempRepo([string]$Path) {
    try { if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
}

try {
    Assert-That (Test-Path -LiteralPath $libPath -PathType Leaf) 'lib file exists' 'missing DevTelemetry.ps1'

    # 1. normalization: invalid kind => null
    $badKind = $null
    try { $badKind = New-DevTelemetryEvent -Kind 'nope_kind' -Source 'run-v3-tests' } catch { $badKind = 'THREW' }
    Assert-That ($null -eq $badKind) 'invalid kind returns null' ([string]$badKind)

    # 2. invalid source => null
    $badSrc = $null
    try { $badSrc = New-DevTelemetryEvent -Kind 'suite_result' -Source 'has space/bad' } catch { $badSrc = 'THREW' }
    Assert-That ($null -eq $badSrc) 'invalid source returns null' ([string]$badSrc)

    # 3. counts clamp: negative => 0, huge => 1000000, bad key dropped
    $evC = $null
    try { $evC = New-DevTelemetryEvent -Kind 'gate_result' -Source 'package-consistency' -Verdict 'PASS' -Counts @{ pass = 3; fail = -5; total = 99999999; 'BAD KEY' = 1 } } catch { $evC = $null }
    $clampOk = $false
    try {
        $clampOk = (($null -ne $evC) -and ([int]$evC.counts.pass -eq 3) -and ([int]$evC.counts.fail -eq 0) -and ([int]$evC.counts.total -eq 1000000))
        $hasBad = $false
        foreach ($pp in @($evC.counts.PSObject.Properties)) { if ($pp.Name -ceq 'BAD KEY') { $hasBad = $true } }
        $clampOk = ($clampOk -and (-not $hasBad))
    } catch { $clampOk = $false }
    Assert-That $clampOk 'counts clamped and bad key dropped' 'counts wrong'

    # 4. invalid suite dropped, event still valid
    $evS = $null
    try { $evS = New-DevTelemetryEvent -Kind 'suite_result' -Source 'run-v3-tests' -Suite 'bad/suite path' -Verdict 'PASS' } catch { $evS = $null }
    $suiteOk = $false
    try {
        $suiteOk = (($null -ne $evS) -and ($null -eq ($evS.PSObject.Properties | Where-Object { $_.Name -ceq 'suite' } | Select-Object -First 1)))
    } catch { $suiteOk = $false }
    Assert-That $suiteOk 'invalid suite dropped, event kept' 'suite handling wrong'

    # 5. confined write in TEMP repo
    $tmpRepo = New-DevTeleTempRepo
    try {
        $okW = $false
        try { $okW = Write-DevTelemetryEvent -Kind 'suite_result' -Source 'run-v3-tests' -Suite 'alpha.tests' -Verdict 'PASS' -ExitCode 0 -DurationMs 120 -Engine 'ps51' -RepoRoot $tmpRepo } catch { $okW = 'THREW' }
        Assert-That ($okW -eq $true) 'confined write returns true' ([string]$okW)
        $devDir = Join-Path $tmpRepo 'cache\v3\telemetry\dev'
        $files = @()
        try { $files = @(Get-ChildItem -LiteralPath $devDir -Filter 'dev-*.jsonl' -File -ErrorAction Stop) } catch { $files = @() }
        Assert-That (@($files).Count -eq 1) 'one dev jsonl created in TEMP repo' ([string]@($files).Count)
        if (@($files).Count -ge 1) {
            $txt = [IO.File]::ReadAllText($files[0].FullName, [Text.Encoding]::UTF8)
            Assert-That (($txt -match 'alpha.tests') -and ($txt -match 'suite_result')) 'jsonl line has suite+kind' 'content missing'
        }
        $outside = Join-Path ([IO.Path]::GetTempPath()) ('devtele-out-' + [guid]::NewGuid().ToString('N') + '.jsonl')
        $okOut = $false
        try { $okOut = Write-DevTelemetryEvent -Kind 'suite_result' -Source 'run-v3-tests' -Suite 'alpha.tests' -Verdict 'PASS' -RepoRoot $tmpRepo -TelemetryPath $outside } catch { $okOut = 'THREW' }
        Assert-That ($okOut -eq $false) 'write outside allowed dir refused' ([string]$okOut)
        Assert-That (-not (Test-Path -LiteralPath $outside)) 'no file created outside' $outside

        # 6. secret canary never persisted
        $canary = 'sk-SYNTHETICSECRET0123456789ABCDEF'
        $okCan = $false
        try { $okCan = Write-DevTelemetryEvent -Kind 'suite_result' -Source 'run-v3-tests' -Suite 'alpha.tests' -Verdict 'PASS' -Detail $canary -RepoRoot $tmpRepo } catch { $okCan = 'THREW' }
        $allTxt = ''
        try {
            foreach ($ff in @(Get-ChildItem -LiteralPath $devDir -Filter 'dev-*.jsonl' -File -ErrorAction Stop)) {
                $allTxt += [IO.File]::ReadAllText($ff.FullName, [Text.Encoding]::UTF8)
            }
        } catch { }
        Assert-That (($allTxt -notmatch 'SYNTHETICSECRET')) 'canary never in file' 'canary leaked'

        # 7. snapshot with 4 synthetic events
        $e1 = New-DevTelemetryEvent -Kind 'suite_result' -Source 'run-v3-tests' -Suite 'suite-a' -Verdict 'FAIL' -DurationMs 100 -Timestamp '2026-10-01T10:00:00Z'
        $e2 = New-DevTelemetryEvent -Kind 'suite_result' -Source 'run-v3-tests' -Suite 'suite-a' -Verdict 'PASS' -DurationMs 200 -Timestamp '2026-10-02T10:00:00Z'
        $e3 = New-DevTelemetryEvent -Kind 'suite_result' -Source 'run-v3-tests' -Suite 'suite-b' -Verdict 'PASS' -DurationMs 300 -Timestamp '2026-10-02T11:00:00Z'
        $e4 = New-DevTelemetryEvent -Kind 'preflight_decision' -Source 'preflight' -Decision 'SINGLE_WORKER' -TaskClass 'trivial' -Risk 'low' -Agents @('coder') -Verdict 'UNKNOWN' -Timestamp '2026-10-02T12:00:00Z'
        $e5 = New-DevTelemetryEvent -Kind 'gate_result' -Source 'package-consistency' -Verdict 'PASS' -Counts @{ pass = 15; fail = 1; total = 16 } -Timestamp '2026-10-02T13:00:00Z'
        $snap = New-DevTelemetrySnapshot -Events @($e1, $e2, $e3, $e4, $e5) -WindowDays 30 -GeneratedAt '2026-10-03T00:00:00Z'
        $snapOk = $false
        try {
            $snapOk = (($null -ne $snap) -and ([int]$snap.raw.events -eq 5) -and ([int]$snap.totals.suite_runs -eq 3) -and ([int]$snap.totals.pass -eq 2) -and ([int]$snap.totals.fail -eq 1))
        } catch { $snapOk = $false }
        Assert-That $snapOk 'snapshot totals pass/fail' 'totals wrong'
        $rateOk = $false
        try { $rateOk = (([double]$snap.totals.pass_rate -gt 0.66) -and ([double]$snap.totals.pass_rate -lt 0.67)) } catch { $rateOk = $false }
        Assert-That $rateOk 'pass_rate 2/3' ([string]$snap.totals.pass_rate)
        $skipSepOk = $false
        try { $skipSepOk = (([int]$snap.totals.skip -eq 0) -and ([int]$snap.totals.error -eq 0)) } catch { $skipSepOk = $false }
        Assert-That $skipSepOk 'skip/error reported separately in totals' 'skip/error wrong'

        # 7b. SKIP does not dilute pass_rate: 2 PASS, 1 FAIL, 5 SKIP => 0.6667 (not 0.25)
        $skP1 = New-DevTelemetryEvent -Kind 'suite_result' -Source 'run-v3-tests' -Suite 'suite-skip' -Verdict 'PASS' -DurationMs 10 -Timestamp '2026-10-02T10:00:00Z'
        $skP2 = New-DevTelemetryEvent -Kind 'suite_result' -Source 'run-v3-tests' -Suite 'suite-skip' -Verdict 'PASS' -DurationMs 20 -Timestamp '2026-10-02T10:01:00Z'
        $skF1 = New-DevTelemetryEvent -Kind 'suite_result' -Source 'run-v3-tests' -Suite 'suite-skip' -Verdict 'FAIL' -DurationMs 30 -Timestamp '2026-10-02T10:02:00Z'
        $skS1 = New-DevTelemetryEvent -Kind 'suite_result' -Source 'run-v3-tests' -Suite 'suite-skip' -Verdict 'SKIP' -DurationMs 0 -Timestamp '2026-10-02T10:03:00Z'
        $skS2 = New-DevTelemetryEvent -Kind 'suite_result' -Source 'run-v3-tests' -Suite 'suite-skip' -Verdict 'SKIP' -DurationMs 0 -Timestamp '2026-10-02T10:04:00Z'
        $skS3 = New-DevTelemetryEvent -Kind 'suite_result' -Source 'run-v3-tests' -Suite 'suite-skip' -Verdict 'SKIP' -DurationMs 0 -Timestamp '2026-10-02T10:05:00Z'
        $skS4 = New-DevTelemetryEvent -Kind 'suite_result' -Source 'run-v3-tests' -Suite 'suite-skip' -Verdict 'SKIP' -DurationMs 0 -Timestamp '2026-10-02T10:06:00Z'
        $skS5 = New-DevTelemetryEvent -Kind 'suite_result' -Source 'run-v3-tests' -Suite 'suite-skip' -Verdict 'SKIP' -DurationMs 0 -Timestamp '2026-10-02T10:07:00Z'
        $snapSk = New-DevTelemetrySnapshot -Events @($skP1, $skP2, $skF1, $skS1, $skS2, $skS3, $skS4, $skS5) -WindowDays 30 -GeneratedAt '2026-10-03T00:00:00Z'
        $skipRateOk = $false
        try {
            $skipRateOk = (($null -ne $snapSk) -and ([int]$snapSk.totals.suite_runs -eq 8) -and ([int]$snapSk.totals.pass -eq 2) -and ([int]$snapSk.totals.fail -eq 1) -and ([int]$snapSk.totals.skip -eq 5) -and ([double]$snapSk.totals.pass_rate -gt 0.66) -and ([double]$snapSk.totals.pass_rate -lt 0.67))
        } catch { $skipRateOk = $false }
        Assert-That $skipRateOk 'SKIP excluded: 2 PASS 1 FAIL 5 SKIP => 0.6667' 'skip diluted pass_rate'
        $skipRowOk = $false
        try {
            $rowSk = @($snapSk.suites | Where-Object { $_.suite -ceq 'suite-skip' } | Select-Object -First 1)
            $skipRowOk = ((@($rowSk).Count -eq 1) -and ([int]$rowSk[0].skip -eq 5) -and ([double]$rowSk[0].pass_rate -gt 0.66) -and ([double]$rowSk[0].pass_rate -lt 0.67))
        } catch { $skipRowOk = $false }
        Assert-That $skipRowOk 'per-suite pass_rate ignores SKIP' 'suite row diluted'

        # 7c. zero denominator (SKIP only) => 0.0
        $zS1 = New-DevTelemetryEvent -Kind 'suite_result' -Source 'run-v3-tests' -Suite 'suite-zero' -Verdict 'SKIP' -DurationMs 0 -Timestamp '2026-10-02T10:00:00Z'
        $zS2 = New-DevTelemetryEvent -Kind 'suite_result' -Source 'run-v3-tests' -Suite 'suite-zero' -Verdict 'SKIP' -DurationMs 0 -Timestamp '2026-10-02T10:01:00Z'
        $snapZero = New-DevTelemetrySnapshot -Events @($zS1, $zS2) -WindowDays 30 -GeneratedAt '2026-10-03T00:00:00Z'
        $zeroOk = $false
        try {
            $zeroOk = (($null -ne $snapZero) -and ([int]$snapZero.totals.skip -eq 2) -and ([double]$snapZero.totals.pass_rate -eq 0.0))
        } catch { $zeroOk = $false }
        Assert-That $zeroOk 'SKIP-only snapshot pass_rate 0.0' 'zero denominator wrong'
        $zeroRowOk = $false
        try {
            $rowZ = @($snapZero.suites | Where-Object { $_.suite -ceq 'suite-zero' } | Select-Object -First 1)
            $zeroRowOk = ((@($rowZ).Count -eq 1) -and ([double]$rowZ[0].pass_rate -eq 0.0))
        } catch { $zeroRowOk = $false }
        Assert-That $zeroRowOk 'SKIP-only suite pass_rate 0.0' 'suite zero wrong'
        $flakyOk = $false
        try { $flakyOk = ((@($snap.flaky).Count -eq 1) -and ([string]$snap.flaky[0].suite -ceq 'suite-a')) } catch { $flakyOk = $false }
        Assert-That $flakyOk 'flaky FAIL->PASS detected' 'flaky wrong'
        $p95Ok = $false
        try {
            $rowA = @($snap.suites | Where-Object { $_.suite -ceq 'suite-a' } | Select-Object -First 1)
            $p95Ok = ((@($rowA).Count -eq 1) -and ([long]$rowA[0].p95_ms -eq 200))
        } catch { $p95Ok = $false }
        Assert-That $p95Ok 'p95 nearest-rank suite-a=200' 'p95 wrong'
        $preOk = $false
        try { $preOk = (([int]$snap.preflight.total -eq 1) -and ([int]$snap.gates.reports -eq 1) -and ([int]$snap.gates.checks_total -eq 16) -and ([int]$snap.gates.checks_fail -eq 1)) } catch { $preOk = $false }
        Assert-That $preOk 'preflight+gates aggregated' 'preflight/gates wrong'

        # 8. publish JSON+MD in TEMP repo
        $tmpRepo2 = New-DevTeleTempRepo
        try {
            $w1 = Write-DevTelemetryEvent -Kind 'suite_result' -Source 'run-v3-tests' -Suite 'pub.tests' -Verdict 'PASS' -ExitCode 0 -DurationMs 50 -Engine 'ps51' -RepoRoot $tmpRepo2
            Assert-That ($w1 -eq $true) 'publish fixture write ok' ([string]$w1)
            $snap2 = Export-DevTelemetrySnapshot -RepoRoot $tmpRepo2 -WindowDays 30 -Publish -Now '2026-10-06T12:00:00Z'
            Assert-That ($null -ne $snap2) 'publish export returns snapshot' 'null snapshot'
            $cj = Join-Path $tmpRepo2 'cache\v3\dev-metrics\latest.json'
            $cm = Join-Path $tmpRepo2 'cache\v3\dev-metrics\latest.md'
            $pj = Join-Path $tmpRepo2 'evidence\dev-telemetry\latest.json'
            $pm = Join-Path $tmpRepo2 'evidence\dev-telemetry\latest.md'
            Assert-That ((Test-Path -LiteralPath $cj) -and (Test-Path -LiteralPath $cm) -and (Test-Path -LiteralPath $pj) -and (Test-Path -LiteralPath $pm)) 'publish writes cache+evidence latest files' 'missing files'
            $hist = @()
            try { $hist = @(Get-ChildItem -LiteralPath (Join-Path $tmpRepo2 'evidence\dev-telemetry\history') -Filter '*.json' -File -ErrorAction Stop) } catch { $hist = @() }
            Assert-That (@($hist).Count -eq 1) 'publish writes one history file' ([string]@($hist).Count)
            if (@($hist).Count -ge 1) {
                $hj = [IO.File]::ReadAllText($hist[0].FullName, [Text.Encoding]::UTF8)
                Assert-That (($hj -match 'aggregate only; nothing leaves this machine') -and ($hj -match '"schema"')) 'history json has schema+note' 'bad history json'
            }
            $mdTxt = ''
            try { $mdTxt = [IO.File]::ReadAllText($pm, [Text.Encoding]::UTF8) } catch { $mdTxt = '' }
            Assert-That (($mdTxt -match 'resumo') -and ($mdTxt -match 'preflight')) 'published md has sections' 'bad md'
        }
        finally { Remove-DevTeleTempRepo $tmpRepo2 }

        # 9. retention: old file removed, recent kept
        $tmpRepo3 = New-DevTeleTempRepo
        try {
            $dd = Join-Path $tmpRepo3 'cache\v3\telemetry\dev'
            New-Item -ItemType Directory -Path $dd -Force | Out-Null
            $obsDest = Join-Path $tmpRepo3 'scripts\v3\lib\CapabilityObservability.ps1'
            New-Item -ItemType Directory -Path (Split-Path -Parent $obsDest) -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'CapabilityObservability.ps1') -Destination $obsDest -Force
            $oldStamp = ([DateTimeOffset]::UtcNow.AddDays(-40)).ToString('yyyyMMdd')
            $newStamp = ([DateTimeOffset]::UtcNow).ToString('yyyyMMdd')
            [IO.File]::WriteAllText((Join-Path $dd ('dev-' + $oldStamp + '.jsonl')), "{`"schema`":1}`n", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $dd ('dev-' + $newStamp + '.jsonl')), "{`"schema`":1}`n", [Text.Encoding]::UTF8)
            $rr = $null
            try { $rr = Invoke-DevTelemetryRetention -RepoRoot $tmpRepo3 -RetentionDays 30 } catch { $rr = 'THREW' }
            Assert-That ($rr -ne 'THREW') 'retention never throws' ([string]$rr)
            Assert-That (-not (Test-Path -LiteralPath (Join-Path $dd ('dev-' + $oldStamp + '.jsonl')))) 'old file removed' 'old kept'
            Assert-That (Test-Path -LiteralPath (Join-Path $dd ('dev-' + $newStamp + '.jsonl'))) 'recent file kept' 'recent removed'
        }
        finally { Remove-DevTeleTempRepo $tmpRepo3 }

        # 10. adversarial read sanitization: secret suite/detail dropped, schema:0 ignored
        $tmpRepo4 = New-DevTeleTempRepo
        try {
            $dd4 = Join-Path $tmpRepo4 'cache\v3\telemetry\dev'
            New-Item -ItemType Directory -Path $dd4 -Force | Out-Null
            $tsNow = ([DateTimeOffset]::UtcNow.ToString('o'))
            $dayStamp = ([DateTimeOffset]::UtcNow.ToString('yyyyMMdd'))
            $rawFile = Join-Path $dd4 ('dev-' + $dayStamp + '.jsonl')
            $advLine = '{"schema":1,"timestamp":"' + $tsNow + '","kind":"suite_result","source":"test","suite":"sk-SYNTHETICSECRET0123456789ABCDEF","detail":"C:\\Users\\secret\\file.txt","verdict":"PASS"}'
            $zeroLine = '{"schema":0,"timestamp":"' + $tsNow + '","kind":"suite_result","source":"test","suite":"zero.tests","verdict":"PASS"}'
            $goodLine = '{"schema":1,"timestamp":"' + $tsNow + '","kind":"suite_result","source":"test","suite":"good.tests","verdict":"PASS","duration_ms":10}'
            [IO.File]::WriteAllText($rawFile, ($advLine + "`n" + $zeroLine + "`n" + $goodLine + "`n"), [Text.UTF8Encoding]::new($false))
            $snapA = $null
            try { $snapA = Export-DevTelemetrySnapshot -RepoRoot $tmpRepo4 -WindowDays 30 -Publish -Now $tsNow } catch { $snapA = 'THREW' }
            Assert-That (($snapA -ne 'THREW') -and ($null -ne $snapA)) 'adversarial export never throws' ([string]$snapA)
            $evCount = -1
            try { $evCount = [int]$snapA.raw.events } catch { $evCount = -1 }
            Assert-That ($evCount -eq 2) 'schema:0 ignored, adversarial normalized (events=2)' ([string]$evCount)
            $pjA = Join-Path $tmpRepo4 'evidence\dev-telemetry\latest.json'
            $pmA = Join-Path $tmpRepo4 'evidence\dev-telemetry\latest.md'
            $cjA = Join-Path $tmpRepo4 'cache\v3\dev-metrics\latest.json'
            $allPub = ''
            try {
                $allPub += [IO.File]::ReadAllText($pjA, [Text.Encoding]::UTF8)
                $allPub += [IO.File]::ReadAllText($pmA, [Text.Encoding]::UTF8)
                $allPub += [IO.File]::ReadAllText($cjA, [Text.Encoding]::UTF8)
            } catch { $allPub = 'READFAIL' }
            Assert-That (($allPub -notmatch 'SYNTHETICSECRET')) 'canary suite absent from snapshots' 'canary leaked'
            Assert-That (($allPub -notmatch 'Users')) 'canary path absent from snapshots' 'path leaked'
            $suiteNames = ''
            try { $suiteNames = ((@($snapA.suites) | ForEach-Object { [string]$_.suite }) -join ',') } catch { $suiteNames = 'READFAIL' }
            Assert-That (($suiteNames -notmatch 'SYNTHETICSECRET') -and ($suiteNames -notmatch 'zero')) 'invalid suite not aggregated' $suiteNames
            Assert-That ($suiteNames -match 'good.tests') 'valid suite aggregated' $suiteNames
        }
        finally { Remove-DevTeleTempRepo $tmpRepo4 }

        # 11. junction reparse: history junction to external dir => publish refused, external untouched
        $tmpRepo5 = New-DevTeleTempRepo
        try {
            $extDir = Join-Path ([IO.Path]::GetTempPath()) ('devext-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $extDir -Force | Out-Null
            $canaryPath = Join-Path $extDir 'canary.txt'
            [IO.File]::WriteAllText($canaryPath, 'EXTERNAL-CANARY-DO-NOT-TOUCH', [Text.UTF8Encoding]::new($false))
            $beforeCount = @((Get-ChildItem -LiteralPath $extDir -File -Force -ErrorAction SilentlyContinue)).Count
            $pubDir5 = Join-Path $tmpRepo5 'evidence\dev-telemetry'
            New-Item -ItemType Directory -Path $pubDir5 -Force | Out-Null
            $histLink = Join-Path $pubDir5 'history'
            $linkOk = $false
            try { New-Item -ItemType Junction -Path $histLink -Value $extDir -ErrorAction Stop | Out-Null; $linkOk = $true } catch { $linkOk = $false }
            if (-not $linkOk) {
                try { New-Item -ItemType Junction -Path $histLink -Target $extDir -ErrorAction Stop | Out-Null; $linkOk = $true } catch { $linkOk = $false }
            }
            if (-not $linkOk) {
                try { & cmd /c mklink /J $histLink $extDir 2>$null | Out-Null; if (Test-Path -LiteralPath $histLink) { $linkOk = $true } } catch { $linkOk = $false }
            }
            if (-not $linkOk) {
                Skip-DevTele 'junction publish refused' 'cannot create junction in this environment'
            }
            else {
                Assert-That ((Test-DevTelemetryReparse -Path $histLink) -eq $true) 'junction detected as reparse' 'not detected'
                $w5 = $false
                try { $w5 = Write-DevTelemetryEvent -Kind 'suite_result' -Source 'run-v3-tests' -Suite 'jun.tests' -Verdict 'PASS' -RepoRoot $tmpRepo5 } catch { $w5 = 'THREW' }
                Assert-That ($w5 -eq $true) 'fixture write ok before refused publish' ([string]$w5)
                $snapJ = 'NOTRUN'
                try { $snapJ = Export-DevTelemetrySnapshot -RepoRoot $tmpRepo5 -WindowDays 30 -Publish } catch { $snapJ = 'THREW' }
                Assert-That ($snapJ -ne 'THREW') 'refused publish never throws' ([string]$snapJ)
                Assert-That ($null -eq $snapJ) 'publish refused on history junction' ([string]$snapJ)
                $canaryAfter = ''
                try { $canaryAfter = [IO.File]::ReadAllText($canaryPath, [Text.Encoding]::UTF8) } catch { $canaryAfter = 'READFAIL' }
                Assert-That ($canaryAfter -ceq 'EXTERNAL-CANARY-DO-NOT-TOUCH') 'external canary unaltered' $canaryAfter
                $afterCount = @((Get-ChildItem -LiteralPath $extDir -File -Force -ErrorAction SilentlyContinue)).Count
                Assert-That ($afterCount -eq $beforeCount) 'no file added to external dir' ([string]$afterCount)
            }
            try { Remove-Item -LiteralPath $extDir -Recurse -Force -ErrorAction SilentlyContinue | Out-Null } catch { }
        }
        finally { Remove-DevTeleTempRepo $tmpRepo5 }

        # 11b. destination symlink: cache latest.json as symlink => export refused (or WARN when symlink creation is unavailable)
        $tmpRepo5b = New-DevTeleTempRepo
        try {
            $w5b = $false
            try { $w5b = Write-DevTelemetryEvent -Kind 'suite_result' -Source 'run-v3-tests' -Suite 'sym.tests' -Verdict 'PASS' -RepoRoot $tmpRepo5b } catch { $w5b = 'THREW' }
            Assert-That ($w5b -eq $true) 'symlink fixture write ok' ([string]$w5b)
            $cacheDir5b = Join-Path $tmpRepo5b 'cache\v3\dev-metrics'
            New-Item -ItemType Directory -Path $cacheDir5b -Force | Out-Null
            $extFile = Join-Path ([IO.Path]::GetTempPath()) ('devextfile-' + [guid]::NewGuid().ToString('N') + '.json')
            [IO.File]::WriteAllText($extFile, 'EXTERNAL-FILE-DO-NOT-TOUCH', [Text.UTF8Encoding]::new($false))
            $destLink = Join-Path $cacheDir5b 'latest.json'
            $symOk = $false
            try { New-Item -ItemType SymbolicLink -Path $destLink -Target $extFile -ErrorAction Stop | Out-Null; $symOk = $true } catch { $symOk = $false }
            if (-not $symOk) {
                try { New-Item -ItemType SymbolicLink -Path $destLink -Value $extFile -ErrorAction Stop | Out-Null; $symOk = $true } catch { $symOk = $false }
            }
            if (-not $symOk) {
                # WARN (not [SKIP]): kept skipped in the summary count, but must not
                # emit a ^[SKIP] line or run-v3-tests.ps1 marks the whole suite SKIP.
                $script:skipped++
                Write-Host 'WARN: symlink test skipped -- cannot create symlink in this environment'
            }
            else {
                $snapS = 'NOTRUN'
                try { $snapS = Export-DevTelemetrySnapshot -RepoRoot $tmpRepo5b -WindowDays 30 } catch { $snapS = 'THREW' }
                Assert-That ($snapS -ne 'THREW') 'symlink export never throws' ([string]$snapS)
                Assert-That ($null -eq $snapS) 'export refused on symlinked dest' ([string]$snapS)
                $extAfter = ''
                try { $extAfter = [IO.File]::ReadAllText($extFile, [Text.Encoding]::UTF8) } catch { $extAfter = 'READFAIL' }
                Assert-That ($extAfter -ceq 'EXTERNAL-FILE-DO-NOT-TOUCH') 'external symlink target unaltered' $extAfter
            }
            try { Remove-Item -LiteralPath $extFile -Force -ErrorAction SilentlyContinue | Out-Null } catch { }
        }
        finally { Remove-DevTeleTempRepo $tmpRepo5b }

        # 12. bounded read: file > 4MB, valid line beyond cap ignored without throw
        $tmpRepo6 = New-DevTeleTempRepo
        try {
            $dd6 = Join-Path $tmpRepo6 'cache\v3\telemetry\dev'
            New-Item -ItemType Directory -Path $dd6 -Force | Out-Null
            $dayStamp6 = ([DateTimeOffset]::UtcNow.ToString('yyyyMMdd'))
            $bigFile = Join-Path $dd6 ('dev-' + $dayStamp6 + '.jsonl')
            $filler = New-Object string ('A', 102400)
            for ($i = 0; $i -lt 45; $i++) {
                [IO.File]::AppendAllText($bigFile, ($filler + "`n"), [Text.UTF8Encoding]::new($false))
            }
            $tsBig = ([DateTimeOffset]::UtcNow.ToString('o'))
            $bigLine = '{"schema":1,"timestamp":"' + $tsBig + '","kind":"suite_result","source":"test","suite":"big.tests","verdict":"PASS"}'
            [IO.File]::AppendAllText($bigFile, ($bigLine + "`n"), [Text.UTF8Encoding]::new($false))
            $bigLen = 0
            try { $bigLen = (Get-Item -LiteralPath $bigFile -Force).Length } catch { $bigLen = 0 }
            Assert-That ($bigLen -gt 4194304) 'fixture exceeds 4MB cap' ([string]$bigLen)
            $gotBig = $null
            $threwBig = $false
            try { $gotBig = @(Read-DevTelemetryEvents -RepoRoot $tmpRepo6 -SinceDays 30) } catch { $threwBig = $true; $gotBig = $null }
            Assert-That (-not $threwBig) 'read beyond cap never throws' 'threw'
            $foundBig = 1
            try { $foundBig = @($gotBig | Where-Object { ([string](Get-DevTelemetryNodeProp -Node $_ -Name 'suite')) -ceq 'big.tests' }).Count } catch { $foundBig = -1 }
            Assert-That ($foundBig -eq 0) 'event beyond 4MB cap truncated' ([string]$foundBig)
        }
        finally { Remove-DevTeleTempRepo $tmpRepo6 }

        # 13. automatic retention on write: old file removed, marker created, event kept
        $tmpRepo7 = New-DevTeleTempRepo
        try {
            $dd7 = Join-Path $tmpRepo7 'cache\v3\telemetry\dev'
            New-Item -ItemType Directory -Path $dd7 -Force | Out-Null
            $obsDest7 = Join-Path $tmpRepo7 'scripts\v3\lib\CapabilityObservability.ps1'
            New-Item -ItemType Directory -Path (Split-Path -Parent $obsDest7) -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'CapabilityObservability.ps1') -Destination $obsDest7 -Force
            [IO.File]::WriteAllText((Join-Path $dd7 'dev-20200101.jsonl'), "{`"schema`":1}`n", [Text.UTF8Encoding]::new($false))
            $w7 = $false
            try { $w7 = Write-DevTelemetryEvent -Kind 'suite_result' -Source 'run-v3-tests' -Suite 'auto.tests' -Verdict 'PASS' -RepoRoot $tmpRepo7 } catch { $w7 = 'THREW' }
            Assert-That ($w7 -eq $true) 'auto-retention write returns true' ([string]$w7)
            Assert-That (-not (Test-Path -LiteralPath (Join-Path $dd7 'dev-20200101.jsonl'))) 'auto-retention removed old file' 'old kept'
            $marker7 = Join-Path $dd7 ('.retention-' + ([DateTimeOffset]::UtcNow.ToString('yyyyMMdd')))
            Assert-That (Test-Path -LiteralPath $marker7 -PathType Leaf) 'retention marker of today exists' $marker7
            $newTxt7 = ''
            try {
                foreach ($ff in @(Get-ChildItem -LiteralPath $dd7 -Filter 'dev-*.jsonl' -File -ErrorAction Stop)) {
                    $newTxt7 += [IO.File]::ReadAllText($ff.FullName, [Text.Encoding]::UTF8)
                }
            } catch { }
            Assert-That ($newTxt7 -match 'auto.tests') 'new event persisted after auto-retention' 'event missing'
        }
        finally { Remove-DevTeleTempRepo $tmpRepo7 }

        # 14. atomic overwrite: locked dest => false, old content intact, no orphans; unlocked => new content wins
        $tmpRepo8 = New-DevTeleTempRepo
        try {
            $cacheDir8 = Join-Path $tmpRepo8 'cache\v3\dev-metrics'
            New-Item -ItemType Directory -Path $cacheDir8 -Force | Out-Null
            $dest8 = Join-Path $cacheDir8 'latest.json'
            $oldContent8 = '{"schema":1,"old":true}'
            [IO.File]::WriteAllText($dest8, $oldContent8, [Text.UTF8Encoding]::new($false))
            $fsLock = $null
            try { $fsLock = New-Object System.IO.FileStream($dest8, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None) } catch { $fsLock = $null }
            if ($null -eq $fsLock) {
                Skip-DevTele 'locked atomic write refused' 'cannot lock file in this environment'
            }
            else {
                $okLock = 'NOTRUN'
                try { $okLock = Write-DevTelemetryFileAtomic -Dest $dest8 -Content '{"schema":1,"new":true}' -AllowedDir $cacheDir8 -RepoRoot $tmpRepo8 -Encoding ([Text.UTF8Encoding]::new($false)) } catch { $okLock = 'THREW' }
                Assert-That ($okLock -eq $false) 'locked dest export returns false' ([string]$okLock)
                $afterLock = ''
                try { $afterLock = [IO.File]::ReadAllText($dest8, [Text.Encoding]::UTF8) } catch { $afterLock = 'READFAIL' }
                try { $fsLock.Close() } catch { }
                try { $fsLock.Dispose() } catch { }
                $fsLock = $null
                try { $afterLock = [IO.File]::ReadAllText($dest8, [Text.Encoding]::UTF8) } catch { $afterLock = 'READFAIL' }
                Assert-That ($afterLock -ceq $oldContent8) 'locked dest content intact' $afterLock
                $orphans = @()
                try { $orphans = @(Get-ChildItem -LiteralPath $cacheDir8 -File -Force -ErrorAction Stop | Where-Object { ($_.Name -match '\.tmp$') -or ($_.Name -match '\.bak$') }) } catch { $orphans = @('LISTFAIL') }
                Assert-That (@($orphans).Count -eq 0) 'no tmp/bak orphans after refused write' ([string]@($orphans).Count)
                $okOver = 'NOTRUN'
                try { $okOver = Write-DevTelemetryFileAtomic -Dest $dest8 -Content '{"schema":1,"new":true}' -AllowedDir $cacheDir8 -RepoRoot $tmpRepo8 -Encoding ([Text.UTF8Encoding]::new($false)) } catch { $okOver = 'THREW' }
                Assert-That ($okOver -eq $true) 'unlocked overwrite returns true' ([string]$okOver)
                $afterOver = ''
                try { $afterOver = [IO.File]::ReadAllText($dest8, [Text.Encoding]::UTF8) } catch { $afterOver = 'READFAIL' }
                Assert-That ($afterOver -ceq '{"schema":1,"new":true}') 'overwrite replaces content' $afterOver
                $orphans2 = @()
                try { $orphans2 = @(Get-ChildItem -LiteralPath $cacheDir8 -File -Force -ErrorAction Stop | Where-Object { ($_.Name -match '\.tmp$') -or ($_.Name -match '\.bak$') }) } catch { $orphans2 = @('LISTFAIL') }
                Assert-That (@($orphans2).Count -eq 0) 'no tmp/bak orphans after overwrite' ([string]@($orphans2).Count)
            }
        }
        finally {
            try { if ($null -ne $fsLock) { $fsLock.Close() } } catch { }
            try { if ($null -ne $fsLock) { $fsLock.Dispose() } } catch { }
            Remove-DevTeleTempRepo $tmpRepo8
        }

        # 15. invalid/missing/empty timestamp never enters aggregates
        $tmpRepo9 = New-DevTeleTempRepo
        try {
            $dd9 = Join-Path $tmpRepo9 'cache\v3\telemetry\dev'
            New-Item -ItemType Directory -Path $dd9 -Force | Out-Null
            $dayStamp9 = ([DateTimeOffset]::UtcNow.ToString('yyyyMMdd'))
            $rawFile9 = Join-Path $dd9 ('dev-' + $dayStamp9 + '.jsonl')
            $tsGood9 = ([DateTimeOffset]::UtcNow.ToString('o'))
            $good9 = '{"schema":1,"timestamp":"' + $tsGood9 + '","kind":"suite_result","source":"test","suite":"tsgood.tests","verdict":"PASS"}'
            $badTs9 = '{"schema":1,"timestamp":"not-a-date","kind":"suite_result","source":"test","suite":"badts.tests","verdict":"PASS"}'
            $noTs9 = '{"schema":1,"kind":"suite_result","source":"test","suite":"nots.tests","verdict":"PASS"}'
            $emptyTs9 = '{"schema":1,"timestamp":"","kind":"suite_result","source":"test","suite":"emptyts.tests","verdict":"PASS"}'
            [IO.File]::WriteAllText($rawFile9, ($good9 + "`n" + $badTs9 + "`n" + $noTs9 + "`n" + $emptyTs9 + "`n"), [Text.UTF8Encoding]::new($false))
            $got9 = @()
            try { $got9 = @(Read-DevTelemetryEvents -RepoRoot $tmpRepo9 -SinceDays 30) } catch { $got9 = @() }
            Assert-That (@($got9).Count -eq 1) 'only valid timestamp enters aggregates' ([string]@($got9).Count)
            $names9 = ''
            try { $names9 = ((@($got9) | ForEach-Object { [string](Get-DevTelemetryNodeProp -Node $_ -Name 'suite') }) -join ',') } catch { $names9 = 'READFAIL' }
            Assert-That (($names9 -match 'tsgood.tests') -and ($names9 -notmatch 'badts') -and ($names9 -notmatch 'nots') -and ($names9 -notmatch 'emptyts')) 'bad/missing/empty ts excluded' $names9
        }
        finally { Remove-DevTeleTempRepo $tmpRepo9 }

        # 16. truncated tail: 5MB single-space line beyond cap => no event; real EOF without trailing newline => accepted
        $tmpRepo10 = New-DevTeleTempRepo
        try {
            $dd10 = Join-Path $tmpRepo10 'cache\v3\telemetry\dev'
            New-Item -ItemType Directory -Path $dd10 -Force | Out-Null
            $dayStamp10 = ([DateTimeOffset]::UtcNow.ToString('yyyyMMdd'))
            $bigFile10 = Join-Path $dd10 ('dev-' + $dayStamp10 + '.jsonl')
            $spaces = New-Object string (' ', 5242880)
            [IO.File]::WriteAllText($bigFile10, $spaces, [Text.UTF8Encoding]::new($false))
            $tsBig10 = ([DateTimeOffset]::UtcNow.ToString('o'))
            [IO.File]::AppendAllText($bigFile10, ("`n" + '{"schema":1,"timestamp":"' + $tsBig10 + '","kind":"suite_result","source":"test","suite":"beyond.tests","verdict":"PASS"}' + "`n"), [Text.UTF8Encoding]::new($false))
            $got10 = $null
            $threw10 = $false
            try { $got10 = @(Read-DevTelemetryEvents -RepoRoot $tmpRepo10 -SinceDays 30) } catch { $threw10 = $true; $got10 = $null }
            Assert-That (-not $threw10) 'truncated tail read never throws' 'threw'
            $foundBeyond = -1
            try { $foundBeyond = @($got10 | Where-Object { ([string](Get-DevTelemetryNodeProp -Node $_ -Name 'suite')) -ceq 'beyond.tests' }).Count } catch { $foundBeyond = -1 }
            Assert-That ($foundBeyond -eq 0) 'event beyond cap with no LF in buffer discarded' ([string]$foundBeyond)
            $eofFile10 = Join-Path $dd10 ('dev-20200102.jsonl')
            $tsEof10 = ([DateTimeOffset]::UtcNow.ToString('o'))
            [IO.File]::WriteAllText($eofFile10, ('{"schema":1,"timestamp":"' + $tsEof10 + '","kind":"suite_result","source":"test","suite":"eof.tests","verdict":"PASS","duration_ms":7}'), [Text.UTF8Encoding]::new($false))
            $gotEof = @()
            try { $gotEof = @(Read-DevTelemetryEvents -RepoRoot $tmpRepo10 -SinceDays 30) } catch { $gotEof = @() }
            $foundEof = -1
            try { $foundEof = @($gotEof | Where-Object { ([string](Get-DevTelemetryNodeProp -Node $_ -Name 'suite')) -ceq 'eof.tests' }).Count } catch { $foundEof = -1 }
            Assert-That ($foundEof -eq 1) 'real EOF line without newline accepted' ([string]$foundEof)
        }
        finally { Remove-DevTeleTempRepo $tmpRepo10 }

        # 17. retention gate: error => no marker + false; success => marker + true
        $tmpRepo11 = New-DevTeleTempRepo
        try {
            $dd11 = Join-Path $tmpRepo11 'cache\v3\telemetry\dev'
            New-Item -ItemType Directory -Path $dd11 -Force | Out-Null
            function Invoke-DevTelemetryRetention { param([string]$RepoRoot = '', $RetentionDays = 30) return ([PSCustomObject]@{ Removed = 0; Kept = 0; RemovedFiles = @(); Error = 'boom' }) }
            $rErr = 'NOTRUN'
            try { $rErr = Invoke-DevTelemetryRetentionIfDue -RepoRoot $tmpRepo11 } catch { $rErr = 'THREW' }
            Assert-That ($rErr -eq $false) 'retention error returns false' ([string]$rErr)
            $marker11 = Join-Path $dd11 ('.retention-' + ([DateTimeOffset]::UtcNow.ToString('yyyyMMdd')))
            Assert-That (-not (Test-Path -LiteralPath $marker11)) 'no marker after retention error' $marker11
            function Invoke-DevTelemetryRetention { param([string]$RepoRoot = '', $RetentionDays = 30) return ([PSCustomObject]@{ Removed = 0; Kept = 1; RemovedFiles = @(); Error = '' }) }
            $rOk = 'NOTRUN'
            try { $rOk = Invoke-DevTelemetryRetentionIfDue -RepoRoot $tmpRepo11 } catch { $rOk = 'THREW' }
            Assert-That ($rOk -eq $true) 'retention success returns true' ([string]$rOk)
            Assert-That (Test-Path -LiteralPath $marker11 -PathType Leaf) 'marker present after retention success' $marker11
        }
        finally {
            Remove-Item -LiteralPath 'function:Invoke-DevTelemetryRetention' -ErrorAction SilentlyContinue | Out-Null
            try { . $libPath } catch { }
            Remove-DevTeleTempRepo $tmpRepo11
        }

        # 18. determinism: same -Now + same events => byte-identical JSON
        $tmpRepo12 = New-DevTeleTempRepo
        try {
            $w12 = Write-DevTelemetryEvent -Kind 'suite_result' -Source 'run-v3-tests' -Suite 'det.tests' -Verdict 'PASS' -ExitCode 0 -DurationMs 42 -Engine 'ps51' -Timestamp '2026-10-05T10:00:00Z' -RepoRoot $tmpRepo12
            Assert-That ($w12 -eq $true) 'determinism fixture write ok' ([string]$w12)
            $w12b = Write-DevTelemetryEvent -Kind 'gate_result' -Source 'package-consistency' -Verdict 'PASS' -Counts @{ pass = 15; fail = 1; total = 16 } -Timestamp '2026-10-05T11:00:00Z' -RepoRoot $tmpRepo12
            Assert-That ($w12b -eq $true) 'determinism gate fixture write ok' ([string]$w12b)
            $fixedNow = '2026-10-06T12:00:00Z'
            $s1 = $null
            try { $s1 = Export-DevTelemetrySnapshot -RepoRoot $tmpRepo12 -WindowDays 30 -Now $fixedNow } catch { $s1 = 'THREW' }
            Assert-That (($s1 -ne 'THREW') -and ($null -ne $s1)) 'first deterministic export ok' ([string]$s1)
            $j1 = ''
            try { $j1 = [IO.File]::ReadAllText((Join-Path $tmpRepo12 'cache\v3\dev-metrics\latest.json'), [Text.Encoding]::UTF8) } catch { $j1 = 'READFAIL' }
            $s2 = $null
            try { $s2 = Export-DevTelemetrySnapshot -RepoRoot $tmpRepo12 -WindowDays 30 -Now $fixedNow } catch { $s2 = 'THREW' }
            Assert-That (($s2 -ne 'THREW') -and ($null -ne $s2)) 'second deterministic export ok' ([string]$s2)
            $j2 = ''
            try { $j2 = [IO.File]::ReadAllText((Join-Path $tmpRepo12 'cache\v3\dev-metrics\latest.json'), [Text.Encoding]::UTF8) } catch { $j2 = 'READFAIL' }
            Assert-That (($j1 -ne 'READFAIL') -and ($j1 -ceq $j2)) 'same -Now exports byte-identical JSON' 'json differs'
            $genFixed = ''
            try { $genFixed = [string]$s2.generated_at } catch { $genFixed = 'READFAIL' }
            Assert-That ($genFixed -ceq '2026-10-06T12:00:00.0000000+00:00') 'generated_at pinned to -Now' $genFixed
        }
        finally { Remove-DevTeleTempRepo $tmpRepo12 }

        # 19. round-trip: gate_result counts read from JSONL land in snapshot
        $tmpRepo13 = New-DevTeleTempRepo
        try {
            $w13 = Write-DevTelemetryEvent -Kind 'gate_result' -Source 'package-consistency' -Verdict 'PASS' -Counts @{ pass = 15; fail = 1; total = 16 } -Timestamp '2026-10-05T11:00:00Z' -RepoRoot $tmpRepo13
            Assert-That ($w13 -eq $true) 'gate round-trip write ok' ([string]$w13)
            $snap13 = $null
            try { $snap13 = Export-DevTelemetrySnapshot -RepoRoot $tmpRepo13 -WindowDays 30 -Now '2026-10-06T12:00:00Z' } catch { $snap13 = $null }
            $gateOk = $false
            try {
                $gateOk = (($null -ne $snap13) -and ([int]$snap13.gates.reports -eq 1) -and ([int]$snap13.gates.checks_total -eq 16) -and ([int]$snap13.gates.checks_fail -eq 1))
            } catch { $gateOk = $false }
            Assert-That $gateOk 'gate_result counts round-trip into snapshot' 'gates wrong'
        }
        finally { Remove-DevTeleTempRepo $tmpRepo13 }

        # 20. schema strict: only integer 1 accepted (true/1.4/"1"/null/0/2 rejected)
        $tmpRepo14 = New-DevTeleTempRepo
        try {
            $dd14 = Join-Path $tmpRepo14 'cache\v3\telemetry\dev'
            New-Item -ItemType Directory -Path $dd14 -Force | Out-Null
            $dayStamp14 = ([DateTimeOffset]::UtcNow.ToString('yyyyMMdd'))
            $rawFile14 = Join-Path $dd14 ('dev-' + $dayStamp14 + '.jsonl')
            $ts14 = ([DateTimeOffset]::UtcNow.ToString('o'))
            $lTrue = '{"schema":true,"timestamp":"' + $ts14 + '","kind":"suite_result","source":"test","suite":"schema-bool.tests","verdict":"PASS"}'
            $lFloat = '{"schema":1.4,"timestamp":"' + $ts14 + '","kind":"suite_result","source":"test","suite":"schema-float.tests","verdict":"PASS"}'
            $lStr = '{"schema":"1","timestamp":"' + $ts14 + '","kind":"suite_result","source":"test","suite":"schema-str.tests","verdict":"PASS"}'
            $lNull = '{"schema":null,"timestamp":"' + $ts14 + '","kind":"suite_result","source":"test","suite":"schema-null.tests","verdict":"PASS"}'
            $lZero = '{"schema":0,"timestamp":"' + $ts14 + '","kind":"suite_result","source":"test","suite":"schema-zero.tests","verdict":"PASS"}'
            $lTwo = '{"schema":2,"timestamp":"' + $ts14 + '","kind":"suite_result","source":"test","suite":"schema-two.tests","verdict":"PASS"}'
            $lOne = '{"schema":1,"timestamp":"' + $ts14 + '","kind":"suite_result","source":"test","suite":"schema-one.tests","verdict":"PASS"}'
            [IO.File]::WriteAllText($rawFile14, ($lTrue + "`n" + $lFloat + "`n" + $lStr + "`n" + $lNull + "`n" + $lZero + "`n" + $lTwo + "`n" + $lOne + "`n"), [Text.UTF8Encoding]::new($false))
            $got14 = @()
            try { $got14 = @(Read-DevTelemetryEvents -RepoRoot $tmpRepo14 -SinceDays 30) } catch { $got14 = @() }
            Assert-That (@($got14).Count -eq 1) 'strict schema: only integer 1 enters aggregates' ([string]@($got14).Count)
            $names14 = ''
            try { $names14 = ((@($got14) | ForEach-Object { [string](Get-DevTelemetryNodeProp -Node $_ -Name 'suite') }) -join ',') } catch { $names14 = 'READFAIL' }
            Assert-That (($names14 -ceq 'schema-one.tests')) 'strict schema: schema-one kept, others dropped' $names14
        }
        finally { Remove-DevTeleTempRepo $tmpRepo14 }

        # 21. ISO week at year boundaries (Thursday rule)
        $isoCases = @(
            @('2026-10-21T12:00:00Z', '2026-W43'),
            @('2025-12-29T12:00:00Z', '2026-W01'),
            @('2021-01-01T12:00:00Z', '2020-W53'),
            @('2024-12-30T12:00:00Z', '2025-W01'),
            @('2026-01-01T12:00:00Z', '2026-W01')
        )
        foreach ($c in $isoCases) {
            $gotW = ''
            try { $gotW = Get-DevTelemetryIsoWeekFile -Timestamp $c[0] } catch { $gotW = 'THREW' }
            Assert-That ($gotW -ceq $c[1]) ('iso week ' + $c[0] + ' => ' + $c[1]) ([string]$gotW)
        }

        # 22. round-trip metrics: plugin_health ints+bool preserved into snapshot
        $tmpRepo15 = New-DevTeleTempRepo
        try {
            $w15 = $false
            try { $w15 = Write-DevTelemetryEvent -Kind 'plugin_health' -Source 'telemetry-test' -Verdict 'PASS' -Metrics @{ load_errors = 2; expected_load_errors = 3; telemetry_present = $true; plugins_present = 4 } -Timestamp '2026-10-05T11:00:00Z' -RepoRoot $tmpRepo15 } catch { $w15 = 'THREW' }
            Assert-That ($w15 -eq $true) 'plugin_health metrics write ok' ([string]$w15)
            $snap15 = $null
            try { $snap15 = Export-DevTelemetrySnapshot -RepoRoot $tmpRepo15 -WindowDays 30 -Now '2026-10-06T12:00:00Z' } catch { $snap15 = $null }
            $plugOk = $false
            try {
                $plugOk = (($null -ne $snap15) -and ([int]$snap15.plugin.reports -eq 1) -and ([int]$snap15.plugin.latest_load_errors -eq 2) -and ([int]$snap15.plugin.latest_expected_load_errors -eq 3) -and ([int]$snap15.plugin.latest_telemetry_present -eq 1) -and ($snap15.plugin.latest_telemetry_present -eq $true) -and ([int]$snap15.plugin.latest_plugins_present -eq 4))
            } catch { $plugOk = $false }
            Assert-That $plugOk 'plugin_health metrics round-trip into snapshot' 'plugin metrics wrong'
        }
        finally { Remove-DevTeleTempRepo $tmpRepo15 }

        # 23. record CLI: APPROVED recorded in child process, INVALID rejected (subprocess, split stdout/stderr)
        $tmpCli = New-DevTeleTempRepo
        try {
            $cliPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'dev-telemetry-record.ps1'
            Assert-That (Test-Path -LiteralPath $cliPath -PathType Leaf) 'record CLI file exists' $cliPath
            $cliEngine = Join-Path $PSHOME 'powershell.exe'
            try { if ($PSVersionTable.PSEdition -ceq 'Core') { $cliEngine = Join-Path $PSHOME 'pwsh.exe' } } catch { }
            Assert-That (Test-Path -LiteralPath $cliEngine -PathType Leaf) 'cli engine exists' $cliEngine
            function Invoke-DevTeleCliProc {
                param([string]$Engine, [string[]]$CliArgs)
                $outFile = Join-Path ([IO.Path]::GetTempPath()) ('devcli-out-' + [guid]::NewGuid().ToString('N') + '.txt')
                $errFile = Join-Path ([IO.Path]::GetTempPath()) ('devcli-err-' + [guid]::NewGuid().ToString('N') + '.txt')
                $code = 999
                try {
                    $quoted = @()
                    foreach ($a in $CliArgs) {
                        $s = [string]$a
                        if (($s -eq '') -or ($s -match '[\s"]')) {
                            $q = $s -replace '"', '""'
                            $quoted += ('"' + $q + '"')
                        }
                        else { $quoted += $s }
                    }
                    $argString = ($quoted -join ' ')
                    $proc = Start-Process -FilePath $Engine -ArgumentList $argString -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
                    try { $code = [int]$proc.ExitCode } catch { $code = 999 }
                }
                catch { $code = 999 }
                $outTxt = ''
                try { if (Test-Path -LiteralPath $outFile) { $outTxt = [IO.File]::ReadAllText($outFile, [Text.Encoding]::UTF8) } else { $outTxt = '' } } catch { $outTxt = 'READFAIL' }
                $errTxt = ''
                try { if (Test-Path -LiteralPath $errFile) { $errTxt = [IO.File]::ReadAllText($errFile, [Text.Encoding]::UTF8) } else { $errTxt = '' } } catch { $errTxt = 'READFAIL' }
                $outLines = @()
                try {
                    if (-not [string]::IsNullOrEmpty($outTxt)) {
                        $normalizedOut = [string]$outTxt
                        if ($normalizedOut.EndsWith("`r`n")) { $normalizedOut = $normalizedOut.Substring(0, $normalizedOut.Length - 2) }
                        elseif ($normalizedOut.EndsWith("`n") -or $normalizedOut.EndsWith("`r")) { $normalizedOut = $normalizedOut.Substring(0, $normalizedOut.Length - 1) }
                        if (-not [string]::IsNullOrEmpty($normalizedOut)) {
                            $outLines = @($normalizedOut -split "\r?\n")
                        }
                    }
                }
                catch { $outLines = @('SPLITFAIL') }
                try { if (Test-Path -LiteralPath $outFile) { Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue } } catch { }
                try { if (Test-Path -LiteralPath $errFile) { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue } } catch { }
                return ([PSCustomObject]@{ Code = $code; Lines = $outLines; Count = @($outLines).Count; Err = $errTxt; Stdout = $outTxt })
            }
            function Get-DevTeleRawText([string]$Repo) {
                $t = ''
                try {
                    foreach ($ff in @(Get-ChildItem -LiteralPath (Join-Path $Repo 'cache\v3\telemetry\dev') -Filter 'dev-*.jsonl' -File -ErrorAction Stop)) {
                        $t += [IO.File]::ReadAllText($ff.FullName, [Text.Encoding]::UTF8)
                    }
                }
                catch { $t = '' }
                return $t
            }
            function Get-DevTeleRawCount([string]$Repo) {
                $c = 0
                try {
                    $t = Get-DevTeleRawText -Repo $Repo
                    if (-not [string]::IsNullOrEmpty($t)) {
                        $c = @((([string]$t) -split "`n") | Where-Object { ([string]$_) -ne '' }).Count
                    }
                }
                catch { $c = -1 }
                return $c
            }
            $extraLinesScript = Join-Path ([IO.Path]::GetTempPath()) ('extra-lines-' + [guid]::NewGuid().ToString('N') + '.ps1')
            try {
                [IO.File]::WriteAllText($extraLinesScript, "Write-Output 'x'; Write-Output ''", [Text.Encoding]::ASCII)
                $rExtraLines = Invoke-DevTeleCliProc -Engine $cliEngine -CliArgs @('-NoProfile', '-File', $extraLinesScript)
                Assert-That ([int]$rExtraLines.Count -eq 2) 'extra blank stdout line is counted' ([string]$rExtraLines.Count)
            }
            finally { try { Remove-Item -LiteralPath $extraLinesScript -Force -ErrorAction SilentlyContinue } catch { } }
            $rOk = Invoke-DevTeleCliProc -Engine $cliEngine -CliArgs @('-NoProfile', '-File', $cliPath, '-RepoRoot', $tmpCli, '-Verdict', 'APPROVED', '-Now', '2026-10-21T12:00:00Z')
            Assert-That ([int]$rOk.Code -eq 0) 'record CLI APPROVED exit 0' ([string]$rOk.Code)
            Assert-That ([int]$rOk.Count -eq 1) 'record CLI APPROVED stdout exactly 1 line' ([string]$rOk.Count)
            $okLine = $false
            try { $okLine = (([int]$rOk.Count -eq 1) -and ([string]$rOk.Lines[0] -match 'recorded review_outcome=APPROVED')) } catch { $okLine = $false }
            Assert-That $okLine 'record CLI stdout confirms APPROVED' ([string]$rOk.Lines)
            Assert-That (([string]$rOk.Err) -ceq '') 'record CLI APPROVED stderr empty' ([string]$rOk.Err)
            $rawCli = Get-DevTeleRawText -Repo $tmpCli
            Assert-That (($rawCli -match '"kind":"review_outcome"') -and ($rawCli -match '"verdict":"APPROVED"')) 'record CLI jsonl has kind+verdict' 'content missing'
            Assert-That ($rawCli -match '"timestamp":"2026-10-21T12:00:00') 'record CLI timestamp prefix 2026-10-21T12:00:00' 'timestamp missing'
            $beforeBad = Get-DevTeleRawCount -Repo $tmpCli
            $rBad = Invoke-DevTeleCliProc -Engine $cliEngine -CliArgs @('-NoProfile', '-File', $cliPath, '-RepoRoot', $tmpCli, '-Verdict', 'INVALID')
            Assert-That ([int]$rBad.Code -eq 2) 'record CLI INVALID exit 2' ([string]$rBad.Code)
            Assert-That ([int]$rBad.Count -eq 1) 'record CLI INVALID stdout exactly 1 line' ([string]$rBad.Count)
            $badLine = $false
            try { $badLine = (([int]$rBad.Count -eq 1) -and ([string]$rBad.Lines[0] -ceq 'dev-telemetry: failed to record review_outcome')) } catch { $badLine = $false }
            Assert-That $badLine 'record CLI INVALID stdout exact fail line' ([string]$rBad.Lines)
            Assert-That (([string]$rBad.Err) -ceq '') 'record CLI INVALID stderr empty' ([string]$rBad.Err)
            $afterBad = Get-DevTeleRawCount -Repo $tmpCli
            Assert-That (($afterBad -eq $beforeBad) -and ($rawCli -notmatch 'INVALID')) 'record CLI INVALID writes no event' ([string]$afterBad)
            $beforeMissing = Get-DevTeleRawCount -Repo $tmpCli
            $rMissing = Invoke-DevTeleCliProc -Engine $cliEngine -CliArgs @('-NoProfile', '-File', $cliPath, '-RepoRoot', $tmpCli)
            Assert-That ([int]$rMissing.Code -eq 2) 'record CLI missing Verdict exit 2' ([string]$rMissing.Code)
            Assert-That ([int]$rMissing.Count -eq 1) 'record CLI missing Verdict stdout exactly 1 line' ([string]$rMissing.Count)
            $missLine = $false
            try { $missLine = (([int]$rMissing.Count -eq 1) -and ([string]$rMissing.Lines[0] -ceq 'dev-telemetry: failed to record review_outcome')) } catch { $missLine = $false }
            Assert-That $missLine 'record CLI missing Verdict stdout exact fail line' ([string]$rMissing.Lines)
            Assert-That (([string]$rMissing.Err) -ceq '') 'record CLI missing Verdict stderr empty' ([string]$rMissing.Err)
            $afterMissing = Get-DevTeleRawCount -Repo $tmpCli
            Assert-That ($afterMissing -eq $beforeMissing) 'record CLI missing Verdict writes no event' ([string]$afterMissing)
            $beforeLf = Get-DevTeleRawCount -Repo $tmpCli
            $rLf = Invoke-DevTeleCliProc -Engine $cliEngine -CliArgs @('-NoProfile', '-File', $cliPath, '-RepoRoot', $tmpCli, '-Verdict', 'APPROVED', '-Source', ("planner`n"))
            Assert-That ([int]$rLf.Code -eq 2) 'record CLI Source LF exit 2' ([string]$rLf.Code)
            Assert-That ([int]$rLf.Count -eq 1) 'record CLI Source LF stdout exactly 1 line' ([string]$rLf.Count)
            $lfLine = $false
            try { $lfLine = (([int]$rLf.Count -eq 1) -and ([string]$rLf.Lines[0] -ceq 'dev-telemetry: failed to record review_outcome')) } catch { $lfLine = $false }
            Assert-That $lfLine 'record CLI Source LF stdout exact fail line' ([string]$rLf.Lines)
            Assert-That (([string]$rLf.Err) -ceq '') 'record CLI Source LF stderr empty' ([string]$rLf.Err)
            $afterLf = Get-DevTeleRawCount -Repo $tmpCli
            Assert-That ($afterLf -eq $beforeLf) 'record CLI Source LF writes no event' ([string]$afterLf)
            $beforeDet = Get-DevTeleRawCount -Repo $tmpCli
            $rDet = Invoke-DevTeleCliProc -Engine $cliEngine -CliArgs @('-NoProfile', '-File', $cliPath, '-RepoRoot', $tmpCli, '-Verdict', 'APPROVED', '-Detail', 'bad detail with space')
            Assert-That ([int]$rDet.Code -eq 2) 'record CLI bad Detail exit 2' ([string]$rDet.Code)
            Assert-That ([int]$rDet.Count -eq 1) 'record CLI bad Detail stdout exactly 1 line' ([string]$rDet.Count)
            $detLine = $false
            try { $detLine = (([int]$rDet.Count -eq 1) -and ([string]$rDet.Lines[0] -ceq 'dev-telemetry: failed to record review_outcome')) } catch { $detLine = $false }
            Assert-That $detLine 'record CLI bad Detail stdout exact fail line' ([string]$rDet.Lines)
            Assert-That (([string]$rDet.Err) -ceq '') 'record CLI bad Detail stderr empty' ([string]$rDet.Err)
            $afterDet = Get-DevTeleRawCount -Repo $tmpCli
            Assert-That ($afterDet -eq $beforeDet) 'record CLI bad Detail writes no event' ([string]$afterDet)
            $fileRepo = Join-Path ([IO.Path]::GetTempPath()) ('devrepo-file-' + [guid]::NewGuid().ToString('N') + '.tmp')
            try { [IO.File]::WriteAllText($fileRepo, 'x', [Text.UTF8Encoding]::new($false)) } catch { }
            $rWrite = Invoke-DevTeleCliProc -Engine $cliEngine -CliArgs @('-NoProfile', '-File', $cliPath, '-RepoRoot', $fileRepo, '-Verdict', 'APPROVED')
            Assert-That ([int]$rWrite.Code -eq 1) 'record CLI write failure exit 1' ([string]$rWrite.Code)
            Assert-That ([int]$rWrite.Count -eq 1) 'record CLI write failure stdout exactly 1 line' ([string]$rWrite.Count)
            $wLine = $false
            try { $wLine = (([int]$rWrite.Count -eq 1) -and ([string]$rWrite.Lines[0] -ceq 'dev-telemetry: failed to record review_outcome')) } catch { $wLine = $false }
            Assert-That $wLine 'record CLI write failure stdout exact fail line' ([string]$rWrite.Lines)
            Assert-That (([string]$rWrite.Err) -ceq '') 'record CLI write failure stderr empty' ([string]$rWrite.Err)
            try { if (Test-Path -LiteralPath $fileRepo) { Remove-Item -LiteralPath $fileRepo -Force -ErrorAction SilentlyContinue } } catch { }
        }
        finally { Remove-DevTeleTempRepo $tmpCli }
    }
    finally { Remove-DevTeleTempRepo $tmpRepo }
}
catch {
    Write-Host ("[FAIL] unexpected error: " + $_.Exception.Message)
    exit 1
}

Write-Host ("DevTelemetry: " + $script:passed + " / " + $script:total + " tests passed (" + $script:skipped + " skipped)")
if ($script:passed -ne $script:total) { exit 1 }
exit 0
