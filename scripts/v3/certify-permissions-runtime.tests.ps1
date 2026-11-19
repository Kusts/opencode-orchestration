$ErrorActionPreference='Stop'
$repo=Resolve-Path (Join-Path $PSScriptRoot '..\..')
$scriptPath=Join-Path $PSScriptRoot 'certify-permissions-runtime.ps1'
. (Join-Path $PSScriptRoot 'lib\PermissionRuntimeCertification.ps1')
$count=0; $failed=0
function Check($ok,$name) { $script:count++; if ($ok) { Write-Host "[PASS] $name" } else { Write-Host "[FAIL] $name"; $script:failed++ } }
$base=[IO.Path]::GetTempPath()
$out=Join-Path $base ('f3-plan-test-'+[guid]::NewGuid().ToString('N')+'.json')
$authFile=Join-Path $base ('f3-service-auth-'+[guid]::NewGuid().ToString('N')+'.json')
$plan=$null
$runRoot=$null
try {
  & $scriptPath -RepoRoot $repo -TempBase $base -Mode Plan -Output $out
  $plan=Get-Content $out -Raw|ConvertFrom-Json
  $runPlan=Copy-F3PlanForRun $plan
  $runPlan.cases=@()
  Check (@($plan.cases).Count -eq 3 -and @($runPlan.cases).Count -eq 0) 'Run result case initialization preserves plan cases'
  $tokens=$null; $parseErrors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
  $httpFunctions=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in @('Read-F3HttpBody','Invoke-F3Http')},$true))
  foreach ($functionAst in $httpFunctions) { Invoke-Expression $functionAst.Extent.Text }
  $httpSource=[IO.File]::ReadAllText($scriptPath)
  Check ($httpSource -match '\$request\.AllowAutoRedirect=\$false' -and $httpSource -match 'F3_HTTP_REDIRECT_REJECTED') 'HTTP client disables and explicitly rejects redirects'
  Check ($httpSource -notmatch 'ReadToEnd\(' -and $httpSource -match 'while \(\$builder\.Length -lt \$MaxChars\)') 'all HTTP streams use bounded reads'
  Check ($httpSource -match 'Invoke-F3Http -Port \$apiPort -Method GET -Path ''/openapi\.json'' -Password \$httpPassword -MaxResponseChars 500000') 'OpenAPI request uses an explicit 500000-character cap'
  Check ($httpSource -match 'openapi_parse_failed=\$true' -and $httpSource -match 'openapi_truncated=\$openapiTruncated' -and $httpSource -match 'OPENAPI_SPEC_PARSE_FAILED') 'OpenAPI parse failure and truncation are diagnosed explicitly'
  $casesForStatus=@([pscustomobject]@{classification='HOLD'},[pscustomobject]@{classification='FAIL'})
  Check ((Get-F3AggregateStatus -Cases $casesForStatus) -ceq 'FAIL' -and (Get-F3RunExitCode -VerifyExit 0 -PostGateFailed $false -CaseFailed $true) -eq 1) 'FAIL case propagates to aggregate status and nonzero exit'
  Check ((Get-F3AggregateStatus -Cases @([pscustomobject]@{classification='HOLD'})) -ceq 'HOLD') 'all HOLD cases preserve aggregate HOLD'
  $config=Get-Content $plan.fixture.path -Raw|ConvertFrom-Json
  $rules=@($config.agents.build.permissions)
  Check ($rules.Count -eq 3 -and $rules[0].resource -ceq ('echo '+$plan.fixture.tokens.allow) -and $rules[1].resource -ceq ('echo '+$plan.fixture.tokens.ask) -and $rules[2].resource -ceq ('git reset --hard '+$plan.fixture.tokens.deny)) 'permission rules use exact unique command resources'
  Check ([IO.Path]::GetFullPath($plan.fixture.path).StartsWith([IO.Path]::GetFullPath($base),[StringComparison]::OrdinalIgnoreCase)) 'Plan writes fixture only under TEMP'
  $rejected=$false
  try { & $scriptPath -RepoRoot $repo -TempBase $repo -Mode Plan -Output $out } catch { $rejected=($_.Exception.Message -match 'F3_TEMPBASE_OUTSIDE_TEMP') }
  Check $rejected 'TempBase outside TEMP rejected'
  $fake=Get-F3AskClassification $null
  $rawBool=Get-F3AskClassification $true
  $validEvidence=Get-F3AskClassification ([pscustomobject]@{source='event-stream';decision_id='decision-1'})
  Check ($fake.status -ceq 'HOLD' -and $rawBool.status -ceq 'HOLD' -and $validEvidence.status -ceq 'PASS') 'ask PASS requires event source and decision id'
  Check (Test-F3HttpSuccess -Status 204) 'HTTP 204 is a successful shell request'
  $askEvent=[pscustomobject]@{source='/api/event';id='decision-ask-1';state='once';type='permission.replied'}
  $askDecision=Get-F3PermissionCaseDecision -CaseName ask -HttpOk $true -PermissionEvents @($askEvent)
  Check ($askDecision.classification -ceq 'PASS') 'real ask decision event produces PASS'
  $askPending=Get-F3PermissionCaseDecision -CaseName ask -HttpOk $true -PermissionEvents @()
  Check ($askPending.classification -ceq 'HOLD') 'ask without event remains HOLD'
  $allowDecision=Get-F3PermissionCaseDecision -CaseName allow -HttpOk $true -PermissionEvents @([pscustomobject]@{source='/api/event';id='decision-allow-1';state='approved';type='permission.replied'})
  Check ($allowDecision.classification -ceq 'PASS') 'explicit allow event produces PASS'
  $allowMissing=Get-F3PermissionCaseDecision -CaseName allow -HttpOk $true -PermissionEvents @()
  $denyMissing=Get-F3PermissionCaseDecision -CaseName deny -HttpOk $true -PermissionEvents @()
  Check ($allowMissing.classification -ceq 'HOLD' -and $denyMissing.classification -ceq 'HOLD') 'allow and deny without decision events remain HOLD'
  $deniedEvent=Get-F3PermissionCaseDecision -CaseName deny -HttpOk $true -PermissionEvents @([pscustomobject]@{source='/api/event';id='decision-deny-1';state='reject';type='permission.replied'})
  Check ($deniedEvent.classification -ceq 'PASS') 'explicit deny event produces PASS'
  $denyEffect=Get-F3PermissionCaseDecision -CaseName deny -HttpOk $true -PermissionEvents @([pscustomobject]@{source='/api/event';id='decision-allow-1';state='allow';type='permission.replied'}) -CommandEffectObserved $true
  Check ($denyEffect.classification -ceq 'FAIL') 'deny rule with observed allow and command effect fails'
  $repoProbe=Join-Path $base ('f3-effect-'+[guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $repoProbe -Force|Out-Null
  $probeFile=Join-Path $repoProbe 'state.txt'
  [IO.File]::WriteAllText($probeFile,'before',[Text.UTF8Encoding]::new($false))
  $fingerprintBefore=Get-F3SessionRepoFingerprint -Directory $repoProbe
  [IO.File]::WriteAllText($probeFile,'after',[Text.UTF8Encoding]::new($false))
  $fingerprintAfter=Get-F3SessionRepoFingerprint -Directory $repoProbe
  Check ($fingerprintBefore -cne $fingerprintAfter) 'deny effect fingerprint detects session repo state changes'
  Remove-Item $repoProbe -Recurse -Force
  $serviceRejected=$false
  try { Assert-F3ServiceInactive -ExitCode 0 -Text 'server running at 127.0.0.1:49374' } catch { $serviceRejected=($_.Exception.Message -eq 'SERVICE_ISOLATION_UNPROVEN') }
  Check $serviceRejected 'active/unproven service status aborts before startup'
  $stoppedAccepted=$true
  try { Assert-F3ServiceInactive -ExitCode 0 -Text ' StOpPeD ' } catch { $stoppedAccepted=$false }
  Check $stoppedAccepted 'exit 0 with normalized stopped status is inactive'
  foreach ($unprovenStatus in @('running','')) {
    $statusRejected=$false
    try { Assert-F3ServiceInactive -ExitCode 0 -Text $unprovenStatus } catch { $statusRejected=($_.Exception.Message -eq 'SERVICE_ISOLATION_UNPROVEN') }
    Check $statusRejected "exit 0 with '$unprovenStatus' remains unproven"
  }
  $nonzeroAccepted=$true
  try { Assert-F3ServiceInactive -ExitCode 1 -Text 'not running' } catch { $nonzeroAccepted=$false }
  Check $nonzeroAccepted 'nonzero exit with explicit not running status remains inactive'
  $ambiguousRejected=$false
  try { Assert-F3ServiceInactive -ExitCode 0 -Text 'service is stopped but service at 127.0.0.1:1234' } catch { $ambiguousRejected=($_.Exception.Message -eq 'SERVICE_ISOLATION_UNPROVEN') }
  Check $ambiguousRejected 'ambiguous text containing stopped phrase is rejected'
  $postStoppedAccepted=$true
  try { Assert-F3PostRun -VerifyExit 0 -StopSucceeded $true -PostStatusExit 0 -PostStatusText ' StOpPeD ' } catch { $postStoppedAccepted=$false }
  Check $postStoppedAccepted 'post-run exit 0 with normalized stopped status is inactive'
  foreach ($postUnprovenStatus in @('running','')) {
    $postStatusRejected=$false
    try { Assert-F3PostRun -VerifyExit 0 -StopSucceeded $true -PostStatusExit 0 -PostStatusText $postUnprovenStatus } catch { $postStatusRejected=($_.Exception.Message -eq 'F3_POST_RUN_SERVICE_STATE_UNPROVEN') }
    Check $postStatusRejected "post-run exit 0 with '$postUnprovenStatus' remains unproven"
  }
  $postNonzeroAccepted=$true
  try { Assert-F3PostRun -VerifyExit 0 -StopSucceeded $true -PostStatusExit 1 -PostStatusText 'not running' } catch { $postNonzeroAccepted=$false }
  Check $postNonzeroAccepted 'post-run nonzero exit with explicit not running status remains inactive'
  $failedCase=New-F3FailedHttpCase -Case ([pscustomobject]@{name='allow';command='echo TOKEN'}) -SessionId '' -SessionDirectory 'temp/session' -Stage 'POST /api/session' -Status 500 -Text 'request failed' -Password 'secret'
  Check ($failedCase.classification -ceq 'HOLD' -and $failedCase.exit -eq -1 -and $failedCase.signal -match 'status=500' -and $failedCase.response -eq 'request failed') 'failed session HTTP response produces an explicit HOLD case'
  $redactedCase=New-F3FailedHttpCase -Case ([pscustomobject]@{name='deny';command='echo TOKEN'}) -SessionId '' -SessionDirectory 'temp/session' -Stage 'POST /api/session' -Status 401 -Text 'bad secret' -Password 'secret'
  Check ($redactedCase.signal -notmatch 'secret' -and $redactedCase.response -notmatch 'secret') 'failed HTTP case redacts password from diagnostics'
  [IO.File]::WriteAllText($authFile,'{"port":43210,"password":"synthetic-service-password"}',[Text.UTF8Encoding]::new($false))
  $auth=Get-F3ServiceAuth -Path $authFile -ExpectedPort 43210
  Check ($auth.password_present -and $auth.port_match) 'isolated service JSON provides password and matching port'
  $missingAuthRejected=$false
  try { Get-F3ServiceAuth -Path ($authFile+'.missing') -ExpectedPort 43210 } catch { $missingAuthRejected=($_.Exception.Message -eq 'F3_SERVICE_AUTH_UNPROVEN') }
  Check $missingAuthRejected 'missing service JSON fails closed'
  $portMismatchRejected=$false
  try { $mismatch=Get-F3ServiceAuth -Path $authFile -ExpectedPort 43211; Assert-F3ServiceAuthPort -ServiceAuth $mismatch } catch { $portMismatchRejected=($_.Exception.Message -eq 'F3_SERVICE_AUTH_UNPROVEN') }
  Check $portMismatchRejected 'service JSON port mismatch is detectable for fail-closed handling'
  $serialized=Protect-F3JsonSecrets -Json (([ordered]@{response='synthetic-generated-password';signal='synthetic-service-password'}|ConvertTo-Json -Compress)) -Passwords @('synthetic-generated-password','synthetic-service-password')
  Check ($serialized -notmatch 'synthetic-generated-password|synthetic-service-password' -and $serialized -match '\[REDACTED\]') 'serialized output redacts both password sources'
  $eventJson='{"event":{"type":"permission.replied","properties":{"sessionID":"session-1","requestID":"decision-1","reply":"once","password":"synthetic-service-password"}}}'
  $safeEvents=Get-F3PermissionEventRecords -PermissionBody '' -EventBody $eventJson -SessionId 'session-1' -Passwords @('synthetic-service-password')
  $safeEventsJson=$safeEvents|ConvertTo-Json -Compress
  Check (@($safeEvents|Where-Object { $_.id -ceq 'decision-1' }).Count -eq 1 -and $safeEventsJson -notmatch 'synthetic-service-password') 'permission event records are bounded and sanitized'
  $manyEvents=1..8|ForEach-Object { [ordered]@{type='permission.replied';sessionID='session-1';id=("event-{0}" -f $_);reply='once';padding=('x'*3000)} }
  $boundedEvents=Get-F3PermissionEventRecords -PermissionBody '' -EventBody ($manyEvents|ConvertTo-Json -Compress -Depth 5) -SessionId 'session-1'
  $boundedEventJson=@($boundedEvents|ForEach-Object { $_|ConvertTo-Json -Compress })
  Check (@($boundedEvents).Count -le 5 -and @($boundedEventJson|Where-Object { $_.Length -gt 2000 }).Count -eq 0) 'permission events are capped at five and 2000 chars each'
  $passwordRejected=$false
  try { Assert-F3PasswordPresent @{XDG_CONFIG_HOME='isolated'} } catch { $passwordRejected=($_.Exception.Message -eq 'F3_PASSWORD_MISSING_BEFORE_WARMUP') }
  Check $passwordRejected 'missing ephemeral password aborts before warmup'
  $verifyRejected=$false
  try { Assert-F3PostRun -VerifyExit 1 -StopSucceeded $true -PostStatusExit 1 -PostStatusText 'not running' } catch { $verifyRejected=($_.Exception.Message -eq 'ACTIVE_PATH_CHANGED') }
  Check ($verifyRejected -and (Get-F3RunExitCode -VerifyExit 1 -PostGateFailed $false) -eq 1) 'Verify divergence requires nonzero exit'
  $outside=Join-Path $base ('f3-outside-'+[guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $outside -Force|Out-Null
  $directoryRejected=$false
  try { Assert-F3SessionDirectory -Directory $outside -RunRoot $base } catch { $directoryRejected=($_.Exception.Message -eq 'SESSION_DIRECTORY_UNPROVEN') }
  Check $directoryRejected 'session directory must be git repo under runRoot'
  Remove-Item $outside -Recurse -Force
} finally {
  if (Test-Path $out) { Remove-Item $out -Force }
  if (Test-Path $authFile) { Remove-Item $authFile -Force }
  if ($plan -and $plan.fixture -and $plan.fixture.path) {
    $fixtureDir=Split-Path $plan.fixture.path -Parent
    $runRoot=Split-Path (Split-Path $fixtureDir -Parent) -Parent
    if ($runRoot -and (Test-Path $runRoot) -and $runRoot.StartsWith([IO.Path]::GetFullPath($base),[StringComparison]::OrdinalIgnoreCase)) { Remove-Item $runRoot -Recurse -Force }
  }
}
Write-Host "RESULT $($count-$failed)/$count"
if ($failed) { exit 1 }
