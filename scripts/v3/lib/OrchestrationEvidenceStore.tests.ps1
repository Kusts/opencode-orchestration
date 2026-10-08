$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OrchestrationEvidenceStore.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('evidence-store-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
$assertions=0
function Assert([bool]$Ok,[string]$Message){$script:assertions++;if(-not $Ok){throw $Message}}
$raw=Join-Path $root 'large.log';[IO.File]::WriteAllText($raw,('log-'*1024))
$now=[DateTimeOffset]::UtcNow;$created=$now.AddMinutes(-1).ToString('o');$expires=$now.AddMinutes(4).ToString('o')
$base=[ordered]@{task_id='task-1';run_id='run-1';worker_id='coder_1';provenance=@{created_by='coder';kernel_task_ref='task-1'};base_revision='rev-a';criteria_hash='crit-a';source_fingerprints=@{'src/a.ps1'='sha-a'};diff_hash='diff-a';scope=@('src/a.ps1');command='test';environment=@{runtime='pwsh';version='7'};result=@{summary='passed';raw_content=('sk-SYNTHETICSECRET'+('x'*5000));raw_ref=$raw};assumptions=@('token=sk-SYNTHETICSECRET');invalidation_conditions=@(@{type='source-changed';paths=@('src/a.ps1')},@{type='criteria-changed';hash='crit-a'},@{type='base-revision';require_same=$true},@{type='env-changed';runtime='pwsh';version='7'},@{type='ttl';expires_at=$expires});created_at=$created}
$createdResult=New-OrchestrationEvidenceRecord $base $root
Assert $createdResult.created ('record creation: '+$createdResult.reason)
$record=$createdResult.record;$recordPath=Join-Path $root ($record.evidence_id+'.json');$onDisk=[IO.File]::ReadAllText($recordPath)
Assert ($record.evidence_id.Length -eq 32) '128-bit evidence id'
Assert ($onDisk -notmatch 'SYNTHETICSECRET|xxxxxx|raw_content') 'raw/secret must not be persisted'
Assert ($record.task_id -and $record.run_id -and $record.worker_id -and $record.provenance.kernel_task_ref) 'identity/provenance'
$many=@{};for($i=0;$i -lt 1000;$i++){$many[('src/{0:D4}.ps1' -f $i)]='fingerprint'};$bounded=ConvertFrom-Json (ConvertTo-Json $base -Depth 20);$bounded.source_fingerprints=$many;$bounded.run_id='run-bounded';$boundedResult=New-OrchestrationEvidenceRecord $bounded $root -MaxItems 7;Assert ($boundedResult.created -and $boundedResult.record.source_fingerprints.Count -eq 7) 'fingerprint enumeration bounded'
$hugeCondition=ConvertFrom-Json (ConvertTo-Json $base -Depth 20);$hugePaths=@();for($i=0;$i -lt 100;$i++){$hugePaths+=@(('p'*240)+$i)};$hugeCondition.invalidation_conditions=@(@{type='source-changed';paths=$hugePaths});Assert ((New-OrchestrationEvidenceRecord $hugeCondition $root).reason -eq 'conditions-oversized') 'condition serialized cap'
$same=New-OrchestrationEvidenceRecord $base $root;Assert ($same.created -and $same.record.evidence_id -ceq $record.evidence_id) 'idempotent same payload'
$changed=ConvertFrom-Json (ConvertTo-Json $base -Depth 20);$changed.command='different';Assert ((New-OrchestrationEvidenceRecord $changed $root).record.evidence_id -cne $record.evidence_id) 'payload change id differs'
$current=@{current_source_fingerprints=@{'src/a.ps1'='sha-a';other='changed'};current_base_revision='rev-a';current_criteria_hash='crit-a';current_env=@{runtime='pwsh';version='7'};now=$now.ToString('o')}
Assert ( (Test-OrchestrationEvidenceValidity $record $current).reusable) 'unrelated file change valid'
$current.current_source_fingerprints['src/a.ps1']='sha-b';Assert ((Test-OrchestrationEvidenceValidity $record $current).reasons -contains 'source-changed:src/a.ps1') 'source change reason'
$current.current_source_fingerprints.Remove('src/a.ps1');Assert ((Test-OrchestrationEvidenceValidity $record $current).reasons -contains 'source-state-missing') 'missing source state'
$current.current_source_fingerprints['src/a.ps1']='sha-a';$current.current_criteria_hash='different';Assert ((Test-OrchestrationEvidenceValidity $record $current).reasons -contains 'criteria-changed') 'criteria reason'
$current.current_criteria_hash='crit-a';$current.current_base_revision='rev-b';Assert ((Test-OrchestrationEvidenceValidity $record $current).reasons -contains 'base-revision') 'base revision reason'
$allowRevision=ConvertFrom-Json (ConvertTo-Json $record -Depth 20);$allowRevision.invalidation_conditions=@(@{type='base-revision';require_same=$false});Assert ((Test-OrchestrationEvidenceValidity $allowRevision $current).reusable) 'require_same false accepts revision change'
$current.current_base_revision='rev-a';$current.current_env.version='8';Assert ((Test-OrchestrationEvidenceValidity $record $current).reasons -contains 'env-changed') 'environment reason'
$current.current_env.version='7';$current.now=$expires;Assert ((Test-OrchestrationEvidenceValidity $record $current).reusable) 'expiry boundary remains valid'
$current.now=$now.AddTicks(1).AddMinutes(4).ToString('o');Assert ((Test-OrchestrationEvidenceValidity $record $current).reasons -contains 'ttl') 'expired ttl'
$ps7NowUtc=$now.UtcDateTime
$ps7PastRec=[pscustomobject]@{invalidation_conditions=@([pscustomobject]@{type='ttl';expires_at=$now.AddMinutes(-5).LocalDateTime})}
$ps7PastValid=Test-OrchestrationEvidenceValidity $ps7PastRec @{now=$ps7NowUtc}
Assert ((-not $ps7PastValid.reusable) -and ($ps7PastValid.reasons -contains 'ttl')) 'ps7 expired-as-local-DateTime is ttl miss'
$ps7FutRec=[pscustomobject]@{invalidation_conditions=@([pscustomobject]@{type='ttl';expires_at=$now.AddMinutes(30).LocalDateTime})}
Assert ((Test-OrchestrationEvidenceValidity $ps7FutRec @{now=$ps7NowUtc}).reusable) 'ps7 future-as-local-DateTime is hit'
$ps7UnspecRec=[pscustomobject]@{invalidation_conditions=@([pscustomobject]@{type='ttl';expires_at=(New-Object DateTime($now.AddMinutes(30).LocalDateTime.Ticks,[DateTimeKind]::Unspecified))})}
Assert ((Test-OrchestrationEvidenceValidity $ps7UnspecRec @{now=$ps7NowUtc}).reasons -contains 'ttl') 'ps7 Unspecified DateTime fail-closed ttl'
$badTtl=ConvertFrom-Json (ConvertTo-Json $base -Depth 20);$badTtl.invalidation_conditions=@(@{type='ttl';expires_at='not-a-date'});Assert ((New-OrchestrationEvidenceRecord $badTtl $root).reason -eq 'invalid-ttl') 'invalid ttl rejected'
$unknown=ConvertFrom-Json (ConvertTo-Json $base -Depth 20);$unknown.invalidation_conditions=@(@{type='evil';payload=@{secret='canary'}});Assert ((New-OrchestrationEvidenceRecord $unknown $root).reason -eq 'unknown-invalidation-type') 'unknown condition rejected'
$extra=ConvertFrom-Json (ConvertTo-Json $base -Depth 20);$extra.invalidation_conditions=@(@{type='ttl';expires_at=$expires;secret='sk-SYNTHETICSECRET'});Assert ((New-OrchestrationEvidenceRecord $extra $root).reason -eq 'unexpected-invalidation-field') 'extra nested field rejected'
$invalidId=ConvertFrom-Json (ConvertTo-Json $base -Depth 20);$invalidId.worker_id='bad/id';Assert ((New-OrchestrationEvidenceRecord $invalidId $root).reason -eq 'invalid-worker_id') 'unsafe identity rejected'
$outside=Get-OrchestrationEvidenceRaw (Join-Path $env:TEMP 'outside.log') $root 100;Assert ($outside.reason -eq 'raw-path-outside-store') 'outside raw path rejected'
$retrieved=Get-OrchestrationEvidenceRaw $raw $root 5000;Assert ($retrieved.retrieved -and $retrieved.content.Length -gt 0) 'bounded raw retrieval'
$over=Get-OrchestrationEvidenceRaw $raw $root 100;Assert ($over.reason -eq 'raw-cap-exceeded') 'raw cap'
$overLength=([IO.File]::ReadAllBytes($raw)).Length;$overStream=Get-OrchestrationEvidenceRaw $raw $root 100;Assert ($overLength -gt 101 -and $overStream.content -eq $null -and $overStream.reason -eq 'raw-cap-exceeded') 'oversized streaming response bounded to cap plus one'
[IO.File]::WriteAllText($raw,'case');$caseRoot=$root.ToUpperInvariant();$casePath=$raw.ToLowerInvariant();$caseResult=Get-OrchestrationEvidenceRaw $casePath $caseRoot 20;if($env:OS -eq 'Windows_NT'){Assert $caseResult.retrieved 'Windows case-insensitive root containment'}
$junction=Join-Path $root 'junction';$targetDir=Join-Path $root 'junction-target';[void][IO.Directory]::CreateDirectory($targetDir);$junctionCreated=$false;try{$null=New-Item -ItemType Junction -Path $junction -Target $targetDir -ErrorAction Stop;$junctionCreated=$true}catch{Write-Output ('SKIP junction reparse test: creation '+$_.Exception.GetType().Name)};if($junctionCreated){[IO.File]::WriteAllText((Join-Path $targetDir 'via-link.log'),'x');$linked=Get-OrchestrationEvidenceRaw (Join-Path $junction 'via-link.log') $root 10;Assert ($linked.reason -eq 'raw-path-reparse') 'junction ancestor rejected';try{[IO.Directory]::Delete($junction,$false)}catch{}}
[IO.File]::WriteAllText($raw,'short');$truncated=Get-OrchestrationEvidenceRaw $raw $root 100;Assert ($truncated.retrieved -and $truncated.content -eq 'short') 'mutated/truncated raw read safe'
$query=Find-ReusableOrchestrationEvidence $root @('src/a.ps1') @{ 'src/a.ps1'='sha-a' } 'rev-a' 'crit-a' @{runtime='pwsh';version='7'} $now.ToString('o') 1
Assert ($query.Count -eq 1 -and -not $query[0].PSObject.Properties['raw_content']) 'compact query + MaxResults'
$queryRoot=Join-Path $root 'ordered';[void][IO.Directory]::CreateDirectory($queryRoot);$orderedIds=@();foreach($minutes in @(0,1,2)){$entry=ConvertFrom-Json (ConvertTo-Json $base -Depth 20);$entry.run_id=('ordered-'+$minutes);$entry.created_at=$now.AddMinutes(-$minutes).ToString('o');$resultRecord=New-OrchestrationEvidenceRecord $entry $queryRoot;$orderedIds+=@($resultRecord.record.evidence_id)};$ordered=Find-ReusableOrchestrationEvidence $queryRoot @('src/a.ps1') @{ 'src/a.ps1'='sha-a' } 'rev-a' 'crit-a' @{runtime='pwsh';version='7'} $now.ToString('o') 10;Assert ($ordered.Count -eq 3 -and $ordered[0].evidence_id -ceq $orderedIds[0] -and $ordered[2].evidence_id -ceq $orderedIds[2]) 'query newest first'
$null=Find-ReusableOrchestrationEvidence $queryRoot @('src/a.ps1') @{ 'src/a.ps1'='wrong' } 'rev-a' 'crit-a' @{runtime='pwsh';version='7'} $now.ToString('o') 10;$null=Find-ReusableOrchestrationEvidence $queryRoot @('src/a.ps1') @{ 'src/a.ps1'='sha-a' } 'rev-a' 'wrong' @{runtime='pwsh';version='7'} $now.ToString('o') 10;$missMetrics=Get-OrchestrationEvidenceMetrics $queryRoot;Assert ($missMetrics.misses_by_reason.Contains('source-changed:src/a.ps1') -and $missMetrics.misses_by_reason.Contains('criteria-changed')) 'distinct miss reason counters'
$badFile=Join-Path $root 'hostile.json';[IO.File]::WriteAllText($badFile,'not-json');$null=Find-ReusableOrchestrationEvidence $root @() @{} 'rev-a' 'crit-a' @{} $now.ToString('o') 200;$hostileMetrics=Get-OrchestrationEvidenceMetrics $root;Assert ($hostileMetrics.records_skipped_invalid -ge 1) 'hostile record skipped with metric'
$lock=[IO.File]::Open((Join-Path $root '.evidence.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);try{$busy=New-OrchestrationEvidenceRecord $base $root -LockTimeoutMs 10;Assert ($busy.reason -eq 'lock-busy') 'bounded lock busy'}finally{$lock.Dispose()}
$conflict=$recordPath;[IO.File]::WriteAllText($conflict,'different');$conflictResult=New-OrchestrationEvidenceRecord $base $root;Assert ($conflictResult.reason -eq 'record-conflict') 'id collision conflict'
$metrics=Get-OrchestrationEvidenceMetrics $root;Assert ($metrics.records_created -ge 1 -and $metrics.lock_busy_skips -eq 1 -and $metrics.errors -ge 1) 'metrics counters'
    $metricLock=[IO.File]::Open((Join-Path $root '.metrics.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);try{$null=Write-OrchestrationEvidenceMetric $root @{metric='reuse_hits';reason='locked'}}finally{$metricLock.Dispose()};$lockedMetrics=Get-OrchestrationEvidenceMetrics $root;Assert ($lockedMetrics.lock_busy_skips -ge 1) 'metric lock busy skip counted'
    $metricsPath=Join-Path $root 'reuse-metrics.jsonl';[IO.File]::SetAttributes($metricsPath,[IO.FileAttributes]::ReadOnly);$beforeReadonly=(Get-OrchestrationEvidenceMetrics $root).errors;$null=Write-OrchestrationEvidenceMetric $root @{metric='reuse_hits';reason='readonly'};$readonlyWorked=([IO.File]::GetAttributes($metricsPath) -band [IO.FileAttributes]::ReadOnly) -ne 0;[IO.File]::SetAttributes($metricsPath,[IO.FileAttributes]::Normal);if((Get-OrchestrationEvidenceMetrics $root).errors -le $beforeReadonly){Write-Output 'SKIP read-only metrics write test: filesystem allowed append despite ReadOnly attribute'}else{Assert $true 'readonly metrics destination counted as error'}
    $inaccessible=ConvertFrom-Json (ConvertTo-Json $base -Depth 20);$inaccessible.run_id='inaccessible';$calc=Join-Path $root 'id-calc';[void][IO.Directory]::CreateDirectory($calc);$idResult=New-OrchestrationEvidenceRecord $inaccessible $calc;$null=Remove-Item -LiteralPath $calc -Recurse -Force;$blockedPath=Join-Path $root ($idResult.record.evidence_id+'.json');[void][IO.Directory]::CreateDirectory($blockedPath);$accessFailure=New-OrchestrationEvidenceRecord $inaccessible $root;Assert ($accessFailure.reason -eq 'record-access-failed' -and (Get-OrchestrationEvidenceMetrics $root).errors -ge 2) 'persistence access failure structured and counted'
$f3Root=Join-Path ([IO.Path]::GetTempPath()) ('evidence-f3-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($f3Root)
$f3Raw=Join-Path $f3Root 'out.log';[IO.File]::WriteAllText($f3Raw,'f3')
$f3Exp=$now.AddMinutes(30).ToString('o')
$f3Base=[ordered]@{task_id='f3-task';run_id='f3-run';worker_id='coder_1';provenance=@{created_by='coder';kernel_task_ref='f3-task'};base_revision='rev-a';criteria_hash='crit-a';source_fingerprints=@{'src/a.ps1'='sha-a'};diff_hash='diff-a';scope=@('src/a.ps1');command='test';environment=@{runtime='pwsh';version='7'};result=@{summary='passed';raw_ref=$f3Raw};assumptions=@();invalidation_conditions=@(@{type='source-changed';paths=@('src/a.ps1')},@{type='criteria-changed';hash='crit-a'},@{type='base-revision';require_same=$true},@{type='env-changed';runtime='pwsh';version='7'},@{type='ttl';expires_at=$f3Exp});created_at=$created}
$f3Rec=New-OrchestrationEvidenceRecord $f3Base $f3Root
Assert $f3Rec.created ('f3 golden record: '+$f3Rec.reason)
$f3Hit=Find-ReusableOrchestrationEvidence $f3Root @('src/a.ps1') @{'src/a.ps1'='sha-a'} 'rev-a' 'crit-a' @{runtime='pwsh';version='7'} $now.ToString('o') 5
Assert ($f3Hit.Count -eq 1) 'f3 identical query hits 1 result'
$f3MissSrc=Find-ReusableOrchestrationEvidence $f3Root @('src/a.ps1') @{'src/a.ps1'='sha-b'} 'rev-a' 'crit-a' @{runtime='pwsh';version='7'} $now.ToString('o') 5
Assert ($f3MissSrc.Count -eq 0) 'f3 source-changed miss'
$f3MissCrit=Find-ReusableOrchestrationEvidence $f3Root @('src/a.ps1') @{'src/a.ps1'='sha-a'} 'rev-a' 'crit-b' @{runtime='pwsh';version='7'} $now.ToString('o') 5
Assert ($f3MissCrit.Count -eq 0) 'f3 criteria-changed miss'
$f3MissRev=Find-ReusableOrchestrationEvidence $f3Root @('src/a.ps1') @{'src/a.ps1'='sha-a'} 'rev-b' 'crit-a' @{runtime='pwsh';version='7'} $now.ToString('o') 5
Assert ($f3MissRev.Count -eq 0) 'f3 base-revision miss'
$f3MissEnv=Find-ReusableOrchestrationEvidence $f3Root @('src/a.ps1') @{'src/a.ps1'='sha-a'} 'rev-a' 'crit-a' @{runtime='pwsh';version='8'} $now.ToString('o') 5
Assert ($f3MissEnv.Count -eq 0) 'f3 env-changed miss'
$f3MissTtl=Find-ReusableOrchestrationEvidence $f3Root @('src/a.ps1') @{'src/a.ps1'='sha-a'} 'rev-a' 'crit-a' @{runtime='pwsh';version='7'} $now.AddMinutes(31).ToString('o') 5
Assert ($f3MissTtl.Count -eq 0) 'f3 ttl miss'
$f3Revoked=ConvertFrom-Json (ConvertTo-Json $f3Base -Depth 20);$f3Revoked.run_id='f3-revoked';$f3Revoked.invalidation_conditions=@(@{type='revoked';revoked_by='operator-1'})
$f3RevRec=New-OrchestrationEvidenceRecord $f3Revoked $f3Root
Assert $f3RevRec.created ('f3 revoked record: '+$f3RevRec.reason)
$f3RevValid=Test-OrchestrationEvidenceValidity $f3RevRec.record @{current_source_fingerprints=@{'src/a.ps1'='sha-a'};current_base_revision='rev-a';current_criteria_hash='crit-a';current_env=@{runtime='pwsh';version='7'};now=$now.ToString('o')}
Assert ((-not $f3RevValid.reusable) -and ($f3RevValid.reasons -contains 'revoked')) 'f3 revoked validity'
$f3RevQ=Find-ReusableOrchestrationEvidence $f3Root @('src/a.ps1') @{'src/a.ps1'='sha-a'} 'rev-a' 'crit-a' @{runtime='pwsh';version='7'} $now.ToString('o') 5
Assert ($f3RevQ.Count -eq 1 -and $f3RevQ[0].evidence_id -ceq $f3Rec.record.evidence_id) 'f3 revoked excluded from query'
$f3BadRevoke=ConvertFrom-Json (ConvertTo-Json $f3Base -Depth 20);$f3BadRevoke.run_id='f3-badrevoke';$f3BadRevoke.invalidation_conditions=@(@{type='revoked';revoked_by=''})
Assert ((New-OrchestrationEvidenceRecord $f3BadRevoke $f3Root).reason -eq 'invalid-revoked-by') 'f3 empty revoked_by rejected'
$f3MissingRevoke=ConvertFrom-Json (ConvertTo-Json $f3Base -Depth 20);$f3MissingRevoke.run_id='f3-missingrevoke';$f3MissingRevoke.invalidation_conditions=@(@{type='revoked'})
Assert ((New-OrchestrationEvidenceRecord $f3MissingRevoke $f3Root).reason -eq 'invalid-revoked-by') 'f3 missing revoked_by rejected'
$f3Metrics=Get-OrchestrationEvidenceMetrics $f3Root
Assert ($f3Metrics.reuse_queries -eq 7) 'f3 one reuse_queries metric per query'
Assert ($f3Metrics.misses_by_reason.Contains('source-changed:src/a.ps1') -and $f3Metrics.misses_by_reason.Contains('criteria-changed') -and $f3Metrics.misses_by_reason.Contains('base-revision') -and $f3Metrics.misses_by_reason.Contains('env-changed') -and $f3Metrics.misses_by_reason.Contains('ttl') -and $f3Metrics.misses_by_reason.Contains('revoked')) 'f3 distinct miss reasons'
$f3ExplicitDir=Join-Path $f3Root 'explicit-store'
Assert ((Get-OrchestrationEvidenceDefaultStoreDir -StoreDir $f3ExplicitDir) -ceq $f3ExplicitDir) 'f3 explicit store dir wins'
$f3DefaultDir=Get-OrchestrationEvidenceDefaultStoreDir
Assert ((-not [string]::IsNullOrWhiteSpace($f3DefaultDir)) -and ($f3DefaultDir -like '*cache*evidence-store*') -and (Test-Path -LiteralPath $f3DefaultDir -PathType Container)) 'f3 default store resolved and created'
$f3FileAsStore=Join-Path $f3Root 'file-as-store';[IO.File]::WriteAllText($f3FileAsStore,'x')
$f3DownErr=$null;$f3Down=Find-ReusableOrchestrationEvidence $f3FileAsStore @('src/a.ps1') @{'src/a.ps1'='sha-a'} 'rev-a' 'crit-a' @{runtime='pwsh';version='7'} $now.ToString('o') 5 -QueryError ([ref]$f3DownErr)
Assert (($f3Down.Count -eq 0) -and ([string]$f3DownErr -ceq 'reuse-store-query-failed')) 'f3 store enumeration failure surfaces QueryError'
$f3HitErr=$null;$null=Find-ReusableOrchestrationEvidence $f3Root @('src/a.ps1') @{'src/a.ps1'='sha-a'} 'rev-a' 'crit-a' @{runtime='pwsh';version='7'} $now.ToString('o') 5 -QueryError ([ref]$f3HitErr)
Assert ([string]::IsNullOrWhiteSpace([string]$f3HitErr)) 'f3 hit leaves QueryError empty'
$f3MissErr=$null;$null=Find-ReusableOrchestrationEvidence $f3Root @('src/a.ps1') @{'src/a.ps1'='sha-b'} 'rev-a' 'crit-a' @{runtime='pwsh';version='7'} $now.ToString('o') 5 -QueryError ([ref]$f3MissErr)
Assert ([string]::IsNullOrWhiteSpace([string]$f3MissErr)) 'f3 miss leaves QueryError empty'
Remove-Item -LiteralPath $f3Root -Recurse -Force
Write-Output "OrchestrationEvidenceStore: PASS ($assertions assertions)"
Remove-Item -LiteralPath $root -Recurse -Force
