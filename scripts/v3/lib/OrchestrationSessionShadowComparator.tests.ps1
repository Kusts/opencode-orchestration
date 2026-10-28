$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationSessionShadowComparator.ps1')

$passed = 0; $failed = 0
function Assert-H($cond, $name, $detail) {
    if ($cond) { $script:passed++; Write-Host ("PASS {0}" -f $name) }
    else { $script:failed++; Write-Host ("FAIL {0} :: {1}" -f $name, $detail) }
}

# 1. IDs iguais (MATCH)
$local = @([pscustomobject]@{ session_id='ses_1'; directory='D:\x'; project='p1'; updated_at=2000 })
$native = [pscustomobject]@{ ok=$true; sessions=@([pscustomobject]@{ id='ses_1'; directory='D:\x'; projectId='p1'; updated=2000 }) }
$r = Compare-SessionCatalogs -LocalBindings $local -NativeResult $native
Assert-H ($r.matches -eq 1) 'match equal ids' ("matches=$($r.matches)")

# 2. NATIVE_ONLY
$local2 = @()
$native2 = [pscustomobject]@{ ok=$true; sessions=@([pscustomobject]@{ id='ses_2'; directory='D:\y'; projectId='p2'; updated=3000 }) }
$r2 = Compare-SessionCatalogs -LocalBindings $local2 -NativeResult $native2
Assert-H ($r2.native_only -eq 1) 'native only' ("got $($r2.native_only)")

# 3. LOCAL_ONLY
$local3 = @([pscustomobject]@{ session_id='ses_3'; directory='D:\z'; project='p3'; updated_at=4000 })
$native3 = [pscustomobject]@{ ok=$true; sessions=@() }
$r3 = Compare-SessionCatalogs -LocalBindings $local3 -NativeResult $native3
Assert-H ($r3.local_only -eq 1) 'local only' ("got $($r3.local_only)")

# 4. FIELD_MISMATCH (directory divergent)
$local4 = @([pscustomobject]@{ session_id='ses_4'; directory='D:\a'; project='p4'; updated_at=5000 })
$native4 = [pscustomobject]@{ ok=$true; sessions=@([pscustomobject]@{ id='ses_4'; directory='D:\b'; projectId='p4'; updated=5000 }) }
$r4 = Compare-SessionCatalogs -LocalBindings $local4 -NativeResult $native4
Assert-H ($r4.field_mismatches -eq 1) 'field mismatch' ("got $($r4.field_mismatches)")

# 5. QUERY_ERROR
$native5 = [pscustomobject]@{ ok=$false; error='TIMEOUT'; sessions=@() }
$local5 = @([pscustomobject]@{ session_id='ses_5'; directory='D:\e'; project='p5'; updated_at=6000 })
$r5 = Compare-SessionCatalogs -LocalBindings $local5 -NativeResult $native5
Assert-H ($r5.query_error -eq $true) 'query error' "not query_error"

# 6. Truncation
$native6 = [pscustomobject]@{ ok=$true; sessions=@([pscustomobject]@{ id='ses_6'; directory='D:\f'; projectId='p6'; updated=7000 }) }
$local6 = @([pscustomobject]@{ session_id='ses_7'; directory='D:\g'; project='p7'; updated_at=8000 })
$r6 = Compare-SessionCatalogs -LocalBindings $local6 -NativeResult $native6 -NativeLimit 1
Assert-H ($r6.truncated -eq $true) 'truncated' "not truncated"

# 7. No sessions available
$native7 = [pscustomobject]@{ ok=$true; sessions=@() }
$local7 = @()
$r7 = Compare-SessionCatalogs -LocalBindings $local7 -NativeResult $native7
Assert-H ($r7.native_count -eq 0 -and $r7.local_count -eq 0) 'no sessions' "counts wrong"

# 8. Duplicate ID -> NOT_COMPARABLE
$native8 = [pscustomobject]@{ ok=$true; sessions=@([pscustomobject]@{ id='ses_8'; directory='D:\h'; projectId='p8'; updated=9000 }, [pscustomobject]@{ id='ses_8'; directory='D:\i'; projectId='p9'; updated=9001 }) }
$local8 = @()
$r8 = Compare-SessionCatalogs -LocalBindings $local8 -NativeResult $native8
Assert-H ($r8.status -eq 'not_comparable') 'duplicate id' ("status=$($r8.status)")

# 9. Timestamp incompatibility (string vs ms) - should not crash; tolerance
$local9 = @([pscustomobject]@{ session_id='ses_9'; directory='D:\j'; project='p9'; updated_at='2024-10-28T10:00:00Z' })
$native9 = [pscustomobject]@{ ok=$true; sessions=@([pscustomobject]@{ id='ses_9'; directory='D:\j'; projectId='p9'; updated=1730109600000 }) }
$r9 = Compare-SessionCatalogs -LocalBindings $local9 -NativeResult $native9
Assert-H ($r9.matches -eq 1) 'timestamp normalized' ("matches=$($r9.matches) mm=$($r9.field_mismatches)")

# 10. Case-sensitive identity: ses_A vs ses_a are distinct
$local10 = @([pscustomobject]@{ session_id='ses_A'; directory='D:\x'; project='p'; updated_at=1000 })
$native10 = [pscustomobject]@{ ok=$true; sessions=@([pscustomobject]@{ id='ses_a'; directory='D:\x'; projectId='p'; updated=1000 }) }
$r10 = Compare-SessionCatalogs -LocalBindings $local10 -NativeResult $native10
Assert-H ($r10.native_only -eq 1 -and $r10.local_only -eq 1) 'case-sensitive ids' ("native_only=$($r10.native_only) local_only=$($r10.local_only)")

# 11. NOT_COMPARABLE when missing directory
$local11 = @([pscustomobject]@{ session_id='ses_11'; directory=''; project='p'; updated_at=1000 })
$native11 = [pscustomobject]@{ ok=$true; sessions=@([pscustomobject]@{ id='ses_11'; directory='D:\x'; projectId='p'; updated=1000 }) }
$r11 = Compare-SessionCatalogs -LocalBindings $local11 -NativeResult $native11
Assert-H ($r11.not_comparable -ge 1) 'not comparable missing dir' ("nc=$($r11.not_comparable)")

# 12. local_candidates vs real_local_bindings (synthetic id excluded)
$local12 = @([pscustomobject]@{ session_id=''; directory='D:\x'; project='p'; updated_at=1000 }, [pscustomobject]@{ session_id='ses_12'; directory='D:\y'; project='p'; updated_at=2000 })
$native12 = [pscustomobject]@{ ok=$true; sessions=@() }
$r12 = Compare-SessionCatalogs -LocalBindings $local12 -NativeResult $native12
Assert-H ($r12.local_candidates -eq 2 -and $r12.real_local_bindings -eq 1) 'candidates vs real bindings' ("cand=$($r12.local_candidates) real=$($r12.real_local_bindings)")

# 13. QUERY_ERROR distinct (no LOCAL_ONLY)
$local13 = @([pscustomobject]@{ session_id='ses_13'; directory='D:\z'; project='p'; updated_at=3000 })
$native13 = [pscustomobject]@{ ok=$false; error='TIMEOUT'; sessions=@() }
$r13 = Compare-SessionCatalogs -LocalBindings $local13 -NativeResult $native13
Assert-H ($r13.query_error -eq $true -and $r13.local_only -eq 0) 'query error distinct' ("qe=$($r13.query_error) lo=$($r13.local_only)")

Write-Host ("TOTAL={0} PASS={1} FAIL={2}" -f ($passed + $failed), $passed, $failed)
if ($failed -gt 0) { exit 1 }
exit 0