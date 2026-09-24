<#!
.SYNOPSIS
    Testes standalone do CapabilitySanitize.ps1 (Phase 1, ADR-041).
.DESCRIPTION
    Usa apenas valores sinteticos (nenhum segredo real). Roda com
    `pwsh -NoProfile -File <este-arquivo>`; termina com exit 0/1.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$libPath = Join-Path $PSScriptRoot 'CapabilitySanitize.ps1'
. $libPath

$passed = 0
$failed = 0

function Assert-SanitizeTrue {
    param([bool]$Condition, [string]$Name)
    if ($Condition) {
        Write-Host ("PASS {0}" -f $Name)
        $script:passed++
    }
    else {
        Write-Host ("FAIL {0}" -f $Name)
        $script:failed++
    }
}

try {
    $pattern = Get-SensitiveKeyPattern
    Assert-SanitizeTrue (('myToken' -match $pattern) -and ('AUTHORIZATION' -match $pattern) -and ('api_key' -match $pattern)) 'pattern matches sensitive names'
    Assert-SanitizeTrue (('x-api-key' -match $pattern) -and ('access_key' -match $pattern) -and ('JWT' -match $pattern) -and ('SESSION_ID' -match $pattern) -and ('auth' -match $pattern) -and ('passphrase' -match $pattern) -and ('refresh_token' -match $pattern) -and ('connectionstring' -match $pattern) -and ('private' -match $pattern) -and ('secret_key' -match $pattern)) 'pattern covers extended sensitive names'
    Assert-SanitizeTrue (-not ('description' -match $pattern)) 'pattern ignores safe names'

    $nested = [PSCustomObject]@{
        name   = 'synthetic-skill'
        nested = [PSCustomObject]@{
            token         = 'SYNTHETIC-TOKEN-VALUE-1'
            Authorization = 'SYNTHETIC-AUTH-VALUE-2'
            safe          = 'keep-me'
        }
        items  = @(
            [PSCustomObject]@{ api_key = 'SYNTHETIC-KEY-VALUE-3'; location = 'somewhere' }
        )
    }
    $cleaned = Remove-SensitiveKeys -InputObject $nested
    $cleanedJson = ConvertTo-Json -InputObject $cleaned -Depth 10 -Compress
    Assert-SanitizeTrue (($cleanedJson -notmatch 'SYNTHETIC-TOKEN-VALUE-1') -and ($cleanedJson -notmatch 'SYNTHETIC-AUTH-VALUE-2') -and ($cleanedJson -notmatch 'SYNTHETIC-KEY-VALUE-3')) 'nested sensitive values are removed'
    Assert-SanitizeTrue (($cleanedJson -match 'keep-me') -and ($cleanedJson -match 'somewhere')) 'safe values survive'
    Assert-SanitizeTrue (Test-NoSensitiveKeys -InputObject $cleaned) 'cleaned object has no sensitive keys'

    $record = [PSCustomObject]@{ name = 'n'; description = 'd'; location = 'l'; extra = 'drop-me' }
    $projected = Select-Fields -InputObject $record -Fields @('name', 'location', 'absent-field')
    Assert-SanitizeTrue (($projected.name -ceq 'n') -and ($projected.location -ceq 'l')) 'select projects requested fields'
    Assert-SanitizeTrue ($null -eq $projected.PSObject.Properties['extra'] -and $null -eq $projected.PSObject.Properties['absent-field']) 'select drops unlisted and absent fields'

    $emptyOut = Select-Fields -InputObject @() -Fields @('name')
    Assert-SanitizeTrue (($emptyOut -is [array]) -and (@($emptyOut).Count -eq 0)) 'select preserves empty array'

    $oneIn = @([PSCustomObject]@{ name = 'n'; extra = 'drop-me' })
    $oneOut = Select-Fields -InputObject $oneIn -Fields @('name')
    Assert-SanitizeTrue (($oneOut -is [array]) -and (@($oneOut).Count -eq 1) -and ($oneOut[0].name -ceq 'n')) 'select preserves single-item array'

    $arrClean = Remove-SensitiveKeys -InputObject @([PSCustomObject]@{ name = 'a'; token = 'SYNTHETIC-ARR-TOKEN-0' })
    Assert-SanitizeTrue (($arrClean -is [array]) -and (@($arrClean).Count -eq 1) -and ($arrClean[0].name -ceq 'a')) 'remove preserves single-item array'

    $extendedKeys = [PSCustomObject]@{
        'x-api-key'   = 'SYNTHETIC-XAPI-1'
        'access_key'  = 'SYNTHETIC-ACCESS-2'
        'jwt'         = 'SYNTHETIC-JWT-3'
        'session'     = 'SYNTHETIC-SESSION-4'
        'auth'        = 'SYNTHETIC-AUTH-5'
        'passphrase'  = 'SYNTHETIC-PP-6'
        'description' = 'keep-this-text'
    }
    $extendedClean = Remove-SensitiveKeys -InputObject $extendedKeys
    $extendedJson = ConvertTo-Json -InputObject $extendedClean -Depth 10 -Compress
    Assert-SanitizeTrue (($extendedJson -notmatch 'SYNTHETIC-XAPI-1') -and ($extendedJson -notmatch 'SYNTHETIC-ACCESS-2') -and ($extendedJson -notmatch 'SYNTHETIC-JWT-3') -and ($extendedJson -notmatch 'SYNTHETIC-SESSION-4') -and ($extendedJson -notmatch 'SYNTHETIC-AUTH-5') -and ($extendedJson -notmatch 'SYNTHETIC-PP-6')) 'extended sensitive keys are removed'
    Assert-SanitizeTrue ($extendedJson -match 'keep-this-text') 'safe field survives extended removal'

    $skillEvidence = [PSCustomObject]@{
        name        = 'synthetic-skill'
        description = 'synthetic description'
        location    = 'synthetic-location'
        content     = 'SYNTHETIC-SKILL-BODY-MUST-NOT-PERSIST'
        token       = 'SYNTHETIC-SKILL-TOKEN-4'
    }
    $sanitizedSkill = Invoke-SanitizeEvidence -Kind 'debugskill' -InputObject $skillEvidence
    $skillJson = ConvertTo-Json -InputObject $sanitizedSkill -Depth 10 -Compress
    Assert-SanitizeTrue (($skillJson -notmatch 'content') -and ($skillJson -notmatch 'SYNTHETIC-SKILL-BODY-MUST-NOT-PERSIST')) 'debugskill evidence drops content'
    Assert-SanitizeTrue (($skillJson -match 'synthetic-skill') -and ($skillJson -notmatch 'SYNTHETIC-SKILL-TOKEN-4')) 'debugskill keeps identity and drops token'

    Assert-SanitizeTrue (-not (Test-NoSensitiveKeys -InputObject ([PSCustomObject]@{ cookie = 'SYNTHETIC-COOKIE-5' }))) 'detector is false on sensitive key'
    Assert-SanitizeTrue (Test-NoSensitiveKeys -InputObject ([PSCustomObject]@{ name = 'plain' })) 'detector is true on clean object'

    $configEvidence = [PSCustomObject]@{
        model          = 'synthetic-model'
        default_agent  = 'build'
        subagent_depth = 1
        username       = 'synthetic-user'
        raw_line       = 'SYNTHETIC-RAW-LINE-6'
    }
    $sanitizedConfig = Invoke-SanitizeEvidence -Kind 'debugconfig' -InputObject $configEvidence
    $configJson = ConvertTo-Json -InputObject $sanitizedConfig -Depth 10 -Compress
    Assert-SanitizeTrue (($configJson -notmatch 'SYNTHETIC-RAW-LINE-6') -and ($configJson -match 'synthetic-model')) 'debugconfig keeps allowlist and drops raw lines'

    $projection = Get-SanitizeProjection -Kind 'registry'
    Assert-SanitizeTrue (($projection -contains 'id') -and ($projection -contains 'capability_profile') -and ($projection -contains 'provenance')) 'registry projection covers schema fields'

    $bearerRec = [PSCustomObject]@{
        name        = 'synthetic-skill'
        description = 'connects with Bearer SYNTHETIC-BEARER-TOKEN-ABC123 today'
        location    = 'synthetic-location'
    }
    $sanitizedBearer = Invoke-SanitizeEvidence -Kind 'skill' -InputObject $bearerRec
    $bearerJson = ConvertTo-Json -InputObject $sanitizedBearer -Depth 10 -Compress
    Assert-SanitizeTrue (($bearerJson -match '\[REDACTED\]') -and ($bearerJson -notmatch 'SYNTHETIC-BEARER-TOKEN-ABC123')) 'bearer value redacted in description'
    Assert-SanitizeTrue (Test-NoSecretValues -InputObject $sanitizedBearer) 'redacted evidence passes value detector'

    $unredacted = Invoke-SanitizeEvidence -Kind 'skill' -InputObject $bearerRec -RedactValues $false
    $unredactedJson = ConvertTo-Json -InputObject $unredacted -Depth 10 -Compress
    Assert-SanitizeTrue ($unredactedJson -match 'SYNTHETIC-BEARER-TOKEN-ABC123') 'redact opt-out keeps value'
    Assert-SanitizeTrue (-not (Test-NoSecretValues -InputObject $unredacted)) 'value detector is false on bearer text'

    $metaRec = [PSCustomObject]@{
        id                = 'agent:synthetic'
        type              = 'agent'
        name              = 'synthetic'
        description       = 'plain synthetic description'
        source            = 'synthetic-source'
        source_kind       = 'synthetic-kind'
        runtime           = 'synthetic-runtime'
        status            = 'available'
        categories        = @('synthetic-cat')
        tags              = @('synthetic-tag')
        capabilities      = @('synthetic.cap')
        risk              = 'low'
        trust             = 'approved'
        read_only         = $false
        fingerprint       = 'synthetic-fingerprint'
        metadata          = [PSCustomObject]@{ token = 'SYNTHETIC-META-TOKEN-9'; note = 'plain note' }
        eligibility       = 'synthetic-eligibility'
        capability_profile = 'synthetic-profile'
        provenance        = 'synthetic-provenance'
        evidence          = 'synthetic-evidence'
    }
    $sanitizedMeta = Invoke-SanitizeEvidence -Kind 'registry' -InputObject $metaRec
    $metaJson = ConvertTo-Json -InputObject $sanitizedMeta -Depth 10 -Compress
    Assert-SanitizeTrue ($metaJson -notmatch 'SYNTHETIC-META-TOKEN-9') 'synthetic token in metadata does not survive'
    Assert-SanitizeTrue (Test-NoSensitiveKeys -InputObject $sanitizedMeta) 'sanitized registry has no sensitive keys'
    Assert-SanitizeTrue (Test-NoSecretValues -InputObject $sanitizedMeta) 'sanitized registry has no secret values'

    Assert-SanitizeTrue (-not (Test-NoSecretValues -InputObject ([PSCustomObject]@{ description = 'uses sk-SYNTHETICSECRET01 here' }))) 'value detector is false on sk- value'
    Assert-SanitizeTrue (-not (Test-NoSecretValues -InputObject ([PSCustomObject]@{ description = 'id AKIAIOSFODNN7EXAMPLE here' }))) 'value detector is false on AKIA value'
    Assert-SanitizeTrue (-not (Test-NoSecretValues -InputObject ([PSCustomObject]@{ description = 'jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.c2lnbmF0dXJl here' }))) 'value detector is false on JWT value'
    Assert-SanitizeTrue (-not (Test-NoSecretValues -InputObject ([PSCustomObject]@{ description = 'config token=abcdef0123456789abcdef0123456789 done' }))) 'value detector is false on long hex value'
    Assert-SanitizeTrue (Test-NoSecretValues -InputObject ([PSCustomObject]@{ description = 'plain synthetic description' })) 'value detector is true on clean text'
}
catch {
    Write-Host ("FAIL unexpected error: {0}" -f $_)
    exit 1
}

Write-Host ("CapabilitySanitize: {0} / {1} tests passed" -f $passed, ($passed + $failed))
if ($failed -gt 0) { exit 1 }
exit 0
