$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OrchestrationExternalActionClaim.ps1')

$script:results = [System.Collections.Generic.List[object]]::new()
function Evaluate($Claim, [string]$ActionHash = 'abc123', [string[]]$UsedNonces = @(), [datetime]$Now) {
  $result = Test-OcExternalActionClaim -Claim $Claim -ActionHash $ActionHash -UsedNonces $UsedNonces -Now $Now
  foreach ($field in @('claim_present','action_bound','fresh','nonce_unused','well_formed','effective')) {
    if ($result.$field -isnot [bool]) { throw "Diagnostic field $field must be Boolean." }
  }
  if (-not $result.well_formed -and ($result.action_bound -or $result.fresh -or $result.nonce_unused)) {
    throw 'Malformed claims must not bind, be fresh, or have an unused nonce.'
  }
  if ($result.trust -cne 'UNVERIFIED_LOCAL' -or $result.effective -ne $false) {
    throw 'Every diagnostic must remain unverified and ineffective.'
  }
  $script:results.Add($result)
  return $result
}

$now = [datetime]::Parse('2026-11-14T12:00:00Z').ToUniversalTime()
$claim = @{
  action_hash = 'abc123'; scope = 'external-action'; claimed_by = 'operator'
  source = 'local-fixture'; claimed_at = '2026-11-14T11:00:00Z'
  expires_at = '2026-11-14T13:00:00Z'; nonce = 'n-1'
}
$validLooking = Evaluate $claim -Now $now
if (-not $validLooking.claim_present -or -not $validLooking.action_bound -or -not $validLooking.fresh -or -not $validLooking.nonce_unused -or -not $validLooking.well_formed) { throw 'Valid-looking fixture diagnostics incorrect.' }
$mismatch = Evaluate $claim -ActionHash other -Now $now
if ($mismatch.action_bound) { throw 'Action mismatch was accepted.' }
$scopeMismatch = $claim.Clone(); $scopeMismatch.scope = 'other'
$scopeResult = Evaluate $scopeMismatch -Now $now
if ($scopeResult.action_bound -or $scopeResult.effective) { throw 'Scope mismatch was accepted.' }
foreach ($badActionHash in @('', $null, '  ')) {
  if ((Evaluate $claim -ActionHash $badActionHash -Now $now).action_bound) { throw 'Empty action hash bound a nonempty claim.' }
}
$caseMismatch = $claim.Clone(); $caseMismatch.action_hash = 'ABC123'
if ((Evaluate $caseMismatch -Now $now).action_bound) { throw 'Action hash comparison must be case-sensitive.' }
$expiredClaim = $claim.Clone(); $expiredClaim.expires_at = '2026-11-14T11:30:00Z'
if ((Evaluate $expiredClaim -Now $now).fresh) { throw 'Expired claim was accepted.' }
$equalExpiry = $claim.Clone(); $equalExpiry.expires_at = '2026-11-14T12:00:00Z'
if ((Evaluate $equalExpiry -Now $now).fresh) { throw 'Expiry equal to Now was accepted.' }
$futureClaim = $claim.Clone(); $futureClaim.claimed_at = '2026-11-14T12:01:00Z'
if ((Evaluate $futureClaim -Now $now).fresh) { throw 'Future claimed_at was accepted.' }
$badOrder = $claim.Clone(); $badOrder.expires_at = '2026-11-14T10:00:00Z'
if ((Evaluate $badOrder -Now $now).fresh) { throw 'Expiry not after claim time was accepted.' }
if ((Evaluate $claim -UsedNonces @('n-1') -Now $now).nonce_unused) { throw 'Replayed nonce was accepted.' }
# Replay comparison is case-insensitive only; values are not trimmed or Unicode-normalized.
if ((Evaluate $claim -UsedNonces @('N-1') -Now $now).nonce_unused) { throw 'Case-different nonce replay was not conservatively detected.' }
$malformedClaim = $claim.Clone(); $malformedClaim.approved = $true
if ((Evaluate $malformedClaim -Now $now).well_formed) { throw 'Unknown field accepted.' }
$absent = Evaluate $null -Now $now
if ($absent.claim_present -or $absent.action_bound -or $absent.fresh -or $absent.nonce_unused) { throw 'Absent claim diagnostics incorrect.' }
$objectClaim = [pscustomobject]$claim.Clone()
if ((Evaluate $objectClaim -Now $now).well_formed) { throw 'PSCustomObject accepted.' }
$nonString = $claim.Clone(); $nonString.source = 42
if ((Evaluate $nonString -Now $now).well_formed) { throw 'Non-string field accepted.' }
$missingKey = $claim.Clone(); $missingKey.Remove('source')
if ((Evaluate $missingKey -Now $now).well_formed) { throw 'Missing key accepted.' }
foreach ($field in @('action_hash','scope','claimed_by','source','claimed_at','expires_at','nonce')) {
  $whitespace = $claim.Clone(); $whitespace[$field] = ' '
  if ((Evaluate $whitespace -Now $now).well_formed) { throw "Whitespace field accepted: $field" }
}
$emptyHash = $claim.Clone(); $emptyHash.action_hash = ''
if ((Evaluate $emptyHash -Now $now).well_formed) { throw 'Empty action hash accepted.' }
$emptyClaimHash = $emptyHash.Clone()
if ((Evaluate $emptyClaimHash -ActionHash '' -Now $now).action_bound -or (Evaluate $emptyClaimHash -ActionHash '' -Now $now).effective) { throw 'Empty claim hash must remain unbound and ineffective.' }
foreach ($bad in @('not-a-date', "2026-11-14T11:00:00Z`n", ' 2026-11-14T11:00:00Z', '2026-11-14T11:00:00Z ', '2026-11-14T11:00:00z', '2026-11-14T11:00:00')) {
  $badClaim = $claim.Clone(); $badClaim.claimed_at = $bad
  if ((Evaluate $badClaim -Now $now).well_formed) { throw "Invalid timestamp accepted: $bad" }
}
$offsetClaim = $claim.Clone(); $offsetClaim.claimed_at = '2026-11-14T06:00:00-05:00'; $offsetClaim.expires_at = '2026-11-14T08:00:00-05:00'
if (-not (Evaluate $offsetClaim -Now $now).fresh -or (Evaluate $offsetClaim -Now $now.AddHours(4)).fresh) { throw 'Offset instants compared incorrectly.' }
$localNow = $now.ToLocalTime()
if (-not (Evaluate $claim -Now $localNow).fresh) { throw 'Local Now did not normalize to the matching UTC instant.' }
$unspecifiedNow = [datetime]::SpecifyKind($now, [DateTimeKind]::Unspecified)
if (-not (Evaluate $claim -Now $unspecifiedNow).fresh) { throw 'Unspecified Now did not follow UTC normalization.' }

# Scan source/config text with bounded, explicit traversal; no recursive provider walk.
$rootItem = Get-Item $PSScriptRoot
while ($rootItem -and -not (Test-Path (Join-Path $rootItem.FullName '.git'))) { $rootItem = $rootItem.Parent }
if (-not $rootItem) { throw 'Could not locate repository root (.git).' }
$rootPath = [IO.Path]::GetFullPath($rootItem.FullName).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
$helperPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'OrchestrationExternalActionClaim.ps1'))
$testPath = [IO.Path]::GetFullPath($PSCommandPath)
$extensions = @('.ps1','.psm1','.psd1','.js','.mjs','.cjs','.ts','.mts','.cts','.tsx','.jsx','.json','.jsonc','.yaml','.yml','.toml','.cmd','.bat','.sh','.py','.vbs','.ps1xml','.txt','.jsonl','.xml','.html')
$excludedRoot = @('.git','.opencode','cache','evidence','generated','docs','tests','scratchpad')
$binaryExtensions = @('.png','.jpg','.jpeg','.gif','.webp','.ico','.pdf','.zip','.7z','.dll','.exe','.pdb','.woff','.woff2','.ttf','.mp4','.mp3')
$matcher = '(?i)(OrchestrationExternalActionClaim|Test-OcExternalActionClaim)'
if ('synthetic OrchestrationExternalActionClaim' -notmatch $matcher -or 'ordinary unrelated text' -match $matcher) { throw 'Static matcher positive/negative self-check failed.' }
function Get-RelativePathCompat([string]$Path) {
  if (-not $Path.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)) { throw "Path escaped scan root: $Path" }
  return $Path.Substring($rootPath.Length).Replace('\','/')
}
function Get-ScanFiles([string]$base, [string]$helper, [string]$test, [long]$MaxBytes = 20MB) {
  $pending = [Collections.Generic.Stack[string]]::new(); $pending.Push($base)
  while ($pending.Count) {
    $dir = $pending.Pop()
    foreach ($entry in Get-ChildItem -LiteralPath $dir -Force) {
      $rel = Get-RelativePathCompat ([IO.Path]::GetFullPath($entry.FullName))
      $top = ($rel -split '/')[0]
      if ($entry.PSIsContainer) {
        if ($entry.Name -ieq 'node_modules' -or $top -in $excludedRoot) { continue }
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Unscannable source reparse-point directory: $rel" }
        $pending.Push($entry.FullName); continue
      }
      if ($entry.Name -match '^\.env(?:$|rc$|\..*)' -or $entry.Name -ieq 'models.jsonc') { continue }
      if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Unscannable source reparse-point file: $rel" }
      $ext = [IO.Path]::GetExtension($entry.Name).ToLowerInvariant()
      if ($binaryExtensions -contains $ext) { continue }
      if ($ext -and $ext -notin $extensions -and -not $entry.Name.StartsWith('.')) { continue }
      if ([IO.Path]::GetFullPath($entry.FullName) -ieq $helper -or [IO.Path]::GetFullPath($entry.FullName) -ieq $test) { continue }
      if ($entry.Length -gt $MaxBytes) { throw "Unscannable source file exceeds configured limit: $rel" }
      Write-Output $entry.FullName
    }
  }
}
function Read-ScanText([string]$Path) {
  $bytes = [IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -ge 4 -and $bytes[0] -eq 0xff -and $bytes[1] -eq 0xfe -and $bytes[2] -eq 0 -and $bytes[3] -eq 0) { throw "Unscannable UTF-32 text: $(Get-RelativePathCompat $Path)" }
  if ($bytes.Length -ge 4 -and $bytes[0] -eq 0 -and $bytes[1] -eq 0 -and $bytes[2] -eq 0xfe -and $bytes[3] -eq 0xff) { throw "Unscannable UTF-32 text: $(Get-RelativePathCompat $Path)" }
  if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xff -and $bytes[1] -eq 0xfe) { return [Text.Encoding]::Unicode.GetString($bytes,2,$bytes.Length-2) }
  if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xfe -and $bytes[1] -eq 0xff) { return [Text.Encoding]::BigEndianUnicode.GetString($bytes,2,$bytes.Length-2) }
  if ([Array]::IndexOf($bytes,[byte]0) -ge 0) { throw "Unscannable text encoding (NUL without UTF-16 BOM): $(Get-RelativePathCompat $Path)" }
  try { return ([Text.UTF8Encoding]::new($false,$true)).GetString($bytes) } catch { throw "Unscannable UTF-8 text: $(Get-RelativePathCompat $Path)" }
}
function Assert-NoReferences([string]$base, [string]$helper, [string]$test) {
  foreach ($file in Get-ScanFiles $base $helper $test) {
    $relative = Get-RelativePathCompat $file
    if ((Read-ScanText $file) -match $matcher) { throw "Shadow claim diagnostic referenced outside its exact helper/test: $relative" }
  }
}
function Assert-ScannerFixture {
  $tempRoot = [IO.Path]::GetTempPath()
  $preferred = Join-Path $env:LOCALAPPDATA 'Temp\opencode'
  if ($env:LOCALAPPDATA -and (Test-Path -LiteralPath $preferred -PathType Container)) { $tempRoot = $preferred }
  $tmp = Join-Path $tempRoot ("oc-claim-scan-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmp | Out-Null
  try {
    New-Item -ItemType Directory -Path (Join-Path $tmp 'scripts/build'),(Join-Path $tmp 'scripts/cache'),(Join-Path $tmp 'cache'),(Join-Path $tmp 'node_modules/nested'),(Join-Path $tmp 'src') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $tmp 'scripts/build/x.ps1'),'OrchestrationExternalActionClaim')
    [IO.File]::WriteAllText((Join-Path $tmp 'cache/y.ps1'),'Test-OcExternalActionClaim')
    [IO.File]::WriteAllText((Join-Path $tmp 'scripts/cache/nested.ps1'),'Test-OcExternalActionClaim')
    [IO.File]::WriteAllText((Join-Path $tmp 'node_modules/nested/x.ps1'),'Test-OcExternalActionClaim')
    [IO.File]::WriteAllText((Join-Path $tmp 'src/x.ps1'),'OrchestrationExternalActionClaim')
    [IO.File]::WriteAllText((Join-Path $tmp '.hook'),'Test-OcExternalActionClaim')
    [IO.File]::WriteAllText((Join-Path $tmp 'Makefile'),'Test-OcExternalActionClaim')
    [IO.File]::WriteAllText((Join-Path $tmp 'image.png'),'Test-OcExternalActionClaim')
    [IO.File]::WriteAllText((Join-Path $tmp 'utf16.ps1'),'OrchestrationExternalActionClaim',[Text.Encoding]::Unicode)
    [IO.File]::WriteAllText((Join-Path $tmp 'utf16be.ps1'),'Test-OcExternalActionClaim',[Text.Encoding]::BigEndianUnicode)
    [IO.File]::WriteAllText((Join-Path $tmp 'hidden.ps1'),'Test-OcExternalActionClaim')
    [IO.File]::SetAttributes((Join-Path $tmp 'hidden.ps1'),[IO.FileAttributes]::Hidden)
    New-Item -ItemType Directory -Path (Join-Path $tmp 'hidden-dir') | Out-Null
    [IO.File]::SetAttributes((Join-Path $tmp 'hidden-dir'),[IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::Directory)
    [IO.File]::WriteAllText((Join-Path $tmp 'hidden-dir/x.ps1'),'Test-OcExternalActionClaim')
    foreach ($name in @('.env','.env.local','.envrc','models.jsonc','nested/models.jsonc')) {
      $p = Join-Path $tmp $name
      New-Item -ItemType Directory -Path (Split-Path $p) -Force | Out-Null
      [IO.File]::WriteAllText($p,'OrchestrationExternalActionClaim')
    }
    $script:rootPath = [IO.Path]::GetFullPath($tmp).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    $paths = @(Get-ScanFiles $tmp '' '')
    if (-not ($paths -match 'scripts[\\/]build[\\/]x\.ps1') -or ($paths -match '[\\/]cache[\\/]y\.ps1') -or -not ($paths -match 'scripts[\\/]cache[\\/]nested\.ps1') -or -not ($paths -match '[\\/]\.hook$') -or -not ($paths -match '[\\/]Makefile$') -or ($paths -match '[\\/]image\.png$')) { throw 'Scanner traversal/pruning/extension fixture failed.' }
    foreach ($name in @('hidden.ps1','hidden-dir/x.ps1','utf16.ps1','utf16be.ps1')) {
      if (-not ($paths -match [regex]::Escape($name.Replace('/','\')))) { throw "Scanner omitted fixture: $name" }
    }
    foreach ($name in @('.env','.env.local','.envrc','models.jsonc','nested/models.jsonc','node_modules/nested/x.ps1')) {
      $normalized = @($paths | ForEach-Object { (Get-RelativePathCompat $_).Replace('\','/') })
      if ($normalized -contains $name) { throw "Scanner included excluded path: $name" }
    }
    if ((Read-ScanText (Join-Path $tmp 'utf16.ps1')) -notmatch $matcher -or (Read-ScanText (Join-Path $tmp 'utf16be.ps1')) -notmatch $matcher) { throw 'UTF-16 BOM scanner fixture failed.' }
    try { Assert-NoReferences $tmp '' ''; throw 'Reference guard did not detect fixture reference.' } catch { if ($_.Exception.Message -notmatch 'Shadow claim diagnostic referenced') { throw } }
    foreach ($badBytes in @(@([byte]0xff,0xfe,0,0),@([byte]0x41,0,0x42),@([byte]0xff,0xfe,0,0,0),@([byte]0xc3,0x28))) {
      $badPath = Join-Path $tmp ('bad' + [guid]::NewGuid().ToString('N') + '.txt')
      [IO.File]::WriteAllBytes($badPath,[byte[]]$badBytes)
      $expectedError = if ($badBytes.Count -eq 2) { 'Unscannable UTF-8' } else { 'Unscannable' }
      $rejected = $false
      try { Read-ScanText $badPath | Out-Null } catch { if ($_.Exception.Message -match $expectedError) { $rejected = $true } else { throw } }
      if (-not $rejected) { throw "Fail-closed decoder did not reject fixture as $expectedError." }
    }
    $oversize = Join-Path $tmp 'oversize.txt'; [IO.File]::WriteAllText($oversize,'0123456789')
    try { Get-ScanFiles $tmp '' '' 5 | Out-Null; throw 'Scanner accepted oversize fixture.' } catch { if ($_.Exception.Message -notmatch 'configured limit') { throw } }
    $decoy = Join-Path $tmp 'elsewhere/OrchestrationExternalActionClaim.ps1'; New-Item -ItemType Directory -Path (Split-Path $decoy) | Out-Null; [IO.File]::WriteAllText($decoy,'Test-OcExternalActionClaim')
    $excluded = Join-Path $tmp 'scripts/OrchestrationExternalActionClaim.ps1'; [IO.File]::WriteAllText($excluded,'Test-OcExternalActionClaim')
    $decoyPaths = @(Get-ScanFiles $tmp $excluded $testPath)
    if ($decoyPaths -contains $excluded -or $decoyPaths -notcontains $decoy) { throw 'Exact path exclusion/same-basename decoy fixture failed.' }
    $junction = Join-Path $tmp 'junction'
    $junctionCreated = $false
    try {
      try {
        New-Item -ItemType Junction -Path $junction -Target (Join-Path $tmp 'scripts') -ErrorAction Stop | Out-Null
        $junctionCreated = $true
      } catch {
        Write-Output "SKIP junction fixture: creation failed or is unsupported: $($_.Exception.Message)"
      }
      if ($junctionCreated) {
        $junctionItem = Get-Item -LiteralPath $junction -Force
        if (($junctionItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { throw 'Junction fixture was not a reparse point.' }
        $rejected = $false
        try { Get-ScanFiles $tmp '' '' | Out-Null } catch { if ($_.Exception.Message -match 'reparse-point') { $rejected = $true } else { throw } }
        if (-not $rejected) { throw 'Scanner accepted reparse point.' }
      }
    } finally {
      if ($junctionCreated -and (Test-Path -LiteralPath $junction)) { [IO.Directory]::Delete($junction) }
      Remove-Item -LiteralPath $tmp -Recurse -Force
    }
  } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force } }
}
Assert-ScannerFixture
$script:rootPath = [IO.Path]::GetFullPath($rootItem.FullName).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
$scanTimer = [Diagnostics.Stopwatch]::StartNew()
Assert-NoReferences $rootItem.FullName $helperPath $testPath
$scanTimer.Stop()
Write-Output "Repository scan elapsed: $($scanTimer.Elapsed.TotalSeconds.ToString('F2'))s"
Write-Output "OrchestrationExternalActionClaim: PASS ($($script:results.Count) fixture results and repository static scan)"
