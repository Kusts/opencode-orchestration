<#
.SYNOPSIS
    PowerShell 5.1 compatible adaptive validation policy; no process/network access.
.DESCRIPTION
    The kernel allowlist in source/registry/verification-policy.json is the
    effective verified_pass authority. This library only declares/mirrors that
    contract; it does not grant DONE or verified_pass authority.
#>
[CmdletBinding()]
param()

function Get-ValidationValue { param($Object,[string]$Name,$Default=$null)
    if($null -eq $Object){return $Default}
    if($Object -is [System.Collections.IDictionary]){if($Object.Contains($Name)){return $Object[$Name]};return $Default}
    $p=$Object.PSObject.Properties[$Name];if($null -ne $p){return $p.Value};return $Default
}
function Get-ValidationPolicy { param($Policy)
    if($null -ne $Policy){return $Policy}
    $path=Join-Path $PSScriptRoot '..\..\..\source\registry\validation-policy.json'
    try{return (ConvertFrom-Json ([IO.File]::ReadAllText([IO.Path]::GetFullPath($path))))}catch{return $null}
}
function Test-ValidationPolicyShape { param($Policy)
    if($null -eq $Policy -or $null -eq $Policy.levels -or $null -eq $Policy.minimum_level_by_risk -or @($Policy.hard_risk_triggers).Count -eq 0 -or @($Policy.descriptor_rules).Count -eq 0){return $false}
    foreach($level in @('L0','L1','L2','L3')){if($null -eq $Policy.levels.$level -or @($Policy.levels.$level.required_roles).Count -eq 0){return $false}}
    return $true
}

function Get-OrchestrationValidationLevel {
    [CmdletBinding()] param($Descriptor,$Policy)
    $Policy=Get-ValidationPolicy $Policy
    if(-not (Test-ValidationPolicyShape $Policy)){return [pscustomobject]@{level='L3';required_roles=@('coder','tester','reviewer','security-reviewer');triggers=@('policy-unavailable');rationale='Validation policy unavailable or malformed; fail-closed.';status='policy-unavailable'}}
    $level='L2';$rationale='Conservative default for unsupported descriptor.';$triggers=@()
    $risk=[string](Get-ValidationValue $Descriptor 'risk' 'medium');$triggerInput=@(Get-ValidationValue $Descriptor 'risk_triggers' @())
    foreach($trigger in @($Policy.hard_risk_triggers)){if($triggerInput -contains $trigger){$triggers+=@([string]$trigger)}}
    $text=[string](Get-ValidationValue $Descriptor 'domain' '')+' '+[string](Get-ValidationValue $Descriptor 'operation' '')+' '+[string](Get-ValidationValue $Descriptor 'summary' '')
    foreach($trigger in @($Policy.hard_risk_triggers)){if($text -match ('(?i)(^|[^a-z])'+[regex]::Escape([string]$trigger)+'([^a-z]|$)')){$triggers+=@([string]$trigger)}}
    $triggers=@($triggers | Sort-Object -Unique)
    $knownRisk=@('low','medium','high','critical')
    if($risk -notin $knownRisk -or $null -eq (Get-ValidationValue $Policy.minimum_level_by_risk $risk $null)){$roles=@(Get-ValidationValue $Policy.levels.L3 'required_roles' @('coder','tester','reviewer','security-reviewer'));return [pscustomobject]@{level='L3';required_roles=$roles;triggers=@($triggers+'unrecognized-risk');rationale='Unrecognized or unmapped risk; fail-closed.';status='unknown-risk'}}
    foreach($rule in $Policy.descriptor_rules){$matches=$true;foreach($name in $rule.when.PSObject.Properties.Name){if([string](Get-ValidationValue $Descriptor $name '') -ine [string]$rule.when.$name){$matches=$false;break}};if($matches){$level=[string]$rule.level;$rationale='Selected by validation-policy descriptor rule.';break}}
    $riskMinimum=[string](Get-ValidationValue $Policy.minimum_level_by_risk $risk '')
    if($triggers.Count -gt 0){$level='L3';$rationale='Hard risk trigger requires security validation.'}
    elseif($riskMinimum -in @('L0','L1','L2','L3')){if(@('L0','L1','L2','L3').IndexOf($level) -lt @('L0','L1','L2','L3').IndexOf($riskMinimum)){$level=$riskMinimum};$rationale='Policy descriptor rule constrained by policy minimum risk level.'}
    $roles=@(Get-ValidationValue $Policy.levels.$level 'required_roles' @('coder'))
    return [pscustomobject]@{level=$level;required_roles=$roles;triggers=$triggers;rationale=$rationale;status='ok'}
}

function Test-OrchestrationCompletionPolicy {
    [CmdletBinding()] param([string]$Level,[string[]]$CompletedRoles,$Descriptor,$Policy)
    $Policy=Get-ValidationPolicy $Policy
    $decision=Get-OrchestrationValidationLevel $Descriptor $Policy
    if(-not (Test-ValidationPolicyShape $Policy)){return [pscustomobject]@{allowed=$false;missing_roles=@('coder','tester','reviewer','security-reviewer');effective_level='L3';status='policy-unavailable'}}
    $levelsOrder=@('L0','L1','L2','L3');$effective=$decision.level
    if($Level -in $levelsOrder -and $levelsOrder.IndexOf($Level) -gt $levelsOrder.IndexOf($effective)){$effective=$Level}
    $risk=[string](Get-ValidationValue $Descriptor 'risk' 'medium');$minimum=[string](Get-ValidationValue (Get-ValidationPolicy $Policy).minimum_level_by_risk $risk '')
    if($risk -notin @('low','medium','high','critical') -or -not $minimum){$effective='L3'}
    if($minimum -in $levelsOrder -and $levelsOrder.IndexOf($minimum) -gt $levelsOrder.IndexOf($effective)){$effective=$minimum}
    $levels=Get-ValidationValue $Policy 'levels';$levelPolicy=Get-ValidationValue $levels $effective
    $required=@(Get-ValidationValue $levelPolicy 'required_roles' @())
    $missing=@($required | Where-Object {$_ -notin $CompletedRoles})
    return [pscustomobject]@{allowed=($missing.Count -eq 0);missing_roles=$missing;effective_level=$effective}
}

function Test-OrchestrationEvidenceCoverage {
    [CmdletBinding()] param($EvidenceRecordRefs,$CurrentFingerprints,[hashtable]$ExpectedFingerprints,[string]$CurrentBaseRevision,[string]$Now,$Policy)
    foreach($record in @($EvidenceRecordRefs)){
        if($null -eq $record){continue}
        $status=[string](Get-ValidationValue $record 'status' 'confirmed');if($status -ne 'confirmed'){continue}
        $old=Get-ValidationValue $record 'source_fingerprints' $null;if($null -eq $old){continue}
        $expected=$ExpectedFingerprints;if($null -eq $expected){$expected=$CurrentFingerprints};if($null -eq $expected -or $expected.Count -eq 0 -or $old.Count -ne $expected.Count){continue}
        $same=$true;foreach($path in $expected.Keys){if(-not $old.ContainsKey([string]$path) -or -not $CurrentFingerprints.ContainsKey([string]$path) -or [string]$CurrentFingerprints[[string]$path] -cne [string]$expected[$path] -or [string]$old[[string]$path] -cne [string]$expected[$path]){$same=$false;break}}
        $conditions=Get-ValidationValue $record 'invalidation_conditions' @();$base=Get-ValidationValue $record 'base_revision' ''
        if($same -and $base -and $CurrentBaseRevision -and $base -cne $CurrentBaseRevision){$same=$false}
        foreach($condition in @($conditions)){if((Get-ValidationValue $condition 'type' '') -eq 'base-revision' -and [bool](Get-ValidationValue $condition 'require_same' $true) -and $base -cne $CurrentBaseRevision){$same=$false};if((Get-ValidationValue $condition 'type' '') -eq 'ttl'){$expires=[DateTimeOffset]::MinValue;$nowValue=[DateTimeOffset]::MinValue;$nowText=$Now;if(-not $nowText){$nowText=[DateTime]::UtcNow.ToString('o')};if(-not [DateTimeOffset]::TryParse([string](Get-ValidationValue $condition 'expires_at' ''),[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$expires) -or -not [DateTimeOffset]::TryParse($nowText,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$nowValue) -or $nowValue -gt $expires){$same=$false}}}
        if($same){$same=Test-ValidationCoverageAge $record $Now $Policy}
        if($same){return [pscustomobject]@{can_skip_tester_check=$true;reason='valid-equivalent-evidence'}}
    }
    return [pscustomobject]@{can_skip_tester_check=$false;reason='no-valid-equivalent-evidence-or-source-changed'}
}

function Test-ValidationCoverageAge { param($Record,[string]$Now,$Policy)
    $Policy=Get-ValidationPolicy $Policy;$days=30;if(-not (Test-ValidationPolicyShape $Policy)){$days=7}else{$days=[int](Get-ValidationValue $Policy 'max_coverage_age_days' 30)}
    if($days -lt 1){$days=7};$createdRaw=Get-ValidationValue $Record 'created_at' (Get-ValidationValue $Record 'timestamp' '');$createdText=[string]$createdRaw;if($createdRaw -is [DateTime]){$createdText=$createdRaw.ToUniversalTime().ToString('o')};$created=[DateTimeOffset]::MinValue;$nowText=$Now;if(-not $nowText){$nowText=[DateTime]::UtcNow.ToString('o')};$nowValue=[DateTimeOffset]::MinValue
    if(-not [DateTimeOffset]::TryParse($createdText,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$created) -or -not [DateTimeOffset]::TryParse($nowText,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$nowValue)){return $false}
    return (($nowValue-$created).TotalDays -le $days -and $nowValue -ge $created)
}

function Get-OrchestrationReviewerBundle {
    [CmdletBinding()] param([string[]]$ChangedFiles,$RelatedFiles)
    $set=New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($file in $ChangedFiles){if(-not [string]::IsNullOrWhiteSpace($file)){[void]$set.Add($file)}}
    foreach($file in @($RelatedFiles)){if($file -and ($ChangedFiles | Where-Object {([IO.Path]::GetDirectoryName($_)) -ieq [IO.Path]::GetDirectoryName($file) -and ([IO.Path]::GetFileNameWithoutExtension($file) -match ('(?i)^'+[regex]::Escape([IO.Path]::GetFileNameWithoutExtension($_))+'([._-]|$)'))})){[void]$set.Add([string]$file)}}
    return ,@($set)
}

function Write-OrchestrationSecurityCoverage {
    [CmdletBinding()] param([string]$Path,[string]$Scope,$Fingerprints,[ValidateSet('confirmed','needs-validation')][string]$Status,[string]$TimestampUtc,[string]$BaseRevision='',[string]$ExpiresAt='')
    try {
        if([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Scope)){return $false}
        if($Status -eq 'confirmed' -and ($null -eq $Fingerprints -or $Fingerprints.Count -eq 0 -or [string]::IsNullOrWhiteSpace($BaseRevision))){$Status='needs-validation'}
        $safeScope=$Scope -replace '[^A-Za-z0-9._/-]','_';if($safeScope.Length -gt 240){$safeScope=$safeScope.Substring(0,240)}
        $clean=[ordered]@{};foreach($key in @($Fingerprints.Keys | Sort-Object)){if($clean.Count -ge 100){break};$k=([string]$key -replace '(?i)sk-[A-Za-z0-9_-]+','[REDACTED]');$v=([string]$Fingerprints[$key] -replace '(?i)sk-[A-Za-z0-9_-]+','[REDACTED]');if($k.Length -gt 240){$k=$k.Substring(0,240)};if($v.Length -gt 128){$v=$v.Substring(0,128)};$clean[$k]=$v}
        $stamp=$TimestampUtc;if(-not $stamp){$stamp=[DateTime]::UtcNow.ToString('o')};$parsed=[DateTimeOffset]::MinValue;if(-not [DateTimeOffset]::TryParse($stamp,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed)){return $false}
        $row=[ordered]@{schema_version=1;scope=$safeScope;source_fingerprints=$clean;status=$Status;timestamp=$parsed.UtcDateTime.ToString('o');base_revision=$BaseRevision;expires_at=$ExpiresAt};$line=(ConvertTo-Json $row -Depth 8 -Compress)+"`n";$bytes=[Text.Encoding]::UTF8.GetByteCount($line);if($bytes -gt 8192){return $false};$dir=Split-Path -Parent $Path;if($dir -and -not (Test-Path -LiteralPath $dir)){[void][IO.Directory]::CreateDirectory($dir)}
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::None);try{if($stream.Length+$bytes -gt 262144){return $false};$b=[Text.Encoding]::UTF8.GetBytes($line);$stream.Write($b,0,$b.Length);$stream.Flush();return $true}finally{$stream.Dispose()}
    }catch{return $false}
}

function Test-OrchestrationSecurityCoverage {
    [CmdletBinding()] param([string]$Path,[string]$Scope,$CurrentFingerprints,[hashtable]$ExpectedFingerprints,[string]$CurrentBaseRevision,[string]$Now,$Policy)
    try{foreach($line in [IO.File]::ReadAllLines($Path)){try{$r=ConvertFrom-Json $line;if($r.schema_version -ne 1 -or $r.scope -cne $Scope -or $r.status -ne 'confirmed'){continue};$expected=$ExpectedFingerprints;if($null -eq $expected){$expected=$CurrentFingerprints};if($null -eq $expected -or $expected.Count -eq 0){continue};$stored=$r.source_fingerprints;$same=($stored.PSObject.Properties.Count -eq $expected.Count);foreach($k in $expected.Keys){if($null -eq $stored.$k -or -not $CurrentFingerprints.ContainsKey($k) -or [string]$CurrentFingerprints[$k] -cne [string]$expected[$k] -or [string]$stored.$k -cne [string]$expected[$k]){$same=$false;break}};if(-not $same){continue};if(-not $r.base_revision -or -not $CurrentBaseRevision -or [string]$r.base_revision -cne $CurrentBaseRevision){continue};if($r.expires_at){$expiry=[DateTimeOffset]::MinValue;$nowValue=[DateTimeOffset]::MinValue;$nowText=$Now;if(-not $nowText){$nowText=[DateTime]::UtcNow.ToString('o')};if(-not [DateTimeOffset]::TryParse([string]$r.expires_at,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$expiry) -or -not [DateTimeOffset]::TryParse($nowText,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$nowValue) -or $nowValue -gt $expiry){continue}};if(-not (Test-ValidationCoverageAge $r $Now $Policy)){continue};return [pscustomobject]@{covered=$true;status='confirmed';reason='fingerprints-match'}}catch{}}}catch{};return [pscustomobject]@{covered=$false;status='needs-validation';reason='missing-or-invalidated-coverage'}
}

function Assert-VerifiedPassAuthority {
    [CmdletBinding()] param([string]$Role,$Policy)
    $Policy=Get-ValidationPolicy $Policy
    return ([string]$Role -in @($Policy.verified_pass_authorities))
}
