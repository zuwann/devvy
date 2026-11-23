# Updates the program to the latest GitHub release: downloads only the new or changed files, checks each SHA-256, replaces the old
# ones, removes the files that are no longer part of the project. Runs ONLY when the person presses "Update". The data folder and the
# user's own tables are never touched. devvy.bat is replaced only after the program has closed (a running .bat must not change).
. "$PSScriptRoot\common.ps1"
Assert-Admin
Start-Log 'self-update'
if (-not (Test-Internet)) {
    Write-Err (T 'No internet connection')
    Write-Todo @(T 'Connect the PC to the network (Wi-Fi or cable), check that a web page opens, then try again.')
    Stop-Log
    exit 2
}
Write-Title (T 'Updating Devvy')
$root = Split-Path $PSScriptRoot
Write-Prog 1 6
Write-Info (T 'Comparing the installed files with the latest release...')
$plan = Get-UpdatePlan
if (-not $plan.ok) { Write-Err $plan.error; Stop-Log; exit 1 }
Write-Info ((T 'Installed version:') + ' ' + $plan.current + '   ' + (T 'Available:') + ' ' + $plan.latest)
if (-not $plan.needed) { Write-Ok (T 'Devvy is already up to date.'); Stop-Log; exit 0 }
Write-Info (T 'New: {0}   Changed: {1}   To remove: {2}' $plan.added.Count $plan.changed.Count $plan.removed.Count)

$u = Get-UpdateUrls
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$stage = Join-Path $script:DataRoot 'update-staging'
if (Test-Path $stage) { Remove-Item -Path $stage -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'files') | Out-Null
$hashes = @{}; foreach ($f in @($plan.manifest.files)) { $hashes["$($f.path)"] = "$($f.sha256)".ToLower() }
$maxBytes = 8MB
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
$ProgressPreference = 'SilentlyContinue'

# 1) download and check everything BEFORE changing anything
Write-Prog 2 6
$todo = @($plan.added) + @($plan.changed); $n = 0; $bad = @()
foreach ($rp in $todo) {
    $n++
    $dst = Join-Path (Join-Path $stage 'files') ($rp -replace '/', '\')
    New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
    try {
        Invoke-WebRequest -Uri ($u.Raw + $plan.tag + '/' + $rp) -OutFile $dst -UseBasicParsing -TimeoutSec 60 -Headers @{ 'User-Agent' = 'Devvy-update' }
        $len = (Get-Item $dst).Length
        if ($len -gt $maxBytes -or $len -eq 0) { throw (T 'wrong size') }
        if ((Get-FileHash -Path $dst -Algorithm SHA256).Hash.ToLower() -ne $hashes[$rp]) { throw (T 'the SHA-256 does not match') }
        Write-Host ('  [{0}/{1}] {2}' -f $n, $todo.Count, $rp) -ForegroundColor Gray
    } catch { $bad += ($rp + ': ' + ($_.Exception.Message -replace '\s+', ' ')); Write-Err ('  ' + $rp + ': ' + ($_.Exception.Message -replace '\s+', ' ')) }
    Write-Prog (2 + [math]::Floor(2 * $n / [math]::Max(1, $todo.Count))) 6
}
if ($bad.Count -gt 0) {
    Write-Err (T 'Some files could not be downloaded or did not pass the check: nothing was changed.')
    Remove-Item -Path $stage -Recurse -Force -ErrorAction SilentlyContinue
    Stop-Log; exit 1
}

# 2) backup of what will be replaced or removed
Write-Prog 4 6
$bk = Join-Path $script:DataRoot ('update-backup\' + $plan.current + '-' + $ts)
foreach ($rp in (@($plan.changed) + @($plan.removed))) {
    $src = Join-Path $root ($rp -replace '/', '\')
    if (Test-Path -LiteralPath $src -PathType Leaf) {
        $d = Join-Path $bk ($rp -replace '/', '\'); New-Item -ItemType Directory -Force -Path (Split-Path $d) | Out-Null
        Copy-Item -LiteralPath $src -Destination $d -Force
    }
}
$oldMan = Join-Path $root 'files.json'
if (Test-Path $oldMan) { New-Item -ItemType Directory -Force -Path $bk | Out-Null; Copy-Item -Path $oldMan -Destination (Join-Path $bk 'files.json') -Force }

# 3) apply (devvy.bat waits for the restart)
Write-Prog 5 6
$deferred = @('devvy.bat'); $applied = @(); $failed = $false
foreach ($rp in $todo) {
    $src = Join-Path (Join-Path $stage 'files') ($rp -replace '/', '\')
    if ($deferred -contains $rp) {
        $dd = Join-Path $stage 'deferred'; New-Item -ItemType Directory -Force -Path $dd | Out-Null
        Move-Item -Path $src -Destination (Join-Path $dd $rp) -Force; continue
    }
    $dst = Join-Path $root ($rp -replace '/', '\')
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
        $applied += $rp
    } catch { $failed = $true; Write-Err ('  ' + $rp + ': ' + ($_.Exception.Message -replace '\s+', ' ')); break }
}
if ($failed) {
    Write-Warn (T 'Restoring the previous files...')
    foreach ($rp in $applied) {
        $b = Join-Path $bk ($rp -replace '/', '\'); $dst = Join-Path $root ($rp -replace '/', '\')
        if (Test-Path -LiteralPath $b) { Copy-Item -LiteralPath $b -Destination $dst -Force -ErrorAction SilentlyContinue } else { Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue }
    }
    Write-Err (T 'The update could not be completed: the previous version was restored.')
    Remove-Item -Path $stage -Recurse -Force -ErrorAction SilentlyContinue
    Stop-Log; exit 1
}
foreach ($rp in @($plan.removed)) {
    $dst = Join-Path $root ($rp -replace '/', '\')
    try { Remove-Item -LiteralPath $dst -Force -ErrorAction Stop; Write-Host ('  - ' + $rp) -ForegroundColor Gray } catch { Write-Warn ('  ' + (T 'Could not remove:') + ' ' + $rp) }
}
# empty folders left behind by removed files (never the data folder)
foreach ($rp in @($plan.removed)) {
    $dir = Split-Path (Join-Path $root ($rp -replace '/', '\'))
    while ($dir -and $dir.Length -gt $root.Length -and (Test-Path $dir) -and @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue).Count -eq 0) { Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue; $dir = Split-Path $dir }
}
# the new file list becomes the reference for the next update
try { [IO.File]::WriteAllText($oldMan, (ConvertTo-Json -InputObject $plan.manifest -Depth 5), (New-Object Text.UTF8Encoding($false))) } catch { }
# keep the last 3 backups
try { Get-ChildItem -Path (Join-Path $script:DataRoot 'update-backup') -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -Skip 3 | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue } catch { }
Write-Prog 6 6
Write-Ok (T 'Update done: version {0}. The previous files are saved in {1}' $plan.latest $bk)
if ($env:DEVVY_WEB -eq '1') { Write-Host '##UPDATED##' }
Stop-Log
