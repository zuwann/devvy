# Goes back to the PREVIOUS driver of ONE device, using the copy saved by Devvy just before it replaced that driver
# (reports\rollback.csv, written by 10-install-from-catalog.ps1 -SaveOld). Only rows of that file are accepted.
# Usage: 26-rollback-driver.ps1 -Key <guid>
param([Parameter(Mandatory = $true)][string]$Key)
. "$PSScriptRoot\common.ps1"
Assert-Admin
Start-Log 'rollback'
Write-Title (T 'RESTORING THE PREVIOUS DRIVER')

$csv = Join-Path $script:ReportDir 'rollback.csv'
$rows = @()
if (Test-Path $csv) { $rows = @(Import-Csv -Path $csv -Delimiter ';') }
$row = $rows | Where-Object { $_.Key -eq $Key } | Select-Object -First 1
if (-not $row) { Write-Err (T 'This driver was not saved: nothing to go back to.'); Stop-Log; exit 1 }
if (-not $row.BackupPath -or -not (Test-Path $row.BackupPath) -or -not (Get-ChildItem -Path $row.BackupPath -Filter '*.inf' -Recurse -ErrorAction SilentlyContinue)) {
    Write-Err (T 'The saved copy of the old driver is no longer there: {0}' $row.BackupPath); Stop-Log; exit 1
}
Write-Info ((T 'Device:') + ' ' + $row.Device)
Write-Info ((T 'Previous driver:') + ' ' + $row.Provider + ' ' + $row.OldVersion + ' (' + $row.OldDate + ')')
Write-Prog 1 5

$cur = @(Get-DriverState $row.ShortId) | Where-Object { $_.Id -eq $row.InstanceId } | Select-Object -First 1
if (-not $cur) { Write-Err (T 'The device is not connected: connect it and try again.'); Stop-Log; exit 1 }
$newInf = $cur.Inf
Write-Info ((T 'Current driver:') + ' ' + $cur.Inf + ' ' + $cur.Ver + ' (' + $cur.Date + ')')

Write-Ok (T 'Adding the previous driver to Windows...')
$r = Invoke-Pnp @('/add-driver', (Join-Path $row.BackupPath '*.inf'), '/subdirs', '/install')
Write-Prog 2 5
if (-not ($r.Ok -or ($r.Code -eq 259 -and $r.Output -match 'oem\d+\.inf'))) {
    Write-Err (T 'Windows refused (code {0}): {1}' $r.Code ($r.Output -replace '\s+', ' ')); Stop-Log; exit 1
}
Write-RebootNeeded
Write-Ok (T 'Applying the previous driver (it can take a few seconds)...')
$f = Invoke-ForceDriver $row.InstanceId $row.BackupPath $row.Class $row.ShortId
Write-Prog 3 5
if ($f.Ok) { Write-Ok ('  ' + $f.Message) } else { Write-Warn ('  ' + (T 'Not done:') + ' ' + $f.Message) }

$now = @(Get-DriverState $row.ShortId) | Where-Object { $_.Id -eq $row.InstanceId } | Select-Object -First 1
$back = ($now -and $now.Ver -eq $row.OldVersion)
if ($now) { Write-Info ('  ' + (T 'The device now uses: {0} {1} ({2})' $now.Inf $now.Ver $now.Date)) }

# the replaced (new) package goes, so Windows does not bind it again at the next restart
if ($back -and $newInf -match '^oem\d+\.inf$' -and $newInf -ne $now.Inf) {
    $usage = Get-DriverUsage
    if ([int]$usage.Present[$newInf.ToLower()] -eq 0) {
        $d = Invoke-Pnp @('/delete-driver', $newInf, '/uninstall', '/force')
        if ($d.Ok) { Write-Ok ('  ' + (T 'Removed the driver you were going back from ({0}).' $newInf)) }
        else { Write-Warn ('  ' + (T '{0}: Windows refused (code {1}): {2}' $newInf $d.Code ($d.Output -replace '\s+', ' '))) }
    }
}
Write-Prog 4 5

if ($back) {
    foreach ($x in $rows) { if ($x.Key -eq $Key) { $x.State = 'restored' } }
    $rows | Export-Csv -Path $csv -Delimiter ';' -NoTypeInformation -Encoding UTF8
    Add-Outcome $row.Device $row.InstanceId ((T 'Previous driver restored ({0}). Restart the PC.' $row.OldVersion)) 'ok'
    $code = 0
} elseif ($now) {
    Add-Outcome $row.Device $row.InstanceId ((T 'The device still shows {0}: restart and check again; if it does not change, use Device Manager > Update driver > Browse > "{1}".' $now.Ver $row.BackupPath)) 'warn'
    $code = 0
} else {
    Add-Outcome $row.Device $row.InstanceId (T 'The device was not found after the change: check in Device Manager.') 'warn'
    $code = 0
}
Save-Outcomes 'rollback'
Write-Prog 5 5
Stop-Log
exit $code
