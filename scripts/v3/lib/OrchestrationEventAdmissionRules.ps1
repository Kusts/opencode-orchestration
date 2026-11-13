function Import-OrchestrationEventAdmissionRules {
    [CmdletBinding()]
    param([string]$Path,[string]$RepoRoot,[int]$MaxBytes=262144,[int]$MaxRules=50)
    $result=[ordered]@{ok=$false;policy_version='';rules=@();rule_count=0;error=''}
    try {
        if($MaxRules -lt 1 -or $MaxRules -gt 200){$result.error='RULES_CONFIG_INVALID';return [pscustomobject]$result}
        if(-not $Path){if(-not $RepoRoot){$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path};$Path=Join-Path $RepoRoot 'source\registry\event-admission-rules.json'}
        if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){$result.error='RULES_PATH_NOT_FOUND';return [pscustomobject]$result}
        $item=Get-Item -LiteralPath $Path -ErrorAction Stop
        if($item.Length -gt $MaxBytes){$result.error='RULES_TOO_LARGE';return [pscustomobject]$result}
        try {$doc=Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop} catch {$result.error='RULES_INVALID_JSON';return [pscustomobject]$result}
        if($null -eq $doc.schema_version -or $doc.schema_version -isnot [ValueType] -or $doc.schema_version -is [bool] -or [decimal]$doc.schema_version -ne 1 -or $null -eq $doc.rules -or $doc.rules -isnot [array]){$result.error='RULES_SCHEMA_INVALID';return [pscustomobject]$result}
        if($doc.policy_version -isnot [string] -or $doc.policy_version.Length -lt 1 -or $doc.policy_version.Length -gt 64){$result.error='RULES_POLICY_VERSION_INVALID';return [pscustomobject]$result}
        if($doc.rules.Count -gt $MaxRules){$result.error='RULES_LIMIT_EXCEEDED';return [pscustomobject]$result}
        $seen=@{};$normalized=@();$allowed=@('rule_id','enabled','risk','trigger','scope_allowlist','thread_allowlist','description','owner')
        foreach($r in $doc.rules){
            if($null -eq $r -or $r -is [array] -or $r -isnot [pscustomobject]){$result.error='RULES_RULE_INVALID';return [pscustomobject]$result}
            foreach($p in $r.PSObject.Properties){if($p.Name -notin $allowed){$result.error='RULES_RULE_INVALID';return [pscustomobject]$result}}
            if($r.rule_id -isnot [string] -or $r.rule_id -cnotmatch '^[a-z0-9][a-z0-9._-]{0,63}$' -or $r.enabled -isnot [bool] -or $r.risk -cne 'low' -or $r.trigger -cnotin @('issue_comment','pull_request_review','ci_status','push') -or $r.scope_allowlist -isnot [array] -or $r.scope_allowlist.Count -lt 1 -or $r.scope_allowlist.Count -gt 16){$result.error='RULES_RULE_INVALID';return [pscustomobject]$result}
            if($seen.ContainsKey($r.rule_id)){$result.error='RULES_RULE_ID_DUPLICATE';return [pscustomobject]$result};$seen[$r.rule_id]=$true
            foreach($s in $r.scope_allowlist){if($s -isnot [string] -or !$s -or $s.Length -gt 64){$result.error='RULES_RULE_INVALID';return [pscustomobject]$result}}
            if($r.PSObject.Properties['thread_allowlist']){if($r.thread_allowlist -isnot [array] -or !$r.thread_allowlist.Count -or $r.thread_allowlist.Count -gt 16){$result.error='RULES_RULE_INVALID';return [pscustomobject]$result};foreach($t in $r.thread_allowlist){if($t -isnot [string] -or $t.Length -gt 128 -or $t -cnotmatch '^(pr:|issue:|branch:)\S+$'){$result.error='RULES_RULE_INVALID';return [pscustomobject]$result}}}
            if($r.PSObject.Properties['description'] -and ($r.description -isnot [string] -or $r.description.Length -gt 200)){$result.error='RULES_RULE_INVALID';return [pscustomobject]$result}
            if($r.PSObject.Properties['owner'] -and ($r.owner -isnot [string] -or $r.owner.Length -gt 64)){$result.error='RULES_RULE_INVALID';return [pscustomobject]$result}
            $n=[ordered]@{rule_id=$r.rule_id;enabled=$r.enabled;risk=$r.risk;trigger=$r.trigger;scope_allowlist=@($r.scope_allowlist)}
            if($r.PSObject.Properties['thread_allowlist']){$n.thread_allowlist=@($r.thread_allowlist)};if($r.PSObject.Properties['description']){$n.description=$r.description};if($r.PSObject.Properties['owner']){$n.owner=$r.owner};$normalized+=,[pscustomobject]$n
        }
        $result.ok=$true;$result.policy_version=$doc.policy_version;$result.rules=@($normalized);$result.rule_count=$normalized.Count
    } catch {$result.error='RULES_SCHEMA_INVALID'}
    [pscustomobject]$result
}
