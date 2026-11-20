# Removes the GHOST devices marked REMOVE in reports\devices.csv
# Checks before every removal: not excluded, still existing, still not present.
# Without -Apply it only shows a preview.
# -BlockReinstall (optional): software components (SWD\DRIVERENUM, class SoftwareComponent) removed here also get their SWC\ hardware ids
# added to the Windows block list, so Windows Update does not create them again (undo in Device management).
param([switch]$Apply, [switch]$BlockReinstall)
. "$PSScriptRoot\common.ps1"
Assert-Admin
Start-Log 'remove-devices'
Write-ModeBanner $Apply

$rows = @(Read-ReportCsv 'devices')
if ($rows.Count -eq 0) { Stop-Log; exit 1 }
$todo = @($rows | Where-Object { $_.Action -match '^REMOVE' })
Write-Host (T 'Devices to remove: {0} of {1}' $todo.Count $rows.Count)

$failed = @()
$total = @($todo).Count; $index = 0
foreach ($r in $todo) {
    Write-Prog $index $total; $index++
    $id = $r.InstanceId
    $label = '{0} [{1}]' -f $r.FriendlyName, $r.Class
    $text = '{0} {1} {2}' -f $r.FriendlyName, $r.Manufacturer, $id
    if (Test-Excluded $text $r.Class) { Add-Outcome $label $id (T 'Excluded in settings: skipped') 'warn'; continue }

    $cur = Get-PnpExact $id
    if (-not $cur) { Add-Outcome $label $id (T 'Already removed') 'ok'; continue }
    if ($cur.Present) { Add-Outcome $label $id (T 'Present now: skipped') 'warn'; continue }
    if (-not $Apply) { Add-Outcome $label $id (T 'Preview (would be removed)') 'preview'; continue }

    $swcIds = @()
    if ($BlockReinstall -and "$($r.Class)" -eq 'SoftwareComponent' -and $id -like 'SWD\DRIVERENUM\*') {
        try { $swcIds = @((Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction Stop).Data | Where-Object { $_ -and (Test-BlockableId $_) -and $_ -like 'SWC\*' } | Select-Object -Unique) } catch { }
    }
    $p = Remove-DeviceNode $id
    # pnputil can say OK while the entry stays: check
    if ($p.Ok -and -not (Get-PnpExact $id)) {
        Add-Outcome $label $id (T 'Removed') 'ok'
        foreach ($sid in $swcIds) {
            try { $null = Add-BlockedId $sid $r.FriendlyName '' "$($r.Manufacturer)"; Add-Outcome $label $sid (T 'Windows is stopped from installing this device again (undo it in Device management)') 'ok' }
            catch { Add-Outcome $label $sid ((T 'Could not block:') + ' ' + $_.Exception.Message) 'err' }
        }
    } else { $failed += $r }
}

# second pass: children often disappear together with their parent
foreach ($r in $failed) {
    $id = $r.InstanceId
    $label = '{0} [{1}]' -f $r.FriendlyName, $r.Class
    if (-not (Get-PnpExact $id)) { Add-Outcome $label $id (T 'Removed together with its parent') 'ok'; continue }
    $p = Remove-DeviceNode $id
    if ($p.Ok -and -not (Get-PnpExact $id)) { Add-Outcome $label $id (T 'Removed (second attempt)') 'ok' }
    else { Add-Outcome $label $id ((T 'FAILED:') + ' ' + (($p.Output -replace '\s+', ' ') + $(if ($p.Ok) { ' ' + (T 'The entry is still there after the removal') } else { '' }))) 'err' }
}

Save-Outcomes 'devices'
Write-AfterRun $Apply @(T 'A device removed by mistake comes back by itself: plug it in again and Windows reinstalls it.')
Stop-Log
