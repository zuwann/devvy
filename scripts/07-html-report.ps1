# Final HTML report (read only): before/after, outcomes of the operations, drivers to check with links to the
# Microsoft Update Catalog. Writes reports\report.html and opens it in the browser. Sends nothing: the links are
# only addresses that you open yourself.
param([switch]$NoOpen)
. "$PSScriptRoot\common.ps1"
Assert-Admin
Start-Log 'html-report'
Write-ReadOnlyBanner

function Enc([object]$s) { return [System.Net.WebUtility]::HtmlEncode([string]$s) }

function Read-CsvFile([string]$Path) {
    if (-not (Test-Path $Path)) { return @() }
    $first = Get-Content -Path $Path -TotalCount 1
    $delim = ';'
    if ($first -and ($first.Split(';').Count -lt 2) -and ($first.Split(',').Count -gt 1)) { $delim = ',' }
    return @(Import-Csv -Path $Path -Delimiter $delim)
}

# Previous CSV (latest in reports\history with that name), for the before/after comparison
function Get-Previous([string]$Name) {
    $hist = Join-Path $script:ReportDir 'history'
    if (-not (Test-Path $hist)) { return @() }
    $rx = '^' + [regex]::Escape($Name) + '-\d{8}-\d{6}\.csv$'
    $f = Get-ChildItem -Path $hist -Filter '*.csv' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $rx } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $f) { return @() }
    return (Read-CsvFile $f.FullName)
}

$dev  = Read-CsvFile (Join-Path $script:ReportDir 'devices.csv')
$drv  = Read-CsvFile (Join-Path $script:ReportDir 'drivers.csv')
$btt  = Read-CsvFile (Join-Path $script:ReportDir 'bluetooth.csv')
$ver  = Read-CsvFile (Join-Path $script:ReportDir 'drivers-to-check.csv')
$unk  = Read-CsvFile (Join-Path $script:ReportDir 'unknown.csv')
$tst  = Read-CsvFile (Join-Path $script:ReportDir 'selftest.csv')
$cat  = Read-CsvFile (Join-Path $script:ReportDir 'catalog.csv')
$dev0 = Get-Previous 'devices'
$drv0 = Get-Previous 'drivers'
$btt0 = Get-Previous 'bluetooth'

if ($dev.Count -eq 0 -and $drv.Count -eq 0 -and $btt.Count -eq 0) {
    Write-Err (T 'There are no reports to show.')
    Write-Todo @((T 'Run the full inventory first, then create the report again.'))
    Stop-Log
    exit 1
}

# ---------- Numeri prima / dopo ----------
function Count-Where($rows, [scriptblock]$f) { return @($rows | Where-Object $f).Count }
$stat = @(
    @{ N = (T 'Devices listed');        A = (Count-Where $dev0 { $true });                     B = (Count-Where $dev { $true }) },
    @{ N = (T 'Ghost devices');         A = (Count-Where $dev0 { $_.Present -eq 'NO' });      B = (Count-Where $dev { $_.Present -eq 'NO' }) },
    @{ N = (T 'Third-party driver packages'); A = (Count-Where $drv0 { $_.Origin -eq 'Third-party' }); B = (Count-Where $drv { $_.Origin -eq 'Third-party' }) },
    @{ N = (T 'Drivers with an old version');  A = (Count-Where $drv0 { $_.Versions -eq 'OldVersion' }); B = (Count-Where $drv { $_.Versions -eq 'OldVersion' }) },
    @{ N = (T 'Bluetooth pairings');        A = (Count-Where $btt0 { $true });                     B = (Count-Where $btt { $true }) }
)
$hasBefore = ($dev0.Count + $drv0.Count + $btt0.Count) -gt 0

# ---------- Outcomes: the latest file for each kind of operation ----------
$outs = @()
if (Test-Path $script:OutcomesDir) {
    $files = @(Get-ChildItem -Path $script:OutcomesDir -Filter '*.csv' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    $seen = @{}
    foreach ($f in $files) {
        $kind = ($f.BaseName -replace '-\d{8}-\d{6}$', '')
        if ($kind -like 'bt-registry*') { continue }
        if ($seen.ContainsKey($kind)) { continue }
        $seen[$kind] = 1
        $outs += [pscustomobject]@{ Kind = $kind; When = $f.LastWriteTime; Rows = (Read-CsvFile $f.FullName) }
    }
}

# ---------- Links to the Microsoft Update Catalog ----------
# The catalog has no address parameters for architecture or Windows version: it only accepts the text to
# search (q=). So: link 1 = ID only (the most reliable), link 2 = ID + Windows version as a keyword
# (may give fewer results). The architecture is checked in the driver details.
$build = 0
try { $build = [int][Environment]::OSVersion.Version.Build } catch { }
$osName = 'Windows 10'
if ($build -ge 22000) { $osName = 'Windows 11' }
$archPc = $env:PROCESSOR_ARCHITECTURE
$archCat = 'x64 (AMD64)'
if ($archPc -eq 'ARM64') { $archCat = 'ARM64' } elseif ($archPc -eq 'x86') { $archCat = 'x86' }

function Get-ShortId([string]$Id) {
    $m = [regex]::Match($Id, '(VEN_[0-9A-Fa-f]{4}&DEV_[0-9A-Fa-f]{4})')
    if ($m.Success) { return $m.Groups[1].Value.ToUpper() }
    $m = [regex]::Match($Id, '(VID_[0-9A-Fa-f]{4}&PID_[0-9A-Fa-f]{4})')
    if ($m.Success) { return $m.Groups[1].Value.ToUpper() }
    return $Id
}
function Get-CatalogUrl([string]$Query) {
    return ('https://www.catalog.update.microsoft.com/Search.aspx?q=' + [uri]::EscapeDataString($Query))
}

# ---------- Pagina ----------
$sb = New-Object System.Text.StringBuilder
function AddL([string]$s) { [void]$sb.AppendLine($s) }

AddL '<!doctype html>'
AddL ('<html lang="' + $script:Lang + '"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">')
AddL ('<title>' + (Enc (T 'Devvy report')) + '</title>')
AddL @'
<style>
:root{--bg:#fff;--fg:#1d2733;--mut:#5b6877;--line:#d9dee5;--card:#f5f7fa;--ok:#1b7f3b;--warn:#9a6700;--err:#b42318;--acc:#0b63c5}
@media (prefers-color-scheme:dark){:root{--bg:#14181d;--fg:#e6ebf1;--mut:#9aa7b5;--line:#2b333c;--card:#1c2229;--ok:#4cc77a;--warn:#e3b341;--err:#ff7b72;--acc:#6cb2ff}}
body{margin:0;padding:16px;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
main{max-width:1100px;margin:0 auto}
h1{font-size:1.5rem;margin:.2em 0}h2{font-size:1.2rem;margin:1.6em 0 .5em;border-bottom:1px solid var(--line);padding-bottom:.2em}
p.mut,.mut{color:var(--mut)}
.box{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:10px 14px;margin:10px 0}
.warn{border-left:4px solid var(--warn)}
table{border-collapse:collapse;width:100%;margin:8px 0}th,td{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);vertical-align:top}
th{color:var(--mut);font-weight:600;font-size:.85rem}
td.n{text-align:right;font-variant-numeric:tabular-nums}
.OK,.Removed{color:var(--ok)}.WARN,.Medium,.Info{color:var(--warn)}.ERROR,.High{color:var(--err)}
code{font-family:ui-monospace,Consolas,monospace;font-size:.85rem;word-break:break-all}
a{color:var(--acc)}details{margin:6px 0}summary{cursor:pointer}
.wrap{overflow-x:auto}
</style></head><body><main>
'@
AddL ('<h1>' + (Enc (T 'Devvy report')) + '</h1>')
AddL ('<p class="mut">' + (Enc (T 'Created on {0} - {1}, architecture {2}' (Get-Date -Format 'yyyy-MM-dd HH:mm') $osName $archPc)) + '</p>')
$pcI = Get-PcInfo
if ($pcI.maker) { $lap = ''; if ($pcI.laptop) { $lap = ' (' + (T 'laptop') + ')' }; AddL ('<p class="mut">' + (Enc ((T 'Computer') + ': ' + (T 'Manufacturer') + ': ' + $pcI.maker + ', ' + (T 'Model') + ': ' + $pcI.model + $lap)) + '</p>') }
AddL ('<div class="box warn"><strong>' + (Enc (T 'Privacy:')) + '</strong> ' + (Enc (T 'this file contains device names and hardware IDs of your PC. Do not share it as it is: to report a problem use the anonymized reports.')) + '</div>')

# Self-check
if ($tst.Count -gt 0) {
    $bad = @($tst | Where-Object { $_.Status -ne 'OK' })
    AddL ('<h2>' + (Enc (T 'Self-check')) + '</h2>')
    if ($bad.Count -eq 0) { AddL ('<p class="OK">' + (Enc (T 'All checks are fine.')) + '</p>') }
    else {
        AddL ('<div class="wrap"><table><tr><th>' + (Enc (T 'Status')) + '</th><th>' + (Enc (T 'Check')) + '</th><th>' + (Enc (T 'What to do')) + '</th></tr>')
        foreach ($t in $bad) { AddL ('<tr><td class="' + (Enc $t.Status) + '">' + (Enc $t.Status) + '</td><td>' + (Enc $t.Check) + ': ' + (Enc $t.Detail) + '</td><td>' + (Enc $t.WhatToDo) + '</td></tr>') }
        AddL '</table></div>'
    }
}

# Before / after
AddL ('<h2>' + (Enc (T 'Before and after')) + '</h2>')
if ($hasBefore) {
    AddL ('<p class="mut">' + (Enc (T 'Comparison between the previous inventory (reports\history) and the latest.')) + '</p>')
    AddL ('<table><tr><th>' + (Enc (T 'Item')) + '</th><th>' + (Enc (T 'Before')) + '</th><th>' + (Enc (T 'After')) + '</th></tr>')
    foreach ($s in $stat) { AddL ('<tr><td>' + (Enc $s.N) + '</td><td class="n">' + $s.A + '</td><td class="n">' + $s.B + '</td></tr>') }
    AddL '</table>'
} else {
    AddL ('<p class="mut">' + (Enc (T 'There is only one inventory: after the changes run the inventory again and this table will show the comparison.')) + '</p>')
    AddL ('<table><tr><th>' + (Enc (T 'Item')) + '</th><th>' + (Enc (T 'Now')) + '</th></tr>')
    foreach ($s in $stat) { AddL ('<tr><td>' + (Enc $s.N) + '</td><td class="n">' + $s.B + '</td></tr>') }
    AddL '</table>'
}

# Outcomes
AddL ('<h2>' + (Enc (T 'What was done')) + '</h2>')
if ($outs.Count -eq 0) { AddL ('<p class="mut">' + (Enc (T 'No operation recorded yet.')) + '</p>') }
foreach ($e in $outs) {
    AddL ('<h3>' + (Enc $e.Kind) + ' <span class="mut">(' + (Enc $e.When.ToString('dd/MM/yyyy HH:mm')) + ')</span></h3>')
    $grp = @($e.Rows | Group-Object Outcome | Sort-Object Count -Descending)
    AddL ('<table><tr><th>' + (Enc (T 'Outcome')) + '</th><th>' + (Enc (T 'Items')) + '</th></tr>')
    foreach ($g in $grp) { AddL ('<tr><td>' + (Enc $g.Name) + '</td><td class="n">' + $g.Count + '</td></tr>') }
    AddL '</table>'
    AddL ('<details><summary>' + (Enc (T 'Full list ({0})' @($e.Rows).Count)) + '</summary><div class="wrap"><table><tr><th>' + (Enc (T 'Item')) + '</th><th>' + (Enc (T 'Outcome')) + '</th></tr>')
    foreach ($r in $e.Rows) { AddL ('<tr><td>' + (Enc $r.What) + '</td><td>' + (Enc $r.Outcome) + '</td></tr>') }
    AddL '</table></div></details>'
}

# Drivers to check + catalog
AddL ('<h2>' + (Enc (T 'Drivers to check')) + '</h2>')
if ($ver.Count -eq 0) {
    AddL ('<p class="mut">' + (Enc (T 'No data yet: run Drivers to check, then create the report again.')) + '</p>')
} else {
    AddL ('<div class="box"><strong>' + (Enc (T 'How to use the Microsoft Update Catalog links.')) + '</strong> ' + (Enc (T 'The catalog cannot filter by address: it only searches by text. Link 1 searches the hardware ID (the most reliable). Link 2 adds the keyword "{0}" to narrow it down (it may give fewer results). In the results choose the row that fits your system: {0}, architecture {1} (see Details, Overview tab), most recent date. The catalog offers a file to download and install by hand. For BIOS and firmware use the PC maker website.' $osName $archCat)) + '</div>')
    $order = @{ 'High' = 0; 'Medium' = 1; 'Info' = 2 }
    $rows = @($ver | Sort-Object @{ Expression = { $order[[string]$_.Severity] } }, Device)
    AddL ('<div class="wrap"><table><tr><th>' + (Enc (T 'Severity')) + '</th><th>' + (Enc (T 'Device')) + '</th><th>' + (Enc (T 'Why')) + '</th><th>Windows Update</th><th>' + (Enc (T 'Catalog')) + '</th></tr>')
    foreach ($v in $rows) {
        $ids = @(([string]$v.HardwareId) -split '\s*\|\s*' | Where-Object { $_ })
        $first1 = ''
        if ($ids.Count -gt 0) { $first1 = $ids[0] }
        $wuTxt = [string]$v.WindowsUpdate
        if ($v.WU_Title) { $wuTxt = $wuTxt + ': ' + $v.WU_Title + ' (' + $v.WU_Date + ')' }
        $link = '<span class="mut">' + (Enc (T 'no hardware ID')) + '</span>'
        if ($first1) {
            $short = Get-ShortId $first1
            $l1 = Get-CatalogUrl $short
            $l2 = Get-CatalogUrl ($short + ' ' + $osName)
            $link = '<a href="' + (Enc $l1) + '" target="_blank" rel="noopener">' + (Enc (T 'link 1')) + '</a> &middot; <a href="' + (Enc $l2) + '" target="_blank" rel="noopener">' + (Enc (T 'link 2')) + '</a><br><code>' + (Enc $short) + '</code>'
            if ($short -ne $first1) { $link = $link + '<br><span class="mut">' + (Enc (T 'Full ID:')) + '</span> <code>' + (Enc $first1) + '</code>' }
        }
        $oemN = Get-OemNote ([string]$v.Class) (([string]$v.Device) + ' ' + ([string]$v.DriverProvider))
        $oemH = ''; if ($oemN) { $oemH = '<br><strong>' + (Enc (T 'OEM device')) + ':</strong> ' + (Enc $oemN) }
        AddL ('<tr><td class="' + (Enc $v.Severity) + '">' + (Enc $v.Severity) + '</td><td>' + (Enc $v.Device) + $oemH + '<br><span class="mut">' + (Enc $v.Class) + ' - ' + (Enc (T 'driver')) + ' ' + (Enc $v.DriverProvider) + ' ' + (Enc $v.DriverVersion) + ' (' + (Enc $v.DriverDate) + ')</span></td><td>' + (Enc (Convert-ReasonText ([string]$v.Reason))) + '</td><td>' + (Enc $wuTxt) + '</td><td>' + $link + '</td></tr>')
    }
    AddL '</table></div>'
}

# Catalog search results
if ($cat.Count -gt 0) {
    AddL ('<h2>' + (Enc (T 'Microsoft catalog results')) + '</h2>')
    AddL ('<div class="box warn">' + (Enc (T 'Packages found by the automatic search. On a branded PC the maker driver, with the ID of your model, takes precedence: a generic "newer" package is often not used by Windows. Update from here only if you have a real problem and make the backup first.')) + '</div>')
    AddL ('<div class="wrap"><table><tr><th>' + (Enc (T 'Device')) + '</th><th>' + (Enc (T 'Current driver')) + '</th><th>' + (Enc (T 'Package found')) + '</th><th>' + (Enc (T 'Date')) + '</th><th>' + (Enc (T 'Architecture')) + '</th><th>' + (Enc (T 'Newer?')) + '</th><th>' + (Enc (T 'Note')) + '</th></tr>')
    foreach ($c in $cat) {
        $tit = Enc $c.Title
        $nameLink = T 'open the search'
        if ($c.Title) { $nameLink = $c.Title }
        $lnk = $c.Link
        if ($c.SearchLink) { $lnk = $c.SearchLink }
        if ($lnk) { $tit = '<a href="' + (Enc $lnk) + '" target="_blank" rel="noopener">' + (Enc $nameLink) + '</a>' }
        AddL ('<tr><td>' + (Enc $c.Device) + '<br><code>' + (Enc $c.ShortId) + '</code></td><td>' + (Enc $c.CurrentDriver) + '</td><td>' + $tit + '<br><span class="mut">' + (Enc $c.Version) + '</span></td><td>' + (Enc $c.Date) + '</td><td>' + (Enc $c.Architecture) + '</td><td>' + (Enc $c.NewerThanCurrent) + '</td><td>' + (Enc $c.Note) + '</td></tr>')
    }
    AddL '</table></div>'
}

# Unknown components
if ($unk.Count -gt 0) {
    AddL ('<h2>' + (Enc (T 'Components without advice')) + '</h2>')
    AddL ('<p class="mut">' + (Enc (T '{0} packages are not in the knowledge base (reports\unknown.csv, with hardware IDs and .inf file to identify them). If you know what they are, fill in the columns and paste the rows into scripts\knowledge-user.csv.' $unk.Count)) + '</p>')
}

AddL ('<p class="mut" style="margin-top:2em">' + (Enc (T 'Experimental tool, use at your own risk (see DISCLAIMER.txt). Always check before installing drivers downloaded from other sources.')) + '</p>')
AddL '</main></body></html>'

$out = Join-Path $script:ReportDir 'report.html'
Set-Content -Path $out -Value $sb.ToString() -Encoding UTF8
Write-Ok (T 'Report created: {0}' $out)

if (-not $NoOpen) {
    try { Start-Process -FilePath $out } catch { Write-Warn (T 'Cannot open it automatically: double-click the file. ({0})' $_.Exception.Message) }
}
Write-Todo @(
    (T 'The report opened in the browser: check What was done and Drivers to check.'),
    (T 'For a driver to update: use the Updates tab, or open link 1 of the catalog, choose the row with your Windows version and architecture {0} and the most recent date, download and install by hand.' $archCat)
)
Stop-Log
exit 0
