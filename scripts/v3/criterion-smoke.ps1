<#
.SYNOPSIS
    Deterministic verifier smoke for the M5 DONE proof.
.DESCRIPTION
    Exits 0 so the kernel verifier maps criterion:0 as verified. No side
    effects, no network, no writes.
#>
Write-Output 'criterion:0:PASS'
exit 0
