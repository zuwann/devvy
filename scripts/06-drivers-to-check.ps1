# Finds present devices with a generic, old or missing driver, or for which Windows Update offers
# something newer. READ ONLY: installs nothing.
# Writes reports\drivers-to-check.csv with name, hardware ID (and compatible IDs) and current driver.
# The hardware ID is used to search for the right driver (Windows Update, vendor site, Microsoft Update Catalog).
#   -All               also includes generic drivers of minor classes (informational)
#   -SkipWindowsUpdate does not query Windows Update (no internet access)
#   -OldYears N        threshold for "old driver" (default 3 years)
param([switch]$All, [switch]$SkipWindowsUpdate, [int]$OldYears = 3)
. "$PSScriptRoot\common.ps1"
Assert-Admin
Start-Log 'drivers-to-check'
Write-ReadOnlyBanner

# classes where a generic Windows driver usually means "the vendor one is missing"
$interestingClasses = @('Display', 'Net', 'MEDIA', 'Bluetooth', 'Camera', 'Image', 'Biometric', 'Sensor', 'Modem')

Write-Info (T 'Reading present devices and their hardware IDs...')
$keys = @('DEVPKEY_Device_HardwareIds', 'DEVPKEY_Device_CompatibleIds', 'DEVPKEY_Device_MatchingDeviceId',
          'DEVPKEY_Device_DriverInfPath', 'DEVPKEY_Device_DriverProvider', 'DEVPKEY_Device_DriverVersion', 'DEVPKEY_Device_DriverDate')
$devs = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue)
$props = Get-DevicePropertyMap $keys $true
Write-Host ('  ' + (T 'Present devices: {0}' $devs.Count))

# ---------- Windows Update (read only) ----------
$wu = @{}
if (-not $SkipWindowsUpdate -and -not (Test-Internet)) {
    Write-Warn (T 'No internet connection')
    Write-Todo @(T 'Connect the PC to the network (Wi-Fi or cable), check that a web page opens, then try again.')
    $SkipWindowsUpdate = $true
}
if (-not $SkipWindowsUpdate) {
    Write-Info (T 'Querying Windows Update (search only, it can take a minute)...')
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $res = $session.CreateUpdateSearcher().Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
        for ($i = 0; $i -lt $res.Updates.Count; $i++) {
            $u = $res.Updates.Item($i)
            $hid = ("$($u.DriverHardwareID)").ToUpper()
            if (-not $hid) { continue }
            if (-not $wu.ContainsKey($hid) -or $u.DriverVerDate -gt $wu[$hid].DriverVerDate) { $wu[$hid] = $u }
        }
        Write-Host ('  ' + (T 'Driver updates available: {0}' $res.Updates.Count))
    } catch {
        Write-Warn (T 'Windows Update cannot be queried: {0}' $_.Exception.Message)
    }
}

# ---------- Analysis ----------
$rows = foreach ($d in $devs) {
    # devices the person excluded are never listed, searched or touched
    if (Test-Excluded ('{0} {1}' -f $d.FriendlyName, $d.InstanceId) $d.Class) { continue }
    $p = $props[$d.InstanceId]
    $hw = @(); $cp = @()
    $matchId = ''; $inf = ''; $prov = ''; $ver = ''; $date = $null
    if ($p) {
        $hw = @($p['DEVPKEY_Device_HardwareIds'] | Where-Object { $_ })
        $cp = @($p['DEVPKEY_Device_CompatibleIds'] | Where-Object { $_ })
        $matchId = "$($p['DEVPKEY_Device_MatchingDeviceId'])"
        $inf = "$($p['DEVPKEY_Device_DriverInfPath'])"
        $prov = "$($p['DEVPKEY_Device_DriverProvider'])"
        $ver = "$($p['DEVPKEY_Device_DriverVersion'])"
        $date = $p['DEVPKEY_Device_DriverDate']
    }
    $okDate = ($date -is [datetime]) -and ($date.Year -ge 1995)
    $age = ''
    if ($okDate) { $age = [math]::Round(((Get-Date) - $date).TotalDays / 365.25, 1) }

    # which kind of ID selected the driver: Hardware = specific, Compatible = generic
    $idType = ''
    if ($matchId) {
        if ($hw | Where-Object { $_ -ieq $matchId }) { $idType = 'Hardware' }
        elseif ($cp | Where-Object { $_ -ieq $matchId }) { $idType = 'Compatible' }
        else { $idType = 'Other' }
    }
    $isMs = ($prov -match '^Microsoft')
    $interesting = ($interestingClasses -contains $d.Class)

    $reasons = New-Object System.Collections.Generic.List[string]
    $severity = ''

    $code = "$($d.ConfigManagerErrorCode)"
    if ($code -and $code -ne 'CM_PROB_NONE') { $reasons.Add((TE 'Problem: {0}' $code)); $severity = 'High' }
    # VirtIO serial ports (virtual machines with the QEMU guest agent) work without a driver of their own
    $noDriverOk = ($d.InstanceId -match 'VIOSERIALPORT')
    if (-not $inf -and -not $noDriverOk -and $d.InstanceId -notmatch '^HTREE\\') { $reasons.Add((TE 'No driver installed')); $severity = 'High' }
    if ($idType -eq 'Compatible' -and $isMs) {
        if ($interesting) {
            $reasons.Add((TE 'Generic Microsoft driver: the manufacturer probably provides a specific one'))
            if (-not $severity) { $severity = 'Medium' }
        } elseif ($All) {
            $reasons.Add((TE 'Generic driver (informational)'))
            if (-not $severity) { $severity = 'Info' }
        }
    }
    if ($okDate -and $inf -like 'oem*.inf' -and $interesting -and $age -ge $OldYears) {
        # ID with SUBSYS = driver chosen for the exact PC model (usually the vendor's): old does not mean wrong
        if ($idType -eq 'Hardware' -and $matchId -match 'SUBSYS_') {
            $reasons.Add((TE 'Old driver: {0} years (it is the PC manufacturer driver: if you have no problems leave it; to update it use the manufacturer site or support app)' $age))
            if (-not $severity) { $severity = 'Info' }
        } else {
            $reasons.Add((TE 'Old driver: {0} years' $age))
            if (-not $severity -or $severity -eq 'Info') { $severity = 'Medium' }
        }
    }

    # Windows Update: search by the device hardware IDs
    $wuFlag = 'NO'; $wuTitle = ''; $wuDate = ''; $wuNote = ''
    $best = $null
    foreach ($h in $hw) {
        $k = $h.ToUpper()
        if ($wu.ContainsKey($k)) {
            if (-not $best -or $wu[$k].DriverVerDate -gt $best.DriverVerDate) { $best = $wu[$k] }
        }
    }
    if ($best) {
        $wuFlag = 'YES'
        $wuTitle = "$($best.Title)"
        $wuDate = Format-Date $best.DriverVerDate
        if ($okDate -and $best.DriverVerDate -gt $date) {
            $wuNote = (T 'Newer than the installed driver')
            $reasons.Add((TE 'Update available on Windows Update'))
            if (-not $severity -or $severity -eq 'Info') { $severity = 'Medium' }
        } elseif (-not $okDate) {
            $wuNote = (T 'Installed driver date unknown')
            $reasons.Add((TE 'Windows Update offers a driver (current date unknown)'))
            if (-not $severity -or $severity -eq 'Info') { $severity = 'Medium' }
        } else {
            $wuNote = (T 'Offered but not newer: probably already up to date')
        }
    }

    if ($reasons.Count -eq 0) { continue }

    $name = "$($d.FriendlyName)"
    if (-not $name) { $name = "$($d.Class)" }
    $dateText = ''
    if ($okDate) { $dateText = Format-Date $date }

    [pscustomobject][ordered]@{
        Severity       = $severity
        Reason         = ($reasons -join ' | ')
        Device         = $name
        Class          = "$($d.Class)"
        InstanceId     = $d.InstanceId
        HardwareId     = (($hw | Select-Object -First 4) -join ' | ')
        CompatibleId   = (($cp | Select-Object -First 3) -join ' | ')
        UsedId         = $matchId
        UsedIdType     = $idType
        DriverProvider = $prov
        DriverVersion  = $ver
        DriverDate     = $dateText
        AgeYears       = $age
        DriverInf      = $inf
        WindowsUpdate  = $wuFlag
        WU_Title       = $wuTitle
        WU_Date        = $wuDate
        WU_Note        = $wuNote
    }
}

$rows = @($rows)
Write-Host ''
if ($rows.Count -eq 0) {
    Write-Ok (T 'No device to check: no generic, old or missing driver in the checked classes.')
    # empty list, but the file must exist: the page and the catalog search tell "nothing to check" from "inventory missing"
    try { Set-Content -Path (Join-Path $script:ReportDir 'drivers-to-check.csv') -Encoding UTF8 -Value '"Severity";"Reason";"Device";"Class";"InstanceId";"HardwareId";"CompatibleId";"UsedId";"UsedIdType";"DriverProvider";"DriverVersion";"DriverDate";"AgeYears";"DriverInf";"WindowsUpdate";"WU_Title";"WU_Date";"WU_Note"' } catch { }
} else {
    $sorted = $rows | Sort-Object @{ Expression = { if ($_.Severity -eq 'High') { 0 } elseif ($_.Severity -eq 'Medium') { 1 } else { 2 } } }, Class, Device
    $path = Save-ReportCsv $sorted 'drivers-to-check'
    Write-Ok ((T 'Report:') + ' ' + $path)
    $rows | Group-Object Severity | Sort-Object Name | ForEach-Object { Write-Host ('  ' + (T 'Severity {0}: {1}' $_.Name $_.Count)) }
    Write-Host ''
    Write-Todo @(
        (T 'Open the Drivers to check tab: rows with High severity are at the top.'),
        (T 'If the WindowsUpdate column says YES and WU_Note says "Newer": use the Update drivers function.'),
        (T 'Otherwise copy the HardwareId value and search for it on the PC manufacturer site or on catalog.update.microsoft.com.'),
        (T 'On branded laptops and PCs prefer the manufacturer drivers: generic or newer ones are not always better.')
    )
}
Stop-Log
