$ErrorActionPreference='Stop';$root=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path;Set-Location $root;$out='evidence/issue-50/pinned-versions-audit.test.json';$script=Join-Path $PSScriptRoot 'audit-pinned-versions.ps1';$baseline=@(git -C $root status --porcelain);$protectedBefore=@{}
$protectedPaths=@('templates/opencode.v1.json.tmpl','templates/opencode.v2.json.tmpl','source/agents','source/global/AGENTS.md','source/adapters')
foreach($p in $protectedPaths){if(Test-Path $p){$i=Get-Item $p;if($i.PSIsContainer){$fs=Get-ChildItem $p -File -Recurse}else{$fs=@($i)};foreach($f in $fs){$protectedBefore[$f.FullName]=(Get-FileHash $f.FullName -Algorithm SHA256).Hash}}}
try{
 & $script -OutFile $out -GeneratedAt fixed;$j=Get-Content $out -Raw|ConvertFrom-Json
 if(@($j.declared_pins).Count -ne 5 -or @($j.distinct_literals).Count -ne 3){throw 'pin/literal count mismatch'}
 if($j.counts.path_lines -ne 62 -or $j.counts.REGISTRY_RECORD -ne 25 -or $j.counts.TEST_FIXTURE -ne 26 -or $j.counts.COMMENT_OR_DOC -ne 9 -or $j.counts.PRODUCT_CODE -ne 2 -or $j.counts.UNCLASSIFIED_NEEDS_REVIEW -ne 0){throw 'literal class counts differ from reviewed expected counts'}
 if(@($j.comparators).Count -ne 0 -or $j.comparator_search.comparator_matches -ne 0){throw 'unexpected comparator'};if(!$j.comparator_search.needles -or @($j.comparator_search_hits|Where-Object actual_comparator).Count -ne 0){throw 'directed comparator evidence invalid'};foreach($row in $j.literals){if($null -eq $row.literals -or $row.context -match '[\uFFFD]'){throw 'literal array or UTF-8 context invalid'}}
 $ids=@($j.literals|ForEach-Object{"$($_.path):$($_.line)"});if(@($ids|Select-Object -Unique).Count -ne $ids.Count){throw 'duplicate path:line'}
 if(@($j.reviewed_product_code).Count -ne 2){throw 'manual product review set mismatch'};$productIds=@($j.literals|Where-Object classification -eq PRODUCT_CODE|ForEach-Object{"$($_.path):$($_.line)"}|Sort-Object);if(($productIds -join '|') -ne 'scripts/v3/lib/OrchestrationModelRouter.ps1:2661|scripts/v3/opencode-v2-regression-gate.ps1:71'){throw 'PRODUCT_CODE anchors differ from reviewed set'};foreach($f in $j.protected_files){if((Get-FileHash $f.path -Algorithm SHA256).Hash -ne $f.sha256){throw "protected hash mismatch $($f.path)"}}
 foreach($p in $protectedBefore.Keys){if((Get-FileHash $p -Algorithm SHA256).Hash -ne $protectedBefore[$p]){throw "protected file changed $p"}}
 foreach($u in $j.unparseable){if($u.classification -ne 'UNPARSEABLE'){throw 'UNPARSEABLE was silently resolved'}}
 if($j.scan_scope -contains 'evidence/'){throw 'evidence must not be scanned'}
 $first=Get-Content $out -Raw;& $script -OutFile $out -GeneratedAt fixed;if($first -ne (Get-Content $out -Raw)){throw 'not deterministic'}
 $changed=@(git -C $root status --porcelain|Where-Object{$_ -notmatch [regex]::Escape($out)});if(($changed -join "`n") -ne ($baseline -join "`n")){throw 'write outside OutFile'};'PASS audit-pinned-versions'
}finally{Remove-Item $out -ErrorAction SilentlyContinue}
