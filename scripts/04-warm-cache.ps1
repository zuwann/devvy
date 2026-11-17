# Reads (and keeps) the slow Windows answers, so that the inventories find them ready. Started by 04-inventory-all.ps1 only.
param([ValidateSet('packages', 'devices')][string]$What)
. "$PSScriptRoot\common.ps1"
if ($What -eq 'packages') { $null = Get-DriverPackages } else { $null = Get-DeviceDriverMap }
