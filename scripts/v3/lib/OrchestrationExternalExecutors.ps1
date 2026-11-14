[CmdletBinding()]
param()

function Get-OcExternalExecutors {
    $run = {
        param($Intent, $Evidence)
        $args = @('-m','telegran.cli','fetch-one','--course',[string]$Intent.request.course,'--message-id',[string]$Intent.request.message_id)
        if ($Intent.action -eq 'telegran.learn-one') {
            $args = @('-m','telegran.cli','learn','--course',[string]$Intent.request.course,'--message-id',[string]$Intent.request.message_id,'--workspace','clientes','--project','telegran')
        }
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = Join-Path ([string]$Intent.fixed.repo) '.venv\Scripts\python.exe'
        $psi.WorkingDirectory = [string]$Intent.fixed.repo
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.Arguments = (@($args | ForEach-Object { '"' + ([string]$_).Replace('"','\"') + '"' }) -join ' ')
        $p = New-Object Diagnostics.Process
        $p.StartInfo = $psi
        $maxChars = 8192
        try {
            [void]$p.Start()
            $ot = $p.StandardOutput.ReadToEndAsync()
            $et = $p.StandardError.ReadToEndAsync()
            if (-not $p.WaitForExit([int]$Intent.timeout_seconds * 1000)) {
                try { $p.Kill() } catch {}
                try { $p.WaitForExit() } catch {}
                try { [void]$ot.Wait(1000) } catch {}
                try { [void]$et.Wait(1000) } catch {}
                $Intent | Add-Member -NotePropertyName output_hash -NotePropertyValue '' -Force
                $Intent | Add-Member -NotePropertyName output_tail -NotePropertyValue '' -Force
                return @{ status='UNKNOWN' }
            }
            try { $p.WaitForExit() } catch {}
            $stdout = $ot.Result
            $stderr = $et.Result
            $stdout = $stdout.Substring(0,[Math]::Min($stdout.Length,$maxChars))
            $stderr = $stderr.Substring(0,[Math]::Min($stderr.Length,$maxChars))
            $text = $stdout + "`n" + $stderr
            $text = [regex]::Replace($text,'(?i)([A-Z0-9_]*(?:API_KEY|TOKEN|AUTH_TOKEN))\s*[=:]\s*\S+','$1=[REDACTED]')
            $h = [Security.Cryptography.SHA256]::Create()
            try { $hash = [BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-','') } finally { $h.Dispose() }
            $tail = $text.Substring([Math]::Max(0,$text.Length-512))
            $Intent | Add-Member -NotePropertyName output_hash -NotePropertyValue $hash -Force
            $Intent | Add-Member -NotePropertyName output_tail -NotePropertyValue $tail -Force
            try { $exit = $p.ExitCode } catch { return @{ status='UNKNOWN' } }
            return @{ status=$(if($exit -eq 0){'PASS'}else{'FAIL'}) }
        } catch { return @{ status='UNKNOWN' } }
        finally { $p.Dispose() }
    }
    return @{ 'telegran.fetch-one-message'=$run; 'telegran.learn-one'=$run }
}
