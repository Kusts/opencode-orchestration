function Get-SanityAnswer {
    return 42
}

if ((Get-SanityAnswer) -ne 42) {
    throw "Sanity check failed"
}

Write-Output "SANITY OK"
