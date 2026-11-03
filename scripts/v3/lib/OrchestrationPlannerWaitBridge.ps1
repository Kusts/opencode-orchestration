<#!
.SYNOPSIS
    PR181 Fatia A: stdin/stdout bridge for the planner-wait native tool.
.DESCRIPTION
    Spawned by the orchestration-enforcement V2 plugin (planner-wait tool)
    with shell:false and literal argv
    (-NoProfile -NonInteractive -File <this>). Reads ONE JSON envelope from
    stdin (bounded 65536 bytes, strict UTF-8), dot-sources the sibling
    OrchestrationPlannerWait.ps1 lib, invokes
    Invoke-OrchestrationPlannerWaitBinding with the request fields, and
    prints the result JSON on stdout. Exit code 0 when ok:true, else 1.
    Never throws a raw error to the host: every failure is a JSON envelope
    with ok:false and sanitized ASCII reason. No network, no gh, no daemon.
    Dot-sourcing this file defines functions only (guarded main).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Read-PWBridgeStdin {
    try {
        $stdin = [Console]::OpenStandardInput()
        $buf = New-Object byte[] 8192
        $chunks = New-Object System.Collections.ArrayList
        $total = 0
        while ($true) {
            $n = $stdin.Read($buf, 0, [Math]::Min(8192, 65537 - $total))
            if ($n -le 0) { break }
            $total += $n
            if ($total -gt 65536) { return $null }
            $copy = New-Object byte[] $n
            [Array]::Copy($buf, $copy, $n)
            [void]$chunks.Add($copy)
        }
        if ($total -le 0) { return '' }
        $flat = New-Object byte[] $total
        $off = 0
        foreach ($c in $chunks) {
            [Array]::Copy($c, 0, $flat, $off, $c.Length)
            $off += $c.Length
        }
        try { return ([Text.Encoding]::UTF8.GetString($flat)) }
        catch { return $null }
    }
    catch { return $null }
}

function Get-PWBridgeField {
    param($Object, [string]$Name = '')
    try {
        if ($null -eq $Object) { return $null }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $null
        }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p) { return $p.Value }
        return $null
    }
    catch { return $null }
}

function Get-PWBridgeAllowedRequestFields {
    return @('task_id', 'goal_id', 'run_id', 'session_id', 'repository', 'pr_number', 'branch', 'expected_head_sha', 'required_checks', 'review_expectation', 'cursor', 'deadline_utc', 'retry_budget_max')
}

function Test-PWBridgeRequestShape {
    param($Request)
    $out = { param([bool]$Ok, [string]$Why) return [pscustomobject]@{ ok = $Ok; reason = $Why } }
    try {
        if ($null -eq $Request) { return (& $out $false 'bridge-request-missing') }
        $names = @()
        try {
            if ($Request -is [System.Collections.IDictionary]) { $names = @($Request.Keys) }
            else { $names = @($Request.PSObject.Properties | ForEach-Object { $_.Name }) }
        }
        catch { return (& $out $false 'bridge-request-malformed') }
        $allowed = Get-PWBridgeAllowedRequestFields
        foreach ($n in @($names)) {
            if ($allowed -cnotcontains [string]$n) { return (& $out $false 'bridge-request-unexpected-field') }
        }
        $sid = ''
        try {
            if ($Request -is [System.Collections.IDictionary]) {
                if ($Request.Contains('session_id')) { $sid = [string]$Request['session_id'] }
            }
            else {
                $p = $Request.PSObject.Properties['session_id']
                if ($null -ne $p) { $sid = [string]$p.Value }
            }
        }
        catch { $sid = '' }
        if ([string]::IsNullOrWhiteSpace($sid)) { return (& $out $false 'bridge-request-missing') }
        return (& $out $true '')
    }
    catch { return (& $out $false 'bridge-request-malformed') }
}

function Write-PWBridgeResult {
    param($Result, [int]$ExitCode = 1)
    try {
        $doc = $Result
        if ($null -eq $doc) {
            $doc = [pscustomobject]@{
                ok = $false; reason = 'bridge-internal-error'; run_id = ''; revision = [long]-1
                binding = ''; wait_reused = $false; wait_file = ''; dedup_key = ''
                task_mutated = $false; grants_authority = $false; done_approved = $false
            }
        }
        try {
            $doc | Add-Member -NotePropertyName 'schema_version' -NotePropertyValue 1 -Force
            $doc | Add-Member -NotePropertyName 'operation' -NotePropertyValue 'bind-wait' -Force
        }
        catch { }
        $text = ($doc | ConvertTo-Json -Compress -Depth 8)
        try { [Console]::Out.Write($text) } catch { }
        exit $ExitCode
    }
    catch {
        try { [Console]::Out.Write('{"ok":false,"reason":"bridge-internal-error","grants_authority":false,"done_approved":false}') } catch { }
        exit 1
    }
}

function Invoke-PWBridgeMain {
    $lib = Join-Path $PSScriptRoot 'OrchestrationPlannerWait.ps1'
    if (-not (Test-Path -LiteralPath $lib -PathType Leaf)) {
        Write-PWBridgeResult ([pscustomobject]@{
            ok = $false; reason = 'bridge-lib-missing'; run_id = ''; revision = [long]-1
            binding = ''; wait_reused = $false; wait_file = ''; dedup_key = ''
            task_mutated = $false; grants_authority = $false; done_approved = $false
        }) 1
        return
    }
    . $lib
    $text = Read-PWBridgeStdin
    if ($null -eq $text -or [string]::IsNullOrWhiteSpace($text)) {
        Write-PWBridgeResult ([pscustomobject]@{
            ok = $false; reason = 'bridge-envelope-unreadable'; run_id = ''; revision = [long]-1
            binding = ''; wait_reused = $false; wait_file = ''; dedup_key = ''
            task_mutated = $false; grants_authority = $false; done_approved = $false
        }) 1
        return
    }
    $env = $null
    try { $env = ConvertFrom-Json $text } catch { $env = $null }
    if ($null -eq $env) {
        Write-PWBridgeResult ([pscustomobject]@{
            ok = $false; reason = 'bridge-envelope-malformed'; run_id = ''; revision = [long]-1
            binding = ''; wait_reused = $false; wait_file = ''; dedup_key = ''
            task_mutated = $false; grants_authority = $false; done_approved = $false
        }) 1
        return
    }
    if (([string](Get-PWBridgeField $env 'schema_version')).Trim() -cne '1') {
        Write-PWBridgeResult ([pscustomobject]@{
            ok = $false; reason = 'bridge-envelope-version'; run_id = ''; revision = [long]-1
            binding = ''; wait_reused = $false; wait_file = ''; dedup_key = ''
            task_mutated = $false; grants_authority = $false; done_approved = $false
        }) 1
        return
    }
    $req = Get-PWBridgeField $env 'request'
    if ($null -eq $req) {
        Write-PWBridgeResult ([pscustomobject]@{
            ok = $false; reason = 'bridge-request-missing'; run_id = ''; revision = [long]-1
            binding = ''; wait_reused = $false; wait_file = ''; dedup_key = ''
            task_mutated = $false; grants_authority = $false; done_approved = $false
        }) 1
        return
    }
    $shape = $null
    try { $shape = Test-PWBridgeRequestShape -Request $req } catch { $shape = $null }
    if (($null -eq $shape) -or (-not [bool](Get-PWBridgeField $shape 'ok' $false))) {
        $whyShape = 'bridge-request-unexpected-field'
        try {
            $rs = ([string](Get-PWBridgeField $shape 'reason' '')).Trim()
            if (-not [string]::IsNullOrWhiteSpace($rs)) { $whyShape = $rs }
        }
        catch { }
        Write-PWBridgeResult ([pscustomobject]@{
            ok = $false; reason = $whyShape; run_id = ''; revision = [long]-1
            binding = ''; wait_reused = $false; wait_file = ''; dedup_key = ''
            task_mutated = $false; grants_authority = $false; done_approved = $false
        }) 1
        return
    }
    $res = $null
    try {
        $checks = @()
        try { $checks = @(Get-PWBridgeField $req 'required_checks') } catch { $checks = @() }
        # Only model-safe registration fields cross the boundary. Paths,
        # owner/lease identity+generation/expiry are NEVER accepted here: the
        # library derives Task/Goal/flags paths from kernel defaults tied to
        # the bundled repo root (plus fixed cache/runtime/github-waits) and
        # owner+generation+lease-expiry from the stored Goal ownership record,
        # with the canonical owner as wait lease owner.
        $res = Invoke-OrchestrationPlannerWaitBinding `
            -TaskId ([string](Get-PWBridgeField $req 'task_id')) `
            -GoalId ([string](Get-PWBridgeField $req 'goal_id')) `
            -RunId ([string](Get-PWBridgeField $req 'run_id')) `
            -SessionId ([string](Get-PWBridgeField $req 'session_id')) `
            -Repository ([string](Get-PWBridgeField $req 'repository')) `
            -PrNumber (Get-PWBridgeField $req 'pr_number') `
            -Branch ([string](Get-PWBridgeField $req 'branch')) `
            -ExpectedHeadSha ([string](Get-PWBridgeField $req 'expected_head_sha')) `
            -RequiredChecks $checks `
            -ReviewExpectation ([string](Get-PWBridgeField $req 'review_expectation')) `
            -Cursor ([string](Get-PWBridgeField $req 'cursor')) `
            -DeadlineUtc (Get-PWBridgeField $req 'deadline_utc') `
            -RetryBudgetMax (Get-PWBridgeField $req 'retry_budget_max')
    }
    catch { $res = $null }
    if ($null -eq $res) {
        Write-PWBridgeResult ([pscustomobject]@{
            ok = $false; reason = 'bridge-internal-error'; run_id = ''; revision = [long]-1
            binding = ''; wait_reused = $false; wait_file = ''; dedup_key = ''
            task_mutated = $false; grants_authority = $false; done_approved = $false
        }) 1
        return
    }
    $okOut = $false
    try { $okOut = [bool](Get-PWBridgeField $res 'ok' $false) } catch { $okOut = $false }
    if ($okOut) { Write-PWBridgeResult $res 0 }
    else { Write-PWBridgeResult $res 1 }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-PWBridgeMain
}
