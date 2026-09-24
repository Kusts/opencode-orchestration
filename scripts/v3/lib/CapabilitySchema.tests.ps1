<#!
.SYNOPSIS
    Testes standalone do CapabilitySchema.ps1 (Phase 1).
.DESCRIPTION
    Roda com `pwsh -NoProfile -File <este-arquivo>`; termina com exit 0/1.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$libPath = Join-Path $PSScriptRoot 'CapabilitySchema.ps1'
. $libPath

$passed = 0
$failed = 0

function Assert-SchemaTrue {
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

function Assert-SchemaThrows {
    param([scriptblock]$Script, [string]$Name)
    $threw = $false
    try {
        & $Script | Out-Null
    }
    catch {
        $threw = $true
    }
    Assert-SchemaTrue $threw $Name
}

function New-ValidCapabilityRecord {
    return [PSCustomObject]@{
        id           = 'agent:coder'
        type         = 'agent'
        name         = 'coder'
        status       = 'available'
        categories   = @('engineering')
        tags         = @('implementation', 'write')
        capabilities = @('code.bounded-edit', 'test.run')
        risk         = 'medium'
        trust        = 'approved'
        read_only    = $false
        metadata     = [PSCustomObject]@{ mode = 'subagent'; model = 'synthetic-model' }
    }
}

try {
    $id = Get-CapabilityId -Type ' Agent ' -Name ' Coder '
    Assert-SchemaTrue ($id -ceq 'agent:coder') 'canonical id trims and lowercases type and name'

    Assert-SchemaThrows { Get-CapabilityId -Type 'robot' -Name 'coder' } 'invalid type throws'
    Assert-SchemaThrows { Get-CapabilityId -Type 'agent' -Name '   ' } 'empty name throws'

    $valid = Test-CapabilityRecord -Record (New-ValidCapabilityRecord)
    Assert-SchemaTrue ($valid.Valid -and @( $valid.Errors ).Count -eq 0) 'valid record passes'

    $broken = New-ValidCapabilityRecord
    $broken.status = 'bogus-status'
    $broken.PSObject.Properties.Remove('id')
    $bad = Test-CapabilityRecord -Record $broken
    Assert-SchemaTrue ((-not $bad.Valid) -and @( $bad.Errors ).Count -ge 2) 'invalid record fails with errors'

    $nullReadOnly = New-ValidCapabilityRecord
    $nullReadOnly.read_only = $null
    $nullResult = Test-CapabilityRecord -Record $nullReadOnly
    Assert-SchemaTrue ($nullResult.Valid) 'read_only null is accepted'

    $stringReadOnly = New-ValidCapabilityRecord
    $stringReadOnly.read_only = 'yes'
    $stringResult = Test-CapabilityRecord -Record $stringReadOnly
    Assert-SchemaTrue (-not $stringResult.Valid) 'read_only string is rejected'

    $canonId = Get-CapabilityId -Type 'agent' -Name 'coder'
    $canonRec = New-ValidCapabilityRecord
    Assert-SchemaTrue (($canonRec.id -ceq $canonId) -and (Test-CapabilityRecord -Record $canonRec).Valid) 'canonical id accepted'

    $divergent = New-ValidCapabilityRecord
    $divergent.id = 'skill:coder'
    Assert-SchemaTrue (-not (Test-CapabilityRecord -Record $divergent).Valid) 'divergent id rejected for mismatched type'

    $wrongCase = New-ValidCapabilityRecord
    $wrongCase.id = 'Agent:Coder'
    Assert-SchemaTrue (-not (Test-CapabilityRecord -Record $wrongCase).Valid) 'non-canonical id casing rejected'

    $dictTags = New-ValidCapabilityRecord
    $dictTags.tags = @{ a = 'x' }
    Assert-SchemaTrue (-not (Test-CapabilityRecord -Record $dictTags).Valid) 'dictionary tags rejected'

    $nonString = New-ValidCapabilityRecord
    $nonString.tags = @('ok', 42)
    Assert-SchemaTrue (-not (Test-CapabilityRecord -Record $nonString).Valid) 'non-string array item rejected'

    $emptyItem = New-ValidCapabilityRecord
    $emptyItem.capabilities = @('code.bounded-edit', '   ')
    Assert-SchemaTrue (-not (Test-CapabilityRecord -Record $emptyItem).Valid) 'empty array item rejected'

    $duped = New-ValidCapabilityRecord
    $duped.tags = @('dup', 'dup')
    Assert-SchemaTrue (-not (Test-CapabilityRecord -Record $duped).Valid) 'duplicate array items rejected'

    $caseDistinct = New-ValidCapabilityRecord
    $caseDistinct.tags = @('Dup', 'dup')
    Assert-SchemaTrue ((Test-CapabilityRecord -Record $caseDistinct).Valid) 'case-distinct items accepted'

    $emptyEscape = Escape-JsonString -Text ''
    Assert-SchemaTrue ("$emptyEscape" -ceq '') 'escape handles empty string'
    $emptyJson = ConvertTo-DeterministicJson -InputObject ''
    Assert-SchemaTrue ($emptyJson -ceq '""') 'deterministic json encodes empty string as empty quotes'
    $emptyFieldJson = ConvertTo-DeterministicJson -InputObject @{ a = '' }
    Assert-SchemaTrue ($emptyFieldJson -ceq '{"a":""}') 'deterministic json handles empty field value'
    $emptyHash = Get-LogicalHash -InputObject ''
    Assert-SchemaTrue ($emptyHash -match '^sha256:[0-9a-f]{64}$') 'empty string hashes stably'

    $first = @{ b = 2; a = 1; nested = @{ z = @(1, 2); y = 'x' } }
    $second = @{ nested = @{ y = 'x'; z = @(1, 2) }; a = 1; b = 2 }
    $jsonFirst = ConvertTo-DeterministicJson -InputObject $first
    $jsonSecond = ConvertTo-DeterministicJson -InputObject $second
    Assert-SchemaTrue ($jsonFirst -ceq $jsonSecond) 'deterministic json is stable across key order'
    Assert-SchemaTrue ($jsonFirst -ceq '{"a":1,"b":2,"nested":{"y":"x","z":[1,2]}}') 'deterministic json sorts keys and stays compact'

    $hashA = Get-LogicalHash -InputObject $first
    $hashB = Get-LogicalHash -InputObject $second
    Assert-SchemaTrue (($hashA -ceq $hashB) -and ($hashA -match '^sha256:[0-9a-f]{64}$')) 'equal content yields equal sha256 hashes'

    $hashOther = Get-LogicalHash -InputObject @{ a = 1; b = 3 }
    Assert-SchemaTrue ($hashOther -cne $hashA) 'different content yields different hash'
}
catch {
    Write-Host ("FAIL unexpected error: {0}" -f $_)
    exit 1
}

Write-Host ("CapabilitySchema: {0} / {1} tests passed" -f $passed, ($passed + $failed))
if ($failed -gt 0) { exit 1 }
exit 0
