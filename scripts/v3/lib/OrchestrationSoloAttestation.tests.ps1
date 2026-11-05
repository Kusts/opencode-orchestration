[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationSoloAttestation.ps1')

$passed = 0
function Assert-That {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if (-not $Condition) { throw ("FAIL: " + $Name + " " + $Detail) }
    $script:passed++
}

function ConvertTo-TestDerLength {
    param([int]$Length)
    if ($Length -lt 0) { throw 'negative length' }
    if ($Length -lt 128) { return ([byte[]]@([byte]$Length)) }
    $tmp = New-Object System.Collections.Generic.List[byte]
    $n = $Length
    while ($n -gt 0) { $tmp.Insert(0, [byte]($n -band 255)) | Out-Null; $n = ($n -shr 8) }
    $head = [byte](128 + $tmp.Count)
    $out = New-Object System.Collections.Generic.List[byte]
    $out.Add($head) | Out-Null
    foreach ($b in $tmp) { $out.Add($b) | Out-Null }
    return ([byte[]]$out.ToArray())
}

function ConvertTo-TestDerTlv {
    param([byte]$Tag, [byte[]]$Value)
    $len = ConvertTo-TestDerLength -Length $Value.Length
    $out = New-Object System.Collections.Generic.List[byte]
    $out.Add($Tag) | Out-Null
    foreach ($b in $len) { $out.Add($b) | Out-Null }
    foreach ($b in $Value) { $out.Add($b) | Out-Null }
    return ([byte[]]$out.ToArray())
}

function ConvertTo-TestDerInteger {
    param([byte[]]$Unsigned)
    $i = 0
    while (($i -lt ($Unsigned.Length - 1)) -and ($Unsigned[$i] -eq 0)) { $i++ }
    $mag = $Unsigned[$i..($Unsigned.Length - 1)]
    if (($mag[0] -band 128) -ne 0) { $mag = ([byte[]]@([byte]0)) + $mag }
    return (ConvertTo-TestDerTlv -Tag 2 -Value $mag)
}

function ConvertTo-TestSpkiDer {
    param([byte[]]$Modulus, [byte[]]$Exponent)
    $rsaOid = [byte[]]@(6, 9, 42, 134, 72, 134, 247, 13, 1, 1, 1)
    $nullTlv = [byte[]]@(5, 0)
    $algInner = $rsaOid + $nullTlv
    $algSeq = ConvertTo-TestDerTlv -Tag 48 -Value $algInner
    $nInt = ConvertTo-TestDerInteger -Unsigned $Modulus
    $eInt = ConvertTo-TestDerInteger -Unsigned $Exponent
    $rsaSeq = ConvertTo-TestDerTlv -Tag 48 -Value ($nInt + $eInt)
    $bitContent = ([byte[]]@([byte]0)) + $rsaSeq
    $bitStr = ConvertTo-TestDerTlv -Tag 3 -Value $bitContent
    return (ConvertTo-TestDerTlv -Tag 48 -Value ($algSeq + $bitStr))
}

function New-TestAttestationFixture {
    $rsa = New-Object System.Security.Cryptography.RSACng(2048)
    try {
        $params = $rsa.ExportParameters($false)
        $spki = ConvertTo-TestSpkiDer -Modulus $params.Modulus -Exponent $params.Exponent
        $spkiB64 = [Convert]::ToBase64String($spki)
        return @{ rsa = $rsa; spkiB64 = $spkiB64; keep = $true }
    }
    catch {
        $rsa.Dispose()
        throw
    }
}

function New-TestPayload {
    param(
        [string]$HeadSha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        [string]$Operation = 'op-fixture-001',
        [string]$Profile = 'solo-maintainer',
        [string]$Issuer = 'test-issuer-fixture-01'
    )
    $reviews = @(
        [ordered]@{
            role = 'reviewer'
            session_id = 'ses_Reviewer01ABCDEF1234567890'
            verdict = 'approved'
            candidate_sha = $HeadSha
            evidence_sha256 = @('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbc')
            kernel_record_sha256 = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
        },
        [ordered]@{
            role = 'security-reviewer'
            session_id = 'ses_Security01ABCDEF1234567890'
            verdict = 'approved'
            candidate_sha = $HeadSha
            evidence_sha256 = @('dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd', 'ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddde')
            kernel_record_sha256 = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
        }
    )
    return [ordered]@{
        schema_version = 1
        policy_id = 'solo-attestation-v1'
        policy_digest = 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
        delivery_profile = $Profile
        repository = 'example/solo-attestation-fixture'
        pr_number = 999
        head_sha = $HeadSha
        task_id = 'task-fixture-001'
        run_id = 'run-fixture-001'
        operation_id = $Operation
        issuer_id = $Issuer
        issued_at = '2026-11-04T10:00:00Z'
        expires_at = '2026-11-04T10:10:00Z'
        jti = '12345678-1234-1234-1234-1234567890ab'
        reviews = $reviews
    }
}

function New-TestVerifierPolicy {
    param([string]$Issuer = 'test-issuer-fixture-01', [string]$SpkiB64 = '', [string]$Status = 'ENABLED')
    return ('{"schema_version":1,"status":"' + $Status + '","max_skew_seconds":60,"max_lifetime_seconds":900,"trusted_issuers":[{"issuer_id":"' + $Issuer + '","public_key_base64":"' + $SpkiB64 + '","revoked":false}],"revoked_jtis":[]}')
}

function Invoke-TestVerify {
    param([string]$Document, [string]$Policy, [hashtable]$Fx, [string]$Now = '2026-11-04T10:05:00Z', [string]$Operation = 'op-fixture-001', [string]$Profile = 'solo-maintainer', [string]$Head = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')
    return (Test-OcSoloAttestationDocument -DocumentJson $Document -ExpectedRepository 'example/solo-attestation-fixture' -ExpectedPrNumber 999 -ExpectedHeadSha $Head -ExpectedTaskId 'task-fixture-001' -ExpectedRunId 'run-fixture-001' -ExpectedOperationId $Operation -ExpectedDeliveryProfile $Profile -ExpectedPolicyId 'solo-attestation-v1' -ExpectedPolicyDigest 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' -VerifierPolicyJson $Policy -NowUtc $Now)
}

function New-TestSignedDocument {
    param($Payload, $Rsa)
    $canon = Get-OcSoloAttestationCanonicalJson -Payload $Payload
    if ([string]::IsNullOrWhiteSpace($canon)) { throw 'canonicalization failed in fixture' }
    $bytes = [Text.Encoding]::UTF8.GetBytes($canon)
    $sig = $Rsa.SignData($bytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pss)
    $b64 = [Convert]::ToBase64String($sig)
    return ('{"payload":' + $canon + ',"signature_base64":"' + $b64 + '"}')
}

function ConvertTo-TestLenientJson {
    param($Node)
    if ($null -eq $Node) { return 'null' }
    if ($Node -is [string]) { return (ConvertTo-OcSoloAttestationJsonString -Text ([string]$Node)) }
    if ($Node -is [bool]) {
        if ([bool]$Node) { return 'true' }
        return 'false'
    }
    if ($Node -is [System.Collections.IDictionary]) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($k in @($Node.Keys)) {
            $parts.Add(('"' + ([string]$k) + '":' + (ConvertTo-TestLenientJson -Node $Node[$k]))) | Out-Null
        }
        return ('{' + ($parts -join ',') + '}')
    }
    if ($Node -is [System.Collections.IEnumerable]) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($e in $Node) { $parts.Add((ConvertTo-TestLenientJson -Node $e)) | Out-Null }
        return ('[' + ($parts -join ',') + ']')
    }
    $n = [long]$Node
    return $n.ToString([Globalization.CultureInfo]::InvariantCulture)
}

function New-TestSignedDocumentLenient {
    param($Payload, $Rsa)
    $canon = ConvertTo-TestLenientJson -Node $Payload
    if ([string]::IsNullOrWhiteSpace($canon)) { throw 'lenient serialization failed in fixture' }
    $bytes = [Text.Encoding]::UTF8.GetBytes($canon)
    $sig = $Rsa.SignData($bytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pss)
    $b64 = [Convert]::ToBase64String($sig)
    return ('{"payload":' + $canon + ',"signature_base64":"' + $b64 + '"}')
}

$fx = New-TestAttestationFixture
try {
    $rsa = $fx.rsa
    $policy = New-TestVerifierPolicy -SpkiB64 $fx.spkiB64

    # 1. accepted authentic coherent synthetic attestation.
    $payload = New-TestPayload
    $doc = New-TestSignedDocument -Payload $payload -Rsa $rsa
    $r = Invoke-TestVerify -Document $doc -Policy $policy -Fx $fx
    Assert-That ([bool]$r.ok -and ([string]$r.reason -ceq 'attestation-valid')) 'coherent synthetic attestation accepted' (($r | ConvertTo-Json -Compress))
    Assert-That ((@($r.PSObject.Properties).Count -eq 2)) 'result carries only ok and reason, no authority claims' (($r | ConvertTo-Json -Compress))

    # 2. raw review object rejected (kernel review shape is not an attestation).
    $rawReview = '{"status":"approved","by":"reviewer","candidate_revision":7,"at":"2026-11-04T10:05:00Z","revision":8}'
    $r = Invoke-TestVerify -Document $rawReview -Policy $policy -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'envelope-invalid')) 'raw kernel review object rejected' (($r | ConvertTo-Json -Compress))

    # 3. invalid signature.
    $canon = Get-OcSoloAttestationCanonicalJson -Payload (New-TestPayload)
    $sigBytes = $rsa.SignData([Text.Encoding]::UTF8.GetBytes($canon), [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pss)
    $sigBytes[0] = ($sigBytes[0] -bxor 1)
    $badDoc = ('{"payload":' + $canon + ',"signature_base64":"' + ([Convert]::ToBase64String($sigBytes)) + '"}')
    $r = Invoke-TestVerify -Document $badDoc -Policy $policy -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'signature-invalid')) 'tampered signature rejected' (($r | ConvertTo-Json -Compress))

    # 4. SHA mismatch (document head differs from expected head).
    $payloadSha = New-TestPayload -HeadSha 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $docSha = New-TestSignedDocument -Payload $payloadSha -Rsa $rsa
    $r = Invoke-TestVerify -Document $docSha -Policy $policy -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'head-sha-mismatch')) 'divergent head sha rejected' (($r | ConvertTo-Json -Compress))

    # 5a. missing internal reviewer (only security-reviewer present).
    $p = New-TestPayload
    $p['reviews'] = @($p['reviews'][1])
    $docNoRev = New-TestSignedDocumentLenient -Payload $p -Rsa $rsa
    $r = Invoke-TestVerify -Document $docNoRev -Policy $policy -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'reviews-invalid')) 'missing reviewer rejected' (($r | ConvertTo-Json -Compress))

    # 5b. missing security reviewer (only reviewer present).
    $p = New-TestPayload
    $p['reviews'] = @($p['reviews'][0])
    $docNoSec = New-TestSignedDocumentLenient -Payload $p -Rsa $rsa
    $r = Invoke-TestVerify -Document $docNoSec -Policy $policy -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'reviews-invalid')) 'missing security-reviewer rejected' (($r | ConvertTo-Json -Compress))

    # 5c. wrong role order (security first) rejected.
    $p = New-TestPayload
    $p['reviews'] = @($p['reviews'][1], $p['reviews'][0])
    $docOrder = New-TestSignedDocument -Payload $p -Rsa $rsa
    $r = Invoke-TestVerify -Document $docOrder -Policy $policy -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'reviews-invalid')) 'swapped review order rejected' (($r | ConvertTo-Json -Compress))

    # 6. unknown issuer.
    $payloadUnknown = New-TestPayload -Issuer 'unknown-issuer-zzz'
    $docUnknown = New-TestSignedDocument -Payload $payloadUnknown -Rsa $rsa
    $r = Invoke-TestVerify -Document $docUnknown -Policy $policy -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'unknown-issuer')) 'unknown issuer rejected' (($r | ConvertTo-Json -Compress))

    # 7. same attestation reused against a different operation.
    $r = Invoke-TestVerify -Document $doc -Policy $policy -Fx $fx -Operation 'op-fixture-002'
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'operation-mismatch')) 'operation reuse rejected' (($r | ConvertTo-Json -Compress))

    # 8a. strict profile cannot receive waiver.
    $r = Invoke-TestVerify -Document $doc -Policy $policy -Fx $fx -Profile 'strict'
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'waiver-not-allowed')) 'strict profile waiver rejected' (($r | ConvertTo-Json -Compress))

    # 8b. human-required profile cannot receive waiver.
    $r = Invoke-TestVerify -Document $doc -Policy $policy -Fx $fx -Profile 'human-required'
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'waiver-not-allowed')) 'human-required profile waiver rejected' (($r | ConvertTo-Json -Compress))

    # 9a. expired attestation.
    $r = Invoke-TestVerify -Document $doc -Policy $policy -Fx $fx -Now '2026-11-04T10:30:00Z'
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'expired')) 'expired attestation rejected' (($r | ConvertTo-Json -Compress))

    # 9b. revoked issuer.
    $revokedPolicy = ('{"schema_version":1,"status":"ENABLED","max_skew_seconds":60,"max_lifetime_seconds":900,"trusted_issuers":[{"issuer_id":"test-issuer-fixture-01","public_key_base64":"' + $fx.spkiB64 + '","revoked":true}],"revoked_jtis":[]}')
    $r = Invoke-TestVerify -Document $doc -Policy $revokedPolicy -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'issuer-revoked')) 'revoked issuer rejected' (($r | ConvertTo-Json -Compress))

    # 9c. revoked jti.
    $jtiPolicy = ('{"schema_version":1,"status":"ENABLED","max_skew_seconds":60,"max_lifetime_seconds":900,"trusted_issuers":[{"issuer_id":"test-issuer-fixture-01","public_key_base64":"' + $fx.spkiB64 + '","revoked":false}],"revoked_jtis":["12345678-1234-1234-1234-1234567890ab"]}')
    $r = Invoke-TestVerify -Document $doc -Policy $jtiPolicy -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'jti-revoked')) 'revoked jti rejected' (($r | ConvertTo-Json -Compress))

    # 9c2. uppercase JTI matches lowercase revoked entry (case-insensitive revocation).
    $p = New-TestPayload
    $p['jti'] = '12345678-1234-1234-1234-1234567890AB'
    $docUpperJti = New-TestSignedDocument -Payload $p -Rsa $rsa
    $r = Invoke-TestVerify -Document $docUpperJti -Policy $jtiPolicy -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'jti-revoked')) 'uppercase jti matches lowercase revocation' (($r | ConvertTo-Json -Compress))

    # 9c3. uppercase JTI accepted when not revoked.
    $r = Invoke-TestVerify -Document $docUpperJti -Policy $policy -Fx $fx
    Assert-That ([bool]$r.ok -and ([string]$r.reason -ceq 'attestation-valid')) 'uppercase jti accepted when not revoked' (($r | ConvertTo-Json -Compress))

    # 9c4. malformed revoked_jtis (string, not array) fails closed as policy-invalid.
    $badRevStr = ('{"schema_version":1,"status":"ENABLED","max_skew_seconds":60,"max_lifetime_seconds":900,"trusted_issuers":[{"issuer_id":"test-issuer-fixture-01","public_key_base64":"' + $fx.spkiB64 + '","revoked":false}],"revoked_jtis":"12345678-1234-1234-1234-1234567890ab"}')
    $r = Invoke-TestVerify -Document $doc -Policy $badRevStr -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'policy-invalid')) 'string revoked_jtis rejected as policy-invalid' (($r | ConvertTo-Json -Compress))

    # 9c5. malformed revoked_jtis list item (non-GUID string) fails closed as policy-invalid.
    $badRevItem = ('{"schema_version":1,"status":"ENABLED","max_skew_seconds":60,"max_lifetime_seconds":900,"trusted_issuers":[{"issuer_id":"test-issuer-fixture-01","public_key_base64":"' + $fx.spkiB64 + '","revoked":false}],"revoked_jtis":["not-a-guid"]}')
    $r = Invoke-TestVerify -Document $doc -Policy $badRevItem -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'policy-invalid')) 'non-GUID revoked_jtis item rejected as policy-invalid' (($r | ConvertTo-Json -Compress))

    # 9c6. malformed revoked_jtis list item (non-string) fails closed as policy-invalid.
    $badRevNum = ('{"schema_version":1,"status":"ENABLED","max_skew_seconds":60,"max_lifetime_seconds":900,"trusted_issuers":[{"issuer_id":"test-issuer-fixture-01","public_key_base64":"' + $fx.spkiB64 + '","revoked":false}],"revoked_jtis":[12345]}')
    $r = Invoke-TestVerify -Document $doc -Policy $badRevNum -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'policy-invalid')) 'non-string revoked_jtis item rejected as policy-invalid' (($r | ConvertTo-Json -Compress))

    # 9d1. duplicate issuer_id (active first, revoked second) rejected as policy-invalid, not bypassed via first match.
    $dupActiveFirst = ('{"schema_version":1,"status":"ENABLED","max_skew_seconds":60,"max_lifetime_seconds":900,"trusted_issuers":[{"issuer_id":"test-issuer-fixture-01","public_key_base64":"' + $fx.spkiB64 + '","revoked":false},{"issuer_id":"test-issuer-fixture-01","public_key_base64":"' + $fx.spkiB64 + '","revoked":true}],"revoked_jtis":[]}')
    $r = Invoke-TestVerify -Document $doc -Policy $dupActiveFirst -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'policy-invalid')) 'duplicate issuer active+revoked rejected as policy-invalid' (($r | ConvertTo-Json -Compress))

    # 9d2. duplicate issuer_id in reverse order (revoked first, active second) also rejected as policy-invalid.
    $dupRevokedFirst = ('{"schema_version":1,"status":"ENABLED","max_skew_seconds":60,"max_lifetime_seconds":900,"trusted_issuers":[{"issuer_id":"test-issuer-fixture-01","public_key_base64":"' + $fx.spkiB64 + '","revoked":true},{"issuer_id":"test-issuer-fixture-01","public_key_base64":"' + $fx.spkiB64 + '","revoked":false}],"revoked_jtis":[]}')
    $r = Invoke-TestVerify -Document $doc -Policy $dupRevokedFirst -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'policy-invalid')) 'duplicate issuer revoked+active rejected as policy-invalid' (($r | ConvertTo-Json -Compress))

    # 9d3. duplicate issuer_id differing only by case rejected as policy-invalid (case-insensitive).
    $dupCase = ('{"schema_version":1,"status":"ENABLED","max_skew_seconds":60,"max_lifetime_seconds":900,"trusted_issuers":[{"issuer_id":"test-issuer-fixture-01","public_key_base64":"' + $fx.spkiB64 + '","revoked":false},{"issuer_id":"TEST-ISSUER-FIXTURE-01","public_key_base64":"' + $fx.spkiB64 + '","revoked":false}],"revoked_jtis":[]}')
    $r = Invoke-TestVerify -Document $doc -Policy $dupCase -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'policy-invalid')) 'case-insensitive duplicate issuer rejected as policy-invalid' (($r | ConvertTo-Json -Compress))

    # 9d4. malformed entry (missing public_key_base64) coexisting with a valid issuer rejected as policy-invalid.
    $malformedSibling = ('{"schema_version":1,"status":"ENABLED","max_skew_seconds":60,"max_lifetime_seconds":900,"trusted_issuers":[{"issuer_id":"test-issuer-fixture-01","public_key_base64":"' + $fx.spkiB64 + '","revoked":false},{"issuer_id":"other-issuer-02","revoked":false}],"revoked_jtis":[]}')
    $r = Invoke-TestVerify -Document $doc -Policy $malformedSibling -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'policy-invalid')) 'malformed sibling entry rejected as policy-invalid' (($r | ConvertTo-Json -Compress))

    # 9d5. entry missing revoked field rejected as policy-invalid (revoked is required).
    $missingRevoked = ('{"schema_version":1,"status":"ENABLED","max_skew_seconds":60,"max_lifetime_seconds":900,"trusted_issuers":[{"issuer_id":"test-issuer-fixture-01","public_key_base64":"' + $fx.spkiB64 + '"}],"revoked_jtis":[]}')
    $r = Invoke-TestVerify -Document $doc -Policy $missingRevoked -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'policy-invalid')) 'issuer entry without revoked rejected as policy-invalid' (($r | ConvertTo-Json -Compress))

    # 9d6. trusted_issuers as string rejected as policy-invalid (never silently skipped).
    $issStr = ('{"schema_version":1,"status":"ENABLED","max_skew_seconds":60,"max_lifetime_seconds":900,"trusted_issuers":"oops","revoked_jtis":[]}')
    $r = Invoke-TestVerify -Document $doc -Policy $issStr -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'policy-invalid')) 'string trusted_issuers rejected as policy-invalid' (($r | ConvertTo-Json -Compress))

    # 9d7. trusted_issuers null rejected as policy-invalid (empty array stays policy-blocked).
    $issNull = '{"schema_version":1,"status":"ENABLED","max_skew_seconds":60,"max_lifetime_seconds":900,"trusted_issuers":null,"revoked_jtis":[]}'
    $r = Invoke-TestVerify -Document $doc -Policy $issNull -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'policy-invalid')) 'null trusted_issuers rejected as policy-invalid' (($r | ConvertTo-Json -Compress))

    # 9d8. trusted_issuers as dictionary rejected as policy-invalid.
    $issDict = '{"schema_version":1,"status":"ENABLED","max_skew_seconds":60,"max_lifetime_seconds":900,"trusted_issuers":{"issuer_id":"test-issuer-fixture-01"},"revoked_jtis":[]}'
    $r = Invoke-TestVerify -Document $doc -Policy $issDict -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'policy-invalid')) 'dictionary trusted_issuers rejected as policy-invalid' (($r | ConvertTo-Json -Compress))

    # 9d9. duplicate root trust key (status) rejected as policy-invalid, not last-wins.
    $dupStatus = ('{"schema_version":1,"status":"ENABLED","status":"BLOCKED","max_skew_seconds":60,"max_lifetime_seconds":900,"trusted_issuers":[{"issuer_id":"test-issuer-fixture-01","public_key_base64":"' + $fx.spkiB64 + '","revoked":false}],"revoked_jtis":[]}')
    $r = Invoke-TestVerify -Document $doc -Policy $dupStatus -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'policy-invalid')) 'duplicate policy status rejected as policy-invalid' (($r | ConvertTo-Json -Compress))

    # 9d10. duplicate nested issuer key (issuer_id) rejected as policy-invalid, not last-wins.
    $dupIssuerKey = ('{"schema_version":1,"status":"ENABLED","max_skew_seconds":60,"max_lifetime_seconds":900,"trusted_issuers":[{"issuer_id":"test-issuer-fixture-01","issuer_id":"test-issuer-fixture-01","public_key_base64":"' + $fx.spkiB64 + '","revoked":false}],"revoked_jtis":[]}')
    $r = Invoke-TestVerify -Document $doc -Policy $dupIssuerKey -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'policy-invalid')) 'duplicate nested issuer_id rejected as policy-invalid' (($r | ConvertTo-Json -Compress))

    # 10a. malformed input.
    $r = Invoke-TestVerify -Document 'not-json{{{' -Policy $policy -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'malformed')) 'malformed input rejected' (($r | ConvertTo-Json -Compress))

    # 10b. extra field input rejected (payload with unknown field, resigned).
    $p = New-TestPayload
    $p['extra_field'] = 'nope'
    $docExtra = New-TestSignedDocumentLenient -Payload $p -Rsa $rsa
    $r = Invoke-TestVerify -Document $docExtra -Policy $policy -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'unknown-field')) 'extra-field input rejected' (($r | ConvertTo-Json -Compress))

    # 10c. noncanonical input rejected (same semantics, pretty whitespace).
    $canon2 = Get-OcSoloAttestationCanonicalJson -Payload (New-TestPayload)
    $pretty = $canon2.Replace(',', ', ')
    $sigPretty = $rsa.SignData([Text.Encoding]::UTF8.GetBytes($pretty), [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pss)
    $docPretty = ('{"payload":' + $pretty + ',"signature_base64":"' + ([Convert]::ToBase64String($sigPretty)) + '"}')
    $r = Invoke-TestVerify -Document $docPretty -Policy $policy -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'noncanonical')) 'noncanonical whitespace rejected' (($r | ConvertTo-Json -Compress))

    # 10d. duplicate field rejected.
    $dupDoc = $doc.Replace('"pr_number":999', '"pr_number":999,"pr_number":999')
    $r = Invoke-TestVerify -Document $dupDoc -Policy $policy -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'duplicate-field')) 'duplicate field rejected' (($r | ConvertTo-Json -Compress))

    # 11. shipped source verifier policy is BLOCKED and verifies nothing.
    $sourcePolicyPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\source\registry\solo-attestation-policy.json'))
    $sourcePolicyText = [IO.File]::ReadAllText($sourcePolicyPath, [Text.Encoding]::UTF8)
    $sourcePolicy = ($sourcePolicyText | ConvertFrom-Json)
    Assert-That (([string]$sourcePolicy.status -ceq 'BLOCKED')) 'shipped policy is BLOCKED' ([string]$sourcePolicy.status)
    Assert-That ((@($sourcePolicy.trusted_issuers).Count -eq 0)) 'shipped policy carries no trusted issuers' ''
    $r = Invoke-TestVerify -Document $doc -Policy $sourcePolicyText -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'policy-blocked')) 'BLOCKED source policy verifies nothing' (($r | ConvertTo-Json -Compress))

    # 12. non-approved verdict rejected.
    $p = New-TestPayload
    $p['reviews'][0]['verdict'] = 'changes_required'
    $docVerdict = New-TestSignedDocument -Payload $p -Rsa $rsa
    $r = Invoke-TestVerify -Document $docVerdict -Policy $policy -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'verdict-not-approved')) 'non-approved verdict rejected' (($r | ConvertTo-Json -Compress))

    # 13. non-native session identifier rejected.
    $p = New-TestPayload
    $p['reviews'][0]['session_id'] = 'human-alice'
    $docSess = New-TestSignedDocument -Payload $p -Rsa $rsa
    $r = Invoke-TestVerify -Document $docSess -Policy $policy -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'session-invalid')) 'non-native session id rejected' (($r | ConvertTo-Json -Compress))

    # 14a. empty evidence list rejected.
    $p = New-TestPayload
    $p['reviews'][0]['evidence_sha256'] = @()
    $docEvEmpty = New-TestSignedDocumentLenient -Payload $p -Rsa $rsa
    $r = Invoke-TestVerify -Document $docEvEmpty -Policy $policy -Fx $fx
    Assert-That ((-not [bool]$r.ok)) 'empty evidence list rejected' (($r | ConvertTo-Json -Compress))

    # 14b. non-array evidence (legacy single string) rejected.
    $p = New-TestPayload
    $p['reviews'][0]['evidence_sha256'] = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $docEvStr = New-TestSignedDocumentLenient -Payload $p -Rsa $rsa
    $r = Invoke-TestVerify -Document $docEvStr -Policy $policy -Fx $fx
    Assert-That ((-not [bool]$r.ok)) 'string evidence rejected, array required' (($r | ConvertTo-Json -Compress))

    # 14c. invalid evidence entry rejected.
    $p = New-TestPayload
    $p['reviews'][0]['evidence_sha256'] = @('not-a-hash')
    $docEvBad = New-TestSignedDocumentLenient -Payload $p -Rsa $rsa
    $r = Invoke-TestVerify -Document $docEvBad -Policy $policy -Fx $fx
    Assert-That ((-not [bool]$r.ok)) 'invalid evidence entry rejected' (($r | ConvertTo-Json -Compress))

    # 15a. exact expiry instant is expired (now >= expires_at).
    $r = Invoke-TestVerify -Document $doc -Policy $policy -Fx $fx -Now '2026-11-04T10:10:00Z'
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'expired')) 'exact expiry instant rejected as expired' (($r | ConvertTo-Json -Compress))

    # 15a2. one second before expiry still valid.
    $r = Invoke-TestVerify -Document $doc -Policy $policy -Fx $fx -Now '2026-11-04T10:09:59Z'
    Assert-That ([bool]$r.ok -and ([string]$r.reason -ceq 'attestation-valid')) 'one second before expiry accepted' (($r | ConvertTo-Json -Compress))

    # 15b. one second past expiry rejected (no post-expiry skew).
    $r = Invoke-TestVerify -Document $doc -Policy $policy -Fx $fx -Now '2026-11-04T10:10:01Z'
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'expired')) 'just-expired attestation rejected' (($r | ConvertTo-Json -Compress))

    # 16a. oversize document rejected before parsing.
    $bigDoc = $doc + (' ' * 70000)
    $r = Invoke-TestVerify -Document $bigDoc -Policy $policy -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'oversize')) 'oversize document rejected' ([string]$r.reason)

    # 16b. oversize verifier policy rejected before parsing.
    $bigPolicy = $policy + (' ' * 40000)
    $r = Invoke-TestVerify -Document $doc -Policy $bigPolicy -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'policy-invalid')) 'oversize policy rejected' ([string]$r.reason)

    # 16c. outer envelope whitespace rejected (leading).
    $r = Invoke-TestVerify -Document (" `n" + $doc) -Policy $policy -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'noncanonical')) 'leading envelope whitespace rejected' (($r | ConvertTo-Json -Compress))

    # 16d. outer envelope whitespace rejected (trailing).
    $r = Invoke-TestVerify -Document ($doc + "`n") -Policy $policy -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'noncanonical')) 'trailing envelope whitespace rejected' (($r | ConvertTo-Json -Compress))

    # 17. 1024-bit RSA key rejected (minimum 2048-bit).
    $weak = New-Object System.Security.Cryptography.RSACng(1024)
    try {
        $wparams = $weak.ExportParameters($false)
        $wspki = ConvertTo-TestSpkiDer -Modulus $wparams.Modulus -Exponent $wparams.Exponent
        $wspkiB64 = [Convert]::ToBase64String($wspki)
        $wpolicy = New-TestVerifierPolicy -SpkiB64 $wspkiB64
        $wpayload = New-TestPayload
        $wdoc = New-TestSignedDocument -Payload $wpayload -Rsa $weak
        $r = Invoke-TestVerify -Document $wdoc -Policy $wpolicy -Fx $fx
        Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'unknown-issuer')) '1024-bit key rejected' (($r | ConvertTo-Json -Compress))
    }
    finally {
        try { $weak.Dispose() } catch { }
    }

    # 17b. 256-byte modulus with top bit clear (2047 effective bits) rejected.
    $narrow = New-Object byte[] 256
    $narrow[0] = 0x40
    for ($bi = 1; $bi -lt 256; $bi++) { $narrow[$bi] = 0xA5 }
    $narrowSpki = ConvertTo-TestSpkiDer -Modulus $narrow -Exponent ([byte[]]@(1, 0, 1))
    $narrowB64 = [Convert]::ToBase64String($narrowSpki)
    $narrowPolicy = New-TestVerifierPolicy -SpkiB64 $narrowB64
    $narrowPayload = New-TestPayload
    $narrowDoc = New-TestSignedDocument -Payload $narrowPayload -Rsa $rsa
    $r = Invoke-TestVerify -Document $narrowDoc -Policy $narrowPolicy -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'unknown-issuer')) '2047-bit modulus rejected' (($r | ConvertTo-Json -Compress))

    # 17c. RSA exponent 1 rejected (public-only malformed-key policy, unknown-issuer).
    $realParams = $rsa.ExportParameters($false)
    $exp1Spki = ConvertTo-TestSpkiDer -Modulus $realParams.Modulus -Exponent ([byte[]]@(1))
    $exp1B64 = [Convert]::ToBase64String($exp1Spki)
    $exp1Policy = New-TestVerifierPolicy -SpkiB64 $exp1B64
    $expPayload = New-TestPayload
    $expDoc = New-TestSignedDocument -Payload $expPayload -Rsa $rsa
    $r = Invoke-TestVerify -Document $expDoc -Policy $exp1Policy -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'unknown-issuer')) 'RSA exponent 1 rejected' (($r | ConvertTo-Json -Compress))

    # 17d. RSA exponent 2 rejected (public-only malformed-key policy, unknown-issuer).
    $exp2Spki = ConvertTo-TestSpkiDer -Modulus $realParams.Modulus -Exponent ([byte[]]@(2))
    $exp2B64 = [Convert]::ToBase64String($exp2Spki)
    $exp2Policy = New-TestVerifierPolicy -SpkiB64 $exp2B64
    $r = Invoke-TestVerify -Document $expDoc -Policy $exp2Policy -Fx $fx
    Assert-That ((-not [bool]$r.ok) -and ([string]$r.reason -ceq 'unknown-issuer')) 'RSA exponent 2 rejected' (($r | ConvertTo-Json -Compress))

    # 18. same exact operation remains idempotent (re-verify identical document).
    $r = Invoke-TestVerify -Document $doc -Policy $policy -Fx $fx
    Assert-That ([bool]$r.ok -and ([string]$r.reason -ceq 'attestation-valid')) 'same-operation re-verify stays valid' (($r | ConvertTo-Json -Compress))
}
finally {
    try { $fx.rsa.Dispose() } catch { }
}

Write-Host ("PASS OrchestrationSoloAttestation " + [string]$passed + " assertions")
