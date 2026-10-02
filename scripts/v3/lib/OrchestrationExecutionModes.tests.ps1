$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OrchestrationExecutionModes.ps1')
$script:passed=0
function Assert([bool]$Condition,[string]$Name){if(-not $Condition){throw "FAIL: $Name"};$script:passed++}
$policy=Get-Content (Join-Path $PSScriptRoot '../../../source/registry/execution-modes-policy.json') -Raw | ConvertFrom-Json
$a=Get-OrchestrationExecutionMode @{task_shape='fixed_pipeline'} $policy
Assert ($a.mode -eq 'A') 'fixed pipeline'
$c=Get-OrchestrationExecutionMode @{task_shape='single_lookup'} $policy
Assert ($c.mode -eq 'C') 'lookup one-shot'
$enabled=ConvertFrom-Json (ConvertTo-Json @{specialist_enabled=$true;runtime_caps=@{v1_persistent_specialist=$true}} -Compress)
$b=Get-OrchestrationExecutionMode @{task_shape='long_debug';continuity_need='required'} $enabled
Assert ($b.mode -eq 'B') 'enabled persistent specialist'
$fallback=Get-OrchestrationExecutionMode @{task_shape='long_debug';continuity_need='required';specialist_requested=$true} $policy
Assert ($fallback.mode -eq 'C' -and $fallback.fallback_from -eq 'B' -and $fallback.rationale -match 'policy-off') 'unsupported specialist explicit fallback'
$bothOff=Get-OrchestrationExecutionMode @{task_shape='long_debug';continuity_need='required';runtime='v1'} $policy
Assert ($bothOff.gates.Count -eq 2 -and $bothOff.gates -contains 'policy-off' -and $bothOff.gates -contains 'runtime-unsupported') 'both gates recorded'
$matrix=0
foreach($requested in @($false,$true)){foreach($long in @($false,$true)){foreach($on in @($false,$true)){foreach($cap in @($false,$true)){
    $shape='single_lookup';$continuity='none';if($long){$shape='long_debug';$continuity='required'}
    $p=ConvertFrom-Json (ConvertTo-Json @{specialist_enabled=$on;runtime_caps=@{v1_persistent_specialist=$cap}} -Compress)
    $d=@{task_shape=$shape;continuity_need=$continuity;specialist_requested=$requested;runtime='v1'}
    $got=Get-OrchestrationExecutionMode $d $p
    $eligible=$long;$expected='C';$fallbackExpected=$false
    if($eligible -and $on -and $cap){$expected='B'}elseif($eligible){$fallbackExpected=$true}
    Assert ($got.mode -eq $expected -and (($null -ne $got.fallback_from) -eq $fallbackExpected)) "eligibility matrix $requested/$long/$on/$cap"
    $matrix++
}}}}
$notApplicable=Get-OrchestrationExecutionMode @{task_shape='single_lookup';specialist_requested=$true} $policy
Assert ($null -eq $notApplicable.fallback_from -and $notApplicable.rationale -match 'not applicable to shape') 'specialist request shape gate'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('execution-mode-'+[guid]::NewGuid().ToString('N')); [void](New-Item -ItemType Directory $testRoot)
try {
    $path=Join-Path $testRoot 'evidence.jsonl'
    Assert (Write-OrchestrationModeEvidence $path $c 'safe' '2026-10-02T12:00:00Z') 'write evidence'
    $raw=[IO.File]::ReadAllText($path)
    Assert ($raw -match '2026-10-02T12:00:00\.0000000Z' -and $raw -notmatch 'sk-SYNTHETICSECRET') 'sanitized bounded evidence'
    $offsetPath=Join-Path $testRoot 'offset.jsonl'
    Assert (Write-OrchestrationModeEvidence $offsetPath $c 'safe' '2026-10-02T14:00:00+02:00') 'offset timestamp accepted'
    Assert ((Get-Content $offsetPath -Raw) -match '2026-10-02T12:00:00\.0000000Z') 'offset normalized to UTC'
    $badTimePath=Join-Path $testRoot 'bad-time.jsonl'
    Assert (Write-OrchestrationModeEvidence $badTimePath $c 'safe' '2026-13-99T99:99:99Z') 'invalid calendar timestamp does not throw'
    $badTimeRaw=Get-Content $badTimePath -Raw
    Assert ($badTimeRaw -match '"generated_at":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z"' -and $badTimeRaw -match 'Invalid timestamp replaced') 'invalid timestamp replaced and noted'
    $secretDecision=[pscustomobject]@{mode='C';rationale='reason sk-SYNTHETICSECRET example.com'}
    $largePath=Join-Path $testRoot 'large.jsonl'
    Assert (Write-OrchestrationModeEvidence $largePath $secretDecision 'safe' 'fixed' 180) 'large evidence structured truncation'
    $largeRaw=[IO.File]::ReadAllText($largePath)
    Assert ($largeRaw.Length -le 180 -and $largeRaw -notmatch 'SYNTHETICSECRET|example.com' -and $largeRaw -match '\[truncated\]|\[redacted\]') 'byte cap and rationale redaction'
    $locked=Join-Path $testRoot 'locked.jsonl';[IO.File]::WriteAllText($locked,'')
    $lockStream=[IO.File]::Open($locked,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {Assert (-not (Write-OrchestrationModeEvidence $locked $c 'safe' 'fixed')) 'lock busy fails safely'} finally {$lockStream.Dispose()}
    $hostile=Get-OrchestrationExecutionMode @{task_shape=@('fixed_pipeline');continuity_need=[pscustomobject]@{x='y'}} $policy
    Assert ($hostile.mode -eq 'C') 'hostile descriptor safe fallback'
    $first=Get-OrchestrationExecutionMode @{task_shape='long_debug';continuity_need='required';team_size=1} $enabled
    $second=Get-OrchestrationExecutionMode @{task_shape='long_debug';continuity_need='required';team_size=8} $enabled
    Assert ($first.mode -eq $second.mode) 'team size does not choose mode'
    Assert ((Get-OrchestrationExecutionMode @{task_shape='long_debug';continuity_need='required'} $enabled).mode -eq 'B') 'no deeper delegation; label only'
    Assert ((Get-OrchestrationExecutionMode @{task_shape='single_lookup'} $policy).mode -eq $c.mode) 'deterministic decision'
} finally {Remove-Item -LiteralPath $testRoot -Recurse -Force}
"PASS: $script:passed"
