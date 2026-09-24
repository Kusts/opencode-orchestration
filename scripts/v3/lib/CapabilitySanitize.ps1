<#!
.SYNOPSIS
    V3 Capability sanitize: reducao fail-closed de evidencia (ADR-041).
.DESCRIPTION
    Biblioteca dot-sourceable (sem escrita em disco). Aplica allowlist de
    campos por tipo de artefato e remove chaves sensiveis recursivamente.
    Nunca persiste `debug skill.content`, headers, payloads ou valores de env:
    a projecao seleciona apenas os campos listados.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-SensitiveKeyPattern {
    <#
    .SYNOPSIS
        Retorna a regex (case-insensitive) de nomes de chave sensiveis.
    #>
    [CmdletBinding()]
    param()
    return '(?i)(token|secret|password|passwd|passphrase|apikey|api_key|api-key|x-api-key|authorization|auth|cookie|bearer|jwt|session|private|private_key|secret_key|access_key|refresh_token|connectionstring|connection_string|client_secret|credential)'
}

function Remove-SensitiveKeysNode {
    [CmdletBinding()]
    param($Node, [string]$Pattern)
    if ($null -eq $Node) {
        return $null
    }
    if ($Node -is [System.Collections.IDictionary]) {
        $clean = @{}
        foreach ($key in $Node.Keys) {
            if ("$key" -match $Pattern) {
                continue
            }
            $clean[$key] = Remove-SensitiveKeysNode -Node $Node[$key] -Pattern $Pattern
        }
        return $clean
    }
    if (($Node -is [System.Collections.IEnumerable]) -and -not ($Node -is [string])) {
        $items = @()
        foreach ($element in $Node) {
            $cleaned = Remove-SensitiveKeysNode -Node $element -Pattern $Pattern
            if ($null -eq $cleaned) {
                $items += $null
            }
            else {
                $items += $cleaned
            }
        }
        Write-Output -NoEnumerate $items
        return
    }
    if (($Node -is [string]) -or ($Node -is [System.ValueType])) {
        return $Node
    }
    $properties = @($Node.PSObject.Properties)
    if ($properties.Count -eq 0) {
        return $Node
    }
    $clean = New-Object PSCustomObject
    foreach ($property in $properties) {
        if ($property.Name -match $Pattern) {
            continue
        }
        $clean | Add-Member -NotePropertyName $property.Name -NotePropertyValue (Remove-SensitiveKeysNode -Node $property.Value -Pattern $Pattern)
    }
    return $clean
}

function Remove-SensitiveKeys {
    <#
    .SYNOPSIS
        Remove recursivamente propriedades cujo nome casa o padrao sensivel.
    #>
    [CmdletBinding()]
    param($InputObject)
    $pattern = Get-SensitiveKeyPattern
    $result = Remove-SensitiveKeysNode -Node $InputObject -Pattern $pattern
    if ($null -eq $result) {
        return $null
    }
    if ($result -is [array]) {
        Write-Output -NoEnumerate $result
        return
    }
    return $result
}

function Select-FieldsNode {
    [CmdletBinding()]
    param($Node, [string[]]$Fields)
    if ($null -eq $Node) {
        return $null
    }
    if ($Node -is [System.Collections.IDictionary]) {
        $projected = @{}
        foreach ($field in $Fields) {
            if ($Node.Contains($field)) {
                $projected[$field] = Select-FieldsNode -Node $Node[$field] -Fields $Fields
            }
        }
        return $projected
    }
    if (($Node -is [System.Collections.IEnumerable]) -and -not ($Node -is [string])) {
        $items = @()
        foreach ($element in $Node) {
            $selected = Select-FieldsNode -Node $element -Fields $Fields
            if ($null -eq $selected) {
                $items += $null
            }
            else {
                $items += $selected
            }
        }
        Write-Output -NoEnumerate $items
        return
    }
    if (($Node -is [string]) -or ($Node -is [System.ValueType])) {
        return $Node
    }
    $properties = @($Node.PSObject.Properties)
    if ($properties.Count -eq 0) {
        return $Node
    }
    $projected = New-Object PSCustomObject
    foreach ($field in $Fields) {
        $property = $properties | Where-Object { $_.Name -ceq $field } | Select-Object -First 1
        if ($null -ne $property) {
            $projected | Add-Member -NotePropertyName $field -NotePropertyValue (Select-FieldsNode -Node $property.Value -Fields $Fields)
        }
    }
    return $projected
}

function Select-Fields {
    <#
    .SYNOPSIS
        Projeta somente as chaves listadas (arrays recursam; ausentes omitidas).
        Arrays de 0 ou 1 elemento permanecem arrays na saida.
    #>
    [CmdletBinding()]
    param(
        $InputObject,
        [Parameter(Mandatory = $true)]
        [string[]]$Fields
    )
    $result = Select-FieldsNode -Node $InputObject -Fields $Fields
    if ($null -eq $result) {
        return $null
    }
    if ($result -is [array]) {
        Write-Output -NoEnumerate $result
        return
    }
    return $result
}

function Get-SanitizeProjection {
    <#
    .SYNOPSIS
        Retorna a allowlist de campos por tipo de artefato (fail-closed).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Kind
    )
    $normalized = "$Kind".Trim().ToLowerInvariant()
    if ($normalized -eq 'debugconfig') {
        return @('model', 'default_agent', 'subagent_depth', 'username')
    }
    if ($normalized -eq 'agent') {
        return @('name', 'description', 'mode', 'model', 'temperature', 'tools', 'permission', 'orchestration')
    }
    if ($normalized -eq 'skill' -or $normalized -eq 'debugskill') {
        return @('name', 'description', 'location')
    }
    if ($normalized -eq 'mcp') {
        return @('id', 'type', 'enabled', 'env_keys')
    }
    if ($normalized -eq 'registry') {
        return @('id', 'type', 'name', 'description', 'source', 'source_kind', 'runtime', 'status', 'categories', 'tags', 'capabilities', 'risk', 'trust', 'read_only', 'fingerprint', 'metadata', 'eligibility', 'capability_profile', 'provenance', 'evidence')
    }
    throw ("Unknown sanitize kind: '{0}'." -f $Kind)
}

function Invoke-SanitizeEvidence {
    <#
    .SYNOPSIS
        Aplica projecao por tipo + remocao de chaves sensiveis + (por padrao)
        redacao de valores textuais que casem padroes de segredo.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Kind,
        $InputObject,
        [bool]$RedactValues = $true
    )
    $fields = Get-SanitizeProjection -Kind $Kind
    $projected = Select-Fields -InputObject $InputObject -Fields $fields
    $cleaned = Remove-SensitiveKeys -InputObject $projected
    if ($RedactValues) {
        $valuePattern = Get-SecretValuePattern
        $cleaned = Remove-SecretValuesNode -Node $cleaned -Pattern $valuePattern
    }
    if ($null -eq $cleaned) {
        return $null
    }
    if ($cleaned -is [array]) {
        Write-Output -NoEnumerate $cleaned
        return
    }
    return $cleaned
}

function Get-SecretValuePattern {
    <#
    .SYNOPSIS
        Retorna a regex de VALORES textuais que parecem segredo (sinteticos
        ou reais): Bearer <token>, sk-..., ghp_..., AKIA..., JWT (x.y.z em
        base64url) e strings hex/base64 longas (>=32) apos '=' ou ':'.
    #>
    [CmdletBinding()]
    param()
    $parts = @(
        'Bearer\s+[A-Za-z0-9\-._~+/=]{8,}',
        'sk-[A-Za-z0-9]{10,}',
        'ghp_[A-Za-z0-9]{20,}',
        'AKIA[0-9A-Z]{16}',
        'eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+',
        '[:=]\s*[''"]?[A-Fa-f0-9]{32,}',
        '[:=]\s*[''"]?[A-Za-z0-9+/=_-]{32,}'
    )
    return ($parts -join '|')
}

function Remove-SecretValuesNode {
    <#
    .SYNOPSIS
        Substitui por '[REDACTED]' (recursivo) valores textuais que casem o
        padrao de segredo.
    #>
    [CmdletBinding()]
    param($Node, [string]$Pattern)
    if ($null -eq $Node) {
        return $null
    }
    if ($Node -is [string]) {
        if ($Node -match $Pattern) {
            return '[REDACTED]'
        }
        return $Node
    }
    if ($Node -is [System.ValueType]) {
        return $Node
    }
    if ($Node -is [System.Collections.IDictionary]) {
        $clean = @{}
        foreach ($key in $Node.Keys) {
            $clean[$key] = Remove-SecretValuesNode -Node $Node[$key] -Pattern $Pattern
        }
        return $clean
    }
    if ($Node -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($element in $Node) {
            $redacted = Remove-SecretValuesNode -Node $element -Pattern $Pattern
            if ($null -eq $redacted) {
                $items += $null
            }
            else {
                $items += $redacted
            }
        }
        Write-Output -NoEnumerate $items
        return
    }
    $properties = @($Node.PSObject.Properties)
    if ($properties.Count -eq 0) {
        return $Node
    }
    $clean = New-Object PSCustomObject
    foreach ($property in $properties) {
        $clean | Add-Member -NotePropertyName $property.Name -NotePropertyValue (Remove-SecretValuesNode -Node $property.Value -Pattern $Pattern)
    }
    return $clean
}

function Remove-SecretValues {
    <#
    .SYNOPSIS
        Substitui por '[REDACTED]' (recursivo) valores textuais que parecem segredo.
    #>
    [CmdletBinding()]
    param($InputObject)
    $pattern = Get-SecretValuePattern
    $result = Remove-SecretValuesNode -Node $InputObject -Pattern $pattern
    if ($null -eq $result) {
        return $null
    }
    if ($result -is [array]) {
        Write-Output -NoEnumerate $result
        return
    }
    return $result
}

function Test-NoSensitiveKeysNode {
    [CmdletBinding()]
    param($Node, [string]$Pattern)
    if ($null -eq $Node) {
        return $true
    }
    if (($Node -is [string]) -or ($Node -is [System.ValueType])) {
        return $true
    }
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($key in $Node.Keys) {
            if ("$key" -match $Pattern) {
                return $false
            }
            if (-not (Test-NoSensitiveKeysNode -Node $Node[$key] -Pattern $Pattern)) {
                return $false
            }
        }
        return $true
    }
    if ($Node -is [System.Collections.IEnumerable]) {
        foreach ($element in $Node) {
            if (-not (Test-NoSensitiveKeysNode -Node $element -Pattern $Pattern)) {
                return $false
            }
        }
        return $true
    }
    foreach ($property in @($Node.PSObject.Properties)) {
        if ($property.Name -match $Pattern) {
            return $false
        }
        if (-not (Test-NoSensitiveKeysNode -Node $property.Value -Pattern $Pattern)) {
            return $false
        }
    }
    return $true
}

function Test-NoSensitiveKeys {
    <#
    .SYNOPSIS
        True se nenhum nome de chave casa o padrao sensivel (recursivo).
    #>
    [CmdletBinding()]
    param($InputObject)
    $pattern = Get-SensitiveKeyPattern
    return (Test-NoSensitiveKeysNode -Node $InputObject -Pattern $pattern)
}

function Test-NoSecretValuesNode {
    [CmdletBinding()]
    param($Node, [string]$Pattern)
    if ($null -eq $Node) {
        return $true
    }
    if ($Node -is [string]) {
        if ($Node -match $Pattern) {
            return $false
        }
        return $true
    }
    if ($Node -is [System.ValueType]) {
        return $true
    }
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($key in $Node.Keys) {
            if (-not (Test-NoSecretValuesNode -Node $Node[$key] -Pattern $Pattern)) {
                return $false
            }
        }
        return $true
    }
    if ($Node -is [System.Collections.IEnumerable]) {
        foreach ($element in $Node) {
            if (-not (Test-NoSecretValuesNode -Node $element -Pattern $Pattern)) {
                return $false
            }
        }
        return $true
    }
    foreach ($property in @($Node.PSObject.Properties)) {
        if (-not (Test-NoSecretValuesNode -Node $property.Value -Pattern $Pattern)) {
            return $false
        }
    }
    return $true
}

function Test-NoSecretValues {
    <#
    .SYNOPSIS
        False se algum VALOR textual retido casa os padroes de segredo (recursivo).
    #>
    [CmdletBinding()]
    param($InputObject)
    $pattern = Get-SecretValuePattern
    return (Test-NoSecretValuesNode -Node $InputObject -Pattern $pattern)
}
