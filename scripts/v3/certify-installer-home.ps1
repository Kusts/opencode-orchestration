[CmdletBinding()]
param(
  [string]$RepoRoot,
  [string]$TempBase = [IO.Path]::GetTempPath(),
  [switch]$SkipActiveHashGuard,
  [string]$Output,
  [string]$InstallerPath,
  [string]$UninstallerPath
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $entry = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { $PSCommandPath } else { [string]$MyInvocation.MyCommand.Path }
  if ([string]::IsNullOrWhiteSpace($entry)) { throw 'F2_REPOROOT_UNRESOLVED' }
  $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $entry))
}
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
$TempBase = [IO.Path]::GetFullPath($TempBase)
$allowed = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
if (-not $TempBase.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -and
    $TempBase.TrimEnd('\','/') -ne $allowed.TrimEnd('\','/')) { throw 'F2_TEMPBASE_OUTSIDE_TEMP' }
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$run = Join-Path $TempBase "oo-f2-$stamp"
$home1 = Join-Path $run 'home-clean'; $home2 = Join-Path $run 'home-reinstall'
$artifacts = Join-Path $run 'artifacts'
if (-not $Output) { $Output = Join-Path $artifacts 'certification.json' }
$Output = [IO.Path]::GetFullPath($Output)
$runPrefix = $run.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
if (-not $Output.StartsWith($runPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'F2_OUTPUT_OUTSIDE_RUN' }
$profileHome = if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $env:USERPROFILE } else { [Environment]::GetFolderPath('UserProfile') }
. (Join-Path $RepoRoot 'scripts\runtime\lib\OrchestrationTargetGuard.ps1')
Assert-OrchestrationMutatingTargetAllowed -TargetPath $Output -ExplicitTargetProvided $true -OptIn $false -ProtectedRootsOverride @($profileHome)
New-Item -ItemType Directory -Force -Path $home1,$home2,$artifacts | Out-Null
$guard = Join-Path $PSScriptRoot 'assert-active-paths-unchanged.ps1'
$active = @(
  (Join-Path $profileHome '.config\opencode\opencode.json'),
  (Join-Path $profileHome '.config\opencode\AGENTS.md'),
  (Join-Path $profileHome '.config\opencode\agents\coder.md'),
  (Join-Path $profileHome '.opencode-orchestration\manifest.json')
)
$guardLib = Join-Path $RepoRoot 'scripts\v3\assert-active-paths-unchanged.ps1'
$doc = [ordered]@{ run_directory=$run; monitored_paths=@($active); commands=[Collections.Generic.List[object]]::new(); stages=[ordered]@{}; active_before=$null; active_after=$null; planner_worker_smoke=[ordered]@{status='HOLD';limitation='No deterministic offline Planner-to-worker invocation established; reevaluation when pinned V2 runtime and provider are explicitly available.'} }
function Invoke-Step([string]$Name,[string]$File,[string[]]$Arguments,[string]$Target) {
  if (-not $File) { throw "F2_MISSING_SCRIPT:$Name" }
  $resolved = [IO.Path]::GetFullPath($File)
  $line = "powershell -NoProfile -File `"$resolved`" " + (($Arguments | ForEach-Object { '"' + ([string]$_).Replace('"','\"') + '"' }) -join ' ')
  & powershell.exe -NoProfile -File $resolved @Arguments
  $stepExit = $LASTEXITCODE
  $doc.commands.Add([ordered]@{name=$Name;command=$line;exit_code=$stepExit})
  if ($stepExit -ne 0) { throw "F2_STEP_FAILED:$Name exit=$stepExit" }
}
function Get-ManifestProjection([string]$Path,[string]$Target) {
  $m = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  $files = @($m.managed_files | ForEach-Object {
    $relative = if ($_.relative) { [string]$_.relative } else { [string]$_.path }
    $relative = $relative -replace [regex]::Escape($Target), '' -replace '^[\\/]+','' -replace '/','\'
    $relative
  } | Sort-Object -Unique)
  $configPaths = @($m.managed_config_paths | ForEach-Object {
    $relative = if ($_ -is [string]) { [string]$_ } elseif ($_.relative) { [string]$_.relative } else { [string]$_.path }
    $relative = $relative -replace [regex]::Escape($Target), '' -replace '^[\\/]+','' -replace '/','\'
    $relative
  } | Sort-Object -Unique)
  $projection = [ordered]@{
    package_version=[string]$m.package_version
    source_revision=[string]$m.source_revision
    config_ownership=[string]$m.config_ownership
    plugin_dependency=[string]$m.plugin_dependency
    runtime=[ordered]@{id=[string]$m.runtime.id;generation=[int]$m.runtime.generation;profile=[string]$m.runtime.profile}
    managed_files=$files
    managed_config_paths=$configPaths
  }
  $canonical = $projection | ConvertTo-Json -Depth 20 -Compress
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return [ordered]@{projection=$projection;sha256=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))).Replace('-','').ToLowerInvariant())} }
  finally { $sha.Dispose() }
}
function Get-PermissionTuples([string]$Text) {
  $front = [regex]::Match($Text,'(?ms)^---\s*\r?\n(.*?)\r?\n---')
  if (-not $front.Success) { return @() }
  $perm = [regex]::Match($front.Groups[1].Value,'(?ms)^permissions:\s*\r?\n(.*?)(?=^\S|\z)')
  if (-not $perm.Success) { return @() }
  $items = @()
  $current = @{}
  foreach ($line in ($perm.Groups[1].Value -split "`r?`n")) {
    if ($line -match '^\s+-\s+action:\s*(.*)$') {
      if ($current.Count) { $items += [ordered]@{action=$current.action;resource=$current.resource;effect=$current.effect} }
      $current=@{action=$Matches[1].Trim();resource='';effect=''}
    } elseif ($current.Count -and $line -match '^\s+resource:\s*(.*)$') { $current.resource=$Matches[1].Trim() }
    elseif ($current.Count -and $line -match '^\s+effect:\s*(.*)$') { $current.effect=$Matches[1].Trim() }
  }
  if ($current.Count) { $items += [ordered]@{action=$current.action;resource=$current.resource;effect=$current.effect} }
  return @($items)
}
try {
  if (-not $SkipActiveHashGuard) {
    & $guard -Mode Capture -Output (Join-Path $artifacts 'active-before.json') -Paths $active -ProtectedRootsOverride @($profileHome)
    $doc.active_before = Join-Path $artifacts 'active-before.json'
  }
  $installer = if ($InstallerPath) { $InstallerPath } else { Join-Path $RepoRoot 'install.ps1' }
  $uninstaller = if ($UninstallerPath) { $UninstallerPath } else { Join-Path $RepoRoot 'uninstall.ps1' }
  $installArgs = @('-TargetHome',$home1,'-Runtime','V2')
  Invoke-Step 'install-clean' $installer $installArgs $home1
  $manifest = Join-Path $home1 '.opencode-orchestration\manifest.json'
  if (-not (Test-Path $manifest)) { throw 'F2_MANIFEST_MISSING' }
  $proj1 = Get-ManifestProjection $manifest $home1
  $manifestHash1 = $proj1.sha256
  $managed1 = @(Get-Content $manifest -Raw | ConvertFrom-Json).managed_files
  $doc.stages.install_clean = [ordered]@{manifest_sha256=$manifestHash1;managed_file_count=@($managed1).Count}
  Invoke-Step 'reinstall-idempotency' $installer $installArgs $home1
  $proj2 = Get-ManifestProjection $manifest $home1
  $manifestHash2 = $proj2.sha256
  $doc.stages.idempotency = [ordered]@{first_hash=$manifestHash1;second_hash=$manifestHash2;passed=($manifestHash1 -eq $manifestHash2)}
  if ($manifestHash1 -ne $manifestHash2) { throw 'F2_IDEMPOTENCY_HASH_MISMATCH' }
  Invoke-Step 'install-clean-reference' $installer @('-TargetHome',$home2,'-Runtime','V2') $home2
  $manifest2 = Join-Path $home2 '.opencode-orchestration\manifest.json'
  $proj3 = Get-ManifestProjection $manifest2 $home2
  $manifestHash3 = $proj3.sha256
  $raw1 = Get-Content $manifest -Raw | ConvertFrom-Json
  $raw2 = Get-Content $manifest2 -Raw | ConvertFrom-Json
  $differing = @($raw1.PSObject.Properties.Name | Where-Object {
    $a = $raw1.$_; $b = $raw2.$_
    (($a | ConvertTo-Json -Depth 20 -Compress) -cne ($b | ConvertTo-Json -Depth 20 -Compress))
  } | Sort-Object)
  $freshEqual = $manifestHash2 -eq $manifestHash3
  $byteDiffs = New-Object System.Collections.ArrayList
  $unexplained = New-Object System.Collections.ArrayList
  $permissionOrderDiffers = $false
  foreach ($rel in $proj2.projection.managed_files) {
    $f1 = Join-Path (Join-Path $home1 '.config\opencode') $rel
    $f2 = Join-Path (Join-Path $home2 '.config\opencode') $rel
    if (-not (Test-Path $f1 -PathType Leaf) -or -not (Test-Path $f2 -PathType Leaf)) { [void]$unexplained.Add("$rel (missing managed file)"); continue }
    $t1 = [IO.File]::ReadAllText($f1); $t2 = [IO.File]::ReadAllText($f2)
    if ($t1 -ceq $t2) { continue }
    $n1 = $t1.Replace($home1,'<TARGET_HOME>').Replace(($home1 -replace '\\','/'),'<TARGET_HOME>')
    $n2 = $t2.Replace($home2,'<TARGET_HOME>').Replace(($home2 -replace '\\','/'),'<TARGET_HOME>')
    if ($rel -match '^agents\\.+\.md$') {
      $tuples1 = @(Get-PermissionTuples $n1); $tuples2 = @(Get-PermissionTuples $n2)
      if ($tuples1.Count -eq 0 -or $tuples2.Count -eq 0 -or @($tuples1 | Where-Object { -not $_.action -or -not $_.resource -or -not $_.effect }).Count -gt 0 -or @($tuples2 | Where-Object { -not $_.action -or -not $_.resource -or -not $_.effect }).Count -gt 0) {
        [void]$unexplained.Add("$rel (permission tuples missing or malformed)"); continue
      }
      $sig1 = @($tuples1 | ForEach-Object { "$($_.action)`t$($_.resource)`t$($_.effect)" } | Sort-Object)
      $sig2 = @($tuples2 | ForEach-Object { "$($_.action)`t$($_.resource)`t$($_.effect)" } | Sort-Object)
      if (($sig1 -join "`n") -cne ($sig2 -join "`n")) { [void]$unexplained.Add($rel); continue }
      $ordered1 = @($tuples1 | ForEach-Object { "$($_.action)`t$($_.resource)`t$($_.effect)" })
      $ordered2 = @($tuples2 | ForEach-Object { "$($_.action)`t$($_.resource)`t$($_.effect)" })
      if (($ordered1 -join "`n") -cne ($ordered2 -join "`n")) { $permissionOrderDiffers=$true }
      $n1 = [regex]::Replace($n1,'(?ms)^permissions:\s*\r?\n.*?(?=^\S|\z)',"permissions:`n<TUPLES>")
      $n2 = [regex]::Replace($n2,'(?ms)^permissions:\s*\r?\n.*?(?=^\S|\z)',"permissions:`n<TUPLES>")
    }
    if ($rel -match '^(AGENTS\.md|opencode\.json)$') {
      if ($n1 -ceq $n2) { [void]$byteDiffs.Add("$rel embeds TargetHome") }
      else { [void]$unexplained.Add($rel) }
    }
    if ($rel -notmatch '^(AGENTS\.md|opencode\.json)$' -and $n1 -cne $n2) { [void]$unexplained.Add($rel) }
  }
  if ($permissionOrderDiffers) { [void]$byteDiffs.Add('Permission tuple order differs; semantically relevant for V2 (allow/ask/deny ordering).') }
  if ($unexplained.Count -gt 0) { [void]$byteDiffs.Add('UNEXPLAINED_CONTENT_DIFFERENCE'); $freshEqual=$false }
  $doc.stages.fresh_home_comparison = [ordered]@{home_clean_hash=$manifestHash2;home_reinstall_hash=$manifestHash3;equal=$freshEqual;differing_top_level_properties=$differing;byte_level_differences=$byteDiffs;permission_order_differs=$permissionOrderDiffers;order_is_semantically_relevant=$permissionOrderDiffers;unexplained_files=@($unexplained)}
  $config = Join-Path $home1 '.config'
  $agentNames = @('build','explorer','researcher','coder','tester','reviewer','debugger','security-reviewer','architect','docs-manager','frontend-engineer','backend-engineer','database-engineer','ai-agent-engineer','automation-engineer','infra-engineer','requirements-analyst','product-designer','skeptic')
  $opencodeCommand = Get-Command opencode -ErrorAction SilentlyContinue
  $opencodePath = if ($opencodeCommand) { if ($opencodeCommand.Source) { $opencodeCommand.Source } else { $opencodeCommand.Definition } } else { $null }
  $savedEnv = @{}
  foreach ($name in @('XDG_CONFIG_HOME','HOME','USERPROFILE','TEMP','TMP','OPENCODE_CONFIG','OPENCODE_CONFIG_DIR')) { $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name,'Process') }
  $outText = ''; $discoveryStatus='HOLD'; $discoveryReason=''; $discoveredCount=$null
  try {
    $env:XDG_CONFIG_HOME = Join-Path $home1 '.config'; $env:HOME=$home1; $env:USERPROFILE=$home1
    $env:TEMP=Join-Path $home1 'temp'; $env:TMP=$env:TEMP
    New-Item -ItemType Directory -Force -Path $env:TEMP | Out-Null
    Remove-Item Env:OPENCODE_CONFIG -ErrorAction SilentlyContinue; Remove-Item Env:OPENCODE_CONFIG_DIR -ErrorAction SilentlyContinue
    if (-not $opencodePath) { throw 'Get-Command opencode: command not found in parent PATH.' }
    $outText = (& $opencodePath debug agents --standalone 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0) {
      $observed = @($agentNames | Where-Object { $outText -match "(?m)\b$([regex]::Escape($_))\b" })
      if ($observed.Count -eq $agentNames.Count) { $discoveryStatus='PASS'; $discoveredCount=$observed.Count } else { $discoveryReason="Observed $($observed.Count) of $($agentNames.Count) expected agents." }
    } else {
      $firstLine = (($outText -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1) -join '')
      if ($firstLine.Length -gt 240) { $firstLine = $firstLine.Substring(0,240) }
      $discoveryReason="exit=$LASTEXITCODE error=$firstLine"
    }
  } catch { $discoveryReason=$_.Exception.Message }
  finally { foreach ($name in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($name,$savedEnv[$name],'Process') } }
  if ($discoveryStatus -ne 'PASS') { $discoveredCount=$null }
  $doc.stages.agent_discovery = [ordered]@{status=$discoveryStatus;command='opencode debug agents --standalone';discovered_count=$discoveredCount;expected_count=19;output_truncated=($outText.Length -gt 512);reason=$discoveryReason}
  Invoke-Step 'uninstall-reference' $uninstaller @('-TargetHome',$home2) $home2
  $doc.stages.uninstall = [ordered]@{exit=0;preserved_unowned='not independently enumerated'}
  if (-not $SkipActiveHashGuard) {
    $verifyPaths = [string[]]@($active)
    $verifyArgs = @{ Mode='Verify'; BaselinePath=(Join-Path $artifacts 'active-before.json'); ProtectedRootsOverride=@($profileHome); Paths=$verifyPaths }
    try {
      $verify = & $guard @verifyArgs 2>&1
      $exitCode = $LASTEXITCODE
      $doc.active_after = [ordered]@{exit_code=$exitCode;output=($verify -join "`n")}
    } catch {
      $problem = [string]$verifyArgs.Paths | Where-Object { [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
      $doc.active_after = [ordered]@{exit_code=1;output=("ACTIVE_PATH_INVALID: " + $_.Exception.Message);problematic_value=$problem}
      $exitCode=1
    }
    if ($exitCode -ne 0) { throw "F2_ACTIVE_CONFIG_CHANGED $($verify -join ' ')" }
  }
  if ($unexplained.Count -gt 0) { throw 'F2_UNEXPLAINED_CONTENT_DIFFERENCE' }
  if (-not $freshEqual) { throw 'F2_FRESH_HOME_MISMATCH' }
  $doc.verdict='PASS'
} catch { $doc.verdict='FAIL'; $doc.failure=$_.Exception.Message; $doc.exit_code=1 }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Output) | Out-Null
[IO.File]::WriteAllText($Output,($doc | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
if ($doc.verdict -ne 'PASS') { [Console]::Error.WriteLine($doc.failure); exit 1 }
Write-Output $Output
