# Runs as SYSTEM: started by 21-remove-bluetooth.ps1 through a temporary scheduled task.
# Deletes from the registry the Bluetooth pairings of the MAC addresses listed in the list file (one per line).
# Do not run by hand: it needs the SYSTEM context because Windows protects these keys even from administrators.
# It writes language-neutral codes (Item, Result); 21-remove-bluetooth.ps1 translates them for the user.
param(
    [Parameter(Mandatory = $true)][string]$ListFile,
    [Parameter(Mandatory = $true)][string]$OutFile
)
$ErrorActionPreference = 'Continue'
$res = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$mac, [string]$item, [string]$result) {
    $res.Add([pscustomobject]@{ MAC = $mac; Item = $item; Result = $result })
}
function Save-Output {
    $tmp = $OutFile + '.tmp'
    $res | Export-Csv -Path $tmp -Delimiter ';' -NoTypeInformation -Encoding UTF8
    Move-Item -Path $tmp -Destination $OutFile -Force
}

$base = 'HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters'
$macs = @()
if (Test-Path $ListFile) {
    $macs = @(Get-Content -Path $ListFile |
        ForEach-Object { ($_ -replace '[^0-9A-Fa-f]', '').ToLower() } |
        Where-Object { $_.Length -eq 12 } | Select-Object -Unique)
}
if ($macs.Count -eq 0) {
    Add-Result '' 'list' 'empty'
    Save-Output
    exit 0
}

# local Bluetooth adapters: they are not devices and are never touched
$adapters = @()
if (Test-Path "$base\Keys") {
    $adapters = @(Get-ChildItem -Path "$base\Keys" -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName.ToLower() })
}

# stop the Bluetooth service (and the services depending on it) so the keys are not written back
$svc = Get-Service -Name 'bthserv' -ErrorAction SilentlyContinue
$wasRunning = $false
$deps = @()
if ($svc -and $svc.Status -eq 'Running') {
    $wasRunning = $true
    $deps = @($svc.DependentServices | Where-Object { $_.Status -eq 'Running' } | ForEach-Object { $_.Name })
    try {
        Stop-Service -Name 'bthserv' -Force -ErrorAction Stop
        $svc.WaitForStatus('Stopped', (New-TimeSpan -Seconds 20))
        Add-Result '' 'service' 'stopped'
    } catch {
        Add-Result '' 'service' ('not-stopped: ' + $_.Exception.Message)
    }
}

foreach ($mac in $macs) {
    if ($adapters -contains $mac) { Add-Result $mac 'adapter' 'skipped'; continue }

    $p = "$base\Devices\$mac"
    if (Test-Path $p) {
        try { Remove-Item -Path $p -Recurse -Force -ErrorAction Stop; Add-Result $mac 'devices' 'removed' }
        catch { Add-Result $mac 'devices' ('error: ' + $_.Exception.Message) }
    } else {
        Add-Result $mac 'devices' 'absent'
    }

    foreach ($ad in $adapters) {
        $k = "$base\Keys\$ad"
        # classic pairing key: a value named like the MAC
        $item = Get-Item -Path $k -ErrorAction SilentlyContinue
        if ($item -and ($item.GetValueNames() -contains $mac)) {
            try { Remove-ItemProperty -Path $k -Name $mac -Force -ErrorAction Stop; Add-Result $mac "keys-value:$ad" 'removed' }
            catch { Add-Result $mac "keys-value:$ad" ('error: ' + $_.Exception.Message) }
        }
        # low energy (LE) devices: subkey
        if (Test-Path "$k\$mac") {
            try { Remove-Item -Path "$k\$mac" -Recurse -Force -ErrorAction Stop; Add-Result $mac "keys-subkey:$ad" 'removed' }
            catch { Add-Result $mac "keys-subkey:$ad" ('error: ' + $_.Exception.Message) }
        }
    }
}

if ($wasRunning) {
    try {
        Start-Service -Name 'bthserv' -ErrorAction Stop
        foreach ($n in $deps) { Start-Service -Name $n -ErrorAction SilentlyContinue }
        Add-Result '' 'service' 'restarted'
    } catch {
        Add-Result '' 'service' ('not-restarted: ' + $_.Exception.Message)
    }
}
Save-Output
exit 0
