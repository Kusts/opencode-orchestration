<# Simplicity discipline helpers. Pure, deterministic, PS 5.1 compatible. #>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'CapabilitySanitize.ps1')

function Get-SimplicityValue { param($Object,[string]$Name,$Default=$null)
    if($null -eq $Object){return $Default}
    if($Object -is [System.Collections.IDictionary]){if($Object.Contains($Name)){return $Object[$Name]};return $Default}
    $p=$Object.PSObject.Properties[$Name];if($null -ne $p){return $p.Value};return $Default
}
function ConvertTo-SimplicityText { param($Value,[int]$Max=500)
    $safe=Remove-SecretValues -InputObject $Value
    $s=[string]$safe
    $s=$s -replace '[\x00-\x1F]',' '
    $s=$s.Trim();if($s.Length -gt $Max){$s=$s.Substring(0,$Max)};return $s
}
function Get-SimplicityPolicy { param($Policy)
    if($null -ne $Policy){return $Policy}
    $path=Join-Path $PSScriptRoot '..\..\..\source\registry\simplicity-policy.json'
    try{return (ConvertFrom-Json ([IO.File]::ReadAllText([IO.Path]::GetFullPath($path))))}catch{return $null}
}
function Get-SimplicityInt { param($Value,[int]$Default,[int]$Maximum)
    $parsed=0;if(-not [int]::TryParse([string]$Value,[ref]$parsed) -or $parsed -lt 1){return $Default}
    return [Math]::Min($parsed,$Maximum)
}
function ConvertTo-SimplicityBudget { param($Requested,$PolicyBudget)
    $fallback=[pscustomobject]@{max_files=3;max_total_loc=240;max_loc_by_category=[pscustomobject]@{code=120;tests=160;docs=100;config=80;other=60}}
    if($null -eq $PolicyBudget){$PolicyBudget=$fallback}
    $maxFiles=Get-SimplicityInt (Get-SimplicityValue $PolicyBudget 'max_files' 3) 3 200
    $maxTotal=Get-SimplicityInt (Get-SimplicityValue $PolicyBudget 'max_total_loc' 240) 240 100000
    $baseCats=Get-SimplicityValue $PolicyBudget 'max_loc_by_category' $fallback.max_loc_by_category
    $requestedCats=Get-SimplicityValue $Requested 'max_loc_by_category' $null
    $cats=[ordered]@{}
    foreach($cat in @('code','tests','docs','config','other')){$base=Get-SimplicityInt (Get-SimplicityValue $baseCats $cat (Get-SimplicityValue $fallback.max_loc_by_category $cat)) (Get-SimplicityValue $fallback.max_loc_by_category $cat) 100000;$value=Get-SimplicityValue $Requested $cat $null;if($cat -eq 'code' -or $cat -eq 'tests' -or $cat -eq 'docs' -or $cat -eq 'config' -or $cat -eq 'other'){$value=Get-SimplicityValue $requestedCats $cat $value};$cats[$cat]=Get-SimplicityInt $value $base $base}
    $requestedFiles=Get-SimplicityValue $Requested 'max_files' $maxFiles
    $requestedTotal=Get-SimplicityValue $Requested 'max_total_loc' $maxTotal
    return [pscustomobject]@{max_files=(Get-SimplicityInt $requestedFiles $maxFiles $maxFiles);max_total_loc=(Get-SimplicityInt $requestedTotal $maxTotal $maxTotal);max_loc_by_category=[pscustomobject]$cats}
}
function Build-OrchestrationWorkerContractFields {
    [CmdletBinding()] param($Descriptor,$Policy)
    $Policy=Get-SimplicityPolicy $Policy
    $principles=@('minimum-sufficient-change','no-bonus-work','reuse-before-create','abstraction-by-evidence','stop-condition')
    $scope=ConvertTo-SimplicityText (Get-SimplicityValue $Descriptor 'summary' (Get-SimplicityValue $Descriptor 'objective' 'bounded task')) 300
    $nonGoals=@(Get-SimplicityValue $Descriptor 'NON_GOALS' (Get-SimplicityValue $Descriptor 'non_goals' @())) | ForEach-Object {ConvertTo-SimplicityText $_ 240} | Where-Object {$_}
    if($nonGoals.Count -eq 0){$nonGoals=@('Unrelated refactors, feature additions, and speculative cleanup outside: '+$scope)}
    $preserve=@(Get-SimplicityValue $Descriptor 'PRESERVE' (Get-SimplicityValue $Descriptor 'preserve' @())) | ForEach-Object {ConvertTo-SimplicityText $_ 240} | Where-Object {$_}
    $reuse=@(Get-SimplicityValue $Descriptor 'reuse_candidates' @()) | ForEach-Object {ConvertTo-SimplicityText $_ 240} | Where-Object {$_}
    $consumer=ConvertTo-SimplicityText (Get-SimplicityValue $Descriptor 'abstraction_consumer' '') 240
    $bounded=ConvertTo-SimplicityText (Get-SimplicityValue $Descriptor 'bounded_question' '') 240
    $stop=ConvertTo-SimplicityText (Get-SimplicityValue $Descriptor 'stop_condition' '') 300
    if(-not $stop){if($bounded){$stop='Stop when sufficient evidence answers: '+$bounded}else{$stop='Stop when acceptance criteria are met; do not expand scope.'}}
    $policyBudget=Get-SimplicityValue $Policy 'change_budget' $null
    $budget=ConvertTo-SimplicityBudget (Get-SimplicityValue $Descriptor 'change_budget' $null) $policyBudget
    $blast=ConvertTo-SimplicityText (Get-SimplicityValue $Descriptor 'expected_blast_radius' 'Task scope only; expand only with evidence and rationale.') 300
    return [pscustomobject]@{principles=$principles;minimum_sufficient_change='Make only the smallest change satisfying acceptance criteria.';no_bonus_work='Do not add unrelated improvements.';reuse_before_create=[pscustomobject]@{instruction='Inspect and reuse existing helpers before creating new ones.';candidate_paths=@($reuse)};abstraction_by_evidence=[pscustomobject]@{instruction='Add abstractions only when a real consumer is declared.';consumer=$consumer;requires_real_consumer=$true};stop_condition=$stop;bounded_question=$bounded;NON_GOALS=@($nonGoals);PRESERVE=@($preserve);CHANGE_BUDGET=$budget;expected_blast_radius=$blast}
}
function Test-OrchestrationChangeBudget {
    [CmdletBinding()] param([object[]]$ChangedFiles,$Budget,[string]$Rationale='')
    if(@($ChangedFiles).Count -gt 200){return [pscustomobject]@{within_budget=$false;exceeded='input-limit-exceeded';reason='input-limit-exceeded: changed_files exceeds 200';changed_files=@($ChangedFiles).Count;total_loc=0;rationale=''}}
    if($null -eq $Budget){$Budget=Get-SimplicityValue (Get-SimplicityPolicy) 'change_budget' $null}
    $maxFiles=0;$maxTotal=0
    if(-not [int]::TryParse([string](Get-SimplicityValue $Budget 'max_files' ''),[ref]$maxFiles) -or -not [int]::TryParse([string](Get-SimplicityValue $Budget 'max_total_loc' ''),[ref]$maxTotal) -or $maxFiles -lt 1 -or $maxTotal -lt 1){return [pscustomobject]@{within_budget=$false;exceeded='input-limit-exceeded';reason='input-limit-exceeded: invalid change budget';changed_files=0;total_loc=0;rationale=''}}
    $byCat=Get-SimplicityValue $Budget 'max_loc_by_category' $null
    $count=0;$total=0;$ratio=1.0
    foreach($f in @($ChangedFiles)) { if($null -eq $f){continue};$path=ConvertTo-SimplicityText (Get-SimplicityValue $f 'path' '') 500;if(-not $path){continue};$count++
        $a=[Math]::Max(0,[int](Get-SimplicityValue $f 'additions' 0));$d=[Math]::Max(0,[int](Get-SimplicityValue $f 'deletions' 0));$loc=$a+$d;$total+=$loc
        $cat='other';if($path -match '(?i)\.tests?\.(ps1|js|ts|py)$|(^|/)tests?/'){$cat='tests'}elseif($path -match '(?i)\.(ps1|psm1|cs|js|jsx|ts|tsx|py|go|rs|java)$'){$cat='code'}elseif($path -match '(?i)\.(md|rst|txt)$'){$cat='docs'}elseif($path -match '(?i)\.(json|jsonc|ya?ml|toml|ini)$'){$cat='config'}
        $lim=0;if(-not [int]::TryParse([string](Get-SimplicityValue $byCat $cat 60),[ref]$lim) -or $lim -lt 1){return [pscustomobject]@{within_budget=$false;exceeded='input-limit-exceeded';reason='input-limit-exceeded: invalid category budget';changed_files=$count;total_loc=$total;rationale=''}};if($loc -gt $lim){$ratio=[Math]::Max($ratio,[double]$loc/[Math]::Max(1,$lim))}
    }
    if($count -gt $maxFiles){$ratio=[Math]::Max($ratio,[double]$count/[Math]::Max(1,$maxFiles))};if($total -gt $maxTotal){$ratio=[Math]::Max($ratio,[double]$total/[Math]::Max(1,$maxTotal))}
    $level='none';if($ratio -gt 2){$level='hard'}elseif($ratio -gt 1){$level='soft'}
    $safeRationale=ConvertTo-SimplicityText $Rationale 500;$hasWhy=(-not [string]::IsNullOrWhiteSpace($safeRationale))
    $status=$level;$within=($level -eq 'none')
    if($level -eq 'soft' -and $hasWhy){$status='soft-accepted';$within=$true}
    elseif($level -eq 'hard' -and $hasWhy){$status='hard-accepted';$within=$true}
    $reason=if($level -eq 'none'){'within-change-budget'}elseif($level -eq 'soft' -and -not $hasWhy){'rationale-required'}elseif($level -eq 'hard' -and -not $hasWhy){'CHANGE_BUDGET_EXCEEDED'}elseif($level -eq 'soft'){'soft overage accepted with rationale'}else{'hard overage accepted with rationale'}
    return [pscustomobject]@{within_budget=$within;exceeded=$status;reason=$reason;changed_files=$count;total_loc=$total;rationale_required=($level -ne 'none');rationale=$safeRationale}
}
function Review-OrchestrationSimplicityFindings {
    <#
    .SYNOPSIS
        Assistive checklist over a pre-categorized DiffSummary; it does not
        inspect or autonomously analyze a raw diff.
    #>
    [CmdletBinding()] param($DiffSummary,$Contract)
    $findings=New-Object 'System.Collections.Generic.List[object]'
    $sourceCount=0;foreach($key in @('unrelated_changes','speculative_abstractions','duplicated_helpers','unjustified_compatibility_layers')){$sourceCount+=@((Get-SimplicityValue $DiffSummary $key @())).Count};if($sourceCount -gt 200){return ,@([pscustomobject]@{type='input-limit-exceeded';detail='input-limit-exceeded: findings inputs exceeds 200'})}
    foreach($spec in @(@('unrelated_changes','unrelated-change','Changes outside declared task scope.'),@('speculative_abstractions','speculative-abstraction','Abstraction lacks evidence/consumer.'),@('duplicated_helpers','duplicate-helper','New helper duplicates an existing helper.'),@('unjustified_compatibility_layers','compatibility-layer','Compatibility layer lacks justification.'))){
        $items=@(Get-SimplicityValue $DiffSummary $spec[0] @());foreach($item in $items){$text=ConvertTo-SimplicityText $item 300;if($text){$findings.Add([pscustomobject]@{type=$spec[1];detail=$text})}}
    }
    if([bool](Get-SimplicityValue $DiffSummary 'abstraction_added' $false) -and -not (Get-SimplicityValue $Contract 'abstraction_by_evidence' $null).consumer){$findings.Add([pscustomobject]@{type='speculative-abstraction';detail='New abstraction has no declared real consumer.'})}
    if($findings.Count -gt 200){return ,@([pscustomobject]@{type='input-limit-exceeded';detail='input-limit-exceeded: findings exceeds 200'})}
    return ,@($findings.ToArray())
}
