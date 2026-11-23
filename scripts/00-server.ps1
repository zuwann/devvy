# LOCAL web interface: a small server on 127.0.0.1 (this PC only, random port, secret code) that shows
# the page web\app.html and runs the tool scripts when you click. No data leaves the PC.
# Exit codes: 0 = closed normally, 3 = cannot start the server.
param([switch]$NoOpen, [switch]$AfterRestart)
. "$PSScriptRoot\common.ps1"
Assert-Admin
Start-Log 'web'
$env:DEVVY_WEB = '1'      # no keyboard questions in the scripts
$env:DEVVY_BATCH = '1'    # no "press X in the menu" boxes: the page guides the user

$appPath = Join-Path $PSScriptRoot 'web\app.html'
if (-not (Test-Path $appPath)) { Write-Err (T 'Missing file: {0}' $appPath); Stop-Log; exit 3 }
$appHtml = [IO.File]::ReadAllText($appPath, [Text.Encoding]::UTF8)

# ---------- Only one copy of Devvy ----------
# A named mutex plus data\instance.json (pid + address). A second start opens the page of the copy that is already running.
$script:InstFile = Join-Path $script:DataRoot 'instance.json'
$script:InstMutex = $null
$haveInst = $true
try {
    $script:InstMutex = New-Object System.Threading.Mutex($false, 'Global\DevvyServer')
    try { $haveInst = $script:InstMutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $haveInst = $true }
} catch { $script:InstMutex = $null }
if (-not $haveInst -or ($null -eq $script:InstMutex -and (Test-Path $script:InstFile))) {
    $other = $null
    try { $other = Get-Content -Path $script:InstFile -Raw | ConvertFrom-Json } catch { }
    $alive = $false
    if ($other -and $other.pid) { try { $null = Get-Process -Id ([int]$other.pid) -ErrorAction Stop; $alive = $true } catch { } }
    if ($alive -or -not $haveInst) {
        Write-Host ''
        Write-Warn (T 'Devvy is already running: only one copy at a time is allowed.')
        if ($alive -and $other.url -and -not $NoOpen) { Write-Info ('  ' + (T 'I open the page of the copy that is already running.')); $null = Open-DevvyPage ([string]$other.url) }
        Start-Sleep -Seconds 3
        Stop-Log; exit 0
    }
}

# ---------- One-time task for the check after a restart ----------
# Started by hand while that task is waiting: do not run a second copy, let the task start the program (it knows it is the
# check after the restart). Started by the task (-AfterRestart): go on.
if (-not $AfterRestart -and $IsWindows -ne $false) {
    $tk = Get-PostRebootTask
    if ($tk) {
        $stale = $false
        try { $pf0 = Get-PostRebootFile; if (Test-Path $pf0) { $stale = (((Get-Date) - [datetime]((Get-Content -Path $pf0 -Raw | ConvertFrom-Json).Time)).TotalDays -ge 3) } } catch { }
        if ($stale) { Unregister-PostRebootTask }
        else {
            Write-Host ''
            Write-Warn (T 'The check after the restart is scheduled: Devvy starts by itself from that task.')
            if ("$($tk.State)" -eq 'Running') { Write-Host ('  ' + (T 'It is already starting: wait a few seconds, the page opens by itself.')) -ForegroundColor Yellow }
            else {
                try { Start-ScheduledTask -TaskName $script:PostRebootTask -ErrorAction Stop; Write-Ok ('  ' + (T 'I started it now: the page opens in a few seconds.')) }
                catch { Write-Err ((T 'I could not start the scheduled task: {0}' $_.Exception.Message) + ' ' + (T 'Delete the task "Devvy-AfterRestart" in the Task Scheduler and start Devvy again.')) }
            }
            Start-Sleep -Seconds 4
            Stop-Log; exit 0
        }
    }
}

# ---------- Server ----------
$token = [guid]::NewGuid().ToString('N')
$listener = $null
$port = 0
foreach ($i in 1..20) {
    $p = Get-Random -Minimum 49200 -Maximum 64900
    $l = New-Object System.Net.HttpListener
    $l.Prefixes.Add('http://127.0.0.1:' + $p + '/')
    try { $l.Start(); $listener = $l; $port = $p; break } catch { try { $l.Close() } catch { } }
}
if (-not $listener) {
    Write-Err (T 'Cannot start the local server (port busy or blocked).')
    Stop-Log
    exit 3
}
$origin = 'http://127.0.0.1:' + $port
# Started by the one-time task after a restart? Then the page runs the post-restart check
$script:PostReboot = $false
try {
    $pf = Get-PostRebootFile
    if (Test-Path $pf) {
        $pt = [datetime]((Get-Content -Path $pf -Raw | ConvertFrom-Json).Time)
        if (((Get-Date) - $pt).TotalDays -lt 3) { $script:PostReboot = $true } else { Remove-Item -Path $pf -Force -ErrorAction SilentlyContinue }
        Unregister-PostRebootTask
    }
} catch { }
$url = $origin + '/?t=' + $token
try { [IO.File]::WriteAllText($script:InstFile, (ConvertTo-Json -InputObject @{ pid = $PID; url = $url; time = (Get-Date).ToString('s') }), (New-Object Text.UTF8Encoding($false))) } catch { }

# ---------- Response helpers ----------
function Send-Resp($ctx, [int]$Code, [string]$Type, [string]$Body, [string]$Cookie = '') {
    $b = [Text.Encoding]::UTF8.GetBytes($Body)
    $r = $ctx.Response
    $r.StatusCode = $Code
    $r.ContentType = $Type + '; charset=utf-8'
    $r.Headers.Add('Cache-Control', 'no-store')
    $r.Headers.Add('X-Content-Type-Options', 'nosniff')
    $r.Headers.Add('Content-Security-Policy', "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; frame-ancestors 'none'")
    if ($Cookie) { $r.Headers.Add('Set-Cookie', $Cookie) }
    $r.ContentLength64 = $b.Length
    $r.OutputStream.Write($b, 0, $b.Length)
    $r.OutputStream.Close()
}
function Send-Json($ctx, $Obj, [int]$Code = 200) { Send-Resp $ctx $Code 'application/json' (ConvertTo-Json -InputObject $Obj -Depth 6 -Compress) }
function Read-Body($ctx) {
    $sr = New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
    $t = $sr.ReadToEnd()
    $sr.Close()
    if ($t.Length -gt 2000000) { return $null }
    return $t
}


# ---------- Short description of this PC (shown in the page header) ----------
$script:PcInfo = $null

# ---------- Data (CSV) ----------
function Read-CsvQuiet([string]$Name) {
    $path = Join-Path $script:ReportDir ($Name + '.csv')
    if (-not (Test-Path $path)) { return @() }
    $first = Get-Content -Path $path -TotalCount 1
    $delim = ';'
    if ($first -and ($first.Split(';').Count -lt 2) -and ($first.Split(',').Count -gt 1)) { $delim = ',' }
    return @(Import-Csv -Path $path -Delimiter $delim)
}
function Write-CsvInPlace($Rows, [string]$Name) {
    $path = Join-Path $script:ReportDir ($Name + '.csv')
    $Rows | Export-Csv -Path $path -Delimiter ';' -NoTypeInformation -Encoding UTF8
}

# What the page may read: name -> (file, columns)
$dataSets = @{
    devices   = @{ File = 'devices'; Cols = @('Action', 'KbId', 'Category', 'Present', 'Class', 'FriendlyName', 'InstanceId', 'Manufacturer', 'DriverVersion', 'HardwareIds', 'InfPath', 'InfDescription', 'What', 'Advice', 'Reason', 'GhostKind') }
    drivers   = @{ File = 'drivers'; Cols = @('Action', 'KbId', 'Origin', 'Category', 'Driver', 'InfName', 'Provider', 'Class', 'Version', 'Date', 'UsedByPresent', 'Versions', 'HardwareIds', 'InfPath', 'InfDescription', 'What', 'Risk', 'Advice', 'Reason') }
    bluetooth = @{ File = 'bluetooth'; Cols = @('Action', 'MAC', 'Name', 'Present', 'InRegistry', 'Reason') }
    catalog   = @{ File = 'catalog'; Cols = @('Device', 'Class', 'ShortId', 'CurrentDriver', 'UpdateId', 'Title', 'Date', 'Version', 'FitsSystem', 'Architecture', 'NewerThanCurrent', 'SearchLink', 'Note') }
    rollback  = @{ File = 'rollback'; Cols = @('Key', 'Date', 'Device', 'Class', 'OldInf', 'OldVersion', 'OldDate', 'Provider', 'NewVersion', 'BackupPath', 'State') }
    check     = @{ File = 'drivers-to-check'; Cols = @('Severity', 'Reason', 'Device', 'Class', 'DriverProvider', 'DriverVersion', 'DriverDate', 'WindowsUpdate') }
    selftest  = @{ File = 'selftest'; Cols = @('Check', 'Status', 'Detail', 'WhatToDo', 'FixId') }
    unknown   = @{ File = 'unknown'; Cols = @('Id', 'InfName', 'Provider', 'Class', 'Version', 'Date', 'UsedByPresent', 'HardwareIds', 'InfPath', 'InfDescription') }
}
$keyOf = @{ devices = 'InstanceId'; drivers = 'Driver'; bluetooth = 'MAC' }
$allowedValues = @{
    devices   = @('KEEP', 'REMOVE')
    drivers   = @('KEEP', 'REMOVE', 'REMOVE+UNINSTALL')
    bluetooth = @('KEEP', 'REMOVE')
}
# Fixes the page may ask for (the same list is checked again by 00-fix.ps1)
$okFixes = '^enable-service:(Schedule|wuauserv|bthserv)$'

function Test-RowProtected([string]$Type, $Row) {
    if ($Type -eq 'devices') { return (Test-Excluded ('{0} {1} {2}' -f $Row.FriendlyName, $Row.Manufacturer, $Row.InstanceId) $Row.Class) }
    if ($Type -eq 'drivers') {
        if ($Row.Origin -ne 'Third-party') { return $true }
        return (Test-Excluded ('{0} {1}' -f $Row.Provider, $Row.InfName) $Row.Class)
    }
    return $false
}

# ---------- Language: the page gets the same translation file as the scripts ----------
function Set-UiLanguage([string]$Code) {
    if ((Get-AvailableLanguages) -notcontains $Code) { $Code = 'en' }
    $script:Lang = $Code
    $script:Strings = @{}
    if ($Code -ne 'en') {
        $lf = Join-Path $script:LocalesDir ($Code + '.json')
        if (Test-Path $lf) {
            try {
                $j = Get-Content -Path $lf -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($p in $j.PSObject.Properties) { $script:Strings[$p.Name] = [string]$p.Value }
            } catch { }
        }
    }
}
$langNames = @{ en = 'English'; it = 'Italiano'; es = 'Espa' + [char]0xF1 + 'ol'; de = 'Deutsch'; fr = 'Fran' + [char]0xE7 + 'ais' }

# ---------- Jobs (scripts started from the page, one at a time) ----------
$script:Job = $null
$script:JobSeq = 0
$webLog = Join-Path $script:LogDir 'web'
New-Item -ItemType Directory -Force -Path $webLog | Out-Null
$script:DefenderOn = $false
$script:DefenderOk = $false

# Only these scripts and arguments: the page cannot start anything else
$fixedActions = @{
    'selftest'       = @(, @('00-selftest.ps1'))
    'inventory'      = @(, @('04-inventory-all.ps1'))
    'search'         = @(@('06-drivers-to-check.ps1', '-SkipWindowsUpdate'), @('08-catalog-search.ps1', '-SkipConfirm'))
    'report'         = @(, @('07-html-report.ps1', '-NoOpen'))
    'postcheck'      = @(, @('30-post-reboot-check.ps1'))
    'anonymize'      = @(, @('05-anonymize-reports.ps1'))
    'problem'        = @(, @('27-problem-report.ps1'))
    'kbupdate'       = @(, @('28-update-knowledge.ps1'))
    'selfupdate'     = @(, @('29-self-update.ps1'))
    'def-prepare'    = @(, @('00-defender.ps1', '-Action', 'Prepare'))
    'def-restore'    = @(, @('00-defender.ps1', '-Action', 'Restore'))
    'def-status'     = @(@('00-defender.ps1', '-Action', 'Status'), @('00-defender.ps1', '-Action', 'Diagnose'))
}
# Job kinds (the page translates them): selftest, inventory, search, report, anonymize, defender, fix, preview, apply
$kindOf = @{ 'selftest' = 'selftest'; 'inventory' = 'inventory'; 'search' = 'search'; 'report' = 'report'; 'anonymize' = 'anonymize'; 'problem' = 'problem'; 'kbupdate' = 'kbupdate'; 'selfupdate' = 'selfupdate'; 'postcheck' = 'postcheck'
             'def-prepare' = 'defender'; 'def-restore' = 'defender'; 'def-status' = 'defender' }
$execParts = [ordered]@{ 'catalog-install' = '10-install-from-catalog.ps1'; 'bluetooth' = '21-remove-bluetooth.ps1'
                         'devices' = '22-remove-devices.ps1'; 'drivers' = '23-remove-drivers.ps1'; 'versions' = '25-remove-old-versions.ps1' }

function Start-Step {
    $j = $script:Job
    $st = $j.Steps[$j.Idx]
    $script2 = Join-Path $PSScriptRoot $st[0]
    $args2 = '-NoProfile -ExecutionPolicy Bypass -File "' + $script2 + '"'
    if ($st.Count -gt 1) { $args2 = $args2 + ' ' + (($st[1..($st.Count - 1)]) -join ' ') }
    $j.OutFile = Join-Path $webLog ('job-' + $j.Id + '-' + $j.Idx + '.txt')
    $j.ErrFile = Join-Path $webLog ('job-' + $j.Id + '-' + $j.Idx + '.err.txt')
    $sp = @{ FilePath = 'powershell.exe'; ArgumentList = $args2; PassThru = $true; RedirectStandardOutput = $j.OutFile; RedirectStandardError = $j.ErrFile }
    if ($IsWindows -ne $false) { $sp['WindowStyle'] = 'Hidden' }
    $askDir = Join-Path $webLog ('ask-' + $j.Id)
    New-Item -ItemType Directory -Force -Path $askDir | Out-Null
    $env:DEVVY_ASKDIR = $askDir
    $j.Proc = Start-Process @sp
    $null = $j.Proc.Handle
}
function Read-Shared([string]$Path) {
    if (-not $Path -or -not (Test-Path $Path)) { return '' }
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
        $t = $sr.ReadToEnd(); $sr.Close()
        return $t
    } catch { return '' }
}
function Update-Job {
    $j = $script:Job
    if (-not $j -or $j.Status -ne 'running') { return }
    if ($j.Proc -and $j.Proc.HasExited) {
        $j.Text = $j.Text + (Read-Shared $j.OutFile) + (Read-Shared $j.ErrFile)
        $code = $j.Proc.ExitCode
        if ($code -ne 0) {
            $j.Status = 'error'; $j.Exit = $code
            $j.Text = $j.Text + "`r`n--- " + (T 'Step stopped (code {0}): the next steps were NOT run.' $code) + " ---`r`n"
            return
        }
        if ($j.Text -match '##DEFENDER covered=(true|false)##') { $script:DefenderOk = ($Matches[1] -eq 'true') }
        $j.Idx++
        if ($j.Idx -ge $j.Steps.Count) { $j.Status = 'done'; $j.Exit = 0; return }
        $j.Text = $j.Text + "`r`n"
        try { Start-Step }
        catch { $j.Status = 'error'; $j.Exit = -1; $j.Text = $j.Text + (T 'Cannot start the next step: {0}' $_.Exception.Message) }
    }
}
function Get-JobText {
    $j = $script:Job
    if (-not $j) { return '' }
    if ($j.Status -eq 'running') { return ($j.Text + (Read-Shared $j.OutFile)) }
    return $j.Text
}
function Get-JobPct {
    $j = $script:Job
    if (-not $j) { return 0 }
    if ($j.Status -eq 'done') { return 100 }
    $n = [math]::Max(1, $j.Steps.Count)
    $frac = 0.0
    $txt = ''
    try { $txt = Read-Shared $j.OutFile } catch { }
    $m = [regex]::Matches([string]$txt, '##PROG (\d+)/(\d+)##')
    if ($m.Count -gt 0) {
        $l = $m[$m.Count - 1]
        $b = [double]$l.Groups[2].Value
        if ($b -gt 0) { $frac = [math]::Min(0.98, [double]$l.Groups[1].Value / $b) }
    }
    # soft progress: between two markers the bar creeps up slowly (asymptote), never past the next marker
    if ($j.MarkIdx -ne $j.Idx -or [math]::Abs($j.MarkFrac - $frac) -gt 0.0001) { $j.MarkIdx = $j.Idx; $j.MarkFrac = $frac; $j.MarkT = [datetime]::Now }
    $dt = ([datetime]::Now - $j.MarkT).TotalSeconds
    $unit = 0.5
    if ($m.Count -gt 0 -and [double]$m[$m.Count - 1].Groups[2].Value -gt 0) { $unit = 1.0 / [double]$m[$m.Count - 1].Groups[2].Value }
    $frac = [math]::Min(0.98, $frac + $unit * 0.9 * (1.0 - [math]::Exp(-$dt / 25.0)))
    $p = [int][math]::Floor(100.0 * ($j.Idx + $frac) / $n)
    if ($j.Status -eq 'running') { $p = [math]::Min($p, 99) }
    return [math]::Max(0, $p)
}
function Get-JobReboot {
    $j = $script:Job
    if (-not $j -or $j.Status -ne 'done' -or $j.Kind -ne 'apply') { return $false }
    if ($j.Text -match '##REBOOT##') { return $true }
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')) {
        if (Test-Path $k) { return $true }
    }
    return $false
}
function New-Job([string]$Kind, $Steps) {
    $script:JobSeq++
    $script:Job = [pscustomobject]@{ Id = $script:JobSeq; Kind = $Kind; Steps = @($Steps); Idx = 0; Proc = $null; Status = 'running'; Exit = $null; Text = ''; OutFile = ''; ErrFile = ''
                                     MarkFrac = -1.0; MarkT = [datetime]::Now; MarkIdx = -1 }
    try { Start-Step }
    catch {
        $script:Job.Status = 'error'; $script:Job.Exit = -1
        $script:Job.Text = (T 'Cannot start the job: {0}' $_.Exception.Message)
    }
}
function Invoke-DefenderScript([string]$Action) {
    $of = Join-Path $webLog ('defender-' + $Action.ToLower() + '.txt')
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot '00-defender.ps1') + '" -Action ' + $Action) -Wait -WindowStyle Hidden -RedirectStandardOutput $of
        $t = Read-Shared $of
        if ($t -match '##DEFENDER covered=(true|false)##') { $script:DefenderOk = ($Matches[1] -eq 'true') }
        return $t
    } catch { return '' }
}

# ---------- Request handling ----------
function Test-Auth($ctx) {
    $req = $ctx.Request
    if ($req.Headers['Host'] -ne ('127.0.0.1:' + $port)) { return $false }
    $o = $req.Headers['Origin']
    if ($o -and $o -ne $origin) { return $false }
    $c = $req.Cookies['pt']
    if (-not $c -or $c.Value -ne $token) { return $false }
    if ($req.Headers['X-Devvy'] -ne '1') { return $false }
    return $true
}

function Get-SettingsForPage {
    $s = $script:Settings
    $langs = @()
    foreach ($c in (Get-AvailableLanguages)) { $nm = $c; if ($langNames.ContainsKey($c)) { $nm = $langNames[$c] }; $langs += @{ code = $c; name = $nm } }
    return @{ language = $script:Lang; detected = (Get-DetectedLanguage); languages = $langs; exclusions = @($s.exclusions); defender = "$($s.defender)"; backup = "$($s.backup)"
              theme = "$($s.theme)"; dataDir = "$($s.dataDir)"; dataDirNow = $script:DataRoot; catalogConsent = [bool]$s.catalogConsent; inventoryAtStart = [bool]$s.inventoryAtStart; blockReinstall = [bool]$s.blockReinstall; postRebootCheck = [bool]$s.postRebootCheck; updateCheck = ($s.updateCheck -ne $false); firstRunDone = [bool]$s.firstRunDone }
}

function Handle-Api($ctx, [string]$Path, [string]$Method) {
    $body = $null
    if ($Method -eq 'POST') {
        $raw = Read-Body $ctx
        if ($null -eq $raw) { Send-Json $ctx @{ error = (T 'Request too large') } 413; return }
        try { if ($raw) { $body = $raw | ConvertFrom-Json } } catch { Send-Json $ctx @{ error = (T 'Invalid JSON') } 400; return }
    }

    if ($Path -eq '/api/i18n') {
        Send-Json $ctx @{ lang = $script:Lang; strings = $script:Strings }
        return
    }
    if ($Path -eq '/api/health') {
        # Summary of what the inventories found: counts only, every item says where to go
        $dev = @(Read-CsvQuiet 'devices'); $drv = @(Read-CsvQuiet 'drivers'); $bt = @(Read-CsvQuiet 'bluetooth')
        $chk = @(Read-CsvQuiet 'drivers-to-check'); $cat = @(Read-CsvQuiet 'catalog')
        $items = @()
        if ($dev.Count -gt 0) {
            $n = @($dev | Where-Object { $_.Action -match '^REMOVE' }).Count
            $items += @{ id = 'ghosts'; count = $n; tab = 'devices' }
            $np = @($dev | Where-Object { $_.Present -eq 'YES' -and "$($_.Problem)" -and "$($_.Problem)" -ne 'CM_PROB_NONE' -and "$($_.Problem)" -ne '0' }).Count
            $items += @{ id = 'problems'; count = $np; tab = 'devices' }
        }
        if ($bt.Count -gt 0 -or (Test-Path (Join-Path $script:ReportDir 'bluetooth.csv'))) {
            $items += @{ id = 'btpairs'; count = @($bt | Where-Object { $_.Action -match '^REMOVE' }).Count; tab = 'bluetooth' }
        }
        if ($drv.Count -gt 0) {
            $old = @($drv | Where-Object { $_.Action -match '^REMOVE' -and [int]$_.UsedByPresent -eq 0 }).Count
            $items += @{ id = 'olddrivers'; count = $old; tab = 'drivers' }
            $unk = @($drv | Where-Object { $_.Origin -eq 'Third-party' -and -not $_.KbId }).Count
            $items += @{ id = 'unknown'; count = $unk; tab = 'drivers' }
        }
        if (Test-Path (Join-Path $script:ReportDir 'drivers-to-check.csv')) {
            $items += @{ id = 'tocheck'; count = @($chk | Where-Object { $_.Severity -ne 'Info' }).Count; tab = 'updates' }
        }
        if (Test-Path (Join-Path $script:ReportDir 'catalog.csv')) {
            $dv = @{}
            foreach ($c in $cat) { if ($c.UpdateId -and $c.NewerThanCurrent -ne 'NO') { $dv["$($c.ShortId)|$($c.Device)"] = 1 } }
            $items += @{ id = 'updates'; count = $dv.Count; tab = 'updates' }
        }
        Send-Json $ctx @{ items = @($items) }
        return
    }
    if ($Path -eq '/api/state') {
        $rep = @{}
        foreach ($n in @('devices', 'drivers', 'bluetooth', 'drivers-to-check', 'catalog', 'selftest', 'unknown')) { $rep[$n] = (Test-Path (Join-Path $script:ReportDir ($n + '.csv'))) }
        $times = @{}
        foreach ($n in @('devices', 'drivers', 'bluetooth')) { $fp = Join-Path $script:ReportDir ($n + '.csv'); if (Test-Path $fp) { try { $times[$n] = (Get-Item $fp).LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ') } catch { } } }
        $rep['html-report'] = (Test-Path (Join-Path $script:ReportDir 'report.html'))
        $rep['selection'] = (Test-Path (Join-Path $script:ReportDir 'selection.json'))
        $build = 0
        try { $build = [int][Environment]::OSVersion.Version.Build } catch { }
        $defActive = $false
        $defFile = Join-Path $script:LogDir 'defender-exceptions.json'
        if ($script:DefenderOk) { $defActive = $true }
        if (Test-Path $defFile) { try { if ((Get-Item $defFile).Length -gt 5) { $defActive = $true } } catch { } }
        if (-not $script:BootIso) { $script:BootIso = ''; try { $script:BootIso = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } catch { } }
        $cont = $null
        try { $cf = Get-ContinueFile; if ($script:PostReboot -and (Test-Path $cf)) { $cj = Get-Content -Path $cf -Raw -Encoding UTF8 | ConvertFrom-Json; if (((Get-Date) - [datetime]$cj.Time).TotalDays -lt 3) { $cont = $cj } } } catch { }
        Send-Json $ctx @{ cont = $cont; report = $rep; times = $times; boot = $script:BootIso; postReboot = [bool]$script:PostReboot; defender = $defActive; folder = $script:Root; arch = $env:PROCESSOR_ARCHITECTURE; build = $build; settings = (Get-SettingsForPage) }
        return
    }
    if ($Path -eq '/api/about') {
        if (-not $script:AboutFiles) {
            $list = @()
            $root = $script:Root.TrimEnd('\', '/')
            $files = @(Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '[\\/]data[\\/]' -and $_.Extension -match '^\.(ps1|bat|html|csv|json|txt|md)$' -or $_.Name -eq 'LICENSE' })
            foreach ($f in ($files | Sort-Object FullName)) {
                $hash = ''
                try { $hash = (Get-FileHash -Path $f.FullName -Algorithm SHA256 -ErrorAction Stop).Hash } catch { }
                $list += @{ file = $f.FullName.Substring($root.Length).TrimStart('\', '/'); sha256 = $hash }
            }
            $script:AboutFiles = $list
        }
        # drop the downloads whose driver does not exist any more (the rows go to downloads-gone.csv)
        try {
            $dRows = @(Read-CsvQuiet 'downloads')
            if ($dRows.Count -gt 0 -and $IsWindows -ne $false) {
                $pk = @(Get-DriverPackages); $infMap = Get-DownloadInfs
                if ($pk.Count -gt 0) {
                    $have = @{}; $vers = @{}
                    foreach ($q in $pk) { $have["$($q.Driver)".ToLower()] = 1; $vers["$($q.Version)"] = 1 }
                    $keep = @(); $gone = @()
                    foreach ($dr in $dRows) {
                        $isGone = $false
                        if ("$($dr.Result)" -ne (T 'REFUSED')) {
                            if ($infMap.ContainsKey("$($dr.Sha256)")) { $isGone = (@($infMap["$($dr.Sha256)"] | Where-Object { $have.ContainsKey($_) }).Count -eq 0) }
                            else { $tk = @([regex]::Matches("$($dr.Package)", '\d+\.\d+\.\d+\.\d+') | ForEach-Object { $_.Value }); if ($tk.Count -gt 0) { $isGone = (@($tk | Where-Object { $vers.ContainsKey($_) }).Count -eq 0) } }
                        }
                        if ($isGone) { $gone += $dr } else { $keep += $dr }
                    }
                    if ($gone.Count -gt 0) {
                        $gone | Export-Csv -Path (Join-Path $script:ReportDir 'downloads-gone.csv') -Append -Delimiter ';' -NoTypeInformation -Encoding UTF8
                        $dp = Join-Path $script:ReportDir 'downloads.csv'
                        if ($keep.Count -gt 0) { $keep | Export-Csv -Path $dp -Delimiter ';' -NoTypeInformation -Encoding UTF8 } else { Remove-Item -Path $dp -Force -ErrorAction SilentlyContinue }
                    }
                }
            }
        } catch { }
        $dls = @(Read-CsvQuiet 'downloads' | ForEach-Object { @{ date = "$($_.Date)"; package = "$($_.Package)"; sha256 = "$($_.Sha256)"; signer = "$($_.Signer)"; result = "$($_.Result)" } })
        $guide = ''; if ($script:IssuesUrl -notmatch 'OWNER') { $guide = ($script:IssuesUrl -replace '/issues/new.*$', '/blob/main/COMMANDS.md') }
        Send-Json $ctx @{ files = @($script:AboutFiles); downloads = @($dls); data = "$script:DataRoot"; folder = "$script:Root"; guideUrl = $guide }
        return
    }
    if ($Path -eq '/api/commands') {
        # the list of the command line commands, in the language of the page: it is the output of `devvy.bat -h` (same texts, same translations)
        $of = Join-Path $webLog 'commands.txt'
        $txt = ''
        try {
            Remove-Item -Path $of -Force -ErrorAction SilentlyContinue
            $sp = @{ FilePath = 'powershell.exe'; ArgumentList = ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'devvy-cli.ps1') + '" /cli /help'); PassThru = $true; RedirectStandardOutput = $of }
            if ($IsWindows -ne $false) { $sp['WindowStyle'] = 'Hidden' }
            $pc = Start-Process @sp
            $null = $pc.Handle
            if (-not $pc.WaitForExit(20000)) { try { $pc.Kill() } catch { } }
            $txt = (Read-Shared $of)
        } catch { }
        Send-Json $ctx @{ text = "$txt" }
        return
    }
    if ($Path -eq '/api/update/check') {
        $pl = Get-UpdatePlan
        if (-not $pl.ok) { Send-Json $ctx @{ ok = $false; error = "$($pl.error)"; ready = ($script:UpdateRepo -notmatch 'OWNER') }; return }
        Send-Json $ctx @{ ok = $true; ready = $true; current = "$($pl.current)"; latest = "$($pl.latest)"; needed = [bool]$pl.needed
                          added = @($pl.added).Count; changed = @($pl.changed).Count; removed = @($pl.removed).Count
                          names = @((@($pl.added) + @($pl.changed) + @($pl.removed)) | Select-Object -First 30) }
        return
    }
    if ($Path -eq '/api/restart' -and $Method -eq 'POST') {
        # After an update: a helper waits for this process to end, puts devvy.bat in place and starts the program again
        $rp = Join-Path $PSScriptRoot 'restart.ps1'
        $par = 0; try { $par = [int](Get-CimInstance Win32_Process -Filter ('ProcessId=' + $PID) -ErrorAction Stop).ParentProcessId } catch { }
        try {
            $null = Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $rp + '" -ServerPid ' + $PID + ' -ParentPid ' + $par) -WindowStyle Hidden
        } catch { Send-Json $ctx @{ error = ((T 'Internal error:') + ' ' + $_.Exception.Message) } 500; return }
        if (-not $script:Closing) { $script:Closing = @{ Phase = 0; Lines = (New-Object System.Collections.ArrayList); Done = $false; Proc = $null; Since = [DateTime]::UtcNow; DoneAt = $null; Text = ''; OutFile = (Join-Path $webLog 'closing-defender.txt') } }
        Send-Json $ctx @{ ok = $true }
        return
    }
    if ($Path -eq '/api/kb/check') {
        $ki = Get-KbRemoteInfo
        Send-Json $ctx @{ ok = [bool]$ki.ok; error = "$($ki.error)"; current = "$($ki.current)"; latest = "$($ki.latest)"; needed = [bool]$ki.needed; date = "$($ki.date)" }
        return
    }
    if ($Path -eq '/api/kb') {
        $inst = ''; $mf = Join-Path $script:KbDir 'manifest.json'; if (Test-Path -LiteralPath $mf) { try { $inst = "$((Get-Content -LiteralPath $mf -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json).installed)" } catch { } }
        Send-Json $ctx @{ shipped = (Get-KbShippedVersion); downloaded = (Get-KbDownloadedVersion); installed = $inst; ready = ($script:KbUpdateBaseUrl -notmatch 'OWNER') }
        return
    }
    if ($Path -eq '/api/support') {
        # Links (opened by the user, nothing is downloaded or sent) to the official support pages that fit this PC
        $pc = Get-PcInfo
        $hay = "$($pc.maker) $($pc.model) $($pc.cpu) $($pc.gpu)"
        $rows = @()
        $f = Get-KbFile 'support-links.csv' $PSScriptRoot
        if (Test-Path $f) { $rows = @(Import-Csv -Path $f -Delimiter ';' -Encoding UTF8 | Where-Object { $_.Url -match '^https://' -and $hay -match $_.Match } | ForEach-Object { @{ name = "$($_.Name)"; url = "$($_.Url)"; note = "$($_.Note)" } }) }
        $finder = @()
        if (Test-Path $f) { $finder = @(Import-Csv -Path $f -Delimiter ';' -Encoding UTF8 | Where-Object { $_.Finder -match '^https://' -and $hay -match $_.Match } | ForEach-Object { @{ name = (T 'Product finder of {0}' "$($pc.maker)"); url = "$($_.Finder)" } }) }
        $deep = @()
        $serial = Get-PcSerial
        # {sku} {model} {serial} are URL-encoded; "#" of the SKU is kept (HP uses it). A row whose placeholders have no value is skipped.
        $fill = {
            param([string]$u)
            if (($u -match '\{sku\}' -and -not $pc.sku) -or ($u -match '\{serial\}' -and -not $serial) -or ($u -match '\{model\}' -and -not $pc.model)) { return '' }
            $u = $u -replace '\{sku\}', (([uri]::EscapeDataString("$($pc.sku)")) -replace '%23', '#')
            $u = $u -replace '\{serial\}', ([uri]::EscapeDataString("$serial"))
            return ($u -replace '\{model\}', ([uri]::EscapeDataString("$($pc.model)")))
        }
        # Exact product pages: support-models-user.csv (yours, first) and support-models.csv (updatable). Match by SKU (part before "#") or by exact model name.
        $skuKey = ("$($pc.sku)" -split '#')[0].Trim().ToUpper()
        foreach ($mf in @((Join-Path $PSScriptRoot 'support-models-user.csv'), (Get-KbFile 'support-models.csv' $PSScriptRoot))) {
            if (-not (Test-Path $mf)) { continue }
            foreach ($m in @(Import-Csv -Path $mf -Delimiter ';' -Encoding UTF8)) {
                if ("$($m.Url)" -notmatch '^https://') { continue }
                $hit = (($skuKey -and "$($m.Sku)".Trim().ToUpper() -eq $skuKey) -or ("$($m.Model)".Trim() -and "$($pc.model)" -eq "$($m.Model)".Trim()))
                if ($hit) { $u = & $fill "$($m.Url)"; if ($u) { $deep += @{ name = "$($m.Name)"; url = $u } } }
            }
        }
        # DeepUrl column of support-links.csv: product page of the maker built from the SKU, serial or model
        if (Test-Path $f) {
            foreach ($m in @(Import-Csv -Path $f -Delimiter ';' -Encoding UTF8 | Where-Object { $_.DeepUrl -match '^https://' -and $hay -match $_.Match })) {
                $u = & $fill "$($m.DeepUrl)"; if ($u) { $deep += @{ name = (T 'Product page of {0}' "$($pc.maker)"); url = $u } }
            }
        }
        # Motherboard: pages of the board maker (board-links.csv). Url = support/download page, DeepUrl = built from {product}, Finder = search page where the model is pasted
        $board = @{ maker = "$($pc.bmaker)"; model = "$($pc.bmodel)"; show = $false; links = @(); matched = $false }
        if ($pc.bmaker -or $pc.bmodel) {
            $sameAsPc = ($pc.laptop -and ("$($pc.model)" -like "*$($pc.bmodel)*" -or "$($pc.maker)" -like "*$(($pc.bmaker -split '\s+')[0])*"))
            $board.show = (-not $sameAsPc)
            $bf = Get-KbFile 'board-links.csv' $PSScriptRoot
            if (Test-Path $bf) {
                foreach ($b in @(Import-Csv -Path $bf -Delimiter ';' -Encoding UTF8 | Where-Object { $_.Url -match '^https://' -and $pc.bmaker -match $_.Match })) {
                    $board.matched = $true
                    $du = "$($b.DeepUrl)"
                    if ($du -match '^https://' -and $pc.bmodel) { $board.links += @{ name = (T 'Drivers of {0}' "$($pc.bmodel)"); url = ($du -replace '\{product\}', [uri]::EscapeDataString("$($pc.bmodel)")); kind = 'deep' } }
                    $board.links += @{ name = "$($b.Name)"; url = "$($b.Url)"; kind = 'page' }
                    if ("$($b.Finder)" -match '^https://') { $board.links += @{ name = (T 'Search page of {0}' "$($b.Name)"); url = "$($b.Finder)"; kind = 'finder' } }
                }
            }
        }
        Send-Json $ctx @{ board = $board; list = $rows; deep = $deep; maker = "$($pc.maker)"; model = "$($pc.model)"; finder = $finder; sku = "$($pc.sku)"; serial = "$serial" }
        return
    }
    if ($Path -eq '/api/pc') { Send-Json $ctx (Get-PcInfo); return }
    if ($Path -eq '/api/defender') {
        $o = @{ available = $false; tamper = $null; items = @() }
        $pref = $null
        try { $pref = Get-MpPreference -ErrorAction Stop } catch { }
        if ($pref) {
            $o.available = $true
            try { $o.tamper = [bool](Get-MpComputerStatus -ErrorAction Stop).IsTamperProtected } catch { }
            $s32 = Join-Path $env:SystemRoot 'System32'
            $hp = @($pref.ExclusionPath | Where-Object { $_ } | ForEach-Object { "$_".TrimEnd('\', '*').ToLower() })
            $hr = @($pref.ExclusionProcess | Where-Object { $_ } | ForEach-Object { "$_".ToLower() })
            $items = @()
            $r = "$script:Root".TrimEnd('\').ToLower()
            $okp = $false; foreach ($x in $hp) { if ($r -eq $x -or $r.StartsWith($x + '\')) { $okp = $true } }
            $items += @{ kind = 'folder'; value = "$script:Root"; ok = $okp }
            foreach ($pr in @((Join-Path $s32 'cmd.exe'), (Join-Path $s32 'WindowsPowerShell\v1.0\powershell.exe'), (Join-Path $s32 'pnputil.exe'))) {
                $items += @{ kind = 'process'; value = $pr; ok = ($hr -contains $pr.ToLower()) }
            }
            $o.items = @($items)
        }
        Send-Json $ctx $o
        return
    }
    if ($Path -eq '/api/closing') {
        $c = $script:Closing
        if (-not $c) { Send-Json $ctx @{ text = ''; done = $false }; return }
        $tx = $c.Text
        if ($c.Proc -and -not $c.Proc.HasExited) { $tx += (Read-Shared $c.OutFile) }
        $pc = @(10, 25, 40, 70, 90, 100)[[math]::Min([int]$c.Phase, 5)]
        if ($c.Done) { $pc = 100 }
        Send-Json $ctx @{ text = $tx; done = [bool]$c.Done; pct = $pc; step = [math]::Min([int]$c.Phase + 1, 5) }
        return
    }
    if ($Path -eq '/api/pins' -and $Method -eq 'GET') { Send-Json $ctx @{ list = @(Get-PinMismatch) }; return }
    if ($Path -eq '/api/pins' -and $Method -eq 'POST') {
        $pb = $null; try { $pb = (Read-Body $ctx) | ConvertFrom-Json } catch { }
        Save-Pins @(Get-Pins | Where-Object { "$($_.InstanceId)" -ne "$($pb.forget)" })
        Send-Json $ctx @{ ok = $true }; return
    }
    if ($Path -eq '/api/blocked' -and $Method -eq 'GET') { Send-Json $ctx @{ list = @(Get-BlockedForPage) }; return }
    if ($Path -eq '/api/unblock' -and $Method -eq 'POST') {
        $id = "$($body.id)"
        $known = @(Get-BlockedListReal | Where-Object { $_.Id -ieq $id })
        if ($known.Count -eq 0) { Send-Json $ctx @{ error = (T 'Not found') } 404; return }
        try { Remove-BlockedId $id; Send-Json $ctx @{ ok = $true } } catch { Send-Json $ctx @{ error = $_.Exception.Message } 500 }
        return
    }
    if ($Path -eq '/api/problem' -and $Method -eq 'GET') {
        $z = Get-ChildItem -Path $script:ReportDir -Filter 'problem-report-*.zip' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $zn = ''; if ($z) { $zn = $z.Name }
        $sz = Get-ChildItem -Path $script:ReportDir -Filter 'shareable-*.zip' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $szn = ''; if ($sz) { $szn = $sz.Name }
        $ready = ($script:IssuesUrl -notmatch 'OWNER')
        Send-Json $ctx @{ zip = $zn; szip = $szn; issuesUrl = $script:IssuesUrl; ready = $ready; folder = $script:ReportDir }
        return
    }
    if ($Path -eq '/api/openfolder' -and $Method -eq 'POST') {
        $fn = "$($body.file)"
        if ($fn -notmatch '^(problem-report|shareable)-\d{8}-\d{6}\.zip$' -or -not (Test-Path (Join-Path $script:ReportDir $fn))) { Send-Json $ctx @{ error = (T 'Not found') } 404; return }
        try { if ($IsWindows -ne $false) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + (Join-Path $script:ReportDir $fn) + '"') }; Send-Json $ctx @{ ok = $true } }
        catch { Send-Json $ctx @{ error = $_.Exception.Message } 500 }
        return
    }
    if ($Path -eq '/api/settings' -and $Method -eq 'GET') { Send-Json $ctx (Get-SettingsForPage); return }
    if ($Path -eq '/api/settings' -and $Method -eq 'POST') {
        $s = Read-Settings
        $notes = @()
        if ($null -ne $body.language) {
            $lg = "$($body.language)"
            if ((Get-AvailableLanguages) -contains $lg) { $s.language = $lg } else { Send-Json $ctx @{ error = (T 'Unknown language') } 400; return }
        }
        if ($null -ne $body.exclusions) {
            $ex = @()
            foreach ($e in @($body.exclusions)) {
                $t = ("$e").Trim()
                if (-not $t) { continue }
                try { $null = [regex]::new($t) } catch { $notes += (T 'The pattern "{0}" is not a valid expression: it is used as plain text.' $t); $t = [regex]::Escape($t) }
                $ex += $t
            }
            $s.exclusions = @($ex)
        }
        if ($null -ne $body.defender) {
            if (@('ask', 'always', 'never') -notcontains "$($body.defender)") { Send-Json $ctx @{ error = (T 'Invalid value') } 400; return }
            $s.defender = "$($body.defender)"
        }
        if ($null -ne $body.backup) {
            if (@('ask', 'full', 'drivers', 'none') -notcontains "$($body.backup)") { Send-Json $ctx @{ error = (T 'Invalid value') } 400; return }
            $s.backup = "$($body.backup)"
        }
        if ($null -ne $body.dataDir) {
            $dd = ("$($body.dataDir)").Trim()
            if ($dd) {
                try { New-Item -ItemType Directory -Force -Path $dd -ErrorAction Stop | Out-Null } catch { Send-Json $ctx @{ error = (T 'Cannot use this folder: {0}' $dd) } 400; return }
            }
            if ($dd -ne "$($s.dataDir)") { $notes += (T 'The new data folder is used the next time you start the program.') }
            $s.dataDir = $dd
        }
        if ($null -ne $body.catalogConsent) { $s.catalogConsent = ($body.catalogConsent -eq $true) }
        if ($null -ne $body.postRebootCheck) { $s.postRebootCheck = ($body.postRebootCheck -eq $true) }
        if ($null -ne $body.updateCheck) { $s.updateCheck = ($body.updateCheck -eq $true) }
        if ($null -ne $body.theme) {
            if (@('', 'light', 'dark') -notcontains "$($body.theme)") { Send-Json $ctx @{ error = (T 'Invalid value') } 400; return }
            $s.theme = "$($body.theme)"
        }
        if ($null -ne $body.inventoryAtStart) { $s.inventoryAtStart = ($body.inventoryAtStart -eq $true) }
        if ($null -ne $body.blockReinstall) { $s.blockReinstall = ($body.blockReinstall -eq $true) }
        if ($null -ne $body.firstRunDone) { $s.firstRunDone = ($body.firstRunDone -eq $true) }
        Save-Settings $s
        $script:Settings = $s
        $script:ExclusionRegex = ''
        if (@($s.exclusions).Count -gt 0) { $script:ExclusionRegex = (@($s.exclusions) -join '|') }
        if ($null -ne $body.language) { Set-UiLanguage "$($s.language)" }
        Send-Json $ctx @{ ok = $true; notes = @($notes); settings = (Get-SettingsForPage) }
        return
    }
    if ($Path -like '/api/data/*') {
        $n = $Path.Substring('/api/data/'.Length)
        if (-not $dataSets.ContainsKey($n)) { Send-Json $ctx @{ error = (T 'Unknown type') } 404; return }
        $rows = Read-CsvQuiet $dataSets[$n].File
        $out = @()
        foreach ($r in $rows) {
            $o = [ordered]@{}
            foreach ($c in $dataSets[$n].Cols) { $o[$c] = "$($r.$c)" }
            if (@('check', 'devices', 'drivers', 'bluetooth') -contains $n -and $o.Contains('Reason')) { $o['Reason'] = Convert-ReasonText $o['Reason'] }
            if ($keyOf.ContainsKey($n)) { $o['Protected'] = (Test-RowProtected $n $r) }
            $out += [pscustomobject]$o
        }
        Send-Json $ctx @{ rows = @($out) }
        return
    }
    if ($Path -eq '/api/save' -and $Method -eq 'POST') {
        $type = "$($body.type)"
        if (-not $keyOf.ContainsKey($type)) { Send-Json $ctx @{ error = (T 'Unknown type') } 400; return }
        $rows = @(Read-CsvQuiet $type)
        $map = @{}
        foreach ($r in $rows) { $map["$($r.($keyOf[$type]))"] = $r }
        $changed = 0; $prot = 0; $dropped = 0
        foreach ($s in @($body.choices)) {
            $k = "$($s.k)"; $a = "$($s.a)"
            if (-not $map.ContainsKey($k) -or ($allowedValues[$type] -notcontains $a)) { $dropped++; continue }
            $row = $map[$k]
            if ((Test-RowProtected $type $row) -and $a -ne 'KEEP') { $prot++; continue }
            if ($type -eq 'drivers' -and $a -ne 'KEEP' -and [int]$row.UsedByPresent -gt 0) { $prot++; continue }
            if ($row.Action -ne $a) { $row.Action = $a; $changed++ }
        }
        if ($changed -gt 0) { Write-CsvInPlace $rows $type }
        Send-Json $ctx @{ ok = $true; changed = $changed; protectedRows = $prot; dropped = $dropped }
        return
    }
    # Profile: export / import the user's own choices (exclusions, options, own knowledge rows, own support pages). No serial number, no data folder, no reports.
    if ($Path -eq '/api/profile' -and $Method -eq 'GET') {
        Send-Json $ctx (Get-DevvyProfile)
        return
    }
    if ($Path -eq '/api/profile' -and $Method -eq 'POST') {
        $res = Import-DevvyProfile $body.profile
        if (-not $res) { Send-Json $ctx @{ error = (T 'This is not a Devvy profile file.') } 400; return }
        $res['settings'] = (Get-SettingsForPage)
        Send-Json $ctx $res
        return
    }
    if ($Path -eq '/api/catalog/select' -and $Method -eq 'POST') {
        $cat = @(Read-CsvQuiet 'catalog')
        $out = @()
        foreach ($s in @($body.choices)) {
            $id = "$($s.updateId)"
            $r = $cat | Where-Object { $_.UpdateId -eq $id } | Select-Object -First 1
            if (-not $r) { continue }
            if ($r.FitsSystem -ne 'YES') { continue }
            $out += [pscustomobject]@{ UpdateId = $id; Device = $r.Device; ShortId = $r.ShortId; Title = $r.Title; Class = $r.Class
                                       Version = $r.Version; Date = $r.Date; RiskAccepted = [bool]$s.riskAccepted }
        }
        $selFile = Join-Path $script:ReportDir 'selection.json'
        if ($out.Count -eq 0) { Remove-Item -Path $selFile -Force -ErrorAction SilentlyContinue }
        else { Set-Content -Path $selFile -Value (ConvertTo-Json -InputObject @($out) -Depth 4) -Encoding UTF8 }
        Send-Json $ctx @{ ok = $true; chosen = $out.Count }
        return
    }
    if ($Path -eq '/api/run' -and $Method -eq 'POST') {
        Update-Job
        if ($script:Job -and $script:Job.Status -eq 'running') { Send-Json $ctx @{ error = (T 'A job is already running: wait for it to finish.') } 409; return }
        $az = "$($body.action)"
        if ($fixedActions.ContainsKey($az)) {
            if ($az -eq 'def-prepare') { $script:DefenderOn = $true }
            if ($az -eq 'postcheck') { $script:PostReboot = $false; Remove-Item -Path (Get-PostRebootFile) -Force -ErrorAction SilentlyContinue; Remove-Item -Path (Get-ContinueFile) -Force -ErrorAction SilentlyContinue }
            New-Job $kindOf[$az] $fixedActions[$az]
            Send-Json $ctx @{ ok = $true; id = $script:Job.Id }
            return
        }
        if ($az -eq 'rollback') {
            $rk = "$($body.key)"
            if ($rk -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { Send-Json $ctx @{ error = (T 'Invalid identifier') } 400; return }
            New-Job 'rollback' @(, @('26-rollback-driver.ps1', '-Key', $rk))
            Send-Json $ctx @{ ok = $true; id = $script:Job.Id }
            return
        }
        if ($az -eq 'fix') {
            $fx = "$($body.fix)"
            if ($fx -notmatch $okFixes) { Send-Json $ctx @{ error = (T 'Unknown fix') } 400; return }
            New-Job 'fix' @(, @('00-fix.ps1', '-Fix', $fx))
            Send-Json $ctx @{ ok = $true; id = $script:Job.Id }
            return
        }
        if ($az -eq 'execute') {
            $apply = ($body.apply -eq $true)
            $steps = @()
            if ($apply) {
                if ($body.confirm -ne $true) { Send-Json $ctx @{ error = (T 'Confirmation missing') } 400; return }
                $bk = "$($body.backup)"
                if ($bk -eq 'full') { $steps += , @('00-backup.ps1', '-Mode', 'Full') }
                elseif ($bk -eq 'drivers') { $steps += , @('00-backup.ps1', '-Mode', 'Drivers') }
                elseif ($bk -ne 'none' -and $bk -ne 'done') { Send-Json $ctx @{ error = (T 'Choose the backup') } 400; return }
            }
            $wanted = @($body.parts | ForEach-Object { "$_" })
            $need = @{ 'bluetooth' = 'bluetooth.csv'; 'devices' = 'devices.csv'; 'drivers' = 'drivers.csv'; 'catalog-install' = 'selection.json' }
            foreach ($w in $wanted) {
                if ($need.ContainsKey($w) -and -not (Test-Path (Join-Path $script:ReportDir $need[$w]))) {
                    if ($w -eq 'catalog-install') { Send-Json $ctx @{ error = (T 'No catalog driver is chosen: to install one go to Updates, search the catalog, choose the package and press "Save the catalog choice".') } 400 }
                    else { Send-Json $ctx @{ error = (T 'The inventory is missing: go to Start and create the full inventory first.') } 400 }
                    return
                }
            }
            foreach ($k in $execParts.Keys) {
                if ($wanted -notcontains $k) { continue }
                $a2 = @($execParts[$k])
                if ($apply) { $a2 += '-Apply' }
                if (($k -eq 'drivers' -or $k -eq 'devices') -and $apply -and $body.blockReinstall -eq $true) { $a2 += '-BlockReinstall' }
                if ($k -eq 'catalog-install' -and $apply -and ($bk -eq 'full' -or $bk -eq 'drivers')) { $a2 += '-SaveOld' }
                $steps += , $a2
            }
            if (@($steps | Where-Object { $_[0] -ne '00-backup.ps1' }).Count -eq 0) { Send-Json $ctx @{ error = (T 'You did not choose any operation.') } 400; return }
            $needCsv = @{ 'bluetooth' = 'bluetooth'; 'devices' = 'devices'; 'drivers' = 'drivers' }
            foreach ($k in $needCsv.Keys) {
                if (($wanted -contains $k) -and -not (Test-Path (Join-Path $script:ReportDir ($needCsv[$k] + '.csv')))) { Send-Json $ctx @{ error = (T 'Create the PC inventory first (Start tab).') } 409; return }
            }
            $kind = 'preview'
            if ($apply) { $kind = 'apply' }
            New-Job $kind $steps
            Send-Json $ctx @{ ok = $true; id = $script:Job.Id }
            return
        }
        Send-Json $ctx @{ error = (T 'Unknown action') } 400
        return
    }
    if ($Path -eq '/api/job') {
        Update-Job
        $j = $script:Job
        if (-not $j) { Send-Json $ctx @{ id = 0; status = 'none'; text = ''; kind = '' }; return }
        $q = $null
        if ($j.Status -eq 'running') {
            $fq = Join-Path (Join-Path $webLog ('ask-' + $j.Id)) 'question.json'
            if (Test-Path $fq) {
                try { $dq = (Read-Shared $fq) | ConvertFrom-Json; $q = @{ text = "$($dq.text)"; valid = @($dq.valid | ForEach-Object { "$_" }) } } catch { $q = $null }
            }
        }
        Send-Json $ctx @{ question = $q; id = $j.Id; kind = $j.Kind; status = $j.Status; text = (Get-JobText); exit = $j.Exit; step = ([math]::Min($j.Idx + 1, $j.Steps.Count)); steps = $j.Steps.Count; pct = (Get-JobPct); reboot = (Get-JobReboot); updated = ($j.Status -eq 'done' -and $j.Kind -eq 'selfupdate' -and $j.Text -match '##UPDATED##') }
        return
    }
    if ($Path -eq '/api/answer' -and $Method -eq 'POST') {
        $j = $script:Job
        if (-not $j -or $j.Status -ne 'running') { Send-Json $ctx @{ error = (T 'No job running') } 409; return }
        $dirQ = Join-Path $webLog ('ask-' + $j.Id)
        $fq = Join-Path $dirQ 'question.json'
        if (-not (Test-Path $fq)) { Send-Json $ctx @{ error = (T 'No question waiting') } 409; return }
        $dq = $null
        try { $dq = (Read-Shared $fq) | ConvertFrom-Json } catch { }
        $r = ("$($body.answer)").Trim().ToUpper()
        if (-not $dq -or (@($dq.valid) -notcontains $r)) { Send-Json $ctx @{ error = (T 'Invalid answer') } 400; return }
        Set-Content -Path (Join-Path $dirQ 'answer.txt') -Value $r -Encoding ASCII
        Send-Json $ctx @{ ok = $true }
        return
    }
    if ($Path -eq '/api/reboot' -and $Method -eq 'POST') {
        if ($script:Job -and $script:Job.Status -eq 'running') { Send-Json $ctx @{ error = (T 'A job is running') } 409; return }
        Send-Json $ctx @{ ok = $true }
        # what the person chose to apply: after the restart Devvy goes on with the leftovers by itself
        try {
            if ($body -and $body.cont -and @($body.cont.parts).Count -gt 0 -and $script:Settings.postRebootCheck) {
                $cp = @(@($body.cont.parts) | Where-Object { "$_" -match '^[A-Za-z0-9_-]{1,40}$' })
                $co = [ordered]@{ Time = (Get-Date).ToString('o'); parts = $cp; blockReinstall = ($body.cont.blockReinstall -eq $true); touched = $body.cont.touched }
                (ConvertTo-Json -InputObject $co -Depth 6) | Set-Content -Path (Get-ContinueFile) -Encoding UTF8
            } else { Remove-Item -Path (Get-ContinueFile) -Force -ErrorAction SilentlyContinue }
        } catch { }
        if ($script:DefenderOn) { $null = Invoke-DefenderScript 'Restore' }
        if ($script:Settings.postRebootCheck -and $IsWindows -ne $false) { $null = Register-PostRebootTask (Join-Path (Split-Path $PSScriptRoot) 'devvy.bat') }
        if ($IsWindows -ne $false) { Start-Process -FilePath 'shutdown.exe' -ArgumentList ('/r /f /t 0 /c "' + (T 'Restart to finish the driver update') + '"') }
        $script:Quit = $true
        return
    }
    if ($Path -eq '/api/cancel' -and $Method -eq 'POST') {
        $j = $script:Job
        if (-not $j -or $j.Status -ne 'running') { Send-Json $ctx @{ ok = $true }; return }
        try {
            if ($j.Proc -and -not $j.Proc.HasExited) {
                if ($IsWindows -ne $false) { $null = & taskkill.exe /PID $j.Proc.Id /T /F 2>&1 } else { Stop-Process -Id $j.Proc.Id -Force -ErrorAction SilentlyContinue }
            }
        } catch { }
        $j.Text = $j.Text + (Read-Shared $j.OutFile) + "`r`n--- " + (T 'CANCELLED by the user. Operations already completed stay valid; check the state with a new inventory.') + " ---`r`n"
        $j.Status = 'cancelled'; $j.Exit = -2
        Send-Json $ctx @{ ok = $true }
        return
    }
    if ($Path -eq '/api/exit' -and $Method -eq 'POST') {
        if (-not $script:Closing) { $script:Closing = @{ Phase = 0; Lines = (New-Object System.Collections.ArrayList); Done = $false; Proc = $null; Since = [DateTime]::UtcNow; DoneAt = $null; Text = ''; OutFile = (Join-Path $webLog 'closing-defender.txt') } }
        Send-Json $ctx @{ ok = $true }
        return
    }
    Send-Json $ctx @{ error = (T 'Not found') } 404
}

function Handle-Request($ctx) {
    $req = $ctx.Request
    $path = $req.Url.AbsolutePath
    $m = $req.HttpMethod
    if ($req.Headers['Host'] -ne ('127.0.0.1:' + $port)) { Send-Resp $ctx 403 'text/plain' 'Invalid host'; return }
    if ($path -eq '/' -and $m -eq 'GET') {
        if ($req.QueryString['t'] -ne $token) { Send-Resp $ctx 403 'text/plain' (T 'Open the page from the link shown in the PowerShell window.'); return }
        $pageHtml = $appHtml; if (@('light', 'dark') -contains "$($script:Settings.theme)") { $pageHtml = $appHtml.Replace('<html lang="en"', ('<html data-theme="' + $script:Settings.theme + '" lang="en"')) }
        Send-Resp $ctx 200 'text/html' $pageHtml ('pt=' + $token + '; Path=/; HttpOnly; SameSite=Strict')
        return
    }
    if ($path -eq '/report' -and $m -eq 'GET') {
        $c = $req.Cookies['pt']
        if (-not $c -or $c.Value -ne $token) { Send-Resp $ctx 403 'text/plain' 'Forbidden'; return }
        $f = Join-Path $script:ReportDir 'report.html'
        if (-not (Test-Path $f)) { Send-Resp $ctx 404 'text/plain' (T 'The report does not exist yet: use the Create report button.'); return }
        Send-Resp $ctx 200 'text/html' ([IO.File]::ReadAllText($f, [Text.Encoding]::UTF8))
        return
    }
    if ($path -like '/api/*') {
        if (-not (Test-Auth $ctx)) { Send-Json $ctx @{ error = 'Forbidden' } 403; return }
        try { Handle-Api $ctx $path $m }
        catch { try { Send-Json $ctx @{ error = ((T 'Internal error:') + ' ' + $_.Exception.Message) } 500 } catch { } }
        return
    }
    Send-Resp $ctx 404 'text/plain' 'Not found'
}

# ---------- Start ----------
$script:Quit = $false
$script:Closing = $null
# Closing sequence driven by the main loop, so the page can show what the engine is doing
function Step-Closing {
    $c = $script:Closing
    if (-not $c) { return }
    if ($c.Done) { if (([DateTime]::UtcNow - $c.DoneAt).TotalMilliseconds -gt 1500) { $script:Quit = $true }; return }
    switch ($c.Phase) {
        0 { $c.Text += ((T 'Closing the interface...')) + "`r`n"; $c.Phase = 1 }
        1 {
            $run = ($script:Job -and $script:Job.Status -eq 'running')
            if ($run -and ([DateTime]::UtcNow - $c.Since).TotalSeconds -lt 120) {
                if (-not $c.WaitMsg) { $c.Text += ((T 'A job is still running: waiting for it to finish...')) + "`r`n"; $c.WaitMsg = $true }
            } else { $c.Phase = 2 }
        }
        2 {
            if ($script:DefenderOn) {
                $c.Text += ((T 'Removing the temporary Defender exceptions...')) + "`r`n"
                $c.Proc = Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot '00-defender.ps1') + '" -Action Restore') -PassThru -WindowStyle Hidden -RedirectStandardOutput $c.OutFile
                $c.Phase = 3
            } else { $c.Phase = 4 }
        }
        3 { if ($c.Proc.HasExited) { $c.Text += (Read-Shared $c.OutFile); $script:DefenderOn = $false; $c.Text += ((T 'Defender exceptions removed.')) + "`r`n"; $c.Phase = 4 } }
        4 { $c.Text += ((T 'Stopping the PowerShell engine...')) + "`r`n"; $c.Phase = 5 }
        5 { $c.Text += ((T 'Done.')) + "`r`n"; $c.Done = $true; $c.DoneAt = [DateTime]::UtcNow }
    }
}
Write-Title ('  ' + (T 'DEVVY - web interface'))
Write-Host ''
Write-Info ('  ' + (T 'The page opens in the browser. If it does not, copy this address into the browser (it only works on this PC):'))
Write-Host ('  ' + $url) -ForegroundColor White
Write-Host ''
Write-Warn ('  ' + (T 'Keep this window OPEN: it is the engine. To close, use the Exit button in the page (or Ctrl+C here).'))
Write-Host ''
# Windows Defender exceptions chosen in the settings ("always"): applied at every start, removed at exit
if ("$($script:Settings.defender)" -eq 'always') {
    Write-Info ('  ' + (T 'Applying the Defender exceptions saved in the settings...'))
    $script:DefenderOn = $true
    $null = Invoke-DefenderScript 'Prepare'
}
if (-not $NoOpen) { if (-not (Open-DevvyPage $url)) { Write-Warn ('  ' + (T 'Cannot open the browser by itself: copy the address above.')) } }

try {
    $pending = $null
    while (-not $script:Quit) {
        if (-not $pending) { $pending = $listener.GetContextAsync() }
        if ($pending.Wait(300)) {
            $ctx = $pending.Result
            $pending = $null
            try { Handle-Request $ctx } catch { try { $ctx.Response.Abort() } catch { } }
        }
        Update-Job
        Step-Closing
    }
} finally {
    try { $listener.Stop(); $listener.Close() } catch { }
    if ($script:Job -and $script:Job.Status -eq 'running' -and $script:Job.Proc -and -not $script:Job.Proc.HasExited) {
        Write-Warn ('  ' + (T 'A job was still running: waiting for it before closing (it can take a minute)...'))
        $null = $script:Job.Proc.WaitForExit(120000)
    }
    if ($script:DefenderOn) {
        Write-Info ('  ' + (T 'Removing the temporary Defender exceptions...'))
        $null = Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot '00-defender.ps1') + '" -Action Restore') -Wait -PassThru -NoNewWindow
    }
}
try { Remove-Item -Path $script:InstFile -Force -ErrorAction SilentlyContinue } catch { }
try { if ($script:InstMutex) { $script:InstMutex.ReleaseMutex() } } catch { }
Write-Ok ('  ' + (T 'Done. You can close this window.'))
Stop-Log
exit 0
