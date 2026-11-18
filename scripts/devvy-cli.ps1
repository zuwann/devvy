# Devvy without the web page, for administrators and scheduled tasks:  devvy.bat /cli <Action> [options]
#   Audit   read-only: inventory + findings (ghost devices, old Bluetooth pairings, removable drivers, drivers to check)
#   Clean   preview of the cleanup; with -Apply it really removes, repeats while new leftovers appear (max 3 extra rounds)
#   Search  read-only: asks the Microsoft catalog for newer drivers (needs the catalog consent in the settings)
#   Update  checks GitHub for a newer release (exit 1 = available); with -Apply it downloads, verifies (SHA-256) and installs it
#   Profile -Import <file.json> adds a profile exported from the page (exclusions, options, user rows); -Export <file.json> writes one
# Options: -Output text|json   -Apply   -Parts devices,drivers,oldversions,bluetooth (default all)   -Backup none|drivers|full (before -Apply)
# Exit codes: 0 nothing to do / done, 1 findings (Audit, or Clean preview) , 2 error, 3 restart needed, 4 not allowed (catalog consent off),
#             5 not running as administrator.  Exclusions, language and options come from data\settings.json (same as the page).
param(
    [Parameter(Position = 0)][string]$Mode = '/cli',   # devvy.bat passes all its arguments (%*), the first one is /cli: this keeps commas in lists intact
    [Parameter(Position = 1)][string]$Action = 'Help',
    [ValidateSet('text', 'json')][string]$Output = 'text',
    [switch]$Apply,
    [string[]]$Parts = @('devices', 'drivers', 'oldversions', 'bluetooth'),
    [ValidateSet('none', 'drivers', 'full')][string]$Backup = 'none',
    [string]$Import = '',
    [string]$Export = ''
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
$isAdmin = $true
if ($IsWindows -ne $false) {
    $p0 = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = $p0.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Show-Help {
    $c = { param($a, $b) Write-Host ('  ' + $a.PadRight(34)) -NoNewline -ForegroundColor Cyan; Write-Host $b }
    Write-Host (T 'Devvy on the command line (no web page). Start it from an administrator prompt:') -ForegroundColor Green
    Write-Host '  devvy.bat /cli <Action> [options]'
    Write-Host ''
    Write-Host (T 'Command line: actions') -ForegroundColor Yellow
    & $c '-h  /?  /help' (T 'Shows this help. It works without administrator rights.')
    & $c 'Audit' (T 'Read only: inventory and summary (ghost devices, old drivers, old Bluetooth pairings, drivers to check).')
    & $c 'Clean' (T 'Preview of the cleanup: nothing is removed. Add -Apply to really remove.')
    & $c 'Search' (T 'Read only: looks in the Microsoft catalog for newer drivers (needs the catalog consent in the settings).')
    & $c 'Update' (T 'Checks for a newer Devvy. Add -Apply to install it.')
    & $c 'Profile -Export <file.json>' (T 'Saves your exclusions, options and own table rows.')
    & $c 'Profile -Import <file.json>' (T 'Adds a saved profile to this PC (nothing of yours is deleted).')
    Write-Host ''
    Write-Host (T 'Command line: options') -ForegroundColor Yellow
    & $c '-Output text|json' (T 'Colored text (default) or one JSON object, for scripts.')
    & $c '-Apply' (T 'Really do it (Clean, Update). Without it nothing changes.')
    & $c '-Parts "devices,drivers,..."' (T 'Clean only: devices, drivers, oldversions, bluetooth (comma list in quotes; default all).')
    & $c '-Backup none|drivers|full' (T 'Clean -Apply only: none (default), drivers, or full (restore point + driver export).')
    Write-Host ''
    Write-Host (T 'Command line: exit codes') -ForegroundColor Yellow
    Write-Host ('  ' + (T '0 ok, 1 findings or update available, 2 error, 3 restart needed, 4 not allowed, 5 not administrator.'))
    Write-Host ''
    Write-Host (T 'Command line: examples') -ForegroundColor Yellow
    Write-Host '  devvy.bat /cli Audit'
    Write-Host '  devvy.bat /cli Audit -Output json'
    Write-Host '  devvy.bat /cli Clean -Parts "devices,bluetooth"'
    Write-Host '  devvy.bat /cli Clean -Apply -Backup drivers'
    Write-Host '  devvy.bat /cli Update -Apply'
    Write-Host ''
    Write-Host ((T 'Full guide:') + ' COMANDI.md')
}
if (@('-h', '/?', '/help') -contains "$Action".ToLower()) { Show-Help; exit 0 }
if (-not $Action -or $Action -eq 'Help') { Write-Host (T 'To see what Devvy can do run: devvy.bat -h'); exit 0 }
if (-not $isAdmin) { [Console]::Error.WriteLine((T 'ERROR: this script needs administrator rights.')); [Console]::Error.WriteLine((T 'Exit code {0}: {1}' 5 (T 'administrator rights needed'))); exit 5 }
$Parts = @($Parts | ForEach-Object { "$_".Split(',') } | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
$json = ($Output -eq 'json')
$ps = 'powershell.exe'
try { $q = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'; if (Test-Path -LiteralPath $q) { $ps = $q } } catch { }
$env:DEVVY_WEB = '1'   # children write UTF-8 and print ##REBOOT##; questions never wait for a keyboard (cautious answer)
$logDir = Join-Path $script:DataRoot 'logs'; New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir ('cli-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
$script:Reboot = $false; $script:Errors = New-Object System.Collections.Generic.List[string]
function Say([string]$Text, [string]$Color = 'Gray') { if (-not $json) { Write-Host $Text -ForegroundColor $Color } }
Say (T 'Please wait: Devvy is working. Some steps take a minute or two, nothing is frozen.') 'Yellow'

function Invoke-Step([string]$Title, [string]$Script, [string[]]$More = @(), [switch]$Show, [string]$Hint = '') {
    Say ('> ' + $Title) 'Green'
    if ($Hint) { Say ('  ' + $Hint) 'DarkGray' }
    $arg = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot $Script)) + $More
    # the child writes UTF-8 (DEVVY_WEB=1): read it as UTF-8 so accents are right, then give the console encoding back
    $oldEnc = $null
    try { $oldEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch { }
    try { $txt = (& $ps @arg 2>&1 | ForEach-Object { "$_" } | Out-String) } finally { if ($oldEnc) { try { [Console]::OutputEncoding = $oldEnc } catch { } } }
    $code = $LASTEXITCODE
    Add-Content -Path $logFile -Value ("===== $Title ($Script) exit $code`r`n" + $txt) -Encoding UTF8
    if ($txt -match '##REBOOT##') { $script:Reboot = $true }
    if ($Show) {
        foreach ($ln in ($txt -split "\r?\n")) {
            $l = $ln.TrimEnd(); if (-not $l.Trim() -or $l -match '^\s*##') { continue }
            $col = 'Gray'; if ($l -match '(?i)error|errore|fail|non rimoss|NOT') { $col = 'Yellow' }
            Say ('  ' + $l.TrimStart()) $col
        }
    }
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
    else {
        $what = @{ 0 = (T 'all fine / done'); 1 = (T 'something found (or an update is available)'); 2 = (T 'error, see the log'); 3 = (T 'restart Windows to finish'); 4 = (T 'not allowed (catalog switched off in the settings)'); 5 = (T 'administrator rights needed') }[$Code]
        $col = 'Green'; if ($Code -eq 1 -or $Code -eq 3) { $col = 'Yellow' } elseif ($Code -ge 2) { $col = 'Red' }
        Write-Host ''; Write-Host (T 'Exit code {0}: {1}' $Code $what) -ForegroundColor $col
        Write-Host ((T 'Log:') + ' ' + $logFile) -ForegroundColor DarkGray
    }
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
        $null = Invoke-Step (T 'PC inventory') '04-inventory-all.ps1' -Hint (T 'This can take a minute or two...')
        $null = Invoke-Step (T 'Drivers to check') '06-drivers-to-check.ps1' @('-SkipWindowsUpdate')
        $f = Get-Findings; Show-Summary $f
        $o = $base; $o['summary'] = (& $summ $f); $o['findings'] = $f
        $code = 0; if ($script:Errors.Count -gt 0) { $code = 2 } elseif ((Get-Total $f) -gt 0) { $code = 1 }
        Write-Result $o $code
    }
    '^(?i)clean$' {
        if ($Apply -and $Backup -ne 'none') { $null = Invoke-Step (T 'Backup') '00-backup.ps1' @('-Mode', $(if ($Backup -eq 'full') { 'Full' } else { 'Drivers' })) -Show }
        $s = Read-Settings
        $round = 0; $maxRound = 4; $log = New-Object System.Collections.Generic.List[object]
        do {
            $round++
            Say ((T 'Round {0}' $round)) 'Cyan'
            $null = Invoke-Step (T 'PC inventory') '04-inventory-all.ps1' -Hint (T 'This can take a minute or two...')
            $f = Get-Findings; Show-Summary $f
            if ($round -eq 1) { $first = & $summ $f }
            if ((Get-Total $f) -eq 0) { break }
            $ap = @(); if ($Apply) { $ap = @('-Apply') }
            if ($Parts -contains 'devices' -and $f.ghostDevices.Count -gt 0) { $null = Invoke-Step (T 'Remove ghost devices') '22-remove-devices.ps1' $ap -Show }
            if ($Parts -contains 'drivers' -and $f.removableDrivers.Count -gt 0) { $a2 = $ap; if ($Apply -and $s.blockReinstall) { $a2 = @('-Apply', '-BlockReinstall') }; $null = Invoke-Step (T 'Remove drivers') '23-remove-drivers.ps1' $a2 -Show }
            if ($Parts -contains 'oldversions') { $null = Invoke-Step (T 'Remove old driver versions') '25-remove-old-versions.ps1' $ap -Show }
            if ($Parts -contains 'bluetooth' -and $f.bluetoothPairings.Count -gt 0) { $null = Invoke-Step (T 'Remove Bluetooth pairings') '21-remove-bluetooth.ps1' $ap -Show }
            $log.Add([ordered]@{ round = $round; found = (& $summ $f) })
            if (-not $Apply) { break }
        } while ($round -lt $maxRound -and -not $script:Reboot)
        if ($Apply) { $null = Invoke-Step (T 'PC inventory') '04-inventory-all.ps1' -Hint (T 'This can take a minute or two...'); $f = Get-Findings }
        $o = $base; $o['firstFound'] = $first; $o['rounds'] = $log.ToArray(); $o['remaining'] = (& $summ $f)
        $code = 0
        if ($script:Errors.Count -gt 0) { $code = 2 } elseif ($script:Reboot -and $Apply) { $code = 3 } elseif (-not $Apply -and (Get-Total $f) -gt 0) { $code = 1 }
        Write-Result $o $code
    }
    '^(?i)search$' {
        if ($s0 = Read-Settings) { if ($s0.catalogConsent -eq $false) { [Console]::Error.WriteLine((T 'The catalog search is switched off in the settings.')); Write-Result $base 4 } }
        $null = Invoke-Step (T 'Drivers to check') '06-drivers-to-check.ps1' @('-SkipWindowsUpdate')
        $null = Invoke-Step (T 'Microsoft catalog') '08-catalog-search.ps1' @('-SkipConfirm') -Hint (T 'This can take a minute or two...')
        $rows = @(Get-Rows 'catalog' | Where-Object { $_.UpdateId -and $_.NewerThanCurrent -ne 'NO' })
        Say ('  ' + (T 'Newer drivers found: {0}' $rows.Count))
        foreach ($r in $rows) { Say ('   - ' + $r.Device + ': ' + $r.Version + ' (' + $r.Date + ')  <-  ' + $r.CurrentDriver) 'Yellow' }
        $o = $base; $o['newerDrivers'] = @($rows | ForEach-Object { [ordered]@{ device = $_.Device; title = $_.Title; version = $_.Version; date = $_.Date; current = $_.CurrentDriver } })
        $code = 0; if ($script:Errors.Count -gt 0) { $code = 2 } elseif ($rows.Count -gt 0) { $code = 1 }
        Write-Result $o $code
    }
    '^(?i)update$' {
        Say ('> ' + (T 'Checking GitHub for a newer version...')) 'Green'
        $plan = Get-UpdatePlan
        if (-not $plan.ok) { [Console]::Error.WriteLine($plan.error); $o = $base; $o['error'] = $plan.error; Write-Result $o 2 }
        $o = $base; $o['installed'] = $plan.current; $o['latest'] = $plan.latest; $o['updateAvailable'] = [bool]$plan.needed
        if (-not $plan.needed) { Say ('  ' + (T 'Devvy is already up to date.')) 'Green'; Say ('  ' + (T 'Installed version:') + ' ' + $plan.current); Write-Result $o 0 }
        Say ('  ' + (T 'Update available: {0} (installed: {1}). To install it: devvy.bat /cli Update -Apply' $plan.latest $plan.current)) 'Yellow'
        if (-not $Apply) { Write-Result $o 1 }
        $code = Invoke-Step (T 'Updating Devvy') '29-self-update.ps1' -Show
        if ($code -ne 0) { Write-Result $o 2 }
        # devvy.bat could not change while a program was running: nobody is running it now except this very call (its CLI block is read in advance), so put it in place
        $root = Split-Path $PSScriptRoot
        $def = Join-Path $script:DataRoot 'update-staging\deferred'
        if (Test-Path -LiteralPath $def) {
            foreach ($f in @(Get-ChildItem -LiteralPath $def -File -Recurse)) {
                $rel = $f.FullName.Substring($def.Length).TrimStart('\')
                try { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $root $rel) -Force -ErrorAction Stop } catch { $script:Errors.Add("$rel : $($_.Exception.Message)") }
            }
        }
        try { Remove-Item -LiteralPath (Join-Path $script:DataRoot 'update-staging') -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        $o['updated'] = ($script:Errors.Count -eq 0)
        if ($script:Errors.Count -gt 0) { Write-Result $o 2 }
        Say ('  ' + (T 'Devvy was updated to version {0}.' $plan.latest)) 'Green'
        Write-Result $o 0
    }
    '^(?i)profile$' {
        if ($Import) {
            if (-not (Test-Path -LiteralPath $Import)) { [Console]::Error.WriteLine((T 'File not found: {0}' $Import)); Write-Result $base 2 }
            try { $pr = ([IO.File]::ReadAllText((Resolve-Path -LiteralPath $Import).Path, [Text.Encoding]::UTF8)).TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { $pr = $null }
            $res = Import-DevvyProfile $pr
            if (-not $res) { [Console]::Error.WriteLine((T 'This is not a Devvy profile file.')); Write-Result $base 2 }
            Say ('  ' + (T 'Profile imported: {0} exclusion(s) in total, {1} knowledge row(s) and {2} support page(s) added.' $res.exclusions $res.knowledgeAdded $res.supportAdded)) 'Green'
            if (@($res.invalid).Count -gt 0) { Say ('  ' + (T 'Skipped as invalid: {0}.' (@($res.invalid) -join ', '))) 'Yellow' }
            $o = $base; $o['exclusions'] = $res.exclusions; $o['knowledgeAdded'] = $res.knowledgeAdded; $o['supportAdded'] = $res.supportAdded; $o['invalid'] = @($res.invalid)
            Write-Result $o 0
        }
        if ($Export) {
            [IO.File]::WriteAllText($Export, (ConvertTo-Json -InputObject (Get-DevvyProfile) -Depth 6), (New-Object Text.UTF8Encoding($false)))
            Say ('  ' + (T 'Profile exported: devvy-profile.json')) 'Green'
            Write-Result $base 0
        }
        [Console]::Error.WriteLine('Profile: use -Import <file.json> or -Export <file.json>'); Write-Result $base 2
    }
    default { [Console]::Error.WriteLine((T 'Unknown action: {0}' $Action)); [Console]::Error.WriteLine((T 'To see what Devvy can do run: devvy.bat -h')); Write-Result $base 2 }
}
