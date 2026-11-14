function Get-Total {
    param([int[]]$Values)
    $total = 0
    for ($i = 0; $i -lt $Values.Count; $i++) { $total += $Values[$i] }
    return $total
}
