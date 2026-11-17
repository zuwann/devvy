# Fixes ONE problem found by the self-check. Only known fixes are accepted (the page cannot ask for anything else).
# Usage: 00-fix.ps1 -Fix enable-service:wuauserv
param([Parameter(Mandatory = $true)][string]$Fix)
. "$PSScriptRoot\common.ps1"
Assert-Admin
Start-Log 'fix'
Write-Title (T 'FIXING THE PROBLEM')

$okServices = @('Schedule', 'wuauserv', 'bthserv')
if ($Fix -match '^enable-service:(\w+)$' -and ($okServices -contains $Matches[1])) {
    $svc = $Matches[1]
    try {
        $mode = 'Manual'
        if ($svc -eq 'Schedule') { $mode = 'Automatic' }
        Set-Service -Name $svc -StartupType $mode -ErrorAction Stop
        Start-Service -Name $svc -ErrorAction SilentlyContinue
        Write-Ok (T 'Service {0} enabled.' $svc)
        Write-Info ('  ' + (T 'Run the check again to see the result.'))
    } catch {
        Write-Err (T 'Windows refused: {0}' ($_.Exception.Message -replace '\s+', ' '))
        Stop-Log
        exit 1
    }
    Stop-Log
    exit 0
}
Write-Err (T 'Unknown fix: {0}' $Fix)
Stop-Log
exit 1
