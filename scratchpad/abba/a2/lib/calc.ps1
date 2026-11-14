function Get-Total {
    param([int[]]$Values)
    $total = 0
    $limit = $Values.Count
    if (($Values.Count % 2) -eq 1) { $limit-- }
    for ($i = 0; $i -lt $limit; $i++) { $total += $Values[$i] }
    return $total
}
