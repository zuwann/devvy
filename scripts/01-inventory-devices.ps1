# Inventory of all PnP devices (present and ghost) -> reports\devices.csv
# Changes nothing. The Action column is a suggestion: the user can change it to KEEP / REMOVE.
# The What / Advice / Risk columns come from the knowledge base (knowledge.csv).
. "$PSScriptRoot\common.ps1"
Assert-Admin
Start-Log 'inventory-devices'
Write-ReadOnlyBanner

function Get-Category([string]$Id, [string]$Class, [string]$Text) {
    if (Test-Excluded $Text $Class) { return (T 'Excluded by you') }
    if ($Class -in @('PrintQueue', 'Printer', 'WSDPrintDevice', 'USBPrint') -or $Id -match 'PRINTENUM|USBPRINT|WSDPRINT') { return (T 'Printing') }
    if ($Id -match '^(BTH|BTHENUM|BTHHFENUM)\\' -or $Class -eq 'Bluetooth' -or $Id -like 'SWD\RADIO\BLUETOOTH*') { return 'Bluetooth' }
    if ($Id -match 'DAFUPNPPROVIDER|WIFIDIRECT' -or $Class -in @('Miracast', 'DigitalMediaDevices')) { return 'TV / DLNA / Miracast' }
    if ($Id -match 'WPDBUSENUM|USBSTOR' -or $Class -in @('WPD', 'Volume', 'VolumeSnapshot', 'DiskDrive')) { return (T 'Storage / USB') }
    if ($Class -in @('AudioEndpoint', 'MEDIA', 'AudioProcessingObject')) { return 'Audio' }
    if ($Class -in @('SoftwareComponent', 'SoftwareDevice', 'Extension')) { return (T 'Software components') }
    if ($Class -in @('Display', 'Monitor')) { return (T 'Video') }
    if ($Id -match '^(USB|HID)\\') { return 'USB / HID' }
    return (T 'System / other')
}

Write-Ok (T 'Reading the devices (ghosts too)...')
$devices = @(Get-PnpDevice -ErrorAction SilentlyContinue)
Write-Info ('  ' + (T 'Found: {0}' $devices.Count))

Write-Ok (T 'Reading the associated drivers (this can take a minute)...')
$map = Get-DeviceDriverMap

$sigMap = $null
$rows = foreach ($d in $devices) {
    $id = $d.InstanceId
    $m = $map[$id]
    $inf = ''; $prov = ''; $ver = ''; $dd = ''; $last = ''
    if ($m) {
        $inf  = "$($m['DEVPKEY_Device_DriverInfPath'])"
        $prov = "$($m['DEVPKEY_Device_DriverProvider'])"
        $ver  = "$($m['DEVPKEY_Device_DriverVersion'])"
        $dd   = Format-Date $m['DEVPKEY_Device_DriverDate']
        $last = Format-Date $m['DEVPKEY_Device_LastArrivalDate']
        if (-not $last) { $last = Format-Date $m['DEVPKEY_Device_InstallDate'] }
    }
    # a connected device with the driver name or date missing: ask Windows (Win32_PnPSignedDriver, read once)
    if ($d.Present -and (-not $inf -or -not $dd -or -not $prov)) {
        if ($null -eq $sigMap) {
            $sigMap = @{}
            try { foreach ($x in @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop)) { if ($x.DeviceID) { $sigMap["$($x.DeviceID)"] = $x } } } catch { }
        }
        $sg = $sigMap[$id]
        if ($sg) {
            if (-not $inf) { $inf = "$($sg.InfName)" }
            if (-not $prov) { $prov = "$($sg.DriverProviderName)" }
            if (-not $ver) { $ver = "$($sg.DriverVersion)" }
            if (-not $dd) { $dd = Format-Date $sg.DriverDate }
        }
    }
    # still no driver data (typical of ghosts and of software devices): read it from the driver key that Windows keeps for the device
    $infPath = ''
    if (-not $inf -or -not $dd -or -not $ver) {
        try {
            $ek = Get-ItemProperty -LiteralPath ('Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\' + $id) -ErrorAction Stop
            if ($ek.Driver) {
                $ck = Get-ItemProperty -LiteralPath ('Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Class\' + $ek.Driver) -ErrorAction Stop
                if (-not $inf -and $ck.InfPath) { $inf = "$($ck.InfPath)" }
                if (-not $prov -and $ck.ProviderName) { $prov = "$($ck.ProviderName)" }
                if (-not $ver -and $ck.DriverVersion) { $ver = "$($ck.DriverVersion)" }
                if (-not $dd -and $ck.DriverDate) {
                    $dt = [datetime]::MinValue
                    if ([datetime]::TryParseExact("$($ck.DriverDate)", 'M-d-yyyy', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$dt)) { $dd = Format-Date $dt }
                }
            }
        } catch { }
    }
    if ($inf -and $inf -notmatch '^oem') { $ip = Join-Path (Join-Path $env:windir 'INF') $inf; if (Test-Path -LiteralPath $ip) { $infPath = $ip } }
    # driver date still missing but the inf is known: it is the DriverVer line of the inf
    if (-not $dd -and $infPath) {
        try { if ((Get-Content -LiteralPath $infPath -TotalCount 400 -ErrorAction Stop | Out-String) -match '(?im)^\s*DriverVer\s*=\s*(\d{1,2})/(\d{1,2})/(\d{4})') { $dd = ('{0}-{1:00}-{2:00}' -f $Matches[3], [int]$Matches[1], [int]$Matches[2]) } } catch { }
    }
    $text = '{0} {1} {2}' -f $d.FriendlyName, $d.Manufacturer, $id
    $excluded = Test-Excluded $text $d.Class
    $cat = Get-Category $id $d.Class $text
    $present = 'NO'
    if ($d.Present) { $present = 'YES' }

    $adv = $null
    if (-not $excluded) { $adv = Get-Advice ('{0} {1} {2} {3} {4}' -f $inf, $prov, $d.FriendlyName, $id, $d.Class) }
    $kbId = ''; $what = ''; $risk = ''; $advText = ''
    if ($adv) { $kbId = $adv.Id; $what = $adv.Name; $risk = $adv.Risk; $advText = Get-AdviceText $adv }

    if ($excluded) { $action = 'KEEP'; $why = TE 'Excluded by you in the settings (pattern: {0})' (Get-ExclusionMatch $text) }
    elseif (-not $d.Present) {
        $action = 'REMOVE'
        if ((Get-GhostKind $id "$($d.Class)" "$($d.FriendlyName)") -eq 'SAFE') { $why = TE 'Ghost: virtual or system component, safe to remove' } else { $why = TE 'Ghost: physical hardware not connected (remove it only if you no longer use it)' }
    }
    elseif ($adv -and $adv.Auto -eq 'ORPHAN' -and $adv.IsOrphan) { $action = 'KEEP'; $why = TE 'Orphaned component: remove it from the drivers list (see drivers.csv)' }
    else { $action = 'KEEP'; $why = TE 'Present' }

    [pscustomobject][ordered]@{
        Action             = $action
        Category           = $cat
        Present            = $present
        Status             = "$($d.Status)"
        Problem            = "$($d.ConfigManagerErrorCode)"
        Class              = "$($d.Class)"
        FriendlyName       = "$($d.FriendlyName)"
        InstanceId         = $id
        Manufacturer       = "$($d.Manufacturer)"
        DriverInf          = $inf
        InfPath            = $infPath
        DriverProvider     = $prov
        DriverVersion      = $ver
        DriverDate         = $dd
        LastSeen           = $last
        KbId               = $kbId
        What               = $what
        Risk               = $risk
        Advice             = $advText
        Reason             = $why
        GhostKind          = $(if ($d.Present) { '' } else { Get-GhostKind $id "$($d.Class)" "$($d.FriendlyName)" })
    }
}

$sorted = $rows | Sort-Object Action, Category, Class, FriendlyName
$path = Save-ReportCsv $sorted 'devices'
Write-Host ''
Write-Ok ((T 'Report:') + ' ' + $path)
Write-Info (T 'Summary (Action, Category):')
$rows | Group-Object Action, Category | Sort-Object Name | ForEach-Object { Write-Host ('  {0}: {1}' -f (ConvertTo-SummaryName $_.Name), $_.Count) }

Write-Todo @(
    (T 'Open the Devices tab: REMOVE means the device will be deleted, KEEP means it stays. The What and Advice columns explain each entry.'),
    (T 'When you are ready go to the Run tab: first the preview, then the changes.')
)
Stop-Log
