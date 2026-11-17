# Removes from the driver store the OLD versions of third-party drivers (the newest is always kept).
# Never touches a version used by a present device, or inbox drivers.
# Does not depend on the CSV files. Without -Apply it only shows a preview.
param([switch]$Apply)
. "$PSScriptRoot\common.ps1"
Assert-Admin
Start-Log 'remove-old-versions'
Write-ModeBanner $Apply

Write-Host (T 'Reading the installed drivers and how they are used...') -ForegroundColor Green
$pkgs = @(Get-DriverPackages | Where-Object { $_.Driver -like 'oem*.inf' })
$use = Get-DriverUsage

$cands = @($pkgs | Where-Object {
    $leaf = Split-Path $_.OriginalFileName -Leaf
    -not (Test-Excluded ('{0} {1}' -f $_.ProviderName, $leaf) $_.ClassName)
})
$groups = $cands | Group-Object { '{0}|{1}|{2}' -f (Split-Path $_.OriginalFileName -Leaf), $_.ProviderName, $_.ClassName }

$total = 0
foreach ($g in $groups) {
    if ($g.Count -lt 2) { continue }
    $sorted = @($g.Group | Sort-Object @{ Expression = { $_.Date }; Descending = $true }, @{ Expression = { ConvertTo-Ver $_.Version }; Descending = $true })
    $newest = $sorted[0]
    foreach ($old in ($sorted | Select-Object -Skip 1)) {
        $total++
        $leaf = Split-Path $old.OriginalFileName -Leaf
        $label = (T '{0} | {1} | v{2} (newest: v{3})' $old.Driver $leaf $old.Version $newest.Version)
        if ([int]$use.Present[$old.Driver.ToLower()] -gt 0) {
            Add-Outcome $label $old.Driver (T 'In use: skipped (update the drivers first, restart and run again)') 'warn'
            continue
        }
        if (-not $Apply) { Add-Outcome $label $old.Driver (T 'Preview (would be removed)') 'preview'; continue }
        $r = Invoke-Pnp @('/delete-driver', $old.Driver)
        if ($r.Ok) { Add-Outcome $label $old.Driver (T 'Removed') 'ok' }
        else { Add-Outcome $label $old.Driver ((T 'NOT removed:') + ' ' + ($r.Output -replace '\s+', ' ')) 'err' }
    }
}
if ($total -eq 0) { Write-Host (T 'No old version found: the drivers are already tidy.') }

Save-Outcomes 'old-versions'
Write-AfterRun $Apply @(T 'If a device stops working, reinstall the driver from the backup.')
Stop-Log
