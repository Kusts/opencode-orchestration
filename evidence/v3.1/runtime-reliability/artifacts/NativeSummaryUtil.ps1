function Format-OrchestrationSummary {
    param(
        [Parameter(Mandatory=$true)][string]$Title,
        [Parameter(Mandatory=$true)][string]$Status
    )
    return "[$Status] $Title"
}