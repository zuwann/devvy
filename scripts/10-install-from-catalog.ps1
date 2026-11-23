# Installs the drivers chosen from the Microsoft Update Catalog (reports\selection.json, written by the web page).
# For each package: downloads the .cab from the catalog (Microsoft sites only), checks it, opens it, installs it
# with pnputil and then RE-READS which driver the device really uses (Windows may keep the previous one).
# If Windows keeps the old driver the user can choose to replace it completely: stop the old driver's
# services, bind the new driver, then delete the old package so that after a restart only the new one is found.
# With -SaveOld (the user chose a driver backup) the old package of each replaced device is exported first, so it can be restored
# one device at a time (26-rollback-driver.ps1). Without -Apply it only previews. The backup is asked and made by the caller BEFORE this script.
param([switch]$Apply, [switch]$SaveOld)
. "$PSScriptRoot\common.ps1"
Assert-Admin
Start-Log 'catalog-install'
Write-ModeBanner $Apply

$selPath = Join-Path $script:ReportDir 'selection.json'
if (-not (Test-Path $selPath)) {
    Write-Warn (T 'NO catalog driver selected (or the selection was already used): nothing was downloaded or installed. Go to Updates, choose the package, press Save the catalog selection and try again.')
    Stop-Log
    exit 0
}
$sel = @()
# In PowerShell 5.1 ConvertFrom-Json returns an array as ONE object: the pipeline splits it into the single items
try { $sel = @((Get-Content -Path $selPath -Raw | ConvertFrom-Json) | ForEach-Object { $_ }) } catch { }
if ($sel.Count -eq 0) { Write-Warn (T 'The selection is empty: nothing was downloaded or installed.'); Stop-Log; exit 0 }
if ($Apply) {
if (-not (Test-Internet)) {
    Write-Err (T 'No internet connection')
    Write-Todo @(T 'Connect the PC to the network (Wi-Fi or cable), check that a web page opens, then try again.')
    Stop-Log
    exit 2
}
}

# Classes where a wrong driver can stop the PC from starting or turn the screen off: they need the explicit OK chosen in the page
$riskClasses = @('Display', 'System', 'Firmware', 'SCSIAdapter', 'HDC', 'Processor', 'USB', 'Net')
$hostOk = '(^|\.)(microsoft\.com|windowsupdate\.com|delivery\.mp\.microsoft\.com)$'
# Windows services that must never be stopped
$neverStop = '^(winmgmt|rpcss|dcomlaunch|lsm|samss|eventlog|plugplay|power|profsvc|schedule|themes|audiosrv|audioendpointbuilder|bits|wuauserv|trustedinstaller|cryptsvc|dnscache|dhcp|netprofm|nlasvc|lanmanserver|lanmanworkstation|bfe|mpssvc|wscsvc|windefend|sense)$'

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }


$saveStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
function Save-Before($s, $b) {
    if (-not $SaveOld) { return }
    $dv = [pscustomobject]@{ Device = $s.Device; ShortId = $s.ShortId; Class = $s.Class; OldVer = $b.Ver; OldDate = $b.Date }
    $null = Save-OldDriver $dv $b.Inf $b.Id $s.Version $saveStamp
}

# Stops the background services installed by the OLD driver package (so that nothing keeps its files busy or puts it back).
# Only real services (own process) that are running; kernel drivers and Windows core services are never touched.
function Stop-OldDriverServices([string]$OldInf) {
    $stopped = @()
    if ($IsWindows -eq $false -or $OldInf -notmatch '^oem\d+\.inf$') { return $stopped }
    $orig = ''
    try { $orig = (Get-DriverPackages | Where-Object { $_.Driver -eq $OldInf } | Select-Object -First 1).OriginalFileName } catch { }
    if (-not $orig -or -not (Test-Path $orig)) { return $stopped }
    $txt = ''
    try { $txt = Get-Content -Path $orig -Raw -ErrorAction Stop } catch { return $stopped }
    $names = @()
    foreach ($m in [regex]::Matches($txt, '(?im)^\s*AddService\s*=\s*"?([A-Za-z0-9_.\-]+)"?')) { $names += $m.Groups[1].Value }
    foreach ($n in @($names | Select-Object -Unique)) {
        if ($n -match $neverStop) { continue }
        try {
            $svc = Get-CimInstance -ClassName Win32_Service -Filter ("Name='" + $n + "'") -ErrorAction Stop
            if ($svc -and $svc.State -eq 'Running' -and "$($svc.ServiceType)" -match 'Own Process|Share Process') {
                Stop-Service -Name $n -Force -ErrorAction Stop
                $stopped += $n
            }
        } catch { }
    }
    return $stopped
}

# A CAB file starts with the 4 bytes "MSCF"
function Test-CabFile([string]$Path) {
    if (-not (Test-Path $Path)) { return $false }
    try {
        $fs = [IO.File]::OpenRead($Path)
        $b = New-Object byte[] 4
        $n = $fs.Read($b, 0, 4)
        $fs.Close()
        return ($n -eq 4 -and $b[0] -eq 0x4D -and $b[1] -eq 0x53 -and $b[2] -eq 0x43 -and $b[3] -eq 0x46)
    } catch { return $false }
}

# Once a device uses the new driver, drop it from the saved "to check" and "catalog" lists so the Updates page does not show stale data
function Clear-DoneDevice($Sel) {
    try { foreach ($ds in @(Get-DriverState $Sel.ShortId)) { Save-PinnedDriver "$($Sel.Device)" "$($Sel.ShortId)" "$($ds.Id)" "$($ds.Ver)" "$($ds.Inf)" "$($ds.Date)" } } catch { }
    foreach ($spec in @(@('catalog', 'ShortId', "$($Sel.ShortId)"), @('drivers-to-check', 'Device', "$($Sel.Device)"))) {
        try {
            $f = Join-Path $script:ReportDir ($spec[0] + '.csv')
            if (-not (Test-Path $f)) { continue }
            $rows = @(Import-Csv -Path $f -Delimiter ';')
            $keep = @($rows | Where-Object { "$($_.($spec[1]))" -ne $spec[2] })
            if ($keep.Count -ne $rows.Count) {
                if ($keep.Count -gt 0) { $keep | Export-Csv -Path $f -Delimiter ';' -NoTypeInformation -Encoding UTF8 } else { Remove-Item -Path $f -Force }
            }
        } catch { }
    }
}

# Several packages: download them all at the same time first (3 at once); the checks and the installation stay one by one below.
# A package that fails here is simply tried again, with the usual messages, when its turn comes.
if ($Apply) {
    $want = @()
    foreach ($s0 in $sel) {
        $id0 = "$($s0.UpdateId)".Trim()
        if ($id0 -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { continue }
        if (Test-Excluded ('{0} {1}' -f $s0.Device, $s0.Title) $s0.Class) { continue }
        if (($riskClasses -contains "$($s0.Class)") -and -not $s0.RiskAccepted) { continue }
        $dir0 = Join-Path $script:ReportDir ('catalog-downloads\' + $id0)
        if (Test-CabFile (Join-Path $dir0 'package.cab')) { continue }
        $want += [pscustomobject]@{ Short = "$($s0.ShortId)"; Id = $id0; Dir = $dir0 }
    }
    if ($want.Count -gt 1) {
        Write-Ok (T 'Downloading {0} packages at the same time (they are installed one by one afterwards)...' $want.Count)
        $dlBlock = {
            param($Short, $Id, $Dir, $HostOk)
            $ErrorActionPreference = 'SilentlyContinue'
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
            $ProgressPreference = 'SilentlyContinue'
            New-Item -ItemType Directory -Force -Path $Dir | Out-Null
            $cab = Join-Path $Dir 'package.cab'
            $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
            $web = New-Object Microsoft.PowerShell.Commands.WebRequestSession
            $searchUrl = 'https://www.catalog.update.microsoft.com/Search.aspx?q=' + [uri]::EscapeDataString($Short)
            try { $null = Invoke-WebRequest -Uri $searchUrl -WebSession $web -UserAgent $ua -UseBasicParsing -TimeoutSec 60 } catch { }
            $post = '[{"size":0,"languages":"","uidInfo":"' + $Id + '","updateID":"' + $Id + '"}]'
            $body = @{ updateIDs = $post; updateIDsBlockedForImport = ''; wsusApiPresent = ''; contentImport = ''; sku = ''; serverName = ''; ssl = ''; portNumber = ''; version = '' }
            $html = ''
            try {
                $resp = Invoke-WebRequest -Uri 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' -Method Post -Body $body -WebSession $web -UserAgent $ua `
                    -Headers @{ Referer = $searchUrl; Origin = 'https://www.catalog.update.microsoft.com' } -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
                $html = [string]$resp.Content
            } catch { return }
            $norm = $html.Replace('&amp;', '&').Replace('\/', '/')
            $urls = @()
            foreach ($m in [regex]::Matches($norm, 'downloadInformation\[\d+\]\.files\[\d+\]\.url\s*=\s*[''"]([^''"]+)[''"]')) { $urls += $m.Groups[1].Value }
            if ($urls.Count -eq 0) {
                foreach ($m in [regex]::Matches($norm, 'https?://[^''"\s<>\\]+')) {
                    if ($m.Value -match '\.(js|css|aspx|png|gif|ico)(\?|$)') { continue }
                    if ($urls -notcontains $m.Value) { $urls += $m.Value }
                }
            }
            $urls = @($urls | Where-Object { $h = ''; try { $h = ([uri]$_).Host } catch { }; $h -match $HostOk })
            foreach ($u in $urls) {
                $tmp = Join-Path $Dir 'download-parallel.tmp'
                try { Invoke-WebRequest -Uri $u -OutFile $tmp -WebSession $web -UserAgent $ua -UseBasicParsing -TimeoutSec 900 -ErrorAction Stop } catch { continue }
                $ok = $false
                try { $fs = [IO.File]::OpenRead($tmp); $b = New-Object byte[] 4; $n = $fs.Read($b, 0, 4); $fs.Close(); $ok = ($n -eq 4 -and $b[0] -eq 0x4D -and $b[1] -eq 0x53 -and $b[2] -eq 0x43 -and $b[3] -eq 0x46) } catch { }
                if ($ok) { Move-Item -Path $tmp -Destination $cab -Force; break }
                Remove-Item -Path $tmp -Force
            }
        }
        $jobs = @(); $queue = New-Object System.Collections.Queue; foreach ($w in $want) { $queue.Enqueue($w) }
        $limit = 4; $t0 = Get-Date
        while ($queue.Count -gt 0 -or $jobs.Count -gt 0) {
            while ($queue.Count -gt 0 -and $jobs.Count -lt $limit) {
                $w = $queue.Dequeue()
                $jobs += Start-Job -ScriptBlock $dlBlock -ArgumentList $w.Short, $w.Id, $w.Dir, $hostOk
            }
            Start-Sleep -Milliseconds 700
            $still = @(); foreach ($j in $jobs) { if ($j.State -eq 'Running') { $still += $j } else { $null = Receive-Job -Job $j -ErrorAction SilentlyContinue; Remove-Job -Job $j -Force -ErrorAction SilentlyContinue } }
            $jobs = $still
            if (((Get-Date) - $t0).TotalMinutes -gt 20) { foreach ($j in $jobs) { Stop-Job -Job $j; Remove-Job -Job $j -Force }; break }
        }
        $ready = @($want | Where-Object { Test-CabFile (Join-Path $_.Dir 'package.cab') }).Count
        Write-Ok (T 'Downloads finished: {0} of {1} ready.' $ready $want.Count)
    }
}

$nSel = @($sel).Count; $iSel = 0
foreach ($s in $sel) {
    Write-Prog (5 * $iSel) (5 * $nSel); $iSel++
    Write-Title ('[' + $iSel + '/' + $nSel + '] ' + $s.Device + ' - ' + $s.Title)
    $id = "$($s.UpdateId)".Trim()
    $label = '{0} | {1} {2}' -f $s.Device, $s.Title, $s.Version
    if ($id -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { Add-Outcome $label $id (T 'Invalid identifier: skipped') 'warn'; continue }
    if ((Test-Excluded ('{0} {1}' -f $s.Device, $s.Title) $s.Class)) { Add-Outcome $label $id (T 'Excluded in settings: skipped') 'warn'; continue }
    if (($riskClasses -contains "$($s.Class)") -and -not $s.RiskAccepted) {
        Add-Outcome $label $id (T 'Type {0}: you must confirm the risk in the page. Skipped' $s.Class) 'warn'; continue
    }
    if (-not $Apply) { Add-Outcome $label $id (T 'Preview (it would be downloaded, checked and installed)') 'preview'; continue }

    $dir = Join-Path $script:ReportDir ('catalog-downloads\' + $id)
    $ext = Join-Path $dir 'extracted'
    New-Item -ItemType Directory -Force -Path $ext | Out-Null

    Write-Ok ('  ' + (T 'Preparing the download...'))
    $cab = Join-Path $dir 'package.cab'
    $dialogFile = Join-Path $dir 'dialog-response.html'

    # 1-2) the package: if you downloaded it by hand and saved it here with this name, it is used
    if (-not (Test-CabFile $cab)) {
        Remove-Item -Path $cab -Force -ErrorAction SilentlyContinue
        Write-Ok ('  ' + (T 'Looking for the file in the Microsoft catalog...'))
        # Same way as the browser: search page (cookies), then the Download button = POST to DownloadDialog.aspx,
        # whose page contains the file addresses. Current catalog addresses do NOT end with .cab.
        $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
        $web = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        $searchUrl = 'https://www.catalog.update.microsoft.com/Search.aspx?q=' + [uri]::EscapeDataString([string]$s.ShortId)
        try { $null = Invoke-WebRequest -Uri $searchUrl -WebSession $web -UserAgent $ua -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop } catch { }
        $post = '[{"size":0,"languages":"","uidInfo":"' + $id + '","updateID":"' + $id + '"}]'
        $body = @{ updateIDs = $post; updateIDsBlockedForImport = ''; wsusApiPresent = ''; contentImport = ''; sku = ''; serverName = ''; ssl = ''; portNumber = ''; version = '' }
        $html = ''
        try {
            $resp = Invoke-WebRequest -Uri 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' -Method Post -Body $body -WebSession $web -UserAgent $ua `
                -Headers @{ Referer = $searchUrl; Origin = 'https://www.catalog.update.microsoft.com' } -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
            $html = [string]$resp.Content
            Set-Content -Path $dialogFile -Value $html -Encoding UTF8
        } catch {
            Add-Outcome $label $id (T 'The catalog does not answer the download request: {0}. Download it by hand from the catalog list and save the file as {1}' ($_.Exception.Message -replace '\s+', ' ') $cab) 'err'; continue
        }
        $norm = $html.Replace('&', '&').Replace('&amp;', '&').Replace('\/', '/')
        $urls = @()
        foreach ($m in [regex]::Matches($norm, 'downloadInformation\[\d+\]\.files\[\d+\]\.url\s*=\s*[''"]([^''"]+)[''"]')) { $urls += $m.Groups[1].Value }
        if ($urls.Count -eq 0) {
            foreach ($m in [regex]::Matches($norm, 'https?://[^''"\s<>\\]+')) {
                if ($m.Value -match '\.(js|css|aspx|png|gif|ico)(\?|$)') { continue }
                if ($urls -notcontains $m.Value) { $urls += $m.Value }
            }
        }
        $urls = @($urls | Where-Object { $h = ''; try { $h = ([uri]$_).Host } catch { }; $h -match $hostOk })
        if ($urls.Count -eq 0) {
            Add-Outcome $label $id (T 'The catalog answer contains no download address. The answer was saved in {0} (send it to the developer). Download by hand from the list and save the file as {1}' $dialogFile $cab) 'err'; continue
        }
        Write-Ok ('  ' + (T 'Download in progress (it can take a few minutes)...'))
        Write-Prog (5 * ($iSel - 1) + 1) (5 * $nSel)
        $got = $false
        foreach ($u in $urls) {
            $tmp = Join-Path $dir 'download.tmp'
            try { Invoke-WebRequest -Uri $u -OutFile $tmp -WebSession $web -UserAgent $ua -UseBasicParsing -TimeoutSec 900 -ErrorAction Stop } catch { continue }
            if (Test-CabFile $tmp) { Write-Ok ('  ' + (T 'Downloaded: {0} MB' ([math]::Round((Get-Item $tmp).Length / 1MB, 1)))); Move-Item -Path $tmp -Destination $cab -Force; $got = $true; break }
            Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
        }
        if (-not $got) { Add-Outcome $label $id (T 'Download failed: the catalog did not provide a usable package. You can download it by hand from the catalog and save it as {0}' $cab) 'err'; continue }
    }
    $sigText = T 'unsigned'
    try {
        $sg = Get-AuthenticodeSignature -FilePath $cab
        if ("$($sg.Status)" -eq 'HashMismatch') { Add-Outcome $label $id (T 'FILE TAMPERED WITH (signature does not match): discarded') 'err'; Remove-Item -Path $cab -Force -ErrorAction SilentlyContinue; continue }
        if ("$($sg.Status)" -eq 'Valid') { $sigText = T 'valid Microsoft signature' }
    } catch { }

    Write-Prog (5 * ($iSel - 1) + 2) (5 * $nSel)
    Write-Ok ('  ' + (T 'Checking and opening the package...'))
    # 3) extraction (expand.exe is part of Windows)
    $null = & expand.exe $cab ('-F:*') $ext 2>&1
    $infs = @(Get-ChildItem -Path $ext -Filter '*.inf' -Recurse -ErrorAction SilentlyContinue)
    if ($infs.Count -eq 0) { Add-Outcome $label $id (T 'The package contains no installable driver: skipped') 'warn'; continue }

    # 3b) fingerprint and signature of the package: shown to the user and logged
    $sha = ''
    try { $sha = (Get-FileHash -Path $cab -Algorithm SHA256 -ErrorAction Stop).Hash } catch { }
    if ($sha) { Write-Info ('  ' + (T 'SHA-256 of the downloaded package: {0}' $sha)) }
    $cats = @(Get-ChildItem -Path $ext -Filter '*.cat' -Recurse -ErrorAction SilentlyContinue)
    $signer = ''; $catBad = 0
    foreach ($ct in $cats) {
        try {
            $cs = Get-AuthenticodeSignature -FilePath $ct.FullName
            $stt = "$($cs.Status)"
            if ($stt -eq 'NotSigned' -or $stt -eq 'HashMismatch') { $catBad++ }
            elseif ($cs.SignerCertificate -and -not $signer) { $signer = ("$($cs.SignerCertificate.Subject)" -replace '^.*?CN=([^,]+).*$', '$1') }
        } catch { }
    }
    $verdict = ''
    if ($cats.Count -eq 0 -or $catBad -gt 0) { $verdict = T 'REFUSED' }
    elseif ($signer -match 'Microsoft Windows') { $verdict = T 'Microsoft certified' }
    else { $verdict = T 'signed by another publisher' }
    try {
        $dl = Join-Path $script:ReportDir 'downloads.csv'
        [pscustomobject][ordered]@{ Date = (Get-Date -Format 'yyyy-MM-dd HH:mm'); Package = "$label"; Sha256 = $sha; Signer = $signer; Result = $verdict } | Export-Csv -Path $dl -Append -Delimiter ';' -NoTypeInformation -Encoding UTF8
    } catch { }
    if ($cats.Count -eq 0 -or $catBad -gt 0) { Add-Outcome $label $id (T 'REFUSED: the signature of the package is missing or does not match. Nothing was installed.') 'err'; continue }
    if ($signer) { Write-Ok ('  ' + (T 'Signed by: {0} ({1})' $signer $verdict)) }

    # 4) installation: Windows checks the driver signature (pnputil refuses unsigned packages)
    Write-Ok ('  ' + (T 'Installing the driver...'))
    Write-Prog (5 * ($iSel - 1) + 3) (5 * $nSel)
    $before = @(Get-DriverState $s.ShortId)
    $r = Invoke-Pnp @('/add-driver', (Join-Path $ext '*.inf'), '/subdirs', '/install')
    $alreadyThere = ($r.Code -eq 259 -and $r.Output -match 'oem\d+\.inf')
    try { Set-DownloadInfs $sha @($(if ($r.Ok -or $alreadyThere) { [regex]::Matches($r.Output, 'oem\d+\.inf') | ForEach-Object { $_.Value.ToLower() } | Select-Object -Unique })) } catch { }
    if (-not ($r.Ok -or $alreadyThere)) { Add-Outcome $label $id (T 'NOT installed (code {0}): {1}' $r.Code ($r.Output -replace '\s+', ' ')) 'err'; continue }

    Write-RebootNeeded
    Write-Prog (5 * ($iSel - 1) + 4) (5 * $nSel)
    Write-Ok ('  ' + (T 'Checking that the device uses the new driver...'))
    # 5) check: what does the device use now?
    $after = @(Get-DriverState $s.ShortId)
    $changed = 0
    foreach ($b in $after) {
        $a = $before | Where-Object { $_.Id -eq $b.Id } | Select-Object -First 1
        if ($a -and (($a.Inf -ne $b.Inf) -or ($a.Ver -ne $b.Ver) -or ($a.Date -ne $b.Date))) { $changed++ }
    }
    if ($changed -gt 0 -and $Apply) { Clear-DoneDevice $s }
    if ($changed -gt 0) { Add-Outcome $label $id (T 'Installed and checked: {0} device(s) now use the new driver ({1}). Restart the PC if Windows asks' $changed $sigText) 'ok' }
    elseif (@($after).Count -eq 0) { Add-Outcome $label $id (T 'Driver added to Windows; the device was not found to compare before and after: check in Device Manager ({0})' $sigText) 'warn' }
    else {
        # Windows keeps the current driver (usually the PC maker one, with a more specific ID): the user decides
        $replaced = 0; $kept = 0; $failed = @(); $removed = @(); $notRemoved = @(); $stoppedAll = @(); $changed2 = 0
        $usage = $null
        foreach ($b in $after) {
            $warn = ''
            if ($riskClasses -contains "$($s.Class)") { $warn = ' ' + (T 'WARNING: this is a {0} driver: the screen or the network can flicker or drop for a few seconds.' $s.Class) }
            $q = T 'Windows keeps using driver {1} ({2}) for "{0}" instead of the new {3}.{4} Do you want to replace it with the new one? If you remove the old one, going back needs the driver backup. [F] Yes, replace it and remove the old one (recommended)  [S] Yes, use the new one but keep the old one too  [M] No, keep the current one' $s.Device $b.Ver $b.Date $s.Version $warn
            $k = Read-Choice $q @('F', 'S', 'M')
            if ($k -eq 'M') { $kept++; continue }
            if (-not (Find-DriverInf $b.Id $ext $s.Class $s.ShortId)) { $failed += (T 'This package has no driver for this exact device, so Windows cannot use it: the current driver stays.'); Write-Warn ('  ' + (T 'Not done:') + ' ' + $failed[-1]); continue }
            $oldInf = $b.Inf
            $oldGone = $false
            if ($k -eq 'F') {
                # 1) the old package goes FIRST: with only the new one left in the driver store Windows binds it by itself,
                #    now and at every restart (forcing alone is undone when Windows ranks the old package higher)
                if ($oldInf -notmatch '^oem\d+\.inf$') { $notRemoved += (T '{0}: it is a Windows built-in driver, it cannot be removed' $oldInf) }
                else {
                    if (-not $usage) { $usage = Get-DriverUsage }
                    $ours = @($after | Where-Object { $_.Inf -eq $oldInf }).Count
                    if ([int]$usage.Present[$oldInf.ToLower()] -gt $ours) { $notRemoved += (T '{0}: still used by another device' $oldInf) }
                    else {
                        Save-Before $s $b
                        $st = @(Stop-OldDriverServices $oldInf)
                        if ($st.Count -gt 0) { Write-Ok ('  ' + (T 'Stopped the services of the old driver: {0}' ($st -join ', '))); $stoppedAll += $st }
                        Write-Ok ('  ' + (T 'Removing the old driver ({0})...' $oldInf))
                        $d = Invoke-Pnp @('/delete-driver', $oldInf, '/uninstall', '/force')
                        if ($d.Ok) { $removed += $oldInf; $oldGone = $true; $null = Invoke-Pnp @('/scan-devices'); Start-Sleep -Seconds 4 }
                        else { $notRemoved += (T '{0}: Windows refused (code {1}): {2}' $oldInf $d.Code ($d.Output -replace '\s+', ' ')) }
                    }
                }
            }
            # 2) does the device already use the new driver?
            $now = @(Get-DriverState $s.ShortId) | Where-Object { $_.Id -eq $b.Id } | Select-Object -First 1
            if ($now -and $now.Inf -ne $oldInf -and ($now.Ver -ne $b.Ver -or $now.Date -ne $b.Date)) { $changed2++; $replaced++; continue }
            # 3) not yet (or the old one could not be removed): force the new package onto the device
            Write-Ok ('  ' + (T 'Applying the new driver (it can take a few seconds)...'))
            $f = Invoke-ForceDriver $b.Id $ext $s.Class $s.ShortId $s.ShortId
            if (-not $f.Ok -and $f.Message -match '\b259\b' -and -not ($riskClasses -contains "$($s.Class)")) {
                # Error 259: Windows does not apply the package to this device node directly (seen with USB composite devices and
                # built-in drivers). The package is already in the driver store: remove ONLY this device entry and let Windows
                # detect it again, so it picks the best driver by itself (the newer package wins over the old built-in one).
                Write-Info ('  ' + (T 'Windows did not take the driver directly: I remove this device entry and let Windows detect it again...'))
                $rd = Invoke-Pnp @('/remove-device', "$($b.Id)")
                $null = Invoke-Pnp @('/scan-devices'); Start-Sleep -Seconds 5
                if ($rd.Ok -or $rd.Code -eq 3010) { $f = [pscustomobject]@{ Ok = $true; Message = (T 'The device was detected again by Windows, which chose the driver (check below)'); Reboot = $false } }
            }
            if ($f.Ok) { Write-Ok ('  ' + $f.Message); $replaced++ } else { Write-Warn ('  ' + (T 'Not done:') + ' ' + $f.Message); $failed += $f.Message }
            $now = @(Get-DriverState $s.ShortId) | Where-Object { $_.Id -eq $b.Id } | Select-Object -First 1
            if ($now) { Write-Info ('  ' + (T 'The device now uses: {0} {1} ({2})' $now.Inf $now.Ver $now.Date)) }
            if ($now -and $now.Inf -ne $oldInf -and ($now.Ver -ne $b.Ver -or $now.Date -ne $b.Date)) { $changed2++
                # forced with the old package still in the store: now it can go (otherwise Windows may put it back)
                if ($k -eq 'F' -and -not $oldGone -and $oldInf -match '^oem\d+\.inf$' -and ($notRemoved -join ' ') -notmatch [regex]::Escape($oldInf)) {
                    if (-not $usage) { $usage = Get-DriverUsage }
                    if ([int]$usage.Present[$oldInf.ToLower()] -eq 0) {
                        Save-Before $s $b
                        $d = Invoke-Pnp @('/delete-driver', $oldInf, '/uninstall', '/force')
                        if ($d.Ok) { $removed += $oldInf } else { $notRemoved += (T '{0}: Windows refused (code {1}): {2}' $oldInf $d.Code ($d.Output -replace '\s+', ' ')) }
                    }
                }
            }
        }
        $tail = ''
        if ($stoppedAll.Count -gt 0) { $tail += ' ' + (T 'Services stopped: {0}.' ($stoppedAll -join ', ')) }
        if ($removed.Count -gt 0) { $tail += ' ' + (T 'Old driver removed: {0}.' ($removed -join ', ')) }
        if ($notRemoved.Count -gt 0) { $tail += ' ' + (T 'Old driver NOT removed: {0}.' ($notRemoved -join '; ')) }
        if ($changed2 -gt 0 -and $Apply) { Clear-DoneDevice $s }
        if ($changed2 -gt 0) { Add-Outcome $label $id ((T 'New driver applied and checked on {0} device(s) ({1}).' $changed2 $sigText) + $tail + ' ' + (T 'Restart the PC')) 'ok' }
        elseif ($replaced -gt 0) { Add-Outcome $label $id ((T 'Applied, but the device still shows the previous driver: restart and check again ({0}).' $sigText) + $tail) 'warn' }
        elseif ($failed.Count -gt 0) { Add-Outcome $label $id (T 'Replacement NOT done: {0}' ((@($failed | Select-Object -Unique)) -join '; ')) 'warn' }
        else { Add-Outcome $label $id (T 'Driver added to Windows; you chose to keep the current driver ({0})' $sigText) 'warn' }
    }
}

Save-Outcomes 'catalog-install'
if ($Apply) {
    $hist = Join-Path $script:ReportDir 'history'
    New-Item -ItemType Directory -Force -Path $hist | Out-Null
    Move-Item -Path $selPath -Destination (Join-Path $hist ('selection-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')) -Force -ErrorAction SilentlyContinue
}
Write-AfterRun $Apply @((T 'Check the outcome of each driver above: "the device still shows the previous driver" is not an error, it means Windows keeps the PC maker driver.'))
Stop-Log
exit 0
