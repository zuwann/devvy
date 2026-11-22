# Windows Update: hides again the driver updates of the packages Devvy removed (the ones Windows Update did not offer yet)
# and saves the data that explains why drivers come back (reports\wu-history.csv, oem-inf.csv, setupapi-trail.csv).
. "$PSScriptRoot\common.ps1"
Assert-Admin
Start-Log 'wu-hide'
Write-Host (T 'Windows Update: hiding the drivers removed by Devvy...') -ForegroundColor Green
$pend = @(Get-WuHideList)
Write-Host ('  ' + (T 'Waiting to be hidden: {0}' $pend.Count))
$n = 0
foreach ($x in @(Invoke-PendingWuHide)) { if ($x.Hidden) { $n++; Write-Host ('  ' + (T 'Windows Update will not offer this driver again (undo it in Device management)') + ': ' + $x.Title) -ForegroundColor Green } }
if ($pend.Count -gt 0 -and $n -eq 0) { Write-Host ('  ' + (T 'Windows Update is not offering them now: Devvy tries again next time.')) -ForegroundColor Yellow }
Write-Host (T 'Saving the data about returning drivers...') -ForegroundColor Green
foreach ($d in @(Save-ReturnDiag)) { Write-Host ('  ' + (T 'Saved: {0}' ('reports\' + $d + '.csv'))) }
Stop-Log
exit 0
