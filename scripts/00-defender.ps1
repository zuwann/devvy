# TEMPORARY Microsoft Defender exceptions for this tool.
#   -Action Status    shows the state of Defender and the current exceptions (changes nothing)
#   -Action Diagnose  lists recent events where Defender blocked or reported something about this tool
#   -Action Prepare   checks which exceptions are missing, adds ONLY those and remembers what it added
#   -Action Restore   removes ONLY the exceptions added by this tool (never touches yours)
# Exceptions created (only if missing):
#   - the tool folder
#   - the processes cmd.exe, powershell.exe, pnputil.exe
#   - the same three apps as "allowed apps" of Controlled Folder Access (only if it is on)
# Safety net: if the window is closed without exiting the tool, a scheduled task removes the exceptions
# within 4 hours (or at the next PC start) and the next start of the tool removes them anyway.
# Status also prints one machine readable line:  ##DEFENDER active=<true|false> exceptions=<n>##
param(
    [ValidateSet('Prepare', 'Restore', 'Status', 'Diagnose')][string]$Action = 'Status',
    [switch]$Silent
)
. "$PSScriptRoot\common.ps1"
if (-not $Silent) { Assert-Admin }
Start-Log ('defender-' + $Action.ToLower())

$statePath = Join-Path $script:LogDir 'defender-exceptions.json'
$taskName = 'DevvyDefenderRestore'
$sys32 = Join-Path $env:SystemRoot 'System32'
$psExe = Join-Path $sys32 'WindowsPowerShell\v1.0\powershell.exe'
$wantPath = @($script:Root)
$wantProc = @((Join-Path $sys32 'cmd.exe'), $psExe, (Join-Path $sys32 'pnputil.exe'))

function Get-Pref {
    try { return (Get-MpPreference -ErrorAction Stop) } catch { return $null }
}

function Get-DefenderState {
    $o = [pscustomobject]@{ Available = $false; Active = $false; TamperProtected = $false; Cfa = 0; Detail = '' }
    try {
        $st = Get-MpComputerStatus -ErrorAction Stop
        $o.Available = $true
        $o.Active = [bool]($st.AntivirusEnabled -and $st.AMServiceEnabled -and ($st.RealTimeProtectionEnabled -or ("$($st.AMRunningMode)" -eq 'Normal')))
        $o.TamperProtected = [bool]$st.IsTamperProtected
        $o.Detail = "$($st.AMRunningMode)"
    } catch {
        $o.Detail = $_.Exception.Message
    }
    $pref = Get-Pref
    if ($pref) { $o.Cfa = [int]$pref.EnableControlledFolderAccess }
    return $o
}

# number of exceptions created by this tool and still registered in the state file
function Get-OwnExceptionCount {
    if (-not (Test-Path $statePath)) { return 0 }
    try {
        $s = Get-Content -Path $statePath -Raw | ConvertFrom-Json
        return (@($s.Path | Where-Object { $_ }).Count + @($s.Process | Where-Object { $_ }).Count + @($s.Cfa | Where-Object { $_ }).Count)
    } catch { return 0 }
}

function Test-PathCovered([string[]]$Existing, [string]$Path) {
    foreach ($e in $Existing) {
        if (-not $e) { continue }
        $x = $e.TrimEnd('\', '*')
        if (-not $x) { continue }
        if (($Path -ieq $x) -or $Path.StartsWith($x + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-ProcCovered([string[]]$Existing, [string]$Exe) {
    $leaf = Split-Path $Exe -Leaf
    foreach ($e in $Existing) {
        if (-not $e) { continue }
        if (($e -ieq $Exe) -or ($e -ieq $leaf)) { return $true }
    }
    return $false
}

function Test-AppListed([string[]]$Existing, [string]$Exe) {
    foreach ($e in $Existing) { if ($e -and ($e -ieq $Exe)) { return $true } }
    return $false
}

function Remove-FailsafeTask {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Add-FailsafeTask {
    try {
        $a = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action Restore -Silent' -f $PSCommandPath
        $action = New-ScheduledTaskAction -Execute $psExe -Argument $a
        $trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddHours(4))
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        return $true
    } catch {
        Write-Warn ('  ' + (T 'Safety net not created:') + ' ' + $_.Exception.Message)
        return $false
    }
}

# ---------------------------------------------------------------- Status
function Show-Status {
    $s = Get-DefenderState
    $own = Get-OwnExceptionCount
    Write-Title (T 'Microsoft Defender status')
    if (-not $s.Available) {
        Write-Warn ('  ' + (T 'Defender does not answer (usually because you use another antivirus):') + ' ' + $s.Detail)
        Write-Host ('##DEFENDER active=false exceptions={0}##' -f $own)
        return
    }
    if ($s.Active) { Write-Ok ('  ' + (T 'Real-time protection: ON')) } else { Write-Warn ('  ' + (T 'Real-time protection: NOT active (mode: {0})' $s.Detail)) }
    if ($s.TamperProtected) { Write-Warn ('  ' + (T 'Tamper protection: ON (Windows may refuse to change the exceptions)')) }
    else { Write-Info ('  ' + (T 'Tamper protection: off')) }
    $cfa = T 'off'
    if ($s.Cfa -eq 1) { $cfa = T 'ON (blocks unauthorized writes in Documents, Pictures, Desktop...)' }
    elseif ($s.Cfa -eq 2) { $cfa = T 'audit only (logs but does not block)' }
    elseif ($s.Cfa -ge 3) { $cfa = T 'disk sector mode (does not block files)' }
    Write-Info ('  ' + (T 'Controlled folder access:') + ' ' + $cfa)
    $pref = Get-Pref
    if ($pref) {
        $lp = @($pref.ExclusionPath | Where-Object { $_ }).Count
        $lc = @($pref.ExclusionProcess | Where-Object { $_ }).Count
        $la = @($pref.ControlledFolderAccessAllowedApplications | Where-Object { $_ }).Count
        Write-Info ('  ' + (T 'Exceptions already present: {0} folders/files, {1} processes, {2} allowed apps' $lp $lc $la))
    }
    if ($own -gt 0) { Write-Warn ('  ' + (T 'There are exceptions created by this tool that are still active (they are removed with Restore or when the tool exits).')) }
    Write-Host ('##DEFENDER active={0} exceptions={1}##' -f $s.Active.ToString().ToLower(), $own)
}

# ---------------------------------------------------------------- Prepare
# The marker line tells the web page whether the exceptions are in place (it shows the "exceptions active" badge)
function Write-Covered([bool]$V) { Write-Host ('##DEFENDER covered={0}##' -f $V.ToString().ToLower()) }
function Invoke-Prepare {
    $s = Get-DefenderState
    Write-Title (T 'Microsoft Defender check')
    if (-not $s.Available) {
        Write-Info ('  ' + (T 'Defender does not answer: usually this means you use another antivirus. I create no exceptions.'))
        Write-Warn ('  ' + (T 'If your antivirus blocks this tool, add the folder as an exception by hand:') + ' ' + $script:Root)
        Write-Covered $false
        return
    }
    if (-not $s.Active) {
        Write-Info ('  ' + (T 'Defender real-time protection is not active (mode: {0}): no exceptions are needed.' $s.Detail))
        Write-Warn ('  ' + (T 'If another antivirus blocks this tool, add the folder as an exception by hand:') + ' ' + $script:Root)
        Write-Covered $false
        return
    }
    if ($s.TamperProtected) {
        Write-Warn ('  ' + (T 'Tamper protection is on: Windows may refuse to change the exceptions. I try anyway and tell you how it went.'))
    }
    if (Test-Path $statePath) {
        Write-Info ('  ' + (T 'I found exceptions from a previous session: I remove them before creating them again.'))
        Invoke-Restore -Quiet
    }

    $pref = Get-Pref
    $havePath = @($pref.ExclusionPath)
    $haveProc = @($pref.ExclusionProcess)
    $haveCfa = @($pref.ControlledFolderAccessAllowedApplications)
    $added = @{ Path = @(); Process = @(); Cfa = @() }
    $failed = 0

    Write-Info ('  ' + (T 'I check them one by one (already there = I leave it, missing = I add it):'))
    $lblFolder = T 'folder'
    $lblProc = T 'process'
    $lblApp = T 'allowed app (Controlled folder access)'
    foreach ($p in $wantPath) {
        if (Test-PathCovered $havePath $p) { Write-Info ('    ' + (T 'already there') + '   ' + $lblFolder + '  ' + $p); continue }
        try { Add-MpPreference -ExclusionPath $p -ErrorAction Stop; $added.Path += $p; Write-Ok ('    ' + (T 'ADDED') + '   ' + $lblFolder + '  ' + $p) }
        catch { $failed++; Write-Err ('    ' + (T 'NOT ADDED') + '   ' + $lblFolder + '  ' + $p + ' - ' + $_.Exception.Message) }
    }
    foreach ($p in $wantProc) {
        if (Test-ProcCovered $haveProc $p) { Write-Info ('    ' + (T 'already there') + '   ' + $lblProc + '  ' + $p); continue }
        try { Add-MpPreference -ExclusionProcess $p -ErrorAction Stop; $added.Process += $p; Write-Ok ('    ' + (T 'ADDED') + '   ' + $lblProc + '  ' + $p) }
        catch { $failed++; Write-Err ('    ' + (T 'NOT ADDED') + '   ' + $lblProc + '  ' + $p + ' - ' + $_.Exception.Message) }
    }
    if ($s.Cfa -eq 1) {
        foreach ($p in $wantProc) {
            if (Test-AppListed $haveCfa $p) { Write-Info ('    ' + (T 'already there') + '   ' + $lblApp + '  ' + $p); continue }
            try { Add-MpPreference -ControlledFolderAccessAllowedApplications $p -ErrorAction Stop; $added.Cfa += $p; Write-Ok ('    ' + (T 'ADDED') + '   ' + $lblApp + '  ' + $p) }
            catch { $failed++; Write-Err ('    ' + (T 'NOT ADDED') + '   ' + $lblApp + '  ' + $p + ' - ' + $_.Exception.Message) }
        }
    } else {
        Write-Info ('    ' + (T 'Controlled folder access is off: no allowed apps to add.'))
    }

    # verify: only what is really present is kept in the state file
    $pref2 = Get-Pref
    $vPath = @($pref2.ExclusionPath); $vProc = @($pref2.ExclusionProcess); $vCfa = @($pref2.ControlledFolderAccessAllowedApplications)
    $real = @{ Path = @(); Process = @(); Cfa = @() }
    foreach ($p in $added.Path) { if (Test-PathCovered $vPath $p) { $real.Path += $p } else { $failed++; Write-Err ('    ' + (T 'Check failed (folder):') + ' ' + $p) } }
    foreach ($p in $added.Process) { if (Test-ProcCovered $vProc $p) { $real.Process += $p } else { $failed++; Write-Err ('    ' + (T 'Check failed (process):') + ' ' + $p) } }
    foreach ($p in $added.Cfa) { if (Test-AppListed $vCfa $p) { $real.Cfa += $p } else { $failed++; Write-Err ('    ' + (T 'Check failed (allowed app):') + ' ' + $p) } }

    $n = $real.Path.Count + $real.Process.Count + $real.Cfa.Count
    if ($n -gt 0) {
        $state = [pscustomobject]@{ Created = (Get-Date).ToString('s'); Path = $real.Path; Process = $real.Process; Cfa = $real.Cfa }
        $state | ConvertTo-Json | Set-Content -Path $statePath -Encoding UTF8
        $fs = Add-FailsafeTask
        Write-Ok ('  ' + (T 'Exceptions added by this tool: {0}' $n))
        Write-Info ('  ' + (T 'I remove them when you exit the tool.'))
        if ($fs) { Write-Info ('  ' + (T 'Safety net: if you close the window without exiting, they are removed by themselves within 4 hours or at the next PC start.')) }
    } else {
        Write-Info ('  ' + (T 'I did not have to add anything: the needed exceptions were already there (or were not accepted).'))
    }
    if ($failed -gt 0) {
        Write-Todo @(
            (T 'Windows refused {0} exceptions (probably tamper protection or organization policies).' $failed),
            (T 'You can continue anyway: the exceptions are only needed if Defender blocks something.'),
            (T 'If blocks appear, run the Defender diagnosis to see what was blocked and add the exceptions by hand in Windows Security > Virus and threat protection > Manage settings > Exclusions.')
        ) (T 'WARNING')
    }
    Write-Covered ($failed -eq 0)
}

# ---------------------------------------------------------------- Restore
function Invoke-Restore([switch]$Quiet) {
    if (-not (Test-Path $statePath)) {
        if (-not $Quiet) { Write-Info (T 'No exceptions created by this tool: nothing to restore.') }
        Remove-FailsafeTask
        return
    }
    $s = $null
    try { $s = Get-Content -Path $statePath -Raw | ConvertFrom-Json }
    catch { Write-Err ((T 'State file unreadable:') + ' ' + $_.Exception.Message); return }

    if (-not $Quiet) { Write-Title (T 'Restoring the Defender exceptions created by this tool') }
    foreach ($p in @($s.Path)) {
        if (-not $p) { continue }
        try { Remove-MpPreference -ExclusionPath $p -ErrorAction Stop } catch { Write-Err ('  ' + (T 'Error removing the folder {0}: {1}' $p $_.Exception.Message)) }
    }
    foreach ($p in @($s.Process)) {
        if (-not $p) { continue }
        try { Remove-MpPreference -ExclusionProcess $p -ErrorAction Stop } catch { Write-Err ('  ' + (T 'Error removing the process {0}: {1}' $p $_.Exception.Message)) }
    }
    foreach ($p in @($s.Cfa)) {
        if (-not $p) { continue }
        try { Remove-MpPreference -ControlledFolderAccessAllowedApplications $p -ErrorAction Stop } catch { Write-Err ('  ' + (T 'Error removing the allowed app {0}: {1}' $p $_.Exception.Message)) }
    }

    # verify
    $pref = Get-Pref
    $left = New-Object System.Collections.Generic.List[string]
    if ($pref) {
        $vPath = @($pref.ExclusionPath); $vProc = @($pref.ExclusionProcess); $vCfa = @($pref.ControlledFolderAccessAllowedApplications)
        foreach ($p in @($s.Path)) { if ($p -and (Test-PathCovered $vPath $p)) { $left.Add((T 'folder:') + ' ' + $p) } }
        foreach ($p in @($s.Process)) { if ($p -and (Test-ProcCovered $vProc $p)) { $left.Add((T 'process:') + ' ' + $p) } }
        foreach ($p in @($s.Cfa)) { if ($p -and (Test-AppListed $vCfa $p)) { $left.Add((T 'allowed app:') + ' ' + $p) } }
    }
    if ($left.Count -eq 0) {
        Remove-Item -Path $statePath -Force -ErrorAction SilentlyContinue
        Remove-FailsafeTask
        Write-Ok ('  ' + (T 'Exceptions removed: Defender is back as it was before.'))
    } else {
        $lines = @(T 'These exceptions are still there and must be removed by hand:')
        foreach ($l in $left) { $lines += ('   ' + $l) }
        $lines += T 'Open Windows Security > Virus and threat protection > Manage settings > Add or remove exclusions, and remove them.'
        Write-Todo $lines (T 'WARNING: EXCEPTIONS STILL ACTIVE')
    }
}

# ---------------------------------------------------------------- Diagnose
function Invoke-Diagnose {
    Write-Title (T 'Diagnosis: did Defender block anything of this tool? (last 7 days)')
    $ids = @(1116, 1117, 1121, 1122, 1123, 1124)
    $names = @{
        1116 = T 'Threat detected'
        1117 = T 'Action taken against a threat (quarantine or removal)'
        1121 = T 'ASR rule: BLOCKED'
        1122 = T 'ASR rule: audit only'
        1123 = T 'Controlled folder access: BLOCKED'
        1124 = T 'Controlled folder access: audit only'
    }
    $ev = @()
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Windows Defender/Operational'; Id = $ids; StartTime = (Get-Date).AddDays(-7) } -ErrorAction Stop)
    } catch {
        Write-Info ('  ' + (T 'No events read (or log not available):') + ' ' + $_.Exception.Message)
        return
    }
    $pat = 'powershell|cmd\.exe|pnputil|' + [regex]::Escape($script:Root)
    $mine = @($ev | Where-Object { $_.Message -match $pat })
    Write-Info ('  ' + (T 'Defender events in the last 7 days: {0} (of which {1} concern this tool, PowerShell, cmd or pnputil)' $ev.Count $mine.Count))
    if ($mine.Count -eq 0) {
        Write-Ok ('  ' + (T 'No block or report concerning this tool: the exceptions are probably not needed.'))
        return
    }
    $rows = foreach ($e in ($mine | Sort-Object TimeCreated -Descending)) {
        $m = ("$($e.Message)" -replace '\s+', ' ')
        if ($m.Length -gt 300) { $m = $m.Substring(0, 300) }
        [pscustomobject][ordered]@{ When = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm'); Id = $e.Id; Type = $names[[int]$e.Id]; Detail = $m }
    }
    $path = Save-ReportCsv $rows 'defender-events'
    foreach ($r in ($rows | Select-Object -First 8)) {
        $col = 'Yellow'
        if ($r.Id -in @(1117, 1121, 1123)) { $col = 'Red' }
        Write-Host ('  {0}  {1}' -f $r.When, $r.Type) -ForegroundColor $col
    }
    Write-Info ('  ' + (T 'Full list:') + ' ' + $path)
    Write-Todo @(
        (T 'Red lines = Defender BLOCKED something: try again after allowing the temporary exceptions.'),
        (T 'Yellow lines = Defender only logged it (audit): it did not block anything.'),
        (T 'If a file of the tool was quarantined, restore it from Windows Security > Virus and threat protection > Protection history.')
    )
}

switch ($Action) {
    'Status'   { Show-Status }
    'Diagnose' { Invoke-Diagnose }
    'Prepare'  { Invoke-Prepare }
    'Restore'  { Invoke-Restore; Write-Covered $false }
}
Stop-Log
