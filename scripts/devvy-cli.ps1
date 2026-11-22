# Devvy without the web page, for administrators and scheduled tasks:  devvy.bat /cli <Action> [options]
# Everything the page does can be done here; questions of the scripts ([F]/[S]/[M], confirmations, backup) appear in this window.
#   Check | Inventory | Audit | Clean | Search | Install | Rollback | Report | Problem | Share | Defender | Exclusions | Blocked |
#   Settings | KbUpdate | PostCheck | Update | Profile | Restart          (see devvy.bat -h)
# Exit codes: 0 ok, 1 findings, 2 error, 3 restart needed, 4 not allowed, 5 not administrator.
param(
    [Parameter(Position = 0)][string]$Mode = '/cli',   # devvy.bat passes all its arguments (%*), the first one is /cli: this keeps commas in lists intact
    [Parameter(Position = 1)][string]$Action = 'Help',
    [Parameter(Position = 2)][string]$Sub = '',
    [Parameter(Position = 3)][string]$Value = '',
    [ValidateSet('text', 'json')][string]$Output = 'text',
    [switch]$Apply,
    [switch]$Yes,
    [switch]$Review,
    [switch]$AcceptRisk,
    [switch]$Fix,
    [switch]$Restart,
    [string[]]$Parts = @('devices', 'drivers', 'oldversions', 'bluetooth'),
    [ValidateSet('none', 'drivers', 'full')][string]$Backup = '',
    [string]$Select = '',
    [string]$Key = '',
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
    $c = { param($a, $b) Write-Host ('  ' + $a.PadRight(38)) -NoNewline -ForegroundColor Cyan; Write-Host $b }
    Write-Host (T 'Devvy on the command line (no web page). Start it from an administrator prompt:') -ForegroundColor Green
    Write-Host '  devvy.bat /cli <Action> [options]'
    Write-Host (T 'Everything the page does can be done here. Questions appear in this window.')
    Write-Host ''
    Write-Host (T 'Command line: actions') -ForegroundColor Yellow
    & $c '/gui  (devvy.bat /gui)' (T 'Starts the web page (the same as devvy.bat alone). It asks for administrator rights if needed.')
    & $c '-h  /?  /help' (T 'Shows this help. It works without administrator rights.')
    & $c 'Check' (T 'System check (requirements). Add -Fix to repair what can be repaired.')
    & $c 'Inventory' (T 'Creates the inventory of devices, drivers and Bluetooth.')
    & $c 'Audit' (T 'Read only: inventory and summary (ghost devices, old drivers, old Bluetooth pairings, drivers to check).')
    & $c 'Clean' (T 'Preview of the cleanup: nothing is removed. Add -Apply to really remove (-Review lets you keep single items).')
    & $c 'Search' (T 'Read only: looks in the Microsoft catalog for newer drivers (needs the catalog consent in the settings).')
    & $c 'Install' (T 'Chooses and installs drivers from the catalog (preview, or -Apply). -Select newest | 1,3 | all')
    & $c 'Rollback' (T 'Goes back to a driver replaced by Devvy (-Key <id> to choose without asking).')
    & $c 'Report' (T 'Creates the HTML report.')
    & $c 'Problem' (T 'Creates the anonymous problem report (zip) to attach to a GitHub issue.')
    & $c 'Share' (T 'Creates the anonymous copies of the reports for the knowledge base.')
    & $c 'Defender Status|On|Off' (T 'Shows, adds or removes the temporary Microsoft Defender exceptions.')
    & $c 'Exclusions List|Add|Remove <text>' (T 'Devices Devvy never touches.')
    & $c 'Blocked List|Remove <id>' (T 'Device IDs Windows is stopped from reinstalling; Remove undoes the block.')
    & $c 'Settings Show|Set <name>=<value>' (T 'Shows or changes the settings (language, defender, backup, catalogConsent, ...).')
    & $c 'KbUpdate' (T 'Updates the knowledge base from GitHub.')
    & $c 'WuHide' (T 'Hides in Windows Update the drivers removed by Devvy (tries again the ones not offered yet) and saves the data about returning drivers.')
    & $c 'PostCheck' (T 'Checks the PC after a restart (network, screen, devices with errors).')
    & $c 'Update' (T 'Checks for a newer Devvy. Add -Apply to install it.')
    & $c 'Profile -Export|-Import <file.json>' (T 'Saves or adds your exclusions, options and own table rows.')
    & $c 'Restart' (T 'Restarts Windows (asks first).')
    Write-Host ''
    Write-Host (T 'Command line: options') -ForegroundColor Yellow
    & $c '-Output text|json' (T 'Colored text (default) or one JSON object, for scripts (no questions are asked in json).')
    & $c '-Apply' (T 'Really do it (Clean, Install, Update). Without it nothing changes.')
    & $c '-Yes' (T 'Do not ask for confirmations (scripts). Questions of the drivers still get the cautious answer.')
    & $c '-Parts "devices,drivers,..."' (T 'Clean only: devices, drivers, oldversions, bluetooth (comma list in quotes; default all).')
    & $c '-Backup none|drivers|full' (T 'With -Apply: backup before changing (if missing, it is asked or taken from the settings).')
    & $c '-Review' (T 'Clean: choose which suggested items to keep.')
    & $c '-Select newest|1,3|all' (T 'Install: which drivers (newest = the newest of each device, not risky).')
    & $c '-AcceptRisk' (T 'Install: accept risky drivers (screen, network, system, USB...).')
    & $c '-Restart' (T 'Restart Windows at the end if it is needed.')
    Write-Host ''
    Write-Host (T 'Command line: exit codes') -ForegroundColor Yellow
    Write-Host ('  ' + (T '0 ok, 1 findings or update available, 2 error, 3 restart needed, 4 not allowed, 5 not administrator.'))
    Write-Host ''
    Write-Host (T 'Command line: examples') -ForegroundColor Yellow
    Write-Host '  devvy.bat /gui'
    Write-Host '  devvy.bat /cli Audit -Output json'
    Write-Host '  devvy.bat /cli Clean -Apply -Backup drivers'
    Write-Host '  devvy.bat /cli Install'
    Write-Host '  devvy.bat /cli Install -Apply -Select newest -Backup full'
    Write-Host '  devvy.bat /cli Exclusions Add "Intel(R) UHD Graphics 630"'
    Write-Host ''
    Write-Host ((T 'Full guide:') + ' COMMANDS.md')
}
if (@('-h', '/?', '/help') -contains "$Action".ToLower()) { Show-Help; exit 0 }
if (-not $Action -or $Action -eq 'Help') { Write-Host (T 'To see what Devvy can do run: devvy.bat -h'); exit 0 }
if (-not $isAdmin) { [Console]::Error.WriteLine((T 'ERROR: this script needs administrator rights.')); [Console]::Error.WriteLine((T 'Exit code {0}: {1}' 5 (T 'administrator rights needed'))); exit 5 }
$Parts = @($Parts | ForEach-Object { "$_".Split(',') } | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
$json = ($Output -eq 'json')
$ps = 'powershell.exe'
try { $q = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'; if (Test-Path -LiteralPath $q) { $ps = $q } } catch { }
$env:DEVVY_WEB = '1'   # children write UTF-8 and print ##REBOOT##; their questions go through DEVVY_ASKDIR files, answered below
$logDir = Join-Path $script:DataRoot 'logs'; New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $logDir ('cli-' + $stamp + '.txt')
$askRoot = Join-Path (Join-Path $logDir 'web') ('cli-' + $stamp); New-Item -ItemType Directory -Force -Path $askRoot | Out-Null
$script:Reboot = $false; $script:Errors = New-Object System.Collections.Generic.List[string]
$script:StepN = 0; $script:DefOn = $false; $script:Kept = @{}
# questions only when somebody can answer: keyboard present, text mode, no -Yes
$script:Interactive = $false
try { $script:Interactive = ((-not $json) -and (-not $Yes) -and (-not [Console]::IsInputRedirected)) } catch { }
function Say([string]$Text, [string]$Color = 'Gray') { if (-not $json) { Write-Host $Text -ForegroundColor $Color } }
Say (T 'Please wait: Devvy is working. Some steps take a minute or two, nothing is frozen.') 'Yellow'

# One key from a list. Without a keyboard (or with -Yes / json) the default is used and said.
function Ask-Key([string]$Text, [string[]]$Valid, [string]$Default) {
    if (-not $script:Interactive) { Say ($Text + ' -> ' + $Default + ' (' + (T 'no keyboard') + ')') 'DarkGray'; return $Default }
    while ($true) {
        Write-Host ($Text + ' ') -ForegroundColor White -NoNewline
        $k = [Console]::ReadKey($true); $c = $k.KeyChar.ToString().ToUpper()
        if ($Valid -contains $c) { Write-Host $c -ForegroundColor Yellow; return $c }
        Write-Host ''; Write-Host ('  ' + (T 'Invalid key. Press one of:') + ' ' + ($Valid -join ', ')) -ForegroundColor Red
    }
}
function Read-TextShared([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try { $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite'); $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8); $t = $sr.ReadToEnd(); $sr.Close(); return $t } catch { return '' }
}
$script:Skip1 = (T 'QUESTION:'); $script:Skip2 = (T 'Waiting for your answer in the page...')
function Show-Lines([string]$Text) {
    foreach ($ln in ($Text -split "\r?\n")) {
        $l = $ln.TrimEnd(); if (-not $l.Trim() -or $l -match '^\s*##') { continue }
        if ($l.TrimStart().StartsWith($script:Skip1) -or $l.Trim() -eq $script:Skip2) { continue }
        $col = 'Gray'; if ($l -match '(?i)error|errore|fail|NOT') { $col = 'Yellow' }
        Say ('  ' + $l.TrimStart()) $col
    }
}
# Runs one of the scripts as a child process, shows what it prints while it works and answers its questions on the keyboard.
function Invoke-Step([string]$Title, [string]$Script, [string[]]$More = @(), [switch]$Show, [string]$Hint = '') {
    Say ('> ' + $Title) 'Green'
    if ($Hint) { Say ('  ' + $Hint) 'DarkGray' }
    $script:StepN++
    $dir = Join-Path $askRoot ('s' + $script:StepN); New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $of = Join-Path $dir 'out.txt'; $ef = Join-Path $dir 'err.txt'
    $env:DEVVY_ASKDIR = $dir
    $al = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot $Script) + '"'
    if ($More.Count -gt 0) { $al += ' ' + ($More -join ' ') }
    $sp = @{ FilePath = $ps; ArgumentList = $al; PassThru = $true; RedirectStandardOutput = $of; RedirectStandardError = $ef }
    if ($IsWindows -ne $false) { $sp['NoNewWindow'] = $true }
    $p = Start-Process @sp
    $null = $p.Handle
    $shown = 0; $lastQ = ''
    while ($true) {
        $done = $p.HasExited
        $txt = Read-TextShared $of
        if ($txt.Length -gt $shown) {
            $new = $txt.Substring($shown); $cut = $new.LastIndexOf("`n"); if ($done) { $cut = $new.Length - 1 }
            if ($cut -ge 0) { $chunk = $new.Substring(0, $cut + 1); $shown += $chunk.Length; if ($Show) { Show-Lines $chunk } }
        }
        if ($done) { break }
        $qf = Join-Path $dir 'question.json'
        if (Test-Path -LiteralPath $qf) {
            $dq = $null; try { $dq = (Read-TextShared $qf) | ConvertFrom-Json } catch { }
            if ($dq -and "$($dq.id)" -ne $lastQ) {
                $lastQ = "$($dq.id)"
                $valid = @($dq.valid | ForEach-Object { "$_" })
                $def = $valid[0]; if ($valid -contains 'N') { $def = 'N' } elseif ($valid -contains 'X') { $def = 'X' }
                Say ''
                $a = Ask-Key ("$($dq.text)") $valid $def
                Set-Content -LiteralPath (Join-Path $dir 'answer.txt') -Value $a -Encoding ASCII
            }
        }
        Start-Sleep -Milliseconds 300
    }
    $code = $p.ExitCode; if ($null -eq $code) { $code = 0 }
    $errTxt = Read-TextShared $ef
    $all = $txt + $(if ($errTxt) { "`r`n" + $errTxt } else { '' })
    Add-Content -Path $logFile -Value ("===== $Title ($Script) exit $code`r`n" + $all) -Encoding UTF8
    if ($all -match '##REBOOT##') { $script:Reboot = $true }
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
function Stop-DefenderExceptions {
    if (-not $script:DefOn) { return }
    $script:DefOn = $false
    $null = Invoke-Step (T 'Removing the Defender exceptions') '00-defender.ps1' @('-Action', 'Restore') -Show
}
function Write-Result($Obj, [int]$Code) {
    Stop-DefenderExceptions
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

# ---- shared pieces of the flows ----
# Confirmation before really changing something (asked only when somebody is at the keyboard)
function Confirm-Apply([string]$What) {
    if (-not $script:Interactive) { return }
    Say ''
    $a = Ask-Key ((T 'Apply the changes now? ({0})' $What) + ' [Y/N]') @('Y', 'N') 'N'
    if ($a -ne 'Y') { Say (T 'Nothing was changed.') 'Yellow'; Write-Result $base 0 }
}
# Backup chosen with -Backup, else the setting, else (at the keyboard) a question; returns none|drivers|full
function Resolve-Backup {
    if ($Backup) { return $Backup }
    $s = Read-Settings
    if (@('full', 'drivers', 'none') -contains "$($s.backup)") { return "$($s.backup)" }
    if ($script:Interactive) {
        $a = Ask-Key ((T 'Backup before the changes: [F] full (restore point + drivers), [D] drivers only, [N] none') + ' ') @('F', 'D', 'N') 'D'
        return @{ F = 'full'; D = 'drivers'; N = 'none' }[$a]
    }
    return 'none'
}
function Invoke-Backup([string]$Kind) {
    if ($Kind -eq 'full') { $null = Invoke-Step (T 'Backup') '00-backup.ps1' @('-Mode', 'Full') -Show }
    elseif ($Kind -eq 'drivers') { $null = Invoke-Step (T 'Backup') '00-backup.ps1' @('-Mode', 'Drivers') -Show }
}
# Microsoft Defender exceptions during the work, as the page does (setting: always | ask | never)
function Start-DefenderExceptions {
    $s = Read-Settings; $go = $false
    if ("$($s.defender)" -eq 'always') { $go = $true }
    elseif ("$($s.defender)" -eq 'ask' -and $script:Interactive) { $go = ((Ask-Key ((T 'Add temporary Microsoft Defender exceptions while Devvy works? [Y/N]') + ' ') @('Y', 'N') 'N') -eq 'Y') }
    if ($go) { $script:DefOn = $true; $null = Invoke-Step (T 'Adding the Defender exceptions') '00-defender.ps1' @('-Action', 'Prepare') -Show }
}
# Offers the restart when Windows needs it
function Finish-Reboot {
    if (-not $script:Reboot) { return }
    Say ''; Say (T 'Windows must be restarted to finish.') 'Yellow'
    $go = [bool]$Restart
    if (-not $go -and $script:Interactive) { $go = ((Ask-Key ((T 'Restart Windows now? [Y/N]') + ' ') @('Y', 'N') 'N') -eq 'Y') }
    if ($go) { Restart-Windows }
}
function Restart-Windows {
    Stop-DefenderExceptions
    $s = Read-Settings
    if ($s.postRebootCheck -and $IsWindows -ne $false) { try { $null = Register-PostRebootTask (Join-Path (Split-Path $PSScriptRoot) 'devvy.bat') } catch { } }
    Say (T 'Restarting Windows...') 'Yellow'
    if ($IsWindows -ne $false) { Start-Process -FilePath 'shutdown.exe' -ArgumentList ('/r /f /t 5 /c "' + (T 'Restart to finish the driver update') + '"') }
    exit 3
}
function Write-CsvBack($Rows, [string]$Name) { $Rows | Export-Csv -Path (Join-Path $script:ReportDir ($Name + '.csv')) -Delimiter ';' -NoTypeInformation -Encoding UTF8 }
# Lets the person keep single items of the suggested removals (what the page does with the checkboxes)
$script:KeyCol = @{ devices = 'InstanceId'; drivers = 'Driver'; bluetooth = 'MAC' }
$script:NameCol = @{ devices = 'FriendlyName'; drivers = 'InfName'; bluetooth = 'Name' }
function Invoke-Review {
    foreach ($set in @('devices', 'drivers', 'bluetooth')) {
        $rows = @(Get-Rows $set); $rem = @($rows | Where-Object { $_.Action -match '^REMOVE' })
        if ($rem.Count -eq 0) { continue }
        Say ''; Say ((T 'Suggested for removal:') + ' ' + $set) 'Cyan'
        $i = 0; foreach ($r in $rem) { $i++; Say ('  {0,3}. {1}  [{2}]' -f $i, $r.($script:NameCol[$set]), $r.Reason) }
        $ans = Read-Host (T 'Numbers to KEEP (comma separated, Enter = remove all of them)')
        foreach ($n in @("$ans".Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' })) {
            $ix = [int]$n - 1; if ($ix -ge 0 -and $ix -lt $rem.Count) { $rem[$ix].Action = 'KEEP'; $script:Kept[$set + '|' + $rem[$ix].($script:KeyCol[$set])] = $true }
        }
        Write-CsvBack $rows $set
    }
}
# After a new inventory, the items the person chose to keep stay KEEP
function Restore-Kept {
    foreach ($set in @('devices', 'drivers', 'bluetooth')) {
        $rows = @(Get-Rows $set); $chg = $false
        foreach ($r in $rows) { if ($script:Kept.ContainsKey($set + '|' + $r.($script:KeyCol[$set])) -and $r.Action -ne 'KEEP') { $r.Action = 'KEEP'; $chg = $true } }
        if ($chg) { Write-CsvBack $rows $set }
    }
}
$riskClasses = @('Display', 'System', 'Firmware', 'SCSIAdapter', 'HDC', 'Processor', 'USB', 'Net')

switch -Regex ($Action) {
    '^(?i)check$' {
        $null = Invoke-Step (T 'System check') '00-selftest.ps1'
        $rows = @(Get-Rows 'selftest'); $bad = @($rows | Where-Object { $_.Status -ne 'OK' })
        foreach ($r in $rows) { $col = 'Green'; if ($r.Status -eq 'WARN') { $col = 'Yellow' } elseif ($r.Status -eq 'ERROR') { $col = 'Red' }; Say ('  {0,-6} {1}: {2}' -f $r.Status, $r.Check, $r.Detail) $col; if ($r.Status -ne 'OK' -and $r.WhatToDo) { Say ('         ' + $r.WhatToDo) 'DarkGray' } }
        foreach ($r in @($bad | Where-Object { $_.FixId -match '^enable-service:(Schedule|wuauserv|bthserv)$' })) {
            $go = [bool]$Fix
            if (-not $go -and $script:Interactive) { $go = ((Ask-Key ((T 'Fix it now: {0}? [Y/N]' $r.Check) + ' ') @('Y', 'N') 'N') -eq 'Y') }
            if ($go) { $null = Invoke-Step (T 'Fixing: {0}' $r.Check) '00-fix.ps1' @('-Fix', $r.FixId) -Show }
        }
        $o = $base; $o['checks'] = @($rows | ForEach-Object { [ordered]@{ check = $_.Check; status = $_.Status; detail = $_.Detail } })
        $code = 0; if ($script:Errors.Count -gt 0) { $code = 2 } elseif (@($bad | Where-Object { $_.Status -eq 'ERROR' }).Count -gt 0) { $code = 1 }
        Write-Result $o $code
    }
    '^(?i)inventory$' {
        $null = Invoke-Step (T 'PC inventory') '04-inventory-all.ps1' -Show -Hint (T 'This can take a minute or two...')
        $f = Get-Findings; Show-Summary $f
        $o = $base; $o['summary'] = (& $summ $f)
        Write-Result $o $(if ($script:Errors.Count -gt 0) { 2 } else { 0 })
    }
    '^(?i)audit$' {
        $null = Invoke-Step (T 'PC inventory') '04-inventory-all.ps1' -Hint (T 'This can take a minute or two...')
        $null = Invoke-Step (T 'Drivers to check') '06-drivers-to-check.ps1' @('-SkipWindowsUpdate')
        $f = Get-Findings; Show-Summary $f
        $o = $base; $o['summary'] = (& $summ $f); $o['findings'] = $f
        $code = 0; if ($script:Errors.Count -gt 0) { $code = 2 } elseif ((Get-Total $f) -gt 0) { $code = 1 }
        Write-Result $o $code
    }
    '^(?i)clean$' {
        $bk = 'none'
        $round = 0; $maxRound = 4; $log = New-Object System.Collections.Generic.List[object]; $first = $null
        $s = Read-Settings
        do {
            $round++
            Say ((T 'Round {0}' $round)) 'Cyan'
            $null = Invoke-Step (T 'PC inventory') '04-inventory-all.ps1' -Hint (T 'This can take a minute or two...')
            if ($round -gt 1) { Restore-Kept }
            $f = Get-Findings; Show-Summary $f
            if ($round -eq 1) { $first = & $summ $f }
            if ((Get-Total $f) -eq 0) { break }
            if ($round -eq 1) {
                if ($Review -and $script:Interactive) { Invoke-Review; $f = Get-Findings }
                if ($Apply) {
                    $bk = Resolve-Backup
                    Confirm-Apply ($Parts -join ', ')
                    Start-DefenderExceptions
                    Invoke-Backup $bk
                }
            }
            $ap = @(); if ($Apply) { $ap = @('-Apply') }
            if ($Parts -contains 'devices' -and $f.ghostDevices.Count -gt 0) { $a1 = $ap; if ($Apply -and $s.blockReinstall) { $a1 = @('-Apply', '-BlockReinstall') }; $null = Invoke-Step (T 'Remove ghost devices') '22-remove-devices.ps1' $a1 -Show }
            if ($Parts -contains 'drivers' -and $f.removableDrivers.Count -gt 0) { $a2 = $ap; if ($Apply -and $s.blockReinstall) { $a2 = @('-Apply', '-BlockReinstall') }; $null = Invoke-Step (T 'Remove drivers') '23-remove-drivers.ps1' $a2 -Show }
            if ($Parts -contains 'oldversions') { $null = Invoke-Step (T 'Remove old driver versions') '25-remove-old-versions.ps1' $ap -Show }
            if ($Parts -contains 'bluetooth' -and $f.bluetoothPairings.Count -gt 0) { $null = Invoke-Step (T 'Remove Bluetooth pairings') '21-remove-bluetooth.ps1' $ap -Show }
            $log.Add([ordered]@{ round = $round; found = (& $summ $f) })
            if (-not $Apply) { break }
        } while ($round -lt $maxRound -and -not $script:Reboot)
        if ($Apply) { $null = Invoke-Step (T 'PC inventory') '04-inventory-all.ps1'; $f = Get-Findings; Show-Summary $f }
        $o = $base; $o['firstFound'] = $first; $o['rounds'] = $log.ToArray(); $o['remaining'] = (& $summ $f); $o['backup'] = $bk
        $code = 0
        if ($script:Errors.Count -gt 0) { $code = 2 } elseif ($script:Reboot -and $Apply) { $code = 3 } elseif (-not $Apply -and (Get-Total $f) -gt 0) { $code = 1 }
        if ($Apply) { Finish-Reboot }
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
    '^(?i)install$' {
        if ($s0 = Read-Settings) { if ($s0.catalogConsent -eq $false) { [Console]::Error.WriteLine((T 'The catalog search is switched off in the settings.')); Write-Result $base 4 } }
        $catF = Join-Path $script:ReportDir 'catalog.csv'
        if (-not (Test-Path -LiteralPath $catF) -or ((Get-Date) - (Get-Item -LiteralPath $catF).LastWriteTime).TotalMinutes -gt 30) {
            $null = Invoke-Step (T 'PC inventory') '04-inventory-all.ps1' -Hint (T 'This can take a minute or two...')
            $null = Invoke-Step (T 'Drivers to check') '06-drivers-to-check.ps1' @('-SkipWindowsUpdate')
            $null = Invoke-Step (T 'Microsoft catalog') '08-catalog-search.ps1' @('-SkipConfirm') -Hint (T 'This can take a minute or two...')
        }
        $cat = @(Get-Rows 'catalog' | Where-Object { $_.UpdateId -and $_.FitsSystem -eq 'YES' -and $_.NewerThanCurrent -ne 'NO' })
        if ($cat.Count -eq 0) { Say ('  ' + (T 'No newer driver found in the catalog: nothing to install.')); $o = $base; $o['installed'] = 0; Write-Result $o 0 }
        # the newest of each device first
        $cat = @($cat | Sort-Object Device, @{ Expression = { $_.Date }; Descending = $true })
        Say ''; Say (T 'Drivers found in the catalog (newer than the installed ones):') 'Cyan'
        $i = 0; $newest = @{}
        foreach ($r in $cat) {
            $i++; $risk = ''; if ($riskClasses -contains $r.Class) { $risk = ' [' + (T 'RISKY') + ']' }
            if (-not $newest.ContainsKey($r.Device)) { $newest[$r.Device] = $i }
            $star = ''; if ($newest[$r.Device] -eq $i) { $star = ' *' }
            Say ('  {0,3}. {1}  {2}  {3}  ({4}){5}{6}' -f $i, $r.Device, $r.Version, $r.Date, $r.Class, $risk, $star) $(if ($risk) { 'Yellow' } else { 'Gray' })
            Say ('       ' + $r.Note) 'DarkGray'
        }
        Say ('  * = ' + (T 'the newest of each device')) 'DarkGray'
        $pick = $Select
        if (-not $pick -and $script:Interactive) { $pick = Read-Host (T 'Which to install? numbers (1,3), N = the newest of each device (not risky), A = all, Enter = none') }
        $chosen = @()
        switch -Regex ("$pick".Trim()) {
            '^(?i)(n|newest)$' { $ix = 0; foreach ($r in $cat) { $ix++; if ($newest[$r.Device] -eq $ix -and -not ($riskClasses -contains $r.Class)) { $chosen += $r } } }
            '^(?i)(a|all)$' { $chosen = @($cat) }
            '^[\d,\s]+$' { foreach ($n in @("$pick".Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' })) { $ix = [int]$n - 1; if ($ix -ge 0 -and $ix -lt $cat.Count) { $chosen += $cat[$ix] } } }
        }
        if ($chosen.Count -eq 0) { Say ('  ' + (T 'No driver chosen: nothing to install. Use -Select newest, -Select 1,3 or -Select all.')); $o = $base; $o['installed'] = 0; Write-Result $o 1 }
        $out = @()
        foreach ($r in $chosen) {
            $risky = ($riskClasses -contains $r.Class); $acc = $false
            if ($risky) {
                $acc = [bool]$AcceptRisk
                if (-not $acc -and $script:Interactive) { $acc = ((Ask-Key ((T 'WARNING: {0} is a {1} driver: the screen or the network can flicker or drop. Do you understand the risk and want it? [Y/N]' $r.Device $r.Class) + ' ') @('Y', 'N') 'N') -eq 'Y') }
                if (-not $acc) { Say ('  ' + (T 'Skipped (risk not accepted): {0}' $r.Device)) 'Yellow'; continue }
            }
            $out += [pscustomobject]@{ UpdateId = $r.UpdateId; Device = $r.Device; ShortId = $r.ShortId; Title = $r.Title; Class = $r.Class; Version = $r.Version; Date = $r.Date; RiskAccepted = $acc }
        }
        if ($out.Count -eq 0) { $o = $base; $o['installed'] = 0; Write-Result $o 1 }
        Set-Content -Path (Join-Path $script:ReportDir 'selection.json') -Value (ConvertTo-Json -InputObject @($out) -Depth 4) -Encoding UTF8
        Say ('  ' + (T 'Chosen: {0}' $out.Count)) 'Green'
        $bk = 'none'; $a2 = @()
        if ($Apply) {
            $bk = Resolve-Backup
            Confirm-Apply (T 'install {0} driver(s)' $out.Count)
            Start-DefenderExceptions
            Invoke-Backup $bk
            $a2 = @('-Apply'); if ($bk -ne 'none') { $a2 += '-SaveOld' }
        }
        $null = Invoke-Step (T 'Install from the catalog') '10-install-from-catalog.ps1' $a2 -Show
        $o = $base; $o['chosen'] = @($out | ForEach-Object { [ordered]@{ device = $_.Device; version = $_.Version } }); $o['backup'] = $bk
        $code = 0; if ($script:Errors.Count -gt 0) { $code = 2 } elseif ($script:Reboot -and $Apply) { $code = 3 } elseif (-not $Apply) { $code = 1 }
        if ($Apply) { Finish-Reboot }
        Write-Result $o $code
    }
    '^(?i)rollback$' {
        $rb = @(Get-Rows 'rollback' | Where-Object { $_.State -ne 'restored' })
        if ($rb.Count -eq 0) { Say ('  ' + (T 'No replaced driver to go back to.')); Write-Result $base 0 }
        $sel = $null
        if ($Key) { $sel = $rb | Where-Object { $_.Key -eq $Key } | Select-Object -First 1 }
        else {
            Say ''; Say (T 'Drivers replaced by Devvy (you can go back to the previous one):') 'Cyan'
            $i = 0; foreach ($r in $rb) { $i++; Say ('  {0,3}. {1}: {2} -> {3}  ({4})' -f $i, $r.Device, $r.NewVersion, $r.OldVersion, $r.Date); Say ('       Key: ' + $r.Key) 'DarkGray' }
            if ($script:Interactive) { $n = Read-Host (T 'Number to go back to (Enter = none)'); if ("$n" -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $rb.Count) { $sel = $rb[[int]$n - 1] } }
        }
        if (-not $sel) { Say ('  ' + (T 'Nothing chosen. Use -Key <id> to choose without asking.')); Write-Result $base 1 }
        if ($sel.Key -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { Write-Result $base 2 }
        if (-not $Apply -and -not $script:Interactive) { Say ('  ' + (T 'Preview only: add -Apply to go back to {0}.' $sel.Device)) 'Yellow'; Write-Result $base 1 }
        Confirm-Apply (T 'go back: {0}' $sel.Device)
        Start-DefenderExceptions
        $null = Invoke-Step (T 'Going back to the previous driver') '26-rollback-driver.ps1' @('-Key', $sel.Key) -Show
        $code = 0; if ($script:Errors.Count -gt 0) { $code = 2 } elseif ($script:Reboot) { $code = 3 }
        Finish-Reboot
        Write-Result $base $code
    }
    '^(?i)report$' {
        $null = Invoke-Step (T 'HTML report') '07-html-report.ps1' @('-NoOpen') -Show
        $rp = Join-Path $script:ReportDir 'report.html'
        if (Test-Path -LiteralPath $rp) { Say ('  ' + (T 'Report:') + ' ' + $rp) 'Green' }
        $o = $base; $o['report'] = $rp
        Write-Result $o $(if ($script:Errors.Count -gt 0) { 2 } else { 0 })
    }
    '^(?i)problem$' {
        $null = Invoke-Step (T 'Problem report') '27-problem-report.ps1' -Show
        $z = Get-ChildItem -Path $script:ReportDir -Filter 'problem-report-*.zip' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($z) { Say ('  ' + (T 'Attach this file to the GitHub issue:') + ' ' + $z.FullName) 'Green' }
        $o = $base; $o['zip'] = $(if ($z) { $z.FullName } else { '' })
        Write-Result $o $(if ($script:Errors.Count -gt 0) { 2 } else { 0 })
    }
    '^(?i)share$' {
        $null = Invoke-Step (T 'Anonymous copies of the reports') '05-anonymize-reports.ps1' -Show
        $z = Get-ChildItem -Path $script:ReportDir -Filter 'shareable-*.zip' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($z) { Say ('  ' + (T 'File:') + ' ' + $z.FullName) 'Green' }
        $o = $base; $o['zip'] = $(if ($z) { $z.FullName } else { '' })
        Write-Result $o $(if ($script:Errors.Count -gt 0) { 2 } else { 0 })
    }
    '^(?i)defender$' {
        $m = @{ status = 'Status'; on = 'Prepare'; off = 'Restore' }["$Sub".ToLower()]
        if (-not $m) { [Console]::Error.WriteLine((T 'Use: Defender Status | On | Off')); Write-Result $base 2 }
        if ($m -eq 'Status') { $null = Invoke-Step (T 'Microsoft Defender') '00-defender.ps1' @('-Action', 'Status') -Show; $null = Invoke-Step (T 'Microsoft Defender') '00-defender.ps1' @('-Action', 'Diagnose') -Show }
        else {
            if ($m -eq 'Restore') { Confirm-Apply (T 'remove the Defender exceptions') }
            $null = Invoke-Step (T 'Microsoft Defender') '00-defender.ps1' @('-Action', $m) -Show
        }
        Write-Result $base $(if ($script:Errors.Count -gt 0) { 2 } else { 0 })
    }
    '^(?i)exclusions$' {
        $s = Read-Settings; $ex = @($s.exclusions)
        switch ("$Sub".ToLower()) {
            { $_ -in @('', 'list') } {
                if ($ex.Count -eq 0) { Say ('  ' + (T 'No exclusions: Devvy may touch every device.')) }
                foreach ($e in $ex) { Say ('  - ' + ($e -replace '\\(.)', '$1')) }
                $o = $base; $o['exclusions'] = $ex; Write-Result $o 0
            }
            'add' {
                if (-not $Value) { [Console]::Error.WriteLine((T 'Use: Exclusions Add "<device name>"')); Write-Result $base 2 }
                $pat = [regex]::Escape($Value)
                if ($ex -contains $pat) { Say ('  ' + (T 'Already in the list: {0}' $Value)) 'Yellow' }
                else { $s.exclusions = @($ex + $pat); Save-Settings $s; Say ('  ' + (T 'Added to the exclusions: {0}' $Value)) 'Green' }
                Write-Result $base 0
            }
            'remove' {
                $keep = @($ex | Where-Object { $_ -ne [regex]::Escape($Value) -and $_ -ne $Value })
                if ($keep.Count -eq $ex.Count) { Say ('  ' + (T 'Not in the list: {0}' $Value)) 'Yellow'; Write-Result $base 1 }
                $s.exclusions = @($keep); Save-Settings $s; Say ('  ' + (T 'Removed from the exclusions: {0}' $Value)) 'Green'
                Write-Result $base 0
            }
            default { [Console]::Error.WriteLine((T 'Use: Exclusions List | Add <text> | Remove <text>')); Write-Result $base 2 }
        }
    }
    '^(?i)blocked$' {
        $bl = @(Get-BlockedListReal)
        switch ("$Sub".ToLower()) {
            { $_ -in @('', 'list') } {
                if ($bl.Count -eq 0) { Say ('  ' + (T 'No blocked devices.')) }
                foreach ($b in $bl) { Say ('  - ' + $b.Id + '   ' + $b.Driver + '  ' + $b.Date) }
                $o = $base; $o['blocked'] = @($bl | ForEach-Object { $_.Id }); Write-Result $o 0
            }
            'remove' {
                if (@($bl | Where-Object { $_.Id -ieq $Value }).Count -eq 0) { Say ('  ' + (T 'Not found: {0}' $Value)) 'Yellow'; Write-Result $base 1 }
                Confirm-Apply (T 'let Windows install {0} again' $Value)
                try { Remove-BlockedId $Value; Say ('  ' + (T 'Block removed: {0}' $Value)) 'Green' } catch { $script:Errors.Add($_.Exception.Message); Say ('  ' + $_.Exception.Message) 'Red' }
                Write-Result $base $(if ($script:Errors.Count -gt 0) { 2 } else { 0 })
            }
            default { [Console]::Error.WriteLine((T 'Use: Blocked List | Remove <id>')); Write-Result $base 2 }
        }
    }
    '^(?i)settings$' {
        $s = Read-Settings
        $names = @('language', 'defender', 'backup', 'catalogConsent', 'postRebootCheck', 'updateCheck', 'inventoryAtStart', 'blockReinstall')
        if ("$Sub".ToLower() -eq 'set') {
            if ("$Value" -notmatch '^(\w+)=(.*)$') { [Console]::Error.WriteLine((T 'Use: Settings Set <name>=<value>')); Write-Result $base 2 }
            $n = $Matches[1]; $v = $Matches[2].Trim(); $okv = $true
            $nm = @($names | Where-Object { $_ -ieq $n })[0]
            if (-not $nm) { [Console]::Error.WriteLine((T 'Unknown setting: {0}' $n)); Write-Result $base 2 }
            switch ($nm) {
                'language' { if ((Get-AvailableLanguages) -contains $v) { $s.language = $v } else { $okv = $false } }
                'defender' { if (@('ask', 'always', 'never') -contains $v) { $s.defender = $v } else { $okv = $false } }
                'backup' { if (@('ask', 'full', 'drivers', 'none') -contains $v) { $s.backup = $v } else { $okv = $false } }
                default { if (@('true', 'false', 'on', 'off', 'yes', 'no', '1', '0') -contains $v.ToLower()) { $s.$nm = (@('true', 'on', 'yes', '1') -contains $v.ToLower()) } else { $okv = $false } }
            }
            if (-not $okv) { [Console]::Error.WriteLine((T 'Invalid value: {0}' $v)); Write-Result $base 2 }
            Save-Settings $s; Say ('  ' + (T 'Saved: {0} = {1}' $nm $v)) 'Green'
        }
        else { foreach ($n in $names) { Say ('  {0,-18} {1}' -f $n, $s.$n) } }
        $o = $base; $o['settings'] = [ordered]@{}; foreach ($n in $names) { $o['settings'][$n] = $s.$n }
        Write-Result $o 0
    }
    '^(?i)kbupdate$' {
        $null = Invoke-Step (T 'Knowledge base update') '28-update-knowledge.ps1' -Show
        Write-Result $base $(if ($script:Errors.Count -gt 0) { 2 } else { 0 })
    }
    '^(?i)wuhide$' {
        $null = Invoke-Step (T 'Windows Update: hide removed drivers') '31-wu-hide.ps1' -Show
        Write-Result $base $(if ($script:Errors.Count -gt 0) { 2 } else { 0 })
    }
    '^(?i)postcheck$' {
        $null = Invoke-Step (T 'Check after the restart') '30-post-reboot-check.ps1' -Show
        Write-Result $base $(if ($script:Errors.Count -gt 0) { 2 } else { 0 })
    }
    '^(?i)restart$' {
        $go = [bool]$Yes
        if (-not $go) { $go = ((Ask-Key ((T 'Restart Windows now? [Y/N]') + ' ') @('Y', 'N') 'N') -eq 'Y') }
        if ($go) { Restart-Windows }
        Say (T 'Nothing was changed.') 'Yellow'; Write-Result $base 0
    }
    '^(?i)update$' {
        Say ('> ' + (T 'Checking GitHub for a newer version...')) 'Green'
        $plan = Get-UpdatePlan
        if (-not $plan.ok) { [Console]::Error.WriteLine($plan.error); $o = $base; $o['error'] = $plan.error; Write-Result $o 2 }
        $o = $base; $o['installed'] = $plan.current; $o['latest'] = $plan.latest; $o['updateAvailable'] = [bool]$plan.needed
        if (-not $plan.needed) { Say ('  ' + (T 'Devvy is already up to date.')) 'Green'; Say ('  ' + (T 'Installed version:') + ' ' + $plan.current); Write-Result $o 0 }
        Say ('  ' + (T 'Update available: {0} (installed: {1}). To install it: devvy.bat /cli Update -Apply' $plan.latest $plan.current)) 'Yellow'
        if (-not $Apply) { Write-Result $o 1 }
        Confirm-Apply (T 'update Devvy to {0}' $plan.latest)
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
