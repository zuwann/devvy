# Search (READ ONLY) of the Microsoft Update Catalog for the drivers listed in reports\drivers-to-check.csv.
# It does not download or install anything: it writes reports\catalog.csv with the packages found (title, date,
# version, architecture, link). The catalog has no official API: the web page is read, so it may stop working.
# Privacy: only the search text (VEN_xxxx&DEV_xxxx[&SUBSYS_xxxxxxxx] or VID_xxxx&PID_xxxx) is sent to the catalog, never serials or names.
param([int]$Max = 12, [switch]$SkipConfirm)
. "$PSScriptRoot\common.ps1"
Assert-Admin
Start-Log 'catalog-search'
Write-ReadOnlyBanner
if (-not (Test-Internet)) {
    Write-Err (T 'No internet connection')
    Write-Todo @(T 'Connect the PC to the network (Wi-Fi or cable), check that a web page opens, then try again.')
    Stop-Log
    exit 2
}

$rows = @(Read-ReportCsv 'drivers-to-check')
if ((Test-Path (Join-Path $script:ReportDir 'drivers-to-check.csv')) -and $rows.Count -eq 0) {
    Write-Ok (T 'No driver to search in the catalog: nothing to check (devices excluded by you are not searched).')
    # an empty result file: the page then knows the search was done and found nothing
    try { Set-Content -Path (Join-Path $script:ReportDir 'catalog.csv') -Encoding UTF8 -Value '"Device";"Class";"ShortId";"CurrentDriver";"UpdateId";"Title";"Date";"Version";"Products";"FitsSystem";"Architecture";"NewerThanCurrent";"Link";"SearchLink";"Note"' } catch { }
    Stop-Log
    exit 0
}
if ($rows.Count -eq 0) {
    Write-Err (T 'The list of drivers to check does not exist yet.')
    Write-Todo @(T 'Run the driver check first, then repeat this search.')
    Stop-Log
    exit 1
}

$build = 0
try { $build = [int][Environment]::OSVersion.Version.Build } catch { }
$isWin11 = ($build -ge 22000)
$osName = 'Windows 10'
if ($isWin11) { $osName = 'Windows 11' }
# Windows feature versions by build: a package "for version X and later" only fits builds from X on
$verByBuild = @(
    @(26200, 2509), @(26100, 2409), @(22631, 2309), @(22621, 2209), @(22000, 2109),
    @(19045, 2209), @(19044, 2109), @(19043, 2103), @(19042, 2009), @(19041, 2004), @(18363, 1909), @(18362, 1903), @(17763, 1809))
$curVer = 0
foreach ($e in $verByBuild) { if ($build -ge $e[0]) { $curVer = $e[1]; break } }
function ConvertTo-VerNum([string]$V) {
    # "24H2" -> 2409, "22H2" -> 2209 (same scale as the table above: year*100 + 3 for H1, 9 for H2), "2004" -> 2004, "1903" -> 1903
    if ($V -match '^(\d{2})H(\d)$') { $y = [int]$Matches[1]; $h = [int]$Matches[2]; return ($y * 100 + $(if ($h -eq 1) { 3 } else { 9 })) }
    if ($V -match '^\d{4}$') { return [int]$V }
    return 0
}
# Does the "Products" text of a catalog row fit this PC? Any of the listed products is enough.
# The catalog lists several products in one cell ("Windows 10, Vibranium and later, Servicing Drivers Windows 11 Client, version 22H2 and later, ...",
# "Windows - Client, version 21H2 and later" = Windows 10 21H2+ and Windows 11): split at every "Windows" that starts a product.
function Test-ProductFits([string]$Products) {
    foreach ($part in ($Products -split '\s*;\s*|\s+(?=Windows\b)')) {
        if (-not $part) { continue }
        $isW11 = ($part -match 'Windows 11'); $isW10 = ($part -match 'Windows 10')
        if (-not $isW11 -and -not $isW10 -and $part -notmatch 'Windows\s*-\s*Client') { continue }
        if ($isW11 -and -not $isWin11) { continue }
        if ($isW10 -and -not $isW11 -and $isWin11 -and $part -notmatch 'and later') { continue }
        $ok = $true
        $need = 0
        if ($part -match '(?i)version\s+(\d{2}H\d|\d{4})') { $need = ConvertTo-VerNum $Matches[1] }
        elseif ($part -match '(?i)Vibranium') { $need = 2004 }
        if ($need -gt 0 -and $curVer -gt 0 -and $need -gt $curVer -and $part -match '(?i)and later') { $ok = $false }
        if ($ok) { return $true }
    }
    return $false
}
$pcArch = $env:PROCESSOR_ARCHITECTURE
$archRx = 'AMD64|x64'
if ($pcArch -eq 'ARM64') { $archRx = 'ARM64' } elseif ($pcArch -eq 'x86') { $archRx = 'x86' }

function Get-ShortId([string]$Id) {
    $m = [regex]::Match($Id, '(VEN_[0-9A-Fa-f]{4}&DEV_[0-9A-Fa-f]{4})')
    if ($m.Success) { return $m.Groups[1].Value.ToUpper() }
    $m = [regex]::Match($Id, '(VID_[0-9A-Fa-f]{4}&PID_[0-9A-Fa-f]{4})')
    if ($m.Success) { return $m.Groups[1].Value.ToUpper() }
    return ''
}
# The most specific code we may send: with the subsystem (maker of the board/card) or the interface number of a USB child device.
function Get-SpecificId([string]$Id) {
    $m = [regex]::Match($Id, '(VEN_[0-9A-Fa-f]{4}&DEV_[0-9A-Fa-f]{4}&SUBSYS_[0-9A-Fa-f]{8})')
    if ($m.Success) { return $m.Groups[1].Value.ToUpper() }
    $m = [regex]::Match($Id, '(VID_[0-9A-Fa-f]{4}&PID_[0-9A-Fa-f]{4}&MI_[0-9A-Fa-f]{2})')
    if ($m.Success) { return $m.Groups[1].Value.ToUpper() }
    return ''
}
function Strip-Html([string]$s) {
    $x = [regex]::Replace($s, '<[^>]+>', ' ')
    $x = [System.Net.WebUtility]::HtmlDecode($x)
    return ([regex]::Replace($x, '\s+', ' ')).Trim()
}

# Reads the result rows from the search page (raw HTML). Returns objects with UpdateId, Title, ...
function Read-CatalogResults([string]$Html) {
    $out = New-Object System.Collections.Generic.List[object]
    $rx = [regex]'(?is)<tr[^>]*id="([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})_R\d+"[^>]*>(.*?)</tr>'
    foreach ($m in $rx.Matches($Html)) {
        $id = $m.Groups[1].Value
        $body = $m.Groups[2].Value
        $cells = @()
        foreach ($c in ([regex]::Matches($body, '(?is)<td[^>]*>(.*?)</td>'))) {
            $cells += (Strip-Html $c.Groups[1].Value)
        }
        $cells = @($cells | Where-Object { $_ -ne '' })
        if ($cells.Count -lt 5) { continue }
        # column order of the catalog: Title, Products, Classification, Last updated, Version, Size
        $d = $null
        $dateOk = $false
        foreach ($c in $cells) {
            $tmp = [datetime]::MinValue
            if ([datetime]::TryParseExact($c, [string[]]@('M/d/yyyy', 'MM/dd/yyyy'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$tmp)) { $d = $tmp; $dateOk = $true; break }
        }
        $ver = ''
        if ($cells.Count -ge 5) { $ver = $cells[4] }
        # driver rows show "n/a" in the Version column: the version is the last number group of the title ("Maker - Class - 1.2.3.4")
        if ($ver -notmatch '^\d+(\.\d+)+$' -and $cells[0] -match '(\d+(\.\d+){2,3})\s*$') { $ver = $Matches[1] }
        $dateText = ''
        if ($dateOk) { $dateText = $d.ToString('yyyy-MM-dd') }
        # size of the download (last column, e.g. "9.4 MB"): shown in the Updates tab
        $sizeText = ''
        foreach ($c in $cells) { if ($c -match '^(\d[\d.,]*)\s*(KB|MB|GB)') { $sizeText = $Matches[1] + ' ' + $Matches[2] } }
        # fallback: the size may sit in a cell the filter above dropped or be glued to a hidden value: look in the whole row text
        if (-not $sizeText) { $ms = [regex]::Matches((Strip-Html $body), '(\d[\d.,]*)\s*(KB|MB|GB)'); if ($ms.Count -gt 0) { $lm = $ms[$ms.Count - 1]; $sizeText = $lm.Groups[1].Value + ' ' + $lm.Groups[2].Value } }
        $out.Add([pscustomobject]@{
            UpdateId = $id; Title = $cells[0]; Products = $cells[1]; Classification = $cells[2]
            Date = $dateText; DateValid = $dateOk; DateObj = $d; Version = $ver; Size = $sizeText
        })
    }
    return $out
}

function Get-Architecture([string]$UpdateId) {
    try {
        $url = 'https://www.catalog.update.microsoft.com/ScopedViewInline.aspx?updateid=' + $UpdateId
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $txt = Strip-Html ([string]$r.Content)
        $m = [regex]::Match($txt, '(?i)Architecture:?\s*([A-Za-z0-9 ,/]{2,40}?)\s+(Classification|Supported|Last|Languages|MSRC|Description|$)')
        if ($m.Success) { return $m.Groups[1].Value.Trim() }
    } catch { }
    return ''
}

# Builds one result row (same columns everywhere)
function New-ResultRow($Dev, [string]$Url, $Pkg, [string]$FitsSystem, [string]$Arch, [string]$Newer, [string]$Note) {
    $link = $Url
    $id = ''; $title = ''; $date = ''; $ver = ''; $prod = ''; $size = ''
    if ($Pkg) {
        $id = $Pkg.UpdateId; $title = $Pkg.Title; $date = $Pkg.Date; $ver = $Pkg.Version; $prod = $Pkg.Products; $size = "$($Pkg.Size)"
        $link = 'https://www.catalog.update.microsoft.com/ScopedViewInline.aspx?updateid=' + $Pkg.UpdateId
    }
    return [pscustomobject][ordered]@{
        Device = $Dev.Name; Class = $Dev.Class; ShortId = $Dev.ShortId; CurrentDriver = ($Dev.DriverVersion + ' ' + $Dev.DriverDate)
        UpdateId = $id; Title = $title; Date = $date; Version = $ver; Size = $size; Products = $prod; FitsSystem = $FitsSystem
        Architecture = $Arch; NewerThanCurrent = $Newer; Link = $link; SearchLink = $Url; Note = $Note
    }
}

# ---------- Consent: this is the only step of the tool that talks to the catalog ----------
Write-Host ''
Write-Host ('  ' + (T 'SEARCH IN THE MICROSOFT UPDATE CATALOG') + '  ') -ForegroundColor Black -BackgroundColor Cyan
Write-Info ('  ' + (T 'For each driver in the list I search the catalog (catalog.update.microsoft.com) using ONLY the hardware code'))
Write-Info ('  ' + (T 'of the type VEN_xxxx&DEV_xxxx[&SUBSYS_xxxxxxxx] or VID_xxxx&PID_xxxx. I do not send names, serial numbers, PC name or user name.'))
Write-Info ('  ' + (T 'I do not download or install anything here: I only list the packages found, with date, version and architecture.'))
Write-Warn ('  ' + (T 'The catalog is not meant to be used by programs: if Microsoft changes the page, the search may stop working.'))
if (-not $SkipConfirm) {
    $k = Read-Choice ('  ' + (T 'Go ahead?  [Y] Yes  [N] No')) @('Y', 'N')
    if ($k -ne 'Y') { Write-Info ('  ' + (T 'Search cancelled: nobody was contacted.')); Stop-Log; exit 0 }
}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

# one single search for each short ID
$devs = @()
foreach ($r in $rows) {
    if (Test-Excluded ('{0} {1} {2} {3}' -f $r.Device, $r.DriverProvider, $r.InstanceId, $r.HardwareId) $r.Class) { continue }
    $ids = @(([string]$r.HardwareId) -split '\s*\|\s*' | Where-Object { $_ })
    $short = ''
    foreach ($i in $ids) { $c = Get-ShortId $i; if ($c) { $short = $c; break } }
    if (-not $short) { continue }
    $spec = ''
    foreach ($i in $ids) { $c = Get-SpecificId $i; if ($c -and $c.StartsWith($short)) { $spec = $c; break } }
    $devs += [pscustomobject]@{ ShortId = $short; Spec = $spec; Name = [string]$r.Device; Class = [string]$r.Class; Severity = [string]$r.Severity
                                DriverDate = [string]$r.DriverDate; DriverVersion = [string]$r.DriverVersion; Provider = [string]$r.DriverProvider }
}
$order = @{ 'High' = 0; 'Medium' = 1; 'Info' = 2 }
$devs = @($devs | Sort-Object @{ Expression = { $order[$_.Severity] } }, Name)
$seen = @{}
$list = @()
foreach ($d in $devs) { $key = $d.ShortId + '|' + $d.Spec; if (-not $seen.ContainsKey($key)) { $seen[$key] = 1; $list += $d } }
if ($list.Count -gt $Max) {
    Write-Warn ('  ' + (T 'I search only the first {0} of {1} (the most important): use -Max to change this.' $Max $list.Count))
    $list = @($list | Select-Object -First $Max)
}

# driver packages already in the driver store (a catalog package with the same version and maker is not an update: it is already installed, often as an extension of the device)
$instPk = @(Read-ReportCsv 'drivers')
$results = New-Object System.Collections.Generic.List[object]
$errors = 0
$n = 0
foreach ($d in $list) {
    $n++
    Write-Prog ($n - 1) $list.Count
    Write-Host ('  [{0}/{1}] {2} ({3})...' -f $n, $list.Count, $d.Name, $d.ShortId) -ForegroundColor Green
    # first the exact code (with the subsystem), then the generic one of the chip: the exact one shows only packages made for this very board
    $queries = @(); if ($d.Spec) { $queries += $d.Spec }; $queries += $d.ShortId
    $url = ''; $found = @(); $fitting = @(); $matchKind = ''; $lastErr = ''; $anyOk = $false
    foreach ($q in $queries) {
        $url = 'https://www.catalog.update.microsoft.com/Search.aspx?q=' + [uri]::EscapeDataString($q)
        $html = ''
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 40 -ErrorAction Stop
            $html = [string]$resp.Content; $anyOk = $true
        } catch {
            $lastErr = ($_.Exception.Message -replace '\s+', ' ')
            Write-Warn ('      ' + (T 'I cannot read the catalog: {0}' $lastErr))
            continue
        }
        $found = @(Read-CatalogResults $html)
        $fitting = @($found | Where-Object { Test-ProductFits $_.Products } | Sort-Object @{ Expression = { $_.DateObj }; Descending = $true })
        # the catalog lists the same driver once per product set: show each title and date only once
        $seenT = @{}; $fitting = @($fitting | Where-Object { $k = $_.Title + '|' + $_.Date; if ($seenT.ContainsKey($k)) { $false } else { $seenT[$k] = 1; $true } })
        if ($fitting.Count -gt 0) { if ($q -eq $d.Spec) { $matchKind = 'exact' } else { $matchKind = 'generic' }; break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $anyOk) {
        $errors++
        $results.Add((New-ResultRow $d $url $null '' '' '' (T 'Catalog reading error: open the link by hand')))
        continue
    }
    if ($found.Count -eq 0) {
        Write-Info ('      ' + (T 'No results (or a page format I do not recognize).'))
        $results.Add((New-ResultRow $d $url $null '' '' '' (T 'No recognized result: open the link by hand to check')))
        Start-Sleep -Milliseconds 800
        continue
    }
    $cur = [datetime]::MinValue
    $curOk = [datetime]::TryParseExact($d.DriverDate, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$cur)
    $top = @($fitting | Select-Object -First 3)
    if ($top.Count -eq 0) {
        Write-Info ('      ' + (T 'Found {0} packages, but none is for {1}.' $found.Count $osName))
        $results.Add((New-ResultRow $d $url $null 'NO' '' '' (T 'Found {0} packages, none for {1}' $found.Count $osName)))
        Start-Sleep -Milliseconds 800
        continue
    }
    foreach ($f in $top) {
        $arch = Get-Architecture $f.UpdateId
        $archOk = ''
        if ($arch) { if ($arch -match $archRx) { $archOk = 'YES' } else { $archOk = 'NO' } }
        $newer = ''
        if ($f.DateValid -and $curOk) { if ($f.DateObj -gt $cur) { $newer = 'YES' } else { $newer = 'NO' } }
        # same version number in the title as the installed driver: not an update, whatever the date says
        if ($d.DriverVersion -and $f.Title -and $f.Title.Contains([string]$d.DriverVersion)) { $newer = 'NO' }
        $inStore = $false
        if ($newer -ne 'NO' -and $f.Version) {
            foreach ($ip in $instPk) {
                if ("$($ip.Version)" -ne "$($f.Version)") { continue }
                $pv = (("$($ip.Provider)" -split '[^A-Za-z0-9]')[0])
                if ($pv.Length -ge 3 -and $f.Title -match [regex]::Escape($pv)) { $inStore = $true; break }
            }
            if ($inStore) { $newer = 'NO' }
        }
        $note = ''
        if ($inStore) { $note = T 'Already in the driver store (same version and maker): installing it again changes nothing.' }
        elseif ($archOk -eq 'NO') { $note = T 'Architecture different from your PC ({0}): not suitable' $pcArch }
        elseif ($newer -eq 'NO') { $note = T 'Not newer than the installed driver' }
        elseif ($newer -eq 'YES' -and $archOk -ne 'NO') { $note = T 'Newer: check that it comes from the right maker before installing it' }
        if ($matchKind -eq 'exact') { $note = ((T 'Exact match: made for this very hardware.') + ' ' + $note).Trim() }
        elseif ($matchKind -eq 'generic') { $note = ((T 'Generic match: same chip, any maker of the board.') + ' ' + $note).Trim() }
        $results.Add((New-ResultRow $d $url $f 'YES' $arch $newer $note))
        Start-Sleep -Milliseconds 500
    }
    Write-Info ('      ' + (T '{0} packages fit {1}; I report {2}.' $fitting.Count $osName $top.Count))
    if ($matchKind -eq 'exact') { Write-Info ('      ' + (T 'Exact match: made for this very hardware.')) }
    Start-Sleep -Milliseconds 800
}

$path = Save-ReportCsv $results 'catalog'
$newerCount = @($results | Where-Object { $_.NewerThanCurrent -eq 'YES' -and $_.FitsSystem -eq 'YES' -and $_.Architecture -notmatch 'x86|ARM' }).Count
Write-Host ''
Write-Ok ('  ' + (T 'Report:') + ' ' + $path)
Write-Info ('  ' + (T 'Packages newer than the installed driver: {0}   Reading errors: {1}' $newerCount $errors))
if ($errors -gt 0) { Write-Warn ('  ' + (T 'Some searches failed (no connection or the page changed): the report has the link to open by hand.')) }
Write-Todo @(
    (T 'Open the Updates tab: the packages found are listed there.'),
    (T 'A "newer" package is NOT automatically better: on a branded laptop the maker driver (with your model ID) has priority and Windows will not use the generic one. Update only if you have a real problem.'),
    (T 'Back up before installing anything from the catalog.')
)
Stop-Log
exit 0
