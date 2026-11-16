[CmdletBinding()]
param(
    [string[]]$SkillRoots = @((Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'skills-core'), (Join-Path $HOME '.config\opencode\skills')),
    [AllowEmptyString()][string]$Query = '', [int]$Limit = 5, [int]$Iterations = 10, [switch]$Json, [switch]$SkipReparse
)
$ErrorActionPreference = 'Stop'
function Stop-Metrics([string]$Message) { [Console]::Error.WriteLine($Message); exit 2 }
if ($Limit -lt 1 -or $Limit -gt 20) { Stop-Metrics 'Limit must be between 1 and 20.' }
if ($Iterations -lt 1 -or $Iterations -gt 50) { Stop-Metrics 'Iterations must be between 1 and 50.' }

function Get-SkillScan {
    param([string[]]$Roots)
    $items = New-Object System.Collections.Generic.List[object]
    $rootStats = New-Object System.Collections.Generic.List[object]
    foreach ($rootInput in $Roots) {
        $root = [IO.Path]::GetFullPath($rootInput)
        $valid=0; $invalid=0; $unreadable=0; $metaChars=0; $bodyCharsTotal=0; $exists=$false; $children=@();$unreadableReasons=New-Object System.Collections.Generic.List[string]
        try {
            if (Test-Path -LiteralPath $root -PathType Container) { $exists=$true; $children=@(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction Stop) }
        } catch { $exists=$true; $unreadable++ }
        foreach ($dir in $children) {
            try {
                if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    if ($SkipReparse) { $script:skippedReparse++; continue }
                    # Follow reparse points by default because the runtime resolves these links; reads remain limited to SKILL.md and never execute content. SkipReparse is for source-origin auditing.
                    $script:followedReparse++
                }
                $file=Join-Path $dir.FullName 'SKILL.md'
                if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
                $fileInfo=Get-Item -LiteralPath $file -Force -ErrorAction Stop
                if (($fileInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    if ($SkipReparse) { $script:skippedReparse++; continue }
                    $script:followedReparse++
                }
                if ($fileInfo.Length -gt 1MB) { $unreadable++;$unreadableReasons.Add('too_large');continue }
                $bytes=[IO.File]::ReadAllBytes($file)
                $text=[Text.Encoding]::UTF8.GetString($bytes)
                $lines=@($text -split "`r?`n")
                if ($lines.Count -gt 0) { $lines[0]=$lines[0].TrimStart([char]0xFEFF) }
                if ($lines.Count -lt 3 -or $lines[0].Trim() -ne '---') { $invalid++; continue }
                $end=-1
                for($i=1;$i -lt $lines.Count;$i++){if($lines[$i].Trim() -eq '---'){$end=$i;break}}
                if($end -lt 0){$invalid++;continue}
                $name='';$description='';$unsupported=$false;$nameSeen=$false;$descriptionSeen=$false
                # YAML-lite only: top-level scalar keys, single-line values; block scalars are unsupported.
                for($i=1;$i -lt $end;$i++){
                    if(-not $nameSeen -and $lines[$i] -cmatch '^name:\s*(.*?)\s*$'){$nameSeen=$true;$name=$matches[1].Trim().Trim('"').Trim("'")}
                    if(-not $descriptionSeen -and $lines[$i] -cmatch '^description:\s*(.*?)\s*$'){$descriptionSeen=$true
                        $value=$matches[1].Trim().Trim('"').Trim("'")
                        if($value -eq '>' -or $value -eq '|'){$unsupported=$true;$description=''}else{$description=$value}
                    }
                }
                if([string]::IsNullOrWhiteSpace($name)){$invalid++;continue}
                $bodyOffset=0;$newlineCount=0
                for($i=0;$i -lt $bytes.Length -and $newlineCount -lt ($end+1);$i++){if($bytes[$i] -eq 10){$newlineCount++;$bodyOffset=$i+1}}
                if($newlineCount -lt ($end+1)){$bodyOffset=$bytes.Length}
                $bodyBytes=$bytes.Length-$bodyOffset
                $body=if($bodyOffset -lt $bytes.Length){[Text.Encoding]::UTF8.GetString($bytes,$bodyOffset,$bodyBytes)}else{''}
                $meta=$name.Length+$description.Length
                $relative=$dir.Name
                $sha=[Convert]::ToBase64String(([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)))
                $items.Add([pscustomobject]@{name=$name;root=$root;relative_dir=$relative;metadata_chars=$meta;body_bytes=$bodyBytes;body_chars=$body.Length;metadata_tokens_est=[int][Math]::Ceiling($meta/4.0);body_tokens_est=[int][Math]::Ceiling($body.Length/4.0);description=$description;unsupported_frontmatter=$unsupported;sha256=$sha})
                $valid++;$metaChars+=$meta;$bodyCharsTotal+=$body.Length
            } catch { $unreadable++;$unreadableReasons.Add('read_error') }
        }
        $rootStats.Add([pscustomobject]@{root=$root;exists=$exists;skills_total=$valid;invalid=$invalid;unreadable=$unreadable;unreadable_reasons=@($unreadableReasons.ToArray());metadata_chars_total=$metaChars;metadata_tokens_est_total=[int][Math]::Ceiling($metaChars/4.0);body_chars_total=$bodyCharsTotal;body_tokens_est_total=[int][Math]::Ceiling($bodyCharsTotal/4.0);body_over_metadata_ratio=$(if($metaChars){[Math]::Round($bodyCharsTotal/[double]$metaChars,2)}else{0.0})})
    }
    return [pscustomobject]@{items=@($items.ToArray());roots=@($rootStats.ToArray());skipped_reparse=$script:skippedReparse;followed_reparse=$script:followedReparse}
}
$times=New-Object System.Collections.Generic.List[double];$scan=$null
for($i=0;$i -lt $Iterations;$i++){$script:skippedReparse=0;$script:followedReparse=0;$watch=[Diagnostics.Stopwatch]::StartNew();$scan=Get-SkillScan -Roots $SkillRoots;$watch.Stop();$times.Add($watch.Elapsed.TotalMilliseconds)}
$sortedTimes=@($times.ToArray()|Sort-Object);$p50Index=[int][Math]::Floor(($Iterations-1)*0.5);$p95Index=[Math]::Max(0,[int][Math]::Ceiling($Iterations*0.95)-1)
$agg=[ordered]@{skills_total=0;invalid=0;unreadable=0;metadata_chars_total=0;metadata_tokens_est_total=0;body_chars_total=0;body_tokens_est_total=0;body_over_metadata_ratio=0.0}
foreach($r in $scan.roots){foreach($k in @('skills_total','invalid','unreadable','metadata_chars_total','metadata_tokens_est_total','body_chars_total','body_tokens_est_total')){$agg[$k]+=[long]$r.$k}}
if($agg.metadata_chars_total){$agg.body_over_metadata_ratio=[Math]::Round($agg.body_chars_total/[double]$agg.metadata_chars_total,2)}
# Ordinal order defines canonical occurrences: root, relative directory, then name.
$orderedList=New-Object 'System.Collections.Generic.List[object]';foreach($skill in $scan.items){$orderedList.Add($skill)}
$ordinalCompare=[System.Comparison[object]]{param($left,$right);$c=[string]::CompareOrdinal($left.root,$right.root);if($c -eq 0){$c=[string]::CompareOrdinal($left.relative_dir,$right.relative_dir)};if($c -eq 0){$c=[string]::CompareOrdinal($left.name,$right.name)};return $c}
$orderedList.Sort($ordinalCompare);$orderedItems=@($orderedList.ToArray())
$byName=New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
foreach($skill in $orderedItems){if(-not $byName.ContainsKey($skill.name)){$byName.Add($skill.name,$skill)}}
$uniqueMeta=0;$uniqueBodyChars=0;foreach($skill in $byName.Values){$uniqueMeta+=$skill.metadata_chars;$uniqueBodyChars+=$skill.body_chars}
$uniqueTokens=[int][Math]::Ceiling($uniqueMeta/4.0)
$duplicateGroups=New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
foreach($skill in $orderedItems){if(-not $duplicateGroups.ContainsKey($skill.name)){$duplicateGroups.Add($skill.name,(New-Object System.Collections.Generic.List[object]))};$duplicateGroups[$skill.name].Add($skill)}
$duplicateNamesList=New-Object 'System.Collections.Generic.List[object]'
foreach($name in $duplicateGroups.Keys){$group=@($duplicateGroups[$name].ToArray());if($group.Count -gt 1){$rootSet=New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::Ordinal);foreach($entry in $group){[void]$rootSet.Add($entry.root)};$roots=@($rootSet);$hashes=@($group|ForEach-Object{$_.sha256}|Select-Object -Unique);$duplicateNamesList.Add([pscustomobject]@{name=$name;occurrences=$group.Count;differs=($hashes.Count -gt 1);roots=$roots})}}
$duplicateNameList=New-Object 'System.Collections.Generic.List[object]';foreach($dupe in $duplicateNamesList){$duplicateNameList.Add($dupe)}
$duplicateNameList.Sort([System.Comparison[object]]{param($left,$right);[string]::CompareOrdinal($left.name,$right.name)});$duplicateNames=@($duplicateNameList.ToArray())
$terms=@();if(-not [string]::IsNullOrWhiteSpace($Query)){$terms=@([regex]::Matches($Query.ToLowerInvariant(),'[\p{L}\p{N}_-]{3,}')|ForEach-Object{$_.Value}|Select-Object -Unique)}
$selected=@();$selectedTokens=0;$coverage=0;$ratio=0.0
$uniqueTokenDenominator=$uniqueTokens
if($terms.Count){$ranked=@($byName.Values|ForEach-Object{$hay=($_.name+' '+$_.description).ToLowerInvariant();$matched=@($terms|Where-Object{$hay.Contains($_)});[pscustomobject]@{skill=$_;score=$matched.Count;terms=$matched}}|Where-Object{$_.score -gt 0})
    $rankList=New-Object 'System.Collections.Generic.List[object]';foreach($entry in $ranked){$rankList.Add($entry)}
    $rankList.Sort([System.Comparison[object]]{param($left,$right);$c=$right.score.CompareTo($left.score);if($c -eq 0){$c=[string]::CompareOrdinal($left.skill.name,$right.skill.name)};if($c -eq 0){$c=[string]::CompareOrdinal($left.skill.root,$right.skill.root)};return $c})
    $uniqueRanked=@($rankList.ToArray())
    $top=@($uniqueRanked|Select-Object -First $Limit);$covered=@{};foreach($entry in $top){foreach($term in $entry.terms){$covered[$term]=$true};$selected+=,[ordered]@{name=$entry.skill.name;root=$entry.skill.root;score=$entry.score};$selectedTokens+=$entry.skill.metadata_tokens_est};$coverage=$covered.Count
    if($uniqueTokenDenominator){$ratio=[Math]::Round($selectedTokens/[double]$uniqueTokenDenominator,4)}
}
$uniqueTotals=[ordered]@{skills_total=$byName.Count;metadata_chars_total=$uniqueMeta;metadata_tokens_est_total=$uniqueTokens;body_chars_total=$uniqueBodyChars;body_tokens_est_total=[int][Math]::Ceiling($uniqueBodyChars/4.0);body_over_metadata_ratio=$(if($uniqueMeta){[Math]::Round($uniqueBodyChars/[double]$uniqueMeta,2)}else{0.0})}
$publicSkills=@($scan.items|Sort-Object name,root,relative_dir|ForEach-Object{[ordered]@{name=$_.name;root=$_.root;relative_dir=$_.relative_dir;metadata_chars=$_.metadata_chars;body_bytes=$_.body_bytes;metadata_tokens_est=$_.metadata_tokens_est;body_tokens_est=$_.body_tokens_est;unsupported_frontmatter=$_.unsupported_frontmatter}})
$result=[ordered]@{schema_version=1;ok=$true;estimator='chars/4';baseline=$agg;roots=@($scan.roots);skills=$publicSkills;duplicate_names=$duplicateNames;unique_name_totals=$uniqueTotals;followed_reparse=$scan.followed_reparse;skipped_reparse=$scan.skipped_reparse;timing=[ordered]@{scan_ms_p50=[Math]::Round($sortedTimes[$p50Index],3);scan_ms_p95=[Math]::Round($sortedTimes[$p95Index],3);scan_ms_max=[Math]::Round($sortedTimes[-1],3);deterministic=$false};selected=@($selected);selected_metadata_tokens_est=$selectedTokens;selection_ratio_vs_unique=$ratio;selected_coverage=$coverage}
if($Json){Write-Output (ConvertTo-Json -InputObject $result -Depth 8 -Compress)}else{Write-Output ('Skills: {0}; invalid: {1}; unreadable: {2}; metadata tokens (est. chars/4): {3}; body/metadata: {4}; scan ms (não determinística) p50/p95/max: {5}/{6}/{7}' -f $agg.skills_total,$agg.invalid,$agg.unreadable,$agg.metadata_tokens_est_total,$agg.body_over_metadata_ratio,$result.timing.scan_ms_p50,$result.timing.scan_ms_p95,$result.timing.scan_ms_max)}
