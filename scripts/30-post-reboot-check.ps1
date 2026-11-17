# Check after a restart: is the PC still healthy? Read only: it changes nothing.
# Looks at: network, screen, devices with errors, and the drivers changed by the program in the last days.
. "$PSScriptRoot\common.ps1"
Assert-Admin
Start-Log 'post-reboot-check'
Write-ReadOnlyBanner

$bad = 0
function Add-Check([string]$Name, [string]$Status, [string]$Detail) {
    $col = 'Green'; $label = T 'OK'
    if ($Status -eq 'WARN') { $col = 'Yellow'; $label = T 'WARNING'; $script:bad++ }
    elseif ($Status -eq 'ERROR') { $col = 'Red'; $label = T 'ERROR'; $script:bad++ }
    Write-Host ('  {0,-11} ' -f $label) -ForegroundColor $col -NoNewline
    Write-Host ($Name + ': ') -ForegroundColor White -NoNewline
    Write-Host $Detail -ForegroundColor Gray
}

Write-Host (T 'Checking the PC after the restart...') -ForegroundColor Green
Write-Prog 0 4

# 1) network: an adapter that is up with an address, and name resolution
Write-Prog 1 4
try {
    $up = @([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object {
        $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' -and $_.NetworkInterfaceType -ne 'Tunnel' -and $_.GetIPProperties().UnicastAddresses.Count -gt 0 })
    if ($up.Count -eq 0) { Add-Check (T 'Network') 'ERROR' (T 'No network adapter is connected. If it worked before the restart, check the network driver in Device Manager (Roll Back Driver).') }
    else {
        $dnsOk = $false
        try { $null = [System.Net.Dns]::GetHostAddresses('www.microsoft.com'); $dnsOk = $true } catch { }
        if ($dnsOk) { Add-Check (T 'Network') 'OK' (T 'Connected ({0} adapter(s) up)' $up.Count) }
        else { Add-Check (T 'Network') 'WARN' (T 'Adapter up but no internet or name resolution yet: wait a minute and run the check again.') }
    }
} catch { Add-Check (T 'Network') 'WARN' (T 'I could not read the network state.') }

# 2) screen: real graphics driver and a sensible resolution
Write-Prog 2 4
try {
    $vc = @(Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object { $_.Name -notmatch 'Remote|Mirror|Parsec|Meta|Virtual' })
    if ($vc.Count -eq 0) { Add-Check (T 'Screen') 'WARN' (T 'No graphics adapter found.') }
    foreach ($v in $vc) {
        $nm = "$($v.Name)"; $w = [int]$v.CurrentHorizontalResolution; $h = [int]$v.CurrentVerticalResolution
        if ($nm -match 'Basic Display|Basic Render') { Add-Check (T 'Screen') 'WARN' (T '{0}: Windows is using the basic display driver. If this is new, roll back the graphics driver or install the maker driver.' $nm) }
        elseif ($v.Status -and "$($v.Status)" -ne 'OK') { Add-Check (T 'Screen') 'WARN' (T '{0}: state {1}' $nm $v.Status) }
        elseif ($w -gt 0 -and $w -lt 1024) { Add-Check (T 'Screen') 'WARN' (T '{0}: resolution {1}x{2} is very low: the graphics driver may not be working.' $nm $w $h) }
        else { Add-Check (T 'Screen') 'OK' ('{0} ({1}x{2})' -f $nm, $w, $h) }
    }
} catch { Add-Check (T 'Screen') 'WARN' (T 'I could not read the graphics state.') }

# 3) devices with an error right now
Write-Prog 3 4
try {
    $pd = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { $_.Status -eq 'Error' -or ("$($_.Problem)" -and "$($_.Problem)" -ne 'CM_PROB_NONE' -and "$($_.Problem)" -ne 'CM_PROB_DISABLED') })
    if ($pd.Count -eq 0) { Add-Check (T 'Devices') 'OK' (T 'No device reports an error.') }
    else {
        Add-Check (T 'Devices') 'WARN' (T '{0} device(s) report an error:' $pd.Count)
        foreach ($d in ($pd | Select-Object -First 15)) { Write-Host ('      - {0} ({1}): {2}' -f $d.FriendlyName, $d.Class, $d.Problem) -ForegroundColor Yellow }
        Write-Host ('  ' + (T 'See the Devices page of Devvy: each device has an explanation in plain words.')) -ForegroundColor Gray
    }
} catch { Add-Check (T 'Devices') 'WARN' (T 'I could not read the devices.') }
# 4) drivers installed by the program: did Windows put the old one back?
try {
    $mm = @(Get-PinMismatch)
    if (@(Get-Pins).Count -gt 0 -and $mm.Count -eq 0) { Add-Check (T 'Installed drivers') 'OK' (T 'The drivers installed by Devvy are still the ones in use.') }
    foreach ($m in $mm) {
        Add-Check (T 'Installed drivers') 'WARN' (T '{0}: Devvy installed {1} but Windows now uses {2} ({3}). Probably Windows Update or the maker app put the other driver back.' $m.Device $m.Expected $m.Current $m.Inf)
        $trail = @(Get-SetupApiTrail $m.InstanceId 6)
        if ($trail.Count -gt 0) {
            Write-Host ('      ' + (T 'Last driver installs for this device (Windows setup log):')) -ForegroundColor Gray
            foreach ($tr in $trail) { Write-Host ('        ' + $tr) -ForegroundColor Gray }
        }
    }
} catch { }
Write-Prog 4 4

Write-Host ''
if ($bad -eq 0) { Write-Host (T 'Everything looks fine after the restart.') -ForegroundColor Green }
else {
    Write-Host (T 'Something does not look right. If it started after the last driver change: Device Manager > right click the device > Properties > Driver > Roll Back Driver, or restore from the backup you made.') -ForegroundColor Yellow
}
Stop-Log
