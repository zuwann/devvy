# Removes the Bluetooth pairings marked REMOVE in reports\bluetooth.csv
# Phase 1: Windows API (BluetoothRemoveDevice) + the PnP node if any.
# Phase 2: pairings left only in the registry (typical after removing just the nodes from Device Manager):
#          they are deleted as SYSTEM with a temporary scheduled task, because Windows protects
#          those keys even from administrators. The Bluetooth service is stopped and restarted.
# Without -Apply it only shows a preview.
param([switch]$Apply)
. "$PSScriptRoot\common.ps1"
Assert-Admin
Start-Log 'remove-bluetooth'
Write-ModeBanner $Apply

$rows = @(Read-ReportCsv 'bluetooth')
if ($rows.Count -eq 0) { Stop-Log; exit 1 }
$todo = @($rows | Where-Object { $_.Action -match '^REMOVE' })
Write-Host (T 'Pairings to remove: {0} of {1}' $todo.Count $rows.Count)

if (-not ('BtUnpair' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BtUnpair {
    [DllImport("bthprops.cpl", SetLastError = true)]
    public static extern uint BluetoothRemoveDevice(ref ulong pAddress);
}
'@
}

# ---------- Phase 1: Windows API ----------
Write-Host ('' + [Environment]::NewLine + (T '[1] Pairings known to Windows...')) -ForegroundColor Green
$total = @($todo).Count; $index = 0
foreach ($r in $todo) {
    Write-Prog $index $total; $index++
    $mac = ($r.MAC -replace '[^0-9A-Fa-f]', '')
    $label = '{0} ({1})' -f $r.Name, $r.MAC
    if ($mac.Length -ne 12) { Add-Outcome $label $r.InstanceId (T 'Invalid MAC: skipped') 'warn'; continue }
    if (-not $Apply) { Add-Outcome $label $r.InstanceId (T 'Preview (would be removed)') 'preview'; continue }

    [uint64]$addr = [Convert]::ToUInt64($mac, 16)
    $res = [BtUnpair]::BluetoothRemoveDevice([ref]$addr)
    $outcome = T 'Pairing removed'
    $kind = 'ok'
    if ($res -eq 1168) { $outcome = T 'Not known to Windows (the registry is checked)'; $kind = 'warn' }
    elseif ($res -ne 0) { $outcome = T 'API error {0} (the registry is checked)' $res; $kind = 'warn' }

    # remove the device entry if one is left
    if ($r.InstanceId -and (Get-PnpExact $r.InstanceId)) {
        $p = Remove-DeviceNode $r.InstanceId -Subtree
        if ($p.Ok) { $outcome = $outcome + ' + ' + (T 'Device entry removed') } else { $outcome = $outcome + ' + ' + (T 'Device entry NOT removed'); $kind = 'warn' }
    }
    Add-Outcome $label $r.InstanceId $outcome $kind
}

# ---------- Phase 2: pairings left in the registry ----------
Write-Host ('' + [Environment]::NewLine + (T '[2] Pairings left in the registry...')) -ForegroundColor Green
# Translates the language-neutral codes written by 21b-bt-registry-system.ps1
function Convert-BtItem([string]$Item) {
    if ($Item -eq 'list') { return T 'List' }
    if ($Item -eq 'service') { return T 'Bluetooth service' }
    if ($Item -eq 'adapter') { return T 'Local adapter' }
    if ($Item -eq 'devices') { return T 'Devices' }
    if ($Item -like 'keys-value:*') { return ('Keys\' + $Item.Substring(11) + ' ' + (T '(value)')) }
    if ($Item -like 'keys-subkey:*') { return ('Keys\' + $Item.Substring(12) + ' ' + (T '(subkey)')) }
    return $Item
}
function Convert-BtResult([string]$Result) {
    if ($Result -eq 'empty') { return T 'Empty: nothing to do' }
    if ($Result -eq 'stopped') { return T 'Stopped' }
    if ($Result -eq 'restarted') { return T 'Restarted' }
    if ($Result -eq 'removed') { return T 'Removed' }
    if ($Result -eq 'absent') { return T 'Not present' }
    if ($Result -eq 'skipped') { return T 'Skipped (not a device)' }
    if ($Result -like 'not-stopped:*') { return ((T 'Not stopped:') + $Result.Substring(12)) }
    if ($Result -like 'not-restarted:*') { return ((T 'Not restarted:') + $Result.Substring(14) + ' ' + (T '(restart the PC)')) }
    if ($Result -like 'error:*') { return ((T 'ERROR:') + $Result.Substring(6)) }
    return $Result
}

$regDevices = 'HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices'
function Get-RegMacs {
    $h = @{}
    if (Test-Path $regDevices) {
        Get-ChildItem -Path $regDevices -ErrorAction SilentlyContinue | ForEach-Object { $h[$_.PSChildName.ToLower()] = 1 }
    }
    return $h
}

$wanted = @{}
foreach ($r in $todo) {
    $m = ($r.MAC -replace '[^0-9A-Fa-f]', '').ToLower()
    if ($m.Length -eq 12) { $wanted[$m] = $r }
}
$inReg = Get-RegMacs
$left = @($wanted.Keys | Where-Object { $inReg.ContainsKey($_) })

if ($left.Count -eq 0) {
    Write-Host ('  ' + (T 'No pairing to delete from the registry.'))
}
elseif (-not $Apply) {
    foreach ($m in $left) {
        Add-Outcome (T 'Registry: {0} ({1})' $wanted[$m].Name $wanted[$m].MAC) $m (T 'Preview (would be deleted with system rights)') 'preview'
    }
}
else {
    $sysScript = Join-Path $PSScriptRoot '21b-bt-registry-system.ps1'
    $listFile = Join-Path $script:OutcomesDir 'bt-registry-list.txt'
    $outFile = Join-Path $script:OutcomesDir 'bt-registry-outcome.csv'
    Remove-Item -Path $outFile -Force -ErrorAction SilentlyContinue
    Set-Content -Path $listFile -Value $left -Encoding ASCII

    $taskName = 'DevvyBtRegistry'
    Write-Host ('  ' + (T 'Deleting {0} pairings with system rights (the Bluetooth service stops for a few seconds)...' $left.Count))
    try {
        $arg = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ListFile "{1}" -OutFile "{2}"' -f $sysScript, $listFile, $outFile
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 3) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        $waited = 0
        while (-not (Test-Path $outFile) -and $waited -lt 120) { Start-Sleep -Seconds 2; $waited += 2 }
        if (-not (Test-Path $outFile)) { Write-Warning (T 'No answer from the system task within 2 minutes.') }
    } catch {
        Write-Warning ((T 'The system task failed:') + ' ' + $_.Exception.Message)
    } finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }

    if (Test-Path $outFile) {
        Write-Host ('  ' + (T 'Details:'))
        Import-Csv -Path $outFile -Delimiter ';' | ForEach-Object { Write-Host ('    {0} {1}: {2}' -f $_.MAC, (Convert-BtItem $_.Item), (Convert-BtResult $_.Result)) }
    }

    # independent check: read the registry again
    Start-Sleep -Seconds 2
    $after = Get-RegMacs
    foreach ($m in $left) {
        $label = T 'Registry: {0} ({1})' $wanted[$m].Name $wanted[$m].MAC
        if ($after.ContainsKey($m)) { Add-Outcome $label $m (T 'STILL in the registry: see the details above') 'err' }
        else { Add-Outcome $label $m (T 'Removed from the registry') 'ok' }
    }
    Remove-Item -Path $listFile -Force -ErrorAction SilentlyContinue
}

Save-Outcomes 'bluetooth'
Write-AfterRun $Apply @((T 'If a pairing still shows up, run the Bluetooth inventory again and look at the InRegistry column.'), (T 'To reconnect a removed device: Settings > Bluetooth & devices > Add device.'))
Stop-Log
