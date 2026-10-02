[CmdletBinding()] param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OrchestrationCapabilityDoctor.ps1')
$policy=ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\..\..\source\registry\capability-doctor-policy.json')))
$passed=0
function Assert-That {param([bool]$Condition,[string]$Name);if(-not $Condition){throw "FAIL: $Name"};$script:passed++}
function Copy-Policy {param($Source);return (ConvertFrom-Json (ConvertTo-Json $Source -Depth 20 -Compress))}
$clock={ '2026-10-02T12:00:00Z' }
$before=@(Get-ChildItem -LiteralPath $env:TEMP -Force | ForEach-Object {$_.Name} | Sort-Object)
$healthy=Invoke-OrchestrationCapabilityDoctor -Policy $policy -Platform linux -Clock $clock -Probe {param($name,$budget) if($name -eq 'jev'){return @{health='healthy';detail='Ready'}};return @{health='unavailable';detail='Unavailable'}}
Assert-That ($healthy.capabilities.jev.health -eq 'healthy' -and $healthy.capabilities.jev.provider -eq 'jev-advisory') 'healthy primary descriptor'
Assert-That ($healthy.generated_at -eq '2026-10-02T12:00:00Z') 'injected timestamp preserved'
$overBudget=Invoke-OrchestrationCapabilityDoctor -Policy $policy -Platform linux -Clock $clock -Probe {param($name,$budget) @{health='healthy';elapsed_seconds=($budget+1);detail='late'}}
Assert-That ($overBudget.capabilities.jev.health -eq 'unavailable') 'probe result beyond declared budget fails closed'
$unhealthy=Get-OrchestrationCapabilityFallback -Capability 'ai-memory' -Health unavailable -Policy $policy
Assert-That ($unhealthy.use_fallback -and $unhealthy.fallback_to -eq 'local-project-search') 'unhealthy optional primary has explicit fallback'
$unsupported=Invoke-OrchestrationCapabilityDoctor -Policy $policy -Platform windows -Clock $clock -Probe {throw 'probe must not run'}
Assert-That ($unsupported.capabilities.'semantic-discovery'.health -eq 'unsupported') 'Windows semantic discovery unsupported without throwing'
$unsupportedFallback=Get-OrchestrationCapabilityFallback -Capability 'semantic-discovery' -Health unsupported -Policy $policy
Assert-That ($unsupportedFallback.use_fallback -and $unsupportedFallback.fallback_to -eq 'direct-search') 'unsupported platform falls back explicitly'
Assert-That ($policy.capabilities.'semantic-discovery'.routing_hint -match 'Exact symbol/path lookup') 'exact symbol/path prefers direct lookup'
$allDown=Invoke-OrchestrationCapabilityDoctor -Policy $policy -Platform linux -Clock $clock -Probe {param($name,$budget) @{health='unavailable';detail='down'}}
Assert-That ($allDown.degraded_mode -and $allDown.capabilities.jev.degraded_mode) 'all optional providers unavailable produce structured degraded mode'
$required=Get-OrchestrationCapabilityFallback -Capability jev -Health unavailable -Policy $policy -Required
Assert-That ($required.blocked -and $required.blocker_type -eq 'CAPABILITY_REQUIRED_BLOCKED' -and -not $required.use_fallback) 'required unavailable capability returns typed blocker'
$hostile=Invoke-OrchestrationCapabilityDoctor -Policy $policy -Platform linux -Clock $clock -Probe {param($name,$budget) @{health='degraded';detail='sk-SYNTHETICSECRET token=abc https://secret.example.com/path'}}
$safe=$hostile.capabilities.jev.detail
Assert-That ($safe -notmatch 'SYNTHETICSECRET|\babc\b|example\.com|https?://' -and $safe.Length -le 160) 'detail redacts tokens and hostnames and stays bounded'
$executionPolicy=Copy-Policy $policy
$executionPolicy.capabilities.jev.risk_class.authority='execution'
$secureFallback=Get-OrchestrationCapabilityFallback -Capability jev -Health unavailable -Policy $executionPolicy
Assert-That ($secureFallback.blocked -and $secureFallback.blocker_type -eq 'CAPABILITY_SECURITY_HEALTH_BLOCKED' -and -not $secureFallback.use_fallback) 'execution-risk health failure blocks without fallback authority'
$after=@(Get-ChildItem -LiteralPath $env:TEMP -Force | ForEach-Object {$_.Name} | Sort-Object)
Assert-That ((ConvertTo-Json $before -Compress) -ceq (ConvertTo-Json $after -Compress)) 'doctor does not mutate filesystem state'
$first=Invoke-OrchestrationCapabilityDoctor -Policy $policy -Platform linux -Clock $clock -Probe {param($name,$budget) @{health='healthy';detail='ok'}}
$second=Invoke-OrchestrationCapabilityDoctor -Policy $policy -Platform linux -Clock $clock -Probe {param($name,$budget) @{health='healthy';detail='ok'}}
Assert-That ((ConvertTo-Json $first -Depth 10 -Compress) -ceq (ConvertTo-Json $second -Depth 10 -Compress)) 'fixed inputs and timestamp are deterministic'

# F1: schema validation rejects invalid descriptors as structured unavailable
$missingProvider=Copy-Policy $policy
$missingProvider.capabilities.jev.PSObject.Properties.Remove('provider')
$missingReport=Invoke-OrchestrationCapabilityDoctor -Policy $missingProvider -Platform linux -Clock $clock -Probe {param($name,$budget) @{health='healthy';detail='ok'}}
Assert-That ($missingReport.capabilities.jev.health -eq 'unavailable' -and $missingReport.capabilities.jev.schema_error -eq 'capability-schema-invalid' -and $missingReport.capabilities.jev.schema_error_reason -eq 'provider-missing') 'descriptor missing required provider is rejected as capability-schema-invalid'
$missingBlocked=Get-OrchestrationCapabilityFallback -Capability jev -Health unavailable -Policy $missingProvider
Assert-That ($missingBlocked.blocked -and $missingBlocked.blocker_type -eq 'CAPABILITY_SCHEMA_INVALID' -and -not $missingBlocked.use_fallback) 'schema-invalid capability yields typed blocker without fallback authority'
$wrongType=Copy-Policy $policy
$wrongType.capabilities.jev.fallback_order='deterministic-policy'
$wrongTypeReport=Invoke-OrchestrationCapabilityDoctor -Policy $wrongType -Platform linux -Clock $clock -Probe {param($name,$budget) @{health='healthy';detail='ok'}}
Assert-That ($wrongTypeReport.capabilities.jev.schema_error -eq 'capability-schema-invalid' -and $wrongTypeReport.capabilities.jev.schema_error_reason -eq 'fallback-order-type') 'fallback_order of wrong type is rejected as capability-schema-invalid'
$badAuthority=Copy-Policy $policy
$badAuthority.capabilities.jev.risk_class.authority='critical'
$badAuthorityReport=Invoke-OrchestrationCapabilityDoctor -Policy $badAuthority -Platform linux -Clock $clock -Probe {param($name,$budget) @{health='healthy';detail='ok'}}
Assert-That ($badAuthorityReport.capabilities.jev.schema_error -eq 'capability-schema-invalid' -and $badAuthorityReport.capabilities.jev.schema_error_reason -eq 'authority-invalid') 'authority outside the closed enum is rejected as capability-schema-invalid'
$badBudget=Copy-Policy $policy
$badBudget.capabilities.jev.health_probe.probe_budget_metadata=0
$badBudgetReport=Invoke-OrchestrationCapabilityDoctor -Policy $badBudget -Platform linux -Clock $clock -Probe {param($name,$budget) @{health='healthy';detail='ok'}}
Assert-That ($badBudgetReport.capabilities.jev.schema_error -eq 'capability-schema-invalid' -and $badBudgetReport.capabilities.jev.schema_error_reason -eq 'probe-budget-range') 'probe budget outside 1..3600 is rejected as capability-schema-invalid'

# R2: platform_support is validated as a real boolean, never coerced
$coercedSupport=Copy-Policy $policy
$coercedSupport.capabilities.'semantic-discovery'.platform_support.windows='false'
$coercedReport=Invoke-OrchestrationCapabilityDoctor -Policy $coercedSupport -Platform windows -Clock $clock -Probe {param($name,$budget) @{health='healthy';detail='ok'}}
Assert-That ($coercedReport.capabilities.'semantic-discovery'.schema_error -eq 'capability-schema-invalid' -and $coercedReport.capabilities.'semantic-discovery'.schema_error_reason -eq 'platform-support-type' -and $coercedReport.capabilities.'semantic-discovery'.health -eq 'unavailable') 'string platform_support is schema-invalid instead of coerced to supported'
$coercedBlocked=Get-OrchestrationCapabilityFallback -Capability 'semantic-discovery' -Health unavailable -Policy $coercedSupport -Platform 'windows'
Assert-That ($coercedBlocked.blocked -and $coercedBlocked.blocker_type -eq 'CAPABILITY_SCHEMA_INVALID' -and -not $coercedBlocked.use_fallback) 'string platform_support yields typed blocker per risk_class'
$numericSupport=Copy-Policy $policy
$numericSupport.capabilities.jev.platform_support.linux=0
$numericReport=Invoke-OrchestrationCapabilityDoctor -Policy $numericSupport -Platform linux -Clock $clock -Probe {param($name,$budget) @{health='healthy';detail='ok'}}
Assert-That ($numericReport.capabilities.jev.schema_error -eq 'capability-schema-invalid' -and $numericReport.capabilities.jev.schema_error_reason -eq 'platform-support-type') 'numeric platform_support is schema-invalid'
$nullSupport=Copy-Policy $policy
$nullSupport.capabilities.jev.platform_support.linux=$null
$nullReport=Invoke-OrchestrationCapabilityDoctor -Policy $nullSupport -Platform linux -Clock $clock -Probe {param($name,$budget) @{health='healthy';detail='ok'}}
Assert-That ($nullReport.capabilities.jev.schema_error -eq 'capability-schema-invalid' -and $nullReport.capabilities.jev.schema_error_reason -eq 'platform-support-type') 'null platform_support is schema-invalid'
$booleanSupport=Copy-Policy $policy
$booleanSupport.capabilities.'semantic-discovery'.platform_support.windows=$false
$booleanReport=Invoke-OrchestrationCapabilityDoctor -Policy $booleanSupport -Platform windows -Clock $clock -Probe {param($name,$budget) throw 'probe must not run for a boolean false'}
Assert-That ($booleanReport.capabilities.'semantic-discovery'.health -eq 'unsupported' -and $booleanReport.capabilities.'semantic-discovery'.schema_error -eq $null) 'boolean false platform_support is honoured as unsupported'
$hostileDestinationPolicy=Copy-Policy $policy
$hostileDestinationPolicy.fallback_destinations.'direct-search'.platform_support.windows='false'
$hostileDestination=Get-OrchestrationCapabilityFallback -Capability 'semantic-discovery' -Health unsupported -Policy $hostileDestinationPolicy -Platform 'windows'
Assert-That (-not $hostileDestination.use_fallback -and $hostileDestination.fallback_rejected_reason -eq 'fallback-destination-unsupported') 'string platform_support on a fallback destination is unsupported, not coerced'

# F2: probe budget is metadata in this slice; no timeout is claimed or enforced
$doctorHelp=Get-Help (Resolve-Path (Join-Path $PSScriptRoot 'OrchestrationCapabilityDoctor.ps1'))
$doctorDescription=[string](($doctorHelp.Description.Text) -join ' ')
Assert-That ($doctorDescription -match 'METADATA ONLY' -and $doctorDescription -match 'HOLD' -and $doctorDescription -notmatch 'enforces the timeout' -and $doctorDescription -notmatch 'deadline') 'synopsis documents the probe budget as metadata with real timeout on HOLD'

# F3: fallback destination must exist and be supported on the platform
$requiredUnsupported=Get-OrchestrationCapabilityFallback -Capability 'semantic-discovery' -Health unsupported -Policy $policy -Platform 'windows' -Required
Assert-That ($requiredUnsupported.blocked -and $requiredUnsupported.blocker_type -eq 'CAPABILITY_REQUIRED_BLOCKED' -and -not $requiredUnsupported.use_fallback) 'required plus unsupported capability returns typed blocker'
$requiredUnsupportedReport=Invoke-OrchestrationCapabilityDoctor -Policy $policy -Platform windows -Clock $clock -RequiredCapabilities @('semantic-discovery') -Probe {param($name,$budget) @{health='healthy';detail='ok'}}
Assert-That ($requiredUnsupportedReport.capabilities.'semantic-discovery'.required_blocker -and $requiredUnsupportedReport.capabilities.'semantic-discovery'.blocker_type -eq 'CAPABILITY_REQUIRED_BLOCKED') 'doctor surfaces the typed blocker for a required unsupported capability'
$ghostPolicy=Copy-Policy $policy
$ghostPolicy.capabilities.'ai-memory'.fallback_order=@('ghost-provider','degraded-mode')
$ghostFallback=Get-OrchestrationCapabilityFallback -Capability 'ai-memory' -Health unavailable -Policy $ghostPolicy -Platform 'linux'
Assert-That (-not $ghostFallback.use_fallback -and $null -eq $ghostFallback.fallback_to -and $ghostFallback.degraded_mode -and $ghostFallback.fallback_rejected_reason -eq 'fallback-destination-unknown') 'nonexistent fallback destination yields no fallback'
$platformPolicy=Copy-Policy $policy
$platformPolicy.capabilities.'ai-memory'.fallback_order=@('semantic-discovery','degraded-mode')
$unsupportedDestination=Get-OrchestrationCapabilityFallback -Capability 'ai-memory' -Health unavailable -Policy $platformPolicy -Platform 'windows'
Assert-That (-not $unsupportedDestination.use_fallback -and $null -eq $unsupportedDestination.fallback_to -and $unsupportedDestination.fallback_rejected_reason -eq 'fallback-destination-unsupported') 'fallback destination unsupported on the platform yields no fallback'
$supportedDestination=Get-OrchestrationCapabilityFallback -Capability 'ai-memory' -Health unavailable -Policy $platformPolicy -Platform 'linux'
Assert-That ($supportedDestination.use_fallback -and $supportedDestination.fallback_to -eq 'semantic-discovery' -and $null -eq $supportedDestination.fallback_rejected_reason) 'supported fallback destination is used'

# F4: authority_class sanitized and capped; max_detail_chars clamped to 1..160
$canaryPolicy=Copy-Policy $policy
$canaryPolicy.capabilities.jev.provider='sk-SYNTHETICSECRET token=abc https://secret.example.com/path'
$canaryPolicy.capabilities.jev.risk_class.authority='sk-SYNTHETICSECRET token=abc https://secret.example.com/authority'
$canaryReport=Invoke-OrchestrationCapabilityDoctor -Policy $canaryPolicy -Platform linux -Clock $clock -Probe {param($name,$budget) @{health='healthy';detail='ok'}}
$canaryProvider=$canaryReport.capabilities.jev.provider
$canaryAuthority=$canaryReport.capabilities.jev.authority_class
Assert-That ($canaryProvider -notmatch 'SYNTHETICSECRET|\babc\b|example\.com|https?://' -and $canaryAuthority -notmatch 'SYNTHETICSECRET|\babc\b|example\.com|https?://') 'provider and authority_class with canary payload are sanitized'
Assert-That ($canaryAuthority.Length -le 16 -and $canaryReport.capabilities.jev.schema_error -eq 'capability-schema-invalid') 'hostile authority_class is capped and rejected as capability-schema-invalid'
$negativeDetailPolicy=Copy-Policy $policy
$negativeDetailPolicy.max_detail_chars=-5
$negativeDetail=Invoke-OrchestrationCapabilityDoctor -Policy $negativeDetailPolicy -Platform linux -Clock $clock -Probe {param($name,$budget) @{health='healthy';detail=('y'*400)}}
Assert-That ($negativeDetail.capabilities.jev.detail.Length -le 160 -and $negativeDetail.capabilities.jev.health -eq 'healthy') 'negative max_detail_chars falls back to the default bound'
$excessiveDetailPolicy=Copy-Policy $policy
$excessiveDetailPolicy.max_detail_chars=100000
$excessiveDetail=Invoke-OrchestrationCapabilityDoctor -Policy $excessiveDetailPolicy -Platform linux -Clock $clock -Probe {param($name,$budget) @{health='healthy';detail=('y'*400)}}
Assert-That ($excessiveDetail.capabilities.jev.detail.Length -le 160) 'excessive max_detail_chars is clamped to the valid range'
$overflowDetailPolicy=Copy-Policy $policy
$overflowDetailPolicy.max_detail_chars=1e30
$overflowDetail=Invoke-OrchestrationCapabilityDoctor -Policy $overflowDetailPolicy -Platform linux -Clock $clock -Probe {param($name,$budget) @{health='healthy';detail=('y'*400)}}
Assert-That ($overflowDetail.capabilities.jev.detail.Length -le 160 -and $overflowDetail.capabilities.jev.health -eq 'healthy') 'out of numeric range max_detail_chars falls back to default without throwing'
$tightDetailPolicy=Copy-Policy $policy
$tightDetailPolicy.max_detail_chars=20
$tightDetail=Invoke-OrchestrationCapabilityDoctor -Policy $tightDetailPolicy -Platform linux -Clock $clock -Probe {param($name,$budget) @{health='healthy';detail=('y'*400)}}
Assert-That ($tightDetail.capabilities.jev.detail.Length -le 20) 'valid max_detail_chars inside 1..160 is honored'

# F5: invalid clock falls back to the default stamp without throwing
$invalidClock=Invoke-OrchestrationCapabilityDoctor -Policy $policy -Platform linux -Clock { 'not-a-timestamp' } -Probe {param($name,$budget) @{health='healthy';detail='ok'}}
$parsedStamp=[DateTimeOffset]::MinValue
Assert-That ([DateTimeOffset]::TryParse($invalidClock.generated_at,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsedStamp) -and $invalidClock.generated_at -ne 'not-a-timestamp') 'invalid clock yields the default stamp without throwing'
$throwingClock=Invoke-OrchestrationCapabilityDoctor -Policy $policy -Platform linux -Clock { throw 'clock failure' } -Probe {param($name,$budget) @{health='healthy';detail='ok'}}
Assert-That (-not [string]::IsNullOrWhiteSpace($throwingClock.generated_at)) 'throwing clock falls back to the default stamp without throwing'

Write-Output "PASS: $passed assertions"