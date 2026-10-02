<# PowerShell 5.1 compatible, pure mode selection plus bounded JSONL evidence. #>
[CmdletBinding()]
param()

function Get-OrchestrationExecutionMode {
    [CmdletBinding()]
    param($Descriptor, $Policy)
    $result=[ordered]@{mode='C';rationale='Conservative one-shot fallback for invalid or unsupported descriptor.'}
    try {
        if($null -eq $Descriptor){return [pscustomobject]$result}
        if($Descriptor -isnot [System.Collections.IDictionary] -and $Descriptor -isnot [pscustomobject]){return [pscustomobject]$result}
        foreach($field in @('task_shape','continuity_need','specialist_requested')) {
            try { $value=$Descriptor.$field; if($null -ne $value -and $value -isnot [string] -and $value -isnot [bool]){return [pscustomobject]$result} } catch { return [pscustomobject]$result }
        }
        $shape=[string]$Descriptor.task_shape
        $continuity=[string]$Descriptor.continuity_need
        $requested=$false
        try {$requested=[bool]$Descriptor.specialist_requested} catch {}
        if($shape -eq 'fixed_pipeline'){$result.mode='A';$result.rationale='Fixed repeatable pipeline uses deterministic workflow.';return [pscustomobject]$result}
        if($shape -in @('single_lookup','small_localized')){if($requested){$result.rationale='Persistent specialist not applicable to shape; using one-shot worker.'}else{$result.rationale='Bounded lookup/localized task uses one-shot worker.'};return [pscustomobject]$result}
        $eligible=($shape -eq 'long_debug' -and ($requested -or $continuity -eq 'required'))
        if(-not $eligible){if($requested){$result.rationale='Persistent specialist not applicable to shape; using one-shot worker.'};return [pscustomobject]$result}
        $runtime=[string]$Descriptor.runtime
        if($runtime -notin @('v1','v2')){$runtime='v1'}
        $capName="${runtime}_persistent_specialist"
        $specialistOn=$false; $runtimeOn=$false
        try {$specialistOn=([bool]$Policy.specialist_enabled);$runtimeOn=([bool]$Policy.runtime_caps.$capName)} catch {}
        if(-not $specialistOn -or -not $runtimeOn){
            $result.fallback_from='B'
            $gates=@(); if(-not $specialistOn){$gates+=@('policy-off')}; if(-not $runtimeOn){$gates+=@('runtime-unsupported')}
            $result.policy_gated=$gates; $result.gates=$gates
            $result.rationale="Persistent specialist fell back to one-shot: $($gates -join ', ').";return [pscustomobject]$result
        }
        $result.mode='B';$result.rationale='Specialist eligible by request or continuity/task shape; policy and runtime capability enabled.';return [pscustomobject]$result
    } catch {}
    return [pscustomobject]$result
}

function Write-OrchestrationModeEvidence {
    [CmdletBinding()]
    param([string]$Path,$Decision,[string]$TaskId='', [string]$TimestampUtc=([DateTime]::UtcNow.ToString('o')),[int]$MaxBytes=65536)
    try {
        if([string]::IsNullOrWhiteSpace($Path) -or $null -eq $Decision){return $false}
        $mode=[string]$Decision.mode; if($mode -notin @('A','B','C')){$mode='C'}
        $id=$TaskId -replace '[^A-Za-z0-9._-]','_'; if($id.Length -gt 64){$id=$id.Substring(0,64)}
        $stamp=[string]$TimestampUtc
        $parsed=[DateTimeOffset]::MinValue
        $validTime=[DateTimeOffset]::TryParse($stamp,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed)
        if($validTime){$stamp=$parsed.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",[Globalization.CultureInfo]::InvariantCulture)}
        else {$stamp=[DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",[Globalization.CultureInfo]::InvariantCulture);$Decision=[pscustomobject]@{mode=$Decision.mode;rationale=([string]$Decision.rationale+' Invalid timestamp replaced with internal UTC time.')}}
        $stamp=$stamp -replace '(?i)sk-[A-Za-z0-9_-]+','[redacted]' -replace '(?i)(token|key)\s*=\s*[^\s,;]+','$1=[redacted]'
        if($stamp.Length -gt 80){$stamp=$stamp.Substring(0,80)}
        $rationale=([string]$Decision.rationale -replace '(?i)sk-[A-Za-z0-9_-]+','[redacted]' -replace '(?i)(token|key)\s*=\s*[^\s,;]+','$1=[redacted]' -replace '(?i)\b[a-z0-9.-]+\.(com|net|org|local|dev|io|br)\b','[redacted-host]')
        $row=[ordered]@{generated_at=$stamp;task_id=$id;mode=$mode;rationale=$rationale}
        if($row.rationale.Length -gt 160){$row.rationale=$row.rationale.Substring(0,160)}
        $line=(ConvertTo-Json -InputObject $row -Compress)+"`n"
        if($MaxBytes -lt 1){return $false}
        $size=[Text.Encoding]::UTF8.GetByteCount($line)
        if($size -gt $MaxBytes){$row.rationale='[truncated]';$line=(ConvertTo-Json -InputObject $row -Compress)+"`n";$size=[Text.Encoding]::UTF8.GetByteCount($line)}
        if($size -gt $MaxBytes){return $false}
        if((Test-Path -LiteralPath $Path -PathType Leaf) -and ((Get-Item -LiteralPath $Path).Length + $size -gt $MaxBytes)){return $false}
        $bytes=[Text.Encoding]::UTF8.GetBytes($line)
        $stream=$null
        try {
            $stream=[IO.File]::Open($Path,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::None)
            $stream.Write($bytes,0,$bytes.Length); $stream.Flush(); return $true
        } finally {if($null -ne $stream){$stream.Dispose()}}
    } catch {return $false}
}
