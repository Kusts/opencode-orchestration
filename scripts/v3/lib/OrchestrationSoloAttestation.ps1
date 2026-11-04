<#!
.SYNOPSIS
    Solo-maintainer signed attestation: offline-only, fail-closed contract verifier.
.DESCRIPTION
    Contract-only validation for a versioned solo-maintainer attestation
    document with a detached RSA-PSS-SHA256 signature. This library:

      - defines a fixed payload schema (schema_version 1) with a canonical
        UTF-8 byte representation; any unknown, duplicate, misordered, or
        noncanonical field fails closed;
      - verifies the detached signature ONLY against public keys supplied
        in an explicit caller-provided verifier policy (public key only,
        SubjectPublicKeyInfo DER, base64);
      - binds the expected repository, PR number, head SHA, task_id,
        run_id, operation_id, solo-maintainer delivery profile, and
        policy_id + policy_digest supplied by the caller;
      - checks issuer allowlist/revocation, the required reviewer then
        security-reviewer entries (approved verdicts, native ses_*
        identifiers, evidence/kernel-record SHA-256 hashes), the jti GUID,
        and a short issued/expiry window;
      - returns a structured {ok, reason} object only and makes NO
        authority claim: it never grants readiness, resume, merge, or DONE.

    TRUSTED-CALLER RESPONSIBILITIES (read carefully): the expected context
    values (repository, PR, SHAs, ids, profile, policy digest) and the
    verifier policy (trusted issuers, revocation lists, skew/lifetime
    bounds) are inputs the CALLER must obtain from a trusted source. This
    function cannot prove reviewer source provenance (a native ses_*
    string inside the payload is a claim, not proof of origin) nor key
    isolation (that the signing key is held only by the named issuer).
    It is a cryptographic document-contract check only.

    NOT WIRED TO READINESS: a valid attestation does NOT imply
    READY_FOR_RESUME, resume authorization, merge eligibility, or task
    completion. Operational use is on HOLD; the shipped verifier policy
    (source/registry/solo-attestation-policy.json) is BLOCKED with no
    trusted issuers, so nothing verifies until a human operator
    provisions an explicit policy.

    There is deliberately NO signing/issuer function and NO
    arbitrary-JSON signing API in this module. Tests generate synthetic
    RSA keypairs in memory only, inside test code.

    Offline only. No file, network, or process side effects. No key
    generation. PowerShell 5.1 compatible. ASCII-only. Never throws for
    domain input; unexpected internals fail closed as {ok:$false}.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-OcSoloAttestationFieldOrder {
    [CmdletBinding()]
    param()
    return @('schema_version', 'policy_id', 'policy_digest', 'delivery_profile', 'repository', 'pr_number', 'head_sha', 'task_id', 'run_id', 'operation_id', 'issuer_id', 'issued_at', 'expires_at', 'jti', 'reviews')
}

function Get-OcSoloAttestationReviewFieldOrder {
    [CmdletBinding()]
    param()
    return @('role', 'session_id', 'verdict', 'candidate_sha', 'evidence_sha256', 'kernel_record_sha256')
}

function Get-OcSoloAttestationNode {
    [CmdletBinding()]
    param($Node, [Parameter(Mandatory = $true)][string]$Name)
    try {
        if ($null -eq $Node) { return @{ found = $false; value = $null } }
        if ($Node -is [System.Collections.IDictionary]) {
            foreach ($k in @($Node.Keys)) {
                if ([string]$k -ceq $Name) { return @{ found = $true; value = $Node[$k] } }
            }
            return @{ found = $false; value = $null }
        }
        $prop = @($Node.PSObject.Properties) | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1
        if ($null -eq $prop) { return @{ found = $false; value = $null } }
        return @{ found = $true; value = $prop.Value }
    }
    catch { return @{ found = $false; value = $null } }
}

function Get-OcSoloAttestationNodeKeys {
    [CmdletBinding()]
    param($Node)
    try {
        if ($null -eq $Node) { return ([string[]]@()) }
        if ($Node -is [System.Collections.IDictionary]) { return ([string[]]@($Node.Keys | ForEach-Object { [string]$_ })) }
        return ([string[]]@(@($Node.PSObject.Properties) | ForEach-Object { [string]$_.Name }))
    }
    catch { return ([string[]]@()) }
}

function ConvertTo-OcSoloAttestationEscaped {
    [CmdletBinding()]
    param([string]$Text)
    $sb = New-Object System.Text.StringBuilder
    try {
        foreach ($ch in ([string]$Text).ToCharArray()) {
            $code = [int]$ch
            if ($ch -ceq '"') { $sb.Append('\"') | Out-Null }
            elseif ($ch -ceq '\') { $sb.Append('\\') | Out-Null }
            elseif ($code -eq 8) { $sb.Append('\b') | Out-Null }
            elseif ($code -eq 9) { $sb.Append('\t') | Out-Null }
            elseif ($code -eq 10) { $sb.Append('\n') | Out-Null }
            elseif ($code -eq 12) { $sb.Append('\f') | Out-Null }
            elseif ($code -eq 13) { $sb.Append('\r') | Out-Null }
            elseif (($code -lt 32) -or ($code -gt 126)) { $sb.Append(('\u' + $code.ToString('x4'))) | Out-Null }
            else { $sb.Append($ch) | Out-Null }
        }
    }
    catch { return $null }
    return $sb.ToString()
}

function ConvertTo-OcSoloAttestationJsonString {
    [CmdletBinding()]
    param([string]$Text)
    $e = ConvertTo-OcSoloAttestationEscaped -Text ([string]$Text)
    if ($null -eq $e) { return $null }
    return ('"' + $e + '"')
}

function ConvertTo-OcSoloAttestationCanonicalInstant {
    <#
    .SYNOPSIS
        Normalizes an issued/expiry value to canonical Zulu text.
        Accepts the strict Zulu string form, or a DateTime already
        carrying the same instant (PowerShell 7 ConvertFrom-Json coerces
        date-like strings to DateTime; Windows PowerShell 5.1 keeps
        strings). DateTime input is rendered in UTC with trailing-zero
        fraction trimming, so only exactly-normalized raw text survives
        the later byte comparison. Anything else fails.
    #>
    [CmdletBinding()]
    param($Value)
    try {
        if ($Value -is [DateTime]) {
            $u = ([DateTime]$Value).ToUniversalTime()
            $text = $u.ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
            $ticks = [long]($u.Ticks % 10000000)
            if ($ticks -ne 0) {
                $frac = $ticks.ToString('D7', [Globalization.CultureInfo]::InvariantCulture).TrimEnd('0')
                $text += ('.' + $frac)
            }
            return @{ ok = $true; text = ($text + 'Z') }
        }
        if ($Value -is [string]) {
            $t = ([string]$Value).Trim()
            if ($t -cmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$') {
                return @{ ok = $true; text = $t }
            }
        }
    }
    catch { }
    return @{ ok = $false; text = '' }
}

function Get-OcSoloAttestationCanonicalJson {
    <#
    .SYNOPSIS
        Builds the canonical UTF-8 (ASCII-only) JSON bytes source for a
        payload node. Returns '' when the node is not exactly shaped.
        Canonicalization only; never signs.
    #>
    [CmdletBinding()]
    param($Payload)
    try {
        $keys = Get-OcSoloAttestationNodeKeys -Node $Payload
        $want = Get-OcSoloAttestationFieldOrder
        if ($keys.Count -ne $want.Count) { return '' }
        for ($i = 0; $i -lt $want.Count; $i++) {
            if ($keys[$i] -cne $want[$i]) { return '' }
        }
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($k in $want) {
            $slot = Get-OcSoloAttestationNode -Node $Payload -Name $k
            if (-not [bool]$slot.found) { return '' }
            $v = $slot.value
            if (($k -ceq 'schema_version') -or ($k -ceq 'pr_number')) {
                try {
                    if (($v -is [bool]) -or ($v -is [string]) -or ($v -is [double]) -or ($v -is [decimal])) { return '' }
                    $n = [long]$v
                }
                catch { return '' }
                $parts.Add(('"' + $k + '":' + $n.ToString([Globalization.CultureInfo]::InvariantCulture))) | Out-Null
            }
            elseif ($k -ceq 'reviews') {
                if ($null -eq $v) { return '' }
                $items = @($v)
                if ($items.Count -ne 2) { return '' }
                $rfields = Get-OcSoloAttestationReviewFieldOrder
                $rparts = New-Object System.Collections.Generic.List[string]
                foreach ($item in $items) {
                    $rk = Get-OcSoloAttestationNodeKeys -Node $item
                    if ($rk.Count -ne $rfields.Count) { return '' }
                    for ($j = 0; $j -lt $rfields.Count; $j++) {
                        if ($rk[$j] -cne $rfields[$j]) { return '' }
                    }
                    $rp = New-Object System.Collections.Generic.List[string]
                    foreach ($f in $rfields) {
                        $fs = Get-OcSoloAttestationNode -Node $item -Name $f
                        if (-not [bool]$fs.found) { return '' }
                        if ($f -ceq 'evidence_sha256') {
                            if (($null -eq $fs.value) -or ($fs.value -is [string])) { return '' }
                            if ($fs.value -is [System.Collections.IDictionary]) { return '' }
                            if (-not ($fs.value -is [System.Collections.IEnumerable])) { return '' }
                            $evItems = @($fs.value)
                            if (($evItems.Count -lt 1) -or ($evItems.Count -gt 32)) { return '' }
                            $evParts = New-Object System.Collections.Generic.List[string]
                            foreach ($ev in $evItems) {
                                if (($null -eq $ev) -or -not ($ev -is [string])) { return '' }
                                $ejs = ConvertTo-OcSoloAttestationJsonString -Text ([string]$ev)
                                if ($null -eq $ejs) { return '' }
                                $evParts.Add($ejs) | Out-Null
                            }
                            $rp.Add(('"evidence_sha256":[' + ($evParts -join ',') + ']')) | Out-Null
                        }
                        else {
                        if (($null -eq $fs.value) -or -not ($fs.value -is [string])) { return '' }
                        $js = ConvertTo-OcSoloAttestationJsonString -Text ([string]$fs.value)
                        if ($null -eq $js) { return '' }
                        $rp.Add(('"' + $f + '":' + $js)) | Out-Null
                        }
                    }
                    $rparts.Add(('{' + ($rp -join ',') + '}')) | Out-Null
                }
                $parts.Add(('"reviews":[' + ($rparts -join ',') + ']')) | Out-Null
            }
            elseif (($k -ceq 'issued_at') -or ($k -ceq 'expires_at')) {
                $inst = ConvertTo-OcSoloAttestationCanonicalInstant -Value $v
                if (-not [bool]$inst.ok) { return '' }
                $js = ConvertTo-OcSoloAttestationJsonString -Text ([string]$inst.text)
                if ($null -eq $js) { return '' }
                $parts.Add(('"' + $k + '":' + $js)) | Out-Null
            }
            else {
                if (($null -eq $v) -or -not ($v -is [string])) { return '' }
                $js = ConvertTo-OcSoloAttestationJsonString -Text ([string]$v)
                if ($null -eq $js) { return '' }
                $parts.Add(('"' + $k + '":' + $js)) | Out-Null
            }
        }
        return ('{' + ($parts -join ',') + '}')
    }
    catch { return '' }
}

function Test-OcSoloAttestationDuplicates {
    <#
    .SYNOPSIS
        Scans raw JSON text for duplicate keys within any single object.
        String-aware (escapes, \uXXXX). Returns $true when duplicated.
    #>
    [CmdletBinding()]
    param([string]$Text)
    try {
        $s = [string]$Text
        $stack = New-Object System.Collections.ArrayList
        $i = 0
        $n = $s.Length
        while ($i -lt $n) {
            $c = $s[$i]
            if (($c -ceq '{')) {
                $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
                [void]$stack.Add(@{ kind = 'obj'; keys = $set })
                $i++
            }
            elseif (($c -ceq '[')) {
                [void]$stack.Add(@{ kind = 'arr' })
                $i++
            }
            elseif ((($c -ceq '}') -or ($c -ceq ']')) -and ($stack.Count -gt 0)) {
                $stack.RemoveAt($stack.Count - 1)
                $i++
            }
            elseif ($c -ceq '"') {
                $sb = New-Object System.Text.StringBuilder
                $j = $i + 1
                $closed = $false
                while ($j -lt $n) {
                    $d = $s[$j]
                    if ($d -ceq '\') {
                        if (($j + 1) -ge $n) { break }
                        $e = $s[$j + 1]
                        if ($e -ceq 'u') {
                            if (($j + 5) -ge $n) { break }
                            $hex = $s.Substring($j + 2, 4)
                            $code = 0
                            if (-not [int]::TryParse($hex, [Globalization.NumberStyles]::HexNumber, [Globalization.CultureInfo]::InvariantCulture, [ref]$code)) { break }
                            $sb.Append([char]$code) | Out-Null
                            $j += 6
                        }
                        else {
                            if ($e -ceq '"') { $sb.Append('"') | Out-Null }
                            elseif ($e -ceq '\') { $sb.Append('\') | Out-Null }
                            elseif ($e -ceq '/') { $sb.Append('/') | Out-Null }
                            elseif ($e -ceq 'b') { $sb.Append([char]8) | Out-Null }
                            elseif ($e -ceq 'f') { $sb.Append([char]12) | Out-Null }
                            elseif ($e -ceq 'n') { $sb.Append([char]10) | Out-Null }
                            elseif ($e -ceq 'r') { $sb.Append([char]13) | Out-Null }
                            elseif ($e -ceq 't') { $sb.Append([char]9) | Out-Null }
                            else { break }
                            $j += 2
                        }
                    }
                    elseif ($d -ceq '"') { $closed = $true; $j++; break }
                    else { $sb.Append($d) | Out-Null; $j++ }
                }
                if (-not $closed) { return $false }
                $k = $j
                while (($k -lt $n) -and (($s[$k] -ceq ' ') -or ($s[$k] -ceq "`t") -or ($s[$k] -ceq "`r") -or ($s[$k] -ceq "`n"))) { $k++ }
                if (($k -lt $n) -and ($s[$k] -ceq ':') -and ($stack.Count -gt 0) -and ([string]$stack[$stack.Count - 1].kind -ceq 'obj')) {
                    $name = $sb.ToString()
                    $set = $stack[$stack.Count - 1].keys
                    if ($set.Contains($name)) { return $true }
                    [void]$set.Add($name)
                }
                $i = $j
            }
            else { $i++ }
        }
    }
    catch { return $false }
    return $false
}

function Get-OcSoloAttestationDerLength {
    [CmdletBinding()]
    param([byte[]]$Bytes, [int]$Offset)
    try {
        if ($Offset -ge $Bytes.Length) { return @{ ok = $false } }
        $first = [int]$Bytes[$Offset]
        if ($first -lt 128) { return @{ ok = $true; length = $first; next = ($Offset + 1) } }
        $count = $first - 128
        if (($count -lt 1) -or ($count -gt 4)) { return @{ ok = $false } }
        if (($Offset + 1 + $count) -gt $Bytes.Length) { return @{ ok = $false } }
        $len = 0
        for ($i = 0; $i -lt $count; $i++) { $len = ($len * 256) + [int]$Bytes[$Offset + 1 + $i] }
        if ($len -lt 0) { return @{ ok = $false } }
        return @{ ok = $true; length = $len; next = ($Offset + 1 + $count) }
    }
    catch { return @{ ok = $false } }
}

function Get-OcSoloAttestationRsaParams {
    <#
    .SYNOPSIS
        Parses a SubjectPublicKeyInfo (DER) carrying rsaEncryption and
        returns RSAParameters (Modulus/Exponent). Anything else fails.
        The public exponent must equal exactly 65537 (bytes 01 00 01,
        the Windows CNG default); exponent 1, 2, and all other values
        fail closed. Effective modulus must be >= 2048 bits.
    #>
    [CmdletBinding()]
    param([byte[]]$Der)
    try {
        $b = $Der
        if (($null -eq $b) -or ($b.Length -lt 10)) { return @{ ok = $false } }
        $p = 0
        if ([int]$b[$p] -ne 48) { return @{ ok = $false } }
        $lr = Get-OcSoloAttestationDerLength -Bytes $b -Offset ($p + 1)
        if (-not [bool]$lr.ok) { return @{ ok = $false } }
        $p = [int]$lr.next
        if ([int]$b[$p] -ne 48) { return @{ ok = $false } }
        $la = Get-OcSoloAttestationDerLength -Bytes $b -Offset ($p + 1)
        if (-not [bool]$la.ok) { return @{ ok = $false } }
        $algStart = [int]$la.next
        $algEnd = $algStart + [int]$la.length
        if ($algEnd -gt $b.Length) { return @{ ok = $false } }
        $q = $algStart
        if ([int]$b[$q] -ne 6) { return @{ ok = $false } }
        $lo = Get-OcSoloAttestationDerLength -Bytes $b -Offset ($q + 1)
        if (-not [bool]$lo.ok) { return @{ ok = $false } }
        $oidStart = [int]$lo.next
        $oidEnd = $oidStart + [int]$lo.length
        if ($oidEnd -gt $b.Length) { return @{ ok = $false } }
        $wantOid = [byte[]]@(42, 134, 72, 134, 247, 13, 1, 1, 1)
        if (($oidEnd - $oidStart) -ne $wantOid.Length) { return @{ ok = $false } }
        for ($i = 0; $i -lt $wantOid.Length; $i++) {
            if ([int]$b[$oidStart + $i] -ne [int]$wantOid[$i]) { return @{ ok = $false } }
        }
        $q = $oidEnd
        if ((($q + 1) -ge $b.Length) -or ([int]$b[$q] -ne 5) -or ([int]$b[$q + 1] -ne 0)) { return @{ ok = $false } }
        $q += 2
        if ($q -ne $algEnd) { return @{ ok = $false } }
        $p = $algEnd
        if ([int]$b[$p] -ne 3) { return @{ ok = $false } }
        $lb = Get-OcSoloAttestationDerLength -Bytes $b -Offset ($p + 1)
        if (-not [bool]$lb.ok) { return @{ ok = $false } }
        $bitStart = [int]$lb.next
        $bitEnd = $bitStart + [int]$lb.length
        if ($bitEnd -gt $b.Length) { return @{ ok = $false } }
        if ([int]$b[$bitStart] -ne 0) { return @{ ok = $false } }
        $r = $bitStart + 1
        if ([int]$b[$r] -ne 48) { return @{ ok = $false } }
        $lrs = Get-OcSoloAttestationDerLength -Bytes $b -Offset ($r + 1)
        if (-not [bool]$lrs.ok) { return @{ ok = $false } }
        $rsStart = [int]$lrs.next
        $rsEnd = $rsStart + [int]$lrs.length
        if ($rsEnd -ne $bitEnd) { return @{ ok = $false } }
        $ints = New-Object System.Collections.ArrayList
        $t = $rsStart
        while ($t -lt $rsEnd) {
            if ([int]$b[$t] -ne 2) { return @{ ok = $false } }
            $li = Get-OcSoloAttestationDerLength -Bytes $b -Offset ($t + 1)
            if (-not [bool]$li.ok) { return @{ ok = $false } }
            $vStart = [int]$li.next
            $vEnd = $vStart + [int]$li.length
            if ($vEnd -gt $rsEnd) { return @{ ok = $false } }
            $val = [byte[]]@($b[$vStart..($vEnd - 1)])
            while (($val.Length -gt 1) -and ([int]$val[0] -eq 0)) { $val = [byte[]]@($val[1..($val.Length - 1)]) }
            [void]$ints.Add($val)
            $t = $vEnd
        }
        if ($ints.Count -ne 2) { return @{ ok = $false } }
        $mod = [byte[]]$ints[0]
        $exp = [byte[]]$ints[1]
        if (($mod.Length -lt 256) -or ($mod.Length -gt 512)) { return @{ ok = $false } }
        $expWant = [byte[]]@(1, 0, 1)
        if ($exp.Length -ne $expWant.Length) { return @{ ok = $false } }
        for ($ei = 0; $ei -lt $expWant.Length; $ei++) {
            if ([int]$exp[$ei] -ne [int]$expWant[$ei]) { return @{ ok = $false } }
        }
        $firstNz = -1
        for ($bi = 0; $bi -lt $mod.Length; $bi++) {
            if ([int]$mod[$bi] -ne 0) { $firstNz = $bi; break }
        }
        if ($firstNz -lt 0) { return @{ ok = $false } }
        $topByte = [int]$mod[$firstNz]
        $topBits = 0
        $shift = $topByte
        while ($shift -gt 0) { $topBits++; $shift = ($shift -shr 1) }
        $effectiveBits = (($mod.Length - $firstNz - 1) * 8) + $topBits
        if ($effectiveBits -lt 2048) { return @{ ok = $false } }
        $rp = New-Object System.Security.Cryptography.RSAParameters
        $rp.Modulus = $mod
        $rp.Exponent = $exp
        return @{ ok = $true; params = $rp }
    }
    catch { return @{ ok = $false } }
}

function New-OcSoloAttestationResult {
    [CmdletBinding()]
    param([bool]$Ok, [Parameter(Mandatory = $true)][string]$Reason)
    return [PSCustomObject]@{ ok = [bool]$Ok; reason = [string]$Reason }
}

function Test-OcSoloAttestationInstant {
    [CmdletBinding()]
    param([string]$Text)
    try {
        $t = ([string]$Text).Trim()
        if (-not ($t -cmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$')) {
            return @{ ok = $false }
        }
        $dt = [DateTime]::ParseExact($t, 'yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
        if ($t -cmatch '\.') {
            try {
                $frac = $t.Substring($t.IndexOf('.'), ($t.Length - $t.IndexOf('.') - 1))
                $dt = [DateTime]::Parse($t, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
            }
            catch { return @{ ok = $false } }
        }
        if ($dt.Kind -ne [DateTimeKind]::Utc) { $dt = [DateTime]::SpecifyKind($dt, [DateTimeKind]::Utc) }
        return @{ ok = $true; instant = $dt }
    }
    catch { return @{ ok = $false } }
}

function Get-OcSoloAttestationInstantValue {
    <#
    .SYNOPSIS
        Resolves an issued/expiry node to a UTC instant. Accepts the
        strict Zulu string or a DateTime carrying the same instant (see
        ConvertTo-OcSoloAttestationCanonicalInstant). By the time this
        runs, the raw document has already matched canonical bytes, so a
        DateTime here provably came from exactly-normalized Zulu text.
    #>
    [CmdletBinding()]
    param($Value)
    try {
        if ($Value -is [DateTime]) {
            return @{ ok = $true; instant = ([DateTime]$Value).ToUniversalTime() }
        }
        if ($Value -is [string]) {
            return (Test-OcSoloAttestationInstant -Text ([string]$Value))
        }
    }
    catch { }
    return @{ ok = $false }
}

function Test-OcSoloAttestationDocument {
    <#
    .SYNOPSIS
        Verifies a solo-maintainer attestation document against explicit
        expected context and an explicit verifier policy. Returns
        {ok:$true, reason:'attestation-valid'} or {ok:$false, reason:<code>}.
    .DESCRIPTION
        See the file header: expected context and verifier policy are
        trusted-caller responsibilities; this is a contract-only check,
        not wired to readiness, and proves neither reviewer provenance
        nor key isolation. Offline; no side effects; never throws.
    #>
    [CmdletBinding()]
    param(
        [string]$DocumentJson = '',
        [string]$ExpectedRepository = '',
        [int]$ExpectedPrNumber = 0,
        [string]$ExpectedHeadSha = '',
        [string]$ExpectedTaskId = '',
        [string]$ExpectedRunId = '',
        [string]$ExpectedOperationId = '',
        [string]$ExpectedDeliveryProfile = '',
        [string]$ExpectedPolicyId = '',
        [string]$ExpectedPolicyDigest = '',
        [string]$VerifierPolicyJson = '',
        [string]$NowUtc = ''
    )
    try {
        $rawIn = [string]$DocumentJson
        if ([string]::IsNullOrWhiteSpace($rawIn)) { return (New-OcSoloAttestationResult -Ok $false -Reason 'malformed') }
        try {
            if ([Text.Encoding]::UTF8.GetByteCount($rawIn) -gt 65536) { return (New-OcSoloAttestationResult -Ok $false -Reason 'oversize') }
        }
        catch { return (New-OcSoloAttestationResult -Ok $false -Reason 'malformed') }
        if ($rawIn -cne $rawIn.Trim()) { return (New-OcSoloAttestationResult -Ok $false -Reason 'noncanonical') }
        $raw = $rawIn
        if ([string]::IsNullOrWhiteSpace($raw)) { return (New-OcSoloAttestationResult -Ok $false -Reason 'malformed') }
        $doc = $null
        try { $doc = ($raw | ConvertFrom-Json) }
        catch { return (New-OcSoloAttestationResult -Ok $false -Reason 'malformed') }
        if ($null -eq $doc) { return (New-OcSoloAttestationResult -Ok $false -Reason 'malformed') }
        if (Test-OcSoloAttestationDuplicates -Text $raw) {
            return (New-OcSoloAttestationResult -Ok $false -Reason 'duplicate-field')
        }
        $envKeys = Get-OcSoloAttestationNodeKeys -Node $doc
        if (($envKeys.Count -ne 2) -or ($envKeys[0] -cne 'payload') -or ($envKeys[1] -cne 'signature_base64')) {
            return (New-OcSoloAttestationResult -Ok $false -Reason 'envelope-invalid')
        }
        $sigSlot = Get-OcSoloAttestationNode -Node $doc -Name 'signature_base64'
        $paySlot = Get-OcSoloAttestationNode -Node $doc -Name 'payload'
        if ((-not [bool]$sigSlot.found) -or (-not [bool]$paySlot.found)) {
            return (New-OcSoloAttestationResult -Ok $false -Reason 'envelope-invalid')
        }
        if (($null -eq $sigSlot.value) -or -not ($sigSlot.value -is [string])) {
            return (New-OcSoloAttestationResult -Ok $false -Reason 'signature-malformed')
        }
        $sigB64 = ([string]$sigSlot.value).Trim()
        if ([string]::IsNullOrWhiteSpace($sigB64)) {
            return (New-OcSoloAttestationResult -Ok $false -Reason 'signature-malformed')
        }

        $prawIn = [string]$VerifierPolicyJson
        if ([string]::IsNullOrWhiteSpace($prawIn)) { return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid') }
        try {
            if ([Text.Encoding]::UTF8.GetByteCount($prawIn) -gt 32768) { return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid') }
        }
        catch { return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid') }
        $praw = $prawIn.Trim()
        if ([string]::IsNullOrWhiteSpace($praw)) { return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid') }
        $vp = $null
        if (Test-OcSoloAttestationDuplicates -Text $praw) { return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid') }
        try { $vp = ($praw | ConvertFrom-Json) }
        catch { return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid') }
        if ($null -eq $vp) { return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid') }
        $stSlot = Get-OcSoloAttestationNode -Node $vp -Name 'status'
        $status = ''
        if ([bool]$stSlot.found -and ($null -ne $stSlot.value)) { $status = ([string]$stSlot.value).Trim() }
        if ($status -cne 'ENABLED') { return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-blocked') }
        $issSlot = Get-OcSoloAttestationNode -Node $vp -Name 'trusted_issuers'
        if (-not [bool]$issSlot.found) { return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-blocked') }
        $issRaw = $issSlot.value
        if ($null -eq $issRaw) { return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid') }
        if (($issRaw -is [string]) -or ($issRaw -is [System.Collections.IDictionary])) {
            return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid')
        }
        if (-not ($issRaw -is [System.Collections.IEnumerable])) {
            return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid')
        }
        $issuers = @($issRaw)
        if ($issuers.Count -eq 0) { return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-blocked') }
        if ($issuers.Count -gt 64) { return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid') }
        $seenIssuerIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($cand in $issuers) {
            if ($null -eq $cand) { return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid') }
            if ($cand -is [System.Collections.IDictionary]) { }
            elseif (($cand -is [string]) -or ($cand -is [bool]) -or ($cand -is [ValueType]) -or ($cand -is [System.Collections.IEnumerable])) {
                return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid')
            }
            $cidSlot = Get-OcSoloAttestationNode -Node $cand -Name 'issuer_id'
            if ((-not [bool]$cidSlot.found) -or ($null -eq $cidSlot.value) -or -not ($cidSlot.value -is [string])) {
                return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid')
            }
            $cidText = ([string]$cidSlot.value)
            if ([string]::IsNullOrWhiteSpace($cidText)) { return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid') }
            if ($cidText.Length -gt 128) { return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid') }
            if (-not ($cidText -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')) {
                return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid')
            }
            $ckeySlot = Get-OcSoloAttestationNode -Node $cand -Name 'public_key_base64'
            if ((-not [bool]$ckeySlot.found) -or ($null -eq $ckeySlot.value) -or -not ($ckeySlot.value -is [string])) {
                return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid')
            }
            if ([string]::IsNullOrWhiteSpace([string]$ckeySlot.value)) {
                return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid')
            }
            $crvSlot = Get-OcSoloAttestationNode -Node $cand -Name 'revoked'
            if ((-not [bool]$crvSlot.found) -or ($null -eq $crvSlot.value) -or -not ($crvSlot.value -is [bool])) {
                return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid')
            }
            try {
                if (-not $seenIssuerIds.Add($cidText)) {
                    return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid')
                }
            }
            catch { return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid') }
        }
        $skew = 60
        $life = 900
        $skSlot = Get-OcSoloAttestationNode -Node $vp -Name 'max_skew_seconds'
        if ([bool]$skSlot.found -and ($null -ne $skSlot.value)) {
            try { $skew = [int]$skSlot.value } catch { return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid') }
            if (($skew -lt 0) -or ($skew -gt 3600)) { return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid') }
        }
        $lfSlot = Get-OcSoloAttestationNode -Node $vp -Name 'max_lifetime_seconds'
        if ([bool]$lfSlot.found -and ($null -ne $lfSlot.value)) {
            try { $life = [int]$lfSlot.value } catch { return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid') }
            if (($life -lt 1) -or ($life -gt 86400)) { return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid') }
        }
        $revokedJtis = @()
        $rjSlot = Get-OcSoloAttestationNode -Node $vp -Name 'revoked_jtis'
        if ([bool]$rjSlot.found) {
            $rjRaw = $rjSlot.value
            if (($null -eq $rjRaw) -or ($rjRaw -is [string]) -or ($rjRaw -is [System.Collections.IDictionary])) {
                return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid')
            }
            if (-not ($rjRaw -is [System.Collections.IEnumerable])) {
                return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid')
            }
            $rjList = @($rjRaw)
            if ($rjList.Count -gt 1024) {
                return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid')
            }
            foreach ($rj in $rjList) {
                if (($null -eq $rj) -or -not ($rj -is [string])) {
                    return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid')
                }
                if (-not ([string]$rj -cmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')) {
                    return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-invalid')
                }
            }
            $revokedJtis = $rjList
        }

        $payload = $paySlot.value
        $pkeys = Get-OcSoloAttestationNodeKeys -Node $payload
        $want = Get-OcSoloAttestationFieldOrder
        $wantSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($k in $want) { [void]$wantSet.Add($k) }
        $orderOk = (($pkeys.Count -eq $want.Count))
        if ($orderOk) {
            foreach ($k in $pkeys) {
                if (-not $wantSet.Contains($k)) { $orderOk = $false; break }
            }
        }
        if (-not $orderOk) { return (New-OcSoloAttestationResult -Ok $false -Reason 'unknown-field') }
        for ($i = 0; $i -lt $want.Count; $i++) {
            if ($pkeys[$i] -cne $want[$i]) { return (New-OcSoloAttestationResult -Ok $false -Reason 'field-order') }
        }
        $canon = Get-OcSoloAttestationCanonicalJson -Payload $payload
        if ([string]::IsNullOrWhiteSpace($canon)) { return (New-OcSoloAttestationResult -Ok $false -Reason 'reviews-invalid') }
        $canonEnv = ('{"payload":' + $canon + ',"signature_base64":"' + $sigB64 + '"}')
        if ($raw -cne $canonEnv) { return (New-OcSoloAttestationResult -Ok $false -Reason 'noncanonical') }

        $svSlot = Get-OcSoloAttestationNode -Node $payload -Name 'schema_version'
        try {
            if (($svSlot.value -is [bool]) -or ($svSlot.value -is [string])) { return (New-OcSoloAttestationResult -Ok $false -Reason 'schema-version') }
            if ([long]$svSlot.value -ne 1) { return (New-OcSoloAttestationResult -Ok $false -Reason 'schema-version') }
        }
        catch { return (New-OcSoloAttestationResult -Ok $false -Reason 'schema-version') }

        $profSlot = Get-OcSoloAttestationNode -Node $payload -Name 'delivery_profile'
        $prof = ([string]$profSlot.value)
        $expProf = ([string]$ExpectedDeliveryProfile).Trim()
        if (($expProf -ceq 'strict') -or ($expProf -ceq 'human-required')) {
            return (New-OcSoloAttestationResult -Ok $false -Reason 'waiver-not-allowed')
        }
        if (($prof -cne 'solo-maintainer') -or ($expProf -cne 'solo-maintainer')) {
            return (New-OcSoloAttestationResult -Ok $false -Reason 'profile-binding')
        }

        $pidSlot = Get-OcSoloAttestationNode -Node $payload -Name 'policy_id'
        $pdgSlot = Get-OcSoloAttestationNode -Node $payload -Name 'policy_digest'
        if (([string]$pidSlot.value -cne ([string]$ExpectedPolicyId)) -or ([string]$pdgSlot.value -cne ([string]$ExpectedPolicyDigest).ToLowerInvariant())) {
            return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-binding')
        }
        if (-not ([string]$pdgSlot.value -cmatch '^[0-9a-f]{64}$')) {
            return (New-OcSoloAttestationResult -Ok $false -Reason 'policy-binding')
        }

        $repoSlot = Get-OcSoloAttestationNode -Node $payload -Name 'repository'
        if ([string]::IsNullOrWhiteSpace([string]$repoSlot.value) -or ([string]$repoSlot.value -cne ([string]$ExpectedRepository))) {
            return (New-OcSoloAttestationResult -Ok $false -Reason 'repository-mismatch')
        }
        $prSlot = Get-OcSoloAttestationNode -Node $payload -Name 'pr_number'
        try {
            if (($prSlot.value -is [bool]) -or ($prSlot.value -is [string])) { return (New-OcSoloAttestationResult -Ok $false -Reason 'pr-mismatch') }
            if ([long]$prSlot.value -ne [long]$ExpectedPrNumber) { return (New-OcSoloAttestationResult -Ok $false -Reason 'pr-mismatch') }
            if ([long]$ExpectedPrNumber -lt 1) { return (New-OcSoloAttestationResult -Ok $false -Reason 'pr-mismatch') }
        }
        catch { return (New-OcSoloAttestationResult -Ok $false -Reason 'pr-mismatch') }
        $headSlot = Get-OcSoloAttestationNode -Node $payload -Name 'head_sha'
        $head = ([string]$headSlot.value)
        if (-not ($head -cmatch '^[0-9a-f]{40}$')) { return (New-OcSoloAttestationResult -Ok $false -Reason 'head-sha-mismatch') }
        if ($head -cne ([string]$ExpectedHeadSha)) { return (New-OcSoloAttestationResult -Ok $false -Reason 'head-sha-mismatch') }
        $tidSlot = Get-OcSoloAttestationNode -Node $payload -Name 'task_id'
        if ([string]::IsNullOrWhiteSpace([string]$tidSlot.value) -or ([string]$tidSlot.value -cne ([string]$ExpectedTaskId))) {
            return (New-OcSoloAttestationResult -Ok $false -Reason 'task-mismatch')
        }
        $runSlot = Get-OcSoloAttestationNode -Node $payload -Name 'run_id'
        if ([string]::IsNullOrWhiteSpace([string]$runSlot.value) -or ([string]$runSlot.value -cne ([string]$ExpectedRunId))) {
            return (New-OcSoloAttestationResult -Ok $false -Reason 'run-mismatch')
        }
        $opSlot = Get-OcSoloAttestationNode -Node $payload -Name 'operation_id'
        if ([string]::IsNullOrWhiteSpace([string]$opSlot.value) -or ([string]$opSlot.value -cne ([string]$ExpectedOperationId))) {
            return (New-OcSoloAttestationResult -Ok $false -Reason 'operation-mismatch')
        }

        $issIdSlot = Get-OcSoloAttestationNode -Node $payload -Name 'issuer_id'
        $issuerId = ([string]$issIdSlot.value)
        if ([string]::IsNullOrWhiteSpace($issuerId)) { return (New-OcSoloAttestationResult -Ok $false -Reason 'unknown-issuer') }
        $issuerEntry = $null
        foreach ($cand in $issuers) {
            $idSlot = Get-OcSoloAttestationNode -Node $cand -Name 'issuer_id'
            if ([bool]$idSlot.found -and ($null -ne $idSlot.value) -and ([string]$idSlot.value -ceq $issuerId)) {
                $issuerEntry = $cand
                break
            }
        }
        if ($null -eq $issuerEntry) { return (New-OcSoloAttestationResult -Ok $false -Reason 'unknown-issuer') }
        $rvSlot = Get-OcSoloAttestationNode -Node $issuerEntry -Name 'revoked'
        if ([bool]$rvSlot.found -and ($null -ne $rvSlot.value) -and ([bool]$rvSlot.value)) {
            return (New-OcSoloAttestationResult -Ok $false -Reason 'issuer-revoked')
        }
        $keySlot = Get-OcSoloAttestationNode -Node $issuerEntry -Name 'public_key_base64'
        if ((-not [bool]$keySlot.found) -or ($null -eq $keySlot.value) -or -not ($keySlot.value -is [string])) {
            return (New-OcSoloAttestationResult -Ok $false -Reason 'unknown-issuer')
        }
        $keyB64 = ([string]$keySlot.value).Trim()
        if ([string]::IsNullOrWhiteSpace($keyB64)) { return (New-OcSoloAttestationResult -Ok $false -Reason 'unknown-issuer') }

        $jtiSlot = Get-OcSoloAttestationNode -Node $payload -Name 'jti'
        $jti = ([string]$jtiSlot.value)
        if (-not ($jti -cmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')) {
            return (New-OcSoloAttestationResult -Ok $false -Reason 'jti-invalid')
        }
        $jtiCanon = ([string]$jti).ToLowerInvariant()
        foreach ($rj in $revokedJtis) {
            if (($null -ne $rj) -and ($rj -is [string]) -and (([string]$rj).ToLowerInvariant() -ceq $jtiCanon)) {
                return (New-OcSoloAttestationResult -Ok $false -Reason 'jti-revoked')
            }
        }

        $iaSlot = Get-OcSoloAttestationNode -Node $payload -Name 'issued_at'
        $eaSlot = Get-OcSoloAttestationNode -Node $payload -Name 'expires_at'
        $ia = Get-OcSoloAttestationInstantValue -Value $iaSlot.value
        $ea = Get-OcSoloAttestationInstantValue -Value $eaSlot.value
        if ((-not [bool]$ia.ok) -or (-not [bool]$ea.ok)) { return (New-OcSoloAttestationResult -Ok $false -Reason 'time-invalid') }
        $issued = [DateTime]$ia.instant
        $expires = [DateTime]$ea.instant
        if ($expires -le $issued) { return (New-OcSoloAttestationResult -Ok $false -Reason 'time-invalid') }
        if ((($expires - $issued).TotalSeconds) -gt [double]$life) {
            return (New-OcSoloAttestationResult -Ok $false -Reason 'lifetime-exceeded')
        }
        $now = [DateTime]::UtcNow
        if (-not [string]::IsNullOrWhiteSpace([string]$NowUtc)) {
            $nw = Test-OcSoloAttestationInstant -Text ([string]$NowUtc)
            if (-not [bool]$nw.ok) { return (New-OcSoloAttestationResult -Ok $false -Reason 'time-invalid') }
            $now = [DateTime]$nw.instant
        }
        if ($now -lt $issued.AddSeconds(-1 * [double]$skew)) { return (New-OcSoloAttestationResult -Ok $false -Reason 'not-yet-valid') }
        if ($now -ge $expires) { return (New-OcSoloAttestationResult -Ok $false -Reason 'expired') }

        $revSlot = Get-OcSoloAttestationNode -Node $payload -Name 'reviews'
        $revItems = @($revSlot.value)
        if ($revItems.Count -ne 2) { return (New-OcSoloAttestationResult -Ok $false -Reason 'reviews-invalid') }
        $wantRoles = @('reviewer', 'security-reviewer')
        for ($ri = 0; $ri -lt 2; $ri++) {
            $rk = Get-OcSoloAttestationNodeKeys -Node $revItems[$ri]
            $rf = Get-OcSoloAttestationReviewFieldOrder
            if ($rk.Count -ne $rf.Count) { return (New-OcSoloAttestationResult -Ok $false -Reason 'reviews-invalid') }
            for ($j = 0; $j -lt $rf.Count; $j++) {
                if ($rk[$j] -cne $rf[$j]) { return (New-OcSoloAttestationResult -Ok $false -Reason 'reviews-invalid') }
            }
            $role = ([string](Get-OcSoloAttestationNode -Node $revItems[$ri] -Name 'role').value)
            if ($role -cne $wantRoles[$ri]) { return (New-OcSoloAttestationResult -Ok $false -Reason 'reviews-invalid') }
            $verdict = ([string](Get-OcSoloAttestationNode -Node $revItems[$ri] -Name 'verdict').value)
            if ($verdict -cne 'approved') { return (New-OcSoloAttestationResult -Ok $false -Reason 'verdict-not-approved') }
            $sess = ([string](Get-OcSoloAttestationNode -Node $revItems[$ri] -Name 'session_id').value)
            if (-not ($sess -cmatch '^ses_[A-Za-z0-9]{1,64}$')) { return (New-OcSoloAttestationResult -Ok $false -Reason 'session-invalid') }
            $cand = ([string](Get-OcSoloAttestationNode -Node $revItems[$ri] -Name 'candidate_sha').value)
            if (-not ($cand -cmatch '^[0-9a-f]{40}$')) { return (New-OcSoloAttestationResult -Ok $false -Reason 'sha-invalid') }
            if ($cand -cne $head) { return (New-OcSoloAttestationResult -Ok $false -Reason 'candidate-mismatch') }
            $evNode = (Get-OcSoloAttestationNode -Node $revItems[$ri] -Name 'evidence_sha256').value
            $krh = ([string](Get-OcSoloAttestationNode -Node $revItems[$ri] -Name 'kernel_record_sha256').value)
            if (-not ($krh -cmatch '^[0-9a-f]{64}$')) {
                return (New-OcSoloAttestationResult -Ok $false -Reason 'evidence-invalid')
            }
            if (($null -eq $evNode) -or ($evNode -is [string]) -or ($evNode -is [System.Collections.IDictionary])) {
                return (New-OcSoloAttestationResult -Ok $false -Reason 'evidence-invalid')
            }
            if (-not ($evNode -is [System.Collections.IEnumerable])) {
                return (New-OcSoloAttestationResult -Ok $false -Reason 'evidence-invalid')
            }
            $evList = @($evNode)
            if (($evList.Count -lt 1) -or ($evList.Count -gt 32)) {
                return (New-OcSoloAttestationResult -Ok $false -Reason 'evidence-invalid')
            }
            foreach ($ev in $evList) {
                if (($null -eq $ev) -or -not ($ev -is [string])) {
                    return (New-OcSoloAttestationResult -Ok $false -Reason 'evidence-invalid')
                }
                if (-not ([string]$ev -cmatch '^[0-9a-f]{64}$')) {
                    return (New-OcSoloAttestationResult -Ok $false -Reason 'evidence-invalid')
                }
            }
        }

        $sigBytes = $null
        try { $sigBytes = [Convert]::FromBase64String($sigB64) }
        catch { return (New-OcSoloAttestationResult -Ok $false -Reason 'signature-malformed') }
        if (($null -eq $sigBytes) -or ($sigBytes.Length -eq 0)) {
            return (New-OcSoloAttestationResult -Ok $false -Reason 'signature-malformed')
        }
        $keyBytes = $null
        try { $keyBytes = [Convert]::FromBase64String($keyB64) }
        catch { return (New-OcSoloAttestationResult -Ok $false -Reason 'unknown-issuer') }
        $rp = Get-OcSoloAttestationRsaParams -Der $keyBytes
        if (-not [bool]$rp.ok) { return (New-OcSoloAttestationResult -Ok $false -Reason 'unknown-issuer') }
        $dataBytes = [Text.Encoding]::UTF8.GetBytes($canon)
        $rsa = $null
        try {
            $rsa = New-Object System.Security.Cryptography.RSACng
            $rsa.ImportParameters($rp.params)
            $valid = $rsa.VerifyData($dataBytes, $sigBytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pss)
            if (-not [bool]$valid) { return (New-OcSoloAttestationResult -Ok $false -Reason 'signature-invalid') }
        }
        catch { return (New-OcSoloAttestationResult -Ok $false -Reason 'signature-invalid') }
        finally {
            try { if ($null -ne $rsa) { $rsa.Dispose() } } catch { }
        }
        return (New-OcSoloAttestationResult -Ok $true -Reason 'attestation-valid')
    }
    catch { return (New-OcSoloAttestationResult -Ok $false -Reason 'internal-error') }
}
