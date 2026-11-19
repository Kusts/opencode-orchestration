function Get-F3AskClassification {
  param($Evidence)
  if ($null -eq $Evidence -or [string]::IsNullOrWhiteSpace([string]$Evidence.source) -or [string]::IsNullOrWhiteSpace([string]$Evidence.decision_id)) {
    return [ordered]@{ status='HOLD'; signal='approval event source and decision identifier are required' }
  }
  return [ordered]@{ status='PASS'; signal=([string]$Evidence.source+':'+[string]$Evidence.decision_id) }
}
function Test-F3ServiceInactive {
  param([int]$ExitCode,[string]$Text)
  $status=([string]$Text).Trim()
  $explicitInactive=$status -match '(?i)^(?:not running|no service|service is stopped|not started)$'
  $stopped=$status -ieq 'stopped'
  return (($ExitCode -eq 0 -and ($explicitInactive -or $stopped)) -or ($ExitCode -ne 0 -and $explicitInactive))
}
function Assert-F3ServiceInactive {
  param([int]$ExitCode,[string]$Text)
  if (-not (Test-F3ServiceInactive -ExitCode $ExitCode -Text $Text)) { throw 'SERVICE_ISOLATION_UNPROVEN' }
}
function Assert-F3PasswordPresent {
  param([hashtable]$Environment)
  if (-not $Environment.ContainsKey('OPENCODE_PASSWORD') -or [string]::IsNullOrWhiteSpace([string]$Environment.OPENCODE_PASSWORD)) { throw 'F3_PASSWORD_MISSING_BEFORE_WARMUP' }
}
function Assert-F3SessionDirectory {
  param([string]$Directory,[string]$RunRoot)
  if ([string]::IsNullOrWhiteSpace($Directory) -or -not (Test-Path -LiteralPath $Directory -PathType Container)) { throw 'SESSION_DIRECTORY_UNPROVEN' }
  $full=[IO.Path]::GetFullPath($Directory); $root=([IO.Path]::GetFullPath($RunRoot).TrimEnd('\')+'\')
  if (-not $full.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path (Join-Path $full '.git'))) { throw 'SESSION_DIRECTORY_UNPROVEN' }
}
function Assert-F3PostRun {
  param([int]$VerifyExit,[bool]$StopSucceeded,[int]$PostStatusExit,[string]$PostStatusText)
  if ($VerifyExit -ne 0) { throw 'ACTIVE_PATH_CHANGED' }
  if (-not $StopSucceeded -or -not (Test-F3ServiceInactive -ExitCode $PostStatusExit -Text $PostStatusText)) { throw 'F3_POST_RUN_SERVICE_STATE_UNPROVEN' }
}
function Get-F3RunExitCode {
  param([int]$VerifyExit,[bool]$PostGateFailed,[bool]$CaseFailed=$false)
  if ($VerifyExit -ne 0 -or $PostGateFailed -or $CaseFailed) { return 1 }
  return 0
}
function Get-F3AggregateStatus {
  param($Cases,[int]$VerifyExit=0,[bool]$PostGateFailed=$false)
  if ($VerifyExit -ne 0 -or $PostGateFailed -or @($Cases|Where-Object { $_.classification -ceq 'FAIL' }).Count -gt 0) { return 'FAIL' }
  return 'HOLD'
}
function New-F3FailedHttpCase {
  param($Case,[string]$SessionId,[string]$SessionDirectory,[string]$Stage,[int]$Status,[string]$Text,[string]$Password='')
  $safeText=[string]$Text
  if (-not [string]::IsNullOrEmpty($Password)) { $safeText=$safeText.Replace($Password,'[REDACTED]') }
  $safeText=$safeText.Trim()
  if ($safeText.Length -gt 500) { $safeText=$safeText.Substring(0,500) }
  $detail=if ($safeText) { $safeText } else { 'no response text' }
  return [ordered]@{
    name=[string]$Case.name; command=[string]$Case.command; session_id=$SessionId
    session_directory=$SessionDirectory; classification='HOLD'; command_token_observed=$false
    signal="$Stage HTTP request failed (status=$Status): $detail"; exit=-1; response=$detail
  }
}
function Copy-F3PlanForRun {
  param($Plan)
  $copy=[ordered]@{}
  foreach ($key in $Plan.Keys) { $copy[$key]=$Plan[$key] }
  return $copy
}
function Get-F3ServiceAuth {
  param([string]$Path,[int]$ExpectedPort)
  try {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'missing' }
    $service=Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $password=[string]$service.password
    if ([string]::IsNullOrWhiteSpace($password)) { throw 'missing password' }
    return [ordered]@{ password=$password; password_present=$true; port_match=($service.port -eq $ExpectedPort) }
  } catch {
    throw 'F3_SERVICE_AUTH_UNPROVEN'
  }
}
function Assert-F3ServiceAuthPort {
  param($ServiceAuth)
  if (-not $ServiceAuth.port_match) { throw 'F3_SERVICE_AUTH_UNPROVEN' }
}
function Protect-F3JsonSecrets {
  param([string]$Json,[string[]]$Passwords=@())
  foreach ($password in $Passwords) {
    if (-not [string]::IsNullOrEmpty($password)) { $Json=$Json.Replace($password,'[REDACTED]') }
  }
  return $Json
}
function Test-F3HttpSuccess {
  param([int]$Status)
  return ($Status -ge 200 -and $Status -lt 300)
}
function Get-F3EventNodes {
  param($Value,[int]$Depth=0)
  if ($null -eq $Value -or $Depth -gt 8) { return }
  if ($Value -is [System.Array]) {
    foreach ($item in @($Value | Select-Object -First 100)) { Get-F3EventNodes -Value $item -Depth ($Depth+1) }
    return
  }
  if ($Value -is [string] -or $Value.GetType().IsValueType) { return }
  $props=@($Value.PSObject.Properties)
  if (@($props.Name | Where-Object { $_ -in @('type','event','permission','reply','decision','status','state','requestID','sessionID') }).Count -gt 0) { Write-Output -NoEnumerate $Value }
  foreach ($property in $props) { Get-F3EventNodes -Value $property.Value -Depth ($Depth+1) }
}
function ConvertFrom-F3EventPayload {
  param([string]$Body)
  $nodes=[System.Collections.Generic.List[object]]::new()
  if ([string]::IsNullOrWhiteSpace($Body)) { return ,$nodes.ToArray() }
  try {
    $parsed=ConvertFrom-Json -InputObject $Body -ErrorAction Stop
    foreach ($node in @(Get-F3EventNodes -Value $parsed)) { $nodes.Add($node) }
    return ,$nodes.ToArray()
  } catch {}
  foreach ($line in ($Body -split "`r?`n")) {
    if ($line -match '^data:\s*(.+)$') {
      try {
        $parsed=ConvertFrom-Json -InputObject $Matches[1] -ErrorAction Stop
        foreach ($node in @(Get-F3EventNodes -Value $parsed)) { $nodes.Add($node) }
      } catch {}
    }
  }
  return ,$nodes.ToArray()
}
function Get-F3PermissionEventRecords {
  param([string]$PermissionBody,[string]$EventBody,[string]$SessionId,[string[]]$Passwords=@())
  $records=[System.Collections.Generic.List[object]]::new()
  $sources=@(
    [ordered]@{ name='/api/session/{sessionID}/permission'; body=$PermissionBody; session_scoped=$true },
    [ordered]@{ name='/api/event'; body=$EventBody; session_scoped=$false }
  )
  foreach ($source in $sources) {
    foreach ($node in (ConvertFrom-F3EventPayload -Body ([string]$source.body))) {
      $session=[string]$node.sessionID
      if (-not $session) { $session=[string]$node.session_id }
      if (-not $source.session_scoped -and $session -cne $SessionId) { continue }
      $type=''
      if ($node.type -is [string]) { $type=[string]$node.type }
      if (-not $type -and $node.event -is [string]) { $type=[string]$node.event }
      $state=[string]$node.reply
      foreach ($field in @('decision','status','state')) { if (-not $state -and $node.$field) { $state=[string]$node.$field } }
      $id=[string]$node.id
      foreach ($field in @('requestID','permissionID')) { if (-not $id -and $node.$field) { $id=[string]$node.$field } }
      if ($type.Length -gt 256) { $type=$type.Substring(0,256) }
      if ($state.Length -gt 256) { $state=$state.Substring(0,256) }
      if ($id.Length -gt 256) { $id=$id.Substring(0,256) }
      if (-not ($type -match '(?i)permission' -or $node.permission -or $state)) { continue }
      $record=[ordered]@{ source=[string]$source.name; type=$type; state=$state; id=$id }
      $json=Protect-F3JsonSecrets -Json ($record|ConvertTo-Json -Compress) -Passwords $Passwords
      if ($records.Count -lt 5 -and -not (@($records|Where-Object { $_.json -ceq $json }).Count)) {
        $records.Add([pscustomobject]@{ json=$json; record=($json|ConvertFrom-Json) })
      }
    }
  }
  return ,@($records | ForEach-Object { $_.record })
}
function Get-F3PermissionCaseDecision {
  param([string]$CaseName,[bool]$HttpOk,$PermissionEvents,[bool]$CommandEffectObserved=$false)
  if ($CaseName -eq 'deny' -and $CommandEffectObserved) {
    return [ordered]@{classification='FAIL';signal='Repository state changed during the deny case; command effect observed despite the deny rule.'}
  }
  foreach ($event in @($PermissionEvents)) {
    $state=([string]$event.state+' '+[string]$event.type).Trim()
    if ($CaseName -eq 'ask' -and $state -match '(?i)(approved|allow|once|always|reject|denied)') {
      $decision=Get-F3AskClassification ([pscustomobject]@{source=[string]$event.source;decision_id=[string]$event.id})
      if ($decision.status -eq 'PASS') { return [ordered]@{classification='PASS';signal=$decision.signal} }
    }
    if ($CaseName -eq 'allow' -and $HttpOk -and $state -match '(?i)(approved|allow|once|always)') {
      return [ordered]@{classification='PASS';signal="Observed allow decision at $($event.source), event $($event.id)."}
    }
    if ($CaseName -eq 'deny' -and $state -match '(?i)(reject|denied|permission\.denied)') {
      return [ordered]@{classification='PASS';signal="Observed denial at $($event.source), event $($event.id)."}
    }
  }
  if (-not $HttpOk) { return [ordered]@{classification='HOLD';signal='Shell HTTP request did not succeed and no conclusive permission decision was observed.'} }
  if ($CaseName -eq 'ask' -and @($PermissionEvents).Count -gt 0) { return [ordered]@{classification='HOLD';signal='Permission request/event is observable, but no decision event was observed.'} }
  return [ordered]@{classification='HOLD';signal='No explicit permission-decision event observed; HTTP success or command output alone is insufficient evidence.'}
}
function Get-F3SessionRepoFingerprint {
  param([string]$Directory)
  $root=[IO.Path]::GetFullPath($Directory).TrimEnd('\')
  $items=@(Get-ChildItem -LiteralPath $root -File -Force -Recurse -ErrorAction Stop | Sort-Object FullName)
  $lines=foreach ($item in $items) {
    $relative=$item.FullName.Substring($root.Length).TrimStart('\')
    "$relative=$((Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash)"
  }
  $bytes=[Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
  return [Convert]::ToBase64String([Security.Cryptography.SHA256]::Create().ComputeHash($bytes))
}
