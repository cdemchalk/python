#Requires -Version 5.1
<#
Applies the two power fixes behind the "Crystal worked yesterday, now shows
disconnected, no hardware changed" case:
  * disables USB selective suspend (AC + DC) so Windows cannot power down the
    headset's USB port, and
  * disables Fast Startup so a Shut Down performs a clean device init instead
    of restoring a stale USB/DisplayPort state.
Then offers to reboot (the cold boot is what clears a post-Windows-Update
stale state).

Run from an *elevated* PowerShell prompt:
    powershell -ExecutionPolicy Bypass -File .\Fix-PimaxPowerSettings.ps1
#>

[CmdletBinding()]
param([switch]$RebootNow)

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal] `
           [Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'ERROR: must be run as Administrator.' -ForegroundColor Red
    exit 1
}

$usbSub = '2a737441-1930-4402-8d77-b2bebba308a3'  # USB settings subgroup
$usbSel = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'  # USB selective suspend setting

Write-Host 'Disabling USB selective suspend (AC + DC)...' -ForegroundColor Cyan
powercfg /setacvalueindex SCHEME_CURRENT $usbSub $usbSel 0
powercfg /setdcvalueindex SCHEME_CURRENT $usbSub $usbSel 0
powercfg /setactive SCHEME_CURRENT
Write-Host '  done.' -ForegroundColor Green

Write-Host 'Disabling Fast Startup (HiberbootEnabled = 0)...' -ForegroundColor Cyan
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
                 -Name 'HiberbootEnabled' -Value 0 -Type DWord
Write-Host '  done.' -ForegroundColor Green

Write-Host ''
Write-Host 'Manual step this script cannot safely automate per-device:' -ForegroundColor Yellow
Write-Host '  Device Manager > Universal Serial Bus controllers > each "USB Root Hub"' -ForegroundColor Gray
Write-Host '  > Properties > Power Management > uncheck "Allow the computer to turn' -ForegroundColor Gray
Write-Host '  off this device to save power".' -ForegroundColor Gray
Write-Host ''

Write-Host 'A full reboot is required to clear the stale USB/DisplayPort state.' -ForegroundColor Cyan
if ($RebootNow) {
    Write-Host 'Rebooting now...' -ForegroundColor Yellow
    Restart-Computer -Force
} else {
    $ans = Read-Host 'Reboot now? (y/N)'
    if ($ans -match '^[Yy]') { Restart-Computer -Force }
    else { Write-Host 'Skipped. Please Restart (not Shut Down) before testing the Crystal.' -ForegroundColor Gray }
}
