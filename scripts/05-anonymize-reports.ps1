# Prepares copies of the reports that are safe to share (for example in a GitHub issue):
# hides MAC addresses, USB serial numbers, the PC name, the user name and the words you indicate.
# Writes to reports\shareable\ and does not change the original reports.
# WARNING: this is basic protection, not a guarantee. Always check the files before sharing them.
. "$PSScriptRoot\common.ps1"

$srcDir = $script:ReportDir
$dstDir = Join-Path $srcDir 'shareable'
New-Item -ItemType Directory -Force -Path $dstDir | Out-Null

$names = @('devices', 'drivers', 'bluetooth', 'unknown', 'drivers-to-check', 'driver-updates', 'defender-events')
$files = @($names | ForEach-Object { Join-Path $srcDir ($_ + '.csv') } | Where-Object { Test-Path $_ })
if ($files.Count -eq 0) {
    Write-Err (T 'ERROR: I cannot find any report to make shareable.')
    Write-Todo @(T 'Run the inventory first (Start tab), then repeat this operation.')
    exit 1
}

$hide = New-Object System.Collections.Generic.List[string]
foreach ($n in @($env:COMPUTERNAME, $env:USERNAME, $env:USERDOMAIN)) {
    if ($n -and $n.Length -ge 3 -and -not $hide.Contains($n)) { $hide.Add($n) }
}
Write-Info (T 'The PC name and the Windows user name will be hidden too.')
if ($env:DEVVY_WEB -ne '1') {
    $extra = Read-Host (T 'Other names to hide (for example your phones or your family), separated by commas; Enter for none')
    foreach ($n in ($extra -split ',')) {
        $w = $n.Trim()
        if ($w.Length -ge 3 -and -not $hide.Contains($w)) { $hide.Add($w) }
    }
}

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
foreach ($f in $files) {
    $text = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8)
    $out = Hide-Text $text $hide
    $dst = Join-Path $dstDir (Split-Path $f -Leaf)
    [IO.File]::WriteAllText($dst, $out, $utf8Bom)
    Write-Host ('  ' + (T 'Created:') + ' ' + $dst)
}

# one zip with the shareable copies: easy to attach to a GitHub issue
try {
    Get-ChildItem -Path $srcDir -Filter 'shareable-*.zip' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    $szip = Join-Path $srcDir ('shareable-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.zip')
    Compress-Archive -Path @($files | ForEach-Object { Join-Path $dstDir (Split-Path $_ -Leaf) }) -DestinationPath $szip -Force
    Write-Host ('  ' + (T 'Created:') + ' ' + $szip)
} catch { Write-Warn ((T 'Could not create the zip of the shareable copies:') + ' ' + $_.Exception.Message) }

Write-Host ''
Write-Ok (T 'Done: MAC addresses, USB serial numbers, the PC name, the user name and the indicated words are hidden.')
Write-Todo @(
    (T 'Open the reports\shareable folder.'),
    (T 'Check the files by hand before sharing them: device names can contain other personal data.'),
    (T 'Share only the files of that folder, never the originals in reports.')
)
