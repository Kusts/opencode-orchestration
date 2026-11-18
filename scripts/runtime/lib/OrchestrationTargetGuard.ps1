function Test-OrchestrationNonInteractiveContext {
  param([Nullable[bool]]$IsNonInteractive = $null)
  if ($null -ne $IsNonInteractive) { return [bool]$IsNonInteractive }
  return (($env:CI -match '^(true|1)$') -or ($env:GITHUB_ACTIONS -match '^(true|1)$') -or (-not [Environment]::UserInteractive))
}

function ConvertTo-OrchestrationComparablePath {
  param([Parameter(Mandatory)][string]$Path)
  $value = $Path
  if ($value.StartsWith('\\.\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'MUTATING_TARGET_REQUIRES_EXPLICIT_PATH: prefixo de dispositivo \\.\ recusado.'
  }
  if ($value.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
    if ($value -notmatch '^\\\\\?\\[A-Za-z]:\\') {
      throw 'MUTATING_TARGET_REQUIRES_EXPLICIT_PATH: prefixo \\?\ fora do formato de drive recusado.'
    }
    $value = $value.Substring(4)
  }
  if ($value.StartsWith('\\', [StringComparison]::Ordinal)) {
    return $value.TrimEnd('\')
  }
  $full = [IO.Path]::GetFullPath($value)
  $volume = [IO.Path]::GetPathRoot($full)
  if ($full.Equals($volume, [StringComparison]::OrdinalIgnoreCase)) { return $full }
  return $full.TrimEnd('\', '/')
}

function Get-OrchestrationProtectedRoots {
  param([string[]]$ProtectedRootsOverride = @())
  $candidates = @()
  if ($PSBoundParameters.ContainsKey('ProtectedRootsOverride')) {
    $candidates = @($ProtectedRootsOverride)
  } else {
    $candidates += $env:USERPROFILE
    $candidates += [Environment]::GetFolderPath('UserProfile')
    $candidates += $env:HOME
    if (-not [string]::IsNullOrWhiteSpace($env:HOMEDRIVE) -and -not [string]::IsNullOrWhiteSpace($env:HOMEPATH)) {
      $candidates += ($env:HOMEDRIVE + $env:HOMEPATH)
    }
  }
  $roots = New-Object System.Collections.ArrayList
  foreach ($candidate in $candidates) {
    if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
    try {
      $canonical = ConvertTo-OrchestrationComparablePath ([string]$candidate)
      if (-not (@($roots | Where-Object { $_.Equals($canonical, [StringComparison]::OrdinalIgnoreCase) }).Count)) {
        [void]$roots.Add($canonical)
      }
    } catch { }
  }
  if ($roots.Count -eq 0) { throw 'MUTATING_TARGET_PROFILE_ROOT_UNKNOWN: nenhuma raiz de perfil pode ser resolvida; alvo recusado fail-closed.' }
  return @($roots)
}

function Test-OrchestrationPathUnderRoot {
  param([string]$Path, [string]$Root)
  if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
  $p = ConvertTo-OrchestrationComparablePath $Path
  $r = ConvertTo-OrchestrationComparablePath $Root
  $separator = [IO.Path]::DirectorySeparatorChar
  return $p.Equals($r, [StringComparison]::OrdinalIgnoreCase) -or
    $p.StartsWith($r.TrimEnd('\', '/') + $separator, [StringComparison]::OrdinalIgnoreCase) -or
    ($p.StartsWith('\\', [StringComparison]::Ordinal) -and $p.StartsWith($r.TrimEnd('\', '/') + '\', [StringComparison]::OrdinalIgnoreCase))
}

function Get-OrchestrationResolvedPath {
  param([Parameter(Mandatory)][string]$Path)
  $cursor = ConvertTo-OrchestrationComparablePath $Path
  $resolvedPath = ConvertTo-OrchestrationComparablePath $Path
  while (-not [string]::IsNullOrWhiteSpace($cursor)) {
    if (Test-Path -LiteralPath $cursor) {
      try {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
          if ($PSVersionTable.PSVersion.Major -ge 6 -and $null -ne $item.Target) {
            $target = $item.ResolveLinkTarget($true)
            if ($null -eq $target) { throw 'target de reparse point nao resolvido' }
            throw ('reparse point resolvido para ' + $target.FullName + '; alvo com reparse recusado fail-closed')
          } else {
            throw ('reparse point nao resolvido nesta versao do PowerShell: ' + $cursor)
          }
        }
      } catch {
        throw ('MUTATING_TARGET_REPARSE_UNVERIFIED: nao foi possivel validar ancestry de ' + $Path + ': ' + $_.Exception.Message)
      }
    }
    $volume = [IO.Path]::GetPathRoot($cursor)
    if ($cursor.Equals($volume, [StringComparison]::OrdinalIgnoreCase)) { break }
    $parent = Split-Path -Parent $cursor -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cursor) { break }
    $cursor = $parent.TrimEnd('\', '/')
  }
  return $resolvedPath
}

function Assert-OrchestrationMutatingTargetAllowed {
  param(
    [Parameter(Mandatory)][string]$TargetPath,
    [Parameter(Mandatory)][bool]$ExplicitTargetProvided,
    [Parameter(Mandatory)][bool]$OptIn,
    [Nullable[bool]]$IsNonInteractive = $null,
    [string[]]$ProtectedRootsOverride = @()
  )
  # ExplicitTargetProvided e IsNonInteractive permanecem por compatibilidade;
  # a autoridade atual e exclusivamente -OptIn.
  $raw = $TargetPath
  $target = ConvertTo-OrchestrationComparablePath $raw
  if ($target.StartsWith('\\', [StringComparison]::Ordinal)) {
    throw ('MUTATING_TARGET_REQUIRES_EXPLICIT_PATH: alvo UNC recusado; use -AllowUserProfileTarget somente se a escrita for intencional.')
  }
  $resolvedTarget = Get-OrchestrationResolvedPath $target
  if ($PSBoundParameters.ContainsKey('ProtectedRootsOverride')) {
    $profiles = @(Get-OrchestrationProtectedRoots -ProtectedRootsOverride $ProtectedRootsOverride)
  } else {
    $profiles = @(Get-OrchestrationProtectedRoots)
  }
  $protectedSubtrees = @()
  foreach ($root in $profiles) {
    $protectedSubtrees += (Join-Path $root '.config\opencode')
    $protectedSubtrees += (Join-Path $root '.opencode-orchestration')
  }
  $tempRoots = @([IO.Path]::GetTempPath(), $env:TEMP, $env:TMP) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
  $validTempRoots = New-Object System.Collections.ArrayList
  foreach ($tempRoot in $tempRoots) {
    try { $tempCanonical = ConvertTo-OrchestrationComparablePath ([string]$tempRoot) } catch { continue }
    $ancestorOfProfile = $false
    foreach ($root in $profiles) {
      if (Test-OrchestrationPathUnderRoot -Path $root -Root $tempCanonical) { $ancestorOfProfile = $true; break }
    }
    if (-not $ancestorOfProfile -and -not (@($validTempRoots | Where-Object { $_.Equals($tempCanonical, [StringComparison]::OrdinalIgnoreCase) }).Count)) {
      [void]$validTempRoots.Add($tempCanonical)
    }
  }
  $underProtected = $false
  foreach ($root in $profiles) {
    if ((Test-OrchestrationPathUnderRoot $target $root) -or (Test-OrchestrationPathUnderRoot $resolvedTarget $root)) { $underProtected = $true; break }
  }
  if (-not $underProtected) { return }
  if ($OptIn) { return }
  $underTemp = $false
  foreach ($tempRoot in $validTempRoots) {
    if ((Test-OrchestrationPathUnderRoot $target $tempRoot) -and (Test-OrchestrationPathUnderRoot $resolvedTarget $tempRoot)) { $underTemp = $true; break }
  }
  $underSensitive = $false
  foreach ($subtree in $protectedSubtrees) {
    if ((Test-OrchestrationPathUnderRoot $target $subtree) -or (Test-OrchestrationPathUnderRoot $resolvedTarget $subtree)) { $underSensitive = $true; break }
  }
  if ($underTemp -and -not $underSensitive) { return }
  throw ('MUTATING_TARGET_REQUIRES_EXPLICIT_PATH: alvo no perfil exige -AllowUserProfileTarget, mesmo quando o caminho foi informado explicitamente.')
}

# Residual known: short 8.3 names and subst/mapped drives are not expanded;
# lexical canonicalization cannot prove equivalence across those aliases.
