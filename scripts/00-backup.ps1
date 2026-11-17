# Restore point + backup of the third-party drivers. Exits with code 1 if the user stops.
# -Mode Full (restore point + drivers) or Drivers (only the drivers export, faster).
param([ValidateSet('Full', 'Drivers')][string]$Mode = 'Full')
. "$PSScriptRoot\common.ps1"
Assert-Admin
Start-Log 'backup'

Write-Title (T 'BACKUP: restore point and copy of the third-party drivers')
Write-Info ('  ' + (T 'It lets you go back if something stops working after the changes.'))

$restorePointName = 'Devvy: before the changes'

Write-Host ''
$rpOk = $true
if ($Mode -eq 'Full') {
    Write-Host (T '[1/2] Creating the Windows restore point (it can take a few minutes)...') -ForegroundColor Green
    try {
        Enable-ComputerRestore -Drive ($env:SystemDrive + '\') -ErrorAction Stop
    } catch { }
    try {
        Checkpoint-Computer -Description $restorePointName -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Ok ('  ' + (T 'Restore point created: "{0}".' $restorePointName))
    } catch {
        $rpOk = $false
        Write-Warn ('  ' + (T 'Restore point NOT created:') + ' ' + $_.Exception.Message)
        Write-Info ('  ' + (T 'Windows creates at most one every 24 hours: if you already have a recent one this is normal. It can also be turned off on the system disk.'))
    }
} else {
    Write-Info (T '[1/2] Restore point skipped (you chose the quick backup: drivers only).')
}

Write-Host ''
Write-Host (T '[2/2] Saving the third-party drivers (it can take a minute)...') -ForegroundColor Green
$dest = Join-Path $script:BackupRoot ('drivers-' + (Get-Date -Format 'yyyyMMdd-HHmm'))
New-Item -ItemType Directory -Force -Path $dest | Out-Null
$r = Invoke-Pnp @('/export-driver', '*', $dest)
if ($r.Ok) {
    Write-Ok ('  ' + (T 'Drivers saved in:') + ' ' + $dest)
    Write-Info ('  ' + (T 'To reinstall them if something goes wrong: pnputil /add-driver "<folder>\*.inf" /subdirs /install'))
} else {
    Write-Err ('  ' + (T 'Saving the drivers failed:') + ' ' + $r.Output)
}

if (-not $rpOk -and -not $r.Ok) {
    Write-Err (T 'No backup was created.')
    $k = Read-Choice (T '  Continue anyway WITHOUT a backup? [Y] yes  [N] no, cancel') @('Y', 'N')
    if ($k -ne 'Y') { Stop-Log; exit 1 }
} elseif (-not $rpOk) {
    $k = Read-Choice (T '  The restore point is missing (the drivers are saved). Continue? [Y] yes  [N] no, cancel') @('Y', 'N')
    if ($k -ne 'Y') { Stop-Log; exit 1 }
}
Stop-Log
exit 0
