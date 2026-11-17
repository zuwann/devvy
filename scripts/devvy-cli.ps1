# Devvy without the web page, for administrators and scheduled tasks:  devvy.bat /cli <Action> [options]
#   Audit   read-only: inventory + findings (ghost devices, old Bluetooth pairings, removable drivers, drivers to check)
#   Clean   preview of the cleanup; with -Apply it really removes, repeats while new leftovers appear (max 3 extra rounds)
#   Search  read-only: asks the Microsoft catalog for newer drivers (needs the catalog consent in the settings)
# Options: -Output text|json   -Apply   -Parts devices,drivers,oldversions,bluetooth (default all)   -Backup none|drivers|full (before -Apply)
# Exit codes: 0 nothing to do / done, 1 findings (Audit, or Clean preview) , 2 error, 3 restart needed, 4 not allowed (catalog consent off),
#             5 not running as administrator.  Exclusions, language and options come from data\settings.json (same as the page).
param(
    [Parameter(Position = 0)][string]$Action = 'Help',
    [ValidateSet('text', 'json')][string]$Output = 'text',
    [switch]$Apply,
    [string[]]$Parts = @('devices', 'drivers', 'oldversions', 'bluetooth'),
    [ValidateSet('none', 'drivers', 'full')][string]$Backup = 'none'
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$isAdmin = $true
if ($IsWindows -ne $false) {
    $p0 = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = $p0.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not $isAdmin) { [Console]::Error.WriteLine((T 'ERROR: this script needs administrator rights.')); exit 5 }
$Parts = @($Parts | ForEach-Object { "$_".Split(',') } | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
$json = ($Output -eq 'json')
$ps = 'powershell.exe'
try { $q = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'; if (Test-Path -LiteralPath $q) { $ps = $q } } catch { }
$env:DEVVY_WEB = '1'   # children write UTF-8 and print ##REBOOT##; questions never wait for a keyboard (cautious answer)
$logDir = Join-Path $script:DataRoot 'logs'; New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir ('cli-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
$script:Reboot = $false; $script:Errors = New-Object System.Collections.Generic.List[string]
function Say([string]$Text, [string]$Color = 'Gray') { if (-not $json) { Write-Host $Text -ForegroundColor $Color } }

function Invoke-Step([string]$Title, [string]$Script, [string[]]$More = @()) {
    Say ('> ' + $Title) 'Green'
    $arg = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot $Script)) + $More
    $txt = (& $ps @arg 2>&1 | ForEach-Object { "$_" } | Out-String)
    $code = $LASTEXITCODE
    Add-Content -Path $logFile -Value ("===== $Title ($Script) exit $code`r`n" + $txt) -Encoding UTF8
    if ($txt -match '##REBOOT##') { $script:Reboot = $true }
    if ($null -ne $code -and $code -ne 0) { $script:Errors.Add("$Title (exit $code)"); Say ('  ' + (T 'It ended with an error, see the log:') + ' ' + $logFile) 'Yellow' }
    return $code
}
function Get-Rows([string]$Name) {
    $f = Join-Path $script:ReportDir ($Name + '.csv')
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    return @(Import-Csv -Path $f -Delimiter ';' -Encoding UTF8)
}
function Get-Findings {
    $dev = @(Get-Rows 'devices' | Where-Object { $_.Action -match '^REMOVE' })
    $drv = @(Get-Rows 'drivers' | Where-Object { $_.Action -match '^REMOVE' })
    $bt = @(Get-Rows 'bluetooth' | Where-Object { $_.Action -match '^REMOVE' })
    $chk = @(Get-Rows 'drivers-to-check')
    return [ordered]@{
        ghostDevices      = @($dev | ForEach-Object { [ordered]@{ name = $_.FriendlyName; class = $_.Class; reason = $_.Reason } })
        removableDrivers  = @($drv | ForEach-Object { [ordered]@{ inf = $_.InfName; provider = $_.Provider; version = $_.Version; reason = $_.Reason } })
        bluetoothPairings = @($bt | ForEach-Object { [ordered]@{ name = $_.Name; reason = $_.Reason } })
        driversToCheck    = @($chk | ForEach-Object { [ordered]@{ device = $_.Device; class = $_.Class; reason = $_.Reason } })
    }
}
function Get-Total($f) { return ($f.ghostDevices.Count + $f.removableDrivers.Count + $f.bluetoothPairings.Count) }
function Write-Result($Obj, [int]$Code) {
    $Obj['exitCode'] = $Code; $Obj['log'] = $logFile; $Obj['restartNeeded'] = $script:Reboot; $Obj['errors'] = @($script:Errors)
    if ($json) { Write-Output (ConvertTo-Json -InputObject $Obj -Depth 6) }
    exit $Code
}
function Show-Summary($f) {
    Say ('  ' + (T 'Ghost devices: {0}' $f.ghostDevices.Count))
    Say ('  ' + (T 'Old or unused drivers: {0}' $f.removableDrivers.Count))
    Say ('  ' + (T 'Old Bluetooth pairings: {0}' $f.bluetoothPairings.Count))
    Say ('  ' + (T 'Drivers to check: {0}' $f.driversToCheck.Count))
}
$summ = { param($f) [ordered]@{ ghostDevices = $f.ghostDevices.Count; removableDrivers = $f.removableDrivers.Count; bluetoothPairings = $f.bluetoothPairings.Count; driversToCheck = $f.driversToCheck.Count } }
$ver = (Get-LocalVersion)
$base = [ordered]@{ program = 'Devvy'; version = $ver; action = $Action; apply = [bool]$Apply; date = (Get-Date).ToString('s') }

switch -Regex ($Action) {
    '^(?i)audit$' {
        $null = Invoke-Step (T 'PC inventory') '04-inventory-all.ps1'
        $null = Invoke-Step (T 'Drivers to check') '06-drivers-to-check.ps1' @('-SkipWindowsUpdate')
        $f = Get-Findings; Show-Summary $f
        $o = $base; $o['summary'] = (& $summ $f); $o['findings'] = $f
        $code = 0; if ($script:Errors.Count -gt 0) { $code = 2 } elseif ((Get-Total $f) -gt 0) { $code = 1 }
        Write-Result $o $code
    }
    '^(?i)clean$' {
        if ($Apply -and $Backup -ne 'none') { $null = Invoke-Step (T 'Backup') '00-backup.ps1' @('-Mode', $(if ($Backup -eq 'full') { 'Full' } else { 'Drivers' })) }
        $s = Read-Settings
        $round = 0; $maxRound = 4; $log = New-Object System.Collections.Generic.List[object]
        do {
            $round++
            Say ((T 'Round {0}' $round)) 'Cyan'
            $null = Invoke-Step (T 'PC inventory') '04-inventory-all.ps1'
            $f = Get-Findings; Show-Summary $f
            if ($round -eq 1) { $first = & $summ $f }
            if ((Get-Total $f) -eq 0) { break }
            $ap = @(); if ($Apply) { $ap = @('-Apply') }
            if ($Parts -contains 'devices' -and $f.ghostDevices.Count -gt 0) { $null = Invoke-Step (T 'Remove ghost devices') '22-remove-devices.ps1' $ap }
            if ($Parts -contains 'drivers' -and $f.removableDrivers.Count -gt 0) { $a2 = $ap; if ($Apply -and $s.blockReinstall) { $a2 = @('-Apply', '-BlockReinstall') }; $null = Invoke-Step (T 'Remove drivers') '23-remove-drivers.ps1' $a2 }
            if ($Parts -contains 'oldversions') { $null = Invoke-Step (T 'Remove old driver versions') '25-remove-old-versions.ps1' $ap }
            if ($Parts -contains 'bluetooth' -and $f.bluetoothPairings.Count -gt 0) { $null = Invoke-Step (T 'Remove Bluetooth pairings') '21-remove-bluetooth.ps1' $ap }
            $log.Add([ordered]@{ round = $round; found = (& $summ $f) })
            if (-not $Apply) { break }
        } while ($round -lt $maxRound -and -not $script:Reboot)
        if ($Apply) { $null = Invoke-Step (T 'PC inventory') '04-inventory-all.ps1'; $f = Get-Findings }
        $o = $base; $o['firstFound'] = $first; $o['rounds'] = $log.ToArray(); $o['remaining'] = (& $summ $f)
        $code = 0
        if ($script:Errors.Count -gt 0) { $code = 2 } elseif ($script:Reboot -and $Apply) { $code = 3 } elseif (-not $Apply -and (Get-Total $f) -gt 0) { $code = 1 }
        Write-Result $o $code
    }
    '^(?i)search$' {
        if ($s0 = Read-Settings) { if ($s0.catalogConsent -eq $false) { [Console]::Error.WriteLine((T 'The catalog search is switched off in the settings.')); Write-Result $base 4 } }
        $null = Invoke-Step (T 'Drivers to check') '06-drivers-to-check.ps1' @('-SkipWindowsUpdate')
        $null = Invoke-Step (T 'Microsoft catalog') '08-catalog-search.ps1' @('-SkipConfirm')
        $rows = @(Get-Rows 'catalog' | Where-Object { $_.UpdateId -and $_.NewerThanCurrent -ne 'NO' })
        Say ('  ' + (T 'Newer drivers found: {0}' $rows.Count))
        $o = $base; $o['newerDrivers'] = @($rows | ForEach-Object { [ordered]@{ device = $_.Device; title = $_.Title; version = $_.Version; date = $_.Date; current = $_.CurrentDriver } })
        $code = 0; if ($script:Errors.Count -gt 0) { $code = 2 } elseif ($rows.Count -gt 0) { $code = 1 }
        Write-Result $o $code
    }
    default {
        Write-Host 'Devvy CLI: devvy.bat /cli <Audit|Clean|Search> [-Output json] [-Apply] [-Parts devices,drivers,oldversions,bluetooth] [-Backup none|drivers|full]'
        Write-Host 'Audit and Search only read. Clean only previews unless -Apply is given. Exit codes: 0 ok, 1 findings, 2 error, 3 restart needed, 4 not allowed, 5 not administrator.'
        exit 0
    }
}
