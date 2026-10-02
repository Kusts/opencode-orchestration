<#
.SYNOPSIS
    Synthetic-only capability health and deterministic fallback policy (P39).
.DESCRIPTION
    health_probe.probe_budget_metadata is METADATA ONLY in this slice: the probe
    is synthetic and opens no process, socket or file, so no execution timeout is
    enforced and none is claimed. Real execution timeouts arrive with the real
    transport and stay HOLD until that transport exists.
    Descriptors are schema-validated before use; an invalid descriptor is
    rejected as capability-schema-invalid and reported as structured
    unavailable, never as a valid capability. platform_support values must be
    exactly booleans; a string, number or null is a schema failure, never a
    coerced $true. A fallback destination must be
    declared (capability key or fallback_destinations registry) and supported on
    the current platform; otherwise there is no fallback (degraded mode, or the
    typed blocker required by risk_class). No writes, process or network access.
#>
[CmdletBinding()]
param()

function Get-CapabilityDoctorValue {
    param($Object,[string]$Name,$Default=$null)
    if($null -eq $Object){return $Default}
    if($Object -is [System.Collections.IDictionary]){if($Object.Contains($Name)){return $Object[$Name]};return $Default}
    $property=$Object.PSObject.Properties[$Name]
    if($null -ne $property){return $property.Value}
    return $Default
}

function Test-CapabilityDoctorField {
    param($Object,[string]$Name)
    if($null -eq $Object){return $false}
    if($Object -is [System.Collections.IDictionary]){return [bool]$Object.Contains($Name)}
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Test-CapabilityDoctorArrayField {
    param($Object,[string]$Name)
    if(-not (Test-CapabilityDoctorField $Object $Name)){return $false}
    $value=Get-CapabilityDoctorValue $Object $Name $null
    if($null -eq $value){return $false}
    if($value -is [string]){return $false}
    if($value -is [System.Collections.IDictionary]){return $false}
    return ($value -is [System.Collections.IEnumerable])
}

function Get-CapabilityDoctorPolicy {
    param($Policy)
    if($null -ne $Policy){return $Policy}
    $path=Join-Path $PSScriptRoot '..\..\..\source\registry\capability-doctor-policy.json'
    try{return (ConvertFrom-Json ([IO.File]::ReadAllText([IO.Path]::GetFullPath($path))))}catch{return $null}
}

function Test-CapabilityDoctorDescriptor {
    <#
    .SYNOPSIS
        Schema validation of one capability descriptor.
    .DESCRIPTION
        Returns '' when the descriptor satisfies every required field, otherwise a
        kebab-case reason naming the first violated rule. Missing or mistyped
        required fields are schema failures, never silently defaulted.
    #>
    [CmdletBinding()]
    param($Descriptor)
    if($null -eq $Descriptor){return 'descriptor-missing'}
    if(-not (Test-CapabilityDoctorField $Descriptor 'provider')){return 'provider-missing'}
    $provider=Get-CapabilityDoctorValue $Descriptor 'provider' $null
    if($provider -isnot [string] -or [string]::IsNullOrWhiteSpace($provider)){return 'provider-invalid'}
    if(-not (Test-CapabilityDoctorField $Descriptor 'fallback_order')){return 'fallback-order-missing'}
    if(-not (Test-CapabilityDoctorArrayField $Descriptor 'fallback_order')){return 'fallback-order-type'}
    if(-not (Test-CapabilityDoctorField $Descriptor 'platform_support')){return 'platform-support-missing'}
    $platformSupport=Get-CapabilityDoctorValue $Descriptor 'platform_support' $null
    if($null -eq $platformSupport -or $platformSupport -is [string] -or $platformSupport -is [ValueType]){return 'platform-support-type'}
    $supportPairs=@()
    if($platformSupport -is [System.Collections.IDictionary]){foreach($key in @($platformSupport.Keys)){$supportPairs+=,@([string]$key,$platformSupport[$key])}}
    else{foreach($property in $platformSupport.PSObject.Properties){$supportPairs+=,@([string]$property.Name,$property.Value)}}
    if($supportPairs.Count -eq 0){return 'platform-support-empty'}
    foreach($pair in $supportPairs){if($pair[1] -isnot [bool]){return 'platform-support-type'}}
    $risk=Get-CapabilityDoctorValue $Descriptor 'risk_class' $null
    if(-not (Test-CapabilityDoctorField $Descriptor 'risk_class')){return 'risk-class-missing'}
    if(-not (Test-CapabilityDoctorField $risk 'authority')){return 'authority-missing'}
    $authority=Get-CapabilityDoctorValue $risk 'authority' $null
    if($authority -isnot [string] -or $authority -notin @('none','advisory','execution','authority')){return 'authority-invalid'}
    $probe=Get-CapabilityDoctorValue $Descriptor 'health_probe' $null
    if(-not (Test-CapabilityDoctorField $Descriptor 'health_probe')){return 'probe-missing'}
    if($null -eq $probe -or $probe -is [string] -or $probe -is [ValueType]){return 'probe-type'}
    if(-not (Test-CapabilityDoctorField $probe 'probe_budget_metadata')){return 'probe-budget-missing'}
    $budget=Get-CapabilityDoctorValue $probe 'probe_budget_metadata' $null
    if($budget -is [bool] -or $budget -isnot [ValueType]){return 'probe-budget-type'}
    $number=[double]$budget
    if($number -ne [Math]::Floor($number) -or $number -lt 1 -or $number -gt 3600){return 'probe-budget-range'}
    return ''
}

function Get-CapabilityDoctorSupport {
    <#
    .SYNOPSIS
        Strict platform_support read: only a real boolean is honoured.
    .DESCRIPTION
        Returns the declared boolean, or $false when the platform is absent or
        the declared value is not exactly [bool]. Never coerces, because a
        non-empty string such as "false" would coerce to $true in PowerShell.
    #>
    [CmdletBinding()]
    param($Descriptor,[string]$Platform='')
    $support=Get-CapabilityDoctorValue (Get-CapabilityDoctorValue $Descriptor 'platform_support' $null) $Platform $null
    if($support -is [bool]){return $support}
    return $false
}

function Resolve-CapabilityDoctorMaxDetailChars {
    <#
    .SYNOPSIS
        Clamp policy max_detail_chars to 1..160, defaulting when out of range.
    #>
    [CmdletBinding()]
    param($Policy)
    if(-not (Test-CapabilityDoctorField $Policy 'max_detail_chars')){return 160}
    $raw=Get-CapabilityDoctorValue $Policy 'max_detail_chars' $null
    if($raw -is [bool] -or $raw -isnot [ValueType]){return 160}
    $number=[double]$raw
    if([double]::IsNaN($number) -or $number -lt 1 -or $number -gt 160){return 160}
    return [int][Math]::Floor($number)
}

function Resolve-CapabilityDoctorDestination {
    <#
    .SYNOPSIS
        Classify a fallback destination as supported, unsupported or unknown.
    .DESCRIPTION
        A destination is usable only when it is declared (capability key or
        fallback_destinations registry) and supported on the current platform.
        Unknown and unsupported destinations are both rejected, fail-closed.
    #>
    [CmdletBinding()]
    param($Policy,[string]$Name,[string]$Platform='')
    $capability=Get-CapabilityDoctorValue (Get-CapabilityDoctorValue $Policy 'capabilities' $null) $Name $null
    if($null -ne $capability){
        if((Test-CapabilityDoctorDescriptor $capability) -ne ''){return 'unknown'}
        if($Platform -and -not (Get-CapabilityDoctorSupport $capability $Platform)){return 'unsupported'}
        return 'supported'
    }
    $entry=Get-CapabilityDoctorValue (Get-CapabilityDoctorValue $Policy 'fallback_destinations' $null) $Name $null
    if($null -eq $entry){return 'unknown'}
    if($Platform -and -not (Get-CapabilityDoctorSupport $entry $Platform)){return 'unsupported'}
    return 'supported'
}

function Protect-CapabilityDoctorDetail {
    param([string]$Text,[int]$MaxChars=160)
    if($null -eq $Text){return ''}
    $value=$Text -replace '(?i)\b[a-z0-9.-]+\.(com|net|org|local|dev|io|br)\b','[redacted-host]'
    $value=$value -replace '(?i)(token|key|authorization)\s*[:=]\s*[^\s,;]+','$1=[redacted]'
    $value=$value -replace '(?i)sk-[A-Za-z0-9_-]+','[redacted]'
    $value=$value -replace '(?i)https?://[^\s]+','[redacted-url]'
    $value=$value -replace '[\r\n\t]',' '
    if($MaxChars -lt 1 -or $MaxChars -gt 160){$MaxChars=160}
    if($value.Length -gt $MaxChars){$value=$value.Substring(0,$MaxChars)}
    return $value
}

function Invoke-OrchestrationCapabilityDoctor {
    <#
    .SYNOPSIS
        Report synthetic health and fallback state for every policy capability.
    #>
    [CmdletBinding()]
    param($Policy,[scriptblock]$Probe,[string]$Platform='', [string[]]$RequiredCapabilities=@(), [scriptblock]$Clock={ [DateTime]::UtcNow.ToString('o') })
    $policy=Get-CapabilityDoctorPolicy $Policy
    $stamp=''
    try{$stamp=[string](& $Clock)}catch{$stamp=''}
    $parsed=[DateTimeOffset]::MinValue
    if([string]::IsNullOrWhiteSpace($stamp) -or -not [DateTimeOffset]::TryParse($stamp,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed)){$stamp=[DateTime]::UtcNow.ToString('o')}
    if(-not $Platform){if($env:OS -eq 'Windows_NT'){$Platform='windows'}else{$Platform='linux'}}
    $platformName=$Platform.ToLowerInvariant()
    $maxChars=Resolve-CapabilityDoctorMaxDetailChars $policy
    $results=[ordered]@{}
    $caps=Get-CapabilityDoctorValue $policy 'capabilities' $null
    if($null -eq $caps){return [pscustomobject]@{generated_at=$stamp;status='policy-unavailable';capabilities=[pscustomobject]@{}}}
    foreach($entry in $caps.PSObject.Properties){
        $name=[string]$entry.Name;$descriptor=$entry.Value
        $schemaReason=Test-CapabilityDoctorDescriptor $descriptor
        $schemaError=$null;if($schemaReason){$schemaError='capability-schema-invalid'}
        $provider=[string](Get-CapabilityDoctorValue $descriptor 'provider' 'unknown')
        $authority=Protect-CapabilityDoctorDetail ([string](Get-CapabilityDoctorValue (Get-CapabilityDoctorValue $descriptor 'risk_class' $null) 'authority' 'unknown')) 16
        $health='unavailable';$detail='Synthetic probe not supplied.'
        $supported=Get-CapabilityDoctorSupport $descriptor $platformName
        if($schemaError){$health='unavailable';$detail='Capability descriptor rejected as capability-schema-invalid: '+$schemaReason+'.'}
        elseif(-not $supported){$health='unsupported';$detail='Capability unsupported on this platform.'}
        elseif($null -ne $Probe){
            try{
                $probePolicy=Get-CapabilityDoctorValue $descriptor 'health_probe' $null
                $budget=[int](Get-CapabilityDoctorValue $probePolicy 'probe_budget_metadata' 1)
                $probeResult=$null
                if([bool](Get-CapabilityDoctorValue $probePolicy 'synthetic_only' $false) -and $budget -gt 0){$probeResult=& $Probe $name $budget}
                if($null -eq $probeResult){$health='unavailable';$detail='Synthetic-only probe policy missing or invalid.'}
                elseif([double](Get-CapabilityDoctorValue $probeResult 'elapsed_seconds' 0) -gt $budget){$health='unavailable';$detail='Synthetic probe reported elapsed beyond its declared budget metadata.'}
                else{$candidate=[string](Get-CapabilityDoctorValue $probeResult 'health' 'unavailable');if($candidate -in @('healthy','unavailable','degraded')){$health=$candidate};$detail=[string](Get-CapabilityDoctorValue $probeResult 'detail' 'Synthetic probe completed.')}
            }catch{$health='unavailable';$detail='Synthetic probe failed.'}
        }
        $safeProvider=Protect-CapabilityDoctorDetail $provider 80
        $safeDetail=Protect-CapabilityDoctorDetail $detail $maxChars
        $fallback=Get-OrchestrationCapabilityFallback -Capability $name -Health $health -Policy $policy -Platform $platformName -Required:($RequiredCapabilities -contains $name)
        $results[$name]=[ordered]@{health=$health;provider=$safeProvider;fallback_available=[bool]$fallback.use_fallback;detail=$safeDetail;generated_at=$stamp;required_blocker=$fallback.blocked;blocker_type=$fallback.blocker_type;authority_class=$authority;schema_error=$schemaError;schema_error_reason=$(if($schemaError){$schemaReason}else{$null})}
    }
    $optionalNames=@();foreach($entry in $caps.PSObject.Properties){if([bool](Get-CapabilityDoctorValue $entry.Value 'optional' $false)){$optionalNames+=@([string]$entry.Name)}}
    $allOptionalUnavailable=($optionalNames.Count -gt 0)
    foreach($optionalName in $optionalNames){if($results[$optionalName].health -eq 'healthy'){$allOptionalUnavailable=$false}}
    if($allOptionalUnavailable){foreach($optionalName in $optionalNames){$results[$optionalName].fallback_available=$false;$results[$optionalName].degraded_mode=$true;$results[$optionalName].detail='All optional providers unavailable; structured degraded mode.'}}
    return [pscustomobject]@{generated_at=$stamp;status='synthetic-only';degraded_mode=$allOptionalUnavailable;capabilities=[pscustomobject]$results}
}

function Get-OrchestrationCapabilityFallback {
    <#
    .SYNOPSIS
        Resolve deterministic fallback or typed blocker for one capability.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Capability,[Parameter(Mandatory=$true)][string]$Health,$Policy,[string]$Platform='',[switch]$Required)
    $policy=Get-CapabilityDoctorPolicy $Policy
    $descriptor=Get-CapabilityDoctorValue (Get-CapabilityDoctorValue $policy 'capabilities' $null) $Capability $null
    if($null -eq $descriptor){return [pscustomobject]@{use_fallback=$false;fallback_to=$null;degraded_mode=$true;blocked=$true;blocker_type='CAPABILITY_POLICY_UNAVAILABLE';detail='Capability policy unavailable.'}}
    $schemaReason=Test-CapabilityDoctorDescriptor $descriptor
    if($schemaReason){return [pscustomobject]@{use_fallback=$false;fallback_to=$null;degraded_mode=$false;blocked=$true;blocker_type='CAPABILITY_SCHEMA_INVALID';detail='Capability descriptor rejected as capability-schema-invalid: '+$schemaReason+'; no fallback authority granted.'}}
    $risk=Get-CapabilityDoctorValue $descriptor 'risk_class' $null
    $authority=[string](Get-CapabilityDoctorValue $risk 'authority' 'execution')
    if($Health -eq 'healthy'){return [pscustomobject]@{use_fallback=$false;fallback_to=$null;degraded_mode=$false;blocked=$false;blocker_type=$null;fallback_rejected_reason=$null;detail='Primary capability healthy.'}}
    if($authority -in @('execution','authority')){return [pscustomobject]@{use_fallback=$false;fallback_to=$null;degraded_mode=$false;blocked=$true;blocker_type='CAPABILITY_SECURITY_HEALTH_BLOCKED';fallback_rejected_reason=$null;detail='Security-sensitive capability health is unavailable; no fallback authority granted.'}}
    if($Required){return [pscustomobject]@{use_fallback=$false;fallback_to=$null;degraded_mode=$false;blocked=$true;blocker_type='CAPABILITY_REQUIRED_BLOCKED';fallback_rejected_reason=$null;detail='Required capability unavailable.'}}
    $order=@(Get-CapabilityDoctorValue $descriptor 'fallback_order' @())
    $target=$null
    foreach($candidate in $order){if([string]$candidate -ne 'degraded-mode'){$target=[string]$candidate;break}}
    if($null -eq $target){return [pscustomobject]@{use_fallback=$false;fallback_to=$null;degraded_mode=$true;blocked=$false;blocker_type=$null;fallback_rejected_reason=$null;detail='All optional providers unavailable; structured degraded mode.'}}
    $destination=Resolve-CapabilityDoctorDestination -Policy $policy -Name $target -Platform $Platform
    if($destination -ne 'supported'){return [pscustomobject]@{use_fallback=$false;fallback_to=$null;degraded_mode=$true;blocked=$false;blocker_type=$null;fallback_rejected_reason=('fallback-destination-'+$destination);detail='Fallback destination not usable on this platform; structured degraded mode.'}}
    return [pscustomobject]@{use_fallback=$true;fallback_to=$target;degraded_mode=$false;blocked=$false;blocker_type=$null;fallback_rejected_reason=$null;detail='Explicit deterministic fallback selected.'}
}