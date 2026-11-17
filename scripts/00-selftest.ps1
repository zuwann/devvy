# Self test: checks that the PC has everything the tool needs, BEFORE touching anything.
# Read only. It changes nothing and creates no restore points. Writes reports\selftest.csv.
# Status values in the CSV are language neutral: OK / WARN / ERROR. FixId is set when the page can fix the problem.
. "$PSScriptRoot\common.ps1"
Assert-Admin
Start-Log 'selftest'
Write-ReadOnlyBanner

$script:Tests = New-Object System.Collections.Generic.List[object]
$script:ToDo = New-Object System.Collections.Generic.List[string]

# Status: OK / WARN / ERROR. When it is not OK, $WhatToDo tells the user what to do and $FixId (optional)
# names an automatic fix known by the page, e.g. enable-service:wuauserv.
function Add-Test([string]$Name, [string]$Status, [string]$Detail, [string]$WhatToDo = '', [string]$FixId = '') {
    $script:Tests.Add([pscustomobject]@{ Check = $Name; Status = $Status; Detail = $Detail; WhatToDo = $WhatToDo; FixId = $FixId })
    $col = 'Green'
    $label = T 'OK'
    if ($Status -eq 'WARN') { $col = 'Yellow'; $label = T 'WARNING' }
    elseif ($Status -eq 'ERROR') { $col = 'Red'; $label = T 'ERROR' }
    Write-Host ('  {0,-11} ' -f $label) -ForegroundColor $col -NoNewline
    Write-Host ($Name + ': ') -ForegroundColor White -NoNewline
    Write-Host $Detail -ForegroundColor Gray
    if ($Status -ne 'OK' -and $WhatToDo) { $script:ToDo.Add($Name + ' -> ' + $WhatToDo) }
}

Write-Title (T 'SELF TEST: checking the requirements')
Write-Host ''

# --- Windows version and architecture
$build = 0
try { $build = [int][Environment]::OSVersion.Version.Build } catch { }
$arch = $env:PROCESSOR_ARCHITECTURE
$verTxt = [Environment]::OSVersion.Version.ToString()
$nWin = T 'Windows version'
if ($build -ge 19041) { Add-Test $nWin 'OK' (T 'build {0}, architecture {1}' $verTxt $arch) }
elseif ($build -gt 0) { Add-Test $nWin 'WARN' (T 'build {0}: older than Windows 10 2004' $verTxt) (T 'Windows 10 2004 (build 19041) or later is recommended. On this version devices are removed with an alternative method; if something does not work, update Windows.') }
else { Add-Test $nWin 'WARN' (T 'I cannot read the version') (T 'Check the Windows version by hand (it must be Windows 10 2004 or later).') }

# --- PowerShell
$psv = $PSVersionTable.PSVersion
if ($psv.Major -ge 5) { Add-Test 'PowerShell' 'OK' (T 'version {0}' $psv.ToString()) }
else { Add-Test 'PowerShell' 'ERROR' (T 'version {0}' $psv.ToString()) (T 'Windows PowerShell 5.1 is needed (included in Windows 10 and 11).') }

# --- Windows driver tool (pnputil) with /remove-device
$nTool = T 'Windows driver tool'
$pnp = Join-Path $env:SystemRoot 'System32\pnputil.exe'
if (Test-Path $pnp) {
    $help = ''
    try { $help = (& $pnp '/?' 2>&1 | Out-String) } catch { }
    if ($help -match 'remove-device') { Add-Test $nTool 'OK' (T 'present and able to remove devices') }
    else { Add-Test $nTool 'OK' (T 'present; it cannot remove devices on this Windows, so the program uses an alternative method') }
} else {
    Add-Test $nTool 'ERROR' (T 'not found in {0}' $pnp) (T 'Run "sfc /scannow" in an administrator window and try again: a system file is missing.')
}

# --- Reading devices and drivers
$nDev = -1
$nDevName = T 'Device list'
try { $nDev = @(Get-PnpDevice -ErrorAction Stop).Count } catch { }
if ($nDev -gt 0) { Add-Test $nDevName 'OK' (T '{0} devices read' $nDev) }
else { Add-Test $nDevName 'ERROR' (T 'I cannot read the devices') (T 'Restart the PC and try again. If it persists, run "DISM /Online /Cleanup-Image /RestoreHealth" in an administrator window.') }

$nDrv = -1
$nDrvName = T 'Installed drivers list'
try { $nDrv = @(Get-DriverPackages).Count } catch { }
if ($nDrv -gt 0) { Add-Test $nDrvName 'OK' (T '{0} driver packages found' $nDrv) }
else { Add-Test $nDrvName 'ERROR' (T 'I cannot read the installed drivers') (T 'Restart the PC. If it persists, run "DISM /Online /Cleanup-Image /RestoreHealth" in an administrator window.') }

# --- Services
function Test-ServiceCheck([string]$Svc, [string]$Label, [string]$WhatToDo, [string]$Severity) {
    $s = Get-Service -Name $Svc -ErrorAction SilentlyContinue
    if (-not $s) { Add-Test $Label $Severity (T 'service not present') $WhatToDo; return }
    $start = ''
    try { $start = (Get-CimInstance -ClassName Win32_Service -Filter ("Name='" + $Svc + "'") -ErrorAction Stop).StartMode } catch { }
    if ($start -eq 'Disabled') { Add-Test $Label $Severity (T 'service DISABLED') $WhatToDo ('enable-service:' + $Svc) }
    else { Add-Test $Label 'OK' (T 'service present ({0}, start mode {1})' $s.Status $start) }
}
Test-ServiceCheck 'Schedule' (T 'Task Scheduler') (T 'Enable the Task Scheduler service: it is needed to delete the Bluetooth pairings left in the registry.') 'WARN'
Test-ServiceCheck 'wuauserv' 'Windows Update' (T 'Enable the Windows Update service: without it Windows cannot download some updates.') 'WARN'
$nBt = T 'Bluetooth service'
$bt = Get-Service -Name 'bthserv' -ErrorAction SilentlyContinue
if ($bt) { Add-Test $nBt 'OK' (T 'present ({0})' $bt.Status) }
else { Add-Test $nBt 'OK' (T 'not present: this PC has no Bluetooth, nothing to do here') }

# --- Windows Update through COM
$nWu = T 'Windows Update (API)'
$wu = $false
try { $null = New-Object -ComObject 'Microsoft.Update.Session'; $wu = $true } catch { }
if ($wu) { Add-Test $nWu 'OK' (T 'available') }
else { Add-Test $nWu 'WARN' (T 'API not available') (T 'Searching Windows Update will work only in part: use Windows Update from the Settings app.') }

# --- Restore point
$nRp = T 'Restore point'
$sr = $null
try { $sr = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -ErrorAction Stop).DisableSR } catch { }
if ($sr -eq 1) { Add-Test $nRp 'WARN' (T 'disabled by policy') (T 'When asked about the backup choose "Drivers only": the restore point cannot be created.') }
else { Add-Test $nRp 'OK' (T 'not blocked (Windows creates at most one every 24 hours)') }

# --- Free space (the drivers backup can take a few hundred MB)
$nSpace = T 'Free space'
try {
    $drv = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop
    $gb = [math]::Round($drv.Free / 1GB, 1)
    if ($gb -ge 2) { Add-Test $nSpace 'OK' (T '{0} GB free on {1}' $gb $env:SystemDrive) }
    else { Add-Test $nSpace 'WARN' (T '{0} GB free on {1}' $gb $env:SystemDrive) (T 'Free at least 2 GB: the drivers backup and the restore point use it.') }
} catch { Add-Test $nSpace 'WARN' (T 'I cannot read it') '' }

# --- Pending restart
$nReb = T 'Pending restart'
$pend = $false
foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
                 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')) {
    if (Test-Path $k) { $pend = $true }
}
if ($pend) { Add-Test $nReb 'WARN' (T 'Windows is waiting for a restart') (T 'Restart the PC before making changes: the results would be unreliable.') }
else { Add-Test $nReb 'OK' (T 'no restart waiting') }

# --- Data folder and program folder
$nFolder = T 'Data folder'
$testFile = Join-Path $script:ReportDir '.write-test'
$writable = $false
try {
    New-Item -ItemType Directory -Force -Path $script:ReportDir | Out-Null
    Set-Content -Path $testFile -Value 'x' -ErrorAction Stop
    Remove-Item -Path $testFile -Force -ErrorAction SilentlyContinue
    $writable = $true
} catch { }
if ($writable) { Add-Test $nFolder 'OK' (T 'I can write reports and logs') }
else { Add-Test $nFolder 'ERROR' (T 'I cannot write in the folder') (T 'Move the program to a normal folder (for example C:\Devvy) or choose another data folder in the settings: Controlled folder access or permissions block it.') }
$nPath = T 'Program location'
if ($script:Root -match '^\\\\') { Add-Test $nPath 'WARN' (T 'the folder is on a network share') (T 'Copy the program to a local disk.') }
elseif ($script:Root -match 'OneDrive') { Add-Test $nPath 'WARN' (T 'the folder is inside OneDrive') (T 'Move the program out of OneDrive (for example C:\Devvy): synchronization can block the files.') }

# --- Defender
$mp = $null
try { $mp = Get-MpComputerStatus -ErrorAction Stop } catch { }
$nDef = 'Microsoft Defender'
if ($mp -and $mp.RealTimeProtectionEnabled) {
    $cfa = 0
    try { $cfa = [int](Get-MpPreference -ErrorAction Stop).EnableControlledFolderAccess } catch { }
    if ($cfa -eq 1) { Add-Test $nDef 'OK' (T 'active with Controlled folder access') }
    else { Add-Test $nDef 'OK' (T 'active') }
    if ($mp.IsTamperProtected) { Add-Test (T 'Tamper protection') 'WARN' (T 'on') (T 'Windows may refuse the temporary exceptions: if something is blocked, run the Defender diagnosis.') }
} else { Add-Test $nDef 'OK' (T 'not active or managed by another antivirus') }

# --- Summary
Write-Host ''
$groups = @($script:Tests | Group-Object Status)
foreach ($g in $groups) {
    $col = 'Green'
    $label = T 'OK'
    if ($g.Name -eq 'WARN') { $col = 'Yellow'; $label = T 'WARNING' } elseif ($g.Name -eq 'ERROR') { $col = 'Red'; $label = T 'ERROR' }
    Write-Host ('  {0}: {1}' -f $label, $g.Count) -ForegroundColor $col
}
$path = Save-ReportCsv $script:Tests 'selftest'
Write-Info ('  ' + (T 'List saved in:') + ' ' + $path)

if ($script:ToDo.Count -eq 0) {
    Write-Todo @(T 'All good: you can start with the inventory.')
} else {
    Write-Todo (@($script:ToDo) + @(T 'Then run this check again until no ERROR is left.'))
}
Stop-Log
if (@($script:Tests | Where-Object { $_.Status -eq 'ERROR' }).Count -gt 0) { exit 1 }
exit 0
