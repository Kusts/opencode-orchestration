[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet('Capture','Verify')][string]$Mode,
  [string]$Output,
  [Alias('Input')][string]$BaselinePath,
  [AllowEmptyString()][string[]]$Paths = @(),
  [string[]]$ProtectedRootsOverride = @()
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\runtime\lib\OrchestrationTargetGuard.ps1')
for ($i = 0; $i -lt $Paths.Count; $i++) {
  if ([string]::IsNullOrWhiteSpace([string]$Paths[$i])) { throw "ACTIVE_PATH_INVALID: Paths[$i] is null or empty." }
}
if ($PSBoundParameters.ContainsKey('ProtectedRootsOverride')) {
  $protectedRoots = @(Get-OrchestrationProtectedRoots -ProtectedRootsOverride $ProtectedRootsOverride)
} else {
  $protectedRoots = @(Get-OrchestrationProtectedRoots)
}
foreach ($pathArg in $Paths) {
  $pathArgFull = [IO.Path]::GetFullPath($pathArg)
  if (Test-Path -LiteralPath $pathArgFull -PathType Container) { throw ('ACTIVE_PATH_DIRECTORY_REJECTED: -Paths nao aceita diretorio: ' + $pathArgFull) }
}
if (-not [string]::IsNullOrWhiteSpace($Output)) {
  $outputCheck = [IO.Path]::GetFullPath($Output)
  try {
    $guardArgs = @{ TargetPath=$outputCheck; ExplicitTargetProvided=$true; OptIn=$false }
    if ($PSBoundParameters.ContainsKey('ProtectedRootsOverride')) { $guardArgs.ProtectedRootsOverride = $ProtectedRootsOverride }
    Assert-OrchestrationMutatingTargetAllowed @guardArgs
  } catch {
    throw ('ACTIVE_PATH_OUTPUT_IN_PROFILE: ' + $_.Exception.Message)
  }
}
function Get-ActivePathRecord([string]$InputPath) {
  if ([string]::IsNullOrWhiteSpace($InputPath)) { throw 'ACTIVE_PATH_INVALID: baseline path is null or empty.' }
  try { $full = [IO.Path]::GetFullPath($InputPath) }
  catch { throw ("ACTIVE_PATH_INVALID: invalid path value [$InputPath]: " + $_.Exception.Message) }
  if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return [ordered]@{ path=$full; missing=$true } }
  $item = Get-Item -LiteralPath $full
  return [ordered]@{
    path=$full
    sha256=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
    bytes=[long]$item.Length
    lastWriteTimeUtc=$item.LastWriteTimeUtc.ToString('o')
  }
}
if ($Mode -eq 'Capture') {
  if ([string]::IsNullOrWhiteSpace($Output)) { throw 'Capture requer -Output.' }
  $outputFull = [IO.Path]::GetFullPath($Output)
  $records = @()
  foreach ($p in $Paths) {
    $pathFull = [IO.Path]::GetFullPath($p)
    if (Test-Path -LiteralPath $pathFull -PathType Container) { throw ('ACTIVE_PATH_DIRECTORY_REJECTED: -Paths nao aceita diretorio: ' + $pathFull) }
    if ($pathFull.Equals($outputFull, [StringComparison]::OrdinalIgnoreCase)) { throw ('ACTIVE_PATH_OUTPUT_COLLISION: -Output coincide com -Paths: ' + $pathFull) }
    $records += Get-ActivePathRecord $pathFull
  }
  $parent = Split-Path -Parent $outputFull
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
  [IO.File]::WriteAllText($outputFull, ($records | ConvertTo-Json -Depth 5) + "`n", [Text.UTF8Encoding]::new($false))
  exit 0
}
  if ([string]::IsNullOrWhiteSpace($BaselinePath)) { throw 'Verify requer -Input.' }
  $parsedBaseline = Get-Content -LiteralPath $BaselinePath -Raw | ConvertFrom-Json
  $baseline = @()
  foreach ($entry in $parsedBaseline) { if ($entry -is [Array]) { $baseline += @($entry) } else { $baseline += $entry } }
$changes = New-Object System.Collections.ArrayList
$known = @{}
for ($i = 0; $i -lt $baseline.Count; $i++) {
  $record = $baseline[$i]
  if ($null -eq $record -or [string]::IsNullOrWhiteSpace([string]$record.path)) { throw "ACTIVE_PATH_INVALID: baseline[$i].path is null or empty." }
    $path = [string]$record.path
  $known[$path] = $true
  $current = Get-ActivePathRecord -InputPath $path
  if ([bool]$record.missing) {
    if (-not [bool]$current.missing) { [void]$changes.Add($path + ' (novo)') }
  } elseif ([bool]$current.missing) { [void]$changes.Add($path + ' (ausente)') }
  elseif (($record.sha256 -ne $current.sha256) -or ([long]$record.bytes -ne [long]$current.bytes)) { [void]$changes.Add($path + ' (alterado)') }
}
foreach ($p in $Paths) {
  $full = [IO.Path]::GetFullPath($p)
  if (-not $known.ContainsKey($full)) { [void]$changes.Add($full + ' (novo no baseline)') }
}
if ($changes.Count -gt 0) {
  Write-Output ('ACTIVE_PATH_CHANGED: ' + ($changes -join '; '))
  exit 1
}
Write-Host 'ACTIVE_PATHS_UNCHANGED'
exit 0
