# Removes from the Windows driver store the oemNN.inf packages marked REMOVE or REMOVE+UNINSTALL in reports\drivers.csv
# Checks: third-party only, not excluded, still installed and still the same .inf as in the inventory.
# REMOVE refuses drivers that are in use; REMOVE+UNINSTALL also removes them from the devices using them.
# Without -Apply it only shows a preview.
# -BlockReinstall (optional): after removing a driver, also block the hardware ID of its devices so Windows does not install it again.
param([switch]$Apply, [switch]$BlockReinstall)
. "$PSScriptRoot\common.ps1"
Assert-Admin
Start-Log 'remove-drivers'
Write-ModeBanner $Apply

$rows = @(Read-ReportCsv 'drivers')
if ($rows.Count -eq 0) { Stop-Log; exit 1 }
$todo = @($rows | Where-Object { $_.Action -match '^REMOVE' })
Write-Host (T 'Drivers to remove: {0} of {1}' $todo.Count $rows.Count)

Write-Host (T 'Reading the installed drivers...') -ForegroundColor Green
$installed = @{}
Get-DriverPackages | Where-Object { $_.Driver -like 'oem*.inf' } | ForEach-Object { $installed[$_.Driver.ToLower()] = $_ }

Write-Host (T 'Checking which drivers are in use right now...') -ForegroundColor Green
$usage = Get-DriverUsage
$blockClasses = @('Display', 'System', 'Firmware', 'SCSIAdapter', 'HDC', 'Processor', 'USB', 'Net', 'Bluetooth', 'Keyboard', 'Mouse', 'HIDClass', 'DiskDrive', 'Volume')
$total = @($todo).Count; $index = 0
$toHide = @()
foreach ($r in $todo) {
    Write-Prog $index $total; $index++
    $drv = "$($r.Driver)".Trim()
    $label = '{0} | {1} | {2}' -f $drv, $r.InfName, $r.Provider

    if ($drv -notmatch '^oem\d+\.inf$') { Add-Outcome $label $drv (T 'Not a third-party driver: skipped') 'warn'; continue }
    if (Test-Excluded ('{0} {1}' -f $r.Provider, $r.InfName) $r.Class) { Add-Outcome $label $drv (T 'Excluded in settings: skipped') 'warn'; continue }
    $cur = $installed[$drv.ToLower()]
    if (-not $cur) { Add-Outcome $label $drv (T 'Already removed') 'ok'; continue }
    $curLeaf = Split-Path $cur.OriginalFileName -Leaf
    if ($curLeaf -ne $r.InfName) { Add-Outcome $label $drv (T 'It is now a different package ({0}): skipped' $curLeaf) 'warn'; continue }
    # A driver used by a connected device is never removed here: to change it, install the right version from the catalog
    if ([int]$usage.Present[$drv.ToLower()] -gt 0) { Add-Outcome $label $drv (T 'In use by a connected device: not removed (to replace it, install the right version from the catalog)') 'warn'; continue }
    if (-not $Apply) {
        $extra = ''
        if ($BlockReinstall) { $extra = ' ' + (T '(and Windows would be stopped from installing it again)') }
        Add-Outcome $label $drv ((T 'Preview (would be removed)') + $extra) 'preview'; continue
    }

    $swcIds = @(); try { $swcIds = @(Get-SwcIdsFromInf $cur.OriginalFileName) } catch { }
    $a = @('/delete-driver', $drv)
    if ($r.Action -match 'UNINSTALL') { $a += '/uninstall' }
    $p = Invoke-Pnp $a
    if ($p.Ok) {
        Add-Outcome $label $drv (T 'Removed') 'ok'
        if ($swcIds.Count -gt 0) { Start-Sleep -Seconds 2; try { $null = Remove-SwcGhosts $swcIds } catch { } }
        else { try { Start-Sleep -Seconds 2; $null = Remove-RelatedGhosts "$($r.InfName)" } catch { } }
        if ($BlockReinstall) {
            if ($blockClasses -contains "$($r.Class)") { Add-Outcome $label $drv (T 'Not blocked from coming back: {0} drivers are too important to block' $r.Class) 'warn' }
            else {
                $ids = @(@("$($r.HardwareIds)" -split '\s*\|\s*') + $swcIds | Where-Object { $_ -and (Test-BlockableId $_) } | Select-Object -Unique)
                if ($ids.Count -eq 0) { if ("$($r.Class)" -eq 'Extension') { $toHide += $r } else { Add-Outcome $label $drv (T 'No device ID to block: Windows may install it again') 'warn' } }
                foreach ($id in $ids) {
                    try { $res = Add-BlockedId $id $drv $r.InfName $r.Provider $r; Add-Outcome $label $id (T 'Windows is stopped from installing this device again (undo it in Device management)') 'ok' }
                    catch { Add-Outcome $label $id ((T 'Could not block:') + ' ' + $_.Exception.Message) 'err' }
                }
            }
        }
    }
    else { Add-Outcome $label $drv ((T 'NOT removed (in use?):') + ' ' + ($p.Output -replace '\s+', ' ')) 'err' }
}

if ($toHide.Count -gt 0) {
    Write-Host (T 'Asking Windows Update to hide the removed extension drivers (it can take a minute)...') -ForegroundColor Green
    $hres = $null
    try { Add-WuHidePending $toHide } catch { }
    try { $hres = @(Hide-WuDriverUpdates $toHide) } catch { foreach ($pk in $toHide) { Add-Outcome ('{0} | {1} | {2}' -f $pk.Driver, $pk.InfName, $pk.Provider) $pk.Driver ((T 'Could not hide the Windows Update driver:') + ' ' + $_.Exception.Message) 'err' } }
    foreach ($x in @($hres)) {
        $lb = '{0} | {1} | {2}' -f $x.Pkg.Driver, $x.Pkg.InfName, $x.Pkg.Provider
        if ($x.Hidden) { Add-Outcome $lb $x.Title (T 'Windows Update will not offer this driver again (undo it in Device management)') 'ok' }
        else { Add-Outcome $lb $x.Pkg.Driver (T 'Windows Update is not offering this driver yet: Devvy remembers it and hides it at the next Windows Update check (Updates step)') 'warn' }
    }
}
Save-Outcomes 'drivers'
Write-AfterRun $Apply @(T 'If a device stops working: Device Manager > right click the device > Update driver, or reinstall from the backup.')
Stop-Log
