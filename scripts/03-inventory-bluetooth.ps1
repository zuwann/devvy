# Inventory of the paired Bluetooth devices (from Windows and from the registry) -> reports\bluetooth.csv
# Changes nothing. Action: REMOVE (unpairs and deletes the pairing) / KEEP.
. "$PSScriptRoot\common.ps1"
Assert-Admin
Start-Log 'inventory-bluetooth'
Write-ReadOnlyBanner

$all = @(Get-PnpDevice -ErrorAction SilentlyContinue)
$devNodes = @($all | Where-Object { $_.InstanceId -match '^BTHENUM\\DEV_[0-9A-Fa-f]{12}' })
$svcNodes = @($all | Where-Object { $_.InstanceId -match '^BTHENUM\\\{' })

# Pairings known only to the registry (may include devices that PnP no longer shows)
$reg = @{}
$regPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices'
if (Test-Path $regPath) {
    Get-ChildItem -Path $regPath -ErrorAction SilentlyContinue | ForEach-Object {
        $name = ''
        $raw = $_.GetValue('Name')
        if ($raw -is [byte[]]) { $name = [Text.Encoding]::UTF8.GetString($raw).Trim([char]0) }
        $reg[$_.PSChildName.ToUpper()] = $name
    }
}

$macs = @{}
foreach ($n in $devNodes) {
    if ($n.InstanceId -match 'DEV_([0-9A-Fa-f]{12})') { $macs[$Matches[1].ToUpper()] = 1 }
}
foreach ($k in $reg.Keys) { if ($k -match '^[0-9A-F]{12}$') { $macs[$k] = 1 } }

$rows = foreach ($mac in ($macs.Keys | Sort-Object)) {
    $node = $devNodes | Where-Object { $_.InstanceId -match ('DEV_' + $mac) } | Select-Object -First 1
    $nSvc = @($svcNodes | Where-Object { $_.InstanceId -match ('&' + $mac + '_') }).Count
    $name = ''
    if ($node -and $node.FriendlyName) { $name = "$($node.FriendlyName)" }
    elseif ($reg.ContainsKey($mac)) { $name = $reg[$mac] }
    $present = 'NO'
    if ($node -and $node.Present) { $present = 'YES' }
    $inReg = 'NO'
    if ($reg.ContainsKey($mac)) { $inReg = 'YES' }
    $iid = ''
    if ($node) { $iid = $node.InstanceId }

    [pscustomobject][ordered]@{
        Action        = 'REMOVE'
        MAC           = ($mac -replace '(.{2})(?!$)', '$1:')
        Name          = $name
        Present        = $present
        InRegistry    = $inReg
        ServiceNodes  = $nSvc
        InstanceId    = $iid
        Reason        = (TE 'Bluetooth pairing')
    }
}

$rows = @($rows)
if ($rows.Count -eq 0) {
    Write-Warn (T 'No paired Bluetooth device found.')
    # an empty table, so that the page knows the inventory was done
    $emptyPath = Join-Path $script:ReportDir 'bluetooth.csv'
    Set-Content -Path $emptyPath -Value 'Action;MAC;Name;Present;InRegistry;ServiceNodes;InstanceId;Reason' -Encoding UTF8
} else {
    $path = Save-ReportCsv $rows 'bluetooth'
    Write-Ok ((T 'Report:') + ' ' + $path)
    $rows | ForEach-Object { Write-Host ('  ' + (T '{0}  {1}  (present: {2})' $_.MAC $_.Name $_.Present)) }
    Write-Todo @(
        (T 'Open the Bluetooth tab: every row is a paired device.'),
        (T 'All of them are set to REMOVE. Change to KEEP the ones you want to keep (for example the headphones you use).'),
        (T 'Then go to the Run tab: first the preview, then the changes. Removed devices must be paired again by hand.')
    )
}
Stop-Log
