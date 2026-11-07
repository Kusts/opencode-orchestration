$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationNativeSessionAdapter.ps1')

$passed = 0; $failed = 0
function Assert-S($cond, $name, $detail) {
    if ($cond) { $script:passed++; Write-Host ("PASS {0}" -f $name) }
    else { $script:failed++; Write-Host ("FAIL {0} :: {1}" -f $name, $detail) }
}

function New-FixtureCmd($dir, $name, $content) {
    $p = Join-Path $dir ($name + '.cmd')
    [IO.File]::WriteAllText($p, $content, [Text.Encoding]::ASCII)
    return $p
}

function New-ListFixture($dir, $name, $json) {
    # Escape for cmd echo: single echo line. JSON has no % or & in our fixtures.
    $content = "@echo off`r`necho " + $json + "`r`n"
    return (New-FixtureCmd $dir $name $content)
}

function To-JsonDir($path) {
    return (([string]$path) -replace '\\', '\\')
}

$base = Join-Path ([IO.Path]::GetTempPath()) ('nsb-herm-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base -Force | Out-Null
try {
    # --- id format ---
    Assert-S ((Test-NativeSessionIdFormat -SessionId 'ses_abc123') -eq $true) 'id-format valid' 'expected true'
    Assert-S ((Test-NativeSessionIdFormat -SessionId 'ses_1') -eq $true) 'id-format minimal' 'expected true'
    Assert-S ((Test-NativeSessionIdFormat -SessionId '') -eq $false) 'id-format empty' 'expected false'
    Assert-S ((Test-NativeSessionIdFormat -SessionId 'bad!') -eq $false) 'id-format bad chars' 'expected false'
    Assert-S ((Test-NativeSessionIdFormat -SessionId 'ses_') -eq $false) 'id-format bare prefix' 'expected false'
    Assert-S ((Test-NativeSessionIdFormat -SessionId 'SES_123') -eq $false) 'id-format prefix case' 'expected false'
    Assert-S ((Test-NativeSessionIdFormat -SessionId ' ses_1') -eq $false) 'id-format leading space' 'expected false'
    Assert-S ((Test-NativeSessionIdFormat -SessionId 'ses_abc-def') -eq $false) 'id-format dash' 'expected false'

    # --- resolve directory: trailing slash + case-insensitive equality, never throws ---
    $work = Join-Path $base 'Work'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $c1 = Resolve-NativeSessionDirectory -Path $work
    $c2 = Resolve-NativeSessionDirectory -Path ($work + '\')
    $c3 = Resolve-NativeSessionDirectory -Path ($work.ToUpperInvariant())
    Assert-S ((-not [string]::IsNullOrWhiteSpace($c1)) -and ($c1 -ieq $c2)) 'resolve trailing-slash equal' ("c1=$c1 c2=$c2")
    Assert-S ($c1 -ieq $c3) 'resolve case-insensitive equal' ("c1=$c1 c3=$c3")
    Assert-S ((Resolve-NativeSessionDirectory -Path '') -eq '') 'resolve empty' 'expected empty'
    $threw = $false
    try { [void](Resolve-NativeSessionDirectory -Path $null) } catch { $threw = $true }
    Assert-S (-not $threw) 'resolve never throws' 'threw'

    # Build fixtures with real work dir
    $jd = To-JsonDir $work
    $json1 = '[{"id":"ses_aaa","title":"t","created":1000,"updated":2000,"directory":"' + $jd + '","projectId":"p1"}]'

    # --- binding: invalid id (no spawn needed) ---
    $listOk = [pscustomobject]@{ ok = $true; error = $null; sessions = @([pscustomobject]@{ id = 'ses_aaa'; title = 't'; created = 1000; updated = 2000; directory = $work; projectId = 'p1' }); count = 1 }
    $b = Test-NativeSessionBinding -SessionId 'bad!' -ExpectedDirectory $work -ExpectedProjectId 'p1' -SessionsResult $listOk
    Assert-S ($b.ok -eq $false -and $b.reason -eq 'session-id-invalid') 'binding id-invalid' $b.reason

    # --- binding: not found ---
    $b = Test-NativeSessionBinding -SessionId 'ses_bbb' -ExpectedDirectory $work -ExpectedProjectId 'p1' -SessionsResult $listOk
    Assert-S ($b.ok -eq $false -and $b.reason -eq 'session-not-found') 'binding not-found' $b.reason

    # --- binding: empty list ---
    $emptyList = [pscustomobject]@{ ok = $true; error = $null; sessions = @(); count = 0 }
    $b = Test-NativeSessionBinding -SessionId 'ses_aaa' -ExpectedDirectory $work -ExpectedProjectId 'p1' -SessionsResult $emptyList
    Assert-S ($b.ok -eq $false -and $b.reason -eq 'session-not-found') 'binding empty-list' $b.reason

    # --- binding: project mismatch ---
    $b = Test-NativeSessionBinding -SessionId 'ses_aaa' -ExpectedDirectory $work -ExpectedProjectId 'p2' -SessionsResult $listOk
    Assert-S ($b.ok -eq $false -and $b.reason -eq 'project-mismatch') 'binding project-mismatch' $b.reason

    # --- binding: directory trailing-slash + case must PASS ---
    $b = Test-NativeSessionBinding -SessionId 'ses_aaa' -ExpectedDirectory ($work + '\') -ExpectedProjectId 'p1' -SessionsResult $listOk
    Assert-S ($b.ok -eq $true) 'binding dir trailing-slash pass' $b.reason
    $b = Test-NativeSessionBinding -SessionId 'ses_aaa' -ExpectedDirectory ($work.ToUpperInvariant()) -ExpectedProjectId 'p1' -SessionsResult $listOk
    Assert-S ($b.ok -eq $true) 'binding dir case pass' $b.reason

    # --- binding: really different directory must FAIL ---
    $other = Join-Path $base 'Other'
    New-Item -ItemType Directory -Path $other -Force | Out-Null
    $b = Test-NativeSessionBinding -SessionId 'ses_aaa' -ExpectedDirectory $other -ExpectedProjectId 'p1' -SessionsResult $listOk
    Assert-S ($b.ok -eq $false -and $b.reason -eq 'directory-mismatch') 'binding dir mismatch' $b.reason

    # --- binding: happy path ---
    $b = Test-NativeSessionBinding -SessionId 'ses_aaa' -ExpectedDirectory $work -ExpectedProjectId 'p1' -SessionsResult $listOk
    Assert-S ($b.ok -eq $true -and $b.session.id -ceq 'ses_aaa') 'binding ok' $b.reason

    # --- find by id via injected BinaryCommand ---
    $p = New-ListFixture $base 'findlist' $json1
    $f = Find-NativeSessionById -SessionId 'ses_aaa' -BinaryCommand $p
    Assert-S ($null -ne $f -and $f.id -ceq 'ses_aaa') 'find injected ok' 'not found'
    $f = Find-NativeSessionById -SessionId 'ses_zzz' -BinaryCommand $p
    Assert-S ($null -eq $f) 'find injected missing' 'expected null'
    # case-sensitive ordinal: SES_AAA must not match ses_aaa
    $f = Find-NativeSessionById -SessionId 'SES_AAA' -SessionsResult $listOk
    Assert-S ($null -eq $f) 'find case-sensitive' 'matched wrong case'

    # --- identity via injected BinaryCommand ---
    $byJson = '{"data":{"id":"ses_aaa","title":"t","time":{"created":1000,"updated":2000},"location":{"directory":"' + $jd + '"},"projectID":"p1"}}'
    $p = New-FixtureCmd $base 'identok' ("@echo off`r`necho " + $byJson + "`r`n")
    $r = Get-NativeSessionIdentity -SessionId 'ses_aaa' -ExpectedDirectory $work -ExpectedProjectId 'p1' -BinaryCommand $p
    Assert-S ($r.ok -eq $true -and $r.session.id -ceq 'ses_aaa') 'identity ok' $r.reason

    $r = Get-NativeSessionIdentity -SessionId 'bad!' -ExpectedDirectory $work -ExpectedProjectId 'p1' -BinaryCommand (Join-Path $base 'nope.cmd')
    Assert-S ($r.ok -eq $false -and $r.reason -eq 'session-id-invalid') 'identity id-invalid' $r.reason

    $pEmpty = New-FixtureCmd $base 'identempty' "@echo off`r`necho {`"data`":null}`r`n"
    $r = Get-NativeSessionIdentity -SessionId 'ses_aaa' -ExpectedDirectory $work -ExpectedProjectId 'p1' -BinaryCommand $pEmpty
    Assert-S ($r.ok -eq $false -and $r.reason -eq 'session-not-found') 'identity empty-list' $r.reason

    $r = Get-NativeSessionIdentity -SessionId 'ses_zzz' -ExpectedDirectory $work -ExpectedProjectId 'p1' -BinaryCommand $p
    Assert-S ($r.ok -eq $false -and $r.reason -eq 'session-not-found') 'identity not-found' $r.reason

    $r = Get-NativeSessionIdentity -SessionId 'ses_aaa' -ExpectedDirectory $work -ExpectedProjectId 'pX' -BinaryCommand $p
    Assert-S ($r.ok -eq $false -and $r.reason -eq 'project-mismatch') 'identity project-mismatch' $r.reason

    $r = Get-NativeSessionIdentity -SessionId 'ses_aaa' -ExpectedDirectory $other -ExpectedProjectId 'p1' -BinaryCommand $p
    Assert-S ($r.ok -eq $false -and $r.reason -eq 'directory-mismatch') 'identity dir-mismatch' $r.reason

    $r = Get-NativeSessionIdentity -SessionId 'ses_aaa' -ExpectedDirectory ($work + '\') -ExpectedProjectId 'p1' -BinaryCommand $p
    Assert-S ($r.ok -eq $true) 'identity dir trailing-slash pass' $r.reason

    # detail sanitized: max 200 chars, present on failure
    $r = Get-NativeSessionIdentity -SessionId 'ses_zzz' -ExpectedDirectory $work -ExpectedProjectId 'p1' -BinaryCommand $p
    $detailLen = 0
    try { $detailLen = ([string]$r.detail).Length } catch { $detailLen = 9999 }
    Assert-S ($detailLen -le 200) 'identity detail bounded' ("len=$detailLen")

    # --- export never used for binding (list only, no run/export/continue) ---
    $src = ''
    try {
        $src += (Get-Command Test-NativeSessionBinding).ScriptBlock.ToString() + "`n"
        $src += (Get-Command Get-NativeSessionIdentity).ScriptBlock.ToString() + "`n"
        $src += (Get-Command Find-NativeSessionById).ScriptBlock.ToString() + "`n"
    } catch { $src = 'UNREADABLE' }
    Assert-S ($src -notmatch '(?i)\bexport\b') 'binding no-export' 'found export token'
    Assert-S ($src -notmatch '--continue') 'binding no-continue' 'found --continue'
    Assert-S ($src -notmatch '(?i)\bsession\s+export\b') 'binding no-session-export' 'found session export'
    Assert-S ((Get-Command Get-NativeSessionIdentity).ScriptBlock.ToString() -match 'Get-NativeSessionById') 'identity uses direct lookup' 'missing direct lookup'
    Assert-S ((Get-Command Find-NativeSessionById).ScriptBlock.ToString() -match 'Get-NativeSessionList') 'find still uses list' 'list lookup missing'

    $archJson = '{"data":{"id":"ses_aaa","time":{"created":1,"updated":2,"archived":3},"location":{"directory":"' + $jd + '"},"projectID":"p1"}}'
    $pArch = New-FixtureCmd $base 'identarch' ("@echo off`r`necho " + $archJson + "`r`n")
    $r = Get-NativeSessionIdentity -SessionId 'ses_aaa' -ExpectedDirectory $work -ExpectedProjectId 'p1' -BinaryCommand $pArch
    Assert-S ($r.reason -eq 'session-archived' -and $null -eq $r.session) 'identity archived' $r.reason
}
finally {
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ("TOTAL={0} PASS={1} FAIL={2}" -f ($passed + $failed), $passed, $failed)
if ($failed -gt 0) { exit 1 }
exit 0
