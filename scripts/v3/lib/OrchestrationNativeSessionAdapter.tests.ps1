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

$base = Join-Path ([IO.Path]::GetTempPath()) ('nsa-herm-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base -Force | Out-Null
try {
    # LAUNCH_ERROR
    $r = Get-NativeSessionList -BinaryCommand (Join-Path $base 'nope.cmd')
    Assert-S ($r.ok -eq $false -and $r.error -eq 'LAUNCH_ERROR') 'LAUNCH_ERROR' $r.error

    # EXIT non-zero
    $p = New-FixtureCmd $base 'exit1' "@echo off`r`nexit /b 3`r`n"
    $r = Get-NativeSessionList -BinaryCommand $p
    Assert-S ($r.ok -eq $false -and $r.error -eq 'EXIT_3') 'EXIT non-zero' $r.error

    # PARSE_ERROR (invalid JSON)
    $p = New-FixtureCmd $base 'badjson' "@echo off`r`necho not-json`r`n"
    $r = Get-NativeSessionList -BinaryCommand $p
    Assert-S ($r.ok -eq $false -and $r.error -eq 'PARSE_ERROR') 'PARSE_ERROR' $r.error

    # PARSE_ERROR (empty response)
    $p = New-FixtureCmd $base 'empty' "@echo off`r`n"
    $r = Get-NativeSessionList -BinaryCommand $p
    Assert-S ($r.ok -eq $false -and $r.error -eq 'PARSE_ERROR') 'empty response' $r.error

    # PARSE_ERROR (object instead of array)
    $p = New-FixtureCmd $base 'obj' "@echo off`r`necho {""id"":""x""}`r`n"
    $r = Get-NativeSessionList -BinaryCommand $p
    Assert-S ($r.ok -eq $false -and $r.error -eq 'PARSE_ERROR') 'object not array' $r.error

    # FIELD_ERROR (missing id)
    $p = New-FixtureCmd $base 'noid' "@echo off`r`necho [{""title"":""t""}]`r`n"
    $r = Get-NativeSessionList -BinaryCommand $p
    Assert-S ($r.ok -eq $false -and $r.error -eq 'FIELD_ERROR') 'missing id' $r.error

    # FIELD_ERROR (invalid timestamp)
    $p = New-FixtureCmd $base 'badts' "@echo off`r`necho [{""id"":""ses_1"",""created"":""x"",""updated"":2}]`r`n"
    $r = Get-NativeSessionList -BinaryCommand $p
    Assert-S ($r.ok -eq $false -and $r.error -eq 'FIELD_ERROR') 'invalid timestamp' $r.error

    # Valid empty list
    $p = New-FixtureCmd $base 'emptyarr' "@echo off`r`necho []`r`n"
    $r = Get-NativeSessionList -BinaryCommand $p
    Assert-S ($r.ok -eq $true -and $r.count -eq 0) 'empty list valid' ("ok=$($r.ok) count=$($r.count)")

    # Valid multiple sessions
    $p = New-FixtureCmd $base 'multi' "@echo off`r`necho [{""id"":""ses_1"",""title"":""t1"",""created"":1000,""updated"":2000,""directory"":""D:\\\\x"",""projectId"":""p1""},{""id"":""ses_2"",""title"":""t2"",""created"":3000,""updated"":4000}]`r`n"
    $r = Get-NativeSessionList -BinaryCommand $p
    Assert-S ($r.ok -eq $true -and $r.count -eq 2) 'multi sessions' ("count=$($r.count)")
    Assert-S ($r.sessions[0].id -eq 'ses_1' -and $r.sessions[1].id -eq 'ses_2') 'ids' 'mismatch'

    # TIMEOUT
    $p = New-FixtureCmd $base 'slow' "@echo off`r`nping -n 6 127.0.0.1 >nul`r`necho []`r`n"
    $r = Get-NativeSessionList -BinaryCommand $p -TimeoutMs 200
    Assert-S ($r.ok -eq $false -and $r.error -eq 'TIMEOUT') 'TIMEOUT' $r.error

    $byId = '{"data":{"id":"ses_1","title":"t","time":{"created":1000,"updated":2000},"location":{"directory":"D:\\\\x"},"projectID":"p1"}}'
    $p = New-FixtureCmd $base 'byid' ("@echo off`r`nif `"%1`"==`"api`" (echo " + $byId + ") else (echo [])`r`n")
    $r = Get-NativeSessionList -BinaryCommand $p
    Assert-S ($r.ok -and $r.count -eq 0) 'by-id fixture list is empty' ($r.error + ':count=' + $r.count)
    $r = Get-NativeSessionById -SessionId 'ses_1' -BinaryCommand $p
    Assert-S ($r.ok -and $r.count -eq 1 -and $r.sessions[0].id -ceq 'ses_1') 'by-id independent of list' ($r.error + ':' + $r.detail + ':count=' + $r.count)
    $arch = '{"data":{"id":"ses_1","time":{"created":1,"updated":2,"archived":3000}}}'
    $p = New-FixtureCmd $base 'archived' ("@echo off`r`necho " + $arch + "`r`n")
    $r = Get-NativeSessionById -SessionId 'ses_1' -BinaryCommand $p
    Assert-S ($r.ok -and $r.sessions[0].archived -and $r.sessions[0].archivedAt -eq 3000) 'by-id archived' $r.error
    $p = New-FixtureCmd $base 'notfound' "@echo off`r`necho SessionNotFoundError 1>&2`r`nexit /b 1`r`n"
    $r = Get-NativeSessionById -SessionId 'ses_1' -BinaryCommand $p
    Assert-S ($r.error -eq 'NOT_FOUND') 'by-id not found' $r.error
    $wrongJson = '{"data":{"id":"ses_2","time":{"created":1,"updated":2}}}'
    $p = New-FixtureCmd $base 'wrongid' ("@echo off`r`necho " + $wrongJson + "`r`n")
    $r = Get-NativeSessionById -SessionId 'ses_1' -BinaryCommand $p
    Assert-S ($r.error -eq 'FIELD_ERROR') 'by-id wrong id' $r.error
    $p = New-FixtureCmd $base 'shouldnotrun' "@echo off`r`necho spawned > `"$base\spawned.txt`"`r`n"
    $r = Get-NativeSessionById -SessionId 'bad!' -BinaryCommand $p
    Assert-S ($r.error -eq 'INVALID_ID' -and -not (Test-Path (Join-Path $base 'spawned.txt'))) 'by-id invalid no spawn' $r.error
    $p = New-FixtureCmd $base 'bybadjson' "@echo off`r`necho nope`r`n"
    $r = Get-NativeSessionById -SessionId 'ses_1' -BinaryCommand $p
    Assert-S ($r.error -eq 'PARSE_ERROR') 'by-id malformed json' $r.error
    $badts = '{"data":{"id":"ses_1","time":{"created":"1000","updated":2000}}}'
    $p = New-FixtureCmd $base 'bybadts' ("@echo off`r`necho " + $badts + "`r`n")
    $r = Get-NativeSessionById -SessionId 'ses_1' -BinaryCommand $p
    Assert-S ($r.error -eq 'FIELD_ERROR') 'by-id string timestamp' $r.error
    $p = New-FixtureCmd $base 'byslow' "@echo off`r`nping -n 6 127.0.0.1 >nul`r`necho {}`r`n"
    $r = Get-NativeSessionById -SessionId 'ses_1' -BinaryCommand $p -TimeoutMs 200
    Assert-S ($r.error -eq 'TIMEOUT') 'by-id timeout' $r.error
}
finally {
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}

# Runtime smoke (separate, only if available)
$hasOpencode = $null -ne (Get-Command opencode.cmd -ErrorAction SilentlyContinue)
if ($hasOpencode) {
    $r = Get-NativeSessionList -MaxCount 2
    Assert-S ($r.ok -eq $true) 'runtime smoke ok' $r.error
    Assert-S ($r.count -ge 1 -and $r.count -le 2) 'runtime smoke bounded' ("got $($r.count)")
    $sid = [string]$r.sessions[0].id
    $byId = Get-NativeSessionById -SessionId $sid
    Assert-S ($byId.ok -and $byId.sessions[0].id -ceq $sid) 'runtime smoke by id' $byId.error
} else {
    Write-Host 'SKIP runtime smoke: opencode not available'
}

Write-Host ("TOTAL={0} PASS={1} FAIL={2}" -f ($passed + $failed), $passed, $failed)
if ($failed -gt 0) { exit 1 }
exit 0
