<#!
.SYNOPSIS
    V3 Capability schema: enums, IDs canonicos, validacao de registros e hash logico.
.DESCRIPTION
    Biblioteca dot-sourceable (sem acesso a disco/rede). Implementa o schema
    v1 da ORCHESTRATION V3 (plano §5): enums com estado `unknown`, IDs no
    formato `<type>:<name>` normalizados e serializacao JSON deterministica
    para hashing (AC-10 / idempotencia do registry).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-CapabilityEnums {
    <#
    .SYNOPSIS
        Retorna os enums do schema de capability v1.
    #>
    [CmdletBinding()]
    param()
    return [PSCustomObject]@{
        Type   = @('agent', 'skill', 'mcp')
        Status = @('discovered', 'validating', 'available', 'degraded', 'disabled', 'missing', 'invalid', 'unknown')
        Risk   = @('low', 'medium', 'high', 'critical', 'unknown')
        Trust  = @('trusted', 'approved', 'external', 'untrusted', 'unknown')
    }
}

function Get-CapabilityId {
    <#
    .SYNOPSIS
        Constroi o ID canonico "<type>:<name>" normalizado (trim + lowercase).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Type,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    $enums = Get-CapabilityEnums
    $normalizedType = "$Type".Trim().ToLowerInvariant()
    $normalizedName = "$Name".Trim().ToLowerInvariant()
    if ($enums.Type -cnotcontains $normalizedType) {
        throw ("Invalid capability type: '{0}'. Valid types: {1}." -f $Type, ($enums.Type -join ', '))
    }
    if ([string]::IsNullOrWhiteSpace($normalizedName)) {
        throw 'Capability name must not be empty.'
    }
    return ('{0}:{1}' -f $normalizedType, $normalizedName)
}

function Get-CapabilityRecordField {
    <#
    .SYNOPSIS
        Le um campo de um registro (hashtable ou PSCustomObject), distinguindo
        ausente de presente-com-null (relevante para read_only).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Record,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    if ($Record -is [System.Collections.IDictionary]) {
        if ($Record.Contains($Name)) {
            return @{ Found = $true; Value = $Record[$Name] }
        }
        return @{ Found = $false; Value = $null }
    }
    $property = $Record.PSObject.Properties | Where-Object { $_.Name -ceq $Name } | Select-Object -First 1
    if ($null -eq $property) {
        return @{ Found = $false; Value = $null }
    }
    return @{ Found = $true; Value = $property.Value }
}

function Test-CapabilityRecord {
    <#
    .SYNOPSIS
        Valida um registro de capability contra o schema v1 (§5).
    .OUTPUTS
        PSCustomObject @{ Valid = [bool]; Errors = [string[]] }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Record
    )
    $errors = New-Object System.Collections.Generic.List[string]
    $enums = Get-CapabilityEnums
    $required = @('id', 'type', 'name', 'status', 'categories', 'tags', 'capabilities', 'risk', 'trust', 'read_only', 'metadata')

    foreach ($field in $required) {
        $slot = Get-CapabilityRecordField -Record $Record -Name $field
        if (-not $slot.Found) {
            $errors.Add(("Missing required field: '{0}'." -f $field))
        }
    }

    $idSlot = Get-CapabilityRecordField -Record $Record -Name 'id'
    if ($idSlot.Found) {
        $idText = "$($idSlot.Value)".Trim()
        if ([string]::IsNullOrWhiteSpace($idText)) {
            $errors.Add("Field 'id' must not be empty.")
        }
        else {
            $parts = $idText -split ':'
            if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[1])) {
                $errors.Add(("Field 'id' must use the format <type>:<name>; got '{0}'." -f $idSlot.Value))
            }
            elseif ($enums.Type -cnotcontains $parts[0].Trim().ToLowerInvariant()) {
                $errors.Add(("Field 'id' has unknown type prefix '{0}'." -f $parts[0]))
            }
        }
    }

    foreach ($enumField in @('type', 'status', 'risk', 'trust')) {
        $slot = Get-CapabilityRecordField -Record $Record -Name $enumField
        if ($slot.Found -and $null -ne $slot.Value) {
            $enumName = $enumField.Substring(0, 1).ToUpperInvariant() + $enumField.Substring(1)
            $allowed = $enums.$enumName
            if ($allowed -cnotcontains "$($slot.Value)".Trim().ToLowerInvariant()) {
                $errors.Add(("Field '{0}' has invalid value '{1}'. Allowed: {2}." -f $enumField, $slot.Value, ($allowed -join ', ')))
            }
        }
        elseif ($slot.Found -and $null -eq $slot.Value) {
            $errors.Add(("Field '{0}' must not be null." -f $enumField))
        }
    }

    $nameSlot = Get-CapabilityRecordField -Record $Record -Name 'name'
    if ($nameSlot.Found -and [string]::IsNullOrWhiteSpace("$($nameSlot.Value)")) {
        $errors.Add("Field 'name' must not be empty.")
    }

    $typeSlot = Get-CapabilityRecordField -Record $Record -Name 'type'
    if ($idSlot.Found -and $typeSlot.Found -and $nameSlot.Found) {
        $idRaw = "$($idSlot.Value)"
        $typeRaw = "$($typeSlot.Value)"
        $nameRaw = "$($nameSlot.Value)"
        $typeOk = (-not [string]::IsNullOrWhiteSpace($typeRaw)) -and ($enums.Type -ccontains $typeRaw.Trim().ToLowerInvariant())
        if ((-not [string]::IsNullOrWhiteSpace($idRaw)) -and $typeOk -and (-not [string]::IsNullOrWhiteSpace($nameRaw))) {
            $expectedId = $null
            try {
                $expectedId = Get-CapabilityId -Type $typeRaw -Name $nameRaw
            }
            catch {
                $expectedId = $null
            }
            if (($null -ne $expectedId) -and ($idRaw -cne $expectedId)) {
                $errors.Add(("Field 'id' must equal the canonical id '{0}' for type '{1}' and name '{2}'; got '{3}'." -f $expectedId, $typeSlot.Value, $nameSlot.Value, $idSlot.Value))
            }
        }
    }

    $readOnlySlot = Get-CapabilityRecordField -Record $Record -Name 'read_only'
    if ($readOnlySlot.Found -and $null -ne $readOnlySlot.Value -and -not ($readOnlySlot.Value -is [bool])) {
        $errors.Add("Field 'read_only' must be a boolean or null.")
    }

    foreach ($arrayField in @('categories', 'tags', 'capabilities')) {
        $slot = Get-CapabilityRecordField -Record $Record -Name $arrayField
        if ($slot.Found) {
            if ($null -eq $slot.Value) {
                $errors.Add(("Field '{0}' must not be null." -f $arrayField))
            }
            elseif (($slot.Value -is [string]) -or ($slot.Value -is [System.Collections.IDictionary]) -or -not ($slot.Value -is [array])) {
                $errors.Add(("Field '{0}' must be an array of non-empty strings." -f $arrayField))
            }
            else {
                $hasBadItem = $false
                $hasDuplicate = $false
                $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
                foreach ($item in $slot.Value) {
                    if (-not ($item -is [string]) -or [string]::IsNullOrWhiteSpace($item)) {
                        $hasBadItem = $true
                    }
                    elseif (-not $seen.Add($item)) {
                        $hasDuplicate = $true
                    }
                }
                if ($hasBadItem) {
                    $errors.Add(("Field '{0}' must contain only non-empty strings." -f $arrayField))
                }
                if ($hasDuplicate) {
                    $errors.Add(("Field '{0}' must not contain duplicate items (case-sensitive)." -f $arrayField))
                }
            }
        }
    }

    $metadataSlot = Get-CapabilityRecordField -Record $Record -Name 'metadata'
    if ($metadataSlot.Found) {
        $metadataValue = $metadataSlot.Value
        if ($null -eq $metadataValue) {
            $errors.Add("Field 'metadata' must not be null.")
        }
        else {
            $isBadScalar = ($metadataValue -is [string]) -or ($metadataValue -is [System.ValueType])
            $isBadList = ($metadataValue -is [System.Collections.IEnumerable]) -and -not ($metadataValue -is [System.Collections.IDictionary])
            if ($isBadScalar -or $isBadList) {
                $errors.Add("Field 'metadata' must be an object.")
            }
        }
    }

    return [PSCustomObject]@{
        Valid  = ($errors.Count -eq 0)
        Errors = [string[]]$errors
    }
}

function Escape-JsonString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Text = ''
    )
    if ([string]::IsNullOrEmpty($Text)) {
        return [string]''
    }
    $builder = New-Object System.Text.StringBuilder
    foreach ($char in $Text.ToCharArray()) {
        $code = [int][char]$char
        if ($code -eq 34) {
            $builder.Append('\"') | Out-Null
        }
        elseif ($code -eq 92) {
            $builder.Append('\\') | Out-Null
        }
        elseif ($code -eq 8) {
            $builder.Append('\b') | Out-Null
        }
        elseif ($code -eq 9) {
            $builder.Append('\t') | Out-Null
        }
        elseif ($code -eq 10) {
            $builder.Append('\n') | Out-Null
        }
        elseif ($code -eq 12) {
            $builder.Append('\f') | Out-Null
        }
        elseif ($code -eq 13) {
            $builder.Append('\r') | Out-Null
        }
        elseif ($code -lt 32) {
            $builder.Append(('\u{0:x4}' -f $code)) | Out-Null
        }
        else {
            $builder.Append($char) | Out-Null
        }
    }
    return $builder.ToString()
}

function ConvertTo-DeterministicJsonNode {
    [CmdletBinding()]
    param($Node)
    if ($null -eq $Node) {
        return 'null'
    }
    if ($Node -is [bool]) {
        if ($Node) { return 'true' }
        return 'false'
    }
    if ($Node -is [string]) {
        return ('"' + (Escape-JsonString -Text $Node) + '"')
    }
    if ($Node -is [System.ValueType]) {
        if ($Node -is [System.DateTime]) {
            return ('"' + ([System.DateTime]$Node).ToString('o') + '"')
        }
        if ($Node -is [System.DateTimeOffset]) {
            return ('"' + ([System.DateTimeOffset]$Node).ToString('o') + '"')
        }
        return ([System.Convert]::ToString($Node, [System.Globalization.CultureInfo]::InvariantCulture))
    }
    if ($Node -is [System.Collections.IDictionary]) {
        $keys = @()
        foreach ($key in $Node.Keys) {
            $keys += "$key"
        }
        [Array]::Sort($keys, [System.StringComparer]::Ordinal)
        $pairs = @()
        foreach ($key in $keys) {
            $pairs += ('"' + (Escape-JsonString -Text $key) + '":' + (ConvertTo-DeterministicJsonNode -Node $Node[$key]))
        }
        return ('{' + ($pairs -join ',') + '}')
    }
    if ($Node -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($element in $Node) {
            $items += (ConvertTo-DeterministicJsonNode -Node $element)
        }
        return ('[' + ($items -join ',') + ']')
    }
    $allNames = @($Node.PSObject.Properties | ForEach-Object { $_.Name })
    [Array]::Sort($allNames, [System.StringComparer]::Ordinal)
    $pairs = @()
    foreach ($name in $allNames) {
        $value = $Node.PSObject.Properties[$name].Value
        $pairs += ('"' + (Escape-JsonString -Text $name) + '":' + (ConvertTo-DeterministicJsonNode -Node $value))
    }
    return ('{' + ($pairs -join ',') + '}')
}

function ConvertTo-DeterministicJson {
    <#
    .SYNOPSIS
        Serializa para JSON compacto com chaves ordenadas (ordinal) em todos
        os niveis; arrays preservam a ordem. Base do hash logico.
    #>
    [CmdletBinding()]
    param($InputObject)
    return (ConvertTo-DeterministicJsonNode -Node $InputObject)
}

function Get-LogicalHash {
    <#
    .SYNOPSIS
        Retorna "sha256:<hex>" do JSON deterministico do objeto.
    #>
    [CmdletBinding()]
    param($InputObject)
    $json = ConvertTo-DeterministicJson -InputObject $InputObject
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }
    $hex = ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
    return ("sha256:{0}" -f $hex)
}
