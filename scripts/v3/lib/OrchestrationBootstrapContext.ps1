<#
.SYNOPSIS
    Builds a bounded, read-only orchestration bootstrap snapshot.
.DESCRIPTION
    Does not activate or install anything in OpenCode. Runtime activation and
    applying this snapshot are operator-owned. Missing inputs are unavailable.
    Discard order: task refs, wait refs, Jev, AI Memory, then task/wait counts;
    capability health is last. The minimum envelope can itself exceed a smaller
    requested budget; that case is reported explicitly with oversized=true.
    No transcript/history is read. Runtime info is injected; no process runs.
    PowerShell 5.1 compatible; no network or writes.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

function New-OrchestrationBootstrapContext {
    [CmdletBinding()]
    param(
        [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))),
        [string]$TasksDir = '', [string]$FlagsPath = '',
        [string]$JevPolicyPath = '', [string]$AiMemoryPolicyPath = '',
        [string]$AiMemoryConfigPath = '', [int]$ByteBudget = 8192,
        [scriptblock]$Clock = { [DateTime]::UtcNow.ToString('o') },
        [int]$MaxRefs = 20, $RuntimeInfo = $null
    )
    try {
    $ctx = [ordered]@{ project_id='unknown'; runtime=[ordered]@{generation='unknown';source='not-probed'}; capability_health=[ordered]@{status='unavailable'}; tasks=[ordered]@{status='unavailable'}; pending_waits=[ordered]@{status='unavailable'}; jev_status=[ordered]@{status='unavailable'}; aimemory_status=[ordered]@{status='unavailable'}; generated_at=''; truncated=$false }
    if($MaxRefs -lt 0){$MaxRefs=20}; if($MaxRefs -gt 20){$MaxRefs=20}; if($ByteBudget -lt 0){$ByteBudget=8192}
    try { $name = Split-Path -Leaf ([IO.Path]::GetFullPath($RepoRoot)); if ($name) { $ctx.project_id = $name } } catch { }
    try { $ctx.generated_at = [string](& $Clock) } catch { $ctx.generated_at = '' }
    function Protect-BootstrapText([string]$Value) {
        if($null -eq $Value){return ''}
        $v=$Value -replace '(?i)\b[a-z0-9.-]+\.(com|net|org|local|dev|io|br)\b','[redacted-host]'
        $v=$v -replace '(?i)\b(token|key)\s*=\s*[^\s,;]+','$1=[redacted]'
        $v=$v -replace '(?i)sk-[A-Za-z0-9_-]+','[redacted]'
        if($v.Length -gt 160){$v=$v.Substring(0,160)}
        return $v
    }
    $ctx.project_id=Protect-BootstrapText ([string]$ctx.project_id)
    if($null -ne $RuntimeInfo) {
        try { $g=[string]$RuntimeInfo.generation; if($g -match '^[12]$'){$ctx.runtime=[ordered]@{generation=$g;version=(Protect-BootstrapText ([string]$RuntimeInfo.version));source='injected'}} } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($FlagsPath)) { $FlagsPath=Join-Path $RepoRoot 'source/registry/capability-flags.json' }
    if ([string]::IsNullOrWhiteSpace($TasksDir)) { $TasksDir=Join-Path $RepoRoot 'cache/runtime/tasks' }
    if ([string]::IsNullOrWhiteSpace($JevPolicyPath)) { $JevPolicyPath=Join-Path $RepoRoot 'source/registry/jev-advisory-policy.json' }
    if ([string]::IsNullOrWhiteSpace($AiMemoryPolicyPath)) { $AiMemoryPolicyPath=Join-Path $RepoRoot 'source/registry/ai-memory-remote-policy.json' }
    try {
        $raw=[IO.File]::ReadAllText($FlagsPath); $f=ConvertFrom-Json $raw; $flags=[ordered]@{}
        foreach($p in $f.PSObject.Properties) { $enabled=$false; try { if ($p.Value.PSObject.Properties['enabled']) { $enabled=[bool]$p.Value.enabled } elseif ($p.Value.PSObject.Properties['active']) { $enabled=[bool]$p.Value.active } } catch { }; $flags[$p.Name]=$enabled }
        $allOff=$true; foreach($v in $flags.Values) { if($v){$allOff=$false} }
        $ctx.capability_health=[ordered]@{flags=$flags;all_off=$allOff}
    } catch { }
    try {
        $tasks=@(); $waits=@(); $active=0; $detached=0
        if (-not (Test-Path -LiteralPath $TasksDir -PathType Container)) { throw 'missing' }
        foreach($file in @(Get-ChildItem -LiteralPath $TasksDir -Filter '*.json' -File -ErrorAction Stop | Select-Object -First 200)) {
            try { $r=ConvertFrom-Json ([IO.File]::ReadAllText($file.FullName)); $id=[string]$r.task_id; if(-not $id){$id=$file.BaseName}; $id=Protect-BootstrapText $id; if($id -notmatch '^[A-Za-z0-9._-]{1,64}$'){$id='redacted'}; $state=([string]$r.state).ToUpperInvariant(); if($state -in @('IMPLEMENTING','VALIDATING','REVIEWING','BLOCKED')) { $active++; if($r.execution_status -eq 'DETACHED'){$detached++}; if($tasks.Count -lt $MaxRefs){$tasks+=@{id=$id}} }; if($null -ne $r.active_wait -and $waits.Count -lt $MaxRefs){$type=Protect-BootstrapText ([string]$r.active_wait.type); if($type -notmatch '^[A-Za-z0-9._-]{1,40}$'){$type='redacted'}; $waits+=@{id=$id;type=$type} } } catch { }
        }
        $ctx.tasks=[ordered]@{active_count=$active;detached_count=$detached;refs=@($tasks)}; $ctx.pending_waits=[ordered]@{count=$waits.Count;refs=@($waits)}
    } catch { }
    try { $null=ConvertFrom-Json ([IO.File]::ReadAllText($JevPolicyPath)); $flag=$false; if($ctx.capability_health.flags.Contains('jev_advisory')){$flag=[bool]$ctx.capability_health.flags['jev_advisory']}; $ctx.jev_status=[ordered]@{flag_enabled=$flag;policy_found=$true;transport='synthetic-hold'} } catch { }
    try { $null=ConvertFrom-Json ([IO.File]::ReadAllText($AiMemoryPolicyPath)); $present=$false; if($AiMemoryConfigPath -and (Test-Path -LiteralPath $AiMemoryConfigPath -PathType Leaf)){$present=$true}; $transport='unconfigured'; if($present){$transport='user-owned'}; $ctx.aimemory_status=[ordered]@{config_present=$present;transport=$transport} } catch { }
    try {
        $stages=@('tasks_refs','wait_refs','jev','aimemory','tasks_counts','wait_counts','capability_health')
        $json=ConvertTo-Json -InputObject $ctx -Depth 20 -Compress
        foreach($stage in $stages) {
            if([Text.Encoding]::UTF8.GetByteCount($json) -le $ByteBudget){break}
            switch($stage) {
                'tasks_refs' { if($ctx.tasks.Contains('refs')){$ctx.tasks.Remove('refs');$ctx.truncated=$true} }
                'wait_refs' { if($ctx.pending_waits.Contains('refs')){$ctx.pending_waits.Remove('refs');$ctx.truncated=$true} }
                'jev' { $ctx.jev_status=[ordered]@{status='unavailable'};$ctx.truncated=$true }
                'aimemory' { $ctx.aimemory_status=[ordered]@{status='unavailable'};$ctx.truncated=$true }
                'tasks_counts' { if($ctx.tasks.Contains('active_count')){$ctx.tasks=[ordered]@{status='unavailable'};$ctx.truncated=$true} }
                'wait_counts' { if($ctx.pending_waits.Contains('count')){$ctx.pending_waits=[ordered]@{status='unavailable'};$ctx.truncated=$true} }
                'capability_health' { if($ctx.capability_health.status -ne 'unavailable'){$ctx.capability_health=[ordered]@{status='unavailable'};$ctx.truncated=$true} }
            }
            $json=ConvertTo-Json -InputObject $ctx -Depth 20 -Compress
        }
        if([Text.Encoding]::UTF8.GetByteCount($json) -gt $ByteBudget){return [pscustomobject][ordered]@{status='oversized';truncated=$true;oversized=$true}}
        return [pscustomobject]$ctx
    } catch { return [pscustomobject][ordered]@{status='error';section='serialize'} }
    } catch { return [pscustomobject][ordered]@{status='error';section='bootstrap'} }
}
