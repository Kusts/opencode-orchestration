[CmdletBinding()]
param(
  [string]$RepoRoot = '',
  [string]$TempBase = [IO.Path]::GetTempPath(),
  [ValidateSet('Plan','Run')][string]$Mode = 'Plan',
  [string]$Output = ''
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
. (Join-Path $RepoRoot 'scripts\runtime\lib\SpikeProcess.ps1')
. (Join-Path $RepoRoot 'scripts\runtime\lib\RuntimeVersions.ps1')
. (Join-Path $RepoRoot 'scripts\runtime\lib\OrchestrationTargetGuard.ps1')
. (Join-Path $RepoRoot 'scripts\v3\lib\PermissionRuntimeCertification.ps1')

function New-F3PermissionFixture {
  param([string]$Root, [string]$Nonce)
  $configDir = Join-Path $Root 'xdg\opencode'
  New-Item -ItemType Directory -Path $configDir -Force | Out-Null
  $tokens = [ordered]@{ allow="F3_ALLOW_$Nonce"; ask="F3_ASK_$Nonce"; deny="F3_DENY_$Nonce" }
  $config = [ordered]@{ default_agent='build'; agents=[ordered]@{ build=[ordered]@{
    mode='primary'; permissions=@(
      [ordered]@{ action='shell'; resource='echo '+$tokens.allow; effect='allow' },
      [ordered]@{ action='shell'; resource='echo '+$tokens.ask; effect='ask' },
      [ordered]@{ action='shell'; resource='git reset --hard '+$tokens.deny; effect='deny' }
    )
  } } }
  $path=Join-Path $configDir 'opencode.json'
  [IO.File]::WriteAllText($path,($config|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
  return [ordered]@{ path=$path; tokens=$tokens; commands=@(
    "echo $($tokens.allow)","echo $($tokens.ask)","git reset --hard $($tokens.deny)"
  )}
}
function Read-F3HttpBody {
  param([IO.Stream]$Stream,[int]$MaxChars)
  if ($null -eq $Stream -or $MaxChars -le 0) { return '' }
  $reader=New-Object IO.StreamReader($Stream)
  try {
    $buffer=New-Object char[] ([Math]::Min(4096,$MaxChars))
    $builder=[Text.StringBuilder]::new()
    while ($builder.Length -lt $MaxChars) {
      $count=[Math]::Min($buffer.Length,$MaxChars-$builder.Length)
      $read=$reader.Read($buffer,0,$count)
      if ($read -le 0) { break }
      [void]$builder.Append($buffer,0,$read)
    }
    return $builder.ToString()
  } finally { $reader.Dispose() }
}
function Invoke-F3Http {
  param([int]$Port,[string]$Method,[string]$Path,[string]$Body='', [string]$Password,[int]$MaxResponseChars=20000,[int]$MaxErrorChars=2000)
  if ($Path -notmatch '^/[A-Za-z0-9._/?{}-]+$') { throw 'F3_HTTP_PATH_REJECTED' }
  $request=[Net.HttpWebRequest]::Create("http://127.0.0.1:$Port$Path")
  $request.Method=$Method
  $request.ContentType='application/json'
  $request.Timeout=10000
  $request.ReadWriteTimeout=10000
  $request.AllowAutoRedirect=$false
  $pair=[Text.Encoding]::UTF8.GetBytes(('opencode:'+$Password))
  $request.Headers['Authorization']='Basic '+[Convert]::ToBase64String($pair)
  if ($Method -ne 'GET' -and $null -ne $Body) {
    $bytes=[Text.Encoding]::UTF8.GetBytes($Body)
    $request.ContentLength=$bytes.Length
    $stream=$request.GetRequestStream()
    try { $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
  }
  try {
    $response=$request.GetResponse()
    try {
      $status=[int]$response.StatusCode
      $text=Read-F3HttpBody -Stream $response.GetResponseStream() -MaxChars $(if ($status -ge 400) {$MaxErrorChars} else {$MaxResponseChars})
      $redirect=$status -ge 300 -and $status -lt 400
      $text=Protect-F3JsonSecrets -Json $text -Passwords @($Password)
      return [ordered]@{status=$status;body=$(if ($redirect) {"F3_HTTP_REDIRECT_REJECTED: $text"} else {$text});signal=$(if ($redirect) {'F3_HTTP_REDIRECT_REJECTED'} else {''})}
    } finally { $response.Dispose() }
  } catch [Net.WebException] {
    $status=-1; $text=''
    if ($_.Exception.Response) {
      $status=[int]$_.Exception.Response.StatusCode
      $text=Read-F3HttpBody -Stream $_.Exception.Response.GetResponseStream() -MaxChars $MaxErrorChars
      $_.Exception.Response.Dispose()
    } else { $text='transport error; response unavailable' }
    $text=Protect-F3JsonSecrets -Json $text -Passwords @($Password)
    return [ordered]@{status=$status;body=$text;signal=$(if ($status -ge 300 -and $status -lt 400) {'F3_HTTP_REDIRECT_REJECTED'} else {''})}
  }
}
function Write-F3Json {
  param($Data,[string]$Path)
  $json=Protect-F3JsonSecrets -Json (($Data|ConvertTo-Json -Depth 12)+"`n") -Passwords $script:F3SensitiveValues
  if ([string]::IsNullOrWhiteSpace($Path)) { $json; return }
  $full=[IO.Path]::GetFullPath($Path)
  Assert-OrchestrationMutatingTargetAllowed -TargetPath $full -ExplicitTargetProvided $true -OptIn $false
  $parent=Split-Path -Parent $full
  if ($parent) { New-Item -ItemType Directory -Path $parent -Force|Out-Null }
  [IO.File]::WriteAllText($full,$json,[Text.UTF8Encoding]::new($false))
}

$script:F3SensitiveValues=@()
$tempFull=[IO.Path]::GetFullPath($TempBase)
$allowed=@([IO.Path]::GetTempPath(),$env:TEMP,$env:TMP)|Where-Object { $_ }|ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') }
if (-not (@($allowed|Where-Object { $tempFull.Equals($_,[StringComparison]::OrdinalIgnoreCase) -or $tempFull.StartsWith($_+'\',[StringComparison]::OrdinalIgnoreCase) }).Count)) {
  throw 'F3_TEMPBASE_OUTSIDE_TEMP'
}
if ($Mode -eq 'Run' -and (-not $env:F3_PERMISSION_RUN_OPT_IN -or $env:F3_PERMISSION_RUN_OPT_IN -cne '1')) {
  throw 'F3_RUN_REQUIRES_F3_PERMISSION_RUN_OPT_IN=1'
}
$runRoot=Join-Path $tempFull ('f3-permissions-'+[guid]::NewGuid().ToString('N'))
Assert-OrchestrationMutatingTargetAllowed -TargetPath $runRoot -ExplicitTargetProvided $true -OptIn $false
$nonce=[guid]::NewGuid().ToString('N')
$fixture=New-F3PermissionFixture -Root $runRoot -Nonce $nonce
$version=[string](Get-OrchestrationRuntimeVersion -Name v2 -RepoRoot $RepoRoot).Version
$plan=[ordered]@{ task_id='OM-F3-CERT'; mode=$Mode; status='PLAN'; pinned_version=$version; fixture=$fixture; paths=@(
  [ordered]@{ path=$fixture.path; sha256=(Get-FileHash $fixture.path -Algorithm SHA256).Hash.ToLowerInvariant() }
); cases=@(
  [ordered]@{name='allow';command=$fixture.commands[0];classification='unverified'},
  [ordered]@{name='ask';command=$fixture.commands[1];classification='HOLD_PENDING_OBSERVABLE_DECISION'},
  [ordered]@{name='deny';command=$fixture.commands[2];classification='unverified'}
); endpoints=@(); limitations=@('shell API nao equivale necessariamente a tool-permission interativa','precedencia e composicao nao certificadas') }
if ($Mode -eq 'Plan') { Write-F3Json $plan $Output; return }

$active=@(
  (Join-Path $env:USERPROFILE '.config\opencode\opencode.json'),
  (Join-Path $env:USERPROFILE '.config\opencode\AGENTS.md'),
  (Join-Path $env:USERPROFILE '.opencode-orchestration\profiles\v2\manifest.json')
)
$baseline=Join-Path $runRoot 'active-baseline.json'
$assert=Join-Path $RepoRoot 'scripts\v3\assert-active-paths-unchanged.ps1'
$result=Copy-F3PlanForRun $plan
$result.mode='Run'; $result.status='HOLD'; $result.cases=@()
$result.failure=$null; $result.failure_type=$null; $result.diagnostics=@()
$binary=(Get-Command opencode -ErrorAction SilentlyContinue).Source
$serviceStarted=$false; $port=0; $isolated=$false; $warm=$false; $captured=$false; $verifyExit=1; $postFailure=$false
$envSet=@{ XDG_CONFIG_HOME=(Split-Path (Split-Path $fixture.path -Parent) -Parent); XDG_DATA_HOME=(Join-Path $runRoot 'data'); XDG_STATE_HOME=(Join-Path $runRoot 'state'); XDG_CACHE_HOME=(Join-Path $runRoot 'cache'); HOME=(Join-Path $runRoot 'home'); USERPROFILE=(Join-Path $runRoot 'home') }
$envRemove=@('OPENCODE_CONFIG','OPENCODE_CONFIG_DIR','OPENCODE_CONFIG_FILE','OPENCODE_CONFIG_CONTENT')
$envSet.OPENCODE_PASSWORD=[guid]::NewGuid().ToString('N')
$script:F3SensitiveValues+= [string]$envSet.OPENCODE_PASSWORD
$result.password_present_before_warmup=$true
$sessionRepo=Join-Path $runRoot 'session-repo'
try {
  & $assert -Mode Capture -Output $baseline -Paths $active
  $captured=$true
  foreach ($dir in @($envSet.XDG_DATA_HOME,$envSet.XDG_STATE_HOME,$envSet.XDG_CACHE_HOME,$envSet.HOME)) { New-Item -ItemType Directory -Path $dir -Force|Out-Null }
  New-Item -ItemType Directory -Path $sessionRepo -Force|Out-Null
  $git=Get-Command git -ErrorAction SilentlyContinue
  if (-not $git) { throw 'SESSION_DIRECTORY_UNPROVEN' }
  $g=& $git.Source -C $sessionRepo init --quiet 2>&1
  if ($LASTEXITCODE -ne 0) { throw 'SESSION_DIRECTORY_UNPROVEN' }
  Assert-F3SessionDirectory -Directory $sessionRepo -RunRoot $runRoot
  Assert-F3PasswordPresent -Environment $envSet
  if (-not $binary) { throw 'F3_V2_BINARY_UNAVAILABLE' }
  $ver=Invoke-SpikeChild -FilePath $binary -ArgumentList @('--version') -EnvSet $envSet -EnvRemove $envRemove -WorkingDirectory $runRoot -CleanEnvironment -StdinNul
  if (-not (Test-SpikeExactVersion -Text ($ver.Stdout+"`n"+$ver.Stderr) -Version $version)) { throw 'F3_VERSION_MISMATCH' }
  $paths=Invoke-SpikeChild -FilePath $binary -ArgumentList @('debug','paths') -EnvSet $envSet -EnvRemove $envRemove -WorkingDirectory $runRoot -CleanEnvironment -StdinNul
  $isolated=($paths.ExitCode -eq 0 -and (($paths.Stdout+$paths.Stderr).Contains('xdg')))
  if (-not $isolated) { throw 'F3_ISOLATION_UNPROVEN' }
  $before=Invoke-SpikeChild -FilePath $binary -ArgumentList @('service','status') -EnvSet $envSet -EnvRemove $envRemove -WorkingDirectory $runRoot -CleanEnvironment -StdinNul
  $beforeText=([string]$before.Stdout+"`n"+[string]$before.Stderr).Trim()
  $result.service_status_before=[ordered]@{exit=[int]$before.ExitCode;text=$beforeText}
  Assert-F3ServiceInactive -ExitCode ([int]$before.ExitCode) -Text $beforeText
  $port=Get-SpikeFreePort
  $set=Invoke-SpikeChild -FilePath $binary -ArgumentList @('service','set','port',"$port") -EnvSet $envSet -EnvRemove $envRemove -WorkingDirectory $runRoot -CleanEnvironment -StdinNul
  if ($set.ExitCode -ne 0) { throw 'F3_PRIVATE_SERVICE_PORT_FAILED' }
  $warm=$true
  Assert-F3PasswordPresent -Environment $envSet
  $cfg=Invoke-SpikeChild -FilePath $binary -ArgumentList @('debug','config') -EnvSet $envSet -EnvRemove $envRemove -WorkingDirectory $runRoot -CleanEnvironment -StdinNul
  if ($cfg.ExitCode -ne 0) { throw 'F3_PRIVATE_SERVICE_WARMUP_FAILED' }
  $serviceStarted=$true
  $serviceAuthPath=Join-Path $envSet.XDG_CONFIG_HOME 'opencode\service.json'
  $serviceAuth=Get-F3ServiceAuth -Path $serviceAuthPath -ExpectedPort $port
  $httpPassword=[string]$serviceAuth.password
  $script:F3SensitiveValues+= $httpPassword
  $result.diagnostics+= [ordered]@{ service_auth_source='isolated_service_json'; password_present=$true; port_match=[bool]$serviceAuth.port_match }
  Assert-F3ServiceAuthPort -ServiceAuth $serviceAuth
  $apiPort=$port
  $api=Invoke-F3Http -Port $apiPort -Method GET -Path '/openapi.json' -Password $httpPassword -MaxResponseChars 500000
  $result.diagnostics+= [ordered]@{ name='openapi_status'; status=[int]$api.status }
  $spec=$null
  if ($api.status -ge 200 -and $api.status -lt 300) {
    try { $spec=($api.body|ConvertFrom-Json) }
    catch {
      $openapiTruncated=([string]$api.body).Length -ge 500000
      $result.diagnostics+= [ordered]@{
        name='openapi_parse'; openapi_parse_failed=$true; openapi_truncated=$openapiTruncated
        signal='OPENAPI_SPEC_PARSE_FAILED'
      }
    }
  }
  $result.endpoints=@()
  if ($spec) { $result.endpoints=@($spec.paths.PSObject.Properties.Name|Where-Object { $_ -match 'permission|event' }) }
  $specPaths=if ($spec -and $spec.paths) { @($spec.paths.PSObject.Properties.Name) } else { @() }
  $hasSessionPermissionEndpoint=@($specPaths|Where-Object { $_ -match '(?i)/session/\{sessionID\}/permission$' }).Count -gt 0
  $hasEventEndpoint=@($specPaths|Where-Object { $_ -match '(?i)/event$' }).Count -gt 0
  $caseCount=if ($null -eq $plan.cases) { 0 } else { @($plan.cases).Count }
  $result.diagnostics+= [ordered]@{ name='plan_cases'; count=$caseCount; is_null=($null -eq $plan.cases); is_empty=($caseCount -eq 0) }
  if ($null -eq $plan.cases -or $caseCount -eq 0) { throw 'F3_PLAN_CASES_MISSING' }
  foreach ($case in $plan.cases) {
    $sessionPayload=@{directory=$sessionRepo}|ConvertTo-Json -Compress
    $sessionCall=Invoke-F3Http -Port $apiPort -Method POST -Path '/api/session' -Body $sessionPayload -Password $httpPassword
    $sid=''
    if ($sessionCall.status -ge 200 -and $sessionCall.status -lt 300) {
      try { $sessionJson=$sessionCall.body|ConvertFrom-Json; $sessionNode=$sessionJson.data; if (-not $sessionNode) {$sessionNode=$sessionJson}; $sid=[string]$sessionNode.id } catch {}
    }
    if (-not ($sessionCall.status -ge 200 -and $sessionCall.status -lt 300) -or $sid -notmatch '^[A-Za-z0-9._-]{4,128}$') {
      $stage=if ($sessionCall.status -lt 200 -or $sessionCall.status -ge 300) { 'POST /api/session' } else { 'POST /api/session invalid response' }
      $result.cases+= (New-F3FailedHttpCase -Case $case -SessionId '' -SessionDirectory $sessionRepo -Stage $stage -Status ([int]$sessionCall.status) -Text ([string]$sessionCall.body) -Password $httpPassword)
      continue
    }
    $commandBody=(@{command=[string]$case.command}|ConvertTo-Json -Compress)
    $repoFingerprintBefore=if ($case.name -eq 'deny') { Get-F3SessionRepoFingerprint -Directory $sessionRepo } else { '' }
    $shellCall=$null
    if ($sid -match '^[A-Za-z0-9._-]{4,128}$') {
      $shellCall=Invoke-F3Http -Port $apiPort -Method POST -Path "/api/session/$sid/shell" -Body $commandBody -Password $httpPassword
    }
    if (-not $shellCall) {
      $status=if ($shellCall) { [int]$shellCall.status } else { -1 }
      $text=if ($shellCall) { [string]$shellCall.body } else { 'shell request was not issued' }
      $result.cases+= (New-F3FailedHttpCase -Case $case -SessionId $sid -SessionDirectory $sessionRepo -Stage 'POST /api/session/{id}/shell' -Status $status -Text $text -Password $httpPassword)
      continue
    }
    $response=[string]$shellCall.body
    $exit=[int]$shellCall.status
    $shellHttpOk=Test-F3HttpSuccess -Status $exit
    $repoFingerprintAfter=if ($case.name -eq 'deny') { Get-F3SessionRepoFingerprint -Directory $sessionRepo } else { '' }
    $permissionBody=''
    if ($hasSessionPermissionEndpoint) {
      $permissionCall=Invoke-F3Http -Port $apiPort -Method GET -Path "/api/session/$sid/permission" -Password $httpPassword
      $permissionBody=[string]$permissionCall.body
    }
    $eventBody=''
    if ($hasEventEndpoint) {
      $eventCall=Invoke-F3Http -Port $apiPort -Method GET -Path '/api/event' -Password $httpPassword -MaxResponseChars 12000
      $eventBody=[string]$eventCall.body
    }
    $permissionEvents=Get-F3PermissionEventRecords -PermissionBody $permissionBody -EventBody $eventBody -SessionId $sid -Passwords $script:F3SensitiveValues
    $observedToken=$false
    $token=[string]$fixture.tokens[$case.name]
    if ($token) { $observedToken=($response -match [regex]::Escape($token)) }
    $commandEffectObserved=($case.name -eq 'deny' -and $repoFingerprintBefore -cne $repoFingerprintAfter)
    $decision=Get-F3PermissionCaseDecision -CaseName $case.name -HttpOk $shellHttpOk -PermissionEvents $permissionEvents -CommandEffectObserved $commandEffectObserved
    $classification=$decision.classification; $signal=$decision.signal
    $safeResponse=Protect-F3JsonSecrets -Json $response -Passwords $script:F3SensitiveValues
    $result.cases+= [ordered]@{ name=$case.name; command=$case.command; session_id=$sid; session_directory=$sessionRepo; classification=$classification; command_token_observed=$observedToken; command_effect_observed=$commandEffectObserved; signal=$signal; http_status=$exit; shell_http_ok=$shellHttpOk; exit=$exit; permission_events=$permissionEvents; response=($safeResponse.Substring(0,[Math]::Min(2000,$safeResponse.Length))) }
  }
} catch {
  $postFailure=$true; $result.status='HOLD'; $result.failure=Protect-F3JsonSecrets -Json ([string]$_.Exception.Message) -Passwords $script:F3SensitiveValues; $result.failure_type=$_.Exception.GetType().FullName
} finally {
  try {
    if ($serviceStarted -or $warm) {
      try {
        $stop=Invoke-SpikeServiceStopIfOwned -FilePath $binary -EnvSet $envSet -EnvRemove $envRemove -WorkingDirectory $runRoot -IsolationProved $isolated -PortConfigured ($port -gt 0) -Port $port -WarmupAttempted $warm -CleanEnvironment -StdinNul
        $result.service_stop=$stop
        if (-not $stop.Stopped) { $postFailure=$true }
        $after=Invoke-SpikeChild -FilePath $binary -ArgumentList @('service','status') -EnvSet $envSet -EnvRemove $envRemove -WorkingDirectory $runRoot -CleanEnvironment -StdinNul
        $afterText=([string]$after.Stdout+"`n"+[string]$after.Stderr).Trim()
        $result.service_status_after=[ordered]@{exit=[int]$after.ExitCode;text=$afterText}
        Assert-F3PostRun -VerifyExit 0 -StopSucceeded ([bool]$stop.Stopped) -PostStatusExit ([int]$after.ExitCode) -PostStatusText $afterText
      } catch { $postFailure=$true; $result.post_service_gate=$_.Exception.Message }
    }
  } finally {
    if ($captured) {
      try {
        & $assert -Mode Verify -BaselinePath $baseline
        $verifyExit=$LASTEXITCODE
      } catch { $verifyExit=1; $result.verify_error=$_.Exception.Message }
      if ($verifyExit -ne 0) { $postFailure=$true; $result.failure='ACTIVE_PATH_CHANGED' }
    }
  }
}
$caseFailed=@($result.cases|Where-Object { $_.classification -ceq 'FAIL' }).Count -gt 0
$result.status=Get-F3AggregateStatus -Cases $result.cases -VerifyExit $verifyExit -PostGateFailed $postFailure
Write-F3Json $result $Output
if ((Get-F3RunExitCode -VerifyExit $verifyExit -PostGateFailed $postFailure -CaseFailed $caseFailed) -ne 0) { exit 1 }
