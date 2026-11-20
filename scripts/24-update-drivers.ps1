# Updates drivers in two ways:
#  A) installs the drivers available on Windows Update (optional ones included)
#  B) applies the newest versions that are already in the driver store but not in use
# Without -Apply it only previews.
param([switch]$Apply)
. "$PSScriptRoot\common.ps1"
Assert-Admin
Start-Log 'update-drivers'
Write-ModeBanner $Apply

# ---------- A) Windows Update ----------
Write-Host ("`n[A] " + (T 'Drivers available on Windows Update...')) -ForegroundColor Green
$updates = @()
$session = $null
try {
    # extension drivers removed earlier by Devvy: hide them now if Windows Update offers them again, so they are not installed back
    try { foreach ($x in @(Invoke-PendingWuHide)) { if ($x.Hidden) { Write-Host ('  ' + (T 'Windows Update will not offer this driver again (undo it in Device management)') + ': ' + $x.Title) -ForegroundColor Green } } } catch { }
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $result = $searcher.Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
    for ($i = 0; $i -lt $result.Updates.Count; $i++) { $updates += $result.Updates.Item($i) }
} catch {
    Write-Warn (T 'Windows Update search failed: {0}' $_.Exception.Message)
}
Write-Host ('  ' + (T 'Available: {0}' $updates.Count))

if ($updates.Count -gt 0) {
    $list = foreach ($u in $updates) {
        [pscustomobject][ordered]@{
            Title     = "$($u.Title)"
            Class     = "$($u.DriverClass)"
            Manufacturer = "$($u.DriverManufacturer)"
            Model = "$($u.DriverModel)"
            Date = Format-Date $u.DriverVerDate
            HardwareID = "$($u.DriverHardwareID)"
        }
    }
    $null = Save-ReportCsv $list 'driver-updates'
}

if ($updates.Count -gt 0 -and -not $Apply) {
    foreach ($u in $updates) { Add-Outcome $u.Title $u.Identity.UpdateID (T 'Preview (it would be installed)') 'preview' }
}

if ($updates.Count -gt 0 -and $Apply) {
    $toGet = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $updates) {
        if (-not $u.EulaAccepted) { $u.AcceptEula() }
        [void]$toGet.Add($u)
    }
    Write-Host ('  ' + (T 'Downloading the updates...'))
    $dl = $session.CreateUpdateDownloader()
    $dl.Updates = $toGet
    $null = $dl.Download()

    $toInst = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $updates) {
        if ($u.IsDownloaded) { [void]$toInst.Add($u) } else { Add-Outcome $u.Title $u.Identity.UpdateID (T 'Download failed') 'err' }
    }
    if ($toInst.Count -gt 0) {
        Write-Host ('  ' + (T 'Installing...'))
        $inst = $session.CreateUpdateInstaller()
        $inst.Updates = $toInst
        $ir = $inst.Install()
        for ($i = 0; $i -lt $toInst.Count; $i++) {
            $code = $ir.GetUpdateResult($i).ResultCode
            $txt = switch ($code) {
                2 { T 'Installed' }
                3 { T 'Installed with warnings' }
                4 { T 'Failed' }
                5 { T 'Cancelled' }
                default { T 'Code {0}' $code }
            }
            $k = 'warn'; if ($code -eq 2) { $k = 'ok' } elseif ($code -eq 4) { $k = 'err' }
            Add-Outcome $toInst.Item($i).Title $toInst.Item($i).Identity.UpdateID $txt $k
        }
        if ($ir.RebootRequired) { Write-RebootNeeded; Write-Host ('  >>> ' + (T 'A restart is needed to finish.')) -ForegroundColor Yellow }
    }
}

# ---------- B) versioni piu recenti gia nel driver store ----------
Write-Host ("`n[B] " + (T 'Newer versions already in the driver store but not in use...')) -ForegroundColor Green
$pkgs = @(Get-DriverPackages | Where-Object { $_.Driver -like 'oem*.inf' })
$use = Get-DriverUsage
$cands = @($pkgs | Where-Object {
    $leaf = Split-Path $_.OriginalFileName -Leaf
    -not (Test-Excluded ('{0} {1}' -f $_.ProviderName, $leaf) $_.ClassName)
})
$groups = $cands | Group-Object { '{0}|{1}|{2}' -f (Split-Path $_.OriginalFileName -Leaf), $_.ProviderName, $_.ClassName }
$found = 0
foreach ($g in $groups) {
    if ($g.Count -lt 2) { continue }
    $sorted = @($g.Group | Sort-Object @{ Expression = { $_.Date }; Descending = $true }, @{ Expression = { ConvertTo-Ver $_.Version }; Descending = $true })
    $newest = $sorted[0]
    if ([int]$use.Present[$newest.Driver.ToLower()] -gt 0) { continue }
    $usedOld = @($sorted | Select-Object -Skip 1 | Where-Object { [int]$use.Present[$_.Driver.ToLower()] -gt 0 })
    if ($usedOld.Count -eq 0) { continue }

    $found++
    $leaf = Split-Path $newest.OriginalFileName -Leaf
    $label = T '{0}: v{1} in use -> v{2} available' $leaf $usedOld[0].Version $newest.Version
    if (-not $Apply) { Add-Outcome $label $newest.Driver (T 'Preview (it would be applied)') 'preview'; continue }
    $r = Invoke-Pnp @('/add-driver', $newest.OriginalFileName, '/install')
    # code 259 = "no new package added": if pnputil still printed an oemNN.inf (already in the store) the command worked
    $alreadyThere = ($r.Code -eq 259 -and $r.Output -match 'oem\d+\.inf')
    if (-not ($r.Ok -or $alreadyThere)) {
        Add-Outcome $label $newest.Driver (T 'NOT applied (code {0}): {1}' $r.Code ($r.Output -replace '\s+', ' ')) 'err'
        continue
    }
    # Check: pnputil says "updated" even when Windows keeps the previous driver (it ranks by how well the hardware ID
    # matches, only then by date and version). Re-read which driver the devices really use.
    $stillOld = 0; $moved = 0
    $oldName = $usedOld[0].Driver.ToLower()
    foreach ($d in @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue)) {
        $cur = "$((Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_DriverInfPath' -ErrorAction SilentlyContinue).Data)".ToLower()
        if ($cur -eq $oldName) { $stillOld++ }
        elseif ($cur -eq $newest.Driver.ToLower()) { $moved++ }
    }
    if ($moved -gt 0 -and $stillOld -eq 0) { Add-Outcome $label $newest.Driver (T 'Applied and checked: the devices use the new version (restart the PC if Windows asks)') 'ok' }
    elseif ($moved -gt 0) { Add-Outcome $label $newest.Driver (T 'Partly applied: {0} device(s) moved to the new version, {1} did not' $moved $stillOld) 'warn' }
    else { Add-Outcome $label $newest.Driver (T 'NOT changed: Windows keeps using the current version (usually the PC maker one, with a more specific hardware ID). Restart and check again; if it stays like this use the Updates tab to force it, or Device Manager > Update driver > Browse my computer > Let me pick') 'warn' }
}
if ($found -eq 0) { Write-Host ('  ' + (T 'No newer version waiting.')) }

Save-Outcomes 'update-drivers'

Write-Host ("`n" + (T 'Notes:')) -ForegroundColor Green
Write-Host ('- ' + (T 'Windows Update does not cover everything: BIOS, firmware and many maker-specific drivers (HP, Dell, Lenovo...) are updated with their support app or website.'))
Write-Host ('- ' + (T 'Graphics drivers are best updated from the maker app (Intel, NVIDIA, AMD).'))
Write-Host ('- ' + (T 'After updating, restart, then use Remove old driver versions.'))
Write-AfterRun $Apply @((T 'Next: Remove old driver versions, to delete the replaced drivers.'), (T 'Then: Drivers to check, to see what is left to update.'))
Stop-Log
