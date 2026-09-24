<#!
.SYNOPSIS
    V3 Capability ids: fingerprints, logical identity helpers and projection
    resolution for skill directories.
.DESCRIPTION
    Dot-sourceable library (filesystem reads only, no writes, no runtime).
    Junctions are reported via LinkType/Target and are never traversed with a
    blind recurse. This module never decides permission.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-FileSha256 {
    <#
    .SYNOPSIS
        Returns "sha256:<hex>" for a file, or $null when it is absent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $hex = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    return ("sha256:{0}" -f $hex)
}

function Resolve-SkillProjection {
    <#
    .SYNOPSIS
        Resolves one projected skill entry (junction-aware) without traversing it.
    .OUTPUTS
        Hashtable @{ LogicalPath; Target; IsJunction = [bool]; Exists = [bool] }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return @{ LogicalPath = $Path; Target = $null; IsJunction = $false; Exists = $false }
    }
    $isJunction = ($item.LinkType -ceq 'Junction') -or ($item.LinkType -ceq 'SymbolicLink')
    $target = $null
    if ($null -ne $item.Target) {
        $target = (@($item.Target) | ForEach-Object { "$_" }) -join ';'
    }
    if ($isJunction) {
        $exists = $false
        foreach ($candidate in @($item.Target)) {
            if (-not [string]::IsNullOrWhiteSpace("$candidate") -and (Test-Path -LiteralPath "$candidate")) {
                $exists = $true
            }
        }
        return @{ LogicalPath = $item.FullName; Target = $target; IsJunction = $true; Exists = $exists }
    }
    return @{ LogicalPath = $item.FullName; Target = $target; IsJunction = $false; Exists = $true }
}

function Get-SkillProjectedEntries {
    <#
    .SYNOPSIS
        Enumerates the direct children of a skills root (no blind recurse).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )
    $entries = @()
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return $entries
    }
    $children = @(Get-ChildItem -LiteralPath $Root -Force | Sort-Object Name)
    foreach ($child in $children) {
        $entries += (Resolve-SkillProjection -Path $child.FullName)
    }
    return $entries
}

function Get-RelativeRepoPath {
    <#
    .SYNOPSIS
        Returns the repo-relative path (forward slashes), or the input unchanged
        when it is not under the repo root.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FullPath,
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )
    try {
        $full = [IO.Path]::GetFullPath($FullPath)
        $root = [IO.Path]::GetFullPath($RepoRoot)
        if ($full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
            $relative = $full.Substring($root.Length).TrimStart('\', '/')
            return ($relative -replace '\\', '/')
        }
    }
    catch {
    }
    return $FullPath
}
