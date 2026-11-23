# Optional update of the knowledge base (knowledge.csv, its translations and support-links.csv) from the project page on GitHub.
# Runs ONLY when the person presses "Check for knowledge updates". It sends nothing: it just downloads kb/manifest.json and the files it
# lists over HTTPS (raw.githubusercontent.com), checks size, SHA-256 and the columns, and only then puts them in <data>\kb.
# Nothing is executed from the downloaded files: they are plain CSV data. The shipped files are never overwritten.
. "$PSScriptRoot\common.ps1"
Start-Log 'kb-update'
Write-Title (T 'UPDATING THE KNOWLEDGE BASE')
Write-Prog 1 5
$base = $script:KbUpdateBaseUrl
if ($base -match 'OWNER') { Write-Warn (T 'The GitHub address of the project is not set yet: nothing to download.'); Stop-Log; exit 0 }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
$ProgressPreference = 'SilentlyContinue'
$allowed = @('knowledge.csv', 'knowledge.it.csv', 'knowledge.es.csv', 'knowledge.de.csv', 'knowledge.fr.csv', 'support-links.csv', 'support-models.csv', 'board-links.csv')
$cols = @{ 'knowledge.csv' = 'Id;Match'; 'knowledge.it.csv' = 'Id;Name'; 'knowledge.es.csv' = 'Id;Name'; 'knowledge.de.csv' = 'Id;Name'; 'knowledge.fr.csv' = 'Id;Name'; 'support-links.csv' = 'Match;Name;Url'; 'support-models.csv' = 'Sku;Url'; 'board-links.csv' = 'Match;Name;Url' }
$maxBytes = 5MB

$man = $null
try {
    $raw = (Invoke-WebRequest -Uri ($base + 'manifest.json') -UseBasicParsing -TimeoutSec 30 -Headers @{ 'User-Agent' = 'Devvy-kb' }).Content
    if ($raw -is [byte[]]) { $raw = [Text.Encoding]::UTF8.GetString($raw) }
    $man = $raw | ConvertFrom-Json
} catch { Write-Err (T 'Cannot reach the update page: {0}' ($_.Exception.Message -replace '\s+', ' ')); Stop-Log; exit 1 }
Write-Prog 2 5
$remote = 0; try { $remote = [int64]$man.version } catch { }
$local = [math]::Max((Get-KbShippedVersion), (Get-KbDownloadedVersion))
Write-Info ((T 'Installed version:') + ' ' + $local + '   ' + (T 'Available:') + ' ' + $remote)
if ($remote -le $local) { Write-Ok (T 'The knowledge base is already up to date.'); Stop-Log; exit 0 }

$tmp = Join-Path $script:DataRoot ('tmp-kb-' + (Get-Date -Format 'yyyyMMddHHmmss'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$ok = $true; $n = 0
foreach ($f in @($man.files)) {
    $name = "$($f.name)"
    if ($allowed -notcontains $name) { Write-Warn ((T 'Skipped (not allowed):') + ' ' + $name); continue }
    $dst = Join-Path $tmp $name
    try {
        Invoke-WebRequest -Uri ($base + $name) -OutFile $dst -UseBasicParsing -TimeoutSec 60 -Headers @{ 'User-Agent' = 'Devvy-kb' }
        $len = (Get-Item $dst).Length
        if ($len -gt $maxBytes -or $len -eq 0) { throw (T 'wrong size') }
        $h = (Get-FileHash -Path $dst -Algorithm SHA256).Hash.ToLower()
        if ($h -ne "$($f.sha256)".ToLower()) { throw (T 'the SHA-256 does not match') }
        $first = (Get-Content -Path $dst -TotalCount 1 -Encoding UTF8)
        foreach ($c in ($cols[$name] -split ';')) { if ($first -notmatch [regex]::Escape($c)) { throw ((T 'missing column') + ' ' + $c) } }
        Write-Ok ('  ' + $name + ' (' + $len + ' bytes, SHA-256 OK)'); $n++
    } catch { Write-Err ('  ' + $name + ': ' + ($_.Exception.Message -replace '\s+', ' ')); $ok = $false }
}
Write-Prog 4 5
if ($ok -and $n -gt 0) {
    New-Item -ItemType Directory -Force -Path $script:KbDir | Out-Null
    foreach ($x in @(Get-ChildItem -Path $tmp -File)) { Copy-Item -Path $x.FullName -Destination (Join-Path $script:KbDir $x.Name) -Force }
    @{ version = $remote; date = "$($man.date)"; installed = (Get-Date -Format 'yyyy-MM-dd HH:mm') } | ConvertTo-Json | Set-Content -Path (Join-Path $script:KbDir 'manifest.json') -Encoding UTF8
    Write-Ok (T 'Knowledge base updated to version {0}. It is used from the next operation.' $remote)
} else {
    Write-Err (T 'Nothing was installed: the current knowledge base is unchanged.')
}
Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Prog 5 5
Stop-Log
if ($ok) { exit 0 } else { exit 1 }
