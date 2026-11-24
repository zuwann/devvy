# Prepares a zip to attach to a problem report (GitHub issue): version, Windows and PC model, the latest logs and results,
# and the reports, with MAC addresses, USB serial numbers, PC name, user name and user folder hidden.
# NOTHING is sent anywhere: the zip is written to reports\ and the person decides whether to share it.
. "$PSScriptRoot\common.ps1"
Start-Log 'problem-report'
Write-Title (T 'BUILDING THE PROBLEM ZIP')

$hide = New-Object System.Collections.Generic.List[string]
foreach ($n in @($env:COMPUTERNAME, $env:USERNAME, $env:USERDOMAIN)) { if ($n -and $n.Length -ge 3 -and -not $hide.Contains($n)) { $hide.Add($n) } }
$tmp = Join-Path $script:DataRoot ('tmp-problem-' + (Get-Date -Format 'yyyyMMddHHmmss'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
Write-Prog 1 5

$ver = ''
try { $m = [regex]::Match((Get-Content -Path (Join-Path $PSScriptRoot 'web\app.html') -Raw -Encoding UTF8), 'Devvy <small class="mut">([^<]+)</small>'); if ($m.Success) { $ver = $m.Groups[1].Value } } catch { }
$pc = Get-PcInfo
$info = @(
    ('Devvy: ' + $ver), ('Windows: ' + $pc.os), ('Manufacturer: ' + $pc.maker), ('Model: ' + $pc.model), ('Laptop: ' + $pc.laptop + '  OEM: ' + $pc.oem + '  Assembled: ' + $pc.assembled + '  Virtual: ' + $pc.virtual),('Title: ' + $pc.title),
    ('CPU: ' + $pc.cpu), ('RAM: ' + $pc.ram), ('GPU: ' + $pc.gpu), ('PowerShell: ' + $PSVersionTable.PSVersion), ('Date: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
) -join "`r`n"
$utf8 = New-Object System.Text.UTF8Encoding($true)
[IO.File]::WriteAllText((Join-Path $tmp 'info.txt'), (Hide-Text $info $hide), $utf8)

function Copy-Hidden([string]$Src, [string]$DstDir) {
    if (-not (Test-Path $Src)) { return }
    New-Item -ItemType Directory -Force -Path $DstDir | Out-Null
    # logs of the running jobs are still open for writing: read them with a shared lock, skip a file that cannot be read
    $t = $null
    try {
        $fs = New-Object System.IO.FileStream($Src, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try { $sr = New-Object System.IO.StreamReader($fs, [Text.Encoding]::UTF8); $t = $sr.ReadToEnd(); $sr.Dispose() } finally { $fs.Dispose() }
    } catch { Write-Warn ((T 'Skipped (cannot be read now):') + ' ' + (Split-Path $Src -Leaf)); return }
    $t = Hide-Text $t $hide
    if ($env:USERPROFILE) { $t = [regex]::Replace($t, [regex]::Escape($env:USERPROFILE), '<USERPROFILE>', 'IgnoreCase') }
    [IO.File]::WriteAllText((Join-Path $DstDir (Split-Path $Src -Leaf)), $t, $utf8)
}
Write-Ok (T 'Copying the latest logs and results (with private data hidden)...')
@(Get-ChildItem -Path $script:LogDir -Filter '*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 10) | ForEach-Object { Copy-Hidden $_.FullName (Join-Path $tmp 'logs') }
Write-Prog 2 5
@(Get-ChildItem -Path $script:OutcomesDir -Filter '*.csv' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 6) | ForEach-Object { Copy-Hidden $_.FullName (Join-Path $tmp 'results') }
Write-Prog 3 5
try { $null = Save-ReturnDiag } catch { }
try { Copy-Hidden (Join-Path $script:DataRoot 'wu-hide.json') (Join-Path $tmp 'reports') } catch { }
foreach ($n in @('selftest', 'devices', 'drivers', 'bluetooth', 'unknown', 'drivers-to-check', 'catalog', 'rollback', 'downloads', 'wu-history', 'oem-inf', 'setupapi-trail', 'wu-pending')) { Copy-Hidden (Join-Path $script:ReportDir ($n + '.csv')) (Join-Path $tmp 'reports') }

$zip = Join-Path $script:ReportDir ('problem-report-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.zip')
try { Compress-Archive -Path (Join-Path $tmp '*') -DestinationPath $zip -Force -ErrorAction Stop }
catch { Write-Err (T 'Cannot create the zip: {0}' ($_.Exception.Message -replace '\s+', ' ')); Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue; Stop-Log; exit 1 }
Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Prog 5 5
Write-Ok ((T 'Done:') + ' ' + $zip)
Write-Todo @(
    (T 'Open the folder and check the zip content before sharing it: device names can contain other personal data.'),
    (T 'Describe the problem in a GitHub issue and attach the zip. Devvy never sends anything by itself.')
)
Stop-Log
exit 0
