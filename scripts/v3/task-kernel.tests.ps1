<#
.SYNOPSIS
    Process-level CLI tests for task-kernel get-evidence.
    PowerShell 5.1/7 compatible, ASCII-only, temporary fixtures only.
#>
[CmdletBinding()]
param([string]$MeasurementPath = '')

$ErrorActionPreference = 'Stop'
$script:Passed = 0
$script:Failed = 0
$script:CliPath = Join-Path $PSScriptRoot 'task-kernel.ps1'
. (Join-Path $PSScriptRoot 'lib\OrchestrationTaskKernel.ps1')
$script:HostExe = ''
try { $script:HostExe = [string](Get-Process -Id $PID).Path } catch { }
if ([string]::IsNullOrWhiteSpace($script:HostExe)) { $script:HostExe = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }) }

function Assert-TaskKernelCli {
    param([bool]$Condition, [string]$Name, [string]$Detail = '')
    if ($Condition) { Write-Host ('[PASS] ' + $Name); $script:Passed++ }
    else { Write-Host ('[FAIL] ' + $Name + $(if ($Detail) { ' -- ' + $Detail })); $script:Failed++ }
}

function Invoke-TaskKernelCli {
    param([string[]]$CliArgs)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:HostExe
    $quoted = @()
    foreach ($arg in $CliArgs) { $quoted += ('"' + ([string]$arg).Replace('"', '\"') + '"') }
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:CliPath + '" ' + ($quoted -join ' ')
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = New-Object System.Diagnostics.Process; $p.StartInfo = $psi
    [void]$p.Start(); $stdout = $p.StandardOutput.ReadToEnd(); $stderr = $p.StandardError.ReadToEnd(); $p.WaitForExit()
    $code = [int]$p.ExitCode; $p.Dispose(); $json = $null
    try { if (-not [string]::IsNullOrWhiteSpace($stdout)) { $json = ConvertFrom-Json -InputObject $stdout } } catch { }
    return [pscustomobject]@{ ExitCode = $code; Stdout = $stdout; Stderr = $stderr; Json = $json }
}

function New-EvidenceFixture {
    param([string]$Id, [string]$Detail, [string]$Root, [string]$Tasks, [string]$Flags, [string]$Store = '')
    $args = @{ TaskId=$Id; Objective='Evidence recall fixture'; Actor='planner'; RuntimeId='opencode-v1'; RuntimeGeneration=1; RuntimeProfile='v1'; RuntimeVersion='1.18.32'; AttemptBudget=3; TasksDir=$Tasks; FlagsPath=$Flags; TelemetryRoot=$Root }
    $created = New-OrchestrationTask @args
    if (-not $created.ok) { throw ('fixture create failed: ' + $created.error) }
    $null = Invoke-OrchestrationTaskTransition -TaskId $Id -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision 1 -TasksDir $Tasks -FlagsPath $Flags
    $null = Invoke-OrchestrationTaskTransition -TaskId $Id -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision 2 -ActorIdentitySource 'explicit-cli' -TasksDir $Tasks -FlagsPath $Flags
    $setArgs = @{ TaskId=$Id; Status='failed'; ProducedBy='coder'; FailureDetail=$Detail; ExpectedRevision=3; TasksDir=$Tasks; FlagsPath=$Flags; TelemetryRoot=$Root }
    if ($Store) { $setArgs.EvidenceStoreDir=$Store; $setArgs.RepoRoot=$Root }
    $recorded = Set-OrchestrationTaskWorkerResult @setArgs
    if (-not $recorded.ok) { throw ('fixture result failed: ' + $recorded.error) }
    return (Get-OrchestrationTask -TaskId $Id -TasksDir $Tasks)
}

function New-EvidencePendingTask {
    param([string]$Id, [string]$Root, [string]$Tasks, [string]$Flags)
    $created = New-OrchestrationTask -TaskId $Id -Objective 'CLI record-result fixture' -Actor 'planner' -RuntimeId 'opencode-v1' `
        -RuntimeGeneration 1 -RuntimeProfile 'v1' -RuntimeVersion '1.18.32' -AttemptBudget 3 `
        -TasksDir $Tasks -FlagsPath $Flags -TelemetryRoot $Root
    if (-not $created.ok) { throw ('CLI fixture create failed: ' + $created.error) }
    $null = Invoke-OrchestrationTaskTransition -TaskId $Id -ToState 'PLANNING' -Actor 'planner' -ExpectedRevision 1 -TasksDir $Tasks -FlagsPath $Flags
    $null = Invoke-OrchestrationTaskTransition -TaskId $Id -ToState 'IMPLEMENTING' -Actor 'planner' -ExpectedRevision 2 -ActorIdentitySource 'explicit-cli' -TasksDir $Tasks -FlagsPath $Flags
}

$repoRoot = Get-TaskKernelRepoRoot -RepoRoot ''
$root = Join-Path ([IO.Path]::GetTempPath()) ('task-kernel-evidence-' + [guid]::NewGuid().ToString('N'))
$tasks = Join-Path $root 'tasks'; $store = Join-Path $repoRoot ('cache\runtime\evidence-test-' + [guid]::NewGuid().ToString('N')); $otherStore = Join-Path $repoRoot ('cache\runtime\other-evidence-' + [guid]::NewGuid().ToString('N')); $flags = Join-Path $root 'flags.json'
$cliTasks = Get-TaskKernelDefaultTasksDir -RepoRoot ''; $cliFlags = Get-TaskKernelDefaultFlagsPath -RepoRoot ''
try {
    New-Item -ItemType Directory -Path $tasks -Force | Out-Null
    [IO.File]::WriteAllText($flags, '{"task_kernel":{"enabled":true,"shadow":false}}', [Text.UTF8Encoding]::new($false))
    $detail = 'cli-evidence-' + ('z' * 200000)
    $utf8Bytes = [Text.Encoding]::UTF8.GetByteCount($detail)
    $legacy = New-EvidenceFixture -Id 'evidence-cli-legacy' -Detail $detail -Root $root -Tasks $tasks -Flags $flags
    $record = New-EvidenceFixture -Id 'evidence-cli-virtual' -Detail $detail -Root $repoRoot -Tasks $tasks -Flags $flags -Store $store
    $legacyFile = Join-Path $tasks 'evidence-cli-legacy.json'; $recordFile = Join-Path $tasks 'evidence-cli-virtual.json'
    $entry = @($record['attempts'][0]['evidence_artifacts'])[0]
    $artifactPath = Join-Path (Join-Path $store ([string]$entry['kind'])) ([string]$entry['sha256'] + '.txt')
    $artifactBytes = [IO.File]::ReadAllBytes($artifactPath).Length
    $argsBase = @('-Action','get-evidence','-TaskId','evidence-cli-virtual','-TasksDir',$tasks,'-FlagsPath',$flags)

    $fullTimer = [Diagnostics.Stopwatch]::StartNew()
    $byAttempt = Invoke-TaskKernelCli ($argsBase + @('-Attempt','1','-Full'))
    $fullTimer.Stop()
    $byHash = Invoke-TaskKernelCli ($argsBase + @('-ArtifactId',[string]$entry['sha256'],'-Full'))
    Assert-TaskKernelCli ($byAttempt.ExitCode -eq 0 -and $byAttempt.Json.ok -and $byAttempt.Json.verified -and [string]$byAttempt.Json.content -ceq $detail) 'c3 recall by attempt returns byte-identical verified content' ($byAttempt.Stderr)
    Assert-TaskKernelCli ($byHash.ExitCode -eq 0 -and $byHash.Json.ok -and $byHash.Json.verified -and [string]$byHash.Json.content -ceq $detail) 'c3 recall by artifact id returns byte-identical verified content' ($byHash.Stderr)
    $previewOnly = Invoke-TaskKernelCli ($argsBase + @('-Attempt','1'))
    Assert-TaskKernelCli ($previewOnly.ExitCode -eq 0 -and $previewOnly.Json.verified -and $previewOnly.Json.preview.Length -le 2000 -and $null -eq $previewOnly.Json.PSObject.Properties['content']) 'c3 preview-only response omits full content'
    $missing = Invoke-TaskKernelCli ($argsBase + @('-ArtifactId',('0' * 64)))
    Assert-TaskKernelCli ($missing.ExitCode -eq 1 -and $missing.Json.error -ceq 'EVIDENCE_ARTIFACT_NOT_FOUND') 'c3 nonexistent artifact id returns domain error'
    $escaped = Invoke-TaskKernelCli ($argsBase + @('-Attempt','1','-Full','-StoreDir',$otherStore))
    Assert-TaskKernelCli ($escaped.ExitCode -eq 1 -and -not $escaped.Json.ok -and $escaped.Json.error -ceq 'ARTIFACT_NOT_FOUND') 'c3 alternate store cannot read original store artifact'
    [IO.File]::AppendAllText($artifactPath, 'tamper', [Text.Encoding]::UTF8)
    $tampered = Invoke-TaskKernelCli ($argsBase + @('-Attempt','1','-Full'))
    Assert-TaskKernelCli ($tampered.ExitCode -eq 1 -and -not $tampered.Json.ok -and -not $tampered.Json.verified -and $tampered.Json.error -ceq 'ARTIFACT_HASH_MISMATCH') 'c3 tampered artifact fails hash verification'
    $bothSelectors = Invoke-TaskKernelCli ($argsBase + @('-Attempt','1','-ArtifactId',[string]$entry['sha256']))
    $noSelector = Invoke-TaskKernelCli @('-Action','get-evidence','-TaskId','evidence-cli-virtual')
    Assert-TaskKernelCli ($bothSelectors.ExitCode -eq 2 -and $noSelector.ExitCode -eq 2) 'G selector validation rejects both and neither selector'
    $noArtifactTask = Invoke-TaskKernelCli @('-Action','get-evidence','-TaskId','evidence-cli-legacy','-Attempt','1','-TasksDir',$tasks)
    Assert-TaskKernelCli ($noArtifactTask.ExitCode -eq 1 -and $noArtifactTask.Json.error -ceq 'EVIDENCE_ARTIFACT_NOT_FOUND') 'G attempt without artifact returns domain error'
    $wrongRoot = Invoke-TaskKernelCli @('-Action','record-result','-TaskId','evidence-trusted-path','-WorkerStatus','failed','-ProducedBy','coder','-ExpectedRevision','3','-FailureDetail','some detail','-EvidenceStoreDir',$store,'-CliRepoRoot',$root,'-TasksDir',$cliTasks,'-FlagsPath',$cliFlags)
    Assert-TaskKernelCli ($wrongRoot.ExitCode -eq 1 -and $wrongRoot.Json.error -ceq 'TRUSTED_PATH_MISMATCH' -and $wrongRoot.Json.path_role -ceq 'repo_root') 'G record-result rejects untrusted CliRepoRoot'
    $wrongTasks = Invoke-TaskKernelCli @('-Action','record-result','-TaskId','evidence-trusted-path','-WorkerStatus','failed','-ProducedBy','coder','-ExpectedRevision','3','-FailureDetail','some detail','-EvidenceStoreDir',$store,'-TasksDir',$tasks,'-FlagsPath',$cliFlags)
    $wrongFlags = Invoke-TaskKernelCli @('-Action','record-result','-TaskId','evidence-trusted-path','-WorkerStatus','failed','-ProducedBy','coder','-ExpectedRevision','3','-FailureDetail','some detail','-EvidenceStoreDir',$store,'-TasksDir',$cliTasks,'-FlagsPath',$flags)
    Assert-TaskKernelCli ($wrongTasks.Json.path_role -ceq 'tasks_dir' -and $wrongFlags.Json.path_role -ceq 'flags_path') 'G record-result identifies untrusted task and flags paths'
    $outsideStore = Invoke-TaskKernelCli @('-Action','record-result','-TaskId','evidence-trusted-path','-WorkerStatus','failed','-ProducedBy','coder','-ExpectedRevision','3','-FailureDetail',('x' * 5000),'-EvidenceStoreDir',$root)
    $rootStore = Invoke-TaskKernelCli @('-Action','record-result','-TaskId','evidence-trusted-path','-WorkerStatus','failed','-ProducedBy','coder','-ExpectedRevision','3','-FailureDetail',('x' * 5000),'-EvidenceStoreDir',$repoRoot)
    Assert-TaskKernelCli ($outsideStore.Json.error -ceq 'EVIDENCE_STORE_OUTSIDE_REPO' -and $rootStore.Json.error -ceq 'EVIDENCE_STORE_OUTSIDE_REPO') 'G rejects store outside repository and store equal to repository root'
    $invalidThreshold = Invoke-TaskKernelCli @('-Action','record-result','-TaskId','bad-threshold','-WorkerStatus','failed','-ProducedBy','coder','-ExpectedRevision','3','-FailureDetail','small','-EvidenceStoreDir',$store,'-VirtualizeThresholdBytes','1')
    Assert-TaskKernelCli ($invalidThreshold.ExitCode -eq 1 -and $invalidThreshold.Json.error -ceq 'EVIDENCE_THRESHOLD_INVALID') 'G invalid virtualization threshold is rejected'

    # Exercise record-result through the real CLI, with and without opt-in.
    $cliSuffix = [guid]::NewGuid().ToString('N').Substring(0,8)
    $cliLegacyId = 'evidence-cli-legacy-' + $cliSuffix; $cliVirtualId = 'evidence-cli-store-' + $cliSuffix
    New-Item -ItemType Directory -Path $cliTasks -Force | Out-Null
    New-EvidencePendingTask -Id $cliLegacyId -Root $repoRoot -Tasks $cliTasks -Flags $cliFlags
    New-EvidencePendingTask -Id $cliVirtualId -Root $repoRoot -Tasks $cliTasks -Flags $cliFlags
    $cliDetail = 'cli-record-payload-' + ('p' * 5200)
    $secretDetail = 'before sk-SYNTHETICSECRET after ' + $cliDetail
    $legacyRecordResult = Invoke-TaskKernelCli @('-Action','record-result','-TaskId',$cliLegacyId,'-WorkerStatus','failed','-ProducedBy','coder','-ExpectedRevision','3','-FailureDetail',$secretDetail)
    $legacyCliRead = Get-OrchestrationTask -TaskId $cliLegacyId -TasksDir $cliTasks
    $legacyCliAttempt = @($legacyCliRead['attempts'])[0]
    Assert-TaskKernelCli ($legacyRecordResult.ExitCode -eq 0 -and -not $legacyCliAttempt.Contains('evidence_artifacts') -and ([string]$legacyCliAttempt['failure_detail']).Length -le 2000 -and ([string]$legacyCliAttempt['failure_detail']) -ceq (Protect-TaskKernelText -Text $secretDetail)) 'record-result CLI without store preserves legacy redacted truncation'

    $cliStore = Join-Path $repoRoot ('cache\runtime\evidence-test-' + [guid]::NewGuid().ToString('N'))
    $virtualDetail = 'prefix sk-SYNTHETICSECRET suffix ' + $cliDetail
    $virtualRecordResult = Invoke-TaskKernelCli @('-Action','record-result','-TaskId',$cliVirtualId,'-WorkerStatus','failed','-ProducedBy','coder','-ExpectedRevision','3','-FailureDetail',$virtualDetail,'-EvidenceStoreDir',$cliStore)
    $virtualCliRead = Get-OrchestrationTask -TaskId $cliVirtualId -TasksDir $cliTasks
    $virtualCliAttempt = @($virtualCliRead['attempts'])[0]
    $virtualCliEntry = @($virtualCliAttempt['evidence_artifacts'])[0]
    $cliEndToEnd = Invoke-TaskKernelCli @('-Action','get-evidence','-TaskId',$cliVirtualId,'-Attempt','1','-Full')
    $explicitStore = Invoke-TaskKernelCli @('-Action','get-evidence','-TaskId',$cliVirtualId,'-Attempt','1','-Full','-TasksDir',$cliTasks,'-StoreDir',$cliStore)
    Assert-TaskKernelCli ($explicitStore.ExitCode -eq 0 -and $explicitStore.Json.verified) 'get-evidence accepts explicit confined StoreDir'
    $persistedRedacted = Get-TaskKernelRedactedText -Text $virtualDetail
    Assert-TaskKernelCli ($virtualRecordResult.ExitCode -eq 0 -and $virtualCliEntry['store_rel'] -and -not $virtualCliEntry.Contains('store_dir') -and $virtualCliEntry['sha256'] -match '^[0-9a-f]{64}$' -and $virtualCliEntry['preview'] -notlike '*sk-SYNTHETICSECRET*' -and $cliEndToEnd.ExitCode -eq 0 -and $cliEndToEnd.Json.verified -and [string]$cliEndToEnd.Json.content -ceq $persistedRedacted -and [string]$cliEndToEnd.Json.content -notlike '*sk-SYNTHETICSECRET*') 'record-result CLI redacts secrets and recalls persisted content byte-identically via store_rel'
    $cliRecordPath = Join-Path $cliTasks ($cliVirtualId + '.json')
    $originalRecordJson = [IO.File]::ReadAllText($cliRecordPath)
    $tamperedRecord = ConvertFrom-Json $originalRecordJson
    $tamperedRecord.attempts[0].evidence_artifacts[0].kind = '../escape'
    [IO.File]::WriteAllText($cliRecordPath, ($tamperedRecord | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    $badKind = Invoke-TaskKernelCli @('-Action','get-evidence','-TaskId',$cliVirtualId,'-Attempt','1')
    $tamperedRecord = ConvertFrom-Json $originalRecordJson
    $legacyTamperedEntry = $tamperedRecord.attempts[0].evidence_artifacts[0]
    $legacyTamperedEntry.PSObject.Properties.Remove('store_rel')
    $legacyTamperedEntry | Add-Member -NotePropertyName store_dir -NotePropertyValue 'Z:\\missing-evidence-store' -Force
    [IO.File]::WriteAllText($cliRecordPath, ($tamperedRecord | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    $missingDrive = Invoke-TaskKernelCli @('-Action','get-evidence','-TaskId',$cliVirtualId,'-Attempt','1')
    Assert-TaskKernelCli ($badKind.ExitCode -eq 1 -and $badKind.Json.error -ceq 'ARTIFACT_KIND_INVALID' -and $missingDrive.ExitCode -eq 1 -and $missingDrive.Json.error -ceq 'ARTIFACT_PATH_ESCAPE' -and $missingDrive.Stdout -notmatch 'at line:|Join-Path') 'G tampered kind and legacy out-of-root store return structured JSON errors'

    $tamperedRecord = ConvertFrom-Json $originalRecordJson
    $tamperedRecord.attempts[0].evidence_artifacts[0].store_rel = '..\\..\\fora'
    [IO.File]::WriteAllText($cliRecordPath, ($tamperedRecord | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    $relativeEscape = Invoke-TaskKernelCli @('-Action','get-evidence','-TaskId',$cliVirtualId,'-Attempt','1')
    Assert-TaskKernelCli ($relativeEscape.ExitCode -eq 1 -and $relativeEscape.Json.error -ceq 'ARTIFACT_PATH_ESCAPE' -and $relativeEscape.Stdout -notmatch 'at line:|Join-Path') 'G rejects traversal in store_rel with domain JSON error'

    $tamperedRecord = ConvertFrom-Json $originalRecordJson
    $tamperedRecord.attempts[0].evidence_artifacts[0].store_rel = 'C:\\Windows'
    [IO.File]::WriteAllText($cliRecordPath, ($tamperedRecord | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    $absoluteEscape = Invoke-TaskKernelCli @('-Action','get-evidence','-TaskId',$cliVirtualId,'-Attempt','1')
    Assert-TaskKernelCli ($absoluteEscape.ExitCode -eq 1 -and $absoluteEscape.Json.error -ceq 'ARTIFACT_PATH_ESCAPE' -and $absoluteEscape.Stdout -notmatch 'at line:|Join-Path') 'G rejects absolute store_rel with domain JSON error'

    $tooLargeTask = 'evidence-too-large-' + $cliSuffix
    New-EvidencePendingTask -Id $tooLargeTask -Root $repoRoot -Tasks $cliTasks -Flags $cliFlags
    $tooLarge = Set-OrchestrationTaskWorkerResult -TaskId $tooLargeTask -Status failed -ProducedBy coder -ExpectedRevision 3 -FailureDetail ('x' * 1100000) -TasksDir $cliTasks -FlagsPath $cliFlags -EvidenceStoreDir $cliStore -RepoRoot $repoRoot
    $tooLargeRecord = Get-OrchestrationTask -TaskId $tooLargeTask -TasksDir $cliTasks
    Assert-TaskKernelCli ($tooLarge.ok -and $tooLargeRecord.attempts[0].evidence_artifact_error -ceq 'ARTIFACT_TOO_LARGE') 'D oversized artifact failure is recorded without failing worker result'

    $detailBytes = $artifactBytes
    $previewBytes = [Text.Encoding]::UTF8.GetByteCount([string]$entry['preview'])
    $measurement = [ordered]@{
        detail_bytes = $utf8Bytes
        record_bytes_without_virtualization = [IO.File]::ReadAllBytes($legacyFile).Length
        record_bytes_with_virtualization = [IO.File]::ReadAllBytes($recordFile).Length
        artifact_bytes = $detailBytes
        preview_bytes = $previewBytes
        recall_ms = [long]$fullTimer.ElapsedMilliseconds
        tokens = @{ estimate='chars/4'; value=[int][Math]::Ceiling($detail.Length / 4.0) }
        recall_integrity = @{ hash_verified=[bool]$byAttempt.Json.verified; byte_identical=([string]$byAttempt.Json.content -ceq $detail) }
        redaction = 'applied'
        redaction_fail_closed = $true
        store_rel = [bool]$entry['store_rel']
        decision = 'Adopt opt-in virtualization: complete redacted detail is stored externally and hash-verified; the legacy record remains bounded to 2000 characters. Redaction avoids persisting secret material at rest.'
        generated_at = [DateTime]::UtcNow.ToString('o')
        runtime = ('PowerShell ' + $PSVersionTable.PSVersion.ToString() + ' (' + $PSVersionTable.PSEdition + ')')
    }
    if (-not [string]::IsNullOrWhiteSpace($MeasurementPath)) {
        $measurementParent = Split-Path -Parent $MeasurementPath
        if ($measurementParent) { New-Item -ItemType Directory -Path $measurementParent -Force | Out-Null }
        [IO.File]::WriteAllText($MeasurementPath, ($measurement | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    }
    Assert-TaskKernelCli ($detailBytes -eq $utf8Bytes -and $measurement.record_bytes_with_virtualization -gt 0 -and $measurement.record_bytes_without_virtualization -gt 0 -and $measurement.recall_integrity.hash_verified) 'c6 records observed bytes and verified recall measurement'
}
catch { Write-Host ('[FAIL] unexpected error: ' + $_); Write-Host ('[FAIL] stack: ' + $_.ScriptStackTrace); $script:Failed++ }
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    foreach ($path in @($store, $otherStore, $cliStore)) { if ($path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue } }
    foreach ($id in @($cliLegacyId,$cliVirtualId,$tooLargeTask)) { if ($id) { $file = Join-Path $cliTasks ($id + '.json'); if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue } } }
}

Write-Host ('TASK-KERNEL-CLI: ' + $script:Passed + ' passed / ' + $script:Failed + ' failed')
if ($script:Failed -gt 0) { exit 1 }; exit 0
