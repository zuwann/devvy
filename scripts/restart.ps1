# Restarts Devvy after an update: waits for the old copy to close, puts in place the files that could not change while it was
# running (devvy.bat), and starts devvy.bat again. Started by the server; nobody needs to run it by hand.
param([int]$ServerPid = 0, [int]$ParentPid = 0)
$ErrorActionPreference = 'SilentlyContinue'
$root = Split-Path $PSScriptRoot
# the server first (up to 60 s); then the console that ran devvy.bat, but only a few seconds: a console left at a prompt never reads the batch again, so it is safe to go on
if ($ServerPid -gt 0) { try { $p = Get-Process -Id $ServerPid -ErrorAction Stop; $null = $p.WaitForExit(60000) } catch { } }
if ($ParentPid -gt 0) {
    try {
        $p = Get-Process -Id $ParentPid -ErrorAction Stop
        if (-not $p.WaitForExit(3000)) {
            # The window of the old copy is still there (a console left at its prompt): close it, but only if it is a cmd window titled "Devvy" (set by devvy.bat), never another console
            if ($p.ProcessName -eq 'cmd' -and "$($p.MainWindowTitle)" -match 'Devvy') { try { Stop-Process -Id $ParentPid -Force -ErrorAction Stop } catch { } }
            else { $null = $p.WaitForExit(5000) }
        }
    } catch { }
}
Start-Sleep -Milliseconds 800
# data folder: same rule as the program (settings may move it)
$data = Join-Path $root 'data'
try { $sj = Join-Path $data 'settings.json'; if (Test-Path $sj) { $dd = (Get-Content -Path $sj -Raw | ConvertFrom-Json).dataDir; if ($dd -and (Test-Path $dd)) { $data = [string]$dd } } } catch { }
$def = Join-Path $data 'update-staging\deferred'
if (Test-Path $def) {
    foreach ($f in @(Get-ChildItem -Path $def -File -Recurse)) {
        $rel = $f.FullName.Substring($def.Length).TrimStart('\')
        try { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $root $rel) -Force -ErrorAction Stop } catch { }
    }
}
try { Remove-Item -Path (Join-Path $data 'update-staging') -Recurse -Force } catch { }
$bat = Join-Path $root 'devvy.bat'
if (Test-Path $bat) { Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c start "" "' + $bat + '"') -WorkingDirectory $root }
