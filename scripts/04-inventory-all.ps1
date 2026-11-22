# Full inventory (devices, drivers, Bluetooth) with the independent parts running at the same time.
# Stage 1: the slow Windows readings (driver packages, device properties) and the Bluetooth inventory, together.
# Stage 2: the device and driver inventories, together (they now find the readings ready).
# Each part is the same script as before and keeps its own log; here only their text is shown, in order.
. "$PSScriptRoot\common.ps1"
Assert-Admin
$ps = 'powershell.exe'
try { $p0 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'; if (Test-Path -LiteralPath $p0) { $ps = $p0 } } catch { }
$tmp = Join-Path $script:DataRoot ('cache\inv-' + $PID)
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$fail = 0
function Start-Part([string]$Name, [string[]]$More, [string]$Tag = '') {
    $o = Join-Path $tmp ($Name + $Tag + '.out.txt'); $e = Join-Path $tmp ($Name + $Tag + '.err.txt')
    $arg = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot ($Name + '.ps1')) + '"'
    if ($More) { $arg += ' ' + ($More -join ' ') }
    $sp = @{ FilePath = $ps; ArgumentList = $arg; PassThru = $true; RedirectStandardOutput = $o; RedirectStandardError = $e }
    if ($IsWindows -ne $false) { $sp['WindowStyle'] = 'Hidden' }
    $p = Start-Process @sp
    $null = $p.Handle   # keeps the exit code readable after the process ends (known PowerShell quirk)
    return @{ Name = $Name; Proc = $p; Out = $o }
}
function Show-Part($Part) {
    $Part.Proc.WaitForExit()
    $ec = $Part.Proc.ExitCode
    if ($null -ne $ec -and $ec -ne 0) { $script:fail++ }
    if (Test-Path $Part.Out) {
        foreach ($l in @(Get-Content -Path $Part.Out -Encoding UTF8 -ErrorAction SilentlyContinue)) { if ($l -notmatch '^##PROG ') { Write-Host $l } }
    }
}

Write-Prog 0 3
Write-Ok (T 'Reading Windows, devices and Bluetooth at the same time...')
$w1 = Start-Part '04-warm-cache' @('-What', 'packages') '-packages'
$d  = Start-Part '04-warm-cache' @('-What', 'devices') '-devices'
$bt = Start-Part '03-inventory-bluetooth' @()
$null = $w1.Proc.WaitForExit(); $null = $d.Proc.WaitForExit()
Write-Prog 1 3
Write-Ok (T 'Building the device and driver lists at the same time...')
$p1 = Start-Part '01-inventory-devices' @()
$p2 = Start-Part '02-inventory-drivers' @()
Show-Part $p1
Write-Prog 2 3
Show-Part $p2
Show-Part $bt
Write-Prog 3 3
try { if (@(Get-WuHideList).Count -gt 0) { foreach ($x in @(Invoke-PendingWuHide)) { if ($x.Hidden) { Write-Ok ((T 'Windows Update will not offer this driver again (undo it in Device management)') + ': ' + $x.Title) } } } } catch { }
try { Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { }
if ($fail -gt 0) { Write-Err (T 'Some parts of the inventory ended with an error: see the messages above.'); exit 1 }
exit 0
