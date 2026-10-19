<#!
.SYNOPSIS
    F1-S1 native CLAIM bridge (isolated fixture only): consumes ONE durable PREPARE.
.DESCRIPTION
    Thin cooperative CLI for slice S1. It NEVER spawns workers, NEVER verifies,
    NEVER approves DONE and NEVER grants authority. It performs exactly ONE call
    to the existing library entrypoint for CLAIM and reports the observation.

    Invocation:
      <request-json> | powershell -NoProfile -File native-dispatch-claim.ps1 `
        -Action claim -ContextFile <absolute path>

    Params:
      -Action claim : the ONLY action. Anything else is rejected (exit 2).
      -ContextFile  : absolute path of the fixture-owned context file
        (UTF-8 JSON, max 64 KiB). The context is data from the FILE, never
        from the request.

    Context file schema (strict: unknown fields rejected, exit 2):
      {
        "schema_version": 1,
        "receipt_dir": "<absolute dir>",
        "goal_store_dir": "<absolute dir>",
        "tasks_dir": "<absolute dir>",
        "flags_path": "<absolute path>",
        "authorization_file": "<absolute path of the Authorization JSON>",
        "idempotency_key": "<32 hex>",
        "prepared_fingerprint": "<32 hex>",
        "expected_caller_agent": "<agent>",
        "expected_target_agent": "<agent>",
        "expected_prompt_hash": "<32 hex>",
        "expected_args_template": { "<key>": "<string value>" }
      }
      All paths must be absolute. Stores are used ONLY under these explicit
      dirs; no repository default is ever consulted. expected_args_template
      is a flat string map (empty object allowed): the request args must
      carry EXACTLY these keys with ordinal-equal string values.

    Request JSON (stdin, raw bytes, max 65536 bytes, strict: unknown
    fields or wrong JSON types rejected with exit 2):
      {
        "schema_version": 1,
        "session_id": "<host session>",
        "message_id": "<host message>",
        "call_id": "<host call>",
        "caller_agent": "<agent>",
        "target_agent": "<agent>",
        "tool": "subagent",
        "args": { "prompt": "<text>", ...template keys... }
      }
      schema_version must be the exact JSON integer 1 (1.0, "1" and
      other shapes are rejected). Every id/agent/tool field must be a
      JSON string (a JSON number such as session_id:123 is rejected).
      args must be a flat JSON string map: a wrong-typed value where a
      string is expected (bool/array/object/number) is a schema error
      (exit 2), distinct from a value divergence (exit 0). args.prompt
      is hashed with Get-NativeDispatchHash32 and compared to
      expected_prompt_hash.

    Checks in order (all fail-closed):
      identity  : caller/target agents equal the expected ones (ordinal);
      template  : args match expected_args_template exactly (no missing,
                  no extra, values ordinal-equal strings);
      prompt    : args.prompt hashes to expected_prompt_hash;
      durable   : the request prompt hash is compared to the DURABLE
                  prompt_hash re-read from the prepared receipt itself
                  (pre-lock pre-read with the library helpers, same
                  functions the CLAIM entrypoint uses); the context hash
                  is only redundancy, the receipt is the authority;
                  divergence refuses with receipt-prompt-mismatch;
      consume   : ONE call to the library CLAIM entrypoint with the
                  context stores + authorization + request identity +
                  context key/fingerprint (lock timeout 2000 ms).

    Output: exactly ONE bounded JSON envelope (max 64 KiB) on stdout:
      {
        "schema_version": 1, "operation": "claim",
        "ok": <bool>, "claimed": <bool>, "reason": "<code>",
        "idempotency_key": "<32hex>", "prepared_fingerprint": "<32hex>",
        "session_id": "...", "message_id": "...", "call_id": "...",
        "call_fingerprint": "<32hex>",
        "call_binding_material": "<exact canonical string hashed>",
        "target_agent": "<echo of the request target>",
        "tool": "<echo of the request tool>",
        "grants_authority": false, "verified_pass": false,
        "done_approved": false
      }
      call_fingerprint binds session/message/call/caller/target/key.
      call_binding_material is the EXACT canonical string over which the
      fingerprint was computed, so the caller can recompute it.
      ok=true/claimed=true means ONLY that the durable 'prepared' ->
      'claimed' (DISPATCH_UNCERTAIN) transition was persisted BEFORE the
      effect. It never means the effect ran or anything was verified.

    HASH ALGORITHM NOTE: Get-NativeDispatchHash32 is SHA-256 over UTF-8
    bytes, hex-lowercased, truncated to 32 characters. The plugin
    recomputes the fingerprint from call_binding_material with node
    crypto (a pure function, not a duplication of CLAIM rules). If the
    library ever changes that algorithm this bridge and its suites break
    loudly by design; update both sides together, never silently.

    EXPLICIT LIMITATIONS (fixture-only, no production claims):
      * Absolute paths are NOT confinement: links/junctions in the path
        are followed by IO; ownership of the fixture tree belongs to the
        operator, outside this file.
      * No signature or integrity check exists for the bridge script, the
        shell executable or the dot-sourced libraries: a planted file
        runs with the identity of this process. The plugin verifies the
        bridge file at setup time; a setup throw never proves the host
        will refuse a dispatch if it ignores the failure or loads late.
      * Context and authorization files do not authenticate origin:
        whoever can write them forges the request. They require
        ownership external to the agent.
      * This bridge never writes an admission file: it consumes the
        durable receipt and returns an observation only.

    Exit codes: 0 = valid observation (whose ok may be false on refusal),
    2 = invalid input, 1 = internal/dependency failure. The process itself
    is the subprocess: the caller owns the 10 s budget; the receipt lock
    inside is 2 s.

    Dot-source safe: without -Action this file defines functions and does
    nothing else. PS 5.1 and PS7 compatible. ASCII-only. No network, no
    process spawn, no model calls, no secrets.
#>
param(
    [string]$Action = '',
    [string]$ContextFile = ''
)

$ErrorActionPreference = 'Stop'

function Get-NCValue {
    param($Object, [string]$Name, $Default = $null)
    try {
        if ($null -eq $Object) { return $Default }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $Default
        }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -ne $p) { return $p.Value }
        return $Default
    }
    catch { return $Default }
}

function Get-NCPropertyNames {
    param($Object)
    try {
        if ($null -eq $Object) { return @() }
        if ($Object -is [System.Collections.IDictionary]) { return @($Object.Keys) }
        $names = @()
        foreach ($p in @($Object.PSObject.Properties)) {
            try { $names += @([string]$p.Name) } catch { }
        }
        return $names
    }
    catch { return @() }
}

function Write-NCEnvelope {
    param($Envelope)
    try {
        $text = ConvertTo-Json -InputObject $Envelope -Depth 10 -Compress
        if ([string]::IsNullOrWhiteSpace($text)) { throw 'empty-envelope' }
        if ($text.Length -gt 65536) { throw 'envelope-too-large' }
        Write-Output $text
    }
    catch {
        Write-Output '{"schema_version":1,"operation":"claim","ok":false,"claimed":false,"reason":"encode-failed","idempotency_key":"","prepared_fingerprint":"","session_id":"","message_id":"","call_id":"","call_fingerprint":"","call_binding_material":"","target_agent":"","tool":"","grants_authority":false,"verified_pass":false,"done_approved":false}'
    }
}

function New-NCEnvelope {
    param(
        [bool]$Ok = $false,
        [string]$Reason = '',
        [string]$Key = '',
        [string]$PreparedFp = '',
        [string]$SessionId = '',
        [string]$MessageId = '',
        [string]$CallId = '',
        [string]$CallFp = '',
        [string]$CallMaterial = '',
        [string]$TargetAgent = '',
        [string]$ToolName = ''
    )
    return [pscustomobject][ordered]@{
        schema_version       = 1
        operation            = 'claim'
        ok                   = [bool]$Ok
        claimed              = $false
        reason               = ([string]$Reason)
        idempotency_key      = ([string]$Key)
        prepared_fingerprint = ([string]$PreparedFp)
        session_id           = ([string]$SessionId)
        message_id           = ([string]$MessageId)
        call_id              = ([string]$CallId)
        call_fingerprint     = ([string]$CallFp)
        call_binding_material = ([string]$CallMaterial)
        target_agent         = ([string]$TargetAgent)
        tool                 = ([string]$ToolName)
        grants_authority     = $false
        verified_pass        = $false
        done_approved        = $false
    }
}

function New-NCOkEnvelope {
    param($Claim, [string]$Key = '', [string]$PreparedFp = '', [string]$CallFp = '', [string]$CallMaterial = '', [string]$TargetAgent = '', [string]$ToolName = '')
    return [pscustomobject][ordered]@{
        schema_version       = 1
        operation            = 'claim'
        ok                   = [bool](Get-NCValue $Claim 'ok' $false)
        claimed              = [bool](Get-NCValue $Claim 'claimed' $false)
        reason               = ([string](Get-NCValue $Claim 'reason' ''))
        idempotency_key      = ([string]$Key)
        prepared_fingerprint = ([string]$PreparedFp)
        session_id           = ([string](Get-NCValue $Claim 'session_id' ''))
        message_id           = ([string](Get-NCValue $Claim 'message_id' ''))
        call_id              = ([string](Get-NCValue $Claim 'call_id' ''))
        call_fingerprint     = ([string]$CallFp)
        call_binding_material = ([string]$CallMaterial)
        target_agent         = ([string]$TargetAgent)
        tool                 = ([string]$ToolName)
        grants_authority     = $false
        verified_pass        = $false
        done_approved        = $false
    }
}

function Test-NCHex32 {
    param([string]$Value = '')
    try {
        $v = ([string]$Value).Trim().ToLowerInvariant()
        return ($v -cmatch '\A[a-f0-9]{32}\z')
    }
    catch { return $false }
}

function Test-NCAgentShape {
    param([string]$Value = '')
    try {
        $v = ([string]$Value)
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        return ($v -cmatch '\A[A-Za-z0-9_-]{1,64}\z')
    }
    catch { return $false }
}

function Test-NCHostIdShape {
    param([string]$Value = '')
    try {
        $v = ([string]$Value)
        if ([string]::IsNullOrWhiteSpace($v)) { return $false }
        return ($v -cmatch '\A[A-Za-z0-9._:-]{1,128}\z')
    }
    catch { return $false }
}

function Test-NCRequestNumberOne {
    param($Value = $null)
    try {
        # Exact JSON integer 1 only: 1.0 and 1e0 arrive as Double and are
        # rejected, as are strings, arrays and any other number.
        if (($Value -is [int]) -or ($Value -is [long])) {
            return ([long]$Value -eq 1)
        }
        return $false
    }
    catch { return $false }
}

function Test-NCJsonString {
    param($Value = $null)
    try {
        return ($Value -is [string])
    }
    catch { return $false }
}

function Test-NCRawJsonString {
    # Type test WITHOUT pipeline enumeration: Get-NCValue returns through
    # the output pipeline, which unrolls a one-element JSON array into its
    # scalar - a ["s1"] would read back as the string "s1". Property access
    # assigned to a variable keeps the raw shape, so arrays (of any length)
    # are still rejected here.
    param($Object = $null, [string]$Name = '')
    try {
        if (($null -eq $Object) -or ([string]::IsNullOrWhiteSpace($Name))) { return $false }
        if ($Object -is [System.Collections.IDictionary]) {
            if (-not $Object.Contains($Name)) { return $false }
            return ($Object[$Name] -is [string])
        }
        $prop = $Object.PSObject.Properties[$Name]
        if ($null -eq $prop) { return $false }
        return ($prop.Value -is [string])
    }
    catch { return $false }
}

function Get-NCRawField {
    # Raw property read WITHOUT pipeline enumeration (R3b): the value is
    # stored into a holder instead of crossing the output pipeline, so a
    # one-element JSON array stays an array instead of unrolling into its
    # scalar. Returns a single holder object @{found; value}.
    param($Object = $null, [string]$Name = '')
    try {
        if (($null -eq $Object) -or ([string]::IsNullOrWhiteSpace($Name))) {
            return @{ found = $false; value = $null }
        }
        if ($Object -is [System.Collections.IDictionary]) {
            if (-not $Object.Contains($Name)) { return @{ found = $false; value = $null } }
            $h = @{ found = $true; value = $null }
            $h.value = $Object[$Name]
            return $h
        }
        $prop = $Object.PSObject.Properties[$Name]
        if ($null -eq $prop) { return @{ found = $false; value = $null } }
        $h = @{ found = $true; value = $null }
        $h.value = $prop.Value
        return $h
    }
    catch { return @{ found = $false; value = $null } }
}

function Read-NCJsonFile {
    param([string]$Path = '', [int]$MaxBytes = 65536)
    try {
        $p = ([string]$Path).Trim()
        if ([string]::IsNullOrWhiteSpace($p)) {
            return [pscustomobject]@{ ok = $false; reason = 'file-missing'; doc = $null }
        }
        # FileStream with a byte cap instead of a Get-Item/ReadAllText pair:
        # the cap applies to the bytes actually read (no length race), and
        # the strict decoder rejects invalid UTF-8 instead of substituting.
        $fs = $null
        try { $fs = [IO.File]::Open($p, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read) }
        catch { $fs = $null }
        if ($null -eq $fs) {
            return [pscustomobject]@{ ok = $false; reason = 'file-missing'; doc = $null }
        }
        try {
            $buf = New-Object byte[] 8192
            $mem = New-Object IO.MemoryStream
            $seen = [long]0
            $tooBig = $false
            while ($true) {
                $n = $fs.Read($buf, 0, 8192)
                if ($n -le 0) { break }
                $seen += [long]$n
                if ($seen -gt [long]$MaxBytes) { $tooBig = $true; break }
                $mem.Write($buf, 0, $n)
            }
            if ($tooBig) {
                return [pscustomobject]@{ ok = $false; reason = 'file-unreadable'; doc = $null }
            }
            $bytes = $mem.ToArray()
            if (($null -eq $bytes) -or (@($bytes).Count -eq 0)) {
                return [pscustomobject]@{ ok = $false; reason = 'file-unreadable'; doc = $null }
            }
            $strict = New-Object System.Text.UTF8Encoding($false, $true)
            $raw = $strict.GetString($bytes)
            $doc = ConvertFrom-Json $raw
            if ($null -eq $doc) {
                return [pscustomobject]@{ ok = $false; reason = 'json-invalid'; doc = $null }
            }
            if (($doc -is [System.Array]) -or (-not ($doc -is [PSCustomObject]))) {
                return [pscustomobject]@{ ok = $false; reason = 'json-invalid'; doc = $null }
            }
            return [pscustomobject]@{ ok = $true; reason = ''; doc = $doc }
        }
        finally { try { $fs.Dispose() } catch { } }
    }
    catch {
        return [pscustomobject]@{ ok = $false; reason = 'json-invalid'; doc = $null }
    }
}

# CLI entrypoint. Runs only when -Action is supplied, so dot-sourcing this
# file as a library defines the functions above and does nothing else.
if (-not [string]::IsNullOrWhiteSpace($Action)) {
    $act = ([string]$Action).Trim().ToLowerInvariant()
    if ($act -cne 'claim') {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'invalid-action')
        exit 2
    }
    $libDir = Join-Path $PSScriptRoot 'lib'
    $ndLib = Join-Path $libDir 'OrchestrationNativeDispatch.ps1'
    if (-not (Test-Path -LiteralPath $ndLib -PathType Leaf)) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'lib-unavailable')
        exit 1
    }
    try { . $ndLib }
    catch {
        # R5: a throwing library must escape through the fixed envelope
        # only. Never retry the dot-source and never print raw exception
        # text: the failure is reported, not explained.
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'lib-unavailable')
        exit 1
    }
    $needCmds = @('Invoke-OrchestrationNativeDispatchClaim', 'Get-NativeDispatchHash32', 'Get-NDCanonicalField', 'Resolve-NDGoalReceiptDir', 'Test-NDReceiptDirLive', 'Read-NDReceipt', 'Get-NDReceiptIntentView')
    $libsOk = $true
    foreach ($nc in $needCmds) {
        try {
            if ($null -eq (Get-Command $nc -ErrorAction SilentlyContinue)) { $libsOk = $false; break }
        }
        catch { $libsOk = $false; break }
    }
    if (-not $libsOk) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'lib-unavailable')
        exit 1
    }

    # ---------- context: file-owned, explicit, strict ----------
    $cf = ([string]$ContextFile).Trim()
    if ([string]::IsNullOrWhiteSpace($cf) -or (-not [IO.Path]::IsPathRooted($cf))) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'invalid-context-file')
        exit 2
    }
    $ctxSlot = Read-NCJsonFile -Path $cf -MaxBytes 65536
    if (-not [bool]$ctxSlot.ok) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'invalid-context-file')
        exit 2
    }
    $ctx = $ctxSlot.doc
    $ctxAllowed = @('schema_version', 'receipt_dir', 'goal_store_dir', 'tasks_dir', 'flags_path', 'authorization_file', 'idempotency_key', 'prepared_fingerprint', 'expected_caller_agent', 'expected_target_agent', 'expected_prompt_hash', 'expected_args_template')
    $ctxNames = @(Get-NCPropertyNames -Object $ctx)
    $ctxStrict = $true
    if (@($ctxNames).Count -ne @($ctxAllowed).Count) { $ctxStrict = $false }
    else {
        foreach ($cn in @($ctxNames)) {
            if ($ctxAllowed -cnotcontains $cn) { $ctxStrict = $false; break }
        }
    }
    if (-not $ctxStrict) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'invalid-context')
        exit 2
    }
    $ctxVerField = Get-NCRawField -Object $ctx -Name 'schema_version'
    if ((-not [bool]$ctxVerField.found) -or (-not (Test-NCRequestNumberOne -Value $ctxVerField.value))) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'invalid-context')
        exit 2
    }
    $rDirRaw = Get-NCValue $ctx 'receipt_dir' $null
    $gDirRaw = Get-NCValue $ctx 'goal_store_dir' $null
    $tDirRaw = Get-NCValue $ctx 'tasks_dir' $null
    $fPathRaw = Get-NCValue $ctx 'flags_path' $null
    $aFileRaw = Get-NCValue $ctx 'authorization_file' $null
    foreach ($cpField in @('receipt_dir', 'goal_store_dir', 'tasks_dir', 'flags_path', 'authorization_file')) {
        # R3: context paths must be JSON strings, never coerced numbers,
        # arrays or other shapes; anything else is an invalid context.
        # The raw shape is tested without pipeline enumeration.
        if (-not (Test-NCRawJsonString -Object $ctx -Name $cpField)) {
            Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'invalid-context')
            exit 2
        }
    }
    $rDir = ([string]$rDirRaw).Trim()
    $gDir = ([string]$gDirRaw).Trim()
    $tDir = ([string]$tDirRaw).Trim()
    $fPath = ([string]$fPathRaw).Trim()
    $aFile = ([string]$aFileRaw).Trim()
    foreach ($cp in @($rDir, $gDir, $tDir, $fPath, $aFile)) {
        if ([string]::IsNullOrWhiteSpace($cp) -or (-not [IO.Path]::IsPathRooted($cp))) {
            Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'invalid-context')
            exit 2
        }
    }
    $keyRaw = Get-NCValue $ctx 'idempotency_key' $null
    $pfpRaw = Get-NCValue $ctx 'prepared_fingerprint' $null
    $expPromptRaw = Get-NCValue $ctx 'expected_prompt_hash' $null
    foreach ($hxField in @('idempotency_key', 'prepared_fingerprint', 'expected_prompt_hash')) {
        if (-not (Test-NCRawJsonString -Object $ctx -Name $hxField)) {
            Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'invalid-context')
            exit 2
        }
    }
    $key = ([string]$keyRaw).Trim().ToLowerInvariant()
    $pfp = ([string]$pfpRaw).Trim().ToLowerInvariant()
    $expPrompt = ([string]$expPromptRaw).Trim().ToLowerInvariant()
    if ((-not (Test-NCHex32 -Value $key)) -or (-not (Test-NCHex32 -Value $pfp)) -or (-not (Test-NCHex32 -Value $expPrompt))) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'invalid-context')
        exit 2
    }
    $expCallerRaw = Get-NCValue $ctx 'expected_caller_agent' $null
    $expTargetRaw = Get-NCValue $ctx 'expected_target_agent' $null
    foreach ($agField in @('expected_caller_agent', 'expected_target_agent')) {
        if (-not (Test-NCRawJsonString -Object $ctx -Name $agField)) {
            Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'invalid-context')
            exit 2
        }
    }
    $expCaller = ([string]$expCallerRaw).Trim()
    $expTarget = ([string]$expTargetRaw).Trim()
    if ((-not (Test-NCAgentShape -Value $expCaller)) -or (-not (Test-NCAgentShape -Value $expTarget))) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'invalid-context')
        exit 2
    }
    $tmplField = Get-NCRawField -Object $ctx -Name 'expected_args_template'
    $tmpl = $null
    if ([bool]$tmplField.found) { $tmpl = $tmplField.value }
    if (($null -eq $tmpl) -or ($tmpl -is [System.Array]) -or (-not ($tmpl -is [PSCustomObject]))) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'invalid-context')
        exit 2
    }
    $tmplNames = @(Get-NCPropertyNames -Object $tmpl)
    $tmplOk = $true
    foreach ($tn in @($tmplNames)) {
        # Raw shape check: a one-element array must not unroll into a
        # string through the value reader below.
        if (-not (Test-NCRawJsonString -Object $tmpl -Name $tn)) { $tmplOk = $false; break }
    }
    if (-not $tmplOk) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'invalid-context')
        exit 2
    }
    $authSlot = Read-NCJsonFile -Path $aFile -MaxBytes 65536
    if (-not [bool]$authSlot.ok) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'invalid-authorization-file')
        exit 2
    }

    # ---------- request: stdin-owned, bounded by BYTES, strict ----------
    # R4: bytes are counted as read with a 65536+1 ceiling; exceeding it
    # refuses immediately WITHOUT draining the rest. Decoding uses a
    # strict UTF-8 decoder (throwOnInvalidBytes): invalid bytes refuse
    # with exit 2 instead of being substituted.
    $reqBytes = $null
    $reqTooLarge = $false
    try {
        $stdinStream = [Console]::OpenStandardInput()
        $mem = New-Object IO.MemoryStream
        $chunk = New-Object byte[] 8192
        $seen = [long]0
        while ($true) {
            $n = $stdinStream.Read($chunk, 0, 8192)
            if ($n -le 0) { break }
            $seen += [long]$n
            if ($seen -gt 65536) { $reqTooLarge = $true; break }
            $mem.Write($chunk, 0, $n)
        }
        $reqBytes = $mem.ToArray()
        try { $mem.Dispose() } catch { }
    }
    catch {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'request-unreadable')
        exit 1
    }
    if ($reqTooLarge) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'request-too-large')
        exit 2
    }
    if (($null -eq $reqBytes) -or (@($reqBytes).Count -eq 0)) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'empty-request')
        exit 2
    }
    $reqText = ''
    try {
        $strictIn = New-Object System.Text.UTF8Encoding($false, $true)
        $reqText = $strictIn.GetString($reqBytes)
    }
    catch {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'request-invalid-encoding')
        exit 2
    }
    if ([string]::IsNullOrWhiteSpace($reqText)) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'empty-request')
        exit 2
    }
    $req = $null
    try { $req = ConvertFrom-Json $reqText } catch { $req = $null }
    if (($null -eq $req) -or ($req -is [System.Array]) -or (-not ($req -is [PSCustomObject]))) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'invalid-request-json')
        exit 2
    }
    $reqAllowed = @('schema_version', 'session_id', 'message_id', 'call_id', 'caller_agent', 'target_agent', 'tool', 'args')
    $reqNames = @(Get-NCPropertyNames -Object $req)
    $reqStrict = $true
    if (@($reqNames).Count -ne @($reqAllowed).Count) { $reqStrict = $false }
    else {
        foreach ($rn in @($reqNames)) {
            if ($reqAllowed -cnotcontains $rn) { $reqStrict = $false; break }
        }
    }
    if (-not $reqStrict) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'invalid-request-shape')
        exit 2
    }
    $reqVerField = Get-NCRawField -Object $req -Name 'schema_version'
    if ((-not [bool]$reqVerField.found) -or (-not (Test-NCRequestNumberOne -Value $reqVerField.value))) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'invalid-request-shape')
        exit 2
    }
    $sidRaw = Get-NCValue $req 'session_id' $null
    $midRaw = Get-NCValue $req 'message_id' $null
    $cidRaw = Get-NCValue $req 'call_id' $null
    $callerRaw = Get-NCValue $req 'caller_agent' $null
    $targetRaw = Get-NCValue $req 'target_agent' $null
    $toolRaw = Get-NCValue $req 'tool' $null
    # R3: ids and agent/tool fields must be JSON strings. The raw shape is
    # tested without pipeline enumeration (a ["ses-x"] must not unroll
    # into "ses-x"); a JSON number (session_id:123) or any other shape is
    # a schema error (exit 2). Nothing is coerced and nothing is echoed.
    foreach ($fn in @('session_id', 'message_id', 'call_id', 'caller_agent', 'target_agent', 'tool')) {
        if (-not (Test-NCRawJsonString -Object $req -Name $fn)) {
            Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'invalid-request-value')
            exit 2
        }
    }
    $sid = ([string]$sidRaw)
    $mid = ([string]$midRaw)
    $cid = ([string]$cidRaw)
    $caller = ([string]$callerRaw)
    $target = ([string]$targetRaw)
    $tool = ([string]$toolRaw)
    if ((-not (Test-NCHostIdShape -Value $sid)) -or (-not (Test-NCHostIdShape -Value $mid)) -or (-not (Test-NCHostIdShape -Value $cid))) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'invalid-request-value')
        exit 2
    }
    if ((-not (Test-NCAgentShape -Value $caller)) -or (-not (Test-NCAgentShape -Value $target))) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'invalid-request-value')
        exit 2
    }
    if ([string]::IsNullOrWhiteSpace($tool)) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'invalid-request-value')
        exit 2
    }
    $argsField = Get-NCRawField -Object $req -Name 'args'
    $args = $null
    if ([bool]$argsField.found) { $args = $argsField.value }
    if (($null -eq $args) -or ($args -is [System.Array]) -or (-not ($args -is [PSCustomObject]))) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'invalid-request-value')
        exit 2
    }
    $cfpMaterial = 'ndcall1;'
    # KEEP IN SYNC WITH THE PLUGIN (R1b): buildIsolatedCallMaterial in
    # plugins/g1-dispatch-admission/index.js mirrors this exact field
    # order and the name:length:value; shape of Get-NDCanonicalField
    # (length counts UTF-16 code units on both sides). If the hash
    # algorithm changes, update both sides together.
    try {
        $cfpMaterial += Get-NDCanonicalField -Name 'session' -Value $sid
        $cfpMaterial += Get-NDCanonicalField -Name 'message' -Value $mid
        $cfpMaterial += Get-NDCanonicalField -Name 'call' -Value $cid
        $cfpMaterial += Get-NDCanonicalField -Name 'caller' -Value $caller
        $cfpMaterial += Get-NDCanonicalField -Name 'target' -Value $target
        $cfpMaterial += Get-NDCanonicalField -Name 'key' -Value $key
    }
    catch {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'claim-internal-error')
        exit 1
    }
    $cfp = ''
    try { $cfp = Get-NativeDispatchHash32 $cfpMaterial } catch { $cfp = '' }
    if ([string]::IsNullOrWhiteSpace($cfp)) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'claim-internal-error')
        exit 1
    }

    # ---------- binding: identity + template + prompt hash (all exit 0) ----------
    if ($tool -cne 'subagent') {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'claim-tool-mismatch' -Key $key -PreparedFp $pfp -SessionId $sid -MessageId $mid -CallId $cid -CallFp $cfp -CallMaterial $cfpMaterial -TargetAgent $target -ToolName $tool)
        exit 0
    }
    if ($caller -cne $expCaller) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'claim-caller-mismatch' -Key $key -PreparedFp $pfp -SessionId $sid -MessageId $mid -CallId $cid -CallFp $cfp -CallMaterial $cfpMaterial -TargetAgent $target -ToolName $tool)
        exit 0
    }
    if ($target -cne $expTarget) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'claim-target-mismatch' -Key $key -PreparedFp $pfp -SessionId $sid -MessageId $mid -CallId $cid -CallFp $cfp -CallMaterial $cfpMaterial -TargetAgent $target -ToolName $tool)
        exit 0
    }
    $argsNames = @(Get-NCPropertyNames -Object $args)
    # R3: every args value must be a JSON string, tested on the raw shape
    # (a one-element array must not unroll into a string). A wrong-typed
    # value (bool/array/object/number) where a string is expected is a
    # schema error (exit 2), never a silent mismatch. Missing/extra keys
    # or differing string values stay binding divergences (exit 0 below).
    foreach ($an in @($argsNames)) {
        if (-not (Test-NCRawJsonString -Object $args -Name $an)) {
            Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'invalid-args-value')
            exit 2
        }
    }
    $argsOk = $true
    if (@($argsNames).Count -ne @($tmplNames).Count) { $argsOk = $false }
    else {
        foreach ($tn in @($tmplNames)) {
            if ($argsNames -cnotcontains $tn) { $argsOk = $false; break }
            $av = Get-NCValue $args $tn $null
            $ev = Get-NCValue $tmpl $tn $null
            if (($null -eq $av) -or ($av -cne [string]$ev)) { $argsOk = $false; break }
        }
    }
    if (-not $argsOk) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'claim-args-template-mismatch' -Key $key -PreparedFp $pfp -SessionId $sid -MessageId $mid -CallId $cid -CallFp $cfp -CallMaterial $cfpMaterial -TargetAgent $target -ToolName $tool)
        exit 0
    }
    $promptText = Get-NCValue $args 'prompt' $null
    if (($null -eq $promptText) -or (-not ($promptText -is [string])) -or [string]::IsNullOrWhiteSpace([string]$promptText)) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'claim-prompt-missing' -Key $key -PreparedFp $pfp -SessionId $sid -MessageId $mid -CallId $cid -CallFp $cfp -CallMaterial $cfpMaterial -TargetAgent $target -ToolName $tool)
        exit 0
    }
    $promptHash = ''
    try { $promptHash = Get-NativeDispatchHash32 ([string]$promptText) } catch { $promptHash = '' }
    if ([string]::IsNullOrWhiteSpace($promptHash) -or ($promptHash -cne $expPrompt)) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'claim-prompt-hash-mismatch' -Key $key -PreparedFp $pfp -SessionId $sid -MessageId $mid -CallId $cid -CallFp $cfp -CallMaterial $cfpMaterial -TargetAgent $target -ToolName $tool)
        exit 0
    }

    # ---------- durable prompt anchor (SEC1): the AUTHORITY is the receipt --
    # The context hash above is only redundancy: both the template and the
    # expected hash come from the same fixture file, so a writer that owns
    # the context could swap the prompt. Here the prepared receipt itself
    # is re-read (pre-lock, with the same library helpers the CLAIM
    # entrypoint uses) and the request prompt hash is compared to the
    # DURABLE prompt_hash of the intent view. Divergence refuses with
    # receipt-prompt-mismatch and consumes nothing. The library file
    # OrchestrationNativeDispatch.ps1 is NOT modified: the CLAIM call
    # below still revalidates everything under its locks.
    $authGoalRaw = Get-NCValue $authSlot.doc 'goal_id' $null
    if (-not (Test-NCRawJsonString -Object $authSlot.doc -Name 'goal_id') -or [string]::IsNullOrWhiteSpace([string]$authGoalRaw)) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'invalid-authorization-file')
        exit 2
    }
    $authGoal = ([string]$authGoalRaw).Trim()
    $preState = $null
    try { $preState = Resolve-NDGoalReceiptDir -RootDir $rDir -GoalId $authGoal } catch { $preState = $null }
    $preDir = ''
    $preIdent = ''
    if ($null -ne $preState) {
        $preDir = ([string](Get-NCValue $preState 'dir' ''))
        $preIdent = ([string](Get-NCValue $preState 'created_utc' ''))
    }
    if ([string]::IsNullOrWhiteSpace($preDir)) {
        $preWhy = 'receipt-dir-unresolvable'
        try {
            $pw = ([string](Get-NCValue $preState 'reason' ''))
            if (-not [string]::IsNullOrWhiteSpace($pw)) { $preWhy = $pw }
        }
        catch { }
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason $preWhy -Key $key -PreparedFp $pfp -SessionId $sid -MessageId $mid -CallId $cid -CallFp $cfp -CallMaterial $cfpMaterial -TargetAgent $target -ToolName $tool)
        exit 0
    }
    $preLiveWhy = ''
    try { $preLiveWhy = Test-NDReceiptDirLive -Dir $preDir -Expected $preIdent } catch { $preLiveWhy = 'receipt-dir-identity-changed' }
    if (-not [string]::IsNullOrWhiteSpace($preLiveWhy)) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason $preLiveWhy -Key $key -PreparedFp $pfp -SessionId $sid -MessageId $mid -CallId $cid -CallFp $cfp -CallMaterial $cfpMaterial -TargetAgent $target -ToolName $tool)
        exit 0
    }
    $preRead = $null
    try { $preRead = Read-NDReceipt -Dir $preDir -Key $key -Expected $preIdent -AllowHandoffPhases } catch { $preRead = $null }
    if (($null -eq $preRead) -or (-not [bool](Get-NCValue $preRead 'ok' $false))) {
        $preReadWhy = 'receipt-unreadable'
        try {
            $prw = ([string](Get-NCValue $preRead 'reason' ''))
            if (-not [string]::IsNullOrWhiteSpace($prw)) { $preReadWhy = $prw }
        }
        catch { }
        if ($preReadWhy -ceq 'receipt-absent') { $preReadWhy = 'claim-not-prepared' }
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason $preReadWhy -Key $key -PreparedFp $pfp -SessionId $sid -MessageId $mid -CallId $cid -CallFp $cfp -CallMaterial $cfpMaterial -TargetAgent $target -ToolName $tool)
        exit 0
    }
    $preReceipt = Get-NCValue $preRead 'receipt' $null
    if ($null -eq $preReceipt) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'claim-not-prepared' -Key $key -PreparedFp $pfp -SessionId $sid -MessageId $mid -CallId $cid -CallFp $cfp -CallMaterial $cfpMaterial -TargetAgent $target -ToolName $tool)
        exit 0
    }
    $intentView = $null
    try { $intentView = Get-NDReceiptIntentView -Receipt $preReceipt } catch { $intentView = $null }
    if ($null -eq $intentView) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'claim-receipt-unusable' -Key $key -PreparedFp $pfp -SessionId $sid -MessageId $mid -CallId $cid -CallFp $cfp -CallMaterial $cfpMaterial -TargetAgent $target -ToolName $tool)
        exit 0
    }
    $storedPromptHash = ''
    try { $storedPromptHash = ([string](Get-NCValue $intentView 'prompt_hash' '')).Trim().ToLowerInvariant() } catch { $storedPromptHash = '' }
    if ([string]::IsNullOrWhiteSpace($storedPromptHash) -or ($storedPromptHash -cne $promptHash)) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'receipt-prompt-mismatch' -Key $key -PreparedFp $pfp -SessionId $sid -MessageId $mid -CallId $cid -CallFp $cfp -CallMaterial $cfpMaterial -TargetAgent $target -ToolName $tool)
        exit 0
    }

    # ---------- durable consumption: exactly ONE library CLAIM call ----------
    $claim = $null
    try {
        $claim = Invoke-OrchestrationNativeDispatchClaim -IdempotencyKey $key -Authorization $authSlot.doc -SessionId $sid -MessageId $mid -CallId $cid -CallerAgent $caller -TargetAgent $target -PreparedFingerprint $pfp -ReceiptDir $rDir -GoalStoreDir $gDir -TasksDir $tDir -FlagsPath $fPath -LockTimeoutMs 2000
    }
    catch { $claim = $null }
    if ($null -eq $claim) {
        Write-NCEnvelope (New-NCEnvelope -Ok $false -Reason 'claim-internal-error' -Key $key -PreparedFp $pfp -SessionId $sid -MessageId $mid -CallId $cid -CallFp $cfp -CallMaterial $cfpMaterial -TargetAgent $target -ToolName $tool)
        exit 1
    }
    Write-NCEnvelope (New-NCOkEnvelope -Claim $claim -Key $key -PreparedFp $pfp -CallFp $cfp -CallMaterial $cfpMaterial -TargetAgent $target -ToolName $tool)
    exit 0
}
