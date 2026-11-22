# Shared functions and settings. Included by the other scripts with:  . "$PSScriptRoot\common.ps1"
# ASCII only in all .ps1 files (Windows PowerShell 5.1 reads UTF-8 without BOM as ANSI). Translations live in locales\<lang>.json.

$script:ScriptsDir = $PSScriptRoot
$script:Root       = Split-Path -Parent $PSScriptRoot

# ---------- Settings (data\settings.json, edited from the Settings tab of the page) ----------
$script:SettingsDir  = Join-Path $script:Root 'data'
$script:SettingsPath = Join-Path $script:SettingsDir 'settings.json'
function Get-DefaultSettings {
    @{ language = ''; exclusions = @(); defender = 'always'; backup = 'ask'; dataDir = ''; catalogConsent = $true; inventoryAtStart = $false; blockReinstall = $true; postRebootCheck = $true; updateCheck = $true; theme = ''; firstRunDone = $false; defenderApplied = $false }
}
# ---------- Open the Devvy page in the browser, whatever the browser profiles are ----------
# Chromium browsers (Chrome, Edge, Brave, Vivaldi) show a profile picker (or open nothing) when several profiles exist: the page is
# opened with the profile used last (read from "Local State"). Other browsers and any failure fall back to the plain address.
function Get-DefaultBrowserExe {
    try {
        $prog = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice' -ErrorAction Stop).ProgId
        if (-not $prog) { return $null }
        $cmd = (Get-ItemProperty -Path ('Registry::HKEY_CLASSES_ROOT\' + $prog + '\shell\open\command') -ErrorAction Stop).'(default)'
        if (-not $cmd) { return $null }
        $cmd = $cmd.Trim()
        if ($cmd.StartsWith('"')) { $e = $cmd.IndexOf('"', 1); if ($e -gt 1) { return $cmd.Substring(1, $e - 1) } }
        else { $m = [regex]::Match($cmd, '^\S+\.exe', 'IgnoreCase'); if ($m.Success) { return $m.Value } }
    } catch { }
    return $null
}
function Get-ChromiumProfile {
    param([string]$UserDataDir)
    $name = 'Default'
    try {
        $ls = Join-Path $UserDataDir 'Local State'
        if (Test-Path -LiteralPath $ls) {
            $j = Get-Content -LiteralPath $ls -Raw -Encoding UTF8 | ConvertFrom-Json
            $last = "$($j.profile.last_used)"
            if (-not $last) { $act = @($j.profile.last_active_profiles | ForEach-Object { $_ }); if ($act.Count -gt 0) { $last = "$($act[0])" } }
            if ($last -and $last -match '^[A-Za-z0-9 _.-]{1,60}$' -and (Test-Path -LiteralPath (Join-Path $UserDataDir $last))) { $name = $last }
        }
    } catch { }
    return $name
}
function Open-DevvyPage {
    param([string]$Url)
    if ($IsWindows -eq $false) { return $false }
    $la = $env:LOCALAPPDATA
    $known = @{
        'chrome.exe'  = (Join-Path $la 'Google\Chrome\User Data')
        'msedge.exe'  = (Join-Path $la 'Microsoft\Edge\User Data')
        'brave.exe'   = (Join-Path $la 'BraveSoftware\Brave-Browser\User Data')
        'vivaldi.exe' = (Join-Path $la 'Vivaldi\User Data')
    }
    $cands = New-Object System.Collections.Generic.List[string]
    $def = Get-DefaultBrowserExe
    if ($def -and (Test-Path -LiteralPath $def)) { $cands.Add($def) }
    foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $la)) {
        if (-not $pf) { continue }
        foreach ($rel in @('Google\Chrome\Application\chrome.exe', 'Microsoft\Edge\Application\msedge.exe')) {
            $c = Join-Path $pf $rel; if ((Test-Path -LiteralPath $c) -and -not $cands.Contains($c)) { $cands.Add($c) }
        }
    }
    foreach ($exe in $cands) {
        $leaf = (Split-Path $exe -Leaf).ToLower()
        try {
            if ($known.ContainsKey($leaf)) {
                $prof = Get-ChromiumProfile $known[$leaf]
                Start-Process -FilePath $exe -ArgumentList ('--profile-directory="' + $prof + '" "' + $Url + '"')
                return $true
            }
            if ($leaf -eq 'firefox.exe') { Start-Process -FilePath $exe -ArgumentList ('-new-tab "' + $Url + '"'); return $true }
        } catch { }
    }
    try { Start-Process -FilePath $Url; return $true } catch { return $false }
}

function Read-Settings {
    $s = Get-DefaultSettings
    if (Test-Path $script:SettingsPath) {
        try {
            $j = Get-Content -Path $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { if ($s.ContainsKey($p.Name)) { $s[$p.Name] = $p.Value } }
        } catch { }
    }
    $s.exclusions = @($s.exclusions | ForEach-Object { "$_" } | Where-Object { $_ })
    return $s
}
function Save-Settings($S) {
    New-Item -ItemType Directory -Force -Path $script:SettingsDir | Out-Null
    $S.exclusions = @($S.exclusions)
    ConvertTo-Json -InputObject $S -Depth 4 | Set-Content -Path $script:SettingsPath -Encoding UTF8
}
$script:Settings = Read-Settings

# ---------- Data folders (reports, logs, backups): next to the program unless the user chose another place ----------
$script:DataRoot = $script:SettingsDir
if ($script:Settings.dataDir -and (Test-Path $script:Settings.dataDir)) { $script:DataRoot = [string]$script:Settings.dataDir }
$script:ReportDir   = Join-Path $script:DataRoot 'reports'
$script:LogDir      = Join-Path $script:DataRoot 'logs'
$script:BackupRoot  = Join-Path $script:DataRoot 'backups'
$script:OutcomesDir = Join-Path $script:ReportDir 'outcomes'
foreach ($d in @($script:ReportDir, $script:LogDir, $script:BackupRoot, $script:OutcomesDir)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}
$script:Outcomes = New-Object System.Collections.Generic.List[object]

# ---------- Language: English is the source text; other languages are translations in locales\<code>.json ----------
$script:LocalesDir = Join-Path $script:ScriptsDir 'locales'
function Get-AvailableLanguages {
    $l = @('en')
    if (Test-Path $script:LocalesDir) {
        foreach ($f in @(Get-ChildItem -Path $script:LocalesDir -Filter '*.json' -ErrorAction SilentlyContinue)) { $l += $f.BaseName }
    }
    return @($l | Select-Object -Unique)
}
function Get-DetectedLanguage {
    $c = 'en'
    try { $c = (Get-UICulture).TwoLetterISOLanguageName } catch { }
    if ((Get-AvailableLanguages) -contains $c) { return $c }
    return 'en'
}
$script:Lang = 'en'
if ($env:DEVVY_LANG) { $script:Lang = $env:DEVVY_LANG }
elseif ($script:Settings.language) { $script:Lang = [string]$script:Settings.language }
else { $script:Lang = Get-DetectedLanguage }
if ((Get-AvailableLanguages) -notcontains $script:Lang) { $script:Lang = 'en' }
$script:Strings = @{}
if ($script:Lang -ne 'en') {
    $lf = Join-Path $script:LocalesDir ($script:Lang + '.json')
    if (Test-Path $lf) {
        try {
            $j = Get-Content -Path $lf -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { $script:Strings[$p.Name] = [string]$p.Value }
        } catch { }
    }
}
# Child processes started by the web server write UTF-8 so that translated text with accents arrives intact
if ($env:DEVVY_WEB -eq '1') { try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { } }

# T 'English text {0}' $value  -> translated text (the English text is the key); placeholders are {0}, {1}...
# English text without translation: values written to CSV files stay language neutral (the screen translates them with Convert-ReasonText)
function TE {
    param([string]$Text)
    if ($args.Count -gt 0) { return [string]::Format([Globalization.CultureInfo]::InvariantCulture, $Text, [object[]]$args) }
    return $Text
}
$script:ReasonTemplates = @(
    'Problem: {0}', 'No driver installed', 'Generic Microsoft driver: the manufacturer probably provides a specific one', 'Generic driver (informational)',
    'Old driver: {0} years (it is the PC manufacturer driver: if you have no problems leave it; to update it use the manufacturer site or support app)',
    'Old driver: {0} years', 'Update available on Windows Update', 'Windows Update offers a driver (current date unknown)',
    'Excluded by you in the settings (pattern: {0})', 'Ghost: virtual or system component, safe to remove', 'Ghost: physical hardware not connected (remove it only if you no longer use it)',
    'Orphaned component: remove it from the drivers list (see drivers.csv)', 'Present', 'Driver included with Windows', 'In use by {0} connected device(s)',
    'Orphaned component: {0} (app not installed)', 'Not in use: {0}', 'Older version of the same package', 'Used only by devices that are not connected',
    'Extension driver: it extends another driver (0 users is normal)', 'Third-party driver not in use: to be evaluated', 'Bluetooth pairing')
function Convert-ReasonText {
    param([string]$Text)
    if (-not $Text) { return $Text }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($part in ($Text -split ' \| ')) {
        $res = $part
        foreach ($tpl in $script:ReasonTemplates) {
            $rx = '^' + ([regex]::Escape($tpl) -replace '\\\{0\}', '(.+?)') + '$'
            $m = [regex]::Match($part, $rx)
            if ($m.Success) { $a = @(); for ($i = 1; $i -lt $m.Groups.Count; $i++) { $a += $m.Groups[$i].Value }; $res = T $tpl @a; break }
        }
        $out.Add($res)
    }
    return ($out -join ' | ')
}

function T {
    param([string]$Text)
    $s = $Text
    if ($script:Strings.ContainsKey($Text)) { $s = $script:Strings[$Text] }
    if ($args.Count -gt 0) { $s = [string]::Format($s, [object[]]$args) }
    return $s
}

# ---------- Exclusions (optional): things the user never wants removed, from the settings ----------
$script:ExclusionRegex = ''
if (@($script:Settings.exclusions).Count -gt 0) { $script:ExclusionRegex = (@($script:Settings.exclusions) -join '|') }

# Which of the user's exclusion patterns matches (to tell the user WHY something is excluded)
function Get-ExclusionMatch([string]$Text) {
    foreach ($e in @($script:Settings.exclusions)) {
        try { if ($Text -match $e) { return "$e" } } catch { }
    }
    return ''
}
function Test-Excluded {
    param([string]$Text, [string]$Class)
    if ($script:ExclusionRegex -and $Text) {
        try { if ($Text -match $script:ExclusionRegex) { return $true } } catch { }
    }
    return $false
}

# ---------- Administrator, log, pnputil ----------
function Assert-Admin {
    $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host ''
        Write-Host (T 'ERROR: this script needs administrator rights.') -ForegroundColor Red
        Write-Host (' ' + (T 'WHAT TO DO: close this window and start devvy.bat with a double click (it asks for the rights by itself).') + ' ') -ForegroundColor Black -BackgroundColor Yellow
        exit 1
    }
}

function Start-Log([string]$Name) {
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:LogPath = Join-Path $script:LogDir ("{0}-{1}.txt" -f $Name, $ts)
    Start-Transcript -Path $script:LogPath | Out-Null
}

function Stop-Log {
    try { Stop-Transcript | Out-Null } catch { }
    Write-Host ((T 'Log:') + ' ' + $script:LogPath)
}

# Device by exact instance ID. Get-PnpDevice -InstanceId treats [ ] * ? as wildcards, and some IDs (Apple recovery mode:
# SRNM:[serial]) contain them: the device would look "already removed" while it is still there.
function Get-PnpExact([string]$InstanceId) {
    if (-not $InstanceId) { return $null }
    $esc = [Management.Automation.WildcardPattern]::Escape($InstanceId)
    $d = @(Get-PnpDevice -InstanceId $esc -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -ieq $InstanceId })
    if ($d.Count -eq 0) { $d = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -ieq $InstanceId }) }
    if ($d.Count -gt 0) { return $d[0] }
    return $null
}

function Invoke-Pnp([string[]]$PnpArgs) {
    $out = & pnputil.exe @PnpArgs 2>&1 | Out-String
    $code = [int]$LASTEXITCODE
    $ok = ($code -eq 0 -or $code -eq 3010)
    # pnputil scrive nella codepage di Windows ma PowerShell la legge in quella della console: gli accenti diventano simboli.
    $txt = ($out.Trim() -replace '[^\x00-\x7F]', '?')
    [pscustomobject]@{ Ok = $ok; Code = $code; Output = $txt }
}

# ---------- Outcomes of the operations ----------
# Kind decides the color: ok (green), warn (yellow), err (red), preview (cyan)
function Add-Outcome([string]$What, [string]$Id, [string]$Outcome, [string]$Kind = 'ok') {
    $script:Outcomes.Add([pscustomobject]@{ What = $What; Id = $Id; Outcome = $Outcome; Kind = $Kind })
    Write-Host ("  {0} -> " -f $What) -NoNewline
    Write-Host $Outcome -ForegroundColor (Get-OutcomeColor $Kind)
}

function Save-Outcomes([string]$Name) {
    if ($script:Outcomes.Count -eq 0) { return }
    $path = Join-Path $script:OutcomesDir ("{0}-{1}.csv" -f $Name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $script:Outcomes | Export-Csv -Path $path -Delimiter ';' -NoTypeInformation -Encoding UTF8
    Write-Host ''
    Write-Host ((T 'Full list saved in:') + ' ' + $path) -ForegroundColor Gray
    Write-Host (T 'Summary:') -ForegroundColor Cyan
    $script:Outcomes | Group-Object Outcome | Sort-Object Name | ForEach-Object {
        $k = ($_.Group | Select-Object -First 1).Kind
        Write-Host ("  {0,4}  {1}" -f $_.Count, $_.Name) -ForegroundColor (Get-OutcomeColor $k)
    }
}

# ---------- CSV di report (separatore ; per Excel italiano) ----------
function Save-ReportCsv {
    param($Rows, [string]$Name)
    $path = Join-Path $script:ReportDir ($Name + '.csv')
    if (Test-Path $path) {
        $hist = Join-Path $script:ReportDir 'history'
        New-Item -ItemType Directory -Force -Path $hist | Out-Null
        $stamp = (Get-Item $path).LastWriteTime.ToString('yyyyMMdd-HHmmss')
        Move-Item -Path $path -Destination (Join-Path $hist ("{0}-{1}.csv" -f $Name, $stamp)) -Force
    }
    $Rows | Export-Csv -Path $path -Delimiter ';' -NoTypeInformation -Encoding UTF8
    return $path
}

function Read-ReportCsv([string]$Name) {
    $path = Join-Path $script:ReportDir ($Name + '.csv')
    if (-not (Test-Path $path)) {
        Write-Host ''
        Write-Host ((T 'ERROR: the file is missing:') + ' ' + $path) -ForegroundColor Red
        Write-Host (' ' + (T 'WHAT TO DO: run the inventory first (Start tab), then repeat this operation.') + ' ') -ForegroundColor Black -BackgroundColor Yellow
        return
    }
    $first = Get-Content -Path $path -TotalCount 1
    $delim = ';'
    if ($first -and ($first.Split(';').Count -lt 2) -and ($first.Split(',').Count -gt 1)) { $delim = ',' }
    Import-Csv -Path $path -Delimiter $delim
}

function Format-Date($v) {
    if ($null -eq $v) { return '' }
    if ($v -is [datetime]) { return $v.ToString('yyyy-MM-dd') }
    return "$v"
}

# ---------- Driver associato a ogni dispositivo (anche fantasmi) ----------
function Get-DeviceDriverMap {
    $keys = @('DEVPKEY_Device_DriverInfPath', 'DEVPKEY_Device_DriverProvider', 'DEVPKEY_Device_DriverVersion',
              'DEVPKEY_Device_DriverDate', 'DEVPKEY_Device_LastArrivalDate', 'DEVPKEY_Device_InstallDate')
    # Reading the properties of every device is the slow part: the answer is kept while the driver set, the list of devices
    # and which of them are connected stay the same (data\cache\device-map.xml).
    $devs = @(Get-PnpDevice -ErrorAction SilentlyContinue)
    $sig = Get-DriverSig
    $cf = Join-Path $script:DataRoot 'cache\device-map.xml'
    if ($sig -and $devs.Count -gt 0) {
        try {
            $sig = $sig + '|' + [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes((($devs | ForEach-Object { "$($_.InstanceId):$($_.Present)" } | Sort-Object) -join ';')))).Replace('-', '')
            if (Test-Path -LiteralPath $cf) {
                $c = Import-Clixml -LiteralPath $cf -ErrorAction Stop
                if ($c.Sig -eq $sig -and $c.Map -and $c.Map.Count -gt 0) { $m2 = @{}; foreach ($k in @($c.Map.Keys)) { $m2[[string]$k] = $c.Map[$k] }; return $m2 }
            }
        } catch { }
    }
    $map = @{}
    $devs | Get-PnpDeviceProperty -KeyName $keys -ErrorAction SilentlyContinue |
        ForEach-Object {
            if (-not $map.ContainsKey($_.InstanceId)) { $map[$_.InstanceId] = @{} }
            $map[$_.InstanceId][$_.KeyName] = $_.Data
        }
    if ($sig -and $map.Count -gt 0) {
        try { New-Item -ItemType Directory -Force -Path (Split-Path $cf) | Out-Null; Export-Clixml -LiteralPath $cf -InputObject ([pscustomobject]@{ Sig = $sig; Map = $map }) -Depth 4 } catch { }
    }
    return $map
}

# Proprieta PnP arbitrarie per tutti i dispositivi (o solo i presenti): hashtable InstanceId -> (KeyName -> Data)
function Get-DevicePropertyMap {
    param([string[]]$Keys, [bool]$PresentOnly = $false)
    $map = @{}
    if ($PresentOnly) { $src = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue }
    else { $src = Get-PnpDevice -ErrorAction SilentlyContinue }
    $src | Get-PnpDeviceProperty -KeyName $Keys -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not $map.ContainsKey($_.InstanceId)) { $map[$_.InstanceId] = @{} }
        $map[$_.InstanceId][$_.KeyName] = $_.Data
    }
    return $map
}

# Quanti dispositivi presenti / fantasma usano ciascun pacchetto driver (chiave: nome .inf in minuscolo)
function Get-DriverUsage {
    $map = Get-DeviceDriverMap
    $present = @{}
    $ghost = @{}
    foreach ($d in @(Get-PnpDevice -ErrorAction SilentlyContinue)) {
        $m = $map[$d.InstanceId]
        if (-not $m) { continue }
        $inf = $m['DEVPKEY_Device_DriverInfPath']
        if (-not $inf) { continue }
        $k = "$inf".ToLower()
        if ($d.Present) { $present[$k] = 1 + [int]$present[$k] } else { $ghost[$k] = 1 + [int]$ghost[$k] }
    }
    return @{ Present = $present; Ghost = $ghost }
}

# ---------- Installed driver packages (Get-WindowsDriver reads every package: 20-30 s, so the answer is kept) ----------
# The cache is valid while Windows (build + update number) and the set of oem*.inf files are the same; any install or removal changes
# that set, so the list is read again. Never used when the INF folder cannot be read.
function Get-DriverSig {
    $sig = ''
    try {
        $inf = Join-Path $env:SystemRoot 'INF'
        if ($env:SystemRoot -and (Test-Path -LiteralPath $inf)) {
            $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
            $oem = @(Get-ChildItem -LiteralPath $inf -Filter 'oem*.inf' -File -ErrorAction Stop | Sort-Object Name | ForEach-Object { $_.Name + ':' + $_.Length + ':' + $_.LastWriteTimeUtc.Ticks })
            $sig = "$($cv.CurrentBuild).$($cv.UBR)|" + ($oem -join ';')
            $sig = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($sig))).Replace('-', '')
        }
    } catch { $sig = '' }
    return $sig
}
function Get-DriverPackages {
    $sig = Get-DriverSig
    $cf = Join-Path $script:DataRoot 'cache\driver-packages.xml'
    if ($sig) {
        try {
            if (Test-Path -LiteralPath $cf) {
                $c = Import-Clixml -LiteralPath $cf -ErrorAction Stop
                if ($c.Sig -eq $sig -and @($c.List).Count -gt 0) { return @($c.List) }
            }
        } catch { }
    }
    $list = @(Get-WindowsDriver -Online -All)
    if ($sig -and $list.Count -gt 0) {
        try { New-Item -ItemType Directory -Force -Path (Split-Path $cf) | Out-Null; Export-Clixml -LiteralPath $cf -InputObject ([pscustomobject]@{ Sig = $sig; List = $list }) -Depth 3 } catch { }
    }
    return $list
}

function ConvertTo-Ver([string]$s) {
    try { return [version]$s } catch { return [version]'0.0.0.0' }
}

# ---------- Knowledge-base updates (optional, only when the user presses the button: 28-update-knowledge.ps1) ----------
# Downloaded files live in <data>\kb and are used only when their version is newer than the one shipped in scripts\kb-version.txt.
$script:KbUpdateBaseUrl = 'https://raw.githubusercontent.com/zuwann/devvy/main/kb/'
$script:KbDir = Join-Path $script:DataRoot 'kb'
function Get-KbShippedVersion { $f = Join-Path $script:ScriptsDir 'kb-version.txt'; if (-not (Test-Path -LiteralPath $f)) { return [int64]0 }; try { return [int64]((Get-Content -LiteralPath $f -ErrorAction Stop | Select-Object -First 1).Trim()) } catch { return [int64]0 } }
function Get-KbDownloadedVersion {
    # no file = no downloaded update (checked first: a missing file made Windows PowerShell print a 'fatal error' line even inside try/catch)
    $f = Join-Path $script:KbDir 'manifest.json'
    if (-not (Test-Path -LiteralPath $f)) { return [int64]0 }
    try { return [int64]((Get-Content -LiteralPath $f -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json).version) } catch { return [int64]0 }
}
# Path of a knowledge file: the downloaded one when it is newer than the shipped one, otherwise the shipped one.
function Get-KbFile([string]$Name, [string]$Dir) {
    $dl = Join-Path $script:KbDir $Name
    if ((Test-Path $dl) -and ((Get-KbDownloadedVersion) -gt (Get-KbShippedVersion))) { return $dl }
    return (Join-Path $Dir $Name)
}

# ---------- Base di conoscenza: cosa sono i componenti e cosa conviene fare ----------
# knowledge.csv = base ufficiale; knowledge-user.csv = voci locali dell'utente (vincono a parita di Id
# e sono sempre provate per prime; gli aggiornamenti della base ufficiale non le toccano).
$script:Kb = @()
$kbOfficial = @()
$kbUser = @()
$script:KbPath = Get-KbFile 'knowledge.csv' $script:ScriptsDir
$script:KbUserPath = Join-Path $script:ScriptsDir 'knowledge-user.csv'
if (Test-Path $script:KbPath) { $kbOfficial = @(Import-Csv -Path $script:KbPath -Delimiter ';' -Encoding UTF8) }
if (Test-Path $script:KbUserPath) { $kbUser = @(Import-Csv -Path $script:KbUserPath -Delimiter ';' -Encoding UTF8 | Where-Object { $_.Match }) }
$kbUserIds = @($kbUser | ForEach-Object { $_.Id })
$script:Kb = @($kbUser) + @($kbOfficial | Where-Object { $kbUserIds -notcontains $_.Id })
# Translated texts of the knowledge base: locales\knowledge.<lang>.csv (Id;Name;What;IfNeeded;IfNotNeeded) overrides the English ones
if ($script:Lang -ne 'en') {
    $kbTr = Get-KbFile ('knowledge.' + $script:Lang + '.csv') $script:LocalesDir
    if (Test-Path $kbTr) {
        $tr = @{}
        foreach ($r in @(Import-Csv -Path $kbTr -Delimiter ';' -Encoding UTF8)) { $tr[$r.Id] = $r }
        foreach ($e in $script:Kb) {
            if ($tr.ContainsKey($e.Id)) {
                foreach ($f in @('Name', 'What', 'IfNeeded', 'IfNotNeeded')) { if ($tr[$e.Id].$f) { $e.$f = $tr[$e.Id].$f } }
            }
        }
    }
}

$script:AppsCache = $null
function Get-InstalledAppNames {
    if ($null -ne $script:AppsCache) { return $script:AppsCache }
    $names = New-Object System.Collections.Generic.List[string]
    $paths = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
               'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
               'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
    foreach ($p in $paths) {
        Get-ItemProperty -Path $p -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.DisplayName) { $names.Add([string]$_.DisplayName) }
        }
    }
    try { Get-AppxPackage -ErrorAction SilentlyContinue | ForEach-Object { $names.Add([string]$_.Name) } } catch { }
    $script:AppsCache = @($names | Sort-Object -Unique)
    return $script:AppsCache
}

# Cerca la prima voce della base di conoscenza che corrisponde al testo (nomi, inf, produttore, classe, id).
function Get-Advice {
    param([string]$Text)
    foreach ($e in $script:Kb) {
        if (-not $e.Match) { continue }
        if ($Text -notmatch $e.Match) { continue }
        if ($e.Exclude -and ($Text -match $e.Exclude)) { continue }
        $haApp = [bool]$e.AppRegex
        $appPresente = $false
        if ($haApp) {
            $apps = @(Get-InstalledAppNames)
            $appPresente = [bool]($apps | Where-Object { $_ -match $e.AppRegex } | Select-Object -First 1)
        }
        return [pscustomobject]@{
            Id = $e.Id; Name = $e.Name; What = $e.What; IfNeeded = $e.IfNeeded; IfNotNeeded = $e.IfNotNeeded
            Risk = $e.Risk; Depends = $e.Depends; Auto = $e.Auto
            HasApp = $haApp; AppInstalled = $appPresente; IsOrphan = ($haApp -and -not $appPresente)
        }
    }
    return $null
}

# Generic advice for third-party drivers that are NOT in the knowledge base: built from the driver class and from
# how many connected devices use it. Works offline, no web search.
function Get-ClassAdvice {
    param([string]$Class, [int]$UsedByPresent = 0, [int]$UsedByGhost = 0)
    $what = switch -Regex ($Class) {
        '^(Printer|PrintQueue)$' { T 'Printer driver.'; break }
        '^(Image|Camera)$' { T 'Driver of a camera, scanner or webcam.'; break }
        '^(MEDIA|AudioEndpoint|SoftwareComponent)$' { T 'Audio or media driver.'; break }
        '^Net' { T 'Network driver (cable, Wi-Fi or virtual).'; break }
        '^Bluetooth$' { T 'Bluetooth driver.'; break }
        '^(USB|USBDevice|HIDClass|Ports|WPD)$' { T 'Driver of a device connected by USB or a port.'; break }
        '^(SCSIAdapter|HDC|DiskDrive|Volume|CDROM)$' { T 'Storage driver (disks, virtual disks, adapters).'; break }
        '^(Display|Monitor)$' { T 'Graphics or screen driver.'; break }
        '^Extension$' { T 'Extension of another driver: it adds settings or features to it.'; break }
        '^(System|Firmware|Processor)$' { T 'Driver of a system component (motherboard, firmware, processor).'; break }
        default { T 'Third-party driver.' }
    }
    if ($UsedByPresent -gt 0) { return ($what + ' ' + (T 'It is in use by a connected device: keep it.')) }
    if ($Class -eq 'Extension') { return ($what + ' ' + (T 'Having no users is normal: keep it.')) }
    if ($Class -match '^(System|Firmware|Processor|Display|HDC|SCSIAdapter)$') { return ($what + ' ' + (T 'Not in use right now, but it may belong to a component the PC needs: keep it unless you know what it is.')) }
    if ($UsedByGhost -gt 0) { return ($what + ' ' + (T 'Only devices that are not connected use it: if you no longer own that hardware you can remove it, Windows adds it back when needed.')) }
    return ($what + ' ' + (T 'No device uses it now: if you no longer own that hardware you can remove it, Windows adds it back when needed. Use Identify and Search the web if unsure.'))
}

# ---------- Optional: stop Windows from installing again a removed driver (policy "Prevent installation of devices") ----------
# HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstallation\Restrictions: DenyDeviceIDs=1, DenyDeviceIDsRetroactive=0 (devices already
# installed are not touched) and the hardware IDs as values 1,2,3... of the subkey DenyDeviceIDs. A device with a blocked ID cannot be installed
# again by ANY driver until the ID is unblocked. Devvy keeps its own list (blocked-ids.json) to show and undo what it added.
$script:DenyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstallation\Restrictions'
function Get-BlockedList {
    $f = Join-Path $script:DataRoot 'blocked-ids.json'
    if (-not (Test-Path $f)) { return @() }
    $list = @()
    try { $list = @(Get-Content -Path $f -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ }) } catch { $list = @() }
    return $list
}
# The Windows policy key is the truth: entries only in blocked-ids.json (not blocked any more) are dropped, ids blocked in the key but
# unknown to the file (data folder deleted, other tool) are listed too.
function Get-BlockedListReal {
    $list = @(Get-BlockedList)
    if ($IsWindows -eq $false) { return $list }
    $sub = Join-Path $script:DenyKey 'DenyDeviceIDs'
    $read = {
        $have = $null
        try { $have = Get-ItemProperty -Path $sub -ErrorAction Stop } catch { }
        $h = @{}
        if ($have) { foreach ($p in @($have.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })) { $h["$($p.Value)".ToUpper()] = "$($p.Name)" } }
        return $h
    }
    $reg = & $read
    # Ids Devvy blocked that Windows no longer has (policy refresh, other tool): they are applied again, so the block really works
    $lost = @($list | Where-Object { "$($_.Id)" -notmatch '^WU:' -and -not $reg.ContainsKey("$($_.Id)".ToUpper()) })
    if ($lost.Count -gt 0) {
        try { foreach ($l in $lost) { $null = Add-BlockedId "$($l.Id)" "$($l.Driver)" "$($l.Inf)" "$($l.Provider)" $l } } catch { }
        $reg = & $read
        $list = @(Get-BlockedList)
    }
    $out = @($list | Where-Object { "$($_.Id)" -match '^WU:' -or $reg.ContainsKey("$($_.Id)".ToUpper()) })
    foreach ($k in $reg.Keys) {
        if (-not ($out | Where-Object { "$($_.Id)".ToUpper() -eq $k })) {
            $out += [pscustomobject]@{ Id = $k; Driver = (T 'Blocked earlier'); Inf = ''; Provider = ''; Date = ''; RegName = $reg[$k] }
        }
    }
    return $out
}
# Windows Update delivers removed extension drivers again. The supported way to stop it is to hide the driver update.
# Hidden updates are kept in the same list as the blocked devices (id "WU:<update id>") so they can be undone in Device management.
# Extension drivers removed by Devvy are remembered in data\wu-hide.json until a matching Windows Update driver has been hidden.
# Pending list of Windows Update hides. PowerShell 5.1 quirk: ConvertFrom-Json returns a JSON array as ONE object, and writing it back nests it
# ("value"/"Count"): so the list is always rebuilt from plain objects with an InfName, and a nested/corrupted file is flattened (0.10.115).
$script:WuKeep = @('InfName', 'Provider', 'Class', 'Version', 'Date', 'Removed', 'Driver', 'What', 'Category', 'KbId', 'InfDescription', 'InfPath', 'Reason', 'Advice', 'HardwareIds')
function ConvertTo-WuEntry($i) {
    $h = [ordered]@{}
    foreach ($n in $script:WuKeep) { $v = ''; if ($i.PSObject.Properties[$n]) { $v = "$($i.$n)" }; $h[$n] = $v }
    return [pscustomobject]$h
}
function ConvertTo-WuFlat($X) {
    $o = @()
    foreach ($i in @($X)) {
        if ($null -eq $i) { continue }
        if ($i -is [string]) { continue }
        if ($i.PSObject.Properties['InfName'] -and "$($i.InfName)") { $o += ConvertTo-WuEntry $i }
        elseif ($i.PSObject.Properties['value']) { $o += @(ConvertTo-WuFlat $i.value) }
        elseif ($i -is [System.Collections.IEnumerable]) { foreach ($j in $i) { $o += @(ConvertTo-WuFlat $j) } }
    }
    return @($o)
}
function Get-WuHideList { $f = Join-Path $script:DataRoot 'wu-hide.json'; if (Test-Path $f) { try { $j = Get-Content $f -Raw | ConvertFrom-Json; return @(ConvertTo-WuFlat $j) } catch { } }; return @() }
function Save-WuHideList($L) {
    $f = Join-Path $script:DataRoot 'wu-hide.json'
    $parts = @(ConvertTo-WuFlat $L | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 3 })
    $txt = '[' + ($parts -join ',') + ']'
    Set-Content -Path $f -Value $txt -Encoding UTF8
}
function Add-WuHidePending($Pkgs) {
    $l = @(Get-WuHideList)
    foreach ($pk in $Pkgs) {
        if ($l | Where-Object { "$($_.InfName)" -ieq "$($pk.InfName)" -and "$($_.Version)" -eq "$($pk.Version)" }) { continue }
        $e = ConvertTo-WuEntry $pk
        $e.Removed = (Get-Date -Format 'yyyy-MM-dd')
        $l += $e
    }
    Save-WuHideList $l
}
# Does a pending Windows Update driver correspond to a driver Devvy removed? Same provider and class, and the same version, or the same
# date, or the inf name (without ext) inside the update text. Without a clear sign nothing is hidden (it could be a driver you need).
function Test-WuMatch($u, $pk) {
    $prov = "$($u.DriverProvider)"; $cls = "$($u.DriverClass)"
    if (-not $prov -or -not "$($pk.Provider)") { return $false }
    if (-not ($prov -ieq "$($pk.Provider)" -or $prov -like "*$($pk.Provider)*" -or "$($pk.Provider)" -like "*$prov*")) { return $false }
    if ($cls -ine "$($pk.Class)") { return $false }
    if ("$($u.DriverVerVersion)" -eq "$($pk.Version)") { return $true }
    try { if ($pk.Date -and (Format-Date $u.DriverVerDate) -eq "$($pk.Date)") { return $true } } catch { }
    $base = ("$($pk.InfName)" -replace '(?i)\.inf$', '' -replace '(?i)(extension|ext)$', '' -replace '[_\-]+$', '')
    if ($base.Length -ge 5) {
        $txt = "$($u.Title) $($u.DriverModel) $($u.DriverHardwareID)"
        if ($txt -like "*$base*") { return $true }
    }
    return $false
}
# Searches the pending driver updates (online, a few tries: Windows Update needs a moment to notice a removed driver) and hides the matching ones.
function Hide-WuDriverUpdates($Pkgs, [int]$Tries = 3, [int]$WaitSeconds = 20) {
    $res = @{}
    $sess = New-Object -ComObject Microsoft.Update.Session
    $seen = @()
    for ($t = 1; $t -le $Tries; $t++) {
        $srch = $sess.CreateUpdateSearcher()
        try { $srch.Online = $true } catch { }
        $found = $srch.Search("IsInstalled=0 and IsHidden=0 and Type='Driver'")
        $seen = @(); foreach ($u in $found.Updates) { $seen += $u }
        foreach ($pk in $Pkgs) {
            $key = "$($pk.InfName)|$($pk.Version)"
            if ($res.ContainsKey($key) -and $res[$key].Hidden) { continue }
            $hit = $null
            foreach ($u in $seen) { if (Test-WuMatch $u $pk) { $hit = $u; break } }
            if (-not $hit) { $res[$key] = [pscustomobject]@{ Pkg = $pk; Hidden = $false; Title = '' }; continue }
            $hit.IsHidden = $true
            $uid = "$($hit.Identity.UpdateID)"
            $list = @(Get-BlockedList | Where-Object { $_.Id -ine "WU:$uid" })
            $ent = [ordered]@{ Id = "WU:$uid"; Driver = "$($hit.Title)"; Inf = "$($pk.InfName)"; Provider = "$($pk.Provider)"; Date = (Get-Date -Format 'yyyy-MM-dd'); RegName = '' }
            foreach ($n in (Get-BlockExtraNames)) { if ($pk.PSObject.Properties[$n] -and "$($pk.$n)" -and -not $ent.Contains($n) -and $n -notin @('InfName', 'Provider', 'Driver', 'Date')) { $ent[$n] = "$($pk.$n)" } }
            $vd = ''; try { $vd = Format-Date $hit.DriverVerDate } catch { }
            if ($vd) { $ent['DriverDate'] = $vd } elseif ($pk.PSObject.Properties['InfName'] -and "$($pk.Date)") { $ent['DriverDate'] = "$($pk.Date)" }
            if (-not "$($ent['Version'])") { try { if ("$($hit.DriverVerVersion)") { $ent['Version'] = "$($hit.DriverVerVersion)" } } catch { } }
            $list += [pscustomobject]$ent
            Save-BlockedList $list
            $res[$key] = [pscustomobject]@{ Pkg = $pk; Hidden = $true; Title = "$($hit.Title)" }
        }
        if (@($res.Values | Where-Object { -not $_.Hidden }).Count -eq 0) { break }
        if ($t -lt $Tries) { Start-Sleep -Seconds $WaitSeconds }
    }
    # what Windows Update is offering, for diagnosis (reports\wu-pending.csv)
    try {
        $dl = foreach ($u in $seen) { [pscustomobject][ordered]@{ Title = "$($u.Title)"; Provider = "$($u.DriverProvider)"; Class = "$($u.DriverClass)"; Model = "$($u.DriverModel)"; Version = "$($u.DriverVerVersion)"; Date = (Format-Date $u.DriverVerDate) } }
        if (@($dl).Count -gt 0) { $null = Save-ReportCsv $dl 'wu-pending' }
    } catch { }
    # the ones hidden now are no longer pending; the others stay on the list for the next try
    Save-WuHideList @(Get-WuHideList | Where-Object { $e = $_; -not (@($res.Values | Where-Object { $_.Hidden -and "$($_.Pkg.InfName)" -ieq "$($e.InfName)" -and "$($_.Pkg.Version)" -eq "$($e.Version)" }).Count) })
    return @($res.Values)
}
# Tries again for the extension drivers removed earlier that Windows Update was not offering yet (called by the Windows Update step)
function Invoke-PendingWuHide {
    $l = @(Get-WuHideList)
    if ($l.Count -eq 0) { return @() }
    try { return @(Hide-WuDriverUpdates $l 1 0) } catch { return @() }
}
# Data to understand why drivers/devices come back: what Windows Update installed (history), the third-party driver packages now present, and the setupapi trail of the ones Devvy removed
function Save-ReturnDiag {
    $out = @()
    try {
        $sess = New-Object -ComObject Microsoft.Update.Session
        $s = $sess.CreateUpdateSearcher()
        $n = $s.GetTotalHistoryCount()
        if ($n -gt 0) {
            $take = [Math]::Min($n, 300)
            $h = foreach ($e in $s.QueryHistory(0, $take)) {
                $cat = ''; try { $cat = (@($e.Categories | ForEach-Object { $_.Name }) -join ';') } catch { }
                if ($cat -match 'Driver' -or "$($e.Title)" -match 'Driver|driver') {
                    [pscustomobject][ordered]@{ Date = (Format-Date $e.Date); Result = "$($e.ResultCode)"; Title = "$($e.Title)"; Categories = $cat }
                }
            }
            if (@($h).Count -gt 0) { $null = Save-ReportCsv @($h) 'wu-history'; $out += 'wu-history' }
        }
    } catch { }
    try {
        $inf = Join-Path $env:windir 'INF'
        $pend = @(Get-WuHideList)
        $rows = foreach ($f in @(Get-ChildItem -Path $inf -Filter 'oem*.inf' -ErrorAction SilentlyContinue)) {
            $t = Read-InfText $f.FullName
            $prov = ''; $cls = ''; $ver = ''
            if ($t -match '(?im)^\s*Provider\s*=\s*(.+)$') { $prov = $Matches[1].Trim() }
            if ($t -match '(?im)^\s*Class\s*=\s*(\S+)') { $cls = $Matches[1].Trim() }
            if ($t -match '(?im)^\s*DriverVer\s*=\s*(.+)$') { $ver = $Matches[1].Trim() }
            [pscustomobject][ordered]@{ Inf = $f.Name; Provider = $prov; Class = $cls; DriverVer = $ver; Installed = (Format-Date $f.CreationTime); PendingHide = [bool]($pend | Where-Object { "$($_.InfName)" -ieq $f.Name }) }
        }
        if (@($rows).Count -gt 0) { $null = Save-ReportCsv @($rows | Sort-Object Installed -Descending) 'oem-inf'; $out += 'oem-inf' }
        $names = @($pend | ForEach-Object { "$($_.InfName)" })
        foreach ($f in @(Get-ChildItem -Path $inf -Filter 'oem*.inf' -ErrorAction SilentlyContinue | Where-Object { $_.CreationTime -gt (Get-Date).AddDays(-14) })) { if ($names -notcontains $f.Name) { $names += $f.Name } }
        $tr = foreach ($nm in $names) { foreach ($l in @(Get-SetupApiTrail $nm 6)) { [pscustomobject][ordered]@{ Inf = $nm; Trail = "$l" } } }
        if (@($tr).Count -gt 0) { $null = Save-ReportCsv @($tr) 'setupapi-trail'; $out += 'setupapi-trail' }
    } catch { }
    return @($out)
}
function Show-WuDriverUpdate([string]$UpdateId) {
    $sess = New-Object -ComObject Microsoft.Update.Session
    $srch = $sess.CreateUpdateSearcher()
    $found = $srch.Search("IsHidden=1 and Type='Driver'")
    foreach ($u in $found.Updates) { if ("$($u.Identity.UpdateID)" -ieq $UpdateId) { $u.IsHidden = $false } }
}
function Save-BlockedList($List) {
    $f = Join-Path $script:DataRoot 'blocked-ids.json'
    ConvertTo-Json -InputObject @($List) -Depth 3 | Set-Content -Path $f -Encoding UTF8
}
# Reads an .inf whatever its encoding (UTF-16 with or without BOM, UTF-8, ANSI)
function Read-InfText([string]$Path) {
    try {
        $b = [IO.File]::ReadAllBytes($Path)
        if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { return [Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2) }
        if ($b.Length -ge 2 -and $b[0] -eq 0xFE -and $b[1] -eq 0xFF) { return [Text.Encoding]::BigEndianUnicode.GetString($b, 2, $b.Length - 2) }
        if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { return [Text.Encoding]::UTF8.GetString($b, 3, $b.Length - 3) }
        $zeros = 0; $n = [math]::Min($b.Length, 400)
        for ($i = 1; $i -lt $n; $i += 2) { if ($b[$i] -eq 0) { $zeros++ } }
        if ($n -gt 20 -and $zeros -gt ($n / 4)) { return [Text.Encoding]::Unicode.GetString($b) }
        return [Text.Encoding]::UTF8.GetString($b)
    } catch { return '' }
}
# Software-component IDs (SWC\xxx) that an .inf creates, e.g. SWC\HPAnalytics
function Get-SwcIdsFromInf([string]$Path) {
    $ids = @()
    $txt = Read-InfText $Path
    foreach ($m in [regex]::Matches($txt, '(?im)^\s*[^;=\r\n]+=\s*[^,\r\n;]+,\s*([^;\r\n]+)')) {
        foreach ($t in ($m.Groups[1].Value -split ',')) { $t = $t.Trim().Trim('"'); if ($t -match '^SWC\\[A-Za-z0-9_.&-]+$') { $ids += $t } }
    }
    return @($ids | Select-Object -Unique)
}
# After a driver package that creates software components is removed, its component nodes become ghosts: remove them in the same run
function Remove-SwcGhosts([string[]]$SwcIds) {
    $n = 0
    foreach ($id in $SwcIds) {
        $suffix = ($id -replace '^SWC\\', '').ToUpper()
        $devs = @()
        try { $devs = @(Get-PnpDevice -Class SoftwareComponent -ErrorAction Stop | Where-Object { $_.InstanceId.ToUpper().EndsWith('#' + $suffix) }) } catch { }
        foreach ($d in $devs) {
            if ($d.Present) { Write-Host ('  ' + (T 'Component still active: it disappears at the next restart: {0}' $d.FriendlyName)) -ForegroundColor Yellow; continue }
            $r = Remove-DeviceNode -InstanceId $d.InstanceId
            if ($r.Ok) { $n++; Write-Host ('  ' + (T 'Leftover component removed: {0}' $d.FriendlyName)) -ForegroundColor Green }
        }
    }
    return $n
}
# Extension INFs have no SWC id of their own (it lives in the base package), so the software component they served stays behind as a
# ghost (example: hpanalyticsext.inf -> SWD\DRIVERENUM\...#HPANALYTICSSOFTWARE). Only SAFE ghosts (virtual/system) whose last name
# part starts with the INF name (without 'ext'/'extension') are removed; at least 6 characters must match.
function Remove-RelatedGhosts([string]$InfName) {
    $n = 0
    $base = ("$InfName" -replace '(?i)\.inf$', '' -replace '(?i)(extension|ext)$', '').ToUpper()
    if ($base.Length -lt 6) { return 0 }
    $devs = @()
    try { $devs = @(Get-PnpDevice -ErrorAction Stop | Where-Object { -not $_.Present -and $_.InstanceId -match '#' }) } catch { }
    foreach ($d in $devs) {
        $suffix = ($d.InstanceId -split '#')[-1].ToUpper()
        if (-not $suffix.StartsWith($base)) { continue }
        if ((Get-GhostKind $d.InstanceId "$($d.Class)" "$($d.FriendlyName)") -ne 'SAFE') { continue }
        $r = Remove-DeviceNode -InstanceId $d.InstanceId
        if ($r.Ok) { $n++; Write-Host ('  ' + (T 'Leftover component removed: {0}' $d.FriendlyName)) -ForegroundColor Green }
    }
    return $n
}
function Test-BlockableId([string]$Id) {
    return [bool]($Id -match '^(SWC\\[A-Za-z0-9_.&-]+$|USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}|PCI\\VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}|BTHENUM\\|BTH\\|HID\\VID_|ROOT\\|SWD\\|ACPI\\)')
}
# Completes an old blocked entry (made before the data was kept with it) for the page: class from the id / the Windows Update title,
# version from the title, and what it is + advice from the knowledge base (same texts as the Drivers table)
$script:WuInfoTried = $false
$script:WuInfo = @{}
# Date and version of the hidden Windows Update drivers (asked once to Windows Update, then kept in blocked-ids.json)
function Get-WuHiddenInfo {
    if ($script:WuInfoTried) { return $script:WuInfo }
    $script:WuInfoTried = $true
    try {
        $sess = New-Object -ComObject Microsoft.Update.Session
        $found = $sess.CreateUpdateSearcher().Search("IsHidden=1 and Type='Driver'")
        foreach ($u in $found.Updates) { $script:WuInfo["$($u.Identity.UpdateID)".ToLower()] = @{ Date = (Format-Date $u.DriverVerDate); Version = "$($u.DriverVerVersion)" } }
    } catch { }
    return $script:WuInfo
}
function Get-BlockedForPage {
    $out = @()
    $save = $false
    $stored = @(Get-BlockedList)
    foreach ($b in @(Get-BlockedListReal)) {
        $h = [ordered]@{}
        foreach ($pp in $b.PSObject.Properties) { $h[$pp.Name] = $pp.Value }
        $id = "$($b.Id)"
        if (-not "$($h['Class'])") {
            if ($id -match '^SWC\\') { $h['Class'] = 'SoftwareComponent' }
            elseif ($id -match '^WU:' -and "$($b.Driver)" -match '^.+? - (\w+) - ') { $h['Class'] = $Matches[1] }
        }
        if ($id -match '^WU:' -and -not "$($h['Version'])" -and "$($b.Driver)" -match ' - ([0-9][0-9.]+)\s*$') { $h['Version'] = $Matches[1] }
        if ($id -match '^WU:(.+)$') {
            $uid = $Matches[1].ToLower()
            if (-not "$($h['DriverDate'])" -and "$($b.Driver)" -match '\b(\d{1,2})/(\d{1,2})/(\d{4})\b') { $h['DriverDate'] = ('{0}-{1:00}-{2:00}' -f $Matches[3], [int]$Matches[1], [int]$Matches[2]) }
            if (-not "$($h['DriverDate'])") {
                $wi = (Get-WuHiddenInfo)[$uid]
                if ($wi) { $h['DriverDate'] = "$($wi.Date)"; if (-not "$($h['Version'])") { $h['Version'] = "$($wi.Version)" } }
            }
            if ("$($h['DriverDate'])") {
                $e = @($stored | Where-Object { $_.Id -ieq $id })[0]
                if ($e -and -not $e.PSObject.Properties['DriverDate']) { $e | Add-Member -NotePropertyName DriverDate -NotePropertyValue "$($h['DriverDate'])" -Force; if ("$($h['Version'])" -and -not $e.PSObject.Properties['Version']) { $e | Add-Member -NotePropertyName Version -NotePropertyValue "$($h['Version'])" -Force }; $save = $true }
            }
        }
        if (-not "$($h['What']) $($h['Advice'])".Trim()) {
            try {
                $adv = Get-Advice ('{0} {1} {2}' -f $b.Inf, $b.Provider, $h['Class'])
                if ($adv) { $h['What'] = "$($adv.Name)"; $h['Advice'] = (Get-AdviceText $adv); $h['KbId'] = "$($adv.Id)" }
            } catch { }
        }
        $out += [pscustomobject]$h
    }
    if ($save) { try { Save-BlockedList $stored } catch { } }
    return @($out)
}
# Data of the device/driver kept with a blocked entry, so Device management can show the same summary as the Devices/Drivers tables
function Get-BlockExtraNames { return @('Class', 'Version', 'Manufacturer', 'FriendlyName', 'What', 'InfDescription', 'InfPath', 'Reason', 'Advice', 'HardwareIds', 'InstanceId', 'DriverDate') }
function Get-BlockExtra($R) {
    $h = @{}
    if ($R) { foreach ($n in (Get-BlockExtraNames)) { if ($R.PSObject.Properties[$n] -and "$($R.$n)") { $h[$n] = "$($R.$n)" } } }
    # a driver row of the inventory: its Date is the date of the driver (a blocked entry has Inf, not InfName, and its Date is the day of the block)
    if ($R -and $R.PSObject.Properties['InfName'] -and $R.PSObject.Properties['Date'] -and "$($R.Date)") { $h['DriverDate'] = "$($R.Date)" }
    return $h
}
function Add-BlockedId {
    param([string]$Id, [string]$Driver, [string]$Inf, [string]$Provider, $Row = $null)
    $sub = Join-Path $script:DenyKey 'DenyDeviceIDs'
    if (-not (Test-Path $sub)) { New-Item -Path $sub -Force | Out-Null }
    $have = Get-ItemProperty -Path $sub -ErrorAction SilentlyContinue
    $names = @($have.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object { $_.Name })
    $already = $null
    foreach ($n in $names) { if ("$($have.$n)" -ieq $Id) { $already = $n } }
    $i = 1; while ($names -contains "$i") { $i++ }
    if ($null -eq $already) {
        New-ItemProperty -Path $sub -Name "$i" -Value $Id -PropertyType String -Force | Out-Null
        Set-ItemProperty -Path $script:DenyKey -Name 'DenyDeviceIDs' -Value 1 -Type DWord
        Set-ItemProperty -Path $script:DenyKey -Name 'DenyDeviceIDsRetroactive' -Value 0 -Type DWord
    }
    # the list file is always brought up to date, also when Windows already had the id (file lost or older version)
    $oldE = @(Get-BlockedList | Where-Object { $_.Id -ieq $Id })[0]
    $list = @(Get-BlockedList | Where-Object { $_.Id -ine $Id })
    $ent = [ordered]@{ Id = $Id; Driver = $Driver; Inf = $Inf; Provider = $Provider; Date = (Get-Date -Format 'yyyy-MM-dd'); RegName = $(if ($null -ne $already) { "$already" } else { "$i" }) }
    foreach ($n in (Get-BlockExtraNames)) { if ($oldE -and $oldE.PSObject.Properties[$n] -and "$($oldE.$n)") { $ent[$n] = "$($oldE.$n)" } }
    $x = Get-BlockExtra $Row; foreach ($k in $x.Keys) { $ent[$k] = $x[$k] }
    $list += [pscustomobject]$ent
    Save-BlockedList $list
    if ($null -ne $already) { return 'exists' }
    return 'added'
}
function Remove-BlockedId([string]$Id) {
    if ($Id -match '^WU:(.+)$') { Show-WuDriverUpdate $Matches[1]; Save-BlockedList @(Get-BlockedList | Where-Object { $_.Id -ine $Id }); return }
    $sub = Join-Path $script:DenyKey 'DenyDeviceIDs'
    $have = Get-ItemProperty -Path $sub -ErrorAction SilentlyContinue
    if ($have) {
        foreach ($p in @($have.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })) {
            if ("$($p.Value)" -ieq $Id) { Remove-ItemProperty -Path $sub -Name $p.Name -ErrorAction SilentlyContinue }
        }
    }
    Save-BlockedList @(Get-BlockedList | Where-Object { $_.Id -ine $Id })
}

function Get-AdviceText($k) {
    if (-not $k) { return '' }
    if ($k.IsOrphan) { return ((T 'Orphaned component: the related app is not installed.') + ' ' + $k.IfNotNeeded) }
    if ($k.HasApp -and $k.AppInstalled) { return ((T 'App installed. Needed if:') + ' ' + $k.IfNeeded + ' ' + (T 'If you do not need it:') + ' ' + $k.IfNotNeeded) }
    return ((T 'Needed if:') + ' ' + $k.IfNeeded + ' ' + (T 'If you do not need it:') + ' ' + $k.IfNotNeeded)
}

# Removes a device entry. Windows 10 2004+ has "pnputil /remove-device"; on older builds (for example 1809 / LTSC 2019) the same is done
# with the SetupAPI call SetupDiRemoveDevice, which does not need pnputil.
$script:PnpCanRemove = $null
function Test-PnpCanRemove {
    if ($null -ne $script:PnpCanRemove) { return $script:PnpCanRemove }
    $script:PnpCanRemove = $false
    try { $script:PnpCanRemove = ((& pnputil.exe '/?' 2>&1 | Out-String) -match 'remove-device') } catch { }
    return $script:PnpCanRemove
}
function Remove-DeviceNode {
    param([string]$InstanceId, [switch]$Subtree)
    if (Test-PnpCanRemove) {
        $a = @('/remove-device', $InstanceId); if ($Subtree) { $a += '/subtree' }
        return (Invoke-Pnp $a)
    }
    if (-not ('DpSetup' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class DpSetup {
    [StructLayout(LayoutKind.Sequential)]
    public struct SP_DEVINFO_DATA { public int cbSize; public Guid ClassGuid; public int DevInst; public IntPtr Reserved; }
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Auto)]
    static extern IntPtr SetupDiGetClassDevs(IntPtr classGuid, string enumerator, IntPtr hwnd, int flags);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiEnumDeviceInfo(IntPtr set, int index, ref SP_DEVINFO_DATA data);
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Auto)]
    static extern bool SetupDiGetDeviceInstanceId(IntPtr set, ref SP_DEVINFO_DATA data, StringBuilder buf, int size, out int required);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiRemoveDevice(IntPtr set, ref SP_DEVINFO_DATA data);
    [DllImport("setupapi.dll")]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
    // 0 = removed, 1 = not found, other = Win32 error
    public static int Remove(string instanceId) {
        IntPtr set = SetupDiGetClassDevs(IntPtr.Zero, null, IntPtr.Zero, 4);
        if (set == IntPtr.Zero || set.ToInt64() == -1) return Marshal.GetLastWin32Error();
        try {
            SP_DEVINFO_DATA d = new SP_DEVINFO_DATA();
            d.cbSize = Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
            for (int i = 0; SetupDiEnumDeviceInfo(set, i, ref d); i++) {
                StringBuilder sb = new StringBuilder(512); int req;
                if (!SetupDiGetDeviceInstanceId(set, ref d, sb, sb.Capacity, out req)) continue;
                if (string.Equals(sb.ToString(), instanceId, StringComparison.OrdinalIgnoreCase)) {
                    if (SetupDiRemoveDevice(set, ref d)) return 0;
                    return Marshal.GetLastWin32Error();
                }
            }
            return 1;
        } finally { SetupDiDestroyDeviceInfoList(set); }
    }
}
'@
    }
    $r = 1
    try { $r = [DpSetup]::Remove($InstanceId) } catch { return [pscustomobject]@{ Ok = $false; Code = -1; Output = $_.Exception.Message } }
    [pscustomobject]@{ Ok = ($r -eq 0); Code = $r; Output = ('SetupAPI code ' + $r) }
}

# ---------- Colored messages (same palette in every script) ----------
# Cyan = titles | Gray = information | Green = in progress / ok | Yellow = warning | Red = error | Black on yellow = WHAT TO DO
function Write-Title([string]$Text) { Write-Host ''; Write-Host $Text -ForegroundColor Cyan }
# Progress for the web page (only when started by 00-server.ps1): a "##PROG a/b##" line read by the server
function Write-Prog([int]$A, [int]$B) { if ($env:DEVVY_WEB -eq '1' -and $B -gt 0) { Write-Host ('##PROG ' + $A + '/' + $B + '##') } }
function Write-RebootNeeded { if ($env:DEVVY_WEB -eq '1') { Write-Host '##REBOOT##' } }
# Summary lines "ACTION, Category": the action and origin words are translated too
function ConvertTo-SummaryName([string]$Name) {
    $out = @()
    foreach ($p in ($Name -split ', ')) {
        switch ($p) {
            'KEEP' { $out += (T 'KEEP') } 'REMOVE' { $out += (T 'REMOVE') } 'REMOVE+UNINSTALL' { $out += (T 'REMOVE+UNINSTALL') }
            'Inbox' { $out += (T 'Windows (included)') } 'Third-party' { $out += (T 'Third-party') }
            default { $out += $p }
        }
    }
    return ($out -join ', ')
}
function Write-Info([string]$Text) { Write-Host $Text -ForegroundColor Gray }
function Write-Ok([string]$Text) { Write-Host $Text -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host $Text -ForegroundColor Yellow }
function Write-Err([string]$Text) { Write-Host $Text -ForegroundColor Red }

# "What to do now" box. The web page proposes the next step itself, so it is only shown when a script is run by hand.
function Write-Todo {
    param([string[]]$Lines, [string]$Title = '')
    if ($env:DEVVY_WEB -eq '1') { return }
    if (-not $Title) { $Title = T 'WHAT TO DO NOW' }
    Write-Host ''
    Write-Host ('  ' + $Title + '  ') -ForegroundColor Black -BackgroundColor Yellow
    $i = 1
    foreach ($l in $Lines) {
        Write-Host ('  {0}. {1}' -f $i, $l) -ForegroundColor White
        $i++
    }
    Write-Host ''
}

function Write-ModeBanner([bool]$Apply) {
    if ($env:DEVVY_WEB -eq '1') { return }   # in the page the popup title already says preview or changes
    Write-Host ''
    if ($Apply) { Write-Host ('  ' + (T 'CHANGING THE PC: the operations are really performed') + '  ') -ForegroundColor White -BackgroundColor DarkRed }
    else { Write-Host ('  ' + (T 'PREVIEW: nothing is changed on the PC') + '  ') -ForegroundColor Black -BackgroundColor Cyan }
    Write-Host ''
}

function Write-ReadOnlyBanner {
    if ($env:DEVVY_WEB -eq '1') { return }
    Write-Host ''
    Write-Host ('  ' + (T 'READ ONLY: this step changes nothing') + '  ') -ForegroundColor Black -BackgroundColor Green
    Write-Host ''
}

# color of an outcome line from its kind
function Get-OutcomeColor([string]$Kind) {
    switch ($Kind) { 'err' { return 'Red' } 'warn' { return 'Yellow' } 'preview' { return 'Cyan' } default { return 'Green' } }
}

# What to do after an operation that can change the system (shown only when a script is run by hand)
function Write-AfterRun {
    param([bool]$Apply, [string[]]$AfterApply = @())
    if (-not $Apply) {
        Write-Todo @(
            (T 'This was a PREVIEW: nothing was changed on the PC.'),
            (T 'Check what would be done in the latest file of the outcomes folder.'),
            (T 'If everything is right, run the same script again with -Apply.')
        )
    } else {
        $l = @(T 'Restart the PC: some changes complete only after a restart.')
        $l += $AfterApply
        $l += T 'After the restart run the inventory again to check the result.'
        $l += T 'If something no longer works and you made a backup: use System Restore (point "Devvy: before the changes"), or reinstall the saved drivers from the backups folder with: pnputil /add-driver "<folder>\*.inf" /subdirs /install.'
        Write-Todo $l
    }
}

# one-key choice: asks again if the key is not valid
function Read-Choice {
    param([string]$Prompt, [string[]]$Valid)
    # In the web page (DEVVY_WEB=1) there is no keyboard: without a question folder the cautious answer (N, then X) is used.
    if ($env:DEVVY_WEB -eq '1') {
        # If the server gave a question folder, the question appears in the page popup and we wait for the answer here
        $dirQ = $env:DEVVY_ASKDIR
        if ($dirQ -and (Test-Path $dirQ)) {
            $fq = Join-Path $dirQ 'question.json'
            $fa = Join-Path $dirQ 'answer.txt'
            Remove-Item -Path $fa -Force -ErrorAction SilentlyContinue
            $js = ConvertTo-Json -InputObject @{ id = ([guid]::NewGuid().ToString()); text = $Prompt; valid = @($Valid) } -Compress
            Set-Content -Path $fq -Value $js -Encoding UTF8
            Write-Host ''
            Write-Host ((T 'QUESTION:') + ' ' + $Prompt) -ForegroundColor Yellow
            Write-Host ('  ' + (T 'Waiting for your answer in the page...')) -ForegroundColor Gray
            while ($true) {
                Start-Sleep -Milliseconds 700
                if (-not (Test-Path $fa)) { continue }
                $r = ''
                try { $r = ((Get-Content -Path $fa -Raw -ErrorAction Stop) + '').Trim().ToUpper() } catch { continue }
                if ($Valid -contains $r) {
                    Remove-Item -Path $fq, $fa -Force -ErrorAction SilentlyContinue
                    Write-Host ('  ' + (T 'Answer:') + ' ' + $r) -ForegroundColor Yellow
                    return $r
                }
                Remove-Item -Path $fa -Force -ErrorAction SilentlyContinue
            }
        }
        if ($Valid -contains 'N') { return 'N' }
        if ($Valid -contains 'X') { return 'X' }
        return $Valid[0]
    }
    while ($true) {
        Write-Host ($Prompt + ' ') -ForegroundColor White -NoNewline
        $k = [Console]::ReadKey($true)
        $c = $k.KeyChar.ToString().ToUpper()
        if ($Valid -contains $c) { Write-Host $c -ForegroundColor Yellow; return $c }
        Write-Host ''
        Write-Host ('  ' + (T 'Invalid key. Press one of:') + ' ' + ($Valid -join ', ')) -ForegroundColor Red
    }
}


# ---------- Update of the program itself (sync with the latest GitHub release) ----------
# files.json (root of the project) lists every file of the release with its SHA-256. The update downloads only the new or
# changed files from the release tag, checks each hash, replaces the old ones and removes those no longer in the project.
# Never touched: the data folder and the user's own tables.
$script:UpdateRepo = 'zuwann/devvy'
function Get-UpdateUrls {
    # '/releases/latest' ignores pre-releases (all Devvy betas are pre-releases): take the newest published release from the list
    $api = 'https://api.github.com/repos/' + $script:UpdateRepo + '/releases?per_page=10'
    $raw = 'https://raw.githubusercontent.com/' + $script:UpdateRepo + '/'
    # test hook: a local fake server (only 127.0.0.1 is accepted)
    if ($env:DEVVY_UPDATE_TEST -match '^http://127\.0\.0\.1:\d+/$') { $api = $env:DEVVY_UPDATE_TEST + 'api/latest'; $raw = $env:DEVVY_UPDATE_TEST + 'raw/' }
    return @{ Api = $api; Raw = $raw }
}
function Get-LocalVersion {
    try {
        $h = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'web\app.html'), [Text.Encoding]::UTF8)
        if ($h -match '<h1>Devvy <small[^>]*>\s*(\d+(?:\.\d+)+)') { return $Matches[1] }
    } catch { }
    return '0.0.0'
}
function Test-SafeRelPath([string]$P) {
    if (-not $P) { return $false }
    if ($P -match '(^|[\\/])\.\.([\\/]|$)' -or $P -match '^[\\/]' -or $P -match '^[A-Za-z]:') { return $false }
    if ($P -notmatch '^[A-Za-z0-9_.\- /]+$') { return $false }
    if ($P -match '^(data|\.git)(/|$)' -or $P -match '(^|/)(knowledge-user|support-models-user)\.csv$') { return $false }
    return $true
}
function Get-WebText([string]$Url) {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $ProgressPreference = 'SilentlyContinue'
    $c = (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30 -Headers @{ 'User-Agent' = 'Devvy-update'; 'Accept' = 'application/vnd.github+json' }).Content
    if ($c -is [byte[]]) { $c = [Text.Encoding]::UTF8.GetString($c) }
    return "$c"
}
# Compares the installed files with the latest release. Reads only; nothing is changed.
function Get-UpdatePlan {
    $root = Split-Path $PSScriptRoot
    $r = @{ ok = $false; error = ''; current = (Get-LocalVersion); latest = ''; tag = ''; needed = $false; added = @(); changed = @(); removed = @(); manifest = $null }
    if ($script:UpdateRepo -match 'OWNER' -and -not $env:DEVVY_UPDATE_TEST) { $r.error = (T 'The GitHub address of the project is not set yet: nothing to download.'); return $r }
    try {
        $u = Get-UpdateUrls
        $rel = (Get-WebText $u.Api) | ConvertFrom-Json
        # a list (real GitHub) -> newest release that is not a draft; a single object (test server) is used as it is
        $relList = @($rel | ForEach-Object { $_ })
        if ($relList.Count -gt 0 -and $null -ne $relList[0].tag_name) { $rel = @($relList | Where-Object { -not $_.draft })[0] }
        if (-not $rel) { $r.error = (T 'No release has been published yet.'); return $r }
        $tag = "$($rel.tag_name)"
        if ($tag -notmatch '^v?\d+(\.\d+)+([-.\w]*)?$') { $r.error = (T 'The release name is not valid.'); return $r }
        $r.tag = $tag; $r.latest = ($tag -replace '^v', '' -replace '[^\d.].*$', '')
        $man = (Get-WebText ($u.Raw + $tag + '/files.json')) | ConvertFrom-Json
        $files = @($man.files)
        if ($files.Count -lt 5) { $r.error = (T 'The file list of the release is not valid.'); return $r }
        $keep = @{}
        foreach ($f in $files) {
            $rp = "$($f.path)"
            if (-not (Test-SafeRelPath $rp) -or "$($f.sha256)" -notmatch '^[0-9a-fA-F]{64}$') { continue }
            $keep[$rp] = $true
            $lp = Join-Path $root ($rp -replace '/', '\')
            if (-not (Test-Path -LiteralPath $lp -PathType Leaf)) { $r.added += $rp; continue }
            if ((Get-FileHash -LiteralPath $lp -Algorithm SHA256).Hash.ToLower() -ne "$($f.sha256)".ToLower()) { $r.changed += $rp }
        }
        $old = Join-Path $root 'files.json'
        if (Test-Path $old) {
            try {
                foreach ($f in @((Get-Content -Path $old -Raw -Encoding UTF8 | ConvertFrom-Json).files)) {
                    $rp = "$($f.path)"
                    if ($rp -and -not $keep.ContainsKey($rp) -and ($rp -like 'scripts/*') -and (Test-SafeRelPath $rp) -and (Test-Path -LiteralPath (Join-Path $root ($rp -replace '/', '\')) -PathType Leaf)) { $r.removed += $rp }
                }
            } catch { }
        }
        $diff = ($r.added.Count + $r.changed.Count + $r.removed.Count)
        $newer = $false; try { $newer = ([version]$r.latest -gt [version]$r.current) } catch { }
        $same = $false; try { $same = ([version]$r.latest -eq [version]$r.current) } catch { }
        $r.needed = ($diff -gt 0 -and ($newer -or $same))
        $r.manifest = $man
        $r.ok = $true
    } catch { $r.error = (T 'Cannot reach the update page: {0}' ($_.Exception.Message -replace '\s+', ' ')) }
    return $r
}

# ---------- Check after a restart started from the program ----------
# A one-time scheduled task starts the program at the next sign-in (elevated, no UAC window); the page then runs the
# post-restart check. The task deletes itself as soon as the program starts.
$script:PostRebootTask = 'Devvy-AfterRestart'
# Which Windows driver packages (oemNN.inf) each catalog download installed: lets the "installed from the catalog" list
# drop what does not exist any more
function Get-DownloadInfFile { return (Join-Path $script:DataRoot 'downloads-inf.json') }
function Get-DownloadInfs {
    $m = @{}
    try { $f = Get-DownloadInfFile; if (Test-Path $f) { foreach ($e in @(Get-Content -Path $f -Raw -Encoding UTF8 | ConvertFrom-Json)) { if ($e.Sha) { $m["$($e.Sha)"] = @($e.Infs | Where-Object { $_ }) } } } } catch { }
    return $m
}
function Set-DownloadInfs([string]$Sha, [string[]]$Infs) {
    if (-not $Sha) { return }
    try {
        $m = Get-DownloadInfs; $m[$Sha] = @($Infs | Where-Object { $_ })
        $l = @(foreach ($k in $m.Keys) { [pscustomobject]@{ Sha = $k; Infs = @($m[$k]) } })
        (ConvertTo-Json -InputObject $l -Depth 4) | Set-Content -Path (Get-DownloadInfFile) -Encoding UTF8
    } catch { }
}
function Get-ContinueFile { return (Join-Path $script:DataRoot 'continue.json') }
function Get-PostRebootFile { return (Join-Path $script:DataRoot 'postreboot.json') }
function Register-PostRebootTask([string]$BatPath) {
    try {
        $usr = "$env:USERDOMAIN\$env:USERNAME"
        $act = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c ""' + $BatPath + '" /afterrestart"') -WorkingDirectory (Split-Path $BatPath)
        $trg = New-ScheduledTaskTrigger -AtLogOn -User $usr
        $trg.Delay = 'PT30S'
        $pri = New-ScheduledTaskPrincipal -UserId $usr -LogonType Interactive -RunLevel Highest
        # laptops: by default a task does not start on battery, which is why it only ran when started by hand
        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew
        $null = Register-ScheduledTask -TaskName $script:PostRebootTask -Action $act -Trigger $trg -Principal $pri -Settings $set -Force -ErrorAction Stop
        ([pscustomobject]@{ Time = (Get-Date).ToString('o') } | ConvertTo-Json) | Set-Content -Path (Get-PostRebootFile) -Encoding UTF8
        return $true
    } catch { return $false }
}
function Get-PostRebootTask {
    # schtasks first: Get-ScheduledTask prints a red 'fatal error' line on the console when the task does not exist
    try { $null = & schtasks.exe /query /tn $script:PostRebootTask 2>&1; if ($LASTEXITCODE -ne 0) { return $null } } catch { return $null }
    try { return (Get-ScheduledTask -TaskName $script:PostRebootTask -ErrorAction Stop) } catch { return $null }
}
function Unregister-PostRebootTask { try { $null = Unregister-ScheduledTask -TaskName $script:PostRebootTask -Confirm:$false -ErrorAction Stop } catch { } }

# ---------- Drivers installed by the program: remember them, notice when Windows puts the old one back ----------
function Get-PinFile { return (Join-Path $script:DataRoot 'pinned-drivers.json') }
function Get-Pins { try { $f = Get-PinFile; if (Test-Path $f) { return @(Get-Content -Path $f -Raw -Encoding UTF8 | ConvertFrom-Json) } } catch { } return @() }
function Save-Pins($List) { try { (ConvertTo-Json -InputObject @($List) -Depth 4) | Set-Content -Path (Get-PinFile) -Encoding UTF8 } catch { } }
function Save-PinnedDriver([string]$Device, [string]$ShortId, [string]$InstanceId, [string]$Version, [string]$Inf, [string]$Date) {
    if (-not $InstanceId -or -not $Version) { return }
    $l = @(Get-Pins | Where-Object { $_.InstanceId -ne $InstanceId })
    $l += [pscustomobject]@{ Device = $Device; ShortId = $ShortId; InstanceId = $InstanceId; Version = $Version; Inf = $Inf; Date = $Date; Time = (Get-Date).ToString('o') }
    Save-Pins $l
}
# Pins whose device now uses a different driver version than the one the program installed
function Get-PinMismatch {
    $out = @()
    foreach ($pn in @(Get-Pins)) {
        try {
            $pp = @{}
            Get-PnpDeviceProperty -InstanceId $pn.InstanceId -KeyName @('DEVPKEY_Device_DriverVersion', 'DEVPKEY_Device_DriverInfPath', 'DEVPKEY_Device_DriverDate') -ErrorAction Stop | ForEach-Object { $pp[$_.KeyName] = $_.Data }
            $cur = "$($pp['DEVPKEY_Device_DriverVersion'])"
            if ($cur -and $cur -ne $pn.Version) { $out += [pscustomobject]@{ Device = $pn.Device; InstanceId = $pn.InstanceId; Expected = $pn.Version; Current = $cur; Inf = "$($pp['DEVPKEY_Device_DriverInfPath'])"; Since = $pn.Time } }
        } catch { }
    }
    return $out
}
# Trail of driver installs for a device in the Windows setup log: who installed what and when (diagnostic only)
function Get-SetupApiTrail([string]$Needle, [int]$Max = 8) {
    $res = @()
    try {
        $f = Join-Path $env:windir 'INF\setupapi.dev.log'
        if (-not (Test-Path $f)) { return $res }
        $fs = [IO.File]::Open($f, 'Open', 'Read', 'ReadWrite')
        try {
            $len = $fs.Length; $take = [Math]::Min($len, 6MB); $null = $fs.Seek($len - $take, 'Begin')
            $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8); $txt = $sr.ReadToEnd()
        } finally { $fs.Dispose() }
        $head = ''; $start = ''; $hit = $false
        foreach ($ln in ($txt -split "`r?`n")) {
            if ($ln -match '^>>>\s+\[(.+)\]\s*$') { $head = $Matches[1]; $start = ''; $hit = $false }
            elseif ($ln -match '^>>>\s+Section start\s+(.+)$') { $start = $Matches[1].Trim() }
            elseif ($ln -match '^<<<\s+Section end') { if ($hit) { $res += ('{0}  {1}' -f $start, $head) }; $hit = $false }
            elseif ($Needle -and $ln.IndexOf($Needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $true }
        }
    } catch { }
    return @($res | Select-Object -Last $Max)
}

# Basic data of the PC (cached): used by the page and by the report
function Get-PcInfo {
    if ($script:PcInfo) { return $script:PcInfo }
    $o = @{ os = ''; cpu = ''; ram = ''; disk = ''; gpu = ''; maker = ''; model = ''; sku = ''; bmaker = ''; bmodel = ''; laptop = $false; oem = $false }
    try { $o.os = ("$((Get-CimInstance Win32_OperatingSystem).Caption)" -replace '^Microsoft\s+', '').Trim() } catch { }
    try { $o.cpu = ("$(@(Get-CimInstance Win32_Processor)[0].Name)" -replace '\s+', ' ' -replace '\(R\)|\(TM\)', '').Trim() } catch { }
    try { $m = [double](Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory; if ($m -gt 0) { $o.ram = ('{0} GB' -f [math]::Round($m / 1GB)) } } catch { }
    try {
        $sd = "$env:SystemDrive"; if (-not $sd) { $sd = 'C:' }
        $ld = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='" + $sd + "'")
        $model = ''
        try { $model = ("$(@(Get-CimInstance Win32_DiskDrive | Sort-Object Index)[0].Model)").Trim() } catch { }
        if ($ld) {
            $txt = ('{0} GB, {1} GB {2}' -f [math]::Round($ld.Size / 1GB), [math]::Round($ld.FreeSpace / 1GB), (T 'free'))
            if ($model) { $o.disk = $model + ' (' + $txt + ')' } else { $o.disk = $txt }
        }
    } catch { }
    try {
        $names = @(Get-CimInstance Win32_VideoController | ForEach-Object { "$($_.Name)".Trim() } | Where-Object { $_ })
        $real = @($names | Where-Object { $_ -notmatch 'Basic|Remote|Virtual|Parsec|Meta|Mirror' })
        if ($real.Count -eq 0) { $real = $names }
        $o.gpu = (@($real | Select-Object -Unique) -join ' + ')
    } catch { }
    try {
        $cs = Get-CimInstance Win32_ComputerSystem
        $maker = ("$($cs.Manufacturer)").Trim(); $model = ("$($cs.Model)").Trim()
        $ch = @()
        try { $ch = @((Get-CimInstance Win32_SystemEnclosure).ChassisTypes | ForEach-Object { [int]$_ }) } catch { }
        $laptop = (@($ch | Where-Object { @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32) -contains $_ }).Count -gt 0)
        $brand = ($maker -match '^(ASUS|ASUSTeK|HP|Hewlett|Lenovo|Dell|Acer|MSI|Micro-Star|Samsung|Toshiba|Dynabook|Fujitsu|Gigabyte|LG|Sony|VAIO|Huawei|Honor|Xiaomi|Razer|Alienware|Medion|Packard|Gateway|Microsoft Corporation)')
        $virtual = (("$maker $model") -match 'VMware|VirtualBox|QEMU|KVM|Virtual Machine|Xen|Bochs|Parallels|Proxmox')
        $generic = ($model -match 'System Product Name|To Be Filled|Default string|Standard PC|System Version')
        $o.maker = $maker; $o.model = $model; $o.laptop = $laptop
        $sku = ("$($cs.SystemSKUNumber)").Trim(); if ($sku -match 'To Be Filled|Default string|System SKU|^0+$|Not Applicable') { $sku = '' }; $o.sku = $sku
        $o.oem = ($brand -and -not $virtual -and ($laptop -or -not $generic))
    } catch { }
    # Motherboard (baseboard): on desktop PCs most drivers (chipset, audio, LAN, Wi-Fi) come from the board maker
    try {
        $bb = Get-CimInstance Win32_BaseBoard
        $bm = ("$($bb.Manufacturer)").Trim(); $bp = ("$($bb.Product)").Trim()
        $ph = 'To Be Filled|Default string|System Product Name|Not Applicable|Base Board|O\.E\.M|None|Unknown|^0+$|^\s*$'
        if ($bm -match $ph) { $bm = '' }
        if ($bp -match $ph) { $bp = '' }
        $o.bmaker = $bm; $o.bmodel = $bp
    } catch { }
    $script:PcInfo = $o
    return $o
}

# OEM warning text for components that often need the PC maker driver (network, Realtek-like audio)
function Get-OemNote([string]$Class, [string]$Text) {
    $pc = Get-PcInfo
    if (-not $pc.oem) { return '' }
    $sens = ($Class -match '^Net$') -or (($Class -match '^Media$') -and ($Text -match 'realtek|conexant|waves|nahimic|dolby'))
    if ($sens) { return (T 'This component may need custom drivers from the PC maker. Installing a generic version from the Microsoft catalog could remove its dedicated control panels. If everything works, we suggest excluding it.') }
    return ''
}
# Ghost devices: SAFE = virtual or system component (always recreated by Windows when needed); PHYSICAL = real hardware not connected now
function Get-GhostKind([string]$InstanceId, [string]$Class, [string]$Name) {
    if ($Class -match '^(Printer|PrintQueue|WSDPrintDevice|USB|DiskDrive|CDROM|Monitor|Camera|Image|WPD|Bluetooth)$') { return 'PHYSICAL' }
    if ($InstanceId -match '^(SWD\\|ROOT\\|SW\\|HTREE\\ROOT|STORAGE\\VOLUME|UMB\\|TERMINPUT|BTH\\MS_BTH|MS_)' ) { return 'SAFE' }
    if ($Name -match 'WAN Miniport|Virtual|Hyper-V|TAP-|Loopback|Proxy|Redirector|Streaming (Service|Tee|Sink)|Software Device|Remote Desktop|Teredo|6to4|IP-HTTPS|ISATAP|Wi-Fi Direct|Kernel Debug|Generic software') { return 'SAFE' }
    return 'PHYSICAL'
}

# ---------- Per-device driver state, package lookup and forcing (used by the catalog install and by the rollback) ----------
# Current driver of the present devices that have this hardware ID (to compare before and after)
function Get-DriverState([string]$ShortId) {
    $res = @()
    foreach ($d in @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue)) {
        $p = @{}
        Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName @('DEVPKEY_Device_HardwareIds', 'DEVPKEY_Device_DriverInfPath', 'DEVPKEY_Device_DriverVersion', 'DEVPKEY_Device_DriverDate') -ErrorAction SilentlyContinue |
            ForEach-Object { $p[$_.KeyName] = $_.Data }
        $hw = @($p['DEVPKEY_Device_HardwareIds'])
        if (-not ($hw | Where-Object { "$_" -match [regex]::Escape($ShortId) })) { continue }
        $dt = ''
        if ($p['DEVPKEY_Device_DriverDate']) { $dt = Format-Date $p['DEVPKEY_Device_DriverDate'] }
        $res += [pscustomobject]@{ Id = $d.InstanceId; Inf = "$($p['DEVPKEY_Device_DriverInfPath'])"; Ver = "$($p['DEVPKEY_Device_DriverVersion'])"; Date = $dt }
    }
    return $res
}

# Finds in the extracted package the .inf for ONE device. Compatible IDs and short generic IDs such as PCI\VEN_8086 are NOT
# used (they appear in unrelated drivers: a graphics card could end up with an audio bus driver). Two levels:
#  1) an INF that lists one of the device's own hardware IDs exactly (most specific first), same INF class;
#  2) otherwise an INF of the same class that names the same vendor+device pair (the catalog found the package with it).
function Find-DriverInf([string]$InstanceId, [string]$Folder, [string]$DevClass, [string]$ShortId) {
    $hw = @()
    try { $hw = @((Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction Stop).Data | ForEach-Object { "$_" }) } catch { }
    $ids = @($hw | Where-Object { $_ -match '&' })
    $infs = @(Get-ChildItem -Path $Folder -Filter '*.inf' -Recurse -ErrorAction SilentlyContinue)
    $texts = @{}
    foreach ($inf in $infs) { $texts[$inf.FullName] = Read-InfText $inf.FullName }
    function Test-InfClass([string]$Txt) {
        if (-not $DevClass) { return $true }
        if ($Txt -match '(?im)^\s*Class\s*=\s*([A-Za-z0-9_]+)') { return ($Matches[1] -eq $DevClass) }
        return $true
    }
    foreach ($h in $ids) {
        foreach ($inf in $infs) {
            $txt = $texts[$inf.FullName]
            if ($txt -notmatch ('(?im)(^|[\s,=])' + [regex]::Escape($h) + '\s*(?=$|[,;\r\n])')) { continue }
            if (-not (Test-InfClass $txt)) { continue }
            return @{ Inf = $inf.FullName; Id = $h; Level = 1 }
        }
    }
    if ($ShortId) {
        $pair = [regex]::Escape($ShortId)
        foreach ($inf in $infs) {
            $txt = $texts[$inf.FullName]
            if ($txt -notmatch ('(?i)' + $pair)) { continue }
            if (-not (Test-InfClass $txt)) { continue }
            $useId = ''
            if ($ids.Count -gt 0) { $useId = $ids[$ids.Count - 1] }
            foreach ($h in $ids) { if ($h -match ('(?i)' + $pair + '$')) { $useId = $h } }
            return @{ Inf = $inf.FullName; Id = $useId; Level = 2 }
        }
    }
    # nothing found: say what was looked at, so the problem can be understood
    Write-Info ('  ' + (T 'Device IDs: {0}' ($hw -join ' | ')))
    Write-Info ('  ' + (T 'Files looked at in the package ({0}): {1}' $infs.Count (($infs | Select-Object -First 12 | ForEach-Object { $_.Name }) -join ', ')))
    return $null
}

# Forces the new package onto ONE device (like "Let me pick" in Device Manager):
# UpdateDriverForPlugAndPlayDevices with INSTALLFLAG_FORCE installs the .inf even if Windows would rank another one higher.
function Invoke-ForceDriver([string]$InstanceId, [string]$Folder, [string]$DevClass, [string]$ShortId) {
    $res = [pscustomobject]@{ Ok = $false; Message = ''; Reboot = $false }
    if ($IsWindows -eq $false) { $res.Message = T 'Only available on Windows'; return $res }
    $found = Find-DriverInf $InstanceId $Folder $DevClass $ShortId
    if (-not $found) { $res.Message = T 'No file in the package matches an ID of this device'; return $res }
    Write-Info ('  ' + (T 'Package file: {0} (ID {1})' (Split-Path $found.Inf -Leaf) $found.Id))
    try {
        if (-not ('Devvy.Newdev' -as [type])) {
            Add-Type -Namespace Devvy -Name Newdev -MemberDefinition '[DllImport("newdev.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool UpdateDriverForPlugAndPlayDevicesW(IntPtr hwnd, string HardwareId, string FullInfPath, uint InstallFlags, out bool RebootRequired);'
        }
        $rb = $false
        $ok = [Devvy.Newdev]::UpdateDriverForPlugAndPlayDevicesW([IntPtr]::Zero, $found.Id, $found.Inf, 1, [ref]$rb)
        if ($ok) { $res.Ok = $true; $res.Reboot = $rb; $res.Message = T 'New driver applied ({0}, ID {1})' (Split-Path $found.Inf -Leaf) $found.Id }
        else { $le = [Runtime.InteropServices.Marshal]::GetLastWin32Error(); $res.Message = T 'Windows refused (error {0})' ('{0} 0x{1:X8}' -f $le, $le) }
    } catch { $res.Message = (T 'Could not apply:') + ' ' + ($_.Exception.Message -replace '\s+', ' ') }
    return $res
}

# Saves the package of the OLD driver of one device BEFORE it is deleted (pnputil /export-driver) and records it in
# reports\rollback.csv, so that "Go back to the previous driver" can reinstall it later. Returns $true when saved.
function Save-OldDriver($Dev, [string]$Inf, [string]$InstanceId, [string]$NewVer, [string]$Stamp) {
    if ($IsWindows -eq $false -or $Inf -notmatch '^oem\d+\.inf$') { return $false }
    $safe = (($Dev.Device) -replace '[^A-Za-z0-9._-]+', '_')
    if ($safe.Length -gt 40) { $safe = $safe.Substring(0, 40) }
    $dir = Join-Path (Join-Path $script:BackupRoot ('replaced-' + $Stamp)) ($safe + '-' + ($Inf -replace '\.inf$', ''))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $r = Invoke-Pnp @('/export-driver', $Inf, $dir)
    if (-not $r.Ok -or -not (Get-ChildItem -Path $dir -Filter '*.inf' -ErrorAction SilentlyContinue)) {
        Write-Warn ('  ' + (T 'Could not save the old driver for a later rollback: {0}' ($r.Output -replace '\s+', ' ')))
        return $false
    }
    $prov = ''
    try { $prov = "$((Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_DriverProvider' -ErrorAction Stop).Data)" } catch { }
    $row = [pscustomobject]@{
        Key = [guid]::NewGuid().ToString(); Date = (Get-Date -Format 'yyyy-MM-dd HH:mm'); Device = $Dev.Device; InstanceId = $InstanceId
        ShortId = $Dev.ShortId; Class = $Dev.Class; OldInf = $Inf; OldVersion = $Dev.OldVer; OldDate = $Dev.OldDate; Provider = $prov
        NewVersion = $NewVer; BackupPath = $dir; State = 'saved'
    }
    $path = Join-Path $script:ReportDir 'rollback.csv'
    $row | Export-Csv -Path $path -Delimiter ';' -NoTypeInformation -Encoding UTF8 -Append
    Write-Ok ('  ' + (T 'Old driver saved for a later rollback: {0}' $dir))
    return $true
}

# Where "Report a problem" sends the user (the program never uploads anything). Replace OWNER with the real GitHub account before publishing.
$script:IssuesUrl = 'https://github.com/zuwann/devvy/issues/new'

# Hides MAC addresses, Bluetooth addresses, USB serial numbers and the given words (PC name, user name...) in a text.
function Hide-Text([string]$Text, $Hide) {
    $Text = [regex]::Replace($Text, '(?<![0-9A-Fa-f])([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f])', 'XX:XX:XX:XX:XX:XX')
    $Text = [regex]::Replace($Text, '(?<![0-9A-Fa-f])[0-9A-Fa-f]{12}(?![0-9A-Fa-f])', 'XXXXXXXXXXXX')
    $Text = [regex]::Replace($Text, '(USB(STOR)?\\[^\;"]*\\)([^\;"]+)', '$1<ID>', 'IgnoreCase')
    $Text = [regex]::Replace($Text, '(USBSTOR#[^#;"]*#)([^#;"]+)', '$1<ID>', 'IgnoreCase')
    foreach ($n in @($Hide)) { if ($n) { $Text = [regex]::Replace($Text, [regex]::Escape($n), '<NAME>', 'IgnoreCase') } }
    return $Text
}

# Serial number / service tag of the PC. Personal data: used ONLY to build a link that the person opens, never stored in reports or sent by the program.
function Get-PcSerial {
    $bad = 'To Be Filled|Default string|System Serial|Not Applicable|Not Specified|None|^0+$|^\s*$|O\.E\.M'
    foreach ($q in @({ (Get-CimInstance Win32_BIOS).SerialNumber }, { (Get-CimInstance Win32_ComputerSystemProduct).IdentifyingNumber })) {
        try { $v = ("$(& $q)").Trim(); if ($v -and $v -notmatch $bad) { return $v } } catch { }
    }
    return ''
}

# ---------- Profile (export / import), used by the page and by the command line ----------
function Get-DevvyProfile {
    $st = Read-Settings
    $rd = { param($n) $f = Join-Path $script:ScriptsDir $n; if (Test-Path $f) { [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8).TrimStart([char]0xFEFF) } else { '' } }
    $prof = [ordered]@{ devvy = 1; exported = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        settings = [ordered]@{ exclusions = @($st.exclusions); defender = "$($st.defender)"; backup = "$($st.backup)"; catalogConsent = [bool]$st.catalogConsent
                               inventoryAtStart = [bool]$st.inventoryAtStart; blockReinstall = [bool]$st.blockReinstall; postRebootCheck = [bool]$st.postRebootCheck; updateCheck = ($st.updateCheck -ne $false); language = "$($st.language)" }
        knowledgeUser = (& $rd 'knowledge-user.csv'); supportModelsUser = (& $rd 'support-models-user.csv') }
    return $prof
}

# Merge a profile object (exported by Get-DevvyProfile) into this installation: ADDS only. Returns $null when it is not a Devvy profile.
function Import-DevvyProfile($pr) {
    if (-not $pr -or "$($pr.devvy)" -ne '1' -or -not $pr.settings) { return $null }
    $st = Read-Settings; $done = @(); $bad = @()
    $ex = @($st.exclusions)
    foreach ($e in @($pr.settings.exclusions)) {
        $t = ("$e").Trim(); if (-not $t) { continue }
        try { $null = [regex]::new($t) } catch { $bad += $t; continue }
        if ($ex -notcontains $t) { $ex += $t }
    }
    $st.exclusions = @($ex)
    if (@('always', 'ask', 'never') -contains "$($pr.settings.defender)") { $st.defender = "$($pr.settings.defender)" }
    if (@('ask', 'full', 'drivers', 'none') -contains "$($pr.settings.backup)") { $st.backup = "$($pr.settings.backup)" }
    foreach ($k in @('catalogConsent', 'inventoryAtStart', 'blockReinstall', 'postRebootCheck', 'updateCheck')) { if ($null -ne $pr.settings.$k) { $st.$k = ($pr.settings.$k -eq $true) } }
    Save-Settings $st
    if (@($st.exclusions).Count -gt 0) { $script:ExclusionRegex = (@($st.exclusions) -join '|') }
    $mergeCsv = {
        param([string]$Name, [string]$Text, [string]$Key, [string[]]$Cols)
        if (-not "$Text".Trim()) { return 0 }
        $tmp = [IO.Path]::GetTempFileName()
        try {
            [IO.File]::WriteAllText($tmp, $Text, (New-Object Text.UTF8Encoding($true)))
            $inc = @(Import-Csv -Path $tmp -Delimiter ';' -Encoding UTF8)
        } catch { return 0 } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        if ($inc.Count -eq 0 -or -not ($inc[0].PSObject.Properties.Name -contains $Key)) { return 0 }
        $f = Join-Path $script:ScriptsDir $Name
        $cur = @(); if (Test-Path $f) { $cur = @(Import-Csv -Path $f -Delimiter ';' -Encoding UTF8) }
        $keys = @($cur | ForEach-Object { "$($_.$Key)".Trim().ToLower() }); $n = 0
        foreach ($r in $inc) {
            $kv = "$($r.$Key)".Trim().ToLower(); if (-not $kv -or $keys -contains $kv) { continue }
            $o = [ordered]@{}; foreach ($c in $Cols) { $o[$c] = "$($r.$c)" }
            $cur += [pscustomobject]$o; $keys += $kv; $n++
        }
        if ($n -gt 0) { $cur | Select-Object $Cols | Export-Csv -Path $f -Delimiter ';' -NoTypeInformation -Encoding UTF8 }
        return $n
    }
    $nk = & $mergeCsv 'knowledge-user.csv' "$($pr.knowledgeUser)" 'Id' @('Id', 'Match', 'Exclude', 'Name', 'What', 'IfNeeded', 'IfNotNeeded', 'AppRegex', 'Risk', 'Depends', 'Auto')
    $nm = & $mergeCsv 'support-models-user.csv' "$($pr.supportModelsUser)" 'Url' @('Sku', 'Model', 'Name', 'Url')
    return [ordered]@{ ok = $true; exclusions = @($st.exclusions).Count; knowledgeAdded = [int]$nk; supportAdded = [int]$nm; invalid = @($bad) }
}
